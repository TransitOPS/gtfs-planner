defmodule GtfsPlanner.Gtfs.PatternComparison.UsageTest do
  @moduledoc """
  Merge evidence (EV-6) for CL-9, establishing INV-1 for the compare page's trip
  reads and preserving INV-2: `Usage.usage/3` and `Usage.calendars/2` count each
  pattern's trips on one calendar per R7 and never leave the organization and
  version.

  Every expected number is hand-derived from the fixtures below. The frequency
  trip's window is counted by the same `Summary.trips_per_hour/2` expansion the
  Schedules tab uses, whose `end_time` is exclusive: 10:00-13:30 every 30 minutes
  is 7 departures (10:00 through 13:00), and the template row is never added. The
  focused gate command is deferred to branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner/gtfs/pattern_comparison/usage_test.exs
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.PatternComparison.Usage

  @hours 24

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    stop_fixture(organization.id, version.id, %{stop_id: "s1", stop_name: "First stop"})
    stop_fixture(organization.id, version.id, %{stop_id: "s2", stop_name: "Second stop"})

    pattern_a =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "pattern_a"
      })

    pattern_b =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "pattern_b"
      })

    weekday = timed_pattern_fixture(pattern_a, %{name: "Weekday base"})
    peak = timed_pattern_fixture(pattern_a, %{name: "Weekday peak"})
    saturday = timed_pattern_fixture(pattern_a, %{name: "Saturday base"})
    other_route = timed_pattern_fixture(pattern_b, %{name: "Other route base"})

    # pattern_a on Weekday: two trips on the base timing, one on the peak timing,
    # one custom trip and one repeating trip. On Saturday: one trip.
    linked_trip(organization, version, route, "pattern_a", weekday, "WEEKDAY", "06:00:00")
    linked_trip(organization, version, route, "pattern_a", weekday, "WEEKDAY", "07:00:00")
    linked_trip(organization, version, route, "pattern_a", peak, "WEEKDAY", "07:30:00")
    linked_trip(organization, version, route, "pattern_a", saturday, "SATURDAY", "09:00:00")
    custom_trip(organization, version, route, "pattern_a", "WEEKDAY", "06:15:00")
    frequency_trip(organization, version, route, "pattern_a", weekday)

    linked_trip(organization, version, route, "pattern_b", other_route, "WEEKDAY", "06:30:00")
    linked_trip(organization, version, route, "pattern_b", other_route, "WEEKDAY", "18:00:00")

    calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAY"})
    calendar_fixture(organization.id, version.id, %{service_id: "SATURDAY"})
    calendar_fixture(organization.id, version.id, %{service_id: "SUNDAY"})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      service_description: "Weekday"
    })

    # The same natural route_pattern_id in another organization and in another
    # version of this organization: neither may be counted.
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_route = route_fixture(foreign_organization.id, foreign_version.id)

    foreign_pattern =
      route_pattern_fixture(foreign_organization.id, foreign_version.id, %{
        route_id: foreign_route.route_id,
        route_pattern_id: "pattern_a"
      })

    foreign_timing = timed_pattern_fixture(foreign_pattern, %{name: "Foreign timing"})
    unscoped_trip(foreign_organization, foreign_version, foreign_route, foreign_timing)

    other_version = gtfs_version_fixture(organization.id)
    other_version_route = route_fixture(organization.id, other_version.id)

    other_version_pattern =
      route_pattern_fixture(organization.id, other_version.id, %{
        route_id: other_version_route.route_id,
        route_pattern_id: "pattern_a"
      })

    other_version_timing =
      timed_pattern_fixture(other_version_pattern, %{name: "Other version timing"})

    unscoped_trip(organization, other_version, other_version_route, other_version_timing)

    %{
      scope: %{organization_id: organization.id, gtfs_version_id: version.id},
      organization: organization,
      version: version,
      route: route,
      pattern_a: pattern_a,
      pattern_b: pattern_b,
      weekday: weekday,
      peak: peak,
      other_route: other_route,
      foreign_timing: foreign_timing,
      other_version_timing: other_version_timing
    }
  end

  test "counts each pattern's trips per calendar", context do
    usage = Usage.usage(context.scope, [context.pattern_a, context.pattern_b], "WEEKDAY")

    assert usage["pattern_a"].total == 11

    assert usage["pattern_a"].hours ==
             hours(%{6 => 2, 7 => 2, 10 => 2, 11 => 2, 12 => 2, 13 => 1})

    assert usage["pattern_b"].total == 2
    assert usage["pattern_b"].hours == hours(%{6 => 1, 18 => 1})

    saturday = Usage.usage(context.scope, [context.pattern_a, context.pattern_b], "SATURDAY")

    assert saturday["pattern_a"].total == 1
    assert saturday["pattern_a"].hours == hours(%{9 => 1})

    assert saturday["pattern_b"] == %{
             total: 0,
             by_timing: %{},
             custom: 0,
             repeating: 0,
             hours: List.duplicate(0, @hours)
           }
  end

  test "splits the totals by timed_pattern_id", context do
    summary = Usage.usage(context.scope, [context.pattern_a], "WEEKDAY")["pattern_a"]

    assert summary.by_timing == %{context.weekday.id => 9, context.peak.id => 1}
    refute Map.has_key?(summary.by_timing, nil)
  end

  test "counts a trip with no timing as custom", context do
    summary = Usage.usage(context.scope, [context.pattern_a], "WEEKDAY")["pattern_a"]

    assert summary.custom == 1

    # The custom trip's 06:15 departure is in the total and in its hour bucket.
    assert summary.total == 11
    assert Enum.at(summary.hours, 6) == 2
  end

  test "counts a repeating trip as its expanded departures only", context do
    summary = Usage.usage(context.scope, [context.pattern_a], "WEEKDAY")["pattern_a"]

    # 10:00-13:30 every 30 minutes is 7 departures (10:00 through 13:00): the
    # shared expansion stops before `end_time`, exactly as the Schedules tab
    # counts this window. The trip's own stored 10:00 departure is not added.
    assert summary.repeating == 7
    assert summary.total == 11
    assert Enum.slice(summary.hours, 10, 4) == [2, 2, 2, 1]
  end

  test "never counts another organization's or version's trips", context do
    summary = Usage.usage(context.scope, [context.pattern_a], "WEEKDAY")["pattern_a"]

    assert summary.total == 11
    refute Map.has_key?(summary.by_timing, context.foreign_timing.id)
    refute Map.has_key?(summary.by_timing, context.other_version_timing.id)

    # The calendar counts are scoped the same way: both stray trips are on
    # WEEKDAY and would raise this pattern's count.
    weekday =
      Enum.find(Usage.calendars(context.scope, ["pattern_a"]), &(&1.service_id == "WEEKDAY"))

    assert weekday.trips == %{"pattern_a" => 11}
  end

  test "lists every calendar with per-pattern trip counts", context do
    assert Usage.calendars(context.scope, ["pattern_a", "pattern_b"]) == [
             %{
               service_id: "SATURDAY",
               name: "SATURDAY",
               trips: %{"pattern_a" => 1, "pattern_b" => 0}
             },
             %{
               service_id: "SUNDAY",
               name: "SUNDAY",
               trips: %{"pattern_a" => 0, "pattern_b" => 0}
             },
             %{
               service_id: "WEEKDAY",
               name: "Weekday",
               trips: %{"pattern_a" => 11, "pattern_b" => 2}
             }
           ]
  end

  test "counts nothing for a calendar the pattern does not run on", context do
    empty = %{
      total: 0,
      by_timing: %{},
      custom: 0,
      repeating: 0,
      hours: List.duplicate(0, @hours)
    }

    assert Usage.usage(context.scope, [context.pattern_a], "SUNDAY")["pattern_a"] == empty
    assert Usage.usage(context.scope, [context.pattern_a], nil)["pattern_a"] == empty
  end

  test "adds an after-midnight departure to the last hour bucket", context do
    linked_trip(
      context.organization,
      context.version,
      context.route,
      "pattern_b",
      context.other_route,
      "SATURDAY",
      "25:10:00"
    )

    summary = Usage.usage(context.scope, [context.pattern_b], "SATURDAY")["pattern_b"]

    assert summary.total == 1
    assert length(summary.hours) == @hours
    assert summary.hours == hours(%{23 => 1})
  end

  defp linked_trip(organization, version, route, pattern_id, timing, service_id, departure) do
    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: unique_trip_id(service_id),
        service_id: service_id
      })

    trip =
      trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })

    with_stop_times(organization, version, trip, departure)
  end

  defp custom_trip(organization, version, route, pattern_id, service_id, departure) do
    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: unique_trip_id(service_id),
        service_id: service_id
      })

    trip =
      trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: pattern_id,
        timed_pattern_id: nil,
        pattern_derivation_state: "custom",
        pattern_derivation_reason: "stops_mismatch"
      })

    with_stop_times(organization, version, trip, departure)
  end

  defp frequency_trip(organization, version, route, pattern_id, timing) do
    trip = linked_trip(organization, version, route, pattern_id, timing, "WEEKDAY", "10:00:00")

    frequency_fixture(organization.id, version.id, trip.trip_id, %{
      start_time: "10:00:00",
      end_time: "13:30:00",
      headway_secs: 1800
    })

    trip
  end

  # A trip of another organization or version carrying the same natural
  # route_pattern_id. It must never be counted, so it needs no stop times.
  defp unscoped_trip(organization, version, route, timing) do
    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: unique_trip_id("WEEKDAY"),
        service_id: "WEEKDAY"
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: "pattern_a",
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })
  end

  defp with_stop_times(organization, version, trip, departure) do
    stop_time_fixture(organization.id, version.id, trip.trip_id, "s1", %{
      arrival_time: departure,
      departure_time: departure,
      stop_sequence: 1
    })

    # A later departure that only a read taking the wrong stop time would use.
    stop_time_fixture(organization.id, version.id, trip.trip_id, "s2", %{
      arrival_time: "23:59:00",
      departure_time: "23:59:00",
      stop_sequence: 2
    })

    trip
  end

  defp unique_trip_id(service_id) do
    "trip_#{service_id}_#{System.unique_integer([:positive])}"
  end

  defp hours(counts) do
    Enum.map(0..(@hours - 1), &Map.get(counts, &1, 0))
  end
end
