defmodule GtfsPlannerWeb.Api.V1.SyncControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Pathway

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_user_with_org(_context) do
    user = user_fixture()
    org = organization_fixture()

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    %{user: user, org: org, membership: membership}
  end

  defp authed_conn(conn, user) do
    token = Accounts.generate_api_session_token(user)

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp build_station_with_pathway(org_id, version_id) do
    level = level_fixture(org_id, version_id)
    station = stop_fixture(org_id, version_id, %{location_type: 1, parent_station: nil})

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

    %{station: station, child1: child1, child2: child2, pathway: pathway}
  end

  defp sync_url(version_id, station_id),
    do: "/api/v1/versions/#{version_id}/stations/#{station_id}/sync"

  # ---------------------------------------------------------------------------
  # POST /api/v1/versions/:version_id/stations/:station_id/sync
  # ---------------------------------------------------------------------------

  describe "create/2" do
    setup [:setup_user_with_org]

    test "returns 401 before organization or editor authorization without a session", %{conn: conn} do
      conn = post(conn, sync_url(Ecto.UUID.generate(), Ecto.UUID.generate()), %{"pathways" => []})

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "rejects a selected non-editor membership without mutating pathways", %{
      conn: conn,
      user: user,
      org: org,
      membership: membership
    } do
      version = gtfs_version_fixture(org.id)
      %{station: station, pathway: pathway} = build_station_with_pathway(org.id, version.id)

      {:ok, _membership} =
        membership
        |> Ecto.Changeset.change(%{roles: []})
        |> Repo.update()

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), %{
          "pathways" => [%{"id" => pathway.id, "traversal_time" => 45}]
        })

      assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
      assert Repo.get!(Pathway, pathway.id).traversal_time != 45
    end

    test "keeps protected reads available to an active non-editor membership", %{
      conn: conn,
      user: user,
      membership: membership
    } do
      {:ok, _membership} =
        membership
        |> Ecto.Changeset.change(%{roles: []})
        |> Repo.update()

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions")

      assert %{"data" => _versions} = json_response(conn, 200)
    end

    test "syncs editable fields successfully (traversal_time, signposted_as, field_notes, field_completed_at)",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station, pathway: pathway} = build_station_with_pathway(org.id, version.id)

      now_iso = "2025-06-01T12:00:00Z"

      payload = %{
        "pathways" => [
          %{
            "id" => pathway.id,
            "traversal_time" => 45,
            "signposted_as" => "To Exit",
            "field_notes" => "Handrail broken",
            "field_completed_at" => now_iso
          }
        ]
      }

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["synced_count"] == 1
      refute Map.has_key?(data, "errors")

      updated = Repo.get!(Pathway, pathway.id)
      assert updated.traversal_time == 45
      assert updated.signposted_as == "To Exit"
      assert updated.field_notes == "Handrail broken"
      assert %DateTime{} = updated.field_completed_at
    end

    test "does not modify read-only fields (pathway_mode)",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      %{station: station, pathway: pathway} =
        build_station_with_pathway(org.id, version.id)

      original_mode = pathway.pathway_mode

      payload = %{
        "pathways" => [
          %{
            "id" => pathway.id,
            "pathway_mode" => 7
          }
        ]
      }

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["synced_count"] == 1

      unchanged = Repo.get!(Pathway, pathway.id)
      assert unchanged.pathway_mode == original_mode
    end

    test "endpoint pair matching stored order is a no-op (accepted)",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      %{station: station, pathway: pathway, child1: child1, child2: child2} =
        build_station_with_pathway(org.id, version.id)

      payload = %{
        "pathways" => [
          %{
            "id" => pathway.id,
            "from_stop_id" => child1.stop_id,
            "to_stop_id" => child2.stop_id,
            "field_notes" => "unchanged endpoints"
          }
        ]
      }

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["synced_count"] == 1
      refute Map.has_key?(data, "errors")

      updated = Repo.get!(Pathway, pathway.id)
      assert updated.from_stop_id == child1.stop_id
      assert updated.to_stop_id == child2.stop_id
      assert updated.field_notes == "unchanged endpoints"
    end

    test "swapped endpoint pair reverses the pathway (with other fields, atomically)",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      %{station: station, pathway: pathway, child1: child1, child2: child2} =
        build_station_with_pathway(org.id, version.id)

      payload = %{
        "pathways" => [
          %{
            "id" => pathway.id,
            "from_stop_id" => child2.stop_id,
            "to_stop_id" => child1.stop_id,
            "signposted_as" => "Now the other way",
            "stair_count" => -4
          }
        ]
      }

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["synced_count"] == 1
      refute Map.has_key?(data, "errors")

      updated = Repo.get!(Pathway, pathway.id)
      assert updated.from_stop_id == child2.stop_id
      assert updated.to_stop_id == child1.stop_id
      assert updated.signposted_as == "Now the other way"
      assert updated.stair_count == -4
    end

    test "foreign endpoint pair is rejected with invalid_endpoints and nothing applied",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      %{station: station, pathway: pathway, child1: child1, child2: child2} =
        build_station_with_pathway(org.id, version.id)

      payload = %{
        "pathways" => [
          %{
            "id" => pathway.id,
            "from_stop_id" => "somewhere_else",
            "to_stop_id" => child2.stop_id,
            "field_notes" => "must not be applied"
          }
        ]
      }

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["synced_count"] == 0
      assert [%{"id" => _, "code" => "invalid_endpoints"}] = data["errors"]

      unchanged = Repo.get!(Pathway, pathway.id)
      assert unchanged.from_stop_id == child1.stop_id
      assert unchanged.to_stop_id == child2.stop_id
      assert unchanged.field_notes != "must not be applied"
    end

    test "partial endpoint pair (only one field) is rejected",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      %{station: station, pathway: pathway, child2: child2} =
        build_station_with_pathway(org.id, version.id)

      payload = %{
        "pathways" => [
          %{"id" => pathway.id, "from_stop_id" => child2.stop_id}
        ]
      }

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["synced_count"] == 0
      assert [%{"code" => "invalid_endpoints"}] = data["errors"]
    end

    test "returns error for pathway ID belonging to another org",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_with_pathway(org.id, version.id)

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)
      other_level = level_fixture(other_org.id, other_version.id)

      other_child1 =
        stop_fixture(other_org.id, other_version.id, %{
          location_type: 0,
          level_id: other_level.level_id
        })

      other_child2 =
        stop_fixture(other_org.id, other_version.id, %{
          location_type: 0,
          level_id: other_level.level_id
        })

      other_pathway =
        pathway_fixture(
          other_org.id,
          other_version.id,
          other_child1.stop_id,
          other_child2.stop_id
        )

      payload = %{
        "pathways" => [
          %{"id" => other_pathway.id, "traversal_time" => 30}
        ]
      }

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["synced_count"] == 0
      assert [error] = data["errors"]
      assert error["id"] == other_pathway.id
      assert error["code"] == "not_found"
    end

    test "returns error for invalid UUID in pathway list",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_with_pathway(org.id, version.id)

      payload = %{
        "pathways" => [
          %{"id" => "not-a-uuid", "traversal_time" => 30}
        ]
      }

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["synced_count"] == 0
      assert [error] = data["errors"]
      assert error["id"] == "not-a-uuid"
      assert error["code"] == "invalid_id"
    end

    test "returns 400 when pathways array is missing",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_with_pathway(org.id, version.id)

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), %{"other_key" => "value"})

      assert %{"error" => %{"code" => "bad_request"}} = json_response(conn, 400)
    end

    test "partial failure: some pathways succeed, some fail",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      %{station: station, pathway: good_pathway} =
        build_station_with_pathway(org.id, version.id)

      payload = %{
        "pathways" => [
          %{"id" => good_pathway.id, "traversal_time" => 90},
          %{"id" => "not-a-uuid", "traversal_time" => 30},
          %{"id" => Ecto.UUID.generate(), "traversal_time" => 15}
        ]
      }

      conn =
        conn
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["synced_count"] == 1
      assert length(data["errors"]) == 2

      updated = Repo.get!(Pathway, good_pathway.id)
      assert updated.traversal_time == 90
    end
  end
end
