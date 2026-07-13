defmodule Latchkey.Simulation.Schedule do
  @moduledoc """
  A tenant's **payment schedule** — the pure, infrastructure-free input the
  behaviour engine reasons over (issue #43 / ADR 0005 decision 8). It is a list of
  rent **periods**, each with a due date and the amount owed, plus the `holder`
  (`tenancy_ref`) the resulting payments are attributed to.

  This is a *simulation* artefact, not a domain read model: it mirrors the cadence the
  `Tenancy` aggregate accrues (`first_due_date`, then the cadence's period — weekly
  `+7`, fortnightly `+14`, or a calendar month from the anchor — one whole period per
  due date, `domain-model.md` §6/§7, ADR 0009) so seeded history is byte-identical to
  what the live sweep + engine would produce, but it stays a plain struct so the engine
  can be unit-tested with zero infrastructure.

  A **period** is a plain map `%{index: non_neg_integer, due_on: Date.t(),
  amount_cents: pos_integer}`. `index` is a stable 0-based ordinal used both to key
  scripted per-period overrides and to derive a deterministic `payment_id`.
  """

  @enforce_keys [:holder]
  defstruct holder: nil, periods: []

  @type period :: %{index: non_neg_integer(), due_on: Date.t(), amount_cents: pos_integer()}
  @type t :: %__MODULE__{holder: String.t(), periods: [period()]}

  @week_days 7
  @fortnight_days 14

  @typedoc "The rent cadences the simulation seeds (ADR 0009)."
  @type cycle :: :weekly | :fortnightly | :monthly

  @doc """
  Build a schedule for `holder` on `cycle`, one period per cadence starting at
  `first_due_date`, each owing `amount_cents`, for `count` periods. Dispatches to the
  per-cadence builder so callers can stay cadence-agnostic (ADR 0009).
  """
  @spec for_cycle(cycle(), String.t(), Date.t(), pos_integer(), pos_integer()) :: t()
  def for_cycle(:weekly, holder, first_due_date, amount_cents, count),
    do: weekly(holder, first_due_date, amount_cents, count)

  def for_cycle(:fortnightly, holder, first_due_date, amount_cents, count),
    do: fortnightly(holder, first_due_date, amount_cents, count)

  def for_cycle(:monthly, holder, first_due_date, amount_cents, count),
    do: monthly(holder, first_due_date, amount_cents, count)

  @doc """
  Build a weekly schedule for `holder`, one period per week starting at
  `first_due_date`, each owing `amount_cents`, for `count` periods.

  The cadence (`+7` days, whole-period amounts) matches the aggregate's weekly
  accrual, so the payments the engine emits over this schedule line up with the
  `RentFellDue` charges the tenancy books.
  """
  @spec weekly(String.t(), Date.t(), pos_integer(), pos_integer()) :: t()
  def weekly(holder, %Date{} = first_due_date, amount_cents, count) do
    build(holder, amount_cents, count, fn index ->
      Date.add(first_due_date, index * @week_days)
    end)
  end

  @doc """
  Build a fortnightly schedule: same shape as `weekly/4` but a 14-day period, matching
  the aggregate's fortnightly accrual (ADR 0009 decision 2).
  """
  @spec fortnightly(String.t(), Date.t(), pos_integer(), pos_integer()) :: t()
  def fortnightly(holder, %Date{} = first_due_date, amount_cents, count) do
    build(holder, amount_cents, count, fn index ->
      Date.add(first_due_date, index * @fortnight_days)
    end)
  end

  @doc """
  Build a monthly schedule: each due date is the `first_due_date` day-of-month advanced
  **from the anchor** by `index` calendar months (`Date.shift(first_due_date, month:
  index)`), month-end clamped — never iterated off the previous due date. This matches
  the aggregate's monthly accrual (ADR 0009 decision 2), so a "due on the 31st" schedule
  reads Jan 31 → Feb 28 → Mar 31, and the period length is naturally 28–31 days.
  """
  @spec monthly(String.t(), Date.t(), pos_integer(), pos_integer()) :: t()
  def monthly(holder, %Date{} = first_due_date, amount_cents, count) do
    build(holder, amount_cents, count, fn index -> Date.shift(first_due_date, month: index) end)
  end

  # Shared builder: `count` periods indexed 0-based, each `amount_cents`, due on
  # `due_fun.(index)`. The per-cadence walk is the only thing that varies.
  defp build(holder, amount_cents, count, due_fun)
       when is_binary(holder) and is_integer(amount_cents) and amount_cents > 0 and
              is_integer(count) and count > 0 and is_function(due_fun, 1) do
    periods =
      for index <- 0..(count - 1) do
        %{index: index, due_on: due_fun.(index), amount_cents: amount_cents}
      end

    %__MODULE__{holder: holder, periods: periods}
  end
end
