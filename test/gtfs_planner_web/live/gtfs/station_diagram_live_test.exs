defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.ValidationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations

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

    test "clicking child stop without diagram coordinates shows flash error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_STOP_NO_COORD",
          stop_name: "Child Stop No Coord",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: nil
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='edit_child_stop']")
      |> render_click()

      assert has_element?(
               view,
               "#flash-error",
               ~s(Stop "CHILD_STOP_NO_COORD" has no diagram position)
             )

      refute has_element?(view, "#child-stop-drawer[open]")
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

    test "new child stop drawer renders latitude and longitude inputs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "add"})
      render_hook(view, "canvas_click", %{"x" => "12", "y" => "24"})

      assert has_element?(view, "#child-stop-form input[name='stop_lat'][type='number']")
      assert has_element?(view, "#child-stop-form input[name='stop_lon'][type='number']")
      assert has_element?(view, "#child-stop-form input[name='stop_lat'][min='-90'][max='90']")
      assert has_element?(view, "#child-stop-form input[name='stop_lon'][min='-180'][max='180']")
    end

    test "creating a child stop persists latitude and longitude", %{
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
      render_hook(view, "canvas_click", %{"x" => "30", "y" => "40"})

      view
      |> element("#child-stop-form button[phx-click='toggle_stop_id_mode']")
      |> render_click()

      view
      |> form("#child-stop-form", %{
        "stop_id" => "child_lat_lon_create",
        "stop_name" => "Child Lat Lon Create",
        "location_type" => "3",
        "level_id" => level.level_id,
        "wheelchair_boarding" => "",
        "stop_lat" => "40.7128",
        "stop_lon" => "-74.0060"
      })
      |> render_submit()

      created_stop =
        Gtfs.list_child_stops_for_parent(organization.id, gtfs_version.id, station.id)
        |> Enum.find(&(&1.stop_name == "Child Lat Lon Create"))

      assert created_stop
      assert Decimal.equal?(created_stop.stop_lat, Decimal.new("40.7128"))
      assert Decimal.equal?(created_stop.stop_lon, Decimal.new("-74.0060"))
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

    test "editing child stop pre-populates and updates latitude and longitude", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_LAT_LON_EDIT",
          stop_name: "Child Lat Lon Edit",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          stop_lat: Decimal.new("40.7128"),
          stop_lon: Decimal.new("-74.0060"),
          diagram_coordinate: %{"x" => 45.0, "y" => 55.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='edit_child_stop']")
      |> render_click()

      assert has_element?(view, "#child-stop-form input[name='stop_lat'][value='40.7128']")
      assert has_element?(view, "#child-stop-form input[name='stop_lon'][value='-74.0060']")

      view
      |> form("#child-stop-form", %{
        "stop_id" => child_stop.stop_id,
        "stop_name" => child_stop.stop_name,
        "location_type" => Integer.to_string(child_stop.location_type),
        "level_id" => level.level_id,
        "wheelchair_boarding" => "",
        "stop_lat" => "40.730610",
        "stop_lon" => "-73.935242"
      })
      |> render_submit()

      updated_stop = Gtfs.get_stop!(child_stop.id)
      assert Decimal.equal?(updated_stop.stop_lat, Decimal.new("40.730610"))
      assert Decimal.equal?(updated_stop.stop_lon, Decimal.new("-73.935242"))
    end

    test "out-of-range latitude keeps child stop form open with validation error", %{
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
      render_hook(view, "canvas_click", %{"x" => "60", "y" => "70"})

      view
      |> element("#child-stop-form button[phx-click='toggle_stop_id_mode']")
      |> render_click()

      view
      |> form("#child-stop-form", %{
        "stop_id" => "child_lat_invalid",
        "stop_name" => "Child Lat Invalid",
        "location_type" => "3",
        "level_id" => level.level_id,
        "wheelchair_boarding" => "",
        "stop_lat" => "91",
        "stop_lon" => "-74.0060"
      })
      |> render_submit()

      assert has_element?(view, "#child-stop-form")
      assert has_element?(view, "#child-stop-form", "90")

      created_stops =
        Gtfs.list_child_stops_for_parent(organization.id, gtfs_version.id, station.id)

      refute Enum.any?(created_stops, &(&1.stop_name == "Child Lat Invalid"))
    end

    test "editing child stop with blank stop_id auto-generates kebab ID", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OLD_MANUAL_ID",
          stop_name: "Mezzanine West",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 30.0}
        })

      other_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "other-stop",
          stop_name: "Other Stop",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 40.0, "y" => 30.0}
        })

      pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          child_stop.stop_id,
          other_stop.stop_id
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='edit_child_stop']")
      |> render_click()

      view
      |> form("#child-stop-form", %{
        "stop_id" => "",
        "stop_name" => "Mezzanine West",
        "location_type" => "3",
        "level_id" => level.level_id,
        "wheelchair_boarding" => ""
      })
      |> render_submit()

      refute has_element?(view, "#child-stop-form")

      updated_stop = Gtfs.get_stop!(child_stop.id)
      assert updated_stop.stop_id == "mezzanine-west-01"

      updated_pathway = Gtfs.get_pathway!(pathway.id)
      assert updated_pathway.from_stop_id == "mezzanine-west-01"
      assert updated_pathway.to_stop_id == "other-stop"
    end

    test "editing child stop with blank stop_id shows error when sequences exhausted", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      for n <- 1..99 do
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "exhaust-#{String.pad_leading(Integer.to_string(n), 2, "0")}"
        })
      end

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "WILL_EXHAUST",
          stop_name: "Exhaust",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='edit_child_stop']")
      |> render_click()

      view
      |> form("#child-stop-form", %{
        "stop_id" => "",
        "stop_name" => "Exhaust",
        "location_type" => "0",
        "level_id" => level.level_id,
        "wheelchair_boarding" => ""
      })
      |> render_submit()

      assert has_element?(view, "#child-stop-form")
      assert render(view) =~ "exhausted"

      unchanged_stop = Gtfs.get_stop!(child_stop.id)
      assert unchanged_stop.stop_id == "WILL_EXHAUST"
    end

    test "boarding area form shows parent platform options and no-platform info message", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLATFORM_PARENT_SELECT",
          stop_name: "Platform Parent Select",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 14.0, "y" => 22.0}
        })

      station_without_platforms =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_NO_PLATFORM_OPTIONS",
          stop_name: "Station No Platform Options",
          location_type: 1
        })

      level_without_platforms =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_NO_PLATFORM_OPTIONS",
          level_name: "No Platform Level",
          level_index: 1.0
        })

      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station_without_platforms.id,
          level_id: level_without_platforms.id
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "add"})
      render_hook(view, "canvas_click", %{"x" => "12", "y" => "24"})

      view
      |> form("#child-stop-form", %{
        "stop_name" => "Boarding Area Candidate",
        "location_type" => "4",
        "level_id" => level.level_id,
        "wheelchair_boarding" => ""
      })
      |> render_change()

      assert has_element?(view, "#child-stop-form select[name='parent_platform']")

      assert has_element?(
               view,
               "#child-stop-form select[name='parent_platform'] option[value='']",
               "— None (under station)"
             )

      assert has_element?(
               view,
               "#child-stop-form select[name='parent_platform'] option[value='#{platform.stop_id}']",
               "#{platform.stop_id} - #{platform.stop_name}"
             )

      {:ok, view_without_platforms, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station_without_platforms.stop_id}/diagram",
          on_error: :warn
        )

      render_hook(view_without_platforms, "switch_mode", %{"mode" => "add"})
      render_hook(view_without_platforms, "canvas_click", %{"x" => "14", "y" => "26"})

      view_without_platforms
      |> form("#child-stop-form", %{
        "stop_name" => "No Platform Boarding Area",
        "location_type" => "4",
        "level_id" => level_without_platforms.level_id,
        "wheelchair_boarding" => ""
      })
      |> render_change()

      refute has_element?(
               view_without_platforms,
               "#child-stop-form select[name='parent_platform']"
             )

      assert has_element?(
               view_without_platforms,
               "#parent-platform-info",
               "No platforms defined for this station yet."
             )
    end

    test "boarding area create and edit persist selected parent platform", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLATFORM_PARENT_SAVE",
          stop_name: "Platform Parent Save",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 16.0, "y" => 24.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "add"})
      render_hook(view, "canvas_click", %{"x" => "30", "y" => "42"})

      view
      |> element("#child-stop-form button[phx-click='toggle_stop_id_mode']")
      |> render_click()

      view
      |> form("#child-stop-form", %{
        "stop_id" => "BOARDING_PARENT_SAVE",
        "stop_name" => "Boarding Parent Save",
        "location_type" => "4",
        "level_id" => level.level_id,
        "wheelchair_boarding" => ""
      })
      |> render_change()

      view
      |> form("#child-stop-form", %{
        "stop_id" => "BOARDING_PARENT_SAVE",
        "stop_name" => "Boarding Parent Save",
        "location_type" => "4",
        "parent_platform" => platform.stop_id,
        "level_id" => level.level_id,
        "wheelchair_boarding" => ""
      })
      |> render_submit()

      boarding_area =
        Gtfs.list_child_stops_for_parent(organization.id, gtfs_version.id, station.id)
        |> Enum.find(&(&1.stop_id == "BOARDING_PARENT_SAVE"))

      assert boarding_area.parent_station == platform.stop_id

      view
      |> element("#child-stop-row-#{boarding_area.id} button[phx-click='edit_child_stop']")
      |> render_click()

      assert has_element?(
               view,
               "#child-stop-form select[name='parent_platform'] option[value='#{platform.stop_id}'][selected]"
             )
    end

    test "changing location type from boarding area clears parent platform and saves under station",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLATFORM_PARENT_CLEAR",
          stop_name: "Platform Parent Clear",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 24.0}
        })

      boarding_area =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BOARDING_PARENT_CLEAR",
          stop_name: "Boarding Parent Clear",
          location_type: 4,
          parent_station: platform.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 26.0, "y" => 34.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child-stop-row-#{boarding_area.id} button[phx-click='edit_child_stop']")
      |> render_click()

      assert has_element?(
               view,
               "#child-stop-form select[name='parent_platform'] option[value='#{platform.stop_id}'][selected]"
             )

      view
      |> form("#child-stop-form", %{
        "stop_id" => boarding_area.stop_id,
        "stop_name" => boarding_area.stop_name,
        "location_type" => "3",
        "parent_platform" => platform.stop_id,
        "level_id" => level.level_id,
        "wheelchair_boarding" => "",
        "platform_code" => ""
      })
      |> render_change()

      refute has_element?(view, "#child-stop-form select[name='parent_platform']")

      view
      |> form("#child-stop-form", %{
        "stop_id" => boarding_area.stop_id,
        "stop_name" => boarding_area.stop_name,
        "location_type" => "3",
        "level_id" => level.level_id,
        "wheelchair_boarding" => ""
      })
      |> render_submit()

      updated_stop = Gtfs.get_stop!(boarding_area.id)
      assert updated_stop.parent_station == station.stop_id
    end

    test "reposition allows boarding areas nested under platform", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLATFORM_REPOSITION_NESTED",
          stop_name: "Platform Reposition Nested",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 22.0, "y" => 30.0}
        })

      boarding_area =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "BOARDING_REPOSITION_NESTED",
          stop_name: "Boarding Reposition Nested",
          location_type: 4,
          parent_station: platform.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 28.0, "y" => 36.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "add"})
      render_hook(view, "canvas_click", %{"x" => "70", "y" => "80"})

      view
      |> element("#enter-reposition-mode")
      |> render_click()

      assert has_element?(view, "#positioned-stop-row-#{boarding_area.id}")

      view
      |> element("#positioned-stop-row-#{boarding_area.id} button[phx-click='reposition_stop']")
      |> render_click()

      refute render(view) =~ "Invalid stop selection"

      updated_stop = Gtfs.get_stop!(boarding_area.id)
      assert updated_stop.diagram_coordinate == %{"x" => 70.0, "y" => 80.0}
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

    test "renders pan and zoom hints when a diagram exists", %{
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

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert html =~ "Scroll to pan"
      assert html =~ "Show Key"
    end

    test "renders legend markup and keeps legend panel hidden by default", %{
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

      {:ok, view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert html =~ "diagram-legend-panel"
      assert html =~ "hidden"
      assert html =~ "Child Stops"
      assert html =~ "Pathways"
      assert has_element?(view, "#diagram-legend-panel.hidden")
    end

    test "stop renders a single hit-target rect that also triggers the tooltip", %{
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
          stop_id: "CHILD_UNIFIED_HIT",
          stop_name: "Child Unified Hit",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 22.0, "y" => 32.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      # Single hit rect carries both click wiring and tooltip trigger.
      assert has_element?(
               view,
               "#child_stops-#{child_stop.id} rect[data-stop-hit-target][data-tooltip-trigger][phx-click='stop_clicked']"
             )

      # The separate oversized tooltip-hit rect is gone.
      refute has_element?(view, "[data-stop-tooltip-hit]")
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
      |> element("#child_stops-#{child_stop.id} [data-stop-hit-target]")
      |> render_click()

      assert has_element?(view, "#child-stop-form")
      assert render(view) =~ "Child View Dot"
    end

    test "view mode stop click does not render pending marker shape", %{
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
          stop_id: "CHILD_VIEW_NO_PENDING",
          stop_name: "Child View No Pending",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 26.0, "y" => 36.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child_stops-#{child_stop.id} [data-stop-hit-target]")
      |> render_click()

      assert has_element?(view, "#child-stop-form")

      assert has_element?(
               view,
               "#child-stop-form input[name='stop_name'][value='Child View No Pending']"
             )

      refute has_element?(view, "#diagram-overlay polygon[fill='#f97316']")
    end

    test "view mode selected stop marker uses emerald and non-selected stays default", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")

      selected_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "SELECTED_EMERALD",
          stop_name: "Selected Emerald",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 18.0, "y" => 28.0}
        })

      other_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DEFAULT_BLUE",
          stop_name: "Default Blue",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 42.0, "y" => 52.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child_stops-#{selected_stop.id} [data-stop-hit-target]")
      |> render_click()

      assert has_element?(
               view,
               "#child_stops-#{selected_stop.id} [data-stop-marker][data-location-type='3'][fill='#FF4500']"
             )

      assert has_element?(
               view,
               "#child_stops-#{other_stop.id} [data-stop-marker][data-location-type='3'][fill='#0080FF']"
             )
    end

    test "view mode selected stop cross-level badge uses pathway cyan fill", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "diagram.png")

      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "VIEW_BADGE_L2",
          level_name: "View Badge Level 2",
          level_index: 1.0
        })

      {:ok, _stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id,
          diagram_filename: "view-badge-level-2.png"
        })

      selected_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VIEW_BADGE_L1",
          stop_name: "View Badge L1",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 22.0, "y" => 32.0}
        })

      level_2_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VIEW_BADGE_L2_STOP",
          stop_name: "View Badge L2 Stop",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 62.0, "y" => 72.0}
        })

      cross_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          selected_stop.stop_id,
          level_2_stop.stop_id,
          %{pathway_mode: 1, is_bidirectional: false}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child_stops-#{selected_stop.id} [data-stop-hit-target]")
      |> render_click()

      assert has_element?(
               view,
               "#child_stops-#{selected_stop.id} [data-cross-level-pathway-badge][data-pathway-id='#{cross_level_pathway.id}'] [data-cross-level-badge-elevator][fill='#FF00FF']"
             )
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
      |> element("#child_stops-#{child_stop.id} [data-stop-hit-target]")
      |> render_click()

      refute has_element?(view, "#child-stop-form")
      refute has_element?(view, "#child-stop-form input[name='stop_id'][readonly]")
      refute has_element?(view, "#child-stop-form button[phx-click='delete_child_stop']")
      refute has_element?(view, "#diagram-action-strip", "From:")
    end

    test "switching from add to connect keeps stop clicks available for connect selection", %{
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
          stop_id: "CHILD_CONNECT_AFTER_ADD",
          stop_name: "Child Connect After Add",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 24.0, "y" => 34.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("button[phx-click='switch_mode'][phx-value-mode='add']")
      |> render_click()

      render_hook(view, "switch_mode", %{"mode" => "connect"})

      view
      |> element("#child_stops-#{child_stop.id} [data-stop-hit-target]")
      |> render_click()

      assert has_element?(view, "#diagram-action-strip", "From: Child Connect After Add")
      refute has_element?(view, "#child-stop-form")
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

      refute has_element?(view, "#pathways-#{pathway.id}[phx-click='edit_pathway']")
      refute has_element?(view, "#pathway-form")
      refute has_element?(view, "#diagram-action-strip", "From:")
    end

    test "view mode pathway click opens pathway drawer", %{
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
          stop_id: "CHILD_VIEW_PATH_1",
          stop_name: "Child View Path 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 30.0}
        })

      child_stop_2 =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_VIEW_PATH_2",
          stop_name: "Child View Path 2",
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
      |> element("#pathways-#{pathway.id}")
      |> render_click()

      assert has_element?(view, "#pathway-form")
      assert render(view) =~ pathway.pathway_id
    end
  end

  describe "StationDiagramLive - edit_child_stop_id URL intent" do
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
          stop_id: "STATION_INTENT",
          stop_name: "Intent Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_INTENT",
          level_name: "Level Intent",
          level_index: 0.0
        })

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

    test "mounting with valid edit_child_stop_id opens the edit drawer and clears the param", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "INTENT_CHILD",
          stop_name: "Intent Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 40.0, "y" => 60.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?edit_child_stop_id=#{child_stop.id}", on_error: :warn)

      html = render(view)
      assert html =~ "Intent Child"
      assert html =~ ~r/value=\"INTENT_CHILD\"/
      assert html =~ ~r/value=\"Intent Child\"/

      assert_patch(view, base_path)
    end

    test "mounting with unknown edit_child_stop_id leaves drawer closed and shows not-found flash",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      conn = log_in_user(conn, user, organization: organization)

      base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?edit_child_stop_id=#{Ecto.UUID.generate()}", on_error: :warn)

      html = render(view)
      refute html =~ ~r/value=\"INTENT_CHILD\"/
      assert has_element?(view, "#flash-error", "Stop not found")
    end

    test "mounting with malformed edit_child_stop_id shows not-found flash", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?edit_child_stop_id=not-a-uuid", on_error: :warn)

      html = render(view)
      refute html =~ ~r/value=\"INTENT_CHILD\"/
      assert has_element?(view, "#flash-error", "Stop not found")
    end

    test "mounting with edit_child_stop_id from another station shows scope flash", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      other_station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_INTENT_STATION",
          stop_name: "Other Intent Station",
          location_type: 1
        })

      other_child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_INTENT_CHILD",
          stop_name: "Other Intent Child",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 12.0, "y" => 24.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?edit_child_stop_id=#{other_child.id}", on_error: :warn)

      html = render(view)
      refute html =~ ~r/value=\"OTHER_INTENT_CHILD\"/
      assert has_element?(view, "#flash-error", "Stop does not belong to this station")
    end

    test "mounting with edit_child_stop_id on a non-default level switches active level and survives the patch",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      level_two =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_INTENT_2",
          level_name: "Level Intent Two",
          level_index: 1.0
        })

      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_two.id
        })

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "INTENT_CHILD_L2",
          stop_name: "Intent Child L2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_two.level_id,
          diagram_coordinate: %{"x" => 80.0, "y" => 90.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?edit_child_stop_id=#{child_stop.id}", on_error: :warn)

      html = render(view)
      assert html =~ ~r/value=\"INTENT_CHILD_L2\"/
      assert html =~ ~r/value=\"Intent Child L2\"/

      assert_patch(view, base_path)

      # The patch must NOT snap active_level back to the default level.
      # `level` is the default (level_index 0.0); `level_two` is where the stop lives.
      _ = level
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.active_level.id == level_two.id
    end

    test "mounting with edit_child_stop_id for a stop with no diagram coordinate shows missing-coordinate flash",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "INTENT_CHILD_NOCOORD",
          stop_name: "Intent Child NoCoord",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      conn = log_in_user(conn, user, organization: organization)

      base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?edit_child_stop_id=#{child_stop.id}", on_error: :warn)

      html = render(view)
      refute html =~ ~r/value=\"INTENT_CHILD_NOCOORD\"/
      assert has_element?(view, "#flash-error", "Stop has no diagram coordinate")
    end

    test "mounting with edit_child_stop_id for a stop on an unknown level shows unknown-level flash",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "INTENT_CHILD_BAD_LEVEL",
          stop_name: "Intent Child Bad Level",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L_NOT_ON_STATION",
          diagram_coordinate: %{"x" => 5.0, "y" => 6.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

      {:ok, view, _html} =
        live(conn, "#{base_path}?edit_child_stop_id=#{child_stop.id}", on_error: :warn)

      html = render(view)
      refute html =~ ~r/value=\"INTENT_CHILD_BAD_LEVEL\"/
      assert has_element?(view, "#flash-error", "Stop is not assigned to a known station level")
    end
  end

  describe "StationDiagramLive - remove from diagram" do
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
          stop_id: "STATION_RM",
          stop_name: "Remove Test Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_RM",
          level_name: "Level RM",
          level_index: 0.0
        })

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

    test "remove button is hidden in create drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "add"})
      render_hook(view, "canvas_click", %{"x" => "10", "y" => "20"})

      refute has_element?(view, "#remove-from-diagram-section")
    end

    test "remove button is visible in edit drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_RM_VIS",
          stop_name: "Visible Remove",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 40.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='edit_child_stop']")
      |> render_click()

      assert has_element?(view, "#remove-from-diagram-button")
    end

    test "clicking remove moves stop from child-stops-table to unassigned-stops-table and deletes pathways",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      child_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_RM_A",
          stop_name: "Child A",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      child_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_RM_B",
          stop_name: "Child B",
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          child_a.stop_id,
          child_b.stop_id,
          %{pathway_mode: 1, is_bidirectional: true}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      # Verify child_a is in the child stops table
      assert has_element?(view, "#child-stop-row-#{child_a.id}")

      # Open the edit drawer for child_a
      view
      |> element("#child-stop-row-#{child_a.id} button[phx-click='edit_child_stop']")
      |> render_click()

      # Click remove from diagram
      view
      |> element("#remove-from-diagram-button")
      |> render_click()

      # The stop should no longer be in the child stops table
      refute has_element?(view, "#child-stop-row-#{child_a.id}")

      # The stop should appear in the unassigned stops table
      assert has_element?(view, "#unassigned-stop-row-#{child_a.id}")

      # The pathway should be deleted (no dangling pathways)
      refute Repo.get(GtfsPlanner.Gtfs.Pathway, pathway.id)
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
      |> element("#child_stops-#{child_stop1.id} [data-stop-hit-target]")
      |> render_click()

      # Switch to level 2
      view
      |> element("form[phx-change=\"switch_level\"]")
      |> render_change(%{"level_id" => level2.id})

      # Click second stop on level 2
      view
      |> element("#child_stops-#{child_stop2.id} [data-stop-hit-target]")
      |> render_click()

      # Assert pathway was created
      pathways = Gtfs.list_pathways_for_station(organization.id, gtfs_version.id, station.id)
      assert length(pathways) == 1

      pathway = hd(pathways)
      assert pathway.from_stop_id == child_stop1.stop_id
      assert pathway.to_stop_id == child_stop2.stop_id

      assert has_element?(view, "#pathway-form")

      assert has_element?(
               view,
               "#pathway-form input[name='pathway_id'][value='#{pathway.pathway_id}']"
             )

      # Assert selected_from_stop is cleared by checking view state
      # The view should not show "From: ..." message anymore
      html = render(view)
      refute html =~ "From: Child Stop 1"
    end
  end

  describe "StationDiagramLive - child stop canvas visibility for active level connectivity" do
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
          stop_id: "VISIBILITY_STATION_PRIMARY",
          stop_name: "Visibility Station Primary",
          location_type: 1
        })

      foreign_station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VISIBILITY_STATION_FOREIGN",
          stop_name: "Visibility Station Foreign",
          location_type: 1
        })

      level_1 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "VISIBILITY_LEVEL_1",
          level_name: "Visibility Level 1",
          level_index: 0.0
        })

      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "VISIBILITY_LEVEL_2",
          level_name: "Visibility Level 2",
          level_index: 1.0
        })

      {:ok, _stop_level_1} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_1.id,
          diagram_filename: "visibility-level-1.png"
        })

      {:ok, _stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id,
          diagram_filename: "visibility-level-2.png"
        })

      on_level_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VISIBILITY_ON_LEVEL",
          stop_name: "Visibility On Level",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_1.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      off_level_disconnected_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VISIBILITY_OFF_LEVEL_DISCONNECTED",
          stop_name: "Visibility Off Level Disconnected",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 20.0}
        })

      off_level_connected_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VISIBILITY_OFF_LEVEL_CONNECTED",
          stop_name: "Visibility Off Level Connected",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 30.0}
        })

      off_level_connected_reverse_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VISIBILITY_OFF_LEVEL_CONNECTED_REVERSE",
          stop_name: "Visibility Off Level Connected Reverse",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 40.0, "y" => 40.0}
        })

      unassigned_disconnected_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VISIBILITY_UNASSIGNED_DISCONNECTED",
          stop_name: "Visibility Unassigned Disconnected",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 45.0, "y" => 45.0}
        })
        |> Ecto.Changeset.change(level_id: nil)
        |> Repo.update!()

      foreign_station_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VISIBILITY_FOREIGN_STATION_STOP",
          stop_name: "Visibility Foreign Station Stop",
          location_type: 0,
          parent_station: foreign_station.stop_id,
          level_id: level_1.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      pathway_fixture(
        organization.id,
        gtfs_version.id,
        on_level_stop.stop_id,
        off_level_connected_stop.stop_id
      )

      pathway_fixture(
        organization.id,
        gtfs_version.id,
        off_level_connected_reverse_stop.stop_id,
        on_level_stop.stop_id
      )

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level_1: level_1,
        on_level_stop: on_level_stop,
        off_level_disconnected_stop: off_level_disconnected_stop,
        off_level_connected_stop: off_level_connected_stop,
        off_level_connected_reverse_stop: off_level_connected_reverse_stop,
        unassigned_disconnected_stop: unassigned_disconnected_stop,
        foreign_station_stop: foreign_station_stop
      }
    end

    test "off-level disconnected child stop is hidden while on-level child stop is visible", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level_1: level_1,
      on_level_stop: on_level_stop,
      off_level_disconnected_stop: off_level_disconnected_stop
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level_id=#{level_1.id}",
          on_error: :warn
        )

      assert has_element?(view, "#child_stops-#{on_level_stop.id}")
      refute has_element?(view, "#child_stops-#{off_level_disconnected_stop.id}")
    end

    test "off-level connected child stop is hidden when connected to an active-level stop", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level_1: level_1,
      off_level_connected_stop: off_level_connected_stop
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level_id=#{level_1.id}",
          on_error: :warn
        )

      refute has_element?(view, "#child_stops-#{off_level_connected_stop.id}")
    end

    test "pathway direction does not affect off-level stop hiding when active-level stop is pathway to_stop",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level_1: level_1,
           off_level_connected_reverse_stop: off_level_connected_reverse_stop
         } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level_id=#{level_1.id}",
          on_error: :warn
        )

      refute has_element?(view, "#child_stops-#{off_level_connected_reverse_stop.id}")
    end

    test "foreign-station child stops never render in another station diagram", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level_1: level_1,
      foreign_station_stop: foreign_station_stop
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level_id=#{level_1.id}",
          on_error: :warn
        )

      refute has_element?(view, "#child_stops-#{foreign_station_stop.id}")
    end

    test "unassigned child stop without active-level pathway does not render on canvas", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level_1: level_1,
      unassigned_disconnected_stop: unassigned_disconnected_stop
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(
          conn,
          "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?level_id=#{level_1.id}",
          on_error: :warn
        )

      refute has_element?(view, "#child_stops-#{unassigned_disconnected_stop.id}")
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

      render_hook(view, "switch_mode", %{"mode" => "connect"})

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

      assert has_element?(
               view,
               "#child_stops-#{platform_stop.id} [data-stop-label]",
               "PLATFORM LABEL · 3A"
             )

      assert has_element?(
               view,
               "#child_stops-#{platform_without_code.id} [data-stop-label]",
               "PLATFORM NO CODE"
             )

      assert has_element?(
               view,
               "#child_stops-#{entrance_stop.id} [data-stop-label]",
               "ENTRANCE LABEL"
             )

      assert has_element?(view, "#child_stops-#{node_stop.id} [data-stop-label]", "NODE LABEL")

      assert has_element?(
               view,
               "#child_stops-#{boarding_without_code.id} [data-stop-label]",
               "BOARDING NO CODE"
             )
    end

    test "renders bounded and wrapped stop labels for long names", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      wrapped_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "WRAP_LABEL_STOP",
          stop_name: "Long Label For Platform Concourse Connector East Wing",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 18.0, "y" => 18.0}
        })

      truncated_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "TRUNC_LABEL_STOP",
          stop_name:
            "Very Long Label Name For Multi Segment Connector Through Main Hall And Auxiliary Passage To Platform",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 22.0, "y" => 22.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(
               view,
               "#child_stops-#{wrapped_stop.id} [data-stop-label-box][data-base-width][data-base-height]"
             )

      assert has_element?(
               view,
               "#child_stops-#{wrapped_stop.id} [data-stop-label] tspan:nth-of-type(2)"
             )

      assert has_element?(
               view,
               "#child_stops-#{truncated_stop.id} [data-stop-label][data-label-truncated='true']"
             )

      assert has_element?(view, "#child_stops-#{truncated_stop.id} [data-stop-label]", "...")
    end
  end

  describe "StationDiagramLive - pathway mode rendering" do
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
          stop_id: "PATHWAY_STATION",
          stop_name: "Pathway Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "PATHWAY_L1",
          level_name: "Pathway Level",
          level_index: 0.0
        })

      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "pathway-level.png"
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level
      }
    end

    test "renders mode-specific SVG structure for pathway modes 1 through 7", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      from_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PATHWAY_FROM",
          stop_name: "Pathway From",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      make_to_stop = fn suffix, x ->
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PATHWAY_TO_#{suffix}",
          stop_name: "Pathway To #{suffix}",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => x, "y" => 10.0 + x / 10}
        })
      end

      walkway_to = make_to_stop.("WALK", 20.0)
      stairs_to = make_to_stop.("STAIRS", 24.0)
      moving_to = make_to_stop.("MOVE", 28.0)
      escalator_to = make_to_stop.("ESC", 32.0)
      elevator_to = make_to_stop.("ELEV", 36.0)
      fare_gate_to = make_to_stop.("FARE", 40.0)
      exit_gate_to = make_to_stop.("EXIT", 44.0)

      mode_1 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          from_stop.stop_id,
          walkway_to.stop_id,
          %{
            pathway_mode: 1,
            is_bidirectional: true,
            signposted_as: "Forward Sign",
            reversed_signposted_as: "Reverse Sign"
          }
        )

      mode_2 =
        pathway_fixture(organization.id, gtfs_version.id, from_stop.stop_id, stairs_to.stop_id, %{
          pathway_mode: 2,
          is_bidirectional: false
        })

      mode_3 =
        pathway_fixture(organization.id, gtfs_version.id, from_stop.stop_id, moving_to.stop_id, %{
          pathway_mode: 3,
          is_bidirectional: true
        })

      mode_4 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          from_stop.stop_id,
          escalator_to.stop_id,
          %{
            pathway_mode: 4,
            is_bidirectional: false
          }
        )

      mode_5 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          from_stop.stop_id,
          elevator_to.stop_id,
          %{
            pathway_mode: 5,
            is_bidirectional: true
          }
        )

      mode_6 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          from_stop.stop_id,
          fare_gate_to.stop_id,
          %{
            pathway_mode: 6,
            is_bidirectional: false
          }
        )

      mode_7 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          from_stop.stop_id,
          exit_gate_to.stop_id,
          %{
            pathway_mode: 7,
            is_bidirectional: false
          }
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#pathways-#{mode_1.id} [data-pathway-line]")
      assert has_element?(view, "#pathways-#{mode_1.id} [data-pathway-label]", "Forward Sign →")
      assert has_element?(view, "#pathways-#{mode_1.id} [data-pathway-label]", "← Reverse Sign")
      assert has_element?(view, "#pathways-#{mode_1.id} [data-pathway-label][data-rotation]")

      assert has_element?(
               view,
               "#pathways-#{mode_1.id} [data-pathway-label][transform^='rotate(']",
               "Forward Sign →"
             )

      assert has_element?(
               view,
               "#pathways-#{mode_1.id} [data-pathway-label][transform^='rotate(']",
               "← Reverse Sign"
             )

      assert has_element?(view, "#pathways-#{mode_2.id} [data-pathway-center-tick]")
      assert has_element?(view, "#pathways-#{mode_3.id} [data-pathway-center-cross]")
      assert has_element?(view, "#pathways-#{mode_4.id} [data-pathway-center-bar]")
      assert has_element?(view, "#pathways-#{mode_5.id} [data-pathway-elevator-box]")
      assert has_element?(view, "#pathways-#{mode_5.id} [data-pathway-connector]")
      assert has_element?(view, "#pathways-#{mode_6.id} [data-pathway-rail]")
      assert has_element?(view, "#pathways-#{mode_6.id} [data-pathway-arrow-guide]")
      assert has_element?(view, "#pathways-#{mode_7.id} [data-pathway-rail]")
      assert has_element?(view, "#pathways-#{mode_7.id} [data-pathway-arrow-guide]")
    end

    test "left-to-right pathways render forward and reverse arrows with non-flipped mapping", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "LTR_ARROW_A",
          stop_name: "LTR Arrow A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 30.0}
        })

      stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "LTR_ARROW_B",
          stop_name: "LTR Arrow B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 30.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true,
          signposted_as: "Exit",
          reversed_signposted_as: "Entrance"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#pathways-#{pathway.id} [data-pathway-label]", "Exit →")
      assert has_element?(view, "#pathways-#{pathway.id} [data-pathway-label]", "← Entrance")
    end

    test "right-to-left pathways render forward and reverse arrows with flipped mapping", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "RTL_ARROW_A",
          stop_name: "RTL Arrow A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 32.0}
        })

      stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "RTL_ARROW_B",
          stop_name: "RTL Arrow B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 32.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true,
          signposted_as: "Exit",
          reversed_signposted_as: "Entrance"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#pathways-#{pathway.id} [data-pathway-label]", "← Exit")
      assert has_element?(view, "#pathways-#{pathway.id} [data-pathway-label]", "Entrance →")
    end

    test "horizontal pathway labels keep forward above and reverse below via opposite y offsets",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "H_OFFSET_A",
          stop_name: "Horizontal Offset A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 12.0, "y" => 35.0}
        })

      stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "H_OFFSET_B",
          stop_name: "Horizontal Offset B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 32.0, "y" => 35.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true,
          signposted_as: "Forward Y",
          reversed_signposted_as: "Reverse Y"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(
               view,
               "#pathways-#{pathway.id} [data-pathway-label][data-offset-y='-0.95']",
               "Forward Y →"
             )

      assert has_element?(
               view,
               "#pathways-#{pathway.id} [data-pathway-label][data-offset-y='0.95']",
               "← Reverse Y"
             )
    end

    test "vertical pathway labels keep forward and reverse on canonical opposite x offsets", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "V_OFFSET_A",
          stop_name: "Vertical Offset A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 12.0}
        })

      stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "V_OFFSET_B",
          stop_name: "Vertical Offset B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 32.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true,
          signposted_as: "Forward X",
          reversed_signposted_as: "Reverse X"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(
               view,
               "#pathways-#{pathway.id} [data-pathway-label][data-offset-x='-0.95']",
               "Forward X →"
             )

      assert has_element?(
               view,
               "#pathways-#{pathway.id} [data-pathway-label][data-offset-x='0.95']",
               "← Reverse X"
             )
    end

    test "applies directional arrow rules for one-way and bidirectional pathways", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ARROW_A",
          stop_name: "Arrow A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 12.0, "y" => 22.0}
        })

      stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ARROW_B",
          stop_name: "Arrow B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 25.0, "y" => 22.0}
        })

      stop_c =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ARROW_C",
          stop_name: "Arrow C",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 38.0, "y" => 22.0}
        })

      one_way_walkway =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: false
        })

      two_way_walkway =
        pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_c.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      two_way_moving =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_c.stop_id, %{
          pathway_mode: 3,
          is_bidirectional: true
        })

      stop_d =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ARROW_D",
          stop_name: "Arrow D",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 22.0}
        })

      stop_e =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ARROW_E",
          stop_name: "Arrow E",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 62.0, "y" => 22.0}
        })

      one_way_exit_gate =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_d.stop_id, %{
          pathway_mode: 7,
          is_bidirectional: false
        })

      two_way_exit_gate =
        pathway_fixture(organization.id, gtfs_version.id, stop_d.stop_id, stop_e.stop_id, %{
          pathway_mode: 7,
          is_bidirectional: true
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(
               view,
               "#pathways-#{one_way_walkway.id} [data-pathway-line][marker-end='url(#pathway-arrow)']"
             )

      refute has_element?(
               view,
               "#pathways-#{one_way_walkway.id} [data-pathway-line][marker-start='url(#pathway-arrow)']"
             )

      assert has_element?(
               view,
               "#pathways-#{two_way_walkway.id} [data-pathway-line][marker-start='url(#pathway-arrow)']"
             )

      assert has_element?(
               view,
               "#pathways-#{two_way_walkway.id} [data-pathway-line][marker-end='url(#pathway-arrow)']"
             )

      assert has_element?(
               view,
               "#pathways-#{two_way_moving.id} [data-pathway-line][marker-start='url(#pathway-arrow)']"
             )

      assert has_element?(
               view,
               "#pathways-#{two_way_moving.id} [data-pathway-line][marker-end='url(#pathway-arrow)']"
             )

      # One-way exit gate: arrow at end only
      assert has_element?(
               view,
               "#pathways-#{one_way_exit_gate.id} [data-pathway-arrow-guide][marker-end='url(#pathway-arrow)']"
             )

      refute has_element?(
               view,
               "#pathways-#{one_way_exit_gate.id} [data-pathway-arrow-guide][marker-start='url(#pathway-arrow)']"
             )

      # Bidirectional exit gate: arrows at both ends
      assert has_element?(
               view,
               "#pathways-#{two_way_exit_gate.id} [data-pathway-arrow-guide][marker-start='url(#pathway-arrow)']"
             )

      assert has_element?(
               view,
               "#pathways-#{two_way_exit_gate.id} [data-pathway-arrow-guide][marker-end='url(#pathway-arrow)']"
             )
    end

    test "renders editable tooltip metadata for stops and pathways with one shared tooltip node",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      from_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "TOOLTIP_STOP_A",
          stop_name: "Tooltip Stop A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 14.0, "y" => 20.0}
        })

      to_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "TOOLTIP_STOP_B",
          stop_name: "Tooltip Stop B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 34.0, "y" => 20.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, from_stop.stop_id, to_stop.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: false
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(
               view,
               "#child_stops-#{from_stop.id}[data-editable='stop'][data-tooltip='Click to edit, hold to move'][tabindex='0'][aria-label]"
             )

      assert has_element?(
               view,
               "#pathways-#{pathway.id}[data-editable='pathway'][data-tooltip='Click to edit pathway'][tabindex='0'][aria-label]"
             )

      assert has_element?(view, "#diagram-edit-tooltip[role='tooltip'][aria-hidden='true']")

      html = render(view)
      assert length(Regex.scan(~r/id=\"diagram-edit-tooltip\"/, html)) == 1
    end

    test "connect mode pathways omit edit affordances and pathway tooltip triggers", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      from_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CONNECT_PATHWAY_A",
          stop_name: "Connect Pathway A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 16.0, "y" => 30.0}
        })

      to_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CONNECT_PATHWAY_B",
          stop_name: "Connect Pathway B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 34.0, "y" => 30.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, from_stop.stop_id, to_stop.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: false
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "connect"})

      assert has_element?(view, "#pathways-#{pathway.id}")
      refute has_element?(view, "#pathways-#{pathway.id}[phx-click='edit_pathway']")
      refute has_element?(view, "#pathways-#{pathway.id}[data-tooltip]")
      refute has_element?(view, "#pathways-#{pathway.id}[tabindex='0']")
      refute has_element?(view, "#pathways-#{pathway.id} [data-pathway-tooltip-hit]")
      refute has_element?(view, "#pathways-#{pathway.id} [data-tooltip-trigger='true']")
    end

    test "connect mode stops render connect-specific tooltip guidance", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CONNECT_TOOLTIP_STOP",
          stop_name: "Connect Tooltip Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 18.0, "y" => 18.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("button[phx-click='switch_mode'][phx-value-mode='connect']")
      |> render_click()

      assert has_element?(
               view,
               "#child_stops-#{stop.id}[data-tooltip='Select stop to create pathway']"
             )
    end

    test "connect mode cross-level badges render hit rect without edit affordances", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "CONNECT_BADGE_L2",
          level_name: "Connect Badge Level 2",
          level_index: 1.0
        })

      {:ok, _stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id,
          diagram_filename: "connect-badge-level-2.png"
        })

      level_1_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CONNECT_BADGE_L1",
          stop_name: "Connect Badge L1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 40.0}
        })

      level_2_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CONNECT_BADGE_L2_STOP",
          stop_name: "Connect Badge L2 Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 32.0, "y" => 52.0}
        })

      cross_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          level_2_stop.stop_id,
          %{pathway_mode: 2, is_bidirectional: true}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("button[phx-click='switch_mode'][phx-value-mode='connect']")
      |> render_click()

      assert has_element?(view, "#cross-level-badge-#{cross_level_pathway.id}")

      refute has_element?(
               view,
               "#cross-level-badge-#{cross_level_pathway.id}[phx-click='edit_pathway']"
             )

      refute has_element?(view, "#cross-level-badge-#{cross_level_pathway.id}[data-tooltip]")
      refute has_element?(view, "#cross-level-badge-#{cross_level_pathway.id}[tabindex='0']")

      # Unified hit rect is still rendered in connect mode — only the edit
      # affordances above are gated on view mode.
      assert has_element?(
               view,
               "#cross-level-badge-#{cross_level_pathway.id} rect[data-cross-level-badge-hit='true'][data-base-size='0.9']"
             )

      # Icon paths must not carry the edit-mode hover color.
      refute has_element?(
               view,
               ~s|#cross-level-badge-#{cross_level_pathway.id} path.group-hover\\:fill-\\[\\#FF4500\\]|
             )
    end

    test "view mode keeps pathway and cross-level badge edit affordances", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "VIEW_AFFORDANCE_L2",
          level_name: "View Affordance Level 2",
          level_index: 1.0
        })

      {:ok, _stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id,
          diagram_filename: "view-affordance-level-2.png"
        })

      from_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VIEW_AFFORDANCE_A",
          stop_name: "View Affordance A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 15.0, "y" => 15.0}
        })

      same_level_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VIEW_AFFORDANCE_B",
          stop_name: "View Affordance B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 36.0, "y" => 15.0}
        })

      level_2_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "VIEW_AFFORDANCE_C",
          stop_name: "View Affordance C",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 42.0, "y" => 30.0}
        })

      same_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          from_stop.stop_id,
          same_level_stop.stop_id,
          %{pathway_mode: 1, is_bidirectional: false}
        )

      cross_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          from_stop.stop_id,
          level_2_stop.stop_id,
          %{pathway_mode: 1, is_bidirectional: false}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#pathways-#{same_level_pathway.id}[phx-click='edit_pathway']")

      assert has_element?(
               view,
               "#pathways-#{same_level_pathway.id}[data-tooltip='Click to edit pathway']"
             )

      assert has_element?(view, "#pathways-#{same_level_pathway.id}[tabindex='0']")
      assert has_element?(view, "#pathways-#{same_level_pathway.id} [data-pathway-tooltip-hit]")

      assert has_element?(
               view,
               "#cross-level-badge-#{cross_level_pathway.id}[phx-click='edit_pathway']"
             )

      assert has_element?(view, "#cross-level-badge-#{cross_level_pathway.id}[data-tooltip]")
      assert has_element?(view, "#cross-level-badge-#{cross_level_pathway.id}[tabindex='0']")

      assert has_element?(
               view,
               "#cross-level-badge-#{cross_level_pathway.id} rect[data-cross-level-badge-hit='true'][data-base-size='0.9']"
             )

      assert has_element?(
               view,
               "#cross-level-badge-#{cross_level_pathway.id} [data-tooltip-trigger='true']"
             )
    end

    test "cross-level badge renders a unified hit rect with group hover classes in view mode", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      %{
        badge_pathway: badge_pathway,
        line_pathway: _line_pathway
      } = setup_badge_and_line_fixtures(organization, gtfs_version, station, level)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      # AC #1: badge <g> has exactly one unified hit rect
      assert has_element?(
               view,
               "g#cross-level-badge-#{badge_pathway.id} rect[data-cross-level-badge-hit='true'][data-base-size='0.9']"
             )

      # AC #2/#3: legacy hit attributes are gone everywhere
      refute has_element?(view, "[data-cross-level-badge-hit-target]")
      refute has_element?(view, "[data-cross-level-badge-tooltip-hit]")

      # AC #4: badge <g> carries the `group` class so descendants can resolve group-hover
      assert has_element?(view, "g#cross-level-badge-#{badge_pathway.id}.group")

      # AC #5: icon path carries pointer-events-none and the #FF4500 group-hover fill
      assert has_element?(
               view,
               ~s|g#cross-level-badge-#{badge_pathway.id} path.group-hover\\:fill-\\[\\#FF4500\\].pointer-events-none|
             )
    end

    test "clicking the cross-level badge <g> opens the pathway drawer for the badge's pathway",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      %{
        badge_pathway: badge_pathway,
        line_pathway: line_pathway
      } = setup_badge_and_line_fixtures(organization, gtfs_version, station, level)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("g#cross-level-badge-#{badge_pathway.id}")
      |> render_click()

      # Drawer opens for the badge's pathway (AC #7)
      assert has_element?(
               view,
               "#pathway-form input[name='pathway_id'][value='#{badge_pathway.pathway_id}']"
             )

      # And not for the line pathway
      refute has_element?(
               view,
               "#pathway-form input[name='pathway_id'][value='#{line_pathway.pathway_id}']"
             )
    end

    test "clicking the same-level pathway <g> opens the pathway drawer for the line pathway",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      %{
        badge_pathway: badge_pathway,
        line_pathway: line_pathway
      } = setup_badge_and_line_fixtures(organization, gtfs_version, station, level)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#pathways-#{line_pathway.id}")
      |> render_click()

      # Drawer opens for the line pathway (AC #8)
      assert has_element?(
               view,
               "#pathway-form input[name='pathway_id'][value='#{line_pathway.pathway_id}']"
             )

      # And not for the badge pathway
      refute has_element?(
               view,
               "#pathway-form input[name='pathway_id'][value='#{badge_pathway.pathway_id}']"
             )
    end

    test "add mode disables badge click and removes hover classes (mode gating)", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      %{
        badge_pathway: badge_pathway,
        line_pathway: _line_pathway
      } = setup_badge_and_line_fixtures(organization, gtfs_version, station, level)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "add"})

      # Badge is still rendered, but click affordance is gone (AC #12)
      assert has_element?(view, "g#cross-level-badge-#{badge_pathway.id}")
      refute has_element?(view, "g#cross-level-badge-#{badge_pathway.id}[phx-click]")

      refute has_element?(
               view,
               ~s|g#cross-level-badge-#{badge_pathway.id} path.group-hover\\:fill-\\[\\#FF4500\\]|
             )
    end

    test "renders elevator opacity, cross-level badges, and keeps cross-level pathways out of SVG",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "PATHWAY_L2",
          level_name: "Pathway Level 2",
          level_index: 1.0
        })

      {:ok, _stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id,
          diagram_filename: "pathway-level-2.png"
        })

      level_1_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OPACITY_L1_A",
          stop_name: "Opacity L1 A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 15.0, "y" => 35.0}
        })

      level_1_stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OPACITY_L1_B",
          stop_name: "Opacity L1 B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 28.0, "y" => 35.0}
        })

      level_2_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OPACITY_L2_A",
          stop_name: "Opacity L2 A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 28.0, "y" => 44.0}
        })

      elevator_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          level_1_stop_b.stop_id,
          %{
            pathway_mode: 5,
            is_bidirectional: true
          }
        )

      cross_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          level_2_stop.stop_id,
          %{
            pathway_mode: 1,
            is_bidirectional: false
          }
        )

      cross_level_pathway_mode_2 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          level_2_stop.stop_id,
          %{
            pathway_mode: 2,
            is_bidirectional: true
          }
        )

      normal_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop_b.stop_id,
          level_1_stop.stop_id,
          %{
            pathway_mode: 1,
            is_bidirectional: true
          }
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#pathways-#{elevator_pathway.id}[opacity='1']")
      assert has_element?(view, "#pathways-#{normal_pathway.id}[opacity='1']")

      refute has_element?(view, "#pathways-#{cross_level_pathway.id}")
      refute has_element?(view, "#pathways-#{cross_level_pathway_mode_2.id}")

      assert has_element?(view, "#pathway-row-#{cross_level_pathway.id}")
      assert has_element?(view, "#pathway-row-#{cross_level_pathway_mode_2.id}")
      assert has_element?(view, "#pathway-row-#{cross_level_pathway.id}", level_2.level_id)
      assert has_element?(view, "#pathway-row-#{cross_level_pathway_mode_2.id}", level_2.level_id)
      assert has_element?(view, "#pathway-row-#{normal_pathway.id}", "—")

      assert has_element?(
               view,
               "#child_stops-#{level_1_stop.id} [data-cross-level-pathway-badge][data-pathway-id='#{cross_level_pathway.id}'] [data-cross-level-badge-elevator]"
             )

      assert has_element?(
               view,
               "#child_stops-#{level_1_stop.id} [data-cross-level-pathway-badge][data-pathway-id='#{cross_level_pathway_mode_2.id}'] [data-cross-level-badge-stairs]"
             )

      refute has_element?(
               view,
               "#child_stops-#{level_1_stop_b.id} [data-cross-level-pathway-badge]"
             )

      assert has_element?(view, "#diagram-legend-panel", "Cross-level Stairs")
      assert has_element?(view, "#diagram-legend-panel", "Cross-level Elevator")
    end

    test "clicking a cross-level badge opens pathway drawer for that pathway only", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "PATHWAY_L2_CLICK",
          level_name: "Pathway Level 2 Click",
          level_index: 1.0
        })

      {:ok, _stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id,
          diagram_filename: "pathway-level-2-click.png"
        })

      level_1_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_CLICK_L1",
          stop_name: "Cross Click L1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 18.0, "y" => 28.0}
        })

      level_2_stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_CLICK_L2_A",
          stop_name: "Cross Click L2 A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 36.0, "y" => 42.0}
        })

      level_2_stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_CLICK_L2_B",
          stop_name: "Cross Click L2 B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 42.0, "y" => 46.0}
        })

      _other_cross_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          level_2_stop_a.stop_id,
          %{
            pathway_mode: 1,
            is_bidirectional: true
          }
        )

      clicked_cross_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          level_2_stop_b.stop_id,
          %{
            pathway_mode: 2,
            is_bidirectional: false
          }
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element(
        "#child_stops-#{level_1_stop.id} [data-cross-level-pathway-badge][data-pathway-id='#{clicked_cross_level_pathway.id}']"
      )
      |> render_click()

      assert has_element?(view, "#pathway-form")

      assert has_element?(
               view,
               "#pathway-form input[name='pathway_id'][value='#{clicked_cross_level_pathway.pathway_id}']"
             )

      refute has_element?(view, "#child-stop-form")
    end

    test "renders one cross-level badge per cross-level pathway even for duplicate modes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "PATHWAY_L2_DUP",
          level_name: "Pathway Level 2 Dup",
          level_index: 1.0
        })

      {:ok, _stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id,
          diagram_filename: "pathway-level-2-dup.png"
        })

      level_1_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_DUP_L1",
          stop_name: "Cross Dup L1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 14.0, "y" => 22.0}
        })

      level_2_stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_DUP_L2_A",
          stop_name: "Cross Dup L2 A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 34.0, "y" => 36.0}
        })

      level_2_stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_DUP_L2_B",
          stop_name: "Cross Dup L2 B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 38.0, "y" => 40.0}
        })

      cross_level_pathway_1 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          level_2_stop_a.stop_id,
          %{pathway_mode: 1, is_bidirectional: true}
        )

      cross_level_pathway_2 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          level_2_stop_b.stop_id,
          %{pathway_mode: 1, is_bidirectional: true}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(
               view,
               "#child_stops-#{level_1_stop.id} [data-cross-level-pathway-badge][data-pathway-id='#{cross_level_pathway_1.id}']"
             )

      assert has_element?(
               view,
               "#child_stops-#{level_1_stop.id} [data-cross-level-pathway-badge][data-pathway-id='#{cross_level_pathway_2.id}']"
             )

      assert has_element?(
               view,
               "#cross-level-badge-#{cross_level_pathway_1.id} [data-cross-level-badge-elevator]"
             )

      assert has_element?(
               view,
               "#cross-level-badge-#{cross_level_pathway_2.id} [data-cross-level-badge-elevator]"
             )
    end

    test "does not render a secondary badge for same-level pathways when a stop also has a cross-level pathway",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level
         } do
      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "PATHWAY_L2_MIXED",
          level_name: "Pathway Level 2 Mixed",
          level_index: 1.0
        })

      {:ok, _stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id,
          diagram_filename: "pathway-level-2-mixed.png"
        })

      level_1_stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_MIX_L1_A",
          stop_name: "Cross Mix L1 A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 16.0, "y" => 26.0}
        })

      level_1_stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_MIX_L1_B",
          stop_name: "Cross Mix L1 B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 24.0, "y" => 26.0}
        })

      level_2_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_MIX_L2",
          stop_name: "Cross Mix L2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 34.0, "y" => 38.0}
        })

      same_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop_a.stop_id,
          level_1_stop_b.stop_id,
          %{pathway_mode: 2, is_bidirectional: true}
        )

      cross_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop_a.stop_id,
          level_2_stop.stop_id,
          %{pathway_mode: 2, is_bidirectional: true}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(
               view,
               "#child_stops-#{level_1_stop_a.id} [data-cross-level-pathway-badge][data-pathway-id='#{cross_level_pathway.id}']"
             )

      refute has_element?(
               view,
               "#child_stops-#{level_1_stop_a.id} [data-cross-level-pathway-badge][data-pathway-id='#{same_level_pathway.id}']"
             )
    end

    test "deleting a cross-level pathway immediately removes its secondary badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "PATHWAY_L2_DELETE",
          level_name: "Pathway Level 2 Delete",
          level_index: 1.0
        })

      {:ok, _stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id,
          diagram_filename: "pathway-level-2-delete.png"
        })

      level_1_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_DELETE_L1",
          stop_name: "Cross Delete L1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 19.0, "y" => 29.0}
        })

      level_2_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CROSS_DELETE_L2",
          stop_name: "Cross Delete L2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 37.0, "y" => 45.0}
        })

      cross_level_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          level_2_stop.stop_id,
          %{pathway_mode: 1, is_bidirectional: true}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(
               view,
               "#child_stops-#{level_1_stop.id} [data-cross-level-pathway-badge][data-pathway-id='#{cross_level_pathway.id}']"
             )

      render_hook(view, "delete_pathway", %{"id" => cross_level_pathway.id})

      refute has_element?(view, "#pathway-row-#{cross_level_pathway.id}")

      refute has_element?(
               view,
               "#child_stops-#{level_1_stop.id} [data-cross-level-pathway-badge][data-pathway-id='#{cross_level_pathway.id}']"
             )
    end

    test "pathway to an unassigned-level stop does not render a secondary badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      level_1_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "UNASSIGNED_BADGE_L1",
          stop_name: "Unassigned Badge L1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 21.0, "y" => 31.0}
        })

      unassigned_stop =
        Repo.insert!(%GtfsPlanner.Gtfs.Stop{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: "UNASSIGNED_BADGE_STOP",
          stop_name: "Unassigned Badge Stop",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: nil,
          stop_lat: Decimal.new("40.7128"),
          stop_lon: Decimal.new("-74.0060"),
          wheelchair_boarding: 0
        })

      pathway_to_unassigned =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          level_1_stop.stop_id,
          unassigned_stop.stop_id,
          %{pathway_mode: 1, is_bidirectional: true}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#pathway-row-#{pathway_to_unassigned.id}")

      refute has_element?(
               view,
               "#child_stops-#{level_1_stop.id} [data-cross-level-pathway-badge][data-pathway-id='#{pathway_to_unassigned.id}']"
             )
    end

    test "add mode keeps pathways non-interactive", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NON_INTERACTIVE_A",
          stop_name: "Non Interactive A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 12.0, "y" => 48.0}
        })

      stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NON_INTERACTIVE_B",
          stop_name: "Non Interactive B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 26.0, "y" => 48.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: false
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("button[phx-click='switch_mode'][phx-value-mode='add']")
      |> render_click()

      refute has_element?(view, "#pathways-#{pathway.id}[phx-click='edit_pathway']")
      refute has_element?(view, "#pathway-form")
    end

    test "pathway preview SVG renders mode-specific elements and directional markers", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      from_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PREVIEW_FROM",
          stop_name: "Preview From",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 14.0, "y" => 20.0}
        })

      to_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PREVIEW_TO",
          stop_name: "Preview To",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 34.0, "y" => 20.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, from_stop.stop_id, to_stop.stop_id, %{
          pathway_mode: 5,
          is_bidirectional: true,
          signposted_as: "Forward Sign",
          reversed_signposted_as: "Reverse Sign"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#pathway-row-#{pathway.id} button[phx-click='edit_pathway']")
      |> render_click()

      assert has_element?(view, "svg[data-pathway-preview]")
      assert has_element?(view, "svg[data-pathway-preview] g title", "Preview From")
      assert has_element?(view, "svg[data-pathway-preview] g title", "Preview To")

      assert has_element?(
               view,
               "svg[data-pathway-preview] rect[x='215'][y='8'][width='50'][height='16']"
             )

      assert has_element?(
               view,
               "svg[data-pathway-preview] line[marker-start='url(#preview-arrow)']"
             )

      assert has_element?(view, "svg[data-pathway-preview] text", "Forward Sign →")
      assert has_element?(view, "svg[data-pathway-preview] text", "← Reverse Sign")

      view
      |> form("#pathway-form", %{"reversed_signposted_as" => ""})
      |> render_change()

      assert has_element?(view, "svg[data-pathway-preview] text", "Forward Sign →")
      refute has_element?(view, "svg[data-pathway-preview] text", "← Reverse Sign")

      view
      |> form("#pathway-form", %{
        "is_bidirectional" => "false",
        "reversed_signposted_as" => "Reverse Hidden"
      })
      |> render_change()

      assert has_element?(view, "svg[data-pathway-preview] text", "Forward Sign →")
      refute has_element?(view, "svg[data-pathway-preview] text", "← Reverse Hidden")
      assert has_element?(view, "button[phx-click='flip_pathway'][phx-value-id='#{pathway.id}']")
    end

    test "flip pathway swaps from/to stops and signage", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_x =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "FLIP_X",
          stop_name: "Flip X",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 14.0, "y" => 30.0}
        })

      stop_y =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "FLIP_Y",
          stop_name: "Flip Y",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 34.0, "y" => 30.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, stop_x.stop_id, stop_y.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: false,
          signposted_as: "To Y",
          reversed_signposted_as: "To X"
        })

      other_pathway =
        pathway_fixture(organization.id, gtfs_version.id, stop_y.stop_id, stop_x.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: false,
          signposted_as: "Other To X",
          reversed_signposted_as: "Other To Y"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#pathway-row-#{pathway.id} button[phx-click='edit_pathway']")
      |> render_click()

      view
      |> element("button[phx-click='flip_pathway']")
      |> render_click()

      # Verify signage was swapped in the form (signposted_as is always visible)
      assert has_element?(
               view,
               "#pathway-form input[name='signposted_as'][value='To X']"
             )

      # Verify the database record was updated with swapped stops and signage
      updated = Gtfs.get_pathway_with_stops!(pathway.id)
      assert updated.from_stop_id == stop_y.stop_id
      assert updated.to_stop_id == stop_x.stop_id
      assert updated.signposted_as == "To X"
      assert updated.reversed_signposted_as == "To Y"

      # Verify event payload targeted the selected pathway
      untouched = Gtfs.get_pathway_with_stops!(other_pathway.id)
      assert untouched.from_stop_id == stop_y.stop_id
      assert untouched.to_stop_id == stop_x.stop_id
      assert untouched.signposted_as == "Other To X"
      assert untouched.reversed_signposted_as == "Other To Y"
    end

    test "flip pathway with invalid id shows not found error without crashing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "flip_pathway", %{"id" => "not-a-uuid"})

      assert has_element?(view, "#lists-section", "Pathway not found.")
    end

    test "flip pathway with missing id shows not found error without crashing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "flip_pathway", %{})

      assert has_element?(view, "#lists-section", "Pathway not found.")
    end

    test "flip pathway with stale valid id shows not found error without crashing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_click(view, "flip_pathway", %{"id" => Ecto.UUID.generate()})

      assert has_element?(view, "#lists-section", "Pathway not found.")
    end

    test "flip pathway for pathway outside station shows unauthorized error without crashing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      other_station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "FLIP_OTHER_STATION",
          stop_name: "Flip Other Station",
          location_type: 1
        })

      other_stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "FLIP_OTHER_A",
          stop_name: "Flip Other A",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 42.0, "y" => 42.0}
        })

      other_stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "FLIP_OTHER_B",
          stop_name: "Flip Other B",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 46.0, "y" => 46.0}
        })

      unauthorized_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          other_stop_a.stop_id,
          other_stop_b.stop_id,
          %{pathway_mode: 1, is_bidirectional: true}
        )

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "flip_pathway", %{"id" => unauthorized_pathway.id})

      assert has_element?(view, "#lists-section", "Unauthorized pathway access.")
    end
  end

  describe "StationDiagramLive - walkability selection" do
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
          stop_id: "STATION_WALKABILITY",
          stop_name: "Walkability Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1_WALKABILITY",
          level_name: "Walkability Level",
          level_index: 0.0
        })

      secondary_level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L2_WALKABILITY",
          level_name: "Walkability Level 2",
          level_index: 1.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "walkability-diagram.png")

      {:ok, _secondary_stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: secondary_level.id
        })

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_WALKABILITY_1",
          stop_name: "Walkability Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      off_level_child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_WALKABILITY_2",
          stop_name: "Walkability Child Off Level",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: secondary_level.level_id,
          diagram_coordinate: %{"x" => 55.0, "y" => 55.0}
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        child_stop: child_stop,
        off_level_child_stop: off_level_child_stop
      }
    end

    test "address selection enables walkability test submission", %{
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

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='open_walkability_drawer']")
      |> render_click()

      assert has_element?(view, "#walkability-test-form button[type='submit'][disabled]")

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "123 Main", _opts ->
        {:ok,
         [
           %GtfsPlanner.Geocoding.Result{
             formatted_address: "123 Main St, Boston, MA, USA",
             lat: 42.3601,
             lon: -71.0589,
             country: "USA",
             state: "Massachusetts",
             city: "Boston"
           }
         ]}
      end)

      render_hook(view, "live_select_change", %{
        "text" => "123 Main",
        "id" => "walkability_address_autocomplete_component"
      })

      selection =
        Phoenix.json_library().encode!(%{
          "formatted_address" => "123 Main St, Boston, MA, USA",
          "lat" => 42.3601,
          "lon" => -71.0589,
          "country" => "USA",
          "state" => "Massachusetts",
          "city" => "Boston"
        })

      render_change(view, "walkability_form_change", %{
        "walkability" => %{"address_autocomplete" => selection}
      })

      assert has_element?(view, "#walkability-test-form button[type='submit']:not([disabled])")
      assert has_element?(view, "#walkability-test-form p", "123 Main St, Boston, MA, USA")
    end

    test "text-input-only change does not clear selected walkability address", %{
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

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='open_walkability_drawer']")
      |> render_click()

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "123 Main", _opts ->
        {:ok,
         [
           %GtfsPlanner.Geocoding.Result{
             formatted_address: "123 Main St, Boston, MA, USA",
             lat: 42.3601,
             lon: -71.0589,
             country: "USA",
             state: "Massachusetts",
             city: "Boston"
           }
         ]}
      end)

      render_hook(view, "live_select_change", %{
        "text" => "123 Main",
        "id" => "walkability_address_autocomplete_component"
      })

      selection =
        Phoenix.json_library().encode!(%{
          "formatted_address" => "123 Main St, Boston, MA, USA",
          "lat" => 42.3601,
          "lon" => -71.0589,
          "country" => "USA",
          "state" => "Massachusetts",
          "city" => "Boston"
        })

      render_change(view, "walkability_form_change", %{
        "walkability" => %{"address_autocomplete" => selection}
      })

      assert has_element?(view, "#walkability-test-form button[type='submit']:not([disabled])")

      render_change(view, "walkability_form_change", %{
        "walkability" => %{"address_autocomplete_text_input" => ""}
      })

      assert has_element?(view, "#walkability-test-form button[type='submit']:not([disabled])")
      assert has_element?(view, "#walkability-test-form p", "123 Main St, Boston, MA, USA")
    end

    test "save success closes drawer and marks stop as tested", %{
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

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='open_walkability_drawer']")
      |> render_click()

      selection =
        Phoenix.json_library().encode!(%{
          "formatted_address" => "123 Main St, Boston, MA, USA",
          "lat" => 42.3601,
          "lon" => -71.0589,
          "country" => "USA",
          "state" => "Massachusetts",
          "city" => "Boston"
        })

      render_change(view, "walkability_form_change", %{
        "walkability" => %{"address_autocomplete" => selection}
      })

      view
      |> form("#walkability-test-form")
      |> render_submit()

      refute has_element?(view, "#walkability-test-form")

      assert has_element?(view, "#child-stop-row-#{child_stop.id}", "1 test case")
    end

    test "duplicate save shows duplicate-address error flash", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      child_stop: child_stop
    } do
      _existing_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: child_stop.stop_id,
          address: "123 Main St, Boston, MA, USA"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#child-stop-row-#{child_stop.id} button[phx-click='open_walkability_drawer']")
      |> render_click()

      selection =
        Phoenix.json_library().encode!(%{
          "formatted_address" => "123 Main St, Boston, MA, USA",
          "lat" => 42.3601,
          "lon" => -71.0589,
          "country" => "USA",
          "state" => "Massachusetts",
          "city" => "Boston"
        })

      render_change(view, "walkability_form_change", %{
        "walkability" => %{"address_autocomplete" => selection}
      })

      view
      |> form("#walkability-test-form")
      |> render_submit()

      assert has_element?(
               view,
               "#walkability-test-drawer",
               "This address is already registered for this stop."
             )

      assert has_element?(view, "#walkability-test-form")
    end

    test "table lists only active-level walkability tests", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      child_stop: child_stop,
      off_level_child_stop: off_level_child_stop
    } do
      in_level_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: child_stop.stop_id,
          address: "10 Active Level Way"
        })

      off_level_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: off_level_child_stop.stop_id,
          address: "20 Off Level Way"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#walkability-tests-table")
      assert has_element?(view, "#walkability-test-row-#{in_level_test.id}")
      refute has_element?(view, "#walkability-test-row-#{off_level_test.id}")
    end

    test "clicking Edit opens drawer in edit mode with pre-populated values", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      child_stop: child_stop
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: child_stop.stop_id,
          address: "123 Edit Street, Boston, MA, USA",
          description: "Prepopulated description",
          expected_traversable: true,
          expected_wheelchair_accessible: true,
          expected_min_duration_seconds: 30
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#walkability-test-stop-#{walkability_test.id}")
      |> render_click()

      assert has_element?(view, "#walkability-test-form button[type='submit']", "Save Test Case")
      assert has_element?(view, "#walkability-test-form", "123 Edit Street, Boston, MA, USA")
      assert has_element?(view, "#walkability-test-form", "Prepopulated description")
      assert has_element?(view, "#walkability-test-delete-section")
    end

    test "edit submit updates record and row content then closes drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      child_stop: child_stop
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: child_stop.stop_id,
          address: "500 Update Ave, Boston, MA, USA",
          description: "Before update",
          expected_traversable: true,
          expected_wheelchair_accessible: false
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#walkability-test-stop-#{walkability_test.id}")
      |> render_click()

      render_change(view, "walkability_form_change", %{
        "walkability" => %{
          "description" => "After update",
          "expected_traversable" => "false",
          "expected_wheelchair_accessible" => "true",
          "expected_min_duration_seconds" => "45",
          "expected_max_duration_seconds" => "120"
        }
      })

      view
      |> form("#walkability-test-form")
      |> render_submit()

      refute has_element?(view, "#walkability-test-form")
      assert has_element?(view, "#walkability-test-row-#{walkability_test.id}", "After update")
      refute has_element?(view, "#walkability-test-row-#{walkability_test.id}", "Before update")

      updated = Validations.get_walkability_test!(walkability_test.id)
      assert updated.description == "After update"
      assert updated.expected_traversable == false
      assert updated.expected_wheelchair_accessible == true
      assert updated.expected_min_duration_seconds == 45
      assert updated.expected_max_duration_seconds == 120
    end

    test "duplicate address on edit shows duplicate-specific error flash and keeps drawer open",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           child_stop: child_stop
         } do
      existing =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: child_stop.stop_id,
          address: "111 Existing Address, Boston, MA, USA"
        })

      editing =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: child_stop.stop_id,
          address: "222 Editable Address, Boston, MA, USA"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> element("#walkability-test-stop-#{editing.id}")
      |> render_click()

      duplicate_selection =
        Phoenix.json_library().encode!(%{
          "formatted_address" => existing.address,
          "lat" => 42.3601,
          "lon" => -71.0589
        })

      render_change(view, "walkability_form_change", %{
        "walkability" => %{"address_autocomplete" => duplicate_selection}
      })

      view
      |> form("#walkability-test-form")
      |> render_submit()

      assert has_element?(
               view,
               "#flash-error",
               "This address is already registered for this stop."
             )

      assert has_element?(view, "#walkability-test-form")

      unchanged = Validations.get_walkability_test!(editing.id)
      assert unchanged.address == "222 Editable Address, Boston, MA, USA"
    end

    test "deleting from row removes record and row, updates child-stop count, and shows success flash",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           child_stop: child_stop
         } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: child_stop.stop_id,
          address: "999 Delete Me Ave"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#walkability-test-row-#{walkability_test.id}")
      assert has_element?(view, "#child-stop-row-#{child_stop.id}", "1 test case")

      view
      |> element("#walkability-test-stop-#{walkability_test.id}")
      |> render_click()

      view
      |> element("#walkability-test-delete-in-form")
      |> render_click()

      refute has_element?(view, "#walkability-test-row-#{walkability_test.id}")
      refute has_element?(view, "#child-stop-row-#{child_stop.id}", "1 test case")
      assert is_nil(Validations.get_walkability_test(walkability_test.id))
    end
  end

  describe "StationDiagramLive - nested platform scope validation" do
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
          stop_id: "NESTED_SCOPE_STATION",
          stop_name: "Nested Scope Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "NESTED_SCOPE_L1",
          level_name: "Nested Scope Level",
          level_index: 0.0
        })

      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      platform_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NESTED_SCOPE_PLATFORM",
          stop_name: "Nested Scope Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 20.0}
        })

      boarding_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NESTED_SCOPE_BOARDING_A",
          stop_name: "Nested Scope Boarding A",
          location_type: 4,
          parent_station: platform_stop.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 24.0, "y" => 24.0}
        })

      boarding_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NESTED_SCOPE_BOARDING_B",
          stop_name: "Nested Scope Boarding B",
          location_type: 4,
          parent_station: platform_stop.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 34.0, "y" => 24.0}
        })

      nested_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          boarding_a.stop_id,
          boarding_b.stop_id,
          %{pathway_mode: 1, is_bidirectional: true}
        )

      foreign_station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NESTED_SCOPE_FOREIGN_STATION",
          stop_name: "Nested Scope Foreign Station",
          location_type: 1
        })

      foreign_platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NESTED_SCOPE_FOREIGN_PLATFORM",
          stop_name: "Nested Scope Foreign Platform",
          location_type: 0,
          parent_station: foreign_station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 40.0, "y" => 40.0}
        })

      foreign_boarding =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NESTED_SCOPE_FOREIGN_BOARDING",
          stop_name: "Nested Scope Foreign Boarding",
          location_type: 4,
          parent_station: foreign_platform.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 44.0, "y" => 44.0}
        })

      unauthorized_pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          boarding_a.stop_id,
          foreign_boarding.stop_id,
          %{pathway_mode: 1, is_bidirectional: true}
        )

      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: boarding_a.stop_id,
          address: "700 Nested Scope Ave, Boston, MA, USA"
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        boarding_a: boarding_a,
        nested_pathway: nested_pathway,
        unauthorized_pathway: unauthorized_pathway,
        walkability_test: walkability_test
      }
    end

    test "save_pathway accepts boarding areas nested under platform parents", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      nested_pathway: nested_pathway
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{nested_pathway.id} button[phx-click='edit_pathway']")
      |> render_click()

      view
      |> form("#pathway-form", %{
        "pathway_mode" => "3",
        "is_bidirectional" => "false",
        "traversal_time" => "45",
        "length" => "12.50",
        "min_width" => "1.25",
        "signposted_as" => "Updated Nested Sign",
        "reversed_signposted_as" => ""
      })
      |> render_submit()

      updated_pathway = Gtfs.get_pathway!(nested_pathway.id)
      assert updated_pathway.pathway_mode == 3
      assert updated_pathway.is_bidirectional == false
      assert updated_pathway.traversal_time == 45
      assert Decimal.equal?(updated_pathway.length, Decimal.new("12.50"))
      assert Decimal.equal?(updated_pathway.min_width, Decimal.new("1.25"))
      assert updated_pathway.signposted_as == "Updated Nested Sign"
      refute has_element?(view, "#lists-section", "Unauthorized pathway access.")
    end

    test "save_pathway authorization failure keeps submitted form values and shows drawer error",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           unauthorized_pathway: unauthorized_pathway
         } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      render_hook(view, "edit_pathway", %{"id" => unauthorized_pathway.id})

      view
      |> form("#pathway-form", %{
        "pathway_mode" => "7",
        "is_bidirectional" => "true",
        "traversal_time" => "88",
        "length" => "18.75",
        "min_width" => "1.10",
        "signposted_as" => "Unauthorized Attempt",
        "reversed_signposted_as" => "Reverse Unauthorized Attempt"
      })
      |> render_submit()

      assert has_element?(view, "#pathway-form")
      assert has_element?(view, "#pathway-form-error", "Unauthorized pathway access.")
      assert has_element?(view, "#pathway-form input[name='traversal_time'][value='88']")

      assert has_element?(
               view,
               "#pathway-form input[name='signposted_as'][value='Unauthorized Attempt']"
             )

      assert has_element?(
               view,
               "#pathway-form select[name='pathway_mode'] option[value='7'][selected]"
             )
    end

    test "open_walkability_drawer accepts boarding areas nested under platform parents", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      boarding_a: boarding_a
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#child-stop-row-#{boarding_a.id} button[phx-click='open_walkability_drawer']")
      |> render_click()

      assert has_element?(view, "#walkability-test-form")
    end

    test "edit and delete walkability test succeed for boarding area nested under platform parent",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           walkability_test: walkability_test
         } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#walkability-test-stop-#{walkability_test.id}")
      |> render_click()

      assert has_element?(view, "#walkability-test-form button[type='submit']", "Save Test Case")

      view
      |> element("#walkability-test-delete-in-form")
      |> render_click()

      refute has_element?(view, "#walkability-test-row-#{walkability_test.id}")
      assert is_nil(Validations.get_walkability_test(walkability_test.id))
    end

    test "pathway mode options render in deterministic numeric order", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      nested_pathway: nested_pathway
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{nested_pathway.id} button[phx-click='edit_pathway']")
      |> render_click()

      Enum.each(1..7, fn mode ->
        assert has_element?(
                 view,
                 "#pathway-form select[name='pathway_mode'] option:nth-child(#{mode})[value='#{mode}']"
               )
      end)
    end
  end

  describe "StationDiagramLive - pathway pair behavior" do
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
          stop_id: "PAIR_STATION",
          stop_name: "Pair Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "PAIR_LEVEL_1",
          level_name: "Pair Level 1",
          level_index: 0.0
        })

      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id,
          diagram_filename: "pair-level.png"
        })

      stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PAIR_STOP_A",
          stop_name: "Pair Stop A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 12.0, "y" => 12.0}
        })

      stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PAIR_STOP_B",
          stop_name: "Pair Stop B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 12.0}
        })

      stop_c =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PAIR_STOP_C",
          stop_name: "Pair Stop C",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 40.0, "y" => 12.0}
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        stop_a: stop_a,
        stop_b: stop_b,
        stop_c: stop_c
      }
    end

    test "paired pathways render with thicker base stroke values", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b,
      stop_c: stop_c
    } do
      paired_1 =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      paired_2 =
        pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_a.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: false
        })

      single =
        pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_c.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      assert has_element?(
               view,
               "#pathways-#{paired_1.id} [data-pathway-line][data-base-stroke='0.54']"
             )

      assert has_element?(
               view,
               "#pathways-#{paired_2.id} [data-pathway-line][data-base-stroke='0.54']"
             )

      refute has_element?(
               view,
               "#pathways-#{single.id} [data-pathway-line][data-base-stroke='0.54']"
             )
    end

    test "paired pathway editing shows tabs and switching tabs changes form values", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      first =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      second =
        pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_a.stop_id, %{
          pathway_mode: 2,
          is_bidirectional: false
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{first.id} button[phx-click='edit_pathway']")
      |> render_click()

      assert has_element?(view, "#pathway-drawer header #pathway-pair-tabs")
      assert has_element?(view, "#pathway-drawer header #pathway-tab-first")
      assert has_element?(view, "#pathway-drawer header #pathway-tab-second")

      assert has_element?(
               view,
               "#pathway-form select[name='pathway_mode'] option[value='1'][selected]"
             )

      refute has_element?(view, "#add-second-pathway-btn")

      view
      |> element("#pathway-tab-second")
      |> render_click()

      assert has_element?(view, "#pathway-tab-second[aria-selected='true']")

      assert has_element?(
               view,
               "#pathway-form select[name='pathway_mode'] option[value='2'][selected]"
             )

      assert has_element?(
               view,
               "#pathway-form input[name='pathway_id'][value='#{second.pathway_id}']"
             )
    end

    test "add second pathway creates sibling and activates second tab", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      first =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 4,
          is_bidirectional: true
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{first.id} button[phx-click='edit_pathway']")
      |> render_click()

      assert has_element?(view, "#pathway-drawer header #add-second-pathway-btn")

      view
      |> element("#add-second-pathway-btn")
      |> render_click()

      pair_count =
        Gtfs.list_pathways_for_station(organization.id, gtfs_version.id, station.id)
        |> Enum.filter(fn pathway ->
          MapSet.new([pathway.from_stop_id, pathway.to_stop_id]) ==
            MapSet.new([stop_a.stop_id, stop_b.stop_id])
        end)
        |> length()

      assert pair_count == 2
      assert has_element?(view, "#pathway-drawer header #pathway-pair-tabs")
      assert has_element?(view, "#pathway-tab-second[aria-selected='true']")
      refute has_element?(view, "#add-second-pathway-btn")
    end

    test "dirty pathway form shows unsaved indicator and confirmation when switching forms", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      first =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      _second =
        pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_a.stop_id, %{
          pathway_mode: 2,
          is_bidirectional: false
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{first.id} button[phx-click='edit_pathway']")
      |> render_click()

      refute has_element?(view, "#pathway-dirty-indicator")
      refute has_element?(view, "#pathway-tab-second[data-confirm]")

      view
      |> form("#pathway-form", %{
        "traversal_time" => "123"
      })
      |> render_change()

      assert has_element?(view, "#pathway-dirty-indicator", "Unsaved changes")

      assert has_element?(
               view,
               "#pathway-tab-first[data-confirm='Discard unsaved pathway changes?']"
             )

      assert has_element?(
               view,
               "#pathway-tab-second[data-confirm='Discard unsaved pathway changes?']"
             )
    end

    test "saving a pathway in a two-pathway pair keeps the drawer open", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      first =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      second =
        pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_a.stop_id, %{
          pathway_mode: 2,
          is_bidirectional: false
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{second.id} button[phx-click='edit_pathway']")
      |> render_click()

      view
      |> form("#pathway-form", %{
        "pathway_mode" => "2",
        "is_bidirectional" => "false",
        "traversal_time" => "87",
        "length" => "",
        "stair_count" => "",
        "min_width" => "",
        "signposted_as" => "Saved While Paired"
      })
      |> render_submit()

      assert has_element?(view, "#pathway-form")
      assert has_element?(view, "#pathway-pair-tabs")
      assert has_element?(view, "#pathway-tab-second[aria-selected='true']")

      reloaded_first = Gtfs.get_pathway!(first.id)
      reloaded_second = Gtfs.get_pathway!(second.id)

      assert reloaded_first.id == first.id
      assert reloaded_second.traversal_time == 87
      assert reloaded_second.signposted_as == "Saved While Paired"
    end

    test "paired pathways render one combined signage label separated by //", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      first =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true,
          signposted_as: "Northbound",
          reversed_signposted_as: "Uptown"
        })

      second =
        pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_a.stop_id, %{
          pathway_mode: 3,
          is_bidirectional: true,
          signposted_as: "Express",
          reversed_signposted_as: "Downtown"
        })

      [primary, secondary] = Enum.sort_by([first, second], & &1.pathway_id, :asc)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      assert has_element?(
               view,
               "#pathways-#{primary.id} [data-pathway-label]",
               "Northbound // Express"
             )

      assert has_element?(
               view,
               "#pathways-#{primary.id} [data-pathway-label]",
               "Uptown // Downtown"
             )

      refute has_element?(view, "#pathways-#{secondary.id} [data-pathway-label]")
    end

    test "paired pathways with one blank signage render unnumbered single signage text", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      first =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true,
          signposted_as: "Local",
          reversed_signposted_as: nil
        })

      second =
        pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_a.stop_id, %{
          pathway_mode: 2,
          is_bidirectional: true,
          signposted_as: nil,
          reversed_signposted_as: nil
        })

      [primary, _secondary] = Enum.sort_by([first, second], & &1.pathway_id, :asc)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      assert has_element?(view, "#pathways-#{primary.id} [data-pathway-label]", "Local")
      refute has_element?(view, "#pathways-#{primary.id} [data-pathway-label]", "//")
      refute has_element?(view, "#pathways-#{primary.id} [data-pathway-label]", "1.")
      refute has_element?(view, "#pathways-#{primary.id} [data-pathway-label]", "2.")
    end

    test "connect mode creation is blocked when pair already has two pathways", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
        pathway_mode: 1,
        is_bidirectional: true
      })

      pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_a.stop_id, %{
        pathway_mode: 3,
        is_bidirectional: true
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      render_hook(view, "switch_mode", %{"mode" => "connect"})
      render_hook(view, "stop_clicked", %{"id" => stop_a.id})
      render_hook(view, "stop_clicked", %{"id" => stop_b.id})

      pair_count =
        Gtfs.list_pathways_for_station(organization.id, gtfs_version.id, station.id)
        |> Enum.filter(fn pathway ->
          MapSet.new([pathway.from_stop_id, pathway.to_stop_id]) ==
            MapSet.new([stop_a.stop_id, stop_b.stop_id])
        end)
        |> length()

      assert pair_count == 2

      assert has_element?(
               view,
               "#lists-section .text-error",
               "This stop pair already has two pathways"
             )
    end

    test "deleting one paired pathway keeps drawer open on remaining sibling without tabs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      first =
        pathway_fixture(organization.id, gtfs_version.id, stop_a.stop_id, stop_b.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      _second =
        pathway_fixture(organization.id, gtfs_version.id, stop_b.stop_id, stop_a.stop_id, %{
          pathway_mode: 6,
          is_bidirectional: false
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{first.id} button[phx-click='edit_pathway']")
      |> render_click()

      assert has_element?(view, "#pathway-pair-tabs")

      view
      |> element("button[phx-click='delete_pathway']")
      |> render_click()

      [remaining] =
        Gtfs.list_pathways_for_station(organization.id, gtfs_version.id, station.id)
        |> Enum.filter(fn pathway ->
          MapSet.new([pathway.from_stop_id, pathway.to_stop_id]) ==
            MapSet.new([stop_a.stop_id, stop_b.stop_id])
        end)

      assert has_element?(view, "#pathway-form")
      refute has_element?(view, "#pathway-pair-tabs")
      assert has_element?(view, "#add-second-pathway-btn")

      assert has_element?(
               view,
               "#pathway-form input[name='pathway_id'][value='#{remaining.pathway_id}']"
             )
    end
  end

  describe "StationDiagramLive - diagram measurement" do
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
          stop_id: "STATION_MEASURE",
          stop_name: "Measure Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_MEASURE_1",
          level_name: "Level 1",
          level_index: 0.0
        })

      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_MEASURE_2",
          level_name: "Level 2",
          level_index: 1.0
        })

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, stop_level_2} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "measure-level-1.png")
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level_2, "measure-level-2.png")

      stop_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "MEASURE_STOP_A",
          stop_name: "Measure Stop A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      stop_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "MEASURE_STOP_B",
          stop_name: "Measure Stop B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 13.0, "y" => 14.0}
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level,
        level_2: level_2,
        stop_a: stop_a,
        stop_b: stop_b
      }
    end

    test "establish scale control is available in view mode when diagram exists and ordered before mode switch",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      assert has_element?(view, "button[phx-click='toggle_measurement']", "Set Scale")

      assert has_element?(
               view,
               "#diagram-action-strip .ml-auto > button[phx-click='toggle_measurement'] + div.join button[phx-value-mode='view']"
             )

      assert has_element?(view, "#diagram-overlay[data-mode='view']")
    end

    test "establish scale control is hidden in non-view modes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      render_hook(view, "switch_mode", %{"mode" => "add"})

      refute has_element?(view, "button[phx-click='toggle_measurement']")
    end

    test "first click while establishing scale renders a draft endpoint", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("button[phx-click='toggle_measurement']") |> render_click()
      render_hook(view, "canvas_click", %{"x" => "20", "y" => "20"})

      assert has_element?(view, "#diagram-overlay circle[data-ruler-endpoint]")
      refute has_element?(view, "#diagram-overlay line[data-ruler-line]")
    end

    test "two clicks while establishing scale open ruler drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("button[phx-click='toggle_measurement']") |> render_click()
      render_hook(view, "canvas_click", %{"x" => "20", "y" => "20"})
      render_hook(view, "canvas_click", %{"x" => "30", "y" => "20"})

      assert has_element?(view, "#ruler-form")
    end

    test "saving ruler persists calibration and shows edit and clear scale controls", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("button[phx-click='toggle_measurement']") |> render_click()
      render_hook(view, "canvas_click", %{"x" => "10", "y" => "10"})
      render_hook(view, "canvas_click", %{"x" => "20", "y" => "10"})

      view
      |> form("#ruler-form", %{"ruler" => %{"distance_meters" => "25"}})
      |> render_submit()

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      refute is_nil(stop_level.scale_point_a)
      refute is_nil(stop_level.scale_point_b)
      assert has_element?(view, "button[phx-click='clear_calibration']", "Clear Scale")
    end

    test "saved scale label uses top-node anchor attributes with right offset", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      {:ok, _} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 10.0, "y" => 10.0},
          scale_point_b: %{"x" => 24.0, "y" => 30.0},
          scale_distance_meters: Decimal.new("25"),
          scale_meters_per_unit: Decimal.new("1.25")
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      html = render(view)
      assert html =~ ~r/data-ruler-label="true"/
      assert html =~ ~r/data-label-anchor-x="10(?:\.0)?"/
      assert html =~ ~r/data-label-anchor-y="10(?:\.0)?"/
      assert html =~ ~r/data-label-offset-x="0\.5"/
      assert html =~ ~r/text-anchor="start"/
      assert has_element?(view, "#diagram-overlay text[data-ruler-label]", "SCALE")
    end

    test "clear scale removes saved scale fields and returns establish action", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      {:ok, _} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 10.0, "y" => 10.0},
          scale_point_b: %{"x" => 20.0, "y" => 10.0},
          scale_distance_meters: Decimal.new("25"),
          scale_meters_per_unit: Decimal.new("2.5")
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#diagram-action-strip button[phx-click='clear_calibration']")
      |> render_click()

      cleared = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      assert is_nil(cleared.scale_point_a)
      assert is_nil(cleared.scale_point_b)
      assert has_element?(view, "button[phx-click='toggle_measurement']", "Set Scale")
    end

    test "editing scale recalculates same-level pathway lengths", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      stop_c =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "MEASURE_STOP_C_SAME",
          stop_name: "Measure Stop C Same",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 20.0}
        })

      existing_1 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          stop_a.stop_id,
          stop_b.stop_id,
          %{length: Decimal.new("999.00")}
        )

      existing_2 =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          stop_a.stop_id,
          stop_c.stop_id,
          %{length: Decimal.new("123.45")}
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("button[phx-click='toggle_measurement']", "Set Scale")
      |> render_click()

      render_hook(view, "canvas_click", %{"x" => "10", "y" => "10"})
      render_hook(view, "canvas_click", %{"x" => "20", "y" => "10"})

      view
      |> form("#ruler-form", %{"ruler" => %{"distance_meters" => "10"}})
      |> render_submit()

      updated_stop_level =
        Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      expected_1 = Gtfs.calculate_pathway_length(updated_stop_level, stop_a, stop_b)
      expected_2 = Gtfs.calculate_pathway_length(updated_stop_level, stop_a, stop_c)

      reloaded_1 = Gtfs.get_pathway!(existing_1.id)
      reloaded_2 = Gtfs.get_pathway!(existing_2.id)

      assert Decimal.equal?(reloaded_1.length, expected_1)
      assert Decimal.equal?(reloaded_2.length, expected_2)

      assert has_element?(
               view,
               "#scale-status",
               "Scale updated - 2 pathway length(s) recalculated"
             )
    end

    test "editing scale does not recalculate cross-level pathway lengths", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level_2: level_2,
      stop_a: stop_a
    } do
      stop_cross =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "MEASURE_STOP_CROSS_LEVEL",
          stop_name: "Measure Stop Cross",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 20.0}
        })

      pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          stop_a.stop_id,
          stop_cross.stop_id,
          %{length: Decimal.new("77.77")}
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("button[phx-click='toggle_measurement']", "Set Scale")
      |> render_click()

      render_hook(view, "canvas_click", %{"x" => "10", "y" => "10"})
      render_hook(view, "canvas_click", %{"x" => "20", "y" => "10"})

      view
      |> form("#ruler-form", %{"ruler" => %{"distance_meters" => "10"}})
      |> render_submit()

      reloaded_pathway = Gtfs.get_pathway!(pathway.id)
      assert Decimal.equal?(reloaded_pathway.length, Decimal.new("77.77"))
    end

    test "status region is accessible and updates on save and clear", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      refute has_element?(view, "#scale-status")

      view
      |> element("button[phx-click='toggle_measurement']", "Set Scale")
      |> render_click()

      render_hook(view, "canvas_click", %{"x" => "10", "y" => "10"})
      render_hook(view, "canvas_click", %{"x" => "20", "y" => "10"})

      view
      |> form("#ruler-form", %{"ruler" => %{"distance_meters" => "10"}})
      |> render_submit()

      assert has_element?(view, "#scale-status[role='status'][aria-live='polite']")
      assert has_element?(view, "#scale-status", "Scale updated -")

      view
      |> element("#diagram-action-strip button[phx-click='clear_calibration']", "Clear Scale")
      |> render_click()

      assert has_element?(view, "#scale-status", "Scale removed - pathway measurements unchanged")
    end

    test "dismiss button clears scale status message", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("button[phx-click='toggle_measurement']", "Set Scale")
      |> render_click()

      render_hook(view, "canvas_click", %{"x" => "10", "y" => "10"})
      render_hook(view, "canvas_click", %{"x" => "20", "y" => "10"})

      view
      |> form("#ruler-form", %{"ruler" => %{"distance_meters" => "10"}})
      |> render_submit()

      assert has_element?(view, "#scale-status", "Scale updated -")

      view
      |> element("button[phx-click='dismiss_scale_status']")
      |> render_click()

      refute has_element?(view, "#scale-status")
    end

    test "switching level clears in-progress measurement state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level_2: level_2
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("button[phx-click='toggle_measurement']") |> render_click()
      render_hook(view, "canvas_click", %{"x" => "15", "y" => "15"})
      render_hook(view, "switch_level", %{"level_id" => level_2.id})

      assert has_element?(view, "button[phx-click='toggle_measurement']", "Set Scale")
      assert has_element?(view, "#diagram-action-strip", "Click a stop to view or edit")
    end

    test "same-level pathway creation auto-populates length when calibrated", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      {:ok, _} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 0.0, "y" => 0.0},
          scale_point_b: %{"x" => 10.0, "y" => 0.0},
          scale_distance_meters: Decimal.new("20"),
          scale_meters_per_unit: Decimal.new("2")
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      render_hook(view, "switch_mode", %{"mode" => "connect"})
      render_hook(view, "stop_clicked", %{"id" => stop_a.id})
      render_hook(view, "stop_clicked", %{"id" => stop_b.id})

      assert has_element?(view, "#pathway-form input[name='length'][value='10.00']")
    end

    test "edit pathway with configured scale and blank length shows calculate length action", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      {:ok, _} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 0.0, "y" => 0.0},
          scale_point_b: %{"x" => 10.0, "y" => 0.0},
          scale_distance_meters: Decimal.new("20"),
          scale_meters_per_unit: Decimal.new("2")
        })

      pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          stop_a.stop_id,
          stop_b.stop_id,
          %{length: nil}
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{pathway.id} button[phx-click='edit_pathway']")
      |> render_click()

      assert has_element?(
               view,
               "#pathway-form button[phx-click='calculate_pathway_length']",
               "Calculate length?"
             )
    end

    test "clicking calculate length populates pathway form length without persisting", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      {:ok, _} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 0.0, "y" => 0.0},
          scale_point_b: %{"x" => 10.0, "y" => 0.0},
          scale_distance_meters: Decimal.new("20"),
          scale_meters_per_unit: Decimal.new("2")
        })

      pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          stop_a.stop_id,
          stop_b.stop_id,
          %{length: nil}
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{pathway.id} button[phx-click='edit_pathway']")
      |> render_click()

      view
      |> element("#pathway-form button[phx-click='calculate_pathway_length']")
      |> render_click()

      assert has_element?(view, "#pathway-form")
      assert has_element?(view, "#pathway-form input[name='length'][value='10.00']")

      reloaded_pathway = Gtfs.get_pathway!(pathway.id)
      assert is_nil(reloaded_pathway.length)
    end

    test "calculate length action is hidden when length is already set", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      {:ok, _} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 0.0, "y" => 0.0},
          scale_point_b: %{"x" => 10.0, "y" => 0.0},
          scale_distance_meters: Decimal.new("20"),
          scale_meters_per_unit: Decimal.new("2")
        })

      pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          stop_a.stop_id,
          stop_b.stop_id,
          %{length: Decimal.new("7.50")}
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{pathway.id} button[phx-click='edit_pathway']")
      |> render_click()

      refute has_element?(view, "#pathway-form button[phx-click='calculate_pathway_length']")
    end

    test "calculate length action is hidden when scale is not configured", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_a: stop_a,
      stop_b: stop_b
    } do
      pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          stop_a.stop_id,
          stop_b.stop_id,
          %{length: nil}
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{pathway.id} button[phx-click='edit_pathway']")
      |> render_click()

      refute has_element?(view, "#pathway-form button[phx-click='calculate_pathway_length']")
    end

    test "calculate length fails for cross-level pathway and sets pathway error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      level_2: level_2,
      stop_a: stop_a
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      {:ok, _} =
        Gtfs.update_stop_level_scale(stop_level, %{
          scale_point_a: %{"x" => 0.0, "y" => 0.0},
          scale_point_b: %{"x" => 10.0, "y" => 0.0},
          scale_distance_meters: Decimal.new("20"),
          scale_meters_per_unit: Decimal.new("2")
        })

      stop_c =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "MEASURE_STOP_C",
          stop_name: "Measure Stop C",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 13.0, "y" => 14.0}
        })

      pathway =
        pathway_fixture(
          organization.id,
          gtfs_version.id,
          stop_a.stop_id,
          stop_c.stop_id,
          %{length: nil}
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view
      |> element("#pathway-row-#{pathway.id} button[phx-click='edit_pathway']")
      |> render_click()

      view
      |> element("#pathway-form button[phx-click='calculate_pathway_length']")
      |> render_click()

      refute has_element?(view, "#pathway-form input[name='length'][value='10.00']")

      assert has_element?(
               view,
               "span.text-error",
               "Length calculation requires stops on the same level."
             )
    end

    test "invalid mode payload does not crash", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      render_hook(view, "switch_mode", %{"mode" => "nope"})
      assert has_element?(view, "#diagram-page")
    end
  end

  describe "StationDiagramLive - diagram upload error handling" do
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
          stop_id: "STATION_UPLOAD_ERRORS",
          stop_name: "Upload Error Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_UPLOAD_ERRORS",
          level_name: "Upload Level",
          level_index: 0.0
        })

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
        station: station
      }
    end

    test "invalid file type selection shows explicit validation error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      upload =
        file_input(view, "#diagram-upload-form-sub-nav", :diagram, [
          %{name: "bad.gif", content: "gif-bytes", type: "image/gif"}
        ])

      render_upload(upload, "bad.gif")

      assert has_element?(
               view,
               "span.text-error",
               "File type not accepted (PNG, JPG, JPEG, SVG only)"
             )
    end

    test "oversized file selection shows explicit validation error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      upload =
        file_input(view, "#diagram-upload-form-sub-nav", :diagram, [
          %{name: "big.png", content: :binary.copy(<<0>>, 10_000_001), type: "image/png"}
        ])

      render_upload(upload, "big.png")

      assert has_element?(view, "span.text-error", "File is too large (max 10 MB)")
    end
  end

  describe "StationDiagramLive - diagram upload path safety" do
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
          stop_id: "STATION:UPLOAD:SAFE",
          stop_name: "Upload Safe Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L_UPLOAD_SAFE",
          level_name: "Upload Safe Level",
          level_index: 0.0
        })

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

    test "upload succeeds for stop_ids outside strict filename regex", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      upload_diagram(view, "floorplan.png", "safe storage payload")

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)

      assert stop_level.diagram_filename != nil

      station_dir = PathSafety.stop_storage_dir(station.stop_id)
      uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)

      stored_path =
        Path.join([
          uploads_path,
          "diagrams",
          to_string(organization.id),
          station_dir,
          stop_level.diagram_filename
        ])

      assert File.exists?(stored_path)
      refute has_element?(view, "span.text-error", "Invalid diagram upload path")
    end
  end

  defp setup_badge_and_line_fixtures(organization, gtfs_version, station, level) do
    level_2 =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "CLICK_PRECEDENCE_L2",
        level_name: "Click Precedence Level 2",
        level_index: 1.0
      })

    {:ok, _stop_level_2} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level_2.id,
        diagram_filename: "click-precedence-level-2.png"
      })

    # The badged stop on the active level (L1).
    badged_stop =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "CLICK_PRECEDENCE_BADGED",
        stop_name: "Click Precedence Badged",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 20.0, "y" => 20.0}
      })

    # Off-level stop so the pathway renders as a cross-level badge.
    level_2_stop =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "CLICK_PRECEDENCE_L2_STOP",
        stop_name: "Click Precedence L2",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level_2.level_id,
        diagram_coordinate: %{"x" => 60.0, "y" => 60.0}
      })

    # Two additional stops on the active level connected by a same-level pathway
    # that runs *near* the badged stop. The badge hit rect spans x ∈ [20.9, 21.8]
    # and y ∈ [19.55, 20.45]. The line at y = 18.5 passes underneath that rect
    # without overlapping it — this is the reported adjacency scenario. Under
    # the old 1.3 × 1.3 rect (y ∈ [19.35, 20.65]) the line's stroke-width-2 hit
    # band would have grazed the badge; under the new 0.9 × 0.9 rect it does not.
    line_from =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "CLICK_PRECEDENCE_LINE_FROM",
        stop_name: "Click Precedence Line From",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 15.0, "y" => 18.5}
      })

    line_to =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "CLICK_PRECEDENCE_LINE_TO",
        stop_name: "Click Precedence Line To",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 30.0, "y" => 18.5}
      })

    badge_pathway =
      pathway_fixture(
        organization.id,
        gtfs_version.id,
        badged_stop.stop_id,
        level_2_stop.stop_id,
        %{pathway_mode: 5, is_bidirectional: true}
      )

    line_pathway =
      pathway_fixture(
        organization.id,
        gtfs_version.id,
        line_from.stop_id,
        line_to.stop_id,
        %{pathway_mode: 1, is_bidirectional: true}
      )

    %{badge_pathway: badge_pathway, line_pathway: line_pathway}
  end

  defp upload_diagram(view, filename, content, form_selector \\ "#diagram-upload-form-sub-nav") do
    upload =
      file_input(view, form_selector, :diagram, [
        %{
          name: filename,
          content: content,
          type: "image/png"
        }
      ])

    render_upload(upload, filename)
  end

  # ============================================================================
  # Naming drawer tests
  # ============================================================================

  describe "StationDiagramLive - naming drawer" do
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
          stop_id: "NAMING_STATION",
          stop_name: "Naming Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "ground",
          level_name: "Ground",
          level_index: 0.0
        })

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

    test "Apply naming button is present in toolbar", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, _view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      assert html =~ "Apply naming"
    end

    test "clicking Apply naming opens drawer with name-based preview by default", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_N1",
          stop_name: "Child N1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      html = render_click(view, "open_naming_drawer")

      assert html =~ "naming-drawer"
      assert html =~ "CHILD_N1"
      assert html =~ "child-n1-01"
      assert html =~ "Apply naming convention"
      assert html =~ "kebab-case"
    end

    test "changing naming style refreshes preview rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STYLE_CHILD",
          stop_name: "Style Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 11.0, "y" => 11.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      html = render_click(view, "open_naming_drawer")
      assert html =~ "kebab-case"
      assert html =~ "style-child-01"
      refute html =~ "deterministic convention"
      refute html =~ "naming_station_platform_general_ground_01"

      html = view |> element("button", "Name-based") |> render_click()
      assert html =~ "kebab-case"
      assert html =~ "style-child-01"
      refute html =~ "deterministic convention"
      refute html =~ "naming_station_platform_general_ground_01"

      html = view |> element("button", "Structured") |> render_click()
      assert html =~ "deterministic convention"
      assert html =~ "naming_station_platform_general_ground_01"
      refute html =~ "kebab-case"
      refute html =~ "style-child-01"
    end

    test "Apply naming convention uses selected naming style", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "RENAME_ME",
          stop_name: "Rename Me",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 20.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("[phx-click='open_naming_drawer']") |> render_click()
      view |> element("button", "Name-based") |> render_click()
      html = view |> element("button", "Apply naming convention") |> render_click()

      assert html =~ "Renamed 1 child stop"
      assert html =~ "updated 0 pathway references"

      assert Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, child.stop_id) == nil

      assert Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, "rename-me-01")
    end

    test "excluding a row updates selection and pathway counts", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _path_child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PATH_CHILD",
          stop_name: "Path Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 12.0, "y" => 12.0}
        })

      _other_child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_CHILD",
          stop_name: "Other Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 18.0, "y" => 18.0}
        })

      _pathway =
        pathway_fixture(organization.id, gtfs_version.id, "PATH_CHILD", station.stop_id, %{
          pathway_mode: 1
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      html = render_click(view, "open_naming_drawer")
      assert html =~ ~r/>\s*2\s*<\/span>\s*child stops\s*will be renamed\./s
      assert html =~ ~r/>\s*1\s*<\/span>\s*pathway reference\s*will be updated\./s

      assert has_element?(
               view,
               "input[aria-label='Select all child stops for renaming'][checked]"
             )

      assert has_element?(view, "input[aria-label='Select PATH_CHILD for renaming'][checked]")

      html =
        view
        |> element("input[aria-label='Select PATH_CHILD for renaming']")
        |> render_click()

      assert html =~
               ~r/>\s*1\s*<\/span>\s*of\s*<span[^>]*>\s*2\s*<\/span>\s*child stops selected for renaming\./s

      assert html =~
               ~r/>\s*0\s*<\/span>\s*pathway references\s*will be updated for the selected stops\./s

      assert has_element?(view, "#naming-row-PATH_CHILD.opacity-40")

      refute has_element?(
               view,
               "input[aria-label='Select all child stops for renaming'][checked]"
             )

      refute has_element?(view, "input[aria-label='Select PATH_CHILD for renaming'][checked]")
      assert has_element?(view, "input[aria-label='Select OTHER_CHILD for renaming'][checked]")
    end

    test "select all toggles all naming rows on and off", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _child_a =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ALL_CHILD_A",
          stop_name: "All Child A",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 14.0, "y" => 14.0}
        })

      _child_b =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ALL_CHILD_B",
          stop_name: "All Child B",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 22.0, "y" => 22.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("[phx-click='open_naming_drawer']") |> render_click()

      html =
        view
        |> element("input[aria-label='Select all child stops for renaming']")
        |> render_click()

      assert html =~
               ~r/>\s*0\s*<\/span>\s*of\s*<span[^>]*>\s*2\s*<\/span>\s*child stops selected for renaming\./s

      assert has_element?(view, "#naming-row-ALL_CHILD_A.opacity-40")
      assert has_element?(view, "#naming-row-ALL_CHILD_B.opacity-40")
      assert has_element?(view, "button[phx-click='apply_naming_convention'][disabled]")

      html =
        view
        |> element("input[aria-label='Select all child stops for renaming']")
        |> render_click()

      assert html =~ ~r/>\s*2\s*<\/span>\s*child stops\s*will be renamed\./s
      refute has_element?(view, "#naming-row-ALL_CHILD_A.opacity-40")
      refute has_element?(view, "#naming-row-ALL_CHILD_B.opacity-40")
      refute has_element?(view, "button[phx-click='apply_naming_convention'][disabled]")
    end

    test "selection resets when closing the drawer or changing naming style", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "RESET_CHILD",
          stop_name: "Reset Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 16.0, "y" => 16.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("[phx-click='open_naming_drawer']") |> render_click()
      view |> element("button", "Structured") |> render_click()
      view |> element("input[aria-label='Select RESET_CHILD for renaming']") |> render_click()
      assert has_element?(view, "#naming-row-RESET_CHILD.opacity-40")

      view |> element("button", "Cancel") |> render_click()
      html = view |> element("[phx-click='open_naming_drawer']") |> render_click()
      refute has_element?(view, "#naming-row-RESET_CHILD.opacity-40")
      assert has_element?(view, "input[aria-label='Select RESET_CHILD for renaming'][checked]")
      assert has_element?(view, "button.btn-primary", "Name-based")
      refute has_element?(view, "button.btn-primary", "Structured")
      assert html =~ "kebab-case"
      assert html =~ "reset-child-01"
      refute html =~ "deterministic convention"

      view |> element("input[aria-label='Select RESET_CHILD for renaming']") |> render_click()
      assert has_element?(view, "#naming-row-RESET_CHILD.opacity-40")

      html = view |> element("button", "Name-based") |> render_click()
      refute has_element?(view, "#naming-row-RESET_CHILD.opacity-40")
      assert has_element?(view, "input[aria-label='Select RESET_CHILD for renaming'][checked]")
      assert html =~ "reset-child-01"
    end

    test "applying naming from the drawer only renames selected rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      selected_child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "SUBSET_SELECTED",
          stop_name: "Subset Selected",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 24.0, "y" => 24.0}
        })

      unselected_child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "SUBSET_UNSELECTED",
          stop_name: "Subset Unselected",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 28.0, "y" => 28.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("[phx-click='open_naming_drawer']") |> render_click()
      view |> element("button", "Structured") |> render_click()

      view
      |> element("input[aria-label='Select SUBSET_UNSELECTED for renaming']")
      |> render_click()

      html = view |> element("button", "Apply naming convention") |> render_click()

      assert html =~ "Renamed 1 child stop"

      assert Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, selected_child.stop_id) ==
               nil

      assert Gtfs.get_stop_by_stop_id(
               organization.id,
               gtfs_version.id,
               "naming_station_platform_general_ground_01"
             )

      assert Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, unselected_child.stop_id)
      refute Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, "subset-unselected-01")

      html = view |> element("[phx-click='open_naming_drawer']") |> render_click()

      assert has_element?(view, "button.btn-primary", "Name-based")
      refute has_element?(view, "button.btn-primary", "Structured")
      assert html =~ "kebab-case"
      assert html =~ "subset-unselected-01"
      refute html =~ "deterministic convention"
    end

    test "excluding a row surfaces subset collisions and disables apply", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _selected_child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "AAA_CHILD",
          stop_name: "AAA Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 24.0, "y" => 24.0}
        })

      blocker_id = "naming_station_platform_general_ground_01"

      _blocking_child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: blocker_id,
          stop_name: "Blocking Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 28.0, "y" => 28.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("[phx-click='open_naming_drawer']") |> render_click()
      view |> element("button", "Structured") |> render_click()

      html =
        view
        |> element("input[aria-label='Select #{blocker_id} for renaming']")
        |> render_click()

      assert html =~ "Naming collision detected: #{blocker_id}"
      assert has_element?(view, "button[phx-click='apply_naming_convention'][disabled]")
    end

    test "drawer shows no-stops message when station has no children", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      html = render_click(view, "open_naming_drawer")

      assert html =~ "No child stops to rename"
    end

    test "drawer shows collision error without no-stops empty state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "COLLIDE_ME",
          stop_name: "Collide Me",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      _blocker =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "naming_station_platform_general_ground_01",
          stop_name: "Collision Blocker",
          location_type: 0
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("[phx-click='open_naming_drawer']") |> render_click()
      html = view |> element("button", "Structured") |> render_click()

      assert html =~ "Naming collision detected"
      refute html =~ "No child stops to rename"
    end

    test "dismiss clears status message", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DISMISS_ME",
          stop_name: "Dismiss Me",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 30.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      view |> element("[phx-click='open_naming_drawer']") |> render_click()
      view |> element("button", "Apply naming convention") |> render_click()

      html = view |> element("button", "Dismiss") |> render_click()
      refute html =~ "Renamed"
    end
  end

  describe "StationDiagramLive - drag events" do
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
          stop_id: "DRAG_STATION",
          stop_name: "Drag Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "DRAG_L1",
          level_name: "Drag Level 1",
          level_index: 0.0
        })

      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _updated_stop_level} = Gtfs.update_stop_level_diagram(stop_level, "drag-level.png")

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level
      }
    end

    test "drag_end persists new coordinates", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DRAG_CHILD_1",
          stop_name: "Drag Child 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 25.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "drag_start", %{"id" => to_string(child_stop.id)})

      render_hook(view, "drag_end", %{
        "id" => to_string(child_stop.id),
        "x" => "44.2",
        "y" => "55.8"
      })

      updated_stop = Gtfs.get_stop!(child_stop.id)
      assert updated_stop.diagram_coordinate == %{"x" => 44.2, "y" => 55.8}
    end

    test "drag_end reloads pathways", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      from_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DRAG_FROM",
          stop_name: "Drag From",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 20.0, "y" => 20.0}
        })

      to_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DRAG_TO",
          stop_name: "Drag To",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 80.0, "y" => 20.0}
        })

      pathway =
        pathway_fixture(organization.id, gtfs_version.id, from_stop.stop_id, to_stop.stop_id, %{
          pathway_mode: 1,
          is_bidirectional: true
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#pathways-#{pathway.id} [data-pathway-hit][x1='20.0']")

      render_hook(view, "drag_start", %{"id" => to_string(from_stop.id)})

      render_hook(view, "drag_end", %{
        "id" => to_string(from_stop.id),
        "x" => "30.0",
        "y" => "20.0"
      })

      refute has_element?(view, "#pathways-#{pathway.id} [data-pathway-hit][x1='20.0']")
      assert has_element?(view, "#pathways-#{pathway.id} [data-pathway-hit][x1='30.0']")

      assert has_element?(
               view,
               "#pathways-#{pathway.id}[data-from-stop-id='#{from_stop.id}'][data-to-stop-id='#{to_stop.id}']"
             ) or
               has_element?(
                 view,
                 "#pathways-#{pathway.id}[data-from-stop-id='#{to_stop.id}'][data-to-stop-id='#{from_stop.id}']"
               )
    end

    test "drag_end rejects out-of-range coordinates", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DRAG_CHILD_OOR",
          stop_name: "Drag Child OOR",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 40.0, "y" => 40.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "drag_start", %{"id" => to_string(child_stop.id)})

      render_hook(view, "drag_end", %{"id" => to_string(child_stop.id), "x" => "150", "y" => "55"})

      unchanged = Gtfs.get_stop!(child_stop.id)
      assert unchanged.diagram_coordinate == %{"x" => 40.0, "y" => 40.0}
      assert has_element?(view, "#flash-error", "Invalid drag position")
    end

    test "drag_cancel resets state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "DRAG_CHILD_CANCEL",
          stop_name: "Drag Child Cancel",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 60.0, "y" => 60.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "drag_start", %{"id" => to_string(child_stop.id)})
      render_hook(view, "drag_cancel", %{})
      render_hook(view, "drag_end", %{"id" => to_string(child_stop.id), "x" => "65", "y" => "65"})

      unchanged = Gtfs.get_stop!(child_stop.id)
      assert unchanged.diagram_coordinate == %{"x" => 60.0, "y" => 60.0}
      assert has_element?(view, "#flash-error", "Invalid drag position")
    end
  end

  describe "StationDiagramLive - search_stop" do
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
          stop_id: "SEARCH_STATION",
          stop_name: "Search Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "SEARCH_L1",
          level_name: "Level 1",
          level_index: 0.0
        })

      level_2 =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "SEARCH_L2",
          level_name: "Level 2",
          level_index: 1.0
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level.id
        })

      {:ok, _} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_2.id
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level,
        level_2: level_2
      }
    end

    test "search form is only shown in view mode with a diagram", %{
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

      refute has_element?(view, "#stop-search-form")

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "search-diagram.png")

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "#stop-search-form")

      render_hook(view, "switch_mode", %{"mode" => "add"})
      refute has_element?(view, "#stop-search-form")

      render_hook(view, "switch_mode", %{"mode" => "connect"})
      refute has_element?(view, "#stop-search-form")
    end

    test "search form submit handles valid and invalid query without crashing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "SEARCH_CHILD_SUBMIT",
          stop_name: "Search Child Submit",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 22.0, "y" => 33.0}
        })

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "search-submit-diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      valid_result =
        view
        |> form("#stop-search-form", %{
          "stop_id_query" => child_stop.stop_id
        })
        |> render_submit()

      assert valid_result =~ "Search Child Submit"
      assert valid_result =~ "SEARCH_CHILD_SUBMIT"

      view
      |> form("#stop-search-form", %{
        "stop_id_query" => "NONEXISTENT_SUBMIT_STOP"
      })
      |> render_submit()

      assert has_element?(view, "#flash-error", ~s(Stop "NONEXISTENT_SUBMIT_STOP" not found))

      assert has_element?(view, "#stop-search-form")
    end

    test "blank search query is ignored without flash or sidebar", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "search-blank-diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      refute has_element?(view, "#child-stop-drawer[open]")

      view
      |> form("#stop-search-form", %{"stop_id_query" => "   "})
      |> render_submit()

      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#child-stop-drawer[open]")
    end

    test "stop found on current level opens edit sidebar", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "SEARCH_CHILD_1",
          stop_name: "Search Child 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 30.0, "y" => 40.0}
        })

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "search-current-level-diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      result =
        view
        |> form("#stop-search-form", %{"stop_id_query" => child_stop.stop_id})
        |> render_submit()

      assert result =~ "Search Child 1"
      assert result =~ "SEARCH_CHILD_1"
      assert_push_event(view, "center_on_stop", %{x: 30.0, y: 40.0})

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.selected_stop_id == child_stop.id
      assert state.socket.assigns.active_level.id == level.id
    end

    test "stop found on different level switches level and opens sidebar", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      level_2: level_2
    } do
      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "SEARCH_CHILD_L2",
          stop_name: "Search Child L2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level_2.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "search-different-level-diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      result =
        view
        |> form("#stop-search-form", %{"stop_id_query" => child_stop.stop_id})
        |> render_submit()

      assert result =~ "Search Child L2"
      assert result =~ "SEARCH_CHILD_L2"
      assert_push_event(view, "center_on_stop", %{x: 50.0, y: 50.0})

      assert has_element?(
               view,
               "#diagram-action-strip form[phx-change='switch_level'] option[value='#{level_2.id}'][selected]"
             )

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.active_level.id == level_2.id
      assert state.socket.assigns.selected_stop_id == child_stop.id
    end

    test "stop not found shows flash error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "search-not-found-diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> form("#stop-search-form", %{"stop_id_query" => "NONEXISTENT_STOP"})
      |> render_submit()

      assert has_element?(view, "#flash-error", ~s(Stop "NONEXISTENT_STOP" not found))
    end

    test "stop belonging to different station shows flash error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      other_station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_STATION",
          stop_name: "Other Station",
          location_type: 1
        })

      _other_child =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "OTHER_CHILD",
          stop_name: "Other Child",
          location_type: 0,
          parent_station: other_station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 10.0, "y" => 10.0}
        })

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "search-other-station-diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> form("#stop-search-form", %{"stop_id_query" => "OTHER_CHILD"})
      |> render_submit()

      assert has_element?(
               view,
               "#flash-error",
               ~s(Stop "OTHER_CHILD" does not belong to this station)
             )
    end

    test "stop with no diagram position shows flash error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _no_coord_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NO_COORD_CHILD",
          stop_name: "No Coord Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: nil
        })

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "search-no-coord-diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> form("#stop-search-form", %{"stop_id_query" => "NO_COORD_CHILD"})
      |> render_submit()

      assert has_element?(
               view,
               "#flash-error",
               ~s(Stop "NO_COORD_CHILD" has no diagram position)
             )
    end

    test "stop on unknown station level shows flash error", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      _orphan_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ORPHAN_LEVEL_CHILD",
          stop_name: "Orphan Level Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "UNKNOWN_LEVEL",
          diagram_coordinate: %{"x" => 14.0, "y" => 28.0}
        })

      stop_level = Gtfs.get_stop_level(organization.id, gtfs_version.id, station.id, level.id)
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "search-orphan-level-diagram.png")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      view
      |> form("#stop-search-form", %{"stop_id_query" => "ORPHAN_LEVEL_CHILD"})
      |> render_submit()

      assert has_element?(
               view,
               "#flash-error",
               ~s(Stop "ORPHAN_LEVEL_CHILD" is not assigned to a known station level)
             )
    end

    test "malformed search_stop payload is ignored", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "search_stop", %{"stop_id_query" => 123})
      render_hook(view, "search_stop", %{})

      refute has_element?(view, "#flash-error")
    end
  end

  describe "StationDiagramLive - map mode" do
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
          stop_id: "MAP_STATION",
          stop_name: "Map Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "map_level",
          level_name: "Map Level",
          level_index: 0.0
        })

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

    test "mode_toggle renders a Map button", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "button[phx-value-mode='map']", "Map")
    end

    test "Map button is disabled when no diagram file exists", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      assert has_element?(view, "button[phx-value-mode='map'][disabled]")
    end

    test "switch_mode to map swaps to the map canvas", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, ".map-canvas")
      refute has_element?(view, "[id^='diagram-canvas-']")
    end

    test "action strip shows map-mode hint", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(
               view,
               "#diagram-action-strip",
               "Align the floorplan over real-world imagery"
             )
    end

    test "canvas_click in map mode is a no-op", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "canvas_click", %{"x" => 50, "y" => 50})

      assert has_element?(view, "button[phx-value-mode='map'].bg-blue-600")
    end

    test "stop_clicked in map mode is a no-op", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "MAP_CHILD_1",
          stop_name: "Map Child 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 25.0, "y" => 35.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "stop_clicked", %{"id" => child_stop.id})

      assert has_element?(view, ".map-canvas")
    end

    test "switching from map back to view restores the diagram canvas", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "switch_mode", %{"mode" => "view"})

      assert has_element?(view, "[id^='diagram-canvas-']")
      refute has_element?(view, ".map-canvas")
    end

    test "map canvas renders the floorplan image", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, ".map-canvas img[src]")
    end

    test "map canvas renders the leaflet overlay container with hook wiring", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, ".map-canvas[phx-hook='MapAlignment'][phx-update='ignore']")
      assert has_element?(view, ".map-canvas #map-alignment-leaflet")
      assert has_element?(view, "#map-alignment-overlay img[alt='Level floorplan']")
    end

    test "map canvas exposes initial view data attributes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, station} =
        Gtfs.update_stop(station, %{
          stop_lat: Decimal.new("42.3601"),
          stop_lon: Decimal.new("-71.0589")
        })

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render(view)

      assert [_, lat] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-lat="([^"]+)"/, html)
      assert [_, lon] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-lon="([^"]+)"/, html)
      assert [_, zoom] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-zoom="([^"]+)"/, html)

      assert lat == to_string(station.stop_lat)
      assert lon == to_string(station.stop_lon)
      assert zoom == "19"
    end

    test "map canvas falls back to 0,0 when station lat/lon are nil", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, station} =
        Gtfs.update_stop(station, %{stop_lat: nil, stop_lon: nil})

      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render(view)

      assert [_, lat] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-lat="([^"]+)"/, html)
      assert [_, lon] = Regex.run(~r/id="map-canvas[^"]*"[^>]*data-initial-lon="([^"]+)"/, html)

      assert lat == "0"
      assert lon == "0"
    end

    test "map canvas renders the control strip elements", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, "#map-alignment-lat-input")
      assert has_element?(view, "#map-alignment-lon-input")
      assert has_element?(view, "#map-alignment-apply-center")
      assert has_element?(view, "#map-alignment-reset")
      assert has_element?(view, "#map-alignment-rotate-handle")
      assert has_element?(view, "#map-alignment-scale-handle")
    end

    test "save_alignment persists the four fields on the active stop_level", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      render_hook(view, "save_alignment", %{
        "center_lat" => 40.7128,
        "center_lon" => -74.0060,
        "scale_mpp" => 0.35,
        "rotation_deg" => 15.5
      })

      reloaded = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      assert_in_delta reloaded.floorplan_center_lat, 40.7128, 1.0e-6
      assert_in_delta reloaded.floorplan_center_lon, -74.0060, 1.0e-6
      assert_in_delta reloaded.floorplan_scale_mpp, 0.35, 1.0e-6
      assert_in_delta reloaded.floorplan_rotation_deg, 15.5, 1.0e-6
    end

    test "save_alignment rejects out-of-range lat and does not mutate the DB", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html =
        render_hook(view, "save_alignment", %{
          "center_lat" => 200,
          "center_lon" => 0,
          "scale_mpp" => 0.5,
          "rotation_deg" => 0
        })

      reloaded = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      assert reloaded.floorplan_center_lat == nil
      assert reloaded.floorplan_center_lon == nil
      assert reloaded.floorplan_scale_mpp == nil
      assert reloaded.floorplan_rotation_deg == nil

      assert html =~ "Could not save alignment"
    end

    test "clear_alignment nulls all four fields", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      {:ok, stop_level} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.0060,
          floorplan_scale_mpp: 0.35,
          floorplan_rotation_deg: 15.5
        })

      assert stop_level.floorplan_center_lat == 40.7128

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "clear_alignment", %{})

      reloaded = Repo.get!(GtfsPlanner.Gtfs.StopLevel, stop_level.id)

      assert reloaded.floorplan_center_lat == nil
      assert reloaded.floorplan_center_lon == nil
      assert reloaded.floorplan_scale_mpp == nil
      assert reloaded.floorplan_rotation_deg == nil
    end

    test "map canvas renders data-align-* attributes when alignment is set", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      {:ok, _stop_level} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.0060,
          floorplan_scale_mpp: 0.35,
          floorplan_rotation_deg: 15.5
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render(view)

      assert [_, lat] =
               Regex.run(~r/id="map-canvas[^"]*"[^>]*data-align-center-lat="([^"]+)"/, html)

      assert [_, lon] =
               Regex.run(~r/id="map-canvas[^"]*"[^>]*data-align-center-lon="([^"]+)"/, html)

      assert [_, mpp] =
               Regex.run(~r/id="map-canvas[^"]*"[^>]*data-align-scale-mpp="([^"]+)"/, html)

      assert [_, rot] =
               Regex.run(~r/id="map-canvas[^"]*"[^>]*data-align-rotation-deg="([^"]+)"/, html)

      assert String.to_float(lat) == 40.7128
      assert String.to_float(lon) == -74.0060
      assert String.to_float(mpp) == 0.35
      assert String.to_float(rot) == 15.5
    end

    test "map canvas omits data-align-* attributes when alignment is partial or nil", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render(view)

      [_, opening_tag] = Regex.run(~r/(<div[^>]*id="map-canvas[^"]*"[^>]*>)/, html)

      refute opening_tag =~ "data-align-center-lat"
      refute opening_tag =~ "data-align-center-lon"
      refute opening_tag =~ "data-align-scale-mpp"
      refute opening_tag =~ "data-align-rotation-deg"
    end

    test "save and clear buttons are present in map mode", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      assert has_element?(view, "#map-alignment-save")
      assert has_element?(view, "#map-alignment-clear")
    end

    test "set_image_natural_size with valid integers updates the image dimension assigns", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "set_image_natural_size", %{"w" => 1024, "h" => 768})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.floorplan_image_w == 1024
      assert assigns.floorplan_image_h == 768
    end

    test "set_image_natural_size coerces float payloads to positive integers", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "set_image_natural_size", %{"w" => 1024.7, "h" => 768.4})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.floorplan_image_w == 1024
      assert assigns.floorplan_image_h == 768
    end

    test "set_image_natural_size ignores non-positive payloads", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "set_image_natural_size", %{"w" => 0, "h" => -5})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.floorplan_image_w == nil
      assert assigns.floorplan_image_h == nil
    end

    test "apply_alignment with valid alignment and image dims persists stop lat/lon and flashes count",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: level,
           stop_level: stop_level
         } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      {:ok, _aligned} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.0060,
          floorplan_scale_mpp: 0.35,
          floorplan_rotation_deg: 0.0
        })

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "APPLY_CHILD_1",
          stop_name: "Apply Child 1",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "set_image_natural_size", %{"w" => 1024, "h" => 768})

      html = render_hook(view, "apply_alignment", %{})

      assert html =~ "Applied alignment to 1 stops"

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, child_stop.id)
      refute is_nil(reloaded.stop_lat)
      refute is_nil(reloaded.stop_lon)
    end

    test "apply_alignment without alignment shows error flash and makes no writes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NO_ALIGN_CHILD",
          stop_name: "No Align Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      original_lat = child_stop.stop_lat
      original_lon = child_stop.stop_lon

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})
      render_hook(view, "set_image_natural_size", %{"w" => 1024, "h" => 768})

      html = render_hook(view, "apply_alignment", %{})

      assert html =~ "Save alignment before applying"

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, child_stop.id)
      assert reloaded.stop_lat == original_lat
      assert reloaded.stop_lon == original_lon
    end

    test "apply_alignment without image dimensions shows error flash and makes no writes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    } do
      {:ok, _} = Gtfs.update_stop_level_diagram(stop_level, "map-diagram.png")

      {:ok, _aligned} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.0060,
          floorplan_scale_mpp: 0.35,
          floorplan_rotation_deg: 0.0
        })

      child_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "NO_DIMS_CHILD",
          stop_name: "No Dims Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id,
          diagram_coordinate: %{"x" => 50.0, "y" => 50.0}
        })

      original_lat = child_stop.stop_lat
      original_lon = child_stop.stop_lon

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram", on_error: :warn)

      render_hook(view, "switch_mode", %{"mode" => "map"})

      html = render_hook(view, "apply_alignment", %{})

      assert html =~ "Floorplan image not ready"

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, child_stop.id)
      assert reloaded.stop_lat == original_lat
      assert reloaded.stop_lon == original_lon
    end
  end
end
