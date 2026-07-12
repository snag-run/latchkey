defmodule Latchkey.AccountsIntegrationTest do
  @moduledoc """
  The Accounts append API through the real Commanded Postgres EventStore. Proves the
  wiring the pure builder test can't: both edge events persist to the Accounts stream
  and rehydrate as structs with the bitemporal envelope intact across the JSON
  round-trip.

  The event store is not sandboxed (Commanded runs its own DB connection), so the
  stream is keyed uniquely per run.
  """
  use ExUnit.Case, async: false

  alias Latchkey.Accounts
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Accounts.Events.PaymentReversed
  alias Latchkey.EventStore

  setup do
    start_supervised!(Latchkey.EventStore)
    stream = "accounts-test-#{System.unique_integer([:positive])}"
    {:ok, stream: stream}
  end

  test "appends both edge events and rehydrates them with the envelope", %{stream: stream} do
    received =
      Accounts.payment_received(%{
        payment_id: "p1",
        amount_cents: 50_000,
        received_on: ~D[2026-01-05],
        recorded_on: ~D[2026-01-06],
        holder: "tenancy-1"
      })

    reversed =
      Accounts.payment_reversed(%{
        payment_id: "p1-rev",
        reverses: "p1",
        amount_cents: -50_000,
        reversed_on: ~D[2026-01-07],
        recorded_on: ~D[2026-01-07],
        reason: "wrong_holder"
      })

    assert :ok = Accounts.append([received, reversed], stream: stream)

    events =
      stream
      |> EventStore.stream_forward()
      |> Enum.map(& &1.data)

    assert [%PaymentReceived{} = got_received, %PaymentReversed{} = got_reversed] = events

    # Envelope survives the JSON round-trip (dates return as ISO strings).
    assert got_received.holder == "tenancy-1"
    assert got_received.amount_cents == 50_000
    assert to_date(got_received.occurred_on) == ~D[2026-01-05]
    assert to_date(got_received.recorded_on) == ~D[2026-01-06]

    assert got_reversed.reverses == "p1"
    assert got_reversed.reason == "wrong_holder"
    # Compensating entry: negative amount.
    assert got_reversed.amount_cents == -50_000
    assert to_date(got_reversed.occurred_on) == ~D[2026-01-07]
  end

  test "an UNKNOWN-held payment is representable in the stream", %{stream: stream} do
    event =
      Accounts.payment_received(%{
        payment_id: "p2",
        amount_cents: 25_000,
        received_on: ~D[2026-01-05],
        holder: Accounts.unknown_holder()
      })

    assert :ok = Accounts.append(event, stream: stream)

    assert [%PaymentReceived{holder: "UNKNOWN"}] =
             stream |> EventStore.stream_forward() |> Enum.map(& &1.data)
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)
end
