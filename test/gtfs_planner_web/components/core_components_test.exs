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
    test "renders correct range with items" do
      assigns = %{page: 1, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "Showing 1–10 of 25 routes"
      assert html =~ "Previous"
      assert html =~ "Next"
    end

    test "renders correct range on second page" do
      assigns = %{page: 2, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "Showing 11–20 of 25 routes"
    end

    test "renders correct range on last page with partial results" do
      assigns = %{page: 3, per_page: 10, total: 25}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
        """)

      assert html =~ "Showing 21–25 of 25 routes"
    end

    test "handles empty state correctly (total = 0)" do
      assigns = %{page: 1, per_page: 10, total: 0}

      html =
        rendered_to_string(~H"""
        <.pagination page={@page} per_page={@per_page} total={@total} />
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
end
