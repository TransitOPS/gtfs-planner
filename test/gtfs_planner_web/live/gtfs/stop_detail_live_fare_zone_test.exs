defmodule GtfsPlannerWeb.Gtfs.StopDetailLiveFareZoneTest do
  @moduledoc """
  Merge evidence (EV-25) for the read-only fare zone on stop details.

  Every case mounts the real route over the real `CatalogReadAdapter.Repo`
  adapter, so the entries, the names and the links come from
  `FareZones.zone_names/3` and the version's own `stops` rows rather than from
  the LiveView's own output. The fixture carries the shapes the acceptance
  criterion names: a boardable stop whose declared zone has a name, a boardable
  stop whose zone ID is only carried by stops and so has no record, a boardable
  stop whose stored ID holds padding, a boardable stop with no zone, a station
  whose platforms carry two zones while the station itself, its entrance and its
  boarding area carry others, a station with nothing to list, an entrance, and a
  twin version that declares the same zone ID under another name.

  Links are read as the page rendered them and compared with the path the card
  specifies, so a link cannot pass by encoding a zone ID its own way; the padded
  ID case keeps its bytes in the page text and proves the space is encoded in the
  href. `stops.zone_id` is never cast from a changeset (INV-2), so the fixture
  writes the column the way the full importer and `FareZones` do: one direct
  column write per zone. Link and heading texts are trimmed of the template's own
  indentation; the `#stop-fare-zone` value is compared byte-for-byte.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @adapter_key :gtfs_catalog_read_adapter

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
    twin = gtfs_version_fixture(organization.id)

    # The twin version declares `A` under another name, so a name the page shows
    # can only have come from the version the URL selected (CR-4, INV-1).
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {4, nil} =
      Repo.insert_all(
        FareZone,
        Enum.map(
          [
            {version.id, "A", "Central"},
            {version.id, "B", "Eastbank"},
            {version.id, " A", "Airport West"},
            {twin.id, "A", "Airport"}
          ],
          fn {gtfs_version_id, zone_id, name} ->
            %{
              id: Ecto.UUID.generate(),
              organization_id: organization.id,
              gtfs_version_id: gtfs_version_id,
              zone_id: zone_id,
              name: name,
              color: "ocean",
              inserted_at: now,
              updated_at: now
            }
          end
        )
      )

    stop = fn attrs -> stop_fixture(organization.id, version.id, attrs) end
    level = level_fixture(organization.id, version.id)

    platform_a = stop.(%{stop_id: "PLATFORM_A", stop_name: "Central Platform"})
    platform_b = stop.(%{stop_id: "PLATFORM_B", stop_name: "Eastbank Platform"})
    platform_padded = stop.(%{stop_id: "PLATFORM_PADDED", stop_name: "Airport West Platform"})
    platform_implied = stop.(%{stop_id: "PLATFORM_IMPLIED", stop_name: "Riverside Platform"})
    platform_none = stop.(%{stop_id: "PLATFORM_NONE", stop_name: "Bayline Platform"})

    station = stop.(%{stop_id: "STATION_1", stop_name: "Union Station", location_type: 1})

    station_platform_a =
      stop.(%{
        stop_id: "STATION_PLATFORM_A",
        stop_name: "Union Platform A",
        parent_station: "STATION_1",
        level_id: level.level_id
      })

    station_platform_b =
      stop.(%{
        stop_id: "STATION_PLATFORM_B",
        stop_name: "Union Platform B",
        parent_station: "STATION_1",
        level_id: level.level_id
      })

    station_platform_none =
      stop.(%{
        stop_id: "STATION_PLATFORM_NONE",
        stop_name: "Union Platform C",
        parent_station: "STATION_1",
        level_id: level.level_id
      })

    # The third platform deliberately keeps no zone, so the station's entry must
    # drop it rather than show an empty value.
    assert station_platform_none.zone_id == nil

    station_entrance =
      stop.(%{
        stop_id: "STATION_ENTRANCE",
        stop_name: "Union Entrance",
        location_type: 2,
        parent_station: "STATION_1",
        level_id: level.level_id
      })

    station_boarding =
      stop.(%{
        stop_id: "STATION_BOARDING",
        stop_name: "Union Boarding Area",
        location_type: 4,
        parent_station: "STATION_PLATFORM_A",
        level_id: level.level_id
      })

    quiet_station =
      stop.(%{stop_id: "STATION_QUIET", stop_name: "Quiet Station", location_type: 1})

    entrance = stop.(%{stop_id: "ENTRANCE_1", stop_name: "South Entrance", location_type: 2})

    set_zones(organization, version, [
      {platform_a, "A"},
      {platform_b, "B"},
      {platform_padded, " A"},
      {platform_implied, "C"},
      {station, "S"},
      {station_platform_a, "A"},
      {station_platform_b, "B"},
      {station_entrance, "E"},
      {station_boarding, "Z"},
      {quiet_station, "Q"},
      {entrance, "E"}
    ])

    twin_platform =
      stop_fixture(organization.id, twin.id, %{
        stop_id: "TWIN_PLATFORM",
        stop_name: "Twin Platform"
      })

    set_zones(organization, twin, [{twin_platform, "A"}])

    %{
      user: user,
      organization: organization,
      version: version,
      twin: twin,
      station: station,
      platform_none: platform_none
    }
  end

  describe "a boardable stop's own fare zone" do
    test "shows the version's name for its zone with a link to that zone's filter", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_stop(conn, user, organization, version, "PLATFORM_A")

      assert stop_fare_zone(view) == "Central · A"

      assert has_element?(view, "a#stop-fare-zone-link", "View in Fares")

      assert href(view, "#stop-fare-zone-link") ==
               "/gtfs/#{version.id}/settings/fares?zone=A"

      # The entry sits in the Overview list, directly after Platform Code.
      labels = dt_labels(view)
      assert Enum.at(labels, Enum.find_index(labels, &(&1 == "Platform Code")) + 1) == "Fare zone"
    end

    test "shows None with the unassigned filter for a boardable stop with no zone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_stop(conn, user, organization, version, "PLATFORM_NONE")

      assert stop_fare_zone(view) == "None"
      assert has_element?(view, "a#stop-fare-zone-link", "View in Fares")

      # `filter` is its own query key: the unassigned link never sets `zone`.
      assert href(view, "#stop-fare-zone-link") ==
               "/gtfs/#{version.id}/settings/fares?filter=unassigned"
    end

    test "names a zone no record declares by its own ID", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_stop(conn, user, organization, version, "PLATFORM_IMPLIED")

      assert stop_fare_zone(view) == "C · C"
      assert href(view, "#stop-fare-zone-link") == "/gtfs/#{version.id}/settings/fares?zone=C"
    end

    test "keeps a padded stored zone ID byte-for-byte and encodes its space in the link", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_stop(conn, user, organization, version, "PLATFORM_PADDED")

      # `has_element?/3` collapses whitespace, so the padded value is read from
      # the element's own text instead.
      assert stop_fare_zone(view) == "Airport West ·  A"

      href = href(view, "#stop-fare-zone-link")
      assert href == "/gtfs/#{version.id}/settings/fares?" <> URI.encode_query(%{"zone" => " A"})
      refute href =~ " "
    end

    test "shows the value as read-only text with a link, not a control", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_stop(conn, user, organization, version, "PLATFORM_A")

      assert has_element?(view, "span#stop-fare-zone")
      refute has_element?(view, "#stop-fare-zone input")
      refute has_element?(view, "#stop-fare-zone select")
      refute has_element?(view, "#stop-fare-zone form")
      refute has_element?(view, "#stop-fare-zone textarea")
      refute has_element?(view, "#stop-fare-zone-link[phx-click]")
    end

    test "reads the zone through the version the URL selected", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      twin: twin
    } do
      {:ok, view, _html} = open_stop(conn, user, organization, version, "PLATFORM_A")
      assert stop_fare_zone(view) == "Central · A"

      {:ok, twin_view, _html} = open_stop(conn, user, organization, twin, "TWIN_PLATFORM")
      assert stop_fare_zone(twin_view) == "Airport · A"

      assert href(twin_view, "#stop-fare-zone-link") ==
               "/gtfs/#{twin.id}/settings/fares?zone=A"
    end
  end

  describe "a station's platform fare zones" do
    test "lists the distinct zones of its boardable children and nothing else", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_stop(conn, user, organization, version, "STATION_1")

      # A station shows the child platform zones instead of a zone of its own.
      refute has_element?(view, "#stop-fare-zone")
      assert "Platform fare zones" in dt_labels(view)

      assert has_element?(view, "#platform-fare-zone-0", "Central · A")
      assert has_element?(view, "#platform-fare-zone-1", "Eastbank · B")
      assert link_texts(view, "#station-platform-fare-zones a") == ["Central · A", "Eastbank · B"]

      # The station's own zone `S`, its entrance's `E` and its boarding area's
      # `Z` are not platform fare zones, and the unzoned platform adds nothing.
      refute has_element?(view, "#platform-fare-zone-2")
      refute has_element?(view, "#station-platform-fare-zones a", "S · S")
      refute has_element?(view, "#station-platform-fare-zones a", "E · E")
      refute has_element?(view, "#station-platform-fare-zones a", "Z · Z")

      assert href(view, "#platform-fare-zone-0") == "/gtfs/#{version.id}/settings/fares?zone=A"
      assert href(view, "#platform-fare-zone-1") == "/gtfs/#{version.id}/settings/fares?zone=B"
    end

    test "shows None for a station with no zoned platform", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_stop(conn, user, organization, version, "STATION_QUIET")

      assert has_element?(view, "#station-platform-fare-zones", "None")
      assert link_texts(view, "#station-platform-fare-zones a") == []
      assert "Platform fare zones" in dt_labels(view)
    end

    test "shows the fallback, not None, while the child stops cannot be read", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      station: station
    } do
      stub_unavailable_child_stops(station)

      {:ok, view, _html} = open_stop(conn, user, organization, version, "STATION_1")

      assert has_element?(view, "#station-platform-fare-zones", "—")
      assert link_texts(view, "#station-platform-fare-zones a") == []
    end
  end

  describe "location types without a fare zone" do
    test "shows no entry at all for an entrance", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_stop(conn, user, organization, version, "ENTRANCE_1")

      refute has_element?(view, "#stop-fare-zone")
      refute has_element?(view, "#station-platform-fare-zones")
      refute "Fare zone" in dt_labels(view)
      refute "Platform fare zones" in dt_labels(view)

      # The page still offers no way to edit a fare zone.
      refute has_element?(view, "input[name*='zone']")
      refute has_element?(view, "select[name*='zone']")
      refute has_element?(view, "[phx-submit*='zone']")
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp open_stop(conn, user, organization, version, stop_id) do
    conn = log_in_user(conn, user, organization: organization)
    live(conn, "/gtfs/#{version.id}/stops/#{stop_id}", on_error: :warn)
  end

  # `stops.zone_id` is not cast by any changeset (INV-2), so each zone is written
  # straight to the column, one statement per distinct ID.
  defp set_zones(organization, version, assignments) do
    assignments
    |> Enum.group_by(fn {_stop, zone_id} -> zone_id end, fn {stop, _zone_id} -> stop.stop_id end)
    |> Enum.each(fn {zone_id, stop_ids} ->
      {count, nil} =
        Repo.update_all(
          from(s in Stop,
            where:
              s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id and
                s.stop_id in ^stop_ids
          ),
          set: [zone_id: zone_id]
        )

      assert count == length(stop_ids)
    end)
  end

  defp stub_unavailable_child_stops(station) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)

    Mox.stub(CatalogReadAdapterMock, :fetch_stop, fn _organization_id,
                                                     _gtfs_version_id,
                                                     stop_id ->
      if stop_id == station.stop_id, do: {:ok, station}, else: {:error, :not_found}
    end)

    Mox.stub(CatalogReadAdapterMock, :load_stop_regions, fn _organization_id,
                                                            _gtfs_version_id,
                                                            _stop ->
      %{
        child_stops: {:error, :unavailable},
        levels: {:ok, []},
        pathways: {:ok, []},
        editing_status: {:ok, nil}
      }
    end)
  end

  # The rendered value of `#stop-fare-zone`, byte-for-byte: `LazyHTML.text/1`
  # keeps the padding a stored zone ID may carry.
  defp stop_fare_zone(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#stop-fare-zone")
    |> LazyHTML.text()
  end

  defp href(view, selector) do
    [href] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("href")

    href
  end

  defp dt_labels(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("dt")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp link_texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
