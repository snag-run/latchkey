defmodule LatchkeyWeb.Inspector.LedgerPane do
  @moduledoc """
  The read-only **double-entry ledger pane** — the accounting lens on a tenancy
  stream (`LatchkeyWeb.InspectorLive`, spec `docs/spec/developer-view.md` D1,
  issue #84, ADR 0006): beside the event log and the fold panes, the standardized
  rent statement the same events fold into.

  One fold, the money view: rows come from `Latchkey.PropertyManagement.Timeline.fold/1`
  — itself the pure, compute-on-read prefix fold (ADR 0006), the very query the
  per-tenancy timeline runs. `RentFellDue` posts a **debit**, `RentPaymentRecorded`
  a **credit**, and the running balance is `Σ debits − Σ credits` folded in
  `(occurred_on, stream_sequence)` order (D1). A **reversal** — a *negative*
  `RentPaymentRecorded` — is re-expanded into the **debit** column at its own
  `occurred_on` as a positive magnitude (ADR 0006 §7): it is **shown, never hidden,
  never a negative credit**, restoring the balance the reversed credit had reduced.

  Each charge row also carries its half-open **`[period_from, period_to)`** span —
  the rent period the debit pays for — because the periods are the evidence.

  The ledger's **final balance equals the read-model pane's balance** (Σ is
  order-invariant; both fold the same events), and the pane surfaces that
  equivalence explicitly: *the ledger and the read model are the same fold.*

  Presentational only. It renders the pre-folded `Timeline.Entry` rows it is handed
  — it reads no store, writes nothing, and exposes **no** create/update/delete
  affordance. The log is **append-only / immutable** (never "tamper-evident" —
  issue #16).
  """
  use LatchkeyWeb, :html

  import LatchkeyWeb.InspectorComponents, only: [caption: 1, read_more: 1]

  @doc """
  The double-entry ledger pane for one tenancy stream. `entries` is the ordered
  `Timeline.Entry` list from `Timeline.fold/1`, `read_model_balance_cents` is the
  read-model pane's `balance_cents` (surfaced as the final-balance equivalence),
  and `docs` carries the canonical "read more" URLs.
  """
  attr :stream_id, :string, required: true
  attr :entries, :list, required: true, doc: "ordered Timeline.Entry rows from Timeline.fold/1"

  attr :read_model_balance_cents, :integer,
    required: true,
    doc: "the read-model pane's balance_cents, for the final-balance equivalence"

  attr :docs, :map, required: true, doc: "canonical doc URLs for read-more links"

  def ledger_pane(assigns) do
    ledger_final = ledger_final_balance(assigns.entries)

    assigns =
      assigns
      |> assign(:ledger_final, ledger_final)
      |> assign(:balances_match?, ledger_final == assigns.read_model_balance_cents)

    ~H"""
    <section
      id="ledger-pane"
      class="mt-6 max-w-3xl rounded-xl border border-secondary/50 bg-base-100 p-4"
    >
      <header class="mb-2 flex items-center gap-2">
        <span class="badge badge-sm badge-secondary">read model</span>
        <h3 class="text-sm font-semibold">Rental ledger</h3>
        <span class="ml-auto font-mono text-[11px] text-base-content/40">double-entry</span>
      </header>

      <.caption id="ledger-caption" class="mb-3">
        The <b>rental ledger</b>
        — the same events as a two-column money statement. A rent charge posts a <b>debit</b>, a payment a <b>credit</b>, and the running balance is <code class="font-mono">Σ debits − Σ credits</code>. A
        <b>reversal</b>
        is shown as a <b>debit</b>, never a negative credit — corrections are
        compensating, not erasures. Folded on read from the <b>append-only / immutable</b>
        log; nothing here is edited.
        <.read_more href={"#{@docs.domain_model}#7-arrears"}>domain-model.md §7</.read_more>
      </.caption>

      <div class="overflow-x-auto">
        <table class="w-full text-[11px]">
          <thead>
            <tr class="border-b border-base-300 text-left text-base-content/50">
              <th class="py-1 pr-3 font-semibold">Date</th>
              <th class="py-1 pr-3 font-semibold">Entry</th>
              <th class="py-1 pr-3 font-semibold">Period</th>
              <th class="py-1 pr-3 text-right font-semibold">Debit</th>
              <th class="py-1 pr-3 text-right font-semibold">Credit</th>
              <th class="py-1 text-right font-semibold">Balance</th>
            </tr>
          </thead>
          <tbody id="ledger-rows">
            <tr :if={@entries == []} id="ledger-empty">
              <td colspan="6" class="py-3 italic text-base-content/50">
                No ledger entries on this stream yet.
              </td>
            </tr>

            <tr
              :for={{entry, i} <- Enum.with_index(@entries)}
              id={"ledger-row-#{@stream_id}-#{i}"}
              class="border-b border-base-200/70 align-top"
            >
              <td class="py-1.5 pr-3 whitespace-nowrap font-mono text-base-content/70">
                {fmt_date(entry.occurred_on)}
              </td>
              <td class="py-1.5 pr-3">
                <span id={"ledger-kind-#{@stream_id}-#{i}"} class="font-mono text-base-content/50">
                  {entry.kind}
                </span>
                <span class="ml-1.5">{entry.description}</span>
              </td>
              <td
                id={"ledger-period-#{@stream_id}-#{i}"}
                class="py-1.5 pr-3 whitespace-nowrap font-mono text-base-content/60"
              >
                {period(entry)}
              </td>
              <td id={"ledger-debit-#{@stream_id}-#{i}"} class="py-1.5 pr-3 text-right font-mono">
                {money(entry.debit_cents)}
              </td>
              <td id={"ledger-credit-#{@stream_id}-#{i}"} class="py-1.5 pr-3 text-right font-mono">
                {money(entry.credit_cents)}
              </td>
              <td
                id={"ledger-balance-#{@stream_id}-#{i}"}
                class="py-1.5 text-right font-mono font-medium"
              >
                {money(entry.balance_snapshot_cents)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Final-balance equivalence: the ledger fold and the read-model fold agree (D1). --%>
      <div
        id="ledger-balance-equivalence"
        class={[
          "mt-3 rounded-lg border p-3",
          if(@balances_match?, do: "border-success/50", else: "border-error/50")
        ]}
      >
        <div class="flex items-center gap-2">
          <span class="text-[11px] font-semibold text-base-content/70">Final balance</span>
          <span id="ledger-final-balance" class="font-mono text-[11px] font-medium">
            {money(@ledger_final)}
          </span>
          <span
            id="ledger-balance-verdict"
            class={[
              "ml-auto badge badge-sm",
              if(@balances_match?, do: "badge-success", else: "badge-error")
            ]}
          >
            {if(@balances_match?, do: "matches read model", else: "differs from read model")}
          </span>
        </div>
        <.caption id="ledger-equivalence-caption" class="mt-1.5">
          The ledger's running balance and the read-model <code class="font-mono">balance_cents</code>
          are the <b>same fold</b>
          of the same log — <code class="font-mono">Σ debits − Σ credits</code>
          is order-invariant, so they agree by construction.
        </.caption>
      </div>
    </section>
    """
  end

  # The folded final balance = the last row's running snapshot, or 0 for an empty
  # stream. Σ is order-invariant, so this equals the read model's `balance_cents`.
  defp ledger_final_balance([]), do: 0

  defp ledger_final_balance(entries),
    do: entries |> List.last() |> Map.fetch!(:balance_snapshot_cents)

  # A charge carries the half-open `[period_from, period_to)` span the debit pays
  # for; other rows have no period. Rendered `from → to` so the interval is legible.
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
