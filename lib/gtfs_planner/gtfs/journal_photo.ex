defmodule GtfsPlanner.Gtfs.JournalPhoto do
  @moduledoc """
  A photo belonging to a station-journal entry. The binary is stored under
  `/uploads/field-captures/...` and served as a static URL (like floorplans);
  this row is the metadata. See the companion app's `specs/api/station-journal.md`.

  `id` is client-generated (the upload idempotency key).
  """
  use Ecto.Schema
  import Ecto.Changeset
  import GtfsPlanner.ChangesetHelpers

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          journal_entry_id: Ecto.UUID.t(),
          filename: String.t(),
          content_type: String.t(),
          byte_size: integer() | nil,
          width: integer() | nil,
          height: integer() | nil,
          captured_at: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "journal_photos" do
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :captured_at, :utc_datetime_usec

    belongs_to :organization, GtfsPlanner.Organizations.Organization,
      foreign_key: :organization_id

    belongs_to :gtfs_version, GtfsPlanner.Versions.GtfsVersion
    belongs_to :journal_entry, GtfsPlanner.Gtfs.JournalEntry

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(photo, attrs) do
    photo
    |> cast(attrs, [
      :id,
      :organization_id,
      :gtfs_version_id,
      :journal_entry_id,
      :filename,
      :content_type,
      :byte_size,
      :width,
      :height,
      :captured_at
    ])
    |> trim_string_fields()
    |> validate_required([
      :id,
      :organization_id,
      :gtfs_version_id,
      :journal_entry_id,
      :filename,
      :content_type,
      :captured_at
    ])
    |> foreign_key_constraint(:journal_entry_id)
    |> foreign_key_constraint(:organization_id)
  end
end
