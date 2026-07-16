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

`mix precommit` is the whole gate and is **enforced before every push** by `.githooks/pre-push` (wired per-clone by `mix setup`). It runs the audits, compile-as-errors, format check, `credo --strict`, `sobelow`, and the test suite under coverage:

```bash
mix precommit
# deps.unlock --check-unused · hex.audit · deps.audit · compile --warnings-as-errors
# · format --check-formatted · credo --strict · sobelow --config · ash.setup · coveralls
```

If you only want the fast pieces while iterating, run them individually — but **`mix precommit` must be green before you push**. Fix everything red here; don't push a partial. **Never lower the coverage floor** (`coveralls.json`) or file unrequested issues to route around a failure — surface it to David. Emergency bypass (rare, and you own the risk): `SKIP_PREPUSH=1 git push`.

**Verify the real exit status — do not infer "green" from the tail of the output.** `mix precommit` passed only if it exited `0`. Check the actual exit code (`echo "gate exit: $?"` on its own line immediately after, or that the tool didn't report a non-zero exit) — never conclude "passed" from the last printed line. In a chained command a trailing success message can print *after* an earlier step already failed; that has produced false-green reports before. If you didn't watch it exit 0, you don't know it's green — re-run it.

## 3. Push once, open the PR

- **One push per batch** to save cycles. Stage deliberately; don't push WIP.
- PR body: repeat `Closes #N` before **each** issue number (only the first auto-closes otherwise).
- **No `Co-Authored-By` / "Generated with" trailer** in commits or PR body — it biases the LLM reviewer.
- Trivial PRs (see step 4's summon test) stay **draft** and untriggered *through review* — but a draft can't be squash-merged, so **mark it ready (`gh pr ready <n>`) as part of the step 5 handoff**.

## 4. Babysit CodeRabbit to green

**First decide whether to summon at all — default is YES.** Skip the CodeRabbit summon *only* when the change is genuinely trivial, meaning **both**:

1. the diff touches **only** mechanical paths — `README.md`, `CHANGELOG.md`, other non-decision `*.md`, `.github/**`, non-secret JSON/config; **and**
2. total changed lines (added + deleted, **excluding** lockfiles/generated files like `mix.lock`) is **≤ 150** — a tunable knob, nudge it if the cut-line feels wrong.

**Always summon, regardless of size,** when the diff touches any of: `lib/**`, `priv/repo/migrations/**`, `config/runtime.exs`, or the **decision docs** — `docs/adr/**`, `docs/spec/**`, `docs/brief/**`, `CONTEXT.md` — or `test/**`. Line count is *not* a proxy for triviality in this domain: a 10-line ledger/money change or a 40-line ADR is exactly what most needs review, while a 200-line README refresh needs none. Decision docs and domain code are always reviewed by *path*; the ≤150 cap only guards a large mechanical dump. `test/**` is always reviewed because a wrong assertion locks in wrong behavior (mirrors the pre-push gate, which treats test changes as gate-worthy). **When in doubt, summon — an unrecognized path is "review", not "skip".**

Check the diff before deciding — classify against the **full** changed-path list (a lockfile bump like `mix.lock` is *not* a mechanical README, so it must show up here and force a summon), and exclude lockfiles/generated files **only** from the line-count total:

```bash
git diff --name-only "origin/main...HEAD"                          # classification: every path counts
git diff --numstat "origin/main...HEAD" -- . ':(exclude)mix.lock'  # line-count total only
```

If every changed path is mechanical **and** the summed lines ≤ 150, leave the PR as **draft** and skip to step 5. Otherwise:

- CodeRabbit auto-review is OFF (`.coderabbit.yaml`, summon-only). Trigger it explicitly: comment `@coderabbitai review` on the PR. (A push dismisses approvals — re-trigger after pushes.)
- For each CodeRabbit comment: fix it, or skip with a brief justification when not warranted. Then **reply in-thread** referencing the fix/skip rationale and **resolve** the thread.
- `request_changes_workflow` is on, so a clean pass ends with CodeRabbit's approval. Treat the PR as done only once the review is resolved — verify, don't assume.

## 5. Hand off the merge (do not self-merge)

The harness denies `gh pr merge` to protected `main` even with verbal OK. Drive the PR to merge-ready, then hand David the squash command. If the PR is still a **draft** (the trivial-PR path), mark it ready first — a draft can't be merged:

```bash
gh pr ready <n>                          # only if it's still a draft
gh pr merge <n> --squash --delete-branch
```

Squash title = PR title, body = PR description. `--delete-branch` because this repo does **not** auto-delete on merge.

## Notes

- Flag **major decisions** (architectural/scope/risky) to David rather than deciding unilaterally.
- If blocked (env, permissions, harness gate), stop and produce a precise handoff with the blocking cause — don't report success on partial work.
