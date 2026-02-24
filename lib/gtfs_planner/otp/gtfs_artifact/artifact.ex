defmodule GtfsPlanner.Otp.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          zip_path: String.t(),
          content_hash: String.t(),
          file_size_bytes: integer(),
          manifest_json: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "otp_gtfs_artifacts" do
    field :zip_path, :string
    field :content_hash, :string
    field :file_size_bytes, :integer
    field :manifest_json, :map

    belongs_to :organization, GtfsPlanner.Organizations.Organization
    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :organization_id,
      :gtfs_version_id,
      :zip_path,
      :content_hash,
      :file_size_bytes,
      :manifest_json
    ])
    |> validate_required([
      :organization_id,
      :gtfs_version_id,
      :zip_path,
      :content_hash,
      :file_size_bytes,
      :manifest_json
    ])
    |> validate_number(:file_size_bytes, greater_than_or_equal_to: 0)
    |> unique_constraint([:organization_id, :gtfs_version_id],
      name: :otp_gtfs_artifacts_org_version_unique_index
    )
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:gtfs_version_id)
  end
end
