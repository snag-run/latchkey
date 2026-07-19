defmodule LatchkeyWeb.InspectorPerStreamLiveTest do
  @moduledoc """
  Tests for the **per-stream live updates** of the tenancy stream-detail view
  (issue #86, spec developer-view.md decision **D5**): the view subscribes to its
  `dev:stream:<id>` topic and, as new events land, either follows at the head or
  pins the position and raises a "new events available" nudge.

  Drives the real Postgres `EventStore` (events appended directly, mirroring the
  replay-scrubber test) so the live re-read sees them, and asserts on stable DOM
  ids, never raw HTML. No `Process.sleep`: the live path is driven by broadcasting
  / sending the `{:dev_event, ...}` message the broadcaster (#82) publishes.
  `async: false` — the EventStore runs outside the Ecto sandbox.
  """
  use LatchkeyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EventStore.EventData
  alias Latchkey.EventStore
  alias Latchkey.Inspector.Broadcaster
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced

  setup do
    start_supervised!(Latchkey.EventStore)
    :ok
  end

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))

  defp put_arrears!(attrs) do
    Arrears
    |> Ash.Changeset.for_create(:upsert, Enum.into(attrs, %{status: :active, balance_cents: 0}))
    |> Ash.create!()
  end

  defp append!(stream_id, events) do
    data =
      events
      |> List.wrap()
      |> Enum.map(fn %mod{} = e ->
        %EventData{event_type: Atom.to_string(mod), data: e, metadata: %{}}
      end)

    :ok = EventStore.append_to_stream(stream_id, :any_version, data)
  end

  # A weekly $500 charge that falls due — appended to make a pane visibly move.
  defp charge(tid, on) do
    %RentFellDue{
      tenancy_id: tid,
      occurred_on: on,
      recorded_on: on,
      amount_cents: 50_000,
      period_from: on,
      period_to: Date.add(on, 7)
    }
  end

  # Metadata as the broadcaster (#82) fans out — enough for the firehose row and
  # the per-stream advance (`stream_id`). The live path re-reads the store, so the
  # exact numbers here don't drive the fold, only the firehose row.
  defp meta(stream_id, version) do
    %{
      event_number: version,
      stream_id: stream_id,
      stream_version: version,
      created_at: ~U[2026-01-15 10:00:00Z]
    }
  end

  describe "per-stream live updates (D5)" do
    setup %{conn: conn} do
      tid = "live-" <> uniq()
      stream = "tenancy-" <> tid
      pref = "prop-" <> tid

      # Seed a 2-event stream: commence + one $500 charge (balance $500 at head).
      append!(stream, [
        %TenancyCommenced{
          tenancy_id: tid,
          property_ref: pref,
          occurred_on: ~D[2026-01-01],
          recorded_on: ~D[2026-01-01],
          rent_amount_cents: 50_000,
          cycle: :weekly,
          first_due_date: ~D[2026-01-01]
        },
        charge(tid, ~D[2026-01-01])
      ])

      put_arrears!(%{tenancy_id: tid, status: :active, balance_cents: 50_000})

      {:ok, view, _html} = live(conn, ~p"/inspector/streams/#{stream}")
      %{view: view, tid: tid, stream: stream}
    end

    test "opens at the head with no nudge", %{view: view} do
      assert has_element?(view, "#scrubber-position", "2 / 2")
      refute has_element?(view, "#scrubber-nudge")
    end

    test "at head, a broadcast event advances to N+1 and folds live into the panes", %{
      view: view,
      tid: tid,
      stream: stream
    } do
      # A new charge lands on the stream (persisted first, then broadcast — the D5
      # order). Broadcasting to the per-stream topic proves the connected-mount
      # subscription is live.
      append!(stream, charge(tid, ~D[2026-01-08]))

      Phoenix.PubSub.broadcast(
        Latchkey.PubSub,
        Broadcaster.stream_topic(stream),
        {:dev_event, charge(tid, ~D[2026-01-08]), meta(stream, 3)}
      )

      # Followed at head: advanced to 3/3, the new event is highlighted, and the
      # read-model balance folded the new charge in ($500 -> $1000). No nudge.
      assert has_element?(view, "#scrubber-position", "3 / 3")
      assert has_element?(view, "#event-row-#{stream}-3[aria-current]")
      assert has_element?(view, "#read-model-balance", "$1000.00")
      refute has_element?(view, "#scrubber-nudge")
    end

    test "a duplicate delivery of the same event does not double-advance", %{
      view: view,
      tid: tid,
      stream: stream
    } do
      append!(stream, charge(tid, ~D[2026-01-08]))
      msg = {:dev_event, charge(tid, ~D[2026-01-08]), meta(stream, 3)}

      # The active stream is delivered on both the global and per-stream topics;
      # re-reading the store makes the second delivery a no-op.
      send(view.pid, msg)
      send(view.pid, msg)

      assert has_element?(view, "#scrubber-position", "3 / 3")
    end

    test "parked mid-history, position holds and a nudge appears; jumping resumes at head",
         %{view: view, tid: tid, stream: stream} do
      # Park back at k=1 (commence only — balance $0.00).
      view |> element("#event-row-#{stream}-1") |> render_click()
      assert has_element?(view, "#scrubber-position", "1 / 2")
      assert has_element?(view, "#read-model-balance", "$0.00")
      refute has_element?(view, "#scrubber-nudge")

      # A new event lands live while parked.
      append!(stream, charge(tid, ~D[2026-01-08]))
      send(view.pid, {:dev_event, charge(tid, ~D[2026-01-08]), meta(stream, 3)})

      # Position holds at k=1; N grew to 3; the nudge appears and the folded panes
      # are unchanged (still $0.00 at k=1).
      assert has_element?(view, "#scrubber-position", "1 / 3")
      assert has_element?(view, "#scrubber-nudge")
      assert has_element?(view, "#scrubber-jump-to-head")
      assert has_element?(view, "#read-model-balance", "$0.00")

      # Clicking the nudge jumps to the head, folds everything in, and clears it.
      view |> element("#scrubber-jump-to-head") |> render_click()

      assert has_element?(view, "#scrubber-position", "3 / 3")
      assert has_element?(view, "#read-model-balance", "$1000.00")
      refute has_element?(view, "#scrubber-nudge")
    end

    test "an event for a different stream does not touch this view", %{view: view} do
      other = "tenancy-other-#{uniq()}"

      send(view.pid, {:dev_event, %TenancyCommenced{tenancy_id: "x"}, meta(other, 1)})

      # Unchanged: still at the original head, no nudge.
      assert has_element?(view, "#scrubber-position", "2 / 2")
      refute has_element?(view, "#scrubber-nudge")
    end
  end

  describe "accounts edge stream — no per-stream subscription (D3/D5)" do
    test "the events-only edge view does not subscribe to its per-stream topic", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/streams/accounts")

      # An event_number the firehose's today-backlog seed can't already hold, so
      # the row we refute could only come from a (wrongful) per-stream
      # subscription — not the seed, which shares the `#firehose-<n>` keyspace.
      n =
        System.unique_integer([:positive])
        |> Stream.iterate(&(&1 + 1))
        |> Enum.find(&(not has_element?(view, "#firehose-#{&1}")))

      # Broadcast only to the accounts *per-stream* topic (not the global firehose).
      # The edge folds no state, so it never subscribes here — the message reaches
      # nothing and no firehose row is inserted. (A subscribed view would have.)
      Phoenix.PubSub.broadcast(
        Latchkey.PubSub,
        Broadcaster.stream_topic("accounts"),
        {:dev_event, %TenancyCommenced{tenancy_id: "x"}, meta("accounts", n)}
      )

      assert has_element?(view, "#event-log")
      refute has_element?(view, "#firehose-#{n}")
    end
  end
end
