defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Repo

  describe "StationDiagramLive - child stop editing" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      # Create a parent station
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_1",
          stop_name: "Test Station",
          location_type: 1
        })

      # Create a level for station
      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Level 1",
          level_index: 0.0
        })

      # Associate level with station
      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level
      }
    end

    test "clicking child stop list item opens edit drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      # Create a child stop with diagram coordinates
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_STOP_1",
          stop_name: "Child Stop 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 75.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      # Click on child stop list item
      result =
        view
        |> element("#child-stop-row-#{child_stop.id} button[phx-click='edit_child_stop']")
        |> render_click()

      # Assert drawer opened with populated form fields
      assert result =~ "Child Stop 1"
      assert result =~ "CHILD_STOP_1"

      # Verify form has correct values in input fields
      assert result =~ ~r/value=\"CHILD_STOP_1\"/
      assert result =~ ~r/value=\"Child Stop 1\"/
    end

    test "new child stop drawer locks level to active level with hidden field", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "add"})

      render_hook(view, "canvas_click", %{"x" => "12", "y" => "24"})

      assert has_element?(
               view,
               "#child-stop-form input[type='hidden'][name='level_id'][value='#{level.level_id}']"
             )

      assert has_element?(view, "#child-stop-form", "Level 1 (0)")
      refute has_element?(view, "#child-stop-form button[phx-click='toggle_level_edit']")
    end

    test "add mode click near existing stop keeps create drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_NEARBY",
          stop_name: "Nearby Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 30.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "add"})
      render_hook(view, "canvas_click", %{"x" => "21", "y" => "31"})

      assert has_element?(view, "#child-stop-form button[type='submit']", "Create Stop")
      refute has_element?(view, "#child-stop-form input[name='stop_id'][readonly]")
      refute has_element?(view, "#child-stop-form button[phx-click='delete_child_stop']")
    end

    test "editing child stop shows change link and toggles level selector", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_TOGGLE_1",
          stop_name: "Child Toggle 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 15.0, "y" => 25.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='edit_child_stop']")
      |> render_click()

      assert has_element?(view, "#child-stop-form button[phx-click='toggle_level_edit']")
      refute has_element?(view, "#child-stop-form select[name='level_id']")

      view
      |> element("#child-stop-form button[phx-click='toggle_level_edit']")
      |> render_click()

      assert has_element?(view, "#child-stop-form select[name='level_id']")

      view
      |> element("#child-stop-form button[phx-click='close_drawer']")
      |> render_click()

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='edit_child_stop']")
      |> render_click()

      refute has_element?(view, "#child-stop-form select[name='level_id']")
    end

    test "editing stop preserves nil wheelchair boarding when unchanged", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_WHEELCHAIR_NIL",
          stop_name: "Child Wheelchair Nil",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          wheelchair_boarding: nil,
          diagram_coordinate: %{"x" => 35.0, "y" => 45.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='edit_child_stop']")
      |> render_click()

      assert has_element?(
               view,
               "#child-stop-form select[name='wheelchair_boarding'] option[value=''][selected]"
             )

      view
      |> form("#child-stop-form", %{
        "stop_id" => child_stop.stop_id,
        "stop_name" => child_stop.stop_name,
        "location_type" => Integer.to_string(child_stop.location_type),
        "level_id" => level.level_id,
        "wheelchair_boarding" => "",
        "platform_code" => ""
      })
      |> render_submit()

      updated_stop = Gtfs.get_stop!(child_stop.id)
      assert is_nil(updated_stop.wheelchair_boarding)
    end

    test "view mode background click is a no-op", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "canvas_click", %{"x" => "20", "y" => "30"})

      refute has_element?(view, "#child-stop-form")
    end

    test "view mode stop dot click opens edit drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_VIEW_DOT",
          stop_name: "Child View Dot",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 30.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child_stops-#{child_stop.id}")
      |> render_click()

      assert has_element?(view, "#child-stop-form")
      assert render(view) =~ "Child View Dot"
    end

    test "add mode stop dot click does not open edit drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_ADD_DOT",
          stop_name: "Child Add Dot",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 30.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "add"})

      view
      |> element("#child_stops-#{child_stop.id}")
      |> render_click()

      refute has_element?(view, "#child-stop-form")
      refute has_element?(view, "#child-stop-form input[name='stop_id'][readonly]")
      refute has_element?(view, "#child-stop-form button[phx-click='delete_child_stop']")
    end

    test "view mode stop click opens edit drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_VIEW_CANVAS",
          stop_name: "Child View Canvas",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 22.0, "y" => 33.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "stop_clicked", %{"id" => child_stop.id})

      assert has_element?(view, "#child-stop-form")
      assert render(view) =~ child_stop.stop_id
    end

    test "add mode pathway click does not open pathway drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")

      child_stop_1 =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_PATH_1",
          stop_name: "Child Path 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 30.0}
        })

      child_stop_2 =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_PATH_2",
          stop_name: "Child Path 2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 40.0, "y" => 30.0}
        })

      pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          child_stop_1.stop_id,
          child_stop_2.stop_id
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("button[phx-click='switch_mode'][phx-value-mode='add']")
      |> render_click()

      assert has_element?(view, "#diagram-page[data-immersive='true']")

      view
      |> element("#pathways-#{pathway.id}")
      |> render_click()

      refute has_element?(view, "#pathway-form")
    end
  end

  describe "StationDiagramLive - cross-level pathway creation" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      # Create a parent station
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_1",
          stop_name: "Test Station",
          location_type: 1
        })

      # Create two levels
      level1 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Level 1",
          level_index: 0.0
        })

      level2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L2",
          level_name: "Level 2",
          level_index: 1.0
        })

      # Associate levels with station
      {:ok, _stop_level1} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level1.id,
          diagram_filename: "level1.png"
        })

      {:ok, _stop_level2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level2.id,
          diagram_filename: "level2.png"
        })

      # Create child stops on different levels
      child_stop1 =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_STOP_1",
          stop_name: "Child Stop 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level1.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      child_stop2 =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_STOP_2",
          stop_name: "Child Stop 2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level2.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level1: level1,
        level2: level2,
        child_stop1: child_stop1,
        child_stop2: child_stop2
      }
    end

    test "creates cross-level pathway when clicking stops on different levels", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level1: level1,
      level2: level2,
      child_stop1: child_stop1,
      child_stop2: child_stop2
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level_id=#{level1.id}",
          on_error: :warn
        )

      # Switch to connect mode
      view
      |> element("button[phx-click=\"switch_mode\"][phx-value-mode=\"connect\"]")
      |> render_click()

      # Click first stop on level 1
      view
      |> element("#child_stops-#{child_stop1.id}")
      |> render_click()

      # Switch to level 2
      view
      |> element("form[phx-change=\"switch_level\"]")
      |> render_change(%{"level_id" => level2.id})

      # Click second stop on level 2
      view
      |> element("#child_stops-#{child_stop2.id}")
      |> render_click()

      # Assert pathway was created
      pathways = Gtfs.list_pathways_for_station(organization.id, gtfs_version.id, station.id)
      assert length(pathways) == 1

      pathway = hd(pathways)
      assert pathway.from_stop_id == child_stop1.stop_id
      assert pathway.to_stop_id == child_stop2.stop_id

      # Assert selected_from_stop is cleared by checking view state
      # The view should not show "From: ..." message anymore
      html = render(view)
      refute html =~ "From: Child Stop 1"
    end
  end

  describe "StationDiagramLive - action strip and UI elements" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      # Create a parent station
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_1",
          stop_name: "Test Station",
          location_type: 1
        })

      # Create a level for the station
      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Level 1",
          level_index: 0.0
        })

      # Associate level with station
      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level,
        stop_level: stop_level
      }
    end

    test "action strip has sticky positioning when diagram exists", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      # Add a diagram to the stop_level
      {:ok, _updated_stop_level} =
        Gtfs.update_stop_level_diagram(stop_level, "test_diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      html = render(view)

      # Assert the action strip contains sticky positioning classes
      assert html =~ "sticky top-0 z-10"
      assert html =~ "bg-blue-50"
    end

    test "upload button shows 'Upload Diagram' when no diagram exists", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      html = render(view)

      # Assert the upload button shows "Upload Diagram" when no diagram exists
      assert html =~ "Upload Diagram"
      refute html =~ "Replace diagram"
    end

    test "upload button shows 'Replace diagram' when diagram exists", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      # Add a diagram to the stop_level
      {:ok, _updated_stop_level} =
        Gtfs.update_stop_level_diagram(stop_level, "test_diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      html = render(view)

      # Assert the upload button shows "Replace diagram" when diagram exists
      assert html =~ "Replace diagram"
    end

    test "mode toggle has view first, highlights view by default, and keeps view enabled", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, ".join button:nth-child(1)[phx-value-mode='view']", "View")
      assert has_element?(view, ".join button:nth-child(2)[phx-value-mode='add']", "Add Stop")
      assert has_element?(view, ".join button:nth-child(3)[phx-value-mode='connect']", "Connect")
      assert has_element?(view, "button[phx-value-mode='view']:not([disabled]).bg-blue-600")
    end

    test "view mode shows contextual text and default cursor with diagram", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "span", "Click a stop to view or edit")
      assert has_element?(view, "svg.cursor-default")

      view
      |> element("button[phx-click='switch_mode'][phx-value-mode='add']")
      |> render_click()

      assert has_element?(view, "svg.cursor-crosshair")
    end

    test "immersive data attribute toggles by mode", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#diagram-page:not([data-immersive])")

      view
      |> element("button[phx-click='switch_mode'][phx-value-mode='add']")
      |> render_click()

      assert has_element?(view, "#diagram-page[data-immersive='true']")

      view
      |> element("button[phx-click='switch_mode'][phx-value-mode='connect']")
      |> render_click()

      assert has_element?(view, "#diagram-page[data-immersive='true']")

      view
      |> element("button[phx-click='switch_mode'][phx-value-mode='view']")
      |> render_click()

      assert has_element?(view, "#diagram-page:not([data-immersive])")
    end

    test "renders diagram canvas wrapper id", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#diagram-canvas-wrapper")
    end
  end

  describe "StationDiagramLive - diagram replacement and level isolation" do
    setup do
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
          stop_id: "STATION_1",
          stop_name: "Test Station",
          location_type: 1
        })

      level1 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Level 1",
          level_index: 0.0
        })

      level2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L2",
          level_name: "Level 2",
          level_index: 1.0
        })

      {:ok, _stop_level1} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level1.id
        })

      {:ok, _stop_level2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level2.id
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level1: level1,
        level2: level2
      }
    end

    test "replacing a diagram updates rendered image URL in the same LiveView session", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level1: level1
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      upload_diagram(view, "floorplan.png", "first image payload")

      first_stop_level =
        Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level1.id)

      first_filename = first_stop_level.diagram_filename
      first_href_fragment = "#{first_filename}?v=#{first_filename}"

      assert has_element?(view, "image[href*='#{first_href_fragment}']")

      upload_diagram(view, "floorplan.png", "second image payload")

      second_stop_level =
        Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level1.id)

      second_filename = second_stop_level.diagram_filename
      second_href_fragment = "#{second_filename}?v=#{second_filename}"

      assert second_filename != first_filename
      assert has_element?(view, "image[href*='#{second_href_fragment}']")
      refute has_element?(view, "image[href*='#{first_href_fragment}']")
    end

    test "same client filename uploads persist distinct diagram filenames per level", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level1: level1,
      level2: level2
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      upload_diagram(view, "floorplan.png", "level 1 payload")

      view
      |> element("form[phx-change='switch_level']")
      |> render_change(%{"level_id" => level2.id})

      upload_diagram(view, "floorplan.png", "level 2 payload")

      level1_stop_level =
        Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level1.id)

      level2_stop_level =
        Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level2.id)

      assert level1_stop_level.diagram_filename != level2_stop_level.diagram_filename
    end

    test "replacing level A diagram does not change level B rendered or persisted filename", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level1: level1,
      level2: level2
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      upload_diagram(view, "floorplan.png", "level a initial payload")
      level1_before = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level1.id)

      view
      |> element("form[phx-change='switch_level']")
      |> render_change(%{"level_id" => level2.id})

      upload_diagram(view, "floorplan.png", "level b payload")
      level2_before = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level2.id)

      view
      |> element("form[phx-change='switch_level']")
      |> render_change(%{"level_id" => level1.id})

      upload_diagram(view, "floorplan.png", "level a replacement payload")

      level1_after = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level1.id)
      level2_after = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level2.id)

      assert level1_after.diagram_filename != level1_before.diagram_filename
      assert level2_after.diagram_filename == level2_before.diagram_filename

      view
      |> element("form[phx-change='switch_level']")
      |> render_change(%{"level_id" => level2.id})

      level2_href_fragment = "#{level2_after.diagram_filename}?v=#{level2_after.diagram_filename}"
      assert has_element?(view, "image[href*='#{level2_href_fragment}']")
    end

    test "diagram upload auto-creates stop_level when level is associated via child stops only",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level1: level1
         } do
      # Delete the pre-created stop_level so the level is only associated via child stops
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level1.id)
      Repo.delete!(stop_level)

      # Create a child stop that references level1 via level_id
      _child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_NO_SL",
          stop_name: "Child No StopLevel",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level1.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 20.0}
        })

      # Verify no stop_level exists yet
      assert is_nil(Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level1.id))

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      # Upload a diagram — this should auto-create the stop_level
      upload_diagram(view, "floorplan.png", "auto-create payload")

      # Verify stop_level was created and diagram was saved
      created_stop_level =
        Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level1.id)

      assert created_stop_level != nil
      assert created_stop_level.diagram_filename != nil
    end
  end

  describe "StationDiagramLive - level switching validation" do
    setup do
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
          stop_id: "STATION_SWITCH",
          stop_name: "Station Switch",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1_SWITCH",
          level_name: "Level 1",
          level_index: 0.0
        })

      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_SWITCH_1",
          stop_name: "Child Switch 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 15.0}
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level,
        child_stop: child_stop
      }
    end

    test "invalid level_id keeps active level data and shows explicit error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      child_stop: child_stop
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#child-stop-row-#{child_stop.id}")

      view
      |> element("form[phx-change='switch_level']")
      |> render_change(%{"level_id" => "not-a-real-level"})

      assert has_element?(view, "#child-stop-row-#{child_stop.id}")
      assert render(view) =~ "Invalid level selection"
    end

    test "missing level_id payload keeps current level data and shows explicit error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      child_stop: child_stop
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#child-stop-row-#{child_stop.id}")

      render_hook(view, "switch_level", %{})

      assert has_element?(view, "#child-stop-row-#{child_stop.id}")
      assert render(view) =~ "Malformed level selection request"
    end

    test "switching levels updates data-canvas-key on the SVG element", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      # Give level A a diagram
      stop_level_a =
        Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level_a, "level_a.png")

      # Create a second level with its own diagram
      level_b =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L2_SWITCH",
          level_name: "Level 2",
          level_index: 1.0
        })

      {:ok, stop_level_b} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_b.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level_b, "level_b.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      # Assert initial canvas key contains level A's id
      assert has_element?(view, "svg[data-canvas-key*=\"#{level.id}\"]")

      # Switch to level B
      view
      |> element("form[phx-change='switch_level']")
      |> render_change(%{"level_id" => level_b.id})

      # Assert canvas key now contains level B's id
      assert has_element?(view, "svg[data-canvas-key*=\"#{level_b.id}\"]")
      refute has_element?(view, "svg[data-canvas-key*=\"#{level.id}\"]")
    end

    test "station with no levels renders empty level state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_NO_LEVELS",
          stop_name: "Station No Levels",
          location_type: 1
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert render(view) =~ "No levels defined"
    end
  end

  describe "StationDiagramLive - stop marker rendering" do
    setup do
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
          stop_id: "STATION_MARKERS",
          stop_name: "Station Markers",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1_MARKERS",
          level_name: "Level 1",
          level_index: 0.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level
      }
    end

    test "renders marker shape per location type", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      platform_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLATFORM_0",
          stop_name: "Platform Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      entrance_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENTRANCE_2",
          stop_name: "Entrance Stop",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 20.0}
        })

      node_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NODE_3",
          stop_name: "Node Stop",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 30.0}
        })

      boarding_area_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BOARDING_4",
          stop_name: "Boarding Area Stop",
          location_type: 4,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 40.0, "y" => 40.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(
               view,
               "#child_stops-#{platform_stop.id} rect[data-stop-marker][data-location-type='0']"
             )

      assert has_element?(
               view,
               "#child_stops-#{entrance_stop.id} rect[data-stop-marker][data-location-type='2'][fill='#FFFFFF']"
             )

      assert has_element?(
               view,
               "#child_stops-#{node_stop.id} circle[data-stop-marker][data-location-type='3']"
             )

      assert has_element?(
               view,
               "#child_stops-#{boarding_area_stop.id} rect[data-stop-marker][data-location-type='4']"
             )
    end

    test "renders expected stop labels by location type", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      platform_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLATFORM_LABEL",
          stop_name: "Platform Label",
          location_type: 0,
          platform_code: "3A",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 15.0, "y" => 15.0}
        })

      platform_without_code =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLATFORM_NO_CODE",
          stop_name: "Platform No Code",
          location_type: 0,
          platform_code: nil,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 12.0, "y" => 12.0}
        })

      entrance_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENTRANCE_LABEL",
          stop_name: "Entrance Label",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 25.0, "y" => 25.0}
        })

      node_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NODE_LABEL",
          stop_name: "Node Label",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 35.0, "y" => 35.0}
        })

      boarding_without_code =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BOARDING_NO_CODE",
          stop_name: "Boarding No Code",
          location_type: 4,
          platform_code: nil,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 45.0, "y" => 45.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#child_stops-#{platform_stop.id} [data-stop-label]", "3A")
      refute has_element?(view, "#child_stops-#{platform_without_code.id} [data-stop-label]")
      assert has_element?(view, "#child_stops-#{entrance_stop.id} [data-stop-label]", "↙↗")
      refute has_element?(view, "#child_stops-#{node_stop.id} [data-stop-label]")
      refute has_element?(view, "#child_stops-#{boarding_without_code.id} [data-stop-label]")
    end
    end
  end

  defp upload_diagram(view, filename, content) do
    upload =
      file_input(view, "#diagram-upload-form", :diagram, [
        %{
          name: filename,
          content: content,
          type: "image/png"
        }
      ])

    render_upload(upload, filename)

    view
    |> form("#diagram-upload-form")
    |> render_submit()
  end
end
