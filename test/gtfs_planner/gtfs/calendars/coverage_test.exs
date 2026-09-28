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
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.RowParser

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

  defp import_calendars(context, calendar_csv, attributes_csv) do
    Import.import_files(context.organization.id, context.version.id, [
      %{filename: "calendar.txt", content: calendar_csv},
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
end
