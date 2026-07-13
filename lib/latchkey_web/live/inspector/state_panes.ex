defmodule LatchkeyWeb.Inspector.StatePanes do
  @moduledoc """
  The read-only **aggregate-state + read-model panes** — the write-vs-read
  money-shot (`LatchkeyWeb.InspectorLive`, spec `docs/spec/developer-view.md`,
  issue #83, decisions **D1/D2**): beside a tenancy stream's event log, what the
  log *folds into*.

  Two panes, one fold:

  - the **aggregate-state pane** renders the folded `%Tenancy.State{}` core — the
    write model's consistency boundary (status, charges, `due_through`,
    `effective_end_date`, …);
  - the **read-model pane** renders the `Arrears` fields (balance, oldest-unpaid,
    `days_behind`, status) **derived off that same core**.

  Both come from `Latchkey.PropertyManagement.ArrearsFold.fold_and_derive/1` at
  full history — the **one shared fold** the operational `ArrearsProjector` also
  runs (D1), so what the inspector teaches is the real fold, not a lookalike. A
  **consistency check** then shows the full-prefix recompute equalling the live
  `Arrears` row: *the read model is just a fold of the log.*

  Presentational only. It renders the pre-folded state it is handed — it reads no
  store, writes nothing, and exposes **no** create/update/delete affordance. The
  log is **append-only / immutable** (never "tamper-evident" — issue #16); the
  live read-model row is **read** for the check, never rewound (brief cut #4).
  """
  use LatchkeyWeb, :html

  import LatchkeyWeb.InspectorComponents, only: [caption: 1, read_more: 1]

  @doc """
  The aggregate-state + read-model panes and the consistency check for one
  tenancy stream. `state` is the folded `%Tenancy.State{}` core, `derived` the
  `ArrearsFold` struct off that core, and `consistency` either an
  `ArrearsFold.reconcile/2` report or `:no_live_row` when the stream has no
  projected `Arrears` row to check against.
  """
  attr :stream_id, :string, required: true
  attr :state, :map, required: true, doc: "the folded %Tenancy.State{} core"
  attr :derived, :map, required: true, doc: "the ArrearsFold struct (read-model fields)"
  attr :consistency, :any, required: true, doc: "reconcile/2 report or :no_live_row"
  attr :docs, :map, required: true, doc: "canonical doc URLs for read-more links"

  def fold_panes(assigns) do
    ~H"""
    <section id="fold-panes" class="mt-8 max-w-3xl space-y-6">
      <%!-- ── Aggregate-state pane (write model) ────────────────────────────── --%>
      <div id="aggregate-state-pane" class="rounded-xl border border-primary/50 bg-base-100 p-4">
        <header class="mb-2 flex items-center gap-2">
          <span class="badge badge-sm badge-primary">write model</span>
          <h3 class="text-sm font-semibold">Aggregate state</h3>
          <span class="ml-auto font-mono text-[11px] text-base-content/40" phx-no-curly-interpolation>%Tenancy.State{}</span>
        </header>

        <.caption id="aggregate-caption" class="mb-3">
          The <b>aggregate</b>
          — the consistency boundary that <b>folds from the events on the
          left</b>
          (<code class="font-mono">Tenancy.evolve/2</code>). It holds the state the write
          model needs to enforce its invariants; it is <b>never</b>
          read by reports, only by the
          aggregate's own decisions.
          <.read_more href={"#{@docs.domain_model}#4-the-tenancy-aggregate"}>
            domain-model.md §4
          </.read_more>
        </.caption>

        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-[11px]">
          <.field id="aggregate-status" label="status">
            <span class="badge badge-sm badge-ghost font-mono">{@state.status}</span>
          </.field>
          <.field id="aggregate-rent-amount" label="rent_amount_cents">
            {money(@state.rent_amount_cents)}
          </.field>
          <.field id="aggregate-cycle" label="cycle">{fmt(@state.cycle)}</.field>
          <.field id="aggregate-first-due-date" label="first_due_date">
            {fmt(@state.first_due_date)}
          </.field>
          <.field id="aggregate-due-through" label="due_through">{fmt(@state.due_through)}</.field>
          <.field id="aggregate-charges" label="charges">
            {length(@state.charges)} booked · {money(charges_total(@state.charges))}
          </.field>
          <.field id="aggregate-payments-total" label="payments_total_cents">
            {money(@state.payments_total_cents)}
          </.field>
          <.field id="aggregate-applied-payments" label="applied_payment_ids">
            {MapSet.size(@state.applied_payment_ids)} applied
          </.field>
          <.field id="aggregate-effective-end-date" label="effective_end_date">
            {fmt(@state.effective_end_date)}
          </.field>
          <.field id="aggregate-keys-returned-on" label="keys_returned_on">
            {fmt(@state.keys_returned_on)}
          </.field>
          <.field id="aggregate-final-balance" label="final_balance_cents">
            {money(@state.final_balance_cents)}
          </.field>
        </dl>
      </div>

      <%!-- ── Read-model pane (derived off the same core) ───────────────────── --%>
      <div id="read-model-pane" class="rounded-xl border border-info/50 bg-base-100 p-4">
        <header class="mb-2 flex items-center gap-2">
          <span class="badge badge-sm badge-info">read model</span>
          <h3 class="text-sm font-semibold">Arrears</h3>
          <span class="ml-auto font-mono text-[11px] text-base-content/40">derived</span>
        </header>

        <.caption id="read-model-caption" class="mb-3">
          A <b>derived, disposable report</b>
          folded off the <b>same aggregate core</b>
          — a
          projection, never the arrears gate (that reads the aggregate). It is rebuildable from the
          log at any time; <code class="font-mono">days_behind</code>
          is computed on read, here as-at the prefix's last event.
          <.read_more href={"#{@docs.domain_model}#7-arrears"}>domain-model.md §7</.read_more>
        </.caption>

        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-[11px]">
          <.field id="read-model-status" label="status">
            <span class="badge badge-sm badge-ghost font-mono">{@derived.status}</span>
          </.field>
          <.field id="read-model-balance" label="balance_cents">
            {money(@derived.balance_cents)}
          </.field>
          <.field id="read-model-oldest-unpaid" label="oldest_unpaid_due_date">
            {fmt(@derived.oldest_unpaid_due_date)}
          </.field>
          <.field id="read-model-days-behind" label="days_behind">
            {@derived.days_behind} days
          </.field>
          <.field id="read-model-final-balance" label="final_balance_cents">
            {money(@derived.final_balance_cents)}
          </.field>
        </dl>
      </div>

      <%!-- ── Consistency check (immutability made visible, D1) ─────────────── --%>
      <div
        id="consistency-check"
        class={[
          "rounded-xl border p-4 bg-base-100",
          consistency_border(@consistency)
        ]}
      >
        <header class="mb-2 flex items-center gap-2">
          <h3 class="text-sm font-semibold">Consistency check</h3>
          <span
            :if={@consistency != :no_live_row}
            id="consistency-verdict"
            class={[
              "ml-auto badge badge-sm",
              if(@consistency.consistent?, do: "badge-success", else: "badge-error")
            ]}
          >
            {if(@consistency.consistent?, do: "in sync", else: "drifted")}
          </span>
        </header>

        <.caption id="consistency-caption" class="mb-3">
          The read model is <b>just a fold of the log</b>: re-folding the full stream in memory
          reproduces the live <code class="font-mono">Arrears</code>
          row, field for field. Nothing is edited here — the log is <b>append-only / immutable</b>, and the recompute is read-only.
        </.caption>

        <p
          :if={@consistency == :no_live_row}
          id="consistency-no-live-row"
          class="text-[11px] italic text-base-content/50"
        >
          No live read-model row is projected for this stream yet — nothing to check against.
        </p>

        <dl
          :if={@consistency != :no_live_row}
          class="grid grid-cols-[1fr_auto_auto_auto] gap-x-4 gap-y-1 text-[11px]"
        >
          <dt class="font-semibold text-base-content/50">field</dt>
          <dd class="font-semibold text-base-content/50">recomputed</dd>
          <dd class="font-semibold text-base-content/50">live</dd>
          <dd class="font-semibold text-base-content/50 text-right">✓</dd>

          <div :for={f <- @consistency.fields} class="contents">
            <dt id={"consistency-field-#{f.field}"} class="font-mono text-base-content/70">
              {f.field}
            </dt>
            <dd class="font-mono">{fmt(f.recomputed)}</dd>
            <dd class="font-mono">{fmt(f.live)}</dd>
            <dd class={["text-right font-mono", if(f.match?, do: "text-success", else: "text-error")]}>
              {if(f.match?, do: "=", else: "≠")}
            </dd>
          </div>
        </dl>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <dt class="font-mono text-base-content/50">{@label}</dt>
    <dd id={@id} class="font-mono break-all">{render_slot(@inner_block)}</dd>
    """
  end

  defp consistency_border(:no_live_row), do: "border-base-300"
  defp consistency_border(%{consistent?: true}), do: "border-success/50"
  defp consistency_border(%{consistent?: false}), do: "border-error/50"

  defp charges_total(charges),
    do: Enum.reduce(charges, 0, fn {_due, amount}, acc -> acc + amount end)

  # Render a signed cents amount as dollars (a nil amount reads "—").
  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    dollars = div(abs_cents, 100)
    remainder = rem(abs_cents, 100)
    "#{sign}$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end

  # Render a folded state / read-model value (dates, atoms, ints, nils) for display.
  defp fmt(%Date{} = d), do: Date.to_iso8601(d)
  defp fmt(nil), do: "—"
  defp fmt(value) when is_binary(value), do: value
  defp fmt(value) when is_atom(value), do: Atom.to_string(value)
  defp fmt(value) when is_integer(value), do: Integer.to_string(value)
  defp fmt(value), do: inspect(value)
end
