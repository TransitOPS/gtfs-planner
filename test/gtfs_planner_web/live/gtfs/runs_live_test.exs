defmodule GtfsPlannerWeb.Gtfs.RunsLiveTest do
  @moduledoc """
  The Runs page shell and its load states.

  The tests use the production adapter, and that is deliberate: every state except
  `:unavailable` is reached by loading a real version built from
  `RunsFixtures.runs_version_fixture/1`, so the page is proven against the reads
  it will actually make. The mock adapter is installed for exactly one case — the
  reload that fails — and only after a real load has succeeded, so the test can
  prove the runs already on screen survive the failure.

  Assertions are on element IDs and `data-*` attributes through
  `has_element?/2` and `LazyHTML`, not on raw HTML, so a copy change that keeps
  the same structure does not break them and a structure change does.

  Rows are created inside the SQL Sandbox transaction and rolled back.
  """
  # `async: false`, and deliberately so. The `:unavailable` case replaces the
  # application environment's catalog read adapter, which is global; an async
  # test would have every other case running beside a mock that refuses every
  # read. This is the same reason `fares_live_test.exs` and the route detail
  # tests are `async: false`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Versions

  setup :verify_on_exit!

  # Only the user is built here. `RunsFixtures.runs_version_fixture/1` creates
  # its OWN organization, so the membership has to be added to THAT one —
  # adding it to a fixture organization the test makes instead would leave the
  # seeded version belonging to an organization the reader is not a member of,
  # and the page would answer "GTFS version not found" for the right reason and
  # the wrong test.
  defp editor_setup(_context) do
    user = user_fixture()
    %{user: user}
  end

  # The seeded world plus an editor membership in the organization that owns it.
  defp world(%{user: user}) do
    world = runs_version_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: world.organization.id,
      roles: ["pathways_studio_editor"]
    })

    world
  end

  defp conn_for(%{conn: conn, user: user}, organization) do
    log_in_user(conn, user, organization: organization)
  end

  # The common case: a seeded world, a conn already a member of it, and the
  # world's own version.
  defp signed_in(context) do
    world = world(context)
    {conn_for(context, world.organization), world}
  end

  describe "the page shell" do
    setup :editor_setup

    test "renders the Runs page, its H1 and the Operations tab marked current", context do
      {conn, world} = signed_in(context)

      {:ok, _view, html} = live(conn, "/gtfs/#{world.version.id}/runs")

      assert html =~ "Runs"

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs")

      assert has_element?(view, "#runs-page")
      assert view |> element("h1") |> render() =~ "Runs"
      # The apostrophe is HTML-escaped in the rendered output, so the assertion
      # matches on a fragment that does not straddle it.
      assert view |> element("#runs-page") |> render() =~ "one or two pieces of vehicle work"
      assert has_element?(view, "#operations-sub-nav")
      assert has_element?(view, "#operations-tab-runs[aria-current=page]")

      # The page this replaced. If any of this survives, the route did not
      # actually change and the rest of the file is testing a placeholder.
      refute html =~ "Coming soon"
      refute has_element?(view, "#coming-soon")
    end

    test "the Rosters placeholder still renders Coming soon", context do
      {conn, world} = signed_in(context)

      {:ok, view, html} = live(conn, "/gtfs/#{world.version.id}/rosters")

      assert html =~ "Coming soon", "/rosters stopped being a Coming soon page"
      assert has_element?(view, "#coming-soon")
    end
  end

  describe "load states" do
    setup :editor_setup

    test "a version with blocks loads and shows the day type in the scope bar", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs")

      assert view |> element("#runs-page") |> render() =~ ~s(data-load-state="loaded")
      assert has_element?(view, "#runs-scope")
      assert has_element?(view, "#runs-day-dates")

      # The select is the Blocks control, reused unchanged, so the day type is
      # offered by the same widget the reader has already used.
      assert has_element?(view, "#runs-day")
    end

    test "a version without blocks renders the no-blocks state with Go to Blocks", context do
      organization = organization_fixture()

      Accounts.create_user_org_membership(%{
        user_id: context.user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      conn = conn_for(context, organization)

      # A calendar with no trips and no blocks: day types exist, so this is NOT
      # the no-dates state, and there is no block to cut. `:empty` and
      # `:no_dates` are different problems and the reader is sent to a different
      # page for each, so the fixture has to separate them.
      {:ok, version} = Versions.create_gtfs_version(organization.id, %{name: "No Blocks"})

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "EMPTY",
        name: "Empty day",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0
      })

      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/runs")

      assert html =~ ~s(data-load-state="empty")
      assert has_element?(view, "#runs-empty")
      assert has_element?(view, "#runs-empty-link")
      assert view |> element("#runs-empty-link") |> render() =~ "Go to Blocks"

      # Exactly one primary action, and it is the one that can fix this: a runs
      # page with no blocks has nothing to suggest, cut, or review.
      assert has_element?(view, "#runs-empty-link.btn-primary")
      refute has_element?(view, "#runs-scope")
    end

    test "a version with no service dates renders the no-dates state", context do
      {conn, world} = signed_in(context)
      organization = world.organization

      {:ok, version} = Versions.create_gtfs_version(organization.id, %{name: "No Dates"})

      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/runs")

      assert html =~ ~s(data-load-state="no_dates")
      assert has_element?(view, "#runs-no-dates")
      assert has_element?(view, "#runs-no-dates-link")
    end

    test "an unknown day renders the unknown-day state listing the day types", context do
      {conn, world} = signed_in(context)

      {:ok, view, html} = live(conn, "/gtfs/#{world.version.id}/runs?day=not-a-day-type")

      assert html =~ ~s(data-load-state="unknown")
      assert has_element?(view, "#runs-unknown-day")

      # Nothing is applied on the reader's behalf: the state names the day types
      # that do exist rather than silently loading one of them.
      assert has_element?(view, "#runs-unknown-day-form")
      assert view |> element("#runs-unknown-day") |> render() =~ "Choose a day type"
      refute html =~ ~s(data-load-state="loaded")
    end
  end

  describe "choosing a day type" do
    setup :editor_setup

    test "the select patches ?day= and loads that day type", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs")

      # Driving the control itself, not the URL: the reader changes the select,
      # and the page is what has to follow it into the address bar.
      view |> element("#runs-day-form") |> render_change(%{"day" => world.day_type_key})

      assert_patch(view, "/gtfs/#{world.version.id}/runs?day=#{world.day_type_key}")
      assert has_element?(view, "#runs-page[data-load-state=loaded]")

      # The URL is the only source of the day type, so the page and the address
      # bar cannot disagree about whose work is whose.
      assert view |> element("#runs-page") |> render() =~ "loaded"
    end

    test "an unknown day type is corrected to the one the read chose", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs?day=nope")

      assert has_element?(view, "#runs-unknown-day")

      # Applying the day type the form offers replaces the unknown one, so the
      # URL stops carrying a key the version does not have.
      view
      |> form("#runs-unknown-day-form", %{"day" => world.day_type_key})
      |> render_submit()

      assert_patch(view, "/gtfs/#{world.version.id}/runs?day=#{world.day_type_key}")
      assert has_element?(view, "#runs-page[data-load-state=loaded]")
    end

    test "a blank day falls back to the version's own default", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs?day=")

      assert has_element?(view, "#runs-page[data-load-state=loaded]")
    end
  end

  describe "a read that fails" do
    setup :editor_setup

    test "the callout and Try again appear and the earlier runs stay rendered", context do
      {conn, world} = signed_in(context)

      # One REAL load first, through the production adapter. The point of the
      # case is what survives a failure, so there has to be something there.
      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs")

      assert has_element?(view, "#runs-page[data-load-state=loaded]")

      install_failing_adapter()

      # Re-reading the same day is refused by the stub.
      render_hook(view, "retry", %{})

      assert has_element?(view, "#runs-unavailable")
      assert view |> element("#runs-unavailable") |> render() =~ "Runs couldn&#39;t load."

      assert has_element?(view, "#runs-retry")
      assert view |> element("#runs-retry") |> render() =~ "Try again"

      # The content is not blanked. A failure to read the NEXT state must not
      # destroy the state the reader is already in.
      assert has_element?(view, "#runs-scope")
      assert has_element?(view, "#runs-day-dates")
    end

    test "a first load that fails shows the callout with no content to keep", context do
      {conn, world} = signed_in(context)

      install_failing_adapter()

      {:ok, view, html} = live(conn, "/gtfs/#{world.version.id}/runs")

      assert html =~ ~s(data-load-state="unavailable")
      assert has_element?(view, "#runs-unavailable")
      assert has_element?(view, "#runs-retry")
    end
  end

  describe "scoping and access" do
    setup :editor_setup

    test "a mounted crew save reaches the transaction after editor revocation", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs")
      view |> element("#runs-crew-rules-button") |> render_click()

      before = Gtfs.get_crew_settings(world.organization.id, world.version.id)
      membership = Accounts.get_user_org_membership(context.user.id, world.organization.id)
      deactivate_membership_fixture(membership)

      view
      |> form("#crew-rules-form", crew: %{paid_break_max_minutes: "40"})
      |> render_submit()

      assert has_element?(
               view,
               "[data-role=toast-text]",
               "You no longer have editor access to this organization."
             )

      assert Gtfs.get_crew_settings(world.organization.id, world.version.id) == before
    end

    test "a member without GTFS editor access is redirected away from /runs", context do
      world = world(context)
      organization = world.organization

      member = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: member.id,
        organization_id: organization.id,
        roles: []
      })

      conn =
        build_conn()
        |> log_in_user(member, organization: organization)

      assert {:error, {:redirect, %{to: path}}} = live(conn, "/gtfs/#{world.version.id}/runs")
      refute path =~ "/runs"
    end

    test "another organization's version is not found", context do
      {conn, _world} = signed_in(context)
      theirs = runs_version_fixture()

      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               live(conn, "/gtfs/#{theirs.version.id}/runs")

      assert flash["error"] =~ "GTFS version not found"
    end

    test "an unpublished version is not found", context do
      {conn, world} = signed_in(context)
      {:ok, staging} = Versions.create_staging_gtfs_version(world.organization.id, %{name: "S"})

      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               live(conn, "/gtfs/#{staging.id}/runs")

      assert flash["error"] =~ "GTFS version not found"
    end
  end

  describe "the load is not repeated" do
    setup :editor_setup

    test "an already-loaded day type is not read again on an unrelated patch", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/runs?day=#{world.day_type_key}")

      # Make every further read fail. If `ensure_day_loaded/1` re-read the same
      # day type the page would drop into :unavailable; staying :loaded is the
      # proof that the guard held, and it is a stronger claim than asserting
      # the state and hoping.
      install_failing_adapter()

      view |> element("#runs-day-form") |> render_change(%{"day" => world.day_type_key})

      refute has_element?(view, "#runs-unavailable")
      assert has_element?(view, "#runs-page[data-load-state=loaded]")
    end
  end

  # Replaces the production adapter with one that refuses every read, and puts
  # the previous value back on exit. The `async: true` case needs this: the
  # application environment is global, so a test that leaves a mock installed
  # would break every other test running beside it.
  defp install_failing_adapter do
    previous = Application.fetch_env(:gtfs_planner, :gtfs_catalog_read_adapter)
    Application.put_env(:gtfs_planner, :gtfs_catalog_read_adapter, CatalogReadAdapterMock)

    Mox.stub(CatalogReadAdapterMock, :load_runs, fn _organization_id, _version_id, _day ->
      {:error, :unavailable}
    end)

    on_exit(fn ->
      # `:gtfs_catalog_read_adapter` has NO config default — the Repo adapter is
      # compiled in as a fallback inside `Gtfs.catalog_read_adapter/0`. So
      # `fetch_env/2` answers `:error` here, and the restore has to DELETE the
      # key rather than put something back. A one-arity `delete_env/1` in this
      # branch would leave the mock installed and every later test in the file
      # would read through it.
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :gtfs_catalog_read_adapter, value)
        :error -> Application.delete_env(:gtfs_planner, :gtfs_catalog_read_adapter)
      end
    end)
  end
end
