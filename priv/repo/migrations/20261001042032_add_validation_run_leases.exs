defmodule GtfsPlanner.Repo.Migrations.AddValidationRunLeases do
  use Ecto.Migration

  # Both columns are nullable with no default, so the add is a catalog-only change that
  # leaves every existing row's lease empty and keeps the previous release working.
  def change do
    alter table(:gtfs_validation_runs) do
      add :lease_token, :binary_id
      add :lease_expires_at, :utc_datetime_usec
    end
  end
end
