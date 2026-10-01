defmodule GtfsPlannerWeb.Gtfs.RostersGridLiveTest do
  @moduledoc """
  The roster grid: one row per line, seven weekday slots, and the four columns
  that describe the week as a whole.

  Every word asserted here is a word the composition produced. The world is
  written through the same writers the page uses — `Gtfs.create_roster_line/1`,
  `Gtfs.set_roster_slot/4`, `Gtfs.assign_roster_operator/3` — over
  `RunsFixtures.runs_version_fixture/1`, and the two stale states are reached the
  ways production reaches them: a day whose base-week day type is no longer the
  weekday's own (a re-cut, INV-13), and a run whose stored assignments are gone
  (a rebuild that drops it).

  ## The world

  The shared fixture is one weekday calendar with two blocks, which gives one
  day type and a base week of Monday to Friday. Two calendars and three blocks
  are added, so that Saturday and Sunday are real base weekdays too: two of the
  states the grid has to draw — days off apart, and a Sunday → Monday short rest
  — are unreachable in a version whose weekend has no runs at all.

    * `WK` "Weekday" — block 201 on run `2001`, a long platform day; block 202
      on run `2002`, a short midday one; and block 204 on run `2004`, whose
      23:45–00:45 trip signs **off** after midnight;
    * `SAT` "Saturday" — block 401 on run `6001`;
    * `SUN` "Sunday" — block 501 on run `7001`, the late Sunday run whose 21:15
      sign-off leaves under ten hours before `2001`'s Monday sign-on.

  Each test builds only the lines it is about — a run can be held on a weekday by
  only one line, so a shared world would make the second case's line collide with
  the first's.

  Asserted on element IDs, `data-*` attributes and `LazyHTML`, never on raw
  HTML. Rows are created inside the SQL Sandbox transaction and rolled back.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo

  setup :verify_on_exit!

  defp editor_setup(_context), do: %{user: user_fixture()}

  # The shared planning day with the two weekend calendars and the three extra
  # blocks the states below need. Every trip goes through the blocking fixture,
  # so a block here is a real block rather than an inserted trip row.
  defp world do
    world = runs_version_fixture()

    # Every weekday flag is named: `calendar_service_fixture/3` fills the ones a
    # caller leaves out from the weekday defaults, so a Saturday calendar that
    # named only `:saturday` would also run Monday to Friday and the day types
    # would merge into one.
    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "SAT",
      name: "Saturday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "SUN",
      name: "Sunday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 1,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    day_type_keys = day_type_keys(world)

    for {block_id, day_type_label, run_id} <- [
          {"201", "Weekday", "2001"},
          {"202", "Weekday", "2002"},
          {"204", "Weekday", "2004"},
          {"401", "Saturday", "6001"},
          {"501", "Sunday", "7001"}
        ],
        {trip_id, first, last} <- block_trips(block_id),
        trip =
          blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
            trip_id: trip_id,
            service_id: service_id(block_id),
            block_id: block_id,
            first_arrival: first,
            last_arrival: last
          }) do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: Map.fetch!(day_type_keys, day_type_label),
        run_id: run_id
      })
    end

    world
  end

  # The base week resolves by the most dates on a weekday, so Saturday and Sunday
  # become their own day types once their calendars are beside the weekday one.
  # The keys are read from the derivation rather than computed, so a test can
  # never name a day type the load would refuse.
  defp day_type_keys(world) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    Map.new(day.day_types, fn day_type -> {day_type.label, day_type.key} end)
  end

  # The calendar service each block's trips run on, and the day type it therefore
  # belongs to. Both are named once per block so a trip can never be written
  # against a service the block was not built for.
  #
  # The block numbers are the fixture's own run numbers with a hundred added. The
  # fixture already owns blocks 101 and 102 carrying runs 2001 and 2002, and a
  # block holding two sets of trips that overlap is a run with errors, which is a
  # state this page has to draw for other reasons and would otherwise answer here.
  defp service_id(block_id) when block_id in ["201", "202", "204"], do: "WK"
  defp service_id("401"), do: "SAT"
  defp service_id("501"), do: "SUN"

  # The late rows are the load-bearing ones: 204 signs off after midnight, and
  # 501 signs off at 21:15 the night before the weekday morning sign-on.
  defp block_trips("201"),
    do: [
      {"w201a", "05:50:00", "06:50:00"},
      {"w201b", "07:00:00", "08:00:00"},
      {"w201c", "09:00:00", "13:00:00"},
      {"w201d", "13:30:00", "15:30:00"}
    ]

  defp block_trips("202"),
    do: [{"w202a", "12:00:00", "12:30:00"}, {"w202b", "12:40:00", "13:10:00"}]

  defp block_trips("204"),
    do: [{"w204a", "22:30:00", "23:00:00"}, {"w204b", "23:45:00", "00:45:00"}]

  defp block_trips("401"),
    do: [{"w401a", "07:00:00", "07:30:00"}, {"w401b", "07:45:00", "08:15:00"}]

  defp block_trips("501"),
    do: [{"w501a", "20:00:00", "20:30:00"}, {"w501b", "20:45:00", "21:15:00"}]

  defp signed_in(context) do
    world = world()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: context.user.id,
        organization_id: world.organization.id,
        roles: ["pathways_studio_editor"]
      })

    {log_in_user(context.conn, context.user, organization: world.organization), world}
  end

  defp path(world), do: "/gtfs/#{world.version.id}/rosters"

  # Builds one line working the given `{weekday, run_id}` days and returns its
  # id and line number, which is what every assertion below addresses the row by.
  defp line(world, days) do
    {:ok, %{id: line_id}} = Gtfs.create_roster_line(world_audit(world))

    for {weekday, run_id} <- days do
      assert {:ok, _result} =
               Gtfs.set_roster_slot(
                 world_audit(world),
                 line_id,
                 weekday,
                 run_id
               )
    end

    {line_id, line_number(world, line_id)}
  end

  defp line_number(world, line_id) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    Enum.find_value(roster.lines, fn built ->
      if built.id == line_id, do: built.line_number
    end)
  end

  defp text(view, selector), do: view |> element(selector) |> render()

  # The row's own Problems and Days off and paid cells, addressed through the
  # row's stream id so two rows with the same words cannot answer for each other.
  defp in_row(view, number, cell) do
    text(view, "#rosters-grid tr[id='rosters-line-#{number}'] .#{cell}")
  end

  # Takes one row's day type key, which is the only writer-free way to leave a
  # slot naming a weekday and a run the base week no longer resolves: a re-cut
  # changes which day type that weekday runs, and this is the row that survives
  # it (INV-13).
  defp remove_base_week_day(world, line_id, weekday) do
    Repo.update_all(
      from(day in RosterLineDay,
        where: day.roster_line_id == ^line_id and day.weekday == ^weekday
      ),
      set: [day_type_key: world.version.id]
    )

    :ok
  end

  # Removes a run's stored assignments, which is what a rebuild that drops the run
  # does: the row is still there, naming a run that no longer derives.
  defp drop_run(world, day_type_label, run_id) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)
    key = day.day_types |> Enum.find(&(&1.label == day_type_label)) |> Map.fetch!(:key)

    Repo.delete_all(
      from(run in TripRun,
        where:
          run.organization_id == ^world.organization.id and
            run.gtfs_version_id == ^world.version.id and
            run.day_type_key == ^key and run.run_id == ^run_id
      )
    )
  end

  describe "the grid" do
    setup :editor_setup

    test "draws a row per line with a slot for every weekday", context do
      {conn, world} = signed_in(context)
      {_line_id, number} = line(world, [{1, "2001"}])

      {:ok, view, _html} = live(conn, path(world))

      assert has_element?(view, "#rosters-grid")
      assert has_element?(view, "#rosters-grid-body")
      assert has_element?(view, "#rosters-line-#{number}")

      for weekday <- 1..7 do
        assert has_element?(view, "#slot-#{number}-#{weekday}")
      end

      # The Line cell says the number and whether anybody picked the line.
      line_cell = text(view, "#rosters-line-#{number}")
      assert line_cell =~ to_string(number)
      assert line_cell =~ "Open"

      # A working slot is the run's ID over its own sign-on and sign-off. The
      # times are the derived ones, not the trips' own: the first trip departs
      # 05:50 and the last arrives 15:30, and this version's crew rules add a
      # fifteen-minute report before the platform and a five-minute sign-off
      # after it, which is where 5:35 and 15:35 come from.
      assert has_element?(view, "#slot-#{number}-1[data-slot='work']", "2001")
      assert has_element?(view, "#slot-#{number}-1", "5:35–15:35")

      # A day the line does not work is Off, in words, and is still a button.
      assert has_element?(view, "#slot-#{number}-3[data-slot='off']", "Off")

      # The weekday heading carries the base day type in its title, which is how
      # a reader knows which calendar a column is drawn from.
      assert has_element?(view, "#rosters-grid thead th[title*='Weekday']")
    end

    test "a run that signs off after midnight reads above 24 h", context do
      {conn, world} = signed_in(context)
      {_line_id, number} = line(world, [{1, "2004"}])

      {:ok, view, _html} = live(conn, path(world))

      slot = text(view, "#slot-#{number}-1")
      assert slot =~ "2004"
      # The service-day clock, not a wall clock: this run signs off at 00:45 on
      # the next service day, and a bare "00:45" would read as before it started.
      assert slot =~ ~r/\d{2}:\d{2}–24:\d{2}/
    end

    test "reports a short rest on the day that starts too soon", context do
      {conn, world} = signed_in(context)
      {_line_id, number} = line(world, [{7, "7001"}, {1, "2001"}])

      {:ok, view, _html} = live(conn, path(world))

      # The marker is on Monday, because Monday is the day the planner would
      # change; Sunday is the day that leaves too little rest before it.
      assert has_element?(view, "#slot-#{number}-1[data-warning='short-rest']")
      refute has_element?(view, "#slot-#{number}-7[data-warning]")

      assert in_row(view, number, "rosters-problems") =~ "Short rest Sun → Mon"
    end

    test "says a stale slot is stale and names the reason", context do
      {conn, world} = signed_in(context)
      {changed_id, changed_number} = line(world, [{3, "2002"}])
      # A stored time moved behind the writer's back is a re-cut, which the
      # composition can only see as the base week no longer resolving that day
      # to the row's own day type. The row keeps naming the weekday and the run,
      # so the reader still knows which day to go and look at.
      remove_base_week_day(world, changed_id, 3)

      {_removed_id, removed_number} = line(world, [{4, "2004"}])
      drop_run(world, "Weekday", "2004")

      {:ok, view, _html} = live(conn, path(world))

      # The run's ID stays readable, because it is the run the planner has to go
      # and look at; "Stale run" is the word under it.
      assert has_element?(view, "#slot-#{changed_number}-3[data-slot='stale']", "2002")
      assert has_element?(view, "#slot-#{changed_number}-3", "Stale run")
      assert has_element?(view, "#slot-#{removed_number}-4[data-slot='stale']", "Stale run")

      assert in_row(view, changed_number, "rosters-problems") =~ "base week"
      assert in_row(view, removed_number, "rosters-problems") =~ "Run removed"
    end

    test "shows weekly paid as H:MM with the hours over 40", context do
      {conn, world} = signed_in(context)
      {_line_id, number} = line(world, Enum.map(1..5, &{&1, "2001"}))

      {:ok, view, _html} = live(conn, path(world))

      # Five days of run 2001 — an hour of platform time before the garage, a
      # long midday piece and a two-hour last piece, with the reports and the
      # sign-off allowance this version's crew rules add — is 50 h 00 min, over
      # its 48 h warning, so the cell takes the warning treatment as well.
      paid = in_row(view, number, "rosters-paid")
      assert paid =~ "50:00"
      assert paid =~ "+10:00 over 40"

      assert paid =~ "rosters-paid-warning"

      assert in_row(view, number, "rosters-problems") =~ "Over 48 h"
    end

    test "shows the days-off groups and warns when they are split", context do
      {conn, world} = signed_in(context)

      {_line_id, number} =
        line(world, [
          {2, "2001"},
          {3, "2001"},
          {4, "2001"},
          {5, "2001"},
          {7, "7001"}
        ])

      {:ok, view, _html} = live(conn, path(world))

      days_off = in_row(view, number, "rosters-days-off")
      assert days_off =~ "Mon"
      assert days_off =~ "Sat"
      assert days_off =~ "rosters-warning-text"

      assert in_row(view, number, "rosters-problems") =~ "Days off apart"
    end

    test "shows the operator, or Open with a control to record the pick", context do
      {conn, world} = signed_in(context)
      {_open_id, open_number} = line(world, [{1, "2001"}])

      {:ok, view, _html} = live(conn, path(world))

      assert has_element?(view, "#rosters-record-pick-#{open_number}", "Record pick")
      assert text(view, "#rosters-line-#{open_number}") =~ "Open"

      {:ok, operator} =
        Operations.create_operator(world.organization.id, context.user, %{
          employee_id: "E9001",
          display_name: "Ada Okafor"
        })

      {assigned_id, assigned_number} = line(world, [{2, "2002"}])

      assert {:ok, %{line_number: ^assigned_number}} =
               Gtfs.assign_roster_operator(
                 world_audit(world),
                 assigned_id,
                 operator.id
               )

      {:ok, view, _html} = live(conn, path(world))

      operator_cell = in_row(view, assigned_number, "rosters-operator")
      assert operator_cell =~ "Ada Okafor"
      assert operator_cell =~ "E9001"
      assert has_element?(view, "#rosters-record-pick-#{assigned_number}", "Change")
      assert text(view, "#rosters-line-#{assigned_number}") =~ "Assigned"
    end

    test "shows the first finding in words and counts the rest", context do
      {conn, world} = signed_in(context)

      # Monday to Saturday leaves only Sunday off, so this line is both over the
      # weekly warning and short of two days off in a row.
      {_line_id, number} =
        line(world, [
          {1, "2001"},
          {2, "2001"},
          {3, "2001"},
          {4, "2001"},
          {5, "2001"},
          {6, "6001"}
        ])

      {:ok, view, _html} = live(conn, path(world))

      # The findings are sorted by the weekday they concern, so the weekly-hours
      # finding (which names every working day) comes before the days-off one.
      assert in_row(view, number, "rosters-problems") =~ "Over 48 h +1"
    end

    test "a line with no problems says so", context do
      {conn, world} = signed_in(context)

      # Monday to Thursday on the midday run plus the Sunday run is a week with
      # nothing to report: Friday and Saturday are two days off together, every
      # gap between two runs is a full day or more, and four short days plus one
      # evening stay well under the 48 h warning.
      {_line_id, number} =
        line(world, [
          {1, "2002"},
          {2, "2002"},
          {3, "2002"},
          {4, "2002"},
          {7, "7001"}
        ])

      {:ok, view, _html} = live(conn, path(world))

      assert has_element?(
               view,
               "#rosters-grid tr[id='rosters-line-#{number}'] .rosters-problems",
               "No problems"
             )
    end
  end
end
