defmodule GtfsPlanner.Gtfs.Schedules.ConcurrencyTest do
  # EV-4: schedule writers must compose with spec 01's timing apply and spec 02's
  # calendar delete. Two independently committing sessions are interleaved with
  # message barriers on their own connections, the final rows are read on a third
  # connection, and every expected offset is authored literally here rather than
  # produced by the production materializer. `on_exit` deletes only the captured
  # fixture scope.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner/gtfs/schedules/concurrency_test.exs`.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @lock_wait 500
  @collect_timeout 10_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{supervisor: supervisor}
  end

  describe "timing apply against create" do
    test "a create waiting for a committed timing edit materializes the final offsets", %{
      supervisor: supervisor
    } do
      scope = seed_scope("apply-then-create")
      on_exit(fn -> cleanup([scope]) end)

      {operation, reviewed} = review_timing_edit(scope, [{0, 0}, {600, 660}])
      parent = self()

      holder =
        Task.Supervisor.async_nolink(supervisor, fn ->
          hold_route_and_apply(scope, operation, reviewed, parent)
        end)

      assert_receive {:route_holder_ready, holder_pid}, @collect_timeout
      assert holder_pid == holder.pid

      # The holder wrote the timing edit but has not committed it yet.
      send(holder.pid, :apply)
      assert_receive {:timing_applied, ^holder_pid}, @collect_timeout

      creator =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:creator_ready, self()})

          unboxed(fn ->
            Gtfs.create_trips(scope.route_id, create_attrs(scope, "07:00:00"), scope.audit)
          end)
        end)

      assert_receive {:creator_ready, _creator_pid}, @collect_timeout

      # The create is still blocked behind the holder's route lock, so it cannot
      # have read the pre-edit timing rows.
      refute Task.yield(creator, @lock_wait)

      send(holder.pid, :commit)
      assert Task.await(holder, @collect_timeout) == {:ok, :ok}
      assert {:ok, %{trips: [created]}} = Task.await(creator, @collect_timeout)

      assert created.trip_id == "#{scope.route_id}-0-#{scope.service}-0700"

      # The committed timing edit is the literal one, and both the pre-existing
      # trip and the newly created trip match start plus those offsets.
      assert timing_offsets(scope) == [{"A", 0, 0}, {"B", 600, 660}]

      assert clocks_by_trip([scope.existing.trip_id, created.trip_id]) == %{
               scope.existing.trip_id => [
                 {"A", "06:00:00", "06:00:00"},
                 {"B", "06:10:00", "06:11:00"}
               ],
               created.trip_id => [
                 {"A", "07:00:00", "07:00:00"},
                 {"B", "07:10:00", "07:11:00"}
               ]
             }

      assert trip_ids(scope) |> Enum.sort() ==
               Enum.sort([scope.existing.trip_id, created.trip_id])
    end

    test "a timing edit after a committed create rematerializes the created trip", _context do
      scope = seed_scope("create-then-apply")
      on_exit(fn -> cleanup([scope]) end)

      assert {:ok, %{trips: [created]}} =
               unboxed(fn ->
                 Gtfs.create_trips(scope.route_id, create_attrs(scope, "07:00:00"), scope.audit)
               end)

      assert clocks_by_trip([created.trip_id]) == %{
               created.trip_id => [
                 {"A", "07:00:00", "07:00:00"},
                 {"B", "07:05:00", "07:05:30"}
               ]
             }

      created_updated_at = unboxed(fn -> Repo.get!(Trip, created.id).updated_at end)

      # A fresh review over the rows the create just committed, then the apply.
      {operation, reviewed} = review_timing_edit(scope, [{0, 0}, {600, 660}])

      assert {:ok, %{trips_updated: 2}} =
               unboxed(fn ->
                 Gtfs.apply_review(scope.bundle.pattern.id, operation, reviewed, scope.audit)
               end)

      assert timing_offsets(scope) == [{"A", 0, 0}, {"B", 600, 660}]

      assert clocks_by_trip([scope.existing.trip_id, created.trip_id]) == %{
               scope.existing.trip_id => [
                 {"A", "06:00:00", "06:00:00"},
                 {"B", "06:10:00", "06:11:00"}
               ],
               created.trip_id => [
                 {"A", "07:00:00", "07:00:00"},
                 {"B", "07:10:00", "07:11:00"}
               ]
             }

      # The rematerialized trip advances `updated_at` for spec 04's fingerprint.
      # `DateTime.compare/2` orders the instants; the structural `>` comparison
      # this replaces read two DateTime structs' fields and rejected a later
      # timestamp that shares the same second.
      assert DateTime.compare(
               unboxed(fn -> Repo.get!(Trip, created.id).updated_at end),
               created_updated_at
             ) == :gt
    end
  end

  describe "calendar delete against create" do
    test "a delete that commits first refuses the waiting create with :calendar_not_found", %{
      supervisor: supervisor
    } do
      # Without the seeded trip the calendar has no trips, so the reviewed
      # delete can commit and the scenario can exercise the refused create.
      scope = seed_scope("delete-then-create", false)
      on_exit(fn -> cleanup([scope]) end)

      {:ok, reviewed} = review_calendar_delete(scope)
      parent = self()

      holder =
        Task.Supervisor.async_nolink(supervisor, fn ->
          hold_version_and_delete(scope, reviewed.fingerprint, parent)
        end)

      assert_receive {:version_holder_ready, holder_pid}, @collect_timeout
      assert holder_pid == holder.pid

      send(holder.pid, :apply)
      assert_receive {:calendar_deleted, ^holder_pid}, @collect_timeout

      creator =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:creator_ready, self()})

          unboxed(fn ->
            Gtfs.create_trips(scope.route_id, create_attrs(scope, "07:00:00"), scope.audit)
          end)
        end)

      assert_receive {:creator_ready, _creator_pid}, @collect_timeout
      refute Task.yield(creator, @lock_wait)

      send(holder.pid, :commit)
      assert Task.await(holder, @collect_timeout) == {:ok, :ok}

      assert Task.await(creator, @collect_timeout) == {:error, :calendar_not_found}

      # The delete won: no trip exists and nothing references the missing service.
      assert trip_ids(scope) == []
      refute calendar_identity_exists?(scope)

      assert referenced_services_are_missing?(scope) == []
    end

    test "a create that commits first leaves the delete refused as in use", _context do
      # Only the created trip references the calendar, so the refusal counts 1.
      scope = seed_scope("create-then-delete", false)
      on_exit(fn -> cleanup([scope]) end)

      assert {:ok, %{trips: [created]}} =
               unboxed(fn ->
                 Gtfs.create_trips(scope.route_id, create_attrs(scope, "07:00:00"), scope.audit)
               end)

      # The reviewed delete sees the committed trip and refuses without deleting.
      assert {:error, {:in_use, 1, [route_id]}} = review_calendar_delete(scope)

      assert route_id == scope.route_id
      assert calendar_identity_exists?(scope)
      assert unboxed(fn -> Repo.get!(Trip, created.id).service_id end) == scope.service
      assert referenced_services_are_missing?(scope) == []
    end
  end

  # -- Interleaved sessions ---------------------------------------------------

  # The holder takes the published route row lock, then runs the real
  # `Gtfs.apply_review/4` inside the same outer transaction (the nested
  # transaction joins it), signalling after the edit is written and holding the
  # lock until the barrier releases it.
  defp hold_route_and_apply(scope, operation, fingerprint, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        RoutePatterns.lock_published_route!(scope.audit, scope.route_id)
        send(parent, {:route_holder_ready, self()})

        receive do
          :apply -> :ok
        after
          @collect_timeout -> Repo.rollback(:timeout)
        end

        {:ok, _result} =
          Gtfs.apply_review(scope.bundle.pattern.id, operation, fingerprint, scope.audit)

        send(parent, {:timing_applied, self()})

        receive do
          :commit -> :ok
        after
          @collect_timeout -> Repo.rollback(:timeout)
        end

        :ok
      end)
    end)
  end

  # The holder takes the published version row write lock, then runs the real
  # `Gtfs.apply_calendar_change/3` for the reviewed delete inside the same outer
  # transaction and holds the lock until the barrier releases it.
  defp hold_version_and_delete(scope, fingerprint, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.one(from(v in GtfsVersion, where: v.id == ^scope.version.id, lock: "FOR UPDATE"))
        send(parent, {:version_holder_ready, self()})

        receive do
          :apply -> :ok
        after
          @collect_timeout -> Repo.rollback(:timeout)
        end

        command = {:delete, scope.service}
        {:ok, _result} = Gtfs.apply_calendar_change(command, fingerprint, scope.audit)
        send(parent, {:calendar_deleted, self()})

        receive do
          :commit -> :ok
        after
          @collect_timeout -> Repo.rollback(:timeout)
        end

        :ok
      end)
    end)
  end

  defp review_timing_edit(scope, offsets) do
    unboxed(fn ->
      {:ok, %{source_fingerprint: source}} =
        Gtfs.get_pattern(
          scope.organization.id,
          scope.version.id,
          scope.route_id,
          scope.bundle.pattern.id
        )

      rows =
        Repo.all(
          from(o in RoutePatternStop,
            where: o.route_pattern_id == ^scope.bundle.pattern.id,
            order_by: o.position
          )
        )
        |> Enum.zip(offsets)
        |> Enum.map(fn {occurrence, {arrival, departure}} ->
          %{
            route_pattern_stop_id: occurrence.id,
            arrival_offset: arrival,
            departure_offset: departure
          }
        end)

      operation = {:timing, scope.bundle.timing.id, %{rows: rows}}

      {:ok, %{fingerprint: fingerprint}} =
        Gtfs.review(scope.bundle.pattern.id, operation, source, scope.audit)

      {operation, fingerprint}
    end)
  end

  defp review_calendar_delete(scope) do
    unboxed(fn ->
      {:ok, payload} = Gtfs.get_calendar(scope.organization.id, scope.version.id, scope.service)

      Gtfs.review_calendar_change(
        {:delete, scope.service},
        %{scope.service => payload.fingerprint},
        scope.audit
      )
    end)
  end

  defp create_attrs(scope, start_time) do
    %{
      pattern_id: scope.bundle.pattern.id,
      timed_pattern_id: scope.bundle.timing.id,
      service_id: scope.service,
      start_time: start_time,
      repeat: nil
    }
  end

  # -- Committed scope and reads ---------------------------------------------

  # `seed_existing?` is false for the calendar-delete scenarios, which need a
  # calendar with no trips so the reviewed delete can commit; the timing
  # scenarios compare against the seeded 06:00 trip and keep it.
  defp seed_scope(suffix, seed_existing? \\ true) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization =
        organization_fixture(%{alias: "schedule-concurrency-#{suffix}-#{unique}"})

      version = gtfs_version_fixture(organization.id)
      route_id = "rc#{System.unique_integer([:positive])}"
      route_fixture(organization.id, version.id, %{route_id: route_id})
      actor = editor_fixture(organization)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }

      service = "wk_#{System.unique_integer([:positive])}"

      {:ok, _payload} =
        Gtfs.create_calendar(
          %{
            service_id: service,
            name: "Concurrency #{suffix}",
            kind: :weekly,
            monday: 1,
            tuesday: 1,
            wednesday: 1,
            thursday: 1,
            friday: 1,
            saturday: 0,
            sunday: 0,
            start_date: ~D[2026-01-05],
            end_date: ~D[2026-02-27]
          },
          audit
        )

      bundle =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route_id,
          route_pattern_id: "RC-#{suffix}",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]
        })

      existing =
        if seed_existing? do
          schedule_trip_fixture(organization.id, version.id, route_id, bundle, %{
            trip_id: "#{route_id}-0-#{service}-0600",
            service_id: service,
            start_time: "06:00:00"
          }).trip
        end

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: audit,
        route_id: route_id,
        service: service,
        bundle: bundle,
        existing: existing
      }
    end)
  end

  defp timing_offsets(scope) do
    unboxed(fn ->
      Repo.all(
        from(r in TimedPatternStop,
          join: o in RoutePatternStop,
          on: o.id == r.route_pattern_stop_id,
          where: r.timed_pattern_id == ^scope.bundle.timing.id,
          order_by: o.position,
          select: {o.stop_id, r.arrival_offset, r.departure_offset}
        )
      )
    end)
  end

  defp clocks_by_trip(trip_ids) do
    unboxed(fn ->
      Repo.all(
        from(st in StopTime,
          where: st.trip_id in ^trip_ids,
          order_by: [asc: st.trip_id, asc: st.stop_sequence, asc: st.id]
        )
      )
      |> Enum.group_by(& &1.trip_id)
      |> Map.new(fn {trip_id, rows} ->
        {trip_id, Enum.map(rows, &{&1.stop_id, &1.arrival_time, &1.departure_time})}
      end)
    end)
  end

  defp trip_ids(scope) do
    unboxed(fn ->
      Repo.all(from(t in Trip, where: t.route_id == ^scope.route_id, select: t.trip_id))
    end)
  end

  defp calendar_identity_exists?(scope) do
    unboxed(fn ->
      Repo.exists?(
        from(c in Calendar,
          where: c.service_id == ^scope.service and c.organization_id == ^scope.organization.id
        )
      ) or
        Repo.exists?(
          from(a in CalendarAttribute,
            where: a.service_id == ^scope.service and a.organization_id == ^scope.organization.id
          )
        ) or
        Repo.exists?(
          from(d in CalendarDate,
            where: d.service_id == ^scope.service and d.organization_id == ^scope.organization.id
          )
        )
    end)
  end

  # Every trip on the route must still reference a service identity in the union.
  defp referenced_services_are_missing?(scope) do
    unboxed(fn ->
      service_ids =
        Repo.all(
          from(c in Calendar,
            where: c.organization_id == ^scope.organization.id,
            select: c.service_id
          )
        ) ++
          Repo.all(
            from(a in CalendarAttribute,
              where: a.organization_id == ^scope.organization.id,
              select: a.service_id
            )
          )

      Repo.all(from(t in Trip, where: t.route_id == ^scope.route_id, select: t.service_id))
      |> Enum.reject(&(&1 in service_ids))
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Deletes only the captured fixture scope. The organization id is the captured
  # root: every row created here belongs to it, so nothing outside this fixture
  # can be touched.
  defp cleanup(scopes) do
    unboxed(fn ->
      organization_ids = Enum.map(scopes, & &1.organization.id)
      user_ids = Enum.map(scopes, & &1.actor.id)

      Repo.delete_all(
        from(r in TimedPatternStop,
          where:
            r.timed_pattern_id in subquery(
              from(t in TimedPattern,
                where: t.organization_id in ^organization_ids,
                select: t.id
              )
            )
        )
      )

      Repo.delete_all(from(st in StopTime, where: st.organization_id in ^organization_ids))
      Repo.delete_all(from(f in Frequency, where: f.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(t in TimedPattern, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(o in RoutePatternStop, where: o.organization_id in ^organization_ids))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id in ^organization_ids))

      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id in ^organization_ids))

      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id in ^organization_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(c in Calendar, where: c.organization_id in ^organization_ids))
      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end
end
