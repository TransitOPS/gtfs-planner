defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveAlignmentPreviewTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
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

  describe "legacy infer_alignment event is inert" do
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

      anchor_stops =
        @anchor_points
        |> Enum.with_index()
        |> Enum.map(fn {point, idx} ->
          {lat, lon} = anchor_lat_lon(point)

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

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level,
        stop_level: stop_level,
        anchor_stops: anchor_stops
      }
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

      render_hook(view, "infer_alignment", %{})

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
end
