defmodule GtfsPlanner.Gtfs.Alignments.ResolveTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments
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

  defp base_stops(organization, version) do
    stop_with_coords(organization, version, "A", "40.712800", "-74.006000")
    stop_with_coords(organization, version, "B", "40.713800", "-74.005000")
    stop_with_coords(organization, version, "C", "40.714800", "-74.004000")
  end

  test "override wins over shared on section 1 and missing reports empty points" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern = route_pattern_fixture(organization.id, version.id, %{route_id: "R1"})
    first = route_pattern_stop_fixture(pattern, "A", 1)
    _second = route_pattern_stop_fixture(pattern, "B", 2)
    _third = route_pattern_stop_fixture(pattern, "C", 3)

    shared = insert_shared(organization, version, "A", "B", [[-74.005700, 40.713000]])
    override = insert_override(organization, version, first, "A", "B", [[-74.005500, 40.713100]])

    assert %{visits: visits, sections: sections, status: status} = Alignments.resolve(pattern)
    assert length(visits) == 3
    assert length(sections) == 2

    assert [section1, section2] = sections

    assert section1.position == 1
    assert section1.from_occurrence_id == first.id
    assert section1.from_stop_id == "A"
    assert section1.to_stop_id == "B"
    assert section1.kind == :override
    assert section1.blocked_reason == nil
    assert section1.points == [[-74.0055, 40.7131]]
    assert section1.revision == %{segment_id: override.id, lock_version: override.lock_version}
    assert override.id != shared.id

    assert section2.kind == :missing
    assert section2.points == []
    assert section2.revision == %{segment_id: nil, lock_version: nil}

    assert status.missing == 1
    assert status.blocked == 0
  end

  test "loop second traversal keeps its own override while the first stays shared" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern = route_pattern_fixture(organization.id, version.id, %{route_id: "R1"})
    _v1 = route_pattern_stop_fixture(pattern, "A", 1)
    _v2 = route_pattern_stop_fixture(pattern, "B", 2)
    _v3 = route_pattern_stop_fixture(pattern, "C", 3)
    v4 = route_pattern_stop_fixture(pattern, "A", 4)
    _v5 = route_pattern_stop_fixture(pattern, "B", 5)

    _shared = insert_shared(organization, version, "A", "B", [[-74.005700, 40.713000]])
    override = insert_override(organization, version, v4, "A", "B", [[-74.005100, 40.713500]])

    assert %{visits: visits, sections: sections} = Alignments.resolve(pattern)
    assert length(sections) == 4

    assert [s1, _s2, _s3, s4] = sections
    assert s1.kind == :shared
    assert s1.points == [[-74.0057, 40.713]]
    assert s4.kind == :override
    assert s4.points == [[-74.0051, 40.7135]]
    assert s4.revision.segment_id == override.id

    by_stop = Map.new(visits, fn v -> {v.position, v.label} end)
    assert by_stop[1] == "1 / 4"
    assert by_stop[4] == "1 / 4"
    assert by_stop[2] == "2 / 5"
    assert by_stop[5] == "2 / 5"
    assert by_stop[3] == "3"
  end

  test "inserted visit makes the old override stale so the new pair resolves shared" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    stop_with_coords(organization, version, "X", "40.715800", "-74.003000")

    pattern = route_pattern_fixture(organization.id, version.id, %{route_id: "R1"})
    first = route_pattern_stop_fixture(pattern, "A", 1)
    _x = route_pattern_stop_fixture(pattern, "X", 2)
    _b = route_pattern_stop_fixture(pattern, "B", 3)

    # Retained occurrence still points its override at B, but the next visit is X.
    _stale = insert_override(organization, version, first, "A", "B", [[-74.005500, 40.713100]])
    shared_ax = insert_shared(organization, version, "A", "X", [[-74.004500, 40.714000]])

    assert %{sections: [section1, _section2]} = Alignments.resolve(pattern)
    assert section1.kind == :shared
    assert section1.points == [[-74.0045, 40.714]]
    assert section1.revision.segment_id == shared_ax.id
  end

  test "in-place stop replacement makes the override stale" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)
    stop_with_coords(organization, version, "X", "40.715800", "-74.003000")

    pattern = route_pattern_fixture(organization.id, version.id, %{route_id: "R1"})
    first = route_pattern_stop_fixture(pattern, "A", 1)
    _second = route_pattern_stop_fixture(pattern, "B", 2)

    _override = insert_override(organization, version, first, "A", "B", [[-74.005500, 40.713100]])

    # persist_occurrences!/3 can change a retained visit's stop_id in place.
    first |> Ecto.Changeset.change(%{stop_id: "X"}) |> Repo.update!()

    assert %{sections: [section1]} = Alignments.resolve(pattern)
    assert section1.from_stop_id == "X"
    assert section1.kind == :missing
    assert section1.points == []
  end

  test "a shared row with empty points is straight, not missing" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern = route_pattern_fixture(organization.id, version.id, %{route_id: "R1"})
    _first = route_pattern_stop_fixture(pattern, "A", 1)
    _second = route_pattern_stop_fixture(pattern, "B", 2)

    segment = insert_shared(organization, version, "A", "B", [])

    assert %{sections: [section], status: status} = Alignments.resolve(pattern)
    assert section.kind == :shared
    assert section.points == []
    assert section.revision.segment_id == segment.id
    assert status.missing == 0
  end

  test "shared rows from another organization or version do not apply" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    other_organization = organization_fixture()
    other_org_version = gtfs_version_fixture(other_organization.id)
    other_version = gtfs_version_fixture(organization.id)

    pattern = route_pattern_fixture(organization.id, version.id, %{route_id: "R1"})
    _first = route_pattern_stop_fixture(pattern, "A", 1)
    _second = route_pattern_stop_fixture(pattern, "B", 2)

    insert_shared(other_organization, other_org_version, "A", "B", [[0.0, 0.0]])
    insert_shared(organization, other_version, "A", "B", [[1.0, 1.0]])

    assert %{sections: [section]} = Alignments.resolve(pattern)
    assert section.kind == :missing

    own = insert_shared(organization, version, "A", "B", [[-74.005700, 40.713000]])

    assert %{sections: [resolved]} = Alignments.resolve(pattern)
    assert resolved.kind == :shared
    assert resolved.points == [[-74.0057, 40.713]]
    assert resolved.revision.segment_id == own.id
  end

  test "a stop without coordinates blocks both adjacent sections" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_with_coords(organization, version, "A", "40.712800", "-74.006000")
    stop_fixture(organization.id, version.id, %{stop_id: "B", stop_lat: nil, stop_lon: nil})
    stop_with_coords(organization, version, "C", "40.714800", "-74.004000")

    pattern = route_pattern_fixture(organization.id, version.id, %{route_id: "R1"})
    _first = route_pattern_stop_fixture(pattern, "A", 1)
    _second = route_pattern_stop_fixture(pattern, "B", 2)
    _third = route_pattern_stop_fixture(pattern, "C", 3)

    assert %{sections: sections, status: status, digest: digest} = Alignments.resolve(pattern)
    assert length(sections) == 2
    assert Enum.all?(sections, &(&1.kind == :blocked))
    assert Enum.all?(sections, &(&1.blocked_reason == :no_coordinates))
    assert status.blocked == 2
    assert status.missing == 0
    assert digest == nil
  end

  test "status is none without shapes, imported with a linked trip shape" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    base_stops(organization, version)

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    _first = route_pattern_stop_fixture(pattern, "A", 1)
    _second = route_pattern_stop_fixture(pattern, "B", 2)
    insert_shared(organization, version, "A", "B", [])

    assert %{status: status} = Alignments.resolve(pattern)
    assert status == %{missing: 0, blocked: 0, export: :none}

    timing = timed_pattern_fixture(pattern)
    trip = trip_fixture(organization.id, version.id, "R1", %{trip_id: "T1", shape_id: "X"})

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: "P1",
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })

    assert %{status: imported} = Alignments.resolve(pattern)
    assert imported == %{missing: 0, blocked: 0, export: :imported}
  end

  test "status is current when the digest matches and stale after a stop move" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_a = stop_with_coords(organization, version, "A", "40.712800", "-74.006000")
    stop_b = stop_with_coords(organization, version, "B", "40.713800", "-74.005000")

    pattern =
      route_pattern_fixture(organization.id, version.id, %{route_id: "R1", route_pattern_id: "P1"})

    _first = route_pattern_stop_fixture(pattern, "A", 1)
    _second = route_pattern_stop_fixture(pattern, "B", 2)
    insert_shared(organization, version, "A", "B", [])

    assert %{digest: digest, status: status} = Alignments.resolve(pattern)
    assert status.export == :none
    assert is_binary(digest)

    pattern
    |> Ecto.Changeset.change(%{shape_id: "P1", alignment_digest: digest})
    |> Repo.update!()

    pattern = Repo.get!(pattern.__struct__, pattern.id)
    assert %{status: current, digest: current_digest} = Alignments.resolve(pattern)
    assert current == %{missing: 0, blocked: 0, export: :current}
    assert current_digest == digest

    stop_b |> Ecto.Changeset.change(%{stop_lat: Decimal.new("40.713900")}) |> Repo.update!()
    _ = stop_a

    assert %{status: stale, digest: stale_digest} = Alignments.resolve(pattern)
    assert stale == %{missing: 0, blocked: 0, export: :stale}
    assert is_binary(stale_digest)
    assert stale_digest != digest
  end
end
