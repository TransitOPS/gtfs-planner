defmodule GtfsPlanner.Gtfs.RoutePatterns.HeadsignResetUndoTest do
  @moduledoc """
  Focused coverage for the fenced reset and undo operations (EV-8): a reset
  writes each selected in-scope trip's current effective default through the
  fenced writer and returns its undo; Undo restores the recorded prior default
  and exact prior trip values, including nil; both fences write nothing when
  the default or any trip moved since; out-of-scope ids are refused; and two
  concurrent resets of one trip leave exactly one write.

  The focused gate command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_hs20 mix test
  test/gtfs_planner/gtfs/route_patterns/headsign_reset_undo_test.exs`.
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
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Headsigns
  alias GtfsPlanner.Gtfs.RecentChanges
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @old_default "Lincoln City"
  @new_default "Lincoln City via Depoe Bay"
  @typo "Lincoln city"

  setup context do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

    unless context[:unboxed] do
      # The same sandbox shape `GtfsPlanner.DataCase` sets up; skipped for the
      # unboxed concurrency case so every participant commits on its own
      # connection, exactly as in route_patterns/concurrency_test.exs.
      owner = Sandbox.start_owner!(Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(owner) end)
    end

    %{supervisor: supervisor}
  end

  describe "reset_trip_headsigns/4" do
    setup do
      headsign_scope()
    end

    test "a reset writes each selected trip's current effective default and returns its undo",
         %{
           audit: audit,
           pattern: pattern,
           typo_trip: typo,
           follower: follower,
           blank: blank
         } = context do
      selections = [
        %{id: typo.id, from: @typo},
        %{id: blank.id, from: nil},
        %{id: follower.id, from: @old_default}
      ]

      assert {:ok, %{applied: applied, undo: %{default: nil, trips: applied}}} =
               Gtfs.reset_trip_headsigns(pattern.id, :pattern, selections, audit)

      # The no-op follower writes neither trip row nor audit log.
      written = [
        %{id: typo.id, trip_id: "hs20-typo", from: @typo, to: @old_default},
        %{id: blank.id, trip_id: "hs20-blank", from: nil, to: @old_default}
      ]

      assert applied == written

      assert %{headsign: @old_default} = Repo.reload!(pattern)
      assert headsign_of(typo) == @old_default
      assert headsign_of(blank) == @old_default
      assert headsign_of(follower) == @old_default

      # The reset audits exactly the written trips under one operation id and
      # writes no pattern or timing row, because it never moves a default.
      logs = trip_logs(context)
      assert length(logs) == 2
      operation_ids = Enum.map(logs, & &1.changed_fields["operation_id"])
      assert Enum.uniq(operation_ids) == [hd(operation_ids)]
      assert Enum.sort(Enum.map(logs, & &1.entity_id)) == Enum.sort([typo.id, blank.id])
      assert default_rows_audited(context) == []
    end

    test "a repeated reset of already-reset trips writes nothing again",
         %{audit: audit, pattern: pattern, typo_trip: typo, blank: blank} = context do
      assert {:ok, %{applied: [_one, _two]}} =
               Gtfs.reset_trip_headsigns(
                 pattern.id,
                 :pattern,
                 [%{id: typo.id, from: @typo}, %{id: blank.id, from: nil}],
                 audit
               )

      logs_before = change_log_count(context)

      assert {:ok, %{applied: [], undo: %{default: nil, trips: []}}} =
               Gtfs.reset_trip_headsigns(
                 pattern.id,
                 :pattern,
                 [%{id: typo.id, from: @old_default}, %{id: blank.id, from: @old_default}],
                 audit
               )

      assert change_log_count(context) == logs_before
    end

    test "a timing-scope reset writes the timing's own effective default",
         %{audit: audit, pattern: pattern, school: school, school_trip: school_trip} do
      school_trip
      |> Ecto.Changeset.change(trip_headsign: "Edited elsewhere")
      |> Repo.update!()

      assert {:ok, %{applied: [change], undo: %{default: nil, trips: [change]}}} =
               Gtfs.reset_trip_headsigns(
                 pattern.id,
                 {:timing, school.id},
                 [%{id: school_trip.id, from: "Edited elsewhere"}],
                 audit
               )

      assert change.to == "Schools"
      assert headsign_of(school_trip) == "Schools"
    end

    test "a shielded, foreign-pattern or cross-organization trip is refused with nothing written",
         %{
           organization: organization,
           version: version,
           route: route,
           audit: audit,
           pattern: pattern,
           school_trip: school_trip
         } = context do
      other_pattern =
        route_pattern_fixture(organization.id, version.id, %{
          route_id: route.route_id,
          route_pattern_id: "HS20-1"
        })

      other_trip =
        trip_fixture(organization.id, version.id, route.route_id, trip_id: "hs20-other")
        |> trip_pattern_metadata_fixture(%{
          route_pattern_id: other_pattern.route_pattern_id,
          pattern_derivation_state: "custom",
          pattern_derivation_reason: "missing_route"
        })

      foreign_org = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_org.id)
      foreign_route = route_fixture(foreign_org.id, foreign_version.id)

      foreign_bundle =
        schedule_pattern_fixture(foreign_org.id, foreign_version.id, %{
          route_id: foreign_route.route_id,
          route_pattern_id: "FOREIGN-0",
          headsign: "Elsewhere",
          stops: [{"FA", 0, 0, 1}, {"FB", 60, 60, 1}]
        })

      foreign_trip =
        schedule_trip_fixture(
          foreign_org.id,
          foreign_version.id,
          foreign_route.route_id,
          foreign_bundle,
          %{service_id: "WK", trip_id: "foreign-1", trip_headsign: "Elsewhere"}
        )
        |> Map.fetch!(:trip)

      trips_before = raw_headsigns([school_trip, other_trip, foreign_trip])
      logs_before = change_log_count(context)

      for invalid <- [
            %{id: school_trip.id, from: "Schools"},
            %{id: other_trip.id, from: nil},
            %{id: foreign_trip.id, from: "Elsewhere"},
            %{id: "not-a-uuid", from: nil}
          ] do
        assert {:error, :invalid_selection} =
                 Gtfs.reset_trip_headsigns(pattern.id, :pattern, [invalid], audit)
      end

      assert change_log_count(context) == logs_before
      assert raw_headsigns([school_trip, other_trip, foreign_trip]) == trips_before
    end
  end

  describe "undo_headsign_update/3" do
    setup do
      headsign_scope()
    end

    test "undoing a reset restores the exact prior trip values, including nil",
         %{audit: audit, pattern: pattern, typo_trip: typo, blank: blank} = context do
      selections = [%{id: typo.id, from: @typo}, %{id: blank.id, from: nil}]

      assert {:ok, %{applied: _, undo: reset_undo}} =
               Gtfs.reset_trip_headsigns(pattern.id, :pattern, selections, audit)

      assert {:ok, %{applied: applied}} =
               Gtfs.undo_headsign_update(pattern.id, reset_undo, audit)

      restored = [
        %{id: typo.id, trip_id: "hs20-typo", from: @old_default, to: @typo},
        %{id: blank.id, trip_id: "hs20-blank", from: @old_default, to: nil}
      ]

      assert applied == restored

      assert headsign_of(typo) == @typo
      assert Repo.reload!(blank).trip_headsign == nil
      assert %{headsign: @old_default} = Repo.reload!(pattern)

      # The undo appends trip rows under a fresh operation id and deletes none.
      logs = trip_logs(context)
      assert length(logs) == 4

      operation_ids = Enum.map(logs, & &1.changed_fields["operation_id"])
      assert Enum.all?(operation_ids, &is_binary/1)
      assert length(Enum.uniq(operation_ids)) == 2
      assert default_rows_audited(context) == []
    end

    test "undoing a default save restores the prior default and exact trip values",
         %{audit: audit, pattern: pattern, typo_trip: typo, blank: blank} = context do
      operation = {:details, %{headsign: @new_default}, %{headsign_trip_ids: [typo.id, blank.id]}}

      assert {:ok, %{fingerprint: fingerprint}} = Gtfs.review(pattern.id, operation, nil, audit)

      assert {:ok, %{trips_updated: 0, headsign_undo: undo}} =
               Gtfs.apply_review(pattern.id, operation, fingerprint, audit)

      assert %{default: %{scope: :pattern, from: @old_default, to: @new_default}} = undo

      assert {:ok, %{applied: applied}} = Gtfs.undo_headsign_update(pattern.id, undo, audit)

      # The saved undo carries the writer's trip-id order, which depends on the
      # random fixture UUIDs; compare the restored pairs as a set.
      restored_pairs = [{typo.id, @typo}, {blank.id, nil}]
      assert Enum.sort(Enum.map(applied, &{&1.id, &1.to})) == Enum.sort(restored_pairs)

      assert %{headsign: @old_default} = Repo.reload!(pattern)
      assert headsign_of(typo) == @typo
      assert Repo.reload!(blank).trip_headsign == nil

      # The restored pattern row and both rewritten trips share one operation
      # id, and the pattern row carries the exact affected trip count.
      pattern_log = latest_pattern_updated_log(context, pattern)
      operation_id = pattern_log.changed_fields["operation_id"]
      assert is_binary(operation_id)

      assert pattern_log.changed_fields["headsign"] == %{
               "from" => @new_default,
               "to" => @old_default
             }

      assert pattern_log.changed_fields["affected_trips"] == %{"from" => nil, "to" => 2}

      undo_trip_logs =
        Enum.filter(trip_logs(context), &(&1.changed_fields["operation_id"] == operation_id))

      assert Enum.sort(Enum.map(undo_trip_logs, & &1.entity_id)) == Enum.sort([typo.id, blank.id])
    end

    test "undoing a timing-scoped default save audits the timing under its pattern's GTFS ID",
         %{
           audit: audit,
           organization: organization,
           version: version,
           pattern: pattern,
           timing: timing,
           typo_trip: typo,
           blank: blank
         } do
      operation =
        {:timing, timing.id, %{headsign: @new_default}, %{headsign_trip_ids: [typo.id, blank.id]}}

      assert {:ok, %{fingerprint: fingerprint}} = Gtfs.review(pattern.id, operation, nil, audit)

      assert {:ok, %{headsign_undo: undo}} =
               Gtfs.apply_review(pattern.id, operation, fingerprint, audit)

      assert %{default: %{scope: {:timing, _}}} = undo
      assert {:ok, _} = Gtfs.undo_headsign_update(pattern.id, undo, audit)

      # The save and its undo are two rows for the same timing, and both name
      # the pattern, so Recent changes can link them to it.
      external_ids =
        Repo.all(
          from(log in ChangeLog,
            where:
              log.organization_id == ^organization.id and log.entity_type == "timed_pattern" and
                log.entity_id == ^timing.id,
            select: log.entity_external_id
          )
        )

      expected = "#{timing.id}:#{pattern.route_pattern_id}"
      assert Enum.sort(external_ids) == [expected, expected]

      zone = Gtfs.resolve_display_zone(organization.id, version.id)

      timing_groups =
        organization.id
        |> RecentChanges.recent(version.id, :everyone, zone)
        |> Enum.filter(&match?({:timed_pattern, _}, &1.destination))

      assert [%{destination: {:timed_pattern, "HS20-0"}, operations: [_, _]}] = timing_groups
    end

    test "undo after another edit changed one of the trips writes nothing",
         %{audit: audit, pattern: pattern, typo_trip: typo, blank: blank} = context do
      %{undo: undo} = save_default_headsign(pattern, [typo.id, blank.id], audit)

      typo
      |> Ecto.Changeset.change(trip_headsign: "Edited elsewhere")
      |> Repo.update!()

      logs_before = change_log_count(context)

      assert {:error, {:stale, stale}} = Gtfs.undo_headsign_update(pattern.id, undo, audit)

      edited_id = typo.id

      assert [
               %{
                 id: ^edited_id,
                 trip_id: "hs20-typo",
                 reviewed: @new_default,
                 current: "Edited elsewhere"
               }
             ] =
               stale

      # The whole undo rolled back: the default restore too.
      assert %{headsign: @new_default} = Repo.reload!(pattern)
      assert headsign_of(typo) == "Edited elsewhere"
      assert headsign_of(blank) == @new_default
      assert change_log_count(context) == logs_before
    end

    test "undo of a default save after the default changed again writes nothing",
         %{audit: audit, pattern: pattern, typo_trip: typo, blank: blank} = context do
      %{undo: undo} = save_default_headsign(pattern, [typo.id, blank.id], audit)

      pattern
      |> Ecto.Changeset.change(headsign: "Depoe Bay")
      |> Repo.update!()

      logs_before = change_log_count(context)

      assert {:error, {:stale, [%{default: "Depoe Bay"}]}} =
               Gtfs.undo_headsign_update(pattern.id, undo, audit)

      assert %{headsign: "Depoe Bay"} = Repo.reload!(pattern)
      assert headsign_of(typo) == @new_default
      assert headsign_of(blank) == @new_default
      assert change_log_count(context) == logs_before
    end
  end

  describe "two concurrent resets" do
    @tag :unboxed
    test "of the same trip leave one write and one stale", %{supervisor: supervisor} do
      previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
          :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
        end
      end)

      # The concurrency harness runs the writers through the production
      # serializable transaction adapter, as route_patterns/concurrency_test.exs
      # does for its adapter case.
      Application.put_env(
        :gtfs_planner,
        :reviewed_apply_transaction,
        ReviewedApplyTransaction.Repo
      )

      fixture =
        unboxed(fn ->
          unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

          organization = organization_fixture(%{alias: "headsign-reset-race-#{unique}"})
          version = gtfs_version_fixture(organization.id)
          route = route_fixture(organization.id, version.id)
          actor = editor_fixture(organization)

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
                route_pattern_name: "Reset race",
                direction_id: 0,
                headsign: @old_default,
                stops: Enum.map(stops, & &1.stop_id)
              },
              audit
            )

          timing = pattern.id |> stored_timings() |> List.first()

          trip =
            trip_fixture(organization.id, version.id, route.route_id, %{
              trip_id: "hs20-race",
              service_id: "WK",
              trip_headsign: @typo
            })
            |> trip_pattern_metadata_fixture(%{
              route_pattern_id: pattern.route_pattern_id,
              timed_pattern_id: timing.id,
              pattern_derivation_state: "linked"
            })

          %{organization: organization, actor: actor, audit: audit, pattern: pattern, trip: trip}
        end)

      on_exit(fn ->
        unboxed(fn -> cleanup_organization(fixture.organization.id, fixture.actor.id) end)
      end)

      parent = self()

      workers =
        Enum.map(1..2, fn index ->
          Task.Supervisor.async_nolink(supervisor, fn ->
            unboxed(fn ->
              send(parent, {:resetter_ready, index})

              receive do
                :go -> :ok
              end

              result =
                Gtfs.reset_trip_headsigns(
                  fixture.pattern.id,
                  :pattern,
                  [%{id: fixture.trip.id, from: @typo}],
                  fixture.audit
                )

              send(parent, {:resetter_done, index, result})
              result
            end)
          end)
        end)

      assert_receive {:resetter_ready, 1}
      assert_receive {:resetter_ready, 2}
      send(Enum.at(workers, 0).pid, :go)
      send(Enum.at(workers, 1).pid, :go)

      outcomes =
        for _ <- 1..2 do
          assert_receive {:resetter_done, _index, result}, 15_000
          result
        end

      assert Enum.count(outcomes, &match?({:ok, %{applied: [_one_change]}}, &1)) == 1
      assert Enum.count(outcomes, &match?({:error, {:stale, _}}, &1)) == 1
      Enum.each(workers, &Task.await(&1, 15_000))

      final =
        unboxed(fn ->
          %{
            headsign: Repo.reload!(fixture.trip).trip_headsign,
            logs:
              Repo.all(
                from(log in ChangeLog,
                  where:
                    log.organization_id == ^fixture.organization.id and
                      log.entity_type == "trip" and log.entity_id == ^fixture.trip.id
                )
              )
          }
        end)

      assert final.headsign == @old_default
      assert [%ChangeLog{action: "updated"}] = final.logs
    end
  end

  # -- Shared fixtures ---------------------------------------------------------

  # One pattern at "Lincoln City" with a plain timing, one timing that carries
  # its own headsign (shielding its trip from the pattern scope), and three
  # pattern-scope trips: the card's typo, a follower and a nil-headed trip.
  defp headsign_scope do
    organization =
      organization_fixture(%{alias: "headsign-reset-#{System.system_time(:nanosecond)}"})

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "HS20-0",
        headsign: @old_default,
        timing_name: "Weekday",
        stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]
      })

    school = timed_pattern_fixture(bundle.pattern, %{name: "School days", headsign: "Schools"})

    school_trip =
      trip_fixture(organization.id, version.id, route.route_id,
        trip_id: "hs20-school",
        service_id: "WK",
        trip_headsign: "Schools"
      )
      |> trip_pattern_metadata_fixture(%{
        route_pattern_id: bundle.pattern.route_pattern_id,
        timed_pattern_id: school.id,
        pattern_derivation_state: "linked"
      })

    typo_trip =
      schedule_trip_fixture(organization.id, version.id, route.route_id, bundle, %{
        service_id: "WK",
        trip_id: "hs20-typo",
        trip_headsign: @typo
      })
      |> Map.fetch!(:trip)

    follower =
      schedule_trip_fixture(organization.id, version.id, route.route_id, bundle, %{
        service_id: "WK",
        trip_id: "hs20-follower",
        trip_headsign: @old_default
      })
      |> Map.fetch!(:trip)

    blank =
      schedule_trip_fixture(organization.id, version.id, route.route_id, bundle, %{
        service_id: "WK",
        trip_id: "hs20-blank"
      })
      |> Map.fetch!(:trip)

    %{
      organization: organization,
      version: version,
      route: route,
      audit: audit,
      pattern: bundle.pattern,
      timing: bundle.timing,
      school: school,
      school_trip: school_trip,
      typo_trip: typo_trip,
      follower: follower,
      blank: blank,
      trip_ids: [typo_trip.id, follower.id, blank.id, school_trip.id]
    }
  end

  # A real reviewed default save through the facade, so the undo under test is
  # the exact value the editor would hold.
  defp save_default_headsign(pattern, trip_ids, audit) do
    operation = {:details, %{headsign: @new_default}, %{headsign_trip_ids: trip_ids}}

    {:ok, %{fingerprint: fingerprint}} = Gtfs.review(pattern.id, operation, nil, audit)

    {:ok, %{headsign_undo: undo}} = Gtfs.apply_review(pattern.id, operation, fingerprint, audit)

    %{operation: operation, fingerprint: fingerprint, undo: undo}
  end

  # -- Concurrency helpers (shape of route_patterns/concurrency_test.exs) ------

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp cleanup_organization(organization_id, actor_id) do
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
        where: m.organization_id == ^organization_id or m.user_id == ^actor_id
      )
    )

    delete_versions!(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
    Repo.delete_all(from(u in User, where: u.id == ^actor_id))
    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))

    refute Repo.exists?(from(o in Organization, where: o.id == ^organization_id))
    :ok
  end

  # -- Assertion helpers -------------------------------------------------------

  defp headsign_of(trip),
    do: trip |> Repo.reload!() |> Map.get(:trip_headsign) |> Headsigns.normalize()

  defp raw_headsigns(trips), do: Enum.map(trips, &Repo.reload!(&1).trip_headsign)

  defp trip_logs(context) do
    Repo.all(
      from(log in ChangeLog,
        where:
          log.organization_id == ^context.organization.id and
            log.entity_type == "trip" and log.entity_id in ^context.trip_ids,
        order_by: [asc: log.inserted_at]
      )
    )
  end

  defp default_rows_audited(context) do
    Repo.all(
      from(log in ChangeLog,
        where:
          log.organization_id == ^context.organization.id and
            log.entity_type in ["route_pattern", "timed_pattern"]
      )
    )
  end

  defp latest_pattern_updated_log(context, pattern) do
    Repo.one!(
      from(log in ChangeLog,
        where:
          log.organization_id == ^context.organization.id and
            log.entity_type == "route_pattern" and log.entity_id == ^pattern.id and
            log.action == "updated",
        order_by: [desc: log.inserted_at],
        limit: 1
      )
    )
  end

  defp change_log_count(context) do
    Repo.aggregate(
      from(log in ChangeLog, where: log.organization_id == ^context.organization.id),
      :count
    )
  end
end
