defmodule GtfsPlannerWeb.Gtfs.RoutePatternMapLineCopyTest do
  @moduledoc """
  Step 36 / EV-35 / AC-28 / CR-10: the workspace says "Map line" where it used
  to say "Alignment", while `task=alignment`, the element ids, the event names
  and the route paths keep their names.

  Every assertion enters through `live(conn, "...?task=alignment")`, so the
  rendered page is the production one: the tab text, the absence of the old
  wording in the rendered task, and a task switch that still lands on
  `#alignment-task` with a working `switch_task` event.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "map-line-copy-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "map-line-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  # A route with one three-stop pattern, so the alignment task renders its
  # shell without needing a drawn path.
  defp pattern_context(organization, version, route_id) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: route_id,
        route_short_name: route_id,
        route_long_name: "#{route_id} corridor"
      })

    stops =
      for index <- 1..3 do
        stop_fixture(organization.id, version.id, %{
          stop_id: "#{route_id}_S#{index}",
          stop_name: "#{route_id} Stop #{index}",
          stop_lat: Decimal.new("40.71#{index}00"),
          stop_lon: Decimal.new("-74.00#{index}00"),
          location_type: 0
        })
      end

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "P-#{route_id}",
        route_pattern_name: "Pattern #{route_id}",
        headsign: "Harbor",
        direction_id: 0
      })

    stops
    |> Enum.with_index(1)
    |> Enum.each(fn {stop, position} ->
      route_pattern_stop_fixture(pattern, stop.stop_id, position)
    end)

    %{route: route, pattern: pattern, stops: stops}
  end

  defp pattern_path(version, %{route: route, pattern: pattern}, suffix) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}#{suffix}"
  end

  describe "the Map line copy" do
    setup :editor_scope

    test "the alignment tab reads Map line",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "MAPLINE1")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=stops"))

      assert has_element?(view, "#pattern-tabs #pattern-task-alignment", "Map line")
    end

    test "the rendered alignment task says no Alignment",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "MAPLINE2")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=alignment"))

      assert has_element?(view, "#alignment-task")

      # Visible text only: `phx-hook="PatternAlignment"` is an internal name
      # CR-10 keeps, so the assertion reads the rendered text nodes.
      text =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      refute text =~ "Alignment", "the alignment task still shows the old wording"
    end

    test "?task=alignment still selects the tab and the ids and events work",
         %{conn: conn, organization: organization, version: version} do
      context = pattern_context(organization, version, "MAPLINE3")

      {:ok, view, _html} = live(conn, pattern_path(version, context, "?task=alignment"))

      assert has_element?(view, "#pattern-task-alignment[aria-current='page']", "Map line")
      assert has_element?(view, "#alignment-title")
      assert has_element?(view, "#pattern-save-bar #alignment-save", "Save map line")

      # `switch_task` still moves between tasks, and the alignment task keeps
      # its own ids on the way back.
      view
      |> element("#pattern-task-stops")
      |> render_click()

      refute has_element?(view, "#alignment-task")
      assert has_element?(view, "#pattern-task-stops[aria-current='page']")

      view
      |> element("#pattern-task-alignment")
      |> render_click()

      assert has_element?(view, "#alignment-task")
      assert has_element?(view, "#pattern-task-alignment[aria-current='page']", "Map line")
    end
  end
end
