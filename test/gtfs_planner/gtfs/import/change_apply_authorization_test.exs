defmodule GtfsPlanner.Gtfs.Import.ChangeApplyAuthorizationTest do
  @moduledoc """
  EV-37 (CL-3, FH-8): a change-run apply reauthorizes the run's actor inside every decision
  transaction, so an actor who loses editor access mid-apply cannot apply further decisions.

  The first case drives the supervised `ChangeRunner` and the concrete `ChangeWorker`. A thin
  worker module passes the test's pause hook through `ChangeWorker.apply_with_hook/6`, so the
  pause sits in `ChangeRuns.apply_decision_with_hook/7` before the second decision opens its
  transaction, after the first decision has committed. The pause is outside any transaction and
  the revocation is sequential, so this module uses the shared SQL sandbox; the lock interleavings
  run on independent connections in `change_apply_lock_order_test.exs`.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/import/change_apply_authorization_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Import.{ChangeRun, ChangeRunner, ChangeRuns, ChangeWorker}
  alias GtfsPlanner.Organizations

  @gate :change_apply_authorization_gate
  @step_timeout 5_000

  defmodule PausingWorker do
    @moduledoc false

    # The concrete apply worker with one extra pause before each decision's transaction. The
    # test process registered under the gate name receives the paused worker's pid.
    def apply(run, generation, token, audit_context, topic) do
      ChangeWorker.apply_with_hook(run, generation, token, audit_context, topic,
        on_step: fn
          :before_transaction -> pause()
          _step -> :ok
        end
      )
    end

    defp pause do
      send(Process.whereis(:change_apply_authorization_gate), {:before_decision, self()})

      receive do
        :resume -> :ok
      after
        5_000 -> raise "the paused apply was never resumed"
      end
    end
  end

  setup do
    Process.register(self(), @gate)
    organization = organization_fixture()

    %{
      organization: organization,
      version: gtfs_version_fixture(organization.id),
      actor: member!(organization, ["pathways_studio_editor"]),
      admin: member!(organization, ["administrator"])
    }
  end

  test "an actor revoked between decisions stops the apply and closes the run as forbidden", %{
    organization: organization,
    version: version,
    actor: actor,
    admin: admin
  } do
    run =
      review_run!(organization, version, actor, [
        level_decision("L2", 2.0),
        level_decision("L3", 3.0)
      ])

    assert {:ok, runner} = ChangeRunner.start_apply(organization.id, run.id, PausingWorker)
    ref = Process.monitor(runner)

    assert_receive {:before_decision, first_decision}, @step_timeout
    send(first_decision, :resume)

    # The second decision has not opened its transaction, so the first has committed.
    assert_receive {:before_decision, second_decision}, @step_timeout
    assert Gtfs.get_level_by_level_id(organization.id, version.id, "L2")
    assert change_log_count(organization) == 1

    assert {:ok, _membership} =
             Organizations.deactivate_user_in_organization(admin, actor.id, organization.id)

    send(second_decision, :resume)
    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, @step_timeout

    assert %ChangeRun{
             state: :partial,
             failure_code: "forbidden",
             lease_token: nil,
             summary: %{"applied" => 1, "unapplied" => 1}
           } = Repo.get!(ChangeRun, run.id)

    assert decision_statuses(organization, run) == %{
             "level:L2" => :applied,
             "level:L3" => :approved
           }

    refute Gtfs.get_level_by_level_id(organization.id, version.id, "L3")
    assert change_log_count(organization) == 1
  end

  test "an actor revoked before the first decision applies nothing and the decision stays approved",
       %{organization: organization, version: version, actor: actor, admin: admin} do
    run = review_run!(organization, version, actor, [level_decision("L2", 2.0)])
    {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert {:ok, _membership} =
             Organizations.deactivate_user_in_organization(admin, actor.id, organization.id)

    assert :ok =
             ChangeWorker.apply(
               claimed,
               generation,
               token,
               audit_context(claimed),
               ChangeRuns.topic(run)
             )

    assert %ChangeRun{state: :interrupted, failure_code: "forbidden"} =
             Repo.get!(ChangeRun, run.id)

    assert decision_statuses(organization, run) == %{"level:L2" => :approved}
    refute Gtfs.get_level_by_level_id(organization.id, version.id, "L2")
    assert change_log_count(organization) == 0
  end

  test "a revoked actor's decision is refused without a write", %{
    organization: organization,
    version: version,
    actor: actor,
    admin: admin
  } do
    run = review_run!(organization, version, actor, [level_decision("L2", 2.0)])
    {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert {:ok, _membership} =
             Organizations.deactivate_user_in_organization(admin, actor.id, organization.id)

    assert {:error, :forbidden} =
             ChangeRuns.apply_decision(
               organization.id,
               run.id,
               "level:L2",
               generation,
               token,
               audit_context(claimed)
             )

    assert %ChangeRun{state: :applying, progress_current: 0} = Repo.get!(ChangeRun, run.id)
    assert decision_statuses(organization, run) == %{"level:L2" => :approved}
    refute Gtfs.get_level_by_level_id(organization.id, version.id, "L2")
    assert change_log_count(organization) == 0
  end

  test "an editor of another organization does not authorize the apply", %{
    organization: organization,
    version: version
  } do
    outsider = member!(organization_fixture(), ["pathways_studio_editor"])
    run = review_run!(organization, version, outsider, [level_decision("L2", 2.0)])
    {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert {:error, :forbidden} =
             ChangeRuns.apply_decision(
               organization.id,
               run.id,
               "level:L2",
               generation,
               token,
               audit_context(claimed)
             )

    refute Gtfs.get_level_by_level_id(organization.id, version.id, "L2")
    assert change_log_count(organization) == 0
  end

  # Emails never reuse a number from an earlier run, so committed rows left by other tests in
  # the same database cannot make a fixture user collide.
  defp member!(organization, roles) do
    user = user_fixture(%{email: "apply-auth-#{Ecto.UUID.generate()}@example.test"})
    organization_membership_fixture(user, organization, roles)
    user
  end

  defp review_run!(organization, version, actor, decisions) do
    run_actor = %{id: actor.id, email: actor.email}
    {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, run_actor, [])
    {:ok, _computing, generation, token} = ChangeRuns.claim(organization.id, run.id, :compute)

    {:ok, review} =
      ChangeRuns.persist_review(organization.id, run.id, generation, token, %{
        decisions: decisions,
        summary: %{applicable: length(decisions)},
        diagnostics: []
      })

    Enum.each(decisions, fn decision ->
      {:ok, _approved} =
        ChangeRuns.set_decision_status(
          organization.id,
          review.id,
          decision.decision_id,
          :approved
        )
    end)

    {:ok, pending_apply} = ChangeRuns.request_apply(organization.id, review.id, run_actor)
    pending_apply
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

  defp audit_context(run) do
    %AuditContext{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      station_stop_id: nil,
      actor_id: run.actor_id,
      actor_email: run.actor_email
    }
  end

  defp decision_statuses(organization, run) do
    organization.id
    |> ChangeRuns.list_decisions(run.id)
    |> Map.new(&{&1.decision_id, &1.status})
  end

  defp change_log_count(organization) do
    Repo.aggregate(from(log in ChangeLog, where: log.organization_id == ^organization.id), :count)
  end
end
