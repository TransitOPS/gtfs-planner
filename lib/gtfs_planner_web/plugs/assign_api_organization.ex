defmodule GtfsPlannerWeb.Plugs.AssignApiOrganization do
  @moduledoc """
  Plug to resolve and assign the current organization for API requests.

  Reads `X-Organization-Id` header. If present, verifies the authenticated user
  has a membership in that organization and assigns `:current_organization_id`.
  If absent, falls back to the user's sole membership when they belong to exactly
  one organization. Multi-org users without the header receive a 403 listing
  available org IDs. Users with no memberships receive a 403.

  This plug expects `:current_user` to already be assigned on the conn
  (by `VerifyApiSession`). It only handles organization resolution.
  """

  import Plug.Conn
  alias GtfsPlanner.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{code: "unauthorized"}}))
        |> halt()

      user ->
        memberships = Accounts.list_user_org_memberships(user.id)

        case get_req_header(conn, "x-organization-id") do
          [org_id | _] ->
            resolve_with_header(conn, memberships, org_id)

          [] ->
            resolve_without_header(conn, memberships)
        end
    end
  end

  defp resolve_with_header(conn, memberships, org_id) do
    case Ecto.UUID.cast(org_id) do
      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            error: %{
              code: "bad_request",
              message: "X-Organization-Id must be a valid UUID."
            }
          })
        )
        |> halt()

      {:ok, _} ->
        resolve_valid_org_id(conn, memberships, org_id)
    end
  end

  defp resolve_valid_org_id(conn, memberships, org_id) do
    if Enum.any?(memberships, fn m -> m.organization_id == org_id end) do
      assign(conn, :current_organization_id, org_id)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{
          error: %{
            code: "forbidden",
            message: "You do not have access to this organization."
          }
        })
      )
      |> halt()
    end
  end

  defp resolve_without_header(conn, memberships) do
    case memberships do
      [single] ->
        assign(conn, :current_organization_id, single.organization_id)

      [] ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          403,
          Jason.encode!(%{
            error: %{
              code: "no_organization",
              message: "You do not belong to any organization."
            }
          })
        )
        |> halt()

      multiple ->
        org_ids = Enum.map(multiple, & &1.organization_id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          403,
          Jason.encode!(%{
            error: %{
              code: "organization_required",
              message: "Multiple organizations available. Set the X-Organization-Id header.",
              available_organization_ids: org_ids
            }
          })
        )
        |> halt()
    end
  end
end
