defmodule GtfsPlanner.Accounts.FirstAdminConcurrencyTest do
  # Committed PostgreSQL interleavings: first-admin setup serializes on the
  # advisory lock "accounts:first_admin_setup" and counts users after taking it.
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.ConcurrencyHelpers

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Organizations.Organization

  @lock_key "accounts:first_admin_setup"
  @contention_timeout 10_000
  @collect_timeout 15_000

  setup do
    assert unboxed(fn -> Accounts.count_users() end) == 0,
           "first-admin setup tests need a database with no committed users"

    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    uniq = Ecto.UUID.generate()
    emails = Enum.map(1..3, &"first-admin-#{&1}-#{uniq}@example.com")
    aliases = Enum.map(1..3, &"first-admin-#{&1}-#{uniq}")

    on_exit(fn -> unboxed(fn -> cleanup(emails, aliases) end) end)

    %{supervisor: supervisor, emails: emails, aliases: aliases}
  end

  test "a setup waiting on the lock sees the user the lock holder committed", %{
    supervisor: supervisor,
    emails: [holder_email, waiter_email | _],
    aliases: [_, waiter_alias | _]
  } do
    holder = start_holder(supervisor, holder_email)
    waiter = start_setup(supervisor, setup_params(waiter_email, waiter_alias))
    send(waiter.task.pid, :go)

    assert_blocked_by(waiter.backend, holder.backend)
    send(holder.task.pid, :commit)

    assert {:ok, %User{email: ^holder_email}} = Task.await(holder.task, @collect_timeout)
    assert {:error, :already_set_up} = Task.await(waiter.task, @collect_timeout)

    assert unboxed(fn -> Repo.all(from u in User, select: u.email) end) == [holder_email]
    assert unboxed(fn -> Repo.get_by(Organization, alias: waiter_alias) end) == nil
  end

  test "two simultaneous setups create exactly one administrator", %{
    supervisor: supervisor,
    emails: [first_email, second_email | _],
    aliases: [first_alias, second_alias | _]
  } do
    first = start_setup(supervisor, setup_params(first_email, first_alias))
    second = start_setup(supervisor, setup_params(second_email, second_alias))

    send(first.task.pid, :go)
    send(second.task.pid, :go)

    results = [
      Task.await(first.task, @collect_timeout),
      Task.await(second.task, @collect_timeout)
    ]

    assert Enum.count(results, &match?({:ok, %User{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_set_up})) == 1
    assert unboxed(fn -> Accounts.count_users() end) == 1

    assert unboxed(fn ->
             Repo.aggregate(
               from(o in Organization, where: o.alias in ^[first_alias, second_alias]),
               :count
             )
           end) == 1
  end

  defp setup_params(email, org_alias) do
    %{
      email: email,
      password: valid_user_password(),
      password_confirmation: valid_user_password(),
      organization_name: "First Admin #{org_alias}",
      organization_alias: org_alias
    }
  end

  defp start_setup(supervisor, params) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          send(parent, {:setup_ready, self(), backend_pid()})

          receive do
            :go -> :ok
          after
            @contention_timeout -> raise "setup was not released"
          end

          Accounts.register_first_admin(params)
        end)
      end)

    assert_receive {:setup_ready, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  # Holds the setup lock, then commits a user the way a setup that won would.
  defp start_holder(supervisor, email) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@lock_key])
            send(parent, {:setup_locked, self(), backend_pid()})

            receive do
              :commit -> user_fixture(%{email: email})
            after
              @contention_timeout -> raise "setup lock was not released"
            end
          end)
        end)
      end)

    assert_receive {:setup_locked, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  defp assert_blocked_by(backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout
    assert :ok == unboxed(fn -> await_blocker(backend, holder_backend, deadline) end)
  end

  defp cleanup(emails, aliases) do
    organization_ids =
      Repo.all(from(o in Organization, where: o.alias in ^aliases, select: o.id))

    delete_committed_scope!(organization_ids)
    Repo.delete_all(from(u in User, where: u.email in ^emails))
  end
end
