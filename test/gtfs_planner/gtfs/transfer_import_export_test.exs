defmodule GtfsPlanner.Gtfs.TransferImportExportTest do
  @moduledoc """
  Merge evidence (EV-3) for the transfer endpoint rule at the import boundary:

  - Real `Import.import_files/3` stores stopless type 4 and 5 rows with NULL stops
    and both trip IDs, keeps stops required for types 0-3, and names the missing
    field through `RowParser.transfer_row_to_attrs/3`.
  - A full `Export.export_to_zip/3` writes a `transfers.txt` whose rows equal the
    literal input rows field for field (empty fields stay empty), and re-importing
    that export stores the same attribute values in a second version.
  - A row violating the endpoint rule fails with the existing `row_invalid` shape
    at its physical row, and a repeated primary key with empty fields fails with
    `constraint_violation` and stores no transfers.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.CsvParser

  @headers "from_stop_id,to_stop_id,from_route_id,to_route_id,from_trip_id,to_trip_id," <>
             "transfer_type,min_transfer_time"

  @transfer_columns ~w(
    from_stop_id to_stop_id from_route_id to_route_id
    from_trip_id to_trip_id transfer_type min_transfer_time
  )a

  setup do
    organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
    version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  describe "import, full export, and re-import round trip" do
    test "stores stopless in-seat rows and reproduces every input row unchanged", %{
      organization: organization,
      version: version
    } do
      transfers_csv = """
      #{@headers}
      ,,,,T1,T2,4,
      ,,,,T2,T3,5,
      S1,S2,,,T3,T4,4,
      S1,S2,,,,,2,120
      """

      input_rows = [
        %{
          "from_stop_id" => "",
          "to_stop_id" => "",
          "from_route_id" => "",
          "to_route_id" => "",
          "from_trip_id" => "T1",
          "to_trip_id" => "T2",
          "transfer_type" => "4",
          "min_transfer_time" => ""
        },
        %{
          "from_stop_id" => "",
          "to_stop_id" => "",
          "from_route_id" => "",
          "to_route_id" => "",
          "from_trip_id" => "T2",
          "to_trip_id" => "T3",
          "transfer_type" => "5",
          "min_transfer_time" => ""
        },
        %{
          "from_stop_id" => "S1",
          "to_stop_id" => "S2",
          "from_route_id" => "",
          "to_route_id" => "",
          "from_trip_id" => "T3",
          "to_trip_id" => "T4",
          "transfer_type" => "4",
          "min_transfer_time" => ""
        },
        %{
          "from_stop_id" => "S1",
          "to_stop_id" => "S2",
          "from_route_id" => "",
          "to_route_id" => "",
          "from_trip_id" => "",
          "to_trip_id" => "",
          "transfer_type" => "2",
          "min_transfer_time" => "120"
        }
      ]

      expected_stored_rows = [
        %{
          from_stop_id: nil,
          to_stop_id: nil,
          from_route_id: nil,
          to_route_id: nil,
          from_trip_id: "T1",
          to_trip_id: "T2",
          transfer_type: 4,
          min_transfer_time: nil
        },
        %{
          from_stop_id: nil,
          to_stop_id: nil,
          from_route_id: nil,
          to_route_id: nil,
          from_trip_id: "T2",
          to_trip_id: "T3",
          transfer_type: 5,
          min_transfer_time: nil
        },
        %{
          from_stop_id: "S1",
          to_stop_id: "S2",
          from_route_id: nil,
          to_route_id: nil,
          from_trip_id: "T3",
          to_trip_id: "T4",
          transfer_type: 4,
          min_transfer_time: nil
        },
        %{
          from_stop_id: "S1",
          to_stop_id: "S2",
          from_route_id: nil,
          to_route_id: nil,
          from_trip_id: nil,
          to_trip_id: nil,
          transfer_type: 2,
          min_transfer_time: 120
        }
      ]

      files = [%{filename: "transfers.txt", content: transfers_csv}]

      assert {:ok, result} = Import.import_files(organization.id, version.id, files)
      assert result.counts[:transfers] == 4

      assert MapSet.new(stored_transfer_rows(organization.id, version.id)) ==
               MapSet.new(expected_stored_rows)

      assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)

      entries = unzip(zip)
      exported_rows = parsed_transfer_rows(entries)

      assert length(exported_rows) == 4
      assert MapSet.new(exported_rows) == MapSet.new(input_rows)

      second_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

      reimport_files =
        Enum.map(entries, fn {name, content} ->
          %{filename: to_string(name), content: content}
        end)

      assert {:ok, reimport_result} =
               Import.import_files(organization.id, second_version.id, reimport_files)

      assert reimport_result.counts[:transfers] == 4

      assert MapSet.new(stored_transfer_rows(organization.id, second_version.id)) ==
               MapSet.new(expected_stored_rows)
    end
  end

  describe "import failures" do
    test "fails a type 2 row without a from_stop_id at its physical row", %{
      organization: organization,
      version: version
    } do
      # Header is physical row 1, so the first data row is physical row 2 and the
      # failing second data row is physical row 3.
      transfers_csv = """
      #{@headers}
      S1,S2,,,,,0,
      ,S2,,,,,2,120
      """

      files = [%{filename: "transfers.txt", content: transfers_csv}]

      assert {:error, %Import.Failure{} = failure} =
               Import.import_files(organization.id, version.id, files)

      assert failure.reason_code == "row_invalid"
      assert failure.failed_file == "transfers.txt"
      assert failure.failed_row == 3
      assert failure.phase == :phase_1
      assert Gtfs.count_transfers(organization.id, version.id) == 0
    end

    test "fails a type 4 row without a to_trip_id at its physical row", %{
      organization: organization,
      version: version
    } do
      transfers_csv = """
      #{@headers}
      ,,,,T1,T2,4,
      ,,,,T3,,4,
      """

      files = [%{filename: "transfers.txt", content: transfers_csv}]

      assert {:error, %Import.Failure{} = failure} =
               Import.import_files(organization.id, version.id, files)

      assert failure.reason_code == "row_invalid"
      assert failure.failed_file == "transfers.txt"
      assert failure.failed_row == 3
      assert failure.phase == :phase_1
      assert Gtfs.count_transfers(organization.id, version.id) == 0
    end

    test "fails repeated stopless type 4 keys as a constraint violation", %{
      organization: organization,
      version: version
    } do
      transfers_csv = """
      #{@headers}
      ,,,,T1,T2,4,
      ,,,,T1,T2,4,
      """

      files = [%{filename: "transfers.txt", content: transfers_csv}]

      assert {:error, %Import.Failure{} = failure} =
               Import.import_files(organization.id, version.id, files)

      assert failure.reason_code == "constraint_violation"
      assert failure.failed_file == "transfers.txt"
      assert failure.failed_row == nil
      assert failure.phase == :phase_1
      assert Gtfs.count_transfers(organization.id, version.id) == 0
    end

    test "fails repeated stop-only keys as a constraint violation in a second version", %{
      organization: organization
    } do
      transfers_csv = """
      #{@headers}
      S1,S2,,,,,0,
      S1,S2,,,,,0,
      """

      second_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

      files = [%{filename: "transfers.txt", content: transfers_csv}]

      assert {:error, %Import.Failure{} = failure} =
               Import.import_files(organization.id, second_version.id, files)

      assert failure.reason_code == "constraint_violation"
      assert failure.failed_file == "transfers.txt"
      assert failure.phase == :phase_1
      assert Gtfs.count_transfers(organization.id, second_version.id) == 0
    end
  end

  defp unzip(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    entries
  end

  # Reads the exported transfers.txt back as maps of the eight exported columns.
  defp parsed_transfer_rows(entries) do
    case Enum.find(entries, fn {name, _content} -> to_string(name) == "transfers.txt" end) do
      nil ->
        flunk("expected transfers.txt in the export")

      {_name, content} ->
        {:ok, parsed} = CsvParser.stream("transfers.txt", to_string(content))
        Enum.map(parsed.events, fn {:ok, _row_number, row} -> row end)
    end
  end

  defp stored_transfer_rows(organization_id, gtfs_version_id) do
    organization_id
    |> Gtfs.list_transfers(gtfs_version_id)
    |> Enum.map(&Map.take(&1, @transfer_columns))
  end
end
