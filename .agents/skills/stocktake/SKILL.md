---
name: stocktake
description: Read-only status snapshot of every feature/initiative as it moves through the funnel — captured idea → why-grilled (PRD) → how-grilled (ADRs) → sliced to issues → in run plan → in flight (PRs) → completed. Cross-references docs/prd, docs/adr, issue-tracker labels, and open/merged PRs, and recommends the next action (which skill to run) per feature. Use when the user asks "where do things stand", "stocktake", "feature status", "what's in flight", or wants to see the whole pipeline at a glance. Does NOT mutate anything.
---

# Stocktake — pipeline status across the funnel

Produce a single read-only snapshot of where every initiative sits in the latchkey delivery funnel, and what the next action is. **Never mutate** — no edits, label changes, issue/PR creation, or pushes. This is a reporting skill.

## The funnel and its signals

Each stage is detected from an artifact that already exists. The **PRD is the spine** once features reach it — most keyed by their `docs/prd/<name>.md`. Latchkey today leans on `docs/adr/`, `docs/domain-model.md`, and `docs/context-map.md`; some funnel labels/docs below don't exist yet and will read empty until the pipeline creates them.

| Stage | Detect from |
|-------|-------------|
| 1. Captured (not committed) | entries in `docs/future-directions.md` (if present); open issues labeled `proposed` |
| 2. Why-grilled → PRD exists | a file in `docs/prd/` (output of `grill-why` / `to-prd`) |
| 3. How-grilled | PRD has implementation sections filled + linked ADRs in `docs/adr/`; also the shared `docs/domain-model.md` / `docs/context-map.md` (output of `grill-with-prd` / `grill-with-docs`) |
| 4. Sliced to issues | open issues labeled `ready-for-agent` (grabbable / ready for an agent), referencing the PRD or ADR |
| 5. In run plan | issues labeled `in-run-plan` (a run plan = the current set of `in-run-plan` issues; there is no run-plan file) |
| 6. In flight | open PRs referencing those issues (`gh pr list`) |
| 7. Completed | closed issues + merged PRs; corroborate against `CHANGELOG.md` / `docs/ROADMAP.md` if present |

`hitl` on any issue = blocked on a human decision/design/review — call it out separately.

## 1. Gather signals (all read-only)

```bash
# PRDs, ADRs, and the shared model docs
ls docs/prd/ docs/adr/ 2>/dev/null; ls docs/domain-model.md docs/context-map.md 2>/dev/null
# Funnel labels — counts and the issues behind them (labels that don't exist just return empty)
for L in proposed ready-for-agent in-run-plan hitl; do
  echo "== $L =="; gh issue list --state open --label "$L" --limit 500 --json number,title --jq '.[] | "  #\(.number) \(.title)"'
done
# Open PRs in flight — keep `body` so the "Closes #N" links stay available for PR→issue mapping
gh pr list --state open --limit 200 --json number,title,headRefName,isDraft,statusCheckRollup,body \
  --jq '.[] | "#\(.number) [\(if .isDraft then "draft" else "ready" end)] \(.title)"'
# Recently completed
gh pr list --state merged --limit 100 --json number,title,mergedAt --jq '.[] | "#\(.number) \(.title)"'
```

Read each `docs/prd/*.md` enough to know its name, the feature it covers, and whether it has implementation/ADR sections filled (stage 2 vs 3). Map issues to a PRD/ADR via their body references or shared naming. Don't deep-read every issue — titles + labels are usually enough.

## 2. Produce the snapshot

A table per initiative, ordered roughly by funnel stage (most-advanced first):

| Initiative | Stage | PRD | ADRs | Issues (open / closed) | PRs | Blockers | Next action |
|-----------|-------|-----|------|------------------------|-----|----------|-------------|

Then two short lists:

- **Pre-funnel ideas** — `proposed` issues + `docs/future-directions.md` entries not yet committed.
- **Needs a human (`hitl`)** — what's waiting on David and for what decision.

## 3. Recommend the next action (point at the skill that advances it)

For each initiative, the next move follows from its stage — name the actual skill:

- Idea captured, no PRD → **`grill-why`** (build the why + PRD).
- PRD exists but thin on the how / no ADRs → **`grill-with-prd`** (stress-test the design, write ADRs).
- PRD solid, no `ready-for-agent` issues → **`to-issues`** (slice into grabbable issues).
- Issues exist, independent → **`kickoff-afk`**; interdependent → **`to-run-plan`**.
- PRs open and green → hand off the squash-merge (see **`ship-pr`**).
- All issues closed / PRs merged → reconcile `docs/ROADMAP.md` / `CHANGELOG.md` (if present) so the roadmap reflects reality.

## Notes

- Keep it a snapshot, not an audit — if a mapping is ambiguous (issue ↔ PRD), say so rather than guessing.
- Flag drift: a PRD with no issues, an `in-run-plan` issue with no open PR and no recent activity, or a merged feature still shown as pending in `ROADMAP.md`.
- This skill reports; it never advances the funnel itself. The operator chooses which recommended skill to run next.
