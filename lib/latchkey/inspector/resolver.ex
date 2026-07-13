defmodule Latchkey.Inspector.Resolver do
  @moduledoc """
  Shared, read-only **identity + display resolution** for the inspector's event
  views (spec `docs/spec/developer-view.md`, decisions D3/D7/D8).

  Both the per-stream **event-log pane** (`LatchkeyWeb.InspectorLive`, issue #81)
  and the cross-stream **paginated log** (`Latchkey.Inspector.Log`, issue #114)
  resolve the *same* property-leading identity and bitemporal display off the
  *same* primitives here — one home, never two divergent copies.

  Identity is resolved by an **in-Elixir keyed merge** (ADR 0008), never off the
  raw log and never a cross-schema join:

    * the **tenant/property** display comes from the disposable
      `Latchkey.Simulation.Directory`, looked up by `tenancy_id`;
    * the **accounts edge** derives identity from a payment's `holder` (a
      `tenancy_ref`); a reversal inherits the holder of the payment it reverses.

  Unresolvable references honestly render an `UNKNOWN` sentinel (D3) — identity is
  never fabricated. The resolved shape is `%{property, tenant, ref, resolved?}`,
  which the event-row templates render directly.
  """

  alias EventStore.RecordedEvent
  alias Latchkey.Accounts
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Simulation.Directory

  @typedoc "A resolved, property-leading display identity for an event row."
  @type identity :: %{
          property: String.t(),
          tenant: String.t(),
          ref: String.t(),
          resolved?: boolean()
        }

  @doc """
  A disposable, non-PII display lookup keyed by `tenancy_id` (ADR 0008 Directory).
  Read-only; one read builds the map every consuming pane shares.
  """
  @spec directory_map() :: %{
          optional(String.t()) => %{tenant_name: String.t(), property_address: String.t()}
        }
  def directory_map do
    Directory
    |> Ash.read!()
    |> Map.new(fn dir ->
      {dir.tenancy_id, %{tenant_name: dir.tenant_name, property_address: dir.property_address}}
    end)
  end

  @doc """
  `payment_id => holder` over the given recorded events, so a `PaymentReversed`
  (which carries no holder of its own) can inherit the holder of the payment it
  reverses. Events not on the same page simply resolve to `UNKNOWN` (honest).
  """
  @spec payment_holders([RecordedEvent.t()]) :: %{optional(String.t()) => String.t()}
  def payment_holders(recorded) do
    for %RecordedEvent{data: %PaymentReceived{payment_id: payment_id, holder: holder}} <- recorded,
        into: %{},
        do: {payment_id, holder}
  end

  @doc """
  Identity for a `tenancy-<id>` stream event, resolved from the Directory by
  `tenancy_id` (property leading). Unseeded tenancies render `UNKNOWN` (D8): a
  single historical event out of stream context carries no `property_ref`, so the
  cross-stream log leans on the Directory rather than re-resolving per stream.
  """
  @spec tenancy_identity(String.t(), map()) :: identity()
  def tenancy_identity(tenancy_id, directory) do
    case Map.get(directory, tenancy_id) do
      %{tenant_name: tenant, property_address: property} ->
        %{property: property, tenant: tenant, ref: "tenancy-" <> tenancy_id, resolved?: true}

      _ ->
        unknown_identity("tenancy-" <> tenancy_id)
    end
  end

  @doc """
  Identity for an Accounts-edge event. A `PaymentReceived` resolves off its own
  `holder`; a `PaymentReversed` inherits the holder of the payment it reverses
  (via `holders`); anything else resolves `UNKNOWN` (D3).
  """
  @spec accounts_identity(struct(), map(), map()) :: identity()
  def accounts_identity(%PaymentReceived{holder: holder}, directory, _holders) do
    holder_identity(holder, directory)
  end

  def accounts_identity(%{reverses: reverses}, directory, holders) do
    holder_identity(Map.get(holders, reverses), directory)
  end

  def accounts_identity(_data, directory, _holders), do: holder_identity(nil, directory)

  @doc "Resolve a payment `holder` (a `tenancy_ref`) to a display identity, or `UNKNOWN`."
  @spec holder_identity(String.t() | nil, map()) :: identity()
  def holder_identity(holder, directory) do
    with true <- Accounts.known_holder?(holder),
         tenancy_id = String.replace_prefix(holder, "tenancy-", ""),
         %{tenant_name: tenant, property_address: property} <- Map.get(directory, tenancy_id) do
      %{property: property, tenant: tenant, ref: holder, resolved?: true}
    else
      _ -> unknown_identity(holder)
    end
  end

  @doc "The honest `UNKNOWN` sentinel identity — used whenever a ref can't be resolved."
  @spec unknown_identity(String.t() | nil) :: identity()
  def unknown_identity(ref) do
    ref = if is_binary(ref) and ref != "", do: ref, else: "UNKNOWN"
    %{property: "UNKNOWN", tenant: "UNKNOWN", ref: ref, resolved?: false}
  end

  # ── Bitemporal display helpers (D7) ─────────────────────────────────────────

  @doc "The short (last-segment) name of an event struct's module, e.g. `RentFellDue`."
  @spec short_type(struct()) :: String.t()
  def short_type(%module{}), do: module |> Module.split() |> List.last()

  @doc """
  Coerce a stored date value to a `Date` (or nil). Payload columns deserialize
  dates as ISO strings (JSON serializer); coerce so divergence compares real
  dates, not string shapes.
  """
  @spec to_date(term()) :: Date.t() | nil
  def to_date(%Date{} = date), do: date

  def to_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  def to_date(_), do: nil

  @doc "Whether an event's two envelope dates diverge (bitemporal flag, D7)."
  @spec divergent?(Date.t() | nil, Date.t() | nil) :: boolean()
  def divergent?(%Date{} = occurred, %Date{} = recorded),
    do: Date.compare(occurred, recorded) != :eq

  def divergent?(_, _), do: false
end
