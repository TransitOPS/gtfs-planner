defmodule TransitRealtime.Position do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.Position",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :latitude, 1, required: true, type: :float
  field :longitude, 2, required: true, type: :float
  field :bearing, 3, optional: true, type: :float
  field :odometer, 4, optional: true, type: :double
  field :speed, 5, optional: true, type: :float

  extensions [{1000, 2000}, {9000, 10000}]
end
