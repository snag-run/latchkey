defmodule LatchkeyWeb.LearnDddLive do
  @moduledoc """
  A "DDD 101" primer at `/learn/ddd`, taught entirely through Latchkey's own
  domain (never invented examples). It walks the four domain-driven-design ideas
  the codebase actually leans on:

    1. **Bounded contexts + context map** — Property Management (core) vs Accounts
       (supporting), and the one modelled seam between them (`docs/context-map.md`).
    2. **Ubiquitous language** — the exact `CONTEXT.md` terms (ledger, arrears,
       `property_ref`, tenancy) used verbatim in code, comments, and commits.
    3. **Aggregate** — the `Tenancy` aggregate as the consistency boundary: one
       stream, its own invariants, decided by folding only its own events.
    4. **Anti-corruption layer** — the payment ACL translating an Accounts payment
       fact into PM's arrears language, never folding the foreign fact raw.

  It renders no live domain data (the illustrations are fixed and internally
  consistent, at 620.00/week to match the landing page); the live event log lives
  at `/inspector`. Styling reuses the shipped warm-paper `sd-*` tokens and the
  `lk-*` components scoped under `.landing` (see `assets/css/app.css`); a small
  primer-specific `lk-*` block is appended there. All motion is CSS-only and gated
  behind `prefers-reduced-motion`; interactivity is limited to the shared theme
  toggle.
  """
  use LatchkeyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "DDD 101 — Latchkey")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.landing flash={@flash}>
      <header class="topbar">
        <div class="row">
          <.link navigate={~p"/"} class="brand" aria-label="Latchkey home">
            <span class="key" aria-hidden="true">L</span>
            Latchkey <small>DDD 101 · a primer by example</small>
          </.link>
          <nav aria-label="Primary">
            <span class="desktop-nav">
              <a class="navlink" href="#contexts">Contexts</a>
              <a class="navlink" href="#language">Language</a>
              <a class="navlink" href="#aggregate">Aggregate</a>
              <a class="navlink" href="#acl">ACL</a>
              <.link class="navlink" navigate={~p"/inspector"}>Inspector</.link>
            </span>
            <Layouts.theme_toggle />
          </nav>
        </div>
      </header>

      <main>
        <%!-- HERO: what this page is --%>
        <section class="wrap lk-hero" aria-label="Domain-driven design by example">
          <div class="split">
            <div class="copy">
              <p class="eyebrow">Domain-driven design · by example</p>
              <h1 class="display">Two contexts, one seam, and a language kept honest.</h1>
              <p class="lede">
                Domain-driven design is a way of building software around the business it models:
                name the boundaries, speak one precise language inside each, and guard the seams
                where they meet. Latchkey models one such seam deeply. This page walks the four DDD
                ideas it actually uses, each grounded in the real model, <span class="em">no toy
                examples</span>.
              </p>
              <div class="cta-row">
                <.link class="lk-btn primary" navigate={~p"/inspector/docs/context-map"}>
                  Read the context map
                </.link>
                <.link class="lk-btn ghost" navigate={~p"/inspector/glossary"}>Open the glossary</.link>
              </div>
              <div class="provenance">
                <span><b>bounded context</b></span><span>ubiquitous language</span>
                <span><b>aggregate</b></span><span>anti-corruption layer</span>
              </div>
            </div>

            <div
              class="corr"
              role="img"
              aria-label="A two-context map: Property Management is the core domain; Accounts is a supporting subdomain; the seam between them is where a payment becomes an arrears reduction, crossed by the payment anti-corruption layer."
            >
              <div class="evt appended">
                <span class="name">Property Management</span>
                <span class="k">core · tenancy, ledger, arrears, the timeline</span>
              </div>
              <div class="lk-seamcap" aria-hidden="true">the seam · payment ACL</div>
              <div class="evt">
                <span class="name">Accounts</span>
                <span class="k">supporting · payments, receipts, reversals</span>
              </div>
              <span class="appended-tag">
                a payment fact crosses the seam and becomes an arrears reduction
              </span>
            </div>
          </div>
        </section>

        <%!-- BOUNDED CONTEXTS + CONTEXT MAP --%>
        <section class="section" id="contexts" aria-label="Bounded contexts and the context map">
          <div class="wrap">
            <div class="sec-head">
              <p class="eyebrow">Idea 1 · Bounded contexts</p>
              <h2 class="display">Draw the boundaries before you model inside them.</h2>
              <p>
                A <b>bounded context</b> is a boundary within which one model and one language hold.
                A <b>context map</b> names the contexts and how they relate. DDD sorts subdomains by
                where modelling effort earns its keep: <b>core</b> is the differentiator you go deep
                on; <b>supporting</b> is necessary but not a differentiator, modelled lightly. Core
                is about being <span class="em">better</span>, not about being important, trust
                accounting is mission-critical yet still supporting, because every agency does it the
                same way and you can buy it off the shelf.
              </p>
            </div>

            <div class="band-inner">
              <div class="side">
                <span class="lk-tag core">Core domain</span>
                <p class="lk-cardhead">Property Management</p>
                <p>
                  The differentiator: tenancy and arrears management, ending in a hash-chained,
                  tribunal-ready <b>timeline</b>. Its deep bounded context is <b>Tenancy &amp;
                  Arrears</b>, the payments seam. This is where Latchkey goes deep, because this is
                  where it can be better.
                </p>
                <div class="provenance">
                  <span><b>tenancy</b></span><span>rent due</span><span><b>arrears</b></span>
                  <span>notice</span><span>timeline</span>
                </div>
              </div>

              <div class="side">
                <span class="lk-tag supporting">Supporting subdomain</span>
                <p class="lk-cardhead">Accounts</p>
                <p>
                  Trust accounting: receipting, the trust ledger, suspense, reversals. Real and
                  necessary, but not the differentiator, so it is <b>stubbed here to its payment-facts
                  edge</b>. It speaks <b>payments</b>, not arrears.
                </p>
                <div class="provenance">
                  <span><b>payment</b></span><span>receipt</span><span>reversal</span>
                  <span>suspense</span>
                </div>
              </div>
            </div>

            <p class="lk-seamnote">
              Only one seam is modelled deeply, <b>Accounts → Tenancy &amp; Arrears</b>: a
              <code class="lk-code">payment</code>
              in Accounts becomes an <code class="lk-code">arrears reduction</code>
              in Property Management. The concept changes meaning as it crosses. That crossing is
              Idea 4.
            </p>

            <div class="cta-row" style="margin-top: 26px;">
              <.link class="lk-btn ghost" navigate={~p"/inspector/docs/context-map"}>
                See the full context map
              </.link>
            </div>
          </div>
        </section>

        <%!-- UBIQUITOUS LANGUAGE --%>
        <section class="section" id="language" aria-label="Ubiquitous language">
          <div class="wrap">
            <div class="sec-head">
              <p class="eyebrow">Idea 2 · Ubiquitous language</p>
              <h2 class="display">One word, one meaning, everywhere.</h2>
              <p>
                Inside a context, the same terms are used by the code, the tests, the commits, and
                the conversation, so nothing is lost in translation. These four are Latchkey's, used
                verbatim from <code class="lk-code">CONTEXT.md</code>. They are not invented for this
                page.
              </p>
            </div>

            <div class="band-inner lk-terms">
              <div class="side">
                <p class="lk-termname mono">ledger</p>
                <p>
                  The rental ledger: a two-column money statement where
                  <code class="lk-code">RentFellDue</code>
                  is a debit and <code class="lk-code">RentPaymentRecorded</code>
                  a credit, and the running balance is Σ debits − Σ credits. A reversal is a negative <code class="lk-code">RentPaymentRecorded</code>, a signed credit that undoes an
                  earlier one, appended never deleted.
                </p>
              </div>

              <div class="side">
                <p class="lk-termname mono">arrears</p>
                <p>
                  Rent owed, the ledger balance when debits run ahead of credits. Counted in <b>days behind</b>, not calendar days, and measured against the 14-day gate. A
                  part-payment can pull a tenancy back under the line.
                </p>
              </div>

              <div class="side">
                <p class="lk-termname mono">property_ref</p>
                <p>
                  The stable, non-PII key naming the premises a tenancy is for. It <b>recurs across
                  successive tenancies</b>
                  of the same property and is carried on <code class="lk-code">TenancyCommenced</code>, so the log never holds a tenant's
                  name (ADR 0008).
                </p>
              </div>

              <div class="side">
                <p class="lk-termname mono">tenancy</p>
                <p>
                  One lease relationship over one premises, modelled as a single append-only event <b>stream</b>. A co-tenant swapping out stays the same tenancy; a genuine re-let is
                  a new tenancy, a new stream, sharing the prior <code class="lk-code">property_ref</code>.
                </p>
              </div>
            </div>

            <div class="cta-row" style="margin-top: 26px;">
              <.link class="lk-btn ghost" navigate={~p"/inspector/glossary"}>
                Browse the full glossary
              </.link>
            </div>
          </div>
        </section>

        <%!-- AGGREGATE --%>
        <section class="section" id="aggregate" aria-label="The Tenancy aggregate">
          <div class="wrap">
            <div class="sec-head">
              <p class="eyebrow">Idea 3 · Aggregate</p>
              <h2 class="display">The Tenancy is the consistency boundary.</h2>
              <p>
                An <b>aggregate</b>
                is the unit that stays consistent as a whole: a boundary you only
                change through one door, by folding its own history. In Latchkey the <b>Tenancy</b>
                is that unit. One tenancy is one stream, and every rule that must always hold is
                decided <span class="em">inside</span>
                it, against nothing but its own events.
              </p>
            </div>

            <div class="band-inner">
              <div>
                <p>
                  The <code class="lk-code">Tenancy</code>
                  aggregate owns its invariants and no others. It refuses a reversal for a payment it
                  never applied. It no-ops a <code class="lk-code">source_payment_id</code>
                  it has already seen, so a replayed fact stays idempotent. It decides whether the
                  14-day arrears gate is crossed.
                </p>
                <p>
                  Because the boundary is one stream, nothing outside can violate a tenancy's rules,
                  and two tenancies stay independent: re-letting the same premises can legitimately
                  double-charge overlapping days, and that is fine, they are separate aggregates that
                  happen to share a <code class="lk-code">property_ref</code>.
                </p>
              </div>

              <div
                class="lk-boundary"
                role="img"
                aria-label="One Tenancy stream: TenancyCommenced, RentFellDue, RentPaymentRecorded, RentFellDue. The dashed outline marks the aggregate's consistency boundary, everything folded to decide its state lives inside it."
              >
                <span class="lk-boundary-tag">Tenancy aggregate · consistency boundary</span>
                <div class="eventlog">
                  <div class="head">
                    <span class="who">Event log</span>
                    <span class="ref">stream: tenancy-a3f9 · append-only</span>
                  </div>
                  <ol class="evstream">
                    <li class="ev">
                      <div class="ev-top">
                        <span class="seq">1</span>
                        <span class="etype">TenancyCommenced</span>
                        <span class="edate">03 Mar</span>
                      </div>
                      <div class="ev-pay"><span class="k">property_ref</span> kent-st-14</div>
                    </li>
                    <li class="ev">
                      <div class="ev-top">
                        <span class="seq">2</span>
                        <span class="etype">RentFellDue</span>
                        <span class="edate">03 Mar</span>
                      </div>
                      <div class="ev-pay"><span class="k">amount</span> 620.00</div>
                    </li>
                    <li class="ev">
                      <div class="ev-top">
                        <span class="seq">3</span>
                        <span class="etype">RentPaymentRecorded</span>
                        <span class="edate">05 Mar</span>
                      </div>
                      <div class="ev-pay"><span class="k">amount</span> 620.00</div>
                    </li>
                    <li class="ev">
                      <div class="ev-top">
                        <span class="seq">4</span>
                        <span class="etype">RentFellDue</span>
                        <span class="edate">10 Mar</span>
                      </div>
                      <div class="ev-pay"><span class="k">amount</span> 620.00</div>
                    </li>
                  </ol>
                  <div class="foot">
                    <span class="stamp">invariants decided here</span>
                    <span>one stream</span>
                  </div>
                </div>
              </div>
            </div>

            <div class="cta-row" style="margin-top: 26px;">
              <.link class="lk-btn ghost" navigate={~p"/inspector/docs/domain-model"}>
                Read the domain model
              </.link>
            </div>
          </div>
        </section>

        <%!-- ANTI-CORRUPTION LAYER --%>
        <section class="section" id="acl" aria-label="The anti-corruption layer">
          <div class="wrap">
            <div class="sec-head">
              <p class="eyebrow">Idea 4 · Anti-corruption layer</p>
              <h2 class="display">Translate at the seam, never fold a foreign fact raw.</h2>
              <p>
                An <b>anti-corruption layer</b>
                sits on a seam and translates, so a neighbour's
                concepts never leak in and corrupt your model. The <b>payment ACL</b>
                is PM's guard
                over the Accounts stream: an Accounts <code class="lk-code">PaymentReceived</code>
                fact is written on the left, translated across the seam, and read as PM's own
                <code class="lk-code">RentPaymentRecorded</code>
                that reduces arrears. Accounts speaks payments; PM speaks arrears; the ACL is where
                one becomes the other.
              </p>
            </div>

            <div class="seam">
              <div class="seam-line" aria-hidden="true"><span class="acl">payment ACL</span></div>

              <div class="side write">
                <span class="side-label">Accounts fact</span>
                <p class="side-sub">
                  The foreign fact, in Accounts' language. Payments, not arrears.
                </p>
                <div class="evt" phx-no-curly-interpolation>
                  <span class="name">PaymentReceived</span>
                  <span class="k">{ holder:</span>
                  tenancy-a3f9<span class="k">, amount:</span>
                  620.00 <span class="k">}</span>
                </div>
                <p class="side-sub" style="margin-top: 16px;">
                  An <code class="lk-code">UNKNOWN</code>
                  holder never crosses. Unmatched money is not folded into arrears.
                </p>
              </div>

              <div class="side read">
                <span class="side-label">PM language</span>
                <p class="side-sub">
                  Translated into a PM command, then the Tenancy emits its own event.
                </p>
                <div class="evt" phx-no-curly-interpolation>
                  <span class="name">RecordPayment</span>
                  <span class="k">{ tenancy_id:</span>
                  a3f9<span class="k">, amount:</span>
                  620.00 <span class="k">}</span>
                </div>
                <div class="evt">
                  <span class="name">RentPaymentRecorded</span>
                  <span class="k">→ credit, reduces</span> arrears
                </div>
                <div class="gate clear">arrears reduced, model uncorrupted</div>
              </div>
            </div>

            <p class="lk-seamnote">
              A <code class="lk-code">PaymentReversed</code>
              crosses the same way, translated to a negative
              <code class="lk-code">RentPaymentRecorded</code>
              that re-opens the arrears. The reversal is appended, never a deletion, so the history
              stays whole.
            </p>

            <div class="cta-row" style="margin-top: 26px;">
              <.link class="lk-btn primary" navigate={~p"/inspector"}>Watch the seam on a real stream</.link>
            </div>
          </div>
        </section>

        <%!-- CLOSE --%>
        <section class="wrap close-band" aria-label="Keep going">
          <p class="formula"><b>boundary</b> + <b>language</b> + <b>translation</b></p>
          <h2 class="display">Model the domain, then let the code speak it.</h2>
          <div class="cta-row">
            <.link class="lk-btn primary" navigate={~p"/inspector"}>Open the inspector</.link>
            <.link class="lk-btn ghost" navigate={~p"/inspector/docs/domain-model"}>
              Read the model
            </.link>
          </div>
        </section>
      </main>

      <footer class="lk-footer">
        <span>A project by <b>David Taing</b></span>
        <span class="sep" aria-hidden="true">·</span>
        <a href="https://snag.run" target="_blank" rel="noopener noreferrer">snag.run</a>
        <span class="sep" aria-hidden="true">·</span>
        <a href="https://github.com/snag-run/latchkey" target="_blank" rel="noopener noreferrer">
          github.com/snag-run/latchkey
        </a>
      </footer>
    </Layouts.landing>
    """
  end
end
