defmodule GtfsPlanner.Gtfs.JournalPhoto do
  use Ecto.Schema

  import Ecto.Changeset

  @content_types ~w(image/jpeg image/png)
  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          journal_entry_id: Ecto.UUID.t(),
          filename: String.t(),
          content_type: String.t(),
          byte_size: pos_integer(),
          sha256: binary(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          captured_at: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "journal_photos" do
    belongs_to :journal_entry, GtfsPlanner.Gtfs.JournalEntry

    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :sha256, :binary
    field :width, :integer
    field :height, :integer
    field :captured_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(photo, trusted_attrs) do
    photo
    |> cast(trusted_attrs, [
      :id,
      :journal_entry_id,
      :filename,
      :content_type,
      :byte_size,
      :sha256,
      :width,
      :height,
      :captured_at
    ])
    |> validate_required([:id, :journal_entry_id, :filename, :content_type, :byte_size, :sha256, :captured_at])
    |> validate_inclusion(:content_type, @content_types)
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_change(:sha256, fn :sha256, digest ->
      if is_binary(digest) and byte_size(digest) == 32, do: [], else: [sha256: "must be 32 bytes"]
    end)
    |> check_constraint(:content_type, name: :journal_photos_content_type_ck)
    |> check_constraint(:byte_size, name: :journal_photos_byte_size_positive_ck)
    |> check_constraint(:width, name: :journal_photos_dimensions_positive_ck)
    |> check_constraint(:sha256, name: :journal_photos_sha256_length_ck)
    |> foreign_key_constraint(:journal_entry_id)
  end
end
