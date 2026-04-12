defmodule GtfsPlanner.Repo.Migrations.AddCompanionFieldsToPathways do
  use Ecto.Migration

  def change do
    alter table(:pathways) do
      add :notes, :text
      add :field_complete, :boolean, default: false, null: false
    end
  end
end
