defmodule Latchkey.Simulation.BehaviourIntegrationTest do
  @moduledoc """
  The behaviour engine end to end (issue #43 acceptance criterion 4): the
  `PaymentReceived` facts a tenant archetype produces are appended to the Accounts
  stream, cross **ACL-1** into `RentPaymentRecorded`, and **move arrears** on the
  tenancy — proving the seam the pure Seam-1 tests can't.

  Harness mirrors `PaymentAclIntegrationTest` / `SweepIntegrationTest`: the event
  store is not sandbox-isolated (Commanded runs its own DB connection), so streams
  are keyed uniquely per run and the async ACL-1 handler is awaited via a transient
  subscription to the tenancy stream rather than by sleeping.
  """
  use Latchkey.DataCase, async: false
  use Oban.Testing, repo: Latchkey.Repo

  alias Latchkey.Accounts
  alias Latchkey.CommandedApp
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Sweep.TenancyWorker
  alias Latchkey.PropertyManagement.Tenancy.Commands.CommenceTenancy
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.Simulation.Behaviour
  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Schedule

  @rent 50_000
  @first_due ~D[2026-01-05]

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.PaymentAcl)

    tid = "beh-it-#{System.unique_integer([:positive])}"
    tenancy_stream = "tenancy-" <> tid
    accounts_stream = "accounts-test-#{System.unique_integer([:positive])}"

    :ok =
      CommandedApp.dispatch(
        %CommenceTenancy{
          tenancy_id: tid,
          property_ref: "prop-" <> tid,
          rent_amount_cents: @rent,
          cycle: :weekly,
          first_due_date: @first_due
        },
        consistency: :strong
      )

    :ok =
      EventStore.subscribe(tenancy_stream,
        selector: fn %{data: data} -> match?(%RentPaymentRecorded{}, data) end
      )

    {:ok, tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream}
  end

  test "engine payments cross ACL-1 and pay down arrears",
       %{tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream} do
    # Accrue five weekly charges so the tenant is in arrears (250_000, none paid).
    assert :ok = perform_job(TenancyWorker, %{"tenancy_id" => tid, "as_of" => "2026-02-02"})
    assert balance(tenancy_stream) == 250_000

    # A reliable tenant pays the first two periods; feed those facts through Accounts.
    holder = "tenancy-" <> tid
    schedule = Schedule.weekly(holder, @first_due, @rent, 2)
    payments = Behaviour.payments(Profile.reliable(), schedule)

    assert :ok = Accounts.append(payments, stream: accounts_stream)

    # Await both bookings by their engine-derived, stable payment ids.
    assert %RentPaymentRecorded{amount_cents: @rent} = await_source("#{holder}-pmt-0")
    assert %RentPaymentRecorded{amount_cents: @rent} = await_source("#{holder}-pmt-1")

    # Arrears moved: two 50_000 payments booked against the 250_000 owed.
    assert balance(tenancy_stream) == 150_000
    assert recorded_count(tenancy_stream) == 2
  end

  test "a re-run of the same schedule is idempotent (stable payment ids dedupe)",
       %{tid: tid, tenancy_stream: tenancy_stream, accounts_stream: accounts_stream} do
    assert :ok = perform_job(TenancyWorker, %{"tenancy_id" => tid, "as_of" => "2026-02-02"})

    holder = "tenancy-" <> tid
    schedule = Schedule.weekly(holder, @first_due, @rent, 1)
    [payment] = Behaviour.payments(Profile.reliable(), schedule)

    assert :ok = Accounts.append(payment, stream: accounts_stream)
    assert %RentPaymentRecorded{} = await_source("#{holder}-pmt-0")

    # Re-emit the identical fact (a seed re-run / replay). Same payment_id → the
    # aggregate no-ops it. Prove it with a distinct sentinel appended after.
    assert :ok = Accounts.append(payment, stream: accounts_stream)

    sentinel =
      Accounts.payment_received(%{
        payment_id: "#{holder}-sentinel",
        amount_cents: 10_000,
        received_on: @first_due,
        recorded_on: @first_due,
        holder: holder
      })

    assert :ok = Accounts.append(sentinel, stream: accounts_stream)
    assert %RentPaymentRecorded{} = await_source("#{holder}-sentinel")

    # Only the original payment (once) and the sentinel booked — the duplicate added
    # nothing (a double-book would push this to 3).
    assert recorded_count(tenancy_stream) == 2
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  defp balance(tenancy_stream) do
    events = tenancy_stream |> EventStore.stream_forward() |> Enum.map(& &1.data)
    due = sum_amount(events, RentFellDue)
    paid = sum_amount(events, RentPaymentRecorded)
    due - paid
  end

  defp sum_amount(events, module) do
    events
    |> Enum.filter(&(&1.__struct__ == module))
    |> Enum.map(& &1.amount_cents)
    |> Enum.sum()
  end

  defp recorded_count(tenancy_stream) do
    tenancy_stream
    |> EventStore.stream_forward()
    |> Enum.map(& &1.data)
    |> Enum.count(&match?(%RentPaymentRecorded{}, &1))
  end

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
end
