defmodule GtfsPlanner.Gtfs.RouteLifecycleConcurrencyTest do
  @moduledoc """
  R5 M1 opposing-transaction matrix for the reviewed route deletion cascade.

  Each race forces the documented snapshot-before-route-lock-wait ordering with
  a real committing writer and the production `ReviewedApplyTransaction.Repo`
  adapter: a gate transaction holds the version row `FOR SHARE` so
  `Gtfs.delete_route/4` blocks at its first statement (snapshot taken, version
  `FOR UPDATE` waiting) while the competing same-version writer commits. The
  gate then releases and the stale acknowledgement must be refused with no
  surviving orphan. Committed fixtures live outside the shared Sandbox; tasks
  are supervised and synchronized with explicit messages and observed Postgres
  lock waits only.
  """

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
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

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

    :ok
  end

  test "create_pattern/3 committed after the delete snapshot forces stale refusal, never an orphan" do
    parent = self()
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.CreateRace})
    fixture = unboxed(fn -> lifecycle_fixture() end)
    on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)

    {:ok, %{fingerprint: fingerprint}} =
      unboxed(fn -> Gtfs.review_route_deletion(fixture.route.route_id, fixture.audit) end)

    gate = start_version_gate(supervisor, fixture.version.id, parent)
    assert_receive :gate_ready, 5_000

    deleter =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          send(parent, {:deleter_backend, backend_pid()})

          result = Gtfs.delete_route(fixture.route.route_id, fingerprint, true, fixture.audit)

          send(parent, {:deleter_done, result})
          result
        end)
      end)

    assert_receive {:deleter_backend, deleter_backend}, 5_000
    unboxed(fn -> assert_postgres_lock_wait!(deleter_backend) end)

    # The real writer commits after deletion's snapshot but before its route
    # lock is acquired (M1 ordering).
    assert {:ok, pattern} =
             unboxed(fn ->
               Gtfs.create_pattern(fixture.route.route_id, pattern_attrs(fixture), fixture.audit)
             end)

    send(gate.pid, :release)
    assert_receive {:deleter_done, delete_result}, 15_000
    Task.await(deleter, 15_000)

    assert {:error, {:stale_review, fresh}} = delete_result
    assert fresh.fingerprint != fingerprint
    assert category_count(fresh, "patterns") == 1

    state = unboxed(fn -> post_race_state(fixture) end)

    # Never a surviving orphan: the route survives with the writer's complete
    # pattern because the stale acknowledgement changed nothing.
    assert [%Route{id: route_uuid}] = state.routes
    assert route_uuid == fixture.route.id
    assert [%RoutePattern{id: pattern_id}] = state.patterns
    assert pattern_id == pattern.id
    assert length(state.occurrences) == length(fixture.stops)
    assert [%TimedPattern{name: "Timing A"}] = state.timings
    assert length(state.timing_stops) == length(fixture.stops)
  end

  test "build_route_patterns/2 committed after the delete snapshot requires a new acknowledged review" do
    parent = self()
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.DeriveRace})
    fixture = unboxed(fn -> lifecycle_fixture(with_trip: true) end)
    on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)

    {:ok, %{fingerprint: fingerprint}} =
      unboxed(fn -> Gtfs.review_route_deletion(fixture.route.route_id, fixture.audit) end)

    gate = start_version_gate(supervisor, fixture.version.id, parent)
    assert_receive :gate_ready, 5_000

    deleter =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          send(parent, {:deleter_backend, backend_pid()})

          result = Gtfs.delete_route(fixture.route.route_id, fingerprint, true, fixture.audit)

          send(parent, {:deleter_done, result})
          result
        end)
      end)

    assert_receive {:deleter_backend, deleter_backend}, 5_000
    unboxed(fn -> assert_postgres_lock_wait!(deleter_backend) end)

    # Editor-provenance derivation runs through the same serializable/retry
    # boundary and commits while deletion waits at its snapshot.
    assert {:ok, summary} =
             unboxed(fn -> Gtfs.build_route_patterns(fixture.route.route_id, fixture.audit) end)

    assert summary.patterns_created == 1
    assert summary.trips_linked == 1

    send(gate.pid, :release)
    assert_receive {:deleter_done, delete_result}, 15_000
    Task.await(deleter, 15_000)

    assert {:error, {:stale_review, fresh}} = delete_result
    assert fresh.fingerprint != fingerprint
    assert category_count(fresh, "patterns") == 1

    state = unboxed(fn -> post_race_state(fixture) end)
    assert [%Route{}] = state.routes
    assert [%RoutePattern{}] = state.patterns
    assert [%Trip{pattern_derivation_state: "linked"}] = state.trips
  end

  test "zero-dependant review followed by pattern insertion resets the acknowledgement" do
    fixture = unboxed(fn -> lifecycle_fixture() end)
    on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)

    {:ok, previous_review} =
      unboxed(fn -> Gtfs.review_route_deletion(fixture.route.route_id, fixture.audit) end)

    assert previous_review.empty?

    assert {:ok, _pattern} =
             unboxed(fn ->
               Gtfs.create_pattern(fixture.route.route_id, pattern_attrs(fixture), fixture.audit)
             end)

    assert {:error, {:stale_review, fresh}} =
             unboxed(fn ->
               Gtfs.delete_route(
                 fixture.route.route_id,
                 previous_review.fingerprint,
                 true,
                 fixture.audit
               )
             end)

    assert category_count(fresh, "patterns") == 1

    changes = Gtfs.Routes.deletion_review_changes(previous_review.categories, fresh.categories)

    assert Enum.map(changes, & &1.key) == [
             "patterns",
             "pattern_stops",
             "timed_patterns",
             "timed_pattern_stops"
           ]

    assert %{key: "patterns", markers: markers} = Enum.find(changes, &(&1.key == "patterns"))
    assert :count_changed in markers

    # The stale acknowledgement changed nothing and a fresh acknowledged review
    # is required before the route may be deleted.
    state = unboxed(fn -> post_race_state(fixture) end)
    assert [%Route{}] = state.routes
    assert [%RoutePattern{}] = state.patterns

    assert {:error, :not_acknowledged} =
             unboxed(fn ->
               Gtfs.delete_route(fixture.route.route_id, fresh.fingerprint, false, fixture.audit)
             end)
  end

  test "same-count schedule update changes review contents and resets the acknowledgement" do
    fixture = unboxed(fn -> lifecycle_fixture() end)
    on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)

    {pattern, timing, trip} =
      unboxed(fn ->
        {:ok, pattern} =
          Gtfs.create_pattern(fixture.route.route_id, pattern_attrs(fixture), fixture.audit)

        timing = Repo.one!(from t in TimedPattern, where: t.route_pattern_id == ^pattern.id)

        {:ok, %{trips: [trip]}} =
          Gtfs.create_trips(
            fixture.route.route_id,
            %{
              pattern_id: pattern.id,
              timed_pattern_id: timing.id,
              service_id: fixture.calendar.service_id,
              start_time: "06:00:00"
            },
            fixture.audit
          )

        {pattern, timing, trip}
      end)

    {:ok, previous_review} =
      unboxed(fn -> Gtfs.review_route_deletion(fixture.route.route_id, fixture.audit) end)

    assert category_count(previous_review, "trips") == 1

    assert {:ok, updated} =
             unboxed(fn ->
               Gtfs.update_trip(
                 fixture.route.route_id,
                 trip.id,
                 %{trip_headsign: "Replaced Headsign", start_time: "06:00:00"},
                 trip.updated_at,
                 fixture.audit
               )
             end)

    assert updated.trip_headsign == "Replaced Headsign"

    assert {:error, {:stale_review, fresh}} =
             unboxed(fn ->
               Gtfs.delete_route(
                 fixture.route.route_id,
                 previous_review.fingerprint,
                 true,
                 fixture.audit
               )
             end)

    assert category_count(fresh, "trips") == 1

    # Equal totals with changed contents are explained and reset the
    # acknowledgement (AC-13).
    changes = Gtfs.Routes.deletion_review_changes(previous_review.categories, fresh.categories)

    assert %{key: "trips", markers: [:contents_changed]} =
             Enum.find(changes, &(&1.key == "trips"))

    state = unboxed(fn -> post_race_state(fixture) end)
    assert [%Route{}] = state.routes
    assert [%RoutePattern{id: found_pattern_id}] = state.patterns
    assert found_pattern_id == pattern.id
    assert [%Trip{trip_headsign: "Replaced Headsign"}] = state.trips
    assert [%TimedPattern{id: found_timing_id}] = state.timings
    assert found_timing_id == timing.id
  end

  test "schedule insert committed after the delete snapshot forces stale refusal" do
    parent = self()
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.ScheduleRace})
    fixture = unboxed(fn -> lifecycle_fixture() end)
    on_exit(fn -> unboxed(fn -> cleanup_fixture(fixture) end) end)

    {pattern, timing} =
      unboxed(fn ->
        {:ok, pattern} =
          Gtfs.create_pattern(fixture.route.route_id, pattern_attrs(fixture), fixture.audit)

        timing = Repo.one!(from t in TimedPattern, where: t.route_pattern_id == ^pattern.id)
        {pattern, timing}
      end)

    {:ok, %{fingerprint: fingerprint}} =
      unboxed(fn -> Gtfs.review_route_deletion(fixture.route.route_id, fixture.audit) end)

    gate = start_version_gate(supervisor, fixture.version.id, parent)
    assert_receive :gate_ready, 5_000

    deleter =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          send(parent, {:deleter_backend, backend_pid()})

          result = Gtfs.delete_route(fixture.route.route_id, fingerprint, true, fixture.audit)

          send(parent, {:deleter_done, result})
          result
        end)
      end)

    assert_receive {:deleter_backend, deleter_backend}, 5_000
    unboxed(fn -> assert_postgres_lock_wait!(deleter_backend) end)

    assert {:ok, %{trips: [_trip]}} =
             unboxed(fn ->
               Gtfs.create_trips(
                 fixture.route.route_id,
                 %{
                   pattern_id: pattern.id,
                   timed_pattern_id: timing.id,
                   service_id: fixture.calendar.service_id,
                   start_time: "09:15:00"
                 },
                 fixture.audit
               )
             end)

    send(gate.pid, :release)
    assert_receive {:deleter_done, delete_result}, 15_000
    Task.await(deleter, 15_000)

    assert {:error, {:stale_review, fresh}} = delete_result
    assert fresh.fingerprint != fingerprint

    state = unboxed(fn -> post_race_state(fixture) end)
    assert [%Route{}] = state.routes
    assert [%Trip{}] = state.trips
  end

  # --- fixtures and race helpers -------------------------------------------

  defp lifecycle_fixture(opts \\ []) do
    stamp = System.system_time(:nanosecond)

    organization =
      organization_fixture(%{alias: "route-lifecycle-race-#{stamp}"})

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    calendar = calendar_fixture(organization.id, version.id)

    actor =
      user_fixture(%{email: "route-lifecycle-race-#{stamp}@example.com"})

    {:ok, _membership} =
      Organizations.add_user_to_organization(actor.id, organization.id, [
        "pathways_studio_editor"
      ])

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

    trip =
      if Keyword.get(opts, :with_trip, false) do
        trip =
          trip_fixture(organization.id, version.id, route.route_id, %{
            direction_id: 0,
            trip_headsign: nil
          })

        stop_time_fixture(organization.id, version.id, trip.trip_id, Enum.at(stops, 0).stop_id, %{
          stop_sequence: 1
        })

        stop_time_fixture(organization.id, version.id, trip.trip_id, Enum.at(stops, 1).stop_id, %{
          stop_sequence: 2
        })

        trip
      end

    %{
      organization: organization,
      version: version,
      route: route,
      calendar: calendar,
      actor: actor,
      audit: audit,
      stops: stops,
      trip: trip
    }
  end

  defp pattern_attrs(fixture) do
    %{
      route_pattern_name: "Lifecycle Race",
      direction_id: 0,
      stops: Enum.map(fixture.stops, & &1.stop_id)
    }
  end

  # Holds the version row FOR SHARE in its own committing session. Deletion's
  # first statement (version FOR UPDATE) blocks after its snapshot is taken,
  # while writers that only take the version share lock commit freely.
  defp start_version_gate(supervisor, version_id, parent) do
    Task.Supervisor.async_nolink(supervisor, fn -> gate_task(version_id, parent) end)
  end

  defp gate_task(version_id, parent) do
    unboxed(fn -> hold_version_share(version_id, parent) end)
  end

  # The gate's own committing transaction: take the share lock, announce
  # readiness, and hold the row until the parent releases it.
  defp hold_version_share(version_id, parent) do
    Repo.transaction(fn ->
      Repo.all(from v in GtfsVersion, where: v.id == ^version_id, lock: "FOR SHARE")
      send(parent, :gate_ready)

      receive do
        :release -> :ok
      end
    end)
  end

  defp backend_pid do
    %Postgrex.Result{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp assert_postgres_lock_wait!(backend_pid, attempts_remaining \\ 200)

  defp assert_postgres_lock_wait!(_backend_pid, 0) do
    flunk("delete_route did not block on the version gate after its snapshot")
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

  defp category_count(review, key) do
    review.categories |> Enum.find(&(&1.key == key)) |> Map.fetch!(:count)
  end

  defp post_race_state(fixture) do
    pattern_ids = pattern_ids(fixture)
    timing_ids = timing_ids(pattern_ids)

    %{
      routes: Repo.all(from r in Route, where: r.organization_id == ^fixture.organization.id),
      patterns: Repo.all(from p in RoutePattern, where: p.id in ^pattern_ids),
      occurrences:
        Repo.all(from o in RoutePatternStop, where: o.route_pattern_id in ^pattern_ids),
      timings: Repo.all(from t in TimedPattern, where: t.id in ^timing_ids),
      timing_stops:
        Repo.all(from r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids),
      trips: Repo.all(from t in Trip, where: t.organization_id == ^fixture.organization.id)
    }
  end

  defp pattern_ids(fixture) do
    Repo.all(
      from p in RoutePattern,
        where: p.organization_id == ^fixture.organization.id,
        select: p.id
    )
  end

  defp timing_ids(pattern_ids) do
    Repo.all(from t in TimedPattern, where: t.route_pattern_id in ^pattern_ids, select: t.id)
  end

  defp cleanup_fixture(fixture) do
    pattern_ids = pattern_ids(fixture)
    timing_ids = timing_ids(pattern_ids)

    trip_ids =
      Repo.all(
        from t in Trip, where: t.organization_id == ^fixture.organization.id, select: t.trip_id
      )

    Repo.delete_all(from s in StopTime, where: s.trip_id in ^trip_ids)
    Repo.delete_all(from f in Frequency, where: f.trip_id in ^trip_ids)
    Repo.delete_all(from t in Trip, where: t.trip_id in ^trip_ids)
    Repo.delete_all(from r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids)
    Repo.delete_all(from t in TimedPattern, where: t.id in ^timing_ids)
    Repo.delete_all(from o in RoutePatternStop, where: o.route_pattern_id in ^pattern_ids)
    Repo.delete_all(from p in RoutePattern, where: p.id in ^pattern_ids)
    Repo.delete_all(from r in Route, where: r.organization_id == ^fixture.organization.id)
    Repo.delete_all(from s in Stop, where: s.organization_id == ^fixture.organization.id)
    Repo.delete_all(from c in Calendar, where: c.organization_id == ^fixture.organization.id)
    Repo.delete_all(from l in ChangeLog, where: l.organization_id == ^fixture.organization.id)

    Repo.delete_all(
      from m in UserOrgMembership,
        where: m.organization_id == ^fixture.organization.id or m.user_id == ^fixture.actor.id
    )

    Repo.delete_all(from v in GtfsVersion, where: v.organization_id == ^fixture.organization.id)
    Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)
    Repo.delete_all(from u in User, where: u.id == ^fixture.actor.id)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
