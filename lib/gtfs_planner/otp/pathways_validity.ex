defmodule GtfsPlanner.Otp.PathwaysValidity do
  @moduledoc """
  Runs deterministic OTP in-session validity checks for pathways validation.
  """

  alias GtfsPlanner.Otp.Runtime.Session
  alias GtfsPlanner.Validations.WalkabilitySuite

  @graphql_query "{__typename}"

  @spec run_in_session(Session.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def run_in_session(%Session{} = session, organization_id, gtfs_version_id, opts \\ []) do
    case WalkabilitySuite.select_suite(organization_id, gtfs_version_id) do
      {:ok, %{suite: []}} ->
        {:error,
         %{
           reason: :no_walkability_tests,
           organization_id: organization_id,
           gtfs_version_id: gtfs_version_id
         }}

      {:ok, %{suite: suite, meta: suite_meta}} ->
        request_fun =
          Keyword.get(opts, :request_fun, fn graphql_url, request_opts ->
            Req.post(Keyword.merge(request_opts, url: graphql_url))
          end)

        request_opts = [json: %{query: @graphql_query}]
        selected_test_case_ids = Enum.map(suite, & &1.test_case_id)

        case request_fun.(session.graphql_url, request_opts) do
          {:ok, %Req.Response{status: status}} when status >= 200 and status < 300 ->
            {:ok,
             %{
               check: :otp_graphql_typename,
               graphql_url: session.graphql_url,
               query: @graphql_query,
               status: status,
               suite_meta: suite_meta,
               selected_test_case_ids: selected_test_case_ids
             }}

          {:ok, %Req.Response{status: status} = response} ->
            {:error,
             %{
               reason: :otp_validity_check_failed,
               check: :otp_graphql_typename,
               graphql_url: session.graphql_url,
               status: status,
               body: response.body,
               suite_meta: suite_meta,
               selected_test_case_ids: selected_test_case_ids
             }}

          {:error, error} ->
            {:error,
             %{
               reason: :otp_validity_check_failed,
               check: :otp_graphql_typename,
               graphql_url: session.graphql_url,
               details: inspect(error),
               suite_meta: suite_meta,
               selected_test_case_ids: selected_test_case_ids
             }}

          unexpected ->
            {:error,
             %{
               reason: :otp_validity_check_failed,
               check: :otp_graphql_typename,
               graphql_url: session.graphql_url,
               details: "Unexpected request result: #{inspect(unexpected)}",
               suite_meta: suite_meta,
               selected_test_case_ids: selected_test_case_ids
             }}
        end
    end
  end
end
