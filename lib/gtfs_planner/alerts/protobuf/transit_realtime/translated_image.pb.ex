defmodule TransitRealtime.TranslatedImage do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TranslatedImage",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :localized_image, 1,
    repeated: true,
    type: TransitRealtime.TranslatedImage.LocalizedImage,
    json_name: "localizedImage"

  extensions [{1000, 2000}, {9000, 10000}]
end
