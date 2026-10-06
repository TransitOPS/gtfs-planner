defmodule GtfsPlannerWeb.DrawerModalTest do
  @moduledoc """
  Covers the `modal={false}` drawer mode: the shared `.drawer` stays modal by
  default, and a non-modal drawer renders the right-hand panel without a
  backdrop, without `aria-modal`, and with the Escape, Close and focus policy
  the `OverlayDialog` hook implements in `assets/js/overlay_dialog_hook.js`.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import GtfsPlannerWeb.CoreComponents

  defp render_drawer(assigns) do
    assigns = Map.put_new(assigns, :modal, true)

    rendered_to_string(~H"""
    <.drawer
      id="inspector"
      chrome="planner"
      title="Connection"
      open
      modal={@modal}
      return_focus_id="blocks-connection-row"
      initial_focus_id="inspector-title"
      class="max-w-[480px]"
    >
      <:lede>North Avenue → Old Alignment</:lede>
      <:header_actions>
        <span id="inspector-chip" class="text-[13px]">Riders stay on board</span>
      </:header_actions>
      <p id="inspector-slot">Body</p>
    </.drawer>
    """)
  end

  defp panel_classes(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("aside#inspector")
    |> LazyHTML.attribute("class")
    |> List.first()
    |> String.split(" ", trim: true)
  end

  defp dialog_classes(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("dialog#inspector-overlay")
    |> LazyHTML.attribute("class")
    |> List.first()
    |> String.split(" ", trim: true)
  end

  describe "the modal default" do
    test "renders data-modal=true, aria-modal and no non-modal positioning" do
      doc = render_drawer(%{}) |> LazyHTML.from_fragment()
      dialog = LazyHTML.query(doc, "dialog#inspector-overlay")

      assert LazyHTML.attribute(dialog, "data-modal") == ["true"]
      assert LazyHTML.attribute(dialog, "role") == ["dialog"]
      assert LazyHTML.attribute(dialog, "aria-modal") == ["true"]
      assert LazyHTML.attribute(dialog, "aria-hidden") == []
      assert LazyHTML.attribute(dialog, "inert") == []
    end

    test "an explicit modal={true} renders the same as the default" do
      html = render_drawer(%{modal: true})
      doc = html |> LazyHTML.from_fragment()
      dialog = LazyHTML.query(doc, "dialog#inspector-overlay")

      assert LazyHTML.attribute(dialog, "data-modal") == ["true"]
      assert LazyHTML.attribute(dialog, "aria-modal") == ["true"]
      assert "absolute" in panel_classes(html)
    end

    test "positions the panel absolutely inside the full-viewport dialog" do
      html = render_drawer(%{})

      assert "absolute" in panel_classes(html)
      refute "fixed" in panel_classes(html)
      assert "w-screen" in dialog_classes(html)
      refute "pointer-events-none" in dialog_classes(html)
      refute "z-40" in dialog_classes(html)
    end
  end

  describe "modal={false}" do
    test "renders data-modal=false, no aria-modal, and no backdrop-only state" do
      doc = render_drawer(%{modal: false}) |> LazyHTML.from_fragment()
      dialog = LazyHTML.query(doc, "dialog#inspector-overlay")

      assert LazyHTML.attribute(dialog, "data-modal") == ["false"]
      assert LazyHTML.attribute(dialog, "role") == ["dialog"]
      assert LazyHTML.attribute(dialog, "aria-modal") == []
      assert LazyHTML.attribute(dialog, "aria-hidden") == []
      assert LazyHTML.attribute(dialog, "inert") == []
    end

    test "pins the panel to the right edge and lets clicks through the wrapper" do
      html = render_drawer(%{modal: false})

      panel = panel_classes(html)
      assert "fixed" in panel
      refute "absolute" in panel
      assert "right-0" in panel
      assert "pointer-events-auto" in panel
      assert "max-w-[480px]" in panel

      dialog = dialog_classes(html)
      assert "fixed" in dialog
      assert "z-40" in dialog
      assert "pointer-events-none" in dialog
    end

    test "keeps the planner chrome, slots and body helpers" do
      doc = render_drawer(%{modal: false}) |> LazyHTML.from_fragment()

      assert Enum.count(LazyHTML.query(doc, "aside#inspector")) == 1
      assert Enum.count(LazyHTML.query(doc, "#inspector-title")) == 1
      assert Enum.count(LazyHTML.query(doc, "#inspector-close[data-dialog-dismiss]")) == 1
      assert Enum.count(LazyHTML.query(doc, "#inspector-body")) == 1
      assert Enum.count(LazyHTML.query(doc, "#inspector-chip")) == 1

      # `LazyHTML.text/1` reads one fragment, so each node is queried first; the
      # drawer's own body wrapper carries `#inspector-body`, which is why the slot
      # paragraph above is named `#inspector-slot`.
      assert LazyHTML.text(LazyHTML.query(doc, "#inspector-body")) =~ "Body"
      assert LazyHTML.text(LazyHTML.query(doc, "#inspector-slot")) == "Body"
      assert LazyHTML.text(LazyHTML.query(doc, "#inspector-title")) =~ "Connection"
    end

    test "keeps the focus, pending and backdrop policy attributes" do
      doc = render_drawer(%{modal: false}) |> LazyHTML.from_fragment()
      dialog = LazyHTML.query(doc, "dialog#inspector-overlay")

      assert LazyHTML.attribute(dialog, "data-initial-focus") == ["heading"]
      assert LazyHTML.attribute(dialog, "data-initial-focus-id") == ["inspector-title"]
      assert LazyHTML.attribute(dialog, "data-return-focus-id") == ["blocks-connection-row"]
      assert LazyHTML.attribute(dialog, "data-pending") == ["false"]
      assert LazyHTML.attribute(dialog, "data-close-on-backdrop") == ["true"]
      assert LazyHTML.attribute(dialog, "aria-labelledby") == ["inspector-title"]
    end

    test "a closed non-modal drawer is inert and hidden" do
      assigns = %{}

      doc =
        rendered_to_string(~H"""
        <.drawer id="inspector" chrome="planner" title="Connection" modal={false}>
          <p>Body</p>
        </.drawer>
        """)
        |> LazyHTML.from_fragment()

      dialog = LazyHTML.query(doc, "dialog#inspector-overlay")

      assert LazyHTML.attribute(dialog, "data-open") == ["false"]
      assert LazyHTML.attribute(dialog, "data-modal") == ["false"]
      assert LazyHTML.attribute(dialog, "inert") == [""]
      assert LazyHTML.attribute(dialog, "aria-hidden") == ["true"]
      assert LazyHTML.attribute(dialog, "role") == []
    end
  end
end
