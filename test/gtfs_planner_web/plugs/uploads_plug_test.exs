defmodule GtfsPlannerWeb.UploadsPlugTest do
  # Database-enabled and non-async: versioned diagram delivery now authorizes each
  # request against `Versions` publication state before touching the filesystem, and
  # each test still swaps the global `:uploads_path` config, so tests cannot share a
  # sandbox connection or the upload root.
  use GtfsPlanner.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.DiagramStorage
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.UploadsPlug

  setup do
    previous = Application.get_env(:gtfs_planner, :uploads_path)

    uploads_path =
      Path.join(System.tmp_dir!(), "uploads_plug_test_#{System.unique_integer([:positive])}")

    Application.put_env(:gtfs_planner, :uploads_path, uploads_path)
    File.mkdir_p!(uploads_path)

    on_exit(fn ->
      File.rm_rf!(uploads_path)

      if is_nil(previous),
        do: Application.delete_env(:gtfs_planner, :uploads_path),
        else: Application.put_env(:gtfs_planner, :uploads_path, previous)
    end)

    %{uploads_path: uploads_path}
  end

  # Writes a versioned diagram file at
  # `<uploads>/diagrams/<org>/<version>/<station_dir>/<filename>`.
  defp write_versioned_file(uploads_path, org_id, version_id, station_dir, filename, content) do
    dir = Path.join([uploads_path, "diagrams", org_id, version_id, station_dir])
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  defp unavailable_version(org_id, status) do
    {:ok, staging} =
      Versions.create_staging_gtfs_version(org_id, %{name: "Unavailable #{status}"})

    case status do
      "staging" ->
        staging

      "importing" ->
        {:ok, importing} = Versions.claim_staging_gtfs_version(org_id, staging.id)
        importing

      "failed" ->
        {:ok, failed} = Versions.fail_unpublished_gtfs_version(org_id, staging.id)
        failed
    end
  end

  describe "call/2" do
    test "serves file when it exists at /uploads path", %{uploads_path: uploads_path} do
      # Create test file with organization isolation
      org_id = "123"
      stop_id = "TEST_STATION"
      filename = "floor_plan.png"
      file_content = "fake png content"

      file_dir = Path.join([uploads_path, "diagrams", org_id, stop_id])
      File.mkdir_p!(file_dir)
      file_path = Path.join(file_dir, filename)
      File.write!(file_path, file_content)

      # Make request
      conn =
        conn(:get, "/uploads/diagrams/#{org_id}/#{stop_id}/#{filename}")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == file_content
    end

    test "adds CORS header when served to an allowed (localhost) origin", %{
      uploads_path: uploads_path
    } do
      org_id = "123"
      stop_id = "TEST_STATION"
      filename = "floor_plan.png"

      file_dir = Path.join([uploads_path, "diagrams", org_id, stop_id])
      File.mkdir_p!(file_dir)
      File.write!(Path.join(file_dir, filename), "fake png content")

      conn =
        conn(:get, "/uploads/diagrams/#{org_id}/#{stop_id}/#{filename}")
        |> put_req_header("origin", "http://localhost:51091")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 200

      assert get_resp_header(conn, "access-control-allow-origin") == [
               "http://localhost:51091"
             ]
    end

    test "answers CORS preflight (OPTIONS) for an allowed origin without serving a file" do
      conn =
        conn(:options, "/uploads/diagrams/123/TEST_STATION/floor_plan.png")
        |> put_req_header("origin", "http://localhost:51091")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 204

      assert get_resp_header(conn, "access-control-allow-origin") == [
               "http://localhost:51091"
             ]
    end

    test "omits CORS header for a disallowed origin", %{uploads_path: uploads_path} do
      org_id = "123"
      stop_id = "TEST_STATION"
      filename = "floor_plan.png"

      file_dir = Path.join([uploads_path, "diagrams", org_id, stop_id])
      File.mkdir_p!(file_dir)
      File.write!(Path.join(file_dir, filename), "fake png content")

      conn =
        conn(:get, "/uploads/diagrams/#{org_id}/#{stop_id}/#{filename}")
        |> put_req_header("origin", "https://evil.example.com")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "passes through when file does not exist" do
      conn =
        conn(:get, "/uploads/diagrams/999/NONEXISTENT/missing.png")
        |> UploadsPlug.call([])

      refute conn.halted
      assert conn.status == nil
    end

    test "passes through for non-upload paths" do
      conn =
        conn(:get, "/other/path")
        |> UploadsPlug.call([])

      refute conn.halted
      assert conn.status == nil
    end

    test "provides tenant isolation - different org cannot access same stop_id", %{
      uploads_path: uploads_path
    } do
      # Create file for org 1
      org1_id = "1"
      stop_id = "SHARED_STATION"
      filename = "diagram.png"
      file_content = "org 1 content"

      file_dir = Path.join([uploads_path, "diagrams", org1_id, stop_id])
      File.mkdir_p!(file_dir)
      File.write!(Path.join(file_dir, filename), file_content)

      # Request as org 1 - should succeed
      conn1 =
        conn(:get, "/uploads/diagrams/#{org1_id}/#{stop_id}/#{filename}")
        |> UploadsPlug.call([])

      assert conn1.halted
      assert conn1.status == 200
      assert conn1.resp_body == file_content

      # Request as org 2 - should pass through (file not found)
      org2_id = "2"

      conn2 =
        conn(:get, "/uploads/diagrams/#{org2_id}/#{stop_id}/#{filename}")
        |> UploadsPlug.call([])

      refute conn2.halted
      assert conn2.status == nil
    end

    test "handles nested path segments correctly", %{uploads_path: uploads_path} do
      # Create deeply nested file
      file_dir = Path.join([uploads_path, "diagrams", "org", "stop", "subdir"])
      File.mkdir_p!(file_dir)
      File.write!(Path.join(file_dir, "file.txt"), "nested content")

      conn =
        conn(:get, "/uploads/diagrams/org/stop/subdir/file.txt")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == "nested content"
    end

    test "handles root uploads path request" do
      conn =
        conn(:get, "/uploads")
        |> UploadsPlug.call([])

      # Should pass through as there's no file at root
      refute conn.halted
    end

    test "returns 403 for path traversal attempts" do
      # Attempt to traverse outside uploads directory
      conn =
        conn(:get, "/uploads/../mix.exs")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body == "Forbidden"
    end

    test "returns 403 for encoded path traversal attempts" do
      # Multiple .. segments to escape uploads directory
      conn =
        conn(:get, "/uploads/diagrams/../../../../../../etc/passwd")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body == "Forbidden"
    end

    test "serves only valid field captures with deterministic public image headers", %{
      uploads_path: uploads_path
    } do
      organization_id = Ecto.UUID.generate()
      photo_id = Ecto.UUID.generate()
      file_dir = Path.join([uploads_path, "field-captures", organization_id, "STATION"])
      File.mkdir_p!(file_dir)
      File.write!(Path.join(file_dir, "#{photo_id}.png"), <<137, 80, 78, 71>>)

      conn =
        conn(:get, "/uploads/field-captures/#{organization_id}/STATION/#{photo_id}.png")
        |> UploadsPlug.call([])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "does not apply field-capture image headers to an invalid field-capture filename", %{
      uploads_path: uploads_path
    } do
      file_dir = Path.join([uploads_path, "field-captures", "organization", "STATION"])
      File.mkdir_p!(file_dir)
      File.write!(Path.join(file_dir, "untrusted.png"), "not a field capture")

      conn =
        conn(:get, "/uploads/field-captures/organization/STATION/untrusted.png")
        |> UploadsPlug.call([])

      assert conn.status == 200

      refute "public, max-age=31536000, immutable" in get_resp_header(conn, "cache-control")

      assert get_resp_header(conn, "x-content-type-options") == []
    end
  end

  describe "call/2 versioned diagram delivery" do
    setup %{uploads_path: uploads_path} do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      %{org: org, version: version, uploads_path: uploads_path}
    end

    test "serves a published matching organization/version diagram file", %{
      uploads_path: uploads_path,
      org: org,
      version: version
    } do
      content = "versioned png bytes"

      write_versioned_file(
        uploads_path,
        org.id,
        version.id,
        "STATION_A",
        "floor.png",
        content
      )

      conn =
        conn(:get, "/uploads/diagrams/#{org.id}/#{version.id}/STATION_A/floor.png")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == content
    end

    test "public production path contains the organization and version ID", %{
      uploads_path: uploads_path,
      org: org,
      version: version
    } do
      write_versioned_file(uploads_path, org.id, version.id, "STATION_A", "floor.png", "x")

      path = "/uploads/diagrams/#{org.id}/#{version.id}/STATION_A/floor.png"
      assert String.contains?(path, org.id)
      assert String.contains?(path, version.id)

      conn = conn(:get, path) |> UploadsPlug.call([])
      assert conn.status == 200
    end

    test "applies CORS to an allowed origin for a published versioned file", %{
      uploads_path: uploads_path,
      org: org,
      version: version
    } do
      write_versioned_file(uploads_path, org.id, version.id, "STATION_A", "floor.png", "x")

      conn =
        conn(:get, "/uploads/diagrams/#{org.id}/#{version.id}/STATION_A/floor.png")
        |> put_req_header("origin", "http://localhost:51091")
        |> UploadsPlug.call([])

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:51091"]
    end

    test "returns 404 for a malformed version segment even when the file exists", %{
      uploads_path: uploads_path,
      org: org
    } do
      # File written under a non-UUID version-shaped dir must never be reachable
      # through the versioned grammar.
      write_versioned_file(uploads_path, org.id, "not-a-uuid", "STATION_A", "floor.png", "x")

      conn =
        conn(:get, "/uploads/diagrams/#{org.id}/not-a-uuid/STATION_A/floor.png")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 404
    end

    for status <- ["staging", "importing", "failed"] do
      test "returns 404 for a #{status} version even when the file exists", %{
        uploads_path: uploads_path,
        org: org
      } do
        version = unavailable_version(org.id, unquote(status))

        write_versioned_file(uploads_path, org.id, version.id, "STATION_A", "floor.png", "secret")

        conn =
          conn(:get, "/uploads/diagrams/#{org.id}/#{version.id}/STATION_A/floor.png")
          |> UploadsPlug.call([])

        assert conn.halted
        assert conn.status == 404
        refute conn.resp_body == "secret"
      end
    end

    test "returns 404 for a foreign organization that does not own the version", %{
      uploads_path: uploads_path,
      version: version
    } do
      foreign_org = organization_fixture()

      # Even if a file physically exists under the foreign org's versioned dir,
      # the org does not own the supplied version, so it is treated as missing.
      write_versioned_file(
        uploads_path,
        foreign_org.id,
        version.id,
        "STATION_A",
        "floor.png",
        "x"
      )

      conn =
        conn(:get, "/uploads/diagrams/#{foreign_org.id}/#{version.id}/STATION_A/floor.png")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 404
    end

    test "returns 404 for a nonexistent version id", %{org: org} do
      conn =
        conn(:get, "/uploads/diagrams/#{org.id}/#{Ecto.UUID.generate()}/STATION_A/floor.png")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 404
    end

    test "historical four-segment diagram URLs still serve without database gating", %{
      uploads_path: uploads_path,
      org: org
    } do
      file_dir = Path.join([uploads_path, "diagrams", org.id, "STATION_A"])
      File.mkdir_p!(file_dir)
      File.write!(Path.join(file_dir, "legacy.png"), "legacy bytes")

      conn =
        conn(:get, "/uploads/diagrams/#{org.id}/STATION_A/legacy.png")
        |> put_req_header("origin", "http://localhost:51091")
        |> UploadsPlug.call([])

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == "legacy bytes"
      assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:51091"]
    end

    test "legacy backfill copies a referenced image into the published versioned destination without overwriting, stays idempotent, and is served once copied",
         %{uploads_path: uploads_path, org: org, version: version} do
      station =
        stop_fixture(org.id, version.id,
          stop_id: "legacy_station_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      level = level_fixture(org.id, version.id)

      legacy_dir =
        Path.join([
          uploads_path,
          "diagrams",
          org.id,
          PathSafety.stop_storage_dir(station.stop_id)
        ])

      File.mkdir_p!(legacy_dir)
      legacy_path = Path.join(legacy_dir, "plan.png")
      File.write!(legacy_path, "legacy diagram bytes")

      {:ok, _} =
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "plan.png",
          organization_id: org.id,
          gtfs_version_id: version.id
        })

      # Backfill copies the referenced legacy file into the versioned destination.
      assert {:ok, 1} = DiagramStorage.migrate_legacy_assets(Repo)

      {:ok, dest} = DiagramStorage.published_path(org.id, version.id, station.stop_id, "plan.png")
      assert File.read!(dest) == "legacy diagram bytes"

      # Idempotent: a second run copies nothing new.
      assert {:ok, 0} = DiagramStorage.migrate_legacy_assets(Repo)
      assert File.read!(dest) == "legacy diagram bytes"

      # Legacy source remains intact (non-destructive).
      assert File.read!(legacy_path) == "legacy diagram bytes"

      # The backfilled versioned file is served through the public delivery path.
      versioned_url =
        "/uploads/diagrams/#{org.id}/#{version.id}/#{PathSafety.stop_storage_dir(station.stop_id)}/plan.png"

      conn = conn(:get, versioned_url) |> UploadsPlug.call([])
      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == "legacy diagram bytes"
    end

    test "versioned delivery falls back to the historical legacy url only when no versioned copy exists",
         %{uploads_path: uploads_path, org: org, version: version} do
      station =
        stop_fixture(org.id, version.id,
          stop_id: "fallback_station_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      legacy_dir =
        Path.join([
          uploads_path,
          "diagrams",
          org.id,
          PathSafety.stop_storage_dir(station.stop_id)
        ])

      File.mkdir_p!(legacy_dir)
      File.write!(Path.join(legacy_dir, "plan.png"), "only legacy bytes")

      # No versioned copy exists yet, so public_url_path resolves to the legacy url.
      assert {:ok, url} =
               DiagramStorage.public_url_path(org.id, version.id, station.stop_id, "plan.png")

      refute url =~ version.id

      conn = conn(:get, url) |> UploadsPlug.call([])
      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == "only legacy bytes"
    end
  end
end
