defmodule GtfsPlanner.Gtfs.RoutePatterns.LeftOutTest do
  @moduledoc """
  The left-out reader counts trips left outside patterns per route and reason.

  Expected rows are literals from the North Coast Transit scenario in the
  trip-grouping prototype: 24 direction-less supplement trips and 2
  out-of-order trips on route 1, and one station-only trip on route 2. No
  production function computes an expected value.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  test "counts custom trips per route and reason, excluding linked and foreign rows", context do
    org_id = context.organization.id
    version_id = context.version.id

    insert_custom_trips(org_id, version_id, "1", "missing_direction", 24)
    insert_custom_trips(org_id, version_id, "1", "invalid_chronology", 2)
    insert_custom_trips(org_id, version_id, "2", "unusable_stops", 1)

    insert_linked_trip(context, "1")

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)
    insert_custom_trips(other_organization.id, other_version.id, "1", "missing_direction", 5)

    assert Gtfs.left_out_trips(org_id, version_id) == [
             %{route_id: "1", reason: "missing_direction", trip_count: 24},
             %{route_id: "1", reason: "invalid_chronology", trip_count: 2},
             %{route_id: "2", reason: "unusable_stops", trip_count: 1}
           ]
  end

  test "the route filter returns only that route's rows", context do
    org_id = context.organization.id
    version_id = context.version.id

    insert_custom_trips(org_id, version_id, "1", "missing_direction", 24)
    insert_custom_trips(org_id, version_id, "1", "invalid_chronology", 2)
    insert_custom_trips(org_id, version_id, "2", "unusable_stops", 1)

    assert Gtfs.left_out_trips(org_id, version_id, "1") == [
             %{route_id: "1", reason: "missing_direction", trip_count: 24},
             %{route_id: "1", reason: "invalid_chronology", trip_count: 2}
           ]

    assert Gtfs.left_out_trips(org_id, version_id, "2") == [
             %{route_id: "2", reason: "unusable_stops", trip_count: 1}
           ]
  end

  test "another version's custom trips are excluded", context do
    org_id = context.organization.id
    version_id = context.version.id

    insert_custom_trips(org_id, version_id, "1", "missing_direction", 24)
    insert_custom_trips(org_id, version_id, "2", "unusable_stops", 1)

    other_version = gtfs_version_fixture(org_id)
    insert_custom_trips(org_id, other_version.id, "1", "invalid_chronology", 3)

    assert Gtfs.left_out_trips(org_id, version_id) == [
             %{route_id: "1", reason: "missing_direction", trip_count: 24},
             %{route_id: "2", reason: "unusable_stops", trip_count: 1}
           ]
  end

  defp insert_custom_trips(organization_id, version_id, route_id, reason, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      for index <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          trip_id: "#{route_id}-#{reason}-#{System.unique_integer([:positive])}-#{index}",
          route_id: route_id,
          service_id: "WK",
          direction_id: 0,
          pattern_derivation_state: "custom",
          pattern_derivation_reason: reason,
          organization_id: organization_id,
          gtfs_version_id: version_id,
          inserted_at: now,
          updated_at: now
        }
      end

    {^count, nil} = Repo.insert_all(Trip, rows)
  end

  # A linked trip is the exclusion the reader must not count; the trips check
  # constraint requires a real timing and no reason, so it goes through the
  # pattern and timing fixtures.
  defp insert_linked_trip(context, route_id) do
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: route_id,
        direction_id: 0
      })

    timing = timed_pattern_fixture(pattern)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(Trip, [
        %{
          id: Ecto.UUID.generate(),
          trip_id: "#{route_id}-linked-#{System.unique_integer([:positive])}",
          route_id: route_id,
          service_id: "WK",
          direction_id: 0,
          route_pattern_id: pattern.route_pattern_id,
          timed_pattern_id: timing.id,
          pattern_derivation_state: "linked",
          pattern_derivation_reason: nil,
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          inserted_at: now,
          updated_at: now
        }
      ])

    pattern
  end
end
