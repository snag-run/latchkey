defmodule Latchkey.Simulation.Seeder.Scenario do
  @moduledoc """
  One entry in the seed **scenario catalogue** (ADR 0005 decision 9 / ADR 0007) — a
  tenancy engineered to sit at a chosen, legible arrears/exit state **today**.

  A scenario is pure data: it names a tenant archetype
  (`Latchkey.Simulation.Behaviour.Profile`), a backdated commence date, how many
  payment periods the tenant engages with, and an **agent archetype** (`:strict` /
  `:lenient`) plus a per-tenant `overstay_days`. Its agent events — a termination
  notice and the tenant's keys-return — are **derived**, not planted: the world-line
  (`Latchkey.Simulation.WorldLine`, ADR 0011) folds `(tenant archetype × agent
  archetype × commence date)` into the full dated event list, and
  `Latchkey.Simulation.Seeder` replays the `≤ today` slice through the *live* command →
  read-model seam so the seeded output is identical to what the live loop would have
  produced.

  ## `expected` is derived, not authored

  `:expected` is the intended as-of-today read-model state
  (`%{status, oldest_unpaid_due_date, days_behind, balance_cents}`), asserted
  post-seed. It is **computed** by `Latchkey.Simulation.Seeder.Projection` — which
  folds the scenario's own reconstructed events (payments + the derived notice/exit
  from the world-line's `≤ today` slice) through the *real* `Tenancy` domain — rather
  than hand-authored, so a scenario's stated state can never silently drift from what
  the domain actually produces. A scenario is built with `expected: nil`; the catalogue
  fills it.

  ## Fields

    * `:label` — the catalogue name (stable, human-legible).
    * `:tenancy_id` — the base id slug; `Seeder` may prefix it (test isolation).
    * `:property_ref` — the non-PII, stable, opaque property id carried on
      `TenancyCommenced` (ADR 0008). Unique per tenancy for the 1:1 majority; a
      **shared** ref across a re-let pair (a new tenancy on the same premises), which
      is how the address recurs while the tenants differ.
    * `:rent_amount_cents` — the **whole-period** rent for the tenancy's cadence (a
      monthly tenancy carries a monthly amount, a weekly one a weekly amount; ADR 0009
      decision 1 — never converted between cadences).
    * `:first_due_date` — the backdated commencement / first due date (drives accrual).
    * `:cycle` — the payment cadence (`:weekly` | `:fortnightly` | `:monthly`, ADR
      0009). Defaults to `:weekly`; the catalogue draws a 60/30/10 mix across the
      generated scenarios (featured headliners stay weekly).
    * `:profile` — the tenant behaviour archetype (+ any scripted overrides) the
      engine folds over the payment schedule.
    * `:schedule_count` — how many cadence periods the payment schedule spans. For a
      scenario whose agent reacts, this must span far enough for the world-line to
      *see* the arrears cross the agent's threshold (i.e. past the first unpaid period).
    * `:agent_archetype` — the simulated agent's notice threshold (`:strict` = notice
      at 14 days behind, `:lenient` = 30; `Latchkey.Simulation.WorldLine.Agent`). A
      tenant who never crosses it is never noticed.
    * `:overstay_days` — the tenant's deterministic hold-over offset past the
      termination date `E`; the derived vacate date is `V = E + overstay_days`. `0` is a
      compliant departer (vacates on `E`).
    * `:expected` — the derived as-of-today read-model state (filled by the catalogue).
  """

  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.WorldLine.Agent

  @enforce_keys [
    :label,
    :tenancy_id,
    :rent_amount_cents,
    :first_due_date,
    :profile,
    :schedule_count
  ]
  defstruct label: nil,
            tenancy_id: nil,
            property_ref: nil,
            rent_amount_cents: nil,
            first_due_date: nil,
            cycle: :weekly,
            profile: nil,
            schedule_count: nil,
            agent_archetype: :strict,
            overstay_days: 0,
            expected: nil

  @type expected :: %{
          status: :active | :ending | :terminal,
          oldest_unpaid_due_date: Date.t() | nil,
          days_behind: non_neg_integer(),
          balance_cents: integer()
        }

  @type t :: %__MODULE__{
          label: String.t(),
          tenancy_id: String.t(),
          # `nil` only in the transient pre-backfill state; `Catalogue.fill_property_ref/1`
          # assigns a stable ref to every scenario the catalogue emits.
          property_ref: String.t() | nil,
          rent_amount_cents: pos_integer(),
          first_due_date: Date.t(),
          cycle: :weekly | :fortnightly | :monthly,
          profile: Profile.t(),
          schedule_count: pos_integer(),
          agent_archetype: Agent.archetype(),
          overstay_days: non_neg_integer(),
          expected: expected() | nil
        }
end
