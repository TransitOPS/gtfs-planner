defmodule GtfsPlanner.Organizations.RoleChangeConcurrencyTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @rendezvous_timeout 10_000
  @collect_timeout 15_000

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{supervisor: supervisor}
  end

  test "mutual demotion leaves exactly one usable admin", %{supervisor: supervisor} do
    scope = unboxed(&seed_scope/0)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)
    [a, b] = scope.users

    commands = [
      start_command(supervisor, fn ->
        Organizations.update_user_roles(a, b.id, scope.organization.id, ["pathways_studio_editor"])
      end),
      start_command(supervisor, fn ->
        Organizations.update_user_roles(b, a.id, scope.organization.id, ["pathways_studio_editor"])
      end)
    ]

    assert_single_winner(commands, scope)
  end

  test "demotion and deactivation leave exactly one usable admin", %{supervisor: supervisor} do
    scope = unboxed(&seed_scope/0)
    on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)
    [a, b] = scope.users

    commands = [
      start_command(supervisor, fn ->
        Organizations.update_user_roles(a, b.id, scope.organization.id, ["pathways_studio_editor"])
      end),
      start_command(supervisor, fn ->
        Organizations.deactivate_user_in_organization(b, a.id, scope.organization.id)
      end)
    ]

    assert_single_winner(commands, scope)
  end

  defp assert_single_winner(commands, scope) do
    Enum.each(commands, fn task -> send(task.pid, :go) end)
    results = Enum.map(commands, &Task.await(&1, @collect_timeout))

    assert Enum.count(results, &match?({:ok, %UserOrgMembership{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :forbidden})) == 1

    assert unboxed(fn ->
             Repo.aggregate(
               from(m in UserOrgMembership,
                 join: u in User,
                 on: u.id == m.user_id,
                 where:
                   m.organization_id == ^scope.organization.id and is_nil(m.deactivated_at) and
                     ^"pathways_studio_admin" in m.roles and not is_nil(u.hashed_password)
               ),
               :count
             )
           end) == 1
  end

  defp start_command(supervisor, command) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          after
            @rendezvous_timeout -> raise "command was not released"
          end

          command.()
        end)
      end)

    assert_receive {:ready, task_pid}, @rendezvous_timeout
    assert task_pid == task.pid
    task
  end

  defp seed_scope do
    organization = organization_fixture()

    members =
      Enum.map(1..2, fn _ ->
        user = user_fixture()

        membership =
          organization_membership_fixture(user, organization, ["pathways_studio_admin"])

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

  defp cleanup(scope) do
    user_ids = Enum.map(scope.users, & &1.id)
    Repo.delete_all(from(m in UserOrgMembership, where: m.id in ^scope.membership_ids))
    delete_versions!(from(v in GtfsVersion, where: v.id in ^scope.version_ids))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
    Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization.id))
  end
end
