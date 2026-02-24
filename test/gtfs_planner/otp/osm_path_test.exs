defmodule GtfsPlanner.Otp.OsmPathTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Otp.OsmPath

  setup do
    previous_value = Application.get_env(:gtfs_planner, :otp_osm_path)

    on_exit(fn ->
      if is_nil(previous_value) do
        Application.delete_env(:gtfs_planner, :otp_osm_path)
      else
        Application.put_env(:gtfs_planner, :otp_osm_path, previous_value)
      end
    end)

    :ok
  end

  test "resolve/0 returns valid absolute .osm.pbf path" do
    dir = Path.join(System.tmp_dir!(), "otp-osm-path-test-#{System.unique_integer([:positive])}")
    file_path = Path.join(dir, "region.osm.pbf")

    File.mkdir_p!(dir)
    File.write!(file_path, "osm-data")

    on_exit(fn -> File.rm_rf(dir) end)

    Application.put_env(:gtfs_planner, :otp_osm_path, file_path)

    assert {:ok, ^file_path} = OsmPath.resolve()
  end

  test "resolve/0 returns missing_path when config is unset" do
    Application.delete_env(:gtfs_planner, :otp_osm_path)

    assert {:error, :missing_path} = OsmPath.resolve()
  end

  test "resolve/0 returns invalid_extension for non .osm.pbf path" do
    dir = Path.join(System.tmp_dir!(), "otp-osm-path-test-#{System.unique_integer([:positive])}")
    file_path = Path.join(dir, "region.pbf")

    File.mkdir_p!(dir)
    File.write!(file_path, "osm-data")

    on_exit(fn -> File.rm_rf(dir) end)

    Application.put_env(:gtfs_planner, :otp_osm_path, file_path)

    assert {:error, :invalid_extension} = OsmPath.resolve()
  end

  test "resolve/0 returns not_readable for unreadable .osm.pbf file" do
    dir = Path.join(System.tmp_dir!(), "otp-osm-path-test-#{System.unique_integer([:positive])}")
    file_path = Path.join(dir, "region.osm.pbf")

    File.mkdir_p!(dir)
    File.write!(file_path, "osm-data")

    File.chmod!(file_path, 0o000)

    on_exit(fn ->
      File.chmod(file_path, 0o644)
      File.rm_rf(dir)
    end)

    Application.put_env(:gtfs_planner, :otp_osm_path, file_path)

    assert {:error, :not_readable} = OsmPath.resolve()
  end
end
