defmodule GtfsPlannerWeb.Gtfs.RoutePatternLeftOutTest do
  @moduledoc """
  The Patterns tab's card for the trips import left outside patterns: one row per
  derivation reason with the fix that reason can have here, the grouping review as
  the view's only primary action, and the raw codes under Technical details.

  The counts are the ones `BROWSER_SHAPES` seeds in the browser suite, so this
  file asserts the same 24 / 2 / 1 the visual step captures.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  defp scope(%{conn: conn}, roles) do
    organization =
      organization_fixture(%{alias: "left-out-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "left-out-#{System.unique_integer([:positive])}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: roles
      })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp editor_scope(context), do: scope(context, ["pathways_studio_editor"])

  defp route(organization, version, route_id) do
    route_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_short_name: route_id,
      route_long_name: "#{route_id} corridor"
    })
  end

  defp stops(organization, version, route_id, count) do
    for index <- 1..count do
      stop_fixture(organization.id, version.id, %{
        stop_id: "#{route_id}_S#{index}",
        stop_name: "#{route_id} Stop #{index}",
        location_type: 0
      })
    end
  end

  defp saved_pattern(organization, version, route, route_pattern_id, stop_rows) do
    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: route_pattern_id,
        route_pattern_name: "Full route",
        direction_id: 0
      })

    Enum.each(stop_rows, fn {stop, position} ->
      route_pattern_stop_fixture(pattern, stop.stop_id, position)
    end)

    pattern
  end

  # Trips import left outside patterns are stored the way import and derivation
  # leave them: `custom` with the reason that classified them.
  defp left_out_trips(organization, version, route, prefix, count, reason) do
    for index <- 1..count do
      organization.id
      |> trip_fixture(version.id, route.route_id, %{
        trip_id: "#{prefix}#{index}",
        direction_id: 0
      })
      |> then(
        &trip_pattern_metadata_fixture(&1, %{
          pattern_derivation_state: "custom",
          pattern_derivation_reason: reason
        })
      )
    end
  end

  defp pending_trip(organization, version, route, trip_id, stop_rows) do
    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: trip_id,
        direction_id: 0
      })

    Enum.each(stop_rows, fn {stop, {sequence, time}} ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, stop.stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end)

    trip
  end

  # A route the seed's shape describes: one saved pattern, and 24 trips with no
  # direction, 2 with times out of order and 1 serving only a station.
  defp left_out_route(organization, version, route_id) do
    route = route(organization, version, route_id)
    stop_rows = stops(organization, version, route_id, 3)
    saved_pattern(organization, version, route, "#{route_id}-A", Enum.with_index(stop_rows, 1))

    left_out_trips(organization, version, route, "DIR#{route_id}", 24, "missing_direction")
    left_out_trips(organization, version, route, "CHR#{route_id}", 2, "invalid_chronology")
    left_out_trips(organization, version, route, "STA#{route_id}", 1, "unusable_stops")

    route
  end

  defp primary_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#route-patterns-page a.btn-primary")
    |> Enum.count()
  end

  defp patterns_path(version, route),
    do: "/gtfs/#{version.id}/routes/#{route.route_id}/patterns"

  defp text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "the left-out card" do
    setup :editor_scope

    test "names every reason with its count and the fix it can have here",
         %{conn: conn, organization: organization, version: version} do
      route = left_out_route(organization, version, "LEFT1")

      {:ok, view, html} = live(conn, patterns_path(version, route))

      assert text(html, "#patterns-left-out-title") == "27 trips aren’t in a pattern"
      assert text(html, "#patterns-left-out-missing_direction") =~ "24 trips have no direction"

      assert text(html, "#patterns-left-out-invalid_chronology") =~
               "2 trips have times out of order"

      assert text(html, "#patterns-left-out-unusable_stops") =~
               "1 trip serves a station, not a boarding stop"

      assert text(html, "#patterns-left-out-invalid_chronology") =~ "source feed"

      # The list still reads as a list: the card sits above it, not instead of it.
      assert has_element?(view, "#patterns-list-container")
    end

    test "offers the grouping review as the only primary action",
         %{conn: conn, organization: organization, version: version} do
      route = left_out_route(organization, version, "LEFT2")

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(
               view,
               "#patterns-left-out-group[href='/gtfs/#{version.id}/routes/#{route.route_id}/patterns?review=group'].btn-primary",
               "Group 24 trips"
             )

      assert has_element?(
               view,
               "#patterns-left-out-invalid_chronology-trips.btn-outline",
               "View trips"
             )

      assert has_element?(
               view,
               "#patterns-left-out-unusable_stops-trips.btn-outline",
               "View trip"
             )

      # One primary per view: creating a pattern steps back to secondary beside it.
      assert has_element?(view, "#patterns-create.btn-outline")
      assert primary_count(view) == 1
    end

    test "discloses the raw derivation codes under technical details",
         %{conn: conn, organization: organization, version: version} do
      route = left_out_route(organization, version, "LEFT3")

      {:ok, _view, html} = live(conn, patterns_path(version, route))

      codes = text(html, "#patterns-left-out-codes")

      assert codes =~ "Technical details"
      assert codes =~ "missing_direction"
      assert codes =~ "invalid_chronology"
      assert codes =~ "unusable_stops"
    end

    test "no copy offers a fix in Schedules; every fix names a re-import",
         %{conn: conn, organization: organization, version: version} do
      route = left_out_route(organization, version, "LEFT4")

      {:ok, _view, html} = live(conn, patterns_path(version, route))

      card = text(html, "#patterns-left-out")

      refute card =~ "in Schedules"
      refute card =~ "on the Schedules tab"
      assert card =~ "re-import"
      assert card =~ "source feed"
    end

    test "a route with only pending trips keeps the build state and shows no card",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "LEFT5")
      stop_rows = stops(organization, version, "LEFT5", 3)

      pending_trip(organization, version, route, "LEFT5_P1", [
        {Enum.at(stop_rows, 0), {1, "08:00:00"}},
        {Enum.at(stop_rows, 1), {2, "08:10:00"}},
        {Enum.at(stop_rows, 2), {3, "08:20:00"}}
      ])

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-unlinked", "Group your trips into patterns")
      assert has_element?(view, "#patterns-build", "Build patterns from trips")
      refute has_element?(view, "#patterns-left-out")
      refute has_element?(view, "#patterns-left-out-group")
    end

    test "a route with no trips at all shows no card", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route = route(organization, version, "LEFT6")

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-empty", "Add the first pattern")
      refute has_element?(view, "#patterns-left-out")
    end
  end

  # A viewer without the editor role never reaches this route at all, so the
  # read-only case is the one production path that renders the Patterns tab
  # without editing: an editor whose role is removed while the page is open.
  describe "without editing access" do
    setup :editor_scope

    test "reads why the trips are there and is offered no action", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      route = left_out_route(organization, version, "LEFT7")

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      render_click(view, "reload_patterns")

      assert has_element?(view, "#pattern-editor-revoked")
      assert has_element?(view, "#patterns-left-out-title", "27 trips aren\u2019t in a pattern")
      assert has_element?(view, "#patterns-left-out-codes")
      refute has_element?(view, "#patterns-left-out-group")
      refute has_element?(view, "#patterns-left-out-invalid_chronology-trips")
      refute has_element?(view, "#patterns-create")
    end
  end
end
