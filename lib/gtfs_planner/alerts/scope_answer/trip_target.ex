defmodule GtfsPlanner.Alerts.ScopeAnswer.TripTarget do
  @moduledoc """
  One cancelled or changed trip with the service date it runs on, embedded in
  `scope_answer.trips`.

  `service_date` is part of the identity because a trip repeats across its
  service dates and a consumer that reads only the trip ID would match every one
  of them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    # `trip_id` is a `:string` for the same reason as
    # `GtfsPlanner.Alerts.ScopeAnswer.RouteStopPair.route_id`: this row is stored
    # inside the `scope` jsonb column.
    field :trip_id, :string
    field :service_date, :date
  end

  @type t :: %__MODULE__{trip_id: Ecto.UUID.t() | nil, service_date: Date.t() | nil}

  @doc """
  Creates a changeset for one trip and service date.

  Requires both values, for the same reason as `RouteStopPair`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(trip, attrs) do
    trip
    |> cast(attrs, [:trip_id, :service_date])
    |> validate_required([:trip_id, :service_date])
  end
end
