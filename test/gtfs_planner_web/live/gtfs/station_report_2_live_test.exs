defmodule GtfsPlannerWeb.Gtfs.StationReport2LiveTest.ControlledSnapshotSource do
  @moduledoc """
  Report snapshot boundary double used only by the lifecycle tests.

  Every call announces itself to the controlling test process and then blocks
  until that test releases it, so a test can hold one load open while starting
  another and decide the completion order. The task traps exits so that a
  `cancel_async/2` does not kill it: a released, already-cancelled task then
  really does deliver a completion the LiveView must refuse.
  """

  def get_station_report_snapshot(organization_id, gtfs_version_id, stop_id) do
    Process.flag(:trap_exit, true)
    owner = Application.fetch_env!(:gtfs_planner, :station_report_snapshot_owner)
    send(owner, {:snapshot_requested, self(), stop_id})

    receive do
      {:snapshot_release, :real} ->
        GtfsPlanner.Gtfs.get_station_report_snapshot(organization_id, gtfs_version_id, stop_id)

      {:snapshot_release, result} ->
        result
    after
      2_000 -> {:error, :release_timeout}
    end
  end
end

defmodule GtfsPlannerWeb.Gtfs.StationReport2LiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlannerWeb.Gtfs.StationReport2LiveTest.ControlledSnapshotSource

  @long_stop_name "Northbound Interchange Concourse Generic Circulation Node Under Reconstruction"

  defp live_report(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {view, render_async(view, 5_000)}
  end

  defp control_snapshot_source do
    Application.put_env(:gtfs_planner, :station_report_snapshot_source, ControlledSnapshotSource)
    Application.put_env(:gtfs_planner, :station_report_snapshot_owner, self())

    on_exit(fn ->
      Application.delete_env(:gtfs_planner, :station_report_snapshot_source)
      Application.delete_env(:gtfs_planner, :station_report_snapshot_owner)
    end)

    :ok
  end

  defp await_load(stop_id) do
    assert_receive {:snapshot_requested, task_pid, ^stop_id}, 2_000
    task_pid
  end

  defp release_load(task_pid, result) do
    send(task_pid, {:snapshot_release, result})
    :ok
  end

  describe "StationReport2Live" do
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
          stop_name: "Station One",
          location_type: 1,
          parent_station: nil
        })

      _level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Street",
          level_index: 0.0
        })

      entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_1",
          stop_name: "Entrance",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_1",
          stop_name: "Platform",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      _pathway =
        pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, platform.stop_id, %{
          pathway_id: "PATH_1",
          pathway_mode: 5,
          is_bidirectional: true
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "renders report route with all section IDs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#station-sub-nav")
      assert has_element?(view, "#station-report-2")
      assert has_element?(view, "#report2-station-inventory")
      assert has_element?(view, "#report2-data-quality")
      assert has_element?(view, "#report2-gps-checks")
      assert has_element?(view, "#report2-naming-conventions")
      assert has_element?(view, "#report2-reachability-connectivity")
      assert has_element?(view, "#report2-pathway-field-completeness")
    end

    test "sections render in correct order", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {_view, html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      section_ids = [
        "report2-station-inventory",
        "report2-data-quality",
        "report2-gps-checks",
        "report2-naming-conventions",
        "report2-reachability-connectivity",
        "report2-pathway-field-completeness"
      ]

      positions =
        Enum.map(section_ids, fn id ->
          case :binary.match(html, id) do
            {pos, _len} -> pos
            :nomatch -> flunk("Section #{id} not found in HTML")
          end
        end)

      assert positions == Enum.sort(positions),
             "Sections are not in the expected order"
    end

    test "Reports tab is active on report route", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(
               view,
               "#station-sub-nav a[aria-current='page']",
               "Reports"
             )
    end

    test "station nav has one reports tab and no legacy label", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      report_href = "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report"

      {view, html} = live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(
               view,
               "#station-sub-nav a[href='#{report_href}'][aria-current='page']",
               "Reports"
             )

      refute html =~ "Reports New"
      assert length(:binary.matches(html, report_href)) == 1
    end

    test "legacy report route is not defined", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      conn = get(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report_2")
      assert conn.status == 404
    end

    test "data quality section renders real check rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, html} = live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Check that known check labels appear
      assert html =~ "Isolated nodes"
      assert html =~ "Boarding areas must have platform parent"
      assert html =~ "Unique stop IDs"
      assert html =~ "Minimum station children"

      # Status is readable as a word, carried by the shared status vocabulary.
      assert has_element?(view, "#report2-data-quality [data-status='pass']", "Pass")
    end

    test "GPS section renders real check rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, html} = live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # GPS check labels
      assert html =~ "GPS presence by location type"
      assert html =~ "Longitude sign consistency"

      # GPS table headers
      assert html =~ "Present"
      assert html =~ "Missing"

      # GPS section states each status in words
      assert has_element?(view, "#report2-gps-checks [data-status='pass']", "Pass")
    end

    test "stop name links use phx-click select_entity", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Stop-name links use phx-click="select_entity" instead of navigation hrefs
      assert has_element?(view, "[phx-click='select_entity'][phx-value-entity_type='stop']")
    end

    test "detail links show stop-name text and title with raw stop_id", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_DL",
          stop_name: "Detail Link Station",
          location_type: 1,
          stop_lat: Decimal.new("47.0"),
          stop_lon: Decimal.new("122.0")
        })

      _entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_DL",
          stop_name: "Entrance Detail",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L_DL",
          stop_lat: Decimal.new("47.0"),
          stop_lon: Decimal.new("-122.0001")
        })

      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # The stop-name link shows the human-readable name, not the raw ID
      assert has_element?(
               view,
               "[phx-click='select_entity'][phx-value-entity_id='ENT_DL']",
               "Entrance Detail"
             )

      # The title attribute exposes the raw stop_id for inspection
      assert has_element?(
               view,
               "[phx-click='select_entity'][phx-value-entity_id='ENT_DL'][title='ENT_DL']"
             )
    end

    test "clicking a detail link opens the entity drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      refute has_element?(view, "#report-stop-edit-form")

      # Click a stop-name link to open the drawer
      view
      |> element("[phx-click='select_entity'][phx-value-entity_type='stop']", "Entrance")
      |> render_click()

      # Derived native root
      assert has_element?(view, "dialog#report-entity-drawer-overlay")
      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")

      # Inner panel preserves caller-facing ID
      assert has_element?(view, "#report-entity-drawer")
      assert has_element?(view, "#report-stop-edit-form")
    end

    test "closing the entity drawer hides the form", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Open the drawer
      view
      |> element("[phx-click='select_entity'][phx-value-entity_type='stop']", "Entrance")
      |> render_click()

      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")
      assert has_element?(view, "#report-stop-edit-form")

      # Close the drawer
      render_click(view, "close_entity_drawer")

      # Drawer form is removed; native root reflects closed state
      refute has_element?(view, "#report-stop-edit-form")
      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='false']")
    end

    test "large detail sets render without nested overflow text", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_EXPAND",
          stop_name: "Expand Station",
          location_type: 1,
          parent_station: nil
        })

      # Create many isolated generic nodes (type 3) to trigger a large detail list
      for i <- 1..12 do
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "GEN_EXP_#{i}",
          stop_name: "Generic Node #{i}",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L1"
        })
      end

      # Need at least one entrance and platform for minimum_station_children
      _entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "ENT_EXP",
          stop_name: "Entrance Expand",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      _platform =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "PLAT_EXP",
          stop_name: "Platform Expand",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # All 12 generic nodes plus the entrance should appear as isolated
      # Verify the last generic node renders (confirms full list is present)
      assert has_element?(view, "[phx-value-entity_id='GEN_EXP_12']")
      # Verify there is no nested "+ N more" overflow element
      refute has_element?(view, "#report2-data-quality details details")
    end

    test "submitting drawer form saves the stop and closes the drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # Open the drawer
      view
      |> element("[phx-click='select_entity'][phx-value-entity_type='stop']", "Entrance")
      |> render_click()

      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")
      assert has_element?(view, "#report-stop-edit-form")

      # Submit the form with changed data
      view
      |> form("#report-stop-edit-form",
        stop: %{
          stop_name: "Changed Name",
          stop_lat: "48.0",
          stop_lon: "-123.0",
          level_id: "L1",
          wheelchair_boarding: "1",
          platform_code: ""
        }
      )
      |> render_submit()

      # LiveView did not crash and report is still visible
      assert has_element?(view, "#station-report-2")

      # Drawer was closed after successful save
      refute has_element?(view, "#report-stop-edit-form")

      # Data was persisted
      reloaded_stop = Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, "ENT_1")
      assert reloaded_stop.stop_name == "Changed Name"
    end

    test "naming conventions section renders heading and result counts", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert html =~ "Naming &amp; ID Conventions"

      # Result counts come from the shared count strip, in report vocabulary.
      assert has_element?(view, "#naming-counts[data-role='count-strip'][data-mode='display']")
      assert has_element?(view, "#naming-counts-item-passed", "Passed")
      assert has_element?(view, "#naming-counts-item-failed", "Failed")
    end

    test "naming conventions section renders all 6 check rows", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {_view, html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert html =~ "Stop name title case"
      assert html =~ "Generic node ID prefix"
      assert html =~ "Boarding area ID prefix"
      assert html =~ "Entrance ID prefix"
      assert html =~ "location type match"
      assert html =~ "human-written"
    end

    test "naming conventions failing check renders FAIL badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_NC",
          stop_name: "Naming Station",
          location_type: 1,
          parent_station: nil
        })

      # Entrance without entrance_ prefix triggers naming_entrance_prefix failure
      _bad_entrance =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "door_main",
          stop_name: "Main Door",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#report2-naming-conventions [data-status='fail']", "Fail")
    end

    test "naming conventions passing check renders PASS badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#report2-naming-conventions [data-status='pass']", "Pass")
    end

    test "naming conventions prefix mismatch includes expected prefix", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_PM",
          stop_name: "Prefix Mismatch Station",
          location_type: 1,
          parent_station: nil
        })

      # boarding_ prefix on an entrance (type 2) triggers prefix_type_mismatch
      _mismatched =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "boarding_north",
          stop_name: "North Boarding",
          location_type: 2,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      conn = log_in_user(conn, user, organization: organization)

      {_view, html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert html =~ "Expected prefix"
      assert html =~ "entrance_"
    end

    test "redirects with flash when station is missing", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{gtfs_version.id}/stops/UNKNOWN/report")

      {to_path, flash} = assert_redirect(view, 5_000)
      assert to_path == "/gtfs/#{gtfs_version.id}/stops"
      assert flash == %{"error" => "Station not found"}
    end

    test "station inventory section renders node and edge counts", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#report2-station-inventory")
      refute has_element?(view, "#report2-station-inventory p", "Not yet implemented")

      html = render(view)
      assert html =~ "Node inventory by location type"
      assert html =~ "Edge inventory by pathway mode"
      assert html =~ "Pathway directionality"
      assert html =~ "Level count, names, and indices"
    end

    test "station inventory shows all location types and pathway modes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {_view, html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      # All 5 location types present
      assert html =~ "Stop/Platform"
      assert html =~ "Station"
      assert html =~ "Entrance/Exit"
      assert html =~ "Generic Node"
      assert html =~ "Boarding Area"

      # All 7 pathway modes present
      assert html =~ "Walkway"
      assert html =~ "Stairs"
      assert html =~ "Moving Sidewalk"
      assert html =~ "Escalator"
      assert html =~ "Elevator"
      assert html =~ "Fare Gate"
      assert html =~ "Exit Gate"

      # Directionality labels
      assert html =~ "Bidirectional"
      assert html =~ "Unidirectional"
    end

    test "levels table renders level data", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {_view, html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert html =~ "L1"
      assert html =~ "Street"
    end
  end

  describe "report lifecycle" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      _level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Street",
          level_index: 0.0
        })

      station_one = build_station(organization, gtfs_version, "STATION_1", "Station One")
      station_two = build_station(organization, gtfs_version, "STATION_2", "Station Two")

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station_one: station_one,
        station_two: station_two
      }
    end

    test "shows a loading state and withholds sections until the matching result arrives", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one
    } do
      control_snapshot_source()
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, report_path(gtfs_version, station_one))

      assert has_element?(view, "#report-status[data-state='initial_loading']")
      assert render(view) =~ "Loading report"
      refute has_element?(view, "#report2-station-inventory")
      refute has_element?(view, "#report2-reachability-connectivity")

      station_one.stop_id |> await_load() |> release_load(:real)
      html = render_async(view, 5_000)

      refute has_element?(view, "#report-status")
      assert has_element?(view, "#report2-station-inventory")
      assert has_element?(view, "#report2-pathway-field-completeness")
      assert html =~ "Station One"
    end

    test "a station switch during a load applies only the active station's result", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one,
      station_two: station_two
    } do
      control_snapshot_source()
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, report_path(gtfs_version, station_one))
      first_load = await_load(station_one.stop_id)

      render_patch(view, report_path(gtfs_version, station_two))
      second_load = await_load(station_two.stop_id)

      release_load(second_load, :real)
      assert render_async(view, 5_000) =~ "Station Two"

      # The superseded load finishes last. Its completion carries the previous
      # scope and must never replace the station the user is now looking at.
      release_and_settle(view, first_load, :real)

      assert render(view) =~ "Station Two"
      refute render(view) =~ "Station One"
      assert has_element?(view, "#report2-station-inventory")
    end

    test "a stale completion cannot revive content after the active load already applied", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one,
      station_two: station_two
    } do
      control_snapshot_source()
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, report_path(gtfs_version, station_one))
      first_load = await_load(station_one.stop_id)

      # Complete the first load normally, then switch stations.
      release_load(first_load, :real)
      assert render_async(view, 5_000) =~ "Station One"

      render_patch(view, report_path(gtfs_version, station_two))
      second_load = await_load(station_two.stop_id)

      # While station two is loading the report region is explicit, and the
      # station one content is not presented as station two's report.
      assert has_element?(view, "#report-status[data-state='initial_loading']")
      refute has_element?(view, "#report2-station-inventory")

      release_load(second_load, :real)
      assert render_async(view, 5_000) =~ "Station Two"
    end

    test "navigating to another version cancels in-flight work instead of applying it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one
    } do
      other_version = gtfs_version_fixture(organization.id)
      control_snapshot_source()
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, report_path(gtfs_version, station_one))
      in_flight = await_load(station_one.stop_id)

      render_click(view, "gtfs_version_loaded", %{"version_id" => to_string(other_version.id)})

      {to_path, _flash} = assert_redirect(view, 5_000)
      assert to_path == "/gtfs/#{other_version.id}/stops/#{station_one.stop_id}/report"

      # The abandoned load is released after the view is gone. Nothing it reports
      # can be applied, and the test process observes no crash from it.
      ref = Process.monitor(in_flight)
      release_load(in_flight, :real)
      assert_receive {:DOWN, ^ref, :process, ^in_flight, _reason}, 2_000
    end

    test "refreshing after a save keeps the previous report on screen", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one
    } do
      control_snapshot_source()
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, report_path(gtfs_version, station_one))
      station_one.stop_id |> await_load() |> release_load(:real)
      render_async(view, 5_000)

      open_stop_drawer(view, "Entrance One")
      submit_stop_name(view, "Renamed Entrance")

      refresh_load = await_load(station_one.stop_id)

      # Refreshing never blanks content that is already on screen.
      assert has_element?(view, "#report-status[data-state='refreshing']")
      assert has_element?(view, "#report2-station-inventory")
      assert render(view) =~ "Refreshing report"
      refute render(view) =~ "Loading report"

      release_load(refresh_load, :real)
      html = render_async(view, 5_000)

      refute has_element?(view, "#report-status")
      assert html =~ "Renamed Entrance"
    end

    test "a failed initial load offers retry and recovers", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one
    } do
      control_snapshot_source()
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, report_path(gtfs_version, station_one))
      station_one.stop_id |> await_load() |> release_load({:error, :snapshot_unavailable})
      render_async(view, 5_000)

      assert has_element?(view, "#report-status[data-state='error']")
      assert render(view) =~ "Report could not load"
      assert has_element?(view, "button#report-retry", "Retry report")
      refute has_element?(view, "#report2-station-inventory")

      view |> element("button#report-retry") |> render_click()

      station_one.stop_id |> await_load() |> release_load(:real)
      html = render_async(view, 5_000)

      refute has_element?(view, "#report-status")
      assert has_element?(view, "#report2-station-inventory")
      assert html =~ "Station One"
    end

    test "a failed post-save refresh reports the save, keeps content, and retries", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one
    } do
      control_snapshot_source()
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, report_path(gtfs_version, station_one))
      station_one.stop_id |> await_load() |> release_load(:real)
      render_async(view, 5_000)

      open_stop_drawer(view, "Entrance One")
      submit_stop_name(view, "Saved But Stale")

      station_one.stop_id |> await_load() |> release_load({:error, :snapshot_unavailable})
      render_async(view, 5_000)

      assert has_element?(view, "#report-status[data-state='error']")
      assert render(view) =~ "Stop saved, but the report could not refresh"
      assert has_element?(view, "button#report-retry", "Retry report")
      # The stale-but-real report stays visible rather than disappearing.
      assert has_element?(view, "#report2-station-inventory")

      # The save itself did land.
      assert Gtfs.get_stop_by_stop_id(organization.id, gtfs_version.id, "ENT_1").stop_name ==
               "Saved But Stale"

      view |> element("button#report-retry") |> render_click()
      station_one.stop_id |> await_load() |> release_load(:real)
      html = render_async(view, 5_000)

      refute has_element?(view, "#report-status")
      assert html =~ "Saved But Stale"
    end

    test "a repeated save submit after the drawer closed starts no second report load", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one
    } do
      control_snapshot_source()
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, report_path(gtfs_version, station_one))
      station_one.stop_id |> await_load() |> release_load(:real)
      render_async(view, 5_000)

      open_stop_drawer(view, "Entrance One")
      submit_stop_name(view, "Only Once")

      first_refresh = await_load(station_one.stop_id)

      # A duplicate submit for a drawer that is already closed must not queue
      # another rebuild.
      render_click(view, "save_entity", %{"stop" => %{"stop_name" => "Only Once"}})
      refute_receive {:snapshot_requested, _pid, _stop_id}, 200

      release_load(first_refresh, :real)
      render_async(view, 5_000)
      refute has_element?(view, "#report-status")
    end

    test "the stop form acknowledges submission with a distinct saving label", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one
    } do
      conn = log_in_user(conn, user, organization: organization)
      {view, _html} = live_report(conn, report_path(gtfs_version, station_one))

      open_stop_drawer(view, "Entrance One")

      assert has_element?(
               view,
               "#report-stop-edit-form button[type='submit'][phx-disable-with='Saving…']"
             )
    end
  end

  describe "report disclosure and print model" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      _level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Street",
          level_index: 0.0
        })

      station = build_station(organization, gtfs_version, "STATION_1", "Station One")

      _isolated =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "GEN_ISO",
          stop_name: "Isolated Node",
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "a newly loaded report carries every section and every connectivity detail", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {view, html} = live_report(conn, report_path(gtfs_version, station))

      for id <- [
            "report2-station-inventory",
            "report2-data-quality",
            "report2-gps-checks",
            "report2-naming-conventions",
            "report2-reachability-connectivity",
            "report2-pathway-field-completeness"
          ] do
        assert has_element?(view, "##{id}"), "expected section #{id} in a freshly loaded report"
      end

      # No disclosure has been interacted with yet.
      refute has_element?(view, "#station-report-2 [aria-expanded='true']")

      # Source-level connectivity evidence is already built.
      assert has_element?(view, "#connectivity-detail-entrance_to_platform-ENT_1")
      # Route-level and step-level evidence is already built.
      assert has_element?(view, "#route-ENT_1-PLAT_1")
      assert has_element?(view, "#route-ENT_1-PLAT_1 table thead th", "Instruction")
      assert has_element?(view, "#route-ENT_1-PLAT_1 table tbody td", "Elevator")
      # Failed-check evidence is already built.
      assert has_element?(view, "#check-detail-data-quality-isolated_nodes", "Isolated Node")
      assert has_element?(view, "#check-detail-naming-naming_entrance_prefix")

      # Collapsed evidence is hidden on screen but retained for print.
      assert has_element?(view, "#route-ENT_1-PLAT_1[class*='print:block']")

      assert has_element?(
               view,
               "#connectivity-detail-entrance_to_platform-ENT_1[class*='print:']"
             )

      assert has_element?(view, "#check-detail-data-quality-isolated_nodes[class*='print:grid']")

      # The client-only expand-all mutation and native <details> disclosure are gone.
      refute html =~ "ExpandAll"
      refute html =~ "<details"
    end

    test "individual disclosure is server owned and survives an unrelated patch", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {view, _html} = live_report(conn, report_path(gtfs_version, station))

      key = "data-quality-isolated_nodes"

      assert has_element?(
               view,
               "button[phx-click='toggle_check_detail'][phx-value-key='#{key}'][aria-expanded='false']"
             )

      view
      |> element("button[phx-click='toggle_check_detail'][phx-value-key='#{key}']")
      |> render_click()

      assert has_element?(
               view,
               "button[phx-click='toggle_check_detail'][phx-value-key='#{key}'][aria-expanded='true']"
             )

      refute has_element?(view, "#check-detail-#{key}[class*='hidden']")

      # A patch that does not change the scope leaves disclosure state alone.
      render_patch(view, report_path(gtfs_version, station) <> "?dimensions=platform_to_platform")

      assert has_element?(
               view,
               "button[phx-click='toggle_check_detail'][phx-value-key='#{key}'][aria-expanded='true']"
             )

      view
      |> element("button[phx-click='toggle_check_detail'][phx-value-key='#{key}']")
      |> render_click()

      assert has_element?(
               view,
               "button[phx-click='toggle_check_detail'][phx-value-key='#{key}'][aria-expanded='false']"
             )
    end

    test "Expand all and Collapse all drive the same server-owned state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {view, _html} = live_report(conn, report_path(gtfs_version, station))

      assert has_element?(view, "button#report-expand-all[aria-expanded='false']", "Expand all")

      view |> element("button#report-expand-all") |> render_click()

      assert has_element?(view, "button#report-expand-all[aria-expanded='true']", "Collapse all")

      assert has_element?(
               view,
               "button[phx-click='toggle_check_detail'][phx-value-key='data-quality-isolated_nodes'][aria-expanded='true']"
             )

      assert has_element?(
               view,
               "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_1'][aria-expanded='true']"
             )

      refute has_element?(view, "#route-ENT_1-PLAT_1[class*='hidden']")

      view |> element("button#report-expand-all") |> render_click()

      assert has_element?(view, "button#report-expand-all[aria-expanded='false']", "Expand all")
      assert has_element?(view, "#route-ENT_1-PLAT_1[class*='hidden']")
    end

    test "expansion survives a post-save refresh of the same station", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)
      {view, _html} = live_report(conn, report_path(gtfs_version, station))

      view |> element("button#report-expand-all") |> render_click()
      assert has_element?(view, "button#report-expand-all[aria-expanded='true']")

      open_stop_drawer(view, "Entrance One")
      submit_stop_name(view, "Entrance Renamed")
      render_async(view, 5_000)

      # Individual disclosure keys survive the rebuild rather than snapping shut.
      assert has_element?(
               view,
               "button[phx-click='toggle_check_detail'][phx-value-key='data-quality-isolated_nodes'][aria-expanded='true']"
             )

      assert has_element?(
               view,
               "button[phx-click='toggle_route_expand'][phx-value-source_id='ENT_1'][phx-value-target_id='PLAT_1'][aria-expanded='true']"
             )

      refute has_element?(view, "#route-ENT_1-PLAT_1[class*='hidden']")
    end

    test "expansion resets when the station changes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      other = build_station(organization, gtfs_version, "STATION_2", "Station Two")

      conn = log_in_user(conn, user, organization: organization)
      {view, _html} = live_report(conn, report_path(gtfs_version, station))

      view |> element("button#report-expand-all") |> render_click()
      assert has_element?(view, "button#report-expand-all[aria-expanded='true']")

      render_patch(view, report_path(gtfs_version, other))
      render_async(view, 5_000)

      assert has_element?(view, "button#report-expand-all[aria-expanded='false']")
      assert has_element?(view, "#route-ENT_2-PLAT_2[class*='hidden']")
    end
  end

  describe "report presentation contracts" do
    setup %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      _level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
          level_name: "Street",
          level_index: 0.0
        })

      station = build_station(organization, gtfs_version, "STATION_1", "Station One")

      # An isolated generic node whose name is long enough that any truncation
      # would be visible, so "long values stay complete" is actually exercised.
      _isolated =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "GEN_ISO_WITH_A_DELIBERATELY_LONG_IDENTIFIER",
          stop_name: @long_stop_name,
          location_type: 3,
          parent_station: station.stop_id,
          level_id: "L1"
        })

      conn = log_in_user(conn, user, organization: organization)
      {view, _html} = live_report(conn, report_path(gtfs_version, station))

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        view: view
      }
    end

    test "the report has one H1 and six peer section headings", ctx do
      html = report_html(ctx)

      assert count_occurrences(html, "<h1") == 1,
             "the report must own exactly one H1"

      assert count_occurrences(html, "<h2") == 6,
             "the report must expose exactly six peer H2 sections"

      view = ctx.view

      for {id, title} <- [
            {"report2-station-inventory", "Station Inventory"},
            {"report2-data-quality", "Data Quality"},
            {"report2-gps-checks", "GPS"},
            {"report2-naming-conventions", "Naming"},
            {"report2-reachability-connectivity", "Reachability"},
            {"report2-pathway-field-completeness", "Pathway Field Completeness"}
          ] do
        assert has_element?(view, "##{id} > h2", title),
               "expected #{id} to own an H2 titled #{title}"
      end
    end

    test "check statuses are readable as words, not colour alone", ctx do
      view = ctx.view

      assert has_element?(
               view,
               "#report2-data-quality [data-check='isolated_nodes'] [data-status='fail']",
               "Fail"
             )

      assert has_element?(
               view,
               "#report2-data-quality [data-check='duplicate_stop_ids'] [data-status='pass']",
               "Pass"
             )

      assert has_element?(
               view,
               "#report2-naming-conventions [data-check='naming_node_prefix'] [data-status='fail']",
               "Fail"
             )
    end

    test "no literal status palette colours, raw SVG, or emoji remain in the report", ctx do
      html = report_html(ctx)

      for literal <- [
            "bg-red-100",
            "bg-green-100",
            "bg-yellow-100",
            "bg-emerald-50",
            "bg-amber-50",
            "text-teal-600",
            "text-gray-500",
            "text-red-700",
            "text-green-800"
          ] do
        refute html =~ literal,
               "report still renders the literal palette class #{literal}"
      end

      refute html =~ "<svg", "report still renders raw SVG instead of <.icon>"
      refute html =~ "⚠", "report still renders an emoji as a meaningful glyph"
    end

    test "the report exposes a display-only count strip in report vocabulary", ctx do
      view = ctx.view

      assert has_element?(
               view,
               "#report-outcome-counts[data-role='count-strip'][data-mode='display']"
             )

      assert has_element?(view, "#report-outcome-counts-item-failed", "Failed")
      assert has_element?(view, "#report-outcome-counts-item-passed", "Passed")
      refute has_element?(view, "#report-outcome-counts button")
    end

    test "the report count strip agrees with the statuses the sections render", ctx do
      html = report_html(ctx)

      strip_failed =
        ctx.view
        |> element("#report-outcome-counts-item-failed [data-role='count-strip-value']")
        |> render()
        |> extract_integer()

      rendered_failures = count_occurrences(html, ~s(data-status="fail"))

      assert strip_failed == rendered_failures,
             "count strip reports #{strip_failed} failures but #{rendered_failures} are rendered"

      assert strip_failed > 0, "the fixture must produce at least one failing check"
    end

    test "long stop names stay complete and are never truncated", ctx do
      view = ctx.view
      html = report_html(ctx)

      assert has_element?(
               view,
               "#check-detail-data-quality-isolated_nodes",
               @long_stop_name
             )

      refute html =~ "truncate", "report still truncates a value instead of wrapping it"
    end

    test "no interactive table rows remain", ctx do
      view = ctx.view

      refute has_element?(view, "#station-report-2 tr[role='button']")
      refute has_element?(view, "#station-report-2 tr[phx-click]")
      refute has_element?(view, "#station-report-2 tr[tabindex]")
    end

    test "no table renders an empty body shell", ctx do
      html = report_html(ctx)

      refute html =~ ~r|<tbody[^>]*>\s*</tbody>|,
             "a table renders an empty body instead of an explained empty state"
    end

    test "every disclosure control is print-excluded and carries a controlled region", ctx do
      view = ctx.view
      html = report_html(ctx)

      controls =
        ~r/<[a-z]+[^>]*data-report-control[^>]*>/
        |> Regex.scan(html)
        |> List.flatten()

      assert controls != [], "the report renders no controls to exclude from print"

      for control <- controls do
        assert control =~ "print:hidden",
               "a report control is not excluded from print: #{control}"
      end

      refute has_element?(
               view,
               "#station-report-2 button[aria-expanded]:not([aria-controls])"
             )
    end

    test "collapsed disclosure regions stay in the document for print", ctx do
      view = ctx.view

      # A freshly loaded report has clicked nothing, yet every region is present
      # and marked to reappear in print media.
      assert has_element?(view, "[id^='check-detail-'][class*='print:']")
      assert has_element?(view, "[id^='connectivity-detail-'][class*='print:block']")
      assert has_element?(view, "[id^='route-'][class*='print:block']")
      refute has_element?(view, "#station-report-2 [aria-expanded='true']")
    end
  end

  describe "report empty states" do
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
          stop_id: "STATION_BARE",
          stop_name: "Bare Station",
          location_type: 1,
          parent_station: nil
        })

      conn = log_in_user(conn, user, organization: organization)
      {view, _html} = live_report(conn, report_path(gtfs_version, station))

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        view: view
      }
    end

    test "a station with no children explains every missing-data region", ctx do
      view = ctx.view

      assert has_element?(view, "#report2-levels-empty", "No levels")
      assert has_element?(view, "#report2-pathway-field-completeness-empty", "No pathways")

      for dimension <- [:entrance_to_platform, :platform_to_platform, :platform_to_exit] do
        assert has_element?(view, "#connectivity-empty-#{dimension}"),
               "expected an explained empty state for #{dimension}"
      end
    end

    test "the ideal sections still render for a station with no children", ctx do
      view = ctx.view

      for id <- [
            "report2-station-inventory",
            "report2-data-quality",
            "report2-gps-checks",
            "report2-naming-conventions",
            "report2-reachability-connectivity",
            "report2-pathway-field-completeness"
          ] do
        assert has_element?(view, "##{id}")
      end

      refute report_html(ctx) =~ ~r|<tbody[^>]*>\s*</tbody>|
    end

    test "an empty report still reports zero counts rather than hiding the strip", ctx do
      assert has_element?(ctx.view, "#report-outcome-counts-item-failed")
      assert has_element?(ctx.view, "#report-outcome-counts-item-passed")
    end
  end

  # -- helpers --------------------------------------------------------------

  defp report_html(%{view: view}) do
    view |> element("#station-report-2") |> render()
  end

  defp count_occurrences(haystack, needle),
    do: haystack |> :binary.matches(needle) |> length()

  defp extract_integer(html) do
    [value] = Regex.run(~r/(\d+)/, html, capture: :all_but_first)
    String.to_integer(value)
  end

  defp report_path(gtfs_version, station),
    do: "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report"

  defp build_station(organization, gtfs_version, station_id, station_name) do
    suffix = String.replace(station_id, "STATION_", "")

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: station_id,
        stop_name: station_name,
        location_type: 1,
        parent_station: nil
      })

    entrance =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "ENT_#{suffix}",
        stop_name: "Entrance #{station_name |> String.split() |> List.last()}",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: "L1"
      })

    platform =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "PLAT_#{suffix}",
        stop_name: "Platform #{suffix}",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: "L1"
      })

    _pathway =
      pathway_fixture(organization.id, gtfs_version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PATH_#{suffix}",
        pathway_mode: 5,
        is_bidirectional: true
      })

    station
  end

  defp open_stop_drawer(view, entity_name) do
    view
    |> element("[phx-click='select_entity'][phx-value-entity_type='stop']", entity_name)
    |> render_click()
  end

  defp submit_stop_name(view, stop_name) do
    view
    |> form("#report-stop-edit-form",
      stop: %{
        stop_name: stop_name,
        stop_lat: "47.6",
        stop_lon: "-122.3",
        level_id: "L1",
        wheelchair_boarding: "",
        platform_code: ""
      }
    )
    |> render_submit()
  end

  # Releases a held load and waits until the task process is gone, so any
  # completion it reported is already queued ahead of the next render.
  defp release_and_settle(view, task_pid, result) do
    ref = Process.monitor(task_pid)
    release_load(task_pid, result)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 2_000
    render(view)
    :ok
  end
end
