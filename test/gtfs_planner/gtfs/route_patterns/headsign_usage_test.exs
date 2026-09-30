defmodule GtfsPlanner.Gtfs.RoutePatterns.HeadsignUsageTest do
  @moduledoc """
  Focused coverage for the scoped headsign usage read model (EV-3): the School
  days shielding counterexample, the timing scope, `timings_carry` for a nil
  pattern headsign, `from` splitting, cross-organization scoping, import-shaped
  padded values and the usage trip contract shape.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup do
    organization =
      organization_fixture(%{alias: "headsign-usage-#{System.system_time(:nanosecond)}"})

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    %{organization: organization, version: version, route: route}
  end

  test "pattern scope counts followers, the padded import value and the typo with School days shielded",
       context do
    %{pattern: pattern} = lincoln_pattern(context)

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    assert usage.scope == :pattern
    assert usage.default == "Lincoln City"
    assert usage.total == 5
    assert usage.same == 4
    assert usage.differ == 1

    # Only the shielded timing's two trips are excluded; a timing with its own
    # headsign but no trips shields nothing.
    assert [
             %{
               timing_id: _school,
               name: "School days",
               headsign: "Lincoln City via Taft High",
               trip_count: 2
             }
           ] = usage.shielded

    assert usage.timings_carry == []
  end

  test "pattern scope groups list the likely typo first and exclude followers", context do
    %{pattern: pattern, typo_trip: typo_trip, padded_id: padded_id} =
      lincoln_pattern(context)

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    typo_id = typo_trip.id

    assert [
             %{
               value: "Lincoln city",
               kind: :case_or_spacing,
               likely_typo: true,
               trips: [%{id: ^typo_id}]
             }
           ] = usage.groups

    # Followers of the default (including the import-shaped padded value) are
    # not part of any group.
    refute Enum.any?(usage.groups, &(&1.value == "Lincoln City"))

    group_trip_ids = Enum.flat_map(usage.groups, fn group -> Enum.map(group.trips, & &1.id) end)

    refute padded_id in group_trip_ids
  end

  test "timing scope counts only the timing's trips under its own default", context do
    %{pattern: pattern, school: school} = lincoln_pattern(context)

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               {:timing, school.id}
             )

    assert usage.scope == {:timing, school.id}
    assert usage.default == "Lincoln City via Taft High"
    assert usage.total == 2
    assert usage.same == 2
    assert usage.differ == 0
    assert usage.groups == []
    assert usage.shielded == []
    assert usage.timings_carry == []
  end

  test "a nil pattern headsign lists the timings carrying the headsign", context do
    # Import-shaped data: the pattern headsign stays nil and the derived timing
    # carries the modal headsign of its trips.
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "HS-IMPORT",
        headsign: nil
      })

    weekday = timed_pattern_fixture(pattern, %{name: "Weekday base", headsign: "Lincoln City"})

    five_lincoln_trips(context, pattern, weekday)

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    assert usage.default == nil

    assert [
             %{name: "Weekday base", headsign: "Lincoln City", trip_count: 5} = carrying
           ] = usage.timings_carry

    assert carrying.timing_id == weekday.id

    # The carrying timing also shields its trips from the pattern scope, so the
    # pattern scope itself is empty.
    assert [%{name: "Weekday base", trip_count: 5}] = usage.shielded
    assert usage.total == 0
    assert usage.same == 0
    assert usage.differ == 0
    assert usage.groups == []
  end

  test "opts from: splits the followers into a first :follows group", context do
    %{pattern: pattern} = lincoln_pattern(context)

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern,
               from: "Lincoln City"
             )

    assert [
             %{kind: :follows, value: "Lincoln City", likely_typo: false, trips: followers},
             %{value: "Lincoln city", likely_typo: true}
           ] = usage.groups

    # Three exact followers plus the import-shaped padded value follow the old
    # default after normalization.
    assert length(followers) == 4
    assert usage.same == 4
    assert usage.differ == 1
  end

  test "a trip with the same route_pattern_id in another organization is not counted", context do
    %{pattern: pattern} = lincoln_pattern(context)

    foreign_organization =
      organization_fixture(%{alias: "headsign-usage-other-#{System.system_time(:nanosecond)}"})

    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_route = route_fixture(foreign_organization.id, foreign_version.id)

    trip_fixture(foreign_organization.id, foreign_version.id, foreign_route.route_id,
      trip_headsign: "Lincoln City",
      route_pattern_id: pattern.route_pattern_id
    )

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    assert usage.total == 5
    assert usage.same == 4
    assert usage.differ == 1
  end

  test "an unknown pattern id and a foreign timing scope return :not_found", context do
    %{pattern: pattern} = lincoln_pattern(context)

    assert Gtfs.headsign_usage(
             context.organization.id,
             context.version.id,
             Ecto.UUID.generate(),
             :pattern
           ) == {:error, :not_found}

    assert Gtfs.headsign_usage(
             context.organization.id,
             context.version.id,
             pattern.id,
             {:timing, Ecto.UUID.generate()}
           ) == {:error, :not_found}
  end

  test "usage trips carry the contract shape with parsed first departure and timing name",
       context do
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "HS-SHAPE",
        headsign: "Lincoln City"
      })

    weekday = timed_pattern_fixture(pattern, %{name: "Weekday base"})
    stop = stop_fixture(context.organization.id, context.version.id)

    linked =
      trip_fixture(context.organization.id, context.version.id, context.route.route_id,
        trip_headsign: "Lincoln City"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: weekday.id,
        pattern_derivation_state: "linked"
      })

    custom =
      trip_fixture(context.organization.id, context.version.id, context.route.route_id,
        trip_headsign: "Downtown"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        pattern_derivation_state: "custom",
        pattern_derivation_reason: "missing_route"
      })

    stop_time_fixture(context.organization.id, context.version.id, linked.trip_id, stop.stop_id,
      arrival_time: "08:05:00",
      departure_time: "08:05:00",
      stop_sequence: 1
    )

    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern,
               from: "Lincoln City"
             )

    assert [%{kind: :follows, trips: [follower]}, %{kind: :other, trips: [other]}] =
             usage.groups

    assert follower.id == linked.id
    assert follower.trip_id == linked.trip_id
    assert follower.headsign == "Lincoln City"
    assert follower.service_id == linked.service_id
    assert follower.departure_secs == 8 * 3_600 + 5 * 60
    assert follower.timing_name == "Weekday base"
    assert follower.custom? == false
    assert follower.next_block == nil
    assert follower.mid_trip_change == nil

    assert other.id == custom.id
    assert other.headsign == "Downtown"
    assert other.custom? == true
    assert other.timing_name == nil
    assert other.departure_secs == nil
  end

  test "blank and other differing values group without typo flags", context do
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "HS-BLANK",
        headsign: "Lincoln City"
      })

    weekday = timed_pattern_fixture(pattern, %{name: "Weekday base"})

    trip_fixture(context.organization.id, context.version.id, context.route.route_id,
      trip_headsign: "Lincoln City"
    )
    |> trip_pattern_metadata_fixture(%{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: weekday.id,
      pattern_derivation_state: "linked"
    })

    trip_fixture(context.organization.id, context.version.id, context.route.route_id,
      trip_headsign: " "
    )
    |> trip_pattern_metadata_fixture(%{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: weekday.id,
      pattern_derivation_state: "linked"
    })

    trip_fixture(context.organization.id, context.version.id, context.route.route_id,
      trip_headsign: "Roads End via Lincoln City"
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

    assert usage.same == 1
    assert usage.differ == 2

    assert [
             %{value: nil, kind: :blank, likely_typo: false},
             %{value: "Roads End via Lincoln City", kind: :other, likely_typo: false}
           ] = usage.groups
  end

  # The card's School days counterexample: the pattern headsign "Lincoln City"
  # with a Weekday base timing that has no own headsign and five trips (three
  # exact, one import-shaped padded value, one case-only typo), a School days
  # timing with its own headsign and two shielded trips, and a tripless timing
  # with its own headsign.
  defp lincoln_pattern(context) do
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "HS-LINCOLN",
        headsign: "Lincoln City"
      })

    weekday = timed_pattern_fixture(pattern, %{name: "Weekday base"})

    school =
      timed_pattern_fixture(pattern, %{
        name: "School days",
        headsign: "Lincoln City via Taft High"
      })

    # Own headsign but no trips: it neither shields nor carries anything.
    timed_pattern_fixture(pattern, %{name: "Zero trips", headsign: "Somewhere Else"})

    trips = five_lincoln_trips(context, pattern, weekday)
    padded_trip = Map.fetch!(trips, :padded)
    typo_trip = Map.fetch!(trips, :typo)

    for _ <- 1..2 do
      trip_fixture(context.organization.id, context.version.id, context.route.route_id,
        trip_headsign: "Lincoln City via Taft High"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: school.id,
        pattern_derivation_state: "linked"
      })
    end

    %{
      pattern: pattern,
      weekday: weekday,
      school: school,
      padded_trip: padded_trip,
      typo_trip: typo_trip,
      padded_id: padded_trip.id
    }
  end

  defp five_lincoln_trips(context, pattern, timing) do
    for _ <- 1..3 do
      trip_fixture(context.organization.id, context.version.id, context.route.route_id,
        trip_headsign: "Lincoln City"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
    end

    padded_trip = imported_trip(context, pattern, timing, " Lincoln City")

    typo_trip =
      trip_fixture(context.organization.id, context.version.id, context.route.route_id,
        trip_headsign: "Lincoln city"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })

    %{padded: padded_trip, typo: typo_trip}
  end

  # Import stores headsigns untrimmed through insert_all, so the padded value
  # bypasses the Trip changeset trimming exactly like a real import.
  defp imported_trip(context, pattern, timing, headsign) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: Ecto.UUID.generate(),
      trip_id: "trip_import_#{System.unique_integer([:positive])}",
      route_id: context.route.route_id,
      service_id: "WK",
      direction_id: 0,
      trip_headsign: headsign,
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked",
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      inserted_at: now,
      updated_at: now
    }

    {1, _} = Repo.insert_all(Trip, [row])

    Repo.get!(Trip, row.id)
  end
end
