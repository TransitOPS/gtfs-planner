defmodule TransitRealtime.TripUpdate.StopTimeUpdate.ScheduleRelationship do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "transit_realtime.TripUpdate.StopTimeUpdate.ScheduleRelationship",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :SCHEDULED, 0
  field :SKIPPED, 1
  field :NO_DATA, 2
  field :UNSCHEDULED, 3
end
