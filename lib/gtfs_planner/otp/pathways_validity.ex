defmodule GtfsPlanner.Otp.PathwaysValidity do
  @moduledoc """
  Runs deterministic OTP in-session validity checks for pathways validation.
  """

  alias GtfsPlanner.Otp.Runtime.Session
  alias GtfsPlanner.Validations

  @graphql_query "{__typename}"

  @spec run_in_session(Session.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def run_in_session(%Session{} = session, organization_id, gtfs_version_id, opts \\ []) do
    if Validations.list_walkability_tests(organization_id) == [] do
      {:error,
       %{
         reason: :no_walkability_tests,
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id
       }}
    else
      request_fun =
        Keyword.get(opts, :request_fun, fn graphql_url, request_opts ->
          Req.post(Keyword.merge(request_opts, url: graphql_url))
        end)

      request_opts = [json: %{query: @graphql_query}]

      case request_fun.(session.graphql_url, request_opts) do
        {:ok, %Req.Response{status: status}} when status >= 200 and status < 300 ->
          {:ok,
           %{
             check: :otp_graphql_typename,
             graphql_url: session.graphql_url,
             query: @graphql_query,
             status: status
           }}

        {:ok, %Req.Response{status: status} = response} ->
          {:error,
           %{
             reason: :otp_validity_check_failed,
             check: :otp_graphql_typename,
             graphql_url: session.graphql_url,
             status: status,
             body: response.body
           }}

        {:error, error} ->
          {:error,
           %{
             reason: :otp_validity_check_failed,
             check: :otp_graphql_typename,
             graphql_url: session.graphql_url,
             details: inspect(error)
           }}

        unexpected ->
          {:error,
           %{
             reason: :otp_validity_check_failed,
             check: :otp_graphql_typename,
             graphql_url: session.graphql_url,
             details: "Unexpected request result: #{inspect(unexpected)}"
           }}
      end
    end
  end
end
