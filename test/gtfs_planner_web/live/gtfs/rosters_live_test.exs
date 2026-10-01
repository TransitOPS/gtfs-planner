defmodule GtfsPlannerWeb.Gtfs.RostersLiveTest do
  @moduledoc """
  The Rosters page shell and the states it can be in before it has any lines.

  The tests use the production adapter, and that is deliberate: every state is
  reached by loading a real version built from `RunsFixtures.runs_version_fixture/1`
  or a calendar with no trips, so the page is proven against the read it will
  actually make. There is no mock adapter here — `:unavailable` and its retry
  are step 25's `#rosters-unavailable`, and this step only refuses to blank the
  page.

  Assertions are on element IDs and `data-*` attributes through `has_element?/2`
  and `LazyHTML`, not on raw HTML, so a copy change that keeps the same
  structure does not break them and a structure change does. The disconnected
  render has no live process, so that one case is asserted through `LazyHTML`
  over the static HTML — which is the point of it, since a state the browser
  never receives is a state that cannot be checked any other way.

  Rows are created inside the SQL Sandbox transaction and rolled back.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # Only the user is built here. `RunsFixtures.runs_version_fixture/1` creates
  # its OWN organization, so the membership has to be added to THAT one — adding
  # it to a fixture organization the test makes instead would leave the seeded
  # version belonging to an organization the reader is not a member of, and the
  # page would answer "GTFS version not found" for the right reason and the
  # wrong test.
  defp editor_setup(_context) do
    %{user: user_fixture()}
  end

  # `runs_version_fixture/1` builds blocks, not runs: the derivation follows
  # stored assignments, so a fixture with no `TripRun` rows derives no runs at
  # all and the roster's run-day total is zero. That is the same fact the Runs
  # page reports for it, which is why the roster tests here assign each block to
  # a run first — the world the page is really asked about is a version an
  # operator has already cut.
  defp world(%{user: user}) do
    world = runs_version_fixture()

    for {block_id, run_id} <- [{"101", "2001"}, {"102", "2002"}],
        trip <- world.blocks[block_id] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: run_id
      })
    end

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

  defp member_with_roles(organization, roles) do
    member = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: member.id,
      organization_id: organization.id,
      roles: roles
    })

    member
  end

  # An editor's own conn in an organization the test made, for the cases that
  # build their own version rather than the runs fixture's.
  defp editor_in(_context, organization) do
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    user
  end

  describe "the page shell" do
    setup :editor_setup

    test "an editor sees the Rosters head with the tab current", context do
      {conn, world} = signed_in(context)

      {:ok, view, html} = live(conn, "/gtfs/#{world.version.id}/rosters")

      assert has_element?(view, "#rosters-page")
      assert has_element?(view, "#rosters-head")
      assert view |> element("#rosters-head h1") |> render() =~ "Roster lines"
      assert has_element?(view, "#operations-sub-nav")
      assert has_element?(view, "#operations-tab-rosters[aria-current=page]")

      # The subtitle is the one sentence that says what a line is, and it is
      # what a reader who has never seen the page decides from the copy alone.
      assert view |> element("#rosters-head") |> render() =~
               "one week of work that repeats through the service period"

      # The page this replaced. If any of this survives, the route did not
      # actually change and the rest of the file is testing a placeholder.
      refute html =~ "Coming soon"
      refute has_element?(view, "#coming-soon")
    end

    test "a loaded version reads as ready, and Add line is the head's action", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/rosters")

      assert view |> element("#rosters-page") |> render() =~ ~s(data-load-state="ready")

      # Secondary, and enabled: the clean state has no primary, and a disabled
      # control with no reason is a dead end rather than a pause.
      assert has_element?(view, "#rosters-add-line.btn-outline:not([disabled])")

      # This step owns the shell, so no state panel is drawn over a loaded
      # version. Step 25 draws the scope bar and the count strip.
      refute has_element?(view, "#rosters-loading")
      refute has_element?(view, "#rosters-no-runs")
    end
  end

  describe "load states" do
    setup :editor_setup

    test "the disconnected render is the loading skeleton with editing off", context do
      {conn, world} = signed_in(context)

      conn = get(conn, "/gtfs/#{world.version.id}/rosters")

      # A disconnected render is the static HTML a browser gets before its
      # socket opens, so this case goes through the router and asserts on the
      # response rather than on a live process — there is no process yet.
      conn = get(conn, "/gtfs/#{world.version.id}/rosters")
      html = html_response(conn, 200)

      doc = LazyHTML.from_document(html)

      assert LazyHTML.attribute(LazyHTML.query(doc, "#rosters-page"), "data-load-state") == [
               "loading"
             ]

      assert Enum.count(LazyHTML.query(doc, "#rosters-loading")) == 1

      # The skeleton mirrors the grid it stands in for: a Line column, seven
      # weekday columns and eight rows. A skeleton of the wrong shape makes the
      # page jump when the real content arrives.
      assert LazyHTML.text(LazyHTML.query(doc, "#rosters-skeleton")) =~ "Line"

      for day <- ~w(Mon Tue Wed Thu Fri Sat Sun) do
        assert LazyHTML.text(LazyHTML.query(doc, "#rosters-skeleton")) =~ day
      end
      # Each row is the one with an inline height, so the count is the row count
      # rather than a reading of how many divs the pulse wrapper happens to hold.
      assert Enum.count(LazyHTML.query(doc, "#rosters-loading div[style='height:48px']")) == 8

      # Editing is paused while loading, and the button says why rather than
      # being quietly off.
      assert Enum.count(
               LazyHTML.query(
                 doc,
                 "#rosters-add-line[disabled][title='Editing is paused until the roster loads.']"
               )
             ) == 1

      # No state panel over the loading skeleton: the skeleton IS the state.
      assert Enum.empty?(LazyHTML.query(doc, "#rosters-no-runs"))
    end

    test "a version with no runs renders the no-runs state with one primary to Runs", context do
      organization = organization_fixture()
      user = editor_in(context, organization)
      conn = conn_for(%{context | user: user}, organization)

      # A calendar with no trips: day types exist, so the version is published
      # and readable, and there is simply no run to put in a line. "No runs" is
      # a settled fact about the version rather than a failure, and its one
      # action goes to the page that makes runs.
      {:ok, version} = Versions.create_gtfs_version(organization.id, %{name: "No Runs"})

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

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/rosters")

      # `html` here is the disconnected render, which is deliberately still the
      # skeleton; the no-runs panel is only true once the read has happened.
      assert view |> element("#rosters-page") |> render() =~ ~s(data-load-state="no_runs")
      assert has_element?(view, "#rosters-no-runs")
      assert has_element?(view, "#rosters-go-to-runs", "Go to Runs")
      # Exactly one primary, and it is the one that can fix this. Go to Runs is
      # the only `.btn-primary` anywhere on the page.
      refute has_element?(view, "#rosters-page .btn-primary:not(#rosters-go-to-runs)")

      # Exactly one primary, and it is the one that can fix this.
      assert has_element?(view, "#rosters-go-to-runs.btn-primary")
      assert view |> element("#rosters-go-to-runs") |> render() =~
               ~s(href="/gtfs/#{version.id}/runs")

      # The head offers no Add line beside it: there is no run to put in a line,
      # so the action would create an empty line that cannot be filled, and the
      # page's one action is already the one that makes runs.
      refute has_element?(view, "#rosters-add-line")

      refute has_element?(view, "#rosters-loading")
    end
  end

  describe "access" do
    setup :editor_setup

    test "a member without the editor role is redirected", context do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      for roles <- [[], ["pathways_studio_admin"]] do
        member = member_with_roles(organization, roles)
        member_conn = conn_for(%{context | user: member}, organization)

        assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
                 live(member_conn, "/gtfs/#{version.id}/rosters")
      end
    end

    test "a foreign or unpublished version redirects with the not-found flash", context do
      organization = organization_fixture()
      user = editor_in(context, organization)
      conn = conn_for(%{context | user: user}, organization)

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      for version_id <- [foreign_version.id, staging.id, Ecto.UUID.generate()] do
        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
                 live(conn, "/gtfs/#{version_id}/rosters")
      end
    end

    test "an unauthenticated visit follows the existing login redirect", _context do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      conn = build_conn() |> init_test_session(%{})

      assert redirected_to(get(conn, "/gtfs/#{version.id}/rosters")) == "/users/log_in"
    end
  end

  describe "a revoked editor role" do
    setup :editor_setup

    test "the next write is refused and writes nothing", context do
      {conn, world} = signed_in(context)

      {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/rosters")

      membership = Accounts.get_user_org_membership(context.user.id, world.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      before = Repo.aggregate(RosterLine, :count)

      render_hook(view, "add_line", %{})

      assert has_element?(view, "#rosters-toast", "You no longer have editor access")
      assert Repo.aggregate(RosterLine, :count) == before
    end
  end
end
