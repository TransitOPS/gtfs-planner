defmodule GtfsPlanner.Gtfs.Calendars.CombinationConcurrencyTest do
  @moduledoc """
  The public reviewed combination apply under real contention (step 16, AC-13/AC-15, CL-3).

  Every case here uses `async: false` and `Sandbox.unboxed_run/2` so each worker owns its own
  committing PostgreSQL connection, and every wait is a `pg_blocking_pids` rendezvous with a finite
  deadline instead of a sleep:

  - A source writer that holds the scoped version share lock and commits a trip while the apply
    waits for the exclusive version lock makes the submitted token stale, and the apply writes
    nothing - for a source that starts with zero trips and for one that starts with trips.
  - A second confirmation with the token of a completed operation never moves a trip created after
    that operation.
  - A writer that starts while the combine holds the version lock waits for the combine to commit,
    so its trip is created after the move and stays on the source.

  The focused gate command
  `mix test test/gtfs_planner/gtfs/calendars/combination_apply_test.exs
  test/gtfs_planner/gtfs/calendars/combination_concurrency_test.exs` is deferred to branch review;
  every assertion here is unexecuted until that gate runs.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @command {:combine, "DEST", ["SAT"], %{}}
  @poll_interval 10
  @contention_timeout 10_000
  @collect_timeout 15_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{supervisor: supervisor}
  end

  test "a writer that commits while the apply waits makes the token stale with zero writes",
       %{supervisor: supervisor} do
    scope = unboxed(fn -> seed_committed_scope("zero-initial", 0) end)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)

    assert source_trip_ids(scope) == []
    token = review_token(scope)
    before = committed_footprint(scope)

    # The cooperating writer's own order: the scoped version row `FOR SHARE` first, then the real
    # `Gtfs.create_trip/1` insert, committed by this transaction.
    writer = start_trip_writer(supervisor, scope)
    apply_task = start_apply(supervisor, scope, token)

    assert_blocked_by(apply_task.backend, writer.backend)

    send(writer.task.pid, :commit)
    assert {:ok, created_trip_id} = Task.await(writer.task, @collect_timeout)

    # The apply acquired the exclusive version lock only after the writer committed, so the reviewed
    # rows no longer match the token (AC-15) and the whole operation writes nothing.
    assert {:error, :stale_review} = Task.await(apply_task.task, @collect_timeout)

    expected_trips = [{created_trip_id, "SAT", nil}]

    assert committed_footprint(scope) == %{
             before
             | reviewed_trip_id: created_trip_id,
               trips: expected_trips
           }

    assert Enum.map(source_trip_ids(scope), & &1.id) == [created_trip_id]
    assert log_count(scope) == 0
  end

  test "a writer that commits while the apply waits makes the token stale for a moving source",
       %{supervisor: supervisor} do
    scope = unboxed(fn -> seed_committed_scope("nonzero-initial", 1) end)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)

    assert length(source_trip_ids(scope)) == 1
    token = review_token(scope)
    before = committed_footprint(scope)

    writer = start_trip_writer(supervisor, scope)
    apply_task = start_apply(supervisor, scope, token)

    assert_blocked_by(apply_task.backend, writer.backend)

    send(writer.task.pid, :commit)
    assert {:ok, created_trip_id} = Task.await(writer.task, @collect_timeout)

    assert {:error, :stale_review} = Task.await(apply_task.task, @collect_timeout)

    # Neither the reviewed trip nor the late one moved, and no calendar or audit row changed.
    assert Enum.sort(Enum.map(source_trip_ids(scope), & &1.id)) ==
             Enum.sort([created_trip_id, before.reviewed_trip_id])

    expected_trips =
      Enum.sort([
        {before.reviewed_trip_id, "SAT", "C700"},
        {created_trip_id, "SAT", nil}
      ])

    # `reviewed_trip_id` is only the footprint's lowest SAT trip UUID, which the late trip's fresh
    # UUID can now own, so the reviewed trip's own identity is asserted above instead.
    assert Map.delete(committed_footprint(scope), :reviewed_trip_id) ==
             Map.delete(%{before | trips: expected_trips}, :reviewed_trip_id)

    assert log_count(scope) == 0
  end

  test "a second confirmation with the old token never moves newly created trips" do
    scope = unboxed(fn -> seed_committed_scope("duplicate", 1) end)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)

    token = review_token(scope)

    assert {:ok, first} =
             unboxed(fn -> Gtfs.apply_calendar_change(@command, token, scope.audit) end)

    assert first.action == :combined
    assert length(first.changed_trip_ids) == 1

    logs_after_first = unboxed(fn -> log_count(scope) end)

    # The retained source allows later creation, so a new trip appears after the operation.
    created_trip_id = unboxed(fn -> create_source_trip!(scope, "LATE_SAT_T1") end)

    assert {:error, :stale_review} =
             unboxed(fn -> Gtfs.apply_calendar_change(@command, token, scope.audit) end)

    assert unboxed(fn -> trip_service(scope, created_trip_id) end) == "SAT"
    assert unboxed(fn -> log_count(scope) end) == logs_after_first

    assert Enum.sort(unboxed(fn -> Enum.map(source_trip_ids(scope), & &1.id) end)) == [
             created_trip_id
           ]
  end

  test "a writer that starts while the combine holds the lock waits for the combine to commit",
       %{supervisor: supervisor} do
    scope = unboxed(fn -> seed_committed_scope("late-writer", 1) end)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)

    reviewed_trip_id = unboxed(fn -> hd(source_trip_ids(scope)).id end)
    token = review_token(scope)

    holder = hold_exclusive_version(supervisor, scope)
    apply_task = start_apply(supervisor, scope, token)

    assert_blocked_by(apply_task.backend, holder.backend)

    # The writer starts while the combine is already queued for the exclusive version lock, so it
    # queues behind the combine and waits on the combine's own backend: the combine's token was
    # reviewed before the writer's trip existed, and the writer can only insert after the combine
    # has committed and released the version row.
    writer = start_queued_trip_writer(supervisor, scope)
    assert_blocked_by(writer.backend, apply_task.backend)

    send(holder.task.pid, :release)

    assert {:error, :released} = Task.await(holder.task, @collect_timeout)

    assert {:ok, result} = Task.await(apply_task.task, @collect_timeout)
    assert result.action == :combined
    assert result.changed_trip_ids == [reviewed_trip_id]

    assert {:ok, created_trip_id} = Task.await(writer.task, @collect_timeout)

    # The late trip was created after the reviewed move committed, so it stays on the source while
    # the reviewed trip runs on the destination.
    assert Enum.sort(unboxed(fn -> Enum.map(source_trip_ids(scope), & &1.id) end)) == [
             created_trip_id
           ]

    assert unboxed(fn -> trip_service(scope, reviewed_trip_id) end) == "DEST"

    # The destination's evaluated dates did not change, so the combine's only write is the one
    # moved trip's log; the late trip's own insert adds no audit.
    assert unboxed(fn -> log_count(scope) end) == 1
  end

  # --- committed scope -------------------------------------------------------

  defp seed_committed_scope(suffix, source_trip_count) do
    unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    organization = organization_fixture(%{alias: "combination-concurrency-#{suffix}-#{unique}"})
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "R_#{unique}"})
    actor = user_fixture(%{email: "combination-concurrency-#{unique}@example.test"})
    membership = organization_membership_fixture(actor, organization)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "DEST",
      saturday: 1,
      sunday: 0,
      start_date: ~D[2026-03-02],
      end_date: ~D[2026-03-28]
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SAT",
      dates: [~D[2026-03-07], ~D[2026-03-14]]
    })

    trip_fixture(organization.id, version.id, route.id, %{
      trip_id: "DEST_T1",
      service_id: "DEST",
      block_id: "C701"
    })

    for index <- 1..source_trip_count//1 do
      trip_fixture(organization.id, version.id, route.id, %{
        trip_id: "SAT_T#{index}",
        service_id: "SAT",
        block_id: "C700"
      })
    end

    %{
      organization_id: organization.id,
      version_id: version.id,
      actor_id: actor.id,
      membership_id: membership.id,
      route_id: route.route_id,
      audit: audit_for(organization.id, version.id, actor.id)
    }
  end

  # The source's own trip count for a moving service, read from a committing connection.
  defp source_trip_ids(scope) do
    Repo.all(
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization_id and
            t.gtfs_version_id == ^scope.version_id and t.service_id == "SAT",
        order_by: t.id,
        select: %{id: t.id}
      )
    )
  end

  defp trip_service(scope, trip_id) do
    Repo.one!(
      from(t in Trip,
        where: t.id == ^trip_id and t.organization_id == ^scope.organization_id,
        select: t.service_id
      )
    )
  end

  defp log_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization_id and l.gtfs_version_id == ^scope.version_id
      ),
      :count
    )
  end

  defp committed_footprint(scope) do
    reviewed_trip_id =
      Repo.one(
        from(t in Trip,
          where:
            t.organization_id == ^scope.organization_id and
              t.gtfs_version_id == ^scope.version_id and t.service_id == "SAT",
          order_by: [asc: t.id],
          limit: 1,
          select: t.id
        )
      )

    %{
      reviewed_trip_id: reviewed_trip_id,
      trips:
        Repo.all(
          from(t in Trip,
            where:
              t.organization_id == ^scope.organization_id and
                t.gtfs_version_id == ^scope.version_id,
            where: t.service_id == "SAT",
            order_by: t.id,
            select: {t.id, t.service_id, t.block_id}
          )
        ),
      destination:
        Repo.all(
          from(c in Calendar,
            where:
              c.organization_id == ^scope.organization_id and
                c.gtfs_version_id == ^scope.version_id and c.service_id == "DEST",
            select: {c.service_id, c.start_date, c.end_date, c.updated_at}
          )
        ),
      destination_dates:
        Repo.all(
          from(d in CalendarDate,
            where:
              d.organization_id == ^scope.organization_id and
                d.gtfs_version_id == ^scope.version_id and d.service_id == "DEST",
            order_by: d.date,
            select: {d.date, d.exception_type}
          )
        ),
      logs:
        Repo.aggregate(
          from(l in ChangeLog, where: l.organization_id == ^scope.organization_id),
          :count
        )
    }
  end

  # The review must run on its own committing connection. Taken on the shared sandbox owner
  # connection the review's scoped version `FOR UPDATE` would be held until the end of the case and
  # deadlock every unboxed rendezvous participant below; `unboxed_run/2` releases it when the review
  # transaction commits.
  defp review_token(scope) do
    unboxed(fn ->
      {:ok, review} =
        Gtfs.review_calendar_change(
          @command,
          %{"DEST" => "client-DEST", "SAT" => "client-SAT"},
          scope.audit
        )

      assert review.ready?
      assert is_binary(review.fingerprint)
      review.fingerprint
    end)
  end

  defp create_source_trip!(scope, trip_id) do
    {:ok, trip} =
      Gtfs.create_trip(%{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.version_id,
        route_id: scope.route_id,
        trip_id: trip_id,
        service_id: "SAT"
      })

    trip.id
  end

  defp audit_for(organization_id, version_id, actor_id) do
    %AuditContext{
      organization_id: organization_id,
      gtfs_version_id: version_id,
      station_stop_id: nil,
      actor_id: actor_id,
      actor_email: "combination-concurrency@example.test"
    }
  end

  # --- contention helpers ----------------------------------------------------

  defp start_apply(supervisor, scope, token) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> await_apply(scope, token, parent) end)

    assert_receive {:apply_ready, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    send(task.pid, :go)
    %{task: task, backend: backend}
  end

  defp await_apply(scope, token, parent) do
    unboxed(fn ->
      backend = backend_pid()
      send(parent, {:apply_ready, self(), backend})

      receive do
        :go -> :ok
      end

      Gtfs.apply_calendar_change(@command, token, scope.audit)
    end)
  end

  defp start_trip_writer(supervisor, scope) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> write_late_trip(scope, parent) end)

    assert_receive {:writer_locked, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  # A racing input writer for the case where the combine already holds the exclusive version row.
  # It must announce before attempting the shared version lock, because that lock waits on the
  # combine's own holder and so never becomes observable afterwards; it inserts and commits its trip
  # as soon as the combine has released the row. The announcement is sent inside the writer's
  # transaction, so the shared lock follows it and the case observes the writer waiting.
  defp start_queued_trip_writer(supervisor, scope) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> write_queued_trip(scope, parent) end)

    assert_receive {:writer_started, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  defp write_queued_trip(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        send(parent, {:writer_started, self(), backend_pid()})
        Versions.lock_for_input_write!(scope.organization_id, scope.version_id)
        create_source_trip!(scope, "LATE_SAT_T1")
      end)
    end)
  end

  defp write_late_trip(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Versions.lock_for_input_write!(scope.organization_id, scope.version_id)
        send(parent, {:writer_locked, self(), backend_pid()})

        receive do
          :commit -> :ok
        end

        create_source_trip!(scope, "LATE_SAT_T1")
      end)
    end)
  end

  defp hold_exclusive_version(supervisor, scope) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> hold_version(scope, parent) end)

    assert_receive {:held, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  defp hold_version(scope, parent) do
    unboxed(fn -> Repo.transaction(fn -> lock_version(scope) |> announce(parent) end) end)
  end

  defp lock_version(scope) do
    Repo.one(
      from(v in GtfsVersion,
        where: v.id == ^scope.version_id and v.organization_id == ^scope.organization_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp announce(version, parent) do
    send(parent, {:held, self(), backend_pid()})

    receive do
      :release -> Repo.rollback(:released)
    end

    version
  end

  defp assert_blocked_by(backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout

    case unboxed(fn -> await_blocker(backend, holder_backend, deadline) end) do
      :ok ->
        :ok

      {:error, blocked_by} ->
        flunk(
          "expected backend #{backend} to wait on #{holder_backend}, saw #{inspect(blocked_by)}"
        )
    end
  end

  defp await_blocker(backend, holder_backend, deadline) do
    blocked_by = blockers_of(backend)

    cond do
      holder_backend in blocked_by ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, blocked_by}

      true ->
        Process.sleep(@poll_interval)
        await_blocker(backend, holder_backend, deadline)
    end
  end

  defp blockers_of(backend) do
    %Postgrex.Result{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend])
    List.wrap(blockers)
  end

  defp backend_pid do
    %Postgrex.Result{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  # --- cleanup ---------------------------------------------------------------

  # `async: false` with unboxed committing connections means the committed fixtures are not rolled
  # back, so the scope this case created is deleted explicitly.
  defp cleanup(scope) do
    organization_id = scope.organization_id

    Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
    Repo.delete_all(from(t in Transfer, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
    Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
    Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id == ^organization_id))
    Repo.delete_all(from(d in CalendarDate, where: d.organization_id == ^organization_id))
    Repo.delete_all(from(c in Calendar, where: c.organization_id == ^organization_id))
    Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))
    Repo.delete_all(from(a in Agency, where: a.organization_id == ^organization_id))

    Repo.delete_all(
      from(m in UserOrgMembership,
        where: m.organization_id == ^organization_id or m.user_id == ^scope.actor_id
      )
    )

    Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
    Repo.delete_all(from(u in User, where: u.id == ^scope.actor_id))
    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))

    :ok
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
