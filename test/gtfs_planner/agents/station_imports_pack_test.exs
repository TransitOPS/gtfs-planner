defmodule GtfsPlanner.Agents.StationImportsPackTest do
  @moduledoc """
  Merge evidence (EV-7) for the Station import pack through the real composition:
  `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> `Packs.StationImports` ->
  `Gtfs.StationAssistant` -> `Gtfs.Import.ChangeRunReview`, with only the OpenRouter
  HTTP boundary doubled.

  The decisions are written out by hand rather than produced by the diff engine,
  so the expected selection is a stated expectation: W14's min_width-only
  pending change matches an accepted 105 cm measurement exactly, W12's disputed
  width does not, and PW_W14's own endpoint decision is somebody else's approval.
  The last case recomputes the same run through the default native compute, so
  the pack is also read over decisions this module never authored.

  Every expectation here is about what the model may read and what it may not
  cause: a forged identity or observation argument is refused by the dispatch
  fence, the prepared command carries no approval operation, and preparation
  leaves every persisted status, the run manifest and the GTFS rows untouched.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.StationImports
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeArtifactStorage
  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.ChangeDecisionSerializer
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Import.ChangeRuns
  alias GtfsPlanner.Gtfs.Import.ChangeWorker
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.StationAssistant

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  @diff_arguments ~s({})
  @prepare_w14 ~s({"decision_ids":["pathway:PW_W14","pathway:PW_W12"]})
  @final_text "I prepared one width decision for your review; nothing is approved yet."

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()

    organization = organization_fixture()
    editor = user_fixture()
    membership = organization_membership_fixture(editor, organization)
    version = gtfs_version_fixture(organization.id)

    level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})
    level_fixture(organization.id, version.id, %{level_id: "L2", level_index: 1.0})

    station = station_stop(organization.id, version.id, "STATION_A", "L1")
    entrance = child_stop(organization.id, version.id, station, "ENT_A", "L1", "Entrance A")
    platform = child_stop(organization.id, version.id, station, "PLAT_A", "L1", "Platform A")

    other_station = station_stop(organization.id, version.id, "STATION_B", "L2")

    other_platform =
      child_stop(organization.id, version.id, other_station, "PLAT_B", "L2", "Platform B")

    _w12 =
      pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_W12",
        pathway_mode: 1,
        min_width: Decimal.new("1.10")
      })

    _w14 =
      pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_W14",
        pathway_mode: 1,
        min_width: Decimal.new("0.95")
      })

    _cross_station =
      pathway_fixture(organization.id, version.id, entrance.stop_id, other_platform.stop_id, %{
        pathway_id: "PW_CROSS",
        pathway_mode: 1,
        min_width: Decimal.new("0.80")
      })

    other_version = gtfs_version_fixture(organization.id)
    foreign_organization = organization_fixture()

    %{
      organization: organization,
      editor: editor,
      membership: membership,
      version: version,
      station: station,
      entrance: entrance,
      platform: platform,
      other_station: other_station,
      other_version: other_version,
      foreign_organization: foreign_organization
    }
  end

  describe "the shipped registration" do
    test "the registry names the pack and its tools are exactly the prepare-only read set",
         _ctx do
      assert Agents.packs()["station_imports"] == StationImports
      assert StationImports.id() == "station_imports"
      assert StationImports.title() == "Import helper"

      assert Enum.map(StationImports.tools(), & &1.name) == [
               "get_station_import_diff",
               "get_observation_provenance",
               "prepare_station_import_decisions"
             ]

      assert Enum.all?(StationImports.tools(), &(&1.parameters["additionalProperties"] == false))

      # The only argument a model chooses is a page offset or a bounded list of
      # decision ids of the run this page already selected.
      declared =
        StationImports.tools()
        |> Enum.flat_map(&Map.keys(&1.parameters["properties"]))
        |> Enum.uniq()
        |> Enum.sort()

      assert declared == ["decision_ids", "offset"]

      for forbidden <- [
            "station_id",
            "station_stop_id",
            "change_run_id",
            "observations",
            "approve",
            "status",
            "sql",
            "path"
          ] do
        refute forbidden in declared
      end

      assert StationImports.skill() =~ "prepare_station_import_decisions"
    end

    test "a run-bound conversation opens the shipped session", ctx do
      run = width_run(ctx)
      scope = import_scope(ctx, ctx.station, run, observations(ctx))

      assert {:ok, session, snapshot} = Agents.open(scope)
      assert is_pid(session)
      assert snapshot.entries == []

      # A conversation with different frozen observations is a different one.
      other = import_scope(ctx, ctx.station, run, [])
      assert {:ok, other_session, _snapshot} = Agents.open(other)
      refute other_session == session
    end
  end

  describe "the composed turn (Agents -> Session -> Dispatch -> pack -> projection)" do
    setup ctx do
      run = width_run(ctx)

      %{
        run: run,
        scope: import_scope(ctx, ctx.station, run, observations(ctx)),
        before: persisted_state(ctx)
      }
    end

    test "the station's decisions reach the entry with their server evidence", ctx do
      expect_reply(tool_calls_reply([{"call_1", "get_station_import_diff", @diff_arguments}]))
      expect_reply(text_reply("Three decisions in this station's run."))

      entry = run_turn(ctx.scope, "Which pathways changed width?")

      assert entry.status == :done
      assert entry.activity == ["Read this station's import decisions"]

      result = tool_result()

      assert result["station_stop_id"] == ctx.station.stop_id
      assert result["run_id"] == ctx.run.id
      assert result["state"] == "review"
      assert result["serializer_version"] == 1
      assert result["completeness"] == "complete"

      # The cross-station pathway belongs to another station: it is counted, not
      # described, and no foreign value appears in the answer.
      assert result["counts"]["station_total"] == 3
      assert result["counts"]["version_total"] == 4
      assert result["counts"]["excluded_total"] == 1

      assert result["excluded"] == %{"unresolvable_or_other_endpoint" => 1}

      refute Jason.encode!(result) =~ "PW_CROSS"

      w14 =
        Enum.find(result["decisions"], &(&1["decision_id"] == "pathway:PW_W14"))

      assert w14["action"] == "modify"
      assert w14["status"] == "pending"
      assert w14["uploaded_values"]["min_width"] == "1.05"
      assert w14["fingerprint_state"] == "match"

      assert [evidence] = entry.evidence
      assert evidence.kind == "station_import_diff"
      assert evidence.total == 3
      assert evidence.completeness == :complete
      assert evidence.source_ref == "gtfs_station_assistant"
      assert evidence.scope.identity == "station:#{ctx.station.stop_id}"

      assert Enum.map(evidence.resources, & &1.kind) == ["station_import_run", "station"]

      # Reading is not writing.
      assert persisted_state(ctx) == ctx.before
    end

    test "accepted provenance reaches the model without the journal's prose or author", ctx do
      body = "SENTINEL-JOURNAL-PROSE-DO-NOT-SEND"
      journal_entry(ctx, body)

      scope = import_scope(ctx, ctx.station, ctx.run, observations(ctx))
      expect_reply(tool_calls_reply([{"call_1", "get_observation_provenance", ~s({})}]))

      expect_reply(text_reply("One accepted measurement."))

      entry = run_turn(scope, "What measurements have staff accepted?")

      assert entry.status == :done
      assert entry.activity == ["Read accepted measurement provenance"]

      request = tool_request()
      result = request_tool_result(request)

      assert result["counts"] == %{"submitted" => 2, "accepted" => 2, "rejected" => 0}

      assert [w14, w12] = result["observations"]
      assert w14["normalized_value"] == "1.05"
      assert w14["original_value"] == "105"
      assert w14["unit"] == "cm"
      assert w14["meaning"] == "minimum_clear_width"
      assert w14["captured_date"] == "2026-09-18"
      assert w12["normalized_value"] == "1.2"
      assert w12["conflict"] == true

      assert [evidence] = entry.evidence
      assert evidence.kind == "station_observation_provenance"
      assert evidence.total == 2

      encoded = Jason.encode!(request)
      refute encoded =~ body
      refute encoded =~ ctx.editor.email
    end

    test "a prepared selection names no approval and changes nothing", ctx do
      expect_reply(
        tool_calls_reply([{"call_1", "prepare_station_import_decisions", @prepare_w14}])
      )

      expect_reply(text_reply(@final_text))

      entry = run_turn(ctx.scope, "Prepare PW_W14; we measured 105 cm.")

      assert entry.status == :done
      assert entry.activity == ["Prepared accepted width decisions for review"]

      result = tool_result()

      # Exactly one row is prepared: W12's disputed width is unresolved.
      assert [selected] = result["selected"]
      assert selected["decision_id"] == "pathway:PW_W14"
      assert selected["uploaded_value"] == "1.05"
      assert selected["observation"]["source_ref"] == "OBS88"

      assert result["unresolved"] == [
               %{"decision_id" => "pathway:PW_W12", "reason" => "no_accepted_observation"}
             ]

      assert result["counts"]["selected"] == 1

      # The prepared command is the review the native host opens: a run, a
      # station, the preparation's own digest and each row's decision digest. It
      # carries no operation that could approve or apply anything.
      command = entry.prepared.command

      assert command.kind == :station_import_selection
      assert command.run_id == ctx.run.id
      assert command.station_id == ctx.station.id
      assert command.input_digest == result["input_digest"]
      assert command.source_digest =~ ~r/\A[0-9a-f]{64}\z/

      assert command.decisions == [
               %{
                 "decision_id" => "pathway:PW_W14",
                 "decision_digest" => selected["decision_digest"]
               }
             ]

      refute Jason.encode!(command) =~ "approve"
      refute Jason.encode!(command) =~ "confirm_observation_selection"
      refute Jason.encode!(command) =~ "set_decision_status"
      refute Jason.encode!(command) =~ "request_apply"
      refute Jason.encode!(command) =~ "apply"

      assert [evidence] = entry.evidence
      assert evidence.kind == "station_import_selection"
      assert evidence.total == 1
      assert evidence.digest == result["input_digest"]

      # Preparing changed no status, no run metadata and no GTFS row (INV-2).
      assert persisted_state(ctx) == ctx.before
    end

    test "a run with no accepted observation is a summary, not an empty review", ctx do
      scope = import_scope(ctx, ctx.station, ctx.run, [])

      expect_reply(
        tool_calls_reply([{"call_1", "prepare_station_import_decisions", @prepare_w14}])
      )

      expect_reply(text_reply("No measurements have been accepted here."))

      entry = run_turn(scope, "Prepare the width review.")

      assert entry.status == :done

      result = tool_result()
      assert result["selected"] == []
      assert result["counts"]["selected"] == 0

      # Nothing was prepared for a person to confirm, so no review is offered.
      assert is_nil(entry.prepared)
      assert persisted_state(ctx) == ctx.before
    end
  end

  describe "the dispatch fence" do
    setup ctx do
      run = width_run(ctx)

      Map.merge(ctx, %{
        scope: import_scope(ctx, ctx.station, run, observations(ctx)),
        run: run
      })
    end

    test "a forged identity, observation or approval argument is refused", %{scope: scope} do
      for {tool, arguments} <- [
            {"get_station_import_diff", ~s({"station_id":"#{Ecto.UUID.generate()}"})},
            {"get_station_import_diff", ~s({"change_run_id":"#{Ecto.UUID.generate()}"})},
            {"get_station_import_diff", ~s({"sql":"update pathways"})},
            {"get_observation_provenance", ~s({"observations":[]})},
            {"get_observation_provenance", ~s({"source_ref":"OBS88"})},
            {"prepare_station_import_decisions", ~s({"decision_ids":[],"approve":true})},
            {"prepare_station_import_decisions",
             ~s({"decision_ids":["pathway:PW_W14"],"status":"approved"})},
            {"prepare_station_import_decisions", ~s({"decision_ids":{"0":"pathway:PW_W14"}})}
          ] do
        assert {:tool_error, message} = Dispatch.call(StationImports, scope, tool, arguments)

        assert message =~ "Unexpected argument" or message =~ "must be an array"
      end
    end

    test "a missing, empty or over-long decision list is refused", %{scope: scope} do
      for arguments <- [
            ~s({}),
            ~s({"decision_ids":[]}),
            ~s({"decision_ids":["pathway:PW_W14","pathway:PW_W14"]}),
            ~s({"decision_ids":[7]}),
            ~s({"decision_ids":["#{String.duplicate("x", 513)}"]})
          ] do
        assert {:tool_error, _message} =
                 Dispatch.call(
                   StationImports,
                   scope,
                   "prepare_station_import_decisions",
                   arguments
                 )
      end

      too_many =
        Jason.encode!(%{
          "decision_ids" => Enum.map(1..101, &"pathway:PW_#{&1}")
        })

      assert {:tool_error, message} =
               Dispatch.call(StationImports, scope, "prepare_station_import_decisions", too_many)

      assert message =~ "100"
    end

    test "a decision outside this station is excluded, never answered", %{scope: scope} do
      assert {:ok, result, _evidence} =
               StationImports.call(
                 "prepare_station_import_decisions",
                 %{"decision_ids" => ["pathway:PW_CROSS"]},
                 scope
               )

      assert result["selected"] == []

      assert result["excluded"] == [
               %{"decision_id" => "pathway:PW_CROSS", "reason" => "not_a_station_decision"}
             ]

      refute Jason.encode!(result) =~ "0.8"
    end

    test "an unknown tool is refused", %{scope: scope} do
      assert {:tool_error, message} =
               Dispatch.call(StationImports, scope, "apply_import_decisions", ~s({}))

      assert message =~ "Unknown tool"
    end
  end

  describe "the pack's own precondition" do
    setup ctx do
      run = width_run(ctx)

      Map.merge(ctx, %{
        scope: import_scope(ctx, ctx.station, run, observations(ctx)),
        run: run
      })
    end

    test "a run that is not a computed review of this version is unavailable", ctx do
      # `create_pending_compute/4` returns the version's active run rather than a
      # second one, so the still-computing run gets its own version and station.
      pending_version = gtfs_version_fixture(ctx.organization.id)
      level_fixture(ctx.organization.id, pending_version.id, %{level_id: "L1"})

      pending_station =
        station_stop(ctx.organization.id, pending_version.id, "STATION_A", "L1")

      pending_run = create_pending_run(ctx, pending_version.id)

      for {label, scope} <- [
            {"a run still computing",
             import_scope(ctx, pending_station, pending_run, observations(ctx),
               version_id: pending_version.id
             )},
            {"another version's run",
             import_scope(ctx, ctx.station, ctx.run, observations(ctx),
               version_id: ctx.other_version.id
             )},
            {"an unknown run",
             import_scope(ctx, ctx.station, %{id: Ecto.UUID.generate()}, observations(ctx))}
          ] do
        assert {:error, :unavailable} = StationImports.authorize_context(scope), label

        assert {:error, :unavailable} =
                 Dispatch.call(StationImports, scope, "get_station_import_diff", @diff_arguments),
               label
      end

      # Another organization's run reached through this organization and version
      # is unavailable too, because the scoped read finds nothing.
      assert {:error, :unavailable} =
               StationImports.authorize_context(
                 import_scope(
                   ctx,
                   ctx.station,
                   %{id: Ecto.UUID.generate()},
                   observations(ctx)
                 )
               )
    end

    test "another station's own page reads its own empty projection", ctx do
      # Another station in the same version is not a foreign resource: its own
      # preconditions hold, and the projection is what finds no decision of that
      # station in this run. The answer is empty and names none of this
      # station's rows.
      scope = import_scope(ctx, ctx.other_station, ctx.run, observations(ctx))

      # The conversation itself opens: the station is this page's own, top-level
      # station and the run is its computed review.
      assert :ok = StationImports.authorize_context(scope)

      assert {:ok, result, _evidence} =
               Dispatch.call(StationImports, scope, "get_station_import_diff", @diff_arguments)

      assert result["counts"]["station_total"] == 0
      assert result["decisions"] == []
      refute Jason.encode!(result) =~ "PW_W14"
    end

    test "another version and another organization are unavailable", ctx do
      assert {:error, :unavailable} =
               StationImports.authorize_context(
                 import_scope(ctx, ctx.station, ctx.run, observations(ctx),
                   version_id: ctx.other_version.id
                 )
               )

      foreign_version = gtfs_version_fixture(ctx.foreign_organization.id)
      level_fixture(ctx.foreign_organization.id, foreign_version.id, %{level_id: "L1"})

      foreign_station =
        station_stop(ctx.foreign_organization.id, foreign_version.id, "STATION_A", "L1")

      # A real editor of the foreign organization: a membership of this one would
      # be refused as `:forbidden` before the station was ever examined.
      foreign = GtfsPlanner.Organizations.get_organization!(ctx.foreign_organization.id)
      user = editor_fixture(foreign)

      {:ok, resource_context} =
        Scope.context({:version, foreign_version.id})
        |> Scope.with_source_snapshot(%{
          kind: "station_imports",
          payload: %{
            "station_id" => foreign_station.id,
            "station_stop_id" => foreign_station.stop_id,
            "change_run_id" => ctx.run.id,
            "observations" => observations(ctx)
          }
        })

      scope = %Scope{
        organization_id: ctx.foreign_organization.id,
        gtfs_version_id: foreign_version.id,
        user_id: user.id,
        user_email: user.email,
        pack_id: "station_imports",
        version_name: "Foreign",
        resource_context: resource_context
      }

      assert {:error, :unavailable} = StationImports.authorize_context(scope)
    end

    test "a results source and a malformed payload are unavailable", ctx do
      {:ok, results_context} =
        Scope.context({:version, ctx.version.id})
        |> Scope.with_source_snapshot(%{
          kind: "station_results",
          payload: %{
            "station_id" => ctx.station.id,
            "station_stop_id" => ctx.station.stop_id,
            "run_id" => ctx.run.id
          }
        })

      results_scope = %{scope_base(ctx) | resource_context: results_context}

      assert {:error, :unavailable} = StationImports.authorize_context(results_scope)

      assert {:error, :unavailable} =
               Dispatch.call(
                 StationImports,
                 results_scope,
                 "get_station_import_diff",
                 @diff_arguments
               )

      for payload <- [
            %{"station_id" => ctx.station.id, "station_stop_id" => ctx.station.stop_id},
            %{
              "station_id" => "not-a-uuid",
              "station_stop_id" => ctx.station.stop_id,
              "change_run_id" => ctx.run.id
            },
            %{
              "station_id" => ctx.station.id,
              "station_stop_id" => ctx.station.stop_id,
              "change_run_id" => Ecto.UUID.generate()
            }
          ] do
        assert {:ok, resource_context} =
                 Scope.context({:version, ctx.version.id})
                 |> Scope.with_source_snapshot(%{kind: "station_imports", payload: payload})

        assert {:error, :unavailable} =
                 StationImports.authorize_context(%{
                   scope_base(ctx)
                   | resource_context: resource_context
                 })
      end
    end

    test "a revoked membership stops the request and the read", ctx do
      deactivate_membership_fixture(ctx.membership)

      # The pack's own check says unavailable; Dispatch refuses earlier, at the
      # scope's membership check, with forbidden.
      assert {:error, :unavailable} = StationImports.authorize_context(ctx.scope)

      assert {:error, :forbidden} =
               Dispatch.call(
                 StationImports,
                 ctx.scope,
                 "get_station_import_diff",
                 @diff_arguments
               )

      assert {:error, :forbidden} = Agents.open(ctx.scope)
    end

    test "observations the model did not supply cannot change the frozen set", ctx do
      # The frozen rows are W14 accepted at 105 cm and W12 disputed at 120 cm.
      # A model that asks for a different value still gets the frozen answer.
      assert {:ok, result, _evidence} =
               StationImports.call(
                 "get_observation_provenance",
                 %{"observations" => [observation("FORGED", "PW_W14", "9.99", "m")]},
                 ctx.scope
               )

      assert Enum.map(result["observations"], & &1["source_ref"]) == ["OBS88", "OBS91"]
      assert Enum.all?(result["observations"], &(&1["original_value"] != "9.99"))
    end

    test "the native compute path yields the same selection", ctx do
      # `create_pending_compute/4` returns the version's active run, so the
      # setup's hand-written review is removed before the real compute.
      Repo.delete!(ctx.run)

      run = native_compute_run(ctx)
      scope = import_scope(ctx, ctx.station, run, observations(ctx))

      assert {:prepared, _prepared, result, _evidence} =
               Dispatch.call(
                 StationImports,
                 scope,
                 "prepare_station_import_decisions",
                 ~s({"decision_ids":["pathway:PW_W14"]})
               )

      assert [selected] = result["selected"]
      assert selected["decision_id"] == "pathway:PW_W14"
      assert selected["uploaded_value"] == "1.05"
      assert is_binary(selected["decision_digest"])
    end
  end

  ## Helpers

  # Everything preparation must leave alone, compared before and after: each
  # decision's status and uploaded values, the run's state and manifest, the
  # pathway rows and the journal.
  defp persisted_state(ctx) do
    %{
      decisions:
        Repo.all(
          from(d in ChangeDecision,
            join: r in ChangeRun,
            on: r.id == d.change_run_id,
            where: r.gtfs_version_id == ^ctx.version.id,
            select: {d.decision_id, d.status, d.uploaded_values, d.user_edited},
            order_by: d.decision_id
          )
        ),
      runs:
        Repo.all(
          from(r in ChangeRun,
            where: r.gtfs_version_id == ^ctx.version.id,
            select: {r.id, r.state, r.source_manifest},
            order_by: r.id
          )
        ),
      pathways:
        Gtfs.list_pathways(ctx.organization.id, ctx.version.id)
        |> Enum.map(&{&1.pathway_id, &1.min_width, &1.updated_at})
        |> Enum.sort(),
      journal: Repo.all(from(e in JournalEntry, select: {e.id, e.body, e.updated_at}))
    }
  end

  defp observations(_ctx) do
    [
      observation("OBS88", "PW_W14", "105", "cm"),
      Map.merge(observation("OBS91", "PW_W12", "120", "cm"), %{"conflict" => true})
    ]
  end

  defp observation(source_ref, pathway_id, value, unit) do
    %{
      "source_ref" => source_ref,
      "source_revision" => nil,
      "target" => %{"pathway_id" => pathway_id},
      "field" => "min_width",
      "original_value" => value,
      "unit" => unit,
      "captured_date" => "2026-09-18",
      "meaning" => "minimum_clear_width",
      "accepted" => true,
      "conflict" => false
    }
  end

  # The host builds the snapshot from the station, run and observations it
  # resolved; the pack only ever reads them back.
  defp import_scope(ctx, station, run, observations, opts \\ []) do
    version_id = Keyword.get(opts, :version_id, ctx.version.id)

    {:ok, resource_context} =
      Scope.context({:version, version_id})
      |> Scope.with_source_snapshot(%{
        kind: "station_imports",
        payload: %{
          "station_id" => station.id,
          "station_stop_id" => station.stop_id,
          "change_run_id" => run_id(run),
          "observations" => observations,
          "observations_digest" => StationAssistant.observations_digest(observations)
        }
      })

    %{scope_base(ctx) | resource_context: resource_context, gtfs_version_id: version_id}
  end

  defp run_id(%{id: id}) when is_binary(id), do: id
  defp run_id(id) when is_binary(id), do: id

  defp scope_base(ctx) do
    %Scope{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      user_id: ctx.editor.id,
      user_email: ctx.editor.email,
      pack_id: "station_imports",
      version_name: ctx.version.name,
      resource_context: Scope.context({:version, ctx.version.id})
    }
  end

  # One run holding the two width decisions, the endpoint decision PW_W14 depends
  # on, and one cross-station pathway that must stay out of this station's
  # answer. Every decision is written out here so the expected selection does not
  # depend on the diff engine's own choices.
  defp width_run(ctx) do
    {:ok, platform_fingerprint} =
      ChangeDecisionSerializer.record_fingerprint(:stop, ctx.platform, ["stop_name"])

    review = %{
      decisions: [
        decision("pathway:PW_W14", :pathway, :modify, "PW_W14",
          current: %{"from_stop_id" => "ENT_A", "to_stop_id" => "PLAT_A", "min_width" => "0.95"},
          uploaded: %{"from_stop_id" => "ENT_A", "to_stop_id" => "PLAT_A", "min_width" => "1.05"}
        ),
        decision("pathway:PW_W12", :pathway, :modify, "PW_W12",
          current: %{"from_stop_id" => "ENT_A", "to_stop_id" => "PLAT_A", "min_width" => "1.1"},
          uploaded: %{"from_stop_id" => "ENT_A", "to_stop_id" => "PLAT_A", "min_width" => "1.2"}
        ),
        decision("pathway:PW_CROSS", :pathway, :modify, "PW_CROSS",
          current: %{"from_stop_id" => "ENT_A", "to_stop_id" => "PLAT_B", "min_width" => "0.8"},
          uploaded: %{"from_stop_id" => "ENT_A", "to_stop_id" => "PLAT_B", "min_width" => "0.9"}
        ),
        decision("stop:PLAT_A", :stop, :modify, "PLAT_A",
          current: %{"stop_name" => "Platform A"},
          uploaded: %{"stop_name" => "Platform A renamed"},
          fingerprint: platform_fingerprint
        )
      ],
      summary: %{applicable: 4, modify: 4},
      diagnostics: []
    }

    persist_review(ctx, staged_files("stops.txt", 12) ++ staged_files("pathways.txt", 20), review)
  end

  defp create_pending_run(ctx, version_id) do
    {:ok, run} =
      ChangeRuns.create_pending_compute(
        ctx.organization.id,
        version_id || ctx.version.id,
        actor(ctx),
        staged_files("stops.txt", 12)
      )

    run
  end

  defp persist_review(ctx, manifest, review) do
    {:ok, run} =
      ChangeRuns.create_pending_compute(
        ctx.organization.id,
        ctx.version.id,
        actor(ctx),
        manifest
      )

    {:ok, claimed, generation, token} =
      ChangeRuns.claim(ctx.organization.id, run.id, :compute)

    {:ok, _review} =
      ChangeRuns.persist_review(ctx.organization.id, run.id, generation, token, review)

    claimed
  end

  # The default production compute: staged artifacts and the real worker over
  # them. Nothing about the answer is assigned here.
  defp native_compute_run(ctx) do
    root = Path.join(System.tmp_dir!(), "ai07-imports-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    files = [
      %{filename: "stops.txt", content: stops_csv(ctx)},
      %{filename: "pathways.txt", content: pathways_csv(ctx)}
    ]

    run_id = Ecto.UUID.generate()

    assert {:ok, manifest} =
             ChangeArtifactStorage.stage(
               ctx.organization.id,
               ctx.version.id,
               run_id,
               files,
               root: root
             )

    {:ok, run} =
      ChangeRuns.create_pending_compute(
        ctx.organization.id,
        ctx.version.id,
        actor(ctx),
        manifest,
        run_id
      )

    {:ok, claimed, generation, token} =
      ChangeRuns.claim(ctx.organization.id, run.id, :compute)

    assert :ok = ChangeWorker.compute(claimed, generation, token, ChangeRuns.topic(run.id))

    Repo.reload!(run)
  end

  defp stops_csv(ctx) do
    rows =
      Gtfs.list_stops(ctx.organization.id, ctx.version.id)
      |> Enum.map(fn stop ->
        [
          stop.stop_id,
          stop.stop_name,
          stop.stop_desc || "",
          to_string(stop.stop_lat),
          to_string(stop.stop_lon),
          to_string(stop.location_type || 0),
          to_string(stop.wheelchair_boarding || 0),
          stop.platform_code || "",
          stop.level_id || "",
          stop.parent_station || ""
        ]
      end)

    csv(
      [
        "stop_id",
        "stop_name",
        "stop_desc",
        "stop_lat",
        "stop_lon",
        "location_type",
        "wheelchair_boarding",
        "platform_code",
        "level_id",
        "parent_station"
      ],
      rows
    )
  end

  defp pathways_csv(ctx) do
    widths = %{"PW_W12" => "1.2", "PW_W14" => "1.05", "PW_CROSS" => "0.9"}

    rows =
      Gtfs.list_pathways(ctx.organization.id, ctx.version.id)
      |> Enum.map(fn pathway ->
        [
          pathway.pathway_id,
          to_string(pathway.pathway_mode),
          "1",
          to_string(pathway.traversal_time || ""),
          pathway.from_stop_id,
          pathway.to_stop_id,
          Map.get(widths, pathway.pathway_id) || to_string(pathway.min_width)
        ]
      end)

    csv(
      [
        "pathway_id",
        "pathway_mode",
        "is_bidirectional",
        "traversal_time",
        "from_stop_id",
        "to_stop_id",
        "min_width"
      ],
      rows
    )
  end

  defp csv(header, rows) do
    Enum.join([Enum.join(header, ",") | Enum.map(rows, &Enum.join(&1, ","))], "\n") <> "\n"
  end

  defp decision(id, entity_type, action, natural_key, opts) do
    current = Keyword.get(opts, :current, %{})
    uploaded = Keyword.get(opts, :uploaded, %{})

    %{
      serializer_version: 1,
      decision_id: id,
      entity_type: entity_type,
      action: action,
      status: Keyword.get(opts, :status, :pending),
      natural_key: natural_key,
      current_values: current,
      uploaded_values: uploaded,
      changed_fields: changed_fields(current, uploaded),
      dependency_keys: Keyword.get(opts, :dependencies, []),
      current_fingerprint: Keyword.get(opts, :fingerprint),
      user_edited: false
    }
  end

  defp changed_fields(current, uploaded) do
    for {field, before} <- current,
        Map.has_key?(uploaded, field),
        Map.get(uploaded, field) != before do
      %{"field" => field, "before" => before, "after" => Map.get(uploaded, field)}
    end
  end

  defp actor(ctx), do: %{id: ctx.editor.id, email: ctx.editor.email}

  defp staged_files(name, size),
    do: [%{name: name, size: size, sha256: String.duplicate("a", 64)}]

  defp station_stop(organization_id, version_id, stop_id, level_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: stop_id,
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

  # A real journal entry, created through the production sync path a station host
  # uses, so the prose the projection must never carry is genuinely persisted.
  defp journal_entry(ctx, body) do
    {:ok, scope} =
      Gtfs.resolve_station_journal_scope(
        ctx.organization.id,
        ctx.version.id,
        ctx.station.id,
        ctx.editor.id
      )

    id = Ecto.UUID.generate()

    assert %{synced_count: 1, errors: []} =
             Gtfs.sync_journal_entries(scope, [
               %{
                 id: id,
                 target_type: "station",
                 body: body,
                 captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
               }
             ])

    Repo.get!(JournalEntry, id)
  end

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

  defp tool_result, do: tool_request() |> request_tool_result()

  # The first provider request that replays a tool message.
  defp tool_request do
    assert_receive {:model_request, request}, 5_000

    case tool_messages(request) do
      [] -> tool_request()
      _messages -> request
    end
  end

  defp request_tool_result(request) do
    request |> tool_messages() |> List.last() |> Map.fetch!("content") |> Jason.decode!()
  end

  defp tool_messages(request) do
    Enum.filter(request["messages"] || [], &(&1["role"] == "tool"))
  end
end
