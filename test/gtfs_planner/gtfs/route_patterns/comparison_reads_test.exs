defmodule GtfsPlanner.Gtfs.RoutePatterns.ComparisonReadsTest do
  @moduledoc """
  Merge evidence (EV-1) for CL-11, establishing INV-1's pattern-lookup half:
  `timing_rows/2` reads one timing's rows without leaving the pattern, and
  `get_scoped_pattern/3` resolves a pattern only inside the organization, the
  version and a published route.

  Expected rows and offsets are the literal fixture values inserted below. The
  negative scopes insert a pattern with the same natural ID in another
  organization and in another version, so a query that dropped a scope filter
  would find those rows. The focused gate command is deferred to branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner/gtfs/route_patterns/comparison_reads_test.exs
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    Enum.each(
      [{"stop_alpha", "Alpha"}, {"stop_bravo", "Bravo"}, {"stop_charlie", "Charlie"}],
      fn {stop_id, stop_name} ->
        stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
      end
    )

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "pattern_reads"
      })

    alpha = route_pattern_stop_fixture(pattern, "stop_alpha", 1)
    bravo = route_pattern_stop_fixture(pattern, "stop_bravo", 2)
    charlie = route_pattern_stop_fixture(pattern, "stop_charlie", 3)

    timing = timed_pattern_fixture(pattern, %{name: "Weekday"})

    # Inserted out of position order so the read's ordering is observable.
    timed_pattern_stop_fixture(timing, charlie, %{
      arrival_offset: 600,
      departure_offset: 630,
      timepoint: 1,
      pickup_type: 0,
      drop_off_type: 3
    })

    timed_pattern_stop_fixture(timing, alpha, %{
      arrival_offset: 0,
      departure_offset: 30,
      timepoint: 1,
      pickup_type: 1,
      drop_off_type: 2,
      stop_headsign: "Alpha via Center"
    })

    timed_pattern_stop_fixture(timing, bravo, %{
      arrival_offset: 300,
      departure_offset: 330,
      timepoint: nil,
      pickup_type: 0,
      drop_off_type: 0
    })

    %{
      organization: organization,
      version: version,
      route: route,
      pattern: pattern,
      timing: timing,
      occurrences: %{alpha: alpha, bravo: bravo, charlie: charlie}
    }
  end

  test "timing_rows/2 returns the timing's rows ordered by position without :stop", context do
    rows = RoutePatterns.timing_rows(context.pattern, context.timing.id)

    assert Enum.map(rows, & &1.position) == [1, 2, 3]

    assert rows == [
             %{
               route_pattern_stop_id: context.occurrences.alpha.id,
               position: 1,
               stop_id: "stop_alpha",
               arrival_offset: 0,
               departure_offset: 30,
               timepoint: 1,
               pickup_type: 1,
               drop_off_type: 2,
               stop_headsign: "Alpha via Center"
             },
             %{
               route_pattern_stop_id: context.occurrences.bravo.id,
               position: 2,
               stop_id: "stop_bravo",
               arrival_offset: 300,
               departure_offset: 330,
               timepoint: nil,
               pickup_type: 0,
               drop_off_type: 0,
               stop_headsign: nil
             },
             %{
               route_pattern_stop_id: context.occurrences.charlie.id,
               position: 3,
               stop_id: "stop_charlie",
               arrival_offset: 600,
               departure_offset: 630,
               timepoint: 1,
               pickup_type: 0,
               drop_off_type: 3,
               stop_headsign: nil
             }
           ]

    refute Enum.any?(rows, &Map.has_key?(&1, :stop))
  end

  test "timing_rows/2 returns [] for a timing that belongs to another pattern", context do
    other_pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        route_pattern_id: "pattern_other"
      })

    other_occurrence = route_pattern_stop_fixture(other_pattern, "stop_other", 1)
    other_timing = timed_pattern_fixture(other_pattern, %{name: "Other timing"})

    timed_pattern_stop_fixture(other_timing, other_occurrence, %{
      arrival_offset: 60,
      departure_offset: 90
    })

    # The other timing's row exists, so the [] below cannot pass vacuously.
    assert [%{stop_id: "stop_other"}] =
             RoutePatterns.timing_rows(other_pattern, other_timing.id)

    assert RoutePatterns.timing_rows(context.pattern, other_timing.id) == []
    assert RoutePatterns.timing_rows(other_pattern, context.timing.id) == []
  end

  test "timing_rows/2 does not read a timing through a pattern with the same ID in another scope",
       context do
    sibling_version = gtfs_version_fixture(context.organization.id)
    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)

    for {organization, version} <- [
          {context.organization, sibling_version},
          {foreign_org, foreign_version}
        ] do
      duplicate =
        route_pattern_fixture(organization.id, version.id, %{
          route_id: context.route.route_id,
          route_pattern_id: context.pattern.route_pattern_id
        })

      route_pattern_stop_fixture(duplicate, "stop_alpha", 1)

      # The duplicate has the same pattern ID, so only its organization and
      # version keep it from reading the first scope's timing.
      assert RoutePatterns.timing_rows(duplicate, context.timing.id) == []
    end
  end

  test "get_scoped_pattern/3 finds a pattern on a second published route of the version",
       context do
    other_route = route_fixture(context.organization.id, context.version.id)

    other_pattern =
      route_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: other_route.route_id,
        route_pattern_id: "pattern_second_route"
      })

    assert {:ok, found} =
             RoutePatterns.get_scoped_pattern(
               context.organization.id,
               context.version.id,
               "pattern_second_route"
             )

    assert found.id == other_pattern.id
    assert found.route_id == other_route.route_id

    assert {:ok, %RoutePattern{id: own_id}} =
             RoutePatterns.get_scoped_pattern(
               context.organization.id,
               context.version.id,
               "pattern_reads"
             )

    assert own_id == context.pattern.id
  end

  test "get_scoped_pattern/3 rejects a pattern of another organization", context do
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    foreign_route = route_fixture(foreign_organization.id, foreign_version.id)

    foreign_pattern =
      route_pattern_fixture(foreign_organization.id, foreign_version.id, %{
        route_id: foreign_route.route_id,
        route_pattern_id: "pattern_foreign"
      })

    assert {:ok, %RoutePattern{id: foreign_id}} =
             RoutePatterns.get_scoped_pattern(
               foreign_organization.id,
               foreign_version.id,
               "pattern_foreign"
             )

    assert foreign_id == foreign_pattern.id

    assert {:error, :not_found} =
             RoutePatterns.get_scoped_pattern(
               context.organization.id,
               context.version.id,
               "pattern_foreign"
             )
  end

  test "get_scoped_pattern/3 rejects a pattern of another version", context do
    other_version = gtfs_version_fixture(context.organization.id)
    other_route = route_fixture(context.organization.id, other_version.id)

    other_pattern =
      route_pattern_fixture(context.organization.id, other_version.id, %{
        route_id: other_route.route_id,
        route_pattern_id: "pattern_other_version"
      })

    assert {:ok, %RoutePattern{id: other_id}} =
             RoutePatterns.get_scoped_pattern(
               context.organization.id,
               other_version.id,
               "pattern_other_version"
             )

    assert other_id == other_pattern.id

    assert {:error, :not_found} =
             RoutePatterns.get_scoped_pattern(
               context.organization.id,
               context.version.id,
               "pattern_other_version"
             )
  end

  test "get_scoped_pattern/3 rejects a pattern on an unpublished version", context do
    {:ok, staging} =
      Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

    staging_route = route_fixture(context.organization.id, staging.id)

    staging_pattern =
      route_pattern_fixture(context.organization.id, staging.id, %{
        route_id: staging_route.route_id,
        route_pattern_id: "pattern_staging"
      })

    # The row exists in the version; only the publication gate rejects it.
    assert %RoutePattern{id: staging_id} = Repo.get(RoutePattern, staging_pattern.id)
    assert staging_id == staging_pattern.id

    assert {:error, :not_found} =
             RoutePatterns.get_scoped_pattern(
               context.organization.id,
               staging.id,
               "pattern_staging"
             )
  end

  test "get_scoped_pattern/3 rejects an unknown route_pattern_id", context do
    assert {:error, :not_found} =
             RoutePatterns.get_scoped_pattern(
               context.organization.id,
               context.version.id,
               "pattern_unknown"
             )
  end

  test "pattern_screen/4 detail rows keep the attached stop", context do
    assert {:ok, screen} =
             RoutePatterns.pattern_screen(
               context.organization.id,
               context.version.id,
               context.route.route_id,
               pattern_id: "pattern_reads",
               timing_id: context.timing.id
             )

    rows = screen.detail.selected_timing_rows

    assert Enum.map(rows, & &1.position) == [1, 2, 3]

    assert [
             %Stop{stop_id: "stop_alpha"},
             %Stop{stop_id: "stop_bravo"},
             %Stop{stop_id: "stop_charlie"}
           ] = Enum.map(rows, & &1.stop)
  end
end
