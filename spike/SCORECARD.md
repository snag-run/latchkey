# ES bake-off — scorecard

Both spikes implement the identical slice (`README.md`) over the **same** shared
decision core (`lib/spike/tenancy_core.ex`, 188 LOC). So every difference below is
*plumbing*, not domain — the domain logic is framework-independent (finding #0).

Both **pass the discriminating test**: the L7 arrears gate refuses under 14 days
and accepts at/over, reading the **fold** — the thing AshCommanded structurally
could not do (ADR 0002). So this is not a correctness bake-off; it's a *fit* one.

| # | dimension | Spike A — raw Commanded | Spike B — pure Ash | edge |
|---|---|---|---|---|
| 1 | **Fold-as-truth** | **Structural.** `execute/2` cannot run without Commanded first replaying `apply/2` — you *cannot* decide off unfolded state | **Disciplined.** the gate reads the fold because `run/4` loads→folds→decides; nothing stops a future action appending without folding | **A** |
| 2 | **Invariant expression** | L2/L3/L7 live in `execute/2`, pure & obvious | identical (shared core) — but reached through hand plumbing | tie |
| 3 | **Concurrency** | expected-version per stream, **built in** | hand-rolled: unique `(stream_id, sequence)` identity → `:concurrency_conflict` | **A** |
| 4 | **Projection / read model** | subscriptions + `consistency: :strong`, replay from `:origin`, **free async** | synchronous upsert inside the command; async would be hand-rolled | **A** |
| 5 | **ACL / saga fit** (§8, §10) | process managers / Reactor — first-class for ACL-1/2 + sagas | hand-rolled coordination (Ash has no native PM) | **A** |
| 6 | **Ceremony / footprint** | 13 files, **3 deps**, a **second Postgres DB** with its own create/init/migrate lifecycle | **4 files, 0 new deps, 1 migration** in the existing DB | **B** |
| 7 | **Testability** | aggregate is pure `execute`/`apply` — **4 tests, 0.01s, no DB** | needs the Postgres sandbox — 5 tests, 0.09s | **A** |
| 8 | **Learning value** | storage is a black box (event store hidden) — less "feel the mechanics" | you see the log table, `sequence`, fold, append — **mechanics visible** | **B** |

LOC is a wash (A 250 / B 254) — the cost isn't lines, it's **moving parts**:
A spreads across a second database + 3 deps + 13 files; B is 4 files in one DB.

## Reading

- **Commanded (A)** encodes the project's *thesis* (fold-as-truth) as **structure,
  not discipline**, hands you the **seam** (§8 ACLs, §10 sagas) via process managers
  for free, and makes the aggregate **purely unit-testable**. Cost: real infra weight
  (second DB, deps, ceremony) and hidden storage.
- **Pure Ash (B)** is featherweight and stays in **one DB + one idiom** you already
  know, with the **raw mechanics visible** (good for learning). Cost: you hand-roll
  concurrency, async projections, and — most significantly — the **ACL/saga
  coordination** that is the heart of this project, and fold-as-truth rests on
  discipline rather than structure.

The decisive axis is the **seam**: the whole project is "the payments seam" (two
ACLs + sagas). Commanded gives that structurally; Ash makes you build it. That is
why ADR 0002 already *leaned* Option 1 — the spike backs the lean, but see the open
questions in ADR 0003 before committing.
