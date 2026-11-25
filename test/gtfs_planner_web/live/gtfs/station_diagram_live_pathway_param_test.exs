defmodule GtfsPlannerWeb.Gtfs.StationDiagramLivePathwayParamTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

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
        stop_id: "PW_PARAM_STATION",
        stop_name: "Pathway Param Station",
        location_type: 1
      })

    ground_level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "L1",
        level_name: "Ground",
        level_index: 0.0
      })

    upper_level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "L2",
        level_name: "Upper",
        level_index: 1.0
      })

    {:ok, _ground_stop_level} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: ground_level.id
      })

    {:ok, _upper_stop_level} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: upper_level.id
      })

    ground_stop =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PW_GROUND_STOP",
        stop_name: "Ground Entrance",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: ground_level.level_id,
        diagram_coordinate: %{"x" => 20.0, "y" => 30.0}
      })

    upper_stop_a =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PW_UPPER_A",
        stop_name: "Upper Concourse",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: upper_level.level_id,
        diagram_coordinate: %{"x" => 40.0, "y" => 50.0}
      })

    upper_stop_b =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PW_UPPER_B",
        stop_name: "Upper Platform",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: upper_level.level_id,
        diagram_coordinate: %{"x" => 70.0, "y" => 50.0}
      })

    upper_pathway =
      pathway_fixture(
        organization.id,
        gtfs_version.id,
        upper_stop_a.stop_id,
        upper_stop_b.stop_id,
        %{pathway_id: "pw_upper_walkway", pathway_mode: 1}
      )

    cross_level_pathway =
      pathway_fixture(
        organization.id,
        gtfs_version.id,
        ground_stop.stop_id,
        upper_stop_a.stop_id,
        %{pathway_id: "pw_elevator_l1_l2", pathway_mode: 5}
      )

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      ground_level: ground_level,
      upper_level: upper_level,
      upper_stop_a: upper_stop_a,
      upper_pathway: upper_pathway,
      cross_level_pathway: cross_level_pathway
    }
  end

  test "mounting with valid edit_pathway_id switches to pathway level, opens drawer, and clears param",
       %{
         conn: conn,
         user: user,
         organization: organization,
         gtfs_version: gtfs_version,
         station: station,
         upper_level: upper_level,
         upper_pathway: upper_pathway
       } do
    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} = live(conn, "#{base_path}?edit_pathway_id=#{upper_pathway.id}")

    assert has_element?(view, "#pathway-form")

    assert has_element?(
             view,
             "#pathway-form input[name='pathway_id'][value='#{upper_pathway.pathway_id}']"
           )

    assert has_element?(
             view,
             "#level-control button[data-level-id='L2'][aria-current='true']"
           )

    refute has_element?(
             view,
             "#level-control button[data-level-id='L1'][aria-current='true']"
           )

    assert_patch(view, base_path)

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.active_level.id == upper_level.id
    assert state.socket.assigns.show_pathway_drawer == true
    assert state.socket.assigns.editing_pathway.id == upper_pathway.id

    render_hook(view, "close_pathway_drawer", %{})
    refute has_element?(view, "#pathway-form")
  end

  test "mounting with explicit valid level and edit_pathway_id keeps the requested level", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station,
    upper_level: upper_level,
    cross_level_pathway: cross_level_pathway
  } do
    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} =
      live(conn, "#{base_path}?level=L2&edit_pathway_id=#{cross_level_pathway.id}")

    assert has_element?(
             view,
             "#pathway-form input[name='pathway_id'][value='#{cross_level_pathway.pathway_id}']"
           )

    assert has_element?(
             view,
             "#level-control button[data-level-id='L2'][aria-current='true']"
           )

    assert_patch(view, base_path)

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.active_level.id == upper_level.id
  end

  test "mounting with edit_pathway_id falls back to to_stop level when from_stop has no level", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station,
    upper_level: upper_level,
    upper_stop_a: upper_stop_a
  } do
    unleveled_stop =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PW_NO_LEVEL_STOP",
        stop_name: "Unleveled Node",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: nil
      })

    pathway =
      pathway_fixture(
        organization.id,
        gtfs_version.id,
        unleveled_stop.stop_id,
        upper_stop_a.stop_id,
        %{pathway_id: "pw_fallback_to_level", pathway_mode: 1}
      )

    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} = live(conn, "#{base_path}?edit_pathway_id=#{pathway.id}")

    assert has_element?(
             view,
             "#pathway-form input[name='pathway_id'][value='#{pathway.pathway_id}']"
           )

    assert_patch(view, base_path)

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.active_level.id == upper_level.id
  end

  test "simultaneous edit_pathway_id and journal=open opens only the pathway drawer", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station,
    upper_pathway: upper_pathway
  } do
    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} =
      live(conn, "#{base_path}?edit_pathway_id=#{upper_pathway.id}&journal=open")

    render_async(view, 5_000)

    assert has_element?(
             view,
             "#pathway-form input[name='pathway_id'][value='#{upper_pathway.pathway_id}']"
           )

    refute has_element?(view, "#station-journal-panel")
    assert_patch(view, base_path)
  end

  test "patching an already-loaded session to edit_pathway_id switches level and opens drawer", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station,
    upper_level: upper_level,
    upper_pathway: upper_pathway
  } do
    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} = live(conn, base_path)

    assert has_element?(
             view,
             "#level-control button[data-level-id='L1'][aria-current='true']"
           )

    refute has_element?(view, "#pathway-form")

    render_patch(view, "#{base_path}?edit_pathway_id=#{upper_pathway.id}")

    assert has_element?(
             view,
             "#pathway-form input[name='pathway_id'][value='#{upper_pathway.pathway_id}']"
           )

    assert has_element?(
             view,
             "#level-control button[data-level-id='L2'][aria-current='true']"
           )

    assert_patch(view, base_path)

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.active_level.id == upper_level.id
    assert state.socket.assigns.station.id == station.id
  end

  test "patching edit_pathway_id in add mode preserves add mode and leaves pathway drawer closed",
       %{
         conn: conn,
         user: user,
         organization: organization,
         gtfs_version: gtfs_version,
         station: station,
         ground_level: ground_level,
         upper_pathway: upper_pathway
       } do
    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} = live(conn, base_path)
    render_hook(view, "switch_mode", %{"mode" => "add"})

    render_patch(view, "#{base_path}?level=L2&edit_pathway_id=#{upper_pathway.id}")

    refute has_element?(view, "#pathway-form")
    refute has_element?(view, "#flash-error")

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.mode == :add
    assert state.socket.assigns.active_level.id == ground_level.id
  end

  test "patching edit_pathway_id while measurement is enabled preserves measurement mode", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station,
    ground_level: ground_level,
    upper_pathway: upper_pathway
  } do
    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} = live(conn, base_path)
    render_hook(view, "toggle_measurement", %{})

    assert :sys.get_state(view.pid).socket.assigns.measurement_enabled == true

    render_patch(view, "#{base_path}?level=L2&edit_pathway_id=#{upper_pathway.id}")

    refute has_element?(view, "#pathway-form")
    refute has_element?(view, "#flash-error")

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.measurement_enabled == true
    assert state.socket.assigns.active_level.id == ground_level.id
  end

  test "malformed non-UUID edit_pathway_id flashes generic error and keeps diagram usable", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station
  } do
    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} = live(conn, "#{base_path}?edit_pathway_id=not-a-uuid")

    refute has_element?(view, "#pathway-form")
    assert has_element?(view, "#flash-error", "Pathway not found.")

    render_patch(view, "#{base_path}?level=L2")

    assert has_element?(
             view,
             "#level-control button[data-level-id='L2'][aria-current='true']"
           )
  end

  test "unknown UUID edit_pathway_id flashes generic error without opening drawer", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station
  } do
    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} = live(conn, "#{base_path}?edit_pathway_id=#{Ecto.UUID.generate()}")

    refute has_element?(view, "#pathway-form")
    assert has_element?(view, "#flash-error", "Pathway not found.")
  end

  test "pathway belonging to another station in the same version flashes generic error", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station
  } do
    other_station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PW_OTHER_STATION",
        stop_name: "Other Station",
        location_type: 1
      })

    other_stop_a =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PW_OTHER_A",
        stop_name: "Other A",
        location_type: 3,
        parent_station: other_station.stop_id
      })

    other_stop_b =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PW_OTHER_B",
        stop_name: "Other B",
        location_type: 0,
        parent_station: other_station.stop_id
      })

    other_station_pathway =
      pathway_fixture(
        organization.id,
        gtfs_version.id,
        other_stop_a.stop_id,
        other_stop_b.stop_id,
        %{pathway_id: "pw_other_station", pathway_mode: 1}
      )

    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} =
      live(conn, "#{base_path}?edit_pathway_id=#{other_station_pathway.id}")

    refute has_element?(view, "#pathway-form")
    assert has_element?(view, "#flash-error", "Pathway not found.")
  end

  test "pathway belonging to another GTFS version flashes generic error", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station
  } do
    other_version = gtfs_version_fixture(organization.id)

    other_version_station =
      stop_fixture(organization.id, other_version.id, %{
        stop_id: station.stop_id,
        stop_name: "Same Station Other Version",
        location_type: 1
      })

    other_version_a =
      stop_fixture(organization.id, other_version.id, %{
        stop_id: "PW_VER_A",
        stop_name: "Other Version A",
        location_type: 3,
        parent_station: other_version_station.stop_id
      })

    other_version_b =
      stop_fixture(organization.id, other_version.id, %{
        stop_id: "PW_VER_B",
        stop_name: "Other Version B",
        location_type: 0,
        parent_station: other_version_station.stop_id
      })

    other_version_pathway =
      pathway_fixture(
        organization.id,
        other_version.id,
        other_version_a.stop_id,
        other_version_b.stop_id,
        %{pathway_id: "pw_other_version", pathway_mode: 1}
      )

    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} =
      live(conn, "#{base_path}?edit_pathway_id=#{other_version_pathway.id}")

    refute has_element?(view, "#pathway-form")
    assert has_element?(view, "#flash-error", "Pathway not found.")
  end

  test "pathway belonging to another organization flashes generic error", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: gtfs_version,
    station: station
  } do
    other_org = organization_fixture()
    other_org_version = gtfs_version_fixture(other_org.id)

    other_org_station =
      stop_fixture(other_org.id, other_org_version.id, %{
        stop_id: station.stop_id,
        stop_name: "Foreign Org Station",
        location_type: 1
      })

    other_org_a =
      stop_fixture(other_org.id, other_org_version.id, %{
        stop_id: "PW_ORG_A",
        stop_name: "Foreign Org A",
        location_type: 3,
        parent_station: other_org_station.stop_id
      })

    other_org_b =
      stop_fixture(other_org.id, other_org_version.id, %{
        stop_id: "PW_ORG_B",
        stop_name: "Foreign Org B",
        location_type: 0,
        parent_station: other_org_station.stop_id
      })

    other_org_pathway =
      pathway_fixture(
        other_org.id,
        other_org_version.id,
        other_org_a.stop_id,
        other_org_b.stop_id,
        %{pathway_id: "pw_other_org", pathway_mode: 1}
      )

    conn = log_in_user(conn, user, organization: organization)
    base_path = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

    {:ok, view, _html} =
      live(conn, "#{base_path}?edit_pathway_id=#{other_org_pathway.id}")

    refute has_element?(view, "#pathway-form")
    assert has_element?(view, "#flash-error", "Pathway not found.")
  end
end
