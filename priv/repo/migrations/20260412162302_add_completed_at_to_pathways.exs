defmodule GtfsPlanner.Repo.Migrations.AddCompletedAtToPathways do
  use Ecto.Migration

  def change do
    alter table(:pathways) do
      add :field_completed_at, :utc_datetime_usec
    end
  end
end
