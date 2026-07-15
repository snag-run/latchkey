defmodule Latchkey.Simulation.WorldLine do
  @moduledoc """
  The **world-line** — a *pure* function that turns a scenario (tenant profile +
  payment schedule + agent archetype) into the **full dated event list**, past and
  future (ADR 0011 / spec `docs/spec/simulation-engine.md`). It is the seam the rest
  of the ambient-simulation feature consumes: the seeder replays the `≤ today` slice
  as backhistory, the planner schedules the `> today` slice — one derivation cut at a
  different date, not two code paths.

  ## What it derives

    * **Payments** come straight from the tenant behaviour engine
      (`Latchkey.Simulation.Behaviour.payments/2`) — the one simulated actor.
    * **Agent events are derived, not planted.** Folding the same payments and the
      schedule's due dates gives the arrears trajectory (`days_behind` over time,
      mirroring `Latchkey.PropertyManagement.Tenancy.oldest_unpaid_due_date/1`); the
      agent archetype's threshold picks the day it crosses, and that is the notice date.
      From it: termination date `E = notice_date + 14` (s88 statutory minimum) and
      vacate/exit date `V = E + overstay`. A tenant who never crosses the threshold
      gets neither.

  ## Deterministic, no infrastructure

  Every input is explicit — no Oban, no dispatch, no `Latchkey.Clock`, no runtime RNG —
  so the same `(profile, schedule, agent)` always yields byte-identical output,
  including a re-plan reproducing the same schedule (spec testing decisions). The steps
  match `Latchkey.Simulation.Seeder.Projection`'s shape (`{:payment, ...}`,
  `{:notice, ...}`, `{:exit, ...}`) so the derived list drops straight into the
  existing dispatch order.

  `property_ref` is **identity only** (ADR 0008): it labels which premises the derived
  events attach to and is never a behavioural input, so the derivation tuple stays
  `(tenant archetype × agent archetype × commence date)` — the commence date rides in
  via the schedule's first due date. It is therefore *not* an argument here.
  """

  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Simulation.Behaviour
  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Schedule
  alias Latchkey.Simulation.WorldLine.Agent

  # s88 statutory minimum: the termination date E is 14 days after the notice is served.
  @statutory_notice_days 14

  @typedoc "The termination notice the agent derives — mirrors `Seeder.Scenario.notice/0`."
  @type notice :: %{given_on: Date.t(), termination_date: Date.t(), as_of: Date.t()}

  @typedoc "The keys-return the tenant derives — mirrors `Seeder.Scenario.exit_step/0`."
  @type exit_step :: %{keys_on: Date.t()}

  @typedoc "A dated world-line step, in `Seeder.Projection.step/0` shape."
  @type step ::
          {:payment, PaymentReceived.t()}
          | {:notice, notice()}
          | {:exit, exit_step()}

  @doc """
  The full dated event list for a scenario: the tenant's payments merged with the
  agent's derived notice and the tenant's derived vacate, each paired with its
  real-world date and sorted oldest-first.

  On a shared date the order is notice → payment → exit (a notice folds before a
  same-day payment; keys are returned after one), matching
  `Latchkey.Simulation.Seeder.Projection.dated_timeline/2`. When the tenant never
  crosses the agent's threshold, the result is payments only.
  """
  @spec events(Profile.t(), Schedule.t(), Agent.t()) :: [{Date.t(), step()}]
  def events(%Profile{} = profile, %Schedule{} = schedule, %Agent{} = agent) do
    payments = Behaviour.payments(profile, schedule)

    payment_steps =
      Enum.map(payments, fn %PaymentReceived{} = p -> {p.occurred_on, 1, {:payment, p}} end)

    (payment_steps ++ agent_steps(schedule, payments, agent))
    |> Enum.sort_by(fn {date, tiebreak, _step} -> {Date.to_erl(date), tiebreak} end)
    |> Enum.map(fn {date, _tiebreak, step} -> {date, step} end)
  end

  # The derived notice + exit for the scenario, or `[]` when the tenant never crosses
  # the agent's threshold. `V = E + overstay`, `E = notice_date + 14`.
  defp agent_steps(%Schedule{periods: periods}, payments, %Agent{} = agent) do
    case notice_date(periods, payments, agent.threshold_days) do
      nil ->
        []

      given_on ->
        termination_date = Date.add(given_on, @statutory_notice_days)
        keys_on = Date.add(termination_date, agent.overstay_days)

        [
          {given_on, 0,
           {:notice, %{given_on: given_on, termination_date: termination_date, as_of: given_on}}},
          {keys_on, 2, {:exit, %{keys_on: keys_on}}}
        ]
    end
  end

  # ── deriving the notice date from the arrears trajectory ──────────────────────

  # The first date `days_behind` reaches `threshold_days`, or `nil` if it never does.
  #
  # `oldest_unpaid_due_date` only ever advances (payments clear periods FIFO; a new
  # period is appended after the existing charges), so between two "change points" — a
  # due date falling or a payment landing — it is constant and `days_behind` grows
  # linearly. So we evaluate the oldest-unpaid at each change point and find the first
  # segment in which `oldest + threshold_days` actually lands, taking the earliest. The
  # open-ended tail segment (`:infinity`) catches a crossing after the last change point
  # — a permanently-behind tenant whose arrears keep climbing past the final due date.
  defp notice_date(periods, payments, threshold_days) do
    change_points =
      (Enum.map(periods, & &1.due_on) ++ Enum.map(payments, & &1.occurred_on))
      |> Enum.uniq()
      |> Enum.sort(Date)

    change_points
    |> Enum.zip(tl(change_points) ++ [:infinity])
    |> Enum.find_value(fn {start_on, next_on} ->
      case oldest_unpaid_on(periods, payments, start_on) do
        nil -> nil
        oldest -> crossing_in_segment(oldest, threshold_days, start_on, next_on)
      end
    end)
  end

  # Within `[start_on, next_on)` the oldest-unpaid is fixed, so the crossing is
  # `oldest + threshold_days` — clamped up to `start_on` when the segment opens already
  # past the threshold (a late payment having just revealed an old period as oldest).
  # Valid only if it lands before the segment closes; otherwise a later segment owns it.
  defp crossing_in_segment(oldest, threshold_days, start_on, next_on) do
    candidate = later(start_on, Date.add(oldest, threshold_days))

    cond do
      next_on == :infinity -> candidate
      Date.before?(candidate, next_on) -> candidate
      true -> nil
    end
  end

  # Mirrors `Tenancy.oldest_unpaid_due_date/1`: the earliest due date whose *cumulative*
  # charge exceeds *cumulative* payments (FIFO), counting only periods due and payments
  # received on or before `date`. `nil` when square. Keeping this in lock-step with the
  # aggregate is what makes the derived notice pass the same L7 gate downstream.
  defp oldest_unpaid_on(periods, payments, date) do
    paid =
      payments
      |> Enum.filter(&(Date.compare(&1.occurred_on, date) != :gt))
      |> Enum.reduce(0, &(&2 + &1.amount_cents))

    periods
    |> Enum.filter(&(Date.compare(&1.due_on, date) != :gt))
    |> Enum.reduce_while(0, fn %{due_on: due_on, amount_cents: amount}, cumulative ->
      cumulative = cumulative + amount
      if cumulative > paid, do: {:halt, due_on}, else: {:cont, cumulative}
    end)
    |> case do
      %Date{} = due_on -> due_on
      _cumulative -> nil
    end
  end

  defp later(a, b), do: if(Date.after?(a, b), do: a, else: b)
end
