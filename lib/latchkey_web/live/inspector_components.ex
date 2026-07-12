defmodule LatchkeyWeb.InspectorComponents do
  @moduledoc """
  Presentational function components for the read-only ES/DDD inspector
  (`LatchkeyWeb.InspectorLive`).

  These render the **Workbench** shell from the layout spike: a
  context → aggregate → stream nav rail, the orientation-map landing (the two
  live context boxes, the ACL-1 seam edge, and the named-only static boxes), the
  firehose right-rail placeholder, and interaction-anchored teaching captions
  (spec developer-view.md, D2/D3).

  Everything here is **read-only**: it navigates and renders, never mutating. No
  component issues commands or exposes an edit/delete affordance.
  """
  use LatchkeyWeb, :html

  @doc """
  Left nav rail: contexts (deep + edge) with their aggregate and streams, then
  the named-only contexts rendered as honestly-labelled, non-navigable entries.
  """
  attr :contexts, :list, required: true, doc: "the live, emitting contexts"
  attr :named_contexts, :list, required: true, doc: "named-only, not-modelled contexts"
  attr :active_stream, :string, default: nil, doc: "currently selected stream id, if any"

  def nav_rail(assigns) do
    ~H"""
    <nav id="inspector-nav" aria-label="Context, aggregate and stream navigation" class="text-sm">
      <p class="px-2 mb-2 text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
        Context → Aggregate → Stream
      </p>

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

        <.link
          :for={stream <- ctx.streams}
          id={"nav-stream-#{stream.id}"}
          patch={~p"/inspector/streams/#{stream.id}"}
          class={[
            "flex items-center gap-2 pl-6 pr-2 py-1.5 rounded-md hover:bg-base-200 transition-colors",
            @active_stream == stream.id && "bg-primary/10 text-primary font-medium"
          ]}
        >
          <span class={["inline-block size-2 rounded-full", tone_dot(stream.tone)]} />
          <span class="flex flex-col leading-tight">
            <span>{stream.label}</span>
            <span class="font-mono text-[10.5px] text-base-content/50">{stream.id}</span>
          </span>
        </.link>
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
      </header>

      <div class="grid grid-cols-1 md:grid-cols-[1fr_auto_1fr] items-center gap-4 mb-8">
        <.context_box context={@edge_context} />

        <div id="acl-1-edge" class="text-center">
          <span class="inline-flex items-center gap-1.5 px-3 py-1 rounded-full bg-primary/10 text-primary font-mono text-xs">
            {@acl_edge_label}
          </span>
          <p class="mt-1.5 text-[10.5px] text-base-content/50">ACL-1</p>
          <p class="text-primary text-lg leading-none" aria-hidden="true">→</p>
        </div>

        <.context_box context={@deep_context} />
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
      <.link
        :for={stream <- @context.streams}
        id={"map-stream-#{stream.id}"}
        patch={~p"/inspector/streams/#{stream.id}"}
        class="flex items-center gap-2 px-1 py-1.5 rounded-md hover:bg-base-200 transition-colors"
      >
        <span class={["inline-block size-2 rounded-full", tone_dot(stream.tone)]} />
        <span class="flex flex-col leading-tight">
          <span>{stream.label}</span>
          <span class="font-mono text-[10.5px] text-base-content/50">{stream.id}</span>
        </span>
      </.link>
    </div>
    """
  end

  @doc """
  Right-rail firehose placeholder. The live feed itself lands in a later slice
  (#82); here we render a labelled empty region so the shell shows where it goes.
  """
  def firehose_placeholder(assigns) do
    ~H"""
    <aside
      id="firehose-placeholder"
      aria-label="Live event firehose (placeholder)"
      class="flex flex-col h-full"
    >
      <div class="flex items-baseline justify-between gap-2 px-3.5 py-3 border-b border-base-300">
        <span class="text-xs font-bold uppercase tracking-wide text-base-content/70">
          Firehose
        </span>
        <span class="font-mono text-[11px] text-base-content/50">dev:events</span>
      </div>
      <div class="flex-1 grid place-items-center p-4 text-center">
        <p class="text-xs text-base-content/50 max-w-[24ch]">
          The live event feed arrives in a later slice. Events will stream in here as the
          simulation emits them.
        </p>
      </div>
    </aside>
    """
  end

  @doc """
  Placeholder stream view. The deep three-pane treatment (events / aggregate /
  read model) + scrubber lands in a later slice; this shell just confirms the
  nav routed to the right stream.
  """
  attr :stream_id, :string, required: true
  attr :context_name, :string, required: true

  def stream_placeholder(assigns) do
    ~H"""
    <section id="stream-view" class="max-w-2xl">
      <div id={"stream-view-#{@stream_id}"} class="rounded-xl border border-base-300 bg-base-100 p-6">
        <p class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
          {@context_name}
        </p>
        <h2 class="mt-1 text-lg font-semibold font-mono">{@stream_id}</h2>
        <.caption class="mt-3">
          The event / aggregate-state / read-model panes and the replay scrubber for this
          stream arrive in a later slice. This shell routed you here read-only — no commands,
          no editing, no deleting.
        </.caption>
      </div>
    </section>
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
  slot :inner_block, required: true

  def caption(assigns) do
    ~H"""
    <p class={["text-xs leading-relaxed text-base-content/60 [&_b]:text-base-content/80", @class]}>
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
