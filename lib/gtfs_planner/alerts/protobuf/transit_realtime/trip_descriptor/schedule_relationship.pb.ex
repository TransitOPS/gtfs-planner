defmodule TransitRealtime.TripDescriptor.ScheduleRelationship do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "transit_realtime.TripDescriptor.ScheduleRelationship",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto2

  field :SCHEDULED, 0
  field :ADDED, 1
  field :UNSCHEDULED, 2
  field :CANCELED, 3
  field :REPLACEMENT, 5
  field :DUPLICATED, 6
  field :DELETED, 7
  field :NEW, 8
end
