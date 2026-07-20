defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveMapModeTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Repo

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

  defp apply_coordinate_preview(view) do
    render_click(element(view, "#confirm-coordinate-preview"))

    render_submit(
      element(view, "#coordinate-preview-confirmation-form"),
      %{"coordinate_preview" => %{"phrase" => "APPLY"}}
    )
  end

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

    test "switch_mode to map swaps to the map canvas", %{
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

      assert has_element?(view, ".map-canvas")
      refute has_element?(view, "[id^='diagram-canvas-']")
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

      html =
        map_event(view, "preview_coordinate_application", %{
          "center_lat" => 40.7128,
          "center_lon" => -74.0060,
          "scale_mpp" => 0.35,
          "rotation_deg" => 0.0
        })

      assert html =~ "Preview coordinate changes"
      apply_coordinate_preview(view)

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
      assert has_element?(view, "#map-alignment-apply.btn-primary", "Preview coordinate changes")

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

    test "save_and_apply_alignment persists alignment and stop lat/lon and flashes count",
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

      html =
        map_event(view, "preview_coordinate_application", %{
          "center_lat" => 40.7128,
          "center_lon" => -74.0060,
          "scale_mpp" => 0.35,
          "rotation_deg" => 0.0
        })

      assert html =~ "Preview coordinate changes"
      apply_coordinate_preview(view)

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

    test "save_and_apply_alignment without image dimensions shows error and makes no writes", %{
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

      html =
        map_event(view, "preview_coordinate_application", %{
          "center_lat" => 40.7128,
          "center_lon" => -74.0060,
          "scale_mpp" => 0.35,
          "rotation_deg" => 0.0
        })

      assert html =~ "Floorplan image not ready"

      reloaded_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert reloaded_level.floorplan_center_lat == nil

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, child_stop.id)
      assert reloaded.stop_lat == original_lat
      assert reloaded.stop_lon == original_lon
    end

    test "infer_alignment with three direct anchors persists inferred alignment and flashes anchor count",
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

      _stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "INFER_LV_A",
          stop_name: "Infer A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 40.0, "y" => 60.0},
          stop_lat: Decimal.new("40.7000"),
          stop_lon: Decimal.new("-74.0100")
        })

      _stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "INFER_LV_B",
          stop_name: "Infer B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 60.0, "y" => 40.0},
          stop_lat: Decimal.new("40.7200"),
          stop_lon: Decimal.new("-74.0000")
        })

      _stop_c =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "INFER_LV_C",
          stop_name: "Infer C",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0},
          stop_lat: Decimal.new("40.7100"),
          stop_lon: Decimal.new("-74.0050")
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1000, 800)

      html = render_hook(view, "infer_alignment", %{})

      assert html =~ ~r/Set lat\/lon for \d+ child stops \(3 anchors, RMSE [\d.]+ m\)/

      reloaded = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      refute is_nil(reloaded.floorplan_center_lat)
      refute is_nil(reloaded.floorplan_center_lon)
      refute is_nil(reloaded.floorplan_scale_mpp)
      refute is_nil(reloaded.floorplan_rotation_deg)
    end

    test "infer_alignment with fewer than two anchors shows error flash and leaves alignment unchanged",
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

      _lonely =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "INFER_LV_SINGLE",
          stop_name: "Infer Single",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0},
          stop_lat: Decimal.new("40.7000"),
          stop_lon: Decimal.new("-74.0000")
        })

      before = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, 1000, 800)

      html = render_hook(view, "infer_alignment", %{})

      assert html =~ "Not enough anchor stops to infer alignment"

      reloaded = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert reloaded.floorplan_center_lat == before.floorplan_center_lat
      assert reloaded.floorplan_center_lon == before.floorplan_center_lon
      assert reloaded.floorplan_scale_mpp == before.floorplan_scale_mpp
      assert reloaded.floorplan_rotation_deg == before.floorplan_rotation_deg
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
end
