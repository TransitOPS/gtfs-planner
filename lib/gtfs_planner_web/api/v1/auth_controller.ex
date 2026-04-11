defmodule GtfsPlannerWeb.Api.V1.AuthController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Accounts
  alias GtfsPlannerWeb.JWT

  @doc """
  POST /api/v1/auth/login
  Exchanges email + password for a JWT.
  """
  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_status(401)
        |> json(%{error: %{code: "invalid_credentials", message: "Email or password is incorrect."}})

      user ->
        memberships = Accounts.list_user_org_memberships(user.id)

        case memberships do
          [] ->
            conn
            |> put_status(403)
            |> json(%{error: %{code: "no_organization", message: "User has no organization membership."}})

          [membership | _] ->
            case JWT.generate_token(user.id, membership.organization_id) do
              {:ok, token, _claims} ->
                json(conn, %{
                  data: %{
                    token: token,
                    user: %{
                      id: user.id,
                      email: user.email
                    },
                    organization_id: membership.organization_id
                  }
                })

              {:error, _reason} ->
                conn
                |> put_status(500)
                |> json(%{error: %{code: "internal_error", message: "Failed to generate token."}})
            end
        end
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: %{code: "bad_request", message: "Email and password are required."}})
  end

  @doc """
  POST /api/v1/auth/refresh
  Issues a new JWT from a valid existing one.
  """
  def refresh(conn, _params) do
    user_id = conn.assigns[:current_user_id]
    org_id = conn.assigns[:current_organization_id]

    case JWT.generate_token(user_id, org_id) do
      {:ok, token, _claims} ->
        json(conn, %{data: %{token: token}})

      {:error, _reason} ->
        conn
        |> put_status(500)
        |> json(%{error: %{code: "internal_error", message: "Failed to generate token."}})
    end
  end
end
