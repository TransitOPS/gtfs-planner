defmodule TransitRealtime.TripDescriptor.ModifiedTripSelector do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripDescriptor.ModifiedTripSelector",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :modifications_id, 1, optional: true, type: :string, json_name: "modificationsId"
  field :affected_trip_id, 2, optional: true, type: :string, json_name: "affectedTripId"
  field :start_time, 3, optional: true, type: :string, json_name: "startTime"
  field :start_date, 4, optional: true, type: :string, json_name: "startDate"

  extensions [{1000, 2000}, {9000, 10000}]
end
