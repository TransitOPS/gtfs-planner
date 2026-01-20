defmodule GtfsPlanner.Repo.Migrations.AddDeactivatedAtToUserOrgMemberships do
  use Ecto.Migration

  def change do
    alter table(:user_org_memberships) do
      add :deactivated_at, :utc_datetime, null: true, default: nil
    end

    create index(:user_org_memberships, [:organization_id, :deactivated_at])
  end
end