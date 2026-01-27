defmodule GtfsPlanner.Gtfs.Export.FileSpec do
  @moduledoc """
  Defines GTFS field specifications for each file type.

  Each spec maps database schema fields to GTFS CSV fields, handling:
  - Direct field mappings (schema field → CSV field)
  - Foreign key lookups (UUID → GTFS string ID)
  - Field exclusions (internal fields not in GTFS spec)
  """

  alias GtfsPlanner.Gtfs

  @doc """
  Returns the file specification for the given file type.

  Each spec is a map with:
  - `:filename` - GTFS filename (e.g., "stops.txt")
  - `:schema` - Ecto schema module
  - `:fields` - List of `{csv_field_name, source}` tuples where source is:
    - An atom for direct field mapping
    - `{:lookup, db_field, lookup_key}` for foreign key resolution
  """
  def agency_spec do
    %{
      filename: "agency.txt",
      schema: Gtfs.Agency,
      fields: [
        {"agency_id", :agency_id},
        {"agency_name", :agency_name},
        {"agency_url", :agency_url},
        {"agency_timezone", :agency_timezone},
        {"agency_lang", :agency_lang},
        {"agency_phone", :agency_phone},
        {"agency_fare_url", :agency_fare_url},
        {"agency_email", :agency_email}
      ]
    }
  end

  def stops_spec do
    %{
      filename: "stops.txt",
      schema: Gtfs.Stop,
      fields: [
        {"stop_id", :stop_id},
        {"stop_name", :stop_name},
        {"stop_desc", :stop_desc},
        {"stop_lat", :stop_lat},
        {"stop_lon", :stop_lon},
        {"location_type", :location_type},
        {"parent_station", :parent_station},
        {"wheelchair_boarding", :wheelchair_boarding},
        {"platform_code", :platform_code},
        {"level_id", :level_id}
      ]
    }
  end

  def routes_spec do
    %{
      filename: "routes.txt",
      schema: Gtfs.Route,
      fields: [
        {"route_id", :route_id},
        {"agency_id", :agency_id},
        {"route_short_name", :route_short_name},
        {"route_long_name", :route_long_name},
        {"route_desc", :route_desc},
        {"route_type", :route_type},
        {"route_url", :route_url},
        {"route_color", :route_color},
        {"route_text_color", :route_text_color},
        {"route_sort_order", :route_sort_order},
        {"continuous_pickup", :continuous_pickup},
        {"continuous_drop_off", :continuous_drop_off},
        {"network_id", :network_id}
      ]
    }
  end

  def trips_spec do
    %{
      filename: "trips.txt",
      schema: Gtfs.Trip,
      fields: [
        {"route_id", :route_id},
        {"service_id", :service_id},
        {"trip_id", :trip_id},
        {"trip_headsign", :trip_headsign},
        {"trip_short_name", :trip_short_name},
        {"direction_id", :direction_id},
        {"block_id", :block_id},
        {"shape_id", :shape_id},
        {"wheelchair_accessible", :wheelchair_accessible},
        {"bikes_allowed", :bikes_allowed}
      ]
    }
  end

  def stop_times_spec do
    %{
      filename: "stop_times.txt",
      schema: Gtfs.StopTime,
      fields: [
        {"trip_id", :trip_id},
        {"arrival_time", :arrival_time},
        {"departure_time", :departure_time},
        {"stop_id", :stop_id},
        {"stop_sequence", :stop_sequence},
        {"stop_headsign", :stop_headsign},
        {"pickup_type", :pickup_type},
        {"drop_off_type", :drop_off_type},
        {"continuous_pickup", :continuous_pickup},
        {"continuous_drop_off", :continuous_drop_off},
        {"shape_dist_traveled", :shape_dist_traveled},
        {"timepoint", :timepoint}
      ]
    }
  end

  def calendar_spec do
    %{
      filename: "calendar.txt",
      schema: Gtfs.Calendar,
      fields: [
        {"service_id", :service_id},
        {"monday", :monday},
        {"tuesday", :tuesday},
        {"wednesday", :wednesday},
        {"thursday", :thursday},
        {"friday", :friday},
        {"saturday", :saturday},
        {"sunday", :sunday},
        {"start_date", :start_date},
        {"end_date", :end_date}
      ]
    }
  end

  def calendar_dates_spec do
    %{
      filename: "calendar_dates.txt",
      schema: Gtfs.CalendarDate,
      fields: [
        {"service_id", :service_id},
        {"date", :date},
        {"exception_type", :exception_type}
      ]
    }
  end

  def fare_attributes_spec do
    %{
      filename: "fare_attributes.txt",
      schema: Gtfs.FareAttribute,
      fields: [
        {"fare_id", :fare_id},
        {"price", :price},
        {"currency_type", :currency_type},
        {"payment_method", :payment_method},
        {"transfers", :transfers},
        {"agency_id", :agency_id},
        {"transfer_duration", :transfer_duration}
      ]
    }
  end

  def fare_rules_spec do
    %{
      filename: "fare_rules.txt",
      schema: Gtfs.FareRule,
      fields: [
        {"fare_id", :fare_id},
        {"route_id", :route_id},
        {"origin_id", :origin_id},
        {"destination_id", :destination_id},
        {"contains_id", :contains_id}
      ]
    }
  end

  def shapes_spec do
    %{
      filename: "shapes.txt",
      schema: Gtfs.Shape,
      fields: [
        {"shape_id", :shape_id},
        {"shape_pt_lat", :shape_pt_lat},
        {"shape_pt_lon", :shape_pt_lon},
        {"shape_pt_sequence", :shape_pt_sequence},
        {"shape_dist_traveled", :shape_dist_traveled}
      ]
    }
  end

  def frequencies_spec do
    %{
      filename: "frequencies.txt",
      schema: Gtfs.Frequency,
      fields: [
        {"trip_id", :trip_id},
        {"start_time", :start_time},
        {"end_time", :end_time},
        {"headway_secs", :headway_secs},
        {"exact_times", :exact_times}
      ]
    }
  end

  def transfers_spec do
    %{
      filename: "transfers.txt",
      schema: Gtfs.Transfer,
      fields: [
        {"from_stop_id", :from_stop_id},
        {"to_stop_id", :to_stop_id},
        {"from_route_id", :from_route_id},
        {"to_route_id", :to_route_id},
        {"from_trip_id", :from_trip_id},
        {"to_trip_id", :to_trip_id},
        {"transfer_type", :transfer_type},
        {"min_transfer_time", :min_transfer_time}
      ]
    }
  end

  def pathways_spec do
    %{
      filename: "pathways.txt",
      schema: Gtfs.Pathway,
      fields: [
        {"pathway_id", :pathway_id},
        {"from_stop_id", :from_stop_id},
        {"to_stop_id", :to_stop_id},
        {"pathway_mode", :pathway_mode},
        {"is_bidirectional", :is_bidirectional},
        {"length", :length},
        {"traversal_time", :traversal_time},
        {"stair_count", :stair_count},
        {"max_slope", :max_slope},
        {"min_width", :min_width},
        {"signposted_as", :signposted_as},
        {"reversed_signposted_as", :reversed_signposted_as}
      ]
    }
  end

  def levels_spec do
    %{
      filename: "levels.txt",
      schema: Gtfs.Level,
      fields: [
        {"level_id", :level_id},
        {"level_index", :level_index},
        {"level_name", :level_name}
      ]
    }
  end

  def feed_info_spec do
    %{
      filename: "feed_info.txt",
      schema: Gtfs.FeedInfo,
      fields: [
        {"feed_publisher_name", :feed_publisher_name},
        {"feed_publisher_url", :feed_publisher_url},
        {"feed_lang", :feed_lang},
        {"default_lang", :default_lang},
        {"feed_start_date", :feed_start_date},
        {"feed_end_date", :feed_end_date},
        {"feed_version", :feed_version},
        {"feed_contact_email", :feed_contact_email},
        {"feed_contact_url", :feed_contact_url}
      ]
    }
  end

  def attributions_spec do
    %{
      filename: "attributions.txt",
      schema: Gtfs.Attribution,
      fields: [
        {"attribution_id", :attribution_id},
        {"agency_id", :agency_id},
        {"route_id", :route_id},
        {"trip_id", :trip_id},
        {"organization_name", :organization_name},
        {"is_producer", :is_producer},
        {"is_operator", :is_operator},
        {"is_authority", :is_authority},
        {"attribution_url", :attribution_url},
        {"attribution_email", :attribution_email},
        {"attribution_phone", :attribution_phone}
      ]
    }
  end

  @doc """
  Returns list of file specs for the given export type.

  ## Export Types
  - `:full` - All GTFS files
  - `:pathways` - Only stops, levels, and pathways
  """
  def get_specs(:full) do
    [
      agency_spec(),
      stops_spec(),
      routes_spec(),
      trips_spec(),
      stop_times_spec(),
      calendar_spec(),
      calendar_dates_spec(),
      fare_attributes_spec(),
      fare_rules_spec(),
      shapes_spec(),
      frequencies_spec(),
      transfers_spec(),
      pathways_spec(),
      levels_spec(),
      feed_info_spec(),
      attributions_spec()
    ]
  end

  def get_specs(:pathways) do
    [
      stops_spec(),
      levels_spec(),
      pathways_spec()
    ]
  end
end
