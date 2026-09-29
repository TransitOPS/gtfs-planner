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

  @doc """
  Builds the context from LiveView assigns that hold the organization, GTFS version,
  signed-in user and the station whose editor recorded the change.
  """
  @spec from_assigns(map()) :: t()
  def from_assigns(%{
        current_organization: %{id: organization_id},
        current_gtfs_version: %{id: gtfs_version_id},
        current_user: %{id: actor_id, email: actor_email},
        station: %{stop_id: station_stop_id}
      }) do
    %__MODULE__{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      station_stop_id: station_stop_id,
      actor_id: actor_id,
      actor_email: actor_email
    }
  end
end
