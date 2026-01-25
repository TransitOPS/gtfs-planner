defmodule GtfsPlanner.Gtfs.Agency do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agencies" do
    field :agency_id, :string
    field :agency_name, :string
    field :agency_url, :string
    field :agency_timezone, :string
    field :agency_lang, :string
    field :agency_phone, :string
    field :agency_fare_url, :string
    field :agency_email, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          agency_id: String.t() | nil,
          agency_name: String.t(),
          agency_url: String.t(),
          agency_timezone: String.t(),
          agency_lang: String.t() | nil,
          agency_phone: String.t() | nil,
          agency_fare_url: String.t() | nil,
          agency_email: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for an agency."
  def changeset(agency, attrs) do
    agency
    |> cast(attrs, [
      :agency_id,
      :agency_name,
      :agency_url,
      :agency_timezone,
      :agency_lang,
      :agency_phone,
      :agency_fare_url,
      :agency_email,
      :organization_id,
      :gtfs_version_id
    ])
    |> validate_required([
      :agency_name,
      :agency_url,
      :agency_timezone,
      :organization_id,
      :gtfs_version_id
    ])
    |> unique_constraint([:organization_id, :gtfs_version_id, :agency_id])
    |> foreign_key_constraint(:organization_id)
  end
end
