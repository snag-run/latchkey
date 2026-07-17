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
  crystallised daily-rate `RentFellDue` at keys-return (issue #32, ADR 0004). When a
  backdated notice sets E inside a period the sweep already booked whole, a single
  compensating `RentFellDue` nets that period back down to the #31 pro-rata (issue #64).
  See `docs/adr/0003-es-foundation-bakeoff.md`.
  """
  alias Latchkey.PropertyManagement.Tenancy.State

  @arrears_gate_days 14

  # The rent cadences this slice accrues (ADR 0009): a fixed 7/14-day period for weekly/
  # fortnightly and a calendar month for monthly. `decide_commence` accepts these; any
  # other cycle is refused rather than silently mischarged.
  @supported_cycles [:weekly, :fortnightly, :monthly]

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
  On-demand, **end-date-aware** catch-up (§6): the `rent_fell_due` events owed for
  `(due_through, as_of]`. Cadence-aware (ADR 0009): due dates are the uniform
  index-from-anchor walk `due(n)` (weekly `+7·n`, fortnightly `+14·n`, monthly
  `Date.shift(anchor, month: n)` from the commencement anchor — month-end clamped, never
  stuck at 28), and each period is `[due(n), due(n+1))`, so the monthly period length is
  naturally 28–31 with no special-casing. Idempotent by the `due_through` pointer: resume
  advances `n` from 0 until `due(n)` is strictly past the last booked due date.

  Each tick's `occurred_on` is its historical due date. `recorded_on` is the booking date:
  pass `nil` for system-managed accrual and every tick self-stamps `recorded_on =
  occurred_on` — it books on its own due date, no bitemporal divergence (issue #118,
  supersedes ADR 0005 decision 4). A non-nil `recorded_on` is threaded onto every tick and
  is the sole legitimate `recorded_on > occurred_on` case: an imported/transferred tenancy
  whose history is rebuilt after the fact (issue #117).

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
    # The cadence-aware period sequence `{due(n), due(n+1)}`, n = 0,1,2… from the
    # commencement anchor. `due_through` stores the last booked due *date* (not an index),
    # so resume drops every already-booked period (`period_from <= due_through`).
    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&period_bounds(s, &1))
    |> Stream.filter(fn {period_from, _to} -> booked_after?(s.due_through, period_from) end)
    |> Enum.reduce_while([], fn {period_from, period_to}, acc ->
      cond do
        # Not yet due — the sweep books nothing past `as_of`.
        Date.compare(period_from, as_of) == :gt ->
          {:halt, acc}

        # No E yet, or a full period still fits before E — charge it whole and continue.
        whole_period_fits?(s.effective_end_date, period_to) ->
          {:cont, [whole_period_charge(s, period_from, period_to, recorded_on) | acc]}

        # E falls inside this period — pro-rate `[period_from, E)` and stop (issue #31).
        Date.compare(period_from, s.effective_end_date) == :lt ->
          {:halt,
           [boundary_charge(s, period_from, period_to, s.effective_end_date, recorded_on) | acc]}

        # period_from is on/after E — post-exit span (overstay, #32): emit nothing, stop.
        true ->
          {:halt, acc}
      end
    end)
    |> Enum.reverse()
  end

  # The nth rent period `{due(n), due(n+1)}` walked from the commencement anchor by the
  # tenancy's cadence (ADR 0009 decision 2). Monthly shifts month-by-month **from the
  # anchor**, so a short month clamps but the day-of-month "comes back" (Jan 31 → Feb 28 →
  # Mar 31), never drifting to 28.
  defp period_bounds(%State{first_due_date: anchor, cycle: cycle}, n) do
    {due_date(anchor, cycle, n), due_date(anchor, cycle, n + 1)}
  end

  defp due_date(%Date{} = anchor, :weekly, n), do: Date.add(anchor, 7 * n)
  defp due_date(%Date{} = anchor, :fortnightly, n), do: Date.add(anchor, 14 * n)
  defp due_date(%Date{} = anchor, :monthly, n), do: Date.shift(anchor, month: n)

  # Resume predicate: a period whose start is on/before the last booked due date has
  # already been charged. With no `due_through` (never swept) every period is fresh.
  defp booked_after?(nil, _period_from), do: true

  defp booked_after?(%Date{} = due_through, period_from),
    do: Date.compare(period_from, due_through) == :gt

  # A full period fits before E when its exclusive end `period_to` is on/before E. With
  # no E (active tenancy), every period is charged whole.
  defp whole_period_fits?(nil, _period_to), do: true
  defp whole_period_fits?(%Date{} = e, period_to), do: Date.compare(period_to, e) != :gt

  # A whole rent period `[due(n), due(n+1))` at the full periodic rent. `occurred_on` (the
  # accrual/FIFO key) is the period start `period_from`; `period_to` is the cadence's next
  # due date (7/14 days on, or the next calendar month), so the persisted span carries the
  # real period length for the read side. `recorded_on` defaults to `occurred_on`
  # (`period_from`) — a system-managed tick books on its own due date, no bitemporal
  # divergence (issue #118). A non-nil `recorded_on` is the import/transfer rebuild date
  # (#117), the sole legitimate `recorded_on > occurred_on` case.
  defp whole_period_charge(%State{} = s, period_from, period_to, recorded_on) do
    %{
      type: :rent_fell_due,
      occurred_on: period_from,
      recorded_on: recorded_on || period_from,
      amount_cents: s.rent_amount_cents,
      period_from: period_from,
      period_to: period_to
    }
  end

  # The pro-rated boundary charge: `period_rent × days_in_period_to_E ÷ period_length`,
  # rounded half-up **once** on the final amount (Money §9). `days_in_period_to_E =
  # Date.diff(E, period_from)` (E exclusive) and `period_length = Date.diff(period_to,
  # period_from)` — the actual length of the period E falls in (7/14/28–31, ADR 0009
  # decision 3). The emitted `period_to` is E, so E is not charged here.
  defp boundary_charge(%State{} = s, period_from, period_to, e, recorded_on) do
    %{
      type: :rent_fell_due,
      occurred_on: period_from,
      recorded_on: recorded_on || period_from,
      amount_cents: daily_rate_amount(s, period_from, e, Date.diff(period_to, period_from)),
      period_from: period_from,
      period_to: e
    }
  end

  # The daily-rate pro-ration shared by the boundary (#31) and overstay (#32) charges:
  # `period_rent × days ÷ period_length` for `days = Date.diff(to, from)`, actual/actual
  # over the **actual** length of the period the span falls in (`period_length`, passed
  # explicitly because the span end need not equal the period end). Rounded half-up
  # **once** on the final amount (Money §9). One home for the money-rounding rule so the
  # two call sites can't drift apart.
  defp daily_rate_amount(%State{} = s, %Date{} = from, %Date{} = to, period_length) do
    round_half_up(s.rent_amount_cents * Date.diff(to, from), period_length)
  end

  # Round `numerator / denominator` half-up on the single final amount (denominator > 0,
  # numerator >= 0 for accrual). `floor((num + denom/2) / denom) = div(2·num + denom,
  # 2·denom)` — integer-only, so no float rounding drift.
  defp round_half_up(numerator, denominator) when denominator > 0 do
    div(2 * numerator + denominator, 2 * denominator)
  end

  # ── Decisions (execute) — {:ok, [event]} | {:error, reason} ──────────────────

  def decide_commence(%State{status: :pending}, %{cycle: cycle, property_ref: ref} = cmd)
      when cycle in @supported_cycles and is_binary(ref) and ref != "" do
    {:ok,
     [
       %{
         type: :tenancy_commenced,
         tenancy_id: cmd.tenancy_id,
         # Non-PII property id (ADR 0008) — log metadata for the read side; recurs
         # across re-lets. Does not affect accrual or the aggregate invariants, but is
         # required so every tenancy is resolvable by the inspector/Directory.
         property_ref: ref,
         # occurrence = commencement date = the first due date (the accrual anchor).
         occurred_on: cmd.first_due_date,
         recorded_on: cmd.recorded_on,
         rent_amount_cents: cmd.rent_amount_cents,
         cycle: cmd.cycle,
         first_due_date: cmd.first_due_date
       }
     ]}
  end

  # A supported-cycle commence must carry a non-empty `property_ref` (the non-PII identity
  # key, ADR 0008) — refuse one without it rather than write an event the read side can't
  # resolve. Ordered before the cycle guard so the error names the real problem.
  def decide_commence(%State{status: :pending}, %{cycle: cycle})
      when cycle in @supported_cycles,
      do: {:error, :missing_property_ref}

  # Refuse cadences this slice doesn't accrue (ADR 0009 defers e.g. 4-weekly/quarterly).
  def decide_commence(%State{status: :pending}, _cmd), do: {:error, :unsupported_cycle}

  # L2 — a tenancy commences at most once.
  def decide_commence(%State{}, _cmd), do: {:error, :already_commenced}

  # Payment *application* is lifecycle-agnostic (spec §5 P4): once a tenancy has
  # commenced, a `RentPaymentRecorded` is accepted through Ending and Terminal alike, so
  # an ex-tenant can pay down a persisting debt after settlement (issue #33). Only a
  # pre-commence (`:pending`) tenancy has no ledger to pay into.
  def decide_payment(%State{status: :pending}, _cmd), do: {:error, :not_active}

  def decide_payment(%State{} = s, cmd) do
    if MapSet.member?(s.applied_payment_ids, cmd.source_payment_id) do
      {:ok, []}
    else
      # Accrual stays lifecycle-gated even though application isn't: a Terminal tenancy
      # books no new `RentFellDue` (L3 keeps it final), so the payment reduces the live
      # folded balance without reopening the tenancy or resuming the rent clock.
      # Accrual ticks book same-day (`recorded_on = nil` → each tick self-stamps its
      # occurred_on, #118); the payment event itself keeps `cmd.recorded_on` below.
      catch_up =
        if s.status == :terminal,
          do: [],
          else: catch_up_events(s, cmd.received_on, nil)

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

  # §6 on-demand sweep as a first-class no-decision op (keeps the read model warm).
  def decide_catch_up(%State{status: :pending}, _cmd), do: {:ok, []}

  # A settled tenancy is done (L3): no rent accrues after Terminal, so the daily
  # sweep (#41) must not keep emitting `RentFellDue`. No-op like the pending case.
  def decide_catch_up(%State{status: :terminal}, _cmd), do: {:ok, []}

  # Organic sweep books same-day (`recorded_on = nil`, #118). An import/transfer that
  # rebuilds history threads its real rebuild date through `catch_up_events/3` instead.
  def decide_catch_up(%State{} = s, %{as_of: as_of}),
    do: {:ok, catch_up_events(s, as_of, nil)}

  # L1/L3 — a termination notice needs a live (active) tenancy.
  def decide_termination(%State{status: status}, _cmd) when status != :active,
    do: {:error, :not_active}

  def decide_termination(%State{} = s, cmd) do
    # Sweep as if the proposed end date E were already in effect, so the notice-time
    # catch-up is E-aware and clamps at `min(as_of, termination_date)` — it never books
    # whole periods past a backdated E (`as_of > E`), which the `[E, V)` overstay booked
    # at keys-return (issue #32) would then double-charge (issue #71). Backdating stays a
    # soft invariant (a genuinely-served notice entered late is legitimate), so this is a
    # clamp, not a gate. A future E (the usual arrears notice) is a no-op: the `as_of`
    # guard halts the sweep before it ever reaches E.
    s_at_e = %State{s | effective_end_date: cmd.termination_date}
    catch_up = catch_up_events(s_at_e, cmd.as_of, nil)
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

      # Reconcile a rent period the sweep already booked *whole* that E now cuts short
      # (issue #64). Appended after the notice — the notice is what sets E, so the
      # correction reads as its consequence. The **original** `s` (pre-catch-up) is the
      # right basis: this call's catch-up is E-aware and never books a fresh boundary
      # whole, so the only whole booking of E's period is a prior sweep, recorded in
      # `s.due_through`.
      correction = prebooked_boundary_correction(s, cmd.termination_date, nil)

      {:ok, catch_up ++ [notice] ++ correction}
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
      catch_up = catch_up_events(s, e, nil)
      overstay = overstay_events(s, e, cmd.keys_on, nil)
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
  # exclusive), the same daily-rate maths as the boundary charge (#31). The denominator is
  # the length of **the scheduled period E falls in** — the last scheduled period — applied
  # flat across the whole span (ADR 0009 decision 3); a cross-boundary overstay is one
  # figure, never re-pro-rated per calendar month (that piecewise split is deferred).
  # `period_from = E` inclusive, `period_to = V` exclusive, so V (the keys-return day,
  # possession recovered) is not charged and E is counted once — in the overstay span,
  # never the boundary period. `occurred_on = E` is the accrual/FIFO key. `V = E` ⇒ empty
  # span ⇒ no event.
  defp overstay_events(%State{} = s, %Date{} = e, %Date{} = v, recorded_on) do
    if Date.compare(v, e) == :gt do
      {p_from, p_to} = scheduled_period_containing(s, e)

      [
        %{
          type: :rent_fell_due,
          occurred_on: e,
          recorded_on: recorded_on || e,
          amount_cents: daily_rate_amount(s, e, v, Date.diff(p_to, p_from)),
          period_from: e,
          period_to: v
        }
      ]
    else
      []
    end
  end

  # The pre-booked boundary reconciliation (issue #64). When the effective end date E lands
  # strictly inside a rent period the daily sweep (#41) already booked **whole** — the sweep
  # books each period in advance, before any notice sets E — the days `[E, period_to)` were
  # over-charged. #31 only pro-rates a boundary period the catch-up reaches *unbooked*; a
  # pre-booked one slips past the `due_through` resume filter and is never corrected. Emit
  # **one** compensating `rent_fell_due` that nets the whole charge down to the #31 boundary
  # pro-rata `[period_from, E)` — an event-sourced correction, never a mutation, preserving
  # double-entry fidelity (ADR 0004). Nothing fires when the sweep never ran (`due_through`
  # nil), when E is a period boundary (over-charges nothing), or when E's period is still
  # unbooked (catch-up pro-rates it live, #31) — the last two would otherwise double-correct.
  defp prebooked_boundary_correction(%State{due_through: nil}, _e, _recorded_on), do: []

  defp prebooked_boundary_correction(%State{} = s, %Date{} = e, recorded_on) do
    {period_from, period_to} = scheduled_period_containing(s, e)

    if boundary_prebooked?(s, period_from, period_to, e) do
      # `boundary_prorata − full_rent` (negative): `full + correction` equals the #31
      # boundary charge exactly, so a pre-booked exit and a lazily-accrued one settle to the
      # identical figure with no rounding drift (one half-up, Money §9). `occurred_on = E`:
      # the reconciliation takes effect at the end date, keeping `occurred_on == period_from`
      # (the charge invariant) while the span `[E, period_to)` names the clawed-back tail.
      prorata = daily_rate_amount(s, period_from, e, Date.diff(period_to, period_from))

      [
        %{
          type: :rent_fell_due,
          occurred_on: e,
          recorded_on: recorded_on || e,
          amount_cents: prorata - s.rent_amount_cents,
          period_from: e,
          period_to: period_to
        }
      ]
    else
      []
    end
  end

  # E needs a correction only when it lands **strictly inside** a period (`period_from < E <
  # period_to`) that was already booked whole — its start is on/before the last booked due
  # date (`period_from <= due_through`). A boundary-aligned E over-charges nothing; an
  # unbooked period is pro-rated live by `catch_up_events` (#31).
  defp boundary_prebooked?(%State{due_through: due_through}, period_from, period_to, e) do
    Date.compare(period_from, e) == :lt and
      Date.compare(e, period_to) == :lt and
      Date.compare(period_from, due_through) != :gt
  end

  # The **last scheduled period** for the overstay denominator (ADR 0009 decision 3): the
  # first period whose exclusive end is on/after `date` (`due(n) < date <= due(n+1)`). For a
  # `date` strictly interior to a period this is the period it sits in; for a
  # **boundary-aligned** `date == due(m)` it is the period *ending* at `date` —
  # `[due(m-1), due(m))` — not the period *starting* at `date` (which `catch_up_events`
  # classifies as post-exit, #30). Selecting the ending period keeps the flat daily-rate
  # denominator on the last period actually scheduled within the tenancy (e.g. a monthly E
  # on Mar 1 divides by Feb's 28, not the next month's 31). Weekly/fortnightly are immune:
  # fixed period length makes ending-at-E and starting-at-E the same denominator.
  defp scheduled_period_containing(%State{} = s, %Date{} = date) do
    0
    |> Stream.iterate(&(&1 + 1))
    |> Enum.find_value(fn n ->
      {period_from, period_to} = period_bounds(s, n)
      if Date.compare(date, period_to) != :gt, do: {period_from, period_to}
    end)
  end
end
