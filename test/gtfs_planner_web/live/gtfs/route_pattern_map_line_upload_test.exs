defmodule GtfsPlannerWeb.Gtfs.RoutePatternMapLineUploadTest do
  @moduledoc false
  # EV-28: the Map line tab's "Import a path file" panel, through the real
  # LiveView upload (CL-22, CL-23; FH-22, FH-23). Every case goes through
  # `file_input/4` + `render_upload/2` on the rendered page and the panel's own
  # submit event, so the production path is the one under test: the upload's
  # limits, `MapLineFiles.parse/2` and the file's own message. Expected values
  # are literals from the parser's documented contract and the prototype's
  # `err-*` states, never read back from the code under test.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  setup :editor_scope

  test "a two-line KMZ lists both lines with their names, lengths and point counts", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload = file_input(view, "#map-line-upload-form", :map_line_file, kmz_entry("my maps.kmz"))
    assert render_upload(upload, "my maps.kmz")

    view |> element("#map-line-upload-form") |> render_submit()

    # The My Maps archive's first two pieces meet, so they are one line named
    # after the first piece; the third never meets them and stays its own line.
    assert has_element?(view, "#file-line-0")
    assert has_element?(view, "#file-line-1")
    refute has_element?(view, "#file-line-2")

    assert has_element?(view, "label[for='file-line-0']", "Walking Route")
    assert has_element?(view, "label[for='file-line-0']", "Joined from 2 pieces")
    assert has_element?(view, "label[for='file-line-0']", "0.7 km")
    assert has_element?(view, "label[for='file-line-0']", "4 points")

    # The second line's own piece carries no name of its own, so the panel
    # names it by its position rather than showing a blank.
    assert has_element?(view, "label[for='file-line-1']", "Line 2")
    assert has_element?(view, "label[for='file-line-1']", "0.4 km")
    assert has_element?(view, "label[for='file-line-1']", "2 points")

    assert has_element?(view, "#file-import-file-row", "my maps.kmz")
    assert has_element?(view, "#file-import-panel", "Which line is this pattern’s path?")
    assert has_element?(view, "#file-import-restart", "Choose another file")
    refute has_element?(view, "#file-error-unreadable")
  end

  test "choosing a line pushes that line's points to the hook and closes the panel", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload = file_input(view, "#map-line-upload-form", :map_line_file, kmz_entry("my maps.kmz"))
    assert render_upload(upload, "my maps.kmz")
    view |> element("#map-line-upload-form") |> render_submit()

    view |> element("#file-line-form") |> render_change(%{"line" => "1"})

    # AC-22: the chosen line, not the joined one, is what the hook receives.
    assert_push_event(view, "alignment:file_line", %{
      points: [[-71.0637, 42.3754], [-71.0601, 42.3772]],
      name: nil
    })

    refute render(view) =~ "id=\"file-import-panel\""
  end

  test "a line index the file does not have pushes nothing", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload = file_input(view, "#map-line-upload-form", :map_line_file, kmz_entry("my maps.kmz"))
    assert render_upload(upload, "my maps.kmz")
    view |> element("#map-line-upload-form") |> render_submit()

    view |> element("#file-line-form") |> render_change(%{"line" => "7"})

    # An index this file does not have leaves the pick exactly as it was.
    assert has_element?(view, "#file-line-form")
  end

  test "a one-line GeoJSON goes straight to the fit without a pick", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload =
      file_input(view, "#map-line-upload-form", :map_line_file, [
        %{name: "route-line.geojson", content: one_line_geojson()}
      ])

    assert render_upload(upload, "route-line.geojson")
    view |> element("#map-line-upload-form") |> render_submit()

    assert_push_event(view, "alignment:file_line", %{
      points: [[-71.0637, 42.3554], [-71.0565, 42.3590]],
      name: "Coast Highway"
    })

    refute render(view) =~ "id=\"file-import-panel\""
  end

  test "an entity-expanding KML is refused as unreadable", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload =
      file_input(view, "#map-line-upload-form", :map_line_file, [
        %{name: "bomb.kml", content: billion_laughs_kml()}
      ])

    assert render_upload(upload, "bomb.kml")
    view |> element("#map-line-upload-form") |> render_submit()

    assert has_element?(view, "#file-error-unreadable", "This file couldn’t be read")
    assert has_element?(view, "#file-error-unreadable", "It’s empty or damaged")
    assert has_element?(view, "#file-import-file-row", "Not used")
    # The chooser is the way out of a file problem, and it says so.
    assert has_element?(view, "#map-line-file-upload", "Choose another file")
    refute has_element?(view, "#file-line-form")
  end

  test "an archive entry that inflates past the cap is refused as too large", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    # 30 MB of zeros inside the archive: the archive itself is far under the
    # 10 MB upload limit, so only the parser's bounded inflate can stop it.
    upload =
      file_input(view, "#map-line-upload-form", :map_line_file, kmz_entry("big.kmz", nil, 30))

    assert render_upload(upload, "big.kmz")
    view |> element("#map-line-upload-form") |> render_submit()

    assert has_element?(view, "#file-error-too_large", "expands to more than the limit")
    assert has_element?(view, "#file-import-file-row", "Not used")
    refute has_element?(view, "#file-line-form")
  end

  test "an 11 MB file is refused by the upload's own size limit", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload =
      file_input(view, "#map-line-upload-form", :map_line_file, [
        %{name: "huge.kmz", content: :binary.copy(<<"kml">>, 11_000_000)}
      ])

    assert {:error, [[_ref, :too_large]]} = render_upload(upload, "huge.kmz")

    # The file never reached the parser: the upload's own message is what the
    # editor sees, and the panel is still on the choose step.
    assert render(view) =~ "File is too large"
    refute render(view) =~ "id=\"file-line-form\""
    refute render(view) =~ "id=\"file-error-"
  end

  test "a shapefile is refused by the upload's accept list", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload =
      file_input(view, "#map-line-upload-form", :map_line_file, [
        %{name: "route-line.shp", content: "not a map file"}
      ])

    assert {:error, [[_ref, :not_accepted]]} = render_upload(upload, "route-line.shp")

    assert render(view) =~ "File type not accepted"
    refute render(view) =~ "id=\"file-error-"
  end

  test "a KMZ that only links to a network map gets its own message", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload =
      file_input(
        view,
        "#map-line-upload-form",
        :map_line_file,
        kmz_entry("feed.kmz", network_link_kml())
      )

    assert render_upload(upload, "feed.kmz")
    view |> element("#map-line-upload-form") |> render_submit()

    assert has_element?(view, "#file-error-network_link", "links to a map online")
    assert has_element?(view, "#file-error-network_link", "network link KML")
    refute has_element?(view, "#file-line-form")
  end

  test "a GeoJSON listing latitude first gets the swapped message", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload =
      file_input(view, "#map-line-upload-form", :map_line_file, [
        %{name: "swapped.geojson", content: swapped_geojson()}
      ])

    assert render_upload(upload, "swapped.geojson")
    view |> element("#map-line-upload-form") |> render_submit()

    assert has_element?(view, "#file-error-swapped", "the wrong way round")
    assert has_element?(view, "#file-error-swapped", "GeoJSON lists longitude first")
  end

  test "a file of points only gets its own message", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload =
      file_input(view, "#map-line-upload-form", :map_line_file, [
        %{name: "stops.geojson", content: points_geojson()}
      ])

    assert render_upload(upload, "stops.geojson")
    view |> element("#map-line-upload-form") |> render_submit()

    assert has_element?(view, "#file-error-points_only", "points, not a line")
  end

  test "choosing another file drops the message and the file", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    upload =
      file_input(view, "#map-line-upload-form", :map_line_file, [
        %{name: "bomb.kml", content: billion_laughs_kml()}
      ])

    assert render_upload(upload, "bomb.kml")
    view |> element("#map-line-upload-form") |> render_submit()
    assert has_element?(view, "#file-error-unreadable")

    # Reopening the panel is the section list's own entry, and it starts again
    # from the choose step with the previous file and its message dropped.
    view |> element("#file-import-cancel") |> render_click()
    view |> element("#alignment-open-file-import") |> render_click()

    refute render(view) =~ "id=\"file-error-"
    assert has_element?(view, "#file-import-panel", "Choose a file")
  end

  test "leaving the panel closes it and keeps the sections", ctx do
    {route, pattern} = drawn_pattern(ctx)
    view = open_panel(ctx, route, pattern)

    view |> element("#file-import-cancel") |> render_click()

    refute render(view) =~ "id=\"file-import-panel\""
    assert has_element?(view, "#alignment-task")
    assert has_element?(view, "#alignment-section-1")
  end

  # --- fixtures -------------------------------------------------------------

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "map-line-file-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "map-line-file-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  # Boston Common to Downtown Crossing, split where a My Maps export breaks it,
  # plus a second leg 2 km north that never meets the first.
  @common [-71.0637, 42.3554]
  @mid [-71.0601, 42.3572]
  @after_mid [-71.0601, 42.3573]
  @crossing [-71.0565, 42.3590]
  @north [-71.0637, 42.3754]
  @north_end [-71.0601, 42.3772]

  defp drawn_pattern(%{organization: organization, version: version}) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "FILE1",
        route_short_name: "FILE1",
        route_long_name: "FILE1 corridor"
      })

    for {stop_id, name, lat, lon} <- [
          {"FL1_A", "File Alpha", "42.355400", "-71.063700"},
          {"FL1_B", "File Bravo", "42.359000", "-71.056500"},
          {"FL1_C", "File Charlie", "42.375400", "-71.063700"},
          {"FL1_D", "File Delta", "42.377200", "-71.060100"}
        ] do
      stop_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new(lon)
      })
    end

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "P-FILE-A",
        route_pattern_name: "P-FILE-A",
        direction_id: 0
      })

    ["FL1_A", "FL1_B", "FL1_C", "FL1_D"]
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    {route, pattern}
  end

  # Step 30 / EV-29: the fit the hook reports for the file line. The hook
  # measures the line against the model's visits and pushes the result; the
  # editor never sends it, so a forged or misshapen push must leave the
  # reported fit alone instead of describing a line nobody picked.
  describe "the hook's fit of the file line" do
    test "a reported fit is kept for the review panel", ctx do
      {route, pattern} = drawn_pattern(ctx)
      view = open_panel(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", fit_params())

      assert :sys.get_state(view.pid).socket.assigns.file_fit == %{
               direction: "same",
               reaches_start: true,
               reaches_end: false,
               far: [%{position: 3, stop_id: "FL1_C", distance_m: 145.25}],
               within: 3,
               visit_count: 4,
               length_m: 812.4
             }
    end

    test "a forged fit leaves the reported fit alone", ctx do
      {route, pattern} = drawn_pattern(ctx)
      view = open_panel(ctx, route, pattern)
      render_hook(view, "alignment_fit_result", fit_params())
      before = :sys.get_state(view.pid).socket.assigns.file_fit

      # A direction the geometry never reports, and counts that do not add
      # up to the visits, are both refused.
      render_hook(view, "alignment_fit_result", %{fit_params() | "direction" => "sideways"})
      assert :sys.get_state(view.pid).socket.assigns.file_fit == before

      render_hook(
        view,
        "alignment_fit_result",
        Map.put(fit_params(), "visit_count", 99)
      )

      assert :sys.get_state(view.pid).socket.assigns.file_fit == before
      # The editor's page is still there.
      assert has_element?(view, "#file-import-panel")
    end

    test "a forged fit before any real one reports nothing", ctx do
      {route, pattern} = drawn_pattern(ctx)
      view = open_panel(ctx, route, pattern)

      render_hook(view, "alignment_fit_result", %{"direction" => "same"})

      assert is_nil(:sys.get_state(view.pid).socket.assigns.file_fit)
    end
  end

  defp fit_params do
    %{
      "direction" => "same",
      "reaches_start" => true,
      "reaches_end" => false,
      "far" => [%{"position" => 3, "stop_id" => "FL1_C", "distance_m" => 145.25}],
      "within" => 3,
      "visit_count" => 4,
      "length_m" => 812.4
    }
  end

  defp open_panel(%{conn: conn, version: version}, route, pattern) do
    path =
      "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=alignment"

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#alignment-open-file-import")
    view |> element("#alignment-open-file-import") |> render_click()
    assert has_element?(view, "#file-import-panel", "Import a path file")

    view
  end

  defp kmz_entry(name, document \\ my_maps_kml(), size_mb \\ nil) do
    payload =
      case size_mb do
        nil -> document
        megabytes -> :binary.copy(<<0>>, megabytes * 1024 * 1024)
      end

    [%{name: name, content: kmz([{~c"doc.kml", payload}])}]
  end

  defp kmz(entries) do
    path =
      Path.join(System.tmp_dir!(), "map-line-upload-#{System.unique_integer([:positive])}.kmz")

    try do
      {:ok, _path} = :zip.create(String.to_charlist(path), entries)
      File.read!(path)
    after
      File.rm(path)
    end
  end

  defp my_maps_kml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <name>Walking Route</name>
          <LineString>
            <coordinates>#{@common |> coord()} #{@mid |> coord()}</coordinates>
          </LineString>
        </Placemark>
        <Placemark>
          <name>Walking Route continued</name>
          <LineString>
            <coordinates>#{@after_mid |> coord()} #{@crossing |> coord()}</coordinates>
          </LineString>
        </Placemark>
        <Placemark>
          <name>Unrelated</name>
          <LineString>
            <coordinates>#{@north |> coord()} #{@north_end |> coord()}</coordinates>
          </LineString>
        </Placemark>
      </Document>
    </kml>
    """
  end

  defp coord([lon, lat]), do: "#{lon},#{lat},0"

  defp network_link_kml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml>
      <Document>
        <NetworkLink>
          <name>Live feed</name>
          <Link><href>https://example.test/feed.kml</href></Link>
        </NetworkLink>
      </Document>
    </kml>
    """
  end

  defp billion_laughs_kml do
    """
    <?xml version="1.0"?>
    <!DOCTYPE lolz [
     <!ENTITY lol "lol">
     <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
     <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
     <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
     <!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">
    ]>
    <kml><Document><Placemark><name>&lol5;</name></Placemark></Document></kml>
    """
  end

  defp one_line_geojson do
    Jason.encode!(%{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "properties" => %{"name" => "Coast Highway"},
          "geometry" => %{
            "type" => "LineString",
            "coordinates" => [@common, @crossing]
          }
        }
      ]
    })
  end

  # Latitude first: this is Oregon written `[lat, lon]`, so the second slot
  # carries a latitude no longitude could hold.
  defp swapped_geojson do
    Jason.encode!(%{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "properties" => %{"name" => "Swapped"},
          "geometry" => %{
            "type" => "LineString",
            "coordinates" => [
              [44.61, -124.05],
              [44.63, -122.33]
            ]
          }
        }
      ]
    })
  end

  defp points_geojson do
    Jason.encode!(%{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "properties" => %{"name" => "Stop 1"},
          "geometry" => %{"type" => "Point", "coordinates" => @common}
        },
        %{
          "type" => "Feature",
          "properties" => %{"name" => "Stop 2"},
          "geometry" => %{"type" => "Point", "coordinates" => @crossing}
        }
      ]
    })
  end
end
