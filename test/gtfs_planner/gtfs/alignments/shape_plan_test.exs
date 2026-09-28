defmodule GtfsPlanner.Gtfs.Alignments.ShapePlanTest do
  use GtfsPlanner.DataCase, async: true

  import Ecto.Changeset, only: [change: 2]
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo

  defp three_visit_pattern(organization, version, attrs \\ %{}) do
    pattern =
      route_pattern_fixture(
        organization.id,
        version.id,
        Map.merge(%{route_id: "R1", route_pattern_id: "P1"}, attrs)
      )

    route_pattern_stop_fixture(pattern, "A", 1)
    route_pattern_stop_fixture(pattern, "B", 2)
    route_pattern_stop_fixture(pattern, "C", 3)

    pattern
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

  defp set_owned_shape(pattern, shape_id) do
    pattern |> change(%{shape_id: shape_id}) |> Repo.update!()
  end

  test "a pattern that already owns a shape keeps it with no replacements" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version)
    pattern = set_owned_shape(pattern, "P1")

    assert Alignments.shape_plan(pattern, 3) == %{
             shape_id: "P1",
             mode: :existing,
             replaced: [],
             previous: [],
             blockers: []
           }
  end

  test "linked trips on one otherwise-unused shape adopt it with prior points" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version)
    timing = timed_pattern_fixture(pattern)

    insert_shape(organization, version, "X", 1, "40.713800", "-74.005000", "812.4")
    insert_shape(organization, version, "X", 0, "40.712800", "-74.006000", "0")

    link_trip(organization, version, pattern, timing, "T1", "X", [
      Decimal.new("0"),
      Decimal.new("812.4"),
      Decimal.new("1200.0")
    ])

    link_trip(organization, version, pattern, timing, "T2", "X", [
      Decimal.new("0"),
      Decimal.new("812.4"),
      Decimal.new("1200.0")
    ])

    link_trip(organization, version, pattern, timing, "T3", "X", [
      Decimal.new("0"),
      Decimal.new("812.4"),
      Decimal.new("1200.0")
    ])

    assert %{
             shape_id: "X",
             mode: :adopt,
             replaced: [
               %{shape_id: "X", trip_count: 3, action: :adopted, points: points}
             ],
             previous: [
               %{
                 shape_id: "X",
                 trip_count: 3,
                 visit_distances: [d0, d1, d2]
               }
             ],
             blockers: []
           } = Alignments.shape_plan(pattern, 3)

    assert points == [
             [40.7128, -74.006, 0, Decimal.new("0")],
             [40.7138, -74.005, 1, Decimal.new("812.4")]
           ]

    assert Enum.map([d0, d1, d2], &Decimal.to_float/1) == [0.0, 812.4, 1200.0]
  end

  test "a custom trip of the same route on the shape forces allocation" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version)
    timing = timed_pattern_fixture(pattern)

    insert_shape(organization, version, "X", 0, "40.712800", "-74.006000", "0")

    link_trip(organization, version, pattern, timing, "T1", "X", [
      Decimal.new("0"),
      Decimal.new("1"),
      Decimal.new("2")
    ])

    custom =
      trip_fixture(organization.id, version.id, pattern.route_id, %{
        trip_id: "CUSTOM",
        shape_id: "X"
      })

    trip_pattern_metadata_fixture(custom, %{
      route_pattern_id: pattern.route_pattern_id,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: "stops_differ"
    })

    assert %{shape_id: "P1", mode: :allocate, replaced: [], blockers: []} =
             Alignments.shape_plan(pattern, 3)
  end

  test "another pattern's linked trip on the shape forces allocation without replacement" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version)
    timing = timed_pattern_fixture(pattern)

    other =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R2",
        route_pattern_id: "Q1"
      })

    route_pattern_stop_fixture(other, "A", 1)
    route_pattern_stop_fixture(other, "B", 2)
    other_timing = timed_pattern_fixture(other)

    insert_shape(organization, version, "X", 0, "40.712800", "-74.006000", "0")

    link_trip(organization, version, pattern, timing, "T1", "X", [
      Decimal.new("0"),
      Decimal.new("1"),
      Decimal.new("2")
    ])

    link_trip(organization, version, other, other_timing, "OT1", "X", [
      Decimal.new("0"),
      Decimal.new("9")
    ])

    assert %{shape_id: "P1", mode: :allocate, replaced: [], blockers: []} =
             Alignments.shape_plan(pattern, 3)
  end

  test "divergent shapes used only by this pattern allocate and list both deletions" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version)
    timing = timed_pattern_fixture(pattern)

    insert_shape(organization, version, "X", 0, "40.712800", "-74.006000", "0")
    insert_shape(organization, version, "Y", 0, "40.714800", "-74.004000", nil)

    link_trip(organization, version, pattern, timing, "T1", "X", [
      Decimal.new("0"),
      Decimal.new("1"),
      Decimal.new("2")
    ])

    link_trip(organization, version, pattern, timing, "T2", "X", [
      Decimal.new("0"),
      Decimal.new("1"),
      Decimal.new("2")
    ])

    link_trip(organization, version, pattern, timing, "T3", "Y", [
      Decimal.new("0"),
      Decimal.new("1"),
      Decimal.new("2")
    ])

    assert %{
             shape_id: "P1",
             mode: :allocate,
             replaced: [
               %{shape_id: "X", trip_count: 2, action: :deleted, points: x_points},
               %{shape_id: "Y", trip_count: 1, action: :deleted, points: y_points}
             ],
             blockers: []
           } = Alignments.shape_plan(pattern, 3)

    assert x_points == [[40.7128, -74.006, 0, Decimal.new("0")]]
    assert y_points == [[40.7148, -74.004, 0, nil]]
  end

  test "candidate IDs skip taken shape rows and owned pattern shapes" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version, %{route_pattern_id: "P9"})

    insert_shape(organization, version, "P9", 0, "40.712800", "-74.006000", "0")

    assert %{shape_id: "P9-2", mode: :allocate} = Alignments.shape_plan(pattern, 3)

    other =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R2",
        route_pattern_id: "Q1"
      })

    set_owned_shape(other, "P9-2")

    assert %{shape_id: "P9-3", mode: :allocate} = Alignments.shape_plan(pattern, 3)
  end

  test "a linked trip with fewer stop times than visits blocks with a named blocker" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    pattern =
      three_visit_pattern(organization, version, %{
        route_pattern_id: "P7",
        route_pattern_name: "Harbor Local"
      })

    timing = timed_pattern_fixture(pattern)

    link_trip(organization, version, pattern, timing, "SHORT", nil, [
      Decimal.new("0"),
      Decimal.new("5")
    ])

    assert %{
             mode: :allocate,
             blockers: [
               %{
                 trip_id: "SHORT",
                 stop_time_count: 2,
                 visit_count: 3,
                 route_pattern_id: "P7",
                 pattern_label: "Harbor Local"
               }
             ]
           } = Alignments.shape_plan(pattern, 3)
  end

  test "previous groups linked trips by exact shape and distance vectors" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version)
    timing = timed_pattern_fixture(pattern)

    link_trip(organization, version, pattern, timing, "T1", "X", [
      Decimal.new("0"),
      Decimal.new("812.4"),
      Decimal.new("1200.0")
    ])

    link_trip(organization, version, pattern, timing, "T2", "X", [
      Decimal.new("0"),
      Decimal.new("812.4"),
      Decimal.new("1200.0")
    ])

    link_trip(organization, version, pattern, timing, "T3", "X", [nil, nil, nil])

    assert %{previous: previous} = Alignments.shape_plan(pattern, 3)
    assert length(previous) == 2

    assert Enum.find(previous, &(&1.trip_count == 2)) == %{
             shape_id: "X",
             trip_count: 2,
             visit_distances: [Decimal.new("0"), Decimal.new("812.4"), Decimal.new("1200.0")]
           }

    assert Enum.find(previous, &(&1.trip_count == 1)) == %{
             shape_id: "X",
             trip_count: 1,
             visit_distances: [nil, nil, nil]
           }
  end

  test "a nil shape set allocates with no replacements" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version)
    timing = timed_pattern_fixture(pattern)

    link_trip(organization, version, pattern, timing, "T1", nil, [
      Decimal.new("0"),
      Decimal.new("1"),
      Decimal.new("2")
    ])

    assert %{shape_id: "P1", mode: :allocate, replaced: [], blockers: []} =
             Alignments.shape_plan(pattern, 3)
  end

  test "trips from another organization never block adoption" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version)
    timing = timed_pattern_fixture(pattern)

    insert_shape(organization, version, "X", 0, "40.712800", "-74.006000", "0")

    link_trip(organization, version, pattern, timing, "T1", "X", [
      Decimal.new("0"),
      Decimal.new("1"),
      Decimal.new("2")
    ])

    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)

    foreign_pattern =
      route_pattern_fixture(foreign_organization.id, foreign_version.id, %{
        route_id: "R1",
        route_pattern_id: "P1"
      })

    foreign_timing = timed_pattern_fixture(foreign_pattern)

    link_trip(foreign_organization, foreign_version, foreign_pattern, foreign_timing, "FT1", "X", [
      Decimal.new("0")
    ])

    assert %{shape_id: "X", mode: :adopt} = Alignments.shape_plan(pattern, 3)
  end

  test "a referenced shape with no shape rows adopts with empty points" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = three_visit_pattern(organization, version)
    timing = timed_pattern_fixture(pattern)

    link_trip(organization, version, pattern, timing, "T1", "GHOST", [
      Decimal.new("0"),
      Decimal.new("1"),
      Decimal.new("2")
    ])

    assert %{
             shape_id: "GHOST",
             mode: :adopt,
             replaced: [%{shape_id: "GHOST", trip_count: 1, action: :adopted, points: []}]
           } = Alignments.shape_plan(pattern, 3)
  end
end
