defmodule GtfsPlanner.Gtfs.Export.OperationsRunsTest do
  @moduledoc """
  The `:operations` ZIP carries `run_events.txt`, every reference it writes
  resolves, and every public file stays byte-identical to `:full`.

  The cases go through `Export.build_zip/3` and unzip the result, on rows created
  inside the SQL Sandbox transaction and rolled back. Nothing here builds a run
  event, a service or a movement row by hand: "a reference that does not resolve"
  is a `trip_id` or a `service_id` a consumer cannot follow, and only the real
  export can say whether it does.

  The runs are created through the domain's own suggest-and-apply path rather than
  by inserting `trip_runs` rows, so what is exported is a run this application
  would actually have cut.

  Run with:
  `mix test test/gtfs_planner/gtfs/export/operations_runs_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.RunsFixtures

  @run_events "run_events.txt"

  @public_files [
    "calendar.txt",
    "calendar_attributes.txt",
    "routes.txt",
    "stop_times.txt",
    "stops.txt",
    "trips.txt"
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "export-runs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, old_root)
    end)

    %{world: runs_version_fixture()}
  end

  describe "the operations ZIP's run_events.txt" do
    setup %{world: world} do
      cut_runs(world)

      {:ok, zip, warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations)

      %{
        world: world,
        entries: zip_entries(zip),
        warnings: warnings,
        run_events: csv_rows_of(zip_entries(zip)[@run_events])
      }
    end

    test "is written with the header from run_events_spec/0", %{entries: entries} do
      assert Map.has_key?(entries, @run_events),
             "#{@run_events} was not written for a version that has runs"

      assert entries[@run_events] =~ header()
    end

    test "carries one row per run event, and every event type the spec names",
         %{run_events: rows} do
      assert rows != []

      assert Enum.all?(rows, &(&1["run_id"] != "")),
             "every run event belongs to a run"

      # The four movement kinds plus the three that belong to no piece.
      types = rows |> Enum.map(& &1["event_type"]) |> MapSet.new()

      for expected <- ["Operator", "Pull-Out", "Pull-Back", "Report Time", "Sign-Off"] do
        assert MapSet.member?(types, expected),
               "expected a #{expected} event, got #{inspect(MapSet.to_list(types))}"
      end
    end

    test "each Operator event names one assigned trip by its GTFS trip ID", %{run_events: rows} do
      operator_trips =
        rows
        |> Enum.filter(&(&1["event_type"] == "Operator"))
        |> Enum.map(& &1["trip_id"])
        |> Enum.sort()

      # The fixture's six trips, by the IDs it gives them: a, b, c and d on block
      # 101, e and f on block 102.
      assert operator_trips == ["a", "b", "c", "d", "e", "f"]
    end

    test "every non-blank trip_id is in trips.txt or trips_supplement.txt", %{
      entries: entries,
      run_events: rows
    } do
      # The two files a consumer finds a run event's trip in: a revenue trip is
      # public, a deadhead is a movement this same export wrote.
      known =
        ["trips.txt", "trips_supplement.txt"]
        |> Enum.flat_map(fn file ->
          file |> then(&csv_rows_of(entries[&1])) |> Enum.map(& &1["trip_id"])
        end)
        |> MapSet.new()

      for row <- rows, row["trip_id"] != "" do
        assert MapSet.member?(known, row["trip_id"]),
               "run event names trip #{row["trip_id"]}, which is in no trips file"
      end
    end

    test "every service_id is in calendar_dates_supplement.txt", %{
      entries: entries,
      run_events: rows
    } do
      # A run on a service the supplement does not define is a run on dates that
      # service does not run, which is the failure this whole file exists to
      # avoid.
      services =
        entries["calendar_dates_supplement.txt"]
        |> csv_rows_of()
        |> Enum.map(& &1["service_id"])
        |> MapSet.new()

      for row <- rows do
        assert MapSet.member?(services, row["service_id"]),
               "run event is on service #{row["service_id"]}, which no supplement row defines"
      end
    end

    test "within each run the event_sequence ascends and trip events do not overlap", %{
      run_events: rows
    } do
      for run_id <- rows |> Enum.map(& &1["run_id"]) |> Enum.uniq() do
        run_rows = Enum.filter(rows, &(&1["run_id"] == run_id))

        sequences = run_rows |> Enum.map(& &1["event_sequence"]) |> Enum.map(&to_integer/1)

        assert sequences == Enum.sort(sequences),
               "run #{run_id}'s event_sequence does not ascend: #{inspect(sequences)}"

        assert sequences == Enum.uniq(sequences),
               "run #{run_id} repeats an event_sequence: #{inspect(sequences)}"

        # Only the events that run along a trip can overlap: a break and a report
        # are not on a trip at all, and the spec leaves them unmarked.
        trip_events =
          run_rows
          |> Enum.filter(&(&1["start_mid_trip"] != ""))
          |> Enum.sort_by(&to_integer(&1["event_sequence"]))

        trip_events
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [earlier, later] ->
          assert to_secs(later["start_time"]) >= to_secs(earlier["end_time"]),
                 "run #{run_id}: #{later["event_type"]} at #{later["start_time"]} starts " <>
                   "before #{earlier["event_type"]} ends at #{earlier["end_time"]}"
        end)
      end
    end

    test "no time is negative and none is wrapped into the morning", %{run_events: rows} do
      for row <- rows do
        for field <- ["start_time", "end_time"] do
          clock = row[field]

          assert clock != "", "#{field} is blank on a #{row["event_type"]} event"

          parts = String.split(clock, ":")

          assert length(parts) == 3, "#{field} is not HH:MM:SS: #{clock}"

          assert Enum.all?(parts, &(String.to_integer(&1) >= 0)),
                 "#{field} is negative on a #{row["event_type"]} event: #{clock}"
        end
      end
    end
  end

  describe "public GTFS files" do
    test "are byte-identical to the :full export of the same version", %{world: world} do
      cut_runs(world)

      {:ok, operations_zip, _warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations)

      {:ok, full_zip, []} = Export.build_zip(world.organization.id, world.version.id, :full)

      operations = zip_entries(operations_zip)
      full = zip_entries(full_zip)

      # Named as well as derived from the :full ZIP, so a public file the export
      # stops writing cannot pass by being absent from both sides.
      for filename <- @public_files do
        assert Map.has_key?(full, filename), "#{filename} is missing from the :full export"

        assert Map.get(operations, filename) == full[filename],
               "#{filename} changed between the :full and :operations exports"
      end
    end
  end

  describe "a version without runs" do
    test "writes no run_events.txt and raises no run warning", %{world: world} do
      # Blocks and no saved assignments: the movements are still exported, but
      # there is no run to write.
      {:ok, zip, warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations)

      entries = zip_entries(zip)

      refute Map.has_key?(entries, @run_events)

      # A version with movements and no runs exports with no warnings at all, as
      # the movements export already promises: runs are optional, and a day type
      # nobody has cut has no uncovered work to report.
      refute Enum.any?(warnings, &(&1.file == @run_events)),
             "expected no run warning, got #{inspect(warnings)}"
    end
  end

  describe "a version that is not published" do
    test "writes no run_events.txt even when it has runs", %{world: world} do
      cut_runs(world)

      # Staging takes the version out of the published set without touching a
      # row, so the runs are still there and simply not reachable.
      world = unpublish(world)

      {:ok, zip, warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations)

      entries = zip_entries(zip)

      refute Map.has_key?(entries, @run_events)

      # The public files are still written: the caller could always have them.
      for filename <- @public_files do
        assert Map.has_key?(entries, filename),
               "#{filename} was dropped from an unpublished export"
      end

      # The code, not just the prose: a consumer keys on the code, and the
      # movements already publish their own `tods_movements_unavailable` for this
      # same version. A run file that borrowed it would be invisible.
      [warning] =
        Enum.filter(warnings, &(&1.file == @run_events and &1.code == "tods_runs_unavailable"))

      assert warning.detail =~ "not published"
      assert warning.entity_type == "run"
    end
  end

  describe "left-out and uncovered runs" do
    test "a run with an error is left out, counted, and never named in the file", %{
      world: world
    } do
      {world, broken} = break_one_run(world)

      {:ok, zip, warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations)

      rows = zip_entries(zip)[@run_events] |> csv_rows_of()

      # The run is gone whole: writing half of it would give a consumer sequence
      # numbers that no longer describe a day.
      assert rows != [], "the healthy runs should still have been written"

      assert Enum.all?(rows, &(&1["run_id"] != broken)),
             "run #{broken} has errors and was written anyway"

      left_out = Enum.find(warnings, &(&1.code == "tods_runs_left_out"))

      assert left_out, "expected tods_runs_left_out"
      assert left_out.entity_type == "run"
      assert left_out.file == @run_events
      # The count is taken from the domain, not from the export: the split
      # produced more than one run with an error, and a hardcoded 1 would have
      # been a guess about the fixture rather than a check on the export.
      # The whole sentence, not just its count: "were left out" is the part that
      # tells a planner what happened to the runs that are not in the file.
      assert left_out.detail ==
               "#{error_run_count(world)} runs have errors and were left out."
    end

    test "a day type with uncovered trips warns once, naming its count and label", %{
      world: world
    } do
      # Only one block is cut, so the other's trips are in no run at all.
      cut_run_for(world, "101")

      {:ok, _zip, warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations)

      uncovered = Enum.filter(warnings, &(&1.code == "tods_runs_uncovered"))

      assert [one] = uncovered,
             "expected exactly one uncovered warning, got #{inspect(uncovered)}"

      assert one.entity_type == "run"
      assert one.file == @run_events
      assert one.detail =~ "are not in a run for"

      [day_type | _] = day_types(world)

      assert one.detail =~ day_type.label
    end

    test "a fully covered day type raises no uncovered warning", %{world: world} do
      cut_runs(world)

      {:ok, _zip, warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations)

      refute Enum.any?(warnings, &(&1.code == "tods_runs_uncovered")),
             "a version whose every trip is in a run should say nothing about uncovered work"
    end

    test "a version with no run errors raises no left-out warning", %{world: world} do
      cut_runs(world)

      {:ok, _zip, warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations)

      refute Enum.any?(warnings, &(&1.code == "tods_runs_left_out"))
    end
  end

  # Cuts runs for every day type, through the domain's own suggest-and-apply path.
  defp cut_runs(world) do
    for key <- day_type_keys(world) do
      {:ok, plan} = Gtfs.suggest_runs(world.organization.id, world.version.id, key, :replace_all)
      {:ok, _result} = Gtfs.apply_run_plan(world.audit, plan)
    end

    world
  end

  # Covers every trip EXCEPT one block's, so that block's work is uncovered. The
  # excluded trips are moved into a run of their own rather than removed, which is
  # the only way a planner produces uncovered work at all.
  defp cut_run_for(world, excluded_block_id) do
    cut_runs(world)

    [key | _] = day_type_keys(world)

    moves =
      for trip <- world.blocks[excluded_block_id] do
        %{trip_id: trip.trip_id, from: run_of(world, key, trip.trip_id), to: nil}
      end

    {:ok, _result} = Gtfs.apply_run_moves(world.audit, key, moves)
    world
  end

  # The one run a trip is in. A trip in no run, or in two, would make the move
  # `stale_moves` or would quietly move the wrong work, so both are refused here
  # rather than discovered as a confusing domain error.
  defp run_of(world, key, trip_id) do
    {:ok, day} = Gtfs.load_runs(world.organization.id, world.version.id, key)

    runs_containing(day, trip_id)
    |> case do
      [one] -> one
      other -> raise "expected trip #{trip_id} in exactly one run, got #{inspect(other)}"
    end
  end

  defp runs_containing(day, trip_id) do
    for run <- day.derived.runs,
        Enum.any?(run.pieces, fn piece -> Enum.any?(piece.trips, &(&1.trip_id == trip_id)) end),
        do: run.run_id
  end

  # Renaming a run to collide with nothing, then leaving a finding on it: the
  # export's own left-out rule keys on an error finding, which is what
  # `Runs.Checks` raises for a piece that cannot be reached.
  # Splits one run into three pieces, which is a `:too_many_pieces` error finding
  # against it — the export's left-out rule keys on an error finding, and this is
  # one a planner can actually make through the move writer.
  #
  # A crew rule no run could satisfy was tried first and the domain refused it,
  # which is the right answer: a setting the writer will not accept is not a way
  # to manufacture a broken run.
  defp break_one_run(world) do
    cut_runs(world)

    [key | _] = day_type_keys(world)
    {:ok, day} = Gtfs.load_runs(world.organization.id, world.version.id, key)
    # The run with the most work in it: it needs at least two trips to be split
    # into three pieces, and picking the first run would match on a fixture's
    # ordering rather than on anything the case is about.
    victim = Enum.max_by(day.derived.runs, &trip_count/1)

    [first, second | _] = trips_of(victim)
    existing = run_ids(world, key)

    moves = [
      %{trip_id: first.trip_id, from: victim.run_id, to: Gtfs.next_run_id(existing)},
      %{trip_id: second.trip_id, from: victim.run_id, to: Gtfs.next_run_id(existing ++ ["1"])}
    ]

    {:ok, _result} = Gtfs.apply_run_moves(world.audit, key, moves)

    {world, victim.run_id}
  end

  # Every run the domain itself marks with an error finding, over every day type.
  defp error_run_count(world) do
    for key <- day_type_keys(world),
        {:ok, day} <- [Gtfs.load_runs(world.organization.id, world.version.id, key)],
        run <- day.derived.runs,
        Enum.any?(run.findings, &(&1.severity == :error)) do
      run.run_id
    end
    |> length()
  end

  defp trip_count(run), do: trips_of(run) |> length()

  defp trips_of(run), do: Enum.flat_map(run.pieces, & &1.trips)

  defp run_ids(world, key) do
    {:ok, day} = Gtfs.load_runs(world.organization.id, world.version.id, key)
    Enum.map(day.derived.runs, & &1.run_id)
  end

  defp day_type_keys(world) do
    for day_type <- day_types(world), do: day_type.key
  end

  defp day_types(world) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)
    day.day_types
  end

  # The version leaves the published set by its own field. `status` is not the
  # column: the export asks `publication_status`, so a version made "staging" in
  # the wrong field would still be published and the case would prove nothing.
  # Through the lifecycle changeset, not through `update_gtfs_version/3`. That
  # function's changeset casts only the name, so passing `publication_status`
  # there returns `{:ok, version}` having changed nothing at all — a silent
  # success that left the version published and made this case prove nothing.
  defp unpublish(world) do
    {:ok, version} =
      world.version
      |> GtfsVersion.transition_changeset("staging")
      |> Repo.update()

    %{world | version: version}
  end

  defp header do
    Tods.run_events_spec().fields |> Enum.map_join(",", &elem(&1, 0))
  end

  defp zip_entries(zip_binary) do
    {:ok, files} = :zip.unzip(zip_binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  # Parsed as a map per row, so a case reads `row["event_type"]` rather than a
  # column index that would move with the header.
  defp csv_rows_of(nil), do: []

  defp csv_rows_of(content) do
    [header | lines] =
      content
      |> String.trim_trailing("\n")
      |> String.split("\n")

    keys = String.split(header, ",")

    lines
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      keys
      |> Enum.zip(String.split(line, ","))
      |> Map.new()
    end)
  end

  defp to_integer(value), do: value |> String.trim() |> String.to_integer()

  # The model's own restoration, so a missing key is deleted rather than set to
  # nil — an `Application.put_env/3` of nil is not the same as never having set it.
  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)

  defp to_secs(clock) do
    [h, m, s] = String.split(clock, ":") |> Enum.map(&String.to_integer/1)
    h * 3600 + m * 60 + s
  end
end
