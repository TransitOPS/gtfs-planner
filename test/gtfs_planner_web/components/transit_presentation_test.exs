defmodule GtfsPlannerWeb.Components.TransitPresentationTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Components.TransitPresentation

  test "renders all three accessibility states without transforming the source value" do
    for {status, label} <- [
          {:accessible, "Accessible"},
          {:not_accessible, "Not accessible"},
          {:unknown, "Accessibility unknown"}
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

  test "renders a compact pathway summary with direction and applicable metrics" do
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
    assert html =~ "24 stairs"
    assert html =~ "18.5 m"
    assert html =~ "32 sec"
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
    refute html =~ "24 stairs"
  end
end
