defmodule GtfsPlanner.Gtfs.Import.ChangeWorkerApplyTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.{AuditContext, ChangeLog}

  alias GtfsPlanner.Gtfs.Import.{
    ChangeDecision,
    ChangeDecisionSerializer,
    ChangeRun,
    ChangeRunner,
    ChangeRuns,
    ChangeWorker
  }

  alias GtfsPlanner.Repo

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "reviewer@example.com"}

  test "applies approved decisions in dependency order and checkpoints the original version" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    level_fixture(organization.id, version.id, %{level_id: "L1"})

    run =
      review_run!(organization.id, version.id, [
        decision(:level, :add, "L2", %{level_index: 2.0}, [], "level:L2"),
        decision(
          :stop,
          :add,
          "central",
          %{
            stop_name: "Central",
            stop_lat: 40.0,
            stop_lon: -70.0,
            level_id: "L2"
          },
          ["level:L2"],
          "stop:central"
        )
      ])

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert :ok =
             ChangeWorker.apply(
               claimed,
               generation,
               token,
               audit_context(claimed),
               ChangeRuns.topic(run)
             )

    assert GtfsPlanner.Gtfs.get_level_by_level_id(organization.id, version.id, "L2")
    assert GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")

    assert %ChangeRun{state: :completed, progress_current: 2, progress_total: 2} =
             Repo.get!(ChangeRun, run.id)

    assert Enum.all?(ChangeRuns.list_decisions(organization.id, run.id), &(&1.status == :applied))
    assert Repo.aggregate(ChangeLog, :count) == 2

    logs = Repo.all(ChangeLog)
    assert Enum.any?(logs, &(&1.entity_type == "level" and is_nil(&1.station_stop_id)))
    assert Enum.any?(logs, &(&1.entity_type == "stop" and &1.station_stop_id == "central"))
  end

  test "rolls back mutation, audit, decision, and progress at an injected audit boundary" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    run =
      review_run!(organization.id, version.id, [
        decision(:level, :add, "L2", %{level_index: 2.0}, [], "level:L2")
      ])

    assert {:ok, _claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert {:error, :audit_boundary} =
             ChangeRuns.apply_decision_with_hook(
               organization.id,
               run.id,
               "level:L2",
               generation,
               token,
               audit_context(run),
               on_step: fn
                 :before_audit -> {:error, :audit_boundary}
                 _step -> :ok
               end
             )

    refute GtfsPlanner.Gtfs.get_level_by_level_id(organization.id, version.id, "L2")
    assert Repo.aggregate(ChangeLog, :count) == 0

    assert [%ChangeDecision{status: :approved}] =
             ChangeRuns.list_decisions(organization.id, run.id)

    assert Repo.get!(ChangeRun, run.id).progress_current == 0
  end

  test "the supervised runner reaches the concrete apply worker" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    run =
      review_run!(organization.id, version.id, [
        decision(:level, :add, "L2", %{level_index: 2.0}, [], "level:L2")
      ])

    assert {:ok, runner} = ChangeRunner.start_apply(organization.id, run.id)
    ref = Process.monitor(runner)
    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}

    assert %ChangeRun{state: :completed} = Repo.get!(ChangeRun, run.id)
    assert GtfsPlanner.Gtfs.get_level_by_level_id(organization.id, version.id, "L2")
  end

  test "drift is marked stale without mutation or audit" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, %{stop_id: "central", stop_name: "Central"})

    run =
      review_run!(organization.id, version.id, [
        %{
          decision(:stop, :modify, "central", %{stop_name: "Central Station"}, [], "stop:central")
          | current_values: %{stop_name: "Central"}
        }
      ])

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    {:ok, current} =
      GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")
      |> GtfsPlanner.Gtfs.import_update_stop(%{stop_name: "Drifted"})

    assert :ok =
             ChangeWorker.apply(
               claimed,
               generation,
               token,
               audit_context(claimed),
               ChangeRuns.topic(run)
             )

    assert %ChangeRun{state: :partial, summary: %{"failed" => 1}} = Repo.get!(ChangeRun, run.id)

    assert [%ChangeDecision{status: :stale, apply_failure_code: "drifted"}] =
             ChangeRuns.list_decisions(organization.id, run.id)

    assert current.stop_name == "Drifted"
    assert Repo.aggregate(ChangeLog, :count) == 0
  end

  test "applies a modification when the persisted fingerprint matches the current record" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, %{stop_id: "central", stop_name: "Central"})
    current_values = %{"stop_name" => "Central"}

    run =
      review_run!(organization.id, version.id, [
        %{
          decision(
            :stop,
            :modify,
            "central",
            %{stop_name: "Central Station"},
            [],
            "stop:central"
          )
          | current_values: current_values,
            current_fingerprint: ChangeDecisionSerializer.current_fingerprint(current_values)
        }
      ])

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert :ok =
             ChangeWorker.apply(
               claimed,
               generation,
               token,
               audit_context(claimed),
               ChangeRuns.topic(run)
             )

    assert %{stop_name: "Central Station"} =
             GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")

    assert %ChangeRun{state: :completed, summary: %{"applied" => 1, "unapplied" => 0}} =
             Repo.get!(ChangeRun, run.id)
  end

  test "an apply executor failure before any commit is interrupted with an unapplied count" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    run =
      review_run!(organization.id, version.id, [
        decision(:level, :add, "L2", %{level_index: 2.0}, [], "level:L2")
      ])

    assert {:ok, _claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert {:ok, %ChangeRun{state: :interrupted, summary: summary}} =
             ChangeRuns.fail_apply(
               organization.id,
               run.id,
               generation,
               token,
               "executor_failed"
             )

    assert summary["applied"] == 0
    assert summary["failed"] == 0
    assert summary["unapplied"] == 1
  end

  test "partial retry selects only failed decisions and applies once" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    run =
      review_run!(organization.id, version.id, [
        decision(:level, :add, "L2", %{level_index: 2.0}, [], "level:L2")
      ])

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert :ok =
             ChangeWorker.apply_with_hook(
               claimed,
               generation,
               token,
               audit_context(claimed),
               ChangeRuns.topic(run),
               on_step: fn
                 :before_audit -> {:error, :audit_boundary}
                 _step -> :ok
               end
             )

    assert %ChangeRun{state: :partial} = Repo.get!(ChangeRun, run.id)

    artifact_root = Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)

    retry_result =
      try do
        ChangeRuns.retry(organization.id, run.id)
      after
        Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, artifact_root)
      end

    assert {:ok, %ChangeRun{progress_current: 0, progress_total: 1} = pending_apply} =
             retry_result

    assert {:ok, retried, retry_generation, retry_token} =
             ChangeRuns.claim(organization.id, pending_apply.id, :apply)

    assert :ok =
             ChangeWorker.apply(
               retried,
               retry_generation,
               retry_token,
               audit_context(retried),
               ChangeRuns.topic(retried)
             )

    assert %ChangeRun{state: :completed, progress_current: 1} = Repo.get!(ChangeRun, run.id)
    assert Repo.aggregate(ChangeLog, :count) == 1

    assert [%ChangeDecision{status: :applied}] =
             ChangeRuns.list_decisions(organization.id, run.id)
  end

  test "stale generation, cancellation, preview rows, and retry never duplicate a mutation or audit" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    run =
      review_run!(organization.id, version.id, [
        decision(:level, :add, "L2", %{level_index: 2.0}, [], "level:L2"),
        %{decision(:level, :add, "L3", %{level_index: 3.0}, [], "level:L3") | status: :preview}
      ])

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert {:error, :lease_lost} =
             ChangeRuns.apply_decision(
               organization.id,
               run.id,
               "level:L2",
               generation + 1,
               token,
               audit_context(run)
             )

    assert {:ok, cancelling} = ChangeRuns.request_cancel(organization.id, run.id)

    assert :ok =
             ChangeWorker.apply(
               claimed,
               generation,
               token,
               audit_context(claimed),
               ChangeRuns.topic(run)
             )

    assert %ChangeRun{state: :cancelled} = Repo.get!(ChangeRun, cancelling.id)
    refute GtfsPlanner.Gtfs.get_level_by_level_id(organization.id, version.id, "L2")
    refute GtfsPlanner.Gtfs.get_level_by_level_id(organization.id, version.id, "L3")
    assert Repo.aggregate(ChangeLog, :count) == 0
  end

  defp review_run!(organization_id, version_id, decisions) do
    {:ok, run} = ChangeRuns.create_pending_compute(organization_id, version_id, @actor, [])
    {:ok, _computing, generation, token} = ChangeRuns.claim(organization_id, run.id, :compute)

    {:ok, review} =
      ChangeRuns.persist_review(organization_id, run.id, generation, token, %{
        decisions: decisions,
        summary: %{applicable: Enum.count(decisions, &(&1.status != :preview))},
        diagnostics: []
      })

    Enum.each(decisions, fn decision ->
      if decision.status == :pending do
        {:ok, _} =
          ChangeRuns.set_decision_status(
            organization_id,
            review.id,
            decision.decision_id,
            :approved
          )
      end
    end)

    {:ok, pending_apply} = ChangeRuns.request_apply(organization_id, review.id)
    pending_apply
  end

  defp decision(entity_type, action, natural_key, uploaded_values, dependencies, decision_id) do
    %{
      serializer_version: 1,
      decision_id: decision_id,
      entity_type: entity_type,
      action: action,
      status: :pending,
      natural_key: natural_key,
      current_values: %{},
      uploaded_values: uploaded_values,
      changed_fields: [],
      dependency_keys: dependencies,
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
end
