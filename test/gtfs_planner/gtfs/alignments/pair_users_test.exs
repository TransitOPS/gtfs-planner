defmodule GtfsPlanner.Gtfs.Alignments.PairUsersTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Repo

  defp insert_override(organization, version, occurrence, from_id, to_id) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_id,
      to_stop_id: to_id,
      from_occurrence_id: occurrence.id
    }
    |> AlignmentSegment.changeset(%{points: []})
    |> Repo.insert!()
  end

  defp link_trip(organization, version, pattern, trip_id) do
    timing = timed_pattern_fixture(pattern)
    trip = trip_fixture(organization.id, version.id, pattern.route_id, %{trip_id: trip_id})

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })
  end

  test "returns patterns on two routes using A then B, sorted with labels and trip counts" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    route_fixture(organization.id, version.id, %{
      route_id: "R2",
      route_short_name: "Two",
      route_long_name: "Two"
    })

    route_fixture(organization.id, version.id, %{
      route_id: "R1",
      route_short_name: "One",
      route_long_name: "One"
    })

    p2 =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R2",
        route_pattern_id: "P2",
        route_pattern_name: "Second"
      })

    route_pattern_stop_fixture(p2, "A", 1)
    route_pattern_stop_fixture(p2, "B", 2)

    p1 =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_pattern_id: "P1",
        route_pattern_name: "First"
      })

    route_pattern_stop_fixture(p1, "A", 1)
    route_pattern_stop_fixture(p1, "B", 2)

    link_trip(organization, version, p1, "T1")
    link_trip(organization, version, p1, "T2")
    link_trip(organization, version, p2, "T3")
    # A custom (non-linked) trip never counts toward the pattern.
    trip_fixture(organization.id, version.id, "R1", %{trip_id: "TX"})

    assert [
             %{
               pattern_id: p1_id,
               route_pattern_id: "P1",
               route_id: "R1",
               route_label: "One",
               pattern_label: "First",
               visit_positions: [1],
               custom_positions: [],
               owns_shape?: false,
               linked_trip_count: 2
             },
             %{
               pattern_id: p2_id,
               route_pattern_id: "P2",
               route_id: "R2",
               route_label: "Two",
               pattern_label: "Second",
               visit_positions: [1],
               custom_positions: [],
               owns_shape?: false,
               linked_trip_count: 1
             }
           ] = Alignments.pair_users(organization.id, version.id, "A", "B")

    assert p1_id == p1.id
    assert p2_id == p2.id
  end

  test "loop pattern reports both traversals of the pair" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    route_pattern_stop_fixture(pattern, "A", 1)
    route_pattern_stop_fixture(pattern, "B", 2)
    route_pattern_stop_fixture(pattern, "C", 3)
    route_pattern_stop_fixture(pattern, "A", 4)
    route_pattern_stop_fixture(pattern, "B", 5)

    assert [
             %{
               route_pattern_id: "P1",
               route_label: "R1",
               pattern_label: "P1",
               visit_positions: [1, 4],
               custom_positions: [],
               linked_trip_count: 0
             }
           ] = Alignments.pair_users(organization.id, version.id, "A", "B")
  end

  test "an applicable override moves the position to custom_positions" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    first = route_pattern_stop_fixture(pattern, "A", 1)
    route_pattern_stop_fixture(pattern, "B", 2)
    insert_override(organization, version, first, "A", "B")

    assert [
             %{visit_positions: [], custom_positions: [1]}
           ] = Alignments.pair_users(organization.id, version.id, "A", "B")
  end

  test "a stale override keeps the position a plain visit" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    first = route_pattern_stop_fixture(pattern, "A", 1)
    route_pattern_stop_fixture(pattern, "B", 2)
    # Stored from_stop_id no longer matches the visit's stop (INV-6).
    insert_override(organization, version, first, "X", "B")

    assert [
             %{visit_positions: [1], custom_positions: []}
           ] = Alignments.pair_users(organization.id, version.id, "A", "B")
  end

  test "reverse and non-consecutive pairs are not returned" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    reversed =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    route_pattern_stop_fixture(reversed, "B", 1)
    route_pattern_stop_fixture(reversed, "A", 2)

    gapped =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P2"})

    route_pattern_stop_fixture(gapped, "A", 1)
    route_pattern_stop_fixture(gapped, "C", 2)
    route_pattern_stop_fixture(gapped, "B", 3)

    assert [] = Alignments.pair_users(organization.id, version.id, "A", "B")
  end

  test "patterns in another organization or version are not returned" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    mine =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    route_pattern_stop_fixture(mine, "A", 1)
    route_pattern_stop_fixture(mine, "B", 2)

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)

    foreign =
      route_pattern_fixture(other_organization.id, other_version.id, %{
        route_id: "R1",
        route_pattern_id: "P9"
      })

    route_pattern_stop_fixture(foreign, "A", 1)
    route_pattern_stop_fixture(foreign, "B", 2)

    next_version = gtfs_version_fixture(organization.id)

    later =
      route_pattern_fixture(organization.id, next_version.id, %{
        route_id: "R1",
        route_pattern_id: "P8"
      })

    route_pattern_stop_fixture(later, "A", 1)
    route_pattern_stop_fixture(later, "B", 2)

    assert [%{route_pattern_id: "P1", route_label: "R1"}] =
             Alignments.pair_users(organization.id, version.id, "A", "B")
  end

  test "owns_shape? is true only when shape_id is set" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    owned =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    route_pattern_stop_fixture(owned, "A", 1)
    route_pattern_stop_fixture(owned, "B", 2)

    owned
    |> Ecto.Changeset.change(%{shape_id: "P1"})
    |> Repo.update!()

    plain =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P2"})

    route_pattern_stop_fixture(plain, "A", 1)
    route_pattern_stop_fixture(plain, "B", 2)

    assert [
             %{route_pattern_id: "P1", owns_shape?: true},
             %{route_pattern_id: "P2", owns_shape?: false}
           ] = Alignments.pair_users(organization.id, version.id, "A", "B")
  end
end
