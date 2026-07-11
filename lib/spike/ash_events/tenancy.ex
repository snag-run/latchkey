defmodule Spike.AshEvents.Tenancy do
  @moduledoc """
  The aggregate, hand-rolled over the Ash event log. Every command is the same
  four steps you write yourself: **load** the stream, **fold** it, **decide**,
  **append**. The decision itself is `Spike.TenancyCore` — shared with the
  Commanded spike — so this module is *pure plumbing*, which is the point.

  Note the serialization tax (`to_stored/1`, `from_stored/1`): jsonb round-trips
  strings, so we own encoding atoms and Dates by hand. Commanded's serializer
  does this for you.
  """
  alias Spike.AshEvents.{Event, TenancyArrears}
  alias Spike.TenancyCore

  def commence(cmd),
    do: run(cmd.tenancy_id, cmd, &TenancyCore.decide_commence/2, cmd.first_due_date)

  def record_payment(cmd),
    do: run(cmd.tenancy_id, cmd, &TenancyCore.decide_payment/2, cmd.received_on)

  def give_termination_notice(cmd),
    do: run(cmd.tenancy_id, cmd, &TenancyCore.decide_termination/2, cmd.as_of)

  @doc "§6 lazy sweep — book owed rent up to `as_of` and warm the read model."
  def catch_up(cmd), do: run(cmd.tenancy_id, cmd, &TenancyCore.decide_catch_up/2, cmd.as_of)

  @doc "Read model is disposable — drop and refold from the log."
  def rebuild_projection(tenancy_id, as_of) do
    state = tenancy_id |> load_stream() |> elem(1) |> TenancyCore.fold()
    upsert_projection(tenancy_id, state, as_of)
  end

  # ── the four steps ─────────────────────────────────────────────────────────

  defp run(stream_id, cmd, decide_fun, as_of) do
    {rows, normalized} = load_stream(stream_id)
    state = TenancyCore.fold(normalized)

    case decide_fun.(state, cmd) do
      {:error, reason} ->
        {:error, reason}

      {:ok, []} ->
        {:ok, :noop}

      {:ok, new_events} ->
        base_seq = length(rows)

        input =
          new_events
          |> Enum.with_index(base_seq + 1)
          |> Enum.map(fn {ev, seq} ->
            {type, data} = to_stored(ev)
            %{stream_id: stream_id, sequence: seq, type: type, data: data}
          end)

        # Atomic append; the (stream_id, sequence) identity enforces concurrency.
        case Ash.bulk_create(input, Event, :append,
               return_records?: false,
               transaction: :all,
               stop_on_error?: true
             ) do
          %Ash.BulkResult{status: :success} ->
            final = TenancyCore.fold(normalized ++ new_events)
            upsert_projection(stream_id, final, as_of)
            {:ok, :appended}

          %Ash.BulkResult{status: :error} ->
            {:error, :concurrency_conflict}
        end
    end
  end

  defp load_stream(stream_id) do
    rows =
      Event
      |> Ash.Query.for_read(:for_stream, %{stream_id: stream_id})
      |> Ash.read!()

    {rows, Enum.map(rows, &from_stored/1)}
  end

  defp upsert_projection(tenancy_id, state, as_of) do
    TenancyArrears
    |> Ash.Changeset.for_create(:upsert, %{
      tenancy_id: tenancy_id,
      balance_cents: TenancyCore.balance_cents(state),
      days_behind: TenancyCore.days_behind(state, as_of),
      oldest_unpaid_due_date: TenancyCore.oldest_unpaid_due_date(state),
      as_of: as_of
    })
    |> Ash.create!()
  end

  # ── serialization (jsonb is string-only, so we own it) ──────────────────────

  defp to_stored(%{type: :tenancy_commenced} = e) do
    {:tenancy_commenced,
     %{
       "tenancy_id" => e.tenancy_id,
       "rent_amount_cents" => e.rent_amount_cents,
       "cycle" => Atom.to_string(e.cycle),
       "first_due_date" => Date.to_iso8601(e.first_due_date)
     }}
  end

  defp to_stored(%{type: :rent_fell_due} = e) do
    {:rent_fell_due,
     %{"due_date" => Date.to_iso8601(e.due_date), "amount_cents" => e.amount_cents}}
  end

  defp to_stored(%{type: :rent_payment_recorded} = e) do
    {:rent_payment_recorded,
     %{
       "amount_cents" => e.amount_cents,
       "received_on" => Date.to_iso8601(e.received_on),
       "source_payment_id" => e.source_payment_id
     }}
  end

  defp to_stored(%{type: :termination_notice_given} = e) do
    {:termination_notice_given,
     %{
       "grounds" => Atom.to_string(e.grounds),
       "termination_date" => Date.to_iso8601(e.termination_date),
       "given_on" => Date.to_iso8601(e.given_on)
     }}
  end

  defp from_stored(%Event{type: :tenancy_commenced, data: d}) do
    %{
      type: :tenancy_commenced,
      tenancy_id: d["tenancy_id"],
      rent_amount_cents: d["rent_amount_cents"],
      cycle: String.to_existing_atom(d["cycle"]),
      first_due_date: Date.from_iso8601!(d["first_due_date"])
    }
  end

  defp from_stored(%Event{type: :rent_fell_due, data: d}) do
    %{
      type: :rent_fell_due,
      due_date: Date.from_iso8601!(d["due_date"]),
      amount_cents: d["amount_cents"]
    }
  end

  defp from_stored(%Event{type: :rent_payment_recorded, data: d}) do
    %{
      type: :rent_payment_recorded,
      amount_cents: d["amount_cents"],
      received_on: Date.from_iso8601!(d["received_on"]),
      source_payment_id: d["source_payment_id"]
    }
  end

  defp from_stored(%Event{type: :termination_notice_given, data: d}) do
    %{
      type: :termination_notice_given,
      grounds: String.to_existing_atom(d["grounds"]),
      termination_date: Date.from_iso8601!(d["termination_date"]),
      given_on: Date.from_iso8601!(d["given_on"])
    }
  end
end
