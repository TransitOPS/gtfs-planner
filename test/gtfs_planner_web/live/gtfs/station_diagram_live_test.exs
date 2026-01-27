defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

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
        |> element("#child-stop-list-#{child_stop.id}")
        |> render_click()

      # Assert drawer opened with populated form fields
      assert result =~ "Child Stop 1"
      assert result =~ "CHILD_STOP_1"

      # Verify form has correct values in input fields
      assert result =~ ~r/value=\"CHILD_STOP_1\"/
      assert result =~ ~r/value=\"Child Stop 1\"/
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
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level_id=#{level1.id}", on_error: :warn)

      # Switch to connect mode
      view
      |> element("button[phx-click=\"switch_mode\"][phx-value-mode=\"connect\"]")
      |> render_click()

      # Click first stop on level 1
      view
      |> element("#child_stops-#{child_stop1.id}-circle")
      |> render_click()

      # Switch to level 2
      view
      |> element("form[phx-change=\"switch_level\"]")
      |> render_change(%{"level_id" => level2.id})

      # Click second stop on level 2
      view
      |> element("#child_stops-#{child_stop2.id}-circle")
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
  end
end
