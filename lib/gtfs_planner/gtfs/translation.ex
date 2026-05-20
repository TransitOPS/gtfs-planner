defmodule GtfsPlanner.Gtfs.Translation do
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "translations" do
    field :table_name, :string
    field :field_name, :string
    field :language, :string
    field :translation, :string
    field :record_id, :string
    field :record_sub_id, :string
    field :field_value, :string

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    field :gtfs_version_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          table_name: String.t(),
          field_name: String.t(),
          language: String.t(),
          translation: String.t(),
          record_id: String.t() | nil,
          record_sub_id: String.t() | nil,
          field_value: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Creates a changeset for a translation."
  def changeset(translation, attrs) do
    translation
    |> cast(attrs, [
      :table_name,
      :field_name,
      :language,
      :translation,
      :record_id,
      :record_sub_id,
      :field_value,
      :organization_id,
      :gtfs_version_id
    ])
    |> trim_string_fields()
    |> validate_required([
      :table_name,
      :field_name,
      :language,
      :translation,
      :organization_id,
      :gtfs_version_id
    ])
    |> unique_constraint([
      :organization_id,
      :gtfs_version_id,
      :table_name,
      :field_name,
      :language,
      :record_id,
      :record_sub_id,
      :field_value
    ])
    |> foreign_key_constraint(:organization_id)
  end
end
