defmodule GtfsPlannerWeb.Gtfs.FaresLiveInventoryTest do
  @moduledoc """
  Merge evidence (EV-14) for the Zones tab's inventory panel and its URL filters.

  Every case mounts the real route and reads the version's real data through the
  default `CatalogReadAdapter.Repo` adapter, so the rows, counts and colors come
  from `FareZones.inventory/2` and not from the component's own output. The
  fixture carries the shapes the criteria name: declared zones with and without
  stops, an imported ID holding a space and an ampersand, a zone carried only by
  a station, a zone a fare rule references with no stops at all, and a zone
  literally named `unassigned`.

  The panel is the page's navigation, so each filter case reads the href the
  panel rendered and patches through that exact href: the test cannot pass by
  rebuilding a URL the panel never produced. That is also where the encoding rule
  lives - `URI.encode_query/1` output, `filter` kept a separate key from `zone`,
  and no DOM ID derived from a zone ID. One case pins the unknown-zone fallback's
  second workspace read, which is what keeps the stop list below the header
  describing the same filter the header names.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @adapter_key :gtfs_catalog_read_adapter

  # The version's eight zones in the byte-for-byte ID order the inventory sorts
  # them into, and the row DOM ID each one renders as. The row index - never the
  # zone ID - is what identifies a row's elements.
  @rows [
    {"fare-zone-row-1", " A"},
    {"fare-zone-row-2", "A"},
    {"fare-zone-row-3", "A&B 1"},
    {"fare-zone-row-4", "D"},
    {"fare-zone-row-5", "R"},
    {"fare-zone-row-6", "S"},
    {"fare-zone-row-7", "T"},
    {"fare-zone-row-8", "unassigned"}
  ]

  setup :verify_on_exit!

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    # Zone metadata is inserted directly, standing in for an imported feed: a
    # stored ID is byte-exact and never revalidated, so the imported "A&B 1"
    # that the encoding case needs could not come through `create_zone/3`.
    insert_zone(organization, version, "A", "Central", "ocean")
    insert_zone(organization, version, "A&B 1", "Bayside & Central", "teal")
    insert_zone(organization, version, "D", "Airport", "ochre")
    insert_zone(organization, version, "unassigned", "Unassigned Park", "plum")

    # Eight boardable stops: A has two, " A" one, "A&B 1" one, the zone named
    # "unassigned" one, T one platform, and two have no zone. S and T each also
    # carry a station, which no count may include.
    insert_stops(organization, version, [
      {"STOP_A_1", 0, "A"},
      {"STOP_A_2", 0, "A"},
      {"STOP_SPACE_A", 0, " A"},
      {"STOP_AMP", 0, "A&B 1"},
      {"STOP_ZONE_UNA", 0, "unassigned"},
      {"STOP_T_PLATFORM", 0, "T"},
      {"STOP_T_STATION", 1, "T"},
      {"STOP_S_STATION", 1, "S"},
      {"STOP_NO_ZONE_1", 0, nil},
      {"STOP_NO_ZONE_2", 0, nil}
    ])

    # R is referenced by a fare rule and has neither stops nor a record, so the
    # inventory carries it as an empty zone.
    insert_rule(organization, version, "CITY", "R", "A")

    %{user: user, organization: organization, version: version}
  end

  describe "inventory panel" do
    test "lists every zone with its exact ID, name, color and boardable count", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")
      html = render(view)

      assert has_element?(view, "#fare-zone-inventory-count", "8")

      assert has_element?(view, "#fare-zone-row-all", "All stops")
      assert has_element?(view, "#fare-zone-row-all", "Every zone")
      assert has_element?(view, "#fare-zone-row-all-count", "8")

      # A declared zone: its name, its ID and its boardable membership.
      assert has_element?(view, "#fare-zone-row-2 strong", "Central")
      assert has_element?(view, "#fare-zone-row-2 small", "ID A")
      assert has_element?(view, "#fare-zone-row-2-count", "2")

      # " A" and "A" are two zones with two rows: no path trims an existing ID.
      assert has_element?(view, "#fare-zone-row-1 strong", " A")
      assert has_element?(view, "#fare-zone-row-1 small", "ID  A")
      assert has_element?(view, "#fare-zone-row-1-count", "1")

      # A declared zone with no stops, and a rule-referenced zone with none.
      assert has_element?(view, "#fare-zone-row-4 small", "ID D · Empty zone")
      assert has_element?(view, "#fare-zone-row-5 small", "ID R · Empty zone")
      assert has_element?(view, "#fare-zone-row-5-count", "0")

      # Counts are boardable stops only: a zone carried by a station alone reads
      # 0 and keeps its row, and a zone with one platform counts the platform.
      assert has_element?(view, "#fare-zone-row-6 small", "ID S · Empty zone")
      assert has_element?(view, "#fare-zone-row-6-count", "0")
      assert has_element?(view, "#fare-zone-row-7-count", "1")

      assert has_element?(view, "#fare-zone-row-unassigned", "Unassigned")
      assert has_element?(view, "#fare-zone-row-unassigned", "Needs assignment")
      assert has_element?(view, "#fare-zone-row-unassigned-count", "2")

      assert html =~ "Each stop belongs to one zone."
      assert html =~ "Zone names help your team. Zone IDs travel with your GTFS feed."

      # The chip is drawn in the zone's own palette color, on a tinted square.
      assert html =~ "color: #1f5fbf"
      assert html =~ "background-color: #1f5fbf1a"
      assert html =~ "color: #0d737d"

      # No DOM ID derives from a zone ID, so an ID with spaces, "&" or a name
      # that collides with the fixed rows cannot break a selector.
      doc = LazyHTML.from_fragment(html)

      for {selector, _zone_id} <- @rows do
        assert Enum.count(LazyHTML.query(doc, "##{selector}")) == 1
      end

      for {_selector, zone_id} <- @rows, zone_id not in ["A", "unassigned"] do
        refute html =~ ~s(id="fare-zone-row-#{zone_id}")
      end
    end

    test "a zone row patches ?zone=, marks itself current and renames the stage", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      assert has_element?(view, "#fare-zone-row-all[aria-current='page']")
      assert has_element?(view, "#fare-zone-stage-title", "All stops")
      assert has_element?(view, "#fare-zone-stage-subtitle", "8 stops in this version")

      assert row_href(view, "#fare-zone-row-2") == "/gtfs/#{version.id}/settings/fares?zone=A"

      render_patch(view, row_href(view, "#fare-zone-row-2"))

      assert has_element?(view, "#fare-zone-row-2[aria-current='page']")
      refute has_element?(view, "#fare-zone-row-all[aria-current='page']")
      assert has_element?(view, "#fare-zone-stage-title", "Central")
      assert has_element?(view, "#fare-zone-stage-subtitle", "2 stops · Zone ID A")
    end

    test "a zone ID holding a space and an ampersand round-trips through its link", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      href = row_href(view, "#fare-zone-row-3")
      assert href == "/gtfs/#{version.id}/settings/fares?zone=A%26B+1"

      render_patch(view, href)

      assert has_element?(view, "#fare-zone-row-3[aria-current='page']")
      assert has_element?(view, "#fare-zone-stage-title", "Bayside & Central")
      assert has_element?(view, "#fare-zone-stage-subtitle", "1 stop · Zone ID A&B 1")

      assert row_href(view, "#fare-zone-row-unassigned") ==
               "/gtfs/#{version.id}/settings/fares?filter=unassigned"

      refute render(view) =~ ~s(id="fare-zone-row-A&B 1")
    end

    test "?zone=unassigned and ?filter=unassigned are different filters", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      zone_href = row_href(view, "#fare-zone-row-8")
      filter_href = row_href(view, "#fare-zone-row-unassigned")

      assert zone_href == "/gtfs/#{version.id}/settings/fares?zone=unassigned"
      assert filter_href == "/gtfs/#{version.id}/settings/fares?filter=unassigned"

      render_patch(view, zone_href)

      assert has_element?(view, "#fare-zone-row-8[aria-current='page']")
      refute has_element?(view, "#fare-zone-row-unassigned[aria-current='page']")
      assert has_element?(view, "#fare-zone-stage-title", "Unassigned Park")
      assert has_element?(view, "#fare-zone-stage-subtitle", "1 stop · Zone ID unassigned")

      render_patch(view, filter_href)

      assert has_element?(view, "#fare-zone-row-unassigned[aria-current='page']")
      refute has_element?(view, "#fare-zone-row-8[aria-current='page']")
      assert has_element?(view, "#fare-zone-stage-title", "Unassigned stops")
      assert has_element?(view, "#fare-zone-stage-subtitle", "2 stops")
    end

    test "a zone value the inventory does not carry shows All stops", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      render_patch(view, "/gtfs/#{version.id}/settings/fares?zone=A")
      assert has_element?(view, "#fare-zone-row-2[aria-current='page']")

      # Byte-exact: " A" is its own zone, so the space the link encoded selects
      # it instead of "A".
      render_patch(view, row_href(view, "#fare-zone-row-1"))
      assert has_element?(view, "#fare-zone-row-1[aria-current='page']")
      refute has_element?(view, "#fare-zone-row-2[aria-current='page']")

      render_patch(view, "/gtfs/#{version.id}/settings/fares?zone=GONE")

      assert has_element?(view, "#fare-zone-row-all[aria-current='page']")
      assert has_element?(view, "#fare-zone-stage-title", "All stops")
      assert has_element?(view, "#fare-zone-stage-subtitle", "8 stops in this version")
      refute has_element?(view, "#fare-zone-row-1[aria-current='page']")
    end

    test "an unknown zone filter reads the stop page again for All stops", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      previous = Application.fetch_env(:gtfs_planner, @adapter_key)
      Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
          :error -> Application.delete_env(:gtfs_planner, @adapter_key)
        end
      end)

      test_pid = self()

      expect(CatalogReadAdapterMock, :load_fare_workspace, 2, fn _organization_id,
                                                                 _version_id,
                                                                 opts ->
        send(test_pid, {:stop_filter, opts[:filter]})

        {:ok,
         %{
           inventory: %{
             zones: [
               %{
                 zone_id: "A",
                 name: "Central",
                 color: "ocean",
                 declared?: true,
                 stop_count: 1,
                 other_stop_count: 0,
                 rule_count: 0
               }
             ],
             unassigned_count: 0,
             boardable_count: 1
           },
           checks: %{
             stopless_referenced: [],
             unassigned_count: 0,
             empty_declared: [],
             rules_reference_zones?: false
           },
           stops: %{
             entries: [],
             total_count: 1,
             page: 1,
             per_page: 100,
             without_location_count: 0
           }
         }}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=GONE")

      # The first read serves the filter the URL asked for; the second one serves
      # All stops, so the stop list below the header cannot render the rows of a
      # filter that is no longer selected.
      assert_receive {:stop_filter, {:zone, "GONE"}}, 1_000
      assert_receive {:stop_filter, :all}, 1_000

      assert has_element?(view, "#fare-zone-row-all[aria-current='page']")
      assert has_element?(view, "#fare-zone-stage-title", "All stops")
      refute has_element?(view, "#fare-zone-row-1[aria-current='page']")
    end
  end

  # The rendered href of one row. The panel owns the encoding, so the tests read
  # the link it produced rather than reconstructing it.
  defp row_href(view, selector) do
    [href] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("href")

    href
  end

  defp insert_stops(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn {stop_id, location_type, zone_id} ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop_id,
          stop_name: "Stop #{stop_id}",
          location_type: location_type,
          zone_id: zone_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Stop, rows)
    assert count == length(rows)
  end

  defp insert_zone(organization, version, zone_id, name, color) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareZone, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          zone_id: zone_id,
          name: name,
          color: color,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp insert_rule(organization, version, fare_id, origin_id, destination_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareRule, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: fare_id,
          origin_id: origin_id,
          destination_id: destination_id,
          inserted_at: now,
          updated_at: now
        }
      ])
  end
end
