defmodule GtfsPlannerWeb.LiveHelpers do
  @moduledoc """
  Shared helper functions for LiveViews.
  """

  alias GtfsPlanner.Accounts.UserOrgMembership

  @doc """
  Retrieves the roles for the current user in the current organization.

  ## Parameters
    - socket: The LiveView socket with `:current_user` and `:current_organization` assigns

  ## Returns
    - A list of role atoms if the user has a membership in the organization
    - An empty list if no membership is found

  ## Examples

      iex> get_user_roles(socket)
      [:pathways_studio_editor, :pathways_studio_viewer]

      iex> get_user_roles(socket)
      []
  """
  @spec get_user_roles(Phoenix.LiveView.Socket.t()) :: [atom()]
  def get_user_roles(socket) do
    user = socket.assigns[:current_user]
    organization = socket.assigns[:current_organization]

    case GtfsPlanner.Accounts.get_user_org_membership(user.id, organization.id) do
      %UserOrgMembership{roles: roles} when is_list(roles) -> roles
      _ -> []
    end
  end
end
