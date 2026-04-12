defmodule GtfsPlanner.Repo.Migrations.AddCompanionFieldsToPathways do
  use Ecto.Migration

  def change do
    alter table(:pathways) do
      add :field_notes, :text
    end
  end
end
