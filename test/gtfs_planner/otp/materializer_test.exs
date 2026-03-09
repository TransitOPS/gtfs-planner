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

      status_callback = fn payload -> send(self(), {:status, payload}) end

      assert {:ok, zip_path, first_meta} =
               Materializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 status_callback: status_callback
               )

      refute first_meta.reused
      assert File.regular?(zip_path)
      assert {:ok, _artifact} = Otp.fetch_artifact(organization.id, gtfs_version.id)

      assert_receive {:status, %{phase: :cache_check}}
      assert_receive {:status, %{phase: :preflight}}
      assert_receive {:status, %{phase: :exporting}}
      assert_receive {:status, %{phase: :packaging}}
      assert_receive {:status, %{phase: :persisting}}
      assert_receive {:status, %{phase: :done, reused: false}}

      assert {:ok, same_zip_path, second_meta} =
               Materializer.get_or_build_gtfs_zip(organization.id, gtfs_version.id)

      assert same_zip_path == zip_path
      assert second_meta.reused
      assert second_meta.content_hash == first_meta.content_hash
      assert second_meta.file_size_bytes == first_meta.file_size_bytes
    end

    test "lenient preflight still builds and persists artifact with incomplete GTFS", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      _agency = agency_fixture(organization.id, gtfs_version.id)

      assert {:ok, zip_path, meta} =
               Materializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 preflight_mode: :lenient
               )

      refute meta.reused
      assert File.regular?(zip_path)

      assert {:ok, artifact} = Otp.fetch_artifact(organization.id, gtfs_version.id)
      assert artifact.zip_path == zip_path
    end

    test "strict preflight returns issues and does not persist artifact with incomplete GTFS", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      _agency = agency_fixture(organization.id, gtfs_version.id)

      assert {:error, issues} =
               Materializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 preflight_mode: :strict
               )

      issue_codes = Enum.map(issues, & &1.code)
      assert :missing_required_file_data in issue_codes

      assert {:error, :not_found} = Otp.fetch_artifact(organization.id, gtfs_version.id)
    end

    test "force_rebuild ignores cache and rebuilds artifact", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      assert {:ok, _zip_path, first_meta} =
               Materializer.get_or_build_gtfs_zip(organization.id, gtfs_version.id)

      assert first_meta.reused == false

      status_callback = fn payload -> send(self(), {:status, payload}) end

      assert {:ok, _zip_path, second_meta} =
               Materializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 status_callback: status_callback,
                 force_rebuild: true
               )

      assert second_meta.reused == false
      refute_receive {:status, %{phase: :cache_check}}
      assert_receive {:status, %{phase: :preflight}}
      assert_receive {:status, %{phase: :exporting}}
      assert_receive {:status, %{phase: :packaging}}
      assert_receive {:status, %{phase: :persisting}}
      assert_receive {:status, %{phase: :done, reused: false}}
    end

    test "invokes pathways preflight before export packaging", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      organization_id = organization.id
      gtfs_version_id = gtfs_version.id

      seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      status_callback = fn payload -> send(self(), {:status, payload}) end

      pathways_preflight_fun = fn org_id, version_id, _opts ->
        send(self(), {:pathways_preflight_called, org_id, version_id})
        {:ok, %{blocking_errors: [], warnings: [], metadata: %{}}}
      end

      assert {:ok, _zip_path, _meta} =
               Materializer.get_or_build_gtfs_zip(
                 organization_id,
                 gtfs_version_id,
                 force_rebuild: true,
                 status_callback: status_callback,
                 pathways_preflight_fun: pathways_preflight_fun
               )

      assert_receive {:pathways_preflight_called, ^organization_id, ^gtfs_version_id}
      assert_receive {:status, %{phase: :exporting}}
      assert_receive {:status, %{phase: :packaging}}
    end

    test "aborts before export packaging when pathways preflight has blocking errors", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      organization_id = organization.id
      gtfs_version_id = gtfs_version.id

      seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      status_callback = fn payload -> send(self(), {:status, payload}) end

      blocking_issue = %{
        code: :station_stop_lon_out_of_range,
        severity: :blocking,
        message: "Station seed_stop_a has stop_lon outside -180.0..180.0 in stops.txt.",
        context: %{file: "stops.txt", field: "stop_lon", stop_id: "seed_stop_a"}
      }

      pathways_preflight_fun = fn org_id, version_id, _opts ->
        send(self(), {:pathways_preflight_called, org_id, version_id})

        {:error,
         %{blocking_errors: [blocking_issue], warnings: [], metadata: %{organization_id: org_id}}}
      end

      assert {:error, [returned_issue]} =
               Materializer.get_or_build_gtfs_zip(
                 organization_id,
                 gtfs_version_id,
                 force_rebuild: true,
                 status_callback: status_callback,
                 pathways_preflight_fun: pathways_preflight_fun
               )

      assert returned_issue.code == :station_stop_lon_out_of_range
      assert_receive {:pathways_preflight_called, ^organization_id, ^gtfs_version_id}

      assert_receive {:status,
                      %{
                        phase: :failed,
                        reason: :pathways_preflight_failed,
                        blocking_errors_count: 1
                      }}

      refute_receive {:status, %{phase: :exporting}}
      refute_receive {:status, %{phase: :packaging}}
      refute_receive {:status, %{phase: :persisting}}
      refute_receive {:status, %{phase: :done}}
      assert {:error, :not_found} = Otp.fetch_artifact(organization_id, gtfs_version_id)
    end

    test "aborts when pathways preflight returns blocking_errors even with ok status", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      organization_id = organization.id
      gtfs_version_id = gtfs_version.id

      seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      status_callback = fn payload -> send(self(), {:status, payload}) end

      blocking_issue = %{
        code: :pathway_endpoint_stop_not_found,
        severity: :blocking,
        message: "Pathway pw_block references unknown to_stop_id missing_stop.",
        context: %{file: "pathways.txt", field: "to_stop_id", pathway_id: "pw_block"}
      }

      pathways_preflight_fun = fn org_id, version_id, _opts ->
        send(self(), {:pathways_preflight_called, org_id, version_id})

        {:ok,
         %{blocking_errors: [blocking_issue], warnings: [], metadata: %{organization_id: org_id}}}
      end

      assert {:error, [returned_issue]} =
               Materializer.get_or_build_gtfs_zip(
                 organization_id,
                 gtfs_version_id,
                 force_rebuild: true,
                 status_callback: status_callback,
                 pathways_preflight_fun: pathways_preflight_fun
               )

      assert returned_issue.code == :pathway_endpoint_stop_not_found
      assert_receive {:pathways_preflight_called, ^organization_id, ^gtfs_version_id}

      assert_receive {:status,
                      %{
                        phase: :failed,
                        reason: :pathways_preflight_failed,
                        blocking_errors_count: 1
                      }}

      refute_receive {:status, %{phase: :exporting}}
      refute_receive {:status, %{phase: :packaging}}
      refute_receive {:status, %{phase: :persisting}}
      refute_receive {:status, %{phase: :done}}
      assert {:error, :not_found} = Otp.fetch_artifact(organization_id, gtfs_version_id)
    end

    test "treats malformed blocking_errors payload as terminal blocking failure", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      organization_id = organization.id
      gtfs_version_id = gtfs_version.id

      seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      status_callback = fn payload -> send(self(), {:status, payload}) end

      pathways_preflight_fun = fn org_id, version_id, _opts ->
        send(self(), {:pathways_preflight_called, org_id, version_id})

        {:ok,
         %{blocking_errors: :invalid_payload, warnings: [], metadata: %{organization_id: org_id}}}
      end

      assert {:error, [returned_issue]} =
               Materializer.get_or_build_gtfs_zip(
                 organization_id,
                 gtfs_version_id,
                 force_rebuild: true,
                 status_callback: status_callback,
                 pathways_preflight_fun: pathways_preflight_fun
               )

      assert returned_issue.code == :pathways_preflight_invalid_blocking_errors
      assert returned_issue.severity == :blocking
      assert_receive {:pathways_preflight_called, ^organization_id, ^gtfs_version_id}

      assert_receive {:status,
                      %{
                        phase: :failed,
                        reason: :pathways_preflight_failed,
                        blocking_errors_count: 1
                      }}

      refute_receive {:status, %{phase: :exporting}}
      refute_receive {:status, %{phase: :packaging}}
      refute_receive {:status, %{phase: :persisting}}
      refute_receive {:status, %{phase: :done}}
      assert {:error, :not_found} = Otp.fetch_artifact(organization_id, gtfs_version_id)
    end

    test "treats malformed preflight outcome as terminal blocking failure", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      organization_id = organization.id
      gtfs_version_id = gtfs_version.id

      seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      status_callback = fn payload -> send(self(), {:status, payload}) end

      pathways_preflight_fun = fn org_id, version_id, _opts ->
        send(self(), {:pathways_preflight_called, org_id, version_id})
        :unexpected
      end

      assert {:error, [returned_issue]} =
               Materializer.get_or_build_gtfs_zip(
                 organization_id,
                 gtfs_version_id,
                 force_rebuild: true,
                 status_callback: status_callback,
                 pathways_preflight_fun: pathways_preflight_fun
               )

      assert returned_issue.code == :pathways_preflight_invalid_outcome
      assert returned_issue.severity == :blocking
      assert_receive {:pathways_preflight_called, ^organization_id, ^gtfs_version_id}

      assert_receive {:status,
                      %{
                        phase: :failed,
                        reason: :pathways_preflight_failed,
                        blocking_errors_count: 1
                      }}

      refute_receive {:status, %{phase: :exporting}}
      refute_receive {:status, %{phase: :packaging}}
      refute_receive {:status, %{phase: :persisting}}
      refute_receive {:status, %{phase: :done}}
      assert {:error, :not_found} = Otp.fetch_artifact(organization_id, gtfs_version_id)
    end

    test "continues export and returns preflight warnings in meta", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      organization_id = organization.id
      gtfs_version_id = gtfs_version.id

      seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      status_callback = fn payload -> send(self(), {:status, payload}) end

      warning_issue = %{
        code: :pathway_endpoint_stop_not_found,
        severity: :warning,
        message: "Pathway pw_warn references unknown from_stop_id missing_stop in pathways.txt.",
        context: %{file: "pathways.txt", field: "from_stop_id", pathway_id: "pw_warn"}
      }

      pathways_preflight_fun = fn org_id, version_id, _opts ->
        send(self(), {:pathways_preflight_called, org_id, version_id})

        {:ok,
         %{blocking_errors: [], warnings: [warning_issue], metadata: %{organization_id: org_id}}}
      end

      assert {:ok, _zip_path, meta} =
               Materializer.get_or_build_gtfs_zip(
                 organization_id,
                 gtfs_version_id,
                 force_rebuild: true,
                 status_callback: status_callback,
                 pathways_preflight_fun: pathways_preflight_fun
               )

      assert meta.preflight_warnings == [warning_issue]
      assert_receive {:pathways_preflight_called, ^organization_id, ^gtfs_version_id}
      assert_receive {:status, %{phase: :exporting}}
      assert_receive {:status, %{phase: :packaging}}
      assert {:ok, _artifact} = Otp.fetch_artifact(organization_id, gtfs_version_id)
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
