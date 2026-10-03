defmodule TransitRealtime.FeedHeader do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.FeedHeader",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :gtfs_realtime_version, 1, required: true, type: :string, json_name: "gtfsRealtimeVersion"

  field :incrementality, 2,
    optional: true,
    type: TransitRealtime.FeedHeader.Incrementality,
    default: :FULL_DATASET,
    enum: true

  field :timestamp, 3, optional: true, type: :uint64
  field :feed_version, 4, optional: true, type: :string, json_name: "feedVersion"

  extensions [{1000, 2000}, {9000, 10000}]
end
