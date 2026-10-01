defmodule GtfsPlanner.Validations.RunnerTest do
  @moduledoc """
  `Validations.start_mobility_data_run/4` through the application-started
  `Validations.RunnerSupervisor` (one slot, `config :gtfs_planner, :runner_limits`)
  and the real `Validations.Runner`, claim, lease and terminal writes.

  Mox replaces the validator behaviour in global mode, because the runner calls
  it from a task. The stub reports its task pid and holds until the test releases
  it, so each test controls when the validator returns. The sandbox serializes
  every process on one connection, so these cases do not interleave two real
  database connections.
  """

  use GtfsPlanner.DataCase, async: false

  import Mox, only: [set_mox_global: 1, verify_on_exit!: 1]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Gtfs.ValidatorMock
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.{Runner, ValidationRun}

  @moduletag :capture_log

  @supervisor GtfsPlanner.Validations.RunnerSupervisor

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    editor = editor_fixture(organization)

    on_exit(fn -> RunnerSlots.await_idle() end)

    %{organization: organization, version: version, editor: editor}
  end

  describe "a validator that returns" do
    test "completes the run and notifies subscribers once the completed row is stored", ctx do
      hold_validator({:ok, result()})
      {:ok, run} = start_run(ctx)
      subscribe(run)
      {task, runner_ref} = await_validating(run)

      assert %ValidationRun{status: "running", lease_token: token} =
               Repo.get!(ValidationRun, run.id)

      assert is_binary(token)

      send(task, :release)

      run_id = run.id
      assert_receive {:validation_completed, ^run_id}

      # The message follows the write, so the row read on receipt is already stored.
      assert %ValidationRun{
               status: "completed",
               errors_count: 1,
               warnings_count: 2,
               infos_count: 3,
               duration_ms: 1500,
               result_json: %{"notices" => []},
               lease_token: nil,
               lease_expires_at: nil
             } = completed = Repo.get!(ValidationRun, run.id)

      assert completed.completed_at
      assert_receive {:DOWN, ^runner_ref, :process, _runner, :normal}
      assert active_runners() == 0
    end

    test "fails the run with the validator's reason", ctx do
      failed = fail_with(ctx, :timeout)

      assert failed.error_details == "timeout"
      assert failed.completed_at
      assert failed.lease_token == nil
    end

    test "stores the tag of a CLI failure, not its output", ctx do
      failed = fail_with(ctx, {:cli_failed, 3, String.duplicate("x", 65_536)})

      assert failed.error_details == "cli_failed"
    end

    test "stores an invalid report as invalid_report", ctx do
      failed = fail_with(ctx, {:invalid_report, :missing_notices})

      assert failed.error_details == "invalid_report"
    end

    test "fails the run as executor_lost when the validator task crashes", ctx do
      test_pid = self()

      Mox.stub(ValidatorMock, :validate, fn _organization_id, _version_id, opts ->
        send(test_pid, {:validating, self(), Keyword.fetch!(opts, :validation_run_id)})

        receive do
          :release -> raise "validator crashed"
        end
      end)

      {:ok, run} = start_run(ctx)
      subscribe(run)
      {task, runner_ref} = await_validating(run)

      send(task, :release)

      run_id = run.id
      assert_receive {:validation_failed, ^run_id}
      assert Repo.get!(ValidationRun, run.id).error_details == "executor_lost"
      assert_receive {:DOWN, ^runner_ref, :process, _runner, :normal}
    end
  end

  describe "a lease the runner no longer owns" do
    test "is not overwritten by the result and no completion is announced", ctx do
      hold_validator({:ok, result()})
      {:ok, run} = start_run(ctx)
      subscribe(run)
      {task, runner_ref} = await_validating(run)

      expire_lease(run)

      assert [%ValidationRun{status: "failed"}] =
               Validations.reconcile_expired(ctx.organization.id)

      run_id = run.id
      assert_receive {:validation_failed, ^run_id}

      send(task, :release)

      assert_receive {:DOWN, ^runner_ref, :process, _runner, {:shutdown, :lease_lost}}
      refute_receive {:validation_completed, _run_id}
      refute_receive {:validation_failed, _run_id}

      assert %ValidationRun{status: "failed", error_details: "lease_expired", result_json: nil} =
               Repo.get!(ValidationRun, run.id)
    end

    test "cancels the validator at the next heartbeat and releases the slot", ctx do
      put_env(:validation_runner_heartbeat_ms, 10)
      hold_validator({:ok, result()})
      {:ok, run} = start_run(ctx)
      {task, runner_ref} = await_validating(run)
      task_ref = Process.monitor(task)

      expire_lease(run)

      assert_receive {:cancelled, ^task}
      assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}
      assert_receive {:DOWN, ^runner_ref, :process, _runner, {:shutdown, :lease_lost}}
      assert active_runners() == 0

      # The run keeps the state the lease holder left it in: the runner wrote nothing.
      assert %ValidationRun{status: "running", error_details: nil} =
               Repo.get!(ValidationRun, run.id)
    end

    test "is renewed by a heartbeat while the run is running", ctx do
      hold_validator({:ok, result()})
      {:ok, run} = start_run(ctx)
      {task, runner_ref} = await_validating(run)
      [{_id, runner, _type, _modules}] = DynamicSupervisor.which_children(@supervisor)

      soon = DateTime.add(DateTime.utc_now(), 30, :second)
      set_lease_expiry(run, soon)

      send(runner, :renew_lease)
      _ = :sys.get_state(runner)

      renewed = Repo.get!(ValidationRun, run.id).lease_expires_at
      assert DateTime.compare(renewed, soon) == :gt

      send(task, :release)
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, :normal}
    end
  end

  describe "a runner that is shut down" do
    test "cancels its validator task before it exits", ctx do
      hold_validator({:ok, result()})
      {:ok, run} = start_run(ctx)
      {task, runner_ref} = await_validating(run)
      [{_id, runner, _type, _modules}] = DynamicSupervisor.which_children(@supervisor)

      :ok = DynamicSupervisor.terminate_child(@supervisor, runner)

      assert_receive {:cancelled, ^task}
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, :shutdown}
      assert %ValidationRun{status: "running"} = Repo.get!(ValidationRun, run.id)
    end
  end

  describe "start_mobility_data_run/4 at capacity" do
    test "returns :busy, closes the refused run as busy and leaves the running one alone",
         ctx do
      hold_validator({:ok, result()})
      {:ok, first} = start_run(ctx)
      subscribe(first)
      {task, runner_ref} = await_validating(first)
      assert active_runners() == 1

      assert {:error, :busy} = start_run(ctx)

      refused = other_run(ctx, first)
      assert %ValidationRun{status: "failed", error_details: "busy", lease_token: nil} = refused
      assert refused.completed_at
      assert active_runners() == 1
      assert %ValidationRun{status: "running"} = Repo.get!(ValidationRun, first.id)
      refute_receive {:validating, _task, _run_id}

      send(task, :release)
      first_id = first.id
      assert_receive {:validation_completed, ^first_id}
      assert_receive {:DOWN, ^runner_ref, :process, _runner, :normal}
      assert active_runners() == 0
    end

    test "admits the next run once the first runner exits", ctx do
      hold_validator({:ok, result()})
      {:ok, first} = start_run(ctx)
      {task, runner_ref} = await_validating(first)
      assert {:error, :busy} = start_run(ctx)

      send(task, :release)
      assert_receive {:DOWN, ^runner_ref, :process, _runner, :normal}

      assert {:ok, third} = start_run(ctx)
      {third_task, _third_runner_ref} = await_validating(third)
      send(third_task, :release)
    end

    test "does not list the refused run as a feed check", ctx do
      hold_validator({:ok, result()})
      {:ok, first} = start_run(ctx)
      subscribe(first)
      {task, _runner_ref} = await_validating(first)
      assert {:error, :busy} = start_run(ctx)
      send(task, :release)
      first_id = first.id
      assert_receive {:validation_completed, ^first_id}

      assert %ValidationRun{id: ^first_id} =
               Validations.latest_feed_check(ctx.organization.id, ctx.version.id)

      assert [%ValidationRun{id: ^first_id}] =
               Validations.list_recent_validation_runs(ctx.organization.id, ctx.version.id)
    end
  end

  describe "start_mobility_data_run/4 authorization and input" do
    test "refuses a user without a membership and creates no run", ctx do
      assert {:error, :forbidden} =
               Validations.start_mobility_data_run(
                 ctx.organization.id,
                 ctx.version.id,
                 "mobility_data",
                 user_fixture()
               )

      assert Validations.list_validation_runs(ctx.organization.id, ctx.version.id) == []
      assert active_runners() == 0
    end

    test "refuses an editor of another organization and creates no run", ctx do
      other_editor = editor_fixture(organization_fixture())

      assert {:error, :forbidden} =
               Validations.start_mobility_data_run(
                 ctx.organization.id,
                 ctx.version.id,
                 "mobility_data",
                 other_editor
               )

      assert Validations.list_validation_runs(ctx.organization.id, ctx.version.id) == []
    end

    test "refuses a run type the MobilityData validator does not run", ctx do
      assert {:error, :invalid_run_type} =
               Validations.start_mobility_data_run(
                 ctx.organization.id,
                 ctx.version.id,
                 "station_reachability",
                 ctx.editor
               )

      assert Validations.list_validation_runs(ctx.organization.id, ctx.version.id) == []
    end

    test "closes the run as not_started when the runner cannot start", ctx do
      delete_env(:validator_module)

      assert {:error, :not_started} = start_run(ctx)

      assert [%ValidationRun{status: "failed", error_details: "not_started", lease_token: nil}] =
               Validations.list_validation_runs(ctx.organization.id, ctx.version.id)
    end

    test "does not claim a run that is no longer started", ctx do
      {:ok, run} =
        Validations.create_validation_run(ctx.organization.id, ctx.version.id, "mobility_data")

      {:ok, _claimed, token} = Validations.claim_run(ctx.organization.id, run.id)

      assert {:error, :claim_failed} =
               DynamicSupervisor.start_child(
                 @supervisor,
                 {Runner, organization_id: ctx.organization.id, run_id: run.id}
               )

      assert %ValidationRun{status: "running", lease_token: ^token} =
               Repo.get!(ValidationRun, run.id)
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp result do
    %Result{
      summary: %{errors: 1, warnings: 2, infos: 3},
      notices: [],
      duration_ms: 1500,
      validated_at: ~U[2026-01-01 00:00:00.000000Z]
    }
  end

  # Reports its task pid and run id, then holds. A cancel is reported and ends the
  # task the way the real validator does.
  defp hold_validator(outcome) do
    test_pid = self()

    Mox.stub(ValidatorMock, :validate, fn _organization_id, _version_id, opts ->
      send(test_pid, {:validating, self(), Keyword.fetch!(opts, :validation_run_id)})

      receive do
        :release ->
          outcome

        :gtfs_validator_cancel ->
          send(test_pid, {:cancelled, self()})
          {:error, :cancelled}
      end
    end)
  end

  defp start_run(ctx) do
    Validations.start_mobility_data_run(
      ctx.organization.id,
      ctx.version.id,
      "mobility_data",
      ctx.editor
    )
  end

  defp subscribe(run), do: Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Validations.topic(run.id))

  # Waits for the validator to start (the runner has claimed the run) and returns
  # its task pid and a monitor on the runner that owns it.
  defp await_validating(run) do
    run_id = run.id
    assert_receive {:validating, task, ^run_id}, 5_000
    [{_id, runner, _type, _modules}] = DynamicSupervisor.which_children(@supervisor)

    {task, Process.monitor(runner)}
  end

  defp fail_with(ctx, reason) do
    hold_validator({:error, reason})
    {:ok, run} = start_run(ctx)
    subscribe(run)
    {task, runner_ref} = await_validating(run)

    send(task, :release)

    run_id = run.id
    assert_receive {:validation_failed, ^run_id}
    assert_receive {:DOWN, ^runner_ref, :process, _runner, :normal}

    failed = Repo.get!(ValidationRun, run.id)
    assert failed.status == "failed"
    failed
  end

  defp other_run(ctx, run) do
    Repo.one!(
      from(r in ValidationRun,
        where: r.organization_id == ^ctx.organization.id and r.id != ^run.id
      )
    )
  end

  defp expire_lease(run), do: set_lease_expiry(run, ~U[2000-01-01 00:00:00.000000Z])

  defp set_lease_expiry(run, expiry) do
    from(r in ValidationRun, where: r.id == ^run.id)
    |> Repo.update_all(set: [lease_expires_at: expiry])
  end

  # The supervisor removes an exited child when it handles the exit message; the
  # system call is queued behind it, so the count no longer includes that child.
  defp active_runners do
    _ = :sys.get_state(@supervisor)
    DynamicSupervisor.count_children(@supervisor).active
  end

  defp put_env(key, value) do
    restore_on_exit(key)
    Application.put_env(:gtfs_planner, key, value)
  end

  defp delete_env(key) do
    restore_on_exit(key)
    Application.delete_env(:gtfs_planner, key)
  end

  defp restore_on_exit(key) do
    previous = Application.fetch_env(:gtfs_planner, key)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:gtfs_planner, key, old)
        :error -> Application.delete_env(:gtfs_planner, key)
      end
    end)
  end
end
