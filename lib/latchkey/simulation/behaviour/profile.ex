defmodule Latchkey.Simulation.Behaviour.Profile do
  @moduledoc """
  A **tenant archetype** — the deterministic parameters that decide how a simulated
  tenant pays (issue #43 / ADR 0005 decision 8). A profile is pure data; the
  `Latchkey.Simulation.Behaviour` engine folds it over a
  `Latchkey.Simulation.Schedule` to produce `PaymentReceived` facts.

  Four archetypes, expressed as parameterised rules:

    * `:reliable` — pays the full amount on every due date.
    * `:chronically_late` — pays the full amount every period, always `late_by_days`
      days after the due date.
    * `:deteriorating` — pays on time for `grace_periods`, then slips `step_days`
      later each successive period until the lateness reaches a whole period
      (`period_length_days`), at which point it falls behind and misses.
    * `:sporadic` — a **seeded** (reproducible) tenant: each period is paid or
      missed and, when paid, jittered late by up to `max_late_days`, all derived
      deterministically from `seed` + the period index.

  On top of the archetype rule, **scripted per-period overrides** (`overrides`) let a
  seed author force an exact action on a given period index — e.g. a
  *miss-then-double-pay*: miss period 0, then pay `2×` on period 1. Overrides are
  never reactive; they are authored up front (`with_override/3`).
  """

  alias __MODULE__

  defstruct archetype: :reliable,
            late_by_days: 0,
            grace_periods: 2,
            step_days: 2,
            period_length_days: 7,
            seed: 0,
            pay_probability: 0.6,
            max_late_days: 5,
            overrides: %{}

  @typedoc """
  A scripted action forced on a period, overriding the archetype rule:

    * `:miss` — the tenant pays nothing for this period.
    * `{:pay, opts}` — the tenant pays. `opts` accepts `:amount_cents` (defaults to
      the period's own amount) and `:offset` days late (defaults to `0`, i.e. on the
      due date).
  """
  @type override :: :miss | {:pay, keyword()}

  @type archetype :: :reliable | :chronically_late | :deteriorating | :sporadic

  @type t :: %__MODULE__{
          archetype: archetype(),
          late_by_days: non_neg_integer(),
          grace_periods: non_neg_integer(),
          step_days: non_neg_integer(),
          period_length_days: pos_integer(),
          seed: integer(),
          pay_probability: float(),
          max_late_days: non_neg_integer(),
          overrides: %{optional(non_neg_integer()) => override()}
        }

  @doc "Pays the full amount on every due date."
  @spec reliable() :: t()
  def reliable, do: %Profile{archetype: :reliable}

  @doc """
  Pays the full amount every period, always `days` days after the due date
  (`chronically-late(+N)`).
  """
  @spec chronically_late(non_neg_integer()) :: t()
  def chronically_late(days) when is_integer(days) and days >= 0 do
    %Profile{archetype: :chronically_late, late_by_days: days}
  end

  @doc """
  A tenant who starts well then slides. Pays on time for `:grace_periods`, then each
  subsequent period `:step_days` later than the previous, until the accumulated
  lateness reaches a whole `:period_length_days` and the tenant falls behind and
  misses every period thereafter. All options are optional.

  Raises `ArgumentError` on contract-violating options: `:grace_periods` and
  `:step_days` must be non-negative integers and `:period_length_days` a positive
  integer (a non-positive period makes every payment either instantly a whole period
  behind or the decline never terminating; a negative `:step_days` would pay before
  the due date).
  """
  @spec deteriorating(keyword()) :: t()
  def deteriorating(opts \\ []) do
    grace_periods = Keyword.get(opts, :grace_periods, 2)
    step_days = Keyword.get(opts, :step_days, 2)
    period_length_days = Keyword.get(opts, :period_length_days, 7)

    validate_non_neg_int!(:grace_periods, grace_periods)
    validate_non_neg_int!(:step_days, step_days)
    validate_pos_int!(:period_length_days, period_length_days)

    %Profile{
      archetype: :deteriorating,
      grace_periods: grace_periods,
      step_days: step_days,
      period_length_days: period_length_days
    }
  end

  @doc """
  A seeded, reproducible tenant: whether each period is paid, and how late, is
  derived deterministically from `:seed` (default `0`) and the period index — so the
  same seed always yields the same lateness sequence. Options: `:seed`,
  `:pay_probability` (default `0.6`), `:max_late_days` (default `5`).

  Raises `ArgumentError` on contract-violating options: `:seed` must be an integer,
  `:pay_probability` a number in `0.0..1.0` (values outside collapse the archetype to
  always-pay or never-pay), and `:max_late_days` a non-negative integer.
  """
  @spec sporadic(keyword()) :: t()
  def sporadic(opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)
    pay_probability = Keyword.get(opts, :pay_probability, 0.6)
    max_late_days = Keyword.get(opts, :max_late_days, 5)

    validate_integer!(:seed, seed)
    validate_probability!(:pay_probability, pay_probability)
    validate_non_neg_int!(:max_late_days, max_late_days)

    %Profile{
      archetype: :sporadic,
      seed: seed,
      pay_probability: pay_probability,
      max_late_days: max_late_days
    }
  end

  @doc """
  Script an exact `action` for the period at `index`, overriding the archetype rule
  for that period only. Later calls for the same index replace the earlier action.

  Raises `ArgumentError` on a contract-violating action: a `{:pay, opts}` action's
  `:amount_cents` (when given) must be positive — `Accounts.payment_received/1`
  rejects zero/negative amounts downstream — and its `:offset` (when given) must be
  non-negative, since a payment cannot be received before its due date.
  """
  @spec with_override(t(), non_neg_integer(), override()) :: t()
  def with_override(%Profile{overrides: overrides} = profile, index, action)
      when is_integer(index) and index >= 0 do
    validate_override!(action)
    %Profile{profile | overrides: Map.put(overrides, index, action)}
  end

  # ── option validation (raise ArgumentError at the construction boundary) ──────

  defp validate_override!(:miss), do: :ok

  defp validate_override!({:pay, opts}) when is_list(opts) do
    amount_cents = Keyword.get(opts, :amount_cents)
    if amount_cents != nil, do: validate_pos_int!(:amount_cents, amount_cents)

    offset = Keyword.get(opts, :offset)
    if offset != nil, do: validate_non_neg_int!(:offset, offset)

    :ok
  end

  defp validate_override!(action) do
    raise ArgumentError,
          "override action must be :miss or {:pay, opts}, got: #{inspect(action)}"
  end

  defp validate_integer!(_name, value) when is_integer(value), do: :ok

  defp validate_integer!(name, value) do
    raise ArgumentError, "#{name} must be an integer, got: #{inspect(value)}"
  end

  defp validate_non_neg_int!(_name, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_neg_int!(name, value) do
    raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp validate_pos_int!(_name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_pos_int!(name, value) do
    raise ArgumentError, "#{name} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_probability!(_name, value)
       when is_number(value) and value >= 0.0 and value <= 1.0,
       do: :ok

  defp validate_probability!(name, value) do
    raise ArgumentError, "#{name} must be a number in 0.0..1.0, got: #{inspect(value)}"
  end
end
