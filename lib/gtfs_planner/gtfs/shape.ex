defmodule GtfsPlanner.Gtfs.Shape do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "shapes" do
    field :shape_id, :string
    field :shape_pt_lat, :decimal
    field :shape_pt_lon, :decimal
    field :shape_pt_sequence, :integer
    field :shape_dist_traveled, :decimal

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          shape_id: String.t(),
          shape_pt_lat: Decimal.t(),
          shape_pt_lon: Decimal.t(),
          shape_pt_sequence: integer(),
          shape_dist_traveled: Decimal.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a shape."
  def changeset(shape, attrs) do
    shape
    |> cast(attrs, [
      :shape_id,
      :shape_pt_lat,
      :shape_pt_lon,
      :shape_pt_sequence,
      :shape_dist_traveled,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:shape_id, :shape_pt_lat, :shape_pt_lon, :shape_pt_sequence, :organization_id, :gtfs_version_id])
    |> validate_number(:shape_pt_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint([:organization_id, :gtfs_version_id, :shape_id, :shape_pt_sequence])
    |> foreign_key_constraint(:organization_id)
  end
end