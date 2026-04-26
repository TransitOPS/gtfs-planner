defmodule GtfsPlanner.Repo.Migrations.AddAlignmentToStopLevels do
  use Ecto.Migration

  def change do
    alter table(:stop_levels) do
      add :floorplan_center_lat, :float
      add :floorplan_center_lon, :float
      add :floorplan_scale_mpp, :float
      add :floorplan_rotation_deg, :float
    end
  end
end
