defmodule LatchkeyWeb.LandingLive do
  @moduledoc """
  The public landing page: the app's front door at `/`.

  A design-led page that teaches the event-sourced tenancy model in one stacked
  scenario: the append-only **event log** (source of truth), then an
  **append-only** correction (a signed, negative `RentPaymentRecorded`), the **write vs read** seam
  across the payment ACL, **arrears over time** against the 14-day gate, and a
  close. It renders no domain data (the story is a fixed, internally consistent
  illustration at 620.00/week); the live event log lives at `/inspector`. The
  page also states plainly that Latchkey is a learning project in event
  sourcing and domain-driven design.

  Styling reuses the shipped warm-paper `sd-*` tokens; component classes are the
  `lk-*` set scoped under `.landing` (see `assets/css/app.css`). Interactivity is
  limited to the shared theme toggle (`Layouts.theme_toggle/1`, via `phx:set-theme`)
  and a scroll-triggered chart draw (the `.ChartReveal` colocated hook). The hero's
  event-entrance stagger is pure CSS.
  """
  use LatchkeyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Latchkey")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.landing flash={@flash}>
      <header class="topbar">
        <div class="row">
          <.link navigate={~p"/"} class="brand" aria-label="Latchkey home">
            <span class="key" aria-hidden="true">L</span>
            Latchkey <small>event-sourced tenancy ledger</small>
          </.link>
          <nav aria-label="Primary">
            <span class="desktop-nav">
              <a class="navlink" href="#seam">Write vs read</a>
              <a class="navlink" href="#timeline">Timeline</a>
              <.link class="navlink" navigate={~p"/learn/event-sourcing"}>Event sourcing</.link>
              <.link class="navlink" navigate={~p"/learn/ddd"}>DDD</.link>
              <.link class="navlink" navigate={~p"/inspector"}>Inspector</.link>
            </span>
            <Layouts.theme_toggle />
          </nav>
        </div>
      </header>

      <main>
        <%!-- HERO: the event log --%>
        <section class="wrap lk-hero" aria-label="The event log">
          <div class="split">
            <div class="copy">
              <p class="eyebrow">Append-only. Hash-chained.</p>
              <h1 class="display">Every fact of a tenancy, in the order it happened.</h1>
              <p class="lede">
                The append-only event log is the source of truth. The statement, the balance, the
                timeline: each one is just a read of it. Legible enough to stand up at <span class="em">tribunal</span>.
              </p>
              <div class="cta-row">
                <.link class="lk-btn primary" navigate={~p"/inspector"}>Open the inspector</.link>
                <.link class="lk-btn ghost" navigate={~p"/inspector/docs/domain-model"}>
                  Read the model
                </.link>
              </div>
              <div class="provenance">
                <span><b>each event</b></span><span>chained to</span><span><b>the last</b></span>
              </div>
            </div>

            <div
              class="eventlog"
              role="img"
              aria-label="Sample append-only event log for a tenancy stream: each event is numbered, timestamped, and hash-chained to the previous one."
            >
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
                    <span class="h">9c1a…</span><span class="prev">prev —</span>
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

        <%!-- APPEND-ONLY: correction by compensation --%>
        <section class="section" aria-label="Append-only">
          <div class="wrap">
            <div class="band-inner">
              <div>
                <h2 class="display">A reversal is a new line, not a deletion.</h2>
                <p>
                  When a payment is dishonoured, you don't erase it. In
                  <span class="mono">Accounts</span>
                  a <span class="mono">PaymentReversed</span>
                  fact is appended; the payment ACL translates it onto the tenancy stream as a
                  <span class="em">negative</span> <span class="mono">RentPaymentRecorded</span>, which
                  reads as a debit and re-opens the arrears. The original payment stays in the log,
                  and the history stays whole.
                </p>
              </div>
              <div
                class="corr"
                role="img"
                aria-label="A recorded payment, then an appended negative RentPaymentRecorded that re-opens the arrears without deleting the original."
              >
                <div class="evt" phx-no-curly-interpolation>
                  <span class="name">RentPaymentRecorded</span>
                  <span class="k">{ amount:</span>
                  620.00<span class="k">, on:</span>
                  2026-03-05 <span class="k">}</span>
                </div>
                <div class="evt appended" phx-no-curly-interpolation>
                  <span class="name">RentPaymentRecorded</span>
                  <span class="k">{ amount:</span>
                  −620.00<span class="k">, reverses:</span>
                  2026-03-05 <span class="k">}</span>
                </div>
                <span class="appended-tag">appended, never mutated · a signed RentPaymentRecorded</span>
              </div>
            </div>
          </div>
        </section>

        <%!-- SEAM: write vs read --%>
        <section class="section" id="seam" aria-label="Write versus Read">
          <div class="wrap">
            <div class="sec-head">
              <h2 class="display">Written once on the left. Read many ways on the right.</h2>
              <p>
                A payment fact born in Accounts crosses the anti-corruption layer and reconciles into
                arrears. Here the 300.00 part-payment lands and pulls the tenant back under the 14-day
                line.
              </p>
            </div>

            <div class="seam">
              <div class="seam-line" aria-hidden="true"><span class="acl">payment ACL</span></div>

              <div class="side write">
                <span class="side-label">Write</span>
                <p class="side-sub">
                  The append-only log from above. Facts, in the order they happened.
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
                    <span class="lk-label">Expected to date</span><span class="val">1,860.00</span>
                  </div>
                  <div class="metric">
                    <span class="lk-label">Received to date</span><span class="val">920.00</span>
                  </div>
                  <div class="metric arrears">
                    <span class="lk-label">Arrears</span><span class="val">940.00</span>
                  </div>
                  <div class="metric">
                    <span class="lk-label">In arrears</span><span class="val">≈ 11 days</span>
                  </div>
                </div>
                <div class="gate clear">under the 14-day gate</div>
              </div>
            </div>

            <div class="cta-row" style="margin-top: 26px;">
              <.link class="lk-btn ghost" navigate={~p"/inspector"}>See how the fold works</.link>
            </div>
          </div>
        </section>

        <%!-- TIMELINE: arrears over time --%>
        <section class="section" id="timeline" aria-label="The timeline">
          <div class="wrap">
            <div class="sec-head">
              <h2 class="display">Arrears is counted in days, and a payment can pull it back.</h2>
              <p>
                The 14-day gate is two weeks of rent owed, not two weeks on the calendar. A
                part-payment can drop the tenant back under the line. Only when a later charge crosses
                it, uncured, does a termination notice issue.
              </p>
            </div>

            <div id="arrears-timeline" class="lk-timeline" phx-hook=".ChartReveal" phx-update="ignore">
              <script :type={Phoenix.LiveView.ColocatedHook} name=".ChartReveal">
                // Draw the arrears chart once, when it scrolls into view (the CSS
                // animations key off the `.in-view` class). No IntersectionObserver
                // support → reveal immediately.
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
                  Notice issued
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
                  <span><i class="n"></i>notice issued</span>
                </div>
                <.link class="lk-btn primary" navigate={~p"/inspector"}>Scrub a real stream</.link>
              </div>
            </div>
          </div>
        </section>

        <%!-- ABOUT: the learning-project framing --%>
        <section class="section" id="about" aria-label="About this project">
          <div class="wrap">
            <div class="band-inner">
              <div>
                <p class="eyebrow">About the project</p>
                <h2 class="display">Built to practise event sourcing and domain-driven design.</h2>
                <p>
                  Latchkey is a learning project, not production. It simulates the payments seam of
                  NSW residential tenancy management to work both patterns end to end: a hash-chained
                  log on Commanded and Postgres EventStore, arrears folded into Ash read models, and a
                  wall-clock sweep that reveals events as they fall due.
                </p>
              </div>
              <div>
                <div class="provenance">
                  <span><b>Elixir</b></span><span>Phoenix LiveView</span><span>Commanded</span>
                  <span>Postgres EventStore</span><span><b>Ash</b> read model</span>
                </div>
                <div class="cta-row" style="margin-top: 22px;">
                  <.link class="lk-btn primary" navigate={~p"/learn/event-sourcing"}>
                    Event sourcing 101
                  </.link>
                  <.link class="lk-btn primary" navigate={~p"/learn/ddd"}>DDD 101</.link>
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
        <section class="wrap close-band" aria-label="Get started">
          <p class="formula"><b>expected</b> − <b>received</b> = <b>arrears</b></p>
          <h2 class="display">See the whole tenancy, not just the balance.</h2>
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
