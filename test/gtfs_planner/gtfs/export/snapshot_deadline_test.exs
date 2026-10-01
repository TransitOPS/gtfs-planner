defmodule GtfsPlanner.Gtfs.Export.SnapshotDeadlineTest do
  @moduledoc """
  An export snapshot has a deadline, and a build keeps its files in the run's
  private `.build` directory.

  Each case drives the production composition: `Export.Worker.build/4` or
  `Export.build_zips/4` over the real `Snapshot.Repo` repeatable-read adapter and
  `:operations` dispatch, and the ordinary artifact store. The deadline closes the
  database connection, and the SQL sandbox's ownership proxy ends its owner when
  that happens, so these cases cannot run on the sandbox. They run on a dedicated
  `DBConnection.ConnectionPool` repo, the pool production uses, started for the
  case. The rows are committed and removed by `on_exit`.

  A case that blocks the exporter inside the snapshot attaches a telemetry handler
  to the exporter process. The handler reports the backend and isolation level it
  sees, then waits, so the case asserts what the database did while the exporter
  was still blocked.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.{Calendar, CalendarAttribute, CalendarDate, Route, Stop, StopTime, Trip}
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.{ArtifactStorage, Run, Snapshot, Worker}
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @moduletag :capture_log
  @moduletag timeout: 60_000

  @actor %{id: Ecto.UUID.generate(), email: "snapshot-deadline@example.com"}
  @stage_deadline_ms 3_000

  # Holds the exporter inside the snapshot, after reporting its backend, until the
  # case resumes it. The pool closes the connection at the deadline while it waits.
  defmodule BlockingSnapshot do
    @moduledoc false
    @behaviour GtfsPlanner.Gtfs.Export.Snapshot

    @impl true
    def begin_read do
      %Postgrex.Result{rows: [[backend]]} = GtfsPlanner.Repo.query!("SELECT pg_backend_pid()")
      send(Process.get(:snapshot_deadline_owner), {:snapshot_blocked, self(), backend})

      receive do
        :resume -> :ok
      after
        30_000 -> :ok
      end
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "snapshot-deadline-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    put_env(:gtfs_task_artifacts_path, root)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  describe "the private build directory" do
    test "rejects a run id that is not a UUID before writing anything", %{root: root} do
      assert {:error, :invalid_scope} =
               Export.build_zips(Ecto.UUID.generate(), Ecto.UUID.generate(), :full,
                 run_id: "../../escape"
               )

      assert File.ls!(root) == []
    end

    test "reports unavailable storage when no artifact root is configured" do
      Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)

      assert {:error, :artifact_storage_unavailable} =
               Export.build_zips(Ecto.UUID.generate(), Ecto.UUID.generate(), :full,
                 run_id: Ecto.UUID.generate()
               )
    end
  end

  describe "an export on a committed feed" do
    setup [:committed_pool, :committed_world]

    test "the configured default deadline is 600,000 ms" do
      assert Application.fetch_env!(:gtfs_planner, :export_snapshot_timeout_ms) == 600_000
    end

    test "a run that finishes inside the deadline publishes a verified artifact and no build files",
         %{world: world, root: root} do
      {run, claimed, generation, token} = claimed_run(world, :operations)

      assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

      assert %Run{state: :ready} = Repo.get!(Run, run.id)

      assert {:ok, %{path: path, size: size}} =
               ExportRuns.claim_download(world.organization.id, world.version.id, run.id)

      assert File.stat!(path).size == size
      assert Path.dirname(path) == run_dir(root, world, run.id)
      refute File.exists?(build_dir(root, world, run.id))
    end

    test "a snapshot that outlives the deadline fails the run with snapshot_timeout", context do
      %{repo: repo, world: world, root: root} = context
      put_env(:gtfs_export_snapshot, BlockingSnapshot)
      put_env(:export_snapshot_timeout_ms, 200)
      {run, claimed, generation, token} = claimed_run(world, :full)
      tmp_before = tmp_build_dirs()

      task =
        start_export(repo, fn ->
          Worker.build(claimed, generation, token, ExportRuns.topic(run))
        end)

      send(task.pid, :start)
      exporter = task.pid

      assert_receive {:snapshot_blocked, ^exporter, backend}, 10_000

      # The exporter is still blocked: the pool closed its connection at the
      # deadline, and the files it is building are in the run's private directory.
      assert File.dir?(build_dir(root, world, run.id))
      assert_backend_released(backend)

      send(exporter, :resume)

      # The worker ends with a terminal write instead of crashing its runner.
      assert {:ok, :ok} = Task.yield(task, 15_000)

      assert %Run{state: :failed, failure_code: "snapshot_timeout", artifact_key: nil} =
               Repo.get!(Run, run.id)

      refute File.exists?(build_dir(root, world, run.id))
      assert tmp_build_dirs() -- tmp_before == []
    end

    test "a build killed inside the snapshot leaves files that reconcile removes with an unretained run",
         %{repo: repo, world: world, root: root} do
      run_id = Ecto.UUID.generate()
      tmp_before = tmp_build_dirs()

      task =
        start_export(repo, fn ->
          Export.build_zips(world.organization.id, world.version.id, :operations, run_id: run_id)
        end)

      {exporter, backend, _isolation} = block_at(:public_ids, task)

      assert [_ | _] = Path.wildcard(Path.join(build_dir(root, world, run_id), "*/stops.txt"))

      # What the runner does when a lease is lost: the process dies without
      # reaching its own cleanup.
      monitor = Process.monitor(exporter)
      Process.exit(exporter, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^exporter, :killed}, 10_000

      assert_backend_released(backend)
      assert File.dir?(build_dir(root, world, run_id))
      assert tmp_build_dirs() -- tmp_before == []

      assert {:ok, 0} = ArtifactStorage.reconcile([run_id], root: root)
      assert File.dir?(build_dir(root, world, run_id))

      assert {:ok, 1} = ArtifactStorage.reconcile([], root: root)
      refute File.exists?(run_dir(root, world, run_id))
    end
  end

  describe "an operations export that outlives the deadline" do
    setup [:committed_pool, :committed_world]

    test "expires while stop coordinates are resolved for estimation", context do
      assert_expires_during(:coordinates, context, estimate: :distance)
    end

    test "expires while movements are computed", context do
      assert_expires_during(:movement_computation, context)
    end

    test "expires while runs are derived", context do
      assert_expires_during(:run_derivation, context)
    end

    test "expires after the last public ID read, while rows and files are produced", context do
      assert_expires_during(:public_ids, context)
    end
  end

  # -- stage cases ------------------------------------------------------------

  # Blocks the exporter at `stage`, lets the deadline pass, and asserts that the
  # stage read inside a repeatable-read snapshot, the database released the
  # backend while the exporter was blocked, the export reported the deadline, and
  # the run's build directory is gone.
  defp assert_expires_during(stage, %{repo: repo, world: world, root: root}, opts \\ []) do
    put_env(:gtfs_export_snapshot, Snapshot.Repo)
    put_env(:export_snapshot_timeout_ms, @stage_deadline_ms)
    run_id = Ecto.UUID.generate()
    tmp_before = tmp_build_dirs()

    task =
      start_export(repo, fn ->
        Export.build_zips(
          world.organization.id,
          world.version.id,
          :operations,
          [run_id: run_id] ++ opts
        )
      end)

    {exporter, backend, isolation} = block_at(stage, task)

    assert isolation == "repeatable read"
    assert File.dir?(build_dir(root, world, run_id))
    assert_backend_released(backend)

    send(exporter, :resume)

    assert {:ok, {:error, :snapshot_timeout}} = Task.yield(task, 15_000)
    refute File.exists?(build_dir(root, world, run_id))
    assert tmp_build_dirs() -- tmp_before == []
  end

  # Starts the exporter task paused, attaches a barrier at `stage`, releases the
  # task and returns once it is blocked there.
  defp block_at(stage, task) do
    attach_barrier(stage, task.pid)
    send(task.pid, :start)
    exporter = task.pid

    assert_receive {:stage_blocked, ^exporter, backend, isolation}, 15_000
    {exporter, backend, isolation}
  end

  defp attach_barrier(stage, exporter) do
    handler_id = {__MODULE__, stage, exporter}

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {id, owner, exporter, at_stage?} ->
        if self() == exporter and at_stage?.(metadata) do
          :telemetry.detach(id)

          %Postgrex.Result{rows: [[backend, isolation]]} =
            Repo.query!("SELECT pg_backend_pid(), current_setting('transaction_isolation')")

          send(owner, {:stage_blocked, self(), backend, isolation})

          receive do
            :resume -> :ok
          after
            30_000 -> :ok
          end
        end
      end,
      {handler_id, self(), exporter, stage_matcher(stage)}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # The first query that only the named stage issues. Each runs inside the
  # export's snapshot transaction.
  defp stage_matcher(:coordinates) do
    &query_matches?(&1, ~r/SELECT \w+\."stop_id", \w+\."stop_lat", \w+\."stop_lon" FROM "stops"/)
  end

  defp stage_matcher(:movement_computation), do: &(&1[:source] == "blocking_settings")
  defp stage_matcher(:run_derivation), do: &(&1[:source] == "trip_runs")

  defp stage_matcher(:public_ids) do
    &query_matches?(&1, ~r/SELECT \w+\."service_id" FROM "calendar_dates"/)
  end

  defp query_matches?(metadata, pattern) do
    is_binary(metadata[:query]) and Regex.match?(pattern, metadata[:query])
  end

  # -- exporter task and database observation ---------------------------------

  # The exporter runs unlinked on its own process, which waits for `:start`, so a
  # barrier can be attached to its pid first. The dynamic repo and the owner of
  # the snapshot double are per-process, so the task sets both itself.
  defp start_export(repo, fun) do
    owner = self()

    Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn ->
      Repo.put_dynamic_repo(repo)
      Process.put(:snapshot_deadline_owner, owner)

      receive do
        :start -> fun.()
      end
    end)
  end

  defp assert_backend_released(backend, attempts \\ 1_000)

  defp assert_backend_released(backend, 0) do
    flunk("backend #{backend} still holds its transaction long after the deadline")
  end

  defp assert_backend_released(backend, attempts) do
    %Postgrex.Result{rows: rows} =
      Repo.query!("SELECT state FROM pg_stat_activity WHERE pid = $1", [backend])

    if Enum.any?(rows, fn [state] -> state == "active" or in_transaction?(state) end) do
      receive do
      after
        10 -> assert_backend_released(backend, attempts - 1)
      end
    else
      :ok
    end
  end

  defp in_transaction?(state), do: String.starts_with?(state || "", "idle in transaction")

  defp tmp_build_dirs, do: Path.wildcard(Path.join(System.tmp_dir!(), "gtfs_export_*"))

  # -- paths ------------------------------------------------------------------

  defp run_dir(root, world, run_id) do
    Path.join([Path.expand(root), "export-runs", world.organization.id, world.version.id, run_id])
  end

  defp build_dir(root, world, run_id), do: Path.join(run_dir(root, world, run_id), ".build")

  # -- committed feed ---------------------------------------------------------

  # A dedicated pool for the test process and the exporter. Its connections are
  # the ones the deadline closes; the sandboxed default pool is not touched.
  defp committed_pool(_context) do
    repo =
      start_supervised!(
        {Repo, name: nil, pool: DBConnection.ConnectionPool, pool_size: 4, log: false}
      )

    Repo.put_dynamic_repo(repo)
    put_env(:gtfs_export_snapshot, Snapshot.Repo)

    %{repo: repo}
  end

  # Two day types with five blocked trip pairs each: movement computation, run
  # derivation and public ID reads all run over real rows, and the run is
  # `:operations`. The rows are committed, so `on_exit` removes them through an
  # unboxed connection, which sees them from the default pool.
  defp committed_world(_context) do
    organization = organization_fixture(%{alias: "deadline-#{System.system_time(:nanosecond)}"})
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> delete_world(organization.id) end) end)

    version = gtfs_version_fixture(organization.id)
    route_fixture(organization.id, version.id, route_id: "R1", route_short_name: "1")

    for {stop_id, lat} <- [{"S1", "40.0000"}, {"S2", "40.0100"}, {"S3", "40.0200"}] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0")
      })
    end

    weekdays = %{monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1}
    weekend = %{saturday: 1, sunday: 1}
    none = %{monday: 0, tuesday: 0, wednesday: 0, thursday: 0, friday: 0, saturday: 0, sunday: 0}

    for {service_id, days} <- [{"WK", weekdays}, {"WE", weekend}] do
      calendar_service_fixture(
        organization.id,
        version.id,
        Map.merge(none, days) |> Map.merge(%{service_id: service_id, name: service_id})
      )

      for block <- 0..4 do
        blocked_pair(organization, version, service_id, block)
      end
    end

    %{world: %{organization: organization, version: version}}
  end

  # One block of two trips: S1 to S2 early, then S2 to S3 later, so the vehicle
  # needs no drive between them.
  defp blocked_pair(organization, version, service_id, block) do
    block_id = "#{service_id}-B#{block}"

    for {suffix, first_stop, last_stop, hour} <- [
          {"a", "S1", "S2", 6 + block},
          {"b", "S2", "S3", 12 + block}
        ] do
      blocked_trip_fixture(organization.id, version.id, "R1", %{
        trip_id: "#{block_id}-#{suffix}",
        service_id: service_id,
        block_id: block_id,
        first_stop: first_stop,
        last_stop: last_stop,
        first_arrival: clock(hour, "00"),
        last_arrival: clock(hour, "30")
      })
    end
  end

  defp clock(hour, minutes),
    do: "#{String.pad_leading(Integer.to_string(hour), 2, "0")}:#{minutes}:00"

  defp claimed_run(world, export_type) do
    {:ok, run} =
      ExportRuns.create_pending(world.organization.id, world.version.id, @actor, export_type)

    {:ok, claimed, generation, token} = ExportRuns.claim(world.organization.id, run.id, :build)
    {run, claimed, generation, token}
  end

  # Child rows first: version-owned tables also reference their version through a
  # composite `NO ACTION` key, and stops reference the organization without a
  # cascade, so nothing here relies on the cascade order.
  defp delete_world(organization_id) do
    for schema <- [Run, StopTime, Trip, Route, CalendarAttribute, CalendarDate, Calendar, Stop] do
      Repo.delete_all(from(row in schema, where: row.organization_id == ^organization_id))
    end

    Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
  end

  # -- environment ------------------------------------------------------------

  defp put_env(key, value) do
    previous = Application.fetch_env(:gtfs_planner, key)
    Application.put_env(:gtfs_planner, key, value)
    on_exit(fn -> restore_env(key, previous) end)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)
end
