defmodule GtfsPlanner.Gtfs.StationBoardStatusTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StationBoard
  alias GtfsPlanner.Gtfs.StationReport2.Outcome
  alias GtfsPlanner.Validations.ValidationRun

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    level = level_fixture(organization.id, gtfs_version.id, %{level_id: "L1"})

    %{organization: organization, gtfs_version: gtfs_version, level: level}
  end

  test "matches the station report's own issue count per station", ctx do
    _clean = clean_station(ctx, "CLEAN", "Clean")
    _failing = failing_station(ctx, "FAIL", "Fail")
    _node = node_station(ctx, "NODE", "Node")

    statuses = statuses(ctx)

    assert Map.keys(statuses) |> Enum.sort() == ["CLEAN", "FAIL", "NODE"]

    for station_stop_id <- ["CLEAN", "FAIL", "NODE"] do
      assert {:ok, snapshot} =
               Gtfs.get_station_report_snapshot(
                 ctx.organization.id,
                 ctx.gtfs_version.id,
                 station_stop_id
               )

      assert statuses[station_stop_id].issues ==
               Outcome.counts(Outcome.report_items(snapshot)).failed,
             "#{station_stop_id} disagrees with its station report snapshot"
    end

    # The fixtures are load bearing: the clean station reports no failures, the
    # failing station reports its isolated second entrance, and the node station
    # reports two failures if its type-3 node under the platform counts as a
    # child stop.
    assert statuses["CLEAN"].issues == 0
    assert statuses["FAIL"].issues > 0
    assert statuses["NODE"].issues == 0
  end

  test "marks reachability stale when the station changed after the run", ctx do
    _stale = clean_station(ctx, "STA", "Sta")
    _fresh = clean_station(ctx, "STB", "Stb")

    insert_run(ctx, "STA", %{
      completed_at: ~U[2026-09-01 09:00:05.000000Z],
      outcome: "passed",
      reachable: 3,
      pair_count: 4
    })

    insert_run(ctx, "STB", %{
      completed_at: ~U[2026-09-05 09:00:05.000000Z],
      outcome: "warning",
      reachable: 2,
      pair_count: 4
    })

    insert_change_logs(ctx, [
      %{
        station_stop_id: "STA",
        actor_email: "after-run@example.test",
        inserted_at: ~U[2026-09-03 12:00:00.000000Z]
      },
      %{
        station_stop_id: "STB",
        actor_email: "before-run@example.test",
        inserted_at: ~U[2026-09-04 12:00:00.000000Z]
      }
    ])

    statuses = statuses(ctx)

    assert %{stale?: true, outcome: :passed, reachable: 3, pair_count: 4} =
             statuses["STA"].reachability

    assert %{stale?: false, outcome: :warning} = statuses["STB"].reachability
  end

  test "reports zero issues without pathways and no reachability without a run", ctx do
    _computed = clean_station(ctx, "STA", "Sta")
    _untouched = station_fixture(ctx, "STB", "Stb Station")

    statuses = statuses(ctx)

    # STA has pathways and a clean report but no run; STB has no pathways, so the
    # board reports 0 issues without calling the report builders even though the
    # report path on its own would flag its missing children.
    assert statuses["STA"] == %{issues: 0, reachability: nil}
    assert statuses["STB"] == %{issues: 0, reachability: nil}
  end

  defp statuses(ctx) do
    StationBoard.statuses(
      ctx.organization.id,
      ctx.gtfs_version.id,
      StationBoard.base(ctx.organization.id, ctx.gtfs_version.id)
    )
  end

  defp clean_station(ctx, stop_id, name) do
    {station, _platform} = station_with_connected_entrance(ctx, stop_id, name)
    station
  end

  defp failing_station(ctx, stop_id, name) do
    {station, _platform} = station_with_connected_entrance(ctx, stop_id, name)

    _isolated =
      child_stop(ctx, "#{stop_id}_entrance_2", station.stop_id, 2, "#{name} Side Entrance")

    station
  end

  defp node_station(ctx, stop_id, name) do
    {station, platform} = station_with_connected_entrance(ctx, stop_id, name)

    # A generic node under the platform is not one of the station's child stops,
    # so its isolated-node failure must not reach the station's count.
    _node = child_stop(ctx, "node_1", platform.stop_id, 3, "#{name} Access")

    station
  end

  defp station_with_connected_entrance(ctx, stop_id, name) do
    station = station_fixture(ctx, stop_id, "#{name} Station")
    entrance = child_stop(ctx, "#{stop_id}_entrance_1", station.stop_id, 2, "#{name} Entrance")
    platform = child_stop(ctx, "#{stop_id}_platform_1", station.stop_id, 0, "#{name} Platform")

    pathway_fixture(
      ctx.organization.id,
      ctx.gtfs_version.id,
      entrance.stop_id,
      platform.stop_id,
      %{pathway_mode: 5}
    )

    {station, platform}
  end

  defp station_fixture(ctx, stop_id, stop_name, attrs \\ %{}) do
    stop_fixture(
      ctx.organization.id,
      ctx.gtfs_version.id,
      Map.merge(%{stop_id: stop_id, stop_name: stop_name, location_type: 1}, attrs)
    )
  end

  defp child_stop(ctx, stop_id, parent_station, location_type, stop_name) do
    stop_fixture(ctx.organization.id, ctx.gtfs_version.id, %{
      stop_id: stop_id,
      stop_name: stop_name,
      location_type: location_type,
      parent_station: parent_station,
      level_id: ctx.level.level_id
    })
  end

  defp insert_run(ctx, station_stop_id, attrs) do
    attrs =
      Map.merge(
        %{
          status: "completed",
          started_at: ~U[2026-09-01 09:00:00.000000Z],
          completed_at: ~U[2026-09-01 09:00:05.000000Z],
          inserted_at: ~U[2026-09-01 09:00:00.000000Z],
          error_details: nil,
          outcome: "passed",
          reachable: 2,
          pair_count: 4
        },
        attrs
      )

    %ValidationRun{organization_id: ctx.organization.id, gtfs_version_id: ctx.gtfs_version.id}
    |> ValidationRun.changeset(%{
      run_type: "station_reachability",
      status: attrs.status,
      started_at: attrs.started_at,
      completed_at: attrs.completed_at,
      error_details: attrs.error_details,
      result_json: %{
        "metadata" => %{"station_stop_id" => station_stop_id},
        "outcome" => attrs.outcome,
        "totals" => %{"reachable" => attrs.reachable, "pair_count" => attrs.pair_count}
      }
    })
    |> Ecto.Changeset.put_change(:inserted_at, attrs.inserted_at)
    |> Repo.insert!()
  end

  defp insert_change_logs(ctx, rows) do
    rows
    |> Enum.map(fn row ->
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          entity_type: "pathway",
          entity_id: Ecto.UUID.generate(),
          entity_external_id: Ecto.UUID.generate(),
          station_stop_id: nil,
          actor_id: Ecto.UUID.generate(),
          actor_email: "teammate@example.test",
          snapshot: nil,
          changed_fields: nil,
          action: "updated",
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.gtfs_version.id,
          inserted_at: ~U[2026-09-01 12:00:00.000000Z]
        },
        Map.new(row)
      )
    end)
    |> then(&Repo.insert_all(ChangeLog, &1))
  end
end
