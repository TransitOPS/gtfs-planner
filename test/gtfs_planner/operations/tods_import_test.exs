defmodule GtfsPlanner.Operations.TodsImportTest do
  @moduledoc """
  Organization-scoped TODS import previews and atomic applies.

  Every expected value is written from the TODS specification, the prepared
  contract (AC-9 to AC-12) and the field-preservation rules; no production
  function computes an expectation. Cases invoke the real
  `GtfsPlanner.Operations`/`Repo` composition and compare stored rows field by
  field before and after apply, so a wipe of an untouched field, a lost UUID, a
  duplicate insert or a partial/stale commit fails the suite.
  """

  use GtfsPlanner.DataCase, async: false

  @async_timeout 5_000

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Operations.Vehicle
  alias GtfsPlanner.Operations.VehicleType
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures

  @fixture_dir Path.expand("../../fixtures/tods", __DIR__)
  @garage_file "stops_supplement.txt"
  @vehicle_file "vehicles.txt"

  defp fixture(name), do: File.read!(Path.join(@fixture_dir, name))

  defp parsed!(kind, content, file) do
    assert {:ok, parsed} = Tods.parse(kind, file, content)
    parsed
  end

  describe "preview_tods_import/2" do
    test "reports the published TODS example's new garage as missing coordinates in an empty organization" do
      organization = organization_fixture()
      file = "tods_example_stops_supplement.txt"
      parsed = parsed!(:garages, fixture(file), file)

      assert Operations.preview_tods_import(organization.id, parsed) == %{
               kind: :garages,
               add: [],
               update: [],
               skipped: [
                 %{
                   row: 3,
                   id: "garage-waypoint",
                   reason: "Changes or adds a public stop; not imported."
                 }
               ],
               errors: [
                 %{row: 2, id: "garage", reason: "New garage needs stop_lat and stop_lon."}
               ],
               ignored_columns: ["location_type"]
             }

      assert garages(organization.id) == []
    end

    test "classifies the published TODS example's garage as an update when it already exists" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id, %{"garage_id" => "garage", "name" => "Existing"})
      file = "tods_example_stops_supplement.txt"
      parsed = parsed!(:garages, fixture(file), file)

      preview = Operations.preview_tods_import(organization.id, parsed)

      assert preview.add == []
      assert preview.update == ["garage"]
      assert preview.errors == []

      assert preview.skipped == [
               %{
                 row: 3,
                 id: "garage-waypoint",
                 reason: "Changes or adds a public stop; not imported."
               }
             ]

      assert Repo.get(Garage, garage.id).updated_by_id == garage.updated_by_id
    end

    test "classifies the extended garage fixture against stored records and lists ignored columns" do
      organization = organization_fixture()
      garage_fixture(organization.id, %{"garage_id" => "garage_main", "name" => "Main garage"})
      parsed = parsed!(:garages, fixture(@garage_file), @garage_file)

      preview = Operations.preview_tods_import(organization.id, parsed)

      assert preview.add == ["garage_east"]
      assert preview.update == ["garage_main"]

      assert Enum.map(preview.skipped, & &1.id) == ["garage-waypoint", "stop_401", "garage_old"]
      assert preview.errors == []
      assert preview.ignored_columns == ["location_type", "zone_id"]
    end

    test "matches IDs only inside the caller's organization" do
      organization = organization_fixture()
      other = organization_fixture()
      garage_fixture(other.id, %{"garage_id" => "garage_main"})
      parsed = parsed!(:garages, fixture(@garage_file), @garage_file)

      preview = Operations.preview_tods_import(organization.id, parsed)

      assert preview.add == ["garage_main", "garage_east"]
      assert preview.update == []
    end
  end

  describe "apply_tods_import/4 inserts" do
    test "creates garages from the extended fixture with their named fields and no address" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      parsed = parsed!(:garages, fixture(@garage_file), @garage_file)
      preview = Operations.preview_tods_import(organization.id, parsed)

      assert {:ok, %{added: 2, updated: 0}} =
               Operations.apply_tods_import(organization.id, actor, parsed, preview)

      assert [main, east] = Operations.list_garages(organization.id)
      assert main.garage_id == "garage_east"
      assert main.name == "East depot"
      assert main.address == nil
      assert main.lat == Decimal.new("45.5231")
      assert main.lon == Decimal.new("-122.6765")
      assert main.organization_id == organization.id
      assert main.updated_by_id == actor.id

      assert east.garage_id == "garage_main"
      assert east.name == "Main garage"
      assert east.lat == Decimal.new("45.5121")
      assert east.updated_by_id == actor.id
    end

    test "names a new garage from its stop_id when stop_name is absent or blank" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)

      parsed =
        parsed!(
          :garages,
          "stop_id,stop_name,stop_lat,stop_lon,TODS_location_type\n" <>
            "garage_named,,45.5,-122.6,garage\ngarage_absent,,45.6,-122.7,garage\n",
          @garage_file
        )

      preview = Operations.preview_tods_import(organization.id, parsed)

      assert {:ok, %{added: 2, updated: 0}} =
               Operations.apply_tods_import(organization.id, actor, parsed, preview)

      names = organization.id |> garages() |> Map.new(&{&1.garage_id, &1.name})
      assert names == %{"garage_absent" => "garage_absent", "garage_named" => "garage_named"}
    end

    test "creates vehicles with their label and plate and no assignment" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      file = "tods_example_vehicles.txt"
      parsed = parsed!(:vehicles, fixture(file), file)
      preview = Operations.preview_tods_import(organization.id, parsed)

      assert {:ok, %{added: 2, updated: 0}} =
               Operations.apply_tods_import(organization.id, actor, parsed, preview)

      assert Enum.map(Operations.list_vehicles(organization.id, %{}), & &1.vehicle_id) ==
               ["bus-1", "bus-2"]

      vehicle = Repo.get_by(Vehicle, organization_id: organization.id, vehicle_id: "bus-1")
      assert vehicle.vehicle_label == "Old Reliable"
      assert vehicle.license_plate == "OR-E285104"
      assert vehicle.vehicle_type_id == nil
      assert vehicle.garage_id == nil
      assert vehicle.updated_by_id == actor.id
    end

    test "an empty accepted set applies as a no-op" do
      organization = organization_fixture()
      parsed = parsed!(:vehicles, "vehicle_id,vehicle_label\n", @vehicle_file)
      preview = Operations.preview_tods_import(organization.id, parsed)

      assert preview.add == [] and preview.update == [] and preview.errors == []

      assert {:ok, %{added: 0, updated: 0}} =
               Operations.apply_tods_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert vehicles(organization.id) == []
    end
  end

  describe "apply_tods_import/4 field preservation" do
    test "re-importing vehicles keeps their type and garage and updates only carried fields" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Bus"})
      garage = garage_fixture(organization.id)

      vehicle =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "bus-1",
          "vehicle_label" => "Old label",
          "vehicle_type_id" => vehicle_type.id,
          "garage_id" => garage.id
        })

      file = "tods_example_vehicles.txt"
      parsed = parsed!(:vehicles, fixture(file), file)
      preview = Operations.preview_tods_import(organization.id, parsed)

      assert {:ok, %{added: 1, updated: 1}} =
               Operations.apply_tods_import(organization.id, actor, parsed, preview)

      reloaded = Repo.get(Vehicle, vehicle.id)
      assert reloaded.id == vehicle.id
      assert reloaded.inserted_at == vehicle.inserted_at
      assert reloaded.vehicle_label == "Old Reliable"
      assert reloaded.license_plate == "OR-E285104"
      assert reloaded.vehicle_type_id == vehicle_type.id
      assert reloaded.garage_id == garage.id
      assert reloaded.updated_by_id == actor.id
    end

    test "re-importing garages preserves their address and never writes an address" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)

      garage =
        garage_fixture(organization.id, %{
          "garage_id" => "garage_main",
          "name" => "Old name",
          "address" => "123 Main St",
          "lat" => Decimal.new("10.0"),
          "lon" => Decimal.new("20.0")
        })

      parsed = parsed!(:garages, fixture(@garage_file), @garage_file)
      preview = Operations.preview_tods_import(organization.id, parsed)

      assert {:ok, %{added: 1, updated: 1}} =
               Operations.apply_tods_import(organization.id, actor, parsed, preview)

      reloaded = Repo.get(Garage, garage.id)
      assert reloaded.id == garage.id
      assert reloaded.address == "123 Main St"
      assert reloaded.name == "Main garage"
      assert reloaded.lat == Decimal.new("45.5121")
      assert reloaded.lon == Decimal.new("-122.6587")
      assert reloaded.updated_by_id == actor.id
    end

    test "a blank vehicle field clears, an absent column preserves, and a blank stop_name preserves" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)

      garage =
        garage_fixture(organization.id, %{
          "garage_id" => "garage_main",
          "name" => "Stored name",
          "lat" => Decimal.new("10.0"),
          "lon" => Decimal.new("20.0")
        })

      vehicle =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "bus-1",
          "vehicle_label" => "Has label",
          "license_plate" => "KEEP"
        })

      garage_parsed =
        parsed!(
          :garages,
          "stop_id,stop_name,TODS_location_type\ngarage_main,,garage\n",
          @garage_file
        )

      garage_preview = Operations.preview_tods_import(organization.id, garage_parsed)

      assert {:ok, %{added: 0, updated: 1}} =
               Operations.apply_tods_import(
                 organization.id,
                 actor,
                 garage_parsed,
                 garage_preview
               )

      reloaded_garage = Repo.get(Garage, garage.id)
      assert reloaded_garage.name == "Stored name"
      assert reloaded_garage.lat == Decimal.new("10.0")
      assert reloaded_garage.lon == Decimal.new("20.0")

      vehicle_parsed = parsed!(:vehicles, "vehicle_id,vehicle_label\nbus-1,\n", @vehicle_file)
      vehicle_preview = Operations.preview_tods_import(organization.id, vehicle_parsed)

      assert {:ok, %{added: 0, updated: 1}} =
               Operations.apply_tods_import(
                 organization.id,
                 actor,
                 vehicle_parsed,
                 vehicle_preview
               )

      reloaded_vehicle = Repo.get(Vehicle, vehicle.id)
      assert reloaded_vehicle.vehicle_label == nil
      assert reloaded_vehicle.license_plate == "KEEP"

      absent_parsed = parsed!(:vehicles, "vehicle_id\nbus-1\n", @vehicle_file)
      absent_preview = Operations.preview_tods_import(organization.id, absent_parsed)

      assert {:ok, %{added: 0, updated: 1}} =
               Operations.apply_tods_import(
                 organization.id,
                 actor,
                 absent_parsed,
                 absent_preview
               )

      assert Repo.get(Vehicle, vehicle.id).vehicle_label == nil
    end

    test "a no-op update still records the acting user without changing stored fields" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      garage = garage_fixture(organization.id, %{"garage_id" => "garage", "name" => "Existing"})
      file = "tods_example_stops_supplement.txt"
      parsed = parsed!(:garages, fixture(file), file)
      preview = Operations.preview_tods_import(organization.id, parsed)

      assert {:ok, %{added: 0, updated: 1}} =
               Operations.apply_tods_import(organization.id, actor, parsed, preview)

      reloaded = Repo.get(Garage, garage.id)
      assert reloaded.id == garage.id
      assert reloaded.name == "Existing"
      assert reloaded.address == garage.address
      assert reloaded.updated_by_id == actor.id
    end

    test "import never deletes records absent from the file" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      kept_one = vehicle_fixture(organization.id, %{"vehicle_id" => "bus-2"})
      kept_two = vehicle_fixture(organization.id, %{"vehicle_id" => "bus-3"})
      parsed = parsed!(:vehicles, "vehicle_id,vehicle_label\nbus-1,New\n", @vehicle_file)
      preview = Operations.preview_tods_import(organization.id, parsed)

      assert {:ok, %{added: 1, updated: 0}} =
               Operations.apply_tods_import(organization.id, actor, parsed, preview)

      assert Repo.get(Vehicle, kept_one.id)
      assert Repo.get(Vehicle, kept_two.id)
      assert Enum.sort(vehicles(organization.id)) == ["bus-1", "bus-2", "bus-3"]
    end
  end

  describe "apply_tods_import/4 idempotence" do
    test "a second apply of the same file adds nothing" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      file = "tods_example_vehicles.txt"
      parsed = parsed!(:vehicles, fixture(file), file)

      first_preview = Operations.preview_tods_import(organization.id, parsed)
      assert first_preview.add == ["bus-1", "bus-2"]

      assert {:ok, %{added: 2, updated: 0}} =
               Operations.apply_tods_import(organization.id, actor, parsed, first_preview)

      second_preview = Operations.preview_tods_import(organization.id, parsed)
      assert second_preview.add == []
      assert second_preview.update == ["bus-1", "bus-2"]

      assert {:ok, %{added: 0, updated: 2}} =
               Operations.apply_tods_import(organization.id, actor, parsed, second_preview)

      assert vehicles(organization.id) == ["bus-1", "bus-2"]
    end
  end

  describe "apply_tods_import/4 blocking" do
    test "a blank vehicle_id on the last row makes preview and apply invalid with zero writes" do
      organization = organization_fixture()
      content = "vehicle_id,vehicle_label\nbus-1,Old Reliable\nbus-2,Buster\n,Orphan\n"
      parsed = parsed!(:vehicles, content, @vehicle_file)
      preview = Operations.preview_tods_import(organization.id, parsed)

      assert preview.add == ["bus-1", "bus-2"]
      assert preview.errors == [%{row: 4, id: nil, reason: "Vehicle ID is required."}]

      assert {:error, {:invalid, returned}} =
               Operations.apply_tods_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert returned.errors == preview.errors
      assert vehicles(organization.id) == []
    end

    test "a record created between preview and apply returns preview_changed with zero writes" do
      organization = organization_fixture()

      parsed =
        parsed!(:vehicles, "vehicle_id,vehicle_label\nbus-1,One\nbus-2,Two\n", @vehicle_file)

      preview = Operations.preview_tods_import(organization.id, parsed)
      assert preview.add == ["bus-1", "bus-2"]

      between = vehicle_fixture(organization.id, %{"vehicle_id" => "bus-1"})

      assert {:error, {:preview_changed, fresh}} =
               Operations.apply_tods_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert fresh.add == ["bus-2"]
      assert fresh.update == ["bus-1"]
      assert vehicles(organization.id) == ["bus-1"]
      assert Repo.get(Vehicle, between.id).vehicle_label == between.vehicle_label
    end

    test "a crafted preview whose add or update set differs changes nothing" do
      organization = organization_fixture()
      parsed = parsed!(:vehicles, "vehicle_id,vehicle_label\nbus-1,One\n", @vehicle_file)
      preview = Operations.preview_tods_import(organization.id, parsed)

      for forged <- [%{preview | add: []}, %{preview | update: ["bus-1"]}] do
        assert {:error, {:preview_changed, _fresh}} =
                 Operations.apply_tods_import(
                   organization.id,
                   operations_actor(organization.id),
                   parsed,
                   forged
                 )

        assert vehicles(organization.id) == []
      end
    end
  end

  describe "apply_tods_import/4 organization isolation" do
    test "matches, inserts and updates only the caller's organization" do
      organization = organization_fixture()
      other = organization_fixture()
      other_garage = garage_fixture(other.id, %{"garage_id" => "garage_main", "name" => "Other"})
      parsed = parsed!(:garages, fixture(@garage_file), @garage_file)

      preview = Operations.preview_tods_import(organization.id, parsed)
      assert preview.update == []
      assert preview.add == ["garage_main", "garage_east"]

      assert {:ok, %{added: 2, updated: 0}} =
               Operations.apply_tods_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert Enum.sort(Enum.map(garages(organization.id), & &1.garage_id)) ==
               ["garage_east", "garage_main"]

      assert [%Garage{id: other_id, name: "Other"}] = garages(other.id)
      assert other_id == other_garage.id
      assert Repo.get(Garage, other_garage.id).updated_by_id == other_garage.updated_by_id
    end
  end

  describe "apply_tods_import/4 concurrency" do
    test "a competing insert after the recompute rolls back every write and returns a fresh preview" do
      Sandbox.unboxed_run(Repo, fn ->
        organization = organization_fixture(%{alias: "tods-race-#{Ecto.UUID.generate()}"})
        actor = operations_actor(organization.id)
        owner = self()

        existing =
          garage_fixture(organization.id, %{
            "garage_id" => "garage_main",
            "name" => "Stored name"
          })

        parsed =
          parsed!(
            :garages,
            "stop_id,stop_name,stop_lat,stop_lon,TODS_location_type\n" <>
              "garage_main,Changed name,45.5,-122.6,garage\ngarage_new,New depot,45.6,-122.7,garage\n",
            @garage_file
          )

        preview = Operations.preview_tods_import(organization.id, parsed)
        assert preview.update == ["garage_main"]
        assert preview.add == ["garage_new"]

        try do
          {competing, competing_id} =
            start_unboxed_task(fn ->
              Repo.transaction(fn ->
                {1, _} =
                  Repo.insert_all(Garage, [
                    %{
                      id: Ecto.UUID.generate(),
                      organization_id: organization.id,
                      garage_id: "garage_new",
                      name: "Competing",
                      address: nil,
                      lat: Decimal.new("1.0"),
                      lon: Decimal.new("2.0"),
                      inserted_at: DateTime.utc_now(),
                      updated_at: DateTime.utc_now()
                    }
                  ])

                send(owner, :competing_inserted)

                receive do
                  :commit -> :ok
                end
              end)
            end)

          try do
            assert_receive :competing_inserted, @async_timeout

            {apply_task, apply_id} =
              start_unboxed_task(fn ->
                %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
                send(owner, {:apply_backend, backend_pid})

                result = Operations.apply_tods_import(organization.id, actor, parsed, preview)
                send(owner, {:apply_result, result})
              end)

            try do
              apply_ref = Process.monitor(apply_task)
              assert_receive {:apply_backend, backend_pid}, @async_timeout

              # The apply has recomputed the preview (uncommitted row invisible),
              # passed the plan comparison and now blocks inserting garage_new.
              assert_postgres_lock_wait!(backend_pid)
              send(competing, :commit)

              assert_receive {:apply_result, {:error, {:preview_changed, fresh}}},
                             @async_timeout

              assert fresh.add == []
              assert fresh.update == ["garage_main", "garage_new"]

              assert_receive {:DOWN, ^apply_ref, :process, ^apply_task, :normal}, @async_timeout
            after
              stop_supervised_task(apply_id)
            end

            # The earlier update to garage_main was rolled back with the batch.
            assert Repo.get(Garage, existing.id).name == "Stored name"

            competing_garage =
              Repo.get_by(Garage, organization_id: organization.id, garage_id: "garage_new")

            assert competing_garage.name == "Competing"
          after
            send(competing, :commit)
            stop_supervised_task(competing_id)
          end
        after
          delete_operations_fixtures!(organization.id)
        end
      end)
    end
  end

  defp garages(organization_id) do
    Garage
    |> where([g], g.organization_id == ^organization_id)
    |> order_by([g], asc: g.garage_id)
    |> Repo.all()
  end

  defp vehicles(organization_id) do
    Vehicle
    |> where([v], v.organization_id == ^organization_id)
    |> order_by([v], asc: v.vehicle_id)
    |> select([v], v.vehicle_id)
    |> Repo.all()
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

  defp stop_supervised_task(child_id) do
    case stop_supervised(child_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp assert_postgres_lock_wait!(backend_pid, attempts_remaining \\ 200)

  defp assert_postgres_lock_wait!(_backend_pid, 0) do
    flunk("the apply never blocked on the competing garage insert")
  end

  defp assert_postgres_lock_wait!(backend_pid, attempts_remaining) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT wait_event_type
        FROM pg_stat_activity
        WHERE pid = $1
        """,
        [backend_pid]
      )

    case rows do
      [["Lock"]] ->
        :ok

      _other ->
        receive do
        after
          10 -> assert_postgres_lock_wait!(backend_pid, attempts_remaining - 1)
        end
    end
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
