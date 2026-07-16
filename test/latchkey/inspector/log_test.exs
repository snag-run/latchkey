defmodule Latchkey.Inspector.LogTest do
  @moduledoc """
  Tests for `Latchkey.Inspector.Log` (issue #114, spec developer-view.md D8): keyset
  pagination over the whole `$all` stream, newest-first, with cross-stream identity
  resolution reused from `Latchkey.Inspector.Resolver`.

  Drives the real Postgres `EventStore` (Commanded is disabled in `:test`), appending
  events directly like the event-log pane tests. `async: false` — the EventStore runs
  outside the Ecto sandbox and is shared, so events accumulate; every assertion is
  made against the specific global event numbers this test appended (captured after
  append), never absolute positions.
  """
  use Latchkey.DataCase, async: false

  alias EventStore.EventData
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Clock
  alias Latchkey.EventStore
  alias Latchkey.Inspector.Log
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced
  alias Latchkey.Simulation.Directory

  setup do
    start_supervised!(Latchkey.EventStore)
    :ok
  end

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))

  defp append!(stream_id, events) do
    data =
      events
      |> List.wrap()
      |> Enum.map(fn %mod{} = e ->
        %EventData{event_type: Atom.to_string(mod), data: e, metadata: %{}}
      end)

    :ok = EventStore.append_to_stream(stream_id, :any_version, data)
  end

  defp put_directory!(tenancy_id, name, address) do
    Directory
    |> Ash.Changeset.for_create(:upsert, %{
      tenancy_id: tenancy_id,
      tenant_name: name,
      property_address: address
    })
    |> Ash.create!()
  end

  # Global `$all` event numbers for a stream's events (ascending). async:false → no
  # concurrent appends, so reading the newest slice and filtering by stream is stable.
  defp global_numbers(stream_id) do
    {:ok, events} = EventStore.read_all_streams_backward(-1, 5_000)

    events
    |> Enum.filter(&(&1.stream_uuid == stream_id))
    |> Enum.map(& &1.event_number)
    |> Enum.sort()
  end

  defp commenced(tid, pref) do
    %TenancyCommenced{
      tenancy_id: tid,
      property_ref: pref,
      occurred_on: ~D[2026-01-01],
      recorded_on: ~D[2026-01-01],
      rent_amount_cents: 50_000,
      cycle: :weekly,
      first_due_date: ~D[2026-01-08]
    }
  end

  defp fell_due(tid, occurred, recorded) do
    %RentFellDue{
      tenancy_id: tid,
      occurred_on: occurred,
      recorded_on: recorded,
      amount_cents: 50_000,
      period_from: occurred,
      period_to: Date.add(occurred, 7)
    }
  end

  describe "page/2 keyset pagination" do
    test "pages newest-first and walks history back and forth by cursor" do
      tid = uniq()
      stream = "tenancy-" <> tid

      append!(stream, [
        commenced(tid, "prop-" <> tid),
        fell_due(tid, ~D[2026-01-08], ~D[2026-01-08]),
        fell_due(tid, ~D[2026-01-15], ~D[2026-01-15]),
        fell_due(tid, ~D[2026-01-22], ~D[2026-01-22]),
        fell_due(tid, ~D[2026-01-29], ~D[2026-01-29])
      ])

      [_n1, n2, n3, n4, n5] = global_numbers(stream)

      # First page (head): newest two, newest-first, nothing newer.
      page1 = Log.page(nil, page_size: 2)
      assert Enum.map(page1.rows, & &1.event_number) == [n5, n4]
      assert page1.newer_cursor == nil
      assert page1.older_cursor == n4

      # Older page: strictly older than the cursor, still newest-first.
      page2 = Log.page({:before, page1.older_cursor}, page_size: 2)
      assert Enum.map(page2.rows, & &1.event_number) == [n3, n2]
      assert page2.newer_cursor == n3

      # Newer page: strictly newer than the cursor, re-ordered newest-first.
      newer = Log.page({:after, n3}, page_size: 2)
      assert Enum.map(newer.rows, & &1.event_number) == [n5, n4]
    end

    test "head equals the store's newest global event number" do
      tid = uniq()
      stream = "tenancy-" <> tid
      append!(stream, [commenced(tid, "prop-" <> tid)])
      [n1] = global_numbers(stream)

      assert Log.page(nil).head == n1
    end
  end

  describe "page/2 row building + identity" do
    test "resolves property-leading identity for a seeded tenancy stream" do
      tid = uniq()
      stream = "tenancy-" <> tid
      put_directory!(tid, "Jane Tenant", "42 Wallaby Way, Sydney NSW 2000")
      append!(stream, [commenced(tid, "prop-" <> tid)])
      [n] = global_numbers(stream)

      row = Enum.find(Log.page(nil).rows, &(&1.event_number == n))

      assert row.stream_id == stream
      assert row.kind == :deep
      assert row.position == 1
      assert row.type == "TenancyCommenced"
      assert row.identity.property == "42 Wallaby Way, Sydney NSW 2000"
      assert row.identity.tenant == "Jane Tenant"
      assert row.identity.resolved?
    end

    test "resolves an accounts holder, and shows UNKNOWN for an unseeded tenancy" do
      paid_tid = uniq()
      put_directory!(paid_tid, "Bill Payer", "9 Cash Lane, Sydney NSW 2000")
      pid = "pmt-" <> uniq()

      append!("accounts", [
        %PaymentReceived{
          payment_id: pid,
          amount_cents: 10_000,
          occurred_on: ~D[2026-02-01],
          recorded_on: ~D[2026-02-01],
          holder: "tenancy-" <> paid_tid
        }
      ])

      unseeded = "tenancy-" <> uniq()
      unseeded_tid = String.replace_prefix(unseeded, "tenancy-", "")
      append!(unseeded, [commenced(unseeded_tid, "prop-" <> unseeded_tid)])

      rows = Log.page(nil, page_size: 100).rows

      accounts_row =
        Enum.find(
          rows,
          &(&1.stream_id == "accounts" and &1.identity.ref == "tenancy-" <> paid_tid)
        )

      assert accounts_row.kind == :edge
      assert accounts_row.identity.resolved?
      assert accounts_row.identity.property == "9 Cash Lane, Sydney NSW 2000"

      unseeded_row = Enum.find(rows, &(&1.stream_id == unseeded))
      refute unseeded_row.identity.resolved?
      assert unseeded_row.identity.property == "UNKNOWN"
    end

    test "flags bitemporal divergence only where the two dates differ" do
      tid = uniq()
      stream = "tenancy-" <> tid

      append!(stream, [
        commenced(tid, "prop-" <> tid),
        # An imported tick: recorded lags occurred → divergent.
        fell_due(tid, ~D[2026-01-08], ~D[2026-01-20])
      ])

      [n1, n2] = global_numbers(stream)
      rows = Log.page(nil, page_size: 100).rows

      refute Enum.find(rows, &(&1.event_number == n1)).divergent?
      assert Enum.find(rows, &(&1.event_number == n2)).divergent?
    end
  end

  describe "recorded_today/2 (firehose backlog)" do
    test "returns today's events newest-first, capped by :limit" do
      tid = uniq()
      stream = "tenancy-" <> tid

      append!(stream, [
        commenced(tid, "prop-" <> tid),
        fell_due(tid, ~D[2026-01-08], ~D[2026-01-08]),
        fell_due(tid, ~D[2026-01-15], ~D[2026-01-15])
      ])

      [n1, n2, n3] = global_numbers(stream)

      # These three were just appended, so they carry today's recorded instant.
      mine =
        Clock.today()
        |> Log.recorded_today(limit: 5_000)
        |> Enum.filter(&(&1.stream_uuid == stream))
        |> Enum.map(& &1.event_number)

      # Newest-first, and the whole set is present (order within the stream is stable
      # because the suite is async: false).
      assert mine == [n3, n2, n1]
    end

    test "caps the backlog at :limit, keeping the newest" do
      tid = uniq()
      stream = "tenancy-" <> tid

      append!(stream, [
        commenced(tid, "prop-" <> tid),
        fell_due(tid, ~D[2026-01-08], ~D[2026-01-08])
      ])

      backlog = Log.recorded_today(Clock.today(), limit: 1)

      assert length(backlog) == 1
      # The single kept row is the store's newest event (the backlog reads from head).
      assert hd(backlog).event_number == Log.page(nil).head
    end

    test "a day with no recorded events yields an empty backlog" do
      # The store's events are all recorded today; a past `today` stops the
      # newest-first take_while on the very first (still-today) event.
      assert Log.recorded_today(~D[2000-01-01], limit: 5_000) == []
    end
  end
end
