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

  @crumb_route %{
    route_id: "R1",
    route_short_name: "1",
    route_long_name: "Coast Highway",
    route_color: "1F5FBF",
    route_text_color: "FFFFFF"
  }

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

    test "shows a pattern count on the Patterns tab only when given one" do
      assigns = %{route: route(%{})}

      counted =
        rendered_to_string(~H"""
        <.route_header route={@route} gtfs_version_id="v1" active_tab={:schedules} pattern_count={3} />
        """)

      assert doc(counted) |> LazyHTML.query("#route-tab-patterns-count") |> LazyHTML.text() =~ "3"

      assert doc(render_header(route(%{})))
             |> LazyHTML.query("#route-tab-patterns-count")
             |> Enum.empty?()
    end

    test "draws only the way back while the route has not loaded" do
      assigns = %{}

      idle =
        rendered_to_string(~H"""
        <.route_header route={nil} gtfs_version_id="v1" />
        """)

      loading =
        rendered_to_string(~H"""
        <.route_header route={nil} gtfs_version_id="v1" loading />
        """)

      assert doc(idle) |> LazyHTML.query("#route-back") |> Enum.count() == 1

      assert doc(idle)
             |> LazyHTML.query("h1, #route-tabs, #route-workspace-loading")
             |> Enum.empty?()

      assert doc(loading) |> LazyHTML.query("#route-workspace-loading") |> Enum.count() == 1
      assert doc(loading) |> LazyHTML.query("h1, #route-tabs") |> Enum.empty?()
    end

    test "shows an Inactive chip only for an inactive route" do
      active = render_header(route(%{}))
      inactive = render_header(route(%{active: false}))

      assert doc(active) |> LazyHTML.query("#route-inactive") |> Enum.count() == 0
      assert doc(inactive) |> LazyHTML.query("#route-inactive") |> LazyHTML.text() =~ "Inactive"
    end
  end

  describe "badge/1" do
    test "puts the state in words on the tone's ground" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.badge id="state" tone="warning">Unsaved changes</.badge>
        """)

      badge = doc(html) |> LazyHTML.query("#state")

      assert LazyHTML.text(badge) |> String.trim() == "Unsaved changes"
      assert LazyHTML.attribute(badge, "class") |> hd() =~ "bg-warning-bg"
    end

    test "shows its icon before the text and only when one is given" do
      assigns = %{}

      with_icon =
        rendered_to_string(~H"""
        <.badge id="with" tone="success" icon="hero-check-circle">Saved</.badge>
        """)

      without_icon =
        rendered_to_string(~H"""
        <.badge id="without" tone="neutral">Draft</.badge>
        """)

      assert Enum.count(doc(with_icon) |> LazyHTML.query("#with .hero-check-circle")) == 1
      assert Enum.empty?(doc(without_icon) |> LazyHTML.query("#without [class*='hero-']"))
    end
  end

  describe "crumbs/1" do
    test "leads with Routes, this route's badge and name, the section and the page" do
      assigns = %{route: @crumb_route}

      html =
        rendered_to_string(~H"""
        <.crumbs id="trail" route={@route} gtfs_version_id="v1" current="Night owl" />
        """)

      trail = doc(html) |> LazyHTML.query("#trail")
      hrefs = LazyHTML.query(trail, "a") |> LazyHTML.attribute("href")

      assert hrefs == ["/gtfs/v1/routes", "/gtfs/v1/routes/R1", "/gtfs/v1/routes/R1/patterns"]
      assert LazyHTML.text(trail) =~ "Coast Highway"
      assert LazyHTML.text(trail) =~ "Patterns"

      assert LazyHTML.attribute(LazyHTML.query(trail, "[aria-current='page']"), "aria-current") ==
               ["page"]

      assert LazyHTML.text(LazyHTML.query(trail, "[aria-current='page']")) =~ "Night owl"
    end

    test "lets a page replace the section link with its own control" do
      assigns = %{route: @crumb_route}

      html =
        rendered_to_string(~H"""
        <.crumbs id="trail" route={@route} gtfs_version_id="v1" current="Night owl">
          <:section><button id="guarded-back" type="button">Patterns</button></:section>
        </.crumbs>
        """)

      trail = doc(html) |> LazyHTML.query("#trail")

      assert Enum.count(LazyHTML.query(trail, "#guarded-back")) == 1

      refute LazyHTML.query(trail, "a")
             |> LazyHTML.attribute("href")
             |> Enum.member?("/gtfs/v1/routes/R1/patterns")
    end

    test "falls back to the route id when the route has no names" do
      assigns = %{
        route: %{route_id: "R9", route_short_name: nil, route_long_name: nil, route_color: nil}
      }

      html =
        rendered_to_string(~H"""
        <.crumbs id="trail" route={@route} gtfs_version_id="v1" current="New pattern" />
        """)

      assert doc(html) |> LazyHTML.query("#trail") |> LazyHTML.text() =~ "R9"
    end
  end
end
