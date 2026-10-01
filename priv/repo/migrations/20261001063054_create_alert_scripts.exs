defmodule GtfsPlanner.Repo.Migrations.CreateAlertScripts do
  use Ecto.Migration

  def change do
    create table(:alert_scripts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string
      add :situation, :string
      add :header_template, :string
      add :description_template, :string
      add :position, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:alert_scripts, [:organization_id, :name])
  end
end
