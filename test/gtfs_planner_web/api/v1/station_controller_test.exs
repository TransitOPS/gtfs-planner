defmodule GtfsPlannerWeb.Api.V1.StationControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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
    |> put_req_header("authorization", "Bearer #{token}")
  end

  # Build a minimal station setup: one station stop + two child stops + a level + a pathway.
  defp build_station_data(org_id, version_id) do
    level = level_fixture(org_id, version_id)

    station =
      stop_fixture(org_id, version_id, %{
        location_type: 1,
        parent_station: nil
      })

    child1 =
      stop_fixture(org_id, version_id, %{
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id
      })

    child2 =
      stop_fixture(org_id, version_id, %{
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id
      })

    pathway = pathway_fixture(org_id, version_id, child1.stop_id, child2.stop_id)

    %{station: station, level: level, child1: child1, child2: child2, pathway: pathway}
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/versions/:version_id/stations (index)
  # ---------------------------------------------------------------------------

  describe "index/2" do
    setup [:setup_user_with_org]

    test "returns stations with counts for a valid version", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_data(org.id, version.id)

      conn = conn |> authed_conn(user) |> get("/api/v1/versions/#{version.id}/stations")

      assert %{"data" => data} = json_response(conn, 200)
      entry = Enum.find(data, &(&1["id"] == station.id))
      assert entry != nil
      assert entry["stop_id"] == station.stop_id
      assert entry["stop_name"] == station.stop_name
      assert entry["child_stop_count"] == 2
      assert entry["pathway_count"] == 1
      assert entry["level_count"] == 1
    end

    test "returns 404 for nonexistent version", %{conn: conn, user: user} do
      nonexistent_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{nonexistent_id}/stations")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 404 for version belonging to another org", %{conn: conn, user: user} do
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{other_version.id}/stations")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 400 for invalid UUID format", %{conn: conn, user: user} do
      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/not-a-uuid/stations")

      assert %{"error" => %{"code" => "bad_request"}} = json_response(conn, 400)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/versions/:version_id/stations/:station_id/bundle
  # ---------------------------------------------------------------------------

  describe "bundle/2" do
    setup [:setup_user_with_org]

    test "returns full bundle (station, levels, stops, pathways) for valid station", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      %{station: station, level: level, pathway: pathway} = build_station_data(org.id, version.id)

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => data} = json_response(conn, 200)

      assert data["station"]["id"] == station.id
      assert data["station"]["stop_id"] == station.stop_id
      assert data["station"]["stop_name"] == station.stop_name

      assert length(data["levels"]) == 1
      assert hd(data["levels"])["id"] == level.id

      assert length(data["stops"]) == 2

      assert length(data["pathways"]) == 1
      p = hd(data["pathways"])
      assert p["id"] == pathway.id
      assert p["pathway_id"] == pathway.pathway_id

      assert is_binary(data["downloaded_at"])
    end

    test "bundle includes field_notes and field_completed_at in pathway serialization", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      level = level_fixture(org.id, version.id)
      station = stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})

      child1 =
        stop_fixture(org.id, version.id, %{
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      child2 =
        stop_fixture(org.id, version.id, %{
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      pathway =
        pathway_fixture(org.id, version.id, child1.stop_id, child2.stop_id, %{
          field_notes: "Needs repair",
          field_completed_at: now
        })

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => data} = json_response(conn, 200)
      p = Enum.find(data["pathways"], &(&1["id"] == pathway.id))

      assert p["field_notes"] == "Needs repair"
      assert is_binary(p["field_completed_at"])
    end

    test "downloaded_at is an ISO8601 string", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_data(org.id, version.id)

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => data} = json_response(conn, 200)
      assert {:ok, _, _} = DateTime.from_iso8601(data["downloaded_at"])
    end

    test "returns 404 for station belonging to another org", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      other_station =
        stop_fixture(other_org.id, other_version.id, %{location_type: 1, parent_station: nil})

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{other_station.id}/bundle")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 400 for invalid UUID format in station_id", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/not-a-uuid/bundle")

      assert %{"error" => %{"code" => "bad_request"}} = json_response(conn, 400)
    end

    test "returns 400 for invalid UUID format in version_id", %{conn: conn, user: user} do
      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/not-a-uuid/stations/#{Ecto.UUID.generate()}/bundle")

      assert %{"error" => %{"code" => "bad_request"}} = json_response(conn, 400)
    end
  end
end
