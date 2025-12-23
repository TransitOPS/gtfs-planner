defmodule GtfsPlanner.Repo.Migrations.CreateUserOrgMemberships do
  use Ecto.Migration

  def change do
    create table(:user_org_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id), null: false
      add :roles, {:array, :string}, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_org_memberships, [:user_id, :organization_id])
  end
end
