defmodule TransitRealtime.TripUpdate.TripProperties do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripUpdate.TripProperties",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :trip_id, 1, optional: true, type: :string, json_name: "tripId"
  field :start_date, 2, optional: true, type: :string, json_name: "startDate"
  field :start_time, 3, optional: true, type: :string, json_name: "startTime"
  field :shape_id, 4, optional: true, type: :string, json_name: "shapeId"
  field :trip_headsign, 5, optional: true, type: :string, json_name: "tripHeadsign"
  field :trip_short_name, 6, optional: true, type: :string, json_name: "tripShortName"

  extensions [{1000, 2000}, {9000, 10000}]
end
