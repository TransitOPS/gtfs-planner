defmodule GtfsPlannerWeb.Gtfs.BlocksScopeLiveTest do
  # EV-19: the Blocks day-type scope, the whole-day count strip, the Service
  # dates, Checks and Peak drawers and every page state, observed through the
  # ordinary `/gtfs/:version/blocks` route on the production `CatalogReadAdapter.Repo`
  # and the scoped `Blocking` context. Rows are created inside the SQL Sandbox
  # transaction and rolled back. Only the outage cases substitute the catalog read
  # adapter, and they restore the previous config on exit.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_scope_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock

  @adapter_key :gtfs_catalog_read_adapter
  @weekend %{
    monday: 0,
    tuesday: 0,
    wednesday: 0,
    thursday: 0,
    friday: 0,
    saturday: 1,
    sunday: 0
  }

  setup :verify_on_exit!

  defp editor_scope(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "1"})

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
    {first, attrs} = attrs |> Map.new() |> Map.pop(:first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.route.route_id,
      attrs
      |> Map.put_new(:service_id, "WK")
      |> Map.put_new(:trip_id, "trip_#{System.unique_integer([:positive])}")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  # Two blocks, five trips and two unassigned trips. Block 101 runs 06:00–08:30 and
  # block 102 07:00–08:00, so two vehicles are out from 07:00; the pool trips sit
  # outside the blocks and are excluded from the peak.
  defp seed_blocked_day(context) do
    calendar(context, "WK", "Weekday")

    trip(context, %{trip_id: "t1", block_id: "101", first: "06:00:00", last: "07:00:00"})
    trip(context, %{trip_id: "t2", block_id: "101", first: "07:30:00", last: "08:30:00"})
    trip(context, %{trip_id: "t3", block_id: "102", first: "07:00:00", last: "08:00:00"})
    trip(context, %{trip_id: "p1", first: "05:30:00", last: "06:30:00"})
    trip(context, %{trip_id: "p2", first: "09:00:00", last: "10:00:00"})
  end

  # Block 101 overlaps itself (08:00–09:00 and 08:30–09:30) and holds a trip with a
  # missing endpoint time; every block spans 08:00–11:00, which is twelve
  # 15-minute bins.
  defp seed_overlapping_day(context) do
    calendar(context, "WK", "Weekday")

    trip(context, %{trip_id: "t1", block_id: "101", first: "08:00:00", last: "09:00:00"})
    trip(context, %{trip_id: "t2", block_id: "101", first: "08:30:00", last: "09:30:00"})
    trip(context, %{trip_id: "t3", block_id: "102", first: "10:00:00", last: "11:00:00"})
    trip(context, %{trip_id: "untimed", first: nil, last: "12:00:00"})
  end

  defp stub_real_read do
    stub(CatalogReadAdapterMock, :load_blocking_day, &CatalogReadAdapter.Repo.load_blocking_day/3)
  end

  defp substitute_read_adapter(_context) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)

    :ok
  end

  defp strip_value(view, key) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#blocks-summary-counts-item-#{key}")
    |> LazyHTML.query("[data-role='count-strip-value']")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp element_count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp day_options(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
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

  # The day-type key is a derived 43-character value, so a test that needs one as
  # an input reads it from the production load or from the rendered select.
  defp first_day_key(context) do
    {:ok, day} = Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)
    day.day_type.key
  end

  describe "the day-type scope and the whole-day summary" do
    setup :editor_scope

    test "the count strip shows the whole day's figures and they survive a filter and paging",
         %{version: version} = context do
      seed_blocked_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert strip_value(view, "blocks") == "2"
      assert strip_value(view, "unassigned") == "2"
      assert strip_value(view, "problems") == "0"
      assert strip_value(view, "notices") == "0"
      assert strip_value(view, "peak") == "2"

      assert has_element?(
               view,
               "#blocks-summary-note",
               "Whole day type · #{weekday_count()} dates"
             )

      assert has_element?(
               view,
               "#blocks-peak-detail",
               "Peak at 07:00 · excludes 2 unassigned trips and 0 frequency trips"
             )

      # The route filter and paging describe the workspace, never the whole day.
      view
      |> element("#blocks-filter-form")
      |> render_change(%{"route" => context.route.route_id})

      assert strip_value(view, "blocks") == "2"
      assert strip_value(view, "unassigned") == "2"
      assert strip_value(view, "peak") == "2"

      {:ok, paged, _html} = live(conn, blocks_path(version.id) <> "?page=3&pool_page=2")

      assert strip_value(paged, "blocks") == "2"
      assert strip_value(paged, "unassigned") == "2"
      assert strip_value(paged, "problems") == "0"

      {:ok, filtered, _html} =
        live(conn, blocks_path(version.id) <> "?route=#{context.route.route_id}")

      assert strip_value(filtered, "blocks") == "2"
      assert strip_value(filtered, "peak") == "2"
    end

    test "the day select prints each day type's date count and groups one-date types",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      calendar(context, "SAT", "Saturday", @weekend)
      calendar(context, "TURKEY", "Thanksgiving", %{dates: [~D[2026-11-26]]})

      trip(context, %{trip_id: "wk_1", block_id: "101"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      options = day_options(view)

      assert {"WK", "Weekday · #{weekday_count()} dates"} in options

      assert {"SAT", "Saturday · #{saturday_count()} dates"} in options

      assert Enum.any?(options, fn {_key, text} -> text == "Thanksgiving · 1 date" end)

      doc = view |> render() |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(LazyHTML.query(doc, "#blocks-day optgroup"), "label") ==
               ["Special days"]

      assert LazyHTML.text(LazyHTML.query(doc, "#blocks-day optgroup option")) |> String.trim() ==
               "Thanksgiving · 1 date"
    end

    test "selecting a day patches the day key and drops the trip and paging",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      calendar(context, "SAT", "Saturday", @weekend)
      trip(context, %{trip_id: "wk_1", block_id: "101"})

      conn = editor_conn(context)

      {:ok, view, _html} =
        live(conn, blocks_path(version.id) <> "?page=3&pool_page=2&trip=wk_1")

      saturday = day_key(view, "Saturday")

      view |> element("#blocks-day") |> render_change(%{"day" => saturday})

      assert_patch(view, blocks_path(version.id) <> "?day=#{saturday}")
      assert :sys.get_state(view.pid).socket.assigns.selection == MapSet.new()
    end

    test "an unknown day key shows the recovery state and applies no day type",
         %{version: version} = context do
      seed_blocked_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?day=not-a-key")

      assert has_element?(view, "#blocks-unknown-day")
      assert has_element?(view, "#blocks-unknown-day #blocks-day")
      refute has_element?(view, "#blocks-workspace")
      refute has_element?(view, "#blocks-summary")
      refute_received {_ref, {:patch, _topic, _opts}}

      # No day type is applied: the select carries no selection.
      assert element_count(view, "#blocks-day option[selected]") == 0

      # Choosing the first day type in the recovery state loads it.
      first_key = view |> day_options() |> hd() |> elem(0)

      view
      |> element("#blocks-unknown-day-form")
      |> render_submit(%{"day" => first_key})

      assert_patch(view, blocks_path(version.id) <> "?day=#{first_key}")
    end
  end

  describe "the page states" do
    setup :editor_scope

    test "a version with no calendars shows the no-dates state with a Calendars link",
         %{version: version} = context do
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert has_element?(view, "#blocks-no-dates")
      refute has_element?(view, "#blocks-workspace")

      doc = view |> render() |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(LazyHTML.query(doc, "#blocks-no-dates a"), "href") ==
               ["/gtfs/#{version.id}/calendars"]
    end

    test "day types without trips show the trips-needed state with a Routes link",
         %{version: version} = context do
      calendar(context, "WK", "Weekday")
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert has_element?(view, "#blocks-empty", "Blocks need trips with calendars")
      refute has_element?(view, "#blocks-workspace")

      doc = view |> render() |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(LazyHTML.query(doc, "#blocks-empty a"), "href") ==
               ["/gtfs/#{version.id}/routes"]
    end

    test "an all-unassigned day shows the no-blocks guidance", %{version: version} = context do
      calendar(context, "WK", "Weekday")
      trip(context, %{trip_id: "p1", first: "08:00:00", last: "09:00:00"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert strip_value(view, "blocks") == "0"
      assert strip_value(view, "unassigned") == "1"

      assert has_element?(
               view,
               "#blocks-workspace-guidance",
               "Start by selecting trips and assigning them to a new block."
             )
    end

    test "mixed agency timezones show the callout", %{version: version} = context do
      seed_blocked_day(context)

      agency_fixture(context.organization.id, version.id, %{
        agency_id: "a1",
        agency_timezone: "America/New_York"
      })

      agency_fixture(context.organization.id, version.id, %{
        agency_id: "a2",
        agency_timezone: "America/Los_Angeles"
      })

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert has_element?(view, "#blocks-mixed-timezones")
      assert has_element?(view, "#blocks-summary")
    end

    test "the disconnected render shows the skeleton and render/1 never reads the day",
         %{version: version} = context do
      conn = editor_conn(context)

      body = conn |> get(blocks_path(version.id)) |> html_response(200)
      doc = LazyHTML.from_fragment(body)

      assert Enum.count(LazyHTML.query(doc, "#blocks-skeleton")) == 1
      assert Enum.empty?(LazyHTML.query(doc, "#blocks-summary"))
      assert Enum.empty?(LazyHTML.query(doc, "#blocks-workspace"))

      source = File.read!("lib/gtfs_planner_web/live/gtfs/blocks_live.ex")
      render_body = source |> String.split("def render(assigns) do") |> List.last()

      refute render_body =~ ~r/@day\b/
      assert render_body =~ "@day_type"
    end
  end

  describe "an unavailable database" do
    setup :editor_scope
    # Only this describe reads through the mock: the page resolves its adapter
    # from application config, so a stub alone would never be called.
    setup :substitute_read_adapter

    test "an outage shows the callout and Retry loads the same URL again",
         %{version: version} = context do
      seed_blocked_day(context)
      conn = editor_conn(context)

      stub(CatalogReadAdapterMock, :load_blocking_day, fn _org, _version, _key ->
        {:error, :unavailable}
      end)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert has_element?(view, "#blocks-unavailable")
      assert has_element?(view, "#blocks-retry")
      refute has_element?(view, "#blocks-summary")

      stub_real_read()

      view |> element("#blocks-retry") |> render_click()

      refute_received {_ref, {:patch, _topic, _opts}}
      refute has_element?(view, "#blocks-unavailable")
      assert strip_value(view, "blocks") == "2"
      assert strip_value(view, "unassigned") == "2"
    end

    test "an outage on reload keeps the loaded day below the callout",
         %{version: version} = context do
      seed_blocked_day(context)
      calendar(context, "SAT", "Saturday", @weekend)
      trip(context, %{trip_id: "sat_1", service_id: "SAT", block_id: "201"})

      conn = editor_conn(context)

      stub_real_read()
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert strip_value(view, "blocks") == "2"

      stub(CatalogReadAdapterMock, :load_blocking_day, fn _org, _version, _key ->
        {:error, :unavailable}
      end)

      saturday = day_key(view, "Saturday")
      view |> element("#blocks-day") |> render_change(%{"day" => saturday})

      assert has_element?(view, "#blocks-unavailable")
      assert strip_value(view, "blocks") == "2"
      assert has_element?(view, "#blocks-workspace")
    end
  end

  describe "the drawers" do
    setup :editor_scope

    test "the checks drawer lists problems before notices with their actions",
         %{version: version} = context do
      seed_overlapping_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view |> element("#blocks-review-checks") |> render_click()

      assert has_element?(view, "#checks-drawer-overlay[data-open='true']")

      html = render(view)

      # `:binary.match/2` returns each id's byte offset, so the problem group must
      # start before the notice group and a missing id fails the match.
      {problems_at, _length} = :binary.match(html, "checks-drawer-problems")
      {notices_at, _length} = :binary.match(html, "checks-drawer-notices")

      assert problems_at < notices_at

      problems =
        LazyHTML.from_fragment(html)
        |> LazyHTML.query("#checks-drawer-problems [data-role='blocks-finding']")

      assert [overlap] =
               Enum.filter(problems, &(LazyHTML.attribute(&1, "data-code") == ["overlap"]))

      assert LazyHTML.attribute(overlap, "data-severity") == ["error"]

      assert LazyHTML.text(LazyHTML.query(overlap, "[data-role='blocks-finding-block']"))
             |> String.trim() == "Open block 101"

      trip_actions =
        LazyHTML.text(LazyHTML.query(overlap, "[data-role='blocks-finding-trip']"))
        |> String.trim()

      assert trip_actions =~ "Open trip t1"
      assert trip_actions =~ "Open trip t2"

      assert has_element?(
               view,
               "#checks-drawer-notices [data-role='blocks-finding'][data-code='unplottable']"
             )

      assert has_element?(view, "#checks-drawer-notices", "Time missing")
    end

    test "the peak drawer shows the definition and one row per 15-minute bin",
         %{version: version} = context do
      seed_overlapping_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view |> element("#blocks-summary-counts-item-peak") |> render_click()

      assert has_element?(view, "#peak-drawer-overlay[data-open='true']")

      assert has_element?(
               view,
               "#peak-drawer",
               "Blocks in progress, including time between trips. Excludes unassigned and frequency trips."
             )

      # Blocks span 08:00–11:00, which is twelve 15-minute bins.
      assert element_count(view, "#peak-bins tbody tr[data-role='peak-bin']") == 12

      assert has_element?(view, "#peak-bin-28800", "08:00")
      assert has_element?(view, "#peak-bin-38700", "10:45")

      assert has_element?(
               view,
               "#peak-exclusions",
               "Excludes 1 unassigned trip and 0 frequency trips"
             )
    end

    test "the service dates drawer lists the dates by month",
         %{version: version} = context do
      calendar(context, "SPRING", "Spring dates", %{
        dates: [~D[2026-03-02], ~D[2026-03-04], ~D[2026-04-01]]
      })

      trip(context, %{trip_id: "s1", service_id: "SPRING", block_id: "101"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      view |> element("#blocks-service-dates") |> render_click()

      assert has_element?(view, "#service-dates-drawer-overlay[data-open='true']")

      doc = view |> render() |> LazyHTML.from_fragment()
      months = LazyHTML.query(doc, "[data-role='service-dates-month']")

      assert Enum.count(months) == 2
      assert LazyHTML.text(months) =~ "March 2026"
      assert LazyHTML.text(months) =~ "April 2026"
      assert LazyHTML.text(months) =~ "02 Mar 2026"

      # Chronological order: a Date struct compares day-first, so the range needs
      # the ordered dates.
      assert has_element?(view, "#service-dates-drawer", "02 Mar 2026 – 01 Apr 2026")
      assert has_element?(view, "#service-dates-drawer", "Spring dates · 3 dates")
    end
  end

  describe "URL state" do
    setup :editor_scope

    test "non-default parameters round-trip and defaults are omitted",
         %{version: version} = context do
      seed_overlapping_day(context)
      conn = editor_conn(context)
      weekday = first_day_key(context)

      base =
        blocks_path(version.id) <>
          "?day=#{weekday}&panel=pool&route=#{context.route.route_id}&status=problems" <>
          "&sort=trips&dir=desc&scale=zoom&page=3&pool_page=2"

      {:ok, view, _html} = live(conn, base)

      assert has_element?(view, "#blocks-problems-only[checked]")

      doc = view |> render() |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(LazyHTML.query(doc, "#blocks-route option[selected]"), "value") ==
               [context.route.route_id]

      # A patch keeps every non-default parameter and omits the defaults: the
      # review-checks button is a drawer and the finding's block is a patch.
      view |> element("#blocks-review-checks") |> render_click()
      view |> element("[data-role='blocks-finding-block']") |> render_click()

      assert_patch(view, base <> "&block=101")
    end

    test "an unknown route falls back to all routes", %{version: version} = context do
      seed_blocked_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?route=not-a-route")

      refute has_element?(view, "#blocks-route option[selected]")
      assert has_element?(view, "#blocks-summary")
    end

    test "a fully blocked day shows 0 unassigned trips", %{version: version} = context do
      calendar(context, "WK", "Weekday")

      trip(context, %{trip_id: "t1", block_id: "101", first: "08:00:00", last: "09:00:00"})
      trip(context, %{trip_id: "t2", block_id: "102", first: "09:30:00", last: "10:30:00"})

      conn = editor_conn(context)
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert strip_value(view, "unassigned") == "0"
      assert strip_value(view, "blocks") == "2"
    end
  end

  defp weekday_count, do: dates_matching(&(Date.day_of_week(&1) in 1..5))

  defp saturday_count, do: dates_matching(&(Date.day_of_week(&1) == 6))
end
