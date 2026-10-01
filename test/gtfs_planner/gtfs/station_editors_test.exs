defmodule GtfsPlanner.Gtfs.StationEditorsTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.StationEditingStatus

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  test "lists two editors ordered by started_at ascending with their station and email" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    first_station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "STA-A",
        stop_name: "Alpha",
        location_type: 1
      })

    second_station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "STA-B",
        stop_name: "Beta",
        location_type: 1
      })

    first_editor = user_fixture()
    second_editor = user_fixture()

    set_editing_status(
      organization,
      gtfs_version,
      second_station,
      second_editor,
      ~U[2026-09-20 11:00:00.000000Z]
    )

    set_editing_status(
      organization,
      gtfs_version,
      first_station,
      first_editor,
      ~U[2026-09-20 10:00:00.000000Z]
    )

    assert Gtfs.list_station_editors(organization.id, gtfs_version.id) == [
             %{
               station_id: first_station.id,
               station_stop_id: "STA-A",
               station_name: "Alpha",
               user_id: first_editor.id,
               email: first_editor.email,
               started_at: ~U[2026-09-20 10:00:00.000000Z]
             },
             %{
               station_id: second_station.id,
               station_stop_id: "STA-B",
               station_name: "Beta",
               user_id: second_editor.id,
               email: second_editor.email,
               started_at: ~U[2026-09-20 11:00:00.000000Z]
             }
           ]
  end

  test "ignores look-alike statuses in another version and another organization" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "STA",
        stop_name: "Subject station",
        location_type: 1
      })

    editor = user_fixture()

    set_editing_status(
      organization,
      gtfs_version,
      station,
      editor,
      ~U[2026-09-20 10:00:00.000000Z]
    )

    sibling_version = gtfs_version_fixture(organization.id)

    sibling_station =
      stop_fixture(organization.id, sibling_version.id, %{
        stop_id: "STA",
        stop_name: "Sibling version station",
        location_type: 1
      })

    set_editing_status(
      organization,
      sibling_version,
      sibling_station,
      user_fixture(),
      ~U[2026-09-20 11:00:00.000000Z]
    )

    other_organization = organization_fixture()
    other_organization_version = gtfs_version_fixture(other_organization.id)

    other_organization_station =
      stop_fixture(other_organization.id, other_organization_version.id, %{
        stop_id: "STA",
        stop_name: "Foreign organization station",
        location_type: 1
      })

    set_editing_status(
      other_organization,
      other_organization_version,
      other_organization_station,
      user_fixture(),
      ~U[2026-09-20 12:00:00.000000Z]
    )

    assert Gtfs.list_station_editors(organization.id, gtfs_version.id) == [
             %{
               station_id: station.id,
               station_stop_id: "STA",
               station_name: "Subject station",
               user_id: editor.id,
               email: editor.email,
               started_at: ~U[2026-09-20 10:00:00.000000Z]
             }
           ]
  end

  defp set_editing_status(organization, gtfs_version, station, editor, started_at) do
    status = station_editing_status_fixture(organization, gtfs_version, station, editor)

    # Pin the persisted time so the ordering assertion does not depend on clock resolution.
    {1, _} =
      from(s in StationEditingStatus, where: s.id == ^status.id)
      |> Repo.update_all(set: [started_at: started_at])

    status
  end
end
