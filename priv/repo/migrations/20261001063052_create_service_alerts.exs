defmodule GtfsPlanner.Repo.Migrations.CreateServiceAlerts do
  use Ecto.Migration

  def change do
    create table(:service_alerts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :gtfs_version_id, references(:gtfs_versions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :revision, :integer, null: false, default: 1
      add :urgency, :string
      add :situation, :string
      add :service_change_kind, :string
      add :effect, :string
      add :cause, :string
      add :cause_detail, :string

      add :scope, :map, null: false, default: %{}
      add :timing, :map, null: false, default: %{}
      add :message, :map, null: false, default: %{}

      add :complete, :boolean, null: false, default: false

      add :first_date, :date
      add :last_date, :date

      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:service_alerts, [:organization_id, :gtfs_version_id, :last_date])

    create constraint(:service_alerts, :service_alerts_revision_positive, check: "revision >= 1")
  end
end
