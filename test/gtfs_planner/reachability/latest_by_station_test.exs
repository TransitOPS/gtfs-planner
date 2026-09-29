defmodule GtfsPlanner.Reachability.LatestByStationTest do
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Validations.ValidationRun

  @query_event [:gtfs_planner, :repo, :query]

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)

    %{organization: organization, gtfs_version: gtfs_version}
  end

  test "returns the newest completed run's outcome, reachability and totals", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    insert_run(organization, gtfs_version, %{
      inserted_at: ~U[2026-09-01 09:00:00.000000Z],
      completed_at: ~U[2026-09-01 09:00:05.000000Z],
      outcome: "failed",
      reachable: 1,
      pair_count: 4
    })

    newest =
      insert_run(organization, gtfs_version, %{
        inserted_at: ~U[2026-09-02 09:00:00.000000Z],
        completed_at: ~U[2026-09-02 09:00:05.000000Z],
        outcome: "passed",
        reachable: 3,
        pair_count: 4
      })

    assert %{"STA" => latest} =
             Reachability.latest_by_station(organization.id, gtfs_version.id, ["STA"])

    assert latest.run_id == newest.id
    assert latest.outcome == :passed
    assert latest.reachable == 3
    assert latest.pair_count == 4
    assert latest.completed_at == ~U[2026-09-02 09:00:05.000000Z]
  end

  test "ignores newer running and failed-status runs for the same station", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    completed =
      insert_run(organization, gtfs_version, %{
        inserted_at: ~U[2026-09-01 09:00:00.000000Z],
        outcome: "warning",
        reachable: 2,
        pair_count: 4
      })

    insert_run(organization, gtfs_version, %{
      status: "running",
      inserted_at: ~U[2026-09-02 09:00:00.000000Z],
      completed_at: nil
    })

    insert_run(organization, gtfs_version, %{
      status: "failed",
      inserted_at: ~U[2026-09-03 09:00:00.000000Z],
      error_details: "crashed"
    })

    assert %{"STA" => %{run_id: run_id, outcome: :warning}} =
             Reachability.latest_by_station(organization.id, gtfs_version.id, ["STA"])

    assert run_id == completed.id
  end

  test "ignores look-alike station keys in another organization or version", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    mine =
      insert_run(organization, gtfs_version, %{
        inserted_at: ~U[2026-09-01 09:00:00.000000Z],
        outcome: "passed"
      })

    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)

    insert_run(other_organization, other_version, %{
      inserted_at: ~U[2026-09-02 09:00:00.000000Z],
      outcome: "failed"
    })

    sibling_version = gtfs_version_fixture(organization.id)

    insert_run(organization, sibling_version, %{
      inserted_at: ~U[2026-09-03 09:00:00.000000Z],
      outcome: "failed"
    })

    assert %{"STA" => %{run_id: run_id}} =
             Reachability.latest_by_station(organization.id, gtfs_version.id, ["STA"])

    assert run_id == mine.id
  end

  test "omits a station whose newest completed result has an unknown outcome", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    insert_run(organization, gtfs_version, %{
      inserted_at: ~U[2026-09-01 09:00:00.000000Z],
      outcome: "surprising"
    })

    assert Reachability.latest_by_station(organization.id, gtfs_version.id, ["STA"]) == %{}
  end

  test "keys each result by its own station and omits stations without a completed run", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    sta =
      insert_run(organization, gtfs_version, %{
        station_stop_id: "STA",
        inserted_at: ~U[2026-09-01 09:00:00.000000Z],
        outcome: "passed",
        reachable: 3,
        pair_count: 4
      })

    stb =
      insert_run(organization, gtfs_version, %{
        station_stop_id: "STB",
        inserted_at: ~U[2026-09-02 09:00:00.000000Z],
        outcome: "not_applicable",
        reachable: 0,
        pair_count: 0
      })

    latest =
      Reachability.latest_by_station(organization.id, gtfs_version.id, [
        "STA",
        "STB",
        "MISSING"
      ])

    assert Map.keys(latest) |> Enum.sort() == ["STA", "STB"]
    assert latest["STA"].run_id == sta.id
    assert latest["STA"].outcome == :passed
    assert latest["STB"].run_id == stb.id
    assert latest["STB"].outcome == :not_applicable
  end

  test "returns %{} without querying when no stations are requested", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    result =
      refute_queries(organization, fn ->
        Reachability.latest_by_station(organization.id, gtfs_version.id, [])
      end)

    assert result == %{}
  end

  test "selects the newest run ids through the partial reachability station index", %{
    organization: organization,
    gtfs_version: gtfs_version
  } do
    params = [
      Ecto.UUID.dump!(organization.id),
      Ecto.UUID.dump!(gtfs_version.id),
      ["STA"]
    ]

    Repo.query!("SET LOCAL enable_seqscan = off")

    %{rows: rows} =
      Repo.query!("EXPLAIN " <> Reachability.latest_station_run_ids_sql(), params)

    plan = rows |> List.flatten() |> Enum.join("\n")

    assert plan =~ "gtfs_validation_runs_reachability_station_index"
  end

  defp insert_run(organization, gtfs_version, attrs) do
    attrs =
      Map.merge(
        %{
          station_stop_id: "STA",
          run_type: "station_reachability",
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

    %ValidationRun{organization_id: organization.id, gtfs_version_id: gtfs_version.id}
    |> ValidationRun.changeset(%{
      run_type: attrs.run_type,
      status: attrs.status,
      started_at: attrs.started_at,
      completed_at: attrs.completed_at,
      error_details: attrs.error_details,
      result_json: %{
        "metadata" => %{"station_stop_id" => attrs.station_stop_id},
        "outcome" => attrs.outcome,
        "totals" => %{"reachable" => attrs.reachable, "pair_count" => attrs.pair_count}
      }
    })
    |> Ecto.Changeset.put_change(:inserted_at, attrs.inserted_at)
    |> Repo.insert!()
  end

  # Ecto emits @query_event from the process issuing the query. Only events whose
  # params carry this test's organization id are reported, so tests running in
  # parallel cannot add messages to the mailbox checked below.
  defp refute_queries(organization, fun) do
    ref = make_ref()
    handler_id = "latest-by-station-#{System.unique_integer([:positive])}"
    test_pid = self()
    organization_dump = Ecto.UUID.dump!(organization.id)

    :telemetry.attach(
      handler_id,
      @query_event,
      fn _event, _measurements, metadata, _config ->
        if is_list(metadata.params) and
             Enum.any?(metadata.params, &(&1 == organization.id or &1 == organization_dump)) do
          send(test_pid, {:repo_query, ref})
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    refute_received {:repo_query, ^ref}

    result
  end
end
