defmodule TransitRealtime.VehiclePosition.VehicleStopStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "transit_realtime.VehiclePosition.VehicleStopStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :INCOMING_AT, 0
  field :STOPPED_AT, 1
  field :IN_TRANSIT_TO, 2
end
