defmodule GtfsPlanner.Operations.FleetBatchTest do
  use GtfsPlanner.DataCase, async: false

  @async_timeout 5_000

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Vehicle
  alias GtfsPlanner.Operations.VehicleType
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures

  describe "create_vehicle_range/3" do
    test "creates 200 vehicles with the assignments, the actor and sorted IDs" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Bus"})
      garage = garage_fixture(organization.id, %{"name" => "Depot"})

      assert {:ok, vehicles} =
               Operations.create_vehicle_range(organization.id, actor, %{
                 "first" => "1",
                 "last" => "200",
                 "vehicle_type_id" => vehicle_type.id,
                 "garage_id" => garage.id
               })

      assert length(vehicles) == 200
      assert Enum.map(vehicles, & &1.vehicle_id) == Enum.map(1..200, &Integer.to_string/1)

      assert Enum.all?(vehicles, fn vehicle ->
               vehicle.vehicle_type_id == vehicle_type.id and
                 vehicle.garage_id == garage.id and
                 vehicle.updated_by_id == actor.id and
                 vehicle.organization_id == organization.id and
                 is_binary(vehicle.id)
             end)

      assert vehicle_id_count(organization.id) == 200

      persisted = Repo.get(Vehicle, hd(vehicles).id) |> Repo.preload([:vehicle_type, :garage])
      assert persisted.vehicle_id == "1"
      assert persisted.vehicle_type.id == vehicle_type.id
      assert persisted.garage.id == garage.id
      assert persisted.updated_by_id == actor.id
    end

    test "pads generated IDs to the digit width of the first number" do
      organization = organization_fixture()

      assert {:ok, vehicles} =
               Operations.create_vehicle_range(
                 organization.id,
                 operations_actor(organization.id),
                 %{
                   "first" => "0098",
                   "last" => "0102"
                 }
               )

      assert Enum.map(vehicles, & &1.vehicle_id) == ["0098", "0099", "0100", "0101", "0102"]

      assert {:ok, wide} =
               Operations.create_vehicle_range(
                 organization.id,
                 operations_actor(organization.id),
                 %{
                   "first" => "98",
                   "last" => "102"
                 }
               )

      assert Enum.map(wide, & &1.vehicle_id) == ["98", "99", "100", "101", "102"]
    end

    test "the policy accessors report the enforced count and ID-length limits" do
      assert Operations.vehicle_range_limit() == 200
      assert Operations.vehicle_id_max_length() == 255
    end

    test "rejects a range of more than 200 vehicles and inserts nothing" do
      organization = organization_fixture()

      for attrs <- [
            %{"first" => "1", "last" => "201"},
            %{"first" => "0", "last" => "200"},
            %{"first" => "0098", "last" => "0300"}
          ] do
        assert {:error, {:invalid_range, message}} =
                 Operations.create_vehicle_range(
                   organization.id,
                   operations_actor(organization.id),
                   attrs
                 )

        assert is_binary(message) and message != ""
      end

      assert vehicle_ids(organization.id) == []
    end

    test "rejects reversed, non-numeric and missing bounds and inserts nothing" do
      organization = organization_fixture()

      for attrs <- [
            %{"first" => "5", "last" => "3"},
            %{"first" => "abc", "last" => "10"},
            %{"first" => "1", "last" => "1.5"},
            %{"first" => "1", "last" => "-5"},
            %{"first" => "", "last" => "10"},
            %{"first" => "1", "last" => "   "},
            %{"first" => "1"},
            %{"last" => "10"},
            %{"first" => 1, "last" => 5},
            %{}
          ] do
        assert {:error, {:invalid_range, message}} =
                 Operations.create_vehicle_range(
                   organization.id,
                   operations_actor(organization.id),
                   attrs
                 )

        assert is_binary(message) and message != ""
      end

      assert vehicle_ids(organization.id) == []
    end

    test "rejects a 256 digit bound and accepts one of exactly 255 digits" do
      organization = organization_fixture()

      over_long = String.duplicate("9", 256)

      assert {:error, {:invalid_range, message}} =
               Operations.create_vehicle_range(
                 organization.id,
                 operations_actor(organization.id),
                 %{
                   "first" => over_long,
                   "last" => over_long
                 }
               )

      assert is_binary(message) and message != ""
      assert vehicle_ids(organization.id) == []

      boundary = String.duplicate("0", 254) <> "1"

      assert {:ok, [vehicle]} =
               Operations.create_vehicle_range(
                 organization.id,
                 operations_actor(organization.id),
                 %{
                   "first" => boundary,
                   "last" => boundary
                 }
               )

      assert vehicle.vehicle_id == boundary
      assert String.length(vehicle.vehicle_id) == 255
      assert vehicle_ids(organization.id) == [boundary]
    end

    test "a collision names every existing ID and inserts nothing" do
      organization = organization_fixture()

      existing =
        vehicle_fixture(organization.id, %{"vehicle_id" => "0100", "vehicle_label" => "Keep me"})

      also = vehicle_fixture(organization.id, %{"vehicle_id" => "0102"})
      vehicle_fixture(organization.id, %{"vehicle_id" => "0200"})

      assert {:error, {:ids_taken, taken}} =
               Operations.create_vehicle_range(
                 organization.id,
                 operations_actor(organization.id),
                 %{
                   "first" => "0098",
                   "last" => "0102"
                 }
               )

      assert taken == ["0100", "0102"]
      assert vehicle_ids(organization.id) == ["0100", "0102", "0200"]

      reloaded = Repo.get(Vehicle, existing.id)
      assert reloaded.vehicle_id == "0100"
      assert reloaded.vehicle_label == "Keep me"
      assert reloaded.updated_at == existing.updated_at
      assert Repo.get(Vehicle, also.id)
    end

    test "another organization's vehicles do not collide with the range" do
      organization = organization_fixture()
      other = organization_fixture()
      vehicle_fixture(other.id, %{"vehicle_id" => "0100"})

      assert {:ok, vehicles} =
               Operations.create_vehicle_range(
                 organization.id,
                 operations_actor(organization.id),
                 %{
                   "first" => "0098",
                   "last" => "0102"
                 }
               )

      assert Enum.map(vehicles, & &1.vehicle_id) == ["0098", "0099", "0100", "0101", "0102"]
      assert vehicle_ids(other.id) == ["0100"]
    end

    test "a malformed, missing or foreign assignment target inserts nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign_type = vehicle_type_fixture(other.id)
      foreign_garage = garage_fixture(other.id)

      for attrs <- [
            %{"first" => "1", "last" => "5", "vehicle_type_id" => Ecto.UUID.generate()},
            %{"first" => "1", "last" => "5", "vehicle_type_id" => "not-a-uuid"},
            %{"first" => "1", "last" => "5", "vehicle_type_id" => foreign_type.id},
            %{"first" => "1", "last" => "5", "garage_id" => Ecto.UUID.generate()},
            %{"first" => "1", "last" => "5", "garage_id" => "not-a-uuid"},
            %{"first" => "1", "last" => "5", "garage_id" => foreign_garage.id}
          ] do
        assert {:error, :not_found} =
                 Operations.create_vehicle_range(
                   organization.id,
                   operations_actor(organization.id),
                   attrs
                 )

        assert vehicle_ids(organization.id) == []
      end

      assert vehicle_ids(other.id) == []
    end

    test "a blank assignment is unassigned and tenant params are ignored" do
      organization = organization_fixture()
      other = organization_fixture()
      vehicle_type_fixture(organization.id)

      assert {:ok, vehicles} =
               Operations.create_vehicle_range(
                 organization.id,
                 operations_actor(organization.id),
                 %{
                   "first" => "1",
                   "last" => "3",
                   "vehicle_type_id" => "",
                   "garage_id" => nil,
                   "organization_id" => other.id,
                   "updated_by_id" => Ecto.UUID.generate()
                 }
               )

      assert Enum.all?(vehicles, &is_nil(&1.vehicle_type_id))
      assert Enum.all?(vehicles, &is_nil(&1.garage_id))
      assert Enum.all?(vehicles, &(&1.organization_id == organization.id))
      assert Operations.list_vehicles(other.id, %{}) == []
    end

    test "a concurrent writer claiming part of the range leaves one whole batch" do
      Sandbox.unboxed_run(Repo, fn ->
        organization = organization_fixture(%{alias: "range-race-#{Ecto.UUID.generate()}"})
        actor = operations_actor(organization.id)
        owner = self()

        attrs = %{"first" => "1", "last" => "3"}

        try do
          for _ <- 1..2 do
            start_unboxed_task(fn ->
              result =
                Operations.create_vehicle_range(
                  organization.id,
                  actor,
                  attrs
                )

              send(owner, {:range_result, self(), result})
            end)
          end

          results =
            for _ <- 1..2 do
              assert_receive {:range_result, _pid, result}, @async_timeout
              result
            end

          assert [vehicles] = for({:ok, vehicles} <- results, do: vehicles)
          assert Enum.map(vehicles, & &1.vehicle_id) == ["1", "2", "3"]

          assert [{:error, {:ids_taken, taken}}] =
                   for(
                     {:error, {:ids_taken, taken}} <- results,
                     do: {:error, {:ids_taken, taken}}
                   )

          assert taken == ["1", "2", "3"]

          assert Repo.aggregate(
                   from(v in Vehicle, where: v.organization_id == ^organization.id),
                   :count,
                   :id
                 ) == 3
        after
          delete_operations_fixtures!(organization.id)
        end
      end)
    end
  end

  describe "update_vehicles/4" do
    test "sets a type on every listed vehicle and keeps the garage" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      previous_type = vehicle_type_fixture(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id)
      garage = garage_fixture(organization.id)

      first =
        vehicle_fixture(organization.id, %{
          "vehicle_type_id" => previous_type.id,
          "garage_id" => garage.id
        })

      second = vehicle_fixture(organization.id, %{"garage_id" => garage.id})

      assert {:ok, 2} =
               Operations.update_vehicles(organization.id, actor, [first.id, second.id], {
                 :vehicle_type_id,
                 vehicle_type.id
               })

      for id <- [first.id, second.id] do
        reloaded = Repo.get(Vehicle, id)
        assert reloaded.vehicle_type_id == vehicle_type.id
        assert reloaded.garage_id == garage.id
        assert reloaded.updated_by_id == actor.id
      end
    end

    test "a nil value clears only the named field" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id)
      garage = garage_fixture(organization.id)

      vehicle =
        vehicle_fixture(organization.id, %{
          "vehicle_type_id" => vehicle_type.id,
          "garage_id" => garage.id
        })

      assert {:ok, 1} =
               Operations.update_vehicles(organization.id, actor, [vehicle.id], {:garage_id, nil})

      reloaded = Repo.get(Vehicle, vehicle.id)
      assert reloaded.garage_id == nil
      assert reloaded.vehicle_type_id == vehicle_type.id
      assert reloaded.updated_by_id == actor.id
    end

    test "writes only the named field, the actor and the timestamp" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      garage = garage_fixture(organization.id)

      vehicle =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "batch-write",
          "vehicle_label" => "Untouched",
          "license_plate" => "OR-12345"
        })

      before = DateTime.utc_now()

      assert {:ok, 1} =
               Operations.update_vehicles(
                 organization.id,
                 actor,
                 [vehicle.id],
                 {:garage_id, garage.id}
               )

      reloaded = Repo.get(Vehicle, vehicle.id)
      assert reloaded.vehicle_id == "batch-write"
      assert reloaded.vehicle_label == "Untouched"
      assert reloaded.license_plate == "OR-12345"
      assert reloaded.vehicle_type_id == nil
      assert reloaded.garage_id == garage.id
      assert reloaded.inserted_at == vehicle.inserted_at
      assert reloaded.updated_by_id == actor.id
      assert DateTime.compare(reloaded.updated_at, before) != :lt
    end

    test "a foreign, unknown or malformed vehicle changes nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      actor = operations_actor(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id)
      mine = vehicle_fixture(organization.id)
      foreign = vehicle_fixture(other.id)

      for ids <- [
            [mine.id, foreign.id],
            [mine.id, Ecto.UUID.generate()],
            [mine.id, "not-a-uuid"],
            [mine.id, nil],
            [foreign.id]
          ] do
        assert {:error, :not_found} =
                 Operations.update_vehicles(organization.id, actor, ids, {
                   :vehicle_type_id,
                   vehicle_type.id
                 })
      end

      assert Repo.get(Vehicle, mine.id).vehicle_type_id == nil
      assert Repo.get(Vehicle, foreign.id).vehicle_type_id == nil
    end

    test "a foreign, unknown or malformed target changes nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      actor = operations_actor(organization.id)
      foreign_type = vehicle_type_fixture(other.id)
      foreign_garage = garage_fixture(other.id)
      type = vehicle_type_fixture(organization.id)
      garage = garage_fixture(organization.id)

      first = vehicle_fixture(organization.id, %{"vehicle_type_id" => type.id})
      second = vehicle_fixture(organization.id, %{"garage_id" => garage.id})

      for {field, target} <- [
            {:vehicle_type_id, foreign_type.id},
            {:vehicle_type_id, Ecto.UUID.generate()},
            {:vehicle_type_id, "not-a-uuid"},
            {:garage_id, foreign_garage.id},
            {:garage_id, Ecto.UUID.generate()}
          ] do
        assert {:error, :not_found} =
                 Operations.update_vehicles(organization.id, actor, [first.id, second.id], {
                   field,
                   target
                 })
      end

      assert Repo.get(Vehicle, first.id).vehicle_type_id == type.id
      assert Repo.get(Vehicle, second.id).garage_id == garage.id
    end

    test "duplicate ids count once and empty lists return zero" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      garage = garage_fixture(organization.id)
      first = vehicle_fixture(organization.id)
      second = vehicle_fixture(organization.id)

      assert {:ok, 2} =
               Operations.update_vehicles(
                 organization.id,
                 actor,
                 [first.id, second.id, first.id, second.id],
                 {:garage_id, garage.id}
               )

      assert {:ok, 1} =
               Operations.update_vehicles(
                 organization.id,
                 actor,
                 [second.id, String.upcase(second.id)],
                 {:garage_id, nil}
               )

      assert Repo.get(Vehicle, first.id).garage_id == garage.id
      assert Repo.get(Vehicle, second.id).garage_id == nil

      assert {:ok, 0} =
               Operations.update_vehicles(organization.id, actor, [], {:garage_id, garage.id})

      assert Repo.get(Vehicle, first.id).garage_id == garage.id
    end

    test "an unsupported field is refused and changes nothing" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "field-guard"})

      assert {:error, :not_found} =
               Operations.update_vehicles(organization.id, actor, [vehicle.id], {
                 :vehicle_id,
                 "renamed"
               })

      assert {:error, :not_found} =
               Operations.update_vehicles(
                 organization.id,
                 actor,
                 [vehicle.id],
                 {:organization_id, nil}
               )

      reloaded = Repo.get(Vehicle, vehicle.id)
      assert reloaded.vehicle_id == "field-guard"
      assert reloaded.organization_id == organization.id
    end

    test "isolates organizations" do
      organization = organization_fixture()
      other = organization_fixture()
      vehicle_type = vehicle_type_fixture(organization.id)
      foreign = vehicle_fixture(other.id)

      assert {:error, :not_found} =
               Operations.update_vehicles(
                 organization.id,
                 operations_actor(organization.id),
                 [foreign.id],
                 {
                   :vehicle_type_id,
                   vehicle_type.id
                 }
               )

      assert Repo.get(Vehicle, foreign.id).vehicle_type_id == nil
      assert Enum.map(Operations.list_vehicles(other.id, %{}), & &1.id) == [foreign.id]
    end
  end

  describe "delete_vehicles/3" do
    test "deletes every listed vehicle and leaves the others" do
      organization = organization_fixture()
      first = vehicle_fixture(organization.id)
      second = vehicle_fixture(organization.id)
      kept = vehicle_fixture(organization.id)

      assert {:ok, 2} =
               Operations.delete_vehicles(organization.id, operations_actor(organization.id), [
                 first.id,
                 second.id
               ])

      assert Repo.get(Vehicle, first.id) == nil
      assert Repo.get(Vehicle, second.id) == nil
      assert vehicle_ids(organization.id) == [kept.vehicle_id]
    end

    test "a foreign, unknown or malformed vehicle deletes nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      mine = vehicle_fixture(organization.id)
      foreign = vehicle_fixture(other.id)

      for ids <- [
            [mine.id, foreign.id],
            [mine.id, Ecto.UUID.generate()],
            [mine.id, "not-a-uuid"],
            [mine.id, nil],
            [foreign.id]
          ] do
        assert {:error, :not_found} =
                 Operations.delete_vehicles(
                   organization.id,
                   operations_actor(organization.id),
                   ids
                 )
      end

      assert Repo.get(Vehicle, mine.id)
      assert Repo.get(Vehicle, foreign.id)
    end

    test "a selected vehicle deleted before the request rolls the rest back" do
      organization = organization_fixture()
      gone = vehicle_fixture(organization.id)
      remaining = vehicle_fixture(organization.id)

      assert {:ok, 1} =
               Operations.delete_vehicles(organization.id, operations_actor(organization.id), [
                 gone.id
               ])

      assert {:error, :not_found} =
               Operations.delete_vehicles(organization.id, operations_actor(organization.id), [
                 gone.id,
                 remaining.id
               ])

      assert Repo.get(Vehicle, remaining.id)
      assert vehicle_ids(organization.id) == [remaining.vehicle_id]
    end

    test "duplicate ids count once and an empty list returns zero" do
      organization = organization_fixture()
      vehicle = vehicle_fixture(organization.id)
      other = vehicle_fixture(organization.id)

      assert {:ok, 0} =
               Operations.delete_vehicles(organization.id, operations_actor(organization.id), [])

      assert Repo.get(Vehicle, vehicle.id)

      assert {:ok, 1} =
               Operations.delete_vehicles(organization.id, operations_actor(organization.id), [
                 vehicle.id,
                 vehicle.id,
                 String.upcase(vehicle.id)
               ])

      assert Repo.get(Vehicle, vehicle.id) == nil
      assert Repo.get(Vehicle, other.id)
    end

    test "isolates organizations" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign = vehicle_fixture(other.id)

      assert {:error, :not_found} =
               Operations.delete_vehicles(organization.id, operations_actor(organization.id), [
                 foreign.id
               ])

      assert Repo.get(Vehicle, foreign.id)

      assert {:ok, 1} =
               Operations.delete_vehicles(other.id, operations_actor(other.id), [foreign.id])

      assert Repo.get(Vehicle, foreign.id) == nil
    end
  end

  describe "fleet_summary/1" do
    test "buckets every garage and type pair including the unassigned values" do
      organization = organization_fixture()
      alpha = garage_fixture(organization.id, %{"name" => "Alpha Yard"})
      beta = garage_fixture(organization.id, %{"name" => "Beta Depot"})
      bus = vehicle_type_fixture(organization.id, %{"name" => "Bus"})
      coach = vehicle_type_fixture(organization.id, %{"name" => "Coach"})

      for _ <- 1..2,
          do:
            vehicle_fixture(organization.id, %{
              "garage_id" => alpha.id,
              "vehicle_type_id" => bus.id
            })

      vehicle_fixture(organization.id, %{"garage_id" => alpha.id, "vehicle_type_id" => coach.id})
      vehicle_fixture(organization.id, %{"garage_id" => beta.id})
      vehicle_fixture(organization.id, %{"vehicle_type_id" => bus.id})
      vehicle_fixture(organization.id)

      summary = Operations.fleet_summary(organization.id)

      assert Enum.map(summary, &{garage_name(&1.garage), type_name(&1.vehicle_type), &1.count}) ==
               [
                 {"Alpha Yard", "Bus", 2},
                 {"Alpha Yard", "Coach", 1},
                 {"Beta Depot", nil, 1},
                 {nil, "Bus", 1},
                 {nil, nil, 1}
               ]

      assert Enum.sum(Enum.map(summary, & &1.count)) == 6
      assert %Garage{id: alpha_id} = Enum.at(summary, 0).garage
      assert alpha_id == alpha.id
      assert %VehicleType{id: bus_id} = Enum.at(summary, 0).vehicle_type
      assert bus_id == bus.id
    end

    test "totals match the organization's vehicles and ignore other organizations" do
      organization = organization_fixture()
      other = organization_fixture()
      garage = garage_fixture(organization.id)

      for _ <- 1..3, do: vehicle_fixture(organization.id, %{"garage_id" => garage.id})
      for _ <- 1..2, do: vehicle_fixture(organization.id)
      for _ <- 1..4, do: vehicle_fixture(other.id)

      summary = Operations.fleet_summary(organization.id)

      assert Enum.sum(Enum.map(summary, & &1.count)) == 5

      assert Enum.sum(Enum.map(summary, & &1.count)) ==
               Repo.aggregate(
                 from(v in Vehicle, where: v.organization_id == ^organization.id),
                 :count,
                 :id
               )

      assert length(Operations.list_vehicles(organization.id, %{})) == 5

      assert Enum.sum(Enum.map(Operations.fleet_summary(other.id), & &1.count)) == 4
    end

    test "returns no buckets for an organization without vehicles" do
      organization = organization_fixture()

      assert Operations.fleet_summary(organization.id) == []
      assert Operations.fleet_summary(Ecto.UUID.generate()) == []
    end
  end

  defp vehicle_ids(organization_id) do
    Vehicle
    |> where([v], v.organization_id == ^organization_id)
    |> order_by([v], asc: v.vehicle_id)
    |> select([v], v.vehicle_id)
    |> Repo.all()
  end

  defp vehicle_id_count(organization_id) do
    Vehicle
    |> where([v], v.organization_id == ^organization_id)
    |> Repo.aggregate(:count, :id)
  end

  defp garage_name(nil), do: nil
  defp garage_name(%Garage{name: name}), do: name

  defp type_name(nil), do: nil
  defp type_name(%VehicleType{name: name}), do: name

  # The same unboxed-task pattern the single-vehicle races use: each task owns a
  # real connection so two transactions can contend for the same rows.
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

  defp delete_operations_fixtures!(organization_id) do
    Repo.delete_all(from(v in Vehicle, where: v.organization_id == ^organization_id))
    Repo.delete_all(from(t in VehicleType, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(g in Garage, where: g.organization_id == ^organization_id))

    editor_user_ids =
      Repo.all(
        from(m in UserOrgMembership,
          where: m.organization_id == ^organization_id,
          select: m.user_id
        )
      )

    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
    Repo.delete_all(from(u in User, where: u.id in ^editor_user_ids))
  end
end
