defmodule GtfsPlannerWeb.Gtfs.FaresLiveMapTest do
  @moduledoc """
  Merge evidence (EV-21) for the server side of the Zones tab's map.

  Every case mounts the real route and reads the version's real data through the
  default `CatalogReadAdapter.Repo` adapter, and drives the map through the
  protocol the `FareZoneMap` hook uses: the `fare_zone_map_ready` handshake, the
  `select_stops` and `toggle_stop` events, `map_unavailable`, `retry_map` and
  `use_stop_list`. Nothing here fakes the map: the hook itself runs in the
  browser (EV-27), and this gate is what the hook's reply and every pushed delta
  contain.

  The fixture carries what AC-7, AC-28 and AC-29 name: located boardable stops in
  two declared zones, an unlocated boardable stop and a station (both excluded
  from the points), an unassigned located stop, an implicit zone whose ID is the
  padded `" A"` (so the byte-exact ID travels into the reply, the filter and the
  legend without being trimmed), a zone a fare rule references that has no stops,
  and an empty declared zone. Twin scope is present too: the same organization's
  other version and another organization carry their own `"A"` zone and located
  stops, so a reply or a selection that is not scoped to one organization and one
  version is visible.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @tile_failure "Map tiles are unavailable"

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    insert_zone(organization, version, "A", "Central", "ocean")
    insert_zone(organization, version, "B", "Eastbank", "teal")
    insert_zone(organization, version, "D", "Airport", "ochre")

    stops =
      insert_stops(organization, version, [
        located("CENTRAL_1", "Central 1", "A", 42.300, -71.108),
        located("CENTRAL_2", "Central 2", "A", 42.302, -71.107),
        located("EAST_1", "East 1", "B", 42.300, -71.019),
        located("BAY_1", "Bayline 1", nil, 42.330, -71.005),
        # An imported ID with a leading space, kept byte-for-byte and carried by
        # this stop alone, so it is an implicit zone of its own.
        located("SPACE_1", "Riverside", " A", 42.305, -71.100),
        # A boardable stop with no coordinates: AC-7 keeps it out of the points.
        %{stop_id: "DEPOT_1", stop_name: "Central Depot", zone_id: "A"},
        # A station of zone A with coordinates: not boardable, so no marker.
        located("CENTRAL_STATION", "Central Union", "A", 42.400, -71.030)
        |> Map.put(:location_type, 1)
      ])

    # "Q" is referenced by a rule and carried by no stop, so the inventory has a
    # zone the map cannot draw, and "A" is referenced, so its deletion needs a
    # replacement rather than an unassign.
    insert_rule(organization, version, "CITY", "A", "B")
    insert_rule(organization, version, "CITY", "Q", "A")

    # Twin scope: the same organization's other version and another organization.
    other_version = gtfs_version_fixture(organization.id)
    insert_zone(organization, other_version, "A", "Central", "ocean")

    other_stops =
      insert_stops(organization, other_version, [
        located("OTHER_VERSION_1", "Other version", "A", 42.310, -71.100)
      ])

    other_organization = organization_fixture()
    other_org_version = gtfs_version_fixture(other_organization.id)
    insert_zone(other_organization, other_org_version, "A", "Central", "ocean")

    foreign_stops =
      insert_stops(other_organization, other_org_version, [
        located("FOREIGN_1", "Foreign", "A", 42.320, -71.090)
      ])

    # A version with no zone at all: AC-22's first-use state, which replaces the
    # whole workspace, map included.
    empty_version = gtfs_version_fixture(organization.id)
    insert_stops(organization, empty_version, [located("EMPTY_1", "Empty", nil, 42.300, -71.100)])

    # A version whose only zone has no stops: the map still renders, with nothing
    # to draw.
    zones_only_version = gtfs_version_fixture(organization.id)
    insert_zone(organization, zones_only_version, "Z", "Zed", "plum")

    %{
      user: user,
      organization: organization,
      version: version,
      other_version: other_version,
      other_org_version: other_org_version,
      empty_version: empty_version,
      zones_only_version: zones_only_version,
      stops: Map.new(stops, &{&1.stop_id, &1.id}),
      other_stop: hd(other_stops).id,
      foreign_stop: hd(foreign_stops).id
    }
  end

  describe "the ready reply" do
    test "carries this version's located boardable points, zone colors, selection and filter",
         ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zones_path(ctx.version))

      # Map + list is the default view, so the hook's root is here before any
      # hook runs, with the canvas element and both control groups.
      assert has_element?(view, "#fare-zone-map")
      assert attribute(view, "#fare-zone-map", "phx-hook") == "FareZoneMap"
      assert attribute(view, "#fare-zone-map", "phx-update") == "ignore"
      assert has_element?(view, "#fare-zone-map [data-map-canvas]")
      assert has_element?(view, "#fare-zone-map [data-map-mode='select']", "Select stops")
      assert has_element?(view, "#fare-zone-map [data-map-mode='pan']", "Pan map")
      assert has_element?(view, "#fare-zone-map [data-map-zoom='in']")
      assert has_element?(view, "#fare-zone-map [data-map-zoom='out']")
      assert has_element?(view, "#fare-zone-map [data-map-fit][aria-label='Fit all stops']")
      assert has_element?(view, "#fare-zone-map [data-map-hint]")

      toggle_stop(view, ctx.stops["CENTRAL_1"])
      reply = ready_reply(view)

      assert reply.filter == %{kind: "all", zone_id: nil}
      assert reply.selected == [ctx.stops["CENTRAL_1"]]

      points = Map.new(reply.points, &{Enum.at(&1, 1), &1})

      # Only located boardable stops of this version: the depot has no
      # coordinates, the station is not boardable, and the twin scope's stops
      # belong to another version and another organization.
      assert Enum.sort(Map.keys(points)) == [
               "BAY_1",
               "CENTRAL_1",
               "CENTRAL_2",
               "EAST_1",
               "SPACE_1"
             ]

      assert [id, "CENTRAL_1", "Central 1", lat, lon, "A", nil] = points["CENTRAL_1"]
      assert id == ctx.stops["CENTRAL_1"]
      assert_in_delta lat, 42.300, 0.0001
      assert_in_delta lon, -71.108, 0.0001
      assert Enum.at(points["BAY_1"], 5) == nil
      # The padded imported ID travels as its exact bytes (INV-3).
      assert Enum.at(points["SPACE_1"], 5) == " A"

      # The colors are the palette hex values the panel and the list use, for the
      # declared zones, the stopless rule reference and the padded implicit zone.
      assert reply.zones["A"] == %{name: "Central", color: "#1f5fbf"}
      assert reply.zones["B"] == %{name: "Eastbank", color: "#0d737d"}
      assert reply.zones["D"] == %{name: "Airport", color: "#8a5a0e"}

      assert reply.zones["Q"] == %{
               name: "Q",
               color: FareZone.color_hex(FareZone.default_color("Q"))
             }

      assert reply.zones[" A"] == %{
               name: " A",
               color: FareZone.color_hex(FareZone.default_color(" A"))
             }
    end

    test "is the filter the URL names, byte-for-byte", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)

      {:ok, view, _html} = live(conn, zone_url(ctx.version, "A"))
      assert ready_reply(view).filter == %{kind: "zone", zone_id: "A"}

      {:ok, padded_view, _html} = live(conn, zone_url(ctx.version, " A"))
      assert ready_reply(padded_view).filter == %{kind: "zone", zone_id: " A"}

      {:ok, unassigned_view, _html} = live(conn, zones_path(ctx.version) <> "?filter=unassigned")
      assert ready_reply(unassigned_view).filter == %{kind: "unassigned", zone_id: nil}
    end
  end

  describe "a dragged box" do
    test "adds only the IDs this version's boardable stops carry, and pushes them", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zones_path(ctx.version))
      ready_reply(view)

      render_hook(view, "select_stops", %{
        "ids" => [
          ctx.stops["CENTRAL_1"],
          ctx.stops["EAST_1"],
          # Valid UUIDs, but of another version and another organization.
          ctx.other_stop,
          ctx.foreign_stop,
          ctx.stops["CENTRAL_STATION"]
        ]
      })

      assert_push_event(view, "fare_zone_selection", %{added: added, removed: []})

      assert Enum.sort(added) ==
               Enum.sort([ctx.stops["CENTRAL_1"], ctx.stops["EAST_1"]])

      # The selection is the server's, and the next mount is told all of it.
      assert ready_reply(view).selected ==
               Enum.sort([ctx.stops["CENTRAL_1"], ctx.stops["EAST_1"]])
    end

    test "drops a malformed value and a payload that is not a list of IDs", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zones_path(ctx.version))
      ready_reply(view)

      central_2 = ctx.stops["CENTRAL_2"]

      render_hook(view, "select_stops", %{"ids" => ["not-a-uuid", central_2]})

      assert_push_event(view, "fare_zone_selection", %{added: [^central_2], removed: []})

      render_click(view, "select_stops", %{"ids" => "not-a-list"})

      assert ready_reply(view).selected == [central_2]
    end
  end

  describe "deltas" do
    test "a save pushes the stops it moved, and Undo pushes them back", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zones_path(ctx.version))
      ready_reply(view)

      central_1 = ctx.stops["CENTRAL_1"]

      toggle_stop(view, central_1)
      render_click(view, "open_assignment", %{"mode" => "assign"})
      choose_target(view, "B")
      confirm_save(view)

      assert_push_event(view, "fare_zone_points_changed", %{changes: [[^central_1, "B"]]})

      # The save cleared the selection, so the map's rings go with it.
      assert_push_event(view, "fare_zone_selection", %{added: [], removed: [^central_1]})

      view |> element("#fare-zone-undo") |> render_click()

      assert_push_event(view, "fare_zone_points_changed", %{changes: [[^central_1, "A"]]})
    end

    test "a metadata edit pushes the zone colors, and a rename pushes a whole snapshot", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zone_url(ctx.version, "A"))
      ready_reply(view)

      # A color-only edit keeps the ID, so the map keeps its points, selection and
      # filter and only the zone's color changes.
      view |> element("#fare-zone-edit") |> render_click()
      submit_zone(view, %{"zone_id" => "A", "name" => "Central", "color" => "plum"})

      assert_push_event(view, "fare_zone_zones", %{zones: zones})
      assert zones["A"] == %{name: "Central", color: "#4b1f78"}
      refute drawer_open?(view)

      # A rename moves the stored ID every member's point carries, so the whole
      # snapshot - not one color - is what the map needs.
      view |> element("#fare-zone-edit") |> render_click()
      submit_zone(view, %{"zone_id" => "AA", "name" => "Central", "color" => "plum"})

      assert_patch(view, zone_url(ctx.version, "AA"))
      render_patch(view, zone_url(ctx.version, "AA"))

      assert_push_event(view, "fare_zone_snapshot", %{points: points, zones: renamed})

      refute Map.has_key?(renamed, "A")
      assert renamed["AA"] == %{name: "Central", color: "#4b1f78"}

      point_zones = points |> Enum.map(&Enum.at(&1, 5)) |> Enum.uniq() |> Enum.sort()
      # The renamed zone's points moved with it, and the padded zone kept its own
      # bytes through the rename of a neighbour.
      assert point_zones == [nil, " A", "AA", "B"]
    end

    test "a metadata edit is not pushed to a map that is not mounted", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zone_url(ctx.version, "A"))

      view |> element("#fare-zone-edit") |> render_click()
      submit_zone(view, %{"zone_id" => "A", "name" => "Central", "color" => "plum"})

      refute_push_event(view, "fare_zone_zones", %{})
    end
  end

  describe "the fallback" do
    test "map_unavailable replaces the frame, and Retry rehydrates the selection made in between",
         ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zones_path(ctx.version))
      ready_reply(view)

      render_hook(view, "map_unavailable", %{"reason" => @tile_failure})

      refute has_element?(view, "#fare-zone-map")
      # The legend stays with the fallback, as the reference keeps it: the colors
      # it names are the ones the complete list below shows.
      assert has_element?(view, "#fare-zone-map-legend", "Central")
      assert has_element?(view, "#fare-zone-map-unavailable", "The map is unavailable")
      assert has_element?(view, "#fare-zone-map-retry", "Retry map")
      assert has_element?(view, "#fare-zone-map-use-list", "Use stop list")

      # The list stays the complete alternative: it still selects, and the
      # selection is not pushed at a hook that is not in the page (CR-8).
      assert has_element?(
               view,
               "#fare-zone-map-unavailable",
               "You can still find and assign every stop in the list."
             )

      toggle_stop(view, ctx.stops["EAST_1"])
      refute_push_event(view, "fare_zone_selection", %{})

      view |> element("#fare-zone-map-retry") |> render_click()

      assert has_element?(view, "#fare-zone-map")
      assert has_element?(view, "#fare-zone-map-legend")
      assert ready_reply(view).selected == [ctx.stops["EAST_1"]]
    end

    test "Use stop list removes the map, and the stage header's switch renders it again", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zones_path(ctx.version))
      ready_reply(view)
      assert has_element?(view, "#fare-zone-map")

      # The rows are a stream and are not re-rendered by a change of view, so the
      # list carries the view as an attribute and the row's view-dependent parts
      # follow it in CSS.
      assert has_element?(view, "#fare-zone-stop-list[data-view='map']")

      view |> form("#fare-zone-view-form", %{"view" => "list"}) |> render_change()

      refute has_element?(view, "#fare-zone-map")
      refute has_element?(view, "#fare-zone-map-legend")
      assert has_element?(view, "#fare-zone-stop-list[data-view='list']")

      view |> form("#fare-zone-view-form", %{"view" => "map"}) |> render_change()

      assert has_element?(view, "#fare-zone-stop-list[data-view='map']")
      assert has_element?(view, "#fare-zone-map")
      assert has_element?(view, "#fare-zone-map-legend")
      assert ready_reply(view).points != []

      render_hook(view, "map_unavailable", %{"reason" => @tile_failure})
      view |> element("#fare-zone-map-use-list") |> render_click()

      refute has_element?(view, "#fare-zone-map")
      refute has_element?(view, "#fare-zone-map-unavailable")
      assert has_element?(view, "#fare-zone-stop-list")
    end
  end

  describe "a delete" do
    test "pushes a snapshot that no longer draws the deleted zone", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zone_url(ctx.version, "A"))
      ready_reply(view)

      view |> element("#fare-zone-edit") |> render_click()
      view |> element("#fare-zone-delete") |> render_click()
      choose_replacement(view, "B")
      view |> element("#fare-zone-delete-dialog-confirm") |> render_click()

      assert_patch(view, zones_path(ctx.version))
      render_patch(view, zones_path(ctx.version))

      assert_push_event(view, "fare_zone_snapshot", %{points: points, zones: zones})

      # The deleted zone's metadata and every point that carried its ID are gone
      # from what the mounted map now draws.
      refute Map.has_key?(zones, "A")
      assert zones["B"] == %{name: "Eastbank", color: "#0d737d"}

      by_stop_id = Map.new(points, &{Enum.at(&1, 1), &1})

      assert Enum.at(by_stop_id["CENTRAL_1"], 5) == "B"
      assert Enum.at(by_stop_id["CENTRAL_2"], 5) == "B"
      # A neighbour that kept its own zone ID, padded bytes included, is untouched.
      assert Enum.at(by_stop_id["SPACE_1"], 5) == " A"
      assert Enum.at(by_stop_id["BAY_1"], 5) == nil

      refute Map.has_key?(by_stop_id, "DEPOT_1")

      # What the workspace beside the map now shows.
      assert has_element?(view, "#fare-zone-stage-title", "All stops")
      refute has_element?(view, "#fare-zone-map-legend", "Central")
    end
  end

  describe "nothing to draw" do
    test "an empty inventory replaces the whole workspace and mounts no map", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zones_path(ctx.empty_version))

      assert has_element?(view, "#fare-zone-first-use", "Start with your first fare zone")
      refute has_element?(view, "#fare-zone-map")
      refute has_element?(view, "#fare-zone-map-unavailable")
      refute has_element?(view, "#fare-zone-map-legend")
    end

    test "an inventory whose zones have no stops still renders, with nothing to draw", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zones_path(ctx.zones_only_version))

      assert has_element?(view, "#fare-zone-map")
      assert ready_reply(view).points == []

      # The legend names what a marker could carry, and the one zone this version
      # has carries no stop, so only Unassigned is left to explain.
      assert has_element?(view, "#fare-zone-map-legend", "No zone")
      refute has_element?(view, "#fare-zone-map-legend", "Zed")
      assert has_element?(view, "#fare-zone-stops-empty", "No stops yet")
    end

    test "the legend names the zones a marker carries and not the empty ones", ctx do
      conn = log_in_user(ctx.conn, ctx.user, organization: ctx.organization)
      {:ok, view, _html} = live(conn, zones_path(ctx.version))

      assert has_element?(view, "#fare-zone-map-legend", "Central")
      assert has_element?(view, "#fare-zone-map-legend", "Eastbank")
      assert has_element?(view, "#fare-zone-map-legend", "No zone")
      # The empty declared zone and the stopless zone a rule references have no
      # marker, so no legend entry.
      refute has_element?(view, "#fare-zone-map-legend", "Airport")
      refute has_element?(view, "#fare-zone-map-legend", "Q")
      # No DOM ID on the page derives from a zone ID, padded zone included (CR-7).
      refute Enum.any?(rendered_ids(view), &String.contains?(&1, " A"))
    end
  end

  defp zones_path(version), do: "/gtfs/#{version.id}/settings/fares"

  defp zone_url(version, zone_id) do
    zones_path(version) <> "?" <> URI.encode_query(zone: zone_id)
  end

  # The handshake the hook sends on mount: its reply is the whole state the map
  # draws from, so every case reads it rather than the render.
  defp ready_reply(view) do
    render_hook(view, "fare_zone_map_ready", %{})
    assert_reply(view, reply)
    reply
  end

  defp toggle_stop(view, stop_id) do
    view
    |> element("#stops-#{stop_id} input[type='checkbox']")
    |> render_click()
  end

  defp choose_target(view, zone_id) do
    view |> form("#fare-zone-assignment-target-form", %{"target" => zone_id}) |> render_change()
  end

  defp confirm_save(view) do
    view |> element("#fare-zone-assignment-dialog-confirm") |> render_click()
  end

  defp choose_replacement(view, zone_id) do
    view
    |> form("#fare-zone-delete-replacement-form", %{"replacement" => zone_id})
    |> render_change()
  end

  defp submit_zone(view, params) do
    view |> form("#fare-zone-form", %{"zone" => params}) |> render_submit()
  end

  defp drawer_open?(view), do: attribute(view, "#fare-zone-drawer-overlay", "data-open") == "true"

  defp rendered_ids(view) do
    ~r/(?:^|\s)id="([^"]*)"/
    |> Regex.scan(render(view), capture: :all_but_first)
    |> List.flatten()
  end

  defp attribute(view, selector, name) do
    view |> nodes(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp nodes(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  defp insert_stops(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn stop ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop.stop_id,
          stop_name: stop.stop_name,
          location_type: Map.get(stop, :location_type, 0),
          zone_id: Map.get(stop, :zone_id),
          stop_lat: coordinate(Map.get(stop, :lat)),
          stop_lon: coordinate(Map.get(stop, :lon)),
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Stop, rows)
    assert count == length(rows)
    rows
  end

  defp located(stop_id, stop_name, zone_id, lat, lon),
    do: %{stop_id: stop_id, stop_name: stop_name, zone_id: zone_id, lat: lat, lon: lon}

  defp coordinate(nil), do: nil
  defp coordinate(value), do: Decimal.new(:erlang.float_to_binary(value, decimals: 3))

  defp insert_zone(organization, version, zone_id, name, color) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareZone, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          zone_id: zone_id,
          name: name,
          color: color,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp insert_rule(organization, version, fare_id, origin_id, destination_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareRule, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: fare_id,
          origin_id: origin_id,
          destination_id: destination_id,
          inserted_at: now,
          updated_at: now
        }
      ])
  end
end
