defmodule GtfsPlanner.Gtfs.Alignments.RouteSummaryTest do
  # async: false — the query-count case attaches a process-wide :telemetry
  # handler, so concurrently running tests would inflate its counts.
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Repo

  defp stop_with_coords(organization, version, stop_id, lat_s, lon_s) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: "Stop #{stop_id}",
      stop_lat: Decimal.new(lat_s),
      stop_lon: Decimal.new(lon_s)
    })
  end

  defp insert_shared(organization, version, from_id, to_id, points) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_id,
      to_stop_id: to_id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  defp base_stops(organization, version) do
    stop_with_coords(organization, version, "A", "40.712800", "-74.006000")
    stop_with_coords(organization, version, "B", "40.713800", "-74.005000")
    stop_with_coords(organization, version, "C", "40.714800", "-74.004000")
  end

  defp link_imported_shape(organization, version, pattern, natural_id, trip_id, shape_id) do
    timing = timed_pattern_fixture(pattern)

    trip =
      trip_fixture(organization.id, version.id, pattern.route_id, %{
        trip_id: trip_id,
        shape_id: shape_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: natural_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })
  end

  defp count_queries(fun) do
    test_pid = self()
    handler_id = "route-summary-queries-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:gtfs_planner, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {handler_id, metadata.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain_queries(handler_id, 0)}
  end

  defp drain_queries(handler_id, count) do
    receive do
      {^handler_id, _query} -> drain_queries(handler_id, count + 1)
    after
      0 -> count
    end
  end

  test "each state matches resolve/1 with missing positions" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    stop_fixture(organization.id, version.id, %{stop_id: "N", stop_lat: nil, stop_lon: nil})
    insert_shared(organization, version, "A", "B", [])
    insert_shared(organization, version, "B", "C", [])

    missing_pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_pattern_id: "P-missing"
      })

    route_pattern_stop_fixture(missing_pattern, "C", 1)
    # No shared row covers C -> D or D -> A, so both sections stay missing.
    stop_with_coords(organization, version, "D", "40.715800", "-74.003000")
    route_pattern_stop_fixture(missing_pattern, "D", 2)
    route_pattern_stop_fixture(missing_pattern, "A", 3)

    blocked_pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_pattern_id: "P-blocked"
      })

    route_pattern_stop_fixture(blocked_pattern, "A", 1)
    route_pattern_stop_fixture(blocked_pattern, "N", 2)
    route_pattern_stop_fixture(blocked_pattern, "C", 3)

    current_pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_pattern_id: "P-current"
      })

    route_pattern_stop_fixture(current_pattern, "A", 1)
    route_pattern_stop_fixture(current_pattern, "B", 2)
    %{digest: digest} = Alignments.resolve(current_pattern)

    current_pattern
    |> Ecto.Changeset.change(%{shape_id: "P-current", alignment_digest: digest})
    |> Repo.update!()

    stale_pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_pattern_id: "P-stale"
      })

    route_pattern_stop_fixture(stale_pattern, "A", 1)
    route_pattern_stop_fixture(stale_pattern, "B", 2)

    stale_pattern
    |> Ecto.Changeset.change(%{shape_id: "P-stale", alignment_digest: "0"})
    |> Repo.update!()

    imported_pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_pattern_id: "P-imported"
      })

    route_pattern_stop_fixture(imported_pattern, "A", 1)
    route_pattern_stop_fixture(imported_pattern, "B", 2)
    link_imported_shape(organization, version, imported_pattern, "P-imported", "T-imp", "IMP-1")

    none_pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_pattern_id: "P-none"
      })

    route_pattern_stop_fixture(none_pattern, "A", 1)
    route_pattern_stop_fixture(none_pattern, "B", 2)

    summary = Alignments.route_summary(organization.id, version.id, "R1")
    assert map_size(summary) == 6

    assert summary["P-missing"] == %{
             missing: 2,
             blocked: 0,
             export: :none,
             missing_positions: [1, 2]
           }

    patterns = %{
      "P-missing" => missing_pattern,
      "P-blocked" => blocked_pattern,
      "P-current" => Repo.get!(current_pattern.__struct__, current_pattern.id),
      "P-stale" => Repo.get!(stale_pattern.__struct__, stale_pattern.id),
      "P-imported" => imported_pattern,
      "P-none" => none_pattern
    }

    for {natural_id, pattern} <- patterns do
      %{sections: sections, status: status} = Alignments.resolve(pattern)
      entry = summary[natural_id]

      assert entry.missing == status.missing
      assert entry.blocked == status.blocked
      assert entry.export == status.export

      expected_missing =
        for section <- sections, section.kind == :missing, do: section.position

      assert entry.missing_positions == expected_missing
    end
  end

  test "query count is the same for one pattern and five patterns" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    insert_shared(organization, version, "A", "B", [])

    solo =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "RQ1",
        route_pattern_id: "P-solo"
      })

    route_pattern_stop_fixture(solo, "A", 1)
    route_pattern_stop_fixture(solo, "B", 2)

    for n <- 1..5 do
      pattern =
        route_pattern_fixture(organization.id, version.id, %{
          route_id: "RQ5",
          route_pattern_id: "P-five-#{n}"
        })

      route_pattern_stop_fixture(pattern, "A", 1)
      route_pattern_stop_fixture(pattern, "B", 2)
    end

    {solo_summary, solo_count} =
      count_queries(fn -> Alignments.route_summary(organization.id, version.id, "RQ1") end)

    {five_summary, five_count} =
      count_queries(fn -> Alignments.route_summary(organization.id, version.id, "RQ5") end)

    assert map_size(solo_summary) == 1
    assert map_size(five_summary) == 5
    assert solo_count == five_count
    assert solo_count == 5
  end

  test "another organization's or version's rows do not affect the result" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    insert_shared(organization, version, "A", "B", [])

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R9", route_pattern_id: "P1"})

    route_pattern_stop_fixture(pattern, "A", 1)
    route_pattern_stop_fixture(pattern, "B", 2)

    before_summary = Alignments.route_summary(organization.id, version.id, "R9")

    other_organization = organization_fixture()
    other_org_version = gtfs_version_fixture(other_organization.id)
    other_version = gtfs_version_fixture(organization.id)

    insert_shared(other_organization, other_org_version, "A", "B", [[0.0, 0.0]])
    insert_shared(organization, other_version, "A", "B", [[1.0, 1.0]])

    other_org_pattern =
      route_pattern_fixture(other_organization.id, other_org_version.id, %{
        route_id: "R9",
        route_pattern_id: "P1"
      })

    route_pattern_stop_fixture(other_org_pattern, "A", 1)
    route_pattern_stop_fixture(other_org_pattern, "B", 2)

    other_version_pattern =
      route_pattern_fixture(organization.id, other_version.id, %{
        route_id: "R9",
        route_pattern_id: "P1"
      })

    route_pattern_stop_fixture(other_version_pattern, "A", 1)
    route_pattern_stop_fixture(other_version_pattern, "B", 2)

    assert Alignments.route_summary(organization.id, version.id, "R9") == before_summary
    assert map_size(before_summary) == 1

    assert map_size(Alignments.route_summary(organization.id, other_version.id, "R9")) == 1

    assert map_size(Alignments.route_summary(other_organization.id, other_org_version.id, "R9")) ==
             1
  end
end
