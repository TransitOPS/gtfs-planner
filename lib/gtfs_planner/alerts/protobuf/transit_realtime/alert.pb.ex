defmodule TransitRealtime.Alert do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.Alert",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :active_period, 1,
    repeated: true,
    type: TransitRealtime.TimeRange,
    json_name: "activePeriod",
    deprecated: true

  field :communication_period, 2,
    repeated: true,
    type: TransitRealtime.TimeRange,
    json_name: "communicationPeriod"

  field :impact_period, 3,
    repeated: true,
    type: TransitRealtime.TimeRange,
    json_name: "impactPeriod"

  field :informed_entity, 5,
    repeated: true,
    type: TransitRealtime.EntitySelector,
    json_name: "informedEntity"

  field :cause, 6,
    optional: true,
    type: TransitRealtime.Alert.Cause,
    default: :UNKNOWN_CAUSE,
    enum: true

  field :effect, 7,
    optional: true,
    type: TransitRealtime.Alert.Effect,
    default: :UNKNOWN_EFFECT,
    enum: true

  field :url, 8, optional: true, type: TransitRealtime.TranslatedString

  field :header_text, 10,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "headerText"

  field :description_text, 11,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "descriptionText"

  field :tts_header_text, 12,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "ttsHeaderText"

  field :tts_description_text, 13,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "ttsDescriptionText"

  field :severity_level, 14,
    optional: true,
    type: TransitRealtime.Alert.SeverityLevel,
    json_name: "severityLevel",
    default: :UNKNOWN_SEVERITY,
    enum: true

  field :image, 15, optional: true, type: TransitRealtime.TranslatedImage

  field :image_alternative_text, 16,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "imageAlternativeText"

  field :cause_detail, 17,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "causeDetail"

  field :effect_detail, 18,
    optional: true,
    type: TransitRealtime.TranslatedString,
    json_name: "effectDetail"

  extensions [{1000, 2000}, {9000, 10000}]
end
