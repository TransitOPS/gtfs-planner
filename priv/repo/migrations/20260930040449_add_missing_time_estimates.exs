defmodule GtfsPlanner.Repo.Migrations.AddMissingTimeEstimates do
  use Ecto.Migration

  def change do
    alter table(:export_defaults) do
      add :estimate_missing_times, :boolean, null: false, default: true
      add :estimate_method, :string, null: false, default: "distance"
    end

    create constraint(:export_defaults, :estimate_method,
             check: "estimate_method IN ('distance', 'even')"
           )

    alter table(:gtfs_export_runs) do
      add :estimate_missing_times, :boolean, null: false, default: false
      add :estimate_method, :string
    end
  end
end
