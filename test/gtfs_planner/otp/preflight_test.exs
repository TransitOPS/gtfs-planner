defmodule GtfsPlanner.Otp.PreflightTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Otp.Preflight

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "run/2" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      %{
        organization: organization,
        gtfs_version: gtfs_version
      }
    end

    test "returns deterministic ordered integrity issues", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      _stop = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "existing_stop"})

      _stop_time_missing_trip =
        stop_time_fixture(
          organization.id,
          gtfs_version.id,
          "missing_trip_ref",
          "existing_stop",
          %{stop_sequence: 1}
        )

      _stop_time_missing_stop =
        stop_time_fixture(
          organization.id,
          gtfs_version.id,
          "trip_for_missing_route",
          "missing_stop_ref",
          %{stop_sequence: 2}
        )

      _pathway_missing_from =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          "missing_from_stop_ref",
          "existing_stop",
          %{pathway_id: "pathway_missing_from"}
        )

      _pathway_missing_to =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          "existing_stop",
          "missing_to_stop_ref",
          %{pathway_id: "pathway_missing_to"}
        )

      assert {:error, issues} = Preflight.run(organization.id, gtfs_version.id)

      assert Enum.map(issues, & &1.code) == [
               :missing_required_file_data,
               :missing_required_file_data,
               :missing_required_file_data,
               :missing_calendar_or_calendar_dates,
               :stop_times_trip_id_missing_trip,
               :stop_times_stop_id_missing_stop,
               :pathways_from_stop_id_missing_stop,
               :pathways_to_stop_id_missing_stop
             ]
    end
  end
end
