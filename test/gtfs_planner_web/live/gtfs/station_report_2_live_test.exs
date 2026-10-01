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

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Repo
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

      # Problems come first, and what the station contains comes last.
      section_ids = [
        "report2-data-quality",
        "report2-reachability-connectivity",
        "report2-gps-checks",
        "report2-pathway-field-completeness",
        "report2-naming-conventions",
        "report2-station-inventory"
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

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#report2-naming-conventions h2", "Names and IDs")

      # Result counts come from the shared count strip, in report vocabulary.
      # A naming rule is house style, so a failed one is counted as a suggestion.
      assert has_element?(view, "#naming-counts[data-role='count-strip'][data-mode='display']")
      assert has_element?(view, "#naming-counts-item-passed", "Passed")
      assert has_element?(view, "#naming-counts-item-suggestions", "Suggestions")
      refute has_element?(view, "#naming-counts-item-failed")
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
      assert html =~ "Stop ID prefix matches location type"
      assert html =~ "Human-written stop names"
    end

    test "naming conventions failing check renders a Suggestion badge, not a Problem", %{
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

      assert has_element?(view, "#report2-naming-conventions [data-status='warn']", "Suggestion")
      refute has_element?(view, "#report2-naming-conventions [data-status='fail']")
    end

    test "naming conventions passing check renders a Passed badge", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, user, organization: organization)

      {view, _html} =
        live_report(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/report")

      assert has_element?(view, "#report2-naming-conventions [data-status='pass']", "Passed")
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

    test "the station tabs stay reachable while the report loads and after it fails", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station_one: station_one
    } do
      control_snapshot_source()
      conn = log_in_user(conn, user, organization: organization)
      diagram_href = "/gtfs/#{gtfs_version.id}/stops/#{station_one.stop_id}/diagram"

      {:ok, view, _html} = live(conn, report_path(gtfs_version, station_one))

      # Nothing is known about the station yet, so the header names it by its id.
      assert has_element?(view, "#report-status[data-state='initial_loading']")
      assert has_element?(view, "#station-sub-nav h1", station_one.stop_id)
      assert has_element?(view, "#station-sub-nav a[aria-current='page']", "Reports")
      assert has_element?(view, "#station-sub-nav a[href='#{diagram_href}']", "Floorplans")

      station_one.stop_id |> await_load() |> release_load({:error, :snapshot_unavailable})
      render_async(view, 5_000)

      assert has_element?(view, "#report-status[data-state='error']")
      assert has_element?(view, "#station-sub-nav a[aria-current='page']", "Reports")
      assert has_element?(view, "#station-sub-nav a[href='#{diagram_href}']", "Floorplans")

      view |> element("button#report-retry") |> render_click()
      station_one.stop_id |> await_load() |> release_load(:real)
      render_async(view, 5_000)

      # Once the report loads, the header names the station and what it holds.
      assert has_element?(view, "#station-sub-nav h1", "Station One")
      assert has_element?(view, "#station-sub-nav", "STATION_1")
      assert has_element?(view, "#station-sub-nav", "1 level")
      assert has_element?(view, "#station-sub-nav", "stops and nodes inside")
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
      {view, _html} = live_report(conn, report_path(gtfs_version, station))

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

      assert has_element?(view, "#check-detail-data-quality-isolated_nodes[class*='print:block']")

      # The client-only expand-all mutation and native <details> disclosure are gone.
      refute has_element?(view, "[phx-hook='ExpandAll']")
      refute has_element?(view, "#station-report-2 details")
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
      doc = report_doc(ctx)

      assert element_count(doc, "h1") == 1,
             "the report must own exactly one H1"

      # The workspace header names the station on screen and does not print, so
      # the report's own H1 is the printed title and is hidden on screen.
      assert has_element?(ctx.view, "#station-report-2 h1[class~='hidden'][class~='print:block']")
      assert has_element?(ctx.view, "#station-sub-nav h1", "Station One")

      assert element_count(doc, "h2") == 6,
             "the report must expose exactly six peer H2 sections"

      view = ctx.view

      for {id, title} <- [
            {"report2-station-inventory", "What's in this station"},
            {"report2-data-quality", "Data quality"},
            {"report2-gps-checks", "Stop locations"},
            {"report2-naming-conventions", "Names and IDs"},
            {"report2-reachability-connectivity", "Routes riders can take"},
            {"report2-pathway-field-completeness", "Pathway details"}
          ] do
        assert has_element?(view, "##{id} h2", title),
               "expected #{id} to own an H2 titled #{title}"
      end
    end

    test "check statuses are readable as words, not colour alone", ctx do
      view = ctx.view

      assert has_element?(
               view,
               "#report2-data-quality [data-check='isolated_nodes'] [data-status='fail']",
               "Problem"
             )

      assert has_element?(
               view,
               "#report2-data-quality [data-check='duplicate_stop_ids'] [data-status='pass']",
               "Passed"
             )

      assert has_element?(
               view,
               "#report2-naming-conventions [data-check='naming_node_prefix'] [data-status='warn']",
               "Suggestion"
             )
    end

    # AC-9 forbids literal status colour, raw SVG, and emoji glyphs inside the
    # report. That obligation is stated as an absence, so it is the one place a
    # colour utility may still be named — as a bounded negative class-token
    # query against the report subtree, never a substring match on whole-page
    # HTML.
    test "no literal status palette colours, raw SVG, or emoji remain in the report", ctx do
      doc = report_doc(ctx)

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
        assert element_count(doc, ~s([class~="#{literal}"])) == 0,
               "report still renders the literal palette class #{literal}"
      end

      assert element_count(doc, "svg") == 0,
             "report still renders raw SVG instead of <.icon>"

      refute doc |> LazyHTML.text() |> String.contains?("⚠"),
             "report still renders an emoji as a meaningful glyph"
    end

    test "the report exposes a display-only count strip in report vocabulary", ctx do
      view = ctx.view

      assert has_element?(
               view,
               "#report-outcome-counts[data-role='count-strip'][data-mode='display']"
             )

      assert has_element?(view, "#report-outcome-counts-item-problems", "Problems")
      assert has_element?(view, "#report-outcome-counts-item-suggestions", "Suggestions")
      assert has_element?(view, "#report-outcome-counts-item-notes", "Notes")
      assert has_element?(view, "#report-outcome-counts-item-passed", "Passed")
      refute has_element?(view, "#report-outcome-counts button")
    end

    test "an unfilled optional pathway field reads Missing, never as a failure", ctx do
      # The fixture's elevator pathway carries neither a width nor a travel time.
      assert has_element?(
               ctx.view,
               "#report2-pathway-field-completeness [data-field-status='fail']",
               "Missing"
             )

      refute ctx |> report_html() |> String.contains?(">Fail<")
    end

    test "the report count strip agrees with the statuses the sections render", ctx do
      strip_problems =
        ctx.view
        |> element("#report-outcome-counts-item-problems [data-role='count-strip-value']")
        |> render()
        |> extract_integer()

      rendered_problems = ctx |> report_doc() |> element_count(~s([data-status="fail"]))

      assert strip_problems == rendered_problems,
             "count strip reports #{strip_problems} problems but #{rendered_problems} are rendered"

      assert strip_problems > 0, "the fixture must produce at least one failing check"

      # Naming failures are suggestions, so the strip counts them with the
      # warnings the sections render rather than with the problems.
      strip_suggestions =
        ctx.view
        |> element("#report-outcome-counts-item-suggestions [data-role='count-strip-value']")
        |> render()
        |> extract_integer()

      rendered_suggestions = ctx |> report_doc() |> element_count(~s([data-status="warn"]))

      assert strip_suggestions == rendered_suggestions
    end

    test "long stop names stay complete and are never truncated", ctx do
      view = ctx.view
      doc = report_doc(ctx)

      assert has_element?(
               view,
               "#check-detail-data-quality-isolated_nodes",
               @long_stop_name
             )

      assert element_count(doc, "[class~=truncate]") == 0,
             "report still truncates a value instead of wrapping it"
    end

    test "no interactive table rows remain", ctx do
      view = ctx.view

      refute has_element?(view, "#station-report-2 tr[role='button']")
      refute has_element?(view, "#station-report-2 tr[phx-click]")
      refute has_element?(view, "#station-report-2 tr[tabindex]")
    end

    test "no table renders an empty body shell", ctx do
      bodies = ctx |> report_doc() |> LazyHTML.query("tbody") |> Enum.to_list()

      assert bodies != [], "the fixture must render at least one comparison table"

      for body <- bodies do
        refute body |> LazyHTML.query("tr") |> Enum.empty?(),
               "a table renders an empty body instead of an explained empty state"
      end
    end

    test "every disclosure control is print-excluded and carries a controlled region", ctx do
      view = ctx.view
      doc = report_doc(ctx)

      controls = element_count(doc, "[data-report-control]")
      excluded = element_count(doc, ~s([data-report-control][class~="print:hidden"]))

      assert controls > 0, "the report renders no controls to exclude from print"

      assert excluded == controls,
             "#{controls - excluded} of #{controls} report controls are not excluded from print"

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
      assert has_element?(ctx.view, "#report-outcome-counts-item-problems")
      assert has_element?(ctx.view, "#report-outcome-counts-item-passed")
    end
  end

  describe "report stop drawer" do
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

    test "the report issue link is the only way in and opens only the stop form", ctx do
      view = ctx.view

      refute has_element?(view, "#report-stop-edit-form")
      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='false']")

      open_stop_drawer(view, "Entrance One")

      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")
      assert has_element?(view, "form#report-stop-edit-form")
      assert has_element?(view, "#report-entity-drawer", "Saving rebuilds the report")

      # The report owns no pathway drawer: neither a form nor a select path.
      refute has_element?(view, "#report-pathway-edit-form")
      refute has_element?(view, "[phx-value-entity_type='pathway']")
    end

    test "selecting a pathway entity leaves the drawer closed", ctx do
      render_click(ctx.view, "select_entity", %{
        "entity_id" => "PATH_1",
        "entity_type" => "pathway"
      })

      assert has_element?(ctx.view, "dialog#report-entity-drawer-overlay[data-open='false']")
      refute has_element?(ctx.view, "#report-pathway-edit-form")
      refute has_element?(ctx.view, "#report-stop-edit-form")
    end

    test "the stop form reads as sentence case with visible optional and raw-key help", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      rendered_labels =
        view
        |> stop_form_doc()
        |> LazyHTML.query("label")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      for label <- [
            "Stop name (optional)",
            "Latitude (optional)",
            "Longitude (optional)",
            "Wheelchair boarding (optional)",
            "Platform code (optional)",
            "Level"
          ] do
        # A `<label>` that wraps a `<select>` also contains its option text, so
        # the caption is asserted as the label's leading text.
        assert Enum.any?(rendered_labels, &String.starts_with?(&1, label)),
               "expected #{inspect(label)} to caption a visible <label>, got #{inspect(rendered_labels)}"
      end

      # Raw GTFS keys stay available as secondary help, never as the label.
      for {input_id, gtfs_key} <- [
            {"stop_stop_name", "stop_name"},
            {"stop_stop_lat", "stop_lat"},
            {"stop_stop_lon", "stop_lon"},
            {"stop_level_id", "level_id"},
            {"stop_wheelchair_boarding", "wheelchair_boarding"},
            {"stop_platform_code", "platform_code"}
          ] do
        assert has_element?(view, "##{input_id}-help", gtfs_key)
        assert has_element?(view, "##{input_id}[aria-describedby~='#{input_id}-help']")
      end
    end

    test "numeric fields declare numeric type, step, range, and input mode", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      assert has_element?(
               view,
               "#stop_stop_lat[type='number'][step='0.000001'][min='-90'][max='90'][inputmode='decimal']"
             )

      assert has_element?(
               view,
               "#stop_stop_lon[type='number'][step='0.000001'][min='-180'][max='180'][inputmode='decimal']"
             )
    end

    # The measured one-column layout is a browser contract and is proven by
    # `assets/e2e/station_reports_and_history.spec.js` (one distinct left edge at
    # 320 px). What ExUnit owns is the structure that makes it possible: every
    # editable control sits in its own row-level block under the form, so no two
    # fields can ever share a row.
    test "each editable field occupies its own form row so the form can stay one column", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      controls_per_row =
        view
        |> stop_form_doc()
        |> LazyHTML.query("#report-stop-edit-form .overflow-y-auto > *")
        |> Enum.map(&element_count(&1, "input:not([type='hidden']), select, textarea"))

      assert Enum.sum(controls_per_row) == 6,
             "expected the six editable stop fields, got #{Enum.sum(controls_per_row)}"

      assert Enum.max(controls_per_row) == 1,
             "a single form row holds more than one control: #{inspect(controls_per_row)}"
    end

    test "an invalid submit keeps the drawer, preserves input, and associates field errors",
         ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      # The level select offers no blank choice for a stop inside a station, so
      # a blank level can only arrive as a crafted submit.
      render_submit(view, "save_entity", %{
        "stop" => %{
          "stop_name" => "Renamed But Rejected",
          "stop_lat" => "91.5",
          "stop_lon" => "-122.3",
          "level_id" => "",
          "wheelchair_boarding" => "",
          "platform_code" => ""
        }
      })

      # The drawer does not close.
      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")
      assert has_element?(view, "form#report-stop-edit-form")

      # Typed values survive.
      assert has_element?(view, "#stop_stop_lat[value='91.5']")
      assert has_element?(view, "#stop_stop_name[value='Renamed But Rejected']")

      # Errors are associated with their controls, not just printed.
      assert has_element?(view, "#stop_stop_lat[aria-invalid='true']")
      assert has_element?(view, "#stop_stop_lat[aria-describedby~='stop_stop_lat-error']")
      assert has_element?(view, "#stop_stop_lat-error")
      assert has_element?(view, "#stop_level_id[aria-invalid='true']")
      assert has_element?(view, "#stop_level_id-error", "can't be blank")

      # A view-level explanation says what failed and what to do next.
      assert has_element?(
               view,
               "#report-stop-form-error",
               "Nothing was saved. Fix these fields:"
             )

      # The summary names each rejected field and links to it.
      assert has_element?(view, "#report-stop-form-error a[href='#stop_stop_lat']", "Latitude")
      assert has_element?(view, "#report-stop-form-error a[href='#stop_level_id']", "Level")

      # Nothing was written, not even the field that was valid.
      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1")
      assert stored.stop_name == "Entrance One"
      assert stored.level_id == "L1"

      assert is_nil(stored.stop_lat) or
               Decimal.compare(stored.stop_lat, Decimal.new("91.5")) != :eq
    end

    test "an invalid submit asks the client to focus the first invalid field", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      assert has_element?(view, "#report-stop-drawer[phx-hook='FormErrorFocus']")

      view
      |> form("#report-stop-edit-form",
        stop: %{
          stop_name: "Entrance One",
          stop_lat: "91.5",
          stop_lon: "-122.3",
          level_id: "L1",
          wheelchair_boarding: "",
          platform_code: ""
        }
      )
      |> render_submit()

      assert_push_event(view, "focus_form_error", %{
        form_id: "report-stop-edit-form",
        fallback_id: "report-stop-form-error"
      })
    end

    test "a valid submit acknowledges immediately and cannot be submitted twice", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      assert has_element?(
               view,
               "#report-stop-edit-form button[type='submit'][phx-disable-with='Saving…']"
             )

      submit_stop_name(view, "Saved Once")
      render_async(view, 5_000)

      # The form is gone, so a replayed submit has nothing to save again.
      refute has_element?(view, "#report-stop-edit-form")

      render_click(view, "save_entity", %{"stop" => %{"stop_name" => "Saved Twice"}})

      assert Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1").stop_name ==
               "Saved Once"
    end

    test "validating on change reports errors without writing anything", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      view
      |> form("#report-stop-edit-form",
        stop: %{
          stop_name: "Typed But Unsaved",
          stop_lat: "200",
          stop_lon: "-122.3",
          level_id: "L1",
          wheelchair_boarding: "",
          platform_code: ""
        }
      )
      |> render_change()

      assert has_element?(view, "#stop_stop_lat[aria-invalid='true']")
      # A change is not a save attempt, so no failed-save banner appears.
      refute has_element?(view, "#report-stop-form-error")

      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1")
      assert stored.stop_name == "Entrance One"
    end

    test "a zero wheelchair value is stored and shown as zero, never dropped", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      view
      |> form("#report-stop-edit-form",
        stop: %{
          stop_name: "Entrance One",
          stop_lat: "",
          stop_lon: "",
          level_id: "L1",
          wheelchair_boarding: "0",
          platform_code: ""
        }
      )
      |> render_submit()

      render_async(view, 5_000)

      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1")
      assert stored.wheelchair_boarding == 0

      open_stop_drawer(view, "Entrance One")

      assert has_element?(view, "#stop_wheelchair_boarding option[value='0'][selected]")
    end

    test "saving a changed stop name writes one history entry naming the old and new value",
         ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      view
      |> form("#report-stop-edit-form", stop: %{stop_name: "Renamed Entrance"})
      |> render_submit()

      render_async(view, 5_000)

      assert [log] = stop_change_logs(ctx)
      assert log.action == "updated"
      assert log.entity_external_id == "ENT_1"
      assert log.station_stop_id == "STATION_1"
      assert log.actor_id == ctx.user.id
      assert log.actor_email == ctx.user.email

      assert log.changed_fields == %{
               "stop_name" => %{"from" => "Entrance One", "to" => "Renamed Entrance"}
             }
    end

    test "saving a stop with no changes writes no history entry", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      view
      |> form("#report-stop-edit-form")
      |> render_submit()

      render_async(view, 5_000)

      refute has_element?(view, "#report-stop-edit-form")
      assert stop_change_logs(ctx) == []
    end

    test "a rejected save writes no history entry", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      view
      |> form("#report-stop-edit-form", stop: %{stop_name: "Rejected Rename", stop_lat: "91.5"})
      |> render_submit()

      assert has_element?(view, "#report-stop-form-error")
      assert stop_change_logs(ctx) == []
    end

    test "history can roll a drawer save back to the old stop name", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      view
      |> form("#report-stop-edit-form", stop: %{stop_name: "Renamed Entrance"})
      |> render_submit()

      render_async(view, 5_000)

      [log] = stop_change_logs(ctx)

      audit_ctx = %GtfsPlanner.Gtfs.AuditContext{
        organization_id: ctx.organization.id,
        gtfs_version_id: ctx.gtfs_version.id,
        station_stop_id: "STATION_1",
        actor_id: ctx.user.id,
        actor_email: ctx.user.email
      }

      assert {:ok, restored} =
               GtfsPlanner.Gtfs.Stations.rollback_entity(
                 audit_ctx,
                 log.id,
                 persisted_entity_revision(log)
               )

      assert restored.stop_name == "Entrance One"

      assert Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1").stop_name ==
               "Entrance One"
    end

    test "submitted scope and identity fields cannot move the stop", ctx do
      view = ctx.view
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      open_stop_drawer(view, "Entrance One")

      render_submit(view, "save_entity", %{
        "stop" => %{
          "stop_name" => "Renamed",
          "stop_lat" => "47.6",
          "stop_lon" => "-122.3",
          "level_id" => "L1",
          "wheelchair_boarding" => "",
          "platform_code" => "",
          "stop_id" => "HIJACKED",
          "organization_id" => other_organization.id,
          "gtfs_version_id" => other_version.id,
          "parent_station" => "SOMEWHERE_ELSE",
          "location_type" => "1"
        }
      })

      render_async(view, 5_000)

      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1")
      assert stored.stop_name == "Renamed"
      assert stored.stop_id == "ENT_1"
      assert stored.organization_id == ctx.organization.id
      assert stored.gtfs_version_id == ctx.gtfs_version.id
      assert stored.parent_station == "STATION_1"
      assert stored.location_type == 2

      refute is_nil(Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1"))
      assert is_nil(Gtfs.get_stop_by_stop_id(other_organization.id, other_version.id, "HIJACKED"))
    end

    test "a stop outside the active scope is refused instead of loaded", ctx do
      view = ctx.view
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      foreign =
        stop_fixture(other_organization.id, other_version.id, %{
          stop_id: "FOREIGN_1",
          stop_name: "Foreign Platform",
          location_type: 0,
          parent_station: nil
        })

      render_click(view, "select_entity", %{
        "entity_id" => "FOREIGN_1",
        "entity_type" => "stop"
      })

      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")
      refute has_element?(view, "#report-stop-edit-form")
      assert has_element?(view, "#report-stop-lookup-error", "Stop not found")
      refute render(view) =~ "Foreign Platform"

      # A submit while the lookup failed writes nothing anywhere.
      render_submit(view, "save_entity", %{"stop" => %{"stop_name" => "Hijacked"}})

      assert Gtfs.get_stop_by_stop_id(other_organization.id, other_version.id, "FOREIGN_1").stop_name ==
               foreign.stop_name
    end

    test "a stop in another station of the same version is refused", ctx do
      other_station =
        stop_fixture(ctx.organization.id, ctx.gtfs_version.id, %{
          stop_id: "OTHER_REPORT_STATION",
          location_type: 1
        })

      foreign_child =
        child_stop_fixture(
          ctx.organization.id,
          ctx.gtfs_version.id,
          other_station.stop_id,
          %{stop_id: "OTHER_REPORT_CHILD", stop_name: "Other Station Platform"}
        )

      render_click(ctx.view, "select_entity", %{
        "entity_id" => foreign_child.stop_id,
        "entity_type" => "stop"
      })

      refute has_element?(ctx.view, "#report-stop-edit-form")
      assert has_element?(ctx.view, "#report-stop-lookup-error")

      assert Repo.get!(GtfsPlanner.Gtfs.Stop, foreign_child.id).stop_name ==
               "Other Station Platform"
    end

    test "a stale save keeps the entered name and shows a focused warning", ctx do
      open_stop_drawer(ctx.view, "Entrance One")
      stop = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1")
      assert {:ok, _} = Gtfs.import_update_stop(stop, %{stop_name: "Changed elsewhere"})

      ctx.view
      |> form("#report-stop-edit-form", stop: %{stop_name: "My draft name"})
      |> render_submit()

      assert has_element?(ctx.view, "#report-stop-save-error[role='alert']")

      assert has_element?(
               ctx.view,
               "#report-stop-edit-form input[name='stop[stop_name]'][value='My draft name']"
             )

      assert Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id).stop_name == "Changed elsewhere"
      assert stop_change_logs(ctx) == []
    end

    test "a same-id stop in another version is never the one edited", ctx do
      view = ctx.view
      other_version = gtfs_version_fixture(ctx.organization.id)

      other_entrance =
        stop_fixture(ctx.organization.id, other_version.id, %{
          stop_id: "ENT_1",
          stop_name: "Other Version Entrance",
          location_type: 2,
          parent_station: nil
        })

      open_stop_drawer(view, "Entrance One")
      submit_stop_name(view, "Active Version Only")
      render_async(view, 5_000)

      assert Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1").stop_name ==
               "Active Version Only"

      assert Gtfs.get_stop_by_stop_id(ctx.organization.id, other_version.id, "ENT_1").stop_name ==
               other_entrance.stop_name
    end

    test "a failed lookup offers a local retry that recovers in place", ctx do
      view = ctx.view

      render_click(view, "select_entity", %{
        "entity_id" => "LATE_ARRIVAL",
        "entity_type" => "stop"
      })

      assert has_element?(view, "#report-stop-lookup-error", "Stop not found")
      assert has_element?(view, "button#report-stop-lookup-retry", "Retry lookup")

      # Nothing was opened, so the drawer does not promise a rebuild.
      refute has_element?(view, "#report-entity-drawer", "Saving rebuilds the report")

      # Retrying while the stop is still missing stays in the drawer.
      view |> element("button#report-stop-lookup-retry") |> render_click()
      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")
      assert has_element?(view, "#report-stop-lookup-error")

      stop_fixture(ctx.organization.id, ctx.gtfs_version.id, %{
        stop_id: "LATE_ARRIVAL",
        stop_name: "Late Arrival",
        location_type: 0,
        parent_station: nil
      })

      view |> element("button#report-stop-lookup-retry") |> render_click()

      refute has_element?(view, "#report-stop-lookup-error")
      assert has_element?(view, "form#report-stop-edit-form")
      assert has_element?(view, "#stop_stop_name[value='Late Arrival']")
    end

    test "the level control offers this version's levels by name, and a required level has no blank choice",
         ctx do
      view = ctx.view
      other_version = gtfs_version_fixture(ctx.organization.id)
      other_organization = organization_fixture()
      other_organization_version = gtfs_version_fixture(other_organization.id)

      level_fixture(ctx.organization.id, ctx.gtfs_version.id, %{
        level_id: "L2",
        level_name: "Mezzanine",
        level_index: 1.0
      })

      level_fixture(ctx.organization.id, ctx.gtfs_version.id, %{
        level_id: "Z_UNNAMED",
        level_name: nil,
        level_index: 2.0
      })

      level_fixture(ctx.organization.id, other_version.id, %{
        level_id: "OTHER_VERSION_LEVEL",
        level_name: "Other Version"
      })

      level_fixture(other_organization.id, other_organization_version.id, %{
        level_id: "OTHER_ORG_LEVEL",
        level_name: "Other Organization"
      })

      open_stop_drawer(view, "Entrance One")

      assert has_element?(view, "select#stop_level_id[name='stop[level_id]']")
      refute has_element?(view, "input#stop_level_id")

      assert level_options(view) == [
               {"Mezzanine (L2)", "L2"},
               {"Street (L1)", "L1"},
               {"Z_UNNAMED", "Z_UNNAMED"}
             ]

      assert has_element?(view, "#stop_level_id option[value='L1'][selected]")
    end

    test "a stop that may have no level offers a blank choice", ctx do
      view = ctx.view

      stop_fixture(ctx.organization.id, ctx.gtfs_version.id, %{
        stop_id: "FREE_1",
        stop_name: "Free Standing",
        location_type: 0,
        parent_station: nil
      })

      render_click(view, "select_entity", %{"entity_id" => "FREE_1", "entity_type" => "stop"})

      assert level_options(view) == [{"No level", ""}, {"Street (L1)", "L1"}]
      assert has_element?(view, "#stop_level_id option[value=''][selected]")
    end

    test "choosing another existing level stores it", ctx do
      view = ctx.view

      level_fixture(ctx.organization.id, ctx.gtfs_version.id, %{
        level_id: "L2",
        level_name: "Mezzanine",
        level_index: 1.0
      })

      open_stop_drawer(view, "Entrance One")

      view
      |> form("#report-stop-edit-form", stop: %{level_id: "L2"})
      |> render_submit()

      render_async(view, 5_000)

      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1")
      assert stored.level_id == "L2"
    end

    test "a crafted submit naming a missing level saves nothing and marks the level field",
         ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      render_submit(view, "save_entity", %{
        "stop" => %{
          "stop_name" => "Renamed But Rejected",
          "level_id" => "NO_SUCH_LEVEL"
        }
      })

      assert has_element?(view, "dialog#report-entity-drawer-overlay[data-open='true']")
      assert has_element?(view, "#stop_level_id[aria-invalid='true']")

      assert has_element?(
               view,
               "#stop_level_id-error",
               "Choose a level that exists in this version."
             )

      assert has_element?(
               view,
               "#report-stop-form-error a[href='#stop_level_id']",
               "Choose a level that exists in this version."
             )

      assert_push_event(view, "focus_form_error", %{
        form_id: "report-stop-edit-form",
        fallback_id: "report-stop-form-error"
      })

      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1")
      assert stored.level_id == "L1"
      assert stored.stop_name == "Entrance One"
    end

    test "validating a crafted missing level marks the field without writing", ctx do
      view = ctx.view
      open_stop_drawer(view, "Entrance One")

      render_change(view, "validate_entity", %{
        "stop" => %{"level_id" => "NO_SUCH_LEVEL"}
      })

      assert has_element?(
               view,
               "#stop_level_id-error",
               "Choose a level that exists in this version."
             )

      refute has_element?(view, "#report-stop-form-error")

      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_1")
      assert stored.level_id == "L1"
    end

    test "a stored level the version lacks shows a prompt and must be replaced to save", ctx do
      view = ctx.view

      stop_fixture(ctx.organization.id, ctx.gtfs_version.id, %{
        stop_id: "ENT_STALE",
        stop_name: "Stale Level Entrance",
        location_type: 2,
        parent_station: "STATION_1",
        level_id: "DOCQA_NO_SUCH_LEVEL"
      })

      render_click(view, "select_entity", %{"entity_id" => "ENT_STALE", "entity_type" => "stop"})

      assert level_options(view) == [
               {"Choose a level", "DOCQA_NO_SUCH_LEVEL"},
               {"Street (L1)", "L1"}
             ]

      assert has_element?(
               view,
               "#stop_level_id option[value='DOCQA_NO_SUCH_LEVEL'][selected]",
               "Choose a level"
             )

      assert has_element?(
               view,
               "#stop_level_id-help",
               "Stored level DOCQA_NO_SUCH_LEVEL does not exist in this version."
             )

      # Saving with the prompt still selected is refused.
      view |> form("#report-stop-edit-form") |> render_submit()

      assert has_element?(
               view,
               "#stop_level_id-error",
               "Choose a level that exists in this version."
             )

      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_STALE")
      assert stored.level_id == "DOCQA_NO_SUCH_LEVEL"

      view |> form("#report-stop-edit-form", stop: %{level_id: "L1"}) |> render_submit()
      render_async(view, 5_000)

      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "ENT_STALE")
      assert stored.level_id == "L1"
    end

    test "an optional level that no longer exists offers the prompt and No level", ctx do
      view = ctx.view

      stop_fixture(ctx.organization.id, ctx.gtfs_version.id, %{
        stop_id: "FREE_STALE",
        stop_name: "Free Stale",
        location_type: 0,
        parent_station: nil,
        level_id: "DOCQA_NO_SUCH_LEVEL"
      })

      render_click(view, "select_entity", %{
        "entity_id" => "FREE_STALE",
        "entity_type" => "stop"
      })

      assert level_options(view) == [
               {"Choose a level", "DOCQA_NO_SUCH_LEVEL"},
               {"No level", ""},
               {"Street (L1)", "L1"}
             ]

      assert has_element?(view, "#stop_level_id option[value='DOCQA_NO_SUCH_LEVEL'][selected]")

      view |> form("#report-stop-edit-form", stop: %{level_id: ""}) |> render_submit()
      render_async(view, 5_000)

      stored = Gtfs.get_stop_by_stop_id(ctx.organization.id, ctx.gtfs_version.id, "FREE_STALE")
      assert is_nil(stored.level_id)
    end

    test "the drawer names the exact opener so closing restores it", ctx do
      view = ctx.view

      opener_id = stop_link_opener_id(view, "Entrance One")
      assert opener_id != ""

      assert has_element?(
               view,
               "##{opener_id}[phx-click='select_entity'][phx-value-opener_id='#{opener_id}']"
             )

      open_stop_drawer(view, "Entrance One")

      assert has_element?(
               view,
               "dialog#report-entity-drawer-overlay[data-open='true'][data-return-focus-id='#{opener_id}']"
             )

      render_click(view, "close_entity_drawer")

      # The opener is still named while the dialog closes, so focus can return.
      assert has_element?(
               view,
               "dialog#report-entity-drawer-overlay[data-open='false'][data-return-focus-id='#{opener_id}']"
             )

      refute has_element?(view, "#report-stop-edit-form")
      assert has_element?(view, "##{opener_id}")
    end
  end

  # -- helpers --------------------------------------------------------------

  defp stop_link_opener_id(view, entity_name) do
    [id] =
      view
      |> element("[phx-click='select_entity'][phx-value-entity_type='stop']", entity_name)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("id")

    id
  end

  defp report_html(%{view: view}) do
    view |> element("#station-report-2") |> render()
  end

  # Bounded document queries. Every structural assertion is scoped to the report
  # subtree (or to one form) rather than matched against whole-page HTML, so a
  # match can only come from the contract under test.
  defp report_doc(ctx), do: ctx |> report_html() |> LazyHTML.from_fragment()

  defp stop_form_doc(view) do
    view |> element("form#report-stop-edit-form") |> render() |> LazyHTML.from_fragment()
  end

  defp element_count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  # The level select's options in order, as {label, value}.
  defp level_options(view) do
    view
    |> element("#stop_level_id")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(fn option ->
      {option |> LazyHTML.text() |> String.trim(), option |> LazyHTML.attribute("value") |> hd()}
    end)
  end

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

  defp stop_change_logs(ctx) do
    Repo.all(
      from(cl in GtfsPlanner.Gtfs.ChangeLog,
        where:
          cl.organization_id == ^ctx.organization.id and
            cl.gtfs_version_id == ^ctx.gtfs_version.id and cl.entity_type == "stop"
      )
    )
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
