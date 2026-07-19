defmodule LatchkeyWeb.LearnEventSourcingLive do
  @moduledoc """
  "ES 101" primer: event sourcing taught on Latchkey's real tenancy stream.

  A design-led explainer at `/learn/event-sourcing` that teaches event sourcing
  using only what Latchkey implements, in the order a newcomer meets it:

    1. **Events as facts**: the core tenancy vocabulary (`TenancyCommenced`,
       `RentFellDue`, `RentPaymentRecorded`, `TerminationNoticeGiven`), plus the
       Accounts `PaymentReversed` that crosses the payment ACL.
    2. **The append-only, hash-chained log** as the single source of truth,
       legible enough to stand up as NCAT (tribunal) evidence.
    3. **Projections are reads**: the rental ledger, the arrears read model, and
       the timeline are folds of the log, derived and disposable.
    4. **Correction by compensation**: nothing is mutated; an Accounts
       `PaymentReversed` crosses the ACL as a negative `RentPaymentRecorded`,
       reads as a debit, and re-opens the arrears.
    5. **Replay and rebuild**: projectors refold from `:origin`, and the
       Commanded reset primitive cold-rebuilds the whole board from the log.

  It renders no live domain data: the story is a fixed, internally consistent
  illustration at 620.00/week (the live event log is at `/inspector`). Styling
  reuses the shipped warm-paper `sd-*` tokens and the `lk-*` component set scoped
  under `.landing` (see `assets/css/app.css`) so this page inherits the landing's
  chrome without adding new CSS. Interactivity is limited to the shared theme
  toggle and a scroll-triggered chart draw (the `.ArrearsDraw` colocated hook,
  a distinct copy of the landing's reveal); reduced-motion viewers see every
  element with no animation.

  Out of scope (by design, issue #191): generic ES/CQRS theory beyond what
  Latchkey shows, and Commanded/EventStore internals (ADR 0003 covers those).
  """
  use LatchkeyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "ES 101: event sourcing on a tenancy")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.landing flash={@flash}>
      <header class="topbar">
        <div class="row">
          <.link navigate={~p"/"} class="brand" aria-label="Latchkey home">
            <span class="key" aria-hidden="true">L</span> Latchkey <small>ES 101 primer</small>
          </.link>
          <nav aria-label="Primary">
            <span class="desktop-nav">
              <.link class="navlink" navigate={~p"/learn/ddd"}>DDD</.link>
              <.link class="navlink" navigate={~p"/inspector"}>Inspector</.link>
            </span>
            <Layouts.theme_toggle />
          </nav>
        </div>
      </header>

      <main>
        <%!-- HERO: events as facts, on the append-only log --%>
        <section class="wrap lk-hero" aria-label="Event sourcing, in one tenancy">
          <div class="split">
            <div class="copy">
              <p class="eyebrow">ES 101 · Primer</p>
              <h1 class="display">Learn event sourcing on one tenancy.</h1>
              <p class="lede">
                Event sourcing keeps the <span class="em">facts</span>, not just the balance. Latchkey
                writes every fact of a tenancy to an append-only log, then reads the ledger, the
                arrears, and the timeline back out of it. This page walks that idea end to end, using
                the real stream.
              </p>
              <div class="cta-row">
                <.link class="lk-btn primary" navigate={~p"/inspector"}>Open the inspector</.link>
                <.link class="lk-btn ghost" navigate={~p"/inspector/docs/domain-model"}>
                  Read the domain model
                </.link>
              </div>
              <div class="provenance">
                <span><b>write</b></span><span>a fact</span><span>fold</span><span><b>a read</b></span>
              </div>
            </div>

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
                  <div class="ev-hash">
                    <span class="h">9c1a…</span><span class="prev">prev none</span>
                  </div>
                </li>
                <li class="ev">
                  <div class="ev-top">
                    <span class="seq">2</span>
                    <span class="etype">RentFellDue</span>
                    <span class="edate">03 Mar</span>
                  </div>
                  <div class="ev-pay"><span class="k">amount</span> 620.00</div>
                  <div class="ev-hash">
                    <span class="h">4f7b…</span><span class="prev">prev 9c1a</span>
                  </div>
                </li>
                <li class="ev">
                  <div class="ev-top">
                    <span class="seq">3</span>
                    <span class="etype">RentPaymentRecorded</span>
                    <span class="edate">05 Mar</span>
                  </div>
                  <div class="ev-pay"><span class="k">amount</span> 620.00</div>
                  <div class="ev-hash">
                    <span class="h">a2e8…</span><span class="prev">prev 4f7b</span>
                  </div>
                </li>
                <li class="ev">
                  <div class="ev-top">
                    <span class="seq">4</span>
                    <span class="etype">RentFellDue</span>
                    <span class="edate">10 Mar</span>
                  </div>
                  <div class="ev-pay"><span class="k">amount</span> 620.00</div>
                  <div class="ev-hash">
                    <span class="h">c33d…</span><span class="prev">prev a2e8</span>
                  </div>
                </li>
                <li class="ev">
                  <div class="ev-top">
                    <span class="seq">5</span>
                    <span class="etype">RentFellDue</span>
                    <span class="edate">17 Mar</span>
                  </div>
                  <div class="ev-pay"><span class="k">amount</span> 620.00</div>
                  <div class="ev-hash">
                    <span class="h">71f0…</span><span class="prev">prev c33d</span>
                  </div>
                </li>
              </ol>
              <div class="foot">
                <span class="stamp">chain verified</span>
                <span>5 events</span>
              </div>
            </div>
          </div>
        </section>

        <%!-- EVENTS AS FACTS: the real tenancy vocabulary --%>
        <section class="section" id="events" aria-label="Events as facts">
          <div class="wrap">
            <div class="band-inner">
              <div>
                <p class="eyebrow">1 · Events as facts</p>
                <h2 class="display">An event is something that already happened.</h2>
                <p>
                  It is named in the past tense, and never edited or deleted once written. These are
                  the core tenancy facts this page follows; the stream carries more (rent changes,
                  notices, settlement). Payments are <span class="mono">Accounts</span>
                  facts that cross
                  the payment ACL to land here as a signed <span class="mono">RentPaymentRecorded</span>.
                  Everything you read later is folded from facts like these.
                </p>
                <div class="cta-row" style="margin-top: 22px;">
                  <.link class="lk-btn ghost" navigate={~p"/inspector/glossary"}>
                    Full glossary
                  </.link>
                </div>
              </div>
              <div class="corr">
                <div class="evt">
                  <span class="name">TenancyCommenced</span>
                  a tenancy begins at a <span class="k">property_ref</span>, with its rent and cycle.
                </div>
                <div class="evt">
                  <span class="name">RentFellDue</span>
                  a rent period falls due, carrying the <span class="k">amount</span>
                  owed.
                </div>
                <div class="evt">
                  <span class="name">RentPaymentRecorded</span>
                  the payment ACL's output: a payment against the tenancy, signed (a reversal is
                  negative).
                </div>
                <div class="evt">
                  <span class="name">TerminationNoticeGiven</span>
                  notice on arrears grounds, once the 14-day gate is crossed uncured.
                </div>
                <span class="appended-tag">past tense · written once · never mutated</span>
              </div>
            </div>
          </div>
        </section>

        <%!-- THE LOG: append-only, hash-chained, source of truth --%>
        <section class="section" id="log" aria-label="The log is the source of truth">
          <div class="wrap">
            <div class="sec-head">
              <p class="eyebrow">2 · The log</p>
              <h2 class="display">The log is the source of truth, not a side effect of one.</h2>
              <p>
                Events are appended in the order they happened, and each one is hash-chained to the one
                before it. Nothing overwrites the past, so the history stays whole and tamper-evident,
                legible enough to stand up as evidence in an NCAT arrears case.
              </p>
            </div>
            <div class="provenance" aria-hidden="true">
              <span><b>append-only</b></span><span>each event</span><span>chained to</span><span><b>the last</b></span><span>tamper-evident</span>
            </div>
            <div class="cta-row" style="margin-top: 26px;">
              <.link class="lk-btn ghost" navigate={~p"/inspector/log"}>See the live log</.link>
            </div>
          </div>
        </section>

        <%!-- PROJECTIONS: reads are folds of the log --%>
        <section class="section" id="projections" aria-label="Projections are reads">
          <div class="wrap">
            <div class="sec-head">
              <p class="eyebrow">3 · Projections</p>
              <h2 class="display">Every read is a fold of the log.</h2>
              <p>
                The rental ledger, the arrears read model, and the timeline are not stored truths. Each
                one is derived by replaying the events and folding them into a shape that is useful to
                read. Written once on the left, read many ways on the right.
              </p>
            </div>

            <div class="seam">
              <div class="seam-line" aria-hidden="true"><span class="acl">payment ACL</span></div>

              <div class="side write">
                <span class="side-label">Write</span>
                <p class="side-sub">
                  The append-only facts. A payment born in Accounts crosses the payment ACL into the
                  tenancy stream.
                </p>
                <div class="evt" phx-no-curly-interpolation>
                  <span class="name">RentFellDue</span>
                  <span class="k">{ amount:</span>
                  620.00<span class="k">, on:</span>
                  2026-03-10 <span class="k">}</span>
                </div>
                <div class="evt" phx-no-curly-interpolation>
                  <span class="name">RentFellDue</span>
                  <span class="k">{ amount:</span>
                  620.00<span class="k">, on:</span>
                  2026-03-17 <span class="k">}</span>
                </div>
                <div class="evt" phx-no-curly-interpolation>
                  <span class="name">RentPaymentRecorded</span>
                  <span class="k">{ amount:</span>
                  300.00<span class="k">, on:</span>
                  2026-03-19 <span class="k">}</span>
                </div>
              </div>

              <div class="fact" aria-hidden="true">
                <span class="name">RentPaymentRecorded</span> 300.00
              </div>

              <div class="side read">
                <span class="side-label">Read</span>
                <p class="side-sub">
                  Projections folded from the log. Derived, disposable, rebuildable.
                </p>
                <div class="proj">
                  <div class="metric">
                    <span class="lk-label">Rental ledger, expected</span><span class="val">1,860.00</span>
                  </div>
                  <div class="metric">
                    <span class="lk-label">Rental ledger, received</span><span class="val">920.00</span>
                  </div>
                  <div class="metric arrears">
                    <span class="lk-label">Arrears read model</span><span class="val">940.00</span>
                  </div>
                  <div class="metric">
                    <span class="lk-label">Timeline, days behind</span><span class="val">≈ 11 days</span>
                  </div>
                </div>
                <div class="gate clear">under the 14-day gate</div>
              </div>
            </div>

            <div class="cta-row" style="margin-top: 26px;">
              <.link class="lk-btn ghost" navigate={~p"/inspector/docs/context-map"}>
                Where the ACL sits
              </.link>
            </div>
          </div>
        </section>

        <%!-- ARREARS: the arrears read model, over time, vs the 14-day gate --%>
        <section class="section" id="arrears" aria-label="Arrears over time">
          <div class="wrap">
            <div class="sec-head">
              <p class="eyebrow">3b · A projection over time</p>
              <h2 class="display">Arrears is a fold, counted in days, against the 14-day gate.</h2>
              <p>
                The arrears read model is the same idea in motion. The 14-day gate is two weeks of rent
                owed, not two weeks on the calendar. A part-payment can drop the tenant back under the
                line. Only when a later charge crosses it, uncured, is a termination notice given.
              </p>
            </div>

            <div
              id="es-arrears-timeline"
              class="lk-timeline"
              phx-hook=".ArrearsDraw"
              phx-update="ignore"
            >
              <script :type={Phoenix.LiveView.ColocatedHook} name=".ArrearsDraw">
                // Draw the arrears chart once, when it scrolls into view (the CSS
                // animations key off the `.in-view` class). No IntersectionObserver
                // support → reveal immediately, so reduced-motion and no-JS viewers
                // still see the finished chart.
                export default {
                  mounted() {
                    if (!("IntersectionObserver" in window)) {
                      this.el.classList.add("in-view")
                      return
                    }
                    this.io = new IntersectionObserver((entries) => {
                      entries.forEach((e) => {
                        if (e.isIntersecting) {
                          this.el.classList.add("in-view")
                          this.io.disconnect()
                        }
                      })
                    }, { threshold: 0.35 })
                    this.io.observe(this.el)
                  },
                  destroyed() {
                    if (this.io) this.io.disconnect()
                  }
                }
              </script>
              <svg
                class="arrears-chart"
                viewBox="0 0 800 210"
                role="img"
                aria-label="Arrears over time against a 14-day threshold of 1,240 dollars. Arrears rises to 620, clears to zero on 05 March, rises again to touch the 1,240 line on 17 March, drops to 940 after a 300 part-payment on 19 March, then crosses the line to 1,560 on 24 March, when a termination notice issues."
              >
                <%!-- danger zone above the 14-day line --%>
                <rect class="danger" x="44" y="28" width="716" height="61"></rect>
                <%!-- baseline (arrears = 0) --%>
                <line class="axis-line" x1="44" y1="170" x2="760" y2="170"></line>
                <%!-- 14-day threshold at 1,240.00 (y=89) --%>
                <line class="threshold" x1="44" y1="89" x2="760" y2="89"></line>
                <text class="threshold-label" x="48" y="83">14-day gate · 1,240.00 owed</text>
                <text class="ylabel" x="48" y="166">0</text>

                <%!-- arrears step line --%>
                <polyline
                  class="arr-line"
                  points="44,170 44,130 95,130 95,170 223,170 223,130 402,130 402,89 453,89 453,109 581,109 581,68 760,68 760,28"
                >
                </polyline>

                <%!-- event dots --%>
                <circle class="chart-dot write" cx="44" cy="130" r="5" style="animation-delay:.2s">
                </circle>
                <circle class="chart-dot read" cx="95" cy="170" r="5" style="animation-delay:.5s">
                </circle>
                <circle class="chart-dot write" cx="223" cy="130" r="5" style="animation-delay:1.4s">
                </circle>
                <circle class="chart-dot write" cx="402" cy="89" r="5" style="animation-delay:2.3s">
                </circle>
                <circle class="chart-dot read" cx="453" cy="109" r="5" style="animation-delay:2.7s">
                </circle>
                <circle class="chart-dot write" cx="581" cy="68" r="5" style="animation-delay:3.5s">
                </circle>
                <circle class="chart-dot notice" cx="620" cy="68" r="6" style="animation-delay:3.9s">
                </circle>

                <%!-- annotations --%>
                <text
                  class="note reveal"
                  x="95"
                  y="186"
                  text-anchor="middle"
                  style="animation-delay:.6s"
                >
                  paid in full
                </text>
                <text
                  class="note accent reveal"
                  x="402"
                  y="106"
                  text-anchor="middle"
                  style="animation-delay:2.4s"
                >
                  hits 14 days
                </text>
                <text
                  class="note reveal"
                  x="453"
                  y="126"
                  text-anchor="middle"
                  style="animation-delay:2.8s"
                >
                  part-pay 300
                </text>
                <text class="note accent reveal" x="636" y="60" style="animation-delay:4.0s">
                  Notice given
                </text>

                <%!-- x-axis dates --%>
                <text class="xlabel" x="44" y="202" text-anchor="middle">03 Mar</text>
                <text class="xlabel" x="223" y="202" text-anchor="middle">10 Mar</text>
                <text class="xlabel" x="402" y="202" text-anchor="middle">17 Mar</text>
                <text class="xlabel" x="581" y="202" text-anchor="middle">24 Mar</text>
                <text class="xlabel" x="760" y="202" text-anchor="middle">31 Mar</text>
              </svg>

              <div class="tl-foot">
                <div class="legend">
                  <span><i class="w"></i>rent fell due</span>
                  <span><i class="r"></i>payment recorded</span>
                  <span><i class="n"></i>notice given</span>
                </div>
                <.link class="lk-btn primary" navigate={~p"/inspector"}>Scrub a real stream</.link>
              </div>
            </div>
          </div>
        </section>

        <%!-- COMPENSATION: correction is a new fact, never a mutation --%>
        <section class="section" id="compensation" aria-label="Correction by compensation">
          <div class="wrap">
            <div class="band-inner">
              <div>
                <p class="eyebrow">4 · Correction by compensation</p>
                <h2 class="display">You fix the log by adding to it, never by editing it.</h2>
                <p>
                  When a payment is dishonoured, the original stays. In
                  <span class="mono">Accounts</span>
                  a <span class="mono">PaymentReversed</span>
                  fact is appended; the payment ACL translates it onto the tenancy stream as a
                  <span class="em">negative</span> <span class="mono">RentPaymentRecorded</span>, which
                  reads as a debit and re-opens the arrears. Correction by compensation, never mutation,
                  and the next fold picks it up for free.
                </p>
              </div>
              <div class="corr">
                <div class="evt" phx-no-curly-interpolation>
                  <span class="name">RentPaymentRecorded</span>
                  <span class="k">{ amount:</span>
                  620.00<span class="k">, source_payment_id:</span>
                  pay_9f2c <span class="k">}</span>
                </div>
                <div class="evt appended" phx-no-curly-interpolation>
                  <span class="name">RentPaymentRecorded</span>
                  <span class="k">{ amount:</span>
                  −620.00<span class="k">, reverses:</span>
                  pay_9f2c <span class="k">}</span>
                </div>
                <span class="appended-tag">the reversal: a signed RentPaymentRecorded · reads as a debit</span>
              </div>
            </div>
          </div>
        </section>

        <%!-- REPLAY: refold from :origin, cold-rebuild the board --%>
        <section class="section" id="replay" aria-label="Replay and rebuild">
          <div class="wrap">
            <div class="band-inner">
              <div>
                <p class="eyebrow">5 · Replay and rebuild</p>
                <h2 class="display">Throw the reads away, and rebuild them from the log.</h2>
                <p>
                  Because reads are only folds, they are disposable. Projectors subscribe from
                  <span class="mono">:origin</span>
                  and refold the whole stream, and the Commanded reset primitive cold-rebuilds the
                  entire board from scratch. Same events in, same read models out.
                </p>
                <div class="cta-row" style="margin-top: 22px;">
                  <.link class="lk-btn ghost" navigate={~p"/inspector/docs/domain-model"}>
                    Replay semantics
                  </.link>
                </div>
              </div>
              <div class="corr">
                <div class="evt" phx-no-curly-interpolation>
                  <span class="name">ArrearsProjector</span>
                  <span class="k">{ start_from:</span> :origin <span class="k">}</span>
                </div>
                <div class="evt appended">
                  <span class="name">refold</span>
                  every event, in order, from the beginning of the stream.
                </div>
                <span class="appended-tag">read models are disposable · the log is not</span>
              </div>
            </div>
          </div>
        </section>

        <%!-- ABOUT: the learning-project framing + doc links --%>
        <section class="section" id="about" aria-label="About this primer">
          <div class="wrap">
            <div class="band-inner">
              <div>
                <p class="eyebrow">About the project</p>
                <h2 class="display">This primer runs on the real thing.</h2>
                <p>
                  Latchkey is a learning project in event sourcing and domain-driven design, not
                  production. It simulates the payments seam of NSW residential tenancy management: a
                  hash-chained log on Commanded and Postgres EventStore, arrears folded into Ash read
                  models, and a wall-clock sweep that reveals events as they fall due.
                </p>
              </div>
              <div>
                <div class="provenance">
                  <span><b>Elixir</b></span><span>Phoenix LiveView</span><span>Commanded</span>
                  <span>Postgres EventStore</span><span><b>Ash</b> read model</span>
                </div>
                <div class="cta-row" style="margin-top: 22px;">
                  <.link class="lk-btn ghost" navigate={~p"/inspector/docs/domain-model"}>
                    Domain model
                  </.link>
                  <.link class="lk-btn ghost" navigate={~p"/inspector/docs/context-map"}>
                    Context map
                  </.link>
                  <.link class="lk-btn ghost" navigate={~p"/inspector/glossary"}>Glossary</.link>
                </div>
              </div>
            </div>
          </div>
        </section>

        <%!-- CLOSE --%>
        <section class="wrap close-band" aria-label="See it live">
          <p class="formula"><b>events</b> → <b>fold</b> → <b>read model</b></p>
          <h2 class="display">Now watch it happen on a live stream.</h2>
          <div class="cta-row">
            <.link class="lk-btn primary" navigate={~p"/inspector"}>Open the inspector</.link>
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
