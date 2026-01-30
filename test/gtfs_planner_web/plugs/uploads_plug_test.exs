defmodule GtfsPlannerWeb.UploadsPlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias GtfsPlannerWeb.UploadsPlug

  @uploads_path Path.join(System.tmp_dir!(), "uploads_plug_test_#{:rand.uniform(100_000)}")

  setup_all do
    # Configure uploads path for tests
    Application.put_env(:gtfs_planner, :uploads_path, @uploads_path)

    on_exit(fn ->
      # Cleanup test directory
      File.rm_rf!(@uploads_path)
    end)

    :ok
  end

  setup do
    # Ensure clean state for each test
    File.rm_rf!(@uploads_path)
    File.mkdir_p!(@uploads_path)
    :ok
  end

  describe "call/2" do
    test "serves file when it exists at /uploads path" do
      # Create test file with organization isolation
      org_id = "123"
      stop_id = "TEST_STATION"
      filename = "floor_plan.png"
      file_content = "fake png content"

      file_dir = Path.join([@uploads_path, "diagrams", org_id, stop_id])
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

    test "provides tenant isolation - different org cannot access same stop_id" do
      # Create file for org 1
      org1_id = "1"
      stop_id = "SHARED_STATION"
      filename = "diagram.png"
      file_content = "org 1 content"

      file_dir = Path.join([@uploads_path, "diagrams", org1_id, stop_id])
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

    test "handles nested path segments correctly" do
      # Create deeply nested file
      file_dir = Path.join([@uploads_path, "diagrams", "org", "stop", "subdir"])
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
  end
end
