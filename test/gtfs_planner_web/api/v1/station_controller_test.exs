defmodule GtfsPlannerWeb.Api.V1.StationControllerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.{JournalEntry, JournalPhoto, StopLevel}
  alias GtfsPlanner.Repo

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

  defp journal_entry_fixture(org, version, station, user, attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      organization_id: org.id,
      gtfs_version_id: version.id,
      station_id: station.id,
      author_id: user.id,
      target_type: "station",
      captured_at: ~U[2026-07-13 10:00:00.000000Z]
    }

    Repo.insert!(struct!(JournalEntry, Map.merge(defaults, attrs)))
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

    test "default list returns only location_type=1 rows and meta.total reflects filtered count",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      for _ <- 1..3 do
        stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})
      end

      for _ <- 1..2 do
        stop_fixture(org.id, version.id, %{location_type: 0, parent_station: nil})
      end

      conn = conn |> authed_conn(user) |> get("/api/v1/versions/#{version.id}/stations")

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert length(data) == 3
      assert meta["total"] == 3
      assert meta["page"] == 1
      assert meta["per_page"] == 25
    end

    test "page=2&per_page=2 returns correct slice and meta", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      for _ <- 1..5 do
        stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})
      end

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations?page=2&per_page=2")

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert length(data) == 2
      assert meta["total"] == 5
      assert meta["page"] == 2
      assert meta["per_page"] == 2
    end

    test "per_page=1000 clamps to 100", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations?per_page=1000")

      assert %{"meta" => meta} = json_response(conn, 200)
      assert meta["per_page"] == 100
    end

    test "per_page=0 defaults to 25", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations?per_page=0")

      assert %{"meta" => meta} = json_response(conn, 200)
      assert meta["per_page"] == 25
    end

    test "per_page=abc defaults to 25", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations?per_page=abc")

      assert %{"meta" => meta} = json_response(conn, 200)
      assert meta["per_page"] == 25
    end

    test "page=-5 clamps to 1", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations?page=-5")

      assert %{"meta" => meta} = json_response(conn, 200)
      assert meta["page"] == 1
    end

    test "page=abc defaults to 1", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations?page=abc")

      assert %{"meta" => meta} = json_response(conn, 200)
      assert meta["page"] == 1
    end

    test "search filters by stop_name substring", %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)

      match =
        stop_fixture(org.id, version.id, %{
          location_type: 1,
          parent_station: nil,
          stop_name: "Penn Station"
        })

      _other =
        stop_fixture(org.id, version.id, %{
          location_type: 1,
          parent_station: nil,
          stop_name: "Grand Central"
        })

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations?search=Penn")

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert length(data) == 1
      assert hd(data)["id"] == match.id
      assert meta["total"] == 1
    end

    test "mixed location_type=0 + location_type=1 data returns only stations", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)

      station =
        stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})

      _bus_stop =
        stop_fixture(org.id, version.id, %{location_type: 0, parent_station: nil})

      conn = conn |> authed_conn(user) |> get("/api/v1/versions/#{version.id}/stations")

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert length(data) == 1
      assert hd(data)["id"] == station.id
      assert meta["total"] == 1
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
      # The station's own GTFS coordinates ride along as JSON numbers — the
      # companion's camera fallback for un-aligned stations.
      assert is_number(data["station"]["lat"])
      assert is_number(data["station"]["lon"])

      assert length(data["levels"]) == 1
      level_json = hd(data["levels"])
      assert level_json["id"] == level.id
      # No stop_level/alignment for this level → floorplan is null.
      assert Map.has_key?(level_json, "floorplan")
      assert level_json["floorplan"] == nil

      assert length(data["stops"]) == 2
      # Stops carry resolved coordinates as JSON numbers (from stop_lat/stop_lon).
      stop_json = hd(data["stops"])
      assert is_number(stop_json["lat"])
      assert is_number(stop_json["lon"])

      assert length(data["pathways"]) == 1
      p = hd(data["pathways"])
      assert p["id"] == pathway.id
      assert p["pathway_id"] == pathway.pathway_id

      # Keep the legacy diagrams[] array for companion client compatibility.
      assert data["diagrams"] == []

      assert is_binary(data["downloaded_at"])
    end

    test "nests scoped journal history with ordered photos at documented bundle targets", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)

      %{station: station, level: level, child1: child1, pathway: pathway} =
        build_station_data(org.id, version.id)

      {:ok, stop_level} =
        %StopLevel{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org.id,
          gtfs_version_id: version.id
        }
        |> Repo.insert()

      station_entry =
        journal_entry_fixture(org, version, station, user, %{
          body: "station entry",
          captured_at: ~U[2026-07-13 09:00:00.000000Z],
          closed_at: ~U[2026-07-13 09:30:00.000000Z],
          closed_by: user.id
        })

      _node_entry =
        journal_entry_fixture(org, version, station, user, %{
          target_type: "node",
          target_id: child1.id,
          body: "node entry"
        })

      _pathway_entry =
        journal_entry_fixture(org, version, station, user, %{
          target_type: "pathway",
          target_id: pathway.id,
          body: "pathway entry"
        })

      _pin_entry =
        journal_entry_fixture(org, version, station, user, %{
          target_type: "pin",
          stop_level_id: stop_level.id,
          diagram_x: 12.5,
          diagram_y: 40.0,
          lat: 39.95,
          lon: -75.16,
          body: "pin entry"
        })

      earlier_photo =
        Repo.insert!(%JournalPhoto{
          id: Ecto.UUID.generate(),
          journal_entry_id: station_entry.id,
          filename: "#{Ecto.UUID.generate()}.jpg",
          content_type: "image/jpeg",
          byte_size: 3,
          sha256: :crypto.strong_rand_bytes(32),
          captured_at: ~U[2026-07-13 08:00:00.000000Z]
        })

      later_photo =
        Repo.insert!(%JournalPhoto{
          id: Ecto.UUID.generate(),
          journal_entry_id: station_entry.id,
          filename: "#{Ecto.UUID.generate()}.png",
          content_type: "image/png",
          byte_size: 3,
          sha256: :crypto.strong_rand_bytes(32),
          captured_at: ~U[2026-07-13 11:00:00.000000Z]
        })

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => data} = json_response(conn, 200)
      assert [station_json] = data["journal_entries"]
      assert station_json["id"] == station_entry.id
      assert station_json["closed_by"] == user.id
      assert [photo, second_photo] = station_json["photos"]
      assert photo["id"] == earlier_photo.id
      assert second_photo["id"] == later_photo.id

      assert String.starts_with?(
               photo["url"],
               "#{GtfsPlannerWeb.Endpoint.url()}/uploads/field-captures/#{org.id}/"
             )

      assert String.ends_with?(photo["url"], ".jpg")

      assert [node_json] = Enum.find(data["stops"], &(&1["id"] == child1.id))["journal_entries"]
      assert node_json["body"] == "node entry"

      assert [pathway_json] =
               Enum.find(data["pathways"], &(&1["id"] == pathway.id))["journal_entries"]

      assert pathway_json["body"] == "pathway entry"

      level_json = Enum.find(data["levels"], &(&1["id"] == level.id))
      assert level_json["stop_level_id"] == stop_level.id
      assert [pin_json] = level_json["journal_entries"]
      assert pin_json["diagram_coordinate"] == %{"x" => 12.5, "y" => 40.0}
      assert pin_json["lat"] == 39.95
      assert pin_json["lon"] == -75.16
    end

    test "omits journal history whose target no longer appears in the bundle", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      %{station: station, child1: child1} = build_station_data(org.id, version.id)

      _orphaned_node_entry =
        journal_entry_fixture(org, version, station, user, %{
          target_type: "node",
          target_id: Ecto.UUID.generate(),
          body: "deleted node history"
        })

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.find(data["stops"], &(&1["id"] == child1.id))["journal_entries"] == []
    end

    test "level floorplan carries url + alignment when the stop_level is aligned", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      %{station: station, level: level} = build_station_data(org.id, version.id)

      {:ok, _stop_level} =
        %StopLevel{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org.id,
          gtfs_version_id: version.id,
          diagram_filename: "B1/busway plan.png",
          floorplan_center_lat: 39.9536,
          floorplan_center_lon: -75.1632,
          floorplan_scale_mpp: 0.05,
          floorplan_rotation_deg: 12.5
        }
        |> Repo.insert()

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => data} = json_response(conn, 200)
      floorplan = Enum.find(data["levels"], &(&1["id"] == level.id))["floorplan"]

      assert floorplan["filename"] == "B1/busway plan.png"
      assert floorplan["center_lat"] == 39.9536
      assert floorplan["center_lon"] == -75.1632
      assert floorplan["scale_mpp"] == 0.05
      assert floorplan["rotation_deg"] == 12.5
      assert is_binary(floorplan["url"])
      assert String.contains?(floorplan["url"], "/uploads/diagrams/")
      assert String.contains?(floorplan["url"], "B1%2Fbusway%20plan.png")
    end

    test "level floorplan url uses the encoded storage directory for unsafe station stop_id", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      level = level_fixture(org.id, version.id)

      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "station/with spaces",
          location_type: 1,
          parent_station: nil
        })

      {:ok, _stop_level} =
        %StopLevel{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org.id,
          gtfs_version_id: version.id,
          diagram_filename: "concourse.png",
          floorplan_center_lat: 39.9536,
          floorplan_center_lon: -75.1632,
          floorplan_scale_mpp: 0.05,
          floorplan_rotation_deg: 12.5
        }
        |> Repo.insert()

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      encoded_dir = "sid_" <> Base.url_encode64(station.stop_id, padding: false)

      assert %{"data" => data} = json_response(conn, 200)
      floorplan = Enum.find(data["levels"], &(&1["id"] == level.id))["floorplan"]

      assert floorplan["url"] =~ "/uploads/diagrams/#{org.id}/#{encoded_dir}/concourse.png"
    end

    test "level floorplan carries the image with null alignment when the stop_level has a diagram but incomplete alignment",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station, level: level} = build_station_data(org.id, version.id)

      {:ok, _stop_level} =
        %StopLevel{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org.id,
          gtfs_version_id: version.id,
          diagram_filename: "B1_busway.png"
        }
        |> Repo.insert()

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => data} = json_response(conn, 200)
      floorplan = Enum.find(data["levels"], &(&1["id"] == level.id))["floorplan"]

      # The diagram image is emitted independent of alignment so the client can
      # render it in diagram space; the alignment fields are null.
      assert floorplan["filename"] == "B1_busway.png"
      assert is_binary(floorplan["url"])
      assert String.contains?(floorplan["url"], "/uploads/diagrams/")
      assert floorplan["center_lat"] == nil
      assert floorplan["center_lon"] == nil
      assert floorplan["scale_mpp"] == nil
      assert floorplan["rotation_deg"] == nil
    end

    test "level floorplan is null when the stop_level has no diagram image",
         %{conn: conn, user: user, org: org} do
      version = gtfs_version_fixture(org.id)
      %{station: station, level: level} = build_station_data(org.id, version.id)

      {:ok, _stop_level} =
        %StopLevel{
          stop_id: station.id,
          level_id: level.id,
          organization_id: org.id,
          gtfs_version_id: version.id
        }
        |> Repo.insert()

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.find(data["levels"], &(&1["id"] == level.id))["floorplan"] == nil
    end

    test "stop coordinates serialize decimal values as numbers and nil values as null", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)
      level = level_fixture(org.id, version.id)
      station = stop_fixture(org.id, version.id, %{location_type: 1, parent_station: nil})

      decimal_stop =
        stop_fixture(org.id, version.id, %{
          stop_id: "decimal_stop",
          stop_name: "Decimal Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          stop_lat: Decimal.new("39.9536"),
          stop_lon: Decimal.new("-75.1632")
        })

      nil_stop =
        stop_fixture(org.id, version.id, %{
          stop_id: "nil_stop",
          stop_name: "Nil Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          stop_lat: nil,
          stop_lon: nil
        })

      lat_only_stop =
        stop_fixture(org.id, version.id, %{
          stop_id: "lat_only_stop",
          stop_name: "Lat Only Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          stop_lat: Decimal.new("40.0"),
          stop_lon: nil
        })

      lon_only_stop =
        stop_fixture(org.id, version.id, %{
          stop_id: "lon_only_stop",
          stop_name: "Lon Only Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          stop_lat: nil,
          stop_lon: Decimal.new("-75.0")
        })

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{station.id}/bundle")

      assert %{"data" => data} = json_response(conn, 200)

      decimal_stop_json = Enum.find(data["stops"], &(&1["id"] == decimal_stop.id))
      nil_stop_json = Enum.find(data["stops"], &(&1["id"] == nil_stop.id))
      lat_only_stop_json = Enum.find(data["stops"], &(&1["id"] == lat_only_stop.id))
      lon_only_stop_json = Enum.find(data["stops"], &(&1["id"] == lon_only_stop.id))

      assert decimal_stop_json["lat"] == 39.9536
      assert decimal_stop_json["lon"] == -75.1632
      assert nil_stop_json["lat"] == nil
      assert nil_stop_json["lon"] == nil
      assert lat_only_stop_json["lat"] == nil
      assert lat_only_stop_json["lon"] == nil
      assert lon_only_stop_json["lat"] == nil
      assert lon_only_stop_json["lon"] == nil
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

    test "returns 404 for location_type=0 stop even when parent_station is nil", %{
      conn: conn,
      user: user,
      org: org
    } do
      version = gtfs_version_fixture(org.id)

      bus_stop =
        stop_fixture(org.id, version.id, %{location_type: 0, parent_station: nil})

      conn =
        conn
        |> authed_conn(user)
        |> get("/api/v1/versions/#{version.id}/stations/#{bus_stop.id}/bundle")

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "returns 200 with expected shape for location_type=1 station", %{
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
      assert hd(data["pathways"])["id"] == pathway.id

      assert is_binary(data["downloaded_at"])
    end
  end
end
