defmodule GtfsPlannerWeb.Gtfs.FlexAreaEditorLiveTest.UnavailableBoundaries do
  @moduledoc """
  A boundary service that never answers, for the editor's `#census-unavailable`
  state (AC-10). Every callback answers `:unavailable`, the behaviour's own
  service-failure term.
  """

  @behaviour GtfsPlanner.Boundaries.Behaviour

  @impl GtfsPlanner.Boundaries.Behaviour
  def places_near(_bbox), do: {:error, :unavailable}

  @impl GtfsPlanner.Boundaries.Behaviour
  def search(_name, _state_fips), do: {:error, :unavailable}

  @impl GtfsPlanner.Boundaries.Behaviour
  def boundary(_layer, _geoid), do: {:error, :unavailable}

  @impl GtfsPlanner.Boundaries.Behaviour
  def water(_bbox), do: {:error, :unavailable}
end

defmodule GtfsPlannerWeb.Gtfs.FlexAreaEditorLiveTest.ControlledBoundaries do
  @moduledoc """
  The recorded boundaries with two controls the editor's timing and extent cases
  need: `places_near/1` and `search/2` report what they were asked to the test
  process, and `boundary/2` can be held open until the test releases it.

  The controls are read from the application environment
  (`:area_editor_boundary_owner`, `:area_editor_boundary_block`) and set and
  restored by the test that needs them, because a boundary service is a global
  the test file shares.
  """

  @behaviour GtfsPlanner.Boundaries.Behaviour

  alias GtfsPlanner.BrowserBoundaries

  @impl GtfsPlanner.Boundaries.Behaviour
  def places_near(bbox) do
    notify({:places_near, bbox})
    BrowserBoundaries.places_near(bbox)
  end

  @impl GtfsPlanner.Boundaries.Behaviour
  def search(name, state_fips) do
    notify({:search, name, state_fips})
    BrowserBoundaries.search(name, state_fips)
  end

  @impl GtfsPlanner.Boundaries.Behaviour
  def boundary(layer, geoid) do
    if Application.get_env(:gtfs_planner, :area_editor_boundary_block, false) do
      notify({:boundary_requested, self()})

      receive do
        :release -> BrowserBoundaries.boundary(layer, geoid)
      end
    else
      BrowserBoundaries.boundary(layer, geoid)
    end
  end

  @impl GtfsPlanner.Boundaries.Behaviour
  def water(bbox), do: BrowserBoundaries.water(bbox)

  defp notify(message) do
    case Application.get_env(:gtfs_planner, :area_editor_boundary_owner) do
      nil -> :ok
      owner -> send(owner, message)
    end
  end
end

