defmodule Latchkey.Simulation.Seeder.Projection do
  @moduledoc """
  The **pure** as-of-today projection for a seed scenario — the single source of truth
  for a scenario's `:expected` read-model state.

  It reconstructs the scenario's events by driving the *real* `Tenancy` domain
  (`decide_*` + `evolve`, framework-free) through exactly the command sequence the
  live seeder dispatches — commence → the tenant's engine payments (translated by the
  real ACL-1) merged with any planted notice/exit → a closing sweep as-of `today` —
  then derives `{status, balance_cents, oldest_unpaid_due_date, days_behind}` off the
  folded state. Because it reuses the same domain functions the aggregate runs, the
  derived `expected` **cannot drift** from what the live seam produces; the seeder
  integration test proves the two agree on a representative sample.

  It also owns the scenario **timeline** — the chronological merge of payments, notice
  and exit — which the live seeder consumes for its dispatch order, so ordering lives
  in one place too.
  """

  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.PropertyManagement.PaymentAcl
  alias Latchkey.PropertyManagement.Tenancy
  alias Latchkey.PropertyManagement.Tenancy.Commands.RecordPayment
  alias Latchkey.Simulation.Behaviour
  alias Latchkey.Simulation.Schedule
  alias Latchkey.Simulation.Seeder.Scenario

  @typedoc "A non-commence, non-sweep timeline step, ordered by real-world date."
  @type step ::
          {:payment, PaymentReceived.t()}
          | {:notice, Scenario.notice()}
          | {:exit, Scenario.exit_step()}

  @doc """
  The chronologically-ordered timeline of the scenario's engine payments (by received
  date) merged with any planted notice (by given date) and exit (by keys-return date).

  On a shared date the order is notice → payment → exit, so a notice folds before a
  same-day payment and keys are returned after a same-day payment (defensive; the
  catalogue plants no such ties). `tenancy_id` is the (already-prefixed) id whose
  `tenancy_ref` the engine attributes payments to.
  """
  @spec timeline(Scenario.t(), String.t()) :: [step()]
  def timeline(%Scenario{} = scenario, tenancy_id) do
    payment_steps =
      scenario.profile
      |> Behaviour.payments(schedule(scenario, tenancy_id))
      |> Enum.map(fn %PaymentReceived{} = p -> {p.occurred_on, 1, {:payment, p}} end)

    notice_steps =
      case scenario.notice do
        nil -> []
        %{given_on: given_on} = notice -> [{given_on, 0, {:notice, notice}}]
      end

    exit_steps =
      case scenario.exit do
        nil -> []
        %{keys_on: keys_on} = exit -> [{keys_on, 2, {:exit, exit}}]
      end

    (payment_steps ++ notice_steps ++ exit_steps)
    |> Enum.sort_by(fn {date, tiebreak, _step} -> {Date.to_erl(date), tiebreak} end)
    |> Enum.map(fn {_date, _tiebreak, step} -> step end)
  end

  @doc """
  The weekly payment schedule the behaviour engine folds over for `scenario`, keyed to
  `tenancy_id`'s `tenancy_ref`.
  """
  @spec schedule(Scenario.t(), String.t()) :: Schedule.t()
  def schedule(%Scenario{} = scenario, tenancy_id) do
    Schedule.weekly(
      "tenancy-" <> tenancy_id,
      scenario.first_due_date,
      scenario.rent_amount_cents,
      scenario.schedule_count
    )
  end

  @doc """
  Derive the scenario's intended as-of-`today` read-model state by folding its
  reconstructed events through the real `Tenancy` domain. Raises with context if any
  planted step is domain-invalid (e.g. a notice that fails the L7 arrears gate) — so a
  mis-generated scenario fails loudly at catalogue-build time rather than crashing the
  live seed.
  """
  @spec derive(Scenario.t(), Date.t()) :: Scenario.expected()
  def derive(%Scenario{} = scenario, %Date{} = today) do
    core =
      Tenancy.initial_state()
      |> apply_commence(scenario)
      |> apply_steps(timeline(scenario, scenario.tenancy_id))
      |> apply_sweep(today)

    %{
      status: core.status,
      balance_cents: Tenancy.balance_cents(core),
      oldest_unpaid_due_date: Tenancy.oldest_unpaid_due_date(core),
      days_behind: Tenancy.days_behind(core, today)
    }
  end

  # ── driving the pure core ─────────────────────────────────────────────────────

  defp apply_commence(core, %Scenario{} = scenario) do
    cmd = %{
      tenancy_id: scenario.tenancy_id,
      property_ref: scenario.property_ref,
      rent_amount_cents: scenario.rent_amount_cents,
      cycle: :weekly,
      first_due_date: scenario.first_due_date,
      recorded_on: scenario.first_due_date
    }

    apply_decision(core, Tenancy.decide_commence(core, cmd), {:commence, scenario.tenancy_id})
  end

  defp apply_steps(core, steps), do: Enum.reduce(steps, core, &apply_step/2)

  defp apply_step({:payment, %PaymentReceived{} = payment}, core) do
    # Translate through the *real* ACL-1 so the reconstructed command is byte-identical
    # to the live seam's (holder-strip, date coercion, idempotency key).
    {:ok, %RecordPayment{} = command} = PaymentAcl.translate(payment)

    cmd = %{
      amount_cents: command.amount_cents,
      received_on: command.received_on,
      source_payment_id: command.source_payment_id,
      recorded_on: command.recorded_on
    }

    apply_decision(core, Tenancy.decide_payment(core, cmd), {:payment, command.source_payment_id})
  end

  defp apply_step({:notice, notice}, core) do
    cmd = %{
      termination_date: notice.termination_date,
      given_on: notice.given_on,
      as_of: notice.as_of,
      recorded_on: notice.given_on
    }

    apply_decision(core, Tenancy.decide_termination(core, cmd), {:notice, notice})
  end

  defp apply_step({:exit, exit}, core) do
    cmd = %{keys_on: exit.keys_on, recorded_on: exit.keys_on}
    apply_decision(core, Tenancy.decide_return_keys(core, cmd), {:exit, exit})
  end

  defp apply_sweep(core, today) do
    apply_decision(
      core,
      Tenancy.decide_catch_up(core, %{as_of: today, recorded_on: today}),
      :sweep
    )
  end

  # Fold the decided events into the core, or raise with the offending step's context.
  defp apply_decision(core, {:ok, events}, _context),
    do: Enum.reduce(events, core, &Tenancy.evolve(&2, &1))

  defp apply_decision(_core, {:error, reason}, context) do
    raise ArgumentError,
          "Seeder scenario has a domain-invalid step #{inspect(context)}: #{inspect(reason)}"
  end
end
