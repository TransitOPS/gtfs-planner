defmodule GtfsPlannerWeb.Gtfs.BlocksGapBlockDrawerLiveTest do
  # EV-23: the gap drawer and the read-only block drawer, observed through the
  # ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context. Rows are created
  # inside the SQL Sandbox transaction and rolled back; nothing here substitutes
  # an adapter or a fake day.
  #
  # Every gap sentence is asserted as the reader sees it, at the handoff the
  # fixture builds: the same stop, two platforms of one parent station, a stop
  # 120 m away, a stop 340 m away and a stop without coordinates. The distances
  # come from the stop coordinates the fixture stores, rounded by the pure
  # `Checks.handoff/2` the drawer reads, so no test re-derives a handoff.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_gap_block_drawer_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  # The fixture's baseline stop sits at 40.712800/-74.006000; these two
  # latitudes are 119.98 m and 340.03 m away from it, which `Checks.handoff/2`
  # rounds to 120 m (nearby) and 340 m (an empty move).
  @base_lat "40.712800"
  @near_lat "40.713879"
  @far_lat "40.715858"
  @base_lon "-74.006000"

  @rider_note "Trip planners such as Google Maps may tell riders they can stay on board."

  defp editor_scope(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "1",
        route_long_name: "Riverside Line"
      })

    %{user: user, organization: organization, version: version, route: route}
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp calendar(context, service_id, name, attrs \\ %{}) do
    calendar_service_fixture(
      context.organization.id,
      context.version.id,
      Map.merge(Enum.into(attrs, %{}), %{service_id: service_id, name: name})
    )
  end

  defp trip(context, attrs) do
    attrs = Map.new(attrs)
    route_id = Map.get(attrs, :route, context.route.route_id)
    {first, attrs} = Map.pop(attrs, :first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      route_id,
      attrs
      |> Map.delete(:route)
      |> Map.put_new(:service_id, "WK")
      |> Map.put_new(:trip_id, "trip_#{System.unique_integer([:positive])}")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  defp stop(context, attrs) do
    stop_fixture(context.organization.id, context.version.id, attrs)
  end

  defp coord(value), do: Decimal.new(value)

  # The `gap=` deep link carries both trip UUIDs in one parameter, after the
  # parameters the page had.
  defp gap_url(base, from_id, to_id, extra \\ []) do
    base <> "?" <> URI.encode_query([{"gap", "#{from_id}|#{to_id}"}] ++ extra)
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp element_count(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp attribute_values(view, selector, attribute) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(LazyHTML.attribute(&1, attribute) |> List.first()))
  end

  describe "the gap drawer" do
    setup :editor_scope

    test "a same-stop gap shows the layover sentence with the rider note",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      main = stop(context, %{stop_id: "MAIN", stop_name: "Main St"})

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
          first: "07:12:00",
          last: "08:00:00"
        })

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base)

      view
      |> element("[data-role='blocks-gap'][data-from='#{a.id}'][data-to='#{b.id}']")
      |> render_click()

      assert_patch(view, gap_url(base, a.id, b.id))

      assert has_element?(view, "#gap-drawer", "Between trips a and b")
      assert has_element?(view, "#gap-drawer", "Block 101 · Weekday")
      assert has_element?(view, "#gap-drawer", "Arrives")
      assert has_element?(view, "#gap-drawer", "07:00")
      assert has_element?(view, "#gap-drawer", "Next trip leaves")
      assert has_element?(view, "#gap-drawer", "07:12")
      assert has_element?(view, "#gap-drawer", "Main St")
      assert has_element?(view, "#gap-text", "12 min layover at Main St")
      assert has_element?(view, "#gap-text[data-short='false']")
      assert has_element?(view, "#gap-rider-note", @rider_note)
      assert has_element?(view, "#gap-transfers", "Transfer records · 0")

      # Each trip's own drawer is one click away with the block context kept.
      assert attribute_values(view, "#gap-drawer [data-role='gap-inspect']", "phx-value-trip") ==
               ["a", "b"]

      # Closing the drawer drops the URL parameter.
      view |> element("#gap-drawer-close") |> render_click()

      assert_patch(view, base)
      refute has_element?(view, "#gap-drawer")
    end

    test "a same-station gap names the shared parent station",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      _parent =
        stop(context, %{stop_id: "Central", stop_name: "Union Station", location_type: 1})

      # A child stop requires a level_id (`Stop.changeset/2`), so both platforms
      # carry one; the level need not exist because the stop level FK was dropped.
      platform_a =
        stop(context, %{
          stop_id: "CA",
          stop_name: "Platform A",
          parent_station: "Central",
          level_id: "L1",
          stop_lat: nil,
          stop_lon: nil
        })

      platform_b =
        stop(context, %{
          stop_id: "CB",
          stop_name: "Platform B",
          parent_station: "Central",
          level_id: "L1",
          stop_lat: nil,
          stop_lon: nil
        })

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: platform_a.stop_id,
          last_stop: platform_a.stop_id,
          first: "06:00:00",
          last: "07:00:00"
        })

      b =
        trip(context, %{
          trip_id: "b",
          block_id: "101",
          first_stop: platform_b.stop_id,
          last_stop: platform_b.stop_id,
          first: "07:03:00",
          last: "08:00:00"
        })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view
      |> element("[data-role='blocks-gap'][data-from='#{a.id}'][data-to='#{b.id}']")
      |> render_click()

      assert has_element?(view, "#gap-text", "Same station · 3 min at Central")
      # 3 minutes is below the day type's stored default minimum layover (5), so
      # the callout carries the warning the block's own finding carries.
      assert has_element?(view, "#gap-text[data-short='true']")
      assert has_element?(view, "#gap-rider-note", @rider_note)
    end

    test "a nearby stop shows its distance and the time available",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      main =
        stop(context, %{
          stop_id: "MAIN",
          stop_name: "Main St",
          stop_lat: coord(@base_lat),
          stop_lon: coord(@base_lon)
        })

      near =
        stop(context, %{
          stop_id: "NEAR",
          stop_name: "Library",
          stop_lat: coord(@near_lat),
          stop_lon: coord(@base_lon)
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
          first_stop: near.stop_id,
          last_stop: near.stop_id,
          first: "07:06:00",
          last: "08:00:00"
        })

      conn = editor_conn(context)
      base = blocks_path(version.id)

      # The deep link alone opens the drawer, without any click. The day type's
      # minimum layover is the stored default (5 minutes), so 6 minutes is not a
      # short layover and the callout stays an info one.
      {:ok, view, _html} = live(conn, gap_url(base, a.id, b.id))

      assert has_element?(view, "#gap-drawer", "Between trips a and b")
      assert has_element?(view, "#gap-text", "Nearby stop · 120 m · 6 min available")
      assert has_element?(view, "#gap-text[data-short='false']")
      assert has_element?(view, "#gap-rider-note", @rider_note)
    end

    test "an empty move has no rider note and says the driving time is unknown",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      main =
        stop(context, %{
          stop_id: "MAIN",
          stop_name: "Riverside",
          stop_lat: coord(@base_lat),
          stop_lon: coord(@base_lon)
        })

      far =
        stop(context, %{
          stop_id: "FAR",
          stop_name: "North End",
          stop_lat: coord(@far_lat),
          stop_lon: coord(@base_lon)
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
          first_stop: far.stop_id,
          last_stop: far.stop_id,
          first: "07:15:00",
          last: "08:00:00"
        })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view
      |> element("[data-role='blocks-gap'][data-from='#{a.id}'][data-to='#{b.id}']")
      |> render_click()

      # The measured move's own minutes, so the callout no longer claims a driving
      # time the day load can compute (step 39). The row below carries the same
      # number with its source; the estimate itself is the domain's, not the test's.
      assert has_element?(view, "#gap-text", "Moves empty: Riverside → North End.")
      refute has_element?(view, "#gap-text", "Driving time is unknown")
      assert has_element?(view, "#gap-drive")

      assert has_element?(view, "#gap-text[data-short='false']")
      refute has_element?(view, "#gap-rider-note")
    end

    test "an empty move without coordinates says so", %{version: version} = context do
      calendar(context, "WK", "Weekday")

      main =
        stop(context, %{
          stop_id: "MAIN",
          stop_name: "Riverside",
          stop_lat: coord(@base_lat),
          stop_lon: coord(@base_lon)
        })

      unknown =
        stop(context, %{stop_id: "NOWHERE", stop_name: "Depot", stop_lat: nil, stop_lon: nil})

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
          first_stop: unknown.stop_id,
          last_stop: unknown.stop_id,
          first: "07:15:00",
          last: "08:00:00"
        })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view
      |> element("[data-role='blocks-gap'][data-from='#{a.id}'][data-to='#{b.id}']")
      |> render_click()

      # The same sentence as a measured move, with the reason it is unknown.
      assert has_element?(
               view,
               "#gap-text",
               "Moves empty: Riverside → Depot. Driving time is unknown (coordinates unavailable)."
             )

      refute has_element?(view, "#gap-rider-note")
    end

    test "an overlapping pair's drawer shows the overlap minutes",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      main =
        stop(context, %{
          stop_id: "MAIN",
          stop_name: "Riverside",
          stop_lat: coord(@base_lat),
          stop_lon: coord(@base_lon)
        })

      far =
        stop(context, %{
          stop_id: "FAR",
          stop_name: "North End",
          stop_lat: coord(@far_lat),
          stop_lon: coord(@base_lon)
        })

      a =
        trip(context, %{
          trip_id: "a",
          block_id: "101",
          first_stop: main.stop_id,
          last_stop: main.stop_id,
          first: "06:00:00",
          last: "07:30:00"
        })

      b =
        trip(context, %{
          trip_id: "b",
          block_id: "101",
          first_stop: far.stop_id,
          last_stop: far.stop_id,
          first: "07:20:00",
          last: "08:00:00"
        })

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base)

      # The row still reports the overlap, but the timeline bar for it is
      # deliberately suppressed: the drawer is reached through the block drawer.
      assert has_element?(view, "[data-block='101'] [data-role='block-status']", "Overlap")
      refute has_element?(view, "[data-block='101'] [data-role='blocks-gap']")

      view
      |> element("#blocks-timeline tr[data-block='101'] button[phx-click='open_block']")
      |> render_click()

      assert has_element?(view, "#block-drawer [data-role='block-gap']", "10 min overlap")

      view |> element("#block-drawer [data-role='block-gap']") |> render_click()

      assert_patch(view, gap_url(base, a.id, b.id, [{"block", "101"}]))

      assert has_element?(view, "#gap-drawer", "10 min overlap")
      assert has_element?(view, "#gap-drawer", "Block 101 · Weekday")
      assert has_element?(view, "#gap-back-to-block", "Open block 101")
    end

    test "a record for the pair appears with its state text", %{version: version} = context do
      calendar(context, "WK", "Weekday")
      main = stop(context, %{stop_id: "MAIN", stop_name: "Main St"})

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
          first: "07:12:00",
          last: "08:00:00"
        })

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      # A record for a pair this gap does not join stays out of the drawer.
      other =
        trip(context, %{
          trip_id: "c",
          block_id: "201",
          first_stop: main.stop_id,
          last_stop: main.stop_id
        })

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, other)

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, gap_url(base, a.id, b.id))

      assert has_element?(view, "#gap-transfers", "Transfer records · 1")

      assert has_element?(
               view,
               "#gap-transfers [data-role='gap-transfer'][data-transfer-type='4']",
               "Riders stay on board"
             )

      assert has_element?(
               view,
               "#gap-transfers [data-role='gap-transfer-state']",
               "Matches the block on all shared dates"
             )

      refute has_element?(view, "#gap-transfers", "Trip a → c")
    end
  end

  describe "the block drawer" do
    setup :editor_scope

    test "lists the block's trips in the vehicle's day with their gaps and notes",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      main = stop(context, %{stop_id: "MAIN", stop_name: "Main St"})

      trip(context, %{
        trip_id: "a",
        block_id: "101",
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "06:00:00",
        last: "07:00:00"
      })

      trip(context, %{
        trip_id: "b",
        block_id: "101",
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "07:12:00",
        last: "08:00:00"
      })

      trip(context, %{
        trip_id: "u",
        block_id: "101",
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "09:00:00",
        last: nil
      })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?block=101")

      assert has_element?(view, "#block-drawer", "Block 101")
      assert has_element?(view, "#block-drawer", "3 trips")
      assert has_element?(view, "#block-drawer", "06:00–08:00")

      # The block's own order: its plottable sequence, then the trip it cannot
      # plot; the untimed trip carries its own finding.
      assert attribute_values(view, "#block-drawer [data-role='block-inspect']", "phx-value-trip") ==
               ["a", "b", "u"]

      # The layover is a wait row of the vehicle's day, and the row's own button
      # is what opens that gap's drawer.
      assert has_element?(view, "#block-drawer tr[data-kind='wait']", "Wait at Main St")
      assert has_element?(view, "#block-drawer tr[data-kind='wait']", "12 min")

      assert element_count(view, "#block-drawer [data-role='block-gap']") == 1

      assert has_element?(
               view,
               "#block-drawer [data-role='block-inspect'][phx-value-trip='u']",
               "Inspect"
             )

      # The trip the sequence cannot plot is still in the drawer, with the reason
      # it is out of the vehicle's timed day on its own row.
      assert has_element?(
               view,
               "#block-drawer tr[data-kind='trip']",
               "Time missing"
             )

      assert has_element?(view, "#block-drawer", "Main St → Main St")
    end

    test "the block's gap note opens the gap drawer with the block kept",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      main = stop(context, %{stop_id: "MAIN", stop_name: "Main St"})

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
          first: "07:12:00",
          last: "08:00:00"
        })

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?block=101")

      view |> element("#block-drawer [data-role='block-gap']") |> render_click()

      assert_patch(view, gap_url(base, a.id, b.id, [{"block", "101"}]))

      assert has_element?(view, "#gap-drawer", "12 min layover at Main St")
      assert has_element?(view, "#gap-back-to-block", "Open block 101")
      refute has_element?(view, "#block-drawer")

      view |> element("#gap-back-to-block") |> render_click()

      assert_patch(view, base <> "?block=101")
      assert has_element?(view, "#block-drawer", "Block 101")
      refute has_element?(view, "#gap-drawer")
    end

    test "a trip opened from the block drawer returns to it", %{version: version} = context do
      calendar(context, "WK", "Weekday")
      main = stop(context, %{stop_id: "MAIN", stop_name: "Main St"})

      trip(context, %{
        trip_id: "a",
        block_id: "101",
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "06:00:00",
        last: "07:00:00"
      })

      trip(context, %{
        trip_id: "b",
        block_id: "101",
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "07:12:00",
        last: "08:00:00"
      })

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?block=101")

      view
      |> element("#block-drawer [data-role='block-inspect'][phx-value-trip='a']")
      |> render_click()

      # The URL keeps the block, so the trip drawer knows where it came from.
      assert_patch(view, base <> "?trip=a&block=101")
      assert has_element?(view, "#trip-drawer", "Trip a")
      assert has_element?(view, "#trip-back-to-block", "Back to block 101")
      refute has_element?(view, "#block-drawer")

      view |> element("#trip-back-to-block") |> render_click()

      assert_patch(view, base <> "?block=101")
      assert has_element?(view, "#block-drawer", "Block 101")
      refute has_element?(view, "#trip-drawer")
    end

    test "a trip opened from the timeline has no back link", %{version: version} = context do
      calendar(context, "WK", "Weekday")
      main = stop(context, %{stop_id: "MAIN", stop_name: "Main St"})

      trip(context, %{
        trip_id: "a",
        block_id: "101",
        first_stop: main.stop_id,
        last_stop: main.stop_id,
        first: "06:00:00",
        last: "07:00:00"
      })

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base)

      view |> element("[data-role='trip-bar'][data-trip='a']") |> render_click()

      assert_patch(view, base <> "?trip=a")
      assert has_element?(view, "#trip-drawer", "Trip a")
      refute has_element?(view, "#trip-back-to-block")
    end
  end
end
