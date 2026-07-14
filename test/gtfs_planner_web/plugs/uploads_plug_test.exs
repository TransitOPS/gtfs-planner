defmodule GtfsPlannerWeb.UploadsPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias GtfsPlannerWeb.UploadsPlug

  setup_all do
    previous = Application.get_env(:gtfs_planner, :uploads_path)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gtfs_planner, :uploads_path),
        else: Application.put_env(:gtfs_planner, :uploads_path, previous)
    end)

    :ok
  end

  setup do
    uploads_path =
      Path.join(System.tmp_dir!(), "uploads_plug_test_#{System.unique_integer([:positive])}")

    Application.put_env(:gtfs_planner, :uploads_path, uploads_path)
    File.mkdir_p!(uploads_path)

    on_exit(fn -> File.rm_rf!(uploads_path) end)

    %{uploads_path: uploads_path}
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
end
