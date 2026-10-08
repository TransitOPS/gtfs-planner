defmodule GtfsPlannerWeb.Gtfs.ExportLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Mox, only: [set_mox_global: 1, verify_on_exit!: 1]
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.Export.RunnerSupervisor
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Gtfs.ValidatorMock
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun
  alias GtfsPlanner.Versions

  @validation_supervisor GtfsPlanner.Validations.RunnerSupervisor
  @fake_java Path.expand("../../../support/fixtures/fake_validator.sh", __DIR__)

  # Trip EXP_TD has blank middle times anchored 08:00 and 08:10 over stored
  # distances 0/200/400/2400/3000: the distance estimate gives 40/80/480 second
  # shares and the even estimate 150 seconds each.
  @distance_times [
    {"EXP_D1", "08:00:00"},
    {"EXP_D2", "08:00:40"},
    {"EXP_D3", "08:01:20"},
    {"EXP_D4", "08:08:00"},
    {"EXP_D5", "08:10:00"}
  ]
  @even_times [
    {"EXP_D1", "08:00:00"},
    {"EXP_D2", "08:02:30"},
    {"EXP_D3", "08:05:00"},
    {"EXP_D4", "08:07:30"},
    {"EXP_D5", "08:10:00"}
  ]

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  # LiveView "start_export" clicks start a real Export.Runner child that holds
  # the sandbox connection while it builds. Waiting here for any runner child
  # created during the test keeps that build (or its forced teardown) inside
  # this test's on_exit, which runs before ConnCase releases the DB owner.
  @runner_exit_timeout 5_000

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

    root = Path.join(System.tmp_dir!(), "export-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    # Registered before the runner wait below: `on_exit` runs last-registered
    # first, so every owned build finishes before its artifact root is removed.
    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, previous_root)
    end)

    existing_runners = runner_pids()
    on_exit(fn -> await_new_runners(existing_runners) end)

    %{user: user, organization: organization, gtfs_version: gtfs_version}
  end

  test "runs the only validation from a single control", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version
  } do
    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

    assert has_element?(view, "#run-validation", "Check feed")
    refute has_element?(view, "#validation-checks")
    refute has_element?(view, ~s(input[type="checkbox"][name="validation[checks][]"]))
  end

  test "starts an export instead of reporting storage as unavailable", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version
  } do
    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

    html = view |> element("#start-export") |> render_click()

    refute html =~ "cannot write export files"
    assert has_element?(view, "#export-files-card")
    refute has_element?(view, "#export-files-empty")
  end

  test "renders with a recent legacy pathways_tests run present", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version
  } do
    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "pathways_tests")

    run
    |> ValidationRun.changeset(%{status: "failed"})
    |> Repo.update!()

    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

    assert has_element?(view, "#export-workspace")
    assert has_element?(view, "#recent-checks")
    assert has_element?(view, "#recent-check-#{run.id} a", "Pathways test")
    assert has_element?(view, "#recent-validation-counts-#{run.id}")
  end

  test "offers Export feed before the first export and no download", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version
  } do
    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

    assert has_element?(view, "#export-files-empty")
    assert has_element?(view, "#start-export", "Export full feed")
    refute has_element?(view, "#export-files-card [id$='-download']")
    refute has_element?(view, "#recent-checks")
  end

  describe "version switching" do
    test "an explicit selection of another published version reports it and moves",
         %{conn: conn, user: user, organization: organization, gtfs_version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

      assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})
      assert_redirect(view, "/gtfs/#{other_version.id}/export")
    end

    test "a stored selection of another published version moves without reporting a selection",
         %{conn: conn, user: user, organization: organization, gtfs_version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      render_hook(view, "gtfs_version_loaded", %{
        "version_id" => to_string(other_version.id)
      })

      assert_redirect(view, "/gtfs/#{other_version.id}/export")
      refute_push_event(view, "gtfs_version_selected", %{version_id: _})
    end

    test "staging, foreign and absent selections neither navigate nor report a selection",
         %{conn: conn, user: user, organization: organization, gtfs_version: version} do
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      for version_id <- [staging.id, foreign_version.id, Ecto.UUID.generate()] do
        render_hook(view, "switch_gtfs_version", %{"version" => to_string(version_id)})
        refute_push_event(view, "gtfs_version_selected", %{version_id: _})
        refute_redirected(view)
      end
    end

    test "a stored nil or current selection changes nothing",
         %{conn: conn, user: user, organization: organization, gtfs_version: version} do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      for version_id <- [to_string(version.id), nil] do
        render_hook(view, "gtfs_version_loaded", %{"version_id" => version_id})
        refute_redirected(view)
      end

      refute_push_event(view, "gtfs_version_selected", %{version_id: _})
    end

    test "an explicit selection of the current version is still accepted",
         %{conn: conn, user: user, organization: organization, gtfs_version: version} do
      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(version.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

      assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})
      assert_redirect(view, "/gtfs/#{version.id}/export")
    end
  end

  describe "feed check" do
    setup :set_mox_global
    setup :verify_on_exit!

    # The validator runs in a task owned by a `Validations.Runner`; wait for any
    # runner still holding the slot before the sandbox owner goes away.
    setup do
      on_exit(fn -> RunnerSlots.await_idle() end)
      :ok
    end

    test "shows the verdict and links the full results when a check finishes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_validator(%{errors: 0, warnings: 3, infos: 7})
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("#run-validation") |> render_click()
      assert has_element?(view, "#check-progress")

      release_validation(view)

      assert has_element?(view, "#mobility-summary-metrics [data-count=warnings]", "3")

      assert has_element?(
               view,
               "#check-verdict",
               "No errors. 3 warnings point to weak spots, but most trip planners still accept the feed."
             )

      assert has_element?(
               view,
               "#view-validation-results[href^='/gtfs/#{version.id}/validation/']"
             )

      assert has_element?(view, "#recent-checks a", "Feed check")
    end

    test "returns to Check feed when the reader chooses Check again", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_validator(%{errors: 0, warnings: 0, infos: 5})
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      view |> element("#run-validation") |> render_click()
      release_validation(view)

      assert has_element?(
               view,
               "#check-verdict",
               "No errors or warnings. Information notices are optional to review."
             )

      view |> element("#reset-validation") |> render_click()

      assert has_element?(view, "#run-validation", "Check feed")
      refute has_element?(view, "#mobility-summary-metrics")
    end

    @tag :capture_log
    test "says the check could not finish when the validator errors", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      hold_validator({:error, :validator_unavailable})
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      view |> element("#run-validation") |> render_click()

      release_validation(view)

      assert has_element?(view, "#validation-error-panel", "The check couldn’t finish.")
      assert has_element?(view, "#run-validation", "Try again")
      refute has_element?(view, "#validation-error-panel", "validator_unavailable")
    end

    @tag :capture_log
    test "says the check could not finish when the validator task crashes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      test_pid = self()

      Mox.stub(ValidatorMock, :validate, fn _organization_id, _version_id, _opts ->
        send(test_pid, {:validator_task, self()})

        receive do
          :release -> raise "validator crashed"
        end
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      view |> element("#run-validation") |> render_click()

      release_validation(view)

      assert has_element?(view, "#validation-error-panel", "The check couldn’t finish.")

      assert [%ValidationRun{status: "failed", error_details: "executor_lost"}] =
               Validations.list_validation_runs(organization.id, version.id)
    end

    test "says another validation is running while the slot is taken and works once it is free",
         %{conn: conn, user: user, organization: organization, gtfs_version: version} do
      stub_validator(%{errors: 0, warnings: 0, infos: 4})

      {:ok, held} =
        Validations.start_mobility_data_run(organization.id, version.id, "mobility_data", user)

      assert_receive {:validator_task, held_task}, 5_000
      {held_runner, held_ref} = monitor_validation_runner()

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      view |> element("#run-validation") |> render_click()

      assert has_element?(
               view,
               "#flash-error",
               "Another validation is running. Try again when it finishes."
             )

      assert has_element?(view, "#run-validation", "Check feed")
      refute has_element?(view, "#check-progress")

      assert [%ValidationRun{status: "failed", error_details: "busy"}] =
               refused_validation_runs(organization, version, held)

      send(held_task, :release)
      assert_receive {:DOWN, ^held_ref, :process, ^held_runner, :normal}, 5_000
      _ = :sys.get_state(@validation_supervisor)

      view |> element("#run-validation") |> render_click()
      assert has_element?(view, "#check-progress")

      release_validation(view)

      assert has_element?(
               view,
               "#check-verdict",
               "No errors or warnings. Information notices are optional to review."
             )
    end

    test "ignores the outcome of a run it is not showing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_validator(%{errors: 0, warnings: 2, infos: 0})
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      view |> element("#run-validation") |> render_click()

      send(view.pid, {:validation_completed, Ecto.UUID.generate()})
      send(view.pid, {:validation_failed, Ecto.UUID.generate()})

      assert has_element?(view, "#check-progress")
      refute has_element?(view, "#validation-error-panel")

      release_validation(view)

      assert has_element?(
               view,
               "#check-verdict",
               "No errors. 2 warnings point to weak spots, but most trip planners still accept the feed."
             )
    end

    test "refuses a check after the reader's editor role is revoked and starts no run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      {:ok, _membership} =
        user.id
        |> Accounts.get_user_org_membership(organization.id)
        |> Accounts.update_user_org_membership(%{roles: []})

      view |> element("#run-validation") |> render_click()

      assert has_element?(
               view,
               "#flash-error",
               "You no longer have permission to check this feed."
             )

      assert has_element?(view, "#run-validation", "Check feed")
      assert Validations.list_validation_runs(organization.id, version.id) == []
    end
  end

  describe "feed check through the real validator" do
    setup :set_mox_global
    setup :verify_on_exit!

    # ExportLive, Validations.Runner, Validator and Export all run for real. The
    # validator module is the mock only so the test can hold the task before it
    # starts: on release it hands the call to `Validator.validate/3` unchanged. The
    # Java process is the one replaced boundary (`fake_validator.sh`).
    setup %{organization: organization, gtfs_version: version} do
      test_pid = self()

      Mox.stub(ValidatorMock, :validate, fn organization_id, version_id, opts ->
        send(test_pid, {:validator_task, self()})

        receive do
          :release -> Validator.validate(organization_id, version_id, opts)
        end
      end)

      put_env(:java_path, @fake_java)
      seed_distance_sensitive_trip(organization, version)
      temp_dirs_before = validation_temp_dirs()

      on_exit(fn -> RunnerSlots.await_idle() end)

      %{temp_dirs_before: temp_dirs_before}
    end

    test "validates with the current estimate defaults, not an earlier export's snapshot", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      temp_dirs_before: temp_dirs_before
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # An export made under the default (distance) estimate.
      start_export_and_wait(view)
      prior = latest_full_run(organization, version)
      assert %Run{state: :ready, estimate_method: :distance} = prior
      prior_bytes = artifact_bytes(prior)
      assert trip_times(prior_bytes) == @distance_times

      # A validation after it estimates by the same default.
      first_copy = zip_copy_path()
      put_env(:gtfs_validator_path, "report@" <> first_copy)
      view |> element("#run-validation") |> render_click()
      release_validation(view)

      assert has_element?(
               view,
               "#check-verdict",
               "No errors or warnings. Information notices are optional to review."
             )

      assert trip_times(File.read!(first_copy)) == @distance_times

      # Changing the default changes the next validation and no export that exists.
      view |> element("#reset-validation") |> render_click()

      {:ok, _defaults} =
        ExportDefaults.update(organization.id, editor_fixture(organization), %{
          estimate_method: :even
        })

      second_copy = zip_copy_path()
      put_env(:gtfs_validator_path, "report@" <> second_copy)
      view |> element("#run-validation") |> render_click()
      release_validation(view)

      assert has_element?(
               view,
               "#check-verdict",
               "No errors or warnings. Information notices are optional to review."
             )

      assert trip_times(File.read!(second_copy)) == @even_times

      unchanged = Repo.get!(Run, prior.id)
      assert unchanged.estimate_method == :distance
      assert unchanged.artifact_sha256 == prior.artifact_sha256
      assert artifact_bytes(unchanged) == prior_bytes

      # Neither validation left its working files behind.
      assert validation_temp_dirs() -- temp_dirs_before == []
    end

    test "refuses a second validation while the first is held and frees everything after it ends",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version,
           temp_dirs_before: temp_dirs_before
         } do
      put_env(:gtfs_validator_path, "report")

      {:ok, held} =
        Validations.start_mobility_data_run(organization.id, version.id, "mobility_data", user)

      assert_receive {:validator_task, held_task}, 5_000
      {held_runner, held_ref} = monitor_validation_runner()

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      view |> element("#run-validation") |> render_click()

      assert has_element?(view, "#flash-error", "Another validation is running.")
      refute_receive {:validator_task, _task}
      assert validation_temp_dirs() -- temp_dirs_before == []

      send(held_task, :release)
      assert_receive {:DOWN, ^held_ref, :process, ^held_runner, :normal}, 10_000
      _ = :sys.get_state(@validation_supervisor)

      assert %ValidationRun{status: "completed"} = Repo.get!(ValidationRun, held.id)
      assert validation_temp_dirs() -- temp_dirs_before == []
      assert DynamicSupervisor.count_children(@validation_supervisor).active == 0
    end

    @tag :capture_log
    test "a cancelled run stops its Java process, removes its files and frees the slot", %{
      organization: organization,
      gtfs_version: version,
      user: user,
      temp_dirs_before: temp_dirs_before
    } do
      put_env(:gtfs_validator_path, "sleep")

      {:ok, run} =
        Validations.start_mobility_data_run(organization.id, version.id, "mobility_data", user)

      assert_receive {:validator_task, task}, 5_000
      task_ref = Process.monitor(task)
      {runner, runner_ref} = monitor_validation_runner()
      send(task, :release)

      # Shutting the runner down cancels the validator. It is still exporting (the
      # Java process is then never launched) or running it (the process is killed).
      :ok = DynamicSupervisor.terminate_child(@validation_supervisor, runner)

      assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, :shutdown}
      assert DynamicSupervisor.count_children(@validation_supervisor).active == 0
      assert validation_temp_dirs() -- temp_dirs_before == []
      assert %ValidationRun{status: "running"} = Repo.get!(ValidationRun, run.id)
    end
  end

  describe "recent checks" do
    test "summarises the last checks and reports each one's counts", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      failing =
        completed_run(organization, version, "mobility_data",
          errors_count: 2,
          warnings_count: 5,
          infos_count: 7
        )

      clean = completed_run(organization, version, "mobility_data", infos_count: 5)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      assert has_element?(view, "#recent-checks summary", "Earlier checks · 2")

      assert has_element?(view, "#recent-validation-counts-#{failing.id}", "2 errors")
      assert has_element?(view, "#recent-validation-counts-#{failing.id}", "5 warnings")
      assert has_element?(view, "#recent-validation-counts-#{clean.id}", "0 errors")
    end

    test "reports a pathways test as failed, couldn’t be checked and passed", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run =
        completed_run(organization, version, "pathways_tests",
          result_json: %{
            "summary" => %{"scoring_failure" => 2, "query_failure" => 1, "passed" => 14}
          }
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      assert has_element?(view, "#recent-validation-counts-#{run.id}", "2 failed")
      assert has_element?(view, "#recent-validation-counts-#{run.id}", "1 couldn’t be checked")
      assert has_element?(view, "#recent-validation-counts-#{run.id}", "14 passed")
    end

    test "links a station reachability check to its own results with the station's name", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stop_fixture(organization.id, version.id, stop_id: "STATION1", stop_name: "Central Station")

      run =
        completed_run(organization, version, "station_reachability",
          result_json: %{"metadata" => %{"station_stop_id" => "STATION1"}}
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      assert has_element?(
               view,
               "#recent-check-#{run.id} a",
               "Station reachability · Central Station"
             )

      assert has_element?(
               view,
               "#recent-check-#{run.id} a[href='/gtfs/#{version.id}/station-reachability/#{run.id}?stop_id=STATION1']"
             )
    end
  end

  describe "operations export" do
    test "selecting the operations option patches the URL and lists the TODS files", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      garage_fixture(organization.id, garage_id: "garage_main")
      garage_fixture(organization.id)
      vehicle_fixture(organization.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      refute has_element?(view, "#export-type-operations[checked]")
      refute has_element?(view, "#operations-export-note")

      view
      |> form("#gtfs-export-form", export: %{type: "operations"})
      |> render_change()

      assert_patch(view, "/gtfs/#{version.id}/export?type=operations")
      assert has_element?(view, "#export-type-operations[checked]")
      assert has_element?(view, "#start-export", "Export feed with operations")

      render_async(view)

      assert tods_inventory_rows(view) == [
               ["stops_supplement.txt", "2"],
               ["vehicles.txt", "1"]
             ]

      view
      |> form("#gtfs-export-form", export: %{type: "full"})
      |> render_change()

      assert_patch(view, "/gtfs/#{version.id}/export?type=full")
      assert has_element?(view, "#export-type-full[checked]")
      refute has_element?(view, "#operations-export-note")
      assert tods_inventory_rows(view) == []
    end

    test "an operations URL preselects the option and its run, and an unknown type falls back", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      assert {:ok, run} =
               ExportRuns.create_pending(organization.id, version.id, @actor, :operations)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")
      assert has_element?(view, "#export-type-operations[checked]")
      assert has_element?(view, "#export-file-#{run.id}")

      {:ok, fallback_view, _html} = live(conn, "/gtfs/#{version.id}/export?type=bogus")
      assert has_element?(fallback_view, "#export-type-full[checked]")
      assert has_element?(fallback_view, "#export-file-#{run.id}")
    end

    test "starting an operations export publishes a downloadable ZIP with both TODS files", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      agency_fixture(organization.id, version.id, agency_id: "AGENCY1")
      stop_fixture(organization.id, version.id, stop_id: "STOP1")
      route_fixture(organization.id, version.id, route_id: "ROUTE1", route_short_name: "1")
      garage_fixture(organization.id, garage_id: "garage_main", name: "Main garage")
      vehicle_fixture(organization.id, vehicle_id: "bus-1", vehicle_label: "Bus 1")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")

      start_export_and_wait(view)

      assert %Run{state: :ready} = run = latest_operations_run(organization, version)
      assert has_element?(view, "#export-file-#{run.id}-download")

      download = get(conn, "/gtfs/#{version.id}/export-runs/#{run.id}/download")
      assert download.status == 200

      {:ok, entries} = :zip.unzip(download.resp_body, [:memory])
      filenames = Enum.map(entries, fn {name, _content} -> to_string(name) end)

      assert "stops_supplement.txt" in filenames
      assert "vehicles.txt" in filenames
    end

    test "an operations export omits the TODS files for empty tables and reports it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stop_fixture(organization.id, version.id, stop_id: "STOP1")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")

      start_export_and_wait(view)

      assert %Run{state: :ready} = run = latest_operations_run(organization, version)

      view |> element("#export-file-#{run.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#export-file-#{run.id}-warnings-detail",
               "stops_supplement.txt was not included"
             )

      assert has_element?(
               view,
               "#export-file-#{run.id}-warnings-detail",
               "vehicles.txt was not included"
             )

      refute has_element?(view, "#export-garage-clash")
    end

    test "a garage/stop ID conflict is actionable and clears after the ID is corrected", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stop_fixture(organization.id, version.id, stop_id: "STOP1", stop_name: "Main Street")
      garage = garage_fixture(organization.id, garage_id: "STOP1", name: "Main garage")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")

      start_export_and_wait(view)

      assert %Run{state: :failed, failure_code: "garage_stop_id_conflict"} =
               failed =
               latest_operations_run(organization, version)

      assert has_element?(view, "#export-garage-clash")
      assert has_element?(view, "#export-garage-clash-details", "Main garage")
      assert has_element?(view, "#export-garage-clash-details", "Main Street")

      assert attribute_values(render(view), "#export-edit-garages", "href") == [
               "/gtfs/#{version.id}/settings/garages"
             ]

      # The conflict detail belongs to the clash callout only.
      refute has_element?(view, "#export-file-#{failed.id}-warnings")

      assert {:ok, _garage} =
               Operations.update_garage(
                 organization.id,
                 operations_actor(organization.id),
                 garage.id,
                 %{
                   "garage_id" => "garage_main"
                 }
               )

      start_export_and_wait(view, "#export-file-#{failed.id} button[phx-click='retry_file']")

      assert %Run{state: :ready} = run = latest_operations_run(organization, version)
      assert has_element?(view, "#export-file-#{run.id}-download")
      refute has_element?(view, "#export-garage-clash")
    end
  end

  describe "operations export visibility (ProductSurfaces)" do
    defp pathways_org_with_version(roles) do
      organization = organization_fixture(%{product: :pathways})
      member = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: member.id,
        organization_id: organization.id,
        roles: roles
      })

      version = gtfs_version_fixture(organization.id)
      %{organization: organization, member: member, version: version}
    end

    test "a Pathways organization hides the operations option and its note",
         %{conn: conn} do
      %{organization: organization, member: editor, version: version} =
        pathways_org_with_version(["pathways_studio_editor"])

      conn = log_in_user(conn, editor, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      refute has_element?(view, "#export-type-operations")
      refute has_element?(view, "#operations-export-note")
      assert has_element?(view, "#export-type-full[checked]")
    end

    test "a Pathways ?export_type=operations URL falls back to the full export",
         %{conn: conn} do
      %{organization: organization, member: editor, version: version} =
        pathways_org_with_version(["pathways_studio_editor"])

      conn = log_in_user(conn, editor, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")

      assert has_element?(view, "#export-type-full[checked]")
      refute has_element?(view, "#export-type-operations")
      refute has_element?(view, "#operations-export-note")
    end

    test "a Planner organization keeps the operations option and param", %{conn: conn} do
      organization = organization_fixture(%{product: :planner})
      member = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: member.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, member, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      assert has_element?(view, "#export-type-operations")
      refute has_element?(view, "#export-type-operations[checked]")

      {:ok, operations_view, _html} =
        live(conn, "/gtfs/#{version.id}/export?type=operations")

      assert has_element?(operations_view, "#export-type-operations[checked]")
      assert has_element?(operations_view, "#start-export", "Export feed with operations")
    end
  end

  describe "closure export coverage" do
    test "Pathways with closures names the count and Choose Full export restores the closure row",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      pathway_evolution_fixture(organization.id, version.id)
      pathway_evolution_fixture(organization.id, version.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=pathways")

      assert has_element?(view, "#export-type-pathways[checked]")

      assert has_element?(
               view,
               "#export-pathways-closures-omitted",
               "2 scheduled closures are left out."
             )

      assert inventory_count(view, "stops.txt") == "4"
      assert inventory_count(view, "pathways.txt") == "2"
      refute inventory_count(view, "pathway_evolutions.txt")

      assert has_element?(view, "#export-choose-full[type=button]")
      view |> element("#export-choose-full") |> render_click()

      assert_patch(view, "/gtfs/#{version.id}/export?type=full")
      assert has_element?(view, "#export-type-full[checked]")
      refute has_element?(view, "#export-pathways-closures-omitted")
      assert inventory_count(view, "pathway_evolutions.txt") == "2"

      assert has_element?(
               view,
               "#export-inventory",
               "Scheduled closures · extension, not core GTFS"
             )
    end

    test "one closure reads as a singular scheduled closure", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      pathway_evolution_fixture(organization.id, version.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=pathways")

      assert has_element?(
               view,
               "#export-pathways-closures-omitted",
               "1 scheduled closure is left out."
             )
    end

    test "a version without closures shows no Pathways omission", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, pathways_view, _html} = live(conn, "/gtfs/#{version.id}/export?type=pathways")

      refute has_element?(pathways_view, "#export-pathways-closures-omitted")
      refute inventory_count(pathways_view, "pathway_evolutions.txt")

      {:ok, full_view, _html} = live(conn, "/gtfs/#{version.id}/export?type=full")

      refute has_element?(full_view, "#export-pathways-closures-omitted")
      assert inventory_count(full_view, "pathway_evolutions.txt") == "0left out"

      assert has_element?(
               full_view,
               "#export-inventory",
               "Scheduled closures · extension, not core GTFS"
             )
    end

    test "operations keeps its TODS warnings and never reports the Pathways omission", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      pathway_evolution_fixture(organization.id, version.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")

      assert has_element?(view, "#start-export", "Export feed with operations")
      refute has_element?(view, "#export-pathways-closures-omitted")

      render_async(view)

      assert inventory_count(view, "pathway_evolutions.txt") == "1"

      start_export_and_wait(view)

      assert %Run{state: :ready} = run = latest_operations_run(organization, version)

      view |> element("#export-file-#{run.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#export-file-#{run.id}-warnings-detail",
               "stops_supplement.txt was not included"
             )

      assert has_element?(
               view,
               "#export-file-#{run.id}-warnings-detail",
               "vehicles.txt was not included"
             )

      refute has_element?(view, "#export-pathways-closures-omitted")
    end
  end

  describe "missing stop times (spec 23)" do
    test "estimates the missing times with the summary counts and a link to Export defaults",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      seed_estimable_trip(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      render_async(view)

      assert has_element?(view, "#export-missing-times", "2 times on 1 trip")
      assert has_element?(view, "#export-missing-times", "by distance along the path")

      assert has_element?(
               view,
               "#export-missing-times",
               "Every trip with gaps can be estimated."
             )

      assert attribute_values(render(view), "#export-missing-times-link", "href") == [
               "/gtfs/#{version.id}/settings/export-defaults"
             ]

      assert has_element?(view, "#export-missing-times-link", "Change")
    end

    test "leaves the times blank in a warning tone when the defaults say so",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      seed_estimable_trip(organization, version)

      assert {:ok, _} =
               ExportDefaults.update(organization.id, editor_fixture(organization), %{
                 estimate_missing_times: false
               })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      render_async(view)

      assert has_element?(view, "#export-missing-times", "2 times on 1 trip go out blank")

      assert has_element?(view, "#export-missing-times-link", "Change")
    end

    test "says nothing can be estimated when every gapped trip is unfillable",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      seed_unfillable_trip(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      render_async(view)

      assert has_element?(
               view,
               "#export-missing-times",
               "No missing times can be estimated."
             )

      assert has_element?(
               view,
               "#export-missing-times",
               "1 trip can't be estimated and goes out as it is."
             )
    end

    test "a finished run shows its recorded method and names changed defaults",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      seed_estimable_trip(organization, version)

      assert {:ok, run} =
               ExportRuns.create_pending(organization.id, version.id, @actor, :full)

      assert run.estimate_missing_times == true
      assert run.estimate_method == :distance
      ready = mark_export_ready(run)

      # A harmless warning opens the row detail, where the made-with line and the
      # stale-settings line live.
      {:ok, _} =
        ready
        |> Run.system_changeset(%{
          warnings: [%{"code" => "harmless", "detail" => "Nothing to fix."}]
        })
        |> Repo.update()

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      render_async(view)

      view |> element("#export-file-#{ready.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#export-file-#{ready.id}-warnings-detail",
               "missing stop times estimated by distance along the path"
             )

      refute has_element?(view, "#export-file-#{ready.id}-stale-settings")

      assert {:ok, _} =
               ExportDefaults.update(organization.id, editor_fixture(organization), %{
                 estimate_missing_times: false
               })

      {:ok, stale_view, _html} = live(conn, "/gtfs/#{version.id}/export")
      render_async(stale_view)

      stale_view |> element("#export-file-#{ready.id}-warnings") |> render_click()
      _ = :sys.get_state(stale_view.pid)

      assert has_element?(
               stale_view,
               "#export-file-#{ready.id}-warnings-detail",
               "missing stop times estimated by distance along the path"
             )

      assert has_element?(
               stale_view,
               "#export-file-#{ready.id}-stale-settings",
               "Export again to use today's settings"
             )
    end

    test "a run recorded before the setting reads left blank without inventing a method",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      assert {:ok, _} =
               ExportDefaults.update(organization.id, editor_fixture(organization), %{
                 estimate_missing_times: false
               })

      assert {:ok, run} =
               ExportRuns.create_pending(organization.id, version.id, @actor, :full)

      assert run.estimate_missing_times == false
      assert run.estimate_method == nil
      ready = mark_export_ready(run)

      # A harmless warning opens the row detail; the made-with line reads the
      # recorded blank choice.
      {:ok, _} =
        ready
        |> Run.system_changeset(%{
          warnings: [%{"code" => "harmless", "detail" => "Nothing to fix."}]
        })
        |> Repo.update()

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      render_async(view)

      view |> element("#export-file-#{ready.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#export-file-#{ready.id}-warnings-detail",
               "missing stop times left blank"
             )
    end

    test "a Pathways Studio organization sees the line", %{conn: conn} do
      %{organization: organization, member: editor, version: version} =
        pathways_org_with_version(["pathways_studio_editor"])

      conn = log_in_user(conn, editor, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      render_async(view)

      assert has_element?(view, "#export-missing-times")
    end

    test "missing_times_not_estimated warnings render through the warnings list",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      assert {:ok, run} =
               ExportRuns.create_pending(organization.id, version.id, @actor, :full)

      warning = %{
        "code" => "missing_times_not_estimated",
        "detail" => "Trip \"EXP_T1\" was left blank: the last stop has no time.",
        "file" => "stop_times.txt",
        "entity_type" => "trip"
      }

      ready = mark_export_ready(run)

      {:ok, _} =
        ready
        |> Run.system_changeset(%{warnings: [warning]})
        |> Repo.update()

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
      render_async(view)

      view |> element("#export-file-#{ready.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#export-file-#{ready.id}-warnings-detail", "was left blank")

      assert has_element?(
               view,
               "#export-file-#{ready.id}-warnings-detail",
               "missing_times_not_estimated"
             )
    end
  end

  describe "GTFS area navigation" do
    test "mounts the GTFS tabs with Export current above the unchanged page", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/export")

      assert has_element?(view, "#gtfs-sub-nav")
      assert has_element?(view, "#gtfs-tab-export[aria-current='page']")
      assert has_element?(view, "#gtfs-tab-import[href='/gtfs/#{version.id}/import']")
      refute has_element?(view, "#gtfs-tab-import[aria-current='page']")

      assert heading_text(html, "header h1") == "Export"
      assert has_element?(view, "#gtfs-export-form")
      assert has_element?(view, "#export-download-container")
    end
  end

  # A finished file on the run's recorded settings: created through
  # `ExportRuns.create_pending/4` (which snapshots the current defaults
  # per INV-3) and moved to `:ready` with a structurally valid artifact
  # receipt, the same shape the dashboard tests use for ready runs.
  defp mark_export_ready(run) do
    now = DateTime.utc_now()

    {:ok, ready} =
      run
      |> Run.system_changeset(%{
        state: :ready,
        started_at: DateTime.add(now, -60, :second),
        finished_at: now,
        artifact_key: "exports/#{Ecto.UUID.generate()}.zip",
        artifact_filename: "gtfs.zip",
        artifact_sha256: String.duplicate("a", 64),
        artifact_size_bytes: 1024,
        artifact_expires_at: DateTime.add(now, 86_400, :second)
      })
      |> Repo.update()

    ready
  end

  # One trip with a single blank middle row (2 missing cells) over strictly
  # increasing stored distances, so the summary counts are literal: 1 trip,
  # 2 missing times, both estimable.
  defp seed_estimable_trip(organization, version) do
    stop_fixture(organization.id, version.id, %{stop_id: "EXP_S1"})
    stop_fixture(organization.id, version.id, %{stop_id: "EXP_S2"})
    stop_fixture(organization.id, version.id, %{stop_id: "EXP_S3"})
    route_fixture(organization.id, version.id, %{route_id: "EXP_R1", route_short_name: "10"})

    trip_fixture(organization.id, version.id, "EXP_R1", %{
      trip_id: "EXP_T1",
      service_id: "EXP_SV"
    })

    stop_time_fixture(organization.id, version.id, "EXP_T1", "EXP_S1", %{
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00",
      timepoint: 1,
      shape_dist_traveled: Decimal.new("0")
    })

    stop_time_fixture(organization.id, version.id, "EXP_T1", "EXP_S2", %{
      stop_sequence: 2,
      arrival_time: nil,
      departure_time: nil,
      timepoint: nil,
      shape_dist_traveled: Decimal.new("1500")
    })

    stop_time_fixture(organization.id, version.id, "EXP_T1", "EXP_S3", %{
      stop_sequence: 3,
      arrival_time: "08:10:00",
      departure_time: "08:10:00",
      timepoint: 1,
      shape_dist_traveled: Decimal.new("3000")
    })
  end

  # One trip whose first stop has no time, so the export cannot estimate
  # it: the line leads with that instead of counting estimates.
  defp seed_unfillable_trip(organization, version) do
    stop_fixture(organization.id, version.id, %{stop_id: "EXP_U1"})
    stop_fixture(organization.id, version.id, %{stop_id: "EXP_U2"})
    stop_fixture(organization.id, version.id, %{stop_id: "EXP_U3"})
    route_fixture(organization.id, version.id, %{route_id: "EXP_RU", route_short_name: "11"})

    trip_fixture(organization.id, version.id, "EXP_RU", %{
      trip_id: "EXP_TU",
      service_id: "EXP_SVU"
    })

    stop_time_fixture(organization.id, version.id, "EXP_TU", "EXP_U1", %{
      stop_sequence: 1,
      arrival_time: nil,
      departure_time: nil,
      timepoint: nil,
      shape_dist_traveled: Decimal.new("0")
    })

    stop_time_fixture(organization.id, version.id, "EXP_TU", "EXP_U2", %{
      stop_sequence: 2,
      arrival_time: "08:05:00",
      departure_time: "08:05:00",
      timepoint: nil,
      shape_dist_traveled: Decimal.new("1500")
    })

    stop_time_fixture(organization.id, version.id, "EXP_TU", "EXP_U3", %{
      stop_sequence: 3,
      arrival_time: "08:10:00",
      departure_time: "08:10:00",
      timepoint: 1,
      shape_dist_traveled: Decimal.new("3000")
    })
  end

  defp heading_text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp completed_run(organization, version, run_type, attrs) do
    {:ok, run} = Validations.create_validation_run(organization.id, version.id, run_type)

    run
    |> ValidationRun.changeset(Enum.into(attrs, %{status: "completed"}))
    |> Repo.update!()
  end

  # The validator runs in a task owned by a `Validations.Runner`. The stub reports
  # its task pid and holds until `release_validation/1` lets it return, so the test
  # always finds the runner alive.
  defp stub_validator(summary) do
    hold_validator(
      {:ok,
       %Result{
         summary: summary,
         notices: [],
         duration_ms: 1,
         validated_at: DateTime.utc_now()
       }}
    )
  end

  defp hold_validator(outcome) do
    test_pid = self()

    Mox.stub(ValidatorMock, :validate, fn _organization_id, _version_id, _opts ->
      send(test_pid, {:validator_task, self()})

      receive do
        :release -> outcome
      end
    end)
  end

  defp monitor_validation_runner do
    [{_id, runner, _type, _modules}] = DynamicSupervisor.which_children(@validation_supervisor)
    {runner, Process.monitor(runner)}
  end

  # Lets the held validator return, waits for its runner to write the outcome and
  # exit (it broadcasts first), then lets the LiveView drain the message.
  defp release_validation(view) do
    assert_receive {:validator_task, task_pid}, 5_000
    {runner, ref} = monitor_validation_runner()
    send(task_pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 10_000
    _ = :sys.get_state(@validation_supervisor)
    _ = :sys.get_state(view.pid)
    render(view)
  end

  defp refused_validation_runs(organization, version, held_run) do
    organization.id
    |> Validations.list_validation_runs(version.id)
    |> Enum.reject(&(&1.id == held_run.id))
  end

  defp validation_temp_dirs do
    System.tmp_dir!() |> Path.join("gtfs_validation_*") |> Path.wildcard() |> Enum.sort()
  end

  defp zip_copy_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "export-live-validator-#{System.unique_integer([:positive])}.zip"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp latest_full_run(organization, version),
    do: ExportRuns.latest_for_version(organization.id, version.id, :full)

  defp artifact_bytes(%Run{} = run) do
    {:ok, path} =
      ArtifactStorage.verify(%{
        run_id: run.id,
        organization_id: run.organization_id,
        gtfs_version_id: run.gtfs_version_id,
        key: run.artifact_key,
        size: run.artifact_size_bytes,
        sha256: run.artifact_sha256
      })

    File.read!(path)
  end

  # {stop_id, arrival_time} of trip EXP_TD in stop order, from a feed ZIP's bytes.
  defp trip_times(zip_binary) do
    {:ok, entries} = :zip.unzip(zip_binary, [:memory])

    {_name, content} =
      Enum.find(entries, fn {name, _content} -> List.to_string(name) == "stop_times.txt" end)

    [header | lines] = content |> to_string() |> String.split("\n", trim: true)
    columns = String.split(header, ",")

    lines
    |> Enum.map(fn line -> columns |> Enum.zip(String.split(line, ",")) |> Map.new() end)
    |> Enum.filter(&(&1["trip_id"] == "EXP_TD"))
    |> Enum.sort_by(&String.to_integer(&1["stop_sequence"]))
    |> Enum.map(&{&1["stop_id"], &1["arrival_time"]})
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:gtfs_planner, key)
    Application.put_env(:gtfs_planner, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:gtfs_planner, key, old)
        :error -> Application.delete_env(:gtfs_planner, key)
      end
    end)
  end

  defp seed_distance_sensitive_trip(organization, version) do
    for index <- 1..5 do
      stop_fixture(organization.id, version.id, %{stop_id: "EXP_D#{index}"})
    end

    route_fixture(organization.id, version.id, %{route_id: "EXP_RD", route_short_name: "12"})

    trip_fixture(organization.id, version.id, "EXP_RD", %{
      trip_id: "EXP_TD",
      service_id: "EXP_SVD"
    })

    distances = ["0", "200", "400", "2400", "3000"]

    for sequence <- 1..5 do
      time = anchor_time(sequence)

      stop_time_fixture(organization.id, version.id, "EXP_TD", "EXP_D#{sequence}", %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time,
        timepoint: if(time, do: 1),
        shape_dist_traveled: Decimal.new(Enum.at(distances, sequence - 1))
      })
    end
  end

  defp anchor_time(1), do: "08:00:00"
  defp anchor_time(5), do: "08:10:00"
  defp anchor_time(_sequence), do: nil

  defp inventory_count(view, filename) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#export-inventory tbody tr")
    |> Enum.find_value(fn row ->
      file = row |> LazyHTML.query("th") |> LazyHTML.text() |> String.trim()
      count = row |> LazyHTML.query("td") |> LazyHTML.text() |> String.trim()

      if String.starts_with?(file, filename), do: count
    end)
  end

  defp start_export_and_wait(view, button_id \\ "#start-export") do
    existing_runners = runner_pids()
    view |> element(button_id) |> render_click()
    await_new_runners(existing_runners)
    render(view)
  end

  defp latest_operations_run(organization, version),
    do: ExportRuns.latest_for_version(organization.id, version.id, :operations)

  defp tods_inventory_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#export-inventory tbody tr")
    |> Enum.map(fn row ->
      row |> LazyHTML.query("th, td") |> Enum.map(&String.trim(LazyHTML.text(&1)))
    end)
    |> Enum.filter(fn [filename, _count] ->
      filename in ["stops_supplement.txt", "vehicles.txt"]
    end)
  end

  defp attribute_values(html, selector, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)

  defp runner_pids do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(RunnerSupervisor), is_pid(pid), do: pid
  end

  defp await_new_runners(existing_runners) do
    for pid <- runner_pids(), pid not in existing_runners do
      await_runner_down(pid)
    end
  end

  defp await_runner_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @runner_exit_timeout -> force_runner_down(pid, ref)
    end
  end

  defp force_runner_down(pid, ref) do
    task_pid =
      try do
        case :sys.get_state(pid, @runner_exit_timeout) do
          %{task_pid: task_pid} -> task_pid
          _ -> nil
        end
      catch
        :exit, _ -> nil
      end

    task_ref = task_pid && Process.monitor(task_pid)

    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    if task_ref do
      receive do
        {:DOWN, ^task_ref, :process, ^task_pid, _reason} -> :ok
      end
    end
  end
end
