defmodule Latchkey.PropertyManagement.PaymentAcl do
  @moduledoc """
  ACL-1, forward path (domain-model.md §8) — Property Management's anti-corruption
  layer over the **Accounts** stream. It translates an Accounts `PaymentReceived`
  fact into PM's own language by dispatching a `RecordPayment` command, whose
  aggregate emits `RentPaymentRecorded`. Accounts speaks *payments*; PM speaks
  *arrears* — this seam is where one becomes the other.

  ## Why a checkpointed policy, not a projection

  Unlike a side-effect-free projection (e.g. `ArrearsProjector`, which only refolds
  and upserts a read model), this handler has a **side effect**: it emits a new
  event. So it cannot be blindly re-run. It keeps its **own checkpoint** over the
  event store (the checkpoint a `Commanded.Event.Handler` persists under its `name`,
  resuming there on restart), and it is **idempotent on `source_payment_id`** — the
  `Tenancy` aggregate's `decide_payment` already no-ops a `source_payment_id` it has
  seen. On a replay the already-emitted `RentPaymentRecorded` is simply **re-folded**
  into the aggregate, never re-translated. This is the one place the "consumers
  translate; projections stay pure" discipline (§2) is deliberately bent; the
  checkpoint plus the idempotency key are what make the side effect replay-safe.

  ## Seam rules

  - Fires **only for tenancy-attributed receipts**. The `UNKNOWN` holder sentinel
    (and any holder that is not a well-formed `tenancy_ref`) never crosses the seam —
    PM's arrears is never polluted by unmatched money (`Accounts.known_holder?/1`).
  - `holder` is a `tenancy_ref` (`"tenancy-" <> tenancy_id`, the aggregate's stream
    identity); ACL-1 strips the prefix to recover the bare `tenancy_id` the
    `RecordPayment` command carries.
  - A receipt whose target tenancy PM cannot record against (e.g. never commenced)
    is **logged and skipped**, not retried forever — a single mis-attributed fact
    must not wedge the subscription.

  This module owns only the **forward** path (`PaymentReceived → RentPaymentRecorded`).
  The reversal path (`PaymentReversed → negative RentPaymentRecorded`) is a separate
  ticket; §10's "not seen yet vs never coming" reversal-ordering wrinkle is deferred.
  """
  use Commanded.Event.Handler,
    application: Latchkey.CommandedApp,
    name: __MODULE__,
    consistency: :eventual,
    start_from: :origin

  require Logger

  alias Latchkey.Accounts
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.CommandedApp
  alias Latchkey.PropertyManagement.Tenancy.Commands.RecordPayment

  @ref_prefix "tenancy-"

  # ── the policy (event in → command dispatched) ────────────────────────────────

  @impl Commanded.Event.Handler
  def handle(%PaymentReceived{} = event, _metadata) do
    case translate(event) do
      {:ok, %RecordPayment{} = command} ->
        dispatch(command)

      :skip ->
        :ok

      # A structurally-invalid date can never parse on retry, so it is non-retryable:
      # log and advance the checkpoint rather than wedge the subscription forever.
      {:error, :malformed_date} ->
        Logger.warning(
          "ACL-1 skipped payment #{inspect(event.payment_id)}: malformed date " <>
            "(occurred_on=#{inspect(event.occurred_on)}, recorded_on=#{inspect(event.recorded_on)})"
        )

        :ok
    end
  end

  defp dispatch(%RecordPayment{source_payment_id: id, tenancy_id: tid} = command) do
    case CommandedApp.dispatch(command) do
      :ok ->
        :ok

      # KNOWN, non-retryable business rejection: `decide_payment` returns `:not_active`
      # when the target tenancy can't accept the payment (never commenced / already
      # ended). Log and skip — advancing the checkpoint keeps the subscription alive,
      # and the aggregate's own idempotency makes a re-seen payment a harmless no-op.
      {:error, :not_active} ->
        Logger.warning("ACL-1 skipped payment #{inspect(id)} for #{inspect(tid)}: :not_active")

        :ok

      # Anything else (dispatch/consistency timeout, infrastructure failure) may be
      # transient: return the error so Commanded does NOT advance the checkpoint and the
      # handler retries — a dropped payment must never happen on a recoverable failure.
      {:error, reason} = error ->
        Logger.error(
          "ACL-1 retrying payment #{inspect(id)} for #{inspect(tid)}: #{inspect(reason)}"
        )

        error
    end
  end

  # ── pure translation (Accounts fact → PM command) ─────────────────────────────

  @doc """
  Translate a `PaymentReceived` fact into a `RecordPayment` command, `:skip` when the
  money must not cross the seam (an `UNKNOWN`/blank holder, or a holder that is not a
  well-formed `tenancy_ref`), or `{:error, :malformed_date}` when a carried date is not
  a `%Date{}` nor a parseable ISO-8601 string.

  Pure and total: it coerces the ISO-string dates the JSON serializer returns on
  replay back to `Date`, so the same call is deterministic live and on re-read.
  `Accounts` does not validate those strings, so a structurally-invalid date is
  reported (not raised) and handled as a non-retryable skip at the call site.
  """
  @spec translate(PaymentReceived.t()) ::
          {:ok, RecordPayment.t()} | :skip | {:error, :malformed_date}
  def translate(%PaymentReceived{holder: holder} = event) do
    with true <- Accounts.known_holder?(holder),
         {:ok, tenancy_id} <- ref_to_tenancy_id(holder),
         {:ok, received_on} <- to_date(event.occurred_on),
         {:ok, recorded_on} <- to_date(event.recorded_on) do
      {:ok,
       %RecordPayment{
         tenancy_id: tenancy_id,
         amount_cents: event.amount_cents,
         received_on: received_on,
         recorded_on: recorded_on,
         source_payment_id: event.payment_id
       }}
    else
      false -> :skip
      :error -> :skip
      {:error, :malformed_date} = err -> err
    end
  end

  # `holder` is a `tenancy_ref` ("tenancy-<id>"); recover the bare `tenancy_id`.
  # Anything without the prefix (or empty after it) is not a tenancy — refuse.
  defp ref_to_tenancy_id(@ref_prefix <> id) when id != "", do: {:ok, id}
  defp ref_to_tenancy_id(_holder), do: :error

  # JSON rehydration returns ISO strings for Dates on replay — coerce back without
  # raising, since `PaymentReceived` does not validate its date strings.
  defp to_date(%Date{} = d), do: {:ok, d}
  defp to_date(nil), do: {:ok, nil}

  defp to_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, %Date{} = d} -> {:ok, d}
      {:error, _reason} -> {:error, :malformed_date}
    end
  end

  defp to_date(_other), do: {:error, :malformed_date}
end
