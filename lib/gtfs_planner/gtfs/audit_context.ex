defmodule GtfsPlanner.Gtfs.AuditContext do
  @moduledoc """
  Bundles audit-scope parameters extracted from a LiveView socket so
  recording call sites can pass a single struct instead of five separate values.
  """
  defstruct [:organization_id, :gtfs_version_id, :station_stop_id, :actor_id, :actor_email]

  @type t :: %__MODULE__{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          station_stop_id: String.t() | nil,
          actor_id: Ecto.UUID.t(),
          actor_email: String.t()
        }
end
