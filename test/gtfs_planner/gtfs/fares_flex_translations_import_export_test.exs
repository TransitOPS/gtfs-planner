defmodule GtfsPlanner.Gtfs.FaresFlexTranslationsImportExportTest do
  @moduledoc """
  Round trip for the fourteen tables import stores but the full export used to leave
  out: Fares v2 (`fare_products`, `fare_media`, `fare_leg_rules`, `fare_leg_join_rules`,
  `fare_transfer_rules`, `rider_categories`, `timeframes`, `areas`, `stop_areas`), the
  network tables (`networks`, `route_networks`), Flex (`locations`, `booking_rules`) and
  `translations`.

  - Each new spec writes the header its importer reads, and covers every GTFS column
    its table stores.
  - A full export reproduces each literal input file byte for byte, and re-importing
    the export stores the same rows.
  - A version without rows in a table exports no file for it, and the `:pathways`
    export keeps its three files.

  Every input file is a hand-written literal in the exporter's column order and row
  order, so neither the parser nor the exporter can confirm its own output.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.CsvWriter
  alias GtfsPlanner.Gtfs.Export.FileSpec
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport

  @new_files ~w(
    fare_products.txt fare_media.txt fare_leg_rules.txt fare_leg_join_rules.txt
    fare_transfer_rules.txt rider_categories.txt timeframes.txt areas.txt stop_areas.txt
    networks.txt route_networks.txt locations.txt booking_rules.txt translations.txt
  )

  @expected_headers %{
    "fare_products.txt" =>
      "fare_product_id,fare_product_name,rider_category_id,fare_media_id,amount,currency," <>
        "bundle_amount,duration_start,duration_amount,duration_unit\n",
    "fare_media.txt" => "fare_media_id,fare_media_name,fare_media_type\n",
    "fare_leg_rules.txt" =>
      "leg_group_id,network_id,from_area_id,to_area_id,from_timeframe_group_id," <>
        "to_timeframe_group_id,fare_product_id,rule_priority\n",
    "fare_leg_join_rules.txt" => "from_network_id,to_network_id,from_stop_id,to_stop_id\n",
    "fare_transfer_rules.txt" =>
      "from_leg_group_id,to_leg_group_id,transfer_count,duration_limit,duration_limit_type," <>
        "fare_transfer_type,fare_product_id\n",
    "rider_categories.txt" =>
      "rider_category_id,rider_category_name,min_age,max_age,eligibility_url\n",
    "timeframes.txt" => "timeframe_group_id,start_time,end_time,service_id\n",
    "areas.txt" => "area_id,area_name\n",
    "stop_areas.txt" => "area_id,stop_id\n",
    "networks.txt" => "network_id,network_name\n",
    "route_networks.txt" => "network_id,route_id\n",
    "locations.txt" => "location_id,location_name,location_lat,location_lon\n",
    "booking_rules.txt" =>
      "booking_rule_id,booking_type,prior_notice_duration_min,prior_notice_duration_max," <>
        "prior_notice_last_day,prior_notice_last_time,prior_notice_start_day," <>
        "prior_notice_start_time,prior_notice_service_id,message,pickup_message," <>
        "drop_off_message,phone_number,info_url,booking_url\n",
    "translations.txt" =>
      "table_name,field_name,language,translation,record_id,record_sub_id,field_value\n"
  }

  # Rows follow each table's natural key order, with empty key values last.
  @input_files %{
    "fare_products.txt" => """
    fare_product_id,fare_product_name,rider_category_id,fare_media_id,amount,currency,bundle_amount,duration_start,duration_amount,duration_unit
    P1,Single ride,R1,M1,2.50,USD,,,,
    P2,Day pass,,,10.00,USD,3,1,24,1
    """,
    "fare_media.txt" => """
    fare_media_id,fare_media_name,fare_media_type
    M1,Contactless card,2
    M2,,0
    """,
    "fare_leg_rules.txt" => """
    leg_group_id,network_id,from_area_id,to_area_id,from_timeframe_group_id,to_timeframe_group_id,fare_product_id,rule_priority
    L1,N1,A1,A2,T1,T2,P1,1
    L2,,,,,,P2,
    """,
    "fare_leg_join_rules.txt" => """
    from_network_id,to_network_id,from_stop_id,to_stop_id
    N1,N2,S1,S2
    N2,N1,,
    """,
    "fare_transfer_rules.txt" => """
    from_leg_group_id,to_leg_group_id,transfer_count,duration_limit,duration_limit_type,fare_transfer_type,fare_product_id
    L1,L2,1,7200,1,2,P1
    L2,L1,,,,0,
    """,
    "rider_categories.txt" => """
    rider_category_id,rider_category_name,min_age,max_age,eligibility_url
    R1,Adult,19,64,https://example.test/adult
    R2,Senior,,,
    """,
    "timeframes.txt" => """
    timeframe_group_id,start_time,end_time,service_id
    T1,07:00:00,09:30:00,WKD
    T2,,,SAT
    """,
    "areas.txt" => """
    area_id,area_name
    A1,Zone one
    A2,
    """,
    "stop_areas.txt" => """
    area_id,stop_id
    A1,S1
    A2,S2
    """,
    "networks.txt" => """
    network_id,network_name
    N1,Local bus
    N2,
    """,
    "route_networks.txt" => """
    network_id,route_id
    N1,R1
    N2,R2
    """,
    "locations.txt" => """
    location_id,location_name,location_lat,location_lon
    LOC1,Downtown zone,40.712776,-74.005974
    LOC2,,,
    """,
    "booking_rules.txt" => """
    booking_rule_id,booking_type,prior_notice_duration_min,prior_notice_duration_max,prior_notice_last_day,prior_notice_last_time,prior_notice_start_day,prior_notice_start_time,prior_notice_service_id,message,pickup_message,drop_off_message,phone_number,info_url,booking_url
    BR1,2,60,120,1,17:00:00,7,08:00:00,WKD,Call ahead,Pickup note,Drop-off note,555-0100,https://example.test/info,https://example.test/book
    BR2,0,,,,,,,,,,,,,
    """,
    "translations.txt" => """
    table_name,field_name,language,translation,record_id,record_sub_id,field_value
    fare_products,fare_product_name,es,Viaje sencillo,P1,,
    stop_times,stop_headsign,es,Al centro,T1,3,
    trips,trip_headsign,fr,"Centre, ville",,,Downtown
    """
  }

  # Stored fare products: a decimal amount, integers, and empty fields stored as NULL.
  @expected_stored_fare_products [
    %{
      fare_product_id: "P1",
      fare_product_name: "Single ride",
      rider_category_id: "R1",
      fare_media_id: "M1",
      amount: Decimal.new("2.50"),
      currency: "USD",
      bundle_amount: nil,
      duration_start: nil,
      duration_amount: nil,
      duration_unit: nil
    },
    %{
      fare_product_id: "P2",
      fare_product_name: "Day pass",
      rider_category_id: nil,
      fare_media_id: nil,
      amount: Decimal.new("10.00"),
      currency: "USD",
      bundle_amount: 3,
      duration_start: 1,
      duration_amount: 24,
      duration_unit: 1
    }
  ]

  setup do
    organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
    version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  describe "file specs" do
    test "write the header each table's importer reads" do
      assert new_spec_headers() == @expected_headers
    end

    test "cover every GTFS column their table stores" do
      assert spec_columns() == stored_columns()
    end

    test "are all part of the full profile and none of the pathways profile" do
      full_files = FileSpec.get_specs(:full) |> Enum.map(& &1.filename) |> MapSet.new()
      pathways_files = FileSpec.get_specs(:pathways) |> Enum.map(& &1.filename)

      assert MapSet.subset?(MapSet.new(@new_files), full_files)
      assert pathways_files == ["stops.txt", "levels.txt", "pathways.txt"]
    end
  end

  describe "import, full export and re-import" do
    test "reproduce every input file byte for byte and store the same rows again", %{
      organization: organization,
      version: version
    } do
      assert {:ok, result} = StagedImport.import_files(organization.id, version.id, input_files())
      assert result.counts[:fare_products] == 2
      assert result.counts[:translations] == 3

      assert MapSet.new(stored_rows(organization.id, version.id)["fare_products.txt"]) ==
               MapSet.new(@expected_stored_fare_products)

      assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)
      entries = unzip(zip)

      assert Map.take(entries, @new_files) == @input_files

      second_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

      reimport_files =
        Enum.map(entries, fn {name, content} -> %{filename: name, content: content} end)

      assert {:ok, _result} =
               StagedImport.import_files(organization.id, second_version.id, reimport_files)

      assert stored_row_sets(organization.id, second_version.id) ==
               stored_row_sets(organization.id, version.id)
    end

    test "export only the new files whose table has rows", %{
      organization: organization,
      version: version
    } do
      files = [
        %{filename: "fare_products.txt", content: @input_files["fare_products.txt"]},
        %{filename: "translations.txt", content: @input_files["translations.txt"]},
        %{filename: "routes.txt", content: "route_id,route_type\nR1,3\n"}
      ]

      assert {:ok, _result} = StagedImport.import_files(organization.id, version.id, files)
      assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)

      exported = zip |> unzip() |> Map.keys()

      assert Enum.filter(exported, &(&1 in @new_files)) |> Enum.sort() ==
               ["fare_products.txt", "translations.txt"]

      assert "routes.txt" in exported
    end

    test "include the new files in the operations export", %{
      organization: organization,
      version: version
    } do
      files = [%{filename: "areas.txt", content: @input_files["areas.txt"]}]

      assert {:ok, _result} = StagedImport.import_files(organization.id, version.id, files)
      assert {:ok, zip, _warnings} = Export.build_zip(organization.id, version.id, :operations)

      assert unzip(zip)["areas.txt"] == @input_files["areas.txt"]
    end
  end

  describe "row order" do
    test "sorts rows by natural key with empty key values last", %{
      organization: organization,
      version: version
    } do
      rules_in_reverse = """
      leg_group_id,network_id,from_area_id,to_area_id,from_timeframe_group_id,to_timeframe_group_id,fare_product_id,rule_priority
      L2,,,,,,P2,
      L1,N1,A1,A2,T1,T2,P1,1
      """

      files = [%{filename: "fare_leg_rules.txt", content: rules_in_reverse}]

      assert {:ok, _result} = StagedImport.import_files(organization.id, version.id, files)
      assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)

      assert unzip(zip)["fare_leg_rules.txt"] == @input_files["fare_leg_rules.txt"]
    end
  end

  describe "export inventory" do
    test "counts the rows of each new file in the full export only", %{
      organization: organization,
      version: version
    } do
      files = [
        %{filename: "fare_products.txt", content: @input_files["fare_products.txt"]},
        %{filename: "locations.txt", content: @input_files["locations.txt"]}
      ]

      assert {:ok, _result} = StagedImport.import_files(organization.id, version.id, files)

      full = Gtfs.get_file_inventory(organization.id, version.id, :full)
      pathways = Gtfs.get_file_inventory(organization.id, version.id, :pathways)

      assert {"fare_products.txt", 2} in full
      assert {"locations.txt", 2} in full
      assert {"translations.txt", 0} in full
      assert Enum.map(pathways, &elem(&1, 0)) == ["stops.txt", "levels.txt", "pathways.txt"]
    end
  end

  defp input_files do
    Enum.map(@input_files, fn {filename, content} -> %{filename: filename, content: content} end)
  end

  defp new_specs do
    Enum.filter(FileSpec.get_specs(:full), &(&1.filename in @new_files))
  end

  defp new_spec_headers do
    Map.new(new_specs(), fn spec ->
      {:ok, io} = StringIO.open("")
      CsvWriter.write_header(io, spec)
      {:ok, {_input, header}} = StringIO.close(io)

      {spec.filename, header}
    end)
  end

  defp spec_columns do
    Map.new(new_specs(), fn spec ->
      {spec.filename, spec.fields |> Enum.map(fn {_name, field} -> field end) |> Enum.sort()}
    end)
  end

  # Every schema field except the row identity, scope and timestamps.
  defp stored_columns do
    Map.new(new_specs(), fn spec ->
      columns =
        spec.schema.__schema__(:fields)
        |> Kernel.--([:id, :organization_id, :gtfs_version_id, :inserted_at, :updated_at])
        |> Enum.sort()

      {spec.filename, columns}
    end)
  end

  defp unzip(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    Map.new(entries, fn {name, content} -> {to_string(name), to_string(content)} end)
  end

  # Stored rows per file, reduced to the GTFS columns (no ids or timestamps).
  defp stored_rows(organization_id, gtfs_version_id) do
    Map.new(new_specs(), fn spec ->
      columns = spec.fields |> Enum.map(fn {_name, field} -> field end)

      rows =
        spec.schema
        |> where([r], r.organization_id == ^organization_id)
        |> where([r], r.gtfs_version_id == ^gtfs_version_id)
        |> Repo.all()
        |> Enum.map(&Map.take(&1, columns))

      {spec.filename, rows}
    end)
  end

  defp stored_row_sets(organization_id, gtfs_version_id) do
    organization_id
    |> stored_rows(gtfs_version_id)
    |> Map.new(fn {filename, rows} -> {filename, MapSet.new(rows)} end)
  end
end
