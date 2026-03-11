defmodule GtfsPlanner.Validations.WalkabilitySuiteTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.WalkabilityTest
  alias GtfsPlanner.Validations.WalkabilitySuite

  test "select_suite/2 returns deterministic suite and metadata" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop_a =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-a", stop_name: "Stop A"})

    _stop_b =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-b", stop_name: "Stop B"})

    wt_b =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-b",
        address: "Addr B"
      })

    wt_a =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-a",
        address: "Addr A",
        address_lat: Decimal.new("42.3601"),
        address_lon: Decimal.new("-71.0589"),
        expected_traversable: true,
        expected_wheelchair_accessible: false,
        expected_min_duration_seconds: 60,
        expected_max_duration_seconds: 300,
        expected_min_distance_meters: 20,
        expected_max_distance_meters: 1000,
        description: "Test case A"
      })

    assert {:ok, result} = WalkabilitySuite.select_suite(organization.id, gtfs_version.id)

    assert result.invalid_cases == []

    assert result.meta == %{
             total: 2,
             valid: 2,
             invalid: 0,
             ordering: "stop_id ASC, address ASC, id ASC"
           }

    assert Enum.map(result.suite, & &1.walkability_test_id) == [wt_a.id, wt_b.id]
    assert Enum.map(result.suite, & &1.test_case_id) == [wt_a.id, wt_b.id]

    [first_case | _] = result.suite
    assert is_float(first_case.address_lat)
    assert is_float(first_case.address_lon)
    assert first_case.address_lat == 42.3601
    assert first_case.address_lon == -71.0589
    assert first_case.expected_traversable == true
    assert first_case.expected_wheelchair_accessible == false
    assert first_case.expected_min_duration_seconds == 60
    assert first_case.expected_max_duration_seconds == 300
    assert first_case.expected_min_distance_meters == 20
    assert first_case.expected_max_distance_meters == 1000
    assert first_case.description == "Test case A"
  end

  test "select_suite/2 is scoped by organization and gtfs_version" do
    organization = organization_fixture()
    requested_version = gtfs_version_fixture(organization.id)
    other_version = gtfs_version_fixture(organization.id)

    _requested_stop =
      stop_fixture(organization.id, requested_version.id, %{stop_id: "stop-requested"})

    _other_version_stop =
      stop_fixture(organization.id, other_version.id, %{stop_id: "stop-other-version"})

    _requested =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: requested_version.id,
        stop_id: "stop-requested"
      })

    _other_version =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: other_version.id,
        stop_id: "stop-other-version"
      })

    other_org = organization_fixture()
    other_org_version = gtfs_version_fixture(other_org.id)

    _other_org_stop =
      stop_fixture(other_org.id, other_org_version.id, %{stop_id: "stop-other-org"})

    _other_org =
      walkability_test_fixture(%{
        organization_id: other_org.id,
        gtfs_version_id: other_org_version.id,
        stop_id: "stop-other-org"
      })

    assert {:ok, result} = WalkabilitySuite.select_suite(organization.id, requested_version.id)
    assert result.meta.total == 1
    assert length(result.suite) == 1
    assert hd(result.suite).stop_id == "stop-requested"
  end

  test "select_suite/2 classifies malformed rows with reason codes" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop_valid =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-valid"})

    _stop_invalid_coordinate =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-invalid-coordinate"})

    _stop_invalid_expectation =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-invalid-expectation"})

    _valid =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-valid",
        address: "Addr valid"
      })

    _invalid_coordinate =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-invalid-coordinate",
        address: "Addr invalid coordinate",
        address_lat: Decimal.new("95.0000"),
        address_lon: Decimal.new("-71.0589")
      })

    _invalid_expectation =
      Repo.insert!(%WalkabilityTest{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-invalid-expectation",
        address: "Addr invalid expectation",
        address_lat: Decimal.new("42.3601"),
        address_lon: Decimal.new("-71.0589"),
        expected_min_duration_seconds: 200,
        expected_max_duration_seconds: 100
      })

    assert {:ok, result} = WalkabilitySuite.select_suite(organization.id, gtfs_version.id)

    assert result.meta == %{
             total: 3,
             valid: 1,
             invalid: 2,
             ordering: "stop_id ASC, address ASC, id ASC"
           }

    assert Enum.map(result.suite, & &1.stop_id) == ["stop-valid"]

    assert Enum.map(result.invalid_cases, & &1.reason_code) == [
             :invalid_coordinate_range,
             :invalid_expectation_bounds
           ]
  end

  test "select_suite/2 classifies invalid stop_id for version" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "stop-present",
        stop_name: "Present Stop"
      })

    _valid =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-present",
        address: "Addr valid"
      })

    _invalid_missing_stop =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-missing",
        address: "Addr missing stop"
      })

    assert {:ok, result} = WalkabilitySuite.select_suite(organization.id, gtfs_version.id)

    assert result.meta == %{
             total: 2,
             valid: 1,
             invalid: 1,
             ordering: "stop_id ASC, address ASC, id ASC"
           }

    assert Enum.map(result.suite, & &1.stop_id) == ["stop-present"]

    assert Enum.map(result.invalid_cases, & &1.reason_code) == [
             :invalid_stop_id_for_version
           ]
  end

  test "select_suite/2 is non-lossy: invalid rows are returned and excluded from suite" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop_valid =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-valid"})

    _stop_invalid_coordinate =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-invalid-coordinate"})

    valid_case =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-valid",
        address: "Addr valid"
      })

    invalid_coordinate =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-invalid-coordinate",
        address: "Addr invalid coordinate",
        address_lat: Decimal.new("95.0000"),
        address_lon: Decimal.new("-71.0589")
      })

    invalid_missing_stop =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-missing",
        address: "Addr missing stop"
      })

    inserted_ids =
      [valid_case.id, invalid_coordinate.id, invalid_missing_stop.id]
      |> MapSet.new()

    assert {:ok, result} = WalkabilitySuite.select_suite(organization.id, gtfs_version.id)

    suite_ids = result.suite |> Enum.map(& &1.walkability_test_id) |> MapSet.new()
    invalid_ids = result.invalid_cases |> Enum.map(& &1.walkability_test_id) |> MapSet.new()

    assert MapSet.disjoint?(suite_ids, invalid_ids)
    assert MapSet.union(suite_ids, invalid_ids) == inserted_ids

    assert suite_ids == MapSet.new([valid_case.id])
    assert invalid_ids == MapSet.new([invalid_coordinate.id, invalid_missing_stop.id])
  end

  test "select_suite/2 returns no valid suite with invalid diagnostics when all rows are malformed" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop_invalid_coordinate =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-invalid-coordinate"})

    invalid_coordinate =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-invalid-coordinate",
        address: "Addr invalid coordinate",
        address_lat: Decimal.new("95.0000"),
        address_lon: Decimal.new("-71.0589")
      })

    invalid_missing_stop =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-missing",
        address: "Addr missing stop"
      })

    assert {:ok, result} = WalkabilitySuite.select_suite(organization.id, gtfs_version.id)

    assert result.suite == []

    assert result.meta == %{
             total: 2,
             valid: 0,
             invalid: 2,
             ordering: "stop_id ASC, address ASC, id ASC"
           }

    invalid_by_id = Map.new(result.invalid_cases, &{&1.walkability_test_id, &1.reason_code})

    assert invalid_by_id == %{
             invalid_coordinate.id => :invalid_coordinate_range,
             invalid_missing_stop.id => :invalid_stop_id_for_version
           }
  end

  test "select_suite/3 scopes candidates by allowed_stop_ids before classification" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _in_scope_stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-in-scope"})

    _out_of_scope_stop =
      stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-out-of-scope"})

    in_scope_valid =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-in-scope",
        address: "Addr in scope"
      })

    out_of_scope_invalid =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-out-of-scope",
        address: "Addr out of scope",
        address_lat: Decimal.new("95.0"),
        address_lon: Decimal.new("-71.0589")
      })

    assert {:ok, result} =
             WalkabilitySuite.select_suite(organization.id, gtfs_version.id,
               allowed_stop_ids: ["stop-in-scope"],
               scope_label: "station:stop-in-scope"
             )

    assert Enum.map(result.suite, & &1.walkability_test_id) == [in_scope_valid.id]
    assert result.invalid_cases == []

    assert result.selection.total_candidates == 2
    assert result.selection.in_scope_candidates == 1
    assert result.selection.selected_count == 1
    assert result.selection.invalid_count == 0
    assert result.selection.scope_label == "station:stop-in-scope"
    assert result.selection.selected_test_case_ids == [in_scope_valid.id]
    assert result.selection.invalid_test_case_ids == []

    refute Enum.any?(result.selection.invalid_cases, fn invalid_case ->
             invalid_case.walkability_test_id == out_of_scope_invalid.id
           end)
  end

  test "select_suite/3 normalizes blank scope_label to nil" do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    _stop = stop_fixture(organization.id, gtfs_version.id, %{stop_id: "stop-1"})

    _walkability_test =
      walkability_test_fixture(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: "stop-1"
      })

    assert {:ok, result} =
             WalkabilitySuite.select_suite(organization.id, gtfs_version.id,
               allowed_stop_ids: ["stop-1"],
               scope_label: "   "
             )

    assert result.selection.scope_label == nil
  end
end
