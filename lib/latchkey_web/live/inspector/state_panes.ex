defmodule LatchkeyWeb.Inspector.StatePanes do
  @moduledoc """
  The read-only **write-vs-read duel** — the money-shot of the tenancy stream view
  (`LatchkeyWeb.InspectorLive`, spec `docs/spec/developer-view.md`, issue #83,
  decisions **D1/D2**), in the editorial "stream-detail" language: what the log *folds
  into*, with the two folds facing each other.

  Two panes, one fold, with the **consistency check as the seam** between them:

  - the **aggregate-state pane** (write model) renders the folded `%Tenancy.State{}`
    core — the consistency boundary that guards the invariants;
  - the **read-model pane** renders the `Arrears` fields (balance, oldest-unpaid,
    `days_behind`, status) **derived off that same core**.

  Both come from `Latchkey.PropertyManagement.ArrearsFold.fold_and_derive/1` (the
  **one shared fold** the operational `ArrearsProjector` also runs, D1), so what the
  inspector teaches is the real fold. The **consistency check** shows the full-prefix
  recompute equalling the live `Arrears` row, field for field: *two folds, do they
  agree?*

  Presentational only. It renders the pre-folded state it is handed — it reads no
  store, writes nothing, and exposes **no** create/update/delete affordance. The log
  is **append-only / immutable** (never "tamper-evident" — issue #16); the live
  read-model row is **read** for the check, never rewound (brief cut #4).
  """
  use LatchkeyWeb, :html

  @doc """
  The write-vs-read duel and the consistency check for one tenancy stream. `state`
  is the folded `%Tenancy.State{}` core, `derived` the `ArrearsFold` struct off that
  core, and `consistency` either an `ArrearsFold.reconcile/2` report or `:no_live_row`
  when the stream has no projected `Arrears` row to check against.
  """
  attr :stream_id, :string, required: true
  attr :state, :map, required: true, doc: "the folded %Tenancy.State{} core"
  attr :derived, :map, required: true, doc: "the ArrearsFold struct (read-model fields)"
  attr :consistency, :any, required: true, doc: "reconcile/2 report or :no_live_row"
  attr :docs, :map, required: true, doc: "canonical doc URLs for read-more links"

  def fold_panes(assigns) do
    ~H"""
    <section id="fold-panes">
      <div class="sd-duel">
        <%!-- ── Aggregate-state pane (write model) ──────────────────────────── --%>
        <div id="aggregate-state-pane" class="sd-pane sd-write">
          <h3><span class="sd-badge sd-write">write model</span> Aggregate</h3>
          <p id="aggregate-caption" class="sd-note">
            the consistency boundary — folds events, guards invariants, never read by
            reports.
            <.link navigate={"#{@docs.domain_model}#4-the-tenancy-aggregate"} class="sd-readmore">
              domain-model.md §4
            </.link>
          </p>
          <dl class="sd-fields">
            <.field id="aggregate-status" label="status">
              <.status_spill status={@state.status} />
            </.field>
            <.field id="aggregate-rent-amount" label="rent_amount">
              {money(@state.rent_amount_cents)}
            </.field>
            <.field id="aggregate-charges" label="charges">
              {length(@state.charges)} booked
            </.field>
            <.field id="aggregate-due-through" label="due_through">
              {fmt(@state.due_through)}
            </.field>
            <.field id="aggregate-payments-total" label="payments_total" count>
              {money(@state.payments_total_cents)}
            </.field>
          </dl>
        </div>

        <%!-- ── The seam: the balance both folds must agree on ──────────────── --%>
        <div class="sd-seam">
          <div class="sd-conn"></div>
          <div class="sd-eq">balance<br />=<br />{money(@derived.balance_cents)}<br />=</div>
          <div class="sd-conn"></div>
        </div>

        <%!-- ── Read-model pane (derived off the same core) ─────────────────── --%>
        <div id="read-model-pane" class="sd-pane sd-read">
          <h3><span class="sd-badge sd-read">read model</span> Arrears</h3>
          <p id="read-model-caption" class="sd-note">
            a disposable projection off the same core — rebuildable from the log at any
            time.
            <.link navigate={"#{@docs.domain_model}#7-arrears"} class="sd-readmore">
              domain-model.md §7
            </.link>
          </p>
          <dl class="sd-fields">
            <.field id="read-model-status" label="status">
              <.status_spill status={@derived.status} />
            </.field>
            <.field id="read-model-balance" label="balance" count>
              {money(@derived.balance_cents)}
            </.field>
            <.field id="read-model-oldest-unpaid" label="oldest_unpaid">
              {fmt(@derived.oldest_unpaid_due_date)}
            </.field>
            <.field id="read-model-days-behind" label="days_behind" count>
              {@derived.days_behind} days
            </.field>
          </dl>
        </div>
      </div>

      <%!-- ── Consistency check — the verdict on the seam (D1) ─────────────── --%>
      <div
        id="consistency-check"
        class={["sd-consist", consistency_drift?(@consistency) && "sd-drift"]}
      >
        <span class="sd-ck">{consistency_mark(@consistency)}</span>
        <%= case @consistency do %>
          <% :no_live_row -> %>
            <span id="consistency-no-live-row">
              No live read-model row is projected for this stream yet — nothing to check
              against.
            </span>
          <% %{consistent?: true} -> %>
            <span>
              <span id="consistency-verdict" class="sd-mono">in sync</span>
              — write &amp; read agree · both are folds of the same log.
            </span>
          <% _ -> %>
            <span>
              <span id="consistency-verdict" class="sd-mono">drifted</span>
              — the recompute differs from the live row (see below).
            </span>
        <% end %>
      </div>

      <%!-- The field-by-field recompute vs the live row: immutability made visible. --%>
      <div :if={@consistency != :no_live_row} class="sd-pane" style="margin-top:12px">
        <p id="consistency-caption" class="sd-note">
          The read model is <b>just a fold of the log</b>: re-folding the full stream in
          memory reproduces the live <code class="sd-mono">Arrears</code>
          row, field for field. Nothing is edited here — the log is <b>append-only /
          immutable</b>, and the recompute is read-only.
        </p>
        <dl class="sd-fields" style="grid-template-columns:1fr auto auto auto">
          <dt>field</dt>
          <dd>recomputed</dd>
          <dd>live</dd>
          <dd>✓</dd>
          <div :for={f <- @consistency.fields} class="contents">
            <dt id={"consistency-field-#{f.field}"}>{f.field}</dt>
            <dd>{fmt(f.recomputed)}</dd>
            <dd>{fmt(f.live)}</dd>
            <dd style={"color:#{if f.match?, do: "var(--sd-ok)", else: "var(--sd-debit)"}"}>
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

  attr :count, :boolean,
    default: false,
    doc: "numeric field the fold animation counts to on scrub"

  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <dt>{@label}</dt>
    <dd id={@id} data-fold-field data-fold-count={@count}>
      {render_slot(@inner_block)}
    </dd>
    """
  end

  # A status atom → a coloured spill. Unknown statuses read as "current"-toned.
  attr :status, :any, required: true

  defp status_spill(assigns) do
    assigns = assign(assigns, :tone, status_tone(assigns.status))

    ~H"""
    <span class={["sd-spill", @tone]}>{fmt(@status)}</span>
    """
  end

  defp status_tone(:arrears), do: "sd-arrears"
  defp status_tone(:settled), do: "sd-settled"
  defp status_tone(:closed), do: "sd-settled"
  defp status_tone(:pre), do: "sd-pre"
  defp status_tone(nil), do: "sd-pre"
  defp status_tone(_), do: "sd-current"

  defp consistency_drift?(:no_live_row), do: false
  defp consistency_drift?(%{consistent?: consistent?}), do: not consistent?

  defp consistency_mark(:no_live_row), do: "—"
  defp consistency_mark(%{consistent?: true}), do: "✓"
  defp consistency_mark(_), do: "≠"

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
