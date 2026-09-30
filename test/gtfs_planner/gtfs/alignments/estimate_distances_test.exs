defmodule GtfsPlanner.Gtfs.Alignments.EstimateDistancesTest do
  # Spec 23 step 10 (AC-19, R13): cumulative editor metres per visit from
  # `Alignments.resolve/1` output. Literal Newport-area (Oregon coast)
  # coordinates pin the `[lon, lat]` section order against a `{lat, lon}`
  # swap: Lincoln City 44.9596/-124.0178, Depoe Bay 44.8082/-124.0615,
  # Newport–Nye Beach 44.6309/-124.0586.
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.Alignments.Materializer
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

  defp newport_stops(organization, version) do
    stop_with_coords(organization, version, "LC", "44.959600", "-124.017800")
    stop_with_coords(organization, version, "DB", "44.808200", "-124.061500")
    stop_with_coords(organization, version, "NW", "44.630900", "-124.058600")
  end

  defp setup_pattern(organization, version, stop_ids) do
    pattern = route_pattern_fixture(organization.id, version.id, %{route_id: "R1"})

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  test "a fully drawn pattern returns 0 then cumulative length_m over [from] ++ points ++ [to]" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    newport_stops(organization, version)
    pattern = setup_pattern(organization, version, ["LC", "DB", "NW"])

    points_ab = [[-124.040000, 44.880000]]
    points_bc = [[-124.060000, 44.710000]]
    insert_shared(organization, version, "LC", "DB", points_ab)
    insert_shared(organization, version, "DB", "NW", points_bc)

    resolved = Alignments.resolve(pattern)
    assert [s1, s2] = resolved.sections
    assert s1.kind == :shared
    assert s2.kind == :shared

    expected_ab =
      Materializer.length_m([[-124.017800, 44.959600]] ++ points_ab ++ [[-124.061500, 44.808200]])

    expected_bc =
      Materializer.length_m([[-124.061500, 44.808200]] ++ points_bc ++ [[-124.058600, 44.630900]])

    assert [d1, d2, d3] = Alignments.estimate_distances(resolved)
    assert d1 == 0.0
    assert_in_delta d2, expected_ab, 0.01
    assert_in_delta d3, expected_ab + expected_bc, 0.01
  end

  test "a :missing section contributes the straight line between its visits" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    newport_stops(organization, version)
    pattern = setup_pattern(organization, version, ["LC", "DB", "NW"])

    resolved = Alignments.resolve(pattern)
    assert Enum.all?(resolved.sections, &(&1.kind == :missing))

    straight_ab = Materializer.length_m([[-124.017800, 44.959600], [-124.061500, 44.808200]])
    straight_bc = Materializer.length_m([[-124.061500, 44.808200], [-124.058600, 44.630900]])

    assert [d1, d2, d3] = Alignments.estimate_distances(resolved)
    assert d1 == 0.0
    assert_in_delta d2, straight_ab, 0.01
    assert_in_delta d3, straight_ab + straight_bc, 0.01
  end

  test "a :zero_length section contributes 0 m and later visits keep true differences" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    newport_stops(organization, version)
    # DB2 shares Depoe Bay's coordinates: a real 0 m hop.
    stop_with_coords(organization, version, "DB2", "44.808200", "-124.061500")
    pattern = setup_pattern(organization, version, ["LC", "DB", "DB2", "NW"])

    resolved = Alignments.resolve(pattern)
    assert [s1, s2, s3] = resolved.sections
    assert s1.kind == :missing
    assert s2.kind == :blocked
    assert s2.blocked_reason == :zero_length
    assert s3.kind == :missing

    straight_ab = Materializer.length_m([[-124.017800, 44.959600], [-124.061500, 44.808200]])
    straight_dn = Materializer.length_m([[-124.061500, 44.808200], [-124.058600, 44.630900]])

    assert [d1, d2, d3, d4] = Alignments.estimate_distances(resolved)
    assert d1 == 0.0
    assert_in_delta d2, straight_ab, 0.01
    assert_in_delta d3, d2, 0.01
    assert_in_delta d4 - d3, straight_dn, 0.01
  end

  test "a visit without coordinates is nil and later visits bridge the gap" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    newport_stops(organization, version)
    # No Stop row for "XX": the visit carries nil coordinates.
    pattern = setup_pattern(organization, version, ["LC", "XX", "DB", "NW"])

    resolved = Alignments.resolve(pattern)

    assert [_lc_lat, nil, _db_lat, _nw_lat] =
             Enum.map(resolved.visits, & &1.lat)

    bridge = Materializer.length_m([[-124.017800, 44.959600], [-124.061500, 44.808200]])
    straight_bn = Materializer.length_m([[-124.061500, 44.808200], [-124.058600, 44.630900]])

    assert [d1, d2, d3, d4] = Alignments.estimate_distances(resolved)
    assert d1 == 0.0
    assert d2 == nil
    assert_in_delta d3, bridge, 0.01
    assert_in_delta d4 - d3, straight_bn, 0.01
  end

  test "section coordinates are read as [lon, lat] and never swapped" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    newport_stops(organization, version)
    pattern = setup_pattern(organization, version, ["LC", "DB"])

    points = [[-124.040000, 44.880000]]
    insert_shared(organization, version, "LC", "DB", points)

    resolved = Alignments.resolve(pattern)

    expected =
      Materializer.length_m([[-124.017800, 44.959600]] ++ points ++ [[-124.061500, 44.808200]])

    swapped =
      Materializer.length_m(
        [[44.959600, -124.017800]] ++ [[44.880000, -124.040000]] ++ [[44.808200, -124.061500]]
      )

    assert abs(swapped - expected) > 100.0

    assert [_d1, d2] = Alignments.estimate_distances(resolved)
    assert_in_delta d2, expected, 0.01
    refute_in_delta d2, swapped, 0.01
  end
end
