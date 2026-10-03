defmodule TransitRealtime.TranslatedString do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TranslatedString",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :translation, 1, repeated: true, type: TransitRealtime.TranslatedString.Translation

  extensions [{1000, 2000}, {9000, 10000}]
end
