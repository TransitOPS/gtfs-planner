defmodule GtfsPlannerWeb.Gtfs.RostersFilterLiveTest do
  @moduledoc """
  The grid's filter and its three orders, as URL params.

  Everything asserted here is asserted through a URL: `?filter=`, `?sort=` and
  `?dir=` are read in `handle_params/3` and nowhere else, so a link is the same
  page as the click that produced it, and both are the thing under test. The
  world is written through the same writers the page uses —
  `Gtfs.create_roster_line/2`, `Gtfs.set_roster_slot/5` and
  `Gtfs.assign_roster_operator/4` — over `RunsFixtures.runs_version_fixture/1`,
  so a filter or an order can never be right about rows the page never had.

  ## The world

  The shared fixture is one weekday calendar with two blocks, plus a Saturday and
  a Sunday calendar and three more weekday blocks, which is the world step 26's
  grid test builds and the reason it is repeated here rather than shared: a run
  can be held on a weekday by only one line, so a shared world would make this
  file's lines collide with that file's. The runs differ in length, which is what
  makes `?sort=paid` mean something — `2001` is a ten-hour platform day, `2002` a
  short midday one and `2004` a late one.

  Every test builds only the lines it is about, and each test that needs a stale
  slot reaches it the way production does: the weekday's base day type no longer
  resolves the row's own, which is what a re-cut does (INV-13).

  Asserted on element IDs, `data-*` attributes, `aria-sort` and `LazyHTML`,
  never on raw HTML. Rows are created inside the SQL Sandbox transaction and
  rolled back.
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
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo

  setup :verify_on_exit!

  defp editor_setup(_context), do: %{user: user_fixture()}

  defp world do
    world = runs_version_fixture()

    # Every weekday flag is named: `calendar_service_fixture/3` fills the ones a
    # caller leaves out from the weekday defaults, so a Saturday calendar that
    # named only `:saturday` would also run Monday to Friday and the day types
    # would merge into one.
    for calendar <- [
          %{
            service_id: "SAT",
            name: "Saturday",
            monday: 0,
            tuesday: 0,
            wednesday: 0,
            thursday: 0,
            friday: 0,
            saturday: 1,
            sunday: 0
          },
          %{
            service_id: "SUN",
            name: "Sunday",
            monday: 0,
            tuesday: 0,
            wednesday: 0,
            thursday: 0,
            friday: 0,
            saturday: 0,
            sunday: 1
          }
        ] do
      attrs = Map.put(Map.put(calendar, :start_date, ~D[2026-01-01]), :end_date, ~D[2026-12-31])

      calendar_service_fixture(world.organization.id, world.version.id, attrs)
    end

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

  # The three weekday blocks differ in length on purpose: a paid order over runs
  # of the same length would be the line-number order wearing another name.
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

  defp rosters_url(world, query \\ ""), do: "/gtfs/#{world.version.id}/rosters#{query}"

  # Builds one line working the given `{weekday, run_id}` days and returns its id
  # and line number, which is what every assertion below addresses the row by.
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

    {line_id, line_number(world, line_id)}
  end

  defp line_number(world, line_id) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    Enum.find_value(roster.lines, fn built ->
      if built.id == line_id, do: built.line_number
    end)
  end

  defp operator(world, actor, employee_id, name) do
    {:ok, operator} =
      Operations.create_operator(world.organization.id, actor, %{
        employee_id: employee_id,
        display_name: name
      })

    operator
  end

  defp assign_operator(world, line_id, operator_id) do
    assert {:ok, _line} =
             Gtfs.assign_roster_operator(
               world.organization.id,
               world.version.id,
               line_id,
               operator_id
             )
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

  # The line numbers on screen, in the order the grid drew them. This is the
  # order itself, so a test reads "paid descending" rather than "this row is
  # above that one". The grid's other rows — the pick row and the row a filter
  # that matched nothing draws — are not line rows and are not counted here.
  defp row_numbers(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#rosters-grid-body > tr[id^='rosters-line-']")
    |> Enum.map(fn node ->
      id = node |> LazyHTML.attribute("id") |> hd()
      Regex.replace(~r/^rosters-line-/, id, "") |> String.to_integer()
    end)
  end

  defp filter_labels(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#rosters-filter label")
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.map(&String.trim/1)
  end

  describe "the filter row" do
    setup :editor_setup

    test "?filter=open shows only the lines nobody has picked", context do
      {conn, world} = signed_in(context)
      {_open_id, open_number} = line(world, [{1, "2001"}])
      {taken_id, taken_number} = line(world, [{2, "2002"}])
      assign_operator(world, taken_id, operator(world, context.user, "E9101", "Ada Okafor").id)

      {:ok, view, _html} = live(conn, rosters_url(world))
      assert Enum.sort(row_numbers(view)) == Enum.sort([open_number, taken_number])

      {:ok, view, _html} = live(conn, rosters_url(world, "?filter=open"))

      assert row_numbers(view) == [open_number]
      refute has_element?(view, "#rosters-line-#{taken_number}")
      # The filter says how many rows it left, in the same words as the strip.
      assert has_element?(view, "#rosters-filter-count", "Showing 1 of 2 lines")

      # Back to all, and the option is where the reader last left it.
      {:ok, view, _html} = live(conn, rosters_url(world))
      assert row_numbers(view) == Enum.sort([open_number, taken_number])
    end

    test "?filter=problems shows only the lines the composition has findings for", context do
      {conn, world} = signed_in(context)

      # Monday to Thursday leaves Friday, Saturday and Sunday off together, which is
      # the only way a line has no finding at all: the composition asks for a
      # pair of days off, not for the absence of an awkward one.
      {_clean_id, clean_number} =
        line(world, [{1, "2002"}, {2, "2002"}, {3, "2002"}, {4, "2002"}])

      # Monday, Wednesday, Friday and Saturday leaves Tuesday, Thursday and Sunday off
      # on their own, and a pair of days off in a row is what the composition
      # asks for: a line with none has a finding in words. Sunday stays off
      # because working it would put the late Sunday run in front of the Monday
      # sign-on, and the short rest would be the finding said instead.
      {_rest_id, rest_number} =
        line(world, [{1, "2001"}, {3, "2001"}, {5, "2001"}, {6, "6001"}])

      {:ok, view, _html} = live(conn, rosters_url(world))

      refute has_element?(
               view,
               "#rosters-line-#{clean_number} .rosters-problems",
               "Days off apart"
             )

      assert has_element?(
               view,
               "#rosters-line-#{rest_number} .rosters-problems",
               "Days off apart"
             )

      {:ok, view, _html} = live(conn, rosters_url(world, "?filter=problems"))

      assert row_numbers(view) == [rest_number]
      refute has_element?(view, "#rosters-line-#{clean_number}")
    end

    test "?filter=stale shows only the lines with a stale slot", context do
      {conn, world} = signed_in(context)
      {stale_id, stale_number} = line(world, [{3, "2002"}])
      remove_base_week_day(world, stale_id, 3)

      {_fresh_id, fresh_number} = line(world, [{4, "2001"}])

      {:ok, view, _html} = live(conn, rosters_url(world, "?filter=stale"))

      assert row_numbers(view) == [stale_number]
      refute has_element?(view, "#rosters-line-#{fresh_number}")
    end

    test "the Stale option is absent while nothing is stale, and present when something is",
         context do
      {conn, world} = signed_in(context)
      {_line_id, number} = line(world, [{1, "2001"}])

      {:ok, view, _html} = live(conn, rosters_url(world))

      refute has_element?(view, "#rosters-filter-option-stale")
      assert filter_labels(view) == ["All lines 1", "Open lines 1", "Lines with problems 0"]

      {:ok, stale_line} = Gtfs.create_roster_line(world.organization.id, world.version.id)

      assert {:ok, _result} =
               Gtfs.set_roster_slot(
                 world.organization.id,
                 world.version.id,
                 stale_line.id,
                 2,
                 "2004"
               )

      remove_base_week_day(world, stale_line.id, 2)

      {:ok, view, _html} = live(conn, rosters_url(world))
      assert has_element?(view, "label[for='rosters-filter-option-stale']", "Stale slots 1")
      # The row it names is on screen: the count beside the option is the
      # composition's own, not a second count.
      assert has_element?(view, "#rosters-line-#{number}")
    end

    test "a filter that matches nothing says so instead of drawing an empty week", context do
      {conn, world} = signed_in(context)
      line(world, [{1, "2001"}])

      {:ok, view, _html} = live(conn, rosters_url(world, "?filter=problems"))

      assert row_numbers(view) == []
      assert has_element?(view, "#rosters-show-all", "Show all lines")
    end
  end

  describe "the orderable headers" do
    setup :editor_setup

    test "?sort=paid&dir=desc orders the rows by weekly paid, longest first", context do
      {conn, world} = signed_in(context)
      {_short_id, short_number} = line(world, [{2, "2002"}])
      {_long_id, long_number} = line(world, [{1, "2001"}])
      {_evening_id, evening_number} = line(world, [{6, "6001"}])

      {:ok, view, _html} = live(conn, rosters_url(world, "?sort=paid&dir=desc"))

      # 2001 is the ten-hour platform day, 6001 a short Saturday morning and
      # 2002 a short midday one, so the order is the order of the week rather
      # than the order the lines were created in.
      assert row_numbers(view) == [long_number, evening_number, short_number]

      # The header says which way the column is ordered, and only that one does.
      assert has_element?(view, "#rosters-grid thead th[aria-sort='descending']", "Weekly paid")
      assert has_element?(view, "#rosters-grid thead th[aria-sort='none']", "Line")
      assert has_element?(view, "#rosters-grid thead th[aria-sort='none']", "Operator")

      {:ok, view, _html} = live(conn, rosters_url(world, "?sort=paid&dir=asc"))
      assert row_numbers(view) == [short_number, evening_number, long_number]

      # Every row is still a whole week: an order is a re-order, not a
      # projection.
      for number <- [long_number, short_number, evening_number], weekday <- 1..7 do
        assert has_element?(view, "#slot-#{number}-#{weekday}")
      end
    end

    test "?sort=operator orders by display name with the open lines last", context do
      {conn, world} = signed_in(context)
      zoe = operator(world, context.user, "E9202", "Zoe Adeyemi")
      amal = operator(world, context.user, "E9203", "Amal Yusuf")

      {z_id, z_number} = line(world, [{1, "2001"}])
      assign_operator(world, z_id, zoe.id)

      {a_id, a_number} = line(world, [{2, "2002"}])
      assign_operator(world, a_id, amal.id)

      {_open_id, open_number} = line(world, [{3, "2004"}])

      {:ok, view, _html} = live(conn, rosters_url(world, "?sort=operator"))

      # Names ascending, and the line nobody picked last in both directions.
      assert row_numbers(view) == [a_number, z_number, open_number]

      {:ok, view, _html} = live(conn, rosters_url(world, "?sort=operator&dir=desc"))
      assert row_numbers(view) == [z_number, a_number, open_number]
    end

    test "an unknown sort or filter is the default, not an error", context do
      {conn, world} = signed_in(context)
      {_first_id, first_number} = line(world, [{1, "2001"}])
      {_second_id, second_number} = line(world, [{2, "2002"}])

      {:ok, view, _html} =
        live(conn, rosters_url(world, "?filter=nonsense&sort=nonsense&dir=sideways"))

      assert row_numbers(view) == Enum.sort([first_number, second_number])
      assert has_element?(view, "#rosters-filter-option-all[checked]")
      assert has_element?(view, "#rosters-grid thead th[aria-sort='ascending']", "Line")
    end
  end

  describe "the URL" do
    setup :editor_setup

    test "a filter option patches the URL and drops the defaults", context do
      {conn, world} = signed_in(context)
      line(world, [{1, "2001"}])

      {:ok, view, _html} = live(conn, rosters_url(world))
      assert has_element?(view, "#rosters-filter-option-all[checked]")

      view
      |> form("#rosters-filter-form", %{"filter" => "problems"})
      |> render_change()

      assert_patched(view, rosters_url(world, "?filter=problems"))
      assert has_element?(view, "#rosters-filter-option-problems[checked]")
      # `filter=all&sort=line&dir=asc` is not what the address bar says, so the
      # URL a reader copies for the default view is the short one.
      refute has_element?(view, "#rosters-filter-option-all[checked]")
    end

    test "a header patches the URL and keeps the filter", context do
      {conn, world} = signed_in(context)
      line(world, [{1, "2001"}])

      {:ok, view, _html} = live(conn, rosters_url(world, "?filter=open"))

      view |> element("#rosters-grid thead th button[phx-value-key='paid']") |> render_click()
      assert_patched(view, rosters_url(world, "?filter=open&sort=paid"))

      # The same header again reverses it.
      view |> element("#rosters-grid thead th button[phx-value-key='paid']") |> render_click()
      assert_patched(view, rosters_url(world, "?filter=open&sort=paid&dir=desc"))

      # A different header starts ascending again, and the filter is still there.
      view |> element("#rosters-grid thead th button[phx-value-key='operator']") |> render_click()
      assert_patched(view, rosters_url(world, "?filter=open&sort=operator"))
    end

    test "the stale message's control patches the same URL as the filter row", context do
      {conn, world} = signed_in(context)
      {:ok, stale_line} = Gtfs.create_roster_line(world.organization.id, world.version.id)

      assert {:ok, _result} =
               Gtfs.set_roster_slot(
                 world.organization.id,
                 world.version.id,
                 stale_line.id,
                 2,
                 "2004"
               )

      remove_base_week_day(world, stale_line.id, 2)

      {:ok, view, _html} = live(conn, rosters_url(world, "?sort=paid"))

      assert has_element?(view, "#rosters-stale-message")
      view |> element("#rosters-stale-message button[phx-click='show_stale']") |> render_click()
      assert_patched(view, rosters_url(world, "?filter=stale&sort=paid"))
    end
  end
end
