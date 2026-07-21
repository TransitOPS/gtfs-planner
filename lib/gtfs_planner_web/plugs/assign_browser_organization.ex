defmodule GtfsPlannerWeb.Plugs.AssignBrowserOrganization do
  @moduledoc """
  Assigns the active browser-session organization for scoped HTTP endpoints.

  A browser session supplies the organization identifier, but the assignment is
  only usable while the current user has an active membership in that
  organization. Role enforcement stays with `GtfsPlannerWeb.EnsureRole`.
  """

  import Plug.Conn

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Organizations

  def init(opts), do: opts

  def call(conn, _opts) do
    case {conn.assigns[:current_user], get_session(conn, :organization_id)} do
      {%{id: user_id}, organization_id} when is_binary(organization_id) ->
        assign_active_organization(conn, user_id, organization_id)

      _ ->
        conn
    end
  end

  defp assign_active_organization(conn, user_id, organization_id) do
    with {:ok, organization_id} <- Ecto.UUID.cast(organization_id),
         organization when not is_nil(organization) <-
           Organizations.get_organization(organization_id),
         %{deactivated_at: nil} <- Accounts.get_user_org_membership(user_id, organization_id) do
      assign(conn, :current_organization, organization)
    else
      _ -> conn
    end
  end
end
