defmodule GtfsPlanner.Validations.WalkabilityTest do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          stop_id: String.t(),
          address: String.t(),
          address_lat: Decimal.t(),
          address_lon: Decimal.t(),
          description: String.t() | nil,
          expected_traversable: boolean() | nil,
          expected_wheelchair_accessible: boolean() | nil,
          expected_min_duration_seconds: integer() | nil,
          expected_max_duration_seconds: integer() | nil,
          expected_min_distance_meters: integer() | nil,
          expected_max_distance_meters: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "walkability_tests" do
    field :stop_id, :string
    field :address, :string
    field :address_lat, :decimal
    field :address_lon, :decimal
    field :description, :string
    field :expected_traversable, :boolean
    field :expected_wheelchair_accessible, :boolean
    field :expected_min_duration_seconds, :integer
    field :expected_max_duration_seconds, :integer
    field :expected_min_distance_meters, :integer
    field :expected_max_distance_meters, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(walkability_test, attrs) do
    walkability_test
    |> cast(attrs, [
      :stop_id,
      :address,
      :address_lat,
      :address_lon,
      :description,
      :expected_traversable,
      :expected_wheelchair_accessible,
      :expected_min_duration_seconds,
      :expected_max_duration_seconds,
      :expected_min_distance_meters,
      :expected_max_distance_meters
    ])
    |> validate_required([:stop_id, :address, :address_lat, :address_lon])
    |> unique_constraint([:organization_id, :stop_id, :address])
    |> foreign_key_constraint(:organization_id)
  end
end
