defmodule GtfsPlanner.Gtfs.Import.ChangeArtifactStorageTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Gtfs.Import.ChangeArtifactStorage

  setup do
    root = Path.join(System.tmp_dir!(), "change-artifacts-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      organization_id: Ecto.UUID.generate(),
      version_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate()
    }
  end

  test "stages unique immutable files and verifies final bytes", context do
    files = [
      %{
        filename: "stops.txt",
        content: "stop_id,stop_name,stop_lat,stop_lon\ncentral,Central,1,2\n"
      }
    ]

    assert {:ok, [manifest]} =
             ChangeArtifactStorage.stage(
               context.organization_id,
               context.version_id,
               context.run_id,
               files,
               root: context.root
             )

    assert manifest.name == "stops.txt"
    assert String.match?(manifest.sha256, ~r/\A[0-9a-f]{64}\z/)
    assert manifest.size > 0
    assert manifest.key != manifest.name

    path =
      Path.join([
        context.root,
        "change-runs",
        context.organization_id,
        context.version_id,
        context.run_id,
        manifest.key
      ])

    assert {:ok, content} = File.read(path)
    assert byte_size(content) == manifest.size
  end

  test "rejects traversal, excess inputs, and oversized content", context do
    assert {:error, :invalid_staged_files} =
             ChangeArtifactStorage.stage(
               context.organization_id,
               context.version_id,
               context.run_id,
               [%{filename: "../stops.txt", content: "x"}],
               root: context.root
             )

    files = for number <- 1..4, do: %{filename: "stops#{number}.txt", content: "x"}

    assert {:error, :invalid_file_count} =
             ChangeArtifactStorage.stage(
               context.organization_id,
               context.version_id,
               context.run_id,
               files,
               root: context.root
             )
  end

  test "reconciles an orphan directory deterministically", context do
    orphan =
      Path.join([
        context.root,
        "change-runs",
        context.organization_id,
        context.version_id,
        Ecto.UUID.generate()
      ])

    File.mkdir_p!(orphan)
    File.write!(Path.join(orphan, "orphan.source"), "orphan")

    assert {:ok, 1} = ChangeArtifactStorage.reconcile([], root: context.root)
    refute File.exists?(orphan)
  end

  test "does not read a staged file whose final bytes changed", context do
    files = [%{filename: "levels.txt", content: "level_id,level_index\nL1,1\n"}]

    assert {:ok, [manifest]} =
             ChangeArtifactStorage.stage(
               context.organization_id,
               context.version_id,
               context.run_id,
               files,
               root: context.root
             )

    path =
      Path.join([
        context.root,
        "change-runs",
        context.organization_id,
        context.version_id,
        context.run_id,
        manifest.key
      ])

    File.write!(path, "changed")

    run = %GtfsPlanner.Gtfs.Import.ChangeRun{
      id: context.run_id,
      organization_id: context.organization_id,
      gtfs_version_id: context.version_id,
      source_manifest: %{files: [manifest]}
    }

    assert {:error, :missing_or_corrupt_artifact} =
             ChangeArtifactStorage.read(run, root: context.root)
  end
end
