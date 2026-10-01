defmodule GtfsPlannerWeb.Gtfs.StopsMapChecksTest do
  @moduledoc """
  Tests for the Map view's "things to check" disclosure: the version's
  placement findings, read after the list rather than with it.

  A finding is worth an editor's time only if it can be acted on, so each row
  names the stops or the pattern it is about, says what the reader should do,
  and offers the action that does it. The distances and the wording are
  literals, not values read back out of the code under test: a pair 1.5 m apart is "5 ft apart" because that is the coarsest
  distance an editor can act on, and a stop is "isn't served" when no pattern
  calls there.

  The disclosure never blocks the list, and a dismissal is a judgement rather
  than a deletion: "They're different stops" removes the row for this session
  and writes nothing, so the next mount asks again. A dismissal nobody made is
  a dismissal nobody agreed to.

  Every event names a row by its key, and a key the panel is not showing is
  refused rather than looked up. A forged key must not be able to select a stop
  the editor cannot see.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.GeocodingMock

  setup do
    organization = organization_fixture()
    editor = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: editor.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      organization: organization,
      version: version,
      editor_conn: log_in_user(build_conn(), editor, organization: organization)
    }
  end

  # Two reads, so two waits: the model has to land before the checks read even
  # starts, and a single `render_async` answers after the first of them. The
  # wait is bounded rather than the 100 ms default, which is a coin toss on a
  # loaded machine and makes a flaky test look like a broken panel.
  defp open_map(conn, version) do
    {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/stops/map")
    render_async(view, 2_000)
    render_async(view, 2_000)
    view
  end

  # The seed's duplicate pair: 1433 and 1434 carry the same
  # name and sit 1.5 m apart on the same line of longitude, so the distance
  # between them is a latitude difference alone. Both are on a pattern, so the
  # only finding the pair produces is the pair itself.
  defp duplicate_pair(ctx) do
    route = route_fixture(ctx.organization.id, ctx.version.id, %{route_short_name: "1"})

    pattern =
      route_pattern_fixture(ctx.organization.id, ctx.version.id, %{route_id: route.route_id})

    for {stop_id, lat, position} <- [
          {"1433", "44.6356100", 1},
          {"1434", "44.6356235", 2}
        ] do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: stop_id,
        stop_name: "US 101 & SE 1st St",
        stop_desc: "Northbound",
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-124.0531700")
      })

      route_pattern_stop_fixture(pattern, stop_id, position)
    end
  end

  # A stop no pattern calls at, and no trip is scheduled to, so the read has to
  # work it out rather than being told.
  defp unserved_stop(ctx) do
    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: "1531",
      stop_name: "Depot Road Gate",
      stop_lat: Decimal.new("44.6400000"),
      stop_lon: Decimal.new("-124.0531700")
    })
  end

  describe "the disclosure" do
    test "lists the pair a metre and a half apart with both of its actions", ctx do
      duplicate_pair(ctx)
      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stops-map-checks")
      assert has_element?(view, "#stops-map-checks-toggle", "thing to check")
      assert has_element?(view, "#stops-map-checks-toggle", "Show")

      assert has_element?(
               view,
               "#stops-map-checks-duplicate-1433-1434",
               "Two stops 5 ft apart"
             )

      row = view |> element("#stops-map-checks-duplicate-1433-1434") |> render()

      assert words(row) =~
               "US 101 &amp; SE 1st St (1433) and US 101 &amp; SE 1st St (1434)"

      assert words(row) =~ "Riders see two stops at one sign"
      assert has_element?(view, "#stops-map-checks-duplicate-1433-1434 button", "Review pair")

      assert has_element?(
               view,
               "#stops-map-checks-dismiss-duplicate-1433-1434",
               "different stops"
             )
    end

    test "the row list is closed until it is asked for", ctx do
      duplicate_pair(ctx)
      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stops-map-checks-toggle[aria-expanded=false]")

      html = view |> element("#stops-map-checks-toggle") |> render_click()

      assert html =~ ~s(aria-expanded="true")
      assert has_element?(view, "#stops-map-checks-toggle", "Hide")
      assert has_element?(view, "#stops-map-checks-duplicate-1433-1434")
    end

    test "a version with nothing wrong has no disclosure at all", ctx do
      route = route_fixture(ctx.organization.id, ctx.version.id)

      pattern =
        route_pattern_fixture(ctx.organization.id, ctx.version.id, %{route_id: route.route_id})

      stop = stop_fixture(ctx.organization.id, ctx.version.id, %{stop_id: "A1", stop_name: "A"})

      route_pattern_stop_fixture(pattern, stop.stop_id, 1)

      view = open_map(ctx.editor_conn, ctx.version)

      # An empty disclosure says "0 things to check", which reads as a failed
      # read rather than as a version that is clean. It is simply absent.
      refute has_element?(view, "#stops-map-checks")
      assert has_element?(view, "#stops-map-list")
    end

    test "a search replaces the list, so the disclosure goes with it", ctx do
      duplicate_pair(ctx)
      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stops-map-checks")

      # The address service is not what this case is about, and a query it has
      # not answered yet is exactly what a real one does below its minimum.
      Mox.stub(GeocodingMock, :autocomplete, fn _query, _opts -> {:error, :text_too_short} end)
      Mox.allow(GeocodingMock, self(), view.pid)

      view
      |> element("#stops-map-search")
      |> render_change(%{"search" => %{"query" => "1st"}})

      assert has_element?(view, "#stops-map-search-results")
      refute has_element?(view, "#stops-map-checks")
    end
  end

  describe "the findings" do
    test "an unserved stop says so and says what to do about it", ctx do
      unserved_stop(ctx)
      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stops-map-checks-not-served-1531", "isn’t served")

      row = view |> element("#stops-map-checks-not-served-1531") |> render()

      assert words(row) =~ "No pattern stops here, so the export leaves it out"
      assert has_element?(view, "#stops-map-checks-not-served-1531 button", "Show stop")
    end

    test "the stops list is painted before the checks read finishes", ctx do
      duplicate_pair(ctx)

      {:ok, view, html} = live(ctx.editor_conn, ~p"/gtfs/#{ctx.version.id}/stops/map")

      # The first paint is the list's own loading state. The checks are read
      # after the model rather than with it, so a version that takes a moment to
      # read still shows where its stops are going to be, and the findings fill
      # in once it has.
      assert html =~ ~s(id="stops-map-panel-loading")
      refute html =~ ~s(id="stops-map-checks")

      render_async(view, 2_000)
      render_async(view, 2_000)

      assert has_element?(view, "#stops-map-list")
      assert has_element?(view, "#stops-map-checks")
    end
  end

  describe "the actions" do
    test "reviewing a pair selects the first stop and asks the map to go to it", ctx do
      duplicate_pair(ctx)
      view = open_map(ctx.editor_conn, ctx.version)

      view
      |> element("#stops-map-checks-duplicate-1433-1434 button", "Review pair")
      |> render_click()

      # The panel's heading names the stop the editor chose.
      assert has_element?(view, "#stops-map-panel h2", "US 101 & SE 1st St")
      assert has_element?(view, "#stops-map-panel", "ID 1433")

      assert_push_event(view, "stop_map:focus", %{lat: lat, lon: lon})
      assert_in_delta(lat, 44.63561, 0.0001)
      assert_in_delta(lon, -124.05317, 0.0001)
    end

    test "showing an unserved stop selects it and asks the map to go to it", ctx do
      unserved_stop(ctx)
      view = open_map(ctx.editor_conn, ctx.version)

      view
      |> element("#stops-map-checks-not-served-1531 button", "Show stop")
      |> render_click()

      assert has_element?(view, "#stops-map-panel h2", "Depot Road Gate")
      assert_push_event(view, "stop_map:focus", %{lat: 44.64, lon: -124.05317})
    end

    test "a key the panel is not showing selects nothing", ctx do
      unserved_stop(ctx)
      view = open_map(ctx.editor_conn, ctx.version)

      before = render(view)

      render_click(view, "review_check", %{"key" => "not-served|SOMEWHERE-ELSE"})
      render_click(view, "dismiss_check", %{"key" => "not-served|SOMEWHERE-ELSE"})

      # Nothing moved: the heading is the same, so no stop was selected and
      # therefore no focus was asked for.
      assert render(view) == before
    end
  end

  describe "dismissing a finding" do
    test "removes the row and writes nothing, so a new mount asks again", ctx do
      duplicate_pair(ctx)

      {:ok, first, _html} = live(ctx.editor_conn, ~p"/gtfs/#{ctx.version.id}/stops/map")
      render_async(first, 2_000)
      render_async(first, 2_000)

      assert has_element?(first, "#stops-map-checks-duplicate-1433-1434")

      first
      |> element("#stops-map-checks-dismiss-duplicate-1433-1434")
      |> render_click()

      refute has_element?(first, "#stops-map-checks-duplicate-1433-1434")

      # The disclosure itself goes with its last row: a summary reading "0 things
      # to check" looks like a read that failed rather than a version an editor
      # has just cleared.
      refute has_element?(first, "#stops-map-checks")
      assert has_element?(first, "#stops-map-list")

      # A second mount is a second session: the dismissal was never written
      # anywhere, so the finding is asked again.
      second = open_map(ctx.editor_conn, ctx.version)
      assert has_element?(second, "#stops-map-checks-duplicate-1433-1434")
    end

    test "the dismissal does not outlive the check it was made about", ctx do
      duplicate_pair(ctx)
      unserved_stop(ctx)
      view = open_map(ctx.editor_conn, ctx.version)

      assert render(view) =~ "2 things to check"

      view |> element("#stops-map-checks-toggle") |> render_click()

      view
      |> element("#stops-map-checks-dismiss-duplicate-1433-1434")
      |> render_click()

      assert render(view) =~ "1 thing to check"
      assert has_element?(view, "#stops-map-checks-not-served-1531")
    end
  end

  # The rendered element's own words, whitespace collapsed, so an assertion is
  # about what a reader reads rather than how the markup happens to wrap it.
  # Entities stay escaped, which is how the markup carries them.
  defp words(html),
    do:
      html
      |> String.replace(~r/<[^>]*>/, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.join(" ")
end
