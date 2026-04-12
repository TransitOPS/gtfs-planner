defmodule GtfsPlanner.Repo.Migrations.AddCompanionFieldsToPathways do
  use Ecto.Migration

  def change do
    alter table(:pathways) do
      add :field_notes, :text
      add :field_completed_at, :utc_datetime_usec
    end
  end
end
