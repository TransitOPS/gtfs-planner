defmodule GtfsPlanner.Organizations.MembershipConcurrencyTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @contention_timeout 10_000
  @collect_timeout 15_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{supervisor: supervisor}
  end

  test "two admins deactivating each other leave one usable admin", %{supervisor: supervisor} do
    scope = unboxed(fn -> seed_scope(["pathways_studio_admin", "pathways_studio_admin"]) end)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)

    [first, second] = scope.users
    first_command = start_deactivation(supervisor, first, second, scope.organization)
    second_command = start_deactivation(supervisor, second, first, scope.organization)

    send(first_command.task.pid, :go)
    send(second_command.task.pid, :go)

    results = [
      Task.await(first_command.task, @collect_timeout),
      Task.await(second_command.task, @collect_timeout)
    ]

    assert Enum.count(results, &match?({:ok, %UserOrgMembership{}}, &1)) == 1
    # The loser is already deactivated when its actor check takes the organization lock.
    assert Enum.count(results, &(&1 == {:error, :forbidden})) == 1

    assert unboxed(fn ->
             Repo.aggregate(
               from(m in UserOrgMembership,
                 where:
                   m.organization_id == ^scope.organization.id and is_nil(m.deactivated_at) and
                     ^"pathways_studio_admin" in m.roles
               ),
               :count
             )
           end) == 1
  end

  test "deactivation waits for a held editor command and later editor locks fail", %{
    supervisor: supervisor
  } do
    scope = unboxed(fn -> seed_scope(["pathways_studio_admin", "pathways_studio_editor"]) end)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)

    [admin, editor] = scope.users
    holder = start_editor_holder(supervisor, editor, scope.organization)
    deactivation = start_deactivation(supervisor, admin, editor, scope.organization)
    send(deactivation.task.pid, :go)

    assert_blocked_by(deactivation.backend, holder.backend)
    send(holder.task.pid, :commit)

    assert {:ok, :held} = Task.await(holder.task, @collect_timeout)

    assert {:ok, %UserOrgMembership{deactivated_at: %DateTime{}}} =
             Task.await(deactivation.task, @collect_timeout)

    assert {:error, :forbidden} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 Authorization.lock_editor!(%{
                   actor_id: editor.id,
                   organization_id: scope.organization.id
                 })
               end)
             end)
  end

  defp seed_scope(roles) do
    organization = organization_fixture()

    members =
      Enum.map(roles, fn role ->
        user = user_fixture()
        membership = organization_membership_fixture(user, organization, [role])
        {user, membership}
      end)

    version_ids =
      Repo.all(from(v in GtfsVersion, where: v.organization_id == ^organization.id, select: v.id))

    %{
      organization: organization,
      users: Enum.map(members, &elem(&1, 0)),
      membership_ids: Enum.map(members, fn {_user, membership} -> membership.id end),
      version_ids: version_ids
    }
  end

  defp start_deactivation(supervisor, actor, target, organization) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          backend = backend_pid()
          send(parent, {:deactivation_ready, self(), backend})

          receive do
            :go -> :ok
          after
            @contention_timeout -> raise "deactivation was not released"
          end

          Organizations.deactivate_user_in_organization(actor, target.id, organization.id)
        end)
      end)

    assert_receive {:deactivation_ready, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  defp start_editor_holder(supervisor, editor, organization) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Authorization.lock_editor!(%{actor_id: editor.id, organization_id: organization.id})
            send(parent, {:editor_locked, self(), backend_pid()})

            receive do
              :commit -> :held
            after
              @contention_timeout -> raise "editor lock was not released"
            end
          end)
        end)
      end)

    assert_receive {:editor_locked, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  defp assert_blocked_by(backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout
    assert :ok == unboxed(fn -> await_blocker(backend, holder_backend, deadline) end)
  end

  defp cleanup(scope) do
    user_ids = Enum.map(scope.users, & &1.id)
    membership_ids = scope.membership_ids
    version_ids = scope.version_ids
    organization_id = scope.organization.id

    Repo.delete_all(from(m in UserOrgMembership, where: m.id in ^membership_ids))
    Repo.delete_all(from(v in GtfsVersion, where: v.id in ^version_ids))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
  end
end
