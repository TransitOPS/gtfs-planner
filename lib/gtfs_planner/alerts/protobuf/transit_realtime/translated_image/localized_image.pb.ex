defmodule TransitRealtime.TranslatedImage.LocalizedImage do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TranslatedImage.LocalizedImage",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :url, 1, required: true, type: :string
  field :media_type, 2, required: true, type: :string, json_name: "mediaType"
  field :language, 3, optional: true, type: :string

  extensions [{1000, 2000}, {9000, 10000}]
end
