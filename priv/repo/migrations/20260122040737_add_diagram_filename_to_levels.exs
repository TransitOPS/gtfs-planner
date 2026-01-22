defmodule GtfsPlanner.Repo.Migrations.AddDiagramFilenameToLevels do
  use Ecto.Migration

  def change do
    alter table(:levels) do
      add :diagram_filename, :string
    end
  end
end
