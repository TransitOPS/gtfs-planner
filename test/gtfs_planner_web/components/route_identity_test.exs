defmodule GtfsPlannerWeb.Components.RouteIdentityTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Components.RouteIdentity

  describe "normalize_hex/1" do
    test "accepts six-digit uppercase hex without hash" do
      assert {:ok, "D32F2F"} = RouteIdentity.normalize_hex("D32F2F")
    end

    test "accepts six-digit lowercase hex without hash" do
      assert {:ok, "D32F2F"} = RouteIdentity.normalize_hex("d32f2f")
    end

    test "accepts mixed-case six-digit hex without hash" do
      assert {:ok, "1A2B3C"} = RouteIdentity.normalize_hex("1a2B3c")
    end

    test "accepts six-digit hex with leading hash" do
      assert {:ok, "FFFFFF"} = RouteIdentity.normalize_hex("#FFFFFF")
    end

    test "accepts lowercase hex with leading hash" do
      assert {:ok, "000000"} = RouteIdentity.normalize_hex("#000000")
    end

    test "rejects nil" do
      assert :error = RouteIdentity.normalize_hex(nil)
    end

    test "rejects non-string values" do
      assert :error = RouteIdentity.normalize_hex(123_456)
      assert :error = RouteIdentity.normalize_hex(:D32F2F)
      assert :error = RouteIdentity.normalize_hex(%{})
      assert :error = RouteIdentity.normalize_hex([])
    end

    test "rejects empty string" do
      assert :error = RouteIdentity.normalize_hex("")
    end

    test "rejects wrong-length values" do
      assert :error = RouteIdentity.normalize_hex("FFF")
      assert :error = RouteIdentity.normalize_hex("FFFFFFFF")
      assert :error = RouteIdentity.normalize_hex("#FFF")
    end

    test "rejects non-hex characters" do
      assert :error = RouteIdentity.normalize_hex("GGGGGG")
      assert :error = RouteIdentity.normalize_hex("ZZZZZZ")
      assert :error = RouteIdentity.normalize_hex("12345G")
    end

    test "rejects blank strings" do
      assert :error = RouteIdentity.normalize_hex("   ")
    end
  end

  describe "contrast_ratio/2" do
    test "black on white yields 21:1" do
      ratio = RouteIdentity.contrast_ratio("FFFFFF", "000000")
      assert_in_delta ratio, 21.0, 0.1
    end

    test "white on black yields 21:1" do
      ratio = RouteIdentity.contrast_ratio("000000", "FFFFFF")
      assert_in_delta ratio, 21.0, 0.1
    end

    test "same color yields 1:1" do
      ratio = RouteIdentity.contrast_ratio("808080", "808080")
      assert_in_delta ratio, 1.0, 0.01
    end

    test "the 4.5:1 boundary is respected" do
      ratio = RouteIdentity.contrast_ratio("767676", "FFFFFF")
      assert ratio >= 4.5

      ratio = RouteIdentity.contrast_ratio("757575", "FFFFFF")
      assert ratio >= 4.5
    end

    test "a low-contrast pair falls below 4.5:1" do
      ratio = RouteIdentity.contrast_ratio("808080", "999999")
      assert ratio < 4.5
    end
  end

  describe "route_badge/1" do
    test "renders valid background and foreground with inline style" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{route_color: "D32F2F", route_text_color: "FFFFFF", route_short_name: "42"}
        } />
        """)

      assert html =~ "background-color: #D32F2F"
      assert html =~ "color: #FFFFFF"
      assert html =~ "42"
    end

    test "corrects low-contrast foreground to higher-contrast choice" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{route_color: "FFFF00", route_text_color: "FFFFFF", route_short_name: "X"}
        } />
        """)

      assert html =~ "background-color: #FFFF00"
      assert html =~ "color: #000000"
      refute html =~ "color: #FFFFFF"
    end

    test "retains supplied foreground at 4.5:1 or better" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{route_color: "1A1A1A", route_text_color: "FFFFFF", route_short_name: "Y"}
        } />
        """)

      assert html =~ "background-color: #1A1A1A"
      assert html =~ "color: #FFFFFF"
    end

    test "renders neutral treatment for invalid background" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{route_color: "ZZZZZZ", route_text_color: "FFFFFF", route_short_name: "Z"}
        } />
        """)

      refute html =~ "background-color"
      refute html =~ "style="
      assert html =~ "Z"
    end

    test "renders neutral treatment for missing background" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{route_color: nil, route_text_color: "FFFFFF", route_short_name: "W"}
        } />
        """)

      refute html =~ "style="
      assert html =~ "W"
    end

    test "falls back from short name to route ID" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{
            route_color: "D32F2F",
            route_text_color: "FFFFFF",
            route_short_name: nil,
            route_id: "R-100"
          }
        } />
        """)

      assert html =~ "R-100"
    end

    test "falls back to Unknown route when no name or ID" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{route_color: "D32F2F", route_text_color: "FFFFFF", route_short_name: nil}
        } />
        """)

      assert html =~ "Unknown route"
    end

    test "treats blank short name as missing" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{
            route_color: "D32F2F",
            route_text_color: "FFFFFF",
            route_short_name: "  ",
            route_id: "R-200"
          }
        } />
        """)

      assert html =~ "R-200"
    end

    test "never interpolates invalid color into style" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <RouteIdentity.route_badge route={
          %{route_color: "abc", route_text_color: "FFFFFF", route_short_name: "Q"}
        } />
        """)

      refute html =~ "style="
      refute html =~ "abc"
    end
  end
end
