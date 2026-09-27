defmodule GtfsPlanner.Operations.FleetTest do
  use GtfsPlanner.DataCase, async: false

  @async_timeout 5_000

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Vehicle
  alias GtfsPlanner.Operations.VehicleType
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures

  describe "list_vehicle_types/1" do
    test "isolates organizations, orders by name and counts vehicles" do
      organization = organization_fixture()
      other = organization_fixture()
      type = vehicle_type_fixture(organization.id, %{"name" => "Coach"})

      vehicle_type_fixture(organization.id, %{"name" => "Bus"})
      vehicle_fixture(organization.id, %{"vehicle_type_id" => type.id})
      vehicle_fixture(organization.id, %{"vehicle_type_id" => type.id})
      vehicle_type_fixture(other.id, %{"name" => "Foreign Type"})

      assert Enum.map(Operations.list_vehicle_types(organization.id), & &1.name) == [
               "Bus",
               "Coach"
             ]

      assert [%VehicleType{name: "Bus", vehicle_count: 0}, %VehicleType{vehicle_count: 2}] =
               Operations.list_vehicle_types(organization.id)

      assert Enum.map(Operations.list_vehicle_types(other.id), & &1.name) == ["Foreign Type"]
    end
  end

  describe "create_vehicle_type/3" do
    test "requires a name" do
      organization = organization_fixture()

      assert {:error, changeset} =
               Operations.create_vehicle_type(organization.id, operations_actor(), %{})

      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "stores supplied hours as minutes" do
      organization = organization_fixture()

      assert {:ok, %VehicleType{max_out_minutes: 600}} =
               Operations.create_vehicle_type(organization.id, operations_actor(), %{
                 "name" => "Ten hours",
                 "max_out_hours" => "10"
               })

      assert {:ok, %VehicleType{max_out_minutes: 60}} =
               Operations.create_vehicle_type(organization.id, operations_actor(), %{
                 "name" => "One hour",
                 "max_out_hours" => "1"
               })

      assert {:ok, %VehicleType{max_out_minutes: 1440}} =
               Operations.create_vehicle_type(organization.id, operations_actor(), %{
                 "name" => "All day",
                 "max_out_hours" => "24"
               })

      assert {:ok, %VehicleType{max_out_minutes: nil}} =
               Operations.create_vehicle_type(organization.id, operations_actor(), %{
                 "name" => "No limit"
               })
    end

    test "an out-of-range limit is a max_out_hours error and is not rounded into range" do
      organization = organization_fixture()

      for hours <- ["0.999", "24.001", "25", "0"] do
        assert {:error, changeset} =
                 Operations.create_vehicle_type(organization.id, operations_actor(), %{
                   "name" => "Out of range #{hours}",
                   "max_out_hours" => hours
                 })

        assert %{max_out_hours: [_ | _]} = errors_on(changeset)
        refute Map.has_key?(changeset.changes, :max_out_minutes)
      end
    end

    test "rejects a case-insensitive duplicate name and allows it in another organization" do
      organization = organization_fixture()
      other = organization_fixture()
      vehicle_type_fixture(organization.id, %{"name" => "Bus"})

      assert {:error, changeset} =
               Operations.create_vehicle_type(organization.id, operations_actor(), %{
                 "name" => "bus"
               })

      assert %{name: [_ | _]} = errors_on(changeset)
      assert length(Operations.list_vehicle_types(organization.id)) == 1

      assert {:ok, %VehicleType{}} =
               Operations.create_vehicle_type(other.id, operations_actor(), %{"name" => "Bus"})
    end

    test "records the acting user and ignores tenant and actor params" do
      organization = organization_fixture()
      other = organization_fixture()
      actor = operations_actor()

      assert {:ok, vehicle_type} =
               Operations.create_vehicle_type(organization.id, actor, %{
                 "name" => "Bus",
                 "organization_id" => other.id,
                 "updated_by_id" => Ecto.UUID.generate()
               })

      assert vehicle_type.organization_id == organization.id
      assert vehicle_type.updated_by_id == actor.id
      assert Operations.list_vehicle_types(other.id) == []
    end
  end

  describe "update_vehicle_type/4" do
    test "records the acting user and re-stores edited hours as minutes" do
      organization = organization_fixture()
      actor = operations_actor()
      vehicle_type = vehicle_type_fixture(organization.id, %{"max_out_hours" => "10"})

      assert {:ok, updated} =
               Operations.update_vehicle_type(organization.id, actor, vehicle_type.id, %{
                 "max_out_hours" => "12.5"
               })

      assert updated.max_out_minutes == 750
      assert updated.updated_by_id == actor.id
      assert updated.id == vehicle_type.id
    end

    test "a blank clears the limit and an absent value preserves it" do
      organization = organization_fixture()
      vehicle_type = vehicle_type_fixture(organization.id, %{"max_out_hours" => "10"})

      assert {:ok, cleared} =
               Operations.update_vehicle_type(
                 organization.id,
                 operations_actor(),
                 vehicle_type.id,
                 %{
                   "max_out_hours" => ""
                 }
               )

      assert cleared.max_out_minutes == nil
      assert Repo.get(VehicleType, vehicle_type.id).max_out_minutes == nil

      restored =
        vehicle_type_fixture(organization.id, %{"max_out_hours" => "10"})

      assert {:ok, preserved} =
               Operations.update_vehicle_type(organization.id, operations_actor(), restored.id, %{
                 "name" => "Renamed"
               })

      assert preserved.name == "Renamed"
      assert preserved.max_out_minutes == 600
    end

    test "a foreign, unknown or malformed type is not found and changes nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign = vehicle_type_fixture(other.id, %{"name" => "Foreign"})

      assert {:error, :not_found} =
               Operations.update_vehicle_type(organization.id, operations_actor(), foreign.id, %{
                 "name" => "Hijacked"
               })

      assert Repo.get(VehicleType, foreign.id).name == "Foreign"

      assert {:error, :not_found} =
               Operations.update_vehicle_type(
                 organization.id,
                 operations_actor(),
                 Ecto.UUID.generate(),
                 %{"name" => "Missing"}
               )

      assert {:error, :not_found} =
               Operations.update_vehicle_type(
                 organization.id,
                 operations_actor(),
                 "not-a-uuid",
                 %{"name" => "Missing"}
               )
    end
  end

  describe "list_garages/1 vehicle counts" do
    test "populates vehicle_count from the vehicles in the organization" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id, %{"name" => "Main"})
      garage_fixture(organization.id, %{"name" => "Empty"})

      vehicle_fixture(organization.id, %{"garage_id" => garage.id})
      vehicle_fixture(organization.id, %{"garage_id" => garage.id})
      vehicle_fixture(organization.id)

      assert [%Garage{name: "Empty", vehicle_count: 0}, %Garage{vehicle_count: 2}] =
               Operations.list_garages(organization.id)
    end
  end

  describe "create_vehicle/3" do
    test "requires a vehicle_id" do
      organization = organization_fixture()

      assert {:error, changeset} =
               Operations.create_vehicle(organization.id, operations_actor(), %{})

      assert %{vehicle_id: [_ | _]} = errors_on(changeset)
    end

    test "rejects a duplicate vehicle_id with a changeset error and adds nothing" do
      organization = organization_fixture()
      existing = vehicle_fixture(organization.id, %{"vehicle_id" => "bus-1"})

      assert {:error, changeset} =
               Operations.create_vehicle(organization.id, operations_actor(), %{
                 "vehicle_id" => "bus-1"
               })

      assert %{vehicle_id: [_ | _]} = errors_on(changeset)
      assert [%Vehicle{id: id}] = Operations.list_vehicles(organization.id, %{})
      assert id == existing.id
    end

    test "allows the same vehicle_id in another organization" do
      organization = organization_fixture()
      other = organization_fixture()

      vehicle_fixture(organization.id, %{"vehicle_id" => "bus-1"})

      assert {:ok, vehicle} =
               Operations.create_vehicle(other.id, operations_actor(), %{"vehicle_id" => "bus-1"})

      assert vehicle.organization_id == other.id
    end

    test "records the acting user and ignores tenant and actor params" do
      organization = organization_fixture()
      other = organization_fixture()
      actor = operations_actor()

      assert {:ok, vehicle} =
               Operations.create_vehicle(organization.id, actor, %{
                 "vehicle_id" => "bus-1",
                 "vehicle_label" => "  Old Reliable  ",
                 "organization_id" => other.id,
                 "updated_by_id" => Ecto.UUID.generate()
               })

      assert vehicle.organization_id == organization.id
      assert vehicle.updated_by_id == actor.id
      assert vehicle.vehicle_label == "Old Reliable"
      assert Operations.list_vehicles(other.id, %{}) == []
    end

    test "a blank assignment is stored as unassigned" do
      organization = organization_fixture()

      assert {:ok, %Vehicle{vehicle_type_id: nil, garage_id: nil}} =
               Operations.create_vehicle(organization.id, operations_actor(), %{
                 "vehicle_id" => "bus-1",
                 "vehicle_type_id" => "",
                 "garage_id" => ""
               })
    end

    test "malformed, missing and foreign type or garage UUIDs return safe errors" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign_garage = garage_fixture(other.id)
      foreign_type = vehicle_type_fixture(other.id)
      missing_id = Ecto.UUID.generate()

      for attrs <- [
            %{"vehicle_id" => "v1", "garage_id" => "not-a-uuid"},
            %{"vehicle_id" => "v2", "vehicle_type_id" => "not-a-uuid"},
            %{"vehicle_id" => "v3", "garage_id" => foreign_garage.id},
            %{"vehicle_id" => "v4", "vehicle_type_id" => foreign_type.id},
            %{"vehicle_id" => "v5", "garage_id" => missing_id},
            %{"vehicle_id" => "v6", "vehicle_type_id" => missing_id}
          ] do
        assert {:error, :not_found} =
                 Operations.create_vehicle(organization.id, operations_actor(), attrs)
      end

      assert Operations.list_vehicles(organization.id, %{}) == []
    end
  end

  describe "update_vehicle/4" do
    test "updates the editable fields and records the acting user" do
      organization = organization_fixture()
      actor = operations_actor()
      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "bus-1"})

      assert {:ok, updated} =
               Operations.update_vehicle(organization.id, actor, vehicle.id, %{
                 "vehicle_id" => "bus-9",
                 "vehicle_label" => "Buster",
                 "license_plate" => "OR-E251432"
               })

      assert updated.vehicle_id == "bus-9"
      assert updated.vehicle_label == "Buster"
      assert updated.license_plate == "OR-E251432"
      assert updated.updated_by_id == actor.id
      assert updated.id == vehicle.id
    end

    test "sets a present assignment and clears a blank one while preserving absent keys" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id)
      other_garage = garage_fixture(organization.id)
      vehicle = vehicle_fixture(organization.id)

      assert {:ok, assigned} =
               Operations.update_vehicle(organization.id, operations_actor(), vehicle.id, %{
                 "garage_id" => garage.id
               })

      assert assigned.garage_id == garage.id
      assert assigned.vehicle_type_id == nil

      assert {:ok, typed} =
               Operations.update_vehicle(organization.id, operations_actor(), vehicle.id, %{
                 "vehicle_type_id" => vehicle_type.id
               })

      assert typed.vehicle_type_id == vehicle_type.id
      assert typed.garage_id == garage.id

      assert {:ok, moved} =
               Operations.update_vehicle(organization.id, operations_actor(), vehicle.id, %{
                 "garage_id" => other_garage.id
               })

      assert moved.garage_id == other_garage.id
      assert moved.vehicle_type_id == vehicle_type.id

      assert {:ok, cleared} =
               Operations.update_vehicle(organization.id, operations_actor(), vehicle.id, %{
                 "vehicle_type_id" => ""
               })

      assert cleared.vehicle_type_id == nil
      assert cleared.garage_id == other_garage.id
    end

    test "a foreign, unknown or malformed vehicle or target is not found and changes nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign = vehicle_fixture(other.id)
      foreign_garage = garage_fixture(other.id)
      vehicle = vehicle_fixture(organization.id, %{"vehicle_label" => "Original"})

      assert {:error, :not_found} =
               Operations.update_vehicle(organization.id, operations_actor(), foreign.id, %{
                 "vehicle_label" => "Hijacked"
               })

      assert {:error, :not_found} =
               Operations.update_vehicle(
                 organization.id,
                 operations_actor(),
                 Ecto.UUID.generate(),
                 %{"vehicle_label" => "Missing"}
               )

      assert {:error, :not_found} =
               Operations.update_vehicle(organization.id, operations_actor(), "not-a-uuid", %{
                 "vehicle_label" => "Missing"
               })

      assert {:error, :not_found} =
               Operations.update_vehicle(organization.id, operations_actor(), vehicle.id, %{
                 "garage_id" => foreign_garage.id
               })

      assert Repo.get(Vehicle, vehicle.id).vehicle_label == "Original"
      assert Repo.get(Vehicle, vehicle.id).garage_id == nil
      assert Repo.get(Vehicle, foreign.id).vehicle_label != "Hijacked"
    end
  end

  describe "list_vehicles/2" do
    test "orders by vehicle ID length then value" do
      organization = organization_fixture()

      for id <- ["bus-2", "10", "9"], do: vehicle_fixture(organization.id, %{"vehicle_id" => id})

      assert Enum.map(Operations.list_vehicles(organization.id, %{}), & &1.vehicle_id) == [
               "9",
               "10",
               "bus-2"
             ]
    end

    test "filters by type, garage, :none and preloads the assignments" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id)

      assigned =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "assigned",
          "garage_id" => garage.id,
          "vehicle_type_id" => vehicle_type.id
        })

      garage_only =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "garage-only",
          "garage_id" => garage.id
        })

      unassigned = vehicle_fixture(organization.id, %{"vehicle_id" => "unassigned"})

      assert [%Vehicle{id: id, garage: %Garage{}, vehicle_type: %VehicleType{}}] =
               Operations.list_vehicles(organization.id, %{type: vehicle_type.id})

      assert id == assigned.id

      assert Enum.map(
               Operations.list_vehicles(organization.id, %{garage: garage.id}),
               & &1.id
             )
             |> Enum.sort() == Enum.sort([assigned.id, garage_only.id])

      assert Operations.list_vehicles(organization.id, %{type: :none})
             |> Enum.map(& &1.id)
             |> Enum.sort() == Enum.sort([garage_only.id, unassigned.id])

      assert Enum.map(Operations.list_vehicles(organization.id, %{garage: :none}), & &1.id) == [
               unassigned.id
             ]

      assert Operations.list_vehicles(organization.id, %{garage: Ecto.UUID.generate()}) == []
    end

    test "q matches ID, label and plate case-insensitively and treats % and _ literally" do
      organization = organization_fixture()

      vehicle_fixture(organization.id, %{"vehicle_id" => "bus%1"})
      vehicle_fixture(organization.id, %{"vehicle_id" => "busX1"})
      vehicle_fixture(organization.id, %{"vehicle_id" => "bus_2"})
      vehicle_fixture(organization.id, %{"vehicle_id" => "busY2"})

      vehicle_fixture(organization.id, %{
        "vehicle_id" => "shuttle",
        "vehicle_label" => "Old Reliable"
      })

      vehicle_fixture(organization.id, %{"vehicle_id" => "tram", "license_plate" => "OR-E251432"})

      assert Enum.map(Operations.list_vehicles(organization.id, %{q: "bus%"}), & &1.vehicle_id) ==
               [
                 "bus%1"
               ]

      assert Enum.map(Operations.list_vehicles(organization.id, %{q: "bus_"}), & &1.vehicle_id) ==
               [
                 "bus_2"
               ]

      assert Enum.map(
               Operations.list_vehicles(organization.id, %{q: "reliable"}),
               & &1.vehicle_id
             ) ==
               ["shuttle"]

      assert Enum.map(
               Operations.list_vehicles(organization.id, %{q: "or-e251432"}),
               & &1.vehicle_id
             ) == ["tram"]

      assert Operations.list_vehicles(organization.id, %{q: "  "}) |> length() == 6
    end

    test "isolates organizations" do
      organization = organization_fixture()
      other = organization_fixture()

      vehicle_fixture(organization.id, %{"vehicle_id" => "mine"})
      vehicle_fixture(other.id, %{"vehicle_id" => "theirs"})

      assert Enum.map(Operations.list_vehicles(organization.id, %{}), & &1.vehicle_id) == ["mine"]
    end
  end

  describe "delete_garage/2 in-use guard" do
    test "an in-use garage is refused with a count and every row is left intact" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id)
      vehicle = vehicle_fixture(organization.id, %{"garage_id" => garage.id})

      assert {:error, {:in_use, vehicles: 1}} =
               Operations.delete_garage(organization.id, garage.id)

      assert Repo.get(Garage, garage.id)
      assert Repo.get(Vehicle, vehicle.id)

      # The savepoint around the attempted delete left the connection usable, so
      # a following count still succeeds.
      assert Repo.aggregate(Vehicle, :count, :id) == 1
    end

    test "an unused garage deletes" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id)

      assert {:ok, %Garage{id: id}} = Operations.delete_garage(organization.id, garage.id)
      assert id == garage.id
      assert Repo.get(Garage, garage.id) == nil
    end

    test "a foreign, unknown or malformed garage is not found and changes nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign = garage_fixture(other.id)

      assert {:error, :not_found} = Operations.delete_garage(organization.id, foreign.id)
      assert Repo.get(Garage, foreign.id)

      assert {:error, :not_found} =
               Operations.delete_garage(organization.id, Ecto.UUID.generate())

      assert {:error, :not_found} = Operations.delete_garage(organization.id, "not-a-uuid")
    end

    test "changing a garage ID keeps the UUID and every vehicle assignment" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id, %{"garage_id" => "garage_main"})
      vehicle_type = vehicle_type_fixture(organization.id)

      vehicle =
        vehicle_fixture(organization.id, %{
          "garage_id" => garage.id,
          "vehicle_type_id" => vehicle_type.id
        })

      assert {:ok, updated} =
               Operations.update_garage(organization.id, operations_actor(), garage.id, %{
                 "garage_id" => "garage_depot"
               })

      assert updated.id == garage.id
      assert updated.garage_id == "garage_depot"

      reloaded = Repo.get(Vehicle, vehicle.id)
      assert reloaded.garage_id == garage.id
      assert reloaded.vehicle_type_id == vehicle_type.id

      assert [%Vehicle{garage: %Garage{garage_id: "garage_depot"}}] =
               Operations.list_vehicles(organization.id, %{garage: garage.id})
    end
  end

  describe "delete_vehicle_type/2 in-use guard" do
    test "an in-use type is refused with a count and every row is left intact" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id)

      vehicle =
        vehicle_fixture(organization.id, %{
          "garage_id" => garage.id,
          "vehicle_type_id" => vehicle_type.id
        })

      assert {:error, {:in_use, vehicles: 1}} =
               Operations.delete_vehicle_type(organization.id, vehicle_type.id)

      assert Repo.get(VehicleType, vehicle_type.id)
      assert Repo.get(Vehicle, vehicle.id).vehicle_type_id == vehicle_type.id
      assert Repo.aggregate(Vehicle, :count, :id) == 1
    end

    test "an unused type deletes" do
      organization = organization_fixture()
      vehicle_type = vehicle_type_fixture(organization.id)

      assert {:ok, %VehicleType{id: id}} =
               Operations.delete_vehicle_type(organization.id, vehicle_type.id)

      assert id == vehicle_type.id
      assert Repo.get(VehicleType, vehicle_type.id) == nil
    end

    test "a foreign, unknown or malformed type is not found and changes nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign = vehicle_type_fixture(other.id)

      assert {:error, :not_found} =
               Operations.delete_vehicle_type(organization.id, foreign.id)

      assert Repo.get(VehicleType, foreign.id)

      assert {:error, :not_found} =
               Operations.delete_vehicle_type(organization.id, Ecto.UUID.generate())

      assert {:error, :not_found} = Operations.delete_vehicle_type(organization.id, "not-a-uuid")
    end
  end

  describe "foreign key semantics" do
    test "both vehicle references are NO ACTION so organization deletion still cascades" do
      actions = foreign_key_delete_actions()

      assert actions["vehicles_garage_id_fkey"] == "a"
      assert actions["vehicles_vehicle_type_id_fkey"] == "a"
      # The organization reference cascades so deleting the organization still works.
      assert actions["vehicles_organization_id_fkey"] == "c"
    end

    test "deleting an organization with assigned vehicles removes garages, types and vehicles" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id)

      vehicle =
        vehicle_fixture(organization.id, %{
          "garage_id" => garage.id,
          "vehicle_type_id" => vehicle_type.id
        })

      assert {:ok, %Organization{id: id}} = Organizations.delete_organization(organization)
      assert id == organization.id

      assert Repo.get(Garage, garage.id) == nil
      assert Repo.get(VehicleType, vehicle_type.id) == nil
      assert Repo.get(Vehicle, vehicle.id) == nil
    end
  end

  describe "concurrency" do
    test "concurrent duplicate inserts yield changeset errors rather than escaping Postgrex errors" do
      Sandbox.unboxed_run(Repo, fn ->
        organization = organization_fixture(%{alias: "race-#{Ecto.UUID.generate()}"})
        vehicle_id = "race-#{System.unique_integer([:positive])}"
        owner = self()

        try do
          for _ <- 1..2 do
            start_unboxed_task(fn ->
              result =
                Operations.create_vehicle(
                  organization.id,
                  %{id: Ecto.UUID.generate()},
                  %{"vehicle_id" => vehicle_id}
                )

              send(owner, {:insert_result, self(), result})
            end)
          end

          results =
            for _ <- 1..2 do
              assert_receive {:insert_result, _pid, result}, @async_timeout
              result
            end

          assert [%Vehicle{}] = for({:ok, vehicle} <- results, do: vehicle)

          assert [{:error, %Ecto.Changeset{} = changeset}] =
                   for({:error, changeset} <- results, do: {:error, changeset})

          assert %{vehicle_id: [_ | _]} = errors_on(changeset)

          assert Repo.aggregate(
                   from(v in Vehicle, where: v.vehicle_id == ^vehicle_id),
                   :count,
                   :id
                 ) ==
                   1
        after
          delete_operations_fixtures!(organization.id)
        end
      end)
    end

    test "assignment versus deletion cannot commit a dangling or silently cleared assignment" do
      Sandbox.unboxed_run(Repo, fn ->
        organization = organization_fixture(%{alias: "race-#{Ecto.UUID.generate()}"})
        garage = garage_fixture(organization.id, %{"garage_id" => "garage_race"})
        vehicle_id = "race-#{System.unique_integer([:positive])}"
        owner = self()

        try do
          {assigner, _assigner_id} =
            start_unboxed_task(fn ->
              result =
                Repo.transaction(fn ->
                  %Postgrex.Result{} =
                    Repo.query!(
                      "SELECT id FROM garages WHERE id = $1 FOR KEY SHARE",
                      [Ecto.UUID.dump!(garage.id)]
                    )

                  send(owner, {:garage_locked, self()})

                  receive do
                    :assign -> :ok
                  after
                    @async_timeout -> :timeout
                  end

                  Operations.create_vehicle(
                    organization.id,
                    %{id: Ecto.UUID.generate()},
                    %{"vehicle_id" => vehicle_id, "garage_id" => garage.id}
                  )
                end)

              send(owner, {:assign_result, self(), result})
            end)

          assert_receive {:garage_locked, ^assigner}, @async_timeout

          {deleter, _deleter_id} =
            start_unboxed_task(fn ->
              send(
                owner,
                {:delete_result, self(), Operations.delete_garage(organization.id, garage.id)}
              )
            end)

          send(assigner, :assign)

          assert_receive {:assign_result, ^assigner, {:ok, {:ok, %Vehicle{}}}}, @async_timeout

          assert_receive {:delete_result, ^deleter, {:error, {:in_use, vehicles: 1}}},
                         @async_timeout

          assert Repo.get(Garage, garage.id)

          assert Repo.aggregate(
                   from(v in Vehicle, where: v.vehicle_id == ^vehicle_id),
                   :count,
                   :id
                 ) == 1
        after
          delete_operations_fixtures!(organization.id)
        end
      end)
    end
  end

  defp start_unboxed_task(task) do
    child_id = make_ref()

    child_spec =
      Supervisor.child_spec(
        {Task,
         fn ->
           :ok = Sandbox.checkout(Repo, sandbox: false)

           try do
             task.()
           after
             Sandbox.checkin(Repo)
           end
         end},
        id: child_id
      )

    {start_supervised!(child_spec), child_id}
  end

  defp foreign_key_delete_actions do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT con.conname, con.confdeltype
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE rel.relname = 'vehicles'
          AND con.contype = 'f'
          AND nsp.nspname = current_schema()
        """,
        []
      )

    Map.new(rows, fn [name, action] -> {name, action} end)
  end

  defp delete_operations_fixtures!(organization_id) do
    Repo.delete_all(from(v in Vehicle, where: v.organization_id == ^organization_id))
    Repo.delete_all(from(t in VehicleType, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(g in Garage, where: g.organization_id == ^organization_id))
    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
  end
end

defmodule GtfsPlanner.Operations.FleetMigrationTest do
  # The fleet migration is exercised against real DDL in a unique disposable
  # PostgreSQL schema dropped on exit, so no retained development database is
  # ever rolled back.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Repo

  setup_all do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @migration_glob "../../../priv/repo/migrations/*_create_vehicle_types_and_vehicles.exs"

  @migration_path (
                    matches = Path.wildcard(Path.expand(@migration_glob, __DIR__))

                    case matches do
                      [path] ->
                        path

                      other ->
                        raise "expected exactly one create_vehicle_types_and_vehicles migration file, got: #{inspect(other)}"
                    end
                  )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.CreateVehicleTypesAndVehicles, as: Migration

  @now ~U[2026-09-27 00:00:00.000000Z]

  describe "create_vehicle_types_and_vehicles migration" do
    test "up, down and up again touches only the fleet tables and preserves garages" do
      schema = setup_prefix()
      organization_id = insert_organization(schema, "Retained Org")
      garage_id = insert_garage(schema, organization_id, "garage_kept")

      refute table_exists?(schema, "vehicle_types")
      refute table_exists?(schema, "vehicles")

      migrate_up(schema)
      assert table_exists?(schema, "vehicle_types")
      assert table_exists?(schema, "vehicles")

      assert "vehicle_types_organization_id_lower_name_index" in index_names(
               schema,
               "vehicle_types"
             )

      for index <- ~w(
            vehicles_organization_id_vehicle_id_index
            vehicles_organization_id_garage_id_vehicle_type_id_index
            vehicles_vehicle_type_id_index
          ) do
        assert index in index_names(schema, "vehicles")
      end

      assert garage_ids(schema) == [garage_id]

      migrate_down(schema)
      refute table_exists?(schema, "vehicle_types")
      refute table_exists?(schema, "vehicles")
      assert garage_ids(schema) == [garage_id]

      migrate_up(schema)
      assert table_exists?(schema, "vehicle_types")
      assert table_exists?(schema, "vehicles")
      assert garage_ids(schema) == [garage_id]
    end

    test "the vehicle references are NO ACTION in the migrated schema" do
      schema = setup_prefix()
      organization_id = insert_organization(schema, "Org")
      migrate_up(schema)

      actions = foreign_key_actions(schema, "vehicles")

      assert actions["vehicles_vehicle_type_id_fkey"] == "a"
      assert actions["vehicles_garage_id_fkey"] == "a"
      assert actions["vehicles_organization_id_fkey"] == "c"

      assert is_binary(organization_id)
    end
  end

  defp setup_prefix do
    schema = "test_fleet_#{System.unique_integer([:positive])}"

    SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|, [])
    end)

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".organizations (
        id uuid PRIMARY KEY,
        name varchar(255) NOT NULL,
        inserted_at timestamp NOT NULL DEFAULT now(),
        updated_at timestamp NOT NULL DEFAULT now()
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".garages (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id),
        garage_id varchar(255) NOT NULL,
        name varchar(255) NOT NULL,
        lat numeric NOT NULL,
        lon numeric NOT NULL,
        inserted_at timestamp NOT NULL DEFAULT now(),
        updated_at timestamp NOT NULL DEFAULT now()
      )
      """,
      []
    )

    schema
  end

  defp insert_organization(schema, name) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".organizations (id, name) VALUES ($1, $2)|,
      [Ecto.UUID.dump!(id), name]
    )

    id
  end

  defp insert_garage(schema, organization_id, garage_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".garages
        (id, organization_id, garage_id, name, lat, lon, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 40.0, -74.0, $5, $5)
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(organization_id), garage_id, "Garage", @now]
    )

    id
  end

  defp garage_ids(schema) do
    %{rows: rows} =
      SQL.query!(Repo, ~s|SELECT id::text FROM "#{schema}".garages ORDER BY garage_id|, [])

    List.flatten(rows)
  end

  defp table_exists?(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = $1 AND table_name = $2
        """,
        [schema, table]
      )

    rows != []
  end

  defp index_names(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = $1 AND tablename = $2
        """,
        [schema, table]
      )

    List.flatten(rows)
  end

  defp foreign_key_actions(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT con.conname, con.confdeltype
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND rel.relname = $2 AND con.contype = 'f'
        """,
        [schema, table]
      )

    Map.new(rows, fn [name, action] -> {name, action} end)
  end

  defp migrate_up(schema) do
    Ecto.Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)
  end

  defp migrate_down(schema) do
    Ecto.Migrator.down(Repo, @migration_version, Migration, prefix: schema, log: false)
  end
end
