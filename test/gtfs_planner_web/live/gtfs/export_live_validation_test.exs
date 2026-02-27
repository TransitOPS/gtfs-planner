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
          callback.(%{scope: :suite, phase: :running, completed: 0, total: 2, test_case_id: "case-1"})
          Process.sleep(180)
          callback.(%{scope: :suite, phase: :running, completed: 1, total: 2, test_case_id: "case-2"})
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
          send(pid, {:pathways_runner_invoked, validation_run.id, organization_id, gtfs_version_id})

        _other ->
          :ok
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

      Process.sleep(400)

      assert has_element?(view, "progress.progress") || has_element?(view, "#pathways-summary-metrics")
    end

    test "pathways run start shows initial progress label", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      Process.sleep(400)

      assert has_element?(view, "progress.progress") || has_element?(view, "#pathways-summary-metrics")
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

      [latest_run | _rest] = Validations.list_recent_validation_runs(organization.id, version.id, 5)
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

      [latest_run | _rest] = Validations.list_recent_validation_runs(organization.id, version.id, 5)
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

      [latest_run | _rest] = Validations.list_recent_validation_runs(organization.id, version.id, 5)
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

      Process.sleep(600)

      [latest_run | _rest] = Validations.list_recent_validation_runs(organization.id, version.id, 5)
      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "failed"
      assert latest_run.error_details =~ "otp_start_failed"
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

      Process.sleep(250)

      [latest_run | _rest] = Validations.list_recent_validation_runs(organization.id, version.id, 5)
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

      Process.sleep(100)

      [latest_run | _rest] = Validations.list_recent_validation_runs(organization.id, version.id, 5)
      assert latest_run.run_type == "pathways_tests"
      assert latest_run.status == "failed"
      assert latest_run.error_details =~ "otp_runtime_already_running"
      assert render(view) =~ "Another pathways runtime is already active for this organization."
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
          Application.put_env(:gtfs_planner, :pathways_runner_failure_reason, previous_failure_reason)
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
      assert run.status == "running"
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
      assert started_run.status == "running"
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

      Process.sleep(100)

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

      # Wait for async task to complete
      Process.sleep(100)

      html = render(view)
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

      # Wait for progress update to be broadcast and processed
      Process.sleep(100)

      html = render(view)
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

      # Wait for async task to complete
      Process.sleep(100)

      html = render(view)
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

      # Wait for async task to complete
      Process.sleep(100)

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

      Process.sleep(100)

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

      # Wait for async task to complete
      Process.sleep(100)
      assert render(view) =~ "View Full Results"

      # Click Run Again
      view |> element("button", "Run Again") |> render_click()

      # Should be back to initial state
      assert has_element?(view, "button", "Run Validation")
      refute render(view) =~ "View Full Results"
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
end
