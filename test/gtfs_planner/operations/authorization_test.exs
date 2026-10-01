defmodule GtfsPlanner.Operations.AuthorizationTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Operations.Vehicle
  alias GtfsPlanner.Operations.VehicleType

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  test "a revoked editor cannot use any public operations writer" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    garage = garage_fixture(organization.id)
    vehicle_type = vehicle_type_fixture(organization.id)

    vehicle =
      vehicle_fixture(organization.id, %{
        "garage_id" => garage.id,
        "vehicle_type_id" => vehicle_type.id
      })

    orphan =
      block_attribute_fixture(organization.id, version.id, %{
        service_id: "weekday",
        block_id: "orphan",
        garage_id: garage.id,
        vehicle_type_id: vehicle_type.id
      })

    driving_time =
      deadhead_time_fixture(organization.id, version.id, %{
        from_ref: {:garage, garage.id},
        to_ref: {:stop, "depot"},
        minutes: 5
      })

    {:ok, parsed} =
      Tods.parse(
        :garages,
        "stops_supplement.txt",
        "stop_id,stop_name,stop_lat,stop_lon,TODS_location_type\n" <>
          "garage_new,New garage,40.0,-74.0,garage\n"
      )

    preview = Operations.preview_tods_import(organization.id, parsed)
    assert preview.errors == []
    before = snapshot(organization.id, garage, vehicle_type, vehicle, orphan, driving_time)

    actor
    |> membership_for(organization)
    |> deactivate_membership_fixture()

    assert {:error, :forbidden} =
             Operations.create_garage(organization.id, actor, %{
               "garage_id" => "garage_added",
               "name" => "Added",
               "lat" => "40.0",
               "lon" => "-74.0"
             })

    assert {:error, :forbidden} =
             Operations.update_garage(organization.id, actor, garage.id, %{"name" => "Changed"})

    assert {:error, :forbidden} = Operations.delete_garage(organization.id, actor, garage.id)

    assert {:error, :forbidden} =
             Operations.create_vehicle_type(organization.id, actor, %{"name" => "Added"})

    assert {:error, :forbidden} =
             Operations.update_vehicle_type(organization.id, actor, vehicle_type.id, %{
               "name" => "Changed"
             })

    assert {:error, :forbidden} =
             Operations.delete_vehicle_type(organization.id, actor, vehicle_type.id)

    assert {:error, :forbidden} =
             Operations.create_vehicle(organization.id, actor, %{"vehicle_id" => "added"})

    assert {:error, :forbidden} =
             Operations.update_vehicle(organization.id, actor, vehicle.id, %{
               "vehicle_label" => "Changed"
             })

    assert {:error, :forbidden} =
             Operations.create_vehicle_range(organization.id, actor, %{
               "first" => "100",
               "last" => "101"
             })

    assert {:error, :forbidden} =
             Operations.create_vehicle_range(organization.id, actor, %{
               "first" => "invalid",
               "last" => "101"
             })

    assert {:error, :forbidden} =
             Operations.update_vehicles(organization.id, actor, [vehicle.id], {:garage_id, nil})

    assert {:error, :forbidden} =
             Operations.update_vehicles(organization.id, actor, [], {:garage_id, nil})

    assert {:error, :forbidden} =
             Operations.delete_vehicles(organization.id, actor, [vehicle.id])

    assert {:error, :forbidden} = Operations.delete_vehicles(organization.id, actor, [])

    assert {:error, :forbidden} =
             Operations.apply_tods_import(organization.id, actor, parsed, preview)

    assert snapshot(organization.id, garage, vehicle_type, vehicle, orphan, driving_time) ==
             before
  end

  test "a revoked editor cannot use any operator writer" do
    organization = organization_fixture()
    actor = editor_fixture(organization)

    assert {:ok, operator} =
             Operations.create_operator(organization.id, actor, %{
               "employee_id" => "E4101",
               "display_name" => "Aurelia Nowak",
               "seniority_number" => 7
             })

    {:ok, parsed} =
      Tods.parse(
        :operators,
        "operators.csv",
        "employee_id,display_name,seniority_number\nE4101,Renamed,3\nE4200,Bo Silva,9\n"
      )

    preview = Operations.preview_operator_import(organization.id, parsed)
    assert [%{employee_id: "E4200"}] = preview.add
    before = stored_operators(organization.id)

    actor
    |> membership_for(organization)
    |> deactivate_membership_fixture()

    assert {:error, :forbidden} =
             Operations.create_operator(organization.id, actor, %{
               "employee_id" => "E4300",
               "display_name" => "Added"
             })

    assert {:error, :forbidden} =
             Operations.update_operator(organization.id, actor, operator.id, %{
               "display_name" => "Changed"
             })

    assert {:error, :forbidden} = Operations.delete_operator(organization.id, actor, operator.id)

    assert {:error, :forbidden} =
             Operations.apply_operator_import(organization.id, actor, parsed, preview)

    assert stored_operators(organization.id) == before
  end

  test "an editor of another organization cannot create or delete local assets" do
    organization = organization_fixture()
    other = organization_fixture()
    actor = editor_fixture(other)
    garage = garage_fixture(organization.id)

    assert {:error, :forbidden} =
             Operations.create_garage(organization.id, actor, %{
               "garage_id" => "foreign_added",
               "name" => "Added",
               "lat" => "40.0",
               "lon" => "-74.0"
             })

    assert {:error, :forbidden} = Operations.delete_garage(organization.id, actor, garage.id)
    assert Repo.get(Garage, garage.id)
    assert length(Operations.list_garages(organization.id)) == 1
    assert Operations.list_garages(other.id) == []
  end

  defp stored_operators(organization_id) do
    Repo.all(from(o in Operator, where: o.organization_id == ^organization_id, order_by: o.id))
  end

  defp membership_for(actor, organization) do
    Repo.get_by!(UserOrgMembership, user_id: actor.id, organization_id: organization.id)
  end

  defp snapshot(organization_id, garage, vehicle_type, vehicle, orphan, driving_time) do
    %{
      garages:
        Repo.aggregate(from(g in Garage, where: g.organization_id == ^organization_id), :count),
      vehicle_types:
        Repo.aggregate(
          from(t in VehicleType, where: t.organization_id == ^organization_id),
          :count
        ),
      vehicles:
        Repo.aggregate(from(v in Vehicle, where: v.organization_id == ^organization_id), :count),
      garage: Repo.get(Garage, garage.id),
      vehicle_type: Repo.get(VehicleType, vehicle_type.id),
      vehicle: Repo.get(Vehicle, vehicle.id),
      orphan: Repo.get(BlockAttribute, orphan.id),
      driving_time: Repo.get(DeadheadTime, driving_time.id)
    }
  end
end
