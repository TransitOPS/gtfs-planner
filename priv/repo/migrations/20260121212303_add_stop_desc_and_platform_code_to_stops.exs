defmodule GtfsPlanner.Repo.Migrations.AddStopDescAndPlatformCodeToStops do
  use Ecto.Migration

  def change do
    alter table(:stops) do
      add :stop_desc, :text
      add :platform_code, :string
    end
  end
end
