defmodule TransitRealtime.VehicleDescriptor.WheelchairAccessible do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "transit_realtime.VehicleDescriptor.WheelchairAccessible",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :NO_VALUE, 0
  field :UNKNOWN, 1
  field :WHEELCHAIR_ACCESSIBLE, 2
  field :WHEELCHAIR_INACCESSIBLE, 3
end
