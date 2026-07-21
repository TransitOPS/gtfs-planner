defmodule GtfsPlanner.Repo.Migrations.AllowVersionScopedChangeLogs do
  use Ecto.Migration

  def change do
    alter table(:change_logs) do
      modify :station_stop_id, :string, null: true, from: {:string, null: false}
    end
  end
end
