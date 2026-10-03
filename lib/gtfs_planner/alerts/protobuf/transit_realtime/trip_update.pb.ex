defmodule TransitRealtime.TripUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripUpdate",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :trip, 1, required: true, type: TransitRealtime.TripDescriptor
  field :vehicle, 3, optional: true, type: TransitRealtime.VehicleDescriptor

  field :stop_time_update, 2,
    repeated: true,
    type: TransitRealtime.TripUpdate.StopTimeUpdate,
    json_name: "stopTimeUpdate"

  field :timestamp, 4, optional: true, type: :uint64
  field :delay, 5, optional: true, type: :int32

  field :trip_properties, 6,
    optional: true,
    type: TransitRealtime.TripUpdate.TripProperties,
    json_name: "tripProperties"

  extensions [{1000, 2000}, {9000, 10000}]
end
