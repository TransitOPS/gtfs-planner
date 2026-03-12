defmodule GtfsPlanner.Otp.StationMaterializerTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Gtfs.{
    Attribution,
    Calendar,
    CalendarDate,
    FareRule,
    Frequency
  }
  alias GtfsPlanner.Otp.ArtifactPath
  alias GtfsPlanner.Otp.StationMaterializer
  alias GtfsPlanner.Otp.StationMaterializer.GtfsZipReader

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "get_or_build_gtfs_zip/3" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)

      on_exit(fn ->
        File.rm_rf(ArtifactPath.artifact_dir(organization.id, gtfs_version.id))
      end)

      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "returns blocking issue when station_stop_id is missing", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:error, [issue]} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 []
               )

      assert issue.code == :invalid_station_stop_id
      assert issue.severity == :blocking
    end

    test "delegates to OTP materializer and returns station metadata", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      %{
        station_stop_id: station_stop_id,
        trip_id: trip_id,
        route_id: route_id,
        service_id: service_id,
        shape_id: shape_id,
        agency_id: agency_id
      } =
        seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      _kept_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_index: 0.0,
          level_name: "Level 1"
        })

      _dropped_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L2_UNUSED",
          level_index: 1.0,
          level_name: "Unused Level"
        })

      _unused_agency =
        agency_fixture(organization.id, gtfs_version.id, %{agency_id: "agency_unused"})

      create_calendar!(organization.id, gtfs_version.id, "other_service")

      create_calendar_date!(organization.id, gtfs_version.id, service_id, %{date: ~D[2026-01-02]})

      create_calendar_date!(organization.id, gtfs_version.id, "other_service", %{
        date: ~D[2026-01-03]
      })

      create_frequency!(organization.id, gtfs_version.id, trip_id, %{start_time: "08:00:00"})
      create_frequency!(organization.id, gtfs_version.id, "other_trip", %{start_time: "09:00:00"})
      create_attribution!(organization.id, gtfs_version.id, %{attribution_id: "global_attr"})

      create_attribution!(organization.id, gtfs_version.id, %{
        attribution_id: "kept_attr",
        route_id: route_id,
        trip_id: trip_id
      })

      create_attribution!(organization.id, gtfs_version.id, %{
        attribution_id: "drop_route_attr",
        route_id: "route_not_kept"
      })

      create_attribution!(organization.id, gtfs_version.id, %{
        attribution_id: "drop_trip_attr",
        trip_id: "trip_not_kept"
      })

      assert {:ok, zip_path, meta} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 station_stop_id: station_stop_id
               )

      assert File.regular?(zip_path)
      assert Path.basename(zip_path) == "station_gtfs.zip"
      assert meta.station_stop_id == station_stop_id
      assert meta.kept_level_ids == ["L1"]
      assert meta.kept_trip_ids == [trip_id]
      assert meta.kept_route_ids == [route_id]
      assert meta.kept_service_ids == [service_id]
      assert meta.kept_shape_ids == expected_shape_ids(shape_id)
      assert meta.kept_agency_ids == expected_agency_ids(agency_id)
      assert meta.kept_fare_ids == []
      assert meta.station_preflight_warning_issues == []
      assert meta.extension_warning_issues == []

      expected_summary = %{
        "stops.txt" => %{
          kept_count: 2,
          dropped_count: 1,
          missing_file: false,
          blocking_issue_count: 0
        },
        "levels.txt" => %{
          kept_count: 1,
          dropped_count: 1,
          missing_file: false,
          blocking_issue_count: 0,
          warning_issue_count: 0,
          missing_level_count: 0
        },
        "pathways.txt" => %{
          kept_count: 0,
          dropped_count: 1,
          missing_file: false,
          blocking_issue_count: 0
        },
        "transfers.txt" => %{
          kept_count: 0,
          dropped_count: 0,
          missing_file: true,
          blocking_issue_count: 0
        },
        "stop_times.txt" => %{
          kept_count: 1,
          dropped_count: 0,
          missing_file: false,
          blocking_issue_count: 0
        },
        "trips.txt" => %{
          kept_count: 1,
          dropped_count: 0,
          missing_file: false,
          blocking_issue_count: 0
        },
        "attributions.txt" => %{
          kept_count: 2,
          dropped_count: 2,
          missing_file: false,
          blocking_issue_count: 0
        },
        "routes.txt" => %{
          kept_count: 1,
          dropped_count: 0,
          missing_file: false,
          blocking_issue_count: 0
        },
        "agency.txt" => %{
          kept_count: 1,
          dropped_count: 1,
          missing_file: false,
          blocking_issue_count: 0
        },
        "calendar.txt" => %{
          kept_count: 1,
          dropped_count: 1,
          missing_file: false,
          blocking_issue_count: 0
        },
        "calendar_dates.txt" => %{
          kept_count: 1,
          dropped_count: 1,
          missing_file: false,
          blocking_issue_count: 0
        },
        "frequencies.txt" => %{
          kept_count: 0,
          dropped_count: 0,
          missing_file: true,
          blocking_issue_count: 0
        },
        "shapes.txt" => %{
          kept_count: 0,
          dropped_count: 0,
          missing_file: true,
          blocking_issue_count: 0
        },
        "fare_rules.txt" => %{
          kept_count: 0,
          dropped_count: 0,
          missing_file: true,
          blocking_issue_count: 0
        },
        "fare_attributes.txt" => %{
          kept_count: 0,
          dropped_count: 0,
          missing_file: true,
          blocking_issue_count: 0,
          warning_issue_count: 1
        }
      }

      normalized_expected_summary =
        Enum.into(expected_summary, %{}, fn {file_name, summary} ->
          {file_name, Map.put_new(summary, :warning_issue_count, 0)}
        end)

      assert Map.take(meta.station_feed_summary, Map.keys(normalized_expected_summary)) ==
               normalized_expected_summary

      assert meta.source_zip_path != zip_path
      assert meta.station_zip_path == zip_path
      assert File.regular?(meta.source_zip_path)

      assert {:ok, tables} = GtfsZipReader.read_tables(zip_path)
      stops_rows = Map.get(tables, "stops.txt", %{rows: []}).rows

      levels_rows = Map.get(tables, "levels.txt", %{rows: []}).rows

      kept_stop_ids =
        stops_rows
        |> Enum.map(fn row -> row.values["stop_id"] end)
        |> Enum.sort()

      assert kept_stop_ids == ["seed_station", "seed_stop_a"]

      assert Enum.map(levels_rows, & &1.values["level_id"]) == ["L1"]

      pathways_rows = Map.get(tables, "pathways.txt", %{rows: []}).rows
      assert pathways_rows == []

      stop_times_rows = Map.get(tables, "stop_times.txt", %{rows: []}).rows
      assert length(stop_times_rows) == 1
      assert Enum.at(stop_times_rows, 0).values["stop_id"] == "seed_stop_a"

      trips_rows = Map.get(tables, "trips.txt", %{rows: []}).rows
      assert length(trips_rows) == 1
      assert Enum.at(trips_rows, 0).values["trip_id"] == trip_id

      attributions_rows = Map.get(tables, "attributions.txt", %{rows: []}).rows
      assert length(attributions_rows) == 2

      attribution_ids =
        attributions_rows
        |> Enum.map(fn row -> row.values["attribution_id"] end)
        |> Enum.sort()

      assert attribution_ids == ["global_attr", "kept_attr"]

      routes_rows = Map.get(tables, "routes.txt", %{rows: []}).rows
      assert length(routes_rows) == 1
      assert Enum.at(routes_rows, 0).values["route_id"] == route_id

      agency_rows = Map.get(tables, "agency.txt", %{rows: []}).rows
      assert length(agency_rows) == 1
      assert Enum.at(agency_rows, 0).values["agency_id"] == agency_id

      calendar_rows = Map.get(tables, "calendar.txt", %{rows: []}).rows
      assert length(calendar_rows) == 1
      assert Enum.at(calendar_rows, 0).values["service_id"] == service_id

      calendar_dates_rows = Map.get(tables, "calendar_dates.txt", %{rows: []}).rows
      assert length(calendar_dates_rows) == 1
      assert Enum.at(calendar_dates_rows, 0).values["service_id"] == service_id

      frequencies_rows = Map.get(tables, "frequencies.txt", %{rows: []}).rows
      assert frequencies_rows == []

      fare_rules_rows = Map.get(tables, "fare_rules.txt", %{rows: []}).rows
      assert fare_rules_rows == []

      fare_attributes_rows = Map.get(tables, "fare_attributes.txt", %{rows: []}).rows
      assert fare_attributes_rows == []
    end

    test "records warning metadata when fare_rules is absent", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      %{station_stop_id: station_stop_id} =
        seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      _kept_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_index: 0.0,
          level_name: "Level 1"
        })

      assert {:ok, zip_path, meta} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 station_stop_id: station_stop_id
               )

      assert File.regular?(zip_path)
      assert meta.kept_fare_ids == []
      assert meta.extension_warning_issues == []

      assert meta.station_feed_summary["fare_rules.txt"] == %{
               kept_count: 0,
               dropped_count: 0,
               missing_file: true,
               blocking_issue_count: 0,
               warning_issue_count: 0
             }

      assert meta.station_feed_summary["levels.txt"] == %{
               kept_count: 1,
               dropped_count: 0,
               missing_file: false,
               blocking_issue_count: 0,
               warning_issue_count: 0,
               missing_level_count: 0
             }

      assert meta.station_feed_summary["fare_attributes.txt"] == %{
               kept_count: 0,
               dropped_count: 0,
               missing_file: true,
               blocking_issue_count: 0,
               warning_issue_count: 1
             }

      assert {:ok, tables} = GtfsZipReader.read_tables(zip_path)

      fare_attributes_rows = Map.get(tables, "fare_attributes.txt", %{rows: []}).rows
      assert fare_attributes_rows == []

      fare_rules_rows = Map.get(tables, "fare_rules.txt", %{rows: []}).rows
      assert fare_rules_rows == []
    end

    test "succeeds with warning metadata when fare rule references missing fare attribute", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      %{station_stop_id: station_stop_id, route_id: route_id} =
        seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      _trip_for_fare_rule_scope =
        trip_fixture(organization.id, gtfs_version.id, route_id, %{
          trip_id: "trip_missing_fare_attr",
          service_id: "seed_service"
        })

      create_fare_rule!(organization.id, gtfs_version.id, %{
        fare_id: "fare_without_attribute",
        route_id: route_id
      })

      assert {:ok, _zip_path, meta} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 station_stop_id: station_stop_id
               )

      assert meta.integrity_summary.blocking_issue_count == 0

      assert Map.has_key?(meta.integrity_summary, :warning_issue_count)
      assert Map.has_key?(meta.station_feed_summary["fare_rules.txt"], :warning_issue_count)
    end

    test "returns blocking stop_times trip integrity issue with blocking severity", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      %{station_stop_id: station_stop_id} =
        seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      stop_time_fixture(
        organization.id,
        gtfs_version.id,
        "missing_trip_for_stop_time",
        "seed_stop_a",
        %{stop_sequence: 888}
      )

      assert {:error, issues} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 station_stop_id: station_stop_id
               )

      issue = Enum.find(issues, &(&1.code == :stop_times_trip_id_missing_trip))

      assert issue.severity in [:blocking, :error]

      context = Map.get(issue, :context) || Map.get(issue, :details) || %{}

      assert context.source_file == "stop_times.txt"
      assert context.source_field == "trip_id"
      assert context.target_file == "trips.txt"
      assert context.target_field == "trip_id"
      assert context.invalid_count > 0
    end

    test "returns blocking issues when referential integrity validation fails", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      %{station_stop_id: station_stop_id, route_id: route_id} =
        seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      missing_service_trip =
        trip_fixture(
          organization.id,
          gtfs_version.id,
          route_id,
          %{service_id: "missing_service_for_station_filter"}
        )

      stop_time_fixture(
        organization.id,
        gtfs_version.id,
        missing_service_trip.trip_id,
        "seed_stop_a",
        %{stop_sequence: 999}
      )

      assert {:error, issues} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 station_stop_id: station_stop_id
               )

      assert Enum.any?(issues, fn issue -> issue.severity == :blocking end)

      assert Enum.any?(issues, fn issue ->
               issue.code in [:trips_service_id_missing_calendar, :trip_service_not_found]
             end)
    end

    test "returns blocking issues when station coordinate preflight fails", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      %{station_stop_id: station_stop_id} =
        seed_minimum_required_gtfs!(organization.id, gtfs_version.id,
          station_attrs: %{stop_lat: nil}
        )

      assert {:error, issues} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 station_stop_id: station_stop_id
               )

      assert Enum.any?(issues, fn issue -> issue.severity == :blocking end)

      assert Enum.any?(issues, fn issue ->
               issue.code == :station_stop_lat_missing and
                 issue.context.file == "stops.txt" and
                 issue.context.field == "stop_lat"
             end)
    end

    test "packages station_gtfs.zip with deterministic file and row ordering", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      %{station_stop_id: station_stop_id, trip_id: trip_id} =
        seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      _boarding_area_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "seed_boarding_b",
          location_type: 4,
          parent_station: "seed_stop_a",
          level_id: "L1"
        })

      _boarding_area_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "seed_boarding_a",
          location_type: 4,
          parent_station: "seed_stop_a",
          level_id: "L1"
        })

      stop_time_fixture(
        organization.id,
        gtfs_version.id,
        trip_id,
        "seed_boarding_b",
        %{stop_sequence: 20}
      )

      stop_time_fixture(
        organization.id,
        gtfs_version.id,
        trip_id,
        "seed_boarding_a",
        %{stop_sequence: 3}
      )

      assert {:ok, zip_path, _meta} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 station_stop_id: station_stop_id
               )

      assert {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])

      zip_file_names =
        entries
        |> Enum.map(fn {name, _content} -> to_string(name) end)

      assert zip_file_names == Enum.sort(zip_file_names)

      assert {:ok, tables} = GtfsZipReader.read_tables(zip_path)

      stops_rows = Map.get(tables, "stops.txt", %{rows: []}).rows

      assert Enum.map(stops_rows, fn row -> row.values["stop_id"] end) == [
               "seed_boarding_a",
               "seed_boarding_b",
               "seed_station",
               "seed_stop_a"
             ]

      stop_times_rows = Map.get(tables, "stop_times.txt", %{rows: []}).rows

      stop_time_pairs =
        Enum.map(stop_times_rows, fn row ->
          {row.values["stop_id"], row.values["stop_sequence"]}
        end)

      assert stop_time_pairs ==
               Enum.sort_by(stop_time_pairs, fn {stop_id, stop_sequence} ->
                 {parse_stop_sequence(stop_sequence), stop_id}
               end)

      assert Enum.member?(stop_time_pairs, {"seed_boarding_a", "3"})
      assert Enum.member?(stop_time_pairs, {"seed_boarding_b", "20"})
    end

    test "produces deterministic station_gtfs.zip file set across repeated builds", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      %{station_stop_id: station_stop_id} =
        seed_minimum_required_gtfs!(organization.id, gtfs_version.id)

      assert {:ok, first_zip_path, first_meta} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 station_stop_id: station_stop_id
               )

      assert {:ok, second_zip_path, second_meta} =
               StationMaterializer.get_or_build_gtfs_zip(
                 organization.id,
                 gtfs_version.id,
                 station_stop_id: station_stop_id
               )

      assert first_zip_path == second_zip_path

      assert {:ok, source_entries} =
               :zip.unzip(String.to_charlist(first_meta.source_zip_path), [:memory])

      assert {:ok, first_entries} = :zip.unzip(String.to_charlist(first_zip_path), [:memory])
      assert {:ok, second_entries} = :zip.unzip(String.to_charlist(second_zip_path), [:memory])

      source_file_names =
        source_entries
        |> Enum.map(fn {name, _content} -> to_string(name) end)
        |> Enum.sort()

      first_file_names =
        first_entries
        |> Enum.map(fn {name, _content} -> to_string(name) end)

      second_file_names =
        second_entries
        |> Enum.map(fn {name, _content} -> to_string(name) end)

      assert first_file_names == Enum.sort(first_file_names)
      assert second_file_names == Enum.sort(second_file_names)
      assert first_file_names == second_file_names
      assert first_file_names == source_file_names

      assert normalize_zip_entries(first_entries) == normalize_zip_entries(second_entries)
      assert second_meta.station_zip_path == first_zip_path
    end
  end

  defp seed_minimum_required_gtfs!(organization_id, gtfs_version_id, opts \\ []) do
    agency = agency_fixture(organization_id, gtfs_version_id)

    station_attrs =
      opts
      |> Keyword.get(:station_attrs, %{})
      |> Enum.into(%{})

    station =
      stop_fixture(
        organization_id,
        gtfs_version_id,
        %{
          stop_id: "seed_station",
          location_type: 1,
          parent_station: nil
        }
        |> Map.merge(station_attrs)
      )

    stop_a =
      stop_fixture(organization_id, gtfs_version_id, %{
        stop_id: "seed_stop_a",
        parent_station: station.stop_id,
        level_id: "L1"
      })

    stop_b = stop_fixture(organization_id, gtfs_version_id, %{stop_id: "seed_stop_b"})

    route = route_fixture(organization_id, gtfs_version_id, %{agency_id: agency.agency_id})

    trip =
      trip_fixture(organization_id, gtfs_version_id, route.route_id, %{
        service_id: "seed_service",
        shape_id: "seed_shape"
      })

    stop_time_fixture(organization_id, gtfs_version_id, trip.trip_id, stop_a.stop_id)
    pathway_fixture(organization_id, gtfs_version_id, stop_a.stop_id, stop_b.stop_id)

    create_calendar!(organization_id, gtfs_version_id, trip.service_id)

    %{
      station_stop_id: station.stop_id,
      trip_id: trip.trip_id,
      route_id: route.route_id,
      agency_id: route.agency_id,
      service_id: trip.service_id,
      shape_id: trip.shape_id
    }
  end

  defp create_calendar!(organization_id, gtfs_version_id, service_id) do
    attrs = %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31],
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    %Calendar{}
    |> Calendar.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_calendar_date!(organization_id, gtfs_version_id, service_id, attrs) do
    attrs =
      Map.merge(
        %{
          service_id: service_id,
          date: ~D[2026-01-01],
          exception_type: 1,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        },
        attrs
      )

    %CalendarDate{}
    |> CalendarDate.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_frequency!(organization_id, gtfs_version_id, trip_id, attrs) do
    attrs =
      Map.merge(
        %{
          trip_id: trip_id,
          start_time: "08:00:00",
          end_time: "10:00:00",
          headway_secs: 600,
          exact_times: 0,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        },
        attrs
      )

    %Frequency{}
    |> Frequency.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_attribution!(organization_id, gtfs_version_id, attrs) do
    attrs =
      Map.merge(
        %{
          organization_name: "Test Attribution Org",
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        },
        attrs
      )

    %Attribution{}
    |> Attribution.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_fare_rule!(organization_id, gtfs_version_id, attrs) do
    attrs =
      Map.merge(
        %{
          fare_id: "fare_#{System.unique_integer([:positive])}",
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        },
        attrs
      )

    %FareRule{}
    |> FareRule.changeset(attrs)
    |> Repo.insert!()
  end

  defp expected_shape_ids(nil), do: []
  defp expected_shape_ids(""), do: []
  defp expected_shape_ids(shape_id), do: [shape_id]

  defp parse_stop_sequence(sequence) when is_binary(sequence) do
    case Integer.parse(sequence) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp parse_stop_sequence(sequence) when is_integer(sequence), do: sequence
  defp parse_stop_sequence(_sequence), do: 0

  defp expected_agency_ids(nil), do: []
  defp expected_agency_ids(""), do: []
  defp expected_agency_ids(agency_id), do: [agency_id]

  defp normalize_zip_entries(entries) do
    entries
    |> Enum.map(fn {name, content} -> {to_string(name), content} end)
    |> Enum.sort_by(fn {name, _content} -> name end)
  end
end
