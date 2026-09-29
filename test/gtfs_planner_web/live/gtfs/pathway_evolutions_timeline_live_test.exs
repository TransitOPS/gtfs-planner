defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsTimelineLiveTest do
  @moduledoc """
  The service-time closure timeline of the access view, through its ordinary
  route: the instances of the selected service date, the spill-over an earlier
  or later service date contributes to the displayed span, and the four
  boundary actions that name an exact instant.

  Assertions are authored from AC-15, AC-24, AC-38 and AC-40. Every service
  time, service date, UTC offset and bar position below is a hand-derived
  literal from the fixture and from `America/New_York`; the timeline's own
  output is never read back as the expected value.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  @station_stop %{
    stop_id: "TIMELINE_STATION",
    stop_name: "Timeline Test Station",
    location_type: 1,
    parent_station: nil
  }

  # A slash and a space in the elevator's ID, so a boundary id and a data
  # attribute have to carry the exact value rather than a sanitized one.
  @lift_pathway_id "TIMELINE/PW LIFT 1"

  # 2027-01-19 is an ordinary winter Tuesday: America/New_York is EST, its
  # service day runs 05:00Z to 05:00Z, and local noon is 17:00Z. 2027-01-18 is
  # the Monday whose 22:00-26:00 window spills into it.
  @monday ~D[2027-01-18]
  @tuesday ~D[2027-01-19]

  # 2027-03-14 is the spring-forward Sunday: its origin is 2027-03-14T04:00:00Z,
  # so its 00:00:00 window opens at 04:00Z (23:00 EST on Saturday) and a minute
  # before it is expressed on Saturday's own service day.
  @sunday ~D[2027-03-14]
  @saturday ~D[2027-03-13]

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
    query = URI.encode_query([{"date", to_string(date)}, {"time", to_string(time)}])

    "/gtfs/#{version.id}/stops/#{stop_id}/evolutions/access?#{query}"
  end

  # A daily native calendar that covers the agency's own today (so a default
  # moment is on a service date) and the 2027 fixtures these cases name.
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

  # One station with an entrance, a mezzanine and a platform, a walkway and a
  # lift to reach the platform step-free, and a staircase that keeps walking
  # travel when the lift closes. The unit of comparison is the entrance ->
  # platform pair, so the lift's window alone decides whether step-free travel
  # is lost.
  defp timeline_station(organization, version) do
    station = stop_fixture(organization.id, version.id, @station_stop)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    entrance =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "TIMELINE_ENTRANCE",
        stop_name: "North entrance",
        location_type: 2
      })

    mezzanine =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "TIMELINE_MEZZANINE",
        stop_name: "Mezzanine hall",
        location_type: 0
      })

    platform =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "TIMELINE_PLATFORM",
        stop_name: "Platform 1",
        location_type: 0
      })

    pathway_fixture(organization.id, version.id, entrance.stop_id, mezzanine.stop_id, %{
      pathway_id: "TIMELINE_PW_WALK",
      pathway_mode: 1,
      is_bidirectional: true
    })

    lift =
      pathway_fixture(organization.id, version.id, mezzanine.stop_id, platform.stop_id, %{
        pathway_id: @lift_pathway_id,
        pathway_mode: 5,
        is_bidirectional: true
      })

    _stairs =
      pathway_fixture(organization.id, version.id, mezzanine.stop_id, platform.stop_id, %{
        pathway_id: "TIMELINE_PW_STAIR",
        pathway_mode: 2,
        is_bidirectional: true
      })

    %{station: station, entrance: entrance, mezzanine: mezzanine, platform: platform, lift: lift}
  end

  defp closure(organization, version, pathway_id, start_time, end_time) do
    pathway_evolution_fixture(organization.id, version.id, %{
      pathway_id: pathway_id,
      service_id: "CAL_DAILY",
      start_time: start_time,
      end_time: end_time
    })
  end

  # The rendered timeline at one moment, after the preview behind it completed.
  defp timeline(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {view, render_async(view, 5_000)}
  end

  defp attribute(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.attribute(&1, name))
    |> List.flatten()
  end

  # The words one element carries, collapsed to single spaces, so a template's
  # own line breaks and indentation cannot decide an assertion.
  defp label(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map_join(" ", &LazyHTML.text/1)
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp style(html, selector), do: attribute(html, selector, "style") |> List.first()

  defp boundary_id(closure_id, date, phase), do: "boundary-#{closure_id}-#{date}-#{phase}"

  defp row_id(closure_id, date), do: "#timeline-instance-#{closure_id}-#{date}"

  describe "the closure timeline" do
    setup :editor_setup

    test "draws the selected service date on a service-hour axis with its own four actions", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, lift: lift} = timeline_station(organization, version)
      daily_calendar(organization, version, "CAL_DAILY")
      daytime = closure(organization, version, lift.pathway_id, 32_400, 54_000)

      conn = log_in_user(conn, user, organization: organization)

      {view, html} = timeline(conn, access_path(version, station.stop_id, @tuesday, "12:00:00"))

      # One instance, on its own service date, on a 24-hour axis: the winter
      # Tuesday runs 05:00Z to 05:00Z and the window ends before midnight.
      assert has_element?(view, "#preview-timeline[data-axis-seconds='86400']")
      assert label(html, "#timeline-title") == "Closures on Tue, Jan 19"

      assert label(html, "#timeline-sub") ==
               "Service hours 00:00–24:00. Choose a boundary to preview that moment."

      assert label(html, "#timeline-cursor-label") == "Selected time · 12:00"
      assert style(html, "[data-timeline-cursor]") == "left: 50.000%"

      row = row_id(daytime.id, "2027-01-19")

      assert attribute(html, row, "data-service-date") == ["2027-01-19"]
      assert attribute(html, row, "data-start-time") == ["32400"]
      assert attribute(html, row, "data-end-time") == ["54000"]

      # The bar is drawn in service seconds from the selected date's origin:
      # 09:00 is 32400/86400 of the axis and 15:00 is 54000/86400 of it.
      assert style(html, "#{row} [data-timeline-closed]") == "left: 37.500%; width: 25.000%"

      # A row of the selected service date carries no spill label.
      assert attribute(html, "#{row} [data-spill]", "data-spill") == []

      # The four actions are the domain's own targets: start - 60 s, start,
      # midpoint and end, all inside the selected service date.
      assert attribute(html, "#{row} button", "id") == [
               boundary_id(daytime.id, "2027-01-19", "before"),
               boundary_id(daytime.id, "2027-01-19", "closes"),
               boundary_id(daytime.id, "2027-01-19", "during"),
               boundary_id(daytime.id, "2027-01-19", "reopens")
             ]

      assert attribute(html, "#{row} [data-boundary-phase]", "data-boundary-time") ==
               ["32340", "32400", "43200", "54000"]

      assert label(html, "##{boundary_id(daytime.id, "2027-01-19", "before")}") == "08:59 before"
      assert label(html, "##{boundary_id(daytime.id, "2027-01-19", "closes")}") == "09:00 closes"

      # The selected moment is the window's own midpoint, so that action is the
      # one marked current and the others are not.
      assert attribute(
               html,
               "##{boundary_id(daytime.id, "2027-01-19", "during")}",
               "aria-pressed"
             ) ==
               ["true"]

      assert attribute(
               html,
               "##{boundary_id(daytime.id, "2027-01-19", "closes")}",
               "aria-pressed"
             ) ==
               ["false"]

      assert label(html, "##{boundary_id(daytime.id, "2027-01-19", "reopens")}") ==
               "15:00 reopens"
    end

    test "keeps a previous service date's instance under its own service label", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, lift: lift} = timeline_station(organization, version)
      daily_calendar(organization, version, "CAL_DAILY")
      overnight = closure(organization, version, lift.pathway_id, 79_200, 93_600)

      conn = log_in_user(conn, user, organization: organization)

      {view, html} = timeline(conn, access_path(version, station.stop_id, @tuesday, "01:00:00"))

      # Tuesday's own window runs to 26:00, so the axis reaches past 24:00 and
      # the sub-line names where those hours land on the local clock: 24:00 is
      # 12:00 AM on Wednesday and 26:00 is 2:00 AM on Wednesday.
      assert has_element?(view, "#preview-timeline[data-axis-seconds='93600']")

      assert label(html, "#timeline-sub") ==
               "Service hours 00:00–26:00. 24:00–26:00 is 12:00 AM–2:00 AM on Wed, Jan 20. " <>
                 "Choose a boundary to preview that moment."

      # The Monday 22:00-26:00 instance is still running at Tuesday 01:00, so it
      # is a row of Tuesday's timeline, clipped to the part of the span it
      # covers and labelled with the service date it started on.
      spill = row_id(overnight.id, "2027-01-18")
      row = row_id(overnight.id, "2027-01-19")

      assert attribute(html, spill, "data-service-date") == ["2027-01-18"]
      assert attribute(html, spill, "data-from-seconds") == ["0"]
      assert attribute(html, spill, "data-to-seconds") == ["7200"]
      assert attribute(html, spill, "data-start-time") == ["79200"]
      assert attribute(html, spill, "data-end-time") == ["93600"]
      assert style(html, "#{spill} [data-timeline-closed]") == "left: 0.000%; width: 7.692%"
      assert attribute(html, "#{spill} [data-spill]", "data-spill") == ["2027-01-18"]
      assert label(html, spill) =~ "From Mon, Jan 18 service"
      assert label(html, spill) =~ "22:00–26:00"

      # Its drawn edge is the display span's start, not the instance's own
      # start, and its actions belong to the service date it started on.
      assert label(html, "#{spill}-actions") ==
               "Boundary actions are on the Mon, Jan 18 service date."

      # Tuesday's own instance keeps its whole window and the four actions the
      # domain derived for it.
      assert attribute(html, row, "data-from-seconds") == ["79200"]
      assert attribute(html, row, "data-to-seconds") == ["93600"]
      assert attribute(html, "#{row} [data-spill]", "data-spill") == []

      assert attribute(html, "#{row} button", "id") == [
               boundary_id(overnight.id, "2027-01-19", "before"),
               boundary_id(overnight.id, "2027-01-19", "closes"),
               boundary_id(overnight.id, "2027-01-19", "during"),
               boundary_id(overnight.id, "2027-01-19", "reopens")
             ]

      # The cursor is the selected moment, 01:00 of Tuesday's service day.
      assert label(html, "#timeline-cursor-label") == "Selected time · 01:00"
      assert style(html, "[data-timeline-cursor]") == "left: 3.846%"
    end

    test "a boundary action previews the exact instant it names, past 24:00", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, lift: lift} = timeline_station(organization, version)
      daily_calendar(organization, version, "CAL_DAILY")
      overnight = closure(organization, version, lift.pathway_id, 79_200, 93_600)

      conn = log_in_user(conn, user, organization: organization)

      {view, _html} = timeline(conn, access_path(version, station.stop_id, @tuesday, "12:00:00"))
      row = row_id(overnight.id, "2027-01-19")
      closes = "##{boundary_id(overnight.id, "2027-01-19", "closes")}"
      reopens = "##{boundary_id(overnight.id, "2027-01-19", "reopens")}"

      # 22:00 is the window's start: the lift is closed from that instant, so
      # the step-free connection is lost and the staircase keeps walking.
      view |> element(closes) |> render_click()

      assert_patch(view, access_path(version, station.stop_id, @tuesday, "22:00:00"))

      patched =
        render_patch(view, access_path(version, station.stop_id, @tuesday, "22:00:00"))

      # The earlier answer stays on screen under its stale label while the new
      # moment is calculated. That state belongs to the patch's own render: the
      # completion is free to arrive before any later render request.
      assert label(patched, "#analysis-stale") =~ "Results are from an earlier check"

      html = render_async(view, 5_000)

      assert has_element?(
               view,
               "#preview-result-title",
               "No step-free route to or from Platform 1"
             )

      assert label(html, "#preview-moment") =~
               "Tuesday, January 19, 2027 · 22:00 service time (10:00 PM)"

      assert attribute(html, closes, "aria-pressed") == ["true"]

      assert attribute(
               html,
               "##{boundary_id(overnight.id, "2027-01-19", "before")}",
               "aria-pressed"
             ) ==
               ["false"]

      # 26:00 is the window's own end in service time: the same instant as
      # 2:00 AM on Wednesday, and the lift is open again there.
      view |> element(reopens) |> render_click()

      assert_patch(view, access_path(version, station.stop_id, @tuesday, "26:00:00"))
      render_patch(view, access_path(version, station.stop_id, @tuesday, "26:00:00"))
      html = render_async(view, 5_000)

      assert has_element?(view, "#preview-result-title", "No connection lost at this time")

      assert label(html, "#preview-moment") =~
               "Tuesday, January 19, 2027 · 26:00 service time (2:00 AM Jan 20)"

      assert label(html, "#timeline-cursor-label") == "Selected time · 26:00"
      assert attribute(html, reopens, "aria-pressed") == ["true"]
      assert attribute(html, row, "data-from-seconds") == ["79200"]
    end

    test "a midnight start's before action names the preceding service date", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, lift: lift} = timeline_station(organization, version)
      daily_calendar(organization, version, "CAL_DAILY")
      midnight = closure(organization, version, lift.pathway_id, 0, 1_800)

      conn = log_in_user(conn, user, organization: organization)

      {view, html} = timeline(conn, access_path(version, station.stop_id, @tuesday, "12:00:00"))
      row = row_id(midnight.id, "2027-01-19")
      before = "##{boundary_id(midnight.id, "2027-01-18", "before")}"

      assert label(html, row) =~ "00:00–00:30"
      # One minute before a 00:00:00 start is 2027-01-19T04:59:00Z, which is
      # 23:59:00 of Monday's own service day. The action says both the weekday
      # and the time, and it carries the exact seconds it will patch.
      assert has_element?(view, before)
      assert attribute(html, before, "data-boundary-date") == ["2027-01-18"]
      assert attribute(html, before, "data-boundary-time") == ["86340"]
      assert label(html, before) == "Mon 23:59 before"

      view |> element(before) |> render_click()

      assert_patch(view, access_path(version, station.stop_id, @monday, "23:59:00"))
      render_patch(view, access_path(version, station.stop_id, @monday, "23:59:00"))
      html = render_async(view, 5_000)

      # The preview is the preceding service date's own 23:59, one minute
      # before the closure closes, so the lift is still open and the moment
      # line names the earlier date.
      assert label(html, "#preview-moment") =~
               "Monday, January 18, 2027 · 23:59 service time (11:59 PM)"

      assert has_element?(view, "#preview-result-title", "No connection lost at this time")
      assert label(html, "#timeline-title") == "Closures on Mon, Jan 18"
      assert has_element?(view, row_id(midnight.id, "2027-01-18"))
    end

    test "a spring-forward service date resolves its boundaries to their exact instants", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, lift: lift} = timeline_station(organization, version)
      daily_calendar(organization, version, "CAL_DAILY")
      midnight = closure(organization, version, lift.pathway_id, 0, 1_800)

      conn = log_in_user(conn, user, organization: organization)

      {view, html} = timeline(conn, access_path(version, station.stop_id, @sunday, "12:00:00"))
      before = "##{boundary_id(midnight.id, "2027-03-13", "before")}"

      # 2027-03-14's origin is 04:00Z, so one minute before its 00:00:00 window
      # is 03:59Z: 22:59 EST on 2027-03-13, the latest service day whose origin
      # is at or before that instant. The action keeps the exact seconds.
      assert has_element?(view, before)
      assert attribute(html, before, "data-boundary-date") == ["2027-03-13"]
      assert attribute(html, before, "data-boundary-time") == ["82740"]
      assert label(html, before) == "Sat 22:59 before"

      view |> element(before) |> render_click()

      assert_patch(view, access_path(version, station.stop_id, @saturday, "22:59:00"))
      render_patch(view, access_path(version, station.stop_id, @saturday, "22:59:00"))
      html = render_async(view, 5_000)

      # The patched moment is one minute before the closure opens, and its local
      # label is EST on Saturday: the instant 2027-03-14T03:59:00Z.
      assert label(html, "#preview-moment") =~
               "Saturday, March 13, 2027 · 22:59 service time (10:59 PM)"

      assert has_element?(view, "#preview-result-title", "No connection lost at this time")
    end

    test "a date whose only instances belong to another service date says so and draws no actions",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      %{station: station, lift: lift} = timeline_station(organization, version)

      # The calendar runs on Mondays only: Tuesday has no instance of its own,
      # while Monday's 22:00-26:00 window is still open at Tuesday 01:00.
      daily_calendar(organization, version, "CAL_DAILY", %{
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 0
      })

      overnight = closure(organization, version, lift.pathway_id, 79_200, 93_600)

      conn = log_in_user(conn, user, organization: organization)

      {view, html} = timeline(conn, access_path(version, station.stop_id, @tuesday, "01:00:00"))
      spill = row_id(overnight.id, "2027-01-18")

      assert has_element?(view, spill)
      refute has_element?(view, row_id(overnight.id, "2027-01-19"))
      refute has_element?(view, "#timeline-empty")

      # No instance of the selected service date means no boundary targets, and
      # the sub-line says why instead of offering actions that do not exist.
      refute has_element?(view, "#{spill} button")

      assert label(html, "#timeline-sub") ==
               "Service hours 00:00–24:00. No closure starts on this service date."
    end

    test "a service date with no closure at all renders the empty state", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station} = timeline_station(organization, version)
      daily_calendar(organization, version, "CAL_DAILY")

      conn = log_in_user(conn, user, organization: organization)

      {view, html} = timeline(conn, access_path(version, station.stop_id, @tuesday, "12:00:00"))

      assert has_element?(view, "#preview-timeline[data-axis-seconds='86400']")
      assert attribute(html, "#timeline-rows li", "id") == []

      assert label(html, "#timeline-empty") ==
               "No closure affects Tue, Jan 19. Choose another date to see its closures."

      assert label(html, "#timeline-sub") == "Service hours 00:00–24:00."
    end

    test "a boundary action that names no rendered boundary changes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{station: station, lift: lift} = timeline_station(organization, version)
      daily_calendar(organization, version, "CAL_DAILY")
      daytime = closure(organization, version, lift.pathway_id, 32_400, 54_000)

      conn = log_in_user(conn, user, organization: organization)

      {view, _html} = timeline(conn, access_path(version, station.stop_id, @tuesday, "12:00:00"))

      # A foreign closure, another service date and an unknown phase are each a
      # request for a boundary this preview does not carry.
      render_click(view, "preview_boundary", %{
        "evolution-id" => Ecto.UUID.generate(),
        "service-date" => "2027-01-19",
        "phase" => "closes"
      })

      render_click(view, "preview_boundary", %{
        "evolution-id" => daytime.id,
        "service-date" => "2027-01-18",
        "phase" => "closes"
      })

      render_click(view, "preview_boundary", %{
        "evolution-id" => daytime.id,
        "service-date" => "2027-01-19",
        "phase" => "halfway"
      })

      assert has_element?(view, "#preview-time[value='12:00:00']")
      refute has_element?(view, "#analysis-stale")
      assert has_element?(view, row_id(daytime.id, "2027-01-19"))
    end
  end
end
