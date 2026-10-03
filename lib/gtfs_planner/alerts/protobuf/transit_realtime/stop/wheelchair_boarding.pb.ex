defmodule TransitRealtime.Stop.WheelchairBoarding do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "transit_realtime.Stop.WheelchairBoarding",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :UNKNOWN, 0
  field :AVAILABLE, 1
  field :NOT_AVAILABLE, 2
end
