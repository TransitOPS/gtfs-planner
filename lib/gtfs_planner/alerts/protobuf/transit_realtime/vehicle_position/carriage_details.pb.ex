defmodule TransitRealtime.VehiclePosition.CarriageDetails do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.VehiclePosition.CarriageDetails",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :id, 1, optional: true, type: :string
  field :label, 2, optional: true, type: :string

  field :occupancy_status, 3,
    optional: true,
    type: TransitRealtime.VehiclePosition.OccupancyStatus,
    json_name: "occupancyStatus",
    default: :NO_DATA_AVAILABLE,
    enum: true

  field :occupancy_percentage, 4,
    optional: true,
    type: :int32,
    json_name: "occupancyPercentage",
    default: -1

  field :carriage_sequence, 5, optional: true, type: :uint32, json_name: "carriageSequence"

  extensions [{1000, 2000}, {9000, 10000}]
end
