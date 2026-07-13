defmodule LatchkeyWeb.InspectorLogTest do
  @moduledoc """
  Tests for the read-only **paginated full event-log view** (issue #114, spec
  developer-view.md D8): a historical browser over the whole `$all` stream,
  newest-first, with keyset paging back and forth through history and rows that
  link through to their stream detail (scrubbed to the event's position).

  Drives the real Postgres `EventStore` (Commanded is disabled in `:test`).
  `async: false` — the EventStore is shared and unsandboxed, so every assertion is
  keyed to the specific global event numbers this test appended, and DOM ids are
  asserted via `has_element?`, never raw HTML.
  """
  use LatchkeyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EventStore.EventData
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
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

  defp put_arrears!(attrs) do
    Arrears
    |> Ash.Changeset.for_create(:upsert, Enum.into(attrs, %{status: :active, balance_cents: 0}))
    |> Ash.create!()
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

  defp global_numbers(stream_id) do
    {:ok, events} = EventStore.read_all_streams_backward(-1, 5_000)

    events
    |> Enum.filter(&(&1.stream_uuid == stream_id))
    |> Enum.map(& &1.event_number)
    |> Enum.sort()
  end

  # Three events (commencement + two ticks) on a fresh tenancy stream; returns the
  # stream id and the ascending global event numbers [n1, n2, n3].
  defp seed_stream!(opts \\ []) do
    tid = uniq()
    stream = "tenancy-" <> tid

    if Keyword.get(opts, :arrears, false),
      do: put_arrears!(%{tenancy_id: tid, status: :active})

    if Keyword.get(opts, :directory, false),
      do: put_directory!(tid, "Jane Tenant", "42 Wallaby Way, Sydney NSW 2000")

    append!(stream, [
      %TenancyCommenced{
        tenancy_id: tid,
        property_ref: "prop-" <> tid,
        occurred_on: ~D[2026-01-01],
        recorded_on: ~D[2026-01-01],
        rent_amount_cents: 50_000,
        cycle: :weekly,
        first_due_date: ~D[2026-01-08]
      },
      %RentFellDue{
        tenancy_id: tid,
        occurred_on: ~D[2026-01-08],
        # Imported tick: recorded lags occurred → divergent.
        recorded_on: ~D[2026-01-20],
        amount_cents: 50_000,
        period_from: ~D[2026-01-08],
        period_to: ~D[2026-01-15]
      },
      %RentFellDue{
        tenancy_id: tid,
        occurred_on: ~D[2026-01-15],
        recorded_on: ~D[2026-01-15],
        amount_cents: 50_000,
        period_from: ~D[2026-01-15],
        period_to: ~D[2026-01-22]
      }
    ])

    [n1, n2, n3] = global_numbers(stream)
    %{stream: stream, tid: tid, n1: n1, n2: n2, n3: n3}
  end

  describe "the paginated log view" do
    test "renders the full-history log shell and pager", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/log")

      assert has_element?(view, "#event-log-full")
      assert has_element?(view, "#log-rows")
      assert has_element?(view, "#full-log-caption")
      assert has_element?(view, "#log-pager-top")
      assert has_element?(view, "#log-pager-bottom")
      # A read-only historical browser — never a form/editor.
      refute has_element?(view, "form")
    end

    test "renders an appended event as a row that links to its stream detail", %{conn: conn} do
      %{stream: stream, n2: n2, n3: n3} = seed_stream!(directory: true)

      {:ok, view, _html} = live(conn, ~p"/inspector/log")

      # Newest events show on the head page, tagged by global event number.
      assert has_element?(view, "#log-row-#{n3}", "RentFellDue")
      # The divergent tick flags its bitemporal divergence.
      assert has_element?(view, "#log-divergence-#{n2}")
      # Property-leading identity resolved from the Directory.
      assert has_element?(view, "#log-identity-#{n3}", "42 Wallaby Way, Sydney NSW 2000")
      # A deep row links through scrubbed to the event's exact position: n3 is
      # stream version 3, so the scrubber target is `?at=3` (catches off-by-one).
      assert has_element?(
               view,
               ~s{a#log-row-#{n3}[href="/inspector/streams/#{stream}?at=3"]}
             )
    end

    test "pages back through history and forward again by keyset cursor", %{conn: conn} do
      %{n1: n1, n2: n2, n3: n3} = seed_stream!()

      # Older-than-n3 page excludes n3, includes the two older events.
      {:ok, older, _html} = live(conn, ~p"/inspector/log?#{[before: n3]}")
      refute has_element?(older, "#log-row-#{n3}")
      assert has_element?(older, "#log-row-#{n2}")
      assert has_element?(older, "#log-row-#{n1}")
      # Not at head → a "Newer" pager link is offered.
      assert has_element?(older, "#log-pager-top-newer")

      # Newer-than-n1 page includes the two newer events, excludes n1.
      {:ok, newer, _html} = live(conn, ~p"/inspector/log?#{[after: n1]}")
      assert has_element?(newer, "#log-row-#{n3}")
      assert has_element?(newer, "#log-row-#{n2}")
      refute has_element?(newer, "#log-row-#{n1}")
    end

    test "the Newer pager link patches toward the head", %{conn: conn} do
      %{n2: n2, n3: n3} = seed_stream!()

      {:ok, view, _html} = live(conn, ~p"/inspector/log?#{[before: n2]}")
      refute has_element?(view, "#log-row-#{n3}")

      view |> element("#log-pager-top-newer") |> render_click()

      # After paging newer, the newest event is now visible.
      assert has_element?(view, "#log-row-#{n3}")
    end
  end

  describe "deep-link scrubbing from a log row (?at=)" do
    test "opening a stream at ?at=N highlights that event's position", %{conn: conn} do
      %{stream: stream} = seed_stream!(arrears: true)

      {:ok, view, _html} = live(conn, ~p"/inspector/streams/#{stream}?#{[at: 1]}")

      # The scrubber parks at k=1, marking the first event as the current step.
      assert has_element?(view, ~s{#event-row-#{stream}-1[aria-current="step"]})
      refute has_element?(view, ~s{#event-row-#{stream}-2[aria-current="step"]})
    end
  end

  describe "navigation affordance" do
    test "the workbench header links to the full log", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")
      assert has_element?(view, "#inspector-full-log-link")
    end
  end
end
