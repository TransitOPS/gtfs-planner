defmodule GtfsPlannerWeb.Gtfs.StopsMapSearchTest do
  @moduledoc """
  Tests for the Map view's search: stops by name or ID in the browse panel, and
  biased address autocomplete in both the browse panel and add mode.

  Two things have to hold at once, and they pull against each other. Stop search
  is this version's own data and must keep working when the address service does
  not, so a failed autocomplete is a line beside the stop results rather than an
  empty panel. And the address results have to be ranked near this version's
  stops, because the editor is placing a stop in the feed they are editing
  rather than looking for an address anywhere — so the bias is the midpoint of
  the loaded stops' bounds, and a version with no located stop sends no bias at
  all rather than a fabricated one.

  Choosing a place is a placement, not a label: it writes the same
  `placement` a click on the map writes, so the pin, the caption and the map's
  mode are unchanged by how the editor got there. The expected points below are
  literals from the fixture rows and the mock's result, not values read back out
  of the code under test.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.GeocodingMock

  @result %GtfsPlanner.Geocoding.Result{
    formatted_address: "120 Depot Road, Cedar Valley",
    lat: 44.4759,
    lon: -73.2121
  }

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

  # The read runs asynchronously, so a test that wants what the read brought has
  # to wait for it rather than read the first paint. The wait is bounded rather
  # than the 100 ms default: the read is a real query in the SQL sandbox and
  # 100 ms is a coin toss on a loaded machine, which makes a flaky test look
  # like a broken panel.
  defp open_map(conn, version) do
    {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/stops/map")
    render_async(view, 2_000)
    view
  end

  # Expectation first, permission second: the address service is only reached
  # from a search, so the view exists by the time anything calls it, and the
  # expectation is scoped to this LiveView's process the way the garages tests
  # scope theirs.
  defp allow_geocoding(view, fun) do
    Mox.expect(GeocodingMock, :autocomplete, fun)
    Mox.allow(GeocodingMock, self(), view.pid)
  end

  # Two stops whose bounds have a midpoint an editor can check by eye: the
  # longitude span is -124.06..-124.04 and the latitude span 44.63..44.65.
  defp two_stops(ctx) do
    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: "1434",
      stop_name: "US 101 &amp; SE 1st St",
      stop_desc: "Northbound",
      stop_lat: Decimal.new("44.63000"),
      stop_lon: Decimal.new("-124.06000")
    })

    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: "1531",
      stop_name: "SE Bay Blvd",
      stop_lat: Decimal.new("44.65000"),
      stop_lon: Decimal.new("-124.04000")
    })
  end

  describe "searching the browse panel" do
    test "a query lists the stops it named and the places the address service returned", ctx do
      two_stops(ctx)

      view = open_map(ctx.editor_conn, ctx.version)
      allow_geocoding(view, fn "1st", _opts -> {:ok, [@result]} end)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "1st"}})
      |> render_change()

      # Stops and places are separate groups because they answer different
      # questions, and a reader who cannot tell them apart searches twice.
      assert has_element?(view, "#stops-map-search-results-stops #stops-map-row-1434")
      assert has_element?(view, "#stops-map-search-results-stops", "US 101 &amp; SE 1st St")
      refute has_element?(view, "#stops-map-search-results-stops #stops-map-row-1531")

      assert has_element?(
               view,
               "#stops-map-search-results-places",
               "120 Depot Road, Cedar Valley"
             )

      # The list the search replaced is gone: forty rows under a result set is
      # a page an editor scrolls past to see what they searched for.
      refute has_element?(view, "#stops-map-list")
    end

    test "a stop is found by its ID as well as its name", ctx do
      two_stops(ctx)

      view = open_map(ctx.editor_conn, ctx.version)
      allow_geocoding(view, fn _text, _opts -> {:ok, []} end)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "1531"}})
      |> render_change()

      assert has_element?(view, "#stops-map-search-results-stops #stops-map-row-1531")
      refute has_element?(view, "#stops-map-search-results-stops #stops-map-row-1434")
    end

    test "the address search is biased to the midpoint of the loaded stops", ctx do
      two_stops(ctx)

      view = open_map(ctx.editor_conn, ctx.version)

      allow_geocoding(view, fn "1st", opts ->
        # The adapter takes `{lon, lat}`; the midpoint of the two fixture rows
        # is -124.05, 44.64. Compared with a tolerance because the bounds come
        # from decimals, and a rounding difference is not a wrong bias.
        assert {lon, lat} = opts[:bias]
        assert_in_delta lon, -124.05, 0.0001
        assert_in_delta lat, 44.64, 0.0001
        {:ok, [@result]}
      end)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "1st"}})
      |> render_change()

      assert has_element?(view, "#stops-map-search-results-places")
    end

    test "a version with no located stop sends no bias rather than a made-up one", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "NOPOINT",
        stop_name: "No coordinates",
        stop_lat: nil,
        stop_lon: nil
      })

      view = open_map(ctx.editor_conn, ctx.version)

      allow_geocoding(view, fn "depot", opts ->
        assert opts[:bias] == nil
        {:ok, [@result]}
      end)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "depot"}})
      |> render_change()

      assert has_element?(view, "#stops-map-search-results-places")
    end

    test "choosing a stop result opens its editor and the panel says which one", ctx do
      two_stops(ctx)

      view = open_map(ctx.editor_conn, ctx.version)
      allow_geocoding(view, fn _text, _opts -> {:ok, []} end)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "1st"}})
      |> render_change()

      view |> element("#stops-map-row-1434") |> render_click()

      # The editor is behind every row, so choosing a result opens the
      # editor for that stop; the heading it has to carry is the one that says
      # which stop this is.
      assert view |> element("#stops-map-edit-panel") |> render() =~ "Stop · ID 1434"
    end

    # The panel only shows what the search returned. A forged id from another
    # session's result set would select a stop the editor cannot see, and the
    # heading would then be the heading for a stop nobody chose.
    test "a stop id this search did not return is refused", ctx do
      two_stops(ctx)

      view = open_map(ctx.editor_conn, ctx.version)
      allow_geocoding(view, fn _text, _opts -> {:ok, []} end)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "1st"}})
      |> render_change()

      render_hook(view, "select_stop", %{"stop_id" => "1531"})

      assert view |> element("#stops-map-panel") |> render() =~ "Stops in this area"
      refute view |> element("#stops-map-panel") |> render() =~ "SE Bay Blvd"
    end

    test "clearing the field gives the list back", ctx do
      two_stops(ctx)

      view = open_map(ctx.editor_conn, ctx.version)
      allow_geocoding(view, fn _text, _opts -> {:ok, [@result]} end)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "1st"}})
      |> render_change()

      refute has_element?(view, "#stops-map-list")

      view
      |> form("#stops-map-search", %{"search" => %{"query" => ""}})
      |> render_change()

      assert has_element?(view, "#stops-map-list")
      refute has_element?(view, "#stops-map-search-results")
    end

    test "a query that matches nothing says what to try", ctx do
      two_stops(ctx)

      view = open_map(ctx.editor_conn, ctx.version)
      allow_geocoding(view, fn _text, _opts -> {:ok, []} end)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "zzz"}})
      |> render_change()

      assert has_element?(view, "#stops-map-search-results-empty", "Try a street name")
    end
  end

  describe "when the address service fails" do
    test "the stop results stay and the panel says address search is unavailable", ctx do
      two_stops(ctx)

      view = open_map(ctx.editor_conn, ctx.version)
      allow_geocoding(view, fn _text, _opts -> {:error, :unavailable} end)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "1st"}})
      |> render_change()

      # Stop search is this version's own rows, so it answers anyway.
      assert has_element?(view, "#stops-map-search-results-stops #stops-map-row-1434")

      assert has_element?(
               view,
               "#stops-map-search-results-unavailable",
               "Address search is unavailable"
             )

      refute has_element?(view, "#stops-map-search-results-places")
    end
  end

  describe "add mode" do
    test "choosing a place sets the draft position the pin is drawn at", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      view |> element("#stops-map-add-stop") |> render_click()

      allow_geocoding(view, fn "depot", _opts -> {:ok, [@result]} end)

      view
      |> form("#stops-map-address-search", %{"search" => %{"query" => "depot"}})
      |> render_change()

      assert has_element?(view, "#stops-map-address-results-places")

      view |> element("[data-stop-map-place]") |> render_click()

      # A place is a placement, written the same way a click writes one: the
      # server reads the point and echoes it as the pin, so add mode ends here.
      assert_push_event(view, "stop_map:mode", %{
        mode: :browse,
        pin: %{lat: 44.4759, lon: -73.2121, label: "New stop"},
        ghost: nil
      })

      assert has_element?(view, "#stops-map-caption", "Drag the pin to adjust")
    end

    test "add mode offers an address, not this version's stops", ctx do
      two_stops(ctx)

      view = open_map(ctx.editor_conn, ctx.version)

      view |> element("#stops-map-add-stop") |> render_click()

      allow_geocoding(view, fn "1st", _opts -> {:ok, [@result]} end)

      view
      |> form("#stops-map-address-search", %{"search" => %{"query" => "1st"}})
      |> render_change()

      # The add panel is for a stop that does not exist yet. Listing the stops
      # that do would offer to edit this version from inside a create form.
      refute has_element?(view, "#stops-map-row-1434")
      assert has_element?(view, "#stops-map-address-results-places")
    end

    test "an address failure in add mode says so and keeps the field", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      view |> element("#stops-map-add-stop") |> render_click()

      allow_geocoding(view, fn _text, _opts -> {:error, :network_error} end)

      view
      |> form("#stops-map-address-search", %{"search" => %{"query" => "depot"}})
      |> render_change()

      assert has_element?(view, "#stops-map-address-results-unavailable")
      # The draft survives the failure: an editor who retypes an address does not
      # want the half they had to do it again.
      assert has_element?(view, "#stops-map-address-search-query[value=depot]")
    end
  end
end
