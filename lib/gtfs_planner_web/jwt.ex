defmodule GtfsPlannerWeb.JWT do
  @moduledoc """
  JWT token generation and verification for the companion app API.
  Uses HS256 with the application's secret_key_base.
  """

  use Joken.Config

  @token_ttl 24 * 60 * 60  # 24 hours in seconds

  @impl true
  def token_config do
    default_claims(default_exp: @token_ttl)
  end

  @doc """
  Generates a JWT for the given user and organization.
  """
  def generate_token(user_id, organization_id) do
    claims = %{
      "sub" => user_id,
      "org" => organization_id
    }

    generate_and_sign(claims, signer())
  end

  @doc """
  Verifies a JWT and returns the claims.
  """
  def verify_token(token) do
    verify_and_validate(token, signer())
  end

  defp signer do
    secret = Application.fetch_env!(:gtfs_planner, GtfsPlannerWeb.Endpoint)[:secret_key_base]
    Joken.Signer.create("HS256", secret)
  end
end
