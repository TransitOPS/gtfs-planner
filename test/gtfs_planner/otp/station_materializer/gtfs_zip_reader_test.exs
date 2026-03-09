defmodule GtfsPlanner.Otp.StationMaterializer.GtfsZipReaderTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Otp.StationMaterializer.GtfsZipReader

  describe "read_tables/1" do
    test "reads root-level txt tables and preserves header order" do
      zip_path =
        write_zip!(%{
          "stops.txt" => "stop_id,stop_name,parent_station\nA,Station A,\n",
          "nested/routes.txt" => "route_id,route_short_name\nR1,1\n",
          "README.md" => "ignored"
        })

      assert {:ok, tables} = GtfsZipReader.read_tables(zip_path)
      assert Map.has_key?(tables, "stops.txt")
      refute Map.has_key?(tables, "nested/routes.txt")

      stops = Map.fetch!(tables, "stops.txt")
      assert stops.header == ["stop_id", "stop_name", "parent_station"]
      assert [%{line_number: 2, fields: ["A", "Station A", ""]}] = stops.rows
    end

    test "returns blocking issue when headers are duplicated" do
      zip_path =
        write_zip!(%{
          "stops.txt" => "stop_id,stop_id,stop_name\nA,A,Station A\n"
        })

      assert {:error, [issue]} = GtfsZipReader.read_tables(zip_path)
      assert issue.code == :gtfs_duplicate_headers
      assert issue.severity == :blocking
      assert issue.context.file_name == "stops.txt"
      assert issue.context.duplicate_headers == ["stop_id"]
    end

    test "returns blocking issue when a row has malformed field count" do
      zip_path =
        write_zip!(%{
          "stops.txt" => "stop_id,stop_name\nA\n"
        })

      assert {:error, [issue]} = GtfsZipReader.read_tables(zip_path)
      assert issue.code == :gtfs_malformed_row
      assert issue.severity == :blocking
      assert issue.context.file_name == "stops.txt"
      assert issue.context.line_number == 2
    end

    test "returns blocking issue when zip path does not exist" do
      assert {:error, [issue]} = GtfsZipReader.read_tables("/tmp/does-not-exist-gtfs.zip")
      assert issue.code == :gtfs_zip_not_found
      assert issue.severity == :blocking
    end
  end

  defp write_zip!(entries) when is_map(entries) do
    files =
      Enum.map(entries, fn {name, content} ->
        {String.to_charlist(name), content}
      end)

    {:ok, {_name, zip_binary}} = :zip.create(~c"gtfs.zip", files, [:memory])

    dir = Path.join(System.tmp_dir!(), "gtfs-zip-reader-test-#{System.unique_integer([:positive])}")
    :ok = File.mkdir_p(dir)

    zip_path = Path.join(dir, "gtfs.zip")
    :ok = File.write(zip_path, zip_binary)

    on_exit(fn ->
      File.rm_rf(dir)
    end)

    zip_path
  end
end
