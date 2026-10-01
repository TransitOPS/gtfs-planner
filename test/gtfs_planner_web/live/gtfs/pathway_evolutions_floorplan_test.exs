defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsFloorplanTest do
  @moduledoc """
  The static pathway floorplan of the Evolutions locator and of the access
  preview, through their ordinary routes: the stored coordinates the overlay
  reads, the Floorplan/List choice, the level switch, the selection it shares
  with the pathway list, the moment's closed set and the list fallback for a
  station without a usable image.

  Assertions are authored from AC-34, AC-36, AC-39, AC-40 and AC-44 and from
  FH-16/FH-18. Every coordinate, level and natural ID below is a hand-derived
  literal from the fixture, and the island is asserted to be an ignored,
  selection-only read: no case relies on a geometry write, and the stored
  coordinates are re-read after each interaction.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.DiagramStorage

  @station_stop %{
    stop_id: "FLOORPLAN_STATION",
    stop_name: "Floorplan Test Station",
    location_type: 1,
    parent_station: nil
  }

  # A real (if tiny) raster, so `DiagramStorage.public_path/4` resolves the
  # published file exactly as it does for an uploaded station floorplan.
  @floorplan_png Base.decode64!(
                   "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLqXQAAAABJRU5ErkJggg=="
                 )

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, version: version}
  end

  defp evolutions_path(version, stop_id) do
    "/gtfs/#{version.id}/stops/#{stop_id}/evolutions"
  end

  defp access_path(version, stop_id, date, time) do
    "/gtfs/#{version.id}/stops/#{stop_id}/evolutions/access?date=#{date}&time=#{time}"
  end

  # One station with two published levels: a Concourse whose stops carry the
  # stored width-normalized coordinates, and a Street whose only stop is the far
  # end of the cross-level pathway. The lift carries one saved closure, so the
  # access preview has a closed pathway to draw.
  defp station_with_floorplan(organization, version) do
    station = stop_fixture(organization.id, version.id, @station_stop)

    concourse =
      level_fixture(organization.id, version.id, %{
        level_id: "FP_L1",
        level_name: "Concourse",
        level_index: 0.0
      })

    street =
      level_fixture(organization.id, version.id, %{
        level_id: "FP_L2",
        level_name: "Street",
        level_index: 1.0
      })

    for {level, filename} <- [{concourse, "floorplan_l1.png"}, {street, "floorplan_l2.png"}] do
      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: filename
        })

      :ok =
        DiagramStorage.store_import_image(
          organization.id,
          version.id,
          station.stop_id,
          stop_level.diagram_filename,
          @floorplan_png
        )
    end

    on_exit(fn -> DiagramStorage.delete_version_namespace(organization.id, version.id) end)

    entrance =
      stop_fixture(organization.id, version.id, %{
        stop_id: "FP_ENTRANCE",
        stop_name: "North entrance",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: concourse.level_id,
        diagram_coordinate: %{"x" => 20, "y" => 15}
      })

    mezzanine =
      stop_fixture(organization.id, version.id, %{
        stop_id: "FP_MEZZANINE",
        stop_name: "Mezzanine hall",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: concourse.level_id,
        diagram_coordinate: %{"x" => 50, "y" => 30}
      })

    platform =
      stop_fixture(organization.id, version.id, %{
        stop_id: "FP_PLATFORM",
        stop_name: "Platform 1",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: concourse.level_id,
        diagram_coordinate: %{"x" => 78, "y" => 55}
      })

    street_stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "FP_STREET",
        stop_name: "Street landing",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: street.level_id,
        diagram_coordinate: %{"x" => 45, "y" => 55}
      })

    walk =
      pathway_fixture(organization.id, version.id, entrance.stop_id, mezzanine.stop_id, %{
        pathway_id: "FP/PW WALK",
        pathway_mode: 1,
        is_bidirectional: true
      })

    lift =
      pathway_fixture(organization.id, version.id, mezzanine.stop_id, platform.stop_id, %{
        pathway_id: "FP/PW LIFT",
        pathway_mode: 5,
        is_bidirectional: true
      })

    cross =
      pathway_fixture(organization.id, version.id, platform.stop_id, street_stop.stop_id, %{
        pathway_id: "FP/PW CROSS",
        pathway_mode: 5,
        is_bidirectional: false
      })

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    calendar_fixture(organization.id, version.id, %{
      service_id: "CAL_DAILY",
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    closure =
      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: lift.pathway_id,
        service_id: "CAL_DAILY",
        start_time: 32_400,
        end_time: 54_000
      })

    %{
      station: station,
      concourse: concourse,
      street: street,
      entrance: entrance,
      mezzanine: mezzanine,
      platform: platform,
      street_stop: street_stop,
      walk: walk,
      lift: lift,
      cross: cross,
      closure: closure
    }
  end

  # A station of the same shape whose published image files were never stored:
  # the resolver refuses the URL and the locator must fall back to the list.
  defp station_without_image(organization, version) do
    station =
      stop_fixture(organization.id, version.id, %{
        @station_stop
        | stop_id: "FLOORPLAN_NO_IMAGE",
          stop_name: "Floorplan No Image Station"
      })

    level =
      level_fixture(organization.id, version.id, %{
        level_id: "FP_NI_L1",
        level_name: "Concourse",
        level_index: 0.0
      })

    {:ok, _stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        stop_id: station.id,
        level_id: level.id,
        diagram_filename: "never_stored.png"
      })

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    calendar_fixture(organization.id, version.id, %{
      service_id: "CAL_NO_IMAGE",
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    child =
      stop_fixture(organization.id, version.id, %{
        stop_id: "FP_NI_CHILD",
        stop_name: "Unphotographed platform",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 30, "y" => 40}
      })

    pathway_fixture(organization.id, version.id, child.stop_id, station.stop_id, %{
      pathway_id: "FP/PW NI",
      pathway_mode: 1,
      is_bidirectional: true
    })

    station
  end

  # A station whose level has no diagram filename at all: the same fallback,
  # reached through the other branch of the resolver.
  defp station_without_level_diagram(organization, version) do
    station =
      stop_fixture(organization.id, version.id, %{
        @station_stop
        | stop_id: "FLOORPLAN_NO_DIAGRAM",
          stop_name: "Floorplan No Diagram Station"
      })

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    calendar_fixture(organization.id, version.id, %{
      service_id: "CAL_NO_DIAGRAM",
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    child =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "FP_ND_CHILD",
        stop_name: "Unphotographed concourse",
        location_type: 0
      })

    pathway_fixture(organization.id, version.id, child.stop_id, station.stop_id, %{
      pathway_id: "FP/PW ND",
      pathway_mode: 1,
      is_bidirectional: true
    })

    station
  end

  # The first value of one attribute on the first element the selector matches.
  defp attribute(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  # The island's server-owned contract: its stable id, the hook that owns it,
  # and every stored value the overlay draws.
  defp island(view, id \\ "closure-floorplan") do
    html = render(view)

    if is_nil(attribute(html, "##{id}", "phx-hook")) do
      flunk("no floorplan island ##{id} is rendered")
    end

    %{
      id: id,
      hook: attribute(html, "##{id}", "phx-hook"),
      update: attribute(html, "##{id}", "phx-update"),
      image_url: attribute(html, "##{id}", "data-image-url"),
      image_alt: attribute(html, "##{id}", "data-image-alt"),
      stops: Jason.decode!(attribute(html, "##{id}", "data-stops")),
      pathways: Jason.decode!(attribute(html, "##{id}", "data-pathways")),
      selected_id: attribute(html, "##{id}", "data-selected-id"),
      closed_ids: Jason.decode!(attribute(html, "##{id}", "data-closed-ids")),
      select_event: attribute(html, "##{id}", "data-select-event"),
      show_stop_names: attribute(html, "##{id}", "data-show-stop-names"),
      note_id: attribute(html, "##{id}", "data-note-id"),
      list_id: attribute(html, "##{id}", "data-list-id")
    }
  end

  defp pathway(%{pathways: pathways}, pathway_id),
    do: Enum.find(pathways, &(&1["pathway_id"] == pathway_id))

  defp stored_points(organization, version, station) do
    {:ok, snapshot} =
      Gtfs.get_station_report_snapshot(organization.id, version.id, station.stop_id)

    Map.new(snapshot.child_stops, &{&1.stop_id, &1.diagram_coordinate})
  end

  describe "the locator floorplan" do
    setup :editor_setup

    test "renders the selected level's stored coordinates as one ignored island",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, lift: lift, cross: cross} =
        station_with_floorplan(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      attributes = island(view)

      assert attributes.hook == "PathwayEvolutionsFloorplan"
      assert attributes.update == "ignore"
      assert attributes.select_event == "select_pathway"
      assert attributes.note_id == "closure-floorplan-missing"
      assert attributes.list_id == "closure-pathway-list"
      assert attributes.show_stop_names == "false"
      assert attributes.selected_id == ""
      assert attributes.closed_ids == []

      # The component adds the endpoint base to the path DiagramStorage returns.
      # The base follows the endpoint's configured port, which runtime.exs reads
      # from PORT, so the expectation takes it from Endpoint.url/0.
      expected_image_url =
        GtfsPlannerWeb.Endpoint.url() <>
          "/uploads/diagrams/#{organization.id}/#{version.id}/" <>
          "FLOORPLAN_STATION/floorplan_l1.png"

      assert attributes.image_url == expected_image_url
      assert has_element?(view, "#closure-floorplan-image[src='#{attributes.image_url}']")

      # Every plotted stop of the Concourse with its stored coordinate. Street
      # belongs to the other level, so it is not on this floorplan at all.
      assert attributes.stops == [
               %{
                 "stop_id" => "FP_ENTRANCE",
                 "name" => "North entrance",
                 "type" => 2,
                 "x" => 20.0,
                 "y" => 15.0
               },
               %{
                 "stop_id" => "FP_MEZZANINE",
                 "name" => "Mezzanine hall",
                 "type" => 0,
                 "x" => 50.0,
                 "y" => 30.0
               },
               %{
                 "stop_id" => "FP_PLATFORM",
                 "name" => "Platform 1",
                 "type" => 0,
                 "x" => 78.0,
                 "y" => 55.0
               }
             ]

      # List order (mode group, then pathway_id): the cross-level elevator, the
      # lift, then the walkway. The cross-level pathway keeps exactly one plotted
      # endpoint, which is what the overlay draws as a marker.
      assert Enum.map(attributes.pathways, & &1["pathway_id"]) == [
               "FP/PW CROSS",
               "FP/PW LIFT",
               "FP/PW WALK"
             ]

      cross_attributes = pathway(attributes, cross.pathway_id)

      assert cross_attributes["from"] == %{
               "stop_id" => "FP_PLATFORM",
               "name" => "Platform 1",
               "type" => 0,
               "x" => 78.0,
               "y" => 55.0
             }

      assert cross_attributes["to"] == nil

      lift_attributes = pathway(attributes, lift.pathway_id)
      assert lift_attributes["from"]["stop_id"] == "FP_MEZZANINE"
      assert lift_attributes["from"]["x"] == 50.0
      assert lift_attributes["to"]["stop_id"] == "FP_PLATFORM"
      assert lift_attributes["to"]["y"] == 55.0
      assert lift_attributes["closures"] == 1
      assert lift_attributes["label"] == "Elevator · Mezzanine hall ↔ Platform 1"
      assert lift_attributes["id"] == lift.id

      assert pathway(attributes, "FP/PW WALK")["closures"] == 0

      assert has_element?(view, "#closure-floorplan-level-label", "Concourse")
      assert has_element?(view, "#closure-floorplan-legend", "Has closures")
      assert has_element?(view, "#closure-floorplan-caption")
      refute render(view) =~ "DiagramCanvas"
    end

    test "offers Floorplan and List and keeps the list reachable below md",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_floorplan(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      assert has_element?(view, "#locator-view-diagram[aria-pressed='true']", "Floorplan")
      assert has_element?(view, "#locator-view-list[aria-pressed='false']", "List")
      assert has_element?(view, "#closure-floorplan-panel")
      assert attribute(render(view), "#closure-floorplan-panel", "class") =~ "max-md:hidden"
      assert attribute(render(view), "#closure-pathway-list", "class") =~ "md:hidden"

      assert Enum.count(
               LazyHTML.query(
                 LazyHTML.from_fragment(render(view)),
                 "#closure-pathway-list button"
               )
             ) == 3

      # Choosing List keeps the same pathways and removes the panel entirely,
      # so the list is the only locator at every width.
      view |> element("#locator-view-list") |> render_click()

      refute has_element?(view, "#closure-floorplan-panel")
      refute has_element?(view, "#closure-floorplan")
      refute attribute(render(view), "#closure-pathway-list", "class") =~ "md:hidden"
      assert has_element?(view, "#locator-view-list[aria-pressed='true']")
      assert has_element?(view, "#locator-view-diagram[aria-pressed='false']")

      assert Enum.count(
               LazyHTML.query(
                 LazyHTML.from_fragment(render(view)),
                 "#closure-pathway-list button"
               )
             ) == 3

      # Choosing Floorplan restores the panel and the md+ list toggle.
      view |> element("#locator-view-diagram") |> render_click()

      assert has_element?(view, "#closure-floorplan")
      assert attribute(render(view), "#closure-pathway-list", "class") =~ "md:hidden"
    end

    test "lays the plan out on the card's inset with a Level switch and a titled Key",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_floorplan(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      html = render(view)
      panel_class = attribute(html, "#closure-floorplan-panel", "class")

      # The level line, the plan, the caption and the Key share the card's
      # content inset instead of sitting flush against its edge.
      assert panel_class =~ "px-4"
      assert panel_class =~ "md:px-5"

      # More than one level: a labelled group with one underlined tab per level.
      assert has_element?(
               view,
               ~s(#closure-floorplan-levels[aria-label="Floorplan level"]),
               "Level"
             )

      assert attribute(html, "#closure-floorplan-level-FP_L1", "class") =~ "border-b-2"

      # The plan is drawn at reduced opacity on the canvas so the marks read.
      assert attribute(html, "#closure-floorplan-image", "class") =~ "opacity-[.62]"
      assert attribute(html, "#closure-floorplan-frame", "class") =~ "bg-canvas"

      # The Key is titled and names every mark, including the point kinds.
      assert has_element?(view, "#closure-floorplan-legend-title", "Key")

      for label <- [
            "Selected pathway",
            "Continues to another level",
            "Platform",
            "Entrance or exit",
            "Junction",
            "Boarding spot",
            "Has closures"
          ] do
        assert has_element?(view, "#closure-floorplan-legend li", label)
      end
    end

    test "switches levels from the station's own snapshot",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, street_stop: street_stop, lift: lift} =
        station_with_floorplan(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      assert has_element?(view, "#closure-floorplan-level-FP_L1[aria-pressed='true']")
      assert has_element?(view, "#closure-floorplan-level-FP_L2[aria-pressed='false']", "Street")

      view |> element("#closure-floorplan-level-FP_L2") |> render_click()

      attributes = island(view)

      assert has_element?(view, "#closure-floorplan-level-FP_L2[aria-pressed='true']")
      assert has_element?(view, "#closure-floorplan-level-label", "Street")
      assert attributes.image_url =~ "floorplan_l2.png"

      assert attributes.stops == [
               %{
                 "stop_id" => "FP_STREET",
                 "name" => "Street landing",
                 "type" => 0,
                 "x" => 45.0,
                 "y" => 55.0
               }
             ]

      # The same cross-level pathway now has its other endpoint plotted, and the
      # two same-level pathways are not on this floorplan at all.
      assert Enum.map(attributes.pathways, & &1["pathway_id"]) == ["FP/PW CROSS"]
      cross = pathway(attributes, "FP/PW CROSS")
      assert cross["from"] == nil
      assert cross["to"]["stop_id"] == street_stop.stop_id
      assert cross["to"]["x"] == 45.0
      refute pathway(attributes, lift.pathway_id)

      # A level of another scope is ignored rather than stored.
      render_hook(view, "select_floorplan_level", %{"level" => "FP_UNKNOWN"})

      assert has_element?(view, "#closure-floorplan-level-FP_L2[aria-pressed='true']")
    end

    test "selects the same pathway from the list and from the overlay event",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, walk: walk, lift: lift} = station_with_floorplan(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      # Opening a new closure from the pathway list marks that pathway.
      view |> element("#pathway-option-#{lift.id}") |> render_click()

      assert has_element?(view, "#closure-form")
      assert has_element?(view, "#closure-pathway option[value='FP/PW LIFT'][selected]")
      assert island(view).selected_id == lift.id
      assert has_element?(view, "#evolutions-status", "Scheduling a new closure.")

      # Closing the clean draft clears the selection on both surfaces.
      view |> element("#discard-closure") |> render_click()

      assert island(view).selected_id == ""
      refute has_element?(view, "#closure-pathway option[value='FP/PW LIFT'][selected]")

      # The overlay's own selection-only event is the same event the hook
      # pushes, and it preselects the same pathway in the editor.
      render_hook(view, "select_pathway", %{"id" => walk.id})

      assert island(view).selected_id == walk.id
      assert has_element?(view, "#closure-pathway option[value='FP/PW WALK'][selected]")
      assert has_element?(view, "#evolutions-status", "Scheduling a new closure.")

      # A UUID outside this station is ignored, exactly as the list ignores it.
      render_hook(view, "select_pathway", %{"id" => Ecto.UUID.generate()})

      assert island(view).selected_id == walk.id
    end

    test "never writes geometry while a floorplan interaction selects a pathway",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, lift: lift} = station_with_floorplan(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      before_points = stored_points(organization, version, station)
      assert before_points["FP_MEZZANINE"] == %{"x" => 50, "y" => 30}

      view |> element("#locator-view-list") |> render_click()
      view |> element("#locator-view-diagram") |> render_click()
      view |> element("#closure-floorplan-level-FP_L2") |> render_click()
      view |> element("#closure-floorplan-level-FP_L1") |> render_click()
      render_hook(view, "select_pathway", %{"id" => lift.id})

      assert has_element?(view, "#closure-form")
      assert stored_points(organization, version, station) == before_points

      # The island itself names no geometry event: only the hook and the ignored
      # update travel from the server; selection is an event the client sends.
      phx_attributes =
        render(view)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#closure-floorplan")
        |> LazyHTML.attributes()
        |> List.first()
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&String.starts_with?(&1, "phx-"))
        |> Enum.sort()

      assert phx_attributes == ["phx-hook", "phx-update"]
    end

    test "falls back to the list with an explicit note when no image can be shown",
         %{conn: conn, user: user, organization: organization, version: version} do
      no_image = station_without_image(organization, version)
      no_diagram = station_without_level_diagram(organization, version)

      conn = log_in_user(conn, user, organization: organization)

      for station <- [no_image, no_diagram] do
        {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

        assert has_element?(view, "#closure-floorplan-missing", "No floorplan image is available")
        refute has_element?(view, "#closure-floorplan")
        refute has_element?(view, "#locator-toggle")

        # The list is the locator in this state, at every width.
        assert has_element?(view, "#closure-pathway-list button")
        refute attribute(render(view), "#closure-pathway-list", "class") =~ "md:hidden"
      end
    end
  end

  describe "the access preview floorplan" do
    setup :editor_setup

    test "draws the moment's closed set and names every closed pathway in text",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, lift: lift, closure: closure} =
        station_with_floorplan(organization, version)

      conn = log_in_user(conn, user, organization: organization)

      # Tuesday 2026-03-10, 12:00 service time: the lift's 09:00-15:00 window is
      # active, the stairs' overnight window is not.
      {:ok, view, _html} =
        live(conn, access_path(version, station.stop_id, "2026-03-10", "12:00:00"))

      render_async(view, 5_000)

      assert has_element?(view, "#preview-floorplan")
      assert has_element?(view, "#preview-floorplan-title", "Station at 12:00")
      assert has_element?(view, "#preview-floorplan-badge", "1 pathway closed")
      assert has_element?(view, "#preview-floorplan-closed", "FP/PW LIFT")

      assert has_element?(
               view,
               "#preview-floorplan-closed",
               "Elevator · Mezzanine hall ↔ Platform 1"
             )

      assert has_element?(view, "#preview-floorplan-closed", "dashed line")
      assert has_element?(view, "#preview-floorplan-missing[hidden]")

      attributes = island(view, "preview-floorplan-canvas")

      assert attributes.hook == "PathwayEvolutionsFloorplan"
      assert attributes.update == "ignore"
      assert attributes.select_event == ""
      assert attributes.selected_id == ""
      assert attributes.show_stop_names == "true"
      assert attributes.closed_ids == [lift.pathway_id]
      assert attributes.image_url =~ "floorplan_l1.png"

      # The closed pathway's cause row is addressable by its exact natural ID.
      assert has_element?(
               view,
               "#preview-cause-#{closure.id}[data-cause-pathway='FP/PW LIFT']"
             )

      assert has_element?(view, "#preview-floorplan-legend", "Closed")
      assert has_element?(view, "#preview-floorplan-legend-title", "Key")

      # Badges are 4px, never pills, and the counts read in words.
      assert has_element?(view, "#preview-floorplan-badge[data-tone='error']", "1 pathway closed")
      refute has_element?(view, "#evolutions .rounded-full")
    end

    test "renders the missing note separately when the station has no floorplan image",
         %{conn: conn, user: user, organization: organization, version: version} do
      station = station_without_level_diagram(organization, version)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, access_path(version, station.stop_id, "2026-03-10", "12:00:00"))

      render_async(view, 5_000)

      assert has_element?(view, "#preview-floorplan-missing", "No floorplan image is available")
      refute has_element?(view, "#preview-floorplan")
      refute has_element?(view, "#preview-floorplan-canvas")
    end
  end
end
