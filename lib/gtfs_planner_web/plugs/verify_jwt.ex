defmodule GtfsPlannerWeb.Plugs.VerifyJWT do
  @moduledoc """
  Plug that extracts and verifies a JWT from the Authorization header.
  On success, assigns :current_user_id and :current_organization_id to the conn.
  On failure, halts with 401.
  """

  import Plug.Conn
  alias GtfsPlannerWeb.JWT

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, claims} <- JWT.verify_token(token) do
      conn
      |> assign(:current_user_id, claims["sub"])
      |> assign(:current_organization_id, claims["org"])
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{code: "unauthorized", message: "Invalid or missing token."}}))
        |> halt()
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end
