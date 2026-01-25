defmodule GtfsPlanner.Gtfs.FareMedia do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fare_media" do
    field :fare_media_id, :string
    field :fare_media_name, :string
    field :fare_media_type, :integer

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          fare_media_id: String.t(),
          fare_media_name: String.t() | nil,
          fare_media_type: integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a fare media."
  def changeset(fare_media, attrs) do
    fare_media
    |> cast(attrs, [
      :fare_media_id,
      :fare_media_name,
      :fare_media_type,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:fare_media_id, :fare_media_type, :organization_id, :gtfs_version_id])
    |> validate_inclusion(:fare_media_type, 0..4)
    |> unique_constraint([:organization_id, :gtfs_version_id, :fare_media_id])
    |> foreign_key_constraint(:organization_id)
  end
end