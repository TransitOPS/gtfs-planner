defmodule GtfsPlannerWeb.Gtfs.RouteDetailMapLinesTest do
  @moduledoc """
  The next step on every imported line of Route › Details (spec 27, step 23, EV-22).

  Each line the map draws from imported shapes offers one next step: "Edit map
  line" for the one pattern that uses it, a chooser naming every pattern that
  uses it when several do, and "Group N trips" for the trips it holds that no
  pattern covers. A route with no patterns at all still draws its imported lines
  with their grouping action instead of the empty-patterns card.

  Every case mounts the ordinary authenticated route, so the panel is rendered
  by the production composition `RouteDetailLive` -> `Gtfs.route_map/3` ->
  `GtfsPlanner.Gtfs.Routes.Map.route_map/3` over real rows.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo

  setup %{conn: conn} do
    organization =
      organization_fixture(%{alias: "map-lines-#{System.unique_integer([:positive])}"})

    user = user_fixture(%{email: "map-lines-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      organization: organization,
      version: version,
      conn: log_in_user(conn, user, organization: organization)
    }
  end

  test "a line one pattern uses offers that pattern's map line", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    route(organization, version, "LINES1")
    pattern = pattern(organization, version, "LINES1", "P1", "Newport to Lincoln City", 0)
    stops(pattern, organization, version, "L1", 2)

    linked_trip(organization, version, "LINES1", pattern, "L1_SHARED")

    shape_points(organization, version, "L1_SHARED", [
      {1, "44.60", "-124.05"},
      {2, "44.62", "-124.07"}
    ])

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/LINES1")

    assert has_element?(view, "#route-map-line-L1_SHARED-edit", "Edit map line")

    assert view |> element("#route-map-line-L1_SHARED-edit") |> render() =~
             "/gtfs/#{version.id}/routes/LINES1/patterns/P1?task=alignment"

    # Neither the chooser nor the grouping action belongs on this line.
    refute has_element?(view, "#route-map-line-L1_SHARED-choose")
    refute has_element?(view, "#route-map-line-L1_SHARED-group")
  end

  test "a line several patterns use opens a chooser naming every one of them", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    route(organization, version, "LINES2")
    first = pattern(organization, version, "LINES2", "P1", "Newport to Lincoln City", 0)
    second = pattern(organization, version, "LINES2", "P2", "Lincoln City to Newport", 1)
    stops(first, organization, version, "L2A", 2)
    stops(second, organization, version, "L2B", 3)

    linked_trip(organization, version, "LINES2", first, "L2_SHARED")
    linked_trip(organization, version, "LINES2", second, "L2_SHARED")

    shape_points(organization, version, "L2_SHARED", [
      {1, "44.60", "-124.05"},
      {2, "44.62", "-124.07"}
    ])

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/LINES2")

    assert has_element?(view, "#route-map-line-L2_SHARED-choose")
    refute has_element?(view, "#route-map-line-L2_SHARED-edit")
    refute has_element?(view, "#route-map-line-L2_SHARED-group")

    # The list is a disclosure: it is closed until the operator opens it, and
    # opening it names both patterns and where each one's map line is edited.
    refute has_element?(view, "#route-map-line-L2_SHARED-choices")

    assert view |> element("#route-map-line-L2_SHARED-choose") |> render() =~
             ~s(aria-expanded="false")

    view |> element("#route-map-line-L2_SHARED-choose") |> render_click()

    assert has_element?(view, "#route-map-line-L2_SHARED-choices")

    for route_pattern_id <- ["P1", "P2"] do
      option =
        "#route-map-line-L2_SHARED-choices a[href$='patterns/#{route_pattern_id}?task=alignment']"

      assert has_element?(view, option)
    end

    assert view |> element("#route-map-line-L2_SHARED-choices") |> render() =~
             "Newport to Lincoln City"

    assert view |> element("#route-map-line-L2_SHARED-choices") |> render() =~
             "Lincoln City to Newport"

    # The same button closes what it opened.
    view |> element("#route-map-line-L2_SHARED-choose") |> render_click()
    refute has_element?(view, "#route-map-line-L2_SHARED-choices")
  end

  test "a line with trips outside patterns offers to group exactly those trips", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    route(organization, version, "LINES3")
    pattern = pattern(organization, version, "LINES3", "P1", "Newport to Lincoln City", 0)
    stops(pattern, organization, version, "L3", 2)

    for _index <- 1..18 do
      custom_trip(organization, version, "LINES3", "L3_OUTSIDE")
    end

    shape_points(organization, version, "L3_OUTSIDE", [
      {1, "44.60", "-124.05"},
      {2, "44.62", "-124.07"}
    ])

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/LINES3")

    assert has_element?(view, "#route-map-line-L3_OUTSIDE-group", "Group 18 trips")

    assert view |> element("#route-map-line-L3_OUTSIDE-group") |> render() =~
             "/gtfs/#{version.id}/routes/LINES3/patterns?review=group"

    refute has_element?(view, "#route-map-line-L3_OUTSIDE-edit")
    refute has_element?(view, "#route-map-line-L3_OUTSIDE-choose")
  end

  test "a route with no patterns draws its imported lines and never the empty card", %{
    conn: conn,
    organization: organization,
    version: version
  } do
    route(organization, version, "LINES4")

    for {shape_id, count} <- [
          {"L4_NORTH", 26},
          {"L4_NEWPORT", 24},
          {"L4_DEPOE", 7},
          {"L4_SHORT", 7}
        ] do
      shape_points(organization, version, shape_id, [
        {1, "44.60", "-124.05"},
        {2, "44.62", "-124.07"}
      ])

      for _index <- 1..count do
        custom_trip(organization, version, "LINES4", shape_id)
      end
    end

    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/LINES4")

    # Every imported line is drawn and offers its own count, in shape-id order.
    for {shape_id, count} <- [
          {"L4_DEPOE", 7},
          {"L4_NEWPORT", 24},
          {"L4_NORTH", 26},
          {"L4_SHORT", 7}
        ] do
      assert has_element?(view, "#route-map-line-#{shape_id}-group", "Group #{count} trips")
    end

    # The map draws them, so the panel is not the "No patterns yet" dead end.
    assert has_element?(view, "#route-map")
    assert has_element?(view, "#route-map-variant-list")
    refute has_element?(view, "#route-map-first-pattern")

    # The map's text equivalent says what is actually drawn.
    assert has_element?(view, "#route-map-alt", "4 imported lines")
  end

  # -- fixtures ---------------------------------------------------------------

  defp route(organization, version, route_id) do
    route_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_short_name: route_id,
      route_long_name: "#{route_id} long name",
      route_type: 3
    })
  end

  defp pattern(organization, version, route_id, route_pattern_id, name, direction_id) do
    route_pattern_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_pattern_id: route_pattern_id,
      route_pattern_name: name,
      direction_id: direction_id
    })
  end

  defp stops(pattern, organization, version, prefix, count) do
    for index <- 1..count do
      stop_id = "#{prefix}_S#{index}"

      stop_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_lat: Decimal.new("44.#{format(60 + index)}"),
        stop_lon: Decimal.new("-124.#{format(5 + index)}")
      })

      route_pattern_stop_fixture(pattern, stop_id, index)
    end
  end

  defp format(integer) do
    integer |> Integer.to_string() |> String.pad_leading(2, "0")
  end

  # A linked trip sits on a pattern's timing, which the landed `trips` check
  # constraint requires.
  defp linked_trip(organization, version, route_id, pattern, shape_id) do
    timing = timed_pattern_fixture(pattern)

    trip =
      trip_fixture(organization.id, version.id, route_id, %{
        trip_id: "trip_#{System.unique_integer([:positive])}",
        shape_id: shape_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })
  end

  # A custom trip is outside every pattern: no pattern, no timing, and the
  # reason the import left it out.
  defp custom_trip(organization, version, route_id, shape_id) do
    Repo.insert!(%GtfsPlanner.Gtfs.Trip{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      route_id: route_id,
      trip_id: "trip_#{System.unique_integer([:positive])}",
      service_id: "service_1",
      trip_headsign: "Lincoln City",
      shape_id: shape_id,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: "no_direction"
    })
  end

  defp shape_points(organization, version, shape_id, points) do
    for {sequence, lat, lon} <- points do
      Repo.insert!(%Shape{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        shape_id: shape_id,
        shape_pt_lat: Decimal.new(lat),
        shape_pt_lon: Decimal.new(lon),
        shape_pt_sequence: sequence
      })
    end
  end
end
