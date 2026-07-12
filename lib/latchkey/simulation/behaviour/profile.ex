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
  """
  @spec deteriorating(keyword()) :: t()
  def deteriorating(opts \\ []) do
    %Profile{
      archetype: :deteriorating,
      grace_periods: Keyword.get(opts, :grace_periods, 2),
      step_days: Keyword.get(opts, :step_days, 2),
      period_length_days: Keyword.get(opts, :period_length_days, 7)
    }
  end

  @doc """
  A seeded, reproducible tenant: whether each period is paid, and how late, is
  derived deterministically from `:seed` (default `0`) and the period index — so the
  same seed always yields the same lateness sequence. Options: `:seed`,
  `:pay_probability` (default `0.6`), `:max_late_days` (default `5`).
  """
  @spec sporadic(keyword()) :: t()
  def sporadic(opts \\ []) do
    %Profile{
      archetype: :sporadic,
      seed: Keyword.get(opts, :seed, 0),
      pay_probability: Keyword.get(opts, :pay_probability, 0.6),
      max_late_days: Keyword.get(opts, :max_late_days, 5)
    }
  end

  @doc """
  Script an exact `action` for the period at `index`, overriding the archetype rule
  for that period only. Later calls for the same index replace the earlier action.
  """
  @spec with_override(t(), non_neg_integer(), override()) :: t()
  def with_override(%Profile{overrides: overrides} = profile, index, action)
      when is_integer(index) and index >= 0 do
    %Profile{profile | overrides: Map.put(overrides, index, action)}
  end
end
