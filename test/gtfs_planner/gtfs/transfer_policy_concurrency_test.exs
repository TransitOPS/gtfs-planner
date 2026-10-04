defmodule GtfsPlanner.Gtfs.TransferPolicyConcurrencyTest do
  @moduledoc """
  Merge evidence (EV-2) for writing a reviewed general-policy change under the fence.

  `Transfers.apply_reviewed_policy_change/2` must reauthorize its actor in every
  attempt, take the version `FOR UPDATE` before any version or entity read,
  recompute the review's dependency fingerprint from a reloaded state and refuse a
  moved one, then write through the same editor changeset, reference checks and
  prospective rule set the review used. A committed competitor between the review
  and the save is `:stale` and writes nothing; a competitor that starts while the
  apply holds the fence waits on that fence; a competitor that commits first
  turns the reviewed decision `:stale` rather than applying it; and a SERIALIZABLE
  native writer that began before the apply committed and then waited on the fence
  retries on a fresh snapshot instead of resuming on one that cannot see the apply.

  Every case runs the production transaction module on its own connection through
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` with a message barrier immediately
  before commit (`GtfsPlanner.Gtfs.TransferBarrierTransaction`), so the commit
  order is forced rather than hoped for, and the final state is read on the same
  unboxed connection. The competing writers are real native writers — the transfer
  CRUD, `Gtfs.delete_trips/5` and the actor's membership row — not inserted rows,
  so a fence that only the reviewed path honors is rejected here.

  EV-2 does not prove the review's own arithmetic (EV-1), the agent pack that calls
  it (EV-4), the LiveView handoff (EV-5), or the browser journey (EV-13).

  The focused command is:
  `MIX_TEST_PARTITION=_ai05 mix test test/gtfs_planner/gtfs/transfer_policy_concurrency_test.exs`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.TransferBarrierTransaction
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.TransfersFixtures
  alias GtfsPlanner.Versions.GtfsVersion

  # The fixture network's calendar, route and service, so the extra trip X the
  # incidence case deletes goes through the same natural ids a caller uses.
  @service "WKDY"
  @route "12"
  # The transfers concurrency precedent's window for "must not have finished" and
  # its per-step collect timeout.
  @lock_wait 500
  @collect_timeout 10_000
  @poll 100
  # The process-dictionary key `TransferBarrierTransaction` reads.
  @barrier :transfer_barrier

  # These cases replace the global write transaction module so the reviewed apply
  # runs at the isolation level it asks for, which the plain sandbox transaction
  # configured for ordinary cases would not prove. The module is non-async and the
  # exact previous value is restored.
  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, TransferBarrierTransaction)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    %{supervisor: supervisor}
  end

  describe "a dependency that moved after the review" do
    test "a committed competitor insertion is stale and writes no transfer or audit" do
      unboxed(fn ->
        scope = seed_scope("stale-competitor")
        on_exit(fn -> unboxed(fn -> cleanup([scope]) end) end)

        command =
          create_command(%{
            "from_stop_id" => "CEN-A",
            "to_stop_id" => "MKT",
            "transfer_type" => "0"
          })

        assert {:ok, review} = Transfers.review_policy_change(scope.scope, command, scope.audit)

        # The competitor commits through the native writer, so the version's general
        # rules — one set of the fingerprint — no longer match what the review read.
        assert {:ok, competitor} =
                 Gtfs.create_general_transfer(
                   %{"from_stop_id" => "MUS", "to_stop_id" => "NOC", "transfer_type" => "0"},
                   scope.audit
                 )

        assert Transfers.dependencies_digest(scope.audit) != review.dependencies_digest

        assert {:error, :stale} = Transfers.apply_reviewed_policy_change(review, scope.audit)

        # Nothing was written: the reviewed key is absent and only the competitor's
        # own change log exists.
        refute transfer_exists?(scope, "CEN-A", "MKT")
        assert transfer_count(scope) == 1
        assert change_log_count(scope) == 1
        assert reload(scope, competitor.id).id == competitor.id

        # A target that moved under the review is refused the same way, by the
        # freshness check rather than the fingerprint.
        assert {:ok, stored} =
                 Gtfs.create_general_transfer(
                   %{"from_stop_id" => "CEN-C", "to_stop_id" => "HBR", "transfer_type" => "0"},
                   scope.audit
                 )

        update = update_command(stored.id, stored.updated_at, %{"transfer_type" => "1"})

        assert {:ok, update_review} =
                 Transfers.review_policy_change(scope.scope, update, scope.audit)

        assert {:ok, _moved} =
                 Gtfs.update_general_transfer(
                   stored.id,
                   %{"transfer_type" => "1"},
                   stored.updated_at,
                   scope.audit
                 )

        assert {:error, :stale} =
                 Transfers.apply_reviewed_policy_change(update_review, scope.audit)

        assert reload(scope, stored.id).transfer_type == 1
        assert transfer_count(scope) == 2
      end)
    end

    test "a review of another organization or a value that is not a review is refused" do
      unboxed(fn ->
        scope = seed_scope("foreign-review")
        foreign = foreign_scope()
        on_exit(fn -> unboxed(fn -> cleanup([scope, foreign]) end) end)

        command =
          create_command(%{
            "from_stop_id" => "CEN-A",
            "to_stop_id" => "MKT",
            "transfer_type" => "0"
          })

        assert {:ok, local_review} =
                 Transfers.review_policy_change(scope.scope, command, scope.audit)

        # The foreign review is built against the foreign audit context, so it is a
        # real review of a real version rather than a doctored map.
        assert {:ok, foreign_review} =
                 Transfers.review_policy_change(
                   %{
                     organization_id: foreign.organization.id,
                     gtfs_version_id: foreign.version.id
                   },
                   command,
                   foreign.audit
                 )

        # The digest names the state, not the tenant, so two organizations holding
        # the same literal network agree on it and only the scope differs.
        assert foreign_review.dependencies_digest == local_review.dependencies_digest

        assert {:error, :forbidden} =
                 Transfers.apply_reviewed_policy_change(foreign_review, scope.audit)

        assert {:error, :invalid_input} =
                 Transfers.apply_reviewed_policy_change(%{command: command}, scope.audit)

        assert {:error, :invalid_input} =
                 Transfers.apply_reviewed_policy_change(local_review, %{actor_id: nil})

        assert transfer_count(scope) == 0
        assert change_log_count(scope) == 0
      end)
    end
  end

  describe "the exclusive fence against a competing writer" do
    test "a competing rule writer waits while the apply holds the fence", %{
      supervisor: supervisor
    } do
      unboxed(fn ->
        scope = seed_scope("fence-first")
        on_exit(fn -> unboxed(fn -> cleanup([scope]) end) end)

        command =
          create_command(%{
            "from_stop_id" => "CEN-A",
            "to_stop_id" => "MKT",
            "transfer_type" => "0"
          })

        assert {:ok, review} = Transfers.review_policy_change(scope.scope, command, scope.audit)

        parent = self()

        apply_task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Process.put(@barrier, parent)

            owned_connection(fn ->
              Transfers.apply_reviewed_policy_change(review, scope.audit)
            end)
          end)

        assert_receive {:before_commit, apply_pid}, @collect_timeout
        on_exit(fn -> send(apply_pid, :commit) end)

        # The apply has written its rule and holds the version `FOR UPDATE` without
        # committing, so the competing native writer cannot take its `FOR SHARE`.
        competitor =
          Task.Supervisor.async_nolink(supervisor, fn ->
            owned_connection(fn ->
              send(parent, {:competitor_backend, self(), current_backend_pid()})

              Gtfs.create_general_transfer(
                %{"from_stop_id" => "MUS", "to_stop_id" => "NOC", "transfer_type" => "0"},
                scope.audit
              )
            end)
          end)

        assert_receive {:competitor_backend, competitor_pid, backend_pid}, @collect_timeout
        assert competitor_pid == competitor.pid

        refute Task.yield(competitor, @lock_wait)
        assert_postgres_lock_wait!(backend_pid)

        send(apply_pid, :commit)

        assert {:ok, %Transfer{from_stop_id: "CEN-A", to_stop_id: "MKT"}} =
                 await_task(apply_task, @collect_timeout)

        assert {:ok, %Transfer{from_stop_id: "MUS"}} = await_task(competitor, @collect_timeout)

        # Both writes survive: the fence serialized them instead of losing either.
        assert transfer_count(scope) == 2
        assert change_log_count(scope) == 2
      end)
    end

    test "a competitor that commits first turns the apply stale instead of applying it", %{
      supervisor: supervisor
    } do
      unboxed(fn ->
        scope = seed_scope("fence-second")
        on_exit(fn -> unboxed(fn -> cleanup([scope]) end) end)

        command =
          create_command(%{
            "from_stop_id" => "CEN-A",
            "to_stop_id" => "MKT",
            "transfer_type" => "0"
          })

        assert {:ok, review} = Transfers.review_policy_change(scope.scope, command, scope.audit)

        parent = self()

        competitor =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Process.put(@barrier, parent)

            owned_connection(fn ->
              Gtfs.create_general_transfer(
                %{"from_stop_id" => "MUS", "to_stop_id" => "NOC", "transfer_type" => "0"},
                scope.audit
              )
            end)
          end)

        assert_receive {:before_commit, competitor_pid}, @collect_timeout
        on_exit(fn -> send(competitor_pid, :commit) end)

        apply_task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            owned_connection(fn ->
              Transfers.apply_reviewed_policy_change(review, scope.audit)
            end)
          end)

        # The competitor's `FOR SHARE` is held but not committed, so the apply's
        # `FOR UPDATE` waits for it rather than reading past it.
        refute Task.yield(apply_task, @lock_wait)

        send(competitor_pid, :commit)
        assert {:ok, %Transfer{from_stop_id: "MUS"}} = await_task(competitor, @collect_timeout)

        # The competitor is now part of the committed state the fingerprint covers,
        # so the reviewed decision is stale: it is never applied on top of it.
        assert {:error, :stale} = await_task(apply_task, @collect_timeout)

        refute transfer_exists?(scope, "CEN-A", "MKT")
        assert transfer_count(scope) == 1
        assert change_log_count(scope) == 1
      end)
    end

    test "an incidence edit that commits first fences the apply out of the decision", %{
      supervisor: supervisor
    } do
      unboxed(fn ->
        scope = seed_scope("incidence")
        on_exit(fn -> unboxed(fn -> cleanup([scope]) end) end)

        # The reviewed rule selects trip X, so both the trips the rules select and
        # the `stop_time` incidence of its coverage are in the fingerprint.
        command =
          create_command(%{
            "from_stop_id" => "CEN",
            "to_stop_id" => "HBR",
            "from_route_id" => @route,
            "from_trip_id" => scope.trip.trip_id,
            "transfer_type" => "0"
          })

        assert {:ok, review} = Transfers.review_policy_change(scope.scope, command, scope.audit)

        parent = self()

        deleter =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Process.put(@barrier, parent)

            owned_connection(fn ->
              send(parent, {:deleter_ready, self()})
              Gtfs.delete_trips(@route, @service, [scope.trip.id], scope.audit)
            end)
          end)

        assert_receive {:deleter_ready, deleter_pid}, @collect_timeout
        assert deleter_pid == deleter.pid

        # The deletion is paused before commit, holding its own `FOR SHARE`, its
        # trip removal and its stop_times removal uncommitted.
        assert_receive {:before_commit, deleter_commit_pid}, @collect_timeout
        assert deleter_commit_pid == deleter_pid
        on_exit(fn -> send(deleter_commit_pid, :commit) end)

        apply_task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            owned_connection(fn ->
              send(parent, {:apply_backend, self(), current_backend_pid()})
              Transfers.apply_reviewed_policy_change(review, scope.audit)
            end)
          end)

        assert_receive {:apply_backend, apply_pid, apply_backend}, @collect_timeout
        assert apply_pid == apply_task.pid

        # The deletion's uncommitted `FOR SHARE` holds the apply at the version
        # fence, so it cannot read or write the version's transfer policy at all.
        refute Task.yield(apply_task, @lock_wait)
        assert_postgres_lock_wait!(apply_backend)

        send(deleter_commit_pid, :commit)
        assert {:ok, %{trips: 1, transfers: 0}} = await_task(deleter, @collect_timeout)

        # Trip X and its stop_times are committed and gone. The dependency
        # fingerprint deliberately covers the stored rules' own dependencies, and
        # this command had none stored yet, so it is the fence plus the reference
        # check that refuse: the selector no longer resolves, and the attempt
        # writes nothing rather than applying a decision computed from a trip that
        # is gone.
        assert {:error, %Ecto.Changeset{} = changeset} = await_task(apply_task, @collect_timeout)
        assert Keyword.has_key?(changeset.errors, :from_trip_id)

        refute transfer_names_trip?(scope)
        refute trip_exists?(scope)
        assert transfer_count(scope) == 0
        assert change_log_count(scope) == 0
      end)
    end

    test "a native deleter that began before the apply committed cannot leave a rule naming its deleted trip",
         %{supervisor: supervisor} do
      unboxed(fn ->
        scope = seed_scope("fence-deleter")
        on_exit(fn -> unboxed(fn -> cleanup([scope]) end) end)

        command =
          create_command(%{
            "from_stop_id" => "CEN",
            "to_stop_id" => "HBR",
            "from_route_id" => @route,
            "from_trip_id" => scope.trip.trip_id,
            "transfer_type" => "0"
          })

        assert {:ok, review} = Transfers.review_policy_change(scope.scope, command, scope.audit)

        parent = self()

        apply_task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Process.put(@barrier, parent)

            owned_connection(fn ->
              Transfers.apply_reviewed_policy_change(review, scope.audit)
            end)
          end)

        assert_receive {:before_commit, apply_pid}, @collect_timeout
        on_exit(fn -> send(apply_pid, :commit) end)

        # The apply holds the version `FOR UPDATE` with its rule, which names trip X,
        # uncommitted. The native deleter opens its SERIALIZABLE snapshot at its first
        # statement and then waits for that fence, so the snapshot predates the rule.
        deleter =
          Task.Supervisor.async_nolink(supervisor, fn ->
            owned_connection(fn ->
              send(parent, {:deleter_backend, self(), current_backend_pid()})
              Gtfs.delete_trips(@route, @service, [scope.trip.id], scope.audit)
            end)
          end)

        assert_receive {:deleter_backend, deleter_pid, deleter_backend}, @collect_timeout
        assert deleter_pid == deleter.pid

        refute Task.yield(deleter, @lock_wait)
        assert_postgres_lock_wait!(deleter_backend)

        send(apply_pid, :commit)

        assert {:ok, %Transfer{from_trip_id: from_trip_id}} =
                 await_task(apply_task, @collect_timeout)

        assert from_trip_id == scope.trip.trip_id

        # The deleter must not resume on its pre-apply snapshot: that would delete
        # trip X without seeing the rule that names it. It retries on a fresh snapshot,
        # sees the committed rule and removes it with the trip.
        assert {:ok, %{trips: 1, transfers: 1}} = await_task(deleter, @collect_timeout)

        refute trip_exists?(scope)
        refute transfer_names_trip?(scope)
        assert transfer_count(scope) == 0
      end)
    end
  end

  describe "authorization inside the fence" do
    test "a revoked editor role is forbidden and writes nothing" do
      unboxed(fn ->
        scope = seed_scope("revoked")
        on_exit(fn -> unboxed(fn -> cleanup([scope]) end) end)

        command =
          create_command(%{
            "from_stop_id" => "CEN-A",
            "to_stop_id" => "MKT",
            "transfer_type" => "0"
          })

        assert {:ok, review} = Transfers.review_policy_change(scope.scope, command, scope.audit)

        scope = revoke!(scope)
        assert membership_roles(scope) == []

        assert {:error, :forbidden} = Transfers.apply_reviewed_policy_change(review, scope.audit)

        assert transfer_count(scope) == 0
        assert change_log_count(scope) == 0

        restore!(scope)
        assert membership_roles(scope) == ["pathways_studio_editor"]

        # The same review applies once the role is active again, so the refusal was
        # the authorization and not the fingerprint.
        assert {:ok, %Transfer{}} = Transfers.apply_reviewed_policy_change(review, scope.audit)
      end)
    end

    test "the actor's membership is locked before the version fence and the manual CRUD is unchanged",
         %{supervisor: supervisor} do
      unboxed(fn ->
        scope = seed_scope("actor-first")
        on_exit(fn -> unboxed(fn -> cleanup([scope]) end) end)

        command =
          create_command(%{
            "from_stop_id" => "CEN-A",
            "to_stop_id" => "MKT",
            "transfer_type" => "0"
          })

        assert {:ok, review} = Transfers.review_policy_change(scope.scope, command, scope.audit)

        parent = self()

        locker =
          Task.Supervisor.async_nolink(supervisor, fn ->
            owned_connection(fn ->
              Repo.transaction(fn ->
                Repo.query!(
                  "SELECT id FROM user_org_memberships WHERE id = $1 FOR UPDATE",
                  [Ecto.UUID.dump!(scope.membership.id)]
                )

                send(parent, {:membership_locked, self()})

                receive do
                  :release_membership -> :ok
                end
              end)
            end)
          end)

        assert_receive {:membership_locked, locker_pid}, @collect_timeout
        on_exit(fn -> send(locker_pid, :release_membership) end)

        apply_task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            owned_connection(fn ->
              send(parent, {:apply_backend, self(), current_backend_pid()})
              Transfers.apply_reviewed_policy_change(review, scope.audit)
            end)
          end)

        assert_receive {:apply_backend, apply_pid, backend_pid}, @collect_timeout
        assert apply_pid == apply_task.pid

        # The apply is waiting on the actor's membership row, which is the first
        # lock it takes: it has not reached the version row or any entity read.
        refute Task.yield(apply_task, @lock_wait)
        assert_postgres_lock_wait!(backend_pid)
        assert postgres_query(backend_pid) =~ "user_org_memberships"

        send(locker_pid, :release_membership)
        assert {:ok, %Transfer{}} = await_task(apply_task, @collect_timeout)

        assert {:ok, _locker} = await_task(locker, @collect_timeout)

        # The manual CRUD keeps its own outcomes: a written rule, a stale refusal
        # and an unknown target, none of them re-fenced or re-routed through the
        # reviewed apply.
        attrs = %{
          "from_stop_id" => "MUS",
          "to_stop_id" => "NOC",
          "transfer_type" => "2",
          "min_transfer_time" => "120"
        }

        assert {:ok, created} = Gtfs.create_general_transfer(attrs, scope.audit)

        assert {:ok, %Transfer{min_transfer_time: 300}} =
                 Gtfs.update_general_transfer(
                   created.id,
                   %{"min_transfer_time" => "300"},
                   created.updated_at,
                   scope.audit
                 )

        assert {:error, :stale} =
                 Gtfs.update_general_transfer(
                   created.id,
                   %{"min_transfer_time" => "600"},
                   created.updated_at,
                   scope.audit
                 )

        assert {:error, :not_found} =
                 Gtfs.delete_general_transfer(
                   Ecto.UUID.generate(),
                   created.updated_at,
                   scope.audit
                 )

        assert {:ok, %Transfer{}} =
                 Gtfs.delete_general_transfer(
                   created.id,
                   reload(scope, created.id).updated_at,
                   scope.audit
                 )

        assert transfer_count(scope) == 1
        assert change_log_count(scope) == 4
      end)
    end
  end

  # -- Sessions --------------------------------------------------------------

  # The pid of the connection a session is running on, so a case can watch the
  # session that is about to block rather than another pooled one.
  defp current_backend_pid do
    %Postgrex.Result{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # A spawned session owns its own connection for the length of the session, the
  # reviewed-apply precedent's `start_unboxed_task/1`: the sandbox does not share
  # the test process's unboxed connection with a task, and the task checks its
  # connection in when it returns.
  defp owned_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Answers every before-commit message from a paused session with :commit until the
  # task returns. A retry after a serialization abort runs the transaction body
  # again and reaches the barrier again, so each message is answered as it arrives.
  defp await_task(task, timeout) do
    await_task(task, System.monotonic_time(:millisecond) + timeout, timeout)
  end

  defp await_task(task, deadline, timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("the session did not return within #{timeout} ms")
    else
      receive do
        {:before_commit, pid} ->
          send(pid, :commit)
          await_task(task, deadline, timeout)
      after
        min(remaining, @poll) ->
          case Task.yield(task, min(remaining, @poll)) do
            {:ok, result} -> result
            {:exit, reason} -> flunk("the session exited before returning: #{inspect(reason)}")
            nil -> await_task(task, deadline, timeout)
          end
      end
    end
  end

  # -- Final state, read on the unboxed connection ----------------------------

  # A rule may name trip X only while X's row is still there; a commit order that
  # leaves a transfer naming a missing trip is what the fence has to prevent.
  defp trip_exists?(scope) do
    Repo.exists?(from(t in Trip, where: t.id == ^scope.trip.id))
  end

  defp transfer_names_trip?(scope) do
    Repo.exists?(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and
            (t.from_trip_id == ^scope.trip.trip_id or t.to_trip_id == ^scope.trip.trip_id)
      )
    )
  end

  defp transfer_exists?(scope, from_stop_id, to_stop_id) do
    Repo.exists?(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and t.from_stop_id == ^from_stop_id and
            t.to_stop_id == ^to_stop_id
      )
    )
  end

  defp reload(scope, id) do
    Repo.get_by!(Transfer, id: id, organization_id: scope.organization.id)
  end

  defp transfer_count(scope) do
    Repo.aggregate(
      from(t in Transfer, where: t.organization_id == ^scope.organization.id),
      :count
    )
  end

  defp change_log_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog,
        where: l.organization_id == ^scope.organization.id and l.entity_type == "transfer"
      ),
      :count
    )
  end

  # The membership is refreshed in place on each change: a changeset built from the
  # struct a previous call already changed would be a no-op cast.
  defp revoke!(scope) do
    {:ok, membership} = Accounts.update_user_org_membership(scope.membership, %{roles: []})
    %{scope | membership: membership}
  end

  defp restore!(scope) do
    {:ok, membership} =
      Accounts.update_user_org_membership(scope.membership, %{roles: ["pathways_studio_editor"]})

    %{scope | membership: membership}
  end

  defp membership_roles(scope) do
    Repo.get!(UserOrgMembership, scope.membership.id).roles
  end

  defp create_command(attrs) do
    %{action: :create, target_id: nil, expected_updated_at: nil, attrs: attrs, protected_ids: []}
  end

  defp update_command(target_id, expected_updated_at, attrs) do
    %{
      action: :update,
      target_id: target_id,
      expected_updated_at: expected_updated_at,
      attrs: attrs,
      protected_ids: []
    }
  end

  # -- Committed scope and cleanup -------------------------------------------

  # One organization per case, built on the case's own unboxed connection so the
  # racing sessions can see the rows on their connections: the shared literal
  # network, the calendar its trips name, one extra route 12 trip X serving CEN-A
  # and HBR, and an actor who holds an active editor membership.
  defp seed_scope(suffix) do
    unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

    organization = organization_fixture(%{alias: "transfer-policy-#{suffix}-#{unique}"})
    version = gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)
    actor = user_fixture(%{email: "transfer-policy-#{unique}@example.com"})
    membership = organization_membership_fixture(actor, organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    {:ok, _calendar} = Gtfs.create_calendar(calendar_attrs(suffix), audit)

    %{
      organization: organization,
      version: version,
      actor: actor,
      membership: membership,
      audit: audit,
      scope: %{organization_id: organization.id, gtfs_version_id: version.id},
      trip: extra_trip(organization.id, version.id, unique)
    }
  end

  # A second organization holding the same literal network and an actor of its own.
  defp foreign_scope do
    unique = System.unique_integer([:positive])

    organization =
      organization_fixture(%{
        alias: "transfer-policy-foreign-#{System.system_time(:millisecond)}-#{unique}"
      })

    version = gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)
    actor = user_fixture(%{email: "transfer-policy-foreign-#{unique}@example.com"})
    organization_membership_fixture(actor, organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp calendar_attrs(suffix) do
    %{
      service_id: @service,
      name: "Transfer policy concurrency #{suffix}",
      kind: :weekly,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-02-27]
    }
  end

  defp extra_trip(organization_id, version_id, unique) do
    trip_id = "12-x#{unique}"

    trip =
      trip_fixture(organization_id, version_id, @route, %{
        trip_id: trip_id,
        service_id: @service,
        trip_headsign: "Harbor"
      })

    stop_time_fixture(organization_id, version_id, trip_id, "CEN-A", %{
      arrival_time: "09:00:00",
      departure_time: "09:00:00",
      stop_sequence: 1
    })

    stop_time_fixture(organization_id, version_id, trip_id, "HBR", %{
      arrival_time: "09:15:00",
      departure_time: "09:15:00",
      stop_sequence: 2
    })

    trip
  end

  defp assert_postgres_lock_wait!(backend_pid, attempts_remaining \\ 200)

  defp assert_postgres_lock_wait!(_backend_pid, 0) do
    flunk("the session did not block on the concurrent writer's lock")
  end

  defp assert_postgres_lock_wait!(backend_pid, attempts_remaining) do
    case wait_event_type(backend_pid) do
      "Lock" ->
        :ok

      _ ->
        receive do
        after
          10 -> assert_postgres_lock_wait!(backend_pid, attempts_remaining - 1)
        end
    end
  end

  defp wait_event_type(backend_pid) do
    %Postgrex.Result{rows: rows} =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid])

    case rows do
      [[type]] -> type
      _ -> nil
    end
  end

  # The statement a blocked backend is sitting in names the table whose row it is
  # waiting for, so a case can assert which lock it reached.
  defp postgres_query(backend_pid) do
    %Postgrex.Result{rows: rows} =
      Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [backend_pid])

    case rows do
      [[query]] -> query
      _ -> ""
    end
  end

  # Deletes only the captured scope. The organization id is the captured root: every
  # row this file creates belongs to it, so nothing outside the fixture is touched.
  defp cleanup(scopes) do
    organization_ids = Enum.map(scopes, & &1.organization.id)
    user_ids = scopes |> Enum.map(& &1.actor) |> Enum.reject(&is_nil/1) |> Enum.map(& &1.id)

    Repo.delete_all(from(t in Transfer, where: t.organization_id in ^organization_ids))
    Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
    Repo.delete_all(from(st in StopTime, where: st.organization_id in ^organization_ids))
    Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
    Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
    Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id in ^organization_ids))
    Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))
    Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
    Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
    Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id in ^organization_ids))

    # The active schedule's key refuses a delete of the active version alone.
    Repo.update_all(from(o in Organization, where: o.id in ^organization_ids),
      set: [active_gtfs_version_id: nil]
    )

    Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
    Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

    refute Repo.exists?(from(t in Transfer, where: t.organization_id in ^organization_ids))
    refute Repo.exists?(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
    refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
    refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
    :ok
  end
end
