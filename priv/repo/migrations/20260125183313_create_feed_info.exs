defmodule GtfsPlanner.Repo.Migrations.CreateFeedInfo do
  use Ecto.Migration

  def up do
    create table(:feed_info, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :feed_publisher_name, :string, null: false
      add :feed_publisher_url, :string, null: false
      add :feed_lang, :string, null: false
      add :default_lang, :string
      add :feed_start_date, :date
      add :feed_end_date, :date
      add :feed_version, :string
      add :feed_contact_email, :string
      add :feed_contact_url, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:feed_info, [:organization_id, :gtfs_version_id],
             name: :feed_info_organization_id_gtfs_version_id_index
           )
  end

  def down do
    drop table(:feed_info)
  end
end
