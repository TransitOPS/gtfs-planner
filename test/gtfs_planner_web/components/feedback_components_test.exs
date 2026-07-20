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

  # AC-7 / C-007: administration membership states are part of the one graduated
  # vocabulary, not a locally rebuilt badge. C-009 keeps every state colour *plus*
  # text, so the word survives a greyscale screenshot and a colourblind reader.
  describe "status_badge/1 administration vocabulary" do
    test "renders active as Active with a success tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:active} />
        """)

      assert badge_word(html) == "Active"
      assert badge_word_class(html) =~ "text-success"
      assert badge_dot_class(html) =~ "bg-success"
    end

    test "renders deactivated as Deactivated with an error tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:deactivated} />
        """)

      assert badge_word(html) == "Deactivated"
      assert badge_word_class(html) =~ "text-error"
      assert badge_dot_class(html) =~ "bg-error"
    end

    test "renders invitation_pending as Invitation pending with a warning tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:invitation_pending} />
        """)

      assert badge_word(html) == "Invitation pending"
      assert badge_word_class(html) =~ "text-warning"
      assert badge_dot_class(html) =~ "bg-warning"
    end

    test "accepts the administration statuses as strings" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status="invitation_pending" />
        """)

      assert badge_word(html) == "Invitation pending"
      refute badge_word(html) == "Unknown"
    end

    test "gives each administration status a distinct tone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:active} />
        <.status_badge status={:deactivated} />
        <.status_badge status={:invitation_pending} />
        """)

      dots =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("span[aria-hidden='true']")
        |> LazyHTML.attribute("class")

      assert Enum.count(dots) == 3
      assert dots == Enum.uniq(dots)
    end

    test "pairs every administration status with a visible word beside an aria-hidden dot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:deactivated} />
        """)

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(doc, "span[aria-hidden='true']")) == 1
      assert LazyHTML.text(LazyHTML.query(doc, "span[aria-hidden='true']")) == ""
      assert LazyHTML.text(doc) =~ "Deactivated"
    end

    test "label override still applies to an administration status" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.status_badge status={:invitation_pending} label="Awaiting first sign-in" />
        """)

      assert badge_word(html) == "Awaiting first sign-in"
      assert badge_word_class(html) =~ "text-warning"
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

  # <.status_badge> renders an aria-hidden dot span followed by a `font-medium`
  # word span. Reading the two separately keeps the assertions on the rendered
  # label and tone rather than on a raw-HTML substring.
  defp badge_word(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("span.font-medium")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp badge_word_class(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("span.font-medium")
    |> LazyHTML.attribute("class")
    |> List.first()
  end

  defp badge_dot_class(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("span[aria-hidden='true']")
    |> LazyHTML.attribute("class")
    |> List.first()
  end
end
