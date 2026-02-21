defmodule GtfsPlanner.Otp.PathwaysValidityTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Otp.PathwaysValidity
  alias GtfsPlanner.Otp.Runtime.Session

  test "run_in_session/4 returns deterministic error when no walkability tests exist" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    assert {:error, reason} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id
             )

    assert reason.reason == :no_walkability_tests
    assert reason.organization_id == organization.id
    assert reason.gtfs_version_id == gtfs_version.id
  end

  test "run_in_session/4 returns success map for 2xx GraphQL response" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    _walkability_test = walkability_test_fixture(%{organization_id: organization.id})

    request_fun = fn graphql_url, request_opts ->
      send(self(), {:graphql_request, graphql_url, request_opts})
      {:ok, %Req.Response{status: 200, body: %{"data" => %{"__typename" => "Query"}}}}
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert_receive {:graphql_request, "http://127.0.0.1:8080/otp/routers/default/index/graphql",
                    request_opts}

    assert request_opts[:json] == %{query: "{__typename}"}
    assert result.check == :otp_graphql_typename
    assert result.status == 200
  end

  test "run_in_session/4 returns validity-check error map for non-2xx GraphQL response" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    _walkability_test = walkability_test_fixture(%{organization_id: organization.id})

    request_fun = fn _graphql_url, _request_opts ->
      {:ok, %Req.Response{status: 503, body: %{"errors" => ["unavailable"]}}}
    end

    assert {:error, reason} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert reason.reason == :otp_validity_check_failed
    assert reason.status == 503
    assert reason.check == :otp_graphql_typename
  end

  test "run_in_session/4 returns validity-check error map for transport failure" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    _walkability_test = walkability_test_fixture(%{organization_id: organization.id})

    request_fun = fn _graphql_url, _request_opts ->
      {:error, :nxdomain}
    end

    assert {:error, reason} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert reason.reason == :otp_validity_check_failed
    assert reason.check == :otp_graphql_typename
    assert reason.details =~ ":nxdomain"
  end

  defp session_fixture do
    %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }
  end
end
