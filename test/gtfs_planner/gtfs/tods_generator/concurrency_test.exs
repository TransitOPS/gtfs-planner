defmodule GtfsPlanner.Gtfs.TodsGenerator.ConcurrencyTest do
  @moduledoc """
  Step 7: one generation per scoped request token, under real transactions and
  independent connections.

  `apply_test.exs` isolates the save's own failures on one sandboxed connection.
  This file isolates the parts only real concurrency and the production transaction
  boundary can show:

    * two independent connections apply the same request token at once: both answer
      with the same receipt, exactly one generation commits, and every attempt ran
      through the production `ReviewedApplyTransaction.Repo` at SERIALIZABLE
      isolation (observed through the repo's own query telemetry);
    * three transient serialization failures exhaust the retry owner, which reports
      `:busy` without raising and leaves nothing written;
    * one transient failure followed by a committed membership revocation proves the
      retried attempt re-runs authorization: the second attempt is `:forbidden` and
      no block, run, line or receipt exists.

  Every case commits its own disposable organization, version, actor and schedule
  on an own connection, because the racing applies run on their own connections and
  must see them, and deletes exactly that organization's rows in `on_exit` even when
  the case fails. The production transaction module is selected with the application
  config the module reads at call time, and restored afterwards.

  The transient failures are real `%Postgrex.Error{}` values for SQLSTATE 40001
  raised through the configured transaction boundary, which is the seam the boundary
  exists to substitute; the retried attempt itself runs the production adapter. No
  live serialization failure or shared-connection task is presented as an
  interleaving.

  Run with:
  `mix test test/gtfs_planner/gtfs/tods_generator/concurrency_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.TodsGeneratorFixtures
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.TodsGeneration
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Repo

  @moduletag timeout: 120_000

  @receive_timeout 5_000
  @task_timeout 90_000

  setup :verify_on_exit!

  describe "two connections racing one request token" do
    test "commit once and both answer with the same receipt" do
      scope = committed_world()
      on_exit(fn -> cleanup_committed_world(scope) end)

      # The production boundary, absent the test override, so the race runs at
      # SERIALIZABLE isolation on real connections.
      use_production_transaction()

      counter = :counters.new(1, [])
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:gtfs_planner, :repo, :query],
          fn _event, _measurements, metadata, counter ->
            if metadata.query == "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE" do
              :counters.add(counter, 1, 1)
            end
          end,
          counter
        )

      try do
        parent = self()

        # A barrier so both connections begin their transaction together rather than
        # in whatever order the scheduler happens to run them: the race is the point,
        # and each task reports ready before it applies.
        tasks =
          for _connection <- 1..2 do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> :ok
              end

              unboxed(fn -> Gtfs.apply_tods_generation(scope.audit, scope.request) end)
            end)
          end

        # Both tasks report ready from their own spawned process, so the two
        # messages can arrive in either order; the barrier needs both present,
        # not a fixed order.
        ready_pids =
          for _task <- tasks do
            assert_receive {:ready, pid}, @receive_timeout
            pid
          end

        assert MapSet.new(ready_pids) == MapSet.new(Enum.map(tasks, & &1.pid))

        Enum.each(tasks, fn task -> send(task.pid, :go) end)

        results = Enum.map(tasks, &Task.await(&1, @task_timeout))

        # One serializable transaction per attempt, and a race needs at least the
        # winner's attempt and the loser's retry.
        assert :counters.get(counter, 1) >= 2

        assert Enum.all?(results, &match?({:ok, _}, &1)),
               "a racing connection was refused: #{inspect(results)}"

        receipts = Enum.map(results, fn {:ok, receipt} -> receipt end)
        assert receipts |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

        # One generation committed: one receipt, one new block, one assignment, one
        # line, slot and operator per proposal.
        assert receipt_count(scope) == 1
        assert generated_block_count(scope) == 1
        assert block_attribute_count(scope) == 1
        assert line_count(scope) == scope.line_count
        assert slot_count(scope) == scope.line_count
        assert operator_count(scope) == scope.line_count
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "exhausted attempts" do
    test "three transient failures report :busy and write nothing" do
      scope = committed_world()
      on_exit(fn -> cleanup_committed_world(scope) end)
      use_transaction_mock()

      # A fourth call has no expectation left, so it would raise instead of reaching
      # `:busy`: the assertion below observes the attempt bound itself.
      expect(ReviewedApplyTransactionMock, :run, 3, fn _transaction, _options ->
        raise postgrex_serialization_failure()
      end)

      assert {:error, :busy} =
               unboxed(fn -> Gtfs.apply_tods_generation(scope.audit, scope.request) end)

      assert receipt_count(scope) == 0
      assert generated_block_count(scope) == 0
      assert line_count(scope) == 0
      assert operator_count(scope) == 0
    end
  end

  describe "a transient failure with a revoked editor" do
    test "the retried attempt re-runs authorization and refuses the write" do
      scope = committed_world()
      on_exit(fn -> cleanup_committed_world(scope) end)
      use_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, 1, fn _transaction, _options ->
        # The revocation commits while the first attempt is failing, so an attempt
        # that did not re-read authorization would write after it.
        revoke_membership(scope)
        raise postgrex_serialization_failure()
      end)

      # The retried attempt runs the production transaction boundary.
      expect(ReviewedApplyTransactionMock, :run, 1, fn transaction, options ->
        ReviewedApplyTransaction.Repo.run(transaction, options)
      end)

      assert {:error, :forbidden} =
               unboxed(fn -> Gtfs.apply_tods_generation(scope.audit, scope.request) end)

      assert receipt_count(scope) == 0
      assert generated_block_count(scope) == 0
      assert block_attribute_count(scope) == 0
      assert line_count(scope) == 0
      assert operator_count(scope) == 0
    end
  end

  # --- the committed world ---------------------------------------------------

  # One committed world on an own connection, because both racing applies run on
  # their own connections and must see it. The preview is composed here too, so the
  # request carries the same normalized input and fingerprint a page would hold.
  defp committed_world do
    unboxed(fn ->
      world =
        roster_world_fixture(extra_trips: [{"gen-a", "WK", "RIV", "RIV", "04:00:00", "04:30:00"}])

      assert {:ok, preview} = roster_preview(world)

      %{
        organization_id: world.organization.id,
        version_id: world.version.id,
        actor_id: world.audit.actor_id,
        audit: world.audit,
        line_count: length(preview.roster_lines),
        request: %{
          request_id: Ecto.UUID.generate(),
          input: preview.normalized_inputs,
          source_fingerprint: preview.source_fingerprint
        }
      }
    end)
  end

  # Deletes exactly the rows `committed_world/0` created and the generation's own
  # rows, on an own connection so the deletion is not part of the SQL Sandbox
  # transaction and runs even when the case failed. The organization cascades every
  # table whose `organization_id` reference does; `stops`, `levels` and
  # `stop_levels` reference it without a cascade and go first.
  defp cleanup_committed_world(scope) do
    unboxed(fn ->
      organization_id = Ecto.UUID.dump!(scope.organization_id)

      Repo.query!("DELETE FROM stop_levels WHERE organization_id = $1", [organization_id])
      Repo.query!("DELETE FROM levels WHERE organization_id = $1", [organization_id])
      Repo.query!("DELETE FROM stops WHERE organization_id = $1", [organization_id])
      Repo.query!("DELETE FROM organizations WHERE id = $1", [organization_id])
      Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(scope.actor_id)])
    end)
  end

  defp revoke_membership(scope) do
    Repo.delete_all(
      from(m in UserOrgMembership,
        where: m.user_id == ^scope.actor_id and m.organization_id == ^scope.organization_id
      )
    )
  end

  # --- counters and configuration -------------------------------------------

  defp receipt_count(scope), do: scoped_count(from(g in TodsGeneration), scope)

  defp block_attribute_count(scope), do: scoped_count(from(a in BlockAttribute), scope)

  defp line_count(scope), do: scoped_count(from(l in RosterLine), scope)

  defp slot_count(scope), do: scoped_count(from(d in RosterLineDay), scope)

  defp operator_count(scope) do
    Repo.aggregate(
      from(o in Operator, where: o.organization_id == ^scope.organization_id),
      :count
    )
  end

  defp generated_block_count(scope) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization_id and
            t.gtfs_version_id == ^scope.version_id and t.block_id == "103"
      ),
      :count
    )
  end

  defp scoped_count(query, scope) do
    query
    |> scoped(scope)
    |> Repo.aggregate(:count)
  end

  defp scoped(query, scope) do
    where(
      query,
      [row],
      row.organization_id == ^scope.organization_id and
        row.gtfs_version_id == ^scope.version_id
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # The application config the generator reads at call time. The original is
  # captured before the change and restored in `on_exit`.
  defp use_production_transaction do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransaction.Repo)

    on_exit(fn -> restore_transaction(previous) end)
  end

  defp use_transaction_mock do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransactionMock)

    on_exit(fn -> restore_transaction(previous) end)
  end

  defp restore_transaction(previous) do
    case previous do
      {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
      :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
    end
  end

  # What a real server raises for SQLSTATE 40001; the retry owner classifies it by
  # the normalised atom, so no live serialization failure is needed to exercise it.
  defp postgrex_serialization_failure do
    %Postgrex.Error{
      postgres: %{
        code: :serialization_failure,
        message: "could not serialize access",
        severity: "ERROR"
      }
    }
  end
end
