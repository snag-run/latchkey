defmodule LatchkeyWeb.InspectorComponentsTest do
  @moduledoc """
  Unit tests for the inspector's presentational helpers — the `read_more/1` link
  and the `glossary_ref/1` anchor builder (#129). The pane/LiveView tests assert
  each caption points at its glossary term; here we pin the *link mechanics*: an
  in-app target renders same-tab, an external one opens a new tab, and the anchor
  a pane points at is the same slug the glossary heading carries (no drift).
  """
  use LatchkeyWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias LatchkeyWeb.InspectorComponents

  doctest LatchkeyWeb.InspectorComponents, import: true

  describe "read_more/1" do
    test "an in-app href renders a same-tab live-nav link (#129)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <InspectorComponents.read_more href="/inspector/glossary#aggregate">
          Aggregate
        </InspectorComponents.read_more>
        """)

      assert html =~ ~s(href="/inspector/glossary#aggregate")
      assert html =~ "data-phx-link"
      assert html =~ "→"
      # Same tab: never a new-window target for an in-app link.
      refute html =~ "_blank"
    end

    test "an external href opens in a new tab" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <InspectorComponents.read_more href="https://example.com/doc.md">
          doc.md
        </InspectorComponents.read_more>
        """)

      assert html =~ ~s(href="https://example.com/doc.md")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener")
      assert html =~ "↗"
    end
  end

  describe "glossary_ref/1" do
    test "builds the in-app anchor from the same slug the glossary heading uses" do
      # Ties to Glossary.anchor/1 so a pane link and its heading can't drift.
      assert InspectorComponents.glossary_ref("Rental ledger") ==
               "/inspector/glossary#" <> LatchkeyWeb.Inspector.Glossary.anchor("Rental ledger")

      assert InspectorComponents.glossary_ref("Event store / stream") ==
               "/inspector/glossary#event-store--stream"
    end
  end
end
