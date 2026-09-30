defmodule GtfsPlanner.Support.StopEditingCollisionRunner do
  @moduledoc """
  A `:reviewed_apply_transaction` runner that manufactures a generated stop-ID
  collision, so `StopEditing.create_stop/2`'s retry path can be tested.

  The race `create_stop/2` handles is narrow and real: it allocates a stop ID
  under the version lock, and another session can commit that same number
  between the allocation and the insert. Reproducing that window by timing is
  not possible in a sandboxed test — the command's own transaction holds the
  connection — so this runner simulates the outcome.

  Each time the command reaches the runner it reports
  `{:error, :generated_collision}` — what `create_stop/2` rolls back when the
  database rejects the ID it chose — but first commits the stop row that another
  session would have won the race with. The command's next attempt then
  allocates against committed state and must pick the number after.

  With `always: true` it commits a *new* higher number every attempt, so each
  retry collides again. That is the only way to reach the exhausted-retries
  `:busy` path, which is otherwise unreachable from a test.

  ## What this proves, and what it does not

  It proves the retry *contract*: a reported collision reruns the closure,
  allocation is re-read from committed rows, the audit entry belongs to the stop
  that finally committed, and three collisions answer `:busy` rather than
  looping.

  It does not prove the unique index fires, because it does not depend on one.
  That a real rejection reaches this runner at all is covered separately by the
  typed-duplicate case in the create test, which inserts a genuine duplicate and
  asserts it arrives as a changeset error on `:stop_id` rather than a collision —
  the other branch of the same `Repo.insert/1` match. Between them both outcomes
  of a rejected insert are covered; the narrow window in which the index fires
  for a *generated* ID is not, and is recorded as a residual risk in the step
  learning.

  ## Why the state lives in the process dictionary

  The configured seam is a module, not an instance: production code calls
  `runner.run(transaction)`, so the config value must be an atom. A struct there
  raises "modules must always be an atom" the moment the command tries to call
  it.

  So this is a module, and its per-test state lives in the calling process's
  dictionary. `Sandbox.unboxed_run/2` executes the command in the test's own
  process, so the runner and the test that installed it are the same process and
  the counter the test asserts on is the counter the runner incremented. That
  also keeps concurrent tests from seeing each other's collisions, which a
  process-global agent would not.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction.Sandbox
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopNaming
  alias GtfsPlanner.Repo

  @behaviour GtfsPlanner.Gtfs.ReviewedApplyTransaction

  @state_key :stop_editing_collision_runner_state

  @doc """
  Installs this runner as the configured transaction runner for the current test.

  `scoped` is the `%{organization_id:, gtfs_version_id:}` the injected rows
  belong to and `stop_id` is the number the command is expected to allocate and
  then lose. `always: true` keeps colliding past the first attempt. Restores the
  previous runner when the test exits.

  Returns `:ok`; the attempt count is read back with `attempts/0`.
  """
  @spec install(map(), String.t(), keyword()) :: :ok
  def install(scoped, stop_id, opts \\ []) do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    put_state(%{
      scoped: scoped,
      stop_id: stop_id,
      always: Keyword.get(opts, :always, false),
      attempts: 0,
      transaction: nil,
      options: []
    })

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Process.delete(@state_key)

      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    :ok
  end

  @doc "How many generated-ID collisions this runner has manufactured."
  @spec attempts() :: non_neg_integer()
  def attempts do
    case Process.get(@state_key) do
      %{attempts: attempts} -> attempts
      nil -> 0
    end
  end

  @impl true
  def run(transaction), do: run(transaction, [])

  @impl true
  def run(transaction, options) do
    case Process.get(@state_key) do
      nil ->
        # Installed, but this is not the process that installed it. Defer to the
        # real runner rather than guessing at another test's state.
        Sandbox.run(transaction, options)

      state ->
        collide(%{state | transaction: transaction, options: options})
    end
  end

  # Commits the row another session would have committed, then reports the
  # rejection. Doing both in one step is what makes the simulation terminate:
  # injecting only after observing a real collision would wait on a collision
  # that this row is the only thing able to cause.
  #
  # Once the collisions this test asked for are spent, the real transaction runs
  # so the command can actually commit.
  defp collide(%{always: false, attempts: 0} = state) do
    put_state(%{state | attempts: 1})
    insert_conflicting_stop(state.stop_id)
    {:error, :generated_collision}
  end

  defp collide(%{always: true} = state) do
    put_state(%{state | attempts: state.attempts + 1})
    insert_conflicting_stop(next_free_stop_id(state.scoped))
    {:error, :generated_collision}
  end

  defp collide(state), do: Sandbox.run(state.transaction, state.options)

  defp put_state(state), do: Process.put(@state_key, state)

  defp insert_conflicting_stop(stop_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(Stop, [
      %{
        id: Ecto.UUID.generate(),
        organization_id: state().scoped.organization.id,
        gtfs_version_id: state().scoped.version.id,
        stop_id: stop_id,
        stop_name: "Concurrent writer",
        stop_lat: Decimal.new("44.6210"),
        stop_lon: Decimal.new("-124.0530"),
        location_type: 0,
        inserted_at: now,
        updated_at: now
      }
    ])

    :ok
  end

  # The number the next allocation is about to want, so the collision has to
  # take *that* one. `StopNaming.next_stop_id/3` is asked rather than
  # reimplemented: it owns the highest-plus-one rule, and a second copy of it in
  # a test helper is exactly the kind of drift that makes a test pass for the
  # wrong reason.
  defp next_free_stop_id(scoped) do
    StopNaming.next_stop_id(scoped_stop_ids(scoped), [], {0, "Concurrent writer"})
  end

  defp scoped_stop_ids(scoped) do
    organization_id = scoped.organization.id
    gtfs_version_id = scoped.version.id

    Stop
    |> where(
      [s],
      s.organization_id == ^organization_id and
        s.gtfs_version_id == ^gtfs_version_id
    )
    |> select([s], s.stop_id)
    |> Repo.all()
  end

  defp state, do: Process.get(@state_key)
end
