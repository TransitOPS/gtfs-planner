defmodule GtfsPlannerWeb.Gtfs.StationReachabilityLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  defmodule StationReachabilityRunnerMock do
    def run(validation_run, _organization_id, _gtfs_version_id, _opts) do
      listener = Application.get_env(:gtfs_planner, :station_reachability_test_listener)

      if is_pid(listener) do
        send(listener, {:station_reachability_runner_started, validation_run.id})
      end

      {:ok, validation_run}
    end
  end

  describe "StationReachabilityLive" do
    setup do
      previous_runner_module =
        Application.get_env(:gtfs_planner, :pathways_trip_test_runner_module)

      previous_listener =
        Application.get_env(:gtfs_planner, :station_reachability_test_listener)

      Application.put_env(
        :gtfs_planner,
        :pathways_trip_test_runner_module,
        StationReachabilityRunnerMock
      )

      Application.put_env(:gtfs_planner, :station_reachability_test_listener, self())

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
            :station_reachability_test_listener,
            previous_listener
          )
        else
          Application.delete_env(:gtfs_planner, :station_reachability_test_listener)
        end
      end)

      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_REACHABILITY",
          stop_name: "Station Reachability",
          location_type: 1,
          parent_station: nil
        })

      %{user: user, organization: organization, gtfs_version: gtfs_version, station: station}
    end

    test "renders reachability run action and active tab", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert has_element?(view, "#station-sub-nav")

      assert has_element?(
               view,
               "#station-sub-nav a[aria-current='page']",
               "Reachability"
             )

      assert has_element?(
               view,
               "#run-station-reachability[phx-click='run_reachability']:not([disabled])",
               "Run Reachability Tests"
             )

      html = render(view)

      details_href = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}"
      diagram_href = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"
      report_href = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report"
      reachability_href = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability"

      assert has_element?(view, "#station-sub-nav a[href='#{details_href}']", "Details")
      assert has_element?(view, "#station-sub-nav a[href='#{diagram_href}']", "Diagram")
      assert has_element?(view, "#station-sub-nav a[href='#{report_href}']", "Report")

      assert has_element?(
               view,
               "#station-sub-nav a[href='#{reachability_href}']",
               "Reachability"
             )

      details_pos = :binary.match(html, details_href) |> elem(0)
      diagram_pos = :binary.match(html, diagram_href) |> elem(0)
      report_pos = :binary.match(html, report_href) |> elem(0)
      reachability_pos = :binary.match(html, reachability_href) |> elem(0)

      assert details_pos < diagram_pos
      assert diagram_pos < report_pos
      assert report_pos < reachability_pos
    end

    test "handles gtfs_version_loaded event by navigating to selected version", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, version2} = GtfsPlanner.Versions.create_gtfs_version(organization.id, %{name: "V2"})

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      render_hook(view, "gtfs_version_loaded", %{"version_id" => to_string(version2.id)})

      assert_redirect(view, "/gtfs/#{version2.id}/stops/#{station.stop_id}/reachability")
    end

    test "redirects with flash when station is missing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:live_redirect, %{to: to_path, flash: %{"error" => "Station not found"}}}} =
               live(conn, "/gtfs/#{gtfs_version.id}/stops/UNKNOWN/reachability")

      assert to_path == "/gtfs/#{gtfs_version.id}/stops"
    end

    test "shows station-scoped recent runs newest-first with stable row ids", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      other_station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_STATION_REACHABILITY",
          stop_name: "Other Station Reachability",
          location_type: 1,
          parent_station: nil
        })

      {:ok, older_run} =
        Validations.create_station_reachability_run(
          organization.id,
          gtfs_version.id,
          station.stop_id
        )

      {:ok, other_station_run} =
        Validations.create_station_reachability_run(
          organization.id,
          gtfs_version.id,
          other_station.stop_id
        )

      {:ok, newer_run} =
        Validations.create_station_reachability_run(
          organization.id,
          gtfs_version.id,
          station.stop_id
        )

      assert {:ok, _} =
               Validations.mark_pathways_failed(older_run, %{reason: :pathways_trip_test_failed})

      assert {:ok, _} =
               Validations.mark_pathways_failed(newer_run, %{reason: :pathways_trip_test_failed})

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert has_element?(view, "#recent-station-runs")
      assert has_element?(view, "#recent-station-run-#{older_run.id}")
      assert has_element?(view, "#recent-station-run-#{newer_run.id}")

      assert has_element?(
               view,
               "#recent-station-run-#{newer_run.id} a[href='/gtfs/#{gtfs_version.id}/station-reachability/#{newer_run.id}?stop_id=#{station.stop_id}']"
             )

      refute has_element?(
               view,
               "#recent-station-run-#{other_station_run.id}"
             )

      html = render(view)
      older_pos = :binary.match(html, "recent-station-run-#{older_run.id}") |> elem(0)
      newer_pos = :binary.match(html, "recent-station-run-#{newer_run.id}") |> elem(0)

      assert newer_pos < older_pos
    end

    test "run start wiring creates station run and enters polling state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      assert_receive {:station_reachability_runner_started, run_id}

      run = Repo.get!(ValidationRun, run_id)
      assert run.run_type == "station_reachability"
      assert run.status == "running"

      assert has_element?(view, "#station-reachability-progress .loading-spinner")
      assert has_element?(view, "#station-reachability-progress", "Running pathways trip test...")
      assert has_element?(view, "#run-station-reachability[disabled]")
      assert has_element?(view, "#station-reachability-run-state", "Run in progress")
      assert has_element?(view, "#station-reachability-run-state", "Last checked")
    end

    test "mount resumes active station reachability run from backend state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      {:ok, pending_run} =
        Validations.create_station_reachability_run(
          organization.id,
          gtfs_version.id,
          station.stop_id
        )

      {:ok, active_run} = Validations.mark_running(pending_run)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert has_element?(view, "#station-reachability-progress")
      assert has_element?(view, "#station-reachability-progress", "Running pathways trip test...")
      assert has_element?(view, "#station-reachability-run-state", active_run.id)
      assert has_element?(view, "#run-station-reachability[disabled]")
    end

    test "mount ignores stale active run and leaves run action enabled", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      {:ok, pending_run} =
        Validations.create_station_reachability_run(
          organization.id,
          gtfs_version.id,
          station.stop_id
        )

      {:ok, stale_run} = Validations.mark_running(pending_run)

      stale_started_at = DateTime.add(DateTime.utc_now(), -1_800, :second)

      {:ok, stale_run} =
        stale_run
        |> ValidationRun.changeset(%{started_at: stale_started_at})
        |> Repo.update()

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      refute has_element?(view, "#station-reachability-progress")

      assert has_element?(
               view,
               "#run-station-reachability[phx-click='run_reachability']:not([disabled])"
             )

      stale_run = Repo.get!(ValidationRun, stale_run.id)
      assert stale_run.status == "failed"
    end

    test "run click reuses active backend run and does not create duplicate", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      {:ok, pending_run} =
        Validations.create_station_reachability_run(
          organization.id,
          gtfs_version.id,
          station.stop_id
        )

      {:ok, active_run} = Validations.mark_running(pending_run)

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      refute_receive {:station_reachability_runner_started, _run_id}, 100

      assert has_element?(view, "#station-reachability-progress")
      assert has_element?(view, "#station-reachability-run-state", active_run.id)

      station_runs =
        Validations.list_validation_runs(organization.id, gtfs_version.id)
        |> Enum.filter(fn run ->
          run.run_type == "station_reachability" and
            get_in(run.result_json || %{}, ["metadata", "station_stop_id"]) == station.stop_id
        end)

      assert length(station_runs) == 1
    end

    test "run click replaces stale backend run with a new run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      {:ok, pending_run} =
        Validations.create_station_reachability_run(
          organization.id,
          gtfs_version.id,
          station.stop_id
        )

      {:ok, stale_run} = Validations.mark_running(pending_run)

      stale_started_at = DateTime.add(DateTime.utc_now(), -1_800, :second)

      {:ok, stale_run} =
        stale_run
        |> ValidationRun.changeset(%{started_at: stale_started_at})
        |> Repo.update()

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      assert_receive {:station_reachability_runner_started, new_run_id}
      refute new_run_id == stale_run.id

      stale_run = Repo.get!(ValidationRun, stale_run.id)
      assert stale_run.status == "failed"

      new_run = Repo.get!(ValidationRun, new_run_id)
      assert new_run.status == "running"
      assert new_run.run_type == "station_reachability"
    end

    test "polling keeps spinner active for pending status", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      assert_receive {:station_reachability_runner_started, run_id}

      run = Repo.get!(ValidationRun, run_id)

      assert {:ok, _pending_run} =
               run
               |> ValidationRun.changeset(%{status: "pending"})
               |> Repo.update()

      send(view.pid, {:poll_pathways_trip_test_status, run.id})
      _ = render(view)

      assert has_element?(view, "#station-reachability-progress")
      assert has_element?(view, "#station-reachability-progress", "Checking existing export...")
      assert has_element?(view, "#run-station-reachability[disabled]")
    end

    test "polling does not override detailed prep phase with generic running label", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      assert_receive {:station_reachability_runner_started, run_id}

      send(view.pid, {:pathways_prep_progress, %{scope: :graph, phase: :building}})
      _ = render(view)

      assert has_element?(view, "#station-reachability-progress", "Building OTP graph...")

      run = Repo.get!(ValidationRun, run_id)

      assert {:ok, _running_run} =
               run
               |> ValidationRun.changeset(%{status: "running"})
               |> Repo.update()

      send(view.pid, {:poll_pathways_trip_test_status, run.id})
      _ = render(view)

      assert has_element?(view, "#station-reachability-progress", "Building OTP graph...")
      refute has_element?(view, "#station-reachability-progress", "Running pathways trip test...")
    end

    test "polling replaces terminal detailed phase with running phase", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      assert_receive {:station_reachability_runner_started, run_id}

      send(view.pid, {:pathways_prep_progress, %{scope: :gtfs, phase: :done}})
      _ = render(view)

      assert has_element?(
               view,
               "#station-reachability-progress",
               "GTFS export preparation complete"
             )

      send(view.pid, {:poll_pathways_trip_test_status, run_id})
      _ = render(view)

      assert has_element?(view, "#station-reachability-progress", "Running pathways trip test...")

      refute has_element?(
               view,
               "#station-reachability-progress",
               "GTFS export preparation complete"
             )
    end

    test "polling tolerates unexpected status values without crashing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      assert_receive {:station_reachability_runner_started, run_id}

      from(vr in ValidationRun, where: vr.id == ^run_id)
      |> Repo.update_all(set: [status: "queued"])

      send(view.pid, {:poll_pathways_trip_test_status, run_id})
      _ = render(view)

      assert has_element?(view, "#station-reachability-progress")
      assert has_element?(view, "#run-station-reachability[disabled]")
    end

    test "polling renders blocking failure panel for failed runs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      assert_receive {:station_reachability_runner_started, run_id}

      run = Repo.get!(ValidationRun, run_id)

      reason = %{
        reason: :otp_runtime_failed,
        details: %{stage: :materialization},
        issues: [
          %{
            severity: :blocking,
            code: :station_stop_not_found,
            message: "Station stop_id was not found in stops.txt",
            context: %{station_stop_id: station.stop_id}
          }
        ]
      }

      assert {:ok, _failed_run} = Validations.mark_pathways_failed(run, reason)

      send(view.pid, {:poll_pathways_trip_test_status, run.id})
      _ = render(view)

      assert has_element?(view, "#station-reachability-error-panel")
      assert has_element?(view, "#station-reachability-error-panel", "Blocking issues")

      assert has_element?(
               view,
               "#station-reachability-error-panel",
               "Station stop_id was not found in stops.txt"
             )

      assert has_element?(view, "#station-pathways-failure-checks")
      assert has_element?(view, "#station-pathways-failure-diagnostics")
      assert has_element?(view, "#station-otp-data-requirements-summary")
    end

    test "polling renders simplified validation summary and case results table", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.stop_id,
          address: "123 Station Plaza"
        })

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      assert_receive {:station_reachability_runner_started, run_id}

      run = Repo.get!(ValidationRun, run_id)

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 0, failed: 1, query_failure: 1, scoring_failure: 0},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :failed,
            failure_category: :query_failure,
            details: %{reason: :no_route}
          }
        ]
      }

      assert {:ok, _completed_run} = Validations.mark_pathways_completed(run, run_result, 20)

      send(view.pid, {:poll_pathways_trip_test_status, run.id})
      _ = render(view)

      assert has_element?(view, "#station-reachability-summary")
      assert has_element?(view, "#station-trip-overview")
      assert has_element?(view, "#station-trip-overview", "Test cases")
      assert has_element?(view, "#station-trip-overview", "1")
      assert has_element?(view, "#station-trip-overview", "Passed")
      assert has_element?(view, "#station-trip-overview", "0")
      assert has_element?(view, "#station-trip-overview", "Warnings")
      assert has_element?(view, "#station-trip-overview", "Failed")
      assert has_element?(view, "#station-pathways-case-results")
      assert has_element?(view, "#station-pathways-case-row-0")

      refute has_element?(view, "#reachability-summary-total")
      refute has_element?(view, "#reachability-summary-pass-rate")
      refute has_element?(view, "#station-reachability-top-failures")
    end

    test "polling renders case rows for selected test cases only", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      valid_test_case =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.stop_id,
          address: "1 Valid Station Plaza"
        })

      invalid_test_case =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.stop_id,
          address: "2 Invalid Station Plaza"
        })

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert view
             |> element("#run-station-reachability")
             |> render_click()

      assert_receive {:station_reachability_runner_started, run_id}

      run = Repo.get!(ValidationRun, run_id)

      run_result = %{
        suite_meta: %{total_candidates: 2, selected_count: 1, malformed_count: 1},
        selected_test_case_ids: [valid_test_case.id],
        selection: %{
          total_candidates: 2,
          in_scope_candidates: 2,
          selected_count: 1,
          invalid_count: 1,
          selected_test_case_ids: [valid_test_case.id],
          invalid_test_case_ids: [invalid_test_case.id],
          invalid_cases: [
            %{
              walkability_test_id: invalid_test_case.id,
              reason_code: :invalid_coordinate_range,
              stop_id: station.stop_id,
              address: invalid_test_case.address
            }
          ]
        },
        summary: %{total: 1, passed: 1, failed: 0, query_failure: 0, scoring_failure: 0},
        cases: [
          %{
            test_case_id: valid_test_case.id,
            status: :passed,
            route_output: %{route_exists: true}
          }
        ]
      }

      assert {:ok, _completed_run} = Validations.mark_pathways_completed(run, run_result, 10)

      send(view.pid, {:poll_pathways_trip_test_status, run.id})
      _ = render(view)

      assert has_element?(view, "#station-pathways-case-row-0")
      refute has_element?(view, "#station-pathways-case-row-1")

      refute has_element?(view, "#station-reachability-coverage")
      refute has_element?(view, "#station-reachability-invalid-cases")
    end

    test "renders parent-station reachability test cases table scoped to station", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      level = level_fixture(organization.id, gtfs_version.id)

      station_child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_CHILD_STOP",
          stop_name: "Station Child Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      other_station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_STATION",
          stop_name: "Other Station",
          location_type: 1,
          parent_station: nil
        })

      other_station_child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_STATION_CHILD_STOP",
          stop_name: "Other Station Child Stop",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: level.level_id
        })

      station_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station_child_stop.stop_id,
          address: "1 Station Plaza"
        })

      other_station_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: other_station_child_stop.stop_id,
          address: "9 Other Station Plaza"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert has_element?(view, "#station-reachability-test-cases")
      assert has_element?(view, "#station-walkability-tests-table")
      assert has_element?(view, "#station-walkability-test-row-#{station_test.id}")

      refute has_element?(view, "#station-walkability-test-row-#{other_station_test.id}")
    end

    test "edits and deletes test cases from reachability table", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      level = level_fixture(organization.id, gtfs_version.id)

      station_child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_EDITABLE_CHILD_STOP",
          stop_name: "Station Editable Child Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      test_case =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station_child_stop.stop_id,
          address: "2 Station Plaza",
          description: "Original description",
          expected_traversable: true,
          expected_wheelchair_accessible: false
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/reachability")

      assert view
             |> element("#station-walkability-test-stop-#{test_case.id}")
             |> render_click()

      assert has_element?(view, "#walkability-test-form")

      render_change(view, "walkability_form_change", %{
        "walkability" => %{
          "description" => "Updated description"
        }
      })

      assert view
             |> form("#walkability-test-form")
             |> render_submit()

      updated_test_case = Validations.get_walkability_test!(test_case.id)
      assert updated_test_case.description == "Updated description"

      assert view
             |> element("#station-walkability-test-stop-#{test_case.id}")
             |> render_click()

      assert view
             |> element("#walkability-test-delete-in-form")
             |> render_click()

      assert Validations.get_walkability_test(test_case.id) == nil
      refute has_element?(view, "#station-walkability-test-row-#{test_case.id}")
    end
  end
end
