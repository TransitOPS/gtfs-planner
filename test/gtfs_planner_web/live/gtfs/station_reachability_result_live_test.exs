defmodule GtfsPlannerWeb.Gtfs.StationReachabilityResultLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Reachability.Runner
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

    test "denies a run from another version in the same organization", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      other_version = gtfs_version_fixture(organization.id)

      {:ok, run} =
        Validations.create_validation_run(
          organization.id,
          other_version.id,
          "station_reachability"
        )

      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:live_redirect, %{to: to_path, flash: flash}}} =
               live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert to_path == "/gtfs/#{version.id}/export"
      assert flash["error"] == "Unauthorized access to validation run"
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

  describe "grouped pair results" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)
      run = planned_run(organization, version)

      %{user: user, organization: organization, gtfs_version: version, run: run}
    end

    test "groups pairs into entry, egress, and transfer sections", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      run: run
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#reachability-section-entry", "Street to platform")
      assert has_element?(view, "#reachability-section-egress", "Platform to street")
      assert has_element?(view, "#reachability-section-transfer", "Platform to platform")
    end

    test "counts walking and step-free reachability separately per section", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      run: run
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      # Both platforms are behind the one stairway, so every entry walks and
      # none is step-free. The disconnected platform fails in both modes.
      assert has_element?(view, "#reachability-section-entry-stats", "2/3 on foot")
      assert has_element?(view, "#reachability-section-entry-stats", "0/3 step-free")
    end

    test "explains a pair that walks but has no step-free route", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      run: run
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      view |> element("#pair-ENT_A-PLAT_1") |> render_click()

      assert has_element?(
               view,
               "#trip-ENT_A-PLAT_1",
               "every connecting route uses stairs or an escalator"
             )
    end

    test "explains a pair with no pathway route in either mode", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      run: run
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      view |> element("#pair-ENT_A-PLAT_3") |> render_click()

      assert has_element?(
               view,
               "#trip-ENT_A-PLAT_3",
               "No pathway route connects these two elements"
             )
    end

    test "loads trip steps only once the row is expanded", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      run: run
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      refute has_element?(view, "#trip-ENT_A-PLAT_1")
      assert has_element?(view, ~s(#pair-ENT_A-PLAT_1[aria-expanded="false"]))

      view |> element("#pair-ENT_A-PLAT_1") |> render_click()

      assert has_element?(view, ~s(#pair-ENT_A-PLAT_1[aria-expanded="true"]))
      assert has_element?(view, "#trip-ENT_A-PLAT_1", "On foot")
      assert has_element?(view, "#trip-ENT_A-PLAT_1", "Depart")
    end

    test "collapses an expanded trip on a second click", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      run: run
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      view |> element("#pair-ENT_A-PLAT_1") |> render_click()
      assert has_element?(view, "#trip-ENT_A-PLAT_1")

      view |> element("#pair-ENT_A-PLAT_1") |> render_click()
      refute has_element?(view, "#trip-ENT_A-PLAT_1")
    end

    test "explains that the page simulates a trip planner", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      run: run
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#reachability-engine-note", "OpenTripPlanner")
    end
  end

  # A station where the only way in is a stairway and one platform is stranded:
  # it produces a walking success, an accessibility gap, and a missing pathway.
  defp planned_run(organization, version) do
    station =
      stop_fixture(organization.id, version.id, %{
        stop_id: "STATION_PLANNED",
        stop_name: "Planned Station",
        location_type: 1,
        parent_station: nil
      })

    level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})

    for {stop_id, name, location_type} <- [
          {"ENT_A", "Entrance A", 2},
          {"PLAT_1", "Platform 1", 0},
          {"PLAT_2", "Platform 2", 0},
          {"PLAT_3", "Platform 3", 0}
        ] do
      stop_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        location_type: location_type,
        parent_station: station.stop_id,
        level_id: "L1"
      })
    end

    pathway_fixture(organization.id, version.id, "ENT_A", "PLAT_1", %{
      pathway_id: "PW_STAIRS",
      pathway_mode: 2,
      is_bidirectional: true,
      traversal_time: 45
    })

    pathway_fixture(organization.id, version.id, "PLAT_1", "PLAT_2", %{
      pathway_id: "PW_LIFT",
      pathway_mode: 5,
      is_bidirectional: true,
      traversal_time: 30
    })

    snapshot = %{
      station: station,
      child_stops: Gtfs.list_child_stops_for_parent(organization.id, version.id, station.id),
      pathways: Gtfs.list_pathways_for_station(organization.id, version.id, station.id),
      levels: Gtfs.list_levels_for_station(organization.id, version.id, station.id)
    }

    {:ok, envelope} = Runner.run(snapshot, DateTime.utc_now())

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
