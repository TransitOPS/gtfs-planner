defmodule GtfsPlannerWeb.Gtfs.StopsMapCreatedTest do
  @moduledoc """
  Merge evidence (EV-29) for the panel after a stop is created: which patterns
  pass the new stop, the two stops it would fall between, the link into the
  pattern editor, and the way back to an empty draft.

  The fixture is one route running north up the line of longitude `-124.05310`
  with two patterns on it — `NB` toward Newport and `SB` toward Yaquina — and two
  existing stops on the line, `Bay Street` to the south and `Depot Road` to the
  north. A stop created eight metres east of that line, halfway between them, is
  on the kerb a northbound vehicle stops at and on the far pavement of the
  southbound one, so exactly one of the two patterns may be offered.

  The expectations are literals from the card's cases and from the fixture
  rows: the pattern named is the fixture's own `NB`, the neighbours are the two
  stop names written in, and the link's `add_stop` is the ID read back out of the
  row the create command wrote.

  The focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_sa28 ELIXIR_ERL_OPTIONS="+S 4" mix test test/gtfs_planner_web/live/gtfs/stops_map_created_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Mox, only: [set_mox_global: 1, verify_on_exit!: 1]
  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Geocoding.Place
  alias GtfsPlanner.GeocodingMock
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @line_lon -124.05310
  @metres_per_degree_lon 79_226.0

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    organization = organization_fixture()
    editor = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: editor.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    Mox.stub(GeocodingMock, :autocomplete, fn _text, _opts -> {:ok, []} end)

    Mox.stub(GeocodingMock, :reverse, fn lat, lon, _opts ->
      {:ok,
       [
         %Place{
           name: "US 101",
           street: "US 101",
           city: "Newport",
           state: "OR",
           country: "us",
           lat: lat,
           lon: lon,
           distance_m: 3.0
         }
       ]}
    end)

    %{
      organization: organization,
      version: version,
      editor_conn: log_in_user(build_conn(), editor, organization: organization)
    }
  end

  describe "the patterns a new stop could be added to" do
    test "the northbound pattern is listed with the stops either side, and the southbound one is not",
         ctx do
      existing_stops(ctx, two_directions(ctx))

      view = ctx |> open_map_version() |> create_stop_east_of_line()

      created = Repo.all(from stop in Stop, where: stop.stop_name == "US 101")
      assert [%Stop{stop_id: created_id}] = created

      # The route badge names the route, the headsign names the direction, and
      # the two stops either side of the new one are named because "add it here"
      # is only meaningful against a sequence.
      assert has_element?(view, "#stops-map-created-pattern-NB", "toward Newport")

      assert has_element?(
               view,
               "#stops-map-created-pattern-NB",
               "Between Bay Street and Depot Road"
             )

      # The far pavement of the southbound pattern is not a place its vehicles
      # stop, so it is not offered as somewhere to add the stop.
      refute has_element?(view, "#stops-map-created-pattern-SB")

      # The link carries the stop, and lands on the pattern's stop list rather
      # than its details: that is the task step 37 opens.
      assert has_element?(
               view,
               "#stops-map-created-pattern-NB a[href$='?task=stops&add_stop=#{created_id}']",
               "Add to pattern"
             )

      # The stop's own page is the other way out of this panel, and it is a link
      # rather than a button: it leaves the Map view for a page that already
      # exists.
      assert has_element?(
               view,
               "#stops-map-created-panel a[href$='/stops/#{created_id}']",
               "Open stop"
             )
    end

    test "a stop with no pattern at its kerb says so rather than listing nothing", ctx do
      view = ctx |> open_map_version() |> place_draft()

      # Far from every line: the map has one line, and this is a hundred metres
      # off it, on a street of its own.
      render_hook(view, "place", %{"lat" => 44.6400, "lon" => -124.0400})
      render_async(view, 2_000)

      view |> form("#stops-map-add-form") |> render_submit()
      render_async(view, 2_000)

      assert has_element?(view, "#stops-map-created-panel")
      assert has_element?(view, "#stops-map-created-patterns", "No pattern passes here yet")
    end

    test "Add another stop returns to an empty add panel", ctx do
      existing_stops(ctx, two_directions(ctx))

      view = ctx |> open_map_version() |> create_stop_east_of_line()

      assert has_element?(view, "#stops-map-created-another")

      view |> element("#stops-map-created-another") |> render_click()

      assert has_element?(view, "#stops-map-add-form")
      # A draft, not a copy: the name the created stop had is not still in the
      # field, or the next stop would be created with the last one's name.
      assert has_element?(view, "#stops-map-add-name[value='']")
      refute has_element?(view, "#stops-map-add-create[disabled]")
    end
  end

  # One route, two directions on the same road: the geometry a stop is judged
  # against is the same line either way, and only the direction of travel
  # differs, which is exactly what decides which kerb is served. A shape is
  # owned by one pattern, so the two directions carry the same coordinates under
  # their own shape ids — and the southbound one is written in the order a bus
  # running south meets them, because the side of a line is read from the way it
  # runs, not from the pattern's `direction_id`.
  defp two_directions(ctx) do
    route = route_fixture(ctx.organization.id, ctx.version.id, %{route_short_name: "1"})

    insert_shape(ctx, "SHAPE_NB", [{44.6340, @line_lon}, {44.6400, @line_lon}])
    insert_shape(ctx, "SHAPE_SB", [{44.6400, @line_lon}, {44.6340, @line_lon}])

    northbound = insert_pattern(ctx, route, "NB", 0, "Newport", "SHAPE_NB")
    southbound = insert_pattern(ctx, route, "SB", 1, "Yaquina", "SHAPE_SB")

    [northbound, southbound]
  end

  defp insert_pattern(ctx, route, route_pattern_id, direction_id, headsign, shape_id) do
    %RoutePattern{
      route_pattern_id: route_pattern_id,
      route_id: route.route_id,
      direction_id: direction_id,
      headsign: headsign,
      shape_id: shape_id,
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id
    }
    |> Repo.insert!()
  end

  defp insert_shape(ctx, shape_id, points) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Shape,
      points
      |> Enum.with_index(1)
      |> Enum.map(fn {{lat, lon}, sequence} ->
        %{
          shape_id: shape_id,
          shape_pt_lat: Decimal.from_float(lat),
          shape_pt_lon: Decimal.from_float(lon),
          shape_pt_sequence: sequence,
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.version.id,
          inserted_at: now,
          updated_at: now
        }
      end)
    )
  end

  # The two stops the new one lands between: a hundred metres south and a
  # hundred and forty north of the point, both on the line itself.
  defp existing_stops(ctx, patterns) do
    bay = insert_stop(ctx, "1000", "Bay Street", 44.6350)
    depot = insert_stop(ctx, "1001", "Depot Road", 44.6390)

    Enum.each(patterns, fn pattern ->
      route_pattern_stop_fixture(pattern, "1000", 1)
      route_pattern_stop_fixture(pattern, "1001", 2)
    end)

    [bay, depot]
  end

  defp insert_stop(ctx, stop_id, name, lat) do
    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: stop_id,
      stop_name: name,
      stop_lat: Decimal.from_float(lat),
      stop_lon: Decimal.from_float(@line_lon)
    })
  end

  defp east_of_line(metres), do: @line_lon + metres / @metres_per_degree_lon

  defp open_map_version(ctx) do
    {:ok, view, _html} = live(ctx.editor_conn, ~p"/gtfs/#{ctx.version.id}/stops/map")
    render_async(view, 2_000)
    render_async(view, 2_000)
    view
  end

  defp place_draft(view) do
    view |> element("#stops-map-add-stop") |> render_click()
    view
  end

  # Place eight metres east of the line at 44.6370 — between `Bay Street` at
  # 44.6350 and `Depot Road` at 44.6390 — and create it.
  defp create_stop_east_of_line(view) do
    view = place_draft(view)

    render_hook(view, "place", %{"lat" => 44.6370, "lon" => east_of_line(8.0)})
    render_async(view, 2_000)

    view |> form("#stops-map-add-form") |> render_submit()
    render_async(view, 2_000)

    view
  end
end
