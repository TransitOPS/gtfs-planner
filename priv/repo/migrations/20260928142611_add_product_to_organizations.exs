defmodule GtfsPlanner.Repo.Migrations.AddProductToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :product, :string, null: false, default: "planner"
    end
  end
end
