defmodule GtfsPlannerWeb.Components.FeedbackComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  import GtfsPlannerWeb.CoreComponents

  describe "flash/1 close-only dismissal" do
    test "close button has phx-click and 44px target" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.flash kind={:info} id="test-flash">Test message</.flash>
        """)

      doc = LazyHTML.from_fragment(html)
      close_btn = LazyHTML.query(doc, "button[aria-label='Dismiss message']")
      assert Enum.count(close_btn) == 1
      assert LazyHTML.attribute(close_btn, "phx-click") |> Enum.any?()

      classes = LazyHTML.attribute(close_btn, "class") |> List.first()
      assert classes =~ "min-h-11"
      assert classes =~ "min-w-11"
    end

    test "flash root has no phx-click" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.flash kind={:info} id="test-flash">Test message</.flash>
        """)

      doc = LazyHTML.from_fragment(html)
      root = LazyHTML.query(doc, "#test-flash")
      assert LazyHTML.attribute(root, "phx-click") == []
    end

    test "flash has no role=alert" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.flash kind={:info} id="test-flash">Test message</.flash>
        """)

      doc = LazyHTML.from_fragment(html)
      root = LazyHTML.query(doc, "#test-flash")
      assert LazyHTML.attribute(root, "role") == []
    end
  end

  describe "skeleton/1 visible label" do
    test "label is visually available, not screen-reader only" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.skeleton rows={3} label="Loading routes" />
        """)

      assert html =~ "Loading routes"
      doc = LazyHTML.from_fragment(html)
      label = LazyHTML.query(doc, "p")
      assert Enum.count(label) == 1
      classes = LazyHTML.attribute(label, "class") |> List.first()
      refute classes =~ "sr-only"
    end

    test "skeleton has no role=status" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.skeleton rows={3} label="Loading" />
        """)

      doc = LazyHTML.from_fragment(html)
      assert Enum.empty?(LazyHTML.query(doc, "[role='status']"))
    end
  end

  describe "status_badge/1 explicit vocabulary" do
    test "renders known status with explicit label and tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:pass} />
        """)

      assert html =~ "Pass"
      assert html =~ "text-success"
    end

    test "renders completed as success" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:completed} />
        """)

      assert html =~ "Completed"
      assert html =~ "text-success"
    end

    test "renders running with info tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:running} />
        """)

      assert html =~ "Running"
      assert html =~ "text-info"
    end

    test "renders in_progress as In progress" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:in_progress} />
        """)

      assert html =~ "In progress"
    end

    test "renders string status in_progress as In progress" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status="in_progress" />
        """)

      assert html =~ "In progress"
    end

    test "renders failed with error tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:failed} />
        """)

      assert html =~ "Failed"
      assert html =~ "text-error"
    end

    test "renders warning with warning tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:warning} />
        """)

      assert html =~ "Warning"
      assert html =~ "text-warning"
    end

    test "renders started with neutral tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:started} />
        """)

      assert html =~ "Started"
    end

    test "renders draft with neutral tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:draft} />
        """)

      assert html =~ "Draft"
    end
  end

  describe "status_badge/1 neutral unknown fallback" do
    test "renders Unknown for unrecognized atom status" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:some_new_status} />
        """)

      assert html =~ "Unknown"
      refute html =~ "Some_new_status"
      refute html =~ "Some new status"
    end

    test "renders Unknown for unrecognized string status" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status="mystery_value" />
        """)

      assert html =~ "Unknown"
      refute html =~ "Mystery_value"
      refute html =~ "Mystery value"
    end

    test "renders Unknown for blank string status" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status="" />
        """)

      assert html =~ "Unknown"
    end

    test "does not capitalize underscored machine labels" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:not_yet_started} />
        """)

      assert html =~ "Unknown"
      refute html =~ "Not_yet_started"
      refute html =~ "Not yet started"
    end

    test "label override still works" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:running} label="Building graph" />
        """)

      assert html =~ "Building graph"
    end
  end
end
