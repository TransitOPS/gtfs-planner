defmodule GtfsPlanner.Gtfs.Import.RunnerSourceHandshakeTest do
  @moduledoc """
  The import runner's source handshake. `Runner.start_import/4` is admitted and claims
  the run first, then waits for the caller to stage the upload and call
  `Runner.install_source/2`. A missed deadline, a caller that exits first and a caller
  that gives up with `Runner.cancel_source/1` all fail the run as `source_not_installed`,
  remove the run's directory and stop the runner.

  The cases use the application `Import.RunnerSupervisor`, the real `SourceStorage` under
  the test artifact root and the real claim and closure functions. The caller role is
  played by the test process, which stages like `ImportLive` does; `ImportLive`'s own
  ordering is covered in its LiveView tests. Every run and version is created inside the
  SQL sandbox, and every directory a case creates is removed on exit.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import.{Run, Runner, RunnerSupervisor, SourceStorage}
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Versions.GtfsVersion

  @levels_content "level_id,level_index,level_name\nL1,0.0,Ground Floor\n"
  @staging_event [:gtfs_planner, :task_artifact_capacity, :lock_attempt]

  setup do
    RunnerSlots.await_idle()

    previous = %{
      timeout: Application.fetch_env!(:gtfs_planner, :import_source_install_timeout_ms),
      worker: Application.fetch_env(:gtfs_planner, :import_worker_module),
      owner: Application.fetch_env(:gtfs_planner, :blocking_import_worker_owner)
    }

    on_exit(fn ->
      RunnerSlots.await_idle()
      Application.put_env(:gtfs_planner, :import_source_install_timeout_ms, previous.timeout)
      restore_env(:import_worker_module, previous.worker)
      restore_env(:blocking_import_worker_owner, previous.owner)
    end)

    %{organization: GtfsPlanner.OrganizationsFixtures.organization_fixture()}
  end

  describe "a runner that never receives its source" do
    setup :hold_workers

    test "fails the run, removes the run directory and stops when the deadline passes", %{
      organization: organization
    } do
      Application.put_env(:gtfs_planner, :import_source_install_timeout_ms, 100)
      run = pending_run(organization, "Deadline Feed")
      stage_directory(organization, run)

      {:ok, runner} =
        Runner.start_import(organization.id, run.id, run.lease_token, caller: self())

      ref = Process.monitor(runner)

      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 2_000
      assert_closed_without_source(organization, run)
      assert {:error, :runner_stopped} = Runner.install_source(runner, [])
    end

    test "fails the run, removes the run directory and stops when the caller exits first", %{
      organization: organization
    } do
      run = pending_run(organization, "Caller Exit Feed")
      stage_directory(organization, run)
      caller = spawn_parked_caller()

      {:ok, runner} =
        Runner.start_import(organization.id, run.id, run.lease_token, caller: caller)

      ref = Process.monitor(runner)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 2_000
      assert_closed_without_source(organization, run)
    end

    test "fails the run, removes the run directory and stops when the caller cancels", %{
      organization: organization
    } do
      run = pending_run(organization, "Cancelled Feed")
      stage_directory(organization, run)

      {:ok, runner} =
        Runner.start_import(organization.id, run.id, run.lease_token, caller: self())

      ref = Process.monitor(runner)

      missing_upload = %{
        path: Path.join(System.tmp_dir!(), Ecto.UUID.generate()),
        filename: "a.txt"
      }

      assert {:error, :invalid_file} =
               SourceStorage.stage(organization.id, run.id, [missing_upload])

      assert :ok = Runner.cancel_source(runner)

      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 2_000
      assert_closed_without_source(organization, run)
    end
  end

  describe "closing a run whose source never arrived" do
    test "deletes the empty version and fails the run under the runner's lease token", %{
      organization: organization
    } do
      {run, token} = claimed_run(organization, "Closed Feed")

      assert {:ok, %Run{state: "failed", reason_code: "source_not_installed", phase: "upload"}} =
               ImportRuns.fail_source_not_installed(organization.id, run.id, token)

      assert Repo.get(GtfsVersion, run.gtfs_version_id) == nil
      assert ImportRuns.list_recoverable(organization.id) == []
    end

    test "leaves a run alone when the token is not the runner's current one", %{
      organization: organization
    } do
      {run, _token} = claimed_run(organization, "Superseded Feed")

      assert {:error, :invalid_transition} =
               ImportRuns.fail_source_not_installed(organization.id, run.id, run.lease_token)

      assert %Run{state: "running"} = Repo.get!(Run, run.id)

      assert %GtfsVersion{publication_status: "importing"} =
               Repo.get!(GtfsVersion, run.gtfs_version_id)
    end

    test "leaves a run alone when its lease has expired", %{organization: organization} do
      {run, token} = claimed_run(organization, "Expired Feed")

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]]
      )

      assert {:error, :invalid_transition} =
               ImportRuns.fail_source_not_installed(organization.id, run.id, token)

      assert %Run{state: "running"} = Repo.get!(Run, run.id)
      assert %GtfsVersion{} = Repo.get!(GtfsVersion, run.gtfs_version_id)
    end

    test "leaves a run that no runner has claimed alone", %{organization: organization} do
      run = pending_run(organization, "Unclaimed Feed")

      assert {:error, :invalid_transition} =
               ImportRuns.fail_source_not_installed(organization.id, run.id, run.lease_token)

      assert %Run{state: "pending"} = Repo.get!(Run, run.id)

      assert %GtfsVersion{publication_status: "staging"} =
               Repo.get!(GtfsVersion, run.gtfs_version_id)
    end

    test "leaves another organization's run alone", %{organization: organization} do
      {run, token} = claimed_run(organization, "Foreign Feed")
      other = GtfsPlanner.OrganizationsFixtures.organization_fixture()

      assert {:error, :not_found} = ImportRuns.fail_source_not_installed(other.id, run.id, token)

      assert %Run{state: "running"} = Repo.get!(Run, run.id)
      assert %GtfsVersion{} = Repo.get!(GtfsVersion, run.gtfs_version_id)
    end

    test "reports an unknown run as not found", %{organization: organization} do
      assert {:error, :not_found} =
               ImportRuns.fail_source_not_installed(
                 organization.id,
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate()
               )
    end
  end

  describe "a runner that receives its source" do
    setup :hold_workers

    test "claims the run before the first copy of the upload and starts no worker until install",
         %{organization: organization} do
      run = pending_run(organization, "Ordered Feed")

      {:ok, runner} =
        Runner.start_import(organization.id, run.id, run.lease_token, caller: self())

      attach_staging_probe(runner, run)

      assert {:ok, staged} =
               SourceStorage.stage(organization.id, run.id, uploads(@levels_content))

      assert_received {:staging_started, at_first_copy}
      claimed_token = :sys.get_state(runner).lease_token
      assert at_first_copy.run_state == "running"
      assert at_first_copy.run_token == claimed_token
      refute claimed_token == run.lease_token
      assert at_first_copy.worker == nil
      refute_received {:blocking_import_worker_started, _worker}

      assert :ok = Runner.install_source(runner, staged)
      assert_receive {:blocking_import_worker_started, worker}, 2_000
      assert :sys.get_state(runner).task_pid == worker
      send(worker, :finish)
    end

    test "keeps running when the caller exits, the deadline message arrives late or a second call comes",
         %{organization: organization} do
      run = pending_run(organization, "Installed Feed")
      caller = spawn_parked_caller()
      caller_ref = Process.monitor(caller)

      {:ok, runner} =
        Runner.start_import(organization.id, run.id, run.lease_token, caller: caller)

      assert :ok = Runner.install_source(runner, [])
      assert_receive {:blocking_import_worker_started, worker}, 2_000

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, _reason}
      send(runner, :source_install_timeout)

      assert :sys.get_state(runner).task_pid == worker
      assert {:error, :not_awaiting_source} = Runner.install_source(runner, [])
      assert {:error, :not_awaiting_source} = Runner.cancel_source(runner)
      assert Repo.get!(Run, run.id).state == "running"
      send(worker, :finish)
    end
  end

  describe "a runner with the default worker" do
    test "publishes the import after its source is installed", %{organization: organization} do
      run = pending_run(organization, "Published Feed")

      {:ok, runner} =
        Runner.start_import(organization.id, run.id, run.lease_token, caller: self())

      ref = Process.monitor(runner)
      {:ok, run_dir} = SourceStorage.run_dir(organization.id, run.id)
      on_exit(fn -> SourceStorage.remove(organization.id, run.id) end)

      {:ok, staged} = SourceStorage.stage(organization.id, run.id, uploads(@levels_content))
      assert :ok = Runner.install_source(runner, staged)

      assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 30_000
      assert %Run{state: "published"} = Repo.get!(Run, run.id)

      assert %GtfsVersion{publication_status: "published"} =
               Repo.get!(GtfsVersion, run.gtfs_version_id)

      refute File.exists?(run_dir)
    end
  end

  describe "a runner at capacity" do
    setup :hold_workers

    test "returns busy and leaves the run pending and unclaimed", %{organization: organization} do
      held = pending_run(organization, "Occupant Feed")
      {:ok, _holder} = Runner.start_import(organization.id, held.id, held.lease_token, files: [])
      assert_receive {:blocking_import_worker_started, worker}, 2_000
      refused = pending_run(organization, "Refused Feed")
      attach_staging_probe(nil, refused)

      assert {:error, :busy} =
               Runner.start_import(organization.id, refused.id, refused.lease_token,
                 caller: self()
               )

      assert %Run{state: "pending", lease_token: token} = Repo.get!(Run, refused.id)
      assert token == refused.lease_token
      assert %{active: 1} = DynamicSupervisor.count_children(RunnerSupervisor)
      refute_received {:staging_started, _snapshot}
      send(worker, :finish)
    end
  end

  # Replaces the import worker with one that reports its start and then waits for
  # `:finish`, so a case can tell whether, and when, the runner started it.
  defp hold_workers(_context) do
    Application.put_env(
      :gtfs_planner,
      :import_worker_module,
      GtfsPlanner.Support.BlockingImportWorker
    )

    Application.put_env(:gtfs_planner, :blocking_import_worker_owner, self())
    :ok
  end

  # The actor is an active editor with a collision-proof email: committed rows left by
  # other test files can already hold the sequential `user-N@example.com` addresses.
  # A caller that stays alive until the test kills it. The bare receive parks it without a
  # sleep, and nothing ever sends :stop.
  defp spawn_parked_caller do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp pending_run(organization, name) do
    editor = user_fixture(%{email: "handshake-#{Ecto.UUID.generate()}@example.com"})
    organization_membership_fixture(editor, organization)

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(
        organization.id,
        %{id: editor.id, email: editor.email},
        %{name: name}
      )

    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ImportRuns.topic(run.id))
    run
  end

  # A claimed run: the run as it was created (carrying the single-use preparation token) and
  # the lease token the claim issued.
  defp claimed_run(organization, name) do
    run = pending_run(organization, name)

    {:ok, _claimed, _version, token} =
      ImportRuns.claim_import(organization.id, run.id, run.lease_token)

    {run, token}
  end

  # Upload entries as LiveView hands them over: a temporary path and the client's name.
  defp uploads(content) do
    directory = Path.join(System.tmp_dir!(), "source-handshake-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "upload")
    File.write!(path, content)
    [%{path: path, filename: "levels.txt"}]
  end

  # Leaves a staged copy in the run's directory for the runner to remove.
  defp stage_directory(organization, run) do
    {:ok, _staged} = SourceStorage.stage(organization.id, run.id, uploads(@levels_content))
    on_exit(fn -> SourceStorage.remove(organization.id, run.id) end)
    {:ok, run_dir} = SourceStorage.run_dir(organization.id, run.id)
    assert File.dir?(run_dir)
  end

  # `SourceStorage.stage/4` announces the start of every staging call, in the staging
  # process and before it copies a byte. The probe records what the database and the
  # runner look like at that moment.
  defp attach_staging_probe(runner, run) do
    handler_id = "source-handshake-#{System.unique_integer([:positive])}"
    config = %{owner: self(), runner: runner, run_id: run.id}
    :ok = :telemetry.attach(handler_id, @staging_event, &__MODULE__.record_staging/4, config)
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def record_staging(_event, _measurements, _metadata, %{owner: owner, runner: runner} = config) do
    run = Repo.get!(Run, config.run_id)
    worker = if is_pid(runner), do: :sys.get_state(runner).task_pid

    send(
      owner,
      {:staging_started, %{run_state: run.state, run_token: run.lease_token, worker: worker}}
    )
  end

  defp assert_closed_without_source(organization, run) do
    assert %Run{state: "failed", reason_code: "source_not_installed", phase: "upload"} =
             closed = Repo.get!(Run, run.id)

    assert closed.lease_token == nil
    run_id = run.id
    assert_received {:import_run_changed, ^run_id}

    assert Repo.get(GtfsVersion, run.gtfs_version_id) == nil
    assert ImportRuns.list_recoverable(organization.id) == []

    {:ok, run_dir} = SourceStorage.run_dir(organization.id, run.id)
    refute File.exists?(run_dir)
    refute_received {:blocking_import_worker_started, _worker}
    RunnerSlots.await_idle()
    assert %{active: 0} = DynamicSupervisor.count_children(RunnerSupervisor)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)
end
