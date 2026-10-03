defmodule TransitRealtime.VehiclePosition do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.VehiclePosition",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :trip, 1, optional: true, type: TransitRealtime.TripDescriptor
  field :vehicle, 8, optional: true, type: TransitRealtime.VehicleDescriptor
  field :position, 2, optional: true, type: TransitRealtime.Position
  field :current_stop_sequence, 3, optional: true, type: :uint32, json_name: "currentStopSequence"
  field :stop_id, 7, optional: true, type: :string, json_name: "stopId"

  field :current_status, 4,
    optional: true,
    type: TransitRealtime.VehiclePosition.VehicleStopStatus,
    json_name: "currentStatus",
    default: :IN_TRANSIT_TO,
    enum: true

  field :timestamp, 5, optional: true, type: :uint64

  field :congestion_level, 6,
    optional: true,
    type: TransitRealtime.VehiclePosition.CongestionLevel,
    json_name: "congestionLevel",
    enum: true

  field :occupancy_status, 9,
    optional: true,
    type: TransitRealtime.VehiclePosition.OccupancyStatus,
    json_name: "occupancyStatus",
    enum: true

  field :occupancy_percentage, 10, optional: true, type: :uint32, json_name: "occupancyPercentage"

  field :multi_carriage_details, 11,
    repeated: true,
    type: TransitRealtime.VehiclePosition.CarriageDetails,
    json_name: "multiCarriageDetails"

  extensions [{1000, 2000}, {9000, 10000}]
end
