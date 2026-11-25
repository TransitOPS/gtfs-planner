defmodule GtfsPlannerWeb.Gtfs.StationAccessibilityLiveTest.ControlledSnapshotSource do
  @moduledoc """
  Deterministic snapshot boundary double for async lifecycle & cancellation tests.
  """

  def get_station_report_snapshot(organization_id, gtfs_version_id, stop_id) do
    Process.flag(:trap_exit, true)
    owner = Application.fetch_env!(:gtfs_planner, :station_accessibility_snapshot_owner)
    send(owner, {:snapshot_requested, self(), stop_id})

    receive do
      {:snapshot_release, :real} ->
        GtfsPlanner.Gtfs.get_station_report_snapshot(organization_id, gtfs_version_id, stop_id)

      {:snapshot_release, result} ->
        result
    after
      2_000 -> {:error, :release_timeout}
    end
  end
end

defmodule GtfsPlannerWeb.Gtfs.StationAccessibilityLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.Components.DiagramPalette
  alias GtfsPlannerWeb.Gtfs.StationAccessibilityLiveTest.ControlledSnapshotSource

  @excluded_terms [
    "Outage feed",
    "Not in outage feed",
    "Last verified",
    "Field visit",
    "Blueprint only",
    "Source: blueprint",
    "Pathways Studio"
  ]

  defp live_accessibility(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {view, render_async(view, 5_000)}
  end

  defp control_snapshot_source do
    Application.put_env(:gtfs_planner, :station_report_snapshot_source, ControlledSnapshotSource)
    Application.put_env(:gtfs_planner, :station_accessibility_snapshot_owner, self())

    on_exit(fn ->
      Application.delete_env(:gtfs_planner, :station_report_snapshot_source)
      Application.delete_env(:gtfs_planner, :station_accessibility_snapshot_owner)
    end)

    :ok
  end

  defp await_load(stop_id) do
    assert_receive {:snapshot_requested, task_pid, ^stop_id}, 2_000
    task_pid
  end

  defp release_load(task_pid, result) do
    send(task_pid, {:snapshot_release, result})
    :ok
  end

  defp create_editor_context do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)
    %{organization: organization, user: user, gtfs_version: gtfs_version}
  end

  defp build_small_station(org_id, version_id) do
    station =
      stop_fixture(org_id, version_id, %{
        stop_id: "ST_SMALL",
        stop_name: "Central Square",
        location_type: 1,
        parent_station: nil
      })

    level_fixture(org_id, version_id, %{
      level_id: "L_STREET",
      level_name: "Street",
      level_index: 0.0
    })

    level_fixture(org_id, version_id, %{
      level_id: "L_MEZZ",
      level_name: "Mezzanine",
      level_index: -1.0
    })

    level_fixture(org_id, version_id, %{
      level_id: "L_PLAT",
      level_name: "Platforms",
      level_index: -2.0
    })

    ent_a =
      stop_fixture(org_id, version_id, %{
        stop_id: "ENT_A",
        stop_name: "North Entrance",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L_STREET"
      })

    ent_b =
      stop_fixture(org_id, version_id, %{
        stop_id: "ENT_B",
        stop_name: "Stairs Only Entrance",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L_STREET"
      })

    mezz_unpaid =
      stop_fixture(org_id, version_id, %{
        stop_id: "N_MEZZ_U",
        stop_name: "Mezzanine Lobby",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: "L_MEZZ"
      })

    mezz_paid =
      stop_fixture(org_id, version_id, %{
        stop_id: "N_MEZZ_P",
        stop_name: "Concourse Hall",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: "L_MEZZ"
      })

    mezz_branch =
      stop_fixture(org_id, version_id, %{
        stop_id: "N_MEZZ_B",
        stop_name: "West Mezzanine",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: "L_MEZZ"
      })

    plat_1 =
      stop_fixture(org_id, version_id, %{
        stop_id: "PLAT_1",
        stop_name: "Inbound Platform",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L_PLAT",
        wheelchair_boarding: 1
      })

    plat_2 =
      stop_fixture(org_id, version_id, %{
        stop_id: "PLAT_2",
        stop_name: "Outbound Platform",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L_PLAT",
        wheelchair_boarding: 1
      })

    # Confirmed sole-link elevator from street to unpaid mezzanine
    pw_el1 =
      pathway_fixture(org_id, version_id, ent_a.stop_id, mezz_unpaid.stop_id, %{
        pathway_id: "EL_1",
        pathway_mode: 5,
        is_bidirectional: true,
        traversal_time: 40,
        min_width: Decimal.new("1.20")
      })

    # Near-threshold wide fare gate (0.90 m is in [0.81, 0.92])
    pw_gate =
      pathway_fixture(org_id, version_id, mezz_unpaid.stop_id, mezz_paid.stop_id, %{
        pathway_id: "GATE_1",
        pathway_mode: 6,
        is_bidirectional: true,
        min_width: Decimal.new("0.90")
      })

    # Confirmed elevator to Platform 1
    pw_el2 =
      pathway_fixture(org_id, version_id, mezz_paid.stop_id, plat_1.stop_id, %{
        pathway_id: "EL_2",
        pathway_mode: 5,
        is_bidirectional: true,
        traversal_time: 35,
        min_width: Decimal.new("1.20")
      })

    # Grouped unknown_data: two walkways on L_MEZZ missing min_width leading to Platform 2
    pw_unk1 =
      pathway_fixture(org_id, version_id, mezz_paid.stop_id, mezz_branch.stop_id, %{
        pathway_id: "PW_UNK_1",
        pathway_mode: 1,
        is_bidirectional: true,
        length: Decimal.new("20.0"),
        traversal_time: 18,
        min_width: nil
      })

    pw_unk2 =
      pathway_fixture(org_id, version_id, mezz_branch.stop_id, plat_2.stop_id, %{
        pathway_id: "PW_UNK_2",
        pathway_mode: 5,
        is_bidirectional: true,
        traversal_time: 35,
        min_width: Decimal.new("1.20")
      })

    # Second unverified walkway on same level so unknown_data groups 2 walkways together
    mezz_extra =
      stop_fixture(org_id, version_id, %{
        stop_id: "N_MEZZ_X",
        stop_name: "Side Corridor",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: "L_MEZZ"
      })

    pw_unk3 =
      pathway_fixture(org_id, version_id, mezz_paid.stop_id, mezz_extra.stop_id, %{
        pathway_id: "PW_UNK_3",
        pathway_mode: 1,
        is_bidirectional: true,
        length: Decimal.new("15.0"),
        traversal_time: 14,
        min_width: nil
      })

    # Measured barrier pathway from ENT_B (narrow doorway < 0.81 m)
    pw_barrier =
      pathway_fixture(org_id, version_id, ent_b.stop_id, mezz_unpaid.stop_id, %{
        pathway_id: "PW_BARRIER",
        pathway_mode: 1,
        is_bidirectional: true,
        length: Decimal.new("12.0"),
        traversal_time: 12,
        min_width: Decimal.new("0.70")
      })

    %{
      station: station,
      ent_a: ent_a,
      ent_b: ent_b,
      plat_1: plat_1,
      plat_2: plat_2,
      pw_el1: pw_el1,
      pw_gate: pw_gate,
      pw_el2: pw_el2,
      pw_unk1: pw_unk1,
      pw_unk2: pw_unk2,
      pw_unk3: pw_unk3,
      pw_barrier: pw_barrier
    }
  end

  defp build_large_station(org_id, version_id) do
    # 7 platforms exceeds @max_network_platforms (6) => network_available? == false
    station =
      stop_fixture(org_id, version_id, %{
        stop_id: "ST_HUB",
        stop_name: "Regional Transfer Center",
        location_type: 1,
        parent_station: nil
      })

    level_fixture(org_id, version_id, %{
      level_id: "L_HUB_ST",
      level_name: "Street",
      level_index: 0.0
    })

    level_fixture(org_id, version_id, %{
      level_id: "L_HUB_MZ",
      level_name: "Mezzanine",
      level_index: -1.0
    })

    level_fixture(org_id, version_id, %{
      level_id: "L_HUB_PL",
      level_name: "Platform Level",
      level_index: -2.0
    })

    ent_1 =
      stop_fixture(org_id, version_id, %{
        stop_id: "HUB_E1",
        stop_name: "North Entrance 1",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L_HUB_ST"
      })

    ent_2 =
      stop_fixture(org_id, version_id, %{
        stop_id: "HUB_E2",
        stop_name: "South Entrance 1",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L_HUB_ST"
      })

    # Three sequential confirmed walkways on Mezzanine so collapse_corridors collapses >= 2
    n_u1 =
      stop_fixture(org_id, version_id, %{
        stop_id: "HUB_U1",
        stop_name: "North Landing",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: "L_HUB_MZ"
      })

    n_u2 =
      stop_fixture(org_id, version_id, %{
        stop_id: "HUB_U2",
        stop_name: "Concourse Mid",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: "L_HUB_MZ"
      })

    n_u3 =
      stop_fixture(org_id, version_id, %{
        stop_id: "HUB_U3",
        stop_name: "Gate Approach",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: "L_HUB_MZ"
      })

    n_paid =
      stop_fixture(org_id, version_id, %{
        stop_id: "HUB_PAID",
        stop_name: "Paid Concourse",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: "L_HUB_MZ"
      })

    n_plat_hub =
      stop_fixture(org_id, version_id, %{
        stop_id: "HUB_PHUB",
        stop_name: "Platform Lobby",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: "L_HUB_PL"
      })

    el_north =
      pathway_fixture(org_id, version_id, ent_1.stop_id, n_u1.stop_id, %{
        pathway_id: "HUB_EL_N",
        pathway_mode: 5,
        is_bidirectional: true,
        traversal_time: 45,
        min_width: Decimal.new("1.30")
      })

    el_south =
      pathway_fixture(org_id, version_id, ent_2.stop_id, n_u3.stop_id, %{
        pathway_id: "HUB_EL_S",
        pathway_mode: 5,
        is_bidirectional: true,
        traversal_time: 40,
        min_width: Decimal.new("1.30")
      })

    # Two contiguous confirmed flat walkways in unpaid zone on L_HUB_MZ => collapses into corridor
    pw_c1 =
      pathway_fixture(org_id, version_id, n_u1.stop_id, n_u2.stop_id, %{
        pathway_id: "HUB_WALK_1",
        pathway_mode: 1,
        is_bidirectional: true,
        length: Decimal.new("40.0"),
        traversal_time: 32,
        min_width: Decimal.new("2.40")
      })

    pw_c2 =
      pathway_fixture(org_id, version_id, n_u2.stop_id, n_u3.stop_id, %{
        pathway_id: "HUB_WALK_2",
        pathway_mode: 1,
        is_bidirectional: true,
        length: Decimal.new("35.0"),
        traversal_time: 28,
        min_width: Decimal.new("2.40")
      })

    _pw_gate =
      pathway_fixture(org_id, version_id, n_u3.stop_id, n_paid.stop_id, %{
        pathway_id: "HUB_GATE_1",
        pathway_mode: 6,
        is_bidirectional: true,
        min_width: Decimal.new("1.00")
      })

    el_plat =
      pathway_fixture(org_id, version_id, n_paid.stop_id, n_plat_hub.stop_id, %{
        pathway_id: "HUB_EL_P",
        pathway_mode: 5,
        is_bidirectional: true,
        traversal_time: 35,
        min_width: Decimal.new("1.30")
      })

    platforms =
      for idx <- 1..7 do
        plat =
          stop_fixture(org_id, version_id, %{
            stop_id: "HUB_P#{idx}",
            stop_name: "Track #{idx}",
            location_type: 0,
            parent_station: station.stop_id,
            level_id: "L_HUB_PL"
          })

        pathway_fixture(org_id, version_id, n_plat_hub.stop_id, plat.stop_id, %{
          pathway_id: "HUB_PW_P#{idx}",
          pathway_mode: 1,
          is_bidirectional: true,
          length: Decimal.new("20.0"),
          traversal_time: 18,
          min_width: if(idx == 7, do: nil, else: Decimal.new("2.00"))
        })

        plat
      end

    %{
      station: station,
      ent_1: ent_1,
      ent_2: ent_2,
      platforms: platforms,
      el_north: el_north,
      el_south: el_south,
      el_plat: el_plat,
      pw_c1: pw_c1,
      pw_c2: pw_c2
    }
  end

  describe "authentication and tenant scoping" do
    test "unauthenticated request redirects to login", %{conn: conn} do
      %{organization: org, gtfs_version: version} = create_editor_context()
      %{station: station} = build_small_station(org.id, version.id)

      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               live(conn, "/gtfs/#{version.id}/stops/#{station.stop_id}/report/accessibility")
    end

    test "missing stop_id redirects to stops list with error flash", %{conn: conn} do
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()
      conn = log_in_user(conn, user, organization: org)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops/DOES_NOT_EXIST/report/accessibility")

      {to_path, flash} = assert_redirect(view, 5_000)
      assert to_path == "/gtfs/#{version.id}/stops"
      assert flash == %{"error" => "Station not found"}
    end

    test "non-station stop redirects to stops list with error flash", %{conn: conn} do
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()
      %{plat_1: platform} = build_small_station(org.id, version.id)
      conn = log_in_user(conn, user, organization: org)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops/#{platform.stop_id}/report/accessibility")

      {to_path, flash} = assert_redirect(view, 5_000)
      assert to_path == "/gtfs/#{version.id}/stops"
      assert flash == %{"error" => "Station not found"}
    end

    test "station belonging to another organization cannot be viewed", %{conn: conn} do
      %{organization: org_a, user: user_a, gtfs_version: version_a} = create_editor_context()
      %{organization: org_b, gtfs_version: version_b} = create_editor_context()
      %{station: foreign_station} = build_small_station(org_b.id, version_b.id)

      conn = log_in_user(conn, user_a, organization: org_a)

      # Accessing foreign station under own version -> not found
      {:ok, view, _html} =
        live(conn, "/gtfs/#{version_a.id}/stops/#{foreign_station.stop_id}/report/accessibility")

      {to_path, flash} = assert_redirect(view, 5_000)
      assert to_path == "/gtfs/#{version_a.id}/stops"
      assert flash == %{"error" => "Station not found"}

      # Accessing foreign version directly -> rejected by AssignGtfsVersion
      assert {:error, {:redirect, %{to: redirect_to}}} =
               live(
                 conn,
                 "/gtfs/#{version_b.id}/stops/#{foreign_station.stop_id}/report/accessibility"
               )

      assert redirect_to !=
               "/gtfs/#{version_b.id}/stops/#{foreign_station.stop_id}/report/accessibility"
    end
  end

  describe "async loading, derive_view_state/1, and cancellation" do
    test "transitions from :loading to :error with working retry_load recovery", %{conn: conn} do
      control_snapshot_source()
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()
      %{station: station} = build_small_station(org.id, version.id)

      conn = log_in_user(conn, user, organization: org)

      {:ok, view, html} =
        live(conn, "/gtfs/#{version.id}/stops/#{station.stop_id}/report/accessibility")

      assert html =~ "accessibility-loading"
      assert has_element?(view, "#station-accessibility-page[data-derived-state='loading']")

      first_task = await_load(station.stop_id)
      release_load(first_task, {:error, :transient_db_error})

      _ = render_async(view, 5_000)
      assert has_element?(view, "#station-accessibility-page[data-derived-state='error']")
      assert has_element?(view, "#accessibility-retry")

      # Retry recovers cleanly to :ready
      view |> element("#accessibility-retry") |> render_click()
      retry_task = await_load(station.stop_id)
      release_load(retry_task, :real)

      _ = render_async(view, 5_000)
      assert has_element?(view, "#station-accessibility-page[data-derived-state='ready']")
      assert has_element?(view, "#accessibility-network-view")
    end

    test "ignores superseded async result after navigating to another station", %{conn: conn} do
      control_snapshot_source()
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()
      %{station: station_one} = build_small_station(org.id, version.id)

      station_two =
        stop_fixture(org.id, version.id, %{
          stop_id: "ST_SECOND",
          stop_name: "Second Station",
          location_type: 1,
          parent_station: nil
        })

      conn = log_in_user(conn, user, organization: org)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{version.id}/stops/#{station_one.stop_id}/report/accessibility")

      stale_task = await_load(station_one.stop_id)

      # Patch to second station before first task finishes
      render_patch(
        view,
        "/gtfs/#{version.id}/stops/#{station_two.stop_id}/report/accessibility"
      )

      second_task = await_load(station_two.stop_id)

      # Release second station first, then release stale first station
      release_load(second_task, :real)
      _ = render_async(view, 5_000)

      assert has_element?(
               view,
               "#station-accessibility-page[data-derived-state='empty_topology']"
             )

      assert render(view) =~ "Second Station"

      release_load(stale_task, :real)
      _ = :sys.get_state(view.pid)

      # Stale result from station_one must NOT overwrite station_two
      html = render(view)
      assert html =~ "Second Station"
      refute html =~ "Central Square"

      assert has_element?(
               view,
               "#station-accessibility-page[data-derived-state='empty_topology']"
             )
    end

    test "renders :empty_topology state with Floorplans link", %{conn: conn} do
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()

      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "ST_EMPTY",
          stop_name: "Empty Station",
          location_type: 1,
          parent_station: nil
        })

      conn = log_in_user(conn, user, organization: org)

      {view, _html} =
        live_accessibility(
          conn,
          "/gtfs/#{version.id}/stops/#{station.stop_id}/report/accessibility"
        )

      assert has_element?(
               view,
               "#station-accessibility-page[data-derived-state='empty_topology']"
             )

      assert has_element?(view, "#accessibility-empty-topology")

      assert has_element?(
               view,
               "#empty-open-floorplans[href='/gtfs/#{version.id}/stops/#{station.stop_id}/diagram']"
             )
    end

    test "renders :no_step_free_access state and switches to Validation with Barriers enabled", %{
      conn: conn
    } do
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()

      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "ST_STAIRS",
          stop_name: "Stairs Station",
          location_type: 1,
          parent_station: nil
        })

      level_fixture(org.id, version.id, %{
        level_id: "L_S0",
        level_name: "Street",
        level_index: 0.0
      })

      level_fixture(org.id, version.id, %{
        level_id: "L_S1",
        level_name: "Platform",
        level_index: -1.0
      })

      ent =
        stop_fixture(org.id, version.id, %{
          stop_id: "ST_S_ENT",
          stop_name: "Stair Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_S0"
        })

      plat =
        stop_fixture(org.id, version.id, %{
          stop_id: "ST_S_PLAT",
          stop_name: "Stair Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L_S1",
          wheelchair_boarding: 1
        })

      pathway_fixture(org.id, version.id, ent.stop_id, plat.stop_id, %{
        pathway_id: "PW_STAIRS_ONLY",
        pathway_mode: 2,
        is_bidirectional: true
      })

      conn = log_in_user(conn, user, organization: org)

      {view, _html} =
        live_accessibility(
          conn,
          "/gtfs/#{version.id}/stops/#{station.stop_id}/report/accessibility"
        )

      assert has_element?(
               view,
               "#station-accessibility-page[data-derived-state='no_step_free_access']"
             )

      assert has_element?(view, "#accessibility-no-step-free")
      assert has_element?(view, "#no-step-free-inspect-barriers")

      view |> element("#no-step-free-inspect-barriers") |> render_click()

      assert has_element?(view, "#accessibility-network-view")
      assert has_element?(view, "#tab-validation[aria-selected='true']")
      assert has_element?(view, "#highlight-barriers[checked]")
      assert has_element?(view, "#schematic-edge-PW_STAIRS_ONLY")
    end

    test "renders cross-station incomplete warning banner when pathway leaves station", %{
      conn: conn
    } do
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()
      %{station: station, plat_1: plat_1} = build_small_station(org.id, version.id)

      other_station =
        stop_fixture(org.id, version.id, %{
          stop_id: "ST_OTHER",
          stop_name: "Adjacent Hub",
          location_type: 1,
          parent_station: nil
        })

      outside_stop =
        stop_fixture(org.id, version.id, %{
          stop_id: "OUTSIDE_NODE",
          stop_name: "Adjacent Node",
          location_type: 3,
          parent_station: other_station.stop_id,
          level_id: "L_PLAT"
        })

      pathway_fixture(org.id, version.id, plat_1.stop_id, outside_stop.stop_id, %{
        pathway_id: "PW_CROSS_STATION",
        pathway_mode: 1,
        is_bidirectional: true,
        min_width: Decimal.new("1.50"),
        length: Decimal.new("40.0"),
        traversal_time: 30
      })

      conn = log_in_user(conn, user, organization: org)

      {view, html} =
        live_accessibility(
          conn,
          "/gtfs/#{version.id}/stops/#{station.stop_id}/report/accessibility"
        )

      assert has_element?(view, "#accessibility-incomplete-banner")
      assert html =~ "PW_CROSS_STATION"
    end
  end

  describe "small station Network view (Rider routes & Validation)" do
    test "defaults to Network Rider routes, switches to Validation, toggles 4 highlights, and verifies deep-links",
         %{conn: conn} do
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()
      fixture = build_small_station(org.id, version.id)
      station = fixture.station

      conn = log_in_user(conn, user, organization: org)

      {view, rider_html} =
        live_accessibility(
          conn,
          "/gtfs/#{version.id}/stops/#{station.stop_id}/report/accessibility"
        )

      # Default view is Network -> Rider routes with view switcher visible
      assert has_element?(view, "#accessibility-view-switcher")
      assert has_element?(view, "#view-switch-network[aria-pressed='true']")
      assert has_element?(view, "#accessibility-network-view")
      assert has_element?(view, "#tab-rider-routes[aria-selected='true']")
      assert has_element?(view, "#accessibility-schematic-svg")
      assert has_element?(view, "#network-access-matrix-card")
      assert has_element?(view, "#network-elevator-dependency-card")

      # Back link to Station Report
      assert has_element?(
               view,
               "#accessibility-back-to-report[href='/gtfs/#{version.id}/stops/#{station.stop_id}/report']"
             )

      # Schematic edge links to Floorplans with ?edit_pathway_id=&level=
      el1_href =
        "/gtfs/#{version.id}/stops/#{station.stop_id}/diagram?edit_pathway_id=#{fixture.pw_el1.id}&level=L_STREET"

      assert has_element?(view, "#schematic-edge-EL_1[href='#{el1_href}']")

      # Schematic stop node links to Report 2 with ?edit_stop_id=
      plat1_href =
        "/gtfs/#{version.id}/stops/#{station.stop_id}/report?edit_stop_id=#{fixture.plat_1.id}"

      assert has_element?(view, "#schematic-node-PLAT_1[href='#{plat1_href}']")

      # Switch to Validation tab
      view |> element("#tab-validation") |> render_click()
      validation_html = render(view)

      assert has_element?(view, "#tab-validation[aria-selected='true']")
      assert has_element?(view, "#validation-highlight-filters")
      assert has_element?(view, "#validation-confidence-card")
      assert has_element?(view, "#confidence-confirmed")
      assert has_element?(view, "#confidence-unverified")
      assert has_element?(view, "#confidence-no-route")
      assert has_element?(view, "#validation-issues-card")

      # Toggle all 4 highlight checkboxes
      refute has_element?(view, "#highlight-barriers[checked]")
      view |> element("#highlight-barriers") |> render_click()
      assert has_element?(view, "#highlight-barriers[checked]")
      assert has_element?(view, "#schematic-edge-PW_BARRIER")

      for id <- [
            "#highlight-unknown-data",
            "#highlight-near-threshold",
            "#highlight-single-elevator"
          ] do
        assert has_element?(view, "#{id}[checked]")
        view |> element(id) |> render_click()
        refute has_element?(view, "#{id}[checked]")
      end

      # Invalid toggle key does not crash
      render_click(view, "toggle_highlight", %{"key" => "nonexistent_layer"})

      # All 5 issue kinds present: single_elevator, barrier, unknown_data (grouped), flag_mismatch, near_threshold
      assert has_element?(view, "[data-issue-kind='single_elevator']")
      assert has_element?(view, "[data-issue-kind='barrier']")
      assert has_element?(view, "[data-issue-kind='unknown_data']")
      assert has_element?(view, "[data-issue-kind='flag_mismatch']")
      assert has_element?(view, "[data-issue-kind='near_threshold']")

      # Flag mismatch links to Station Report ?edit_stop_id=<plat_2.id>
      plat2_href =
        "/gtfs/#{version.id}/stops/#{station.stop_id}/report?edit_stop_id=#{fixture.plat_2.id}"

      assert has_element?(view, "#issue-action-flag_mismatch-PLAT_2[href='#{plat2_href}']")

      # Barrier issue links to Floorplans ?edit_pathway_id=<pw_barrier.id>&level=L_STREET
      barrier_href =
        "/gtfs/#{version.id}/stops/#{station.stop_id}/diagram?edit_pathway_id=#{fixture.pw_barrier.id}&level=L_STREET"

      assert has_element?(view, "#issue-action-barrier-PW_BARRIER[href='#{barrier_href}']")

      # Grouped unknown_data expands to show both pathway links into Floorplans
      view |> element("#issue-toggle-edges-unknown_data-PW_UNK_1") |> render_click()
      assert has_element?(view, "#issue-edges-unknown_data-PW_UNK_1")

      unk1_href =
        "/gtfs/#{version.id}/stops/#{station.stop_id}/diagram?edit_pathway_id=#{fixture.pw_unk1.id}&level=L_MEZZ"

      unk3_href =
        "/gtfs/#{version.id}/stops/#{station.stop_id}/diagram?edit_pathway_id=#{fixture.pw_unk3.id}&level=L_MEZZ"

      assert has_element?(view, "#issue-edge-link-PW_UNK_1[href='#{unk1_href}']")
      assert has_element?(view, "#issue-edge-link-PW_UNK_3[href='#{unk3_href}']")

      # Switch to Impact & routes view
      view |> element("#view-switch-impact") |> render_click()
      assert has_element?(view, "#accessibility-impact-view")
      assert has_element?(view, "#view-switch-impact[aria-pressed='true']")

      # Strict exclusions check across Rider routes and Validation HTML
      for excluded <- @excluded_terms do
        refute rider_html =~ excluded
        refute validation_html =~ excluded
      end
    end

    test "preselects route from ?from=&to= query params and tolerates invalid params", %{
      conn: conn
    } do
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()
      %{station: station} = build_small_station(org.id, version.id)
      conn = log_in_user(conn, user, organization: org)

      # ?from=ENT_A&to=PLAT_2 opens Impact & routes with that pair selected
      {view, _html} =
        live_accessibility(
          conn,
          "/gtfs/#{version.id}/stops/#{station.stop_id}/report/accessibility?from=ENT_A&to=PLAT_2"
        )

      assert has_element?(view, "#accessibility-impact-view")
      assert has_element?(view, "#route-pill-ENT_A-PLAT_2[aria-pressed='true']")
      assert has_element?(view, "#selected-route-summary[data-route-status='unverified']")

      # Invalid params normalize cleanly without crashing
      {view_bad, _html} =
        live_accessibility(
          conn,
          "/gtfs/#{version.id}/stops/#{station.stop_id}/report/accessibility?view=bogus&tab=bogus&from=NOPE&to=NOPE&cell=bad"
        )

      assert has_element?(view_bad, "#accessibility-network-view")
      assert has_element?(view_bad, "#tab-rider-routes[aria-selected='true']")
    end
  end

  describe "large station Impact & routes view (CR-S4)" do
    test "enforces Impact & routes only, normalizes ?view=network, supports stepper corridor collapse, grouped matrix drill-down, and 3-column elevator table",
         %{conn: conn} do
      %{organization: org, user: user, gtfs_version: version} = create_editor_context()
      fixture = build_large_station(org.id, version.id)
      station = fixture.station
      conn = log_in_user(conn, user, organization: org)

      # Even when requesting ?view=network, large station normalizes to :impact and hides switcher
      {view, html} =
        live_accessibility(
          conn,
          "/gtfs/#{version.id}/stops/#{station.stop_id}/report/accessibility?view=network"
        )

      assert has_element?(view, "#accessibility-impact-view")
      refute has_element?(view, "#accessibility-view-switcher")
      refute has_element?(view, "#accessibility-network-view")
      refute has_element?(view, "#accessibility-schematic-svg")

      # Forged switch_view to "network" is ignored
      render_click(view, "switch_view", %{"view" => "network"})
      assert has_element?(view, "#accessibility-impact-view")
      refute has_element?(view, "#accessibility-network-view")

      # 4 KPI tiles present
      assert has_element?(view, "#kpi-step-free-entrances")
      assert has_element?(view, "#kpi-confirmed-pairs")
      assert has_element?(view, "#kpi-unverified-pairs")
      assert has_element?(view, "#kpi-sole-elevators")

      # Select HUB_E1 -> HUB_P1 via route selector so the 2-edge verified corridor collapses
      render_click(view, "select_route", %{"from" => "HUB_E1", "to" => "HUB_P1"})

      assert has_element?(view, "#selected-route-summary[data-route-status='confirmed']")
      corridor_toggle = "#corridor-toggle-corridor-HUB_WALK_1--HUB_WALK_2"
      corridor_steps = "#corridor-steps-corridor-HUB_WALK_1--HUB_WALK_2"

      assert has_element?(view, "#{corridor_toggle}[aria-expanded='false']")
      refute has_element?(view, corridor_steps)

      # Expand collapsed verified corridor -> reveals constituent walkway Floorplans links
      view |> element(corridor_toggle) |> render_click()
      assert has_element?(view, "#{corridor_toggle}[aria-expanded='true']")
      assert has_element?(view, corridor_steps)

      walk1_href =
        "/gtfs/#{version.id}/stops/#{station.stop_id}/diagram?edit_pathway_id=#{fixture.pw_c1.id}&level=L_HUB_MZ"

      assert has_element?(view, "#stepper-edit-HUB_WALK_1[href='#{walk1_href}']")

      # Collapse corridor again
      view |> element(corridor_toggle) |> render_click()
      assert has_element?(view, "#{corridor_toggle}[aria-expanded='false']")
      refute has_element?(view, corridor_steps)

      # Toggle direction to return trip (:to_exit)
      view |> element("#direction-to-exit") |> render_click()
      assert has_element?(view, "#direction-to-exit[aria-pressed='true']")

      # Grouped matrix cell click opens inline drill-down and lets editor inspect a pair
      cell_button = "#group-cell-eg-HUB_E1-pg-HUB_P1"
      assert has_element?(view, cell_button)
      view |> element(cell_button) |> render_click()
      assert has_element?(view, "#grouped-matrix-drilldown")
      assert has_element?(view, "#drilldown-inspect-HUB_E1-HUB_P7")

      view |> element("#drilldown-inspect-HUB_E1-HUB_P7") |> render_click()
      assert has_element?(view, "#selected-route-summary[data-route-status='unverified']")

      # Elevator dependency table has strictly 3 columns: Elevator, Connects, Sole link for
      assert has_element?(view, "#elevator-dependency-table thead tr th", "Elevator")
      assert has_element?(view, "#elevator-dependency-table thead tr th", "Connects")
      assert has_element?(view, "#elevator-dependency-table thead tr th", "Sole link for")

      table_html = view |> element("#elevator-dependency-table thead") |> render()
      assert length(:binary.matches(table_html, "</th>")) == 3

      # Strict exclusions check on large station Impact & routes HTML
      for excluded <- @excluded_terms do
        refute html =~ excluded
      end
    end
  end

  describe "WCAG AA contrast for custom purple unverified tokens" do
    test "--color-unverified-fg (#5b21b6) on --color-unverified-bg (#f3edff) meets >= 4.5:1 AA" do
      ratio = DiagramPalette.contrast_ratio("#f3edff", "#5b21b6")
      assert ratio >= 4.5
    end
  end
end
