defmodule GtfsPlanner.Gtfs.Export.OperationsRostersTest do
  @moduledoc """
  The `:operations` ZIP carries `employee_run_dates.txt`, every reference it
  writes resolves in that same ZIP, and a version nobody has rostered exports
  exactly what it exported before.

  The cases go through `Export.build_zip/3` and unzip the result, on rows created
  inside the SQL Sandbox transaction and rolled back. Nothing here builds a
  service ID, a date or a warning by hand: "the two files agree" is a claim about
  bytes a consumer follows, and only the real export can answer it (INV-14).

  The world is `RunsFixtures.runs_version_fixture/1` — a published version whose
  one calendar runs Monday to Friday — plus one block pulling out at 00:05, whose
  run signs on before midnight and so keeps the day type's own service with every
  clock read a day later. That is the case where `employee_run_dates.txt` and
  `run_events.txt` could disagree about a run's service day.

  On that world the cases add roster lines through the writers the Rosters page
  calls: two picked lines, one open line with no operator, and one whose run is
  renamed so its slot is stale. The other-service describe adds a dates-only
  "Holiday" service on Mondays with a trip of its own, which makes those Mondays
  run different service from the weekday base.

  Runs are cut once per world, through the domain's own suggest-and-apply path,
  and every case reads its run IDs from that one cut. Re-cutting would renumber
  the runs and quietly invalidate a slot written against them. Those IDs are read
  from the day type Monday's base week resolves to, because a run ID means nothing
  outside the day type it was cut in — once the holiday service exists, both day
  types derive a before-midnight run and only the base one may be named by a slot.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/export/operations_rosters_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Rosters
  alias GtfsPlanner.Gtfs.Rosters.BaseWeek
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Operations.Tods

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  @moduletag timeout: 120_000

  @employee_run_dates "employee_run_dates.txt"

  # The weekdays this version's single calendar runs, and the ones the cases put
  # a line on. Any two distinct weekdays work; these are only named once.
  @monday 1
  @tuesday 2
  @wednesday 3
  @friday 5

  # The Mondays the holiday service adds. Six of them, so the warning's "first
  # three ... and N more" branch is the one exercised.
  @holidays [
    ~D[2026-01-05],
    ~D[2026-02-02],
    ~D[2026-03-02],
    ~D[2026-04-06],
    ~D[2026-05-04],
    ~D[2026-06-01]
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "export-rosters-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, old_root)
    end)

    %{world: runs_version_fixture()}
  end

  describe "the operations ZIP's employee_run_dates.txt" do
    setup %{world: world} do
      %{world: world, early: early} = prepared(world)

      # Two picked lines: one on the run that signs on before midnight and one on
      # an ordinary daytime run, so the file holds both a shifted and an unshifted
      # row.
      line(world, @monday, early, operator(world, "E4101", "Aurelia Nowak", 7))
      daytime = daytime_runs(world) |> hd()
      line(world, @tuesday, daytime, operator(world, "E4108", "Bram Osei", 12))

      %{
        early: early,
        daytime: daytime,
        entries: zip(world).entries,
        rows: zip(world).entries |> Map.fetch!(@employee_run_dates) |> csv_rows_of(),
        warnings: zip(world).warnings
      }
    end

    test "is written with the header from employee_run_dates_spec/0 and no other column", %{
      entries: entries
    } do
      assert Map.has_key?(entries, @employee_run_dates),
             "#{@employee_run_dates} was not written for a version that has assigned lines"

      assert entries[@employee_run_dates] =~ header()
    end

    test "carries one row per assigned line, base-week date and slot", %{
      rows: rows,
      early: early,
      daytime: daytime
    } do
      assert rows != []

      assert Enum.all?(rows, &(&1["employee_id"] in ["E4101", "E4108"])),
             "a row names an operator other than the two who picked a line"

      assert Enum.all?(rows, &(&1["run_id"] in [early, daytime])),
             "a row names a run neither line works"
    end

    test "a run signing on before midnight keeps the day type's service and reaches past midnight",
         %{
           entries: entries,
           rows: rows,
           early: early
         } do
      # Read from the file rather than assumed: the fixture's early block is what
      # makes this case meaningful, and a fixture that stopped producing a
      # before-midnight run would otherwise pass it vacuously.
      assert before_midnight?(entries, early),
             "fixture run #{early} no longer signs on before midnight, so this case proves nothing"

      written = Enum.filter(rows, &(&1["run_id"] == early))

      assert written != [], "the run signing on before midnight produced no rows"

      assert [service] = written |> Enum.map(& &1["service_id"]) |> Enum.uniq(),
             "expected one service for the before-midnight run"

      # A run reaching past midnight shares the day type's own service day with its
      # trips; it is not moved to a previous-day service, because a consumer
      # requires the run's dates to be a subset of every trip it works.
      refute String.contains?(service, "_prev"),
             "#{service} is a previous-day service, which the run's trips do not share"

      # A shifted date is only right if the same ZIP's supplement lists that
      # service on it, which is the pair a consumer follows.
      listed =
        entries["calendar_dates_supplement.txt"]
        |> csv_rows_of()
        |> Enum.filter(&(&1["service_id"] == service))
        |> MapSet.new(& &1["date"])

      for row <- written do
        assert MapSet.member?(listed, row["date"]),
               "row is on #{row["date"]}, which no supplement row lists on " <> service
      end
    end

    test "every (service_id, date) resolves in the same ZIP's supplement", %{
      entries: entries,
      rows: rows
    } do
      # The failure this whole file exists to avoid: a row naming a service-day
      # pair the consumer cannot find, so it has no date to work.
      listed =
        entries["calendar_dates_supplement.txt"]
        |> csv_rows_of()
        |> MapSet.new(&{&1["service_id"], &1["date"]})

      for row <- rows do
        assert MapSet.member?(listed, {row["service_id"], row["date"]}),
               "row #{row["service_id"]}/#{row["date"]} is in no calendar_dates_supplement row"
      end
    end

    test "every (service_id, run_id) is in the same ZIP's run_events.txt", %{
      entries: entries,
      rows: rows
    } do
      # A row naming a run the export left out would assign an operator work
      # `run_events.txt` says does not happen.
      written =
        entries["run_events.txt"]
        |> csv_rows_of()
        |> MapSet.new(&{&1["service_id"], &1["run_id"]})

      for row <- rows do
        assert MapSet.member?(written, {row["service_id"], row["run_id"]}),
               "row names run #{row["run_id"]} on #{row["service_id"]}, " <>
                 "which run_events.txt does not carry"
      end
    end

    test "no exported file carries an operator's name or seniority number", %{entries: entries} do
      # AC-24. Synthetic fixture names, so a leak is unambiguous.
      for {filename, content} <- entries do
        refute String.contains?(content, "Aurelia Nowak"),
               "#{filename} carries an operator's display name"

        refute String.contains?(content, "Bram Osei"),
               "#{filename} carries an operator's display name"
      end
    end

    test "the planned-data note warns, and its text is the one the spec fixes", %{
      warnings: warnings
    } do
      assert planned(warnings).detail ==
               "Planned from the pick. Vacations, sick days and extraboard are not included."
    end

    test "an unassigned line and a stale slot warn in the singular", %{world: world} do
      # Two DISTINCT daytime runs. A run is on at most one line per weekday, so
      # the open line and the stale line each need their own: naming the same run
      # on two weekdays would leave two stale slots when it was renamed, and the
      # singular sentence this case asserts would then be the wrong one to expect.
      [open_run, stale_run] = daytime_runs(world) |> Enum.slice(1..2)

      # Added on top of the two picked lines the setup made, so this case's own
      # ZIP has an open line and a stale slot at the same time as its rows.
      line(world, @wednesday, open_run, nil)

      line(world, @friday, stale_run, operator(world, "E4109", "Wren Abara", 3))

      assert {:ok, _} = Gtfs.rename_run(world.audit, world.day_type_key, stale_run, "9")

      warnings = warnings(world)

      # The sentences themselves, at 1: the prepared text, verbatim. Each counts
      # one thing — the open line, the one slot whose stored run is gone — so the
      # fixture has to hold exactly one of each.
      assert unassigned(warnings).detail == "1 line has no operator."
      assert stale_warning(warnings).detail == "1 stale slot was skipped."

      for warning <- assignment_warnings(warnings) do
        assert warning.file == @employee_run_dates
        assert warning.entity_type == "roster_line"
      end
    end
  end

  describe "dates running other service" do
    setup %{world: world} do
      # A dates-only service on six Mondays with a trip of its own, so those
      # Mondays run different service from the weekday base and no Monday line
      # may produce a row for them.
      calendar_service_fixture(world.organization.id, world.version.id, %{
        service_id: "HOL",
        name: "Holiday",
        dates: @holidays
      })

      blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
        trip_id: "h1",
        service_id: "HOL",
        block_id: "901",
        first_stop: "BAY_A",
        last_stop: "BAY_B",
        first_departure: "06:00:00",
        last_arrival: "07:00:00"
      })

      %{world: world, early: early} = prepared(world)

      line(world, @monday, early, operator(world, "E4101", "Aurelia Nowak", 7))

      %{world: world}
    end

    test "warn with their count, the first three in date order, and the open run-days", %{
      world: world
    } do
      warning = other_service(warnings(world))

      assert warning.entity_type == "roster_line"
      assert warning.file == @employee_run_dates

      # Six dates, so "and 3 more" appears. The three named are the first three in
      # date order — which is not the order an unsorted `%Date{}` list gives, since
      # Erlang orders those structs by field (FH-17).
      assert warning.detail ==
               "6 dates run different service: 2026-01-05, 2026-02-02, 2026-03-02 and 3 more. " <>
                 "No assignments are exported for them; 36 run-days stay open."
    end

    test "produce no employee_run_dates row on those dates", %{world: world} do
      rows = zip(world).entries |> Map.fetch!(@employee_run_dates) |> csv_rows_of()
      dates = MapSet.new(rows, & &1["date"])

      for date <- @holidays do
        refute MapSet.member?(dates, compact_date(date)),
               "a date running other service produced an employee_run_dates row"
      end
    end
  end

  describe "a version with no roster lines" do
    setup %{world: world} do
      %{world: world, early: early} = prepared(world)

      # The ZIP as it stands before any line exists, which the later case
      # compares against after lines have been added.
      %{world: world, early: early, bare: zip(world)}
    end

    test "writes no employee_run_dates.txt", %{bare: bare} do
      refute Map.has_key?(bare.entries, @employee_run_dates),
             "a version nobody has rostered wrote a #{@employee_run_dates}"
    end

    test "raises no assignment warning", %{world: world} do
      assert [] == assignment_warnings(warnings(world)),
             "a version nobody has rostered owes the consumer no assignment warning"
    end

    test "every other file is byte-identical once the version has a line", %{
      world: world,
      early: early,
      bare: bare
    } do
      line(world, @monday, early, operator(world, "E4101", "Aurelia Nowak", 7))

      rostered = zip(world)

      assert Map.has_key?(rostered.entries, @employee_run_dates),
             "a version with an assigned line wrote no #{@employee_run_dates}"

      # Only the new file may differ. A rostering that changed a public GTFS file
      # or another TODS file would be a change a consumer cannot explain.
      assert Map.keys(rostered.entries) -- Map.keys(bare.entries) == [@employee_run_dates]

      for {filename, content} <- bare.entries do
        assert Map.get(rostered.entries, filename) == content,
               "#{filename} changed once the version had a roster line"
      end
    end
  end

  # ---- the world -------------------------------------------------------

  # The fixture's own blocks all start after 05:00, so without this one no run
  # in the fixture signs on before midnight and the before-midnight read is never
  # exercised. Added before the cut, so its run exists in the same one cut every
  # case reads its run IDs from.
  defp add_early_block(world) do
    blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
      trip_id: "z",
      service_id: "WK",
      block_id: "103",
      first_stop: "BAY_A",
      last_stop: "BAY_B",
      first_departure: "00:05:00",
      last_arrival: "00:45:00"
    })

    world
  end

  # Cuts runs for every day type, through the domain's own suggest-and-apply
  # path, so what is exported is a run this application would have cut. Called
  # once per world: a second cut renumbers the runs and would invalidate any slot
  # written against the first.
  defp cut_runs(world) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    for day_type <- day.day_types do
      {:ok, plan} =
        Gtfs.suggest_runs(world.organization.id, world.version.id, day_type.key, :replace_all)

      assert {:ok, _} = Gtfs.apply_run_plan(world.audit, plan)
    end

    world
  end

  # The world every case starts from: the early block added, the runs cut, and
  # the ID of the run that signs on before midnight **on the day type Monday's
  # base week resolves to**.
  #
  # The day type matters, and more than one day type here derives a
  # before-midnight run. Once the other-service describe adds its holiday service,
  # a holiday Monday runs both `WK` and `HOL`, so the early trip belongs to that
  # day type as well as the weekday one and both of them cut it into a run whose
  # sign-on is negative. That is correct — the trip really does run on those
  # Mondays — and it is why this resolves through `BaseWeek` rather than filtering
  # every run in the version: only the base day type's run is one a Monday slot
  # may name, and `set_roster_slot/4` refuses any other.
  defp prepared(world) do
    world = world |> add_early_block() |> cut_runs()

    base_key = base_day_type_key(world, @monday)
    runs = world |> runs_of_day_type(base_key) |> Enum.filter(&(&1.work.sign_on_secs < 0))

    case runs do
      [run] ->
        %{world: world, early: run.run_id}

      other ->
        raise "expected one before-midnight run on the base day type, got #{inspect(Enum.map(other, & &1.run_id))}"
    end
  end

  # The day type a weekday's base week resolves to, through the same
  # `BaseWeek.resolve/2` the roster read uses. Taken from the stored settings so
  # the test and the export agree on which day type is the base.
  defp base_day_type_key(world, weekday) do
    settings = Rosters.get_roster_settings(world.organization.id, world.version.id)

    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    base_week = BaseWeek.resolve(day.day_types, settings.roster_day_types)

    case Map.fetch!(base_week, weekday) do
      %{day_type: %{key: key}} -> key
      %{day_type: nil} -> raise "weekday #{weekday} has no base day type in this fixture"
    end
  end

  # The ordinary daytime runs, earliest first, so a case wanting "a run that does
  # not sign on before midnight" takes a stable one rather than a fixture's
  # ordering. Scoped to one day type for the same reason `prepared/1` is: a run ID
  # only means something against the day type it was cut in.
  defp daytime_runs(world) do
    world
    |> runs_of_day_type(base_day_type_key(world, @monday))
    |> Enum.filter(&(&1.work.sign_on_secs >= 0))
    |> Enum.sort_by(&{&1.work.sign_on_secs, &1.run_id})
    |> Enum.map(& &1.run_id)
  end

  # One day type's derived runs, as the export's own `run_days` for that key.
  defp runs_of_day_type(world, key) do
    {:ok, runs} = Gtfs.load_runs(world.organization.id, world.version.id, key)
    runs.derived.runs
  end

  defp operator(world, employee_id, display_name, seniority_number) do
    Repo.insert!(
      %Operator{organization_id: world.organization.id}
      |> Operator.changeset(%{
        employee_id: employee_id,
        display_name: display_name,
        seniority_number: seniority_number
      })
    )
  end

  # A line working `run_id` on `weekday`, through the writers the Rosters page
  # calls, with `operator` picked — or with no operator at all, which is the open
  # line the export warns about.
  defp line(world, weekday, run_id, operator) do
    {:ok, line} = Gtfs.create_roster_line(world_audit(world))

    assert {:ok, %{short_rests: []}} =
             Gtfs.set_roster_slot(
               world_audit(world),
               line.id,
               weekday,
               run_id
             )

    if operator do
      assert {:ok, _} =
               Gtfs.assign_roster_operator(
                 world_audit(world),
                 line.id,
                 operator.id
               )
    end

    line
  end

  # ---- the ZIP ---------------------------------------------------------

  defp zip(world) do
    assert {:ok, zip, warnings} =
             Export.build_zip(world.organization.id, world.version.id, :operations)

    %{entries: zip_entries(zip), warnings: warnings}
  end

  defp warnings(world), do: zip(world).warnings

  defp zip_entries(zip_binary) do
    {:ok, files} = :zip.unzip(zip_binary, [:memory])
    Map.new(files, fn {name, content} -> {to_string(name), content} end)
  end

  defp header do
    Tods.employee_run_dates_spec().fields |> Enum.map_join(",", &elem(&1, 0))
  end

  # "Signs on before midnight" read from the file the case is about rather than
  # assumed of a fixture that might have drifted: the early block is what makes
  # this case meaningful, and a fixture that stopped producing a before-midnight
  # run would otherwise pass it vacuously. A run signing on before midnight has
  # its work read one day later on the day type's own service, so it reaches past
  # 24:00 in the file.
  defp before_midnight?(entries, run_id) do
    entries["run_events.txt"]
    |> csv_rows_of()
    |> Enum.filter(&(&1["run_id"] == run_id))
    |> Enum.any?(&(secs(&1["end_time"]) > 86_400))
  end

  defp secs(clock) do
    [h, m, s] = clock |> String.split(":") |> Enum.map(&String.to_integer/1)
    h * 3600 + m * 60 + s
  end

  defp csv_rows_of(nil), do: []

  defp csv_rows_of(content) do
    [header | lines] =
      content
      |> String.trim_trailing("\n")
      |> String.split("\n")

    keys = String.split(header, ",")

    lines
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line -> keys |> Enum.zip(String.split(line, ",")) |> Map.new() end)
  end

  defp compact_date(date), do: date |> Date.to_iso8601() |> String.replace("-", "")

  # ---- the warnings ----------------------------------------------------

  defp assignment_warnings(warnings) do
    Enum.filter(warnings, &String.starts_with?(&1.code, "tods_assignments"))
  end

  defp find_warning(warnings, code) do
    Enum.find(warnings, &(&1.code == code)) ||
      raise "expected #{code}, got #{inspect(Enum.map(warnings, & &1.code))}"
  end

  defp planned(warnings), do: find_warning(warnings, "tods_assignments_planned")
  defp other_service(warnings), do: find_warning(warnings, "tods_assignments_other_service")
  defp unassigned(warnings), do: find_warning(warnings, "tods_assignments_unassigned")
  defp stale_warning(warnings), do: find_warning(warnings, "tods_assignments_stale")

  # The model's own restoration, so a missing key is deleted rather than set to
  # nil — an `Application.put_env/3` of nil is not the same as never having set it.
  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end
