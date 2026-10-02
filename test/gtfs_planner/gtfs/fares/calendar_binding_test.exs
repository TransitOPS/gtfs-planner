defmodule GtfsPlanner.Gtfs.Fares.CalendarBindingTest do
  use GtfsPlanner.DataCase, async: false
  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 2]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]
  alias GtfsPlanner.FaresFixtures
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Projection

  test "export preserves each authored weekday after chained service collisions" do
    org = organization_fixture(%{alias: "binding-calendar-chain"})
    actor = editor_fixture(org, %{email: "binding-calendar-chain@example.com"})
    version = gtfs_version_fixture(org.id, %{name: "calendar chain"})
    FaresFixtures.import!(org, version, "no_fare")

    scope = %{
      organization_id: org.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email,
        station_stop_id: nil
      }
    }

    assert {:ok, _} = Conversion.setup(scope, %{kind: :flat, adult: Decimal.new("6")})

    assert {:ok, _} =
             Fares.save_time_period(scope, %{
               name: "Peak",
               weekdays: 1,
               ranges: [%{start_seconds: 0, end_seconds: 3600}]
             })

    assert {:ok, _} =
             Fares.save_time_period(scope, %{
               name: "Peak 2",
               weekdays: 2,
               ranges: [%{start_seconds: 0, end_seconds: 3600}]
             })

    assert {:ok, _} =
             Gtfs.create_calendar(
               %{
                 service_id: "fare_peak",
                 name: "Later trip service",
                 kind: :weekly,
                 monday: 1,
                 tuesday: 1,
                 wednesday: 1,
                 thursday: 1,
                 friday: 1,
                 saturday: 1,
                 sunday: 1,
                 start_date: ~D[2026-09-07],
                 end_date: ~D[2026-09-08]
               },
               scope.audit
             )

    runtime = Interpreter.load_rows(org.id, version.id)
    export = Projection.export_rows(org.id, version.id)

    exported = %{
      runtime
      | timeframes: export.replaced["timeframes.txt"],
        fare_calendars: export.appended["calendar.txt"]
    }

    runtime_services = Map.new(runtime.timeframes, &{&1.timeframe_group_id, &1.service_id})
    export_services = Map.new(exported.timeframes, &{&1.timeframe_group_id, &1.service_id})
    assert runtime_services == %{"peak" => "fare_peak_2", "peak_2" => "fare_peak_2_2"}
    assert export_services == %{"peak" => "fare_peak_2", "peak_2" => "fare_peak_2_2"}
    assert Interpreter.active_timeframes(exported, ~D[2026-09-07], 1800) == ["peak"]
    assert Interpreter.active_timeframes(exported, ~D[2026-09-08], 1800) == ["peak_2"]
  end
end
