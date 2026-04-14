defmodule GtfsPlannerWeb.Api.V1.AuthController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Accounts

  @login_floor_ms 800
  @token_ttl_days 60

  @doc "POST /api/v1/auth/login — authenticate and return a session token."
  def login(conn, params) do
    start = System.monotonic_time(:millisecond)

    result = do_login(params)

    elapsed = System.monotonic_time(:millisecond) - start
    remaining = @login_floor_ms - elapsed

    if remaining > 0 do
      Process.sleep(remaining)
    end

    send_login_response(conn, result)
  end

  @doc "DELETE /api/v1/auth/session — revoke the current API session token."
  def logout(conn, _params) do
    token = conn.assigns[:api_session_token]
    Accounts.delete_api_session_token(token)
    json(conn, %{data: %{message: "Logged out."}})
  end

  # -- private ----------------------------------------------------------------

  defp do_login(%{"email" => email, "password" => password})
       when is_binary(email) and is_binary(password) do
    with %{} = user <- Accounts.get_user_by_email_and_password(email, password),
         {:ok, membership} <- first_membership(user) do
      token = Accounts.generate_api_session_token(user)

      expires_at =
        DateTime.utc_now()
        |> DateTime.add(@token_ttl_days * 24 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      {:ok, token, user, membership.organization_id, expires_at}
    else
      nil -> {:error, :invalid_credentials}
      {:error, _} = error -> error
    end
  end

  defp do_login(_params), do: {:error, :bad_request}

  defp first_membership(user) do
    case Accounts.list_user_org_memberships(user.id) do
      [] -> {:error, :no_organization}
      [membership | _] -> {:ok, membership}
    end
  end

  defp send_login_response(conn, {:ok, token, user, organization_id, expires_at}) do
    json(conn, %{
      data: %{
        token: token,
        user: %{id: user.id, email: user.email},
        organization_id: organization_id,
        expires_at: DateTime.to_iso8601(expires_at)
      }
    })
  end

  defp send_login_response(conn, {:error, :invalid_credentials}) do
    conn
    |> put_status(401)
    |> json(%{error: %{code: "invalid_credentials", message: "Invalid email or password."}})
  end

  defp send_login_response(conn, {:error, :no_organization}) do
    conn
    |> put_status(403)
    |> json(%{
      error: %{code: "no_organization", message: "No organization membership found."}
    })
  end

  defp send_login_response(conn, {:error, :bad_request}) do
    conn
    |> put_status(400)
    |> json(%{error: %{code: "bad_request", message: "Email and password are required."}})
  end
end
