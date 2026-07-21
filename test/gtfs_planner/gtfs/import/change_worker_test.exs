defmodule GtfsPlanner.Gtfs.Import.ChangeWorkerTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import.{ChangeArtifactStorage, ChangeRun, ChangeRuns, ChangeWorker}
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "reviewer@example.com"}

  setup do
    root = Path.join(System.tmp_dir!(), "change-worker-#{System.unique_integer([:positive])}")
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if old_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, old_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    %{root: root}
  end

  test "persists applicable and preview decisions through the real storage, diff, and Repo path",
       %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run_id = Ecto.UUID.generate()

    assert {:ok, manifest} =
             ChangeArtifactStorage.stage(
               organization.id,
               version.id,
               run_id,
               [
                 %{
                   filename: "stops.txt",
                   content: "stop_id,stop_name,stop_lat,stop_lon\ncentral,Central,40.0,-70.0\n"
                 }
               ],
               root: root
             )

    assert {:ok, run} =
             ChangeRuns.create_pending_compute(
               organization.id,
               version.id,
               @actor,
               manifest,
               run_id
             )

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :compute)

    ChangeWorker.compute(claimed, generation, token, ChangeRuns.topic(run))

    assert %ChangeRun{state: :review, summary: summary} = Repo.get!(ChangeRun, run.id)
    assert Map.get(summary, "applicable") == 1
    assert Map.get(summary, "add") == 1

    assert [%{status: :pending, action: :add, natural_key: "central"}] =
             ChangeRuns.list_decisions(organization.id, run.id)

    refute File.exists?(Path.join([root, "change-runs", organization.id, version.id, run.id]))
  end

  test "missing staged input becomes a bounded failed outcome without decisions" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run_id = Ecto.UUID.generate()

    manifest = [
      %{name: "stops.txt", key: "missing.source", size: 10, sha256: String.duplicate("a", 64)}
    ]

    assert {:ok, run} =
             ChangeRuns.create_pending_compute(
               organization.id,
               version.id,
               @actor,
               manifest,
               run_id
             )

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :compute)

    assert :ok = ChangeWorker.compute(claimed, generation, token, ChangeRuns.topic(run))

    assert %ChangeRun{state: :failed, failure_code: "missing_or_corrupt_artifact"} =
             Repo.get!(ChangeRun, run.id)

    assert [] = ChangeRuns.list_decisions(organization.id, run.id)
  end

  test "parse-tainted input produces no applicable removals" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    level_fixture(organization.id, version.id, %{level_id: "L1"})
    run_id = Ecto.UUID.generate()

    assert {:ok, manifest} =
             ChangeArtifactStorage.stage(
               organization.id,
               version.id,
               run_id,
               [%{filename: "levels.txt", content: "wrong_header\nL1\n"}]
             )

    assert {:ok, run} =
             ChangeRuns.create_pending_compute(
               organization.id,
               version.id,
               @actor,
               manifest,
               run_id
             )

    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :compute)
    assert :ok = ChangeWorker.compute(claimed, generation, token, ChangeRuns.topic(run))
    assert %ChangeRun{state: :review} = Repo.get!(ChangeRun, run.id)
    assert [] = ChangeRuns.list_decisions(organization.id, run.id)
  end
end
