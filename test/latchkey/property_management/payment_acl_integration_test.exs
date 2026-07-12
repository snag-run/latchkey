defmodule Latchkey.PropertyManagement.PaymentAclIntegrationTest do
  @moduledoc """
  ACL-1 forward path through the real Commanded app + Postgres EventStore. Proves the
  seam the unit test can't: an Accounts `PaymentReceived` appended to the store is
  picked up by the checkpointed policy and translated into a `RentPaymentRecorded` on
  the tenancy stream — and that a re-delivered receipt (same `source_payment_id`) is
  a no-op, so no duplicate payment is booked.

  The event store is not sandboxed (Commanded runs its own DB connection), so streams
  are keyed uniquely per run and we await the async handler via a transient
  subscription to the tenancy stream rather than sleeping.
  """
  use ExUnit.Case, async: false

  alias Latchkey.Accounts
  alias Latchkey.CommandedApp
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Tenancy.Commands.CommenceTenancy
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.PaymentAcl)

    tid = "acl-it-#{System.unique_integer([:positive])}"
    tenancy_stream = "tenancy-" <> tid
    accounts_stream = "accounts-test-#{System.unique_integer([:positive])}"

    :ok =
      CommandedApp.dispatch(
        %CommenceTenancy{
          tenancy_id: tid,
          rent_amount_cents: 50_000,
          cycle: :weekly,
          first_due_date: ~D[2026-01-05]
        },
        consistency: :strong
      )

    # Transient subscription filtered to ACL-1's output: the selector drops the
    # commence/charge events (a fresh stream has no RentPaymentRecorded yet), so we
    # observe exactly the payments the policy books — no sleeping.
    :ok =
      EventStore.subscribe(tenancy_stream,
        selector: fn %{data: data} -> match?(%RentPaymentRecorded{}, data) end
      )

    {:ok, tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream}
  end

  test "translates a tenancy-attributed PaymentReceived into a RentPaymentRecorded",
       %{tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream} do
    payment =
      Accounts.payment_received(%{
        payment_id: "acl-p1",
        amount_cents: 50_000,
        received_on: ~D[2026-01-05],
        recorded_on: ~D[2026-01-06],
        holder: "tenancy-" <> tid
      })

    assert :ok = Accounts.append(payment, stream: accounts_stream)

    booked = await_source("acl-p1")

    assert booked.source_payment_id == "acl-p1"
    assert booked.amount_cents == 50_000
    assert to_date(booked.occurred_on) == ~D[2026-01-05]
    assert to_date(booked.recorded_on) == ~D[2026-01-06]

    # Exactly one RentPaymentRecorded on the tenancy stream so far.
    assert recorded_count(tenancy_stream) == 1
  end

  test "a re-delivered receipt (same source_payment_id) books no duplicate payment",
       %{tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream} do
    payment =
      Accounts.payment_received(%{
        payment_id: "acl-dup",
        amount_cents: 30_000,
        received_on: ~D[2026-01-05],
        recorded_on: ~D[2026-01-06],
        holder: "tenancy-" <> tid
      })

    assert :ok = Accounts.append(payment, stream: accounts_stream)
    assert %RentPaymentRecorded{source_payment_id: "acl-dup"} = await_source("acl-dup")

    # Re-deliver the identical receipt; the aggregate's source_payment_id idempotency
    # makes it a no-op. Rather than race a `refute_receive` window, append a second,
    # known-good receipt AFTER the duplicate and wait for ITS RentPaymentRecorded — the
    # handler processes the stream in order, so once the sentinel is acked the duplicate
    # has definitively been processed (and, being idempotent, booked nothing).
    assert :ok = Accounts.append(payment, stream: accounts_stream)

    sentinel = tenancy_receipt(tid, "acl-dup-sentinel", 10_000)
    assert :ok = Accounts.append(sentinel, stream: accounts_stream)
    assert %RentPaymentRecorded{} = await_source("acl-dup-sentinel")

    # Only the original acl-dup (once) and the sentinel are booked — the duplicate added
    # nothing. A double-booked duplicate would push this to 3.
    assert recorded_count(tenancy_stream) == 2
  end

  test "an UNKNOWN-held receipt never crosses the seam",
       %{tid: tid, accounts_stream: accounts_stream, tenancy_stream: tenancy_stream} do
    payment =
      Accounts.payment_received(%{
        payment_id: "acl-unknown",
        amount_cents: 40_000,
        received_on: ~D[2026-01-05],
        holder: Accounts.unknown_holder()
      })

    assert :ok = Accounts.append(payment, stream: accounts_stream)

    # Append a known-good tenancy-attributed receipt AFTER the UNKNOWN one and wait for
    # ITS RentPaymentRecorded. Because the handler processes the stream in order, once
    # the sentinel is acked the UNKNOWN receipt has definitively been processed — so a
    # count of exactly 1 proves suspense money never crossed the seam (a leak → 2).
    sentinel = tenancy_receipt(tid, "acl-unknown-sentinel", 40_000)
    assert :ok = Accounts.append(sentinel, stream: accounts_stream)
    assert %RentPaymentRecorded{} = await_source("acl-unknown-sentinel")

    assert recorded_count(tenancy_stream) == 1
  end

  # A known-good, tenancy-attributed receipt — used as a positive checkpoint the async
  # handler must observably reach, so earlier events are provably processed-or-skipped.
  defp tenancy_receipt(tid, payment_id, amount_cents) do
    Accounts.payment_received(%{
      payment_id: payment_id,
      amount_cents: amount_cents,
      received_on: ~D[2026-01-05],
      recorded_on: ~D[2026-01-06],
      holder: "tenancy-" <> tid
    })
  end

  # Accumulate transient-subscription batches until the RentPaymentRecorded carrying the
  # given source_payment_id arrives (its ack is the deterministic checkpoint we sync on).
  defp await_source(source_id, acc \\ []) do
    receive do
      {:events, events} ->
        acc = acc ++ Enum.map(events, & &1.data)

        case Enum.find(acc, &match?(%RentPaymentRecorded{source_payment_id: ^source_id}, &1)) do
          %RentPaymentRecorded{} = booked -> booked
          nil -> await_source(source_id, acc)
        end
    after
      5000 -> flunk("timed out awaiting RentPaymentRecorded #{source_id}; saw: #{inspect(acc)}")
    end
  end

  defp recorded_count(tenancy_stream) do
    tenancy_stream
    |> EventStore.stream_forward()
    |> Enum.map(& &1.data)
    |> Enum.count(&match?(%RentPaymentRecorded{}, &1))
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)
end
