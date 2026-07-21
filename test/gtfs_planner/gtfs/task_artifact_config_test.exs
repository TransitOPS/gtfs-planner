defmodule GtfsPlanner.Gtfs.TaskArtifactConfigTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Import.ChangeArtifactStorage

  @artifact_mount "/app/var/gtfs-task-artifacts"
  @deployment_descriptors [
    "docker-compose.yml",
    "docker-compose.mock-production.yml",
    "infra/modules/docker-service/main.tf",
    "infra/modules/service/task.tf"
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "task-artifacts-#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)

    on_exit(fn ->
      File.rm_rf(root)

      if previous_root == nil,
        do: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path),
        else: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root)
    end)

    %{
      root: root,
      organization_id: Ecto.UUID.generate(),
      version_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate()
    }
  end

  test "test configuration supplies an isolated task artifact root" do
    root = Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_path)

    assert root == Path.join(System.tmp_dir!(), "gtfs_planner_test_task_artifacts")
    refute root == Application.fetch_env!(:gtfs_planner, :uploads_path)
  end

  test "storage uses the configured private root and not the uploads root", context do
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, context.root)

    assert {:ok, [staged]} =
             ChangeArtifactStorage.stage(
               context.organization_id,
               context.version_id,
               context.run_id,
               [%{filename: "stops.txt", content: "stop_id\ncentral\n"}]
             )

    assert {:ok, artifact} =
             ArtifactStorage.publish(
               context.organization_id,
               context.version_id,
               Ecto.UUID.generate(),
               "network.zip",
               "zip-bytes"
             )

    assert Path.expand(artifact.path) |> String.starts_with?(Path.expand(context.root))

    staged_path =
      Path.join([
        context.root,
        "change-runs",
        context.organization_id,
        context.version_id,
        context.run_id,
        staged.key
      ])

    assert File.regular?(staged_path)
    refute staged_path =~ "/uploads/"
  end

  test "absent or unusable roots fail actionably without a temporary fallback", context do
    Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)

    assert {:error, :artifact_storage_unavailable} =
             ChangeArtifactStorage.stage(
               context.organization_id,
               context.version_id,
               context.run_id,
               [%{filename: "stops.txt", content: "stop_id\ncentral\n"}]
             )

    assert {:error, :artifact_storage_unavailable} =
             ArtifactStorage.publish(
               context.organization_id,
               context.version_id,
               context.run_id,
               "network.zip",
               "zip-bytes"
             )

    unavailable_root = Path.join(context.root, "not-a-directory")
    File.mkdir_p!(context.root)
    File.write!(unavailable_root, "blocking file")
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, unavailable_root)

    assert {:error, :artifact_storage_unavailable} =
             ChangeArtifactStorage.stage(
               context.organization_id,
               context.version_id,
               context.run_id,
               [%{filename: "stops.txt", content: "stop_id\ncentral\n"}]
             )

    assert {:error, :artifact_storage_unavailable} =
             ArtifactStorage.publish(
               context.organization_id,
               context.version_id,
               context.run_id,
               "network.zip",
               "zip-bytes"
             )
  end

  test "deployment descriptors configure the private shared artifact mount and positive limits" do
    Enum.each(@deployment_descriptors, fn relative_path ->
      contents = relative_path |> Path.expand(Path.expand("../../..", __DIR__)) |> File.read!()

      assert contents =~ @artifact_mount
      assert contents =~ "GTFS_TASK_ARTIFACTS_PATH"
      assert contents =~ "GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES"
      assert contents =~ "GTFS_TASK_ARTIFACTS_MAX_TOTAL_BYTES"
      assert contents =~ "GTFS_TASK_ARTIFACTS_TTL_SECONDS"
    end)
  end
end
