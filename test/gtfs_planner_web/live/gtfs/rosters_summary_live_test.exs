defmodule GtfsPlannerWeb.Gtfs.RostersSummaryLiveTest do
  @moduledoc """
  The Rosters page's scope bar, count strip and messages.

  These are the page's summary surfaces, and every figure on them comes from
  `Rosters.Roster.build/1` (INV-15). The tests therefore assert the strip's
  words against figures the composition produced from a real version, written
  out here rather than recomputed in the test — a strip that recomputed its own
  numbers in the assertion would agree with a wrong strip.

  The world is `RunsFixtures.runs_version_fixture/1` with **block 101 only**
  assigned to run `2001`. One run over the fixture's single Monday-to-Friday
  day type is what makes the fixture's own figures small and exact:

    * the base week is one group, "Mon–Fri" of day type "Weekday"; Saturday and
      Sunday have no base day type at all, so the scope bar can claim nothing
      about them and the base week holds 261 base-week dates (52 Mon, 52 Tue,
      53 Wed, 52 Thu, 52 Fri);
    * `run_days_total` is 5 — one derived run on each of five weekdays;
    * a line that works `2001` on all five weekdays covers "5 of 5" and pays
      210 900 s = 58 h 35 min a week, which is over the 48 h warning, so that
      line's weekly-paid tile is a range of one value, "58:35–58:35", and the
      strip reports "1 above 48 h" and one line with problems. Those are the
      fixture's real figures, not a defect: this block is a 58-hour week.

  The stale slot is a real one: a slot is set through `Gtfs.set_roster_slot/4`,
  and then the stored `run_sign_on_secs` is moved behind the writer's back, which
  is exactly what a re-cut does to a run that keeps its ID (INV-13). The
  composition is not told; it discovers the drift from the stored times.

  The `:unavailable` case installs `CatalogReadAdapterMock` before the page
  mounts. It answers the first read with the composition the production adapter
  just produced, refuses the next one and answers normally afterwards, so the
  page's content came from a real read and only the refresh failed — which is
  the only arrangement that can prove the content survives the failure. The
  refusing read is sent as `retry_load`; a write's own reload arrives with the
  step that adds the write, and both go through the same `load_roster/1`.

  Assertions are on element IDs and `data-*` attributes through `has_element?/2`
  and `LazyHTML`, not on raw HTML. Rows are created inside the SQL Sandbox
  transaction and rolled back.

  This file is `async: false` because the `:unavailable` case replaces the
  application environment's catalog read adapter, which is global — the same
  reason `runs_live_test.exs` is.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo

  setup :verify_on_exit!

  defp editor_setup(_context), do: %{user: user_fixture()}

  # One run, so the counts the strip shows are the fixture's own.
  defp world(%{user: user}) do
    build_world(user, true)
  end

  # The same version with nothing cut into runs: the state the page reports as
  # "Cut runs first", which is not the first-use state.
  defp world_without_runs(%{user: user}) do
    build_world(user, false)
  end

  defp build_world(user, assign_run?) do
    world = runs_version_fixture()

    if assign_run? do
      for trip <- world.blocks["101"] do
        trip_run_fixture(world.organization.id, world.version.id, %{
          trip: trip,
          day_type_key: world.day_type_key,
          run_id: "2001"
        })
      end
    end

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: world.organization.id,
      roles: ["pathways_studio_editor"]
    })

    world
  end

  defp signed_in(context) do
    world = world(context)
    {log_in_user(context.conn, context.user, organization: world.organization), world}
  end

  defp signed_in_without_runs(context) do
    world = world_without_runs(context)
    {log_in_user(context.conn, context.user, organization: world.organization), world}
  end

  defp path(world), do: "/gtfs/#{world.version.id}/rosters"

  # A line working run 2001 on every weekday of the base week: the "5 of 5"
  # line the strip's run-days tile is written against.
  defp full_week_line(world) do
    {:ok, %{id: line_id}} = Gtfs.create_roster_line(world_audit(world))

    for weekday <- 1..5 do
      assert {:ok, _result} =
               Gtfs.set_roster_slot(
                 world_audit(world),
                 line_id,
                 weekday,
                 "2001"
               )
    end

    line_id
  end

  defp add_operator(world, user, attrs) do
    {:ok, operator} =
      Operations.create_operator(world.organization.id, user, %{
        employee_id: Map.get(attrs, :employee_id, "E9001"),
        display_name: Map.get(attrs, :display_name, "Ada Okafor")
      })

    operator
  end

  defp text(view, selector) do
    view |> element(selector) |> render()
  end

  describe "the scope bar" do
    setup :editor_setup

    test "names the base week, the two rules and the operator count", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, path(world))

      settings = text(view, "#rosters-settings-button")

      assert settings =~ "Roster settings"
      # The one group this version's base week has, and the day type behind it.
      assert settings =~ "Mon–Fri Weekday"
      assert settings =~ "rest 10 h"
      assert settings =~ "warn above 48 h"

      # 52 Mon + 52 Tue + 53 Wed + 52 Thu + 52 Fri of the fixture's calendar.
      assert has_element?(view, "#rosters-scope", "Lines repeat on 261 base-week dates")

      # No operators yet, and the bar says so with a number rather than hiding
      # the control: the count is the reason the pick cannot be recorded.
      assert has_element?(view, "#rosters-operators-button", "Operators · 0")

      add_operator(world, context.user, %{})
      add_operator(world, context.user, %{employee_id: "E9002", display_name: "Bo Vance"})

      {:ok, view, _html} = live(conn, path(world))
      assert has_element?(view, "#rosters-operators-button", "Operators · 2")
    end
  end

  describe "the count strip" do
    setup :editor_setup

    test "shows the composition's own figures", context do
      {conn, world} = signed_in(context)
      full_week_line(world)

      {:ok, view, _html} = live(conn, path(world))

      # All six keys the architecture names, so a tile cannot be dropped without
      # this failing.
      for key <- ~w(lines run_days open_work weekly_paid split_days_off problems) do
        assert has_element?(view, "#rosters-count-strip-item-#{key}")
      end

      assert has_element?(view, "#rosters-count-strip-item-lines", "1")
      assert has_element?(view, "#rosters-count-strip-item-lines", "1 open")

      # The tile that carries the "of the version's total" reading.
      run_days = text(view, "#rosters-count-strip-item-run_days")
      assert run_days =~ "Run-days in lines"
      assert run_days =~ "5"
      assert run_days =~ "of 5"

      # Every run of the version is in a line, so open work is zero and the tile
      # says so in the success tone.
      open_work = text(view, "#rosters-count-strip-item-open_work")
      assert open_work =~ "Open work"
      assert open_work =~ "Mon 0 · Tue 0 · Wed 0 · Thu 0 · Fri 0 · Sat 0 · Sun 0"

      # One line, one paid week of 210 900 s = 58 h 35 min, which is over the
      # 48 h warning this version stores.
      weekly = text(view, "#rosters-count-strip-item-weekly_paid")
      assert weekly =~ "Weekly paid"
      assert weekly =~ "58:35–58:35"
      assert weekly =~ "average 58:35 · 1 above 48 h"

      # Five working days leaves Saturday and Sunday off, in a row, so no line
      # has its days off split.
      assert has_element?(
               view,
               "#rosters-count-strip-item-split_days_off",
               "every line has two in a row"
             )

      assert has_element?(view, "#rosters-count-strip-item-problems", "Lines with problems")
      assert has_element?(view, "#rosters-count-strip-item-problems", "1")

      # The tiles are figures, not filters: the filter row owns filtering, and a
      # tile that also filters changes meaning when it is pressed.
      assert view |> element("#rosters-count-strip") |> render() =~ ~s(data-mode="display")
      refute has_element?(view, "#rosters-count-strip-item-lines[phx-click]")
    end

    test "reports a line with no work yet without claiming a range", context do
      {conn, world} = signed_in(context)
      {:ok, _line} = Gtfs.create_roster_line(world_audit(world))

      {:ok, view, _html} = live(conn, path(world))

      weekly = text(view, "#rosters-count-strip-item-weekly_paid")
      assert weekly =~ "No line has work yet"

      # The open work the empty line leaves behind is the fixture's one run on
      # each of the five weekdays.
      assert has_element?(view, "#rosters-count-strip-item-open_work", "Mon 1 · Tue 1 · Wed 1")
      assert has_element?(view, "#rosters-count-strip-item-split_days_off", "Split days off")
    end
  end

  describe "the stale-slot message" do
    setup :editor_setup

    test "appears only when a slot is stale, and shows the stale ones", context do
      {conn, world} = signed_in(context)
      line_id = full_week_line(world)

      {:ok, view, _html} = live(conn, path(world))
      refute has_element?(view, "#rosters-stale-message")

      # A re-cut keeps the run's ID and changes its work, which is exactly this
      # row: the stored sign-on no longer matches the derived run's.
      Repo.update_all(
        from(day in RosterLineDay, where: day.roster_line_id == ^line_id and day.weekday == 1),
        set: [run_sign_on_secs: 7_741]
      )

      {:ok, view, _html} = live(conn, path(world))

      assert has_element?(view, "#rosters-stale-message", "1 slot is stale")

      # A stale slot is a warning with a way out, not a dead end.
      view |> element("#rosters-stale-message button", "Show stale slots") |> render_click()

      assert_patched(view, path(world) <> "?filter=stale")
    end
  end

  describe "the no-operators message" do
    setup :editor_setup

    test "appears with no operators and goes away once there is one", context do
      {conn, world} = signed_in(context)
      full_week_line(world)

      {:ok, view, _html} = live(conn, path(world))

      assert has_element?(
               view,
               "#rosters-no-operators-message",
               "Add operators to record the pick."
             )

      assert has_element?(view, "#rosters-add-operator", "Add operator")

      add_operator(world, context.user, %{})

      {:ok, view, _html} = live(conn, path(world))
      refute has_element?(view, "#rosters-no-operators-message")
    end
  end

  describe "the first-use state" do
    setup :editor_setup

    test "a version with no runs shows the scope bar alone", context do
      {conn, world} = signed_in_without_runs(context)

      {:ok, view, _html} = live(conn, path(world))

      # The scope bar still applies — the rules and the operator count are facts
      # about the organization, not about the runs.
      assert has_element?(view, "#rosters-scope")
      assert has_element?(view, "#rosters-operators-button", "Operators · 0")

      # Nothing else: with no runs there is nothing to count, nothing stale and
      # nothing to pick, and the no-runs panel says all three in one sentence.
      refute has_element?(view, "#rosters-count-strip")
      refute has_element?(view, "#rosters-messages")
      refute has_element?(view, "#rosters-first-use")

      # Runs exist (the count strip says so), so this is not the no-runs state.
      assert has_element?(view, "#rosters-no-runs")
      assert has_element?(view, "#rosters-go-to-runs")
    end

    test "appears when there are runs and no lines", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, path(world))

      # Runs exist (the count strip says so), so this is not the no-runs state.
      assert has_element?(view, "#rosters-count-strip-item-open_work")
      refute has_element?(view, "#rosters-no-runs")

      assert has_element?(view, "#rosters-first-use", "No roster lines yet")
      assert has_element?(view, "#rosters-go-to-open-work", "Go to open work")

      full_week_line(world)

      {:ok, view, _html} = live(conn, path(world))
      refute has_element?(view, "#rosters-first-use")
    end
  end

  describe "the failed refresh" do
    setup :editor_setup

    test "keeps the last roster, pauses editing and retries", context do
      {conn, world} = signed_in(context)
      full_week_line(world)

      # The real read first: the composition the mock then hands back is the
      # one this version actually produces.
      assert {:ok, view_model} = Gtfs.load_roster(world.organization.id, world.version.id)
      install_failing_adapter(view_model)

      {:ok, view, _html} = live(conn, path(world))

      # The first read succeeded, so the page is ready and showing figures.
      assert view |> element("#rosters-page") |> render() =~ ~s(data-load-state="ready")
      assert has_element?(view, "#rosters-count-strip-item-run_days", "of 5")
      refute has_element?(view, "#rosters-unavailable")

      # The next read is refused. Everything the reader was looking at stays.
      render_click(view, "retry_load", %{})

      assert view |> element("#rosters-page") |> render() =~ ~s(data-load-state="unavailable")
      assert has_element?(view, "#rosters-unavailable", "The roster could not refresh.")

      assert has_element?(
               view,
               "#rosters-unavailable",
               "Editing is paused until the roster refreshes."
             )

      # The last roster's figures are still on screen, and the lines they count
      # are still the stored ones.
      assert has_element?(view, "#rosters-count-strip-item-lines", "1")
      assert has_element?(view, "#rosters-count-strip-item-run_days", "of 5")

      # Editing is off, and both the control and the message say why.
      assert has_element?(
               view,
               "#rosters-add-line[disabled][title='Editing is paused until the roster refreshes.']"
             )

      # No primary on the page while it is paused. The retry is the action, and it
      # is secondary like every other action here: a message that arrives over
      # content the reader did not ask for does not get to claim the page's one
      # emphasis.
      refute has_element?(view, "#rosters-page .btn-primary")

      # Retrying reads again through the same path. This adapter refuses
      # exactly one read, so the retry succeeds and the pause ends: the retry is
      # not a decoration on the error message, it is the read that recovers the
      # page.
      view |> element("#rosters-retry") |> render_click()

      refute has_element?(view, "#rosters-unavailable")
      assert view |> element("#rosters-page") |> render() =~ ~s(data-load-state="ready")
      assert has_element?(view, "#rosters-add-line:not([disabled])")
    end
  end

  # Replaces the production adapter with one that answers the first read from a
  # real composition, refuses the next one and answers normally afterwards, and
  # puts the previous value back on exit. `:gtfs_catalog_read_adapter` has no
  # config default — the Repo adapter is compiled in as a fallback inside
  # `Gtfs.catalog_read_adapter/0` — so the restore has to delete the key when
  # there was none rather than put something back (`runs_live_test.exs`).
  #
  # The refusing read is sent as `retry_load`, which is the read this step owns:
  # a write's own reload arrives with the step that adds the write, and both go
  # through `load_roster/1`, so a pause between them is the same pause.
  defp install_failing_adapter(view_model) do
    previous = Application.fetch_env(:gtfs_planner, :gtfs_catalog_read_adapter)
    Application.put_env(:gtfs_planner, :gtfs_catalog_read_adapter, CatalogReadAdapterMock)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Mox.stub(CatalogReadAdapterMock, :load_roster, fn _organization_id, _version_id ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        # One good read, then one refused, then the connection is back.
        1 -> {:error, :unavailable}
        _read -> {:ok, view_model}
      end
    end)

    on_exit(fn -> restore(previous) end)

    previous
  end

  defp restore({:ok, value}),
    do: Application.put_env(:gtfs_planner, :gtfs_catalog_read_adapter, value)

  defp restore(:error), do: Application.delete_env(:gtfs_planner, :gtfs_catalog_read_adapter)
end
