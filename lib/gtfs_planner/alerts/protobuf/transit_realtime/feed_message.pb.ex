defmodule TransitRealtime.FeedMessage do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.FeedMessage",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :header, 1, required: true, type: TransitRealtime.FeedHeader
  field :entity, 2, repeated: true, type: TransitRealtime.FeedEntity

  extensions [{1000, 2000}, {9000, 10000}]
end
