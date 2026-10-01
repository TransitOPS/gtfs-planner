defmodule GtfsPlanner.Gtfs.RunnerAdmissionTest do
  @moduledoc """
  Admission through the application-started import, change and export runner
  supervisors, which each admit one job (`config :gtfs_planner, :runner_limits`).

  A blocking worker holds the only slot. A second start returns `{:error, :busy}`
  before it claims anything, the caller closes the unstarted run, and a start
  after the first runner exits is admitted.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export.Run, as: ExportRun
  alias GtfsPlanner.Gtfs.Export.Runner, as: ExportRunner
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Import.{ChangeRun, ChangeRunner, ChangeRuns}
  alias GtfsPlanner.Gtfs.Import.Run, as: ImportRun
  alias GtfsPlanner.Gtfs.Import.Runner, as: ImportRunner
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Support.{BlockingImportWorker, BlockingJobWorker}
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @import_supervisor GtfsPlanner.Gtfs.Import.RunnerSupervisor
  @change_supervisor GtfsPlanner.Gtfs.Import.ChangeRunnerSupervisor
  @export_supervisor GtfsPlanner.Gtfs.Export.RunnerSupervisor
  @exporter %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  setup do
    root = Path.join(System.tmp_dir!(), "runner-admission-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = %{
      artifacts: Application.fetch_env(:gtfs_planner, :gtfs_task_artifacts_path),
      import_worker: Application.fetch_env(:gtfs_planner, :import_worker_module),
      import_owner: Application.fetch_env(:gtfs_planner, :blocking_import_worker_owner),
      job_owner: Application.fetch_env(:gtfs_planner, :blocking_job_worker_owner)
    }

    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)
    Application.put_env(:gtfs_planner, :import_worker_module, BlockingImportWorker)
    Application.put_env(:gtfs_planner, :blocking_import_worker_owner, self())
    Application.put_env(:gtfs_planner, :blocking_job_worker_owner, self())

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, previous.artifacts)
      restore_env(:import_worker_module, previous.import_worker)
      restore_env(:blocking_import_worker_owner, previous.import_owner)
      restore_env(:blocking_job_worker_owner, previous.job_owner)
    end)

    %{organization: organization_fixture()}
  end

  describe "import runner supervisor" do
    test "refuses a second import while the first holds the slot and admits a third after it exits",
         %{organization: organization} do
      actor = editor_actor(organization)
      held = pending_target(organization, actor, "Held")
      refused = pending_target(organization, actor, "Refused")
      after_release = pending_target(organization, actor, "After release")

      assert {:ok, runner} = start_import(organization, held)
      assert_receive {:blocking_import_worker_started, worker}, 2_000
      assert %{active: 1} = DynamicSupervisor.count_children(@import_supervisor)

      assert {:error, :busy} = start_import(organization, refused)
      assert %{active: 1} = DynamicSupervisor.count_children(@import_supervisor)
      assert %ImportRun{state: "pending"} = Repo.get!(ImportRun, refused.run.id)

      assert {:ok, %ImportRun{state: "failed", reason_code: "busy"}} =
               ImportRuns.fail_unstarted(organization.id, refused.run.id, refused.run.lease_token)

      assert %ImportRun{state: "running"} = Repo.get!(ImportRun, held.run.id)

      await_exit(runner, fn -> send(worker, :finish) end)
      assert %{active: 0} = DynamicSupervisor.count_children(@import_supervisor)

      assert {:ok, third_runner} = start_import(organization, after_release)
      assert_receive {:blocking_import_worker_started, third_worker}, 2_000
      await_exit(third_runner, fn -> send(third_worker, :finish) end)
    end

    test "closing a refused import frees its version name and hides the run from recovery",
         %{organization: organization} do
      actor = editor_actor(organization)
      held = pending_target(organization, actor, "Held")
      refused = pending_target(organization, actor, "Same name")

      assert {:ok, runner} = start_import(organization, held)
      assert_receive {:blocking_import_worker_started, worker}, 2_000
      assert {:error, :busy} = start_import(organization, refused)

      assert {:ok, _closed} =
               ImportRuns.fail_unstarted(organization.id, refused.run.id, refused.run.lease_token)

      assert Repo.get(GtfsVersion, refused.version.id) == nil
      refute refused.run.id in Enum.map(ImportRuns.list_recoverable(organization.id), & &1.id)

      assert {:ok, %{run: retried}} =
               ImportRuns.create_pending_target(organization.id, actor, %{name: "Same name"})

      assert retried.id != refused.run.id
      await_exit(runner, fn -> send(worker, :finish) end)
    end

    test "fail_unstarted leaves a claimed run, a stale token and an unknown run alone",
         %{organization: organization} do
      actor = editor_actor(organization)
      claimed = pending_target(organization, actor, "Claimed")
      waiting = pending_target(organization, actor, "Waiting")

      assert {:ok, runner} = start_import(organization, claimed)
      assert_receive {:blocking_import_worker_started, worker}, 2_000

      assert {:error, :invalid_transition} =
               ImportRuns.fail_unstarted(
                 organization.id,
                 claimed.run.id,
                 claimed.run.lease_token
               )

      assert {:error, :invalid_transition} =
               ImportRuns.fail_unstarted(organization.id, waiting.run.id, Ecto.UUID.generate())

      assert {:error, :not_found} =
               ImportRuns.fail_unstarted(
                 organization.id,
                 Ecto.UUID.generate(),
                 waiting.run.lease_token
               )

      assert %ImportRun{state: "running"} = Repo.get!(ImportRun, claimed.run.id)
      assert %ImportRun{state: "pending"} = Repo.get!(ImportRun, waiting.run.id)
      assert %GtfsVersion{} = Repo.get!(GtfsVersion, waiting.version.id)
      await_exit(runner, fn -> send(worker, :finish) end)
    end

    test "refuses a cleanup start at the cap and leaves the recoverable run unchanged",
         %{organization: organization} do
      actor = editor_actor(organization)
      held = pending_target(organization, actor, "Held")
      stopped = pending_target(organization, actor, "Stopped")

      assert {:ok, _run, _version} =
               ImportRuns.fail_pending_target(
                 organization.id,
                 stopped.run.id,
                 stopped.run.lease_token,
                 :upload_consumption_failed
               )

      assert {:ok, runner} = start_import(organization, held)
      assert_receive {:blocking_import_worker_started, worker}, 2_000

      assert {:error, :busy} = ImportRunner.start_cleanup(organization.id, stopped.run.id, actor)
      assert %ImportRun{state: "failed"} = Repo.get!(ImportRun, stopped.run.id)
      await_exit(runner, fn -> send(worker, :finish) end)
    end
  end

  describe "change runner supervisor" do
    test "refuses a second compute while the first holds the slot and admits a third after it exits",
         %{organization: organization} do
      actor = editor_actor(organization)
      held = pending_compute(organization, actor)
      refused = pending_compute(organization, actor)
      after_release = pending_compute(organization, actor)

      assert {:ok, runner} =
               ChangeRunner.start_compute(organization.id, held.id, BlockingJobWorker)

      assert_receive {:blocking_job_worker_started, :compute, worker}, 2_000
      assert %{active: 1} = DynamicSupervisor.count_children(@change_supervisor)

      assert {:error, :busy} = ChangeRunner.start_compute(organization.id, refused.id)
      assert %{active: 1} = DynamicSupervisor.count_children(@change_supervisor)
      assert %ChangeRun{state: :pending_compute} = Repo.get!(ChangeRun, refused.id)

      assert {:ok, %ChangeRun{state: :failed, failure_code: "busy", phase: :cleanup} = failed} =
               ChangeRuns.fail_unstarted(organization.id, refused.id, refused.lease_generation)

      assert %DateTime{} = failed.started_at
      assert %DateTime{} = failed.finished_at

      assert {:error, :invalid_transition} =
               ChangeRuns.fail_unstarted(organization.id, refused.id, refused.lease_generation)

      assert {:error, :invalid_transition} =
               ChangeRuns.fail_unstarted(organization.id, held.id, held.lease_generation)

      assert %ChangeRun{state: :computing} = Repo.get!(ChangeRun, held.id)

      await_exit(runner, fn -> send(worker, :finish) end)
      assert %{active: 0} = DynamicSupervisor.count_children(@change_supervisor)

      assert {:ok, third_runner} =
               ChangeRunner.start_compute(organization.id, after_release.id, BlockingJobWorker)

      assert_receive {:blocking_job_worker_started, :compute, third_worker}, 2_000
      await_exit(third_runner, fn -> send(third_worker, :finish) end)
    end

    test "refuses an apply start at the cap and closes the pending apply run as busy",
         %{organization: organization} do
      actor = editor_actor(organization)
      held = pending_compute(organization, actor)
      applying = pending_apply(organization, actor)

      assert {:ok, runner} =
               ChangeRunner.start_compute(organization.id, held.id, BlockingJobWorker)

      assert_receive {:blocking_job_worker_started, :compute, worker}, 2_000

      assert {:error, :busy} = ChangeRunner.start_apply(organization.id, applying.id)
      assert %ChangeRun{state: :pending_apply} = Repo.get!(ChangeRun, applying.id)

      assert {:error, :invalid_transition} =
               ChangeRuns.fail_unstarted(
                 organization.id,
                 applying.id,
                 applying.lease_generation + 1
               )

      assert %ChangeRun{state: :pending_apply} = Repo.get!(ChangeRun, applying.id)

      assert {:ok, %ChangeRun{state: :failed, failure_code: "busy"}} =
               ChangeRuns.fail_unstarted(organization.id, applying.id, applying.lease_generation)

      await_exit(runner, fn -> send(worker, :finish) end)
    end
  end

  describe "export runner supervisor" do
    test "refuses a second build while the first holds the slot and admits a third after it exits",
         %{organization: organization} do
      held_version = gtfs_version_fixture(organization.id)
      refused_version = gtfs_version_fixture(organization.id)
      {:ok, held} = ExportRuns.create_pending(organization.id, held_version.id, @exporter, :full)

      {:ok, refused} =
        ExportRuns.create_pending(organization.id, refused_version.id, @exporter, :full)

      assert {refused.include_flex, refused.estimate_missing_times, refused.estimate_method} ==
               {true, true, :distance}

      assert {:ok, runner} = ExportRunner.start_build(organization.id, held.id, BlockingJobWorker)
      assert_receive {:blocking_job_worker_started, :build, worker}, 2_000
      run_count = Repo.aggregate(ExportRun, :count)

      assert {:error, :busy} = ExportRunner.ensure_started(organization.id, refused)
      assert %{active: 1} = DynamicSupervisor.count_children(@export_supervisor)
      assert Repo.aggregate(ExportRun, :count) == run_count

      failed = Repo.get!(ExportRun, refused.id)
      assert %ExportRun{state: :failed, failure_code: "busy", lease_token: nil} = failed
      assert %DateTime{} = failed.finished_at

      assert {failed.include_flex, failed.estimate_missing_times, failed.estimate_method} ==
               {true, true, :distance}

      assert ExportRuns.latest_for_version(organization.id, refused_version.id, :full) == nil
      assert %ExportRun{state: :building} = Repo.get!(ExportRun, held.id)

      await_exit(runner, fn -> send(worker, :finish) end)
      assert %{active: 0} = DynamicSupervisor.count_children(@export_supervisor)

      assert {:ok, again} =
               ExportRuns.create_pending(organization.id, refused_version.id, @exporter, :full)

      assert again.id != refused.id

      assert {:ok, third_runner} =
               ExportRunner.start_build(organization.id, again.id, BlockingJobWorker)

      assert_receive {:blocking_job_worker_started, :build, third_worker}, 2_000
      await_exit(third_runner, fn -> send(third_worker, :finish) end)
    end

    test "fail_unstarted leaves a claimed run and a stale generation alone",
         %{organization: organization} do
      version = gtfs_version_fixture(organization.id)
      {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @exporter, :full)

      assert {:error, :invalid_transition} =
               ExportRuns.fail_unstarted(organization.id, run.id, run.lease_generation + 1)

      assert %ExportRun{state: :pending} = Repo.get!(ExportRun, run.id)

      assert {:ok, _building, _generation, _token} =
               ExportRuns.claim(organization.id, run.id, :build)

      assert {:error, :invalid_transition} =
               ExportRuns.fail_unstarted(organization.id, run.id, run.lease_generation)

      assert {:error, :not_found} =
               ExportRuns.fail_unstarted(organization.id, Ecto.UUID.generate(), 0)

      assert %ExportRun{state: :building} = Repo.get!(ExportRun, run.id)
    end
  end

  defp editor_actor(organization) do
    editor = editor_fixture(organization)
    %{id: editor.id, email: editor.email}
  end

  defp pending_target(organization, actor, name) do
    {:ok, target} = ImportRuns.create_pending_target(organization.id, actor, %{name: name})
    target
  end

  defp start_import(organization, %{run: run}),
    do: ImportRunner.start_import(organization.id, run.id, run.lease_token, [])

  # One non-terminal change run is allowed per version, so each run gets its own.
  defp pending_compute(organization, actor) do
    version = gtfs_version_fixture(organization.id)
    {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, actor, [])
    run
  end

  # A pending apply run is a reviewed run that was asked to apply; the review that
  # leads to it is not what these cases exercise.
  defp pending_apply(organization, actor) do
    run = pending_compute(organization, actor)

    from(r in ChangeRun, where: r.id == ^run.id)
    |> Repo.update_all(set: [state: :pending_apply, started_at: DateTime.utc_now()])

    Repo.get!(ChangeRun, run.id)
  end

  # Releases the worker and waits until its runner has exited, so the slot is free.
  defp await_exit(runner, release) do
    ref = Process.monitor(runner)
    release.()
    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 5_000
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)
end
