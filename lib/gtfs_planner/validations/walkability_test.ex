defmodule GtfsPlanner.Validations.WalkabilityTest do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
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
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

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
    |> trim_string_fields()
    |> validate_required([:stop_id, :address, :address_lat, :address_lon, :gtfs_version_id])
    |> validate_number(:expected_min_duration_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:expected_max_duration_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:expected_min_distance_meters, greater_than_or_equal_to: 0)
    |> validate_number(:expected_max_distance_meters, greater_than_or_equal_to: 0)
    |> validate_min_max_range(:expected_min_duration_seconds, :expected_max_duration_seconds)
    |> validate_min_max_range(:expected_min_distance_meters, :expected_max_distance_meters)
    |> unique_constraint(:address,
      name: :walkability_tests_organization_id_gtfs_version_id_stop_id_addre
    )
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
  end

  defp validate_min_max_range(changeset, min_field, max_field) do
    min_value = get_field(changeset, min_field)
    max_value = get_field(changeset, max_field)

    if is_integer(min_value) and is_integer(max_value) and min_value > max_value do
      changeset
      |> add_error(min_field, "must be less than or equal to #{max_field}")
      |> add_error(max_field, "must be greater than or equal to #{min_field}")
    else
      changeset
    end
  end
end
