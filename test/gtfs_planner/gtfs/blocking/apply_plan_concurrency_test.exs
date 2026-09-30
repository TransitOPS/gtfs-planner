defmodule GtfsPlanner.Gtfs.Blocking.ApplyPlanConcurrencyTest do
  @moduledoc """
  The lock half of the plan apply guarantee: a plan apply is serialized with a
  `Schedules` trip writer on the same blocking lock, so a writer that retimes a trip
  the plan touches either loses the race or makes the apply stale — never slips
  between the plan's review and its write.

  One case covers the observation:

  - a holder takes `Blocking.lock_blocking!/1` for the version on its own connection
    and, while it owns the lock, retimes a trip the reviewed plan moves and advances
    its `updated_at` without committing. The apply, on a second own connection, waits
    on that advisory lock — observed through `pg_stat_activity`, not a sleep — and
    after the holder commits it returns `{:error, :stale_plan}` with no `block_id`
    changed and no audit row written.

  The harness is `concurrency_test.exs`'s: `async: false`, `Sandbox.unboxed_run/2` for
  every connection, `wait_until_locked/2` bounded to 5 s, and an `on_exit` that deletes
  exactly the rows the case committed. Nothing here is sandboxed, so the disposable
  organization, version, route, actor, calendars and trips must be committed for the
  holder and the apply to see them, and must be removed even when the test fails.

  SERIALIZABLE behaviour and the production `ReviewedApplyTransaction.Repo` boundary
  are outside this file's scope: `config/test.exs` selects the plain
  `ReviewedApplyTransaction.Sandbox` transaction, which is what
  `concurrency_test.exs` and `schedules_test.exs` state for their own lock cases. The
  `40001` path is simulated through the Mox mock in `apply_plan_test.exs`, not here.

  Run with:
  `mix test test/gtfs_planner/gtfs/blocking/apply_plan_concurrency_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # Every case holds one lock open and observes another backend's wait, so each test
  # is bounded by the module timeout and a 10 s self-release for a hold the
  # test never gets to release.
  @moduletag timeout: 120_000

  @weekday_service "WK"

  @hold_timeout 10_000
  @receive_timeout 5_000
  @lock_wait_attempts 500
  @task_timeout 15_000

  describe "a Schedules writer racing the apply" do
    test "the apply waits for the blocking lock and is then stale" do
      scope = committed_scope()

      on_exit(fn -> cleanup_committed_scope(scope) end)

      day_type_key = weekday_key(scope)
      plan = suggest!(scope, day_type_key)

      moved = Enum.find(plan.moves, &(&1.trip.trip_id == "q"))
      assert moved, "the fixture's pool trip is not a move of the plan"
      assert moved.from == nil

      parent = self()
      retimed = "12:30:00"

      holder =
        Task.async(fn -> hold_blocking_lock_and_retime(scope, moved.trip, retimed, parent) end)

      assert_receive {:retime_held, 1, 1}, @receive_timeout

      applier = Task.async(fn -> apply_on_own_connection(scope, day_type_key, plan, parent) end)
      assert_receive {:apply_pid, apply_pid}, @receive_timeout

      # The apply is inside its own transaction, past the version read, and waiting for
      # the advisory lock this connection owns. `pg_stat_activity` is the observation, so
      # the assertion cannot pass by accident on a fast apply.
      assert wait_until_locked(apply_pid)

      send(holder.pid, :commit)
      assert Task.await(holder, @task_timeout) == {:ok, :ok}

      assert {:error, :stale_plan} = Task.await(applier, @task_timeout)

      # The retime the holder committed is what the apply re-read under the lock, and
      # nothing the plan would have written persisted.
      assert last_departure_time(scope, moved.trip) == retimed
      assert DateTime.compare(persisted(moved.trip).updated_at, moved.trip.updated_at) == :gt
      assert persisted(moved.trip).block_id == nil
      assert change_log_count(scope) == 0
      assert block_attribute_count(scope) == 0
    end
  end

  # --- committed fixtures ----------------------------------------------------

  # One case's rows, committed on an own connection because the holder and the apply
  # each run on their own connection and must see them. Two pool trips on one weekday
  # service, so the plan has a move to race, and two coordinate-bearing stops so the
  # generator's decisions are decided by the times alone.
  defp committed_scope do
    unboxed(fn ->
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      route =
        route_fixture(organization.id, version.id, %{route_id: "12", route_short_name: "12"})

      actor = editor_fixture(organization)

      calendar_service_fixture(organization.id, version.id, %{
        service_id: @weekday_service,
        name: "Weekday",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0
      })

      for {stop_id, name, lat} <- [{"S1", "Riverside", "40.0000"}, {"S2", "Market", "40.0300"}] do
        stop_with_coordinates_fixture(organization.id, version.id, %{
          stop_id: stop_id,
          stop_name: name,
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new("-74.0")
        })
      end

      trips =
        Map.new(
          [
            {:p, %{trip_id: "p", first_arrival: "08:00:00", last_arrival: "09:00:00"}},
            {:q, %{trip_id: "q", first_arrival: "10:00:00", last_arrival: "11:00:00"}}
          ],
          fn {key, attrs} ->
            {key,
             blocked_trip_fixture(
               organization.id,
               version.id,
               route.route_id,
               Map.put_new(attrs, :service_id, @weekday_service)
             )}
          end
        )

      %{
        organization_id: organization.id,
        version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email,
        trips: trips,
        audit: %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          station_stop_id: nil,
          actor_id: actor.id,
          actor_email: actor.email
        }
      }
    end)
  end

  # Deletes exactly the rows `committed_scope/0` created and the apply's change logs and
  # attribute rows, keyed to their own organization, on an own connection so the deletion
  # is not part of the SQL Sandbox transaction and runs even when the test failed.
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      organization_id = scope.organization_id

      Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      Repo.delete_all(from(a in BlockAttribute, where: a.organization_id == ^organization_id))
      Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
      Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(c in CalendarAttribute, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(c in CalendarDate, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(c in Calendar, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
      Repo.delete_all(from(u in User, where: u.id == ^scope.actor_id))
    end)
  end

  # The weekday day type's key from `Calendars.list_calendars/3` (the single
  # service-date source) on an own connection: its version `FOR SHARE` lock must not
  # outlive the read, or the sandboxed test process would block the cleanup's delete of
  # the version row.
  defp weekday_key(scope) do
    unboxed(fn ->
      {:ok, calendars} = Calendars.list_calendars(scope.organization_id, scope.version_id)

      day_type =
        Enum.find(DayTypes.derive(calendars), &(&1.service_ids == [@weekday_service]))

      assert day_type, "the fixtures carry no #{@weekday_service} day type"

      day_type.key
    end)
  end

  # The plan is read on an own connection too: its `FOR SHARE` version lock must be
  # released before the holder takes the blocking lock, or the two would deadlock on
  # this case's own fixtures rather than on the behaviour under test.
  defp suggest!(scope, day_type_key) do
    unboxed(fn ->
      assert {:ok, plan} =
               Gtfs.suggest_blocks(
                 scope.organization_id,
                 scope.version_id,
                 day_type_key,
                 :unassigned_only
               )

      plan
    end)
  end

  # The apply on its own connection: its transaction must commit for the advisory lock
  # and its row locks to be released, and it reports the backend pid the test polls.
  defp apply_on_own_connection(scope, day_type_key, plan, parent) do
    unboxed(fn ->
      {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
      send(parent, {:apply_pid, backend_pid})
      Gtfs.apply_block_plan(day_type_key, plan, scope.audit)
    end)
  end

  # Takes the version's blocking lock with the statement `Blocking.lock_blocking!/1`
  # issues and, while holding it, retimes one of the plan's moved trips and advances its
  # `updated_at` — uncommitted, so the apply is still waiting when the test observes it.
  # A retime and not a delete keeps the trip in the plan's scope: the apply must reach
  # the fingerprint comparison and find the rows changed, rather than find its scope
  # gone.
  defp hold_blocking_lock_and_retime(scope, trip, new_time, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "blocking:" <> scope.version_id
        ])

        {stop_times, _} =
          Repo.update_all(
            from(st in StopTime,
              where:
                st.organization_id == ^scope.organization_id and
                  st.gtfs_version_id == ^scope.version_id and st.trip_id == ^trip.trip_id and
                  st.stop_sequence == 2
            ),
            set: [arrival_time: new_time, departure_time: new_time]
          )

        {trips, _} =
          Repo.update_all(
            from(t in Trip,
              where:
                t.organization_id == ^scope.organization_id and
                  t.gtfs_version_id == ^scope.version_id and t.id == ^trip.id
            ),
            set: [updated_at: DateTime.utc_now()]
          )

        send(parent, {:retime_held, stop_times, trips})

        receive do
          :commit -> :ok
        after
          @hold_timeout -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  # The blocked backend reports itself in `pg_stat_activity` once it waits on the lock,
  # which is deterministic; the test polls it instead of sleeping on a guess. The bound
  # mirrors `concurrency_test.exs`: 500 attempts of 10 ms, so 5 s.
  #
  # The poll reads on this process's own sandbox connection (`async: false` gives it a
  # shared owner connection) instead of checking one out: the case already holds one
  # connection in its holder and one in the blocked apply, and a further checkout would
  # demand a pool connection a host with few schedulers does not have, turning the poll
  # into a `pool_timeout` error instead of an assertion.
  defp wait_until_locked(pid, attempts \\ @lock_wait_attempts) do
    {:ok, %{rows: [[waiting]]}} =
      Repo.query(
        "select count(*) from pg_stat_activity where pid = $1 and wait_event_type = 'Lock' and wait_event = 'advisory'",
        [pid]
      )

    cond do
      waiting > 0 ->
        true

      attempts <= 0 ->
        flunk("the backend #{inspect(pid)} never waited on a lock")

      true ->
        Process.sleep(10)
        wait_until_locked(pid, attempts - 1)
    end
  end

  defp persisted(%{id: id}), do: Repo.get!(Trip, id)

  defp last_departure_time(scope, trip) do
    Repo.one!(
      from(st in StopTime,
        where:
          st.organization_id == ^scope.organization_id and
            st.gtfs_version_id == ^scope.version_id and st.trip_id == ^trip.trip_id and
            st.stop_sequence == 2,
        select: st.departure_time
      )
    )
  end

  defp change_log_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization_id and
            l.gtfs_version_id == ^scope.version_id and l.entity_type == "trip"
      ),
      :count
    )
  end

  defp block_attribute_count(scope) do
    Repo.aggregate(
      from(a in BlockAttribute,
        where:
          a.organization_id == ^scope.organization_id and
            a.gtfs_version_id == ^scope.version_id
      ),
      :count
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
