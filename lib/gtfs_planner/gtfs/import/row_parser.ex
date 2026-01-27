defmodule GtfsPlanner.Gtfs.Import.RowParser do
  @moduledoc """
  Parses GTFS CSV rows into attribute maps for batch insertion.

  Converts CSV row maps into plain maps suitable for `Repo.insert_all/3`,
  bypassing Ecto changesets for performance. Includes validation for critical
  fields, returning `{:ok, attrs}` or `{:error, reason}` tuples.

  All functions are designed for the batch import redesign where large files
  are processed without creating dynamic atoms or individual changesets.
  """

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
         level_id: empty_to_nil(row_map["level_id"]),
         parent_station: empty_to_nil(row_map["parent_station"]),
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
  Converts an agency CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def agency_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, agency_id} <- extract_required(row_map, "agency_id"),
         {:ok, agency_name} <- extract_required(row_map, "agency_name"),
         {:ok, agency_url} <- extract_required(row_map, "agency_url"),
         {:ok, agency_timezone} <- extract_required(row_map, "agency_timezone") do
      {:ok,
       %{
         agency_id: agency_id,
         agency_name: agency_name,
         agency_url: agency_url,
         agency_timezone: agency_timezone,
         agency_lang: empty_to_nil(row_map["agency_lang"]),
         agency_phone: empty_to_nil(row_map["agency_phone"]),
         agency_fare_url: empty_to_nil(row_map["agency_fare_url"]),
         agency_email: empty_to_nil(row_map["agency_email"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts an area CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def area_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, area_id} <- extract_required(row_map, "area_id") do
      {:ok,
       %{
         area_id: area_id,
         area_name: empty_to_nil(row_map["area_name"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts an attribution CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def attribution_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, organization_name} <- extract_required(row_map, "organization_name") do
      {:ok, is_producer} = parse_integer(row_map["is_producer"])
      {:ok, is_operator} = parse_integer(row_map["is_operator"])
      {:ok, is_authority} = parse_integer(row_map["is_authority"])

      {:ok,
       %{
         attribution_id: empty_to_nil(row_map["attribution_id"]),
         agency_id: empty_to_nil(row_map["agency_id"]),
         route_id: empty_to_nil(row_map["route_id"]),
         trip_id: empty_to_nil(row_map["trip_id"]),
         organization_name: organization_name,
         is_producer: is_producer,
         is_operator: is_operator,
         is_authority: is_authority,
         attribution_url: empty_to_nil(row_map["attribution_url"]),
         attribution_email: empty_to_nil(row_map["attribution_email"]),
         attribution_phone: empty_to_nil(row_map["attribution_phone"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a booking_rule CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def booking_rule_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, booking_rule_id} <- extract_required(row_map, "booking_rule_id"),
         {:ok, booking_type_str} <- extract_required(row_map, "booking_type"),
         {:ok, booking_type} <- parse_integer(booking_type_str) do
      {:ok, prior_notice_duration_min} = parse_integer(row_map["prior_notice_duration_min"])
      {:ok, prior_notice_duration_max} = parse_integer(row_map["prior_notice_duration_max"])
      {:ok, prior_notice_last_day} = parse_integer(row_map["prior_notice_last_day"])
      {:ok, prior_notice_start_day} = parse_integer(row_map["prior_notice_start_day"])

      {:ok,
       %{
         booking_rule_id: booking_rule_id,
         booking_type: booking_type,
         prior_notice_duration_min: prior_notice_duration_min,
         prior_notice_duration_max: prior_notice_duration_max,
         prior_notice_last_day: prior_notice_last_day,
         prior_notice_last_time: empty_to_nil(row_map["prior_notice_last_time"]),
         prior_notice_start_day: prior_notice_start_day,
         prior_notice_start_time: empty_to_nil(row_map["prior_notice_start_time"]),
         prior_notice_service_id: empty_to_nil(row_map["prior_notice_service_id"]),
         message: empty_to_nil(row_map["message"]),
         pickup_message: empty_to_nil(row_map["pickup_message"]),
         drop_off_message: empty_to_nil(row_map["drop_off_message"]),
         phone_number: empty_to_nil(row_map["phone_number"]),
         info_url: empty_to_nil(row_map["info_url"]),
         booking_url: empty_to_nil(row_map["booking_url"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a fare_attribute CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def fare_attribute_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, fare_id} <- extract_required(row_map, "fare_id"),
         {:ok, price_str} <- extract_required(row_map, "price"),
         {:ok, price} <- parse_decimal(price_str),
         {:ok, currency_type} <- extract_required(row_map, "currency_type"),
         {:ok, payment_method_str} <- extract_required(row_map, "payment_method"),
         {:ok, payment_method} <- parse_integer(payment_method_str) do
      {:ok, transfers} = parse_integer(row_map["transfers"])
      {:ok, transfer_duration} = parse_integer(row_map["transfer_duration"])

      {:ok,
       %{
         fare_id: fare_id,
         price: price,
         currency_type: currency_type,
         payment_method: payment_method,
         transfers: transfers,
         agency_id: empty_to_nil(row_map["agency_id"]),
         transfer_duration: transfer_duration,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a fare_leg_join_rule CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
  """
  def fare_leg_join_rule_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    {:ok,
     %{
       from_network_id: empty_to_nil(row_map["from_network_id"]),
       to_network_id: empty_to_nil(row_map["to_network_id"]),
       from_stop_id: empty_to_nil(row_map["from_stop_id"]),
       to_stop_id: empty_to_nil(row_map["to_stop_id"]),
       organization_id: organization_id,
       gtfs_version_id: gtfs_version_id
     }}
  end

  @doc """
  Converts a fare_leg_rule CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
  """
  def fare_leg_rule_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    {:ok, rule_priority} = parse_integer(row_map["rule_priority"])

    {:ok,
     %{
       leg_group_id: empty_to_nil(row_map["leg_group_id"]),
       network_id: empty_to_nil(row_map["network_id"]),
       from_area_id: empty_to_nil(row_map["from_area_id"]),
       to_area_id: empty_to_nil(row_map["to_area_id"]),
       from_timeframe_group_id: empty_to_nil(row_map["from_timeframe_group_id"]),
       to_timeframe_group_id: empty_to_nil(row_map["to_timeframe_group_id"]),
       fare_product_id: empty_to_nil(row_map["fare_product_id"]),
       rule_priority: rule_priority,
       organization_id: organization_id,
       gtfs_version_id: gtfs_version_id
     }}
  end

  @doc """
  Converts a fare_media CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def fare_media_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, fare_media_id} <- extract_required(row_map, "fare_media_id"),
         {:ok, fare_media_type} <- parse_fare_media_type(row_map["fare_media_type"]) do
      {:ok,
       %{
         fare_media_id: fare_media_id,
         fare_media_name: empty_to_nil(row_map["fare_media_name"]),
         fare_media_type: fare_media_type,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a fare_product CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def fare_product_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, fare_product_id} <- extract_required(row_map, "fare_product_id"),
         {:ok, fare_product_name} <- extract_required(row_map, "fare_product_name"),
         {:ok, amount_str} <- extract_required(row_map, "amount"),
         {:ok, amount} <- parse_decimal(amount_str),
         {:ok, currency} <- extract_required(row_map, "currency") do
      {:ok, bundle_amount} = parse_integer(row_map["bundle_amount"])
      {:ok, duration_start} = parse_integer(row_map["duration_start"])
      {:ok, duration_amount} = parse_integer(row_map["duration_amount"])
      {:ok, duration_unit} = parse_integer(row_map["duration_unit"])

      {:ok,
       %{
         fare_product_id: fare_product_id,
         fare_product_name: fare_product_name,
         fare_media_id: empty_to_nil(row_map["fare_media_id"]),
         amount: amount,
         currency: currency,
         rider_category_id: empty_to_nil(row_map["rider_category_id"]),
         bundle_amount: bundle_amount,
         duration_start: duration_start,
         duration_amount: duration_amount,
         duration_unit: duration_unit,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a fare_rule CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def fare_rule_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, fare_id} <- extract_required(row_map, "fare_id") do
      {:ok,
       %{
         fare_id: fare_id,
         route_id: empty_to_nil(row_map["route_id"]),
         origin_id: empty_to_nil(row_map["origin_id"]),
         destination_id: empty_to_nil(row_map["destination_id"]),
         contains_id: empty_to_nil(row_map["contains_id"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a fare_transfer_rule CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def fare_transfer_rule_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, fare_transfer_type_str} <- extract_required(row_map, "fare_transfer_type"),
         {:ok, fare_transfer_type} <- parse_fare_transfer_type(fare_transfer_type_str) do
      {:ok, transfer_count} = parse_integer(row_map["transfer_count"])
      {:ok, duration_limit} = parse_integer(row_map["duration_limit"])
      {:ok, duration_limit_type} = parse_duration_limit_type(row_map["duration_limit_type"])

      {:ok,
       %{
         from_leg_group_id: empty_to_nil(row_map["from_leg_group_id"]),
         to_leg_group_id: empty_to_nil(row_map["to_leg_group_id"]),
         transfer_count: transfer_count,
         duration_limit: duration_limit,
         duration_limit_type: duration_limit_type,
         fare_transfer_type: fare_transfer_type,
         fare_product_id: empty_to_nil(row_map["fare_product_id"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a feed_info CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def feed_info_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, feed_publisher_name} <- extract_required(row_map, "feed_publisher_name"),
         {:ok, feed_publisher_url} <- extract_required(row_map, "feed_publisher_url"),
         {:ok, feed_lang} <- extract_required(row_map, "feed_lang") do
      {:ok, feed_start_date} = parse_gtfs_date(row_map["feed_start_date"])
      {:ok, feed_end_date} = parse_gtfs_date(row_map["feed_end_date"])

      {:ok,
       %{
         feed_publisher_name: feed_publisher_name,
         feed_publisher_url: feed_publisher_url,
         feed_lang: feed_lang,
         default_lang: empty_to_nil(row_map["default_lang"]),
         feed_start_date: feed_start_date,
         feed_end_date: feed_end_date,
         feed_version: empty_to_nil(row_map["feed_version"]),
         feed_contact_email: empty_to_nil(row_map["feed_contact_email"]),
         feed_contact_url: empty_to_nil(row_map["feed_contact_url"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a frequency CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def frequency_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, trip_id} <- extract_required(row_map, "trip_id"),
         {:ok, start_time} <- extract_required(row_map, "start_time"),
         {:ok, end_time} <- extract_required(row_map, "end_time"),
         {:ok, headway_secs_str} <- extract_required(row_map, "headway_secs"),
         {:ok, headway_secs} <- parse_headway_secs(headway_secs_str) do
      {:ok, exact_times} = parse_exact_times(row_map["exact_times"])

      {:ok,
       %{
         trip_id: trip_id,
         start_time: start_time,
         end_time: end_time,
         headway_secs: headway_secs,
         exact_times: exact_times,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a location CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def location_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, location_id} <- extract_required(row_map, "location_id") do
      {:ok, location_lat} = parse_decimal(row_map["location_lat"])
      {:ok, location_lon} = parse_decimal(row_map["location_lon"])

      {:ok,
       %{
         location_id: location_id,
         location_name: empty_to_nil(row_map["location_name"]),
         location_lat: location_lat,
         location_lon: location_lon,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a network CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def network_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, network_id} <- extract_required(row_map, "network_id") do
      {:ok,
       %{
         network_id: network_id,
         network_name: empty_to_nil(row_map["network_name"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a rider_category CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def rider_category_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, rider_category_id} <- extract_required(row_map, "rider_category_id"),
         {:ok, rider_category_name} <- extract_required(row_map, "rider_category_name") do
      {:ok, min_age} = parse_integer(row_map["min_age"])
      {:ok, max_age} = parse_integer(row_map["max_age"])

      {:ok,
       %{
         rider_category_id: rider_category_id,
         rider_category_name: rider_category_name,
         min_age: min_age,
         max_age: max_age,
         eligibility_url: empty_to_nil(row_map["eligibility_url"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a route_network CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def route_network_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, network_id} <- extract_required(row_map, "network_id"),
         {:ok, route_id} <- extract_required(row_map, "route_id") do
      {:ok,
       %{
         network_id: network_id,
         route_id: route_id,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a shape CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def shape_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, shape_id} <- extract_required(row_map, "shape_id"),
         {:ok, shape_pt_lat_str} <- extract_required(row_map, "shape_pt_lat"),
         {:ok, shape_pt_lat} <- parse_decimal(shape_pt_lat_str),
         {:ok, shape_pt_lon_str} <- extract_required(row_map, "shape_pt_lon"),
         {:ok, shape_pt_lon} <- parse_decimal(shape_pt_lon_str),
         {:ok, shape_pt_sequence_str} <- extract_required(row_map, "shape_pt_sequence"),
         {:ok, shape_pt_sequence} <- parse_integer(shape_pt_sequence_str) do
      {:ok, shape_dist_traveled} = parse_decimal(row_map["shape_dist_traveled"])

      if shape_pt_sequence >= 0 do
        {:ok,
         %{
           shape_id: shape_id,
           shape_pt_lat: shape_pt_lat,
           shape_pt_lon: shape_pt_lon,
           shape_pt_sequence: shape_pt_sequence,
           shape_dist_traveled: shape_dist_traveled,
           organization_id: organization_id,
           gtfs_version_id: gtfs_version_id
         }}
      else
        {:error, "shape_pt_sequence must be >= 0: #{shape_pt_sequence}"}
      end
    end
  end

  @doc """
  Converts a stop_area CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def stop_area_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, area_id} <- extract_required(row_map, "area_id"),
         {:ok, stop_id} <- extract_required(row_map, "stop_id") do
      {:ok,
       %{
         area_id: area_id,
         stop_id: stop_id,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a timeframe CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def timeframe_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, timeframe_group_id} <- extract_required(row_map, "timeframe_group_id"),
         {:ok, service_id} <- extract_required(row_map, "service_id") do
      {:ok,
       %{
         timeframe_group_id: timeframe_group_id,
         start_time: empty_to_nil(row_map["start_time"]),
         end_time: empty_to_nil(row_map["end_time"]),
         service_id: service_id,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a transfer CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def transfer_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, from_stop_id} <- extract_required(row_map, "from_stop_id"),
         {:ok, to_stop_id} <- extract_required(row_map, "to_stop_id"),
         {:ok, transfer_type_str} <- extract_required(row_map, "transfer_type"),
         {:ok, transfer_type} <- parse_transfer_type(transfer_type_str) do
      {:ok, min_transfer_time} = parse_integer(row_map["min_transfer_time"])

      {:ok,
       %{
         from_stop_id: from_stop_id,
         to_stop_id: to_stop_id,
         from_route_id: empty_to_nil(row_map["from_route_id"]),
         to_route_id: empty_to_nil(row_map["to_route_id"]),
         from_trip_id: empty_to_nil(row_map["from_trip_id"]),
         to_trip_id: empty_to_nil(row_map["to_trip_id"]),
         transfer_type: transfer_type,
         min_transfer_time: min_transfer_time,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a translation CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def translation_row_to_attrs(row_map, organization_id, gtfs_version_id) do
    with {:ok, table_name} <- extract_required(row_map, "table_name"),
         {:ok, field_name} <- extract_required(row_map, "field_name"),
         {:ok, language} <- extract_required(row_map, "language"),
         {:ok, translation} <- extract_required(row_map, "translation") do
      {:ok,
       %{
         table_name: table_name,
         field_name: field_name,
         language: language,
         translation: translation,
         record_id: empty_to_nil(row_map["record_id"]),
         record_sub_id: empty_to_nil(row_map["record_sub_id"]),
         field_value: empty_to_nil(row_map["field_value"]),
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    end
  end

  @doc """
  Converts a pathway CSV row to attributes map.

  ## Parameters

    * `row_map` - Map of CSV column names to values
    * `organization_id` - UUID of the organization
    * `gtfs_version_id` - UUID of the GTFS version
    * `stop_map` - Map of GTFS stop_id strings for validation (keys only)

  ## Returns

    * `{:ok, attrs}` - Valid attributes map
    * `{:error, reason}` - Validation failure
  """
  def pathway_row_to_attrs(row_map, organization_id, gtfs_version_id, stop_map \\ %{})

  # Backwards compatibility for tests that don't pass stop_map yet
  def pathway_row_to_attrs(row_map, organization_id, gtfs_version_id, stop_map) when stop_map == %{} do
    # When no stop_map is provided (or empty), we can't validate stop_id existence.
    # This matches the previous behavior and just returns the stop_id strings as-is.
    pathway_row_to_attrs_impl(row_map, organization_id, gtfs_version_id, fn id -> {:ok, id} end)
  end

  def pathway_row_to_attrs(row_map, organization_id, gtfs_version_id, stop_map) do
    resolve_fn = fn stop_id ->
      if Map.has_key?(stop_map, stop_id) do
        {:ok, stop_id}
      else
        {:error, "stop_id not found: #{stop_id}"}
      end
    end

    pathway_row_to_attrs_impl(row_map, organization_id, gtfs_version_id, resolve_fn)
  end

  defp pathway_row_to_attrs_impl(row_map, organization_id, gtfs_version_id, resolve_stop_fn) do
    with {:ok, pathway_id} <- extract_required(row_map, "pathway_id"),
         {:ok, from_stop_id_str} <- extract_required(row_map, "from_stop_id"),
         {:ok, to_stop_id_str} <- extract_required(row_map, "to_stop_id"),
         {:ok, pathway_mode} <- parse_pathway_mode(row_map["pathway_mode"]),
         {:ok, is_bidirectional} <- parse_is_bidirectional(row_map["is_bidirectional"]) do
      
      # Validate stop IDs exist
      with {:ok, from_stop_id} <- resolve_stop_fn_wrapper(resolve_stop_fn, from_stop_id_str, "from_stop_id"),
           {:ok, to_stop_id} <- resolve_stop_fn_wrapper(resolve_stop_fn, to_stop_id_str, "to_stop_id") do
        
        traversal_time =
          case parse_integer(row_map["traversal_time"]) do
            {:ok, val} -> val
            {:error, _} -> nil
          end

        length =
          case parse_decimal(row_map["length"]) do
            {:ok, val} -> val
            {:error, _} -> nil
          end

        stair_count =
          case parse_integer(row_map["stair_count"]) do
            {:ok, val} -> val
            {:error, _} -> nil
          end

        max_slope =
          case parse_decimal(row_map["max_slope"]) do
            {:ok, val} -> val
            {:error, _} -> nil
          end

        min_width =
          case parse_decimal(row_map["min_width"]) do
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
           from_stop_id: from_stop_id,
           to_stop_id: to_stop_id
         }}
      end
    end
  end

  defp resolve_stop_fn_wrapper(func, stop_id, field_name) do
    case func.(stop_id) do
      {:ok, validated_stop_id} -> {:ok, validated_stop_id}
      {:error, _} -> {:error, "#{field_name} not found: #{stop_id}"}
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
  Parses fare_media_type (0-4, required).

  ## Returns

    * `{:ok, integer}` - Valid fare media type
    * `{:error, reason}` - Parse failure
  """
  def parse_fare_media_type(nil), do: {:error, "fare_media_type is required"}
  def parse_fare_media_type(""), do: {:error, "fare_media_type is required"}

  def parse_fare_media_type(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..4 -> {:ok, int}
      {int, ""} -> {:error, "fare_media_type out of range 0-4: #{int}"}
      _ -> {:error, "invalid fare_media_type: #{string}"}
    end
  rescue
    _ -> {:error, "invalid fare_media_type: #{string}"}
  end

  @doc """
  Parses fare_transfer_type (0-2, required).

  ## Returns

    * `{:ok, integer}` - Valid fare transfer type
    * `{:error, reason}` - Parse failure
  """
  def parse_fare_transfer_type(nil), do: {:error, "fare_transfer_type is required"}
  def parse_fare_transfer_type(""), do: {:error, "fare_transfer_type is required"}

  def parse_fare_transfer_type(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..2 -> {:ok, int}
      {int, ""} -> {:error, "fare_transfer_type out of range 0-2: #{int}"}
      _ -> {:error, "invalid fare_transfer_type: #{string}"}
    end
  rescue
    _ -> {:error, "invalid fare_transfer_type: #{string}"}
  end

  @doc """
  Parses duration_limit_type (0-3, optional).

  ## Returns

    * `{:ok, integer}` - Valid duration limit type
    * `{:ok, nil}` - Empty or nil input
    * `{:error, reason}` - Parse failure
  """
  def parse_duration_limit_type(nil), do: {:ok, nil}
  def parse_duration_limit_type(""), do: {:ok, nil}

  def parse_duration_limit_type(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..3 -> {:ok, int}
      {int, ""} -> {:error, "duration_limit_type out of range 0-3: #{int}"}
      _ -> {:error, "invalid duration_limit_type: #{string}"}
    end
  rescue
    _ -> {:error, "invalid duration_limit_type: #{string}"}
  end

  @doc """
  Parses headway_secs (> 0, required for frequencies).

  ## Returns

    * `{:ok, integer}` - Valid headway_secs
    * `{:error, reason}` - Parse failure
  """
  def parse_headway_secs(nil), do: {:error, "headway_secs is required"}
  def parse_headway_secs(""), do: {:error, "headway_secs is required"}

  def parse_headway_secs(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int > 0 -> {:ok, int}
      {int, ""} -> {:error, "headway_secs must be greater than 0: #{int}"}
      _ -> {:error, "invalid headway_secs: #{string}"}
    end
  rescue
    _ -> {:error, "invalid headway_secs: #{string}"}
  end

  @doc """
  Parses exact_times (0-1, optional).

  ## Returns

    * `{:ok, integer}` - Valid exact_times
    * `{:ok, nil}` - Empty or nil input
    * `{:error, reason}` - Parse failure
  """
  def parse_exact_times(nil), do: {:ok, nil}
  def parse_exact_times(""), do: {:ok, nil}

  def parse_exact_times(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..1 -> {:ok, int}
      {int, ""} -> {:error, "exact_times out of range 0-1: #{int}"}
      _ -> {:error, "invalid exact_times: #{string}"}
    end
  rescue
    _ -> {:error, "invalid exact_times: #{string}"}
  end

  @doc """
  Parses transfer_type (0-5, required).

  ## Returns

    * `{:ok, integer}` - Valid transfer type
    * `{:error, reason}` - Parse failure
  """
  def parse_transfer_type(nil), do: {:error, "transfer_type is required"}
  def parse_transfer_type(""), do: {:error, "transfer_type is required"}

  def parse_transfer_type(string) when is_binary(string) do
    case Integer.parse(string) do
      {int, ""} when int in 0..5 -> {:ok, int}
      {int, ""} -> {:error, "transfer_type out of range 0-5: #{int}"}
      _ -> {:error, "invalid transfer_type: #{string}"}
    end
  rescue
    _ -> {:error, "invalid transfer_type: #{string}"}
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
