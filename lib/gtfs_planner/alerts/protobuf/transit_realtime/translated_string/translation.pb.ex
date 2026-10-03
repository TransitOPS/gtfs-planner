defmodule TransitRealtime.TranslatedString.Translation do
  @moduledoc false

  use Protobuf,
    full_name: "transit_realtime.TranslatedString.Translation",
    proto_source: "priv/proto/gtfs-realtime.proto",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :text, 1, required: true, type: :string
  field :language, 2, optional: true, type: :string

  extensions [{1000, 2000}, {9000, 10000}]
end
