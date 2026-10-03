defmodule TransitRealtime.FeedHeader.Incrementality do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "transit_realtime.FeedHeader.Incrementality",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :FULL_DATASET, 0
  field :DIFFERENTIAL, 1
end
