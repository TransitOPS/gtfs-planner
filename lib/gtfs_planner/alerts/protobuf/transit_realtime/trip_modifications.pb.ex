defmodule TransitRealtime.TripModifications do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripModifications",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :selected_trips, 1,
    repeated: true,
    type: TransitRealtime.TripModifications.SelectedTrips,
    json_name: "selectedTrips"

  field :start_times, 2, repeated: true, type: :string, json_name: "startTimes"
  field :service_dates, 3, repeated: true, type: :string, json_name: "serviceDates"
  field :modifications, 4, repeated: true, type: TransitRealtime.TripModifications.Modification

  extensions [{1000, 2000}, {9000, 10000}]
end
