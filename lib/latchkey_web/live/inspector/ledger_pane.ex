defmodule LatchkeyWeb.Inspector.LedgerPane do
  @moduledoc """
  The read-only **double-entry ledger pane** — the accounting lens on a tenancy
  stream (`LatchkeyWeb.InspectorLive`, spec `docs/spec/developer-view.md` D1,
  issue #84, ADR 0006), in the editorial "stream-detail" language: the same events
  the write and read models fold, viewed as a standardised rent statement.

  One fold, the money view: rows come from `Latchkey.PropertyManagement.Timeline.fold/1`
  — the pure, compute-on-read prefix fold (ADR 0006). `RentFellDue` posts a **debit**,
  `RentPaymentRecorded` a **credit**, and the running balance is `Σ debits − Σ credits`
  folded in `(occurred_on, stream_sequence)` order (D1). A **reversal** — a *negative*
  `RentPaymentRecorded` — is re-expanded into the **debit** column at its own
  `occurred_on` as a positive magnitude (ADR 0006 §7): **shown, never hidden, never a
  negative credit**.

  The ledger's **final balance equals the read-model pane's balance** (Σ is
  order-invariant; both fold the same events), surfaced explicitly: *the ledger and
  the read model are the same fold.*

  Presentational only. It renders the pre-folded `Timeline.Entry` rows it is handed —
  it reads no store, writes nothing, and exposes **no** create/update/delete
  affordance. The log is **append-only / immutable** (never "tamper-evident" — #16).
  """
  use LatchkeyWeb, :html

  @doc """
  The double-entry ledger pane for one tenancy stream. `entries` is the ordered
  `Timeline.Entry` list from `Timeline.fold/1`, and `read_model_balance_cents` is the
  read-model pane's `balance_cents` (surfaced as the final-balance equivalence).
  """
  attr :stream_id, :string, required: true
  attr :entries, :list, required: true, doc: "ordered Timeline.Entry rows from Timeline.fold/1"

  attr :read_model_balance_cents, :integer,
    required: true,
    doc: "the read-model pane's balance_cents, for the final-balance equivalence"

  attr :docs, :map, required: true, doc: "canonical doc URLs for read-more links"

  def ledger_pane(assigns) do
    ledger_final = ledger_final_balance(assigns.entries)
    last_index = length(assigns.entries) - 1

    assigns =
      assigns
      |> assign(:ledger_final, ledger_final)
      |> assign(:last_index, last_index)
      |> assign(:balances_match?, ledger_final == assigns.read_model_balance_cents)

    ~H"""
    <section id="ledger-pane">
      <p id="ledger-caption" class="sd-note">
        The <b>rental ledger</b>
        — the same events as a two-column money statement. A charge posts a <b>debit</b>, a payment a <b>credit</b>, and the running balance is <code class="sd-mono">Σ debits − Σ credits</code>. A
        <b>reversal</b>
        shows as a debit, never a negative credit — corrections are compensating, not
        erasures. Folded on read from the <b>append-only / immutable</b>
        log; nothing
        here is edited.
        <.link navigate={"#{@docs.domain_model}#7-arrears"} class="sd-readmore">
          domain-model.md §7
        </.link>
      </p>

      <div class="sd-ledger">
        <table>
          <thead>
            <tr>
              <th>Date</th>
              <th>Entry</th>
              <th>Period</th>
              <th>Debit</th>
              <th>Credit</th>
              <th>Balance</th>
            </tr>
          </thead>
          <tbody id="ledger-rows">
            <tr :if={@entries == []} id="ledger-empty">
              <td colspan="6" style="font-style:italic;color:var(--sd-muted)">
                Nothing folded yet — no ledger entries at this prefix.
              </td>
            </tr>

            <tr
              :for={{entry, i} <- Enum.with_index(@entries)}
              id={"ledger-row-#{@stream_id}-#{i}"}
              class={[i == @last_index && "sd-new"]}
            >
              <td>{fmt_date(entry.occurred_on)}</td>
              <td style="text-align:left">
                <span
                  id={"ledger-kind-#{@stream_id}-#{i}"}
                  class="sd-mono"
                  style="color:var(--sd-muted)"
                >
                  {entry.kind}
                </span>
                <span>{entry.description}</span>
              </td>
              <td id={"ledger-period-#{@stream_id}-#{i}"}>{period(entry)}</td>
              <td id={"ledger-debit-#{@stream_id}-#{i}"} class="sd-deb">
                {money(entry.debit_cents)}
              </td>
              <td id={"ledger-credit-#{@stream_id}-#{i}"} class="sd-cre">
                {money(entry.credit_cents)}
              </td>
              <td id={"ledger-balance-#{@stream_id}-#{i}"}>{money(entry.balance_snapshot_cents)}</td>
            </tr>
          </tbody>
        </table>
        <div id="ledger-balance-equivalence" class="sd-cap">
          <span>final</span>
          <b id="ledger-final-balance" class="sd-mono">{money(@ledger_final)}</b>
          <span
            id="ledger-balance-verdict"
            style={"color:#{if @balances_match?, do: "var(--sd-ok)", else: "var(--sd-debit)"}"}
          >
            {if(@balances_match?, do: "matches read model ✓", else: "differs from read model")}
          </span>
        </div>
      </div>

      <p id="ledger-equivalence-caption" class="sd-note">
        The ledger's running balance and the read-model <code class="sd-mono">balance_cents</code>
        are the <b>same fold</b>
        of the same log — <code class="sd-mono">Σ debits − Σ credits</code>
        is order-invariant, so they agree by construction.
      </p>
    </section>
    """
  end

  # The folded final balance = the last row's running snapshot, or 0 for an empty
  # stream. Σ is order-invariant, so this equals the read model's `balance_cents`.
  defp ledger_final_balance([]), do: 0

  defp ledger_final_balance(entries),
    do: entries |> List.last() |> Map.fetch!(:balance_snapshot_cents)

  # A charge carries the half-open `[period_from, period_to)` span the debit pays for;
  # other rows have no period. Rendered `from → to` so the interval is legible.
  defp period(%{period_from: %Date{} = from, period_to: %Date{} = to}),
    do: "#{Date.to_iso8601(from)} → #{Date.to_iso8601(to)}"

  defp period(_entry), do: "—"

  defp fmt_date(%Date{} = d), do: Date.to_iso8601(d)
  defp fmt_date(_), do: "—"

  # Render a cents amount as dollars; a nil column (the other side of a single-sided
  # posting) reads as the empty marker so a debit is never shown as a negative credit.
  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    dollars = div(abs_cents, 100)
    remainder = rem(abs_cents, 100)
    "#{sign}$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end
end
