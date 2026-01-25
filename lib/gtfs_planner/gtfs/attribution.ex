defmodule GtfsPlanner.Gtfs.Attribution do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "attributions" do
    field :attribution_id, :string
    field :agency_id, :string
    field :route_id, :string
    field :trip_id, :string
    field :organization_name, :string
    field :is_producer, :integer
    field :is_operator, :integer
    field :is_authority, :integer
    field :attribution_url, :string
    field :attribution_email, :string
    field :attribution_phone, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          attribution_id: String.t() | nil,
          agency_id: String.t() | nil,
          route_id: String.t() | nil,
          trip_id: String.t() | nil,
          organization_name: String.t(),
          is_producer: integer() | nil,
          is_operator: integer() | nil,
          is_authority: integer() | nil,
          attribution_url: String.t() | nil,
          attribution_email: String.t() | nil,
          attribution_phone: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for an attribution."
  def changeset(attribution, attrs) do
    attribution
    |> cast(attrs, [
      :attribution_id,
      :agency_id,
      :route_id,
      :trip_id,
      :organization_name,
      :is_producer,
      :is_operator,
      :is_authority,
      :attribution_url,
      :attribution_email,
      :attribution_phone,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([:organization_name, :organization_id, :gtfs_version_id])
    |> unique_constraint([:organization_id, :gtfs_version_id, :attribution_id])
    |> foreign_key_constraint(:organization_id)
  end
end