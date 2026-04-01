defmodule GtfsPlannerWeb.Gtfs.StationReachabilityResultLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Validations

  describe "StationReachabilityResultLive" do
    setup do
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
          stop_id: "STATION_REACHABILITY_RESULT",
          stop_name: "Station Reachability Result",
          location_type: 1,
          parent_station: nil
        })

      %{user: user, organization: organization, gtfs_version: gtfs_version, station: station}
    end

    test "renders running spinner state for station reachability runs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "station_reachability")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert html =~ "STARTED"
      assert html =~ "Validation starting..."
    end

    test "renders failed error panel for station reachability runs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "station_reachability")

      {:ok, run} =
        Validations.mark_pathways_failed(run, %{
          reason: :otp_runtime_failed,
          details: %{stage: :runtime_startup},
          issues: [
            %{
              severity: :blocking,
              code: :station_stop_not_found,
              message: "Station stop_id was not found in stops.txt",
              context: %{station_stop_id: "STATION_REACHABILITY_RESULT"}
            }
          ]
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#pathways-failure-title")
      assert has_element?(view, "#pathways-failure-summary")
      assert has_element?(view, "#pathways-failure-status-message")
      assert has_element?(view, "#pathways-failure-blocking-issues")
      assert has_element?(view, "#pathways-failure-checks")
      assert has_element?(view, "#otp-data-requirements-summary")
    end

    test "renders completed metrics and results tables", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      station: station
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: station.stop_id,
          address: "123 Station Plaza",
          description: "Street entrance to platform"
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "station_reachability")

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

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#pathways-trip-visualization-overview")
      assert has_element?(view, "#pathways-trip-overview-total-tests-value", "1")
      assert has_element?(view, "#pathways-trip-overview-fail-count-value", "1")
      assert has_element?(view, "#pathways-criteria-comparison-overview")
      assert has_element?(view, "#pathways-case-results")
      assert has_element?(view, "#pathways-case-row-0")
      assert has_element?(view, "#pathways-case-id-0", walkability_test.id)
      assert has_element?(view, "#pathways-case-description-0", "Street entrance to platform")
      assert has_element?(view, "#pathways-case-criteria-details-0")
      assert has_element?(view, "#pathways-case-itinerary-details-0")
    end

    test "redirects non-station runs to shared validation result page", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:live_redirect, %{to: to_path}}} =
               live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert to_path == "/gtfs/#{version.id}/validation/#{run.id}"
    end
  end
end
