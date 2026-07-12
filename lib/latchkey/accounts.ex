defmodule Latchkey.Accounts do
  @moduledoc """
  Accounts bounded context (domain-model.md §2/§3) — the thin **upstream edge /
  stub** that owns payment facts. It emits exactly two tenancy-attributed events —
  `PaymentReceived` and its compensating `PaymentReversed` — to its own append-only
  stream, and nothing else is modelled (no trust ledger, no disbursement). There is
  no reallocation event: reallocation is a reversal on the wrong holder plus a fresh
  `PaymentReceived` on the right one (correction by compensation, never mutation).

  This is the *source* the tenant-behaviour engine writes to; PM consumes these
  facts through ACL-1 (a later issue), translating *payment* into *arrears*.

  ## Bitemporal envelope (ADR 0006 decision 4)

  Every event carries the uniform envelope `{occurred_on, recorded_on}`.
  `occurred_on` is the fact's real-world date (here the received / reversed date);
  `recorded_on` is the booking date, sourced from `Latchkey.Clock.today()` at this
  edge when the caller omits it (ADR 0005 decision 2 — the one live wall-clock
  read-site), overridable for seeding and tests. The append **inputs** keep the
  domain-named dates (`received_on`, `reversed_on`); the persisted **events** carry
  the uniform `occurred_on`.

  ## `holder`

  `holder = tenancy_ref | UNKNOWN`. `UNKNOWN` (the `unknown_holder/0` sentinel) is
  *representable* here — Accounts may book money it can't yet attribute — but it
  **must never cross the seam** into PM. ACL-1 refuses to translate an
  UNKNOWN-held payment (enforced downstream in a later issue); this context only
  keeps it representable and documents the rule (`known_holder?/1`).
  """
  alias EventStore.EventData
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Accounts.Events.PaymentReversed
  alias Latchkey.Clock

  @stream "accounts"
  @unknown_holder "UNKNOWN"

  @typedoc "A payment holder: a tenancy reference, or the `UNKNOWN` sentinel."
  @type holder :: String.t()

  # ── holder / UNKNOWN seam rule ────────────────────────────────────────────────

  @doc "The sentinel `holder` for money Accounts cannot yet attribute to a tenancy."
  @spec unknown_holder() :: holder()
  def unknown_holder, do: @unknown_holder

  @doc """
  Whether a `holder` is attributable — a real `tenancy_ref`, and therefore safe to
  cross the seam. The `UNKNOWN` sentinel (and any blank value) is not; ACL-1 refuses
  it downstream.
  """
  @spec known_holder?(term()) :: boolean()
  def known_holder?(@unknown_holder), do: false
  def known_holder?(holder) when is_binary(holder) and holder != "", do: true
  def known_holder?(_holder), do: false

  # ── builders (edge inputs → event structs with the uniform envelope) ──────────

  @doc """
  Build a `PaymentReceived` from edge inputs (`payment_id`, `amount_cents`,
  `received_on`, `holder`, optional `recorded_on`). `received_on` becomes the
  event's `occurred_on`; `recorded_on` defaults to `Clock.today()`.
  """
  @spec payment_received(map()) :: PaymentReceived.t()
  def payment_received(%{} = attrs) do
    %PaymentReceived{
      payment_id: fetch!(attrs, :payment_id),
      amount_cents: positive!(fetch!(attrs, :amount_cents)),
      occurred_on: fetch!(attrs, :received_on),
      recorded_on: booked_on(Map.get(attrs, :recorded_on)),
      holder: fetch!(attrs, :holder)
    }
  end

  @doc """
  Build a compensating `PaymentReversed` from edge inputs (`payment_id`,
  `reverses`, negative `amount_cents`, `reversed_on`, `reason`, optional
  `recorded_on`). `reversed_on` becomes the event's `occurred_on`; `recorded_on`
  defaults to `Clock.today()`.
  """
  @spec payment_reversed(map()) :: PaymentReversed.t()
  def payment_reversed(%{} = attrs) do
    %PaymentReversed{
      payment_id: fetch!(attrs, :payment_id),
      reverses: fetch!(attrs, :reverses),
      amount_cents: negative!(fetch!(attrs, :amount_cents)),
      occurred_on: fetch!(attrs, :reversed_on),
      recorded_on: booked_on(Map.get(attrs, :recorded_on)),
      reason: fetch!(attrs, :reason)
    }
  end

  # ── the minimal append API ────────────────────────────────────────────────────

  @doc """
  Append one event (or a list of events) to the Accounts stream. Returns `:ok` or
  `{:error, reason}` from the EventStore.

  The stream name is overridable via the `:stream` option for test isolation (the
  Commanded EventStore runs outside the Ecto sandbox, so tests key it uniquely).
  Uses `:any_version` — Accounts is an append-only source with no write-side
  invariant of its own to protect with optimistic concurrency.
  """
  @spec append(struct() | [struct()], keyword()) :: :ok | {:error, term()}
  def append(events, opts \\ []) do
    stream = Keyword.get(opts, :stream, @stream)
    data = events |> List.wrap() |> Enum.map(&to_event_data/1)
    Latchkey.EventStore.append_to_stream(stream, :any_version, data)
  end

  defp to_event_data(%module{} = event) do
    %EventData{event_type: Atom.to_string(module), data: event, metadata: %{}}
  end

  # The single live wall-clock read-site for this edge: default the booking date
  # from the Clock when the caller omits it; take it verbatim otherwise.
  defp booked_on(%Date{} = d), do: d
  defp booked_on(nil), do: Clock.today()

  defp fetch!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required key #{inspect(key)}"
    end
  end

  # Sign invariants that keep the ledger honest: a receipt is a positive credit,
  # a reversal is a negative (compensating) entry. Enforced at the builder so a
  # "negative receipt" or "positive reversal" can never reach the stream.
  defp positive!(amount) when is_integer(amount) and amount > 0, do: amount

  defp positive!(amount),
    do:
      raise(
        ArgumentError,
        "PaymentReceived amount_cents must be positive, got #{inspect(amount)}"
      )

  defp negative!(amount) when is_integer(amount) and amount < 0, do: amount

  defp negative!(amount),
    do:
      raise(
        ArgumentError,
        "PaymentReversed amount_cents must be negative (compensating), got #{inspect(amount)}"
      )
end
