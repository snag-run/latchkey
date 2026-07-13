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
  alias Latchkey.PropertyManagement.PaymentAcl
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
          property_ref: "prop-" <> tid,
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

  test "translates a PaymentReversed into a negative RentPaymentRecorded carrying reason/reverses",
       %{tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream} do
    # First a forward payment PM records, so there is something to reverse.
    assert :ok =
             Accounts.append(tenancy_receipt(tid, "acl-rev-fwd", 50_000), stream: accounts_stream)

    assert %RentPaymentRecorded{} = await_source("acl-rev-fwd")

    reversal =
      Accounts.payment_reversed(%{
        payment_id: "acl-rev-neg",
        reverses: "acl-rev-fwd",
        amount_cents: -50_000,
        reversed_on: ~D[2026-01-10],
        recorded_on: ~D[2026-01-11],
        reason: "dishonoured"
      })

    assert :ok = Accounts.append(reversal, stream: accounts_stream)

    booked = await_source("acl-rev-neg")

    # Signed negative, carrying the reason and the link to the payment it undoes.
    assert booked.amount_cents == -50_000
    assert booked.reason == "dishonoured"
    assert booked.reverses == "acl-rev-fwd"
    assert to_date(booked.occurred_on) == ~D[2026-01-10]

    # Forward receipt + its reversal: exactly two RentPaymentRecorded on the stream.
    assert recorded_count(tenancy_stream) == 2
  end

  test "a re-delivered reversal (same source_payment_id) books no duplicate",
       %{tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream} do
    assert :ok =
             Accounts.append(tenancy_receipt(tid, "acl-ridem-fwd", 50_000),
               stream: accounts_stream
             )

    assert %RentPaymentRecorded{} = await_source("acl-ridem-fwd")

    reversal =
      Accounts.payment_reversed(%{
        payment_id: "acl-ridem-neg",
        reverses: "acl-ridem-fwd",
        amount_cents: -50_000,
        reversed_on: ~D[2026-01-10],
        reason: "dishonoured"
      })

    assert :ok = Accounts.append(reversal, stream: accounts_stream)
    assert %RentPaymentRecorded{} = await_source("acl-ridem-neg")

    # Re-deliver the identical reversal; source_payment_id idempotency makes it a no-op.
    assert :ok = Accounts.append(reversal, stream: accounts_stream)

    sentinel = tenancy_receipt(tid, "acl-ridem-sentinel", 10_000)
    assert :ok = Accounts.append(sentinel, stream: accounts_stream)
    assert %RentPaymentRecorded{} = await_source("acl-ridem-sentinel")

    # forward + reversal (once) + sentinel = 3; a double-booked reversal would push to 4.
    assert recorded_count(tenancy_stream) == 3
  end

  test "defensively rejects a reversal referencing a payment PM never recorded (§5 P2)",
       %{tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream} do
    # A payment attributed to a tenancy that never commenced: PM refuses to record it
    # (:not_active), so PM never books it — yet its holder is a well-formed tenancy_ref,
    # so ACL-1 can still route the reversal and the aggregate is the one that rejects.
    ghost = "acl-ghost-#{System.unique_integer([:positive])}"

    assert :ok =
             Accounts.append(tenancy_receipt(ghost, "acl-ghost-pay", 50_000),
               stream: accounts_stream
             )

    reversal =
      Accounts.payment_reversed(%{
        payment_id: "acl-ghost-rev",
        reverses: "acl-ghost-pay",
        amount_cents: -50_000,
        reversed_on: ~D[2026-01-10],
        reason: "dishonoured"
      })

    assert :ok = Accounts.append(reversal, stream: accounts_stream)

    # Sync on a known-good receipt for the committed tenancy appended AFTER the reversal:
    # once its RentPaymentRecorded is acked, the reversal has definitively been processed
    # (and, being defensively rejected, booked nothing on either stream).
    sentinel = tenancy_receipt(tid, "acl-ghost-sentinel", 10_000)
    assert :ok = Accounts.append(sentinel, stream: accounts_stream)
    assert %RentPaymentRecorded{} = await_source("acl-ghost-sentinel")

    # The rejected reversal booked nothing against the never-commenced tenancy.
    assert recorded_count("tenancy-" <> ghost) == 0
    # Only the sentinel landed on the committed tenancy — the reversal never leaked here.
    assert recorded_count(tenancy_stream) == 1
  end

  test "skips a reversal whose original payment is absent from the source stream (not-found)",
       %{tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream} do
    # A reversal whose `reverses` points at a payment_id never written to the source
    # stream: ACL-1 cannot recover a holder to route it, so it is logged and skipped
    # (not retried forever), booking nothing.
    reversal =
      Accounts.payment_reversed(%{
        payment_id: "acl-orphan-rev",
        reverses: "acl-never-written",
        amount_cents: -50_000,
        reversed_on: ~D[2026-01-10],
        reason: "dishonoured"
      })

    assert :ok = Accounts.append(reversal, stream: accounts_stream)

    # Sync on a known-good receipt appended AFTER the orphan reversal; once its
    # RentPaymentRecorded is acked, the reversal has definitively been processed (and,
    # being un-routable, booked nothing).
    sentinel = tenancy_receipt(tid, "acl-orphan-sentinel", 10_000)
    assert :ok = Accounts.append(sentinel, stream: accounts_stream)
    assert %RentPaymentRecorded{} = await_source("acl-orphan-sentinel")

    # Only the sentinel landed — the orphan reversal never crossed the seam.
    assert recorded_count(tenancy_stream) == 1
  end

  test "skips a reversal whose source stream does not exist at all (stream_not_found)",
       %{tenancy_stream: tenancy_stream} do
    # Distinct from the orphan case above: there the source stream exists but lacks the
    # original payment (find_value default); here the source stream itself is missing.
    # Drive the handler synchronously with a fabricated metadata.stream_id so
    # source_holder's EventStore.stream_forward hits {:error, :stream_not_found} — a
    # permanent miss that is logged and skipped (never retried), booking nothing.
    reversal =
      Accounts.payment_reversed(%{
        payment_id: "acl-nostream-rev",
        reverses: "acl-nostream-orig",
        amount_cents: -50_000,
        reversed_on: ~D[2026-01-10],
        reason: "dishonoured"
      })

    missing_stream = "accounts-missing-#{System.unique_integer([:positive])}"

    # :ok = skip (checkpoint advances); a transient read would instead return {:error, _}.
    assert :ok = PaymentAcl.handle(reversal, %{stream_id: missing_stream})

    # Nothing booked on the committed tenancy stream.
    assert recorded_count(tenancy_stream) == 0
  end

  test "skips a reversal whose original payment was UNKNOWN-held (suspense never crosses)",
       %{tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream} do
    # The original receipt was suspense money (UNKNOWN holder) PM never recorded; its
    # reversal must likewise never cross the seam — ACL-1 recovers the UNKNOWN holder
    # from the source stream, sees it is not a known holder, and skips.
    assert :ok =
             Accounts.append(
               Accounts.payment_received(%{
                 payment_id: "acl-susp-pay",
                 amount_cents: 40_000,
                 received_on: ~D[2026-01-05],
                 holder: Accounts.unknown_holder()
               }),
               stream: accounts_stream
             )

    reversal =
      Accounts.payment_reversed(%{
        payment_id: "acl-susp-rev",
        reverses: "acl-susp-pay",
        amount_cents: -40_000,
        reversed_on: ~D[2026-01-10],
        reason: "dishonoured"
      })

    assert :ok = Accounts.append(reversal, stream: accounts_stream)

    sentinel = tenancy_receipt(tid, "acl-susp-sentinel", 10_000)
    assert :ok = Accounts.append(sentinel, stream: accounts_stream)
    assert %RentPaymentRecorded{} = await_source("acl-susp-sentinel")

    # Only the sentinel landed — neither the suspense receipt nor its reversal crossed.
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
    case EventStore.stream_forward(tenancy_stream) do
      # A never-written stream (e.g. a rejected reversal against a never-commenced
      # tenancy) simply does not exist — that is zero booked payments.
      {:error, :stream_not_found} ->
        0

      stream ->
        stream
        |> Enum.map(& &1.data)
        |> Enum.count(&match?(%RentPaymentRecorded{}, &1))
    end
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)
end
