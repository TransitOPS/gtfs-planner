defmodule GtfsPlanner.Gtfs.RecentChanges.DescribeTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RecentChanges.Describe
  alias GtfsPlanner.Gtfs.Route

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{
      organization: organization,
      gtfs_version: gtfs_version,
      zone: Gtfs.resolve_display_zone(organization.id, gtfs_version.id)
    }
  end

  test "a schedule group is titled by the route name and counts trips on the calendar", context do
    route_fixture(context.organization.id, context.gtfs_version.id, %{
      route_id: "12",
      route_short_name: "12",
      route_long_name: "Downtown – Riverside",
      route_color: "0B6BCB",
      route_text_color: "FFFFFF"
    })

    calendar_fixture(context.organization.id, context.gtfs_version.id, %{service_id: "WKDY"})

    calendar_attribute_fixture(context.organization.id, context.gtfs_version.id, %{
      service_id: "WKDY",
      service_description: "Weekday",
      service_schedule_name: "Schedule label"
    })

    operation_id = Ecto.UUID.generate()
    rows = for index <- 1..6, do: trip_log(operation_id, index)

    assert [item] =
             describe_groups(context, [
               group({:schedules, "12", "WKDY"}, [rows])
             ])

    assert item.kind == :schedules
    assert item.title == "Downtown – Riverside"
    assert item.detail == "6 trips changed on Weekday"
    assert item.context == "Schedules · Sep 20, 2026, 12:00 PM"

    assert item.route == %{
             route_id: "12",
             route_short_name: "12",
             route_color: "0B6BCB",
             route_text_color: "FFFFFF"
           }

    assert item.params == %{route_id: "12", service_id: "WKDY"}
    assert item.actor_email == "editor@example.test"
    assert item.local_at == ~N[2026-09-20 12:00:00.000000]
    assert item.same_day_count == 1
  end

  test "a whitespace-only long name leaves the short name as the title", context do
    # Import keeps raw column bytes, so a whitespace-only long name is stored
    # as given; the route changeset would have trimmed it to nil.
    Repo.insert!(%Route{
      organization_id: context.organization.id,
      gtfs_version_id: context.gtfs_version.id,
      route_id: "12",
      route_short_name: "12",
      route_long_name: "  ",
      route_type: 3
    })

    calendar_fixture(context.organization.id, context.gtfs_version.id, %{service_id: "WKDY"})

    calendar_attribute_fixture(context.organization.id, context.gtfs_version.id, %{
      service_id: "WKDY",
      service_description: "Weekday"
    })

    operation_id = Ecto.UUID.generate()
    rows = for index <- 1..2, do: trip_log(operation_id, index)

    assert [item] = describe_groups(context, [group({:schedules, "12", "WKDY"}, [rows])])

    assert item.title == "12"
  end

  test "a calendar end-date change reads the moved date", context do
    create_calendar(context, "CAL_END", "Seasonal")

    row =
      log(%{
        entity_type: "calendar",
        entity_external_id: "CAL_END",
        action: "updated",
        changed_fields: %{
          "before" => calendar_snapshot("2026-06-30"),
          "after" => calendar_snapshot("2026-12-31")
        }
      })

    assert [item] = describe_groups(context, [group({:calendar, "CAL_END"}, [[row]])])

    assert item.kind == :calendar
    assert item.title == "Seasonal"
    assert item.detail == "end date moved to Dec 31"
    assert item.params == %{service_id: "CAL_END"}
  end

  test "a trip-only combination reads as combined and links a calendar without an anchor",
       context do
    # An imported calendar gets its attribute anchor only on its first edit, and
    # a combination that leaves the destination's dates unchanged never edits it.
    calendar_fixture(context.organization.id, context.gtfs_version.id, %{service_id: "WKND"})

    operation_id = Ecto.UUID.generate()
    plain = trip_log(operation_id, 1)

    envelope =
      trip_log(operation_id, 2)
      |> Map.update!(:changed_fields, fn fields ->
        Map.put(fields, "combination", %{
          "destination_id" => "WKND",
          "selected_service_ids" => ["SAT", "WKND"]
        })
      end)

    assert [item] =
             describe_groups(context, [group({:calendar, "WKND"}, [[plain, envelope]])])

    assert item.kind == :calendar
    assert item.title == "WKND"
    assert item.detail == "combined with 1 calendar"
    assert item.params == %{service_id: "WKND"}
  end

  test "a single trip edit reads in the singular", context do
    create_calendar(context, "WKDY", "Weekday")
    route_fixture(context.organization.id, context.gtfs_version.id, %{route_id: "12"})

    assert [item] =
             describe_groups(context, [
               group({:schedules, "12", "WKDY"}, [[trip_log(Ecto.UUID.generate(), 1)]])
             ])

    assert item.detail == "1 trip changed on Weekday"
  end

  test "a station group keys the GTFS level and names it in the context", context do
    stop_fixture(context.organization.id, context.gtfs_version.id, %{
      stop_id: "STA",
      stop_name: "Union Station",
      location_type: 1
    })

    level_fixture(context.organization.id, context.gtfs_version.id, %{
      level_id: "L2",
      level_name: "Concourse"
    })

    row =
      log(%{
        entity_type: "stop",
        entity_external_id: "STA",
        station_stop_id: "STA",
        action: "updated",
        snapshot: %{"level_id" => "L2"},
        changed_fields: %{"stop_lat" => %{"from" => "40.1", "to" => "40.2"}}
      })

    assert [item] = describe_groups(context, [group({:station, "STA", "L2"}, [[row]])])

    assert item.kind == :station
    assert item.title == "Union Station"
    assert item.detail == "location moved"
    assert item.params == %{stop_id: "STA", level_id: "L2"}
    assert item.context =~ "Station"
    assert item.context =~ "Concourse"
  end

  test "a group whose route no longer exists keeps its text without a link", context do
    create_calendar(context, "WKDY", "Weekday")

    operation_id = Ecto.UUID.generate()
    rows = for index <- 1..6, do: trip_log(operation_id, index, "GONE")

    assert [item] = describe_groups(context, [group({:schedules, "GONE", "WKDY"}, [rows])])

    assert item.kind == :none
    assert item.title == "GONE"
    assert item.detail == "6 trips changed on Weekday"
    assert item.params == %{}
    assert item.route == nil
    assert item.context =~ "Schedules"
  end

  test "a timed pattern group resolves to its route pattern", context do
    route =
      route_fixture(context.organization.id, context.gtfs_version.id, %{
        route_id: "R7",
        route_short_name: "7",
        route_long_name: "Harbor Loop"
      })

    pattern =
      route_pattern_fixture(context.organization.id, context.gtfs_version.id, %{
        route_id: route.route_id,
        route_pattern_id: "RP-7"
      })

    timing = timed_pattern_fixture(pattern)

    row =
      log(%{
        entity_type: "timed_pattern",
        entity_external_id: "#{timing.id}:RP-7",
        action: "updated",
        snapshot: %{"route_pattern_id" => "RP-7", "name" => timing.name}
      })

    assert [item] =
             describe_groups(context, [group({:timed_pattern, pattern.route_pattern_id}, [[row]])])

    assert item.kind == :route_pattern
    assert item.title == "Harbor Loop"
    assert item.detail == "pattern changed"
    assert item.params == %{route_id: "R7", route_pattern_id: "RP-7"}
    assert item.route.route_id == "R7"
  end

  test "an alignment group is unlinked and says the shape was redrawn", context do
    row =
      log(%{
        entity_type: "alignment_segment",
        entity_external_id: "STA>STB",
        action: "updated"
      })

    assert [item] = describe_groups(context, [group(:alignment, [[row]])])

    assert item.kind == :none
    assert item.detail == "shape redrawn"
    assert item.params == %{}
  end

  test "stop, route-pattern build and transfer groups carry their own kinds and params",
       context do
    stop_fixture(context.organization.id, context.gtfs_version.id, %{
      stop_id: "S9",
      stop_name: "Pier 9"
    })

    route_fixture(context.organization.id, context.gtfs_version.id, %{
      route_id: "R3",
      route_short_name: "3",
      route_long_name: "Airport Express"
    })

    stop_row =
      log(%{
        entity_type: "stop",
        entity_external_id: "S9",
        action: "updated",
        changed_fields: %{"stop_name" => %{"from" => "Pier Nine", "to" => "Pier 9"}}
      })

    build_row =
      log(%{
        entity_type: "route_pattern_build",
        entity_external_id: "R3",
        action: "updated",
        changed_fields: %{"patterns_created" => 2}
      })

    transfer_row =
      log(%{
        entity_type: "transfer",
        entity_external_id: "TRANSFER-1",
        action: "deleted"
      })

    assert [stop_item, build_item, transfer_item] =
             describe_groups(context, [
               group({:stop, "S9"}, [[stop_row]]),
               group({:route_patterns, "R3"}, [[build_row]]),
               group(:transfers, [[transfer_row]])
             ])

    assert stop_item.kind == :stop
    assert stop_item.title == "Pier 9"
    assert stop_item.detail == "renamed"
    assert stop_item.params == %{stop_id: "S9"}

    assert build_item.kind == :route_patterns
    assert build_item.title == "Airport Express"
    assert build_item.detail == "patterns built"
    assert build_item.params == %{route_id: "R3"}

    assert transfer_item.kind == :transfers
    assert transfer_item.detail == "transfer rule removed"
    assert transfer_item.params == %{}
  end

  defp describe_groups(context, groups) do
    Describe.describe(context.organization.id, context.gtfs_version.id, groups, context.zone)
  end

  defp create_calendar(context, service_id, description) do
    calendar_fixture(context.organization.id, context.gtfs_version.id, %{service_id: service_id})

    calendar_attribute_fixture(context.organization.id, context.gtfs_version.id, %{
      service_id: service_id,
      service_description: description
    })
  end

  defp group(destination, operations, attrs \\ %{}) do
    Map.merge(
      %{
        destination: destination,
        operations: operations,
        newest_at: ~U[2026-09-20 12:00:00.000000Z],
        actor_email: "editor@example.test",
        same_day_count: 1
      },
      attrs
    )
  end

  defp trip_log(operation_id, index, route_id \\ "12") do
    log(%{
      entity_type: "trip",
      entity_external_id: "TRIP-#{index}",
      action: "updated",
      changed_fields: %{
        "before" => nil,
        "after" => %{"route_id" => route_id, "service_id" => "WKDY"},
        "operation_id" => operation_id
      }
    })
  end

  defp calendar_snapshot(end_date) do
    %{
      "service_id" => "CAL_END",
      "weekly" => %{
        "monday" => 1,
        "tuesday" => 1,
        "wednesday" => 1,
        "thursday" => 1,
        "friday" => 1,
        "saturday" => 0,
        "sunday" => 0,
        "start_date" => "2026-01-01",
        "end_date" => end_date
      },
      "dates" => []
    }
  end

  defp log(attrs) do
    struct!(
      ChangeLog,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          entity_type: "trip",
          entity_id: Ecto.UUID.generate(),
          entity_external_id: Ecto.UUID.generate(),
          station_stop_id: nil,
          actor_id: Ecto.UUID.generate(),
          actor_email: "editor@example.test",
          snapshot: nil,
          changed_fields: nil,
          action: "updated",
          inserted_at: ~U[2026-09-20 12:00:00.000000Z]
        },
        Map.new(attrs)
      )
    )
  end
end
