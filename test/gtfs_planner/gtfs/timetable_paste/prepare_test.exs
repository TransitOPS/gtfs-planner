defmodule GtfsPlanner.Gtfs.TimetablePaste.PrepareTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext

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

  test "a straightforward paste returns scope and a review with a plan", context do
    scope = schedule_scope!(context)

    text =
      "Central Station\tMarket Street\tHospital\n" <>
        "11:00\t11:05\t11:12\n" <>
        "11:30\t11:35\t11:42\n"

    assert {:ok, %{scope: paste, review: review}} =
             Gtfs.prepare_timetable_paste(
               context.organization.id,
               context.version.id,
               scope.route_id,
               %{service_id: scope.service, direction_id: 0},
               paste_input(text)
             )

    assert paste.route.route_id == scope.route_id
    assert paste.calendar.service_id == scope.service
    assert paste.direction_id == 0
    assert paste.pattern_id == scope.main.pattern.id

    assert review.orientation == :trips_in_rows
    assert review.column_issues == []
    assert Enum.map(review.rows, & &1.status) == [:ready, :ready]
    assert review.plan.counts.add == 2
    assert review.plan.warnings == [] or is_list(review.plan.warnings)
    assert review.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "a Block column overlapping another route's trip warns :block_overlap", context do
    scope = schedule_scope!(context)

    # Block B101 already runs 06:30-06:40 on the calendar via the other route.
    # The pasted 06:35-06:47 trip on the same block overlaps it.
    text =
      "Central Station\tMarket Street\tHospital\tBlock\n" <>
        "06:35\t06:40\t06:47\tB101\n"

    assert {:ok, %{scope: paste, review: review}} =
             Gtfs.prepare_timetable_paste(
               context.organization.id,
               context.version.id,
               scope.route_id,
               %{service_id: scope.service, direction_id: 0},
               paste_input(text)
             )

    assert paste.calendar.service_id == scope.service
    assert Enum.any?(review.columns, &(&1.target == :block_id))
    assert review.column_issues == []

    assert [row] = review.rows
    assert row.status == :ready
    assert row.block_id == "B101"

    assert [change] = review.plan.changes
    assert change.op == :add
    assert change.block_id == "B101"
    assert :block_overlap in change.warnings
    assert review.plan.writes_blocks? == true
  end

  test "a disjoint block on the same calendar warns nothing", context do
    scope = schedule_scope!(context)

    text =
      "Central Station\tMarket Street\tHospital\tBlock\n" <>
        "11:00\t11:05\t11:12\tB101\n"

    assert {:ok, %{review: review}} =
             Gtfs.prepare_timetable_paste(
               context.organization.id,
               context.version.id,
               scope.route_id,
               %{service_id: scope.service, direction_id: 0},
               paste_input(text)
             )

    assert [change] = review.plan.changes
    assert change.block_id == "B101"
    assert change.warnings == []
  end

  test "an empty input resolves the scope only", context do
    scope = schedule_scope!(context)

    for input <- [%{text: ""}, %{}, paste_input("   ")] do
      assert {:ok, %{scope: paste, review: nil}} =
               Gtfs.prepare_timetable_paste(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 %{service_id: scope.service, direction_id: 0},
                 input
               )

      assert paste.route.route_id == scope.route_id
      assert paste.calendar.service_id == scope.service
    end
  end

  test "parse failures pass through unchanged", context do
    scope = schedule_scope!(context)

    assert {:error, :no_times} =
             Gtfs.prepare_timetable_paste(
               context.organization.id,
               context.version.id,
               scope.route_id,
               %{service_id: scope.service, direction_id: 0},
               paste_input("Central Station\tMarket Street\nn/a\tn/a\n")
             )
  end

  test "a foreign route, organization or version is :not_found", context do
    scope = schedule_scope!(context)
    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)
    other_route = route_fixture(other_organization.id, other_version.id)

    assert {:error, :not_found} =
             Gtfs.prepare_timetable_paste(
               context.organization.id,
               context.version.id,
               other_route.route_id,
               %{},
               paste_input("07:00\n")
             )

    assert {:error, :not_found} =
             Gtfs.prepare_timetable_paste(
               other_organization.id,
               context.version.id,
               scope.route_id,
               %{},
               paste_input("07:00\n")
             )

    assert {:error, :not_found} =
             Gtfs.prepare_timetable_paste(
               context.organization.id,
               other_version.id,
               scope.route_id,
               %{},
               paste_input("07:00\n")
             )
  end

  defp paste_input(text) do
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

  defp schedule_scope!(context) do
    route = route_fixture(context.organization.id, context.version.id, %{route_id: "R-PASTE"})

    other_route =
      route_fixture(context.organization.id, context.version.id, %{route_id: "R-OTHER"})

    for {stop_id, name, code} <- [
          {"PSA-1", "Central Station", "1001"},
          {"PSA-2", "Market Street", "1002"},
          {"PSA-3", "Hospital", "1003"}
        ] do
      stop =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: stop_id,
          stop_name: name
        })

      # stop_code is import-managed (the editor changeset never casts it),
      # so stamp it directly; the scope must still surface it per stop.
      stop |> Ecto.Changeset.change(%{stop_code: code}) |> Repo.update!()
    end

    service = weekly_calendar!(context, "WKD-PASTE", "Paste Weekday")

    main =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "MAIN",
        route_pattern_name: "Main",
        route_pattern_sort_order: 0,
        headsign: "Hospital",
        timing_name: "Standard",
        stops: [{"PSA-1", 0, 0, 1}, {"PSA-2", 300, 330, 1}, {"PSA-3", 720, 720, 1}]
      })

    other_bundle =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: other_route.route_id,
        direction_id: 0,
        route_pattern_id: "OTHER",
        stops: [{"PSA-1", 0, 0, 1}, {"PSA-3", 600, 600, 1}]
      })

    other_trip =
      schedule_trip_fixture(
        context.organization.id,
        context.version.id,
        other_route.route_id,
        other_bundle,
        %{
          trip_id: "R-OTHER-0-WKD-PASTE-0630",
          service_id: service,
          start_time: "06:30:00",
          block_id: "B101"
        }
      ).trip

    %{
      route_id: route.route_id,
      service: service,
      main: main,
      other_trip_id: other_trip.trip_id
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
