defmodule GtfsPlanner.Organizations.AdminReadAdapter.Repo do
  @moduledoc """
  Production `GtfsPlanner.Organizations.AdminReadAdapter` implementation.

  It reuses the queries the administration screens already read through and adds
  only outcome classification. A missing organization becomes `{:error, :not_found}`.
  A lost database connection becomes `{:error, :unavailable}`. Nothing else is
  rescued, so a malformed id, a bad query, or any other defect still raises.
  """

  @behaviour GtfsPlanner.Organizations.AdminReadAdapter

  import Ecto.Query, warn: false

  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @impl true
  def list_organizations do
    run(fn -> Repo.all(Organization) end)
  end

  @impl true
  def fetch_organization(id) do
    case run(fn -> Repo.get(Organization, id) end) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %Organization{} = organization} -> {:ok, organization}
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def list_users(organization_id) do
    run(fn ->
      from(u in User,
        join: m in UserOrgMembership,
        on: m.user_id == u.id,
        where: m.organization_id == ^organization_id,
        select: %{user: u, roles: m.roles, deactivated_at: m.deactivated_at},
        order_by: [asc: u.email]
      )
      |> Repo.all()
    end)
  end

  # Wraps query execution only. `DBConnection.ConnectionError` is the single
  # recoverable operational failure; every other exception propagates so a code
  # defect can never be reported to an operator as downtime.
  defp run(query) do
    {:ok, query.()}
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end
end
