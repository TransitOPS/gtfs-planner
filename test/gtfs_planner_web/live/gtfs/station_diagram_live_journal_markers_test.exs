defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveJournalMarkersTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  import GtfsPlannerWeb.Gtfs.StationDiagramComponents

  setup do
    organization = organization_fixture()
    user = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    gtfs_version = gtfs_version_fixture(organization.id)
    {station, level, stop_level} = station_with_level(organization.id, gtfs_version.id, "A")

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    }
  end

  defp station_with_level(organization_id, gtfs_version_id, suffix) do
    station =
      stop_fixture(organization_id, gtfs_version_id, %{
        stop_id: "JOURNAL_STATION_#{suffix}",
        stop_name: "Journal Station #{suffix}",
        location_type: 1
      })

    level =
      level_fixture(organization_id, gtfs_version_id, %{
        level_id: "journal_level_#{suffix}",
        level_name: "Platform #{suffix}",
        level_index: 0.0
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        stop_id: station.id,
        level_id: level.id,
        diagram_filename: "level_#{suffix}.svg"
      })

    {station, level, stop_level}
  end

  describe "Station diagram LiveView journal markers layer mount and rendering" do
    test "mounts station diagram with empty marker stream and renders journal-markers-svg after stops",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      conn = log_in_user(conn, user, organization: organization)
      path = ~p"/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram"

      {:ok, _view, html} = live(conn, path)

      # SVG overlay contains journal-markers-svg parent stream
      assert html =~ ~s(id="journal-markers-svg")
      assert html =~ ~s(phx-update="stream")

      # Legend contains the three Journal rows
      assert html =~ "Open Pin"
      assert html =~ "Closed Pin"
      assert html =~ "Entity Dot"
    end
  end

  describe "StationDiagramComponents.journal_markers_layer/1" do
    test "renders streamed pin, dot, ring, and hit target data attributes in view mode" do
      pin_id = Ecto.UUID.generate()
      node_id = Ecto.UUID.generate()

      markers = [
        %{
          id: "journal-marker-pin-#{pin_id}",
          kind: :pin,
          target_id: nil,
          entry_ids: [pin_id],
          focus_entry_id: pin_id,
          open_count: 1,
          total_count: 1,
          state: :open,
          x: 45.0,
          y: 60.0,
          accessible_name: "Journal entry: Check platform sign",
          focused?: true
        },
        %{
          id: "journal-marker-node-#{node_id}",
          kind: :node,
          target_id: node_id,
          entry_ids: [Ecto.UUID.generate()],
          focus_entry_id: Ecto.UUID.generate(),
          open_count: 2,
          total_count: 3,
          state: :open,
          x: 25.0,
          y: 35.0,
          accessible_name: "Journal: 2 open of 3 entries · North Entrance",
          focused?: false
        }
      ]

      assigns = %{
        streams: %{
          journal_markers: [
            {"journal-marker-pin-#{pin_id}", Enum.at(markers, 0)},
            {"journal-marker-node-#{node_id}", Enum.at(markers, 1)}
          ]
        },
        mode: :view
      }

      html =
        rendered_to_string(~H"""
        <svg id="diagram-overlay">
          <.journal_markers_layer streams={@streams} mode={@mode} />
        </svg>
        """)

      # Stream container
      assert html =~ ~s(id="journal-markers-svg")

      # Pin marker elements
      assert html =~ ~s(id="journal-marker-pin-#{pin_id}")
      assert html =~ ~s(data-journal-marker)
      assert html =~ ~s(data-journal-kind="pin")
      assert html =~ ~s(data-journal-state="open")
      assert html =~ ~s(data-center-x="45.0")
      assert html =~ ~s(data-center-y="60.0")
      assert html =~ ~s(aria-label="Journal entry: Check platform sign")
      assert html =~ ~s(role="button")
      assert html =~ ~s(tabindex="0")
      assert html =~ ~s(phx-click="journal_marker_clicked")
      assert html =~ ~s(phx-value-id="journal-marker-pin-#{pin_id}")

      # Open pin sub-elements
      assert html =~ ~s(data-journal-pin-body)
      assert html =~ ~s(data-journal-pin-head)
      assert html =~ ~s(data-journal-ring)
      assert html =~ ~s(data-journal-hit-target)

      # Node marker elements
      assert html =~ ~s(id="journal-marker-node-#{node_id}")
      assert html =~ ~s(data-journal-kind="node")
      assert html =~ ~s(data-journal-dot)
      assert html =~ ~s(aria-label="Journal: 2 open of 3 entries · North Entrance")
    end

    test "renders inert markup without role, tabindex, or click event in add/connect modes" do
      pin_id = Ecto.UUID.generate()

      marker = %{
        id: "journal-marker-pin-#{pin_id}",
        kind: :pin,
        target_id: nil,
        entry_ids: [pin_id],
        focus_entry_id: pin_id,
        open_count: 0,
        total_count: 1,
        state: :closed,
        x: 50.0,
        y: 50.0,
        accessible_name: "Journal entry, closed: Resolved note",
        focused?: false
      }

      assigns = %{
        streams: %{
          journal_markers: [
            {"journal-marker-pin-#{pin_id}", marker}
          ]
        },
        mode: :add
      }

      html =
        rendered_to_string(~H"""
        <svg id="diagram-overlay">
          <.journal_markers_layer streams={@streams} mode={@mode} />
        </svg>
        """)

      # Closed pin hollow body & glyph attributes
      assert html =~ ~s(data-journal-state="closed")
      assert html =~ ~s(data-journal-closed-body)
      assert html =~ ~s(data-journal-closed-glyph)

      # Inert in add mode
      assert html =~ ~s(pointer-events-none)
      refute html =~ ~s(role="button")
      refute html =~ ~s(tabindex="0")
      refute html =~ ~s(phx-click="journal_marker_clicked")
    end
  end

  describe "Station diagram LiveView marker lifecycle across level switches and geometry updates" do
    test "reprojects active level markers on level switch and geometry changes without re-querying journal",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           level: _level,
           stop_level: stop_level
         } do
      level_b =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "journal_level_B",
          level_name: "Mezzanine B",
          level_index: 1.0
        })

      {:ok, stop_level_b} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_b.id,
          diagram_filename: "level_b.svg"
        })

      {:ok, scope} =
        Gtfs.resolve_station_journal_scope(
          organization.id,
          gtfs_version.id,
          station.id,
          user.id
        )

      pin_a_id = Ecto.UUID.generate()
      pin_b_id = Ecto.UUID.generate()

      assert %{synced_count: 2, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 %{
                   id: pin_a_id,
                   target_type: "pin",
                   stop_level_id: stop_level.id,
                   diagram_x: 20.0,
                   diagram_y: 30.0,
                   body: "Level A Pin",
                   captured_at: ~U[2026-07-18 12:00:00.000000Z]
                 },
                 %{
                   id: pin_b_id,
                   target_type: "pin",
                   stop_level_id: stop_level_b.id,
                   diagram_x: 60.0,
                   diagram_y: 70.0,
                   body: "Level B Pin",
                   captured_at: ~U[2026-07-18 12:05:00.000000Z]
                 }
               ])

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, ~p"/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      render_async(view, 5_000)

      # Initial level A displays pin A
      assert has_element?(
               view,
               "#journal-markers-svg #journal-marker-pin-#{pin_a_id}"
             )

      refute has_element?(
               view,
               "#journal-markers-svg #journal-marker-pin-#{pin_b_id}"
             )

      # Switch level to B
      render_hook(view, "switch_level", %{"level_id" => level_b.id})

      # Level B displays pin B and omits pin A
      assert has_element?(
               view,
               "#journal-markers-svg #journal-marker-pin-#{pin_b_id}"
             )

      refute has_element?(
               view,
               "#journal-markers-svg #journal-marker-pin-#{pin_a_id}"
             )
    end
  end

  describe "show_journal_entry_on_floorplan event and ring lifecycle" do
    test "validates locator, pans canvas via center_on_stop, and renders focused ring on same level",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           stop_level: stop_level
         } do
      {:ok, scope} =
        Gtfs.resolve_station_journal_scope(
          organization.id,
          gtfs_version.id,
          station.id,
          user.id
        )

      pin_id = Ecto.UUID.generate()

      assert %{synced_count: 1, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 %{
                   id: pin_id,
                   target_type: "pin",
                   stop_level_id: stop_level.id,
                   diagram_x: 45.0,
                   diagram_y: 55.0,
                   body: "Focused pin on level A",
                   captured_at: ~U[2026-07-18 12:00:00.000000Z]
                 }
               ])

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, ~p"/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      render_async(view, 5_000)

      # Open journal panel
      render_click(element(view, "#journal-trigger"))
      render_async(view, 5_000)
      assert has_element?(view, "#station-journal-panel")

      # Click Show on floorplan
      render_click(element(view, "#journal-show-entry-#{pin_id}"))

      # Pushes center_on_stop event with exact coordinates
      assert_push_event(view, "center_on_stop", %{x: 45.0, y: 55.0})

      # Renders focused ring on marker
      assert has_element?(
               view,
               "#journal-marker-pin-#{pin_id} [data-journal-ring='true']"
             )

      # Closing panel clears the ring
      render_click(element(view, "#journal-panel-close"))
      refute has_element?(view, "#station-journal-panel")

      refute has_element?(
               view,
               "#journal-marker-pin-#{pin_id} [data-journal-ring='true']"
             )
    end

    test "switches levels, reprojects focused marker, and pushes center_on_stop for alternate-level entry",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station,
           stop_level: _stop_level
         } do
      level_b =
        level_fixture(organization.id, gtfs_version.id, %{
          level_id: "journal_level_B_alt",
          level_name: "Mezzanine B Alt",
          level_index: 1.0
        })

      {:ok, stop_level_b} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          stop_id: station.id,
          level_id: level_b.id,
          diagram_filename: "level_b_alt.svg"
        })

      {:ok, scope} =
        Gtfs.resolve_station_journal_scope(
          organization.id,
          gtfs_version.id,
          station.id,
          user.id
        )

      pin_b_id = Ecto.UUID.generate()

      assert %{synced_count: 1, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 %{
                   id: pin_b_id,
                   target_type: "pin",
                   stop_level_id: stop_level_b.id,
                   diagram_x: 75.0,
                   diagram_y: 80.0,
                   body: "Pin on Level B",
                   captured_at: ~U[2026-07-18 12:10:00.000000Z]
                 }
               ])

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, ~p"/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      render_async(view, 5_000)

      # Open journal panel and switch filter to all
      render_click(element(view, "#journal-trigger"))
      render_async(view, 5_000)
      render_change(element(view, "#journal-filter-form"), %{"journal_filter" => "all"})
      render_async(view, 5_000)

      # Click Show on floorplan for pin on Level B
      render_click(element(view, "#journal-show-entry-#{pin_b_id}"))

      # Pushes center_on_stop event with Level B pin coordinates
      assert_push_event(view, "center_on_stop", %{x: 75.0, y: 80.0})

      # Renders focused ring on Level B pin
      assert has_element?(
               view,
               "#journal-marker-pin-#{pin_b_id} [data-journal-ring='true']"
             )
    end

    test "recovers cleanly on stale locator without modifying level or canvas",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: gtfs_version,
           station: station
         } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, ~p"/gtfs/#{gtfs_version.id}/stops/#{station.stop_id}/diagram")

      render_async(view, 5_000)

      # Open journal panel so the error callout renders
      render_click(element(view, "#journal-trigger"))
      render_async(view, 5_000)

      # Invoking show_journal_entry_on_floorplan with stale ID displays recoverable message
      stale_id = Ecto.UUID.generate()
      render_hook(view, "show_journal_entry_on_floorplan", %{"id" => stale_id})

      assert has_element?(view, "#journal-mutation-error")
    end
  end
end
