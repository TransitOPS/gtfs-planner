defmodule GtfsPlanner.Otp.MaterializerTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.ArtifactPath
  alias GtfsPlanner.Otp.Materializer

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "get_or_build_gtfs_zip/3" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      on_exit(fn ->
        File.rm_rf(ArtifactPath.artifact_dir(organization.id, gtfs_version.id))
      end)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "builds once and reuses artifact on retry", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      status_callback = fn %{phase: phase} -> send(self(), {:phase, phase}) end

      assert {:ok, zip_path, first_meta} =
               Materializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 status_callback: status_callback
               )

      refute first_meta.reused
      assert File.regular?(zip_path)
      assert {:ok, _artifact} = Otp.fetch_artifact(organization.id, gtfs_version.id)

      assert_receive {:phase, :cache_check}
      assert_receive {:phase, :preflight}
      assert_receive {:phase, :exporting}
      assert_receive {:phase, :packaging}
      assert_receive {:phase, :persisting}
      assert_receive {:phase, :done}

      assert {:ok, same_zip_path, second_meta} =
               Materializer.get_or_build_gtfs_zip(organization.id, gtfs_version.id)

      assert same_zip_path == zip_path
      assert second_meta.reused
      assert second_meta.content_hash == first_meta.content_hash
      assert second_meta.file_size_bytes == first_meta.file_size_bytes
    end
  end

  defp seed_minimum_required_gtfs!(organization_id, gtfs_version_id) do
    agency_fixture(organization_id, gtfs_version_id)

    stop_a = stop_fixture(organization_id, gtfs_version_id, %{stop_id: "seed_stop_a"})
    stop_b = stop_fixture(organization_id, gtfs_version_id, %{stop_id: "seed_stop_b"})

    route = route_fixture(organization_id, gtfs_version_id)

    trip =
      trip_fixture(organization_id, gtfs_version_id, route.route_id, %{
        service_id: "seed_service"
      })

    stop_time_fixture(organization_id, gtfs_version_id, trip.trip_id, stop_a.stop_id)
    pathway_fixture(organization_id, gtfs_version_id, stop_a.stop_id, stop_b.stop_id)
    create_calendar!(organization_id, gtfs_version_id, trip.service_id)
  end

  defp create_calendar!(organization_id, gtfs_version_id, service_id) do
    attrs = %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31],
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    %Calendar{}
    |> Calendar.changeset(attrs)
    |> Repo.insert!()
  end
end
