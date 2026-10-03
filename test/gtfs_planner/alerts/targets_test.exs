defmodule GtfsPlanner.Alerts.TargetsTest do
  @moduledoc """
  Step 8: the target lookups the editor and the alerts pack read, all scoped to
  the alert's own version (AC-10, R1, CR-4).

  Two versions of one organization deliberately share GTFS identifiers, so a
  lookup that only filtered by GTFS id - or that forgot the version - would
  return the wrong row rather than nothing. Every expectation is a literal from
  the spec's rules, and no date is read from a clock: the departure cases pass
  their own date, including a Monday the fixture's calendar runs and a Saturday
  it does not.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.ScopeAnswer.TripTarget
  alias GtfsPlanner.Gtfs.AuditContext

  # The first Monday of October 2026: the fixture calendar runs Monday to Friday.
  @monday ~D[2026-10-05]
  @saturday ~D[2026-10-10]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "search_stops/3" do
    test "two versions sharing a stop id return only this version's row", context do
      mine =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Main St"))

      other = sibling_version(context)

      _theirs =
        stop_fixture(
          context.organization.id,
          other.gtfs_version_id,
          stop_attrs("S1", "Main St Elsewhere")
        )

      assert [option] = Alerts.search_stops(context.audit, "S1")

      assert option.id == mine.stop_id
      assert option.stop_id == "S1"
      assert option.label == "Main St"
    end

    test "matches name, stop id and platform code, case-insensitively", context do
      central =
        stop_fixture(
          context.organization.id,
          context.version.id,
          stop_attrs("C1", "Central Station", platform_code: "P7")
        )

      depot = stop_fixture(context.organization.id, context.version.id, stop_attrs("D9", "Depot"))

      assert [option] = Alerts.search_stops(context.audit, "central")
      assert option.id == central.stop_id

      assert [option] = Alerts.search_stops(context.audit, "d9")
      assert option.id == depot.stop_id

      assert [option] = Alerts.search_stops(context.audit, "P7")
      assert option.id == central.stop_id
    end

    test "lists the stops of a preferred route first", context do
      twelve =
        route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      on_twelve =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("A1", "Elm St"))

      elsewhere =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("A2", "Birch St"))

      serve(context, twelve, on_twelve, "08:00:00", 1)

      # Without a preference the stops read by name, so Birch St leads.
      assert [first, second] = Alerts.search_stops(context.audit, "St")

      assert first.id == elsewhere.stop_id
      assert second.id == on_twelve.stop_id

      assert [first, second] =
               Alerts.search_stops(context.audit, "St", prefer_route_ids: [twelve.route_id])

      assert first.id == on_twelve.stop_id
      assert second.id == elsewhere.stop_id
    end

    test "lists the preferred route's stops first even when more than 25 stops match",
         context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      for index <- 1..30 do
        stop_fixture(
          context.organization.id,
          context.version.id,
          stop_attrs("H#{index}", "Hwy #{String.pad_leading("#{index}", 2, "0")}")
        )
      end

      # Alphabetically after all thirty, so it is outside the first 25 matches.
      on_route =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("HZ", "Hwy Zulu"))

      serve(context, route, on_route, "08:00:00", 1)

      options = Alerts.search_stops(context.audit, "Hwy", prefer_route_ids: [route.route_id])

      assert length(options) == 25
      assert hd(options).id == on_route.stop_id
    end

    test "still returns twenty-five options when the alert already names some", context do
      stops =
        for index <- 1..30 do
          stop_fixture(
            context.organization.id,
            context.version.id,
            stop_attrs("B#{index}", "Broadway #{String.pad_leading("#{index}", 2, "0")}")
          )
        end

      excluded = Enum.take(stops, 3)

      options =
        Alerts.search_stops(context.audit, "Broadway",
          exclude_stop_ids: Enum.map(excluded, & &1.stop_id)
        )

      assert length(options) == 25
      assert Enum.all?(excluded, fn stop -> stop.stop_id not in Enum.map(options, & &1.id) end)
    end

    test "omits the stops the alert already names", context do
      affected =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("A1", "Elm St"))

      other =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("A2", "Birch St"))

      assert [option] =
               Alerts.search_stops(context.audit, "St", exclude_stop_ids: [affected.stop_id])

      assert option.id == other.stop_id
    end

    test "never offers an entrance or a station's interior stop", context do
      stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("P1", "Platform"))

      _entrance =
        stop_fixture(
          context.organization.id,
          context.version.id,
          stop_attrs("E1", "Platform entrance", location_type: 2)
        )

      assert [option] = Alerts.search_stops(context.audit, "Platform")
      assert option.id == stop.stop_id
    end

    test "returns at most twenty-five options", context do
      for index <- 1..26 do
        stop_fixture(
          context.organization.id,
          context.version.id,
          stop_attrs("B#{index}", "Broadway #{index}")
        )
      end

      assert length(Alerts.search_stops(context.audit, "Broadway")) == 25
    end

    test "a blank query matches nothing", context do
      _stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Main St"))

      assert Alerts.search_stops(context.audit, "   ") == []
      assert Alerts.search_stops(context.audit, nil) == []
    end

    test "a wildcard in the query is matched literally", context do
      _main =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Main St"))

      percent =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("P1", "50% St"))

      assert [option] = Alerts.search_stops(context.audit, "50%")
      assert option.id == percent.stop_id
    end

    test "a member without the editor role reads no stops", context do
      _stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Main St"))

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      audit = audit_context(context.organization, context.version, viewer)

      assert Alerts.search_stops(audit, "S1") == []
    end
  end

  describe "search_routes/2" do
    test "matches short name, long name and route id", context do
      by_number =
        route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      by_name =
        route_fixture(
          context.organization.id,
          context.version.id,
          route_attrs("r44", "44", route_long_name: "Harbour Line")
        )

      assert [option] = Alerts.search_routes(context.audit, "12")
      assert option.id == by_number.route_id
      assert option.label == "12"

      assert [option] = Alerts.search_routes(context.audit, "Harbour")
      assert option.id == by_name.route_id

      assert [option] = Alerts.search_routes(context.audit, "r44")
      assert option.id == by_name.route_id
    end

    test "a route of another version is not offered", context do
      other = sibling_version(context)

      _theirs =
        route_fixture(
          context.organization.id,
          other.gtfs_version_id,
          route_attrs("r12", "12", route_long_name: "Elsewhere Express")
        )

      assert Alerts.search_routes(context.audit, "r12") == []
      assert Alerts.search_routes(context.audit, "Elsewhere") == []
    end

    test "a blank query matches nothing", context do
      _route =
        route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      assert Alerts.search_routes(context.audit, "") == []
    end
  end

  describe "route_stops/2" do
    test "lists the route's stops in the order its trips serve them", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      first = stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Depot"))

      middle =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S2", "Elm St"))

      last =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S3", "Broadway"))

      trip =
        trip_fixture(
          context.organization.id,
          context.version.id,
          route.route_id,
          trip_attrs("t1", "weekday")
        )

      # The clock runs backwards so the assertion reads the sequence, not the
      # time of day.
      stop_time_fixture(
        context.organization.id,
        context.version.id,
        trip.trip_id,
        first.stop_id,
        %{
          stop_sequence: 1,
          departure_time: "09:00:00"
        }
      )

      stop_time_fixture(
        context.organization.id,
        context.version.id,
        trip.trip_id,
        middle.stop_id,
        %{
          stop_sequence: 2,
          departure_time: "08:30:00"
        }
      )

      stop_time_fixture(
        context.organization.id,
        context.version.id,
        trip.trip_id,
        last.stop_id,
        %{
          stop_sequence: 3,
          departure_time: "08:15:00"
        }
      )

      assert [a, b, c] = Alerts.route_stops(context.audit, route.route_id)

      assert [a.id, b.id, c.id] == [first.stop_id, middle.stop_id, last.stop_id]
      assert a.label == "Depot"
    end

    test "orders a two-direction route by one trip, not by the smallest sequence across both",
         context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      stops =
        for {stop_id, name} <- [
              {"A", "Alder"},
              {"B", "Birch"},
              {"C", "Cedar"},
              {"D", "Dogwood"},
              {"E", "Elm"}
            ],
            into: %{} do
          {stop_id,
           stop_fixture(context.organization.id, context.version.id, stop_attrs(stop_id, name))}
        end

      # The outbound trips run A to D and the inbound trip runs back over the same
      # stops, then on to E. Merging both directions by smallest sequence would
      # give A, D, B, C, E.
      outbound = directed_trip(context, route, "out", 0)
      short_turn = directed_trip(context, route, "short", 0)
      inbound = directed_trip(context, route, "in", 1)

      sequence(context, outbound, [stops["A"], stops["B"], stops["C"], stops["D"]])
      sequence(context, short_turn, [stops["A"], stops["B"]])
      sequence(context, inbound, [stops["D"], stops["C"], stops["B"], stops["A"], stops["E"]])

      assert Enum.map(Alerts.route_stops(context.audit, route.route_id), & &1.stop_id) ==
               ["A", "B", "C", "D", "E"]
    end

    test "a route with no trips has no stops", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      assert Alerts.route_stops(context.audit, route.route_id) == []
    end

    test "a route of another version has no stops here", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))
      stop = stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Depot"))

      other = sibling_version(context)

      their_route =
        route_fixture(context.organization.id, other.gtfs_version_id, route_attrs("r12", "12"))

      their_trip =
        trip_fixture(
          context.organization.id,
          other.gtfs_version_id,
          their_route.route_id,
          trip_attrs("t1", "weekday")
        )

      stop_time_fixture(
        context.organization.id,
        other.gtfs_version_id,
        their_trip.trip_id,
        stop.stop_id,
        %{stop_sequence: 1}
      )

      assert Alerts.route_stops(context.audit, their_route.route_id) == []

      serve(context, route, stop, "08:00:00", 1)

      assert [_only] = Alerts.route_stops(context.audit, route.route_id)
    end
  end

  describe "routes_at_stops/2" do
    test "lists the routes serving a stop", context do
      twelve =
        route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      five = route_fixture(context.organization.id, context.version.id, route_attrs("r5", "5"))
      _other = route_fixture(context.organization.id, context.version.id, route_attrs("r9", "9"))

      shared =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Central"))

      serve(context, twelve, shared, "08:00:00", 1)
      serve(context, five, shared, "08:10:00", 1)

      # Routes order by short name as text, so "12" precedes "5".
      assert [first, second] = Alerts.routes_at_stops(context.audit, [shared.stop_id])

      assert [first.id, second.id] == [twelve.route_id, five.route_id]
    end

    test "a stop of another version finds no routes", context do
      other = sibling_version(context)
      audit = audit_context(context.organization, other.version, context.actor)

      their_route =
        route_fixture(context.organization.id, other.gtfs_version_id, route_attrs("r12", "12"))

      their_stop =
        stop_fixture(context.organization.id, other.gtfs_version_id, stop_attrs("S1", "Central"))

      serve(%{context | audit: audit}, their_route, their_stop, "08:00:00", 1)

      assert Alerts.routes_at_stops(context.audit, [their_stop.stop_id]) == []
      assert Alerts.routes_at_stops(context.audit, []) == []
    end
  end

  describe "departures_on/4" do
    test "offers the trips whose service runs on the date", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      _calendar =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      early = serving_trip(context, route, "t_0815", "weekday", 0, "Depot", "08:15:00")
      late = serving_trip(context, route, "t_0930", "weekday", 0, "Depot", "09:30:00")

      other = serving_trip(context, route, "t_0745", "weekday", 1, "Uptown", "07:45:00")

      assert [first, second] = Alerts.departures_on(context.audit, route.route_id, 0, @monday)

      assert [first.trip_id, second.trip_id] == [early.trip_id, late.trip_id]
      assert first.label == "8:15 AM to Depot"
      assert first.first_departure_seconds == 8 * 3_600 + 15 * 60
      assert other.trip_id not in [first.trip_id, second.trip_id]
    end

    test "a trip that does not run on the date is not offered", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      _weekday =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      _weekend =
        calendar_fixture(context.organization.id, context.version.id, %{
          service_id: "weekend",
          monday: 0,
          tuesday: 0,
          wednesday: 0,
          thursday: 0,
          friday: 0,
          saturday: 1,
          sunday: 1
        })

      weekday = serving_trip(context, route, "t_0815", "weekday", 0, "Depot", "08:15:00")
      weekend = serving_trip(context, route, "t_1015", "weekend", 0, "Depot", "10:15:00")

      assert [only] = Alerts.departures_on(context.audit, route.route_id, nil, @monday)
      assert only.trip_id == weekday.trip_id

      assert [only] = Alerts.departures_on(context.audit, route.route_id, nil, @saturday)
      assert only.trip_id == weekend.trip_id
    end

    test "a calendar_dates removal on the date excludes the trip", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      _calendar =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      trip = serving_trip(context, route, "t_0815", "weekday", 0, "Depot", "08:15:00")

      assert [_only] = Alerts.departures_on(context.audit, route.route_id, 0, @monday)

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "weekday",
        date: @monday,
        exception_type: 2
      })

      assert Alerts.departures_on(context.audit, route.route_id, 0, @monday) == []
      # The trip is still in the version: a service exception removes it from
      # this date's choices, it does not delete anything.
      assert Repo.get(GtfsPlanner.Gtfs.Trip, trip.id)
    end

    test "a calendar_dates addition offers a trip the weekly calendar does not run", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      _calendar =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      trip = serving_trip(context, route, "t_0815", "special", 0, "Depot", "08:15:00")

      assert Alerts.departures_on(context.audit, route.route_id, 0, @monday) == []

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "special",
        date: @monday,
        exception_type: 1
      })

      assert [only] = Alerts.departures_on(context.audit, route.route_id, 0, @monday)
      assert only.trip_id == trip.trip_id
    end

    test "a departure past midnight says it is the next day", context do
      route =
        route_fixture(context.organization.id, context.version.id, route_attrs("n12", "N12"))

      _calendar =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "nightly"})

      night = serving_trip(context, route, "t_night", "nightly", 0, "Downtown", "24:40:00")

      assert [only] = Alerts.departures_on(context.audit, route.route_id, 0, @monday)

      assert only.trip_id == night.trip_id
      assert only.label == "12:40 AM (next day) to Downtown"
      assert only.first_departure_seconds == 24 * 3_600 + 40 * 60
    end

    test "a route of another version has no departures here", context do
      other = sibling_version(context)
      audit = audit_context(context.organization, other.version, context.actor)

      their_route =
        route_fixture(context.organization.id, other.gtfs_version_id, route_attrs("r12", "12"))

      _calendar =
        calendar_fixture(context.organization.id, other.gtfs_version_id, %{service_id: "weekday"})

      serving_trip(
        %{context | audit: audit},
        their_route,
        "t_0815",
        "weekday",
        0,
        "Depot",
        "08:15:00"
      )

      assert Alerts.departures_on(context.audit, their_route.route_id, 0, @monday) == []
    end

    test "a trip whose calendar cannot be read does not hide the route's other departures",
         context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      _weekday =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      broken =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "broken"})

      # An imported calendar can end before it starts; the changeset refuses that,
      # so the retained row is written past it.
      {1, _rows} =
        Repo.update_all(
          from(c in GtfsPlanner.Gtfs.Calendar, where: c.id == ^broken.id),
          set: [start_date: ~D[2026-12-31], end_date: ~D[2026-01-01]]
        )

      good = serving_trip(context, route, "t_0815", "weekday", 0, "Depot", "08:15:00")
      _bad = serving_trip(context, route, "t_0900", "broken", 0, "Depot", "09:00:00")

      assert [only] = Alerts.departures_on(context.audit, route.route_id, 0, @monday)
      assert only.trip_id == good.trip_id
    end

    test "a trip with no readable first stop time is not offered", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      _calendar =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      # A trip row with no stop times at all: nothing the operator could
      # recognize as a departure, so it is not offered as one.
      _timeless =
        trip_fixture(
          context.organization.id,
          context.version.id,
          route.route_id,
          trip_attrs("t_none", "weekday")
        )

      assert Alerts.departures_on(context.audit, route.route_id, 0, @monday) == []
    end
  end

  describe "route_types/1" do
    test "lists the version's distinct route types ascending", context do
      _bus =
        route_fixture(
          context.organization.id,
          context.version.id,
          route_attrs("r12", "12", route_type: 3)
        )

      _tram =
        route_fixture(
          context.organization.id,
          context.version.id,
          route_attrs("t1", "T1", route_type: 0)
        )

      _another_bus =
        route_fixture(
          context.organization.id,
          context.version.id,
          route_attrs("r5", "5", route_type: 3)
        )

      assert Alerts.route_types(context.audit) == [0, 3]
    end

    test "a route of another version contributes no type", context do
      _bus =
        route_fixture(
          context.organization.id,
          context.version.id,
          route_attrs("r12", "12", route_type: 3)
        )

      other = sibling_version(context)

      _tram =
        route_fixture(
          context.organization.id,
          other.gtfs_version_id,
          route_attrs("t1", "T1", route_type: 0)
        )

      assert Alerts.route_types(context.audit) == [3]
    end
  end

  describe "route_directions/2" do
    test "labels each direction by its first active pattern's headsign", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      pattern(context, route, 0, "Depot", 2)
      pattern(context, route, 0, "Lincoln City", 1)
      pattern(context, route, 0, "Retired", 0, active: false)
      pattern(context, route, 1, nil, 1)

      assert Alerts.route_directions(context.audit, [route.route_id]) == [
               %{direction_id: 0, label: "Lincoln City"},
               %{direction_id: 1, label: "Direction 1"}
             ]
    end

    test "a pattern of another version sharing the route id names no direction here", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))
      pattern(context, route, 1, nil, 1)

      other = sibling_version(context)

      their_route =
        route_fixture(context.organization.id, other.gtfs_version_id, route_attrs("r12", "12"))

      pattern(
        %{context | audit: audit_context(context.organization, other.version, context.actor)},
        their_route,
        1,
        "Elsewhere",
        0
      )

      assert Alerts.route_directions(context.audit, [route.route_id]) == [
               %{direction_id: 1, label: "Direction 1"}
             ]
    end
  end

  describe "stops_by_id/2" do
    test "an editor reads the version's rows and none of a sibling version's", context do
      stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Central"))

      other = sibling_version(context)

      _their_stop =
        stop_fixture(
          context.organization.id,
          other.gtfs_version_id,
          stop_attrs("S1", "Central Elsewhere")
        )

      # Both versions hold stop "S1"; only this version's row answers.
      assert %{} = stops = Alerts.stops_by_id(context.audit, [stop.stop_id])
      assert Map.keys(stops) == ["S1"]
      assert stops["S1"].label == "Central"
    end

    test "a member without the editor role reads an empty map, not a list", context do
      stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Central"))

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])
      audit = audit_context(context.organization, context.version, viewer)

      assert Alerts.stops_by_id(audit, [stop.stop_id]) == %{}
    end
  end

  describe "labels_for/2" do
    test "names the routes, stops and trips the alert's scope holds", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      _calendar =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Central"))

      trip = serving_trip(context, route, "t_0815", "weekday", 0, "Depot", "08:15:00")

      alert = cancellation(context, route.route_id, stop.stop_id, trip.trip_id)

      assert %{routes: routes, stops: stops, trips: trips} =
               Alerts.labels_for(context.audit, alert)

      assert routes == %{"r12" => "12"}
      assert stops == %{"S1" => "Central"}
      assert trips == %{"t_0815" => "8:15 AM to Depot"}
    end

    test "a stop deleted from the version has no label and is reported missing", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      _calendar =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Central"))

      trip = serving_trip(context, route, "t_0815", "weekday", 0, "Depot", "08:15:00")

      alert = cancellation(context, route.route_id, stop.stop_id, trip.trip_id)

      delete!(GtfsPlanner.Gtfs.Stop, stop.id)

      assert %{stops: stops} = Alerts.labels_for(context.audit, alert)
      assert stops == %{}

      # The same reading the list row uses: the identity is still named, and the
      # list flags it rather than the message inventing a name for it.
      assert %{stops: missing} = Map.fetch!(Listing.missing_target_ids([alert]), alert.id)
      assert MapSet.member?(missing, "S1")
    end

    test "a member without the editor role reads no labels", context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs("S1", "Central"))

      alert = cancellation(context, route.route_id, stop.stop_id, nil)

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      audit = audit_context(context.organization, context.version, viewer)

      assert Alerts.labels_for(audit, alert) == %{routes: %{}, stops: %{}, trips: %{}}
    end
  end

  describe "exact feed IDs" do
    # Feed IDs that read as UUIDs and are not lower case: nothing may normalize them.
    @route_id "ABCDEF00-0000-0000-0000-000000000000"
    @stop_id "FEDCBA00-0000-0000-0000-000000000001"
    @trip_id "AAAAAAAA-0000-0000-0000-000000000002"

    test "a UUID-looking ID keeps its case through the answer, the capture and the labels",
         context do
      route =
        route_fixture(context.organization.id, context.version.id, route_attrs(@route_id, "7"))

      stop =
        stop_fixture(context.organization.id, context.version.id, stop_attrs(@stop_id, "Elm"))

      _trip =
        trip_fixture(
          context.organization.id,
          context.version.id,
          route.route_id,
          trip_attrs(@trip_id, "weekday")
        )

      alert = cancellation(context, @route_id, stop.stop_id, @trip_id)

      assert alert.scope.route_ids == [@route_id]
      assert alert.scope.stop_ids == [@stop_id]
      assert [%{trip_id: @trip_id}] = alert.scope.trips

      selectors = alert.target_reference["selectors"]

      assert [%{"id" => @route_id, "gtfs_id" => @route_id, "label" => "7"}] = selectors["routes"]
      assert [%{"id" => @stop_id, "gtfs_id" => @stop_id, "label" => "Elm"}] = selectors["stops"]
      assert [%{"id" => @trip_id, "gtfs_id" => @trip_id, "resolved" => true}] = selectors["trips"]
      assert selectors["unresolved_routes"] == [] and selectors["unresolved_stops"] == []

      assert %{routes: %{@route_id => "7"}, stops: %{@stop_id => "Elm"}, trips: trips} =
               Alerts.labels_for(context.audit, alert)

      assert Map.keys(trips) == [@trip_id]

      assert %{routes: no_routes, stops: no_stops, trips: no_trips} =
               Map.fetch!(Listing.missing_target_ids([alert]), alert.id)

      assert Enum.all?([no_routes, no_stops, no_trips], &(MapSet.size(&1) == 0))
    end

    test "a differently cased spelling is another target and is refused", context do
      route_fixture(context.organization.id, context.version.id, route_attrs(@route_id, "7"))
      stop_fixture(context.organization.id, context.version.id, stop_attrs(@stop_id, "Elm"))

      assert Alerts.stops_by_id(context.audit, [String.downcase(@stop_id)]) == %{}
      assert Map.keys(Alerts.stops_by_id(context.audit, [@stop_id])) == [@stop_id]

      assert {:error, %Ecto.Changeset{} = changeset} =
               Alerts.create_alert(context.audit, %{
                 "scope" => %{"shape" => "routes", "route_ids" => [String.downcase(@route_id)]}
               })

      assert %{scope: ["Choose routes from this version."]} =
               Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
    end

    test "the selection digest ignores order and tells apart case and frequency instances" do
      trip = %TripTarget{trip_id: "T-100", service_date: ~D[2026-10-05], start_time: "08:00:00"}
      answer = %ScopeAnswer{route_ids: ["b", @route_id], trips: [trip]}

      assert ScopeAnswer.digest(answer) ==
               ScopeAnswer.digest(%{answer | route_ids: [@route_id, "b"]})

      refute ScopeAnswer.digest(answer) ==
               ScopeAnswer.digest(%{answer | route_ids: ["b", String.downcase(@route_id)]})

      refute ScopeAnswer.digest(answer) ==
               ScopeAnswer.digest(%{answer | trips: [%{trip | start_time: "25:15:00"}]})
    end

    test "every frequency instance of a trip is its own target and keeps its start time",
         context do
      route = route_fixture(context.organization.id, context.version.id, route_attrs("r12", "12"))

      trip_fixture(
        context.organization.id,
        context.version.id,
        route.route_id,
        trip_attrs("T-100", "weekday")
      )

      alert =
        alert_fixture(context.audit, %{
          "urgency" => "now",
          "situation" => "cancelled_trips",
          "scope" => %{
            "shape" => "trips",
            "route_ids" => ["r12"],
            "trips" => [
              %{"trip_id" => "T-100", "service_date" => "2026-10-05", "start_time" => "8:00:00"},
              %{"trip_id" => "T-100", "service_date" => "2026-10-05", "start_time" => "25:15:00"},
              %{"trip_id" => "T-100", "service_date" => "2026-10-06"}
            ]
          }
        })

      assert Enum.map(alert.scope.trips, &{&1.trip_id, &1.service_date, &1.start_time}) == [
               {"T-100", ~D[2026-10-05], "08:00:00"},
               {"T-100", ~D[2026-10-05], "25:15:00"},
               {"T-100", ~D[2026-10-06], nil}
             ]

      assert Enum.map(
               alert.target_reference["selectors"]["trips"],
               &{&1["service_date"], &1["start_time"]}
             ) == [
               {"2026-10-05", "08:00:00"},
               {"2026-10-05", "25:15:00"},
               {"2026-10-06", nil}
             ]

      # A save that selects nothing new keeps the answer and its capture as they were.
      saved =
        save!(context.audit, alert, %{"message" => %{"header" => "Trips will not run"}})

      assert saved.scope == alert.scope
      assert saved.target_reference == alert.target_reference

      assert {:error, %Ecto.Changeset{valid?: false}} =
               Alerts.save_draft(context.audit, saved.id, saved.revision, %{
                 "scope" => %{
                   "trips" => [
                     %{
                       "trip_id" => "T-100",
                       "service_date" => "2026-10-05",
                       "start_time" => "8am"
                     }
                   ]
                 }
               })
    end

    test "a feed ID missing from one version does not flag another version's alert", context do
      other = sibling_version(context)
      other_audit = audit_context(context.organization, other.version, context.actor)

      mine = route_fixture(context.organization.id, context.version.id, route_attrs("R1", "1"))
      route_fixture(context.organization.id, other.gtfs_version_id, route_attrs("R1", "1"))

      here =
        alert_fixture(context.audit, %{"scope" => %{"shape" => "routes", "route_ids" => ["R1"]}})

      there =
        alert_fixture(other_audit, %{"scope" => %{"shape" => "routes", "route_ids" => ["R1"]}})

      Repo.delete!(mine)

      missing = Listing.missing_target_ids([here, there])

      assert MapSet.to_list(missing[here.id].routes) == ["R1"]
      assert MapSet.to_list(missing[there.id].routes) == []
    end
  end

  # -- Fixtures ------------------------------------------------------------

  # A second version of the same organization, so two versions can share GTFS
  # identifiers without sharing rows.
  defp sibling_version(context) do
    version = gtfs_version_fixture(context.organization.id)
    agency_fixture(context.organization.id, version.id)

    %{gtfs_version_id: version.id, version: version}
  end

  defp stop_attrs(stop_id, stop_name, overrides \\ []) do
    Map.merge(
      %{
        stop_id: stop_id,
        stop_name: stop_name,
        location_type: 0,
        stop_lat: Decimal.new("40.0"),
        stop_lon: Decimal.new("-74.0")
      },
      Map.new(overrides)
    )
  end

  defp route_attrs(route_id, short_name, overrides \\ []) do
    Map.merge(
      %{route_id: route_id, route_short_name: short_name, route_type: 3},
      Map.new(overrides)
    )
  end

  defp trip_attrs(trip_id, service_id) do
    %{trip_id: trip_id, service_id: service_id, trip_headsign: "Depot"}
  end

  defp pattern(context, route, direction_id, headsign, sort_order, overrides \\ []) do
    route_pattern_fixture(
      context.organization.id,
      context.audit.gtfs_version_id,
      Map.merge(
        %{
          route_id: route.route_id,
          direction_id: direction_id,
          headsign: headsign,
          route_pattern_sort_order: sort_order
        },
        Map.new(overrides)
      )
    )
  end

  defp directed_trip(context, route, trip_id, direction_id) do
    trip_fixture(
      context.organization.id,
      context.version.id,
      route.route_id,
      Map.put(trip_attrs(trip_id, "weekday"), :direction_id, direction_id)
    )
  end

  # The stops in the order the trip serves them, one stop time each.
  defp sequence(context, trip, stops) do
    stops
    |> Enum.with_index(1)
    |> Enum.each(fn {stop, position} ->
      stop_time_fixture(
        context.organization.id,
        context.version.id,
        trip.trip_id,
        stop.stop_id,
        %{stop_sequence: position}
      )
    end)
  end

  # A route with one stop at one time, which is all the "serving" lookups need.
  defp serve(context, route, stop, departure_time, stop_sequence) do
    trip =
      trip_fixture(
        context.organization.id,
        context.audit.gtfs_version_id,
        route.route_id,
        trip_attrs("t_#{route.route_id}_#{stop.stop_id}", "weekday")
      )

    stop_time_fixture(
      context.organization.id,
      context.audit.gtfs_version_id,
      trip.trip_id,
      stop.stop_id,
      %{stop_sequence: stop_sequence, departure_time: departure_time}
    )
  end

  # A trip on the route, running under `service_id`, departing at the route's
  # only stop in `direction_id`.
  defp serving_trip(context, route, trip_id, service_id, direction_id, headsign, departure_time) do
    stop =
      stop_fixture(
        context.organization.id,
        context.audit.gtfs_version_id,
        stop_attrs("stop_#{trip_id}", headsign)
      )

    trip =
      trip_fixture(
        context.organization.id,
        context.audit.gtfs_version_id,
        route.route_id,
        Map.merge(trip_attrs(trip_id, service_id), %{
          direction_id: direction_id,
          trip_headsign: headsign
        })
      )

    stop_time_fixture(
      context.organization.id,
      context.audit.gtfs_version_id,
      trip.trip_id,
      stop.stop_id,
      %{stop_sequence: 1, departure_time: departure_time}
    )

    trip
  end

  # An alert naming a route, a stop and (optionally) a cancelled trip, built
  # through the same commands the editor uses.
  defp cancellation(context, route_id, stop_id, trip_id) do
    alert =
      alert_fixture(context.audit, %{
        "urgency" => "now",
        "situation" => "stop_closed",
        "cause" => "construction",
        "scope" => %{
          "shape" => "trips",
          "route_ids" => [route_id],
          "stop_ids" => [stop_id],
          "trips" =>
            if(trip_id,
              do: [%{"trip_id" => trip_id, "service_date" => "2026-10-05"}],
              else: []
            )
        },
        "message" => %{
          "header" => "Central Station stop closed",
          "description" => "Use Elm St instead."
        }
      })

    save!(context.audit, alert, %{
      "timing" => %{
        "start_date" => "2026-10-05",
        "start_time" => "08:00:00",
        "end_kind" => "estimated",
        "check_in_at" => "2026-10-06 09:00:00"
      }
    })
  end

  defp save!(audit, alert, attrs) do
    assert {:ok, saved} = Alerts.save_draft(audit, alert.id, alert.revision, attrs)
    saved
  end

  defp delete!(schema, id) do
    schema |> Repo.get!(id) |> Repo.delete!()
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end
end
