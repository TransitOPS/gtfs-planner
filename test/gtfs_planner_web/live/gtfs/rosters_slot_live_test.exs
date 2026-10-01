defmodule GtfsPlannerWeb.Gtfs.RostersSlotLiveTest do
  @moduledoc """
  The slot drawer: choosing the run one weekday of one line works.

  Every button here reaches the real writer — `Gtfs.set_roster_slot/4`,
  `set_roster_weekday_group/4`, `clear_roster_slot/3` — and every stored row is
  re-read through `Gtfs.load_roster/2` afterwards, so "the grid shows it" and
  "the row says it" are two independent reads rather than one rendering.

  ## The world

  The shared fixture and the three extra blocks are the grid test's
  (`rosters_grid_live_test.exs`), because this page needs the same three states
  the grid has to draw and cannot invent its own: a weekday day type over
  Saturday and Sunday, a run that signs off after midnight, and the late Sunday
  run that leaves under ten hours of rest before the weekday morning sign-on.
  That last pair is what makes "Set Mon–Fri" refuse, and it is reached the same
  way production reaches it: two single-day writes rather than a group write,
  because a manual per-day edit is allowed to leave short rest.

  A run can be held on a weekday by only one line, so each test builds only the
  lines it is about.
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

  # An element's own text, with the markup out of it. `render/2` returns the
  # element's HTML, which is the right thing to assert a class or an attribute
  # on and the wrong thing to assert that something is *empty*.
  defp text_of(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  # The stored rows, re-read. A test that trusts the page after a write proves
  # the page rendered what it was told, not that anything was written.
  defp stored_day(world, line_id, weekday) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    line = Enum.find(roster.lines, &(&1.id == line_id))

    case line && Map.get(line.slots, weekday) do
      nil -> nil
      slot -> slot.run_id
    end
  end

  defp stored_days(world, line_id) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    line = Enum.find(roster.lines, &(&1.id == line_id))

    line |> Map.fetch!(:slots) |> Map.keys() |> Enum.sort()
  end

  # The run that a weekday's group still has open, read from the composition's
  # own open work rather than from anything the drawer decided.
  defp open_run_ids(world, weekday) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    for group <- roster.groups,
        weekday in group.weekdays,
        open <- group.open_runs,
        weekday in open.open_weekdays,
        do: open.run_id
  end

  # The line that holds a run on a weekday, or `nil`.
  defp holder(world, weekday, run_id) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    Enum.find_value(roster.lines, fn line ->
      case Map.get(line.slots, weekday) do
        %{run_id: ^run_id} -> line.line_number
        _other -> nil
      end
    end)
  end

  describe "opening a slot" do
    setup :editor_setup

    test "opens the drawer with the week's candidates and their rest", context do
      {conn, world} = signed_in(context)
      {line_id, number} = line(world, [{7, "7001"}, {2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      html =
        view
        |> element("#slot-#{number}-1")
        |> render_click()

      assert html =~ "rosters-slot-drawer"
      assert has_element?(view, "#rosters-slot-drawer")

      # The title names the line and the day, so a reader who opened the wrong
      # cell knows it before reading anything else.
      assert text(view, "#rosters-slot-drawer-title") =~ "Line #{number}"
      assert text(view, "#rosters-slot-drawer-title") =~ "Monday"

      # The week strip draws all seven days and marks the one being changed.
      assert has_element?(view, "#rosters-slot-week", "7001")
      assert has_element?(view, "#rosters-slot-week [aria-current='true']")

      # Monday's open runs are both offered, with the four figures a planner
      # chooses by: sign-on, sign-off, paid and the rest either side.
      assert has_element?(view, "#rosters-slot-run-2001")
      assert has_element?(view, "#rosters-slot-run-2002")
      assert has_element?(view, "#rosters-slot-row-2001", "5:35")
      assert has_element?(view, "#rosters-slot-row-2001", "15:35")

      row = text(view, "#rosters-slot-row-2001")
      assert row =~ "One piece"
      # Sunday's late run leaves this under the ten hours it asks for, so the
      # cell is measured *and* marked: the triangle is what a reader scanning the
      # column is looking for, and the words behind it are what a screen reader
      # needs.
      assert row =~ "8 h 15 min"
      assert row =~ "△"
      assert row =~ "under the minimum"

      # A run that keeps every rest is measured and not marked, so the column
      # says which candidate fits rather than which one is merely listed.
      midday = text(view, "#rosters-slot-row-2002")
      assert midday =~ "14 h 25 min"
      refute midday =~ "under the minimum"

      # A run already on the line that day is labelled as the current one.
      assert text(view, "#rosters-slot-lede") =~ "working days"

      # The drawer opens for the line the click named, not for the first line.
      assert has_element?(view, "#rosters-slot-drawer")
      assert line_id
    end

    test "a day off offers the day's runs and no Clear day", context do
      {conn, world} = signed_in(context)
      {_line_id, number} = line(world, [{1, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#slot-#{number}-3") |> render_click()

      assert has_element?(view, "#rosters-slot-run-2001")
      refute has_element?(view, "#rosters-clear-day")
      assert has_element?(view, "#rosters-set-day", "Set Wednesday to run")
    end

    test "a weekday with no base day type has no drawer", context do
      {conn, world} = signed_in(context)
      {_line_id, number} = line(world, [{1, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      # Sunday has a base day type here, so a day that cannot be set is reached
      # the way a hand-built event reaches it: with a weekday outside the week.
      render_click(view, "open_slot", %{"line" => number, "weekday" => "9"})

      refute has_element?(view, "#rosters-slot-drawer")

      # A line this roster does not hold is not a drawer either.
      render_click(view, "open_slot", %{"line" => Ecto.UUID.generate(), "weekday" => "1"})

      refute has_element?(view, "#rosters-slot-drawer")
    end

    test "closing the drawer takes it off the page", context do
      {conn, world} = signed_in(context)
      {_line_id, number} = line(world, [{1, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#slot-#{number}-1") |> render_click()
      assert has_element?(view, "#rosters-slot-drawer")

      view |> element("#rosters-slot-drawer-close") |> render_click()
      refute has_element?(view, "#rosters-slot-drawer")
    end
  end

  describe "the group action" do
    setup :editor_setup

    test "is disabled with the Candidates refusal when the group would be short", context do
      {conn, world} = signed_in(context)
      # The seeded short rest: 7001 signs off Sunday at 21:15 and the early
      # weekday run signs on Monday at 05:35, under the ten hours this version
      # asks for. The line works Sunday only, so Monday is the day the planner
      # is choosing a run for.
      {line_id, number} = line(world, [{7, "7001"}])

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#slot-#{number}-1") |> render_click()
      # The early run is the one the group cannot take: five of them would leave
      # the Sunday run with under ten hours' rest before Monday's sign-on.
      view |> element("#rosters-slot-run-2001") |> render_click()

      # The action is on screen, disabled, with the reason under it — the
      # planner is not left looking for a control that has vanished.
      assert has_element?(view, "#rosters-set-group[disabled]", "Set Mon–Fri to run 2001")

      reason = text(view, "#rosters-group-reason")
      assert reason =~ "Sun → Mon would leave 8 h 15 min of rest after run 2001"
      assert reason =~ "minimum 10 h."
      assert reason =~ "Set Monday alone to keep it as a warning."

      # The day's own action is available and says what it will do: this refusal
      # is about the group, not about the day.
      assert has_element?(view, "#rosters-set-day", "Set Monday to run 2001")

      # Nothing was written by looking, and the drawer is still the one the
      # planner opened.
      assert stored_day(world, line_id, 1) == nil
      assert stored_days(world, line_id) == [7]
    end

    test "fills Mon–Fri when the group is available", context do
      {conn, world} = signed_in(context)
      # Tuesday on the midday run leaves every adjacent pair a full day or more
      # apart, so Monday–Friday on the same run keeps every rest.
      {line_id, number} = line(world, [{2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#slot-#{number}-1") |> render_click()
      view |> element("#rosters-slot-run-2002") |> render_click()

      assert has_element?(view, "#rosters-set-group", "Set Mon–Fri to run 2002")
      refute has_element?(view, "#rosters-set-group[disabled]")
      # An available action carries no reason and does not point at one.
      refute has_element?(view, "#rosters-set-group[aria-describedby]")
      assert text_of(view, "#rosters-group-reason") == ""

      view |> element("#rosters-set-group") |> render_click()

      refute has_element?(view, "#rosters-slot-drawer")

      # The whole group, written in one transaction: five rows, not one day and
      # four promises.
      assert stored_days(world, line_id) == [1, 2, 3, 4, 5]

      for weekday <- 1..5 do
        assert stored_day(world, line_id, weekday) == "2002"
      end

      assert has_element?(view, "#rosters-toast", "Set Mon–Fri to run 2002")
    end
  end

  describe "setting one day" do
    setup :editor_setup

    test "saves, closes the drawer and shows the short rest on the grid", context do
      {conn, world} = signed_in(context)
      {line_id, number} = line(world, [{7, "7001"}])

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#slot-#{number}-1") |> render_click()
      view |> element("#rosters-slot-run-2001") |> render_click()

      assert has_element?(view, "#rosters-set-day", "Set Monday to run 2001")

      view |> element("#rosters-set-day") |> render_click()

      refute has_element?(view, "#rosters-slot-drawer")

      # The row says it, re-read: a manual per-day edit is allowed to leave the
      # short rest the group action would have refused.
      assert stored_day(world, line_id, 1) == "2001"

      assert has_element?(view, "#slot-#{number}-1[data-slot='work']", "2001")
      assert has_element?(view, "#slot-#{number}-1[data-warning='short-rest']")
      assert has_element?(view, "#rosters-toast", "Sun → Mon")

      problems =
        text(view, "#rosters-grid tr[id='rosters-line-#{number}'] .rosters-problems")

      assert problems =~ "Short rest Sun → Mon"
    end

    test "a stale slot's drawer says why, with both sets of times", context do
      {conn, world} = signed_in(context)
      {line_id, number} = line(world, [{3, "2002"}])

      # What a re-cut does: the run is still there and still derives, but it
      # signs on ten minutes earlier than the row was set with (INV-13). The
      # stored time is the only way production reaches this state, because every
      # writer stores the run's current times.
      day =
        Repo.one!(
          from(d in RosterLineDay,
            where:
              d.roster_line_id == ^line_id and d.weekday == ^3 and
                d.organization_id == ^world.organization.id and
                d.gtfs_version_id == ^world.version.id
          )
        )

      day
      |> Ecto.Changeset.change(%{run_sign_on_secs: day.run_sign_on_secs - 600})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#slot-#{number}-3") |> render_click()

      stale = text(view, "#rosters-slot-stale")
      assert stale =~ "Run 2002 is stale."
      assert stale =~ "changed since it was set"
      # Both ends, so the difference is one the planner can see rather than a
      # word they have to trust.
      assert stale =~ "was "
      assert stale =~ "now "
      assert stale =~ "Set Wednesday to run 2002 to keep it with the new times"

      # The day's own action re-sets the same run, which is how a re-cut is
      # accepted. The group action is still offered: the stale row names the same
      # run, so filling Mon–Fri with it changes nothing but the stored times.
      assert has_element?(view, "#rosters-set-day", "Set Wednesday to run 2002")
      assert has_element?(view, "#rosters-set-group", "Set Mon–Fri to run 2002")

      view |> element("#rosters-set-day") |> render_click()

      assert has_element?(view, "#slot-#{number}-3[data-slot='work']")
      refute has_element?(view, "#slot-#{number}-3[data-slot='stale']")
    end

    test "a run taken by a direct write shows the held-by reason and writes nothing", context do
      {conn, world} = signed_in(context)
      # A line working the late Sunday run only, so Monday is free and the
      # weekday group is available for a run another line has not taken.
      {line_id, number} = line(world, [{7, "7001"}])

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#slot-#{number}-1") |> render_click()
      # The after-midnight run keeps every rest against a Sunday-only line, so
      # the group action is available when the drawer opens.
      view |> element("#rosters-slot-run-2004") |> render_click()
      refute has_element?(view, "#rosters-set-group[disabled]")

      # Another line takes run 2004 on Monday while the drawer is open. The
      # drawer is showing a roster that was read before that write, so the only
      # thing that can catch it is the writer's own availability.
      {:ok, %{id: other}} = Gtfs.create_roster_line(world_audit(world))

      assert {:ok, _taken} =
               Gtfs.set_roster_slot(world_audit(world), other, 1, "2004")

      view |> element("#rosters-set-group") |> render_click()

      # The refusal is in the drawer, in the writer's own words, and nothing was
      # written: the group's Monday still holds nothing and Tuesday to Friday
      # were not filled either.
      assert has_element?(view, "#rosters-slot-refusal")
      refusal = text(view, "#rosters-slot-refusal")
      assert refusal =~ "Run 2004 is in line #{line_number(world, other)} on Mon."

      assert stored_day(world, line_id, 1) == nil
      assert stored_days(world, line_id) == [7]
      assert holder(world, 1, "2004") == line_number(world, other)
    end
  end

  describe "clearing a day" do
    setup :editor_setup

    test "removes the row and returns the run to open work", context do
      {conn, world} = signed_in(context)
      {line_id, number} = line(world, [{3, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#slot-#{number}-3") |> render_click()
      assert has_element?(view, "#rosters-clear-day")

      view |> element("#rosters-clear-day") |> render_click()

      refute has_element?(view, "#rosters-slot-drawer")
      assert stored_day(world, line_id, 3) == nil
      assert stored_days(world, line_id) == []

      assert has_element?(view, "#slot-#{number}-3[data-slot='off']", "Off")
      assert "2002" in open_run_ids(world, 3)
    end
  end
end
