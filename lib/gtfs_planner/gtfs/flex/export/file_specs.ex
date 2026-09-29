defmodule GtfsPlanner.Gtfs.Flex.Export.FileSpecs do
  @moduledoc """
  The field specs of the flex-only files and the flex `stop_times.txt` header.

  The flex `stop_times.txt` is the full profile's file with the six flex
  columns in their GTFS reference positions, because the flex zip writes the
  fixed trips and the flex rows through one header. The three extra CSVs are
  written from rows `GtfsPlanner.Gtfs.Flex.Export.Areas` and
  `GtfsPlanner.Gtfs.Flex.Export.Detours` build, keyed by GTFS column atoms, so
  `GtfsPlanner.Gtfs.Export.CsvWriter.write_row/4` resolves them; none of them
  is read back from the database, so `schema` is nil.

  `booking_rules.txt` carries `pickup_message` and `drop_off_message` even
  though only a detour service sets the latter: GTFS defines both columns and an
  omitted key would write no column at all.
  """

  alias GtfsPlanner.Gtfs.StopTime

  @doc """
  `stop_times.txt` as the flex zip writes it: the full profile's columns plus
  `location_group_id`, `location_id`, `start_pickup_drop_off_window`,
  `end_pickup_drop_off_window`, `pickup_booking_rule_id` and
  `drop_off_booking_rule_id`, in the GTFS reference order.
  """
  def stop_times_spec do
    %{
      filename: "stop_times.txt",
      schema: StopTime,
      fields: [
        {"trip_id", :trip_id},
        {"arrival_time", :arrival_time},
        {"departure_time", :departure_time},
        {"stop_id", :stop_id},
        {"location_group_id", :location_group_id},
        {"location_id", :location_id},
        {"stop_sequence", :stop_sequence},
        {"stop_headsign", :stop_headsign},
        {"start_pickup_drop_off_window", :start_pickup_drop_off_window},
        {"end_pickup_drop_off_window", :end_pickup_drop_off_window},
        {"pickup_type", :pickup_type},
        {"drop_off_type", :drop_off_type},
        {"continuous_pickup", :continuous_pickup},
        {"continuous_drop_off", :continuous_drop_off},
        {"shape_dist_traveled", :shape_dist_traveled},
        {"timepoint", :timepoint},
        {"pickup_booking_rule_id", :pickup_booking_rule_id},
        {"drop_off_booking_rule_id", :drop_off_booking_rule_id}
      ]
    }
  end

  @doc """
  `booking_rules.txt` in the GTFS reference column order. The rows come from
  `GtfsPlanner.Gtfs.Flex.Export.Areas.booking_rule_rows/2` (plus the detour
  service's `drop_off_message`), never from the imported `booking_rules` table.
  """
  def booking_rules_spec do
    %{
      filename: "booking_rules.txt",
      schema: nil,
      fields: [
        {"booking_rule_id", :booking_rule_id},
        {"booking_type", :booking_type},
        {"prior_notice_duration_min", :prior_notice_duration_min},
        {"prior_notice_duration_max", :prior_notice_duration_max},
        {"prior_notice_last_day", :prior_notice_last_day},
        {"prior_notice_last_time", :prior_notice_last_time},
        {"prior_notice_start_day", :prior_notice_start_day},
        {"prior_notice_start_time", :prior_notice_start_time},
        {"prior_notice_service_id", :prior_notice_service_id},
        {"message", :message},
        {"pickup_message", :pickup_message},
        {"drop_off_message", :drop_off_message},
        {"phone_number", :phone_number},
        {"info_url", :info_url},
        {"booking_url", :booking_url}
      ]
    }
  end

  @doc "`location_groups.txt` for the area services that name connecting stops."
  def location_groups_spec do
    %{
      filename: "location_groups.txt",
      schema: nil,
      fields: [
        {"location_group_id", :location_group_id},
        {"location_group_name", :location_group_name}
      ]
    }
  end

  @doc "`location_group_stops.txt`: which stops belong to each connecting-stops group."
  def location_group_stops_spec do
    %{
      filename: "location_group_stops.txt",
      schema: nil,
      fields: [
        {"location_group_id", :location_group_id},
        {"stop_id", :stop_id}
      ]
    }
  end
end
