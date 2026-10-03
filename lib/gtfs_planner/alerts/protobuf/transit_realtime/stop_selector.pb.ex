defmodule TransitRealtime.StopSelector do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.StopSelector",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :stop_sequence, 1, optional: true, type: :uint32, json_name: "stopSequence"
  field :stop_id, 2, optional: true, type: :string, json_name: "stopId"

  extensions [{1000, 2000}, {9000, 10000}]
end
