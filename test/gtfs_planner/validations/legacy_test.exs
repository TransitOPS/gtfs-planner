defmodule GtfsPlanner.Validations.LegacyTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.{Legacy, ValidationRun, WalkabilityTestRunResult}

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    %{organization: organization, gtfs_version: gtfs_version}
  end

  test "recognizes only validation runs without an engine", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    assert {:ok, legacy_run} =
             Validations.create_validation_run(organization.id, gtfs_version.id, "pathways_tests")

    router_run =
      %ValidationRun{organization_id: organization.id, gtfs_version_id: gtfs_version.id}
      |> ValidationRun.changeset(%{
        run_type: "station_reachability",
        status: "completed",
        engine: "pathways_router",
        result_schema_version: 1,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert Legacy.legacy_station_run?(legacy_run)
    refute Legacy.legacy_station_run?(router_run)
  end

  test "lists legacy result rows by case order and preloads their tests", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    assert {:ok, run} =
             Validations.create_validation_run(organization.id, gtfs_version.id, "pathways_tests")

    first_test =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "FIRST",
        address: "1 First Street"
      })

    second_test =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "SECOND",
        address: "2 Second Street"
      })

    insert_result(run.id, second_test.id, 2)
    insert_result(run.id, first_test.id, 0)

    assert [%{order_index: 0, walkability_test: %{stop_id: "FIRST"}}, %{order_index: 2}] =
             Legacy.list_run_results(run.id)
  end

  test "lists only the requested organization and version's legacy tests", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    included =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "INCLUDED",
        address: "Included address"
      })

    other_version = gtfs_version_fixture(organization.id)

    walkability_test_fixture(%{
      organization_id: organization.id,
      gtfs_version_id: other_version.id,
      stop_id: "OTHER_VERSION",
      address: "Other version address"
    })

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)

    walkability_test_fixture(%{
      organization_id: other_organization.id,
      gtfs_version_id: other_version.id,
      stop_id: "OTHER_ORGANIZATION",
      address: "Other organization address"
    })

    assert [%{id: included_id}] = Legacy.list_tests_for_version(organization.id, gtfs_version.id)
    assert included_id == included.id
  end

  defp insert_result(run_id, walkability_test_id, order_index) do
    %WalkabilityTestRunResult{}
    |> WalkabilityTestRunResult.changeset(%{
      validation_run_id: run_id,
      walkability_test_id: walkability_test_id,
      order_index: order_index,
      status: "passed"
    })
    |> Repo.insert!()
  end
end
