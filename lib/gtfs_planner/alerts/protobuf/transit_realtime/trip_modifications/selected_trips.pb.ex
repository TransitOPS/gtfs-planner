defmodule TransitRealtime.TripModifications.SelectedTrips do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripModifications.SelectedTrips",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :trip_ids, 1, repeated: true, type: :string, json_name: "tripIds"
  field :shape_id, 2, optional: true, type: :string, json_name: "shapeId"

  extensions [{1000, 2000}, {9000, 10000}]
end
