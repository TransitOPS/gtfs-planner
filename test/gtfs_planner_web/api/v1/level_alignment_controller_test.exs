defmodule GtfsPlannerWeb.Api.V1.LevelAlignmentControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.{Stop, StopLevel}

  defp setup_user_with_org(_context) do
    user = user_fixture()
    org = organization_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    %{user: user, org: org}
  end

  defp authed_conn(conn, user) do
    token = Accounts.generate_api_session_token(user)

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp build_aligned_fixture(org_id, version_id, opts \\ []) do
    level = level_fixture(org_id, version_id)
    station = stop_fixture(org_id, version_id, %{location_type: 1, parent_station: nil})

    # Image center in width-normalized diagram units for a 1000x800 image is
    # (50, 40) — see FloorplanTransform's module doc.
    child =
      stop_fixture(org_id, version_id, %{
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{x: 50, y: 40}
      })

    {:ok, stop_level} =
      %StopLevel{
        stop_id: station.id,
        level_id: level.id,
        organization_id: org_id,
        gtfs_version_id: version_id,
        diagram_filename: Keyword.get(opts, :diagram_filename, "level.png")
      }
      |> Repo.insert()

    %{station: station, level: level, child: child, stop_level: stop_level}
  end

  defp alignment_url(version_id, station_id, level_id),
    do: "/api/v1/versions/#{version_id}/stations/#{station_id}/levels/#{level_id}/alignment"

  @alignment %{
    "center_lat" => 40.7128,
    "center_lon" => -74.0060,
    "scale_mpp" => 0.25,
    "rotation_deg" => 0.0
  }

  describe "update/2" do
    setup [:setup_user_with_org]

    test "saves the alignment, re-imputes nodes, and returns level + stops",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      %{station: station, level: level, child: child} =
        build_aligned_fixture(org.id, version.id)

      conn =
        conn
        |> authed_conn(user)
        |> put(alignment_url(version.id, station.id, level.id), %{
          "alignment" => @alignment,
          "image_w" => 1000,
          "image_h" => 800
        })

      assert %{"data" => data} = json_response(conn, 200)

      assert data["level"]["id"] == level.id
      fp = data["level"]["floorplan"]
      assert fp["filename"] == "level.png"
      assert fp["center_lat"] == 40.7128
      assert fp["center_lon"] == -74.0060
      assert fp["scale_mpp"] == 0.25
      assert String.contains?(fp["url"], "/uploads/diagrams/")

      # The image-center node re-imputes to the alignment anchor.
      assert [stop] = data["stops"]
      assert stop["id"] == child.id
      assert_in_delta stop["lat"], 40.7128, 1.0e-9
      assert_in_delta stop["lon"], -74.0060, 1.0e-9

      reloaded = Repo.get!(Stop, child.id)
      assert_in_delta Decimal.to_float(reloaded.stop_lat), 40.7128, 1.0e-9
    end

    test "returns 404 for a station in another org",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      _own = build_aligned_fixture(org.id, version.id)

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      %{station: other_station, level: other_level} =
        build_aligned_fixture(other_org.id, other_version.id)

      conn =
        conn
        |> authed_conn(user)
        |> put(alignment_url(other_version.id, other_station.id, other_level.id), %{
          "alignment" => @alignment,
          "image_w" => 1000,
          "image_h" => 800
        })

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 422 invalid_alignment for non-positive scale",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station, level: level} = build_aligned_fixture(org.id, version.id)

      conn =
        conn
        |> authed_conn(user)
        |> put(alignment_url(version.id, station.id, level.id), %{
          "alignment" => %{@alignment | "scale_mpp" => 0},
          "image_w" => 1000,
          "image_h" => 800
        })

      assert %{"error" => %{"code" => "invalid_alignment"}} = json_response(conn, 422)
    end

    test "returns 422 invalid_alignment when the payload shape is wrong",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station, level: level} = build_aligned_fixture(org.id, version.id)

      conn =
        conn
        |> authed_conn(user)
        |> put(alignment_url(version.id, station.id, level.id), %{"nope" => true})

      assert %{"error" => %{"code" => "invalid_alignment"}} = json_response(conn, 422)
    end

    test "returns 403 for an org member without the editor role",
         %{conn: conn, org: org} do
      non_editor = user_fixture()

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: non_editor.id,
          organization_id: org.id,
          # org admin (user management) but NOT a GTFS editor
          roles: ["pathways_studio_admin"]
        })

      version = gtfs_version_fixture(org.id)
      %{station: station, level: level} = build_aligned_fixture(org.id, version.id)

      conn =
        conn
        |> authed_conn(non_editor)
        |> put(alignment_url(version.id, station.id, level.id), %{
          "alignment" => @alignment,
          "image_w" => 1000,
          "image_h" => 800
        })

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    end

    test "returns 422 no_diagram when the level has no diagram image",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      %{station: station, level: level} =
        build_aligned_fixture(org.id, version.id, diagram_filename: nil)

      conn =
        conn
        |> authed_conn(user)
        |> put(alignment_url(version.id, station.id, level.id), %{
          "alignment" => @alignment,
          "image_w" => 1000,
          "image_h" => 800
        })

      assert %{"error" => %{"code" => "no_diagram"}} = json_response(conn, 422)
    end
  end
end
