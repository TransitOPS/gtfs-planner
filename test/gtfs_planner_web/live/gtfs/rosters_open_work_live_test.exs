defmodule GtfsPlannerWeb.Gtfs.RostersOpenWorkLiveTest do
  @moduledoc """
  Open work: the groups of runs still open, "Create Mon–Fri line" on a card, and
  the head's "Add line".

  Every button here reaches the real writer — `Gtfs.create_roster_line_from_run/4`
  and `create_roster_line/2` — and every stored row is re-read through
  `Gtfs.load_roster/2` or read straight out of `roster_line_days` afterwards, so
  "the grid shows it" and "the row says it" are two independent reads rather
  than one rendering.

  ## The world

  The same fixture the slot drawer test builds (`rosters_slot_live_test.exs`):
  a weekday day type over Monday to Friday, a Saturday and a Sunday day type, a
  run that signs off after midnight, and the late Sunday run that leaves under
  ten hours of rest before the weekday morning sign-on. Open work needs the
  same three states the drawer needs, because a card is only as real as the runs
  behind it.

  ## What each case is really asserting

  - The groups are the composition's own `Roster.groups`, so a group's label,
    its day type and its open run-day count are read, not re-derived.
  - The create button is `Candidates.new_line_availability/3`'s answer, so a run
    open on every weekday of its group has one and a run open on only some does
    not. A refusal by the writer is shown on the card and writes nothing.
  - "Add line" creates the next numbered line and opens its Monday drawer, so
    the head's entry point is not a dead end.
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

  # An attribute read off the live markup, so a case can assert about the
  # structure rather than about the words around it.
  defp attr_of(view, selector, attribute) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
    |> List.first()
  end

  # The line numbers the composition holds, in the order it holds them.
  defp line_numbers(world) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    Enum.map(roster.lines, & &1.line_number)
  end

  defp line_id(world, number) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    Enum.find_value(roster.lines, fn built ->
      if built.line_number == number, do: built.id
    end)
  end

  defp stored_days(world, id) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)

    roster.lines
    |> Enum.find(&(&1.id == id))
    |> Map.fetch!(:slots)
    |> Map.keys()
    |> Enum.sort()
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

  defp day_type_key(world, label) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    Enum.find_value(day.day_types, fn day_type ->
      if day_type.label == label, do: day_type.key
    end)
  end

  # Each group's open run-day count, read from the markup's own words so the
  # assertion is about what a reader sees rather than about a map key.
  defp group_counts(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#rosters-open-work div[id^='rosters-open-group-']")
    # The "every run is in a line" panel shares the id prefix; a group is the
    # one that has a heading.
    |> Enum.filter(fn node -> node |> LazyHTML.query("h3") |> Enum.count() == 1 end)
    |> Enum.map(fn node ->
      heading = node |> LazyHTML.query("h3") |> LazyHTML.text() |> String.trim()
      [label | _rest] = String.split(heading, "·")
      {String.trim(label), count_from(LazyHTML.text(node))}
    end)
    |> Map.new()
  end

  defp count_from(text) do
    case Regex.run(~r/(\d+) open run-days?/, text) do
      [_all, count] -> String.to_integer(count)
      nil -> 0
    end
  end

  describe "the open-work section" do
    setup :editor_setup

    test "lists one group per base day type with its label and open run-days", context do
      {conn, world} = signed_in(context)

      # A weekday run taken on Monday only: the weekday group keeps the run on
      # screen, one day shorter, which is what makes the count beside the label
      # worth having.
      _held = line(world, [{1, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      assert has_element?(view, "#rosters-open-work")

      # The weekday group names the range and the day type it resolves to, in
      # the base week's own words.
      weekday_heading = text_of(view, "#rosters-open-work h3")
      assert weekday_heading =~ "Mon–Fri"
      assert weekday_heading =~ "Weekday"

      # Its open run-days are the composition's own: three weekday runs over
      # five weekdays each, less the one Monday slot a line took. Saturday and
      # Sunday each hold one run on one day.
      assert group_counts(view) == %{"Mon–Fri" => 14, "Sat" => 1, "Sun" => 1}

      # The section's own sentence says what the actions on a card are, so a
      # reader arriving from the first-use panel knows what they can do.
      intro = text_of(view, "#rosters-open-work p")
      assert intro =~ "Runs not yet in a line."
      assert intro =~ "Create a Mon–Fri line"
    end

    test "an open run's card carries its run, its times and its open weekdays", context do
      {conn, world} = signed_in(context)
      _held = line(world, [{1, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      card = text_of(view, ".rosters-open-run[data-run='2001']")
      assert card =~ "Run 2001"
      assert card =~ "One piece"
      # The same clock the grid prints, so a run reads the same in both places.
      assert card =~ "5:35–15:35"
      assert card =~ "paid"

      # The chips say which weekdays of the group the run is still open on, and
      # `data-open-days` says the same thing to a test without parsing chips.
      assert attr_of(view, ".rosters-open-run[data-run='2001']", "data-open-days") == "1 2 3 4 5"

      assert attr_of(view, ".rosters-open-run[data-run='2002']", "data-open-days") == "2 3 4 5"

      chips = text_of(view, ".rosters-open-run[data-run='2002'] .rosters-day-chips")
      assert chips =~ "Tue"
      assert chips =~ "Fri"

      # The taken Monday chip is struck through rather than dropped, so the
      # group still reads as five days with one of them gone.
      assert has_element?(
               view,
               ".rosters-open-run[data-run='2002'] .rosters-day-chip-taken"
             )
    end

    test "a group whose runs are all placed says so instead of drawing cards", context do
      {conn, world} = signed_in(context)
      # Saturday has one run; placing it empties the group.
      line(world, [{6, "6001"}])

      {:ok, view, _html} = live(conn, path(world))

      refute has_element?(view, ".rosters-open-run[data-run='6001']")
      assert text(view, "#rosters-open-work [id$='-clear']") =~ "Every Saturday run is in a line."
    end

    test "a version with no lines at all still shows open work", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, path(world))

      # The first-use panel points here, so the region it names has to be on the
      # same page; with no lines there is no grid above it.
      assert has_element?(view, "#rosters-first-use")
      assert has_element?(view, "#rosters-go-to-open-work")
      assert has_element?(view, "#rosters-open-work")
      assert has_element?(view, "#rosters-create-line-2001")
    end
  end

  describe "creating a line from a run" do
    setup :editor_setup

    test "creates the next line holding that run on the whole group", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, path(world))

      assert [] == line_numbers(world)
      # 2004 signs off after midnight and keeps its rest against its own
      # consecutive days, so the builder's own answer is available.
      assert has_element?(view, "#rosters-create-line-2004", "Create Mon–Fri line")

      view |> element("#rosters-create-line-2004") |> render_click()

      assert line_numbers(world) == [1]
      id = line_id(world, 1)

      # Re-read: five stored rows on the group, one transaction, each naming the
      # weekday's own base day type.
      assert stored_days(world, id) == [1, 2, 3, 4, 5]
      key = day_type_key(world, "Weekday")

      for weekday <- 1..5 do
        assert stored_day_row(world, id, weekday) == {"2004", key}
      end

      # The new row is the one the write made, and it says so.
      assert has_element?(view, "#rosters-line-1[data-new='true']")
      assert has_element?(view, "#slot-1-1[data-slot='work']", "2004")
      assert has_element?(view, "#rosters-toast", "Line 1 created: run 2004")

      # And the card it came from is gone: the run is no longer open anywhere.
      refute has_element?(view, "#rosters-create-line-2004")
      refute has_element?(view, ".rosters-open-run[data-run='2004']")
    end

    test "highlights the new row until the next write, then lets it go", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-create-line-2004") |> render_click()

      assert has_element?(view, "#rosters-line-1[data-new='true']")

      # The next write is a different change, so the highlight moves to what
      # that write made rather than staying on the previous line.
      view |> element("#rosters-add-line") |> render_click()

      assert line_numbers(world) == [1, 2]
      refute has_element?(view, "#rosters-line-1[data-new='true']")
      assert has_element?(view, "#rosters-line-2[data-new='true']")

      # Closing the drawer is not a write, so the highlight stays until the
      # planner changes something.
      view |> element("#rosters-slot-drawer-close") |> render_click()
      assert has_element?(view, "#rosters-line-2[data-new='true']")
    end

    test "offers no create action for a run open on only some of its weekdays", context do
      {conn, world} = signed_in(context)
      # 2002 is placed on Monday, so it is still open on Tuesday to Friday and
      # the builder cannot take it for the whole group.
      _held = line(world, [{1, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      refute has_element?(view, "#rosters-create-line-2002")
      # The card is still on screen, with the weekdays that explain why.
      assert has_element?(view, ".rosters-open-run[data-run='2002']")

      # A single-weekday group's run is open on every weekday of its group, so
      # `Candidates` offers it and the page does too, named with the group's own
      # label rather than a fixed "Mon–Fri". The prototype draws no create action
      # on a one-day group; here the availability owner is `Candidates` and the
      # prepared condition is its answer, so the button is present and says what
      # it will do.
      assert has_element?(view, "#rosters-create-line-6001", "Create Sat line")
      assert has_element?(view, "#rosters-create-line-7001", "Create Sun line")

      # The runs that *are* open on every weekday of their group still offer it.
      assert has_element?(view, "#rosters-create-line-2001")
      assert has_element?(view, "#rosters-create-line-2004")
    end

    test "a refusal from the writer is on the card and writes nothing", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, path(world))

      # The card offered the action because the roster it was rendered from said
      # the run was open all week. Another line takes the run on Monday while the
      # page is open, which is the only way the writer can refuse.
      other = line(world, [{1, "2004"}])
      before = line_numbers(world)

      view |> element("#rosters-create-line-2004") |> render_click()

      # The refusal names the line that took it, on the day it took it, in the
      # page's own words, and it is on the card rather than in a flash.
      refusal = text_of(view, "#rosters-create-refusal-2004")
      assert refusal =~ "Run 2004 is in line 1 on Mon."

      # Nothing was created: the refusal wrote no line and no day.
      assert line_numbers(world) == before
      assert stored_days(world, other) == [1]
      refute has_element?(view, "#rosters-page[data-new]")

      # And the page did not jump: the card is still the card it was.
      assert has_element?(view, ".rosters-open-run[data-run='2004']")
    end

    test "no card offers a create action while the roster is paused", context do
      {conn, world} = signed_in(context)

      # A failed refresh is the pause: the last roster stays on screen and its
      # controls are off, because the writers read a roster that is no longer
      # being kept fresh. The adapter answers the mount's real read and refuses
      # the next one, so the content on screen provably came from a real read.
      {:ok, view_model} = Gtfs.load_roster(world.organization.id, world.version.id)
      refuse = install_pausing_adapter(view_model)

      {:ok, view, _html} = live(conn, path(world))
      assert has_element?(view, "#rosters-create-line-2004")

      # Arm the failure only once the page is up, so the mount's own read is a
      # real one whatever the mount happens to make.
      Agent.update(refuse, &Map.put(&1, :armed?, true))
      render_click(view, "retry_load", %{})

      assert has_element?(view, "#rosters-unavailable")
      # The card is still readable — the planner can still see what is open —
      # but the action is gone, because it would be refused.
      assert has_element?(view, ".rosters-open-run[data-run='2004']")
      refute has_element?(view, "#rosters-create-line-2004")
    end
  end

  describe "Add line" do
    setup :editor_setup

    test "creates the next numbered empty line and opens its Monday drawer", context do
      {conn, world} = signed_in(context)
      _existing = line(world, [{7, "7001"}])

      {:ok, view, _html} = live(conn, path(world))

      assert has_element?(view, "#rosters-add-line")
      refute has_element?(view, "#rosters-slot-drawer")

      view |> element("#rosters-add-line") |> render_click()

      # The next number, not the next id and not the first free one.
      assert line_numbers(world) == [1, 2]
      assert stored_days(world, line_id(world, 2)) == []

      # The drawer opened on Monday, built by the same `open_slot/4` a grid cell
      # uses, so it carries Monday's open runs and Monday's own actions.
      assert has_element?(view, "#rosters-slot-drawer")
      assert text(view, "#rosters-slot-drawer-title") =~ "Line 2"
      assert text(view, "#rosters-slot-drawer-title") =~ "Monday"
      assert has_element?(view, "#rosters-slot-run-2001")
      assert has_element?(view, "#rosters-slot-run-2004")
      # An empty week has no day to clear.
      refute has_element?(view, "#rosters-clear-day")

      assert has_element?(view, "#rosters-toast", "Line 2 added.")
    end
  end

  # Every read answers with the composition the production adapter just
  # produced, so the content on screen came from a real read; only a read after
  # `:armed?` is set is refused, which is what makes the mount's own read real
  # however many reads it makes. That is the only arrangement that can prove the
  # content survives a failed refresh.
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
