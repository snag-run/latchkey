#!/usr/bin/env bash
#
# SubagentStop hook — loop-engineering gate (v2).
#
# Principle: the actor can't be the judge. A per-ticket sub-agent cannot finish
# until its PR is verifiably merge-ready — checked from ground truth, not from the
# agent's self-report, so false-green termination is structurally impossible.
#
# Two deterministic gates, checked by script (no LLM in the loop):
#   v1  CI is green on the PR   (via `gh pr checks --watch`, reads existing CI)
#   v2  CodeRabbit reviewed the CURRENT head AND all its threads are resolved
#       - keyed off real review/comment + thread OBJECTS (GraphQL), NOT the
#         check-run name or a comment substring -> immune to "Review skipped"
#         and stale-ack false-greens.
#       - freshness: only a CodeRabbit review whose commit == the PR head SHA
#         satisfies the gate, so feedback from an earlier commit can't green a
#         later push. This does NOT re-summon CodeRabbit — the summon-once
#         convention holds; the gate just waits for CodeRabbit's own incremental
#         review of the latest push to land.
#       - every connection (reviews / comments / reviewThreads) is paginated in
#         full, so a PR with >100 of any isn't silently mis-evaluated.
#
# OPT-IN: does nothing unless LATCHKEY_CI_GATE=1 is exported in the session, so
# ad-hoc / Explore / research / Plan sub-agents always exit normally.
#
# Exit 0 -> allow stop (verified / nothing to gate / can't verify / escalated).
# Exit 2 -> block stop; stderr is fed back to the agent as instructions.

set -uo pipefail

MAX_ATTEMPTS=3
CI_WATCH_TIMEOUT=900     # seconds; ceiling on waiting for CI to finish
CR_WAIT_TIMEOUT=120      # seconds; short in-shell wait for CodeRabbit to appear
CR_POLL_INTERVAL=20

# --- Opt-in only: default OFF => every sub-agent exits normally ---------------
[ "${LATCHKEY_CI_GATE:-0}" = "1" ] || exit 0

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true

# Resolve the PR for the current branch. No PR / not open => nothing to gate.
pr_json="$(gh pr view --json number,state,headRefOid 2>/dev/null)" || exit 0
pr_number="$(printf '%s' "$pr_json" | jq -r '.number     // empty')"
pr_state="$(printf '%s'  "$pr_json" | jq -r '.state      // empty')"
head_sha="$(printf '%s'  "$pr_json" | jq -r '.headRefOid // empty')"
[ -z "$pr_number" ] && exit 0
[ "$pr_state" != "OPEN" ] && exit 0

counter_dir="${TMPDIR:-/tmp}/latchkey-ci-gate"; mkdir -p "$counter_dir"
counter_file="$counter_dir/pr-$pr_number"

pass() { rm -f "$counter_file"; exit 0; }

block() {   # $1 = instruction message (may be multiline)
  local msg="$1" attempts
  attempts="$(cat "$counter_file" 2>/dev/null || echo 0)"; attempts=$((attempts + 1))
  echo "$attempts" > "$counter_file"
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    rm -f "$counter_file"
    { echo "⚠️  GATE ESCALATION — PR #$pr_number not merge-ready after $MAX_ATTEMPTS attempts. Allowing stop for human review. NOT merge-ready:"
      echo "$msg"; } >&2
    exit 0
  fi
  { echo "🔴 PR #$pr_number is NOT merge-ready (attempt $attempts/$MAX_ATTEMPTS). Do NOT report success."
    echo "$msg"; } >&2
  exit 2
}

# ---- v1: CI green -----------------------------------------------------------
if ! gh pr checks "$pr_number" 2>&1 | grep -qi "no checks reported"; then
  if ! timeout "$CI_WATCH_TIMEOUT" gh pr checks "$pr_number" --watch >/dev/null 2>&1; then
    block "$(printf 'CI is NOT green. Fix the failing checks and push:\n%s' "$(gh pr checks "$pr_number" 2>&1)")"
  fi
fi

# ---- v2: CodeRabbit reviewed + all its threads resolved ---------------------
repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || pass
[ -z "$repo_nwo" ] && pass
owner="${repo_nwo%%/*}"; repo="${repo_nwo##*/}"

