# Step 004 — Fill missing times in export and validation
#
# Production-composition integration test (EV-4): a run created by
# `ExportRuns.create_pending` and built by `Worker.build/4` with the real
# export module yields estimated stop times per its recorded setting, without
# changing stored rows; `Validator` passes the current defaults through to the
# configured export module.

defmodule GtfsPlanner.Gtfs.Export.MissingTimesExportTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.FlexFixtures, only: [flex_audit_fixture: 2]
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.Export.Worker
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  # Stands in for the configured export module so the test observes the
  # estimate option `Validator.validate/3` passes without exporting.
  defmodule RecordingExport do
    def export_to_zip(organization_id, gtfs_version_id, profile, opts) do
      send(self(), {:exported, organization_id, gtfs_version_id, profile, opts})
      {:ok, :binary.copy(<<0>>, 32)}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "missing-times-export-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, old_root)
    end)

    %{root: root}
  end

  test "an estimating run fills blanks by distance with timepoint 0 and leaves stored rows blank",
       %{
         root: root
       } do
    {organization, version} = seed_fillable_version()

    before =
      version_stop_times(organization.id, version.id)
      |> Enum.map(&{&1.stop_sequence, &1.arrival_time, &1.departure_time})

    assert {"", ""} ==
             {arrival_of(before, 2), departure_of(before, 2)}

    {run, claimed, generation, token} = claim_run(organization, version, :full)

    # The run snapshots the default {true, :distance} setting at creation.
    assert run.estimate_missing_times == true
    assert run.estimate_method == :distance
    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)
    assert ready.state == :ready
    refute Enum.any?(ready.warnings, &(&1["code"] == "missing_times_not_estimated"))

    rows = stop_time_rows(root, ready)

    assert trip_rows(rows, "T1") == [
             {"S1", "08:00:00", "08:00:00", "1", "1"},
             {"S2", "08:00:40", "08:00:40", "2", "0"},
             {"S3", "08:01:20", "08:01:20", "3", "0"},
             {"S4", "08:08:00", "08:08:00", "4", "0"},
             {"S5", "08:10:00", "08:10:00", "5", "1"}
           ]

    # INV-1: the estimating build never rewrites stored stop times.
    assert version_stop_times(organization.id, version.id)
           |> Enum.map(&{&1.stop_sequence, &1.arrival_time, &1.departure_time}) == before
  end

  test "a non-estimating run writes stored blanks unchanged", %{root: root} do
    {organization, version} = seed_fillable_version()
    {:ok, _} = ExportDefaults.update(organization.id, %{estimate_missing_times: false})

    {run, claimed, generation, token} = claim_run(organization, version, :full)

    assert run.estimate_missing_times == false
    assert run.estimate_method == nil
    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)
    assert ready.state == :ready

    rows = stop_time_rows(root, ready)

    assert trip_rows(rows, "T1") == [
             {"S1", "08:00:00", "08:00:00", "1", ""},
             {"S2", "", "", "2", ""},
             {"S3", "", "", "3", ""},
             {"S4", "", "", "4", ""},
             {"S5", "08:10:00", "08:10:00", "5", "1"}
           ]
  end

  test "a snapshot run still estimates after the defaults change", %{root: root} do
    {organization, version} = seed_fillable_version()
    {:ok, _} = ExportDefaults.update(organization.id, %{estimate_method: :even})
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)

    assert run.estimate_missing_times == true
    assert run.estimate_method == :even

    # Changing the defaults after the run exists must not alter the run.
    {:ok, _} = ExportDefaults.update(organization.id, %{estimate_missing_times: false})
    {:ok, claimed, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = Repo.get!(Run, run.id)
    assert ready.state == :ready

    rows = stop_time_rows(root, ready)

    assert trip_rows(rows, "T1") == [
             {"S1", "08:00:00", "08:00:00", "1", "1"},
             {"S2", "08:02:30", "08:02:30", "2", "0"},
             {"S3", "08:05:00", "08:05:00", "3", "0"},
             {"S4", "08:07:30", "08:07:30", "4", "0"},
             {"S5", "08:10:00", "08:10:00", "5", "1"}
           ]
  end

  test "a frequency trip's template fills like a scheduled trip", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_trip_with_blanks(organization.id, version.id, "R1", "TF", "08")
    frequency_fixture(organization.id, version.id, "TF")

    {run, claimed, generation, token} = claim_run(organization, version, :full)
    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = ready_run!(run)
    rows = stop_time_rows(root, ready)

    assert trip_rows(rows, "TF") == [
             {"S1", "08:00:00", "08:00:00", "1", "1"},
             {"S2", "08:00:40", "08:00:40", "2", "0"},
             {"S3", "08:01:20", "08:01:20", "3", "0"},
             {"S4", "08:08:00", "08:08:00", "4", "0"},
             {"S5", "08:10:00", "08:10:00", "5", "1"}
           ]
  end

  test "filled rows on a detour route keep their doubled stop_sequence", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_trip_with_blanks(organization.id, version.id, "20", "T20", "08")

    {:ok, _service} =
      Flex.create_service(flex_audit_fixture(organization.id, version.id), %{
        name: "Valley Line detours",
        kind: :detour,
        route_id: "20"
      })

    # Flex stays out of the run, but R3 still doubles the detour route.
    {:ok, _} = ExportDefaults.update(organization.id, %{include_flex: false})
    {run, claimed, generation, token} = claim_run(organization, version, :full)
    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = ready_run!(run)
    rows = stop_time_rows(root, ready)

    # Fill ran before the R3 mapper: estimates with doubled sequences.
    assert trip_rows(rows, "T20") == [
             {"S1", "08:00:00", "08:00:00", "2", "1"},
             {"S2", "08:00:40", "08:00:40", "4", "0"},
             {"S3", "08:01:20", "08:01:20", "6", "0"},
             {"S4", "08:08:00", "08:08:00", "8", "0"},
             {"S5", "08:10:00", "08:10:00", "10", "1"}
           ]
  end

  test "an unfillable trip is written unchanged with one warning naming it", %{root: root} do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    for index <- 1..5 do
      stop_fixture(organization.id, version.id, stop_id: "S#{index}")
    end

    route_fixture(organization.id, version.id, route_id: "R1")
    trip_fixture(organization.id, version.id, "R1", %{trip_id: "TGOOD"})
    trip_fixture(organization.id, version.id, "R1", %{trip_id: "TBAD"})

    # A fillable trip stays estimated while the broken one warns.
    seed_blanks(organization.id, version.id, "TGOOD", "08:00:00", "08:10:00")

    stop_time_fixture(organization.id, version.id, "TBAD", "S1",
      stop_sequence: 1,
      arrival_time: "09:00:00",
      departure_time: "09:00:00",
      timepoint: 1
    )

    stop_time_fixture(organization.id, version.id, "TBAD", "S2",
      stop_sequence: 2,
      arrival_time: nil,
      departure_time: nil
    )

    {run, claimed, generation, token} = claim_run(organization, version, :full)
    assert :ok = Worker.build(claimed, generation, token, ExportRuns.topic(run))

    ready = ready_run!(run)
    assert ready.state == :ready

    missing =
      Enum.filter(ready.warnings, &(&1["code"] == "missing_times_not_estimated"))

    assert length(missing) == 1
    assert hd(missing)["file"] == "stop_times.txt"
    assert hd(missing)["entity_type"] == "trip"
    assert hd(missing)["detail"] =~ "TBAD"

    rows = stop_time_rows(root, ready)

    assert trip_rows(rows, "TBAD") == [
             {"S1", "09:00:00", "09:00:00", "1", "1"},
             {"S2", "", "", "2", ""}
           ]

    assert length(trip_rows(rows, "TGOOD")) == 5
    assert Enum.at(trip_rows(rows, "TGOOD"), 1) == {"S2", "08:00:40", "08:00:40", "2", "0"}
  end

  test "the validator passes the estimating defaults to the export module" do
    with_export_module(RecordingExport)
    without_validator_path()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

    assert {:error, :validator_path_not_configured} =
             Validator.validate(organization.id, version.id, validation_run_id: run.id)

    assert_received {:exported, organization_id, version_id, :full, [estimate: :distance]}
    assert organization_id == organization.id
    assert version_id == version.id
  end

  test "the validator passes nil when the organization does not estimate" do
    with_export_module(RecordingExport)
    without_validator_path()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    {:ok, _} = ExportDefaults.update(organization.id, %{estimate_missing_times: false})

    {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

    assert {:error, :validator_path_not_configured} =
             Validator.validate(organization.id, version.id, validation_run_id: run.id)

    assert_received {:exported, organization_id, version_id, :full, [estimate: nil]}
    assert organization_id == organization.id
    assert version_id == version.id
  end

  # --- fixtures ---------------------------------------------------------------

  # One version with a fillable trip: anchors at 08:00 and 08:10 over stored
  # distances 0/200/400/2400/3000, so distance shares are exactly
  # 40/80/480 s and equal shares exactly 150/300/450 s.
  defp seed_fillable_version do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_trip_with_blanks(organization.id, version.id, "R1", "T1", "08")
    {organization, version}
  end

  defp seed_trip_with_blanks(organization_id, version_id, route_id, trip_id, hour) do
    for index <- 1..5 do
      stop_fixture(organization_id, version_id, stop_id: "S#{index}")
    end

    route_fixture(organization_id, version_id, route_id: route_id)
    trip_fixture(organization_id, version_id, route_id, %{trip_id: trip_id})

    seed_blanks(organization_id, version_id, trip_id, "#{hour}:00:00", "#{hour}:10:00")
  end

  defp seed_blanks(organization_id, version_id, trip_id, first, last) do
    distances = ["0", "200", "400", "2400", "3000"]

    mids =
      for sequence <- 2..4 do
        %{
          stop_sequence: sequence,
          arrival_time: nil,
          departure_time: nil,
          shape_dist_traveled: Decimal.new(Enum.at(distances, sequence - 1))
        }
      end

    rows =
      [
        %{
          stop_sequence: 1,
          arrival_time: first,
          departure_time: first,
          timepoint: nil,
          shape_dist_traveled: Decimal.new("0")
        }
      ] ++
        mids ++
        [
          %{
            stop_sequence: 5,
            arrival_time: last,
            departure_time: last,
            timepoint: 1,
            shape_dist_traveled: Decimal.new("3000")
          }
        ]

    Enum.each(rows, fn attrs ->
      stop_time_fixture(
        organization_id,
        version_id,
        trip_id,
        "S#{attrs.stop_sequence}",
        attrs
      )
    end)
  end

  # --- build helpers ----------------------------------------------------------

  defp claim_run(organization, version, export_type) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
    {:ok, claimed, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    {run, claimed, generation, token}
  end

  defp ready_run!(run), do: Repo.get!(Run, run.id)

  defp stop_time_rows(root, run) do
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
    {_, content} = Enum.find(entries, fn {name, _} -> to_string(name) == "stop_times.txt" end)

    [header | lines] =
      content |> to_string() |> String.split("\n", trim: true)

    columns = String.split(header, ",")

    Enum.map(lines, fn line ->
      columns |> Enum.zip(String.split(line, ",")) |> Map.new()
    end)
  end

  defp trip_rows(rows, trip_id) do
    rows
    |> Enum.filter(&(&1["trip_id"] == trip_id))
    |> Enum.sort_by(&String.to_integer(&1["stop_sequence"]))
    |> Enum.map(fn row ->
      {row["stop_id"], row["arrival_time"], row["departure_time"], row["stop_sequence"],
       row["timepoint"]}
    end)
  end

  defp version_stop_times(organization_id, version_id) do
    import Ecto.Query

    from(s in StopTime,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id,
      order_by: [asc: s.trip_id, asc: s.stop_sequence]
    )
    |> Repo.all()
  end

  defp arrival_of(rows, sequence) do
    {_, arrival, _} = Enum.find(rows, fn {seq, _, _} -> seq == sequence end)
    arrival || ""
  end

  defp departure_of(rows, sequence) do
    {_, _, departure} = Enum.find(rows, fn {seq, _, _} -> seq == sequence end)
    departure || ""
  end

  defp with_export_module(module) do
    previous = Application.get_env(:gtfs_planner, :gtfs_export_module)
    Application.put_env(:gtfs_planner, :gtfs_export_module, module)
    on_exit(fn -> restore_env(:gtfs_export_module, previous) end)
  end

  defp without_validator_path do
    previous = Application.get_env(:gtfs_planner, :gtfs_validator_path)
    Application.put_env(:gtfs_planner, :gtfs_validator_path, nil)
    on_exit(fn -> restore_env(:gtfs_validator_path, previous) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
