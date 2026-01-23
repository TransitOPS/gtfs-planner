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
end
