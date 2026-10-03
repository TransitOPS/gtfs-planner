defmodule GtfsPlanner.Gtfs.RoutePatterns.HeadsignUsageFactsTest do
  @moduledoc """
  Focused coverage for the block and mid-trip facts on usage trips (EV-4): the
  interline next-block lookup, the same-route successor, the first timed stop
  headsign, the `:follows` group's nil facts and the organization scoping of
  the block lookup.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route

  setup do
    organization =
      organization_fixture(%{alias: "headsign-facts-#{System.system_time(:nanosecond)}"})

    version = gtfs_version_fixture(organization.id)
    route_10 = route_fixture(organization.id, version.id, route_id: "10", route_short_name: "10")

    %{organization: organization, version: version, route_10: route_10}
  end

  test "an interlined trip gets the next block's route and time", context do
    %{pattern: pattern, differing_trip: differing_trip} =
      block_scenario(context, successor_route_id: "20")

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    differing_trip_id = differing_trip.id

    assert [
             %{
               value: "Roads End",
               kind: :interline,
               likely_typo: false,
               trips: [trip]
             }
           ] = usage.groups

    assert trip.id == differing_trip_id

    # 18:22:00 through GtfsTime; at or after the trip's 18:16:00 last arrival.
    assert trip.next_block == %{
             route_short_name: "20",
             departure_secs: 18 * 3_600 + 22 * 60,
             headsign: "Boston"
           }

    assert trip.mid_trip_change == nil
  end

  test "a group mixing interlined and non-interlined trips is labelled :other", context do
    %{pattern: pattern, differing_trip: interlined} =
      block_scenario(context, successor_route_id: "20")

    [weekday] = stored_timings(pattern.id)

    unblocked =
      trip_fixture(context.organization.id, context.version.id, context.route_10.route_id,
        trip_headsign: "Roads End",
        service_id: "WK"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: weekday.id,
        pattern_derivation_state: "linked"
      })

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    assert [%{value: "Roads End", kind: :other, trips: trips}] = usage.groups
    next_blocks = Map.new(trips, &{&1.id, &1.next_block})

    assert %{route_short_name: "20"} = next_blocks[interlined.id]
    assert next_blocks[unblocked.id] == nil
  end

  test "a successor on the same route gives next_block nil and kind :other", context do
    %{pattern: pattern, differing_trip: differing_trip} =
      block_scenario(context, successor_route_id: "10")

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    assert [%{value: "Roads End", kind: :other, likely_typo: false, trips: [trip]}] =
             usage.groups

    assert trip.id == differing_trip.id
    assert trip.next_block == nil
  end

  test "a timing with stop headsigns names its first headsign stop", context do
    stop_one =
      stop_fixture(context.organization.id, context.version.id, stop_name: "Union Station")

    stop_two = stop_fixture(context.organization.id, context.version.id, stop_name: "Taft Square")
    stop_three = stop_fixture(context.organization.id, context.version.id, stop_name: "Taft High")

    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route_10.route_id,
        route_pattern_id: "HS-MIDTRIP",
        headsign: "Lincoln City"
      })

    occurrences = [
      route_pattern_stop_fixture(pattern, stop_one.stop_id, 1),
      route_pattern_stop_fixture(pattern, stop_two.stop_id, 2),
      route_pattern_stop_fixture(pattern, stop_three.stop_id, 3)
    ]

    weekday = timed_pattern_fixture(pattern, %{name: "Weekday base"})

    # The lowest position with a non-blank stop headsign decides: positions 1
    # and 2 carry none (position 2 is import-shaped blank), position 3 does.
    timed_pattern_stop_fixture(weekday, Enum.at(occurrences, 0))
    timed_pattern_stop_fixture(weekday, Enum.at(occurrences, 1), %{stop_headsign: " "})
    timed_pattern_stop_fixture(weekday, Enum.at(occurrences, 2), %{stop_headsign: "Taft High"})

    differing_trip =
      trip_fixture(context.organization.id, context.version.id, context.route_10.route_id,
        trip_headsign: "Roads End",
        service_id: "WK"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: weekday.id,
        pattern_derivation_state: "linked"
      })

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    assert [%{kind: :other, trips: [trip]}] = usage.groups
    assert trip.id == differing_trip.id
    assert trip.mid_trip_change == "Taft High"
    assert trip.next_block == nil
  end

  test "trips in the :follows group keep next_block nil", context do
    %{pattern: pattern, differing_trip: differing_trip} =
      block_scenario(context, successor_route_id: "20", with_follower?: true)

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern,
               from: "Lincoln City"
             )

    assert [%{kind: :follows, trips: [follower]}, %{kind: :interline, trips: [trip]}] =
             usage.groups

    # The follower shares the successor's block and service, so a lookup would
    # have filled its fact; only differing groups are looked up.
    assert follower.next_block == nil
    assert follower.mid_trip_change == nil

    assert trip.id == differing_trip.id

    assert trip.next_block == %{
             route_short_name: "20",
             departure_secs: 18 * 3_600 + 22 * 60,
             headsign: "Boston"
           }
  end

  test "a block successor in another organization is not a next block", context do
    %{pattern: pattern, differing_trip: differing_trip} =
      block_scenario(context, successor_route_id: nil)

    foreign_organization =
      organization_fixture(%{alias: "headsign-facts-other-#{System.system_time(:nanosecond)}"})

    foreign_version = gtfs_version_fixture(foreign_organization.id)

    route_fixture(foreign_organization.id, foreign_version.id,
      route_id: "99",
      route_short_name: "99"
    )

    trip_fixture(foreign_organization.id, foreign_version.id, "99",
      trip_headsign: "Elsewhere",
      block_id: "B1",
      service_id: "WK"
    )
    |> tap(fn successor ->
      stop_time_fixture(
        foreign_organization.id,
        foreign_version.id,
        successor.trip_id,
        stop_fixture(foreign_organization.id, foreign_version.id).stop_id,
        arrival_time: "18:22:00",
        departure_time: "18:22:00",
        stop_sequence: 1
      )
    end)

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    assert [%{kind: :other, trips: [trip]}] = usage.groups
    assert trip.id == differing_trip.id
    assert trip.next_block == nil
  end

  # A differing trip "Roads End" in block B1 on service WK ends at
  # 17:10 + 66 min = 18:16:00, followed in B1 on the same service by a trip
  # departing 18:22:00 on `successor_route_id` ("20" interlines, "10" is this
  # route and must not match, nil builds no in-organization successor).
  defp block_scenario(context, opts) do
    successor_route_id = Keyword.fetch!(opts, :successor_route_id)
    differing_block_id = Keyword.get(opts, :differing_block_id, "B1")

    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route_10.route_id,
        route_pattern_id: "HS-BLOCK",
        headsign: "Lincoln City"
      })

    weekday = timed_pattern_fixture(pattern, %{name: "Weekday base"})

    differing_trip =
      trip_fixture(context.organization.id, context.version.id, context.route_10.route_id,
        trip_headsign: "Roads End",
        service_id: "WK",
        block_id: differing_block_id
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: weekday.id,
        pattern_derivation_state: "linked"
      })

    stop = stop_fixture(context.organization.id, context.version.id)
    last_stop = stop_fixture(context.organization.id, context.version.id)

    stop_time_fixture(
      context.organization.id,
      context.version.id,
      differing_trip.trip_id,
      stop.stop_id,
      arrival_time: "17:10:00",
      departure_time: "17:10:00",
      stop_sequence: 1
    )

    stop_time_fixture(
      context.organization.id,
      context.version.id,
      differing_trip.trip_id,
      last_stop.stop_id,
      arrival_time: "18:16:00",
      departure_time: "18:16:00",
      stop_sequence: 2
    )

    if successor_route_id do
      successor_route_id
      |> block_successor(context)
      |> tap(fn successor ->
        stop_time_fixture(
          context.organization.id,
          context.version.id,
          successor.trip_id,
          stop.stop_id,
          arrival_time: "18:22:00",
          departure_time: "18:22:00",
          stop_sequence: 1
        )
      end)
    end

    if opts[:with_follower?] do
      follower =
        trip_fixture(context.organization.id, context.version.id, context.route_10.route_id,
          trip_headsign: "Lincoln City",
          service_id: "WK",
          block_id: "B9"
        )
        |> trip_pattern_metadata_fixture(%{
          route_pattern_id: pattern.route_pattern_id,
          timed_pattern_id: weekday.id,
          pattern_derivation_state: "linked"
        })

      stop_time_fixture(
        context.organization.id,
        context.version.id,
        follower.trip_id,
        last_stop.stop_id,
        arrival_time: "18:16:00",
        departure_time: "18:16:00",
        stop_sequence: 1
      )

      "20"
      |> block_successor(context, block_id: "B9")
      |> tap(fn successor ->
        stop_time_fixture(
          context.organization.id,
          context.version.id,
          successor.trip_id,
          stop.stop_id,
          arrival_time: "18:22:00",
          departure_time: "18:22:00",
          stop_sequence: 1
        )
      end)
    end

    %{pattern: pattern, differing_trip: differing_trip}
  end

  defp block_successor(route_id, context, attrs \\ []) do
    # The next-block lookup joins routes for the successor's short name, so a
    # successor trip needs its route row to exist; only "10" comes with setup.
    unless Repo.get_by(Route,
             organization_id: context.organization.id,
             gtfs_version_id: context.version.id,
             route_id: route_id
           ) do
      route_fixture(context.organization.id, context.version.id,
        route_id: route_id,
        route_short_name: route_id
      )
    end

    trip_fixture(context.organization.id, context.version.id, route_id,
      trip_headsign: "Boston",
      service_id: "WK",
      block_id: Keyword.get(attrs, :block_id, "B1")
    )
  end
end
