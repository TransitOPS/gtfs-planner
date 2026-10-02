defmodule TransitRealtime.FeedEntity do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.FeedEntity",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :id, 1, required: true, type: :string
  field :is_deleted, 2, optional: true, type: :bool, json_name: "isDeleted", default: false
  field :trip_update, 3, optional: true, type: TransitRealtime.TripUpdate, json_name: "tripUpdate"
  field :vehicle, 4, optional: true, type: TransitRealtime.VehiclePosition
  field :alert, 5, optional: true, type: TransitRealtime.Alert
  field :shape, 6, optional: true, type: TransitRealtime.Shape
  field :stop, 7, optional: true, type: TransitRealtime.Stop

  field :trip_modifications, 8,
    optional: true,
    type: TransitRealtime.TripModifications,
    json_name: "tripModifications"

  extensions [{1000, 2000}, {9000, 10000}]
end
