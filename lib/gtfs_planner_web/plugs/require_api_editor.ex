defmodule GtfsPlannerWeb.Plugs.RequireApiEditor do
  @moduledoc """
  Requires the selected companion-API organization membership to be an editor.

  `AssignApiOrganization` owns membership selection. This plug deliberately
  authorizes only that exact active membership, never a role from another
  organization a user may also belong to.
  """

  @behaviour Plug

  import Plug.Conn

  @editor_role "pathways_studio_editor"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.assigns[:current_organization_membership] do
      %{roles: roles, deactivated_at: nil} when is_list(roles) ->
        if @editor_role in roles do
          conn
        else
          forbidden(conn)
        end

      _ ->
        forbidden(conn)
    end
  end

  defp forbidden(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: %{code: "forbidden"}}))
    |> halt()
  end
end
