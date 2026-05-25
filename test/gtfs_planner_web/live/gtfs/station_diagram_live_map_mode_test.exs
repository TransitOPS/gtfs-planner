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

      assert has_element?(view, "button[phx-value-mode='map']", "Map")
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

      assert has_element?(view, "button[phx-value-mode='map'][disabled]")
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

    test "initializes reference overlay assigns on map mode entry and level switch", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: middle_level,
      stop_level: middle_stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(middle_stop_level, "map-diagram.png")

      below_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "map_level_below",
          level_name: "Map Level Below",
          level_index: -1.0
        })

      above_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "map_level_above",
          level_name: "Map Level Above",
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

      {:ok, _} = Gtfs.update_stop_level_alignment(middle_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_alignment(below_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_alignment(above_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_diagram(below_stop_level, "below-map-diagram.png")
      {:ok, _} = Gtfs.update_stop_level_diagram(above_stop_level, "above-map-diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == nil
      assert assigns.reference_stop_level == nil
      assert assigns.reference_level_index == nil
      assert assigns.show_reference_overlay == false

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == nil
      assert assigns.reference_stop_level == nil
      assert assigns.show_reference_overlay == false

      assert has_element?(view, "#reference-overlay-level-form")
      assert has_element?(view, "#reference-overlay-level-form option[value='']")

      assert has_element?(
               view,
               "#reference-overlay-level-form option[value=''][selected]",
               "Select Level Overlay"
             )

      assert has_element?(view, "#reference-overlay-level-form button[disabled]", "Show")

      refute has_element?(
               view,
               "#reference-overlay-level-form option[value='#{middle_level.id}']"
             )

      assert has_element?(view, "#reference-overlay-level-form option[value='#{below_level.id}']")
      assert has_element?(view, "#reference-overlay-level-form option[value='#{above_level.id}']")

      render_hook(view, "switch_level", %{"level_id" => above_level.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_level.id == above_level.id
      assert assigns.reference_level_id == nil
      assert assigns.reference_stop_level == nil
      assert assigns.show_reference_overlay == false

      assert has_element?(view, "#reference-overlay-level-form")

      assert has_element?(
               view,
               "#reference-overlay-level-form option[value='#{below_level.id}']"
             )

      refute has_element?(
               view,
               "#reference-overlay-level-form option[value='#{above_level.id}']"
             )
    end

    test "refreshes stop-level cache and selectable reference levels after level removal in map mode",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: _middle_level,
           stop_level: middle_stop_level
         } do
      {:ok, _} = Gtfs.update_stop_level_diagram(middle_stop_level, "map-diagram.png")

      below_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "cache_refresh_below",
          level_name: "Cache Refresh Below",
          level_index: -1.0
        })

      above_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "cache_refresh_above",
          level_name: "Cache Refresh Above",
          level_index: 1.0
        })

      {:ok, _below_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: below_level.id
        })

      {:ok, _above_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: above_level.id
        })

      below_stop_level =
        Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, below_level.id)

      above_stop_level =
        Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, above_level.id)

      {:ok, _} = Gtfs.update_stop_level_diagram(below_stop_level, "cache-refresh-below-map.png")
      {:ok, _} = Gtfs.update_stop_level_diagram(above_stop_level, "cache-refresh-above-map.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert Enum.any?(assigns.selectable_reference_stop_levels, &(&1.level_id == above_level.id))
      assert Map.has_key?(assigns.station_stop_levels_cache.by_level_id, above_level.id)

      render_hook(view, "remove_level_from_station", %{"id" => above_level.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_level.id == below_level.id
      refute Map.has_key?(assigns.station_stop_levels_cache.by_level_id, above_level.id)
      assert length(assigns.station_stop_levels_cache.ordered) == 2

      refute Enum.any?(assigns.selectable_reference_stop_levels, &(&1.level_id == above_level.id))
    end

    test "select_reference_overlay_level excludes active level and clears when switched active",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: _middle_level,
           stop_level: middle_stop_level
         } do
      {:ok, _} = Gtfs.update_stop_level_diagram(middle_stop_level, "map-diagram.png")

      below_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "toggle_level_below",
          level_name: "Toggle Level Below",
          level_index: -1.0
        })

      above_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "toggle_level_above",
          level_name: "Toggle Level Above",
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

      {:ok, _} = Gtfs.update_stop_level_alignment(below_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_diagram(below_stop_level, "below-overlay.png")

      {:ok, _} = Gtfs.update_stop_level_alignment(above_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_diagram(above_stop_level, "above-overlay.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == nil
      assert assigns.reference_stop_level == nil
      assert assigns.show_reference_overlay == false

      refute Enum.any?(
               assigns.selectable_reference_stop_levels,
               &(&1.level_id == middle_stop_level.level_id)
             )

      render_hook(view, "select_reference_overlay_level", %{"level_id" => below_level.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == below_level.id
      assert assigns.reference_stop_level.level_id == below_level.id
      assert assigns.reference_level_index == -1.0
      assert assigns.show_reference_overlay == false

      refute Enum.any?(
               assigns.selectable_reference_stop_levels,
               &(&1.level_id == middle_stop_level.level_id)
             )

      render_hook(view, "select_reference_overlay_level", %{"level_id" => above_level.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == above_level.id
      assert assigns.reference_stop_level.level_id == above_level.id
      assert assigns.reference_level_index == 1.0
      assert assigns.show_reference_overlay == false

      refute Enum.any?(
               assigns.selectable_reference_stop_levels,
               &(&1.level_id == middle_stop_level.level_id)
             )

      render_hook(view, "switch_level", %{"level_id" => above_level.id})
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_level.id == above_level.id
      assert assigns.reference_level_id == nil
      assert assigns.reference_stop_level == nil
      assert assigns.reference_level_index == nil
      assert assigns.show_reference_overlay == false
      refute Enum.any?(assigns.selectable_reference_stop_levels, &(&1.level_id == above_level.id))
    end

    test "single selectable reference level starts on prompt and enables toggle after selection",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           stop_level: middle_stop_level
         } do
      {:ok, _} = Gtfs.update_stop_level_diagram(middle_stop_level, "map-diagram.png")

      other_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "single_reference_other",
          level_name: "Single Reference Other",
          level_index: 1.0
        })

      {:ok, other_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: other_level.id
        })

      alignment_attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.35,
        floorplan_rotation_deg: 0.0
      }

      {:ok, _} = Gtfs.update_stop_level_alignment(other_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_diagram(other_stop_level, "single-reference-other.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == nil
      assert assigns.reference_stop_level == nil
      assert has_element?(view, "#reference-overlay-level-form option[value=''][selected]")
      assert has_element?(view, "#reference-overlay-level-form button[disabled]", "Show")

      render_hook(view, "select_reference_overlay_level", %{"level_id" => other_level.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == other_level.id
      assert assigns.reference_stop_level.level_id == other_level.id
      refute has_element?(view, "#reference-overlay-level-form button[disabled]", "Show")
    end

    test "reference overlay options exclude levels without diagrams", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: middle_stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(middle_stop_level, "map-diagram.png")

      with_diagram_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "reference_with_diagram",
          level_name: "Reference With Diagram",
          level_index: 1.0
        })

      without_diagram_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "reference_without_diagram",
          level_name: "Reference Without Diagram",
          level_index: -1.0
        })

      {:ok, with_diagram_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: with_diagram_level.id
        })

      {:ok, _without_diagram_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: without_diagram_level.id
        })

      alignment_attrs = %{
        floorplan_center_lat: 40.7128,
        floorplan_center_lon: -74.006,
        floorplan_scale_mpp: 0.35,
        floorplan_rotation_deg: 0.0
      }

      {:ok, _} = Gtfs.update_stop_level_alignment(with_diagram_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_diagram(with_diagram_stop_level, "reference.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assigns = :sys.get_state(view.pid).socket.assigns

      assert Enum.any?(
               assigns.selectable_reference_stop_levels,
               &(&1.level_id == with_diagram_level.id)
             )

      refute Enum.any?(
               assigns.selectable_reference_stop_levels,
               &(&1.level_id == without_diagram_level.id)
             )

      assert has_element?(
               view,
               "#reference-overlay-level-form option[value='#{with_diagram_level.id}']"
             )

      refute has_element?(
               view,
               "#reference-overlay-level-form option[value='#{without_diagram_level.id}']"
             )
    end

    test "select_reference_overlay_level normalizes unaligned reference but keeps overlay hidden until toggled",
         %{
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
          level_id: "reentry_below",
          level_name: "Re-entry Below",
          level_index: -1.0
        })

      above_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "reentry_above",
          level_name: "Re-entry Above",
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

      {:ok, _} = Gtfs.update_stop_level_alignment(below_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_diagram(below_stop_level, "reentry-below.png")

      {:ok, _} = Gtfs.update_stop_level_alignment(above_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_diagram(above_stop_level, "reentry-above.png")

      {:ok, _} =
        Gtfs.update_stop_level_alignment(above_stop_level, %{
          floorplan_center_lat: nil,
          floorplan_center_lon: nil,
          floorplan_scale_mpp: nil,
          floorplan_rotation_deg: nil
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      render_hook(view, "select_reference_overlay_level", %{"level_id" => above_level.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == above_level.id
      assert assigns.reference_stop_level.level_id == above_level.id
      assert assigns.show_reference_overlay == false

      assert has_element?(
               view,
               ".map-canvas[data-show-reference-overlay='false']"
             )

      html = render(view)

      assert html =~ "data-show-reference-overlay=\"false\""
      assert is_number(assigns.reference_stop_level.floorplan_center_lat)
      assert is_number(assigns.reference_stop_level.floorplan_center_lon)
      assert is_number(assigns.reference_stop_level.floorplan_scale_mpp)
      assert is_number(assigns.reference_stop_level.floorplan_rotation_deg)
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

      assert has_element?(view, "button[phx-value-mode='map'].bg-blue-600")
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

      assert has_element?(view, ".map-canvas[data-show-reference-overlay='false']")

      assert has_element?(view, ".map-canvas #map-alignment-leaflet")
      assert has_element?(view, "#map-alignment-overlay img[alt='Level floorplan']")
      assert has_element?(view, "#map-alignment-pins-reference[data-overlay-role='reference']")
      assert has_element?(view, "#map-alignment-pins-active[data-overlay-role='active']")
    end

    test "reference overlay stays read-only while active overlay is editable", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: middle_level,
      stop_level: middle_stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(middle_stop_level, "map-diagram.png")

      below_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "map_ref_level_below",
          level_name: "Map Ref Level Below",
          level_index: -1.0
        })

      above_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "map_ref_level_above",
          level_name: "Map Ref Level Above",
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

      {:ok, _} = Gtfs.update_stop_level_alignment(middle_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_alignment(below_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_alignment(above_stop_level, alignment_attrs)
      {:ok, _} = Gtfs.update_stop_level_diagram(below_stop_level, "below-reference.png")
      {:ok, _} = Gtfs.update_stop_level_diagram(above_stop_level, "above-reference.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "switch_level", %{"level_id" => middle_level.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_level.id == middle_level.id

      render_hook(view, "select_reference_overlay_level", %{"level_id" => above_level.id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == above_level.id
      assert assigns.show_reference_overlay == false

      refute has_element?(
               view,
               ".map-canvas[data-show-reference-overlay='true'][data-reference-center-lat][data-reference-center-lon][data-reference-scale-mpp][data-reference-rotation-deg]"
             )

      render_hook(view, "toggle_reference_overlay", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reference_level_id == above_level.id
      assert assigns.show_reference_overlay == true

      assert has_element?(
               view,
               ".map-canvas[data-show-reference-overlay='true'][data-reference-center-lat][data-reference-center-lon][data-reference-scale-mpp][data-reference-rotation-deg]"
             )

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
      assert has_element?(view, "#map-alignment-save")
      assert has_element?(view, "#map-alignment-apply")
      refute has_element?(view, "#map-alignment-infer")
      refute has_element?(view, "#map-canvas-wrapper", "Infer from anchors")
      assert has_element?(view, "#map-alignment-rotate-handle")
      assert has_element?(view, "#map-alignment-scale-handle")
      refute has_element?(view, "#map-alignment-reset")
      refute has_element?(view, "#map-alignment-clear")
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

      render_hook(view, "save_alignment", %{
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

    test "saved alignment is reflected when that level is selected as reference after switching levels",
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

      render_hook(view, "save_alignment", %{
        "center_lat" => 40.7128,
        "center_lon" => -74.0060,
        "scale_mpp" => 0.35,
        "rotation_deg" => 15.5
      })

      render_hook(view, "switch_level", %{"level_id" => above_level.id})
      render_hook(view, "select_reference_overlay_level", %{"level_id" => middle_level.id})

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.reference_level_id == middle_level.id
      assert assigns.reference_stop_level.level_id == middle_level.id
      assert_in_delta assigns.reference_stop_level.floorplan_center_lat, 40.7128, 1.0e-6
      assert_in_delta assigns.reference_stop_level.floorplan_center_lon, -74.0060, 1.0e-6
      assert_in_delta assigns.reference_stop_level.floorplan_scale_mpp, 0.35, 1.0e-6
      assert_in_delta assigns.reference_stop_level.floorplan_rotation_deg, 15.5, 1.0e-6

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
        render_hook(view, "save_alignment", %{
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
      render_hook(view, "set_image_natural_size", %{"w" => 1024, "h" => 768})

      assert has_element?(view, "#map-alignment-apply")
      refute has_element?(view, "#map-alignment-apply[disabled]")
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
      render_hook(view, "set_image_natural_size", %{"w" => 1024, "h" => 768})

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
      render_hook(view, "set_image_natural_size", %{"w" => 1000, "h" => 800})

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
      render_hook(view, "set_image_natural_size", %{"w" => 1024, "h" => 768})

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
      render_hook(view, "set_image_natural_size", %{"w" => 1024.7, "h" => 768.4})

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
      render_hook(view, "set_image_natural_size", %{"w" => 0, "h" => -5})

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
      render_hook(view, "set_image_natural_size", %{"w" => 1024, "h" => 768})

      html =
        render_hook(view, "save_and_apply_alignment", %{
          "center_lat" => 40.7128,
          "center_lon" => -74.0060,
          "scale_mpp" => 0.35,
          "rotation_deg" => 0.0
        })

      assert html =~ "Set lat/lon for 1 child stops"

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
        render_hook(view, "save_and_apply_alignment", %{
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
      render_hook(view, "set_image_natural_size", %{"w" => 1000, "h" => 800})

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
      render_hook(view, "set_image_natural_size", %{"w" => 1000, "h" => 800})

      html = render_hook(view, "infer_alignment", %{})

      assert html =~ "Not enough anchor stops to infer alignment"

      reloaded = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert reloaded.floorplan_center_lat == before.floorplan_center_lat
      assert reloaded.floorplan_center_lon == before.floorplan_center_lon
      assert reloaded.floorplan_scale_mpp == before.floorplan_scale_mpp
      assert reloaded.floorplan_rotation_deg == before.floorplan_rotation_deg
    end

  end
end