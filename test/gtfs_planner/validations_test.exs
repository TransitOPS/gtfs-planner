defmodule GtfsPlanner.ValidationsTest do
  use GtfsPlanner.DataCase

  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.WalkabilityTest

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "validation_runs" do
    setup do
      organization = organization_fixture()
      gtfs_version = gtfs_version_fixture(organization.id)
      %{organization: organization, gtfs_version: gtfs_version}
    end

    test "create_validation_run/3 creates a record with status started", %{
      organization: org,
      gtfs_version: version
    } do
      assert {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      assert run.organization_id == org.id
      assert run.gtfs_version_id == version.id
      assert run.run_type == "mobility_data"
      assert run.status == "started"
      assert run.errors_count == 0
      assert run.warnings_count == 0
      assert run.infos_count == 0
      assert run.started_at != nil
      assert run.completed_at == nil
      assert run.result_json == nil
      assert run.error_details == nil
    end

    test "create_validation_run/3 returns error with invalid organization_id" do
      invalid_org_id = Ecto.UUID.generate()
      invalid_version_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Validations.create_validation_run(
                 invalid_org_id,
                 invalid_version_id,
                 "mobility_data"
               )

      # Foreign key constraint error
      assert changeset.errors != []
    end

    test "mark_running/1 updates status to running", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")
      assert run.status == "started"

      assert {:ok, updated_run} = Validations.mark_running(run)
      assert updated_run.status == "running"
      assert updated_run.id == run.id
    end

    test "mark_completed/2 stores result_json and counts", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      result = %{
        summary: %{
          errors: 5,
          warnings: 10,
          infos: 3
        },
        notices: [
          %{
            "code" => "missing_required_field",
            "severity" => "error",
            "totalNotices" => 5,
            "notices" => []
          }
        ],
        duration_ms: 1500
      }

      assert {:ok, completed_run} = Validations.mark_completed(run, result)
      assert completed_run.status == "completed"
      assert completed_run.errors_count == 5
      assert completed_run.warnings_count == 10
      assert completed_run.infos_count == 3
      assert completed_run.duration_ms == 1500
      assert completed_run.result_json != nil
      assert completed_run.result_json["notices"] != nil
      assert completed_run.completed_at != nil
    end

    test "mark_failed/2 stores error_details", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      error_reason = %RuntimeError{message: "Validation process crashed"}

      assert {:ok, failed_run} = Validations.mark_failed(run, error_reason)
      assert failed_run.status == "failed"
      assert failed_run.error_details != nil
      assert failed_run.error_details =~ "RuntimeError"
      assert failed_run.completed_at != nil
    end

    test "get_validation_run!/1 returns the run with given id", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      fetched_run = Validations.get_validation_run!(run.id)
      assert fetched_run.id == run.id
      assert fetched_run.organization_id == org.id
      assert fetched_run.gtfs_version_id == version.id
    end

    test "get_validation_run!/1 raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Validations.get_validation_run!(Ecto.UUID.generate())
      end
    end

    test "get_validation_run/1 returns nil for non-existent id" do
      assert Validations.get_validation_run(Ecto.UUID.generate()) == nil
    end

    test "list_validation_runs/2 returns runs ordered by started_at desc", %{
      organization: org,
      gtfs_version: version
    } do
      # Create runs with different timestamps
      {:ok, run1} = Validations.create_validation_run(org.id, version.id, "mobility_data")
      Process.sleep(10)
      {:ok, run2} = Validations.create_validation_run(org.id, version.id, "mobility_data")
      Process.sleep(10)
      {:ok, run3} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      runs = Validations.list_validation_runs(org.id, version.id)

      # Should be ordered by started_at descending (newest first)
      assert length(runs) == 3
      assert Enum.map(runs, & &1.id) == [run3.id, run2.id, run1.id]
    end

    test "list_validation_runs/2 filters by organization and version", %{
      organization: org,
      gtfs_version: version
    } do
      {:ok, run1} = Validations.create_validation_run(org.id, version.id, "mobility_data")

      # Create another org and version
      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      {:ok, _run2} =
        Validations.create_validation_run(other_org.id, other_version.id, "mobility_data")

      # Create another version for the same org
      another_version = gtfs_version_fixture(org.id)

      {:ok, _run3} =
        Validations.create_validation_run(org.id, another_version.id, "mobility_data")

      runs = Validations.list_validation_runs(org.id, version.id)

      # Should only return runs for this specific org and version
      assert length(runs) == 1
      assert hd(runs).id == run1.id
      assert Enum.all?(runs, fn r -> r.organization_id == org.id end)
      assert Enum.all?(runs, fn r -> r.gtfs_version_id == version.id end)
    end

    test "list_validation_runs/2 limits results to 20", %{
      organization: org,
      gtfs_version: version
    } do
      # Create 25 validation runs
      for _ <- 1..25 do
        {:ok, _run} = Validations.create_validation_run(org.id, version.id, "mobility_data")
      end

      runs = Validations.list_validation_runs(org.id, version.id)

      # Should limit to 20 results
      assert length(runs) == 20
    end
  end

  describe "walkability_tests" do
    setup do
      organization = organization_fixture()
      %{organization: organization}
    end

    test "create_walkability_test/2 creates with valid attrs", %{organization: org} do
      attrs = %{
        stop_id: "stop-1",
        address: "123 Main St",
        address_lat: Decimal.new("42.3601"),
        address_lon: Decimal.new("-71.0589")
      }

      assert {:ok, %WalkabilityTest{} = walkability_test} =
               Validations.create_walkability_test(org.id, attrs)

      assert walkability_test.organization_id == org.id
      assert walkability_test.stop_id == "stop-1"
      assert walkability_test.address == "123 Main St"
      assert walkability_test.address_lat == Decimal.new("42.3601")
      assert walkability_test.address_lon == Decimal.new("-71.0589")
    end

    test "create_walkability_test/2 returns error with missing required field", %{
      organization: org
    } do
      assert {:error, changeset} = Validations.create_walkability_test(org.id, %{})

      assert %{
               stop_id: ["can't be blank"],
               address: ["can't be blank"],
               address_lat: ["can't be blank"],
               address_lon: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "create_walkability_test/2 returns error for duplicate (org_id, stop_id, address)", %{
      organization: org
    } do
      walkability_test_fixture(%{
        organization_id: org.id,
        stop_id: "stop-dup",
        address: "456 Elm St"
      })

      assert {:error, changeset} =
               Validations.create_walkability_test(org.id, %{
                 stop_id: "stop-dup",
                 address: "456 Elm St",
                 address_lat: Decimal.new("42.3601"),
                 address_lon: Decimal.new("-71.0589")
               })

      assert "has already been taken" in errors_on(changeset).organization_id
    end

    test "list_walkability_tests/1 returns tests scoped to the given org", %{organization: org} do
      wt1 =
        walkability_test_fixture(%{organization_id: org.id, stop_id: "stop-a", address: "Addr A"})

      other_org = organization_fixture()

      _wt2 =
        walkability_test_fixture(%{
          organization_id: other_org.id,
          stop_id: "stop-b",
          address: "Addr B"
        })

      results = Validations.list_walkability_tests(org.id)

      assert length(results) == 1
      assert hd(results).id == wt1.id
    end

    test "get_walkability_test!/1 returns the test", %{organization: org} do
      walkability_test = walkability_test_fixture(%{organization_id: org.id})

      fetched = Validations.get_walkability_test!(walkability_test.id)
      assert fetched.id == walkability_test.id
      assert fetched.organization_id == org.id
    end

    test "list_walkability_tests_for_stop_ids/2 scopes by org and stop ids", %{organization: org} do
      included_stop_a =
        walkability_test_fixture(%{
          organization_id: org.id,
          stop_id: "stop-included-a",
          address: "Address A"
        })

      included_stop_b =
        walkability_test_fixture(%{
          organization_id: org.id,
          stop_id: "stop-included-b",
          address: "Address B"
        })

      _excluded_stop =
        walkability_test_fixture(%{
          organization_id: org.id,
          stop_id: "stop-excluded",
          address: "Address C"
        })

      other_org = organization_fixture()

      _excluded_org =
        walkability_test_fixture(%{
          organization_id: other_org.id,
          stop_id: "stop-included-a",
          address: "Address D"
        })

      assert [] = Validations.list_walkability_tests_for_stop_ids(org.id, [])

      results =
        Validations.list_walkability_tests_for_stop_ids(org.id, [
          "stop-included-a",
          "stop-included-b"
        ])

      result_ids = Enum.map(results, & &1.id)
      assert included_stop_a.id in result_ids
      assert included_stop_b.id in result_ids
      assert length(results) == 2
    end

    test "get_walkability_test/1 returns test or nil", %{organization: org} do
      walkability_test = walkability_test_fixture(%{organization_id: org.id})

      assert %WalkabilityTest{id: id} = Validations.get_walkability_test(walkability_test.id)
      assert id == walkability_test.id
      assert nil == Validations.get_walkability_test(Ecto.UUID.generate())
    end

    test "update_walkability_test/2 updates fields", %{organization: org} do
      walkability_test = walkability_test_fixture(%{organization_id: org.id})

      assert {:ok, %WalkabilityTest{} = updated} =
               Validations.update_walkability_test(walkability_test, %{
                 description: "Updated description",
                 expected_traversable: true
               })

      assert updated.id == walkability_test.id
      assert updated.description == "Updated description"
      assert updated.expected_traversable == true
    end

    test "delete_walkability_test/1 removes the record", %{organization: org} do
      walkability_test = walkability_test_fixture(%{organization_id: org.id})

      assert {:ok, %WalkabilityTest{}} = Validations.delete_walkability_test(walkability_test)

      assert_raise Ecto.NoResultsError, fn ->
        Validations.get_walkability_test!(walkability_test.id)
      end
    end
  end
end
