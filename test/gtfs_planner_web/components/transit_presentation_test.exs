defmodule GtfsPlannerWeb.Components.TransitPresentationTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Components.TransitPresentation

  describe "accessibility_status/1" do
    test "renders all three accessibility states without transforming the source value" do
      for {status, label} <- [
            {:accessible, "Accessible"},
            {:not_accessible, "Not accessible"},
            {:unknown, "No data"}
          ] do
        assigns = %{status: status}

        html =
          rendered_to_string(~H"""
          <TransitPresentation.accessibility_status status={@status} />
          """)

        assert html =~ ~s(data-accessibility="#{status}")
        assert html =~ label
      end
    end

    test "renders No data for the stable :unknown atom" do
      assigns = %{status: :unknown}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.accessibility_status status={@status} />
        """)

      assert html =~ ~s(data-accessibility="unknown")
      assert html =~ "No data"
      refute html =~ "Accessibility unknown"
    end

    test "does not render inheritance disclosure for the default direct source" do
      assigns = %{status: :accessible}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.accessibility_status status={@status} />
        """)

      refute html =~ "Inherited from station"
      refute html =~ ~s(data-accessibility-source="inherited")
    end

    test "renders adjacent source text when the value is inherited" do
      assigns = %{status: :accessible}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.accessibility_status status={@status} source={:inherited} />
        """)

      assert html =~ "Accessible"
      assert html =~ "Inherited from station"
      assert html =~ ~s(data-accessibility-source="inherited")
    end

    test "renders No data without inheritance disclosure for a missing source" do
      assigns = %{status: :unknown}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.accessibility_status status={@status} source={:missing} />
        """)

      assert html =~ "No data"
      refute html =~ "Inherited from station"
    end
  end

  describe "pathway_summary/1" do
    test "renders mode, textual direction, and supplied metrics with mono/tabular values" do
      assigns = %{
        pathway: %{
          pathway_mode: 2,
          is_bidirectional: false,
          stair_count: 24,
          length: Decimal.new("18.5"),
          traversal_time: 32
        }
      }

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ "Stairs"
      assert html =~ "One way"
      assert html =~ "font-mono"
      assert html =~ "tabular-nums"
      assert html =~ ">24<"
      assert html =~ ">stairs<"
      assert html =~ ">18.5<"
      assert html =~ ">m<"
      assert html =~ ">32<"
      assert html =~ ">sec<"
    end

    test "renders bidirectional direction as text" do
      assigns = %{pathway: %{pathway_mode: 1, is_bidirectional: true}}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ "Walkway"
      assert html =~ "Bidirectional"
    end

    test "renders duration in seconds as a natural unit" do
      assigns = %{pathway: %{pathway_mode: 3, is_bidirectional: true, traversal_time: 45}}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ ">45<"
      assert html =~ ">sec<"
    end

    test "omits stair metrics that do not apply to the pathway mode" do
      assigns = %{
        pathway: %{pathway_mode: 5, is_bidirectional: true, stair_count: 24, traversal_time: nil}
      }

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ "Elevator"
      assert html =~ "Bidirectional"
      refute html =~ ">stairs<"
      refute html =~ ">24<"
    end

    test "omits absent length and duration metrics" do
      assigns = %{
        pathway: %{
          pathway_mode: 2,
          is_bidirectional: false,
          stair_count: 12,
          length: nil,
          traversal_time: nil
        }
      }

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ ">12<"
      assert html =~ ">stairs<"
      refute html =~ ">m<"
      refute html =~ ">sec<"
    end
  end
end
