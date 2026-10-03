defmodule TransitRealtime.TripUpdate.StopTimeEvent do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripUpdate.StopTimeEvent",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :delay, 1, optional: true, type: :int32
  field :time, 2, optional: true, type: :int64
  field :uncertainty, 3, optional: true, type: :int32
  field :scheduled_time, 4, optional: true, type: :int64, json_name: "scheduledTime"

  extensions [{1000, 2000}, {9000, 10000}]
end
