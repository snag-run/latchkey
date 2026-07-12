defmodule Latchkey.PropertyManagement.Timeline do
  @moduledoc """
  The per-tenancy **timeline** — a **compute-on-read** query (ADR 0006 §9, spec
  `docs/specs/timeline.md`). It folds one tenancy's event stream into ordered typed
  `Entry` rows at read time and stores nothing: no table, no projector. The
  cross-tenancy dashboard stays the materialised `Arrears` projection; this is the
  per-tenancy drill-down.

  ## Two layers

  - `fold/1` — the **pure fold**. Framework-free, no infrastructure. Takes a list of
    `{stream_sequence, event}` tuples (the event structs from
    `Latchkey.PropertyManagement.Tenancy.Events`, dates as `Date` or ISO strings) and
    returns the ordered `Entry` list. Unit-testable in isolation (Seam 1).
  - `for_tenancy/1` — the **thin read edge**. Reads the tenancy's stream from the
    EventStore, pairs each recorded event with its per-stream `stream_version`, and
    hands them to `fold/1`. It **reads the log and never appends** (no catch-up in a
    query — the sweep owns booking, §6).

  ## Ordering (ADR 0006 §4)

  Rows sort by **`(occurred_on, stream_sequence)`** — the real-world date, then the
  event's per-stream append position as the canonical same-day tie-breaker. Never the
  incidental EventStore iteration order, so the running `balance_snapshot` is
  reproducible on every rebuild.

  ## Snapshots (ADR 0006 §5–6)

  - `balance_snapshot_cents` = `Σ debits − Σ credits` folded in `(occurred_on,
    stream_sequence)` order up to and including each row (debit = `rent_fell_due` or a
    reversal, credit = `payment`). A reversal is a **negative** `RentPaymentRecorded`
    re-expanded into the debit column at its own `occurred_on`, restoring the balance the
    reversed credit had reduced (ADR 0006 §7); the original credit row stays untouched.
    The final balance equals the `Arrears` fold
    (`Tenancy.balance_cents/1`) — Σ is order-invariant.
  - `days_behind` per row = `occurred_on − oldest_unpaid_due_date` as-at that row, or
    `0` when paid-up (`oldest_unpaid_due_date` is `nil`) — a stable non-null integer.

  The FIFO `oldest_unpaid_due_date/2` and `days_behind/2` here mirror the semantics of
  `Latchkey.PropertyManagement.Tenancy` (kept as a **local copy** rather than editing
  that module, which is a separate lane) so the timeline's final balance and
  days-behind stay in parity with the `Arrears` read model.

  Integrity is the log's concern (#16), not the timeline's — this module hashes
  nothing; it is a faithful, rebuildable fold (ADR 0006 §8).
  """

  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Tenancy.Events, as: E
  alias Latchkey.PropertyManagement.Timeline.Entry

  @doc """
  Read edge: fold a tenancy's persisted stream into its timeline. Reads only.
  """
  @spec for_tenancy(String.t()) :: [Entry.t()]
  def for_tenancy(tenancy_id) when is_binary(tenancy_id) do
    ("tenancy-" <> tenancy_id)
    |> EventStore.stream_forward()
    |> Enum.map(fn %{stream_version: version, data: data} -> {version, data} end)
    |> fold()
  end

  @doc """
  Pure fold: `[{stream_sequence, event}]` → ordered `[Entry.t()]`.

  `stream_sequence` is the event's per-stream append position; in a unit test it is
  supplied explicitly so ordering is deterministic without any store metadata.
  """
  @spec fold([{non_neg_integer(), struct()}]) :: [Entry.t()]
  def fold(positioned) when is_list(positioned) do
    positioned
    |> Enum.map(fn {sequence, event} -> {sequence, normalize(event)} end)
    |> Enum.sort_by(fn {sequence, n} -> {Date.to_erl(n.occurred_on), sequence} end)
    |> Enum.reduce(%{entries: [], balance: 0, charges: [], payments: 0}, &fold_row/2)
    |> Map.fetch!(:entries)
    |> Enum.reverse()
  end

  # ── fold step ──────────────────────────────────────────────────────────────

  defp fold_row({_sequence, n}, acc) do
    {debit, credit} = money(n)
    balance = acc.balance + (debit || 0) - (credit || 0)

    charges =
      if n.kind == :rent_fell_due do
        acc.charges ++ [{n.occurred_on, n.amount_cents}]
      else
        acc.charges
      end

    # Both a forward payment and a reversal move the FIFO payments total: a reversal's
    # `amount_cents` is negative, so absorbing it un-pays the credit it undoes and the
    # oldest-unpaid due date (and `days_behind`) honestly climbs back (ADR 0006 §7).
    payments =
      if n.kind in [:payment, :reversal] do
        acc.payments + n.amount_cents
      else
        acc.payments
      end

    days_behind = days_behind(oldest_unpaid_due_date(charges, payments), n.occurred_on)
    {period_from, period_to} = period(n)

    entry = %Entry{
      tenancy_id: n.tenancy_id,
      kind: n.kind,
      occurred_on: n.occurred_on,
      recorded_on: n.recorded_on,
      description: describe(n),
      debit_cents: debit,
      credit_cents: credit,
      balance_snapshot_cents: balance,
      days_behind: days_behind,
      period_from: period_from,
      period_to: period_to,
      kick_in_date: kick_in(n),
      reason: Map.get(n, :reason),
      reverses: Map.get(n, :reverses)
    }

    %{
      acc
      | entries: [entry | acc.entries],
        balance: balance,
        charges: charges,
        payments: payments
    }
  end

  # ── as-at snapshots (local copies of the Tenancy fold semantics, for parity) ──

  # FIFO: earliest due date whose cumulative charge exceeds cumulative payments; nil
  # when paid up. Mirrors `Latchkey.PropertyManagement.Tenancy.oldest_unpaid_due_date/1`.
  defp oldest_unpaid_due_date(charges, payments_total) do
    charges
    |> Enum.reduce_while(0, fn {due_date, amount}, cumulative ->
      cumulative = cumulative + amount

      if cumulative > payments_total do
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

  # Mirrors `Latchkey.PropertyManagement.Tenancy.days_behind/2`: 0 when paid up.
  defp days_behind(nil, _occurred_on), do: 0

  defp days_behind(%Date{} = oldest, %Date{} = occurred_on),
    do: max(0, Date.diff(occurred_on, oldest))

  # ── per-kind rendering ───────────────────────────────────────────────────────

  defp money(%{kind: :rent_fell_due, amount_cents: amount}), do: {amount, nil}
  defp money(%{kind: :payment, amount_cents: amount}), do: {nil, amount}
  # A reversal's `amount_cents` is negative; sign picks the column (ADR 0006 §7) — it
  # re-expands into the debit column as a positive magnitude, never a "negative credit".
  defp money(%{kind: :reversal, amount_cents: amount}), do: {-amount, nil}
  defp money(_marker), do: {nil, nil}

  defp period(%{kind: :rent_fell_due, occurred_on: due}), do: {due, Date.add(due, 6)}
  defp period(_other), do: {nil, nil}

  defp kick_in(%{kind: :notice_given, termination_date: date}), do: date
  defp kick_in(_other), do: nil

  defp describe(%{kind: :commenced}), do: "Tenancy commenced"
  defp describe(%{kind: :rent_fell_due}), do: "Rent due"
  defp describe(%{kind: :payment}), do: "Payment received"

  # ACL-1 propagates the reversal's `reason`; degrade to a bare label when it is absent
  # (a pre-ACL-1 or unexplained reversal still renders honestly — spec dependency note).
  defp describe(%{kind: :reversal, reason: reason}) when is_binary(reason) and reason != "",
    do: "Payment reversed — #{reason}"

  defp describe(%{kind: :reversal}), do: "Payment reversed"

  defp describe(%{kind: :notice_given, termination_date: date}) do
    "Termination notice served (arrears) — takes effect #{Date.to_iso8601(date)}"
  end

  # ── normalize event structs → a uniform map (dates coerced from JSON strings) ──

  defp normalize(%E.TenancyCommenced{} = e) do
    %{
      kind: :commenced,
      tenancy_id: e.tenancy_id,
      occurred_on: to_date(e.occurred_on),
      recorded_on: to_date(e.recorded_on),
      amount_cents: e.rent_amount_cents
    }
  end

  defp normalize(%E.RentFellDue{} = e) do
    %{
      kind: :rent_fell_due,
      tenancy_id: e.tenancy_id,
      occurred_on: to_date(e.occurred_on),
      recorded_on: to_date(e.recorded_on),
      amount_cents: e.amount_cents
    }
  end

  # Sign selects the kind (ADR 0006 §7): a negative amount is a reversal (rendered as a
  # debit), a positive amount a forward payment (credit). `reason`/`reverses` are carried
  # through — ACL-1 sets them only on the reversal path, `nil` on the forward path.
  defp normalize(%E.RentPaymentRecorded{amount_cents: amount} = e) do
    %{
      kind: if(amount < 0, do: :reversal, else: :payment),
      tenancy_id: e.tenancy_id,
      occurred_on: to_date(e.occurred_on),
      recorded_on: to_date(e.recorded_on),
      amount_cents: amount,
      reason: e.reason,
      reverses: e.reverses
    }
  end

  defp normalize(%E.TerminationNoticeGiven{} = e) do
    %{
      kind: :notice_given,
      tenancy_id: e.tenancy_id,
      occurred_on: to_date(e.occurred_on),
      recorded_on: to_date(e.recorded_on),
      termination_date: to_date(e.termination_date)
    }
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)
end
