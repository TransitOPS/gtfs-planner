defmodule GtfsPlanner.Gtfs.PathwayEvolutions.ExportTest do
  @moduledoc """
  Merge evidence (EV-6) for the closure export boundary: the full export
  publishes the supported interchange file, a full export re-imported into a
  second version preserves closure tuples and native calendars, the operations
  export inherits the same closure bytes beside its TODS files, and a committed
  calendar plus closure change from another session is read wholly before or
  wholly after one repeatable-read snapshot.

  Every expected CSV byte below is authored here from the acceptance cases, so
  no production function computes an expected value: the header, the `H:MM:SS`
  forms including the hour above 24, the fixed `is_closed` 1, the blank
  direction, the tuple order and the file lists are literals in this file. Rows
  are read back with the registered GTFS CSV parser, so the assertions observe
  the structure a real import would see.

  Ordinary cases and the race case drive the real `Export.export_to_zip/3` and
  `Export.build_zip/3` entrypoints against package-owned organizations on
  committing connections; each test deletes exactly its own organization rows in
  dependency order and asserts their absence. The race case additionally selects
  the production `Export.Snapshot.Repo` adapter in this process and restores the
  configured adapter in `on_exit`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.ConcurrencyHelpers
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.Snapshot
  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.Versions.GtfsVersion

  @closure_header "pathway_id,service_id,start_time,end_time,is_closed,direction\n"

  @race_handler {__MODULE__, :closure_export_race}
  @collect_timeout 15_000
  @pause_timeout 30_000

  describe "full export of a version with closures" do
    test "writes the six supported columns in tuple order with an above-24 hour window" do
      organization = new_org("closure-columns")
      on_exit(fn -> cleanup([organization.id]) end)

      version = new_version(organization)

      # Stored out of tuple order on purpose: the exported order is the identity
      # tuple, not the insertion order.
      seed_pathway(organization, version, "PE_B")
      seed_pathway(organization, version, "PE_A")

      seed_calendar(organization, version, "PE_WEEKDAY")

      seed_calendar_date(organization, version, "PE_WEEKEND", ~D[2027-03-14], 2)

      save_closure(organization, version, "PE_B", "PE_WEEKEND", "00:00", "00:30")
      save_closure(organization, version, "PE_A", "PE_WEEKDAY", "23:00", "26:00")
      save_closure(organization, version, "PE_A", "PE_WEEKDAY", "09:00", "15:00")

      assert {:ok, zip} =
               unboxed(fn -> Export.export_to_zip(organization.id, version.id, :full) end)

      files = unzip(zip)

      closures = entry(files, "pathway_evolutions.txt")

      assert closures ==
               @closure_header <>
                 "PE_A,PE_WEEKDAY,09:00:00,15:00:00,1,\n" <>
                 "PE_A,PE_WEEKDAY,23:00:00,26:00:00,1,\n" <>
                 "PE_B,PE_WEEKEND,00:00:00,00:30:00,1,\n"

      # The native calendars the closures reference travel with them, so the
      # exported feed still carries every referenced service identity.
      assert rows(files, "calendar.txt") == [
               %{
                 "service_id" => "PE_WEEKDAY",
                 "monday" => "1",
                 "tuesday" => "1",
                 "wednesday" => "1",
                 "thursday" => "1",
                 "friday" => "1",
                 "saturday" => "0",
                 "sunday" => "0",
                 "start_date" => "20260101",
                 "end_date" => "20261231"
               }
             ]

      assert [%{"service_id" => "PE_WEEKEND", "date" => "20270314", "exception_type" => "2"}] =
               rows(files, "calendar_dates.txt")

      # Application-only and internal columns stay out of the interchange file.
      refute closures =~ "APPLICATION-ONLY-NOTE"
      refute closures =~ "note"
      refute closures =~ "organization_id"
      refute closures =~ "gtfs_version_id"
      refute closures =~ "inserted_at"
      refute closures =~ version.id
      refute closures =~ organization.id

      # The static pathways profile never carries closures or their calendars.
      assert {:ok, pathways_zip} =
               unboxed(fn -> Export.export_to_zip(organization.id, version.id, :pathways) end)

      pathways_names = filenames(unzip(pathways_zip))

      refute "pathway_evolutions.txt" in pathways_names
      refute "calendar.txt" in pathways_names
      assert pathways_names == ["levels.txt", "pathways.txt", "stops.txt"]
    end

    test "a version without closures keeps its previous full-export file list" do
      organization = new_org("closure-empty")
      on_exit(fn -> cleanup([organization.id]) end)

      version = new_version(organization)
      seed_pathway(organization, version, "PE_EMPTY")
      seed_calendar(organization, version, "PE_NO_CLOSURE")

      assert {:ok, zip} =
               unboxed(fn -> Export.export_to_zip(organization.id, version.id, :full) end)

      files = unzip(zip)

      assert filenames(files) == ["calendar.txt", "levels.txt", "pathways.txt", "stops.txt"]

      # The full inventory lists the closure count and the pathways inventory
      # never lists the file at all.
      assert {"pathway_evolutions.txt", 0} in unboxed(fn ->
               Gtfs.get_file_inventory(organization.id, version.id, :full)
             end)

      refute Enum.any?(
               unboxed(fn -> Gtfs.get_file_inventory(organization.id, version.id, :pathways) end),
               fn {file, _count} -> file == "pathway_evolutions.txt" end
             )
    end

    test "a re-imported full export preserves closure tuples and native calendars" do
      organization = new_org("closure-round-trip")
      on_exit(fn -> cleanup([organization.id]) end)

      version_a = new_version(organization)

      seed_pathway(organization, version_a, "PE_ROUND")
      seed_calendar(organization, version_a, "PE_ROUND_WEEKDAY")

      save_closure(organization, version_a, "PE_ROUND", "PE_ROUND_WEEKDAY", "09:00", "15:00")
      save_closure(organization, version_a, "PE_ROUND", "PE_ROUND_WEEKDAY", "23:00", "26:00")

      assert {:ok, zip} =
               unboxed(fn -> Export.export_to_zip(organization.id, version_a.id, :full) end)

      version_b = new_version(organization)

      import_files =
        Enum.map(unzip(zip), fn {name, content} ->
          %{filename: to_string(name), content: content}
        end)

      assert {:ok, result} =
               unboxed(fn ->
                 StagedImport.import_files(organization.id, version_b.id, import_files)
               end)

      assert result.counts.pathway_evolutions == 2

      assert unboxed(fn -> closure_tuples(organization, version_b) end) == [
               {"PE_ROUND", "PE_ROUND_WEEKDAY", 32_400, 54_000},
               {"PE_ROUND", "PE_ROUND_WEEKDAY", 82_800, 93_600}
             ]

      # Every closure's service still resolves to a native calendar row in the
      # second version, which is what makes the round trip usable.
      assert unboxed(fn ->
               Repo.all(
                 from(c in Calendar,
                   where:
                     c.organization_id == ^organization.id and
                       c.gtfs_version_id == ^version_b.id and
                       c.service_id == "PE_ROUND_WEEKDAY",
                   select: {c.service_id, c.monday, c.start_date, c.end_date}
                 )
               )
             end) == [{"PE_ROUND_WEEKDAY", 1, ~D[2026-01-01], ~D[2026-12-31]}]

      # The interchange format carries no note, so a re-imported row stores none.
      assert unboxed(fn ->
               Repo.all(
                 from(e in PathwayEvolution,
                   where:
                     e.organization_id == ^organization.id and e.gtfs_version_id == ^version_b.id,
                   select: e.note,
                   order_by: e.start_time
                 )
               )
             end) == [nil, nil]
    end
  end

  describe "operations export" do
    test "carries the same closure bytes beside its TODS files, warnings and collision check" do
      organization = new_org("closure-operations")
      on_exit(fn -> cleanup([organization.id]) end)

      version = new_version(organization)

      seed_pathway(organization, version, "PE_OPS")
      seed_calendar(organization, version, "PE_OPS_WEEKDAY")
      save_closure(organization, version, "PE_OPS", "PE_OPS_WEEKDAY", "23:00", "26:00")

      unboxed(fn ->
        garage_fixture(organization.id, garage_id: "garage_ops", name: "Operations Depot")
        vehicle_fixture(organization.id, vehicle_id: "vehicle_ops")
      end)

      assert {:ok, full_zip} =
               unboxed(fn -> Export.export_to_zip(organization.id, version.id, :full) end)

      assert {:ok, operations_zip, warnings} =
               unboxed(fn -> Export.build_zip(organization.id, version.id, :operations) end)

      # The version has no blocks, so the four movement supplements are omitted.
      assert Enum.map(warnings, & &1.file) == [
               "calendar_dates_supplement.txt",
               "routes_supplement.txt",
               "trips_supplement.txt",
               "stop_times_supplement.txt"
             ]

      assert Enum.all?(warnings, &(&1.code == "tods_file_omitted"))

      full = unzip(full_zip)
      operations = unzip(operations_zip)

      # Every full-export file, closures and calendars included, is byte-identical;
      # the operations export only adds the two TODS files.
      assert filenames(operations) -- filenames(full) == [
               "stops_supplement.txt",
               "vehicles.txt"
             ]

      for {filename, content} <- full do
        assert entry(operations, filename) == content,
               "#{filename} changed in the operations export"
      end

      assert entry(operations, "pathway_evolutions.txt") ==
               @closure_header <> "PE_OPS,PE_OPS_WEEKDAY,23:00:00,26:00:00,1,\n"

      assert entry(operations, "stops_supplement.txt") =~ "garage_ops"
      assert entry(operations, "vehicles.txt") =~ "vehicle_ops"

      # The garage/stop ID collision check still refuses to produce an archive.
      conflict_version = new_version(organization)
      unboxed(fn -> stop_fixture(organization.id, conflict_version.id, stop_id: "garage_ops") end)

      assert {:error, {:garage_stop_id_conflict, conflicts}} =
               unboxed(fn ->
                 Export.build_zip(organization.id, conflict_version.id, :operations)
               end)

      assert Enum.map(conflicts, & &1.garage_id) == ["garage_ops"]
    end

    test "an organization with no TODS rows reports every omission beside its closures" do
      organization = new_org("closure-operations-empty")
      on_exit(fn -> cleanup([organization.id]) end)

      version = new_version(organization)
      seed_pathway(organization, version, "PE_OPS_EMPTY")
      seed_calendar(organization, version, "PE_OPS_NONE")
      save_closure(organization, version, "PE_OPS_EMPTY", "PE_OPS_NONE", "09:00", "15:00")

      assert {:ok, zip, warnings} =
               unboxed(fn -> Export.build_zip(organization.id, version.id, :operations) end)

      assert filenames(unzip(zip)) == [
               "calendar.txt",
               "levels.txt",
               "pathway_evolutions.txt",
               "pathways.txt",
               "stops.txt"
             ]

      assert Enum.map(warnings, & &1.file) == [
               "calendar_dates_supplement.txt",
               "routes_supplement.txt",
               "trips_supplement.txt",
               "stop_times_supplement.txt",
               "stops_supplement.txt",
               "vehicles.txt"
             ]

      assert Enum.all?(warnings, &(&1.code == "tods_file_omitted"))
    end
  end

  describe "one repeatable-read snapshot" do
    test "a committed calendar and closure change is read wholly before or wholly after" do
      # The configured adapter is the sandbox no-op; the production adapter owns
      # its own repeatable-read transaction, so this case replaces it in this
      # process and restores the previous value when the test ends.
      assert Application.get_env(:gtfs_planner, :gtfs_export_snapshot) == Snapshot.Sandbox

      previous = Application.get_env(:gtfs_planner, :gtfs_export_snapshot)
      Application.put_env(:gtfs_planner, :gtfs_export_snapshot, Snapshot.Repo)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:gtfs_planner, :gtfs_export_snapshot)
        else
          Application.put_env(:gtfs_planner, :gtfs_export_snapshot, previous)
        end
      end)

      organization = new_org("closure-race")
      on_exit(fn -> cleanup([organization.id]) end)

      version =
        unboxed(fn ->
          version = gtfs_version_fixture(organization.id)
          seed_pathway(organization, version, "PE_RACE")
          seed_calendar(organization, version, "PE_RACE_WEEKDAY")
          save_closure(organization, version, "PE_RACE", "PE_RACE_WEEKDAY", "09:00", "15:00")
          version
        end)

      supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.RaceSupervisor})
      parent = self()

      exporter =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:exporter_ready, self()})

          receive do
            :start_export -> :ok
          end

          unboxed(fn ->
            %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:exporter_backend, self(), backend_pid})
            Export.export_to_zip(organization.id, version.id, :full)
          end)
        end)

      assert_receive {:exporter_ready, exporter_pid}, @collect_timeout
      assert exporter_pid == exporter.pid

      # The exporter pauses on its first read of the closure rows: after the
      # calendar files are written and before the closure file is. The pause is
      # a rendezvous, not a sleep.
      pause_on_closure_read(parent, exporter_pid)

      send(exporter_pid, :start_export)
      assert_receive {:exporter_backend, ^exporter_pid, exporter_backend}, @collect_timeout
      assert_receive {:export_paused, ^exporter_pid}, @collect_timeout

      writer_backend =
        unboxed(fn ->
          %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          backend_pid
        end)

      assert writer_backend != exporter_backend

      assert {:ok, _} =
               unboxed(fn -> commit_calendar_and_closure_change(organization, version) end)

      send(exporter_pid, :resume_export)
      assert {:ok, interleaved_zip} = Task.await(exporter, @collect_timeout)

      before_change = %{calendar_end: "20261231", closure_start: "09:00:00"}
      after_change = %{calendar_end: "20270131", closure_start: "12:00:00"}

      interleaved = snapshot_of(unzip(interleaved_zip))

      assert interleaved in [before_change, after_change],
             "export mixed pre-change and post-change revisions: #{inspect(interleaved)}"

      assert interleaved == before_change

      assert {:ok, after_zip} =
               unboxed(fn -> Export.export_to_zip(organization.id, version.id, :full) end)

      assert snapshot_of(unzip(after_zip)) == after_change
    end
  end

  # -- fixtures --------------------------------------------------------------

  # One entrance-to-platform pathway. The closure's pathway reference is a
  # composite foreign key, so the pathway has to exist before the closure.
  defp seed_pathway(organization, version, pathway_id) do
    unboxed(fn -> seed_pathway_rows(organization, version, pathway_id) end)
  end

  defp seed_pathway_rows(organization, version, pathway_id) do
    level_fixture(organization.id, version.id, %{level_id: "PE_L_#{pathway_id}", level_index: 0.0})

    from_stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "PE_FROM_#{pathway_id}",
        location_type: 2
      })

    to_stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "PE_TO_#{pathway_id}",
        location_type: 0
      })

    pathway_fixture(organization.id, version.id, from_stop.stop_id, to_stop.stop_id, %{
      pathway_id: pathway_id,
      pathway_mode: 1
    })
  end

  defp save_closure(organization, version, pathway_id, service_id, start_time, end_time) do
    unboxed(fn ->
      save_closure_row(organization, version, pathway_id, service_id, start_time, end_time)
    end)
  end

  defp save_closure_row(organization, version, pathway_id, service_id, start_time, end_time) do
    %PathwayEvolution{
      organization_id: organization.id,
      gtfs_version_id: version.id
    }
    |> PathwayEvolution.changeset(%{
      pathway_id: pathway_id,
      service_id: service_id,
      start_time: start_time,
      end_time: end_time,
      note: "APPLICATION-ONLY-NOTE"
    })
    |> Repo.insert!()
  end

  defp seed_calendar(organization, version, service_id) do
    unboxed(fn -> calendar_fixture(organization.id, version.id, %{service_id: service_id}) end)
  end

  defp seed_calendar_date(organization, version, service_id, date, exception_type) do
    unboxed(fn ->
      calendar_date_fixture(organization.id, version.id, %{
        service_id: service_id,
        date: date,
        exception_type: exception_type
      })
    end)
  end

  # One committed transaction that moves both the native calendar and the
  # closure, so a reader that mixed revisions would show one of each.
  defp commit_calendar_and_closure_change(organization, version) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(c in Calendar,
          where:
            c.organization_id == ^organization.id and c.gtfs_version_id == ^version.id and
              c.service_id == "PE_RACE_WEEKDAY"
        ),
        set: [end_date: ~D[2027-01-31]]
      )

      Repo.update_all(
        from(e in PathwayEvolution,
          where:
            e.organization_id == ^organization.id and e.gtfs_version_id == ^version.id and
              e.pathway_id == "PE_RACE"
        ),
        set: [start_time: 43_200, end_time: 45_000]
      )
    end)
  end

  # -- snapshot adapter plumbing --------------------------------------------

  defp pause_on_closure_read(parent, exporter_pid) do
    :telemetry.attach(
      @race_handler,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, exporter} ->
        if self() == exporter and
             String.contains?(to_string(metadata[:query]), ~s(FROM "pathway_evolutions")) do
          :telemetry.detach(@race_handler)
          send(owner, {:export_paused, self()})

          receive do
            :resume_export -> :ok
          after
            @pause_timeout -> :ok
          end
        end
      end,
      {parent, exporter_pid}
    )

    on_exit(fn -> :telemetry.detach(@race_handler) end)
  end

  defp snapshot_of(files) do
    calendar_row = rows(files, "calendar.txt") |> hd()
    closure_row = rows(files, "pathway_evolutions.txt") |> hd()

    %{calendar_end: calendar_row["end_date"], closure_start: closure_row["start_time"]}
  end

  # -- helpers ---------------------------------------------------------------

  defp new_org(prefix) do
    unboxed(fn ->
      organization_fixture(%{alias: "#{prefix}-#{System.unique_integer([:positive])}"})
    end)
  end

  defp new_version(organization), do: unboxed(fn -> gtfs_version_fixture(organization.id) end)

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Entry names arrive as charlists, so they are normalized to binaries once here.
  defp unzip(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    Enum.map(entries, fn {name, content} -> {to_string(name), content} end)
  end

  # The archive lists its entries in creation order, so comparisons sort by name.
  defp filenames(files) do
    files |> Enum.map(fn {name, _content} -> to_string(name) end) |> Enum.sort()
  end

  defp entry(files, filename) do
    case Enum.find(files, fn {name, _content} -> to_string(name) == filename end) do
      nil -> flunk("expected #{filename} in the export; got #{inspect(filenames(files))}")
      {_name, content} -> to_string(content)
    end
  end

  defp rows(files, filename) do
    {:ok, parsed} = CsvParser.stream(filename, entry(files, filename))

    Enum.map(parsed.events, fn
      {:ok, _row_number, row_map} -> row_map
      {:error, error} -> flunk("#{filename} holds a row the parser rejects: #{inspect(error)}")
    end)
  end

  defp closure_tuples(organization, version) do
    Repo.all(
      from(e in PathwayEvolution,
        where: e.organization_id == ^organization.id and e.gtfs_version_id == ^version.id,
        select: {e.pathway_id, e.service_id, e.start_time, e.end_time},
        order_by: [asc: e.pathway_id, asc: e.service_id, asc: e.start_time, asc: e.end_time]
      )
    )
  end

  # These cases commit, so this package's own rows are deleted explicitly in
  # dependency order. Only the given organizations are touched, and their
  # absence is asserted afterwards.
  defp cleanup(organization_ids) do
    unboxed(fn ->
      ConcurrencyHelpers.delete_committed_scope!(organization_ids)

      refute Repo.exists?(
               from(e in PathwayEvolution, where: e.organization_id in ^organization_ids)
             )

      refute Repo.exists?(from(p in Pathway, where: p.organization_id in ^organization_ids))
      refute Repo.exists?(from(s in Stop, where: s.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end
end
