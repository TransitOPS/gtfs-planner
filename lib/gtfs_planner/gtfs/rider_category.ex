defmodule GtfsPlanner.Gtfs.RiderCategory do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rider_categories" do
    field :rider_category_id, :string
    field :rider_category_name, :string
    field :min_age, :integer
    field :max_age, :integer
    field :eligibility_url, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          rider_category_id: String.t(),
          rider_category_name: String.t(),
          min_age: integer() | nil,
          max_age: integer() | nil,
          eligibility_url: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a rider category."
  def changeset(rider_category, attrs) do
    rider_category
    |> cast(attrs, [
      :rider_category_id,
      :rider_category_name,
      :min_age,
      :max_age,
      :eligibility_url,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([
      :rider_category_id,
      :rider_category_name,
      :organization_id,
      :gtfs_version_id
    ])
    |> unique_constraint([:organization_id, :gtfs_version_id, :rider_category_id])
    |> foreign_key_constraint(:organization_id)
  end
end
