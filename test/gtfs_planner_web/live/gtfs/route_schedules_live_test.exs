defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesLiveTest do
  # EV-5: the Schedules read view, its URL state and every documented state.
  #
  # Successful reads run through the production adapter resolved from
  # application config; the mock adapter is substituted only for the outage
  # case and restored on exit. Mount-time patches are consumed by live/2, so a
  # canonicalization is observed by following a non-canonical path through the
  # client with render_patch/2.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

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

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "schedules-live-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "schedules-live-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  defp schedules_path(version, route, query \\ %{}) do
    path = "/gtfs/#{version.id}/routes/#{route.route_id}/schedules"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  # The client follows one server patch. `render_patch/2` re-renders the view at
  # the path and leaves its own patch message in the mailbox.
  defp follow(view, path) do
    html = render_patch(view, path)
    assert_patched(view, path)
    html
  end

  defp weekly_calendar(organization, version, service_id, name) do
    calendar_fixture(organization.id, version.id, %{service_id: service_id})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name,
      service_schedule_name: name
    })

    service_id
  end

  defp dates_only_calendar(organization, version, service_id, name) do
    calendar_date_fixture(organization.id, version.id, %{
      service_id: service_id,
      date: ~D[2026-07-04],
      exception_type: 1
    })

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name,
      service_schedule_name: name
    })

    service_id
  end

  # One route carrying the whole read surface: two weekly calendars and an unused
  # dates-only one, a direction-0 pattern with linked, frequency, custom and
  # incomplete trips, an empty direction-0 pattern, a direction-1 pattern and two
  # unlinked trips.
  defp rich_route(%{organization: organization, version: version}) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "SCH1",
        route_short_name: "S1",
        route_long_name: "Schedules One"
      })

    weekday = weekly_calendar(organization, version, "SCH_WKD", "Weekday")
    holiday = weekly_calendar(organization, version, "SCH_HOL", "Holiday")
    dates_only = dates_only_calendar(organization, version, "SCH_DATES", "Special dates")

    Enum.each(1..5, fn index ->
      stop_fixture(organization.id, version.id, %{
        stop_id: "SCH1_S#{index}",
        stop_name: "Schedules Stop #{index}"
      })
    end)

    downtown =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "SCH1-P1",
        route_pattern_name: "Downtown",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"SCH1_S1", 0, 0, 1},
          {"SCH1_S2", 300, 360, 1},
          {"SCH1_S3", 660, 720, 0},
          {"SCH1_S4", 1020, 1080, 0},
          {"SCH1_S5", 1500, 1560, 1}
        ]
      })

    for {trip_id, start_time} <- [
          {"SCH1_T0600", "06:00:00"},
          {"SCH1_T0630", "06:30:00"},
          {"SCH1_T0700", "07:00:00"}
        ] do
      schedule_trip_fixture(organization.id, version.id, route.route_id, downtown, %{
        service_id: weekday,
        trip_id: trip_id,
        start_time: start_time,
        trip_headsign: "Downtown"
      })
    end

    schedule_trip_fixture(organization.id, version.id, route.route_id, downtown, %{
      service_id: weekday,
      trip_id: "SCH1_TFREQ",
      start_time: "09:00:00",
      trip_headsign: "Downtown",
      frequencies: [%{start_time: "09:00:00", end_time: "12:00:00", headway_secs: 1200}]
    })

    schedule_trip_fixture(organization.id, version.id, route.route_id, downtown, %{
      service_id: weekday,
      trip_id: "SCH1_TCUSTOM",
      state: "custom",
      timed_pattern_id: nil,
      stop_times: [
        {"SCH1_S1", "09:00:00", "09:00:00"},
        {"SCH1_S4", "09:20:00", "09:20:00"},
        {"SCH1_S3", "09:40:00", "09:40:00"}
      ]
    })

    schedule_trip_fixture(organization.id, version.id, route.route_id, downtown, %{
      service_id: weekday,
      trip_id: "SCH1_TNOTIME",
      stop_times: [{"SCH1_S1", nil, nil}, {"SCH1_S2", nil, nil}]
    })

    schedule_trip_fixture(organization.id, version.id, route.route_id, downtown, %{
      service_id: weekday,
      trip_id: "SCH1_TUNL1",
      state: "custom",
      timed_pattern_id: nil,
      route_pattern_id: nil
    })

    schedule_trip_fixture(organization.id, version.id, route.route_id, downtown, %{
      service_id: weekday,
      trip_id: "SCH1_TUNL2",
      state: "custom",
      timed_pattern_id: nil,
      route_pattern_id: nil,
      start_time: "10:00:00"
    })

    unused =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "SCH1-P3",
        route_pattern_name: "Express",
        route_pattern_typicality: 0,
        timing_name: "Standard",
        stops: [{"SCH1_S1", 0, 0, 1}, {"SCH1_S5", 900, 900, 1}]
      })

    schedule_pattern_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      direction_id: 1,
      route_pattern_id: "SCH1-P2",
      route_pattern_name: "Return",
      route_pattern_typicality: 1,
      timing_name: "Standard",
      stops: [{"SCH1_S5", 0, 0, 1}, {"SCH1_S1", 1500, 1500, 1}]
    })

    %{
      route: route,
      weekday: weekday,
      holiday: holiday,
      dates_only: dates_only,
      downtown: downtown,
      unused: unused
    }
  end

  describe "defaults and canonical params" do
    setup :editor_scope

    test "a bare URL renders the busiest calendar and its section",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#route-schedules")
      assert has_element?(view, "#schedules-view-counts", "6 trips · Weekday · To Downtown")
      assert has_element?(view, "#section-#{rich.downtown.pattern.route_pattern_id}")
      refute has_element?(view, "#schedules-no-trips")
    end

    test "a live reload at the canonical params restores the same view",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)
      canonical = schedules_path(version, rich.route, %{"service_id" => rich.weekday})

      {:ok, view, _html} = live(conn, canonical)

      assert has_element?(view, "#schedules-view-counts", "6 trips · Weekday · To Downtown")
      assert has_element?(view, "#trip-SCH1_T0600")
      assert has_element?(view, "#planning-summary")
    end

    test "missing, unknown and invalid values are canonicalized with a replace patch",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      render_patch(
        view,
        schedules_path(version, rich.route, %{
          "service_id" => "missing",
          "direction" => "9",
          "pattern" => "nope",
          "stops" => "weird"
        })
      )

      requested = assert_patch(view)
      assert requested =~ "service_id=missing"
      assert requested =~ "direction=9"
      assert requested =~ "pattern=nope"
      assert requested =~ "stops=weird"

      canonical = assert_patch(view)
      assert canonical == schedules_path(version, rich.route, %{"service_id" => rich.weekday})
      assert has_element?(view, "#schedules-view-counts", "6 trips · Weekday · To Downtown")
    end

    test "a requested calendar, direction, pattern and stops set are kept",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      all_stops =
        schedules_path(version, rich.route, %{
          "service_id" => rich.weekday,
          "pattern" => rich.downtown.pattern.id,
          "stops" => "all"
        })

      render_patch(view, all_stops)

      # The requested parameters are already canonical, so no further patch
      # follows and the filters survive verbatim.
      assert_patched(view, all_stops)
      refute_received {_ref, {:patch, _topic, _opts}}

      assert has_element?(view, "#schedules-stops-legend", "All stops shown")
      refute has_element?(view, "#section-#{rich.downtown.pattern.route_pattern_id}-omitted")
    end

    test "the calendar select lists every calendar with its route trip count and dates-only kind",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(
               view,
               "#calendar-filter option[value='#{rich.weekday}']",
               "Weekday · SCH_WKD · 8 trips"
             )

      assert has_element?(
               view,
               "#calendar-filter option[value='#{rich.holiday}']",
               "Holiday · SCH_HOL · 0 trips"
             )

      assert has_element?(
               view,
               "#calendar-filter option[value='#{rich.dates_only}']",
               "Special dates · SCH_DATES · 0 trips · Dates only"
             )
    end

    test "both version-switch events keep the params and navigate to the new version",
         %{conn: conn, organization: organization, version: version} = context do
      rich = rich_route(context)
      other = gtfs_version_fixture(organization.id)

      params = %{
        "service_id" => rich.weekday,
        "pattern" => rich.downtown.pattern.id,
        "stops" => "all"
      }

      target = schedules_path(other, rich.route, params)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route, params))
      render_click(view, "switch_gtfs_version", %{"version" => other.id})
      assert_redirect(view, target)

      {:ok, loaded, _html} = live(conn, schedules_path(version, rich.route, params))
      render_click(loaded, "gtfs_version_loaded", %{"version_id" => other.id})
      assert_redirect(loaded, target)
    end

    test "an unpublished or foreign version is ignored",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      render_click(view, "switch_gtfs_version", %{"version" => Ecto.UUID.generate()})

      refute_redirected(view)
      assert has_element?(view, "#trip-SCH1_T0600")
    end
  end

  describe "planning summary" do
    setup :editor_scope

    test "the vehicle count keeps the lower-bound wording with its most-at time",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#planning-vehicles-item-vehicles", "Vehicles needed")
      assert has_element?(view, "#vehicles-needed-line", "At least 3 vehicles for route S1 alone")

      assert has_element?(view, "#vehicles-needed-context", "Weekday")
      assert has_element?(view, "#vehicles-needed-context", "both directions")
      assert has_element?(view, "#vehicles-needed-context", "most at 09:20")

      assert has_element?(view, "#planning-summary", "Other routes can share vehicles")
      assert has_element?(view, "#vehicle-change")
      refute has_element?(view, "#vehicle-change", "→")
    end

    test "trips per hour marks frequency hours approximate and mutes zero hours",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#trips-per-hour-block", "Trips per hour · To Downtown")
      assert has_element?(view, "#trips-per-hour-hour-6", "06")
      assert has_element?(view, "#trips-per-hour-count-6", "3")
      assert has_element?(view, "#trips-per-hour-count-7", "1")
      assert has_element?(view, "#trips-per-hour-count-8", "0")
      assert has_element?(view, "#trips-per-hour-count-9", "≈4")
      assert has_element?(view, "#trips-per-hour-count-10", "≈4")
      assert has_element?(view, "#trips-per-hour-count-11", "≈3")
      refute has_element?(view, "#trips-per-hour-count-12")

      zero_hour = render(element(view, "#trips-per-hour-count-8"))
      assert zero_hour =~ "text-base-content/70"
    end

    test "incomplete trips are counted in the note", %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#incomplete-times-note", "1 trip without complete times")
    end
  end

  describe "sections" do
    setup :editor_scope

    test "the section heading, bands, timing lines and omitted stops describe the pattern",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)
      section_id = rich.downtown.pattern.route_pattern_id

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#section-#{section_id}-heading", "Downtown")
      assert has_element?(view, "#section-#{section_id}-heading", "Typical")
      assert has_element?(view, "#section-#{section_id}-facts", "6 trips · 5 stops")

      assert has_element?(
               view,
               "#section-#{section_id}-band-0",
               "06:00–07:00 · every 30 min · 3 trips"
             )

      assert has_element?(
               view,
               "#section-#{section_id}-timing-#{rich.downtown.timing.id}",
               "Standard: 5 · 19 min · 25 min total · 5 trips"
             )

      assert has_element?(view, "#section-#{section_id}-custom-trips", "1 custom-time trip")
      assert has_element?(view, "#section-#{section_id}-omitted", "2 stops not shown")
      assert has_element?(view, "#schedules-stops-legend", "Timepoints are the key stops")
    end

    test "the All stops view shows every occurrence and recomputes the segments",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)
      section_id = rich.downtown.pattern.route_pattern_id

      all_stops =
        schedules_path(version, rich.route, %{"service_id" => rich.weekday, "stops" => "all"})

      {:ok, view, _html} = live(conn, all_stops)

      assert has_element?(view, "#schedules-stops-legend", "All stops shown")
      assert has_element?(view, "#section-#{section_id}-facts", "6 trips · 5 stops")
      refute has_element?(view, "#section-#{section_id}-omitted")

      assert has_element?(
               view,
               "#section-#{section_id}-timing-#{rich.downtown.timing.id}",
               "Standard: 5 · 5 · 5 · 7 min · 25 min total · 5 trips"
             )

      assert has_element?(view, "#section-#{section_id}-table", "Schedules Stop 5")
    end

    test "a custom trip that differs from the pattern shows its reason with no time cells",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#trip-SCH1_TCUSTOM", "Custom times")

      assert has_element?(
               view,
               "#trip-SCH1_TCUSTOM-stops-differ",
               "Stops differ from this pattern"
             )

      assert has_element?(view, "#trip-SCH1_TCUSTOM-start", "09:00")

      html = render(element(view, "#trip-SCH1_TCUSTOM"))
      # A bare <tr> fragment loses its cells to HTML5 table-context parsing, so
      # the row is parsed inside a table wrapper.
      doc = LazyHTML.from_fragment("<table>#{html}</table>")
      cells = LazyHTML.query(doc, "td")

      assert Enum.count(cells, &(LazyHTML.text(&1) =~ ~r/\d\d:\d\d/)) == 1
    end

    test "a frequency trip lists its windows and an unreadable trip shows no time",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#trip-SCH1_TFREQ-frequency", "Every 20 min, 09:00–12:00")
      assert has_element?(view, "#trip-SCH1_TFREQ", "Standard")

      assert has_element?(view, "#trip-SCH1_TNOTIME-start", "No time")

      html = render(element(view, "#trip-SCH1_TNOTIME"))
      # Wrapped for the same table-context reason as the custom row above.
      doc = LazyHTML.from_fragment("<table>#{html}</table>")
      cells = LazyHTML.query(doc, "td")

      assert Enum.count(cells, &(String.trim(LazyHTML.text(&1)) == "—")) == 4
    end
  end

  describe "states" do
    setup :editor_scope

    test "no patterns shows the first-use empty state with a link to Patterns",
         %{conn: conn, version: version} = context do
      # The no-calendars state takes precedence, so this route's version needs a
      # calendar before the no-patterns state is reachable.
      weekly_calendar(context.organization, version, "SCH_NOPAT_WKD", "No patterns")

      route =
        route_fixture(context.organization.id, version.id, %{
          route_id: "SCH_NOPAT",
          route_short_name: "NP"
        })

      {:ok, view, _html} = live(conn, schedules_path(version, route))

      assert has_element?(view, "#schedules-no-patterns", "This route has no patterns yet")

      assert has_element?(
               view,
               "#schedules-no-patterns a[href='/gtfs/#{version.id}/routes/#{route.route_id}/patterns']",
               "Go to patterns"
             )

      refute has_element?(view, "#planning-summary")
    end

    test "a version with no calendars shows the manage-calendars empty state",
         %{conn: conn, organization: organization} do
      version = gtfs_version_fixture(organization.id)

      route =
        route_fixture(organization.id, version.id, %{
          route_id: "SCH_NOCAL",
          route_short_name: "NC"
        })

      {:ok, view, _html} = live(conn, schedules_path(version, route))

      assert has_element?(view, "#schedules-no-calendars", "This version has no calendars")

      assert has_element?(
               view,
               "#schedules-no-calendars a[href='/gtfs/#{version.id}/calendars']",
               "Manage calendars"
             )

      refute has_element?(view, "#schedules-view-counts")
    end

    test "no trips for the calendar and direction names both",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} =
        live(conn, schedules_path(version, rich.route, %{"direction" => "1"}))

      assert has_element?(view, "#schedules-no-trips", "No trips on Weekday going Direction 1")
      refute has_element?(view, "#planning-summary")
    end

    test "a pattern filter with no trips names the pattern",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} =
        live(conn, schedules_path(version, rich.route, %{"pattern" => rich.unused.pattern.id}))

      assert has_element?(view, "#schedules-no-trips", "No trips on this pattern for Weekday")
    end

    test "unlinked trips show the warning callout with a link to Patterns",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#schedules-unlinked", "2 trips aren't linked to a pattern")

      assert has_element?(
               view,
               "#schedules-unlinked a[href='/gtfs/#{version.id}/routes/#{rich.route.route_id}/patterns']"
             )

      refute has_element?(view, "#trip-SCH1_TUNL1")
    end

    test "the first paint shows the table skeleton", %{conn: conn, version: version} = context do
      rich = rich_route(context)

      # `live/2` returns the post-mount connected render, so the disconnected
      # first paint is observed through a plain request instead.
      html = conn |> get(schedules_path(version, rich.route)) |> html_response(200)

      assert html =~ "schedules-loading"
      refute html =~ "schedules-add-trips"
    end

    test "an unavailable read shows the retry callout and recovers",
         %{conn: conn, version: version} = context do
      substitute_read_adapter(%{})
      rich = rich_route(context)

      recover = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :load_route_schedule, fn org, ver, route_id, filters ->
        if :atomics.get(recover, 1) == 1 do
          CatalogReadAdapter.Repo.load_route_schedule(org, ver, route_id, filters)
        else
          {:error, :unavailable}
        end
      end)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#schedules-unavailable", "Schedules couldn't be loaded")
      assert has_element?(view, "#schedules-retry", "Retry")
      refute has_element?(view, "#schedules-no-trips")

      :atomics.put(recover, 1, 1)
      render_click(element(view, "#schedules-retry"))

      refute has_element?(view, "#schedules-unavailable")
      assert has_element?(view, "#trip-SCH1_T0600")
      assert has_element?(view, "#planning-summary")
    end

    test "a failed refresh keeps the sections already on screen",
         %{conn: conn, version: version} = context do
      substitute_read_adapter(%{})
      rich = rich_route(context)
      canonical = schedules_path(version, rich.route, %{"service_id" => rich.weekday})

      fail_next = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :load_route_schedule, fn org, ver, route_id, filters ->
        if :atomics.get(fail_next, 1) == 1 do
          {:error, :unavailable}
        else
          CatalogReadAdapter.Repo.load_route_schedule(org, ver, route_id, filters)
        end
      end)

      {:ok, view, _html} = live(conn, canonical)

      assert has_element?(view, "#trip-SCH1_T0600")
      assert has_element?(view, "#planning-summary")

      :atomics.put(fail_next, 1, 1)

      all_stops =
        schedules_path(version, rich.route, %{"service_id" => rich.weekday, "stops" => "all"})

      view |> form("#stops-filter-form", %{"stops" => "all"}) |> render_change()
      assert_patched(view, all_stops)

      follow(view, all_stops)

      assert has_element?(view, "#schedules-unavailable")
      assert has_element?(view, "#trip-SCH1_T0600")
      assert has_element?(view, "#planning-summary")
      refute has_element?(view, "#schedules-no-trips")
    end
  end

  describe "selection" do
    setup :editor_scope

    test "checkboxes render alongside the mutation controls",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)
      section_id = rich.downtown.pattern.route_pattern_id

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#section-#{section_id}-select-all")
      assert has_element?(view, "#trip-select-SCH1_T0600")
      assert has_element?(view, "#trip-select-SCH1_TNOTIME")
      refute has_element?(view, "#trip-select-SCH1_TUNL1")

      # The step-7 mutation controls are present; the bulk toolbar still needs a
      # selection.
      assert has_element?(view, "#schedules-add-trips")
      assert has_element?(view, "#trip-SCH1_T0600-edit")
      refute has_element?(view, "#schedules-bulk-toolbar")
    end

    test "a selection never enters the URL and clears on a params change",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)
      canonical = schedules_path(version, rich.route, %{"service_id" => rich.weekday})

      all_stops =
        schedules_path(version, rich.route, %{"service_id" => rich.weekday, "stops" => "all"})

      {:ok, view, _html} = live(conn, canonical)

      render_click(element(view, "#trip-select-SCH1_T0600"))

      assert has_element?(view, "#trip-select-SCH1_T0600[checked]")
      refute_received {_ref, {:patch, _topic, _opts}}

      view |> form("#stops-filter-form", %{"stops" => "all"}) |> render_change()
      assert_patched(view, all_stops)

      follow(view, all_stops)

      refute has_element?(view, "#trip-select-SCH1_T0600[checked]")
    end

    test "the section header checkbox selects and clears every row",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)
      section_id = rich.downtown.pattern.route_pattern_id
      canonical = schedules_path(version, rich.route, %{"service_id" => rich.weekday})

      {:ok, view, _html} = live(conn, canonical)

      render_click(element(view, "#section-#{section_id}-select-all"))

      assert has_element?(view, "#trip-select-SCH1_T0600[checked]")
      assert has_element?(view, "#trip-select-SCH1_TNOTIME[checked]")
      assert has_element?(view, "#section-#{section_id}-select-all[checked]")

      render_click(element(view, "#section-#{section_id}-select-all"))

      refute has_element?(view, "#trip-select-SCH1_T0600[checked]")
      refute has_element?(view, "#section-#{section_id}-select-all[checked]")
    end
  end

  describe "scope" do
    setup :editor_scope

    test "an unknown or foreign route navigates to the routes list",
         %{conn: conn, version: version} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/gtfs/#{version.id}/routes/SCH_MISSING/schedules")

      assert to == "/gtfs/#{version.id}/routes"
    end

    test "a successful read runs on the real Repo adapter",
         %{conn: conn, version: version} = context do
      rich = rich_route(context)

      {:ok, view, _html} = live(conn, schedules_path(version, rich.route))

      assert has_element?(view, "#vehicles-needed-line", "At least 3 vehicles for route S1 alone")
      assert has_element?(view, "#trip-SCH1_T0600-start", "06:00")
    end
  end
end
