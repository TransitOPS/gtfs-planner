defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveAlignmentPreviewTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FloorplanTransform
  alias GtfsPlanner.Repo

  @image_w 1000
  @image_h 800

  @test_alignment %{
    center_lat: 40.7128,
    center_lon: -74.0060,
    scale_mpp: 0.35,
    rotation_deg: 0.0
  }

  @anchor_points [
    %{x: 20.0, y: 30.0},
    %{x: 70.0, y: 25.0},
    %{x: 45.0, y: 75.0}
  ]

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

  defp anchor_lat_lon(point) do
    {:ok, {lat, lon}} =
      FloorplanTransform.svg_to_lat_lon(@test_alignment, @image_w, @image_h, point)

    {lat, lon}
  end

  defp read_only_boundary_snapshot(stop_level, anchor_stops) do
    stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

    %{
      alignment:
        Map.take(stop_level, [
          :floorplan_center_lat,
          :floorplan_center_lon,
          :floorplan_scale_mpp,
          :floorplan_rotation_deg
        ]),
      stop_coordinates:
        Enum.map(anchor_stops, fn stop ->
          stop = Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
          {stop.id, stop.stop_lat, stop.stop_lon}
        end),
      change_log_count: Repo.aggregate(ChangeLog, :count)
    }
  end

  defp assert_read_only_boundary(snapshot, stop_level, anchor_stops) do
    assert read_only_boundary_snapshot(stop_level, anchor_stops) == snapshot
  end

  defp refute_flash_messages(view) do
    refute has_element?(view, "#flash-info")
    refute has_element?(view, "#flash-error")
  end

  defp base_setup(_context) do
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
        stop_id: "ALIGN_STATION",
        stop_name: "Alignment Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "align_level",
        level_name: "Alignment Level",
        level_index: 0.0
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
      })

    {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "align-diagram.png")

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    }
  end

  defp create_anchor_stops(context, points_and_coords) do
    %{organization: organization, gtfs_version: gtfs_version, station: station, level: level} =
      context

    points_and_coords
    |> Enum.with_index()
    |> Enum.map(fn {{point, lat, lon}, idx} ->
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "ALIGN_ANCHOR_#{idx}",
        stop_name: "Anchor #{idx}",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => point.x, "y" => point.y},
        stop_lat: Decimal.from_float(Float.round(lat, 7)),
        stop_lon: Decimal.from_float(Float.round(lon, 7))
      })
    end)
  end

  defp mount_map_view(context) do
    %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } =
      context

    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

    render_hook(view, "switch_mode", %{"mode" => "map"})
    set_image_natural_size(view, @image_w, @image_h)

    view
  end

  describe "legacy infer_alignment event is inert" do
    setup context do
      context = base_setup(context)

      anchor_stops =
        create_anchor_stops(
          context,
          Enum.map(@anchor_points, fn point ->
            {lat, lon} = anchor_lat_lon(point)
            {point, lat, lon}
          end)
        )

      Map.put(context, :anchor_stops, anchor_stops)
    end

    test "infer_alignment with valid anchors changes no persisted fields, emits no flash/push/broadcast",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           stop_level: stop_level,
           anchor_stops: anchor_stops
         } do
      before_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      before_stops =
        Enum.map(anchor_stops, fn stop ->
          Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
        end)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      set_image_natural_size(view, @image_w, @image_h)

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stop_levels")
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stops")

      before_boundary = read_only_boundary_snapshot(stop_level, anchor_stops)
      render_hook(view, "infer_alignment", %{})
      assert_read_only_boundary(before_boundary, stop_level, anchor_stops)
      refute_flash_messages(view)

      after_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      assert after_stop_level.floorplan_center_lat == before_stop_level.floorplan_center_lat
      assert after_stop_level.floorplan_center_lon == before_stop_level.floorplan_center_lon
      assert after_stop_level.floorplan_scale_mpp == before_stop_level.floorplan_scale_mpp
      assert after_stop_level.floorplan_rotation_deg == before_stop_level.floorplan_rotation_deg

      after_stops =
        Enum.map(anchor_stops, fn stop ->
          Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
        end)

      Enum.zip(before_stops, after_stops)
      |> Enum.each(fn {before_stop, after_stop} ->
        assert after_stop.stop_lat == before_stop.stop_lat
        assert after_stop.stop_lon == before_stop.stop_lon
      end)

      refute_receive {[:stop_levels, :updated], _}, 100
      refute_receive {[:stops, :updated], _}, 100

      refute_push_event(view, "apply_preview_transform", %{})
      refute_push_event(view, "alignment_saved", %{})
    end
  end

  describe "preview_alignment success" do
    setup context do
      context = base_setup(context)

      anchor_stops =
        create_anchor_stops(
          context,
          Enum.map(@anchor_points, fn point ->
            {lat, lon} = anchor_lat_lon(point)
            {point, lat, lon}
          end)
        )

      Map.put(context, :anchor_stops, anchor_stops)
    end

    test "pushes apply_preview_transform with generation and four alignment fields, no persistence or broadcast",
         %{stop_level: stop_level, anchor_stops: anchor_stops} = context do
      before_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      before_stops =
        Enum.map(anchor_stops, fn stop -> Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id) end)

      view = mount_map_view(context)
      generation = map_generation(view)

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stop_levels")
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stops")

      before_boundary = read_only_boundary_snapshot(stop_level, anchor_stops)
      render_hook(view, "preview_alignment", %{})
      assert_read_only_boundary(before_boundary, stop_level, anchor_stops)

      assert_push_event(view, "apply_preview_transform", %{
        generation: ^generation,
        center_lat: center_lat,
        center_lon: center_lon,
        scale_mpp: scale_mpp,
        rotation_deg: rotation_deg
      })

      assert is_float(center_lat)
      assert is_float(center_lon)
      assert is_float(scale_mpp)
      assert is_float(rotation_deg)
      assert_in_delta center_lat, @test_alignment.center_lat, 0.001
      assert_in_delta center_lon, @test_alignment.center_lon, 0.001
      assert_in_delta scale_mpp, @test_alignment.scale_mpp, 0.05
      assert_in_delta rotation_deg, @test_alignment.rotation_deg, 1.0

      after_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert after_stop_level.floorplan_center_lat == before_stop_level.floorplan_center_lat
      assert after_stop_level.floorplan_center_lon == before_stop_level.floorplan_center_lon
      assert after_stop_level.floorplan_scale_mpp == before_stop_level.floorplan_scale_mpp
      assert after_stop_level.floorplan_rotation_deg == before_stop_level.floorplan_rotation_deg

      after_stops =
        Enum.map(anchor_stops, fn stop -> Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id) end)

      Enum.zip(before_stops, after_stops)
      |> Enum.each(fn {before_stop, after_stop} ->
        assert after_stop.stop_lat == before_stop.stop_lat
        assert after_stop.stop_lon == before_stop.stop_lon
      end)

      refute_receive {[:stop_levels, :updated], _}, 100
      refute_receive {[:stops, :updated], _}, 100

      refute_push_event(view, "alignment_saved", %{})
    end
  end

  describe "preview_alignment errors" do
    setup context do
      base_setup(context)
    end

    test "insufficient anchors produces no push, no flash, no writes, no broadcast",
         %{stop_level: stop_level} = context do
      anchor_stops =
        create_anchor_stops(
          context,
          Enum.take(@anchor_points, 2)
          |> Enum.map(fn point ->
            {lat, lon} = anchor_lat_lon(point)
            {point, lat, lon}
          end)
        )

      before_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      view = mount_map_view(context)

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stop_levels")
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stops")

      before_boundary = read_only_boundary_snapshot(stop_level, anchor_stops)
      render_hook(view, "preview_alignment", %{})
      assert_read_only_boundary(before_boundary, stop_level, anchor_stops)

      refute_push_event(view, "apply_preview_transform", %{})
      refute_push_event(view, "alignment_saved", %{})

      refute_flash_messages(view)

      after_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert after_stop_level.floorplan_center_lat == before_stop_level.floorplan_center_lat
      assert after_stop_level.floorplan_center_lon == before_stop_level.floorplan_center_lon
      assert after_stop_level.floorplan_scale_mpp == before_stop_level.floorplan_scale_mpp
      assert after_stop_level.floorplan_rotation_deg == before_stop_level.floorplan_rotation_deg

      refute_receive {[:stop_levels, :updated], _}, 100
      refute_receive {[:stops, :updated], _}, 100
    end

    test "high residual produces no push, no flash, no writes, no broadcast",
         %{stop_level: stop_level} = context do
      anchor_stops =
        create_anchor_stops(
          context,
          [
            {@anchor_points |> Enum.at(0), 40.7128, -74.0060},
            {@anchor_points |> Enum.at(1), 40.7129, -74.0061},
            {@anchor_points |> Enum.at(2), 40.7200, -74.0100}
          ]
        )

      before_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      view = mount_map_view(context)

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stop_levels")
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stops")

      before_boundary = read_only_boundary_snapshot(stop_level, anchor_stops)
      render_hook(view, "preview_alignment", %{})
      assert_read_only_boundary(before_boundary, stop_level, anchor_stops)

      refute_push_event(view, "apply_preview_transform", %{})
      refute_push_event(view, "alignment_saved", %{})

      refute_flash_messages(view)

      after_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert after_stop_level.floorplan_center_lat == before_stop_level.floorplan_center_lat
      assert after_stop_level.floorplan_center_lon == before_stop_level.floorplan_center_lon
      assert after_stop_level.floorplan_scale_mpp == before_stop_level.floorplan_scale_mpp
      assert after_stop_level.floorplan_rotation_deg == before_stop_level.floorplan_rotation_deg

      refute_receive {[:stop_levels, :updated], _}, 100
      refute_receive {[:stops, :updated], _}, 100
    end

    test "invalid image dimensions produces no push, no flash, no writes, no broadcast",
         %{stop_level: stop_level} = context do
      anchor_stops =
        create_anchor_stops(
          context,
          Enum.map(@anchor_points, fn point ->
            {lat, lon} = anchor_lat_lon(point)
            {point, lat, lon}
          end)
        )

      before_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      %{
        conn: conn,
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      } =
        context

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stop_levels")
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stops")

      before_boundary = read_only_boundary_snapshot(stop_level, anchor_stops)
      render_hook(view, "preview_alignment", %{})
      assert_read_only_boundary(before_boundary, stop_level, anchor_stops)

      refute_push_event(view, "apply_preview_transform", %{})
      refute_push_event(view, "alignment_saved", %{})

      refute_flash_messages(view)

      after_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert after_stop_level.floorplan_center_lat == before_stop_level.floorplan_center_lat
      assert after_stop_level.floorplan_center_lon == before_stop_level.floorplan_center_lon
      assert after_stop_level.floorplan_scale_mpp == before_stop_level.floorplan_scale_mpp
      assert after_stop_level.floorplan_rotation_deg == before_stop_level.floorplan_rotation_deg

      refute_receive {[:stop_levels, :updated], _}, 100
      refute_receive {[:stops, :updated], _}, 100
    end
  end

  describe "restore_saved_alignment" do
    setup context do
      context = base_setup(context)

      anchor_stops =
        create_anchor_stops(
          context,
          Enum.map(@anchor_points, fn point ->
            {lat, lon} = anchor_lat_lon(point)
            {point, lat, lon}
          end)
        )

      Map.put(context, :anchor_stops, anchor_stops)
    end

    test "pushes restore_saved_transform with current generation, no persistence or broadcast",
         %{stop_level: stop_level, anchor_stops: anchor_stops} = context do
      before_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      view = mount_map_view(context)
      generation = map_generation(view)

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stop_levels")
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stops")

      before_boundary = read_only_boundary_snapshot(stop_level, anchor_stops)
      render_hook(view, "restore_saved_alignment", %{})
      assert_read_only_boundary(before_boundary, stop_level, anchor_stops)

      assert_push_event(view, "restore_saved_transform", %{generation: ^generation})

      refute_push_event(view, "apply_preview_transform", %{})
      refute_push_event(view, "alignment_saved", %{})

      after_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert after_stop_level.floorplan_center_lat == before_stop_level.floorplan_center_lat
      assert after_stop_level.floorplan_center_lon == before_stop_level.floorplan_center_lon
      assert after_stop_level.floorplan_scale_mpp == before_stop_level.floorplan_scale_mpp
      assert after_stop_level.floorplan_rotation_deg == before_stop_level.floorplan_rotation_deg

      refute_receive {[:stop_levels, :updated], _}, 100
      refute_receive {[:stops, :updated], _}, 100
    end
  end

  describe "save_alignment synchronization" do
    setup context do
      context = base_setup(context)

      anchor_stops =
        create_anchor_stops(
          context,
          Enum.map(@anchor_points, fn point ->
            {lat, lon} = anchor_lat_lon(point)
            {point, lat, lon}
          end)
        )

      Map.put(context, :anchor_stops, anchor_stops)
    end

    test "successful save pushes alignment_saved with generation and persisted fields, clears preview",
         %{stop_level: stop_level} = context do
      view = mount_map_view(context)
      generation = map_generation(view)

      render_hook(view, "preview_alignment", %{})
      assert has_element?(view, "#auto-alignment-status")

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stop_levels")

      render_hook(view, "save_alignment", %{
        "generation" => generation,
        "center_lat" => 40.7128,
        "center_lon" => -74.0060,
        "scale_mpp" => 0.35,
        "rotation_deg" => 0.0
      })

      assert_push_event(view, "alignment_saved", %{
        generation: ^generation,
        center_lat: center_lat,
        center_lon: center_lon,
        scale_mpp: scale_mpp,
        rotation_deg: rotation_deg
      })

      assert_in_delta center_lat, 40.7128, 0.0001
      assert_in_delta center_lon, -74.0060, 0.0001
      assert_in_delta scale_mpp, 0.35, 0.001
      assert_in_delta rotation_deg, 0.0, 0.001

      after_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert_in_delta after_stop_level.floorplan_center_lat, 40.7128, 0.0001
      assert_in_delta after_stop_level.floorplan_center_lon, -74.0060, 0.0001
      assert_in_delta after_stop_level.floorplan_scale_mpp, 0.35, 0.001
      assert_in_delta after_stop_level.floorplan_rotation_deg, 0.0, 0.001
    end

    test "rejected save retains preview state and does not push alignment_saved",
         %{stop_level: stop_level} = context do
      before_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      view = mount_map_view(context)
      generation = map_generation(view)

      render_hook(view, "preview_alignment", %{})
      assert has_element?(view, "#auto-alignment-status")

      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stop_levels")

      render_hook(view, "save_alignment", %{
        "generation" => generation,
        "center_lat" => 999.0,
        "center_lon" => -74.0060,
        "scale_mpp" => 0.35,
        "rotation_deg" => 0.0
      })

      refute_push_event(view, "alignment_saved", %{})
      assert has_element?(view, "#auto-alignment-status")

      after_stop_level = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)
      assert after_stop_level.floorplan_center_lat == before_stop_level.floorplan_center_lat
      assert after_stop_level.floorplan_center_lon == before_stop_level.floorplan_center_lon
      assert after_stop_level.floorplan_scale_mpp == before_stop_level.floorplan_scale_mpp
      assert after_stop_level.floorplan_rotation_deg == before_stop_level.floorplan_rotation_deg
    end
  end

  describe "assisted alignment cluster rendering" do
    setup context do
      context = base_setup(context)

      anchor_stops =
        create_anchor_stops(
          context,
          Enum.map(@anchor_points, fn point ->
            {lat, lon} = anchor_lat_lon(point)
            {point, lat, lon}
          end)
        )

      Map.put(context, :anchor_stops, anchor_stops)
    end

    test "idle state renders helper copy with anchor count and enabled preview button", context do
      view = mount_map_view(context)

      assert has_element?(view, "#map-alignment-preview-auto")
      assert has_element?(view, "#map-alignment-assisted")
      assert has_element?(view, "#map-alignment-assisted", "Uses 3 stops")

      assert has_element?(
               view,
               "fieldset#map-alignment-transform-controls #map-alignment-restore-saved"
             )

      assert has_element?(
               view,
               "#map-alignment-preview-auto.btn-outline.btn-primary[phx-disable-with='Previewing…']"
             )

      refute has_element?(view, "#auto-alignment-status")
      refute has_element?(view, "#auto-alignment-error")
    end

    test "preview button is disabled when map state is fatal", context do
      view = mount_map_view(context)

      render_hook(view, "map_state", %{
        "generation" => map_generation(view),
        "state" => "fatal"
      })

      assert has_element?(view, "#map-alignment-preview-auto[disabled]")

      assert has_element?(
               view,
               "#map-alignment-preview-auto[aria-describedby='map-auto-alignment-disabled-reason']"
             )

      assert has_element?(
               view,
               "#map-auto-alignment-disabled-reason",
               "Retry the map before previewing auto-alignment"
             )
    end

    test "preview button is not disabled solely for low anchor count",
         %{anchor_stops: anchor_stops} = context do
      anchor_stops
      |> Enum.drop(1)
      |> Enum.each(&Repo.delete!/1)

      view = mount_map_view(context)

      assert has_element?(view, "#map-alignment-assisted", "Uses 1 stops")
      refute has_element?(view, "#map-alignment-preview-auto[disabled]")
    end

    test "successful preview renders unsaved status with one-decimal fit and anchor count",
         context do
      view = mount_map_view(context)

      render_hook(view, "preview_alignment", %{})

      assert has_element?(
               view,
               "#auto-alignment-status[role='status'][aria-live='polite'][aria-describedby='auto-alignment-fit-value auto-alignment-fit-description']",
               "Unsaved auto-alignment preview"
             )

      assert has_element?(view, "#auto-alignment-fit-value", "Estimated fit error")
      assert has_element?(view, "#auto-alignment-fit-value", "0.0 m")

      assert has_element?(
               view,
               "#auto-alignment-fit-description",
               "Computed from 3 anchor stops. RMSE measures the typical anchor mismatch; lower is better."
             )
    end

    test "restore button clears ready status from DOM", context do
      view = mount_map_view(context)

      render_hook(view, "preview_alignment", %{})
      assert has_element?(view, "#auto-alignment-status")

      render_hook(view, "restore_saved_alignment", %{})
      refute has_element?(view, "#auto-alignment-status")
    end

    test "Reset control is absent from transform controls", context do
      view = mount_map_view(context)

      refute has_element?(view, "[data-map-transform-action='reset']")
      refute has_element?(view, "#map-transform-reset-fine")
    end

    test "successful save clears preview status from DOM", context do
      view = mount_map_view(context)
      generation = map_generation(view)

      render_hook(view, "preview_alignment", %{})
      assert has_element?(view, "#auto-alignment-status")

      render_hook(view, "save_alignment", %{
        "generation" => generation,
        "center_lat" => 40.7128,
        "center_lon" => -74.0060,
        "scale_mpp" => 0.35,
        "rotation_deg" => 0.0
      })

      refute has_element?(view, "#auto-alignment-status")
    end
  end

  describe "assisted alignment error rendering" do
    setup context do
      base_setup(context)
    end

    test "insufficient anchors renders inline error with recovery copy", context do
      _anchor_stops =
        create_anchor_stops(
          context,
          Enum.take(@anchor_points, 2)
          |> Enum.map(fn point ->
            {lat, lon} = anchor_lat_lon(point)
            {point, lat, lon}
          end)
        )

      view = mount_map_view(context)

      html = render_hook(view, "preview_alignment", %{})

      assert has_element?(view, "#auto-alignment-error[role='alert']")
      assert html =~ "Not enough anchor stops to infer alignment"

      assert html =~
               "Place more stops with both a floorplan position and map coordinates, then try again."

      refute has_element?(view, "#auto-alignment-status")
    end

    test "high residual renders inline error with recovery copy", context do
      _anchor_stops =
        create_anchor_stops(
          context,
          [
            {@anchor_points |> Enum.at(0), 40.7128, -74.0060},
            {@anchor_points |> Enum.at(1), 40.7129, -74.0061},
            {@anchor_points |> Enum.at(2), 40.7200, -74.0100}
          ]
        )

      view = mount_map_view(context)

      html = render_hook(view, "preview_alignment", %{})

      assert has_element?(view, "#auto-alignment-error[role='alert']")
      assert html =~ "Inferred alignment residual exceeds tolerance"
      assert html =~ "Check the anchor stops"
    end
  end

  describe "alignment_preview_adjusted dirty handling" do
    setup context do
      context = base_setup(context)

      anchor_stops =
        create_anchor_stops(
          context,
          Enum.map(@anchor_points, fn point ->
            {lat, lon} = anchor_lat_lon(point)
            {point, lat, lon}
          end)
        )

      Map.put(context, :anchor_stops, anchor_stops)
    end

    test "current-generation dirty event clears ready preview from DOM", context do
      view = mount_map_view(context)
      generation = map_generation(view)

      render_hook(view, "preview_alignment", %{})
      assert has_element?(view, "#auto-alignment-status")

      render_hook(view, "alignment_preview_adjusted", %{"generation" => generation})
      refute has_element?(view, "#auto-alignment-status")
    end

    test "stale generation dirty event leaves ready preview visible", context do
      view = mount_map_view(context)

      render_hook(view, "preview_alignment", %{})
      assert has_element?(view, "#auto-alignment-status")

      render_hook(view, "alignment_preview_adjusted", %{"generation" => "stale-generation"})
      assert has_element?(view, "#auto-alignment-status")
    end

    test "malformed payload is a no-op", context do
      view = mount_map_view(context)

      render_hook(view, "preview_alignment", %{})
      assert has_element?(view, "#auto-alignment-status")

      render_hook(view, "alignment_preview_adjusted", %{})
      assert has_element?(view, "#auto-alignment-status")
    end

    test "dirty event with no active preview is a no-op", context do
      view = mount_map_view(context)
      generation = map_generation(view)

      render_hook(view, "alignment_preview_adjusted", %{"generation" => generation})
      refute has_element?(view, "#auto-alignment-status")
    end

    test "level switch clears preview and rotates generation", context do
      %{organization: organization, gtfs_version: gtfs_version, station: station} = context

      {:ok, level2} =
        Gtfs.create_level(%{
          level_id: "align_level_2",
          level_name: "Alignment Level 2",
          level_index: 1.0,
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id
        })

      {:ok, _stop_level2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level2.id,
          diagram_filename: "align-diagram-2.png"
        })

      view = mount_map_view(context)
      generation_before = map_generation(view)

      render_hook(view, "preview_alignment", %{})
      assert has_element?(view, "#auto-alignment-status")

      render_hook(view, "switch_level", %{"level_id" => level2.id})

      refute has_element?(view, "#auto-alignment-status")
      generation_after = map_generation(view)
      assert generation_after != generation_before
    end

    test "mode switch clears preview", context do
      view = mount_map_view(context)

      render_hook(view, "preview_alignment", %{})
      assert has_element?(view, "#auto-alignment-status")

      render_hook(view, "switch_mode", %{"mode" => "view"})
      refute has_element?(view, "#auto-alignment-status")
    end
  end
end
