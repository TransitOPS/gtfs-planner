defmodule GtfsPlannerWeb.RouteWorkspaceTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  import GtfsPlannerWeb.RouteWorkspace

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp route(attrs) do
    Enum.into(attrs, %{
      route_id: "R12",
      route_short_name: "12",
      route_long_name: "Nye Beach – Hospital",
      route_type: 3,
      route_color: "1F5FBF",
      route_text_color: "FFFFFF",
      active: true
    })
  end

  defp render_header(route, active_tab \\ :details) do
    assigns = %{route: route, active_tab: active_tab}

    rendered_to_string(~H"""
    <.route_header route={@route} gtfs_version_id="v1" active_tab={@active_tab} />
    """)
  end

  describe "route_title/1" do
    test "is the long name when the feed gives one" do
      assert route_title(route(%{})) == "Nye Beach – Hospital"
    end

    test "reads Route and the short name when there is no long name" do
      assert route_title(route(%{route_long_name: nil})) == "Route 12"
    end

    test "treats a blank long name as missing" do
      assert route_title(route(%{route_long_name: "  "})) == "Route 12"
    end

    test "reads Route and the route ID when there is no name at all" do
      assert route_title(route(%{route_long_name: nil, route_short_name: nil})) == "Route R12"
    end
  end

  describe "route_label/1" do
    test "names a route by its short name" do
      assert route_label(route(%{})) == "Route 12"
    end

    test "names a route without a short name by its route ID" do
      assert route_label(route(%{route_short_name: ""})) == "Route R12"
    end
  end

  describe "mode_label/1" do
    test "puts a mode in sentence case and spells out a slash" do
      assert mode_label(0) == "Tram or light rail"
      assert mode_label(1) == "Subway or metro"
      assert mode_label(5) == "Cable tram"
    end

    test "leaves a single-word mode as a word" do
      assert mode_label(3) == "Bus"
    end

    test "reads an unknown type as Unknown" do
      assert mode_label(nil) == "Unknown"
    end
  end

  describe "route_header/1" do
    test "leads with a way back, the name as the one h1, and the route ID" do
      html = render_header(route(%{}))

      assert doc(html) |> LazyHTML.query("h1") |> Enum.count() == 1

      assert doc(html) |> LazyHTML.query("h1#route-title") |> LazyHTML.text() =~
               "Nye Beach – Hospital"

      assert doc(html) |> LazyHTML.query("#route-back") |> LazyHTML.attribute("href") == [
               "/gtfs/v1/routes"
             ]

      assert doc(html) |> LazyHTML.query("#route-identifier") |> LazyHTML.text() =~ "Route ID R12"
    end

    test "marks only the current tab and links each tab to its page" do
      html = render_header(route(%{}), :patterns)
      tabs = doc(html) |> LazyHTML.query("nav[aria-label='Route navigation']")

      assert LazyHTML.attribute(LazyHTML.query(tabs, "#route-tab-details"), "href") == [
               "/gtfs/v1/routes/R12"
             ]

      assert LazyHTML.attribute(LazyHTML.query(tabs, "#route-tab-patterns"), "href") == [
               "/gtfs/v1/routes/R12/patterns"
             ]

      assert LazyHTML.attribute(LazyHTML.query(tabs, "#route-tab-schedules"), "href") == [
               "/gtfs/v1/routes/R12/schedules"
             ]

      assert LazyHTML.attribute(LazyHTML.query(tabs, "[aria-current]"), "id") == [
               "route-tab-patterns"
             ]
    end

    test "shows an Inactive chip only for an inactive route" do
      active = render_header(route(%{}))
      inactive = render_header(route(%{active: false}))

      assert doc(active) |> LazyHTML.query("#route-inactive") |> Enum.count() == 0
      assert doc(inactive) |> LazyHTML.query("#route-inactive") |> LazyHTML.text() =~ "Inactive"
    end
  end
end