defmodule GtfsPlannerWeb.Gtfs.FlexAreaEditorLiveTest do
  @moduledoc """
  Merge evidence (EV-24) for the area editor's creation routes (AC-10, AC-11,
  AC-13 and AC-14).

  The editor is judged as staff work it: `:area` is entered by `push_patch` from
  the service page, so an unsaved hours edit is still in the draft when the
  editor returns, and the draft is written only when "Use this area" puts the
  candidate in it. Nothing reaches the database until the service page's Save,
  which the case counts rows to prove (CR-8).

  The creation routes are judged through the real LiveView and the real test
  database: the Census picker over the version's stop extent (and the
  name-and-state search when the version has no stops), a Census pick that
  stores the water-removed land boundary with its GEOID, layer and vintage, the
  route buffer from `Flex.Geometry.route_buffer/4`, and a GeoJSON file's
  features, lines, swapped coordinates and size limit. The stats, the overlap
  and the comparison come from `Flex.Geometry` against the same fixtures.

  TIGERweb is replaced with `GtfsPlanner.BrowserBoundaries` (the recorded
  fixtures) and, for the failure and timing cases, with the two Mox-free stubs
  above; the global boundary service is set and restored per test.

  The focused command is deferred to branch review:
  `mix test test/gtfs_planner_web/live/gtfs/flex_area_editor_live_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.FlexAreaEditorLiveTest.ControlledBoundaries
  alias GtfsPlannerWeb.Gtfs.FlexAreaEditorLiveTest.UnavailableBoundaries
  alias GtfsPlannerWeb.Gtfs.FlexComponents

  @newport_geoid "4152450"
  @toledo_geoid "4174000"
  @cdp_geoid "4104850"

  describe "the editor and the draft" do
    setup :editor_with_flex_version

    test "Edit area patches to the editor and keeps the unsaved hours edit", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => hours_params(service, end: "17:00")})

      assert has_element?(view, "#flex-service-page[data-dirty='true']")

      view |> element("#edit-area-a1") |> render_click()

      assert_patch(view, area_path(ctx.version, service, "a1"))
      assert has_element?(view, "#area-panel")
      assert has_element?(view, "#area-title", "Edit area")
      assert has_element?(view, "#area-subtitle", "The service keeps this area when you save it.")

      # The four ways in, town limits first.
      assert positions(doc(view), [
               "area-mode-town",
               "area-mode-routes",
               "area-mode-draw",
               "area-mode-import"
             ]) == [
               "area-mode-town",
               "area-mode-routes",
               "area-mode-draw",
               "area-mode-import"
             ]

      view |> element("#cancel-area") |> render_click()

      assert_patch(view, service_path(ctx.version, service))
      assert has_element?(view, "#service_hours_0_end[value='17:00']")
      assert has_element?(view, "#flex-service-page[data-dirty='true']")

      # Leaving the editor wrote nothing.
      assert stored(ctx, service).hours == service.hours
    end

    test "a new area starts with a name field and Use this area disabled with its reason", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#add-area") |> render_click()

      assert_patch(view, area_path(ctx.version, service, "new"))
      assert has_element?(view, "#area-title", "Add area")
      assert has_element?(view, "#use-area[disabled]")
      assert has_element?(view, "#use-area-reason", "Choose how to set the area first.")

      # The server refuses the event even when the disabled button is bypassed
      # (the direct event form is what a crafted client payload would send).
      render_click(view, "use_area")

      assert has_element?(view, "#use-area-reason", "Choose how to set the area first.")
      assert length(stored(ctx, service).areas) == 2
    end
  end

  describe "town or city limits" do
    setup :editor_with_flex_version

    test "lists the places over the version's stop extent and labels CDPs", ctx do
      use_boundaries(ControlledBoundaries, owner: true)
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-town") |> render_click()

      # The picker asked for the places intersecting the version's own stops.
      assert_receive {:places_near, bbox}, 1_000
      assert bbox == Flex.stop_extent(ctx.organization.id, ctx.version.id)

      render_async(view, 5_000)

      assert has_element?(view, "#census-place-#{@newport_geoid}", "Newport city")
      assert has_element?(view, "#census-place-#{@toledo_geoid}", "Toledo city")

      # A census-designated place is labelled as one, not as a legal boundary.
      assert has_element?(view, "#census-place-#{@cdp_geoid}", "Bayshore CDP")
      assert has_element?(view, "#census-place-#{@cdp_geoid}", "Census-designated place")

      assert render(view) =~ "U.S. Census Bureau, boundaries as of January 1, 2026"
    end

    test "choosing Newport stores the land boundary with its provenance", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-town") |> render_click()
      render_async(view, 5_000)

      view |> element("#census-place-form") |> render_change(%{"geoid" => @newport_geoid})
      render_async(view, 5_000)

      # AC-10: the land polygon (Census water removed) measured on the real
      # server; the fixture's Newport is 25.8 km² (EV-3's measurement).
      assert has_element?(view, "#area-stats")
      assert text_of(doc(view), "#area-stats") =~ "25.8 km²"

      assert text_of(doc(view), "#area-source") =~
               "U.S. Census Bureau 2026 boundaries (GEOID #{@newport_geoid})"

      assert text_of(doc(view), "#area-stats") =~ "Census water areas left out"
      assert has_element?(view, "#area-name[value='Newport city']")
      refute has_element?(view, "#use-area[disabled]")

      # The boundary is land: smaller than the Census boundary's envelope and
      # exactly what `Boundaries.land_boundary/2` answers.
      {:ok, land} = GtfsPlanner.Boundaries.land_boundary("place", @newport_geoid)
      expected = Geometry.stats(ctx.organization.id, ctx.version.id, land.geojson)

      assert text_of(doc(view), "#area-stats") =~
               "#{FlexComponents.km2_text(expected.km2)} km²"
    end

    test "the stats panel names the stops inside, the routes and the overlap", ctx do
      # One active neighbour whose drawn area sits inside the Newport boundary,
      # so the overlap read has a deterministic service to name.
      {:ok, neighbour} =
        Flex.create_service(ctx.organization.id, ctx.version.id, %{
          name: "Neighbor Flex",
          kind: :area
        })

      {:ok, neighbour} =
        Flex.save_service(ctx.organization.id, ctx.version.id, neighbour, %{}, [
          %{key: "a1", name: "Central Newport", source: :drawn, geojson: central_newport()}
        ])

      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-town") |> render_click()
      render_async(view, 5_000)

      view |> element("#census-place-form") |> render_change(%{"geoid" => @newport_geoid})
      render_async(view, 5_000)

      # AC-14: km², the stops inside and the routes serving them, from
      # `Flex.Geometry.stats/3` over the version — the same measurement the
      # panel shows.
      {:ok, land} = GtfsPlanner.Boundaries.land_boundary("place", @newport_geoid)
      expected = Geometry.stats(ctx.organization.id, ctx.version.id, land.geojson)

      names =
        Map.new(Flex.stop_choices(ctx.organization.id, ctx.version.id), fn {name, id} ->
          {id, name}
        end)

      stats = text_of(doc(view), "#area-stats")

      assert stats =~ "Size"
      assert stats =~ "#{FlexComponents.km2_text(expected.km2)} km²"

      for stop_id <- expected.stop_ids, do: assert(stats =~ names[stop_id])

      if expected.route_ids == [] do
        assert stats =~ "No fixed routes"
      else
        for route_id <- expected.route_ids, do: assert(stats =~ route_id)
      end

      # The other active service whose stored area intersects the candidate is
      # information, not an error.
      overlaps = Geometry.overlaps(ctx.organization.id, ctx.version.id, land.geojson, service.id)
      assert Enum.any?(overlaps, &(&1.service_id == neighbour.id and &1.km2 >= 0.5))

      assert has_element?(view, "#area-overlap-#{neighbour.id}", "Overlaps another service")
      assert has_element?(view, "#area-overlap-#{neighbour.id}", "Neighbor Flex")
    end

    test "the comparison names the stops that leave and join against the saved area", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-town") |> render_click()
      render_async(view, 5_000)

      # The saved a1 is the fixture's drawn Newport square; Toledo's boundary is
      # a different shape with different stops inside.
      view |> element("#census-place-form") |> render_change(%{"geoid" => @toledo_geoid})
      render_async(view, 5_000)

      assert has_element?(view, "#area-compare", "Compared with the saved area")

      comparison = text_of(doc(view), "#area-compare")
      assert comparison =~ "km² ("
      assert comparison =~ "→"
      assert comparison =~ "No longer inside:" or comparison =~ "Now inside:"
    end

    test "a version with no stops offers the name and state search", ctx do
      version = gtfs_version_fixture(ctx.organization.id)

      {:ok, service} =
        Flex.create_service(ctx.organization.id, version.id, %{name: "No Stops", kind: :area})

      {:ok, view, _html} = live(ctx.conn, service_path(version, service))

      loaded(view)

      view |> element("#add-area") |> render_click()
      view |> element("#area-mode-town") |> render_click()

      # AC-10: no stops to bound the extent, so the picker asks for a name and a
      # state instead of listing the extent's places.
      assert has_element?(view, "#census-search-form")
      assert has_element?(view, "#census-search-name")
      assert has_element?(view, "#census-search-state")
      refute has_element?(view, "#census-place-#{@newport_geoid}")

      view
      |> element("#census-search-form")
      |> render_submit(%{"place_name" => "Newport", "state_fips" => "41"})

      render_async(view, 5_000)

      assert has_element?(view, "#census-place-#{@newport_geoid}", "Newport city")

      view |> element("#census-place-form") |> render_change(%{"geoid" => @newport_geoid})
      render_async(view, 5_000)

      assert has_element?(view, "#area-stats")
      assert text_of(doc(view), "#area-source") =~ "GEOID #{@newport_geoid}"
    end

    test "an unavailable boundary service shows the three next actions and changes nothing",
         ctx do
      use_boundaries(UnavailableBoundaries)
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()

      before = doc(view)

      view |> element("#area-mode-town") |> render_click()
      render_async(view, 5_000)

      # AC-10: the failure is stated, offers the three ways forward, and the
      # draft and the candidate are untouched.
      assert has_element?(view, "#census-unavailable", "Census boundaries unavailable")
      assert has_element?(view, "#census-retry", "Try again")
      assert has_element?(view, "#census-import", "Import a file")
      assert has_element?(view, "#census-draw", "Draw on the map")
      refute has_element?(view, "#area-stats")

      assert text_of(doc(view), "#use-area-reason") == "Set the area first."
      assert length(stored(ctx, service).areas) == 2
      assert text_of(doc(view), "#area-title") == text_of(before, "#area-title")

      # Try again re-asks the service, and a recovered service lists its places.
      use_boundaries(ControlledBoundaries)
      view |> element("#census-retry") |> render_click()
      render_async(view, 5_000)

      assert has_element?(view, "#census-place-#{@newport_geoid}")
    end

    test "an unavailable pick leaves the listed places and the draft unchanged", ctx do
      use_boundaries(UnavailableBoundaries)
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-town") |> render_click()
      render_async(view, 5_000)

      # The places never loaded, so the panel is the unavailable state; the
      # draft has no candidate and Use this area stays disabled.
      assert has_element?(view, "#census-unavailable")
      refute has_element?(view, "#area-stats")
      assert length(stored(ctx, service).areas) == 2
      assert Repo.aggregate(GtfsPlanner.Gtfs.FlexArea, :count, :id) == 3
    end

    test "a slow boundary service shows its loading state", ctx do
      use_boundaries(ControlledBoundaries, owner: true, block: true)
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-town") |> render_click()
      render_async(view, 5_000)

      view |> element("#census-place-form") |> render_change(%{"geoid" => @newport_geoid})

      # The request is held open, so the pick's own render is the loading state
      # (the reference's spinner appears once the request outlasts 300 ms).
      assert_receive {:boundary_requested, task}, 1_000
      refute has_element?(view, "#census-loading")

      send(view.pid, :area_census_slow)
      assert has_element?(view, "#census-loading")

      send(task, :release)
      render_async(view, 5_000)

      refute has_element?(view, "#census-loading")
      assert has_element?(view, "#area-stats")
    end
  end

  describe "distance from routes" do
    setup :editor_with_flex_version

    test "checking a route and a distance buffers the version's routes", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-routes") |> render_click()

      # AC-11: nothing chosen yet, so there is no candidate.
      assert has_element?(view, "#area-follows-routes", "Follows the current routes")
      refute has_element?(view, "#area-stats")

      view
      |> element("#area-routes-form")
      |> render_change(%{"route_ids" => ["20"], "distance_m" => "800"})

      # The candidate is the buffer `Geometry.route_buffer/4` builds, measured
      # against the version.
      {:ok, buffer} =
        Geometry.route_buffer(ctx.organization.id, ctx.version.id, ["20"], 800)

      expected = Geometry.stats(ctx.organization.id, ctx.version.id, buffer)

      assert text_of(doc(view), "#area-stats") =~ "#{FlexComponents.km2_text(expected.km2)} km²"
      assert text_of(doc(view), "#area-stats") =~ " on #{length(expected.route_ids)}"
      assert text_of(doc(view), "#area-source") =~ "Distance from the current routes · 800 m"
      assert has_element?(view, "#area-name[value='Valley Line corridor']")
      refute has_element?(view, "#use-area[disabled]")

      # A missing route is reported, and the candidate is dropped.
      view
      |> element("#area-routes-form")
      |> render_change(%{"route_ids" => ["1", "20"], "distance_m" => "800"})

      assert has_element?(view, "#area-stats")

      # Unchecking every route clears the candidate.
      view
      |> element("#area-routes-form")
      |> render_change(%{"route_ids" => [], "distance_m" => "800"})

      refute has_element?(view, "#area-stats")
      assert has_element?(view, "#use-area[disabled]")
    end
  end

  describe "import a file" do
    setup :editor_with_flex_version

    test "a file with two polygons lists both names and picking one measures it", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-import") |> render_click()

      upload =
        file_input(view, "#area-upload-form", :area_file, [
          %{name: "provider-zones.geojson", content: two_zone_geojson()}
        ])

      render_upload(upload, "provider-zones.geojson")

      # AC-13: every polygon feature is offered by its `name`, the first is
      # picked, and the pick is normalized through `Geometry.normalize/1`.
      assert has_element?(view, "#area-feature-1", "North zone")
      assert has_element?(view, "#area-feature-2", "South zone")
      assert has_element?(view, "#area-feature-form", "Named by the file’s “name” field")
      assert has_element?(view, "#area-name[value='North zone']")
      assert has_element?(view, "#area-source", "Imported from provider-zones.geojson")
      assert has_element?(view, "#area-stats")

      view |> element("#area-feature-form") |> render_change(%{"feature" => "2"})

      assert has_element?(view, "#area-name[value='South zone']")
      assert has_element?(view, "#area-stats")
    end

    test "a file of lines is refused with the closed-shape message", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-import") |> render_click()

      upload =
        file_input(view, "#area-upload-form", :area_file, [
          %{name: "route-lines.geojson", content: line_geojson()}
        ])

      render_upload(upload, "route-lines.geojson")

      assert has_element?(view, "#area-file-lines", "This file has lines, not areas")
      assert has_element?(view, "#area-file-lines", "A flex area must be a closed shape")
      assert has_element?(view, "#area-file-routes", "Use distance from routes")
      refute has_element?(view, "#area-feature-form")

      # The offer is the way out of the dead end.
      view |> element("#area-file-routes") |> render_click()

      assert has_element?(view, "#area-follows-routes")
    end

    test "a swapped file offers Swap and preview and swaps it", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-import") |> render_click()

      upload =
        file_input(view, "#area-upload-form", :area_file, [
          %{name: "zones-swapped.geojson", content: swapped_geojson()}
        ])

      render_upload(upload, "zones-swapped.geojson")

      # AC-13: a latitude beyond ±90 offers the swap instead of storing a
      # nonsense shape.
      assert has_element?(view, "#area-file-swapped", "wrong way round")
      assert has_element?(view, "#area-file-swap", "Swap and preview")
      refute has_element?(view, "#area-feature-form")

      view |> element("#area-file-swap") |> render_click()

      assert has_element?(view, "#area-feature-1", "Swapped zone")
      assert has_element?(view, "#area-stats")
    end

    test "a file over 5 MB is rejected by the upload", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#edit-area-a1") |> render_click()
      view |> element("#area-mode-import") |> render_click()

      upload =
        file_input(view, "#area-upload-form", :area_file, [
          %{name: "huge.geojson", content: String.duplicate("-", 5_000_001)}
        ])

      _result = render_upload(upload, "huge.geojson")

      assert render(view) =~ "File is too large"
      refute has_element?(view, "#area-feature-form")
      refute has_element?(view, "#area-stats")
    end
  end

  describe "using the area" do
    setup :editor_with_flex_version

    test "Use this area puts it in the draft, dirties the page and stores nothing", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      rows = Repo.aggregate(GtfsPlanner.Gtfs.FlexArea, :count, :id)

      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#add-area") |> render_click()
      view |> element("#area-mode-town") |> render_click()
      render_async(view, 5_000)

      view |> element("#census-place-form") |> render_change(%{"geoid" => @toledo_geoid})
      render_async(view, 5_000)

      view |> element("#use-area") |> render_click()

      assert_patch(view, service_path(ctx.version, service))

      # The draft has the new area and the page is dirty; the where section
      # shows it with the Census source line.
      assert has_element?(view, "#flex-service-page[data-dirty='true']")
      assert has_element?(view, "#f-area-a3", "Toledo city")
      assert has_element?(view, "#f-area-a3", "U.S. Census Bureau 2026")
      assert has_element?(view, "#save-bar")

      # CR-8: nothing was stored, before or by the patch.
      assert Repo.aggregate(GtfsPlanner.Gtfs.FlexArea, :count, :id) == rows
      assert length(stored(ctx, service).areas) == 2

      # Cancel from a re-entered editor leaves the draft's area in place.
      view |> element("#edit-area-a3") |> render_click()
      assert_patch(view, area_path(ctx.version, service, "a3"))
      assert has_element?(view, "#area-name[value='Toledo city']")
      assert has_element?(view, "#area-source", "GEOID #{@toledo_geoid}")

      view |> element("#cancel-area") |> render_click()

      assert_patch(view, service_path(ctx.version, service))
      assert has_element?(view, "#f-area-a3")
      assert Repo.aggregate(GtfsPlanner.Gtfs.FlexArea, :count, :id) == rows
    end

    test "saving the service writes the area the editor built", ctx do
      service = service_named(ctx.organization.id, ctx.version.id, "Newport Dial-a-Ride")
      {:ok, view, _html} = live(ctx.conn, service_path(ctx.version, service))

      loaded(view)

      view |> element("#add-area") |> render_click()
      view |> element("#area-mode-town") |> render_click()
      render_async(view, 5_000)

      view |> element("#census-place-form") |> render_change(%{"geoid" => @newport_geoid})
      render_async(view, 5_000)

      view |> element("#use-area") |> render_click()
      assert_patch(view, service_path(ctx.version, service))

      view
      |> element("#flex-service-form")
      |> render_submit(%{"service" => hours_params(service, [])})

      stored = stored(ctx, service)

      assert has_element?(view, "#flex-service-page[data-dirty='false']")
      assert length(stored.areas) == 3

      area = Enum.find(stored.areas, &(&1.key == "a3"))

      assert area.name == "Newport city"
      assert area.source == :census
      assert area.census_geoid == @newport_geoid
      assert area.census_layer == "place"
      assert area.census_vintage == "2026"

      # The stored geometry is the land boundary the editor measured, and the
      # where section reads it back.
      {:ok, land} = GtfsPlanner.Boundaries.land_boundary("place", @newport_geoid)
      geojson = Geometry.get_geojson([area.id])[area.id]

      assert Geometry.stats(ctx.organization.id, ctx.version.id, geojson).km2 ==
               Geometry.stats(ctx.organization.id, ctx.version.id, land.geojson).km2

      assert has_element?(view, "#f-area-a3", "Newport city")
    end
  end

  # --- setup ------------------------------------------------------------------

  defp editor_with_flex_version(%{conn: conn}) do
    organization = organization_fixture()
    user = editor_for(organization)
    version = gtfs_version_fixture(organization.id)
    services = flex_representative_fixture(organization, version)

    use_boundaries(GtfsPlanner.BrowserBoundaries)

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      user: user,
      version: version,
      services: services.services,
      calendars: Flex.calendars_map(organization.id, version.id)
    }
  end

  defp editor_for(organization) do
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    user
  end

  # A boundary service is a global (`Application.get_env`), so every case that
  # swaps it restores the previous module afterwards.
  defp use_boundaries(module, opts \\ []) do
    previous = Application.get_env(:gtfs_planner, :boundaries_service)
    Application.put_env(:gtfs_planner, :boundaries_service, module)

    if opts[:owner], do: Application.put_env(:gtfs_planner, :area_editor_boundary_owner, self())
    if opts[:block], do: Application.put_env(:gtfs_planner, :area_editor_boundary_block, true)

    on_exit(fn ->
      if previous do
        Application.put_env(:gtfs_planner, :boundaries_service, previous)
      else
        Application.delete_env(:gtfs_planner, :boundaries_service)
      end

      Application.delete_env(:gtfs_planner, :area_editor_boundary_owner)
      Application.delete_env(:gtfs_planner, :area_editor_boundary_block)
    end)

    :ok
  end

  # --- fixtures ---------------------------------------------------------------

  defp two_zone_geojson do
    Jason.encode!(%{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "properties" => %{"name" => "North zone"},
          "geometry" => zone_polygon(-124.06, 44.61, 0.02)
        },
        %{
          "type" => "Feature",
          "properties" => %{"name" => "South zone"},
          "geometry" => zone_polygon(-124.04, 44.59, 0.03)
        }
      ]
    })
  end

  defp line_geojson do
    Jason.encode!(%{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "properties" => %{"name" => "Route 20"},
          "geometry" => %{
            "type" => "LineString",
            "coordinates" => [[-124.05, 44.605], [-123.93, 44.62]]
          }
        }
      ]
    })
  end

  # GeoJSON lists longitude first; this file's first position reads 44.6, -124.0,
  # so its latitude is beyond ±90 and the editor offers the swap.
  defp swapped_geojson do
    Jason.encode!(%{
      "type" => "Feature",
      "properties" => %{"name" => "Swapped zone"},
      "geometry" => %{
        "type" => "Polygon",
        "coordinates" => [
          [
            [44.61, -124.06],
            [44.61, -124.04],
            [44.59, -124.04],
            [44.59, -124.06],
            [44.61, -124.06]
          ]
        ]
      }
    })
  end

  defp central_newport do
    %{
      "type" => "Polygon",
      "coordinates" => [
        [
          [-124.075, 44.595],
          [-124.045, 44.595],
          [-124.045, 44.625],
          [-124.075, 44.625],
          [-124.075, 44.595]
        ]
      ]
    }
  end

  defp zone_polygon(west, south, size) do
    east = west + size
    north = south + size

    %{
      "type" => "Polygon",
      "coordinates" => [
        [[west, south], [east, south], [east, north], [west, north], [west, south]]
      ]
    }
  end

  # --- helpers ----------------------------------------------------------------

  defp service_path(version, service), do: "/gtfs/#{version.id}/flex/#{service.id}"

  defp area_path(version, service, key),
    do: "/gtfs/#{version.id}/flex/#{service.id}/area?area=#{key}"

  defp hours_params(service, opts) do
    hours =
      service.hours
      |> Enum.with_index()
      |> Map.new(fn {hour, index} ->
        {Integer.to_string(index), hours_row(hour, index, opts, length(service.areas) > 1)}
      end)

    rules =
      service.booking_rules
      |> Enum.with_index()
      |> Map.new(fn {rule, index} ->
        {Integer.to_string(index),
         %{
           "service_id" => rule.service_id || "",
           "when" => to_string(rule.when || ""),
           "minutes" => integer_param(rule.minutes),
           "days" => integer_param(rule.days),
           "by" => rule.by || "",
           "business_days" => to_string(rule.business_days),
           "office_service_id" => rule.office_service_id || ""
         }}
      end)

    %{
      "hours" => hours,
      "booking_rules" => rules,
      "phone" => service.phone || "",
      "phone_hours_on" => to_string(service.phone_hours != nil),
      "booking_url" => service.booking_url || "",
      "info_url" => service.info_url || "",
      "note" => service.note || ""
    }
  end

  defp hours_row(hour, 0, %{end: end_time}, multi_area?),
    do: hour_row(hour, end_time, multi_area?)

  defp hours_row(hour, _index, _opts, multi_area?), do: hour_row(hour, hour.end, multi_area?)

  defp hour_row(hour, end_time, multi_area?) do
    row = %{"service_id" => hour.service_id, "start" => hour.start, "end" => end_time}

    if multi_area?, do: Map.put(row, "area_key", hour.area_key || ""), else: row
  end

  defp integer_param(nil), do: ""
  defp integer_param(value), do: Integer.to_string(value)

  defp stored(ctx, service) do
    {:ok, stored} = Flex.get_service(ctx.organization.id, ctx.version.id, service.id)
    stored
  end

  defp service_named(organization_id, version_id, name) do
    organization_id
    |> Flex.list_services(version_id)
    |> Enum.find(&(&1.name == name))
  end

  defp loaded(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp positions(document, ids) do
    html = LazyHTML.to_html(document)

    ids
    |> Enum.map(fn id -> {id, :binary.match(html, "id=\"#{id}\"") |> elem(0)} end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end
end
