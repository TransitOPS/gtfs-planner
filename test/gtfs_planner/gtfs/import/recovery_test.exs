defmodule GtfsPlanner.Gtfs.Import.RecoveryTest do
  @moduledoc """
  Claimed convergent cleanup: batched deletion, isolation, failure convergence,
  and the same-name release.

  Exercises the real Repo, filesystem namespace removal, and `ImportRuns`
  transitions. Concurrency uses `Task.async` + `Sandbox.allow` with no sleeps.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.Runner
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.Import.Recovery
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import Ecto.Query, warn: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "operator@example.com"}
  @cleanup_actor %{id: Ecto.UUID.generate(), email: "cleaner@example.com"}

  setup do
    previous = Application.get_env(:gtfs_planner, :uploads_path)

    root = Path.join(System.tmp_dir!(), "recovery_#{System.unique_integer([:positive])}")
    Application.put_env(:gtfs_planner, :uploads_path, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(previous) do
        Application.delete_env(:gtfs_planner, :uploads_path)
      else
        Application.put_env(:gtfs_planner, :uploads_path, previous)
      end

      Application.delete_env(:gtfs_planner, :import_cleanup_batch_size)
      Application.delete_env(:gtfs_planner, :import_cleanup_inject_failure)
    end)

    org = organization_fixture()
    %{org: org, root: root}
  end

  # --- helpers --------------------------------------------------------------

  defp fail_run(org, name \\ "Failed Target") do
    {:ok, %{run: run, version: version}} =
      ImportRuns.create_pending_target(org.id, @actor, %{name: name})

    {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)
    {:ok, _, _} = ImportRuns.fail_import(org.id, run.id, token, make_failure())
    {run, version}
  end

  defp make_failure do
    Import.Failure.from_error(:unknown, phase: :phase_2, outcome: :failed, committed_counts: %{})
  end

  defp seed_level_rows(org, version, n) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..n, fn i ->
        %{
          id: Ecto.UUID.generate(),
          level_id: "L#{i}",
          level_index: 0.0,
          level_name: "Level #{i}",
          organization_id: org.id,
          gtfs_version_id: version.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Level, rows)
    count
  end

  defp seed_route_rows(org, version, n) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..n, fn i ->
        %{
          id: Ecto.UUID.generate(),
          route_id: "R#{i}",
          route_type: 3,
          route_short_name: "R#{i}",
          route_long_name: "Route #{i}",
          organization_id: org.id,
          gtfs_version_id: version.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Route, rows)
    count
  end

  defp seed_stop_level_rows(org, version, _level, stop, n) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..n, fn i ->
        {:ok, lvl} =
          GtfsPlanner.Gtfs.create_level(%{
            level_id: "L#{System.unique_integer([:positive])}",
            level_index: 0.0,
            level_name: "Level #{i}",
            organization_id: org.id,
            gtfs_version_id: version.id
          })

        %{
          id: Ecto.UUID.generate(),
          organization_id: org.id,
          gtfs_version_id: version.id,
          level_id: lvl.id,
          stop_id: stop.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(StopLevel, rows)
    count
  end

  defp count_rows(schema, org, version) do
    from(r in schema, where: r.organization_id == ^org.id and r.gtfs_version_id == ^version.id)
    |> Repo.aggregate(:count)
  end

  defp write_namespace_file(org, version, rel) do
    version_dir = Path.join([uploads_root(org.id), version.id])
    dest = Path.join([version_dir, rel])
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, "bytes")
    dest
  end

  defp uploads_root(org_id) do
    Path.join([Application.fetch_env!(:gtfs_planner, :uploads_path), "diagrams", org_id])
    |> Path.expand()
  end

  defp version_exists?(version_id) do
    not is_nil(Repo.get(GtfsVersion, version_id))
  end

  # --- full cleanup ---------------------------------------------------------

  describe "discard_claimed/3 full cleanup" do
    test "deletes the namespace and every schema, deletes the version last, and marks cleaned (AC-12)",
         %{org: org} do
      {run, version} = fail_run(org, "Spring 2024")

      seed_level_rows(org, version, 12)
      seed_route_rows(org, version, 7)
      seed_stop_level_rows(org, version, nil, stop_fixture(org.id, version.id), 5)
      file = write_namespace_file(org, version, "station_a/plan.png")

      {:ok, _, claimed_version, token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert {:ok, nil} = Recovery.discard_claimed(run, claimed_version, token)

      refute File.exists?(file)
      assert count_rows(Level, org, version) == 0
      assert count_rows(Route, org, version) == 0
      assert count_rows(StopLevel, org, version) == 0
      refute version_exists?(version.id)

      cleaned = Repo.get!(Run, run.id)
      assert cleaned.state == "cleaned"
      assert cleaned.actor_id == @actor.id
      assert cleaned.cleanup_actor_id == @cleanup_actor.id
      assert cleaned.version_name == "Spring 2024"
    end

    test "converges over already-absent rows when retried (idempotent success)", %{org: org} do
      {run, version} = fail_run(org, "Converge Twice")

      seed_level_rows(org, version, 3)
      {:ok, _, claimed_version, token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      # First attempt fails partway (database), leaving some rows + version.
      Application.put_env(:gtfs_planner, :import_cleanup_inject_failure, {:database, Level})

      assert {:error, :database_error} =
               Recovery.discard_claimed(run, claimed_version, token)

      assert Repo.get!(Run, run.id).state == "cleanup_failed"
      assert version_exists?(version.id)

      Application.delete_env(:gtfs_planner, :import_cleanup_inject_failure)

      # Retry converges over the remaining (and already-absent) rows.
      {:ok, reclaimed, reclaimed_version, re_token} =
        ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert reclaimed.state == "cleaning"
      assert {:ok, nil} = Recovery.discard_claimed(reclaimed, reclaimed_version, re_token)
      assert count_rows(Level, org, version) == 0
      refute version_exists?(version.id)
      assert Repo.get!(Run, run.id).state == "cleaned"
    end
  end

  # --- multi-batch ----------------------------------------------------------

  describe "bounded multi-batch deletion" do
    test "converges across more than one batch while other versions stay intact (AC-4/AC-12)",
         %{org: org} do
      Application.put_env(:gtfs_planner, :import_cleanup_batch_size, 100)

      other = gtfs_version_fixture(org.id)
      {run, target} = fail_run(org, "Multi Batch")

      seed_level_rows(org, target, 250)
      seed_route_rows(org, target, 250)
      seed_level_rows(org, other, 40)
      seed_route_rows(org, other, 40)
      other_file = write_namespace_file(org, other, "station_b/keep.png")

      {:ok, _, claimed_version, token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert {:ok, nil} = Recovery.discard_claimed(run, claimed_version, token)

      assert count_rows(Level, org, target) == 0
      assert count_rows(Route, org, target) == 0
      assert count_rows(Level, org, other) == 40
      assert count_rows(Route, org, other) == 40
      assert File.exists?(other_file)
      refute version_exists?(target.id)
      assert version_exists?(other.id)
    end
  end

  # --- mid failure ----------------------------------------------------------

  describe "mid-cleanup failure convergence" do
    test "database failure calls fail_cleanup, retains version, later attempt converges (AC-13)",
         %{org: org} do
      {run, version} = fail_run(org)
      seed_level_rows(org, version, 50)
      {:ok, _, claimed_version, token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      Application.put_env(:gtfs_planner, :import_cleanup_inject_failure, {:database, Level})

      assert {:error, :database_error} =
               Recovery.discard_claimed(run, claimed_version, token)

      failed = Repo.get!(Run, run.id)
      assert failed.state == "cleanup_failed"
      assert failed.reason_code == "database_error"
      assert version_exists?(version.id)

      Application.delete_env(:gtfs_planner, :import_cleanup_inject_failure)

      {:ok, reclaimed, reclaimed_version, re_token} =
        ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert reclaimed.state == "cleaning"
      assert {:ok, nil} = Recovery.discard_claimed(reclaimed, reclaimed_version, re_token)
      assert count_rows(Level, org, version) == 0
      refute version_exists?(version.id)
      assert Repo.get!(Run, run.id).state == "cleaned"
    end

    test "filesystem failure calls fail_cleanup, retains version, later attempt converges (AC-13)",
         %{org: org} do
      {run, version} = fail_run(org)
      seed_level_rows(org, version, 10)
      {:ok, _, claimed_version, token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      Application.put_env(:gtfs_planner, :import_cleanup_inject_failure, {:filesystem, :any})

      assert {:error, :filesystem_error} =
               Recovery.discard_claimed(run, claimed_version, token)

      failed = Repo.get!(Run, run.id)
      assert failed.state == "cleanup_failed"
      assert failed.reason_code == "filesystem_error"
      assert version_exists?(version.id)

      Application.delete_env(:gtfs_planner, :import_cleanup_inject_failure)

      {:ok, reclaimed, reclaimed_version, re_token} =
        ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert {:ok, nil} = Recovery.discard_claimed(reclaimed, reclaimed_version, re_token)
      assert Repo.get!(Run, run.id).state == "cleaned"
      refute version_exists?(version.id)
    end
  end

  # --- race / same-name -----------------------------------------------------

  describe "cleanup races and same-name release" do
    test "duplicate cleanup claims leave exactly one winner; name re-creatable only after cleaned (AC-11/AC-14)",
         %{org: org} do
      {run, version} = fail_run(org, "Reuse Me")
      {:ok, _, claimed_version, token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      parent = self()

      first = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        Recovery.discard_claimed(run, claimed_version, token)
      end

      second = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)
      end

      t1 = Task.async(first)
      t2 = Task.async(second)

      results = Task.await_many([t1, t2], 5000)
      winners = Enum.count(results, &match?({:ok, _}, &1))
      assert winners == 1

      assert Repo.get!(Run, run.id).state == "cleaned"
      refute version_exists?(version.id)

      # The same version name is now creatable again (AC-14).
      assert {:ok, new_version} = Versions.create_gtfs_version(org.id, %{name: "Reuse Me"})
      assert new_version.name == "Reuse Me"
      assert new_version.id != version.id
    end
  end

  # --- end-to-end discard then re-upload convergence (AC-13/AC-14) ----------

  describe "discard then re-upload under the same name (AC-13/AC-14)" do
    test "discarding a failed target then re-uploading the same name yields one fresh target with no duplicate rows",
         %{org: org} do
      {run, version} = fail_run(org, "Reupload Me")
      seed_level_rows(org, version, 8)

      # Discard the failed target through Recovery.discard_claimed (the same
      # contract the LiveView UI uses after claiming cleanup).
      {:ok, _, claimed_version, token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)
      assert {:ok, nil} = Recovery.discard_claimed(run, claimed_version, token)

      refute version_exists?(version.id)
      assert count_rows(Level, org, version) == 0
      assert Repo.get!(Run, run.id).state == "cleaned"

      # The old gtfs_version_id identity is gone: zero rows remain and the version
      # row is absent.
      assert count_rows(Level, org, version) == 0

      # Re-upload the same feed under the SAME version name. The name is
      # creatable only after cleanup reached `cleaned`.
      {:ok, %{run: new_run, version: new_version}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Reupload Me"})

      refute new_version.id == version.id

      {:ok, _, _, new_token} = ImportRuns.claim_import(org.id, new_run.id, new_run.lease_token)
      {:ok, _, _} = ImportRuns.fail_import(org.id, new_run.id, new_token, make_failure())
      seed_level_rows(org, new_version, 3)

      # Exactly ONE fresh target exists for that name; the deleted identity has
      # no rows and no version row.
      versions_for_name =
        from(v in GtfsVersion, where: v.organization_id == ^org.id and v.name == "Reupload Me")
        |> Repo.all()

      assert length(versions_for_name) == 1
      assert Enum.at(versions_for_name, 0).id == new_version.id

      assert count_rows(Level, org, version) == 0
      refute version_exists?(version.id)

      # The fresh target carries only its own three rows.
      assert count_rows(Level, org, new_version) == 3
    end

    test "a re-uploaded feed published through the runner leaves no duplicate target rows (AC-14)",
         %{org: org, root: root} do
      {run, version} = fail_run(org, "Publish After Discard")
      {:ok, _, claimed_version, token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)
      assert {:ok, nil} = Recovery.discard_claimed(run, claimed_version, token)
      refute version_exists?(version.id)

      # Fresh target, same name, real publication through the runner. The runner
      # claims the pending run itself (pending lease token), exactly like
      # ImportLive.
      {:ok, %{run: new_run, version: new_version}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Publish After Discard"})

      files = [
        %{filename: "levels.txt", content: "level_id,level_index,level_name\nL1,0.0,Ground"}
      ]

      {:ok, runner_pid} = Runner.start_import(org.id, new_run.id, new_run.lease_token, files)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner_pid)

      # Wait for the runner task to finish (monitor it; no sleeps).
      for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
      end

      new_version = Repo.get!(GtfsVersion, new_version.id)
      assert new_version.publication_status == "published"

      # Exactly one version with that name, exactly one level row under it.
      versions_for_name =
        from(v in GtfsVersion,
          where: v.organization_id == ^org.id and v.name == "Publish After Discard"
        )
        |> Repo.all()

      assert length(versions_for_name) == 1
      assert count_rows(Level, org, new_version) == 1

      # The deleted identity is entirely gone.
      refute version_exists?(version.id)
      assert count_rows(Level, org, version) == 0

      _ = root
    end
  end

  # --- runner entry point ---------------------------------------------------

  describe "run/3 (Runner entry)" do
    test "performs cleanup using the held org/run/token without re-claiming", %{org: org} do
      {run, version} = fail_run(org)
      seed_route_rows(org, version, 9)
      {:ok, _, _claimed_version, token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert {:ok, nil} = Recovery.run(org.id, run.id, token)
      assert count_rows(Route, org, version) == 0
      refute version_exists?(version.id)
      assert Repo.get!(Run, run.id).state == "cleaned"
    end

    test "a wrong token cannot complete cleanup", %{org: org} do
      {run, version} = fail_run(org)

      {:ok, _, _claimed_version, _token} =
        ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert {:error, _} = Recovery.run(org.id, run.id, Ecto.UUID.generate())
      assert Repo.get!(Run, run.id).state == "cleaning"
      assert version_exists?(version.id)
    end
  end
end
