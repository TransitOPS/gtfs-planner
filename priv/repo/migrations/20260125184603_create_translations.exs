defmodule GtfsPlanner.Repo.Migrations.CreateTranslations do
  use Ecto.Migration

  def up do
    create table(:translations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, :binary_id, null: false
      add :table_name, :string, null: false
      add :field_name, :string, null: false
      add :language, :string, null: false
      add :translation, :string, null: false
      add :record_id, :string
      add :record_sub_id, :string
      add :field_value, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :translations,
             [
               :organization_id,
               :gtfs_version_id,
               :table_name,
               :field_name,
               :language,
               :record_id,
               :record_sub_id,
               :field_value
             ],
             name: :translations_org_version_table_field_lang_record_index
           )

    create index(:translations, [:organization_id, :gtfs_version_id])
  end

  def down do
    drop table(:translations)
  end
end
