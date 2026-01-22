defmodule GtfsPlanner.Repo.Migrations.AddDiagramCoordinateToStops do
  use Ecto.Migration

  def change do
    alter table(:stops) do
      add :diagram_coordinate, :map
    end
  end
end
