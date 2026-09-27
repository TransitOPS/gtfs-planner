defmodule GtfsPlanner.Operations.Garage do
  @moduledoc """
  An organization-wide garage.

  A garage belongs to exactly one organization and ignores GTFS versions: its
  UUID is its identity and `garage_id` is a correctable external ID that is
  unique within the organization. `organization_id` and `updated_by_id` are set
  programmatically and are never cast from user params.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @garage_id_format ~r/^[A-Za-z0-9_.:-]+$/

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          garage_id: String.t(),
          name: String.t(),
          address: String.t() | nil,
          lat: Decimal.t(),
          lon: Decimal.t(),
          updated_by_id: Ecto.UUID.t() | nil,
          vehicle_count: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "garages" do
    field :garage_id, :string
    field :name, :string
    field :address, :string
    field :lat, :decimal
    field :lon, :decimal
    field :updated_by_id, :binary_id
    field :vehicle_count, :integer, virtual: true, default: 0

    belongs_to :organization, GtfsPlanner.Organizations.Organization

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A changeset for creating and updating a garage.

  Casts only the user-editable fields. `organization_id` and `updated_by_id` are
  assigned by `GtfsPlanner.Operations`.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(garage, attrs) do
    garage
    |> cast(attrs, [:garage_id, :name, :address, :lat, :lon])
    |> trim_string_fields()
    |> validate_required([:garage_id, :name, :lat, :lon])
    |> validate_length(:garage_id, max: 255)
    |> validate_length(:name, max: 255)
    |> validate_length(:address, max: 255)
    |> validate_format(:garage_id, @garage_id_format)
    |> validate_number(:lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:lon, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> unique_constraint(:garage_id, name: :garages_organization_id_garage_id_index)
  end
end
