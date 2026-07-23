defmodule Latchkey.Simulation.ScheduledEvent do
  @moduledoc """
  The **thin scheduled-event worker** — the Oban job the planner enqueues for each
  future world-line step (ADR 0011 / spec `docs/spec/simulation-engine.md`,
  "plan-once after seed"). One job per step (`payment`, `notice`, `vacate`), scheduled
  at the real-world date it occurs, on the dedicated `:simulation` queue.

  ## A dumb dispatch (issue #158)

  The planner decided *everything* at plan time; a fired job carries its pre-decided
  work in its `args` and does **no** arrears read and **no** run-time decision. When it
  fires it simply reconstitutes that work from those args and drives it through the live
  seam:

    * a `notice`/`vacate` dispatches the pre-decided `GiveTerminationNotice`/`ReturnKeys`
      command through Commanded with `consistency: :strong`, so on return the aggregate
      has folded it. Dispatching `ReturnKeys` at the derived vacate date is all the exit
      lifecycle needs: the aggregate itself catches accrual up to `E`, appends any
      overstay charge, and settles to `Terminal` (spec, "Exit lifecycle needs no new
      machinery").
    * a `payment` is *not* a Commanded command — it is appended to the **Accounts**
      stream (`Accounts.append/2`), where the payment ACL crosses it into PM's
      `RentPaymentRecorded` asynchronously, exactly as any live payment does. No
      synchronous await is needed (the daily sweep reflects it downstream); the
      aggregate/ACL dedupe on `source_payment_id` makes a retry safe.

  ## `recorded_on` is left to default — this fires *live*

  Unlike the seeder, which backdates `recorded_on` to manufacture history, a fired job
  runs on the real-world date the event occurs, so it leaves `recorded_on` nil and lets
  the edge default it to `Clock.today/0` (ADR 0005). Because the job's scheduled instant
  *is* that day, the booking date and the pre-decided occurred date (`given_on` /
  `keys_on` / a payment's `received_on`) coincide — a live same-day booking.

  ## Idempotency lives on the enqueue

  Uniqueness (`{tenancy_id, event, generation}`, no duplicate per plan-run) is enforced by
  the planner at insert time (`Latchkey.Simulation.Planner`), not here — a fired job is
  free to run once its scheduled instant arrives.

  ## The reset-generation staleness guard (issue #162)

  Each job is stamped with the **seed generation** it was planned under
  (`Latchkey.Simulation.SeedGeneration`). Reset advances the generation *before* it purges
  + replans — but a job Oban has already **claimed** (`executing`) is past deletion, so it
  still fires. Before dispatching, this worker compares the job's stamped generation to
  the live one and **no-ops if the stamp is behind**: the command was decided against a
  now-superseded seed, so dispatching it would inject stale work into the fresh world.
  This is the backstop for the already-claimed job; the planner's generation-aware
  uniqueness handles the not-yet-claimed ones. A job whose stamp is current dispatches
  normally, and an unstamped job (none planned before #162 existed) dispatches too.
  """
  use Oban.Worker, queue: :simulation, max_attempts: 3

  alias Latchkey.Accounts
  alias Latchkey.CommandedApp
  alias Latchkey.PropertyManagement.Tenancy.Commands.GiveTerminationNotice
  alias Latchkey.PropertyManagement.Tenancy.Commands.ReturnKeys
  alias Latchkey.Simulation.SeedGeneration

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    cond do
      stale?(args) ->
        # Planned under a superseded seed generation (a reset advanced past it while this
        # job was already claimed): drop the stale work rather than inject it into the
        # fresh world. The completed no-op leaves the fresh generation's replan untouched.
        :ok

      args["event"] == "payment" ->
        # A payment fires *live* through the Accounts edge — appended to the Accounts
        # stream, where the payment ACL crosses it into PM asynchronously, exactly as any
        # live payment does (no synchronous await; the daily sweep reflects it downstream).
        record_payment(args)

      true ->
        args
        |> command()
        |> CommandedApp.dispatch(consistency: :strong)
    end
  end

  # Reconstitute the payment's edge inputs and append it to the Accounts stream. Fires on
  # the received date, so `recorded_on` is left to default to `Clock.today/0` (a live
  # same-day booking, matching this worker's dumb-dispatch contract for notice/vacate).
  defp record_payment(args) do
    %{
      "payment_id" => payment_id,
      "amount_cents" => amount_cents,
      "received_on" => received_on,
      "holder" => holder
    } = args

    payment =
      Accounts.payment_received(%{
        payment_id: payment_id,
        amount_cents: amount_cents,
        received_on: Date.from_iso8601!(received_on),
        holder: holder
      })

    Accounts.append(payment, stream: Map.get(args, "accounts_stream", "accounts"))
  end

  # A job is stale iff its stamped generation is *behind* the live one — the generation
  # only ever advances, so anything below current is superseded. An unstamped job (planned
  # before the generation existed) is treated as live.
  defp stale?(%{"generation" => generation}) when is_integer(generation) do
    generation < SeedGeneration.current()
  end

  defp stale?(_args), do: false

  # Reconstitute the pre-decided command from the job's args — dates parsed back from the
  # ISO strings the planner stamped in. No arrears read, no decision: the args *are* the
  # decision (issue #158).
  defp command(%{
         "event" => "notice",
         "tenancy_id" => tenancy_id,
         "given_on" => given_on,
         "termination_date" => termination_date,
         "as_of" => as_of
       }) do
    %GiveTerminationNotice{
      tenancy_id: tenancy_id,
      given_on: Date.from_iso8601!(given_on),
      termination_date: Date.from_iso8601!(termination_date),
      as_of: Date.from_iso8601!(as_of)
    }
  end

  defp command(%{"event" => "vacate", "tenancy_id" => tenancy_id, "keys_on" => keys_on}) do
    %ReturnKeys{tenancy_id: tenancy_id, keys_on: Date.from_iso8601!(keys_on)}
  end
end
