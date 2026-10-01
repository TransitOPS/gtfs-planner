defmodule GtfsPlanner.Repo.Migrations.AddAlertAuthoringModeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :alert_authoring_mode, :string, null: false, default: "form"
    end
  end
end
