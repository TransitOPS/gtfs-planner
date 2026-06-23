defmodule GtfsPlannerWeb.Api.V1.SyncControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.Pathway

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

  describe "create/2 — journal entries" do
    setup [:setup_user_with_org]

    test "creates station/node/pathway journal entries alongside pathways", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)

      %{station: station, child1: child1, pathway: pathway} =
        build_station_with_pathway(org.id, version.id)

      station_entry_id = Ecto.UUID.generate()
      node_entry_id = Ecto.UUID.generate()
      pathway_entry_id = Ecto.UUID.generate()

      payload = %{
        "pathways" => [],
        "journal_entries" => [
          %{
            "id" => station_entry_id,
            "target_type" => "station",
            "body" => "Whole-station note",
            "captured_at" => "2026-06-20T10:00:00Z"
          },
          %{
            "id" => node_entry_id,
            "target_type" => "node",
            "target_id" => child1.id,
            "body" => "Node note",
            "captured_at" => "2026-06-20T10:01:00Z"
          },
          %{
            "id" => pathway_entry_id,
            "target_type" => "pathway",
            "target_id" => pathway.id,
            "body" => "Pathway note",
            "captured_at" => "2026-06-20T10:02:00Z"
          }
        ]
      }

      conn = conn |> authed_conn(user) |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["journal_synced_count"] == 3
      refute Map.has_key?(data, "errors")

      entry = Repo.get!(JournalEntry, node_entry_id)
      assert entry.target_type == "node"
      assert entry.target_id == child1.id
      assert entry.body == "Node note"
      assert entry.author_id == user.id
      assert entry.organization_id == org.id
      assert entry.station_id == station.id
    end

    test "upserts by id (idempotent) and updates body on re-sync", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_with_pathway(org.id, version.id)
      id = Ecto.UUID.generate()

      post1 = %{
        "pathways" => [],
        "journal_entries" => [
          %{
            "id" => id,
            "target_type" => "station",
            "body" => "First",
            "captured_at" => "2026-06-20T10:00:00Z"
          }
        ]
      }

      conn |> authed_conn(user) |> post(sync_url(version.id, station.id), post1)

      post2 = %{
        "pathways" => [],
        "journal_entries" => [
          %{
            "id" => id,
            "target_type" => "station",
            "body" => "Edited",
            "captured_at" => "2026-06-20T10:00:00Z"
          }
        ]
      }

      conn2 = build_conn() |> authed_conn(user) |> post(sync_url(version.id, station.id), post2)

      assert %{"data" => data} = json_response(conn2, 200)
      assert data["journal_synced_count"] == 1
      assert Repo.aggregate(JournalEntry, :count, :id) == 1
      assert Repo.get!(JournalEntry, id).body == "Edited"
    end

    test "reports a per-item error without failing the batch", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_with_pathway(org.id, version.id)
      good_id = Ecto.UUID.generate()

      payload = %{
        "pathways" => [],
        "journal_entries" => [
          %{
            "id" => good_id,
            "target_type" => "station",
            "body" => "ok",
            "captured_at" => "2026-06-20T10:00:00Z"
          },
          %{
            "id" => Ecto.UUID.generate(),
            "target_type" => "bogus",
            "body" => "bad",
            "captured_at" => "2026-06-20T10:00:00Z"
          }
        ]
      }

      conn = conn |> authed_conn(user) |> post(sync_url(version.id, station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["journal_synced_count"] == 1
      assert [%{"code" => "validation_error"}] = data["errors"]
      assert Repo.get(JournalEntry, good_id)
    end

    test "rejects journal entries for a station outside the org", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)
      %{station: other_station} = build_station_with_pathway(other_org.id, other_version.id)

      payload = %{
        "pathways" => [],
        "journal_entries" => [
          %{
            "id" => Ecto.UUID.generate(),
            "target_type" => "station",
            "body" => "x",
            "captured_at" => "2026-06-20T10:00:00Z"
          }
        ]
      }

      # Authed as `user` (org), but posting to another org's station id.
      conn = conn |> authed_conn(user) |> post(sync_url(version.id, other_station.id), payload)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["journal_synced_count"] == 0
      assert [%{"code" => "not_found"}] = data["errors"]
      assert Repo.aggregate(JournalEntry, :count, :id) == 0
    end
  end

  describe "create/2 — pin journal entries" do
    setup [:setup_user_with_org]

    # A stop_level on the station, optionally aligned + sized.
    defp build_stop_level(org_id, version_id, station, opts) do
      level = level_fixture(org_id, version_id)

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: org_id,
          gtfs_version_id: version_id,
          stop_id: station.id,
          level_id: level.id
        })

      if Keyword.get(opts, :aligned, false) do
        {:ok, stop_level} =
          Gtfs.update_stop_level_alignment(stop_level, %{
            floorplan_center_lat: 40.7128,
            floorplan_center_lon: -74.0060,
            floorplan_scale_mpp: 0.25,
            floorplan_rotation_deg: 0.0
          })

        stop_level
      else
        stop_level
      end
    end

    # Posts a single pin entry through sync. Returns the decoded response data.
    defp sync_pin(_conn, user, version, station, pin_id, stop_level, extra \\ %{}) do
      entry =
        Map.merge(
          %{
            "id" => pin_id,
            "target_type" => "pin",
            "stop_level_id" => stop_level.id,
            # Painted image center in width-normalized units for 1000x800.
            "diagram_x" => 50.0,
            "diagram_y" => 40.0,
            "captured_at" => "2026-06-20T10:00:00Z"
          },
          extra
        )

      conn =
        build_conn()
        |> authed_conn(user)
        |> post(sync_url(version.id, station.id), %{
          "pathways" => [],
          "journal_entries" => [entry]
        })

      assert %{"data" => data} = json_response(conn, 200)
      data
    end

    defp bundle_pin_entry(user, version, station, pin_id) do
      bundle_conn =
        build_conn()
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => %{"levels" => levels}} = json_response(bundle_conn, 200)

      levels
      |> Enum.flat_map(& &1["journal_entries"])
      |> Enum.find(&(&1["id"] == pin_id))
    end

    test "syncs a pin storing diagram_x/y with null lat/lon (no sync-time imputation)", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_with_pathway(org.id, version.id)
      stop_level = build_stop_level(org.id, version.id, station, aligned: true)

      pin_id = Ecto.UUID.generate()

      data = sync_pin(conn, user, version, station, pin_id, stop_level)

      assert data["journal_synced_count"] == 1
      # Sync no longer imputes pin coords, so there is no journal_entries echo.
      refute Map.has_key?(data, "journal_entries")

      entry = Repo.get!(JournalEntry, pin_id)
      assert entry.target_type == "pin"
      assert entry.stop_level_id == stop_level.id
      assert entry.diagram_x == 50.0
      assert entry.diagram_y == 40.0
      assert is_nil(entry.lat)
      assert is_nil(entry.lon)

      # Bundle serves the canonical diagram coordinate; lat/lon still null.
      pin_entry = bundle_pin_entry(user, version, station, pin_id)
      assert pin_entry["target_type"] == "pin"
      assert pin_entry["diagram_coordinate"] == %{"x" => 50.0, "y" => 40.0}
      assert is_nil(pin_entry["lat"])
      assert is_nil(pin_entry["lon"])
      assert pin_entry["photos"] == []
    end

    test "imputes pin lat/lon at alignment time, then bundle serves them", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_with_pathway(org.id, version.id)
      # Unaligned at sync time, so the pin lands with null lat/lon.
      stop_level = build_stop_level(org.id, version.id, station, aligned: false)

      pin_id = Ecto.UUID.generate()
      sync_pin(conn, user, version, station, pin_id, stop_level)

      assert is_nil(Repo.get!(JournalEntry, pin_id).lat)

      # Aligning the level imputes lat/lon for its pins alongside nodes.
      assert {:ok, _} =
               Gtfs.save_and_apply_stop_level_alignment(
                 stop_level.id,
                 %{
                   floorplan_center_lat: 40.7128,
                   floorplan_center_lon: -74.0060,
                   floorplan_scale_mpp: 0.25,
                   floorplan_rotation_deg: 0.0
                 },
                 1000,
                 800
               )

      entry = Repo.get!(JournalEntry, pin_id)
      assert_in_delta entry.lat, 40.7128, 1.0e-6
      assert_in_delta entry.lon, -74.0060, 1.0e-6

      pin_entry = bundle_pin_entry(user, version, station, pin_id)
      assert pin_entry["diagram_coordinate"] == %{"x" => 50.0, "y" => 40.0}
      assert_in_delta pin_entry["lat"], 40.7128, 1.0e-6
      assert_in_delta pin_entry["lon"], -74.0060, 1.0e-6
    end

    test "pin lat/lon stay null on an unaligned level", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_with_pathway(org.id, version.id)
      stop_level = build_stop_level(org.id, version.id, station, aligned: false)

      pin_id = Ecto.UUID.generate()
      sync_pin(conn, user, version, station, pin_id, stop_level)

      entry = Repo.get!(JournalEntry, pin_id)
      assert is_nil(entry.lat)
      assert is_nil(entry.lon)
    end

    test "re-syncing a pin after alignment does not reset imputed lat/lon", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      %{station: station} = build_station_with_pathway(org.id, version.id)
      stop_level = build_stop_level(org.id, version.id, station, aligned: false)

      pin_id = Ecto.UUID.generate()
      sync_pin(conn, user, version, station, pin_id, stop_level)

      assert {:ok, _} =
               Gtfs.save_and_apply_stop_level_alignment(
                 stop_level.id,
                 %{
                   floorplan_center_lat: 40.7128,
                   floorplan_center_lon: -74.0060,
                   floorplan_scale_mpp: 0.25,
                   floorplan_rotation_deg: 0.0
                 },
                 1000,
                 800
               )

      imputed = Repo.get!(JournalEntry, pin_id)
      assert_in_delta imputed.lat, 40.7128, 1.0e-6

      # A later metadata re-sync (e.g. edited body) must preserve server-imputed
      # lat/lon — sync never carries lat/lon and must not clobber them to null.
      sync_pin(conn, user, version, station, pin_id, stop_level, %{"body" => "edited"})

      re_synced = Repo.get!(JournalEntry, pin_id)
      assert re_synced.body == "edited"
      assert_in_delta re_synced.lat, imputed.lat, 1.0e-9
      assert_in_delta re_synced.lon, imputed.lon, 1.0e-9
    end
  end
end
