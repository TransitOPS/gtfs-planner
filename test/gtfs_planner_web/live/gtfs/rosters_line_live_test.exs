defmodule GtfsPlannerWeb.Gtfs.RostersLineLiveTest do
  @moduledoc """
  The line drawer and the delete-line confirmation behind its footer.

  Every button here reaches a real writer — `Gtfs.delete_roster_line/2` — and
  the stored rows are re-read straight out of `roster_lines` and
  `roster_line_days` afterwards, so "the line is gone" and "the screen says it
  is gone" are two independent reads rather than one rendering.

  ## The world

  The same fixture the add-to-line tests build (`rosters_add_to_line_live_test.exs`):
  a weekday day type over Monday to Friday plus a Saturday and a Sunday day
  type, with the runs `2001` (05:35–15:35), `2002` (12:00–12:30), `2004`,
  `6001` and `7001`. Run `2001` on five weekdays is a 50-hour line, which is
  what puts "over 40" in the drawer's figures and a `weekly_hours` finding in
  its problems.

  ## What each case is really asserting

  - The drawer reads the composition's own line, so its week, its days off, its
    weekly paid time and its findings are the grid's figures in words rather
    than a second opinion (INV-15).
  - The confirmation names the line and its stored run-days, and says so
    before anything is deleted.
  - A delete removes the row, returns its runs to open work, and hands focus to
    the grid heading, because the link the planner came in through is gone with
    the row.
  - A refusal is the writer's own answer, drawn where the planner is looking.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Repo

  defp editor_setup(_context), do: %{user: user_fixture()}

  defp world do
    world = runs_version_fixture()

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
          {"401", "Saturday", "6001"}
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

  defp day_type_keys(world) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    Map.new(day.day_types, fn day_type -> {day_type.label, day_type.key} end)
  end

  defp service_id(block_id) when block_id in ["201", "202"], do: "WK"
  defp service_id("401"), do: "SAT"

  defp block_trips("201"),
    do: [
      {"w201a", "05:50:00", "06:50:00"},
      {"w201b", "07:00:00", "08:00:00"},
      {"w201c", "09:00:00", "13:00:00"},
      {"w201d", "13:30:00", "15:30:00"}
    ]

  defp block_trips("202"),
    do: [{"w202a", "12:00:00", "12:30:00"}, {"w202b", "12:40:00", "13:10:00"}]

  defp block_trips("401"),
    do: [{"w401a", "07:00:00", "07:30:00"}, {"w401b", "07:45:00", "08:15:00"}]

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

  # A line written through the production writers, so its rows carry the stored
  # run times the composition reads (INV-13).
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

    line_id
  end

  # An operator of the world's own organization, recorded through the pick's own
  # writer rather than inserted onto the row, so "the pick recorded for this
  # line is removed" is a fact about a line that really has a pick.
  defp picked_line(world, days) do
    line_id = line(world, days)

    operator =
      Repo.insert!(
        %Operator{organization_id: world.organization.id}
        |> Operator.changeset(%{employee_id: "E-4102", display_name: "Hiroshi Tanaka"})
      )

    assert {:ok, _result} =
             Gtfs.assign_roster_operator(
               world_audit(world),
               line_id,
               operator.id
             )

    line_id
  end

  defp text_of(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp attr_of(view, selector, attribute) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
    |> List.first()
  end

  defp stored_days(world, id) do
    Repo.all(
      from(d in RosterLineDay,
        where: d.roster_line_id == ^id and d.organization_id == ^world.organization.id,
        select: d.weekday,
        order_by: d.weekday
      )
    )
  end

  defp stored_lines(world) do
    Repo.all(
      from(l in RosterLine,
        where:
          l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id,
        select: l.line_number,
        order_by: l.line_number
      )
    )
  end

  defp stored_operator_ids(world) do
    Repo.all(
      from(l in RosterLine,
        where:
          l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id,
        select: l.operator_id
      )
    )
  end

  describe "the line drawer" do
    setup :editor_setup

    test "shows the week, the days off, the weekly paid and the problems in words", context do
      {conn, world} = signed_in(context)
      # Run 2001 on five weekdays is 50 h a week, which is over the fixture's
      # 48 h warning; Saturday's 6001 takes it to 51:15 and leaves Sunday the
      # only day off, so the line has no two days off in a row either. Two
      # findings, and the over-40 figure beside them.
      _long = line(world, Enum.map(1..5, &{&1, "2001"}) ++ [{6, "6001"}])

      {:ok, view, _html} = live(conn, path(world))

      refute has_element?(view, "#rosters-line-drawer")
      view |> element("#rosters-line-1-open") |> render_click()

      assert has_element?(view, "#rosters-line-drawer")
      assert text_of(view, "#rosters-line-drawer-title") =~ "Line 1"
      assert text_of(view, "#rosters-line-lede") == "Open · 6 working days"

      # The week's own figures, in the words the grid's cells use.
      facts = text_of(view, "#rosters-line-facts")
      assert facts =~ "Operator"
      assert facts =~ "Open"
      assert facts =~ "Days off"
      assert facts =~ "Sun"
      assert facts =~ "51:35"
      assert facts =~ "+11:35 over 40"

      # Every day of the week is a row, working or off, and a working day's
      # times are the run's.
      assert attr_of(view, "#rosters-line-week-1", "data-state") == "work"
      monday = text_of(view, "#rosters-line-week-1")
      assert monday =~ "Monday"
      assert monday =~ "2001"
      assert monday =~ "One piece"
      assert monday =~ "5:35–15:35"
      assert monday =~ "10:00"

      assert attr_of(view, "#rosters-line-week-5", "data-state") == "work"
      assert attr_of(view, "#rosters-line-week-6", "data-state") == "work"
      assert text_of(view, "#rosters-line-week-6") =~ "6001"
      assert attr_of(view, "#rosters-line-week-7", "data-state") == "off"
      assert text_of(view, "#rosters-line-week-7") =~ "Off"

      # The findings are the grid's Problems column in words: the short words
      # as the title, the long sentence behind them as the body.
      assert text_of(view, "#rosters-line-problem-weekly_hours-1-2-3-4-5-6") =~
               "Over 48 h."

      assert text_of(view, "#rosters-line-problem-weekly_hours-1-2-3-4-5-6") =~
               "Paid 51:35 a week, over the 48 h warning."

      assert text_of(view, "#rosters-line-problem-days_off-7") =~ "Days off apart."
      assert text_of(view, "#rosters-line-problem-days_off-7") =~ "no two days off in a row"
      refute has_element?(view, "#rosters-line-no-problems")
    end

    test "says a clean line has no problems", context do
      {conn, world} = signed_in(context)
      # Tuesday alone: the other six days are off in two runs, so the line
      # keeps its rest and its two-days-off rule.
      _short = line(world, [{2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-line-1-open") |> render_click()

      assert has_element?(view, "#rosters-line-no-problems")
      assert text_of(view, "#rosters-line-lede") == "Open · 1 working day"
      assert text_of(view, "#rosters-line-facts") =~ "Wed–Mon"
    end

    test "names the line, its run-days and its pick in the delete confirmation", context do
      {conn, world} = signed_in(context)
      _picked = picked_line(world, [{2, "2002"}, {4, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-line-1-open") |> render_click()
      view |> element("#rosters-delete-line") |> render_click()

      assert has_element?(view, "#rosters-delete-line-confirm")
      assert text_of(view, "#rosters-delete-line-confirm-title") == "Delete line 1?"

      assert text_of(view, "#rosters-delete-line-confirm-body") ==
               "Its 2 run-days return to open work. The pick recorded for this line is removed."

      # The safe answer is first and the destructive one is the confirm, so the
      # reading order and the visual weight agree about which is which.
      assert text_of(view, "#rosters-delete-line-confirm-cancel") == "Keep line"
      assert text_of(view, "#rosters-delete-line-confirm-confirm") == "Delete line"
    end

    test "names one run-day in the singular and leaves out a pick there is none of", context do
      {conn, world} = signed_in(context)
      _short = line(world, [{2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-line-1-open") |> render_click()
      view |> element("#rosters-delete-line") |> render_click()

      assert text_of(view, "#rosters-delete-line-confirm-body") ==
               "Its 1 run-day returns to open work."
    end

    test "keeps the line when the confirmation is kept", context do
      {conn, world} = signed_in(context)
      id = picked_line(world, [{2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-line-1-open") |> render_click()
      view |> element("#rosters-delete-line") |> render_click()

      view |> element("#rosters-delete-line-confirm-cancel") |> render_click()

      refute has_element?(view, "#rosters-delete-line-confirm")

      # The line drawer is still the drawer the planner was reading, and the
      # stored rows and the pick are all exactly as they were.
      assert has_element?(view, "#rosters-line-drawer")
      assert stored_lines(world) == [1]
      assert stored_days(world, id) == [2]
      assert [_operator_id] = stored_operator_ids(world)
    end

    test "closes a slot drawer left open, because the page has one drawer", context do
      {conn, world} = signed_in(context)
      _line = line(world, [{1, "2001"}])

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#slot-1-1") |> render_click()
      assert has_element?(view, "#rosters-slot-drawer")

      view |> element("#rosters-line-1-open") |> render_click()

      refute has_element?(view, "#rosters-slot-drawer")
      assert has_element?(view, "#rosters-line-drawer")
    end

    test "ignores a line this version's roster does not hold", context do
      {conn, world} = signed_in(context)
      _line = line(world, [{1, "2001"}])

      {:ok, view, _html} = live(conn, path(world))

      render_click(view, "open_line", %{"line" => "00000000-0000-0000-0000-000000000000"})

      refute has_element?(view, "#rosters-line-drawer")
    end
  end

  describe "deleting a line" do
    setup :editor_setup

    test "removes the line and returns its runs to open work", context do
      {conn, world} = signed_in(context)
      id = line(world, Enum.map(1..5, &{&1, "2001"}))

      {:ok, view, _html} = live(conn, path(world))

      # Run 2001 is held on every weekday it is open on, so it is not open work
      # at all until the line goes.
      refute has_element?(view, ".rosters-open-run[data-run='2001']")

      view |> element("#rosters-line-1-open") |> render_click()
      view |> element("#rosters-delete-line") |> render_click()
      view |> element("#rosters-delete-line-confirm-confirm") |> render_click()

      # Re-read: the row and every day it held are gone, not merely unlinked.
      assert stored_lines(world) == []
      assert stored_days(world, id) == []
      refute has_element?(view, "#rosters-line-1-open")
      refute has_element?(view, "#rosters-line-drawer")
      refute has_element?(view, "#rosters-delete-line-confirm")

      # And the runs came back to open work on every weekday they are open on,
      # which is the consequence the confirmation named.
      assert attr_of(view, ".rosters-open-run[data-run='2001']", "data-open-days") ==
               "1 2 3 4 5"

      assert has_element?(
               view,
               "#rosters-toast",
               "Line 1 deleted. Its 5 run-days return to open work."
             )

      # The row the planner came in through is gone, so focus is handed to the
      # grid's own heading rather than dropped at the top of the document.
      assert_push_event(view, "focus_scoped_target", %{id: "rosters-lines-title"})
      assert has_element?(view, "#rosters-lines-title")
    end

    test "removes the pick with the line", context do
      {conn, world} = signed_in(context)
      _picked = picked_line(world, [{2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-line-1-open") |> render_click()
      view |> element("#rosters-delete-line") |> render_click()
      view |> element("#rosters-delete-line-confirm-confirm") |> render_click()

      assert stored_lines(world) == []
      assert stored_operator_ids(world) == []
    end

    test "a line deleted elsewhere closes the drawer and says why", context do
      {conn, world} = signed_in(context)
      id = line(world, [{2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-line-1-open") |> render_click()
      view |> element("#rosters-delete-line") |> render_click()

      # Another planner deletes it while the confirmation is up, which is the
      # only way the writer can refuse here.
      assert {:ok, _result} =
               Gtfs.delete_roster_line(world_audit(world), id)

      view |> element("#rosters-delete-line-confirm-confirm") |> render_click()

      refute has_element?(view, "#rosters-delete-line-confirm")
      refute has_element?(view, "#rosters-line-drawer")
      assert has_element?(view, "#rosters-toast", "That line is no longer on this version.")
      assert stored_lines(world) == []
    end
  end
end
