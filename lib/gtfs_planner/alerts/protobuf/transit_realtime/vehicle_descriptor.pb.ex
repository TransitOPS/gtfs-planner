defmodule TransitRealtime.VehicleDescriptor do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.VehicleDescriptor",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :id, 1, optional: true, type: :string
  field :label, 2, optional: true, type: :string
  field :license_plate, 3, optional: true, type: :string, json_name: "licensePlate"

  field :wheelchair_accessible, 4,
    optional: true,
    type: TransitRealtime.VehicleDescriptor.WheelchairAccessible,
    json_name: "wheelchairAccessible",
    default: :NO_VALUE,
    enum: true

  extensions [{1000, 2000}, {9000, 10000}]
end
