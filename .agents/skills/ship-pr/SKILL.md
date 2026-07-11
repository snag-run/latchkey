---
name: ship-pr
description: Drive a change from working tree to merge-ready PR using this repo's conventions — verify context, run the full local gate, push once, babysit CodeRabbit to green, then hand off the squash-merge command. Use when the user says "ship this", "open a PR", "take this to merge-ready", or after a fix/feature is implemented and ready to go out.
---

# Ship PR

Take an implemented change all the way to merge-ready. This repo is **squash-only into `main`** (David's convention — the repo also permits merge/rebase, so always pass `--squash`), CodeRabbit is **summon-only** (auto-review disabled repo-wide), and there is **no CI workflow** — the local gate is the whole gate. Follow the steps in order; do not skip the verification gates.

## 1. Verify context first (cheap, prevents the #1 friction class)

```bash
git worktree list
git branch --show-current
git log --oneline origin/main..HEAD
git status --short
```

Confirm out loud: which worktree, which branch, what diverges from `origin/main`. If you're on `main` or a stale/merged branch, branch off fresh `origin/main` first (`git fetch origin && git checkout -b <type>/<n>-<slug> origin/main`). Never `git checkout main` — it's usually locked in another worktree.

## 2. Run the FULL local gate (this repo has no CI — local IS the gate)

There is no pre-push hook wired yet, so this is manual discipline. `mix precommit` runs compile-as-errors, unused-dep check, format, and the test suite (which runs `ash.setup --quiet` first):

```bash
mix precommit   # compile --warnings-as-errors, deps.unlock --unused, format, test
```

If you only want the fast pieces while iterating, run them individually — but **`mix precommit` must be green before you push**. Fix everything red here; don't push a partial. Never file unrequested issues to route around a failure — surface it to David.

## 3. Push once, open the PR

- **One push per batch** to save cycles. Stage deliberately; don't push WIP.
- PR body: repeat `Closes #N` before **each** issue number (only the first auto-closes otherwise).
- **No `Co-Authored-By` / "Generated with" trailer** in commits or PR body — it biases the LLM reviewer.
- Keep trivial PRs as **draft** and untriggered.

## 4. Babysit CodeRabbit to green

- CodeRabbit auto-review is OFF (`.coderabbit.yaml`, summon-only). Trigger it explicitly: comment `@coderabbitai review` on the PR. (A push dismisses approvals — re-trigger after pushes.)
- For each CodeRabbit comment: fix it, or skip with a brief justification when not warranted. Then **reply in-thread** referencing the fix/skip rationale and **resolve** the thread.
- `request_changes_workflow` is on, so a clean pass ends with CodeRabbit's approval. Treat the PR as done only once the review is resolved — verify, don't assume.

## 5. Hand off the merge (do not self-merge)

The harness denies `gh pr merge` to protected `main` even with verbal OK. Drive the PR to merge-ready, then hand David the squash command:

```bash
gh pr merge <n> --squash --delete-branch
```

Squash title = PR title, body = PR description. `--delete-branch` because this repo does **not** auto-delete on merge.

## Notes

- Flag **major decisions** (architectural/scope/risky) to David rather than deciding unilaterally.
- If blocked (env, permissions, harness gate), stop and produce a precise handoff with the blocking cause — don't report success on partial work.
