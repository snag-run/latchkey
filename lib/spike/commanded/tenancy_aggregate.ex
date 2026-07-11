defmodule Spike.Commanded.TenancyAggregate do
  @moduledoc """
  Commanded aggregate. `execute/2` and `apply/2` are the framework's structural
  home for decide-from-fold: Commanded rehydrates the aggregate by replaying
  `apply/2` over the stream BEFORE calling `execute/2`, so the decision always
  sees folded state. That is the property AshCommanded lacked (ADR 0002).

  The decision + fold themselves are `Spike.TenancyCore` — shared verbatim with
  the pure-Ash spike. This module is the Commanded-shaped adapter around it:
  command struct → core, core events → event structs, event structs → core.
  """
  alias Spike.Commanded.Commands.{CatchUp, CommenceTenancy, GiveTerminationNotice, RecordPayment}
  alias Spike.Commanded.Events
  alias Spike.TenancyCore

  defstruct core: Spike.TenancyCore.initial_state()

  # ── execute (decide) ────────────────────────────────────────────────────────

  def execute(%__MODULE__{core: core}, %CommenceTenancy{} = c) do
    cmd = %{
      tenancy_id: c.tenancy_id,
      rent_amount_cents: c.rent_amount_cents,
      cycle: c.cycle,
      first_due_date: c.first_due_date
    }

    emit(TenancyCore.decide_commence(core, cmd), c.tenancy_id)
  end

  def execute(%__MODULE__{core: core}, %RecordPayment{} = c) do
    cmd = %{
      tenancy_id: c.tenancy_id,
      amount_cents: c.amount_cents,
      received_on: c.received_on,
      source_payment_id: c.source_payment_id
    }

    emit(TenancyCore.decide_payment(core, cmd), c.tenancy_id)
  end

  def execute(%__MODULE__{core: core}, %CatchUp{} = c) do
    emit(TenancyCore.decide_catch_up(core, %{as_of: c.as_of}), c.tenancy_id)
  end

  def execute(%__MODULE__{core: core}, %GiveTerminationNotice{} = c) do
    cmd = %{
      tenancy_id: c.tenancy_id,
      termination_date: c.termination_date,
      given_on: c.given_on,
      as_of: c.as_of
    }

    emit(TenancyCore.decide_termination(core, cmd), c.tenancy_id)
  end

  # ── apply (fold) ────────────────────────────────────────────────────────────

  def apply(%__MODULE__{core: core} = agg, event) do
    %{agg | core: TenancyCore.evolve(core, to_normalized(event))}
  end

  # ── adapters ────────────────────────────────────────────────────────────────

  defp emit({:error, reason}, _tid), do: {:error, reason}
  defp emit({:ok, events}, tid), do: Enum.map(events, &to_struct(&1, tid))

  defp to_struct(%{type: :tenancy_commenced} = e, _tid) do
    %Events.TenancyCommenced{
      tenancy_id: e.tenancy_id,
      rent_amount_cents: e.rent_amount_cents,
      cycle: e.cycle,
      first_due_date: e.first_due_date
    }
  end

  defp to_struct(%{type: :rent_fell_due} = e, tid) do
    %Events.RentFellDue{tenancy_id: tid, due_date: e.due_date, amount_cents: e.amount_cents}
  end

  defp to_struct(%{type: :rent_payment_recorded} = e, tid) do
    %Events.RentPaymentRecorded{
      tenancy_id: tid,
      amount_cents: e.amount_cents,
      received_on: e.received_on,
      source_payment_id: e.source_payment_id
    }
  end

  defp to_struct(%{type: :termination_notice_given} = e, tid) do
    %Events.TerminationNoticeGiven{
      tenancy_id: tid,
      grounds: e.grounds,
      termination_date: e.termination_date,
      given_on: e.given_on
    }
  end

  # JSON rehydration returns strings for atoms/Dates — coerce back (the same
  # type-loss the pure-Ash spike handles by hand; the serializer doesn't save you).
  defp to_normalized(%Events.TenancyCommenced{} = e) do
    %{
      type: :tenancy_commenced,
      tenancy_id: e.tenancy_id,
      rent_amount_cents: e.rent_amount_cents,
      cycle: to_atom(e.cycle),
      first_due_date: to_date(e.first_due_date)
    }
  end

  defp to_normalized(%Events.RentFellDue{} = e) do
    %{type: :rent_fell_due, due_date: to_date(e.due_date), amount_cents: e.amount_cents}
  end

  defp to_normalized(%Events.RentPaymentRecorded{} = e) do
    %{
      type: :rent_payment_recorded,
      amount_cents: e.amount_cents,
      received_on: to_date(e.received_on),
      source_payment_id: e.source_payment_id
    }
  end

  defp to_normalized(%Events.TerminationNoticeGiven{} = e) do
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
