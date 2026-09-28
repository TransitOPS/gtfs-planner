defmodule GtfsPlanner.Gtfs.Calendars.CoverageTest do
  @moduledoc """
  Retained invalid calendar inputs read through the import and list paths.

  `RowParser` and `Import.import_files/3` keep accepting a reversed weekly range, and
  the catalog list read reports that identity as an identified coverage error without
  raising, while valid identities in the same version keep their derived dates.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.RowParser
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @today ~D[2026-06-15]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  describe "a reversed imported weekly range" do
    test "is identified on its summary instead of read as an empty service", context do
      row = %{
        "service_id" => "REVERSED_WEEKLY",
        "monday" => "1",
        "tuesday" => "1",
        "wednesday" => "1",
        "thursday" => "1",
        "friday" => "1",
        "saturday" => "0",
        "sunday" => "0",
        "start_date" => "20261231",
        "end_date" => "20260101"
      }

      assert {:ok, attrs} =
               RowParser.calendar_row_to_attrs(row, context.organization.id, context.version.id)

      assert Date.compare(attrs.end_date, attrs.start_date) == :lt

      route =
        route_fixture(context.organization.id, context.version.id, %{route_id: "r_reversed"})

      trip_fixture(context.organization.id, context.version.id, route.route_id, %{
        service_id: "REVERSED_WEEKLY"
      })

      calendar_csv = """
      service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
      REVERSED_WEEKLY,1,1,1,1,1,0,0,20261231,20260101
      VALID_WEEKLY,1,0,0,0,0,0,0,20260615,20260615
      """

      attributes_csv = """
      service_id,service_description
      REVERSED_WEEKLY,Reversed Weekday
      VALID_WEEKLY,Regular Weekday
      """

      assert {:ok, _result} =
               import_calendars(context, calendar_csv, attributes_csv)

      assert {:ok, summaries} =
               Gtfs.load_calendar_catalog(context.organization.id, context.version.id,
                 today: @today
               )

      reversed = summary!(summaries, "REVERSED_WEEKLY")

      assert reversed.coverage_error == %{service_id: "REVERSED_WEEKLY", reason: :reversed_range}
      assert reversed.name == "Reversed Weekday"
      assert reversed.kind == :weekly
      assert reversed.trip_count == 1
      assert reversed.active_dates == []
      assert reversed.first_active_date == nil
      assert reversed.last_active_date == nil
      assert reversed.warnings == []
      refute reversed.status.no_service?
      refute reversed.status.active_today?
      refute reversed.status.active_period?
      refute reversed.status.ended?
      assert reversed.status.used_by_trips?

      valid = summary!(summaries, "VALID_WEEKLY")

      assert valid.coverage_error == nil
      assert valid.active_dates == [~D[2026-06-15]]
      assert valid.status.active_today?
      refute valid.status.no_service?
    end
  end

  describe "an all-zero weekly row and a metadata-only identity" do
    test "stay valid without a coverage error", context do
      calendar_csv = """
      service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
      LEGACY_ZERO,0,0,0,0,0,0,0,20260101,20261231
      """

      attributes_csv = """
      service_id,service_description
      LEGACY_ZERO,Legacy Zero
      META_ONLY,Metadata Only
      """

      assert {:ok, _result} =
               import_calendars(context, calendar_csv, attributes_csv)

      assert {:ok, summaries} =
               Gtfs.load_calendar_catalog(context.organization.id, context.version.id,
                 today: @today
               )

      legacy = summary!(summaries, "LEGACY_ZERO")

      assert legacy.coverage_error == nil
      assert legacy.kind == :weekly
      assert legacy.active_dates == []
      assert legacy.status.no_service?
      refute legacy.status.used_by_trips?

      meta = summary!(summaries, "META_ONLY")

      assert meta.coverage_error == nil
      assert meta.kind == :dates_only
      assert meta.calendar == nil
      assert meta.attributes.service_description == "Metadata Only"
      assert meta.active_dates == []
      assert meta.status.no_service?
    end
  end

  describe "one coherent calendar screen snapshot" do
    test "returns exact weekly, exception and metadata identities without writes", context do
      :ok = screen_identities(context)

      before = write_counts()

      assert {:ok, screen} =
               Gtfs.load_calendar_screen(context.organization.id, context.version.id)

      assert write_counts() == before

      assert screen.complete?
      assert screen.invalid_calendars == []

      assert screen.zone == %{
               timezone: "UTC",
               fallback?: false,
               fallback_reason: nil,
               date: Date.utc_today()
             }

      assert screen.today == Date.utc_today()
      assert screen.horizon == %{first_date: ~D[2026-01-03], last_date: ~D[2026-01-19]}

      assert screen.gaps == [
               %{first_date: ~D[2026-01-12], last_date: ~D[2026-01-14]},
               %{first_date: ~D[2026-01-17], last_date: ~D[2026-01-18]}
             ]

      assert Enum.map(screen.rows, & &1.service_id) == [
               "EXCEPTION_ONLY",
               "META_ONLY",
               "WKDY",
               "WEEKEND"
             ]

      exception_only = summary!(screen.rows, "EXCEPTION_ONLY")

      assert exception_only.kind == :dates_only
      assert exception_only.name == nil
      assert exception_only.calendar == nil
      assert exception_only.attributes == nil
      assert exception_only.coverage_error == nil
      assert exception_only.active_dates == [~D[2026-01-04]]
      assert exception_only.first_active_date == ~D[2026-01-04]
      assert exception_only.last_active_date == ~D[2026-01-04]
      assert exception_only.trip_count == 0
      assert exception_only.routes == []

      assert Enum.map(exception_only.exceptions, &{&1.date, &1.exception_type}) == [
               {~D[2026-01-04], 1}
             ]

      assert exception_only.periods == %{
               periods: [],
               breaks: [],
               holidays: [],
               extra_days: [~D[2026-01-04]],
               removed_days: []
             }

      metadata_only = summary!(screen.rows, "META_ONLY")

      assert metadata_only.kind == :dates_only
      assert metadata_only.name == "Metadata Only"
      assert metadata_only.calendar == nil
      assert metadata_only.attributes.service_description == "Metadata Only"
      assert metadata_only.active_dates == []
      assert metadata_only.first_active_date == nil
      assert metadata_only.exceptions == []

      assert metadata_only.periods == %{
               periods: [],
               breaks: [],
               holidays: [],
               extra_days: [],
               removed_days: []
             }

      assert metadata_only.trip_count == 1
      assert metadata_only.routes == [%{route_id: "r_screen", trip_count: 1}]

      weekday = summary!(screen.rows, "WKDY")

      assert weekday.kind == :weekly
      assert weekday.name == "Weekday Service"
      assert weekday.coverage_error == nil
      assert weekday.calendar.start_date == ~D[2026-01-05]
      assert weekday.calendar.end_date == ~D[2026-01-19]
      assert weekday.calendar.monday == 1
      assert weekday.calendar.saturday == 0

      assert weekday.active_dates == [
               ~D[2026-01-03],
               ~D[2026-01-05],
               ~D[2026-01-06],
               ~D[2026-01-07],
               ~D[2026-01-08],
               ~D[2026-01-09],
               ~D[2026-01-15],
               ~D[2026-01-16],
               ~D[2026-01-19]
             ]

      assert Enum.map(weekday.exceptions, &{&1.date, &1.exception_type}) == [
               {~D[2026-01-03], 1},
               {~D[2026-01-12], 2},
               {~D[2026-01-13], 2},
               {~D[2026-01-14], 2}
             ]

      assert weekday.periods == %{
               periods: [
                 %{first_date: ~D[2026-01-05], last_date: ~D[2026-01-11]},
                 %{first_date: ~D[2026-01-15], last_date: ~D[2026-01-19]}
               ],
               breaks: [
                 %{first_date: ~D[2026-01-12], last_date: ~D[2026-01-14], service_days: 3}
               ],
               holidays: [],
               extra_days: [~D[2026-01-03]],
               removed_days: []
             }

      assert weekday.trip_count == 1
      assert weekday.routes == [%{route_id: "r_screen", trip_count: 1}]

      weekend = summary!(screen.rows, "WEEKEND")

      assert weekend.kind == :weekly
      assert weekend.active_dates == [~D[2026-01-10], ~D[2026-01-11]]
      assert weekend.exceptions == []
      assert weekend.trip_count == 0
      assert weekend.routes == []

      assert weekend.periods == %{
               periods: [%{first_date: ~D[2026-01-10], last_date: ~D[2026-01-11]}],
               breaks: [],
               holidays: [],
               extra_days: [],
               removed_days: []
             }
    end

    test "filtering a source list leaves the original global horizon and gaps unchanged",
         context do
      :ok = screen_identities(context)

      assert {:ok, all} = Gtfs.load_calendar_screen(context.organization.id, context.version.id)

      assert {:ok, filtered} =
               Gtfs.load_calendar_screen(context.organization.id, context.version.id,
                 service_ids: ["WKDY", "META_ONLY"]
               )

      assert Enum.map(filtered.rows, & &1.service_id) == ["META_ONLY", "WKDY"]
      assert filtered.horizon == all.horizon
      assert filtered.gaps == all.gaps
      assert filtered.today == all.today
      assert filtered.zone == all.zone
      assert filtered.invalid_calendars == all.invalid_calendars
      assert filtered.complete?

      # An unknown or empty source list returns no rows and still reports the
      # version-wide coverage facts of the unfiltered read.
      assert {:ok, unknown} =
               Gtfs.load_calendar_screen(context.organization.id, context.version.id,
                 service_ids: ["UNKNOWN", "wkdy"]
               )

      assert unknown.rows == []
      assert unknown.horizon == all.horizon
      assert unknown.gaps == all.gaps

      assert {:ok, empty} =
               Gtfs.load_calendar_screen(context.organization.id, context.version.id,
                 service_ids: []
               )

      assert empty.rows == []
      assert empty.horizon == all.horizon
      assert empty.gaps == all.gaps
    end
  end

  describe "a screen snapshot of a version holding a retained invalid weekly range" do
    test "reports an incomplete read with nil gaps and keeps the readable rows", context do
      calendar_csv = """
      service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
      REVERSED_WEEKLY,1,1,1,1,1,0,0,20261231,20260101
      VALID_WEEKLY,1,0,0,0,0,0,0,20260302,20260309
      """

      attributes_csv = """
      service_id,service_description
      REVERSED_WEEKLY,Reversed Weekday
      VALID_WEEKLY,Valid Weekday
      """

      assert {:ok, _result} = import_calendars(context, calendar_csv, attributes_csv)

      route =
        route_fixture(context.organization.id, context.version.id, %{route_id: "r_reversed"})

      trip_fixture(context.organization.id, context.version.id, route.route_id, %{
        service_id: "REVERSED_WEEKLY"
      })

      assert {:ok, screen} =
               Gtfs.load_calendar_screen(context.organization.id, context.version.id)

      refute screen.complete?
      assert screen.gaps == nil

      assert screen.invalid_calendars == [
               %{service_id: "REVERSED_WEEKLY", reason: :reversed_range}
             ]

      reversed = summary!(screen.rows, "REVERSED_WEEKLY")

      assert reversed.coverage_error == %{
               service_id: "REVERSED_WEEKLY",
               reason: :reversed_range
             }

      assert reversed.name == "Reversed Weekday"
      assert reversed.kind == :weekly
      assert reversed.trip_count == 1
      assert reversed.routes == [%{route_id: "r_reversed", trip_count: 1}]
      assert reversed.exceptions == []
      assert reversed.active_dates == []
      refute reversed.status.no_service?

      assert reversed.periods == %{
               periods: [],
               breaks: [],
               holidays: [],
               extra_days: [],
               removed_days: []
             }

      valid = summary!(screen.rows, "VALID_WEEKLY")

      assert valid.coverage_error == nil
      assert valid.active_dates == [~D[2026-03-02], ~D[2026-03-09]]

      assert valid.periods == %{
               periods: [%{first_date: ~D[2026-03-02], last_date: ~D[2026-03-09]}],
               breaks: [],
               holidays: [],
               extra_days: [],
               removed_days: []
             }

      # The horizon can only cover dates this read could evaluate; `complete?: false`
      # discloses that the version also holds a range it refused to read.
      assert screen.horizon == %{first_date: ~D[2026-03-02], last_date: ~D[2026-03-09]}
    end
  end

  defp import_calendars(context, calendar_csv, attributes_csv) do
    Import.import_files(context.organization.id, context.version.id, [
      %{filename: "calendar.txt", content: calendar_csv},
      %{filename: "calendar_attributes.txt", content: attributes_csv}
    ])
  end

  defp import_calendars(context, calendar_csv, dates_csv, attributes_csv) do
    Import.import_files(context.organization.id, context.version.id, [
      %{filename: "calendar.txt", content: calendar_csv},
      %{filename: "calendar_dates.txt", content: dates_csv},
      %{filename: "calendar_attributes.txt", content: attributes_csv}
    ])
  end

  defp summary!(summaries, service_id) do
    Enum.find(summaries, &(&1.service_id == service_id)) ||
      flunk(
        "expected a summary for #{service_id}, got: " <>
          inspect(Enum.map(summaries, & &1.service_id))
      )
  end

  # Four identities with different native shapes: a weekly row with an out-of-range
  # addition and a three-day break, a weekend weekly row, an exception-only identity
  # and a metadata-only identity. The agency zone is UTC so the resolved agency-local
  # today is the UTC date, which the case compares against an independent `Date.utc_today/0`.
  defp screen_identities(context) do
    agency_fixture(context.organization.id, context.version.id, %{agency_timezone: "UTC"})

    calendar_csv = """
    service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
    WKDY,1,1,1,1,1,0,0,20260105,20260119
    WEEKEND,0,0,0,0,0,1,1,20260110,20260111
    """

    dates_csv = """
    service_id,date,exception_type
    WKDY,20260103,1
    WKDY,20260112,2
    WKDY,20260113,2
    WKDY,20260114,2
    EXCEPTION_ONLY,20260104,1
    """

    attributes_csv = """
    service_id,service_description
    WKDY,Weekday Service
    WEEKEND,Weekend Service
    META_ONLY,Metadata Only
    """

    assert {:ok, _result} = import_calendars(context, calendar_csv, dates_csv, attributes_csv)

    route = route_fixture(context.organization.id, context.version.id, %{route_id: "r_screen"})

    trip_fixture(context.organization.id, context.version.id, route.route_id, %{
      service_id: "WKDY"
    })

    trip_fixture(context.organization.id, context.version.id, route.route_id, %{
      service_id: "META_ONLY"
    })

    :ok
  end

  # `Trip`, `ChangeLog` and the three calendar tables must be unchanged by a read.
  defp write_counts do
    {
      Repo.aggregate(Calendar, :count),
      Repo.aggregate(CalendarAttribute, :count),
      Repo.aggregate(CalendarDate, :count),
      Repo.aggregate(Trip, :count),
      Repo.aggregate(ChangeLog, :count)
    }
  end
end
