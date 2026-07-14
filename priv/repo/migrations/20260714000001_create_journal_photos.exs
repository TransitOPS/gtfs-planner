defmodule GtfsPlanner.Repo.Migrations.CreateJournalPhotos do
  use Ecto.Migration

  def change do
    create table(:journal_photos, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :journal_entry_id,
          references(:journal_entries, type: :binary_id, on_delete: :delete_all),
          null: false

      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :bigint, null: false
      add :sha256, :binary, null: false
      add :width, :integer
      add :height, :integer
      add :captured_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:journal_photos, [:journal_entry_id, :captured_at, :inserted_at, :id],
             name: :journal_photos_entry_order_index
           )

    create constraint(:journal_photos, :journal_photos_content_type_ck,
             check: "content_type IN ('image/jpeg', 'image/png')"
           )

    create constraint(:journal_photos, :journal_photos_byte_size_positive_ck,
             check: "byte_size > 0"
           )

    create constraint(:journal_photos, :journal_photos_dimensions_positive_ck,
             check: "(width IS NULL OR width > 0) AND (height IS NULL OR height > 0)"
           )

    create constraint(:journal_photos, :journal_photos_sha256_length_ck,
             check: "octet_length(sha256) = 32"
           )
  end
end
