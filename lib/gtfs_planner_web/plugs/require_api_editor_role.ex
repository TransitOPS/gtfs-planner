defmodule GtfsPlannerWeb.Plugs.RequireApiEditorRole do
  @moduledoc """
  Requires the `pathways_studio_editor` role on the user's membership in the
  resolved organization — the API counterpart of the desktop's
  `EnsureRole :require_gtfs_access` mount, for API routes that write GTFS
  data (e.g. the level alignment endpoint, which rewrites child stop
  coordinates).

  Expects `:current_user` (VerifyApiSession) and `:current_organization_id`
  (AssignApiOrganization) to already be assigned.
  """

  import Plug.Conn
  alias GtfsPlanner.Accounts

  @required_role "pathways_studio_editor"

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns[:current_user]
    org_id = conn.assigns[:current_organization_id]

    membership =
      user
      |> then(&Accounts.list_user_org_memberships(&1.id))
      |> Enum.find(&(&1.organization_id == org_id))

    if membership != nil and @required_role in (membership.roles || []) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{
          error: %{
            code: "forbidden",
            message: "This action requires the #{@required_role} role."
          }
        })
      )
      |> halt()
    end
  end
end
