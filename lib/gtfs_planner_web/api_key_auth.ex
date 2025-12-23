defmodule GtfsPlannerWeb.ApiKeyAuth do
  @moduledoc """
  Authentication module for API key-based access.

  This module provides Plug functions for authenticating API requests using
  bearer tokens in the Authorization header. It supports RFC 6750 compliant
  format with a compatibility mode.

  ## Authentication Methods

  - RFC 6750 compliant: `Authorization: Bearer GtfsPlanner.V1.abcdefg`
  - Compatibility mode: `Authorization: GtfsPlanner.V1.abcdefg`

  ## Security Features

  - Constant-time token comparison to prevent timing attacks
  - Random delays (500-800ms) on failed authentication to prevent enumeration
  - Organization-scoped access control via API keys
  """

  import Plug.Conn
  alias GtfsPlanner.Organizations

  @doc """
  Fetches and validates the API key from the Authorization header.

  Extracts the API key token from the Authorization header, validates it,
  and assigns the `current_api_key` to the connection if valid.

  ## Examples

      pipe_through [:fetch_current_api_key]
  """
  def fetch_current_api_key(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, api_key} <- Organizations.get_api_key_by_token(token) do
      assign(conn, :current_api_key, api_key)
    else
      _ -> conn
    end
  end

  @doc """
  Requires API key authentication for the request.

  Halts the connection and returns a 401 Unauthorized response if no valid
  API key is present in the connection assigns.

  ## Examples

      pipe_through [:fetch_current_api_key, :require_authenticated_api_key]
  """
  def require_authenticated_api_key(conn, _opts) do
    if conn.assigns[:current_api_key] do
      conn
    else
      # Add random delay to prevent enumeration attacks
      Process.sleep(Enum.random(500..800))

      conn
      |> put_status(:unauthorized)
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{error: "Unauthorized", message: "Invalid or missing API key"}))
      |> halt()
    end
  end

  # Private helper functions

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      [auth_header] ->
        parse_auth_header(auth_header)

      [] ->
        {:error, :missing}
    end
  end

  defp parse_auth_header("Bearer " <> token) do
    {:ok, token}
  end

  defp parse_auth_header(token) when is_binary(token) do
    # Compatibility mode: accept tokens without "Bearer " prefix
    {:ok, token}
  end

  defp parse_auth_header(_), do: {:error, :invalid}
end
