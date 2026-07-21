defmodule GtfsPlanner.Gtfs.Export.ArtifactStorageTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Gtfs.Export.ArtifactStorage

  setup do
    root = Path.join(System.tmp_dir!(), "export-artifacts-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      organization_id: Ecto.UUID.generate(),
      version_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate()
    }
  end

  test "publishes an immutable generated key only after final-byte verification", context do
    assert {:ok, artifact} =
             ArtifactStorage.publish(
               context.organization_id,
               context.version_id,
               context.run_id,
               "network.zip",
               "zip-bytes",
               root: context.root
             )

    assert artifact.filename == "network.zip"
    assert artifact.size == byte_size("zip-bytes")
    assert artifact.key != artifact.filename
    assert String.match?(artifact.sha256, ~r/\A[0-9a-f]{64}\z/)
    assert {:ok, verified_path} = ArtifactStorage.verify(artifact, root: context.root)
    assert verified_path == artifact.path
    assert String.starts_with?(artifact.path, Path.expand(context.root))
  end

  test "fails closed for corrupted, missing, or capacity-exceeding artifacts", context do
    assert {:ok, artifact} =
             ArtifactStorage.publish(
               context.organization_id,
               context.version_id,
               context.run_id,
               "network.zip",
               "zip-bytes",
               root: context.root
             )

    File.write!(artifact.path, "altered")

    assert {:error, :missing_or_corrupt_artifact} =
             ArtifactStorage.verify(artifact, root: context.root)

    assert {:error, :artifact_capacity_exceeded} =
             ArtifactStorage.publish(
               context.organization_id,
               context.version_id,
               Ecto.UUID.generate(),
               "network.zip",
               "too large",
               root: context.root,
               max_run_bytes: 1
             )

    assert {:error, :artifact_capacity_exceeded} =
             ArtifactStorage.publish(
               context.organization_id,
               context.version_id,
               Ecto.UUID.generate(),
               "network.zip",
               "too large",
               root: context.root,
               max_total_bytes: byte_size("zip-bytes")
             )

    assert {:error, :missing_or_corrupt_artifact} =
             ArtifactStorage.verify(%{artifact | path: Path.join(context.root, "missing.zip")},
               root: context.root
             )
  end

  test "reconciles orphan run directories without deleting kept runs", context do
    orphan_run = Ecto.UUID.generate()

    assert {:ok, kept} =
             ArtifactStorage.publish(
               context.organization_id,
               context.version_id,
               context.run_id,
               "kept.zip",
               "kept",
               root: context.root
             )

    assert {:ok, orphan} =
             ArtifactStorage.publish(
               context.organization_id,
               context.version_id,
               orphan_run,
               "orphan.zip",
               "orphan",
               root: context.root
             )

    assert {:ok, 1} = ArtifactStorage.reconcile([context.run_id], root: context.root)
    assert File.exists?(kept.path)
    refute File.exists?(orphan.path)
  end
end
