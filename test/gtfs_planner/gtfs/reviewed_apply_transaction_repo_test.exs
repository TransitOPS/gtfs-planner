defmodule GtfsPlanner.Gtfs.ReviewedApplyTransaction.RepoTest do
  use GtfsPlanner.DataCase, async: false

  @async_timeout 5_000

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    )

    on_exit(fn ->
      case previous do
        {:ok, adapter} ->
          Application.put_env(:gtfs_planner, :reviewed_apply_transaction, adapter)

        :error ->
          Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)
  end

  test "runs the production transaction at serializable isolation" do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, "serializable"} =
               ReviewedApplyTransaction.Repo.run(fn ->
                 %Postgrex.Result{rows: [[isolation]]} =
                   Repo.query!("SHOW transaction_isolation")

                 isolation
               end)
    end)
  end

  test "public audited apply retries a real serialization conflict and commits atomically" do
    Sandbox.unboxed_run(Repo, fn ->
      organization =
        organization_fixture(%{
          alias: "serializable-#{Ecto.UUID.generate()}",
          name: "Serializable Public Apply"
        })

      gtfs_version = gtfs_version_fixture(organization.id)

      actor =
        user_fixture(%{
          email: "serializable-#{Ecto.UUID.generate()}@example.com"
        })

      try do
        station =
          stop_fixture(organization.id, gtfs_version.id, %{
            stop_id: "SERIALIZABLE_PUBLIC_STATION",
            location_type: 1
          })

        level =
          level_fixture(organization.id, gtfs_version.id, %{
            level_id: "SERIALIZABLE_PUBLIC_LEVEL",
            level_index: 0.0
          })

        {:ok, stop_level} =
          Gtfs.create_stop_level(%{
            organization_id: organization.id,
            gtfs_version_id: gtfs_version.id,
            stop_id: station.id,
            level_id: level.id
          })

        child =
          stop_fixture(organization.id, gtfs_version.id, %{
            stop_id: "SERIALIZABLE_PUBLIC_CHILD",
            location_type: 0,
            parent_station: station.stop_id,
            level_id: level.level_id,
            diagram_coordinate: %{x: 50, y: 40},
            stop_lat: Decimal.new("1.0"),
            stop_lon: Decimal.new("2.0")
          })

        scope = %Scope{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          station_id: station.id,
          station_stop_id: station.stop_id,
          actor_id: actor.id
        }

        pin_id = Ecto.UUID.generate()

        assert %{synced_count: 1, errors: []} =
                 Gtfs.sync_journal_entries(scope, [
                   %{
                     id: pin_id,
                     target_type: "pin",
                     stop_level_id: stop_level.id,
                     diagram_x: 50.0,
                     diagram_y: 40.0,
                     captured_at: ~U[2026-07-23 12:00:00Z]
                   }
                 ])

        alignment = %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.25,
          floorplan_rotation_deg: 0.0
        }

        assert {:ok, preview} =
                 Gtfs.preview_stop_level_coordinate_application(
                   stop_level.id,
                   alignment,
                   1000,
                   800
                 )

        audit_ctx = %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          station_stop_id: station.stop_id,
          actor_id: actor.id,
          actor_email: actor.email
        }

        handler_id = {__MODULE__, make_ref()}
        owner = self()

        :ok =
          :telemetry.attach(
            handler_id,
            [:gtfs_planner, :repo, :query],
            fn _event, _measurements, metadata, destination ->
              if metadata.query == "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE" do
                send(destination, {:serializable_attempt, self()})
              end
            end,
            owner
          )

        try do
          {locker, locker_id} =
            start_unboxed_task(fn ->
              Repo.transaction(fn ->
                Repo.query!(
                  """
                  UPDATE stop_levels
                  SET updated_at = clock_timestamp()
                  WHERE id = $1
                  """,
                  [Ecto.UUID.dump!(stop_level.id)]
                )

                send(owner, {:stop_level_locked, self()})

                receive do
                  :release_stop_level -> :ok
                end
              end)
            end)

          try do
            locker_ref = Process.monitor(locker)
            assert_receive {:stop_level_locked, ^locker}, @async_timeout

            {apply_task, apply_id} =
              start_unboxed_task(fn ->
                %Postgrex.Result{rows: [[backend_pid]]} =
                  Repo.query!("SELECT pg_backend_pid()")

                send(owner, {:apply_backend, self(), backend_pid})
                result = Gtfs.apply_stop_level_coordinate_preview(preview, audit_ctx)
                send(owner, {:public_apply_result, self(), result})
              end)

            try do
              apply_ref = Process.monitor(apply_task)
              assert_receive {:apply_backend, ^apply_task, backend_pid}, @async_timeout
              assert_receive {:serializable_attempt, ^apply_task}, @async_timeout
              assert_postgres_lock_wait!(backend_pid)

              send(locker, :release_stop_level)
              assert_receive {:DOWN, ^locker_ref, :process, ^locker, :normal}, @async_timeout

              assert_receive {:serializable_attempt, ^apply_task}, @async_timeout

              assert_receive {:public_apply_result, ^apply_task,
                              {:ok,
                               %{
                                 active_stop_level: %StopLevel{id: stop_level_id},
                                 touched_stop_count: 1
                               }}},
                             @async_timeout

              assert stop_level_id == stop_level.id
              assert_receive {:DOWN, ^apply_ref, :process, ^apply_task, :normal}, @async_timeout
            after
              stop_supervised_task(apply_id)
            end
          after
            send(locker, :release_stop_level)
            stop_supervised_task(locker_id)
          end

          updated_stop_level = Repo.get!(StopLevel, stop_level.id)
          updated_child = Repo.get!(Stop, child.id)
          updated_pin = Repo.get!(JournalEntry, pin_id)

          assert updated_stop_level.floorplan_center_lat == alignment.floorplan_center_lat
          assert updated_stop_level.floorplan_center_lon == alignment.floorplan_center_lon
          assert_in_delta Decimal.to_float(updated_child.stop_lat), 40.7128, 1.0e-9
          assert_in_delta Decimal.to_float(updated_child.stop_lon), -74.006, 1.0e-9
          assert_in_delta updated_pin.lat, 40.7128, 1.0e-9
          assert_in_delta updated_pin.lon, -74.006, 1.0e-9

          assert [log] =
                   Gtfs.list_change_logs_for_entity(
                     organization.id,
                     gtfs_version.id,
                     "stop",
                     child.id
                   )

          assert log.action == "updated"
          assert log.actor_email == actor.email
          assert log.station_stop_id == station.stop_id
          assert Map.has_key?(log.changed_fields, "stop_lat")
          assert Map.has_key?(log.changed_fields, "stop_lon")
        after
          :telemetry.detach(handler_id)
        end
      after
        delete_fixture!(organization.id, actor.id)
      end
    end)
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

  defp assert_postgres_lock_wait!(backend_pid, attempts_remaining \\ 200)

  defp assert_postgres_lock_wait!(_backend_pid, 0) do
    flunk("public apply did not block on the concurrent stop-level update")
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

      _ ->
        receive do
        after
          10 -> assert_postgres_lock_wait!(backend_pid, attempts_remaining - 1)
        end
    end
  end

  defp delete_fixture!(organization_id, actor_id) do
    Repo.delete_all(from(entry in JournalEntry, where: entry.organization_id == ^organization_id))
    Repo.delete_all(from(log in ChangeLog, where: log.organization_id == ^organization_id))

    Repo.delete_all(
      from(stop_level in StopLevel, where: stop_level.organization_id == ^organization_id)
    )

    Repo.delete_all(from(stop in Stop, where: stop.organization_id == ^organization_id))
    Repo.delete_all(from(level in Level, where: level.organization_id == ^organization_id))

    Repo.delete_all(
      from(version in GtfsVersion, where: version.organization_id == ^organization_id)
    )

    Repo.delete_all(
      from(organization in Organization, where: organization.id == ^organization_id)
    )

    Repo.delete_all(from(user in User, where: user.id == ^actor_id))
  end

  defp stop_supervised_task(child_id) do
    case stop_supervised(child_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
