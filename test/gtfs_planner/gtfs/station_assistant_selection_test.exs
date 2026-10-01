defmodule GtfsPlanner.Gtfs.StationAssistantSelectionTest do
  @moduledoc """
  EV-4: normalizing accepted field observations and preparing a complete,
  matching native review selection - with nothing written.

  The recorded pairs are hand-enumerated: W14's accepted 105 cm measurement and
  W12's disputed width are written out here with their expected outcome, so the
  answer is compared against a stated expectation rather than against whatever
  the diff engine produced. The last case runs the default native compute -
  `ChangeWorker` over staged artifacts and `ChangeReview` over uploaded files - so
  the same selection is reached over decisions this module never authored.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeArtifactStorage
  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.ChangeDecisionSerializer
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Import.ChangeRuns
  alias GtfsPlanner.Gtfs.Import.ChangeWorker
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.StationAssistant
  alias GtfsPlanner.Repo

  import Ecto.Query

  setup do
    organization = organization_fixture()
    editor = editor_fixture(organization)
    membership = organization_membership_fixture(editor, organization)
    version = gtfs_version_fixture(organization.id)

    level = level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})
    other_level = level_fixture(organization.id, version.id, %{level_id: "L2", level_index: 1.0})

    station = station_stop(organization.id, version.id, "STATION_A", "L1")
    entrance = child_stop(organization.id, version.id, station, "ENT_A", "L1", "Entrance A")
    platform = child_stop(organization.id, version.id, station, "PLAT_A", "L1", "Platform A")

    other_station = station_stop(organization.id, version.id, "STATION_B", "L2")

    other_platform =
      child_stop(organization.id, version.id, other_station, "PLAT_B", "L2", "Platform B")

    w12 =
      pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_W12",
        pathway_mode: 1,
        min_width: Decimal.new("1.10")
      })

    w14 =
      pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_W14",
        pathway_mode: 1,
        min_width: Decimal.new("0.95")
      })

    %{
      organization: organization,
      editor: editor,
      membership: membership,
      version: version,
      level: level,
      other_level: other_level,
      station: station,
      entrance: entrance,
      platform: platform,
      other_station: other_station,
      other_platform: other_platform,
      w12: w12,
      w14: w14
    }
  end

  describe "normalize_observations/2" do
    test "105 cm converts to exactly 1.05 m and the answer carries provenance only", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      assert {:ok, result, evidence} =
               StationAssistant.normalize_observations(scope, frozen(ctx, scope))

      assert result["counts"] == %{"submitted" => 1, "accepted" => 1, "rejected" => 0}

      assert [normalized] = result["observations"]
      assert normalized["normalized_value"] == "1.05"
      assert normalized["original_value"] == "105"
      assert normalized["unit"] == "cm"
      assert normalized["field"] == "min_width"
      assert normalized["meaning"] == "minimum_clear_width"
      assert normalized["captured_date"] == "2026-09-18"
      assert normalized["target"] == %{"pathway_id" => "PW_W14"}
      assert normalized["accepted"] == true
      assert normalized["conflict"] == false
      assert normalized["journal_backed"] == false
      assert is_nil(normalized["source_revision"])
      assert is_nil(normalized["source_digest"])

      assert evidence.kind == "station_observation_provenance"
      assert evidence.total == 1
      assert evidence.completeness == :complete
      assert is_binary(evidence.digest)

      # No free-form prose, author identity or photo ever enters the answer.
      refute Jason.encode!(result) =~ "body"
      refute Jason.encode!(result) =~ ctx.editor.email
    end

    test "m, cm and mm convert exactly and a float-shaped value is refused", ctx do
      run = width_run(ctx)

      for {value, unit, expected} <- [
            {"1.05", "m", "1.05"},
            {"1050", "mm", "1.05"},
            {"105.0", "cm", "1.05"},
            {"0.95", "m", "0.95"}
          ] do
        scope =
          selection_scope(ctx, ctx.station, run, [observation("OBS", "PW_W14", value, unit)])

        assert {:ok, result, _evidence} =
                 StationAssistant.normalize_observations(scope, frozen(ctx, scope))

        assert [%{"normalized_value" => ^expected}] = result["observations"]
      end

      # 1.050 m and 1.05 m are the same width, and neither is a different width
      # from 105 cm.
      equal =
        selection_scope(ctx, ctx.station, run, [
          observation("A", "PW_W14", "1.050", "m"),
          observation("B", "PW_W14", "105", "cm")
        ])

      assert {:ok, result, _evidence} =
               StationAssistant.normalize_observations(equal, frozen(ctx, equal))

      # Identical duplicates collapse; they are not a disagreement.
      assert result["counts"]["accepted"] == 1

      assert result["observations"] == [
               %{(result["observations"] |> hd()) | "source_ref" => "A"}
             ]

      # Two accepted rows that disagree about the same target both fail.
      conflict =
        selection_scope(ctx, ctx.station, run, [
          observation("A", "PW_W14", "1.05", "m"),
          observation("B", "PW_W14", "1.20", "m")
        ])

      assert {:ok, conflicting, _evidence} =
               StationAssistant.normalize_observations(conflict, frozen(ctx, conflict))

      assert conflicting["observations"] == []
      assert conflicting["counts"]["rejected"] == 2
      assert Enum.all?(conflicting["rejected"], &(&1["reason"] == "conflicting_duplicate"))
    end

    test "only min_width with minimum clear width meaning in m/cm/mm converts", ctx do
      run = width_run(ctx)

      for {overrides, reason} <- [
            [%{"unit" => "ft"}, "unsupported_unit"],
            [%{"unit" => nil}, "unsupported_unit"],
            [%{"meaning" => "width"}, "missing_meaning"],
            [%{"meaning" => nil}, "missing_meaning"],
            [%{"field" => "length"}, "unsupported_field"],
            [%{"original_value" => "0"}, "nonpositive_value"],
            [%{"original_value" => "-1.05"}, "nonpositive_value"],
            [%{"original_value" => "wide"}, "invalid_value"],
            [%{"original_value" => "1.05 m"}, "invalid_value"],
            [%{"captured_date" => "18/09/2026"}, "invalid_captured_date"],
            [%{"accepted" => "yes"}, "invalid_boolean"],
            [%{"conflict" => 1}, "invalid_boolean"],
            [%{"source_ref" => ""}, "invalid_source_ref"],
            [%{"source_ref" => String.duplicate("x", 513)}, "invalid_source_ref"],
            [%{"source_revision" => String.duplicate("r", 129)}, "invalid_source_revision"],
            [%{"target" => %{"pathway_id" => ""}}, "invalid_target"],
            [%{"target" => %{"pathway_id" => String.duplicate("p", 256)}}, "invalid_target"],
            [%{"target" => %{"stop_id" => "PLAT_A"}}, "invalid_target"],
            [%{"extra" => "field"}, "unknown_field"]
          ] do
        scope =
          selection_scope(ctx, ctx.station, run, [
            Map.merge(observation("OBS", "PW_W14", "105", "cm"), overrides)
          ])

        assert {:ok, result, _evidence} =
                 StationAssistant.normalize_observations(scope, frozen(ctx, scope))

        assert result["observations"] == [], "expected #{reason} to fail the row"
        assert [%{"reason" => ^reason}] = result["rejected"]
      end
    end

    test "a malformed row fails alone and the other measurement survives", ctx do
      run = width_run(ctx)

      rows = [
        observation("OBS88", "PW_W14", "105", "cm"),
        Map.put(observation("OBS89", "PW_W12", "120", "ft"), "field", "max_slope")
      ]

      scope = selection_scope(ctx, ctx.station, run, rows)

      assert {:ok, result, _evidence} =
               StationAssistant.normalize_observations(scope, frozen(ctx, scope))

      assert result["counts"] == %{"submitted" => 2, "accepted" => 1, "rejected" => 1}
      assert [%{"source_ref" => "OBS88", "normalized_value" => "1.05"}] = result["observations"]
      assert [%{"source_ref" => "OBS89", "reason" => "unsupported_field"}] = result["rejected"]
    end

    test "a journal-backed reference freezes revision and digest without the body", ctx do
      run = width_run(ctx)
      entry = journal_entry(ctx, "Bench clearance measured at the fare array.")

      scope =
        selection_scope(ctx, ctx.station, run, [
          Map.put(observation(entry.id, "PW_W14", "105", "cm"), "source_revision", nil)
        ])

      assert {:ok, result, _evidence} =
               StationAssistant.normalize_observations(scope, frozen(ctx, scope))

      assert [normalized] = result["observations"]
      assert normalized["journal_backed"] == true
      assert normalized["source_revision"] == DateTime.to_iso8601(entry.updated_at)
      assert is_binary(normalized["source_digest"])

      # The entry's free text is evidence for a person, not a measurement.
      encoded = Jason.encode!(result)
      refute encoded =~ "fare array"
      refute encoded =~ ctx.editor.email
    end

    test "a journal reference from another station, and a wrong revision, both fail", ctx do
      run = width_run(ctx)
      foreign = journal_entry(ctx, "Other station note.", station: ctx.other_station)
      own = journal_entry(ctx, "Own station note.")

      foreign_scope =
        selection_scope(ctx, ctx.station, run, [observation(foreign.id, "PW_W14", "105", "cm")])

      assert {:ok, refused, _evidence} =
               StationAssistant.normalize_observations(foreign_scope, frozen(ctx, foreign_scope))

      assert refused["observations"] == []
      assert [%{"reason" => "foreign_journal_reference"}] = refused["rejected"]

      stale_scope =
        selection_scope(ctx, ctx.station, run, [
          Map.put(
            observation(own.id, "PW_W14", "105", "cm"),
            "source_revision",
            "2020-01-01T00:00:00Z"
          )
        ])

      assert {:ok, stale, _evidence} =
               StationAssistant.normalize_observations(stale_scope, frozen(ctx, stale_scope))

      assert stale["observations"] == []
      assert [%{"reason" => "foreign_journal_reference"}] = stale["rejected"]
    end

    test "a revoked membership, a results source and an oversized batch all refuse", ctx do
      run = width_run(ctx)
      scope = selection_scope(ctx, ctx.station, run, [observation("OBS", "PW_W14", "105", "cm")])

      {:ok, results_context} =
        Scope.context({:version, ctx.version.id})
        |> Scope.with_source_snapshot(%{
          kind: "station_results",
          payload: %{
            "station_id" => ctx.station.id,
            "station_stop_id" => "STATION_A",
            "run_id" => Ecto.UUID.generate()
          }
        })

      assert {:error, :unavailable} =
               StationAssistant.normalize_observations(
                 %{scope_base(ctx) | resource_context: results_context},
                 frozen(ctx, scope)
               )

      assert {:error, :invalid_selection} =
               StationAssistant.normalize_observations(
                 scope,
                 List.duplicate(observation("O", "PW_W14", "105", "cm"), 101)
               )

      assert {:error, :invalid_selection} =
               StationAssistant.normalize_observations(scope, "not-a-list")

      deactivate_membership_fixture(ctx.membership)

      assert {:error, :forbidden} =
               StationAssistant.normalize_observations(scope, frozen(ctx, scope))
    end
  end

  describe "prepare_import_selection/2" do
    test "W14 selects on the exact match and W12's disputed width stays unresolved", ctx do
      run = width_run(ctx)

      observations = [
        accepted_observation("OBS88", "PW_W14", "105", "cm"),
        Map.merge(accepted_observation("OBS91", "PW_W12", "120", "cm"), %{"conflict" => true})
      ]

      scope = selection_scope(ctx, ctx.station, run, observations)

      assert {:ok, result, evidence} =
               StationAssistant.prepare_import_selection(scope, [
                 "pathway:PW_W14",
                 "pathway:PW_W12"
               ])

      assert [%{decision_id: "pathway:PW_W14"} = selected] = result["selected"]

      assert selected["natural_key"] == "PW_W14"
      assert selected["current_value"] == "0.95"
      assert selected["uploaded_value"] == "1.05"
      assert selected["field"] == "min_width"
      assert selected["observation"]["source_ref"] == "OBS88"
      assert selected["observation"]["original_value"] == "105"
      assert selected["observation"]["unit"] == "cm"
      assert selected["observation"]["normalized_value"] == "1.05"
      assert selected["observation"]["captured_date"] == "2026-09-18"

      # W12's row is prepared as unresolved with the reason, and the answer
      # never carries an approval operation of any kind.
      assert result["unresolved"] == [
               %{"decision_id" => "pathway:PW_W12", "reason" => "no_accepted_observation"}
             ]

      assert result["counts"] == %{
               "requested" => 2,
               "selected" => 1,
               "unresolved" => 1,
               "excluded" => 0,
               "existing_approved" => 0,
               "observations" => %{"submitted" => 2, "accepted" => 2, "rejected" => 0}
             }

      assert is_binary(result["input_digest"])
      assert evidence.kind == "station_import_selection"
      assert evidence.total == 1
      assert evidence.digest == result["input_digest"]

      refute Jason.encode!(result) =~ "approve"
      refute Jason.encode!(result) =~ "set_decision_status"
      refute Jason.encode!(result) =~ "request_apply"
    end

    test "a disputed or unaccepted observation is never selected", ctx do
      run = width_run(ctx)

      for flags <- [%{"conflict" => true}, %{"accepted" => false}] do
        scope =
          selection_scope(ctx, ctx.station, run, [
            Map.merge(accepted_observation("OBS91", "PW_W12", "120", "cm"), flags)
          ])

        assert {:ok, result, _evidence} =
                 StationAssistant.prepare_import_selection(scope, ["pathway:PW_W12"])

        assert result["selected"] == []

        assert result["unresolved"] == [
                 %{"decision_id" => "pathway:PW_W12", "reason" => "no_accepted_observation"}
               ]
      end
    end

    test "a mixed endpoint or direction edit stays unresolved even when the width matches", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [
          accepted_observation("OBS88", "PW_W14", "105", "cm")
        ])

      # The width is accepted and exact, but the decision also changes an
      # endpoint, so the whole decision is left to native review.
      set_changed_fields(run, "pathway:PW_W14", [
        %{"field" => "from_stop_id", "before" => "ENT_A", "after" => "PLAT_A"},
        %{"field" => "min_width", "before" => "0.95", "after" => "1.05"}
      ])

      assert {:ok, result, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert result["selected"] == []

      assert result["unresolved"] == [
               %{"decision_id" => "pathway:PW_W14", "reason" => "incomplete_field_coverage"}
             ]

      set_changed_fields(run, "pathway:PW_W14", [
        %{"field" => "is_bidirectional", "before" => "1", "after" => "0"},
        %{"field" => "min_width", "before" => "0.95", "after" => "1.05"}
      ])

      assert {:ok, directed, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert directed["selected"] == []
      assert [%{"reason" => "incomplete_field_coverage"}] = directed["unresolved"]
    end

    test "a pending dependency leaves the decision unresolved and an approved one does not",
         ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [
          accepted_observation("OBS88", "PW_W14", "105", "cm")
        ])

      # PW_W14's endpoint carries a decision in this run, so a width acceptance
      # cannot carry it with it.
      set_dependencies(run, "pathway:PW_W14", ["stop:PLAT_A"])
      approve_or_leave(run, "stop:PLAT_A", :pending)

      assert {:ok, pending, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert pending["selected"] == []

      assert pending["unresolved"] == [
               %{"decision_id" => "pathway:PW_W14", "reason" => "dependency_not_approved"}
             ]

      approve_or_leave(run, "stop:PLAT_A", :approved)

      assert {:ok, approved, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert [%{"decision_id" => "pathway:PW_W14"}] = approved["selected"]
      # The already approved dependency is listed separately, never selected.
      assert approved["existing_approved"] == [
               %{"decision_id" => "stop:PLAT_A", "status" => "approved"}
             ]

      refute Enum.any?(approved["selected"], &(&1["decision_id"] == "stop:PLAT_A"))
    end

    test "a mismatched uploaded width is reported, never rewritten", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [
          accepted_observation("OBS88", "PW_W14", "105", "cm")
        ])

      before = decision_row(run, "pathway:PW_W14")

      assert {:ok, result, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert result["selected"] == []

      assert result["unresolved"] == [
               %{"decision_id" => "pathway:PW_W14", "reason" => "uploaded_value_mismatch"}
             ]

      # The uploaded file is exactly as it was.
      assert decision_row(run, "pathway:PW_W14") == before
      assert before.uploaded_values["min_width"] == "1.05"
      assert ctx.w14.min_width == Decimal.new("0.95")
    end

    test "a drifted, hand-edited, tainted or non-pending decision is unresolved", ctx do
      run = width_run(ctx)

      observations = [accepted_observation("OBS88", "PW_W14", "105", "cm")]
      scope = selection_scope(ctx, ctx.station, run, observations)

      # A record edited natively after the diff was computed reads as drift.
      {:ok, _w14} =
        ctx.w14 |> Ecto.Changeset.change(%{min_width: Decimal.new("0.90")}) |> Repo.update()

      assert {:ok, drifted, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert [%{"reason" => "fingerprint_drift"}] = drifted["unresolved"]

      {:ok, _w14} =
        ctx.w14 |> Ecto.Changeset.change(%{min_width: Decimal.new("0.95")}) |> Repo.update()

      update_decision(run, "pathway:PW_W14", user_edited: true)

      assert {:ok, edited, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert [%{"reason" => "user_edited"}] = edited["unresolved"]

      update_decision(run, "pathway:PW_W14", user_edited: false, status: :approved)

      assert {:ok, approved, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert approved["selected"] == []
      assert [%{"reason" => "not_pending"}] = approved["unresolved"]

      assert approved["existing_approved"] == [
               %{"decision_id" => "pathway:PW_W14", "status" => "approved"}
             ]

      update_decision(run, "pathway:PW_W14", status: :preview)

      assert {:ok, preview, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert [%{"reason" => "not_pending"}] = preview["unresolved"]
    end

    test "a decision outside this station is excluded without probing another station", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [
          accepted_observation("OBS88", "PW_W14", "105", "cm")
        ])

      assert {:ok, result, _evidence} =
               StationAssistant.prepare_import_selection(scope, [
                 "pathway:PW_W14",
                 "pathway:PW_OTHER",
                 "stop:NOT_A_DECISION"
               ])

      assert [%{"decision_id" => "pathway:PW_W14"}] = result["selected"]

      assert result["excluded"] == [
               %{"decision_id" => "pathway:PW_OTHER", "reason" => "not_a_station_decision"},
               %{"decision_id" => "stop:NOT_A_DECISION", "reason" => "not_a_station_decision"}
             ]

      assert result["counts"]["excluded"] == 2
    end

    test "the input digest binds the snapshot, the base source and the observations", ctx do
      run = width_run(ctx)

      observations = [accepted_observation("OBS88", "PW_W14", "105", "cm")]
      scope = selection_scope(ctx, ctx.station, run, observations)

      assert {:ok, first, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert {:ok, again, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert again["input_digest"] == first["input_digest"]

      # A different observation is a different input.
      other_scope =
        selection_scope(ctx, ctx.station, run, [
          accepted_observation("OBS88", "PW_W14", "1.05", "m")
        ])

      assert {:ok, other, _evidence} =
               StationAssistant.prepare_import_selection(other_scope, ["pathway:PW_W14"])

      assert other["input_digest"] != first["input_digest"]

      # A changed base source file is a different input, even though the
      # selected decision is the same one.
      put_source_manifest(run, %{
        "files" => [
          %{"name" => "stops.txt", "size" => 12, "sha256" => String.duplicate("a", 64)},
          %{"name" => "pathways.txt", "size" => 20, "sha256" => String.duplicate("b", 64)}
        ],
        "total_bytes" => 32
      })

      base_before = first["input_digest"]
      put_source_manifest(run, run.source_manifest, String.duplicate("c", 64))

      assert {:ok, refiled, _evidence} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert refiled["input_digest"] != base_before
      assert [%{"decision_id" => "pathway:PW_W14"}] = refiled["selected"]
    end

    test "an edited frozen observation list is refused rather than read", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [
          accepted_observation("OBS88", "PW_W14", "105", "cm")
        ])

      # A snapshot whose recorded observations digest no longer matches the rows
      # it carries yields no accepted observation, so nothing is selected.
      tampered = put_observation_digest(ctx, scope, String.duplicate("0", 64))

      assert {:ok, result, _evidence} =
               StationAssistant.prepare_import_selection(tampered, ["pathway:PW_W14"])

      assert result["selected"] == []
      assert [%{"reason" => "no_accepted_observation"}] = result["unresolved"]
    end

    test "preparing a selection writes nothing", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [
          accepted_observation("OBS88", "PW_W14", "105", "cm"),
          accepted_observation("OBS91", "PW_W12", "120", "cm")
        ])

      before_run = Repo.get!(ChangeRun, run.id)
      before_decisions = decision_snapshot(run)
      before_pathways = pathway_snapshot(ctx)
      before_journal = journal_snapshot()

      assert {:ok, result, _evidence} =
               StationAssistant.prepare_import_selection(scope, [
                 "pathway:PW_W14",
                 "pathway:PW_W12",
                 "pathway:PW_OTHER"
               ])

      assert length(result["selected"]) == 1

      after_run = Repo.get!(ChangeRun, run.id)
      assert after_run.state == before_run.state
      assert after_run.source_manifest == before_run.source_manifest
      assert after_run.summary == before_run.summary
      assert after_run.updated_at == before_run.updated_at

      assert decision_snapshot(run) == before_decisions
      assert pathway_snapshot(ctx) == before_pathways
      assert journal_snapshot() == before_journal
    end

    test "a foreign scope, a duplicate id list and a revoked membership all refuse", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [
          accepted_observation("OBS88", "PW_W14", "105", "cm")
        ])

      foreign = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign.id)

      foreign_station = station_stop(foreign.id, foreign_version.id, "STATION_F", "L1")

      assert {:ok, context} =
               Scope.context({:version, foreign_version.id})
               |> Scope.with_source_snapshot(%{
                 kind: "station_imports",
                 payload: %{
                   "station_id" => foreign_station.id,
                   "station_stop_id" => foreign_station.stop_id,
                   "change_run_id" => run.id
                 }
               })

      assert {:error, :unavailable} =
               StationAssistant.prepare_import_selection(
                 %{scope_base(ctx) | resource_context: context},
                 ["pathway:PW_W14"]
               )

      assert {:error, :invalid_selection} =
               StationAssistant.prepare_import_selection(scope, [
                 "pathway:PW_W14",
                 "pathway:PW_W14"
               ])

      assert {:error, :invalid_selection} =
               StationAssistant.prepare_import_selection(scope, [""])

      assert {:error, :invalid_selection} =
               StationAssistant.prepare_import_selection(scope, [:atom])

      assert {:error, :invalid_selection} =
               StationAssistant.prepare_import_selection(
                 scope,
                 List.duplicate("pathway:PW_W14", 101)
               )

      deactivate_membership_fixture(ctx.membership)

      assert {:error, :forbidden} =
               StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])
    end
  end

  describe "the default native compute" do
    test "decisions this module never authored prepare the same selection", ctx do
      overrides = %{
        stops: %{},
        pathways: %{"PW_W12" => "1.20", "PW_W14" => "1.05"},
        levels: %{}
      }

      run = native_compute_run(ctx, overrides)

      assert {:ok, run} = Repo.reload(run)
      assert run.state == :review

      decisions = ChangeRuns.list_decisions(ctx.organization.id, run.id)

      assert Enum.map(decisions, & &1.decision_id) |> Enum.sort() == [
               "pathway:PW_W12",
               "pathway:PW_W14"
             ]

      scope =
        selection_scope(ctx, ctx.station, run, [
          accepted_observation("OBS88", "PW_W14", "105", "cm"),
          accepted_observation("OBS91", "PW_W12", "120", "cm")
        ])

      assert {:ok, result, _evidence} =
               StationAssistant.prepare_import_selection(scope, [
                 "pathway:PW_W14",
                 "pathway:PW_W12"
               ])

      assert [%{"decision_id" => "pathway:PW_W14", "uploaded_value" => "1.05"}] =
               result["selected"]

      assert result["unresolved"] == [
               %{"decision_id" => "pathway:PW_W12", "reason" => "no_accepted_observation"}
             ]

      # The projection is computed, not transcribed: it agrees with the persisted
      # decision it selected.
      w14 = Enum.find(decisions, &(&1.decision_id == "pathway:PW_W14"))
      assert w14.uploaded_values["min_width"] == "1.05"
      assert w14.status == :pending
    end
  end

  ## Fixtures

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

  defp accepted_observation(source_ref, pathway_id, value, unit),
    do: observation(source_ref, pathway_id, value, unit)

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
      location_type: if(stop_id =~ ~r/^ENT_/, do: 2, else: 0),
      parent_station: station.stop_id,
      level_id: level_id,
      stop_lat: Decimal.new("39.9527"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

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

  # The host builds the snapshot from the station, run and observations it
  # resolved; this projection only ever reads them back.
  defp selection_scope(ctx, station, run, observations) do
    {:ok, resource_context} =
      Scope.context({:version, ctx.version.id})
      |> Scope.with_source_snapshot(%{
        kind: "station_imports",
        payload: %{
          "station_id" => station.id,
          "station_stop_id" => station.stop_id,
          "change_run_id" => run.id,
          "observations" => observations,
          "observations_digest" => StationAssistant.observations_digest(observations)
        }
      })

    %{scope_base(ctx) | resource_context: resource_context}
  end

  # The rows the scope's own frozen snapshot carries, read back through the
  # public accessor, so no fixture asserts against an array the host never set.
  defp frozen(_ctx, scope),
    do: scope.resource_context.source_snapshot.payload["observations"]

  defp put_observation_digest(ctx, scope, digest) do
    payload =
      scope.resource_context.source_snapshot.payload
      |> Map.put("observations_digest", digest)

    {:ok, resource_context} =
      Scope.context({:version, ctx.version.id})
      |> Scope.with_source_snapshot(%{kind: "station_imports", payload: payload})

    %{scope | resource_context: resource_context}
  end

  # One run holding the two width decisions and the endpoint decisions PW_W14
  # depends on, written out here so the expected selection does not depend on the
  # diff engine's own choices.
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
        decision("stop:PLAT_A", :stop, :modify, "PLAT_A",
          current: %{"stop_name" => "Platform A"},
          uploaded: %{"stop_name" => "Platform A renamed"},
          fingerprint: platform_fingerprint
        )
      ],
      summary: %{applicable: 3, modify: 3},
      diagnostics: []
    }

    {:ok, run} =
      ChangeRuns.create_pending_compute(
        ctx.organization.id,
        ctx.version.id,
        actor(ctx),
        staged_files("stops.txt", 12) ++ staged_files("pathways.txt", 20)
      )

    {:ok, claimed, generation, token} =
      ChangeRuns.claim(ctx.organization.id, run.id, :compute)

    {:ok, _review} =
      ChangeRuns.persist_review(ctx.organization.id, run.id, generation, token, review)

    claimed
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

  defp decision_row(run, decision_id) do
    Repo.one!(
      from(d in ChangeDecision,
        where: d.change_run_id == ^run.id and d.decision_id == ^decision_id
      )
    )
  end

  defp update_decision(run, decision_id, attrs) do
    decision_row(run, decision_id)
    |> ChangeDecision.system_changeset(attrs)
    |> Repo.update!()
  end

  defp set_changed_fields(run, decision_id, changed_fields) do
    update_decision(run, decision_id, changed_fields: changed_fields)
  end

  defp set_dependencies(run, decision_id, dependency_keys) do
    update_decision(run, decision_id, dependency_keys: dependency_keys)
  end

  defp approve_or_leave(run, decision_id, status) do
    update_decision(run, decision_id, status: status)
  end

  defp put_source_manifest(run, manifest) do
    run |> Ecto.Changeset.change(%{source_manifest: manifest}) |> Repo.update!()
  end

  defp put_source_manifest(run, manifest, pathway_sha) do
    files =
      manifest
      |> Map.get("files", [])
      |> Enum.map(fn file ->
        if file["name"] == "pathways.txt", do: Map.put(file, "sha256", pathway_sha), else: file
      end)

    run
    |> Ecto.Changeset.change(%{source_manifest: Map.put(manifest, "files", files)})
    |> Repo.update!()
  end

  defp decision_snapshot(run) do
    ChangeRuns.list_decisions(run.organization_id, run.id)
    |> Enum.map(
      &{&1.decision_id, &1.status, &1.uploaded_values, &1.changed_fields, &1.user_edited}
    )
  end

  defp pathway_snapshot(ctx) do
    Gtfs.list_pathways(ctx.organization.id, ctx.version.id)
    |> Enum.map(&{&1.pathway_id, &1.min_width, &1.updated_at})
    |> Enum.sort()
  end

  defp journal_snapshot do
    Repo.all(from(e in JournalEntry, select: {e.id, e.body, e.updated_at})) |> Enum.sort()
  end

  # A real journal entry, created through the production sync path a station host
  # uses, so the reference resolution reads a genuine entry.
  defp journal_entry(ctx, body, opts \\ []) do
    station = Keyword.get(opts, :station, ctx.station)

    {:ok, scope} =
      Gtfs.resolve_station_journal_scope(
        ctx.organization.id,
        ctx.version.id,
        station.id,
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

  # The default production compute: staged artifacts, the real worker and the
  # real review over uploaded files. Nothing about the answer is assigned here.
  defp native_compute_run(ctx, overrides) do
    root = Path.join(System.tmp_dir!(), "ai07-selection-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)
    run_id = Ecto.UUID.generate()

    files = [
      %{filename: "stops.txt", content: stops_csv(ctx, overrides)},
      %{filename: "pathways.txt", content: pathways_csv(ctx, overrides)}
    ]

    on_exit(fn ->
      File.rm_rf(root)

      if previous,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    assert {:ok, manifest} =
             ChangeArtifactStorage.stage(
               ctx.organization.id,
               ctx.version.id,
               run_id,
               files,
               root: root
             )

    assert {:ok, run} =
             ChangeRuns.create_pending_compute(
               ctx.organization.id,
               ctx.version.id,
               actor(ctx),
               manifest,
               run_id
             )

    assert {:ok, claimed, generation, token} =
             ChangeRuns.claim(ctx.organization.id, run.id, :compute)

    assert :ok = ChangeWorker.compute(claimed, generation, token, ChangeRuns.topic(run.id))

    Repo.reload!(run)
  end

  defp stops_csv(ctx, overrides) do
    rows =
      Gtfs.list_stops(ctx.organization.id, ctx.version.id)
      |> Enum.map(fn stop ->
        [
          stop.stop_id,
          Map.get(overrides.stops, stop.stop_id, stop.stop_name),
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

  defp pathways_csv(ctx, overrides) do
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
          Map.get(overrides.pathways, pathway.pathway_id) || to_string(pathway.min_width)
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
end
