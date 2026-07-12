defmodule Latchkey.Simulation.Schedule do
  @moduledoc """
  A tenant's **payment schedule** — the pure, infrastructure-free input the
  behaviour engine reasons over (issue #43 / ADR 0005 decision 8). It is a list of
  rent **periods**, each with a due date and the amount owed, plus the `holder`
  (`tenancy_ref`) the resulting payments are attributed to.

  This is a *simulation* artefact, not a domain read model: it mirrors the weekly
  cadence the `Tenancy` aggregate accrues (`first_due_date`, `+7` days, one whole
  period per due date — `domain-model.md` §6/§7) so seeded history is byte-identical
  to what the live sweep + engine would produce, but it stays a plain struct so the
  engine can be unit-tested with zero infrastructure.

  A **period** is a plain map `%{index: non_neg_integer, due_on: Date.t(),
  amount_cents: pos_integer}`. `index` is a stable 0-based ordinal used both to key
  scripted per-period overrides and to derive a deterministic `payment_id`.
  """

  @enforce_keys [:holder]
  defstruct holder: nil, periods: []

  @type period :: %{index: non_neg_integer(), due_on: Date.t(), amount_cents: pos_integer()}
  @type t :: %__MODULE__{holder: String.t(), periods: [period()]}

  @week_days 7

  @doc """
  Build a weekly schedule for `holder`, one period per week starting at
  `first_due_date`, each owing `amount_cents`, for `count` periods.

  The cadence (`+7` days, whole-period amounts) matches the aggregate's weekly
  accrual, so the payments the engine emits over this schedule line up with the
  `RentFellDue` charges the tenancy books.
  """
  @spec weekly(String.t(), Date.t(), pos_integer(), pos_integer()) :: t()
  def weekly(holder, %Date{} = first_due_date, amount_cents, count)
      when is_binary(holder) and is_integer(amount_cents) and amount_cents > 0 and
             is_integer(count) and count > 0 do
    periods =
      for index <- 0..(count - 1) do
        %{
          index: index,
          due_on: Date.add(first_due_date, index * @week_days),
          amount_cents: amount_cents
        }
      end

    %__MODULE__{holder: holder, periods: periods}
  end
end
