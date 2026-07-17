defmodule GtfsPlannerWeb.CoreComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import GtfsPlannerWeb.CoreComponents

  describe "drawer/1" do
    test "renders with open: false and has translate-x-full class" do
      assigns = %{open: false}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} on_close="close">
          <p>Drawer content</p>
        </.drawer>
        """)

      assert html =~ "translate-x-full"
      assert html =~ "id=\"test-drawer\""
      assert html =~ "Drawer content"
    end

    test "renders with open: true and has translate-x-0 class" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} on_close="close">
          <p>Drawer content</p>
        </.drawer>
        """)

      assert html =~ "translate-x-0"
      refute html =~ "translate-x-full"
      assert html =~ "id=\"test-drawer\""
    end

    test "renders title when provided" do
      assigns = %{open: true, title: "Test Title"}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} on_close="close" title={@title}>
          <p>Drawer content</p>
        </.drawer>
        """)

      assert html =~ "Test Title"
    end

    test "renders inner_block content" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} on_close="close">
          <p>Custom drawer content</p>
          <div class="custom-class">More content</div>
        </.drawer>
        """)

      assert html =~ "Custom drawer content"
      assert html =~ "More content"
      assert html =~ "custom-class"
    end

    test "uses custom on_close event name" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} on_close="custom_close_event">
          <p>Content</p>
        </.drawer>
        """)

      assert html =~ "phx-click=\"custom_close_event\""
    end

    test "renders close button with aria-label" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} on_close="close">
          <p>Content</p>
        </.drawer>
        """)

      assert html =~ "aria-label"
      assert html =~ "hero-x-mark"
    end

    test "overlay has correct z-index and opacity classes" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} on_close="close">
          <p>Content</p>
        </.drawer>
        """)

      assert html =~ "z-40"
      assert html =~ "opacity-100"
    end

    test "drawer panel has correct z-index" do
      assigns = %{open: true}

      html =
        rendered_to_string(~H"""
        <.drawer id="test-drawer" open={@open} on_close="close">
          <p>Content</p>
        </.drawer>
        """)

      assert html =~ "z-50"
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
        <.input id="name" name="name" label="Name" help="Pick a memorable name" errors={["can't be blank"]} />
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
        <.input id="role" name="role" type="select" label="Role" options={[{"Admin", "admin"}]} errors={["is invalid"]} />
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
