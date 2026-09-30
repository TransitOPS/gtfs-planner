defmodule GtfsPlannerWeb.CoreComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import GtfsPlannerWeb.CoreComponents

  describe "drawer/1" do
    test "closed drawer renders inert, aria-hidden, data-open=false, and no role" do
      assigns = %{open: false, title: "Test"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title}>
          <p>Drawer content</p>
        </.drawer>
        """)

      doc = LazyHTML.from_fragment(html)
      dialog = LazyHTML.query(doc, "dialog#test-drawer-overlay")

      assert LazyHTML.attribute(dialog, "data-open") == ["false"]
      assert LazyHTML.attribute(dialog, "inert") == [""]
      assert LazyHTML.attribute(dialog, "aria-hidden") == ["true"]
      assert LazyHTML.attribute(dialog, "role") == []
      assert LazyHTML.attribute(dialog, "aria-modal") == []
      assert Enum.count(LazyHTML.query(doc, "aside#test-drawer")) == 1
    end

    test "open drawer renders role=dialog, aria-modal=true, and no inert" do
      assigns = %{open: true, title: "Test"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title}>
          <p>Drawer content</p>
        </.drawer>
        """)

      dialog = html |> LazyHTML.from_fragment() |> LazyHTML.query("dialog#test-drawer-overlay")

      assert LazyHTML.attribute(dialog, "data-open") == ["true"]
      assert LazyHTML.attribute(dialog, "role") == ["dialog"]
      assert LazyHTML.attribute(dialog, "aria-modal") == ["true"]
      assert LazyHTML.attribute(dialog, "aria-labelledby") == ["test-drawer-title"]
      assert LazyHTML.attribute(dialog, "inert") == []
      assert LazyHTML.attribute(dialog, "aria-hidden") == []
    end

    test "drawer exposes focus policy as data attributes" do
      assigns = %{open: true, title: "Test"}

      html =
        rendered_to_string(~H"""
        <.drawer
          id="test-drawer"
          open={@open}
          title={@title}
          initial_focus={:heading}
          close_on_backdrop={false}
        >
          <p>Content</p>
        </.drawer>
        """)

      dialog = html |> LazyHTML.from_fragment() |> LazyHTML.query("dialog#test-drawer-overlay")

      assert LazyHTML.attribute(dialog, "data-initial-focus") == ["heading"]
      assert LazyHTML.attribute(dialog, "data-close-on-backdrop") == ["false"]
    end

    test "drawer renders derived stable IDs and preserves caller panel ID" do
      assigns = %{open: true, title: "Test"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title}>
          <p>Content</p>
        </.drawer>
        """)

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "dialog#test-drawer-overlay")) == 1
      assert Enum.count(LazyHTML.query(doc, "aside#test-drawer")) == 1
      assert Enum.count(LazyHTML.query(doc, "#test-drawer-title")) == 1
      assert Enum.count(LazyHTML.query(doc, "#test-drawer-close")) == 1
      assert Enum.count(LazyHTML.query(doc, "#test-drawer-body")) == 1
    end

    test "drawer title heading has tabindex=-1 for focus" do
      assigns = %{open: true, title: "Test Title"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title}>
          <p>Content</p>
        </.drawer>
        """)

      heading = html |> LazyHTML.from_fragment() |> LazyHTML.query("#test-drawer-title")

      assert LazyHTML.attribute(heading, "tabindex") == ["-1"]
    end

    test "drawer panel is an explicit focus fallback" do
      assigns = %{open: true, title: "Test Title"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title}>
          <p>Content</p>
        </.drawer>
        """)

      panel = html |> LazyHTML.from_fragment() |> LazyHTML.query("aside#test-drawer")

      assert LazyHTML.attribute(panel, "data-dialog-panel") == [""]
      assert LazyHTML.attribute(panel, "tabindex") == ["-1"]
    end

    test "close button has matching tooltip and accessible name plus a 44px hit target" do
      assigns = %{open: true, title: "Test"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title}>
          <p>Content</p>
        </.drawer>
        """)

      doc = LazyHTML.from_fragment(html)
      button = LazyHTML.query(doc, "#test-drawer-close")
      tooltip = LazyHTML.query(doc, ".tooltip.tooltip-left[data-tip]")

      assert LazyHTML.attribute(button, "data-dialog-dismiss") == [""]
      assert LazyHTML.attribute(tooltip, "data-tip") == LazyHTML.attribute(button, "aria-label")
      assert "tooltip-left" in (LazyHTML.attribute(tooltip, "class") |> hd() |> String.split())
      classes = LazyHTML.attribute(button, "class") |> hd()
      assert String.contains?(classes, "min-w-[44px]")
      assert String.contains?(classes, "min-h-[44px]")
    end

    test "uses custom on_close event name and optional target" do
      assigns = %{open: true, title: "Test"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title} on_close="custom_close_event">
          <p>Content</p>
        </.drawer>
        """)

      assert html =~ ~s(phx-click="custom_close_event")
    end

    test "renders inner_block content" do
      assigns = %{open: true, title: "Test"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title}>
          <p>Custom drawer content</p>
          <div class="custom-class">More content</div>
        </.drawer>
        """)

      assert html =~ "Custom drawer content"
      assert html =~ "More content"
      assert html =~ "custom-class"
    end

    test "renders optional header_actions slot" do
      assigns = %{open: true, title: "Test"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title}>
          <:header_actions>
            <button class="action-btn">Action</button>
          </:header_actions>
          <p>Content</p>
        </.drawer>
        """)

      assert html =~ "action-btn"
    end

    test "includes phx-mounted and phx-hook for native sync" do
      assigns = %{open: false, title: "Test"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} title={@title}>
          <p>Content</p>
        </.drawer>
        """)

      assert html =~ "phx-mounted"
      assert html =~ "phx-hook=\"OverlayDialog\""
    end

    test "planner chrome keeps the panel, title, close and body IDs and the dismiss contract" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" chrome="planner" open={true} title="Invite user">
          <:lede>They get an email.</:lede>
          <p>Content</p>
        </.drawer>
        """)

      doc = LazyHTML.from_fragment(html)
      close = LazyHTML.query(doc, "button#test-drawer-close")

      assert Enum.count(LazyHTML.query(doc, "aside#test-drawer")) == 1
      assert Enum.count(LazyHTML.query(doc, "h2#test-drawer-title")) == 1
      assert Enum.count(LazyHTML.query(doc, "#test-drawer-body")) == 1
      assert LazyHTML.attribute(close, "data-dialog-dismiss") == [""]
      assert LazyHTML.attribute(close, "phx-click") == ["close_drawer"]
    end

    test "planner chrome shows a text Close button at a 44px target and the lede under the title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" chrome="planner" open={true} title="Invite user">
          <:lede>They get an email.</:lede>
          <p>Content</p>
        </.drawer>
        """)

      doc = LazyHTML.from_fragment(html)
      close = LazyHTML.query(doc, "button#test-drawer-close")

      assert LazyHTML.text(close) =~ "Close"
      assert LazyHTML.attribute(close, "class") |> hd() =~ "min-h-11"

      assert LazyHTML.text(LazyHTML.query(doc, "aside#test-drawer header p")) =~
               "They get an email."
    end

    test "planner chrome disables Close while a write is pending" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" chrome="planner" open={true} pending={true} title="Invite user">
          <p>Content</p>
        </.drawer>
        """)

      close = html |> LazyHTML.from_fragment() |> LazyHTML.query("button#test-drawer-close")

      assert LazyHTML.attribute(close, "disabled") == [""]
    end

    test "the default chrome has no lede and no text Close button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={true} title="Edit">
          <p>Content</p>
        </.drawer>
        """)

      close = html |> LazyHTML.from_fragment() |> LazyHTML.query("button#test-drawer-close")

      assert LazyHTML.text(close) |> String.trim() == ""
    end
  end

  describe "confirm_dialog/1" do
    test "closed renders inert, aria-hidden, data-open=false, and no role" do
      assigns = %{open: false}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      dialog = html |> LazyHTML.from_fragment() |> LazyHTML.query("dialog#test-confirm")

      assert LazyHTML.attribute(dialog, "data-open") == ["false"]
      assert LazyHTML.attribute(dialog, "inert") == [""]
      assert LazyHTML.attribute(dialog, "aria-hidden") == ["true"]
      assert LazyHTML.attribute(dialog, "role") == []
      assert LazyHTML.attribute(dialog, "aria-modal") == []
    end

    test "open renders role=alertdialog, aria-modal=true, and stable derived IDs" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)
      dialog = LazyHTML.query(doc, "dialog#test-confirm")

      assert LazyHTML.attribute(dialog, "data-open") == ["true"]
      assert LazyHTML.attribute(dialog, "role") == ["alertdialog"]
      assert LazyHTML.attribute(dialog, "aria-modal") == ["true"]
      assert LazyHTML.attribute(dialog, "inert") == []
      assert LazyHTML.attribute(dialog, "aria-hidden") == []

      assert Enum.count(LazyHTML.query(doc, "#test-confirm-title")) == 1
      assert Enum.count(LazyHTML.query(doc, "#test-confirm-body")) == 1
      assert Enum.count(LazyHTML.query(doc, "#test-confirm-cancel")) == 1
      assert Enum.count(LazyHTML.query(doc, "#test-confirm-confirm")) == 1
    end

    test "omits aria-describedby when described_by not supplied" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      assert html =~ "aria-describedby" == false
    end

    test "includes aria-describedby when described_by supplied" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
          described_by="desc-42"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      assert html =~ ~s(aria-describedby="desc-42")
    end

    test "wires string events on confirm and cancel buttons" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="do_delete"
          on_cancel="do_cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)

      confirm = LazyHTML.query(doc, "#test-confirm-confirm")
      assert LazyHTML.attribute(confirm, "phx-click") == ["do_delete"]

      cancel = LazyHTML.query(doc, "#test-confirm-cancel")
      assert LazyHTML.attribute(cancel, "phx-click") == ["do_cancel"]
    end

    test "confirm button has phx-disable-with and shows label" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete route"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      confirm = html |> LazyHTML.from_fragment() |> LazyHTML.query("#test-confirm-confirm")

      assert LazyHTML.attribute(confirm, "phx-disable-with") == ["Deleting…"]
      assert html =~ "Delete route"
    end

    test "renders pending_label and disables both buttons when pending" do
      assigns = %{open: true, pending: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete route"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
          pending={@pending}
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)

      confirm = LazyHTML.query(doc, "#test-confirm-confirm")
      assert LazyHTML.attribute(confirm, "disabled") == [""]
      assert html =~ "Deleting…"
      refute html =~ "Delete route"

      cancel = LazyHTML.query(doc, "#test-confirm-cancel")
      assert LazyHTML.attribute(cancel, "disabled") == [""]
    end

    test "cancel button has data-dialog-dismiss and 44px hit target" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      cancel = html |> LazyHTML.from_fragment() |> LazyHTML.query("#test-confirm-cancel")

      assert LazyHTML.attribute(cancel, "data-dialog-dismiss") == [""]
      classes = LazyHTML.attribute(cancel, "class") |> hd()
      assert String.contains?(classes, "h-[44px]")
      assert String.contains?(classes, "min-w-[44px]")
    end

    test "close_on_backdrop defaults to false" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      dialog = html |> LazyHTML.from_fragment() |> LazyHTML.query("dialog#test-confirm")

      assert LazyHTML.attribute(dialog, "data-close-on-backdrop") == ["false"]
    end

    test "sets data-pending=true on the dialog when pending" do
      assigns = %{open: true, pending: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
          pending={@pending}
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      dialog = html |> LazyHTML.from_fragment() |> LazyHTML.query("dialog#test-confirm")

      assert LazyHTML.attribute(dialog, "data-pending") == ["true"]
    end

    test "names the alertdialog from its required title" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      dialog = html |> LazyHTML.from_fragment() |> LazyHTML.query("dialog#test-confirm")

      assert LazyHTML.attribute(dialog, "aria-labelledby") == ["test-confirm-title"]
    end

    test "sets data-return-focus-id when provided" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
          return_focus_id="result-42"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      dialog = html |> LazyHTML.from_fragment() |> LazyHTML.query("dialog#test-confirm")

      assert LazyHTML.attribute(dialog, "data-return-focus-id") == ["result-42"]
    end

    test "includes phx-mounted and phx-hook" do
      assigns = %{open: false}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      assert html =~ "phx-mounted"
      assert html =~ "phx-hook=\"OverlayDialog\""
    end

    test "default panel and confirm button keep small danger classes" do
      # AC-1: omitting size and confirm_variant renders byte-compatible small
      # danger output — max-w-sm panel, no scroll body, danger confirm colors.
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Delete?"
          confirm_label="Delete"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)

      panel = LazyHTML.query(doc, "dialog#test-confirm > div > div")
      panel_class = LazyHTML.attribute(panel, "class") |> List.first()
      assert panel_class =~ "max-w-sm"
      refute panel_class =~ "max-w-2xl"

      body = LazyHTML.query(doc, "#test-confirm-body")
      body_class = LazyHTML.attribute(body, "class") |> List.first()
      refute body_class =~ "max-h-[60vh]"
      refute body_class =~ "overflow-y-auto"

      confirm = LazyHTML.query(doc, "#test-confirm-confirm")
      confirm_class = LazyHTML.attribute(confirm, "class") |> List.first()
      assert confirm_class =~ "bg-error"
      assert confirm_class =~ "text-error-content"
      refute confirm_class =~ "bg-primary"
      refute confirm_class =~ "text-primary-content"
    end

    test "size lg renders max-w-2xl panel with scroll-bounded body" do
      # AC-2: size="lg" produces the wide panel and the 60vh scroll body that
      # hosts the evidence table without truncation (DC-6).
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Update coordinates?"
          confirm_label="Update stops"
          pending_label="Updating…"
          on_confirm="update"
          on_cancel="cancel"
          size="lg"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)

      panel = LazyHTML.query(doc, "dialog#test-confirm > div > div")
      panel_class = LazyHTML.attribute(panel, "class") |> List.first()
      assert panel_class =~ "max-w-2xl"
      refute panel_class =~ "max-w-sm"

      body = LazyHTML.query(doc, "#test-confirm-body")
      body_class = LazyHTML.attribute(body, "class") |> List.first()
      assert body_class =~ "max-h-[60vh]"
      assert body_class =~ "overflow-y-auto"
    end

    test "confirm_variant primary renders primary confirm colors" do
      # AC-2: confirm_variant="primary" swaps the confirm button onto the
      # primary token without widening the dialog.
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Update coordinates?"
          confirm_label="Update stops"
          pending_label="Updating…"
          on_confirm="update"
          on_cancel="cancel"
          confirm_variant="primary"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      confirm =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#test-confirm-confirm")

      confirm_class = LazyHTML.attribute(confirm, "class") |> List.first()
      assert confirm_class =~ "bg-primary"
      assert confirm_class =~ "text-primary-content"
      refute confirm_class =~ "bg-error"
      refute confirm_class =~ "text-error-content"
    end

    test "planner chrome confirms in the action colour and keeps the alertdialog contract" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          chrome="planner"
          open={true}
          title="Deactivate sam@agency.org?"
          confirm_label="Deactivate user"
          pending_label="Deactivating user…"
          cancel_label="Keep access"
          on_confirm="confirm"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)
      dialog = LazyHTML.query(doc, "dialog#test-confirm")
      confirm = LazyHTML.query(doc, "#test-confirm-confirm")
      cancel = LazyHTML.query(doc, "#test-confirm-cancel")

      assert LazyHTML.attribute(dialog, "role") == ["alertdialog"]
      assert LazyHTML.attribute(cancel, "data-dialog-dismiss") == [""]
      assert LazyHTML.text(cancel) =~ "Keep access"
      assert LazyHTML.attribute(confirm, "class") |> hd() =~ "bg-action"
      refute LazyHTML.attribute(confirm, "class") |> hd() =~ "bg-error"
      assert LazyHTML.attribute(confirm, "phx-disable-with") == ["Deactivating user…"]
    end

    test "planner chrome widens to the 600px review and bounds its body when size is lg" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          chrome="planner"
          size="lg"
          open={true}
          title="Assign 3 stops to a zone"
          confirm_label="Assign 3 stops"
          pending_label="Saving…"
          on_confirm="confirm"
          on_cancel="cancel"
        >
          <p>Rows</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)

      body_class =
        doc |> LazyHTML.query("#test-confirm-body") |> LazyHTML.attribute("class") |> hd()

      assert html =~ "w-[min(600px,calc(100vw-32px))]"
      refute html =~ "w-[min(440px,calc(100vw-32px))]"
      assert body_class =~ "max-h-[60vh]"
      assert body_class =~ "overflow-y-auto"
    end

    test "planner chrome keeps the 440px panel and an unbounded body at the default size" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          chrome="planner"
          open={true}
          title="Remove this fare rule?"
          confirm_label="Remove rule"
          pending_label="Removing…"
          on_confirm="confirm"
          on_cancel="cancel"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      body_class =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#test-confirm-body")
        |> LazyHTML.attribute("class")
        |> hd()

      assert html =~ "w-[min(440px,calc(100vw-32px))]"
      refute body_class =~ "max-h-[60vh]"
    end

    test "planner chrome shows a confirm the page ruled out as unavailable, not as pending" do
      render_confirm = fn confirm_disabled, pending ->
        assigns = %{confirm_disabled: confirm_disabled, pending: pending}

        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          chrome="planner"
          open={true}
          title="Delete Central?"
          confirm_label="Delete zone"
          pending_label="Deleting…"
          on_confirm="confirm"
          on_cancel="cancel"
          confirm_disabled={@confirm_disabled}
          pending={@pending}
        >
          <p>Choose a zone first.</p>
        </.confirm_dialog>
        """)
      end

      confirm_class = fn html ->
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#test-confirm-confirm")
        |> LazyHTML.attribute("class")
        |> hd()
      end

      ruled_out = render_confirm.(true, false)
      pending = render_confirm.(true, true)
      ready = render_confirm.(false, false)

      # Ruled out: the design system's disabled control, so it does not look clickable.
      assert confirm_class.(ruled_out) =~ "cursor-not-allowed"
      assert confirm_class.(ruled_out) =~ "bg-canvas"
      refute confirm_class.(ruled_out) =~ "bg-action"

      # A write in flight keeps the action colour and its wait cursor.
      assert confirm_class.(pending) =~ "bg-action"
      refute confirm_class.(pending) =~ "cursor-not-allowed"

      # Ready: the action colour, enabled.
      assert confirm_class.(ready) =~ "bg-action"

      assert ready
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#test-confirm-confirm")
             |> LazyHTML.attribute("disabled") == []

      assert ruled_out
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#test-confirm-confirm")
             |> LazyHTML.attribute("disabled") == [""]
    end

    test "planner chrome at xl is the 680px review panel whose footer stays in view" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          chrome="planner"
          size="xl"
          open={true}
          title="Update 38 trips?"
          confirm_label="Update 38 trips"
          pending_label="Updating…"
          on_confirm="confirm"
          on_cancel="cancel"
        >
          <p>Review</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)

      panel =
        LazyHTML.query(doc, "dialog#test-confirm > div > div") |> LazyHTML.attribute("class")

      body = LazyHTML.query(doc, "#test-confirm-body") |> LazyHTML.attribute("class")

      assert hd(panel) =~ "w-[min(680px,calc(100vw-32px))]"
      assert hd(body) =~ "overflow-y-auto"
      assert Enum.count(LazyHTML.query(doc, "#test-confirm-confirm")) == 1
    end

    test "planner chrome at 2xl is the 720px review panel whose footer stays in view" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          chrome="planner"
          size="2xl"
          open={true}
          title="Keyboard shortcuts"
          confirm_label="Close"
          pending_label="Closing…"
          on_confirm="confirm"
          on_cancel="cancel"
          single_action
        >
          <p>Review</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)

      panel =
        LazyHTML.query(doc, "dialog#test-confirm > div > div") |> LazyHTML.attribute("class")

      body = LazyHTML.query(doc, "#test-confirm-body") |> LazyHTML.attribute("class")

      assert hd(panel) =~ "w-[min(720px,calc(100vw-32px))]"
      assert hd(body) =~ "overflow-y-auto"
      assert Enum.empty?(LazyHTML.query(doc, "#test-confirm-confirm"))
    end

    test "a confirm form makes the confirm button submit that form instead of pushing an event" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          chrome="planner"
          open={true}
          title="Assign selected trips"
          confirm_label="Save assignment"
          pending_label="Saving…"
          on_confirm="submit_assign"
          on_cancel="cancel"
          confirm_form="assign-form"
        >
          <form id="assign-form"></form>
        </.confirm_dialog>
        """)

      confirm = html |> LazyHTML.from_fragment() |> LazyHTML.query("#test-confirm-confirm")

      assert LazyHTML.attribute(confirm, "type") == ["submit"]
      assert LazyHTML.attribute(confirm, "form") == ["assign-form"]
      assert LazyHTML.attribute(confirm, "phx-click") == []
    end

    test "without a confirm form the confirm button still pushes its event" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={true}
          title="Delete route?"
          confirm_label="Delete route"
          pending_label="Deleting…"
          on_confirm="delete"
          on_cancel="cancel"
        >
          <p>Consequence</p>
        </.confirm_dialog>
        """)

      confirm = html |> LazyHTML.from_fragment() |> LazyHTML.query("#test-confirm-confirm")

      assert LazyHTML.attribute(confirm, "type") == ["button"]
      assert LazyHTML.attribute(confirm, "form") == []
      assert LazyHTML.attribute(confirm, "phx-click") == ["delete"]
    end

    test "lg primary dialog retains alertdialog dismiss and pending semantics" do
      # AC-2 + INV-1: the wide primary presentation is the same alertdialog;
      # cancel-first dismissal and pending lockout survive the new axes.
      assigns = %{open: true, pending: true}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog
          id="test-confirm"
          open={@open}
          title="Update coordinates?"
          confirm_label="Update stops"
          pending_label="Updating…"
          on_confirm="update"
          on_cancel="cancel"
          pending={@pending}
          size="lg"
          confirm_variant="primary"
        >
          <p>Consequence text</p>
        </.confirm_dialog>
        """)

      doc = LazyHTML.from_fragment(html)

      dialog = LazyHTML.query(doc, "dialog#test-confirm")
      assert LazyHTML.attribute(dialog, "role") == ["alertdialog"]
      assert LazyHTML.attribute(dialog, "aria-modal") == ["true"]
      assert LazyHTML.attribute(dialog, "data-pending") == ["true"]
      assert LazyHTML.attribute(dialog, "inert") == []
      assert LazyHTML.attribute(dialog, "aria-hidden") == []

      confirm = LazyHTML.query(doc, "#test-confirm-confirm")
      assert LazyHTML.attribute(confirm, "disabled") == [""]
      assert LazyHTML.attribute(confirm, "phx-disable-with") == ["Updating…"]
      assert html =~ "Updating…"
      refute html =~ "Update stops"

      cancel = LazyHTML.query(doc, "#test-confirm-cancel")
      assert LazyHTML.attribute(cancel, "disabled") == [""]
      assert LazyHTML.attribute(cancel, "data-dialog-dismiss") == [""]
    end
  end

  describe "pagination/1" do
    test "omits the noun when no entity is given" do
      assigns = %{page: 1, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "Showing 1–10 of 25"
      refute html =~ "routes"
    end

    test "appends the entity noun when given" do
      assigns = %{page: 1, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} entity="routes" />
        """)

      assert html =~ "Showing 1–10 of 25 routes"
      assert html =~ "Previous"
      assert html =~ "Next"
    end

    test "renders correct range on second page" do
      assigns = %{page: 2, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} entity="routes" />
        """)

      assert html =~ "Showing 11–20 of 25 routes"
    end

    test "renders correct range on last page with partial results" do
      assigns = %{page: 3, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} entity="routes" />
        """)

      assert html =~ "Showing 21–25 of 25 routes"
    end

    test "handles empty state correctly (total = 0)" do
      assigns = %{page: 1, per_page: 10, total: 0}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} entity="routes" />
        """)

      assert html =~ "Showing 0–0 of 0 routes"
      refute html =~ "Showing 1–0"
    end

    test "disables Previous button on first page" do
      assigns = %{page: 1, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ ~r/disabled.*Previous/s
    end

    test "disables Next button on last page" do
      assigns = %{page: 3, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ ~r/disabled.*Next/s
    end

    test "enables both buttons on middle page" do
      assigns = %{page: 2, per_page: 10, total: 50}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      refute html =~ ~r/disabled.*Previous/s
      refute html =~ ~r/disabled.*Next/s
    end

    test "renders pagination controls with phx-click events" do
      assigns = %{page: 2, per_page: 10, total: 50}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "phx-click=\"paginate\""
      assert html =~ "phx-value-page=\"1\""
      assert html =~ "phx-value-page=\"3\""
    end
  end

  describe "input/1 accessibility" do
    test "points aria-describedby only at help text when there are no errors" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input id="name" name="name" label="Name" help="Pick a memorable name" />
        """)

      assert html =~ "id=\"name-help\""
      assert html =~ ~r/aria-describedby="name-help"/
      refute html =~ "name-error"
      assert html =~ ~r/aria-invalid="false"/
    end

    test "combine help and error IDs in aria-describedby when both are present" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          id="name"
          name="name"
          label="Name"
          help="Pick a memorable name"
          errors={["can't be blank"]}
        />
        """)

      assert html =~ "id=\"name-help\""
      assert html =~ "id=\"name-error\""
      assert html =~ ~r/aria-describedby="name-help name-error"/
    end

    test "error container owns a stable id and visible text" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input id="name" name="name" label="Name" errors={["can't be blank"]} />
        """)

      assert html =~ "id=\"name-error\""
      assert html =~ "can&#39;t be blank"
      assert html =~ ~r/aria-describedby="name-error"/
      refute html =~ "role=\"alert\""
      refute html =~ "aria-live"
    end

    test "sets aria-invalid when errors exist and clears it otherwise" do
      assigns = %{}

      valid =
        rendered_to_string(~H"""
        <.input id="name" name="name" label="Name" />
        """)

      refute valid =~ ~r/aria-invalid="true"/

      invalid =
        rendered_to_string(~H"""
        <.input id="name" name="name" label="Name" errors={["can't be blank"]} />
        """)

      assert invalid =~ ~r/aria-invalid="true"/
    end

    test "select and textarea inputs expose the same error association contract" do
      assigns = %{}

      select_html =
        rendered_to_string(~H"""
        <.input
          id="role"
          name="role"
          type="select"
          label="Role"
          options={[{"Admin", "admin"}]}
          errors={["is invalid"]}
        />
        """)

      textarea_html =
        rendered_to_string(~H"""
        <.input id="notes" name="notes" type="textarea" label="Notes" errors={["is invalid"]} />
        """)

      assert select_html =~ "id=\"role-error\""
      assert select_html =~ ~r/aria-invalid="true"/
      assert select_html =~ ~r/aria-describedby="role-error"/
      refute select_html =~ "role=\"alert\""
      refute select_html =~ "aria-live"

      assert textarea_html =~ "id=\"notes-error\""
      assert textarea_html =~ ~r/aria-invalid="true"/
      assert textarea_html =~ ~r/aria-describedby="notes-error"/
      refute textarea_html =~ "role=\"alert\""
      refute textarea_html =~ "aria-live"
    end

    test "multiple errors render inside one referenced container" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input id="name" name="name" label="Name" errors={["can't be blank", "too short"]} />
        """)

      # Both messages render inside exactly one alert container.
      assert html =~ ~r/<p id="name-error"/
      assert length(Regex.scan(~r/<p id="name-error"/, html)) == 1
      assert html =~ "can&#39;t be blank"
      assert html =~ "too short"
    end
  end
end
