# Step 050 — Run the validator CLI under a deadline and fail visibly
#
# Process and report-bound tests (EV-50). The Java executable is the only
# faked boundary: `test/support/fixtures/fake_validator.sh` stands in for
# `java -jar <validator>` and records the PID it runs as, so the tests can
# check with `kill -0` that the process the port started is gone. Everything
# else, including `Validator.validate/3` with the real Export, runs for real.

defmodule GtfsPlanner.Gtfs.ValidatorCliProcessTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @moduletag :capture_log

  @fake_java Path.expand("../../support/fixtures/fake_validator.sh", __DIR__)
  @report_limit 67_108_864

  # Stands in for the export module and removes the validation run, so the
  # write after the validator finishes finds no row to update.
  defmodule RunDeletingExport do
    alias GtfsPlanner.Repo
    alias GtfsPlanner.Validations.ValidationRun

    def export_to_zip(_organization_id, _gtfs_version_id, _profile, _opts) do
      Repo.delete_all(ValidationRun)
      {:ok, "zip"}
    end
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "validator_cli_process_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    zip = Path.join(dir, "gtfs.zip")
    File.write!(zip, "zip")

    %{dir: dir, zip: zip}
  end

  describe "run_validator_cli/3" do
    test "configures a 900,000 ms deadline by default" do
      assert Application.fetch_env!(:gtfs_planner, :validator_timeout_ms) == 900_000
    end

    test "returns the output directory when the CLI exits 0", %{dir: dir, zip: zip} do
      assert {:ok, output_dir} = Validator.run_validator_cli(zip, dir, fake_cli("report"))

      assert output_dir == Path.join(dir, "output")
      assert File.regular?(Path.join(output_dir, "report.json"))
    end

    test "returns :timeout and kills the started process at the deadline", %{dir: dir, zip: zip} do
      assert {:error, :timeout} =
               Validator.run_validator_cli(zip, dir, fake_cli("sleep", timeout_ms: 200))

      refute os_process_alive?(recorded_pid(dir))
    end

    test "returns :cancelled and kills the started process on cancel/1", %{dir: dir, zip: zip} do
      {:ok, _timer} = :timer.apply_after(300, Validator, :cancel, [self()])

      assert {:error, :cancelled} =
               Validator.run_validator_cli(zip, dir, fake_cli("sleep", timeout_ms: 30_000))

      refute os_process_alive?(recorded_pid(dir))
    end

    test "does not start the CLI when cancel/1 arrived first", %{dir: dir, zip: zip} do
      :ok = Validator.cancel(self())

      assert {:error, :cancelled} =
               Validator.run_validator_cli(zip, dir, fake_cli("sleep", timeout_ms: 30_000))

      refute File.exists?(Path.join(dir, "output/fake.pid"))
    end

    test "keeps exactly the last 65,536 bytes of a failing CLI's output", %{dir: dir, zip: zip} do
      expected_tail = binary_part(fake_big_output(), 204_800 - 65_536, 65_536)

      assert {:error, {:cli_failed, 3, output}} =
               Validator.run_validator_cli(zip, dir, fake_cli("big_output"))

      assert byte_size(output) == 65_536
      assert output == expected_tail
    end

    test "names a Java executable that cannot be found", %{dir: dir, zip: zip} do
      assert {:error, {:java_not_found, "no-such-java-executable"}} =
               Validator.run_validator_cli(
                 zip,
                 dir,
                 java_path: "no-such-java-executable",
                 validator_path: "report"
               )
    end
  end

  describe "parse_report/2" do
    test "rejects a 70 MiB report from its size without reading it", %{dir: dir} do
      report_path = Path.join(dir, "report.json")
      write_sparse!(report_path, 70 * 1024 * 1024)
      # An unreadable file makes any attempt to read it surface as :eacces.
      File.chmod!(report_path, 0o000)

      assert {:error, :report_too_large} = Validator.parse_report(dir, now_ms())
    end

    test "reads a report of exactly 64 MiB", %{dir: dir} do
      write_sparse!(Path.join(dir, "report.json"), @report_limit)

      # The file holds only zero bytes, so it is read and then rejected as JSON.
      assert {:error, {:invalid_report, _decode_error}} = Validator.parse_report(dir, now_ms())
    end

    test "rejects malformed JSON as an invalid report", %{dir: dir} do
      File.write!(Path.join(dir, "report.json"), ~s({"notices": [))

      assert {:error, {:invalid_report, _decode_error}} = Validator.parse_report(dir, now_ms())
    end

    test "rejects a missing report as an invalid report", %{dir: dir} do
      assert {:error, {:invalid_report, :enoent}} = Validator.parse_report(dir, now_ms())
    end

    test "rejects JSON without a notices list as an invalid report", %{dir: dir} do
      File.write!(Path.join(dir, "report.json"), ~s({"summary": {}}))

      assert {:error, {:invalid_report, :missing_notices}} = Validator.parse_report(dir, now_ms())
    end

    test "groups notices by code", %{dir: dir} do
      File.write!(
        Path.join(dir, "report.json"),
        ~s({"notices": [{"code": "b_code", "severity": "WARNING"}, {"code": "a_code", "severity": "ERROR"}]})
      )

      assert {:ok, %Result{notices: notices}} = Validator.parse_report(dir, now_ms())

      assert notices |> Enum.map(&{&1.code, &1.severity}) |> Enum.sort() ==
               [{"a_code", "ERROR"}, {"b_code", "WARNING"}]
    end
  end

  describe "validate/3" do
    setup do
      put_env(:java_path, @fake_java)

      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      seed_fillable_trip(organization.id, version.id)

      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      %{organization: organization, version: version, run: run}
    end

    test "returns the invalid-report error instead of {:ok, _} and fails the run", ctx do
      put_env(:gtfs_validator_path, "bad_report")

      assert {:error, {:invalid_report, _decode_error}} = validate(ctx)

      assert %ValidationRun{status: "failed"} = Validations.get_validation_run!(ctx.run.id)
    end

    test "returns :report_too_large instead of {:ok, _} when the report exceeds the limit", ctx do
      put_env(:gtfs_validator_path, "big_report")

      assert {:error, :report_too_large} = validate(ctx)

      assert %ValidationRun{status: "failed"} = Validations.get_validation_run!(ctx.run.id)
    end

    test "fails the run with :timeout when the CLI outlives the configured deadline", ctx do
      put_env(:gtfs_validator_path, "sleep")
      put_env(:validator_timeout_ms, 200)

      assert {:error, :timeout} = validate(ctx)

      failed = Validations.get_validation_run!(ctx.run.id)
      assert failed.status == "failed"
      assert failed.error_details =~ "timeout"
    end

    test "returns persistence_failed instead of :ok when the completion write fails", ctx do
      put_env(:gtfs_validator_path, "report")
      put_env(:gtfs_export_module, RunDeletingExport)

      assert {:error, {:persistence_failed, :mark_completed}} = validate(ctx)
    end

    test "returns persistence_failed instead of the CLI error when the failure write fails",
         ctx do
      put_env(:gtfs_validator_path, "sleep")
      put_env(:validator_timeout_ms, 200)
      put_env(:gtfs_export_module, RunDeletingExport)

      assert {:error, {:persistence_failed, :mark_failed}} = validate(ctx)
    end

    test "feeds the real export with the default distance estimate to the CLI", ctx do
      zip_copy = Path.join(System.tmp_dir!(), "validator_default_#{unique()}.zip")
      on_exit(fn -> File.rm(zip_copy) end)
      put_env(:gtfs_validator_path, "report@" <> zip_copy)
      stored = stored_stop_times(ctx.organization.id, ctx.version.id)

      assert {:ok, %Result{}} = validate(ctx)

      assert zip_trip_times(zip_copy) == [
               {"S1", "08:00:00"},
               {"S2", "08:00:40"},
               {"S3", "08:01:20"},
               {"S4", "08:08:00"},
               {"S5", "08:10:00"}
             ]

      assert stored_stop_times(ctx.organization.id, ctx.version.id) == stored
    end

    test "feeds the current :even default, not an earlier export run's snapshot, to the CLI",
         ctx do
      zip_copy = Path.join(System.tmp_dir!(), "validator_even_#{unique()}.zip")
      on_exit(fn -> File.rm(zip_copy) end)
      put_env(:gtfs_validator_path, "report@" <> zip_copy)

      # This export run snapshots {true, :distance}; the validation must not use it.
      {:ok, snapshot_run} =
        ExportRuns.create_pending(ctx.organization.id, ctx.version.id, actor(), :full)

      assert snapshot_run.estimate_method == :distance

      {:ok, _defaults} =
        ExportDefaults.update(ctx.organization.id, editor_fixture(ctx.organization), %{
          estimate_method: :even
        })

      stored = stored_stop_times(ctx.organization.id, ctx.version.id)

      assert {:ok, %Result{}} = validate(ctx)

      assert zip_trip_times(zip_copy) == [
               {"S1", "08:00:00"},
               {"S2", "08:02:30"},
               {"S3", "08:05:00"},
               {"S4", "08:07:30"},
               {"S5", "08:10:00"}
             ]

      assert stored_stop_times(ctx.organization.id, ctx.version.id) == stored
    end

    test "feeds stored blanks to the CLI when the organization does not estimate", ctx do
      zip_copy = Path.join(System.tmp_dir!(), "validator_disabled_#{unique()}.zip")
      on_exit(fn -> File.rm(zip_copy) end)
      put_env(:gtfs_validator_path, "report@" <> zip_copy)

      {:ok, _defaults} =
        ExportDefaults.update(ctx.organization.id, editor_fixture(ctx.organization), %{
          estimate_missing_times: false
        })

      stored = stored_stop_times(ctx.organization.id, ctx.version.id)

      assert {:ok, %Result{}} = validate(ctx)

      assert zip_trip_times(zip_copy) == [
               {"S1", "08:00:00"},
               {"S2", ""},
               {"S3", ""},
               {"S4", ""},
               {"S5", "08:10:00"}
             ]

      assert stored_stop_times(ctx.organization.id, ctx.version.id) == stored
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp fake_cli(mode, opts \\ []) do
    Keyword.merge([java_path: @fake_java, validator_path: mode], opts)
  end

  defp validate(ctx) do
    Validator.validate(ctx.organization.id, ctx.version.id, validation_run_id: ctx.run.id)
  end

  defp recorded_pid(dir), do: dir |> Path.join("output/fake.pid") |> File.read!() |> String.trim()

  defp os_process_alive?(pid) do
    {_output, status} = System.cmd("/bin/sh", ["-c", "kill -0 " <> pid], stderr_to_stdout: true)
    status == 0
  end

  # What the fake prints in big_output mode: 25,600 lines of eight bytes.
  defp fake_big_output do
    Enum.map_join(0..25_599, fn line ->
      String.pad_leading(Integer.to_string(line), 7, "0") <> "\n"
    end)
  end

  defp write_sparse!(path, size) do
    File.open!(path, [:write, :binary], fn file ->
      {:ok, _position} = :file.position(file, size - 1)
      :ok = IO.binwrite(file, <<0>>)
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp unique, do: System.unique_integer([:positive])

  defp actor, do: %{id: Ecto.UUID.generate(), email: "validator-exporter@example.com"}

  defp put_env(key, value) do
    previous = Application.fetch_env(:gtfs_planner, key)
    Application.put_env(:gtfs_planner, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:gtfs_planner, key, old)
        :error -> Application.delete_env(:gtfs_planner, key)
      end
    end)
  end

  # One trip whose middle times are blank: anchors 08:00 and 08:10 over stored
  # distances 0/200/400/2400/3000, so distance shares are 40/80/480 seconds and
  # even shares are 150 seconds each.
  defp seed_fillable_trip(organization_id, version_id) do
    for index <- 1..5 do
      stop_fixture(organization_id, version_id, stop_id: "S#{index}")
    end

    route_fixture(organization_id, version_id, route_id: "R1")
    trip_fixture(organization_id, version_id, "R1", %{trip_id: "T1"})

    distances = ["0", "200", "400", "2400", "3000"]

    for sequence <- 1..5 do
      stop_time_fixture(organization_id, version_id, "T1", "S#{sequence}", %{
        stop_sequence: sequence,
        arrival_time: anchor_time(sequence, "08:00:00", "08:10:00"),
        departure_time: anchor_time(sequence, "08:00:00", "08:10:00"),
        timepoint: if(sequence in [1, 5], do: 1, else: nil),
        shape_dist_traveled: Decimal.new(Enum.at(distances, sequence - 1))
      })
    end
  end

  defp anchor_time(1, first, _last), do: first
  defp anchor_time(5, _first, last), do: last
  defp anchor_time(_sequence, _first, _last), do: nil

  defp stored_stop_times(organization_id, version_id) do
    from(s in StopTime,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id,
      order_by: [asc: s.trip_id, asc: s.stop_sequence],
      select: {s.stop_sequence, s.arrival_time, s.departure_time, s.timepoint}
    )
    |> Repo.all()
  end

  # {stop_id, arrival_time} for trip T1, in stop order, read from the ZIP the
  # fake validator was given.
  defp zip_trip_times(zip_path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])

    {_name, content} =
      Enum.find(entries, fn {name, _content} -> List.to_string(name) == "stop_times.txt" end)

    [header | lines] = content |> to_string() |> String.split("\n", trim: true)
    columns = String.split(header, ",")

    lines
    |> Enum.map(fn line -> columns |> Enum.zip(String.split(line, ",")) |> Map.new() end)
    |> Enum.filter(&(&1["trip_id"] == "T1"))
    |> Enum.sort_by(&String.to_integer(&1["stop_sequence"]))
    |> Enum.map(&{&1["stop_id"], &1["arrival_time"]})
  end
end
