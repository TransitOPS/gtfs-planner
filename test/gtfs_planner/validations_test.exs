defmodule GtfsPlanner.ValidationsTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.WalkabilityTest

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    %{organization: organization, gtfs_version: gtfs_version}
  end

  describe "validation lifecycle" do
    test "creates, runs, completes, and fetches a generic validation run", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:ok, run} =
               Validations.create_validation_run(
                 organization.id,
                 gtfs_version.id,
                 "mobility_data"
               )

      assert run.status == "started"
      assert {:ok, run} = Validations.mark_running(run)
      assert run.status == "running"

      result = %{
        summary: %{errors: 1, warnings: 2, infos: 3},
        notices: [%{"code" => "missing_required_field"}],
        duration_ms: 1500
      }

      assert {:ok, completed_run} = Validations.mark_completed(run, result)
      assert completed_run.status == "completed"
      assert completed_run.errors_count == 1
      assert completed_run.warnings_count == 2
      assert completed_run.infos_count == 3
      assert completed_run.result_json == %{"notices" => result.notices}
      assert completed_run.completed_at

      assert Validations.get_validation_run!(completed_run.id).id == completed_run.id
      assert Validations.get_validation_run(completed_run.id).id == completed_run.id
    end

    test "marks a generic validation run as failed", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:ok, run} =
               Validations.create_validation_run(
                 organization.id,
                 gtfs_version.id,
                 "mobility_data"
               )

      assert {:ok, failed_run} = Validations.mark_failed(run, :validator_crashed)
      assert failed_run.status == "failed"
      assert failed_run.error_details == ":validator_crashed"
      assert failed_run.completed_at
    end

    test "lists runs within the requested organization and version", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:ok, included} =
               Validations.create_validation_run(
                 organization.id,
                 gtfs_version.id,
                 "mobility_data"
               )

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      assert {:ok, _excluded} =
               Validations.create_validation_run(
                 other_organization.id,
                 other_version.id,
                 "mobility_data"
               )

      assert [run] = Validations.list_validation_runs(organization.id, gtfs_version.id)
      assert run.id == included.id
    end

    test "lists only terminal runs in recent history", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:ok, started_run} =
               Validations.create_validation_run(
                 organization.id,
                 gtfs_version.id,
                 "mobility_data"
               )

      assert {:ok, completed_run} =
               organization.id
               |> then(&Validations.create_validation_run(&1, gtfs_version.id, "mobility_data"))
               |> then(fn {:ok, run} -> Validations.mark_completed(run, empty_result()) end)

      assert {:ok, failed_run} =
               organization.id
               |> then(&Validations.create_validation_run(&1, gtfs_version.id, "mobility_data"))
               |> then(fn {:ok, run} -> Validations.mark_failed(run, :failed) end)

      recent_ids =
        Validations.list_recent_validation_runs(organization.id, gtfs_version.id)
        |> Enum.map(& &1.id)

      assert completed_run.id in recent_ids
      assert failed_run.id in recent_ids
      refute started_run.id in recent_ids
    end

    test "rejects an unsupported run type", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      assert {:error, changeset} =
               Validations.create_validation_run(organization.id, gtfs_version.id, "unsupported")

      assert "is invalid" in errors_on(changeset).run_type
    end

    test "returns nil or raises for a missing run" do
      id = Ecto.UUID.generate()
      assert Validations.get_validation_run(id) == nil
      assert_raise Ecto.NoResultsError, fn -> Validations.get_validation_run!(id) end
    end
  end

  describe "walkability test reads" do
    test "lists and fetches tests within their version scope", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      later =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: "stop-b",
          address: "B Street"
        })

      first =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: "stop-a",
          address: "A Street"
        })

      assert Enum.map(
               Validations.list_walkability_tests(organization.id, gtfs_version.id),
               & &1.id
             ) == [
               first.id,
               later.id
             ]

      assert %WalkabilityTest{id: id} = Validations.get_walkability_test(first.id)
      assert id == first.id
      assert Validations.get_walkability_test!(later.id).id == later.id
      assert Validations.get_walkability_test(Ecto.UUID.generate()) == nil
    end

    test "filters tests by requested stop ids", %{
      organization: organization,
      gtfs_version: gtfs_version
    } do
      included =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: "included",
          address: "Included Street"
        })

      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "excluded",
        address: "Excluded Street"
      })

      assert [] =
               Validations.list_walkability_tests_for_stop_ids(
                 organization.id,
                 gtfs_version.id,
                 []
               )

      assert [%{id: id}] =
               Validations.list_walkability_tests_for_stop_ids(organization.id, gtfs_version.id, [
                 "included"
               ])

      assert id == included.id
    end
  end

  defp empty_result do
    %{summary: %{errors: 0, warnings: 0, infos: 0}, notices: [], duration_ms: 0}
  end
end
