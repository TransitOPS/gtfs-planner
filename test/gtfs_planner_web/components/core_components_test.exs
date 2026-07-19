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

    test "error container owns a stable id and alert semantics" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input id="name" name="name" label="Name" errors={["can't be blank"]} />
        """)

      assert html =~ "id=\"name-error\""
      assert html =~ ~r/role="alert"/
      assert html =~ ~r/aria-live="assertive"/
      assert html =~ ~r/aria-describedby="name-error"/
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
      assert select_html =~ ~r/role="alert"/
      assert select_html =~ ~r/aria-describedby="role-error"/

      assert textarea_html =~ "id=\"notes-error\""
      assert textarea_html =~ ~r/aria-invalid="true"/
      assert textarea_html =~ ~r/role="alert"/
      assert textarea_html =~ ~r/aria-describedby="notes-error"/
    end

    test "keeps alert semantics when announce_errors is explicitly true" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          id="name"
          name="name"
          label="Name"
          errors={["can't be blank"]}
          announce_errors={true}
        />
        """)

      assert html =~ "id=\"name-error\""
      assert html =~ ~r/role="alert"/
      assert html =~ ~r/aria-live="assertive"/
      assert html =~ ~r/aria-describedby="name-error"/
    end

    test "announce_errors={false} omits only the live-region attributes" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.input
          id="name"
          name="name"
          label="Name"
          errors={["can't be blank"]}
          announce_errors={false}
        />
        """)

      refute html =~ "role=\"alert\""
      refute html =~ "aria-live"
      assert html =~ "id=\"name-error\""
      assert html =~ ~r/aria-invalid="true"/
      assert html =~ ~r/aria-describedby="name-error"/
      assert html =~ "can&#39;t be blank"
    end

    test "checkbox, select, and textarea clauses honor announce_errors={false}" do
      assigns = %{}

      checkbox_html =
        rendered_to_string(~H"""
        <.input
          id="active"
          name="active"
          type="checkbox"
          label="Active"
          errors={["is invalid"]}
          announce_errors={false}
        />
        """)

      select_html =
        rendered_to_string(~H"""
        <.input
          id="role"
          name="role"
          type="select"
          label="Role"
          options={[{"Admin", "admin"}]}
          errors={["is invalid"]}
          announce_errors={false}
        />
        """)

      textarea_html =
        rendered_to_string(~H"""
        <.input
          id="notes"
          name="notes"
          type="textarea"
          label="Notes"
          errors={["is invalid"]}
          announce_errors={false}
        />
        """)

      refute checkbox_html =~ "role=\"alert\""
      refute checkbox_html =~ "aria-live"
      assert checkbox_html =~ "id=\"active-error\""
      assert checkbox_html =~ ~r/aria-describedby="active-error"/

      refute select_html =~ "role=\"alert\""
      refute select_html =~ "aria-live"
      assert select_html =~ "id=\"role-error\""
      assert select_html =~ ~r/aria-describedby="role-error"/

      refute textarea_html =~ "role=\"alert\""
      refute textarea_html =~ "aria-live"
      assert textarea_html =~ "id=\"notes-error\""
      assert textarea_html =~ ~r/aria-describedby="notes-error"/
    end

    test "multiple errors render inside one referenced alert container" do
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
