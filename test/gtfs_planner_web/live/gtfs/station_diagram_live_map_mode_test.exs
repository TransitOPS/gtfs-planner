defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveMapModeTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.FloorplanTransform
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.StationDiagramComponents

  # Coordinate review cases (Package 08 step 3) swap
  # :gtfs_planner, :reviewed_apply_transaction and may run the production
  # adapter through shared sandbox, so the whole module is non-async.
  setup do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)

        :error ->
          Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    :ok
  end

  defp map_generation(view) do
    [_, generation] = Regex.run(~r/data-map-generation="([^"]+)"/, render(view))
    generation
  end

  defp set_image_natural_size(view, width, height) do
    render_hook(view, "set_image_natural_size", %{
      "generation" => map_generation(view),
      "w" => width,
      "h" => height
    })
  end

  defp map_event(view, event, params) do
    render_hook(view, event, Map.put(params, "generation", map_generation(view)))
  end

  defp open_coordinate_review(view, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "center_lat" => 40.7128,
          "center_lon" => -74.006,
          "scale_mpp" => 0.35,
          "rotation_deg" => 0.0
        },
        overrides
      )

    map_event(view, "open_coordinate_review", params)
  end

  defp apply_coordinate_review(view), do: render_hook(view, "apply_coordinate_review", %{})

  describe "StationDiagramLive - map mode" do
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
          stop_id: "MAP_STATION",
          stop_name: "Map Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "map_level",
          level_name: "Map Level",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level,
        stop_level: stop_level
      }
    end

    test "mode_toggle renders a Map button", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#diagram-mode-option-map")
      assert has_element?(view, "label[for='diagram-mode-option-map']", "Align")
    end

    test "Map button is disabled when no diagram file exists", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#diagram-mode-option-map[disabled]")
    end

    test "switch_mode to map swaps to the map canvas and hides station data tables", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#lists-section")

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, ".map-canvas")
      refute has_element?(view, "[id^='diagram-canvas-']")
      refute has_element?(view, "#lists-section")

      render_hook(view, "switch_mode", %{"mode" => "view"})

      assert has_element?(view, "#lists-section")
    end

    test "renders the other-levels trigger in map mode and drops the reference select (AC-1)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, "#other-levels-button")
      refute has_element?(view, "#reference-overlay-level-select")
      refute has_element?(view, "#reference-overlay-level-form")
    end

    test "row shows level name and {geo}/{total} located subtext (AC-3)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      other_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "ac3_other",
          level_name: "AC3 Other",
          level_index: 1.0
        })

      {:ok, _other_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: other_level.id
        })

      _geo_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "AC3_GEO",
          stop_name: "AC3 Geo",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: other_level.level_id,
          stop_lat: Decimal.new("40.7000"),
          stop_lon: Decimal.new("-74.0000")
        })

      _no_geo_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "AC3_NOGEO",
          stop_name: "AC3 No Geo",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: other_level.level_id,
          stop_lat: nil,
          stop_lon: nil
        })

      # Active level child stop must not be counted in the other level's row.
      _active_child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "AC3_ACTIVE",
          stop_name: "AC3 Active",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, "#other-levels-panel", "AC3 Other")
      assert has_element?(view, "#other-levels-panel", "1/2 located")
    end

    test "toggling floorplan flips its checkbox and badge (AC-4, AC-6)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      other_level_id = aligned_other_level(organization, gtfs_version, station, "ac4")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      refute has_element?(view, "#other-levels-button .badge")
      refute floorplan_checked?(view, other_level_id)

      render_click(element(view, floorplan_selector(other_level_id)))

      assert has_element?(view, "#other-levels-button .badge", "1")
      assert floorplan_checked?(view, other_level_id)

      render_click(element(view, floorplan_selector(other_level_id)))

      refute has_element?(view, "#other-levels-button .badge")
      refute floorplan_checked?(view, other_level_id)
    end

    test "toggling stops flips its checkbox and badge (AC-5, AC-6)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      other_level_id = level_with_geo_stop(organization, gtfs_version, station, "ac5")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      refute has_element?(view, "#other-levels-button .badge")

      render_click(element(view, stops_selector(other_level_id)))

      assert has_element?(view, "#other-levels-button .badge", "1")
      assert stops_checked?(view, other_level_id)

      render_click(element(view, stops_selector(other_level_id)))

      refute has_element?(view, "#other-levels-button .badge")
      refute stops_checked?(view, other_level_id)
    end

    test "badge counts distinct levels with floorplan or stops enabled (AC-6)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      floorplan_level = aligned_other_level(organization, gtfs_version, station, "ac6fp", 1.0)
      stops_level = level_with_geo_stop(organization, gtfs_version, station, "ac6st", -1.0)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      render_click(element(view, floorplan_selector(floorplan_level)))
      assert has_element?(view, "#other-levels-button .badge", "1")

      render_click(element(view, stops_selector(stops_level)))
      assert has_element?(view, "#other-levels-button .badge", "2")
    end

    test "clear resets both toggles and the badge (AC-7)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      floorplan_level = aligned_other_level(organization, gtfs_version, station, "ac7fp", 1.0)
      stops_level = level_with_geo_stop(organization, gtfs_version, station, "ac7st", -1.0)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      render_click(element(view, floorplan_selector(floorplan_level)))
      render_click(element(view, stops_selector(stops_level)))
      assert has_element?(view, "#other-levels-button .badge", "2")

      render_click(element(view, "#other-levels-panel button", "Clear"))

      refute has_element?(view, "#other-levels-button .badge")
      refute floorplan_checked?(view, floorplan_level)
      refute stops_checked?(view, stops_level)
    end

    test "ineligible floorplan checkboxes render disabled with reasons (AC-8, AC-17)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      # Diagram but no alignment -> "Not yet aligned".
      unaligned_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "ac8_unaligned",
          level_name: "AC8 Unaligned",
          level_index: 1.0
        })

      {:ok, unaligned_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: unaligned_level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(unaligned_stop_level, "ac8-unaligned.png")

      # No diagram -> "No diagram".
      no_diagram_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "ac8_nodiagram",
          level_name: "AC8 No Diagram",
          level_index: -1.0
        })

      {:ok, _no_diagram_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: no_diagram_level.id
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, floorplan_selector(unaligned_level.id) <> "[disabled]")

      assert has_element?(
               view,
               "#floorplan-reason-#{unaligned_level.id}",
               "Not yet aligned"
             )

      assert has_element?(
               view,
               floorplan_selector(unaligned_level.id) <>
                 "[aria-describedby='floorplan-reason-#{unaligned_level.id}']"
             )

      assert has_element?(view, floorplan_selector(no_diagram_level.id) <> "[disabled]")
      assert has_element?(view, "#floorplan-reason-#{no_diagram_level.id}", "No diagram")
    end

    test "stops checkbox disabled with reason when no geo-coded child stops (AC-9)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      other_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "ac9_other",
          level_name: "AC9 Other",
          level_index: 1.0
        })

      {:ok, _other_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: other_level.id
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, stops_selector(other_level.id) <> "[disabled]")

      assert has_element?(
               view,
               "#stops-reason-#{other_level.id}",
               "No geo-coded child stops"
             )

      assert has_element?(
               view,
               stops_selector(other_level.id) <>
                 "[aria-describedby='stops-reason-#{other_level.id}']"
             )
    end

    test "shows empty state when the station has no other levels (AC-10)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(
               view,
               "#other-levels-panel",
               "This station has no other levels to compare."
             )

      refute has_element?(view, "[phx-click='toggle_other_level_floorplan']")
    end

    test "switching the active level resets toggles and badge (AC-11)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      other_level_id = aligned_other_level(organization, gtfs_version, station, "ac11")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      render_click(element(view, floorplan_selector(other_level_id)))
      assert has_element?(view, "#other-levels-button .badge", "1")

      render_hook(view, "switch_level", %{"level_id" => other_level_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert MapSet.size(assigns.other_levels_floorplan) == 0
      assert MapSet.size(assigns.other_levels_stops) == 0
      refute has_element?(view, "#other-levels-button .badge")
    end

    test "switching out of map mode empties the toggle MapSets (AC-12)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      other_level_id = aligned_other_level(organization, gtfs_version, station, "ac12")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      render_click(element(view, floorplan_selector(other_level_id)))
      assert has_element?(view, "#other-levels-button .badge", "1")

      render_hook(view, "switch_mode", %{"mode" => "view"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert MapSet.size(assigns.other_levels_floorplan) == 0
      assert MapSet.size(assigns.other_levels_stops) == 0

      render_hook(view, "switch_mode", %{"mode" => "map"})
      refute has_element?(view, "#other-levels-button .badge")
    end

    test "panel counts reflect updated geo data after Apply Image Position (AC-13)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: active_level,
      stop_level: active_stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(active_stop_level, "map-diagram.png")

      # Active-level child stop without lat/lon; Apply will geo-code it.
      _child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "AC13_CHILD",
          stop_name: "AC13 Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: active_level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0},
          stop_lat: nil,
          stop_lon: nil
        })

      # A second level we switch to afterwards, so the applied level becomes "other".
      target_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "ac13_target",
          level_name: "AC13 Target",
          level_index: 1.0
        })

      {:ok, target_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: target_level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(target_stop_level, "ac13-target.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      # With the target level active, L0 (the level holding the ungeocoded child stop) is an
      # "other" level showing 0 of 1 located.
      render_hook(view, "switch_level", %{"level_id" => target_level.id})
      assert has_element?(view, "#other-levels-panel", "0/1 located")

      # Switch back to L0 and apply: geo-codes AC13_CHILD on the active level and invalidates
      # the per-level counts/markers caches.
      render_hook(view, "switch_level", %{"level_id" => active_level.id})
      set_image_natural_size(view, 1024, 768)

      html = open_coordinate_review(view)

      assert has_element?(view, "#coordinate-review-dialog")
      assert html =~ "Update coordinates for"
      apply_coordinate_review(view)

      # Switch back to the target level so L0 is "other" again; its count must reflect the
      # newly written geo coordinate (caches were invalidated on Apply).
      render_hook(view, "switch_level", %{"level_id" => target_level.id})

      assert has_element?(view, "#other-levels-panel", "1/1 located")
    end

    test "trigger and panel expose required a11y attributes (AC-17)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, "#other-levels-button[aria-expanded]")
      assert has_element?(view, "#other-levels-button[aria-controls='other-levels-panel']")
      assert has_element?(view, "#other-levels-panel[role='dialog']")
    end

    test "action strip shows map-mode hint", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(
               view,
               "#diagram-action-strip",
               "Align the floorplan over real-world imagery"
             )

      refute has_element?(view, "#adjacent-overlay-toggle-group")
    end

    test "map mode renders without synced/aligned levels count UI", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: middle_stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(middle_stop_level, "map-diagram.png")

      below_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "synced_count_below",
          level_name: "Synced Count Below",
          level_index: -1.0
        })

      above_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "synced_count_above",
          level_name: "Synced Count Above",
          level_index: 1.0
        })

      {:ok, below_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: below_level.id
        })

      {:ok, above_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: above_level.id
        })

      alignment_attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.35,
        floorplan_rotation_deg: 0.0
      }

      {:ok, _middle_stop_level} =
        Gtfs.update_stop_level_alignment(middle_stop_level, alignment_attrs)

      {:ok, _below_stop_level} =
        Gtfs.update_stop_level_alignment(below_stop_level, alignment_attrs)

      {:ok, _above_stop_level} =
        Gtfs.update_stop_level_alignment(above_stop_level, alignment_attrs)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, "#map-canvas-wrapper")
    end

    test "canvas_click in map mode is a no-op", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "canvas_click", %{"x" => 50, "y" => 50})

      assert has_element?(view, "#diagram-mode-option-map[checked]")
    end

    test "stop_clicked in map mode is a no-op", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "MAP_CHILD_1",
          stop_name: "Map Child 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 25.0, "y" => 35.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "stop_clicked", %{"id" => child_stop.id})

      assert has_element?(view, ".map-canvas")
    end

    test "switching from map back to view restores the diagram canvas", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "switch_mode", %{"mode" => "view"})

      assert has_element?(view, "[id^='diagram-canvas-']")
      refute has_element?(view, ".map-canvas")
    end

    test "map canvas renders the floorplan image", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, ".map-canvas img[src]")
    end

    test "map canvas renders the leaflet overlay container with hook wiring", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, ".map-canvas[phx-hook='MapAlignment'][phx-update='ignore']")

      assert has_element?(view, ".map-canvas #map-alignment-leaflet")
      assert has_element?(view, "#map-alignment-overlay img[alt='Level floorplan']")
      assert has_element?(view, "#map-other-overlays")
      assert has_element?(view, "#map-other-pins")
      assert has_element?(view, "#map-alignment-pins-active[data-overlay-role='active']")
      refute has_element?(view, "#map-alignment-pins-reference")
    end

    test "active overlay stays editable and other-level overlays stay non-interactive (AC-16)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: middle_level,
      stop_level: middle_stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(middle_stop_level, "map-diagram.png")

      alignment_attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.35,
        floorplan_rotation_deg: 0.0
      }

      {:ok, _} = Gtfs.update_stop_level_alignment(middle_stop_level, alignment_attrs)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(
               view,
               "#map-alignment-overlay[data-overlay-role='active'][data-editable-overlay='true'].cursor-move"
             )

      assert has_element?(
               view,
               "#map-alignment-rotate-handle[data-edit-target-overlay='active']"
             )

      assert has_element?(
               view,
               "#map-alignment-scale-handle[data-edit-target-overlay='active']"
             )

      assert middle_level.id == :sys.get_state(view.pid).socket.assigns.active_level.id
    end

    test "map canvas exposes initial view data attributes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, station} =
        Gtfs.update_stop(station, %{
          stop_lat: Decimal.new("42.3601"),
          stop_lon: Decimal.new("-71.0589")
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render(view)

      assert [_, lat] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-lat="([^"]+)"/, html)
      assert [_, lon] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-lon="([^"]+)"/, html)
      assert [_, zoom] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-zoom="([^"]+)"/, html)

      assert lat == to_string(station.stop_lat)
      assert lon == to_string(station.stop_lon)
      assert zoom == "19"
    end

    test "map canvas falls back to 0,0 when station lat/lon are nil", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, station} =
        Gtfs.update_stop(station, %{stop_lat: nil, stop_lon: nil})

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render(view)

      assert [_, lat] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-lat="([^"]+)"/, html)
      assert [_, lon] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-lon="([^"]+)"/, html)

      assert lat == "0"
      assert lon == "0"
    end

    test "map canvas renders the control strip elements", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, "#map-alignment-lat-input")
      assert has_element?(view, "#map-alignment-lon-input")
      assert has_element?(view, "#map-alignment-apply-center")
      assert has_element?(view, "#map-alignment-save", "Save alignment")
      assert has_element?(view, "#map-alignment-apply")
      refute has_element?(view, "#map-alignment-infer")
      refute has_element?(view, "#map-canvas-wrapper", "Infer from anchors")
      assert has_element?(view, "#map-alignment-rotate-handle")
      assert has_element?(view, "#map-alignment-scale-handle")
      refute has_element?(view, "#map-alignment-reset")
      refute has_element?(view, "#map-alignment-clear")
    end

    test "map control row shows one primary save action with floorplan-and-stops copy", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render(view)

      assert has_element?(view, "#map-alignment-save", "Save alignment")
      assert has_element?(view, "#map-alignment-apply.btn-primary", "Review coordinate changes")

      # Exactly one visible primary save action in the control row.
      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#map-alignment-actions .btn-primary")
             |> Enum.count() == 1

      # Accessible preview-status region the hook can update.
      assert has_element?(view, "#map-alignment-preview-status[aria-live='polite']")
    end

    test "save_alignment persists the four fields on the active stop_level", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      map_event(view, "save_alignment", %{
        "center_lat" => 40.7128,
        "center_lon" => -74.0060,
        "scale_mpp" => 0.35,
        "rotation_deg" => 15.5
      })

      reloaded = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      assert_in_delta reloaded.floorplan_center_lat, 40.7128, 1.0e-6
      assert_in_delta reloaded.floorplan_center_lon, -74.0060, 1.0e-6
      assert_in_delta reloaded.floorplan_scale_mpp, 0.35, 1.0e-6
      assert_in_delta reloaded.floorplan_rotation_deg, 15.5, 1.0e-6
    end

    test "a saved alignment makes that level floorplan-eligible once it becomes an other level",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: middle_level,
           stop_level: middle_stop_level
         } do
      {:ok, _} = Gtfs.update_stop_level_diagram(middle_stop_level, "map-diagram.png")

      above_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "alignment_ref_above",
          level_name: "Alignment Ref Above",
          level_index: 1.0
        })

      {:ok, above_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: above_level.id,
          diagram_filename: "above-ref.png"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      # Before saving alignment, the middle level (once it becomes "other") would be ineligible.
      map_event(view, "save_alignment", %{
        "center_lat" => 40.7128,
        "center_lon" => -74.0060,
        "scale_mpp" => 0.35,
        "rotation_deg" => 15.5
      })

      render_hook(view, "switch_level", %{"level_id" => above_level.id})

      # The middle level now appears as an other level with a saved alignment and a diagram,
      # so its floorplan checkbox is enabled (no disabled reason).
      refute has_element?(view, floorplan_selector(middle_level.id) <> "[disabled]")
      refute has_element?(view, "#floorplan-reason-#{middle_level.id}")

      reloaded = Repo.get!(GtfsPlanner.Gtfs.StopLevel, above_stop_level.id)
      assert reloaded.level_id == above_level.id
    end

    test "save_alignment rejects out-of-range lat and does not mutate the DB", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html =
        map_event(view, "save_alignment", %{
          "center_lat" => 200,
          "center_lon" => 0,
          "scale_mpp" => 0.5,
          "rotation_deg" => 0
        })

      reloaded = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      assert reloaded.floorplan_center_lat == nil
      assert reloaded.floorplan_center_lon == nil
      assert reloaded.floorplan_scale_mpp == nil
      assert reloaded.floorplan_rotation_deg == nil

      assert html =~ "Could not save alignment"
      assert html =~ "floorplan_center_lat"
    end

    test "map canvas renders data-align-* attributes when alignment is set", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      {:ok, _stop_level} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.0060,
          floorplan_scale_mpp: 0.35,
          floorplan_rotation_deg: 15.5
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render(view)

      assert [_, lat] =
               Regex.run(~r/id="map-canvas[^"]*"[^>]*data-align-center-lat="([^"]+)"/, html)

      assert [_, lon] =
               Regex.run(~r/id="map-canvas[^"]*"[^>]*data-align-center-lon="([^"]+)"/, html)

      assert [_, mpp] =
               Regex.run(~r/id="map-canvas[^"]*"[^>]*data-align-scale-mpp="([^"]+)"/, html)

      assert [_, rot] =
               Regex.run(~r/id="map-canvas[^"]*"[^>]*data-align-rotation-deg="([^"]+)"/, html)

      assert String.to_float(lat) == 40.7128
      assert String.to_float(lon) == -74.0060
      assert String.to_float(mpp) == 0.35
      assert String.to_float(rot) == 15.5
    end

    test "map canvas omits data-align-* attributes when alignment is partial or nil", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render(view)

      [_, opening_tag] = Regex.run(~r/(<div[^>]*id="map-canvas[^"]*"[^>]*>)/, html)

      refute opening_tag =~ "data-align-center-lat"
      refute opening_tag =~ "data-align-center-lon"
      refute opening_tag =~ "data-align-scale-mpp"
      refute opening_tag =~ "data-align-rotation-deg"
    end

    test "apply button is disabled when image dims not reported", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      {:ok, _aligned} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.0060,
          floorplan_scale_mpp: 0.35,
          floorplan_rotation_deg: 0.0
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, "#map-alignment-apply[disabled]")
    end

    test "apply button is enabled when alignment saved and image dims present", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      {:ok, _aligned} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.0060,
          floorplan_scale_mpp: 0.35,
          floorplan_rotation_deg: 0.0
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      assert has_element?(view, "#map-alignment-apply")
      refute has_element?(view, "#map-alignment-apply[disabled]")
    end

    test "optional building degradation keeps alignment controls usable and fatal failure explains disablement",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           stop_level: stop_level
         } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      [_, generation] = Regex.run(~r/data-map-generation="([^"]+)"/, render(view))

      render_hook(view, "set_image_natural_size", %{
        "generation" => generation,
        "w" => 1024,
        "h" => 768
      })

      render_hook(view, "map_state", %{
        "generation" => generation,
        "state" => "buildings_degraded"
      })

      refute has_element?(view, "#map-alignment-save[disabled]")
      refute has_element?(view, "#map-alignment-apply[disabled]")

      assert has_element?(
               view,
               "#map-alignment-state",
               "Building outlines are unavailable. You can continue aligning the floorplan."
             )

      render_hook(view, "map_state", %{"generation" => generation, "state" => "fatal"})

      assert has_element?(view, "#map-alignment-save[disabled]")
      assert has_element?(view, "#map-alignment-apply[disabled]")

      assert has_element?(
               view,
               "#map-alignment-disabled-reason",
               "Map service is unavailable. Retry the map before saving or previewing coordinates."
             )
    end

    test "infer button is hidden in map mode", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      refute has_element?(view, "#map-alignment-infer")
      refute render(view) =~ "Infer from anchors"
    end

    test "infer button remains hidden when image dims are missing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      refute has_element?(view, "#map-alignment-infer")
    end

    test "infer button remains hidden even with image dims", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1000, 800)

      refute has_element?(view, "#map-alignment-infer")
    end

    test "set_image_natural_size with valid integers updates the image dimension assigns", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.floorplan_image_w == 1024
      assert assigns.floorplan_image_h == 768
    end

    test "set_image_natural_size coerces float payloads to positive integers", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024.7, 768.4)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.floorplan_image_w == 1024
      assert assigns.floorplan_image_h == 768
    end

    test "set_image_natural_size ignores non-positive payloads", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 0, -5)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.floorplan_image_w == nil
      assert assigns.floorplan_image_h == nil
    end

    test "open and apply coordinate review persists alignment and stop lat/lon and flashes count",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: stop_level
         } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "APPLY_CHILD_1",
          stop_name: "Apply Child 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      # Drain the markers pushed on mode switch so the post-apply assertion below
      # proves the re-push, not the initial push.
      assert_push_event(view, "set_active_child_stops", %{stops: _})

      html = open_coordinate_review(view)

      assert has_element?(view, "#coordinate-review-dialog")
      assert html =~ "Update coordinates for"
      apply_coordinate_review(view)

      # Active marker payloads are re-pushed after apply so pins reflect the
      # persisted geography.
      assert_push_event(view, "set_active_child_stops", %{stops: _stops})

      reloaded_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert reloaded_level.floorplan_center_lat == 40.7128
      assert reloaded_level.floorplan_center_lon == -74.0060
      assert reloaded_level.floorplan_scale_mpp == 0.35
      assert reloaded_level.floorplan_rotation_deg == 0.0

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, child_stop.id)
      refute is_nil(reloaded.stop_lat)
      refute is_nil(reloaded.stop_lon)
    end

    test "open_coordinate_review without image dimensions shows error and makes no writes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NO_DIMS_CHILD",
          stop_name: "No Dims Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      original_lat = child_stop.stop_lat
      original_lon = child_stop.stop_lon

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = open_coordinate_review(view)

      assert html =~ "Floorplan image not ready"

      reloaded_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert reloaded_level.floorplan_center_lat == nil

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, child_stop.id)
      assert reloaded.stop_lat == original_lat
      assert reloaded.stop_lon == original_lon
    end

    test "active child-stop payload carries a cross-level pathway badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level,
      level: level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      other_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "BADGE_OTHER_LEVEL",
          level_name: "Badge Other Level",
          level_index: 1.0
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: other_level.id
        })

      active_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BADGE_ACTIVE",
          stop_name: "Badge Active",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          stop_lat: Decimal.new("40.7000"),
          stop_lon: Decimal.new("-74.0000")
        })

      other_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BADGE_OTHER",
          stop_name: "Badge Other",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: other_level.level_id,
          stop_lat: Decimal.new("40.7010"),
          stop_lon: Decimal.new("-74.0010")
        })

      _stairs_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          active_stop.stop_id,
          other_stop.stop_id,
          %{pathway_mode: 2, is_bidirectional: false}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert_push_event(view, "set_active_child_stops", %{stops: stops})
      marker = Enum.find(stops, &(&1.stop_id == "BADGE_ACTIVE"))

      assert [%{pathway_mode: 2}] = marker.badges
    end

    test "active child-stop payload omits badges for stops without cross-level pathways", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level,
      level: level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      _plain_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BADGE_NONE",
          stop_name: "Badge None",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          stop_lat: Decimal.new("40.7000"),
          stop_lon: Decimal.new("-74.0000")
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert_push_event(view, "set_active_child_stops", %{stops: stops})
      marker = Enum.find(stops, &(&1.stop_id == "BADGE_NONE"))

      assert marker.badges == []
    end

    test "active child-stop payload includes diagram_coordinate for stops with diagram coords",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           stop_level: stop_level,
           level: level
         } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      _diagram_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DIAGRAM_AND_GEO",
          stop_name: "Diagram And Geo",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
          stop_lat: Decimal.new("40.7000"),
          stop_lon: Decimal.new("-74.0000")
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert_push_event(view, "set_active_child_stops", %{stops: stops})
      marker = Enum.find(stops, &(&1.stop_id == "DIAGRAM_AND_GEO"))

      assert marker.diagram_coordinate == %{x: 50.0, y: 40.0}
    end

    test "active child-stop payload includes diagram-only stops without lat/lon", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level,
      level: level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      _diagram_only_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DIAGRAM_ONLY",
          stop_name: "Diagram Only",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 25.0, "y" => 35.0},
          stop_lat: nil,
          stop_lon: nil
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert_push_event(view, "set_active_child_stops", %{stops: stops})
      marker = Enum.find(stops, &(&1.stop_id == "DIAGRAM_ONLY"))

      assert marker.lat == nil
      assert marker.lon == nil
      assert marker.diagram_coordinate == %{x: 25.0, y: 35.0}
    end

    test "active child-stop payload excludes stops with neither diagram coord nor lat/lon", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level,
      level: level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      _unlocated_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NO_COORDS",
          stop_name: "No Coords",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: nil,
          stop_lat: nil,
          stop_lon: nil
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert_push_event(view, "set_active_child_stops", %{stops: stops})

      assert Enum.find(stops, &(&1.stop_id == "NO_COORDS")) == nil
    end

    test "set_other_levels payload shape is unchanged when active markers carry diagram_coordinate (AC-17)",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           stop_level: active_stop_level,
           level: active_level
         } do
      {:ok, _} = Gtfs.update_stop_level_diagram(active_stop_level, "map-diagram.png")

      # Active-level child stop that DOES carry a diagram_coordinate (plus lat/lon).
      # This is the new payload field; it must not perturb the other-level shape.
      _active_diagram_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ISO_ACTIVE",
          stop_name: "Isolation Active",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: active_level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
          stop_lat: Decimal.new("40.7100"),
          stop_lon: Decimal.new("-74.0100")
        })

      # Other level with a complete saved floorplan alignment and one geo-coded stop.
      other_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "iso_other",
          level_name: "Isolation Other",
          level_index: 1.0
        })

      {:ok, other_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: other_level.id
        })

      {:ok, _} =
        Gtfs.update_stop_level_alignment(other_stop_level, %{
          floorplan_center_lat: 41.5,
          floorplan_center_lon: -72.5,
          floorplan_scale_mpp: 0.42,
          floorplan_rotation_deg: 12.0
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(other_stop_level, "iso-other.png")

      _other_geo_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ISO_OTHER_STOP",
          stop_name: "Isolation Other Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: other_level.level_id,
          stop_lat: Decimal.new("41.5005"),
          stop_lon: Decimal.new("-72.5005")
        })

      _other_diagram_only_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ISO_OTHER_DIAGRAM_ONLY",
          stop_name: "Isolation Other Diagram Only",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: other_level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 20.0},
          stop_lat: nil,
          stop_lon: nil
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      # Sanity: the active payload now carries diagram_coordinate.
      assert_push_event(view, "set_active_child_stops", %{stops: active_stops})
      active_marker = Enum.find(active_stops, &(&1.stop_id == "ISO_ACTIVE"))
      assert active_marker.diagram_coordinate == %{x: 50.0, y: 40.0}

      # Drain the mount-time set_other_levels push (empty levels) before toggling.
      assert_push_event(view, "set_other_levels", %{levels: _mount_levels})

      # Turn on the other level's floorplan and stops so it appears in the payload.
      # Each toggle re-pushes set_other_levels; the stops toggle is the final state
      # that carries both the floorplan and the stop marker.
      render_click(element(view, floorplan_selector(other_level.id)))
      assert_push_event(view, "set_other_levels", %{levels: _fp_levels})

      render_click(element(view, stops_selector(other_level.id)))
      assert_push_event(view, "set_other_levels", %{levels: levels})

      other = Enum.find(levels, &(&1.level_id == other_level.id))
      assert other != nil

      # Level wrapper keeps its stable shape: id, color, floorplan, stops.
      assert Map.keys(other) |> Enum.sort() ==
               [:color, :floorplan, :level_id, :level_index, :stops]

      # Other-level floorplan alignment reflects the SAVED stop_level columns,
      # not any active floorplan transform.
      assert other.floorplan.center_lat == 41.5
      assert other.floorplan.center_lon == -72.5
      assert other.floorplan.scale_mpp == 0.42
      assert other.floorplan.rotation_deg == 12.0

      # Other-level stop marker stays anchored to its stored geography.
      other_marker = Enum.find(other.stops, &(&1.stop_id == "ISO_OTHER_STOP"))
      assert other_marker != nil
      assert other_marker.lat == 41.5005
      assert other_marker.lon == -72.5005

      # Other-level overlays are geography-only; diagram-only stops belong to
      # the active floorplan preview where image-space positioning is available.
      refute Enum.find(other.stops, &(&1.stop_id == "ISO_OTHER_DIAGRAM_ONLY"))
    end

    test "map mode behavior is unaffected by keyboard editing paths (DSA Step 8 guard)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      other_level_id = aligned_other_level(organization, gtfs_version, station, "dsa8")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      # Map mode renders the map canvas, not the floorplan canvas
      assert has_element?(view, ".map-canvas #map-alignment-leaflet")

      # Other-level toggling still works
      render_click(element(view, floorplan_selector(other_level_id)))
      assert has_element?(view, "#other-levels-button .badge", "1")

      # Switch back to view mode, then verify map mode still activates
      render_hook(view, "switch_mode", %{"mode" => "view"})
      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, ".map-canvas #map-alignment-leaflet")

      # Badge state was reset on mode switch
      refute has_element?(view, "#other-levels-button .badge")

      # Map-mode canvas_click is still a no-op
      render_hook(view, "canvas_click", %{"x" => "100", "y" => "100"})
      refute has_element?(view, "#child-stop-drawer-overlay[data-open='true']")
    end
  end

  # ---------------------------------------------------------------------------
  # Package 09 part (d) step 3 — server-owned unsaved alignment state.
  #
  # `alignment_unsaved?` is set only by a current-generation
  # `alignment_transform_changed` carrying a truthy `unsaved` key (a payload
  # omitting the key is treated as dirty), and cleared by restore, a successful
  # save, and any level/mode/version reset. The hook never writes `disabled`
  # (INV-09D-3).
  # ---------------------------------------------------------------------------

  describe "StationDiagramLive - unsaved alignment state" do
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
          stop_id: "UNSAVED_STATION",
          stop_name: "Unsaved Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "unsaved_level",
          level_name: "Unsaved Level",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "unsaved-diagram.png")

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        stop_level: stop_level
      }
    end

    defp mount_map_align(%{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         }) do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      view
    end

    defp transform_changed(view, params),
      do: map_event(view, "alignment_transform_changed", params)

    test "a freshly mounted align surface shows no unsaved indicator and disables restore",
         context do
      view = mount_map_align(context)

      refute has_element?(view, "#map-alignment-unsaved")
      assert has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "a transform change with unsaved true shows the indicator and enables restore",
         context do
      view = mount_map_align(context)

      transform_changed(view, %{"unsaved" => true})

      assert has_element?(view, "#map-alignment-unsaved", "Unsaved alignment changes")
      refute has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "a transform change omitting the unsaved key is treated as unsaved", context do
      view = mount_map_align(context)

      transform_changed(view, %{})

      assert has_element?(view, "#map-alignment-unsaved")
      refute has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "a transform change with unsaved false leaves a clean surface clean", context do
      view = mount_map_align(context)

      transform_changed(view, %{"unsaved" => false})

      refute has_element?(view, "#map-alignment-unsaved")
      assert has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "a transform change with unsaved false does not clear an already unsaved surface",
         context do
      view = mount_map_align(context)
      transform_changed(view, %{"unsaved" => true})

      transform_changed(view, %{"unsaved" => false})

      assert has_element?(view, "#map-alignment-unsaved")
      refute has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "a stale-generation transform change does not mark the surface unsaved", context do
      view = mount_map_align(context)

      render_hook(view, "alignment_transform_changed", %{
        "generation" => "stale-generation",
        "unsaved" => true
      })

      refute has_element?(view, "#map-alignment-unsaved")
      assert has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "a transform change without a generation does not mark the surface unsaved", context do
      view = mount_map_align(context)

      render_hook(view, "alignment_transform_changed", %{"unsaved" => true})

      refute has_element?(view, "#map-alignment-unsaved")
      assert has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "restoring the saved alignment clears the unsaved state", context do
      view = mount_map_align(context)
      transform_changed(view, %{"unsaved" => true})

      render_hook(view, "restore_saved_alignment", %{})

      refute has_element?(view, "#map-alignment-unsaved")
      assert has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "a successful save clears the unsaved state", context do
      view = mount_map_align(context)
      transform_changed(view, %{"unsaved" => true})

      map_event(view, "save_alignment", %{
        "center_lat" => 40.7128,
        "center_lon" => -74.0060,
        "scale_mpp" => 0.35,
        "rotation_deg" => 15.5
      })

      refute has_element?(view, "#map-alignment-unsaved")
      assert has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "a rejected save leaves the surface unsaved", context do
      view = mount_map_align(context)
      transform_changed(view, %{"unsaved" => true})

      html =
        map_event(view, "save_alignment", %{
          "center_lat" => 200,
          "center_lon" => 0,
          "scale_mpp" => 0.5,
          "rotation_deg" => 0
        })

      assert html =~ "Could not save alignment"
      assert has_element?(view, "#map-alignment-unsaved")
      refute has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "leaving and re-entering align mode clears the unsaved state", context do
      view = mount_map_align(context)
      transform_changed(view, %{"unsaved" => true})

      render_hook(view, "switch_mode", %{"mode" => "view"})
      render_hook(view, "switch_mode", %{"mode" => "map"})

      refute has_element?(view, "#map-alignment-unsaved")
      assert has_element?(view, "#map-alignment-restore-saved[disabled]")
    end
  end

  # ---------------------------------------------------------------------------
  # Package 08 step 3 — server coordinate-review contract.
  #
  # These cases drive the four LiveView events (`open_coordinate_review`,
  # `cancel_coordinate_review`, `apply_coordinate_review`,
  # `alignment_transform_changed`) directly through the authenticated route.
  # Step 4 cut the hook and template over to these events and removed the
  # legacy inline preview + typed-phrase apply flow in the same commit.
  # ---------------------------------------------------------------------------

  describe "StationDiagramLive - coordinate review contract (step 3)" do
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
          stop_id: "REVIEW_STATION",
          stop_name: "Review Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "review_level",
          level_name: "Review Level",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "review-diagram.png")

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level,
        stop_level: stop_level
      }
    end

    defp cancel_coordinate_review(view),
      do: render_hook(view, "cancel_coordinate_review", %{})

    defp alignment_transform_changed(view),
      do: map_event(view, "alignment_transform_changed", %{})

    defp use_reviewed_apply_transaction_mock do
      Application.put_env(
        :gtfs_planner,
        :reviewed_apply_transaction,
        ReviewedApplyTransactionMock
      )
    end

    defp assigns(view) do
      :sys.get_state(view.pid).socket.assigns
    end

    test "save_alignment persists only the active StopLevel transform and leaves child stop_lat/lon byte-for-byte unchanged (INV-5, AC-4)",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: stop_level
         } do
      child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "INV5_CHILD",
          stop_name: "INV5 Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
          stop_lat: Decimal.new("1.500000"),
          stop_lon: Decimal.new("-1.500000")
        })

      original_lat = child.stop_lat
      original_lon = child.stop_lon

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      map_event(view, "save_alignment", %{
        "center_lat" => 40.7128,
        "center_lon" => -74.006,
        "scale_mpp" => 0.35,
        "rotation_deg" => 12.0
      })

      reloaded_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert_in_delta reloaded_level.floorplan_center_lat, 40.7128, 1.0e-6
      assert_in_delta reloaded_level.floorplan_center_lon, -74.006, 1.0e-6
      assert_in_delta reloaded_level.floorplan_scale_mpp, 0.35, 1.0e-6
      assert_in_delta reloaded_level.floorplan_rotation_deg, 12.0, 1.0e-6

      reloaded_child = Repo.get!(GtfsPlanner.Gtfs.Stop, child.id)
      assert reloaded_child.stop_lat == original_lat
      assert reloaded_child.stop_lon == original_lon

      assert Gtfs.list_change_logs_for_entity(
               organization.id,
               gtfs_version.id,
               "stop",
               child.id
             ) == []
    end

    test "open_coordinate_review stores the normalized review transform and the server fingerprint together (DC-1, AC-5)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           user: user,
           conn: conn
         } do
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "REVIEW_CHILD",
        stop_name: "Review Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      open_coordinate_review(view, %{
        "center_lat" => 40.7128,
        "center_lon" => -74.006,
        "scale_mpp" => 0.35,
        "rotation_deg" => 0.0
      })

      stored = assigns(view)

      assert %{
               floorplan_center_lat: 40.7128,
               floorplan_center_lon: -74.006,
               floorplan_scale_mpp: 0.35,
               floorplan_rotation_deg: +0.0
             } = stored.review_transform

      assert %{
               changes: [_ | _],
               fingerprint: fingerprint,
               generation: generation,
               stop_level_id: stop_level_id
             } = stored.coordinate_review

      assert byte_size(fingerprint) == 64
      assert generation == stored.map_generation
      assert stop_level_id == stored.active_stop_level.id

      # The fingerprint is exactly what Package 06 returned; the LiveView does
      # not re-derive it (INV-3, DC-1).
      assert {:ok, projected} =
               Gtfs.preview_stop_level_alignment(
                 stop_level_id,
                 stored.review_transform,
                 1024,
                 768
               )

      assert projected.fingerprint == fingerprint
    end

    test "open_coordinate_review with no changes clears review state and announces the no-change outcome (AC-5 empty)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: stop_level,
           user: user,
           conn: conn
         } do
      # Pre-save the exact alignment we will ask Package 06 to preview so every
      # eligible child stop already matches and the projection yields changes: [].
      {:ok, _} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.35,
          floorplan_rotation_deg: 0.0
        })

      # Place a child stop whose stored lat/lon already equals what Package 06
      # would derive for the saved alignment (changes == []).
      proposed_sl =
        StopLevel.alignment_changeset(
          stop_level,
          %{
            floorplan_center_lat: 40.7128,
            floorplan_center_lon: -74.006,
            floorplan_scale_mpp: 0.35,
            floorplan_rotation_deg: 0.0
          }
        )
        |> Ecto.Changeset.apply_action!(:update)

      {:ok, alignment} = StopLevel.alignment_transform(proposed_sl)

      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(
          alignment,
          1024,
          768,
          %{x: 50, y: 40}
        )

      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "NOOP_CHILD",
        stop_name: "Noop Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
        stop_lat: Decimal.from_float(lat),
        stop_lon: Decimal.from_float(lon)
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      open_coordinate_review(view)

      stored = assigns(view)
      assert stored.coordinate_review == nil
      assert stored.review_transform == nil
      assert stored.coordinate_review_status == "No coordinate changes to review."
    end

    test "open_coordinate_review ignores a stale generation (cross-step-contract)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           user: user,
           conn: conn
         } do
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "STALE_GEN_CHILD",
        stop_name: "Stale Gen Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      render_hook(view, "open_coordinate_review", %{
        "generation" => Ecto.UUID.generate(),
        "center_lat" => 40.7128,
        "center_lon" => -74.006,
        "scale_mpp" => 0.35,
        "rotation_deg" => 0.0
      })

      stored = assigns(view)
      assert stored.coordinate_review == nil
      assert stored.review_transform == nil
    end

    test "apply_coordinate_review no-ops when no review is current (cancellation contract)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           user: user,
           conn: conn,
           stop_level: stop_level
         } do
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "NOOP_APPLY_CHILD",
        stop_name: "Noop Apply Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      original_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      apply_coordinate_review(view)

      stored = assigns(view)
      assert stored.coordinate_review == nil

      unchanged_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert unchanged_level.floorplan_center_lat == original_level.floorplan_center_lat
    end

    test "apply_coordinate_review through the real Repo adapter commits, flashes updated_stop_count, and writes one actor-attributed ChangeLog per changed stop (AC-6, AC-11, INV-6)",
         %{} do
      # The production-adapter case must follow reviewed_apply_transaction_repo_test.exs:
      # run against the real test PostgreSQL boundary with ReviewedApplyTransaction.Repo
      # and SQL Sandbox unboxed ownership, so the SET TRANSACTION ISOLATION LEVEL
      # SERIALIZABLE wrapper inside the adapter executes outside a sandbox outer
      # transaction. Fixtures, including the user, are created inside the unboxed
      # block so log_in_user can write a session token the unboxed connection sees.
      Application.put_env(
        :gtfs_planner,
        :reviewed_apply_transaction,
        ReviewedApplyTransaction.Repo
      )

      # Reset the shared sandbox so the test process can check out an unboxed
      # connection. ConnCase.setup_sandbox already registered an on_exit that
      # stops the original owner; the mode reset releases its shared lock.
      Sandbox.mode(Repo, :manual)

      Sandbox.unboxed_run(Repo, fn ->
        organization =
          organization_fixture(%{
            alias: "review-#{Ecto.UUID.generate()}",
            name: "Review Adapter Org"
          })

        try do
          gtfs_version = gtfs_version_fixture(organization.id)

          user =
            user_fixture(%{
              email: "review-adapter-#{Ecto.UUID.generate()}@example.com"
            })

          Accounts.create_user_org_membership(%{
            user_id: user.id,
            organization_id: organization.id,
            roles: ["pathways_studio_editor"]
          })

          station =
            stop_fixture(organization.id, gtfs_version.id, %{
              stop_id: "REVIEW_ADAPTER_STATION",
              stop_name: "Review Adapter Station",
              location_type: 1
            })

          level =
            level_fixture(organization.id, gtfs_version.id, %{
              level_id: "review_adapter_level",
              level_name: "Review Adapter Level",
              level_index: 0.0
            })

          {:ok, stop_level} =
            Gtfs.create_stop_level(%{
              organization_id: organization.id,
              gtfs_version_id: gtfs_version.id,
              stop_id: station.id,
              level_id: level.id
            })

          {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "review-adapter.png")

          child_a =
            stop_fixture(organization.id, gtfs_version.id, %{
              stop_id: "ADAPTER_CHILD_A",
              stop_name: "Adapter Child A",
              location_type: 0,
              parent_station: station.stop_id,
              level_id: level.level_id,
              diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
              stop_lat: Decimal.new("1.0"),
              stop_lon: Decimal.new("2.0")
            })

          child_b =
            stop_fixture(organization.id, gtfs_version.id, %{
              stop_id: "ADAPTER_CHILD_B",
              stop_name: "Adapter Child B",
              location_type: 0,
              parent_station: station.stop_id,
              level_id: level.level_id,
              diagram_coordinate: %{"x" => 70.0, "y" => 30.0},
              stop_lat: Decimal.new("3.0"),
              stop_lon: Decimal.new("4.0")
            })

          conn =
            build_conn()
            |> Plug.Conn.put_private(:phoenix_endpoint, GtfsPlannerWeb.Endpoint)
            |> log_in_user(user, organization: organization)

          {:ok, view, _html} =
            live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram",
              on_error: :warn
            )

          # The LiveView process spawns unlinked to the test process. Allow it to
          # share the test's unboxed connection so the SERIALIZABLE wrapper can run.
          Sandbox.allow(Repo, self(), view.pid)

          render_hook(view, "switch_mode", %{"mode" => "map"})
          set_image_natural_size(view, 1024, 768)
          generation = map_generation(view)

          assert_push_event(view, "set_active_child_stops", %{stops: _})

          open_coordinate_review(view)

          html = apply_coordinate_review(view)

          # The success flash carries the count read from the nested
          # apply_result.updated_stop_count (NOT touched_stop_count).
          assert html =~ "Updated coordinates for 2 stops"

          stored = assigns(view)
          assert stored.coordinate_review == nil
          assert stored.review_transform == nil
          assert stored.active_stop_level.id == stop_level.id
          assert_in_delta stored.active_stop_level.floorplan_center_lat, 40.7128, 1.0e-6

          # Restore-saved must use the transform committed by the reviewed apply.
          assert_push_event(view, "alignment_saved", %{
            generation: ^generation,
            center_lat: center_lat,
            center_lon: center_lon,
            scale_mpp: scale_mpp,
            rotation_deg: rotation_deg
          })

          assert_in_delta center_lat, 40.7128, 1.0e-6
          assert_in_delta center_lon, -74.006, 1.0e-6
          assert_in_delta scale_mpp, 0.35, 1.0e-6
          assert_in_delta rotation_deg, 0.0, 1.0e-6

          # Active markers are re-pushed so pins reflect the persisted geography.
          assert_push_event(view, "set_active_child_stops", %{stops: [_ | _]})

          reloaded_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
          assert_in_delta reloaded_level.floorplan_center_lat, 40.7128, 1.0e-6
          assert_in_delta reloaded_level.floorplan_center_lon, -74.006, 1.0e-6

          for child <- [child_a, child_b] do
            reloaded_child = Repo.get!(GtfsPlanner.Gtfs.Stop, child.id)
            assert_in_delta Decimal.to_float(reloaded_child.stop_lat), 40.7128, 1.0e-3
            assert_in_delta Decimal.to_float(reloaded_child.stop_lon), -74.006, 1.0e-3
          end

          # Package 06 owns the per-changed-stop ChangeLog writes inside the apply
          # transaction. The LiveView passes the mounted AuditContext unchanged;
          # every log is attributed from the session, not forged by the LiveView.
          for child <- [child_a, child_b] do
            logs =
              Gtfs.list_change_logs_for_entity(organization.id, gtfs_version.id, "stop", child.id)

            assert length(logs) == 1
            log = hd(logs)
            assert log.action == "updated"
            assert log.actor_id == user.id
            assert log.actor_email == user.email
            assert log.station_stop_id == station.stop_id
          end
        after
          delete_review_adapter_fixtures!(organization.id)
        end
      end)
    end

    test "apply_coordinate_review on a stale fingerprint clears the review with retry copy and performs no stop or history writes (AC-7, DC-2)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           user: user,
           conn: conn
         } do
      # The default ReviewedApplyTransaction.Sandbox adapter is sufficient here:
      # the fingerprint recheck fires in any adapter because it is part of the
      # apply projection under FOR UPDATE. We do not need the SERIALIZABLE
      # wrapper to assert stale rejection (DC-2).

      child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STALE_FP_CHILD",
          stop_name: "Stale Fp Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
          stop_lat: Decimal.new("1.0"),
          stop_lon: Decimal.new("2.0")
        })

      original_lat = child.stop_lat
      original_lon = child.stop_lon

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      open_coordinate_review(view)

      # Mutate the eligible-stops population after opening the review so Package
      # 06's fingerprint recheck under FOR UPDATE returns :stale_review. This is
      # the real correctness boundary (DC-2): the server fence fires regardless
      # of the LiveView's stored review state.
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "STALE_FP_NEW_CHILD",
        stop_name: "Stale Fp New Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 90.0, "y" => 20.0},
        stop_lat: Decimal.new("5.0"),
        stop_lon: Decimal.new("6.0")
      })

      apply_coordinate_review(view)

      stored = assigns(view)
      assert stored.coordinate_review == nil
      assert stored.review_transform == nil

      assert stored.coordinate_review_status ==
               "The station changed. Review the coordinate changes again."

      reloaded_child = Repo.get!(GtfsPlanner.Gtfs.Stop, child.id)
      assert reloaded_child.stop_lat == original_lat
      assert reloaded_child.stop_lon == original_lon

      assert Gtfs.list_change_logs_for_entity(
               organization.id,
               gtfs_version.id,
               "stop",
               child.id
             ) == []
    end

    test "apply_coordinate_review on an exhausted serialization retry clears the review with retry copy and performs no writes (AC-7, AC-10)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: _stop_level,
           user: user,
           conn: conn
         } do
      set_mox_global()

      child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BUSY_CHILD",
          stop_name: "Busy Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
          stop_lat: Decimal.new("1.0"),
          stop_lon: Decimal.new("2.0")
        })

      original_lat = child.stop_lat
      original_lon = child.stop_lon

      use_reviewed_apply_transaction_mock()

      # Three serialization failures in a row collapse to {:error, :busy}.
      expect(ReviewedApplyTransactionMock, :run, 3, fn _transaction ->
        raise postgrex_serialization_error()
      end)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      open_coordinate_review(view)
      apply_coordinate_review(view)

      stored = assigns(view)
      assert stored.coordinate_review == nil
      assert stored.review_transform == nil

      assert stored.coordinate_review_status ==
               "The coordinate update is busy. Review the coordinate changes again."

      reloaded_child = Repo.get!(GtfsPlanner.Gtfs.Stop, child.id)
      assert reloaded_child.stop_lat == original_lat
      assert reloaded_child.stop_lon == original_lon

      assert Gtfs.list_change_logs_for_entity(
               organization.id,
               gtfs_version.id,
               "stop",
               child.id
             ) == []
    end

    test "apply_coordinate_review on a recoverable non-stale error preserves the review rows and fingerprint for retry (AC-8)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: _stop_level,
           user: user,
           conn: conn
         } do
      set_mox_global()

      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "RECOVERABLE_CHILD",
        stop_name: "Recoverable Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, fn _transaction ->
        {:error, :recoverable_test_error}
      end)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      open_coordinate_review(view)

      before_apply = assigns(view)
      fingerprint_before = before_apply.coordinate_review.fingerprint
      transform_before = before_apply.review_transform

      apply_coordinate_review(view)

      stored = assigns(view)
      # Recoverable: review rows and fingerprint preserved so a later apply can
      # reuse the same projection. Only the recovery error assign is set.
      assert stored.coordinate_review != nil
      assert stored.coordinate_review.fingerprint == fingerprint_before
      assert stored.review_transform == transform_before
      assert stored.coordinate_review_error != nil
      assert stored.coordinate_review_status == nil
    end

    test "cancel_coordinate_review clears review state with no writes and no transform mutation (AC-14)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: stop_level,
           user: user,
           conn: conn
         } do
      child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CANCEL_CHILD",
          stop_name: "Cancel Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
          stop_lat: Decimal.new("1.0"),
          stop_lon: Decimal.new("2.0")
        })

      original_lat = child.stop_lat
      original_lon = child.stop_lon

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      open_coordinate_review(view)

      cancel_coordinate_review(view)

      stored = assigns(view)
      assert stored.coordinate_review == nil
      assert stored.review_transform == nil
      assert stored.coordinate_review_error == nil
      assert stored.coordinate_review_status == nil

      # A subsequent transform-only save persists the params (AC-14 second leg).
      map_event(view, "save_alignment", %{
        "center_lat" => 41.0,
        "center_lon" => -73.0,
        "scale_mpp" => 0.5,
        "rotation_deg" => 5.0
      })

      reloaded_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert_in_delta reloaded_level.floorplan_center_lat, 41.0, 1.0e-6
      assert_in_delta reloaded_level.floorplan_center_lon, -73.0, 1.0e-6

      reloaded_child = Repo.get!(GtfsPlanner.Gtfs.Stop, child.id)
      assert reloaded_child.stop_lat == original_lat
      assert reloaded_child.stop_lon == original_lon
    end

    test "alignment_transform_changed clears an open review and announces the re-review prompt (AC-9, INV-4)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           user: user,
           conn: conn
         } do
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "INVALIDATE_CHILD",
        stop_name: "Invalidate Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
        stop_lat: Decimal.new("1.0"),
        stop_lon: Decimal.new("2.0")
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      open_coordinate_review(view)
      assert assigns(view).coordinate_review != nil

      alignment_transform_changed(view)

      stored = assigns(view)
      assert stored.coordinate_review == nil
      assert stored.review_transform == nil
      assert stored.coordinate_review_status == "The alignment changed — review again."

      # A queued apply after invalidation no-ops; client invalidation is advisory
      # and never the correctness fence (INV-4, DC-2).
      apply_coordinate_review(view)
      assert assigns(view).coordinate_review == nil
    end

    test "alignment_transform_changed is silent when no review is open", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      view =
        mount_map_review(%{
          conn: conn,
          user: user,
          organization: organization,
          gtfs_version: gtfs_version,
          station: station
        })

      alignment_transform_changed(view)

      stored = assigns(view)
      assert stored.coordinate_review == nil
      assert stored.review_transform == nil
      assert stored.coordinate_review_error == nil
      assert stored.coordinate_review_status == nil
      refute has_element?(view, "#coordinate-review-status")
    end

    test "a queued duplicate apply_coordinate_review in one LiveView no-ops after success (AC-10, idempotency, INV-2)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: _stop_level,
           user: user,
           conn: conn
         } do
      # The default Sandbox adapter suffices: the queued duplicate no-ops on the
      # cleared review state, which is adapter-independent (INV-2, AC-10).

      child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DUP_APPLY_CHILD",
          stop_name: "Dup Apply Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
          stop_lat: Decimal.new("1.0"),
          stop_lon: Decimal.new("2.0")
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      open_coordinate_review(view)
      apply_coordinate_review(view)

      # Successful apply clears the review; a queued second apply no-ops because
      # the stored review is nil. The LiveView process serializes the events.
      apply_coordinate_review(view)

      stored = assigns(view)
      assert stored.coordinate_review == nil

      # Only one ChangeLog set exists — the duplicate did not duplicate writes.
      logs =
        Gtfs.list_change_logs_for_entity(organization.id, gtfs_version.id, "stop", child.id)

      assert length(logs) == 1
    end

    test "two LiveViews sharing a fingerprint yield one history set, with the second apply rejected as stale (AC-10, DC-2, concurrency)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: _stop_level,
           user: user,
           conn: conn
         } do
      # The default Sandbox adapter suffices: the cross-LiveView stale rejection
      # is the Package 06 fingerprint recheck, which fires in any adapter. With
      # async: false, both LiveView processes share the sandbox owner so the
      # second tab observes the first tab's committed coordinate changes.
      child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "TWO_VIEW_CHILD",
          stop_name: "Two View Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 40.0},
          stop_lat: Decimal.new("1.0"),
          stop_lon: Decimal.new("2.0")
        })

      conn = log_in_user(conn, user, organization: organization)

      # Tab A opens first.
      {:ok, view_a, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view_a, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view_a, 1024, 768)
      open_coordinate_review(view_a)

      # Tab B opens the same projection against the same alignment and eligible
      # stops population.
      {:ok, view_b, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view_b, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view_b, 1024, 768)
      open_coordinate_review(view_b)

      fingerprint_a = assigns(view_a).coordinate_review.fingerprint
      fingerprint_b = assigns(view_b).coordinate_review.fingerprint
      assert fingerprint_a == fingerprint_b

      # Tab A applies first; its committed coordinate changes alter the
      # eligible_stops fingerprint payload, so tab B's stored fingerprint no
      # longer matches the post-apply projection.
      apply_coordinate_review(view_a)

      apply_coordinate_review(view_b)

      stored_b = assigns(view_b)
      assert stored_b.coordinate_review == nil
      assert stored_b.review_transform == nil

      assert stored_b.coordinate_review_status ==
               "The station changed. Review the coordinate changes again."

      # Exactly one history set exists for the changed stop; the second apply
      # was rejected under FOR UPDATE before any write (DC-2).
      logs =
        Gtfs.list_change_logs_for_entity(organization.id, gtfs_version.id, "stop", child.id)

      assert length(logs) == 1
    end

    test "the retired inline preview, APPLY phrase form, coordinate_preview state, and legacy apply events are absent (INV-2, AC-15)",
         %{
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: _stop_level,
           user: user,
           conn: conn
         } do
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "RETIRED_ABSENT_CHILD",
        stop_name: "Retired Absent Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)

      html = open_coordinate_review(view)

      # The evidence-first review dialog is the sole coordinate surface.
      assert has_element?(view, "#coordinate-review-dialog")
      assert has_element?(view, "#coordinate-review-table")
      assert has_element?(view, "#coordinate-review-dialog-cancel")
      assert has_element?(view, "#coordinate-review-dialog-confirm")

      # The retired inline preview, typed-phrase form, and confirmation controls
      # are gone (AC-15, INV-2).
      refute has_element?(view, "#coordinate-preview")
      refute has_element?(view, "#coordinate-preview-confirmation")
      refute has_element?(view, "#coordinate-preview-confirmation-form")
      refute has_element?(view, "#confirm-coordinate-preview")
      refute has_element?(view, "#apply-coordinate-preview")
      refute has_element?(view, "#cancel-coordinate-preview")

      # The trigger carries no change count and uses the review vocabulary.
      assert has_element?(view, "#map-alignment-apply", "Review coordinate changes")
      refute html =~ "Preview coordinate changes"
    end
  end

  # ---------------------------------------------------------------------------
  # Package 08 step 4 — evidence-first review dialog cutover.
  #
  # These cases verify the rendered projection, reconciled counts, copy
  # obligations, focusable recovery, and the advisory invalidation through the
  # real authenticated route and the step-3 server contract.
  # ---------------------------------------------------------------------------

  describe "StationDiagramLive - coordinate review dialog (step 4)" do
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
          stop_id: "DIALOG_STATION",
          stop_name: "Dialog Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "dialog_level",
          level_name: "Dialog Level",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "dialog-diagram.png")

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level,
        stop_level: stop_level
      }
    end

    defp mount_map_review(context) do
      %{
        conn: conn,
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      } = context

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1024, 768)
      view
    end

    test "pre-review surface reports placement vocabulary and a count-free trigger (DC-4, INV-7)",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      # Two placed (normalizable diagram_coordinate), one unplaced (nil).
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "DIALOG_PLACED_A",
        stop_name: "Placed A",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 10.0, "y" => 20.0}
      })

      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "DIALOG_PLACED_B",
        stop_name: "Placed B",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 30.0, "y" => 40.0}
      })

      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "DIALOG_UNPLACED",
        stop_name: "Unplaced",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: nil
      })

      view =
        mount_map_review(%{
          conn: conn,
          user: user,
          organization: organization,
          gtfs_version: gtfs_version,
          station: station
        })

      html = render(view)

      # Placement vocabulary only; the lagging "have lat/long" copy is gone.
      assert has_element?(
               view,
               "[data-role='child-stop-coverage']",
               "2 of 3 stops have floorplan placements · 1 without placement stay unchanged"
             )

      refute html =~ "child stops have lat/long"

      # The trigger carries no change count.
      assert has_element?(view, "#map-alignment-apply", "Review coordinate changes")
    end

    test "dialog renders every projected change row with six-decimal coordinates and reconciled counts (AC-5, AC-13, DC-8, INV-7)",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: stop_level
         } do
      # Persist a baseline alignment so the projection has a known reference.
      {:ok, _} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.5,
          floorplan_rotation_deg: 0.0
        })

      changed =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DIALOG_CHANGED",
          stop_name: "Changed",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0},
          stop_lat: Decimal.new("40.700000"),
          stop_lon: Decimal.new("-74.000000")
        })

      view =
        mount_map_review(%{
          conn: conn,
          user: user,
          organization: organization,
          gtfs_version: gtfs_version,
          station: station
        })

      # A different transform guarantees a coordinate change for the placed stop.
      html =
        open_coordinate_review(view, %{
          "center_lat" => 40.7128,
          "center_lon" => -74.006,
          "scale_mpp" => 0.35,
          "rotation_deg" => 0.0
        })

      assert has_element?(view, "#coordinate-review-dialog")
      assert has_element?(view, "#coordinate-review-row-#{changed.id}")
      assert has_element?(view, "#coordinate-review-table-scroller.overflow-x-auto")
      assert has_element?(view, "#coordinate-review-table thead th:nth-child(2).text-right")
      assert has_element?(view, "#coordinate-review-table thead th:nth-child(3).text-right")
      assert has_element?(view, "#coordinate-review-table tbody td:nth-child(2).text-right")
      assert has_element?(view, "#coordinate-review-table tbody td:nth-child(3).text-right")

      # Title and confirm button carry the change count from one projection.
      assert html =~ "Update coordinates for 1 stop?"
      assert has_element?(view, "#coordinate-review-dialog-confirm", "Update 1 stop")

      # Count identities: placed = changed + unchanged; total = placed + unplaced.
      review = :sys.get_state(view.pid).socket.assigns.coordinate_review
      changed_count = length(review.changes)
      assert changed_count == 1

      stored = assigns(view)

      assert stored.child_stops_with_floorplan ==
               changed_count + review.unchanged_count

      assert stored.child_stops_total ==
               stored.child_stops_with_floorplan + review.unplaced_count

      assert has_element?(
               view,
               "[data-role='child-stop-coverage']",
               "#{stored.child_stops_with_floorplan} of #{stored.child_stops_total} stops have floorplan placements · #{review.unplaced_count} without placement stay unchanged"
             )

      # The consequence names the changed group; recovery copy is truthful (DC-5).
      assert html =~ "cannot be reverted as one batch"
      refute html =~ "undo this update"

      # Coordinates render at exactly six decimals (DC-8). The current Decimal
      # value and the proposed float both project to six-place strings.
      row_html =
        element(view, "#coordinate-review-row-#{changed.id}")
        |> render()

      assert Regex.match?(~r/\d+\.\d{6}, \-?\d+\.\d{6}/, row_html)
    end

    test "dialog omits zero-count consequence clauses", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    } do
      {:ok, _} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.5,
          floorplan_rotation_deg: 0.0
        })

      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "DIALOG_ZERO_UNCHANGED",
        stop_name: "Zero Unchanged",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 50.0},
        stop_lat: Decimal.new("40.700000"),
        stop_lon: Decimal.new("-74.000000")
      })

      view =
        mount_map_review(%{
          conn: conn,
          user: user,
          organization: organization,
          gtfs_version: gtfs_version,
          station: station
        })

      html =
        open_coordinate_review(view, %{
          "center_lat" => 40.7128,
          "center_lon" => -74.006,
          "scale_mpp" => 0.35,
          "rotation_deg" => 0.0
        })

      # With one changed stop and zero unchanged on the active level, the
      # "already match" clause must not appear.
      assert html =~ "1 stop will receive new coordinates"
      refute html =~ "0 already match"
    end

    test "cancel writes nothing and a subsequent save_alignment persists (AC-14, INV-5)",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: stop_level
         } do
      {:ok, _} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.5,
          floorplan_rotation_deg: 0.0
        })

      child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DIALOG_CANCEL_CHILD",
          stop_name: "Cancel Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0},
          stop_lat: Decimal.new("40.700000"),
          stop_lon: Decimal.new("-74.000000")
        })

      original_lat = child.stop_lat
      original_lon = child.stop_lon

      view =
        mount_map_review(%{
          conn: conn,
          user: user,
          organization: organization,
          gtfs_version: gtfs_version,
          station: station
        })

      open_coordinate_review(view, %{
        "center_lat" => 40.7128,
        "center_lon" => -74.006,
        "scale_mpp" => 0.35,
        "rotation_deg" => 0.0
      })

      assert has_element?(view, "#coordinate-review-dialog")
      cancel_coordinate_review(view)
      refute has_element?(view, "#coordinate-review-dialog")

      # Cancel wrote nothing.
      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, child.id)
      assert reloaded.stop_lat == original_lat
      assert reloaded.stop_lon == original_lon

      # A subsequent transform-only save persists without touching coordinates.
      map_event(view, "save_alignment", %{
        "center_lat" => 40.72,
        "center_lon" => -74.01,
        "scale_mpp" => 0.4,
        "rotation_deg" => 5.0
      })

      reloaded_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert_in_delta reloaded_level.floorplan_scale_mpp, 0.4, 1.0e-6

      reloaded_after = Repo.get!(GtfsPlanner.Gtfs.Stop, child.id)
      assert reloaded_after.stop_lat == original_lat
      assert reloaded_after.stop_lon == original_lon
    end

    test "transform invalidation closes the review and announces review-again status (AC-9, INV-4)",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: stop_level
         } do
      {:ok, _} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.5,
          floorplan_rotation_deg: 0.0
        })

      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "DIALOG_INVALIDATE_CHILD",
        stop_name: "Invalidate Child",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50.0, "y" => 50.0},
        stop_lat: Decimal.new("40.700000"),
        stop_lon: Decimal.new("-74.000000")
      })

      view =
        mount_map_review(%{
          conn: conn,
          user: user,
          organization: organization,
          gtfs_version: gtfs_version,
          station: station
        })

      open_coordinate_review(view, %{
        "center_lat" => 40.7128,
        "center_lon" => -74.006,
        "scale_mpp" => 0.35,
        "rotation_deg" => 0.0
      })

      assert has_element?(view, "#coordinate-review-dialog")

      html = alignment_transform_changed(view)

      refute has_element?(view, "#coordinate-review-dialog")

      assert has_element?(
               view,
               "#coordinate-review-status",
               "The alignment changed — review again."
             )

      # Advisory only: the status is the sole observable, not a write guarantee.
      assert html =~ "review again"
    end

    test "no-change review announces the empty status and renders no dialog (AC-5)",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: stop_level
         } do
      {:ok, _} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.5,
          floorplan_rotation_deg: 0.0
        })

      # No placed (eligible) child stops on the level → the projection is empty.
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "DIALOG_NOCHANGE_UNPLACED",
        stop_name: "No Change Unplaced",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: nil
      })

      view =
        mount_map_review(%{
          conn: conn,
          user: user,
          organization: organization,
          gtfs_version: gtfs_version,
          station: station
        })

      html = open_coordinate_review(view)

      refute has_element?(view, "#coordinate-review-dialog")
      assert has_element?(view, "#coordinate-review-status", "No coordinate changes to review.")
      assert html =~ "No coordinate changes to review"

      render_hook(view, "alignment_transform_changed", %{"generation" => "stale-generation"})

      assert has_element?(view, "#coordinate-review-status", "No coordinate changes to review.")

      html = alignment_transform_changed(view)
      stored = assigns(view)

      assert stored.coordinate_review == nil
      assert stored.review_transform == nil
      assert stored.coordinate_review_error == nil
      assert stored.coordinate_review_status == nil
      refute has_element?(view, "#coordinate-review-status")
      refute html =~ "No coordinate changes to review."
      refute html =~ "The alignment changed — review again."
    end
  end

  describe "StationDiagramLive - align workspace anchor" do
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
          stop_id: "WORKSPACE_STATION",
          stop_name: "Workspace Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "workspace_level",
          level_name: "Workspace Level",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "workspace-diagram.png")

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        stop_level: stop_level
      }
    end

    test "align mode renders exactly one workspace element", context do
      view = mount_map_align(context)

      workspaces =
        view
        |> parsed_document()
        |> LazyHTML.query("#map-alignment-workspace")
        |> Enum.count()

      assert workspaces == 1
    end

    test "the workspace wraps the ignored map canvas rather than sitting inside it", context do
      view = mount_map_align(context)

      assert has_element?(
               view,
               "#map-alignment-workspace [phx-hook='MapAlignment'][phx-update='ignore']"
             )

      refute has_element?(view, "[phx-update='ignore'] #map-alignment-workspace")
    end
  end

  # Every align control that survives the part (e) rebuild, addressed the way a
  # consumer addresses it. Each must render exactly once.
  @preserved_align_selectors [
    "#map-alignment-workspace",
    "#map-alignment-tools",
    "#map-alignment-tools-toggle",
    "#map-alignment-commit-bar",
    "#map-alignment-lat-input",
    "#map-alignment-lon-input",
    "#map-alignment-apply-center",
    "#map-transform-left-fine",
    "#map-transform-up-fine",
    "#map-transform-down-fine",
    "#map-transform-right-fine",
    "#map-transform-rotate-left-fine",
    "#map-transform-rotate-right-fine",
    "#map-transform-scale-down-fine",
    "#map-transform-scale-up-fine",
    "#map-alignment-restore-saved",
    "#map-alignment-opacity",
    "#map-alignment-zoom",
    "#map-alignment-zoom-value",
    "[data-role='child-stop-coverage']",
    "#map-alignment-save-help",
    "#map-alignment-actions",
    "#map-alignment-preview-status",
    "#map-alignment-save",
    "#map-alignment-apply",
    "#map-alignment-preview-auto"
  ]

  # ---------------------------------------------------------------------------
  # Package 09 part (e) step 4 — the rebuilt Align layout.
  #
  # These cases pin the structural half of the Id and selector delta: the tools
  # panel floats over the map as a sibling of the ignored canvas, the five
  # bordered control groups are gone, and every control that lived in them still
  # renders exactly once in its new container.
  # ---------------------------------------------------------------------------

  describe "StationDiagramLive - align tools panel and commit bar" do
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
          stop_id: "REBUILD_STATION",
          stop_name: "Rebuild Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "rebuild_level",
          level_name: "Rebuild Level",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "rebuild-diagram.png")

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        stop_level: stop_level
      }
    end

    test "the tools panel floats inside the workspace and outside the ignored canvas", context do
      view = mount_map_align(context)

      assert has_element?(view, "#map-alignment-workspace #map-alignment-tools")
      refute has_element?(view, "[phx-update='ignore'] #map-alignment-tools")

      # The panel stays patchable so the server keeps owning `disabled`. The one
      # exception is the opacity slider: its value is client state, and a patch
      # that restored the rendered `value` would snap the thumb back to 70%
      # while the overlay kept the operator's setting. #map-alignment-zoom
      # carries the same protection for the same reason.
      assert ignored_ids_within(view, "#map-alignment-tools") == ["map-alignment-opacity"]
    end

    test "the five removed control groups no longer render", context do
      view = mount_map_align(context)

      refute has_element?(view, "#map-alignment-transform-controls")
      refute has_element?(view, "#map-alignment-assisted")

      for legend <- [
            "Map center",
            "Floorplan transform",
            "Assisted alignment",
            "Layers",
            "Save and apply"
          ] do
        refute has_element?(view, "fieldset > legend", legend)
      end
    end

    test "every preserved align control renders exactly once", context do
      view = mount_map_align(context)
      document = parsed_document(view)

      counts =
        Map.new(@preserved_align_selectors, fn selector ->
          {selector, document |> LazyHTML.query(selector) |> Enum.count()}
        end)

      assert counts == Map.new(@preserved_align_selectors, &{&1, 1})
    end

    test "the tools panel owns the frequent controls and the commit bar owns the rest",
         context do
      view = mount_map_align(context)

      for id <- [
            "map-transform-left-fine",
            "map-transform-up-fine",
            "map-transform-down-fine",
            "map-transform-right-fine",
            "map-transform-rotate-left-fine",
            "map-transform-rotate-right-fine",
            "map-transform-scale-down-fine",
            "map-transform-scale-up-fine",
            "map-alignment-restore-saved",
            "map-alignment-opacity",
            "map-alignment-tools-toggle"
          ] do
        assert has_element?(view, "#map-alignment-tools ##{id}")
      end

      for id <- [
            "map-alignment-save-help",
            "map-alignment-preview-auto",
            "map-alignment-actions",
            "map-alignment-save",
            "map-alignment-apply",
            "map-alignment-lat-input",
            "map-alignment-lon-input",
            "map-alignment-apply-center",
            "map-alignment-zoom",
            "map-alignment-zoom-value"
          ] do
        assert has_element?(view, "#map-alignment-commit-bar ##{id}")
      end

      assert has_element?(
               view,
               "#map-alignment-commit-bar [data-role='child-stop-coverage']"
             )
    end

    test "the map zoom slider keeps its ignore boundary on the input itself", context do
      view = mount_map_align(context)

      assert has_element?(view, "#map-alignment-zoom[phx-update='ignore']")
    end

    test "restore stays in the tools panel and follows the unsaved state", context do
      view = mount_map_align(context)

      assert has_element?(view, "#map-alignment-tools #map-alignment-restore-saved[disabled]")

      transform_changed(view, %{"unsaved" => true})

      assert has_element?(view, "#map-alignment-tools #map-alignment-restore-saved")
      refute has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "the other-levels opacity control joins the tools panel when its floorplan shows",
         context do
      %{organization: organization, gtfs_version: gtfs_version, station: station} = context
      other_level_id = aligned_other_level(organization, gtfs_version, station, "rebuild")
      view = mount_map_align(context)

      refute has_element?(view, "#map-other-overlays-opacity")

      render_click(element(view, floorplan_selector(other_level_id)))

      assert has_element?(view, "#map-alignment-tools #map-other-overlays-opacity")
    end

    test "the help overlay opens from its trigger and dismisses back to it", context do
      view = mount_map_align(context)

      # The overlay follows the popover idiom: hidden until asked for, dismissed
      # by Escape or a click away, and the dismiss returns focus to the trigger
      # only while the trigger reports itself open.
      assert has_element?(view, "#map-alignment-help-panel[phx-click-away]")
      assert has_element?(view, "#map-alignment-help-panel[phx-window-keydown][phx-key='escape']")
      assert has_element?(view, "#map-alignment-help-panel[role='dialog']")
      assert has_element?(view, "#map-alignment-help-trigger[phx-click]")
      assert has_element?(view, "#map-alignment-help-close[phx-click]")

      assert align_containers_of(view, ["#map-alignment-help-close"]) == %{
               "#map-alignment-help-close" => "map-alignment-help-panel"
             }
    end

    test "the help overlay is a sibling of the ignored canvas, not a child", context do
      view = mount_map_align(context)

      assert has_element?(view, "#map-alignment-workspace #map-alignment-help-panel")
      refute has_element?(view, "[phx-update='ignore'] #map-alignment-help-panel")
    end

    test "the help overlay names dragging, keyboard nudging, and hold-to-hide", context do
      view = mount_map_align(context)

      # The guidance moved off the commit bar and onto the surface it describes.
      # It renders hidden until the operator asks for it, so the copy is
      # asserted inside the panel rather than anywhere in the document.
      refute render(view) =~ "Drag to move the floorplan, or nudge it"

      help = element_text(view, "#map-alignment-help-panel")

      assert help =~ "Drag the floorplan"
      assert help =~ "arrow keys"
      assert help =~ "Hold H"
      assert help =~ "Restore saved alignment"

      assert has_element?(view, "#map-alignment-help-panel[style='display: none;']")
      assert has_element?(view, "#map-alignment-help-trigger[aria-expanded='false']")

      assert has_element?(
               view,
               "#map-alignment-help-trigger[aria-controls='map-alignment-help-panel']"
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Package 09 part (e) step 5 — the demoted Map center and Map zoom popovers.
  #
  # These cases pin the demotion half of the Id and selector delta: the five
  # rarely-used controls step 4 left inline in the commit bar now render only
  # inside their popover panels, the panels render hidden, and the triggers
  # carry the disclosure and dismissal wiring the level-picker precedent uses.
  # Dismissal and focus return need a real browser and belong to step 10.
  # ---------------------------------------------------------------------------

  describe "StationDiagramLive - align popovers" do
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
          stop_id: "POPOVER_STATION",
          stop_name: "Popover Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "popover_level",
          level_name: "Popover Level",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "popover-diagram.png")

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        stop_level: stop_level
      }
    end

    test "the coordinate controls render only inside the map center panel", context do
      view = mount_map_align(context)
      document = parsed_document(view)

      for id <- [
            "map-alignment-lat-input",
            "map-alignment-lon-input",
            "map-alignment-apply-center"
          ] do
        assert has_element?(view, "#map-alignment-center-panel ##{id}")

        assert document |> LazyHTML.query("##{id}") |> Enum.count() == 1,
               "#{id} renders more than once, so a copy survives outside the panel"
      end
    end

    test "the zoom controls render only inside the map zoom panel, keeping the ignore boundary",
         context do
      view = mount_map_align(context)
      document = parsed_document(view)

      for id <- ["map-alignment-zoom", "map-alignment-zoom-value"] do
        assert has_element?(view, "#map-alignment-zoom-panel ##{id}")

        assert document |> LazyHTML.query("##{id}") |> Enum.count() == 1,
               "#{id} renders more than once, so a copy survives outside the panel"
      end

      assert has_element?(
               view,
               "#map-alignment-zoom-panel #map-alignment-zoom[phx-update='ignore']"
             )

      refute has_element?(view, "#map-alignment-zoom-panel[phx-update='ignore']")
    end

    test "both panels render hidden with their triggers collapsed in the commit bar", context do
      view = mount_map_align(context)

      for {trigger, panel} <- [
            {"map-alignment-center-trigger", "map-alignment-center-panel"},
            {"map-alignment-zoom-trigger", "map-alignment-zoom-panel"}
          ] do
        assert has_element?(view, "#map-alignment-commit-bar ##{trigger}")
        assert has_element?(view, "#map-alignment-commit-bar ##{panel}")

        assert has_element?(
                 view,
                 "##{trigger}[aria-expanded='false'][aria-controls='#{panel}']"
               )

        assert has_element?(view, "##{panel}[style='display: none;']")
      end
    end

    test "each panel carries the click-away and escape dismissal wiring", context do
      view = mount_map_align(context)

      for panel <- ["map-alignment-center-panel", "map-alignment-zoom-panel"] do
        assert has_element?(view, "##{panel}[phx-click-away]")
        assert has_element?(view, "##{panel}[phx-window-keydown][phx-key='escape']")
      end

      for trigger <- ["map-alignment-center-trigger", "map-alignment-zoom-trigger"] do
        assert has_element?(view, "##{trigger}[phx-click]")
        assert has_element?(view, "##{trigger}[phx-keydown][phx-key='escape']")

        # phx-keydown fires only when the event target itself carries it, so
        # Escape typed in a panel control reaches only the window binding.
        # That binding returns focus to the trigger, gated on the trigger's
        # own aria-expanded so an Escape with the panel closed moves nothing.
        assert has_element?(
                 view,
                 ~s|[phx-window-keydown*="##{trigger}[aria-expanded='true']"]|
               )
      end
    end

    test "the triggers name their clusters and the primary action keeps its label", context do
      view = mount_map_align(context)

      assert view |> element("#map-alignment-center-trigger") |> render() =~ "Map center"
      assert view |> element("#map-alignment-zoom-trigger") |> render() =~ "Map zoom"
      assert view |> element("#map-alignment-apply-center") |> render() =~ "Center map"
    end

    test "the coordinate fields keep visible labels bound to their inputs", context do
      view = mount_map_align(context)

      assert has_element?(
               view,
               "#map-alignment-center-panel label[for='map-alignment-lat-input']",
               "Latitude"
             )

      assert has_element?(
               view,
               "#map-alignment-center-panel label[for='map-alignment-lon-input']",
               "Longitude"
             )

      assert has_element?(
               view,
               "#map-alignment-zoom-panel label[for='map-alignment-zoom']",
               "Map zoom"
             )
    end
  end

  describe "StationDiagramLive - align residual readout" do
    # The LiveView does not assign `alignment_fit` until the server-side scoring
    # lands, so the four shapes are exercised against the production component
    # directly. `render_component/2` is a harness, not production wiring: the
    # markup under test is the same `~H` block `StationDiagramLive.render/1`
    # renders.
    defp render_map_canvas(overrides) do
      base = [
        organization_id: "00000000-0000-0000-0000-0000000000a1",
        gtfs_version_id: "00000000-0000-0000-0000-0000000000b1",
        station: %{stop_id: "RESIDUAL_STATION", stop_lat: 40.7128, stop_lon: -74.006},
        map_generation: "residual-generation-1",
        map_state: :ready,
        anchor_count: 5,
        child_stops_total: 6,
        child_stops_with_geo: 5,
        child_stops_with_floorplan: 5,
        image_natural_width: 1000,
        image_natural_height: 800
      ]

      render_component(
        &StationDiagramComponents.map_canvas/1,
        Keyword.merge(base, overrides)
      )
    end

    defp residual_state(html),
      do:
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#map-alignment-residual")
        |> LazyHTML.attribute("data-fit-state")
        |> List.first()

    defp residual_value(html),
      do:
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#map-alignment-residual-value")
        |> LazyHTML.text()
        |> String.trim()

    defp residual_text(html),
      do:
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#map-alignment-residual")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

    test "renders a resting line, never a blank or a bare zero, before any measurement" do
      html = render_map_canvas(alignment_fit: nil)

      assert residual_state(html) == "unavailable"
      assert residual_value(html) == "Move to measure"
      refute residual_value(html) =~ ~r/^0(\.0)?( m)?$/
    end

    test "renders the resting line when a round trip could not score the alignment" do
      html = render_map_canvas(alignment_fit: %{status: :unavailable})

      assert residual_state(html) == "unavailable"
      assert residual_value(html) == "Move to measure"
    end

    test "renders the metre value to one decimal and the anchor count within tolerance" do
      html =
        render_map_canvas(alignment_fit: %{status: :ready, rmse_meters: 1.437, anchor_count: 5})

      assert residual_state(html) == "ready"
      assert residual_value(html) == "1.4 m · 5 anchors"
      assert residual_text(html) == "Measured fit 1.4 m · 5 anchors"
    end

    test "singularizes the anchor count when one anchor survived" do
      html =
        render_map_canvas(alignment_fit: %{status: :ready, rmse_meters: 0.25, anchor_count: 1})

      assert residual_value(html) == "0.3 m · 1 anchor"
    end

    test "names the 2.0 m tolerance in text above the threshold, not by colour alone" do
      above =
        render_map_canvas(alignment_fit: %{status: :ready, rmse_meters: 3.62, anchor_count: 5})

      within =
        render_map_canvas(alignment_fit: %{status: :ready, rmse_meters: 2.0, anchor_count: 5})

      assert residual_text(above) == "Fit over 2.0 m 3.6 m · 5 anchors"
      assert residual_state(above) == "ready"

      # 2.0 m exactly is the bar AlignmentInference accepts, so it is not banded.
      refute residual_text(within) =~ "over 2.0 m"
      assert residual_text(within) =~ "Measured fit"
      assert residual_value(within) == "2.0 m · 5 anchors"
    end

    test "names the three-anchor requirement instead of a number below three anchors" do
      html = render_map_canvas(alignment_fit: %{status: :insufficient_anchors, anchor_count: 2})

      assert residual_state(html) == "insufficient"
      assert residual_value(html) == "Needs 3 anchors"
      refute residual_value(html) =~ ~r/\dm|\d m/
    end

    test "keeps the readout on tabular numerals so the value does not reflow as it changes" do
      # `tabular-nums` is the only DOM expression of the no-reflow requirement,
      # so it is asserted directly rather than through a rendered measurement.
      classes =
        render_map_canvas(alignment_fit: %{status: :ready, rmse_meters: 1.0, anchor_count: 4})
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#map-alignment-residual-value")
        |> LazyHTML.attribute("class")
        |> List.first()

      assert classes =~ "tabular-nums"
    end

    test "renders the readout inside the commit bar, exactly once" do
      html =
        render_map_canvas(alignment_fit: %{status: :ready, rmse_meters: 1.0, anchor_count: 4})

      document = LazyHTML.from_fragment(html)

      for id <- ["map-alignment-residual", "map-alignment-residual-value"] do
        assert document |> LazyHTML.query("#map-alignment-commit-bar ##{id}") |> Enum.count() == 1
        assert document |> LazyHTML.query("##{id}") |> Enum.count() == 1
      end
    end

    test "never renders the in-flight state the hook owns" do
      # data-fit-state has four values; "measuring" is written by the hook at
      # schedule time and must never arrive from the server, or a resolved
      # measurement would be presented as still in flight.
      for fit <- [
            nil,
            %{status: :unavailable},
            %{status: :insufficient_anchors, anchor_count: 2},
            %{status: :ready, rmse_meters: 1.0, anchor_count: 4},
            %{status: :ready, rmse_meters: 9.0, anchor_count: 4}
          ] do
        assert residual_state(render_map_canvas(alignment_fit: fit)) in [
                 "ready",
                 "insufficient",
                 "unavailable"
               ]
      end
    end

    test "leaves save and review coordinate changes enabled at every fit value" do
      for fit <- [
            nil,
            %{status: :unavailable},
            %{status: :insufficient_anchors, anchor_count: 0},
            %{status: :ready, rmse_meters: 0.4, anchor_count: 8},
            %{status: :ready, rmse_meters: 2.0, anchor_count: 8},
            %{status: :ready, rmse_meters: 42.5, anchor_count: 8}
          ] do
        document = render_map_canvas(alignment_fit: fit) |> LazyHTML.from_fragment()

        for id <- ["map-alignment-save", "map-alignment-apply"] do
          assert document |> LazyHTML.query("##{id}[disabled]") |> Enum.count() == 0,
                 "#{id} became disabled at fit #{inspect(fit)}; the readout is advisory"
        end
      end
    end

    test "keeps the fatal-state disable expressions independent of the fit" do
      document =
        render_map_canvas(
          map_state: :fatal,
          alignment_fit: %{status: :ready, rmse_meters: 0.1, anchor_count: 9}
        )
        |> LazyHTML.from_fragment()

      for id <- ["map-alignment-save", "map-alignment-apply", "map-alignment-preview-auto"] do
        assert document |> LazyHTML.query("##{id}[disabled]") |> Enum.count() == 1
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Package 09 part (e) step 7 — server-scored fit quality.
  #
  # A current-generation `alignment_transform_changed` carrying an `alignment`
  # key scores that transform against the level's anchor stops and returns the
  # measurement as `alignment_fit`, which `#map-alignment-residual` renders.
  # The measurement is advisory: it appears in no `disabled` expression
  # (CRIT-005), and every other behaviour of the handler is unchanged (AC-20).
  #
  # The anchors are real seeded stops, so `stop_lat`/`stop_lon` arrive as
  # `Decimal`. `FloorplanTransform.residual_rmse_meters/4` requires `is_number/1`
  # and silently skips a `Decimal` anchor, so an unconverted level of five
  # anchors would report "Needs 3 anchors". That conversion is what the
  # measured-value cases below pin.
  # ---------------------------------------------------------------------------

  @fit_image_w 1000
  @fit_image_h 800

  # The alignment the anchor stops are generated from, so a payload carrying it
  # scores ~0 and any departure from it scores the departure.
  @fit_alignment %{
    center_lat: 40.7128,
    center_lon: -74.0060,
    scale_mpp: 0.35,
    rotation_deg: 0.0
  }

  # FloorplanTransform measures 111_111 m per degree of latitude, so shifting
  # the alignment centre north by these offsets displaces every projected anchor
  # by 11.1111 m and 111.111 m — both above the 2.0 m tolerance.
  @fit_offset_above_tolerance 0.0001
  @fit_offset_far_above_tolerance 0.001

  @fit_anchor_points [
    %{x: 20.0, y: 30.0},
    %{x: 70.0, y: 25.0},
    %{x: 45.0, y: 75.0},
    %{x: 15.0, y: 85.0},
    %{x: 88.0, y: 60.0}
  ]

  defp fit_anchor_lat_lon(point) do
    {:ok, {lat, lon}} =
      FloorplanTransform.svg_to_lat_lon(@fit_alignment, @fit_image_w, @fit_image_h, point)

    {lat, lon}
  end

  # The wire shape: string-keyed, exactly what MapAlignmentHook._computeAlignment
  # attaches to the debounced payload.
  defp fit_alignment_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "center_lat" => @fit_alignment.center_lat,
        "center_lon" => @fit_alignment.center_lon,
        "scale_mpp" => @fit_alignment.scale_mpp,
        "rotation_deg" => @fit_alignment.rotation_deg
      },
      overrides
    )
  end

  defp fit_shifted_payload(offset),
    do: fit_alignment_payload(%{"center_lat" => @fit_alignment.center_lat + offset})

  defp fit_base_context(prefix) do
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
        stop_id: "#{prefix}_STATION",
        stop_name: "Fit Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "#{prefix}_level",
        level_name: "Fit Level",
        level_index: 0.0
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
      })

    {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "#{prefix}-diagram.png")

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    }
  end

  # Real seeded stops: `diagram_coordinate` is a string-keyed JSON map and
  # `stop_lat`/`stop_lon` are `Decimal`, both exactly as they come back from the
  # database on the production path.
  defp create_fit_anchor_stops(context, points) do
    points
    |> Enum.with_index()
    |> Enum.map(fn {point, index} ->
      {lat, lon} = fit_anchor_lat_lon(point)

      stop_fixture(context.organization.id, context.gtfs_version.id, %{
        stop_id: "#{context.station.stop_id}_ANCHOR_#{index}",
        stop_name: "Fit Anchor #{index}",
        location_type: 0,
        parent_station: context.station.stop_id,
        level_id: context.level.level_id,
        diagram_coordinate: %{"x" => point.x, "y" => point.y},
        stop_lat: Decimal.from_float(Float.round(lat, 7)),
        stop_lon: Decimal.from_float(Float.round(lon, 7))
      })
    end)
  end

  defp create_fit_unplaced_stop(context, suffix) do
    stop_fixture(context.organization.id, context.gtfs_version.id, %{
      stop_id: "#{context.station.stop_id}_#{suffix}",
      stop_name: "Fit Unplaced #{suffix}",
      location_type: 0,
      parent_station: context.station.stop_id,
      level_id: context.level.level_id,
      diagram_coordinate: nil,
      stop_lat: nil,
      stop_lon: nil
    })
  end

  defp mount_fit_align_without_image_size(context) do
    %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } = context

    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

    render_hook(view, "switch_mode", %{"mode" => "map"})

    view
  end

  defp mount_fit_align(context) do
    view = mount_fit_align_without_image_size(context)
    set_image_natural_size(view, @fit_image_w, @fit_image_h)

    view
  end

  defp fit_transform_changed(view, params),
    do: map_event(view, "alignment_transform_changed", params)

  defp fit_readout(view) do
    document = parsed_document(view)

    %{
      state:
        document
        |> LazyHTML.query("#map-alignment-residual")
        |> LazyHTML.attribute("data-fit-state")
        |> List.first(),
      value:
        document
        |> LazyHTML.query("#map-alignment-residual-value")
        |> LazyHTML.text()
        |> String.trim(),
      text:
        document
        |> LazyHTML.query("#map-alignment-residual")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
    }
  end

  describe "StationDiagramLive - align fit scoring" do
    setup do
      context = fit_base_context("FIT")
      create_fit_anchor_stops(context, @fit_anchor_points)
      create_fit_unplaced_stop(context, "UNPLACED")

      other_level =
        level_fixture(context.organization.id, context.gtfs_version.id, %{
          level_id: "FIT_other_level",
          level_name: "Fit Other Level",
          level_index: 1.0
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          organization_id: context.organization.id,
          gtfs_version_id: context.gtfs_version.id,
          stop_id: context.station.id,
          level_id: other_level.id
        })

      Map.put(context, :other_level, other_level)
    end

    test "a fresh align surface rests with no measurement", context do
      view = mount_fit_align(context)

      assert assigns(view).alignment_fit == nil
      assert fit_readout(view).state == "unavailable"
      assert fit_readout(view).value == "Move to measure"
    end

    test "a current-generation transform measures its alignment against the level's anchor stops",
         context do
      view = mount_fit_align(context)

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      assert %{status: :ready, anchor_count: 5, rmse_meters: rmse} = assigns(view).alignment_fit
      assert rmse < 0.05
      assert fit_readout(view).state == "ready"
      assert fit_readout(view).value == "0.0 m · 5 anchors"
    end

    test "an alignment displaced from its anchors names the tolerance in words", context do
      view = mount_fit_align(context)

      fit_transform_changed(view, %{
        "alignment" => fit_shifted_payload(@fit_offset_above_tolerance)
      })

      assert fit_readout(view).state == "ready"
      assert fit_readout(view).value == "11.1 m · 5 anchors"
      assert fit_readout(view).text =~ "Fit over 2.0 m"
    end

    test "a transform without an alignment key measures nothing on a resting surface", context do
      view = mount_fit_align(context)

      fit_transform_changed(view, %{"unsaved" => true})

      assert assigns(view).alignment_fit == nil
      assert fit_readout(view).value == "Move to measure"
    end

    test "a transform without an alignment key leaves a standing measurement untouched",
         context do
      view = mount_fit_align(context)
      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})
      measured = assigns(view).alignment_fit

      fit_transform_changed(view, %{"unsaved" => true})

      assert assigns(view).alignment_fit == measured
      assert fit_readout(view).value == "0.0 m · 5 anchors"
    end

    test "a stale generation carrying an alignment measures nothing", context do
      view = mount_fit_align(context)

      render_hook(view, "alignment_transform_changed", %{
        "generation" => "stale-generation",
        "alignment" => fit_alignment_payload()
      })

      assert assigns(view).alignment_fit == nil
    end

    test "a stale generation does not overwrite a standing measurement", context do
      view = mount_fit_align(context)
      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})
      measured = assigns(view).alignment_fit

      render_hook(view, "alignment_transform_changed", %{
        "generation" => "stale-generation",
        "alignment" => fit_shifted_payload(@fit_offset_far_above_tolerance)
      })

      assert assigns(view).alignment_fit == measured
    end

    test "re-sending an identical alignment produces an identical measurement", context do
      view = mount_fit_align(context)
      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})
      first = assigns(view).alignment_fit

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})
      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      assert assigns(view).alignment_fit == first
      assert fit_readout(view).value == "0.0 m · 5 anchors"
    end

    test "a later measurement replaces the earlier one", context do
      view = mount_fit_align(context)

      fit_transform_changed(view, %{
        "alignment" => fit_shifted_payload(@fit_offset_above_tolerance)
      })

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      assert fit_readout(view).value == "0.0 m · 5 anchors"
      refute fit_readout(view).text =~ "over 2.0 m"
    end

    test "save and review coordinate changes stay enabled at a fit far above tolerance",
         context do
      view = mount_fit_align(context)

      fit_transform_changed(view, %{
        "alignment" => fit_shifted_payload(@fit_offset_far_above_tolerance)
      })

      assert fit_readout(view).text =~ "Fit over 2.0 m"
      refute has_element?(view, "#map-alignment-save[disabled]")
      refute has_element?(view, "#map-alignment-apply[disabled]")
      refute has_element?(view, "#map-alignment-preview-auto[disabled]")
    end

    test "a transform carrying an alignment but omitting unsaved is still treated as unsaved",
         context do
      view = mount_fit_align(context)

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      assert has_element?(view, "#map-alignment-unsaved")
      refute has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "a transform carrying an alignment still invalidates an open coordinate review",
         context do
      view = mount_fit_align(context)
      open_coordinate_review(view, fit_shifted_payload(@fit_offset_far_above_tolerance))
      assert has_element?(view, "#coordinate-review-dialog")

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      refute has_element?(view, "#coordinate-review-dialog")

      assert has_element?(
               view,
               "#coordinate-review-status",
               "The alignment changed — review again."
             )
    end

    test "the review-invalidating branch records the measurement too", context do
      view = mount_fit_align(context)
      open_coordinate_review(view, fit_shifted_payload(@fit_offset_far_above_tolerance))
      assert has_element?(view, "#coordinate-review-dialog")

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      assert fit_readout(view).value == "0.0 m · 5 anchors"
    end

    test "leaving and re-entering align mode clears the measurement", context do
      view = mount_fit_align(context)
      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      render_hook(view, "switch_mode", %{"mode" => "view"})
      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert assigns(view).alignment_fit == nil
      assert fit_readout(view).value == "Move to measure"
    end

    test "switching level clears the measurement", context do
      view = mount_fit_align(context)
      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      render_hook(view, "switch_level", %{"level_id" => context.other_level.id})

      assert assigns(view).alignment_fit == nil
    end

    test "a transform scored before the floorplan image size arrives reports no measurement",
         context do
      view = mount_fit_align_without_image_size(context)

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      assert assigns(view).alignment_fit == %{status: :unavailable}
      assert fit_readout(view).state == "unavailable"
      assert fit_readout(view).value == "Move to measure"
    end

    test "an alignment the server cannot validate reports no measurement", context do
      view = mount_fit_align(context)
      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      fit_transform_changed(view, %{"alignment" => %{"center_lat" => "not-a-number"}})

      assert assigns(view).alignment_fit == %{status: :unavailable}
    end

    test "floorplan dimensions reported as floats are still scored", context do
      view = mount_fit_align_without_image_size(context)
      set_image_natural_size(view, @fit_image_w * 1.0, @fit_image_h * 1.0)

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      assert %{status: :ready, anchor_count: 5} = assigns(view).alignment_fit
    end
  end

  describe "StationDiagramLive - align fit scoring below the anchor minimum" do
    setup do
      context = fit_base_context("FITMIN")
      create_fit_anchor_stops(context, Enum.take(@fit_anchor_points, 2))

      context
    end

    test "two usable anchors report the three-anchor requirement, never a bare zero", context do
      view = mount_fit_align(context)

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      assert assigns(view).alignment_fit == %{status: :insufficient_anchors, anchor_count: 2}
      assert fit_readout(view).state == "insufficient"
      assert fit_readout(view).value == "Needs 3 anchors"
    end

    test "an insufficient measurement leaves save and review coordinate changes enabled",
         context do
      view = mount_fit_align(context)

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      refute has_element?(view, "#map-alignment-save[disabled]")
      refute has_element?(view, "#map-alignment-apply[disabled]")
    end
  end

  describe "StationDiagramLive - align fit scoring with no placed stops" do
    setup do
      context = fit_base_context("FITNONE")
      create_fit_unplaced_stop(context, "UNPLACED")

      context
    end

    test "a level with no placed stops reports the anchor requirement", context do
      view = mount_fit_align(context)

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      assert assigns(view).alignment_fit == %{status: :insufficient_anchors, anchor_count: 0}
      assert fit_readout(view).value == "Needs 3 anchors"
    end

    test "a transform carrying an alignment still clears a standing no-changes status",
         context do
      view = mount_fit_align(context)
      open_coordinate_review(view)
      assert has_element?(view, "#coordinate-review-status", "No coordinate changes to review.")

      fit_transform_changed(view, %{"alignment" => fit_alignment_payload()})

      refute has_element?(view, "#coordinate-review-status")
    end
  end

  # ---------------------------------------------------------------------------
  # Package 09 part (e) step 9 — the Align control strip after the rework.
  #
  # Part (d) grouped this surface into five bordered `<fieldset>`s and addressed
  # every control by the visible `<legend>` of the group it sat in. Part (e)
  # deletes all five, so those assertions are rewritten here against the
  # containers that replaced them: `#map-alignment-tools` floating over the map
  # (INV-10E-1), the two popover panels, and `#map-alignment-commit-bar` below
  # it (INV-10E-2). No behaviour the old block guarded is dropped — control
  # membership, the ignore boundary on the zoom input, the other-levels
  # permutation, the transform id set and titles, the unsaved matrix, and the
  # three `disabled` expressions all reappear below against the new structure.
  #
  # This block is the mechanical face of the spec's "Id and selector delta"
  # (CRIT-003): every id the rework adds, every id it preserves, and every
  # container it removes is named here, so a later re-parent that silently
  # drops, moves, or duplicates a control fails a test rather than a review.
  # The delta lists are restated independently of the ones the step-4 block
  # uses — a single shared list could be edited to make both blocks pass.
  #
  # Containment is asserted as one id → container map compared for equality
  # rather than as a sweep of membership checks: a map diff names the control
  # and both containers, and it catches a control that gained a second home as
  # well as one that lost its own. No assertion here names a Tailwind class;
  # part (d) had to repoint exactly such an assertion when its container moved.
  # ---------------------------------------------------------------------------

  # The four containers that replaced the five fieldsets. The popover panels
  # nest inside the commit bar, so they are tried first: the innermost
  # container is the one that owns the control.
  @align_containers [
    "map-alignment-center-panel",
    "map-alignment-zoom-panel",
    "map-alignment-help-panel",
    "map-alignment-tools",
    "map-alignment-commit-bar"
  ]

  # Every id the spec's delta says renders on a resting Align surface: the ten
  # under "Added" plus every control and readout under "Preserved verbatim".
  # Each must render exactly once.
  @align_delta_selectors [
    # Added by this spec.
    "#map-alignment-workspace",
    "#map-alignment-tools",
    "#map-alignment-tools-toggle",
    "#map-alignment-commit-bar",
    "#map-alignment-center-trigger",
    "#map-alignment-center-panel",
    "#map-alignment-zoom-trigger",
    "#map-alignment-zoom-panel",
    "#map-alignment-residual",
    "#map-alignment-residual-value",
    # Preserved verbatim from part (d).
    "#map-transform-left-fine",
    "#map-transform-up-fine",
    "#map-transform-down-fine",
    "#map-transform-right-fine",
    "#map-transform-rotate-left-fine",
    "#map-transform-rotate-right-fine",
    "#map-transform-scale-down-fine",
    "#map-transform-scale-up-fine",
    "#map-alignment-restore-saved",
    "#map-alignment-opacity",
    "#map-alignment-zoom",
    "#map-alignment-zoom-value",
    "#map-alignment-lat-input",
    "#map-alignment-lon-input",
    "#map-alignment-apply-center",
    "[data-role='child-stop-coverage']",
    "#map-alignment-save-help",
    "#map-alignment-preview-auto",
    "#map-alignment-actions",
    "#map-alignment-preview-status",
    "#map-alignment-save",
    "#map-alignment-apply"
  ]

  # The "Removed" half of the delta. The two named fieldsets go by id; the three
  # unnamed ones can only return as a fieldset inside one of the surviving
  # containers, or under one of the legends refuted separately. The four coarse
  # transform ids are here because part (d) removed them and INV-09D-4 keeps
  # them removed.
  @align_removed_selectors [
    "#map-alignment-transform-controls",
    "#map-alignment-assisted",
    "#map-alignment-workspace fieldset",
    "#map-alignment-commit-bar fieldset",
    "#map-transform-left-coarse",
    "#map-transform-right-coarse",
    "#map-transform-rotate-right-coarse",
    "#map-transform-scale-up-coarse"
  ]

  @deleted_group_legends [
    "Map center",
    "Floorplan transform",
    "Assisted alignment",
    "Layers",
    "Save and apply"
  ]

  # The commit bar's named blocks, in the order the operator reads them.
  @commit_bar_block_selectors [
    "[data-role='child-stop-coverage']",
    "#map-alignment-save-help",
    "#map-alignment-unsaved",
    "#map-alignment-preview-auto",
    "#map-alignment-center-trigger",
    "#map-alignment-zoom-trigger",
    "#map-alignment-residual",
    "#map-alignment-actions"
  ]

  # The three buttons whose `disabled` expressions INV-09D-3 and CRIT-005 pin.
  @align_action_ids [
    "map-alignment-preview-auto",
    "map-alignment-save",
    "map-alignment-apply"
  ]

  describe "StationDiagramLive - align control strip" do
    setup do
      fit_base_context("STRIP")
    end

    test "every align control and readout renders in the container that owns it", context do
      view = mount_map_align(context)

      containment =
        align_containers_of(view, [
          "#map-transform-left-fine",
          "#map-transform-up-fine",
          "#map-transform-down-fine",
          "#map-transform-right-fine",
          "#map-transform-rotate-left-fine",
          "#map-transform-rotate-right-fine",
          "#map-transform-scale-down-fine",
          "#map-transform-scale-up-fine",
          "#map-alignment-restore-saved",
          "#map-alignment-opacity",
          "#map-alignment-tools-toggle",
          "#map-alignment-lat-input",
          "#map-alignment-lon-input",
          "#map-alignment-apply-center",
          "#map-alignment-zoom",
          "#map-alignment-zoom-value",
          "[data-role='child-stop-coverage']",
          "#map-alignment-save-help",
          "#map-alignment-residual",
          "#map-alignment-residual-value",
          "#map-alignment-preview-auto",
          "#map-alignment-center-trigger",
          "#map-alignment-center-panel",
          "#map-alignment-zoom-trigger",
          "#map-alignment-zoom-panel",
          "#map-alignment-actions",
          "#map-alignment-preview-status",
          "#map-alignment-save",
          "#map-alignment-apply",
          "#map-alignment-state"
        ])

      assert containment == %{
               "#map-transform-left-fine" => "map-alignment-tools",
               "#map-transform-up-fine" => "map-alignment-tools",
               "#map-transform-down-fine" => "map-alignment-tools",
               "#map-transform-right-fine" => "map-alignment-tools",
               "#map-transform-rotate-left-fine" => "map-alignment-tools",
               "#map-transform-rotate-right-fine" => "map-alignment-tools",
               "#map-transform-scale-down-fine" => "map-alignment-tools",
               "#map-transform-scale-up-fine" => "map-alignment-tools",
               "#map-alignment-restore-saved" => "map-alignment-tools",
               "#map-alignment-opacity" => "map-alignment-tools",
               "#map-alignment-tools-toggle" => "map-alignment-tools",
               "#map-alignment-lat-input" => "map-alignment-center-panel",
               "#map-alignment-lon-input" => "map-alignment-center-panel",
               "#map-alignment-apply-center" => "map-alignment-center-panel",
               "#map-alignment-zoom" => "map-alignment-zoom-panel",
               "#map-alignment-zoom-value" => "map-alignment-zoom-panel",
               "[data-role='child-stop-coverage']" => "map-alignment-commit-bar",
               "#map-alignment-save-help" => "map-alignment-commit-bar",
               "#map-alignment-residual" => "map-alignment-commit-bar",
               "#map-alignment-residual-value" => "map-alignment-commit-bar",
               "#map-alignment-preview-auto" => "map-alignment-commit-bar",
               "#map-alignment-center-trigger" => "map-alignment-commit-bar",
               "#map-alignment-center-panel" => "map-alignment-commit-bar",
               "#map-alignment-zoom-trigger" => "map-alignment-commit-bar",
               "#map-alignment-zoom-panel" => "map-alignment-commit-bar",
               "#map-alignment-actions" => "map-alignment-commit-bar",
               "#map-alignment-preview-status" => "map-alignment-commit-bar",
               "#map-alignment-save" => "map-alignment-commit-bar",
               "#map-alignment-apply" => "map-alignment-commit-bar",
               "#map-alignment-state" => "map-alignment-commit-bar"
             }
    end

    test "no align control renders outside the four containers", context do
      view = mount_map_align(context)

      assert uncontained_align_control_ids(view) == []
    end

    test "the unsaved indicator joins the commit bar rather than the tools panel", context do
      view = mount_map_align(context)

      transform_changed(view, %{"unsaved" => true})

      assert align_containers_of(view, ["#map-alignment-unsaved"]) == %{
               "#map-alignment-unsaved" => "map-alignment-commit-bar"
             }
    end

    test "every id in the spec's identity delta renders exactly once", context do
      view = mount_map_align(context)

      assert align_delta_counts(view) == Map.new(@align_delta_selectors, &{&1, 1})
    end

    test "no container the rework removed renders again", context do
      view = mount_map_align(context)

      assert surviving_removed_selectors(view) == []
    end

    test "no legend anywhere on the page names a deleted control group", context do
      view = mount_map_align(context)

      assert resurrected_group_legends(view) == []
    end

    test "the surviving group names read as visible trigger labels, not hidden ones", context do
      view = mount_map_align(context)

      assert element_text(view, "#map-alignment-center-trigger") == "Map center"
      assert element_text(view, "#map-alignment-zoom-trigger") == "Map zoom"
      refute has_element?(view, ".sr-only", "Map center")
    end

    test "the map zoom slider keeps its ignore boundary on the input, not the panel", context do
      view = mount_map_align(context)

      assert has_element?(
               view,
               "#map-alignment-zoom-panel #map-alignment-zoom[phx-update='ignore']"
             )

      refute has_element?(view, "#map-alignment-zoom-panel[phx-update='ignore']")
    end

    test "the other-levels opacity control joins the tools panel when an other level shows its floorplan",
         context do
      %{organization: organization, gtfs_version: gtfs_version, station: station} = context
      other_level_id = aligned_other_level(organization, gtfs_version, station, "strip")
      view = mount_map_align(context)

      render_click(element(view, floorplan_selector(other_level_id)))

      assert align_containers_of(view, ["#map-other-overlays-opacity"]) == %{
               "#map-other-overlays-opacity" => "map-alignment-tools"
             }

      assert has_element?(
               view,
               "#map-other-overlays-opacity-tip[data-tip='Other-levels opacity · 70%']"
             )
    end

    test "no other-levels opacity control renders when no other level shows a floorplan",
         context do
      view = mount_map_align(context)

      refute has_element?(view, "#map-other-overlays-opacity")
    end

    test "the commit bar reads coverage, help, assisted alignment, popovers, fit, then actions",
         context do
      view = mount_map_align(context)

      assert commit_bar_blocks(view) == [
               "child-stop-coverage",
               "map-alignment-save-help",
               "map-alignment-preview-auto",
               "map-alignment-center-trigger",
               "map-alignment-zoom-trigger",
               "map-alignment-residual",
               "map-alignment-actions"
             ]
    end

    test "the unsaved indicator renders between the help line and the assisted cluster",
         context do
      view = mount_map_align(context)

      transform_changed(view, %{"unsaved" => true})

      assert commit_bar_blocks(view) == [
               "child-stop-coverage",
               "map-alignment-save-help",
               "map-alignment-unsaved",
               "map-alignment-preview-auto",
               "map-alignment-center-trigger",
               "map-alignment-zoom-trigger",
               "map-alignment-residual",
               "map-alignment-actions"
             ]
    end

    test "the child-stop coverage sentence renders once and only inside the commit bar",
         context do
      view = mount_map_align(context)

      assert coverage_sentence_count(view) == 1
      assert "child-stop-coverage" in commit_bar_blocks(view)
    end

    test "the actions block holds the preview status, save, and review controls", context do
      view = mount_map_align(context)

      assert has_element?(view, "#map-alignment-actions #map-alignment-preview-status")
      assert has_element?(view, "#map-alignment-actions #map-alignment-save")
      assert has_element?(view, "#map-alignment-actions #map-alignment-apply")
    end

    test "the help line states what each of the two save actions does", context do
      view = mount_map_align(context)

      assert element_text(view, "#map-alignment-save-help") ==
               "Save alignment stores the floorplan's map position. " <>
                 "Review coordinate changes also writes latitude and longitude onto child stops."
    end

    test "the tools toggle renders the expanded label the server owns", context do
      view = mount_map_align(context)

      # The control is icon-only, so its label lives in the tooltip and the
      # accessible name rather than in text. The collapsed label is the hook's
      # to write; the server renders the expanded one on every patch, so a
      # server-rendered "Show tools" would invert the control for anyone who
      # never clicks it.
      assert has_element?(view, "#map-alignment-tools-toggle[data-tip='Hide tools']")
      assert has_element?(view, "#map-alignment-tools-toggle[aria-label='Hide tools']")
      assert has_element?(view, "#map-alignment-tools-toggle[data-collapsed='false']")
    end

    test "the transform pad renders exactly the eight symmetric fine controls", context do
      view = mount_map_align(context)

      assert transform_controls_rendered(view) == %{
               "map-transform-left-fine" =>
                 {"left", "false", "Move floorplan left · 2 px (Shift 10 px)"},
               "map-transform-up-fine" =>
                 {"up", "false", "Move floorplan up · 2 px (Shift 10 px)"},
               "map-transform-down-fine" =>
                 {"down", "false", "Move floorplan down · 2 px (Shift 10 px)"},
               "map-transform-right-fine" =>
                 {"right", "false", "Move floorplan right · 2 px (Shift 10 px)"},
               "map-transform-rotate-left-fine" =>
                 {"rotate-left", "false", "Rotate floorplan left · 1° (Shift 5°)"},
               "map-transform-rotate-right-fine" =>
                 {"rotate-right", "false", "Rotate floorplan right · 1° (Shift 5°)"},
               "map-transform-scale-down-fine" =>
                 {"scale-down", "false", "Shrink floorplan · 1% (Shift 10%)"},
               "map-transform-scale-up-fine" =>
                 {"scale-up", "false", "Grow floorplan · 1% (Shift 10%)"}
             }
    end

    test "the slider readouts render their initial values", context do
      view = mount_map_align(context)

      # The opacity sliders carry their percentage in the tooltip; the thumb
      # position is the at-a-glance reading, so no readout sits beside them.
      refute has_element?(view, "#map-alignment-opacity-value")

      assert has_element?(view, "#map-alignment-opacity-tip[data-tip='Floorplan opacity · 70%']")
      assert element_text(view, "#map-alignment-zoom-value") == "19.0"
    end

    test "the transform pad reports each operation through its tooltip, not a readout",
         context do
      view = mount_map_align(context)

      # Rotation and scale carry no live readout: every pad button names its
      # operation and both step sizes in `title`, and the alignment's real
      # quality signal is the residual in the commit bar.
      refute has_element?(view, "#map-alignment-rotation-value")
      refute has_element?(view, "#map-alignment-scale-value")

      assert has_element?(
               view,
               "#map-transform-rotate-left-fine[data-tip='Rotate floorplan left · 1° (Shift 5°)']"
             )

      assert has_element?(
               view,
               "#map-transform-scale-up-fine[data-tip='Grow floorplan · 1% (Shift 10%)']"
             )
    end

    test "the re-parented status elements keep their aria-live announcements", context do
      view = mount_map_align(context)
      document = parsed_document(view)

      # `#auto-alignment-status` and `#auto-alignment-error` carry the rest of
      # the preserved attribute set; the alignment-preview suite pins those.
      live_regions =
        Map.new(["map-alignment-preview-status", "map-alignment-state"], fn id ->
          {id,
           document |> LazyHTML.query("##{id}") |> LazyHTML.attribute("aria-live") |> List.first()}
        end)

      assert live_regions == %{
               "map-alignment-preview-status" => "polite",
               "map-alignment-state" => "polite"
             }
    end

    test "a fatal map state disables save, preview, and review", context do
      view = mount_map_align(context)
      set_image_natural_size(view, 1024, 768)

      map_event(view, "map_state", %{"state" => "fatal"})

      assert disabled_align_actions(view) == [
               "map-alignment-preview-auto",
               "map-alignment-save",
               "map-alignment-apply"
             ]
    end

    test "a ready map state with valid image dimensions enables save, preview, and review",
         context do
      view = mount_map_align(context)
      set_image_natural_size(view, 1024, 768)

      map_event(view, "map_state", %{"state" => "ready"})

      assert disabled_align_actions(view) == []
    end

    test "missing floorplan image dimensions disable preview and review but not save", context do
      view = mount_map_align(context)

      map_event(view, "map_state", %{"state" => "ready"})

      assert disabled_align_actions(view) == [
               "map-alignment-preview-auto",
               "map-alignment-apply"
             ]
    end

    test "a measured fit far outside tolerance gates nothing", context do
      create_fit_anchor_stops(context, @fit_anchor_points)
      view = mount_fit_align(context)

      fit_transform_changed(view, %{
        "alignment" => fit_shifted_payload(@fit_offset_far_above_tolerance)
      })

      assert fit_readout(view).text =~ "Fit over 2.0 m"
      assert disabled_align_actions(view) == []
    end

    test "restore follows the unsaved state without leaving the tools panel", context do
      view = mount_map_align(context)

      assert has_element?(view, "#map-alignment-tools #map-alignment-restore-saved[disabled]")

      transform_changed(view, %{"unsaved" => true})

      assert has_element?(view, "#map-alignment-tools #map-alignment-restore-saved")
      refute has_element?(view, "#map-alignment-restore-saved[disabled]")
    end

    test "the assisted cluster renders inside the commit bar once a preview is ready", context do
      create_fit_anchor_stops(context, @fit_anchor_points)
      view = mount_fit_align(context)

      render_click(element(view, "#map-alignment-preview-auto"))

      assert align_containers_of(view, [
               "#auto-alignment-fit-value",
               "#auto-alignment-fit-description"
             ]) == %{
               "#auto-alignment-fit-value" => "map-alignment-commit-bar",
               "#auto-alignment-fit-description" => "map-alignment-commit-bar"
             }
    end

    test "the preview banner floats in the workspace rather than the commit bar", context do
      create_fit_anchor_stops(context, @fit_anchor_points)
      view = mount_fit_align(context)

      render_click(element(view, "#map-alignment-preview-auto"))

      assert has_element?(view, "#map-alignment-workspace #auto-alignment-status")
      refute has_element?(view, "#map-alignment-commit-bar #auto-alignment-status")
      refute has_element?(view, "[phx-update='ignore'] #auto-alignment-status")
    end

    test "applying an assisted preview marks the surface unsaved without dropping the preview",
         context do
      create_fit_anchor_stops(context, @fit_anchor_points)
      view = mount_fit_align(context)
      render_click(element(view, "#map-alignment-preview-auto"))

      # The apply itself is the hook's: it moves the overlay client-side and,
      # since step 2, reports the move as dirtying. This is the server-visible
      # half — the payload that path now sends.
      transform_changed(view, %{"unsaved" => true})

      assert has_element?(view, "#map-alignment-commit-bar #map-alignment-unsaved")
      refute has_element?(view, "#map-alignment-restore-saved[disabled]")
      assert has_element?(view, "#auto-alignment-status")
    end

    test "restoring after an applied preview returns the surface to its saved state", context do
      create_fit_anchor_stops(context, @fit_anchor_points)
      view = mount_fit_align(context)
      render_click(element(view, "#map-alignment-preview-auto"))
      transform_changed(view, %{"unsaved" => true})

      render_hook(view, "restore_saved_alignment", %{})

      refute has_element?(view, "#map-alignment-unsaved")
      assert has_element?(view, "#map-alignment-tools #map-alignment-restore-saved[disabled]")
    end
  end

  # Ids of the Align control-strip controls. Part (d) resolved membership by id
  # prefix because the strip was a sibling of the `phx-hook="MapAlignment"` root
  # with no stable container id; part (e) gives it four, but the prefix set is
  # still what distinguishes an Align control from the rest of the page, and the
  # map region's own handles are still subtracted structurally.
  @strip_control_id_prefixes ["map-alignment-", "map-transform-", "map-other-overlays-"]

  defp parsed_document(view), do: view |> render() |> LazyHTML.from_document()

  defp strip_control_id?(id), do: String.starts_with?(id, @strip_control_id_prefixes)

  # Maps each given selector to the Align container that owns it, or `nil` when
  # no container does. `@align_containers` is ordered innermost-first, so a
  # control in a popover is attributed to the popover rather than to the commit
  # bar the popover nests in.
  defp align_containers_of(view, selectors) do
    document = parsed_document(view)

    Map.new(selectors, fn selector -> {selector, owning_align_container(document, selector)} end)
  end

  defp owning_align_container(document, selector) do
    Enum.find(@align_containers, fn container ->
      document |> LazyHTML.query("##{container} #{selector}") |> Enum.any?()
    end)
  end

  # Align controls that render outside every one of the four containers. The
  # map region's own handles (`#map-alignment-rotate-handle`,
  # `#map-alignment-scale-handle`) live inside the ignored canvas by design and
  # are subtracted rather than listed.
  defp uncontained_align_control_ids(view) do
    document = parsed_document(view)

    align_controls =
      document
      |> LazyHTML.query("button[id], input[id]")
      |> LazyHTML.attribute("id")
      |> Enum.filter(&strip_control_id?/1)

    map_region_controls =
      document
      |> LazyHTML.query(
        "[phx-hook='MapAlignment'] button[id], [phx-hook='MapAlignment'] input[id]"
      )
      |> LazyHTML.attribute("id")

    contained_controls =
      Enum.flat_map(@align_containers, fn container ->
        document
        |> LazyHTML.query("##{container} button[id], ##{container} input[id]")
        |> LazyHTML.attribute("id")
      end)

    align_controls
    |> Kernel.--(map_region_controls)
    |> Kernel.--(contained_controls)
  end

  # How many times each selector in the spec's identity delta renders.
  defp align_delta_counts(view) do
    document = parsed_document(view)

    Map.new(@align_delta_selectors, fn selector ->
      {selector, document |> LazyHTML.query(selector) |> Enum.count()}
    end)
  end

  # Containers the rework removed that are rendering again.
  defp surviving_removed_selectors(view) do
    document = parsed_document(view)

    Enum.filter(@align_removed_selectors, fn selector ->
      document |> LazyHTML.query(selector) |> Enum.any?()
    end)
  end

  # Legend text anywhere on the page that names one of the five deleted groups.
  defp resurrected_group_legends(view) do
    view
    |> parsed_document()
    |> LazyHTML.query("legend")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    |> Enum.filter(&(&1 in @deleted_group_legends))
  end

  # The commit bar's named blocks, in document order.
  defp commit_bar_blocks(view) do
    selector =
      Enum.map_join(@commit_bar_block_selectors, ", ", &("#map-alignment-commit-bar " <> &1))

    view
    |> parsed_document()
    |> LazyHTML.query(selector)
    |> Enum.map(fn node ->
      case LazyHTML.attribute(node, "id") do
        [id | _] -> id
        [] -> node |> LazyHTML.attribute("data-role") |> List.first()
      end
    end)
  end

  # The Align action buttons that currently carry `disabled`, in a fixed order
  # so the result is a value to compare rather than a set to search.
  defp disabled_align_actions(view) do
    document = parsed_document(view)

    Enum.filter(@align_action_ids, fn id ->
      document |> LazyHTML.query("##{id}[disabled]") |> Enum.any?()
    end)
  end

  defp coverage_sentence_count(view) do
    view
    |> parsed_document()
    |> LazyHTML.query("[data-role='child-stop-coverage']")
    |> Enum.count()
  end

  # Every rendered transform control, keyed by id, as {action, coarse, title}.
  defp transform_controls_rendered(view) do
    view
    |> parsed_document()
    |> LazyHTML.query("[data-map-transform-action]")
    |> Enum.map(fn control ->
      {first_attribute(control, "id"),
       {first_attribute(control, "data-map-transform-action"),
        first_attribute(control, "data-map-transform-coarse"),
        first_attribute(control, "data-tip")}}
    end)
    |> Map.new()
  end

  # Ids of every patch-ignored element inside the given container, so a new
  # exclusion has to be stated rather than slipping in.
  defp ignored_ids_within(view, container) do
    view
    |> parsed_document()
    |> LazyHTML.query("#{container} [phx-update='ignore']")
    |> Enum.map(&first_attribute(&1, "id"))
  end

  defp element_text(view, selector) do
    view
    |> parsed_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp first_attribute(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  # Creates an other level with a diagram and a complete alignment (floorplan-eligible)
  # and returns its level id (string).
  defp aligned_other_level(organization, gtfs_version, station, slug, level_index \\ 1.0) do
    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "#{slug}_aligned",
        level_name: "#{slug} aligned",
        level_index: level_index
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
      })

    {:ok, _} =
      Gtfs.update_stop_level_alignment(stop_level, %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.35,
        floorplan_rotation_deg: 0.0
      })

    {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "#{slug}-aligned.png")

    level.id
  end

  # Creates an other level with one geo-coded child stop (stops-eligible) and returns its level id.
  defp level_with_geo_stop(organization, gtfs_version, station, slug, level_index \\ 1.0) do
    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "#{slug}_geo",
        level_name: "#{slug} geo",
        level_index: level_index
      })

    {:ok, _stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
      })

    _geo_stop =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "#{String.upcase(slug)}_GEO_STOP",
        stop_name: "#{slug} geo stop",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        stop_lat: Decimal.new("40.7000"),
        stop_lon: Decimal.new("-74.0000")
      })

    level.id
  end

  defp floorplan_selector(level_id) do
    "#other-levels-panel input[phx-click='toggle_other_level_floorplan']" <>
      "[phx-value-level-id='#{level_id}']"
  end

  defp stops_selector(level_id) do
    "#other-levels-panel input[phx-click='toggle_other_level_stops']" <>
      "[phx-value-level-id='#{level_id}']"
  end

  defp floorplan_checked?(view, level_id) do
    has_element?(view, floorplan_selector(level_id) <> "[checked]")
  end

  defp stops_checked?(view, level_id) do
    has_element?(view, stops_selector(level_id) <> "[checked]")
  end

  # Cleanup helper for the production-adapter case. The ReviewedApplyTransaction.Repo
  # adapter commits through SET TRANSACTION ISOLATION LEVEL SERIALIZABLE, which
  # cannot run inside the sandbox's outer transaction; the case therefore wraps
  # its body in Sandbox.unboxed_run/2. The case creates its own organization and
  # user inside that block, so cleanup deletes every unboxed-owned row in
  # dependency order, including user tokens and users.
  defp delete_review_adapter_fixtures!(organization_id) do
    import Ecto.Query

    alias GtfsPlanner.Accounts.User
    alias GtfsPlanner.Accounts.UserOrgMembership
    alias GtfsPlanner.Accounts.UserToken
    alias GtfsPlanner.Gtfs.ChangeLog
    alias GtfsPlanner.Gtfs.JournalEntry
    alias GtfsPlanner.Gtfs.Level
    alias GtfsPlanner.Gtfs.Stop
    alias GtfsPlanner.Gtfs.StopLevel
    alias GtfsPlanner.Versions.GtfsVersion

    user_ids =
      Repo.all(
        from(m in UserOrgMembership,
          where: m.organization_id == ^organization_id,
          select: m.user_id
        )
      )

    Repo.delete_all(from(j in JournalEntry, where: j.organization_id == ^organization_id))
    Repo.delete_all(from(c in ChangeLog, where: c.organization_id == ^organization_id))
    Repo.delete_all(from(s in StopLevel, where: s.organization_id == ^organization_id))
    Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
    Repo.delete_all(from(l in Level, where: l.organization_id == ^organization_id))

    Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id == ^organization_id))

    Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))

    Repo.delete_all(
      from(o in GtfsPlanner.Organizations.Organization, where: o.id == ^organization_id)
    )

    if user_ids != [] do
      Repo.delete_all(from(t in UserToken, where: t.user_id in ^user_ids))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
    end
  end

  defp postgrex_serialization_error do
    %Postgrex.Error{
      postgres: %{
        code: :serialization_failure,
        message: "serialization failure between transactions"
      }
    }
  end
end
