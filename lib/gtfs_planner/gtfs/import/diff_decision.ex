defmodule GtfsPlanner.Gtfs.Import.DiffDecision do
  @moduledoc """
  Represents a proposed station-data change during GTFS diff import.
  """

  @type action :: :add | :modify | :remove | :conflict
  @type entity_type :: :level | :stop | :pathway
  @type status :: :pending | :approved | :rejected

  @enforce_keys [:id, :action, :entity_type, :natural_key]
  defstruct [
    :id,
    :action,
    :entity_type,
    :natural_key,
    current_record: nil,
    uploaded_attrs: nil,
    changed_fields: [],
    user_edited: false,
    status: :pending,
    dependency_keys: [],
    first_of_group: false
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          action: action(),
          entity_type: entity_type(),
          natural_key: String.t(),
          current_record: struct() | nil,
          uploaded_attrs: map() | nil,
          changed_fields: [{atom(), {term(), term()}}],
          user_edited: boolean(),
          status: status(),
          dependency_keys: [String.t()],
          first_of_group: boolean()
        }
end
