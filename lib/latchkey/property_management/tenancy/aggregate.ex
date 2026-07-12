defmodule Latchkey.PropertyManagement.Tenancy.Aggregate do
  @moduledoc """
  Commanded shell for the `Tenancy` aggregate. Commanded replays `apply/2` over the
  stream before every `execute/2`, so decisions always see folded state — that
  structural guarantee is why we chose raw Commanded (ADR 0003).

  All domain logic lives in `Latchkey.PropertyManagement.Tenancy` (framework-free);
  this module only adapts command structs → core, core events → event structs, and
  event structs → core (coercing the strings the JSON serializer returns on replay).

  It is also the **live dispatch edge** for the bitemporal envelope: `decide_*`
  stay pure and receive `recorded_on`; this shell reads `Latchkey.Clock.today()`
  (Sydney, ADR 0005 decision 2) when a command leaves `recorded_on` nil, and threads
  it in. `occurred_on` (the per-kind real-world date) is carried on the commands.
  """
  alias Latchkey.Clock
  alias Latchkey.PropertyManagement.Tenancy
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C
  alias Latchkey.PropertyManagement.Tenancy.Events, as: E

  defstruct core: Latchkey.PropertyManagement.Tenancy.initial_state()

  # ── execute (decide) ────────────────────────────────────────────────────────

  def execute(%__MODULE__{core: core}, %C.CommenceTenancy{} = c) do
    cmd = %{
      tenancy_id: c.tenancy_id,
      rent_amount_cents: c.rent_amount_cents,
      cycle: c.cycle,
      first_due_date: c.first_due_date,
      recorded_on: booked_on(c)
    }

    emit(Tenancy.decide_commence(core, cmd), c.tenancy_id)
  end

  def execute(%__MODULE__{core: core}, %C.RecordPayment{} = c) do
    cmd = %{
      tenancy_id: c.tenancy_id,
      amount_cents: c.amount_cents,
      received_on: c.received_on,
      source_payment_id: c.source_payment_id,
      recorded_on: booked_on(c)
    }

    emit(Tenancy.decide_payment(core, cmd), c.tenancy_id)
  end

  def execute(%__MODULE__{core: core}, %C.CatchUp{} = c) do
    emit(
      Tenancy.decide_catch_up(core, %{as_of: c.as_of, recorded_on: booked_on(c)}),
      c.tenancy_id
    )
  end

  def execute(%__MODULE__{core: core}, %C.GiveTerminationNotice{} = c) do
    cmd = %{
      tenancy_id: c.tenancy_id,
      termination_date: c.termination_date,
      given_on: c.given_on,
      as_of: c.as_of,
      recorded_on: booked_on(c)
    }

    emit(Tenancy.decide_termination(core, cmd), c.tenancy_id)
  end

  # ── apply (fold) ────────────────────────────────────────────────────────────

  def apply(%__MODULE__{core: core} = agg, event) do
    %{agg | core: Tenancy.evolve(core, to_normalized(event))}
  end

  # ── adapters ────────────────────────────────────────────────────────────────

  # The single live wall-clock read-site: the domain stays pure and threads the
  # booking date; the edge sources it from the Clock when the caller omits it.
  defp booked_on(%{recorded_on: %Date{} = d}), do: d
  defp booked_on(%{recorded_on: nil}), do: Clock.today()

  defp booked_on(c),
    do: raise(ArgumentError, "invalid recorded_on: #{inspect(c.recorded_on)}")

  defp emit({:error, reason}, _tid), do: {:error, reason}
  defp emit({:ok, events}, tid), do: Enum.map(events, &to_struct(&1, tid))

  defp to_struct(%{type: :tenancy_commenced} = e, _tid) do
    %E.TenancyCommenced{
      tenancy_id: e.tenancy_id,
      occurred_on: e.occurred_on,
      recorded_on: e.recorded_on,
      rent_amount_cents: e.rent_amount_cents,
      cycle: e.cycle,
      first_due_date: e.first_due_date
    }
  end

  defp to_struct(%{type: :rent_fell_due} = e, tid) do
    %E.RentFellDue{
      tenancy_id: tid,
      occurred_on: e.occurred_on,
      recorded_on: e.recorded_on,
      amount_cents: e.amount_cents
    }
  end

  defp to_struct(%{type: :rent_payment_recorded} = e, tid) do
    %E.RentPaymentRecorded{
      tenancy_id: tid,
      occurred_on: e.occurred_on,
      recorded_on: e.recorded_on,
      amount_cents: e.amount_cents,
      source_payment_id: e.source_payment_id
    }
  end

  defp to_struct(%{type: :termination_notice_given} = e, tid) do
    %E.TerminationNoticeGiven{
      tenancy_id: tid,
      occurred_on: e.occurred_on,
      recorded_on: e.recorded_on,
      grounds: e.grounds,
      termination_date: e.termination_date
    }
  end

  # JSON rehydration returns strings for atoms/Dates on replay — coerce back.
  defp to_normalized(%E.TenancyCommenced{} = e) do
    %{
      type: :tenancy_commenced,
      tenancy_id: e.tenancy_id,
      occurred_on: to_date(e.occurred_on),
      recorded_on: to_date(e.recorded_on),
      rent_amount_cents: e.rent_amount_cents,
      cycle: decode_cycle(e.cycle),
      first_due_date: to_date(e.first_due_date)
    }
  end

  defp to_normalized(%E.RentFellDue{} = e) do
    %{
      type: :rent_fell_due,
      occurred_on: to_date(e.occurred_on),
      recorded_on: to_date(e.recorded_on),
      amount_cents: e.amount_cents
    }
  end

  defp to_normalized(%E.RentPaymentRecorded{} = e) do
    %{
      type: :rent_payment_recorded,
      occurred_on: to_date(e.occurred_on),
      recorded_on: to_date(e.recorded_on),
      amount_cents: e.amount_cents,
      source_payment_id: e.source_payment_id
    }
  end

  defp to_normalized(%E.TerminationNoticeGiven{} = e) do
    %{
      type: :termination_notice_given,
      occurred_on: to_date(e.occurred_on),
      recorded_on: to_date(e.recorded_on),
      grounds: decode_grounds(e.grounds),
      termination_date: to_date(e.termination_date)
    }
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)

  # Decode the fixed vocabularies explicitly — no dynamic atom conversion of
  # persisted strings. Unknown values crash the replay loudly rather than silently.
  defp decode_cycle(c) when c in [:weekly, "weekly"], do: :weekly
  defp decode_grounds(g) when g in [:arrears, "arrears"], do: :arrears
end
