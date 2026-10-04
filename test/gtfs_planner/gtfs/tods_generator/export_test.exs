defmodule GtfsPlanner.Gtfs.TodsGenerator.ExportTest do
  @moduledoc """
  Step 10: a committed generation exports through the ordinary operations
  export-run/worker/download composition, and the ZIP agrees with the records the
  save persisted.

  The failures this file isolates are the generation-specific ones the export
  owner's own tests cannot see, because they never build a generation:

    * the runs, operators, roster lines and dates the save persisted are the ones
      the worker's ZIP carries — the run IDs of `run_events.txt` and the employee
      IDs of `employee_run_dates.txt` are read from the database, not supplied by a
      case;
    * a run whose sign-on falls before midnight is written on the `_prev` service a
      day earlier, and every `(service_id, date)` and `(service_id, run_id)` an
      assignment names resolves in the same ZIP;
    * the holiday Monday the version carries runs a day type no weekday base
      reaches, so no generated employee works it, the day type's own date is still
      known to the supplement, and the export warns that the date runs other
      service;
    * the garage the generation resolved is the one `stops_supplement.txt` writes;
    * the evidence override copies the exact downloaded bytes to a directory a
      caller names and, absent it, the same composition runs under the test's own
      temporary artifact root and cleans its build directory.

  Every case drives the real path: `TodsGeneratorFixtures.generated_operations_world_fixture/1`
  previews and saves through `Gtfs.apply_tods_generation/2`, `ExportRuns.create_pending/4`
  and `Runner.start_build/3` run the concrete `Export.Worker`, and the bytes are read
  through the scoped `ExportRuns.claim_download/4` the download controller uses.
  Assertions are literal facts read back from the database and from the ZIP.

  Emit the fixture ZIP with:

      TODS_GENERATOR_EVIDENCE_DIR=.specs/37-tods-generator/evidence \\
        mix test test/gtfs_planner/gtfs/tods_generator/export_test.exs \\
                 test/gtfs_planner_web/controllers/gtfs_export_download_controller_test.exs

  `TODS_GENERATOR_EVIDENCE_DIR` is a test-only destination; the application gains
  no environment variable or configuration key.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.TodsGeneratorFixtures

  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Repo

  @moduletag timeout: 120_000

  @actor %{id: "9f0e6b1a-3d2c-4f5e-8a7b-0c1d2e3f4a5b", email: "exporter@example.com"}

  @employee_run_dates "employee_run_dates.txt"
  @run_events "run_events.txt"
  @calendar_dates "calendar_dates_supplement.txt"
  @stops_supplement "stops_supplement.txt"

  @evidence_filename "generated-operations.zip"

  setup do
    root =
      Path.join(System.tmp_dir!(), "tods-generator-export-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, old_root)
    end)

    %{root: root}
  end

  describe "the operations ZIP of a generation" do
    setup %{root: root} do
      world = generated_operations_world_fixture()
      run = start_operations_export(world, @actor)
      bytes = download_operations_zip(world, run)

      %{world: world, run: run, root: root, bytes: bytes, entries: unzip(bytes)}
    end

    test "carries the persisted runs, employees and dates the save committed", %{
      world: world,
      run: run,
      bytes: bytes,
      entries: entries
    } do
      assert world.preview.save_available?
      assert world.receipt.created_ids["block_ids"] == ["103"]
      assert world.receipt.summary["operators"] > 0

      # The records the ZIP describes are the persisted ones, read back with an
      # ordinary query rather than carried over from the save's answer.
      generated_trip = Map.fetch!(world.trip_ids, "gen-a")
      assert Repo.get!(Trip, generated_trip).block_id == "103"
      assert Repo.get!(Trip, Map.fetch!(world.trip_ids, "a")).block_id == "101"

      stored_runs = stored_runs(world)
      receipt_run_ids = MapSet.new(world.receipt.created_ids["run_ids"])
      assert stored_runs != []
      assert Enum.all?(stored_runs, &MapSet.member?(receipt_run_ids, elem(&1, 2)))

      operators = Operations.list_operators(world.organization.id)
      employee_ids = Enum.map(operators, & &1.employee_id)
      expected_employee_ids = generated_employee_ids(world)

      assert Enum.sort(employee_ids) == Enum.sort(expected_employee_ids)

      assert Enum.sort(Enum.map(operators, & &1.id)) ==
               Enum.sort(world.receipt.created_ids["operator_ids"])

      assert length(line_rows(world)) == world.receipt.summary["lines"]

      # The worker published the bytes the claim served, and the run is ready.
      assert %Run{state: :ready, artifact_size_bytes: size} = Repo.get!(Run, run.id)
      assert size == byte_size(bytes)

      rows = rows(entries, @employee_run_dates)
      assert rows != []
      assert entries[@employee_run_dates] =~ header(Tods.employee_run_dates_spec())
      assert MapSet.new(rows, & &1["employee_id"]) == MapSet.new(expected_employee_ids)
      assert MapSet.subset?(MapSet.new(rows, & &1["run_id"]), receipt_run_ids)

      # Every generated run's events name a receipt run and the block that was
      # created, and the trip the save moved is the one on block "103".
      events = rows(entries, @run_events)
      generated_events = Enum.filter(events, &(&1["trip_id"] == "gen-a"))
      assert generated_events != []
      assert Enum.all?(generated_events, &MapSet.member?(receipt_run_ids, &1["run_id"]))
      assert Enum.all?(generated_events, &(&1["block_id"] == "103"))

      # The resolved garage is the one the supplement writes, by its public ID.
      garage_row =
        Enum.find(rows(entries, @stops_supplement), &(&1["stop_id"] == world.garage.garage_id))

      assert garage_row, "the resolved garage is not in stops_supplement.txt"
      assert garage_row["stop_name"] == world.garage.name
      assert garage_row["TODS_location_type"] == "garage"
    end

    test "dates a before-midnight sign-on one _prev service earlier and keeps every reference resolvable",
         %{world: world, run: run, entries: entries} do
      rows = rows(entries, @employee_run_dates)
      events = rows(entries, @run_events)

      # Run "1" is the run cut from the just-after-midnight trip, so every row of it
      # is on the day type's previous-day service and one date earlier than the date
      # that service's own calendar row lists.
      run_one = Enum.filter(rows, &(&1["run_id"] == "1"))
      assert run_one != [], "the fixture produced no run for its just-after-midnight trip"

      assert Enum.all?(run_one, &String.ends_with?(&1["service_id"], "_prev")),
             "a run signing on before midnight was dated on its own service"

      assert Enum.any?(events, fn event ->
               event["trip_id"] == "gen-a" and clock_secs(event["end_time"]) > 86_400
             end),
             "the before-midnight run's own events do not run past midnight"

      # The integrity a consumer follows: every named service-day and run exists in
      # the same ZIP's supplement and run list.
      calendar =
        MapSet.new(rows(entries, @calendar_dates), &{&1["service_id"], &1["date"]})

      run_pairs = MapSet.new(events, &{&1["service_id"], &1["run_id"]})

      for row <- rows do
        assert MapSet.member?(calendar, {row["service_id"], row["date"]}),
               "assignment #{row["service_id"]}/#{row["date"]} has no calendar row"

        assert MapSet.member?(run_pairs, {row["service_id"], row["run_id"]}),
               "assignment names run #{row["run_id"]} on #{row["service_id"]} with no event"
      end

      # The holiday Monday runs a day type of its own: the supplement knows its
      # date, no generated employee works it, and the export says so.
      holiday_date = compact_date(world.holiday_date)
      holiday_service = service_id(world.holiday_day_type)

      assert MapSet.member?(calendar, {holiday_service, holiday_date})

      refute MapSet.member?(MapSet.new(rows, &{&1["service_id"], &1["date"]}), {
               holiday_service,
               holiday_date
             })

      assert world.preview.coverage.other_service_dates == [world.holiday_date]
      assert other_service(run.warnings)["detail"] =~ Date.to_iso8601(world.holiday_date)
    end
  end

  describe "the fixture evidence override" do
    test "copies the exact downloaded ZIP into the named directory", %{root: root} do
      original = System.get_env("TODS_GENERATOR_EVIDENCE_DIR")

      dir =
        original ||
          Path.join(System.tmp_dir!(), "tods-evidence-#{System.unique_integer([:positive])}")

      System.put_env("TODS_GENERATOR_EVIDENCE_DIR", dir)

      on_exit(fn ->
        restore_evidence_env(original)
        if is_nil(original), do: File.rm_rf(dir)
      end)

      world = generated_operations_world_fixture()
      run = start_operations_export(world, @actor)
      bytes = download_operations_zip(world, run)

      path = emit_evidence_zip(bytes)

      assert path == Path.join(dir, @evidence_filename)
      assert File.read!(path) == bytes
      assert byte_size(bytes) > 0

      # The copy is the only thing the override changes: the run's own artifact
      # still lives under the scoped root and its build directory is gone.
      refute File.exists?(build_dir(root, world, run))
    end

    test "runs the same composition with its normal root and no evidence file when absent", %{
      root: root
    } do
      original = System.get_env("TODS_GENERATOR_EVIDENCE_DIR")
      System.delete_env("TODS_GENERATOR_EVIDENCE_DIR")

      on_exit(fn -> restore_evidence_env(original) end)

      world = generated_operations_world_fixture()
      run = start_operations_export(world, @actor)
      bytes = download_operations_zip(world, run)
      entries = unzip(bytes)

      # The same assertions hold without the override, and nothing is written.
      assert Repo.get!(Trip, Map.fetch!(world.trip_ids, "gen-a")).block_id == "103"
      assert rows(entries, @employee_run_dates) != []

      assert emit_evidence_zip(bytes) == nil

      refute File.exists?(build_dir(root, world, run))
    end
  end

  # --- fixtures and helpers --------------------------------------------------

  # Every employee ID the save's ordinal operators carry, derived from the request
  # token rather than read back from the operator rows.
  defp generated_employee_ids(world) do
    for ordinal <- 1..world.receipt.summary["operators"] do
      padded = ordinal |> Integer.to_string() |> String.pad_leading(3, "0")
      "DEMO-#{world.request_id}-#{padded}"
    end
  end

  defp stored_runs(world) do
    from(r in TripRun,
      select: {r.day_type_key, r.trip_id, r.run_id},
      order_by: [asc: r.day_type_key, asc: r.trip_id]
    )
    |> scoped(world)
    |> Repo.all()
  end

  defp line_rows(world) do
    from(l in RosterLine, select: {l.line_number, l.operator_id}, order_by: l.line_number)
    |> scoped(world)
    |> Repo.all()
  end

  defp scoped(query, world) do
    where(
      query,
      [r],
      field(r, :organization_id) == ^world.organization.id and
        field(r, :gtfs_version_id) == ^world.version.id
    )
  end

  # The warnings the worker persisted on the ready run, which is what a consumer
  # reads.
  defp other_service(warnings) do
    Enum.find(warnings, &(&1["code"] == "tods_assignments_other_service")) ||
      raise "expected a tods_assignments_other_service warning, got #{inspect(warnings)}"
  end

  # The evidence override: a test-only destination the caller names. Absent the
  # variable nothing is written and the normal scoped root is used unchanged.
  defp emit_evidence_zip(bytes) do
    case System.get_env("TODS_GENERATOR_EVIDENCE_DIR") do
      nil ->
        nil

      dir ->
        File.mkdir_p!(dir)
        path = Path.join(dir, @evidence_filename)
        File.write!(path, bytes)
        path
    end
  end

  defp unzip(bytes) do
    {:ok, files} = :zip.unzip(bytes, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  defp rows(entries, filename) do
    case Map.fetch(entries, filename) do
      {:error, _} -> []
      {:ok, content} -> csv_rows(content)
    end
  end

  defp csv_rows(content) do
    [header | lines] = content |> String.trim_trailing("\n") |> String.split("\n")
    keys = String.split(header, ",")

    lines
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line -> keys |> Enum.zip(String.split(line, ",")) |> Map.new() end)
  end

  defp clock_secs(clock) do
    [h, m, s] = clock |> String.split(":") |> Enum.map(&String.to_integer/1)
    h * 3600 + m * 60 + s
  end

  defp compact_date(date), do: date |> Date.to_iso8601() |> String.replace("-", "")

  # The service ID `TodsExport` reserves for a day type: its own key's SHA-256 at
  # the width identifiers take. Recomputed here so the holiday's service is a
  # literal fact rather than a value read back from the module under test.
  defp service_id(day_type_key) do
    "ops_dt_" <>
      (day_type_key
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower)
       |> String.slice(0, 6))
  end

  defp header(spec) do
    spec.fields |> Enum.map_join(",", &elem(&1, 0))
  end

  defp build_dir(root, world, run) do
    Path.join([
      root,
      "export-runs",
      world.organization.id,
      world.version.id,
      run.id,
      ".build"
    ])
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)

  defp restore_evidence_env(nil), do: System.delete_env("TODS_GENERATOR_EVIDENCE_DIR")
  defp restore_evidence_env(value), do: System.put_env("TODS_GENERATOR_EVIDENCE_DIR", value)
end
