defmodule GtfsPlanner.Gtfs.StationAssistantResultsTest do
  @moduledoc """
  EV-2: bounded recorded station results and current report facts through scoped
  station reads.

  The recorded fixtures are hand-enumerated: the pairs, their outcomes, indices
  and reasons are written here rather than produced by the engine, so the
  projection is checked against an expected answer instead of the engine's own.
  The reachability path case uses the default `Reachability.start_run/4`
  composition, so the projection is also read over a genuinely recorded result.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.StationAssistant
  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Validations.ValidationRun

  @recorded_schema_version 1

  setup do
    RunnerSlots.await_idle()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id)

    _level = level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})
    station = station_fixture(organization.id, version.id)
    entrance = entrance_fixture(station)
    platform = platform_fixture(station)

    pathway =
      pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_#{System.unique_integer([:positive])}",
        pathway_mode: 1,
        traversal_time: 45,
        min_width: Decimal.new("1.05")
      })

    other_version = gtfs_version_fixture(organization.id)
    other_station = station_fixture(organization.id, other_version.id)

    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    level_fixture(foreign_organization.id, foreign_version.id, %{level_id: "L1"})
    foreign_station = station_fixture(foreign_organization.id, foreign_version.id)

    %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      station: station,
      entrance: entrance,
      platform: platform,
      pathway: pathway,
      other_version: other_version,
      other_station: other_station,
      foreign_organization: foreign_organization,
      foreign_version: foreign_version,
      foreign_station: foreign_station
    }
  end

  describe "scoped reads" do
    test "a foreign organization, version, station or run kind is one unavailable refusal", ctx do
      run = completed_run(ctx, envelope(ctx))

      assert {:ok, ^run} =
               Reachability.get_station_run(
                 ctx.organization.id,
                 ctx.version.id,
                 ctx.station.stop_id,
                 run.id
               )

      # Another organization, another version of the same organization, another
      # station in the same version, and a run of another kind are all the same
      # refusal, and none of them reports what the run holds.
      for {organization_id, version_id, stop_id, run_id} <- [
            {ctx.foreign_organization.id, ctx.foreign_version.id, ctx.station.stop_id, run.id},
            {ctx.organization.id, ctx.other_version.id, ctx.station.stop_id, run.id},
            {ctx.organization.id, ctx.version.id, ctx.other_station.stop_id, run.id},
            {ctx.organization.id, ctx.version.id, ctx.station.stop_id, Ecto.UUID.generate()}
          ] do
        assert {:error, :unavailable} =
                 Reachability.get_station_run(organization_id, version_id, stop_id, run_id)
      end

      validation_run =
        insert_run(ctx, %{
          run_type: "mobility_data",
          status: "completed",
          station_stop_id: ctx.station.stop_id,
          result_json: envelope(ctx)
        })

      assert {:error, :unavailable} =
               Reachability.get_station_run(
                 ctx.organization.id,
                 ctx.version.id,
                 ctx.station.stop_id,
                 validation_run.id
               )

      # A malformed identity is refused before any query runs.
      assert {:error, :unavailable} =
               Reachability.get_station_run(
                 ctx.organization.id,
                 ctx.version.id,
                 ctx.station.stop_id,
                 "not-a-uuid"
               )

      # A snapshot naming another station row, or a run the scoped accessor
      # refuses, discloses nothing.
      assert {:error, :unavailable} =
               StationAssistant.result(
                 station_scope(ctx, %{ctx.other_station | id: Ecto.UUID.generate()}, run.id),
                 %{}
               )

      assert {:error, :unavailable} =
               StationAssistant.result(
                 station_scope(ctx, ctx.station, Ecto.UUID.generate()),
                 %{}
               )
    end

    test "a revoked membership prevents the read", ctx do
      run = completed_run(ctx, envelope(ctx))
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:ok, _result, _evidence} = StationAssistant.result(scope, %{})

      deactivate_membership_fixture(ctx.membership)

      assert {:error, :forbidden} = StationAssistant.result(scope, %{})

      assert {:error, :forbidden} = StationAssistant.result_pairs(scope, %{offset: 0})

      assert {:error, :forbidden} = StationAssistant.report_facts(scope)
    end

    test "a scope without a station_results source refuses every read", ctx do
      scope = %{scope_base(ctx) | resource_context: Scope.context({:version, ctx.version.id})}

      assert {:error, :unavailable} = StationAssistant.result(scope, %{})
      assert {:error, :unavailable} = StationAssistant.report_facts(scope)

      # A station snapshot that names no run is a missing selection, not an
      # unavailable resource.
      assert {:error, :no_selected_run} =
               StationAssistant.result(station_scope(ctx, ctx.station, nil), %{})

      import_ctx =
        station_scope(ctx, ctx.station, nil)
        |> Map.put(:resource_context, %{source_snapshot: nil, identity: {:version, nil}})

      assert {:error, :unavailable} = StationAssistant.result(import_ctx, %{})
    end

    test "unknown filters are refused rather than ignored", ctx do
      run = completed_run(ctx, envelope(ctx))
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:error, :invalid_selection} =
               StationAssistant.result(scope, %{offset: -1})

      assert {:error, :invalid_selection} =
               StationAssistant.result(scope, %{mode: "cycling"})

      assert {:error, :invalid_selection} =
               StationAssistant.result_pairs(scope, %{outcome: "maybe"})

      assert {:error, :invalid_selection} =
               StationAssistant.result_pairs(scope, %{pair_index: 1.5})
    end

    test "a report-only source without a selected run still answers report facts", ctx do
      scope = station_scope(ctx, ctx.station, nil)

      assert {:error, :no_selected_run} = StationAssistant.result(scope, %{})
      assert {:error, :no_selected_run} = StationAssistant.result_pairs(scope, %{offset: 0})
      assert {:ok, facts, evidence} = StationAssistant.report_facts(scope)

      assert facts["station_stop_id"] == ctx.station.stop_id
      assert is_binary(facts["digest"])
      assert evidence.kind == "station_report_facts"
    end
  end

  describe "recorded results" do
    test "a stored no_path names no cause, and current report facts have their own source", ctx do
      recorded = envelope(ctx, pairs: [pair(0, "walking", "unreachable", "no_path")])
      run = completed_run(ctx, recorded)
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:ok, result, evidence} = StationAssistant.result(scope, %{})

      assert result["state"] == "recorded"
      assert result["pairs"] |> hd() |> Map.get("reason") == "no_path"

      # Nothing in the recorded answer names an elevator, a pathway or an outage
      # as the cause of the recorded verdict.
      encoded = Jason.encode!(result)

      refute encoded =~ "elevator"
      refute encoded =~ "outage"
      refute encoded =~ "caused"
      refute encoded =~ "because"

      assert {:ok, facts, facts_evidence} = StationAssistant.report_facts(scope)

      # The current facts carry their own capture time and digest: they are not
      # the recorded result's source and never its explanation.
      assert facts["digest"] != evidence.digest
      assert is_binary(facts["capture_time"])
      assert facts_evidence.source_ref == evidence.source_ref
      assert facts_evidence.digest == facts["digest"]
    end

    test "the real recorded run reads back through the projection", ctx do
      run = run_to_completion(ctx)
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:ok, result, _evidence} = StationAssistant.result(scope, %{})

      assert result["state"] == "recorded"
      assert result["engine"] == "pathways_router"
      assert is_integer(result["totals"]["pair_count"])
      assert result["recorded_provenance"]["freshness"] == "recorded"
      assert result["recorded_provenance"]["closure_evaluation"] == "not_evaluated"
      # Nothing changed since the run, so the stored input still matches.
      assert result["data_equality"] == "match"
    end

    test "a later pathway edit makes the recorded input a mismatch, not a rewrite", ctx do
      run = run_to_completion(ctx)
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:ok, result, _evidence} = StationAssistant.result(scope, %{})
      assert result["data_equality"] == "match"

      {:ok, _updated} =
        ctx.pathway
        |> Ecto.Changeset.change(%{min_width: Decimal.new("0.90")})
        |> Repo.update()

      assert {:ok, result, _evidence} = StationAssistant.result(scope, %{})
      assert result["data_equality"] == "mismatch"

      assert result["recorded_provenance"]["digest"] ==
               run.result_json["input_provenance"]["digest"]
    end

    test "filters select recorded pairs and report exact totals", ctx do
      recorded =
        envelope(ctx,
          pairs: [
            pair(0, "walking", "reachable", nil),
            pair(1, "wheelchair", "unreachable", "no_path"),
            pair(2, "walking", "unreachable", "no_path"),
            pair(3, "wheelchair", "reachable", nil)
          ]
        )

      run = completed_run(ctx, recorded)
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:ok, all, _evidence} = StationAssistant.result(scope, %{})

      assert all["counts"] == %{
               "matched_pairs" => 4,
               "returned_pairs" => 4,
               "offset" => 0
             }

      assert {:ok, walking, _evidence} = StationAssistant.result(scope, %{mode: "walking"})
      assert walking["counts"]["matched_pairs"] == 2
      assert Enum.map(walking["pairs"], & &1["index"]) == [0, 2]

      assert {:ok, unreachable, _evidence} =
               StationAssistant.result(scope, %{outcome: "unreachable"})

      assert Enum.map(unreachable["pairs"], & &1["index"]) == [1, 2]

      assert {:ok, one, _evidence} = StationAssistant.result(scope, %{pair_index: 3})
      assert Enum.map(one["pairs"], & &1["index"]) == [3]
      assert one["counts"]["matched_pairs"] == 1

      assert {:ok, second, _evidence} = StationAssistant.result(scope, %{offset: 2})
      assert Enum.map(second["pairs"], & &1["index"]) == [2, 3]

      assert {:ok, pairs, evidence} = StationAssistant.result_pairs(scope, %{offset: 0})
      assert pairs["counts"]["returned_pairs"] == 4
      assert evidence.total == 4
      assert evidence.total_label == "pairs in this answer"
      assert evidence.kind == "recorded_result_pairs"

      assert evidence.resources == [
               %{kind: "station_reachability_run", id: run.id},
               %{kind: "station", id: ctx.station.stop_id, label: ctx.station.stop_id}
             ]
    end

    test "101 recorded pairs page at 100 with the exact total and a stable next offset", ctx do
      recorded = envelope(ctx, pairs: Enum.map(0..100, &pair(&1, "walking", "reachable", nil)))
      run = completed_run(ctx, recorded)
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:ok, first, first_evidence} = StationAssistant.result(scope, %{})

      assert first["counts"]["matched_pairs"] == 101
      assert first["counts"]["returned_pairs"] == 100
      assert first["completeness"] == "incomplete"
      assert first["next_offset"] == 100
      assert first_evidence.completeness == :incomplete
      assert first_evidence.total == 101
      assert Jason.encode!(%{result: first, evidence: first_evidence}) |> byte_size() <= 32 * 1024

      assert {:ok, last, last_evidence} = StationAssistant.result(scope, %{offset: 100})

      assert Enum.map(last["pairs"], & &1["index"]) == [100]
      assert last["next_offset"] == nil
      assert last["completeness"] == "complete"
      assert last_evidence.completeness == :complete
    end

    test "one oversized pair returns zero rows with narrowing guidance", ctx do
      recorded =
        envelope(ctx, pairs: [pair(0, "walking", "unreachable", String.duplicate("x", 40_000))])

      run = completed_run(ctx, recorded)
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:ok, result, evidence} = StationAssistant.result(scope, %{})

      assert result["pairs"] == []
      assert result["counts"]["matched_pairs"] == 1
      assert result["counts"]["returned_pairs"] == 0
      assert result["completeness"] == "incomplete"
      assert result["narrowing"] =~ "Narrow"
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason =~ "Narrow"
      assert Jason.encode!(%{result: result, evidence: evidence}) |> byte_size() <= 32 * 1024
    end

    test "pending, failed, cancelled, unknown schema and a legacy result stay distinct", ctx do
      for {status, expected} <- [
            {"running", "pending"},
            {"failed", "failed"},
            {"cancelled", "cancelled"}
          ] do
        run = insert_run(ctx, %{status: status, station_stop_id: ctx.station.stop_id})

        assert {:ok, result, _evidence} =
                 StationAssistant.result(station_scope(ctx, ctx.station, run.id), %{})

        assert result["state"] == expected
        assert result["pairs"] == []
        assert result["recorded_provenance"]["freshness"] == "unknown"
        assert result["data_equality"] == "unknown"
        assert result["notes"] != []
      end

      # A result recorded before provenance existed reads as unknown freshness,
      # never as a match.
      legacy =
        insert_run(ctx, %{
          status: "completed",
          station_stop_id: ctx.station.stop_id,
          engine: nil,
          result_json: nil
        })

      assert {:ok, result, _evidence} =
               StationAssistant.result(station_scope(ctx, ctx.station, legacy.id), %{})

      assert result["state"] == "legacy"
      assert result["recorded_provenance"]["digest"] == nil

      # An envelope the reader does not support is reported as such, not decoded.
      unsupported =
        insert_run(ctx, %{
          status: "completed",
          station_stop_id: ctx.station.stop_id,
          result_schema_version: 7,
          result_json: envelope(ctx)
        })

      assert {:ok, result, _evidence} =
               StationAssistant.result(station_scope(ctx, ctx.station, unsupported.id), %{})

      assert result["state"] == "unsupported_schema"
      assert result["pairs"] == []

      no_digest =
        insert_run(ctx, %{
          status: "completed",
          station_stop_id: ctx.station.stop_id,
          result_schema_version: @recorded_schema_version,
          result_json: Map.delete(envelope(ctx), "input_provenance")
        })

      assert {:ok, result, _evidence} =
               StationAssistant.result(station_scope(ctx, ctx.station, no_digest.id), %{})

      assert result["state"] == "recorded"

      assert result["recorded_provenance"] == %{
               "digest" => nil,
               "closure_evaluation" => nil,
               "freshness" => "unknown"
             }

      assert result["data_equality"] == "unknown"
    end

    test "the projection discloses no free text beyond the recorded reason", ctx do
      recorded =
        envelope(ctx,
          diagnostics: [
            %{
              "severity" => "warning",
              "code" => "missing_coordinate",
              "entity_type" => "stop",
              "entity_id" => "ENT_A",
              "message" => "This stop has no location on the map."
            }
          ],
          pairs: [pair(0, "wheelchair", "unreachable", "no_path")]
        )

      run = completed_run(ctx, recorded)
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:ok, result, _evidence} = StationAssistant.result(scope, %{})

      assert result["diagnostics"] == [
               %{
                 "severity" => "warning",
                 "code" => "missing_coordinate",
                 "entity_type" => "stop",
                 "entity_id" => "ENT_A"
               }
             ]

      refute Jason.encode!(result) =~ "no location on the map"
    end
  end

  describe "current report facts" do
    test "the facts are derived from the existing builders and never from the run", ctx do
      scope = station_scope(ctx, ctx.station, nil)

      assert {:ok, facts, evidence} = StationAssistant.report_facts(scope)

      ids = Enum.map(facts["data_quality"], & &1["id"])

      assert "entrance_to_platform_connectivity" in ids
      assert "platform_interconnection" in ids

      assert facts["counts"]["checks"] == length(facts["data_quality"])
      assert evidence.total == facts["counts"]["checks"]
      assert facts["digest"] == evidence.digest

      # Free text stays out of the projection: no builder description or per-stop
      # reason reaches it.
      refute Jason.encode!(facts) =~ "Entrances with no pathway to any platform"
      refute Jason.encode!(facts) =~ "level siblings are accessible"

      dimension_ids = Enum.map(facts["connectivity"], & &1["dimension"])
      assert "entrance_to_platform" in dimension_ids
    end
  end

  ## Fixtures

  defp station_fixture(organization_id, version_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: "STATION_#{System.unique_integer([:positive])}",
      stop_name: "Scoped Station",
      location_type: 1,
      level_id: "L1"
    })
  end

  defp entrance_fixture(station) do
    stop_fixture(station.organization_id, station.gtfs_version_id, %{
      stop_id: "ENT_#{System.unique_integer([:positive])}",
      stop_name: "Entrance A",
      location_type: 2,
      parent_station: station.stop_id,
      level_id: "L1",
      stop_lat: Decimal.new("39.9526"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  defp platform_fixture(station) do
    stop_fixture(station.organization_id, station.gtfs_version_id, %{
      stop_id: "PLAT_#{System.unique_integer([:positive])}",
      stop_name: "Platform 1",
      location_type: 0,
      parent_station: station.stop_id,
      level_id: "L1",
      stop_lat: Decimal.new("39.9527"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  defp scope_base(ctx) do
    %Scope{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      user_id: ctx.user.id,
      user_email: ctx.user.email,
      pack_id: "station_results",
      version_name: ctx.version.name,
      resource_context: Scope.context({:version, ctx.version.id})
    }
  end

  # The host builds the snapshot from the station it resolved; the projection
  # only ever reads it back.
  defp station_scope(ctx, station, run_id) do
    {:ok, resource_context} =
      Scope.context({:version, ctx.version.id})
      |> Scope.with_source_snapshot(%{
        kind: "station_results",
        payload: %{
          "station_id" => station.id,
          "station_stop_id" => station.stop_id,
          "run_id" => run_id
        }
      })

    %{scope_base(ctx) | resource_context: resource_context}
  end

  defp envelope(ctx, opts \\ []) do
    pairs = Keyword.get(opts, :pairs, [pair(0, "walking", "reachable", nil)])

    Map.merge(
      %{
        "engine" => "pathways_router",
        "engine_ref" => "f1bf1b58e29307d410742af95dfde18111bcb07a",
        "result_schema_version" => @recorded_schema_version,
        "preferences" => "default",
        "metadata" => %{"station_stop_id" => ctx.station.stop_id},
        "outcome" => "passed",
        "topology" => %{
          "entrance_count" => 1,
          "platform_count" => 1,
          "pathway_count" => 1,
          "level_count" => 1
        },
        "totals" => %{
          "pair_count" => length(pairs),
          "reachable" => length(pairs),
          "unreachable" => 0,
          "invalid" => 0
        },
        "diagnostics" => [],
        "pairs" => pairs,
        "started_at" => "2026-10-02T09:00:00Z",
        "completed_at" => "2026-10-02T09:00:12Z",
        "duration_ms" => 12
      },
      Map.new(opts, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp pair(index, mode, outcome, reason) do
    %{
      "index" => index,
      "kind" => "entry",
      "mode" => mode,
      "from_stop_id" => "ENT_A",
      "from_stop_name" => "Entrance A",
      "to_stop_id" => "PLAT_1",
      "to_stop_name" => "Platform 1",
      "outcome" => outcome,
      "reason" => reason,
      "duration_seconds" => nil,
      "distance_meters" => nil,
      "generalized_cost" => nil,
      "step_count" => nil
    }
  end

  # Every reachability run records its station in `result_json`, including one
  # that has not finished, so the scoped read can resolve it by station.
  defp insert_run(ctx, attrs) do
    merged =
      %{
        organization_id: ctx.organization.id,
        gtfs_version_id: ctx.version.id,
        run_type: "station_reachability",
        status: "completed",
        engine: "pathways_router",
        result_schema_version: @recorded_schema_version,
        started_at: DateTime.utc_now(),
        result_json: %{}
      }
      |> Map.merge(attrs |> Map.new() |> Map.delete(:station_stop_id))

    merged
    |> Map.put(:result_json, with_station_metadata(merged.result_json, ctx.station.stop_id))
    |> then(&struct!(ValidationRun, &1))
    |> Repo.insert!()
  end

  defp with_station_metadata(%{"metadata" => _} = result_json, _stop_id), do: result_json

  defp with_station_metadata(result_json, stop_id) when is_map(result_json),
    do: Map.put(result_json, "metadata", %{"station_stop_id" => stop_id})

  defp with_station_metadata(_result_json, stop_id),
    do: %{"metadata" => %{"station_stop_id" => stop_id}}

  defp completed_run(ctx, result_json) do
    insert_run(ctx, %{status: "completed", result_json: result_json})
  end

  # The production path: the default runner records the envelope the projection
  # later reads.
  defp run_to_completion(ctx) do
    pids_before = MapSet.new(runner_pids())

    assert {:ok, run} =
             Reachability.start_run(ctx.organization.id, ctx.version.id, ctx.station.stop_id)

    case Enum.find(runner_pids(), &(&1 not in pids_before)) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
        assert reason in [:normal, :noproc]
    end

    completed = Repo.get!(ValidationRun, run.id)

    assert completed.status in ["completed", "failed"],
           "run #{run.id} is #{completed.status} after its task exited"

    completed
  end

  defp runner_pids do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(GtfsPlanner.Reachability.RunnerSupervisor),
        is_pid(pid),
        do: pid
  end
end
