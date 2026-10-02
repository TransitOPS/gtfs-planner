defmodule TransitRealtime.TripModifications.Modification do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TripModifications.Modification",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :start_stop_selector, 1,
    optional: true,
    type: TransitRealtime.StopSelector,
    json_name: "startStopSelector"

  field :end_stop_selector, 2,
    optional: true,
    type: TransitRealtime.StopSelector,
    json_name: "endStopSelector"

  field :propagated_modification_delay, 3,
    optional: true,
    type: :int32,
    json_name: "propagatedModificationDelay",
    default: 0

  field :replacement_stops, 4,
    repeated: true,
    type: TransitRealtime.ReplacementStop,
    json_name: "replacementStops"

  field :service_alert_id, 5, optional: true, type: :string, json_name: "serviceAlertId"
  field :last_modified_time, 6, optional: true, type: :uint64, json_name: "lastModifiedTime"

  extensions [{1000, 2000}, {9000, 10000}]
end
