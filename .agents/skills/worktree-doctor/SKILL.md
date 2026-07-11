---
name: worktree-doctor
description: End-of-day worktree hygiene pass — survey every git worktree, resync merged-branch lanes to main, surface in-flight work that should be pushed or draft-PR'd, and flag stale/obsolete branches. Assumes NO agents are running (all worktrees idle). Use when the user says "fix the worktrees", "worktree doctor", "clean up worktrees", "end of day cleanup", or wants the lanes tidied before stopping work.
---

# Worktree Doctor — end-of-day lane hygiene

Survey and tidy every git worktree in one pass. **Assume all worktrees are idle** (this runs when no agents are working — typically end of day). If you suspect an agent is mid-task in a lane, stop and confirm before touching it.

The destructive steps (`reset --hard`, `clean -fd`, `branch -D`) will be **blocked by the auto-mode safety classifier**. That's expected and correct. Do all the read-only surveying and verification yourself, then **hand the user a copy-pasteable command block** for the destructive parts (or ask them to approve / run outside auto mode). Never try to work around the classifier.

## 1. Survey — read-only, never mutate here

```bash
git fetch origin --prune
git worktree list
```

For each worktree, capture: current branch, ahead/behind `origin/main`, tracked vs untracked change counts, and the commits ahead of main.

```bash
# Read paths line-safe (a worktree path may contain spaces).
git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}' | while IFS= read -r wt; do
  br=$(git -C "$wt" branch --show-current)
  ahead=$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null)
  behind=$(git -C "$wt" rev-list --count HEAD..origin/main 2>/dev/null)
  tracked=$(git -C "$wt" status --porcelain | grep -vc '^??')
  untracked=$(git -C "$wt" status --porcelain | grep -c '^??')
  echo "$wt | $br | ahead:$ahead behind:$behind | tracked:$tracked untracked:$untracked"
  git -C "$wt" log --oneline origin/main..HEAD | head
done
```

Then pull the PR picture (branches are squash-merged by convention, so merged branches are NOT ancestors of main — use the PR list, not `git branch --merged`). Capture the merged PR's **head SHA** (`headRefOid`), not just its branch name — you need it in §2:

```bash
gh pr list --state open   --limit 200 --json number,title,headRefName,isDraft,mergeable
gh pr list --state merged --limit 200 --json number,title,headRefName,headRefOid \
  --jq '.[] | "\(.number) \(.headRefName) @\(.headRefOid[0:9]) — \(.title)"'
```

## 2. Categorize each worktree

Match each lane's branch against the PR lists:

- **Merged branch** — its `headRefName` appears in the *merged* PR list **and** the lane's current tip (`git -C "$wt" rev-parse HEAD`) equals that PR's `headRefOid`. Only then is the authored work fully on main → **resync to main** (§3). If the name matches but the tip has moved past the merged SHA, the lane has **new post-merge commits** — treat it as in-flight (push / draft-PR, §5), never reset. The §3 delta check is the backstop, but match the SHA first.
- **Open PR, unpushed commits** (ahead of `origin/<branch>`) → the in-flight work needs a **push**. Surface it; don't force-resync.
- **In-flight, no PR, has uncommitted or unpushed work** → candidate for a **draft PR** or at least a commit so it survives. **Never discard.** Recommend, then act only on confirmation.
- **Stale / obsolete / superseded** (unmerged, far behind, and its diff would *revert* recent main work) → **flag for discard with the rationale**; do not auto-delete unmerged branches.
- **Clean lane at main** (0 ahead / 0 behind, no changes) → leave it.

### Detect the `f.txt` junk-commit corruption

A recurring corruption appears as two commits authored `Test <t@example.com>` titled **`first commit`** (mass-deletes every tracked file) and **`second commit`** (adds `f.txt`), sitting on top of real work, with the whole tree showing as *untracked* and `f.txt` *deleted*. This is throwaway test cruft — the real work underneath is what matters. Resync to main drops it cleanly.

## 3. Verify BEFORE any destructive resync (no lost work)

A worktree showing everything as untracked is usually just stale + corrupted, but **prove it holds no unique authored work** before resetting. Use a throwaway index so you don't mutate the real one:

```bash
idx="$(mktemp -u)"                       # a path, not an empty file — read-tree writes a valid index here
trap 'rm -f "$idx"' RETURN               # clean up even on early return/error
GIT_INDEX_FILE="$idx" git -C "$wt" read-tree origin/main
GIT_INDEX_FILE="$idx" git -C "$wt" add -A
GIT_INDEX_FILE="$idx" git -C "$wt" diff --cached --stat origin/main   # delta vs main
rm -f "$idx"
```

Every line in that delta must be explainable as **staleness** (main advanced past this checkout) or the **`f.txt` junk**. If you see a file with genuinely novel content — a feature that isn't on main and isn't in any PR — **stop and surface it**; do not reset.

## 4. Resync command block (hand to the user)

You can't run these in auto mode. Present them per-worktree so each is auditable. For each **merged-branch** lane:

```bash
wt=/abs/path/to/worktree
git -C "$wt" reset --hard origin/main   # tracked → main; overwrites the stale/junk tree
git -C "$wt" clean -fd                  # drop untracked leftovers (f.txt, removed-from-main files)
git -C "$wt" switch --detach            # detach so the branch can be deleted
git -C "$wt" branch -D <merged-branch>  # safe: confirmed merged via the squash PR list
```

For the fixed lanes (`lane/wt1`, `lane/wt2`, `lane/wt3`, `lane/docs`), the branch is a persistent lane you keep — resync it rather than deleting: `git -C "$wt" reset --hard origin/main` and leave the lane branch checked out. Only `branch -D` throwaway feature branches.

**Guards:**
- **Never `git clean -fdx`** — the bare `-fd` preserves git-ignored build artifacts (`_build`, `deps`), which are expensive to rebuild. Only `-x` would nuke them; don't.
- **Never `git checkout main`** — `main` is usually locked in the privileged lane (`latchkey`).
- Use `branch -D` (force) only because squash-merges aren't ancestors so `-d` wrongly refuses; this is why §1's merged-PR check is the real safety gate.

## 5. In-flight work — push or draft-PR

For lanes with unpushed/uncommitted work the user wants to preserve:

- **Open PR + unpushed commits:** one push to bring the PR current (re-trigger `@coderabbitai review` if it was approved — a push dismisses approvals). See `ship-pr`.
- **No PR yet:** commit the WIP on its branch and open a **draft** PR (`gh pr create --draft`), kept untriggered. This is the safety net so a stray reset can't lose it.

Always confirm with the user before committing someone's WIP or opening a PR — recommend in prose, don't auto-fire.

## 6. Lane policy

Fixed lanes are `latchkey` (main-privileged), `latchkey-wt1`/`wt2`/`wt3` (branches `lane/wt1`…), plus the cheap `latchkey-docs` lane (`lane/docs`). **Purpose-named one-off worktrees** (e.g. `latchkey-wt-deps`) are discouraged — if you find one whose work is merged/obsolete, flag whether to `git worktree remove` it (a heavier, separate decision than resyncing) rather than removing it unasked.

## 7. Report

Close with a table: each worktree → its state → action taken (or command handed off) → anything flagged for a decision. Don't claim a lane is clean until you've shown the `git status`/`git log` that proves it.
