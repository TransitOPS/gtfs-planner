defmodule GtfsPlanner.Gtfs.Calendars.CombinationExportTest do
  @moduledoc """
  Merge evidence (EV-2) for the reviewed calendar combination's native export round trip (AC-27):
  the public `Gtfs.review_calendar_change/3` and `Gtfs.apply_calendar_change/3` composition, the
  public `Export.export_to_zip/3` writer and the public `Import.import_files/3` loader, against
  real scoped rows in the owned `gtfs_planner_exunit_calendar17` partition.

  These cases prove the result at the emitted-file boundary instead of through self-reimport
  equality alone:

  - A successful weekly destination keeps its kind and weekday mask in `calendar.txt` with the
    endpoints its mask still serves, stores exactly the reviewed additions as `calendar_dates.txt`
    rows (including deleting the cancelled Thanksgiving removal), and every changed trip's
    `service_id` in `trips.txt` resolves to a native `calendar.txt` or `calendar_dates.txt` row
    (AC-9, AC-10, AC-27).
  - A dates-only destination writes no `calendar.txt` row and exactly the chosen additions, while
    an empty weekly result keeps its `calendar.txt` row with explicit removals, so weekdays never
    resurrect on reimport (AC-9, AC-10, FH-2).
  - Reimporting the emitted files into a second owned version evaluates the destination to the
    independently enumerated literal result, keeps every source definition and preserves trip
    identity, route, block and stop-time linkage (AC-11, AC-27).
  - A metadata-only destination with zero post-move trips and no native reference is permitted to
    hold an empty result and writes nothing (AC-10).
  - The critique-M2 counterexample - a dates-only destination whose only addition (Monday
    2026-01-05) is cancelled by an explicit `no_service` conflict decision while its own trip and
    the source's trip would still reference it - is refused as `:native_service_required` by both
    review and apply, with zero writes and unchanged emitted native files (AC-10, M2).

  The focused gate command
  `mix test test/gtfs_planner/gtfs/calendars/combination_test.exs
  test/gtfs_planner/gtfs/calendars/combination_export_test.exs` is deferred to branch review;
  every assertion here is unexecuted until that gate runs.
  """
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.Snapshot
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.Versions.GtfsVersion

  # The destination's weekly baseline: every Mon-Fri from 2026-11-02 to 2026-11-27, which includes
  # Thanksgiving on Thursday 2026-11-26 - the conflict whose `run`/`no_service` decision the user
  # accepted on 2026-09-28.
  @november_weekdays ~w(2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06
                        2026-11-09 2026-11-10 2026-11-11 2026-11-12 2026-11-13
                        2026-11-16 2026-11-17 2026-11-18 2026-11-19 2026-11-20
                        2026-11-23 2026-11-24 2026-11-25 2026-11-26 2026-11-27)

  # The reviewed `run` decision keeps Thanksgiving and adds the source's Saturday 2026-11-28.
  @thanksgiving_result @november_weekdays ++ ~w(2026-11-28)

  # The literal Jan-5 dates of critique M2: Monday 2026-01-05 and the Mondays that follow it, plus
  # the single Mon-Fri week used for the empty weekly result.
  @january_mondays ~w(2026-01-05 2026-01-12 2026-01-19 2026-01-26)
  @january_week ~w(2026-01-05 2026-01-06 2026-01-07 2026-01-08 2026-01-09)

  setup do
    scope = unboxed(fn -> seed_scope("combine-export-#{unique()}") end)
    on_exit(fn -> cleanup(scope) end)

    {:ok, scope}
  end

  describe "the emitted native files after a successful combination" do
    test "a weekly destination keeps its mask and round-trips the accepted Thanksgiving conflict",
         scope do
      trips = unboxed(fn -> seed_thanksgiving_scope(scope) end)
      command = {:combine, "WKDY", ["HOL"], %{"2026-11-26" => "run"}}

      assert {:ok, review} = review(scope, command)
      assert review.ready?
      assert review.moved_trip_count == 1
      assert review.retained_sources == ["HOL"]

      assert review.conflicts == [
               %{
                 date: ~D[2026-11-26],
                 running_ids: ["HOL"],
                 removing_ids: ["WKDY"],
                 group_key: "2026-11-26"
               }
             ]

      assert {:ok, result} = apply_change(scope, command, review.fingerprint)
      assert result.action == :combined
      assert result.changed_trip_ids == [trips.source.id]

      # AC-11: the source keeps its definition and loses every trip.
      assert trip_count(scope, scope.version, "HOL") == 0

      # The stored destination rows already evaluate to the literal reviewed result.
      assert service_dates(scope, scope.version, "WKDY") == dates!(@thanksgiving_result)

      # The production export snapshot boundary reads the emitted files from one real session.
      files = export!(scope, scope.version, snapshot: Snapshot.Repo)

      # AC-9: the destination keeps its weekly kind, mask and endpoints.
      assert rows(files, "calendar.txt") == [weekday_row("WKDY", "20261102", "20261127")]

      # AC-9/AC-27: the stored exception rows are exactly the reviewed additions. The cancelled
      # Thanksgiving removal is gone, and the source keeps its own dates-only additions.
      assert calendar_date_tuples(files) == [
               {"HOL", "20261126", "1"},
               {"HOL", "20261128", "1"},
               {"WKDY", "20261128", "1"}
             ]

      # AC-11/AC-27: retained sources keep their metadata anchors, and every exported trip - the
      # moved one included - resolves to a native row.
      assert attribute_service_ids(files) == ["HOL", "WKDY"]

      exported_trips = assert_native_trip_service_ids!(files)
      assert exported_trips == %{"HOL_T1" => "WKDY", "WKDY_T1" => "WKDY"}

      changed_service_ids =
        Enum.map(result.changed_trip_ids, &stored_trip(scope, scope.version, &1).service_id)

      assert changed_service_ids == ["WKDY"]
      assert Enum.all?(changed_service_ids, &(&1 in native_service_ids(files)))

      # AC-27: the public import composition into a second owned version.
      round_trip = reimport!(scope, files)
      round_trip_files = export!(scope, round_trip)

      assert rows(round_trip_files, "calendar.txt") == rows(files, "calendar.txt")
      assert calendar_date_tuples(round_trip_files) == calendar_date_tuples(files)
      assert rows(round_trip_files, "trips.txt") == rows(files, "trips.txt")
      assert attribute_service_ids(round_trip_files) == ["HOL", "WKDY"]

      # The independent oracle: the reimported destination evaluates to the literal result, and the
      # retained source evaluates to exactly its own two dates.
      assert service_dates(scope, round_trip, "WKDY") == dates!(@thanksgiving_result)
      assert service_dates(scope, round_trip, "HOL") == [~D[2026-11-26], ~D[2026-11-28]]

      # AC-11/AC-27: trip identity, route, block, head sign and stop-time linkage are unchanged by
      # the move; only the service ID is the destination.
      assert trip_linkage(scope, round_trip) == trip_linkage(scope, scope.version)
      assert stop_time_linkage(scope, round_trip) == stop_time_linkage(scope, scope.version)

      assert Enum.map(trip_linkage(scope, round_trip), &{elem(&1, 0), elem(&1, 1)}) ==
               [{"HOL_T1", "WKDY"}, {"WKDY_T1", "WKDY"}]
    end

    test "a dates-only destination keeps no weekly row and round-trips exactly its chosen dates",
         scope do
      trips = unboxed(fn -> seed_dates_only_scope(scope) end)
      command = {:combine, "DOW", ["MON"], %{}}

      assert {:ok, review} = review(scope, command)
      assert review.ready?
      assert review.conflicts == []
      assert review.moved_trip_count == 1
      assert review.plan.result_dates == dates!(@january_mondays)

      assert {:ok, result} = apply_change(scope, command, review.fingerprint)
      assert result.action == :combined
      assert result.changed_trip_ids == [trips.source.id]

      files = export!(scope, scope.version)

      # AC-9: a dates-only destination writes no weekly row, and the source keeps its own row.
      assert rows(files, "calendar.txt") == [monday_row("MON", "20260105", "20260126")]

      # AC-9/AC-27: exactly the chosen additions and no removals.
      assert calendar_date_tuples(files) == [
               {"DOW", "20260105", "1"},
               {"DOW", "20260112", "1"},
               {"DOW", "20260119", "1"},
               {"DOW", "20260126", "1"}
             ]

      assert assert_native_trip_service_ids!(files) == %{"DOW_T1" => "DOW", "MON_T1" => "DOW"}
      assert attribute_service_ids(files) == ["DOW", "MON"]

      # AC-11: the source keeps its definition and loses its trip.
      assert trip_count(scope, scope.version, "MON") == 0

      round_trip = reimport!(scope, files)
      round_trip_files = export!(scope, round_trip)

      assert rows(round_trip_files, "calendar.txt") == rows(files, "calendar.txt")
      assert calendar_date_tuples(round_trip_files) == calendar_date_tuples(files)
      assert rows(round_trip_files, "trips.txt") == rows(files, "trips.txt")

      # The independent oracle: the destination and the retained source both evaluate to the
      # literal Mondays, and the destination still has no weekly row.
      assert service_dates(scope, round_trip, "DOW") == dates!(@january_mondays)
      assert service_dates(scope, round_trip, "MON") == dates!(@january_mondays)
      refute stored_weekly(scope, round_trip, "DOW")
      assert trip_linkage(scope, round_trip) == trip_linkage(scope, scope.version)
    end

    test "an empty weekly result keeps its native identity with explicit removals", scope do
      unboxed(fn -> seed_empty_weekly_scope(scope) end)
      command = {:combine, "WKE", ["REM"], Map.new(@january_week, &{&1, "no_service"})}

      assert {:ok, review} = review(scope, command)
      assert review.ready?
      assert review.plan.result_dates == []
      assert review.plan.unresolved_dates == []
      assert Enum.map(review.conflicts, & &1.date) == dates!(@january_week)

      # The five consecutive removed weekdays carry identical participants, so they are one group.
      assert Enum.uniq(Enum.map(review.conflicts, & &1.group_key)) == ["2026-01-05"]

      assert {:ok, result} = apply_change(scope, command, review.fingerprint)
      assert result.action == :combined
      assert result.moved_trip_count == 1

      assert service_dates(scope, scope.version, "WKE") == []
      assert service_dates(scope, scope.version, "REM") == []

      files = export!(scope, scope.version)

      # AC-10: an empty weekly result is permitted and keeps the destination's calendar.txt row, so
      # the trips that reference it are not dangling native references. The retained source keeps
      # its own weekly row beside it.
      assert rows(files, "calendar.txt") == [
               weekday_row("REM", "20260105", "20260109"),
               weekday_row("WKE", "20260105", "20260109")
             ]

      assert calendar_date_tuples(files) ==
               Enum.sort(
                 date_tuples("REM", @january_week, "2") ++ date_tuples("WKE", @january_week, "2")
               )

      assert assert_native_trip_service_ids!(files) == %{"REM_T1" => "WKE", "WKE_T1" => "WKE"}

      round_trip = reimport!(scope, files)
      round_trip_files = export!(scope, round_trip)

      # FH-2: the empty result does not resurrect the removed weekdays on reimport.
      assert service_dates(scope, round_trip, "WKE") == []
      assert service_dates(scope, round_trip, "REM") == []

      assert rows(round_trip_files, "calendar.txt") == rows(files, "calendar.txt")

      assert calendar_date_tuples(round_trip_files) == calendar_date_tuples(files)
    end
  end

  describe "the empty and refused results at the emitted-file boundary" do
    test "a metadata-only destination with no post-move trips may hold an empty result", scope do
      unboxed(fn -> seed_metadata_scope(scope) end)
      before = footprint(scope)

      command = {:combine, "META", ["NOSVC"], %{}}

      assert {:ok, review} = review(scope, command)
      assert review.ready?
      assert review.plan.result_dates == []
      assert review.moved_trip_count == 0

      assert {:ok, result} = apply_change(scope, command, review.fingerprint)
      assert result.action == :unchanged
      assert result.operation_id == nil
      assert result.changed_trip_ids == []

      # AC-12/AC-10: no anchor, native row or audit is written for an allowed empty result.
      assert before.logs == []
      assert footprint(scope) == before

      files = export!(scope, scope.version)

      # Neither native file exists, the metadata anchors are only extension rows, and no trip can
      # dangle on the empty identity.
      refute "calendar.txt" in names(files)
      refute "calendar_dates.txt" in names(files)
      refute "trips.txt" in names(files)
      assert native_service_ids(files) == MapSet.new()
      assert assert_native_trip_service_ids!(files) == %{}
      assert attribute_service_ids(files) == ["META", "NOSVC"]

      # The metadata-only identity survives a round trip as a metadata-only identity.
      round_trip = reimport!(scope, files)

      refute stored_weekly(scope, round_trip, "META")
      assert stored_date_tuples(scope, round_trip, "META") == []
      assert attribute_service_ids(export!(scope, round_trip)) == ["META", "NOSVC"]
    end

    test "a cancelled dates-only addition is refused with zero writes and unchanged native files",
         scope do
      unboxed(fn -> seed_january_fifth_scope(scope) end)
      command = {:combine, "D5", ["S5"], %{"2026-01-05" => "no_service"}}

      before_files = export!(scope, scope.version)
      before = footprint(scope)

      # Critique M2's conflict: the destination's only addition is the date the source deliberately
      # removes, so the only conflict date is Monday 2026-01-05.
      assert {:ok, unresolved} = review(scope, {:combine, "D5", ["S5"], %{}})
      refute unresolved.ready?
      assert unresolved.plan.union_dates == [~D[2026-01-05]]

      assert unresolved.conflicts == [
               %{
                 date: ~D[2026-01-05],
                 running_ids: ["D5"],
                 removing_ids: ["S5"],
                 group_key: "2026-01-05"
               }
             ]

      # AC-10/M2: cancelling it leaves the dates-only destination with neither a `calendar.txt` nor
      # a `calendar_dates.txt` row while its own trip and the source's trip would still reference
      # it, so review and apply both refuse before any write.
      assert {:error, :native_service_required} = review(scope, command)

      assert {:error, :native_service_required} =
               apply_change(scope, command, String.duplicate("a", 64))

      assert before.logs == []
      assert footprint(scope) == before

      # The pre-operation state is intact: the destination still runs its one added day and the
      # source keeps its trip.
      assert service_dates(scope, scope.version, "D5") == [~D[2026-01-05]]
      assert trip_count(scope, scope.version, "S5") == 1

      after_files = export!(scope, scope.version)

      for name <- ~w(calendar.txt calendar_dates.txt calendar_attributes.txt trips.txt) do
        assert file_content(after_files, name) == file_content(before_files, name)
      end

      assert calendar_date_tuples(after_files) == [
               {"D5", "20260105", "1"},
               {"S5", "20260105", "2"}
             ]

      assert assert_native_trip_service_ids!(after_files) == %{
               "D5_T1" => "D5",
               "S5_T1" => "S5"
             }
    end
  end

  # --- fixtures --------------------------------------------------------------

  defp seed_scope(prefix) do
    organization = organization_fixture(%{alias: "#{prefix}-#{unique()}"})
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "R_#{prefix}"})
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})
    actor = user_fixture(%{email: "#{prefix}-#{unique()}@example.test"})
    organization_membership_fixture(actor, organization)

    %{
      organization: organization,
      version: version,
      route: route,
      actor: actor,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: "#{prefix}@example.test"
      }
    }
  end

  # The accepted conflict example at its literal dates: the destination's weekly row removes
  # Thanksgiving (Thursday 2026-11-26) from its own Mon-Fri baseline, while the selected dates-only
  # source runs it together with its own Saturday.
  defp seed_thanksgiving_scope(scope) do
    {organization_id, version_id, route_id} = scope_ids(scope)

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "WKDY",
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-11-02],
      end_date: ~D[2026-11-27]
    })

    calendar_date_fixture(organization_id, version_id, %{
      service_id: "WKDY",
      date: ~D[2026-11-26],
      exception_type: 2
    })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "HOL",
      dates: [~D[2026-11-26], ~D[2026-11-28]]
    })

    %{
      destination:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "WKDY_T1",
          service_id: "WKDY"
        }),
      source:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "HOL_T1",
          service_id: "HOL"
        })
    }
  end

  # A dates-only destination (Monday 2026-01-05 and 2026-01-12, no weekly row) and a weekly Monday
  # source covering 2026-01-05..2026-01-26, so the union adds the two later Mondays.
  defp seed_dates_only_scope(scope) do
    {organization_id, version_id, route_id} = scope_ids(scope)

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "DOW",
      dates: [~D[2026-01-05], ~D[2026-01-12]]
    })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "MON",
      monday: 1,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-01-26]
    })

    %{
      destination:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "DOW_T1",
          service_id: "DOW"
        }),
      source:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "MON_T1",
          service_id: "MON"
        })
    }
  end

  # Both calendars run the single Mon-Fri week 2026-01-05..2026-01-09, and the source removes all
  # five of its own baseline days, so choosing no service for all five empties the result.
  defp seed_empty_weekly_scope(scope) do
    {organization_id, version_id, route_id} = scope_ids(scope)

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "WKE",
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-01-09]
    })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "REM",
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-01-09]
    })

    Enum.each(@january_week, fn iso_date ->
      calendar_date_fixture(organization_id, version_id, %{
        service_id: "REM",
        date: Date.from_iso8601!(iso_date),
        exception_type: 2
      })
    end)

    %{
      destination:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "WKE_T1",
          service_id: "WKE"
        }),
      source:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "REM_T1",
          service_id: "REM"
        })
    }
  end

  # A metadata-only destination and a metadata-only source, both without native rows and without
  # trips, so the reviewed result is empty with nothing to reference it.
  defp seed_metadata_scope(scope) do
    {organization_id, version_id, _route_id} = scope_ids(scope)

    calendar_attribute_fixture(organization_id, version_id, %{
      service_id: "META",
      service_description: "Metadata Only"
    })

    calendar_service_fixture(organization_id, version_id, %{service_id: "NOSVC", dates: []})
  end

  # Critique M2's concrete input: the destination is dates-only with its single addition on Monday
  # 2026-01-05, and the source's weekly Monday row is that same day removed.
  defp seed_january_fifth_scope(scope) do
    {organization_id, version_id, route_id} = scope_ids(scope)

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "D5",
      dates: [~D[2026-01-05]]
    })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "S5",
      monday: 1,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-01-05]
    })

    calendar_date_fixture(organization_id, version_id, %{
      service_id: "S5",
      date: ~D[2026-01-05],
      exception_type: 2
    })

    %{
      destination:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "D5_T1",
          service_id: "D5"
        }),
      source:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "S5_T1",
          service_id: "S5"
        })
    }
  end

  defp scope_ids(scope), do: {scope.organization.id, scope.version.id, scope.route.id}

  # --- the public composition -------------------------------------------------

  defp review(scope, command) do
    unboxed(fn ->
      Gtfs.review_calendar_change(command, selected_fingerprints(command), scope.audit)
    end)
  end

  defp apply_change(scope, command, review_fingerprint) do
    unboxed(fn -> Gtfs.apply_calendar_change(command, review_fingerprint, scope.audit) end)
  end

  # The fingerprints map a retained-form caller submits: exactly one entry per selected ID. The
  # reviewed authority is the server's own complete-input digest, so these values are never trusted.
  defp selected_fingerprints({:combine, destination_id, source_ids, _decisions}) do
    Map.new([destination_id | source_ids], &{&1, "client-#{&1}"})
  end

  defp export!(scope, version, opts \\ []) do
    snapshot = Keyword.get(opts, :snapshot)
    original = Application.get_env(:gtfs_planner, :gtfs_export_snapshot)

    if snapshot, do: Application.put_env(:gtfs_planner, :gtfs_export_snapshot, snapshot)

    try do
      unboxed(fn ->
        assert {:ok, zip} = Export.export_to_zip(scope.organization.id, version.id, :full)
        unzip(zip)
      end)
    after
      if snapshot, do: Application.put_env(:gtfs_planner, :gtfs_export_snapshot, original)
    end
  end

  defp reimport!(scope, files) do
    target = unboxed(fn -> gtfs_version_fixture(scope.organization.id) end)

    reimport = Enum.map(files, fn {name, content} -> %{filename: name, content: content} end)

    assert {:ok, _result} =
             unboxed(fn ->
               StagedImport.import_files(scope.organization.id, target.id, reimport)
             end)

    target
  end

  # --- emitted-file inspection ------------------------------------------------

  defp unzip(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    Enum.map(entries, fn {name, content} -> {to_string(name), content} end)
  end

  defp names(files), do: Enum.map(files, fn {name, _content} -> name end)

  defp file_content(files, name) do
    Enum.find_value(files, &if(elem(&1, 0) == name, do: to_string(elem(&1, 1))))
  end

  defp rows(files, name) do
    case file_content(files, name) do
      nil -> flunk("#{name} is missing from the export; got #{inspect(names(files))}")
      content -> parse_rows(name, content)
    end
  end

  defp rows_or_empty(files, name) do
    case file_content(files, name) do
      nil -> []
      content -> parse_rows(name, content)
    end
  end

  defp parse_rows(name, content) do
    assert {:ok, parsed} = CsvParser.stream(name, content)

    Enum.map(parsed.events, fn
      {:ok, _row_number, row} -> row
      other -> flunk("unexpected parse event for #{name}: #{inspect(other)}")
    end)
  end

  defp native_service_ids(files) do
    weekly = files |> rows_or_empty("calendar.txt") |> Enum.map(& &1["service_id"])
    dates = files |> rows_or_empty("calendar_dates.txt") |> Enum.map(& &1["service_id"])

    MapSet.new(weekly ++ dates)
  end

  # AC-10/AC-27 at the emitted-file boundary: no exported trip may name a service ID that has
  # neither a `calendar.txt` nor a `calendar_dates.txt` row. Returns the exported trip -> service
  # ID map so the caller can assert the exact IDs.
  defp assert_native_trip_service_ids!(files) do
    native = native_service_ids(files)

    exported =
      files
      |> rows_or_empty("trips.txt")
      |> Map.new(&{&1["trip_id"], &1["service_id"]})

    Enum.each(exported, fn {trip_id, service_id} ->
      assert service_id in native,
             "exported trip #{trip_id} references #{inspect(service_id)}, which has no " <>
               "calendar.txt or calendar_dates.txt row; native IDs: " <>
               inspect(Enum.sort(MapSet.to_list(native)))
    end)

    exported
  end

  defp calendar_date_tuples(files) do
    files
    |> rows_or_empty("calendar_dates.txt")
    |> Enum.map(&{&1["service_id"], &1["date"], &1["exception_type"]})
    |> Enum.sort()
  end

  defp attribute_service_ids(files) do
    files
    |> rows_or_empty("calendar_attributes.txt")
    |> Enum.map(& &1["service_id"])
    |> Enum.sort()
  end

  defp date_tuples(service_id, iso_dates, exception_type) do
    Enum.map(iso_dates, fn iso_date ->
      {service_id, String.replace(iso_date, "-", ""), exception_type}
    end)
  end

  defp weekday_row(service_id, start_date, end_date) do
    %{
      "service_id" => service_id,
      "monday" => "1",
      "tuesday" => "1",
      "wednesday" => "1",
      "thursday" => "1",
      "friday" => "1",
      "saturday" => "0",
      "sunday" => "0",
      "start_date" => start_date,
      "end_date" => end_date
    }
  end

  defp monday_row(service_id, start_date, end_date) do
    %{
      weekday_row(service_id, start_date, end_date)
      | "tuesday" => "0",
        "wednesday" => "0",
        "thursday" => "0",
        "friday" => "0"
    }
  end

  # --- stored rows ------------------------------------------------------------

  defp dates!(iso_dates), do: Enum.map(iso_dates, &Date.from_iso8601!/1)

  defp stored_weekly(scope, version, service_id) do
    unboxed(fn ->
      Repo.one(
        from(c in Calendar,
          where:
            c.organization_id == ^scope.organization.id and
              c.gtfs_version_id == ^version.id and c.service_id == ^service_id
        )
      )
    end)
  end

  defp stored_date_tuples(scope, version, service_id) do
    unboxed(fn ->
      Repo.all(
        from(d in CalendarDate,
          where:
            d.organization_id == ^scope.organization.id and
              d.gtfs_version_id == ^version.id and d.service_id == ^service_id,
          order_by: d.date,
          select: {d.date, d.exception_type}
        )
      )
    end)
  end

  defp service_dates(scope, version, service_id) do
    unboxed(fn ->
      ServiceDates.active_dates(
        stored_weekly(scope, version, service_id),
        Repo.all(
          from(d in CalendarDate,
            where:
              d.organization_id == ^scope.organization.id and
                d.gtfs_version_id == ^version.id and d.service_id == ^service_id,
            order_by: d.date
          )
        )
      )
    end)
  end

  defp stored_trip(scope, version, trip_uuid) do
    unboxed(fn ->
      Repo.get_by!(Trip,
        id: trip_uuid,
        organization_id: scope.organization.id,
        gtfs_version_id: version.id
      )
    end)
  end

  defp trip_count(scope, version, service_id) do
    unboxed(fn ->
      Repo.aggregate(
        from(t in Trip,
          where:
            t.organization_id == ^scope.organization.id and
              t.gtfs_version_id == ^version.id and t.service_id == ^service_id
        ),
        :count
      )
    end)
  end

  defp trip_linkage(scope, version) do
    unboxed(fn ->
      Repo.all(
        from(t in Trip,
          where: t.organization_id == ^scope.organization.id and t.gtfs_version_id == ^version.id,
          order_by: t.trip_id,
          select: {t.trip_id, t.service_id, t.route_id, t.block_id, t.trip_headsign}
        )
      )
    end)
  end

  defp stop_time_linkage(scope, version) do
    unboxed(fn ->
      Repo.all(
        from(st in StopTime,
          where:
            st.organization_id == ^scope.organization.id and st.gtfs_version_id == ^version.id,
          order_by: [st.trip_id, st.stop_sequence],
          select: {st.trip_id, st.stop_sequence, st.stop_id, st.arrival_time, st.departure_time}
        )
      )
    end)
  end

  # Everything a refused or empty combination must not write.
  defp footprint(scope) do
    unboxed(fn ->
      organization_id = scope.organization.id

      %{
        calendars:
          Repo.all(
            from(c in Calendar,
              where: c.organization_id == ^organization_id,
              order_by: [c.service_id, c.updated_at],
              select: {c.service_id, c.start_date, c.end_date, c.updated_at}
            )
          ),
        calendar_dates:
          Repo.all(
            from(d in CalendarDate,
              where: d.organization_id == ^organization_id,
              order_by: [d.service_id, d.date],
              select: {d.service_id, d.date, d.exception_type}
            )
          ),
        calendar_attributes:
          Repo.all(
            from(a in CalendarAttribute,
              where: a.organization_id == ^organization_id,
              order_by: a.service_id,
              select: {a.service_id, a.updated_at}
            )
          ),
        trips:
          Repo.all(
            from(t in Trip,
              where: t.organization_id == ^organization_id,
              order_by: t.trip_id,
              select: {t.trip_id, t.service_id, t.block_id, t.updated_at}
            )
          ),
        logs:
          Repo.all(
            from(l in ChangeLog,
              where: l.organization_id == ^organization_id,
              order_by: [l.entity_type, l.entity_external_id],
              select: {l.entity_type, l.entity_external_id, l.changed_fields}
            )
          )
      }
    end)
  end

  # --- helpers ---------------------------------------------------------------

  defp unique, do: System.unique_integer([:positive])

  defp cleanup(scope) do
    organization_id = scope.organization.id
    actor_id = scope.actor.id

    unboxed(fn ->
      timing_ids =
        Repo.all(
          from(t in TimedPattern, where: t.organization_id == ^organization_id, select: t.id)
        )

      Repo.delete_all(from(r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids))
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
      Repo.delete_all(from(t in Transfer, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
      Repo.delete_all(from(f in Frequency, where: f.organization_id == ^organization_id))
      Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(t in TimedPattern, where: t.organization_id == ^organization_id))
      Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
      Repo.delete_all(from(l in Level, where: l.organization_id == ^organization_id))
      Repo.delete_all(from(r in RoutePatternStop, where: r.organization_id == ^organization_id))

      Repo.delete_all(from(p in RoutePattern, where: p.organization_id == ^organization_id))

      Repo.delete_all(from(s in BlockingSetting, where: s.organization_id == ^organization_id))

      Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id == ^organization_id))

      Repo.delete_all(from(d in CalendarDate, where: d.organization_id == ^organization_id))
      Repo.delete_all(from(c in Calendar, where: c.organization_id == ^organization_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(a in Agency, where: a.organization_id == ^organization_id))

      Repo.delete_all(
        from(m in UserOrgMembership,
          where: m.organization_id == ^organization_id or m.user_id == ^actor_id
        )
      )

      delete_versions!(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(u in User, where: u.id == ^actor_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
    end)
  end

  # `Sandbox.unboxed_run/2` is not re-entrant, so each top-level call wraps its body once. Every
  # fixture, public command, export and import here runs on a real checked-out connection: the
  # composition under test is the ordinary one, with no injected internal transaction adapter.
  defp unboxed(fun) do
    if Process.get(:combination_export_connection) do
      fun.()
    else
      Process.put(:combination_export_connection, true)

      try do
        Sandbox.unboxed_run(Repo, fun)
      after
        Process.delete(:combination_export_connection)
      end
    end
  end
end
