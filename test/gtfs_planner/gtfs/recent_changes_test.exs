defmodule GtfsPlanner.Gtfs.RecentChangesTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RecentChanges
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    actor = user_fixture()

    %{
      organization: organization,
      gtfs_version: gtfs_version,
      actor: actor,
      zone: Gtfs.resolve_display_zone(organization.id, gtfs_version.id)
    }
  end

  test "a 500-row operation is one group and four older edits still appear", context do
    operation_id = Ecto.UUID.generate()

    bulk =
      for index <- 1..500 do
        %{
          entity_external_id: "TRIP-#{index}",
          actor_id: context.actor.id,
          actor_email: context.actor.email,
          changed_fields: trip_changed_fields("R1", "weekday", operation_id),
          inserted_at: ~U[2026-09-20 12:00:00.000000Z]
        }
      end

    older = [
      %{
        entity_type: "calendar",
        entity_external_id: "WEEKDAY",
        changed_fields: %{"before" => nil, "after" => %{"service_id" => "WEEKDAY"}},
        inserted_at: ~U[2026-09-19 12:00:00.000000Z]
      },
      %{
        entity_type: "route_pattern",
        entity_external_id: "RP-1",
        snapshot: %{"route_id" => "R2", "route_pattern_id" => "RP-1"},
        inserted_at: ~U[2026-09-18 12:00:00.000000Z]
      },
      %{
        entity_type: "stop",
        entity_external_id: "STOP-1",
        station_stop_id: "STA",
        snapshot: %{"level_id" => "L1"},
        inserted_at: ~U[2026-09-17 12:00:00.000000Z]
      },
      %{
        entity_type: "transfer",
        entity_external_id: "TRANSFER-1",
        inserted_at: ~U[2026-09-16 12:00:00.000000Z]
      }
    ]

    insert_logs(context.organization, context.gtfs_version, bulk ++ older)

    groups =
      RecentChanges.recent(
        context.organization.id,
        context.gtfs_version.id,
        :everyone,
        context.zone
      )

    assert length(groups) == 5

    assert [
             schedules,
             calendar,
             route_pattern,
             station,
             transfers
           ] = groups

    assert schedules.destination == {:schedules, "R1", "weekday"}
    assert length(schedules.operations) == 1
    assert length(hd(schedules.operations)) == 500
    assert schedules.actor_email == context.actor.email
    assert schedules.same_day_count == 1
    assert schedules.newest_at == ~U[2026-09-20 12:00:00.000000Z]

    assert calendar.destination == {:calendar, "WEEKDAY"}
    assert route_pattern.destination == {:route_pattern, nil, "RP-1"}
    assert station.destination == {:station, "STA", "L1"}
    assert transfers.destination == :transfers
  end

  test "a calendar combination with trip rows on two routes is one calendar group", context do
    operation_id = Ecto.UUID.generate()
    at = ~U[2026-09-21 12:00:00.000000Z]

    insert_logs(context.organization, context.gtfs_version, [
      %{
        entity_type: "calendar",
        entity_external_id: "COMBINED",
        actor_id: context.actor.id,
        actor_email: context.actor.email,
        changed_fields: %{
          "before" => nil,
          "after" => %{"service_id" => "COMBINED"},
          "operation_id" => operation_id
        },
        inserted_at: at
      },
      %{
        entity_external_id: "TRIP-R1",
        actor_id: context.actor.id,
        actor_email: context.actor.email,
        changed_fields: trip_changed_fields("R1", "COMBINED", operation_id),
        inserted_at: at
      },
      %{
        entity_external_id: "TRIP-R2",
        actor_id: context.actor.id,
        actor_email: context.actor.email,
        changed_fields: trip_changed_fields("R2", "COMBINED", operation_id),
        inserted_at: at
      }
    ])

    assert [group] =
             RecentChanges.recent(
               context.organization.id,
               context.gtfs_version.id,
               :everyone,
               context.zone
             )

    assert group.destination == {:calendar, "COMBINED"}
    assert length(group.operations) == 1
    assert length(hd(group.operations)) == 3
  end

  test "a trip-only calendar combination is one calendar group, not one route's schedules",
       context do
    operation_id = Ecto.UUID.generate()
    at = ~U[2026-09-21 12:00:00.000000Z]

    # A combination that leaves the destination's dates unchanged writes no
    # calendar row; its envelope rides on one of the moved trips' rows.
    envelope = %{
      "destination_id" => "WKND",
      "selected_service_ids" => ["SAT", "WKND"],
      "changed_trip_ids" => [],
      "decisions" => %{}
    }

    insert_logs(context.organization, context.gtfs_version, [
      %{
        entity_external_id: "TRIP-R1",
        changed_fields:
          "R1"
          |> trip_changed_fields("WKND", operation_id)
          |> Map.put("combination", envelope),
        inserted_at: at
      },
      %{
        entity_external_id: "TRIP-R2",
        changed_fields: trip_changed_fields("R2", "WKND", operation_id),
        inserted_at: at
      }
    ])

    assert [group] =
             RecentChanges.recent(
               context.organization.id,
               context.gtfs_version.id,
               :everyone,
               context.zone
             )

    assert group.destination == {:calendar, "WKND"}
    assert length(hd(group.operations)) == 2
  end

  test "one alignment save of several sections is one group and older edits still appear",
       context do
    at = ~U[2026-09-21 12:00:00.000000Z]

    # An alignment save writes one row per changed section, without an
    # operation id.
    sections =
      for index <- 1..6 do
        %{
          entity_type: "alignment_segment",
          entity_external_id: "A#{index}>B#{index}",
          inserted_at: at
        }
      end

    transfer = %{
      entity_type: "transfer",
      entity_external_id: "TRANSFER-1",
      inserted_at: ~U[2026-09-20 12:00:00.000000Z]
    }

    insert_logs(context.organization, context.gtfs_version, sections ++ [transfer])

    groups =
      RecentChanges.recent(
        context.organization.id,
        context.gtfs_version.id,
        :everyone,
        context.zone
      )

    assert Enum.map(groups, & &1.destination) == [:alignment, :transfers]
  end

  test "a pattern edit and a shape redraw on one pattern are one group", context do
    insert_logs(context.organization, context.gtfs_version, [
      %{
        entity_type: "pattern_shape",
        entity_external_id: "RP-1",
        snapshot: %{"route_pattern_id" => "RP-1", "shape_id" => "SH-1"},
        inserted_at: ~U[2026-09-21 12:00:00.000000Z]
      },
      %{
        entity_type: "route_pattern",
        entity_external_id: "RP-1",
        snapshot: %{"route_id" => "R1", "route_pattern_id" => "RP-1"},
        inserted_at: ~U[2026-09-20 12:00:00.000000Z]
      }
    ])

    assert [group] =
             RecentChanges.recent(
               context.organization.id,
               context.gtfs_version.id,
               :everyone,
               context.zone
             )

    assert group.destination == {:route_pattern, nil, "RP-1"}
    assert length(group.operations) == 2
  end

  test "a timing edit keys its pattern by the GTFS ID in its external ID, whatever its snapshot holds",
       context do
    timing_id = Ecto.UUID.generate()

    insert_logs(context.organization, context.gtfs_version, [
      %{
        entity_type: "timed_pattern",
        entity_external_id: "#{timing_id}:RP:1",
        # An entry written before the conversion kept the pattern's row id here.
        snapshot: %{"route_pattern_id" => Ecto.UUID.generate()},
        inserted_at: ~U[2026-09-20 12:00:00.000000Z]
      },
      %{
        entity_type: "timed_pattern",
        entity_external_id: "#{timing_id}:RP:1",
        snapshot: %{"route_pattern_id" => "RP:1"},
        inserted_at: ~U[2026-09-21 12:00:00.000000Z]
      }
    ])

    assert [group] =
             RecentChanges.recent(
               context.organization.id,
               context.gtfs_version.id,
               :everyone,
               context.zone
             )

    assert group.destination == {:timed_pattern, "RP:1"}
    assert length(group.operations) == 2
  end

  test "a stop edit keys its station and GTFS level; a pathway keys its station with no level",
       context do
    insert_logs(context.organization, context.gtfs_version, [
      %{
        entity_type: "stop",
        entity_external_id: "STOP-1",
        station_stop_id: "STA",
        snapshot: %{"level_id" => "L2"},
        inserted_at: ~U[2026-09-20 12:00:00.000000Z]
      },
      %{
        entity_type: "pathway",
        entity_external_id: "PATH-1",
        station_stop_id: "STA",
        snapshot: %{"from_stop_id" => "STOP-1", "to_stop_id" => "STOP-2"},
        inserted_at: ~U[2026-09-19 12:00:00.000000Z]
      }
    ])

    assert [
             %{destination: {:station, "STA", "L2"}},
             %{destination: {:station, "STA", nil}}
           ] =
             RecentChanges.recent(
               context.organization.id,
               context.gtfs_version.id,
               :everyone,
               context.zone
             )
  end

  test "two operations on one destination the same local day count two changes that day",
       context do
    insert_logs(context.organization, context.gtfs_version, [
      %{
        entity_external_id: "TRIP-1",
        changed_fields: trip_changed_fields("R1", "weekday", Ecto.UUID.generate()),
        inserted_at: ~U[2026-09-20 15:00:00.000000Z]
      },
      %{
        entity_external_id: "TRIP-2",
        changed_fields: trip_changed_fields("R1", "weekday", Ecto.UUID.generate()),
        inserted_at: ~U[2026-09-20 09:00:00.000000Z]
      }
    ])

    assert [group] =
             RecentChanges.recent(
               context.organization.id,
               context.gtfs_version.id,
               :everyone,
               context.zone
             )

    assert group.destination == {:schedules, "R1", "weekday"}
    assert group.same_day_count == 2
    assert length(group.operations) == 2
    assert group.newest_at == ~U[2026-09-20 15:00:00.000000Z]
  end

  test "recent_for_user returns the team scope with everyone's groups when the actor has none",
       context do
    teammate = user_fixture()

    insert_logs(context.organization, context.gtfs_version, [
      %{
        entity_external_id: "TRIP-1",
        actor_id: teammate.id,
        actor_email: teammate.email,
        changed_fields: trip_changed_fields("R1", "weekday"),
        inserted_at: ~U[2026-09-20 12:00:00.000000Z]
      }
    ])

    assert %{scope: :team, groups: [group]} =
             Gtfs.recent_changes_for_user(
               context.organization.id,
               context.gtfs_version.id,
               context.actor.id,
               context.zone
             )

    assert group.destination == {:schedules, "R1", "weekday"}
    assert group.actor_email == teammate.email
  end

  test "recent_for_user returns only the actor's own groups when the actor has rows", context do
    teammate = user_fixture()

    insert_logs(context.organization, context.gtfs_version, [
      %{
        entity_external_id: "TRIP-TEAMMATE",
        actor_id: teammate.id,
        actor_email: teammate.email,
        changed_fields: trip_changed_fields("R9", "weekday"),
        inserted_at: ~U[2026-09-21 12:00:00.000000Z]
      },
      %{
        entity_external_id: "TRIP-MINE",
        actor_id: context.actor.id,
        actor_email: context.actor.email,
        changed_fields: trip_changed_fields("R1", "weekday"),
        inserted_at: ~U[2026-09-20 12:00:00.000000Z]
      }
    ])

    assert %{scope: :own, groups: [group]} =
             RecentChanges.recent_for_user(
               context.organization.id,
               context.gtfs_version.id,
               context.actor.id,
               context.zone
             )

    assert group.destination == {:schedules, "R1", "weekday"}
    assert group.actor_email == context.actor.email
  end

  test "rows from another organization or another version never appear", context do
    insert_logs(context.organization, context.gtfs_version, [
      %{
        entity_external_id: "TRIP-MINE",
        changed_fields: trip_changed_fields("R1", "weekday"),
        inserted_at: ~U[2026-09-20 12:00:00.000000Z]
      }
    ])

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)

    insert_logs(other_organization, other_version, [
      %{
        entity_external_id: "TRIP-THEIRS",
        changed_fields: trip_changed_fields("R9", "weekday"),
        inserted_at: ~U[2026-09-22 12:00:00.000000Z]
      }
    ])

    sibling_version = gtfs_version_fixture(context.organization.id)

    insert_logs(context.organization, sibling_version, [
      %{
        entity_external_id: "TRIP-SIBLING",
        changed_fields: trip_changed_fields("R8", "weekday"),
        inserted_at: ~U[2026-09-23 12:00:00.000000Z]
      }
    ])

    assert [group] =
             RecentChanges.recent(
               context.organization.id,
               context.gtfs_version.id,
               :everyone,
               context.zone
             )

    assert group.destination == {:schedules, "R1", "weekday"}
  end

  test "count_since counts distinct operations and distinct stations after the time", context do
    export_time = ~U[2026-09-20 12:00:00.000000Z]
    operation_id = Ecto.UUID.generate()

    operation_rows =
      for index <- 1..6 do
        %{
          entity_external_id: "TRIP-#{index}",
          changed_fields: trip_changed_fields("R1", "weekday", operation_id),
          inserted_at: ~U[2026-09-20 13:00:00.000000Z]
        }
      end

    station_rows = [
      %{
        entity_type: "pathway",
        entity_external_id: "PATH-1",
        station_stop_id: "STA",
        inserted_at: ~U[2026-09-20 14:00:00.000000Z]
      },
      %{
        entity_type: "pathway",
        entity_external_id: "PATH-2",
        station_stop_id: "STB",
        inserted_at: ~U[2026-09-20 15:00:00.000000Z]
      }
    ]

    before_export = %{
      entity_external_id: "TRIP-OLD",
      changed_fields: trip_changed_fields("R2", "weekday"),
      inserted_at: ~U[2026-09-20 11:00:00.000000Z]
    }

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)

    insert_logs(other_organization, other_version, [
      %{
        entity_external_id: "TRIP-FOREIGN",
        changed_fields: trip_changed_fields("R7", "weekday"),
        inserted_at: ~U[2026-09-20 16:00:00.000000Z]
      }
    ])

    insert_logs(
      context.organization,
      context.gtfs_version,
      operation_rows ++ station_rows ++ [before_export]
    )

    assert Gtfs.count_changes_since(
             context.organization.id,
             context.gtfs_version.id,
             export_time
           ) == %{changes: 3, stations: 2}
  end

  defp trip_changed_fields(route_id, service_id, operation_id \\ nil) do
    %{
      "before" => nil,
      "after" => %{"route_id" => route_id, "service_id" => service_id}
    }
    |> put_operation(operation_id)
  end

  defp put_operation(fields, nil), do: fields
  defp put_operation(fields, operation_id), do: Map.put(fields, "operation_id", operation_id)

  defp insert_logs(organization, gtfs_version, rows) do
    rows
    |> Enum.map(fn row ->
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          entity_type: "trip",
          entity_id: Ecto.UUID.generate(),
          entity_external_id: Ecto.UUID.generate(),
          station_stop_id: nil,
          actor_id: Ecto.UUID.generate(),
          actor_email: "teammate@example.test",
          snapshot: nil,
          changed_fields: nil,
          action: "updated",
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          inserted_at: ~U[2026-09-01 12:00:00.000000Z]
        },
        Map.new(row)
      )
    end)
    |> then(&Repo.insert_all(ChangeLog, &1))
  end
end
