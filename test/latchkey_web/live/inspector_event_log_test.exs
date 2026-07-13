defmodule LatchkeyWeb.InspectorEventLogTest do
  @moduledoc """
  Tests for the read-only **event-log pane** (issue #81, spec developer-view.md
  D3/D7): a selected stream's raw events, rendered chronologically with full
  payloads, both envelope dates + a divergence flag, and property-leading identity.
  The same pane renders the `accounts` stream events-only (the Accounts edge, D3).

  Drives the real Postgres `EventStore` (events appended directly, mirroring the
  `Latchkey.Accounts` append seam) and asserts on stable DOM ids, never raw HTML,
  per the repo's LiveView testing guidelines. `async: false` — the EventStore runs
  outside the Ecto sandbox, so the shared read connection must see the Directory.
  """
  use LatchkeyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EventStore.EventData
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced
  alias Latchkey.Simulation.Directory
  alias Latchkey.Simulation.Identity

  # The pane reads the raw Postgres EventStore; start it (Commanded is disabled in
  # :test). Not sandboxed — streams are keyed uniquely / read back by version.
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

  defp put_directory!(tenancy_id, name, address) do
    Directory
    |> Ash.Changeset.for_create(:upsert, %{
      tenancy_id: tenancy_id,
      tenant_name: name,
      property_address: address
    })
    |> Ash.create!()
  end

  # Append raw events to a stream, mirroring `Latchkey.Accounts.to_event_data/1`
  # (the JSON serializer keys deserialization off `event_type`). The EventStore is
  # not sandboxed, so callers key streams uniquely (or read back actual versions).
  defp append!(stream_id, events) do
    data =
      events
      |> List.wrap()
      |> Enum.map(fn %mod{} = e ->
        %EventData{event_type: Atom.to_string(mod), data: e, metadata: %{}}
      end)

    :ok = EventStore.append_to_stream(stream_id, :any_version, data)
  end

  # Actual per-stream versions of appended events, keyed by a payload field, so the
  # accounts assertions are robust to whatever else shares the global `accounts`
  # stream in the run.
  defp versions_by(stream_id, key) do
    case EventStore.stream_forward(stream_id) do
      {:error, :stream_not_found} -> %{}
      events -> Map.new(events, fn r -> {Map.get(r.data, key), r.stream_version} end)
    end
  end

  describe "tenancy stream event-log pane" do
    setup %{conn: conn} do
      tid = "log-" <> uniq()
      stream = "tenancy-" <> tid
      pref = "prop-" <> tid
      put_arrears!(%{tenancy_id: tid, status: :active})

      append!(stream, [
        %TenancyCommenced{
          tenancy_id: tid,
          property_ref: pref,
          occurred_on: ~D[2026-01-01],
          recorded_on: ~D[2026-01-01],
          rent_amount_cents: 50_000,
          cycle: :weekly,
          first_due_date: ~D[2026-01-08]
        },
        # An imported tick (#117): recorded_on lags occurred_on → divergent.
        %RentFellDue{
          tenancy_id: tid,
          occurred_on: ~D[2026-01-08],
          recorded_on: ~D[2026-01-20],
          amount_cents: 50_000,
          period_from: ~D[2026-01-08],
          period_to: ~D[2026-01-15]
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/inspector/streams/#{stream}")
      %{view: view, tid: tid, stream: stream, pref: pref}
    end

    test "renders events chronologically with their types by stable DOM id", %{
      view: view,
      stream: stream
    } do
      assert has_element?(view, "#event-log")
      assert has_element?(view, "#event-row-#{stream}-1", "TenancyCommenced")
      assert has_element?(view, "#event-row-#{stream}-2", "RentFellDue")
    end

    test "shows both envelope dates and flags divergence only where they differ", %{
      view: view,
      stream: stream
    } do
      # The commencement row's dates coincide → no divergence flag.
      refute has_element?(view, "#event-divergence-#{stream}-1")
      # The lagged accrual tick's dates diverge → flag present.
      assert has_element?(view, "#event-divergence-#{stream}-2")
      # A thin bitemporal caption with a read-more link to domain-model.md §3.
      assert has_element?(view, "#bitemporal-caption")
      assert view |> element("#event-log a[href*='domain-model.md']") |> has_element?()
    end

    test "renders the full stored payload of an event", %{view: view, stream: stream} do
      # The RentFellDue period bounds are part of the raw payload.
      assert has_element?(view, "#event-row-#{stream}-2", "2026-01-15")
      assert has_element?(view, "#event-row-#{stream}-2", "50000")
    end

    test "names property and tenant on each row (property leading)", %{
      view: view,
      stream: stream,
      tid: tid,
      pref: pref
    } do
      %{property_address: address, tenant_name: name} = Identity.resolve(tid, pref)

      assert has_element?(view, "#event-identity-#{stream}-1", address)
      assert has_element?(view, "#event-identity-#{stream}-1", name)
    end

    test "is read-only — no form, no edit/delete affordance, no 'tamper-evident' claim", %{
      view: view
    } do
      refute has_element?(view, "form")
      assert has_element?(view, "#immutability-note")
      assert has_element?(view, "#immutability-note", "append-only")
      refute render(view) =~ "tamper-evident"
    end
  end

  describe "accounts stream event-log pane (edge, events-only)" do
    test "renders the accounts stream events-only with the edge caption", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/streams/accounts")

      assert has_element?(view, "#event-log")
      # D3: names it an edge context that folds no aggregate state.
      assert has_element?(view, "#accounts-edge-caption")
    end

    test "resolves a known holder's identity and shows UNKNOWN honestly otherwise", %{conn: conn} do
      tid = "acct-" <> uniq()
      put_directory!(tid, "Jane Tenant", "42 Wallaby Way, Sydney")

      known_pid = "pmt-known-" <> uniq()
      unknown_pid = "pmt-unknown-" <> uniq()

      append!("accounts", [
        %PaymentReceived{
          payment_id: known_pid,
          amount_cents: 50_000,
          occurred_on: ~D[2026-02-01],
          recorded_on: ~D[2026-02-03],
          holder: "tenancy-" <> tid
        },
        %PaymentReceived{
          payment_id: unknown_pid,
          amount_cents: 20_000,
          occurred_on: ~D[2026-02-05],
          recorded_on: ~D[2026-02-05],
          holder: "UNKNOWN"
        }
      ])

      versions = versions_by("accounts", :payment_id)
      v_known = Map.fetch!(versions, known_pid)
      v_unknown = Map.fetch!(versions, unknown_pid)

      {:ok, view, _html} = live(conn, ~p"/inspector/streams/accounts")

      assert has_element?(view, "#event-row-accounts-#{v_known}", "PaymentReceived")
      # Known holder → resolved property/tenant from the Directory (property leading).
      assert has_element?(view, "#event-identity-accounts-#{v_known}", "42 Wallaby Way, Sydney")
      assert has_element?(view, "#event-identity-accounts-#{v_known}", "Jane Tenant")
      # Unresolvable holder → honest UNKNOWN sentinel, never fabricated identity.
      assert has_element?(view, "#event-identity-accounts-#{v_unknown}", "UNKNOWN")
      # A divergent known payment (received vs booked) flags on its own row.
      assert has_element?(view, "#event-divergence-accounts-#{v_known}")
    end
  end
end
