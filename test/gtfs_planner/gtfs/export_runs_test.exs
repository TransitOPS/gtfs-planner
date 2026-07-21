defmodule GtfsPlanner.Gtfs.ExportRunsTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  setup do
    root = Path.join(System.tmp_dir!(), "export-runs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
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

  test "creates one scoped active run, fences stale publication, and broadcasts only committed state" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    assert {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    run_id = run.id
    assert {:ok, same_run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    assert same_run.id == run.id

    assert {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ExportRuns.topic(run.id))

    assert {:ok, warned} =
             ExportRuns.persist_warnings(organization.id, run.id, generation, token, [
               %{code: "optional_file_missing", detail: "calendar_dates"}
             ])

    assert warned.warnings == [%{code: "optional_file_missing", detail: "calendar_dates"}]

    artifact = publish!(organization.id, version.id, run.id)

    assert {:ok, ready} =
             ExportRuns.mark_ready(organization.id, run.id, generation, token, artifact)

    assert ready.state == :ready

    assert DateTime.diff(ready.artifact_expires_at, ready.finished_at) ==
             Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds)

    assert_receive {:export_run_changed, ^run_id}

    assert {:error, :lease_lost} =
             ExportRuns.mark_ready(organization.id, run.id, generation, token, artifact)
  end

  test "normalizes scope, expiry, cancellation, retry, and claim cleanup races" do
    organization = organization_fixture()
    other_organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    foreign_version = gtfs_version_fixture(other_organization.id)

    assert {:error, :not_found} =
             ExportRuns.create_pending(organization.id, foreign_version.id, @actor, :full)

    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    assert {:error, :not_found} = ExportRuns.claim(other_organization.id, run.id, :build)
    assert {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    artifact = publish!(organization.id, version.id, run.id)

    assert {:ok, _ready} =
             ExportRuns.mark_ready(organization.id, run.id, generation, token, artifact)

    assert {:error, :not_found} =
             ExportRuns.claim_download(other_organization.id, version.id, run.id)

    assert {:ok, claim} = ExportRuns.claim_download(organization.id, version.id, run.id)
    assert claim.path == artifact.path
    assert {:error, :not_found} = ExportRuns.claim_download(organization.id, version.id, run.id)
    assert ExportRuns.cleanup_expired(organization.id) == 0
    assert :ok = ExportRuns.complete_download(organization.id, version.id, run.id, claim.claim_id)

    from(r in Run, where: r.id == ^run.id)
    |> Repo.update_all(set: [artifact_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    assert ExportRuns.cleanup_expired(organization.id) == 1
    assert {:error, :not_found} = ExportRuns.claim_download(organization.id, version.id, run.id)
    assert {:ok, retry} = ExportRuns.retry(organization.id, run.id)
    assert retry.id != run.id

    assert {:ok, building, first_generation, first_token} =
             ExportRuns.claim(organization.id, retry.id, :build)

    expire!(building)

    assert {:ok, _reclaimed, second_generation, second_token} =
             ExportRuns.claim(organization.id, retry.id, :build)

    assert second_generation == first_generation + 1
    assert second_token != first_token

    assert {:error, :lease_lost} =
             ExportRuns.fail_build(
               organization.id,
               retry.id,
               first_generation,
               first_token,
               "old"
             )

    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        ExportRuns.request_cancel(organization.id, retry.id)
      end)

    ref = Process.monitor(task.pid)
    assert {:ok, _} = Task.await(task)
    assert_receive {:DOWN, ^ref, :process, _, :normal}

    assert {:ok, cancelled} =
             ExportRuns.fail_build(
               organization.id,
               retry.id,
               second_generation,
               second_token,
               "cancelled"
             )

    assert cancelled.state == :cancelled

    assert {:error, :lease_lost} =
             ExportRuns.renew_lease(organization.id, retry.id, second_generation, second_token)
  end

  test "normalizes corrupt ready artifacts after failing the durable row" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :pathways)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    artifact = publish!(organization.id, version.id, run.id)
    {:ok, _ready} = ExportRuns.mark_ready(organization.id, run.id, generation, token, artifact)

    File.write!(artifact.path, "corrupt")

    assert {:error, :not_found} = ExportRuns.claim_download(organization.id, version.id, run.id)

    assert %Run{state: :failed, failure_code: "missing_or_corrupt_artifact"} =
             ExportRuns.get_for_version(organization.id, version.id, run.id)
  end

  test "fails fast when the configured private storage root is unavailable" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    missing =
      Path.join(System.tmp_dir!(), "missing-export-root-#{System.unique_integer([:positive])}")

    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, missing)

    assert {:error, :artifact_storage_unavailable} =
             ExportRuns.create_pending(organization.id, version.id, @actor, :full)
  end

  test "a stale completion cannot release a newer download claim" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    artifact = publish!(organization.id, version.id, run.id)
    {:ok, _ready} = ExportRuns.mark_ready(organization.id, run.id, generation, token, artifact)

    assert {:ok, first} = ExportRuns.claim_download(organization.id, version.id, run.id)

    from(r in Run, where: r.id == ^run.id)
    |> Repo.update_all(set: [download_claimed_until: ~U[2000-01-01 00:00:00.000000Z]])

    assert {:ok, second} = ExportRuns.claim_download(organization.id, version.id, run.id)
    assert :ok = ExportRuns.complete_download(organization.id, version.id, run.id, first.claim_id)
    assert {:error, :not_found} = ExportRuns.claim_download(organization.id, version.id, run.id)

    assert :ok =
             ExportRuns.complete_download(organization.id, version.id, run.id, second.claim_id)
  end

  defp publish!(organization_id, version_id, run_id) do
    {:ok, artifact} =
      ArtifactStorage.publish(
        organization_id,
        version_id,
        run_id,
        "network.zip",
        "zip-bytes"
      )

    artifact
  end

  defp expire!(run) do
    from(r in Run, where: r.id == ^run.id)
    |> Repo.update_all(set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])
  end
end
