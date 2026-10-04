defmodule GtfsPlanner.Gtfs.TodsGenerator.RosterPlanTest do
  @moduledoc """
  Step 4: the roster stage maps a generation candidate's feasible runs to the
  additive single-slot lines a save would write, and reports the recurring dates
  they reach and the work they leave unstaffed.

  These are the failures specific to *generation* roster work, which the Rosters
  page's own tests cannot see because they never ask the question:

    * a holiday Monday whose day type is not its weekday's base is left unstaffed
      and listed, while an ordinary Monday outside the selected week is reached by
      the slot the week worked — a roster slot repeats by weekday and base day type,
      so the range scopes which input was selected and not which dates are affected;
    * a base the version already answers — a stored choice, or a weekday holding
      slots a planner set by hand — is never moved, and the request's work it
      refuses is named rather than delivered by moving the operator's own choice;
    * a run signing on before midnight keeps the day type's own date and service,
      read through `AssignmentsExport.rows/1` rather than re-derived;
    * every free run-day gets one single-slot line and one fictional operator of its
      own, with the derived run's own canonical times, and no free pair proposes
      none at all;
    * existing slots and operator holdings are preserved, and the roster's own rest
      findings are disclosed.

  Every case runs the production chain — `Gtfs.preview_tods_generation/2` through
  `TodsGenerator.preview/2` and `Plan.with_roster/3`, with `Rosters.BaseWeek`,
  `Rosters.Roster.build/1` and `Rosters.AssignmentsExport.rows/1` behind it — and
  the facts it asserts are the fixture's own: literal dates of its calendars,
  literal run days, and the run IDs and times the composition itself derived. No
  run ID is written into a case as an invented number, and every stored line is
  written through the roster writers the page uses.

  Run with:
  `mix test test/gtfs_planner/gtfs/tods_generator/roster_plan_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.RunsFixtures, only: [trip_run_fixture: 3]
  import GtfsPlanner.TodsGeneratorFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo

  describe "the base week" do
    test "a holiday Monday differing from the retained base is unstaffed and listed" do
      world = roster_world_fixture()

      # The operator's own choice for Monday: the ordinary day type, stored through
      # the roster settings writer the settings drawer uses.
      assert {:ok, %{roster_day_types: choices}} =
               Gtfs.update_roster_settings(world.audit, %{
                 "roster_day_types" => %{"1" => world.monday_day_type}
               })

      assert choices == %{"1" => world.monday_day_type}

      assert {:ok, preview} = roster_preview(world)

      # A compatible choice is kept and nothing is added to the stored settings.
      assert preview.roster_day_types == %{}

      monday = weekday_base(preview, 1)
      assert monday.weekday == 1
      assert monday.day_type_key == world.monday_day_type
      assert monday.chosen? == true
      assert monday.added? == false
      assert monday.missing_choice == nil

      # The holiday runs a day type of its own, so no weekday's base reaches it:
      # the date is listed as running different service and as an open date.
      assert preview.coverage.other_service_dates == [world.holiday_date]
      assert world.holiday_date in preview.coverage.open_dates
      refute world.holiday_date in preview.coverage.affected_dates

      # Its runs are named as work no recurring weekday reaches.
      assert [%{reason: :no_base_weekday} | _] = holiday_exclusions(preview, world)

      assert holiday_exclusions(preview, world) |> Enum.map(&elem(&1.subject, 0)) |> Enum.uniq() ==
               [1]

      # The ordinary Monday of the week after the range is reached by the Monday
      # slot the selected week worked: the repetition is not scoped by the range.
      repeated = Date.add(world.holiday_date, 7)

      assert repeated == Date.add(roster_monday(world), 21)
      assert repeated in preview.coverage.affected_dates
      assert repeated in preview.coverage.beyond_range_dates

      assert preview.hard_errors == []
      assert preview.save_available? == true
    end

    test "an unprotected weekday takes the representative week's day type" do
      world = roster_world_fixture()
      holiday_week = Date.to_iso8601(Date.add(roster_monday(world), 14))

      assert {:ok, preview} =
               Gtfs.preview_tods_generation(
                 world.audit,
                 roster_inputs(world, %{"representative_week" => holiday_week})
               )

      # Monday's representative date is the holiday, and nothing protects Monday,
      # so the choice this save would store is that date's day type.
      assert preview.roster_day_types == %{"1" => world.holiday_day_type}

      monday = weekday_base(preview, 1)
      assert monday.weekday == 1
      assert monday.day_type_key == world.holiday_day_type
      assert monday.added? == true
      assert monday.chosen? == false

      # The holiday is now the date the Monday slot reaches, and the ordinary
      # Mondays in the range are the dates running different service instead.
      assert world.holiday_date in preview.coverage.affected_dates

      ordinary_monday = Date.add(roster_monday(world), 7)

      assert ordinary_monday in preview.coverage.open_dates
      assert ordinary_monday in preview.coverage.other_service_dates

      assert Enum.any?(preview.roster_exclusions, fn %{subject: {1, key, _run}} ->
               key == world.monday_day_type
             end)

      assert preview.hard_errors == []
      assert preview.save_available? == true
    end

    test "a protected base that differs refuses the request and names the work" do
      world = roster_world_fixture()

      assert {:ok, _settings} =
               Gtfs.update_roster_settings(world.audit, %{
                 "roster_day_types" => %{"1" => world.holiday_day_type}
               })

      assert {:ok, preview} = roster_preview(world)

      # The operator's choice says Monday works the holiday day type; the request's
      # representative week works the ordinary one. The choice is not moved, so the
      # requested work is refused and the whole plan is unavailable to save.
      assert preview.hard_errors == [
               %{
                 reason: :base_conflict,
                 weekday: 1,
                 day_type_key: world.monday_day_type,
                 retained_day_type_key: world.holiday_day_type
               }
             ]

      assert preview.save_available? == false
      assert preview.roster_day_types == %{}

      assert Enum.any?(preview.roster_exclusions, fn %{subject: {1, key, _run}} ->
               key == world.monday_day_type
             end)

      # Nothing was written: the stored choice is exactly what the operator left.
      assert Gtfs.get_roster_settings(world.organization.id, world.version.id).roster_day_types ==
               %{"1" => world.holiday_day_type}
    end
  end

  describe "the recurring dates" do
    test "a run signing on before midnight keeps the day type's own date and service" do
      world = roster_world_fixture(extra_trips: [early_trip()])

      assert {:ok, preview} = roster_preview(world)

      # A duty signing on before midnight shares the day type's service day with
      # its trips, so the export writes it on the day type's own date and service.
      # The preview holds no supplement to name that service, so it reports the
      # date and leaves the service reference to the export that writes it — the
      # same date `Runs.TodsExport` and the file both use for the same run.
      early = run_for_trip(preview, world.monday_day_type, "early-a")
      assert early.work.sign_on_secs < 0

      assert %{date: roster_monday(world), service_id: nil} in preview.coverage.exported_dates

      # The service date itself is staffed: it is the date the range names and the
      # date the row is written on, so no earlier date is exported for this duty.
      assert roster_monday(world) in preview.coverage.affected_dates
      assert Date.add(roster_monday(world), -1) not in preview.coverage.affected_dates
    end
  end

  describe "the lines" do
    test "every free run-day gets one single-slot line with the run's own times" do
      world = roster_world_fixture()

      assert {:ok, preview} = roster_preview(world)

      lines = preview.roster_lines
      assert lines != []

      subjects = Enum.map(lines, &{&1.weekday, &1.day_type_key, &1.run_id})

      # One line per run-day: every pair once, and one operator ordinal each.
      assert Enum.uniq(subjects) == subjects
      assert Enum.map(lines, & &1.operator_ordinal) == Enum.to_list(1..length(lines))
      assert preview.counts.new_lines == length(lines)
      assert preview.counts.new_slots == length(lines)
      assert preview.counts.new_operators == length(lines)

      for line <- lines do
        run = run_by_id(preview, line.day_type_key, line.run_id)

        # The stored slot's times are the run's own, which is what makes it fresh
        # rather than stale the moment the save writes it.
        assert line.run_sign_on_secs == run.work.sign_on_secs
        assert line.run_sign_off_secs == run.work.sign_off_secs

        # And the weekday the line is proposed on is the base of the day type it
        # names, so the slot resolves to that day type's run.
        assert weekday_base(preview, line.weekday).day_type_key == line.day_type_key
      end

      # Every free run-day is covered, so nothing is left open, and the allocation
      # it rests on is disclosed.
      assert preview.counts.open_run_days == 0
      assert preview.assumptions == [:one_operator_per_run_day, :recurring_beyond_range]
      assert preview.no_work? == false
      assert preview.save_available? == true
    end

    test "an existing line with an operator is preserved and its run-day is not proposed" do
      world = roster_world_fixture() |> stored_runs_fixture(stored_runs())

      assert {:ok, first} = roster_preview(world)

      # A run the version already stores, held by a line with an operator of its own:
      # the state a planner's own roster is in when a generation arrives.
      run = hd(runs_on(first, world.monday_day_type))
      line = new_line(world)
      assert {:ok, _slot} = Gtfs.set_roster_slot(world.audit, line.id, 1, run.run_id)
      operator = operator(world)

      assert {:ok, _picked} = Gtfs.assign_roster_operator(world.audit, line.id, operator.id)

      assert {:ok, preview} = roster_preview(world)

      assert preview.counts.preserved_lines == 1
      assert preview.counts.preserved_slots == 1
      assert preview.counts.preserved_operators == 1

      # Held work is not proposed again, and the rest of Monday's free work still is.
      refute Enum.any?(preview.roster_lines, &(&1.weekday == 1 and &1.run_id == run.run_id))
      assert Enum.any?(preview.roster_lines, &(&1.weekday == 1))

      # The stored slot and the pick are exactly what the planner left, read back
      # through the composition the Rosters page reads.
      assert {:ok, view} = Gtfs.load_roster(world.organization.id, world.version.id)

      assert Enum.any?(view.roster.lines, fn stored ->
               (stored.operator && stored.operator.id == operator.id) and
                 Map.has_key?(stored.slots, 1)
             end)

      assert stored_slot_employee(world, line, 1) == operator.employee_id
    end

    test "no free pair proposes no operator and leaves nothing to save" do
      world = roster_world_fixture() |> stored_runs_fixture(stored_runs())

      assert {:ok, first} = roster_preview(world)

      # Every run the composition derives is stored, so the generation cuts nothing
      # new and every run-day is the planner's to hold.
      assert first.counts.new_runs == 0

      hold_every_run_day(world, first)

      assert {:ok, preview} = roster_preview(world)

      assert preview.roster_lines == []
      assert preview.counts.new_lines == 0
      assert preview.counts.new_slots == 0
      assert preview.counts.new_operators == 0
      assert preview.counts.open_run_days == 0

      # The lines the planner holds are preserved, and nothing is added: there is
      # nothing to save, which is a state a page has to be able to show.
      assert preview.counts.preserved_lines > 0
      assert preview.counts.preserved_slots > 0
      assert preview.hard_errors == []
      assert preview.save_available? == false
      assert preview.no_work? == true
    end

    test "a plan whose only addition is a move into a stored block is still available to save" do
      # The version the case above describes — every run stored, every run-day held —
      # with one trip the planner left without a block although it already has a run,
      # and a stored block "201" the generator chains it onto. The generation's only
      # work is that one move: it creates no block, and the crew and roster stages
      # add no run, line or slot. `counts.new_blocks` is therefore zero and the plan
      # is still one to save, because the move is what a save writes.
      world =
        roster_world_fixture(extra_trips: [chained_trip()])

      block_trips = generator_block_fixture(world)

      stored_runs_fixture(world, Map.put(stored_runs(), "gen-chain", "2"))
      store_trip_runs(world, block_trips, "5")

      assert {:ok, first} = roster_preview(world)
      hold_every_run_day(world, first)

      assert {:ok, preview} = roster_preview(world)

      assert preview.assignments == %{trip_uuid(world, "gen-chain") => "201"}
      assert preview.counts.new_assignments == 1
      assert preview.counts.new_blocks == 0
      assert preview.counts.new_runs == 0
      assert preview.counts.new_lines == 0
      assert preview.hard_errors == []
      assert preview.no_work? == false
      assert preview.save_available? == true
    end

    test "a preserved line's rest finding is disclosed" do
      world =
        crew_world_fixture(block: :overnight)
        |> stored_runs_fixture(%{"night-1" => "9001", "night-2" => "9001", "a" => "9002"})

      assert {:ok, before} = roster_preview(world)

      night = run_for_trip(before, world.monday_day_type, "night-1")
      morning = run_for_trip(before, world.weekday_day_type, "a")

      # The night duty is the run the fixture stored, and the morning duty is the
      # second: nothing here invents a run ID the composition did not derive.
      assert night.run_id == "9001"
      assert morning.run_id == "9002"

      line = new_line(world)
      assert {:ok, _monday} = Gtfs.set_roster_slot(world.audit, line.id, 1, night.run_id)
      assert {:ok, _tuesday} = Gtfs.set_roster_slot(world.audit, line.id, 2, morning.run_id)

      assert {:ok, preview} = roster_preview(world)

      # The line works a duty that ends after midnight and one that signs on early
      # the next morning: the composition's own rest finding says so, against the
      # line the plan would leave in place.
      assert [finding] = Enum.filter(preview.roster_findings, &(&1.code == :short_rest))
      assert finding.line_number == line.line_number
      assert finding.operator_ordinal == nil
      assert finding.weekdays == [2]
      assert finding.detail.from == 1
      assert finding.detail.to == 2
      assert finding.detail.rest_secs < finding.detail.min_secs

      # The run-day the line works is held rather than proposed again.
      refute Enum.any?(preview.roster_lines, &(&1.weekday == 1 and &1.run_id == night.run_id))
    end

    test "a stale stored slot leaves a partially staffed date open" do
      world = roster_world_fixture() |> stored_runs_fixture(stored_runs())

      assert {:ok, before} = roster_preview(world)
      run = hd(runs_on(before, world.monday_day_type))

      # A slot the planner set before the run was re-cut: the row still holds the
      # run-day, and the times it stored no longer match the run it names.
      roster_line_fixture(world, %{
        weekday: 1,
        day_type_key: world.monday_day_type,
        run_id: run.run_id,
        run_sign_on_secs: run.work.sign_on_secs + 60,
        run_sign_off_secs: run.work.sign_off_secs
      })

      assert {:ok, preview} = roster_preview(world)

      # Held, so the generation does not offer it again; stale, so the export writes
      # nothing for it and the run-day is reported as work the plan leaves open.
      refute Enum.any?(preview.roster_lines, &(&1.weekday == 1 and &1.run_id == run.run_id))

      assert %{subject: {1, day_type_key, run_id}, reason: :stale_slot} =
               Enum.find(preview.roster_exclusions, &(&1.reason == :stale_slot))

      assert day_type_key == world.monday_day_type
      assert run_id == run.run_id
      assert Enum.any?(preview.roster_findings, &(&1.code == :stale_slot))

      # Other Monday runs are staffed by new lines. Partial coverage must appear
      # both as an affected date and as a date with work still open.
      assert length(runs_on(preview, world.monday_day_type)) > 1
      assert roster_monday(world) in preview.coverage.affected_dates
      assert roster_monday(world) in preview.coverage.open_dates
      refute Date.add(roster_monday(world), 1) in preview.coverage.open_dates
    end

    test "a run with an error finding is not proposed and stays unstaffed" do
      world = crew_world_fixture(block: :long_duty, existing_run: "9001", max_piece_minutes: 480)

      assert {:ok, preview} = roster_preview(world)

      # The stored duty is the operator's to fix, so no line is offered for it and
      # the export drops it: its run-day is work the plan leaves open.
      run = run_for_trip(preview, world.weekday_day_type, "long-1")
      assert run.run_id == "9001"
      assert Enum.any?(run.findings, &(&1.severity == :error))

      exclusions = Enum.filter(preview.roster_exclusions, &(&1.reason == :run_has_errors))
      assert exclusions != []

      assert Enum.all?(exclusions, fn %{subject: {_weekday, key, run_id}} ->
               key == world.weekday_day_type and run_id == "9001"
             end)

      refute Enum.any?(preview.roster_lines, &(&1.run_id == "9001"))
    end
  end

  # One unblocked weekday trip departing before midnight, so its duty signs on the
  # previous day: 00:05 minus the pull-out allowance is a negative service-day
  # second, which is what makes the export read the whole duty one day later on the
  # day type's own service.
  defp early_trip, do: {"early-a", "WK", "RIV", "RIV", "00:05:00", "01:00:00"}

  # One weekday trip timed to chain onto the stored block "201"
  # `generator_block_fixture/1` writes: it leaves `RIV` after that block's own last
  # arrival, so the generator extends the block rather than opening one.
  defp chained_trip, do: {"gen-chain", "WK", "RIV", "RIV", "15:40:00", "16:10:00"}

  defp new_line(world) do
    assert {:ok, line} = Gtfs.create_roster_line(world.audit)
    line
  end

  # Stores a run for trips a case wrote after the world was built, on every day type
  # the version derives: a trip whose run is already stored adds no run delta, which
  # is what leaves a block move as a plan's only addition.
  defp store_trip_runs(world, trips, run_id) do
    for trip <- trips, day_type <- day_types(world) do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip.id,
        day_type_key: day_type.key,
        run_id: run_id
      })
    end
  end

  defp trip_uuid(world, trip_id), do: Map.fetch!(world.trip_ids, trip_id)

  # One stored run per block of the fixture's own schedule: the four runs a planner
  # would have cut and saved, so the version has no uncovered work left.
  defp stored_runs do
    %{"a" => "1", "b" => "2", "c" => "2", "d" => "2", "e" => "3", "f" => "4"}
  end

  defp operator(world) do
    assert {:ok, operator} =
             Operations.create_operator(world.organization.id, %{id: world.audit.actor_id}, %{
               employee_id: "E-1",
               display_name: "Aurelia Nowak",
               seniority_number: 1
             })

    operator
  end

  # Holds every run-day the composition left open, through the roster writers, so no
  # free pair remains: one line per run of the Monday day type and one per run of
  # the weekday day type, which between them cover every base weekday.
  defp hold_every_run_day(world, preview) do
    monday_runs = runs_on(preview, world.monday_day_type)
    weekday_runs = runs_on(preview, world.weekday_day_type)

    lines = for _ <- 1..max(length(monday_runs), length(weekday_runs)), do: new_line(world)

    Enum.each(Enum.zip(lines, monday_runs), fn {line, run} ->
      assert {:ok, _slot} = Gtfs.set_roster_slot(world.audit, line.id, 1, run.run_id)
    end)

    Enum.each(Enum.zip(lines, weekday_runs), fn {line, run} ->
      Enum.each(2..5, fn weekday ->
        assert {:ok, _slot} = Gtfs.set_roster_slot(world.audit, line.id, weekday, run.run_id)
      end)
    end)
  end

  defp runs_on(preview, day_type_key) do
    preview.run_days |> Map.fetch!(day_type_key) |> Map.fetch!(:runs)
  end

  defp run_by_id(preview, day_type_key, run_id) do
    assert run =
             preview.run_days
             |> Map.fetch!(day_type_key)
             |> Map.fetch!(:runs)
             |> Enum.find(&(&1.run_id == run_id))

    run
  end

  # The run a trip is in on one day type, read from the composition's own derived
  # day so a case never writes a run ID it invented.
  defp run_for_trip(preview, day_type_key, trip_id) do
    assert run =
             preview.run_days
             |> Map.fetch!(day_type_key)
             |> Map.fetch!(:runs)
             |> Enum.find(fn run ->
               Enum.any?(run.pieces, &Enum.any?(&1.trips, fn trip -> trip.trip_id == trip_id end))
             end)

    run
  end

  defp weekday_base(preview, weekday) do
    Enum.find(preview.coverage.base_week, &(&1.weekday == weekday))
  end

  # The holiday day type's run-days, which no recurring weekday base reaches.
  defp holiday_exclusions(preview, world) do
    Enum.filter(preview.roster_exclusions, fn %{subject: {_weekday, key, _run}} ->
      key == world.holiday_day_type
    end)
  end

  # The employee the composition reads off one stored slot, read from the tables so
  # the claim is about what the planner's own writer stored.
  defp stored_slot_employee(world, line, weekday) do
    Repo.one!(
      from(d in RosterLineDay,
        join: l in GtfsPlanner.Gtfs.RosterLine,
        on: l.id == d.roster_line_id,
        join: o in GtfsPlanner.Operations.Operator,
        on: o.id == l.operator_id,
        where:
          d.roster_line_id == ^line.id and d.weekday == ^weekday and
            d.gtfs_version_id == ^world.version.id,
        select: o.employee_id
      )
    )
  end
end
