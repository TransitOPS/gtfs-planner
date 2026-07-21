defmodule GtfsPlanner.Gtfs.TaskArtifactMaintenanceTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Import.{ChangeArtifactStorage, ChangeRun, ChangeRuns, ChangeWorker}
  alias GtfsPlanner.Gtfs.TaskArtifactMaintenance
  alias GtfsPlanner.Repo

  @actor %{id: Ecto.UUID.generate(), email: "maintenance@example.com"}

  setup do
    root = Path.join(System.tmp_dir!(), "task-maintenance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    :ok
  end

  test "reconciles expired import and export executors through one runtime owner" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    {:ok, change_run} =
      ChangeRuns.create_pending_compute(organization.id, version.id, @actor, [])

    {:ok, _, _, _} = ChangeRuns.claim(organization.id, change_run.id, :compute)
    {:ok, export_run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _, _, _} = ExportRuns.claim(organization.id, export_run.id, :build)

    from(r in ChangeRun, where: r.id == ^change_run.id)
    |> Repo.update_all(set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    from(r in Run, where: r.id == ^export_run.id)
    |> Repo.update_all(set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    assert :ok = TaskArtifactMaintenance.maintain()
    assert Repo.get!(ChangeRun, change_run.id).state == :interrupted
    assert Repo.get!(Run, export_run.id).state == :interrupted
  end

  test "retains interrupted compute sources through maintenance so retry can finish" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run_id = Ecto.UUID.generate()

    {:ok, manifest} =
      ChangeArtifactStorage.stage(organization.id, version.id, run_id, [
        %{
          filename: "stops.txt",
          content: "stop_id,stop_name,stop_lat,stop_lon\ncentral,Central,40.0,-70.0\n"
        }
      ])

    {:ok, run} =
      ChangeRuns.create_pending_compute(organization.id, version.id, @actor, manifest, run_id)

    {:ok, _, _, _} = ChangeRuns.claim(organization.id, run.id, :compute)

    from(r in ChangeRun, where: r.id == ^run.id)
    |> Repo.update_all(set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    assert :ok = TaskArtifactMaintenance.maintain()
    assert Repo.get!(ChangeRun, run.id).state == :interrupted
    assert {:ok, pending} = ChangeRuns.retry(organization.id, run.id)
    assert {:ok, claimed, generation, token} = ChangeRuns.claim(organization.id, run.id, :compute)
    assert :ok = ChangeWorker.compute(claimed, generation, token, ChangeRuns.topic(run))
    assert Repo.get!(ChangeRun, pending.id).state == :review
  end

  test "does not delete a freshly staged directory before its run row is inserted" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run_id = Ecto.UUID.generate()

    {:ok, manifest} =
      ChangeArtifactStorage.stage(organization.id, version.id, run_id, [
        %{filename: "levels.txt", content: "level_id,level_index\nL1,1\n"}
      ])

    assert :ok = TaskArtifactMaintenance.maintain()

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
    assert Repo.get!(ChangeRun, run.id).state == :review
  end
end
