defmodule GtfsPlannerWeb.Gtfs.RostersPickLiveTest do
  @moduledoc """
  The inline pick row: which operators a line can be given, what the row says
  when the writer refuses, and where focus lands afterwards.

  Every case here reaches the real writer — `Gtfs.assign_roster_operator/4`
  through `RostersLive`'s `save_pick` — and the stored `roster_lines.operator_id`
  is re-read straight out of the database afterwards. "The cell says the
  operator" and "the row holds that operator" are therefore two independent
  reads rather than one rendering.

  ## The world

  The same fixture the line-drawer and add-to-line tests build: a weekday day
  type over Monday to Friday plus Saturday and Sunday day types, with runs
  `2001`, `2002`, `2004`, `6001` and `7001`. Lines are written through the
  production writers, so a pick recorded here lands on a line that really has
  the days the composition reads.

  ## What each case is really asserting

  - The offer is `Operations.list_operators/1` minus the operators who already
    hold a line in this version, in that function's own order, so the list on
    screen and the refusal the writer gives are one computation (domain rule
    11).
  - A pick is a record, so clearing one is a record too: a line that has a pick
    offers "No operator (open)" and saving it empties the column.
  - A refusal is the writer's own answer, drawn where the planner is looking, and
    it writes nothing.
  - A submitted operator id is cast and looked up inside the caller's
    organization by the writer, never by this page.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Operations
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

  # A line written through the production writers, so its row carries the stored
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

  defp operator(organization_id, attrs) do
    Repo.insert!(
      %Operator{organization_id: organization_id}
      |> Operator.changeset(%{employee_id: "E-0000", display_name: "Nobody"} |> Map.merge(attrs))
    )
  end

  # One operator of the world's own organization, with a seniority number, so
  # the option label carries "#10" the way the page draws it.
  defp ines(world) do
    operator(world.organization.id, %{
      employee_id: "E4157",
      display_name: "Ines Duarte",
      seniority_number: 10
    })
  end

  defp stored_operator_id(world, line_id) do
    Repo.one(
      from(l in RosterLine,
        where: l.id == ^line_id and l.organization_id == ^world.organization.id,
        select: l.operator_id
      )
    )
  end

  defp option_labels(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#rosters-pick-operator")
    |> LazyHTML.to_html()
    |> then(&Regex.scan(~r/<option[^>]*>(.*?)<\/option>/s, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  defp option_values(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#rosters-pick-operator option")
    |> LazyHTML.attribute("value")
  end

  defp text_of(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "opening the pick row" do
    setup :editor_setup

    test "opens under the line it belongs to, with the operators nobody holds", context do
      {conn, world} = signed_in(context)
      first = line(world, [{2, "2002"}])
      _second = line(world, [{4, "2002"}])

      held =
        operator(world.organization.id, %{
          employee_id: "E-2200",
          display_name: "Priya Raman",
          seniority_number: 2
        })

      free_a = ines(world)

      free_b =
        operator(world.organization.id, %{
          employee_id: "E-9001",
          display_name: "Wojcik",
          seniority_number: 1
        })

      assert {:ok, _result} =
               Gtfs.assign_roster_operator(
                 world.organization.id,
                 world.version.id,
                 first,
                 held.id
               )

      {:ok, view, _html} = live(conn, path(world))

      refute has_element?(view, "#rosters-pick-row")

      view |> element("#rosters-record-pick-2") |> render_click()

      # The row is inside the grid's own table, under the second line, so the
      # thing being changed and the control that changes it are in one place.
      assert has_element?(view, "#rosters-grid #rosters-pick-row")
      assert has_element?(view, "#rosters-pick-form")
      assert has_element?(view, "#rosters-pick-row", "Record the pick for line 2")

      # The pick is being recorded, so the cell says so rather than offering the
      # control that would reopen the row underneath it.
      assert has_element?(view, "#rosters-line-2", "Recording pick…")
      refute has_element?(view, "#rosters-record-pick-2")

      # The line that holds an operator offers nobody who holds one; the line
      # being picked offers both free operators in seniority order, and nobody
      # else — the operator holding line 1 is not on offer for line 2.
      assert option_values(view) == [free_b.id, free_a.id]
      assert option_labels(view) == ["#1 Wojcik · E-9001", "#10 Ines Duarte · E4157"]
      refute Enum.any?(option_labels(view), &(&1 =~ "Priya Raman"))
      assert text_of(view, "#rosters-pick-operator-help") =~ "picked this line in the bid"

      assert_push_event(view, "focus_scoped_target", %{id: "rosters-pick-operator"})
    end

    test "an operator without a seniority number is labelled without one", context do
      {conn, world} = signed_in(context)
      _line = line(world, [{2, "2002"}])

      _senior =
        operator(world.organization.id, %{
          employee_id: "E-1",
          display_name: "Ada",
          seniority_number: 1
        })

      _unnumbered =
        operator(world.organization.id, %{
          employee_id: "E-2",
          display_name: "Bo Chen"
        })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-record-pick-1") |> render_click()

      # The organization's own order: numbered operators by number, then the rest
      # by name. A blank number is not written as zero or as a dash.
      assert option_labels(view) == ["#1 Ada · E-1", "Bo Chen · E-2"]
    end

    test "a line that already has a pick offers that operator and a way to clear it", context do
      {conn, world} = signed_in(context)
      line_id = line(world, [{2, "2002"}])
      _other = line(world, [{4, "2002"}])
      held = ines(world)

      assert {:ok, _result} =
               Gtfs.assign_roster_operator(
                 world.organization.id,
                 world.version.id,
                 line_id,
                 held.id
               )

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-record-pick-1") |> render_click()

      assert option_labels(view) == [
               "#10 Ines Duarte · E4157 · current",
               "No operator (open)"
             ]

      # The clearing answer is a real write: the stored column is empty
      # afterwards, read straight out of the row.
      view |> element("#rosters-pick-form") |> render_submit(%{"operator" => ""})

      refute has_element?(view, "#rosters-pick-row")
      assert stored_operator_id(world, line_id) == nil
      assert has_element?(view, "#rosters-line-1", "Open")
    end

    test "a line this version does not hold opens nothing", context do
      {conn, world} = signed_in(context)
      _line = line(world, [{2, "2002"}])
      _other = line(world, [{4, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      render_hook(view, "open_pick", %{"line" => Ecto.UUID.generate()})

      refute has_element?(view, "#rosters-pick-row")
    end
  end

  describe "saving a pick" do
    setup :editor_setup

    test "records it, closes the row and hands focus back to the control that opened it",
         context do
      {conn, world} = signed_in(context)
      line_id = line(world, [{2, "2002"}])
      _other = line(world, [{4, "2002"}])
      chosen = ines(world)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-record-pick-1") |> render_click()
      view |> element("#rosters-pick-form") |> render_submit(%{"operator" => chosen.id})

      refute has_element?(view, "#rosters-pick-row")

      # Two independent reads: the stored column, and the cell the composition
      # redrew from it.
      assert stored_operator_id(world, line_id) == chosen.id
      assert has_element?(view, "#rosters-line-1", "Ines Duarte")
      assert has_element?(view, "#rosters-line-1", "E4157")
      assert has_element?(view, "#rosters-record-pick-1", "Change")

      assert has_element?(view, "#rosters-toast", "Pick recorded: Ines Duarte holds line 1.")
      assert_push_event(view, "focus_scoped_target", %{id: "rosters-record-pick-1"})
    end

    test "only one row is open at a time", context do
      {conn, world} = signed_in(context)
      _first = line(world, [{2, "2002"}])
      _second = line(world, [{4, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-record-pick-1") |> render_click()
      assert has_element?(view, "#rosters-pick-row")

      view |> element("#rosters-record-pick-2") |> render_click()

      assert has_element?(view, "#rosters-pick-row")
      assert has_element?(view, "#rosters-pick-row", "Record the pick for line 2")
      refute has_element?(view, "#rosters-pick-row", "Record the pick for line 1")
    end

    test "an operator who took another line first is refused, named and focused", context do
      {conn, world} = signed_in(context)
      first = line(world, [{2, "2002"}])
      second = line(world, [{4, "2002"}])
      chosen = ines(world)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-record-pick-1") |> render_click()

      # Another session records the same pick on line 2 while this row is open.
      assert {:ok, _result} =
               Gtfs.assign_roster_operator(
                 world.organization.id,
                 world.version.id,
                 second,
                 chosen.id
               )

      view |> element("#rosters-pick-form") |> render_submit(%{"operator" => chosen.id})

      # The row stays open with the writer's own sentence, and the select takes
      # focus because choosing again is the next move.
      assert has_element?(
               view,
               "#rosters-pick-error",
               "Ines Duarte already holds line 2. Another session recorded that pick. " <>
                 "Choose another operator."
             )

      assert_push_event(view, "focus_scoped_target", %{id: "rosters-pick-operator"})

      # A refusal writes nothing: line 1 is still open and the other line still
      # holds the operator, both read from the database.
      assert stored_operator_id(world, first) == nil
      assert stored_operator_id(world, second) == chosen.id

      # The refused operator is no longer on offer, because the re-read roster
      # knows they hold a line now.
      refute Enum.any?(option_labels(view), &(&1 =~ "Ines Duarte"))

      assert has_element?(
               view,
               "#rosters-pick-operator-help",
               "Every operator already holds a line"
             )
    end

    test "an operator id from another organization is refused and writes nothing", context do
      {conn, world} = signed_in(context)
      line_id = line(world, [{2, "2002"}])

      other_org = organization_fixture()

      foreign =
        operator(other_org.id, %{
          employee_id: "E-1",
          display_name: "Not On This Roster"
        })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-record-pick-1") |> render_click()

      view |> element("#rosters-pick-form") |> render_submit(%{"operator" => foreign.id})

      assert has_element?(
               view,
               "#rosters-pick-error",
               "That operator is not on this organization's list."
             )

      assert stored_operator_id(world, line_id) == nil
      assert_push_event(view, "focus_scoped_target", %{id: "rosters-pick-operator"})
    end

    test "under the Open filter a recorded pick takes the row away and focus goes to the heading",
         context do
      {conn, world} = signed_in(context)
      line_id = line(world, [{2, "2002"}])
      chosen = ines(world)

      {:ok, view, _html} = live(conn, path(world) <> "?filter=open")

      view |> element("#rosters-record-pick-1") |> render_click()
      view |> element("#rosters-pick-form") |> render_submit(%{"operator" => chosen.id})

      # The line is assigned now, so the Open filter no longer draws it and the
      # control that opened the row went with it. Focus lands on the section
      # heading rather than nowhere.
      refute has_element?(view, "#rosters-line-1")
      assert stored_operator_id(world, line_id) == chosen.id
      assert_push_event(view, "focus_scoped_target", %{id: "rosters-lines-title"})
    end

    test "cancelling closes the row, writes nothing and returns focus to the control", context do
      {conn, world} = signed_in(context)
      line_id = line(world, [{2, "2002"}])
      _chosen = ines(world)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-record-pick-1") |> render_click()

      view |> element("#rosters-pick-cancel") |> render_click()

      refute has_element?(view, "#rosters-pick-row")
      assert stored_operator_id(world, line_id) == nil
      assert_push_event(view, "focus_scoped_target", %{id: "rosters-record-pick-1"})
    end
  end

  describe "a revoked editor role" do
    setup :editor_setup

    test "the save is refused and the pick is not written", context do
      {conn, world} = signed_in(context)
      line_id = line(world, [{2, "2002"}])
      chosen = ines(world)

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-record-pick-1") |> render_click()

      membership = Accounts.get_user_org_membership(context.user.id, world.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      view |> element("#rosters-pick-form") |> render_submit(%{"operator" => chosen.id})

      assert has_element?(view, "#rosters-toast", "You no longer have editor access")
      assert stored_operator_id(world, line_id) == nil
    end
  end

  describe "the operator offer" do
    setup :editor_setup

    test "is the organization's own list, and an operator of another organization is never on it",
         context do
      {conn, world} = signed_in(context)
      _line = line(world, [{2, "2002"}])
      _mine = ines(world)

      other_org = organization_fixture()

      _theirs =
        operator(other_org.id, %{
          employee_id: "E-1",
          display_name: "Not On This Roster"
        })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-record-pick-1") |> render_click()

      on_offer =
        Operations.list_operators(world.organization.id)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert Enum.sort(option_values(view)) == on_offer
      refute Enum.any?(option_labels(view), &(&1 =~ "Not On This Roster"))
    end
  end
end
