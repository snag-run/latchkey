defmodule Latchkey.Simulation.Seeder.Scenario do
  @moduledoc """
  One entry in the seed **scenario catalogue** (ADR 0005 decision 9 / issue #44) — a
  named tenancy engineered to sit at a chosen, legible arrears/exit state **today**.

  A scenario is pure data: it names an archetype
  (`Latchkey.Simulation.Behaviour.Profile`), a backdated commence date, how many
  payment periods the tenant engages with, and any **planted agent event** (a
  termination notice the human agent would have issued). `Latchkey.Simulation.Seeder`
  replays it through the *live* command → read-model seam so the seeded output is
  identical to what the live loop would have produced.

  ## Fields

    * `:label` — the catalogue name (`"paid-up"`, `"20-days-behind-no-notice"`,
      `"notice-issued-then-tenant-paid"`). Stable, human-legible.
    * `:tenancy_id` — the base id slug; `Seeder` may prefix it (test isolation).
    * `:rent_amount_cents` — the weekly rent.
    * `:first_due_date` — the backdated commencement / first due date (drives accrual).
    * `:profile` — the tenant behaviour archetype (+ any scripted overrides) the
      engine folds over the payment schedule.
    * `:schedule_count` — how many weekly periods the payment schedule spans (the
      periods the engine may pay; unpaid periods surface as arrears via the sweep).
    * `:notice` — `nil`, or a planted `%{given_on, termination_date, as_of}` the agent
      issues at a historical date (a `GiveTerminationNotice`).
    * `:expected` — the intended as-of-today read-model state, asserted post-seed:
      `%{status, oldest_unpaid_due_date, days_behind, balance_cents}`.
  """

  alias Latchkey.Simulation.Behaviour.Profile

  @enforce_keys [
    :label,
    :tenancy_id,
    :rent_amount_cents,
    :first_due_date,
    :profile,
    :schedule_count,
    :expected
  ]
  defstruct label: nil,
            tenancy_id: nil,
            rent_amount_cents: nil,
            first_due_date: nil,
            profile: nil,
            schedule_count: nil,
            notice: nil,
            expected: nil

  @type notice :: %{given_on: Date.t(), termination_date: Date.t(), as_of: Date.t()}

  @type expected :: %{
          status: :active | :ending | :terminal,
          oldest_unpaid_due_date: Date.t() | nil,
          days_behind: non_neg_integer(),
          balance_cents: integer()
        }

  @type t :: %__MODULE__{
          label: String.t(),
          tenancy_id: String.t(),
          rent_amount_cents: pos_integer(),
          first_due_date: Date.t(),
          profile: Profile.t(),
          schedule_count: pos_integer(),
          notice: notice() | nil,
          expected: expected()
        }
end
