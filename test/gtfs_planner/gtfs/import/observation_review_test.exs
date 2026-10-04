defmodule GtfsPlanner.Gtfs.Import.ObservationReviewTest do
  @moduledoc """
  EV-5: confirming selected native decisions and their captured provenance in one
  authorized transaction.

  The decisions here are hand-enumerated rather than produced by the diff engine:
  W14 is a complete `min_width`-only pending pathway change that an accepted
  105 cm measurement matches exactly, W12 is a second width change this station's
  own observations may confirm later, and PW_OTHER belongs to another station.
  Every expected outcome is written out below, so the confirmation is compared
  against a stated expectation rather than against whatever the run happens to
  hold.

  Each case prepares through the ordinary host path -
  `GtfsPlanner.Agents.Scope.with_source_snapshot/2` then
  `StationAssistant.prepare_import_selection/2` - and confirms through
  `ChangeRuns.confirm_observation_selection/5`. No run, decision, manifest,
  membership or snapshot assign is written by hand except where a case is about a
  manifest that native confirmation itself produced.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Import.ChangeArtifactStorage
  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.ChangeDecisionSerializer
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Import.ChangeRunReview
  alias GtfsPlanner.Gtfs.Import.ChangeRuns
  alias GtfsPlanner.Gtfs.StationAssistant
  alias GtfsPlanner.Repo

  import Ecto.Query

  setup do
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
    other_platform = child_stop(organization.id, version.id, other_station, "PLAT_B", "L2", "B")

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_W12",
      pathway_mode: 1,
      min_width: Decimal.new("1.10")
    })

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_W14",
      pathway_mode: 1,
      min_width: Decimal.new("0.95")
    })

    pathway_fixture(
      organization.id,
      version.id,
      other_platform.stop_id,
      other_platform.stop_id,
      %{
        pathway_id: "PW_OTHER",
        pathway_mode: 1,
        min_width: Decimal.new("1.00")
      }
    )

    root =
      Path.join(
        System.tmp_dir!(),
        "ai05-observation-review-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    %{
      organization: organization,
      editor: editor,
      membership: membership,
      version: version,
      station: station,
      other_station: other_station,
      root: root
    }
  end

  describe "confirm_observation_selection/5" do
    test "confirms the selected decision and appends its captured provenance", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      {:ok, prepared, _evidence} =
        StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

      assert [%{"decision_id" => "pathway:PW_W14", "decision_digest" => decision_digest}] =
               prepared["selected"]

      before_files = base_files(run)
      staged_bytes = read_staged(run, ctx)

      assert {:ok, %{decisions: decisions, run: confirmed}} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 confirmation(prepared)
               )

      assert confirmed.id == run.id
      assert confirmed.state == :review
      assert Enum.map(decisions, & &1.decision_id) == ["pathway:PW_W14"]
      assert [%ChangeDecision{status: :approved}] = decisions

      # Only the confirmed decision moved. W12 and the stop rename stay pending.
      assert statuses(run) == %{
               "pathway:PW_W12" => :pending,
               "pathway:PW_W14" => :approved,
               "pathway:PW_OTHER" => :pending,
               "stop:PLAT_A" => :pending
             }

      # The original file entries, their hashes and the total survive exactly, and
      # the staged bytes are still readable through the same accessor.
      reloaded = Repo.get!(ChangeRun, run.id)
      assert base_files(reloaded) == before_files
      assert read_staged(reloaded, ctx) == staged_bytes

      # The manifest grew exactly one bounded namespace, beside the base files.
      assert %{"reviewed_evidence" => namespace} = reloaded.source_manifest
      assert namespace["version"] == 1
      assert [entry] = namespace["entries"]

      assert entry["decision_id"] == "pathway:PW_W14"
      assert entry["decision_digest"] == decision_digest
      assert entry["source_digest"] == ChangeRunReview.base_source_digest(run)
      assert entry["snapshot_digest"] == frozen_source(scope).digest
      assert entry["station_id"] == ctx.station.id
      assert entry["actor_id"] == ctx.editor.id
      assert {:ok, _confirmed_at, _offset} = DateTime.from_iso8601(entry["confirmed_at"])

      assert [observation_entry] = entry["observations"]
      assert observation_entry["target"] == %{"pathway_id" => "PW_W14"}
      assert observation_entry["field"] == "min_width"
      assert observation_entry["meaning"] == "minimum_clear_width"
      assert observation_entry["original_value"] == "105"
      assert observation_entry["normalized_value"] == "1.05"
      assert observation_entry["unit"] == "cm"
      assert observation_entry["captured_date"] == "2026-09-18"
      assert observation_entry["source_ref"] == "OBS88"

      # The stored provenance names no editor email, no journal prose, no storage
      # key and no free text of any kind.
      encoded = Jason.encode!(reloaded.source_manifest["reviewed_evidence"])
      refute encoded =~ ctx.editor.email
      refute encoded =~ "note"
      refute encoded =~ ".source"
    end

    test "confirming the identical selection again adds no history and writes nothing", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      payload = prepared_confirmation(scope, ["pathway:PW_W14"])

      assert {:ok, _result} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      after_first = Repo.get!(ChangeRun, run.id)
      stamps = decision_stamps(run)

      assert {:ok, %{decisions: decisions, run: reconfirmed}} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      assert [%ChangeDecision{status: :approved}] = decisions
      assert length(entries(reconfirmed)) == 1
      assert entries(reconfirmed) == entries(after_first)
      assert base_files(reconfirmed) == base_files(after_first)
      assert decision_stamps(run) == stamps
    end

    test "a stale tab reconfirming an applied decision is refused and leaves it applied", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      payload = prepared_confirmation(scope, ["pathway:PW_W14"])

      assert {:ok, _result} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      # The first tab's confirmation went on to be applied; the run is back in
      # review with the decision recorded as applied.
      update_decision(run, "pathway:PW_W14", status: :applied)
      snapshot = confirmation_snapshot(run)

      assert {:error, :stale} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      assert statuses(run)["pathway:PW_W14"] == :applied
      assert confirmation_snapshot(run) == snapshot
    end

    test "a later confirmation appends and never erases the earlier evidence", ctx do
      run = width_run(ctx)

      w14_scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      assert {:ok, _result} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(w14_scope),
                 prepared_confirmation(w14_scope, ["pathway:PW_W14"])
               )

      [first] = entries(Repo.get!(ChangeRun, run.id))

      # Staff later accept a second measurement for W12, frozen in their own
      # snapshot: this is a new observation, not a rewrite of the first.
      w12_scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS91", "PW_W12", "120", "cm")])

      assert {:ok, _result} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(w12_scope),
                 prepared_confirmation(w12_scope, ["pathway:PW_W12"])
               )

      confirmed = Repo.get!(ChangeRun, run.id)
      assert [kept, appended] = entries(confirmed)
      assert kept == first
      assert appended["decision_id"] == "pathway:PW_W12"
      assert appended["snapshot_digest"] == frozen_source(w12_scope).digest
      assert appended["source_digest"] == first["source_digest"]

      assert statuses(run)["pathway:PW_W12"] == :approved
      assert statuses(run)["pathway:PW_W14"] == :approved
      assert statuses(run)["stop:PLAT_A"] == :pending
    end

    test "a revoked membership refuses every write and leaves the draft usable", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      payload = prepared_confirmation(scope, ["pathway:PW_W14"])
      before = confirmation_snapshot(run)

      deactivate_membership_fixture(ctx.membership)

      assert {:error, :forbidden} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      assert confirmation_snapshot(run) == before
      assert statuses(run)["pathway:PW_W14"] == :pending
      assert entries(Repo.get!(ChangeRun, run.id)) == []

      # The refused draft is unchanged and still confirms once the editor is an
      # editor again: a refusal retains the host's payload rather than consuming it.
      membership = Repo.get!(GtfsPlanner.Accounts.UserOrgMembership, ctx.membership.id)

      membership
      |> Ecto.Changeset.change(%{deactivated_at: nil})
      |> Repo.update!()

      assert {:ok, %{decisions: [%ChangeDecision{status: :approved}]}} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )
    end

    test "a changed source file, value or status refuses before any write", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      payload = prepared_confirmation(scope, ["pathway:PW_W14"])

      # The upload this review was computed from is no longer the run's source.
      put_source_files(
        run,
        Enum.map(
          base_files(run)["files"],
          &Map.put(&1, "sha256", "c" <> String.slice(&1["sha256"], 1, 63))
        )
      )

      before = confirmation_snapshot(run)

      assert {:error, :stale} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      assert confirmation_snapshot(run) == before

      # A value that is no longer the one staff measured is not this selection.
      put_source_files(run, base_files(run))

      update_decision(run, "pathway:PW_W14",
        uploaded_values: %{
          "from_stop_id" => "ENT_A",
          "to_stop_id" => "PLAT_A",
          "min_width" => "1.4"
        },
        changed_fields: [%{"field" => "min_width", "before" => "0.95", "after" => "1.4"}]
      )

      assert {:error, :invalid_selection} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      assert statuses(run)["pathway:PW_W14"] == :pending
      assert entries(Repo.get!(ChangeRun, run.id)) == []

      # Somebody else approved it natively: our confirmation may not lend its
      # captured provenance to that approval.
      update_decision(run, "pathway:PW_W14", %{
        uploaded_values: %{
          "from_stop_id" => "ENT_A",
          "to_stop_id" => "PLAT_A",
          "min_width" => "1.05"
        },
        changed_fields: [%{"field" => "min_width", "before" => "0.95", "after" => "1.05"}],
        status: :approved
      })

      assert {:error, :stale} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      assert entries(Repo.get!(ChangeRun, run.id)) == []
    end

    test "a foreign run, a run out of review and another station's decision all refuse", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      payload = prepared_confirmation(scope, ["pathway:PW_W14"])

      # A run in another organization is one unavailable refusal, with no
      # metadata about it in the answer.
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign_editor = editor_fixture(foreign_organization)

      {:ok, foreign_run} =
        ChangeRuns.create_pending_compute(
          foreign_organization.id,
          foreign_version.id,
          %{id: foreign_editor.id, email: foreign_editor.email},
          [%{name: "stops.txt", size: 1, sha256: String.duplicate("d", 64)}]
        )

      foreign_source = %{
        kind: "station_imports",
        payload: %{
          "station_id" => ctx.station.id,
          "station_stop_id" => "STATION_A",
          "change_run_id" => foreign_run.id,
          "observations" => []
        },
        digest: String.duplicate("f", 64)
      }

      foreign_payload = %{
        "run_id" => foreign_run.id,
        "station_stop_id" => "STATION_A",
        "input_digest" => String.duplicate("a", 64),
        "decisions" => [
          %{"decision_id" => "pathway:PW_W14", "decision_digest" => String.duplicate("b", 64)}
        ]
      }

      assert {:error, :unavailable} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 foreign_source,
                 foreign_payload
               )

      # A payload prepared for another run cannot be pointed at this one.
      assert {:error, :invalid_selection} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 foreign_source,
                 payload
               )

      # The same run read through another version is the same refusal.
      assert {:error, :unavailable} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 Ecto.UUID.generate(),
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      # Another station's decision is not this station's to confirm, and a
      # payload prepared for this station cannot be pointed at another run or
      # another station.
      source = frozen_source(scope)

      for {label, selection} <- [
            {"another run", Map.put(payload, "run_id", Ecto.UUID.generate())},
            {"another station",
             %{
               "run_id" => run.id,
               "station_stop_id" => "STATION_B",
               "input_digest" => String.duplicate("a", 64),
               "decisions" => [
                 %{
                   "decision_id" => "pathway:PW_OTHER",
                   "decision_digest" => String.duplicate("b", 64)
                 }
               ]
             }},
            {"another station's decision in this station's run",
             %{
               "run_id" => run.id,
               "station_stop_id" => "STATION_A",
               "input_digest" => String.duplicate("a", 64),
               "decisions" => [
                 %{
                   "decision_id" => "pathway:PW_OTHER",
                   "decision_digest" => String.duplicate("b", 64)
                 }
               ]
             }}
          ] do
        assert {:error, :invalid_selection} =
                 ChangeRuns.confirm_observation_selection(
                   ctx.organization.id,
                   ctx.version.id,
                   actor(ctx),
                   source,
                   selection
                 ),
               "expected #{label} to refuse"
      end

      # A run that is no longer in review holds no decision this may confirm.
      assert {:ok, _pending} =
               ChangeRuns.request_apply(ctx.organization.id, run.id, actor(ctx))

      assert {:error, :unavailable} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )
    end

    test "at the history bound the confirmation refuses and every decision stays pending", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      payload = prepared_confirmation(scope, ["pathway:PW_W14"])

      seed_reviewed_evidence(run, 100)
      before = confirmation_snapshot(run)

      assert {:error, :evidence_limit} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      assert confirmation_snapshot(run) == before
      assert statuses(run)["pathway:PW_W14"] == :pending
    end

    test "a malformed confirmation is one invalid selection, never a partial write", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      payload = prepared_confirmation(scope, ["pathway:PW_W14"])
      [row] = payload["decisions"]
      before = confirmation_snapshot(run)

      refusals = [
        {"not a map", "nope"},
        {"no decisions", Map.delete(payload, "decisions")},
        {"empty decisions", Map.put(payload, "decisions", [])},
        {"a row without a decision digest",
         Map.put(payload, "decisions", [Map.delete(row, "decision_digest")])},
        {"a row with a blank id", Map.put(payload, "decisions", [%{row | "decision_id" => ""}])},
        {"a duplicated decision", Map.put(payload, "decisions", [row, row])},
        {"a non-hex input digest", Map.put(payload, "input_digest", "not-a-digest")},
        {"another run's selection", Map.put(payload, "run_id", Ecto.UUID.generate())},
        {"another station's selection", Map.put(payload, "station_stop_id", "STATION_B")},
        {"more decisions than a page holds",
         Map.put(payload, "decisions", List.duplicate(row, 101))}
      ]

      for {label, selection} <- refusals do
        assert {:error, :invalid_selection} =
                 ChangeRuns.confirm_observation_selection(
                   ctx.organization.id,
                   ctx.version.id,
                   actor(ctx),
                   frozen_source(scope),
                   selection
                 ),
               "expected #{label} to refuse"

        assert confirmation_snapshot(run) == before, "#{label} wrote something"
      end
    end
  end

  describe "the reviewed_evidence namespace" do
    test "a legacy manifest without the namespace stays valid and readable", ctx do
      run = width_run(ctx)

      assert run.source_manifest["files"] != []
      assert entries(run) == []
      assert {:ok, _bytes} = ChangeArtifactStorage.read(run, root: ctx.root)
    end

    test "only the bounded namespace is admitted beside the base source files", ctx do
      run = width_run(ctx)
      files = base_files(run)

      for {label, namespace} <- [
            {"an unknown namespace key",
             %{"version" => 1, "entries" => [], "approved_by" => ctx.editor.email}},
            {"an unknown version", %{"version" => 2, "entries" => []}},
            {"a missing version", %{"entries" => []}},
            {"entries that are not a list", %{"version" => 1, "entries" => %{}}},
            {"more than 100 entries",
             %{"version" => 1, "entries" => Enum.map(1..101, &entry("pathway:PW_W14#{&1}"))}},
            {"a hundred complete entries past the byte bound",
             %{"version" => 1, "entries" => Enum.map(1..100, &entry("pathway:PW_W14#{&1}"))}},
            {"an unknown entry key",
             %{
               "version" => 1,
               "entries" => [Map.put(entry("pathway:PW_W14"), "reason", "because")]
             }},
            {"an observation that is not a list",
             %{
               "version" => 1,
               "entries" => [Map.put(entry("pathway:PW_W14"), "observations", "none")]
             }},
            {"an unknown observation key",
             %{
               "version" => 1,
               "entries" => [
                 with_observations(%{"note" => "text"})
               ]
             }},
            {"an unbounded observation",
             %{
               "version" => 1,
               "entries" => [
                 with_observations([%{"note" => String.duplicate("x", 5_000)}])
               ]
             }}
          ] do
        assert {:error, changeset} =
                 ChangeRun.system_changeset(run, %{
                   source_manifest: Map.put(files, "reviewed_evidence", namespace)
                 })
                 |> Ecto.Changeset.apply_action(:update)

        assert %{source_manifest: ["contains unsupported manifest data"]} = errors_on(changeset),
               "expected #{label} to be refused"
      end

      # A namespace that fits both bounds is admitted, and the base files are
      # untouched. One complete entry is about 700 bytes, so the byte bound is
      # what refuses a full hundred of them: the count bound is only reachable
      # with the smaller entries this same validator allows.
      admitted = %{"version" => 1, "entries" => Enum.map(1..50, &entry("pathway:PW_W14#{&1}"))}

      assert {:ok, run} =
               ChangeRun.system_changeset(run, %{
                 source_manifest: Map.put(files, "reviewed_evidence", admitted)
               })
               |> Repo.update()

      assert base_files(run) == files
      assert length(entries(run)) == 50
      assert byte_size(Jason.encode!(admitted)) <= ChangeRun.reviewed_evidence_limits().max_bytes
    end

    test "an encoded namespace past the byte bound is refused", ctx do
      run = width_run(ctx)
      files = base_files(run)

      oversized =
        %{
          "version" => 1,
          "entries" =>
            Enum.map(1..20, fn index ->
              entry("pathway:PW_W14#{index}")
              |> Map.put("source_ref", String.duplicate("s", 4_000))
            end)
        }

      assert byte_size(Jason.encode!(oversized)) > ChangeRun.reviewed_evidence_limits().max_bytes

      assert {:error, changeset} =
               ChangeRun.system_changeset(run, %{
                 source_manifest: Map.put(files, "reviewed_evidence", oversized)
               })
               |> Ecto.Changeset.apply_action(:update)

      assert %{source_manifest: ["contains unsupported manifest data"]} = errors_on(changeset)
    end

    test "a decision serializer round trip is unchanged by any of this", ctx do
      run = width_run(ctx)

      scope =
        selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

      payload = prepared_confirmation(scope, ["pathway:PW_W14"])

      assert {:ok, _result} =
               ChangeRuns.confirm_observation_selection(
                 ctx.organization.id,
                 ctx.version.id,
                 actor(ctx),
                 frozen_source(scope),
                 payload
               )

      approved = decision_row(run, "pathway:PW_W14")

      assert {:ok, deserialized} =
               ChangeDecisionSerializer.deserialize(%{
                 serializer_version: 1,
                 decision_id: approved.decision_id,
                 entity_type: approved.entity_type,
                 action: approved.action,
                 status: approved.status,
                 natural_key: approved.natural_key,
                 current_values: approved.current_values,
                 uploaded_values: approved.uploaded_values,
                 changed_fields: approved.changed_fields,
                 dependency_keys: approved.dependency_keys,
                 current_fingerprint: approved.current_fingerprint,
                 user_edited: approved.user_edited
               })

      assert {:ok, round_tripped} = ChangeDecisionSerializer.serialize(deserialized)
      assert round_tripped.uploaded_values == approved.uploaded_values
      assert round_tripped.current_values == approved.current_values

      # The run's serializer version is untouched by a confirmation.
      assert Repo.get!(ChangeRun, run.id).serializer_version == 1
    end
  end

  ## Fixtures and helpers

  # One run holding this station's two width decisions, its stop rename and
  # another station's width change. `ctx` supplies the organization, version and
  # artifact root, so a second organization gets its own run and its own version
  # without sharing either.
  defp width_run(ctx) do
    organization_id = ctx.organization.id
    version_id = ctx.version.id

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
        decision("pathway:PW_OTHER", :pathway, :modify, "PW_OTHER",
          current: %{"from_stop_id" => "PLAT_B", "to_stop_id" => "PLAT_B", "min_width" => "1"},
          uploaded: %{"from_stop_id" => "PLAT_B", "to_stop_id" => "PLAT_B", "min_width" => "1.30"}
        ),
        decision("stop:PLAT_A", :stop, :modify, "PLAT_A",
          current: %{"stop_name" => "Platform A"},
          uploaded: %{"stop_name" => "Platform A renamed"}
        )
      ],
      summary: %{applicable: 4, modify: 4},
      diagnostics: []
    }

    {:ok, run} =
      ChangeRuns.create_pending_compute(organization_id, version_id, actor(ctx), [
        %{name: "stops.txt", size: 1, sha256: String.duplicate("d", 64)}
      ])

    {:ok, claimed, generation, token} = ChangeRuns.claim(organization_id, run.id, :compute)
    {:ok, _review} = ChangeRuns.persist_review(organization_id, run.id, generation, token, review)

    # The staged bytes live under this run's own directory, so a confirmation
    # leaves a run whose source artifacts are still readable through the same
    # accessor a retry uses.
    stage_for_run(claimed, organization_id, version_id, ctx.root)
  end

  # Returns the run holding the manifest that names the staged files.
  defp stage_for_run(run, organization_id, version_id, root) do
    {:ok, staged} =
      ChangeArtifactStorage.stage(
        organization_id,
        version_id,
        run.id,
        [
          %{filename: "stops.txt", content: "stop_id,stop_name\nPLAT_A,Platform A\n"},
          %{filename: "pathways.txt", content: "pathway_id,min_width\nPW_W14,1.05\n"}
        ],
        root: root
      )

    put_source_files(run, %{
      "files" =>
        Enum.map(staged, fn file ->
          %{
            "name" => file.name,
            "key" => file.key,
            "size" => file.size,
            "sha256" => file.sha256,
            "content_type" => "text/csv"
          }
        end),
      "total_bytes" => Enum.sum(Enum.map(staged, & &1.size))
    })
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

  defp actor(ctx), do: %{id: ctx.editor.id, email: ctx.editor.email}

  # The scope a station host builds: the station and run it resolved, the typed
  # observations it froze, and the digest it recorded beside them.
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

    %Scope{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      user_id: ctx.editor.id,
      user_email: ctx.editor.email,
      pack_id: "station_imports",
      version_name: ctx.version.name,
      resource_context: resource_context
    }
  end

  defp frozen_source(scope), do: Scope.source_snapshot(scope)

  # What a host asks for: the run and station, the preparation's own digest, and
  # the selected rows exactly as the projection reported them.
  defp prepared_confirmation(scope, decision_ids) do
    {:ok, prepared, _evidence} = StationAssistant.prepare_import_selection(scope, decision_ids)
    confirmation(prepared)
  end

  defp confirmation(prepared) do
    %{
      "run_id" => prepared["run_id"],
      "station_stop_id" => prepared["station_stop_id"],
      "input_digest" => prepared["input_digest"],
      "decisions" => prepared["selected"]
    }
  end

  defp base_files(run), do: Map.take(run.source_manifest, ["files", "total_bytes"])

  defp entries(run) do
    case run.source_manifest do
      %{"reviewed_evidence" => %{"entries" => entries}} -> entries
      %{reviewed_evidence: %{entries: entries}} -> entries
      _other -> []
    end
  end

  defp statuses(run) do
    ChangeRuns.list_decisions(run.organization_id, run.id)
    |> Map.new(&{&1.decision_id, &1.status})
  end

  defp decision_stamps(run) do
    ChangeRuns.list_decisions(run.organization_id, run.id)
    |> Map.new(&{&1.decision_id, {&1.status, &1.updated_at}})
  end

  defp confirmation_snapshot(run) do
    reloaded = Repo.get!(ChangeRun, run.id)
    {base_files(reloaded), entries(reloaded), reloaded.state, decision_stamps(run)}
  end

  defp read_staged(run, ctx) do
    {:ok, files} = ChangeArtifactStorage.read(run, root: ctx.root)
    Enum.map(files, & &1.content)
  end

  defp decision_row(run, decision_id) do
    Repo.one!(
      from(d in ChangeDecision,
        where: d.change_run_id == ^run.id and d.decision_id == ^decision_id
      )
    )
  end

  defp update_decision(run, decision_id, attrs) when is_list(attrs) do
    decision_row(run, decision_id)
    |> ChangeDecision.system_changeset(Map.new(attrs))
    |> Repo.update!()
  end

  defp update_decision(run, decision_id, attrs) when is_map(attrs),
    do: update_decision(run, decision_id, Map.to_list(attrs))

  defp put_source_files(run, files) when is_list(files),
    do: put_source_files(run, Map.put(run.source_manifest, "files", files))

  defp put_source_files(run, manifest) do
    run
    |> Ecto.Changeset.change(%{source_manifest: manifest})
    |> Repo.update!()
  end

  # A history at the admission bound, written through the schema's own changeset
  # so the namespace this case needs is one the validator accepts.
  defp seed_reviewed_evidence(run, count) do
    namespace = %{
      "version" => 1,
      "entries" => Enum.map(1..count, &sized_entry("pathway:PW_W14#{&1}"))
    }

    run
    |> Ecto.Changeset.change(%{
      source_manifest: Map.put(run.source_manifest, "reviewed_evidence", namespace)
    })
    |> Repo.update!()
  end

  defp with_observations(observations, decision_id \\ "pathway:PW_W14") do
    entry(decision_id) |> Map.put("observations", observations)
  end

  # The smallest entry the validator admits: enough to reach the count bound
  # without reaching the byte bound first.
  defp sized_entry(decision_id) do
    %{
      "decision_id" => decision_id,
      "decision_digest" => String.duplicate("a", 64),
      "source_digest" => String.duplicate("b", 64),
      "snapshot_digest" => String.duplicate("c", 64),
      "station_id" => Ecto.UUID.generate(),
      "actor_id" => Ecto.UUID.generate(),
      "confirmed_at" => "2026-09-18T12:00:00Z"
    }
  end

  defp entry(decision_id) do
    %{
      "decision_id" => decision_id,
      "decision_digest" => String.duplicate("a", 64),
      "source_digest" => String.duplicate("b", 64),
      "snapshot_digest" => String.duplicate("c", 64),
      "station_id" => Ecto.UUID.generate(),
      "actor_id" => Ecto.UUID.generate(),
      "confirmed_at" => "2026-09-18T12:00:00Z",
      "observations" => [
        %{
          "target" => %{"pathway_id" => "PW_W14"},
          "field" => "min_width",
          "original_value" => "105",
          "normalized_value" => "1.05",
          "unit" => "cm",
          "meaning" => "minimum_clear_width",
          "captured_date" => "2026-09-18",
          "source_ref" => "OBS88",
          "source_revision" => nil,
          "source_digest" => nil
        }
      ]
    }
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
      location_type: if(String.starts_with?(stop_id, "ENT_"), do: 2, else: 0),
      parent_station: station.stop_id,
      level_id: level_id,
      stop_lat: Decimal.new("39.9527"),
      stop_lon: Decimal.new("-75.1653")
    })
  end
end
