defmodule GtfsPlanner.Gtfs.Export.OperationsOnlyTest do
  @moduledoc """
  The `:operations_only` ZIP carries exactly the TODS members the `:operations`
  build carries, no GTFS file, the same TODS warnings, and no flex zip.

  The `:operations` build is the oracle: its TODS members and warnings are read
  from its own output rather than restated here, so a new TODS file cannot pass
  unnoticed and a warning cannot drift between the two profiles.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.FileSpec
  alias GtfsPlanner.Operations.Tods

  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "the operations-only ZIP" do
    test "carries exactly the operations build's TODS members, byte for byte" do
      %{organization: organization, version: version} = runs_version_fixture()

      {:ok, operations, _operations_warnings} =
        Export.build_zip(organization.id, version.id, :operations)

      {:ok, only, _only_warnings} =
        Export.build_zip(organization.id, version.id, :operations_only)

      operations_entries = zip_entries(operations)
      only_entries = zip_entries(only)

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
