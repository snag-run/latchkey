defmodule Latchkey.PropertyManagement.Tenancy.Aggregate do
  @moduledoc """
  Commanded shell for the `Tenancy` aggregate. Commanded replays `apply/2` over the
  stream before every `execute/2`, so decisions always see folded state — that
  structural guarantee is why we chose raw Commanded (ADR 0003).

  All domain logic lives in `Latchkey.PropertyManagement.Tenancy` (framework-free);
  this module only adapts command structs → core, core events → event structs, and
  event structs → core (coercing the strings the JSON serializer returns on replay).
  """
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
      first_due_date: c.first_due_date
    }

    emit(Tenancy.decide_commence(core, cmd), c.tenancy_id)
  end

  def execute(%__MODULE__{core: core}, %C.RecordPayment{} = c) do
    cmd = %{
      tenancy_id: c.tenancy_id,
      amount_cents: c.amount_cents,
      received_on: c.received_on,
      source_payment_id: c.source_payment_id
    }

    emit(Tenancy.decide_payment(core, cmd), c.tenancy_id)
  end

  def execute(%__MODULE__{core: core}, %C.CatchUp{} = c) do
    emit(Tenancy.decide_catch_up(core, %{as_of: c.as_of}), c.tenancy_id)
  end

  def execute(%__MODULE__{core: core}, %C.GiveTerminationNotice{} = c) do
    cmd = %{
      tenancy_id: c.tenancy_id,
      termination_date: c.termination_date,
      given_on: c.given_on,
      as_of: c.as_of
    }

    emit(Tenancy.decide_termination(core, cmd), c.tenancy_id)
  end

  # ── apply (fold) ────────────────────────────────────────────────────────────

  def apply(%__MODULE__{core: core} = agg, event) do
    %{agg | core: Tenancy.evolve(core, to_normalized(event))}
  end

  # ── adapters ────────────────────────────────────────────────────────────────

  defp emit({:error, reason}, _tid), do: {:error, reason}
  defp emit({:ok, events}, tid), do: Enum.map(events, &to_struct(&1, tid))

  defp to_struct(%{type: :tenancy_commenced} = e, _tid) do
    %E.TenancyCommenced{
      tenancy_id: e.tenancy_id,
      rent_amount_cents: e.rent_amount_cents,
      cycle: e.cycle,
      first_due_date: e.first_due_date
    }
  end

  defp to_struct(%{type: :rent_fell_due} = e, tid) do
    %E.RentFellDue{tenancy_id: tid, due_date: e.due_date, amount_cents: e.amount_cents}
  end

  defp to_struct(%{type: :rent_payment_recorded} = e, tid) do
    %E.RentPaymentRecorded{
      tenancy_id: tid,
      amount_cents: e.amount_cents,
      received_on: e.received_on,
      source_payment_id: e.source_payment_id
    }
  end

  defp to_struct(%{type: :termination_notice_given} = e, tid) do
    %E.TerminationNoticeGiven{
      tenancy_id: tid,
      grounds: e.grounds,
      termination_date: e.termination_date,
      given_on: e.given_on
    }
  end

  # JSON rehydration returns strings for atoms/Dates on replay — coerce back.
  defp to_normalized(%E.TenancyCommenced{} = e) do
    %{
      type: :tenancy_commenced,
      tenancy_id: e.tenancy_id,
      rent_amount_cents: e.rent_amount_cents,
      cycle: to_atom(e.cycle),
      first_due_date: to_date(e.first_due_date)
    }
  end

  defp to_normalized(%E.RentFellDue{} = e) do
    %{type: :rent_fell_due, due_date: to_date(e.due_date), amount_cents: e.amount_cents}
  end

  defp to_normalized(%E.RentPaymentRecorded{} = e) do
    %{
      type: :rent_payment_recorded,
      amount_cents: e.amount_cents,
      received_on: to_date(e.received_on),
      source_payment_id: e.source_payment_id
    }
  end

  defp to_normalized(%E.TerminationNoticeGiven{} = e) do
    %{
      type: :termination_notice_given,
      grounds: to_atom(e.grounds),
      termination_date: to_date(e.termination_date),
      given_on: to_date(e.given_on)
    }
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_existing_atom(s)
end
