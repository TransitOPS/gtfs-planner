defmodule GtfsPlanner.Gtfs.Schedules.PasteApplyTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.TimetablePaste
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{organization: organization, version: version, audit: audit}
  end

  describe "apply_paste/5 removals" do
    test "a Replace removal deletes the trip, its stop times and its two transfers", context do
      scope = apply_case!(context)
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.remove == 1

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.added == 0
      assert summary.changed == 0
      assert summary.removed == 1
      assert summary.transfers_removed == 2
      assert summary.new_timings == []
      assert summary.trip_ids == []
      assert summary.vehicles_before == review.plan.vehicles.before
      assert summary.vehicles_after == review.plan.vehicles.after

      # The removed trip, its stop times and both transfers naming it are gone
      # while the kept trip is byte-identical.
      assert Repo.get_by(Trip, trip_id: scope.trips.first) == nil

      assert scoped(StopTime, context) |> where_trip(scope.trips.first) |> Repo.all() == []
      assert scoped(Transfer, context) |> Repo.all() == []

      assert Schedules.count_trip_transfers(context.organization.id, context.version.id, [
               scope.trips.first
             ]) == 0

      assert %Trip{trip_id: trip_id} = Repo.get_by(Trip, trip_id: scope.trips.second)
      assert trip_id == scope.trips.second

      # One 'deleted' trip audit carries the shared operation id.
      [log] =
        context |> trip_logs() |> Enum.filter(&(&1.action == "deleted"))

      assert log.entity_external_id == scope.trips.first
      assert log.changed_fields["before"]["trip_id"] == scope.trips.first
      assert is_binary(log.changed_fields["operation_id"])
      assert log.changed_fields["affected_trip_ids"] == [log.entity_id]
    end

    test "an unused timing edit between prepare and apply returns :stale_plan with no writes",
         context do
      scope = apply_case!(context, %{spare_timing?: true})
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.remove == 1
      counts_before = scoped_counts(context)

      # An edit to a timing no trip uses still changes the fingerprint.
      scope.spare_rows
      |> hd()
      |> Ecto.Changeset.change(%{departure_offset: 60})
      |> Repo.update!()

      assert {:error, :stale_plan} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      # Nothing was written: the doomed trip, its stop times and both
      # transfers are all still there.
      assert scoped_counts(context) == counts_before
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.first)

      assert Schedules.count_trip_transfers(context.organization.id, context.version.id, [
               scope.trips.first
             ]) == 2
    end

    test "a Replace scope holding a frequency trip returns :refused with no writes", context do
      scope = apply_case!(context, %{frequency?: true})
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert {:frequency, _trip} = review.plan.refusal
      counts_before = scoped_counts(context)

      assert {:error, :refused} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert scoped_counts(context) == counts_before
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.first)
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.second)
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.third)
    end

    test "a plan with an open pairing decision returns :blocking_issues with no writes",
         context do
      scope = apply_case!(context, %{duplicate_start?: true})
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.needs_decision == 1
      counts_before = scoped_counts(context)

      assert {:error, :blocking_issues} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      # The block runs before any write, so the unpaired trip survives too.
      assert scoped_counts(context) == counts_before
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.first)
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.second)
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.second_b)
    end

    test "a foreign route_id returns :not_found", context do
      scope = apply_case!(context)
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert {:error, :not_found} =
               Schedules.apply_paste(
                 "R-NOPE",
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      other_route = route_fixture(other_organization.id, other_version.id)

      assert {:error, :not_found} =
               Schedules.apply_paste(
                 other_route.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )
    end

    test "a pattern outside the direction returns :not_found", context do
      scope = apply_case!(context)
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      params =
        scope_params(scope)
        |> Map.put(:pattern_id, scope.rev.pattern.id)

      assert {:error, :not_found} =
               Schedules.apply_paste(
                 scope.route_id,
                 params,
                 input,
                 review.fingerprint,
                 context.audit
               )
    end
  end

  describe "apply_paste/5 changes" do
    test "a retimed 07:00 trip keeps its trip_id, transfers and wheelchair_accessible, with timepoint 0 at estimated stops",
         context do
      scope = apply_case!(context)

      was_updated_at =
        Repo.get_by!(Trip, trip_id: scope.trips.second) |> Map.fetch!(:updated_at)

      Repo.get_by!(Trip, trip_id: scope.trips.second)
      |> Ecto.Changeset.change(%{wheelchair_accessible: 1})
      |> Repo.update!()

      # Endpoints pasted; Market Street is estimated from the Standard template.
      # Both rows change: the estimated middle carries timepoint 0, so neither
      # vector reuses Standard (R9/R10) and each row mints its own timing.
      input = replace_input("Central Station\tHospital\n06:00\t06:10\n07:00\t07:12\n")
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.change == 2
      assert review.plan.counts.remove == 0

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.added == 0
      assert summary.changed == 2
      assert summary.removed == 0
      assert summary.transfers_removed == 0
      assert summary.new_timings == ["Pasted Sep 28 · A", "Pasted Sep 28 · B"]

      assert Enum.sort(summary.trip_ids) ==
               Enum.sort([scope.trips.first, scope.trips.second])

      first_id = Repo.get_by!(Trip, trip_id: scope.trips.first).id
      second_id = Repo.get_by!(Trip, trip_id: scope.trips.second).id

      trip = Repo.get_by!(Trip, trip_id: scope.trips.second)
      assert trip.trip_id == scope.trips.second
      assert trip.wheelchair_accessible == 1
      assert trip.direction_id == 0
      assert trip.route_pattern_id == "MAIN"
      assert trip.pattern_derivation_state == "linked"
      assert trip.pattern_derivation_reason == nil
      assert trip.trip_short_name == nil
      assert trip.block_id == nil
      assert trip.trip_headsign == nil
      assert trip.updated_at != was_updated_at

      timing = Repo.one!(from t in TimedPattern, where: t.name == "Pasted Sep 28 · B")
      assert trip.timed_pattern_id == timing.id

      first_timing = Repo.one!(from t in TimedPattern, where: t.name == "Pasted Sep 28 · A")

      assert Repo.get_by!(Trip, trip_id: scope.trips.first).timed_pattern_id ==
               first_timing.id

      assert ordered_stop_times(context, scope.trips.second) == [
               {"07:00:00", "07:00:00", 1},
               {"07:06:00", "07:06:00", 0},
               {"07:12:00", "07:12:00", 1}
             ]

      # Both transfers naming the kept trip survive the retime.
      assert Schedules.count_trip_transfers(context.organization.id, context.version.id, [
               scope.trips.second
             ]) == 2

      [first_log, second_log] =
        context |> trip_logs() |> Enum.filter(&(&1.action == "updated"))

      log =
        Enum.find([first_log, second_log], &(&1.entity_external_id == scope.trips.second))

      assert log.changed_fields["before"]["trip_id"] == scope.trips.second
      assert log.changed_fields["after"]["trip_id"] == scope.trips.second
      assert log.changed_fields["after"]["timing_name"] == "Pasted Sep 28 · B"
      assert is_binary(log.changed_fields["operation_id"])

      # Both 'updated' logs of one apply share the operation id and scope.
      assert first_log.changed_fields["operation_id"] ==
               second_log.changed_fields["operation_id"]

      assert Enum.sort(log.changed_fields["affected_trip_ids"]) ==
               Enum.sort([first_id, second_id])

      timing_logs = timing_logs(context)

      assert Enum.map(timing_logs, & &1.changed_fields["after"]["name"]) == [
               "Pasted Sep 28 · A",
               "Pasted Sep 28 · B"
             ]
    end

    test "a metadata-only change keeps the same timed_pattern_id and leaves stop times alone",
         context do
      scope = apply_case!(context)

      input =
        replace_input(
          "Central Station\tMarket Street\tHospital\tTrip number\n" <>
            "06:00\t06:05\t06:10\t1227\n07:00\t07:05\t07:10\t1228\n"
        )

      review = prepare_review!(context, scope, input)

      assert review.plan.counts.change == 2
      assert review.plan.counts.remove == 0

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.changed == 2
      assert summary.new_timings == []
      assert Enum.sort(summary.trip_ids) == Enum.sort([scope.trips.first, scope.trips.second])

      first = Repo.get_by!(Trip, trip_id: scope.trips.first)
      assert first.timed_pattern_id == scope.main.timing.id
      assert first.trip_short_name == "1227"

      second = Repo.get_by!(Trip, trip_id: scope.trips.second)
      assert second.timed_pattern_id == scope.main.timing.id
      assert second.trip_short_name == "1228"

      assert ordered_stop_times(context, scope.trips.first) == [
               {"06:00:00", "06:00:00", 1},
               {"06:05:00", "06:05:00", 1},
               {"06:10:00", "06:10:00", 1}
             ]
    end

    test "two changes sharing one new vector create a single pasted timing", context do
      scope = apply_case!(context)

      input = replace_input("Central Station\tHospital\n06:00\t06:12\n07:00\t07:12\n")
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.change == 2
      assert length(review.plan.new_timings) == 1

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.changed == 2
      assert summary.new_timings == ["Pasted Sep 28 · A"]

      assert Repo.aggregate(
               from(t in TimedPattern, where: t.name == "Pasted Sep 28 · A"),
               :count
             ) == 1

      timing = Repo.one!(from t in TimedPattern, where: t.name == "Pasted Sep 28 · A")
      assert Repo.get_by!(Trip, trip_id: scope.trips.first).timed_pattern_id == timing.id
      assert Repo.get_by!(Trip, trip_id: scope.trips.second).timed_pattern_id == timing.id
    end

    test "a change and a removal in one apply both commit", context do
      scope = apply_case!(context)

      input = replace_input("Central Station\tHospital\n07:00\t07:12\n")
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.change == 1
      assert review.plan.counts.remove == 1

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.changed == 1
      assert summary.removed == 1
      assert summary.transfers_removed == 2
      assert summary.new_timings == ["Pasted Sep 28 · A"]
      assert summary.trip_ids == [scope.trips.second]

      assert Repo.get_by(Trip, trip_id: scope.trips.first) == nil

      assert ordered_stop_times(context, scope.trips.second) == [
               {"07:00:00", "07:00:00", 1},
               {"07:06:00", "07:06:00", 0},
               {"07:12:00", "07:12:00", 1}
             ]

      # The 'updated' and 'deleted' logs of one apply share the operation id.
      operation_ids =
        context
        |> trip_logs()
        |> Enum.filter(&(&1.action in ["updated", "deleted"]))
        |> Enum.map(& &1.changed_fields["operation_id"])
        |> Enum.uniq()

      assert match?([operation_id] when is_binary(operation_id), operation_ids)
    end

    test "a stale change-plus-removal apply writes neither", context do
      scope = apply_case!(context)

      input = replace_input("Central Station\tHospital\n07:00\t07:12\n")
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.change == 1
      assert review.plan.counts.remove == 1
      counts_before = scoped_counts(context)

      scope.trips.first
      |> then(&Repo.get_by!(Trip, trip_id: &1))
      |> Ecto.Changeset.change(%{trip_short_name: "1"})
      |> Repo.update!()

      assert {:error, :stale_plan} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert scoped_counts(context) == counts_before
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.first)

      # The changed trip keeps its original Standard clocks (fixture stop
      # times carry no timepoint, so only the clocks compare here).
      assert ordered_stop_times(context, scope.trips.second)
             |> Enum.map(fn {arrival, departure, _timepoint} -> {arrival, departure} end) == [
               {"07:00:00", "07:00:00"},
               {"07:05:00", "07:05:00"},
               {"07:10:00", "07:10:00"}
             ]

      assert Repo.aggregate(
               from(t in TimedPattern, where: t.name == "Pasted Sep 28 · A"),
               :count
             ) == 0
    end

    test "a custom trip with matching stops becomes linked to the pasted timing", context do
      scope = apply_case!(context)

      custom_trip_id = "R-APPLY-0-WKD-APPLY-0800"

      schedule_trip_fixture(
        context.organization.id,
        context.version.id,
        scope.route_id,
        scope.main,
        %{
          trip_id: custom_trip_id,
          service_id: scope.service,
          start_time: "08:00:00",
          state: "custom"
        }
      )

      input =
        replace_input(
          "Central Station\tMarket Street\tHospital\n" <>
            "06:00\t06:05\t06:10\n07:00\t07:05\t07:10\n08:00\t08:05\t08:10\n"
        )

      review = prepare_review!(context, scope, input)

      custom_change =
        Enum.find(review.plan.changes, &(&1.op == :change and &1.trip.trip_id == custom_trip_id))

      assert custom_change.timing == {:existing, scope.main.timing.id}
      assert :custom_replaced in custom_change.warnings

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.changed == 1
      assert summary.new_timings == []

      custom = Repo.get_by!(Trip, trip_id: custom_trip_id)
      assert custom.trip_id == custom_trip_id
      assert custom.pattern_derivation_state == "linked"
      assert custom.pattern_derivation_reason == nil
      assert custom.timed_pattern_id == scope.main.timing.id

      assert ordered_stop_times(context, custom_trip_id) == [
               {"08:00:00", "08:00:00", 1},
               {"08:05:00", "08:05:00", 1},
               {"08:10:00", "08:10:00", 1}
             ]
    end
  end

  describe "apply_paste/5 adds" do
    test "adding 3 trips inserts natural ids in pattern order with timepoints 1/0/1",
         context do
      scope = apply_case!(context)

      input =
        add_input("Central Station\tHospital\n08:00\t08:12\n09:00\t09:12\n10:00\t10:12\n")

      review = prepare_review!(context, scope, input)

      assert review.plan.counts.add == 3
      assert review.plan.counts.change == 0
      assert review.plan.counts.remove == 0
      assert length(review.plan.new_timings) == 1

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.added == 3
      assert summary.changed == 0
      assert summary.removed == 0
      assert summary.transfers_removed == 0
      assert summary.new_timings == ["Pasted Sep 28 · A"]
      assert summary.vehicles_before == review.plan.vehicles.before
      assert summary.vehicles_after == review.plan.vehicles.after

      expected_ids = [
        "R-APPLY-0-WKD-APPLY-0800",
        "R-APPLY-0-WKD-APPLY-0900",
        "R-APPLY-0-WKD-APPLY-1000"
      ]

      assert Enum.sort(summary.trip_ids) == Enum.sort(expected_ids)

      for {trip_id, start, middle, finish} <- [
            {"R-APPLY-0-WKD-APPLY-0800", "08:00:00", "08:06:00", "08:12:00"},
            {"R-APPLY-0-WKD-APPLY-0900", "09:00:00", "09:06:00", "09:12:00"},
            {"R-APPLY-0-WKD-APPLY-1000", "10:00:00", "10:06:00", "10:12:00"}
          ] do
        trip = Repo.get_by!(Trip, trip_id: trip_id)
        assert trip.trip_id == trip_id
        assert trip.direction_id == 0
        assert trip.route_pattern_id == "MAIN"
        assert trip.pattern_derivation_state == "linked"
        assert trip.pattern_derivation_reason == nil
        assert trip.trip_short_name == nil
        assert trip.block_id == nil
        assert trip.trip_headsign == "Hospital"

        assert ordered_stop_times(context, trip_id) == [
                 {start, start, 1},
                 {middle, middle, 0},
                 {finish, finish, 1}
               ]

        assert ordered_stop_ids(context, trip_id) == ["PSA-1", "PSA-2", "PSA-3"]
      end

      timing = Repo.one!(from t in TimedPattern, where: t.name == "Pasted Sep 28 · A")

      for trip_id <- expected_ids do
        assert Repo.get_by!(Trip, trip_id: trip_id).timed_pattern_id == timing.id
      end

      created_logs =
        context |> trip_logs() |> Enum.filter(&(&1.action == "created"))

      assert length(created_logs) == 3
      assert Enum.sort(Enum.map(created_logs, & &1.entity_external_id)) == Enum.sort(expected_ids)

      assert created_logs
             |> Enum.map(& &1.changed_fields["operation_id"])
             |> Enum.uniq()
             |> length() == 1

      assert {:ok, schedule} =
               Schedules.load_route_schedule(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 %{service_id: scope.service, direction_id: 0}
               )

      assert schedule.summary.vehicles.count == summary.vehicles_after
    end

    test "an add sharing a vector with changes uses the same new timing", context do
      scope = apply_case!(context)

      input =
        replace_input("Central Station\tHospital\n06:00\t06:12\n07:00\t07:12\n08:00\t08:12\n")

      review = prepare_review!(context, scope, input)

      assert review.plan.counts.change == 2
      assert review.plan.counts.add == 1
      assert review.plan.counts.remove == 0
      assert length(review.plan.new_timings) == 1

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.changed == 2
      assert summary.added == 1
      assert summary.removed == 0
      assert summary.new_timings == ["Pasted Sep 28 · A"]

      assert Repo.aggregate(
               from(t in TimedPattern, where: t.name == "Pasted Sep 28 · A"),
               :count
             ) == 1

      timing = Repo.one!(from t in TimedPattern, where: t.name == "Pasted Sep 28 · A")
      assert Repo.get_by!(Trip, trip_id: scope.trips.first).timed_pattern_id == timing.id
      assert Repo.get_by!(Trip, trip_id: scope.trips.second).timed_pattern_id == timing.id

      assert Repo.get_by!(Trip, trip_id: "R-APPLY-0-WKD-APPLY-0800").timed_pattern_id ==
               timing.id

      assert Enum.sort(summary.trip_ids) ==
               Enum.sort([scope.trips.first, scope.trips.second, "R-APPLY-0-WKD-APPLY-0800"])
    end

    test "new timings on two patterns sharing a name each land on their own pattern",
         context do
      scope = apply_case!(context, short_turn?: true)

      input =
        add_input(
          "Central Station\tMarket Street\tHospital\n08:00\t08:05\t08:12\n08:30\t08:37\t-\n"
        )

      review = prepare_review!(context, scope, input)

      assert review.plan.counts.add == 2

      assert review.plan.new_timings |> Enum.map(&{&1.pattern_id, &1.name}) |> Enum.sort() ==
               Enum.sort([
                 {scope.main.pattern.id, "Pasted Sep 28 · A"},
                 {scope.short.pattern.id, "Pasted Sep 28 · A"}
               ])

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.added == 2

      main_timing =
        Repo.get_by!(TimedPattern,
          route_pattern_id: scope.main.pattern.id,
          name: "Pasted Sep 28 · A"
        )

      short_timing =
        Repo.get_by!(TimedPattern,
          route_pattern_id: scope.short.pattern.id,
          name: "Pasted Sep 28 · A"
        )

      main_trip = Repo.get_by!(Trip, trip_id: "R-APPLY-0-WKD-APPLY-0800")
      short_trip = Repo.get_by!(Trip, trip_id: "R-APPLY-0-WKD-APPLY-0830")

      assert {main_trip.route_pattern_id, main_trip.timed_pattern_id} == {"MAIN", main_timing.id}

      assert {short_trip.route_pattern_id, short_trip.timed_pattern_id} ==
               {"SHORT", short_timing.id}

      assert ordered_stop_ids(context, "R-APPLY-0-WKD-APPLY-0830") == ["PSA-1", "PSA-2"]

      created_timing_ids =
        context
        |> timing_logs()
        |> Enum.filter(&(&1.action == "created"))
        |> Enum.map(& &1.entity_id)
        |> Enum.sort()

      assert created_timing_ids == Enum.sort([main_timing.id, short_timing.id])
    end

    test "an Add paste with a duplicate row writes only the new trip and leaves no orphans",
         context do
      scope = apply_case!(context)

      input = add_input("Central Station\tHospital\n06:00\t06:12\n08:00\t08:12\n")
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.add == 1
      assert review.plan.counts.duplicate == 1

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.added == 1
      assert summary.changed == 0
      assert summary.removed == 0
      assert summary.trip_ids == ["R-APPLY-0-WKD-APPLY-0800"]

      assert ordered_stop_times(context, "R-APPLY-0-WKD-APPLY-0800") == [
               {"08:00:00", "08:00:00", 1},
               {"08:06:00", "08:06:00", 0},
               {"08:12:00", "08:12:00", 1}
             ]

      assert ordered_stop_times(context, scope.trips.first)
             |> Enum.map(fn {arrival, departure, _timepoint} -> {arrival, departure} end) == [
               {"06:00:00", "06:00:00"},
               {"06:05:00", "06:05:00"},
               {"06:10:00", "06:10:00"}
             ]

      assert scoped(StopTime, context) |> Repo.aggregate(:count) == 9

      trip_ids =
        Repo.all(
          from t in Trip,
            where:
              t.organization_id == ^context.organization.id and
                t.gtfs_version_id == ^context.version.id,
            select: t.trip_id
        )
        |> MapSet.new()

      orphans =
        Repo.all(
          from st in StopTime,
            where:
              st.organization_id == ^context.organization.id and
                st.gtfs_version_id == ^context.version.id,
            select: st.trip_id
        )
        |> Enum.reject(&MapSet.member?(trip_ids, &1))

      assert orphans == []
    end

    test "a mixed add/change/remove commits all three with one operation_id", context do
      scope = apply_case!(context)

      input = replace_input("Central Station\tHospital\n07:00\t07:12\n08:00\t08:12\n")
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.change == 1
      assert review.plan.counts.add == 1
      assert review.plan.counts.remove == 1

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.added == 1
      assert summary.changed == 1
      assert summary.removed == 1
      assert summary.transfers_removed == 2
      assert summary.new_timings == ["Pasted Sep 28 · A"]

      assert Enum.sort(summary.trip_ids) ==
               Enum.sort([scope.trips.second, "R-APPLY-0-WKD-APPLY-0800"])

      assert Repo.get_by(Trip, trip_id: scope.trips.first) == nil
      assert scoped(StopTime, context) |> where_trip(scope.trips.first) |> Repo.all() == []

      assert ordered_stop_times(context, scope.trips.second) == [
               {"07:00:00", "07:00:00", 1},
               {"07:06:00", "07:06:00", 0},
               {"07:12:00", "07:12:00", 1}
             ]

      assert ordered_stop_times(context, "R-APPLY-0-WKD-APPLY-0800") == [
               {"08:00:00", "08:00:00", 1},
               {"08:06:00", "08:06:00", 0},
               {"08:12:00", "08:12:00", 1}
             ]

      operation_ids =
        context
        |> trip_logs()
        |> Enum.filter(&(&1.action in ["created", "updated", "deleted"]))
        |> Enum.map(& &1.changed_fields["operation_id"])
        |> Enum.uniq()

      assert match?([operation_id] when is_binary(operation_id), operation_ids)

      # AC-22: the paste's timed_pattern "created" log shares the batch's
      # operation_id with the trip logs.
      assert [timing_operation_id] =
               Enum.map(timing_logs(context), & &1.changed_fields["operation_id"])

      assert timing_operation_id == hd(operation_ids)
    end

    test "an audit failure on the last added trip rolls back the whole mixed apply",
         context do
      scope = apply_case!(context)

      input = replace_input("Central Station\tHospital\n07:00\t07:12\n08:00\t08:12\n")
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.change == 1
      assert review.plan.counts.add == 1
      assert review.plan.counts.remove == 1
      counts_before = scoped_counts(context)

      install_last_add_rejection!("R-APPLY-0-WKD-APPLY-0800")

      assert_raise Postgrex.Error, fn ->
        Schedules.apply_paste(
          scope.route_id,
          scope_params(scope),
          input,
          review.fingerprint,
          context.audit
        )
      end

      remove_last_add_rejection!()

      assert scoped_counts(context) == counts_before
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.first)
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.second)
      assert Repo.get_by(Trip, trip_id: "R-APPLY-0-WKD-APPLY-0800") == nil

      assert Repo.aggregate(
               from(t in TimedPattern, where: t.name == "Pasted Sep 28 · A"),
               :count
             ) == 0

      assert ordered_stop_times(context, scope.trips.second)
             |> Enum.map(fn {arrival, departure, _timepoint} -> {arrival, departure} end) == [
               {"07:00:00", "07:00:00"},
               {"07:05:00", "07:05:00"},
               {"07:10:00", "07:10:00"}
             ]

      assert trip_logs(context) == []
    end
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

  defp ordered_stop_ids(context, trip_id) do
    scoped(StopTime, context)
    |> where_trip(trip_id)
    |> Repo.all()
    |> Enum.sort_by(&{&1.stop_sequence, &1.id})
    |> Enum.map(& &1.stop_id)
  end

  defp install_last_add_rejection!(trip_id) do
    Repo.query!("""
    CREATE FUNCTION trip_audit_last_add_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'trip' AND NEW.entity_external_id = '#{trip_id}' THEN
        RAISE EXCEPTION 'trip audit rejection for last add fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER trip_audit_last_add_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION trip_audit_last_add_rejection();
    """)
  end

  defp remove_last_add_rejection! do
    Repo.query!("DROP TRIGGER IF EXISTS trip_audit_last_add_rejection_trigger ON change_logs")
    Repo.query!("DROP FUNCTION IF EXISTS trip_audit_last_add_rejection()")
  end

  defp timing_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.organization_id == ^context.organization.id and
            l.gtfs_version_id == ^context.version.id and l.entity_type == "timed_pattern",
        order_by: [asc: l.inserted_at]
      )
    )
  end

  defp ordered_stop_times(context, trip_id) do
    scoped(StopTime, context)
    |> where_trip(trip_id)
    |> Repo.all()
    |> Enum.sort_by(&{&1.stop_sequence, &1.id})
    |> Enum.map(&{&1.arrival_time, &1.departure_time, &1.timepoint})
  end

  defp prepare_review!(context, scope, input) do
    assert {:ok, loaded} =
             Schedules.load_paste_scope(
               context.organization.id,
               context.version.id,
               scope.route_id,
               scope_params(scope)
             )

    assert {:ok, review} = TimetablePaste.review(loaded, input)
    review
  end

  defp scope_params(scope), do: %{service_id: scope.service, direction_id: 0}

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

  # Keeps the 07:00 trip; the 06:00 trip is unpaired and becomes the removal.
  defp keep_b_text do
    "Central Station\tMarket Street\tHospital\n07:00\t07:05\t07:10\n"
  end

  defp scoped_counts(context) do
    %{
      trips: scoped(Trip, context) |> Repo.aggregate(:count),
      stop_times: scoped(StopTime, context) |> Repo.aggregate(:count),
      transfers: scoped(Transfer, context) |> Repo.aggregate(:count)
    }
  end

  defp scoped(schema, context) do
    from(row in schema,
      where:
        row.organization_id == ^context.organization.id and
          row.gtfs_version_id == ^context.version.id
    )
  end

  defp where_trip(query, trip_id), do: from(row in query, where: row.trip_id == ^trip_id)

  defp trip_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.organization_id == ^context.organization.id and
            l.gtfs_version_id == ^context.version.id and l.entity_type == "trip",
        order_by: [asc: l.entity_external_id, asc: l.inserted_at]
      )
    )
  end

  defp apply_case!(context, opts \\ %{}) do
    opts = Map.new(opts)
    organization_id = context.organization.id
    version_id = context.version.id

    route = route_fixture(organization_id, version_id, %{route_id: "R-APPLY"})

    for {stop_id, name, code} <- [
          {"PSA-1", "Central Station", "1001"},
          {"PSA-2", "Market Street", "1002"},
          {"PSA-3", "Hospital", "1003"}
        ] do
      stop =
        stop_fixture(organization_id, version_id, %{stop_id: stop_id, stop_name: name})

      stop |> Ecto.Changeset.change(%{stop_code: code}) |> Repo.update!()
    end

    service = weekly_calendar!(context, "WKD-APPLY", "Apply Weekday")

    main =
      schedule_pattern_fixture(organization_id, version_id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "MAIN",
        route_pattern_name: "Main",
        route_pattern_sort_order: 0,
        headsign: "Hospital",
        timing_name: "Standard",
        stops: [{"PSA-1", 0, 0, 1}, {"PSA-2", 300, 300, 1}, {"PSA-3", 600, 600, 1}]
      })

    rev =
      schedule_pattern_fixture(organization_id, version_id, %{
        route_id: route.route_id,
        direction_id: 1,
        route_pattern_id: "REV",
        route_pattern_name: "Reverse",
        route_pattern_sort_order: 1,
        headsign: "Central",
        timing_name: "Standard",
        stops: [{"PSA-3", 0, 0, 1}, {"PSA-2", 300, 300, 1}, {"PSA-1", 600, 600, 1}]
      })

    short =
      if opts[:short_turn?] do
        schedule_pattern_fixture(organization_id, version_id, %{
          route_id: route.route_id,
          direction_id: 0,
          route_pattern_id: "SHORT",
          route_pattern_name: "Short turn",
          route_pattern_sort_order: 2,
          headsign: "Market Street",
          timing_name: "Standard",
          stops: [{"PSA-1", 0, 0, 1}, {"PSA-2", 300, 300, 1}]
        })
      end

    first =
      schedule_trip_fixture(organization_id, version_id, route.route_id, main, %{
        trip_id: "R-APPLY-0-WKD-APPLY-0600",
        service_id: service,
        start_time: "06:00:00"
      }).trip

    second =
      schedule_trip_fixture(organization_id, version_id, route.route_id, main, %{
        trip_id: "R-APPLY-0-WKD-APPLY-0700",
        service_id: service,
        start_time: "07:00:00"
      }).trip

    transfer_fixture(organization_id, version_id, %{
      from_stop_id: "PSA-1",
      to_stop_id: "PSA-2",
      from_trip_id: first.trip_id,
      to_trip_id: second.trip_id,
      transfer_type: 0
    })

    transfer_fixture(organization_id, version_id, %{
      from_stop_id: "PSA-2",
      to_stop_id: "PSA-3",
      from_trip_id: second.trip_id,
      to_trip_id: first.trip_id,
      transfer_type: 0
    })

    extra = %{third: nil, second_b: nil, spare_rows: []}

    extra =
      if opts[:frequency?] do
        third =
          schedule_trip_fixture(organization_id, version_id, route.route_id, main, %{
            trip_id: "R-APPLY-0-WKD-APPLY-0900",
            service_id: service,
            start_time: "09:00:00"
          }).trip

        frequency_fixture(organization_id, version_id, third.trip_id, %{
          start_time: "09:00:00",
          end_time: "12:00:00",
          headway_secs: 1200,
          exact_times: 0
        })

        %{extra | third: third.trip_id}
      else
        extra
      end

    extra =
      if opts[:duplicate_start?] do
        second_b =
          schedule_trip_fixture(organization_id, version_id, route.route_id, main, %{
            trip_id: "R-APPLY-0-WKD-APPLY-0700B",
            service_id: service,
            start_time: "07:00:00"
          }).trip

        %{extra | second_b: second_b.trip_id}
      else
        extra
      end

    extra =
      if opts[:spare_timing?] do
        spare = timed_pattern_fixture(main.pattern, %{name: "Spare"})

        rows =
          [{0, 0}, {360, 360}, {720, 720}]
          |> Enum.zip(main.occurrences)
          |> Enum.map(fn {{arrival, departure}, occurrence} ->
            timed_pattern_stop_fixture(spare, occurrence, %{
              arrival_offset: arrival,
              departure_offset: departure,
              timepoint: 1
            })
          end)

        %{extra | spare_rows: rows}
      else
        extra
      end

    # Real timing rows carry explicit service fields (GTFS pickup/drop default
    # 0); the row fixtures leave them NULL, which would keep every pasted
    # vector off the reuse key. Normalize before any review is prepared.
    timing_ids =
      Repo.all(
        from(t in TimedPattern,
          where:
            t.organization_id == ^context.organization.id and
              t.gtfs_version_id == ^context.version.id,
          select: t.id
        )
      )

    Repo.update_all(
      from(r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids),
      set: [pickup_type: 0, drop_off_type: 0]
    )

    %{
      route_id: route.route_id,
      service: service,
      main: main,
      rev: rev,
      short: short,
      trips: %{
        first: first.trip_id,
        second: second.trip_id,
        third: extra.third,
        second_b: extra.second_b
      },
      spare_rows: extra.spare_rows
    }
  end

  defp weekly_calendar!(context, service_id, name) do
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

    assert {:ok, _payload} = Gtfs.create_calendar(attrs, context.audit)
    service_id
  end
end
