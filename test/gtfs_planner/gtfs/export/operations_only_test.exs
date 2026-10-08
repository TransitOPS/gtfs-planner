defmodule GtfsPlanner.Gtfs.Export.OperationsOnlyTest do
  @moduledoc """
  The `:operations_only` ZIP carries exactly the TODS members the `:operations`
  build carries, no GTFS file, the same TODS warnings, and no flex zip.

  The `:operations` build is the oracle: its TODS members and warnings are read
  from its own output rather than restated here, so a new TODS file cannot pass
  unnoticed and a warning cannot drift between the two profiles.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.FileSpec
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Operations.Tods

  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "the operations-only ZIP" do
    test "carries exactly the operations build's TODS members, byte for byte" do
      world = runs_version_fixture()
      put_diagram_extensions!(world)

      {:ok, operations, _operations_warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations)

      {:ok, only, _only_warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations_only)

      operations_entries = zip_entries(operations)
      only_entries = zip_entries(only)

      # The fixture's diagram data reaches the operations build, so the member
      # checks below reject extension entries that leak into operations-only.
      assert Map.has_key?(operations_entries, "_pathways_extensions.json")

      assert Map.has_key?(
               operations_entries,
               "_pathways_extensions/diagrams/#{world.relief_stop_id}/floor.png"
             )

      assert Map.keys(only_entries) -- tods_filenames() == []
      assert only_entries == Map.take(operations_entries, tods_filenames())
      assert Map.has_key?(only_entries, "stops_supplement.txt")
      assert Map.has_key?(only_entries, "trips_supplement.txt")
    end

    test "carries no GTFS file" do
      %{organization: organization, version: version} = runs_version_fixture()

      {:ok, only, _warnings} = Export.build_zip(organization.id, version.id, :operations_only)
      gtfs_files = Enum.map(FileSpec.get_specs(:full), & &1.filename)

      for {name, _content} <- zip_entries(only) do
        refute name in gtfs_files, "#{name} is a GTFS file in an operations-only ZIP"
      end
    end

    test "keeps the operations build's TODS warnings" do
      %{organization: organization, version: version} = runs_version_fixture()

      {:ok, _operations, operations_warnings} =
        Export.build_zip(organization.id, version.id, :operations)

      {:ok, _only, only_warnings} =
        Export.build_zip(organization.id, version.id, :operations_only)

      tods_warnings = Enum.filter(operations_warnings, &String.starts_with?(&1.code, "tods_"))

      assert tods_warnings != []
      assert only_warnings == tods_warnings
    end

    test "refuses a garage whose ID equals an emitted stop ID" do
      world = runs_version_fixture()

      garage =
        garage_fixture(world.organization.id, %{
          "garage_id" => world.relief_stop_id,
          "name" => "Clashing garage"
        })

      assert {:error, {:garage_stop_id_conflict, conflicts}} =
               Export.build_zips(world.organization.id, world.version.id, :operations_only)

      assert Enum.any?(conflicts, &(&1.garage_id == garage.garage_id))
    end

    test "returns no flex file" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      flex_representative_fixture(organization, version)

      assert {:ok, %{flex: flex}, _warnings} =
               Export.build_zips(organization.id, version.id, :operations, include_flex: true)

      assert is_binary(flex)

      assert {:ok, %{flex: nil}, _warnings} =
               Export.build_zips(organization.id, version.id, :operations_only,
                 include_flex: true
               )
    end
  end

  # The operations file-writing body never reads diagram data, but the shared
  # ZIP helper appends the extension entries to every archive. One coordinate
  # plus one referenced floorplan makes the operations build carry
  # `_pathways_extensions.json` and the image, so the member checks reject both
  # when they leak into an operations-only ZIP.
  defp put_diagram_extensions!(world) do
    stop =
      Gtfs.get_stop_by_stop_id(world.organization.id, world.version.id, world.relief_stop_id)

    {:ok, _stop} = put_stop_diagram_coordinate(stop, %{x: 50.5, y: 25.0})

    level = level_fixture(world.organization.id, world.version.id, %{level_id: "L1"})

    {:ok, _stop_level} =
      insert_stop_level(%{
        stop_id: stop.id,
        level_id: level.id,
        organization_id: world.organization.id,
        gtfs_version_id: world.version.id,
        diagram_filename: "floor.png"
      })

    uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)

    image_dir =
      Path.join([
        uploads_path,
        "diagrams",
        world.organization.id,
        world.version.id,
        PathSafety.stop_storage_dir(world.relief_stop_id)
      ])

    File.mkdir_p!(image_dir)
    File.write!(Path.join(image_dir, "floor.png"), "fake png data")

    on_exit(fn ->
      File.rm_rf!(Path.join([uploads_path, "diagrams", world.organization.id, world.version.id]))
    end)
  end

  defp tods_filenames do
    [
      Tods.stops_supplement_spec(),
      Tods.vehicles_spec(),
      Tods.calendar_dates_supplement_spec(),
      Tods.routes_supplement_spec(),
      Tods.trips_supplement_spec(),
      Tods.stop_times_supplement_spec(),
      Tods.run_events_spec(),
      Tods.employee_run_dates_spec()
    ]
    |> Enum.map(& &1.filename)
  end

  defp zip_entries(zip_binary) do
    {:ok, files} = :zip.unzip(zip_binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end
end
