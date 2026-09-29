defmodule GtfsPlanner.Gtfs.Schedules.PasteConcurrencyTest do
  # EV-7/EV-12: apply_paste/5 must compose with the other schedule writers.
  # Independent connections are interleaved with message barriers on their own
  # connections, the final rows are read on a third connection, and every
  # expected outcome is authored literally here rather than produced by the
  # production apply. `on_exit` deletes only the captured fixture scope.
  #
  # Every case runs SERIALIZABLE: the module sets
  # `ReviewedApplyTransaction.Repo` explicitly (the test Sandbox adapter is
  # READ COMMITTED), with the previous value restored on exit. The scale case
  # prints one `EV-7-SCALE:` line carrying the measured wall time; no time
  # budget is asserted.
  #
  # The focused gate commands are:
  # `MIX_ENV=test MIX_TEST_PARTITION=_paste04 mix test test/gtfs_planner/gtfs/schedules/paste_concurrency_test.exs`
  # `MIX_ENV=test MIX_TEST_PARTITION=_paste04 mix test test/gtfs_planner/gtfs/schedules/paste_concurrency_test.exs --only blocks`
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
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.TimetablePaste
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @lock_wait 500
  @collect_timeout 10_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    previous = Application.get_env(:gtfs_planner, :reviewed_apply_transaction)
    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransaction.Repo)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
        value -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
      end
    end)

    %{supervisor: supervisor}
  end

  describe "writers outside the paste scope" do
    test "an unused opposite-direction timing edit commits and the paste still applies", %{
      supervisor: supervisor
    } do
      scope = seed_scope("unused-timing")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      input = replace_input(keep_b_text())
      review = prepare_review!(scope, input)

      # The spare timing lives on the opposite-direction pattern and no trip
      # uses it, so it is outside the paste fingerprint; the edit goes through
      # the production timing writer on its own connection.
      editor =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            {:ok, %{source_fingerprint: source}} =
              Gtfs.get_pattern(
                scope.organization.id,
                scope.version.id,
                scope.route_id,
                scope.rev.pattern.id
              )

            rows =
              Enum.map(scope.rev.occurrences, fn occurrence ->
                %{
                  route_pattern_stop_id: occurrence.id,
                  arrival_offset: 0,
                  departure_offset: 0
                }
              end)

            operation = {:timing, scope.spare_rev_timing.id, %{rows: rows}}

            {:ok, %{fingerprint: fingerprint}} =
              Gtfs.review(scope.rev.pattern.id, operation, source, scope.audit)

            result =
              Gtfs.apply_review(scope.rev.pattern.id, operation, fingerprint, scope.audit)

            send(parent, {:timing_committed, self()})
            result
          end)
        end)

      assert_receive {:timing_committed, editor_pid}, @collect_timeout
      assert editor_pid == editor.pid
      assert {:ok, _} = Task.await(editor, @collect_timeout)

      assert {:ok, summary} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   review.fingerprint,
                   scope.audit
                 )
               end)

      assert summary.removed == 1
      assert summary.transfers_removed == 2

      # Both writers landed: the spare timing carries the edit and the paste
      # removed its trip with the trip's transfers.
      assert timing_departures(scope.spare_rev_timing) == [0, 0, 0]
      assert unboxed(fn -> Repo.get_by(Trip, trip_id: scope.trips.first) end) == nil
      assert_consistent!(scope)
    end

    test "an opposite-direction trip edit on another calendar commits and the paste still applies",
         %{supervisor: supervisor} do
      scope = seed_scope("other-service")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      input = replace_input(keep_b_text())
      review = prepare_review!(scope, input)

      editor =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            trip = Repo.get_by!(Trip, trip_id: scope.rev_trip_other)

            {:ok, updated} =
              Gtfs.update_trip(
                scope.route_id,
                trip.id,
                %{trip_short_name: "12"},
                trip.updated_at,
                scope.audit
              )

            send(parent, {:trip_committed, self()})
            updated
          end)
        end)

      assert_receive {:trip_committed, editor_pid}, @collect_timeout
      assert editor_pid == editor.pid
      assert %Trip{trip_short_name: "12"} = Task.await(editor, @collect_timeout)

      assert {:ok, summary} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   review.fingerprint,
                   scope.audit
                 )
               end)

      assert summary.removed == 1

      # The paste never escapes its direction: the other-service
      # opposite-direction trip keeps the other writer's value.
      assert unboxed(fn -> Repo.get_by!(Trip, trip_id: scope.rev_trip_other).trip_short_name end) ==
               "12"

      assert_consistent!(scope)
    end
  end

  describe "fingerprinted dependency changes" do
    test "a stop rename on the paste pattern yields :stale_plan with no writes", %{
      supervisor: supervisor
    } do
      scope = seed_scope("pattern-stop")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()
      counts_before = scoped_counts(scope)

      input = replace_input(keep_b_text())
      review = prepare_review!(scope, input)

      editor =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            stop = Repo.get_by!(Stop, stop_id: "PSA-2")
            {:ok, renamed} = Gtfs.update_stop(stop, %{stop_name: "Market Street Hall"})
            send(parent, {:stop_committed, self()})
            renamed
          end)
        end)

      assert_receive {:stop_committed, editor_pid}, @collect_timeout
      assert editor_pid == editor.pid
      assert %Stop{stop_name: "Market Street Hall"} = Task.await(editor, @collect_timeout)

      assert {:error, :stale_plan} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   review.fingerprint,
                   scope.audit
                 )
               end)

      # Nothing was written: the doomed trip, its stop times and both
      # transfers are all still there.
      assert scoped_counts(scope) == counts_before
      assert %Trip{} = unboxed(fn -> Repo.get_by(Trip, trip_id: scope.trips.first) end)
      assert_consistent!(scope)
    end

    test "a timing edit on the paste pattern yields :stale_plan with no writes", %{
      supervisor: supervisor
    } do
      scope = seed_scope("pattern-timing")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()
      counts_before = scoped_counts(scope)

      input = replace_input(keep_b_text())
      review = prepare_review!(scope, input)

      editor =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            {:ok, %{source_fingerprint: source}} =
              Gtfs.get_pattern(
                scope.organization.id,
                scope.version.id,
                scope.route_id,
                scope.main.pattern.id
              )

            rows =
              scope.main.occurrences
              |> Enum.zip([{0, 0}, {300, 360}, {600, 660}])
              |> Enum.map(fn {occurrence, {arrival, departure}} ->
                %{
                  route_pattern_stop_id: occurrence.id,
                  arrival_offset: arrival,
                  departure_offset: departure
                }
              end)

            operation = {:timing, scope.main.timing.id, %{rows: rows}}

            {:ok, %{fingerprint: fingerprint}} =
              Gtfs.review(scope.main.pattern.id, operation, source, scope.audit)

            result =
              Gtfs.apply_review(scope.main.pattern.id, operation, fingerprint, scope.audit)

            send(parent, {:timing_committed, self()})
            result
          end)
        end)

      assert_receive {:timing_committed, editor_pid}, @collect_timeout
      assert editor_pid == editor.pid
      assert {:ok, _} = Task.await(editor, @collect_timeout)

      assert {:error, :stale_plan} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   review.fingerprint,
                   scope.audit
                 )
               end)

      assert scoped_counts(scope) == counts_before
      assert_consistent!(scope)
    end

    test "an opposite-direction trip edit on the calendar yields :stale_plan, then a fresh review applies",
         %{supervisor: supervisor} do
      scope = seed_scope("opposite-trip")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      input = replace_input(keep_b_text())
      review = prepare_review!(scope, input)
      counts_before = scoped_counts(scope)

      editor =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            trip = Repo.get_by!(Trip, trip_id: scope.rev_trip)

            {:ok, updated} =
              Gtfs.update_trip(
                scope.route_id,
                trip.id,
                %{trip_short_name: "10"},
                trip.updated_at,
                scope.audit
              )

            send(parent, {:trip_committed, self()})
            updated
          end)
        end)

      assert_receive {:trip_committed, editor_pid}, @collect_timeout
      assert editor_pid == editor.pid
      assert %Trip{trip_short_name: "10"} = Task.await(editor, @collect_timeout)

      # Trips in both directions are fingerprinted (AC-20), so the
      # opposite-direction edit refuses the stale paste with no writes.
      assert {:error, :stale_plan} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   review.fingerprint,
                   scope.audit
                 )
               end)

      assert scoped_counts(scope) == counts_before
      assert_consistent!(scope)

      # A fresh review over the committed edit applies, and the paste still
      # never escapes its direction: the opposite-direction trip keeps the
      # other writer's value.
      fresh = prepare_review!(scope, input)

      assert {:ok, summary} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   fresh.fingerprint,
                   scope.audit
                 )
               end)

      assert summary.removed == 1

      assert unboxed(fn -> Repo.get_by!(Trip, trip_id: scope.rev_trip).trip_short_name end) ==
               "10"

      assert_consistent!(scope)
    end

    test "a Schedules create on the same route yields :stale_plan with no partial rows", %{
      supervisor: supervisor
    } do
      scope = seed_scope("racing-create")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      input = replace_input(keep_b_text())
      review = prepare_review!(scope, input)

      creator =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            {:ok, %{trips: [created]}} =
              Gtfs.create_trips(
                scope.route_id,
                %{
                  pattern_id: scope.main.pattern.id,
                  timed_pattern_id: scope.main.timing.id,
                  service_id: scope.service,
                  start_time: "08:00:00",
                  repeat: nil
                },
                scope.audit
              )

            send(parent, {:trip_created, self()})
            created
          end)
        end)

      assert_receive {:trip_created, creator_pid}, @collect_timeout
      assert creator_pid == creator.pid
      created = Task.await(creator, @collect_timeout)
      assert created.trip_id == "#{scope.route_id}-0-#{scope.service}-0800"

      assert {:error, :stale_plan} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   review.fingerprint,
                   scope.audit
                 )
               end)

      # The created trip is intact with its three stop times; the refused
      # paste wrote nothing.
      assert stop_clocks(scope, created.trip_id) == [
               {"PSA-1", "08:00:00", "08:00:00"},
               {"PSA-2", "08:05:00", "08:05:00"},
               {"PSA-3", "08:10:00", "08:10:00"}
             ]

      assert %Trip{} = unboxed(fn -> Repo.get_by(Trip, trip_id: scope.trips.first) end)
      assert_consistent!(scope)
    end
  end

  describe "transfer naming a removed trip" do
    test "a transfer created between prepare and apply refuses the paste, then a fresh review removes all three",
         %{supervisor: supervisor} do
      scope = seed_scope("racing-transfer")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()
      counts_before = scoped_counts(scope)

      input = replace_input(keep_b_text())
      review = prepare_review!(scope, input)
      assert review.plan.counts.remove == 1

      creator =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            {:ok, transfer} =
              Gtfs.create_general_transfer(
                %{
                  from_stop_id: "PSA-1",
                  to_stop_id: "PSA-3",
                  from_trip_id: scope.trips.first,
                  to_trip_id: scope.trips.second,
                  transfer_type: 0
                },
                scope.audit
              )

            send(parent, {:transfer_created, self()})
            transfer
          end)
        end)

      assert_receive {:transfer_created, creator_pid}, @collect_timeout
      assert creator_pid == creator.pid
      assert %Transfer{} = Task.await(creator, @collect_timeout)

      # The new transfer names a trip the plan removes, so the fingerprint
      # moved: the paste refuses with nothing written and the transfer still
      # names a live trip — never a dangling reference.
      assert {:error, :stale_plan} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   review.fingerprint,
                   scope.audit
                 )
               end)

      assert scoped_counts(scope) == Map.update!(counts_before, :transfers, &(&1 + 1))
      assert %Trip{} = unboxed(fn -> Repo.get_by(Trip, trip_id: scope.trips.first) end)
      assert_consistent!(scope)

      # A fresh review sees the third transfer, and the apply deletes the
      # trip together with all three transfers naming it.
      fresh = prepare_review!(scope, input)

      assert {:ok, summary} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   fresh.fingerprint,
                   scope.audit
                 )
               end)

      assert summary.removed == 1
      assert summary.transfers_removed == 3
      assert unboxed(fn -> Repo.get_by(Trip, trip_id: scope.trips.first) end) == nil
      assert_consistent!(scope)

      # And a transfer naming the now-removed trip is refused, so no
      # dangling reference can be written after the removal either.
      assert {:error, %Ecto.Changeset{} = changeset} =
               unboxed(fn ->
                 Gtfs.create_general_transfer(
                   %{
                     from_stop_id: "PSA-1",
                     to_stop_id: "PSA-3",
                     from_trip_id: scope.trips.first,
                     to_trip_id: scope.trips.second,
                     transfer_type: 0
                   },
                   scope.audit
                 )
               end)

      assert %{from_trip_id: [_message]} = Ecto.Changeset.traverse_errors(changeset, & &1)
      assert_consistent!(scope)
    end
  end

  describe "Schedules create racing the paste" do
    test "a create truly overlapping the apply serializes with no corrupt insert", %{
      supervisor: supervisor
    } do
      scope = seed_scope("overlap-create")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()

      input = replace_input(keep_b_text())
      review = prepare_review!(scope, input)

      holder =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              RoutePatterns.lock_published_route!(scope.audit, scope.route_id)
              send(parent, {:route_holder_ready, self()})

              receive do
                :release -> :ok
              after
                @collect_timeout -> Repo.rollback(:timeout)
              end

              :ok
            end)
          end)
        end)

      assert_receive {:route_holder_ready, holder_pid}, @collect_timeout
      assert holder_pid == holder.pid

      applier =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:applier_ready, self()})

          unboxed(fn ->
            Schedules.apply_paste(
              scope.route_id,
              scope_params(scope),
              input,
              review.fingerprint,
              scope.audit
            )
          end)
        end)

      assert_receive {:applier_ready, _applier_pid}, @collect_timeout

      # The apply is blocked behind the holder's route lock.
      refute Task.yield(applier, @lock_wait)

      creator =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:creator_ready, self()})

          unboxed(fn ->
            Gtfs.create_trips(
              scope.route_id,
              %{
                pattern_id: scope.main.pattern.id,
                timed_pattern_id: scope.main.timing.id,
                service_id: scope.service,
                start_time: "08:00:00",
                repeat: nil
              },
              scope.audit
            )
          end)
        end)

      assert_receive {:creator_ready, _creator_pid}, @collect_timeout
      refute Task.yield(creator, @lock_wait)

      send(holder_pid, :release)
      assert {:ok, :ok} = Task.await(holder, @collect_timeout)

      apply_result = Task.await(applier, @collect_timeout)
      create_result = Task.await(creator, @collect_timeout)

      # Whoever commits first wins: the paste either applied before the
      # create or refused the stale plan (or exhausted retries into :busy).
      # It never leaves a partial write.
      assert match?({:ok, _}, apply_result) or
               match?({:error, reason} when reason in [:stale_plan, :busy], apply_result)

      assert match?({:ok, _}, create_result) or match?({:error, _}, create_result)

      if match?({:ok, _}, create_result) do
        {:ok, %{trips: [created]}} = create_result

        assert stop_clocks(scope, created.trip_id) == [
                 {"PSA-1", "08:00:00", "08:00:00"},
                 {"PSA-2", "08:05:00", "08:05:00"},
                 {"PSA-3", "08:10:00", "08:10:00"}
               ]
      end

      assert_consistent!(scope)
    end
  end

  describe "Blocks writers" do
    @describetag :blocks

    test "a Blocks assign before the paste both succeed and the paste keeps the block", %{
      supervisor: supervisor
    } do
      scope = seed_scope("blocks-first")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()
      day_key = weekday_key(scope)

      assigner =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            trip = Repo.get_by!(Trip, trip_id: scope.trips.second)

            {:ok, result} =
              Gtfs.apply_block_change(day_key, {:assign, [trip.id], "101"}, scope.audit)

            send(parent, {:block_assigned, self()})
            result
          end)
        end)

      assert_receive {:block_assigned, assigner_pid}, @collect_timeout
      assert assigner_pid == assigner.pid
      assert %{block_id: "101"} = Task.await(assigner, @collect_timeout)

      input = replace_input(keep_b_text())
      review = prepare_review!(scope, input)

      assert {:ok, summary} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   review.fingerprint,
                   scope.audit
                 )
               end)

      assert summary.removed == 1

      # The later paste reflects the earlier Blocks write: a paste without a
      # Block column keeps the assigned block (R13).
      assert unboxed(fn -> Repo.get_by!(Trip, trip_id: scope.trips.second).block_id end) ==
               "101"

      assert_consistent!(scope)
    end

    test "a block-writing paste before a Blocks assign both succeed and the assign wins", %{
      supervisor: supervisor
    } do
      scope = seed_scope("paste-first")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()
      day_key = weekday_key(scope)

      input =
        block_input("Central Station\tMarket Street\tHospital\tBlock\n07:00\t07:05\t07:10\t101\n")

      review = prepare_review!(scope, input)

      assert {:ok, summary} =
               unboxed(fn ->
                 Schedules.apply_paste(
                   scope.route_id,
                   scope_params(scope),
                   input,
                   review.fingerprint,
                   scope.audit
                 )
               end)

      assert summary.removed == 1

      assert unboxed(fn -> Repo.get_by!(Trip, trip_id: scope.trips.second).block_id end) ==
               "101"

      assigner =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            trip = Repo.get_by!(Trip, trip_id: scope.trips.second)

            {:ok, result} =
              Gtfs.apply_block_change(day_key, {:assign, [trip.id], "102"}, scope.audit)

            send(parent, {:block_assigned, self()})
            result
          end)
        end)

      assert_receive {:block_assigned, assigner_pid}, @collect_timeout
      assert assigner_pid == assigner.pid
      assert %{block_id: "102"} = Task.await(assigner, @collect_timeout)

      assert unboxed(fn -> Repo.get_by!(Trip, trip_id: scope.trips.second).block_id end) ==
               "102"

      assert_consistent!(scope)
    end

    test "a block-writing paste racing a Blocks assign neither deadlocks nor partially writes",
         %{supervisor: supervisor} do
      scope = seed_scope("overlap-blocks")
      on_exit(fn -> cleanup([scope]) end)
      parent = self()
      day_key = weekday_key(scope)

      input =
        block_input("Central Station\tMarket Street\tHospital\tBlock\n07:00\t07:05\t07:10\t101\n")

      review = prepare_review!(scope, input)
      assert review.plan.counts.remove == 1

      holder =
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              Blocking.lock_blocking!(scope.version.id)
              send(parent, {:blocking_holder_ready, self()})

              receive do
                :release -> :ok
              after
                @collect_timeout -> Repo.rollback(:timeout)
              end

              :ok
            end)
          end)
        end)

      assert_receive {:blocking_holder_ready, holder_pid}, @collect_timeout
      assert holder_pid == holder.pid

      paster =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:paster_ready, self()})

          unboxed(fn ->
            Schedules.apply_paste(
              scope.route_id,
              scope_params(scope),
              input,
              review.fingerprint,
              scope.audit
            )
          end)
        end)

      assert_receive {:paster_ready, _paster_pid}, @collect_timeout

      # The block-writing paste takes the blocking advisory lock, so it waits.
      refute Task.yield(paster, @lock_wait)

      assigner =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:assigner_ready, self()})

          unboxed(fn ->
            trip = Repo.get_by!(Trip, trip_id: scope.trips.second)
            Gtfs.apply_block_change(day_key, {:assign, [trip.id], "102"}, scope.audit)
          end)
        end)

      assert_receive {:assigner_ready, _assigner_pid}, @collect_timeout
      refute Task.yield(assigner, @lock_wait)

      send(holder_pid, :release)
      assert {:ok, :ok} = Task.await(holder, @collect_timeout)

      paste_result = Task.await(paster, @collect_timeout)
      assign_result = Task.await(assigner, @collect_timeout)

      # Both finish: the paste either applied before the assign or refused
      # the stale plan (or exhausted retries into :busy); the assign is a
      # tagged result, never a raise. The last writer's block stands.
      assert match?({:ok, _}, paste_result) or
               match?({:error, reason} when reason in [:stale_plan, :busy], paste_result)

      assert match?({:ok, _}, assign_result) or
               match?({:needs_confirmation, _}, assign_result) or
               match?({:error, _}, assign_result)

      if match?({:ok, _}, assign_result) do
        assert unboxed(fn -> Repo.get_by!(Trip, trip_id: scope.trips.second).block_id end) ==
                 "102"
      end

      assert_consistent!(scope)
    end
  end

  describe "maximum apply" do
    @tag timeout: 300_000
    test "a 500-trip by 150-stop Add apply completes and its wall time is recorded" do
      scope = seed_scale_scope("maximum-apply")
      on_exit(fn -> cleanup([scope]) end)

      # The 200 KB input cap rules out 150 pasted columns at this row count,
      # so the maximum apply pastes the two endpoint columns and estimates
      # the 148 middles from the template: each applied trip still carries
      # all 150 stop times, which is the insert volume being measured.
      input = add_input(scope.text)

      {review_us, review} =
        :timer.tc(fn ->
          loaded = load_scope!(scope)
          {:ok, review} = TimetablePaste.review(loaded, input)
          review
        end)

      assert review.plan.counts.add == 500

      {apply_us, result} =
        :timer.tc(fn ->
          unboxed(fn ->
            Schedules.apply_paste(
              scope.route_id,
              %{service_id: scope.service, direction_id: 0},
              input,
              review.fingerprint,
              scope.audit
            )
          end)
        end)

      assert {:ok, summary} = result
      assert summary.added == 500
      assert summary.changed == 0
      assert summary.removed == 0

      review_ms = div(review_us, 1_000)
      apply_ms = div(apply_us, 1_000)
      stop_times = route_stop_time_count(scope)

      assert route_trip_count(scope) == 500
      assert stop_times == 500 * 150

      IO.puts(
        "EV-7-SCALE: trips=500 stops_per_trip=150 stop_times=#{stop_times} " <>
          "review_ms=#{review_ms} apply_ms=#{apply_ms}"
      )

      assert_consistent!(scope)
    end
  end

  # -- Committed scope and reads ---------------------------------------------

  defp seed_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization = organization_fixture(%{alias: "paste-concurrency-#{suffix}-#{unique}"})
      version = gtfs_version_fixture(organization.id)
      route_id = "pc#{System.unique_integer([:positive])}"
      route_fixture(organization.id, version.id, %{route_id: route_id})
      actor = editor_fixture(organization)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }

      service = "wp_#{System.unique_integer([:positive])}"
      other_service = "wx_#{System.unique_integer([:positive])}"

      weekly_calendar!(audit, service, "Paste concurrency #{suffix}")
      weekly_calendar!(audit, other_service, "Paste concurrency other #{suffix}")

      for {stop_id, name, code} <- [
            {"PSA-1", "Central Station", "1001"},
            {"PSA-2", "Market Street", "1002"},
            {"PSA-3", "Hospital", "1003"}
          ] do
        stop = stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: name})
        stop |> Ecto.Changeset.change(%{stop_code: code}) |> Repo.update!()
      end

      main =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route_id,
          route_pattern_id: "MAIN",
          route_pattern_name: "Main",
          direction_id: 0,
          headsign: "Hospital",
          timing_name: "Standard",
          stops: [{"PSA-1", 0, 0, 1}, {"PSA-2", 300, 300, 1}, {"PSA-3", 600, 600, 1}]
        })

      rev =
        schedule_pattern_fixture(organization.id, version.id, %{
          route_id: route_id,
          route_pattern_id: "REV",
          route_pattern_name: "Reverse",
          direction_id: 1,
          headsign: "Central",
          timing_name: "Standard",
          stops: [{"PSA-3", 0, 0, 1}, {"PSA-2", 300, 300, 1}, {"PSA-1", 600, 600, 1}]
        })

      # A timing on the opposite-direction pattern that no trip uses: it is
      # outside the direction-0 paste fingerprint.
      spare_rev_timing = timed_pattern_fixture(rev.pattern, %{name: "SpareRev"})

      [{0, 0}, {360, 360}, {720, 720}]
      |> Enum.zip(rev.occurrences)
      |> Enum.each(fn {{arrival, departure}, occurrence} ->
        timed_pattern_stop_fixture(spare_rev_timing, occurrence, %{
          arrival_offset: arrival,
          departure_offset: departure,
          timepoint: 1
        })
      end)

      first =
        schedule_trip_fixture(organization.id, version.id, route_id, main, %{
          trip_id: "#{route_id}-0-#{service}-0600",
          service_id: service,
          start_time: "06:00:00"
        }).trip

      second =
        schedule_trip_fixture(organization.id, version.id, route_id, main, %{
          trip_id: "#{route_id}-0-#{service}-0700",
          service_id: service,
          start_time: "07:00:00"
        }).trip

      rev_trip =
        schedule_trip_fixture(organization.id, version.id, route_id, rev, %{
          trip_id: "#{route_id}-1-#{service}-0630",
          service_id: service,
          start_time: "06:30:00"
        }).trip

      rev_trip_other =
        schedule_trip_fixture(organization.id, version.id, route_id, rev, %{
          trip_id: "#{route_id}-1-#{other_service}-0630",
          service_id: other_service,
          start_time: "06:30:00"
        }).trip

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "PSA-1",
        to_stop_id: "PSA-2",
        from_trip_id: first.trip_id,
        to_trip_id: second.trip_id,
        transfer_type: 0
      })

      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "PSA-2",
        to_stop_id: "PSA-3",
        from_trip_id: second.trip_id,
        to_trip_id: first.trip_id,
        transfer_type: 0
      })

      # Real timing rows carry explicit service fields (GTFS pickup/drop
      # default 0); the row fixtures leave them NULL, which would keep every
      # pasted vector off the reuse key. Normalize before any review.
      timing_ids =
        Repo.all(
          from(t in TimedPattern,
            where: t.organization_id == ^organization.id and t.gtfs_version_id == ^version.id,
            select: t.id
          )
        )

      Repo.update_all(
        from(r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids),
        set: [pickup_type: 0, drop_off_type: 0]
      )

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: audit,
        route_id: route_id,
        service: service,
        other_service: other_service,
        main: main,
        rev: rev,
        spare_rev_timing: spare_rev_timing,
        trips: %{first: first.trip_id, second: second.trip_id},
        rev_trip: rev_trip.trip_id,
        rev_trip_other: rev_trip_other.trip_id
      }
    end)
  end

  defp seed_scale_scope(suffix) do
    unboxed(fn ->
      unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

      organization = organization_fixture(%{alias: "paste-scale-#{suffix}-#{unique}"})
      version = gtfs_version_fixture(organization.id)
      route_id = "ps#{System.unique_integer([:positive])}"
      route_fixture(organization.id, version.id, %{route_id: route_id})
      actor = editor_fixture(organization)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }

      service = "ws_#{System.unique_integer([:positive])}"
      weekly_calendar!(audit, service, "Paste scale #{suffix}")

      stop_count = 150

      for index <- 1..stop_count do
        stop =
          stop_fixture(organization.id, version.id, %{
            stop_id: "PSS-#{index}",
            stop_name: "Scale Stop #{index}"
          })

        stop |> Ecto.Changeset.change(%{stop_code: "#{2000 + index}"}) |> Repo.update!()
      end

      stops =
        for index <- 1..stop_count do
          {"PSS-#{index}", (index - 1) * 60, (index - 1) * 60, 1}
        end

      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route_id,
        route_pattern_id: "MAIN",
        route_pattern_name: "Main",
        direction_id: 0,
        headsign: "Scale",
        timing_name: "Standard",
        stops: stops
      })

      timing_ids =
        Repo.all(
          from(t in TimedPattern,
            where: t.organization_id == ^organization.id and t.gtfs_version_id == ^version.id,
            select: t.id
          )
        )

      Repo.update_all(
        from(r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids),
        set: [pickup_type: 0, drop_off_type: 0]
      )

      header = "Scale Stop 1\tScale Stop #{stop_count}"

      rows =
        for row <- 0..499 do
          start = 6 * 60 + row
          "#{format_clock(start)}\t#{format_clock(start + stop_count - 1)}"
        end

      text = header <> "\n" <> Enum.join(rows, "\n") <> "\n"

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: audit,
        route_id: route_id,
        service: service,
        text: text
      }
    end)
  end

  defp format_clock(minutes) do
    :io_lib.format("~2..0B:~2..0B", [div(minutes, 60), rem(minutes, 60)])
    |> IO.iodata_to_binary()
  end

  defp weekly_calendar!(audit, service_id, name) do
    attrs = %{
      service_id: service_id,
      name: name,
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
    }

    {:ok, _payload} = Gtfs.create_calendar(attrs, audit)
    service_id
  end

  defp scope_params(scope), do: %{service_id: scope.service, direction_id: 0}

  # Keeps the 07:00 trip; the 06:00 trip is unpaired and becomes the removal.
  defp keep_b_text, do: "Central Station\tMarket Street\tHospital\n07:00\t07:05\t07:10\n"

  defp replace_input(text) do
    %{
      text: text,
      layout: :auto,
      header?: true,
      overrides: %{},
      confirmations: MapSet.new(),
      decisions: %{},
      mode: :replace,
      template_timing_id: nil,
      stamp: "Sep 28",
      block_rows: []
    }
  end

  defp add_input(text) do
    %{
      text: text,
      layout: :auto,
      header?: true,
      overrides: %{},
      confirmations: MapSet.new(),
      decisions: %{},
      mode: :add,
      template_timing_id: nil,
      stamp: "Sep 28",
      block_rows: []
    }
  end

  defp block_input(text) do
    %{
      text: text,
      layout: :auto,
      header?: true,
      overrides: %{},
      confirmations: MapSet.new(),
      decisions: %{},
      mode: :replace,
      template_timing_id: nil,
      stamp: "Sep 28",
      block_rows: []
    }
  end

  defp prepare_review!(scope, input) do
    unboxed(fn ->
      {:ok, loaded} =
        Schedules.load_paste_scope(
          scope.organization.id,
          scope.version.id,
          scope.route_id,
          scope_params(scope)
        )

      {:ok, review} = TimetablePaste.review(loaded, input)
      review
    end)
  end

  defp load_scope!(scope) do
    unboxed(fn ->
      {:ok, loaded} =
        Schedules.load_paste_scope(
          scope.organization.id,
          scope.version.id,
          scope.route_id,
          %{service_id: scope.service, direction_id: 0}
        )

      loaded
    end)
  end

  defp weekday_key(scope) do
    unboxed(fn ->
      {:ok, calendars} = Gtfs.list_calendars(scope.organization.id, scope.version.id)
      hd(Blocking.DayTypes.derive(calendars)).key
    end)
  end

  defp timing_departures(timing) do
    unboxed(fn ->
      Repo.all(
        from(r in TimedPatternStop,
          join: o in RoutePatternStop,
          on: o.id == r.route_pattern_stop_id,
          where: r.timed_pattern_id == ^timing.id,
          order_by: o.position,
          select: r.departure_offset
        )
      )
    end)
  end

  defp stop_clocks(scope, trip_id) do
    unboxed(fn ->
      Repo.all(
        from(st in StopTime,
          where:
            st.organization_id == ^scope.organization.id and
              st.gtfs_version_id == ^scope.version.id and st.trip_id == ^trip_id,
          order_by: [asc: st.stop_sequence, asc: st.id]
        )
      )
      |> Enum.map(&{&1.stop_id, &1.arrival_time, &1.departure_time})
    end)
  end

  defp scoped_counts(scope) do
    unboxed(fn ->
      %{
        trips:
          Repo.aggregate(
            from(t in Trip,
              where:
                t.organization_id == ^scope.organization.id and
                  t.gtfs_version_id == ^scope.version.id
            ),
            :count
          ),
        stop_times:
          Repo.aggregate(
            from(st in StopTime,
              where:
                st.organization_id == ^scope.organization.id and
                  st.gtfs_version_id == ^scope.version.id
            ),
            :count
          ),
        transfers:
          Repo.aggregate(
            from(tr in Transfer,
              where:
                tr.organization_id == ^scope.organization.id and
                  tr.gtfs_version_id == ^scope.version.id
            ),
            :count
          )
      }
    end)
  end

  defp route_trip_count(scope) do
    unboxed(fn ->
      Repo.aggregate(
        from(t in Trip,
          where:
            t.organization_id == ^scope.organization.id and
              t.gtfs_version_id == ^scope.version.id and t.route_id == ^scope.route_id
        ),
        :count
      )
    end)
  end

  defp route_stop_time_count(scope) do
    unboxed(fn ->
      trip_ids =
        Repo.all(
          from(t in Trip,
            where:
              t.organization_id == ^scope.organization.id and
                t.gtfs_version_id == ^scope.version.id and t.route_id == ^scope.route_id,
            select: t.trip_id
          )
        )

      Repo.aggregate(
        from(st in StopTime,
          where:
            st.organization_id == ^scope.organization.id and
              st.gtfs_version_id == ^scope.version.id and st.trip_id in ^trip_ids
        ),
        :count
      )
    end)
  end

  # A partial write never survives: every stop time names a live trip, every
  # route trip carries its stop times, and no transfer names a missing trip.
  defp assert_consistent!(scope) do
    unboxed(fn ->
      organization_id = scope.organization.id
      version_id = scope.version.id

      trip_ids =
        MapSet.new(
          Repo.all(
            from(t in Trip,
              where: t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id,
              select: t.trip_id
            )
          )
        )

      orphans =
        Repo.all(
          from(st in StopTime,
            where: st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id,
            select: st.trip_id
          )
        )
        |> Enum.reject(&MapSet.member?(trip_ids, &1))
        |> Enum.uniq()

      assert orphans == []

      tripless =
        Repo.all(
          from(t in Trip,
            where:
              t.organization_id == ^organization_id and
                t.gtfs_version_id == ^version_id and t.route_id == ^scope.route_id,
            select: t.trip_id
          )
        )
        |> Enum.reject(fn trip_id ->
          Repo.exists?(
            from(st in StopTime,
              where:
                st.organization_id == ^organization_id and
                  st.gtfs_version_id == ^version_id and st.trip_id == ^trip_id
            )
          )
        end)

      assert tripless == []

      dangling =
        Repo.all(
          from(tr in Transfer,
            where: tr.organization_id == ^organization_id and tr.gtfs_version_id == ^version_id,
            select: {tr.from_trip_id, tr.to_trip_id}
          )
        )
        |> Enum.filter(fn {from_id, to_id} ->
          (is_binary(from_id) and not MapSet.member?(trip_ids, from_id)) or
            (is_binary(to_id) and not MapSet.member?(trip_ids, to_id))
        end)

      assert dangling == []
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Deletes only the captured fixture scope. The organization id is the
  # captured root: every row created here belongs to it, so nothing outside
  # this fixture can be touched.
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
      Repo.delete_all(from(tr in Transfer, where: tr.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(t in TimedPattern, where: t.organization_id in ^organization_ids))

      Repo.delete_all(
        from(o in RoutePatternStop,
          where: o.organization_id in ^organization_ids
        )
      )

      Repo.delete_all(
        from(p in GtfsPlanner.Gtfs.RoutePattern, where: p.organization_id in ^organization_ids)
      )

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

      refute Repo.exists?(from(tr in Transfer, where: tr.organization_id in ^organization_ids))

      refute Repo.exists?(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end
end
