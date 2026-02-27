defmodule GtfsPlanner.ValidationsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.WalkabilityTest

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures

  defmodule StartPathwaysTripTestRunnerMock do
    def run(validation_run, organization_id, gtfs_version_id, _opts) do
      listener = Application.get_env(:gtfs_planner, :pathways_trip_test_runner_test_listener)

      if is_pid(listener) do
        send(
          listener,
          {:pathways_runner_started, validation_run.id, organization_id, gtfs_version_id}
        )
      end

      {:ok, validation_run}
    end
  end

  describe "validation_runs" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "create_validation_run/3 creates a record with status started", %{
      organization: org,
      gtfs_version: version
    } do
      assert {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      assert run.organization_id == org.id
      assert run.gtfs_version_id == version.id
      assert run.run_type == "mobility_data"
      assert run.status == "started"
      assert run.errors_count == 0
      assert run.warnings_count == 0
      assert run.infos_count == 0
      assert run.started_at != nil
      assert run.completed_at == nil
      assert run.result_json == nil
      assert run.error_details == nil
    end

    test "create_validation_run/3 returns error with invalid organization_id" do
      invalid_org_id = Ecto.UUID.generate()
      invalid_version_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Validations.create_validation_run(
                 invalid_org_id,
                 invalid_version_id,
                 "mobility_data"
               )

      # Foreign key constraint error
      assert changeset.errors != []
    end

    test "mark_running/1 updates status to running", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")
      assert run.status == "started"

      assert {:ok, updated_run} = Validations.mark_running(run)
      assert updated_run.status == "running"
      assert updated_run.id == run.id
    end

    test "create_pathways_validation_run/2 creates pathways run with started status", %{
      organization: org,
      gtfs_version: version
    } do
      assert {:ok, run} = Validations.create_pathways_validation_run(org.id, version.id)

      assert run.organization_id == org.id
      assert run.gtfs_version_id == version.id
      assert run.run_type == "pathways_tests"
      assert run.status == "started"
    end

    test "mark_pathways_running/1 updates pathways run to running", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_pathways_validation_run(org.id, version.id)

      assert {:ok, updated_run} = Validations.mark_pathways_running(run)
      assert updated_run.status == "running"
    end

    test "mark_completed/2 stores result_json and counts", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      result = %{
        summary: %{
          errors: 5,
          warnings: 10,
          infos: 3
        },
        notices: [
          %{
            "code" => "missing_required_field",
            "severity" => "error",
            "totalNotices" => 5,
            "notices" => []
          }
        ],
        duration_ms: 1500
      }

      assert {:ok, completed_run} = Validations.mark_completed(run, result)
      assert completed_run.status == "completed"
      assert completed_run.errors_count == 5
      assert completed_run.warnings_count == 10
      assert completed_run.infos_count == 3
      assert completed_run.duration_ms == 1500
      assert completed_run.result_json != nil
      assert completed_run.result_json["notices"] != nil
      assert completed_run.completed_at != nil
    end

    test "mark_failed/2 stores error_details", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      error_reason = %RuntimeError{message: "Validation process crashed"}

      assert {:ok, failed_run} = Validations.mark_failed(run, error_reason)
      assert failed_run.status == "failed"
      assert failed_run.error_details != nil
      assert failed_run.error_details =~ "RuntimeError"
      assert failed_run.completed_at != nil
    end

    test "mark_pathways_failed/2 stores structured error_details", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "pathways_tests")

      reason = %{reason: :otp_runtime_failed, details: %{stage: :runtime_boot, message: "boom"}}

      assert {:ok, failed_run} = Validations.mark_pathways_failed(run, reason)
      assert failed_run.status == "failed"
      assert failed_run.completed_at != nil

      decoded_error = Jason.decode!(failed_run.error_details)
      assert decoded_error["scope"] == "pathways_tests"
      assert decoded_error["reason"] =~ "otp_runtime_failed"
      assert decoded_error["reason"] =~ "runtime_boot"
    end

    test "get_validation_run!/1 returns the run with given id", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      fetched_run = Validations.get_validation_run!(run.id)
      assert fetched_run.id == run.id
      assert fetched_run.organization_id == org.id
      assert fetched_run.gtfs_version_id == version.id
    end

    test "get_validation_run!/1 raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Validations.get_validation_run!(Ecto.UUID.generate())
      end
    end

    test "get_validation_run/1 returns nil for non-existent id" do
      assert Validations.get_validation_run(Ecto.UUID.generate()) == nil
    end

    test "list_validation_runs/2 returns runs ordered by started_at desc", %{
      organization: org,
      gtfs_version: version
    } do
      # Create runs with different timestamps
      {:ok, run1} = Validations.create_validation_run(org.id, version.id, "mobility_data")
      Process.sleep(10)
      {:ok, run2} = Validations.create_validation_run(org.id, version.id, "mobility_data")
      Process.sleep(10)
      {:ok, run3} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      runs = Validations.list_validation_runs(org.id, version.id)

      # Should be ordered by started_at descending (newest first)
      assert length(runs) == 3
      assert Enum.map(runs, & &1.id) == [run3.id, run2.id, run1.id]
    end

    test "list_validation_runs/2 filters by organization and version", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run1} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      # Create another org and version
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      {:ok, _run2} =
        Validations.create_validation_run(other_org.id, other_version.id, "mobility_data")

      # Create another version for the same org
      another_version = gtfs_version_fixture(org.id)

      {:ok, _run3} =
        Validations.create_validation_run(org.id, another_version.id, "mobility_data")

      runs = Validations.list_validation_runs(org.id, version.id)

      # Should only return runs for this specific org and version
      assert length(runs) == 1
      assert hd(runs).id == run1.id
      assert Enum.all?(runs, fn r -> r.organization_id == org.id end)
      assert Enum.all?(runs, fn r -> r.gtfs_version_id == version.id end)
    end

    test "list_validation_runs/2 limits results to 20", %{
      organization: org,
      gtfs_version: version
    } do
      # Create 25 validation runs
      for _ <- 1..25 do
        {:ok, _run} = Validations.create_validation_run(org.id, version.id, "mobility_data")
      end

      runs = Validations.list_validation_runs(org.id, version.id)

      # Should limit to 20 results
      assert length(runs) == 20
    end

    test "start_pathways_trip_test/2 creates running pathways run and spawns runner", %{
      organization: org,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_listener =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_test_listener)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        StartPathwaysTripTestRunnerMock
      )

      Application.put_env(:gtfs_planner, :pathways_trip_test_runner_test_listener, self())

      on_exit(fn ->
        if previous_runner_module do
          Application.put_env(
            :gtfs_planner,
            :pathways_trip_test_runner_module,
            previous_runner_module
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_trip_test_runner_module)
        end

        if previous_listener do
          Application.put_env(
            :gtfs_planner,
            :pathways_trip_test_runner_test_listener,
            previous_listener
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_trip_test_runner_test_listener)
        end
      end)

      assert {:ok, run} = Validations.start_pathways_trip_test(org.id, version.id)
      assert run.run_type == "pathways_tests"
      assert run.status == "running"

      run_id = run.id
      org_id = org.id
      version_id = version.id

      assert_receive {:pathways_runner_started, ^run_id, ^org_id, ^version_id}
    end

    test "start_pathways_trip_test/2 always creates a new run even when one is active", %{
      organization: org,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_listener =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_test_listener)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        StartPathwaysTripTestRunnerMock
      )

      Application.put_env(:gtfs_planner, :pathways_trip_test_runner_test_listener, self())

      on_exit(fn ->
        if previous_runner_module do
          Application.put_env(
            :gtfs_planner,
            :pathways_trip_test_runner_module,
            previous_runner_module
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_trip_test_runner_module)
        end

        if previous_listener do
          Application.put_env(
            :gtfs_planner,
            :pathways_trip_test_runner_test_listener,
            previous_listener
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_trip_test_runner_test_listener)
        end
      end)

      {:ok, existing_started_run} = Validations.create_pathways_validation_run(org.id, version.id)
      {:ok, existing_running_run} = Validations.mark_pathways_running(existing_started_run)

      assert {:ok, new_run} = Validations.start_pathways_trip_test(org.id, version.id)
      assert new_run.status == "running"
      refute new_run.id == existing_running_run.id

      new_run_id = new_run.id
      org_id = org.id
      version_id = version.id

      assert_receive {:pathways_runner_started, ^new_run_id, ^org_id, ^version_id}

      runs = Validations.list_validation_runs(org.id, version.id)
      assert Enum.any?(runs, &(&1.id == existing_running_run.id))
      assert Enum.any?(runs, &(&1.id == new_run.id))
    end

    test "start_pathways_trip_test/2 marks run failed when runner cannot be spawned", %{
      organization: org,
      gtfs_version: version
    } do
      previous_task_supervisor =
        Application.get_env(:gtfs_planner, :pathways_trip_test_task_supervisor)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_task_supervisor,
        GtfsPlanner.MissingTaskSupervisor
      )

      on_exit(fn ->
        if previous_task_supervisor do
          Application.put_env(
            :gtfs_planner,
            :pathways_trip_test_task_supervisor,
            previous_task_supervisor
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_trip_test_task_supervisor)
        end
      end)

      assert {:error, {:pathways_runner_spawn_failed, _reason}} =
               Validations.start_pathways_trip_test(org.id, version.id)

      assert [failed_run] = Validations.list_validation_runs(org.id, version.id)
      assert failed_run.run_type == "pathways_tests"
      assert failed_run.status == "failed"
      assert failed_run.error_details != nil

      decoded_error = Jason.decode!(failed_run.error_details)
      assert decoded_error["scope"] == "pathways_tests"
      assert decoded_error["reason"] =~ "pathways_runner_spawn_failed"
    end

    test "get_active_pathways_trip_test/2 returns newest active pathways run", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, older_run} = Validations.create_pathways_validation_run(org.id, version.id)
      Process.sleep(10)

      {:ok, newer_started_run} = Validations.create_pathways_validation_run(org.id, version.id)
      {:ok, newer_running_run} = Validations.mark_pathways_running(newer_started_run)

      {:ok, _non_pathways_run} =
        Validations.create_validation_run(org.id, version.id, "mobility_data")

      assert %GtfsPlanner.Validations.ValidationRun{id: run_id} =
               Validations.get_active_pathways_trip_test(org.id, version.id)

      assert run_id == newer_running_run.id
      assert run_id != older_run.id
    end

    test "get_active_pathways_trip_test/2 returns nil when no active pathways run exists", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, pathways_run} = Validations.create_pathways_validation_run(org.id, version.id)

      {:ok, _failed_pathways_run} =
        Validations.mark_pathways_failed(pathways_run, %{reason: :no_walkability_tests})

      {:ok, _non_pathways_run} =
        Validations.create_validation_run(org.id, version.id, "mobility_data")

      assert Validations.get_active_pathways_trip_test(org.id, version.id) == nil
    end

    test "get_pathways_trip_test_status/1 returns normalized status for pathways run", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, started_run} = Validations.create_pathways_validation_run(org.id, version.id)
      {:ok, running_run} = Validations.mark_pathways_running(started_run)

      assert {:ok, status} = Validations.get_pathways_trip_test_status(running_run.id)

      assert status.id == running_run.id
      assert status.run_type == "pathways_tests"
      assert status.status == "running"
      assert status.started_at == running_run.started_at
      assert status.completed_at == nil
      assert status.duration_ms == nil
      assert status.errors_count == 0
      assert status.warnings_count == 0
      assert status.infos_count == 0
      assert status.error_payload == nil
    end

    test "get_pathways_trip_test_status/1 returns decoded error payload for failed pathways run",
         %{
           organization: org,
           gtfs_version: version
         } do
      {:ok, run} = Validations.create_pathways_validation_run(org.id, version.id)

      failure_reason = %{
        reason: :otp_runtime_failed,
        details: %{stage: :runtime_boot, message: "runtime startup failed"}
      }

      {:ok, failed_run} = Validations.mark_pathways_failed(run, failure_reason)

      assert {:ok, status} = Validations.get_pathways_trip_test_status(failed_run.id)

      assert status.status == "failed"
      assert status.completed_at != nil
      assert status.error_payload["scope"] == "pathways_tests"
      assert status.error_payload["reason"] =~ "otp_runtime_failed"
      assert status.error_payload["reason"] =~ "runtime_boot"
    end

    test "get_pathways_trip_test_status/1 returns invalid_run_type for non-pathways runs", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      assert {:error, :invalid_run_type} = Validations.get_pathways_trip_test_status(run.id)
    end

    test "get_pathways_trip_test_status/1 returns not_found for missing run" do
      assert {:error, :not_found} =
               Validations.get_pathways_trip_test_status(Ecto.UUID.generate())
    end

    test "get_pathways_trip_test_results/1 returns persisted report and ordered case rows", %{
      organization: org,
      gtfs_version: version
    } do
      walkability_test_1 =
        walkability_test_fixture(%{organization_id: org.id, gtfs_version_id: version.id})

      walkability_test_2 =
        walkability_test_fixture(%{
          organization_id: org.id,
          gtfs_version_id: version.id,
          stop_id: "stop-2",
          address: "456 Oak St"
        })

      {:ok, run} = Validations.create_pathways_validation_run(org.id, version.id)

      run_result = %{
        suite_meta: %{total_candidates: 2, selected_count: 2, malformed_count: 0},
        selected_test_case_ids: [walkability_test_2.id, walkability_test_1.id],
        summary: %{total: 2, passed: 1, failed: 1, query_failure: 1, scoring_failure: 0},
        cases: [
          %{
            test_case_id: walkability_test_2.id,
            status: :passed,
            route_output: %{route_exists: true, duration_seconds: 180.0, distance_meters: 320.0},
            wheelchair_output: %{
              route_exists: true,
              duration_seconds: 200.0,
              distance_meters: 360.0
            }
          },
          %{
            test_case_id: walkability_test_1.id,
            status: :failed,
            failure_category: :query_failure,
            details: %{reason: :non_2xx_response, status: 500}
          }
        ]
      }

      {:ok, completed_run} = Validations.mark_pathways_completed(run, run_result, 120)

      assert {:ok, payload} = Validations.get_pathways_trip_test_results(completed_run.id)

      assert payload.id == completed_run.id
      assert payload.run_type == "pathways_tests"
      assert payload.status == "completed"
      assert payload.result_json["report_version"] == 1

      assert payload.result_json["selected_test_case_ids"] == [
               walkability_test_2.id,
               walkability_test_1.id
             ]

      assert payload.result_json["summary"] == %{
               "total" => 2,
               "passed" => 1,
               "failed" => 1,
               "query_failure" => 1,
               "scoring_failure" => 0,
               "pass_rate" => 50.0
             }

      assert payload.result_json["suite_meta"] == %{
               "total_candidates" => 2,
               "selected_count" => 2,
               "malformed_count" => 0
             }

      assert payload.result_json["stage_timestamps"]["started_at"]
      assert payload.result_json["stage_timestamps"]["completed_at"]
      assert Enum.map(payload.walkability_test_run_results, & &1.order_index) == [0, 1]

      assert Enum.map(payload.walkability_test_run_results, & &1.walkability_test_id) == [
               walkability_test_2.id,
               walkability_test_1.id
             ]
    end

    test "get_pathways_trip_test_results/1 returns run_not_completed for non-terminal pathways run",
         %{
           organization: org,
           gtfs_version: version
         } do
      {:ok, run} = Validations.create_pathways_validation_run(org.id, version.id)

      assert {:error, :run_not_completed} = Validations.get_pathways_trip_test_results(run.id)
    end

    test "get_pathways_trip_test_results/1 returns invalid_run_type for non-pathways run", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      assert {:error, :invalid_run_type} = Validations.get_pathways_trip_test_results(run.id)
    end

    test "get_pathways_trip_test_results/1 returns not_found for missing run" do
      assert {:error, :not_found} =
               Validations.get_pathways_trip_test_results(Ecto.UUID.generate())
    end

    test "get_latest_completed_pathways_trip_test/2 returns newest completed pathways run by completed_at then started_at",
         %{organization: org, gtfs_version: version} do
      {:ok, older_completed_run} = Validations.create_pathways_validation_run(org.id, version.id)

      {:ok, newer_started_same_completed_at_run} =
        Validations.create_pathways_validation_run(org.id, version.id)

      completed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      older_started_at = DateTime.add(completed_at, -120, :second)
      newer_started_at = DateTime.add(completed_at, -60, :second)

      {:ok, older_completed_run} =
        older_completed_run
        |> GtfsPlanner.Validations.ValidationRun.changeset(%{
          status: "completed",
          started_at: older_started_at,
          completed_at: completed_at
        })
        |> GtfsPlanner.Repo.update()

      {:ok, newer_started_same_completed_at_run} =
        newer_started_same_completed_at_run
        |> GtfsPlanner.Validations.ValidationRun.changeset(%{
          status: "completed",
          started_at: newer_started_at,
          completed_at: completed_at
        })
        |> GtfsPlanner.Repo.update()

      {:ok, _failed_pathways_run} =
        Validations.create_pathways_validation_run(org.id, version.id)
        |> then(fn {:ok, run} ->
          run
          |> GtfsPlanner.Validations.ValidationRun.changeset(%{
            status: "failed",
            completed_at: completed_at
          })
          |> GtfsPlanner.Repo.update()
        end)

      {:ok, _non_pathways_completed_run} =
        Validations.create_validation_run(org.id, version.id, "mobility_data")
        |> then(fn {:ok, run} ->
          run
          |> GtfsPlanner.Validations.ValidationRun.changeset(%{
            status: "completed",
            completed_at: DateTime.add(completed_at, 60, :second)
          })
          |> GtfsPlanner.Repo.update()
        end)

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      {:ok, _other_scope_run} =
        Validations.create_pathways_validation_run(other_org.id, other_version.id)
        |> then(fn {:ok, run} ->
          run
          |> GtfsPlanner.Validations.ValidationRun.changeset(%{
            status: "completed",
            completed_at: DateTime.add(completed_at, 120, :second)
          })
          |> GtfsPlanner.Repo.update()
        end)

      assert %GtfsPlanner.Validations.ValidationRun{id: latest_id} =
               Validations.get_latest_completed_pathways_trip_test(org.id, version.id)

      assert latest_id == newer_started_same_completed_at_run.id
      refute latest_id == older_completed_run.id
    end

    test "get_latest_completed_pathways_trip_test/2 returns nil when no completed pathways run exists",
         %{organization: org, gtfs_version: version} do
      {:ok, run} = Validations.create_pathways_validation_run(org.id, version.id)
      {:ok, _running_run} = Validations.mark_pathways_running(run)

      assert Validations.get_latest_completed_pathways_trip_test(org.id, version.id) == nil
    end
  end

  describe "walkability_tests" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "create_walkability_test/3 creates with valid attrs", %{
      organization: org,
      gtfs_version: version
    } do
      attrs = %{
        stop_id: "stop-1",
        address: "123 Main St",
        address_lat: Decimal.new("42.3601"),
        address_lon: Decimal.new("-71.0589")
      }

      assert {:ok, %WalkabilityTest{} = walkability_test} =
               Validations.create_walkability_test(org.id, version.id, attrs)

      assert walkability_test.organization_id == org.id
      assert walkability_test.stop_id == "stop-1"
      assert walkability_test.address == "123 Main St"
      assert walkability_test.address_lat == Decimal.new("42.3601")
      assert walkability_test.address_lon == Decimal.new("-71.0589")
    end

    test "create_walkability_test/3 returns error with missing required field", %{
      organization: org,
      gtfs_version: version
    } do
      assert {:error, changeset} = Validations.create_walkability_test(org.id, version.id, %{})

      assert %{
               stop_id: ["can't be blank"],
               address: ["can't be blank"],
               address_lat: ["can't be blank"],
               address_lon: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "create_walkability_test/3 returns error for duplicate within same org and version", %{
      organization: org,
      gtfs_version: version
    } do
      walkability_test_fixture(%{
        organization_id: org.id,
        gtfs_version_id: version.id,
        stop_id: "stop-dup",
        address: "456 Elm St"
      })

      assert {:error, changeset} =
               Validations.create_walkability_test(org.id, version.id, %{
                 stop_id: "stop-dup",
                 address: "456 Elm St",
                 address_lat: Decimal.new("42.3601"),
                 address_lon: Decimal.new("-71.0589")
               })

      assert "has already been taken" in errors_on(changeset).address
    end

    test "create_walkability_test/3 allows same stop/address across different versions", %{
      organization: org,
      gtfs_version: version
    } do
      other_version = gtfs_version_fixture(org.id)

      attrs = %{
        stop_id: "stop-shared",
        address: "789 Oak St",
        address_lat: Decimal.new("42.3601"),
        address_lon: Decimal.new("-71.0589")
      }

      assert {:ok, %WalkabilityTest{} = first} =
               Validations.create_walkability_test(org.id, version.id, attrs)

      assert {:ok, %WalkabilityTest{} = second} =
               Validations.create_walkability_test(org.id, other_version.id, attrs)

      assert first.id != second.id
      assert first.organization_id == second.organization_id
      assert first.gtfs_version_id != second.gtfs_version_id
      assert first.stop_id == second.stop_id
      assert first.address == second.address
    end

    test "list_walkability_tests/2 returns tests scoped to org and version in deterministic order",
         %{
           organization: org,
           gtfs_version: version
         } do
      wt1 =
        walkability_test_fixture(%{
          organization_id: org.id,
          gtfs_version_id: version.id,
          stop_id: "stop-b",
          address: "Addr B"
        })

      wt2 =
        walkability_test_fixture(%{
          organization_id: org.id,
          gtfs_version_id: version.id,
          stop_id: "stop-a",
          address: "Addr A"
        })

      other_version = gtfs_version_fixture(org.id)

      _wt3 =
        walkability_test_fixture(%{
          organization_id: org.id,
          gtfs_version_id: other_version.id,
          stop_id: "stop-c",
          address: "Addr C"
        })

      other_org = organization_fixture()
      other_org_version = gtfs_version_fixture(other_org.id)

      _wt4 =
        walkability_test_fixture(%{
          organization_id: other_org.id,
          gtfs_version_id: other_org_version.id,
          stop_id: "stop-d",
          address: "Addr D"
        })

      results = Validations.list_walkability_tests(org.id, version.id)

      assert Enum.map(results, & &1.id) == [wt2.id, wt1.id]
    end

    test "get_walkability_test!/1 returns the test", %{organization: org, gtfs_version: version} do
      walkability_test =
        walkability_test_fixture(%{organization_id: org.id, gtfs_version_id: version.id})

      fetched = Validations.get_walkability_test!(walkability_test.id)
      assert fetched.id == walkability_test.id
      assert fetched.organization_id == org.id
    end

    test "list_walkability_tests_for_stop_ids/2 scopes by org and stop ids", %{
      organization: org,
      gtfs_version: version
    } do
      included_stop_a =
        walkability_test_fixture(%{
          organization_id: org.id,
          gtfs_version_id: version.id,
          stop_id: "stop-included-a",
          address: "Address A"
        })

      included_stop_b =
        walkability_test_fixture(%{
          organization_id: org.id,
          gtfs_version_id: version.id,
          stop_id: "stop-included-b",
          address: "Address B"
        })

      _excluded_stop =
        walkability_test_fixture(%{
          organization_id: org.id,
          gtfs_version_id: version.id,
          stop_id: "stop-excluded",
          address: "Address C"
        })

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      _excluded_org =
        walkability_test_fixture(%{
          organization_id: other_org.id,
          gtfs_version_id: other_version.id,
          stop_id: "stop-included-a",
          address: "Address D"
        })

      assert [] = Validations.list_walkability_tests_for_stop_ids(org.id, [])

      results =
        Validations.list_walkability_tests_for_stop_ids(org.id, [
          "stop-included-a",
          "stop-included-b"
        ])

      result_ids = Enum.map(results, & &1.id)
      assert included_stop_a.id in result_ids
      assert included_stop_b.id in result_ids
      assert length(results) == 2
    end

    test "get_walkability_test/1 returns test or nil", %{organization: org, gtfs_version: version} do
      walkability_test =
        walkability_test_fixture(%{organization_id: org.id, gtfs_version_id: version.id})

      assert %WalkabilityTest{id: id} = Validations.get_walkability_test(walkability_test.id)
      assert id == walkability_test.id
      assert nil == Validations.get_walkability_test(Ecto.UUID.generate())
    end

    test "update_walkability_test/2 updates fields", %{organization: org, gtfs_version: version} do
      walkability_test =
        walkability_test_fixture(%{organization_id: org.id, gtfs_version_id: version.id})

      assert {:ok, %WalkabilityTest{} = updated} =
               Validations.update_walkability_test(walkability_test, %{
                 description: "Updated description",
                 expected_traversable: true
               })

      assert updated.id == walkability_test.id
      assert updated.description == "Updated description"
      assert updated.expected_traversable == true
    end

    test "delete_walkability_test/1 removes the record", %{
      organization: org,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{organization_id: org.id, gtfs_version_id: version.id})

      assert {:ok, %WalkabilityTest{}} = Validations.delete_walkability_test(walkability_test)

      assert_raise Ecto.NoResultsError, fn ->
        Validations.get_walkability_test!(walkability_test.id)
      end
    end
  end

  describe "transform_pathways_run_result/1" do
    test "builds report envelope and normalized case rows" do
      case_id_1 = Ecto.UUID.generate()
      case_id_2 = Ecto.UUID.generate()
      case_id_3 = Ecto.UUID.generate()

      run_result = %{
        suite_meta: %{
          total_candidates: 3,
          selected_count: 3,
          malformed_count: 0
        },
        selected_test_case_ids: [case_id_1, case_id_2, case_id_3],
        summary: %{
          total: 3,
          passed: 1,
          failed: 2,
          query_failure: 1,
          scoring_failure: 1
        },
        cases: [
          %{
            test_case_id: case_id_1,
            status: :passed,
            route_output: %{route_exists: true, duration_seconds: 420, distance_meters: 360.5},
            wheelchair_output: %{
              route_exists: true,
              duration_seconds: 500,
              distance_meters: 400.0
            }
          },
          %{
            test_case_id: case_id_2,
            status: :failed,
            failure_category: :query_failure,
            details: %{reason: :non_2xx_response, status: 500}
          },
          %{
            test_case_id: case_id_3,
            status: :failed,
            failure_category: :scoring_failure,
            route_output: %{route_exists: true, duration_seconds: 900, distance_meters: 1200.0},
            wheelchair_output: nil,
            details: %{
              mismatches: [%{kind: :expected_max_duration_seconds, expected: 700, actual: 900}]
            }
          }
        ]
      }

      transformed = Validations.transform_pathways_run_result(run_result)

      assert transformed.result_json["report_version"] == 1
      assert transformed.result_json["suite_meta"] == run_result.suite_meta

      assert transformed.result_json["selected_test_case_ids"] ==
               run_result.selected_test_case_ids

      assert transformed.result_json["summary"] == %{
               "total" => 3,
               "passed" => 1,
               "failed" => 2,
               "query_failure" => 1,
               "scoring_failure" => 1,
               "pass_rate" => 33.33
             }

      assert transformed.result_json["top_failure_categories"] == [
               %{"category" => "query_failure", "count" => 1},
               %{"category" => "scoring_failure", "count" => 1}
             ]

      assert transformed.case_row_attrs == [
               %{
                 walkability_test_id: case_id_1,
                 order_index: 0,
                 status: "passed",
                 failure_category: nil,
                 route_exists: true,
                 duration_seconds: 420.0,
                 distance_meters: 360.5,
                 wheelchair_route_exists: true,
                 wheelchair_duration_seconds: 500.0,
                 wheelchair_distance_meters: 400.0,
                 details_json: nil
               },
               %{
                 walkability_test_id: case_id_2,
                 order_index: 1,
                 status: "failed",
                 failure_category: "query_failure",
                 route_exists: nil,
                 duration_seconds: nil,
                 distance_meters: nil,
                 wheelchair_route_exists: nil,
                 wheelchair_duration_seconds: nil,
                 wheelchair_distance_meters: nil,
                 details_json: %{reason: :non_2xx_response, status: 500}
               },
               %{
                 walkability_test_id: case_id_3,
                 order_index: 2,
                 status: "failed",
                 failure_category: "scoring_failure",
                 route_exists: true,
                 duration_seconds: 900.0,
                 distance_meters: 1200.0,
                 wheelchair_route_exists: nil,
                 wheelchair_duration_seconds: nil,
                 wheelchair_distance_meters: nil,
                 details_json: %{
                   mismatches: [
                     %{kind: :expected_max_duration_seconds, expected: 700, actual: 900}
                   ]
                 }
               }
             ]
    end

    test "sets pass_rate to 0.0 and omits zero-count top categories when total is zero" do
      transformed =
        Validations.transform_pathways_run_result(%{
          suite_meta: %{total_candidates: 0, selected_count: 0, malformed_count: 0},
          selected_test_case_ids: [],
          summary: %{total: 0, passed: 0, failed: 0, query_failure: 0, scoring_failure: 0},
          cases: []
        })

      assert transformed.result_json["summary"]["pass_rate"] == 0.0
      assert transformed.result_json["top_failure_categories"] == []
      assert transformed.case_row_attrs == []
    end
  end

  describe "mark_pathways_completed/3" do
    test "updates pathways run status and persists report payload with case rows in a transaction" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id
        })

      {:ok, run} =
        Validations.create_pathways_validation_run(organization.id, gtfs_version.id)

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 1, failed: 0, query_failure: 0, scoring_failure: 0},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :passed,
            route_output: %{route_exists: true, duration_seconds: 123, distance_meters: 456},
            wheelchair_output: %{route_exists: true, duration_seconds: 130, distance_meters: 500}
          }
        ]
      }

      assert {:ok, completed_run} = Validations.mark_pathways_completed(run, run_result, 250)

      assert completed_run.status == "completed"
      assert completed_run.duration_ms == 250
      assert completed_run.completed_at != nil
      assert completed_run.errors_count == 0
      assert completed_run.warnings_count == 0
      assert completed_run.infos_count == 1
      assert completed_run.result_json["report_version"] == 1
      assert completed_run.result_json["summary"]["total"] == 1
      assert completed_run.result_json["summary"]["pass_rate"] == 100.0
      assert completed_run.result_json["stage_timestamps"]["started_at"]
      assert completed_run.result_json["stage_timestamps"]["completed_at"]

      assert [row] = Validations.list_walkability_test_run_results(completed_run.id)
      assert row.walkability_test_id == walkability_test.id
      assert row.order_index == 0
      assert row.status == "passed"
      assert row.duration_seconds == 123.0
      assert row.distance_meters == 456.0
      assert row.wheelchair_duration_seconds == 130.0
      assert row.wheelchair_distance_meters == 500.0
    end
  end

  describe "pathways reporting queries" do
    test "get_pathways_run_report/1 returns report payload for pathways runs" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      {:ok, run} =
        Validations.create_validation_run(organization.id, gtfs_version.id, "pathways_tests")

      result_json = %{
        "report_version" => 1,
        "summary" => %{"total" => 2, "passed" => 1, "failed" => 1}
      }

      {:ok, run} =
        run
        |> GtfsPlanner.Validations.ValidationRun.changeset(%{result_json: result_json})
        |> GtfsPlanner.Repo.update()

      assert Validations.get_pathways_run_report(run.id) == result_json
    end

    test "get_pathways_run_report/1 returns nil for non-pathways runs" do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      {:ok, run} =
        Validations.create_validation_run(organization.id, gtfs_version.id, "mobility_data")

      assert Validations.get_pathways_run_report(run.id) == nil
    end

    test "list_walkability_test_run_results/1 returns empty list for runs without rows" do
      assert Validations.list_walkability_test_run_results(Ecto.UUID.generate()) == []
    end
  end
end
