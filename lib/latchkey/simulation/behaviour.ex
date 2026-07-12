defmodule Latchkey.Simulation.Behaviour do
  @moduledoc """
  The tenant behaviour engine — the one simulated actor (ADR 0005 decision 8). A
  **pure** function `(profile, schedule, date) → maybe PaymentReceived` that turns a
  deterministic archetype (`Latchkey.Simulation.Behaviour.Profile`) and a payment
  `Latchkey.Simulation.Schedule` into `Latchkey.Accounts.Events.PaymentReceived`
  facts. Those facts are appended to the Accounts stream and cross ACL-1 into PM's
  `RentPaymentRecorded` — the engine itself never touches infrastructure, the event
  store, or the `Latchkey.Clock`.

  Determinism is the whole point: the *same* function runs over past dates (seeding
  backhistory) and over `Clock.today()` (the live loop), so seeded history is
  byte-identical to what the live loop would have produced (ADR 0005 decision 8 /
  spec user story 21). Every input is explicit — no wall-clock read, no RNG state —
  so a `(profile, schedule)` pair always yields the same payment sequence.

  ## API

    * `payments/2` — the full ordered sequence of `PaymentReceived` the tenant makes
      over the whole schedule (missed periods produce nothing). This is the primary
      surface for seeding and for Seam-1 tests.
    * `decide/3` — the live per-day call: the single payment (if any) whose received
      date is `date`, else `nil`. The engine's archetypes and builders guarantee at
      most one payment per date, so this is a genuine *maybe*.

  ## `payment_id` and idempotency

  Each period yields a stable `payment_id` of `"<holder>-pmt-<index>"`. Because the
  id is a pure function of the schedule (not of wall-clock or RNG), re-running the
  engine (a seed re-run, a replay) re-emits the *same* ids — and ACL-1 / the
  aggregate dedupe on `source_payment_id`, so a re-emitted payment re-folds rather
  than double-booking.

  ## `recorded_on`

  A tenant payment is a **live** fact: it is booked the day it is received, so the
  engine sets `recorded_on = received date`. Under seeding, that received date is a
  historical date, which is exactly the seeder-assigned `recorded_on` the envelope
  expects for backhistory (`CONTEXT.md`, the three time axes).
  """

  alias Latchkey.Accounts
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Schedule

  @doc """
  The full ordered sequence of `PaymentReceived` facts the tenant makes over
  `schedule`, given `profile`. Missed periods contribute nothing; the result is
  sorted by received date.
  """
  @spec payments(Profile.t(), Schedule.t()) :: [PaymentReceived.t()]
  def payments(%Profile{} = profile, %Schedule{holder: holder, periods: periods}) do
    periods
    |> Enum.flat_map(fn period ->
      case action_for(profile, period) do
        {:pay, amount_cents, %Date{} = pay_on} ->
          [build_payment(holder, period.index, amount_cents, pay_on)]

        :miss ->
          []
      end
    end)
    |> Enum.sort_by(& &1.occurred_on, Date)
  end

  @doc """
  The single `PaymentReceived` whose received date is `date`, or `nil` when the
  tenant pays nothing that day. This is the live loop's daily call
  (`decide(profile, schedule, Clock.today())`).
  """
  @spec decide(Profile.t(), Schedule.t(), Date.t()) :: PaymentReceived.t() | nil
  def decide(%Profile{} = profile, %Schedule{} = schedule, %Date{} = date) do
    profile
    |> payments(schedule)
    |> Enum.find(fn %PaymentReceived{occurred_on: on} -> Date.compare(on, date) == :eq end)
  end

  # ── per-period action: scripted override wins, else the archetype rule ────────

  @spec action_for(Profile.t(), Schedule.period()) ::
          {:pay, pos_integer(), Date.t()} | :miss
  defp action_for(%Profile{overrides: overrides} = profile, period) do
    case Map.get(overrides, period.index) do
      nil -> archetype_action(profile, period)
      override -> resolve_override(override, period)
    end
  end

  defp resolve_override(:miss, _period), do: :miss

  defp resolve_override({:pay, opts}, period) do
    amount = Keyword.get(opts, :amount_cents, period.amount_cents)
    offset = Keyword.get(opts, :offset, 0)
    {:pay, amount, Date.add(period.due_on, offset)}
  end

  # ── archetype rules ──────────────────────────────────────────────────────────

  defp archetype_action(%Profile{archetype: :reliable}, period) do
    {:pay, period.amount_cents, period.due_on}
  end

  defp archetype_action(%Profile{archetype: :chronically_late, late_by_days: n}, period) do
    {:pay, period.amount_cents, Date.add(period.due_on, n)}
  end

  defp archetype_action(%Profile{archetype: :deteriorating} = p, period) do
    case deteriorating_offset(p, period.index) do
      :miss -> :miss
      offset -> {:pay, period.amount_cents, Date.add(period.due_on, offset)}
    end
  end

  defp archetype_action(%Profile{archetype: :sporadic} = p, period) do
    if pays?(p, period.index) do
      {:pay, period.amount_cents, Date.add(period.due_on, lateness(p, period.index))}
    else
      :miss
    end
  end

  # On time through the grace window; then `step_days` later each successive period
  # until the lateness reaches a whole period, at which point the tenant has fallen a
  # period behind and stops paying (a monotonic decline, fully deterministic).
  defp deteriorating_offset(%Profile{} = p, index) do
    slipped = index - p.grace_periods + 1

    cond do
      slipped <= 0 -> 0
      slipped * p.step_days >= p.period_length_days -> :miss
      true -> slipped * p.step_days
    end
  end

  # ── seeded jitter (deterministic PRNG) ────────────────────────────────────────

  # A stable pseudo-random unit value in [0.0, 1.0) from (seed, tag, index). Using a
  # per-index hash (not stateful RNG) keeps a period's draw independent of iteration
  # path, so seeding a subset of periods reproduces the same result as the full run.
  @resolution 1_000_000

  defp unit(seed, tag, index) do
    :erlang.phash2({seed, tag, index}, @resolution) / @resolution
  end

  defp pays?(%Profile{seed: seed, pay_probability: prob}, index) do
    unit(seed, :pay, index) < prob
  end

  defp lateness(%Profile{seed: seed, max_late_days: max}, index) do
    trunc(unit(seed, :late, index) * (max + 1))
  end

  # ── PaymentReceived construction (reuses the Accounts edge builder) ───────────

  defp build_payment(holder, index, amount_cents, %Date{} = pay_on) do
    Accounts.payment_received(%{
      payment_id: "#{holder}-pmt-#{index}",
      amount_cents: amount_cents,
      received_on: pay_on,
      # A tenant payment is a live fact: booked the day it is received.
      recorded_on: pay_on,
      holder: holder
    })
  end
end
