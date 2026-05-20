defmodule GtfsPlanner.Gtfs.StationEditingStatusTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.StationEditingStatus

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "changeset/2" do
    test "requires organization, GTFS version, station, user, and start time" do
      changeset = StationEditingStatus.changeset(%StationEditingStatus{}, %{})

      refute changeset.valid?

      assert %{
               organization_id: ["can't be blank"],
               gtfs_version_id: ["can't be blank"],
               station_id: ["can't be blank"],
               user_id: ["can't be blank"],
               started_at: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "enforces one status per organization, GTFS version, and station" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      station = stop_fixture(organization.id, gtfs_version.id, %{location_type: 1})
      user = user_fixture()

      attrs = valid_attrs(organization.id, gtfs_version.id, station.id, user.id)

      assert {:ok, _status} =
               %StationEditingStatus{}
               |> StationEditingStatus.changeset(attrs)
               |> Repo.insert()

      assert {:error, changeset} =
               %StationEditingStatus{}
               |> StationEditingStatus.changeset(attrs)
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).organization_id
    end
  end

  defp valid_attrs(organization_id, gtfs_version_id, station_id, user_id) do
    %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      station_id: station_id,
      user_id: user_id,
      started_at: DateTime.utc_now()
    }
  end
end
