defmodule GtfsPlanner.Gtfs.Export.WorkerTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.{Run, Worker}
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  # Stands in for the configured OTP preflight module so a full warning buffer
  # can be observed without an OTP graph.
  defmodule HundredWarningPreflight do
    def run(_organization_id, _gtfs_version_id, _export_type) do
      {:error,
       Enum.map(0..99, fn index ->
         %{code: "preflight_#{index}", message: "Preflight issue #{index}"}
       end)}
    end
  end

  defmodule TwoWarningPreflight do
    def run(_organization_id, _gtfs_version_id, _export_type) do
      {:error,
       [
         %{code: "preflight_0", message: "Preflight issue 0"},
         %{code: "preflight_1", message: "Preflight issue 1"}
       ]}
    end
  end

  # Builds the real ZIPs and replaces their warnings with one the `Run` schema
  # rejects, which is one way the fenced warning write fails while the lease is
  # still current. The composition cases above use the concrete adapter as-is.
  defmodule UnsupportedWarningExport do
    def build_zips(organization_id, gtfs_version_id, export_type, opts) do
      {:ok, zips, _warnings} =
        Export.build_zips(organization_id, gtfs_version_id, export_type, opts)

      {:ok, zips,
       [%{code: "unsupported", detail: "unsupported warning", extra_key: "unsupported"}]}
    end
  end

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

  test "an operations run without vehicles reaches ready with the omitted-file warning", %{
    root: root
  } do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, stop_id: "STOP1")
    garage_fixture(organization.id, garage_id: "garage_main", name: "Main garage")
    {run, claimed, generation, token} = claim_run(organization, version, :operations)

    # The default composition is the concrete `Export` adapter.
    assert Application.get_env(:gtfs_planner, :gtfs_export_module) == nil
    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)

    assert ready.state == :ready
    assert ready.artifact_key
    assert ready.warnings == [tods_omitted_warning("vehicles.txt", "vehicle", "vehicles")]

    entries = published_zip_entries(root, ready)

    assert Map.has_key?(entries, "stops.txt")
    assert entries["stops_supplement.txt"] =~ "garage_main,Main garage"
    refute Map.has_key?(entries, "vehicles.txt")
  end

  test "persists a warning for a stored GTFS violation and still builds the export" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, stop_id: "NO_COORDS", stop_lat: nil, stop_lon: nil)
    {run, claimed, generation, token} = claim_run(organization, version, :full)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)

    assert ready.state == :ready
    assert [%{"code" => "stops_missing_coordinates", "detail" => detail}] = ready.warnings
    assert detail =~ "1 stop, station or entrance has no latitude/longitude"
    assert detail =~ "NO_COORDS"
  end

  test "a pathways run does not warn about trips that its files do not contain" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, stop_id: "STOP1")
    route = route_fixture(organization.id, version.id)
    trip_fixture(organization.id, version.id, route.route_id, service_id: "NO_CALENDAR")
    {run, claimed, generation, token} = claim_run(organization, version, :pathways)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)

    assert ready.state == :ready
    assert ready.warnings == []
  end

  test "keeps the operations omission ahead of 100 preflight warnings" do
    with_preflight_module(HundredWarningPreflight)
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, stop_id: "STOP1")
    garage_fixture(organization.id, garage_id: "garage_main")
    {run, claimed, generation, token} = claim_run(organization, version, :operations)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)

    assert ready.state == :ready
    assert length(ready.warnings) == 100
    assert hd(ready.warnings) == tods_omitted_warning("vehicles.txt", "vehicle", "vehicles")
    assert Enum.at(ready.warnings, 1) == preflight_warning(0)

    assert Enum.map(tl(ready.warnings), & &1["code"]) ==
             Enum.map(0..98, &"preflight_#{&1}")
  end

  test "a garage/stop collision fails the run, names garage and stop, and publishes nothing", %{
    root: root
  } do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, stop_id: "STOP1", stop_name: "Main Street")
    garage_fixture(organization.id, garage_id: "STOP1", name: "Main garage")
    {run, claimed, generation, token} = claim_run(organization, version, :operations)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    failed = Repo.get!(Run, run.id)

    assert failed.state == :failed
    assert failed.failure_code == "garage_stop_id_conflict"
    assert failed.artifact_key == nil

    assert [warning] = failed.warnings
    assert warning["code"] == "garage_stop_id_conflict"
    assert warning["file"] == "stops_supplement.txt"
    assert warning["entity_type"] == "garage"
    assert warning["detail"] =~ "Main garage"
    assert warning["detail"] =~ "STOP1"
    assert warning["detail"] =~ "Main Street"

    assert published_files(root) == []
  end

  test "bounds more than 100 conflicting garages to 99 details and the remaining count", %{
    root: root
  } do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    conflicting_ids = Enum.map(1..101, &conflict_id/1)

    for garage_id <- conflicting_ids do
      stop_fixture(organization.id, version.id,
        stop_id: garage_id,
        stop_name: "Stop #{garage_id}"
      )

      garage_fixture(organization.id, garage_id: garage_id, name: "Garage #{garage_id}")
    end

    {run, claimed, generation, token} = claim_run(organization, version, :operations)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    failed = Repo.get!(Run, run.id)

    assert failed.state == :failed
    assert failed.failure_code == "garage_stop_id_conflict"
    assert length(failed.warnings) == 100

    details = Enum.take(failed.warnings, 99) |> Enum.map(& &1["detail"])

    assert Enum.zip(details, Enum.take(conflicting_ids, 99))
           |> Enum.all?(fn {detail, garage_id} ->
             String.contains?(detail, "Garage \"Garage #{garage_id}\" (#{garage_id})") and
               String.contains?(detail, "the stop \"Stop #{garage_id}\"")
           end)

    assert List.last(failed.warnings) == %{
             "code" => "garage_stop_id_conflict",
             "file" => "stops_supplement.txt",
             "entity_type" => "garage",
             "detail" =>
               "2 more garages match stop IDs in this exported version. Open Garages to review all current conflicts."
           }

    assert published_files(root) == []
  end

  test "a rejected warning write leaves the run failed without publishing", %{root: root} do
    with_export_module(UnsupportedWarningExport)
    with_preflight_module(TwoWarningPreflight)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, stop_id: "STOP1")
    garage_fixture(organization.id, garage_id: "garage_main")
    {run, claimed, generation, token} = claim_run(organization, version, :operations)

    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    failed = Repo.get!(Run, run.id)

    assert failed.state == :failed
    assert failed.failure_code == "export_failed"
    assert failed.artifact_key == nil
    # The rejected write neither published nor replaced the stored warnings.
    assert failed.warnings == [preflight_warning(0), preflight_warning(1)]
    assert published_files(root) == []
  end

  defp claim_run(organization, version, export_type) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
    {:ok, claimed, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    {run, claimed, generation, token}
  end

  defp with_preflight_module(module), do: put_module(:otp_preflight_module, module)

  defp with_export_module(module), do: put_module(:gtfs_export_module, module)

  defp put_module(config_key, module) do
    previous = Application.get_env(:gtfs_planner, config_key)
    Application.put_env(:gtfs_planner, config_key, module)
    on_exit(fn -> restore_env(config_key, previous) end)
  end

  defp conflict_id(index), do: "CONFLICT" <> String.pad_leading("#{index}", 3, "0")

  defp published_files(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  # The published file is named by its stored key inside the run's directory.
  defp published_zip_entries(root, run) do
    path =
      Path.join([
        root,
        "export-runs",
        run.organization_id,
        run.gtfs_version_id,
        run.id,
        run.artifact_key
      ])

    {:ok, entries} = path |> File.read!() |> :zip.unzip([:memory])
    Map.new(entries, fn {name, content} -> {to_string(name), content} end)
  end

  # `gtfs_export_runs.warnings` is a `jsonb[]`, so a row read back from the
  # database carries string keys; the worker writes atom-keyed maps.
  defp tods_omitted_warning(filename, entity_type, label) do
    %{
      "code" => "tods_file_omitted",
      "detail" => "#{filename} was not included because this organization has no #{label}.",
      "file" => filename,
      "entity_type" => entity_type
    }
  end

  defp preflight_warning(index) do
    %{"code" => "preflight_#{index}", "detail" => "Preflight issue #{index}"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
