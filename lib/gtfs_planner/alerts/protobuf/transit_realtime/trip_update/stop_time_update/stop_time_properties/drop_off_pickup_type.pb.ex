defmodule TransitRealtime.TripUpdate.StopTimeUpdate.StopTimeProperties.DropOffPickupType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "transit_realtime.TripUpdate.StopTimeUpdate.StopTimeProperties.DropOffPickupType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :REGULAR, 0
  field :NONE, 1
  field :PHONE_AGENCY, 2
  field :COORDINATE_WITH_DRIVER, 3
end
