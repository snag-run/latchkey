defmodule Spike.TenancyCore do
  @moduledoc """
  Framework-free decision + fold for the `Tenancy` aggregate slice.

  This is the whole domain: `evolve/2` is the `apply` fold, and the `decide_*/2`
  functions are the `execute` decisions. Both spikes (`Spike.Commanded.*` and
  `Spike.AshEvents.*`) call THESE functions — the only difference between the two
  spikes is the plumbing that loads the stream, folds it, and appends the result.

  Events are normalized plain maps `%{type: atom, ...}` so the core is storage-
  agnostic. Each spike adapts its own storage form to/from this shape.

  Slice scope: weekly cycle only; lifecycle `:pending → :active → :ending`.
  See `spike/README.md`.
  """

  defmodule State do
    @moduledoc false
    defstruct status: :pending,
              tenancy_id: nil,
              rent_amount_cents: nil,
              cycle: nil,
              first_due_date: nil,
              due_through: nil,
              charges: [],
              payments_total_cents: 0,
              applied_payment_ids: MapSet.new()
  end

  @arrears_gate_days 14

  def initial_state, do: %State{}

  # ── Fold (the `apply`) ────────────────────────────────────────────────────

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
    %State{s | charges: s.charges ++ [{e.due_date, e.amount_cents}], due_through: e.due_date}
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

  # ── Derived reads (§7) ────────────────────────────────────────────────────

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
  Lazy catch-up (§6): the `RentFellDue` events owed for `(due_through, as_of]`.
  Weekly cycle only in the slice. Idempotent by the `due_through` pointer.
  """
  def catch_up_events(%State{status: :pending}, _as_of), do: []

  def catch_up_events(%State{} = s, %Date{} = as_of) do
    first =
      case s.due_through do
        nil -> s.first_due_date
        d -> Date.add(d, 7)
      end

    first
    |> Stream.iterate(&Date.add(&1, 7))
    |> Enum.take_while(&(Date.compare(&1, as_of) != :gt))
    |> Enum.map(fn due_date ->
      %{type: :rent_fell_due, due_date: due_date, amount_cents: s.rent_amount_cents}
    end)
  end

  # ── Decisions (the `execute`) — {:ok, [event]} | {:error, reason} ─────────

  def decide_commence(%State{status: :pending} = _s, cmd) do
    {:ok,
     [
       %{
         type: :tenancy_commenced,
         tenancy_id: cmd.tenancy_id,
         rent_amount_cents: cmd.rent_amount_cents,
         cycle: cmd.cycle,
         first_due_date: cmd.first_due_date
       }
     ]}
  end

  # L2 — a tenancy commences at most once.
  def decide_commence(%State{}, _cmd), do: {:error, :already_commenced}

  def decide_payment(%State{status: status}, _cmd) when status not in [:active, :ending],
    do: {:error, :not_active}

  def decide_payment(%State{} = s, cmd) do
    if MapSet.member?(s.applied_payment_ids, cmd.source_payment_id) do
      {:ok, []}
    else
      catch_up = catch_up_events(s, cmd.received_on)

      payment = %{
        type: :rent_payment_recorded,
        amount_cents: cmd.amount_cents,
        received_on: cmd.received_on,
        source_payment_id: cmd.source_payment_id
      }

      {:ok, catch_up ++ [payment]}
    end
  end

  # §6 lazy catch-up as a first-class no-decision op (the optional nightly sweep
  # that keeps the read model warm). Emits only the owed RentFellDue ticks.
  def decide_catch_up(%State{status: :pending}, _cmd), do: {:ok, []}
  def decide_catch_up(%State{} = s, %{as_of: as_of}), do: {:ok, catch_up_events(s, as_of)}

  # L1/L3 — a termination notice needs a live (active) tenancy.
  def decide_termination(%State{status: status}, _cmd) when status != :active,
    do: {:error, :not_active}

  def decide_termination(%State{} = s, cmd) do
    catch_up = catch_up_events(s, cmd.as_of)
    s_now = Enum.reduce(catch_up, s, &evolve(&2, &1))
    behind = days_behind(s_now, cmd.as_of)

    # L7 — arrears grounds require ≥14 days behind (elapsed time, not $ owed).
    if behind < @arrears_gate_days do
      {:error, {:not_in_arrears, behind}}
    else
      notice = %{
        type: :termination_notice_given,
        grounds: :arrears,
        termination_date: cmd.termination_date,
        given_on: cmd.given_on
      }

      {:ok, catch_up ++ [notice]}
    end
  end
end
