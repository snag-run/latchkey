defmodule LatchkeyWeb.InspectorComponents do
  @moduledoc """
  Presentational function components for the read-only ES/DDD inspector
  (`LatchkeyWeb.InspectorLive`).

  These render the **Workbench** shell from the layout spike: a
  context → aggregate → stream nav rail, the orientation-map landing (the two
  live context boxes, the ACL-1 seam edge, and the named-only static boxes), and
  interaction-anchored teaching captions (spec developer-view.md, D2/D3). The
  live firehose feed itself is `LatchkeyWeb.Inspector.Firehose` (D5).

  Everything here is **read-only**: it navigates and renders, never mutating. No
  component issues commands or exposes an edit/delete affordance.
  """
  use LatchkeyWeb, :html

  alias LatchkeyWeb.Inspector.Docs
  alias LatchkeyWeb.Inspector.Glossary

  @doc """
  The in-app **glossary** page (spec glossary.md, D1/D2/D3/D6): three lens-sections
  — domain (rendered verbatim from `CONTEXT.md`), DDD, and ES — each rendering
  anchored markdown so per-term headings are deep-link targets. The domain lens
  carries a framing caption (D6). Content is compiled by `Glossary`; the rendered
  HTML is trusted first-party markdown, emitted with `raw/1`.
  """
  def glossary_page(assigns) do
    assigns =
      assign(assigns,
        domain_html: Glossary.html(:domain),
        ddd_html: Glossary.html(:ddd),
        es_html: Glossary.html(:es)
      )

    ~H"""
    <section id="glossary" class="max-w-3xl mx-auto">
      <header class="mb-10">
        <p class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
          Reference · living documentation
        </p>
        <h1 class="mt-1.5 text-2xl font-semibold tracking-tight text-balance">
          A glossary that points back at the running system.
        </h1>
        <.caption class="mt-2 max-w-[66ch]">
          Three lenses on Latchkey: the <b>domain</b>
          it models, and the <b>domain-driven design</b>
          and <b>event-sourcing</b>
          patterns the code uses.
          Each term names the code it maps to and, where it runs, links to the live
          inspector surface.
        </.caption>
        <nav class="mt-4 flex flex-wrap gap-2" aria-label="Glossary lenses">
          <a
            :for={
              {id, label} <- [
                {"glossary-domain", "Domain"},
                {"glossary-ddd", "DDD"},
                {"glossary-es", "Event sourcing"}
              ]
            }
            href={"##{id}"}
            class="px-2.5 py-1 rounded-full bg-base-200 hover:bg-base-300 text-xs font-medium transition-colors"
          >
            {label}
          </a>
        </nav>
      </header>

      <section id="glossary-domain" class="mb-14">
        <div
          id="glossary-domain-framing"
          class="mb-5 rounded-lg border border-base-300 bg-base-200/50 px-4 py-3"
        >
          <p class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
            Domain lens
          </p>
          <.caption class="mt-1">
            Latchkey's ubiquitous language, rendered verbatim from
            <code class="font-mono text-base-content/80">CONTEXT.md</code>
            — a single source of truth, so it can't drift. Inward cross-references
            (“ADR 0008”, “domain-model.md §7”) point to the ADRs and the <.link
              id="glossary-domain-model-link"
              navigate={~p"/inspector/docs/domain-model"}
              class="font-semibold text-primary"
            >
              domain model</.link>.
          </.caption>
        </div>
        <div class="glossary-prose">{raw(@domain_html)}</div>
      </section>

      <section id="glossary-ddd" class="mb-14">
        <div class="glossary-prose">{raw(@ddd_html)}</div>
      </section>

      <section id="glossary-es" class="mb-14">
        <div class="glossary-prose">{raw(@es_html)}</div>
      </section>
    </section>
    """
  end

  @doc """
  An in-app **deep-doc** page (spec glossary.md, D8/D9/D11, issue #131): one
  canonical narrative doc (`:context_map` | `:domain_model`) rendered verbatim from
  its markdown source, with relative links rewritten to GitHub (D9). It reuses the
  glossary's `.glossary-prose` styling and is a distinct, read-through surface that
  coexists with the concise glossary index (D8). A sub-nav cross-links the other
  reference surfaces (D11); the octocat source link stays external (D5c). Content is
  trusted first-party markdown, emitted with `raw/1`.
  """
  attr :doc_key, :atom, required: true, doc: ":context_map or :domain_model"

  def docs_page(assigns) do
    assigns =
      assign(assigns,
        body_html: Docs.html(assigns.doc_key),
        title: Docs.title(assigns.doc_key),
        source_url: Docs.source_url(assigns.doc_key)
      )

    ~H"""
    <section id="docs-page" class="max-w-3xl mx-auto">
      <header class="mb-10">
        <p class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
          Reference · deep documentation
        </p>
        <h1 class="mt-1.5 text-2xl font-semibold tracking-tight text-balance">{@title}</h1>
        <.caption class="mt-2 max-w-[66ch]">
          The repo's canonical <b>{@title}</b>
          doc, rendered in-app from its markdown source — the same prose the
          <code class="font-mono text-base-content/80">read_more</code>
          links point at, in sync at every build.
        </.caption>

        <nav class="mt-4 flex flex-wrap items-center gap-2" aria-label="Reference navigation">
          <.link
            :for={
              {key, path, label} <- [
                {:context_map, ~p"/inspector/docs/context-map", "Context Map"},
                {:domain_model, ~p"/inspector/docs/domain-model", "Domain Model"}
              ]
            }
            id={"docs-nav-#{key}"}
            navigate={path}
            class={[
              "px-2.5 py-1 rounded-full text-xs font-medium transition-colors",
              if(@doc_key == key,
                do: "bg-primary/10 text-primary",
                else: "bg-base-200 hover:bg-base-300"
              )
            ]}
            aria-current={@doc_key == key && "page"}
          >
            {label}
          </.link>
          <.link
            id="docs-nav-glossary"
            navigate={~p"/inspector/glossary"}
            class="px-2.5 py-1 rounded-full bg-base-200 hover:bg-base-300 text-xs font-medium transition-colors"
          >
            Glossary
          </.link>
          <a
            id="docs-source-link"
            href={@source_url}
            target="_blank"
            rel="noopener"
            class="ml-auto text-xs font-semibold text-primary"
          >
            View source on GitHub ↗
          </a>
        </nav>
      </header>

      <div id={"docs-content-#{@doc_key}"} class="glossary-prose">{raw(@body_html)}</div>
    </section>
    """
  end

  @doc """
  Left nav rail: contexts (deep + edge) with their aggregate and streams, then
  the named-only contexts rendered as honestly-labelled, non-navigable entries.

  A context carrying a non-empty `:groups` list (the deep Tenancy context, which
  fans out to ~100 per-tenancy streams) renders those streams **grouped by
  scenario**, each group collapsible; a `:filter` box narrows the list by id.
  Both are driven server-side (`nav_toggle` / `nav_filter`). Every stream link is
  always in the DOM — collapse and filter only toggle a CSS `hidden` class — so a
  collapsed or filtered-out stream stays addressable (deep links, tests).
  """
  attr :contexts, :list, required: true, doc: "the live, emitting contexts"
  attr :named_contexts, :list, required: true, doc: "named-only, not-modelled contexts"
  attr :active_stream, :string, default: nil, doc: "currently selected stream id, if any"
  attr :nav_filter, :string, default: "", doc: "current stream-filter query"
  attr :nav_expanded, :list, default: [], doc: "keys of the currently-expanded groups"

  def nav_rail(assigns) do
    ~H"""
    <nav id="inspector-nav" aria-label="Context, aggregate and stream navigation" class="text-sm">
      <p class="px-2 mb-2 text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
        Context → Aggregate → Stream
      </p>

      <%!-- A bare input (phx-keyup), not a <form>, so the inspector stays literally --%>
      <%!-- form-free — the read-only invariant the tests assert. Filtering never mutates. --%>
      <div class="px-2 mb-3">
        <input
          id="nav-filter"
          type="text"
          value={@nav_filter}
          phx-keyup="nav_filter"
          phx-debounce="150"
          autocomplete="off"
          placeholder="Filter streams…"
          class="w-full px-2 py-1 text-xs rounded-md bg-base-200 border border-base-300 focus:outline-none focus:border-primary"
        />
      </div>

      <div :for={ctx <- @contexts} id={"nav-context-#{ctx.id}"} class="mb-4">
        <div class="flex items-center gap-2 px-2 py-1 font-semibold">
          <span class={["inline-block size-2 rounded-full", context_dot(ctx.kind)]} />
          {ctx.name}
          <span class={[
            "ml-auto badge badge-sm",
            if(ctx.kind == :deep, do: "badge-primary", else: "badge-info")
          ]}>
            {ctx.kind}
          </span>
        </div>

        <p
          :if={ctx.aggregate}
          id={"nav-aggregate-#{ctx.id}"}
          class="pl-6 py-0.5 text-xs text-base-content/70"
        >
          aggregate: <span class="font-semibold">{ctx.aggregate}</span>
        </p>

        <p :if={ctx.streams == []} class="pl-6 py-1 text-xs text-base-content/50 italic">
          no streams yet — seed the board to populate
        </p>

        <%= if ctx[:groups] not in [nil, []] do %>
          <div :for={group <- ctx.groups} id={"nav-group-#{group.key}"} class="mb-1">
            <button
              type="button"
              id={"nav-toggle-#{group.key}"}
              aria-expanded={to_string(group_open?(group, @nav_filter, @nav_expanded))}
              phx-click="nav_toggle"
              phx-value-category={group.key}
              class="w-full flex items-center gap-2 pl-4 pr-2 py-1 rounded-md hover:bg-base-200 text-xs font-medium text-base-content/70"
            >
              <span
                class={[
                  "inline-block transition-transform text-base-content/40",
                  group_open?(group, @nav_filter, @nav_expanded) && "rotate-90"
                ]}
                aria-hidden="true"
              >
                ›
              </span>
              <span>{group.label}</span>
              <span class="ml-auto text-[10.5px] text-base-content/45">
                {group_visible_count(group, @nav_filter)}
              </span>
            </button>

            <div class={["mt-0.5", not group_open?(group, @nav_filter, @nav_expanded) && "hidden"]}>
              <.stream_link
                :for={stream <- group.streams}
                stream={stream}
                active_stream={@active_stream}
                hidden={not stream_matches?(stream, @nav_filter)}
              />
            </div>
          </div>

          <p
            :if={@nav_filter != "" and no_matches?(ctx.groups, @nav_filter)}
            id={"nav-no-match-#{ctx.id}"}
            class="pl-6 py-1 text-xs italic text-base-content/45"
          >
            no streams match “{@nav_filter}”
          </p>
        <% else %>
          <.stream_link
            :for={stream <- ctx.streams}
            stream={stream}
            active_stream={@active_stream}
            hidden={not stream_matches?(stream, @nav_filter)}
          />
        <% end %>
      </div>

      <div id="nav-named-only" class="mb-2">
        <p class="px-2 py-1 text-xs font-medium text-base-content/50">named only — not modelled</p>
        <p
          :for={named <- @named_contexts}
          id={"nav-named-#{named.slug}"}
          class="pl-6 py-0.5 text-xs text-base-content/40"
        >
          · {named.name}
        </p>
      </div>
    </nav>
    """
  end

  # One stream entry in the nav rail. `hidden` (filtered out) only adds a CSS class,
  # never removes the link — so it stays addressable by deep link and by tests.
  attr :stream, :map, required: true
  attr :active_stream, :string, default: nil
  attr :hidden, :boolean, default: false

  defp stream_link(assigns) do
    ~H"""
    <.link
      id={"nav-stream-#{@stream.id}"}
      patch={~p"/inspector/streams/#{@stream.id}"}
      class={[
        "flex items-center gap-2 pl-6 pr-2 py-1.5 rounded-md hover:bg-base-200 transition-colors",
        @active_stream == @stream.id && "bg-primary/10 text-primary font-medium",
        @hidden && "hidden"
      ]}
    >
      <span class={["inline-block size-2 rounded-full", tone_dot(@stream.tone)]} />
      <span class="flex flex-col leading-tight">
        <span>{@stream.label}</span>
        <span class="font-mono text-[10.5px] text-base-content/50">{@stream.id}</span>
      </span>
    </.link>
    """
  end

  # A stream matches an empty filter, else a case-insensitive substring of its
  # label or id.
  defp stream_matches?(_stream, ""), do: true

  defp stream_matches?(stream, filter) do
    haystack = String.downcase(stream.label <> " " <> stream.id)
    String.contains?(haystack, String.downcase(filter))
  end

  # A group is open when the user has expanded it, or — while filtering — whenever
  # it holds a match (so matches are never hidden behind a collapsed group).
  defp group_open?(group, "", expanded), do: group.key in expanded

  defp group_open?(group, filter, _expanded),
    do: Enum.any?(group.streams, &stream_matches?(&1, filter))

  defp group_visible_count(group, ""), do: group.count

  defp group_visible_count(group, filter),
    do: Enum.count(group.streams, &stream_matches?(&1, filter))

  defp no_matches?(groups, filter) do
    Enum.all?(groups, fn group -> group_visible_count(group, filter) == 0 end)
  end

  @doc """
  Orientation-map landing: the two live context boxes joined by the ACL-1 seam
  edge, then the named-only static boxes. This *is* the strategic context map,
  rendered in-view (spec D2).
  """
  attr :deep_context, :map, required: true
  attr :edge_context, :map, required: true
  attr :named_contexts, :list, required: true
  attr :acl_edge_label, :string, required: true
  attr :docs, :map, required: true, doc: "canonical doc URLs for read-more links"
  attr :nav_expanded, :list, default: [], doc: "keys of the currently-expanded groups"

  def orientation_map(assigns) do
    ~H"""
    <section id="orientation-map" aria-label="Strategic context map">
      <header class="mb-6">
        <p class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
          Read-only · living documentation
        </p>
        <h1 class="mt-1.5 text-2xl font-semibold tracking-tight text-balance">
          The event log, navigable by the model's own map.
        </h1>
        <.caption class="mt-2 max-w-[66ch]">
          Every box is a <b>bounded context</b>. Click a stream to open it — events
          fold into aggregate state, a read model, and a double-entry ledger. Nothing
          here can be edited or deleted; the log is <b>append-only / immutable</b>, and
          that is the point.
          <.read_more href={@docs.context_map}>context-map.md</.read_more>
        </.caption>
        <nav
          id="orientation-reference"
          class="mt-3 flex flex-wrap items-center gap-2"
          aria-label="Reference"
        >
          <span class="text-[11px] font-semibold uppercase tracking-widest text-base-content/40">
            Reference
          </span>
          <.link
            :for={
              {id, path, label} <- [
                {"orientation-glossary-link", ~p"/inspector/glossary", "Glossary"},
                {"orientation-docs-context-map", ~p"/inspector/docs/context-map", "Context Map"},
                {"orientation-docs-domain-model", ~p"/inspector/docs/domain-model", "Domain Model"}
              ]
            }
            id={id}
            navigate={path}
            class="px-2.5 py-1 rounded-full bg-base-200 hover:bg-base-300 text-xs font-medium text-primary transition-colors"
          >
            {label}
          </.link>
        </nav>
      </header>

      <div class="grid grid-cols-1 md:grid-cols-[1fr_auto_1fr] items-center gap-4 mb-8">
        <.context_box context={@edge_context} nav_expanded={@nav_expanded} />

        <div id="acl-1-edge" class="text-center">
          <span class="inline-flex items-center gap-1.5 px-3 py-1 rounded-full bg-primary/10 text-primary font-mono text-xs">
            {@acl_edge_label}
          </span>
          <p class="mt-1.5 text-[10.5px] text-base-content/50">ACL-1</p>
          <p class="text-primary text-lg leading-none" aria-hidden="true">→</p>
        </div>

        <.context_box context={@deep_context} nav_expanded={@nav_expanded} />
      </div>

      <p class="mb-2 text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
        Named only — not modelled
      </p>
      <div class="grid grid-cols-[repeat(auto-fill,minmax(150px,1fr))] gap-2.5">
        <div
          :for={named <- @named_contexts}
          id={"named-box-#{named.slug}"}
          class="rounded-xl border border-dashed border-base-300 bg-base-200/60 p-3.5 opacity-70"
        >
          <h4 class="text-sm font-semibold">{named.name}</h4>
          <p class="text-xs text-base-content/50">named only — not modelled</p>
        </div>
      </div>
    </section>
    """
  end

  @doc "One context box on the orientation map: deep (clickable streams) or edge."
  attr :context, :map, required: true
  attr :nav_expanded, :list, default: [], doc: "keys of the currently-expanded groups"

  def context_box(assigns) do
    ~H"""
    <div
      id={"ctx-box-#{@context.id}"}
      class={[
        "rounded-xl border p-3.5 bg-base-100",
        if(@context.kind == :deep,
          do: "border-primary/60",
          else: "border-dashed border-info/60"
        )
      ]}
    >
      <div class="flex items-start justify-between gap-2">
        <h4 class="text-sm font-semibold">{@context.name}</h4>
        <span class={[
          "badge badge-sm",
          if(@context.kind == :deep, do: "badge-primary", else: "badge-info")
        ]}>
          {@context.kind}
        </span>
      </div>
      <p class="mt-1.5 mb-2 text-xs text-base-content/60">{@context.blurb}</p>
      <p :if={@context.aggregate} class="mb-2 text-xs text-base-content/60">
        aggregate: <span class="font-semibold">{@context.aggregate}</span>
      </p>

      <p :if={@context.streams == []} class="text-xs italic text-base-content/50">
        no streams yet — seed the board to populate
      </p>

      <%= if @context[:groups] not in [nil, []] do %>
        <%!-- Deep context fans out to ~100 streams: group by scenario, collapsible, --%>
        <%!-- sharing the nav rail's expand state (nav_toggle) so the two agree. --%>
        <div :for={group <- @context.groups} id={"map-group-#{group.key}"} class="mb-0.5">
          <button
            type="button"
            id={"map-toggle-#{group.key}"}
            aria-expanded={to_string(group_open?(group, "", @nav_expanded))}
            phx-click="nav_toggle"
            phx-value-category={group.key}
            class="w-full flex items-center gap-2 px-1 py-1 rounded-md hover:bg-base-200 text-xs font-medium text-base-content/70"
          >
            <span
              class={[
                "inline-block transition-transform text-base-content/40",
                group_open?(group, "", @nav_expanded) && "rotate-90"
              ]}
              aria-hidden="true"
            >
              ›
            </span>
            <span>{group.label}</span>
            <span class="ml-auto text-[10.5px] text-base-content/45">{group.count}</span>
          </button>

          <div class={["pl-3", not group_open?(group, "", @nav_expanded) && "hidden"]}>
            <.map_stream_link :for={stream <- group.streams} stream={stream} />
          </div>
        </div>
      <% else %>
        <.map_stream_link :for={stream <- @context.streams} stream={stream} />
      <% end %>
    </div>
    """
  end

  # One clickable stream entry inside an orientation-map context box.
  attr :stream, :map, required: true

  defp map_stream_link(assigns) do
    ~H"""
    <.link
      id={"map-stream-#{@stream.id}"}
      patch={~p"/inspector/streams/#{@stream.id}"}
      class="flex items-center gap-2 px-1 py-1.5 rounded-md hover:bg-base-200 transition-colors"
    >
      <span class={["inline-block size-2 rounded-full", tone_dot(@stream.tone)]} />
      <span class="flex flex-col leading-tight">
        <span>{@stream.label}</span>
        <span class="font-mono text-[10.5px] text-base-content/50">{@stream.id}</span>
      </span>
    </.link>
    """
  end

  @doc """
  Shown when a `/inspector/streams/:id` URL names no known stream (a typo'd or
  stale link). Surfaces the unknown id honestly rather than defaulting to a
  context, with a way back to the orientation map.
  """
  attr :stream_id, :string, required: true

  def stream_not_found(assigns) do
    ~H"""
    <section id="stream-not-found" class="max-w-2xl">
      <div class="rounded-xl border border-warning/50 bg-base-100 p-6">
        <p class="text-[11px] font-semibold uppercase tracking-widest text-warning">
          Unknown stream
        </p>
        <h2 class="mt-1 text-lg font-semibold font-mono">{@stream_id}</h2>
        <.caption class="mt-3">
          No live stream matches this id. It may be a stale or mistyped link.
          <.link patch={~p"/inspector"} class="font-semibold text-primary">
            Back to the map →
          </.link>
        </.caption>
      </div>
    </section>
    """
  end

  @doc "A thin, interaction-anchored teaching caption (spec D2 altitude split)."
  attr :class, :string, default: nil
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def caption(assigns) do
    ~H"""
    <p
      id={@id}
      class={["text-xs leading-relaxed text-base-content/60 [&_b]:text-base-content/80", @class]}
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc "A 'read more' link out to the canonical deep-model docs (never re-authored here)."
  attr :href, :string, required: true
  slot :inner_block, required: true

  def read_more(assigns) do
    ~H"""
    <a href={@href} target="_blank" rel="noopener" class="text-xs font-semibold text-primary">
      {render_slot(@inner_block)} ↗
    </a>
    """
  end

  defp context_dot(:deep), do: "bg-primary"
  defp context_dot(_), do: "bg-info"

  defp tone_dot(:ok), do: "bg-success"
  defp tone_dot(:warn), do: "bg-warning"
  defp tone_dot(:crit), do: "bg-error"
  defp tone_dot(:info), do: "bg-info"
  defp tone_dot(_), do: "bg-base-content/40"
end
