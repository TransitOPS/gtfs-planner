defmodule TransitRealtime.Stop do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.Stop",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :stop_id, 1, optional: true, type: :string, json_name: "stopId"

  field :stop_code, 2,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "stopCode"

  field :stop_name, 3,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "stopName"

  field :tts_stop_name, 4,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "ttsStopName"

  field :stop_desc, 5,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "stopDesc"

  field :stop_lat, 6, optional: true, type: :float, json_name: "stopLat"
  field :stop_lon, 7, optional: true, type: :float, json_name: "stopLon"
  field :zone_id, 8, optional: true, type: :string, json_name: "zoneId"
  field :stop_url, 9, optional: true, type: TransitRealtime.TranslatedString, json_name: "stopUrl"
  field :parent_station, 11, optional: true, type: :string, json_name: "parentStation"
  field :stop_timezone, 12, optional: true, type: :string, json_name: "stopTimezone"

  field :wheelchair_boarding, 13,
    optional: true,
    type: TransitRealtime.Stop.WheelchairBoarding,
    json_name: "wheelchairBoarding",
    default: :UNKNOWN,
    enum: true

  field :level_id, 14, optional: true, type: :string, json_name: "levelId"

  field :platform_code, 15,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "platformCode"

  extensions [{1000, 2000}, {9000, 10000}]
end
