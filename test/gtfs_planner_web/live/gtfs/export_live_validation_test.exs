defmodule GtfsPlannerWeb.Gtfs.ExportLiveValidationTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures
  import Mox

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Otp
  alias GtfsPlanner.Otp.ArtifactPath
  alias GtfsPlanner.Otp.GraphPath
  alias GtfsPlanner.Otp.Runtime.Session
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Gtfs.ValidatorMock

  defmodule PathwaysValidityMock do
    def run_in_session(_session, _organization_id, _gtfs_version_id, _opts \\ []) do
      {:ok,
       %{
         suite_meta: %{total_candidates: 0, selected_count: 0, malformed_count: 0},
         selected_test_case_ids: [],
         summary: %{total: 3, passed: 2, failed: 1, query_failure: 1, scoring_failure: 0},
         cases: []
       }}
    end
  end

  defmodule RuntimeMock do
    def run_with_otp(organization_id, gtfs_version_id, callback, opts) do
      _ = {organization_id, gtfs_version_id}

      session = %Session{
        command: "java",
        args: ["-jar", "/tmp/otp.jar"],
        host: "127.0.0.1",
        port: 8080,
        base_url: "http://127.0.0.1:8080",
        graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
        graph_workspace_dir: "/tmp/runtime",
        process: make_ref(),
        runtime_log_path: "/tmp/runtime/runtime.log"
      }

      case opts[:status_callback] do
        callback when is_function(callback, 1) ->
          callback.(%{scope: :gtfs, phase: :cache_check})
          callback.(%{scope: :gtfs, phase: :packaging})
          callback.(%{scope: :graph, phase: :building})
          callback.(%{scope: :graph, phase: :done})
          callback.(%{scope: :otp, phase: :starting})
          callback.(%{scope: :otp, phase: :waiting_ready})
          callback.(%{scope: :otp, phase: :ready})

          callback.(%{
            scope: :suite,
            phase: :running,
            completed: 0,
            total: 2,
            test_case_id: "case-1"
          })

          Process.sleep(180)

          callback.(%{
            scope: :suite,
            phase: :running,
            completed: 1,
            total: 2,
            test_case_id: "case-2"
          })

          Process.sleep(25)
          callback.(%{scope: :suite, phase: :finishing, completed: 2, total: 2})
          Process.sleep(25)
          callback.(%{scope: :suite, phase: :finished, completed: 2, total: 2})
          callback.(%{scope: :otp, phase: :stopping})
          callback.(%{scope: :otp, phase: :stopped})

        _other ->
          :ok
      end

      callback.(session)
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :purged, gtfs: :purged}}
    end
  end

  defmodule RuntimeFailMock do
    def run_with_otp(_organization_id, _gtfs_version_id, _callback, _opts) do
      {:error, [%{code: :otp_start_failed}]}
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :not_found, gtfs: :not_found}}
    end
  end

  defmodule RuntimeLockConflictMock do
    def run_with_otp(_organization_id, _gtfs_version_id, _callback, _opts) do
      {:error, [%{code: :otp_runtime_already_running}]}
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :not_found, gtfs: :not_found}}
    end
  end

  defmodule RuntimeSlowOtpPhaseMock do
    def run_with_otp(_organization_id, _gtfs_version_id, callback, opts) do
      case opts[:status_callback] do
        status_callback when is_function(status_callback, 1) ->
          status_callback.(%{scope: :gtfs, phase: :cache_check})
          status_callback.(%{scope: :graph, phase: :building})
          status_callback.(%{scope: :graph, phase: :done})
          status_callback.(%{scope: :otp, phase: :starting})
          Process.sleep(40)
          status_callback.(%{scope: :otp, phase: :waiting_ready})
          Process.sleep(120)

        _other ->
          Process.sleep(120)
      end

      callback.(%Session{
        command: "java",
        args: ["-jar", "/tmp/otp.jar"],
        host: "127.0.0.1",
        port: 8080,
        base_url: "http://127.0.0.1:8080",
        graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
        graph_workspace_dir: "/tmp/runtime",
        process: make_ref(),
        runtime_log_path: "/tmp/runtime/runtime.log"
      })
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :not_found, gtfs: :not_found}}
    end
  end

  defmodule RuntimeFinishedSuitePhaseMock do
    def run_with_otp(_organization_id, _gtfs_version_id, callback, opts) do
      case opts[:status_callback] do
        status_callback when is_function(status_callback, 1) ->
          status_callback.(%{scope: :gtfs, phase: :cache_check})
          status_callback.(%{scope: :graph, phase: :building})
          status_callback.(%{scope: :graph, phase: :done})
          status_callback.(%{scope: :otp, phase: :ready})

          status_callback.(%{
            scope: :suite,
            phase: :running,
            completed: 0,
            total: 1,
            test_case_id: "case-1"
          })

          status_callback.(%{scope: :suite, phase: :finishing, completed: 1, total: 1})
          status_callback.(%{scope: :suite, phase: :finished, completed: 1, total: 1})
          Process.sleep(120)

        _other ->
          Process.sleep(120)
      end

      callback.(%Session{
        command: "java",
        args: ["-jar", "/tmp/otp.jar"],
        host: "127.0.0.1",
        port: 8080,
        base_url: "http://127.0.0.1:8080",
        graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
        graph_workspace_dir: "/tmp/runtime",
        process: make_ref(),
        runtime_log_path: "/tmp/runtime/runtime.log"
      })
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :not_found, gtfs: :not_found}}
    end
  end

  defmodule RuntimeFinishedSuitePhaseMock do
    def run_with_otp(_organization_id, _gtfs_version_id, callback, opts) do
      case opts[:status_callback] do
        status_callback when is_function(status_callback, 1) ->
          status_callback.(%{scope: :gtfs, phase: :cache_check})
          status_callback.(%{scope: :graph, phase: :building})
          status_callback.(%{scope: :graph, phase: :done})
          status_callback.(%{scope: :otp, phase: :ready})

          status_callback.(%{
            scope: :suite,
            phase: :running,
            completed: 0,
            total: 1,
            test_case_id: "case-1"
          })

          status_callback.(%{scope: :suite, phase: :finishing, completed: 1, total: 1})
          status_callback.(%{scope: :suite, phase: :finished, completed: 1, total: 1})
          Process.sleep(120)

        _other ->
          Process.sleep(120)
      end

      callback.(%Session{
        command: "java",
        args: ["-jar", "/tmp/otp.jar"],
        host: "127.0.0.1",
        port: 8080,
        base_url: "http://127.0.0.1:8080",
        graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
        graph_workspace_dir: "/tmp/runtime",
        process: make_ref(),
        runtime_log_path: "/tmp/runtime/runtime.log"
      })
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :not_found, gtfs: :not_found}}
    end
  end

  defmodule RuntimeShouldNotBeCalledMock do
    def run_with_otp(_organization_id, _gtfs_version_id, _callback, _opts) do
      raise "run_with_otp should not be called in mobility-only path"
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :not_found, gtfs: :not_found}}
    end
  end

  defmodule PathwaysRunnerNotifyMock do
    def run(validation_run, organization_id, gtfs_version_id, _opts) do
      case Application.get_env(:gtfs_planner, :pathways_runner_test_pid) do
        pid when is_pid(pid) ->
          send(
            pid,
            {:pathways_runner_invoked, validation_run.id, organization_id, gtfs_version_id}
          )

        _other ->
          :ok
      end

      try do
        _ =
          GtfsPlanner.Validations.mark_pathways_failed(validation_run, %{reason: :test_complete})
      rescue
        Ecto.StaleEntryError -> :ok
      end

      :ok
    end
  end

  defmodule PathwaysRunnerFailReasonMock do
    def run(validation_run, _organization_id, _gtfs_version_id, _opts) do
      failure_reason =
        Application.get_env(
          :gtfs_planner,
          :pathways_runner_failure_reason,
          %{reason: :no_walkability_tests}
        )

      _ = GtfsPlanner.Validations.mark_pathways_failed(validation_run, failure_reason)

      case Application.get_env(:gtfs_planner, :pathways_runner_test_pid) do
        pid when is_pid(pid) ->
          send(pid, {:pathways_runner_failed, validation_run.id, failure_reason})

        _other ->
          :ok
      end

      :ok
    end
  end

  defmodule PathwaysRunnerNoProgressMock do
    def run(validation_run, _organization_id, _gtfs_version_id, opts) do
      case Application.get_env(:gtfs_planner, :pathways_runner_test_pid) do
        pid when is_pid(pid) ->
          send(pid, {:pathways_runner_no_progress_started, validation_run.id, opts})

        _other ->
          :ok
      end

      Process.sleep(350)

      try do
        _ =
          GtfsPlanner.Validations.mark_pathways_failed(validation_run, %{reason: :test_complete})
      rescue
        Ecto.StaleEntryError -> :ok
      end

      :ok
    end
  end

  defmodule PathwaysRunnerDetailedProgressMock do
    def run(validation_run, _organization_id, _gtfs_version_id, opts) do
      status_callback = Keyword.get(opts, :status_callback)

      if is_function(status_callback, 1) do
        status_callback.(%{scope: :gtfs, phase: :packaging})
      end

      case Application.get_env(:gtfs_planner, :pathways_runner_test_pid) do
        pid when is_pid(pid) ->
          send(
            pid,
            {:pathways_runner_detailed_progress_started, validation_run.id,
             is_function(status_callback, 1)}
          )

        _other ->
          :ok
      end

      Process.sleep(350)

      try do
        _ =
          GtfsPlanner.Validations.mark_pathways_failed(validation_run, %{reason: :test_complete})
      rescue
        Ecto.StaleEntryError -> :ok
      end

      :ok
    end
  end

  defmodule PreflightOkMock do
    def run(_organization_id, _gtfs_version_id), do: :ok
  end

  defmodule PreflightIssuesMock do
    def run(_organization_id, _gtfs_version_id) do
      {:error,
       [
         %{
           code: :stop_times_trip_id_missing_trip,
           severity: :error,
           message: "stop_times.txt.trip_id -> trips.txt.trip_id — 5 invalid",
           details: %{
             source_file: "stop_times.txt",
             source_field: "trip_id",
             target_file: "trips.txt",
             target_field: "trip_id",
             invalid_count: 5
           }
         },
         %{
           code: :missing_required_file_data,
           severity: :error,
           message: "Required GTFS file data is missing",
           details: %{file: "calendar.txt"}
         }
       ]}
    end
  end

  defmodule ExportModuleMock do
    def export_to_zip(organization_id, gtfs_version_id, export_type, _opts \\ []) do
      case Application.get_env(:gtfs_planner, :export_test_pid) do
        pid when is_pid(pid) ->
          send(pid, {:export_to_zip_called, organization_id, gtfs_version_id, export_type})

        _other ->
          :ok
      end

      {:ok, "zip-binary"}
    end
  end

  defmodule ExportModuleShouldNotBeCalledMock do
    def export_to_zip(_organization_id, _gtfs_version_id, _export_type, _opts \\ []) do
      raise "export_to_zip should not be called for pathways export"
    end
  end

  defmodule MaterializerBlockingMock do
    def get_or_build_gtfs_zip(organization_id, gtfs_version_id, opts) do
      case Application.get_env(:gtfs_planner, :export_test_pid) do
        pid when is_pid(pid) ->
          send(pid, {:materializer_called, organization_id, gtfs_version_id, opts})

        _other ->
          :ok
      end

      {:error,
       [
         %{
           code: :boarding_area_parent_station_missing,
           severity: :blocking,
           message: "Boarding area ba-22 is missing parent_station in stops.txt.",
           context: %{file: "stops.txt", field: "parent_station", stop_id: "ba-22"}
         }
       ]}
    end
  end

  defmodule MaterializerLenientMock do
    def get_or_build_gtfs_zip(organization_id, gtfs_version_id, opts) do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "materializer-lenient-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      zip_path = Path.join(temp_dir, "gtfs.zip")
      File.write!(zip_path, "zip-binary")

      otp_preflight_issues =
        Application.get_env(:gtfs_planner, :materializer_mock_otp_preflight_issues, [])

      case Application.get_env(:gtfs_planner, :export_test_pid) do
        pid when is_pid(pid) ->
          send(pid, {:materializer_called, organization_id, gtfs_version_id, opts})
          send(pid, {:materializer_temp_dir, temp_dir})

        _other ->
          :ok
      end

      {:ok, zip_path, %{preflight_warnings: [], otp_preflight_issues: otp_preflight_issues}}
    end
  end

  defmodule MaterializerShouldNotBeCalledMock do
    def get_or_build_gtfs_zip(_organization_id, _gtfs_version_id, _opts) do
      raise "materializer should not be called for full export"
    end
  end

  # Make sure mocks are verified after each test
  setup :verify_on_exit!

  setup do
    previous_runtime_module = Application.get_env(:gtfs_planner, :otp_runtime_module)

    previous_pathways_validity_module =
      Application.get_env(:gtfs_planner, :otp_pathways_validity_module)

    Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeMock)
    Application.put_env(:gtfs_planner, :otp_pathways_validity_module, PathwaysValidityMock)

    on_exit(fn ->
      if previous_runtime_module do
        Application.put_env(:gtfs_planner, :otp_runtime_module, previous_runtime_module)
      else
        Application.delete_env(:gtfs_planner, :otp_runtime_module)
      end

      if previous_pathways_validity_module do
        Application.put_env(
          :gtfs_planner,
          :otp_pathways_validity_module,
          previous_pathways_validity_module
        )
      else
        Application.delete_env(:gtfs_planner, :otp_pathways_validity_module)
      end
    end)

    :ok
  end

  describe "ExportLive Validation" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS editor role
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)
      # Create an agency so there is at least some data to export
      _agency = agency_fixture(organization.id, gtfs_version.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "shows 'Run Validation' button by default", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/export")

      assert html =~ "Run Validation"
      assert html =~ "MobilityData GTFS Validator"
    end

    test "can toggle validation selection", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Click mobility_data checkbox
      view
      |> element("input[phx-value-validation='mobility_data']")
      |> render_click()

      # It should be checked
      assert has_element?(view, "input[phx-value-validation='mobility_data'][checked]")
    end

    test "clicking 'Run Validation' with no selection shows guidance flash", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("button", "Run Validation") |> render_click()

      assert render(view) =~ "Select at least one validation check before running validation"
    end

    test "pathways trip tests selection enters validating state after run click", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "progress.progress") or
             has_element?(view, "#pathways-summary-metrics") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert has_element?(view, "progress.progress") ||
               has_element?(view, "#pathways-summary-metrics")
    end

    test "pathways run start shows initial progress label", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerNoProgressMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_no_progress_started, run_id, opts}, 500
      assert is_function(opts[:status_callback], 1)

      # Poll until progress label appears
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        html = render(view)

        if html =~ "Running pathways trip test..." do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert render(view) =~ "Running pathways trip test..."

      # Poll until run completes
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        run = Validations.get_validation_run!(run_id)

        if run.status == "failed" do
          {:halt, :done}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert Validations.get_validation_run!(run_id).status == "failed"
    end

    test "pathways detailed progress is preserved across poll updates", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerDetailedProgressMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_detailed_progress_started, run_id, true}, 500

      # Poll until detailed progress label appears
      html =
        Enum.reduce_while(1..40, "", fn _, _acc ->
          html = render(view)

          if html =~ "Packaging GTFS zip..." do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert html =~ "Packaging GTFS zip..."
      refute html =~ "Running pathways trip test..."

      # Poll until run completes
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        run = Validations.get_validation_run!(run_id)

        if run.status == "failed" do
          {:halt, :done}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert Validations.get_validation_run!(run_id).status == "failed"
    end

    test "pathways run completes in persistence when runtime succeeds", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeFinishedSuitePhaseMock)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until run completes
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)
        runs = Validations.list_recent_validation_runs(organization.id, version.id, 5)

        if Enum.any?(runs, &(&1.run_type == "pathways_tests" and &1.status == "completed")) do
          {:halt, :done}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      [latest_run | _rest] =
        Validations.list_recent_validation_runs(organization.id, version.id, 5)

      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "completed"
    end

    test "pathways run persists summary metrics", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until run completes
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)
        runs = Validations.list_recent_validation_runs(organization.id, version.id, 5)

        if Enum.any?(runs, &(&1.run_type == "pathways_tests" and &1.status == "completed")) do
          {:halt, :done}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      [latest_run | _rest] =
        Validations.list_recent_validation_runs(organization.id, version.id, 5)

      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "completed"
      assert latest_run.result_json["summary"]["total"] == 3
      assert latest_run.result_json["summary"]["passed"] == 2
      assert latest_run.result_json["summary"]["failed"] == 1
      assert latest_run.result_json["summary"]["query_failure"] == 1
    end

    test "pathways run transitions from status polling to persisted summary rendering", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until summary metrics render
      Enum.reduce_while(1..60, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#pathways-summary-metrics") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert has_element?(view, "#pathways-summary-metrics")
      assert has_element?(view, "a", "View Full Results")

      html = render(view)
      assert html =~ "Total"
      assert html =~ "3"
      assert html =~ "Passed"
      assert html =~ "2"
      assert html =~ "Failed"
      assert html =~ "1"
    end

    test "pathways validation run is persisted as failed when prep fails", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeFailMock)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until validation error panel appears
      Enum.reduce_while(1..60, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#validation-error-panel") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      [latest_run | _rest] =
        Validations.list_recent_validation_runs(organization.id, version.id, 5)

      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "failed"
      assert latest_run.error_details =~ "pathways_tests"
      assert latest_run.error_details =~ "otp_start_failed"
      html = render(view)
      assert html =~ "Failed to start OTP runtime." or html =~ "OTP pathways build failed"
    end

    test "pathways run start shows initial progress label", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerNoProgressMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_no_progress_started, run_id, opts}, 500
      assert is_function(opts[:status_callback], 1)

      Process.sleep(250)

      assert render(view) =~ "Running pathways trip test..."

      Process.sleep(200)
      assert Validations.get_validation_run!(run_id).status == "failed"
    end

    test "pathways detailed progress is preserved across poll updates", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerDetailedProgressMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_detailed_progress_started, run_id, true}, 500

      Process.sleep(250)

      html = render(view)
      assert html =~ "Packaging GTFS zip..."
      refute html =~ "Running pathways trip test..."

      Process.sleep(200)
      assert Validations.get_validation_run!(run_id).status == "failed"
    end

    test "pathways run completes in persistence when runtime succeeds", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeFinishedSuitePhaseMock)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      Process.sleep(250)

      [latest_run | _rest] =
        Validations.list_recent_validation_runs(organization.id, version.id, 5)

      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "completed"
    end

    test "pathways run persists summary metrics", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      Process.sleep(250)

      [latest_run | _rest] =
        Validations.list_recent_validation_runs(organization.id, version.id, 5)

      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "completed"
      assert latest_run.result_json["summary"]["total"] == 3
      assert latest_run.result_json["summary"]["passed"] == 2
      assert latest_run.result_json["summary"]["failed"] == 1
      assert latest_run.result_json["summary"]["query_failure"] == 1
    end

    test "pathways run transitions from status polling to persisted summary rendering", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      Process.sleep(600)

      assert has_element?(view, "#pathways-summary-metrics")
      assert has_element?(view, "a", "View Full Results")

      html = render(view)
      assert html =~ "Total"
      assert html =~ "3"
      assert html =~ "Passed"
      assert html =~ "2"
      assert html =~ "Failed"
      assert html =~ "1"
    end

    test "pathways validation run is persisted as failed when prep fails", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeFailMock)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      Process.sleep(600)

      [latest_run | _rest] =
        Validations.list_recent_validation_runs(organization.id, version.id, 5)

      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "failed"
      assert latest_run.error_details =~ "pathways_tests"
      assert latest_run.error_details =~ "otp_start_failed"
      assert render(view) =~ "Failed to start OTP runtime."
    end

    test "uses configured runtime module for pathways prep failures", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeFailMock)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until error panel appears
      Enum.reduce_while(1..60, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#validation-error-panel") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      [latest_run | _rest] =
        Validations.list_recent_validation_runs(organization.id, version.id, 5)

      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "failed"
      assert latest_run.error_details =~ "otp_start_failed"
    end

    test "pathways prep failure clears validating progress state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeFailMock)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until error panel appears
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#validation-error-panel") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert has_element?(view, "#validation-error-panel")
      refute has_element?(view, "progress.progress")
      refute has_element?(view, "button", "Run Again")
      assert has_element?(view, "button", "Run Validation")
    end

    test "pathways run succeeds when runtime emits OTP phase statuses", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeSlowOtpPhaseMock)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until run completes
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)
        runs = Validations.list_recent_validation_runs(organization.id, version.id, 5)

        if Enum.any?(runs, &(&1.run_type == "pathways_tests" and &1.status == "completed")) do
          {:halt, :done}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      [latest_run | _rest] =
        Validations.list_recent_validation_runs(organization.id, version.id, 5)

      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "completed"
    end

    test "pathways lock conflict is persisted as structured failure", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeLockConflictMock)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until error panel appears
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#validation-error-panel") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      [latest_run | _rest] =
        Validations.list_recent_validation_runs(organization.id, version.id, 5)

      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "failed"
      assert latest_run.error_details =~ "otp_runtime_already_running"
      assert has_element?(view, "#validation-error-panel")

      html = render(view)

      assert html =~ "Another pathways runtime is already active for this organization." or
               html =~ "OTP pathways build failed" or html =~ "Pathways validation failed"
    end

    test "renders structured pathways failure message from failure reason", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      previous_failure_reason =
        Application.get_env(:gtfs_planner, :pathways_runner_failure_reason)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerFailReasonMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

      Application.put_env(
        :gtfs_planner,
        :pathways_runner_failure_reason,
        %{reason: :no_walkability_tests, details: %{source: :suite}}
      )

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end

        if previous_failure_reason do
          Application.put_env(
            :gtfs_planner,
            :pathways_runner_failure_reason,
            previous_failure_reason
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_failure_reason)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_failed, run_id, %{reason: :no_walkability_tests}}, 500

      # Poll until error panel renders
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#validation-error-panel") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      run = Validations.get_validation_run!(run_id)
      assert run.status == "failed"
      assert run.error_details =~ "no_walkability_tests"

      assert has_element?(view, "#validation-error-panel")
      assert has_element?(view, "#pathways-failure-title", "No pathways tests configured")
      assert has_element?(view, "#pathways-failure-checks")

      assert render(view) =~ "No pathways tests are configured for this GTFS version."
    end

    test "pathways runner spawn failures render the rich failure panel", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_task_supervisor =
        Application.get_env(:gtfs_planner, :pathways_trip_test_task_supervisor)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_task_supervisor,
        :missing_task_supervisor
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

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until error panel appears
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#validation-error-panel") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert has_element?(view, "#validation-error-panel")
      assert has_element?(view, "#pathways-failure-title", "Pathways test run could not start")
      assert has_element?(view, "#pathways-failure-checks")
      assert has_element?(view, "#pathways-failure-diagnostics")

      html = render(view)
      assert html =~ "Pathways validation could not start."
    end

    test "renders graph build diagnostics for OTP runtime failure", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      previous_failure_reason =
        Application.get_env(:gtfs_planner, :pathways_runner_failure_reason)

      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "pathways-build-log-#{System.unique_integer([:positive])}"
        )

      build_log_path = Path.join(temp_dir, "build.log")

      File.mkdir_p!(temp_dir)

      File.write!(
        build_log_path,
        """
        java.lang.NullPointerException
        at org.opentripplanner.transit.model.site.BoardingArea.<init>(BoardingArea.java:17)
        """
      )

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerFailReasonMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

      Application.put_env(
        :gtfs_planner,
        :pathways_runner_failure_reason,
        %{
          reason: :otp_runtime_failed,
          issues: [
            %{
              code: :build_failed,
              details: %{
                reason_code: :build_command_failed,
                exit_status: 255,
                graph_path: "/tmp/Graph.obj",
                build_log_path: build_log_path
              }
            }
          ]
        }
      )

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end

        if previous_failure_reason do
          Application.put_env(
            :gtfs_planner,
            :pathways_runner_failure_reason,
            previous_failure_reason
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_failure_reason)
        end

        File.rm_rf(temp_dir)
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_failed, run_id, %{reason: :otp_runtime_failed}}, 500

      # Poll until error panel renders
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#validation-error-panel") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      run = Validations.get_validation_run!(run_id)
      assert run.status == "failed"

      html = render(view)

      assert html =~ "Pathways validation failed during OTP runtime." or
               html =~ "OTP pathways build failed"

      assert html =~ "Exit status:" or html =~ "exit status 255"
      assert html =~ "255"
      assert html =~ "Build log path:" or html =~ "OTP graph build command failed"
      assert html =~ build_log_path
      assert html =~ "Build log excerpt:"
      assert html =~ "java.lang.NullPointerException"
      assert html =~ "Likely cause:"

      assert html =~
               "NullPointerException often indicates a child stop is missing a valid parent_station assignment."

      assert has_element?(view, "#otp-data-requirements-summary")
      assert html =~ "OTP data requirements (quick checks)"
      assert html =~ "Boarding areas (location_type=4) need a valid parent_station."
    end

    test "renders category-specific copy and diagnostics for boarding area parent failures", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      previous_failure_reason =
        Application.get_env(:gtfs_planner, :pathways_runner_failure_reason)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerFailReasonMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

      Application.put_env(
        :gtfs_planner,
        :pathways_runner_failure_reason,
        %{
          reason: :otp_runtime_failed,
          details: %{reason_code: :build_command_failed},
          issues: [
            %{
              code: :build_failed,
              details: %{
                message: "location_type=4 has unresolved parent_station",
                reason_code: :build_command_failed,
                exit_status: 65,
                build_log_path: "/tmp/otp/boarding-area-build.log"
              }
            }
          ]
        }
      )

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end

        if previous_failure_reason do
          Application.put_env(
            :gtfs_planner,
            :pathways_runner_failure_reason,
            previous_failure_reason
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_failure_reason)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_failed, run_id, %{reason: :otp_runtime_failed}}, 500

      # Poll until error panel renders
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#validation-error-panel") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      run = Validations.get_validation_run!(run_id)
      assert run.status == "failed"

      assert has_element?(view, "#pathways-failure-title", "Boarding area parent data is invalid")
      assert has_element?(view, "#pathways-failure-summary")
      assert has_element?(view, "#pathways-failure-checks")
      assert has_element?(view, "#pathways-failure-diagnostics")

      html = render(view)
      assert html =~ "Some boarding areas are missing valid parent station references."
      assert html =~ "location_type=4"
      assert html =~ "parent_station"
      assert html =~ "Reason code:"
      assert html =~ "build_command_failed"
      assert html =~ "Exit status:"
      assert html =~ "65"
      assert html =~ "Build log path:"
      assert html =~ "/tmp/otp/boarding-area-build.log"
    end

    test "renders blocking issues from structured failure payload", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      previous_failure_reason =
        Application.get_env(:gtfs_planner, :pathways_runner_failure_reason)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerFailReasonMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

      Application.put_env(
        :gtfs_planner,
        :pathways_runner_failure_reason,
        %{
          reason: :otp_runtime_failed,
          issues: [
            %{
              code: :boarding_area_parent_station_missing,
              severity: :blocking,
              message: "Boarding area ba-1 is missing parent_station in stops.txt.",
              context: %{file: "stops.txt", field: "parent_station", stop_id: "ba-1"}
            }
          ]
        }
      )

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end

        if previous_failure_reason do
          Application.put_env(
            :gtfs_planner,
            :pathways_runner_failure_reason,
            previous_failure_reason
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_failure_reason)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_failed, _run_id, %{reason: :otp_runtime_failed}}, 500

      # Poll until blocking issues render
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#pathways-failure-blocking-issues") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert has_element?(view, "#pathways-failure-blocking-issues")

      html = render(view)
      assert html =~ "Blocking issues"
      assert html =~ "Boarding area ba-1 is missing parent_station in stops.txt."
      assert html =~ "file: stops.txt"
      assert html =~ "field: parent_station"
      assert html =~ "stop_id: ba-1"
    end

    test "pathways readiness block clears spinner and renders blocking issues", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      previous_failure_reason =
        Application.get_env(:gtfs_planner, :pathways_runner_failure_reason)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerFailReasonMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

      Application.put_env(
        :gtfs_planner,
        :pathways_runner_failure_reason,
        %{
          reason: :pathways_export_prep_failed,
          issues: [
            %{
              code: :boarding_area_parent_station_missing,
              severity: :blocking,
              message: "Boarding area ba-17 is missing parent_station in stops.txt.",
              context: %{file: "stops.txt", field: "parent_station", stop_id: "ba-17"}
            }
          ]
        }
      )

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end

        if previous_failure_reason do
          Application.put_env(
            :gtfs_planner,
            :pathways_runner_failure_reason,
            previous_failure_reason
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_failure_reason)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_failed, _run_id, %{reason: :pathways_export_prep_failed}},
                     500

      # Poll until error panel renders
      Enum.reduce_while(1..40, :waiting, fn _, _acc ->
        render(view)

        if has_element?(view, "#validation-error-panel") do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert has_element?(view, "#validation-error-panel")
      assert has_element?(view, "#pathways-failure-blocking-issues")
      refute has_element?(view, "progress.progress")

      html = render(view)
      assert html =~ "Boarding area ba-17 is missing parent_station in stops.txt."
      assert html =~ "file: stops.txt"
      assert html =~ "field: parent_station"
      assert html =~ "stop_id: ba-17"
      assert has_element?(view, "button", "Run Validation")
    end

    test "pathways start delegates to context entrypoint runner path", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runtime_module = Application.get_env(:gtfs_planner, :otp_runtime_module)

      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeShouldNotBeCalledMock)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerNotifyMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

      on_exit(fn ->
        if previous_runtime_module do
          Application.put_env(:gtfs_planner, :otp_runtime_module, previous_runtime_module)
        else
          Application.delete_env(:gtfs_planner, :otp_runtime_module)
        end

        if previous_runner_module do
          Application.put_env(
            :gtfs_planner,
            :pathways_trip_test_runner_module,
            previous_runner_module
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_trip_test_runner_module)
        end

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_invoked, run_id, org_id, version_id}, 500
      assert org_id == organization.id
      assert version_id == version.id

      run = Validations.get_validation_run!(run_id)
      assert run.run_type == "pathways_tests"
      assert run.status in ["running", "failed"]
    end

    test "starts a new pathways run even when a completed run exists", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerNotifyMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end
      end)

      completed_run = completed_pathways_run_fixture(organization.id, version.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_invoked, run_id, org_id, version_id}, 500
      assert org_id == organization.id
      assert version_id == version.id

      started_run = Validations.get_validation_run!(run_id)
      assert started_run.run_type == "pathways_tests"
      assert started_run.status in ["running", "failed"]
      refute started_run.id == completed_run.id
    end

    test "renders structured pathways failure message from failure reason", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      previous_failure_reason =
        Application.get_env(:gtfs_planner, :pathways_runner_failure_reason)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerFailReasonMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

      Application.put_env(
        :gtfs_planner,
        :pathways_runner_failure_reason,
        %{reason: :no_walkability_tests, details: %{source: :suite}}
      )

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end

        if previous_failure_reason do
          Application.put_env(
            :gtfs_planner,
            :pathways_runner_failure_reason,
            previous_failure_reason
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_failure_reason)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_failed, run_id, %{reason: :no_walkability_tests}}, 500

      Process.sleep(300)

      run = Validations.get_validation_run!(run_id)
      assert run.status == "failed"
      assert run.error_details =~ "no_walkability_tests"

      assert render(view) =~ "No pathways tests are configured for this GTFS version."
    end

    test "pathways runner spawn failures render the rich failure panel", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_task_supervisor =
        Application.get_env(:gtfs_planner, :pathways_trip_test_task_supervisor)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_task_supervisor,
        :missing_task_supervisor
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

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      Process.sleep(150)

      assert has_element?(view, "#validation-error-panel")
      assert has_element?(view, "#pathways-failure-title", "Pathways test run could not start")
      assert has_element?(view, "#pathways-failure-checks")
      assert has_element?(view, "#pathways-failure-diagnostics")

      html = render(view)
      assert html =~ "Pathways validation could not start."
    end

    test "renders graph build diagnostics for OTP runtime failure", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      previous_failure_reason =
        Application.get_env(:gtfs_planner, :pathways_runner_failure_reason)

      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "pathways-build-log-#{System.unique_integer([:positive])}"
        )

      build_log_path = Path.join(temp_dir, "build.log")

      File.mkdir_p!(temp_dir)

      File.write!(
        build_log_path,
        """
        java.lang.NullPointerException
        at org.opentripplanner.transit.model.site.BoardingArea.<init>(BoardingArea.java:17)
        """
      )

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerFailReasonMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

      Application.put_env(
        :gtfs_planner,
        :pathways_runner_failure_reason,
        %{
          reason: :otp_runtime_failed,
          issues: [
            %{
              code: :build_failed,
              details: %{
                reason_code: :build_command_failed,
                exit_status: 255,
                graph_path: "/tmp/Graph.obj",
                build_log_path: build_log_path
              }
            }
          ]
        }
      )

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end

        if previous_failure_reason do
          Application.put_env(
            :gtfs_planner,
            :pathways_runner_failure_reason,
            previous_failure_reason
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_failure_reason)
        end

        File.rm_rf(temp_dir)
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_failed, run_id, %{reason: :otp_runtime_failed}}, 500

      Process.sleep(300)

      run = Validations.get_validation_run!(run_id)
      assert run.status == "failed"

      html = render(view)
      assert html =~ "Pathways validation failed during OTP runtime."
      assert html =~ "OTP graph build command failed"
      assert html =~ "exit status 255"
      assert html =~ "BoardingArea NullPointerException"
      assert html =~ build_log_path
    end

    test "pathways start delegates to context entrypoint runner path", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runtime_module = Application.get_env(:gtfs_planner, :otp_runtime_module)

      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeShouldNotBeCalledMock)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerNotifyMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

      on_exit(fn ->
        if previous_runtime_module do
          Application.put_env(:gtfs_planner, :otp_runtime_module, previous_runtime_module)
        else
          Application.delete_env(:gtfs_planner, :otp_runtime_module)
        end

        if previous_runner_module do
          Application.put_env(
            :gtfs_planner,
            :pathways_trip_test_runner_module,
            previous_runner_module
          )
        else
          Application.delete_env(:gtfs_planner, :pathways_trip_test_runner_module)
        end

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_invoked, run_id, org_id, version_id}, 500
      assert org_id == organization.id
      assert version_id == version.id

      run = Validations.get_validation_run!(run_id)
      assert run.run_type == "pathways_tests"
      assert run.status in ["running", "failed"]
    end

    test "starts a new pathways run even when a completed run exists", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_runner_test_pid =
        Application.get_env(:gtfs_planner, :pathways_runner_test_pid)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        PathwaysRunnerNotifyMock
      )

      Application.put_env(:gtfs_planner, :pathways_runner_test_pid, self())

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

        if previous_runner_test_pid do
          Application.put_env(:gtfs_planner, :pathways_runner_test_pid, previous_runner_test_pid)
        else
          Application.delete_env(:gtfs_planner, :pathways_runner_test_pid)
        end
      end)

      completed_run = completed_pathways_run_fixture(organization.id, version.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert_receive {:pathways_runner_invoked, run_id, org_id, version_id}, 500
      assert org_id == organization.id
      assert version_id == version.id

      started_run = Validations.get_validation_run!(run_id)
      assert started_run.run_type == "pathways_tests"
      assert started_run.status in ["running", "failed"]
      refute started_run.id == completed_run.id
    end

    test "mobility-only path does not invoke OTP runtime pathway", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeShouldNotBeCalledMock)

      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:error, :validator_path_not_configured}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until validation result appears
      Enum.reduce_while(1..20, :waiting, fn _, _acc ->
        html = render(view)

        if html =~ "Validation failed" do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert render(view) =~ "Validation failed"
    end

    test "starts validation when validator is selected and button is clicked", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to simulate a quick failure (no Java)
      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:error, :validator_path_not_configured}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Select validator
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()

      # Run validation
      view |> element("button", "Run Validation") |> render_click()

      # Poll until validation result appears
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if html =~ "Validation failed" do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert html =~ "Validation failed"
    end

    test "updates progress bar via PubSub", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to broadcast progress updates
      stub(ValidatorMock, :validate, fn _org_id, _version_id, opts ->
        validation_id = Keyword.fetch!(opts, :validation_run_id)

        # Simulate progress broadcasts
        Phoenix.PubSub.broadcast(
          GtfsPlanner.PubSub,
          "validation:#{validation_id}",
          {:validation_progress, %{phase: :validating, percent: 50, message: "Testing..."}}
        )

        # Keep the task running to maintain validating state
        Process.sleep(200)
        {:error, :test_timeout}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Select validator and run
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until progress label appears
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if html =~ "Running validator..." do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert html =~ "Running validator..."
    end

    test "displays results when validation completes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to return a successful result
      result = %GtfsPlanner.Gtfs.Validator.Result{
        summary: %{errors: 1, warnings: 2, infos: 3},
        notices: [],
        duration_ms: 1000,
        validated_at: DateTime.utc_now()
      }

      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:ok, result}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Select and run
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until validation results render
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if html =~ "View Full Results" do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert html =~ "Errors"
      assert html =~ "1"
      assert html =~ "Warnings"
      assert html =~ "2"
      assert html =~ "View Full Results"
    end

    test "handles validation failure", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to return an error
      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:error, :cli_failed}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Select and run
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until validation error renders
      Enum.reduce_while(1..20, :waiting, fn _, _acc ->
        html = render(view)

        if html =~ "Validation failed" do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert render(view) =~ "Validation failed: :cli_failed"
      # Should be back to initial state (Run Validation button visible)
      assert has_element?(view, "button", "Run Validation")
    end

    test "validation failure path does not purge staged OTP artifacts", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      runtime_path =
        Path.join(
          System.tmp_dir!(),
          "export-live-runtime-failure-#{System.unique_integer([:positive])}"
        )

      artifacts_path =
        Path.join(
          System.tmp_dir!(),
          "export-live-artifacts-failure-#{System.unique_integer([:positive])}"
        )

      previous_runtime_path = Application.get_env(:gtfs_planner, :otp_runtime_path)
      previous_artifacts_path = Application.get_env(:gtfs_planner, :otp_artifacts_path)

      Application.put_env(:gtfs_planner, :otp_runtime_path, runtime_path)
      Application.put_env(:gtfs_planner, :otp_artifacts_path, artifacts_path)

      on_exit(fn ->
        if previous_runtime_path do
          Application.put_env(:gtfs_planner, :otp_runtime_path, previous_runtime_path)
        else
          Application.delete_env(:gtfs_planner, :otp_runtime_path)
        end

        if previous_artifacts_path do
          Application.put_env(:gtfs_planner, :otp_artifacts_path, previous_artifacts_path)
        else
          Application.delete_env(:gtfs_planner, :otp_artifacts_path)
        end

        File.rm_rf(runtime_path)
        File.rm_rf(artifacts_path)
      end)

      graph_path = GraphPath.graph_obj_path(organization.id, version.id)
      zip_path = ArtifactPath.artifact_zip_path(organization.id, version.id)

      File.mkdir_p!(Path.dirname(graph_path))
      File.write!(graph_path, "graph")
      File.mkdir_p!(Path.dirname(zip_path))
      File.write!(zip_path, "gtfs")

      assert {:ok, _artifact} =
               Otp.upsert_artifact(%{
                 organization_id: organization.id,
                 gtfs_version_id: version.id,
                 zip_path: zip_path,
                 content_hash: "hash-failure",
                 file_size_bytes: 4,
                 manifest_json: %{"files" => ["agency.txt"]}
               })

      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:error, :cli_failed}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until validation error renders
      Enum.reduce_while(1..20, :waiting, fn _, _acc ->
        html = render(view)

        if html =~ "Validation failed" do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert render(view) =~ "Validation failed: :cli_failed"
      assert File.exists?(graph_path)
      assert File.exists?(zip_path)
      assert {:ok, _artifact} = Otp.fetch_artifact(organization.id, version.id)
    end

    test "can reset validation to run again", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to return a successful result
      result = %GtfsPlanner.Gtfs.Validator.Result{
        summary: %{errors: 0, warnings: 0, infos: 0},
        notices: [],
        duration_ms: 100,
        validated_at: DateTime.utc_now()
      }

      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:ok, result}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Run and complete
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Poll until results render
      Enum.reduce_while(1..20, :waiting, fn _, _acc ->
        html = render(view)

        if html =~ "View Full Results" do
          {:halt, :found}
        else
          Process.sleep(25)
          {:cont, :waiting}
        end
      end)

      assert render(view) =~ "View Full Results"

      # Click Run Again
      view |> element("button", "Run Again") |> render_click()

      # Should be back to initial state
      assert has_element?(view, "button", "Run Validation")
      refute render(view) =~ "View Full Results"
    end

    test "recent validations table maps pathways counts to error warning info columns", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, walkability_test_failed} =
        Validations.create_walkability_test(organization.id, version.id, %{
          stop_id: "stop-failed",
          address: "101 Failed St",
          address_lat: Decimal.new("42.3601"),
          address_lon: Decimal.new("-71.0589"),
          expected_traversable: true
        })

      {:ok, walkability_test_warning} =
        Validations.create_walkability_test(organization.id, version.id, %{
          stop_id: "stop-warning",
          address: "102 Warning St",
          address_lat: Decimal.new("42.3602"),
          address_lon: Decimal.new("-71.0588"),
          expected_max_distance_meters: 300
        })

      {:ok, walkability_test_pass} =
        Validations.create_walkability_test(organization.id, version.id, %{
          stop_id: "stop-pass",
          address: "103 Pass St",
          address_lat: Decimal.new("42.3603"),
          address_lon: Decimal.new("-71.0587"),
          expected_traversable: true
        })

      {:ok, pathways_run} =
        Validations.create_pathways_validation_run(organization.id, version.id)

      pathways_result = %{
        suite_meta: %{total_candidates: 0, selected_count: 0, malformed_count: 0},
        selected_test_case_ids: [
          walkability_test_failed.id,
          walkability_test_warning.id,
          walkability_test_pass.id
        ],
        summary: %{total: 9, passed: 4, failed: 5, query_failure: 2, scoring_failure: 3},
        cases: [
          %{
            test_case_id: walkability_test_failed.id,
            status: :failed,
            failure_category: :scoring_failure,
            details: %{
              mismatches: [
                %{kind: :expected_traversable, expected: true, actual: false}
              ]
            }
          },
          %{
            test_case_id: walkability_test_warning.id,
            status: :failed,
            failure_category: :scoring_failure,
            details: %{
              mismatches: [
                %{kind: :expected_max_distance_meters, expected: 300, actual: 450.0}
              ]
            }
          },
          %{
            test_case_id: walkability_test_pass.id,
            status: :passed,
            details: %{}
          }
        ]
      }

      {:ok, pathways_run} =
        Validations.mark_pathways_completed(pathways_run, pathways_result, 100)

      {:ok, mobility_run} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      mobility_result = %{
        summary: %{errors: 7, warnings: 8, infos: 9},
        notices: [],
        duration_ms: 150
      }

      {:ok, mobility_run} = Validations.mark_completed(mobility_run, mobility_result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      assert has_element?(view, "#recent-validation-errors-#{pathways_run.id}", "1")
      assert has_element?(view, "#recent-validation-warnings-#{pathways_run.id}", "1")
      assert has_element?(view, "#recent-validation-infos-#{pathways_run.id}", "0")

      assert has_element?(view, "#recent-validation-errors-#{mobility_run.id}", "7")
      assert has_element?(view, "#recent-validation-warnings-#{mobility_run.id}", "8")
      assert has_element?(view, "#recent-validation-infos-#{mobility_run.id}", "9")
    end

    test "pathways export succeeds with warnings from preflight issues", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_export = Application.get_env(:gtfs_planner, :gtfs_export_module)
      previous_preflight = Application.get_env(:gtfs_planner, :otp_preflight_module)

      Application.put_env(:gtfs_planner, :gtfs_export_module, ExportModuleMock)

      defmodule PreflightPathwaysWarningMock do
        def run(_organization_id, _gtfs_version_id) do
          {:error,
           [
             %{
               code: :boarding_area_parent_station_missing,
               severity: :blocking,
               message: "Boarding area ba-22 is missing parent_station in stops.txt.",
               context: %{file: "stops.txt", field: "parent_station", stop_id: "ba-22"}
             }
           ]}
        end
      end

      Application.put_env(:gtfs_planner, :otp_preflight_module, PreflightPathwaysWarningMock)
      Application.put_env(:gtfs_planner, :export_test_pid, self())

      on_exit(fn ->
        if previous_export,
          do: Application.put_env(:gtfs_planner, :gtfs_export_module, previous_export),
          else: Application.delete_env(:gtfs_planner, :gtfs_export_module)

        if previous_preflight,
          do: Application.put_env(:gtfs_planner, :otp_preflight_module, previous_preflight),
          else: Application.delete_env(:gtfs_planner, :otp_preflight_module)

        Application.delete_env(:gtfs_planner, :export_test_pid)
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[name='export_type'][phx-value-type='pathways']") |> render_click()
      view |> element("button", "Export GTFS") |> render_click()

      organization_id = organization.id
      version_id = version.id

      assert_receive {:export_to_zip_called, ^organization_id, ^version_id, :pathways}, 500

      # Poll until export task completes and warning panel renders
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if has_element?(view, "#export-warning-panel") do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert html =~ "Boarding area ba-22 is missing parent_station in stops.txt."
      assert has_element?(view, "#export-warning-panel")
      assert html =~ "Export completed with warnings"
      refute html =~ "Exporting..."
      assert has_element?(view, "button", "Export GTFS")
    end

    test "full export uses direct export module path", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_export_module = Application.get_env(:gtfs_planner, :gtfs_export_module)

      previous_materializer_module =
        Application.get_env(:gtfs_planner, :otp_gtfs_materializer_module)

      previous_export_test_pid = Application.get_env(:gtfs_planner, :export_test_pid)
      previous_preflight_module = Application.get_env(:gtfs_planner, :otp_preflight_module)

      Application.put_env(:gtfs_planner, :gtfs_export_module, ExportModuleMock)

      Application.put_env(
        :gtfs_planner,
        :otp_gtfs_materializer_module,
        MaterializerShouldNotBeCalledMock
      )

      Application.put_env(:gtfs_planner, :otp_preflight_module, PreflightOkMock)
      Application.put_env(:gtfs_planner, :export_test_pid, self())

      on_exit(fn ->
        if previous_export_module do
          Application.put_env(:gtfs_planner, :gtfs_export_module, previous_export_module)
        else
          Application.delete_env(:gtfs_planner, :gtfs_export_module)
        end

        if previous_materializer_module do
          Application.put_env(
            :gtfs_planner,
            :otp_gtfs_materializer_module,
            previous_materializer_module
          )
        else
          Application.delete_env(:gtfs_planner, :otp_gtfs_materializer_module)
        end

        if previous_export_test_pid do
          Application.put_env(:gtfs_planner, :export_test_pid, previous_export_test_pid)
        else
          Application.delete_env(:gtfs_planner, :export_test_pid)
        end

        if previous_preflight_module do
          Application.put_env(:gtfs_planner, :otp_preflight_module, previous_preflight_module)
        else
          Application.delete_env(:gtfs_planner, :otp_preflight_module)
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[name='export_type'][phx-value-type='full']") |> render_click()
      view |> element("button", "Export GTFS") |> render_click()

      organization_id = organization.id
      version_id = version.id

      assert_receive {:export_to_zip_called, ^organization_id, ^version_id, :full}, 500

      # Poll until export task completes and flash renders
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if html =~ "Export completed" do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert html =~ "Export completed successfully"
    end
  end

  describe "classify_pathways_failure_category/1" do
    test "classifies malformed csv payloads" do
      payload = %{
        "reason" => "otp_runtime_failed",
        "issues" => [
          %{
            "code" => "build_failed",
            "message" => "CSV parse error: malformed row in pathways.txt"
          }
        ]
      }

      assert GtfsPlannerWeb.Gtfs.ExportLive.classify_pathways_failure_category(payload) ==
               :csv_parse_malformed_rows
    end

    test "classifies boarding area parent station integrity failures" do
      payload = %{
        "reason" => "otp_runtime_failed",
        "issues" => [
          %{
            "code" => "build_failed",
            "details" => %{"message" => "location_type=4 has unresolved parent_station"}
          }
        ]
      }

      assert GtfsPlannerWeb.Gtfs.ExportLive.classify_pathways_failure_category(payload) ==
               :boarding_area_parent_integrity
    end

    test "classifies java heap and runtime compatibility failures" do
      payload = %{
        "reason" => "otp_runtime_failed",
        "details" => %{
          "reason" => "Exception in thread main java.lang.OutOfMemoryError: Java heap space"
        }
      }

      assert GtfsPlannerWeb.Gtfs.ExportLive.classify_pathways_failure_category(payload) ==
               :java_heap_runtime_compatibility
    end

    test "classifies legacy payloads from raw error details" do
      payload = %{
        "reason" => "legacy_error_details",
        "raw_error_details" => "stop linking failed because stops are outside OSM bounds",
        "issues" => []
      }

      assert GtfsPlannerWeb.Gtfs.ExportLive.classify_pathways_failure_category(payload) ==
               :osm_coverage_stop_linking
    end

    test "falls back to unknown build failure when no classifier token matches" do
      payload = %{"reason" => "otp_runtime_failed", "issues" => [%{"code" => "build_failed"}]}

      assert GtfsPlannerWeb.Gtfs.ExportLive.classify_pathways_failure_category(payload) ==
               :unknown_build_failure
    end

  end

  describe "present_pathways_failure/2" do
    test "returns requirement-aligned copy and diagnostics for build command failures" do
      payload = %{
        "reason" => "otp_runtime_failed",
        "issues" => [
          %{
            "code" => "build_failed",
            "details" => %{
              "reason_code" => "build_command_failed",
              "exit_status" => 255,
              "build_log_path" => "/tmp/runtime/build.log"
            }
          }
        ]
      }

      presented =
        GtfsPlannerWeb.Gtfs.ExportLive.present_pathways_failure(
          :unknown_build_failure,
          payload
        )

      assert presented.category == :unknown_build_failure
      assert presented.title == "OTP pathways build failed"
      assert presented.summary =~ "build or runtime failure"
      assert length(presented.checks) >= 1
      assert presented.blocking_issues != []

      assert Enum.any?(presented.details, fn detail ->
               detail.label == "Exit status" and detail.value == "255"
             end)

      assert Enum.any?(presented.details, fn detail ->
               detail.label == "Build log path" and detail.value == "/tmp/runtime/build.log"
             end)
    end

    test "uses root build_command_failed details for diagnostics when issue details are absent" do
      payload = %{
        "reason" => "otp_runtime_failed",
        "details" => %{
          "reason_code" => "build_command_failed",
          "exit_status" => 137,
          "build_log_path" => "/tmp/otp/build.log"
        },
        "issues" => [%{"code" => "otp_runtime_failed"}]
      }

      presented =
        GtfsPlannerWeb.Gtfs.ExportLive.present_pathways_failure(
          :unknown_build_failure,
          payload
        )

      assert Enum.any?(presented.details, fn detail ->
               detail.label == "Exit status" and detail.value == "137"
             end)

      assert Enum.any?(presented.details, fn detail ->
               detail.label == "Build log path" and detail.value == "/tmp/otp/build.log"
             end)
    end

    test "returns category-specific copy with actionable checks" do
      presented =
        GtfsPlannerWeb.Gtfs.ExportLive.present_pathways_failure(
          :boarding_area_parent_integrity,
          %{"reason" => "otp_runtime_failed"}
        )

      assert presented.category == :boarding_area_parent_integrity
      assert presented.title == "Boarding area parent data is invalid"
      assert presented.summary =~ "parent station"
      assert Enum.any?(presented.checks, &String.contains?(&1, "parent_station"))
      assert presented.blocking_issues == []
    end

    test "supports non-map legacy payloads with fallback output" do
      presented =
        GtfsPlannerWeb.Gtfs.ExportLive.present_pathways_failure(
          :unknown_build_failure,
          "legacy payload"
        )

      assert presented.category == :unknown_build_failure
      assert presented.title == "OTP pathways build failed"
      assert length(presented.checks) >= 1
      assert presented.details == []
      assert presented.blocking_issues == []
    end

    test "includes build log excerpt detail when build log exists" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "presented-pathways-build-log-#{System.unique_integer([:positive])}"
        )

      build_log_path = Path.join(temp_dir, "build.log")
      File.mkdir_p!(temp_dir)

      File.write!(
        build_log_path,
        """
        INFO Loading graph inputs
        ERROR Graph build failed
        ERROR Failed to load pathways.txt due to malformed csv row
        java.lang.IllegalStateException: invalid stop linkage
        Caused by: missing parent_station
        """
      )

      on_exit(fn ->
        File.rm_rf(temp_dir)
      end)

      payload = %{
        "reason" => "otp_runtime_failed",
        "issues" => [
          %{
            "code" => "build_failed",
            "details" => %{
              "reason_code" => "build_command_failed",
              "exit_status" => 255,
              "build_log_path" => build_log_path
            }
          }
        ]
      }

      presented =
        GtfsPlannerWeb.Gtfs.ExportLive.present_pathways_failure(
          :unknown_build_failure,
          payload
        )

      assert Enum.any?(presented.details, fn detail ->
               detail.label == "Build log excerpt" and
                 String.contains?(detail.value, "ERROR Graph build failed")
             end)

      assert Enum.any?(presented.details, fn detail ->
               detail.label == "Likely GTFS source" and
                 detail.value == "Issue appears to come from pathways.txt."
             end)
    end
  end

  defp completed_pathways_run_fixture(organization_id, gtfs_version_id) do
    {:ok, run} = Validations.create_pathways_validation_run(organization_id, gtfs_version_id)

    run_result = %{
      suite_meta: %{total_candidates: 0, selected_count: 0, malformed_count: 0},
      selected_test_case_ids: [],
      summary: %{total: 3, passed: 2, failed: 1, query_failure: 1, scoring_failure: 0},
      cases: []
    }

    {:ok, completed_run} = Validations.mark_pathways_completed(run, run_result, 123)
    completed_run
  end

  describe "export preflight policy" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)
      _agency = agency_fixture(organization.id, gtfs_version.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "full export with preflight issues shows warning panel", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_export = Application.get_env(:gtfs_planner, :gtfs_export_module)
      previous_preflight = Application.get_env(:gtfs_planner, :otp_preflight_module)

      Application.put_env(:gtfs_planner, :gtfs_export_module, ExportModuleMock)
      Application.put_env(:gtfs_planner, :otp_preflight_module, PreflightIssuesMock)
      Application.put_env(:gtfs_planner, :export_test_pid, self())

      on_exit(fn ->
        if previous_export,
          do: Application.put_env(:gtfs_planner, :gtfs_export_module, previous_export),
          else: Application.delete_env(:gtfs_planner, :gtfs_export_module)

        if previous_preflight,
          do: Application.put_env(:gtfs_planner, :otp_preflight_module, previous_preflight),
          else: Application.delete_env(:gtfs_planner, :otp_preflight_module)

        Application.delete_env(:gtfs_planner, :export_test_pid)
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      organization_id = organization.id
      version_id = version.id

      view |> element("button", "Export GTFS") |> render_click()

      assert_receive {:export_to_zip_called, ^organization_id, ^version_id, :full}, 500

      # Poll until export task completes and warning panel renders
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if has_element?(view, "#export-warning-panel") do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert html =~ "2 data quality warnings"
      assert has_element?(view, "#export-warning-panel")
      assert html =~ "stop_times.txt.trip_id"
      assert html =~ "trips.txt.trip_id"
      assert html =~ "5 invalid"
      assert html =~ "Export completed with warnings"
      refute html =~ "Export completed successfully"
    end

    test "full export without preflight issues shows no warning panel", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_export = Application.get_env(:gtfs_planner, :gtfs_export_module)
      previous_preflight = Application.get_env(:gtfs_planner, :otp_preflight_module)

      Application.put_env(:gtfs_planner, :gtfs_export_module, ExportModuleMock)
      Application.put_env(:gtfs_planner, :otp_preflight_module, PreflightOkMock)
      Application.put_env(:gtfs_planner, :export_test_pid, self())

      on_exit(fn ->
        if previous_export,
          do: Application.put_env(:gtfs_planner, :gtfs_export_module, previous_export),
          else: Application.delete_env(:gtfs_planner, :gtfs_export_module)

        if previous_preflight,
          do: Application.put_env(:gtfs_planner, :otp_preflight_module, previous_preflight),
          else: Application.delete_env(:gtfs_planner, :otp_preflight_module)

        Application.delete_env(:gtfs_planner, :export_test_pid)
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      organization_id = organization.id
      version_id = version.id

      view |> element("button", "Export GTFS") |> render_click()

      assert_receive {:export_to_zip_called, ^organization_id, ^version_id, :full}, 500

      # Poll until export task completes and flash renders
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if html =~ "Export completed" do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      refute has_element?(view, "#export-warning-panel")
      assert html =~ "Export completed successfully"
    end

    test "pathways export succeeds with warnings when preflight issues are present", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_export = Application.get_env(:gtfs_planner, :gtfs_export_module)
      previous_preflight = Application.get_env(:gtfs_planner, :otp_preflight_module)

      Application.put_env(:gtfs_planner, :gtfs_export_module, ExportModuleMock)
      Application.put_env(:gtfs_planner, :otp_preflight_module, PreflightIssuesMock)
      Application.put_env(:gtfs_planner, :export_test_pid, self())

      on_exit(fn ->
        if previous_export,
          do: Application.put_env(:gtfs_planner, :gtfs_export_module, previous_export),
          else: Application.delete_env(:gtfs_planner, :gtfs_export_module)

        if previous_preflight,
          do: Application.put_env(:gtfs_planner, :otp_preflight_module, previous_preflight),
          else: Application.delete_env(:gtfs_planner, :otp_preflight_module)

        Application.delete_env(:gtfs_planner, :export_test_pid)
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[name='export_type'][phx-value-type='pathways']") |> render_click()
      view |> element("button", "Export GTFS") |> render_click()

      organization_id = organization.id
      version_id = version.id

      assert_receive {:export_to_zip_called, ^organization_id, ^version_id, :pathways}, 500

      # Poll until export task completes and warning panel renders
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if has_element?(view, "#export-warning-panel") do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert has_element?(view, "#export-warning-panel")
      assert html =~ "stop_times.txt.trip_id"
      assert html =~ "trips.txt.trip_id"
      assert html =~ "5 invalid"
      assert html =~ "Export completed with warnings"
      refute html =~ "Export completed successfully"
      refute html =~ "Exporting..."
    end

    test "pathways export deduplicates repeated warnings", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_export = Application.get_env(:gtfs_planner, :gtfs_export_module)
      previous_preflight = Application.get_env(:gtfs_planner, :otp_preflight_module)

      Application.put_env(:gtfs_planner, :gtfs_export_module, ExportModuleMock)

      defmodule PreflightPathwaysDuplicatesMock do
        def run(_organization_id, _gtfs_version_id) do
          {:error,
           [
             %{
               code: :boarding_area_parent_station_missing,
               severity: :blocking,
               message: "Boarding area ba-1 is missing parent_station.",
               context: %{file: "stops.txt", field: "parent_station", stop_id: "ba-1"}
             },
             %{
               code: :boarding_area_parent_station_missing,
               severity: :blocking,
               message: "Boarding area ba-1 is missing parent_station.",
               context: %{file: "stops.txt", field: "parent_station", stop_id: "ba-1"}
             },
             %{
               code: :boarding_area_parent_station_missing,
               severity: :blocking,
               message: "Boarding area ba-2 is missing parent_station.",
               context: %{file: "stops.txt", field: "parent_station", stop_id: "ba-2"}
             }
           ]}
        end
      end

      Application.put_env(
        :gtfs_planner,
        :otp_preflight_module,
        PreflightPathwaysDuplicatesMock
      )

      Application.put_env(:gtfs_planner, :export_test_pid, self())

      on_exit(fn ->
        if previous_export,
          do: Application.put_env(:gtfs_planner, :gtfs_export_module, previous_export),
          else: Application.delete_env(:gtfs_planner, :gtfs_export_module)

        if previous_preflight,
          do: Application.put_env(:gtfs_planner, :otp_preflight_module, previous_preflight),
          else: Application.delete_env(:gtfs_planner, :otp_preflight_module)

        Application.delete_env(:gtfs_planner, :export_test_pid)
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[name='export_type'][phx-value-type='pathways']") |> render_click()
      view |> element("button", "Export GTFS") |> render_click()

      organization_id = organization.id
      version_id = version.id

      assert_receive {:export_to_zip_called, ^organization_id, ^version_id, :pathways}, 500

      # Poll until export task completes and warning panel renders
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if has_element?(view, "#export-warning-panel") do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert has_element?(view, "#export-warning-panel")
      # 3 input warnings deduplicated to 2 (ba-1 duplicate removed)
      assert html =~ "2 data quality warning"
      assert html =~ "ba-1"
      assert html =~ "ba-2"
      assert html =~ "Export completed with warnings"
    end

    test "full export deduplicates repeated preflight warnings", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      previous_export = Application.get_env(:gtfs_planner, :gtfs_export_module)
      previous_preflight = Application.get_env(:gtfs_planner, :otp_preflight_module)

      Application.put_env(:gtfs_planner, :gtfs_export_module, ExportModuleMock)

      # Use an inline mock that returns duplicate issues
      defmodule PreflightDuplicateIssuesMock do
        def run(_organization_id, _gtfs_version_id) do
          {:error,
           [
             %{
               code: :stop_times_trip_id_missing_trip,
               severity: :error,
               message: "stop_times.txt.trip_id -> trips.txt.trip_id — 5 invalid",
               details: %{
                 source_file: "stop_times.txt",
                 source_field: "trip_id",
                 target_file: "trips.txt",
                 target_field: "trip_id",
                 invalid_count: 5
               }
             },
             %{
               code: :stop_times_trip_id_missing_trip,
               severity: :error,
               message: "stop_times.txt.trip_id -> trips.txt.trip_id — 5 invalid",
               details: %{
                 source_file: "stop_times.txt",
                 source_field: "trip_id",
                 target_file: "trips.txt",
                 target_field: "trip_id",
                 invalid_count: 5
               }
             }
           ]}
        end
      end

      Application.put_env(:gtfs_planner, :otp_preflight_module, PreflightDuplicateIssuesMock)
      Application.put_env(:gtfs_planner, :export_test_pid, self())

      on_exit(fn ->
        if previous_export,
          do: Application.put_env(:gtfs_planner, :gtfs_export_module, previous_export),
          else: Application.delete_env(:gtfs_planner, :gtfs_export_module)

        if previous_preflight,
          do: Application.put_env(:gtfs_planner, :otp_preflight_module, previous_preflight),
          else: Application.delete_env(:gtfs_planner, :otp_preflight_module)

        Application.delete_env(:gtfs_planner, :export_test_pid)
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("button", "Export GTFS") |> render_click()

      organization_id = organization.id
      version_id = version.id
      assert_receive {:export_to_zip_called, ^organization_id, ^version_id, :full}, 500

      # Poll until warning panel renders
      html =
        Enum.reduce_while(1..20, "", fn _, _acc ->
          html = render(view)

          if has_element?(view, "#export-warning-panel") do
            {:halt, html}
          else
            Process.sleep(25)
            {:cont, html}
          end
        end)

      assert has_element?(view, "#export-warning-panel")
      # 2 identical warnings deduplicated to 1
      assert html =~ "1 data quality warning"
      refute html =~ "2 data quality warning"
      assert html =~ "Export completed with warnings"
    end
  end
end
