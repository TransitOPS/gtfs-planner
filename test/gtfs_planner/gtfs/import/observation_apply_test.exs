defmodule GtfsPlanner.Gtfs.Import.ObservationApplyTest do
  @moduledoc """
  EV-6: the fenced per-decision apply validates any captured reviewed-evidence
  binding before it mutates anything.

  The decisions here are hand-enumerated rather than produced by the diff engine:
  W14 is a complete `min_width`-only pathway change an accepted 105 cm measurement
  matches exactly, W12 is a second width change with no accepted measurement, and
  PW_OTHER belongs to another station. Each expected outcome is written out below,
  so the apply is compared against a stated expectation rather than against
  whatever the run happens to hold.

  Every case reaches apply the way a station host reaches it:
  `Scope.with_source_snapshot/2` -> `StationAssistant.prepare_import_selection/2`
  -> `ChangeRuns.confirm_observation_selection/5` -> the separate native
  `request_apply/3` -> `ChangeRuns.claim/3` -> the concrete `ChangeWorker.apply/5`.
  Nothing here writes a run, decision, manifest, membership or snapshot assign by
  hand except where a case is deliberately about an entry or a mutation the native
  confirmation could not have produced.

  The interleaving case commits its own organization, members, version, run,
  decisions and station rows on independent connections, holds each side open with
  messages, and waits for the other backend's `pg_blocking_pids/1` entry instead of
  sleeping. It deletes exactly those rows in `on_exit`. The other cases roll back in
  the shared SQL sandbox.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StationAssistant
  alias GtfsPlanner.Gtfs.StationJournal

  alias GtfsPlanner.Gtfs.Import.{
    ChangeArtifactStorage,
    ChangeDecision,
    ChangeRun,
    ChangeRuns,
    ChangeWorker
  }

  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  import Ecto.Query

  @rendezvous_timeout 10_000
  @collect_timeout 15_000

  setup do
    organization = organization_fixture()
    editor = editor_fixture(organization)
    version = gtfs_version_fixture(organization.id)

    level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})
    level_fixture(organization.id, version.id, %{level_id: "L2", level_index: 1.0})

    station = station_stop(organization.id, version.id, "STATION_A", "L1")
    entrance = child_stop(organization.id, version.id, station, "ENT_A", "L1", "Entrance A")
    platform = child_stop(organization.id, version.id, station, "PLAT_A", "L1", "Platform A")

    other_station = station_stop(organization.id, version.id, "STATION_B", "L2")
    other_platform = child_stop(organization.id, version.id, other_station, "PLAT_B", "L2", "B")

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_W14",
      pathway_mode: 1,
      min_width: Decimal.new("0.95")
    })

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_W12",
      pathway_mode: 1,
      min_width: Decimal.new("1.10")
    })

    pathway_fixture(
      organization.id,
      version.id,
      other_platform.stop_id,
      other_platform.stop_id,
      %{pathway_id: "PW_OTHER", pathway_mode: 1, min_width: Decimal.new("1.00")}
    )

    root =
      Path.join(System.tmp_dir!(), "ai07-observation-apply-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    %{
      organization: organization,
      editor: editor,
      version: version,
      station: station,
      other_station: other_station,
      root: root
    }
  end

  describe "a real worker apply of a confirmed decision" do
    test "writes the accepted width, keeps the captured evidence and reports actual outcomes",
         ctx do
      run = confirmed_run(ctx)

      evidence_before = entries(Repo.get!(ChangeRun, run.id))
      files_before = base_files(Repo.get!(ChangeRun, run.id))

      # W12 is approved the ordinary native way, with no captured binding, so the
      # receipts below separate a reviewed suggestion from a preexisting approval
      # rather than reporting one generic outcome for both.
      assert {:ok, _approved} =
               ChangeRuns.set_decision_status(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W12",
                 :approved
               )

      apply_run = claim_apply(ctx, run)

      assert :ok =
               ChangeWorker.apply(
                 apply_run.run,
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run),
                 ChangeRuns.topic(run)
               )

      # The accepted 105 cm measurement became exactly 1.05 m; the natively
      # approved W12 applied its own uploaded width; the other station's decision
      # was never in scope.
      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("1.05"))
      assert Decimal.equal?(width_of(ctx, "PW_W12"), Decimal.new("1.2"))
      assert Decimal.equal?(width_of(ctx, "PW_OTHER"), Decimal.new("1.00"))

      assert %ChangeRun{state: :completed, summary: summary} = Repo.get!(ChangeRun, run.id)
      assert %{"applied" => 2, "failed" => 0, "unapplied" => 0} = summary

      assert %{
               "pathway:PW_W12" => :applied,
               "pathway:PW_W14" => :applied,
               "pathway:PW_OTHER" => :pending
             } = statuses(run)

      # The confirmed decision's evidence is still exactly what the confirmation
      # wrote: the apply neither erased it nor extended it, and the original source
      # file entries survive untouched.
      after_run = Repo.get!(ChangeRun, run.id)
      assert entries(after_run) == evidence_before
      assert base_files(after_run) == files_before
      assert [%{"decision_id" => "pathway:PW_W14"}] = entries(after_run)

      assert change_log_count(ctx.organization) == 2
    end

    test "a second failing decision yields actual partial results, not a generic failure", ctx do
      run = confirmed_run(ctx)

      assert {:ok, _approved} =
               ChangeRuns.set_decision_status(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W12",
                 :approved
               )

      # W12's live record no longer matches the fingerprint recorded for it, so
      # the ordinary fingerprint fence - not the new binding check - marks it stale.
      update_decision(run, "pathway:PW_W12", current_fingerprint: String.duplicate("0", 64))

      apply_run = claim_apply(ctx, run)

      assert :ok =
               ChangeWorker.apply(
                 apply_run.run,
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run),
                 ChangeRuns.topic(run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("1.05"))
      assert Decimal.equal?(width_of(ctx, "PW_W12"), Decimal.new("1.10"))

      assert %ChangeRun{state: :partial, summary: summary} = Repo.get!(ChangeRun, run.id)
      assert %{"applied" => 1, "failed" => 1} = summary

      assert %{"pathway:PW_W12" => :stale, "pathway:PW_W14" => :applied} = statuses(run)
      assert [%ChangeDecision{apply_failure_code: "drifted"}] = failures(run, "pathway:PW_W12")

      # The confirmed decision's evidence survived the partial run.
      assert [%{"decision_id" => "pathway:PW_W14"}] = entries(Repo.get!(ChangeRun, run.id))
    end

    test "a retry rechecks the same binding, applies nothing more and keeps actual outcomes",
         ctx do
      run = confirmed_run(ctx)

      # The accepted width is edited in the decision after the confirmation. The
      # first apply must refuse it, and a retry must recheck rather than trust the
      # earlier approval.
      update_decision(run, "pathway:PW_W14",
        uploaded_values: %{
          "from_stop_id" => "ENT_A",
          "to_stop_id" => "PLAT_A",
          "min_width" => "1.40"
        },
        changed_fields: [%{"field" => "min_width", "before" => "0.95", "after" => "1.40"}]
      )

      first = claim_apply(ctx, run)

      assert :ok =
               ChangeWorker.apply(
                 first.run,
                 first.generation,
                 first.token,
                 audit_context(first.run),
                 ChangeRuns.topic(run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("0.95"))
      assert %ChangeRun{state: :partial} = Repo.get!(ChangeRun, run.id)

      assert [%ChangeDecision{apply_failure_code: "stale_reviewed_evidence"}] =
               failures(run, "pathway:PW_W14")

      assert change_log_count(ctx.organization) == 0

      # The historical entry is retained: a stale binding is refused, never erased.
      assert [%{"decision_id" => "pathway:PW_W14"}] = entries(Repo.get!(ChangeRun, run.id))

      assert {:ok, pending_apply} = ChangeRuns.retry(ctx.organization.id, run.id, actor(ctx))

      {:ok, claimed, generation, token} =
        ChangeRuns.claim(ctx.organization.id, pending_apply.id, :apply)

      second = %{run: claimed, generation: generation, token: token}

      assert :ok =
               ChangeWorker.apply(
                 second.run,
                 second.generation,
                 second.token,
                 audit_context(second.run),
                 ChangeRuns.topic(second.run)
               )

      # The retry refuses the same way and applies nothing more. Per-decision
      # outcomes, never a whole-run promise.
      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("0.95"))
      assert change_log_count(ctx.organization) == 0

      assert [%ChangeDecision{apply_failure_code: "stale_reviewed_evidence"}] =
               failures(run, "pathway:PW_W14")
    end
  end

  describe "a binding altered after the confirmation" do
    test "a changed uploaded value refuses before any entity or audit write", ctx do
      run = confirmed_run(ctx)
      before = apply_snapshot(run)

      update_decision(run, "pathway:PW_W14",
        uploaded_values: %{
          "from_stop_id" => "ENT_A",
          "to_stop_id" => "PLAT_A",
          "min_width" => "1.40"
        },
        changed_fields: [%{"field" => "min_width", "before" => "0.95", "after" => "1.40"}]
      )

      apply_run = claim_apply(ctx, run)

      assert {:error, :stale_reviewed_evidence} =
               ChangeRuns.apply_decision(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W14",
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("0.95"))
      assert change_log_count(ctx.organization) == 0
      assert statuses(run)["pathway:PW_W14"] == :approved

      after_run = Repo.get!(ChangeRun, run.id)
      assert base_files(after_run) == elem(before, 0)
      assert entries(after_run) == elem(before, 1)
    end

    test "a changed dependency refuses before any entity or audit write", ctx do
      run = confirmed_run(ctx)
      before = apply_snapshot(run)

      # The decision now depends on a pathway this run does not have, which the
      # ordinary dependency fence would also refuse. The binding check runs first,
      # so the refusal names the stale binding rather than a later gate.
      update_decision(run, "pathway:PW_W14", dependency_keys: ["pathway:PW_MISSING"])

      apply_run = claim_apply(ctx, run)

      assert {:error, :stale_reviewed_evidence} =
               ChangeRuns.apply_decision(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W14",
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("0.95"))
      assert change_log_count(ctx.organization) == 0

      after_run = Repo.get!(ChangeRun, run.id)
      assert base_files(after_run) == elem(before, 0)
      assert entries(after_run) == elem(before, 1)
    end

    test "a changed source file refuses before any entity or audit write and keeps the entry",
         ctx do
      run = confirmed_run(ctx)
      before = apply_snapshot(run)

      # The upload this run was computed from is no longer the run's source, so the
      # entry's base source digest no longer describes it.
      current = Repo.get!(ChangeRun, run.id)

      put_source_files(
        current,
        Map.put(
          current.source_manifest,
          "files",
          Enum.map(
            elem(before, 0)["files"],
            &Map.put(&1, "sha256", "c" <> String.slice(&1["sha256"], 1, 63))
          )
        )
      )

      apply_run = claim_apply(ctx, run)

      assert {:error, :stale_reviewed_evidence} =
               ChangeRuns.apply_decision(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W14",
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("0.95"))
      assert change_log_count(ctx.organization) == 0

      # The historical evidence is untouched by the refusal.
      assert entries(Repo.get!(ChangeRun, run.id)) == elem(before, 1)
    end

    test "an entry naming another station refuses before any entity or audit write", ctx do
      run = confirmed_run(ctx)
      before = apply_snapshot(run)

      # This station's entry, restated against the other station. The decision is
      # genuinely this station's, so only the attribution can refuse.
      replace_entry_station(run, ctx.other_station.id)
      apply_run = claim_apply(ctx, run)

      assert {:error, :stale_reviewed_evidence} =
               ChangeRuns.apply_decision(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W14",
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("0.95"))
      assert change_log_count(ctx.organization) == 0

      # The refusal rewrote nothing: only the station the entry names differs from
      # the confirmation's entry.
      assert [%{"station_id" => station_id} = entry] = entries(Repo.get!(ChangeRun, run.id))
      assert station_id == ctx.other_station.id
      assert Map.delete(entry, "station_id") == Map.delete(hd(elem(before, 1)), "station_id")
    end

    test "an entry with no captured snapshot digest refuses rather than applying unproven", ctx do
      run = confirmed_run(ctx)
      drop_entry_snapshot_digest(run)

      apply_run = claim_apply(ctx, run)

      assert {:error, :stale_reviewed_evidence} =
               ChangeRuns.apply_decision(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W14",
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("0.95"))
      assert change_log_count(ctx.organization) == 0
    end

    test "a later contradictory journal note does not rewrite the captured acceptance", ctx do
      run = confirmed_run(ctx)

      # The journal gains a contradicting note through its own production path after
      # the confirmation. The captured entry is an immutable record of what was
      # accepted, and apply reads that entry rather than the journal, so the
      # accepted width still applies.
      assert {:ok, journal_scope} =
               StationJournal.resolve_scope(
                 ctx.organization.id,
                 ctx.version.id,
                 ctx.station.id,
                 ctx.editor.id
               )

      note = "Width disputed; the 105 cm survey was never taken."

      assert %{synced_count: 1, errors: []} =
               StationJournal.sync_entries(journal_scope, [
                 %{
                   "id" => Ecto.UUID.generate(),
                   "target_type" => "station",
                   "body" => note,
                   "captured_at" => DateTime.utc_now() |> DateTime.truncate(:second)
                 }
               ])

      apply_run = claim_apply(ctx, run)

      assert {:ok, %ChangeDecision{status: :applied}} =
               ChangeRuns.apply_decision(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W14",
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("1.05"))

      # The note still exists as a new observation, and nothing in the stored
      # provenance claims the journal still agrees.
      assert [%{body: ^note}] = StationJournal.list_entries(journal_scope)

      [entry] = entries(Repo.get!(ChangeRun, run.id))
      assert entry["confirmed_at"]
      assert [_measurement] = entry["observations"]

      encoded = Jason.encode!(Repo.get!(ChangeRun, run.id).source_manifest)
      refute encoded =~ "disputed"
      refute encoded =~ "never taken"
    end
  end

  describe "decisions without captured evidence" do
    test "an ordinary approved decision applies through the existing path", ctx do
      run = width_run(ctx)

      assert {:ok, _approved} =
               ChangeRuns.set_decision_status(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W12",
                 :approved
               )

      apply_run = claim_apply(ctx, run)

      assert {:ok, %ChangeDecision{status: :applied, apply_failure_code: nil}} =
               ChangeRuns.apply_decision(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W12",
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W12"), Decimal.new("1.2"))
      assert change_log_count(ctx.organization) == 1

      # A run whose manifest never carried the namespace is unaffected: the absence
      # of reviewed evidence remains readable and applies as before.
      assert entries(Repo.get!(ChangeRun, run.id)) == []
    end

    test "a revoked actor is still refused and its decision is not marked failed", ctx do
      run = width_run(ctx)

      assert {:ok, _approved} =
               ChangeRuns.set_decision_status(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W12",
                 :approved
               )

      apply_run = claim_apply(ctx, run)
      revoke_editor(ctx)

      assert {:error, :forbidden} =
               ChangeRuns.apply_decision(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W12",
                 apply_run.generation,
                 apply_run.token,
                 audit_context(apply_run.run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W12"), Decimal.new("1.10"))
      assert statuses(run)["pathway:PW_W12"] == :approved
      assert change_log_count(ctx.organization) == 0
    end

    test "a lost lease is still refused and writes nothing", ctx do
      run = confirmed_run(ctx)
      apply_run = claim_apply(ctx, run)

      assert {:error, :lease_lost} =
               ChangeRuns.apply_decision(
                 ctx.organization.id,
                 run.id,
                 "pathway:PW_W14",
                 apply_run.generation + 1,
                 apply_run.token,
                 audit_context(apply_run.run)
               )

      assert Decimal.equal?(width_of(ctx, "PW_W14"), Decimal.new("0.95"))
      assert change_log_count(ctx.organization) == 0
      assert statuses(run)["pathway:PW_W14"] == :approved
    end
  end

  describe "the fenced apply and a committed value change" do
    test "an apply that waits on the decision row revalidates and refuses the new value", ctx do
      supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
      scope = committed_scope(ctx, supervisor)
      run = unboxed(fn -> seed_applying_run(scope) end)

      # A second, independent transaction edits the decision's uploaded value and
      # holds it uncommitted. The apply then starts and blocks on the decision row
      # the editor holds, so the apply's locking read can only see the new value
      # after that transaction commits.
      editor = start_value_change(supervisor, run)
      assert_receive {:editor_holds, editor_backend}, @rendezvous_timeout

      apply_task = start_apply(supervisor, scope, run)
      assert_receive {:apply_ready, apply_backend}, @rendezvous_timeout
      assert :ok == unboxed(fn -> await_blocker(apply_backend, editor_backend, deadline()) end)

      send(editor.pid, :commit)

      assert {:ok, {:ok, %ChangeDecision{uploaded_values: %{"min_width" => "1.40"}}}} =
               Task.await(editor, @collect_timeout)

      assert {:error, :stale_reviewed_evidence} = Task.await(apply_task, @collect_timeout)

      unboxed(fn ->
        assert Decimal.equal?(width_of(scope, "PW_W14"), Decimal.new("0.95"))
        assert change_log_count(scope.organization) == 0

        # The refusal rolls the apply back; recording the failure is the worker's
        # job, so the decision is as the editor left it.
        assert [%ChangeDecision{status: :approved, apply_failure_code: nil}] =
                 failures(run, "pathway:PW_W14")

        assert [%{"decision_id" => "pathway:PW_W14"}] = entries(Repo.get!(ChangeRun, run.id))
      end)
    end
  end

  ## Fixtures and helpers

  # One run holding this station's two width decisions and another station's width
  # change, staged under `ctx.root` so its source artifacts stay readable through
  # the same accessor a retry uses.
  defp width_run(ctx) do
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
        )
      ],
      summary: %{applicable: 3, modify: 3},
      diagnostics: []
    }

    {:ok, run} =
      ChangeRuns.create_pending_compute(ctx.organization.id, ctx.version.id, actor(ctx), [
        %{name: "stops.txt", size: 1, sha256: String.duplicate("d", 64)}
      ])

    {:ok, claimed, generation, token} = ChangeRuns.claim(ctx.organization.id, run.id, :compute)

    {:ok, _review} =
      ChangeRuns.persist_review(ctx.organization.id, run.id, generation, token, review)

    stage_for_run(claimed, ctx)
  end

  defp confirmed_run(ctx) do
    run = width_run(ctx)
    confirm_w14(ctx, run)
    run
  end

  defp stage_for_run(run, ctx) do
    {:ok, staged} =
      ChangeArtifactStorage.stage(
        ctx.organization.id,
        ctx.version.id,
        run.id,
        [
          %{filename: "stops.txt", content: "stop_id,stop_name\nPLAT_A,Platform A\n"},
          %{filename: "pathways.txt", content: "pathway_id,min_width\nPW_W14,1.05\n"}
        ],
        root: ctx.root
      )

    put_source_files(run, source_files_of(staged))
  end

  # The ordinary host path: a server-frozen source snapshot, the preparation it
  # describes, and the separate native confirmation that persists the capture.
  defp confirm_w14(ctx, run) do
    scope = selection_scope(ctx, ctx.station, run, [observation("OBS88", "PW_W14", "105", "cm")])

    {:ok, prepared, _evidence} =
      StationAssistant.prepare_import_selection(scope, ["pathway:PW_W14"])

    assert [%{"decision_id" => "pathway:PW_W14", "decision_digest" => _digest}] =
             prepared["selected"]

    assert {:ok, %{decisions: [%ChangeDecision{status: :approved}]}} =
             ChangeRuns.confirm_observation_selection(
               ctx.organization.id,
               ctx.version.id,
               actor(ctx),
               Scope.source_snapshot(scope),
               %{
                 "run_id" => prepared["run_id"],
                 "station_stop_id" => prepared["station_stop_id"],
                 "input_digest" => prepared["input_digest"],
                 "decisions" => prepared["selected"]
               }
             )

    :ok
  end

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

  # The separate native apply request: a confirmation never starts it.
  defp claim_apply(ctx, run) do
    {:ok, pending_apply} = ChangeRuns.request_apply(ctx.organization.id, run.id, actor(ctx))

    {:ok, claimed, generation, token} =
      ChangeRuns.claim(ctx.organization.id, pending_apply.id, :apply)

    %{run: claimed, generation: generation, token: token}
  end

  defp actor(ctx), do: %{id: ctx.editor.id, email: ctx.editor.email}

  defp audit_context(run) do
    %AuditContext{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      station_stop_id: nil,
      actor_id: run.actor_id,
      actor_email: run.actor_email
    }
  end

  defp width_of(ctx_or_scope, pathway_id) do
    ctx_or_scope.organization.id
    |> Gtfs.get_pathway_by_pathway_id(ctx_or_scope.version.id, pathway_id)
    |> Map.fetch!(:min_width)
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

  defp failures(run, decision_id) do
    ChangeRuns.list_decisions(run.organization_id, run.id)
    |> Enum.filter(&(&1.decision_id == decision_id and &1.status != :applied))
  end

  defp change_log_count(organization) do
    Repo.aggregate(
      from(log in ChangeLog, where: log.organization_id == ^organization.id),
      :count
    )
  end

  defp apply_snapshot(run) do
    reloaded = Repo.get!(ChangeRun, run.id)
    {base_files(reloaded), entries(reloaded)}
  end

  defp revoke_editor(ctx) do
    membership =
      Repo.one!(
        from(m in UserOrgMembership,
          where:
            m.organization_id == ^ctx.organization.id and m.user_id == ^ctx.editor.id and
              is_nil(m.deactivated_at)
        )
      )

    membership
    |> Ecto.Changeset.change(%{deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update!()
  end

  defp update_decision(run, decision_id, attrs) do
    decision_row(run, decision_id)
    |> ChangeDecision.system_changeset(Map.new(attrs))
    |> Repo.update!()
  end

  defp decision_row(run, decision_id) do
    Repo.one!(
      from(d in ChangeDecision,
        where: d.change_run_id == ^run.id and d.decision_id == ^decision_id
      )
    )
  end

  defp put_source_files(run, manifest) do
    run
    |> Ecto.Changeset.change(%{source_manifest: manifest})
    |> Repo.update!()
  end

  defp source_files_of(staged) do
    %{
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
    }
  end

  defp replace_entry_station(run, station_id) do
    [entry] = entries(Repo.get!(ChangeRun, run.id))
    put_namespace(run, [Map.put(entry, "station_id", station_id)])
  end

  defp drop_entry_snapshot_digest(run) do
    [entry] = entries(Repo.get!(ChangeRun, run.id))
    put_namespace(run, [Map.delete(entry, "snapshot_digest")])
  end

  defp put_namespace(run, new_entries) do
    reloaded = Repo.get!(ChangeRun, run.id)

    put_source_files(
      reloaded,
      Map.put(
        reloaded.source_manifest,
        "reviewed_evidence",
        %{"version" => 1, "entries" => new_entries}
      )
    )
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

  ## Committed interleaving

  # Its own committed organization, members, version, station and run, all deleted
  # by id in `on_exit`. `ctx` supplies nothing but the task supervisor's lifetime.
  defp committed_scope(_ctx, _supervisor) do
    organization = unboxed(&organization_fixture/0)
    on_exit(fn -> unboxed(fn -> cleanup(organization.id) end) end)

    %{
      organization: organization,
      version: unboxed(fn -> gtfs_version_fixture(organization.id) end),
      root: Path.join(System.tmp_dir!(), "ai07-observation-apply-#{Ecto.UUID.generate()}")
    }
  end

  # One committed run in `:applying`, its W14 decision confirmed through the same
  # host path the sandbox cases use, holding the lease generation and token the
  # interleaving tasks need.
  defp seed_applying_run(scope) do
    on_exit(fn -> File.rm_rf(scope.root) end)

    unboxed(fn ->
      run_actor =
        user = user_fixture(%{email: "apply-evidence-#{Ecto.UUID.generate()}@example.test"})

      organization_membership_fixture(user, scope.organization, ["pathways_studio_editor"])
      %{id: user.id, email: user.email}

      level_fixture(scope.organization.id, scope.version.id, %{level_id: "L1", level_index: 0.0})

      station = station_stop(scope.organization.id, scope.version.id, "STATION_A", "L1")

      entrance =
        child_stop(scope.organization.id, scope.version.id, station, "ENT_A", "L1", "Entrance A")

      child_stop(scope.organization.id, scope.version.id, station, "PLAT_A", "L1", "Platform A")

      pathway_fixture(scope.organization.id, scope.version.id, entrance.stop_id, "PLAT_A", %{
        pathway_id: "PW_W14",
        pathway_mode: 1,
        min_width: Decimal.new("0.95")
      })

      review = %{
        decisions: [
          decision("pathway:PW_W14", :pathway, :modify, "PW_W14",
            current: %{
              "from_stop_id" => "ENT_A",
              "to_stop_id" => "PLAT_A",
              "min_width" => "0.95"
            },
            uploaded: %{
              "from_stop_id" => "ENT_A",
              "to_stop_id" => "PLAT_A",
              "min_width" => "1.05"
            }
          )
        ],
        summary: %{applicable: 1, modify: 1},
        diagnostics: []
      }

      {:ok, run} =
        ChangeRuns.create_pending_compute(scope.organization.id, scope.version.id, run_actor, [
          %{name: "stops.txt", size: 1, sha256: String.duplicate("d", 64)}
        ])

      {:ok, claimed, generation, token} =
        ChangeRuns.claim(scope.organization.id, run.id, :compute)

      {:ok, _review} =
        ChangeRuns.persist_review(scope.organization.id, run.id, generation, token, review)

      {:ok, staged} =
        ChangeArtifactStorage.stage(
          scope.organization.id,
          scope.version.id,
          claimed.id,
          [%{filename: "stops.txt", content: "stop_id,stop_name\nPLAT_A,Platform A\n"}],
          root: scope.root
        )

      put_source_files(claimed, source_files_of(staged))

      confirm_w14(
        %{
          organization: scope.organization,
          editor: %{id: run_actor.id, email: run_actor.email},
          version: scope.version,
          station: station
        },
        Repo.get!(ChangeRun, claimed.id)
      )

      {:ok, pending_apply} =
        ChangeRuns.request_apply(scope.organization.id, run.id, run_actor)

      {:ok, applying, apply_generation, apply_token} =
        ChangeRuns.claim(scope.organization.id, pending_apply.id, :apply)

      Map.merge(applying, %{
        generation: apply_generation,
        token: apply_token
      })
    end)
  end

  defp start_value_change(supervisor, run) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn -> committed_value_change(run, parent) end)
  end

  defp committed_value_change(run, parent) do
    unboxed(fn -> Repo.transaction(fn -> edit_held_decision(run, parent) end) end)
  end

  defp edit_held_decision(run, parent) do
    send(parent, {:editor_holds, backend_pid()})

    decision =
      Repo.one!(
        from(d in ChangeDecision,
          where: d.change_run_id == ^run.id and d.decision_id == "pathway:PW_W14",
          lock: "FOR UPDATE"
        )
      )

    updated =
      ChangeDecision.system_changeset(decision, %{
        uploaded_values: Map.put(decision.uploaded_values, "min_width", "1.40"),
        changed_fields: [%{"field" => "min_width", "before" => "0.95", "after" => "1.40"}]
      })
      |> Repo.update!()

    await_message(:commit)

    {:ok, updated}
  end

  defp start_apply(supervisor, scope, run) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      unboxed(fn ->
        send(parent, {:apply_ready, backend_pid()})

        ChangeRuns.apply_decision(
          scope.organization.id,
          run.id,
          "pathway:PW_W14",
          run.generation,
          run.token,
          audit_context(run)
        )
      end)
    end)
  end

  defp await_message(message) do
    receive do
      ^message -> :ok
    after
      @rendezvous_timeout -> raise "never received #{inspect(message)}"
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @rendezvous_timeout

  # Runs, decisions, stops, pathways and levels cascade from the version and
  # organization rows. Users are found through their memberships, which only this
  # organization's fixtures create.
  defp cleanup(org_id) do
    user_ids =
      Repo.all(
        from(m in UserOrgMembership, where: m.organization_id == ^org_id, select: m.user_id)
      )

    Repo.delete_all(from(log in ChangeLog, where: log.organization_id == ^org_id))
    Repo.delete_all(from(s in GtfsPlanner.Gtfs.Stop, where: s.organization_id == ^org_id))
    Repo.delete_all(from(p in GtfsPlanner.Gtfs.Pathway, where: p.organization_id == ^org_id))
    Repo.delete_all(from(l in GtfsPlanner.Gtfs.Level, where: l.organization_id == ^org_id))
    Repo.delete_all(from(d in ChangeDecision, where: d.change_run_id in subquery(runs(org_id))))
    Repo.delete_all(from(r in ChangeRun, where: r.organization_id == ^org_id))
    Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id == ^org_id))
    Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^org_id))
    Repo.delete_all(from(o in Organization, where: o.id == ^org_id))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
  end

  defp runs(org_id), do: from(r in ChangeRun, where: r.organization_id == ^org_id, select: r.id)
end