# One connection per query so `--paginate` can follow a single cursor to the
# last page. Each query paginates on $endCursor (gh injects it) via pageInfo.
# shellcheck disable=SC2016  # $owner/$repo/$pr/$endCursor are GraphQL vars, not shell
reviews_q='query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviews(first:100,after:$endCursor){nodes{author{login} commit{oid}} pageInfo{hasNextPage endCursor}}}}}'
# shellcheck disable=SC2016
comments_q='query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$pr){comments(first:100,after:$endCursor){nodes{author{login}} pageInfo{hasNextPage endCursor}}}}}'
# shellcheck disable=SC2016
threads_q='query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:100,after:$endCursor){nodes{isResolved comments(first:1){nodes{author{login}}}} pageInfo{hasNextPage endCursor}}}}}'

# Raw concatenated pages for one paginated query.
gql_pages() { gh api graphql --paginate -f query="$1" -f owner="$owner" -f repo="$repo" -F pr="$pr_number" 2>/dev/null; }
# Flatten every page's nodes for connection $2 (e.g. .reviews) into one array.
nodes_of() { printf '%s' "$1" | jq -s "[ .[].data.repository.pullRequest$2.nodes[] ]" 2>/dev/null; }
# Count CodeRabbit-authored nodes in a flat array.
cr_count() { printf '%s' "$1" | jq '[ .[] | select((.author.login // "") | ascii_downcase | test("coderabbit")) ] | length' 2>/dev/null || echo 0; }

# Short in-shell wait for CodeRabbit to review the CURRENT head (async / incremental).
waited=0; cr_any=0; fresh=0
while :; do
  reviews_raw="$(gql_pages "$reviews_q")"
  # API/auth error or no PR node on the first page -> can't verify CR -> fail open on CI-green.
  printf '%s' "$reviews_raw" | jq -e -s '.[0].data.repository.pullRequest' >/dev/null 2>&1 || pass
  comments_raw="$(gql_pages "$comments_q")"

  reviews_nodes="$(nodes_of "$reviews_raw" .reviews)"
  comments_nodes="$(nodes_of "$comments_raw" .comments)"

  cr_any=$(( $(cr_count "$reviews_nodes") + $(cr_count "$comments_nodes") ))
  cr_head="$(printf '%s' "$reviews_nodes" | jq --arg sha "$head_sha" \
    '[ .[] | select((.author.login // "") | ascii_downcase | test("coderabbit")) | select(.commit.oid == $sha) ] | length' 2>/dev/null || echo 0)"

  # With a known head SHA only a review ON that SHA counts; otherwise fall back to "any".
  if [ -n "$head_sha" ]; then fresh="$cr_head"; else fresh="$cr_any"; fi

  [ "${fresh:-0}" -gt 0 ] && break
  [ "$waited" -ge "$CR_WAIT_TIMEOUT" ] && break
  sleep "$CR_POLL_INTERVAL"; waited=$((waited + CR_POLL_INTERVAL))
done

if [ "${fresh:-0}" -eq 0 ]; then
  if [ "${cr_any:-0}" -gt 0 ]; then
    block "CodeRabbit reviewed an earlier commit but has NOT yet reviewed the current head (${head_sha:0:7}). Wait for its incremental review of the latest push to land — do NOT re-summon."
  else
    block "CodeRabbit has not reviewed this PR yet. Summon it ONCE with a '@coderabbitai review' comment and let it finish (do NOT re-summon after later fix pushes)."
  fi
fi

threads_raw="$(gql_pages "$threads_q")"
threads_nodes="$(nodes_of "$threads_raw" .reviewThreads)"
unresolved="$(printf '%s' "$threads_nodes" | jq '
  [ .[]
    | select((.comments.nodes[0].author.login // "") | ascii_downcase | test("coderabbit"))
    | select(.isResolved == false) ] | length' 2>/dev/null || echo 0)"

if [ "${unresolved:-0}" -gt 0 ]; then
  block "CodeRabbit has $unresolved unresolved review thread(s). Address each one, reply on the thread referencing the fix, and resolve it — then you may finish."
fi

pass
