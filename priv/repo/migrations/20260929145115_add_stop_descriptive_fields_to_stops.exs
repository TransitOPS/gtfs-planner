defmodule GtfsPlanner.Repo.Migrations.AddStopDescriptiveFieldsToStops do
  use Ecto.Migration

  def change do
    alter table(:stops) do
      add :stop_code, :string
      add :tts_stop_name, :string
      # GTFS sets no length limit on a URL, so a varchar(255) column could fail a
      # whole import batch on one long stop_url.
      add :stop_url, :text
      add :stop_timezone, :string
    end
  end
end
