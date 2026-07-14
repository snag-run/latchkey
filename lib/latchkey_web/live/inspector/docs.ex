defmodule LatchkeyWeb.Inspector.Docs do
  @moduledoc """
  Compile-time markdown source for the in-app **deep docs** (spec glossary.md,
  D8/D9, issue #131) — the two canonical narrative docs rendered as an in-app,
  read-through reference library, coexisting with (never folded into) the
  glossary's concise term index:

    * **context_map** → `docs/context-map.md` — the strategic bounded-context map;
    * **domain_model** → `docs/domain-model.md` — the tactical model (§1–§11).

  This reuses the exact #127 machinery of `LatchkeyWeb.Inspector.Glossary`: each
  doc is rendered **once at compile time** from an `@external_resource` file via
  `MDEx`, with Comrak's header-id extension (`header_id_prefix: ""`) so headings
  become GitHub-style fragment anchors whose slugs match `MDEx.anchorize/1` — the
  same anchors the pane `read_more` links target (#129).

  ## Deep-doc link handling (D9)

  The docs render **verbatim** (extends D6) with **one** render-time rule: a
  *relative* markdown link (`[ADR 0005](adr/0005-…md)`, `[…](./domain-model.md)`)
  would resolve in-app to `/inspector/docs/adr/…` → 404, so it is rewritten to its
  absolute GitHub `blob/main/docs/…` URL. Absolute URLs (e.g. the NSW RTA links),
  in-page `#` anchors, and plain-text refs (`§7`, `ADR 0008`) are left untouched.
  The rewrite walks the parsed AST, so it never touches link text or code spans.
  """

  # This file lives at lib/latchkey_web/live/inspector/docs.ex; the repo root is
  # four directories up. Both deep docs live under docs/ (their established home).
  @repo_root Path.expand("../../../..", __DIR__)

  @sources %{
    context_map: Path.join([@repo_root, "docs", "context-map.md"]),
    domain_model: Path.join([@repo_root, "docs", "domain-model.md"])
  }

  # Recompile whenever a doc source changes, so the rendered HTML never lags.
  for {_doc, path} <- @sources, do: @external_resource(path)

  # header_id_prefix: "" gives each heading a GitHub-style anchor id matching
  # `MDEx.anchorize/1`. table/strikethrough are GFM extensions the docs use (the
  # event tables in §3/§5, ~~struck~~ deferred markers) — off by default, they'd
  # otherwise fall through as raw pipe text. Content is trusted first-party
  # markdown (default safe render left on). Same options as `Glossary`, so the two
  # agree byte-for-byte.
  @md_opts [extension: [header_id_prefix: "", table: true, strikethrough: true]]

  # D9: relative in-repo doc links resolve against docs/ and point at the GitHub
  # blob, since the ADRs and cross-doc targets are not (all) rendered in-app.
  @github_docs_base "https://github.com/snag-run/latchkey/blob/main/docs/"

  @github_blob "https://github.com/snag-run/latchkey/blob/main/"

  @titles %{context_map: "Context Map", domain_model: "Domain Model"}

  @source_paths %{
    context_map: "docs/context-map.md",
    domain_model: "docs/domain-model.md"
  }

  # Render each doc once at compile time, rewriting relative links (D9) on the AST
  # between parse and render. Only external functions are called here (MDEx, URI,
  # String), so this is legal in a module-attribute expression.
  @rendered (
              rewrite = fn url ->
                cond do
                  URI.parse(url).scheme != nil -> url
                  String.starts_with?(url, "#") -> url
                  String.starts_with?(url, "/") -> url
                  true -> @github_docs_base <> String.replace_prefix(url, "./", "")
                end
              end

              Map.new(@sources, fn {doc, path} ->
                html =
                  path
                  |> File.read!()
                  |> MDEx.parse_document!(@md_opts)
                  |> MDEx.traverse_and_update(fn
                    %MDEx.Link{url: url} = link -> %{link | url: rewrite.(url)}
                    node -> node
                  end)
                  |> MDEx.to_html!(@md_opts)

                {doc, html}
              end)
            )

  @docs Map.keys(@sources)

  @doc "The deep-doc keys, in canonical order (equal billing — no priority, D11)."
  def docs, do: [:context_map, :domain_model]

  @doc """
  The rendered HTML for a doc (`:context_map` | `:domain_model`), as a trusted
  string to be emitted with `Phoenix.HTML.raw/1`. Rendered at compile time from the
  doc source with relative links rewritten to GitHub (D9).
  """
  def html(doc) when doc in @docs, do: Map.fetch!(@rendered, doc)

  @doc "The human title for a doc, used in the page header and the D11 front doors."
  def title(doc) when doc in @docs, do: Map.fetch!(@titles, doc)

  @doc "The canonical GitHub source URL for a doc (the header's view-source link, D5c)."
  def source_url(doc) when doc in @docs, do: @github_blob <> Map.fetch!(@source_paths, doc)
end
