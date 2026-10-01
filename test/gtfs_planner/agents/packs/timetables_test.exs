defmodule GtfsPlanner.Agents.Packs.TimetablesTest do
  @moduledoc """
  Focused coverage for the Timetables helper pack (step 4, EV-4).

  Every expected value is written out by hand from the fixture below: the twenty
  November 2026 service dates the reviewed policy produces, the service-day
  seconds each pasted cell reads as, the two service calendars the route runs and
  the native plan's own counts. Nothing is asserted against another call into
  `GtfsPlanner.Agents.Packs.Timetables`.

  The four cases are the execution card's four observable cases, and they drive
  the real production composition: `GtfsPlanner.Agents.Dispatch.call/4` against
  the pack `GtfsPlanner.Agents.packs/0` ships, the admitted source built by the
  public `TimetableSource` entrypoints and the real
  `GtfsPlanner.Gtfs.prepare_timetable_paste/5`. The only boundary a case could
  fake is the provider's HTTP call, and no case makes one: the pack is called
  directly, so this file proves the pack contract and the native preparation it
  delegates to, not a model's choice of tool.
  """

  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Timetables
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.TimetablePaste
  alias GtfsPlanner.Gtfs.TimetableSource
  alias GtfsPlanner.Gtfs.Trip

  # The reviewed weekday policy over 2026-11-02..2026-11-30 with Thanksgiving
  # Thursday 2026-11-26 removed: 21 ISO weekdays in the interval, 20 reviewed.
  @november_dates ~w(
    2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06
    2026-11-09 2026-11-10 2026-11-11 2026-11-12 2026-11-13
    2026-11-16 2026-11-17 2026-11-18 2026-11-19 2026-11-20
    2026-11-23 2026-11-24 2026-11-25 2026-11-27 2026-11-30
  )

  @foreign_uuid "00000000-0000-0000-0000-000000000000"

  setup do
    organization =
      organization_fixture(%{alias: "timetable-pack-#{System.unique_integer([:positive])}"})

    version = gtfs_version_fixture(organization.id)

    user =
      user_fixture(%{email: "timetable-pack-#{System.unique_integer([:positive])}@example.com"})

    organization_membership_fixture(user, organization)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "SRC1",
        route_short_name: "14",
        route_long_name: "Harbor - Union"
      })

    # Two calendars the route actually runs: weekdays (two trips) and Friday (one).
    for {service_id, name, friday?} <- [{"SRC_WKD", "Weekday", 0}, {"SRC_FRI", "Friday", 1}] do
      calendar_fixture(organization.id, version.id, %{service_id: service_id, friday: friday?})

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: name,
        service_schedule_name: name
      })
    end

    Enum.each(1..3, fn index ->
      stop_fixture(organization.id, version.id, %{
        stop_id: "SRC_S#{index}",
        stop_name: "Source Stop #{index}"
      })
    end)

    pattern =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "SRC-MAIN",
        route_pattern_name: "Main",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"SRC_S1", 0, 0, 1},
          {"SRC_S2", 300, 360, 1},
          {"SRC_S3", 660, 720, 1}
        ]
      })

    # 06:00 and 07:00 on the weekday calendar, 08:00 on the Friday calendar.
    for {service_id, trip_id, hour} <- [
          {"SRC_WKD", "SRC_T360", 6},
          {"SRC_WKD", "SRC_T420", 7},
          {"SRC_FRI", "SRC_T480", 8}
        ] do
      schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
        service_id: service_id,
        trip_id: trip_id,
        start_time: "#{hour}:00:00",
        trip_headsign: "Union Depot"
      })
    end

    weekday = paste_scope(organization, version, route, "SRC_WKD")
    friday = paste_scope(organization, version, route, "SRC_FRI")

    payload = accepted_payload(weekday, friday)

    scope =
      scope_with_source(
        %{
          organization: organization,
          version: version,
          user: user,
          route: route
        },
        payload
      )

    Map.merge(context(organization, version, user, route, weekday, friday), %{
      scope: scope,
      payload: payload,
      source: accepted_source(weekday, friday)
    })
  end

  describe "case 1: the registered pack reads the source, inspects the route and prepares one batch" do
    test "is the pack the application ships, with no apply or comparison tool", context do
      assert Agents.packs()["timetables"] == Timetables
      assert Timetables.id() == "timetables"
      assert Timetables.title() == "Timetable helper"

      assert Enum.map(Timetables.tools(), & &1.name) == [
               "read_timetable_source",
               "inspect_timetable_scope",
               "prepare_timetable_input"
             ]

      assert Timetables.authorize_context(context.scope) == :ok
      assert Timetables.intro() =~ "prepare"
      assert Timetables.skill() =~ "prepare_timetable_input"
    end

    test "reads the accepted source with its own digest and row count", context do
      assert {:ok, result, evidence} = call(context.scope, "read_timetable_source")

      assert result["label"] == "November 2026 board sheet"
      assert result["revision"] == "r3"
      assert result["notes"] == "Thanksgiving Thursday removed; weekdays otherwise."
      assert result["accepted?"] == true
      assert result["digest"] == context.source.digest

      assert result["interval"] == %{
               "first_date" => "2026-11-02",
               "last_date" => "2026-11-30",
               "date_count" => 29
             }

      assert result["date_rules"]["policy"] == "weekly"
      assert result["date_rules"]["weekdays"] == [1, 2, 3, 4, 5]
      assert result["date_rules"]["removed_dates"] == ["2026-11-26"]
      assert result["row_count"] == 3
      assert result["text_truncated"] == false
      assert result["text"] == pasted_text()
      assert result["unresolved"] == []
      assert result["exclusions"] == []

      assert [
               %{
                 "source_row_id" => 1,
                 "feed_trip_id" => "SRC_T360",
                 "service_id" => "SRC_WKD",
                 "direction_id" => 0,
                 "dates" => @november_dates,
                 "cells" => [
                   %{"stop_id" => "SRC_S1", "stop_sequence" => 0, "arrival" => 21_600},
                   %{"stop_id" => "SRC_S2", "stop_sequence" => 0, "arrival" => 21_900},
                   %{"stop_id" => "SRC_S3", "stop_sequence" => 0, "arrival" => 22_200}
                 ]
               },
               %{
                 "source_row_id" => 2,
                 "feed_trip_id" => "SRC_T420",
                 "service_id" => "SRC_WKD",
                 "dates" => @november_dates
               },
               %{
                 "source_row_id" => 3,
                 "feed_trip_id" => "SRC_T480",
                 "service_id" => "SRC_FRI",
                 "dates" => @november_dates
               }
             ] = result["rows"]

      # The evidence card describes the same payload the tool returned.
      assert evidence.kind == "timetable_source"
      assert evidence.total == 3
      assert evidence.total_label == "source rows"
      assert evidence.completeness == :complete
      assert evidence.digest == context.source.digest
      assert evidence.source_ref == "gtfs_timetable_source"
      assert evidence.source_revision == nil
      assert evidence.scope.organization_id == context.organization.id
      assert evidence.scope.gtfs_version_id == context.version.id
      assert evidence.scope.identity == "route:#{context.route.id}"
      assert fact(evidence, "Effective interval") == "2026-11-02 to 2026-11-30"
      assert fact(evidence, "Date policy") =~ "weekdays 1,2,3,4,5"
    end

    test "inspects the route's own native options for the source's calendars", context do
      assert {:ok, result} = call(context.scope, "inspect_timetable_scope")

      assert result["route_id"] == "SRC1"

      assert [
               %{
                 "service_id" => "SRC_FRI",
                 "available" => true,
                 "calendar_name" => "Friday",
                 "direction_id" => 0,
                 "trip_count" => 1
               },
               %{
                 "service_id" => "SRC_WKD",
                 "available" => true,
                 "calendar_name" => "Weekday",
                 "direction_id" => 0,
                 "trip_count" => 2
               }
             ] = result["calendars"]

      assert [pattern] = hd(result["calendars"])["patterns"]
      assert pattern["route_pattern_id"] == "SRC-MAIN"
      assert pattern["name"] == "Main"
      assert pattern["trip_count"] == 1

      assert Enum.map(pattern["occurrences"], &{&1["position"], &1["stop_id"]}) == [
               {1, "SRC_S1"},
               {2, "SRC_S2"},
               {3, "SRC_S3"}
             ]
    end

    test "prepares exactly the selected weekday rows and writes nothing", context do
      before = row_counts()

      assert {:prepared, prepared, result, evidence} =
               prepare(context.scope, %{
                 "row_ids" => [1, 2],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      assert {:timetable_input, command} = prepared.command
      assert command.source_digest == context.source.digest
      assert command.row_ids == [1, 2]

      assert command.scope_params == %{
               service_id: "SRC_WKD",
               direction_id: 0,
               pattern_id: context.weekday.pattern_id
             }

      assert command.input.text == pasted_text()
      assert command.input.mode == :add
      assert command.input.header? == true
      assert String.match?(command.fingerprint, ~r/\A[0-9a-f]{64}\z/)

      # Only the row that is not in this batch is skipped.
      assert command.input.decisions == %{3 => %{skip: true, shift: 0, cells: %{}}}

      assert result["service_id"] == "SRC_WKD"
      assert result["calendar_name"] == "Weekday"
      assert result["source_digest"] == context.source.digest
      assert result["row_count"] == 2
      assert result["rows_left_out"] == 1
      assert result["corrections"] == []
      assert result["mode"] == "add"
      assert result["refusal"] == nil

      # The two pasted rows reproduce the two recorded trips exactly, so the
      # native plan counts them as duplicates of what the feed already holds.
      assert result["counts"] == %{
               "add" => 0,
               "change" => 0,
               "duplicate" => 2,
               "needs_decision" => 0,
               "remove" => 0,
               "skipped" => 1,
               "unchanged" => 0
             }

      assert [
               %{"source_row_id" => 1, "feed_trip_id" => "SRC_T360", "dates" => 20},
               %{"source_row_id" => 2, "feed_trip_id" => "SRC_T420", "dates" => 20}
             ] = result["rows"]

      assert prepared.summary.title == "Prepare SRC_WKD"

      assert prepared.summary.detail ==
               "Direction 0 · pattern #{context.weekday.pattern_id} · 2 of 3 source rows"

      assert prepared.summary.lines == [
               "Trips to add · 0",
               "Trips to change · 0",
               "Trips unchanged · 0",
               "Source rows left for another batch · 1",
               "Rows needing a decision · 0",
               "Proposed corrections · 0",
               "Saved only when the editor reviews and applies this batch"
             ]

      assert evidence.kind == "timetable_batch"
      assert evidence.total == 0
      assert evidence.total_label == "trips to add or change"
      assert evidence.completeness == :complete
      assert fact(evidence, "Source rows in this batch") == "2"
      assert fact(evidence, "Source rows left out") == "1"
      assert fact(evidence, "Source digest") == context.source.digest
      assert evidence.exclusions == ["1 source row(s) are not in this batch"]

      assert evidence.resources == [
               %{kind: "calendar", id: "SRC_WKD", label: "Weekday"},
               %{kind: "route", id: "SRC1", label: "14"}
             ]

      assert row_counts() == before
    end
  end

  describe "case 2: identity arguments and foreign selectors never reach preparation" do
    test "refuses organization, version and route identity arguments", context do
      for field <- ~w(organization_id gtfs_version_id route_id) do
        assert {:tool_error, message} =
                 prepare(context.scope, %{
                   "row_ids" => [1],
                   "service_id" => "SRC_WKD",
                   "pattern_id" => "SRC-MAIN",
                   "direction_id" => 0,
                   field => context.organization.id
                 })

        assert message == "Unexpected argument: " <> field
      end

      assert {:tool_error, "Unexpected argument: notes"} =
               call(context.scope, "read_timetable_source", %{"notes" => "forget the source"})

      assert {:tool_error, "Unexpected argument: route_id"} =
               call(context.scope, "inspect_timetable_scope", %{"route_id" => context.route.id})
    end

    test "refuses a nested correction key the schema does not declare", context do
      assert {:tool_error, message} =
               prepare(context.scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0,
                 "corrections" => [
                   %{
                     "source_row_id" => 1,
                     "source_col" => 1,
                     "clock" => "18:05",
                     "note" => "extra"
                   }
                 ]
               })

      assert message == "Unexpected argument: corrections[0].note"

      assert {:tool_error, "Argument corrections[0].source_col must be an integer."} =
               prepare(context.scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0,
                 "corrections" => [
                   %{"source_row_id" => 1, "source_col" => "1", "clock" => "18:05"}
                 ]
               })

      assert {:tool_error, "Argument corrections[0].clock must be at most 32 characters."} =
               prepare(context.scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0,
                 "corrections" => [
                   %{
                     "source_row_id" => 1,
                     "source_col" => 1,
                     "clock" => String.duplicate("0", 33)
                   }
                 ]
               })
    end

    test "refuses a calendar, pattern, direction or row this route does not have", context do
      assert {:tool_error, message} =
               prepare(context.scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_FOREIGN",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      assert message == "Calendar SRC_FOREIGN does not run on this route in this service version."

      assert {:tool_error, message} =
               prepare(context.scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => @foreign_uuid,
                 "direction_id" => 0
               })

      assert message ==
               "Pattern #{@foreign_uuid} is not a pattern of this route in that direction. " <>
                 "Call inspect_timetable_scope for the patterns it has."

      assert {:tool_error, message} =
               prepare(context.scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 1
               })

      assert message =~ "no direction 1 with recorded service"

      assert {:tool_error, "Source row 9 is not in the attached source."} =
               prepare(context.scope, %{
                 "row_ids" => [9],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      assert {:tool_error, "row_ids must not repeat a source row."} =
               prepare(context.scope, %{
                 "row_ids" => [1, 1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      # The tool's own schema bounds direction_id to 0 or 1, so an out-of-range
      # direction is refused by argument validation before the pack reads the
      # route at all.
      assert {:tool_error, "Argument direction_id must be at most 1."} =
               prepare(context.scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 2
               })
    end

    test "refuses a source row that was reviewed against another pattern", context do
      # A server-admitted snapshot whose row names a pattern this route does not
      # have: the envelope is valid, so only the pack can refuse it.
      forged_payload =
        put_in(context.payload, ["rows"], [
          put_in(hd(context.payload["rows"]), ["pattern_id"], @foreign_uuid)
        ])

      forged_scope =
        scope_with_source(
          %{
            organization: context.organization,
            version: context.version,
            user: context.user,
            route: context.route
          },
          forged_payload
        )

      assert {:tool_error, message} =
               prepare(forged_scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      assert message == "Those source rows were reviewed against another pattern of this route."
    end

    test "refuses a context without an accepted source, a foreign editor and a revoked member",
         context do
      without_source = %{
        context.scope
        | resource_context: Scope.context({:route, context.route.id})
      }

      assert call(without_source, "read_timetable_source") == {:error, :unavailable}
      assert Timetables.authorize_context(without_source) == {:error, :unavailable}

      foreign_organization = organization_fixture()
      foreign_user = user_fixture()
      organization_membership_fixture(foreign_user, foreign_organization)

      assert call(%{context.scope | user_id: foreign_user.id}, "read_timetable_source") ==
               {:error, :forbidden}

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      assert call(%{context.scope | user_id: viewer.id}, "read_timetable_source") ==
               {:error, :forbidden}

      membership = Accounts.get_user_org_membership(context.user.id, context.organization.id)
      assert {:ok, _membership} = Accounts.delete_user_org_membership(membership)

      assert call(context.scope, "read_timetable_source") == {:error, :forbidden}
    end
  end

  describe "case 3: two calendars are two batches, never one merged command" do
    test "prepares the weekday and Friday batches separately", context do
      assert {:prepared, weekday_prepared, weekday_result, _evidence} =
               prepare(context.scope, %{
                 "row_ids" => [1, 2],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      assert {:prepared, friday_prepared, friday_result, _friday_evidence} =
               prepare(context.scope, %{
                 "row_ids" => [3],
                 "service_id" => "SRC_FRI",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      {:timetable_input, weekday_command} = weekday_prepared.command
      {:timetable_input, friday_command} = friday_prepared.command

      # Both proposals name the same reviewed source, and each carries exactly
      # one calendar and only its own rows.
      assert weekday_command.source_digest == friday_command.source_digest
      assert weekday_command.source_digest == context.source.digest
      assert weekday_command.row_ids == [1, 2]
      assert friday_command.row_ids == [3]
      assert weekday_command.scope_params.service_id == "SRC_WKD"
      assert friday_command.scope_params.service_id == "SRC_FRI"

      assert weekday_command.input.decisions == %{3 => %{skip: true, shift: 0, cells: %{}}}

      assert friday_command.input.decisions == %{
               1 => %{skip: true, shift: 0, cells: %{}},
               2 => %{skip: true, shift: 0, cells: %{}}
             }

      refute weekday_command.fingerprint == friday_command.fingerprint
      assert weekday_result["row_count"] == 2
      assert friday_result["row_count"] == 1
      assert weekday_result["rows_left_out"] == 1
      assert friday_result["rows_left_out"] == 2
      assert friday_result["counts"]["duplicate"] == 1
      assert friday_prepared.summary.title == "Prepare SRC_FRI"
    end

    test "refuses rows from two calendars in one batch", context do
      assert {:tool_error, message} =
               prepare(context.scope, %{
                 "row_ids" => [1, 2, 3],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      assert message ==
               "Those rows belong to more than one calendar. Prepare one calendar per call, so " <>
                 "each batch gets its own confirmation."
    end

    test "proposes a correction into the native draft without touching the source", context do
      assert {:prepared, prepared, result, _evidence} =
               prepare(context.scope, %{
                 "row_ids" => [1, 2],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0,
                 "corrections" => [
                   %{"source_row_id" => 1, "source_col" => 1, "clock" => "18:05"}
                 ]
               })

      {:timetable_input, command} = prepared.command

      assert command.input.decisions[1] == %{"cells" => %{1 => "18:05"}}
      assert command.input.decisions[3] == %{skip: true, shift: 0, cells: %{}}

      assert result["corrections"] == [
               %{"source_row_id" => 1, "source_col" => 1, "clock" => "18:05"}
             ]

      # The corrected cell no longer matches the recorded trip, so the native
      # plan now proposes one added trip instead of two duplicates.
      assert result["counts"]["add"] == 1
      assert result["counts"]["duplicate"] == 1
      assert command.source_digest == context.source.digest
    end

    test "leaves an ambiguous or unreadable clock to the editor", context do
      for {clock, expected} <- [
            {"6:05", "Clock 6:05 is ambiguous on a 12-hour reading."},
            {"noon", "Clock noon is not a time this timetable can read."}
          ] do
        assert {:tool_error, message} =
                 prepare(context.scope, %{
                   "row_ids" => [1],
                   "service_id" => "SRC_WKD",
                   "pattern_id" => "SRC-MAIN",
                   "direction_id" => 0,
                   "corrections" => [
                     %{"source_row_id" => 1, "source_col" => 1, "clock" => clock}
                   ]
                 })

        assert message =~ expected
      end

      assert {:tool_error, "Column 9 is not a column of the pasted source."} =
               prepare(context.scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0,
                 "corrections" => [
                   %{"source_row_id" => 1, "source_col" => 9, "clock" => "18:05"}
                 ]
               })

      assert {:tool_error, "A correction names source row 3, which is not in this batch."} =
               prepare(context.scope, %{
                 "row_ids" => [1],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0,
                 "corrections" => [
                   %{"source_row_id" => 3, "source_col" => 1, "clock" => "18:05"}
                 ]
               })
    end
  end

  describe "case 4: the evidence is the native review's own, and a bounded pair is refused" do
    test "binds the card to the native review fingerprint and plan counts", context do
      assert {:prepared, prepared, result, evidence} =
               prepare(context.scope, %{
                 "row_ids" => [1, 2],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      {:timetable_input, command} = prepared.command

      # The same pure fingerprint the editor's own review computes from the same
      # scope and input, recomputed here from the native scope and the command.
      assert TimetablePaste.fingerprint(context.weekday, command.input) == command.fingerprint
      assert evidence.digest == command.fingerprint
      assert evidence.digest == result["fingerprint"]
      assert evidence.source_ref == "gtfs_timetable_paste"
      assert evidence.total == result["counts"]["add"] + result["counts"]["change"]
      assert evidence.total_label == "trips to add or change"
      assert evidence.scope.identity == "route:#{context.route.id}"

      # Nothing a model could write reaches the card: it carries exactly the
      # keys `GtfsPlanner.Agents.Pack`'s evidence type declares, and no value
      # in it is a URL or a prose total.
      assert Enum.sort(Map.keys(evidence)) == [
               :completeness,
               :completeness_reason,
               :digest,
               :exclusions,
               :facts,
               :kind,
               :resources,
               :scope,
               :source_ref,
               :source_revision,
               :title,
               :total,
               :total_label
             ]

      refute inspect(evidence) =~ "http"
      assert Enum.all?(evidence.facts, &(is_binary(&1.label) and is_binary(&1.value)))
    end

    test "marks a batch with an open decision incomplete and names it", context do
      # A pasted cell the native grammar cannot read leaves the row needing the
      # editor's own decision, which the card must not present as complete.
      undecided_payload =
        put_in(context.payload, ["text"], String.replace(pasted_text(), "7:05", "later"))

      undecided_scope =
        scope_with_source(
          %{
            organization: context.organization,
            version: context.version,
            user: context.user,
            route: context.route
          },
          undecided_payload
        )

      assert {:prepared, _prepared, result, evidence} =
               prepare(undecided_scope, %{
                 "row_ids" => [2],
                 "service_id" => "SRC_WKD",
                 "pattern_id" => "SRC-MAIN",
                 "direction_id" => 0
               })

      assert result["needs_decision"] > 0
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason =~ "need an editor decision"
    end

    test "refuses a source whose answer is larger than one tool result" do
      wide = wide_context()

      {:ok, payload} = TimetableSource.assistant_payload(wide.source)

      # The whole source is admitted (it is under the 65,536-byte context
      # ceiling), so the refusal is the existing result limit, not a truncation.
      assert byte_size(Jason.encode!(payload)) < 65_536
      assert byte_size(Jason.encode!(payload)) > 32_768

      assert call(wide.scope, "read_timetable_source") ==
               {:tool_error, "Too much data for one result. Narrow the request."}

      # The batch itself stays preparable: only the whole-source read is refused.
      assert {:prepared, _prepared, result, _evidence} =
               prepare(wide.scope, %{
                 "row_ids" => [1, 2],
                 "service_id" => "WIDE_WKD",
                 "pattern_id" => "WIDE-MAIN",
                 "direction_id" => 0
               })

      assert result["row_count"] == 2
      assert result["rows_left_out"] == 6
    end
  end

  # -- fixture helpers ------------------------------------------------------

  defp context(organization, version, user, route, weekday, friday) do
    %{
      organization: organization,
      version: version,
      user: user,
      route: route,
      weekday: weekday,
      friday: friday
    }
  end

  defp paste_scope(organization, version, route, service_id) do
    assert {:ok, %{scope: native}} =
             Gtfs.prepare_timetable_paste(
               organization.id,
               version.id,
               route.route_id,
               %{"service_id" => service_id},
               %{"text" => ""}
             )

    native
  end

  defp accepted_source(weekday, friday) do
    assert {:ok, draft} =
             TimetableSource.normalize(source_params(weekday), source_scope(weekday, friday))

    assert draft.unresolved == []
    assert {:ok, accepted} = TimetableSource.accept(draft, %{confirmed?: true})
    accepted
  end

  defp accepted_payload(weekday, friday) do
    assert {:ok, payload} = TimetableSource.assistant_payload(accepted_source(weekday, friday))
    payload
  end

  defp source_scope(weekday, friday) do
    pattern_by_natural = Map.new(weekday.patterns, &{&1.route_pattern_id, &1.id})

    %{
      patterns:
        Enum.map(weekday.patterns, fn pattern ->
          %{
            id: pattern.id,
            occurrences:
              Enum.map(pattern.occurrences, fn occurrence ->
                %{stop_id: occurrence.stop_id, stop_sequence: occurrence.position}
              end)
          }
        end),
      trips:
        [weekday, friday]
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn scope ->
          Enum.map(scope.trips, fn trip ->
            %{
              id: trip.trip_id,
              direction_id: trip.direction_id,
              pattern_id: Map.get(pattern_by_natural, trip.route_pattern_id),
              first_departure_secs: trip.start_secs,
              service_id: scope.calendar.service_id
            }
          end)
        end)
    }
  end

  defp source_params(weekday) do
    %{
      "text" => pasted_text(),
      "label" => "November 2026 board sheet",
      "revision" => "r3",
      "notes" => "Thanksgiving Thursday removed; weekdays otherwise.",
      "first_date" => "2026-11-02",
      "last_date" => "2026-11-30",
      "date_policy" => "weekly",
      "weekdays" => [1, 2, 3, 4, 5],
      "removed_dates" => ["2026-11-26"],
      "mapping" => %{
        "direction_id" => 0,
        "pattern_id" => weekday.pattern_id,
        "columns" => %{
          "1" => %{"stop_id" => "SRC_S1", "stop_sequence" => 0},
          "2" => %{"stop_id" => "SRC_S2", "stop_sequence" => 0},
          "3" => %{"stop_id" => "SRC_S3", "stop_sequence" => 0}
        },
        "rows" => %{
          "1" => %{"feed_trip_id" => "SRC_T360"},
          "2" => %{"feed_trip_id" => "SRC_T420"},
          "3" => %{"feed_trip_id" => "SRC_T480"}
        }
      }
    }
  end

  defp pasted_text do
    "Trip\tSource Stop 1\tSource Stop 2\tSource Stop 3\n" <>
      "101\t6:00\t6:05\t6:10\n" <>
      "102\t7:00\t7:05\t7:10\n" <>
      "103\t8:00\t8:05\t8:10\n"
  end

  defp scope_with_source(context, payload) do
    assert {:ok, resource_context} =
             Scope.with_source_snapshot(Scope.context({:route, context.route.id}), %{
               kind: "gtfs_timetable_source",
               payload: payload
             })

    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: Timetables.id(),
      version_name: context.version.name,
      resource_context: resource_context
    }
  end

  # A second route whose reviewed source covers a whole year of daily service:
  # eight rows over 365 dates is admitted whole and is larger than one tool
  # result may carry.
  defp wide_context do
    organization = organization_fixture(%{alias: "timetable-pack-wide"})
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)

    route =
      route_fixture(organization.id, version.id, %{route_id: "WIDE1", route_short_name: "40"})

    calendar_fixture(organization.id, version.id, %{
      service_id: "WIDE_WKD",
      saturday: 1,
      sunday: 1
    })

    Enum.each(1..3, fn index ->
      stop_fixture(organization.id, version.id, %{
        stop_id: "WIDE_S#{index}",
        stop_name: "Wide Stop #{index}"
      })
    end)

    pattern =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "WIDE-MAIN",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"WIDE_S1", 0, 0, 1},
          {"WIDE_S2", 300, 360, 1},
          {"WIDE_S3", 660, 720, 1}
        ]
      })

    for index <- 1..8 do
      schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
        service_id: "WIDE_WKD",
        trip_id: "WIDE_T#{index}",
        start_time: "#{5 + index}:00:00"
      })
    end

    native = paste_scope(organization, version, route, "WIDE_WKD")

    text =
      ([["Trip", "Wide Stop 1", "Wide Stop 2", "Wide Stop 3"]] ++
         for(
           index <- 1..8,
           do: ["#{200 + index}", "#{5 + index}:00", "#{5 + index}:05", "#{5 + index}:10"]
         ))
      |> Enum.map_join("\n", &Enum.join(&1, "\t"))
      |> Kernel.<>("\n")

    params = %{
      "text" => text,
      "label" => "Full year sheet",
      "first_date" => "2026-01-01",
      "last_date" => "2026-12-31",
      "date_policy" => "weekly",
      "weekdays" => [1, 2, 3, 4, 5, 6, 7],
      "mapping" => %{
        "direction_id" => 0,
        "pattern_id" => native.pattern_id,
        "columns" => %{
          "1" => %{"stop_id" => "WIDE_S1", "stop_sequence" => 0},
          "2" => %{"stop_id" => "WIDE_S2", "stop_sequence" => 0},
          "3" => %{"stop_id" => "WIDE_S3", "stop_sequence" => 0}
        },
        "rows" => Map.new(1..8, &{Integer.to_string(&1), %{"feed_trip_id" => "WIDE_T#{&1}"}})
      }
    }

    scope = %{
      patterns:
        Enum.map(native.patterns, fn pattern ->
          %{
            id: pattern.id,
            occurrences:
              Enum.map(pattern.occurrences, fn occurrence ->
                %{stop_id: occurrence.stop_id, stop_sequence: occurrence.position}
              end)
          }
        end),
      trips:
        Enum.map(native.trips, fn trip ->
          %{
            id: trip.trip_id,
            direction_id: trip.direction_id,
            pattern_id: native.pattern_id,
            first_departure_secs: trip.start_secs,
            service_id: "WIDE_WKD"
          }
        end)
    }

    assert {:ok, draft} = TimetableSource.normalize(params, scope)
    assert draft.unresolved == []
    assert {:ok, accepted} = TimetableSource.accept(draft, %{confirmed?: true})

    %{
      source: accepted,
      scope:
        scope_with_source(
          %{organization: organization, version: version, user: user, route: route},
          elem(TimetableSource.assistant_payload(accepted), 1)
        )
    }
  end

  defp call(scope, name, args \\ nil) do
    Dispatch.call(Timetables, scope, name, args && Jason.encode!(args))
  end

  defp prepare(scope, args),
    do: Dispatch.call(Timetables, scope, "prepare_timetable_input", Jason.encode!(args))

  defp fact(evidence, label) do
    Enum.find_value(evidence.facts, fn fact -> fact.label == label && fact.value end)
  end

  defp row_counts do
    {Repo.aggregate(Calendar, :count), Repo.aggregate(Trip, :count),
     Repo.aggregate(CalendarDate, :count), Repo.aggregate(ChangeLog, :count)}
  end
end
