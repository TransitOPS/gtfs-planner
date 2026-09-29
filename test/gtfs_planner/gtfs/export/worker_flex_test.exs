defmodule GtfsPlanner.Gtfs.Export.WorkerFlexTest do
  @moduledoc """
  Judges the flex artifact on export runs (EV-15, AC-16).

  The prepared cases run the concrete `GtfsPlanner.Gtfs.Export.Worker` on the
  local test database with a per-test temporary artifact root: a flex run
  publishes the main and flex zips from one `build_zips/4` answer and records
  both with the build's bytes; the switch off and an R15 version leave the flex
  slots empty; a pair over the run budget fails before writing; expiry and
  corruption remove both files and clear both column sets.

  ZIP bytes are compared with their build by entry content and size rather than
  whole-file bytes: `:zip.create/3` stamps every member with its creation time,
  so two builds of identical data across a second boundary are equal in content
  but not in bytes (the same limit step 15 recorded for the main zip). The
  stored digest is checked against the published file's bytes, which is what
  `ExportRuns.mark_ready/5` commits.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.{Run, Worker}
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Repo

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  @drawn_area %{
    "type" => "Polygon",
    "coordinates" => [
      [
        [-124.09, 44.57],
        [-124.08, 44.57],
        [-124.08, 44.58],
        [-124.09, 44.58],
        [-124.09, 44.57]
      ]
    ]
  }

  # Stands in for the configured export module with a controlled byte pair:
  # each file fits the run budget and the pair together does not.
  defmodule TwoZipExport do
    def build_zips(_organization_id, _gtfs_version_id, _export_type, _opts) do
      {:ok, %{main: :binary.copy(<<0>>, 600), flex: :binary.copy(<<1>>, 600)}, []}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "export-worker-flex-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    old_run_bytes = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_max_run_bytes)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, old_root)
      restore_env(:gtfs_task_artifacts_max_run_bytes, old_run_bytes)
    end)

    %{root: root}
  end

  test "a full run with flex included publishes both zips with the build's bytes", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    flex_representative_fixture(organization, version)

    assert {:ok, %{main: main, flex: flex}, _warnings} =
             Export.build_zips(organization.id, version.id, :full, include_flex: true)

    {run, claimed, generation, token} = claim_run(organization, version, :full)
    assert run.include_flex

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)

    assert ready.state == :ready
    assert ready.artifact_filename == "gtfs-#{run.id}.zip"
    assert ready.flex_artifact_filename == "gtfs-flex-#{run.id}.zip"
    assert ready.artifact_size_bytes == byte_size(main)
    assert ready.flex_artifact_size_bytes == byte_size(flex)
    refute ready.artifact_sha256 == ready.flex_artifact_sha256

    main_bytes = File.read!(artifact_path(root, ready, :main))
    flex_bytes = File.read!(artifact_path(root, ready, :flex))

    assert ready.artifact_sha256 == digest(main_bytes)
    assert ready.flex_artifact_sha256 == digest(flex_bytes)
    assert zip_entries(main_bytes) == zip_entries(main)
    assert zip_entries(flex_bytes) == zip_entries(flex)

    files = zip_entries(flex_bytes)
    assert Map.has_key?(files, "locations.geojson")
    assert Map.has_key?(files, "booking_rules.txt")
    refute Map.has_key?(zip_entries(main_bytes), "locations.geojson")

    assert {:ok, claim} = ExportRuns.claim_download(organization.id, version.id, run.id, :flex)
    assert claim.filename == "gtfs-flex-#{run.id}.zip"
    assert claim.size == byte_size(flex)
    assert claim.sha256 == ready.flex_artifact_sha256
  end

  test "a full run with the switch off publishes only the main zip", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    flex_representative_fixture(organization, version)
    assert {:ok, _defaults} = ExportDefaults.update(organization.id, %{include_flex: false})

    {run, claimed, generation, token} = claim_run(organization, version, :full)
    refute run.include_flex

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)

    assert ready.state == :ready
    assert ready.artifact_filename == "gtfs-#{run.id}.zip"
    assert ready.artifact_key
    assert ready.flex_artifact_key == nil
    assert ready.flex_artifact_filename == nil
    assert ready.flex_artifact_sha256 == nil
    assert ready.flex_artifact_size_bytes == nil
    assert length(published_files(root)) == 1
  end

  test "a version without routes stores the flex zip as the primary artifact", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    only_feed_service(organization, version)

    {run, claimed, generation, token} = claim_run(organization, version, :full)
    assert run.include_flex

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)

    assert ready.state == :ready
    assert ready.artifact_filename == "gtfs-flex-#{run.id}.zip"

    assert ready.artifact_sha256 == digest(File.read!(artifact_path(root, ready, :main)))
    assert ready.flex_artifact_key == nil
    assert ready.flex_artifact_filename == nil
    assert ready.flex_artifact_sha256 == nil
    assert ready.flex_artifact_size_bytes == nil
    assert length(published_files(root)) == 1
    assert Enum.any?(ready.warnings, &(&1["code"] == "main_feed_not_produced"))

    assert zip_entries(File.read!(artifact_path(root, ready, :main)))["routes.txt"] =~
             "flex-only-feed-shuttle"
  end

  test "a pair over the run budget fails before either file is written", %{root: root} do
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_max_run_bytes, 1_000)
    with_export_module(TwoZipExport)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {run, claimed, generation, token} = claim_run(organization, version, :full)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    failed = Repo.get!(Run, run.id)

    assert failed.state == :failed
    assert failed.failure_code == "artifact_capacity_exceeded"
    assert failed.artifact_key == nil
    assert failed.flex_artifact_key == nil
    assert published_files(root) == []
  end

  test "expiry removes both files and clears both artifact sets", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    flex_representative_fixture(organization, version)
    {run, claimed, generation, token} = claim_run(organization, version, :full)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))
    assert length(published_files(root)) == 2

    expire_run!(run)
    assert ExportRuns.cleanup_expired(organization.id) == 1

    expired = Repo.get!(Run, run.id)

    assert expired.state == :expired
    assert expired.failure_code == "artifact_expired"
    assert expired.artifact_key == nil
    assert expired.artifact_filename == nil
    assert expired.artifact_sha256 == nil
    assert expired.artifact_size_bytes == nil
    assert expired.flex_artifact_key == nil
    assert expired.flex_artifact_filename == nil
    assert expired.flex_artifact_sha256 == nil
    assert expired.flex_artifact_size_bytes == nil
    assert published_files(root) == []
  end

  test "a corrupt main artifact closes the run and removes both files", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    flex_representative_fixture(organization, version)
    {run, claimed, generation, token} = claim_run(organization, version, :full)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))
    main_path = artifact_path(root, Repo.get!(Run, run.id), :main)
    File.write!(main_path, "corrupt")

    assert {:error, :not_found} = ExportRuns.claim_download(organization.id, version.id, run.id)

    failed = Repo.get!(Run, run.id)

    assert failed.state == :failed
    assert failed.failure_code == "missing_or_corrupt_artifact"
    assert failed.artifact_key == nil
    assert failed.flex_artifact_key == nil
    assert failed.flex_artifact_sha256 == nil
    assert published_files(root) == []
  end

  test "a corrupt flex artifact closes the run and removes both files", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    flex_representative_fixture(organization, version)
    {run, claimed, generation, token} = claim_run(organization, version, :full)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))
    flex_path = artifact_path(root, Repo.get!(Run, run.id), :flex)
    File.write!(flex_path, "corrupt")

    assert {:error, :not_found} =
             ExportRuns.claim_download(organization.id, version.id, run.id, :flex)

    failed = Repo.get!(Run, run.id)

    assert failed.state == :failed
    assert failed.failure_code == "missing_or_corrupt_artifact"
    assert failed.artifact_key == nil
    assert failed.flex_artifact_key == nil
    assert published_files(root) == []
  end

  test "a run without a flex artifact answers the flex claim with not_found and stays ready", %{
    root: root
  } do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    flex_representative_fixture(organization, version)
    assert {:ok, _defaults} = ExportDefaults.update(organization.id, %{include_flex: false})
    {run, claimed, generation, token} = claim_run(organization, version, :full)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    assert {:error, :not_found} =
             ExportRuns.claim_download(organization.id, version.id, run.id, :flex)

    ready = Repo.get!(Run, run.id)

    assert ready.state == :ready
    assert ready.artifact_key
    assert length(published_files(root)) == 1
  end

  defp claim_run(organization, version, export_type) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
    {:ok, claimed, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    {run, claimed, generation, token}
  end

  # Agency, one weekday calendar and one drawn-area service: the version has no
  # fixed routes, so R15 makes the flex zip its only feed.
  defp only_feed_service(organization, version) do
    agency_fixture(organization.id, version.id, %{
      agency_id: "SOLO",
      agency_name: "Solo Transit",
      agency_url: "https://example.org",
      agency_timezone: "America/Los_Angeles"
    })

    calendar_fixture(organization.id, version.id, %{
      service_id: "weekday",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    {:ok, service} =
      Flex.create_service(organization.id, version.id, %{
        name: "Only Feed Shuttle",
        kind: :area
      })

    assert {:ok, _service} =
             Flex.save_service(
               organization.id,
               version.id,
               service,
               %{
                 phone: "(541) 555-0142",
                 hours: [%{area_key: "a1", service_id: "weekday", start: "08:00", end: "17:00"}],
                 booking_rules: [%{when: :same_day, minutes: 60}]
               },
               [%{key: "a1", name: "Solo", source: :drawn, geojson: @drawn_area}]
             )
  end

  defp expire_run!(run) do
    from(r in Run, where: r.id == ^run.id)
    |> Repo.update_all(set: [artifact_expires_at: ~U[2000-01-01 00:00:00.000000Z]])
  end

  defp published_files(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  # Artifact files are named by their stored key inside the run's directory; the
  # run row's filename is what a download is called.
  defp artifact_path(root, run, file) do
    key = if file == :main, do: run.artifact_key, else: run.flex_artifact_key

    Path.join([
      root,
      "export-runs",
      run.organization_id,
      run.gtfs_version_id,
      run.id,
      key
    ])
  end

  defp zip_entries(bytes) do
    {:ok, entries} = :zip.unzip(bytes, [:memory])
    Map.new(entries, fn {name, content} -> {to_string(name), content} end)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp with_export_module(module) do
    previous = Application.get_env(:gtfs_planner, :gtfs_export_module)
    Application.put_env(:gtfs_planner, :gtfs_export_module, module)
    on_exit(fn -> restore_env(:gtfs_export_module, previous) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
