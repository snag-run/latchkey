defmodule Latchkey.Simulation.Seeder.Scenario do
  @moduledoc """
  One entry in the seed **scenario catalogue** (ADR 0005 decision 9 / ADR 0007) — a
  tenancy engineered to sit at a chosen, legible arrears/exit state **today**.

  A scenario is pure data: it names an archetype
  (`Latchkey.Simulation.Behaviour.Profile`), a backdated commence date, how many
  payment periods the tenant engages with, and any **planted agent events** (a
  termination `notice` and/or an `exit`/keys-return the human agent would have
  recorded). `Latchkey.Simulation.Seeder` replays it through the *live* command →
  read-model seam so the seeded output is identical to what the live loop would have
  produced.

  ## `expected` is derived, not authored

  `:expected` is the intended as-of-today read-model state
  (`%{status, oldest_unpaid_due_date, days_behind, balance_cents}`), asserted
  post-seed. It is **computed** by `Latchkey.Simulation.Seeder.Projection` — which
  folds the scenario's own reconstructed events through the *real* `Tenancy` domain —
  rather than hand-authored, so a scenario's stated state can never silently drift
  from what the domain actually produces. A scenario is built with `expected: nil`;
  the catalogue fills it.

  ## Fields

    * `:label` — the catalogue name (stable, human-legible).
    * `:tenancy_id` — the base id slug; `Seeder` may prefix it (test isolation).
    * `:property_ref` — the non-PII, stable, opaque property id carried on
      `TenancyCommenced` (ADR 0008). Unique per tenancy for the 1:1 majority; a
      **shared** ref across a re-let pair (a new tenancy on the same premises), which
      is how the address recurs while the tenants differ.
    * `:rent_amount_cents` — the weekly rent.
    * `:first_due_date` — the backdated commencement / first due date (drives accrual).
    * `:profile` — the tenant behaviour archetype (+ any scripted overrides) the
      engine folds over the payment schedule.
    * `:schedule_count` — how many weekly periods the payment schedule spans.
    * `:notice` — `nil`, or a planted `%{given_on, termination_date, as_of}` the agent
      issues at a historical date (a `GiveTerminationNotice`).
    * `:exit` — `nil`, or a planted `%{keys_on}` the agent records once the tenancy is
      ending (a `ReturnKeys`, settling the tenancy to `:terminal`).
    * `:expected` — the derived as-of-today read-model state (filled by the catalogue).
  """

  alias Latchkey.Simulation.Behaviour.Profile

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
            profile: nil,
            schedule_count: nil,
            notice: nil,
            exit: nil,
            expected: nil

  @type notice :: %{given_on: Date.t(), termination_date: Date.t(), as_of: Date.t()}

  @type exit_step :: %{keys_on: Date.t()}

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
          profile: Profile.t(),
          schedule_count: pos_integer(),
          notice: notice() | nil,
          exit: exit_step() | nil,
          expected: expected() | nil
        }
end
