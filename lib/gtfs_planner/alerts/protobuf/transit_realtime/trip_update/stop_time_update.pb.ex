defmodule TransitRealtime.TripUpdate.StopTimeUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripUpdate.StopTimeUpdate",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :stop_sequence, 1, optional: true, type: :uint32, json_name: "stopSequence"
  field :stop_id, 4, optional: true, type: :string, json_name: "stopId"
  field :arrival, 2, optional: true, type: TransitRealtime.TripUpdate.StopTimeEvent
  field :departure, 3, optional: true, type: TransitRealtime.TripUpdate.StopTimeEvent

  field :departure_occupancy_status, 7,
    optional: true,
    type: TransitRealtime.VehiclePosition.OccupancyStatus,
    json_name: "departureOccupancyStatus",
    enum: true

  field :schedule_relationship, 5,
    optional: true,
    type: TransitRealtime.TripUpdate.StopTimeUpdate.ScheduleRelationship,
    json_name: "scheduleRelationship",
    default: :SCHEDULED,
    enum: true

  field :stop_time_properties, 6,
    optional: true,
    type: TransitRealtime.TripUpdate.StopTimeUpdate.StopTimeProperties,
    json_name: "stopTimeProperties"

  extensions [{1000, 2000}, {9000, 10000}]
end
