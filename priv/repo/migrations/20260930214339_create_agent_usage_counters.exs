defmodule GtfsPlanner.Repo.Migrations.CreateAgentUsageCounters do
  use Ecto.Migration

  def change do
    create table(:agent_usage_counters, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope_key, :text, null: false
      add :day, :date, null: false
      add :attempts, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:agent_usage_counters, :agent_usage_counters_attempts_check,
             check: "attempts >= 0"
           )

    create unique_index(:agent_usage_counters, [:organization_id, :scope_key, :day],
             name: :agent_usage_counters_org_scope_day_index
           )
  end
end
