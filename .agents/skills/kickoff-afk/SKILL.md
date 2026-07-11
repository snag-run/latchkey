---
name: kickoff-afk
description: Fan out independent `ready-for-agent`-labeled GitHub issues to parallel worktree-isolated agents, each driving its issue to a merge-ready PR, then report a status table and hand off the merges. Use when the user says "kick off AFK work", "run the ready-for-agent issues", "fan out the agent-ready issues", or wants a backlog of independent issues turned into PRs overnight. For interdependent issues that need ordered, merge-gated waves, use `to-run-plan` instead.
---

# Kick off loose AFK work

Turn a batch of **independent**, ready-for-agent issues into a queue of merge-ready PRs the operator can review. This is the *loose* counterpart to `to-run-plan`: no dependency DAG, no wave gating — each issue is grabbed and shipped on its own.

## When this fits vs. `to-run-plan`

- **This skill** — issues are independent (no "must merge X before Y"). Maximum parallelism, no ordering. Signalled by the **`ready-for-agent`** label.
- **`to-run-plan`** — issues are interdependent and need a dependency DAG with merge-gated waves. Signalled by an **`in-run-plan`** label (create it if/when you start orchestrating). If candidate issues touch the same files or have ordering constraints, stop and route to `to-run-plan` instead.

## 1. Discover candidates

Default candidate set = open issues labeled **`ready-for-agent`** that aren't claimed by a run plan and don't need a human:

```bash
gh issue list --state open --label ready-for-agent --limit 500 \
  --json number,title,labels \
  --jq '.[] | select((.labels|map(.name)) as $l | ($l|index("in-run-plan")|not) and ($l|index("hitl")|not)) | "\(.number)\t\(.title)"'
```

- Exclude **`in-run-plan`** (belongs to an orchestrated run plan) and **`hitl`** (needs a human in the loop) — these labels may not exist yet; the filter is harmless if they don't.
- If the user named explicit issue numbers, use those instead — but still warn if any carry `in-run-plan`/`hitl`.

Present the candidate list and **confirm scope before dispatch**: which issues, and how many to run at once. Surface anything that looks interdependent (overlapping files / ordering language) as a reason to route to `to-run-plan` instead.

## 2. Dispatch one isolated agent per issue

Launch the agents **in a single message** (multiple Agent tool calls) so they run concurrently. Each MUST use `isolation: worktree` — without it, parallel agents collide in one working tree (a known past failure). Give each agent this brief:

> Work issue #N. Steps:
> 1. `gh issue view N` — read the full issue and acceptance criteria.
> 2. Branch off fresh `origin/main`: `git fetch origin && git checkout -b <type>/N-<slug> origin/main`. Confirm worktree + branch first.
> 3. Implement the smallest tracer-bullet vertical slice that satisfies the issue. Add regression tests.
> 4. Run the full local gate: `mix precommit` (compile --warnings-as-errors, deps.unlock --unused, format, test). This repo has no CI, so the local gate is the whole gate. Fix everything red.
> 5. Push once. Open a PR with `Closes #N` (repeat `Closes` per issue if it closes several). **No** `Co-Authored-By` / "Generated with" trailer.
> 6. Trigger review: comment `@coderabbitai review` (auto-review is off repo-wide). Babysit to green — address each comment or skip with justification, reply in-thread, resolve.
> 7. **Do not merge.** Report back: issue #, branch, PR URL, review status, and any blocker or major decision that needs David.

## 3. Collect and report

Gather the agents' results into a table for review:

| Issue | PR | Review | Notes / blockers |
|-------|----|--------|------------------|

Flag any agent that hit a **major decision** (architectural/scope/risky) or a blocker (env, permissions, harness gate) — don't paper over a partial result as success.

## 4. Hand off the merges (do not self-merge)

The harness denies `gh pr merge` to protected `main` even with verbal OK. Drive each PR to merge-ready, then hand David the squash commands for the ones he approves:

```bash
gh pr merge <n> --squash --delete-branch
```

Squash-only into `main` (David's convention); `--delete-branch` because this repo does not auto-delete on merge.

## Notes

- One push per branch per batch to save cycles; a push dismisses CodeRabbit approvals, so re-trigger `@coderabbitai review` after pushes.
- Keep trivial PRs as draft + untriggered.
- If the candidate set is empty, say so plainly rather than inventing work.
