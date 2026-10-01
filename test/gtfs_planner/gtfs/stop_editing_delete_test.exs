defmodule GtfsPlanner.Gtfs.StopEditingDeleteTest do
  @moduledoc """
  `StopEditing.delete_review/2` and `delete_stop/3` (EV-18, AC-17).

  A delete is the one command in this module that destroys rows somebody else
  built, so what is under test is mostly what it *refuses* to do. A stop a
  timetable depends on is refused and stays. A station with a level, a
  `stop_levels` row and a journal entry is refused and all three of those rows
  stay — those rows are the station's structure, and cascading them would
  destroy a drawing rather than tidy up after a stop.

  The refusal cases are the ones that would all pass behind a count-based
  check. `StopReferences.counts/3` cannot see `stop_levels` or
  `journal_entries` at all: they match on `stops.id`, and the import review
  holds natural keys before any row exists. A delete that trusted a count
  would pass those rows through on every run.

  The removal case is the one that would pass behind a "nothing blocking, so
  it deleted" assertion. What is checked is that *exactly* the reviewed
  descriptive rows went, and that a transfer belonging to a different stop
  did not.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.StationEditingStatus
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  setup do
    fixture = staged_fixture()

    on_exit(fn -> cleanup_fixture(fixture) end)

    {:ok, fixture: fixture}
  end

  describe "delete_review/2" do
    test "lists the descriptive rows a delete would remove", context do
      fixture = context.fixture
      seed_descriptive(fixture)

      review = delete_review!(fixture, fixture.stops["1434"])

      assert review.blocking == []

      assert Enum.map(review.descriptive, & &1.key) |> Enum.sort() ==
               [:deadhead_from, :transfers_from, :translations]

      assert item_count(review, :transfers_from) == 1
      assert item_count(review, :translations) == 1
      assert String.length(review.fingerprint) == 64
    end

    test "lists a stop time as blocking and writes nothing", context do
      fixture = context.fixture
      seed_stop_time(fixture)

      before = snapshot(fixture)

      review = delete_review!(fixture, fixture.stops["1434"])

      assert [:stop_times] == Enum.map(review.blocking, & &1.key)
      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "a stop the actor may not edit is forbidden", context do
      fixture = context.fixture

      stranger =
        unboxed(fn -> user_fixture(%{email: "delete-stranger-#{stamp()}@example.com"}) end)

      assert {:error, :forbidden} =
               unboxed(fn ->
                 StopEditing.delete_review(fixture.stops["1434"].id, %{
                   fixture.audit
                   | actor_id: stranger.id
                 })
               end)
    end
  end

  describe "delete_stop/3 refuses" do
    test "a stop with a stop time is refused and still exists", context do
      fixture = context.fixture
      seed_stop_time(fixture)

      review = delete_review!(fixture, fixture.stops["1434"])
      before = snapshot(fixture)

      assert {:error, {:blocked, items}} = delete_stop(fixture, fixture.stops["1434"], review)
      assert [:stop_times] == Enum.map(items, & &1.key)

      # Everything is byte-identical, and the stop is still there. A refusal
      # that left the stop deleted and only the audit missing would pass a
      # return-value assertion.
      assert unboxed(fn -> snapshot(fixture) end) == before
      assert unboxed(fn -> Repo.get(Stop, fixture.stops["1434"].id) end) != nil
    end

    test "a station with a level, a stop_levels row and a journal entry is refused", context do
      fixture = context.fixture
      station = seed_station(fixture)

      before = snapshot(fixture)

      assert {:error, {:blocked, items}} =
               delete_stop(fixture, station, delete_review!(fixture, station))

      keys = Enum.map(items, & &1.key) |> Enum.sort()

      assert :stop_levels in keys
      assert :journal_entries in keys

      # The point of the case. A count-based refusal would pass these three
      # rows through: `StopReferences.counts/3` cannot see either table,
      # because both match on `stops.id` and the review holds a natural key.
      assert unboxed(fn -> snapshot(fixture) end) == before
      assert unboxed(fn -> level_count(fixture) end) == 1
      assert unboxed(fn -> stop_level_count(fixture) end) == 1
      assert unboxed(fn -> journal_count(fixture) end) == 1
      assert unboxed(fn -> Repo.get(Stop, station.id) end) != nil
    end

    test "a station with an editing status is refused", context do
      fixture = context.fixture
      station = seed_station(fixture)

      unboxed(fn ->
        %StationEditingStatus{
          organization_id: fixture.organization.id,
          gtfs_version_id: fixture.version.id,
          station_id: station.id,
          user_id: fixture.actor.id,
          started_at: DateTime.utc_now()
        }
        |> StationEditingStatus.changeset(%{})
        |> Repo.insert!()
      end)

      before = snapshot(fixture)

      assert {:error, {:blocked, items}} =
               delete_stop(fixture, station, delete_review!(fixture, station))

      assert :editing_statuses in Enum.map(items, & &1.key)
      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "a transfer added between review and delete is :stale_review", context do
      fixture = context.fixture
      seed_descriptive(fixture)

      review = delete_review!(fixture, fixture.stops["1434"])

      # A new reference the editor never saw. Deleting through the reviewed
      # fingerprint would cascade a row nobody approved.
      unboxed(fn ->
        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: "1434",
          to_stop_id: "1501",
          min_transfer_time: 120
        })
      end)

      before = snapshot(fixture)

      assert {:error, :stale_review} = delete_stop(fixture, fixture.stops["1434"], review)
      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "the stop being renamed between review and delete is :stale_review", context do
      fixture = context.fixture
      seed_descriptive(fixture)

      review = delete_review!(fixture, fixture.stops["1434"])

      unboxed(fn ->
        Stop
        |> where([s], s.id == ^fixture.stops["1434"].id)
        |> Repo.update_all(set: [stop_name: "Renamed elsewhere"])
      end)

      assert {:error, :stale_review} = delete_stop(fixture, fixture.stops["1434"], review)
      assert unboxed(fn -> Repo.get(Stop, fixture.stops["1434"].id) end) != nil
    end

    test "a stop the actor may not edit is forbidden", context do
      fixture = context.fixture
      seed_descriptive(fixture)

      review = delete_review!(fixture, fixture.stops["1434"])
      before = snapshot(fixture)

      stranger = unboxed(fn -> user_fixture(%{email: "delete-no-#{stamp()}@example.com"}) end)

      assert {:error, :forbidden} =
               unboxed(fn ->
                 StopEditing.delete_stop(fixture.stops["1434"].id, review.fingerprint, %{
                   fixture.audit
                   | actor_id: stranger.id
                 })
               end)

      assert unboxed(fn -> snapshot(fixture) end) == before
    end
  end

  describe "delete_stop/3 removes" do
    test "exactly the reviewed descriptive rows go, and nothing else", context do
      fixture = context.fixture
      seed_descriptive(fixture)

      # A transfer and a stop time that belong to *other* stops. A delete that
      # reached past its own scope would take these too, and they are the rows
      # a count-only assertion would not notice.
      other_transfer(fixture)
      other_stop_time(fixture)

      review = delete_review!(fixture, fixture.stops["1434"])

      assert {:ok, %{removed: removed}} = delete_stop(fixture, fixture.stops["1434"], review)

      # Reported under the review's own names: the review says "2 transfers",
      # so the result must not say "1 from, 1 to".
      # `report_key/1` merges the two transfer directions and the two pathway
      # directions, but not the two deadhead ones: "1 deadhead_from removed" is
      # what the review called that row too, and one spelling of one count is
      # the property worth keeping.
      assert removed == %{transfers: 1, deadhead_from: 1, translations: 1}

      assert unboxed(fn -> Repo.get(Stop, fixture.stops["1434"].id) end) == nil
      assert unboxed(fn -> transfer_count(fixture, "1434") end) == 0
      assert unboxed(fn -> translation_count(fixture) end) == 0
      assert unboxed(fn -> deadhead_count(fixture) end) == 0

      assert unboxed(fn -> transfer_count(fixture, "1500") end) == 1
      assert unboxed(fn -> stop_time_count(fixture, "1500") end) == 1
    end

    test "the delete is audited with what it removed", context do
      fixture = context.fixture
      seed_descriptive(fixture)

      review = delete_review!(fixture, fixture.stops["1434"])

      assert {:ok, _result} = delete_stop(fixture, fixture.stops["1434"], review)

      entry =
        unboxed(fn ->
          Repo.one(
            from(log in ChangeLog,
              where:
                log.organization_id == ^fixture.organization.id and
                  log.gtfs_version_id == ^fixture.version.id and
                  log.entity_type == "stop" and
                  log.action == "deleted",
              select: log
            )
          )
        end)

      # INV-2: a stop with no history entry is a stop nobody can account for.
      # The snapshot is the *pre-delete* row, so the history shows what the
      # stop was.
      assert entry.snapshot["stop_name"] == "Main St"
      assert entry.actor_id == fixture.actor.id
    end
  end

  # --- drivers

  # The stop is named at every call site rather than defaulted. A review of one
  # stop deleted against another is answered `:stale_review`, which reads as a
  # concurrency bug rather than a mismatched argument.
  defp delete_review!(fixture, stop) do
    {:ok, review} = unboxed(fn -> StopEditing.delete_review(stop.id, fixture.audit) end)

    review
  end

  defp delete_stop(fixture, stop, review) do
    unboxed(fn -> StopEditing.delete_stop(stop.id, review.fingerprint, fixture.audit) end)
  end

  defp item_count(review, key) do
    review.descriptive |> Enum.find(&(&1.key == key)) |> Map.fetch!(:count)
  end

  # One transfer out, one translation, and one deadhead time in. The three
  # `via` shapes a delete has to handle differently: a plain string column, the
  # `table_name`-discriminated translations table, and the encoded deadhead
  # reference that stores `stop:<id>` rather than the bare ID.
  # Every seeding helper runs inside `unboxed_run`: the fixtures open their
  # own transactions, and the sandbox refuses a second checkout from the test
  # process.
  defp seed_descriptive(fixture) do
    unboxed(fn ->
      transfer_fixture(fixture.organization.id, fixture.version.id, %{
        from_stop_id: "1434",
        to_stop_id: "1500",
        min_transfer_time: 300
      })

      Repo.insert!(%Translation{
        organization_id: fixture.organization.id,
        gtfs_version_id: fixture.version.id,
        table_name: "stops",
        field_name: "stop_name",
        language: "es",
        translation: "Calle Principal",
        record_id: "1434"
      })

      # The encoded form, not the bare ID: a deadhead row written before the
      # encoding existed holds the bare ID and must be deleted too, and this
      # is the row that proves the encoded branch runs at all.
      deadhead_time_fixture(fixture.organization.id, fixture.version.id, %{
        from_ref: "stop:1434",
        to_ref: "garage:11111111-1111-1111-1111-111111111111"
      })
    end)
  end

  defp seed_stop_time(fixture) do
    unboxed(fn ->
      stop_time_fixture(fixture.organization.id, fixture.version.id, "TRIP-1", "1434", %{
        stop_sequence: 1
      })
    end)
  end

  defp other_transfer(fixture) do
    unboxed(fn ->
      transfer_fixture(fixture.organization.id, fixture.version.id, %{
        from_stop_id: "1500",
        to_stop_id: "1501",
        min_transfer_time: 60
      })
    end)
  end

  defp other_stop_time(fixture) do
    unboxed(fn ->
      stop_time_fixture(fixture.organization.id, fixture.version.id, "TRIP-1", "1500", %{
        stop_sequence: 2
      })
    end)
  end

  # A station with the structure a delete must never cascade: a level, the
  # `stop_levels` row joining them, and a journal entry an editor wrote about
  # the drawing.
  defp seed_station(fixture) do
    unboxed(fn ->
      station =
        stop_fixture(fixture.organization.id, fixture.version.id, %{
          stop_id: "ST-NTC",
          stop_name: "NTC Station",
          location_type: 1,
          stop_lat: Decimal.from_float(44.6200),
          stop_lon: Decimal.from_float(-124.0530)
        })

      level =
        level_fixture(fixture.organization.id, fixture.version.id, %{
          level_id: "ST_NTC_L0",
          level_name: "Ground",
          level_index: 0.0
        })

      {:ok, _stop_level} =
        GtfsPlanner.Gtfs.create_stop_level(%{
          organization_id: fixture.organization.id,
          gtfs_version_id: fixture.version.id,
          stop_id: station.id,
          level_id: level.id
        })

      # `JournalEntry` has no plain changeset; it is written through
      # `StationJournal.create_changeset/3`. Inserting the struct directly is
      # the shortest path to the row, and the point of the case is that the
      # delete *finds* it by `station_id`.
      Repo.insert!(%JournalEntry{
        id: Ecto.UUID.generate(),
        organization_id: fixture.organization.id,
        gtfs_version_id: fixture.version.id,
        station_id: station.id,
        author_id: Ecto.UUID.generate(),
        target_type: "node",
        target_id: level.id,
        body: "Concourse note",
        captured_at: DateTime.utc_now()
      })

      station
    end)
  end

  defp level_count(fixture) do
    unboxed(fn ->
      Repo.one(
        from(s in GtfsPlanner.Gtfs.Level,
          where: s.organization_id == ^fixture.organization.id,
          select: count(s.id)
        )
      )
    end)
  end

  defp stop_level_count(fixture) do
    unboxed(fn ->
      Repo.one(
        from(s in StopLevel,
          where: s.organization_id == ^fixture.organization.id,
          select: count(s.id)
        )
      )
    end)
  end

  defp journal_count(fixture) do
    unboxed(fn ->
      Repo.one(
        from(j in JournalEntry,
          where: j.organization_id == ^fixture.organization.id,
          select: count(j.id)
        )
      )
    end)
  end

  defp transfer_count(fixture, from_stop_id) do
    unboxed(fn ->
      Repo.one(
        from(t in Transfer,
          where:
            t.organization_id == ^fixture.organization.id and t.from_stop_id == ^from_stop_id,
          select: count(t.id)
        )
      )
    end)
  end

  defp translation_count(fixture) do
    unboxed(fn ->
      Repo.one(
        from(t in Translation,
          where: t.organization_id == ^fixture.organization.id and t.record_id == "1434",
          select: count(t.id)
        )
      )
    end)
  end

  defp deadhead_count(fixture) do
    unboxed(fn ->
      Repo.one(
        from(d in GtfsPlanner.Gtfs.DeadheadTime,
          where: d.organization_id == ^fixture.organization.id,
          select: count(d.id)
        )
      )
    end)
  end

  defp stop_time_count(fixture, stop_id) do
    unboxed(fn ->
      Repo.one(
        from(s in StopTime,
          where: s.organization_id == ^fixture.organization.id and s.stop_id == ^stop_id,
          select: count(s.id)
        )
      )
    end)
  end

  # Every table the delete reads or writes, compared as rows *and* as values.
  # A refusal that deleted a row and restored a different one would pass a
  # row-count comparison.
  defp snapshot(fixture) do
    unboxed(fn ->
      scope = [fixture.organization.id, fixture.version.id]

      %{
        stops: rows(Stop, scope),
        transfers: rows(Transfer, scope),
        translations: rows(Translation, scope),
        stop_times: rows(StopTime, scope),
        stop_levels: rows(StopLevel, scope),
        levels: rows(GtfsPlanner.Gtfs.Level, scope),
        journal_entries: rows(JournalEntry, scope),
        editing_statuses: rows(StationEditingStatus, scope),
        logs:
          Repo.all(
            from log in ChangeLog,
              where:
                log.organization_id == ^fixture.organization.id and
                  log.gtfs_version_id == ^fixture.version.id,
              order_by: [asc: log.id],
              select: {log.id, log.inserted_at}
          )
      }
    end)
  end

  # `station_editing_statuses` is the one table here with no `updated_at`, and
  # a query that named it would not compile — which is a cheap guard against a
  # future table being added to the snapshot with the wrong shape.
  defp rows(StationEditingStatus, scope) do
    Repo.all(
      from row in StationEditingStatus,
        where: row.organization_id in ^scope and row.gtfs_version_id in ^scope,
        order_by: [asc: row.id],
        select: {row.id, row.inserted_at, row.started_at}
    )
  end

  defp rows(schema, scope) do
    Repo.all(
      from row in schema,
        where: row.organization_id in ^scope and row.gtfs_version_id in ^scope,
        order_by: field(row, :id),
        select: {row.id, row.inserted_at, field(row, :updated_at)}
    )
  end

  # --- fixture

  # The minimum a delete needs: a published version, an editor, and stops that
  # are not referenced by anything. Every reference is seeded by the case, so
  # each one can assert what it added is what the delete saw.
  defp staged_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "stop-delete-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)
      actor = add_actor(organization.id)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      stops =
        Map.new(
          [
            {"1434", "Main St", 44.6210},
            {"1500", "Harbour Way", 44.6100},
            {"1501", "Quay St", 44.6110}
          ],
          fn {id, name, lat} ->
            {id,
             stop_fixture(organization.id, version.id, %{
               stop_id: id,
               stop_name: name,
               stop_lat: Decimal.from_float(lat),
               stop_lon: Decimal.from_float(-124.0530)
             })}
          end
        )

      trip_fixture(organization.id, version.id, "1", %{trip_id: "TRIP-1", service_id: "WEEKDAYS"})

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: audit,
        stops: stops
      }
    end)
  end

  defp add_actor(organization_id) do
    actor = user_fixture(%{email: "stop-delete-#{stamp()}@example.com"})

    {:ok, _membership} =
      Organizations.add_user_to_organization(actor.id, organization_id, [
        "pathways_studio_editor"
      ])

    actor
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  # `journal_entries` and `station_editing_statuses` have no changeset worth
  # reaching for and cascade from the organization; the stops go before the
  # version that scopes them.
  @cleanup_tables [
    ChangeLog,
    StopLevel,
    JournalEntry,
    StationEditingStatus,
    Transfer,
    StopTime,
    GtfsPlanner.Gtfs.DeadheadTime,
    Stop,
    GtfsPlanner.Gtfs.Trip,
    GtfsPlanner.Gtfs.Level,
    GtfsPlanner.Gtfs.Calendar
  ]

  defp cleanup_fixture(fixture) do
    unboxed(fn ->
      scope = [fixture.organization.id, fixture.version.id]

      Enum.each(@cleanup_tables, fn table ->
        Repo.delete_all(
          from row in table,
            where: row.organization_id in ^scope or row.gtfs_version_id in ^scope
        )
      end)

      Repo.delete_all(
        from m in UserOrgMembership, where: m.organization_id == ^fixture.organization.id
      )

      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)
    end)
  end
end
