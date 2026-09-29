defmodule GtfsPlanner.Gtfs.AlignmentSegmentTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    pattern = route_pattern_fixture(organization.id, version.id)
    occurrence = route_pattern_stop_fixture(pattern, "S1", 1)
    _second = route_pattern_stop_fixture(pattern, "S2", 2)

    %{
      organization: organization,
      version: version,
      pattern: pattern,
      occurrence: occurrence
    }
  end

  defp shared_struct(organization, version, from_stop_id \\ "S1", to_stop_id \\ "S2") do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id
    }
  end

  defp override_struct(organization, version, occurrence, to_stop_id \\ "S2") do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: "S1",
      to_stop_id: to_stop_id,
      from_occurrence_id: occurrence.id
    }
  end

  test "valid points cast integers to floats and keep order" do
    changeset =
      AlignmentSegment.changeset(%AlignmentSegment{}, %{
        points: [[-74, 40.7128], [-74.005, 40.7138]]
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :points) == [[-74.0, 40.7128], [-74.005, 40.7138]]
  end

  test "malformed points give a changeset error on :points and insert nothing", %{
    organization: organization,
    version: version
  } do
    invalid_inputs = [
      three_element: [[-74.0, 40.7128, 0.0]],
      string_coordinate: [["-74.0", 40.7128]],
      lon_out_of_range: [[200.0, 40.7128]],
      lat_out_of_range: [[-74.0, -91.0]],
      too_many: List.duplicate([-74.0, 40.7128], 5_001)
    ]

    for {_label, points} <- invalid_inputs do
      changeset =
        shared_struct(organization, version)
        |> AlignmentSegment.changeset(%{points: points})

      refute changeset.valid?
      assert %{points: [_ | _]} = errors_on(changeset)

      assert {:error, failed} =
               shared_struct(organization, version)
               |> AlignmentSegment.changeset(%{points: points})
               |> Repo.insert()

      assert %{points: [_ | _]} = errors_on(failed)
    end

    assert Repo.aggregate(
             from(s in AlignmentSegment,
               where: s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id
             ),
             :count
           ) == 0
  end

  test "duplicate shared rows return a changeset error naming the shared index", %{
    organization: organization,
    version: version
  } do
    {:ok, _first} =
      shared_struct(organization, version)
      |> AlignmentSegment.changeset(%{points: [[-74.0, 40.7128]]})
      |> Repo.insert()

    assert {:error, changeset} =
             shared_struct(organization, version)
             |> AlignmentSegment.changeset(%{points: [[-74.1, 40.7129]]})
             |> Repo.insert()

    assert {_, opts} = changeset.errors[:organization_id]
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "alignment_segments_shared_pair_index"
  end

  test "duplicate overrides return a changeset error naming the override index", %{
    organization: organization,
    version: version,
    occurrence: occurrence
  } do
    {:ok, _first} =
      override_struct(organization, version, occurrence)
      |> AlignmentSegment.changeset(%{points: [[-74.0, 40.7128]]})
      |> Repo.insert()

    assert {:error, changeset} =
             override_struct(organization, version, occurrence)
             |> AlignmentSegment.changeset(%{points: [[-74.1, 40.7129]]})
             |> Repo.insert()

    assert {_, opts} = changeset.errors[:from_occurrence_id]
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "alignment_segments_override_visit_index"
  end

  test "updating a stale struct raises Ecto.StaleEntryError", %{
    organization: organization,
    version: version
  } do
    {:ok, segment} =
      shared_struct(organization, version)
      |> AlignmentSegment.changeset(%{points: [[-74.0, 40.7128]]})
      |> Repo.insert()

    stale = Repo.get!(AlignmentSegment, segment.id)
    fresh = Repo.get!(AlignmentSegment, segment.id)

    {:ok, _updated} =
      fresh
      |> AlignmentSegment.changeset(%{points: [[-74.1, 40.7129]]})
      |> Repo.update()

    assert_raise Ecto.StaleEntryError, fn ->
      stale
      |> AlignmentSegment.changeset(%{points: [[-74.2, 40.713]]})
      |> Repo.update!()
    end
  end

  test "RoutePattern and RoutePatternStop changesets ignore system-owned shape fields", %{
    pattern: pattern,
    occurrence: occurrence
  } do
    pattern_changeset =
      RoutePattern.changeset(pattern, %{"shape_id" => "X", "alignment_digest" => "d"})

    assert Ecto.Changeset.get_field(pattern_changeset, :shape_id) == pattern.shape_id

    assert Ecto.Changeset.get_field(pattern_changeset, :alignment_digest) ==
             pattern.alignment_digest

    stop_changeset =
      RoutePatternStop.changeset(occurrence, %{
        shape_dist_traveled: "12.5",
        route_pattern: pattern
      })

    assert Ecto.Changeset.get_field(stop_changeset, :shape_dist_traveled) ==
             occurrence.shape_dist_traveled
  end
end
