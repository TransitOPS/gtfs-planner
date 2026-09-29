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
  alias GtfsPlanner.Validations.WalkabilityTest
  alias GtfsPlanner.Validations.WalkabilityTestRunResult

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
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#reachability-running[aria-labelledby]", "Checking this station")
      assert has_element?(view, "#reachability-running [role=progressbar]")
    end

    test "renders an interrupted run as failed with a plain explanation", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "station_reachability")

      run
      |> ValidationRun.changeset(%{
        status: "failed",
        error_details: "The run was interrupted before it finished.",
        completed_at: DateTime.utc_now()
      })
      |> Repo.update!()

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#reachability-failed", "The check stopped before it finished.")

      assert has_element?(
               view,
               "#reachability-failed details",
               "The run was interrupted before it finished."
             )
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

      assert has_element?(view, "#graph-diagnostics-summary", "3 suggestions")
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

      assert has_element?(view, "#graph-diagnostics-summary", "8 suggestions")
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
      assert has_element?(view, "#reachability-section-entry-stats", "2 of 3 on foot")
      assert has_element?(view, "#reachability-section-entry-stats", "0 of 3 step-free")
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
               "every route uses stairs or an escalator"
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
               "No route connects Entrance A and Platform 3 in either direction of travel."
             )

      refute has_element?(view, "#trip-ENT_A-PLAT_3", "Riders can travel the other way")
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
      assert has_element?(view, "#trip-ENT_A-PLAT_1", "Start")
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

  describe "one-way pathway failures" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: version}
    end

    test "says riders can travel the other way when the reverse pair is reachable", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run = one_way_run(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#walk-PLAT_1-ENT_A", "Works")
      view |> element("#pair-ENT_A-PLAT_1") |> render_click()

      assert has_element?(
               view,
               "#trip-ENT_A-PLAT_1",
               "Riders can travel the other way, from Platform 1 to Entrance A, but not in this direction."
             )

      assert has_element?(view, "#trip-ENT_A-PLAT_1", "is_bidirectional = 0")
      refute has_element?(view, "#trip-ENT_A-PLAT_1", "in either direction")
    end

    test "drops the either-direction claim when the reverse pair is not in the results", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "STATION_TRUNCATED",
          stop_name: "Truncated Station",
          location_type: 1,
          parent_station: nil
        })

      unreachable_walk = %{
        "index" => 0,
        "kind" => "entry",
        "mode" => "walking",
        "from_stop_id" => "ENT_A",
        "from_stop_name" => "Entrance A",
        "to_stop_id" => "PLAT_1",
        "to_stop_name" => "Platform 1",
        "outcome" => "unreachable",
        "reason" => nil
      }

      run =
        completed_run(organization, version, station, diagnostics: [], pairs: [unreachable_walk])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      view |> element("#pair-ENT_A-PLAT_1") |> render_click()

      assert has_element?(
               view,
               "#trip-ENT_A-PLAT_1",
               "No route leads from Entrance A to Platform 1."
             )

      refute has_element?(view, "#trip-ENT_A-PLAT_1", "in either direction")
      refute has_element?(view, "#trip-ENT_A-PLAT_1", "Riders can travel the other way")
    end
  end

  # Mirrors the run test/support/browser_seed.exs stores for reachability_results.spec.js:
  # one entrance, two platforms, and one elevator between the entrance and the first
  # platform. The spec asserts the same ids and counts.
  describe "completed router run for the seeded station shape" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "BROWSER_STATION",
          stop_name: "Browser Test Station",
          location_type: 1,
          parent_station: nil
        })

      level_fixture(organization.id, version.id, %{level_id: "BROWSER_L1", level_index: 0.0})

      for {stop_id, name, location_type} <- [
            {"BROWSER_STOP_A", "Platform A North", 0},
            {"BROWSER_STOP_B", "Platform B South", 0},
            {"BROWSER_STOP_C", "Entrance C", 2}
          ] do
        stop_fixture(organization.id, version.id, %{
          stop_id: stop_id,
          stop_name: name,
          location_type: location_type,
          parent_station: station.stop_id,
          level_id: "BROWSER_L1"
        })
      end

      pathway_fixture(organization.id, version.id, "BROWSER_STOP_C", "BROWSER_STOP_A", %{
        pathway_id: "BROWSER_PW_ELEVATOR",
        pathway_mode: 5,
        is_bidirectional: true,
        traversal_time: 45,
        length: Decimal.new("12.5")
      })

      run = run_battery(organization, version, station)

      %{user: user, organization: organization, gtfs_version: version, run: run}
    end

    test "shows the entry section and a row for the reachable entrance-to-platform pair", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      run: run
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#station-reachability-results")
      assert has_element?(view, "#reachability-section-entry")
      assert has_element?(view, "#pair-BROWSER_STOP_C-BROWSER_STOP_A")
      refute has_element?(view, "#reachability-no-pairs")
    end

    test "summarizes the entry section and the whole run with real counts", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      run: run
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(
               view,
               "#reachability-section-entry-stats",
               "1 of 2 on foot · 1 of 2 step-free"
             )

      assert has_element?(view, "#reachability-verdict-on-foot", "2 of 6")
      assert has_element?(view, "#reachability-verdict-step-free", "2 of 6")
    end
  end

  describe "verdict" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "STATION_VERDICT",
          stop_name: "Verdict Station",
          location_type: 1,
          parent_station: nil
        })

      %{user: user, organization: organization, gtfs_version: version, station: station}
    end

    test "says every walk works when the run passed", ctx do
      pairs = pair_entries("entry", "ENT_A", "PLAT_1", {works(), works()}, 0)

      {:ok, view, _html} =
        open_results(ctx, outcome: "passed", pairs: pairs, diagnostics: [])

      assert has_element?(
               view,
               ~s(#reachability-verdict[data-outcome="passed"]),
               "Every walk works, including step-free."
             )

      assert has_element?(view, "#reachability-verdict-on-foot", "1 of 1")
      assert has_element?(view, "#reachability-verdict-step-free", "1 of 1")
      assert has_element?(view, "#reachability-verdict-station-data", "No problems found")
    end

    test "names the step-free gap when only step-free fails", ctx do
      pairs = pair_entries("entry", "ENT_A", "PLAT_1", {works(), no_route()}, 0)

      {:ok, view, _html} =
        open_results(ctx, outcome: "warning", pairs: pairs, diagnostics: [])

      assert has_element?(
               view,
               ~s(#reachability-verdict[data-outcome="warning"]),
               "Riders can walk everywhere, but 1 walk has no step-free route."
             )

      assert has_element?(view, "#reachability-verdict-on-foot", "1 of 1")
      assert has_element?(view, "#reachability-verdict-step-free", "0 of 1")
    end

    test "counts each kind of failing walk when the run failed", ctx do
      {:ok, view, _html} = open_results(ctx, mixed_failures())

      assert has_element?(
               view,
               ~s(#reachability-verdict[data-outcome="failed"]),
               "3 of 3 walks need fixing: 1 couldn't be checked, 1 has no route and 1 has no step-free route."
             )
    end

    test "shows a walk that fails on foot with its step-free result muted", ctx do
      {:ok, view, _html} = open_results(ctx, mixed_failures())

      assert has_element?(
               view,
               ~s(#walk-ENT_A-PLAT_1 [data-mode="walking"][data-tone="error"]),
               "No route"
             )

      assert has_element?(
               view,
               ~s(#walk-ENT_A-PLAT_1 [data-mode="wheelchair"][data-tone="muted"]),
               "No route"
             )
    end

    test "shows a walk that works on foot but not step-free as a gap", ctx do
      {:ok, view, _html} = open_results(ctx, mixed_failures())

      assert has_element?(
               view,
               ~s(#walk-ENT_A-PLAT_2 [data-mode="walking"][data-tone="success"]),
               "Works"
             )

      assert has_element?(
               view,
               ~s(#walk-ENT_A-PLAT_2 [data-mode="wheelchair"][data-tone="warning"]),
               "No step-free route"
             )
    end

    test "shows a walk the router could not plan as an error, not a gap", ctx do
      {:ok, view, _html} = open_results(ctx, mixed_failures())

      assert has_element?(
               view,
               ~s(#walk-PLAT_1-ENT_A [data-mode="walking"][data-tone="error"]),
               "Couldn't check"
             )

      assert has_element?(
               view,
               ~s(#walk-PLAT_1-ENT_A [data-mode="wheelchair"][data-tone="muted"]),
               "Couldn't check"
             )
    end

    test "names the place the router could not find when a walk opens", ctx do
      {:ok, view, _html} = open_results(ctx, mixed_failures())

      view |> element("#pair-PLAT_1-ENT_A") |> render_click()

      assert has_element?(
               view,
               "#trip-PLAT_1-ENT_A",
               "Name of PLAT_1 isn't part of the check because it has no location."
             )
    end

    defp open_results(%{conn: conn} = ctx, opts) do
      run =
        completed_run(ctx.organization, ctx.gtfs_version, ctx.station, opts)

      conn = log_in_user(conn, ctx.user, organization: ctx.organization)
      live(conn, "/gtfs/#{ctx.gtfs_version.id}/station-reachability/#{run.id}")
    end

    # One walk with no route on foot, one that only lacks a step-free route, and
    # one whose origin is missing from the routing graph.
    defp mixed_failures do
      invalid = {"invalid", "unknown_element: PLAT_1"}

      pairs =
        pair_entries("entry", "ENT_A", "PLAT_1", {no_route(), no_route()}, 0) ++
          pair_entries("entry", "ENT_A", "PLAT_2", {works(), no_route()}, 2) ++
          pair_entries("egress", "PLAT_1", "ENT_A", {invalid, invalid}, 4)

      [outcome: "failed", pairs: pairs, diagnostics: []]
    end
  end

  describe "other states" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "STATION_STATES",
          stop_name: "States Station",
          location_type: 1,
          parent_station: nil
        })

      %{user: user, organization: organization, gtfs_version: version, station: station}
    end

    test "says nothing was tested and links to floorplans when the run had no walks", ctx do
      %{conn: conn, user: user, organization: organization} = ctx
      version = ctx.gtfs_version
      run = completed_run(organization, version, ctx.station, diagnostics: [])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#reachability-no-pairs", "This check didn't test any walks.")

      assert has_element?(
               view,
               ~s(#reachability-no-pairs a[href="/gtfs/#{version.id}/stops/STATION_STATES/diagram"])
             )

      refute has_element?(view, "#reachability-verdict")
    end

    test "words a known router code in plain language and keeps the code's problem count", ctx do
      %{conn: conn, user: user, organization: organization} = ctx
      version = ctx.gtfs_version

      diagnostic = %{
        "severity" => "error",
        "code" => "missing_coordinate",
        "entity_type" => "stop",
        "entity_id" => "NODE_1",
        "message" => "Stop has no resolvable coordinate"
      }

      run = completed_run(organization, version, ctx.station, diagnostics: [diagnostic])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#graph-diagnostics-summary", "1 problem")

      assert has_element?(
               view,
               "#graph-diagnostics-list",
               "This stop has no location on the map, so it's left out of the check."
             )

      assert has_element?(view, "#graph-diagnostics-list", "NODE_1")
    end

    test "shows the stored error and a way back when the run failed", ctx do
      %{conn: conn, user: user, organization: organization} = ctx
      version = ctx.gtfs_version
      run = failed_run(organization, version, ctx.station)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(
               view,
               "#reachability-failed[role=alert]",
               "The check stopped before it finished."
             )

      assert has_element?(view, "#reachability-failed details", "RuntimeError: routing timed out")

      assert has_element?(
               view,
               ~s(#go-to-reachability[href="/gtfs/#{version.id}/stops/STATION_STATES/reachability"])
             )
    end

    test "labels an older street-address check and keeps its rows", ctx do
      %{conn: conn, user: user, organization: organization} = ctx
      version = ctx.gtfs_version
      run = legacy_run(organization, version, ctx.station)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      assert has_element?(view, "#legacy-note", "This check used a method we've retired.")
      assert has_element?(view, "#legacy-reachability-results", "Legacy row description")
      assert has_element?(view, "#legacy-reachability-results", "Reachable")

      assert has_element?(
               view,
               ~s(#reachability-back[href="/gtfs/#{version.id}/stops/STATION_STATES/reachability"])
             )

      refute has_element?(view, "#reachability-station-unknown")
    end

    test "sends an older check with no station back to the stations list", ctx do
      %{conn: conn, user: user, organization: organization} = ctx
      version = ctx.gtfs_version
      run = legacy_run(organization, version, nil)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/station-reachability/#{run.id}")

      refute has_element?(view, "#station-sub-nav")
      assert has_element?(view, "#reachability-station-unknown")
      assert has_element?(view, ~s(#stops-back[href="/gtfs/#{version.id}/stops"]))
      assert has_element?(view, ~s(#open-stations[href="/gtfs/#{version.id}/stops"]))
    end
  end

  defp failed_run(organization, version, station) do
    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "station_reachability")

    run
    |> ValidationRun.changeset(%{
      status: "failed",
      engine: "pathways_router",
      error_details: "RuntimeError: routing timed out",
      result_json: %{"metadata" => %{"station_stop_id" => station.stop_id}},
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  # Runs from the retired street-address engine have no engine value and store
  # their rows in `walkability_test_run_results`.
  defp legacy_run(organization, version, station) do
    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "station_reachability")

    metadata = if station, do: %{"station_stop_id" => station.stop_id}, else: %{}

    run =
      run
      |> ValidationRun.changeset(%{
        status: "completed",
        result_json: %{"metadata" => metadata},
        completed_at: DateTime.utc_now()
      })
      |> Repo.update!()

    walkability_test =
      %WalkabilityTest{organization_id: organization.id, gtfs_version_id: version.id}
      |> WalkabilityTest.changeset(%{
        stop_id: "LEGACY_STOP",
        address: "1 Legacy Way",
        address_lat: Decimal.new("40.0390"),
        address_lon: Decimal.new("-75.1440"),
        description: "Legacy row description"
      })
      |> Repo.insert!()

    %WalkabilityTestRunResult{validation_run_id: run.id, walkability_test_id: walkability_test.id}
    |> WalkabilityTestRunResult.changeset(%{
      order_index: 0,
      status: "passed",
      route_exists: true,
      duration_seconds: 45.0
    })
    |> Repo.insert!()

    run
  end

  # A one-way walkway from the platform to the entrance: riders can leave, but
  # the entrance cannot reach the platform.
  defp one_way_run(organization, version) do
    station =
      stop_fixture(organization.id, version.id, %{
        stop_id: "STATION_ONE_WAY",
        stop_name: "One Way Station",
        location_type: 1,
        parent_station: nil
      })

    level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})

    for {stop_id, name, location_type} <- [
          {"ENT_A", "Entrance A", 2},
          {"PLAT_1", "Platform 1", 0}
        ] do
      stop_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        location_type: location_type,
        parent_station: station.stop_id,
        level_id: "L1"
      })
    end

    pathway_fixture(organization.id, version.id, "PLAT_1", "ENT_A", %{
      pathway_id: "PW_ONE_WAY",
      pathway_mode: 1,
      is_bidirectional: false,
      traversal_time: 30
    })

    run_battery(organization, version, station)
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

    run_battery(organization, version, station)
  end

  defp run_battery(organization, version, station) do
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

  # One entry per mode, as the runner stores them.
  defp pair_entries(kind, from, to, {walking, wheelchair}, index) do
    for {mode, outcome, offset} <- [{"walking", walking, 0}, {"wheelchair", wheelchair, 1}] do
      %{
        "index" => index + offset,
        "kind" => kind,
        "mode" => mode,
        "from_stop_id" => from,
        "from_stop_name" => "Name of #{from}",
        "to_stop_id" => to,
        "to_stop_name" => "Name of #{to}",
        "outcome" => elem(outcome, 0),
        "reason" => elem(outcome, 1),
        "duration_seconds" => if(elem(outcome, 0) == "reachable", do: 45, else: nil),
        "distance_meters" => if(elem(outcome, 0) == "reachable", do: 12, else: nil)
      }
    end
  end

  defp works, do: {"reachable", nil}
  defp no_route, do: {"unreachable", "no_path"}

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
      "outcome" => Keyword.get(opts, :outcome, "not_applicable"),
      "station" => %{"stop_id" => station.stop_id, "stop_name" => station.stop_name},
      "topology" => %{
        "entrance_count" => 1,
        "platform_count" => 1,
        "pathway_count" => 1,
        "level_count" => 1
      },
      "totals" => %{"pair_count" => 0, "reachable" => 0},
      "diagnostics" => Keyword.fetch!(opts, :diagnostics),
      "pairs" => Keyword.get(opts, :pairs, []),
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
