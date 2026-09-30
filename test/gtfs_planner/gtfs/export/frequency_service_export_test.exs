defmodule GtfsPlanner.Gtfs.Export.FrequencyServiceExportTest do
  @moduledoc """
  Judges the exported `frequencies.txt` of a version whose frequency service the
  trip-change engine created (EV-19, CL-16; AC-25).

  The first describe applies one `:add_frequency` command through the real
  production entry point `GtfsPlanner.Gtfs.apply_trip_change/4` — two touching
  windows, 06:00–07:00 every ten minutes and 07:00–08:00 every fifteen, with
  `exact_times` 1 — exports the version with the export entry point
  `GtfsPlanner.Gtfs.Export.export_to_zip/3`, and asserts the literal
  `frequencies.txt` rows. Every expected value is hand-derived from AC-25, R8 and
  the GTFS reference; nothing computes an expectation with the code under test.

  The second describe is the validator gate. It runs the same export through
  `GtfsPlanner.GtfsValidatorCli` (the tracked MobilityData 8.0.1 CLI, no network)
  and asserts the report carries no frequency-related notice of any severity, so
  an overlapping window, an end that is not after its start, a malformed
  `frequencies.txt` field or a dangling `trip_id` is rejected here (FH-42). It
  then inserts one deliberately overlapping window with `frequency_fixture/4` and
  requires the validator's own `overlapping_frequency` ERROR, so the clean run's
  silence is the validator's judgment of this file and not of a validator that
  never read it. Both raw validator reports are copied to the
  `.specs/18-advanced-trip-editing/evidence/validator/` folder of the repository
  the test runs in; the clean report is EV-19's artifact.

  The module writes the ZIPs and the validator reports to a temporary directory
  removed after the test and makes no network calls (`--skip_validator_update`).
  It shells out to the configured JDK and the tracked jar, so only the validator
  describe carries `:validator_cli`, which `test/test_helper.exs` excludes from
  the default suite; branch review runs the prepared command explicitly:

      MIX_ENV=test MIX_TEST_PARTITION=_s18 ELIXIR_ERL_OPTIONS="+S 4" mix test \
        test/gtfs_planner/gtfs/export/frequency_service_export_test.exs \
        --include validator_cli

  The prepared EV-19 deadline is 300 seconds for the validator describe, enforced
  by its `@moduletag timeout: 300_000`.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.ScheduleEditingFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.GtfsValidatorCli

  @validator_version "8.0.1"

  @frequencies_header "trip_id,start_time,end_time,headway_secs,exact_times"

  # A notice whose sample names `frequencies.txt` carries the file in `filename`
  # (row and range notices) or `childFilename` (foreign keys); the trip-level
  # overlap notice carries neither, so it is named here explicitly.
  @frequency_notice_codes ~w(
    overlapping_frequency
    start_and_end_range_equal
    start_and_end_range_out_of_order
  )

  # The two windows the engine must export: 06:00–07:00 every 10 minutes and
  # 07:00–08:00 every 15, touching at 07:00.
  @windows [
    %{start_secs: 21_600, end_secs: 25_200, headway_secs: 600},
    %{start_secs: 25_200, end_secs: 28_800, headway_secs: 900}
  ]

  @evidence_dir Path.expand(
                  "../../../../.specs/18-advanced-trip-editing/evidence/validator",
                  __DIR__
                )

  describe "exported frequencies.txt (AC-25)" do
    test "carries the two touching windows with exact_times 1" do
      {scope, created} = frequency_service_scope!()

      assert created.trip_id == "12-0-#{scope.service}-0600"

      tmp_dir = tmp_dir!()
      zip_path = export_zip!(tmp_dir, scope, "frequency-service")

      assert {header, rows} = frequencies_csv(zip_path)
      assert header == @frequencies_header

      assert rows == [
               "12-0-#{scope.service}-0600,06:00:00,07:00:00,600,1",
               "12-0-#{scope.service}-0600,07:00:00,08:00:00,900,1"
             ]
    end
  end

  describe "the validator's frequencies.txt judgment (AC-25, FH-42)" do
    @tag :validator_cli
    @moduletag timeout: 300_000

    test "reports no frequency notice, and overlapping_frequency for a known overlap" do
      {scope, created} = frequency_service_scope!()

      tmp_dir = tmp_dir!()
      clean_zip = export_zip!(tmp_dir, scope, "clean")

      # The clean report judges exactly these rows, so assert them before the
      # validator runs.
      assert {@frequencies_header, clean_rows} = frequencies_csv(clean_zip)

      assert clean_rows == [
               "12-0-#{scope.service}-0600,06:00:00,07:00:00,600,1",
               "12-0-#{scope.service}-0600,07:00:00,08:00:00,900,1"
             ]

      clean_report_dir = Path.join(tmp_dir, "clean-report")
      clean_report = GtfsValidatorCli.run!(clean_report_dir, clean_zip)

      assert clean_report["summary"]["validatorVersion"] == @validator_version

      print_observation("clean", clean_report)
      copy_report!(clean_report_dir, Path.join(@evidence_dir, "report.json"))

      assert frequency_notices(clean_report) == [],
             "the exported frequency service carries a validator frequency notice: " <>
               inspect(Enum.map(frequency_notices(clean_report), & &1["code"]))

      # Negative control: one window overlapping the engine's 06:00–07:00 window,
      # written around the engine. The validator must report its own
      # overlapping_frequency ERROR, so the clean run above proves this file was
      # read, not ignored.
      frequency_fixture(scope.organization.id, scope.version.id, created.trip_id, %{
        start_time: "06:30:00",
        end_time: "07:30:00",
        headway_secs: 600,
        exact_times: 1
      })

      overlap_zip = export_zip!(tmp_dir, scope, "overlap")

      assert {@frequencies_header, overlap_rows} = frequencies_csv(overlap_zip)
      assert length(overlap_rows) == 3

      overlap_report_dir = Path.join(tmp_dir, "overlap-report")
      overlap_report = GtfsValidatorCli.run!(overlap_report_dir, overlap_zip)

      print_observation("overlap", overlap_report)

      copy_report!(
        overlap_report_dir,
        Path.join(@evidence_dir, "overlapping-control-report.json")
      )

      notice =
        Enum.find(
          GtfsValidatorCli.notices(overlap_report),
          &(&1["code"] == "overlapping_frequency")
        )

      assert notice,
             "the validator did not report overlapping_frequency for a known overlap: " <>
               inspect(Enum.map(frequency_notices(overlap_report), & &1["code"]))

      assert GtfsValidatorCli.severity(notice) == "ERROR"

      assert Enum.any?(notice["sampleNotices"], fn sample ->
               sample["tripId"] == created.trip_id
             end)
    end
  end

  # One version with new frequency service: the editing scope's pattern and
  # timing, the agency and the three stops the exported stop_times.txt names, and
  # one `:add_frequency` command applied through the production engine. Returns
  # the scope and the created trip's persisted row.
  defp frequency_service_scope! do
    scope = editing_scope!("12", %{timing_headsign: "Downtown"})

    agency_fixture(scope.organization.id, scope.version.id, %{
      agency_id: "AG1",
      agency_name: "Metro Transit"
    })

    for {stop_id, stop_name} <- [
          {"A", "First Stop"},
          {"B", "Market Square"},
          {"C", "Valley College"}
        ] do
      stop_fixture(scope.organization.id, scope.version.id, %{
        stop_id: stop_id,
        stop_name: stop_name
      })
    end

    command =
      {:add_frequency,
       %{
         pattern_id: scope.bundle.pattern.id,
         timed_pattern_id: scope.bundle.timing.id,
         service_id: scope.service,
         windows: @windows,
         exact_times: 1
       }}

    assert {:ok, result} = Gtfs.apply_trip_change("12", command, :none, scope.audit)
    assert [created_id] = result.created_trip_ids

    {scope, Repo.get!(Trip, created_id)}
  end

  defp tmp_dir! do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "frequency_service_export_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    tmp_dir
  end

  defp export_zip!(tmp_dir, scope, name) do
    assert {:ok, zip_binary} =
             Export.export_to_zip(scope.organization.id, scope.version.id, :full)

    path = Path.join(tmp_dir, "#{name}.zip")
    File.write!(path, zip_binary)
    path
  end

  # Reads `frequencies.txt` out of an exported ZIP and returns its header line and
  # its data rows sorted, so the comparison against the literal expectations does
  # not depend on row order.
  defp frequencies_csv(zip_path) do
    [header | rows] =
      zip_path |> zip_entry!("frequencies.txt") |> String.split("\n", trim: true)

    {header, Enum.sort(rows)}
  end

  defp zip_entry!(zip_path, entry_name) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])

    case Enum.find(entries, fn {name, _content} -> List.to_string(name) == entry_name end) do
      {_name, content} -> content
      nil -> flunk("the export has no #{entry_name}: #{inspect(zip_entries(zip_path))}")
    end
  end

  defp zip_entries(zip_path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])
    Enum.map(entries, fn {name, _content} -> List.to_string(name) end)
  end

  # The 8.0.1 report gives every notice code one entry with "code", "severity",
  # "totalNotices" and "sampleNotices"; a file-scoped notice carries "filename"
  # and a foreign-key violation "childFilename".
  defp frequency_notices(report) do
    report
    |> GtfsValidatorCli.notices()
    |> Enum.filter(&frequency_notice?/1)
  end

  defp frequency_notice?(notice) do
    notice["code"] in @frequency_notice_codes or "frequencies.txt" in sample_files(notice)
  end

  defp sample_files(notice) do
    notice
    |> Map.get("sampleNotices", [])
    |> Enum.flat_map(&[&1["filename"], &1["childFilename"]])
    |> Enum.reject(&is_nil/1)
  end

  defp print_observation(label, report) do
    codes =
      Enum.map(
        GtfsValidatorCli.notices(report),
        &{&1["code"], GtfsValidatorCli.severity(&1), &1["totalNotices"]}
      )

    IO.puts("EV-19 #{label} validator notices: #{inspect(codes)}")
    IO.puts("EV-19 #{label} frequency notices: #{length(frequency_notices(report))}")
  end

  # The validator's own report.json bytes are EV-19's artifact; the CLI wrote them
  # under `report_dir`, which the test removes on exit.
  defp copy_report!(report_dir, destination) do
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(Path.join(report_dir, "report.json"), destination)
    IO.puts("EV-19 validator report copied to #{destination}")
  end
end
