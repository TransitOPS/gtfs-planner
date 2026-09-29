defmodule GtfsPlanner.Repo.Migrations.EnablePostgis do
  use Ecto.Migration

  def change do
    # Flex areas, route buffers and Census land boundaries query PostGIS functions.
    execute "CREATE EXTENSION IF NOT EXISTS postgis", "DROP EXTENSION IF EXISTS postgis"
  end
end
