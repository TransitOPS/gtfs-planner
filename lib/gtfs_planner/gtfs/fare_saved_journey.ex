defmodule GtfsPlanner.Gtfs.FareSavedJourney do
  @moduledoc """
  One journey an operator saved to re-price it after a fare change.

  A saved journey is the rider, the payment method, the legs and the service date
  whose price `Fares.Interpreter` priced once. `legs` is the interpreter's leg
  list as JSON, so the journey can be priced again without rebuilding it, and
  `expected_amount` is the amount the editor saw. A journey belongs to exactly
  one version and never to an operator, so it is scoped by
  `organization_id` and `gtfs_version_id` like every other fare row.

  `changeset/2` casts the six user fields only. `organization_id` and
  `gtfs_version_id` are set on the struct by the writer and are never cast
  (AGENTS.md).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fare_saved_journeys" do
    field :name, :string
    field :rider_category_id, :string
    field :fare_media_id, :string
    field :legs, {:array, :map}
    field :service_date, :date
    field :expected_amount, :decimal

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          gtfs_version_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          rider_category_id: String.t() | nil,
          fare_media_id: String.t() | nil,
          legs: [map()] | nil,
          service_date: Date.t() | nil,
          expected_amount: Decimal.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "A changeset for one saved journey."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(journey, attrs) do
    journey
    |> cast(attrs, [
      :name,
      :rider_category_id,
      :fare_media_id,
      :legs,
      :service_date,
      :expected_amount
    ])
    |> update_change(:name, &trim/1)
    |> validate_required([:name, :rider_category_id, :legs, :service_date, :expected_amount])
    |> validate_length(:name, max: 120)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
