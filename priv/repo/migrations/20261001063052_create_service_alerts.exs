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

    # Every table that carries both `organization_id` and `gtfs_version_id` owes
    # the scoped key, so a row cannot name a version of another organization:
    # `GtfsPlanner.Integrity.OwnershipAudit` lists the table and its test checks
    # this constraint by name. It is validated rather than `NOT VALID` because
    # the table is created here and has no retained rows. The single-column
    # cascade key above stays; this one is `NO ACTION`.
    execute(
      """
      ALTER TABLE #{qualified_table(:service_alerts)}
      ADD CONSTRAINT service_alerts_version_owner_fkey
      FOREIGN KEY (gtfs_version_id, organization_id)
      REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
      ON DELETE NO ACTION
      """,
      """
      ALTER TABLE #{qualified_table(:service_alerts)}
      DROP CONSTRAINT service_alerts_version_owner_fkey
      """
    )
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{String.replace(schema, "\"", "\"\"")}".#{table})
    end
  end
end
