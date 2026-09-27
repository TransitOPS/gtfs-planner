defmodule GtfsPlanner.Gtfs.Schedules.MutationsTest do
  # EV-4: the trip edit, duplicate and delete contracts observed through the real
  # `Gtfs` facade, spec 01's locks and rematerializer and the shared audit
  # dispatch. Every expectation that can be authored literally is: pre-mutation
  # row IDs, sequence labels, shape distances and continuous fields are captured
  # and compared after the mutation, exported rows are compared with CSV rows
  # written here, and no expectation calls `Materializer` to compute a value.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner/gtfs/schedules/mutations_test.exs`.
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "linked in-place retiming" do
    test "a linked retime rewrites the stored rows to the new timing's offsets", context do
      scope =
        schedule_scope!(context, "12e", %{
          route_pattern_id: "12E-PATTERN",
          timing_name: "Standard",
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}]
        })

      express =
        timing_fixture(scope.bundle, [{0, 0, 1}, {120, 150, 1}, {420, 420, 1}], %{
          name: "Express"
        })

      trip =
        schedule_trip_fixture(context.organization.id, context.version.id, "12e", scope.bundle, %{
          trip_id: "12e-0-#{scope.service}-0600",
          service_id: scope.service,
          start_time: "06:00:00"
        }).trip

      [first_row | _rest] = raw_stop_times(trip.trip_id)

      Repo.update!(
        Ecto.Changeset.change(first_row, %{
          shape_dist_traveled: Decimal.new("1.25"),
          continuous_pickup: 1,
          continuous_drop_off: 2
        })
      )

      captured = preserved_columns(trip.trip_id)

      assert {:ok, updated} =
               Gtfs.update_trip(
                 "12e",
                 trip.id,
                 %{start_time: "07:00:00", timed_pattern_id: express.id},
                 trip.updated_at,
                 context.audit
               )

      assert updated.id == trip.id
      assert updated.trip_id == trip.trip_id
      assert updated.service_id == scope.service
      assert updated.route_pattern_id == "12E-PATTERN"
      assert updated.direction_id == 0
      assert updated.timed_pattern_id == express.id
      assert updated.pattern_derivation_state == "linked"
      assert DateTime.compare(updated.updated_at, trip.updated_at) == :gt

      # Row identity, sequence labels, shape distances and continuous fields
      # survive literally; only the clocks move.
      assert preserved_columns(trip.trip_id) == captured

      assert clocks(trip.trip_id) == [
               {1, "A", "07:00:00", "07:00:00"},
               {2, "B", "07:02:00", "07:02:30"},
               {3, "C", "07:07:00", "07:07:00"}
             ]

      assert [log] = trip_logs(context)
      assert log.action == "updated"
      assert log.entity_external_id == trip.trip_id

      assert MapSet.new(Map.keys(log.changed_fields)) ==
               MapSet.new(~w(before after operation_id affected_trip_ids))

      assert log.changed_fields["before"]["start_time"] == "06:00:00"
      assert log.changed_fields["after"]["start_time"] == "07:00:00"
      assert log.changed_fields["before"]["timed_pattern_id"] == scope.bundle.timing.id
      assert log.changed_fields["after"]["timed_pattern_id"] == express.id
      assert log.changed_fields["before"]["timing_name"] == "Standard"
      assert log.changed_fields["after"]["timing_name"] == "Express"
      assert log.changed_fields["after"]["stop_time_count"] == 3
      assert log.changed_fields["after"]["frequencies"] == []
      refute Map.has_key?(log.changed_fields["after"], "stop_times")
    end

    test "a timing from another pattern is refused and writes nothing", context do
      scope = schedule_scope!(context, "12t", %{stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]})

      other =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "12t",
          direction_id: 0,
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]
        })

      trip =
        schedule_trip_fixture(context.organization.id, context.version.id, "12t", scope.bundle, %{
          service_id: scope.service,
          start_time: "06:00:00"
        }).trip

      before = raw_stop_times(trip.trip_id)

      assert {:error, :not_found} =
               Gtfs.update_trip(
                 "12t",
                 trip.id,
                 %{timed_pattern_id: other.timing.id},
                 trip.updated_at,
                 context.audit
               )

      assert raw_stop_times(trip.trip_id) == before
      assert Repo.get!(Trip, trip.id).updated_at == trip.updated_at
      assert trip_logs(context) == []

      assert {:error, :not_found} =
               Gtfs.update_trip(
                 "12t",
                 Ecto.UUID.generate(),
                 %{timed_pattern_id: scope.bundle.timing.id},
                 trip.updated_at,
                 context.audit
               )

      assert {:error, :not_found} =
               Gtfs.update_trip(
                 "12t",
                 trip.id,
                 %{timed_pattern_id: Ecto.UUID.generate()},
                 trip.updated_at,
                 context.audit
               )

      assert trip_logs(context) == []
    end
  end

  describe "metadata, calendar and stale edits" do
    test "metadata and calendar edits persist while trip_id stays and no-op or stale requests write nothing",
         context do
      scope =
        schedule_scope!(context, "12m", %{
          route_pattern_id: "12M-PATTERN",
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}]
        })

      second = weekly_calendar!(context, %{name: "Second Weekday"})

      trip =
        schedule_trip_fixture(context.organization.id, context.version.id, "12m", scope.bundle, %{
          trip_id: "12m-0-#{scope.service}-0600",
          service_id: scope.service,
          start_time: "06:00:00"
        }).trip

      # A request repeating the stored values changes nothing: no write, no log.
      assert {:ok, noop} =
               Gtfs.update_trip(
                 "12m",
                 trip.id,
                 %{start_time: "06:00:00", trip_headsign: nil},
                 trip.updated_at,
                 context.audit
               )

      assert noop.updated_at == trip.updated_at
      assert trip_logs(context) == []
      assert Repo.get!(Trip, trip.id).updated_at == trip.updated_at

      assert {:ok, edited} =
               Gtfs.update_trip(
                 "12m",
                 trip.id,
                 %{
                   trip_headsign: "Downtown",
                   trip_short_name: "12M",
                   block_id: "B1",
                   wheelchair_accessible: 1,
                   bikes_allowed: 2
                 },
                 trip.updated_at,
                 context.audit
               )

      assert edited.id == trip.id
      assert edited.trip_id == trip.trip_id
      assert edited.timed_pattern_id == scope.bundle.timing.id
      assert edited.pattern_derivation_state == "linked"

      assert {edited.trip_headsign, edited.trip_short_name, edited.block_id,
              edited.wheelchair_accessible, edited.bikes_allowed} ==
               {"Downtown", "12M", "B1", 1, 2}

      assert DateTime.compare(edited.updated_at, trip.updated_at) == :gt

      assert clocks(trip.trip_id) == [
               {1, "A", "06:00:00", "06:00:00"},
               {2, "B", "06:05:00", "06:05:30"},
               {3, "C", "06:12:00", "06:12:00"}
             ]

      assert {:ok, moved} =
               Gtfs.update_trip(
                 "12m",
                 trip.id,
                 %{service_id: second},
                 edited.updated_at,
                 context.audit
               )

      assert moved.id == trip.id
      assert moved.trip_id == trip.trip_id
      assert moved.service_id == second
      assert DateTime.compare(moved.updated_at, edited.updated_at) == :gt

      # A stale drawer is refused without touching the newer values.
      assert {:error, :stale} =
               Gtfs.update_trip(
                 "12m",
                 trip.id,
                 %{trip_headsign: "Overwritten"},
                 trip.updated_at,
                 context.audit
               )

      stored = Repo.get!(Trip, trip.id)
      assert stored.trip_headsign == "Downtown"
      assert stored.updated_at == moved.updated_at

      # The enum validation is part of the schedule-specific changeset.
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Gtfs.update_trip(
                 "12m",
                 trip.id,
                 %{wheelchair_accessible: 3},
                 moved.updated_at,
                 context.audit
               )

      assert Keyword.has_key?(errors, :wheelchair_accessible)

      # A calendar outside the version union is refused as a scope failure.
      assert {:error, :calendar_not_found} =
               Gtfs.update_trip(
                 "12m",
                 trip.id,
                 %{service_id: "missing_service"},
                 moved.updated_at,
                 context.audit
               )

      assert Repo.get!(Trip, trip.id).service_id == second

      # Exactly the two successful edits wrote a log.
      assert length(trip_logs(context)) == 2
    end
  end

  describe "custom trips" do
    test "a custom trip keeps byte-identical stop times and adopts only a compatible timing",
         context do
      scope =
        schedule_scope!(context, "12c", %{
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}]
        })

      custom =
        custom_trip!(context, "12c", scope, [
          {"A", nil, nil},
          {"B", "06:05:00", "06:05:30"},
          {"C", "06:12:00", "06:12:00"}
        ])

      assert custom.pattern_derivation_state == "custom"
      assert custom.timed_pattern_id == nil
      assert custom.pattern_derivation_reason != nil

      before = raw_stop_times(custom.trip_id)

      # A custom trip cannot move its departure without choosing a timing.
      assert {:error, :timed_pattern_required} =
               Gtfs.update_trip(
                 "12c",
                 custom.id,
                 %{start_time: "09:00:00"},
                 custom.updated_at,
                 context.audit
               )

      assert raw_stop_times(custom.trip_id) == before

      # A metadata edit leaves every custom stop-time row byte-identical.
      assert {:ok, edited} =
               Gtfs.update_trip(
                 "12c",
                 custom.id,
                 %{block_id: "C9", trip_headsign: "Loop"},
                 custom.updated_at,
                 context.audit
               )

      assert edited.pattern_derivation_state == "custom"
      assert edited.block_id == "C9"
      assert raw_stop_times(custom.trip_id) == before

      # Adoption rewrites the missing times from the timing and marks the trip linked.
      assert {:ok, adopted} =
               Gtfs.update_trip(
                 "12c",
                 custom.id,
                 %{
                   timed_pattern_id: scope.bundle.timing.id,
                   start_time: "08:00:00"
                 },
                 edited.updated_at,
                 context.audit
               )

      assert adopted.id == custom.id
      assert adopted.trip_id == custom.trip_id
      assert adopted.timed_pattern_id == scope.bundle.timing.id
      assert adopted.pattern_derivation_state == "linked"
      assert adopted.pattern_derivation_reason == nil
      assert adopted.block_id == "C9"

      assert clocks(custom.trip_id) == [
               {1, "A", "08:00:00", "08:00:00"},
               {2, "B", "08:05:00", "08:05:30"},
               {3, "C", "08:12:00", "08:12:00"}
             ]

      logs = trip_logs(context)
      assert length(logs) == 2

      metadata_log =
        Enum.find(logs, &(&1.changed_fields["after"]["pattern_derivation_state"] == "custom"))

      adoption_log =
        Enum.find(logs, &(&1.changed_fields["after"]["pattern_derivation_state"] == "linked"))

      assert metadata_log.changed_fields["after"]["block_id"] == "C9"
      assert adoption_log.changed_fields["after"]["timed_pattern_id"] == scope.bundle.timing.id
      assert is_list(metadata_log.changed_fields["before"]["stop_times"])
      refute Map.has_key?(adoption_log.changed_fields["after"], "stop_times")
    end

    test "an incompatible custom trip is refused even with repeated occurrences", context do
      scope =
        schedule_scope!(context, "12x", %{
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"A", 600, 600, 1}]
        })

      compatible =
        custom_trip!(context, "12x", scope, [
          {"A", "06:00:00", "06:00:00"},
          {"B", "06:05:00", "06:05:00"},
          {"A", "06:10:00", "06:10:00"}
        ])

      incompatible =
        custom_trip!(context, "12x", scope, [
          {"A", "06:00:00", "06:00:00"},
          {"B", "06:05:00", "06:05:00"},
          {"B", "06:10:00", "06:10:00"}
        ])

      wrong_direction =
        custom_trip!(
          context,
          "12x",
          scope,
          [
            {"A", "06:00:00", "06:00:00"},
            {"B", "06:05:00", "06:05:00"},
            {"A", "06:10:00", "06:10:00"}
          ],
          %{direction_id: 1}
        )

      before = raw_stop_times(incompatible.trip_id)

      assert {:error, :stops_differ} =
               Gtfs.update_trip(
                 "12x",
                 incompatible.id,
                 %{timed_pattern_id: scope.bundle.timing.id, start_time: "07:00:00"},
                 incompatible.updated_at,
                 context.audit
               )

      assert raw_stop_times(incompatible.trip_id) == before
      assert Repo.get!(Trip, incompatible.id).pattern_derivation_state == "custom"
      assert Repo.get!(Trip, incompatible.id).timed_pattern_id == nil

      assert {:error, :stops_differ} =
               Gtfs.update_trip(
                 "12x",
                 wrong_direction.id,
                 %{timed_pattern_id: scope.bundle.timing.id, start_time: "07:00:00"},
                 wrong_direction.updated_at,
                 context.audit
               )

      assert Repo.get!(Trip, wrong_direction.id).pattern_derivation_state == "custom"

      # The repeated-occurrence trip adopts because its ordered stops are A-B-A.
      assert {:ok, adopted} =
               Gtfs.update_trip(
                 "12x",
                 compatible.id,
                 %{timed_pattern_id: scope.bundle.timing.id, start_time: "07:00:00"},
                 compatible.updated_at,
                 context.audit
               )

      assert adopted.pattern_derivation_state == "linked"

      assert clocks(compatible.trip_id) == [
               {1, "A", "07:00:00", "07:00:00"},
               {2, "B", "07:05:00", "07:05:30"},
               {3, "A", "07:10:00", "07:10:00"}
             ]

      assert length(trip_logs(context)) == 1
    end
  end

  describe "frequency service" do
    test "frequency trips refuse start, timing and duplicate edits and lose their windows on deletion",
         context do
      scope = schedule_scope!(context, "12f", %{stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]})
      route_id = "12f"

      other = timing_fixture(scope.bundle, [{0, 0, 1}, {240, 240, 1}], %{name: "Peak"})
      second = weekly_calendar!(context, %{name: "Frequency Second"})

      trip =
        schedule_trip_fixture(context.organization.id, context.version.id, "12f", scope.bundle, %{
          trip_id: "12f-0-#{scope.service}-0600",
          service_id: scope.service,
          start_time: "06:00:00",
          frequencies: [
            %{start_time: "09:00:00", end_time: "12:00:00", headway_secs: 1200, exact_times: 0}
          ]
        }).trip

      before = raw_stop_times(trip.trip_id)

      assert {:error, :frequency_trip} =
               Gtfs.update_trip(
                 "12f",
                 trip.id,
                 %{start_time: "07:00:00"},
                 trip.updated_at,
                 context.audit
               )

      assert {:error, :frequency_trip} =
               Gtfs.update_trip(
                 "12f",
                 trip.id,
                 %{timed_pattern_id: other.id},
                 trip.updated_at,
                 context.audit
               )

      assert {:error, :frequency_trip} =
               Gtfs.duplicate_trip(
                 "12f",
                 trip.id,
                 %{start_time: "07:00:00", timed_pattern_id: scope.bundle.timing.id},
                 context.audit
               )

      assert raw_stop_times(trip.trip_id) == before
      assert Repo.aggregate(from(t in Trip, where: t.route_id == ^route_id), :count) == 1
      assert trip_logs(context) == []

      # Metadata and calendar edits are allowed on frequency service.
      assert {:ok, edited} =
               Gtfs.update_trip(
                 "12f",
                 trip.id,
                 %{block_id: "F1", trip_headsign: "Shuttle"},
                 trip.updated_at,
                 context.audit
               )

      assert edited.block_id == "F1"

      assert {:ok, moved} =
               Gtfs.update_trip(
                 "12f",
                 trip.id,
                 %{service_id: second},
                 edited.updated_at,
                 context.audit
               )

      assert moved.service_id == second

      # Deletion removes every frequency row with the trip.
      assert {:ok, %{trips: 1, transfers: 0}} =
               Gtfs.delete_trips("12f", second, [trip.id], context.audit)

      refute Repo.exists?(from(f in Frequency, where: f.trip_id == ^trip.trip_id))
      refute Repo.exists?(from(t in Trip, where: t.id == ^trip.id))
    end
  end

  describe "duplication" do
    test "duplication copies the source's fields with a fresh ID and leaves the source untouched",
         context do
      scope =
        schedule_scope!(context, "12d", %{
          route_pattern_id: "12D-PATTERN",
          timing_name: "Standard",
          timing_headsign: "Downtown",
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}]
        })

      source =
        schedule_trip_fixture(context.organization.id, context.version.id, "12d", scope.bundle, %{
          trip_id: "12d-0-#{scope.service}-0600",
          service_id: scope.service,
          start_time: "06:00:00",
          trip_headsign: "Downtown"
        }).trip

      source =
        source
        |> Ecto.Changeset.change(%{
          trip_short_name: "12D",
          block_id: "B7",
          wheelchair_accessible: 1,
          bikes_allowed: 2,
          shape_id: "SHAPE-12"
        })
        |> Repo.update!()

      Enum.each(raw_stop_times(source.trip_id), fn row ->
        Repo.update!(Ecto.Changeset.change(row, shape_dist_traveled: Decimal.new("2.5")))
      end)

      source_rows = raw_stop_times(source.trip_id)

      # The same minute is taken, so the new trip takes the smallest free suffix.
      assert {:ok, same_minute} =
               Gtfs.duplicate_trip(
                 "12d",
                 source.id,
                 %{start_time: "06:00:00", timed_pattern_id: scope.bundle.timing.id},
                 context.audit
               )

      assert same_minute.trip_id == "12d-0-#{scope.service}-0600-2"
      assert same_minute.id != source.id

      assert {:ok, copy} =
               Gtfs.duplicate_trip(
                 "12d",
                 source.id,
                 %{start_time: "06:30:00", timed_pattern_id: scope.bundle.timing.id},
                 context.audit
               )

      assert copy.trip_id == "12d-0-#{scope.service}-0630"
      assert copy.id != source.id
      assert copy.route_id == "12d"
      assert copy.route_pattern_id == "12D-PATTERN"
      assert copy.direction_id == 0
      assert copy.timed_pattern_id == scope.bundle.timing.id
      assert copy.pattern_derivation_state == "linked"
      assert copy.pattern_derivation_reason == nil
      assert copy.trip_headsign == "Downtown"

      assert {copy.service_id, copy.trip_short_name, copy.block_id, copy.wheelchair_accessible,
              copy.bikes_allowed, copy.shape_id} ==
               {scope.service, "12D", "B7", 1, 2, "SHAPE-12"}

      assert clocks(copy.trip_id) == [
               {1, "A", "06:30:00", "06:30:00"},
               {2, "B", "06:35:00", "06:35:30"},
               {3, "C", "06:42:00", "06:42:00"}
             ]

      assert Enum.map(raw_stop_times(copy.trip_id), & &1.shape_dist_traveled) == [nil, nil, nil]

      # The source trip is unchanged, including its shape distances.
      assert raw_stop_times(source.trip_id) == source_rows
      assert Repo.get!(Trip, source.id) == source
      assert length(trip_logs(context)) == 2

      # A custom source needs a timing, and the duplicate is created linked on the
      # pattern that timing belongs to.
      custom =
        custom_trip!(
          context,
          "12d",
          scope,
          [
            {"A", "06:00:00", "06:00:00"},
            {"B", "06:05:00", "06:05:00"},
            {"C", "06:12:00", "06:12:00"}
          ],
          %{trip_headsign: "Custom Sign"}
        )

      assert {:ok, custom_copy} =
               Gtfs.duplicate_trip(
                 "12d",
                 custom.id,
                 %{start_time: "10:00:00", timed_pattern_id: scope.bundle.timing.id},
                 context.audit
               )

      assert custom_copy.pattern_derivation_state == "linked"
      assert custom_copy.timed_pattern_id == scope.bundle.timing.id
      assert custom_copy.trip_headsign == "Custom Sign"

      assert clocks(custom_copy.trip_id) == [
               {1, "A", "10:00:00", "10:00:00"},
               {2, "B", "10:05:00", "10:05:30"},
               {3, "C", "10:12:00", "10:12:00"}
             ]
    end
  end

  describe "deletion" do
    test "a whole validated list deletes trips with their stop times and frequencies and audits once",
         context do
      scope = schedule_scope!(context, "12k", %{stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]})

      other_scope =
        schedule_scope!(context, "12z", %{stops: [{"A", 0, 0, 1}, {"B", 600, 600, 1}]})

      kept =
        schedule_trip_fixture(
          context.organization.id,
          context.version.id,
          "12z",
          other_scope.bundle,
          %{
            trip_id: "12z-0-#{other_scope.service}-0600",
            service_id: other_scope.service,
            start_time: "06:00:00"
          }
        ).trip

      kept_rows = raw_stop_times(kept.trip_id)

      plain =
        schedule_trip_fixture(context.organization.id, context.version.id, "12k", scope.bundle, %{
          trip_id: "12k-0-#{scope.service}-0600",
          service_id: scope.service,
          start_time: "06:00:00"
        }).trip

      frequency =
        schedule_trip_fixture(context.organization.id, context.version.id, "12k", scope.bundle, %{
          trip_id: "12k-0-#{scope.service}-0700",
          service_id: scope.service,
          start_time: "07:00:00",
          frequencies: [
            %{start_time: "09:00:00", end_time: "11:00:00", headway_secs: 900, exact_times: 1}
          ]
        }).trip

      # A deduplicated list of two UUIDs reports two deletions and no transfers.
      assert {:ok, %{trips: 2, transfers: 0}} =
               Gtfs.delete_trips(
                 "12k",
                 scope.service,
                 [frequency.id, plain.id, plain.id],
                 context.audit
               )

      refute Repo.exists?(from(t in Trip, where: t.id in ^[plain.id, frequency.id]))

      refute Repo.exists?(
               from(st in StopTime, where: st.trip_id in ^[plain.trip_id, frequency.trip_id])
             )

      refute Repo.exists?(from(f in Frequency, where: f.trip_id == ^frequency.trip_id))

      # Another route's rows are byte-unchanged.
      assert raw_stop_times(kept.trip_id) == kept_rows
      assert Repo.get!(Trip, kept.id) == kept

      # The deleted rows are gone from the real export too.
      assert {:ok, zip} = Export.export_to_zip(context.organization.id, context.version.id, :full)
      files = unzip(zip)

      exported_trip_ids = files |> csv_rows("trips.txt") |> Enum.map(& &1["trip_id"])
      refute plain.trip_id in exported_trip_ids
      refute frequency.trip_id in exported_trip_ids
      assert kept.trip_id in exported_trip_ids

      exported_stop_time_trip_ids =
        files |> csv_rows("stop_times.txt") |> Enum.map(& &1["trip_id"]) |> Enum.uniq()

      refute plain.trip_id in exported_stop_time_trip_ids
      refute frequency.trip_id in exported_stop_time_trip_ids

      # One deleted log per trip sharing one operation, both with before/after snapshots.
      logs = context |> trip_logs() |> Enum.filter(&(&1.action == "deleted"))
      assert length(logs) == 2

      assert logs |> Enum.map(& &1.entity_id) |> Enum.sort() ==
               Enum.sort([plain.id, frequency.id])

      assert logs |> Enum.map(& &1.changed_fields["operation_id"]) |> Enum.uniq() |> length() == 1

      affected = Enum.sort([plain.id, frequency.id])
      assert Enum.all?(logs, &(&1.changed_fields["affected_trip_ids"] == affected))
      assert Enum.all?(logs, &(&1.changed_fields["after"] == nil))

      plain_log = Enum.find(logs, &(&1.entity_external_id == plain.trip_id))
      assert plain_log.changed_fields["before"]["trip_id"] == plain.trip_id
      assert plain_log.changed_fields["before"]["stop_time_count"] == 2

      frequency_log = Enum.find(logs, &(&1.entity_external_id == frequency.trip_id))

      assert frequency_log.changed_fields["before"]["frequencies"] == [
               %{
                 "start_time" => "09:00:00",
                 "end_time" => "11:00:00",
                 "headway_secs" => 900,
                 "exact_times" => 1
               }
             ]
    end

    test "a list mixing routes or calendars deletes nothing", context do
      scope = schedule_scope!(context, "12m", %{stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]})

      other_scope =
        schedule_scope!(context, "12n", %{stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]})

      second = weekly_calendar!(context, %{name: "Mixed List Second"})

      first =
        schedule_trip_fixture(context.organization.id, context.version.id, "12m", scope.bundle, %{
          trip_id: "12m-0-#{scope.service}-0600",
          service_id: scope.service,
          start_time: "06:00:00"
        }).trip

      foreign_route =
        schedule_trip_fixture(
          context.organization.id,
          context.version.id,
          "12n",
          other_scope.bundle,
          %{
            trip_id: "12n-0-#{other_scope.service}-0600",
            service_id: other_scope.service,
            start_time: "06:00:00"
          }
        ).trip

      other_calendar =
        schedule_trip_fixture(context.organization.id, context.version.id, "12m", scope.bundle, %{
          trip_id: "12m-0-#{second}-0800",
          service_id: second,
          start_time: "08:00:00"
        }).trip

      before = Enum.map([first, foreign_route, other_calendar], &raw_stop_times(&1.trip_id))

      transfer =
        transfer_fixture(context.organization.id, context.version.id, %{
          transfer_type: 4,
          from_trip_id: first.trip_id,
          to_trip_id: other_calendar.trip_id
        })

      assert {:error, :not_found} =
               Gtfs.delete_trips(
                 "12m",
                 scope.service,
                 [first.id, foreign_route.id],
                 context.audit
               )

      assert {:error, :stale} =
               Gtfs.delete_trips(
                 "12m",
                 scope.service,
                 [first.id, other_calendar.id],
                 context.audit
               )

      assert {:error, :not_found} =
               Gtfs.delete_trips("12m", scope.service, [Ecto.UUID.generate()], context.audit)

      assert {:error, :not_found} =
               Gtfs.delete_trips("12m", "missing_service", [first.id], context.audit)

      assert Enum.map([first, foreign_route, other_calendar], &raw_stop_times(&1.trip_id)) ==
               before

      assert Enum.all?([first, foreign_route, other_calendar], fn trip ->
               Repo.exists?(from(t in Trip, where: t.id == ^trip.id))
             end)

      # A rejected list removes no transfer naming its trips.
      assert Gtfs.count_trip_transfers(context.organization.id, context.version.id, [
               first.trip_id
             ]) == 1

      assert Repo.get!(Transfer, transfer.id) == transfer
      assert trip_logs(context) == []
    end

    test "foreign organizations, versions and trips are refused as not found", context do
      scope = schedule_scope!(context, "12p", %{stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]})

      trip =
        schedule_trip_fixture(context.organization.id, context.version.id, "12p", scope.bundle, %{
          service_id: scope.service,
          start_time: "06:00:00"
        }).trip

      other_organization = organization_fixture()
      other_actor = editor_fixture(other_organization)
      other_audit = audit_context(other_organization, context.version, other_actor)

      assert {:error, :not_found} =
               Gtfs.update_trip(
                 "12p",
                 trip.id,
                 %{trip_headsign: "Foreign"},
                 trip.updated_at,
                 other_audit
               )

      assert {:error, :not_found} =
               Gtfs.delete_trips("12p", scope.service, [trip.id], other_audit)

      assert {:ok, staging} =
               Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      staging_route = route_fixture(context.organization.id, staging.id, %{route_id: "12stg"})
      staging_audit = audit_context(context.organization, staging, context.actor)

      assert {:error, :not_found} =
               Gtfs.delete_trips(staging_route.route_id, scope.service, [trip.id], staging_audit)

      assert {:error, :not_found} =
               Gtfs.duplicate_trip(
                 "12p",
                 trip.id,
                 %{start_time: "09:00:00", timed_pattern_id: scope.bundle.timing.id},
                 other_audit
               )

      assert Repo.get!(Trip, trip.id).trip_headsign == nil
      assert trip_logs(context) == []
    end
  end

  describe "transfers on deletion" do
    test "removes every transfer naming a deleted trip and leaves every other transfer",
         context do
      scope = schedule_scope!(context, "12t", %{stops: [{"S1", 0, 0, 1}, {"S2", 300, 330, 1}]})

      other_scope =
        schedule_scope!(context, "12u", %{stops: [{"S1", 0, 0, 1}, {"S2", 300, 330, 1}]})

      trip =
        schedule_trip_fixture(context.organization.id, context.version.id, "12t", scope.bundle, %{
          trip_id: "12t-0-#{scope.service}-0600",
          service_id: scope.service,
          start_time: "06:00:00"
        }).trip

      kept =
        schedule_trip_fixture(
          context.organization.id,
          context.version.id,
          "12u",
          other_scope.bundle,
          %{
            trip_id: "12u-0-#{other_scope.service}-0600",
            service_id: other_scope.service,
            start_time: "06:00:00"
          }
        ).trip

      other_trip =
        schedule_trip_fixture(
          context.organization.id,
          context.version.id,
          "12u",
          other_scope.bundle,
          %{
            trip_id: "12u-0-#{other_scope.service}-0700",
            service_id: other_scope.service,
            start_time: "07:00:00"
          }
        ).trip

      # Three rows name the deleted trip: a stopless in-seat pair on the from
      # column, a stop-to-stop row that also names it on the from column, and an
      # in-seat pair that names it on the to column.
      removed =
        Enum.map(
          [
            %{transfer_type: 4, from_trip_id: trip.trip_id, to_trip_id: kept.trip_id},
            %{
              transfer_type: 2,
              from_stop_id: "S1",
              to_stop_id: "S2",
              from_trip_id: trip.trip_id,
              min_transfer_time: 120
            },
            %{transfer_type: 4, from_trip_id: other_trip.trip_id, to_trip_id: trip.trip_id}
          ],
          &transfer_fixture(context.organization.id, context.version.id, &1)
        )

      # Four rows in this version name no deleted trip: a stop-only row, a
      # route-scoped row, an in-seat pair between two other trips, and a
      # stop-to-stop row that names the surviving trip.
      survivors =
        Enum.map(
          [
            %{transfer_type: 0, from_stop_id: "S1", to_stop_id: "S2", min_transfer_time: 60},
            %{
              transfer_type: 1,
              from_stop_id: "S1",
              to_stop_id: "S2",
              from_route_id: "12t",
              to_route_id: "12z",
              min_transfer_time: 45
            },
            %{transfer_type: 4, from_trip_id: other_trip.trip_id, to_trip_id: kept.trip_id},
            %{
              transfer_type: 2,
              from_stop_id: "S1",
              to_stop_id: "S2",
              from_trip_id: kept.trip_id,
              min_transfer_time: 90
            }
          ],
          &transfer_fixture(context.organization.id, context.version.id, &1)
        )

      # The same natural trip ID in another version and in another
      # organization's version keeps its row.
      other_version = gtfs_version_fixture(context.organization.id)

      other_version_transfer =
        transfer_fixture(context.organization.id, other_version.id, %{
          transfer_type: 4,
          from_trip_id: trip.trip_id,
          to_trip_id: kept.trip_id
        })

      other_organization = organization_fixture()
      other_organization_version = gtfs_version_fixture(other_organization.id)

      other_organization_transfer =
        transfer_fixture(other_organization.id, other_organization_version.id, %{
          transfer_type: 4,
          from_trip_id: trip.trip_id,
          to_trip_id: kept.trip_id
        })

      expected_export_rows = [
        %{
          "from_stop_id" => "S1",
          "to_stop_id" => "S2",
          "from_route_id" => "",
          "to_route_id" => "",
          "from_trip_id" => "",
          "to_trip_id" => "",
          "transfer_type" => "0",
          "min_transfer_time" => "60"
        },
        %{
          "from_stop_id" => "S1",
          "to_stop_id" => "S2",
          "from_route_id" => "12t",
          "to_route_id" => "12z",
          "from_trip_id" => "",
          "to_trip_id" => "",
          "transfer_type" => "1",
          "min_transfer_time" => "45"
        },
        %{
          "from_stop_id" => "",
          "to_stop_id" => "",
          "from_route_id" => "",
          "to_route_id" => "",
          "from_trip_id" => other_trip.trip_id,
          "to_trip_id" => kept.trip_id,
          "transfer_type" => "4",
          "min_transfer_time" => ""
        },
        %{
          "from_stop_id" => "S1",
          "to_stop_id" => "S2",
          "from_route_id" => "",
          "to_route_id" => "",
          "from_trip_id" => kept.trip_id,
          "to_trip_id" => "",
          "transfer_type" => "2",
          "min_transfer_time" => "90"
        }
      ]

      # The count a caller states before the deletion is the set it removes.
      assert Gtfs.count_trip_transfers(context.organization.id, context.version.id, [
               trip.trip_id
             ]) == 3

      assert {:ok, %{trips: 1, transfers: 3}} =
               Gtfs.delete_trips("12t", scope.service, [trip.id], context.audit)

      refute Repo.exists?(from(t in Trip, where: t.id == ^trip.id))
      refute Repo.exists?(from(t in Transfer, where: t.id in ^Enum.map(removed, & &1.id)))

      # Every other row is byte-identical, and exactly the four survivors remain.
      assert Enum.all?(survivors, &(Repo.get!(Transfer, &1.id) == &1))
      assert Repo.get!(Transfer, other_version_transfer.id) == other_version_transfer
      assert Repo.get!(Transfer, other_organization_transfer.id) == other_organization_transfer

      assert Repo.all(
               from(t in Transfer,
                 where:
                   t.organization_id == ^context.organization.id and
                     t.gtfs_version_id == ^context.version.id,
                 order_by: t.id,
                 select: t.id
               )
             ) == Enum.sort(Enum.map(survivors, & &1.id))

      assert Gtfs.count_trip_transfers(context.organization.id, context.version.id, [
               trip.trip_id
             ]) == 0

      # The full export carries no row naming the deleted trip and still carries
      # the four same-version survivors field for field.
      assert {:ok, zip} = Export.export_to_zip(context.organization.id, context.version.id, :full)
      files = unzip(zip)
      exported_rows = csv_rows(files, "transfers.txt")

      refute Enum.any?(exported_rows, fn row ->
               row["from_trip_id"] == trip.trip_id or row["to_trip_id"] == trip.trip_id
             end)

      assert MapSet.new(exported_rows) == MapSet.new(expected_export_rows)
    end
  end

  describe "export equality" do
    test "edited, adopted and duplicated stop times export as the authored literal rows",
         context do
      scope =
        schedule_scope!(context, "12x", %{
          route_pattern_id: "12X-PATTERN",
          timing_name: "Standard",
          timing_headsign: "Downtown",
          stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}]
        })

      [first_row | _rest] = scope.bundle.rows

      Repo.update!(
        Ecto.Changeset.change(first_row, %{
          stop_headsign: "Signed",
          pickup_type: 1,
          drop_off_type: 2
        })
      )

      assert {:ok, %{trips: [created]}} =
               Gtfs.create_trips(
                 "12x",
                 %{
                   pattern_id: scope.bundle.pattern.id,
                   timed_pattern_id: scope.bundle.timing.id,
                   service_id: scope.service,
                   start_time: "06:00:00",
                   repeat: nil
                 },
                 context.audit
               )

      assert created.trip_id == "12x-0-#{scope.service}-0600"
      row_ids = created.trip_id |> raw_stop_times() |> Enum.map(& &1.id)

      assert {:ok, retimed} =
               Gtfs.update_trip(
                 "12x",
                 created.id,
                 %{start_time: "07:00:00", timed_pattern_id: scope.bundle.timing.id},
                 created.updated_at,
                 context.audit
               )

      assert retimed.trip_id == created.trip_id
      assert raw_stop_times(retimed.trip_id) |> Enum.map(& &1.id) == row_ids

      assert {:ok, copy} =
               Gtfs.duplicate_trip(
                 "12x",
                 retimed.id,
                 %{start_time: "08:00:00", timed_pattern_id: scope.bundle.timing.id},
                 context.audit
               )

      custom =
        custom_trip!(
          context,
          "12x",
          scope,
          [{"A", nil, nil}, {"B", nil, nil}, {"C", nil, nil}],
          %{trip_id: "12x-custom-0000"}
        )

      assert {:ok, adopted} =
               Gtfs.update_trip(
                 "12x",
                 custom.id,
                 %{start_time: "09:00:00", timed_pattern_id: scope.bundle.timing.id},
                 custom.updated_at,
                 context.audit
               )

      assert adopted.pattern_derivation_state == "linked"

      assert {:ok, zip} = Export.export_to_zip(context.organization.id, context.version.id, :full)
      files = unzip(zip)

      authored =
        literal_rows(created.trip_id, "07:00:00") ++
          literal_rows(copy.trip_id, "08:00:00") ++
          literal_rows(adopted.trip_id, "09:00:00")

      assert files
             |> csv_rows("stop_times.txt")
             |> Enum.sort_by(&{&1["trip_id"], String.to_integer(&1["stop_sequence"])}) ==
               Enum.sort_by(authored, &{&1["trip_id"], String.to_integer(&1["stop_sequence"])})
    end
  end

  describe "audit atomicity" do
    test "an audit failure after the data writes rolls back update, duplicate and deletion",
         context do
      scope = schedule_scope!(context, "12a", %{stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]})

      target =
        schedule_trip_fixture(context.organization.id, context.version.id, "12a", scope.bundle, %{
          trip_id: "12a-0-#{scope.service}-0600",
          service_id: scope.service,
          start_time: "06:00:00"
        }).trip

      victim =
        schedule_trip_fixture(context.organization.id, context.version.id, "12a", scope.bundle, %{
          trip_id: "12a-0-#{scope.service}-0700",
          service_id: scope.service,
          start_time: "07:00:00"
        }).trip

      victim_transfer =
        transfer_fixture(context.organization.id, context.version.id, %{
          transfer_type: 4,
          from_trip_id: victim.trip_id,
          to_trip_id: target.trip_id
        })

      before = persistence_state(context, [target.trip_id, victim.trip_id])

      install_trip_audit_rejection_trigger!()

      assert_raise Postgrex.Error, fn ->
        Gtfs.update_trip(
          "12a",
          target.id,
          %{start_time: "08:00:00", trip_headsign: "Rolled back"},
          target.updated_at,
          context.audit
        )
      end

      assert_raise Postgrex.Error, fn ->
        Gtfs.duplicate_trip(
          "12a",
          target.id,
          %{start_time: "10:00:00", timed_pattern_id: scope.bundle.timing.id},
          context.audit
        )
      end

      assert_raise Postgrex.Error, fn ->
        Gtfs.delete_trips("12a", scope.service, [victim.id], context.audit)
      end

      remove_trip_audit_rejection_trigger!()

      assert persistence_state(context, [target.trip_id, victim.trip_id]) == before
      assert Repo.get!(Transfer, victim_transfer.id) == victim_transfer
      assert trip_logs(context) == []
    end

    test "a failed or empty mutation writes no log", context do
      scope = schedule_scope!(context, "12q", %{stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]})

      trip =
        schedule_trip_fixture(context.organization.id, context.version.id, "12q", scope.bundle, %{
          service_id: scope.service,
          start_time: "06:00:00"
        }).trip

      assert {:error, :stale} =
               Gtfs.update_trip(
                 "12q",
                 trip.id,
                 %{trip_headsign: "Nope"},
                 DateTime.add(trip.updated_at, -1, :second),
                 context.audit
               )

      # An empty list deletes and removes nothing.
      assert {:ok, %{trips: 0, transfers: 0}} =
               Gtfs.delete_trips("12q", scope.service, [], context.audit)

      assert Gtfs.count_trip_transfers(context.organization.id, context.version.id, []) == 0
      assert trip_logs(context) == []
    end
  end

  # -- Scope and fixture helpers ---------------------------------------------

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp weekly_calendar!(context, attrs) do
    attrs =
      Map.merge(
        %{
          service_id: "wk_#{System.unique_integer([:positive])}",
          name: "Weekday #{System.unique_integer([:positive])}",
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
        Map.new(attrs)
      )

    assert {:ok, _payload} = Gtfs.create_calendar(attrs, context.audit)
    attrs.service_id
  end

  defp schedule_scope!(context, route_id, attrs) do
    attrs = Map.new(attrs)
    route_fixture(context.organization.id, context.version.id, %{route_id: route_id})

    service =
      Map.get(attrs, :service) || weekly_calendar!(context, %{name: "Schedules #{route_id}"})

    pattern_attrs =
      %{
        route_id: route_id,
        direction_id: Map.get(attrs, :direction_id, 0),
        route_pattern_id: Map.get(attrs, :route_pattern_id),
        headsign: Map.get(attrs, :pattern_headsign),
        timing_name: Map.get(attrs, :timing_name),
        timing_headsign: Map.get(attrs, :timing_headsign),
        stops: Map.get(attrs, :stops, [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}])
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    bundle = schedule_pattern_fixture(context.organization.id, context.version.id, pattern_attrs)

    %{route_id: route_id, service: service, bundle: bundle}
  end

  defp timing_fixture(bundle, offsets, attrs) do
    timing = timed_pattern_fixture(bundle.pattern, Map.new(attrs))

    bundle.occurrences
    |> Enum.zip(offsets)
    |> Enum.each(fn {occurrence, {arrival, departure, timepoint}} ->
      timed_pattern_stop_fixture(timing, occurrence, %{
        arrival_offset: arrival,
        departure_offset: departure,
        timepoint: timepoint
      })
    end)

    timing
  end

  defp custom_trip!(context, route_id, scope, stop_times, attrs \\ %{}) do
    schedule_trip_fixture(
      context.organization.id,
      context.version.id,
      route_id,
      scope.bundle,
      Map.merge(
        %{service_id: scope.service, state: "custom", stop_times: stop_times},
        Map.new(attrs)
      )
    ).trip
  end

  defp raw_stop_times(trip_id) do
    Repo.all(
      from(st in StopTime,
        where: st.trip_id == ^trip_id,
        order_by: [asc: st.stop_sequence, asc: st.id]
      )
    )
  end

  defp preserved_columns(trip_id) do
    trip_id
    |> raw_stop_times()
    |> Enum.map(fn row ->
      {row.id, row.stop_sequence, row.shape_dist_traveled, row.continuous_pickup,
       row.continuous_drop_off}
    end)
  end

  defp clocks(trip_id) do
    trip_id
    |> raw_stop_times()
    |> Enum.map(&{&1.stop_sequence, &1.stop_id, &1.arrival_time, &1.departure_time})
  end

  defp persistence_state(context, trip_ids) do
    %{
      trips: Repo.all(from(t in Trip, where: t.trip_id in ^trip_ids, order_by: t.id)),
      stop_times: Repo.all(from(st in StopTime, where: st.trip_id in ^trip_ids, order_by: st.id)),
      frequencies: Repo.all(from(f in Frequency, where: f.trip_id in ^trip_ids, order_by: f.id)),
      transfers:
        Repo.all(
          from(t in Transfer,
            where: t.organization_id == ^context.organization.id,
            order_by: t.id
          )
        ),
      logs:
        Repo.all(
          from(l in ChangeLog,
            where: l.organization_id == ^context.organization.id and l.entity_type == "trip",
            order_by: l.id
          )
        )
    }
  end

  defp trip_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^context.organization.id and l.entity_type == "trip",
        order_by: [asc: l.entity_external_id, asc: l.inserted_at]
      )
    )
  end

  defp unzip(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    entries
  end

  defp csv_rows(files, name) do
    case Enum.find(files, fn {entry_name, _content} -> to_string(entry_name) == name end) do
      nil ->
        flunk("expected #{name} in the export")

      {_entry, content} ->
        {:ok, parsed} = CsvParser.stream(name, to_string(content))
        Enum.map(parsed.events, fn {:ok, _row_number, row} -> row end)
    end
  end

  # Literal expected export rows for one trip: A, B and C at the authored start
  # plus the fixture-authored offsets 0, 05:00/05:30 and 12:00.
  defp literal_rows(trip_id, start) do
    start_secs = clock(start)

    Enum.zip(
      [
        {"A", 0, 0, "Signed", "1", "2"},
        {"B", 300, 330, "", "", ""},
        {"C", 720, 720, "", "", ""}
      ],
      [1, 2, 3]
    )
    |> Enum.map(fn {{stop_id, arrival_offset, departure_offset, headsign, pickup, drop_off},
                    sequence} ->
      %{
        "trip_id" => trip_id,
        "arrival_time" => format_clock(start_secs + arrival_offset),
        "departure_time" => format_clock(start_secs + departure_offset),
        "stop_id" => stop_id,
        "stop_sequence" => Integer.to_string(sequence),
        "stop_headsign" => headsign,
        "pickup_type" => pickup,
        "drop_off_type" => drop_off,
        "continuous_pickup" => "",
        "continuous_drop_off" => "",
        "shape_dist_traveled" => "",
        "timepoint" => "1"
      }
    end)
  end

  defp clock(value) do
    {:ok, seconds} = GtfsTime.parse(value)
    seconds
  end

  defp format_clock(seconds), do: GtfsTime.format(seconds)

  # Test-only fault injection: a constraint trigger on `change_logs` raises on the
  # next trip audit insert, after the trip and stop-time rows are written. It is
  # created inside the sandbox transaction, so the guaranteed test rollback removes
  # it, and the test also drops it explicitly. No production failure switch exists.
  defp install_trip_audit_rejection_trigger! do
    Repo.query!("""
    CREATE FUNCTION trip_audit_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'trip' THEN
        RAISE EXCEPTION 'trip audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER trip_audit_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION trip_audit_rejection();
    """)
  end

  defp remove_trip_audit_rejection_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS trip_audit_rejection_trigger ON change_logs")
    Repo.query!("DROP FUNCTION IF EXISTS trip_audit_rejection()")
  end
end
