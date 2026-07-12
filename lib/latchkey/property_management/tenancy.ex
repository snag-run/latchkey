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

  Slice scope so far: weekly cycle; lifecycle `:pending → :active → :ending`;
  invariants L2 (commence once), L1/L3 (notice needs a live tenancy), L7 (arrears
  gate). See `docs/adr/0003-es-foundation-bakeoff.md`.
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

  def evolve(%State{} = s, %{type: :termination_notice_given}) do
    %State{s | status: :ending}
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
  Lazy catch-up (§6): the `rent_fell_due` events owed for `(due_through, as_of]`.
  Weekly cycle only for now. Idempotent by the `due_through` pointer.

  Each tick's `occurred_on` is its historical due date; every tick shares the
  passed `recorded_on` (the booking date), so a swept-in tick has
  `recorded_on >= occurred_on` (lazy accrual, not backdating).
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
    |> Enum.take_while(&(Date.compare(&1, as_of) != :gt))
    |> Enum.map(fn due_date ->
      %{
        type: :rent_fell_due,
        occurred_on: due_date,
        recorded_on: recorded_on,
        amount_cents: s.rent_amount_cents
      }
    end)
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

  # §6 lazy sweep as a first-class no-decision op (keeps the read model warm).
  def decide_catch_up(%State{status: :pending}, _cmd), do: {:ok, []}

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
end
