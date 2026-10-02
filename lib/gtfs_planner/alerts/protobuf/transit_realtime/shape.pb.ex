defmodule TransitRealtime.Shape do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.Shape",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :shape_id, 1, optional: true, type: :string, json_name: "shapeId"
  field :encoded_polyline, 2, optional: true, type: :string, json_name: "encodedPolyline"

  extensions [{1000, 2000}, {9000, 10000}]
end
