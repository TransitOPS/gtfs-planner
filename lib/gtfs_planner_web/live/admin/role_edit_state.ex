defmodule GtfsPlannerWeb.Admin.RoleEditState do
  @moduledoc """
  The Edit roles drawer's state and command, shared by the administration
  LiveViews that render `GtfsPlannerWeb.Admin.Components.roles_form/1`.

  The drawer offers only the organization access levels an invitation can
  grant. Any other role the member holds, such as the system `administrator`
  role, is kept as it is, so saving the drawer never grants or removes it.

  The browser only submits checkbox values. The member being edited is the
  server-resolved `:role_edit` assign, which the parent resolves again inside
  the organization before calling `save/4`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias GtfsPlanner.Organizations
  alias GtfsPlannerWeb.Admin.Components

  @doc """
  Opens the drawer for a resolved member, preselecting their access levels.
  Closing it returns focus to that member's Edit roles button.
  """
  def open(socket, member) do
    socket
    |> assign(:role_edit_return_focus_id, "edit-roles-#{member.user.id}")
    |> assign(:role_edit, %{
      member: member,
      selected: Enum.filter(member.roles, &(&1 in editable_roles())),
      error: nil,
      refusal: nil
    })
  end

  @doc "Closes the drawer."
  def close(socket), do: assign(socket, :role_edit, nil)

  @doc """
  Saves the submitted access levels for `member` in `organization_id`.

  Returns `{:ok, membership}` when saved, `{:error, socket}` with the drawer
  still open and the reason shown in it, or `{:error, :not_found}` when the
  member is no longer in the organization.
  """
  def save(socket, member, organization_id, params) do
    selected = selected_roles(params)
    kept = Enum.reject(member.roles, &(&1 in editable_roles()))
    roles = kept ++ selected

    if roles == [] do
      {:error, put_draft(socket, member, selected, error: "Choose at least one access level.")}
    else
      case Organizations.update_user_roles(
             socket.assigns.current_user,
             member.user.id,
             organization_id,
             roles
           ) do
        {:ok, membership} ->
          {:ok, membership}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error,
           put_draft(socket, member, selected,
             refusal: Components.role_change_refusal(reason, member.user.email)
           )}
      end
    end
  end

  @doc """
  The two lines of the message that reports saved roles. Granting leaves the
  person's sessions alone; removing a role signs them out everywhere.
  """
  def saved_feedback(member, membership, current_user) do
    removed? = Enum.any?(member.roles, &(&1 not in membership.roles))
    title = "#{member.user.email} now has #{Components.role_list(membership.roles)}."

    detail =
      cond do
        removed? -> "They were signed out of every session and sign in again with the new access."
        member.user.id == current_user.id -> "Your new access applies now."
        true -> "They get the new access on the next page they open."
      end

    {title, detail}
  end

  defp put_draft(socket, member, selected, opts) do
    assign(socket, :role_edit, %{
      member: member,
      selected: selected,
      error: opts[:error],
      refusal: opts[:refusal]
    })
  end

  # Unchecked boxes submit nothing, so the key may be missing.
  defp selected_roles(params) do
    case get_in(params, ["member_roles", "roles"]) do
      roles when is_list(roles) -> Enum.filter(editable_roles(), &(&1 in roles))
      _missing -> []
    end
  end

  defp editable_roles, do: Enum.map(Components.access_levels(), & &1.value)
end
