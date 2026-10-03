defmodule TransitRealtime.ReplacementStop do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.ReplacementStop",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :travel_time_to_stop, 1, optional: true, type: :int32, json_name: "travelTimeToStop"
  field :stop_id, 2, optional: true, type: :string, json_name: "stopId"

  extensions [{1000, 2000}, {9000, 10000}]
end
