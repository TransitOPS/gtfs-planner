defmodule TransitRealtime.EntitySelector do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.EntitySelector",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :agency_id, 1, optional: true, type: :string, json_name: "agencyId"
  field :route_id, 2, optional: true, type: :string, json_name: "routeId"
  field :route_type, 3, optional: true, type: :int32, json_name: "routeType"
  field :trip, 4, optional: true, type: TransitRealtime.TripDescriptor
  field :stop_id, 5, optional: true, type: :string, json_name: "stopId"
  field :direction_id, 6, optional: true, type: :uint32, json_name: "directionId"

  extensions [{1000, 2000}, {9000, 10000}]
end
