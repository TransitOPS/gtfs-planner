defmodule GtfsPlanner.Gtfs.StationJournal.Scope do
  @moduledoc """
  Trusted scope for all station-journal operations.

  Scope values are resolved from the authenticated request and station lookup; they
  are never derived from client journal attributes.
  """

  @enforce_keys [:organization_id, :gtfs_version_id, :station_id, :station_stop_id, :actor_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          station_id: Ecto.UUID.t(),
          station_stop_id: String.t(),
          actor_id: Ecto.UUID.t()
        }
end
