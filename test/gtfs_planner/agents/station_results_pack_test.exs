defmodule GtfsPlanner.Agents.StationResultsPackTest do
  @moduledoc """
  Merge evidence (EV-7) for the Station result pack through the real composition:
  `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> `Packs.StationResults` ->
  `Gtfs.StationAssistant`, with only the OpenRouter HTTP boundary doubled.

  The registry, session, turn loop, dispatch fence, pack and station projection
  are the shipped ones, so a pack that was never registered, a tool that never
  reached the projection and evidence that never reached the entry all fail here
  rather than passing over a hand-built controller. What the model actually read is
  asserted on the tool message of the next provider request, so the rows the pack
  sent and the card the panel will render come from the same read.

  The recorded envelope is hand-written rather than produced by the engine: its
  pairs, outcomes, indices and reasons are stated here, so the answer is compared
  against an expected answer. The freshness digest is the one `Envelope` recorded,
  because that is what the provenance equality is meant to describe.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.StationResults
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{JournalEntry, JournalPhoto}
  alias GtfsPlanner.Reachability.Envelope
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Validations.ValidationRun

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response below replaces only the HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  @recorded_schema_version 1
  @result_arguments ~s({})
  @pair_arguments ~s({"mode":"walking","outcome":"unreachable"})

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug and
    # the SQL sandbox are both shared (`async: false`).
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()
    RunnerSlots.await_idle()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = editor_fixture(organization)
    membership = organization_membership_fixture(user, organization)

    _level = level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})
    station = station_stop(organization.id, version.id, "STATION_A", "L1")
    entrance = child_stop(organization.id, version.id, station, "ENT_A", "L1", "Entrance A")
    platform = child_stop(organization.id, version.id, station, "PLAT_A", "L1", "Platform A")

    _pathway =
      pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_A",
        pathway_mode: 1,
        traversal_time: 45,
        min_width: Decimal.new("1.05")
      })

    # Every way this page's station could stop being this conversation's station.
    other_station = station_stop(organization.id, version.id, "STATION_B", "L1")
    other_version = gtfs_version_fixture(organization.id)
    foreign_organization = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_organization.id)
    _foreign_level = level_fixture(foreign_organization.id, foreign_version.id, %{level_id: "L1"})
    foreign_station = station_stop(foreign_organization.id, foreign_version.id, "STATION_A", "L1")

    %{
      organization: organization,
      version: version,
      user: user,
      membership: membership,
      station: station,
      entrance: entrance,
      platform: platform,
      other_station: other_station,
      other_version: other_version,
      foreign_organization: foreign_organization,
      foreign_version: foreign_version,
      foreign_station: foreign_station
    }
  end

  describe "the shipped registration" do
    test "the registry names the pack and its tools are exactly the recorded read set", _ctx do
      assert Agents.packs()["station_results"] == StationResults
      assert StationResults.id() == "station_results"
      assert StationResults.title() == "Station result helper"

      assert Enum.map(StationResults.tools(), & &1.name) == [
               "get_station_result",
               "get_station_report_facts",
               "list_station_result_pairs"
             ]

      assert Enum.all?(StationResults.tools(), &(&1.parameters["additionalProperties"] == false))

      # No identity, no observation, no SQL and no path may be named by an
      # argument: the only bounded things a model chooses are filters.
      declared =
        StationResults.tools()
        |> Enum.flat_map(&Map.keys(&1.parameters["properties"]))
        |> Enum.uniq()
        |> Enum.sort()

      assert declared == ["mode", "offset", "outcome", "pair_index"]

      for forbidden <- [
            "station_id",
            "station_stop_id",
            "run_id",
            "organization_id",
            "observations",
            "sql",
            "path"
          ] do
        refute forbidden in declared
      end

      assert StationResults.skill() =~ "get_station_result"
    end

    test "a version-bound conversation opens the shipped session", ctx do
      run = recorded_run(ctx)
      scope = station_scope(ctx, ctx.station, run.id)

      assert {:ok, session, snapshot} = Agents.open(scope)
      assert is_pid(session)
      assert snapshot.entries == []

      # The same person on a different source snapshot is a different
      # conversation, and the import pack is not this pack's conversation.
      other = station_scope(ctx, ctx.other_station, nil)
      assert {:ok, other_session, _snapshot} = Agents.open(other)
      refute other_session == session

      assert {:error, :unknown_pack} = Agents.open(%{scope | pack_id: "no_such_pack"})
    end
  end

  describe "the composed turn (Agents -> Session -> Dispatch -> pack -> projection)" do
    test "a recorded result reaches the entry with its server evidence", ctx do
      run =
        recorded_run(ctx,
          pairs: [unreachable_pair(0, "walking"), reachable_pair(1, "wheelchair")]
        )

      scope = station_scope(ctx, ctx.station, run.id)

      expect_reply(tool_calls_reply([{"call_1", "get_station_result", @result_arguments}]))

      expect_reply(
        text_reply("The recorded check found no walking path from Entrance A to Platform A.")
      )

      entry = run_turn(scope, "What did the recorded check say?")

      assert entry.status == :done
      assert entry.activity == ["Read the recorded station check"]

      # What the model read: the recorded facts, with the recorded reason kept
      # verbatim and no cause added to it.
      result = tool_result()

      assert result["station_stop_id"] == ctx.station.stop_id
      assert result["run_id"] == run.id
      assert result["state"] == "recorded"
      assert result["engine"] == "pathways_router"
      assert result["engine_ref"] == "f1bf1b58e29307d410742af95dfde18111bcb07a"
      assert result["preferences"] == "default"
      assert result["result_schema_version"] == 1
      assert result["totals"]["unreachable"] == 1
      assert result["counts"]["matched_pairs"] == 2

      assert [unreachable] =
               Enum.filter(result["pairs"], &(&1["outcome"] == "unreachable"))

      assert unreachable["reason"] == "no_path"
      assert unreachable["index"] == 0
      assert unreachable["from_stop_id"] == "ENT_A"
      assert unreachable["to_stop_id"] == "PLAT_A"

      # The recorded no_path names no cause, and the projection adds none.
      refute Jason.encode!(result) =~ "elevator"
      refute Jason.encode!(result) =~ "outage"

      # The card's count and source are the server's, over the same rows.
      assert [evidence] = entry.evidence
      assert evidence.kind == "recorded_result"
      assert evidence.total == 2
      assert evidence.completeness == :complete
      assert evidence.source_ref == "gtfs_station_assistant"
      assert evidence.digest =~ ~r/\A[0-9a-f]{64}\z/
      assert evidence.source_revision == nil

      assert evidence.scope.organization_id == ctx.organization.id
      assert evidence.scope.gtfs_version_id == ctx.version.id
      assert evidence.scope.identity == "station:#{ctx.station.stop_id}"

      assert Enum.map(evidence.resources, & &1.kind) == [
               "station_reachability_run",
               "station"
             ]

      assert Enum.find(evidence.facts, &(&1.label == "Data equality")).value == "match"
    end

    test "a recorded pair page answers from the stored pairs, not a reroute", ctx do
      run =
        recorded_run(ctx,
          pairs: [unreachable_pair(0, "walking"), reachable_pair(1, "wheelchair")]
        )

      scope = station_scope(ctx, ctx.station, run.id)

      expect_reply(tool_calls_reply([{"call_1", "list_station_result_pairs", @pair_arguments}]))
      expect_reply(text_reply("One walking pair had no recorded path."))

      entry = run_turn(scope, "Which walking pairs failed?")

      assert entry.status == :done
      assert entry.activity == ["Listed recorded station check pairs"]

      result = tool_result()

      assert result["counts"]["matched_pairs"] == 1
      assert result["completeness"] == "complete"
      assert [only] = result["pairs"]
      assert only["mode"] == "walking"
      assert only["outcome"] == "unreachable"
      assert only["reason"] == "no_path"

      assert [%{kind: "recorded_result_pairs"}] = entry.evidence
    end

    test "current report facts stay available with their own source and digest", ctx do
      run = recorded_run(ctx)
      scope = station_scope(ctx, ctx.station, run.id)

      expect_reply(tool_calls_reply([{"call_1", "get_station_report_facts", ~s({})}]))

      expect_reply(text_reply("Right now the station reports no failing data-quality checks."))

      entry = run_turn(scope, "What is true of the station today?")

      assert entry.status == :done
      assert entry.activity == ["Read the current station report facts"]

      facts = tool_result()

      assert facts["station_stop_id"] == ctx.station.stop_id
      assert is_binary(facts["capture_time"])
      assert facts["digest"] =~ ~r/\A[0-9a-f]{64}\z/
      assert is_list(facts["data_quality"])
      assert is_map(facts["counts"])

      assert [evidence] = entry.evidence
      assert evidence.kind == "station_report_facts"
      assert evidence.source_ref == "gtfs_station_assistant"

      # The current facts are not the recorded result's source and never claim to
      # be its cause.
      assert evidence.digest != result_digest(run)

      assert Enum.find(evidence.facts, &(&1.label == "Separate source")).value =~
               "current facts"
    end

    test "a report page with no selected run still reads current facts", ctx do
      scope = station_scope(ctx, ctx.station, nil)

      expect_reply(tool_calls_reply([{"call_1", "get_station_result", @result_arguments}]))
      expect_reply(text_reply("No check is selected here; the current facts are available."))

      entry = run_turn(scope, "What did the check say?")

      assert entry.status == :done

      assert {:tool_error, message} =
               Dispatch.call(StationResults, scope, "get_station_result", @result_arguments)

      assert message =~ "No station check is selected"
      assert message =~ "report facts"

      # The facts tool answers for the very same source.
      assert {:ok, facts, evidence} =
               Dispatch.call(StationResults, scope, "get_station_report_facts", ~s({}))

      assert facts["station_stop_id"] == ctx.station.stop_id
      assert evidence.kind == "station_report_facts"

      # The refused turn itself carries no card, so a panel can never render one
      # beside an answer that does not exist.
      assert entry.evidence == []
    end

    test "the provider's follow-up request carries no journal prose, photo or email", ctx do
      run = recorded_run(ctx)
      scope = station_scope(ctx, ctx.station, run.id)
      sentinel = journal_sentinel(ctx)

      expect_reply(tool_calls_reply([{"call_1", "get_station_result", @result_arguments}]))
      expect_reply(text_reply("A summary."))

      run_turn(scope, "What did the check say?")

      assert_receive {:model_request, request}, 5_000

      # The last request carries the tool message the model read; nothing the
      # station journal holds may appear anywhere in it.
      encoded = Jason.encode!(request)

      refute encoded =~ sentinel
      refute encoded =~ "SENTINEL-PHOTO-FILENAME"
      refute encoded =~ ctx.user.email
      refute encoded =~ "image/jpeg"
    end
  end

  describe "the dispatch fence" do
    setup ctx do
      run = recorded_run(ctx)
      Map.merge(ctx, %{scope: station_scope(ctx, ctx.station, run.id), run: run})
    end

    test "a forged identity argument is refused before the pack runs", %{scope: scope} do
      for arguments <- [
            ~s({"station_id":"#{Ecto.UUID.generate()}"}),
            ~s({"station_stop_id":"STATION_B"}),
            ~s({"run_id":"#{Ecto.UUID.generate()}"}),
            ~s({"organization_id":"#{Ecto.UUID.generate()}"}),
            ~s({"sql":"select 1"}),
            ~s({"path":"/etc/passwd"})
          ] do
        assert {:tool_error, message} =
                 Dispatch.call(StationResults, scope, "get_station_result", arguments)

        assert message =~ "Unexpected argument"
      end
    end

    test "a forged identity inside a valid argument is refused too", %{scope: scope} do
      assert {:tool_error, message} =
               Dispatch.call(
                 StationResults,
                 scope,
                 "list_station_result_pairs",
                 ~s({"filters":{"run_id":"#{Ecto.UUID.generate()}"}})
               )

      assert message =~ "Unexpected argument"
    end

    test "an out-of-range or wrongly typed filter is refused", %{scope: scope} do
      assert {:tool_error, message} =
               Dispatch.call(StationResults, scope, "get_station_result", ~s({"offset":-1}))

      assert message =~ "offset"

      assert {:tool_error, message} =
               Dispatch.call(StationResults, scope, "get_station_result", ~s({"mode":7}))

      assert message =~ "mode"
    end

    test "an unknown recorded outcome is a message the model can correct", %{scope: scope} do
      assert {:tool_error, message} =
               Dispatch.call(
                 StationResults,
                 scope,
                 "get_station_result",
                 ~s({"outcome":"sideways"})
               )

      assert message =~ "walking"
      assert message =~ "wheelchair"
    end

    test "an unknown tool is refused", %{scope: scope} do
      assert {:tool_error, message} =
               Dispatch.call(StationResults, scope, "launch_station_check", ~s({}))

      assert message =~ "Unknown tool"
    end
  end

  describe "the pack's own precondition" do
    setup ctx do
      run = recorded_run(ctx)
      Map.merge(ctx, %{scope: station_scope(ctx, ctx.station, run.id), run: run})
    end

    test "a foreign station, version or organization is unavailable, not a lesser answer", ctx do
      for {organization_id, version_id, station} <- [
            {ctx.foreign_organization.id, ctx.foreign_version.id, ctx.foreign_station},
            {ctx.organization.id, ctx.other_version.id, ctx.station},
            {ctx.organization.id, ctx.version.id, ctx.other_station}
          ] do
        scope = foreign_scope(ctx, organization_id, version_id, station)

        assert {:error, :unavailable} = StationResults.authorize_context(scope)

        assert {:error, :unavailable} =
                 Dispatch.call(StationResults, scope, "get_station_result", @result_arguments)
      end
    end

    test "another organization's or another station's run is unavailable", ctx do
      foreign_run =
        insert_run(ctx, %{
          organization_id: ctx.foreign_organization.id,
          gtfs_version_id: ctx.foreign_version.id,
          result_json: envelope(ctx, [unreachable_pair(0, "walking")])
        })

      for run_id <- [foreign_run.id, Ecto.UUID.generate()] do
        scope = station_scope(ctx, ctx.station, run_id)

        assert {:error, :unavailable} = StationResults.authorize_context(scope)

        assert {:error, :unavailable} =
                 Dispatch.call(StationResults, scope, "get_station_result", @result_arguments)
      end
    end

    test "a malformed snapshot payload is unavailable", ctx do
      for payload <- [
            %{"station_stop_id" => ctx.station.stop_id},
            %{
              "station_id" => "not-a-uuid",
              "station_stop_id" => ctx.station.stop_id,
              "run_id" => nil
            },
            %{
              "station_id" => ctx.station.id,
              "station_stop_id" => ctx.station.stop_id,
              "run_id" => "not-a-uuid"
            }
          ] do
        assert {:ok, resource_context} =
                 Scope.context({:version, ctx.version.id})
                 |> Scope.with_source_snapshot(%{kind: "station_results", payload: payload})

        scope = %{scope_base(ctx, "station_results") | resource_context: resource_context}

        assert {:error, :unavailable} = StationResults.authorize_context(scope)
      end
    end

    test "a revoked membership stops the request and the read", ctx do
      deactivate_membership_fixture(ctx.membership)

      assert {:error, :unavailable} = StationResults.authorize_context(ctx.scope)

      assert {:error, :forbidden} =
               Dispatch.call(StationResults, ctx.scope, "get_station_result", @result_arguments)

      assert {:error, :forbidden} = Agents.open(ctx.scope)
    end

    test "a run with no recorded provenance reads as unknown freshness, never a match", ctx do
      legacy = insert_run(ctx, %{status: "completed", engine: nil, result_json: %{"pairs" => []}})

      scope = station_scope(ctx, ctx.station, legacy.id)

      assert {:ok, result, evidence} =
               Dispatch.call(StationResults, scope, "get_station_result", @result_arguments)

      assert result["state"] == "legacy"
      assert result["recorded_provenance"]["freshness"] == "unknown"
      assert result["data_equality"] == "unknown"
      assert Enum.find(evidence.facts, &(&1.label == "Data equality")).value == "unknown"
    end

    test "a run in a state with no recorded pairs says so and claims nothing", ctx do
      for {attrs, expected} <- [
            [%{status: "running"}, "pending"],
            [%{status: "failed"}, "failed"],
            [%{status: "cancelled"}, "cancelled"],
            [%{status: "completed", result_schema_version: 99}, "unsupported_schema"]
          ] do
        run = insert_run(ctx, Map.merge(attrs, %{result_json: %{"pairs" => []}}))
        scope = station_scope(ctx, ctx.station, run.id)

        assert {:ok, result, _evidence} =
                 Dispatch.call(StationResults, scope, "get_station_result", @result_arguments)

        assert result["state"] == expected
        assert result["pairs"] == []
        assert result["notes"] != []
      end
    end
  end

  ## Helpers

  # The station journal's prose and a photo row are real persisted rows on this
  # station: the projection must carry neither the body, nor the photo's
  # filename, nor the author's email to the provider.
  defp journal_sentinel(ctx) do
    {:ok, scope} =
      Gtfs.resolve_station_journal_scope(
        ctx.organization.id,
        ctx.version.id,
        ctx.station.id,
        ctx.user.id
      )

    id = Ecto.UUID.generate()
    body = "SENTINEL-JOURNAL-PROSE-DO-NOT-SEND"

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(scope, [
               %{
                 id: id,
                 target_type: "station",
                 body: body,
                 captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
               }
             ])

    entry = Repo.get!(JournalEntry, id)

    Repo.insert!(%JournalPhoto{
      id: Ecto.UUID.generate(),
      journal_entry_id: entry.id,
      filename: "SENTINEL-PHOTO-FILENAME.jpg",
      content_type: "image/jpeg",
      byte_size: 2,
      sha256: :crypto.hash(:sha256, "sentinel"),
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    body
  end

  # The foreign conversation belongs to a real editor of the foreign
  # organization: a membership of this one would be refused as `:forbidden`
  # before the station or the run was ever examined.
  defp foreign_scope(_ctx, organization_id, version_id, station) do
    foreign = GtfsPlanner.Organizations.get_organization!(organization_id)
    user = editor_fixture(foreign)

    {:ok, resource_context} =
      Scope.context({:version, version_id})
      |> Scope.with_source_snapshot(%{
        kind: "station_results",
        payload: %{
          "station_id" => station.id,
          "station_stop_id" => station.stop_id,
          "run_id" => nil
        }
      })

    %Scope{
      organization_id: organization_id,
      gtfs_version_id: version_id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "station_results",
      version_name: "Foreign",
      resource_context: resource_context
    }
  end

  defp scope_base(ctx, pack_id) do
    %Scope{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      user_id: ctx.user.id,
      user_email: ctx.user.email,
      pack_id: pack_id,
      version_name: ctx.version.name,
      resource_context: Scope.context({:version, ctx.version.id})
    }
  end

  # The host builds the snapshot from the station and the run it resolved; the
  # pack only ever reads it back.
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

    %{scope_base(ctx, "station_results") | resource_context: resource_context}
  end

  defp station_stop(organization_id, version_id, stop_id, level_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: "Station #{stop_id}",
      location_type: 1,
      level_id: level_id,
      stop_lat: Decimal.new("39.9526"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  defp child_stop(organization_id, version_id, station, stop_id, level_id, name) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: name,
      location_type: if(stop_id =~ "ENT_", do: 2, else: 0),
      parent_station: station.stop_id,
      level_id: level_id,
      stop_lat: Decimal.new("39.9526"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  # The provenance digest the production `Envelope` computes over this station's
  # own current input, so the equality the projection reports is the one a real
  # recorded run carries.
  defp input_digest(ctx) do
    {:ok, snapshot} =
      Gtfs.get_station_report_snapshot(ctx.organization.id, ctx.version.id, ctx.station.stop_id)

    Envelope.input_provenance(snapshot)["digest"]
  end

  defp recorded_run(ctx, opts \\ []) do
    pairs = Keyword.get(opts, :pairs, [unreachable_pair(0, "walking")])

    insert_run(ctx, %{
      status: "completed",
      result_json:
        ctx
        |> envelope(pairs)
        |> Map.put("input_provenance", %{
          "version" => 1,
          "digest" => input_digest(ctx),
          "closure_evaluation" => "not_evaluated"
        })
    })
  end

  defp result_digest(%ValidationRun{result_json: %{"input_provenance" => provenance}}) do
    provenance["digest"]
  end

  defp envelope(ctx, pairs) do
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
        "reachable" => Enum.count(pairs, &(&1["outcome"] == "reachable")),
        "unreachable" => Enum.count(pairs, &(&1["outcome"] == "unreachable")),
        "invalid" => 0
      },
      "diagnostics" => [],
      "pairs" => pairs,
      "started_at" => "2026-10-02T09:00:00Z",
      "completed_at" => "2026-10-02T09:00:12Z",
      "duration_ms" => 12
    }
  end

  defp unreachable_pair(index, mode) do
    pair(index, mode, "unreachable", "no_path")
  end

  defp reachable_pair(index, mode) do
    pair(index, mode, "reachable", nil)
  end

  defp pair(index, mode, outcome, reason) do
    %{
      "index" => index,
      "kind" => "entrance_platform",
      "mode" => mode,
      "from_stop_id" => "ENT_A",
      "from_stop_name" => "Entrance A",
      "to_stop_id" => "PLAT_A",
      "to_stop_name" => "Platform A",
      "outcome" => outcome,
      "reason" => reason,
      "duration_seconds" => nil,
      "distance_meters" => nil,
      "step_count" => nil
    }
  end

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
      |> Map.merge(Map.new(attrs))

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

  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
  end

  ## Scripted OpenRouter replies

  defp expect_reply(payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)
  end

  defp text_reply(content) do
    %{
      "id" => "gen-test-text",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 16, "cost" => 0.0}
    }
  end

  defp tool_calls_reply(calls) do
    %{
      "id" => "gen-test-tool",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "tool_calls",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" =>
              Enum.map(calls, fn {id, name, arguments} ->
                %{
                  "id" => id,
                  "type" => "function",
                  "function" => %{"name" => name, "arguments" => arguments}
                }
              end)
          }
        }
      ],
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 32, "cost" => 0.0}
    }
  end

  # The working placeholder arrives before the settled entry, and each provider
  # request is observable, so a turn is driven and read without polling a render
  # or sleeping.
  defp run_turn(scope, text) do
    assert {:ok, pid, _snapshot} = Agents.open(scope)
    assert :ok = Agents.send_message(pid, text)
    await_settled(pid)
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  # The tool message the turn sent back to the provider is the pack's own result,
  # decoded, so the assertions read what the model read.
  defp tool_result do
    assert_receive {:model_request, request}, 5_000

    request
    |> tool_messages()
    |> case do
      [] -> tool_result()
      messages -> messages |> List.last() |> Map.fetch!("content") |> Jason.decode!()
    end
  end

  defp tool_messages(request) do
    Enum.filter(request["messages"] || [], &(&1["role"] == "tool"))
  end
end
