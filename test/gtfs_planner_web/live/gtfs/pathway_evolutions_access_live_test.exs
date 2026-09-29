defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsAccessLiveTest do
  @moduledoc """
  The moment access preview through its ordinary route: the switch into it from
  the closure list, the agency's default moment, the entrance/platform
  comparison it renders, the incomplete and unusable-zone states that must never
  read as an all-clear, and the stale/error lifecycle of its asynchronous check.

  Assertions are authored from AC-16 to AC-21, AC-36, AC-38 and AC-40, and the
  expected values are hand-derived literals: the named entrances, platforms,
  exact natural IDs, service times and UTC offsets below are written out from
  the fixture and from `America/New_York`, not read back out of the view.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.DisplayClock

  @station_stop %{
    stop_id: "ACCESS_STATION",
    stop_name: "Access Test Station",
    location_type: 1,
    parent_station: nil
  }

  # A slash and a space in the elevator's ID, so the row that names it and the
  # `?closure=` link that returns to it have to carry the exact value.
  @lift_pathway_id "ACCESS PW/LIFT 1"

  # 2027-01-15 is a Friday in winter: America/New_York is EST, so its service day
  # runs 05:00Z to 05:00Z and local noon is 17:00Z. 2027-01-19 is a Tuesday,
  # whose 01:00 local instant falls inside the Monday 22:00-26:00 instance.
  @friday ~D[2027-01-15]
  @tuesday ~D[2027-01-19]

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

  defp access_path(version, stop_id, date \\ nil, time \\ nil) do
    base = "/gtfs/#{version.id}/stops/#{stop_id}/evolutions/access"

    case {date, time} do
      {nil, nil} ->
        base

      {date, time} ->
        query = URI.encode_query([{"date", to_string(date)}, {"time", to_string(time)}])
        base <> "?#{query}"
    end
  end

  defp closures_path(version, stop_id) do
    "/gtfs/#{version.id}/stops/#{stop_id}/evolutions"
  end

  # A daily native calendar over the whole span the tests name, including the
  # agency's own today so a default moment is on a service date.
  defp daily_calendar(organization, version, service_id) do
    today = Date.utc_today()

    calendar_fixture(organization.id, version.id, %{
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
    })
  end

  # One station with two entrances, a mezzanine, a platform with a boarding
  # area, and three pathways between them: a walkway from the first entrance,
  # and a lift plus a staircase from the mezzanine to the platform. The first
  # entrance therefore reaches the platform for walking and step-free travel,
  # while the second entrance has no pathway at all, so its pair is a baseline
  # gap. The lift carries a punctuated natural ID and two closures: a daytime
  # window and an overnight one that runs into the next service day.
  defp access_station(organization, version) do
    station = stop_fixture(organization.id, version.id, @station_stop)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    entrance =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "ACCESS_ENTRANCE",
        stop_name: "North entrance",
        location_type: 2
      })

    lonely_entrance =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "ACCESS_LONELY_ENTRANCE",
        stop_name: "East entrance",
        location_type: 2
      })

    mezzanine =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "ACCESS_MEZZANINE",
        stop_name: "Mezzanine hall",
        location_type: 0
      })

    platform =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "ACCESS_PLATFORM",
        stop_name: "Platform 1",
        location_type: 0
      })

    _boarding =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "ACCESS_BOARDING",
        stop_name: "Platform 1 boarding area",
        location_type: 4
      })

    walkway =
      pathway_fixture(organization.id, version.id, entrance.stop_id, mezzanine.stop_id, %{
        pathway_id: "ACCESS PW/WALK 1",
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
        pathway_id: "ACCESS_PW_STAIR",
        pathway_mode: 2,
        is_bidirectional: true
      })

    daily_calendar(organization, version, "CAL_DAILY")

    daytime =
      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: lift.pathway_id,
        service_id: "CAL_DAILY",
        start_time: 32_400,
        end_time: 54_000
      })

    overnight =
      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: lift.pathway_id,
        service_id: "CAL_DAILY",
        start_time: 79_200,
        end_time: 93_600
      })

    %{
      station: station,
      entrance: entrance,
      lonely_entrance: lonely_entrance,
      mezzanine: mezzanine,
      platform: platform,
      walkway: walkway,
      lift: lift,
      stairs: stairs,
      daytime: daytime,
      overnight: overnight
    }
  end

  # A complete station under one station ID: one entrance, one open walkway, one
  # platform and one native calendar, with no agency and no closure of its own,
  # so a caller decides which zone (if any) its version has.
  defp plain_station(organization, version, stop_id, names) do
    station =
      stop_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: names.station,
        location_type: 1
      })

    entrance =
      child_stop_fixture(organization.id, version.id, stop_id, %{
        stop_id: stop_id <> "_ENTRANCE",
        stop_name: names.entrance,
        location_type: 2
      })

    platform =
      child_stop_fixture(organization.id, version.id, stop_id, %{
        stop_id: stop_id <> "_PLATFORM",
        stop_name: names.platform,
        location_type: 0
      })

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: stop_id <> "_PW",
      pathway_mode: 1,
      is_bidirectional: true
    })

    daily_calendar(organization, version, stop_id <> "_CAL")

    %{station: station, entrance: entrance, platform: platform}
  end

  # One version with exactly the agency rows a caller names: none, one unknown
  # name, or two that disagree.
  defp zone_version(organization, timezones, stop_id) do
    version = gtfs_version_fixture(organization.id)

    timezones
    |> Enum.with_index(1)
    |> Enum.each(fn {timezone, index} ->
      agency_fixture(organization.id, version.id, %{
        agency_id: "ZONE_#{index}",
        agency_name: "Zone #{index} Agency",
        agency_timezone: timezone
      })
    end)

    plain_station(organization, version, stop_id, %{
      station: "Zone Station",
      entrance: "Zone entrance",
      platform: "Zone platform"
    })

    version
  end

  # The state of one connection cell in the table row of one named entrance
  # under one named platform. The table's own data attributes are the contract
  # the browser assertions read, so the LiveView test reads the same ones.
  defp cell_states(html, platform_id, entrance_label, connection) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#findings-table tbody[data-platform-id='#{platform_id}'] tr")
    |> Enum.filter(&(LazyHTML.text(&1) =~ entrance_label))
    |> Enum.flat_map(&LazyHTML.query(&1, "td[data-connection='#{connection}']"))
    |> Enum.map(&LazyHTML.attribute(&1, "data-state"))
    |> List.flatten()
  end

  defp attribute(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.attribute(&1, name))
    |> List.flatten()
  end

  # The text one element carries in the render an event returned. A state the
  # view advances again as soon as its process is free — a loading label, a
  # retained result — is deterministic only in that render.
  defp rendered_text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end

  defp rendered?(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.any?()
  end

  # One range request through the access view's own form, submitted the way a
  # reader submits it rather than by calling an event handler directly.
  defp check_range(view, first, last) do
    view
    |> form("#range-form", %{"range" => %{"first_date" => first, "last_date" => last}})
    |> render_submit()
  end

  describe "the moment access route" do
    setup :editor_setup

    test "opens from the closure list's view switch and defaults to the agency today at noon", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = access_station(organization, version)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, closures_path(version, station.stop_id))

      assert has_element?(view, "#evolutions-view-nav")
      assert has_element?(view, "#evolutions-tab-closures[aria-current='page']")

      html = view |> element("#evolutions-tab-access") |> render_click()

      # The switch is a patch of one LiveView: the route changes and the station
      # stays mounted under the same station tab.
      assert_patch(view, access_path(version, station.stop_id))
      assert has_element?(view, "#evolutions-tab-access[aria-current='page']")
      assert has_element?(view, "#station-tab-evolutions[aria-current='page']")
      assert has_element?(view, "#preview-form")

      # The default moment is the agency's own today at noon, and the zone the
      # service times count from is named on the page.
      agency_today = DisplayClock.today(organization.id, version.id).date

      assert view |> element("#preview-date") |> render() =~ Date.to_iso8601(agency_today)
      assert view |> element("#preview-time") |> render() =~ "12:00:00"
      assert view |> element("#preview-zone") |> render() =~ "America/New_York"
      assert html =~ "Checking access at 12:00 on"

      # The check is announced while it runs and then rendered.
      html = render_async(view, 5_000)

      assert html =~ "Access at 12:00 on #{Calendar.strftime(agency_today, "%A, %B %-d, %Y")}"
      assert has_element?(view, "#preview-findings")
      refute has_element?(view, "#preview-skeleton")
    end

    test "an unparsable date or time is a form error instead of a crash", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = access_station(organization, version)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} =
        live(conn, access_path(version, station.stop_id) <> "?date=not-a-date&time=99:99")

      assert has_element?(view, "#preview-date-error", "Enter a service date like 2026-10-06.")

      assert has_element?(
               view,
               "#preview-time-error",
               "Enter a service time like 09:00 or 25:30."
             )

      assert has_element?(view, "#preview-date[aria-invalid='true']")
      assert has_element?(view, "#preview-time[aria-invalid='true']")

      # Nothing was asked of the context, so there is no result and no
      # in-progress state to mistake for one.
      refute has_element?(view, "#preview-findings")
      refute has_element?(view, "#preview-skeleton")
      assert has_element?(view, "#preview-form")

      # The same validation applies to a submitted form.
      html =
        view
        |> form("#preview-form", %{"preview" => %{"service_date" => "", "service_time" => "9 am"}})
        |> render_submit()

      assert html =~ "Enter a service time like 09:00 or 25:30."
    end
  end

  describe "the moment comparison" do
    setup :editor_setup

    test "shows Lost step-free and Available walking, and never blames a closure for a No route pair",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = access_station(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      html = render_async(view, 5_000)

      # Platform 1 is reached through the elevator and the staircase, so closing
      # the elevator for 09:00-15:00 loses the step-free connection in both
      # directions while the staircase keeps the walking connection.
      assert cell_states(html, "ACCESS_PLATFORM", "North entrance", "step_free_to_platform") ==
               ["lost"]

      assert cell_states(html, "ACCESS_PLATFORM", "North entrance", "step_free_to_exit") ==
               ["lost"]

      assert cell_states(html, "ACCESS_PLATFORM", "North entrance", "walking_to_platform") ==
               ["available"]

      assert cell_states(html, "ACCESS_PLATFORM", "North entrance", "walking_to_exit") ==
               ["available"]

      # The concourse is reached by its own walkway, so its pair is untouched by
      # the closure: a loss is reported for the pair that lost it, never for the
      # entrance or the station as a whole.
      for connection <- [
            "step_free_to_platform",
            "step_free_to_exit",
            "walking_to_platform",
            "walking_to_exit"
          ] do
        assert cell_states(html, "ACCESS_MEZZANINE", "North entrance", connection) == [
                 "available"
               ]
      end

      # The second entrance has no pathway at all: unreachable in the base
      # graph, so every cell of its pairs is a No route and none is lost.
      for platform_id <- ["ACCESS_MEZZANINE", "ACCESS_PLATFORM"],
          connection <- [
            "step_free_to_platform",
            "step_free_to_exit",
            "walking_to_platform",
            "walking_to_exit"
          ] do
        assert cell_states(html, platform_id, "East entrance", connection) == ["gap"]
      end

      assert has_element?(view, "#findings-gap-note")
      assert html =~ "Unreachable even without closures, so it is not counted as lost."
      refute has_element?(view, "#findings-incomplete-badge")
      refute has_element?(view, "#analysis-incomplete")

      # The heading names the step-free consequence, and the body separates the
      # contributing closure, what still works and the baseline gap.
      assert has_element?(
               view,
               "#preview-result-title",
               "No step-free route to or from Platform 1"
             )

      assert has_element?(
               view,
               "#preview-result-body",
               "Elevator · Mezzanine hall ↔ Platform 1 (ACCESS PW/LIFT 1) is closed 09:00–15:00."
             )

      assert has_element?(
               view,
               "#preview-result-body",
               "Walking connections to and from Platform 1 remain."
             )

      assert has_element?(
               view,
               "#preview-result-body",
               "East entrance has no step-free route to Platform 1 even without closures."
             )

      # The moment line carries the local clock time and the exact UTC offset of
      # a winter service date, and the computed-at line says when it ran.
      assert has_element?(
               view,
               "#preview-moment",
               "Friday, January 15, 2027 · 12:00 service time (12:00 PM)"
             )

      assert view |> element("#preview-computed") |> render() =~ "Calculated "

      # The verdict is a result card: the tone rides on a badge with words, the
      # pathway is named Mode · From ↔ To, and its ID is quiet mono text. The
      # agency zone and offset are secondary text after the moment.
      assert has_element?(view, "#preview-result [data-tone='error']", "Access interrupted")
      assert has_element?(view, "#preview-result-body .font-mono", @lift_pathway_id)
      assert has_element?(view, "#preview-moment .text-muted", "America/New_York · UTC-05:00")
      assert view |> element("#preview-zone") |> render() =~ "25:00 means 1 AM"
      assert has_element?(view, "#preview-zone .font-mono", "America/New_York")

      # A table stays quiet in its common case: Available is coloured text and
      # an icon, and only Lost takes a tinted badge. A pair with no route even
      # without closures is a muted consequence, not a second problem.
      doc = LazyHTML.from_fragment(html)
      lost = LazyHTML.query(doc, "#findings-table [data-connection-state='lost']")
      available = LazyHTML.query(doc, "#findings-table [data-connection-state='available']")
      gap = LazyHTML.query(doc, "#findings-table [data-connection-state='gap']")

      refute Enum.empty?(lost)
      assert Enum.all?(LazyHTML.attribute(lost, "data-tone"), &(&1 == "error"))
      assert LazyHTML.attribute(available, "data-tone") == []
      assert LazyHTML.attribute(gap, "data-tone") == []

      refute Enum.any?(LazyHTML.attribute(available, "class"), &(&1 =~ "bg-"))
      refute Enum.any?(LazyHTML.attribute(gap, "class"), &(&1 =~ "bg-"))
      refute has_element?(view, "#evolutions .rounded-full")

      # The coverage disclaimer never claims more than the evaluation does.
      assert has_element?(
               view,
               "#preview-coverage",
               "Directed paths and step-free connections at the selected moment."
             )

      assert has_element?(
               view,
               "#preview-coverage",
               "does not certify slopes, widths, or all wheelchair requirements."
             )

      # The cause list names the active closure by its exact natural ID and
      # window, and links back to the closure that carries it.
      assert has_element?(view, "#preview-causes", "Active closures during this loss")
      assert has_element?(view, "#preview-causes", "Elevator · Mezzanine hall ↔ Platform 1")
      assert has_element?(view, "#preview-causes", @lift_pathway_id)
      assert has_element?(view, "#preview-causes", "09:00–15:00")

      assert attribute(render(view), "#preview-cause-link-#{daytime.id}", "href") ==
               ["/gtfs/#{version.id}/stops/#{station.stop_id}/evolutions?closure=#{daytime.id}"]
    end

    test "an overnight window is active on the next civil day and keeps its earlier service date",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      %{station: station, overnight: overnight} = access_station(organization, version)
      conn = log_in_user(conn, user, organization: organization)

      # Tuesday 01:00 local is inside the Monday 22:00-26:00 instance, so the
      # lift is closed: step-free is lost and the staircase keeps walking.
      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @tuesday, "01:00:00"))
      html = render_async(view, 5_000)

      assert cell_states(html, "ACCESS_PLATFORM", "North entrance", "step_free_to_platform") ==
               ["lost"]

      assert cell_states(html, "ACCESS_PLATFORM", "North entrance", "step_free_to_exit") ==
               ["lost"]

      assert cell_states(html, "ACCESS_PLATFORM", "North entrance", "walking_to_platform") ==
               ["available"]

      assert has_element?(
               view,
               "#preview-result-title",
               "No step-free route to or from Platform 1"
             )

      # The instance is not dropped from the causes, and it keeps the service
      # date it started on rather than being restated as Tuesday's window.
      assert has_element?(view, "#preview-causes", @lift_pathway_id)

      assert has_element?(
               view,
               "#preview-causes",
               "from the Monday, January 18, 2027 service day"
             )

      assert has_element?(view, "#preview-causes", "until 2:00 AM Jan 19")

      assert attribute(render(view), "#preview-cause-link-#{overnight.id}", "href") ==
               ["/gtfs/#{version.id}/stops/#{station.stop_id}/evolutions?closure=#{overnight.id}"]
    end

    test "closing every mode reports the connections lost without a step-free claim", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, lift: lift, stairs: stairs} = access_station(organization, version)

      # A window over the staircase that matches the lift's: the only way from
      # the mezzanine to the platform is then closed for walking as well.
      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: stairs.pathway_id,
        service_id: "CAL_DAILY",
        start_time: 32_400,
        end_time: 54_000
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      html = render_async(view, 5_000)

      assert cell_states(html, "ACCESS_PLATFORM", "North entrance", "step_free_to_platform") ==
               ["lost"]

      assert cell_states(html, "ACCESS_PLATFORM", "North entrance", "walking_to_platform") ==
               ["lost"]

      assert has_element?(
               view,
               "#preview-result-title",
               "No step-free route to or from Platform 1"
             )

      # Both active closures are listed as contributing, and the body no longer
      # claims that any walking connection remains.
      assert has_element?(view, "#preview-causes", lift.pathway_id)
      assert has_element?(view, "#preview-causes", stairs.pathway_id)
      refute has_element?(view, "#preview-result-body", "remain.")
    end
  end

  describe "the moment form" do
    setup :editor_setup

    test "a submitted moment replaces the previous answer", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = access_station(organization, version)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      render_async(view, 5_000)

      assert has_element?(
               view,
               "#preview-result-title",
               "No step-free route to or from Platform 1"
             )

      # 16:00 is after the daytime window and before the overnight one, so the
      # same station has no loss at the new moment. The retained result is
      # labelled as an earlier check while the new one is calculated.
      html =
        view
        |> form("#preview-form", %{
          "preview" => %{"service_date" => "2027-01-15", "service_time" => "16:00"}
        })
        |> render_submit()

      assert rendered_text(html, "#analysis-stale") =~ "Results are from an earlier check"

      assert rendered_text(html, "#analysis-stale-detail") =~
               "showing 12:00 on Fri, Jan 15 while 16:00 on Fri, Jan 15 is calculated"

      assert rendered_text(html, "#preview-result-title") =~
               "No step-free route to or from Platform 1"

      html = render_async(view, 5_000)

      refute has_element?(view, "#analysis-stale")
      assert has_element?(view, "#preview-result-title", "No connection lost at this time")
      assert has_element?(view, "#preview-result-body", "No closure is active.")
      assert has_element?(view, "#preview-causes", "No closure is active at")
      assert has_element?(view, "#preview-moment", "16:00 service time (4:00 PM)")
      refute html =~ "No step-free route"

      # The form shows the moment the page now describes.
      assert view |> element("#preview-time") |> render() =~ "16:00:00"
    end
  end

  describe "the check lifecycle" do
    setup :editor_setup

    test "a failed check keeps the earlier answer under its stale label and offers a retry", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = access_station(organization, version)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      render_async(view, 5_000)

      assert has_element?(
               view,
               "#preview-result-title",
               "No step-free route to or from Platform 1"
             )

      # A service date outside PostgreSQL's own date range can only be reached
      # through a link, and the loader stops on it. The earlier answer stays on
      # screen and is labelled as the earlier check instead of being replaced by
      # a failure or by a result for the wrong moment.
      html = render_patch(view, access_path(version, station.stop_id, "-4714-12-31", "12:00:00"))

      assert has_element?(view, "#analysis-error", "The access check stopped before it finished")
      assert has_element?(view, "#analysis-error-detail", "Nothing was changed.")
      assert has_element?(view, "#analysis-retry", "Check again")
      assert has_element?(view, "#analysis-stale")
      assert html =~ "showing 12:00 on Fri, Jan 15"
      assert has_element?(view, "#analysis-stale", "stopped before it finished")

      assert has_element?(
               view,
               "#preview-result-title",
               "No step-free route to or from Platform 1"
             )

      # Retry re-runs the same moment: the failure clears while the check runs
      # and comes back, and the retained answer is still untouched. The loading
      # state belongs to the retry's own render.
      retry = view |> element("#analysis-retry") |> render_click()

      refute rendered?(retry, "#analysis-error")
      assert rendered_text(retry, "#analysis-stale") =~ "Results are from an earlier check"

      html = render_async(view, 5_000)

      assert has_element?(view, "#analysis-error", "The access check stopped before it finished")
      assert html =~ "Nothing was changed."

      assert has_element?(
               view,
               "#preview-result-title",
               "No step-free route to or from Platform 1"
             )

      # A valid moment recovers, and both failure labels go with it.
      render_patch(view, access_path(version, station.stop_id, @friday, "16:00:00"))
      render_async(view, 5_000)

      refute has_element?(view, "#analysis-error")
      refute has_element?(view, "#analysis-stale")
      assert has_element?(view, "#preview-result-title", "No connection lost at this time")
    end

    test "another station's request never shows the previous station's result", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = access_station(organization, version)

      other =
        plain_station(organization, version, "ACCESS_OTHER", %{
          station: "Other Test Station",
          entrance: "Other entrance",
          platform: "Other platform"
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      render_async(view, 5_000)

      assert has_element?(view, "#preview-findings", "Platform 1")

      # Patching to the other station clears the result rather than keeping it
      # under the new station's name, and the new check answers for that station.
      html = render_patch(view, access_path(version, other.station.stop_id, @friday, "12:00:00"))

      refute html =~ "Platform 1"
      refute has_element?(view, "#preview-result")
      assert has_element?(view, "#preview-skeleton")

      html = render_async(view, 5_000)

      assert has_element?(view, "#preview-result-title", "No connection lost at this time")
      assert has_element?(view, "#preview-findings", "Other platform")
      refute html =~ "Mezzanine hall"
    end

    test "a version switch answers in the new version instead of showing the old result", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = access_station(organization, version)

      other_version = gtfs_version_fixture(organization.id)
      agency_fixture(organization.id, other_version.id, %{agency_timezone: "America/New_York"})

      plain_station(organization, other_version, station.stop_id, %{
        station: "Access Test Station",
        entrance: "Later entrance",
        platform: "Later platform"
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      render_async(view, 5_000)

      assert has_element?(view, "#preview-findings", "North entrance")

      view |> render_click("gtfs_version_loaded", %{"version_id" => other_version.id})

      {to, _flash} = assert_redirect(view, 5_000)

      assert to == access_path(other_version, station.stop_id, @friday, "12:00:00")

      {:ok, other_view, _html} = live(conn, to)
      html = render_async(other_view, 5_000)

      # The new version's station has no closures at all: its own names are on
      # screen and nothing from the version the reader left survives.
      assert has_element?(other_view, "#preview-findings", "Later platform")
      assert has_element?(other_view, "#preview-result-title", "No connection lost at this time")
      refute html =~ "Mezzanine hall"
      refute html =~ @lift_pathway_id
    end
  end

  describe "an incomplete station" do
    setup :editor_setup

    test "names the missing data and never claims no connection was lost", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      # A station with platforms and a pathway but no entrance at all: the
      # evaluation cannot answer the question the page asks.
      station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ACCESS_NO_ENTRANCE",
          stop_name: "Entrance-less Station",
          location_type: 1
        })

      concourse =
        child_stop_fixture(organization.id, version.id, station.stop_id, %{
          stop_id: "ACCESS_NOE_CONCOURSE",
          stop_name: "Entrance-less concourse",
          location_type: 0
        })

      platform =
        child_stop_fixture(organization.id, version.id, station.stop_id, %{
          stop_id: "ACCESS_NOE_PLATFORM",
          stop_name: "Entrance-less platform",
          location_type: 0
        })

      pathway_fixture(organization.id, version.id, concourse.stop_id, platform.stop_id, %{
        pathway_id: "ACCESS_NOE_PW",
        pathway_mode: 1,
        is_bidirectional: true
      })

      agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      html = render_async(view, 5_000)

      assert has_element?(view, "#analysis-incomplete", "Access check incomplete")
      assert has_element?(view, "#incomplete-reasons", "no entrance")
      refute has_element?(view, "#incomplete-reasons", "location_type")
      assert has_element?(view, "#findings-incomplete-badge", "Incomplete")

      # No banner and no success claim; the pairs that could be computed are
      # still listed beside the reason.
      refute has_element?(view, "#preview-result")
      refute html =~ "No connection lost"
      assert has_element?(view, "#findings-empty")
      assert has_element?(view, "#incomplete-moment", "Friday, January 15, 2027")
      assert has_element?(view, "#incomplete-floorplans", "Review pathways on Floorplans")
    end

    test "names a pathway that leaves the station by its exact ID", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      outside_station =
        stop_fixture(organization.id, version.id, %{
          stop_id: "ACCESS_OUTSIDE_STATION",
          stop_name: "Outside Station",
          location_type: 1
        })

      # A complete, reachable station whose platform also connects to a stop
      # outside it: every pair can be computed, and the result is still not an
      # all-clear because one pathway is unaccounted for.
      %{station: station, platform: platform} =
        plain_station(organization, version, "ACCESS_BOUNDARY", %{
          station: "Boundary Station",
          entrance: "Boundary entrance",
          platform: "Boundary platform"
        })

      pathway_fixture(organization.id, version.id, platform.stop_id, outside_station.stop_id, %{
        pathway_id: "ACCESS_PW OUT/1",
        pathway_mode: 1,
        is_bidirectional: true
      })

      agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      render_async(view, 5_000)

      assert has_element?(view, "#analysis-incomplete", "Access check incomplete")
      assert has_element?(view, "#incomplete-reasons", "ACCESS_PW OUT/1")
      assert has_element?(view, "#incomplete-reasons", "connects to a stop outside this station")
      refute has_element?(view, "#preview-result")

      # The pair that can be computed is still shown.
      assert has_element?(view, "#findings-table", "Boundary entrance")
      assert has_element?(view, "#findings-table", "Boundary platform")
    end
  end

  describe "the agency zone" do
    setup :editor_setup

    test "a missing zone hides the calculation and still allows authoring", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      version = zone_version(organization, [], "ACCESS_NO_ZONE")
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, access_path(version, "ACCESS_NO_ZONE", @friday, "12:00:00"))

      assert has_element?(
               view,
               "#analysis-timezone-unavailable",
               "this version has no agency time zone"
             )

      assert has_element?(view, "#tz-reason", "No agency in this version has a time zone.")
      assert has_element?(view, "#tz-settings[href='/gtfs/#{version.id}/settings/agencies']")
      assert has_element?(view, "#tz-closures", "Schedule closures")

      # The calculation is gone rather than rendered as an empty or wrong
      # result, and no closure was read or written.
      refute has_element?(view, "#access-analysis")
      refute has_element?(view, "#preview-form")
      refute has_element?(view, "#preview-findings")
      refute has_element?(view, "#preview-result")

      # The switch still reaches the closure list, where authoring works
      # whatever the agency zone says.
      view |> element("#tz-closures") |> render_click()

      assert has_element?(view, "#closures-card")
      assert has_element?(view, "#closure-editor")
    end

    test "an unusable zone names its own reason", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      invalid = zone_version(organization, ["Mars/Olympus"], "ACCESS_INVALID_ZONE")

      conflicting =
        zone_version(organization, ["America/New_York", "America/Denver"], "ACCESS_MIXED")

      conn = log_in_user(conn, user, organization: organization)

      {:ok, invalid_view, _html} =
        live(conn, access_path(invalid, "ACCESS_INVALID_ZONE", @friday, "12:00:00"))

      assert has_element?(
               invalid_view,
               "#analysis-timezone-unavailable",
               "the agency time zone is not recognized"
             )

      {:ok, mixed_view, _html} =
        live(conn, access_path(conflicting, "ACCESS_MIXED", @friday, "12:00:00"))

      assert has_element?(
               mixed_view,
               "#analysis-timezone-unavailable",
               "the agencies use different time zones"
             )

      refute has_element?(mixed_view, "#preview-form")
      refute has_element?(invalid_view, "#preview-result")
    end

    test "a zone that becomes unusable answers with the refusal, not a wrong instant", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = access_station(organization, version)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      render_async(view, 5_000)

      # Another session gives the version a second agency that disagrees with the
      # first while this view is open: the next request is refused with its
      # reason rather than answered in the display clock's UTC fallback.
      for {agency_id, timezone} <- [{"MIX_A", "America/New_York"}, {"MIX_B", "America/Denver"}] do
        agency_fixture(organization.id, version.id, %{
          agency_id: agency_id,
          agency_name: "Mixed #{agency_id}",
          agency_timezone: timezone
        })
      end

      view
      |> form("#preview-form", %{
        "preview" => %{"service_date" => "2027-01-15", "service_time" => "13:00:00"}
      })
      |> render_submit()

      render_async(view, 5_000)

      assert has_element?(
               view,
               "#analysis-timezone-unavailable",
               "the agencies use different time zones"
             )

      refute has_element?(view, "#preview-form")
      refute has_element?(view, "#preview-result")
    end
  end

  describe "the range check and the moment preview" do
    setup :editor_setup

    test "a preview refresh neither replaces the range nor clears its stale label", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = access_station(organization, version)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, access_path(version, station.stop_id, @friday, "12:00:00"))
      render_async(view, 5_000)

      # The access view checks one service date by default. Two windows are
      # active on the Friday: the daytime elevator window and the overnight one
      # whose 22:00 start lands after midnight local, so the covered span reaches
      # 2:00 AM on Saturday.
      check_range(view, "2027-01-15", "2027-01-15")
      render_async(view, 5_000)

      assert has_element?(
               view,
               "#range-result",
               "Service dates Jan 15, 2027 · Jan 15 12:00 AM to Jan 16 2:00 AM (America/New_York)"
             )

      # Three periods: the daytime window, the overnight one, and the previous
      # service date's overnight instance whose 26:00 end spills past midnight
      # into the covered span.
      assert has_element?(view, "#range-computed", "3 periods with lost connections")
      refute has_element?(view, "#range-stale")

      # A range the context refuses leaves the retained range under its own
      # stale label.
      check_range(view, "2027-01-16", "2027-01-15")
      render_async(view, 5_000)

      assert has_element?(
               view,
               "#range-invalid",
               "Choose a last date on or after the first date."
             )

      assert has_element?(view, "#range-stale", "Results are from an earlier check")

      # Refreshing the moment is the preview's own request: it labels the
      # retained moment under `#analysis-stale` and must not touch the range's
      # label, its result or its refused entries.
      patched = render_patch(view, access_path(version, station.stop_id, @friday, "16:00:00"))

      assert rendered_text(patched, "#analysis-stale") =~ "Results are from an earlier check"
      assert has_element?(view, "#range-stale", "Results are from an earlier check")

      assert has_element?(
               view,
               "#range-stale-detail",
               "showing service dates Jan 15, 2027"
             )

      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")

      # The preview completes and its own stale label goes; the range's stays,
      # because no range request replaced it.
      render_async(view, 5_000)

      refute has_element?(view, "#analysis-stale")
      assert has_element?(view, "#range-stale", "Results are from an earlier check")
      assert has_element?(view, "#range-result", "Service dates Jan 15, 2027")

      # Both surfaces are still the same station's: the moment preview answers
      # for 16:00 while the range still names its own Jan 15 span.
      assert view |> element("#preview-time") |> render() =~ "16:00:00"
      assert has_element?(view, "#preview-result-title", "No connection lost at this time")
    end
  end

  describe "the route a cause link points at" do
    setup :editor_setup

    test "the closure row's Preview access impact link answers at the registered route", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, daytime: daytime} = access_station(organization, version)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, closures_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      # The link names the closure's own service time on the calendar's earliest
      # active date, at the access route.
      agency_today = DisplayClock.today(organization.id, version.id).date

      assert [href] = attribute(render(view), "#preview-closure-impact", "href")
      assert href =~ "/gtfs/#{version.id}/stops/#{station.stop_id}/evolutions/access?"
      assert href =~ "date=#{Date.to_iso8601(agency_today)}"
      assert href =~ "time=09%3A00%3A00"

      # Following it renders the moment preview for that closure, which is one of
      # the active causes there: a cause link and this link name one moment.
      {:ok, access_view, _html} =
        live(conn, access_path(version, station.stop_id, agency_today, "09:00:00"))

      render_async(access_view, 5_000)

      assert has_element?(access_view, "#preview-cause-#{daytime.id}")

      assert has_element?(
               access_view,
               "#preview-result-title",
               "No step-free route to or from Platform 1"
             )
    end
  end

  describe "the access route's own scope" do
    setup :editor_setup

    test "an unknown, foreign or non-station target exposes no result", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = access_station(organization, version)

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      plain_station(other_org, other_version, "FOREIGN_STATION", %{
        station: "Foreign",
        entrance: "Foreign entrance",
        platform: "Foreign platform"
      })

      conn = log_in_user(conn, user, organization: organization)

      for target <- [station.stop_id <> "_MISSING", "ACCESS_ENTRANCE", "FOREIGN_STATION"] do
        assert {:error, {:live_redirect, %{to: to, flash: %{"error" => "Station not found"}}}} =
                 live(conn, access_path(version, target, @friday, "12:00:00"))

        assert to == "/gtfs/#{version.id}/stops"
      end

      # A member without the editor role never reaches the page at all.
      member = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: member.id,
        organization_id: organization.id,
        roles: []
      })

      member_conn = log_in_user(conn, member, organization: organization)

      assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
               live(member_conn, access_path(version, station.stop_id, @friday, "12:00:00"))
    end
  end
end
