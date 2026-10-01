defmodule GtfsPlannerWeb.Gtfs.RostersAddToLineLiveTest do
  @moduledoc """
  "Add to line…": the drawer an open run's card opens, the lines it offers, and
  the two writes behind its footer.

  Every button here reaches a real writer — `Gtfs.create_roster_line/2` and
  `Gtfs.set_roster_slot/5` — and every stored row is re-read straight out of
  `roster_line_days` afterwards, so "the line holds the run" and "the row says
  the run" are two independent reads rather than one rendering.

  ## The world

  The same fixture the slot drawer and open-work tests build
  (`rosters_open_work_live_test.exs`): a weekday day type over Monday to Friday
  plus a Saturday and a Sunday day type, and the late Sunday run `7001` that
  leaves under ten hours of rest before the weekday morning sign-on. `7001` is
  what makes the ordering observable: a line working Sunday is exactly the line
  that would leave a short rest, and it is the last row rather than the first.

  ## What each case is really asserting

  - A run open on several weekdays is asked for a day before a line; a run open
    on one is not asked anything.
  - The rows are `Candidates.lines_for_open_run/3` in that function's order, so
    the markup's `data-short` and `data-selected` read the same decision the
    writer runs under the lock (INV-15).
  - A refused write leaves the writer's own sentence in the drawer and writes
    nothing, so the case creates the conflict with a direct context write rather
    than with a page interaction.
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
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Repo

  setup :verify_on_exit!

  defp editor_setup(_context), do: %{user: user_fixture()}

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

  defp day_type_keys(world) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    Map.new(day.day_types, fn day_type -> {day_type.label, day_type.key} end)
  end

  defp service_id(block_id) when block_id in ["201", "202", "204"], do: "WK"
  defp service_id("401"), do: "SAT"
  defp service_id("501"), do: "SUN"

  # 501 is the load-bearing one: it signs off at 21:15 on Sunday, which leaves
  # under ten hours before 2001's 05:35 Monday sign-on.
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

  # A line written through the production writers, so its rows carry the stored
  # run times the composition reads (INV-13).
  defp line(world, days) do
    {:ok, %{id: line_id}} = Gtfs.create_roster_line(world.organization.id, world.version.id)

    for {weekday, run_id} <- days do
      assert {:ok, _result} =
               Gtfs.set_roster_slot(
                 world.organization.id,
                 world.version.id,
                 line_id,
                 weekday,
                 run_id
               )
    end

    line_id
  end

  defp text(view, selector), do: view |> element(selector) |> render()

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

  # One day's own row, read straight out of the table rather than through the
  # composition: a line's day is a stored row and this is that row.
  defp stored_day_row(world, id, weekday) do
    Repo.one(
      from(d in RosterLineDay,
        where:
          d.roster_line_id == ^id and d.weekday == ^weekday and
            d.organization_id == ^world.organization.id and
            d.gtfs_version_id == ^world.version.id,
        select: {d.run_id, d.day_type_key}
      )
    )
  end

  defp line_id(world, number) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    Enum.find_value(roster.lines, fn built ->
      if built.line_number == number, do: built.id
    end)
  end

  defp line_numbers(world) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    Enum.map(roster.lines, & &1.line_number)
  end

  # The line numbers the drawer is offering, in the order it is offering them,
  # read off the markup so the assertion is about what a planner chooses from.
  defp offered_lines(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#rosters-add-line-rows tr")
    |> Enum.map(fn node ->
      id = node |> LazyHTML.attribute("data-line-id") |> List.first()

      {node |> LazyHTML.attribute("id") |> List.first(),
       node |> LazyHTML.attribute("data-short") |> List.first(), id}
    end)
  end

  defp short_lines(view) do
    for {id, short?, _line_id} <- offered_lines(view), short? == "true", do: id
  end

  defp offered_row_ids(view) do
    for {id, _short?, _line_id} <- offered_lines(view), do: id
  end

  defp day_type_key(world, label) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    Enum.find_value(day.day_types, fn day_type ->
      if day_type.label == label, do: day_type.key
    end)
  end

  # Three lines with Monday off, so the drawer's order is observable:
  #
  #   1  Tuesday 2002               1 h 10 paid, keeps every rest
  #   2  Sunday 7001                1 h paid, 8 h 20 rest before Monday's 05:35
  #   3  Wednesday and Friday 2002  2 h 20 paid, keeps every rest
  #
  # So the order is 1, 3, 2: the lines that keep every rest first and by weekly
  # paid ascending, and the one that would leave a short rest last — even though
  # it is the line with the *fewest* paid hours, which is what makes the order
  # worth asserting rather than reading off the line numbers.
  defp three_lines(world) do
    [1, 2, 3]
    |> Enum.zip([
      [{2, "2002"}],
      [{7, "7001"}],
      [{3, "2002"}, {5, "2002"}]
    ])
    |> Enum.map(&line(world, elem(&1, 1)))
  end

  describe "the add-to-line drawer" do
    setup :editor_setup

    test "asks for the day first when the run is open on several weekdays", context do
      {conn, world} = signed_in(context)
      _lines = three_lines(world)

      {:ok, view, _html} = live(conn, path(world))

      refute has_element?(view, "#rosters-add-to-line-drawer")
      view |> element("#rosters-add-to-line-2001") |> render_click()

      assert text(view, "#rosters-add-to-line-drawer-title") =~ "Add run 2001 to a line"
      assert text_of(view, "#rosters-add-lede") =~ "Weekday"
      assert text_of(view, "#rosters-add-lede") =~ "Mon–Fri"

      # The run's own figures, printed by the same helpers the grid prints them
      # with, so a run reads the same in both places.
      run = text_of(view, "#rosters-add-run")
      assert run =~ "Run 2001"
      assert run =~ "One piece"
      assert run =~ "5:35–15:35"
      assert run =~ "10:00 paid"

      # A run open on several weekdays has a day to choose before it has a line
      # to choose, and the choice leads: the first open day is pressed.
      assert text_of(view, "#rosters-add-day") =~ "Run 2001 is open on 5 days."
      assert has_element?(view, "#rosters-add-day-1[aria-pressed='true']")
      assert has_element?(view, "#rosters-add-day-2[aria-pressed='false']")
      assert has_element?(view, "#rosters-add-day-5[aria-pressed='false']")

      # Choosing another day re-reads the lines for that day, keeping the day
      # choice where the planner left it.
      view |> element("#rosters-add-day-5") |> render_click()
      assert attr_of(view, "#rosters-add-day-5", "aria-pressed") == "true"
      assert has_element?(view, "#rosters-add-line-rows")
    end

    test "asks for nothing when the run is open on one day", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-add-to-line-6001") |> render_click()

      refute has_element?(view, "#rosters-add-day")
      assert text_of(view, "#rosters-add-day-only") == "Open on Saturday only."

      # No line has Saturday off in this world, and the drawer says so rather
      # than drawing an empty list.
      assert has_element?(view, "#rosters-add-no-line")
      assert text(view, "#rosters-add-no-line") =~ "No line has Saturday off."
      assert has_element?(view, "#rosters-add-new-line")
    end

    test "lists the lines with that day off, rest-ok first, then by paid time", context do
      {conn, world} = signed_in(context)
      _lines = three_lines(world)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-add-to-line-2001") |> render_click()

      assert text_of(view, "#rosters-add-to-line-drawer") =~ "Lines with Monday off"

      # The order is `Candidates.lines_for_open_run/3`'s own, read off the
      # markup rather than re-derived here.
      assert offered_row_ids(view) == [
               "rosters-add-line-1",
               "rosters-add-line-3",
               "rosters-add-line-2"
             ]

      # The Sunday line is the one that would leave a short rest against, and
      # it is last even though it is the line with the fewest paid hours.
      assert short_lines(view) == ["rosters-add-line-2"]

      # Every row carries the rest either side: a day off is a muted em dash,
      # and the short side is marked in words as well as by the marker.
      assert attr_of(view, "#rosters-add-line-1", "data-selected") == "true"
      assert text_of(view, "#rosters-add-line-1") =~ "Line 1"
      assert text_of(view, "#rosters-add-line-1") =~ "1 day"
      assert text_of(view, "#rosters-add-line-1") =~ "20 h 10 min"

      assert text_of(view, "#rosters-add-line-2") =~ "8 h 15 min"
      assert has_element?(view, "#rosters-add-line-2 .rosters-rest-short")

      # The primary names the chosen line, so the button and the checked radio
      # cannot disagree about what is about to happen.
      assert text_of(view, "#rosters-add-confirm") == "Add to line 1"
    end

    test "choosing another line moves the primary's name", context do
      {conn, world} = signed_in(context)
      _lines = three_lines(world)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-add-to-line-2001") |> render_click()

      view |> element("#rosters-add-line-choice-3") |> render_click()

      assert attr_of(view, "#rosters-add-line-3", "data-selected") == "true"
      assert text_of(view, "#rosters-add-confirm") == "Add to line 3"
    end
  end

  describe "adding a run to a line" do
    setup :editor_setup

    test "saves the slot and closes the drawer", context do
      {conn, world} = signed_in(context)
      [first | _rest] = three_lines(world)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-add-to-line-2001") |> render_click()
      view |> element("#rosters-add-confirm") |> render_click()

      # Re-read: the stored row names the run and the weekday's own base day
      # type, written through the real writer under the lock.
      assert stored_day_row(world, first, 1) == {"2001", day_type_key(world, "Weekday")}

      # The grid redrew from the reloaded composition, so the day it holds the
      # run is the day's own cell.
      assert has_element?(view, "#slot-1-1[data-slot='work']", "2001")

      # The drawer closed: the run is no longer open on Monday, and a week the
      # planner has finished with should not stay on screen.
      refute has_element?(view, "#rosters-add-to-line-drawer")
      assert has_element?(view, "#rosters-toast", "Added run 2001 to line 1 on Monday.")

      # And the run is still open on the rest of its group, which is what the
      # card's remaining chips say.
      assert attr_of(view, ".rosters-open-run[data-run='2001']", "data-open-days") == "2 3 4 5"
    end

    test "a refusal shows its reason in the drawer and writes nothing", context do
      {conn, world} = signed_in(context)
      [first | _rest] = three_lines(world)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-add-to-line-2001") |> render_click()

      # The drawer was drawn from a roster in which the run was open on Monday.
      # Another line takes it there while the page is open, which is the only
      # way the writer can refuse.
      _taken = line(world, [{1, "2001"}])

      view |> element("#rosters-add-confirm") |> render_click()

      # The refusal is the writer's own sentence, in the drawer, with the drawer
      # still open: a refusal that closes a drawer reads as losing the work.
      assert text_of(view, "#rosters-add-refusal") =~ "Run 2001 is in line 4 on Mon."

      # Nothing was saved: the chosen line still has the one day it had.
      assert stored_days(world, first) == [2]
      assert stored_day_row(world, first, 1) == nil
      assert has_element?(view, "#rosters-add-to-line-drawer")
    end
  end

  describe "creating a line for an open run" do
    setup :editor_setup

    test "creates a line holding the run on that day", context do
      {conn, world} = signed_in(context)
      _existing = line(world, [{7, "7001"}])

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-add-to-line-2001") |> render_click()

      assert line_numbers(world) == [1]
      view |> element("#rosters-add-new-line") |> render_click()

      # The next line number, and exactly one day on it: this is a line holding
      # the run on the day that was chosen, not a Mon–Fri line.
      assert line_numbers(world) == [1, 2]
      created = line_id(world, 2)
      assert stored_days(world, created) == [1]
      assert stored_day_row(world, created, 1) == {"2001", day_type_key(world, "Weekday")}

      refute has_element?(view, "#rosters-add-to-line-drawer")
      assert has_element?(view, "#rosters-toast", "Line 2 created with run 2001 on Monday.")
      assert has_element?(view, "#slot-2-1[data-slot='work']", "2001")
    end

    test "no card offers the drawer while the roster is paused", context do
      {conn, world} = signed_in(context)

      # A failed refresh is the pause: the last roster stays on screen and its
      # controls are off, because the writers read a roster that is no longer
      # being kept fresh. The adapter answers the mount's real read and refuses
      # the next one, so the content on screen provably came from a real read.
      {:ok, view_model} = Gtfs.load_roster(world.organization.id, world.version.id)
      refuse = install_pausing_adapter(view_model)

      {:ok, view, _html} = live(conn, path(world))
      assert has_element?(view, "#rosters-add-to-line-2001")

      # Arm the failure only once the page is up, so the mount's own read is a
      # real one whatever the mount happens to make.
      Agent.update(refuse, &Map.put(&1, :armed?, true))
      render_click(view, "retry_load", %{})

      assert has_element?(view, "#rosters-unavailable")
      refute has_element?(view, "#rosters-add-to-line-2001")
    end
  end

  # Every read answers with the composition the production adapter just
  # produced, so the content on screen came from a real read; only a read after
  # `:armed?` is set is refused, which is what makes the mount's own read real
  # however many reads it makes.
  defp install_pausing_adapter(view_model) do
    previous = Application.fetch_env(:gtfs_planner, :gtfs_catalog_read_adapter)
    Application.put_env(:gtfs_planner, :gtfs_catalog_read_adapter, CatalogReadAdapterMock)

    {:ok, state} = Agent.start_link(fn -> %{armed?: false} end)

    Mox.stub(CatalogReadAdapterMock, :load_roster, fn _organization_id, _version_id ->
      if Agent.get(state, & &1.armed?) do
        {:error, :unavailable}
      else
        {:ok, view_model}
      end
    end)

    on_exit(fn -> restore(previous) end)

    state
  end

  defp restore({:ok, value}),
    do: Application.put_env(:gtfs_planner, :gtfs_catalog_read_adapter, value)

  defp restore(:error), do: Application.delete_env(:gtfs_planner, :gtfs_catalog_read_adapter)
end
