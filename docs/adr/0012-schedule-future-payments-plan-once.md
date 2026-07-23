# 0012 — Schedule future payments plan-once (reliable tenants keep paying)

Status: **accepted** — resolves issue #200. Amends
[ADR 0011](0011-ambient-world-simulation-simulated-agent.md) (the "freshness stays
with the reset-to-healthy model" consequence): future **payments** now join the
plan-once schedule alongside the derived agent actions. Determinism (ADR 0005
decision 8) and the pure tenant engine are preserved.

## Context

ADR 0011 scheduled only the derived **agent actions** (notice, vacate) at plan time
and left keeping reliable tenants paying to the reset-to-healthy re-anchor (issue
#92). That was insufficient. Rent accrues forever — the `@daily` sweep books
`RentFellDue` up to today for every non-terminal tenancy — but each tenancy paid only
over its finite `schedule_count` periods, and reliable/healthy schedules were sized to
end ~today *at seed time*. Once wall-clock passed that last period no payment was ever
emitted again, so every reliable tenant slid into ever-growing arrears a bounded time
after seeding. The reset could not save it: it is monthly, default-disabled
(`DEMO_RESET_ENABLED`), and too coarse for weekly/fortnightly payers even when it
fires.

## Decision

Extend the **plan-once** model to payments. Reliable/ongoing tenants' schedules run a
runway (~5 months, comfortably longer than the quarterly reset cadence) past today, and
the planner realizes each future `{:payment, _}` world-line step as a scheduled Oban
job — the same way it already schedules notice/vacate. A payment job fires **live**
through the Accounts edge (`Accounts.append/2`), where the payment ACL crosses it into
PM's `RentPaymentRecorded` asynchronously, exactly as any live payment.

The payment pattern still comes straight from the tenant archetype
(`Behaviour.payments/2`) — the planner only realizes what the archetype produces, so
this stays deterministic with no runtime decider. The reset-to-healthy re-anchor
re-extends the runway on each firing. **Silent/terminal scenarios are untouched** —
their finite schedule *is* how the arrears are modelled (the silence is the truncation).

## Idempotency

Payments are the one event kind that **recurs** per tenancy, so the plan-once
idempotency key changes from `{tenancy_id, event, generation}` to
`{tenancy_id, ref, generation}`, where `ref` is a stable per-occurrence world-line id:
the event name (`notice`/`vacate`) for the once-per-lifecycle agent actions, and the
stable per-period `payment_id` (`"<holder>-pmt-<index>"`) for a payment. This is the
extension point ADR 0011's planner already anticipated. PM state is idempotent under a
retry (the ACL/aggregate dedupe on `source_payment_id`); the raw Accounts stream is a
tolerated append-only source, so a crash between the append and the Oban ack can leave a
duplicate `PaymentReceived` fact that PM dedupes away.

## Consequences

- Reliable tenants stay square as wall-clock time advances, instead of drifting into
  arrears once the seeded schedule runs out.
- Existing stores clear their accrued backlog on the next reseed/reset (which re-anchors
  `first_due_date` to the new today); the fix keeps the board healthy going forward.
- The reset cadence (`@monthly` → quarterly) remains a separate `config.exs` decision;
  the runway is sized so a reliable tenant never runs dry before a quarterly reset.
- Still deferred (unchanged from ADR 0011): tenant curing after notice, perpetual
  re-letting.
