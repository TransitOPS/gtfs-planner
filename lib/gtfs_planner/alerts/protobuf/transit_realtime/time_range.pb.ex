defmodule TransitRealtime.TimeRange do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TimeRange",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :start, 1, optional: true, type: :uint64
  field :end, 2, optional: true, type: :uint64

  extensions [{1000, 2000}, {9000, 10000}]
end
