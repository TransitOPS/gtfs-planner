defmodule GtfsPlanner.Gtfs.Import.ChangeWorkerApplyTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.{AuditContext, ChangeLog, Stop}

  alias GtfsPlanner.Gtfs.Import.{
    ChangeDecision,
    ChangeDecisionSerializer,
    ChangeRun,
    ChangeRunner,
    ChangeRuns,
    ChangeWorker,
    DiffDecision
  }

  alias GtfsPlanner.Repo

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

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
    assert change_log_count(organization) == 2

    logs = Repo.all(from(log in ChangeLog, where: log.organization_id == ^organization.id))
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
    assert change_log_count(organization) == 0

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
    assert change_log_count(organization) == 0
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

  test "applies a reviewed modification of a stop stored with trailing-zero coordinates" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop = trailing_zero_stop!(organization.id, version.id)

    run =
      review_run!(organization.id, version.id, [
        reviewed_decision(:modify, :stop, stop, %{stop_name: "Central Station"})
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

    assert [%ChangeDecision{status: :applied, apply_failure_code: nil}] =
             ChangeRuns.list_decisions(organization.id, run.id)
  end

  test "applies a reviewed removal of a stop stored with trailing-zero coordinates" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop = trailing_zero_stop!(organization.id, version.id)

    run =
      review_run!(organization.id, version.id, [
        reviewed_decision(:remove, :stop, stop, nil)
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

    refute GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")

    assert [%ChangeDecision{status: :applied, apply_failure_code: nil}] =
             ChangeRuns.list_decisions(organization.id, run.id)
  end

  test "applies a reviewed pathway modification when its decimals carry trailing zeros" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, %{stop_id: "from"})
    stop_fixture(organization.id, version.id, %{stop_id: "to"})

    pathway_fixture(organization.id, version.id, "from", "to", %{
      pathway_id: "walk",
      length: Decimal.new("12.50"),
      max_slope: Decimal.new("0.0500"),
      min_width: Decimal.new("2.00")
    })

    pathway = GtfsPlanner.Gtfs.get_pathway_by_pathway_id(organization.id, version.id, "walk")
    assert Decimal.to_string(pathway.length) == "12.50"

    run =
      review_run!(organization.id, version.id, [
        reviewed_decision(:modify, :pathway, pathway, %{traversal_time: 90})
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

    assert %{traversal_time: 90} =
             GtfsPlanner.Gtfs.get_pathway_by_pathway_id(organization.id, version.id, "walk")

    assert [%ChangeDecision{status: :applied}] =
             ChangeRuns.list_decisions(organization.id, run.id)
  end

  test "a coordinate changed after review is drifted without mutation or audit" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop = trailing_zero_stop!(organization.id, version.id)

    run =
      review_run!(organization.id, version.id, [
        reviewed_decision(:modify, :stop, stop, %{stop_name: "Central Station"})
      ])

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    {:ok, _moved} =
      GtfsPlanner.Gtfs.import_update_stop(stop, %{stop_lat: Decimal.new("40.731000")})

    assert :ok =
             ChangeWorker.apply(
               claimed,
               generation,
               token,
               audit_context(claimed),
               ChangeRuns.topic(run)
             )

    assert [%ChangeDecision{status: :stale, apply_failure_code: "drifted"}] =
             ChangeRuns.list_decisions(organization.id, run.id)

    assert %{stop_name: "Central"} =
             GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")

    assert change_log_count(organization) == 0
  end

  test "a reviewed station change leaves the stored zone when its attrs carry zone_id: nil" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop = stop_fixture(organization.id, version.id, %{stop_id: "central", stop_name: "Central"})

    {1, _} = Repo.update_all(from(s in Stop, where: s.id == ^stop.id), set: [zone_id: "A"])

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

    # The intake allowlist refuses `zone_id`, so the persisted decision is given
    # the attribute directly: applying it must still leave the stored zone alone
    # (AC-4).
    {1, _} =
      Repo.update_all(
        from(d in ChangeDecision, where: d.change_run_id == ^run.id),
        set: [uploaded_values: %{"stop_name" => "Central Station", "zone_id" => nil}]
      )

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert :ok =
             ChangeWorker.apply(
               claimed,
               generation,
               token,
               audit_context(claimed),
               ChangeRuns.topic(run)
             )

    assert %{stop_name: "Central Station", zone_id: "A"} =
             GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")

    assert %ChangeRun{state: :completed, summary: %{"applied" => 1, "unapplied" => 0}} =
             Repo.get!(ChangeRun, run.id)
  end

  test "a reviewed station change leaves the stored stop_code, tts_stop_name, stop_url and stop_timezone" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop = stop_fixture(organization.id, version.id, %{stop_id: "central", stop_name: "Central"})

    {1, _} =
      Repo.update_all(from(s in Stop, where: s.id == ^stop.id),
        set: [
          stop_code: "4021",
          tts_stop_name: "Central Station",
          stop_url: "https://example.test/stops/central",
          stop_timezone: "America/New_York"
        ]
      )

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

    # The intake allowlist refuses these fields, so the persisted decision is given
    # them directly: applying it must still leave the stored values alone.
    {1, _} =
      Repo.update_all(
        from(d in ChangeDecision, where: d.change_run_id == ^run.id),
        set: [
          uploaded_values: %{
            "stop_name" => "Central Station",
            "stop_code" => nil,
            "tts_stop_name" => nil,
            "stop_url" => nil,
            "stop_timezone" => nil
          }
        ]
      )

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    assert :ok =
             ChangeWorker.apply(
               claimed,
               generation,
               token,
               audit_context(claimed),
               ChangeRuns.topic(run)
             )

    assert %{
             stop_name: "Central Station",
             stop_code: "4021",
             tts_stop_name: "Central Station",
             stop_url: "https://example.test/stops/central",
             stop_timezone: "America/New_York"
           } = GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")

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
        ChangeRuns.retry(organization.id, run.id, run_actor(run))
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
    assert change_log_count(organization) == 1

    assert [%ChangeDecision{status: :applied}] =
             ChangeRuns.list_decisions(organization.id, run.id)
  end

  test "a closure-backed pathway removal fails with pathway_in_use while its sibling applies, and retry succeeds after the closure is removed" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    organization_membership_fixture(actor, organization)

    level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})

    stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})

    stop_fixture(organization.id, version.id, %{
      stop_id: "ENT_1",
      location_type: 2,
      parent_station: "STN_1",
      level_id: "L1"
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "PLAT_1",
      location_type: 0,
      parent_station: "STN_1",
      level_id: "L1"
    })

    pathway_fixture(organization.id, version.id, "ENT_1", "PLAT_1", %{
      pathway_id: "PW_BLOCKED",
      pathway_mode: 2
    })

    pathway_fixture(organization.id, version.id, "ENT_1", "PLAT_1", %{
      pathway_id: "PW_FREE",
      pathway_mode: 1
    })

    calendar_fixture(organization.id, version.id, %{service_id: "SVC_WEEK"})

    editor_audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: "STN_1",
      actor_id: actor.id,
      actor_email: actor.email
    }

    assert {:ok, %{evolution: evolution, fingerprint: fingerprint}} =
             GtfsPlanner.Gtfs.create_pathway_evolution(
               %{
                 pathway_id: "PW_BLOCKED",
                 service_id: "SVC_WEEK",
                 start_time: "09:00",
                 end_time: "10:00"
               },
               editor_audit
             )

    run =
      review_run!(organization.id, version.id, [
        decision(:pathway, :remove, "PW_BLOCKED", %{}, [], "pathway:PW_BLOCKED"),
        decision(:pathway, :remove, "PW_FREE", %{}, [], "pathway:PW_FREE")
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

    assert %ChangeRun{state: :partial} = Repo.get!(ChangeRun, run.id)

    decisions = ChangeRuns.list_decisions(organization.id, run.id)

    assert %ChangeDecision{status: :failed, apply_failure_code: "pathway_in_use"} =
             Enum.find(decisions, &(&1.decision_id == "pathway:PW_BLOCKED"))

    assert %ChangeDecision{status: :applied} =
             Enum.find(decisions, &(&1.decision_id == "pathway:PW_FREE"))

    assert GtfsPlanner.Gtfs.get_pathway_by_pathway_id(organization.id, version.id, "PW_BLOCKED")

    refute GtfsPlanner.Gtfs.get_pathway_by_pathway_id(organization.id, version.id, "PW_FREE")
    assert Repo.get!(GtfsPlanner.Gtfs.PathwayEvolution, evolution.id)

    assert {:ok, _deleted} =
             GtfsPlanner.Gtfs.delete_pathway_evolution(evolution.id, fingerprint, editor_audit)

    artifact_root = Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)

    retry_result =
      try do
        ChangeRuns.retry(organization.id, run.id, run_actor(run))
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

    refute GtfsPlanner.Gtfs.get_pathway_by_pathway_id(organization.id, version.id, "PW_BLOCKED")

    assert [%ChangeDecision{status: :applied}, %ChangeDecision{status: :applied}] =
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

    assert {:ok, cancelling} = ChangeRuns.request_cancel(organization.id, run.id, run_actor(run))

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
    assert change_log_count(organization) == 0
  end

  describe "removing a stop or level that other records still use" do
    test "leaves a stop that a stop time uses and fails the decision" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      stop = stop_fixture(organization.id, version.id, %{stop_id: "central"})
      stop_time_fixture(organization.id, version.id, "T1", "central")

      run = apply_removals!(organization, version, [reviewed_decision(:remove, :stop, stop, nil)])

      assert_removal_refused(organization, run)
      assert GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")
    end

    test "leaves a stop that a transfer uses as its destination" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      stop_fixture(organization.id, version.id, %{stop_id: "from"})
      stop = stop_fixture(organization.id, version.id, %{stop_id: "central"})

      transfer_fixture(organization.id, version.id, %{from_stop_id: "from", to_stop_id: "central"})

      run = apply_removals!(organization, version, [reviewed_decision(:remove, :stop, stop, nil)])

      assert_removal_refused(organization, run)
      assert GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")
    end

    test "leaves a stop that a pathway outside the review uses" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      stop_fixture(organization.id, version.id, %{stop_id: "from"})
      stop = stop_fixture(organization.id, version.id, %{stop_id: "central"})
      pathway_fixture(organization.id, version.id, "from", "central", %{pathway_id: "walk"})

      run = apply_removals!(organization, version, [reviewed_decision(:remove, :stop, stop, nil)])

      assert_removal_refused(organization, run)
      assert GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")
      assert GtfsPlanner.Gtfs.get_pathway_by_pathway_id(organization.id, version.id, "walk")
    end

    test "leaves a stop that a route pattern visits" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      stop = stop_fixture(organization.id, version.id, %{stop_id: "central"})

      organization.id
      |> route_pattern_fixture(version.id)
      |> route_pattern_stop_fixture("central", 1)

      run = apply_removals!(organization, version, [reviewed_decision(:remove, :stop, stop, nil)])

      assert_removal_refused(organization, run)
      assert GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")
    end

    test "leaves a station that still has a child stop" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      level_fixture(organization.id, version.id, %{level_id: "L1"})
      station = stop_fixture(organization.id, version.id, %{stop_id: "central", location_type: 1})

      stop_fixture(organization.id, version.id, %{
        stop_id: "platform",
        location_type: 0,
        parent_station: "central",
        level_id: "L1"
      })

      run =
        apply_removals!(organization, version, [reviewed_decision(:remove, :stop, station, nil)])

      assert_removal_refused(organization, run)
      assert GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")
    end

    test "leaves a level that a stop uses" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      level = level_fixture(organization.id, version.id, %{level_id: "L1"})
      stop_fixture(organization.id, version.id, %{stop_id: "platform", level_id: "L1"})

      run =
        apply_removals!(organization, version, [reviewed_decision(:remove, :level, level, nil)])

      assert_removal_refused(organization, run)
      assert GtfsPlanner.Gtfs.get_level_by_level_id(organization.id, version.id, "L1")
    end

    test "removes a stop that nothing uses and writes its change log" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      stop = stop_fixture(organization.id, version.id, %{stop_id: "central"})
      stop_fixture(organization.id, version.id, %{stop_id: "other"})
      stop_time_fixture(organization.id, version.id, "T1", "other")

      run = apply_removals!(organization, version, [reviewed_decision(:remove, :stop, stop, nil)])

      refute GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")

      assert [%ChangeDecision{status: :applied, apply_failure_code: nil}] =
               ChangeRuns.list_decisions(organization.id, run.id)

      assert %ChangeRun{state: :completed} = Repo.get!(ChangeRun, run.id)
      assert change_log_count(organization) == 1
    end

    test "removes a stop together with the only pathway that uses it when both are reviewed" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      stop_fixture(organization.id, version.id, %{stop_id: "from"})
      stop = stop_fixture(organization.id, version.id, %{stop_id: "central"})
      pathway_fixture(organization.id, version.id, "from", "central", %{pathway_id: "walk"})
      pathway = GtfsPlanner.Gtfs.get_pathway_by_pathway_id(organization.id, version.id, "walk")

      run =
        apply_removals!(organization, version, [
          reviewed_decision(:remove, :stop, stop, nil),
          reviewed_decision(:remove, :pathway, pathway, nil)
        ])

      refute GtfsPlanner.Gtfs.get_stop_by_stop_id(organization.id, version.id, "central")
      refute GtfsPlanner.Gtfs.get_pathway_by_pathway_id(organization.id, version.id, "walk")

      assert Enum.all?(
               ChangeRuns.list_decisions(organization.id, run.id),
               &(&1.status == :applied)
             )

      assert %ChangeRun{state: :completed} = Repo.get!(ChangeRun, run.id)
    end
  end

  # Applying reauthorizes the run's actor, so the run belongs to a real active editor.
  defp review_run!(organization_id, version_id, decisions) do
    editor = user_fixture(%{email: "apply-editor-#{Ecto.UUID.generate()}@example.test"})
    organization_membership_fixture(editor, %{id: organization_id})
    actor = %{id: editor.id, email: editor.email}
    {:ok, run} = ChangeRuns.create_pending_compute(organization_id, version_id, actor, [])
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

    {:ok, pending_apply} = ChangeRuns.request_apply(organization_id, review.id, actor)
    pending_apply
  end

  # The run's own actor, an active editor created by `review_run!/3`.
  defp run_actor(run), do: %{id: run.actor_id, email: run.actor_email}

  # Approves and applies the removal decisions the way the runner does.
  defp apply_removals!(organization, version, decisions) do
    run = review_run!(organization.id, version.id, decisions)
    {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :apply)

    :ok =
      ChangeWorker.apply(
        claimed,
        generation,
        token,
        audit_context(claimed),
        ChangeRuns.topic(run)
      )

    run
  end

  defp assert_removal_refused(organization, run) do
    assert [%ChangeDecision{status: :failed, apply_failure_code: "has_dependents"}] =
             ChangeRuns.list_decisions(organization.id, run.id)

    assert %ChangeRun{state: :partial, summary: %{"failed" => 1, "applied" => 0}} =
             Repo.get!(ChangeRun, run.id)

    assert change_log_count(organization) == 0
  end

  defp change_log_count(organization) do
    Repo.aggregate(from(log in ChangeLog, where: log.organization_id == ^organization.id), :count)
  end

  # A feed import stores 6-decimal coordinates, so the live Decimal keeps its
  # trailing zeros while the serialized decision holds the normalized form.
  defp trailing_zero_stop!(organization_id, version_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: "central",
      stop_name: "Central",
      stop_lat: Decimal.new("40.730000"),
      stop_lon: Decimal.new("-73.990000")
    })

    stop = GtfsPlanner.Gtfs.get_stop_by_stop_id(organization_id, version_id, "central")
    assert Decimal.to_string(stop.stop_lat) == "40.730000"
    assert Decimal.to_string(stop.stop_lon) == "-73.990000"
    stop
  end

  # Serializes the decision the way a diff does, from the live record.
  defp reviewed_decision(action, entity_type, record, uploaded_attrs) do
    natural_key = Map.fetch!(record, natural_key_field(entity_type))

    {:ok, serialized} =
      ChangeDecisionSerializer.serialize(%DiffDecision{
        id: "#{entity_type}:#{natural_key}",
        action: action,
        entity_type: entity_type,
        natural_key: natural_key,
        current_record: record,
        uploaded_attrs: uploaded_attrs
      })

    serialized
  end

  defp natural_key_field(:level), do: :level_id
  defp natural_key_field(:stop), do: :stop_id
  defp natural_key_field(:pathway), do: :pathway_id

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
