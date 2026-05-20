defmodule GtfsPlanner.Gtfs.FareRule do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fare_rules" do
    field :fare_id, :string
    field :route_id, :string
    field :origin_id, :string
    field :destination_id, :string
    field :contains_id, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          fare_id: String.t(),
          route_id: String.t() | nil,
          origin_id: String.t() | nil,
          destination_id: String.t() | nil,
          contains_id: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a fare rule."
  def changeset(fare_rule, attrs) do
    fare_rule
    |> cast(attrs, [
      :fare_id,
      :route_id,
      :origin_id,
      :destination_id,
      :contains_id,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([:fare_id, :organization_id, :gtfs_version_id])
    |> unique_constraint([
      :organization_id,
      :gtfs_version_id,
      :fare_id,
      :route_id,
      :origin_id,
      :destination_id,
      :contains_id
    ])
    |> foreign_key_constraint(:organization_id)
  end
end
