defmodule GtfsPlanner.Alerts.ScopeAnswer.RouteStopPair do
  @moduledoc """
  One route and stop an alert affects together, embedded in `scope_answer.route_stop_pairs`.

  A pair is the only shape written for a skipped stop on chosen routes, because a
  consumer that honours informed entities combines the two fields inside one
  selector. Both values are row UUIDs, never GTFS feed IDs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    # Target identities are `:string`, not `:binary_id`: this row is stored inside
    # the `scope` jsonb column, and a dumped `:binary_id` is a raw 16-byte
    # binary that cannot be JSON-encoded. The value is still the row UUID, in
    # the same form the target schemas' `id` fields hold.
    field :route_id, :string
    field :stop_id, :string
  end

  @type t :: %__MODULE__{route_id: Ecto.UUID.t() | nil, stop_id: Ecto.UUID.t() | nil}

  @doc """
  Creates a changeset for one route and stop pair.

  Requires both identities: a pair with a missing value is not a selector any
  consumer can apply.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pair, attrs) do
    pair
    |> cast(attrs, [:route_id, :stop_id])
    |> validate_required([:route_id, :stop_id])
  end
end
