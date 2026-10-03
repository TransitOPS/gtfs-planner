defmodule TransitRealtime.Alert.SeverityLevel do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "transit_realtime.Alert.SeverityLevel",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :UNKNOWN_SEVERITY, 1
  field :INFO, 2
  field :WARNING, 3
  field :SEVERE, 4
end
