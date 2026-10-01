defmodule GtfsPlannerWeb.Gtfs.StationDiagramLivePanelTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  # The workspace's docked panel and toolbar: what the level's points and
  # pathways look like as lists, how the panel narrows them, and what the
  # toolbar says about a level.
  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PANEL_STATION",
        stop_name: "Panel Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "PANEL_L1",
        level_name: "Concourse",
        level_index: 0.0
      })

    empty_level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "PANEL_L2",
        level_name: "Platform",
        level_index: -1.0
      })

    {:ok, stop_level} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
      })

    {:ok, _} = put_stop_level_diagram(stop_level, "panel.png")

    {:ok, _} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: empty_level.id
      })

    north =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "panel_north_hall",
        stop_name: "North hall",
        location_type: 3,
        wheelchair_boarding: 1,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 20.0, "y" => 20.0}
      })

    stairs =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "panel_west_stair",
        stop_name: "West stair top",
        location_type: 3,
        wheelchair_boarding: 2,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 60.0, "y" => 40.0}
      })

    pathway =
      pathway_fixture(organization.id, gtfs_version.id, north.stop_id, stairs.stop_id, %{
        pathway_id: "PANEL_PW_1",
        pathway_mode: 2,
        is_bidirectional: false,
        traversal_time: 52
      })

    conn = log_in_user(conn, user, organization: organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

    %{view: view, north: north, stairs: stairs, pathway: pathway, empty_level: empty_level}
  end

  describe "tabs" do
    test "open on Points with the count on each tab", %{view: view} do
      assert has_element?(view, "#panel-tab-points[aria-selected='true']", "2")
      assert has_element?(view, "#panel-tab-pathways[aria-selected='false']", "1")
      assert has_element?(view, "#points-panel:not([hidden])")
      assert has_element?(view, "#pathways-panel[hidden]")
    end

    test "Pathways swaps the visible list", %{view: view} do
      view |> element("#panel-tab-pathways") |> render_click()

      assert has_element?(view, "#panel-tab-pathways[aria-selected='true']")
      assert has_element?(view, "#pathways-panel:not([hidden])")
      assert has_element?(view, "#points-panel[hidden]")
    end

    test "choosing Points or Pathways closes the journal", %{view: view} do
      render_async(view, 5_000)
      view |> element("#journal-trigger") |> render_click()
      render_async(view, 5_000)
      assert has_element?(view, "#journal-trigger[aria-selected='true']")
      assert has_element?(view, "#lists-section[hidden]")

      view |> element("#panel-tab-pathways") |> render_click()

      refute has_element?(view, "#station-journal-panel")
      assert has_element?(view, "#panel-tab-pathways[aria-selected='true']")
    end

    test "an unknown tab leaves the panel as it was", %{view: view} do
      render_hook(view, "select_panel_tab", %{"tab" => "elsewhere"})

      assert has_element?(view, "#panel-tab-points[aria-selected='true']")
    end
  end

  describe "point rows" do
    test "name the type and ID, and flag only points that are not accessible", %{
      view: view,
      north: north,
      stairs: stairs
    } do
      assert has_element?(view, "#child-stop-row-#{north.id}", "North hall")
      assert has_element?(view, "#child-stop-row-#{north.id}", "Junction")
      assert has_element?(view, "#child-stop-row-#{north.id}", "panel_north_hall")
      refute has_element?(view, "#child-stop-row-#{north.id}", "Not accessible")

      assert has_element?(view, "#child-stop-row-#{stairs.id}", "Not accessible")
    end

    test "open the point's editor", %{view: view, north: north} do
      view
      |> element("#child-stop-row-#{north.id} button[phx-click='edit_child_stop']")
      |> render_click()

      assert has_element?(view, "#child-stop-drawer-overlay[data-open='true']")
      assert has_element?(view, "#child-stop-form")
    end
  end

  describe "pathway rows" do
    test "read as the two ends, the mode, direction, time and ID", %{
      view: view,
      pathway: pathway
    } do
      row = "#pathway-row-#{pathway.id}"

      assert has_element?(view, row, "North hall → West stair top")
      assert has_element?(view, row, "Stairs")
      assert has_element?(view, row, "one way")
      assert has_element?(view, row, "52 s")
      assert has_element?(view, row, "PANEL_PW_1")
    end
  end

  describe "search" do
    test "narrows the point list as the mapper types", %{view: view, north: north, stairs: stairs} do
      view |> form("#stop-search-form", %{"stop_id_query" => "stair"}) |> render_change()

      assert has_element?(view, "#child-stop-row-#{stairs.id}")
      refute has_element?(view, "#child-stop-row-#{north.id}")
    end

    test "says when nothing matches and offers a way back", %{view: view, north: north} do
      view |> form("#stop-search-form", %{"stop_id_query" => "zzz"}) |> render_change()

      assert has_element?(view, "#points-panel", "No points match")
      refute has_element?(view, "#child-stop-row-#{north.id}")

      view |> element("#points-panel button", "Clear search") |> render_click()

      assert has_element?(view, "#child-stop-row-#{north.id}")
    end

    test "narrows the pathway list by its ends", %{view: view, pathway: pathway} do
      view |> element("#panel-tab-pathways") |> render_click()

      view |> form("#pathway-search-form", %{"list_query" => "nobody"}) |> render_change()
      refute has_element?(view, "#pathway-row-#{pathway.id}")

      view |> form("#pathway-search-form", %{"list_query" => "west stair"}) |> render_change()
      assert has_element?(view, "#pathway-row-#{pathway.id}")
    end

    test "leaves the plan and the lists alone when the query is empty", %{
      view: view,
      north: north
    } do
      view |> form("#stop-search-form", %{"stop_id_query" => "   "}) |> render_change()

      assert has_element?(view, "#child-stop-row-#{north.id}")
    end
  end

  describe "modes" do
    test "Add point offers the keyboard route beside the plan", %{view: view} do
      render_hook(view, "switch_mode", %{"mode" => "add"})

      assert has_element?(view, "#add-point-card", "Add a point")
      assert has_element?(view, "#add-point-card #keyboard-create-stop", "Enter coordinates")
      assert has_element?(view, "#plan-hint", "Click the floorplan where the point belongs.")
    end

    test "Connect shows the two steps and the chosen start", %{view: view, north: north} do
      render_hook(view, "switch_mode", %{"mode" => "connect"})

      assert has_element?(view, "#connect-card", "Not chosen yet")
      assert has_element?(view, "#plan-hint", "Click the starting point.")

      render_hook(view, "stop_clicked", %{"id" => north.id})

      assert has_element?(view, "#connect-card", "North hall")
      assert has_element?(view, "#connect-card button", "Clear")
      assert has_element?(view, "#plan-hint", "Click the destination.")
    end

    test "Align has no side panel", %{view: view} do
      render_hook(view, "switch_mode", %{"mode" => "map"})

      refute has_element?(view, "#side-panel")
      assert has_element?(view, "#map-canvas-wrapper")
    end
  end

  describe "toolbar levels" do
    test "mark the current level and say when a level has no floorplan", %{
      view: view,
      empty_level: empty_level
    } do
      assert has_element?(view, "#level-control [aria-current='true']", "Concourse")
      refute has_element?(view, "#level-control [aria-current='true']", "No floorplan")
      assert has_element?(view, "#level-option-#{empty_level.id}", "No floorplan")
    end

    test "list the top floor first", %{view: view} do
      labels =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#level-control button")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))

      assert labels == ["Concourse", "Platform · No floorplan"]
    end

    test "a level without a floorplan says why placing points is unavailable", %{
      view: view,
      empty_level: empty_level
    } do
      view |> element("#level-option-#{empty_level.id}") |> render_click()

      assert has_element?(view, "#diagram-mode-reason", "need a floorplan on Platform")
      assert has_element?(view, "#diagram-mode input[value='add'][disabled]")
      assert has_element?(view, "#empty-diagram-state", "No floorplan for Platform")
    end
  end
end
