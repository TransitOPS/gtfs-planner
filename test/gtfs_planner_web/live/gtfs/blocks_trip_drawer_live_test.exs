defmodule GtfsPlannerWeb.Gtfs.BlocksTripDrawerLiveTest do
  # EV-22: the read-only trip drawer and the `trip=` deep links, observed through
  # the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context. Rows are created
  # inside the SQL Sandbox transaction and rolled back; nothing here substitutes
  # an adapter or a fake day.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_trip_drawer_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  @weekend %{
    monday: 0,
    tuesday: 0,
    wednesday: 0,
    thursday: 0,
    friday: 0,
    saturday: 1,
    sunday: 0
  }

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

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp element_count(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp hrefs(view, selector),
    do: view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute("href")

  defp day_options(view) do
    view
    |> doc()
    |> LazyHTML.query("#blocks-day option")
    |> Enum.map(fn option ->
      {LazyHTML.attribute(option, "value") |> List.first(),
       LazyHTML.text(option) |> String.trim()}
    end)
  end

  defp day_key(view, label) do
    {key, _text} =
      Enum.find(day_options(view), fn {_key, text} -> String.starts_with?(text, label) end)

    key
  end

  defp dates_matching(fun) do
    ~D[2026-01-01] |> Date.range(~D[2026-12-31]) |> Enum.count(fun)
  end

  defp weekday_dates, do: dates_matching(&(Date.day_of_week(&1) in 1..5))
  defp saturday_dates, do: dates_matching(&(Date.day_of_week(&1) == 6))

  defp clock(secs),
    do: "#{pad(div(secs, 3_600))}:#{pad(div(rem(secs, 3_600), 60))}:00"

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  describe "the trip drawer opened from the page" do
    setup :editor_scope

    test "open_trip patches trip= and the drawer shows identity, times and GTFS times",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      first_stop =
        stop_fixture(context.organization.id, context.version.id, %{stop_name: "Central"})

      last_stop =
        stop_fixture(context.organization.id, context.version.id, %{stop_name: "Riverside Term"})

      trip(context, %{
        trip_id: "6101",
        block_id: "101",
        trip_headsign: "Downtown",
        route_pattern_id: "pattern-1",
        first_stop: first_stop.stop_id,
        last_stop: last_stop.stop_id,
        first: "06:00:00",
        last: "06:45:00"
      })

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base)

      view |> element("[data-role='trip-bar'][data-trip='6101']") |> render_click()

      assert_patch(view, base <> "?trip=6101")

      # Identity: the route badge with its long name, and the trip's own fields.
      assert has_element?(view, "#trip-drawer", "Trip 6101")
      assert has_element?(view, "#trip-drawer", "Riverside Line")

      # The detail list: headsign, pattern, calendar, endpoints and GTFS times.
      assert has_element?(view, "#trip-drawer", "Downtown")
      assert has_element?(view, "#trip-drawer", "pattern-1")
      assert has_element?(view, "#trip-drawer", "Weekday")
      assert has_element?(view, "#trip-drawer", "06:00")
      assert has_element?(view, "#trip-drawer", "Central")
      assert has_element?(view, "#trip-drawer", "06:45")
      assert has_element?(view, "#trip-drawer", "Riverside Term")
      assert has_element?(view, "#trip-drawer", "06:00:00")
      assert has_element?(view, "#trip-drawer", "06:45:00")
      assert has_element?(view, "#trip-drawer", "101")

      # Closing the drawer drops the URL parameter as well as the panel.
      view |> element("#trip-drawer-close") |> render_click()

      assert_patch(view, base)
      refute has_element?(view, "#trip-drawer")
    end

    test "the day types list every date the trip runs, not only the viewed day type",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      calendar(context, "TURKEY", "Thanksgiving", %{dates: [~D[2026-11-26]]})

      trip(context, %{trip_id: "wk_1", block_id: "101"})

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?trip=wk_1")

      # The loaded day type is the Weekday one (260 dates); the trip's own scope
      # also holds the shared Thanksgiving date, so its sentence sums to 261.
      weekdays = weekday_dates()

      assert has_element?(view, "#trip-day-types", "Runs on #{weekdays} dates in:")
      assert element_count(view, "#trip-day-types a[data-role='trip-day-type']") == 2

      texts =
        view
        |> doc()
        |> LazyHTML.query("#trip-day-types a[data-role='trip-day-type']")
        |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))

      assert hd(texts) == "Weekday · #{weekdays - 1} dates"
      assert List.last(texts) == "Thanksgiving + Weekday · 1 date"

      assert has_element?(
               view,
               "#trip-day-types",
               "Changes apply to all #{weekdays} dates this trip runs."
             )

      # Each link carries the day key and the trip, so following it changes the
      # day type and opens the same drawer there (AC-29).
      weekday_key = day_key(view, "Weekday")
      thanksgiving_key = day_key(view, "Thanksgiving")

      assert hrefs(view, "#trip-day-types a[data-role='trip-day-type']") == [
               base <> "?day=#{weekday_key}&trip=wk_1",
               base <> "?day=#{thanksgiving_key}&trip=wk_1"
             ]

      {:ok, followed, _html} =
        live(conn, base <> "?day=#{thanksgiving_key}&trip=wk_1")

      assert has_element?(followed, "#trip-drawer", "Trip wk_1")
      assert has_element?(followed, "#trip-day-types", "Runs on #{weekdays} dates in:")
      refute has_element?(followed, "#blocks-trip-elsewhere")
    end

    test "the transfer records list every record naming the trip, with its state text",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      a = trip(context, %{trip_id: "a", block_id: "101", first: "06:00:00", last: "07:00:00"})
      b = trip(context, %{trip_id: "b", block_id: "101", first: "07:10:00", last: "08:00:00"})
      x = trip(context, %{trip_id: "x", block_id: "201", first: "09:00:00", last: "10:00:00"})
      y = trip(context, %{trip_id: "y", block_id: "202", first: "11:00:00", last: "12:00:00"})

      in_seat_transfer_fixture(context.organization.id, context.version.id, a, b)

      # x and y do not host each other: they are in different blocks, so the
      # record has no hosting gap and stays visible with its own state (INV-3).
      record = in_seat_transfer_fixture(context.organization.id, context.version.id, x, y)

      transfer_fixture(context.organization.id, context.version.id, %{
        from_trip_id: "x",
        to_trip_id: "y",
        transfer_type: 5,
        from_stop_id: record.from_stop_id,
        to_stop_id: record.to_stop_id
      })

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?trip=a")

      assert has_element?(view, "#trip-transfers", "Transfer records · 1")
      assert has_element?(view, "#trip-transfers", "Riders stay on board")
      assert has_element?(view, "#trip-transfers", "Trip a → b")

      assert has_element?(
               view,
               "#trip-transfers [data-role='trip-transfer-state']",
               "Matches the block on all shared dates"
             )

      {:ok, elsewhere, _html} = live(conn, base <> "?trip=x")

      assert has_element?(elsewhere, "#trip-transfers", "Transfer records · 2")

      assert has_element?(
               elsewhere,
               "#trip-transfers [data-role='trip-transfer'][data-transfer-type='4']",
               "Riders stay on board"
             )

      assert has_element?(
               elsewhere,
               "#trip-transfers [data-role='trip-transfer'][data-transfer-type='5']",
               "Riders must get off and board again"
             )

      assert has_element?(elsewhere, "#trip-transfers", "Trip x → y")

      assert has_element?(
               elsewhere,
               "#trip-transfers [data-role='trip-transfer-state']",
               "Not next on this vehicle on Weekday, #{weekday_dates()} dates"
             )
    end
  end

  describe "trip= deep links" do
    setup :editor_scope

    test "a trip in a block on page 2 renders page 2 regardless of page=",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")

      for index <- 0..100 do
        block = "block-" <> String.pad_leading(Integer.to_string(index), 3, "0")
        start = 6 * 3_600 + index * 60

        trip(context, %{
          trip_id: "#{block}_0",
          block_id: block,
          first: clock(start),
          last: clock(start + 1_800)
        })
      end

      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?page=1&trip=block-100_0")

      assert has_element?(view, "#blocks-pager", "of 101 blocks")
      assert has_element?(view, "[data-block='block-100']")
      refute has_element?(view, "[data-block='block-000']")
      assert has_element?(view, "#trip-drawer", "Trip block-100_0")
    end

    test "a trip in another day type links to its day types, an unknown trip is unavailable",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      calendar(context, "SAT", "Saturday", @weekend)

      trip(context, %{trip_id: "wk_1", block_id: "101"})
      trip(context, %{trip_id: "sat_1", block_id: "201", service_id: "SAT"})

      conn = editor_conn(context)
      base = blocks_path(version.id)

      # The Weekday day type is the default one, so the Saturday trip is elsewhere.
      {:ok, view, _html} = live(conn, base <> "?trip=sat_1")

      assert has_element?(view, "#blocks-trip-elsewhere", "Trip sat_1 is not in this day type.")
      assert element_count(view, "#blocks-trip-elsewhere a[data-role='trip-day-type']") == 1
      refute has_element?(view, "#trip-drawer")

      assert has_element?(
               view,
               "#blocks-trip-elsewhere a[data-role='trip-day-type']",
               "Saturday · #{saturday_dates()} dates"
             )

      assert hrefs(view, "#blocks-trip-elsewhere a") == [
               base <> "?day=#{day_key(view, "Saturday")}&trip=sat_1"
             ]

      {:ok, missing, _html} = live(conn, base <> "?trip=missing")

      assert has_element?(missing, "#trip-elsewhere", "Trip missing isn't in this version.")
      refute has_element?(missing, "#trip-drawer")
    end

    test "an unplottable trip still opens its drawer", %{version: version} = context do
      calendar(context, "WK", "Weekday")
      trip(context, %{trip_id: "untimed_1", block_id: "101", last: nil})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?trip=untimed_1")

      assert has_element?(view, "#trip-drawer", "Trip untimed_1")
      assert has_element?(view, "#trip-drawer", "An endpoint time is missing.")
      assert has_element?(view, "#trip-drawer", "Time missing")
    end

    test "a frequency trip's drawer shows the repeat text", %{version: version} = context do
      calendar(context, "WK", "Weekday")

      frequency =
        trip(context, %{trip_id: "freq_1", first: "09:00:00", last: "10:00:00"})

      frequency_row_fixture(context.organization.id, context.version.id, %{
        trip_id: frequency.trip_id,
        headway_secs: 1_200
      })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?trip=freq_1")

      assert has_element?(view, "#trip-drawer", "Trip freq_1")

      assert has_element?(
               view,
               "#trip-drawer",
               "Repeats every 20 min; individual vehicle work can't be checked here. " <>
                 "An imported block can be removed."
             )
    end
  end
end
