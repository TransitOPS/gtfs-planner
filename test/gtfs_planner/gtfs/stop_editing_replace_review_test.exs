defmodule GtfsPlanner.Gtfs.StopEditingReplaceReviewTest do
  @moduledoc """
  `StopEditing.replace_review/3` (EV-19, AC-18).

  Two things are under test and they are not the same thing. The **refusals**
  are the ones with teeth: each one is a state where carrying references across
  would produce a feed that reads correctly in a validator and wrongly to a
  rider — a pattern visiting the same stop twice running, a bay's references
  quietly adopted by its station. The **effects** are the arithmetic an editor
  reads before agreeing, and the one that matters most is a *drop*: a row the
  replace will delete rather than carry, because the replacement already has a
  row that would collide with it.

  Every case asserts the review wrote nothing. A review that is wrong about
  what it will change is a bug; a review that *changes* it is a worse one, and
  the two are only distinguished by a test that checks the tables afterwards.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.ReliefPoint
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

  describe "refusals" do
    test "replacing a stop with itself is :same_stop", context do
      fixture = context.fixture

      assert {:error, {:refused, [:same_stop]}} = review(fixture, "1433", "1433")
    end

    test "replacing a stop with a station is :station", context do
      fixture = context.fixture
      unboxed(fn -> station_fixture(fixture, "ST-1", "Depot") end)

      assert {:error, {:refused, [:station]}} = review(fixture, "1433", "ST-1")
    end

    test "replacing a station with a stop is :station", context do
      fixture = context.fixture
      unboxed(fn -> station_fixture(fixture, "ST-1", "Depot") end)

      assert {:error, {:refused, [:station]}} = review(fixture, "ST-1", "1433")
    end

    test "replacing a child bay is :child", context do
      fixture = context.fixture
      unboxed(fn -> child_fixture(fixture, "1435", "ST-1", "1434") end)

      assert {:error, {:refused, [:child]}} = review(fixture, "1433", "1435")
      assert {:error, {:refused, [:child]}} = review(fixture, "1435", "1433")
    end

    test "different location types are :type_mismatch", context do
      fixture = context.fixture
      unboxed(fn -> entrance_fixture(fixture, "ENT-1") end)

      assert {:error, {:refused, [:type_mismatch]}} = review(fixture, "1433", "ENT-1")
    end

    test "a pattern visiting the replacement next to the old stop is :consecutive_pattern",
         context do
      fixture = context.fixture
      pattern = unboxed(fn -> pattern_fixture(fixture, "P-1", ["1433", "1391", "1500"]) end)

      assert {:error, {:refused, reasons}} = review(fixture, "1433", "1391")
      assert {:consecutive_pattern, [id]} = reason(reasons, :consecutive_pattern)
      assert id == pattern.id

      # The spec's worked example: the same pattern, a replacement that is *not*
      # adjacent, is allowed. An adjacency check that ignored `position` and
      # compared IDs would refuse this one too.
      assert {:ok, _review} = review(fixture, "1433", "1500")
    end

    test "a trip visiting the replacement next to the old stop is :consecutive_trip", context do
      fixture = context.fixture
      # T-1 has the replacement immediately after the old stop; T-2 puts a
      # third stop between them. Only T-1 is refused, which is what makes the
      # count 1 rather than "some trips".
      unboxed(fn -> trip_times(fixture, "T-1", [{"1433", 1}, {"1391", 2}, {"1500", 3}]) end)

      unboxed(fn ->
        trip_times(fixture, "T-2", [{"1433", 1}, {"1500", 2}, {"1391", 3}])
      end)

      assert {:error, {:refused, reasons}} = review(fixture, "1433", "1391")
      assert {:consecutive_trip, 1} = reason(reasons, :consecutive_trip)

      # 1500 is adjacent in T-1 and T-2, so it is *not* a safe replacement for
      # the trip check either. 1391 is only ever checked against a stop that is
      # not adjacent, so the "allowed" direction is proven with 1500 against a
      # version of the data where nothing is adjacent.
      assert {:ok, _review} = review(fixture, "1433", "1501")
    end

    test "a station row on the old stop is refused by kind, not as a blanket refusal", context do
      fixture = context.fixture

      # The `:refuse` rows are looked for on the **old** stop: they are the rows
      # a replace would strand, and the old stop is where they live. Putting
      # them on the replacement instead would be a different test — one about
      # the replacement's own structure, which the `:station` check already
      # refuses for.
      old = unboxed(fn -> level_join(fixture, stop_id(fixture, "1433")) end)
      unboxed(fn -> journal_fixture(fixture, stop_id(fixture, "1433"), old) end)
      unboxed(fn -> editing_status_fixture(fixture, stop_id(fixture, "1433")) end)
      unboxed(fn -> station_fixture(fixture, "ST-1", "Depot") end)

      assert {:error, {:refused, reasons}} = review(fixture, "1433", "ST-1")

      # Each stranded row is named. An editor who merges two stops and would
      # orphan a drawing needs to know *which* one, and a single "cannot
      # replace" would leave them guessing.
      assert :station in reasons
      assert {:blocked, :stop_levels} in reasons
      assert {:blocked, :journal_entries} in reasons
      assert {:blocked, :editing_statuses} in reasons
    end

    test "a child stop under the old stop is refused by kind", context do
      fixture = context.fixture
      unboxed(fn -> child_fixture(fixture, "CHILD-1", "1433", "1433") end)
      unboxed(fn -> station_fixture(fixture, "ST-1", "Depot") end)

      assert {:error, {:refused, reasons}} = review(fixture, "1433", "ST-1")
      assert {:blocked, :child_stops} in reasons
    end
  end

  describe "effects" do
    test "lists the rows each kind will rewrite", context do
      fixture = context.fixture
      unboxed(fn -> trip_times(fixture, "T-1", [{"1433", 1}, {"1500", 2}]) end)

      unboxed(fn ->
        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: "1433",
          to_stop_id: "1500",
          min_transfer_time: 240
        })
      end)

      assert {:ok, review} = review(fixture, "1433", "1391")

      change = change(review, :stop_times)
      assert change.count == 1
      assert change.dropped == 0
      assert change.rule == :rewrite

      transfer = change(review, :transfers_from)
      assert transfer.count == 1
      assert transfer.label == "Transfers from"
    end

    test "two relief points on the old stop, one on the replacement, drops the old one",
         context do
      fixture = context.fixture

      unboxed(fn ->
        # `relief_points` is unique on `(organization, version, stop_id)`, so a
        # second row for the *same* stop is impossible. The two old rows below
        # are therefore on two different old stops, which is the case that
        # matters: two stops merge, and the replacement's own relief point is
        # the row both old rows would land on.
        relief_point_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1433"})

        relief_point_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1500"})

        # The replacement already has one. Only one of the old two survives the
        # rewrite: the key is `(organization_id, gtfs_version_id, stop_id)`, so
        # both old rows would land on this same row.
        relief_point_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1391"})
      end)

      assert {:ok, review} = review(fixture, "1433", "1391")

      change = change(review, :relief_points)
      assert change.count == 1

      # A drop, naming the row that survives. A review reporting "1 relief point
      # will be carried over" would be the dangerous answer: the rewrite would
      # land on the replacement's own row and raise a unique violation.
      assert change.dropped == 1
      assert [drop] = drops(review, :relief_points)
      assert drop.kept.id != nil
    end

    test "a deadhead time collides on (from_ref, to_ref) and shows both minutes", context do
      fixture = context.fixture

      unboxed(fn ->
        deadhead_time_fixture(fixture.organization.id, fixture.version.id, %{
          from_ref: "garage:G",
          to_ref: "stop:1433",
          minutes: 20
        })

        # The replacement already has a deadhead from the same garage, so the
        # old row cannot be carried over: the key is the ref pair, and minutes
        # are not part of it.
        deadhead_time_fixture(fixture.organization.id, fixture.version.id, %{
          from_ref: "garage:G",
          to_ref: "stop:1391",
          minutes: 5
        })
      end)

      assert {:ok, review} = review(fixture, "1433", "1391")

      drop = drops(review, :deadhead_to) |> hd()

      # The whole question an editor has: the old stop cost 20 minutes from this
      # garage, the replacement costs 5. Neither half says it.
      assert [%{minutes: 20, to_ref: "stop:1433"}] = drop.details
      assert drop.kept.minutes == 5
      assert drop.kept.to_ref == "stop:1391"
    end

    test "a deadhead time with no counterpart is carried over, not dropped", context do
      fixture = context.fixture

      unboxed(fn ->
        deadhead_time_fixture(fixture.organization.id, fixture.version.id, %{
          from_ref: "garage:G",
          to_ref: "stop:1433",
          minutes: 20
        })
      end)

      assert {:ok, review} = review(fixture, "1433", "1391")

      change = change(review, :deadhead_to)
      assert change.count == 1
      assert change.dropped == 0
    end

    test "the old stop's translations are dropped, each named", context do
      fixture = context.fixture

      unboxed(fn ->
        translation_fixture(fixture, "1433", "es", "Calle Antigua")
        translation_fixture(fixture, "1433", "fr", "Rue Ancienne")
      end)

      assert {:ok, review} = review(fixture, "1433", "1391")

      change = change(review, :translations)
      assert change.count == 2
      assert change.rule == :drop

      languages =
        drops(review, :translations) |> Enum.map(&hd(&1.details).language) |> Enum.sort()

      assert languages == ["es", "fr"]
    end

    test "a segment that would become (new, new) is dropped", context do
      fixture = context.fixture
      unboxed(fn -> segment_fixture(fixture, "1391", "1433", [[44.62, -124.05]]) end)

      assert {:ok, review} = review(fixture, "1433", "1391")

      # A zero-length line would draw as real service between a stop and
      # itself, so the row goes rather than being written.
      assert change(review, :segments_to).dropped == 1
    end

    test "a segment with no counterpart is carried over", context do
      fixture = context.fixture
      unboxed(fn -> segment_fixture(fixture, "1433", "1500", [[44.62, -124.05]]) end)

      assert {:ok, review} = review(fixture, "1433", "1391")
      assert change(review, :segments_from).dropped == 0
    end

    test "no row changes", context do
      fixture = context.fixture
      unboxed(fn -> trip_times(fixture, "T-1", [{"1433", 1}, {"1391", 2}, {"1500", 3}]) end)

      unboxed(fn ->
        relief_point_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1433"})

        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: "1433",
          to_stop_id: "1500",
          min_transfer_time: 240
        })

        translation_fixture(fixture, "1433", "es", "Calle Antigua")
      end)

      before = snapshot(fixture)

      assert {:ok, _review} = review(fixture, "1433", "1500")

      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "a reference added after the review changes the fingerprint", context do
      fixture = context.fixture
      unboxed(fn -> trip_times(fixture, "T-1", [{"1433", 1}, {"1500", 2}]) end)

      assert {:ok, first} = review(fixture, "1433", "1391")

      unboxed(fn ->
        trip_times(fixture, "T-2", [{"1433", 1}, {"1500", 2}])
      end)

      assert {:ok, second} = review(fixture, "1433", "1391")
      assert first.fingerprint != second.fingerprint
    end

    test "a stop the actor may not edit is forbidden", context do
      fixture = context.fixture
      stranger = unboxed(fn -> user_fixture(%{email: "replace-no-#{stamp()}@example.com"}) end)

      assert {:error, :forbidden} =
               unboxed(fn ->
                 StopEditing.replace_review(
                   fixture.stops["1433"].id,
                   fixture.stops["1391"].id,
                   %{fixture.audit | actor_id: stranger.id}
                 )
               end)
    end
  end

  # --- drivers

  # Stops are resolved by GTFS ID at call time rather than looked up in the
  # staged map: several cases seed their own station, entrance or bay *after*
  # setup, and reading a missing key there would fail as a map lookup rather
  # than as the refusal under test.
  defp review(fixture, old_id, new_id) do
    unboxed(fn ->
      StopEditing.replace_review(
        stop_id(fixture, old_id).id,
        stop_id(fixture, new_id).id,
        fixture.audit
      )
    end)
  end

  defp stop_id(fixture, stop_id) do
    case Map.fetch(fixture.stops, stop_id) do
      {:ok, stop} -> stop
      :error -> Repo.get_by!(Stop, stop_id: stop_id, gtfs_version_id: fixture.version.id)
    end
  end

  defp change(review, key) do
    Enum.find(review.changes, &(&1.key == key)) || flunk("no change for #{key}")
  end

  defp drops(review, key) do
    Enum.filter(review.dropped, &(&1.key == key))
  end

  defp reason(reasons, key) do
    Enum.find(reasons, &match?({^key, _}, &1)) || flunk("no #{key} reason in #{inspect(reasons)}")
  end

  # --- fixtures. Every one runs inside `unboxed_run`: the fixture helpers open
  # their own transactions and the sandbox refuses a second checkout.

  defp station_fixture(fixture, stop_id, name) do
    stop_fixture(fixture.organization.id, fixture.version.id, %{
      stop_id: stop_id,
      stop_name: name,
      location_type: 1,
      stop_lat: Decimal.from_float(44.6250),
      stop_lon: Decimal.from_float(-124.0530)
    })
  end

  defp entrance_fixture(fixture, stop_id) do
    stop_fixture(fixture.organization.id, fixture.version.id, %{
      stop_id: stop_id,
      stop_name: "Entrance",
      location_type: 2,
      stop_lat: Decimal.from_float(44.6250),
      stop_lon: Decimal.from_float(-124.0530)
    })
  end

  # A bay of 1434. 1434 is itself a plain stop here: the case under test is that
  # *either* stop having a parent is enough to refuse, so the parent needs no
  # structure of its own beyond the foreign key the child row carries.
  defp child_fixture(fixture, child_id, parent_id, _parent_stop_id) do
    stop_fixture(fixture.organization.id, fixture.version.id, %{
      stop_id: child_id,
      stop_name: "Bay 1",
      location_type: 0,
      parent_station: parent_id,
      platform_code: "A",
      stop_lat: Decimal.from_float(44.6211),
      stop_lon: Decimal.from_float(-124.0530)
    })
  end

  defp pattern_fixture(fixture, route_pattern_id, stop_ids) do
    # Positions are 1-based and consecutive, which is what makes the adjacency
    # case real rather than incidental.
    pattern =
      route_pattern_fixture(fixture.organization.id, fixture.version.id, %{
        route_pattern_id: route_pattern_id
      })

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  defp trip_times(fixture, trip_id, stop_ids) do
    trip_fixture(fixture.organization.id, fixture.version.id, trip_id, %{
      trip_id: trip_id,
      service_id: "WEEKDAYS"
    })

    Enum.each(stop_ids, fn {stop_id, sequence} ->
      stop_time_fixture(fixture.organization.id, fixture.version.id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: "08:0#{sequence}:00",
        departure_time: "08:0#{sequence}:00"
      })
    end)
  end

  defp translation_fixture(fixture, record_id, language, text) do
    Repo.insert!(%Translation{
      organization_id: fixture.organization.id,
      gtfs_version_id: fixture.version.id,
      table_name: "stops",
      field_name: "stop_name",
      language: language,
      translation: text,
      record_id: record_id
    })
  end

  defp editing_status_fixture(fixture, station) do
    %StationEditingStatus{
      organization_id: fixture.organization.id,
      gtfs_version_id: fixture.version.id,
      station_id: station.id,
      user_id: fixture.actor.id,
      started_at: DateTime.utc_now()
    }
    |> StationEditingStatus.changeset(%{})
    |> Repo.insert!()
  end

  defp segment_fixture(fixture, from_stop_id, to_stop_id, points) do
    Repo.insert!(%AlignmentSegment{
      organization_id: fixture.organization.id,
      gtfs_version_id: fixture.version.id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id,
      points: points,
      lock_version: 1
    })
  end

  defp level_join(fixture, station) do
    level =
      level_fixture(fixture.organization.id, fixture.version.id, %{
        level_id: "L0",
        level_name: "Ground",
        level_index: 0.0
      })

    {:ok, _stop_level} =
      GtfsPlanner.GtfsFixtures.insert_stop_level(%{
        organization_id: fixture.organization.id,
        gtfs_version_id: fixture.version.id,
        stop_id: station.id,
        level_id: level.id
      })

    level
  end

  defp journal_fixture(fixture, station, level) do
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
  end

  # Every table the review reads, compared as rows *and* values. A review that
  # wrote and undid would pass a row count.
  defp snapshot(fixture) do
    unboxed(fn ->
      scope = [fixture.organization.id, fixture.version.id]

      %{
        stops: rows(Stop, scope),
        stop_times: rows(StopTime, scope),
        transfers: rows(Transfer, scope),
        relief_points: rows(ReliefPoint, scope),
        translations: rows(Translation, scope),
        segments: rows(AlignmentSegment, scope),
        deadheads: rows(DeadheadTime, scope),
        stop_levels: rows(StopLevel, scope),
        levels: rows(Level, scope),
        journal_entries: rows(JournalEntry, scope),
        editing_statuses: rows(StationEditingStatus, scope),
        logs:
          Repo.all(
            from log in ChangeLog,
              where:
                log.organization_id == ^fixture.organization.id and
                  log.gtfs_version_id == ^fixture.version.id,
              select: {log.id, log.inserted_at}
          )
      }
    end)
  end

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

  # --- staging

  # The old stop and its two candidate replacements are seeded up front because
  # almost every case needs them: 1391 is adjacent in the spec's example, 1500
  # is not, and the difference is the whole point of the adjacency rules.
  defp staged_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "stop-replace-#{stamp()}"})
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
            {"1433", "Main St"},
            {"1391", "Court St"},
            {"1500", "Harbour Way"},
            {"1501", "Quay St"}
          ],
          fn {id, name} ->
            {id,
             stop_fixture(organization.id, version.id, %{
               stop_id: id,
               stop_name: name,
               stop_lat: Decimal.from_float(44.6200),
               stop_lon: Decimal.from_float(-124.0530)
             })}
          end
        )

      calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAYS"})

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
    actor = user_fixture(%{email: "stop-replace-#{stamp()}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization_id,
        roles: ["pathways_studio_editor"]
      })

    actor
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  @cleanup_tables [
    ChangeLog,
    StopLevel,
    JournalEntry,
    StationEditingStatus,
    Transfer,
    ReliefPoint,
    StopTime,
    DeadheadTime,
    Translation,
    AlignmentSegment,
    Stop,
    GtfsPlanner.Gtfs.RoutePatternStop,
    GtfsPlanner.Gtfs.Trip,
    Level,
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
