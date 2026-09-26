defmodule GtfsPlanner.Gtfs.RoutePatterns.ConcurrencyTest do
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.Repo

  test "separate committing sessions serialize reviewed route writers and roll back audit failures" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

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

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

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
      Repo.delete_all(from v in GtfsVersion, where: v.id == ^fixture.version.id)
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
end
