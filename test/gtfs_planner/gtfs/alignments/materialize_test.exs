defmodule GtfsPlanner.Gtfs.Alignments.MaterializeTest do
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.Alignments.Materializer
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo

  defp audit_context(organization, version) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: Ecto.UUID.generate(),
      actor_email: "alignment-materialize@example.com"
    }
  end

  defp stop_with_coords(organization, version, stop_id, lat_s, lon_s) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: "Stop #{stop_id}",
      stop_lat: Decimal.new(lat_s),
      stop_lon: Decimal.new(lon_s)
    })
  end

  defp base_stops(organization, version) do
    stop_with_coords(organization, version, "A", "40.712800", "-74.006000")
    stop_with_coords(organization, version, "B", "40.713800", "-74.005000")
    stop_with_coords(organization, version, "C", "40.714800", "-74.004000")
  end

  defp routed_pattern(organization, version, route_id, pattern_id, stops) do
    route_fixture(organization.id, version.id, %{route_id: route_id})

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route_id,
        route_pattern_id: pattern_id
      })

    stops
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    Repo.reload!(pattern)
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

  defp insert_shape(organization, version, shape_id, sequence, lat_s, lon_s, dist_s) do
    %Shape{}
    |> Shape.changeset(%{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      shape_id: shape_id,
      shape_pt_sequence: sequence,
      shape_pt_lat: lat_s,
      shape_pt_lon: lon_s,
      shape_dist_traveled: dist_s
    })
    |> Repo.insert!()
  end

  defp link_trip(organization, version, pattern, trip_id, shape_id, dists) do
    timing = timed_pattern_fixture(pattern)

    trip =
      trip_fixture(organization.id, version.id, pattern.route_id, %{
        trip_id: trip_id,
        shape_id: shape_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })

    Enum.with_index(dists, 1)
    |> Enum.each(fn {dist, sequence} ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, "A", %{
        stop_sequence: sequence,
        shape_dist_traveled: dist
      })
    end)

    Repo.reload!(trip)
  end

  defp custom_trip(organization, version, pattern, trip_id, shape_id, dists) do
    trip =
      trip_fixture(organization.id, version.id, pattern.route_id, %{
        trip_id: trip_id,
        shape_id: shape_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: "stops_differ"
    })

    Enum.with_index(dists, 1)
    |> Enum.each(fn {dist, sequence} ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, "A", %{
        stop_sequence: sequence,
        shape_dist_traveled: dist
      })
    end)

    Repo.reload!(trip)
  end

  defp materialize!(organization, version, pattern) do
    resolved = Alignments.resolve(pattern)
    plan = Alignments.shape_plan(pattern, length(resolved.visits))
    audit = audit_context(organization, version)

    {:ok, result} =
      Repo.transaction(fn ->
        Alignments.materialize_pattern!(Repo.reload!(pattern), resolved, plan, audit)
      end)

    {result, resolved, plan}
  end

  defp shape_rows(organization, version, shape_id) do
    from(s in Shape,
      where:
        s.organization_id == ^organization.id and
          s.gtfs_version_id == ^version.id and
          s.shape_id == ^shape_id,
      order_by: [asc: s.shape_pt_sequence]
    )
    |> Repo.all()
  end

  defp visit_distances(pattern) do
    from(o in RoutePatternStop,
      where: o.route_pattern_id == ^pattern.id,
      order_by: [asc: o.position],
      select: o.shape_dist_traveled
    )
    |> Repo.all()
  end

  defp trip_stop_distances(organization, version, trip_id) do
    from(st in StopTime,
      where:
        st.organization_id == ^organization.id and
          st.gtfs_version_id == ^version.id and
          st.trip_id == ^trip_id,
      order_by: [asc: st.stop_sequence],
      select: st.shape_dist_traveled
    )
    |> Repo.all()
  end

  defp latest_shape_audit(organization, version, pattern) do
    from(cl in ChangeLog,
      where:
        cl.organization_id == ^organization.id and
          cl.gtfs_version_id == ^version.id and
          cl.entity_type == "pattern_shape" and
          cl.entity_id == ^pattern.id,
      order_by: [desc: cl.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  test "writes exact shape rows for a two-visit straight pattern" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    insert_shared(organization, version, "A", "B", [])

    {result, _resolved, plan} = materialize!(organization, version, pattern)

    assert plan.mode == :allocate
    assert result == %{shape_id: "P1", trips_updated: 0, shapes_deleted: []}

    rows = shape_rows(organization, version, "P1")
    assert length(rows) == 2

    [first, second] = rows
    assert first.shape_pt_sequence == 0
    assert first.shape_pt_lat == Decimal.new("40.712800")
    assert first.shape_pt_lon == Decimal.new("-74.006000")
    assert first.shape_dist_traveled == Decimal.new("0.00")
    assert second.shape_pt_sequence == 1
    assert second.shape_pt_lat == Decimal.new("40.713800")
    assert second.shape_pt_lon == Decimal.new("-74.005000")
    assert second.shape_dist_traveled == Decimal.new("139.53")
  end

  test "writes visit distances, pattern shape id and digest" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    insert_shared(organization, version, "A", "B", [])

    {_result, _resolved, _plan} = materialize!(organization, version, pattern)

    assert visit_distances(pattern) == [Decimal.new("0.00"), Decimal.new("139.53")]

    pattern = Repo.reload!(pattern)
    assert pattern.shape_id == "P1"

    assert {:ok, %{digest: expected_digest}} =
             Materializer.build(
               [%{lat: 40.7128, lon: -74.006}, %{lat: 40.7138, lon: -74.005}],
               [[]]
             )

    assert pattern.alignment_digest == expected_digest
  end

  test "linked trips take the shape with advanced updated_at; custom trips stay byte-equal" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    insert_shared(organization, version, "A", "B", [])

    linked =
      link_trip(organization, version, pattern, "T1", nil, [Decimal.new("0"), Decimal.new("1")])

    custom_before =
      custom_trip(organization, version, pattern, "CUSTOM", "ZC", [
        Decimal.new("7"),
        Decimal.new("9")
      ])

    custom_stops_before =
      from(st in StopTime,
        where:
          st.organization_id == ^organization.id and
            st.gtfs_version_id == ^version.id and
            st.trip_id == "CUSTOM",
        order_by: [asc: st.stop_sequence]
      )
      |> Repo.all()

    before_updated_at = linked.updated_at

    {result, _resolved, _plan} = materialize!(organization, version, pattern)

    assert result.trips_updated == 1
    assert result.shape_id == "P1"

    linked_after = Repo.reload!(linked)
    assert linked_after.shape_id == "P1"
    assert DateTime.compare(linked_after.updated_at, before_updated_at) == :gt

    assert Repo.reload!(custom_before) == custom_before

    custom_stops_after =
      from(st in StopTime,
        where:
          st.organization_id == ^organization.id and
            st.gtfs_version_id == ^version.id and
            st.trip_id == "CUSTOM",
        order_by: [asc: st.stop_sequence]
      )
      |> Repo.all()

    assert custom_stops_after == custom_stops_before
  end

  test "sparse stop sequences map to visit distances by position" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B", "C"])
    insert_shared(organization, version, "A", "B", [])
    insert_shared(organization, version, "B", "C", [])

    timing = timed_pattern_fixture(pattern)

    trip =
      trip_fixture(organization.id, version.id, pattern.route_id, %{
        trip_id: "SPARSE",
        shape_id: nil
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })

    for sequence <- [10, 20, 30] do
      stop_time_fixture(organization.id, version.id, trip.trip_id, "A", %{
        stop_sequence: sequence,
        shape_dist_traveled: nil
      })
    end

    {_result, _resolved, _plan} = materialize!(organization, version, pattern)

    expected = visit_distances(pattern)
    assert length(expected) == 3
    assert trip_stop_distances(organization, version, "SPARSE") == expected
  end

  test "adopted shapes are rewritten and audited with prior points" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    insert_shared(organization, version, "A", "B", [])

    insert_shape(organization, version, "X", 0, "40.100000", "-74.100000", "5.5")

    link_trip(organization, version, pattern, "T1", "X", [Decimal.new("0"), Decimal.new("5.5")])
    link_trip(organization, version, pattern, "T2", "X", [Decimal.new("0"), Decimal.new("5.5")])

    {result, _resolved, plan} = materialize!(organization, version, pattern)

    assert plan.mode == :adopt
    assert result == %{shape_id: "X", trips_updated: 2, shapes_deleted: []}

    rows = shape_rows(organization, version, "X")
    assert length(rows) == 2
    assert Enum.map(rows, & &1.shape_dist_traveled) == [Decimal.new("0.00"), Decimal.new("139.53")]

    audit = latest_shape_audit(organization, version, pattern)
    assert audit.action == "updated"
    assert audit.entity_external_id == "P1"

    replaced = audit.changed_fields["before"]["replaced_shapes"]
    assert [%{"shape_id" => "X", "trip_count" => 2, "action" => "adopted", "points" => points}] =
             replaced

    assert points == [[40.1, -74.1, 0, "5.5"]]

    previous = audit.changed_fields["before"]["previous"]
    assert [%{"shape_id" => "X", "trip_count" => 2, "visit_distances" => ["0", "5.5"]}] = previous

    after_shape = audit.changed_fields["after"]
    assert after_shape["shape_id"] == "X"
    assert after_shape["visit_distances"] == ["0.00", "139.53"]
  end

  test "deleted shapes vanish while shapes kept by other trips remain" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    insert_shared(organization, version, "A", "B", [])

    insert_shape(organization, version, "Y", 0, "40.100000", "-74.100000", "5.5")
    insert_shape(organization, version, "Z", 0, "40.200000", "-74.200000", "6.5")

    link_trip(organization, version, pattern, "T1", "Y", [Decimal.new("0"), Decimal.new("5.5")])
    link_trip(organization, version, pattern, "T2", "Z", [Decimal.new("0"), Decimal.new("6.5")])
    custom_trip(organization, version, pattern, "KEEPER", "Z", [Decimal.new("0"), Decimal.new("6.5")])

    {result, _resolved, plan} = materialize!(organization, version, pattern)

    assert plan.mode == :allocate
    assert result == %{shape_id: "P1", trips_updated: 2, shapes_deleted: ["Y"]}

    assert shape_rows(organization, version, "Y") == []

    [kept] = shape_rows(organization, version, "Z")
    assert kept.shape_pt_lat == Decimal.new("40.200000")
    assert kept.shape_dist_traveled == Decimal.new("6.5")

    audit = latest_shape_audit(organization, version, pattern)
    replaced = audit.changed_fields["before"]["replaced_shapes"]
    assert [%{"shape_id" => "Y", "trip_count" => 1, "action" => "deleted", "points" => points}] =
             replaced

    assert points == [[40.1, -74.1, 0, "5.5"]]
  end

  test "a plan with blockers rolls back and leaves rows unchanged" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
    insert_shared(organization, version, "A", "B", [])

    trip = link_trip(organization, version, pattern, "SHORT", nil, [Decimal.new("0")])

    resolved = Alignments.resolve(pattern)
    plan = Alignments.shape_plan(pattern, length(resolved.visits))
    assert plan.blockers != []
    audit = audit_context(organization, version)

    assert {:error, {:blocked, blockers}} =
             Repo.transaction(fn ->
               Alignments.materialize_pattern!(Repo.reload!(pattern), resolved, plan, audit)
             end)

    assert blockers == plan.blockers
    assert shape_rows(organization, version, plan.shape_id) == []
    assert Repo.reload!(trip).shape_id == nil
    assert trip_stop_distances(organization, version, "SHORT") == [Decimal.new("0")]
    assert visit_distances(pattern) == [nil, nil]
    assert Repo.reload!(pattern).shape_id == nil

    assert latest_shape_audit(organization, version, pattern) == nil
  end
end
