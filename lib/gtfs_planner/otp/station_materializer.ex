defmodule GtfsPlanner.Otp.StationMaterializer do
  @moduledoc """
  Station-scoped GTFS materializer runtime boundary.

  This module currently preserves runtime compatibility by delegating to the
  existing OTP GTFS materializer and returning the required runtime contract.
  """

  alias GtfsPlanner.Otp.Materializer
  alias GtfsPlanner.Otp.ArtifactPath
  alias GtfsPlanner.Otp.StationMaterializer.GtfsZipReader
  alias GtfsPlanner.Otp.StationMaterializer.StationClosure

  @filtered_table_files [
    "agency.txt",
    "attributions.txt",
    "calendar.txt",
    "calendar_dates.txt",
    "fare_attributes.txt",
    "fare_rules.txt",
    "frequencies.txt",
    "levels.txt",
    "pathways.txt",
    "routes.txt",
    "shapes.txt",
    "stop_times.txt",
    "stops.txt",
    "transfers.txt",
    "trips.txt"
  ]

  @known_optional_extension_file_mappings %{
    "areas.txt" => :passthrough,
    "booking_rules.txt" => :passthrough,
    "fare_leg_join_rules.txt" => :passthrough,
    "fare_leg_rules.txt" => :passthrough,
    "fare_media.txt" => :passthrough,
    "fare_products.txt" => :passthrough,
    "fare_transfer_rules.txt" => :passthrough,
    "feed_info.txt" => :passthrough,
    "locations.txt" => :passthrough,
    "networks.txt" => :passthrough,
    "rider_categories.txt" => :passthrough,
    "route_networks.txt" => :passthrough,
    "route_patterns.txt" => :passthrough,
    "stop_areas.txt" => :passthrough,
    "timeframes.txt" => :passthrough,
    "translations.txt" => :passthrough
  }

  @integrity_issue_severity_by_code %{
    stop_times_trip_id_missing_trip: :blocking,
    stop_times_stop_id_missing_stop: :blocking,
    trips_route_id_missing_route: :blocking,
    trips_service_id_missing_calendar: :blocking,
    pathways_from_stop_id_missing_stop: :blocking,
    pathways_to_stop_id_missing_stop: :blocking,
    transfers_from_stop_id_missing_stop: :blocking,
    transfers_to_stop_id_missing_stop: :blocking,
    trips_shape_id_missing_shape: :warning,
    fare_rules_fare_id_missing_fare_attributes: :warning
  }

  @type issues :: [map()]
  @type meta :: map()

  @spec get_or_build_gtfs_zip(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, String.t(), meta()} | {:error, issues()}
  def get_or_build_gtfs_zip(organization_id, gtfs_version_id, opts) when is_list(opts) do
    case Keyword.get(opts, :station_stop_id) do
      station_stop_id when is_binary(station_stop_id) and station_stop_id != "" ->
        delegate_materializer(organization_id, gtfs_version_id, station_stop_id, opts)

      invalid_station_stop_id ->
        {:error, [invalid_station_stop_id_issue(invalid_station_stop_id)]}
    end
  end

  defp delegate_materializer(organization_id, gtfs_version_id, station_stop_id, opts) do
    source_materializer_opts = source_materializer_opts(opts)

    case Materializer.get_or_build_gtfs_zip(
           organization_id,
           gtfs_version_id,
           source_materializer_opts
         ) do
      {:ok, source_zip_path, source_meta} ->
        build_station_zip(
          organization_id,
          gtfs_version_id,
          station_stop_id,
          source_zip_path,
          source_meta
        )

      {:error, issues} ->
        {:error, issues}
    end
  end

  defp source_materializer_opts(opts) do
    opts
    |> Keyword.put(:preflight_mode, :lenient)
    |> Keyword.put_new(:pathways_preflight_fun, &skip_source_pathways_preflight/3)
  end

  defp skip_source_pathways_preflight(_organization_id, _gtfs_version_id, _opts) do
    {:ok, %{blocking_errors: [], warnings: [], metadata: %{scope: :station_source}}}
  end

  defp build_station_zip(
         organization_id,
         gtfs_version_id,
         station_stop_id,
         source_zip_path,
         source_meta
       ) do
    station_zip_path = station_zip_path(organization_id, gtfs_version_id, station_stop_id)

    with {:ok, station_zip_binary, filter_meta} <-
           build_station_zip_binary(source_zip_path, station_stop_id),
         :ok <- File.mkdir_p(Path.dirname(station_zip_path)),
         :ok <- File.write(station_zip_path, station_zip_binary) do
      {:ok, station_zip_path,
       merge_station_meta(
         source_meta,
         station_stop_id,
         source_zip_path,
         station_zip_path,
         filter_meta
       )}
    else
      {:error, issues} when is_list(issues) ->
        {:error, issues}

      {:error, reason} ->
        {:error, [station_zip_copy_failed_issue(reason, source_zip_path, station_zip_path)]}
    end
  end

  defp build_station_zip_binary(source_zip_path, station_stop_id) do
    with {:ok, tables} <- GtfsZipReader.read_tables(source_zip_path),
         %{rows: stop_rows} <- Map.get(tables, "stops.txt", %{rows: []}),
         {:ok, _station_row} <-
           StationClosure.validate_station_prerequisites(stop_rows, station_stop_id),
         kept_stop_ids <- StationClosure.derive_kept_stop_ids(stop_rows, station_stop_id),
         {filtered_stops_rows, kept_level_ids, kept_zone_ids} <-
           filter_stops_rows_and_collect_level_ids(stop_rows, kept_stop_ids),
         {filtered_levels_rows, levels_summary} <-
           filter_levels_rows(Map.get(tables, "levels.txt"), kept_level_ids),
         {filtered_pathways_rows, pathways_summary} <-
           filter_pathways_rows(Map.get(tables, "pathways.txt"), kept_stop_ids),
         {filtered_transfers_rows, transfers_summary} <-
           filter_transfers_rows(Map.get(tables, "transfers.txt"), kept_stop_ids),
         {filtered_stop_times_rows, kept_trip_ids, stop_times_summary} <-
           filter_stop_times_rows(Map.get(tables, "stop_times.txt"), kept_stop_ids),
         {filtered_trips_rows, kept_route_ids, kept_service_ids, kept_shape_ids, trips_summary} <-
           filter_trips_rows(Map.get(tables, "trips.txt"), kept_trip_ids),
         {filtered_attributions_rows, attributions_summary} <-
           filter_attributions_rows(
             Map.get(tables, "attributions.txt"),
             kept_route_ids,
             kept_trip_ids
           ),
         {filtered_routes_rows, kept_agency_ids, routes_summary} <-
           filter_routes_rows(Map.get(tables, "routes.txt"), kept_route_ids),
         {filtered_agency_rows, agency_summary} <-
           filter_agency_rows(Map.get(tables, "agency.txt"), kept_agency_ids),
         {filtered_calendar_rows, calendar_summary} <-
           filter_calendar_rows(Map.get(tables, "calendar.txt"), kept_service_ids),
         {filtered_calendar_dates_rows, calendar_dates_summary} <-
           filter_calendar_dates_rows(Map.get(tables, "calendar_dates.txt"), kept_service_ids),
         {filtered_frequencies_rows, frequencies_summary} <-
           filter_frequencies_rows(Map.get(tables, "frequencies.txt"), kept_trip_ids),
         {filtered_shapes_rows, shapes_summary} <-
           filter_shapes_rows(Map.get(tables, "shapes.txt"), kept_shape_ids),
         {filtered_fare_rules_rows, kept_fare_ids, fare_rules_summary} <-
           filter_fare_rules_rows(
             Map.get(tables, "fare_rules.txt"),
             kept_route_ids,
             kept_zone_ids
           ),
         {filtered_fare_attributes_rows, fare_attributes_summary} <-
           filter_fare_attributes_rows(
             Map.get(tables, "fare_attributes.txt"),
             kept_fare_ids,
             fare_rules_summary.missing_file
           ),
         integrity_result =
           validate_referential_integrity(%{
             stop_times_rows: filtered_stop_times_rows,
             stops_rows: filtered_stops_rows,
             trips_rows: filtered_trips_rows,
             routes_rows: filtered_routes_rows,
             calendar_rows: filtered_calendar_rows,
             calendar_dates_rows: filtered_calendar_dates_rows,
             shapes_missing_file: shapes_summary.missing_file,
             shapes_rows: filtered_shapes_rows,
             pathways_rows: filtered_pathways_rows,
             transfers_rows: filtered_transfers_rows,
             fare_rules_rows: filtered_fare_rules_rows,
             fare_attributes_rows: filtered_fare_attributes_rows
           }),
         :ok <- ensure_no_blocking_integrity_issues(integrity_result),
         {:ok, station_preflight_warning_issues} <-
           run_station_scope_preflight(filtered_stops_rows),
         {extension_file_summaries, extension_warning_issues} <-
           extension_file_summaries_and_warnings(tables),
         {:ok, station_zip_binary} <-
           replace_tables(source_zip_path, %{
             "stops.txt" =>
               render_table_csv("stops.txt", Map.get(tables, "stops.txt"), filtered_stops_rows),
             "levels.txt" =>
               render_table_csv("levels.txt", Map.get(tables, "levels.txt"), filtered_levels_rows),
             "pathways.txt" =>
               render_table_csv(
                 "pathways.txt",
                 Map.get(tables, "pathways.txt"),
                 filtered_pathways_rows
               ),
             "transfers.txt" =>
               render_table_csv(
                 "transfers.txt",
                 Map.get(tables, "transfers.txt"),
                 filtered_transfers_rows
               ),
             "stop_times.txt" =>
               render_table_csv(
                 "stop_times.txt",
                 Map.get(tables, "stop_times.txt"),
                 filtered_stop_times_rows
               ),
             "trips.txt" =>
               render_table_csv("trips.txt", Map.get(tables, "trips.txt"), filtered_trips_rows),
             "attributions.txt" =>
               render_table_csv(
                 "attributions.txt",
                 Map.get(tables, "attributions.txt"),
                 filtered_attributions_rows
               ),
             "routes.txt" =>
               render_table_csv("routes.txt", Map.get(tables, "routes.txt"), filtered_routes_rows),
             "agency.txt" =>
               render_table_csv("agency.txt", Map.get(tables, "agency.txt"), filtered_agency_rows),
             "calendar.txt" =>
               render_table_csv(
                 "calendar.txt",
                 Map.get(tables, "calendar.txt"),
                 filtered_calendar_rows
               ),
             "calendar_dates.txt" =>
               render_table_csv(
                 "calendar_dates.txt",
                 Map.get(tables, "calendar_dates.txt"),
                 filtered_calendar_dates_rows
               ),
             "frequencies.txt" =>
               render_table_csv(
                 "frequencies.txt",
                 Map.get(tables, "frequencies.txt"),
                 filtered_frequencies_rows
               ),
             "shapes.txt" =>
               render_table_csv(
                 "shapes.txt",
                 Map.get(tables, "shapes.txt"),
                 filtered_shapes_rows
               ),
             "fare_rules.txt" =>
               render_table_csv(
                 "fare_rules.txt",
                 Map.get(tables, "fare_rules.txt"),
                 filtered_fare_rules_rows
               ),
             "fare_attributes.txt" =>
               render_table_csv(
                 "fare_attributes.txt",
                 Map.get(tables, "fare_attributes.txt"),
                 filtered_fare_attributes_rows
               )
           }) do
      station_feed_summary =
        %{
          "stops.txt" => %{
            kept_count: length(filtered_stops_rows),
            dropped_count: length(stop_rows) - length(filtered_stops_rows),
            missing_file: false,
            blocking_issue_count: 0,
            warning_issue_count: 0
          },
          "levels.txt" => levels_summary,
          "pathways.txt" => pathways_summary,
          "transfers.txt" => transfers_summary,
          "stop_times.txt" => stop_times_summary,
          "trips.txt" => trips_summary,
          "attributions.txt" => attributions_summary,
          "routes.txt" => routes_summary,
          "agency.txt" => agency_summary,
          "calendar.txt" => calendar_summary,
          "calendar_dates.txt" => calendar_dates_summary,
          "frequencies.txt" => frequencies_summary,
          "shapes.txt" => shapes_summary,
          "fare_rules.txt" => fare_rules_summary,
          "fare_attributes.txt" => fare_attributes_summary
        }
        |> Map.merge(extension_file_summaries)
        |> normalize_station_feed_summary_issue_counts()
        |> merge_integrity_issue_counts(integrity_result.summary.per_rule_counts)

      {:ok, station_zip_binary,
       %{
         station_feed_summary: station_feed_summary,
         integrity_summary: integrity_result.summary,
         integrity_warning_issues: integrity_result.warning_issues,
         station_preflight_warning_issues: station_preflight_warning_issues,
         extension_warning_issues: extension_warning_issues,
         kept_level_ids: kept_level_ids,
         kept_zone_ids: kept_zone_ids,
         kept_trip_ids: kept_trip_ids,
         kept_route_ids: kept_route_ids,
         kept_service_ids: kept_service_ids,
         kept_shape_ids: kept_shape_ids,
         kept_agency_ids: kept_agency_ids,
         kept_fare_ids: kept_fare_ids
       }}
    end
  end

  defp validate_referential_integrity(rows_by_file) do
    stop_ids = id_set(rows_by_file.stops_rows, "stop_id")
    trip_ids = id_set(rows_by_file.trips_rows, "trip_id")
    route_ids = id_set(rows_by_file.routes_rows, "route_id")

    service_ids =
      MapSet.union(
        id_set(rows_by_file.calendar_rows, "service_id"),
        id_set(rows_by_file.calendar_dates_rows, "service_id")
      )

    shape_ids = id_set(rows_by_file.shapes_rows, "shape_id")
    fare_ids = id_set(rows_by_file.fare_attributes_rows, "fare_id")

    per_rule_results =
      [
        integrity_issue(
          rows_by_file.stop_times_rows,
          "trip_id",
          trip_ids,
          :stop_times_trip_id_missing_trip,
          "stop_times.txt",
          "trips.txt",
          "trip_id"
        ),
        integrity_issue(
          rows_by_file.stop_times_rows,
          "stop_id",
          stop_ids,
          :stop_times_stop_id_missing_stop,
          "stop_times.txt",
          "stops.txt",
          "stop_id"
        ),
        integrity_issue(
          rows_by_file.trips_rows,
          "route_id",
          route_ids,
          :trips_route_id_missing_route,
          "trips.txt",
          "routes.txt",
          "route_id"
        ),
        integrity_issue(
          rows_by_file.trips_rows,
          "service_id",
          service_ids,
          :trips_service_id_missing_calendar,
          "trips.txt",
          "calendar.txt|calendar_dates.txt",
          "service_id"
        ),
        integrity_issue(
          rows_by_file.trips_rows,
          "shape_id",
          shape_ids,
          :trips_shape_id_missing_shape,
          "trips.txt",
          "shapes.txt",
          "shape_id",
          allow_blank: true,
          skip_check: rows_by_file.shapes_missing_file
        ),
        integrity_issue(
          rows_by_file.pathways_rows,
          "from_stop_id",
          stop_ids,
          :pathways_from_stop_id_missing_stop,
          "pathways.txt",
          "stops.txt",
          "stop_id"
        ),
        integrity_issue(
          rows_by_file.pathways_rows,
          "to_stop_id",
          stop_ids,
          :pathways_to_stop_id_missing_stop,
          "pathways.txt",
          "stops.txt",
          "stop_id"
        ),
        integrity_issue(
          rows_by_file.transfers_rows,
          "from_stop_id",
          stop_ids,
          :transfers_from_stop_id_missing_stop,
          "transfers.txt",
          "stops.txt",
          "stop_id"
        ),
        integrity_issue(
          rows_by_file.transfers_rows,
          "to_stop_id",
          stop_ids,
          :transfers_to_stop_id_missing_stop,
          "transfers.txt",
          "stops.txt",
          "stop_id"
        ),
        integrity_issue(
          rows_by_file.fare_rules_rows,
          "fare_id",
          fare_ids,
          :fare_rules_fare_id_missing_fare_attributes,
          "fare_rules.txt",
          "fare_attributes.txt",
          "fare_id"
        )
      ]

    blocking_issues =
      per_rule_results
      |> Enum.filter(&(&1.severity == :blocking and not is_nil(&1.issue)))
      |> Enum.map(& &1.issue)

    warning_issues =
      per_rule_results
      |> Enum.filter(&(&1.severity == :warning and not is_nil(&1.issue)))
      |> Enum.map(& &1.issue)

    %{
      blocking_issues: blocking_issues,
      warning_issues: warning_issues,
      summary: %{
        blocking_issue_count: length(blocking_issues),
        warning_issue_count: length(warning_issues),
        per_rule_counts:
          Enum.map(per_rule_results, fn result ->
            %{
              code: result.code,
              severity: result.severity,
              source_file: result.source_file,
              invalid_count: result.invalid_count
            }
          end)
      }
    }
  end

  defp ensure_no_blocking_integrity_issues(%{blocking_issues: []}), do: :ok

  defp ensure_no_blocking_integrity_issues(%{blocking_issues: blocking_issues}) do
    {:error, blocking_issues}
  end

  defp run_station_scope_preflight(filtered_stops_rows) do
    blocking_issues =
      station_coordinate_sanity_issues(filtered_stops_rows) ++
        boarding_area_parent_integrity_issues(filtered_stops_rows)

    case blocking_issues do
      [] -> {:ok, []}
      _ -> {:error, blocking_issues}
    end
  end

  defp station_coordinate_sanity_issues(filtered_stops_rows) do
    filtered_stops_rows
    |> Enum.filter(&(Map.get(&1.values, "location_type") == "1"))
    |> Enum.flat_map(fn stop_row ->
      [
        station_coordinate_issue(stop_row, "stop_lat", -90.0, 90.0),
        station_coordinate_issue(stop_row, "stop_lon", -180.0, 180.0)
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp station_coordinate_issue(stop_row, field, min, max) do
    value = Map.get(stop_row.values, field)

    case parse_coordinate(value) do
      {:ok, coordinate} when coordinate >= min and coordinate <= max ->
        nil

      {:ok, coordinate} ->
        %{
          code: out_of_range_coordinate_issue_code(field),
          severity: :blocking,
          message: "station has out-of-range coordinate in stops.txt",
          context: %{
            file: "stops.txt",
            field: field,
            stop_id: Map.get(stop_row.values, "stop_id"),
            value: coordinate,
            min: min,
            max: max
          }
        }

      :missing ->
        %{
          code: missing_coordinate_issue_code(field),
          severity: :blocking,
          message: "station is missing coordinate in stops.txt",
          context: %{
            file: "stops.txt",
            field: field,
            stop_id: Map.get(stop_row.values, "stop_id"),
            value: value
          }
        }

      :not_numeric ->
        %{
          code: non_numeric_coordinate_issue_code(field),
          severity: :blocking,
          message: "station has non-numeric coordinate in stops.txt",
          context: %{
            file: "stops.txt",
            field: field,
            stop_id: Map.get(stop_row.values, "stop_id"),
            value: value
          }
        }
    end
  end

  defp boarding_area_parent_integrity_issues(filtered_stops_rows) do
    stop_ids =
      filtered_stops_rows
      |> Enum.map(fn row -> Map.get(row.values, "stop_id") end)
      |> MapSet.new()

    filtered_stops_rows
    |> Enum.filter(&(Map.get(&1.values, "location_type") == "4"))
    |> Enum.flat_map(fn row ->
      boarding_area_parent_integrity_issue(row, stop_ids)
    end)
  end

  defp boarding_area_parent_integrity_issue(row, stop_ids) do
    parent_station =
      row.values
      |> Map.get("parent_station", "")
      |> String.trim()

    stop_id = Map.get(row.values, "stop_id")

    cond do
      parent_station == "" ->
        [
          %{
            code: :boarding_area_parent_station_missing,
            severity: :blocking,
            message: "boarding area is missing parent_station in stops.txt",
            context: %{
              file: "stops.txt",
              field: "parent_station",
              stop_id: stop_id,
              value: parent_station
            }
          }
        ]

      MapSet.member?(stop_ids, parent_station) ->
        []

      true ->
        [
          %{
            code: :boarding_area_parent_station_not_found,
            severity: :blocking,
            message: "boarding area references unknown parent_station in stops.txt",
            context: %{
              file: "stops.txt",
              field: "parent_station",
              stop_id: stop_id,
              value: parent_station
            }
          }
        ]
    end
  end

  defp parse_coordinate(nil), do: :missing
  defp parse_coordinate(""), do: :missing

  defp parse_coordinate(value) when is_binary(value) do
    case Float.parse(value) do
      {coordinate, ""} -> {:ok, coordinate}
      _ -> :not_numeric
    end
  end

  defp parse_coordinate(value) when is_integer(value), do: {:ok, value * 1.0}
  defp parse_coordinate(value) when is_float(value), do: {:ok, value}
  defp parse_coordinate(_value), do: :not_numeric

  defp missing_coordinate_issue_code("stop_lat"), do: :station_stop_lat_missing
  defp missing_coordinate_issue_code("stop_lon"), do: :station_stop_lon_missing

  defp non_numeric_coordinate_issue_code("stop_lat"), do: :station_stop_lat_not_numeric
  defp non_numeric_coordinate_issue_code("stop_lon"), do: :station_stop_lon_not_numeric

  defp out_of_range_coordinate_issue_code("stop_lat"), do: :station_stop_lat_out_of_range
  defp out_of_range_coordinate_issue_code("stop_lon"), do: :station_stop_lon_out_of_range

  defp integrity_issue(
         rows,
         source_field,
         target_ids,
         code,
         source_file,
         target_file,
         target_field,
         opts \\ []
       ) do
    severity = integrity_issue_severity(code)

    if Keyword.get(opts, :skip_check, false) do
      %{code: code, severity: severity, source_file: source_file, invalid_count: 0, issue: nil}
    else
      invalid_count = invalid_reference_count(rows, source_field, target_ids, opts)

      issue =
        if invalid_count > 0 do
          %{
            code: code,
            severity: severity,
            message: "referential integrity check failed",
            context: %{
              source_file: source_file,
              source_field: source_field,
              target_file: target_file,
              target_field: target_field,
              invalid_count: invalid_count
            }
          }
        end

      %{
        code: code,
        severity: severity,
        source_file: source_file,
        invalid_count: invalid_count,
        issue: issue
      }
    end
  end

  defp integrity_issue_severity(code) do
    Map.get(@integrity_issue_severity_by_code, code, :blocking)
  end

  defp normalize_station_feed_summary_issue_counts(station_feed_summary)
       when is_map(station_feed_summary) do
    Enum.into(station_feed_summary, %{}, fn {file_name, summary} ->
      normalized_summary =
        summary
        |> Map.put_new(:blocking_issue_count, 0)
        |> Map.put_new(:warning_issue_count, 0)

      {file_name, normalized_summary}
    end)
  end

  defp merge_integrity_issue_counts(station_feed_summary, per_rule_counts)
       when is_map(station_feed_summary) and is_list(per_rule_counts) do
    Enum.reduce(per_rule_counts, station_feed_summary, fn
      %{source_file: source_file, severity: severity, invalid_count: invalid_count}, acc
      when is_binary(source_file) and invalid_count > 0 ->
        Map.update(
          acc,
          source_file,
          default_station_feed_issue_summary(severity, invalid_count),
          fn summary ->
            summary
            |> Map.put_new(:blocking_issue_count, 0)
            |> Map.put_new(:warning_issue_count, 0)
            |> Map.update!(integrity_severity_count_key(severity), &(&1 + invalid_count))
          end
        )

      _per_rule_count, acc ->
        acc
    end)
  end

  defp default_station_feed_issue_summary(severity, invalid_count) do
    %{
      kept_count: 0,
      dropped_count: 0,
      missing_file: true,
      blocking_issue_count: if(severity == :blocking, do: invalid_count, else: 0),
      warning_issue_count: if(severity == :warning, do: invalid_count, else: 0)
    }
  end

  defp integrity_severity_count_key(:warning), do: :warning_issue_count
  defp integrity_severity_count_key(_severity), do: :blocking_issue_count

  defp invalid_reference_count(rows, source_field, target_ids, opts) do
    allow_blank? = Keyword.get(opts, :allow_blank, false)

    rows
    |> Enum.count(fn row ->
      row.values
      |> Map.get(source_field)
      |> to_string_if_nil_safe()
      |> String.trim()
      |> case do
        "" when allow_blank? -> false
        "" -> true
        reference_id -> not MapSet.member?(target_ids, reference_id)
      end
    end)
  end

  defp id_set(rows, field) do
    rows
    |> Enum.map(fn row -> Map.get(row.values, field) end)
    |> Enum.map(&to_string_if_nil_safe/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp filter_stops_rows_and_collect_level_ids(stop_rows, kept_stop_ids) do
    kept_stop_ids_set = MapSet.new(kept_stop_ids)

    filtered_rows =
      Enum.filter(stop_rows, fn row ->
        row.values
        |> Map.get("stop_id")
        |> then(&MapSet.member?(kept_stop_ids_set, &1))
      end)

    kept_level_ids =
      filtered_rows
      |> Enum.map(fn row -> row.values |> Map.get("level_id", "") |> String.trim() end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    kept_zone_ids =
      filtered_rows
      |> Enum.map(fn row -> row.values |> Map.get("zone_id", "") |> String.trim() end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    {filtered_rows, kept_level_ids, kept_zone_ids}
  end

  defp filter_pathways_rows(nil, _kept_stop_ids) do
    {[], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_pathways_rows(%{rows: pathways_rows}, kept_stop_ids) do
    kept_stop_ids_set = MapSet.new(kept_stop_ids)

    filtered_rows =
      Enum.filter(pathways_rows, fn row ->
        from_stop_id = Map.get(row.values, "from_stop_id")
        to_stop_id = Map.get(row.values, "to_stop_id")

        MapSet.member?(kept_stop_ids_set, from_stop_id) and
          MapSet.member?(kept_stop_ids_set, to_stop_id)
      end)

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(pathways_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, summary}
  end

  defp filter_levels_rows(nil, kept_level_ids) do
    warning_issue_count = if kept_level_ids == [], do: 0, else: 1

    {[],
     %{
       kept_count: 0,
       dropped_count: 0,
       missing_file: true,
       blocking_issue_count: 0,
       warning_issue_count: warning_issue_count
     }}
  end

  defp filter_levels_rows(%{rows: levels_rows}, kept_level_ids) do
    kept_level_ids_set = MapSet.new(kept_level_ids)

    filtered_rows =
      Enum.filter(levels_rows, fn row ->
        row.values
        |> Map.get("level_id")
        |> then(&MapSet.member?(kept_level_ids_set, &1))
      end)

    found_level_ids =
      filtered_rows
      |> Enum.map(fn row -> Map.get(row.values, "level_id") end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    missing_level_count =
      kept_level_ids_set
      |> MapSet.difference(found_level_ids)
      |> MapSet.size()

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(levels_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0,
      warning_issue_count: if(missing_level_count > 0, do: 1, else: 0),
      missing_level_count: missing_level_count
    }

    {filtered_rows, summary}
  end

  defp filter_transfers_rows(nil, _kept_stop_ids) do
    {[], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_transfers_rows(%{rows: transfers_rows}, kept_stop_ids) do
    kept_stop_ids_set = MapSet.new(kept_stop_ids)

    filtered_rows =
      transfers_rows
      |> Enum.filter(fn row ->
        from_stop_id = Map.get(row.values, "from_stop_id")
        to_stop_id = Map.get(row.values, "to_stop_id")

        MapSet.member?(kept_stop_ids_set, from_stop_id) and
          MapSet.member?(kept_stop_ids_set, to_stop_id)
      end)
      |> Enum.sort_by(fn row ->
        {
          Map.get(row.values, "from_stop_id", ""),
          Map.get(row.values, "to_stop_id", ""),
          Map.get(row.values, "from_route_id", ""),
          Map.get(row.values, "to_route_id", ""),
          Map.get(row.values, "from_trip_id", ""),
          Map.get(row.values, "to_trip_id", ""),
          Map.get(row.values, "transfer_type", ""),
          Map.get(row.values, "min_transfer_time", "")
        }
      end)

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(transfers_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, summary}
  end

  defp filter_stop_times_rows(nil, _kept_stop_ids) do
    {[], [], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_stop_times_rows(%{rows: stop_times_rows}, kept_stop_ids) do
    kept_stop_ids_set = MapSet.new(kept_stop_ids)

    filtered_rows =
      Enum.filter(stop_times_rows, fn row ->
        row.values
        |> Map.get("stop_id")
        |> then(&MapSet.member?(kept_stop_ids_set, &1))
      end)

    kept_trip_ids =
      filtered_rows
      |> Enum.map(fn row -> Map.get(row.values, "trip_id", "") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(stop_times_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, kept_trip_ids, summary}
  end

  defp filter_trips_rows(nil, _kept_trip_ids) do
    {[], [], [], [],
     %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_trips_rows(%{rows: trips_rows}, kept_trip_ids) do
    kept_trip_ids_set = MapSet.new(kept_trip_ids)

    filtered_rows =
      Enum.filter(trips_rows, fn row ->
        row.values
        |> Map.get("trip_id")
        |> then(&MapSet.member?(kept_trip_ids_set, &1))
      end)

    kept_route_ids =
      filtered_rows
      |> Enum.map(fn row -> Map.get(row.values, "route_id", "") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    kept_service_ids =
      filtered_rows
      |> Enum.map(fn row -> Map.get(row.values, "service_id", "") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    kept_shape_ids =
      filtered_rows
      |> Enum.map(fn row -> Map.get(row.values, "shape_id", "") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(trips_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, kept_route_ids, kept_service_ids, kept_shape_ids, summary}
  end

  defp filter_attributions_rows(nil, _kept_route_ids, _kept_trip_ids) do
    {[], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_attributions_rows(%{rows: attribution_rows}, kept_route_ids, kept_trip_ids) do
    kept_route_ids_set = MapSet.new(kept_route_ids)
    kept_trip_ids_set = MapSet.new(kept_trip_ids)

    filtered_rows =
      Enum.filter(attribution_rows, fn row ->
        route_id = row.values |> Map.get("route_id") |> to_string_if_nil_safe() |> String.trim()
        trip_id = row.values |> Map.get("trip_id") |> to_string_if_nil_safe() |> String.trim()

        (route_id == "" or MapSet.member?(kept_route_ids_set, route_id)) and
          (trip_id == "" or MapSet.member?(kept_trip_ids_set, trip_id))
      end)

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(attribution_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, summary}
  end

  defp filter_routes_rows(nil, _kept_route_ids) do
    {[], [], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_routes_rows(%{header: header, rows: routes_rows}, kept_route_ids) do
    kept_route_ids_set = MapSet.new(kept_route_ids)

    filtered_rows =
      Enum.filter(routes_rows, fn row ->
        row.values
        |> Map.get("route_id")
        |> then(&MapSet.member?(kept_route_ids_set, &1))
      end)

    kept_agency_ids =
      if "agency_id" in header do
        filtered_rows
        |> Enum.map(fn row -> Map.get(row.values, "agency_id", "") end)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()
      else
        []
      end

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(routes_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, kept_agency_ids, summary}
  end

  defp filter_agency_rows(nil, _kept_agency_ids) do
    {[], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_agency_rows(%{header: header, rows: agency_rows}, kept_agency_ids) do
    if "agency_id" in header do
      kept_agency_ids_set = MapSet.new(kept_agency_ids)

      filtered_rows =
        Enum.filter(agency_rows, fn row ->
          row.values
          |> Map.get("agency_id")
          |> to_string_if_nil_safe()
          |> String.trim()
          |> then(&MapSet.member?(kept_agency_ids_set, &1))
        end)

      summary = %{
        kept_count: length(filtered_rows),
        dropped_count: length(agency_rows) - length(filtered_rows),
        missing_file: false,
        blocking_issue_count: 0
      }

      {filtered_rows, summary}
    else
      summary = %{
        kept_count: length(agency_rows),
        dropped_count: 0,
        missing_file: false,
        blocking_issue_count: 0
      }

      {agency_rows, summary}
    end
  end

  defp filter_calendar_rows(nil, _kept_service_ids) do
    {[], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_calendar_rows(%{rows: calendar_rows}, kept_service_ids) do
    kept_service_ids_set = MapSet.new(kept_service_ids)

    filtered_rows =
      Enum.filter(calendar_rows, fn row ->
        row.values
        |> Map.get("service_id")
        |> then(&MapSet.member?(kept_service_ids_set, &1))
      end)

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(calendar_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, summary}
  end

  defp filter_calendar_dates_rows(nil, _kept_service_ids) do
    {[], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_calendar_dates_rows(%{rows: calendar_dates_rows}, kept_service_ids) do
    kept_service_ids_set = MapSet.new(kept_service_ids)

    filtered_rows =
      Enum.filter(calendar_dates_rows, fn row ->
        row.values
        |> Map.get("service_id")
        |> then(&MapSet.member?(kept_service_ids_set, &1))
      end)

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(calendar_dates_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, summary}
  end

  defp filter_frequencies_rows(nil, _kept_trip_ids) do
    {[], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_frequencies_rows(%{rows: frequencies_rows}, kept_trip_ids) do
    kept_trip_ids_set = MapSet.new(kept_trip_ids)

    filtered_rows =
      Enum.filter(frequencies_rows, fn row ->
        row.values
        |> Map.get("trip_id")
        |> then(&MapSet.member?(kept_trip_ids_set, &1))
      end)

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(frequencies_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, summary}
  end

  defp filter_shapes_rows(nil, _kept_shape_ids) do
    {[], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_shapes_rows(%{rows: shapes_rows}, kept_shape_ids) do
    kept_shape_ids_set = MapSet.new(kept_shape_ids)

    filtered_rows =
      Enum.filter(shapes_rows, fn row ->
        row.values
        |> Map.get("shape_id")
        |> then(&MapSet.member?(kept_shape_ids_set, &1))
      end)

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(shapes_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, summary}
  end

  defp filter_fare_rules_rows(nil, _kept_route_ids, _kept_zone_ids) do
    {[], [], %{kept_count: 0, dropped_count: 0, missing_file: true, blocking_issue_count: 0}}
  end

  defp filter_fare_rules_rows(%{rows: fare_rules_rows}, kept_route_ids, kept_zone_ids) do
    kept_route_ids_set = MapSet.new(kept_route_ids)
    kept_zone_ids_set = MapSet.new(kept_zone_ids)

    filtered_rows =
      Enum.filter(fare_rules_rows, fn row ->
        fare_rule_references_kept_entities?(row, kept_route_ids_set, kept_zone_ids_set)
      end)

    kept_fare_ids =
      filtered_rows
      |> Enum.map(fn row -> Map.get(row.values, "fare_id", "") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(fare_rules_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0
    }

    {filtered_rows, kept_fare_ids, summary}
  end

  defp filter_fare_attributes_rows(nil, _kept_fare_ids, fare_rules_missing?) do
    warning_issue_count = if fare_rules_missing?, do: 1, else: 0

    {[],
     %{
       kept_count: 0,
       dropped_count: 0,
       missing_file: true,
       blocking_issue_count: 0,
       warning_issue_count: warning_issue_count
     }}
  end

  defp filter_fare_attributes_rows(%{rows: fare_attributes_rows}, _kept_fare_ids, true) do
    summary = %{
      kept_count: length(fare_attributes_rows),
      dropped_count: 0,
      missing_file: false,
      blocking_issue_count: 0,
      warning_issue_count: 1
    }

    {fare_attributes_rows, summary}
  end

  defp filter_fare_attributes_rows(%{rows: fare_attributes_rows}, kept_fare_ids, false) do
    kept_fare_ids_set = MapSet.new(kept_fare_ids)

    filtered_rows =
      Enum.filter(fare_attributes_rows, fn row ->
        row.values
        |> Map.get("fare_id")
        |> then(&MapSet.member?(kept_fare_ids_set, &1))
      end)

    summary = %{
      kept_count: length(filtered_rows),
      dropped_count: length(fare_attributes_rows) - length(filtered_rows),
      missing_file: false,
      blocking_issue_count: 0,
      warning_issue_count: 0
    }

    {filtered_rows, summary}
  end

  defp extension_file_summaries_and_warnings(tables) do
    station_filtered_files = MapSet.new(@filtered_table_files)
    known_optional_files = MapSet.new(Map.keys(@known_optional_extension_file_mappings))

    {summaries, warnings} =
      Enum.reduce(tables, {%{}, []}, fn {file_name, %{rows: rows}},
                                        {summaries_acc, warnings_acc} ->
        cond do
          MapSet.member?(station_filtered_files, file_name) ->
            {summaries_acc, warnings_acc}

          MapSet.member?(known_optional_files, file_name) ->
            {Map.put(summaries_acc, file_name, passthrough_file_summary(rows, false)),
             warnings_acc}

          true ->
            {
              Map.put(summaries_acc, file_name, passthrough_file_summary(rows, true)),
              [unknown_extension_file_warning_issue(file_name) | warnings_acc]
            }
        end
      end)

    {summaries, Enum.reverse(warnings)}
  end

  defp passthrough_file_summary(rows, unvalidated_references?) do
    %{
      kept_count: length(rows),
      dropped_count: 0,
      missing_file: false,
      blocking_issue_count: 0,
      warning_issue_count: if(unvalidated_references?, do: 1, else: 0),
      unvalidated_references: unvalidated_references?
    }
  end

  defp unknown_extension_file_warning_issue(file_name) do
    %{
      code: :station_extension_file_unvalidated_references,
      severity: :warning,
      message: "unknown extension file copied without reference validation",
      context: %{file_name: file_name}
    }
  end

  defp fare_rule_references_kept_entities?(row, kept_route_ids_set, kept_zone_ids_set) do
    route_id = Map.get(row.values, "route_id")
    origin_id = Map.get(row.values, "origin_id")
    destination_id = Map.get(row.values, "destination_id")
    contains_id = Map.get(row.values, "contains_id")

    kept_reference?(route_id, kept_route_ids_set) and
      kept_reference?(origin_id, kept_zone_ids_set) and
      kept_reference?(destination_id, kept_zone_ids_set) and
      kept_reference?(contains_id, kept_zone_ids_set)
  end

  defp kept_reference?(value, kept_ids_set) do
    value
    |> to_string_if_nil_safe()
    |> String.trim()
    |> case do
      "" -> true
      id -> MapSet.member?(kept_ids_set, id)
    end
  end

  defp to_string_if_nil_safe(nil), do: ""
  defp to_string_if_nil_safe(value), do: to_string(value)

  defp replace_tables(source_zip_path, rendered_tables) do
    with {:ok, entries} <- unzip_entries(source_zip_path),
         files <- replace_entries(entries, rendered_tables),
         {:ok, {_zip_name, station_zip_binary}} <-
           :zip.create(~c"station_gtfs.zip", files, [:memory]) do
      {:ok, station_zip_binary}
    else
      {:error, reason} ->
        {:error,
         [
           %{
             code: :station_zip_build_failed,
             severity: :blocking,
             message: "failed to build station_gtfs.zip",
             context: %{reason: inspect(reason), source_zip_path: source_zip_path}
           }
         ]}
    end
  end

  defp unzip_entries(source_zip_path) do
    case :zip.unzip(String.to_charlist(source_zip_path), [:memory]) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_entries(entries, rendered_tables) do
    entries
    |> Enum.sort()
    |> Enum.map(fn {name, content} ->
      entry_name = to_string(name)
      {name, Map.get(rendered_tables, entry_name, content)}
    end)
  end

  defp render_table_csv(file_name, %{header: header}, filtered_rows) do
    stable_rows = stable_order_rows(file_name, filtered_rows)

    csv_lines =
      [header | Enum.map(stable_rows, & &1.fields)]
      |> Enum.map_join("\n", &render_csv_row/1)

    csv_lines <> "\n"
  end

  defp render_table_csv(_file_name, _missing_table, _filtered_rows), do: nil

  defp stable_order_rows("shapes.txt", rows), do: rows

  defp stable_order_rows("stop_times.txt", rows) do
    Enum.sort_by(rows, fn row ->
      {
        row.values |> Map.get("trip_id") |> to_string_if_nil_safe(),
        row.values |> Map.get("stop_sequence") |> parse_int_for_sort(),
        row.values |> Map.get("arrival_time") |> to_string_if_nil_safe(),
        row.values |> Map.get("departure_time") |> to_string_if_nil_safe(),
        row.values |> Map.get("stop_id") |> to_string_if_nil_safe()
      }
    end)
  end

  defp stable_order_rows(file_name, rows)
       when file_name in [
              "agency.txt",
              "attributions.txt",
              "calendar.txt",
              "calendar_dates.txt",
              "fare_attributes.txt",
              "fare_rules.txt",
              "frequencies.txt",
              "levels.txt",
              "pathways.txt",
              "routes.txt",
              "stops.txt",
              "transfers.txt",
              "trips.txt"
            ] do
    Enum.sort_by(rows, fn row ->
      row.fields
    end)
  end

  defp stable_order_rows(_file_name, rows), do: rows

  defp parse_int_for_sort(nil), do: 0

  defp parse_int_for_sort(value) when is_integer(value), do: value

  defp parse_int_for_sort(value) do
    value
    |> to_string_if_nil_safe()
    |> String.trim()
    |> case do
      "" ->
        0

      digits ->
        case Integer.parse(digits) do
          {parsed, ""} -> parsed
          _ -> 0
        end
    end
  end

  defp render_csv_row(fields) do
    fields
    |> Enum.map(&escape_csv_field/1)
    |> Enum.join(",")
  end

  defp escape_csv_field(field) do
    escaped = String.replace(field, "\"", "\"\"")

    if String.contains?(field, [",", "\n", "\""]) do
      "\"#{escaped}\""
    else
      escaped
    end
  end

  defp merge_station_meta(meta, station_stop_id, source_zip_path, station_zip_path, filter_meta)
       when is_map(meta) do
    meta
    |> Map.put(:station_stop_id, station_stop_id)
    |> Map.put(:source_zip_path, source_zip_path)
    |> Map.put(:station_zip_path, station_zip_path)
    |> Map.put(:station_feed_summary, Map.get(filter_meta, :station_feed_summary, %{}))
    |> Map.put(:integrity_summary, Map.get(filter_meta, :integrity_summary, %{}))
    |> Map.put(:integrity_warning_issues, Map.get(filter_meta, :integrity_warning_issues, []))
    |> Map.put(
      :station_preflight_warning_issues,
      Map.get(filter_meta, :station_preflight_warning_issues, [])
    )
    |> Map.put(:extension_warning_issues, Map.get(filter_meta, :extension_warning_issues, []))
    |> Map.put(:kept_level_ids, Map.get(filter_meta, :kept_level_ids, []))
    |> Map.put(:kept_zone_ids, Map.get(filter_meta, :kept_zone_ids, []))
    |> Map.put(:kept_trip_ids, Map.get(filter_meta, :kept_trip_ids, []))
    |> Map.put(:kept_route_ids, Map.get(filter_meta, :kept_route_ids, []))
    |> Map.put(:kept_service_ids, Map.get(filter_meta, :kept_service_ids, []))
    |> Map.put(:kept_shape_ids, Map.get(filter_meta, :kept_shape_ids, []))
    |> Map.put(:kept_agency_ids, Map.get(filter_meta, :kept_agency_ids, []))
    |> Map.put(:kept_fare_ids, Map.get(filter_meta, :kept_fare_ids, []))
  end

  defp merge_station_meta(_meta, station_stop_id, source_zip_path, station_zip_path, filter_meta) do
    %{
      station_stop_id: station_stop_id,
      source_zip_path: source_zip_path,
      station_zip_path: station_zip_path,
      station_feed_summary: Map.get(filter_meta, :station_feed_summary, %{}),
      integrity_summary: Map.get(filter_meta, :integrity_summary, %{}),
      integrity_warning_issues: Map.get(filter_meta, :integrity_warning_issues, []),
      station_preflight_warning_issues:
        Map.get(filter_meta, :station_preflight_warning_issues, []),
      extension_warning_issues: Map.get(filter_meta, :extension_warning_issues, []),
      kept_level_ids: Map.get(filter_meta, :kept_level_ids, []),
      kept_zone_ids: Map.get(filter_meta, :kept_zone_ids, []),
      kept_trip_ids: Map.get(filter_meta, :kept_trip_ids, []),
      kept_route_ids: Map.get(filter_meta, :kept_route_ids, []),
      kept_service_ids: Map.get(filter_meta, :kept_service_ids, []),
      kept_shape_ids: Map.get(filter_meta, :kept_shape_ids, []),
      kept_agency_ids: Map.get(filter_meta, :kept_agency_ids, []),
      kept_fare_ids: Map.get(filter_meta, :kept_fare_ids, [])
    }
  end

  defp station_zip_path(organization_id, gtfs_version_id, station_stop_id) do
    station_hash =
      :sha256
      |> :crypto.hash(station_stop_id)
      |> Base.encode16(case: :lower)

    Path.join([
      ArtifactPath.artifact_dir(organization_id, gtfs_version_id),
      "station",
      station_hash,
      "station_gtfs.zip"
    ])
  end

  defp invalid_station_stop_id_issue(station_stop_id) do
    %{
      code: :invalid_station_stop_id,
      severity: :blocking,
      message: "station_stop_id is required for station GTFS materialization",
      context: %{station_stop_id: inspect(station_stop_id)}
    }
  end

  defp station_zip_copy_failed_issue(reason, source_zip_path, station_zip_path) do
    %{
      code: :station_zip_copy_failed,
      severity: :blocking,
      message: "failed to materialize station_gtfs.zip",
      context: %{
        reason: inspect(reason),
        source_zip_path: source_zip_path,
        station_zip_path: station_zip_path
      }
    }
  end
end
