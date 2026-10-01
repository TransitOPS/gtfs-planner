defmodule GtfsPlannerWeb.Gtfs.StopDetailLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.TransfersFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Repo

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

  describe "StopDetailLive - station editing status" do
    setup do
      organization = organization_fixture()
      viewer = user_fixture(%{email: "viewer@example.com"})
      editor = user_fixture(%{email: "editor@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: viewer.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "STATION_STATUS",
          stop_name: "Status Station",
          location_type: 1
        })

      %{
        viewer: viewer,
        editor: editor,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station
      }
    end

    test "assigns an existing station editing status when the station page loads", %{
      conn: conn,
      viewer: viewer,
      editor: editor,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 editor
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status.id == status.id
      assert state.socket.assigns.station_editing_status.user.id == editor.id
      assert state.socket.assigns.station_editing_status.user.email == editor.email
    end

    test "renders the idle station editing status button", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(
               view,
               ~s(#station-editing-status-button[phx-click="set_station_editing_status"][aria-describedby="station-editing-hint"]),
               "Start editing"
             )

      assert has_element?(view, "#station-editing-hint", "Lets teammates know you're editing.")

      render_click(element(view, "#station-editing-status-button"))

      status = Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id)

      assert status.user.id == viewer.id
    end

    test "does not render the station editing status banner when no status is active", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      refute has_element?(view, "#station-editing-status-banner")
    end

    test "renders the owner active station editing status button", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, _status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 viewer
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(
               view,
               ~s(#station-editing-status-button[phx-click="clear_station_editing_status"]),
               "Finish editing"
             )

      assert has_element?(view, "#station-editing-hint", "Tells teammates you're done.")

      render_click(element(view, "#station-editing-status-button"))

      assert Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id) == nil
    end

    test "renders the owner station editing status banner copy", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      started_at = DateTime.add(DateTime.utc_now(), -5 * 60, :second)

      station_editing_status_fixture_started_at!(
        organization,
        gtfs_version,
        station,
        viewer,
        started_at
      )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(view, "#station-editing-status-banner", "You're editing this station.")

      assert has_element?(
               view,
               "#station-editing-status-banner",
               "Teammates who open it see that you're editing. Select Finish editing when you're done."
             )

      assert has_element?(view, "#station-editing-status-banner[role='status']")

      assert has_element?(view, "#station-editing-status-banner", "Started 5 minutes ago")
      refute has_element?(view, "#station-editing-status-banner-clear-button")
    end

    test "renders the other-user active station editing status button", %{
      conn: conn,
      viewer: viewer,
      editor: editor,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, _status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 editor
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(
               view,
               ~s(#station-editing-status-button[phx-click="clear_station_editing_status"]),
               "Clear editing status"
             )

      assert has_element?(view, "#station-editing-hint", "Clears the status for everyone.")
    end

    test "renders the other-user station editing status banner copy", %{
      conn: conn,
      viewer: viewer,
      editor: editor,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      started_at = DateTime.add(DateTime.utc_now(), -60 * 60, :second)

      station_editing_status_fixture_started_at!(
        organization,
        gtfs_version,
        station,
        editor,
        started_at
      )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert has_element?(
               view,
               "#station-editing-status-banner",
               "#{editor.email} is editing this station."
             )

      assert has_element?(
               view,
               "#station-editing-status-banner",
               "You can view it, but it's best to wait before making changes."
             )

      assert has_element?(view, "#station-editing-status-banner[role='status']")

      assert has_element?(view, "#station-editing-status-banner", "Started 1 hour ago")
      refute has_element?(view, "#station-editing-status-banner-clear-button")
    end

    test "renders every relative started time bucket in the station editing status banner", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      cases = [
        {0, "just now"},
        {60, "1 minute ago"},
        {5 * 60, "5 minutes ago"},
        {60 * 60, "1 hour ago"},
        {3 * 60 * 60, "3 hours ago"}
      ]

      Enum.each(cases, fn {seconds_ago, expected} ->
        station =
          stop_fixture(organization.id, gtfs_version.id, %{
            stop_id: "STATUS_TIME_#{seconds_ago}",
            stop_name: "Status Time #{seconds_ago}",
            location_type: 1
          })

        started_at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

        station_editing_status_fixture_started_at!(
          organization,
          gtfs_version,
          station,
          viewer,
          started_at
        )

        {:ok, view, _html} =
          live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

        assert has_element?(
                 view,
                 "#station-editing-status-banner",
                 "Started #{expected}"
               )
      end)
    end

    test "updates the station editing status assign from PubSub broadcasts", %{
      conn: conn,
      viewer: viewer,
      editor: editor,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.station_editing_status == nil

      assert {:ok, status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 editor
               )

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status.id == status.id
      assert state.socket.assigns.station_editing_status.user.id == editor.id

      assert :ok = Gtfs.clear_station_editing_status(organization.id, gtfs_version.id, station.id)

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.station_editing_status == nil
    end

    test "set_station_editing_status event creates a status owned by the current user", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      render_click(view, "set_station_editing_status")

      # The button blurs while it saves, so focus is sent back to it.
      assert_push_event(view, "focus_scoped_target", %{id: "station-editing-status-button"})

      state = :sys.get_state(view.pid)
      assigned_status = state.socket.assigns.station_editing_status

      persisted_status =
        Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id)

      assert assigned_status.user.id == viewer.id
      assert persisted_status.id == assigned_status.id
      assert persisted_status.user.id == viewer.id
    end

    test "clear_station_editing_status event clears the active status", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, _status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 viewer
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      render_click(view, "clear_station_editing_status")

      assert_push_event(view, "focus_scoped_target", %{id: "station-editing-status-button"})

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status == nil
      assert Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id) == nil
    end

    test "clear_station_editing_status event keeps an already-cleared station idle", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      render_click(view, "clear_station_editing_status")

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status == nil
      refute has_element?(view, "#station-editing-status-banner")

      assert has_element?(
               view,
               ~s(#station-editing-status-button[phx-click="set_station_editing_status"]),
               "Start editing"
             )

      assert Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id) == nil
    end

    test "redirects with flash when station is missing", %{
      conn: conn,
      viewer: viewer,
      organization: organization,
      gtfs_version: gtfs_version
    } do
      conn = log_in_user(conn, viewer, organization: organization)

      assert {:error, {:live_redirect, %{to: to_path, flash: %{"error" => message}}}} =
               live(conn, "/gtfs/#{gtfs_version.id}/stops/UNKNOWN_STATUS")

      assert to_path == "/gtfs/#{gtfs_version.id}/stops"
      assert message =~ "We couldn't find that stop or station in #{gtfs_version.name}."
    end

    test "set_station_editing_status event leaves the assign unchanged when setting fails", %{
      conn: conn,
      viewer: viewer,
      editor: editor,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      assert {:ok, status} =
               Gtfs.set_station_editing_status(
                 organization.id,
                 gtfs_version.id,
                 station,
                 editor
               )

      conn = log_in_user(conn, viewer, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert {:ok, _station} = Repo.delete(station)

      render_click(view, "set_station_editing_status")

      assert_push_event(view, "focus_scoped_target", %{id: "station-editing-status-button"})

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status.id == status.id
      assert state.socket.assigns.station_editing_status.user.id == editor.id
      assert has_element?(view, "#editing-error[role='alert']", "We couldn't start editing")
      assert has_element?(view, "#editing-error", "Teammates won't see that you're editing.")
      assert has_element?(view, "#editing-error-retry", "Try again")
      assert Gtfs.get_station_editing_status(organization.id, gtfs_version.id, station.id) == nil
    end
  end

  defp station_editing_status_fixture_started_at!(
         organization,
         gtfs_version,
         station,
         user,
         started_at
       ) do
    assert {:ok, status} =
             Gtfs.set_station_editing_status(
               organization.id,
               gtfs_version.id,
               station,
               user
             )

    status
    |> Ecto.Changeset.change(started_at: started_at)
    |> Repo.update!()
    |> Repo.preload(:user)
  end

  describe "StopDetailLive - No level child stop assign link" do
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

      level =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "L1",
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

      %{
        user: user,
        organization: organization,
        gtfs_version: gtfs_version,
        station: station,
        level: level
      }
    end

    test "renders an Assign level link for No level child stops with correct href", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      # ORPHAN_LEVEL is a level_id with no matching Level row, so the
      # stop's preloaded :level association is nil → groups under "No Level".
      no_level_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_NO_LEVEL",
          stop_name: "Child No Level",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "ORPHAN_LEVEL"
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      expected_href =
        "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?edit_child_stop_id=#{no_level_stop.id}"

      assert has_element?(
               view,
               "#child-stop-row-#{no_level_stop.id} a[href=\"#{expected_href}\"]",
               "Assign level"
             )
    end

    test "does not render an Assign level link for child stops with a level", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      leveled_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_WITH_LEVEL",
          stop_name: "Child With Level",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      assert html =~ "CHILD_WITH_LEVEL"
      assert html =~ "Child With Level"

      refute has_element?(
               view,
               "#child-stop-row-#{leveled_stop.id} a",
               "Assign level"
             )
    end

    test "only No level rows get the Assign level link when both groups exist", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level
    } do
      no_level_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_NO_LEVEL_2",
          stop_name: "Child No Level 2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "ORPHAN_LEVEL_2"
        })

      leveled_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "CHILD_WITH_LEVEL_2",
          stop_name: "Child With Level 2",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: level.level_id
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}", on_error: :warn)

      expected_href =
        "/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram?edit_child_stop_id=#{no_level_stop.id}"

      assert has_element?(
               view,
               "#child-stop-row-#{no_level_stop.id} a[href=\"#{expected_href}\"]",
               "Assign level"
             )

      refute has_element?(
               view,
               "#child-stop-row-#{leveled_stop.id} a",
               "Assign level"
             )
    end
  end

  describe "StopDetailLive - stop ID with reserved URL characters" do
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
          stop_id: "QA/STN 1",
          stop_name: "Slash Station",
          location_type: 1
        })

      level =
        level_fixture(organization.id, gtfs_version.id, %{level_id: "L1", level_index: 0.0})

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

    test "encodes the stop ID in the Assign level link and keeps its query parameter", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station
    } do
      no_level_stop =
        stop_fixture(organization.id, gtfs_version.id, %{
          stop_id: "QA/CHILD 1",
          stop_name: "Slash Child",
          location_type: 0,
          parent_station: station.stop_id,
          level_id: "ORPHAN_LEVEL"
        })

      conn = log_in_user(conn, user, organization: organization)
      base = "/gtfs/#{gtfs_version.id}/stops/QA%2FSTN%201"

      {:ok, view, _html} = live(conn, base, on_error: :warn)

      expected_href = "#{base}/diagram?edit_child_stop_id=#{no_level_stop.id}"

      assert has_element?(
               view,
               "#child-stop-row-#{no_level_stop.id} a[href=\"#{expected_href}\"]",
               "Assign level"
             )

      {:ok, diagram_view, _html} = live(conn, expected_href, on_error: :warn)

      assert has_element?(diagram_view, "#station-sub-nav h1", "Slash Station")
    end
  end

  describe "StopDetailLive - station facts and regions (Mox)" do
    setup do
      previous = Application.fetch_env(:gtfs_planner, @adapter_key)
      Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
          :error -> Application.delete_env(:gtfs_planner, @adapter_key)
        end
      end)
    end

    setup do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    defp build_stop(organization_id, gtfs_version_id, attrs) do
      %GtfsPlanner.Gtfs.Stop{
        id: Ecto.UUID.generate(),
        stop_id: Map.get(attrs, :stop_id, "TEST_STOP"),
        stop_name: Map.get(attrs, :stop_name, "Test Station"),
        stop_desc: Map.get(attrs, :stop_desc),
        stop_lat: Map.get(attrs, :stop_lat, Decimal.new("40.7128")),
        stop_lon: Map.get(attrs, :stop_lon, Decimal.new("-74.0060")),
        location_type: Map.get(attrs, :location_type, 1),
        wheelchair_boarding: Map.get(attrs, :wheelchair_boarding),
        platform_code: Map.get(attrs, :platform_code),
        level_id: Map.get(attrs, :level_id),
        diagram_coordinate: Map.get(attrs, :diagram_coordinate),
        parent_station: Map.get(attrs, :parent_station),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    end

    defp stub_fetch_stop(result) do
      stub(CatalogReadAdapterMock, :fetch_stop, fn _org, _ver, _stop_id -> result end)
    end

    defp stub_load_regions(regions) do
      stub(CatalogReadAdapterMock, :load_stop_regions, fn _org, _ver, _stop -> regions end)
    end

    defp default_regions do
      %{
        child_stops: {:ok, []},
        levels: {:ok, []},
        pathways: {:ok, []},
        editing_status: {:ok, nil}
      }
    end

    test "station facts render in dl/dt/dd with one h1, no C0 control characters", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{
          stop_id: "FACTS1",
          stop_name: "Facts Station",
          stop_desc: "A test station",
          platform_code: "P1"
        })

      stub_fetch_stop({:ok, stop})
      stub_load_regions(default_regions())

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      html = render(view)
      doc = LazyHTML.from_fragment(html)

      h1s = Enum.to_list(LazyHTML.query(doc, "h1"))
      dls = Enum.to_list(LazyHTML.query(doc, "dl"))
      dts = Enum.to_list(LazyHTML.query(doc, "dt"))
      dds = Enum.to_list(LazyHTML.query(doc, "dd"))

      assert length(h1s) == 1
      refute Enum.empty?(dls)
      refute Enum.empty?(dts)
      refute Enum.empty?(dds)

      refute html =~ ~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/
    end

    test "accessibility shows tri-state with inherited source disclosure", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{
          stop_id: "ACCESS1",
          stop_name: "Accessible Station",
          wheelchair_boarding: 1
        })

      stub_fetch_stop({:ok, stop})
      stub_load_regions(default_regions())

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(view, "[data-accessibility='accessible']", "Accessible")
    end

    test "a stop inside a station says whether it is placed on a floorplan", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop_with_diagram =
        build_stop(organization.id, version.id, %{
          stop_id: "DIAG1",
          stop_name: "Diagram Platform",
          location_type: 0,
          parent_station: "DIAG_PARENT",
          diagram_coordinate: %{"x" => 100, "y" => 200}
        })

      stub_fetch_stop({:ok, stop_with_diagram})
      stub_load_regions(default_regions())

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop_with_diagram.stop_id}")

      assert has_element?(view, "#diagram-status", "Placed on a floorplan")

      stop_without_diagram =
        build_stop(organization.id, version.id, %{
          stop_id: "DIAG2",
          stop_name: "No Diagram Platform",
          location_type: 0,
          parent_station: "DIAG_PARENT",
          diagram_coordinate: nil
        })

      stub_fetch_stop({:ok, stop_without_diagram})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop_without_diagram.stop_id}")

      assert has_element?(view, "#diagram-status", "Not on a floorplan")
    end

    test "pathway rows show mode, direction, the joined points, and only supplied metrics", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{
          stop_id: "PATH1",
          stop_name: "Pathway Station"
        })

      pathway = %GtfsPlanner.Gtfs.Pathway{
        id: Ecto.UUID.generate(),
        pathway_id: "PW1",
        pathway_mode: 2,
        is_bidirectional: true,
        stair_count: 12,
        traversal_time: 30,
        length: nil,
        from_stop_id: "FROM1",
        to_stop_id: "TO1",
        from_stop: %{stop_name: "North entrance"},
        to_stop: %{stop_name: nil},
        organization_id: organization.id,
        gtfs_version_id: version.id,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      stub_fetch_stop({:ok, stop})

      stub_load_regions(%{
        default_regions()
        | pathways: {:ok, [pathway]}
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      # Each end reads as the stop's name, or its ID when the name is missing.
      assert has_element?(view, "#pathways-table [data-pathway-summary]", "North entrance")
      assert has_element?(view, "#pathways-table [data-pathway-summary]", "TO1")
      assert has_element?(view, "#pathways-table [data-pathway-summary]", "and back to")
      assert has_element?(view, "#pathways-table [data-pathway-summary]", "Stairs")
      assert has_element?(view, "#pathways-table [data-pathway-summary]", "12 stairs")
      assert has_element?(view, "#pathways-table [data-pathway-summary]", "30 s")

      # A length the feed does not give is announced as not set, not left blank.
      assert has_element?(view, "#pathways-table [data-pathway-summary]", "Length not set")
    end

    test "pathway lengths read without trailing zeros", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{stop_id: "LEN1", stop_name: "Length Station"})

      pathway = fn id, length ->
        %GtfsPlanner.Gtfs.Pathway{
          id: Ecto.UUID.generate(),
          pathway_id: id,
          pathway_mode: 1,
          is_bidirectional: false,
          length: length,
          traversal_time: 20,
          from_stop_id: "A",
          to_stop_id: "B",
          organization_id: organization.id,
          gtfs_version_id: version.id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end

      stub_fetch_stop({:ok, stop})

      stub_load_regions(%{
        default_regions()
        | pathways:
            {:ok,
             [
               pathway.("PW_WHOLE", Decimal.new("14.00")),
               pathway.("PW_HALF", Decimal.new("8.50"))
             ]}
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(view, "#pathways-table tr", "PW_WHOLE")
      assert has_element?(view, "#pathways-table tr", "14 m")
      assert has_element?(view, "#pathways-table tr", "8.5 m")
      refute has_element?(view, "#pathways-table", "14.00")
    end

    test "child/level/pathway unavailable shows stable-ID region with retry", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{
          stop_id: "UNAVAIL1",
          stop_name: "Unavailable Station"
        })

      stub_fetch_stop({:ok, stop})

      stub_load_regions(%{
        child_stops: {:error, :unavailable},
        levels: {:error, :unavailable},
        pathways: {:error, :unavailable},
        editing_status: {:ok, nil}
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(view, "#child-stops-unavailable")
      assert has_element?(view, "#child-stops-retry")
      assert has_element?(view, "#levels-unavailable")
      assert has_element?(view, "#levels-retry")
      assert has_element?(view, "#pathways-unavailable")
      assert has_element?(view, "#pathways-retry")
    end

    test "empty child/level/pathway shows explanatory state", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{
          stop_id: "EMPTY1",
          stop_name: "Empty Station"
        })

      stub_fetch_stop({:ok, stop})
      stub_load_regions(default_regions())

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(view, "#inside-empty")
      assert has_element?(view, "#pathways-empty")
    end

    test "Start editing button has phx-disable-with; error preserves prior status", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{
          stop_id: "EDIT1",
          stop_name: "Edit Station"
        })

      stub_fetch_stop({:ok, stop})
      stub_load_regions(default_regions())

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(
               view,
               ~s(#station-editing-status-button[phx-disable-with="Starting…"]),
               "Start editing"
             )
    end

    test "clear editing status error shows in-flow callout with retry", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{
          stop_id: "CLEARERR1",
          stop_name: "Clear Error Station"
        })

      stub_fetch_stop({:ok, stop})

      editing_status = %GtfsPlanner.Gtfs.StationEditingStatus{
        id: Ecto.UUID.generate(),
        user_id: user.id,
        user: user,
        started_at: DateTime.utc_now(),
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_id: stop.id
      }

      stub_load_regions(%{
        default_regions()
        | editing_status: {:ok, editing_status}
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(view, "#station-editing-status-banner")
    end

    test "not-found stop redirects; unavailable base shows full-page error with retry", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_fetch_stop({:error, :not_found})
      stub_load_regions(default_regions())

      assert {:error, {:live_redirect, %{to: to_path}}} =
               live(conn, "/gtfs/#{version.id}/stops/MISSING")

      assert to_path == "/gtfs/#{version.id}/stops"

      stub_fetch_stop({:error, :unavailable})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/UNAVAIL")

      assert has_element?(view, "#stop-unavailable")
      assert has_element?(view, "#stop-retry")
    end

    test "a station whose editing status cannot be read disables editing and offers a reload",
         %{conn: conn, user: user, organization: organization, gtfs_version: version} do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{stop_id: "NOSTATUS1", stop_name: "No Status"})

      stub_fetch_stop({:ok, stop})
      stub_load_regions(%{default_regions() | editing_status: {:error, :unavailable}})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(view, "#station-editing-status-button[disabled]", "Start editing")
      assert has_element?(view, "#station-editing-hint", "We couldn't check who is editing.")
      refute has_element?(view, "#station-editing-status-banner")

      stub_load_regions(default_regions())
      render_click(element(view, "#station-editing-reload"))

      refute has_element?(view, "#station-editing-reload")

      refute has_element?(view, "#station-editing-status-button[disabled]")

      assert has_element?(
               view,
               ~s(#station-editing-status-button[phx-click="set_station_editing_status"])
             )
    end

    test "a stop with no coordinates says so and where they come from", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop =
        build_stop(organization.id, version.id, %{
          stop_id: "NOLOC1",
          stop_name: "Nowhere",
          stop_lat: nil,
          stop_lon: nil
        })

      stub_fetch_stop({:ok, stop})
      stub_load_regions(default_regions())

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(view, "#stop-no-location", "No location recorded")
      assert has_element?(view, "#location-card", "Coordinates come from the stops file")
      refute has_element?(view, "#stop-coordinates")
    end

    test "a stop with coordinates shows them as stored", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = build_stop(organization.id, version.id, %{stop_id: "LOC1", stop_name: "Somewhere"})

      stub_fetch_stop({:ok, stop})
      stub_load_regions(default_regions())

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(view, "#stop-coordinates", "40.7128, -74.0060")
    end

    test "reloading the stops region after it failed brings the floors back", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop = build_stop(organization.id, version.id, %{stop_id: "RELOAD1", stop_name: "Reload"})

      stub_fetch_stop({:ok, stop})
      stub_load_regions(%{default_regions() | child_stops: {:error, :unavailable}})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(view, "#child-stops-unavailable[role='alert']", "The rest of the page")

      child =
        build_stop(organization.id, version.id, %{
          stop_id: "KID1",
          stop_name: "Bay 1",
          location_type: 0
        })

      stub_load_regions(%{default_regions() | child_stops: {:ok, [child]}})
      render_click(element(view, "#child-stops-retry"))

      refute has_element?(view, "#child-stops-unavailable")
      assert has_element?(view, "#child-stop-row-#{child.id}", "Bay 1")
      assert has_element?(view, "#level-none", "No level assigned")
    end
  end

  describe "StopDetailLive - related transfers" do
    setup %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)
      transfer_network_fixture(organization.id, version.id)

      %{
        conn: log_in_user(conn, user, organization: organization),
        organization: organization,
        version: version
      }
    end

    test "a station counts itself and its children; a platform counts only itself", ctx do
      station_rule = rule!(ctx, %{from_stop_id: "CEN", to_stop_id: "MKT"})
      platform_rule = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "HBR"})
      bay_c_rule = rule!(ctx, %{from_stop_id: "CEN-C", to_stop_id: "MUS"})
      entrance_rule = rule!(ctx, %{from_stop_id: "CEN-E", to_stop_id: "MKT"})
      _other_rule = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR"})

      # The list's own stop filter matches the station and every stop whose parent
      # it is, whatever the child's location type, so the count follows that
      # predicate instead of inventing a narrower coverage of its own (CR-4, FH-11).
      station_href = "/gtfs/#{ctx.version.id}/transfers?stop=CEN"

      {:ok, station_view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/CEN")

      assert has_element?(station_view, "#stop-transfers-link", "4 transfer rules here")
      assert link_href(station_view, "#stop-transfers-link") == station_href

      {:ok, station_list, _html} = live(ctx.conn, station_href)

      assert Enum.sort(row_ids(station_list)) ==
               Enum.sort(
                 Enum.map(
                   [station_rule, platform_rule, bay_c_rule, entrance_rule],
                   &"transfers-#{&1.id}"
                 )
               )

      {:ok, platform_view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/CEN-A")

      assert has_element?(platform_view, "#stop-transfers-link", "1 transfer rule here")

      {:ok, platform_list, _html} =
        live(ctx.conn, link_href(platform_view, "#stop-transfers-link"))

      assert row_ids(platform_list) == ["transfers-#{platform_rule.id}"]
    end

    test "a stop with no related rules says so and opens an empty list", ctx do
      rule!(ctx, %{from_stop_id: "CEN-C", to_stop_id: "MUS"})

      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/NOC")

      assert has_element?(view, "#stop-transfers-link", "No transfer rules here")

      {:ok, list, _html} = live(ctx.conn, link_href(view, "#stop-transfers-link"))

      assert row_ids(list) == []
    end
  end

  describe "StopDetailLive - station workspace" do
    setup %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "WS_STATION",
          stop_name: "Workspace Station",
          location_type: 1,
          wheelchair_boarding: 1
        })

      %{
        conn: log_in_user(conn, user, organization: organization),
        organization: organization,
        version: version,
        station: station
      }
    end

    defp add_level(ctx, level_id, index, name, diagram_filename \\ nil) do
      level =
        level_fixture(ctx.organization.id, ctx.version.id, %{
          level_id: level_id,
          level_name: name,
          level_index: index
        })

      {:ok, _stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.version.id,
          stop_id: ctx.station.id,
          level_id: level.id,
          diagram_filename: diagram_filename
        })

      level
    end

    defp add_child(ctx, stop_id, attrs) do
      stop_fixture(
        ctx.organization.id,
        ctx.version.id,
        Map.merge(
          %{
            stop_id: stop_id,
            stop_name: stop_id,
            location_type: 0,
            parent_station: ctx.station.stop_id,
            # A stop inside a station needs a level ID; this one names no level.
            level_id: "WS_UNLEVELLED"
          },
          attrs
        )
      )
    end

    defp floor_ids(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#inside section[id^='level-']")
      |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))
    end

    test "a station offers its views and one primary link to Floorplans", ctx do
      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/WS_STATION")

      assert has_element?(view, "#station-tab-details[aria-current='page']", "Details")
      assert has_element?(view, "#station-tab-diagram", "Floorplans")
      assert has_element?(view, "#station-tab-report", "Reports")
      assert has_element?(view, "#station-tab-reachability", "Reachability")
      assert has_element?(view, "#station-tab-evolutions", "Closures")

      assert link_href(view, "#open-floorplans") ==
               "/gtfs/#{ctx.version.id}/stops/WS_STATION/diagram"

      assert has_element?(view, "#station-sub-nav", "Station · nothing added yet")
      assert has_element?(view, "#station-sub-nav", "WS_STATION")
    end

    test "a stop that is not a station has no views, editing control or station sections", ctx do
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "WS_STOP",
        stop_name: "Workspace Stop",
        location_type: 0
      })

      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/WS_STOP")

      assert has_element?(view, "h1", "Workspace Stop")
      assert has_element?(view, "#station-sub-nav", "Stop")
      refute has_element?(view, "#station-sub-nav nav")
      refute has_element?(view, "#station-editing-status-button")
      refute has_element?(view, "#open-floorplans")
      refute has_element?(view, "#inside")
      refute has_element?(view, "#pathways-card")
      refute has_element?(view, "#station-journal-summary")
      assert has_element?(view, "#facts-card")
      assert has_element?(view, "#location-card")
    end

    test "a platform names its station and follows the station's wheelchair access", ctx do
      add_child(ctx, "WS_BAY", %{stop_name: "Bay 2", platform_code: "2"})

      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/WS_BAY")

      assert has_element?(view, "#station-back", "Workspace Station")

      assert link_href(view, "#station-back") ==
               "/gtfs/#{ctx.version.id}/stops/WS_STATION"

      assert has_element?(view, "#stop-parent-link", "Workspace Station")
      assert has_element?(view, "#stop-platform-code", "2")

      assert has_element?(view, "#stop-accessibility [data-accessibility='accessible']")
      assert has_element?(view, "#stop-accessibility [data-accessibility-source='inherited']")

      assert has_element?(view, "#stop-accessibility", "Follows the station")
    end

    test "groups a station's stops by level, ground first and stops with no level last", ctx do
      basement = add_level(ctx, "WS_LB1", -1.0, "Basement")
      street = add_level(ctx, "WS_L0", 0.0, "Street level")
      concourse = add_level(ctx, "WS_L1", 1.0, "Concourse")

      add_child(ctx, "WS_B1", %{level_id: street.level_id})
      add_child(ctx, "WS_UL", %{location_type: 3, level_id: concourse.level_id})
      add_child(ctx, "WS_ORPHAN", %{level_id: "WS_MISSING_LEVEL"})

      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/WS_STATION")

      assert floor_ids(view) == [
               "level-#{street.level_id}",
               "level-#{concourse.level_id}",
               "level-#{basement.level_id}",
               "level-none"
             ]

      assert has_element?(view, "#level-none", "Pathways can't use a stop until it has a level.")
      assert has_element?(view, "#level-#{basement.level_id}", "No stops on this level yet.")
      assert has_element?(view, "#level-#{street.level_id}", "Level 0 · 1 stop")

      assert has_element?(
               view,
               "#station-sub-nav",
               "Station · 2 platforms, 0 entrances, 1 connection point, 3 levels"
             )
    end

    test "says which levels have a floorplan", ctx do
      add_level(ctx, "WS_L0", 0.0, "Street level", "street.png")
      add_level(ctx, "WS_L1", 1.0, "Concourse")

      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/WS_STATION")

      assert has_element?(view, "#diagram-status-WS_L0", "Floorplan added")
      assert has_element?(view, "#diagram-status-WS_L1", "No floorplan yet")
      assert has_element?(view, "#station-floorplans-status", "1 of 2 levels has a floorplan")
    end

    test "shows the first six pathways and reveals the rest on request", ctx do
      add_child(ctx, "WS_A", %{stop_name: "Waiting room"})
      add_child(ctx, "WS_B", %{stop_name: "Bay 1"})

      for n <- 1..8 do
        pathway_fixture(ctx.organization.id, ctx.version.id, "WS_A", "WS_B", %{
          pathway_id: "WS_PW_#{n}"
        })
      end

      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/WS_STATION")

      assert pathway_row_count(view) == 6
      assert has_element?(view, "#pathways-toggle[aria-expanded='false']", "Show all 8 pathways")
      assert has_element?(view, "#pathways-card", "Waiting room")

      render_click(element(view, "#pathways-toggle"))

      assert pathway_row_count(view) == 8
      assert has_element?(view, "#pathways-toggle[aria-expanded='true']", "Show fewer pathways")

      render_click(element(view, "#pathways-toggle"))

      assert pathway_row_count(view) == 6
    end

    test "offers no reveal control when every pathway already shows", ctx do
      add_child(ctx, "WS_A", %{})
      add_child(ctx, "WS_B", %{})
      pathway_fixture(ctx.organization.id, ctx.version.id, "WS_A", "WS_B")

      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/WS_STATION")

      assert pathway_row_count(view) == 1
      refute has_element?(view, "#pathways-toggle")
    end

    test "keeps the stored fields behind a disclosure", ctx do
      {:ok, view, _html} = live(ctx.conn, "/gtfs/#{ctx.version.id}/stops/WS_STATION")

      assert has_element?(view, "#gtfs-details summary", "GTFS fields for this station")
      assert has_element?(view, "#gtfs-details dt", "stop_id")
      assert has_element?(view, "#gtfs-details dd", "WS_STATION")
      assert has_element?(view, "#gtfs-details dd", "Station (1)")
    end

    defp pathway_row_count(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pathways-rows tr")
      |> Enum.count()
    end
  end

  defp rule!(ctx, attrs),
    do:
      transfer_fixture(ctx.organization.id, ctx.version.id, Map.put_new(attrs, :transfer_type, 0))

  defp link_href(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a")
    |> LazyHTML.attribute("href")
    |> List.first()
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody#transfers tr")
    |> Enum.map(fn row -> row |> LazyHTML.attribute("id") |> List.first() end)
  end
end
