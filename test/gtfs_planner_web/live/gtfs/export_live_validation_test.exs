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
  alias GtfsPlanner.Gtfs.ValidatorMock

  defmodule RuntimeMock do
    def prepare_runtime(organization_id, gtfs_version_id, opts) do
      send(self(), {:prepare_runtime_called, organization_id, gtfs_version_id, opts})

      case opts[:status_callback] do
        callback when is_function(callback, 1) ->
          callback.(%{scope: :gtfs, phase: :cache_check})
          callback.(%{scope: :gtfs, phase: :packaging})
          callback.(%{scope: :graph, phase: :building})
          Process.sleep(100)
          callback.(%{scope: :graph, phase: :done})

        _other ->
          :ok
      end

      {:ok,
       %{
         gtfs_zip_path: "/tmp/gtfs.zip",
         graph_path: "/tmp/Graph.obj",
         meta: %{gtfs: %{}, graph: %{}}
       }}
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :purged, gtfs: :purged}}
    end
  end

  defmodule RuntimeFailMock do
    def prepare_runtime(_organization_id, _gtfs_version_id, _opts) do
      {:error,
       [
         %{
           code: :missing_required_file_data,
           severity: :error,
           message: "Required GTFS file data is missing",
           details: %{file: "agency.txt"}
         }
       ]}
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :not_found, gtfs: :not_found}}
    end
  end

  defmodule RuntimeCrashMock do
    def prepare_runtime(_organization_id, _gtfs_version_id, _opts) do
      raise "runtime crashed"
    end

    def cleanup_on_success(_organization_id, _gtfs_version_id) do
      {:ok, %{graph: :not_found, gtfs: :not_found}}
    end
  end

  # Make sure mocks are verified after each test
  setup :verify_on_exit!

  setup do
    previous_runtime_module = Application.get_env(:gtfs_planner, :otp_runtime_module)
    Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeMock)

    on_exit(fn ->
      if previous_runtime_module do
        Application.put_env(:gtfs_planner, :otp_runtime_module, previous_runtime_module)
      else
        Application.delete_env(:gtfs_planner, :otp_runtime_module)
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

    test "pathways trip tests selection shows preparation progress after run click", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      html = render(view)

      assert html =~ "Building OTP graph..." or
               html =~ "Pathways trip test run started. Export preparation complete."
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

      assert has_element?(view, "#pathways-prep-error")

      html = render(view)
      assert html =~ "Pathways export preparation failed."
      assert html =~ "agency.txt"
    end

    test "shows inline pathways prep error when runtime crashes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.put_env(:gtfs_planner, :otp_runtime_module, RuntimeCrashMock)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("input[phx-value-validation='pathways_tests']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      assert eventually(fn -> has_element?(view, "#pathways-prep-error") end)

      assert eventually(fn ->
               render(view) =~ "Pathways export preparation crashed unexpectedly."
             end)
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

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) when is_function(fun, 0) and attempts > 0 do
    if fun.() do
      true
    else
      receive do
      after
        10 -> eventually(fun, attempts - 1)
      end
    end
  end
end
