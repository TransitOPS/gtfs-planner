defmodule GtfsPlanner.Gtfs.RoutePatterns.HeadsignCountsTest do
  @moduledoc """
  Focused coverage for the differing-headsign counts on pattern summaries
  (EV-5): the five-trip literal through `Gtfs.load_route_pattern_screen/4`,
  shielded timing trips that follow their own default, and per-summary
  attribution through the default `CatalogReadAdapter.Repo` read adapter.
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
      organization_fixture(%{alias: "headsign-counts-#{System.system_time(:nanosecond)}"})

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    %{organization: organization, version: version, route: route}
  end

  test "a pattern with five trips counts three differing headsigns and one likely typo",
       context do
    pattern = five_trip_pattern(context)

    assert {:ok, screen} =
             Gtfs.load_route_pattern_screen(
               context.organization.id,
               context.version.id,
               context.route.route_id
             )

    assert [%{id: id, headsign_differ_count: 3, headsign_typo_count: 1}] = screen.patterns
    assert id == pattern.route_pattern_id

    # The summary and the usage read model apply one rule: with no carrying
    # timing holding trips, both scopes cover the same five trips.
    assert {:ok, usage} =
             Gtfs.headsign_usage(
               context.organization.id,
               context.version.id,
               pattern.id,
               :pattern
             )

    assert usage.differ == 3
  end

  test "trips on a timing with its own headsign that follow it add nothing to headsign_differ_count",
       context do
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "HS-COUNT-SHIELD",
        headsign: "Lincoln City"
      })

    school =
      timed_pattern_fixture(pattern, %{
        name: "School days",
        headsign: "Lincoln City via Taft High"
      })

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

    assert {:ok, screen} =
             Gtfs.load_route_pattern_screen(
               context.organization.id,
               context.version.id,
               context.route.route_id
             )

    assert [%{headsign_differ_count: 0, headsign_typo_count: 0}] = screen.patterns
  end

  test "a shielded trip differing from its timing's own headsign counts once against that default",
       context do
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "HS-COUNT-SHIELD-DIFF",
        headsign: "Lincoln City"
      })

    school =
      timed_pattern_fixture(pattern, %{
        name: "School days",
        headsign: "Lincoln City via Taft High"
      })

    # Follows the timing's default: not counted.
    trip_fixture(context.organization.id, context.version.id, context.route.route_id,
      trip_headsign: "Lincoln City via Taft High"
    )
    |> trip_pattern_metadata_fixture(%{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: school.id,
      pattern_derivation_state: "linked"
    })

    # A case-only slip against the timing's default: the one likely typo.
    trip_fixture(context.organization.id, context.version.id, context.route.route_id,
      trip_headsign: "Lincoln City via Taft high"
    )
    |> trip_pattern_metadata_fixture(%{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: school.id,
      pattern_derivation_state: "linked"
    })

    assert {:ok, screen} =
             Gtfs.load_route_pattern_screen(
               context.organization.id,
               context.version.id,
               context.route.route_id
             )

    assert [%{headsign_differ_count: 1, headsign_typo_count: 1}] = screen.patterns
  end

  test "load_route_pattern_screen attributes the counts per summary through CatalogReadAdapter.Repo",
       context do
    differing =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "HS-COUNT-A",
        headsign: "Lincoln City"
      })

    weekday = timed_pattern_fixture(differing, %{name: "Weekday base"})

    # One typo and one other-value trip on the first pattern.
    trip_fixture(context.organization.id, context.version.id, context.route.route_id,
      trip_headsign: "Lincoln city"
    )
    |> trip_pattern_metadata_fixture(%{
      route_pattern_id: differing.route_pattern_id,
      timed_pattern_id: weekday.id,
      pattern_derivation_state: "linked"
    })

    trip_fixture(context.organization.id, context.version.id, context.route.route_id,
      trip_headsign: "Roads End"
    )
    |> trip_pattern_metadata_fixture(%{
      route_pattern_id: differing.route_pattern_id,
      timed_pattern_id: weekday.id,
      pattern_derivation_state: "linked"
    })

    clean =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "HS-COUNT-B",
        headsign: "Boston"
      })

    for _ <- 1..2 do
      trip_fixture(context.organization.id, context.version.id, context.route.route_id,
        trip_headsign: "Boston"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: clean.route_pattern_id,
        timed_pattern_id: weekday.id,
        pattern_derivation_state: "linked"
      })
    end

    assert {:ok, screen} =
             Gtfs.load_route_pattern_screen(
               context.organization.id,
               context.version.id,
               context.route.route_id
             )

    assert [
             %{id: "HS-COUNT-A", headsign_differ_count: 2, headsign_typo_count: 1},
             %{id: "HS-COUNT-B", headsign_differ_count: 0, headsign_typo_count: 0}
           ] = screen.patterns
  end

  test "the counts scope to the organization and version", context do
    pattern = five_trip_pattern(context)

    foreign_organization =
      organization_fixture(%{alias: "headsign-counts-other-#{System.system_time(:nanosecond)}"})

    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_route = route_fixture(foreign_organization.id, foreign_version.id)

    trip_fixture(foreign_organization.id, foreign_version.id, foreign_route.route_id,
      trip_headsign: "Lincoln city",
      route_pattern_id: pattern.route_pattern_id
    )

    assert {:ok, screen} =
             Gtfs.load_route_pattern_screen(
               context.organization.id,
               context.version.id,
               context.route.route_id
             )

    assert [%{headsign_differ_count: 3, headsign_typo_count: 1}] = screen.patterns
  end

  # The card's five-trip literal: a padded follower inserted through insert_all
  # (the import path stores headsigns untrimmed), an exact follower, a
  # case-only typo, a different destination and a nil headsign, under the
  # pattern headsign "Lincoln City".
  defp five_trip_pattern(context) do
    pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "HS-COUNT-LITERAL",
        headsign: "Lincoln City"
      })

    weekday = timed_pattern_fixture(pattern, %{name: "Weekday base"})

    imported_trip(context, pattern, weekday, " Lincoln City")
    linked_trip(context, pattern, weekday, "Lincoln City")
    linked_trip(context, pattern, weekday, "Lincoln city")
    linked_trip(context, pattern, weekday, "Roads End via Lincoln City")
    linked_trip(context, pattern, weekday, nil)

    pattern
  end

  defp linked_trip(context, pattern, timing, headsign) do
    trip_fixture(context.organization.id, context.version.id, context.route.route_id,
      trip_headsign: headsign
    )
    |> trip_pattern_metadata_fixture(%{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })
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
