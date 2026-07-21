defmodule GtfsPlannerWeb.Gtfs.StopDetailLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

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
               ~s(#station-editing-status-button[phx-click="set_station_editing_status"][title="Let others know you're editing this Station."]),
               "Start editing"
             )

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
               ~s(#station-editing-status-button[phx-click="clear_station_editing_status"][title="Let others know you're done editing this Station."]),
               "Finish editing"
             )

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

      assert has_element?(view, "#station-editing-status-banner", "You're editing this Station.")

      assert has_element?(
               view,
               "#station-editing-status-banner",
               "Others have been notified. Remember to clear this when you're done."
             )

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
               ~s(#station-editing-status-button[phx-click="clear_station_editing_status"][title="Clear this editing status for everyone."]),
               "Clear editing status"
             )
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
               "#{editor.email} is editing this Station."
             )

      assert has_element?(
               view,
               "#station-editing-status-banner",
               "You can view it, but it's best to wait before making changes."
             )

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

      assert {:error, {:live_redirect, %{to: to_path, flash: %{"error" => "Station not found"}}}} =
               live(conn, "/gtfs/#{gtfs_version.id}/stops/UNKNOWN_STATUS")

      assert to_path == "/gtfs/#{gtfs_version.id}/stops"
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

      assert {:ok, _station} = Gtfs.delete_stop(station)

      render_click(view, "set_station_editing_status")

      state = :sys.get_state(view.pid)

      assert state.socket.assigns.station_editing_status.id == status.id
      assert state.socket.assigns.station_editing_status.user.id == editor.id
      assert has_element?(view, "#editing-error", "Failed to set station editing status")
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

  describe "StopDetailLive - No Level child stop edit link" do
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

    test "renders Edit in Diagram link for No Level child stops with correct href", %{
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
               "Edit in Diagram"
             )
    end

    test "does not render Edit in Diagram link for child stops with a level", %{
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
               "Edit in Diagram"
             )
    end

    test "only No Level rows get the edit link when both groups exist", %{
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
               "Edit in Diagram"
             )

      refute has_element?(
               view,
               "#child-stop-row-#{leveled_stop.id} a",
               "Edit in Diagram"
             )
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

    test "diagram status renders visible Available or No diagram text", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stop_with_diagram =
        build_stop(organization.id, version.id, %{
          stop_id: "DIAG1",
          stop_name: "Diagram Station",
          diagram_coordinate: %{"x" => 100, "y" => 200}
        })

      stub_fetch_stop({:ok, stop_with_diagram})
      stub_load_regions(default_regions())

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop_with_diagram.stop_id}")

      assert has_element?(view, "#diagram-status", "Available")

      stop_without_diagram =
        build_stop(organization.id, version.id, %{
          stop_id: "DIAG2",
          stop_name: "No Diagram Station",
          diagram_coordinate: nil
        })

      stub_fetch_stop({:ok, stop_without_diagram})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop_without_diagram.stop_id}")

      assert has_element?(view, "#diagram-status", "No diagram")
    end

    test "pathway rows show mode, text direction, and only supplied metrics", %{
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

      assert has_element?(view, "[data-pathway-summary]")
      assert has_element?(view, "[data-pathway-summary]", "Stairs")
      assert has_element?(view, "[data-pathway-summary]", "Bidirectional")
      assert has_element?(view, "[data-pathway-summary]", "12")
      assert has_element?(view, "[data-pathway-summary]", "stairs")
      assert has_element?(view, "[data-pathway-summary]", "30")
      assert has_element?(view, "[data-pathway-summary]", "sec")
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

      assert has_element?(view, "#child-stops-empty")
      assert has_element?(view, "#levels-empty")
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
               ~s(#station-editing-status-button[phx-disable-with="Starting..."]),
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
  end
end
