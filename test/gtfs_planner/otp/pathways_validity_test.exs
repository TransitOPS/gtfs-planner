defmodule GtfsPlanner.Otp.PathwaysValidityTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
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

  test "run_in_session/4 does not fall back to org-only walkability tests" do
    organization = organization_fixture()
    requested_version = gtfs_version_fixture(organization.id)
    other_version = gtfs_version_fixture(organization.id)

    _walkability_test =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: other_version.id
      })

    assert {:error, reason} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               requested_version.id
             )

    assert reason.reason == :no_walkability_tests
    assert reason.organization_id == organization.id
    assert reason.gtfs_version_id == requested_version.id
  end

  test "run_in_session/4 returns no_walkability_tests when only invalid suite cases exist" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _invalid_only_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-missing-from-version"
      })

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

  test "run_in_session/4 sends GraphQL walk plan contract and maps response fields" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    walkability_test =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        expected_traversable: true
      })

    request_fun = fn graphql_url, request_opts ->
      send(self(), {:graphql_request, graphql_url, request_opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => %{"plan" => %{"itineraries" => [%{"duration" => 120, "walkDistance" => 300.5}]}}}
       }}
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

    assert request_opts[:json][:query] =~ "transportModes: [{ mode: WALK }]"
    assert request_opts[:json][:query] =~ "numItineraries: 1"
    assert request_opts[:json][:query] =~ "itineraries"
    assert request_opts[:json][:query] =~ "duration"
    assert request_opts[:json][:query] =~ "walkDistance"
    assert request_opts[:json][:variables]["fromLat"] == 42.3601
    assert request_opts[:json][:variables]["fromLon"] == -71.0589
    assert result.summary.total == 1
    assert result.summary.passed == 1
    assert result.summary.failed == 0
    assert [%{test_case_id: case_id, status: :passed}] = result.cases
    assert case_id == walkability_test.id
    assert result.selected_test_case_ids == [walkability_test.id]
    assert result.suite_meta.total == 1
    assert result.suite_meta.valid == 1
    assert result.suite_meta.invalid == 0
    assert result.suite_meta.ordering == "stop_id ASC, address ASC, id ASC"
  end

  test "run_in_session/4 uses selector output: only valid cases selected and metadata includes invalid cases" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-valid"})

    valid_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-valid",
        address: "Addr valid"
      })

    _invalid_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-missing-from-version",
        address: "Addr invalid"
      })

    request_fun = fn _graphql_url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => %{"plan" => %{"itineraries" => [%{"duration" => 150, "walkDistance" => 250.0}]}}}
       }}
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert result.selected_test_case_ids == [valid_case.id]
    assert result.suite_meta.total == 2
    assert result.suite_meta.valid == 1
    assert result.suite_meta.invalid == 1
    assert result.suite_meta.ordering == "stop_id ASC, address ASC, id ASC"
  end

  test "run_in_session/4 executes all selected cases in deterministic order and does not early exit" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop_1 =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    _stop_2 =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-2", stop_lat: 42.37, stop_lon: -71.06})

    first_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-1",
        address: "A",
        expected_traversable: true
      })

    second_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-2",
        address: "B",
        expected_traversable: true
      })

    request_fun = fn _graphql_url, _request_opts ->
      count = Process.get(:request_count, 0)
      Process.put(:request_count, count + 1)

      case count do
        0 ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" =>
                 %{"plan" => %{"itineraries" => [%{"duration" => 120, "walkDistance" => 200.0}]}}
             }
           }}

        1 ->
          {:ok, %Req.Response{status: 503, body: %{"errors" => ["unavailable"]}}}
      end
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert result.selected_test_case_ids == [first_case.id, second_case.id]
    assert result.summary.total == 2
    assert result.summary.passed == 1
    assert result.summary.failed == 1
    assert result.summary.query_failure == 1
    assert result.summary.scoring_failure == 0
    assert Enum.at(result.cases, 0).test_case_id == first_case.id
    assert Enum.at(result.cases, 0).status == :passed
    assert Enum.at(result.cases, 1).test_case_id == second_case.id
    assert Enum.at(result.cases, 1).status == :failed
    assert Enum.at(result.cases, 1).failure_category == :query_failure
    assert Process.get(:request_count) == 2
  end

  test "run_in_session/4 keeps deterministic order with mixed outcomes and no early exit" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop_1 =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    _stop_2 =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-2", stop_lat: 42.37, stop_lon: -71.06})

    _stop_3 =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-3", stop_lat: 42.38, stop_lon: -71.07})

    first_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-1",
        address: "A",
        expected_traversable: true
      })

    second_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-2",
        address: "B",
        expected_traversable: true,
        expected_max_duration_seconds: 50
      })

    third_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-3",
        address: "C",
        expected_traversable: true
      })

    request_fun = fn _graphql_url, _request_opts ->
      count = Process.get(:request_count, 0)
      Process.put(:request_count, count + 1)

      case count do
        0 ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" =>
                 %{"plan" => %{"itineraries" => [%{"duration" => 120, "walkDistance" => 200.0}]}}
             }
           }}

        1 ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" =>
                 %{"plan" => %{"itineraries" => [%{"duration" => 120, "walkDistance" => 300.0}]}}
             }
           }}

        2 ->
          {:ok, %Req.Response{status: 503, body: %{"errors" => ["unavailable"]}}}
      end
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert result.selected_test_case_ids == [first_case.id, second_case.id, third_case.id]
    assert result.summary.total == 3
    assert result.summary.passed == 1
    assert result.summary.failed == 2
    assert result.summary.scoring_failure == 1
    assert result.summary.query_failure == 1

    assert Enum.at(result.cases, 0).test_case_id == first_case.id
    assert Enum.at(result.cases, 0).status == :passed

    assert Enum.at(result.cases, 1).test_case_id == second_case.id
    assert Enum.at(result.cases, 1).status == :failed
    assert Enum.at(result.cases, 1).failure_category == :scoring_failure

    assert Enum.at(result.cases, 2).test_case_id == third_case.id
    assert Enum.at(result.cases, 2).status == :failed
    assert Enum.at(result.cases, 2).failure_category == :query_failure

    assert Process.get(:request_count) == 3
  end

  test "run_in_session/4 runs wheelchair variant only when expected_wheelchair_accessible is set" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    _walkability_test =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        expected_wheelchair_accessible: true,
        expected_traversable: true
      })

    request_fun = fn _graphql_url, request_opts ->
      send(self(), {:graphql_variables, request_opts[:json][:variables]})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => %{"plan" => %{"itineraries" => [%{"duration" => 100, "walkDistance" => 100.0}]}}}
       }}
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert_receive {:graphql_variables, %{"wheelchair" => nil}}
    assert_receive {:graphql_variables, %{"wheelchair" => true}}
    assert result.summary.total == 1
    assert result.summary.passed == 1
  end

  test "run_in_session/4 skips wheelchair variant when expected_wheelchair_accessible is not set" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    _walkability_test =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        expected_wheelchair_accessible: nil,
        expected_traversable: true
      })

    request_fun = fn _graphql_url, request_opts ->
      send(self(), {:graphql_variables, request_opts[:json][:variables]})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => %{"plan" => %{"itineraries" => [%{"duration" => 100, "walkDistance" => 100.0}]}}}
       }}
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert_receive {:graphql_variables, %{"wheelchair" => nil}}
    refute_receive {:graphql_variables, %{"wheelchair" => true}}
    assert result.summary.total == 1
    assert result.summary.passed == 1
  end

  test "run_in_session/4 attributes transport errors as query_failure" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    walkability_test_fixture(%{
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id,
      expected_traversable: true
    })

    request_fun = fn _graphql_url, _request_opts ->
      {:error, :nxdomain}
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert [%{status: :failed, failure_category: :query_failure, details: details}] = result.cases
    assert details.reason == :transport_error
  end

  test "run_in_session/4 attributes non-2xx GraphQL response as query_failure" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    walkability_test_fixture(%{
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id,
      expected_traversable: true
    })

    request_fun = fn _graphql_url, _request_opts ->
      {:ok, %Req.Response{status: 503, body: %{"errors" => ["unavailable"]}}}
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert [%{status: :failed, failure_category: :query_failure, details: details}] = result.cases
    assert details.reason == :non_2xx_response
    assert details.status == 503
  end

  test "run_in_session/4 attributes malformed graphql payload as query_failure" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    walkability_test_fixture(%{
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id,
      expected_traversable: true
    })

    request_fun = fn _graphql_url, _request_opts ->
      {:ok, %Req.Response{status: 200, body: %{"data" => %{"plan" => %{}}}}}
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert [%{status: :failed, failure_category: :query_failure, details: details}] = result.cases
    assert details.reason == :invalid_graphql_payload
  end

  test "run_in_session/4 attributes expectation mismatches as scoring_failure" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    walkability_test_fixture(%{
      organization_id: organization.id,
      gtfs_version_id: gtfs_version.id,
      expected_max_duration_seconds: 50,
      expected_traversable: true
    })

    request_fun = fn _graphql_url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => %{"plan" => %{"itineraries" => [%{"duration" => 120, "walkDistance" => 300.0}]}}}
       }}
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert [%{status: :failed, failure_category: :scoring_failure, details: details}] = result.cases
    assert Enum.any?(details.mismatches, &(&1.kind == :expected_max_duration_seconds))
  end

  test "run_in_session/4 normalizes route output with explicit keys when no itinerary exists" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    walkability_test =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        expected_traversable: false
      })

    request_fun = fn _graphql_url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => %{"plan" => %{"itineraries" => []}}}
       }}
    end

    assert {:ok, result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun
             )

    assert [case_result] = result.cases
    assert case_result.test_case_id == walkability_test.id
    assert case_result.status == :passed
    assert case_result.route_output == %{route_exists: false, duration_seconds: nil, distance_meters: nil}
  end

  test "run_in_session/4 emits suite progress with running completed/total and finishing/finished phases" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop_1 =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1", stop_lat: 42.36, stop_lon: -71.05})

    _stop_2 =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-2", stop_lat: 42.37, stop_lon: -71.06})

    first_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-1",
        address: "A"
      })

    second_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-2",
        address: "B"
      })

    request_fun = fn _graphql_url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => %{"plan" => %{"itineraries" => []}}}
       }}
    end

    status_callback = fn payload ->
      send(self(), {:suite_status, payload})
    end

    assert {:ok, _result} =
             PathwaysValidity.run_in_session(
               session_fixture(),
               organization.id,
               gtfs_version.id,
               request_fun: request_fun,
               status_callback: status_callback
             )

    assert_receive {:suite_status,
                    %{scope: :suite, phase: :running, completed: 0, total: 2, test_case_id: first_id}}

    assert_receive {:suite_status,
                    %{scope: :suite, phase: :running, completed: 1, total: 2, test_case_id: second_id}}

    assert first_id == first_case.id
    assert second_id == second_case.id

    assert_receive {:suite_status, %{scope: :suite, phase: :finishing, completed: 2, total: 2}}
    assert_receive {:suite_status, %{scope: :suite, phase: :finished, completed: 2, total: 2}}
    refute_receive {:suite_status, _payload}
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
