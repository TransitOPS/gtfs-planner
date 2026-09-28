defmodule GtfsPlannerWeb.Gtfs.TransfersLiveMapTest do
  @moduledoc """
  Merge evidence (EV-27) for the connection map region and the pick-on-map flow.

  The page owns the map's server side. Every change of the connection the context
  pane describes — a selected rule, the opening draft, a moved draft endpoint, a
  finished pick — pushes the connection's endpoints to the `TransferMap` hook, and
  the hook's own reports are answered only when they carry the generation and the
  pick id this page is currently running. The region renders the header, the
  legend, the endpoints the payload names without coordinates, and the
  "Map unavailable" panel with its retry, all outside the `phx-update="ignore"`
  canvas the hook owns.

  Pick-on-map is the same connection answered from the map instead of the named
  field: a session carries the next id, its candidates are this version's stops
  inside the box the hook reports, and a pick resolves the named stop inside this
  page's own organization and version before it can reach the draft. A pick that
  names an entrance, an unknown stop, another version's stop, another session's id
  or a session that has ended changes nothing, and the route and trip the side had
  answered for the gone stop are cleared.

  The hook events here are written by hand, so no browser and no Leaflet are
  involved; the map's own rendering and the same pick driven by an operator are
  the `map:` and `pick:` journeys in `assets/e2e/transfers.spec.js` (step 30).

  The focused command is deferred to branch review:
  `MIX_TEST_PARTITION=_xfer15 mix test test/gtfs_planner_web/live/gtfs/transfers_live_map_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  # The editor's form submits the whole draft; a case names the fields it moved and
  # the rest travel the way a browser form sends them.
  @blank_draft %{
    "from_stop_id" => "",
    "to_stop_id" => "",
    "from_route_id" => "",
    "to_route_id" => "",
    "from_trip_id" => "",
    "to_trip_id" => "",
    "transfer_type" => "2",
    "min_transfer_time" => ""
  }

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    transfer_network_fixture(organization.id, version.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      user: user,
      version: version
    }
  end

  describe "the map region" do
    test "renders the header, the hook element, the legend and the version extent", ctx do
      scoped(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        transfer_type: 2,
        min_transfer_time: 180
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      document = doc(view)

      assert has_element?(view, "#transfer-map-region")
      assert text_of(document, "#transfer-map-title") == "Selected connection"
      assert has_element?(view, "#transfer-map-fit", "Fit connection")

      # The canvas is the hook's: the server never patches inside it, and the read
      # of both data attributes happens once at mount.
      assert has_element?(view, "#transfer-map[phx-hook='TransferMap'][phx-update='ignore']")
      assert generation(document) =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-/

      assert Jason.decode!(attribute(document, "#transfer-map", "data-extent")) ==
               %{"south" => 39.99, "west" => -75.02, "north" => 40.01, "east" => -74.99}

      legend = text_of(document, "#transfer-map-legend")
      assert legend =~ "A Arrival"
      assert legend =~ "B Departure"
      assert legend =~ "Rule direction · not a walking route"

      # Nothing is failing, nothing is being picked and no endpoint is unplaced.
      refute has_element?(view, "#transfer-map-unavailable")
      refute has_element?(view, "#transfer-pick-callout")
      refute has_element?(view, "#transfer-pick-truncated")
      refute has_element?(view, "#transfer-map-missing")
    end

    test "pushes the selected connection on load and again when another row is selected", ctx do
      first =
        scoped(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          transfer_type: 2,
          min_transfer_time: 180
        })

      second = scoped(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: second.id))

      assert_push_event(view, "transfer_map:show", %{
        a: %{stop_id: "MKT", lat: 40.01, lon: -75.01},
        b: %{stop_id: "HBR", lat: 39.99, lon: -74.99},
        children: [],
        missing_coordinates: [],
        fit: true
      })

      view |> element("#transfer-select-#{first.id}") |> render_click()

      assert_push_event(view, "transfer_map:show", %{
        a: %{stop_id: "CEN-A"},
        b: %{stop_id: "CEN-C"},
        fit: true
      })
    end

    test "names an endpoint of this version that has no coordinates", ctx do
      scoped(ctx, %{from_stop_id: "NOC", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert_push_event(view, "transfer_map:show", %{
        a: nil,
        b: %{stop_id: "HBR"},
        missing_coordinates: ["No Coordinates"]
      })

      assert has_element?(view, "#transfer-map-missing", "No Coordinates has no coordinates")
    end
  end

  describe "the map's own state" do
    test "a failed map shows the panel and retry restores the canvas", ctx do
      scoped(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        transfer_type: 2,
        min_transfer_time: 180
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      generation = generation(doc(view))

      render_hook(view, "transfer_map_state", %{
        "generation" => generation,
        "state" => "imagery_unavailable"
      })

      document = doc(view)

      assert has_element?(view, "#transfer-map-unavailable", "Map unavailable")

      assert text_of(document, "#transfer-map-unavailable") =~
               "Stop names and rule details are still available."

      assert has_element?(view, "#transfer-map-retry", "Retry map")

      # The rest of the page is untouched by the map's failure: the list still
      # lists the rule and the inspector still explains it (AC-22).
      assert has_element?(view, "#transfers")
      assert has_element?(view, "#transfer-inspector")

      view |> element("#transfer-map-retry") |> render_click()

      assert_push_event(view, "transfer_map:retry", %{})
      refute has_element?(view, "#transfer-map-unavailable")
      assert has_element?(view, "#transfer-map")
    end

    test "a fatal map shows the same panel, and another mount's report changes nothing", ctx do
      scoped(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        transfer_type: 2,
        min_transfer_time: 180
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      generation = generation(doc(view))

      render_hook(view, "transfer_map_state", %{"generation" => generation, "state" => "fatal"})
      assert has_element?(view, "#transfer-map-unavailable")

      # A report that is not this mount's, and a state the page does not know, are
      # both ignored rather than believed (R10).
      render_hook(view, "transfer_map_state", %{
        "generation" => "00000000-0000-4000-8000-000000000000",
        "state" => "ready"
      })

      assert has_element?(view, "#transfer-map-unavailable")

      render_hook(view, "transfer_map_state", %{"generation" => generation, "state" => "unknown"})
      assert has_element?(view, "#transfer-map-unavailable")

      render_hook(view, "transfer_map_state", %{"generation" => generation, "state" => "ready"})
      refute has_element?(view, "#transfer-map-unavailable")
    end
  end

  describe "pick on map" do
    test "starting a pick opens a session and its candidates are this version's stops", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()
      assert text_of(doc(view), "#transfer-map-title") == "Preview this connection"
      assert has_element?(view, "#transfer-pick-from", "Pick on map")
      assert has_element?(view, "#transfer-pick-to", "Pick on map")

      view |> element("#transfer-pick-from") |> render_click()

      assert_push_event(view, "transfer_map:pick_start", %{pick_id: 1, side: "a"})
      assert text_of(doc(view), "#transfer-map-title") == "Choose the arrival stop"

      assert has_element?(
               view,
               "#transfer-pick-callout",
               "Select a stop on the map, or use the named stop field."
             )

      assert has_element?(view, "#transfer-pick-cancel", "Cancel picking")
      refute has_element?(view, "#transfer-pick-truncated")

      render_hook(view, "transfer_map_bounds", %{
        "pick_id" => 1,
        "south" => 39.9,
        "west" => -75.1,
        "north" => 40.1,
        "east" => -74.9
      })

      # The stops a rule may name, in name then id order; the entrance (type 2) and
      # the stop without coordinates are not candidates (R2).
      assert_push_event(view, "transfer_map:pick_candidates", %{
        pick_id: 1,
        truncated: false,
        stops: [
          %{stop_id: "CEN-A", name: "Central · Bay A"},
          %{stop_id: "CEN-C"},
          %{stop_id: "CEN"},
          %{stop_id: "HBR"},
          %{stop_id: "MKT"},
          %{stop_id: "MUS"}
        ]
      })

      # A box the parser refuses answers nothing at all.
      render_hook(view, "transfer_map_bounds", %{
        "pick_id" => 1,
        "south" => "not-a-number",
        "west" => -75.1,
        "north" => 40.1,
        "east" => -74.9
      })

      refute_push_event(view, "transfer_map:pick_candidates", %{pick_id: 1})
    end

    test "a truncated candidate list asks the operator to zoom in", ctx do
      insert_extra_stops(ctx, 201)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()
      view |> element("#transfer-pick-to") |> render_click()

      assert_push_event(view, "transfer_map:pick_start", %{pick_id: 1, side: "b"})

      render_hook(view, "transfer_map_bounds", %{
        "pick_id" => 1,
        "south" => 10.0,
        "west" => 10.0,
        "north" => 10.5,
        "east" => 10.5
      })

      assert_push_event(view, "transfer_map:pick_candidates", %{pick_id: 1, truncated: true})
      assert has_element?(view, "#transfer-pick-truncated", "Zoom in to see all stops.")
    end

    test "picking a stop sets that side and clears the route and trip it had", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()

      # A scope change drops every selector answered for the previous scope, so the
      # route is chosen after the scope is set.
      change_draft(view, "scope", :routes, %{"from_stop_id" => "MKT"})

      change_draft(view, "from_route_id", :routes, %{
        "from_stop_id" => "MKT",
        "from_route_id" => "12"
      })

      assert has_element?(view, "#transfer-from-route option[value='12'][selected]")

      view |> element("#transfer-pick-from") |> render_click()
      assert_push_event(view, "transfer_map:pick_start", %{pick_id: 1, side: "a"})

      render_hook(view, "transfer_map_pick", %{"pick_id" => 1, "stop_id" => "CEN"})

      # The session is over, and the map now draws the draft's connection.
      assert_push_event(view, "transfer_map:pick_end", %{pick_id: 1})
      assert_push_event(view, "transfer_map:show", %{a: %{stop_id: "CEN"}, b: nil, fit: true})

      document = doc(view)

      assert text_of(document, "#transfer-map-title") == "Preview this connection"
      refute has_element?(view, "#transfer-pick-callout")

      # The picked stop is the side's stop: the field, its LiveSelect and the
      # draft's own preview all answer it.
      assert has_element?(view, "#transfer_from_stop_id[value='CEN']")
      assert has_element?(view, "#transfer_from_stop_id_text_input[value='Central Station']")
      assert text_of(document, "#transfer-from-stop-hint") == "Station · includes 2 platforms"
      assert text_of(document, "#transfer-draft-preview") =~ "Central Station"

      # Its route was answered for the stop that is gone.
      refute has_element?(view, "#transfer-from-route option[value='12'][selected]")
      assert has_element?(view, "#transfer-dirty")
    end

    test "a pick that names a stop this page cannot use changes nothing", ctx do
      other_version = gtfs_version_fixture(ctx.organization.id)

      stop_fixture(ctx.organization.id, other_version.id, %{
        stop_id: "OTHER",
        stop_name: "Another version's stop",
        stop_lat: "40.0100",
        stop_lon: "-75.0100"
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()
      change_draft(view, "from_stop_id", :stops, %{"from_stop_id" => "MKT"})

      view |> element("#transfer-pick-from") |> render_click()
      assert_push_event(view, "transfer_map:pick_start", %{pick_id: 1})

      # An entrance, an unknown id, another version's stop and another session's id
      # are all refused; the draft keeps the stop it had (R2, R10).
      render_hook(view, "transfer_map_pick", %{"pick_id" => 1, "stop_id" => "CEN-E"})
      render_hook(view, "transfer_map_pick", %{"pick_id" => 1, "stop_id" => "NOWHERE"})
      render_hook(view, "transfer_map_pick", %{"pick_id" => 1, "stop_id" => "OTHER"})
      render_hook(view, "transfer_map_pick", %{"pick_id" => 2, "stop_id" => "CEN"})

      assert has_element?(view, "#transfer_from_stop_id[value='MKT']")
      refute has_element?(view, "#transfer_from_stop_id[value='CEN']")
      assert text_of(doc(view), "#transfer-from-stop-hint") == "Stop in this version."
      assert has_element?(view, "#transfer-pick-callout")
    end

    test "cancel and Escape end the pick, and a finished session cannot pick", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()
      view |> element("#transfer-pick-from") |> render_click()
      assert_push_event(view, "transfer_map:pick_start", %{pick_id: 1})

      view |> element("#transfer-pick-cancel") |> render_click()

      assert_push_event(view, "transfer_map:pick_end", %{pick_id: 1})
      refute has_element?(view, "#transfer-pick-callout")
      assert text_of(doc(view), "#transfer-map-title") == "Preview this connection"

      # The ended session's id is not the current one any more.
      render_hook(view, "transfer_map_pick", %{"pick_id" => 1, "stop_id" => "CEN"})
      refute has_element?(view, "#transfer_from_stop_id[value='CEN']")

      # A pick with no session at all is refused the same way.
      render_hook(view, "transfer_map_pick", %{"pick_id" => 2, "stop_id" => "CEN"})
      refute has_element?(view, "#transfer_from_stop_id[value='CEN']")

      view |> element("#transfer-pick-to") |> render_click()
      assert_push_event(view, "transfer_map:pick_start", %{pick_id: 2, side: "b"})
      assert text_of(doc(view), "#transfer-map-title") == "Choose the departure stop"

      view |> element("#transfer-pick-cancel") |> render_keydown(%{"key" => "Escape"})

      assert_push_event(view, "transfer_map:pick_end", %{pick_id: 2})
      refute has_element?(view, "#transfer-pick-callout")
    end

    test "closing the editor ends its pick session and shows the selected connection", ctx do
      scoped(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        transfer_type: 2,
        min_transfer_time: 180
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()
      view |> element("#transfer-pick-from") |> render_click()
      assert_push_event(view, "transfer_map:pick_start", %{pick_id: 1})

      view |> element("#transfer-back") |> render_click()

      assert_push_event(view, "transfer_map:pick_end", %{pick_id: 1})
      assert_push_event(view, "transfer_map:show", %{a: %{stop_id: "CEN-A"}})
      refute has_element?(view, "#transfer-editor")
      assert text_of(doc(view), "#transfer-map-title") == "Selected connection"
    end

    test "a draft still saves while the map is unavailable", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()

      render_hook(view, "transfer_map_state", %{
        "generation" => generation(doc(view)),
        "state" => "imagery_unavailable"
      })

      assert has_element?(view, "#transfer-map-unavailable")

      change_draft(view, "from_stop_id", :stops, %{"from_stop_id" => "CEN-A"})
      change_draft(view, "to_stop_id", :stops, %{"to_stop_id" => "CEN-C"})

      save_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "min_transfer_time" => "180"
      })

      assert [rule] = Repo.all_by(Transfer, gtfs_version_id: ctx.version.id)
      assert rule.from_stop_id == "CEN-A"
      assert rule.min_transfer_time == 180
      refute has_element?(view, "#transfer-editor")
    end
  end

  defp insert_extra_stops(ctx, count) do
    Enum.each(1..count, fn index ->
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "EXTRA_#{index}",
        stop_name: "Extra stop #{String.pad_leading(to_string(index), 3, "0")}",
        stop_lat: "10.2000",
        stop_lon: "10.2000"
      })
    end)
  end

  defp change_draft(view, target, scope, values) do
    render_change(
      element(view, "#transfer-form"),
      %{"_target" => target, "scope" => to_string(scope), "transfer" => draft(values)}
    )
  end

  defp save_draft(view, scope, values) do
    render_submit(
      element(view, "#transfer-form"),
      %{"scope" => to_string(scope), "transfer" => draft(values)}
    )
  end

  defp draft(values), do: Map.merge(@blank_draft, values)

  defp transfers_path(version, params \\ []) do
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    "/gtfs/#{version.id}/transfers#{query}"
  end

  defp scoped(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp generation(document), do: attribute(document, "#transfer-map", "data-map-generation")

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp attribute(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end
end
