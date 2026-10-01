defmodule GtfsPlannerWeb.Gtfs.StopsMapLiveTest do
  @moduledoc """
  Merge evidence (EV-23) for the Map view shell: the route, the header and its
  List | Map switch, the map stage, and the browse panel that lists the stops
  inside the current view.

  The panel's list is the hook's `stop_map_bounds` event turned into rows, so
  the tests write that event by hand rather than driving a browser: a view is
  only worth asserting if a bounds report from one session cannot reach another
  session's panel, and a bounds report that is not a rectangle must be ignored
  rather than clamped.

  The map states are the reason the stage is written as it is. A street basemap
  that fails has to leave the stop list, the route lines and coordinate entry
  working, so `map_unavailable` adds a banner and removes nothing. A version
  with no stops has to read as a version nobody has added stops to yet, not as
  a failed read, so it gets the first-use panel rather than an empty list.

  The focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_sa28 ELIXIR_ERL_OPTIONS="+S 4" mix test test/gtfs_planner_web/live/gtfs/stops_map_live_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

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
      editor: editor,
      version: version,
      editor_conn: log_in_user(build_conn(), editor, organization: organization)
    }
  end

  # The read runs asynchronously, so a test that wants what the read brought has
  # to wait for it rather than read the first paint. This is the same wait a
  # browser makes without knowing it is making one.
  defp open_map(conn, version) do
    {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/stops/map")
    render_async(view)
    view
  end

  # The rendered element's own words, whitespace collapsed, so an assertion is
  # about what a reader reads rather than how the markup happens to wrap it.
  defp words(html),
    do:
      html
      |> String.replace(~r/<[^>]*>/, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.join(" ")

  # Interpolation-free error text, so an assertion does not depend on Ecto's
  # `translate_error/3` being configured.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "the route and the header" do
    test "the map route renders the map page, not the stop page", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stops-map-page")
      assert has_element?(view, "#stops-map-stage")
      refute has_element?(view, "#stops-page")
    end

    test "the header offers both views, with the map one current", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stops-map-view-list", "List")
      assert has_element?(view, "#stops-map-view-map", "Map")

      assert view
             |> element("#stops-map-view-list")
             |> render() =~ ~s(href="#{~p"/gtfs/#{ctx.version.id}/stops"}")

      assert has_element?(view, "#stops-map-view-map[aria-current=page]")
      assert has_element?(view, "#stops-map-add-stop", "Add stop")
    end

    test "the header counts the version's stops and stations", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{stop_id: "A1", stop_name: "A"})
      stop_fixture(ctx.organization.id, ctx.version.id, %{stop_id: "A2", stop_name: "B"})
      stop_fixture(ctx.organization.id, ctx.version.id, %{stop_id: "P1", location_type: 1})

      view = open_map(ctx.editor_conn, ctx.version)

      assert view |> element("#stops-map-scope-note") |> render() =~ "2 stops and 1 station"
    end

    test "a version with no stops says so rather than counting nothing", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      assert view |> element("#stops-map-scope-note") |> render() =~ "No stops yet"
    end
  end

  describe "the browse panel" do
    test "lists the stops inside the view the hook reports", ctx do
      inside =
        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: "1434",
          stop_name: "US 101 &amp; SE 1st St",
          stop_desc: "Northbound",
          stop_lat: Decimal.new("44.63561"),
          stop_lon: Decimal.new("-124.05317")
        })

      _outside =
        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: "1531",
          stop_name: "Far away",
          stop_lat: Decimal.new("44.90000"),
          stop_lon: Decimal.new("-124.00000")
        })

      view = open_map(ctx.editor_conn, ctx.version)

      # Before any view is reported the panel lists the whole version, so both
      # stops are there; the bounds report is what narrows the list.
      assert has_element?(view, "#stops-map-row-1434")
      assert has_element?(view, "#stops-map-row-1531")

      render_hook(view, "stop_map_bounds", %{
        "south" => 44.63,
        "west" => -124.06,
        "north" => 44.64,
        "east" => -124.05
      })

      assert has_element?(view, "#stops-map-list")
      assert has_element?(view, "#stops-map-row-1434")

      refute has_element?(view, "#stops-map-row-1531")

      assert has_element?(
               view,
               "#stops-map-row-1434",
               "US 101 &amp; SE 1st St"
             )

      assert has_element?(view, "#stops-map-row-1434", "Northbound · Not served · ID 1434")

      # The subtitle is the reason the list is not a search result: it says the
      # list follows the map.
      assert view |> element("#stops-map-panel") |> render() =~ "on the map"
      assert inside.stop_id == "1434"
    end

    test "a stop no pattern or stop time serves says so on its row", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1531",
        stop_name: "SE Bay Blvd",
        stop_lat: Decimal.new("44.63095"),
        stop_lon: Decimal.new("-124.04077")
      })

      view = open_map(ctx.editor_conn, ctx.version)

      render_hook(view, "stop_map_bounds", %{
        "south" => 44.60,
        "west" => -124.10,
        "north" => 44.70,
        "east" => -124.00
      })

      assert has_element?(view, "#stops-map-row-1531", "Not served · ID 1531")
    end

    test "a station lists its bays and sits above the stops around it", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "ST-NTC",
        stop_name: "Newport Transit Center",
        location_type: 1,
        stop_lat: Decimal.new("44.63470"),
        stop_lon: Decimal.new("-124.05325")
      })

      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "NTC-A",
        stop_name: "Bay A",
        parent_station: "ST-NTC",
        stop_lat: Decimal.new("44.63461"),
        stop_lon: Decimal.new("-124.05348")
      })

      view = open_map(ctx.editor_conn, ctx.version)

      render_hook(view, "stop_map_bounds", %{
        "south" => 44.60,
        "west" => -124.10,
        "north" => 44.70,
        "east" => -124.00
      })

      assert has_element?(view, "#stops-map-row-ST-NTC", "Station · 1 bay")

      # Stations first: an editor looking for a stop is usually looking for its
      # station, and the bays are reachable from it.
      html = view |> element("#stops-map-list-items") |> render()
      assert String.match?(html, ~r/ST-NTC.*NTC-A/s)
    end

    test "a row names the routes that serve the stop", ctx do
      route =
        route_fixture(ctx.organization.id, ctx.version.id, %{
          route_id: "12",
          route_short_name: "12",
          route_long_name: "Nye Beach"
        })

      pattern =
        route_pattern_fixture(ctx.organization.id, ctx.version.id, %{
          route_pattern_id: "P12",
          route_id: route.route_id
        })

      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1434",
        stop_name: "US 101 &amp; SE 1st St",
        stop_lat: Decimal.new("44.63561"),
        stop_lon: Decimal.new("-124.05317")
      })

      route_pattern_stop_fixture(pattern, "1434", 1)

      view = open_map(ctx.editor_conn, ctx.version)

      render_hook(view, "stop_map_bounds", %{
        "south" => 44.60,
        "west" => -124.10,
        "north" => 44.70,
        "east" => -124.00
      })

      assert has_element?(view, "#stops-map-row-1434", "12")

      # The long name is on the badge rather than in the row: the row's job is
      # to say which buses stop here, and the long name would crowd out the
      # second stop's name in the list.
      assert view |> element("#stops-map-row-1434") |> render() =~ "Nye Beach"
    end

    test "a route badge picks ink that reads on the route's own colour", ctx do
      # A pale route colour in white is unreadable, and a dark one in black is
      # unreadable too. The badge chooses from the colour rather than assuming,
      # because a route number nobody can read beside the stop's name is worse
      # than no badge at all. The expectations below are the contract; the
      # fixture loop only writes the rows.
      for {route_id, colour, text} <- [
            {"1", "1F5FBF", "000000"},
            {"3", "4B1F78", "000000"},
            # Black on a pale route colour reads, so the named ink stands.
            {"4", "FFE066", "000000"},
            # White on a pale route colour does not, so the badge picks its own.
            {"5", "FFE066", "FFFFFF"},
            {"55", "FFFFFF", "000000"},
            # A blank `route_text_color` becomes `000000` on insert, which is a
            # declined answer rather than a chosen one; on a dark route colour it
            # is unreadable, so the badge picks its own ink.
            {"6", "1F5FBF", "000000"},
            # An agency's own text colour is honoured when it reads.
            {"7", "FFFFFF", "1F5FBF"}
          ] do
        route =
          route_fixture(ctx.organization.id, ctx.version.id, %{
            route_id: route_id,
            route_short_name: route_id,
            route_color: colour,
            route_text_color: text
          })

        pattern =
          route_pattern_fixture(ctx.organization.id, ctx.version.id, %{
            route_pattern_id: "P-#{route_id}",
            route_id: route.route_id
          })

        stop_fixture(ctx.organization.id, ctx.version.id, %{
          stop_id: "S-#{route_id}",
          stop_lat: Decimal.new("44.63561"),
          stop_lon: Decimal.new("-124.05317")
        })

        route_pattern_stop_fixture(pattern, "S-#{route_id}", 1)
      end

      view = open_map(ctx.editor_conn, ctx.version)

      for {route_id, _colour, _text, ink} <- [
            {"1", "1F5FBF", "000000", "#ffffff"},
            {"3", "4B1F78", "000000", "#ffffff"},
            {"4", "FFE066", "000000", "#000000"},
            {"5", "FFE066", "FFFFFF", "#0a1330"},
            {"55", "FFFFFF", "000000", "#000000"},
            {"6", "1F5FBF", "000000", "#ffffff"},
            {"7", "FFFFFF", "1F5FBF", "#1F5FBF"}
          ] do
        html = view |> element("#stops-map-row-S-#{route_id}") |> render()

        assert html =~ "color: #{ink}", "route #{route_id} needs #{ink} ink"
      end
    end

    test "a route colour that is not six hex digits never reaches the badge", ctx do
      # `Route.changeset/2` refuses it, so the component's own fallback is a
      # second line rather than the only one. Asserted here because a badge that
      # pasted an unvalidated colour into a `style` attribute could close it and
      # restyle the row.
      assert {:error, changeset} =
               Gtfs.create_route(%{
                 organization_id: ctx.organization.id,
                 gtfs_version_id: ctx.version.id,
                 route_id: "BAD",
                 route_short_name: "BAD",
                 route_color: "not-a-colour"
               })

      assert %{route_color: ["must be a valid 6-character hex color code"]} = errors_on(changeset)
    end

    test "a stop without coordinates is not listed, because it is nowhere to put", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "9999",
        stop_name: "Nowhere",
        stop_lat: nil,
        stop_lon: nil
      })

      view = open_map(ctx.editor_conn, ctx.version)

      render_hook(view, "stop_map_bounds", %{
        "south" => -90.0,
        "west" => -180.0,
        "north" => 90.0,
        "east" => 180.0
      })

      refute has_element?(view, "#stops-map-row-9999")
    end
  end

  describe "the view the hook reports" do
    test "a report before any bounds lists every located stop", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1434",
        stop_lat: Decimal.new("44.63561"),
        stop_lon: Decimal.new("-124.05317")
      })

      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stops-map-row-1434")

      # The header and the panel state the same count in the same words, so the
      # page never contradicts itself about how many stops the version holds.
      panel = view |> element("#stops-map-panel") |> render()
      header = view |> element("#stops-map-scope-note") |> render()

      # The header's sentence and the panel's sentence are the same sentence,
      # because both come from `scope_note/1`. A panel that counted differently
      # would put two different counts of the same version on one screen.
      assert words(header) == "1 stop in " <> ctx.version.name
      assert String.contains?(words(panel), words(header))
    end

    test "an inverted or unreadable view is ignored, not clamped", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1434",
        stop_lat: Decimal.new("44.63561"),
        stop_lon: Decimal.new("-124.05317")
      })

      view = open_map(ctx.editor_conn, ctx.version)

      render_hook(view, "stop_map_bounds", %{
        "south" => 44.60,
        "west" => -124.10,
        "north" => 44.70,
        "east" => -124.00
      })

      assert has_element?(view, "#stops-map-list")

      # An inverted box would list nothing, which reads as "this feed has no
      # stops". A box that is not a box at all would do the same.
      render_hook(view, "stop_map_bounds", %{
        "south" => 44.70,
        "west" => -124.00,
        "north" => 44.60,
        "east" => -124.10
      })

      assert has_element?(view, "#stops-map-row-1434")

      render_hook(view, "stop_map_bounds", %{"south" => "north", "west" => "of"})

      assert has_element?(view, "#stops-map-row-1434")

      render_hook(view, "stop_map_bounds", %{})

      assert has_element?(view, "#stops-map-row-1434")
    end

    test "a report of a string number is read; a report of an unknown shape is not", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1434",
        stop_lat: Decimal.new("44.63561"),
        stop_lon: Decimal.new("-124.05317")
      })

      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1531",
        stop_lat: Decimal.new("44.90000"),
        stop_lon: Decimal.new("-124.00000")
      })

      view = open_map(ctx.editor_conn, ctx.version)

      # JSON numbers arrive as numbers and query params as strings; both are the
      # same view.
      render_hook(view, "stop_map_bounds", %{
        "south" => "44.60",
        "west" => "-124.10",
        "north" => "44.70",
        "east" => "-124.00"
      })

      assert has_element?(view, "#stops-map-row-1434")
      refute has_element?(view, "#stops-map-row-1531")
    end
  end

  describe "the map stage" do
    test "the hook owns the canvas and the page keeps the panel", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stop-map[phx-hook=StopMap][phx-update=ignore]")
      assert has_element?(view, "#stops-map-panel")
      assert has_element?(view, "#stops-map-loading-caption", "Loading map")
    end

    test "the stage reports itself ready when the hook says it is", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      render_hook(view, "stop_map_ready", %{})

      refute has_element?(view, "#stops-map-loading")
      assert has_element?(view, "#stop-map")
      assert has_element?(view, "#stops-map-panel")
    end

    test "an unavailable street map keeps the stop list and offers a retry", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1434",
        stop_lat: Decimal.new("44.63561"),
        stop_lon: Decimal.new("-124.05317")
      })

      view = open_map(ctx.editor_conn, ctx.version)

      render_hook(view, "stop_map_ready", %{})
      render_hook(view, "map_unavailable", %{})

      assert has_element?(view, "#stops-map-unavailable", "Street map unavailable")

      assert has_element?(
               view,
               "#stops-map-unavailable",
               "you can place a stop by entering coordinates"
             )

      assert has_element?(view, "#stops-map-retry", "Retry map")

      # The list is the part of the page that does not need a basemap.
      render_hook(view, "stop_map_bounds", %{
        "south" => 44.60,
        "west" => -124.10,
        "north" => 44.70,
        "east" => -124.00
      })

      assert has_element?(view, "#stops-map-row-1434")
      assert has_element?(view, "#stops-map-add-stop")

      view |> element("#stops-map-retry") |> render_click()

      assert has_element?(view, "#stops-map-loading")
      assert has_element?(view, "#stops-map-row-1434")
    end
  end

  describe "the payload the hook draws" do
    test "is pushed to the hook when it reports itself ready", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1434",
        stop_name: "US 101 &amp; SE 1st St",
        stop_lat: Decimal.new("44.63561"),
        stop_lon: Decimal.new("-124.05317")
      })

      view = open_map(ctx.editor_conn, ctx.version)

      # The scene is pushed on the hook's own ready report rather than on the
      # read, because a hook that mounts after the read has finished would
      # otherwise draw an empty map and wait for a version change that is not
      # coming.
      render_hook(view, "stop_map_ready", %{})

      assert_push_event(view, "stop_map:scene", %{payload: payload})

      # The push carries the model's own atom keys; the client sees the JSON
      # form of exactly this map, which is why `StopsMap.display_payload/2`
      # exists rather than the LiveView assembling the shape itself.
      assert [%{stop_id: "1434", point: [-124.05317, 44.63561]}] = payload.stops
      assert is_float(payload.tolerance_m)
      assert payload.tolerance_m == 2.0
      assert is_list(payload.lines)
      assert is_map(payload.routes)
    end

    test "is pushed again on a retry, so a failed basemap redraws", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1434",
        stop_lat: Decimal.new("44.63561"),
        stop_lon: Decimal.new("-124.05317")
      })

      view = open_map(ctx.editor_conn, ctx.version)

      render_hook(view, "stop_map_ready", %{})
      assert_push_event(view, "stop_map:scene", %{payload: first})
      assert [%{stop_id: "1434"}] = first.stops

      render_hook(view, "map_unavailable", %{})
      view |> element("#stops-map-retry") |> render_click()

      assert_push_event(view, "stop_map:scene", %{payload: second})
      assert second == first
    end
  end

  describe "the first-use panel" do
    test "a version with no stops explains stops and offers both ways in", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stops-map-first-use", "No stops in this version yet")

      assert has_element?(
               view,
               "#stops-map-first-use",
               "Stops are where your buses pick up riders"
             )

      assert has_element?(view, "#stops-map-first-use-add", "Add stop")
      assert has_element?(view, "#stops-map-first-use-import", "Import feed")

      refute has_element?(view, "#stops-map-list")
    end
  end

  describe "add mode" do
    test "the header's Add stop opens the panel, and Cancel closes it", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1434",
        stop_lat: Decimal.new("44.63561"),
        stop_lon: Decimal.new("-124.05317")
      })

      view = open_map(ctx.editor_conn, ctx.version)

      assert has_element?(view, "#stops-map-list")

      view |> element("#stops-map-add-stop") |> render_click()

      assert has_element?(view, "#stops-map-add-panel", "New stop")
      assert has_element?(view, "#stops-map-caption", "Click the curb where riders wait")
      refute has_element?(view, "#stops-map-list")

      view |> element("#stops-map-add-cancel") |> render_click()

      assert has_element?(view, "#stops-map-list")
      refute has_element?(view, "#stops-map-add-panel")
    end

    test "the first-use panel's Add stop opens the same panel", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      view |> element("#stops-map-first-use-add") |> render_click()

      assert has_element?(view, "#stops-map-add-panel")
    end

    test "opening the panel tells the hook to add, and closing it tells the hook to stop", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      view |> element("#stops-map-add-stop") |> render_click()

      # The server says which mode the map is in. A browser that decided for
      # itself would be a map an editor could not place a stop on.
      assert_push_event(view, "stop_map:mode", %{mode: :add, pin: nil, ghost: nil})

      view |> element("#stops-map-add-cancel") |> render_click()

      assert_push_event(view, "stop_map:mode", %{mode: :browse, pin: nil, ghost: nil})
    end

    test "a placed point becomes the pin, and the caption moves to dragging it", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      view |> element("#stops-map-add-stop") |> render_click()

      render_hook(view, "place", %{"lat" => 44.63561, "lon" => -124.05317})

      assert_push_event(view, "stop_map:mode", %{
        mode: :browse,
        pin: %{lat: 44.63561, lon: -124.05317, label: "New stop"},
        ghost: nil
      })

      assert has_element?(view, "#stops-map-caption", "Drag the pin to adjust")
      assert has_element?(view, "#stops-map-caption", "30 ft with Shift")
    end

    test "a dragged pin is the server's point too, and cancelling drops it", ctx do
      view = open_map(ctx.editor_conn, ctx.version)

      view |> element("#stops-map-add-stop") |> render_click()
      render_hook(view, "place", %{"lat" => 44.63561, "lon" => -124.05317})

      render_hook(view, "pin_moved", %{"lat" => 44.63571, "lon" => -124.05317})

      assert_push_event(view, "stop_map:mode", %{
        mode: :browse,
        pin: %{lat: 44.63571, lon: -124.05317, label: "New stop"},
        ghost: nil
      })

      view |> element("#stops-map-add-cancel") |> render_click()

      assert_push_event(view, "stop_map:mode", %{mode: :browse, pin: nil})
      # Cancelling is not "go back to placing": it is the browse panel again, so
      # the add caption goes with it.
      refute has_element?(view, "#stops-map-caption")
    end

    # A lat/lon pair is a position on the Earth. A report that does not carry
    # one is refused rather than believed: a pin drawn at latitude 0 would be a
    # placement on the equator that nobody chose.
    for params <- [
          %{"lat" => "north", "lon" => -124.05317},
          %{"lat" => 44.63561, "lon" => "west"},
          %{"lat" => 91.0, "lon" => -124.05317},
          %{"lat" => 44.63561, "lon" => -181.0},
          %{}
        ] do
      test "a placement that carries no position is refused: #{inspect(params)}", ctx do
        view = open_map(ctx.editor_conn, ctx.version)

        view |> element("#stops-map-add-stop") |> render_click()

        render_hook(view, "place", unquote(Macro.escape(params)))

        refute_push_event(view, "stop_map:mode", %{pin: %{}})
        assert has_element?(view, "#stops-map-caption", "Click the curb where riders wait")
      end
    end
  end

  describe "access" do
    test "a member without the editor role is turned away, as the list view is", ctx do
      reader = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: reader.id,
        organization_id: ctx.organization.id,
        roles: ["pathways_studio_admin"]
      })

      conn = log_in_user(build_conn(), reader, organization: ctx.organization)

      assert {:error, {:redirect, %{to: to}}} =
               live(conn, ~p"/gtfs/#{ctx.version.id}/stops/map")

      # The same destination `StopsLive` sends a reader to, so the two views
      # refuse the same person the same way.
      assert to == "/admin/organizations"
    end

    test "an organization with no membership is turned away", ctx do
      stranger = user_fixture()
      conn = log_in_user(build_conn(), stranger, organization: ctx.organization)

      assert {:error, {:redirect, %{to: _to}}} =
               live(conn, ~p"/gtfs/#{ctx.version.id}/stops/map")
    end
  end
end
