defmodule Latchkey.PropertyManagement.ArrearsFold do
  @moduledoc """
  The **single shared downstream fold-and-derive** for the `Tenancy` stream
  (spec `docs/spec/developer-view.md`, decision **D1** — the keystone).

  One code path folds a list of events (a prefix) into the aggregate core
  (`%Tenancy.State{}`) and derives the `Arrears` read-model fields off it. Both
  consumers call it, so they can never drift:

  - the operational `Latchkey.PropertyManagement.ArrearsProjector` folds the
    **full stream** and upserts the result to Postgres (`pm_tenancy_arrears`);
  - the read-only dev-view inspector folds a **selected prefix**, **in-memory
    only — it never writes to any read-model table**.

  The fold itself is pure (no infrastructure): it reuses `Aggregate.apply/2`
  (which normalises the strings the JSON serializer returns on replay and threads
  `Tenancy.evolve/2`) and the `Tenancy` derived reads
  (`balance_cents/1`, `oldest_unpaid_due_date/1`, `days_behind/2`), so what the
  inspector teaches is the real fold, not a lookalike.

  ## `days_behind` is derived as-at a supplied date

  `days_behind` is elapsed calendar days from the oldest unpaid due date and so
  depends on an as-of date. It is **not** hard-wired to "today": callers pass the
  date to reckon against. The default (`fold_and_derive/1`) reckons **as-at the
  prefix's last event `occurred_on`** — mirroring `Timeline.fold/1`, which does
  days-behind as-at each row — so during a replay scrub the counter visibly climbs
  and falls rather than always reading "today". The operational projector does not
  persist `days_behind` (it is computed on read, `Arrears.days_behind/2`), so the
  value it gets here is simply unused.
  """
  alias Latchkey.PropertyManagement.Tenancy
  alias Latchkey.PropertyManagement.Tenancy.Aggregate
  alias Latchkey.PropertyManagement.Tenancy.State

  @enforce_keys [:core, :status, :balance_cents, :oldest_unpaid_due_date, :days_behind]
  defstruct [
    :core,
    :status,
    :balance_cents,
    :oldest_unpaid_due_date,
    :days_behind,
    :final_balance_cents
  ]

  @type t :: %__MODULE__{
          core: State.t(),
          status: :pending | :active | :ending | :terminal,
          balance_cents: integer(),
          oldest_unpaid_due_date: Date.t() | nil,
          days_behind: non_neg_integer(),
          final_balance_cents: integer() | nil
        }

  @doc """
  Fold an event **prefix** into the aggregate core and derive the read-model
  fields, reckoning `days_behind` as-at the prefix's last event `occurred_on`
  (0 for an empty prefix). See `fold_and_derive/2` to reckon against an explicit
  date.
  """
  @spec fold_and_derive([struct()]) :: t()
  def fold_and_derive(events) when is_list(events),
    do: fold_and_derive(events, last_occurred_on(events))

  @doc """
  Fold an event **prefix** into the aggregate core and derive the read-model
  fields (`status`, `balance_cents`, `oldest_unpaid_due_date`, `final_balance_cents`),
  reckoning `days_behind` as-at `as_of`.

  Pure and side-effect-free — **never writes** to any read-model table.
  """
  @spec fold_and_derive([struct()], Date.t() | nil) :: t()
  def fold_and_derive(events, as_of) when is_list(events) do
    core = fold(events)

    %__MODULE__{
      core: core,
      status: core.status,
      balance_cents: Tenancy.balance_cents(core),
      oldest_unpaid_due_date: Tenancy.oldest_unpaid_due_date(core),
      days_behind: days_behind(core, as_of),
      final_balance_cents: core.final_balance_cents
    }
  end

  @doc """
  Fold an event **prefix** into the aggregate core (`%Tenancy.State{}`) only, with
  no read-model derivation. Reuses `Aggregate.apply/2` so replayed JSON strings are
  coerced back to their domain types exactly as production does.
  """
  @spec fold([struct()]) :: State.t()
  def fold(events) when is_list(events) do
    events
    |> Enum.reduce(%Aggregate{}, fn event, agg -> Aggregate.apply(agg, event) end)
    |> Map.fetch!(:core)
  end

  # No as-of date (empty prefix) ⇒ nothing is due, so nobody is behind.
  defp days_behind(%State{}, nil), do: 0
  defp days_behind(%State{} = core, %Date{} = as_of), do: Tenancy.days_behind(core, as_of)

  # The as-of default: the prefix's last (most recently appended) event's occurrence
  # date. `occurred_on` may be a `Date` or the ISO string the JSON serializer returns.
  defp last_occurred_on([]), do: nil

  defp last_occurred_on(events) do
    case List.last(events).occurred_on do
      %Date{} = d -> d
      s when is_binary(s) -> Date.from_iso8601!(s)
    end
  end
end
