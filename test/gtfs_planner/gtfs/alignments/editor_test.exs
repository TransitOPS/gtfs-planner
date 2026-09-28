defmodule GtfsPlanner.Gtfs.Alignments.EditorTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.Alignments.Materializer
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

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

  defp insert_override(organization, version, occurrence, from_id, to_id, points) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_id,
      to_stop_id: to_id,
      from_occurrence_id: occurrence.id
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

  defp link_trip(organization, version, pattern, timing, trip_id, shape_id, dists) do
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

    trip
  end

  defp base_stops(organization, version) do
    stop_with_coords(organization, version, "A", "40.712800", "-74.006000")
    stop_with_coords(organization, version, "B", "40.713800", "-74.005000")
    stop_with_coords(organization, version, "C", "40.714800", "-74.004000")
  end

  test "unknown, foreign and staging scopes return not_found" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    route_fixture(organization.id, version.id, %{route_id: "R1"})

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    route_pattern_stop_fixture(pattern, "A", 1)
    route_pattern_stop_fixture(pattern, "B", 2)

    assert {:error, :not_found} = Gtfs.alignment_editor(organization.id, version.id, "NOPE", "P1")
    assert {:error, :not_found} = Gtfs.alignment_editor(organization.id, version.id, "R1", "NOPE")

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)

    assert {:error, :not_found} =
             Gtfs.alignment_editor(other_organization.id, other_version.id, "R1", "P1")

    {:ok, staging} =
      Versions.create_staging_gtfs_version(organization.id, %{
        name: "Staging #{System.unique_integer()}"
      })

    assert {:error, :not_found} = Gtfs.alignment_editor(organization.id, staging.id, "R1", "P1")
  end

  test "route colours fall back for light or missing values" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    cases = [
      {"0000FF", "#0000FF"},
      {"FFFFFF", "#334155"},
      {"FFFF99", "#334155"},
      {nil, "#334155"}
    ]

    for {{color, expected}, index} <- Enum.with_index(cases) do
      route_id = "RC#{index}"

      route_fixture(organization.id, version.id, %{route_id: route_id, route_color: color})

      pattern =
        route_pattern_fixture(organization.id, version.id, %{
          route_id: route_id,
          route_pattern_id: "PC#{index}"
        })

      route_pattern_stop_fixture(pattern, "A", 1)
      route_pattern_stop_fixture(pattern, "B", 2)

      assert {:ok, model} =
               Gtfs.alignment_editor(organization.id, version.id, route_id, "PC#{index}")

      assert model.route_color == expected
    end
  end

  test "loop visits share labels across traversals" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    route_fixture(organization.id, version.id, %{route_id: "R1"})

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    route_pattern_stop_fixture(pattern, "A", 1)
    route_pattern_stop_fixture(pattern, "B", 2)
    route_pattern_stop_fixture(pattern, "C", 3)
    route_pattern_stop_fixture(pattern, "A", 4)
    route_pattern_stop_fixture(pattern, "B", 5)

    assert {:ok, model} = Gtfs.alignment_editor(organization.id, version.id, "R1", "P1")

    by_position = Map.new(model.visits, fn visit -> {visit.position, visit.label} end)

    assert by_position[1] == "1 / 4"
    assert by_position[4] == "1 / 4"
    assert by_position[2] == "2 / 5"
    assert by_position[5] == "2 / 5"
    assert by_position[3] == "3"
  end

  test "overrides carry shared_points and shared sections carry shared_users" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    route_fixture(organization.id, version.id, %{route_id: "R1"})

    p1 =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    first = route_pattern_stop_fixture(p1, "A", 1)
    route_pattern_stop_fixture(p1, "B", 2)
    route_pattern_stop_fixture(p1, "C", 3)

    p2 =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P2"})

    route_pattern_stop_fixture(p2, "B", 1)
    route_pattern_stop_fixture(p2, "C", 2)

    insert_shared(organization, version, "A", "B", [[-74.005700, 40.713000]])
    insert_shared(organization, version, "B", "C", [[-74.004500, 40.714000]])
    insert_override(organization, version, first, "A", "B", [[-74.005500, 40.713100]])

    assert {:ok, model} = Gtfs.alignment_editor(organization.id, version.id, "R1", "P1")
    assert [section1, section2] = model.sections

    assert section1.kind == :override
    assert section1.shared_points == [[-74.0057, 40.713]]

    assert section2.kind == :shared

    assert section2.shared_users ==
             length(Alignments.pair_users(organization.id, version.id, "B", "C"))

    assert section2.shared_users == 2
  end

  test "imported shapes list counts, ordered points, length and representative distances" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    route_fixture(organization.id, version.id, %{route_id: "R1"})

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    route_pattern_stop_fixture(pattern, "A", 1)
    route_pattern_stop_fixture(pattern, "B", 2)

    timing = timed_pattern_fixture(pattern)

    # Inserted out of sequence order; the model must order by shape_pt_sequence.
    insert_shape(organization, version, "X", 1, "40.713800", "-74.005000", "100")
    insert_shape(organization, version, "X", 0, "40.712800", "-74.006000", "0")
    insert_shape(organization, version, "Y", 0, "40.712800", "-74.006000", "0")
    insert_shape(organization, version, "Y", 1, "40.714800", "-74.004000", "250")

    link_trip(organization, version, pattern, timing, "T1", "X", [
      Decimal.new("0"),
      Decimal.new("100")
    ])

    link_trip(organization, version, pattern, timing, "T2", "X", [
      Decimal.new("0"),
      Decimal.new("100")
    ])

    # Three stop times for two visits: no representative distances.
    link_trip(organization, version, pattern, timing, "T3", "Y", [
      Decimal.new("0"),
      Decimal.new("120"),
      Decimal.new("250")
    ])

    assert {:ok, model} = Gtfs.alignment_editor(organization.id, version.id, "R1", "P1")
    assert [shape_x, shape_y] = model.imported_shapes

    assert shape_x.shape_id == "X"
    assert shape_x.trip_count == 2

    assert Enum.map(shape_x.points, &Enum.take(&1, 2)) == [
             [-74.006, 40.7128],
             [-74.005, 40.7138]
           ]

    assert Enum.map(shape_x.points, fn [_, _, dist] -> Decimal.to_float(dist) end) == [0.0, 100.0]

    assert shape_x.length_m ==
             Materializer.length_m([[-74.006, 40.7128], [-74.005, 40.7138]])

    assert Enum.map(shape_x.visit_distances, &Decimal.to_float/1) == [0.0, 100.0]

    assert shape_y.shape_id == "Y"
    assert shape_y.trip_count == 1
    assert shape_y.visit_distances == nil

    assert model.export_summary == %{shape_id: nil, linked_trip_count: 3, visit_count: 2}
  end

  test "hook model encodes with [lon, lat] points" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    route_fixture(organization.id, version.id, %{route_id: "R1", route_color: "0000FF"})

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    first = route_pattern_stop_fixture(pattern, "A", 1)
    route_pattern_stop_fixture(pattern, "B", 2)

    insert_override(organization, version, first, "A", "B", [[-74.005500, 40.713100]])

    assert {:ok, model} = Gtfs.alignment_editor(organization.id, version.id, "R1", "P1")

    hooked = Alignments.hook_model(model, editable: true)

    assert is_binary(Jason.encode!(hooked))
    assert hooked.editable == true
    assert hooked.route_color == "#0000FF"
    assert hooked.export in ["current", "stale", "imported", "none"]
    assert hd(hd(hooked.sections).points) == [-74.0055, 40.7131]
  end
end
