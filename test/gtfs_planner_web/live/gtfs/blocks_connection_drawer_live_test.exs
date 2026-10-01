defmodule GtfsPlannerWeb.Gtfs.BlocksConnectionDrawerLiveTest do
  # The gap drawer as the connection drawer: its title and subtitle, its times and
  # handoff, the hints `RiderOutcomes` orders for it, the note a saved record earns,
  # and the table of what each trip planner will tell a rider — observed through
  # the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context. Rows are created
  # inside the SQL Sandbox transaction and rolled back; nothing here substitutes an
  # adapter, a context or a hand-built connection.
  #
  # The two routes are 12 and 24 by short name, because the title reads the day's
  # route map the way the timeline's own badges do. The stop pair is one stop for
  # the route change, two stops of one station for the turnback, and the record
  # cases reuse the same day shape `InSeatTransfers.SetConnectionTest` builds, so
  # the not-next note names the trip the shared rule names.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Blocking.DayTypes

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    twelve =
      route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    twenty_four =
      route_fixture(organization.id, version.id, %{route_id: "R24", route_short_name: "24"})

    %{
      organization: organization,
      user: user,
      version: version,
      twelve: twelve,
      twenty_four: twenty_four
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp service(context, service_id, name, dates) do
    calendar_service_fixture(context.organization.id, context.version.id, %{
      service_id: service_id,
      name: name,
      dates: dates
    })
  end

  defp stop(context, attrs) do
    organization_id = context.organization.id

    if Map.has_key?(attrs, :stop_lat) do
      stop_with_coordinates_fixture(organization_id, context.version.id, attrs)
    else
      GtfsPlanner.GtfsFixtures.stop_fixture(organization_id, context.version.id, attrs)
    end
  end

  # A stop ID for a test's own purposes, unique across the file's cases.
  defp plain_stop_id(tag), do: "CONN_PLAIN_#{tag}_#{System.unique_integer([:positive])}"

  defp coord(value), do: Decimal.new(value)

  defp trip(context, attrs) do
    attrs = Map.new(attrs)
    route_id = Map.get(attrs, :route, context.twelve.route_id)
    {first, attrs} = Map.pop(attrs, :first, "06:00:00")
    {last, attrs} = Map.pop(attrs, :last, "07:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      route_id,
      attrs
      |> Map.delete(:route)
      |> Map.put_new(:service_id, "W")
      |> Map.put_new(:trip_id, "trip_#{System.unique_integer([:positive])}")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  # The `gap=` deep link carries both trip UUIDs in one parameter.
  defp gap_url(base, from_trip, to_trip, extra \\ []) do
    base <> "?" <> URI.encode_query([{"gap", "#{from_trip.id}|#{to_trip.id}"}] ++ extra)
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp texts(view, selector) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp attribute_values(view, selector, attribute) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(LazyHTML.attribute(&1, attribute) |> List.first()))
  end

  # One stop both routes meet at, on one meridian.
  defp main_stop(context) do
    stop(context, %{
      stop_id: "CONN_MAIN_#{System.unique_integer([:positive])}",
      stop_name: "Main St",
      stop_lat: coord("40.0200"),
      stop_lon: coord("-74.0000")
    })
  end

  describe "the connection drawer's title and subtitle" do
    test "a route change names both routes, the block, the pair and the place", context do
      service(context, "W", "Weekday", @weekday_dates)

      main = main_stop(context)

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          route: context.twenty_four.route_id,
          trip_id: "b",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:10:00",
          last: "08:10:00"
        })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert has_element?(view, "#gap-drawer-title", "Route 12 continues as Route 24")

      assert has_element?(
               view,
               "#gap-drawer",
               "Block 101 · trip a → b · Main St"
             )
    end

    test "one route's two directions meeting at a stop read as a turnback", context do
      service(context, "W", "Weekday", @weekday_dates)

      north = main_stop(context)

      south = main_stop(context)

      a =
        trip(context, %{
          trip_id: "out",
          block_id: "101",
          direction_id: 0,
          trip_headsign: "North End",
          first_stop: north.stop_id,
          last_stop: south.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          trip_id: "back",
          block_id: "101",
          direction_id: 1,
          trip_headsign: "Riverside",
          first_stop: south.stop_id,
          last_stop: north.stop_id,
          first: "07:20:00",
          last: "08:20:00"
        })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert has_element?(view, "#gap-drawer-title", "Route 12 turns back")
    end
  end

  describe "the connection drawer's facts" do
    test "the two arrivals and the time on board with the handoff the pair has", context do
      service(context, "W", "Weekday", @weekday_dates)

      main = main_stop(context)

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          route: context.twenty_four.route_id,
          trip_id: "b",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:12:00",
          last: "08:12:00"
        })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert texts(view, "#gap-drawer dt") |> Enum.take(3) == ["Arrives", "Departs", "On board"]
      assert has_element?(view, "#gap-drawer", "07:00 · Main St")
      assert has_element?(view, "#gap-drawer", "07:12 · Main St")
      assert has_element?(view, "#gap-available", "12 min · Same stop")
    end

    test "an empty move with no coordinates says the driving time is unknown", context do
      service(context, "W", "Weekday", @weekday_dates)

      # Two stops this version cannot place: the move is real, its distance and
      # its driving time are not.
      # `stop_fixture` fills in the fixture's default coordinates, so the stops
      # this case needs are built with their coordinates explicitly absent.
      here =
        stop(context, %{
          stop_id: plain_stop_id("A"),
          stop_name: "Here",
          stop_lat: nil,
          stop_lon: nil
        })

      there =
        stop(context, %{
          stop_id: plain_stop_id("B"),
          stop_name: "There",
          stop_lat: nil,
          stop_lon: nil
        })

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: here.stop_id,
          last_stop: here.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          trip_id: "b",
          block_id: "101",
          first_stop: there.stop_id,
          last_stop: there.stop_id,
          first: "07:30:00",
          last: "08:30:00"
        })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert has_element?(view, "#gap-available", "Vehicle moves empty, distance unknown")
      assert has_element?(view, "#gap-available", "Driving time is unknown.")
    end
  end

  describe "the connection drawer's hints" do
    test "a route change and an empty move render in RiderOutcomes' order", context do
      service(context, "W", "Weekday", @weekday_dates)

      here =
        stop(context, %{
          stop_id: "CONN_HERE_#{System.unique_integer([:positive])}",
          stop_name: "Here",
          stop_lat: coord("40.0200"),
          stop_lon: coord("-74.0000")
        })

      there =
        stop(context, %{
          stop_id: "CONN_THERE_#{System.unique_integer([:positive])}",
          stop_name: "There",
          stop_lat: coord("40.0400"),
          stop_lon: coord("-74.0000")
        })

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          trip_headsign: "North End",
          first_stop: here.stop_id,
          last_stop: here.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          route: context.twenty_four.route_id,
          trip_id: "b",
          block_id: "101",
          trip_headsign: "South End",
          first_stop: there.stop_id,
          last_stop: there.stop_id,
          first: "07:30:00",
          last: "08:30:00"
        })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      # The route change, then the 30-minute wait, then the empty move: the order
      # `RiderOutcomes.hints/1` returns them in.
      assert attribute_values(view, "#gap-hints [data-role='gap-hint']", "data-hint") == [
               "route_change",
               "wait",
               "distance"
             ]

      assert has_element?(
               view,
               "#gap-hints",
               "Continues as Route R24 to South End from another stop"
             )

      assert has_element?(view, "#gap-hints", "the vehicle moves empty between them")
    end
  end

  describe "the connection drawer's record note" do
    setup %{organization: organization, version: version} do
      service_id = "W"

      calendar_service_fixture(organization.id, version.id, %{
        service_id: service_id,
        name: "Weekday",
        dates: @weekday_dates
      })

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "NS",
        name: "No school",
        dates: Enum.take(@weekday_dates, 1)
      })

      :ok
    end

    test "a not-next record names the trip that runs between the pair", context do
      main = main_stop(context)

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      _between =
        trip(context, %{
          trip_id: "X",
          service_id: "NS",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:05:00",
          last: "08:05:00"
        })

      b =
        trip(context, %{
          trip_id: "b",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "08:10:00",
          last: "09:10:00"
        })

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      # The drawer draws the day the URL names, and the pair is consecutive only
      # on the weekday-only day type; the shared rule still reads both.
      url = gap_url(blocks_path(context.version.id), a, b, day: DayTypes.key(["W"]))

      {:ok, view, _html} = live(editor_conn(context), url)

      assert has_element?(view, "#gap-record-note", "Saved record needs review")

      assert has_element?(
               view,
               "#gap-record-note",
               "trip X runs next on this vehicle"
             )
    end

    test "a stops-changed record names the stored stop and the stop the trip now starts at",
         context do
      main = main_stop(context)

      moved =
        stop(context, %{
          stop_id: "CONN_OLD_#{System.unique_integer([:positive])}",
          stop_name: "Old Depot",
          stop_lat: coord("40.0200"),
          stop_lon: coord("-74.0000")
        })

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          trip_id: "b",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:10:00",
          last: "08:10:00"
        })

      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 4,
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: main.stop_id,
        to_stop_id: moved.stop_id
      })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert has_element?(view, "#gap-record-note", "Saved record has old stops")
      assert has_element?(view, "#gap-record-note", "It names #{moved.stop_id}")
      assert has_element?(view, "#gap-record-note", "trip b now starts at Main St")
      assert has_element?(view, "#gap-record-note", "OpenTripPlanner drops the record")
    end

    test "two records for one pair read as a conflict", context do
      main = main_stop(context)

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          trip_id: "b",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:10:00",
          last: "08:10:00"
        })

      # One decided pair and one stopless row, which is the shape an import
      # leaves behind: the GTFS key keeps them apart because only one carries
      # stops.
      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 4,
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: main.stop_id,
        to_stop_id: main.stop_id
      })

      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 5,
        from_trip_id: a.trip_id,
        to_trip_id: b.trip_id,
        from_stop_id: nil,
        to_stop_id: nil
      })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert has_element?(view, "#gap-record-note", "Two imported records disagree")
      assert has_element?(view, "#gap-record-note", "apps pick one arbitrarily")
    end
  end

  describe "the connection drawer's rider table" do
    test "a saved type 4 record shows the stay-on link and the footnote", context do
      service(context, "W", "Weekday", @weekday_dates)

      main = main_stop(context)

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          trip_id: "b",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:10:00",
          last: "08:10:00"
        })

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert has_element?(view, "#gap-riders", "What trip planners show riders")

      assert attribute_values(view, "#gap-riders [data-role='gap-rider-row']", "data-app") == [
               "Google Maps",
               "OpenTripPlanner",
               "Transit app"
             ]

      assert has_element?(
               view,
               "#gap-riders [data-app='OpenTripPlanner']",
               "Stay on board"
             )

      assert has_element?(view, "#gap-rider-footnote", "OneBusAway shows")
    end

    test "a pair with no record keeps the block-derived outcome", context do
      service(context, "W", "Weekday", @weekday_dates)

      main = main_stop(context)

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          trip_id: "b",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:10:00",
          last: "08:10:00"
        })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert has_element?(
               view,
               "#gap-riders [data-app='Transit app']",
               "Decides from the block"
             )
    end
  end

  describe "the drawer as a panel" do
    test "it opens beside the page and keeps its own id", context do
      service(context, "W", "Weekday", @weekday_dates)

      main = main_stop(context)

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          trip_id: "b",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "07:10:00",
          last: "08:10:00"
        })

      {:ok, view, _html} =
        live(editor_conn(context), gap_url(blocks_path(context.version.id), a, b))

      assert has_element?(view, "#gap-drawer")
      assert has_element?(view, "#gap-drawer-overlay[data-modal='false']")
      assert has_element?(view, "#gap-drawer-close")
    end
  end
end
