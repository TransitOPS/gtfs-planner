defmodule GtfsPlanner.Gtfs.Import.RowParser do
  @moduledoc """
  Parses GTFS CSV rows into attribute maps for batch insertion.

  Converts CSV row maps into plain maps suitable for `Repo.insert_all/3`,
  bypassing Ecto changesets for performance. Includes validation for critical
  fields, returning `{:ok, attrs}` or `{:error, reason}` tuples.

  All functions are designed for the batch import redesign where large files
  are processed without creating dynamic atoms or individual changesets.
  """

  alias GtfsPlanner.Gtfs

  @doc """
  Converts a route CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def route_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, route_id} <- extract_required(row_map, "route_id"),
         {:ok, route_type} <- parse_route_type(row_map["route_type"]) do
      {:ok, route_sort_order} = parse_integer(row_map["route_sort_order"])
      {:ok, continuous_pickup} = parse_continuous_value(row_map["continuous_pickup"])
      {:ok, continuous_drop_off} = parse_continuous_value(row_map["continuous_drop_off"])

      {:ok,
       %{
         route_id: route_id,
         route_type: route_type,
         route_short_name: empty_to_nil(row_map["route_short_name"]),
         route_long_name: empty_to_nil(row_map["route_long_name"]),
         agency_id: empty_to_nil(row_map["agency_id"]),
         route_desc: empty_to_nil(row_map["route_desc"]),
         route_url: empty_to_nil(row_map["route_url"]),
         route_color: empty_to_nil(row_map["route_color"]) || "FFFFFF",
         route_text_color: empty_to_nil(row_map["route_text_color"]) || "000000",
         route_sort_order: route_sort_order,
         continuous_pickup: continuous_pickup || 1,
         continuous_drop_off: continuous_drop_off || 1,
         network_id: empty_to_nil(row_map["network_id"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a route pattern CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def route_pattern_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, route_pattern_id} <- extract_required(row_map, "route_pattern_id"),
         {:ok, route_id} <- extract_required(row_map, "route_id"),
         {:ok, direction_id} <- parse_direction_id(row_map["direction_id"]) do
      {:ok, typicality} = parse_typicality(row_map["route_pattern_typicality"])
      {:ok, sort_order} = parse_integer(row_map["route_pattern_sort_order"])
      {:ok, canonical} = parse_canonical_route_pattern(row_map["canonical_route_pattern"])

      {:ok,
       %{
         route_pattern_id: route_pattern_id,
         route_id: route_id,
         direction_id: direction_id,
         route_pattern_name: empty_to_nil(row_map["route_pattern_name"]),
         route_pattern_time_desc: empty_to_nil(row_map["route_pattern_time_desc"]),
         route_pattern_typicality: typicality || 0,
         route_pattern_sort_order: sort_order,
         representative_trip_id: empty_to_nil(row_map["representative_trip_id"]),
         canonical_route_pattern: canonical || 0,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a calendar CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def calendar_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, service_id} <- extract_required(row_map, "service_id"),
         {:ok, monday} <- parse_day_flag(row_map["monday"]),
         {:ok, tuesday} <- parse_day_flag(row_map["tuesday"]),
         {:ok, wednesday} <- parse_day_flag(row_map["wednesday"]),
         {:ok, thursday} <- parse_day_flag(row_map["thursday"]),
         {:ok, friday} <- parse_day_flag(row_map["friday"]),
         {:ok, saturday} <- parse_day_flag(row_map["saturday"]),
         {:ok, sunday} <- parse_day_flag(row_map["sunday"]),
         {:ok, start_date} <- parse_gtfs_date(row_map["start_date"]),
         {:ok, end_date} <- parse_gtfs_date(row_map["end_date"]) do
      {:ok,
       %{
         service_id: service_id,
         monday: monday,
         tuesday: tuesday,
         wednesday: wednesday,
         thursday: thursday,
         friday: friday,
         saturday: saturday,
         sunday: sunday,
         start_date: start_date,
         end_date: end_date,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a calendar_dates CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def calendar_date_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, service_id} <- extract_required(row_map, "service_id"),
         {:ok, date} <- parse_gtfs_date(row_map["date"]),
         {:ok, exception_type} <- parse_exception_type(row_map["exception_type"]) do
      {:ok,
       %{
         service_id: service_id,
         date: date,
         exception_type: exception_type,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a trip CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def trip_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, trip_id} <- extract_required(row_map, "trip_id"),
         {:ok, route_id} <- extract_required(row_map, "route_id"),
         {:ok, service_id} <- extract_required(row_map, "service_id") do
      {:ok, direction_id} = parse_direction_id(row_map["direction_id"])
      {:ok, wheelchair_accessible} = parse_integer(row_map["wheelchair_accessible"])
      {:ok, bikes_allowed} = parse_integer(row_map["bikes_allowed"])
      {:ok, cars_allowed} = parse_integer(row_map["cars_allowed"])

      {:ok,
       %{
         trip_id: trip_id,
         route_id: route_id,
         service_id: service_id,
         trip_headsign: empty_to_nil(row_map["trip_headsign"]),
         trip_short_name: empty_to_nil(row_map["trip_short_name"]),
         direction_id: direction_id,
         block_id: empty_to_nil(row_map["block_id"]),
         shape_id: empty_to_nil(row_map["shape_id"]),
         wheelchair_accessible: wheelchair_accessible,
         bikes_allowed: bikes_allowed,
         cars_allowed: cars_allowed,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a level CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def level_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, level_id} <- extract_required(row_map, "level_id"),
         {:ok, level_index} <- parse_float(row_map["level_index"]) do
      {:ok,
       %{
         level_id: level_id,
         level_index: level_index,
         level_name: empty_to_nil(row_map["level_name"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a stop CSV row to attributes map.

  Queries the database to resolve level_id and parent_station references.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def stop_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, stop_id} <- extract_required(row_map, "stop_id"),
         {:ok, stop_lat} <- parse_decimal(row_map["stop_lat"]),
         {:ok, stop_lon} <- parse_decimal(row_map["stop_lon"]) do
      {:ok, location_type} = parse_location_type(row_map["location_type"])
      {:ok, wheelchair_boarding} = parse_wheelchair_boarding(row_map["wheelchair_boarding"])

      {:ok, level_id} =
        resolve_level_id_from_db(row_map["level_id"], organization_id, gtfs_version_id)

      {:ok, parent_station_id} =
        resolve_parent_station_id_from_db(
          row_map["parent_station"],
          organization_id,
          gtfs_version_id
        )

      {:ok,
       %{
         stop_id: stop_id,
         stop_name: empty_to_nil(row_map["stop_name"]),
         stop_desc: empty_to_nil(row_map["stop_desc"]),
         platform_code: empty_to_nil(row_map["platform_code"]),
         stop_lat: stop_lat,
         stop_lon: stop_lon,
         location_type: location_type || 0,
         wheelchair_boarding: wheelchair_boarding,
         level_id: level_id,
         parent_station_id: parent_station_id,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a stop_times CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def stop_time_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, trip_id} <- extract_required(row_map, "trip_id"),
         {:ok, stop_id} <- extract_required(row_map, "stop_id"),
         {:ok, stop_sequence_str} <- extract_required(row_map, "stop_sequence"),
         {:ok, stop_sequence} <- parse_integer(stop_sequence_str) do
      {:ok, arrival_time} = parse_gtfs_time(row_map["arrival_time"])
      {:ok, departure_time} = parse_gtfs_time(row_map["departure_time"])
      {:ok, pickup_type} = parse_integer(row_map["pickup_type"])
      {:ok, drop_off_type} = parse_integer(row_map["drop_off_type"])
      {:ok, continuous_pickup} = parse_integer(row_map["continuous_pickup"])
      {:ok, continuous_drop_off} = parse_integer(row_map["continuous_drop_off"])
      {:ok, timepoint} = parse_integer(row_map["timepoint"])
      {:ok, shape_dist_traveled} = parse_decimal(row_map["shape_dist_traveled"])

      {:ok,
       %{
         trip_id: trip_id,
         stop_id: stop_id,
         stop_sequence: stop_sequence,
         arrival_time: arrival_time,
         departure_time: departure_time,
         stop_headsign: empty_to_nil(row_map["stop_headsign"]),
         pickup_type: pickup_type,
         drop_off_type: drop_off_type,
         continuous_pickup: continuous_pickup,
         continuous_drop_off: continuous_drop_off,
         shape_dist_traveled: shape_dist_traveled,
         timepoint: timepoint,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a pathway CSV row to attributes map.

  Uses the provided stop_map to resolve from_stop_id and to_stop_id UUIDs.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version
    * `stop_map` - Map of stop_id strings to Stop UUIDs

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure (including stop not found)
  """
  def pathway_row_to_attrs(row_map, organization_id, gtfs_version_id, stop_map) do
    with {:ok, pathway_id} <- extract_required(row_map, "pathway_id"),
         {:ok, from_stop_id_str} <- extract_required(row_map, "from_stop_id"),
         {:ok, to_stop_id_str} <- extract_required(row_map, "to_stop_id"),
         {:ok, pathway_mode} <- parse_pathway_mode(row_map["pathway_mode"]),
         {:ok, is_bidirectional} <- parse_is_bidirectional(row_map["is_bidirectional"]),
         {:ok, from_stop_uuid} <- lookup_stop_uuid(stop_map, from_stop_id_str, "from_stop_id"),
         {:ok, to_stop_uuid} <- lookup_stop_uuid(stop_map, to_stop_id_str, "to_stop_id") do
      # Parse optional fields, defaulting to nil on parse errors
      traversal_time = case parse_integer(row_map["traversal_time"]) do
        {:ok, val} -> val
        {:error, _} -> nil
      end

      length = case parse_decimal(row_map["length"]) do
        {:ok, val} -> val
        {:error, _} -> nil
      end

      stair_count = case parse_integer(row_map["stair_count"]) do
        {:ok, val} -> val
        {:error, _} -> nil
      end

      max_slope = case parse_decimal(row_map["max_slope"]) do
        {:ok, val} -> val
        {:error, _} -> nil
      end

      min_width = case parse_decimal(row_map["min_width"]) do
        {:ok, val} -> val
        {:error, _} -> nil
      end

      {:ok,
       %{
         pathway_id: pathway_id,
         pathway_mode: pathway_mode,
         is_bidirectional: is_bidirectional,
         traversal_time: traversal_time,
         length: length,
         stair_count: stair_count,
         max_slope: max_slope,
         min_width: min_width,
         signposted_as: empty_to_nil(row_map["signposted_as"]),
         reversed_signposted_as: empty_to_nil(row_map["reversed_signposted_as"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id,
         from_stop_id: from_stop_uuid,
         to_stop_id: to_stop_uuid
       }}
    end
  end

  # Helper function to look up stop UUID from stop_map
  defp lookup_stop_uuid(stop_map, stop_id_str, field_name) do
    case Map.get(stop_map, stop_id_str) do
      nil -> {:error, "#{field_name} not found: #{stop_id_str}"}
      uuid -> {:ok, uuid}
    end
  end

  @doc """
  Resolves a level_id string to internal UUID by querying the database.

  ## Parameters

    * `level_id_string` - GTFS level_id from CSV
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, uuid}` - Level UUID
    * `{:ok, nil}` - No level_id provided or not found
  """
  def resolve_level_id_from_db(nil, _organization_id, _gtfs_version_id), do: {:ok, nil}
  def resolve_level_id_from_db("", _organization_id, _gtfs_version_id), do: {:ok, nil}

  def resolve_level_id_from_db(level_id_string, organization_id, gtfs_version_id) do
    case Gtfs.get_level_by_level_id(organization_id, gtfs_version_id, level_id_string) do
      nil -> {:ok, nil}
      level -> {:ok, level.id}
    end
  end

  @doc """
  Resolves a parent_station string to internal UUID by querying the database.

  ## Parameters

    * `parent_station_string` - GTFS parent_station from CSV
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, uuid}` - Stop UUID
    * `{:ok, nil}` - No parent_station provided or not found
  """
  def resolve_parent_station_id_from_db(nil, _organization_id, _gtfs_version_id), do: {:ok, nil}

  def resolve_parent_station_id_from_db("", _organization_id, _gtfs_version_id), do: {:ok, nil}

  def resolve_parent_station_id_from_db(parent_station_string, organization_id, gtfs_version_id) do
    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, parent_station_string) do
      nil -> {:ok, nil}
      stop -> {:ok, stop.id}
    end
  end

  # Parsing helper functions

  @doc """
  Parses a string to a float.

  ## Returns

    * `{:ok, float}` - Valid float
    * `{:error, reason}` - Parse failure
  """
  def parse_float(nil), do: {:error, "nil value"}
  def parse_float(""), do: {:error, "empty value"}

  def parse_float(string) when is_binary(string) do
    case Float.parse(string) do
      {float, ""} -> {:ok, float}
      _ -> {:error, "invalid float: #{string}"}
    end
  end

  @doc """
  Parses a string to a Decimal.

  ## Returns

    * `{:ok, decimal}` - Valid decimal
    * `{:ok, nil}` - Empty or nil input
    * `{:error, reason}` - Parse failure
  """
  def parse_decimal(nil), do: {:ok, nil}
  def parse_decimal(""), do: {:ok, nil}

  def parse_decimal(string) when is_binary(string) do
    try do
      case Decimal.new(string) do
        %Decimal{} = decimal -> {:ok, decimal}
        _ -> {:error, "invalid decimal: #{string}"}
      end
    rescue
      Decimal.Error -> {:error, "invalid decimal format: #{string}"}
      ArgumentError -> {:error, "invalid decimal value: #{string}"}
    end
  end

  @doc """
  Parses a string to an integer.

  ## Returns

    * `{:ok, integer}` - Valid integer
    * `{:ok, nil}` - Empty or nil input
    * `{:error, reason}` - Parse failure
  """
  def parse_integer(nil), do: {:ok, nil}
  def parse_integer(""), do: {:ok, nil}

  def parse_integer(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "invalid integer: #{string}"}
    end
  rescue
    _ -> {:error, "invalid integer: #{string}"}
  end

  @doc """
  Parses GTFS date format YYYYMMDD to Date.t().

  ## Returns

    * `{:ok, date}` - Valid date
    * `{:ok, nil}` - Empty or nil input
    * `{:error, reason}` - Parse failure
  """
  def parse_gtfs_date(nil), do: {:ok, nil}
  def parse_gtfs_date(""), do: {:ok, nil}

  def parse_gtfs_date(string) when is_binary(string) and byte_size(string) == 8 do
    year = String.slice(string, 0, 4)
    month = String.slice(string, 4, 2)
    day = String.slice(string, 6, 2)

    with {year_int, ""} <- Integer.parse(year),
         {month_int, ""} <- Integer.parse(month),
         {day_int, ""} <- Integer.parse(day),
         {:ok, date} <- Date.new(year_int, month_int, day_int) do
      {:ok, date}
    else
      _ -> {:error, "invalid GTFS date format: #{string}"}
    end
  end

  def parse_gtfs_date(string) when is_binary(string) do
    {:error, "invalid GTFS date format (expected YYYYMMDD): #{string}"}
  end

  @doc """
  Parses GTFS time format HH:MM:SS (supports times > 24:00:00).

  ## Returns

    * `{:ok, time_string}` - Valid time string
    * `{:ok, nil}` - Empty or nil input
    * `{:error, reason}` - Parse failure
  """
  def parse_gtfs_time(nil), do: {:ok, nil}
  def parse_gtfs_time(""), do: {:ok, nil}

  def parse_gtfs_time(string) when is_binary(string) do
    if String.match?(string, ~r/^\d{2}:\d{2}:\d{2}$/) do
      {:ok, string}
    else
      {:error, "invalid GTFS time format (expected HH:MM:SS): #{string}"}
    end
  end

  @doc """
  Parses location_type (0-4, default 0).

  ## Returns

    * `{:ok, integer}` - Valid location type
    * `{:error, reason}` - Parse failure
  """
  def parse_location_type(nil), do: {:ok, 0}
  def parse_location_type(""), do: {:ok, 0}

  def parse_location_type(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..4 -> {:ok, int}
      {int, ""} -> {:error, "location_type out of range 0-4: #{int}"}
      _ -> {:error, "invalid integer: #{string}"}
    end
  rescue
    _ -> {:error, "invalid location_type: #{string}"}
  end

  @doc """
  Parses wheelchair_boarding (0-2, optional).

  ## Returns

    * `{:ok, integer}` - Valid wheelchair boarding value
    * `{:ok, nil}` - Empty or nil input
    * `{:error, reason}` - Parse failure
  """
  def parse_wheelchair_boarding(nil), do: {:ok, nil}
  def parse_wheelchair_boarding(""), do: {:ok, nil}

  def parse_wheelchair_boarding(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..2 -> {:ok, int}
      {int, ""} -> {:error, "wheelchair_boarding out of range 0-2: #{int}"}
      _ -> {:error, "invalid integer: #{string}"}
    end
  rescue
    _ -> {:error, "invalid wheelchair_boarding: #{string}"}
  end

  @doc """
  Parses pathway_mode (1-7, required).

  ## Returns

    * `{:ok, integer}` - Valid pathway mode
    * `{:error, reason}` - Parse failure
  """
  def parse_pathway_mode(nil), do: {:error, "pathway_mode is required"}
  def parse_pathway_mode(""), do: {:error, "pathway_mode is required"}

  def parse_pathway_mode(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 1..7 -> {:ok, int}
      {int, ""} -> {:error, "pathway_mode out of range 1-7: #{int}"}
      _ -> {:error, "invalid pathway_mode: #{string}"}
    end
  rescue
    _ -> {:error, "invalid pathway_mode: #{string}"}
  end

  @doc """
  Parses is_bidirectional (0/1/true/false, default true).

  ## Returns

    * `{:ok, boolean}` - Valid bidirectional value
  """
  def parse_is_bidirectional(nil), do: {:ok, true}
  def parse_is_bidirectional(""), do: {:ok, true}
  def parse_is_bidirectional("1"), do: {:ok, true}
  def parse_is_bidirectional("0"), do: {:ok, false}

  def parse_is_bidirectional(string) when is_binary(string) do
    case String.downcase(string) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "invalid is_bidirectional: #{string}"}
    end
  end

  @doc """
  Parses direction_id (0-1, required).

  ## Returns

    * `{:ok, integer}` - Valid direction ID
    * `{:ok, nil}` - Empty or nil input (optional field)
    * `{:error, reason}` - Parse failure
  """
  def parse_direction_id(nil), do: {:ok, nil}
  def parse_direction_id(""), do: {:ok, nil}

  def parse_direction_id(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in [0, 1] -> {:ok, int}
      {int, ""} -> {:error, "direction_id out of range 0-1: #{int}"}
      _ -> {:error, "invalid direction_id: #{string}"}
    end
  end

  @doc """
  Parses route_pattern_typicality (0-5, blank = 0 per MBTA spec).

  ## Returns

    * `{:ok, integer}` - Valid typicality value
  """
  def parse_typicality(nil), do: {:ok, 0}
  def parse_typicality(""), do: {:ok, 0}

  def parse_typicality(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..5 -> {:ok, int}
      {int, ""} -> {:error, "route_pattern_typicality out of range 0-5: #{int}"}
      _ -> {:error, "invalid route_pattern_typicality: #{string}"}
    end
  end

  @doc """
  Parses canonical_route_pattern (0-2, blank = 0 per MBTA spec).

  ## Returns

    * `{:ok, integer}` - Valid canonical value
  """
  def parse_canonical_route_pattern(nil), do: {:ok, 0}
  def parse_canonical_route_pattern(""), do: {:ok, 0}

  def parse_canonical_route_pattern(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..2 -> {:ok, int}
      {int, ""} -> {:error, "canonical_route_pattern out of range 0-2: #{int}"}
      _ -> {:error, "invalid canonical_route_pattern: #{string}"}
    end
  end

  @doc """
  Parses route_type (0-7, 11, 12, required).

  ## Returns

    * `{:ok, integer}` - Valid route type
    * `{:error, reason}` - Parse failure
  """
  def parse_route_type(nil), do: {:error, "route_type is required"}
  def parse_route_type(""), do: {:error, "route_type is required"}

  def parse_route_type(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in [0, 1, 2, 3, 4, 5, 6, 7, 11, 12] -> {:ok, int}
      {int, ""} -> {:error, "route_type invalid value: #{int}"}
      _ -> {:error, "invalid route_type: #{string}"}
    end
  end

  @doc """
  Parses continuous_pickup/continuous_drop_off (0-3, optional, default 1).

  ## Returns

    * `{:ok, integer}` - Valid continuous value
    * `{:ok, nil}` - Empty or nil input
  """
  def parse_continuous_value(nil), do: {:ok, nil}
  def parse_continuous_value(""), do: {:ok, nil}

  def parse_continuous_value(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..3 -> {:ok, int}
      {int, ""} -> {:error, "continuous value out of range 0-3: #{int}"}
      _ -> {:error, "invalid continuous value: #{string}"}
    end
  end

  @doc """
  Parses day flag (0 or 1, required for calendar).

  ## Returns

    * `{:ok, integer}` - Valid day flag
    * `{:error, reason}` - Parse failure
  """
  def parse_day_flag(nil), do: {:error, "required"}
  def parse_day_flag(""), do: {:error, "required"}
  def parse_day_flag("0"), do: {:ok, 0}
  def parse_day_flag("1"), do: {:ok, 1}

  def parse_day_flag(string) when is_binary(string) do
    {:error, "invalid day flag (expected 0 or 1): #{string}"}
  end

  @doc """
  Parses exception_type (1 or 2, required for calendar_dates).

  ## Returns

    * `{:ok, integer}` - Valid exception type
    * `{:error, reason}` - Parse failure
  """
  def parse_exception_type(nil), do: {:error, "required"}
  def parse_exception_type(""), do: {:error, "required"}
  def parse_exception_type("1"), do: {:ok, 1}
  def parse_exception_type("2"), do: {:ok, 2}

  def parse_exception_type(string) when is_binary(string) do
    {:error, "invalid exception_type (expected 1 or 2): #{string}"}
  end

  @doc """
  Extracts a required field from a row map.

  ## Returns

    * `{:ok, value}` - Field exists and is not empty
    * `{:error, reason}` - Field missing or empty
  """
  def extract_required(row_map, field) do
    case row_map[field] do
      nil -> {:error, "missing required field: #{field}"}
      "" -> {:error, "empty required field: #{field}"}
      value -> {:ok, value}
    end
  end

  @doc """
  Converts empty strings to nil.

  ## Returns

    * `nil` - If input is empty string or nil
    * `value` - Original value otherwise
  """
  def empty_to_nil(""), do: nil
  def empty_to_nil(nil), do: nil
  def empty_to_nil(value), do: value
end