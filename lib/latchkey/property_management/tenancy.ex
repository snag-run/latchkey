defmodule Latchkey.PropertyManagement.Tenancy do
  @moduledoc """
  The `Tenancy` aggregate's domain logic, framework-free (domain-model.md §4–§7).

  `evolve/2` is the fold (`apply`); the `decide_*/2` functions are the decisions
  (`execute`). `Latchkey.PropertyManagement.Tenancy.Aggregate` is a thin Commanded
  shell over these — so this module has **no Commanded dependency** and is where new
  domain rules (the rest of L1–L8, the exit/overstay accrual) are hand-implemented
  and unit-tested without any infrastructure.

  Events are normalized plain maps `%{type: atom, ...}`; the aggregate shell adapts
  Commanded's event structs to/from this shape.

  Slice scope so far: weekly cycle; lifecycle `:pending → :active → :ending →
  :terminal`; invariants L2 (commence once), L1/L3 (notice needs a live tenancy),
  L7 (arrears gate), L9 (keys-return needs an effective end date, reaches Terminal,
  fires at most once). Exit catch-up books whole periods until a full period no longer
  fits before the effective end date E, then pro-rates the boundary period daily to E
  (issue #31); an overstay (`V > E`) appends the `[E, V)` hold-over span as one
  crystallised daily-rate `RentFellDue` at keys-return (issue #32, ADR 0004). See
  `docs/adr/0003-es-foundation-bakeoff.md`.
  """
  alias Latchkey.PropertyManagement.Tenancy.State

  @arrears_gate_days 14

  def initial_state, do: %State{}

  # ── Fold (apply) ────────────────────────────────────────────────────────────

  def evolve(%State{} = s, %{type: :tenancy_commenced} = e) do
    %State{
      s
      | status: :active,
        tenancy_id: e.tenancy_id,
        rent_amount_cents: e.rent_amount_cents,
        cycle: e.cycle,
        first_due_date: e.first_due_date
    }
  end

  def evolve(%State{} = s, %{type: :rent_fell_due} = e) do
    # `occurred_on` is the charge's due date — the accrual/FIFO key.
    %State{
      s
      | charges: s.charges ++ [{e.occurred_on, e.amount_cents}],
        due_through: e.occurred_on
    }
  end

  def evolve(%State{} = s, %{type: :rent_payment_recorded} = e) do
    %State{
      s
      | payments_total_cents: s.payments_total_cents + e.amount_cents,
        applied_payment_ids: MapSet.put(s.applied_payment_ids, e.source_payment_id)
    }
  end

  def evolve(%State{} = s, %{type: :termination_notice_given} = e) do
    # Fold the effective end date E from the notice's kick-in date — this is the
    # clamp for end-date-aware catch-up and the reference for settlement.
    %State{s | status: :ending, effective_end_date: e.termination_date}
  end

  def evolve(%State{} = s, %{type: :keys_returned} = e) do
    %State{s | keys_returned_on: e.occurred_on}
  end

  def evolve(%State{} = s, %{type: :tenancy_settled} = e) do
    # Terminal (L3 keeps it final). `final_balance_cents` is the frozen settlement
    # snapshot; the live folded `balance_cents/1` still moves on post-terminal
    # payments (P4) — the two are deliberately distinct.
    %State{s | status: :terminal, final_balance_cents: e.final_balance_cents}
  end

  def fold(events), do: Enum.reduce(events, initial_state(), &evolve(&2, &1))

  # ── Derived reads (§7) ────────────────────────────────────────────────────────

  def balance_cents(%State{} = s) do
    Enum.reduce(s.charges, 0, fn {_d, a}, acc -> acc + a end) - s.payments_total_cents
  end

  @doc """
  Earliest due date whose *cumulative* charge exceeds *cumulative* payments (FIFO).
  A partial payment that doesn't clear the oldest period does not advance it.
  `nil` when paid up.
  """
  def oldest_unpaid_due_date(%State{} = s) do
    s.charges
    |> Enum.reduce_while(0, fn {due_date, amount}, cumulative ->
      cumulative = cumulative + amount

      if cumulative > s.payments_total_cents do
        {:halt, due_date}
      else
        {:cont, cumulative}
      end
    end)
    |> case do
      %Date{} = d -> d
      _cumulative_int -> nil
    end
  end

  @doc "Elapsed calendar days from the oldest unpaid due date (time-based, §7)."
  def days_behind(%State{} = s, %Date{} = as_of) do
    case oldest_unpaid_due_date(s) do
      nil -> 0
      due_date -> max(0, Date.diff(as_of, due_date))
    end
  end

  @doc """
  Lazy, **end-date-aware** catch-up (§6): the `rent_fell_due` events owed for
  `(due_through, as_of]`. Weekly cycle only for now. Idempotent by the `due_through`
  pointer.

  Each tick's `occurred_on` is its historical due date; every tick shares the passed
  `recorded_on` (the booking date), so a swept-in tick has `recorded_on >= occurred_on`
  (lazy accrual, not backdating).

  Once the tenancy has an effective end date `E` (folded from the termination notice),
  the sweep books whole periods only until a full period no longer fits before `E`, then
  a single **pro-rated** boundary charge covering the boundary period's start → `E`
  (issue #31). The boundary period is the one that *contains* `E`
  (`period_from < E < period_to`); it is charged for the days actually within the
  tenancy — `[period_from, E)` — never the whole week. When `E` is itself a period
  boundary (`E == period_from`) nothing is pro-rated: whole periods run right up to `E`
  and the period starting *on* `E` is post-exit (the #30 boundary-aligned case). No
  step charge fires on or after `E`; the post-`E` span is the overstay reckoning, which
  `decide_return_keys` appends as a single `[E, V)` charge (issue #32) — not on this
  sweep. With no `E` (an active tenancy) every due period is charged whole.
  """
  def catch_up_events(%State{status: :pending}, _as_of, _recorded_on), do: []

  def catch_up_events(%State{} = s, %Date{} = as_of, recorded_on) do
    first =
      case s.due_through do
        nil -> s.first_due_date
        d -> Date.add(d, 7)
      end

    first
    |> Stream.iterate(&Date.add(&1, 7))
    |> Enum.reduce_while([], fn period_from, acc ->
      period_to = Date.add(period_from, 7)

      cond do
        # Not yet due — lazy accrual books nothing past `as_of`.
        Date.compare(period_from, as_of) == :gt ->
          {:halt, acc}

        # No E yet, or a full period still fits before E — charge it whole and continue.
        whole_period_fits?(s.effective_end_date, period_to) ->
          {:cont, [whole_period_charge(s, period_from, recorded_on) | acc]}

        # E falls inside this period — pro-rate `[period_from, E)` and stop (issue #31).
        Date.compare(period_from, s.effective_end_date) == :lt ->
          {:halt, [boundary_charge(s, period_from, s.effective_end_date, recorded_on) | acc]}

        # period_from is on/after E — post-exit span (overstay, #32): emit nothing, stop.
        true ->
          {:halt, acc}
      end
    end)
    |> Enum.reverse()
  end

  # A full period fits before E when its exclusive end `period_to` is on/before E. With
  # no E (active tenancy), every period is charged whole.
  defp whole_period_fits?(nil, _period_to), do: true
  defp whole_period_fits?(%Date{} = e, period_to), do: Date.compare(period_to, e) != :gt

  # A whole rent period `[due, due + 7)` at the full periodic rent. `occurred_on` (the
  # accrual/FIFO key) is the period start, which equals `period_from`.
  defp whole_period_charge(%State{} = s, due_date, recorded_on) do
    %{
      type: :rent_fell_due,
      occurred_on: due_date,
      recorded_on: recorded_on,
      amount_cents: s.rent_amount_cents,
      period_from: due_date,
      period_to: Date.add(due_date, 7)
    }
  end

  # The pro-rated boundary charge: `period_rent × days_in_period_to_E ÷ period_length`,
  # rounded half-up **once** on the final amount (Money §9). `days_in_period_to_E =
  # Date.diff(E, period_from)` (E exclusive). `period_to` is E, so E is not charged here.
  defp boundary_charge(%State{} = s, period_from, e, recorded_on) do
    %{
      type: :rent_fell_due,
      occurred_on: period_from,
      recorded_on: recorded_on,
      amount_cents: daily_rate_amount(s, period_from, e),
      period_from: period_from,
      period_to: e
    }
  end

  # The daily-rate pro-ration shared by the boundary (#31) and overstay (#32) charges:
  # `period_rent × days ÷ period_length` for `days = Date.diff(to, from)` (actual/actual,
  # weekly `period_length = 7`), rounded half-up **once** on the final amount (Money §9).
  # One home for the money-rounding rule so the two call sites can't drift apart.
  defp daily_rate_amount(%State{} = s, %Date{} = from, %Date{} = to) do
    round_half_up(s.rent_amount_cents * Date.diff(to, from), 7)
  end

  # Round `numerator / denominator` half-up on the single final amount (denominator > 0,
  # numerator >= 0 for accrual). `floor((num + denom/2) / denom) = div(2·num + denom,
  # 2·denom)` — integer-only, so no float rounding drift.
  defp round_half_up(numerator, denominator) when denominator > 0 do
    div(2 * numerator + denominator, 2 * denominator)
  end

  # ── Decisions (execute) — {:ok, [event]} | {:error, reason} ──────────────────

  def decide_commence(%State{status: :pending}, %{cycle: :weekly} = cmd) do
    {:ok,
     [
       %{
         type: :tenancy_commenced,
         tenancy_id: cmd.tenancy_id,
         # occurrence = commencement date (the first due date in this weekly slice).
         occurred_on: cmd.first_due_date,
         recorded_on: cmd.recorded_on,
         rent_amount_cents: cmd.rent_amount_cents,
         cycle: cmd.cycle,
         first_due_date: cmd.first_due_date
       }
     ]}
  end

  # Slice supports weekly accrual only; refuse cycles we'd silently mischarge.
  def decide_commence(%State{status: :pending}, _cmd), do: {:error, :unsupported_cycle}

  # L2 — a tenancy commences at most once.
  def decide_commence(%State{}, _cmd), do: {:error, :already_commenced}

  def decide_payment(%State{status: status}, _cmd) when status not in [:active, :ending],
    do: {:error, :not_active}

  def decide_payment(%State{} = s, cmd) do
    if MapSet.member?(s.applied_payment_ids, cmd.source_payment_id) do
      {:ok, []}
    else
      catch_up = catch_up_events(s, cmd.received_on, cmd.recorded_on)

      payment = %{
        type: :rent_payment_recorded,
        # occurrence = received date.
        occurred_on: cmd.received_on,
        recorded_on: cmd.recorded_on,
        amount_cents: cmd.amount_cents,
        source_payment_id: cmd.source_payment_id
      }

      {:ok, catch_up ++ [payment]}
    end
  end

  @doc """
  Reverse a previously-recorded payment (ACL-1's reversal path, ADR 0006 §7). Emits a
  **negative** `rent_payment_recorded` carrying `reason` and `reverses` (the original
  payment id) so the timeline can render "Payment reversed — <reason>" and tie it to
  the credit it undoes. The fold absorbs the negative amount (payments go down); the
  reversal's own `source_payment_id` enters `applied_payment_ids` for idempotency.

  Three guards, checked in this order so replay is safe:

  - **Sign invariant** — a reversal is a *compensating* (negative) entry; a non-negative
    amount is a structurally-invalid command that must never emit a positive
    `rent_payment_recorded` (which would inflate the balance). Refuse it outright with
    `{:error, :non_negative_reversal}`. (Accounts' builder already enforces the sign at
    its edge; this keeps the domain honest against a direct/malformed command too.)
  - **Idempotent** on the reversal's `source_payment_id` — a re-seen reversal (live
    re-delivery or a replay of an already-emitted one) is a `{:ok, []}` no-op.
  - **Defensive P2** (§5 P2) — a reversal whose `reverses` PM never recorded is a seam
    bug under today's single ordered store; refuse it with `{:error, :unknown_payment}`
    rather than book a phantom debit. Unlike the forward path this is **not** lifecycle
    gated: a payment can be reversed whenever it was applied (incl. post-terminal, P4),
    and the "known payment" check already implies the tenancy commenced.
  """
  def decide_reversal(%State{} = s, cmd) do
    cond do
      cmd.amount_cents >= 0 ->
        {:error, :non_negative_reversal}

      MapSet.member?(s.applied_payment_ids, cmd.source_payment_id) ->
        {:ok, []}

      not MapSet.member?(s.applied_payment_ids, cmd.reverses) ->
        {:error, :unknown_payment}

      true ->
        {:ok,
         [
           %{
             type: :rent_payment_recorded,
             # occurrence = the reversal's reversed date.
             occurred_on: cmd.reversed_on,
             recorded_on: cmd.recorded_on,
             amount_cents: cmd.amount_cents,
             source_payment_id: cmd.source_payment_id,
             reason: cmd.reason,
             reverses: cmd.reverses
           }
         ]}
    end
  end

  # §6 lazy sweep as a first-class no-decision op (keeps the read model warm).
  def decide_catch_up(%State{status: :pending}, _cmd), do: {:ok, []}

  # A settled tenancy is done (L3): no rent accrues after Terminal, so the daily
  # sweep (#41) must not keep emitting `RentFellDue`. No-op like the pending case.
  def decide_catch_up(%State{status: :terminal}, _cmd), do: {:ok, []}

  def decide_catch_up(%State{} = s, %{as_of: as_of} = cmd),
    do: {:ok, catch_up_events(s, as_of, cmd.recorded_on)}

  # L1/L3 — a termination notice needs a live (active) tenancy.
  def decide_termination(%State{status: status}, _cmd) when status != :active,
    do: {:error, :not_active}

  def decide_termination(%State{} = s, cmd) do
    catch_up = catch_up_events(s, cmd.as_of, cmd.recorded_on)
    s_now = Enum.reduce(catch_up, s, &evolve(&2, &1))
    behind = days_behind(s_now, cmd.as_of)

    # L7 — arrears grounds require >=14 days behind (elapsed time, not $ owed).
    if behind < @arrears_gate_days do
      {:error, {:not_in_arrears, behind}}
    else
      notice = %{
        type: :termination_notice_given,
        # occurrence = served/given date; `termination_date` stays payload.
        occurred_on: cmd.given_on,
        recorded_on: cmd.recorded_on,
        grounds: :arrears,
        termination_date: cmd.termination_date
      }

      {:ok, catch_up ++ [notice]}
    end
  end

  # L9 — keys can only be returned on a tenancy that has an effective end date
  # (status `:ending`). Refuses a live/never-ending tenancy, and — because settlement
  # reaches `:terminal` — refuses a second keys-return (L3 keeps Terminal final).
  def decide_return_keys(%State{status: status}, _cmd) when status != :ending,
    do: {:error, :no_effective_end_date}

  # A malformed/legacy `:ending` state carrying no effective end date can't settle:
  # refuse with the same L9 reason rather than crash on `Date.add(nil, -1)`.
  def decide_return_keys(%State{effective_end_date: nil}, _cmd),
    do: {:error, :no_effective_end_date}

  def decide_return_keys(%State{effective_end_date: %Date{} = e} = s, cmd) do
    if Date.compare(cmd.keys_on, e) == :lt do
      # L9 — keys returned *before* E (early leave `V < E`) over-charges periods booked
      # out to E and needs a **correcting entry** — deferred to #64. Refuse it here so
      # this slice never silently un-charges: a valid return is dated on or after E.
      {:error, :keys_returned_before_end_date}
    else
      # The exit is reckoned against the vacant-possession date `V` (= keys_on), not E.
      # Two forward-append steps compose the ledger, in order (spec / ADR 0004 §2):
      #
      # 1. Catch rent up to — but not past — `min(V, E) = E` (V >= E here). The
      #    end-date-aware sweep books whole periods until a full period no longer fits
      #    before E, then a single pro-rated boundary charge covering `[period_from, E)`
      #    (issue #31). E belongs to the post-exit span (half-open `[from, to)`), so no
      #    step `RentFellDue` lands on or after E. A prior sweep/payment may already have
      #    booked the boundary; `due_through` makes catch-up idempotent.
      # 2. If the tenant held over (`V > E`), append the `[E, V)` overstay as a **single**
      #    crystallised `RentFellDue` at the daily rate (linear ramp ⇒ one figure). This
      #    is a forward append *on top of* whatever accrual already booked to E — it never
      #    rewrites or re-pro-rates an already-booked period. `V = E` ⇒ empty span ⇒ no
      #    charge. Any credit the tenant holds is consumed first automatically under
      #    balance-as-truth (the fold nets it), so no special handling is needed.
      catch_up = catch_up_events(s, e, cmd.recorded_on)
      overstay = overstay_events(s, e, cmd.keys_on, cmd.recorded_on)
      exit_charges = catch_up ++ overstay
      s_now = Enum.reduce(exit_charges, s, &evolve(&2, &1))

      # `final_balance_cents` is the fold snapshot after the boundary + overstay charges
      # land (signed: negative = refund owed, positive = debt). Declared, not disbursed.
      final = balance_cents(s_now)

      keys = %{
        type: :keys_returned,
        # occurrence = the keys-return (possession-recovered) date `V`.
        occurred_on: cmd.keys_on,
        recorded_on: cmd.recorded_on
      }

      settled = %{
        type: :tenancy_settled,
        occurred_on: cmd.keys_on,
        recorded_on: cmd.recorded_on,
        final_balance_cents: final
      }

      {:ok, exit_charges ++ [keys, settled]}
    end
  end

  # The overstay reckoning (issue #32): when possession is recovered *after* E (`V > E`),
  # the `[E, V)` hold-over span is one crystallised `RentFellDue` at the daily rate —
  # `round_half_up(period_rent × days ÷ period_length)`, `days = Date.diff(V, E)` (V
  # exclusive), the same daily-rate maths as the boundary charge (#31). `period_from = E`
  # inclusive, `period_to = V` exclusive, so V (the keys-return day, possession recovered)
  # is not charged and E is counted once — in the overstay span, never the boundary period.
  # `occurred_on = E` is the accrual/FIFO key. `V = E` ⇒ empty span ⇒ no event.
  defp overstay_events(%State{} = s, %Date{} = e, %Date{} = v, recorded_on) do
    if Date.compare(v, e) == :gt do
      [
        %{
          type: :rent_fell_due,
          occurred_on: e,
          recorded_on: recorded_on,
          amount_cents: daily_rate_amount(s, e, v),
          period_from: e,
          period_to: v
        }
      ]
    else
      []
    end
  end
end
