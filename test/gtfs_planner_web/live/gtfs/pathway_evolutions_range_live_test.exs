defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsRangeLiveTest do
  @moduledoc """
  The bounded range check of the access view, through its ordinary route: the
  form, the exact service-date horizon and periods the context answers with, the
  grouped and every-period presentations, the spans the context refuses and the
  deadline that stops a check which runs too long.

  Assertions are authored from AC-21 to AC-24, AC-36, AC-40 and AC-41. Every
  service date, service time, local clock time, UTC offset and horizon endpoint
  below is a hand-derived literal from the fixture and from `America/New_York`;
  the report's own output is never read back as the expected value. The two
  limit cases drive real fixtures rather than a test adapter: a station whose
  candidate envelope covers more than 200,000 instances is
  `:analysis_too_large`, and a station with hundreds of independent closures
  keeps one range request genuinely in flight long enough for its own deadline
  message to be delivered while it runs.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  @station_stop %{
    stop_id: "RANGE_STATION",
    stop_name: "Range Test Station",
    location_type: 1,
    parent_station: nil
  }

  # A slash and a space in the elevator's ID, so a period's cause and its data
  # attributes have to carry the exact value rather than a sanitized one.
  @lift_pathway_id "RANGE PW/LIFT 1"

  # 2027-01-15 is a Friday in winter: America/New_York is EST, so the service
  # day runs 05:00Z to 05:00Z. 2027-01-19 is a Tuesday whose 25:00 window is the
  # next civil morning, and 2027-03-14 is the spring-forward Sunday.
  @friday ~D[2027-01-15]
  @tuesday ~D[2027-01-19]
  @dst_saturday ~D[2027-03-13]

  # How many independent closures the deadline fixture carries. Each closure
  # owns its own pathway, so the sweep evaluates a different closed set at every
  # boundary and the request stays in flight long enough for its deadline to be
  # delivered while it is still working.
  @busy_closures 400

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, version: version}
  end

  defp access_path(version, stop_id, date, time) do
    "/gtfs/#{version.id}/stops/#{stop_id}/evolutions/access?date=#{date}&time=#{time}"
  end

  # A daily native calendar over the whole span the tests name, including the
  # agency's own today so a default moment is on a service date.
  defp daily_calendar(organization, version, service_id, weekdays \\ %{}) do
    today = Date.utc_today()

    calendar_fixture(
      organization.id,
      version.id,
      Map.merge(
        %{
          service_id: service_id,
          monday: 1,
          tuesday: 1,
          wednesday: 1,
          thursday: 1,
          friday: 1,
          saturday: 1,
          sunday: 1,
          start_date: Date.add(today, -30),
          end_date: Date.add(today, 400)
        },
        weekdays
      )
    )
  end

  # A calendar that serves exactly one date: no weekly day at all plus one
  # addition. It is how a closure is kept off every other service date, so a
  # moment preview of another date stays empty while the range under test has
  # its instances.
  defp one_date_calendar(organization, version, service_id, date) do
    calendar_fixture(organization.id, version.id, %{
      service_id: service_id,
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 0,
      start_date: Date.add(date, -400),
      end_date: Date.add(date, 400)
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: service_id,
      date: date,
      exception_type: 1
    })
  end

  # One station with two entrances, a mezzanine, a platform with a boarding
  # area and three pathways: a walkway from the first entrance, and a lift plus
  # a staircase from the mezzanine to the platform. The first entrance therefore
  # reaches the platform for walking and step-free travel, while the second
  # entrance has no pathway at all, so its pair is a baseline gap. The lift
  # carries a punctuated natural ID.
  defp range_station(organization, version) do
    station = stop_fixture(organization.id, version.id, @station_stop)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    entrance =
      stop_fixture(organization.id, version.id, %{
        stop_id: "RANGE_ENTRANCE",
        stop_name: "North entrance",
        location_type: 2,
        parent_station: station.stop_id
      })

    lonely_entrance =
      stop_fixture(organization.id, version.id, %{
        stop_id: "RANGE_EAST_ENTRANCE",
        stop_name: "East entrance",
        location_type: 2,
        parent_station: station.stop_id
      })

    mezzanine =
      stop_fixture(organization.id, version.id, %{
        stop_id: "RANGE_MEZZANINE",
        stop_name: "Mezzanine hall",
        location_type: 0,
        parent_station: station.stop_id
      })

    platform =
      stop_fixture(organization.id, version.id, %{
        stop_id: "RANGE_PLATFORM",
        stop_name: "Platform 1",
        location_type: 0,
        parent_station: station.stop_id
      })

    _boarding =
      stop_fixture(organization.id, version.id, %{
        stop_id: "RANGE_BOARDING",
        stop_name: "Platform 1 boarding area",
        location_type: 4,
        parent_station: station.stop_id
      })

    walkway =
      pathway_fixture(organization.id, version.id, entrance.stop_id, mezzanine.stop_id, %{
        pathway_id: "RANGE PW/WALK 1",
        pathway_mode: 1,
        is_bidirectional: true
      })

    lift =
      pathway_fixture(organization.id, version.id, mezzanine.stop_id, platform.stop_id, %{
        pathway_id: @lift_pathway_id,
        pathway_mode: 5,
        is_bidirectional: true
      })

    stairs =
      pathway_fixture(organization.id, version.id, mezzanine.stop_id, platform.stop_id, %{
        pathway_id: "RANGE_PW_STAIR",
        pathway_mode: 2,
        is_bidirectional: true
      })

    %{
      station: station,
      entrance: entrance,
      lonely_entrance: lonely_entrance,
      mezzanine: mezzanine,
      platform: platform,
      walkway: walkway,
      lift: lift,
      stairs: stairs
    }
  end

  defp lift_closure(organization, version, start_time, end_time, service_id \\ "CAL_DAILY") do
    pathway_evolution_fixture(organization.id, version.id, %{
      pathway_id: @lift_pathway_id,
      service_id: service_id,
      start_time: start_time,
      end_time: end_time
    })
  end

  # The station a range check runs against with one closure already in place.
  defp closed_station(organization, version, start_time \\ 32_400, end_time \\ 36_000) do
    fixture = range_station(organization, version)
    daily_calendar(organization, version, "CAL_DAILY")
    closure = lift_closure(organization, version, start_time, end_time)

    Map.put(fixture, :closure, closure)
  end

  defp open_access(conn, version, station, date, time \\ "12:00:00") do
    {:ok, view, _html} = live(conn, access_path(version, station.stop_id, date, time))
    render_async(view, 5_000)
    view
  end

  defp check_range(view, first, last) do
    view
    |> form("#range-form", %{"range" => %{"first_date" => first, "last_date" => last}})
    |> render_submit()
  end

  defp run_range(view, first, last) do
    check_range(view, first, last)
    render_async(view, 5_000)
  end

  # The range report's own rows, read from the table the wide layout shows. Each
  # row carries the exact occurrence, local window, offsets and period count the
  # report produced.
  defp range_rows(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#range-periods-table tbody tr")
  end

  defp list_rows(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#range-periods-list > li")
  end

  defp row_attributes(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute(name) |> List.first()))
  end

  describe "the range form" do
    setup :editor_setup

    test "opens on the selected service date for both endpoints", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = closed_station(organization, version)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))

      assert has_element?(view, "#range-section")
      assert has_element?(view, "#range-help", "Checks every closure boundary across 1–31")
      assert view |> element("#range-first") |> render() =~ "2027-01-15"
      assert view |> element("#range-last") |> render() =~ "2027-01-15"
      assert has_element?(view, "#check-range", "Check date range")

      # Nothing has been checked, so the empty state says what a range is and no
      # result, stale label or limit region exists yet.
      assert has_element?(view, "#range-empty", "No range checked yet.")
      refute has_element?(view, "#range-result")
      refute has_element?(view, "#range-stale")
      refute has_element?(view, "#range-no-loss")
      refute has_element?(view, "#range-invalid")
    end

    test "a five-minute period keeps the exact horizon, window and target", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, closure: closure} =
        closed_station(organization, version, 32_400, 32_700)

      conn = log_in_user(conn, user, organization: organization)
      view = open_access(conn, version, station, @friday)

      html = run_range(view, "2027-01-15", "2027-01-15")

      # The covered span is [origin(first), max(origin(last + 1), the latest end
      # on last)), stated in the zone the service times count from. EST is
      # UTC-05:00, so the Friday service day runs 2027-01-15T05:00Z to
      # 2027-01-16T05:00Z: local midnight to local midnight.
      assert has_element?(
               view,
               "#range-result",
               "Service dates Jan 15, 2027 · Jan 15 12:00 AM to Jan 16 12:00 AM (America/New_York)"
             )

      assert has_element?(view, "#range-computed", "1 period with lost connections · Checked ")

      # One period, so grouping collapses nothing and no view switch is offered:
      # the periods the API returned are exactly the rows on screen.
      refute has_element?(view, "#range-view")

      assert length(range_rows(html)) == 1
      assert length(list_rows(html)) == 1

      assert row_attributes(html, "#range-periods-table tbody tr", "data-range-row") == ["period"]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-service-date") == [
               "2027-01-15"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-target-time") == [
               "32400"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-period-count") == ["1"]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-local-start") == [
               "2027-01-15T09:00:00"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-local-end") == [
               "2027-01-15T09:05:00"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-start-offset") == [
               "-18000"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-end-offset") == [
               "-18000"
             ]

      # The period's own duration is what the reader measures: five minutes.
      assert has_element?(view, "#range-period-0-when", "9:00 AM – 9:05 AM")

      # The platform lost its last step-free route, and the pair report names
      # which entrance and platform lost which direction.
      assert has_element?(view, "#range-period-0-lost", "No step-free route to Platform 1")
      assert has_element?(view, "#range-period-0-lost", "No step-free route from Platform 1")

      assert has_element?(
               view,
               "#range-period-0-lost",
               "Step-free to platform · North entrance ↔ Platform 1"
             )

      assert has_element?(
               view,
               "#range-period-0-lost",
               "Step-free from platform · North entrance ↔ Platform 1"
             )

      # Walking is untouched by the lift's closure, so it is never listed.
      refute html =~ "Walking to platform"

      # The cause is the closure that is active over the whole period, named by
      # its exact natural ID and its own service window.
      assert has_element?(view, "#range-period-0-cause-#{closure.id}-2027-01-15")
      assert html =~ @lift_pathway_id
      assert html =~ "09:00–09:05"

      # The Show at link names the pair the backend chose for this period, not a
      # clock label reparsed here.
      assert row_attributes(html, "#range-show-0", "data-show-date") == ["2027-01-15"]
      assert row_attributes(html, "#range-show-0", "data-show-time") == ["09:00"]

      assert row_attributes(html, "#range-show-0", "href") == [
               "/gtfs/#{version.id}/stops/#{station.stop_id}/evolutions/access?date=2027-01-15&time=09%3A00%3A00"
             ]

      refute has_element?(view, "#range-no-loss")
      refute has_element?(view, "#range-stale")
      refute has_element?(view, "#range-incomplete")
    end

    test "an overnight window on the last date appears and names the next local day", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = closed_station(organization, version, 90_000, 93_600)
      conn = log_in_user(conn, user, organization: organization)
      view = open_access(conn, version, station, @tuesday)

      html = run_range(view, "2027-01-19", "2027-01-19")

      # 25:00 on Tuesday is 01:00 on Wednesday. The horizon end is the later of
      # Wednesday's origin (2027-01-20T05:00Z) and the last instance's end
      # (2027-01-20T07:00Z), so the span reaches 2:00 AM local.
      assert has_element?(
               view,
               "#range-result",
               "Service dates Jan 19, 2027 · Jan 19 12:00 AM to Jan 20 2:00 AM (America/New_York)"
             )

      assert length(range_rows(html)) == 1

      # The occurrence is the service date and elapsed seconds the backend named:
      # Tuesday 25:00, not a Wednesday clock label.
      assert row_attributes(html, "#range-periods-table tbody tr", "data-service-date") == [
               "2027-01-19"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-target-time") == [
               "90000"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-local-start") == [
               "2027-01-20T01:00:00"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-local-end") == [
               "2027-01-20T02:00:00"
             ]

      # The local window is on the next civil day, and the row says so instead of
      # presenting it as Tuesday's own clock.
      assert has_element?(view, "#range-period-0-when", "1:00 AM – 2:00 AM on Wed, Jan 20")
      assert row_attributes(html, "#range-show-0", "data-show-time") == ["25:00"]
    end
  end

  describe "grouping and listing the same periods" do
    setup :editor_setup

    test "repeats one window into a group and never merges across a DST offset change", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = closed_station(organization, version, 32_400, 36_000)
      conn = log_in_user(conn, user, organization: organization)
      view = open_access(conn, version, station, @dst_saturday)

      html = run_range(view, "2027-03-13", "2027-03-15")

      # The spring-forward Sunday splits the offsets: 2027-03-13 is EST and the
      # two days after it are EDT. The span is [origin(Mar 13),
      # origin(Mar 16)) in local terms, midnight to midnight.
      assert has_element?(
               view,
               "#range-result",
               "Service dates Mar 13–15, 2027 · Mar 13 12:00 AM to Mar 16 12:00 AM (America/New_York)"
             )

      # Three periods, but only two distinct windows: the identical 09:00–10:00
      # clock on the two EDT days is one group, and the EST day stays its own
      # group because its offsets differ.
      assert has_element?(view, "#range-view")
      assert has_element?(view, "#range-view-grouped[aria-pressed='true']")
      assert has_element?(view, "#range-view-all[aria-pressed='false']")
      assert length(range_rows(html)) == 2

      assert row_attributes(html, "#range-periods-table tbody tr", "data-range-row") == [
               "group",
               "group"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-period-count") == [
               "1",
               "2"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-start-offset") == [
               "-18000",
               "-14400"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-service-date") == [
               "2027-03-13",
               "2027-03-14"
             ]

      # The one-day group says one day; the repeated group discloses both of its
      # dates, each with its own exact target.
      assert has_element?(view, "#range-group-0-date-label", "Sat, Mar 13")
      assert has_element?(view, "#range-group-1-date-label", "Mar 14–15, 2027")
      assert has_element?(view, "#range-group-1-dates[data-range-dates='2']")
      assert has_element?(view, "#range-date-1-2027-03-14-32400", "Sun, Mar 14")
      assert has_element?(view, "#range-date-1-2027-03-15-32400", "Mon, Mar 15")

      assert row_attributes(html, "#range-date-1-2027-03-14-32400", "data-show-date") == [
               "2027-03-14"
             ]

      assert row_attributes(html, "#range-date-1-2027-03-15-32400", "data-show-date") == [
               "2027-03-15"
             ]

      # List every period restores exactly the periods the API returned: three
      # rows, one per service date, in order.
      view |> element("#range-view-all") |> render_click()
      html = render(view)

      assert length(range_rows(html)) == 3

      assert row_attributes(html, "#range-periods-table tbody tr", "data-range-row") == [
               "period",
               "period",
               "period"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-service-date") == [
               "2027-03-13",
               "2027-03-14",
               "2027-03-15"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-target-time") == [
               "32400",
               "32400",
               "32400"
             ]

      # The two EDT days carry the same offset, and the EST day keeps its own,
      # in the every-period view exactly as in the grouped one.
      assert row_attributes(html, "#range-periods-table tbody tr", "data-start-offset") == [
               "-18000",
               "-14400",
               "-14400"
             ]

      # The switch is a control, not a new result: the grouped view is still one
      # click away and the summary is unchanged.
      assert has_element?(view, "#range-view-grouped[aria-pressed='false']")
      assert has_element?(view, "#range-result", "Service dates Mar 13–15, 2027")
    end

    test "keeps a different closure's identical window in its own period", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = range_station(organization, version)
      one_date_calendar(organization, version, "CAL_FRIDAY", ~D[2027-01-15])
      one_date_calendar(organization, version, "CAL_SATURDAY", ~D[2027-01-16])

      friday = lift_closure(organization, version, 32_400, 36_000, "CAL_FRIDAY")
      saturday = lift_closure(organization, version, 32_400, 36_000, "CAL_SATURDAY")

      conn = log_in_user(conn, user, organization: organization)
      view = open_access(conn, version, station, @friday)

      html = run_range(view, "2027-01-15", "2027-01-16")

      # The two periods share a clock window, offsets and lost pairs, but they
      # are caused by two different closures: grouping must not merge them into
      # one row that shows only one of the causes.
      refute has_element?(view, "#range-view")
      assert length(range_rows(html)) == 2

      assert row_attributes(html, "#range-periods-table tbody tr", "data-range-row") == [
               "period",
               "period"
             ]

      assert row_attributes(html, "#range-periods-table tbody tr", "data-service-date") == [
               "2027-01-15",
               "2027-01-16"
             ]

      assert has_element?(view, "#range-period-0-cause-#{friday.id}-2027-01-15")
      assert has_element?(view, "#range-period-1-cause-#{saturday.id}-2027-01-16")
    end

    test "names every occurrence of a repeated window and never implies the days between",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      %{station: station} = range_station(organization, version)

      # Mondays only, so the same window repeats on the 18th, the 25th and the
      # first of February, with the dates between them served by nothing.
      daily_calendar(organization, version, "CAL_MONDAY", %{
        monday: 1,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 0
      })

      lift_closure(organization, version, 32_400, 36_000, "CAL_MONDAY")

      conn = log_in_user(conn, user, organization: organization)
      view = open_access(conn, version, station, "2027-01-18")

      html = run_range(view, "2027-01-18", "2027-02-07")

      # A 21-day range, and its span ends at the Monday after the last date.
      assert has_element?(
               view,
               "#range-result",
               "Service dates Jan 18–Feb 7, 2027 · Jan 18 12:00 AM to Feb 8 12:00 AM (America/New_York)"
             )

      assert has_element?(view, "#range-view")
      assert length(range_rows(html)) == 1
      assert row_attributes(html, "#range-periods-table tbody tr", "data-period-count") == ["3"]

      # The group's own label names the span rather than every day of it, and
      # the disclosure carries every exact date.
      assert has_element?(view, "#range-group-0-date-label", "Between Jan 18–Feb 1, 2027")
      assert has_element?(view, "#range-group-0-dates[data-range-dates='3']")

      for {date, label} <- [
            {"2027-01-18", "Mon, Jan 18"},
            {"2027-01-25", "Mon, Jan 25"},
            {"2027-02-01", "Mon, Feb 1"}
          ] do
        assert has_element?(view, "#range-date-0-#{date}-32400", label)
      end

      # Each disclosed date names its own exact moment, so selecting one cannot
      # land between two occurrences.
      assert row_attributes(html, "#range-date-0-2027-01-25-32400", "data-show-date") == [
               "2027-01-25"
             ]

      assert row_attributes(html, "#range-date-0-2027-02-01-32400", "data-show-date") == [
               "2027-02-01"
             ]
    end
  end

  describe "refusals and limits" do
    setup :editor_setup

    test "a reversed or over-long span is inline invalid and keeps the earlier range", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = closed_station(organization, version, 32_400, 36_000)
      conn = log_in_user(conn, user, organization: organization)
      view = open_access(conn, version, station, @friday)

      run_range(view, "2027-01-15", "2027-01-15")

      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")
      refute has_element?(view, "#range-stale")

      # A last date before the first: the context refuses the span and the
      # message names the entry the reader can fix. The earlier range stays
      # visible under its own stale label and its original request heading.
      check_range(view, "2027-01-16", "2027-01-15")
      render_async(view, 5_000)

      assert has_element?(
               view,
               "#range-invalid",
               "Choose a last date on or after the first date."
             )

      assert has_element?(view, "#range-last[aria-invalid='true']")
      assert has_element?(view, "#range-first[aria-invalid='true']")
      assert has_element?(view, "#range-stale", "Results are from an earlier check")

      assert has_element?(
               view,
               "#range-stale-detail",
               "showing service dates Jan 15, 2027, checked "
             )

      assert has_element?(view, "#range-stale-detail", "the entered dates were not checked")
      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")
      assert has_element?(view, "#range-computed", "1 period with lost connections")

      # A span of 32 service days is the other refusal the context owns; both
      # values stay in the form and no result replaces the retained one.
      check_range(view, "2027-01-01", "2027-02-01")
      render_async(view, 5_000)

      assert has_element?(view, "#range-invalid", "Choose 31 days or fewer.")
      assert view |> element("#range-first") |> render() =~ "2027-01-01"
      assert view |> element("#range-last") |> render() =~ "2027-02-01"
      assert has_element?(view, "#range-stale")
      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")

      # The form recovers: a valid range replaces the refusal and the stale
      # label goes with it.
      run_range(view, "2027-01-15", "2027-01-16")

      refute has_element?(view, "#range-invalid")
      refute has_element?(view, "#range-stale")
      assert has_element?(view, "#range-result", "Service dates Jan 15–16, 2027")
    end

    test "an oversized range is a limit, never a no-loss result", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, lift: lift} = range_station(organization, version)
      daily_calendar(organization, version, "CAL_DAILY")
      lift_closure(organization, version, 32_400, 36_000)

      conn = log_in_user(conn, user, organization: organization)
      view = open_access(conn, version, station, @friday)

      run_range(view, "2027-01-15", "2027-01-15")

      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")

      # Four more closures whose window runs to the schema's own ceiling: their
      # candidate envelope reaches back 25,935 service dates, so the instance
      # count is 4 * 51,902 = 207,608 and the context refuses the check before
      # building a single instance. The window is a stored value the schema
      # allows, so this state is reachable through the ordinary form.
      wide_pathways =
        for index <- 1..4 do
          pathway_fixture(organization.id, version.id, lift.from_stop_id, lift.to_stop_id, %{
            pathway_id: "RANGE_WIDE_PW_#{index}",
            pathway_mode: 5,
            is_bidirectional: true
          })
        end

      calendar_fixture(organization.id, version.id, %{
        service_id: "CAL_WIDE",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 1,
        start_date: ~D[1900-01-01],
        end_date: ~D[2999-12-31]
      })

      for pathway <- wide_pathways do
        pathway_evolution_fixture(organization.id, version.id, %{
          pathway_id: pathway.pathway_id,
          service_id: "CAL_WIDE",
          start_time: 0,
          end_time: 2_147_483_647
        })
      end

      run_range(view, "2027-01-15", "2027-01-15")

      assert has_element?(view, "#range-too-large", "This range is too large to check")

      assert has_element?(
               view,
               "#range-too-large-detail",
               "It has more than 200,000 closure instances. Choose fewer days."
             )

      # A limit is never a result: the earlier range stays under its stale
      # label, and nothing claims the range has no loss.
      assert has_element?(view, "#range-stale", "Results are from an earlier check")
      assert has_element?(view, "#range-stale-detail", "stopped before it finished")
      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")
      assert has_element?(view, "#range-computed", "1 period with lost connections")
      refute has_element?(view, "#range-no-loss")
      refute has_element?(view, "#range-timeout")
      refute has_element?(view, "#range-error")
    end

    test "an incomplete station names its reasons and never reads as no loss", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      version = gtfs_version_fixture(organization.id)
      agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

      # A station with platforms and a pathway but no entrance at all: the
      # evaluation cannot answer the question a range asks.
      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "RANGE_NO_ENTRANCE",
          stop_name: "Entrance-less Station",
          location_type: 1
        })

      concourse =
        stop_fixture(organization.id, version.id, %{
          stop_id: "RANGE_NOE_CONCOURSE",
          stop_name: "Entrance-less concourse",
          location_type: 0,
          parent_station: station.stop_id
        })

      platform =
        stop_fixture(organization.id, version.id, %{
          stop_id: "RANGE_NOE_PLATFORM",
          stop_name: "Entrance-less platform",
          location_type: 0,
          parent_station: station.stop_id
        })

      pathway =
        pathway_fixture(organization.id, version.id, concourse.stop_id, platform.stop_id, %{
          pathway_id: "RANGE_NOE_PW",
          pathway_mode: 1,
          is_bidirectional: true
        })

      daily_calendar(organization, version, "CAL_DAILY")

      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: pathway.pathway_id,
        service_id: "CAL_DAILY",
        start_time: 32_400,
        end_time: 36_000
      })

      conn = log_in_user(conn, user, organization: organization)
      view = open_access(conn, version, %{station: station}, "2027-01-15")

      run_range(view, "2027-01-15", "2027-01-15")

      assert has_element?(view, "#range-incomplete", "Range check incomplete")
      assert has_element?(view, "#range-incomplete-reasons", "no entrance")

      # The report has no loss period - a station with no entrance has no pair
      # to lose - and the page must still not present that as an all-clear.
      refute has_element?(view, "#range-no-loss")
      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")
      assert has_element?(view, "#range-incomplete-floorplans", "Review pathways on Floorplans")
    end
  end

  describe "the deadline" do
    setup :editor_setup

    test "a stale deadline is ignored and a matching one times out with the earlier range kept",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      %{station: station} = range_station(organization, version)

      # Hundreds of independent closures, each on its own pathway, all serving
      # one date. Every boundary change is a different closed set, so the sweep
      # takes long enough for the running request's own deadline to be delivered
      # while it is still working.
      pathways =
        for index <- 1..@busy_closures do
          pathway_fixture(organization.id, version.id, "RANGE_ENTRANCE", "RANGE_PLATFORM", %{
            pathway_id: "RANGE_BUSY_PW_#{index}",
            pathway_mode: 1,
            is_bidirectional: true
          })
        end

      one_date_calendar(organization, version, "CAL_BUSY", ~D[2027-01-16])

      pathways
      |> Enum.with_index()
      |> Enum.each(fn {pathway, index} ->
        start_time = 79_200 + index * 40

        pathway_evolution_fixture(organization.id, version.id, %{
          pathway_id: pathway.pathway_id,
          service_id: "CAL_BUSY",
          start_time: start_time,
          end_time: start_time + 60
        })
      end)

      conn = log_in_user(conn, user, organization: organization)
      view = open_access(conn, version, station, @friday)

      # The ordinary Friday has no active closure, so the first range is a
      # complete answer with no loss.
      run_range(view, "2027-01-15", "2027-01-15")

      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")
      assert has_element?(view, "#range-no-loss", "No connection lost in this range")
      refute has_element?(view, "#range-stale")

      completed_scope = :sys.get_state(view.pid).socket.assigns.range_scope

      # The next range sweeps the busy date and is still running: the form has
      # been accepted, the earlier answer is retained under the stale label, and
      # no deadline has been delivered yet.
      check_range(view, "2027-01-16", "2027-01-16")

      assert :sys.get_state(view.pid).socket.assigns.range_status == :loading
      assert has_element?(view, "#range-stale", "Results are from an earlier check")
      assert has_element?(view, "#range-stale-detail", "checking service dates Jan 16, 2027")
      assert has_element?(view, "#range-stale-detail", "showing service dates Jan 15, 2027")
      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")
      refute has_element?(view, "#range-timeout")

      # A deadline that belongs to the range the reader already left matches no
      # pending request: it must change nothing. The request is still running
      # afterwards, which is what proves it was not cancelled.
      send(view.pid, {:range_deadline, completed_scope})
      render(view)

      assert :sys.get_state(view.pid).socket.assigns.range_status == :loading
      refute has_element?(view, "#range-timeout")
      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")
      assert has_element?(view, "#range-computed", "1 period with lost connections")

      # The deadline of the request this view is waiting for cancels it and says
      # so, while the last successful range stays on screen under its own
      # heading and the no-loss answer it carried.
      running_scope = :sys.get_state(view.pid).socket.assigns.range_scope
      send(view.pid, {:range_deadline, running_scope})
      render(view)

      assert has_element?(view, "#range-timeout", "The check took too long")

      assert has_element?(
               view,
               "#range-timeout-detail",
               "It stopped after 10 seconds. Choose fewer days, or check the range again."
             )

      assert has_element?(view, "#range-stale", "Results are from an earlier check")

      assert has_element?(
               view,
               "#range-stale-detail",
               "showing service dates Jan 15, 2027, checked "
             )

      assert has_element?(view, "#range-stale-detail", "stopped before it finished")
      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")
      assert has_element?(view, "#range-no-loss", "No connection lost in this range")
      refute has_element?(view, "#range-too-large")

      # The form keeps what the reader entered, and no inline refusal was added
      # by either deadline.
      assert view |> element("#range-first") |> render() =~ "2027-01-16"
      assert view |> element("#range-last") |> render() =~ "2027-01-16"
      refute has_element?(view, "#range-invalid")

      # The timeout is announced in the polite status region as well as being
      # rendered: a reader who cannot see the card still learns the check
      # stopped.
      assert has_element?(
               view,
               "#evolutions-status",
               "The range check took too long and stopped."
             )
    end
  end
end
