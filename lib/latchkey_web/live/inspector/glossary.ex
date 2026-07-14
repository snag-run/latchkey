defmodule LatchkeyWeb.Inspector.Glossary do
  @moduledoc """
  Compile-time markdown source for the in-app **glossary** (spec glossary.md,
  D1/D2/D6) — the inspector's browsable, three-lens on-ramp to the domain and to
  the DDD/ES concepts the code uses.

  Each lens is rendered from a single markdown source into anchored HTML:

    * **domain** → `CONTEXT.md` *verbatim* — the ubiquitous language, rendered (never
      copied), so it can never drift from the single source of truth (D1/D6). Its
      inward cross-refs ("ADR 0008", "domain-model.md §7") are left intact (D6);
    * **ddd** / **es** → authored markdown under `priv/glossary/`, seeded here and
      filled in the content slice (#128).

  Headings become GitHub-style fragment anchors via Comrak's header-id extension,
  whose slugs agree exactly with `MDEx.anchorize/1` — so `anchor/1` is the canonical
  slug the pane `read_more` links (#129) target, and the two can't disagree.

  Rendering happens **once at compile time** from `@external_resource` files: there
  is no runtime file IO, it works in a release (no repo tree shipped), and the page
  is "always in sync at build" — a source edit recompiles the module.
  """

  # This file lives at lib/latchkey_web/live/inspector/glossary.ex; the repo root is
  # four directories up. CONTEXT.md sits at the root (its established home); the
  # authored DDD/ES lenses live with the other narrative docs under docs/glossary/.
  @repo_root Path.expand("../../../..", __DIR__)

  @sources %{
    domain: Path.join(@repo_root, "CONTEXT.md"),
    ddd: Path.join([@repo_root, "docs", "glossary", "ddd.md"]),
    es: Path.join([@repo_root, "docs", "glossary", "es.md"])
  }

  # Recompile whenever any lens source changes, so the rendered HTML never lags.
  for {_lens, path} <- @sources, do: @external_resource(path)

  # header_id_prefix: "" enables Comrak's header-id extension with no prefix, giving
  # each heading a GitHub-style anchor id that matches `MDEx.anchorize/1` (see the
  # moduledoc). table/strikethrough are GFM extensions kept in lock-step with
  # `Docs` (both render GitHub-authored markdown; the lenses have none today, but a
  # future table in CONTEXT.md must not fall through as raw pipe text). Content is
  # trusted first-party markdown, so the default safe render (raw HTML escaped) is
  # left on — no sanitisation is a driver (D2).
  @md_opts [extension: [header_id_prefix: "", table: true, strikethrough: true]]

  @rendered Map.new(@sources, fn {lens, path} ->
              {lens, MDEx.to_html!(File.read!(path), @md_opts)}
            end)

  @lenses Map.keys(@sources)

  # The three lens sections as the page renders them: the `<section>` wrapper id (a
  # jump target) and the human label. Order matches `lenses/0` (domain first, D6).
  @lens_headers [
    %{lens: :domain, id: "glossary-domain", label: "Domain"},
    %{lens: :ddd, id: "glossary-ddd", label: "DDD"},
    %{lens: :es, id: "glossary-es", label: "Event sourcing"}
  ]

  # Table of contents: the three lens sections as level-2 group headers (jumping to
  # the `<section>` wrapper), each followed by its `##` term headings as level-3
  # entries (jumping to the term anchor). Flat `[%{id, text, level}]` so it shares
  # the deep docs' TOC-rail rendering. Anonymous fns only — legal in an attribute.
  @toc (
         flatten = fn flatten, nodes ->
           Enum.map_join(nodes, "", fn
             %MDEx.Text{literal: t} -> t
             %MDEx.Code{literal: t} -> t
             %{nodes: children} -> flatten.(flatten, children)
             _ -> ""
           end)
         end

         Enum.flat_map(@lens_headers, fn %{lens: lens, id: id, label: label} ->
           terms =
             @sources
             |> Map.fetch!(lens)
             |> File.read!()
             |> MDEx.parse_document!(@md_opts)
             |> Map.fetch!(:nodes)
             |> Enum.filter(&match?(%MDEx.Heading{level: 2}, &1))
             |> Enum.map(fn %MDEx.Heading{nodes: inline} ->
               text = flatten.(flatten, inline) |> String.trim()
               %{id: MDEx.anchorize(text), text: text, level: 3}
             end)

           [%{id: id, text: label, level: 2} | terms]
         end)
       )

  @doc "The lens keys, in canonical order (domain first — the reference lens, D6)."
  def lenses, do: [:domain, :ddd, :es]

  @doc """
  The glossary's table of contents as a flat `[%{id, text, level}]` — each lens as a
  level-2 group header (`id` is its `<section>` wrapper) followed by its term
  headings as level-3 entries (`id` is the term anchor). Feeds the shared TOC rail.
  """
  def toc, do: @toc

  @doc """
  The rendered HTML for a lens (`:domain` | `:ddd` | `:es`), as a trusted string to
  be emitted with `Phoenix.HTML.raw/1`. Rendered at compile time from the lens source.
  """
  def html(lens) when lens in @lenses, do: Map.fetch!(@rendered, lens)

  @doc """
  The GitHub-style fragment anchor for a term heading — the canonical slug the
  glossary's rendered headings carry and the pane `read_more` links (#129) point at.
  Delegates to `MDEx.anchorize/1` so link targets and rendered ids can never drift.

      iex> LatchkeyWeb.Inspector.Glossary.anchor("Rental ledger")
      "rental-ledger"
  """
  def anchor(term) when is_binary(term), do: MDEx.anchorize(term)
end
