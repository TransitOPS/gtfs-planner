defmodule GtfsPlannerWeb.Gtfs.RoutePatternMapLineDownloadTest do
  @moduledoc """
  Step 35 / EV-34: the two map-line download menus (CL-27, FH-27).

  The Map line tab's "Import or export" menu and the Patterns list's "Download map
  lines" menu are read here through the production pages an editor sees, and
  every href is checked against the route step 34 serves, so a menu that names
  the wrong pattern, the wrong format or another route's file is caught here
  rather than in the browser. Expected values are literals from the GTFS
  reference and the prototype's menu copy, never computed by the code under test.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo

  # Five stops on a rising line, so a pattern has four sections and a gap in the
  # middle leaves exactly two saved runs.
  @stops [
    {"S1", "40.0", "-74.0"},
    {"S2", "40.1", "-74.1"},
    {"S3", "40.2", "-74.2"},
    {"S4", "40.3", "-74.3"},
    {"S5", "40.4", "-74.4"}
  ]

  setup :editor_scope

  describe "the Map line tab's Import or export menu" do
    test "the KML and GeoJSON links name this pattern and this version", ctx do
      {route, pattern} = corridor_pattern(ctx)
      save_section(ctx, "S1", "S2", [[-74.05, 40.05]])
      save_section(ctx, "S2", "S3", [[-74.15, 40.15]])
      save_section(ctx, "S3", "S4", [[-74.25, 40.25]])
      save_section(ctx, "S4", "S5", [[-74.35, 40.35]])

      view = open_alignment(ctx, route, pattern)

      assert has_element?(view, "#map-line-files")
      assert has_element?(view, "#map-line-files-toggle", "Import or export")

      href = href(view, "#map-line-download-kml")
      assert href == "/gtfs/#{ctx.version.id}/routes/COAST/map-lines?format=kml&pattern=COAST-A"

      href = href(view, "#map-line-download-geojson")

      assert href ==
               "/gtfs/#{ctx.version.id}/routes/COAST/map-lines?format=geojson&pattern=COAST-A"

      # A fully saved pattern promises one line and its stops.
      assert has_element?(
               view,
               "#map-line-download-note",
               "The file has the saved map line and the 5 stops."
             )
    end

    test "a pattern with a gap says the file has the line in pieces", ctx do
      {route, pattern} = corridor_pattern(ctx)

      # The middle two sections have no saved path, so the saved sections are
      # two separate runs: Stop S1 to Stop S2, and Stop S4 to Stop S5.
      save_section(ctx, "S1", "S2", [[-74.05, 40.05]])
      save_section(ctx, "S4", "S5", [[-74.35, 40.35]])

      view = open_alignment(ctx, route, pattern)

      assert has_element?(view, "#map-line-download-note", "2 sections have no saved path")
      assert has_element?(view, "#map-line-download-note", "the line in 2 pieces")
      assert has_element?(view, "#map-line-download-note", "Stop S1 to Stop S2")
      assert has_element?(view, "#map-line-download-note", "Stop S4 to Stop S5")

      # The note must never promise fewer pieces than the file draws (FH-27).
      body = render(view)
      assert body =~ "the line in 2 pieces"
    end

    test "an imported-only pattern's note names the imported shape", ctx do
      {route, pattern} = corridor_pattern(ctx)
      import_shape(ctx, pattern, "SHAPE-1045", [{"40.0", "-74.0"}, {"40.4", "-74.4"}])

      view = open_alignment(ctx, route, pattern)

      assert has_element?(
               view,
               "#map-line-download-note",
               "The file has the imported line (shape SHAPE-1045) and the 5 stops."
             )
    end
  end

  describe "the Patterns list's Download map lines menu" do
    test "offers KML and GeoJSON for the whole route", ctx do
      {route, pattern} = corridor_pattern(ctx)
      save_section(ctx, "S1", "S2", [[-74.05, 40.05]])
      save_section(ctx, "S2", "S3", [[-74.15, 40.15]])
      save_section(ctx, "S3", "S4", [[-74.25, 40.25]])
      save_section(ctx, "S4", "S5", [[-74.35, 40.35]])

      {:ok, view, _html} =
        live(ctx.conn, "/gtfs/#{ctx.version.id}/routes/#{route.route_id}/patterns")

      assert has_element?(view, "#patterns-download-map-lines-toggle", "Download map lines")

      assert href(view, "#patterns-download-map-lines-kml") ==
               "/gtfs/#{ctx.version.id}/routes/COAST/map-lines?format=kml&pattern=all"

      route_href = href(view, "#patterns-download-map-lines-geojson")

      assert route_href ==
               "/gtfs/#{ctx.version.id}/routes/COAST/map-lines?format=geojson&pattern=all"

      # Every download is a real file response for this organization's version,
      # and the route-wide one carries both the line and the stops (FH-27).
      conn = get(ctx.conn, route_href)
      assert conn.status == 200
      assert {:ok, document} = Jason.decode(conn.resp_body)
      assert document["type"] == "FeatureCollection"

      assert Enum.map(document["features"], & &1["geometry"]["type"]) == [
               "LineString",
               "Point",
               "Point",
               "Point",
               "Point",
               "Point"
             ]

      # The same link in another organization's session is a 404, not a file.
      foreign = build_conn() |> log_in_user(ctx.other_user, organization: ctx.other_organization)

      foreign_response =
        get(foreign, "/gtfs/#{ctx.version.id}/routes/COAST/map-lines?format=kml&pattern=all")

      assert foreign_response.status == 404
      assert foreign_response.resp_body == "Not Found"

      assert pattern.route_pattern_id == "COAST-A"
    end
  end

  defp editor_scope(%{conn: conn}) do
    user = user_fixture()
    organization = organization_fixture(%{alias: "map-line-menu-#{Ecto.UUID.generate()}"})
    version = gtfs_version_fixture(organization.id)

    {:ok, _membership} =
      Organizations.add_user_to_organization(user.id, organization.id, ["pathways_studio_editor"])

    other_user = user_fixture()
    other_organization = organization_fixture(%{alias: "map-line-other-#{Ecto.UUID.generate()}"})

    {:ok, _other_membership} =
      Organizations.add_user_to_organization(other_user.id, other_organization.id, [
        "pathways_studio_editor"
      ])

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      version: version,
      other_user: other_user,
      other_organization: other_organization
    }
  end

  defp corridor_pattern(%{organization: organization, version: version}) do
    Enum.each(@stops, fn {id, lat, lon} ->
      stop_fixture(organization.id, version.id, %{
        stop_id: id,
        stop_name: "Stop #{id}",
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new(lon)
      })
    end)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "COAST",
        route_short_name: "1",
        route_long_name: "Coast Highway"
      })

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "COAST-A",
        route_pattern_name: "Toward Lincoln City",
        direction_id: 0
      })

    Enum.with_index(@stops, 1)
    |> Enum.each(fn {{id, _lat, _lon}, position} ->
      route_pattern_stop_fixture(pattern, id, position)
    end)

    {route, pattern}
  end

  # A saved path for one stop pair, which this pattern's sections resolve
  # against; a pair with no row is the gap the note counts.
  defp save_section(ctx, from_stop_id, to_stop_id, points) do
    %AlignmentSegment{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  # One imported shape on a trip linked to this pattern, which is what the feed
  # export uses while the pattern has no saved path of its own.
  defp import_shape(ctx, pattern, shape_id, points) do
    timing = timed_pattern_fixture(pattern)

    trip =
      trip_fixture(ctx.organization.id, ctx.version.id, pattern.route_id, %{
        trip_id: "T-#{shape_id}",
        shape_id: shape_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })

    points
    |> Enum.with_index(0)
    |> Enum.each(fn {{lat, lon}, sequence} ->
      %Shape{}
      |> Shape.changeset(%{
        organization_id: ctx.organization.id,
        gtfs_version_id: ctx.version.id,
        shape_id: shape_id,
        shape_pt_sequence: sequence,
        shape_pt_lat: lat,
        shape_pt_lon: lon,
        shape_dist_traveled: to_string(sequence * 100)
      })
      |> Repo.insert!()
    end)

    trip
  end

  # The menu links' own `href`, read from the rendered page so a typo in the
  # component cannot be mirrored by the test.
  defp href(view, selector) do
    assert [href] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(selector)
             |> LazyHTML.attribute("href")

    href
  end

  defp open_alignment(%{conn: conn, version: version}, route, pattern) do
    path =
      "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=alignment"

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#alignment-task")

    view
  end
end
