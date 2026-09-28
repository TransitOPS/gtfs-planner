defmodule GtfsPlanner.Gtfs.Routes.ExportSelectionTest do
  @moduledoc """
  R6 export selection: full and operations exports omit only the explicitly
  inactive route closure while true/NULL, dangling and shared rows survive.
  """
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.FileSpec
  alias GtfsPlanner.Gtfs.FareRule

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{organization_id: organization.id, gtfs_version_id: gtfs_version.id}
  end

  describe "Export.build_zip/3 :full selection" do
    test "omits only the inactive route closure across service streams", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      seed_selection_closure!(org_id, version_id)

      assert {:ok, zip_binary, []} = Export.build_zip(org_id, version_id, :full)
      files = unzip_files!(zip_binary)

      assert_closure_omitted!(files)
      assert_shared_rows_retained!(files)
    end
  end

  describe "Export.build_zip/3 :operations selection" do
    test "shares the full-export inactive route closure rule", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      seed_selection_closure!(org_id, version_id)

      assert {:ok, zip_binary, warnings} = Export.build_zip(org_id, version_id, :operations)
      files = unzip_files!(zip_binary)

      assert_closure_omitted!(files)
      assert_shared_rows_retained!(files)

      assert Enum.any?(warnings, &(&1.code == "tods_file_omitted"))
    end
  end

  describe "Export.export_specs_to_directory/4 selection" do
    test "streams the same inactive route closure omission", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      seed_selection_closure!(org_id, version_id)

      output_dir =
        Path.join(System.tmp_dir!(), "export_selection_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(output_dir) end)

      assert {:ok, file_paths} =
               Export.export_specs_to_directory(
                 org_id,
                 version_id,
                 FileSpec.get_specs(:full),
                 output_dir
               )

      assert file_paths != []

      files =
        Map.new(file_paths, fn path ->
          {Path.basename(path), File.read!(path)}
        end)

      assert_closure_omitted!(files)
    end

    test "keeps every eligible row in schema order across 1000-row batches", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      route_fixture(org_id, version_id, route_id: "BATCH_ACTIVE", active: true)
      route_fixture(org_id, version_id, route_id: "BATCH_INACTIVE", active: false)

      expected_trip_ids =
        for i <- 1..1201 do
          trip_id = "BATCH_TRIP_#{String.pad_leading(Integer.to_string(i), 4, "0")}"
          route_id = if rem(i, 2) == 1, do: "BATCH_ACTIVE", else: "BATCH_INACTIVE"

          trip_fixture(org_id, version_id, route_id, trip_id: trip_id, service_id: "BATCH_SVC")
          if rem(i, 2) == 1, do: trip_id
        end
        |> Enum.reject(&is_nil/1)

      output_dir =
        Path.join(System.tmp_dir!(), "export_batch_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(output_dir) end)

      assert {:ok, file_paths} =
               Export.export_specs_to_directory(
                 org_id,
                 version_id,
                 FileSpec.get_specs(:full),
                 output_dir
               )

      trips_path = Enum.find(file_paths, &String.ends_with?(&1, "trips.txt"))
      rows = csv_rows(File.read!(trips_path))
      trip_ids = column(rows, "trip_id")

      assert length(trip_ids) == length(expected_trip_ids)
      assert MapSet.new(trip_ids) == MapSet.new(expected_trip_ids)

      routes_path = Enum.find(file_paths, &String.ends_with?(&1, "routes.txt"))

      assert column(csv_rows(File.read!(routes_path)), "route_id") == ["BATCH_ACTIVE"]
    end
  end

  describe "Export.build_zip/3 :pathways selection" do
    test "leaves pathway CSV selection unchanged", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      route_fixture(org_id, version_id, route_id: "R_INACTIVE", active: false)
      stop1 = stop_fixture(org_id, version_id, stop_id: "PATH_STOP1")
      stop2 = stop_fixture(org_id, version_id, stop_id: "PATH_STOP2")
      level_fixture(org_id, version_id, level_id: "PATH_LEVEL1")
      pathway_fixture(org_id, version_id, stop1.id, stop2.id, pathway_id: "PATH1")

      assert {:ok, zip_binary, []} = Export.build_zip(org_id, version_id, :pathways)
      files = unzip_files!(zip_binary)

      assert Map.has_key?(files, "stops.txt")
      assert Map.has_key?(files, "levels.txt")
      assert Map.has_key?(files, "pathways.txt")

      assert column(csv_rows(files["pathways.txt"]), "pathway_id") == ["PATH1"]
    end
  end

  # Seeds one complete inactive route closure plus eligible and dangling rows.
  defp seed_selection_closure!(org_id, version_id) do
    agency_fixture(org_id, version_id, agency_id: "AGENCY1")
    stop_fixture(org_id, version_id, stop_id: "STOP1")
    stop_fixture(org_id, version_id, stop_id: "STOP2")

    route_fixture(org_id, version_id, route_id: "R_ACTIVE", active: true)
    route_fixture(org_id, version_id, route_id: "R_NULL", active: nil)
    route_fixture(org_id, version_id, route_id: "R_INACTIVE", active: false)

    trip_fixture(org_id, version_id, "R_ACTIVE", trip_id: "T_ACTIVE", service_id: "SVC1")
    trip_fixture(org_id, version_id, "R_NULL", trip_id: "T_NULL", service_id: "SVC1")
    trip_fixture(org_id, version_id, "R_INACTIVE", trip_id: "T_INACTIVE", service_id: "SVC1")
    trip_fixture(org_id, version_id, "MISSING_ROUTE", trip_id: "T_DANGLING", service_id: "SVC1")

    for trip_id <- ["T_ACTIVE", "T_NULL", "T_INACTIVE", "T_DANGLING"] do
      stop_time_fixture(org_id, version_id, trip_id, "STOP1", stop_sequence: 1)
    end

    frequency_fixture(org_id, version_id, "T_ACTIVE",
      start_time: "06:00:00",
      end_time: "07:00:00"
    )

    frequency_fixture(org_id, version_id, "T_INACTIVE",
      start_time: "06:00:00",
      end_time: "07:00:00"
    )

    frequency_fixture(org_id, version_id, "MISSING_TRIP",
      start_time: "06:00:00",
      end_time: "07:00:00"
    )

    route_pattern_fixture(org_id, version_id, %{
      route_pattern_id: "P_ACTIVE",
      route_id: "R_ACTIVE"
    })

    route_pattern_fixture(org_id, version_id, %{
      route_pattern_id: "P_INACTIVE",
      route_id: "R_INACTIVE"
    })

    transfer_fixture(org_id, version_id, %{
      from_stop_id: "STOP1",
      to_stop_id: "STOP2",
      from_route_id: "R_ACTIVE"
    })

    transfer_fixture(org_id, version_id, %{
      from_stop_id: "STOP1",
      to_stop_id: "STOP2",
      from_route_id: "R_INACTIVE"
    })

    # Trip endpoint only: excluded even without any route endpoint field.
    transfer_fixture(org_id, version_id, %{
      from_stop_id: "STOP1",
      to_stop_id: "STOP2",
      from_trip_id: "T_INACTIVE"
    })

    transfer_fixture(org_id, version_id, %{
      from_stop_id: "STOP1",
      to_stop_id: "STOP2",
      from_route_id: "MISSING_ROUTE",
      from_trip_id: "MISSING_TRIP"
    })

    fare_rule_fixture(org_id, version_id, fare_id: "FARE1", route_id: "R_ACTIVE")
    fare_rule_fixture(org_id, version_id, fare_id: "FARE1", route_id: "R_INACTIVE")
    fare_rule_fixture(org_id, version_id, fare_id: "FARE1", route_id: "MISSING_ROUTE")

    attribution_fixture(org_id, version_id, attribution_id: "AT_ACTIVE", route_id: "R_ACTIVE")

    attribution_fixture(org_id, version_id,
      attribution_id: "AT_ROUTE_INACTIVE",
      route_id: "R_INACTIVE"
    )

    attribution_fixture(org_id, version_id,
      attribution_id: "AT_TRIP_INACTIVE",
      trip_id: "T_INACTIVE"
    )

    attribution_fixture(org_id, version_id,
      attribution_id: "AT_DANGLING",
      trip_id: "MISSING_TRIP"
    )
  end

  # Every closed-over row is gone; every eligible, NULL-active and dangling row
  # survives, with route/trip rows still in schema order.
  defp assert_closure_omitted!(files) do
    assert column(csv_rows(files["routes.txt"]), "route_id") == ["R_ACTIVE", "R_NULL"]

    trips_rows = csv_rows(files["trips.txt"])
    assert column(trips_rows, "route_id") == ["MISSING_ROUTE", "R_ACTIVE", "R_NULL"]
    assert column(trips_rows, "trip_id") == ["T_DANGLING", "T_ACTIVE", "T_NULL"]

    stop_times = csv_rows(files["stop_times.txt"])

    assert MapSet.new(column(stop_times, "trip_id")) ==
             MapSet.new(["T_ACTIVE", "T_NULL", "T_DANGLING"])

    frequencies = csv_rows(files["frequencies.txt"])
    assert MapSet.new(column(frequencies, "trip_id")) == MapSet.new(["T_ACTIVE", "MISSING_TRIP"])

    assert column(csv_rows(files["route_patterns.txt"]), "route_pattern_id") == ["P_ACTIVE"]

    transfers = csv_rows(files["transfers.txt"])
    assert length(transfers) == 2

    assert MapSet.new(column(transfers, "from_route_id")) ==
             MapSet.new(["R_ACTIVE", "MISSING_ROUTE"])

    assert MapSet.new(column(transfers, "from_trip_id")) == MapSet.new(["", "MISSING_TRIP"])

    assert MapSet.new(column(csv_rows(files["fare_rules.txt"]), "route_id")) ==
             MapSet.new(["R_ACTIVE", "MISSING_ROUTE"])

    assert MapSet.new(column(csv_rows(files["attributions.txt"]), "attribution_id")) ==
             MapSet.new(["AT_ACTIVE", "AT_DANGLING"])
  end

  defp assert_shared_rows_retained!(files) do
    assert column(csv_rows(files["agency.txt"]), "agency_id") == ["AGENCY1"]
    assert column(csv_rows(files["stops.txt"]), "stop_id") == ["STOP1", "STOP2"]
  end

  defp fare_rule_fixture(org_id, version_id, attrs) do
    %FareRule{}
    |> FareRule.changeset(
      Map.merge(
        %{organization_id: org_id, gtfs_version_id: version_id},
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end

  defp attribution_fixture(org_id, version_id, attrs) do
    %Attribution{}
    |> Attribution.changeset(
      Map.merge(
        %{
          organization_name: "Fixture Attribution",
          organization_id: org_id,
          gtfs_version_id: version_id
        },
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end

  defp unzip_files!(zip_binary) do
    {:ok, files} = :zip.unzip(zip_binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  defp csv_rows(content) do
    [header | rows] = String.split(to_string(content), "\n", trim: true)
    columns = String.split(header, ",")

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(String.split(row, ","))
      |> Map.new()
    end)
  end

  defp column(rows, name), do: Enum.map(rows, &Map.fetch!(&1, name))
end
