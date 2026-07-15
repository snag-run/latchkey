defmodule Latchkey.Simulation.WorldLine.Agent do
  @moduledoc """
  A **simulated agent archetype** — the deterministic parameters that decide how the
  property manager reacts to a tenant's arrears (ADR 0011, un-defers ADR 0005 §10 for
  the agent side). Pure data; `Latchkey.Simulation.WorldLine` folds it over the
  computed arrears trajectory to *derive* the notice and vacate dates, rather than
  reading live state at run time.

  ## Archetype = a notice threshold

  The archetype is a single knob — the `days_behind` at which the agent serves a
  termination notice on arrears grounds (spec / ADR 0011). Two for v1:

    * `:strict` — notice the day `days_behind` crosses the L7 eligibility gate
      (`#{14}` days behind).
    * `:lenient` — notice at `#{30}` days behind.

  A tenant who never crosses their agent's threshold is never noticed — a reliable or
  a chronically-late-but-current tenant never exits.

  ## `overstay_days` rides alongside

  `overstay_days` is *not* an agent knob — it's the **tenant's** deterministic
  hold-over offset, carried here because it parameterises the same derived exit the
  agent's notice sets in motion: the vacate date is `V = E + overstay`, where
  `E = notice_date + 14` (s88 statutory minimum). `0` is a compliant departer (vacates
  at `E`); a seeded-positive offset is an arrears hold-over (`V ≥ E`), which the
  aggregate's overstay charge then bites (exit-settlement spec).
  """

  alias __MODULE__

  @strict_threshold_days 14
  @lenient_threshold_days 30

  defstruct archetype: :strict, threshold_days: @strict_threshold_days, overstay_days: 0

  @type archetype :: :strict | :lenient

  @type t :: %__MODULE__{
          archetype: archetype(),
          threshold_days: pos_integer(),
          overstay_days: non_neg_integer()
        }

  @doc """
  A strict agent: notices the day `days_behind` crosses the L7 gate (14). `overstay_days`
  (default `0`) is the tenant's hold-over offset past the termination date `E`.
  """
  @spec strict(non_neg_integer()) :: t()
  def strict(overstay_days \\ 0), do: build(:strict, @strict_threshold_days, overstay_days)

  @doc """
  A lenient agent: notices at 30 days behind. `overstay_days` (default `0`) is the
  tenant's hold-over offset past the termination date `E`.
  """
  @spec lenient(non_neg_integer()) :: t()
  def lenient(overstay_days \\ 0), do: build(:lenient, @lenient_threshold_days, overstay_days)

  defp build(archetype, threshold_days, overstay_days) do
    validate_non_neg_int!(:overstay_days, overstay_days)

    %Agent{archetype: archetype, threshold_days: threshold_days, overstay_days: overstay_days}
  end

  defp validate_non_neg_int!(_name, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_neg_int!(name, value) do
    raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
  end
end
