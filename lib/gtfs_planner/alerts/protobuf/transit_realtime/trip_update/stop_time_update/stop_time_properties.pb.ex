defmodule TransitRealtime.TripUpdate.StopTimeUpdate.StopTimeProperties do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripUpdate.StopTimeUpdate.StopTimeProperties",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :assigned_stop_id, 1, optional: true, type: :string, json_name: "assignedStopId"
  field :stop_headsign, 2, optional: true, type: :string, json_name: "stopHeadsign"

  field :pickup_type, 3,
    optional: true,
    type: TransitRealtime.TripUpdate.StopTimeUpdate.StopTimeProperties.DropOffPickupType,
    json_name: "pickupType",
    enum: true

  field :drop_off_type, 4,
    optional: true,
    type: TransitRealtime.TripUpdate.StopTimeUpdate.StopTimeProperties.DropOffPickupType,
    json_name: "dropOffType",
    enum: true

  extensions [{1000, 2000}, {9000, 10000}]
end
