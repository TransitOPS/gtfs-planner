defmodule TransitRealtime.TripDescriptor do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripDescriptor",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :trip_id, 1, optional: true, type: :string, json_name: "tripId"
  field :route_id, 5, optional: true, type: :string, json_name: "routeId"
  field :direction_id, 6, optional: true, type: :uint32, json_name: "directionId"
  field :start_time, 2, optional: true, type: :string, json_name: "startTime"
  field :start_date, 3, optional: true, type: :string, json_name: "startDate"

  field :schedule_relationship, 4,
    optional: true,
    type: TransitRealtime.TripDescriptor.ScheduleRelationship,
    json_name: "scheduleRelationship",
    enum: true

  field :modified_trip, 7,
    optional: true,
    type: TransitRealtime.TripDescriptor.ModifiedTripSelector,
    json_name: "modifiedTrip"

  extensions [{1000, 2000}, {9000, 10000}]
end
