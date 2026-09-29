defmodule GtfsPlanner.Operations.InUseGuardTest do
  @moduledoc """
  The garage and vehicle-type delete guard, and the driving times a garage owns.

  A delete is refused while a vehicle, a `block_attributes` row or a
  `route_operating_settings` row references the parent, and the refusal names
  all three counts. A garage nothing else references goes with its
  `deadhead_times` rows, whose refs hold the garage UUID (CR-7); a garage used
  only as `blocking_settings.default_garage_id` is a default, not a reference,
  so it deletes and the setting becomes `nil`.

  The concurrency case runs on an unboxed connection and commits its own
  disposable fixtures, which `on_exit` deletes: the racing insert is invisible to
  the sandboxed transaction that runs the delete, so the row must survive and the
  delete must be refused by the foreign key rather than raising.
  """

  use GtfsPlanner.DataCase, async: false

  @async_timeout 5_000

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DeadheadTimes
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.RouteOperatingSetting
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Vehicle
  alias GtfsPlanner.Operations.VehicleType
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup :scope

  defp scope(_context) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    %{organization: organization, version: version}
  end

  describe "delete_garage/2 with a block or route reference" do
    test "a garage a block and a route name is refused, named and left intact", ctx do
      %{organization: organization, version: version} = ctx
      garage = garage_fixture(organization.id)

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "weekday",
        block_id: "12",
        garage_id: garage.id
      })

      route_operating_setting_fixture(organization.id, version.id, %{
        route_id: "10",
        garage_id: garage.id
      })

      assert {:error, {:in_use, %{vehicles: 0, blocks: 1, routes: 1}}} =
               Operations.delete_garage(organization.id, garage.id)

      assert Repo.get(Garage, garage.id)
      assert Repo.aggregate(BlockAttribute, :count, :id) == 1
      assert Repo.aggregate(RouteOperatingSetting, :count, :id) == 1
    end

    test "a block spanning several services is named once", ctx do
      %{organization: organization, version: version} = ctx
      garage = garage_fixture(organization.id)

      for service_id <- ["weekday", "saturday"] do
        block_attribute_fixture(organization.id, version.id, %{
          service_id: service_id,
          block_id: "12",
          garage_id: garage.id
        })
      end

      assert {:error, {:in_use, %{vehicles: 0, blocks: 1, routes: 0}}} =
               Operations.delete_garage(organization.id, garage.id)
    end

    test "a garage with vehicles keeps the existing count shape", ctx do
      %{organization: organization} = ctx
      garage = garage_fixture(organization.id)
      vehicle = vehicle_fixture(organization.id, %{"garage_id" => garage.id})

      assert {:error, {:in_use, %{vehicles: 1, blocks: 0, routes: 0}}} =
               Operations.delete_garage(organization.id, garage.id)

      assert Repo.get(Garage, garage.id)
      assert Repo.get(Vehicle, vehicle.id)
    end
  end

  describe "delete_garage/2 driving times" do
    test "an unreferenced garage is deleted with the rows naming it as either ref", ctx do
      %{organization: organization, version: version} = ctx
      garage = garage_fixture(organization.id)
      ref = DeadheadTimes.encode_ref({:garage, garage.id})
      other_ref = DeadheadTimes.encode_ref({:stop, "depot"})

      deleted_from =
        deadhead_time_fixture(organization.id, version.id, %{
          from_ref: ref,
          to_ref: {:stop, "depot"},
          minutes: 7
        })

      deleted_to =
        deadhead_time_fixture(organization.id, version.id, %{
          from_ref: {:stop, "depot"},
          to_ref: ref,
          minutes: 9
        })

      kept =
        deadhead_time_fixture(organization.id, version.id, %{
          from_ref: {:stop, "depot"},
          to_ref: {:stop, "yard"},
          minutes: 3
        })

      assert {:ok, %Garage{}} = Operations.delete_garage(organization.id, garage.id)

      assert Repo.get(DeadheadTime, deleted_from.id) == nil
      assert Repo.get(DeadheadTime, deleted_to.id) == nil
      assert Repo.get(DeadheadTime, kept.id)
      assert other_ref == "stop:depot"
    end

    test "another garage's rows with a similar public ID stay", ctx do
      %{organization: organization, version: version} = ctx
      garage = garage_fixture(organization.id, %{"garage_id" => "garage_main"})
      other = garage_fixture(organization.id, %{"garage_id" => "garage_main_2"})

      kept =
        deadhead_time_fixture(organization.id, version.id, %{
          from_ref: {:garage, other.id},
          to_ref: {:stop, "depot"},
          minutes: 4
        })

      assert {:ok, %Garage{}} = Operations.delete_garage(organization.id, garage.id)
      assert Repo.get(DeadheadTime, kept.id)
    end

    test "a refused delete restores the driving times it removed", ctx do
      %{organization: organization, version: version} = ctx
      garage = garage_fixture(organization.id)

      kept =
        deadhead_time_fixture(organization.id, version.id, %{
          from_ref: {:garage, garage.id},
          to_ref: {:stop, "depot"},
          minutes: 5
        })

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "weekday",
        block_id: "12",
        garage_id: garage.id
      })

      assert {:error, {:in_use, %{vehicles: 0, blocks: 1, routes: 0}}} =
               Operations.delete_garage(organization.id, garage.id)

      assert Repo.get(DeadheadTime, kept.id)
      assert Repo.get(Garage, garage.id)
    end

    test "a garage used only as the default garage is deleted and the setting becomes nil", ctx do
      %{organization: organization, version: version} = ctx
      garage = garage_fixture(organization.id)

      {:ok, _setting} =
        Blocking.update_settings(organization.id, version.id, %{
          min_layover_minutes: 5,
          pull_out_buffer_minutes: 0,
          interlining: :any,
          deadhead_speed_kmh: 30,
          deadhead_circuity: Decimal.new("1.3"),
          default_garage_id: garage.id
        })

      assert {:ok, %Garage{}} = Operations.delete_garage(organization.id, garage.id)

      assert Blocking.get_settings(organization.id, version.id).default_garage_id ==
               nil
    end
  end

  describe "delete_vehicle_type/2 with a block or route reference" do
    test "a type a route requires is refused and named", ctx do
      %{organization: organization, version: version} = ctx
      vehicle_type = vehicle_type_fixture(organization.id)

      route_operating_setting_fixture(organization.id, version.id, %{
        route_id: "10",
        required_vehicle_type_id: vehicle_type.id
      })

      assert {:error, {:in_use, %{vehicles: 0, blocks: 0, routes: 1}}} =
               Operations.delete_vehicle_type(organization.id, vehicle_type.id)

      assert Repo.get(VehicleType, vehicle_type.id)
      assert Repo.aggregate(RouteOperatingSetting, :count, :id) == 1
    end

    test "a type a block requires is refused and named", ctx do
      %{organization: organization, version: version} = ctx
      vehicle_type = vehicle_type_fixture(organization.id)

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "weekday",
        block_id: "7",
        vehicle_type_id: vehicle_type.id
      })

      assert {:error, {:in_use, %{vehicles: 0, blocks: 1, routes: 0}}} =
               Operations.delete_vehicle_type(organization.id, vehicle_type.id)

      assert Repo.get(VehicleType, vehicle_type.id)
    end
  end

  describe "in-use counts" do
    test "counts are zero for a garage nothing references", ctx do
      %{organization: organization} = ctx
      garage = garage_fixture(organization.id)

      assert Operations.garage_in_use_counts(organization.id, garage.id) ==
               %{vehicles: 0, blocks: 0, routes: 0}

      refute Operations.in_use?(Operations.garage_in_use_counts(organization.id, garage.id))
    end

    test "counts name every referring kind at once", ctx do
      %{organization: organization, version: version} = ctx
      garage = garage_fixture(organization.id)

      vehicle_fixture(organization.id, %{"garage_id" => garage.id})

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "weekday",
        block_id: "12",
        garage_id: garage.id
      })

      route_operating_setting_fixture(organization.id, version.id, %{
        route_id: "10",
        garage_id: garage.id
      })

      counts = Operations.garage_in_use_counts(organization.id, garage.id)
      assert counts == %{vehicles: 1, blocks: 1, routes: 1}
      assert Operations.in_use?(counts)
    end
  end

  describe "a reference inserted while the delete runs" do
    test "the delete is refused rather than raising, and the racing row survives" do
      # The racing connection and the deleter both run outside the sandbox, so
      # their fixtures are committed for real and removed again in `on_exit`;
      # a sandboxed row would be invisible to the racer and its insert would fail
      # its foreign key instead of racing the delete.
      Sandbox.unboxed_run(Repo, fn ->
        organization = organization_fixture(%{alias: "race-#{Ecto.UUID.generate()}"})
        version = gtfs_version_fixture(organization.id)
        garage = garage_fixture(organization.id)
        owner = self()

        try do
          {racer, _racer_id} =
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
                    :insert -> :ok
                  after
                    @async_timeout -> :timeout
                  end

                  {:ok, _row} =
                    Repo.insert(%BlockAttribute{
                      organization_id: organization.id,
                      gtfs_version_id: version.id,
                      service_id: "weekday",
                      block_id: "99",
                      garage_id: garage.id
                    })
                end)

              send(owner, {:insert_result, self(), result})
            end)

          assert_receive {:garage_locked, ^racer}, @async_timeout

          {deleter, _deleter_id} =
            start_unboxed_task(fn ->
              send(
                owner,
                {:delete_result, self(), Operations.delete_garage(organization.id, garage.id)}
              )
            end)

          send(racer, :insert)

          assert_receive {:insert_result, ^racer, {:ok, _value}}, @async_timeout

          assert_receive {:delete_result, ^deleter, {:error, {:in_use, counts}}},
                         @async_timeout

          # The refusal names the racing row, and neither the garage nor the row
          # it lost the race with is deleted.
          assert counts.blocks == 1
          assert Repo.get(Garage, garage.id)
          assert Repo.get_by(BlockAttribute, garage_id: garage.id)
        after
          delete_race_fixtures!(organization.id)
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

  # The committed rows one unboxed test leaves behind. Every table carrying an
  # organization is cleared in the order its foreign keys need.
  defp delete_race_fixtures!(organization_id) do
    Repo.delete_all(from(a in BlockAttribute, where: a.organization_id == ^organization_id))
    Repo.delete_all(from(d in DeadheadTime, where: d.organization_id == ^organization_id))

    Repo.delete_all(
      from(s in RouteOperatingSetting, where: s.organization_id == ^organization_id)
    )

    Repo.delete_all(from(v in Vehicle, where: v.organization_id == ^organization_id))
    Repo.delete_all(from(t in VehicleType, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(g in Garage, where: g.organization_id == ^organization_id))

    Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))

    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
  end
end
