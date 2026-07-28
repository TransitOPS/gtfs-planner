defmodule GtfsPlannerWeb.Gtfs.StationReachabilityResultLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

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

      assert html =~ "Reachability analysis is running"
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

    test "keeps the station tabs available on the results page", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      station: station
    } do
      run = completed_run(organization, version, station, diagnostics: [])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#station-sub-nav")

      assert has_element?(
               view,
               ~s(#station-sub-nav a[aria-current="page"][href$="/reachability"])
             )

      assert has_element?(
               view,
               ~s(#station-sub-nav a[href="/gtfs/#{version.id}/stops/#{station.stop_id}"])
             )
    end

    test "shows every diagnostic without a toggle when the list is short", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      station: station
    } do
      run = completed_run(organization, version, station, diagnostics: diagnostics(3))

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#graph-diagnostics-summary", "3 warnings")
      refute has_element?(view, "#graph-diagnostics-toggle")
      assert has_element?(view, "#graph-diagnostics-list", "Node 3 is not connected")
    end

    test "collapses a long diagnostics list to a summary and expands on request", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      station: station
    } do
      run = completed_run(organization, version, station, diagnostics: diagnostics(8))

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#graph-diagnostics-summary", "8 warnings")
      assert has_element?(view, "#graph-diagnostics-list", "Node 5 is not connected")
      refute has_element?(view, "#graph-diagnostics-list", "Node 6 is not connected")

      assert has_element?(
               view,
               ~s(#graph-diagnostics-toggle[aria-expanded="false"]),
               "Show all 8"
             )

      view |> element("#graph-diagnostics-toggle") |> render_click()

      assert has_element?(view, "#graph-diagnostics-list", "Node 8 is not connected")

      assert has_element?(
               view,
               ~s(#graph-diagnostics-toggle[aria-expanded="true"]),
               "Show first 5"
             )

      view |> element("#graph-diagnostics-toggle") |> render_click()

      refute has_element?(view, "#graph-diagnostics-list", "Node 6 is not connected")
    end
  end

  defp diagnostics(count) do
    for index <- 1..count do
      %{
        "severity" => "warning",
        "code" => "unreachable_node",
        "entity_type" => "stop",
        "entity_id" => "NODE_#{index}",
        "message" => "Node #{index} is not connected to any pathway."
      }
    end
  end

  defp completed_run(organization, version, station, opts) do
    envelope = %{
      "engine" => "pathways_router",
      "result_schema_version" => 1,
      "metadata" => %{"station_stop_id" => station.stop_id},
      "outcome" => "reachable",
      "station" => %{"stop_id" => station.stop_id, "stop_name" => station.stop_name},
      "topology" => %{
        "entrance_count" => 1,
        "platform_count" => 1,
        "pathway_count" => 1,
        "level_count" => 1
      },
      "totals" => %{"pair_count" => 0, "reachable" => 0},
      "diagnostics" => Keyword.fetch!(opts, :diagnostics),
      "pairs" => [],
      "duration_ms" => 12
    }

    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "station_reachability")

    run
    |> ValidationRun.changeset(%{
      status: "completed",
      engine: "pathways_router",
      result_json: envelope,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end
end
