defmodule GtfsPlanner.Home.PlannerStatusTest do
  @moduledoc """
  Planner status facts and attention through the real reads.

  These cases read real imported calendars, real validation runs and real
  import-run rows, so the coverage claim, the stopped-import filter and the
  check-error item are observed against PostgreSQL rather than hand-built maps.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Home
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  test "weekday and Saturday calendars without Sunday service raise no attention", context do
    today = Date.utc_today()
    range_start = Date.add(today, -30)
    range_end = Date.add(today, 90)
    last_active = last_service_date(range_end)

    import_calendars(
      context,
      """
      service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
      WKDY,1,1,1,1,1,0,0,#{stamp(range_start)},#{stamp(range_end)}
      SAT,0,0,0,0,0,1,0,#{stamp(range_start)},#{stamp(range_end)}
      """,
      """
      service_id,service_description
      WKDY,Weekday Service
      SAT,Saturday Service
      """
    )

    route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})

    level = level_fixture(context.organization.id, context.version.id)

    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: "STATION1",
      location_type: 1
    })

    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: "PLATFORM1",
      location_type: 0,
      parent_station: "STATION1",
      level_id: level.level_id
    })

    # The Sundays are real version-wide gaps; attention must never use them (CR-6).
    assert {:ok, screen} = Gtfs.load_calendar_screen(context.organization.id, context.version.id)
    assert screen.complete?
    assert screen.gaps != []
    assert screen.horizon.last_date == last_active

    assert %{
             coverage: {:through, ^last_active},
             today: ^today,
             counts: %{routes: 1, calendars: 2, stations: 1},
             first_use?: false,
             attention: []
           } = Home.planner_status(context.organization.id, context.version.id)
  end

  test "a reversed imported range makes coverage unknown and raises no service item", context do
    today = Date.utc_today()
    soon_end = Date.add(today, 13)

    import_calendars(
      context,
      """
      service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
      REVERSED,1,1,1,1,1,0,0,20261231,20260101
      SOON,1,1,1,1,1,1,1,#{stamp(Date.add(today, -7))},#{stamp(soon_end)}
      """,
      """
      service_id,service_description
      REVERSED,Reversed Weekday
      SOON,Soon Ending
      """
    )

    assert {:ok, screen} = Gtfs.load_calendar_screen(context.organization.id, context.version.id)
    refute screen.complete?
    assert screen.horizon.last_date == soon_end

    assert %{coverage: :unknown, attention: []} =
             Home.planner_status(context.organization.id, context.version.id)
  end

  test "a cleaning import run is not shown while a failed import run is", context do
    cleaning_version = staging_version(context.organization, "Cleanup in progress")
    failed_version = staging_version(context.organization, "October 2026 service")

    insert_run(context.organization, cleaning_version, "cleaning",
      lease_token: Ecto.UUID.generate(),
      lease_expires_at: ~U[2026-09-27 09:05:00.000000Z],
      cleanup_started_at: ~U[2026-09-27 09:00:00.000000Z]
    )

    failed =
      insert_run(context.organization, failed_version, "failed",
        failed_file: "stop_times.txt",
        failed_row: 18_204,
        finished_at: ~U[2026-09-27 10:00:00.000000Z]
      )

    foreign_organization = organization_fixture()
    foreign_version = staging_version(foreign_organization, "Foreign import")

    insert_run(foreign_organization, foreign_version, "failed",
      failed_file: "trips.txt",
      failed_row: 3,
      finished_at: ~U[2026-09-27 11:00:00.000000Z]
    )

    # `cleaning` is both recoverable and active, so it is not a stopped import;
    # the failed run names another version of this organization and still shows.
    assert %{attention: [item]} = Home.planner_status(context.organization.id, context.version.id)

    assert item == %{
             kind: :stopped_import,
             run_id: failed.id,
             version_name: "October 2026 service",
             failed_file: "stop_times.txt",
             failed_row: 18_204
           }

    assert Home.pathways_attention(context.organization.id, context.version.id) == [item]
  end

  test "the latest feed check with errors raises a check-errors item", context do
    agency_fixture(context.organization.id, context.version.id, %{
      agency_timezone: "America/New_York"
    })

    check =
      insert_check(context.organization, context.version,
        run_type: "mobility_data",
        errors_count: 2,
        started_at: ~U[2026-09-25 02:00:00.000000Z]
      )

    insert_check(context.organization, context.version,
      run_type: "station_reachability",
      errors_count: 5,
      started_at: ~U[2026-09-26 09:00:00.000000Z]
    )

    assert %{attention: [item]} = Home.planner_status(context.organization.id, context.version.id)

    assert item == %{
             kind: :check_errors,
             run_id: check.id,
             errors: 2,
             at: ~U[2026-09-25 02:00:00.000000Z],
             local_at: ~N[2026-09-24 22:00:00.000000]
           }

    assert Home.pathways_attention(context.organization.id, context.version.id) == [item]
  end

  test "an empty version is a first use", context do
    assert %{
             coverage: :none,
             today: %Date{},
             counts: %{routes: 0, calendars: 0, stations: 0},
             first_use?: true,
             attention: []
           } = Home.planner_status(context.organization.id, context.version.id)

    assert Home.pathways_attention(context.organization.id, context.version.id) == []
  end

  test "published_on is the agency-local date of the publication instant", context do
    agency_fixture(context.organization.id, context.version.id, %{
      agency_timezone: "America/New_York"
    })

    publish_at(context.version, ~U[2026-03-10 02:30:00.000000Z])

    assert %{published_on: ~D[2026-03-09]} =
             Home.planner_status(context.organization.id, context.version.id)
  end

  test "published_on falls back to the UTC date when the agency has no time zone", context do
    publish_at(context.version, ~U[2026-03-10 02:30:00.000000Z])

    assert %{published_on: ~D[2026-03-10]} =
             Home.planner_status(context.organization.id, context.version.id)
  end

  defp import_calendars(context, calendar_csv, attributes_csv) do
    assert {:ok, _result} =
             Import.import_files(context.organization.id, context.version.id, [
               %{filename: "calendar.txt", content: calendar_csv},
               %{filename: "calendar_attributes.txt", content: attributes_csv}
             ])

    :ok
  end

  defp publish_at(version, published_at) do
    version
    |> Ecto.Changeset.change(published_at: published_at)
    |> Repo.update!()
  end

  defp staging_version(organization, name) do
    assert {:ok, version} = Versions.create_staging_gtfs_version(organization.id, %{name: name})
    version
  end

  defp insert_run(organization, version, state, attrs) do
    attrs =
      Map.merge(
        %{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          version_name: version.name,
          state: state,
          committed_counts: %{},
          counts_complete: true
        },
        Map.new(attrs)
      )

    Repo.insert!(struct!(Run, attrs))
  end

  defp insert_check(organization, version, attrs) do
    attrs =
      Map.merge(
        %{
          run_type: "mobility_data",
          status: "completed",
          errors_count: 0,
          warnings_count: 0,
          infos_count: 0,
          started_at: ~U[2026-09-25 09:00:00.000000Z]
        },
        Map.new(attrs)
      )

    %ValidationRun{
      id: Ecto.UUID.generate(),
      organization_id: organization.id,
      gtfs_version_id: version.id
    }
    |> ValidationRun.changeset(attrs)
    |> Repo.insert!()
  end

  defp last_service_date(date) do
    if Date.day_of_week(date) == 7, do: Date.add(date, -1), else: date
  end

  defp stamp(date), do: Calendar.strftime(date, "%Y%m%d")
end
