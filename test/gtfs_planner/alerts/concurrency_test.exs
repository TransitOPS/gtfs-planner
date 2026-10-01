defmodule GtfsPlanner.Alerts.ConcurrencyTest do
  @moduledoc """
  Merge evidence (EV-6) for CL-7: AC-7's revocation during a waiting save holds
  under a real database interleaving, so FH-7 stays rejected.

  The case commits its own disposable organization, version, agency, actor,
  membership and alert on an own connection, because the holder and the save
  each run on their own connection and must see the same rows;
  `cleanup_committed_scope/1` deletes exactly those rows in `on_exit`, even when
  the test fails. The interleaving is deterministic rather than timed: the
  holder locks the membership `FOR UPDATE` and clears the editor role without
  committing, the save on the second connection reports its own backend pid and
  is observed waiting in `pg_stat_activity` through `wait_until_locked/2`
  (bounded to 5 s), and only then does the holder commit.

  The proof boundary is one PostgreSQL server at READ COMMITTED with `FOR SHARE`
  against `FOR UPDATE`: it rejects a membership check made before the lock or made
  outside the transaction. It does not fix the order of the membership lock and the
  alert row lock; a version that took the alert row first and the membership second
  would also wait on the holder and answer `:forbidden`. SERIALIZABLE, REPEATABLE
  READ, a multi-node deployment and a real server-side deadlock are outside this
  test's scope. The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/alerts/concurrency_test.exs`.

  Two more interleavings use the same structure: a delete that commits while a
  save waits for the alert row's `FOR UPDATE`, and a second first guidelines save
  waiting on the settings table's unique index.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.AlertSettings
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  # Every case holds one lock open and observes another backend's wait, so the test
  # is bounded: EV-6's 120 s command deadline, and a 10 s self-release for any hold
  # the test never gets to release.
  @moduletag timeout: 120_000

  @hold_timeout 10_000
  @receive_timeout 5_000
  @lock_wait_attempts 500
  @task_timeout 15_000

  # The draft the holder's commit must prevent: every answer here differs from the
  # stored row, so a committed save is observable in the assertions below.
  @refused_save %{
    "urgency" => "planned",
    "situation" => "detour",
    "cause" => "construction",
    "message" => %{
      "header" => "Route 1 detour",
      "description" => "Buses follow a temporary route while Route 1 is repaved."
    }
  }

  describe "a save waiting on the membership lock" do
    test "a committed role removal refuses the save and commits nothing" do
      scope = committed_scope()
      on_exit(fn -> cleanup_committed_scope(scope) end)

      before = unboxed(fn -> Repo.get!(Alert, scope.alert.id) end)

      parent = self()
      holder = Task.async(fn -> hold_role_removal(scope, parent) end)
      assert_receive :editor_role_cleared, @receive_timeout

      saver = Task.async(fn -> save_on_own_connection(scope, parent) end)
      assert_receive {:save_pid, save_pid}, @receive_timeout

      # The save's `Authorization.lock_editor!/1` `FOR SHARE` reaches the membership row
      # while the holder still owns that row's `FOR UPDATE`, so it is the membership
      # lock the save waits on, not the alert row.
      assert wait_until_locked(save_pid)

      send(holder.pid, :commit)
      assert Task.await(holder, @task_timeout) == {:ok, :ok}

      assert {:error, :forbidden} = Task.await(saver, @task_timeout)

      # The revocation the waiting save was refused against is committed, so the
      # answer cannot come from a rollback of the holder's own work.
      assert unboxed(fn -> Repo.get!(UserOrgMembership, scope.membership_id).roles end) == []

      after_save = unboxed(fn -> Repo.get!(Alert, scope.alert.id) end)

      assert after_save.revision == before.revision
      assert after_save.urgency == before.urgency
      assert after_save.situation == before.situation
      assert after_save.cause == before.cause
      assert after_save.complete == before.complete
      assert after_save.effect == before.effect
      assert after_save.first_date == before.first_date
      assert after_save.last_date == before.last_date
      assert after_save.message.header == before.message.header
      assert after_save.message.description == before.message.description
      assert after_save.updated_by_id == before.updated_by_id
      assert DateTime.compare(after_save.updated_at, before.updated_at) == :eq

      # The refused save's own answers never reached the row.
      refute after_save.urgency == :planned
      refute after_save.message.header == @refused_save["message"]["header"]
      assert after_save.revision == scope.alert.revision
    end
  end

  describe "a save waiting on the alert row" do
    test "a delete that commits first answers not found and does not raise" do
      scope = committed_scope()
      on_exit(fn -> cleanup_committed_scope(scope) end)

      parent = self()
      holder = Task.async(fn -> hold_alert_deletion(scope, parent) end)
      assert_receive :alert_row_locked, @receive_timeout

      saver = Task.async(fn -> save_on_own_connection(scope, parent) end)
      assert_receive {:save_pid, save_pid}, @receive_timeout

      # The save has passed the membership lock and waits on the alert row the
      # holder has locked and deleted.
      assert wait_until_locked(save_pid)

      send(holder.pid, :commit)
      assert Task.await(holder, @task_timeout) == {:ok, :ok}

      assert {:error, :not_found} = Task.await(saver, @task_timeout)
      assert unboxed(fn -> Repo.get(Alert, scope.alert.id) end) == nil
    end
  end

  describe "a first guidelines save waiting on the unique index" do
    test "the editor who lost the race is told the guidelines are stale" do
      scope = committed_scope()
      on_exit(fn -> cleanup_committed_scope(scope) end)

      parent = self()
      holder = Task.async(fn -> hold_first_guidelines(scope, parent) end)
      assert_receive :first_guidelines_inserted, @receive_timeout

      saver =
        Task.async(fn ->
          on_own_connection(parent, fn ->
            Alerts.save_guidelines(scope.audit, "The second editor's text.", 0)
          end)
        end)

      assert_receive {:save_pid, save_pid}, @receive_timeout

      # The second insert waits on the first editor's uncommitted index entry.
      assert wait_until_locked(save_pid)

      send(holder.pid, :commit)
      assert Task.await(holder, @task_timeout) == {:ok, :ok}

      assert {:error, :stale} = Task.await(saver, @task_timeout)

      stored =
        unboxed(fn -> Repo.get_by!(AlertSettings, organization_id: scope.organization_id) end)

      assert stored.guidelines == "The first editor's text."
      assert stored.revision == 1
    end
  end

  # Committed fixtures for one case: a fresh organization, version, agency, editor,
  # membership and revision-1 alert. They are created on an own connection because
  # the holder and the save run on their own connections and must see them;
  # `cleanup_committed_scope/1` deletes exactly these rows.
  defp committed_scope do
    unboxed(fn ->
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      agency_fixture(organization.id, version.id)
      actor = editor_fixture(organization)
      membership = Repo.get_by!(UserOrgMembership, user_id: actor.id)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }

      alert =
        alert_fixture(audit, %{
          "urgency" => "now",
          "situation" => "delay",
          "message" => %{
            "header" => "Route 1 delays",
            "description" => "Route 1 buses are running 15 minutes late."
          }
        })

      %{
        organization_id: organization.id,
        version_id: version.id,
        actor_id: actor.id,
        membership_id: membership.id,
        alert: alert,
        audit: audit
      }
    end)
  end

  # Deletes exactly the rows `committed_scope/1` created, keyed to their own
  # organization, on an own connection so the deletion is not part of the SQL
  # Sandbox transaction and runs even when the test failed. Deleting the
  # organization removes its versions, agency, alerts, memberships and settings
  # in one statement; deleting a version on its own would be refused while the
  # agency row still names it (`agencies_version_owner_fkey`).
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization_id))
      Repo.delete_all(from(u in User, where: u.id == ^scope.actor_id))
    end)
  end

  # Removes the editor role on an own connection and holds both the row lock and the
  # removal uncommitted until the test releases it, so the save cannot resolve a
  # membership until this transaction has decided it.
  defp hold_role_removal(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        membership =
          Repo.one!(
            from(m in UserOrgMembership,
              where: m.organization_id == ^scope.organization_id and m.user_id == ^scope.actor_id,
              lock: "FOR UPDATE"
            )
          )

        {1, _} =
          Repo.update_all(
            from(m in UserOrgMembership, where: m.id == ^membership.id),
            set: [roles: []]
          )

        hold_until_commit(parent, :editor_role_cleared)
      end)
    end)
  end

  # Locks the alert row and deletes it on an own connection, holding both
  # uncommitted, so a save that has passed the membership lock waits on the row.
  defp hold_alert_deletion(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.one!(from(a in Alert, where: a.id == ^scope.alert.id, lock: "FOR UPDATE"))
        {1, _} = Repo.delete_all(from(a in Alert, where: a.id == ^scope.alert.id))

        hold_until_commit(parent, :alert_row_locked)
      end)
    end)
  end

  # Inserts the organization's first settings row on an own connection and holds
  # it uncommitted, so a second first save reaches the unique index and waits.
  defp hold_first_guidelines(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.insert!(%AlertSettings{
          organization_id: scope.organization_id,
          guidelines: "The first editor's text.",
          revision: 1
        })

        hold_until_commit(parent, :first_guidelines_inserted)
      end)
    end)
  end

  # Tells the test the holder's change is in place, then keeps it uncommitted
  # until the test releases it or the hold times out.
  defp hold_until_commit(parent, ready_message) do
    send(parent, ready_message)

    receive do
      :commit -> :ok
    after
      @hold_timeout -> Repo.rollback(:timeout)
    end
  end

  # A save on its own connection: its transaction must commit for the membership
  # lock to be released, and it reports the backend pid the test polls.
  defp save_on_own_connection(scope, parent) do
    on_own_connection(parent, fn ->
      Alerts.save_draft(scope.audit, scope.alert.id, scope.alert.revision, @refused_save)
    end)
  end

  defp on_own_connection(parent, fun) do
    unboxed(fn ->
      {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
      send(parent, {:save_pid, backend_pid})
      fun.()
    end)
  end

  # The blocked backend reports itself in `pg_stat_activity` once it waits on the
  # lock, which is deterministic; the test polls it instead of sleeping on a guess.
  # The bound mirrors `gtfs/blocking/concurrency_test.exs`: 500 attempts of 10 ms,
  # so 5 s.
  #
  # The poll reads on this process's own sandbox connection (`async: false` gives it a
  # shared owner connection) instead of checking one out: the case already holds one
  # connection in its holder and one in the blocked save, and a further checkout
  # would demand a pool connection a host with few schedulers does not have, turning
  # the poll into a `pool_timeout` error instead of an assertion.
  defp wait_until_locked(pid, attempts \\ @lock_wait_attempts) do
    {:ok, %{rows: [[waiting]]}} =
      Repo.query(
        "select count(*) from pg_stat_activity where pid = $1 and wait_event_type = 'Lock'",
        [pid]
      )

    cond do
      waiting > 0 ->
        true

      attempts <= 0 ->
        flunk("the backend #{inspect(pid)} never waited on a lock")

      true ->
        Process.sleep(10)
        wait_until_locked(pid, attempts - 1)
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
