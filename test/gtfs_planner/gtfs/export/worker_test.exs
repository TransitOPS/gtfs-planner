defmodule GtfsPlanner.Gtfs.Export.WorkerTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export.{Run, Worker}
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  setup do
    root = Path.join(System.tmp_dir!(), "export-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    old_capacity = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_max_total_bytes)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, old_root)
      restore_env(:gtfs_task_artifacts_max_total_bytes, old_capacity)
    end)

    %{root: root}
  end

  test "persists bounded preflight warnings and publishes final export bytes", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, claimed, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    assert %Run{
             state: :ready,
             warnings: [_ | _],
             artifact_size_bytes: size,
             artifact_sha256: sha256,
             artifact_key: key
           } = ready = Repo.get!(Run, run.id)

    assert size > 0
    assert byte_size(sha256) == 64
    assert is_binary(key)
    assert {:ok, claim} = ExportRuns.claim_download(organization.id, version.id, run.id)
    assert File.exists?(claim.path)

    assert :ok =
             ExportRuns.complete_download(
               organization.id,
               version.id,
               ready.id,
               claim.claim_id
             )

    assert File.exists?(
             Path.join([root, "export-runs", organization.id, version.id, run.id, key])
           )
  end

  test "cancellation before packaging leaves a durable cancelled row and no artifact" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, claimed, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    assert {:ok, _} = ExportRuns.request_cancel(organization.id, run.id)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))
    assert %Run{state: :cancelled, artifact_key: nil} = Repo.get!(Run, run.id)
  end

  test "storage capacity failure closes the fenced build without publishing bytes" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_max_total_bytes, 0)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, claimed, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    assert %Run{state: :failed, failure_code: "artifact_capacity_exceeded", artifact_key: nil} =
             Repo.get!(Run, run.id)
  end

  test "no exportable data closes with a durable preflight/package failure" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, claimed, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    assert %Run{state: :failed, failure_code: "no_data", artifact_key: nil} =
             Repo.get!(Run, run.id)
  end

  test "an expired worker cannot publish after a newer lease takes over" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)

    {:ok, stale, stale_generation, stale_token} =
      ExportRuns.claim(organization.id, run.id, :build)

    from(r in Run, where: r.id == ^run.id)
    |> Repo.update_all(set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]])

    assert {:ok, current, current_generation, current_token} =
             ExportRuns.claim(organization.id, run.id, :build)

    assert current_generation == stale_generation + 1
    assert current_token != stale_token
    assert :ok = Worker.build(stale, stale_generation, stale_token, ExportRuns.topic(run))
    assert %Run{state: :building, lease_generation: ^current_generation} = Repo.get!(Run, run.id)

    assert :ok = Worker.build(current, current_generation, current_token, ExportRuns.topic(run))
    assert %Run{state: :ready} = Repo.get!(Run, run.id)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
