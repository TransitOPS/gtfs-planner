defmodule GtfsPlannerWeb.Gtfs.RoutePatternRidersSeeTest do
  @moduledoc """
  LiveView coverage for the Running-times Riders see column (EV-14, AC-19): a
  stop headsign renders bold with "Set at this stop" on the info tint, rows
  without one show the timing's effective default muted, and the last row's
  "Last stop · none" wins even when that stop carries a headsign.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  @stop_headsign "Lincoln City Transit Center"

  setup %{conn: conn} do
    organization =
      organization_fixture(%{
        alias: "riders-see-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{email: "riders-see-#{System.unique_integer([:positive])}@example.com"})

    {:ok, _membership} =
      GtfsPlanner.Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  # One pattern over four stops with a single timing, so row 3 can carry a stop
  # headsign while row 4 stays the last row — the BROWSER-HS1 shape.
  defp lincoln_pattern(organization, version, pattern_id, opts \\ []) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "HS_#{pattern_id}",
        route_short_name: "HS",
        route_long_name: "Headsign corridor"
      })

    stops = Enum.map(1..4, &stop(organization, version, "HS_#{pattern_id}", &1))

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: pattern_id,
        route_pattern_name: "Lincoln runs",
        headsign: Keyword.get(opts, :pattern_headsign, "Lincoln City"),
        direction_id: 0
      })

    occurrences =
      stops
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, position} ->
        route_pattern_stop_fixture(pattern, stop.stop_id, position)
      end)

    timing =
      timed_pattern_fixture(pattern, %{
        name: "Weekday base",
        headsign: Keyword.get(opts, :timing_headsign)
      })

    stop_headsigns = Keyword.get(opts, :stop_headsigns, %{3 => @stop_headsign})

    Enum.each(occurrences, fn occurrence ->
      timed_pattern_stop_fixture(timing, occurrence, %{
        arrival_offset: 0,
        departure_offset: 0,
        stop_headsign: Map.get(stop_headsigns, occurrence.position)
      })
    end)

    trips =
      Enum.map(1..3, fn index ->
        linked_trip(
          organization,
          version,
          route,
          pattern,
          timing,
          "#{pattern_id}_T#{index}",
          stops,
          "Lincoln City"
        )
      end)

    %{route: route, pattern: pattern, timing: timing, trips: trips}
  end

  defp linked_trip(organization, version, route, pattern, timing, trip_id, stops, headsign) do
    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: trip_id,
        trip_headsign: headsign,
        direction_id: 0
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked",
      direction_id: 0
    })

    Enum.with_index(stops, 1)
    |> Enum.each(fn {stop, sequence} ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, stop.stop_id, %{
        stop_sequence: sequence,
        arrival_time: "08:0#{sequence - 1}:00",
        departure_time: "08:0#{sequence - 1}:00"
      })
    end)

    trip
  end

  defp stop(organization, version, route_id, index) do
    stop_fixture(organization.id, version.id, %{
      stop_id: "#{route_id}_S#{index}",
      stop_name: "Stop #{index}",
      location_type: 0
    })
  end

  defp timings_path(version, route, pattern) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=timings"
  end

  describe "the Riders see column" do
    test "the column names itself and marks the stop headsign set at its stop",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-RS1")

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      assert has_element?(view, "#timing-table th", "Riders see")
      assert has_element?(view, "#timing-table th", "headsign at this stop")

      assert has_element?(view, "#timing-riders-3", @stop_headsign)
      assert has_element?(view, "#timing-riders-3", "Set at this stop")
      assert element(view, "#timing-riders-3") |> render() =~ "bg-info-bg/60"
    end

    test "rows without a stop headsign show the effective default muted",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-RS2")

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      assert has_element?(view, "#timing-riders-1", "Lincoln City")
      assert has_element?(view, "#timing-riders-2", "Lincoln City")
      refute has_element?(view, "#timing-riders-1", "Set at this stop")
      refute element(view, "#timing-riders-1") |> render() =~ "bg-info-bg/60"
    end

    test "the last row shows Last stop · none",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_pattern(organization, version, "HS-RS3")

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      assert has_element?(view, "#timing-riders-4", "Last stop · none")
    end

    test "the last row's none wins over a headsign set at that stop",
         %{conn: conn, organization: organization, version: version} do
      context =
        lincoln_pattern(organization, version, "HS-RS4",
          stop_headsigns: %{3 => @stop_headsign, 4 => "Roads End"}
        )

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      assert has_element?(view, "#timing-riders-4", "Last stop · none")
      refute has_element?(view, "#timing-riders-4", "Set at this stop")
      assert has_element?(view, "#timing-riders-3", @stop_headsign)
    end

    test "rows without a stop headsign show the timing's own headsign as the default",
         %{conn: conn, organization: organization, version: version} do
      context =
        lincoln_pattern(organization, version, "HS-RS5",
          timing_headsign: "Lincoln City via Taft High"
        )

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      assert has_element?(view, "#timing-riders-1", "Lincoln City via Taft High")
      assert has_element?(view, "#timing-riders-2", "Lincoln City via Taft High")
      # A stop headsign still beats the timing's own default at its stop.
      assert has_element?(view, "#timing-riders-3", @stop_headsign)
      refute has_element?(view, "#timing-riders-1", "Set at this stop")
    end

    test "rows show No headsign when neither the timing nor the pattern sets one",
         %{conn: conn, organization: organization, version: version} do
      context =
        lincoln_pattern(organization, version, "HS-RS6",
          pattern_headsign: nil,
          stop_headsigns: %{}
        )

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      assert has_element?(view, "#timing-riders-1", "No headsign")
      assert has_element?(view, "#timing-riders-3", "No headsign")
      assert has_element?(view, "#timing-riders-4", "Last stop · none")
    end
  end
end
