defmodule GtfsPlanner.Gtfs.ExportPublicationPinTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.PublicationPin
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.TaskArtifactMaintenance
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}
  @owner "static-publisher"

  setup do
    root = Path.join(System.tmp_dir!(), "export-pins-#{System.unique_integer([:positive])}")
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

  test "a ready pin protects the artifact from cleanup and records no download" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run = ready_run(organization, version)

    assert {:ok, pin} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :main, @owner)

    assert pin.path == artifact(run).path
    assert pin.filename == "network.zip"
    assert pin.size == byte_size("zip-bytes")
    assert pin.sha256 == artifact(run).sha256
    assert {:ok, _} = Ecto.UUID.cast(pin.pin_token)

    # The pin is a lease, not a download: no counter, no download claim.
    assert Repo.get!(Run, run.id).download_count == 0
    assert is_nil(Repo.get!(Run, run.id).download_claimed_until)

    expire_artifact!(run)

    assert ExportRuns.cleanup_expired(organization.id) == 0
    assert Repo.get!(Run, run.id).state == :ready
    assert File.exists?(pin.path)
  end

  test "renewal keeps the pin alive and only the current token may release it" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run = ready_run(organization, version)

    assert {:ok, first} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :main, @owner)

    # A pin may only be taken while the artifact is current; once the pin is live,
    # an artifact whose own TTL elapsed is protected until the pin is released.
    expire_artifact!(run)

    assert {:ok, renewed} =
             ExportRuns.renew_publication_pin(organization.id, run.id, claim(first, @owner))

    assert renewed.pin_token != first.pin_token

    lease = Application.fetch_env!(:gtfs_planner, :export_publication_pin_seconds)
    assert DateTime.diff(renewed.expires_at, DateTime.utc_now()) > lease - 30
    assert ExportRuns.cleanup_expired(organization.id) == 0

    # A late release holding the pre-renewal token is fenced, so it cannot clear
    # the renewed claim.
    assert {:error, :lease_lost} =
             ExportRuns.release_publication_pin(organization.id, run.id, claim(first, @owner))

    assert pin_row(run).pin_token == renewed.pin_token
    assert ExportRuns.cleanup_expired(organization.id) == 0

    # A foreign owner cannot renew or release it either.
    assert {:error, :lease_lost} =
             ExportRuns.renew_publication_pin(organization.id, run.id, claim(renewed, "other"))

    assert {:error, :lease_lost} =
             ExportRuns.release_publication_pin(organization.id, run.id, claim(renewed, "other"))

    assert :ok =
             ExportRuns.release_publication_pin(
               organization.id,
               run.id,
               claim(renewed, @owner)
             )

    assert Repo.aggregate(PublicationPin, :count) == 0
    assert ExportRuns.cleanup_expired(organization.id) == 1
  end

  test "an expired pin is no protection and the same owner may reclaim the run" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run = ready_run(organization, version)

    assert {:ok, _first} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :main, @owner)

    expire_artifact!(run)
    expire_pin!(run)

    # Maintenance drops elapsed pins before it cleans expired artifacts.
    assert ExportRuns.purge_expired_publication_pins(organization.id) == 1
    assert Repo.aggregate(PublicationPin, :count) == 0
    assert ExportRuns.cleanup_expired(organization.id) == 1
    assert Repo.get!(Run, run.id).state == :expired

    # A live pin held by another owner is refused, never replaced.
    other_run = ready_run(organization, version)

    assert {:ok, held} =
             ExportRuns.pin_publication(organization.id, version.id, other_run.id, :main, @owner)

    assert {:error, :artifact_busy} =
             ExportRuns.pin_publication(
               organization.id,
               version.id,
               other_run.id,
               :main,
               "second"
             )

    assert pin_row(other_run).pin_token == held.pin_token

    # The same owner renews its own live claim rather than losing it.
    assert {:ok, reclaimed} =
             ExportRuns.pin_publication(organization.id, version.id, other_run.id, :main, @owner)

    assert reclaimed.pin_token != held.pin_token
    assert pin_row(other_run).pin_token == reclaimed.pin_token
  end

  test "expired, missing, corrupt and foreign artifacts cannot be pinned" do
    organization = organization_fixture()
    other_organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    foreign_version = gtfs_version_fixture(other_organization.id)

    # Not a ready run yet.
    assert {:ok, pending} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)

    assert {:error, :not_found} =
             ExportRuns.pin_publication(organization.id, version.id, pending.id, :main, @owner)

    run = ready_run(organization, version)
    artifact(run)

    # Another tenant's scope, and a run that belongs to a different version.
    assert {:error, :not_found} =
             ExportRuns.pin_publication(other_organization.id, version.id, run.id, :main, @owner)

    assert {:error, :not_found} =
             ExportRuns.pin_publication(
               organization.id,
               foreign_version.id,
               run.id,
               :main,
               @owner
             )

    # The trusted slot is explicit: a run with no flex artifact cannot be pinned as flex.
    assert {:error, :not_found} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :flex, @owner)

    assert {:ok, _main} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :main, @owner)

    assert pin_row(run).slot == :main

    # Expired artifact bytes.
    other = ready_run(organization, version)
    expire_artifact!(other)

    assert {:error, :not_found} =
             ExportRuns.pin_publication(organization.id, version.id, other.id, :main, @owner)

    # Corrupt bytes on disk are normalized exactly as a download claim normalizes them.
    corrupt = ready_run(organization, version)
    corrupt_artifact = artifact(corrupt)
    File.write!(corrupt_artifact.path, "corrupt")

    assert {:error, :not_found} =
             ExportRuns.pin_publication(organization.id, version.id, corrupt.id, :main, @owner)

    assert %Run{state: :failed, failure_code: "missing_or_corrupt_artifact"} =
             Repo.get!(Run, corrupt.id)

    # Missing bytes.
    missing = ready_run(organization, version)
    File.rm!(artifact(missing).path)

    assert {:error, :not_found} =
             ExportRuns.pin_publication(organization.id, version.id, missing.id, :main, @owner)

    assert %Run{state: :failed, failure_code: "missing_or_corrupt_artifact"} =
             Repo.get!(Run, missing.id)

    # Existing download behavior is unchanged by the pin.
    assert {:ok, download} = ExportRuns.claim_download(organization.id, version.id, run.id)
    assert download.claim_id
    assert Repo.get!(Run, run.id).download_count == 1
    assert artifact(run).path == download.path
  end

  test "a flex artifact is pinned under the same owner as its main artifact" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    main = publish!(organization.id, version.id, run.id, "network.zip", "zip-bytes")
    flex = publish!(organization.id, version.id, run.id, "flex.zip", "flex-bytes")

    assert {:ok, _ready} =
             ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
               main: main,
               flex: flex
             })

    assert {:ok, main_pin} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :main, @owner)

    assert main_pin.filename == "network.zip"
    assert main_pin.size == byte_size("zip-bytes")

    # One run carries one publication pin: another owner is refused rather than
    # replacing the live claim.
    assert {:error, :artifact_busy} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :flex, "second")

    assert pin_row(run).pin_token == main_pin.pin_token

    # The owning publisher may move its own claim to the flex slot.
    assert {:ok, flex_pin} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :flex, @owner)

    assert flex_pin.filename == "flex.zip"
    assert flex_pin.sha256 == flex.sha256
    assert pin_row(run).slot == :flex
    assert pin_row(run).pin_token == flex_pin.pin_token

    # The superseded main token no longer owns the run.
    assert {:error, :lease_lost} =
             ExportRuns.release_publication_pin(organization.id, run.id, claim(main_pin, @owner))

    assert :ok =
             ExportRuns.release_publication_pin(organization.id, run.id, claim(flex_pin, @owner))
  end

  test "deleting the source version cannot erase a pinned file" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run = ready_run(organization, version)

    assert {:ok, pin} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :main, @owner)

    # A real database statement, not a mocked cleanup: the run's own
    # ON DELETE CASCADE from the version is stopped by the pin's RESTRICT key.
    # A RESTRICT violation (SQLSTATE 23001) is not one of the constraint classes
    # Ecto converts, so it surfaces as `Postgrex.Error`; either pin run key can
    # be the one PostgreSQL checks first.
    assert_raise Postgrex.Error, ~r/feed_publication_pins_(run_owner|export_run_id)_fkey/, fn ->
      Repo.delete!(version, mode: :savepoint)
    end

    assert Repo.get(Run, run.id)
    assert File.exists?(pin.path)

    # Once the claim is gone the cascade is free again, and only then may the
    # artifact be cleaned.
    assert :ok = ExportRuns.release_publication_pin(organization.id, run.id, claim(pin, @owner))
    Repo.delete!(version)
    refute Repo.get(Run, run.id)
  end

  test "lifecycle maintenance drops expired pins and then cleans their runs" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    run = ready_run(organization, version)

    assert {:ok, _pin} =
             ExportRuns.pin_publication(organization.id, version.id, run.id, :main, @owner)

    expire_artifact!(run)
    assert :ok = TaskArtifactMaintenance.maintain()
    assert Repo.get!(Run, run.id).state == :ready
    assert Repo.aggregate(PublicationPin, :count) == 1

    expire_pin!(run)

    assert :ok = TaskArtifactMaintenance.maintain()
    assert Repo.aggregate(PublicationPin, :count) == 0
    assert Repo.get!(Run, run.id).state == :expired
  end

  defp claim(pin, owner_id), do: %{owner_id: owner_id, pin_token: pin.pin_token}

  defp pin_row(run) do
    Repo.one!(from(p in PublicationPin, where: p.export_run_id == ^run.id))
  end

  defp ready_run(organization, version) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    main = publish!(organization.id, version.id, run.id, "network.zip", "zip-bytes")

    {:ok, ready} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{main: main, flex: nil})

    ready
  end

  defp publish!(organization_id, version_id, run_id, filename, bytes) do
    {:ok, artifact} =
      ArtifactStorage.publish(organization_id, version_id, run_id, filename, bytes)

    artifact
  end

  defp artifact(run) do
    metadata = %{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      run_id: run.id,
      key: run.artifact_key,
      filename: run.artifact_filename,
      sha256: run.artifact_sha256,
      size: run.artifact_size_bytes
    }

    case ArtifactStorage.verify(metadata) do
      {:ok, path} -> Map.put(metadata, :path, path)
      {:error, reason} -> raise "artifact not verifiable: #{inspect(reason)}"
    end
  end

  defp expire_artifact!(run) do
    from(r in Run, where: r.id == ^run.id)
    |> Repo.update_all(set: [artifact_expires_at: ~U[2000-01-01 00:00:00.000000Z]])
  end

  defp expire_pin!(run) do
    from(p in PublicationPin, where: p.export_run_id == ^run.id)
    |> Repo.update_all(set: [expires_at: ~U[2000-01-01 00:00:00.000000Z]])
  end
end
