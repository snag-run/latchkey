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
#   v2  CodeRabbit reviewed AND all its review threads are resolved
#       - keyed off real review/comment + thread OBJECTS (GraphQL), NOT the
#         check-run name or a comment substring -> immune to "Review skipped"
#         and stale-ack false-greens.
#       - respects the summon-once convention: does NOT require the review to be
#         on HEAD, only that CodeRabbit ran and its threads are resolved.
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
pr_json="$(gh pr view --json number,state 2>/dev/null)" || exit 0
pr_number="$(printf '%s' "$pr_json" | jq -r '.number // empty')"
pr_state="$(printf '%s'  "$pr_json" | jq -r '.state  // empty')"
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

cr_query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviews(first:100){nodes{author{login}}} comments(first:100){nodes{author{login}}} reviewThreads(first:100){nodes{isResolved comments(first:1){nodes{author{login}}}}}}}}'

fetch_cr() { gh api graphql -f query="$cr_query" -f owner="$owner" -f repo="$repo" -F pr="$pr_number" 2>/dev/null; }

# Short in-shell wait for CodeRabbit's review to appear (async processing).
waited=0; cr_json=""
while :; do
  cr_json="$(fetch_cr)"
  # If the API errored / returned no PR node, we can't verify CR -> fail open on CI-green.
  printf '%s' "$cr_json" | jq -e '.data.repository.pullRequest' >/dev/null 2>&1 || pass
  reviewed="$(printf '%s' "$cr_json" | jq -r '
    [ .data.repository.pullRequest.reviews.nodes[].author.login,
      .data.repository.pullRequest.comments.nodes[].author.login ]
    | map(select(. != null and (ascii_downcase | test("coderabbit")))) | length' 2>/dev/null || echo 0)"
  [ "${reviewed:-0}" -gt 0 ] && break
  [ "$waited" -ge "$CR_WAIT_TIMEOUT" ] && break
  sleep "$CR_POLL_INTERVAL"; waited=$((waited + CR_POLL_INTERVAL))
done

if [ "${reviewed:-0}" -eq 0 ]; then
  block "CodeRabbit has not reviewed this PR yet. Summon it ONCE with a '@coderabbitai review' comment and let it finish (do NOT re-summon after later fix pushes)."
fi

unresolved="$(printf '%s' "$cr_json" | jq -r '
  [ .data.repository.pullRequest.reviewThreads.nodes[]
    | select((.comments.nodes[0].author.login // "") | ascii_downcase | test("coderabbit"))
    | select(.isResolved == false) ] | length' 2>/dev/null || echo 0)"

if [ "${unresolved:-0}" -gt 0 ]; then
  block "CodeRabbit has $unresolved unresolved review thread(s). Address each one, reply on the thread referencing the fix, and resolve it — then you may finish."
fi

pass
