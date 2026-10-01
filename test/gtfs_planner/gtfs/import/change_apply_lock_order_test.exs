defmodule GtfsPlanner.Gtfs.Import.ChangeApplyLockOrderTest do
  @moduledoc """
  EV-37 (CL-10, FH-24): a change-run decision locks the run, then the actor's membership, then
  the version, so a transaction that takes the run before the version exclusively cannot form a
  lock cycle with it (INV-1).

  Every participant runs on its own committing connection against uniquely scoped rows that
  `on_exit` deletes by id. Each interleaving is held open by messages, and the test waits for the
  other backend's `pg_blocking_pids/1` entry instead of sleeping. The holder models any run-owned
  version-exclusive command: it locks the run row, then calls `Versions.lock_for_exclusive_write!/2`.

  - holder first: the apply waits on the run while holding no version lock, so the holder takes
    the version and both finish. With the version locked first, the holder's version request waits
    on the apply's share lock while the apply waits on the holder's run lock, and PostgreSQL
    aborts one side with `40P01`;
  - apply first: the holder waits on the run held by the apply in flight, then both finish;
  - revocation: a deactivation waits for the membership share lock of the decision in flight, so
    that decision commits whole and the next decision is refused.

  The proof covers one PostgreSQL instance at READ COMMITTED. The focused gate command is deferred
  to branch review:
  `mix test test/gtfs_planner/gtfs/import/change_apply_lock_order_test.exs`.
  """

  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Gtfs.{AuditContext, ChangeLog, Level}
  alias GtfsPlanner.Gtfs.Import.{ChangeDecision, ChangeRun, ChangeRuns}
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @rendezvous_timeout 10_000
  @collect_timeout 15_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    scope = unboxed(&seed_scope/0)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)
    %{scope: scope, supervisor: supervisor}
  end

  test "an apply that starts behind a run-first version holder waits on the run without deadlock",
       %{scope: scope, supervisor: supervisor} do
    holder = start_holder(supervisor, scope)
    assert_receive {:holder_has_run, holder_backend}, @rendezvous_timeout

    apply_task = start_apply(supervisor, scope, "level:L2", :plain)
    assert_receive {:apply_ready, apply_backend}, @rendezvous_timeout
    assert :ok == unboxed(fn -> await_blocker(apply_backend, holder_backend, deadline()) end)

    send(holder.pid, :take_version)

    assert_receive {:holder_has_version, ^holder_backend},
                   @rendezvous_timeout,
                   "the holder never got the version lock; a 40P01 here means the apply locked the version before the run"

    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, @collect_timeout)
    assert {:ok, %ChangeDecision{status: :applied}} = Task.await(apply_task, @collect_timeout)
    assert level_ids(scope) == ["L2"]
  end

  test "a run-first version holder that starts behind an apply in flight waits, then both finish",
       %{scope: scope, supervisor: supervisor} do
    apply_task = start_apply(supervisor, scope, "level:L2", :hold_after_locks)
    assert_receive {:apply_holds, apply_backend}, @rendezvous_timeout

    holder = start_holder(supervisor, scope)
    assert_receive {:holder_ready, holder_backend}, @rendezvous_timeout
    assert :ok == unboxed(fn -> await_blocker(holder_backend, apply_backend, deadline()) end)

    send(apply_task.pid, :release)
    assert {:ok, %ChangeDecision{status: :applied}} = Task.await(apply_task, @collect_timeout)

    assert_receive {:holder_has_run, ^holder_backend}, @rendezvous_timeout
    send(holder.pid, :take_version)
    assert_receive {:holder_has_version, ^holder_backend}, @rendezvous_timeout
    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, @collect_timeout)
    assert level_ids(scope) == ["L2"]
  end

  test "a revocation waits for the decision in flight and the next decision is refused", %{
    scope: scope,
    supervisor: supervisor
  } do
    apply_task = start_apply(supervisor, scope, "level:L2", :hold_after_locks)
    assert_receive {:apply_holds, apply_backend}, @rendezvous_timeout

    revocation = start_revocation(supervisor, scope)
    assert_receive {:revocation_ready, revocation_backend}, @rendezvous_timeout
    assert :ok == unboxed(fn -> await_blocker(revocation_backend, apply_backend, deadline()) end)

    # The membership share lock outlives the authorization check, so the revocation cannot
    # commit between the check and the decision's writes.
    assert level_ids(scope) == []

    send(apply_task.pid, :release)
    assert {:ok, %ChangeDecision{status: :applied}} = Task.await(apply_task, @collect_timeout)

    assert {:ok, %UserOrgMembership{deactivated_at: %DateTime{}}} =
             Task.await(revocation, @collect_timeout)

    assert {:error, :forbidden} = unboxed(fn -> apply_decision(scope, "level:L3") end)
    assert level_ids(scope) == ["L2"]
  end

  defp start_holder(supervisor, scope) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      unboxed(fn -> hold_run_then_version(parent, scope) end)
    end)
  end

  # Locks the run row and then the version exclusively, the order INV-1 gives a run-owned
  # version-exclusive command, and holds both until released.
  defp hold_run_then_version(parent, scope) do
    Repo.transaction(fn ->
      backend = backend_pid()
      send(parent, {:holder_ready, backend})

      Repo.one!(from(r in ChangeRun, where: r.id == ^scope.run.id, lock: "FOR UPDATE"))
      send(parent, {:holder_has_run, backend})

      await_message(:take_version)
      Versions.lock_for_exclusive_write!(scope.organization.id, scope.version.id)
      send(parent, {:holder_has_version, backend})

      await_message(:release)
      :released
    end)
  end

  defp start_apply(supervisor, scope, decision_id, mode) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      unboxed(fn ->
        send(parent, {:apply_ready, backend_pid()})
        apply_decision(scope, decision_id, mode, parent)
      end)
    end)
  end

  defp start_revocation(supervisor, scope) do
    parent = self()

    Task.Supervisor.async_nolink(supervisor, fn ->
      unboxed(fn ->
        send(parent, {:revocation_ready, backend_pid()})

        Organizations.deactivate_user_in_organization(
          scope.admin,
          scope.actor.id,
          scope.organization.id
        )
      end)
    end)
  end

  defp apply_decision(scope, decision_id) do
    ChangeRuns.apply_decision(
      scope.organization.id,
      scope.run.id,
      decision_id,
      scope.generation,
      scope.token,
      scope.audit
    )
  end

  defp apply_decision(scope, decision_id, :plain, _parent), do: apply_decision(scope, decision_id)

  # Pauses inside the decision transaction after it took its run, membership, version and
  # decision locks.
  defp apply_decision(scope, decision_id, :hold_after_locks, parent) do
    ChangeRuns.apply_decision_with_hook(
      scope.organization.id,
      scope.run.id,
      decision_id,
      scope.generation,
      scope.token,
      scope.audit,
      on_step: fn
        :before_fingerprint ->
          send(parent, {:apply_holds, backend_pid()})
          await_message(:release)

        _step ->
          :ok
      end
    )
  end

  defp await_message(message) do
    receive do
      ^message -> :ok
    after
      @rendezvous_timeout -> raise "never received #{inspect(message)}"
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @rendezvous_timeout

  defp level_ids(scope) do
    unboxed(fn ->
      Repo.all(
        from(l in Level,
          where:
            l.organization_id == ^scope.organization.id and
              l.gtfs_version_id == ^scope.version.id,
          order_by: [asc: l.level_id],
          select: l.level_id
        )
      )
    end)
  end

  # One organization with an editor-owned run in the applying state and two approved decisions.
  defp seed_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    admin = system_admin_fixture(organization)
    decisions = [level_decision("L2", 2.0), level_decision("L3", 3.0)]

    {:ok, run} =
      ChangeRuns.create_pending_compute(
        organization.id,
        version.id,
        %{id: actor.id, email: actor.email},
        []
      )

    {:ok, _computing, compute_generation, compute_token} =
      ChangeRuns.claim(organization.id, run.id, :compute)

    {:ok, review} =
      ChangeRuns.persist_review(
        organization.id,
        run.id,
        compute_generation,
        compute_token,
        %{decisions: decisions, summary: %{applicable: 2}, diagnostics: []}
      )

    Enum.each(decisions, fn decision ->
      {:ok, _approved} =
        ChangeRuns.set_decision_status(
          organization.id,
          review.id,
          decision.decision_id,
          :approved
        )
    end)

    {:ok, pending_apply} = ChangeRuns.request_apply(organization.id, review.id)

    {:ok, claimed, generation, token} =
      ChangeRuns.claim(organization.id, pending_apply.id, :apply)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: claimed.actor_id,
      actor_email: claimed.actor_email
    }

    %{
      organization: organization,
      version: version,
      actor: actor,
      admin: admin,
      run: claimed,
      generation: generation,
      token: token,
      audit: audit
    }
  end

  defp level_decision(level_id, level_index) do
    %{
      serializer_version: 1,
      decision_id: "level:#{level_id}",
      entity_type: :level,
      action: :add,
      status: :pending,
      natural_key: level_id,
      current_values: %{},
      uploaded_values: %{level_index: level_index},
      changed_fields: [],
      dependency_keys: [],
      current_fingerprint: nil,
      user_edited: false
    }
  end

  # Runs and decisions cascade from the version and organization rows.
  defp cleanup(scope) do
    org_id = scope.organization.id
    Repo.delete_all(from(row in ChangeLog, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in Level, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in UserOrgMembership, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in GtfsVersion, where: row.organization_id == ^org_id))
    Repo.delete_all(from(row in Organization, where: row.id == ^org_id))
    Repo.delete_all(from(row in User, where: row.id in ^[scope.actor.id, scope.admin.id]))
  end
end
