defmodule GtfsPlanner.Gtfs.StationBoardTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StationBoard

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{organization: organization, gtfs_version: gtfs_version}
  end

  test "assigns direct children and boarding areas to their station" do
    assert StationBoard.children_by_station([
             {"STA", nil, 1},
             {"P1", "STA", 0},
             {"B0", "STA", 4},
             {"B1", "P1", 4},
             {"N1", "P1", 3}
           ]) == %{"STA" => MapSet.new(["P1", "B0", "B1"])}

    assert StationBoard.children_by_station([{"STA", nil, 1}, {"P1", "STA", 0}]) ==
             %{"STA" => MapSet.new(["P1"])}

    assert StationBoard.children_by_station([{"STA", nil, 1}]) == %{"STA" => MapSet.new()}
  end

  test "counts pathways that touch a station's child stops", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    level = level_fixture(organization.id, gtfs_version.id)

    station = station_fixture(organization, gtfs_version, "STA")
    platform = child_stop(organization, gtfs_version, "P1", station.stop_id, level, 0)
    boarding_area = child_stop(organization, gtfs_version, "B1", platform.stop_id, level, 4)
    node = child_stop(organization, gtfs_version, "N1", platform.stop_id, level, 3)
    outside = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "X1"})

    # Both endpoints are children of STA: one pathway, counted once.
    pathway_fixture(organization.id, gtfs_version.id, platform.stop_id, boarding_area.stop_id)
    # The node is a child of the platform, not of the station.
    pathway_fixture(organization.id, gtfs_version.id, node.stop_id, outside.stop_id)
    # Either endpoint being a child is enough.
    pathway_fixture(organization.id, gtfs_version.id, outside.stop_id, platform.stop_id)
    # The station row itself is not one of its own children.
    pathway_fixture(organization.id, gtfs_version.id, station.stop_id, outside.stop_id)

    assert [%{pathway_count: 2}] = StationBoard.base(organization.id, gtfs_version.id)
  end

  test "counts child-stop levels, stop_levels rows and floorplans", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    level_one = level_fixture(organization.id, gtfs_version.id, %{level_id: "L1"})
    level_two = level_fixture(organization.id, gtfs_version.id, %{level_id: "L2"})
    level_three = level_fixture(organization.id, gtfs_version.id, %{level_id: "L3"})
    level_four = level_fixture(organization.id, gtfs_version.id, %{level_id: "L4"})

    station = station_fixture(organization, gtfs_version, "STA")
    _unbuilt_station = station_fixture(organization, gtfs_version, "STB")

    platform = child_stop(organization, gtfs_version, "P1", station.stop_id, level_one, 0)

    # The boarding area's L2 counts; the node under the platform is not a child stop.
    _boarding_area = child_stop(organization, gtfs_version, "B1", platform.stop_id, level_two, 4)
    _node = child_stop(organization, gtfs_version, "N1", platform.stop_id, level_three, 3)

    create_stop_level(organization, gtfs_version, station, level_one, "plan.png")
    create_stop_level(organization, gtfs_version, station, level_four, "")

    bases = StationBoard.base(organization.id, gtfs_version.id)

    assert %{level_count: 3, floorplan_count: 1} = Enum.find(bases, &(&1.stop_id == "STA"))
    assert %{level_count: 0, floorplan_count: 0} = Enum.find(bases, &(&1.stop_id == "STB"))
  end

  test "reports the newest change log row for the station", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    _station = station_fixture(organization, gtfs_version, "STA")
    _never_edited = station_fixture(organization, gtfs_version, "STB")

    insert_change_logs(organization, gtfs_version, [
      %{
        station_stop_id: "STA",
        actor_email: "older@example.test",
        inserted_at: ~U[2026-09-10 08:00:00.000000Z]
      },
      %{
        station_stop_id: "STA",
        actor_email: "newest@example.test",
        inserted_at: ~U[2026-09-12 15:30:00.000000Z]
      },
      %{
        actor_email: "version-wide@example.test",
        inserted_at: ~U[2026-09-13 09:00:00.000000Z]
      }
    ])

    bases = StationBoard.base(organization.id, gtfs_version.id)

    assert %{
             last_edited_at: ~U[2026-09-12 15:30:00.000000Z],
             last_edited_by: "newest@example.test"
           } = Enum.find(bases, &(&1.stop_id == "STA"))

    assert %{last_edited_at: nil, last_edited_by: nil} =
             Enum.find(bases, &(&1.stop_id == "STB"))
  end

  test "ignores look-alike stations in another version and another organization", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    subject_level = level_fixture(organization.id, gtfs_version.id, %{level_id: "L1"})
    subject_station = station_fixture(organization, gtfs_version, "STA")

    subject_platform =
      child_stop(organization, gtfs_version, "P1", subject_station.stop_id, subject_level, 0)

    pathway_fixture(
      organization.id,
      gtfs_version.id,
      subject_platform.stop_id,
      subject_platform.stop_id
    )

    create_stop_level(organization, gtfs_version, subject_station, subject_level, "subject.png")

    insert_change_logs(organization, gtfs_version, [
      %{
        station_stop_id: "STA",
        actor_email: "subject@example.test",
        inserted_at: ~U[2026-09-10 08:00:00.000000Z]
      }
    ])

    sibling_version = gtfs_version_fixture(organization.id)

    sibling_level_one = level_fixture(organization.id, sibling_version.id, %{level_id: "L1"})
    sibling_level_two = level_fixture(organization.id, sibling_version.id, %{level_id: "L2"})
    sibling_station = station_fixture(organization, sibling_version, "STA")

    sibling_platform =
      child_stop(
        organization,
        sibling_version,
        "P1",
        sibling_station.stop_id,
        sibling_level_one,
        0
      )

    sibling_second =
      child_stop(
        organization,
        sibling_version,
        "P2",
        sibling_station.stop_id,
        sibling_level_two,
        0
      )

    pathway_fixture(
      organization.id,
      sibling_version.id,
      sibling_platform.stop_id,
      sibling_second.stop_id
    )

    pathway_fixture(
      organization.id,
      sibling_version.id,
      sibling_second.stop_id,
      sibling_platform.stop_id
    )

    create_stop_level(
      organization,
      sibling_version,
      sibling_station,
      sibling_level_one,
      "sibling.png"
    )

    insert_change_logs(organization, sibling_version, [
      %{
        station_stop_id: "STA",
        actor_email: "sibling@example.test",
        inserted_at: ~U[2026-09-12 08:00:00.000000Z]
      }
    ])

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)
    other_level = level_fixture(other_organization.id, other_version.id, %{level_id: "L1"})
    other_station = station_fixture(other_organization, other_version, "STA")

    other_platform =
      child_stop(other_organization, other_version, "P1", other_station.stop_id, other_level, 0)

    pathway_fixture(
      other_organization.id,
      other_version.id,
      other_platform.stop_id,
      other_platform.stop_id
    )

    create_stop_level(
      other_organization,
      other_version,
      other_station,
      other_level,
      "foreign.png"
    )

    insert_change_logs(other_organization, other_version, [
      %{
        station_stop_id: "STA",
        actor_email: "foreign@example.test",
        inserted_at: ~U[2026-09-14 08:00:00.000000Z]
      }
    ])

    assert StationBoard.base(organization.id, gtfs_version.id) == [
             %{
               id: subject_station.id,
               stop_id: "STA",
               name: "Station STA",
               level_count: 1,
               floorplan_count: 1,
               pathway_count: 1,
               last_edited_at: ~U[2026-09-10 08:00:00.000000Z],
               last_edited_by: "subject@example.test"
             }
           ]

    assert [
             %{
               level_count: 2,
               floorplan_count: 1,
               pathway_count: 2,
               last_edited_by: "sibling@example.test"
             }
           ] = StationBoard.base(organization.id, sibling_version.id)

    assert [
             %{
               level_count: 1,
               floorplan_count: 1,
               pathway_count: 1,
               last_edited_by: "foreign@example.test"
             }
           ] = StationBoard.base(other_organization.id, other_version.id)
  end

  test "sorts by stop_id and reports empty facts for an untouched station", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    second_station = station_fixture(organization, gtfs_version, "STB", %{stop_name: nil})
    first_station = station_fixture(organization, gtfs_version, "STA")

    assert StationBoard.base(organization.id, gtfs_version.id) == [
             %{
               id: first_station.id,
               stop_id: "STA",
               name: "Station STA",
               level_count: 0,
               floorplan_count: 0,
               pathway_count: 0,
               last_edited_at: nil,
               last_edited_by: nil
             },
             %{
               id: second_station.id,
               stop_id: "STB",
               name: nil,
               level_count: 0,
               floorplan_count: 0,
               pathway_count: 0,
               last_edited_at: nil,
               last_edited_by: nil
             }
           ]

    empty_version = gtfs_version_fixture(organization.id)

    assert StationBoard.base(organization.id, empty_version.id) == []
  end

  test "delegates through the Gtfs context", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    station = station_fixture(organization, gtfs_version, "STA")

    assert Gtfs.station_board_base(organization.id, gtfs_version.id) ==
             StationBoard.base(organization.id, gtfs_version.id)

    assert [%{stop_id: "STA", id: id}] = Gtfs.station_board_base(organization.id, gtfs_version.id)
    assert id == station.id
  end

  defp station_fixture(organization, gtfs_version, stop_id, attrs \\ %{}) do
    stop_fixture(
      organization.id,
      gtfs_version.id,
      Map.merge(%{stop_id: stop_id, stop_name: "Station #{stop_id}", location_type: 1}, attrs)
    )
  end

  defp child_stop(organization, gtfs_version, stop_id, parent_station, level, location_type) do
    stop_fixture(organization.id, gtfs_version.id, %{
      stop_id: stop_id,
      stop_name: "Child stop #{stop_id}",
      location_type: location_type,
      parent_station: parent_station,
      level_id: level.level_id
    })
  end

  defp create_stop_level(organization, gtfs_version, station, level, diagram_filename) do
    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        stop_id: station.id,
        level_id: level.id,
        diagram_filename: diagram_filename,
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id
      })

    stop_level
  end

  defp insert_change_logs(organization, gtfs_version, rows) do
    rows
    |> Enum.map(fn row ->
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          entity_type: "pathway",
          entity_id: Ecto.UUID.generate(),
          entity_external_id: Ecto.UUID.generate(),
          station_stop_id: nil,
          actor_id: Ecto.UUID.generate(),
          actor_email: "teammate@example.test",
          snapshot: nil,
          changed_fields: nil,
          action: "updated",
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          inserted_at: ~U[2026-09-01 12:00:00.000000Z]
        },
        Map.new(row)
      )
    end)
    |> then(&Repo.insert_all(ChangeLog, &1))
  end
end
