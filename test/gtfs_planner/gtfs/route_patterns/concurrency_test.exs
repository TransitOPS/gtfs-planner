defmodule GtfsPlanner.Gtfs.RoutePatterns.ConcurrencyTest do
  # AC-15/AC-16: `RoutePatterns.lock_published_route!/2` takes the scoped published version row
  # `FOR SHARE` before it takes the route `FOR UPDATE`, so a calendar mutation or a calendar
  # combination that owns the same version row cannot commit pattern or timing input between a
  # review load and its apply. The version lock is a scope, not an authorization: the route lock
  # keeps its own published refusal, and a caller that already holds the shared lock (the schedule
  # writers) re-locks the same row without upgrading or reversing the lock order.
  #
  # Every participant gets its own committing PostgreSQL connection through
  # `Sandbox.unboxed_run/2`. Contention is proven by polling `pg_blocking_pids/1` for the holder's
  # own backend, and the lock order is proven by probing the route row while the apply waits, so no
  # timing sleep decides any assertion.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner/gtfs/route_patterns/concurrency_test.exs`.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
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
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @collect_timeout 15_000
  @contention_timeout 10_000
  @poll_interval 10

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{supervisor: supervisor}
  end

  test "separate committing sessions serialize reviewed route writers and roll back audit failures",
       %{supervisor: supervisor} do
    fixture =
      unboxed(fn ->
        organization =
          organization_fixture(%{
            alias: "route-pattern-concurrency-#{System.system_time(:nanosecond)}"
          })

        version = gtfs_version_fixture(organization.id)
        route = route_fixture(organization.id, version.id)

        actor =
          user_fixture(%{
            email: "route-pattern-concurrency-#{System.system_time(:nanosecond)}@example.com"
          })

        organization_membership_fixture(actor, organization)

        audit = %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          actor_id: actor.id,
          actor_email: actor.email
        }

        stops = [
          stop_fixture(organization.id, version.id),
          stop_fixture(organization.id, version.id)
        ]

        {:ok, pattern} =
          Gtfs.create_pattern(
            route.route_id,
            %{
              route_pattern_name: "Concurrent",
              direction_id: 0,
              stops: Enum.map(stops, & &1.stop_id)
            },
            audit
          )

        {:ok, %{source_fingerprint: source}} =
          Gtfs.get_pattern(organization.id, version.id, route.route_id, pattern.id)

        operations = [
          {:details, %{headsign: "First writer"}},
          {:details, %{headsign: "Second writer"}}
        ]

        reviews =
          Enum.map(operations, fn operation ->
            {:ok, %{fingerprint: fingerprint}} = Gtfs.review(pattern.id, operation, source, audit)
            {operation, fingerprint}
          end)

        occurrence_ids =
          Repo.all(
            from o in RoutePatternStop, where: o.route_pattern_id == ^pattern.id, select: o.id
          )

        timing_ids =
          Repo.all(from t in TimedPattern, where: t.route_pattern_id == ^pattern.id, select: t.id)

        timing_stop_ids =
          Repo.all(
            from r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids, select: r.id
          )

        audit_ids = Repo.all(from l in ChangeLog, where: l.entity_id == ^pattern.id, select: l.id)

        membership_ids =
          Repo.all(
            from m in UserOrgMembership,
              where: m.organization_id == ^organization.id or m.user_id == ^actor.id,
              select: m.id
          )

        %{
          organization: organization,
          version: version,
          route: route,
          actor: actor,
          stops: stops,
          pattern: pattern,
          audit: audit,
          reviews: reviews,
          occurrence_ids: occurrence_ids,
          timing_ids: timing_ids,
          timing_stop_ids: timing_stop_ids,
          audit_ids: audit_ids,
          membership_ids: membership_ids
        }
      end)

    on_exit(fn -> cleanup(fixture) end)

    parent = self()

    workers =
      fixture.reviews
      |> Enum.with_index()
      |> Enum.map(fn {{operation, fingerprint}, index} ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:writer_ready, index})

          receive do
            {:commit, ^index} ->
              result =
                unboxed(fn ->
                  Gtfs.apply_review(fixture.pattern.id, operation, fingerprint, fixture.audit)
                end)

              send(parent, {:writer_done, index, result})
              result
          end
        end)
      end)

    assert_receive {:writer_ready, 0}
    assert_receive {:writer_ready, 1}
    send(Enum.at(workers, 0).pid, {:commit, 0})
    send(Enum.at(workers, 1).pid, {:commit, 1})

    outcomes =
      for _ <- 1..2 do
        assert_receive {:writer_done, index, result}, 10_000
        {index, result}
      end

    assert Enum.count(outcomes, fn {_index, result} -> match?({:ok, _}, result) end) == 1
    assert Enum.count(outcomes, fn {_index, result} -> result == {:error, :stale_review} end) == 1
    Enum.each(workers, &Task.await(&1, 10_000))

    post_race_state = unboxed(fn -> persisted_state(fixture.pattern.id) end)
    post_race_pattern = post_race_state.pattern
    post_race_audit_ids = post_race_state.audit_ids

    assert post_race_pattern.headsign in ["First writer", "Second writer"]
    assert length(post_race_audit_ids) == 2

    {before_failure, failure_review} =
      unboxed(fn ->
        current = persisted_state(fixture.pattern.id)

        {:ok, %{source_fingerprint: source}} =
          Gtfs.get_pattern(
            fixture.organization.id,
            fixture.version.id,
            fixture.route.route_id,
            fixture.pattern.id
          )

        operation = {:details, %{headsign: "Must roll back"}}

        {:ok, %{fingerprint: fingerprint}} =
          Gtfs.review(fixture.pattern.id, operation, source, fixture.audit)

        {current, {operation, fingerprint}}
      end)

    {operation, fingerprint} = failure_review
    bad_audit = %{fixture.audit | actor_id: nil}

    assert {:error, _} =
             unboxed(fn ->
               Gtfs.apply_review(fixture.pattern.id, operation, fingerprint, bad_audit)
             end)

    after_failure = unboxed(fn -> persisted_state(fixture.pattern.id) end)

    assert after_failure == before_failure
  end

  describe "version boundary" do
    test "a public timing apply waits at the version boundary and stays audited after release",
         %{supervisor: supervisor} do
      scope = seed_scope("timing-apply")
      on_exit(fn -> cleanup_scope(scope) end)

      {operation, fingerprint} = review_timing_edit(scope)
      before_clocks = stop_time_clocks(scope)
      before_audits = timing_audit_ids(scope)

      assert before_clocks == clocks(scope, [{"8:00:00", "8:00:00"}, {"08:10:00", "08:11:00"}])

      {holder, holder_backend} = hold_exclusive_version(scope, supervisor)
      parent = self()

      writer =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            backend = backend_pid()
            send(parent, {:writer_ready, self(), backend})

            receive do
              :go -> :ok
            end

            Gtfs.apply_review(scope.pattern.id, operation, fingerprint, scope.audit)
          end)
        end)

      assert_receive {:writer_ready, writer_pid, writer_backend}, @collect_timeout
      assert writer_pid == writer.pid
      send(writer.pid, :go)

      # The apply is genuinely waiting on the holder's own backend rather than merely slow.
      assert_blocked_by(writer_backend, holder_backend)

      # It waits before it takes the route lock: the route row is still free, so an implementation
      # that locked the route first and the version second cannot pass this check.
      assert_route_row_is_free(scope)

      # The reviewed materialization and its audit are untouched while the version is owned.
      assert stop_time_clocks(scope) == before_clocks
      assert timing_audit_ids(scope) == before_audits

      send(holder.pid, :release)
      assert Task.await(holder, @collect_timeout) == {:error, :released}

      assert {:ok, %{trips_updated: 1}} = Task.await(writer, @collect_timeout)

      # The committed apply materializes the reviewed offsets from the trip's own start.
      assert stop_time_clocks(scope) ==
               clocks(scope, [{"8:00:00", "8:00:00"}, {"08:11:00", "08:12:00"}])

      assert [%ChangeLog{action: "updated"} = audit] = new_timing_audits(scope, before_audits)
      assert audit.changed_fields["affected_trips"] == %{"from" => nil, "to" => 1}
    end

    test "the route lock keeps its published requirement behind the shared version lock" do
      scope = seed_scope("published-check")
      on_exit(fn -> cleanup_scope(scope) end)

      assert {:ok, %Route{route_id: route_id}} =
               lock_route(scope.organization.id, scope.version.id, scope.route.route_id)

      assert route_id == scope.route.route_id

      # A staging scope is lockable by the shared writer lock but still refused here.
      assert {:error, :not_found} =
               lock_route(scope.organization.id, scope.staging_version.id, scope.route.route_id)

      assert {:error, :not_found} =
               lock_route(scope.organization.id, Ecto.UUID.generate(), scope.route.route_id)

      assert {:error, :not_found} =
               lock_route(Ecto.UUID.generate(), scope.version.id, scope.route.route_id)

      assert {:error, :not_found} =
               lock_route(scope.organization.id, scope.version.id, "no_such_route")

      # The public lifecycle entrypoint keeps its return shape, its audit and its refusal for a
      # scope the shared lock accepts but this path does not publish.
      assert {:ok, %RoutePattern{} = created} =
               unboxed(fn ->
                 Gtfs.create_pattern(
                   scope.route.route_id,
                   second_pattern_attrs(scope),
                   scope.audit
                 )
               end)

      assert {:error, :not_found} =
               unboxed(fn ->
                 Gtfs.create_pattern(
                   scope.route.route_id,
                   second_pattern_attrs(scope),
                   %{scope.audit | gtfs_version_id: scope.staging_version.id}
                 )
               end)

      assert [%ChangeLog{action: "created", entity_type: "route_pattern"}] =
               unboxed(fn ->
                 Repo.all(from(l in ChangeLog, where: l.entity_id == ^created.id, order_by: l.id))
               end)

      refute unboxed(fn ->
               Repo.exists?(
                 from(p in RoutePattern,
                   where:
                     p.organization_id == ^scope.organization.id and
                       p.gtfs_version_id == ^scope.staging_version.id
                 )
               )
             end)
    end

    test "the same timing apply materializes through the production transaction adapter" do
      scope = seed_scope("production-adapter")
      on_exit(fn -> cleanup_scope(scope) end)

      {operation, fingerprint} = review_timing_edit(scope)

      previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
          :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
        end
      end)

      # The production adapter owns a real serializable Repo transaction, so this case proves the
      # shared version lock composes with the production boundary instead of the test adapter.
      Application.put_env(
        :gtfs_planner,
        :reviewed_apply_transaction,
        ReviewedApplyTransaction.Repo
      )

      assert {:ok, %{trips_updated: 1}} =
               unboxed(fn ->
                 Gtfs.apply_review(scope.pattern.id, operation, fingerprint, scope.audit)
               end)

      assert stop_time_clocks(scope) ==
               clocks(scope, [{"8:00:00", "8:00:00"}, {"08:11:00", "08:12:00"}])

      assert [%ChangeLog{action: "updated"}] = new_timing_audits(scope, [])
    end

    test "an apply whose transaction already holds the version share lock completes" do
      scope = seed_scope("preheld")
      on_exit(fn -> cleanup_scope(scope) end)

      {operation, fingerprint} = review_timing_edit(scope)

      # The shared lock is taken first, exactly where `Calendars.lock_service_for_reference!/3`
      # takes it for schedule callers; the apply re-locks the same row in the joined transaction.
      assert {:ok, {:ok, %{trips_updated: 1}}} =
               unboxed(fn ->
                 Repo.transaction(fn ->
                   _version =
                     Versions.lock_for_input_write!(scope.organization.id, scope.version.id)

                   Gtfs.apply_review(scope.pattern.id, operation, fingerprint, scope.audit)
                 end)
               end)

      assert stop_time_clocks(scope) ==
               clocks(scope, [{"8:00:00", "8:00:00"}, {"08:11:00", "08:12:00"}])
    end
  end

  describe "create_pattern/3 serializable boundary" do
    setup :verify_on_exit!

    setup do
      previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

      on_exit(fn ->
        case previous do
          {:ok, adapter} ->
            Application.put_env(:gtfs_planner, :reviewed_apply_transaction, adapter)

          :error ->
            Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
        end
      end)

      :ok
    end

    test "persists pattern descendants and audit under the production transaction adapter" do
      put_transaction_adapter(ReviewedApplyTransaction.Repo)

      fixture = unboxed(fn -> create_pattern_fixture() end)
      on_exit(fn -> cleanup_create_fixture(fixture) end)

      handler_id = {__MODULE__, make_ref()}
      owner = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:gtfs_planner, :repo, :query],
          fn _event, _measurements, metadata, destination ->
            if metadata.query == "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE" do
              send(destination, :serializable_boundary)
            end
          end,
          owner
        )

      try do
        assert {:ok, pattern} =
                 unboxed(fn ->
                   Gtfs.create_pattern(
                     fixture.route.route_id,
                     pattern_attrs(fixture),
                     fixture.audit
                   )
                 end)

        assert_received :serializable_boundary

        state = unboxed(fn -> created_pattern_state(fixture) end)

        assert [%RoutePattern{id: pattern_id}] = state.patterns
        assert pattern_id == pattern.id

        assert Enum.map(state.occurrences, & &1.stop_id) ==
                 Enum.map(fixture.stops, & &1.stop_id)

        assert [%TimedPattern{name: "Timing A"}] = state.timings
        assert length(state.timing_stops) == length(fixture.stops)

        assert [%ChangeLog{} = log] = state.audits
        assert log.entity_type == "route_pattern"
        assert log.entity_id == pattern.id
        assert log.action == "created"
        assert log.actor_email == fixture.audit.actor_email
      after
        :telemetry.detach(handler_id)
      end
    end

    test "forced deadlock then serialization conflicts rerun the whole closure and commit once" do
      put_transaction_adapter(ReviewedApplyTransactionMock)

      fixture = unboxed(fn -> create_pattern_fixture() end)
      on_exit(fn -> cleanup_create_fixture(fixture) end)

      owner = self()
      attempts = start_supervised!({Agent, fn -> 0 end})

      expect(ReviewedApplyTransactionMock, :run, 3, fn transaction ->
        attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)

        case attempt do
          1 ->
            # The closure completes and its transaction aborts like a commit-time
            # deadlock: none of this attempt's rows survive.
            Repo.transaction(fn ->
              result = transaction.()
              send(owner, {:closure_completed, attempt, result})
              raise postgrex_error("40P01", "deadlock detected")
            end)

          2 ->
            case Repo.transaction(fn ->
                   result = transaction.()
                   send(owner, {:closure_completed, attempt, result})
                   Repo.rollback(:forced_40001)
                 end) do
              {:error, :forced_40001} ->
                {:error, postgrex_error("40001", "serialization failure")}
            end

          3 ->
            ReviewedApplyTransaction.Repo.run(transaction)
        end
      end)

      assert {:ok, pattern} =
               unboxed(fn ->
                 Gtfs.create_pattern(
                   fixture.route.route_id,
                   pattern_attrs(fixture),
                   fixture.audit
                 )
               end)

      assert_received {:closure_completed, 1, %RoutePattern{id: first_id}}
      assert_received {:closure_completed, 2, %RoutePattern{id: second_id}}
      assert first_id != pattern.id
      assert second_id != pattern.id
      assert first_id != second_id

      state = unboxed(fn -> created_pattern_state(fixture) end)

      assert [%RoutePattern{id: pattern_id}] = state.patterns
      assert pattern_id == pattern.id
      assert Enum.map(state.occurrences, & &1.stop_id) == Enum.map(fixture.stops, & &1.stop_id)
      assert length(state.timing_stops) == length(fixture.stops)
      assert [%ChangeLog{action: "created"}] = state.audits
      assert Agent.get(attempts, & &1) == 3
    end

    test "exhausted retries return busy with no partial rows" do
      put_transaction_adapter(ReviewedApplyTransactionMock)

      fixture = unboxed(fn -> create_pattern_fixture() end)
      on_exit(fn -> cleanup_create_fixture(fixture) end)

      owner = self()
      attempts = start_supervised!({Agent, fn -> 0 end})

      expect(ReviewedApplyTransactionMock, :run, 3, fn transaction ->
        attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)

        Repo.transaction(fn ->
          result = transaction.()
          send(owner, {:closure_completed, attempt, result})
          raise postgrex_error("40001", "serialization failure")
        end)
      end)

      assert {:error, :busy} =
               unboxed(fn ->
                 Gtfs.create_pattern(
                   fixture.route.route_id,
                   pattern_attrs(fixture),
                   fixture.audit
                 )
               end)

      for attempt <- 1..3 do
        assert_received {:closure_completed, ^attempt, %RoutePattern{}}
      end

      assert unboxed(fn -> created_pattern_state(fixture) end) == %{
               patterns: [],
               occurrences: [],
               timings: [],
               timing_stops: [],
               audits: []
             }

      assert Agent.get(attempts, & &1) == 3
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp put_transaction_adapter(adapter),
    do: Application.put_env(:gtfs_planner, :reviewed_apply_transaction, adapter)

  defp postgrex_error(code, message) do
    Postgrex.Error.exception(
      postgres: %{
        code: code,
        severity: "ERROR",
        message: message
      }
    )
  end

  defp create_pattern_fixture do
    stamp = System.system_time(:nanosecond)

    organization =
      organization_fixture(%{alias: "route-pattern-create-serializable-#{stamp}"})

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    actor =
      user_fixture(%{email: "route-pattern-create-serializable-#{stamp}@example.com"})

    organization_membership_fixture(actor, organization)

    stops = [
      stop_fixture(organization.id, version.id),
      stop_fixture(organization.id, version.id)
    ]

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{
      organization: organization,
      version: version,
      route: route,
      actor: actor,
      stops: stops,
      audit: audit
    }
  end

  defp pattern_attrs(fixture) do
    %{
      route_pattern_name: "Serialized Create",
      direction_id: 0,
      stops: Enum.map(fixture.stops, & &1.stop_id)
    }
  end

  defp created_pattern_state(fixture) do
    pattern_ids =
      Repo.all(
        from p in RoutePattern,
          where:
            p.organization_id == ^fixture.organization.id and
              p.route_id == ^fixture.route.route_id,
          select: p.id
      )

    timing_ids =
      Repo.all(from t in TimedPattern, where: t.route_pattern_id in ^pattern_ids, select: t.id)

    %{
      patterns: Repo.all(from p in RoutePattern, where: p.id in ^pattern_ids, order_by: p.id),
      occurrences:
        Repo.all(
          from o in RoutePatternStop,
            where: o.route_pattern_id in ^pattern_ids,
            order_by: [asc: o.position, asc: o.id]
        ),
      timings: Repo.all(from t in TimedPattern, where: t.id in ^timing_ids, order_by: t.id),
      timing_stops:
        Repo.all(
          from r in TimedPatternStop,
            where: r.timed_pattern_id in ^timing_ids,
            order_by: r.id
        ),
      audits:
        Repo.all(
          from l in ChangeLog,
            where: l.organization_id == ^fixture.organization.id,
            order_by: l.id
        )
    }
  end

  defp cleanup_create_fixture(fixture) do
    unboxed(fn ->
      pattern_ids =
        Repo.all(
          from p in RoutePattern,
            where: p.organization_id == ^fixture.organization.id,
            select: p.id
        )

      timing_ids =
        Repo.all(from t in TimedPattern, where: t.route_pattern_id in ^pattern_ids, select: t.id)

      Repo.delete_all(from r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids)
      Repo.delete_all(from t in TimedPattern, where: t.id in ^timing_ids)
      Repo.delete_all(from o in RoutePatternStop, where: o.route_pattern_id in ^pattern_ids)
      Repo.delete_all(from p in RoutePattern, where: p.id in ^pattern_ids)
      Repo.delete_all(from l in ChangeLog, where: l.organization_id == ^fixture.organization.id)
      Repo.delete_all(from r in Route, where: r.id == ^fixture.route.id)
      Repo.delete_all(from s in Stop, where: s.id in ^Enum.map(fixture.stops, & &1.id))

      Repo.delete_all(
        from m in UserOrgMembership,
          where: m.organization_id == ^fixture.organization.id or m.user_id == ^fixture.actor.id
      )

      delete_versions!(from v in GtfsVersion, where: v.id == ^fixture.version.id)
      Repo.delete_all(from u in User, where: u.id == ^fixture.actor.id)
      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)
      :ok
    end)
  end

  defp persisted_state(pattern_id) do
    timing_ids =
      Repo.all(from t in TimedPattern, where: t.route_pattern_id == ^pattern_id, select: t.id)

    %{
      pattern: Repo.get!(RoutePattern, pattern_id),
      occurrences:
        Repo.all(
          from o in RoutePatternStop,
            where: o.route_pattern_id == ^pattern_id,
            order_by: o.id
        ),
      timings:
        Repo.all(from t in TimedPattern, where: t.route_pattern_id == ^pattern_id, order_by: t.id),
      timing_stops:
        Repo.all(
          from r in TimedPatternStop,
            where: r.timed_pattern_id in ^timing_ids,
            order_by: r.id
        ),
      audit_ids:
        Repo.all(
          from l in ChangeLog,
            where: l.entity_id == ^pattern_id,
            order_by: l.id,
            select: l.id
        )
    }
  end

  defp cleanup(fixture) do
    unboxed(fn ->
      audit_ids =
        Enum.uniq(
          fixture.audit_ids ++
            Repo.all(
              from l in ChangeLog,
                where: l.entity_id == ^fixture.pattern.id,
                select: l.id
            )
        )

      Repo.delete_all(from l in ChangeLog, where: l.id in ^audit_ids)
      Repo.delete_all(from r in TimedPatternStop, where: r.id in ^fixture.timing_stop_ids)
      Repo.delete_all(from t in TimedPattern, where: t.id in ^fixture.timing_ids)
      Repo.delete_all(from o in RoutePatternStop, where: o.id in ^fixture.occurrence_ids)
      Repo.delete_all(from p in RoutePattern, where: p.id == ^fixture.pattern.id)
      Repo.delete_all(from r in Route, where: r.id == ^fixture.route.id)
      Repo.delete_all(from s in Stop, where: s.id in ^Enum.map(fixture.stops, & &1.id))
      Repo.delete_all(from m in UserOrgMembership, where: m.id in ^fixture.membership_ids)
      delete_versions!(from v in GtfsVersion, where: v.id == ^fixture.version.id)
      Repo.delete_all(from u in User, where: u.id == ^fixture.actor.id)
      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)

      refute Repo.exists?(from l in ChangeLog, where: l.id in ^audit_ids)
      refute Repo.exists?(from r in TimedPatternStop, where: r.id in ^fixture.timing_stop_ids)
      refute Repo.exists?(from t in TimedPattern, where: t.id in ^fixture.timing_ids)
      refute Repo.exists?(from o in RoutePatternStop, where: o.id in ^fixture.occurrence_ids)
      refute Repo.exists?(from p in RoutePattern, where: p.id == ^fixture.pattern.id)
      refute Repo.exists?(from r in Route, where: r.id == ^fixture.route.id)
      refute Repo.exists?(from s in Stop, where: s.id in ^Enum.map(fixture.stops, & &1.id))
      refute Repo.exists?(from m in UserOrgMembership, where: m.id in ^fixture.membership_ids)
      refute Repo.exists?(from v in GtfsVersion, where: v.id == ^fixture.version.id)
      refute Repo.exists?(from u in User, where: u.id == ^fixture.actor.id)
      refute Repo.exists?(from o in Organization, where: o.id == ^fixture.organization.id)
      :ok
    end)
  end

  # -- Version-boundary fixtures ---------------------------------------------

  # One committed scope: an organization with its published version, a staging version used to
  # pin the published requirement, one route with a two-stop pattern, and one linked trip whose
  # stop times already match the timing row for row.
  defp seed_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization = organization_fixture(%{alias: "route-pattern-boundary-#{suffix}-#{unique}"})
      version = gtfs_version_fixture(organization.id)

      {:ok, staging_version} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Staging #{unique}"})

      route = route_fixture(organization.id, version.id)
      actor = editor_fixture(organization)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      stops = [
        stop_fixture(organization.id, version.id, %{stop_name: "A"}),
        stop_fixture(organization.id, version.id, %{stop_name: "B"})
      ]

      {:ok, pattern} =
        Gtfs.create_pattern(
          route.route_id,
          %{
            route_pattern_name: "Boundary #{suffix}",
            direction_id: 0,
            stops: Enum.map(stops, & &1.stop_id)
          },
          audit
        )

      [timing] = Repo.all(from(t in TimedPattern, where: t.route_pattern_id == ^pattern.id))
      set_timing_offsets(timing, [{0, 0}, {600, 660}])

      trip = linked_trip(organization.id, version.id, route.route_id, pattern, timing, stops)

      %{
        organization: organization,
        version: version,
        staging_version: staging_version,
        route: route,
        actor: actor,
        audit: audit,
        stops: stops,
        pattern: pattern,
        timing: timing,
        trip: trip
      }
    end)
  end

  defp set_timing_offsets(timing, values) do
    rows =
      Repo.all(
        from(r in TimedPatternStop,
          join: o in RoutePatternStop,
          on: o.id == r.route_pattern_stop_id,
          where: r.timed_pattern_id == ^timing.id,
          order_by: o.position
        )
      )

    Enum.zip(rows, values)
    |> Enum.each(fn {row, {arrival, departure}} ->
      row
      |> Ecto.Changeset.change(%{arrival_offset: arrival, departure_offset: departure})
      |> Repo.update!()
    end)
  end

  defp linked_trip(organization_id, version_id, route_id, pattern, timing, stops) do
    trip =
      trip_fixture(organization_id, version_id, route_id)
      |> Ecto.Changeset.change(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
      |> Repo.update!()

    Enum.zip([stops, [10, 40], ["8:00:00", "08:10:00"], ["8:00:00", "08:11:00"]])
    |> Enum.each(fn {stop, sequence, arrival, departure} ->
      %StopTime{}
      |> StopTime.changeset(%{
        trip_id: trip.trip_id,
        stop_id: stop.stop_id,
        stop_sequence: sequence,
        arrival_time: arrival,
        departure_time: departure,
        organization_id: organization_id,
        gtfs_version_id: version_id,
        pickup_type: 2,
        drop_off_type: 3,
        timepoint: 1
      })
      |> Repo.insert!()
    end)

    trip
  end

  defp second_pattern_attrs(scope) do
    %{
      route_pattern_name: "Second",
      direction_id: 1,
      stops: Enum.map(scope.stops, & &1.stop_id)
    }
  end

  # A review binds the exact offsets that the apply must materialize; both calls run through the
  # same public entrypoints the editor uses.
  defp review_timing_edit(scope, offsets \\ [{0, 0}, {660, 720}]) do
    unboxed(fn ->
      {:ok, %{source_fingerprint: source}} =
        Gtfs.get_pattern(
          scope.organization.id,
          scope.version.id,
          scope.route.route_id,
          scope.pattern.id
        )

      rows =
        scope.pattern.id
        |> pattern_occurrences()
        |> Enum.zip(offsets)
        |> Enum.map(fn {occurrence, {arrival, departure}} ->
          %{
            route_pattern_stop_id: occurrence.id,
            arrival_offset: arrival,
            departure_offset: departure
          }
        end)

      operation = {:timing, scope.timing.id, %{rows: rows}}

      {:ok, %{fingerprint: fingerprint}} =
        Gtfs.review(scope.pattern.id, operation, source, scope.audit)

      {operation, fingerprint}
    end)
  end

  defp pattern_occurrences(pattern_id) do
    Repo.all(
      from(o in RoutePatternStop, where: o.route_pattern_id == ^pattern_id, order_by: o.position)
    )
  end

  defp stop_time_clocks(scope) do
    unboxed(fn ->
      Repo.all(
        from(st in StopTime,
          where:
            st.organization_id == ^scope.organization.id and st.trip_id == ^scope.trip.trip_id,
          order_by: [asc: st.stop_sequence, asc: st.id],
          select: {st.stop_id, st.arrival_time, st.departure_time}
        )
      )
    end)
  end

  defp clocks(scope, values) do
    scope.stops
    |> Enum.map(& &1.stop_id)
    |> Enum.zip(values)
    |> Enum.map(fn {stop_id, {arrival, departure}} -> {stop_id, arrival, departure} end)
  end

  defp timing_audit_ids(scope) do
    unboxed(fn ->
      Repo.all(
        from(l in ChangeLog,
          where: l.entity_type == "timed_pattern" and l.entity_id == ^scope.timing.id,
          order_by: l.id,
          select: l.id
        )
      )
    end)
  end

  defp new_timing_audits(scope, before_ids) do
    unboxed(fn ->
      Repo.all(
        from(l in ChangeLog,
          where:
            l.entity_type == "timed_pattern" and l.entity_id == ^scope.timing.id and
              l.id not in ^before_ids,
          order_by: l.id
        )
      )
    end)
  end

  defp lock_route(organization_id, version_id, route_id) do
    unboxed(fn ->
      Repo.transaction(fn ->
        RoutePatterns.lock_published_route!(
          %AuditContext{organization_id: organization_id, gtfs_version_id: version_id},
          route_id
        )
      end)
    end)
  end

  # The waiting apply must hold no route lock: taking the route row `FOR UPDATE` here fails with a
  # loud lock timeout if the writer locked the route before it reached the version boundary.
  defp assert_route_row_is_free(scope) do
    assert {:ok, %Route{id: route_row_id}} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL lock_timeout = '2s'")
                 Repo.one(from(r in Route, where: r.id == ^scope.route.id, lock: "FOR UPDATE"))
               end)
             end)

    assert route_row_id == scope.route.id
  end

  defp hold_exclusive_version(scope, supervisor) do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        lock_version_until_released(scope, parent)
      end)

    assert_receive {:version_held, holder_pid, holder_backend}, @contention_timeout
    assert holder_pid == holder.pid
    {holder, holder_backend}
  end

  defp lock_version_until_released(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.one(
          from(v in GtfsVersion,
            where: v.id == ^scope.version.id and v.organization_id == ^scope.organization.id,
            lock: "FOR UPDATE"
          )
        )

        send(parent, {:version_held, self(), backend_pid()})

        receive do
          :release -> Repo.rollback(:released)
        end
      end)
    end)
  end

  defp assert_blocked_by(backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout

    case unboxed(fn -> await_blocker(backend, holder_backend, deadline) end) do
      :ok ->
        :ok

      {:error, blocked_by} ->
        flunk(
          "expected backend #{backend} to wait on #{holder_backend}, saw blocking pids #{inspect(blocked_by)}"
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

  defp cleanup_scope(scope) do
    unboxed(fn ->
      organization_id = scope.organization.id

      Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
      Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))

      Repo.delete_all(
        from(r in TimedPatternStop,
          where:
            r.timed_pattern_id in subquery(
              from(t in TimedPattern, where: t.organization_id == ^organization_id, select: t.id)
            )
        )
      )

      Repo.delete_all(from(t in TimedPattern, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(o in RoutePatternStop, where: o.organization_id == ^organization_id))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id == ^organization_id))
      Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))

      Repo.delete_all(
        from(m in UserOrgMembership,
          where: m.organization_id == ^organization_id or m.user_id == ^scope.actor.id
        )
      )

      delete_versions!(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(u in User, where: u.id == ^scope.actor.id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))

      refute Repo.exists?(from(o in Organization, where: o.id == ^organization_id))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      :ok
    end)
  end
end
