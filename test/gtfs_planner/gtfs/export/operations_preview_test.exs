defmodule GtfsPlanner.Gtfs.Export.OperationsPreviewTest do
  @moduledoc """
  R7: `Export.operations_preview/2` derives the operations export's file counts,
  runs and trips from the same structures the build writes, so the preview and
  the `:operations_only` ZIP cannot disagree.

  The expected values come from the built ZIP's own bytes, never from the
  preview: a preview that is wrong about a file, a warning or a run count is a
  mismatch against what the build actually produced.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Operations.Tods

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.RunsFixtures

  describe "operations_preview/2" do
    test "an uncut day type has nothing to reconcile" do
      world = runs_version_fixture()

      {:ok, preview} = Export.operations_preview(world.organization.id, world.version.id)

      assert preview.trips_total == 0
      assert preview.trips_in_run == 0
      refute Enum.any?(preview.warnings, &(&1.code == "tods_runs_uncovered"))
    end

    test "uncovered trips reconcile with the preview totals" do
      world = partial_coverage(runs_version_fixture())

      {:ok, preview} = Export.operations_preview(world.organization.id, world.version.id)

      assert preview.trips_in_run > 0
      assert preview.trips_total - preview.trips_in_run > 0
      assert Enum.any?(preview.warnings, &(&1.code == "tods_runs_uncovered"))

      assert preview.trips_total - preview.trips_in_run == uncovered_trip_total(preview.warnings)
    end

    test "every TODS file count matches an operations-only build" do
      world = cut_day_runs(runs_version_fixture())

      {:ok, preview} = Export.operations_preview(world.organization.id, world.version.id)

      {:ok, zip, _warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations_only)

      entries = zip_entries(zip)

      assert Enum.map(preview.files, &elem(&1, 0)) == tods_filenames()

      for {filename, count} <- preview.files do
        assert count == data_row_count(entries[filename]),
               "#{filename} preview count #{count} disagrees with the built ZIP"
      end

      assert Enum.any?(preview.files, fn {_filename, count} -> count > 0 end)
    end

    test "warnings equal the operations-only build's" do
      world = cut_day_runs(runs_version_fixture())

      {:ok, preview} = Export.operations_preview(world.organization.id, world.version.id)

      {:ok, _zip, build_warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations_only)

      assert preview.warnings == build_warnings
      assert preview.warnings != []
    end

    test "runs equals the distinct runs in the built run_events" do
      world = cut_day_runs(runs_version_fixture())

      {:ok, preview} = Export.operations_preview(world.organization.id, world.version.id)

      {:ok, zip, _warnings} =
        Export.build_zip(world.organization.id, world.version.id, :operations_only)

      entries = zip_entries(zip)

      built_runs =
        entries
        |> Map.fetch!("run_events.txt")
        |> run_ids_in()
        |> Enum.uniq()
        |> length()

      assert preview.runs == built_runs
      assert preview.runs > 0
    end
  end

  # Cuts runs for the day type through the domain's own suggest-and-apply path,
  # so the preview and the build read the runs a planner would have cut.
  defp cut_day_runs(world) do
    {:ok, plan} =
      Gtfs.suggest_runs(world.organization.id, world.version.id, world.day_type_key, :replace_all)

    {:ok, _result} = Gtfs.apply_run_plan(world.audit, plan)

    world
  end

  # Fully cuts the day, then removes one block's trips from their run so that
  # block's work is uncovered while the day type keeps its other runs.
  defp partial_coverage(world) do
    world = cut_day_runs(world)
    block_id = hd(Map.keys(world.blocks))
    trip = hd(world.blocks[block_id])

    Repo.delete_all(
      from tr in TripRun,
        where:
          tr.organization_id == ^world.organization.id and
            tr.gtfs_version_id == ^world.version.id and tr.trip_id == ^trip.id
    )

    world
  end

  defp tods_filenames do
    [
      Tods.stops_supplement_spec(),
      Tods.vehicles_spec(),
      Tods.calendar_dates_supplement_spec(),
      Tods.routes_supplement_spec(),
      Tods.trips_supplement_spec(),
      Tods.stop_times_supplement_spec(),
      Tods.run_events_spec(),
      Tods.employee_run_dates_spec()
    ]
    |> Enum.map(& &1.filename)
  end

  defp zip_entries(zip_binary) do
    {:ok, files} = :zip.unzip(zip_binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  defp data_row_count(nil), do: 0

  defp data_row_count(content) do
    [_header | lines] = content |> String.trim_trailing("\n") |> String.split("\n")
    length(lines)
  end

  defp run_ids_in(content) do
    [header | lines] = content |> String.trim_trailing("\n") |> String.split("\n")
    index = header |> String.split(",") |> Enum.find_index(&(&1 == "run_id"))

    Enum.map(lines, fn line -> line |> String.split(",") |> Enum.at(index) end)
  end

  defp uncovered_trip_total(warnings) do
    warnings
    |> Enum.filter(&(&1.code == "tods_runs_uncovered"))
    |> Enum.map(fn warning ->
      [_, count] = Regex.run(~r/^(\d+) trips are not in a run/, warning.detail)
      String.to_integer(count)
    end)
    |> Enum.sum()
  end
end
