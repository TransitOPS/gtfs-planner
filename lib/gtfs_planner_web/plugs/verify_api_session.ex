defmodule GtfsPlannerWeb.Plugs.VerifyApiSession do
  @moduledoc """
  Plug that authenticates API requests using Bearer tokens backed by `UserToken`.

  Extracts the Bearer token from the Authorization header, verifies it via
  `Accounts.get_user_by_api_session_token/1`, and assigns `:current_user`,
  `:current_user_id`, and `:api_session_token` on success. Halts with 401 JSON
  on any failure.
  """

  import Plug.Conn
  alias GtfsPlanner.Accounts

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         %{} = user <- Accounts.get_user_by_api_session_token(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_user_id, user.id)
      |> assign(:api_session_token, token)
    else
      _ -> unauthorized(conn)
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: "unauthorized"}}))
    |> halt()
  end
end
