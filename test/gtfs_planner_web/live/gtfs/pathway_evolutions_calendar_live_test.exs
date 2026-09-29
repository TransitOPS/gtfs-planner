defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsCalendarLiveTest do
  @moduledoc """
  The read-only service dates of the Evolutions editor.

  A closure references a native calendar, and the editor has to show which days
  that calendar actually runs without becoming a second calendar editor. These
  cases drive the ordinary authenticated route: `#closure-dates-toggle` opens
  the disclosure, one month at a time is built by the shared
  `ServiceDates.month_grid/3`, the month buttons and the grid's own keyboard
  binding move the same state, and `#closure-calendar-link` carries the exact
  calendar address.

  Assertions are authored from AC-4 and AC-39 and compared with the native
  evaluator and the stored rows — counts, `updated_at` and the absence of a
  metadata anchor — rather than with the LiveView's own derivations. The cases
  write nothing: the seeded closures stay on their saved values.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar, as: GtfsCalendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Repo

  @weekly_service "CAL_WEEKLY"
  @dates_service "CAL_DATES"
  @dark_service "CAL_DARK"
  # A slash, a percent sign and spaces in one service ID: the link has to carry
  # all three exactly, and the calendar route has to resolve that one identity.
  @punctuated_service "svc 50% off/main"

  @station_stop %{
    stop_id: "CAL_DATES_STATION",
    stop_name: "Calendar Dates Station",
    location_type: 1,
    parent_station: nil
  }

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "UTC"})

    %{user: user, organization: organization, version: version}
  end

  defp postgres_local_today(timezone) do
    %{rows: [[%Date{} = date]]} = Repo.query!("SELECT (now() AT TIME ZONE $1)::date", [timezone])

    date
  end

  # The agency zone is pinned to UTC, so the calendar read's own today is this
  # date; the test computes its expectations from the same civil day.
  defp agency_today, do: postgres_local_today("Etc/UTC")

  defp first_of_month(%Date{year: year, month: month}), do: Date.new!(year, month, 1)

  # Test-local month arithmetic and title, so the expectation is not produced by
  # the same helper the view uses.
  defp shift_month(%Date{year: year, month: month}, offset) do
    total = year * 12 + (month - 1) + offset
    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end

  defp month_title(%Date{} = month), do: Calendar.strftime(month, "%B %Y")

  defp evolutions_path(version, stop_id) do
    "/gtfs/#{version.id}/stops/#{stop_id}/evolutions"
  end

  defp detail_path(version, service_id) do
    "/gtfs/#{version.id}/calendars/show?service_id=" <> URI.encode_www_form(service_id)
  end

  defp cell_aria_label(html, %Date{} = date) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#month-cell-#{Date.to_iso8601(date)}")
    |> LazyHTML.attribute("aria-label")
    |> List.first()
  end

  # One station with one walkway, so a closure can be scheduled at it.
  defp station_with_pathway(organization, version) do
    station = stop_fixture(organization.id, version.id, @station_stop)

    platform =
      child_stop_fixture(organization.id, version.id, station.stop_id, %{
        stop_id: "CAL_DATES_PLATFORM",
        stop_name: "Platform 1",
        location_type: 0
      })

    walkway =
      pathway_fixture(organization.id, version.id, station.stop_id, platform.stop_id, %{
        pathway_id: "PW-WALK",
        pathway_mode: 1,
        is_bidirectional: true
      })

    %{station: station, platform: platform, walkway: walkway}
  end

  # A weekly calendar that runs every day across a wide range, with one removed
  # service day and one stored addition on a day the weekly schedule already
  # serves, so both exception kinds are observable.
  defp weekly_calendar(organization, version) do
    today = agency_today()
    first = first_of_month(today)

    calendar_fixture(organization.id, version.id, %{
      service_id: @weekly_service,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 1,
      sunday: 1,
      start_date: Date.add(today, -400),
      end_date: Date.add(today, 400)
    })

    removed_date = Date.add(first, 9)
    redundant_added_date = Date.add(first, 19)

    calendar_date_fixture(organization.id, version.id, %{
      service_id: @weekly_service,
      date: removed_date,
      exception_type: 2
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: @weekly_service,
      date: redundant_added_date,
      exception_type: 1
    })

    %{removed_date: removed_date, redundant_added_date: redundant_added_date}
  end

  # A dates-only calendar: no weekly row at all, two added days in the current
  # month and one in the next, which only month navigation reveals.
  # Three stored dates around the agency's own month, anchored so the grid
  # always opens on that month: the agency's today is one of its added dates.
  defp dates_only_calendar(organization, version) do
    today = agency_today()
    month = first_of_month(today)
    added = if Date.compare(month, today) == :eq, do: Date.add(today, 1), else: month
    next_month = shift_month(month, 1)
    plain = Enum.find(Date.range(month, Date.end_of_month(month)), &(&1 != today and &1 != added))

    for date <- [today, added, next_month] do
      calendar_date_fixture(organization.id, version.id, %{
        service_id: @dates_service,
        date: date,
        exception_type: 1
      })
    end

    %{
      first_date: today,
      second_date: added,
      plain_date: plain,
      next_month_date: next_month
    }
  end

  # A native calendar with a weekly row but no expected service day, so it has
  # no active dates at all.
  defp dark_calendar(organization, version) do
    today = agency_today()

    calendar_fixture(organization.id, version.id, %{
      service_id: @dark_service,
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 0,
      start_date: Date.add(today, -30),
      end_date: Date.add(today, 30)
    })
  end

  defp closure_on(organization, version, attrs) do
    pathway_evolution_fixture(
      organization.id,
      version.id,
      Map.merge(%{pathway_id: "PW-WALK", start_time: 32_400, end_time: 54_000}, attrs)
    )
  end

  # The stored shape of the version's calendars: how many rows of each kind, and
  # the last write time of the calendar the editor is showing. Opening a
  # disclosure and paging months must not change any of them.
  defp calendar_state(organization, version, service_id) do
    %{
      calendars: scoped_count(GtfsCalendar, organization, version),
      dates: scoped_count(CalendarDate, organization, version),
      attributes: scoped_count(CalendarAttribute, organization, version),
      updated_at:
        Repo.one!(
          from(c in GtfsCalendar,
            where: c.organization_id == ^organization.id and c.gtfs_version_id == ^version.id,
            where: c.service_id == ^service_id,
            select: c.updated_at
          )
        )
    }
  end

  defp scoped_count(schema, organization, version) do
    Repo.aggregate(
      from(row in schema,
        where: row.organization_id == ^organization.id and row.gtfs_version_id == ^version.id
      ),
      :count
    )
  end

  defp open_editor_on(view, closure),
    do: view |> element("#closure-open-#{closure.id}") |> render_click()

  defp open_dates(view), do: view |> element("#closure-dates-toggle") |> render_click()

  describe "the read-only service dates" do
    setup :editor_setup

    test "shows the native month grid and matches the evaluator for every cell",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, walkway: walkway} = station_with_pathway(organization, version)

      %{removed_date: removed_date, redundant_added_date: redundant_added_date} =
        weekly_calendar(organization, version)

      closure = closure_on(organization, version, %{service_id: @weekly_service})

      before = calendar_state(organization, version, @weekly_service)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      open_editor_on(view, closure)

      # The disclosure is closed on a freshly opened row, and the toggle says so
      # in text and in `aria-expanded` rather than by color.
      assert has_element?(view, "#closure-dates-toggle[aria-expanded='false']")
      assert has_element?(view, "#closure-dates-toggle[aria-controls='closure-dates']")
      assert has_element?(view, "#closure-dates-toggle", "Show service dates")
      assert has_element?(view, "#closure-dates[hidden]")

      html = open_dates(view)

      assert has_element?(view, "#closure-dates-toggle[aria-expanded='true']")
      assert has_element?(view, "#closure-dates-toggle", "Hide service dates")
      refute has_element?(view, "#closure-dates[hidden]")

      today = agency_today()
      month = first_of_month(today)

      # The month opens on the calendar's earliest active day on or after today,
      # which the everyday weekly range makes today itself.
      assert has_element?(view, "#closure-dates-month", month_title(month))

      assert has_element?(
               view,
               "#closure-dates-prev[aria-label='Show #{month_title(shift_month(month, -1))}']"
             )

      assert has_element?(
               view,
               "#closure-dates-next[aria-label='Show #{month_title(shift_month(month, 1))}']"
             )

      # The exact cells the native evaluator derives, hand-checked against the
      # two stored exceptions: a removed weekday and a redundant addition.
      evaluator_grid =
        ServiceDates.month_grid(
          calendar_row!(organization, version),
          exceptions(organization, version, @weekly_service),
          month
        )

      assert cell_aria_label(html, removed_date) =~ "Service removed"
      assert cell_aria_label(html, redundant_added_date) =~ "Regular service"
      assert cell_aria_label(html, redundant_added_date) =~ "Service added recorded"

      plain_day = Date.add(month, 13)
      assert cell_aria_label(html, plain_day) =~ "Regular service"
      refute cell_aria_label(html, plain_day) =~ "recorded"

      state_words = %{
        service: "Regular service",
        removed: "Service removed",
        added: "Service added",
        none: "No service scheduled"
      }

      for week <- evaluator_grid.weeks, cell <- week, not is_nil(cell) do
        assert cell_aria_label(html, cell.date) =~ Map.fetch!(state_words, cell.state)
      end

      # Dates are read-only: no input, no select, and no event on any cell.
      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(LazyHTML.query(doc, "#closure-dates input"))
      assert Enum.empty?(LazyHTML.query(doc, "#closure-dates select"))
      assert Enum.empty?(LazyHTML.query(doc, "#closure-dates textarea"))
      assert Enum.empty?(LazyHTML.query(doc, "#closure-dates-months [phx-click]"))
      assert Enum.empty?(LazyHTML.query(doc, "#closure-dates-months [phx-value-date]"))

      # The buttons and the preview's own keyboard binding move the same month.
      assert render_click(view, "dates_step", %{"step" => "next"}) =~
               month_title(shift_month(month, 1))

      assert render_click(view, "dates_step", %{"step" => "prev"}) =~
               month_title(month)

      assert render_keydown(view, "preview_keys", %{"key" => "ArrowRight"}) =~
               month_title(shift_month(month, 1))

      assert render_keydown(view, "preview_keys", %{"key" => "ArrowLeft"}) =~
               month_title(month)

      assert render_keydown(view, "preview_keys", %{"key" => "Home"}) =~
               month_title(month)

      # The saved closure and every stored calendar row are untouched, and no
      # metadata anchor was created to show the dates.
      assert calendar_state(organization, version, @weekly_service) == before

      assert %{evolution: reloaded} =
               closure_row!(organization, version, station.stop_id, closure.id)

      assert reloaded.end_time == 54_000
      assert reloaded.pathway_id == walkway.pathway_id
    end

    test "a dates-only calendar shows its added days and pages into the next month",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_pathway(organization, version)

      %{
        first_date: first_date,
        second_date: second_date,
        plain_date: plain_date,
        next_month_date: next_month_date
      } = dates_only_calendar(organization, version)

      closure = closure_on(organization, version, %{service_id: @dates_service})

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      open_editor_on(view, closure)

      # The effective date summary comes from the read contract: the span and the
      # count of days this calendar actually runs.
      assert has_element?(view, "#closure-calendar-help", "3 service days")

      html = open_dates(view)

      assert cell_aria_label(html, first_date) =~ "Service added"
      assert cell_aria_label(html, second_date) =~ "Service added"
      assert cell_aria_label(html, plain_date) =~ "No service scheduled"
      refute html =~ "month-cell-#{Date.to_iso8601(next_month_date)}"

      # The box names the calendar the grid belongs to, and there is no
      # "no active dates" state for a calendar that has some.
      assert has_element?(
               view,
               "#closure-dates-months[aria-label='Read-only service dates for #{@dates_service}']"
             )

      refute has_element?(view, "#closure-dates-none")

      # The next month holds the third stored date.
      html = render_click(view, "dates_step", %{"step" => "next"})

      month = shift_month(first_of_month(agency_today()), 1)
      assert html =~ month_title(month)
      assert cell_aria_label(html, next_month_date) =~ "Service added"
      refute cell_aria_label(html, next_month_date) =~ "Service removed"
    end

    test "a calendar with no active service dates says so without a grid of guesses",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_pathway(organization, version)
      dark_calendar(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      # A new closure pointed at the dark calendar: the disclosure is available
      # as soon as a calendar is chosen, before anything is saved.
      view |> element("#new-closure") |> render_click()

      view
      |> form("#closure-form", %{
        "closure" => %{
          "pathway_id" => "PW-WALK",
          "service_id" => @dark_service,
          "start_time" => "",
          "end_time" => "",
          "note" => ""
        }
      })
      |> render_change()

      assert has_element?(view, "#closure-calendar-help", "No active service dates")

      open_dates(view)

      assert has_element?(
               view,
               "#closure-dates-none",
               "This calendar has no active service dates."
             )

      assert has_element?(
               view,
               "#closure-dates-month",
               month_title(first_of_month(agency_today()))
             )

      # The month the calendar could not name is the agency's own month, and the
      # grid still states the effective state of every day in it.
      assert render(view) =~ "No service scheduled"
    end

    test "paging and closing the dates keeps the entered closure values",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_pathway(organization, version)
      weekly_calendar(organization, version)
      closure = closure_on(organization, version, %{service_id: @weekly_service})

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      open_editor_on(view, closure)

      # Unsaved input in two fields, exactly what the guard protects.
      view
      |> form("#closure-form", %{
        "closure" => %{
          "pathway_id" => "PW-WALK",
          "service_id" => @weekly_service,
          "start_time" => "09:00",
          "end_time" => "16:00",
          "note" => "Contractor on site from 08:30."
        }
      })
      |> render_change()

      assert has_element?(view, "#closure-editor[data-dirty='true']")
      assert has_element?(view, "#closure-dirty-chip")

      month = first_of_month(agency_today())

      html = open_dates(view)
      assert html =~ month_title(month)

      html = render_click(view, "dates_step", %{"step" => "next"})
      assert html =~ month_title(shift_month(month, 1))

      html = render_click(view, "dates_step", %{"step" => "next"})
      assert html =~ month_title(shift_month(month, 2))

      # The disclosure's own state is separate from the form: every entered
      # string and the dirty marker survive the month change.
      assert has_element?(view, "#closure-start[value='09:00']")
      assert has_element?(view, "#closure-end[value='16:00']")
      assert html =~ "Contractor on site from 08:30."
      assert has_element?(view, "#closure-editor[data-dirty='true']")
      assert has_element?(view, "#closure-dirty-chip")

      # Closing the disclosure writes nothing and keeps the same entries.
      html = render_click(view, "toggle_dates", %{})

      assert has_element?(view, "#closure-dates-toggle[aria-expanded='false']")
      assert has_element?(view, "#closure-dates[hidden]")
      refute html =~ "month-cell-"
      assert has_element?(view, "#closure-end[value='16:00']")
      assert has_element?(view, "#closure-editor[data-dirty='true']")

      # Reopening reads the calendar again and still describes this closure's
      # calendar; the entered values are untouched.
      html = open_dates(view)

      assert has_element?(view, "#closure-dates-month", month_title(month))
      assert html =~ "Contractor on site from 08:30."
      assert has_element?(view, "#closure-end[value='16:00']")

      # Discarding restores the saved row and leaves the stored values alone.
      view |> element("#discard-closure") |> render_click()

      assert has_element?(view, "#closure-end[value='15:00']")
      assert has_element?(view, "#closure-dates-toggle[aria-expanded='false']")
      assert has_element?(view, "#closure-dates[hidden]")
    end

    test "Open calendar links exactly, and its departure obeys the dirty guard",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_pathway(organization, version)

      calendar_date_fixture(organization.id, version.id, %{
        service_id: @punctuated_service,
        date: Date.add(first_of_month(agency_today()), 4),
        exception_type: 1
      })

      closure = closure_on(organization, version, %{service_id: @punctuated_service})

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      open_editor_on(view, closure)

      expected = detail_path(version, @punctuated_service)

      # The exact address, with the slash, the percent sign and the spaces held
      # as one value rather than split into a path.
      assert expected =~ "service_id=svc+50%25+off%2Fmain"
      assert has_element?(view, "#closure-calendar-link[href='#{expected}']")

      doc = LazyHTML.from_fragment(render(view))
      assert Enum.count(LazyHTML.query(doc, "#closure-calendar-link")) == 1

      assert LazyHTML.attribute(LazyHTML.query(doc, "#closure-calendar-link"), "href") == [
               expected
             ]

      # Unsaved input is not dropped for it: the guard keeps the values and asks.
      view
      |> form("#closure-form", %{
        "closure" => %{
          "pathway_id" => "PW-WALK",
          "service_id" => @punctuated_service,
          "start_time" => "09:00",
          "end_time" => "16:00",
          "note" => ""
        }
      })
      |> render_change()

      asked = render_hook(view, "calendar_depart", %{"path" => expected})

      assert dialog_open?(asked, "closure-dirty-dialog")
      assert has_element?(view, "#closure-end[value='16:00']")
      assert has_element?(view, "#closure-calendar-link[href='#{expected}']")

      render_hook(view, "keep_editing", %{})
      assert has_element?(view, "#closure-end[value='16:00']")
      assert has_element?(view, "#closure-editor[data-dirty='true']")

      # Confirming runs the same exact calendar address.
      render_hook(view, "calendar_depart", %{"path" => expected})

      assert {:error, {:live_redirect, %{to: ^expected}}} =
               render_hook(view, "discard_edits", %{})

      # A clean inspector leaves for that same address without a question.
      {:ok, clean_view, _html} = live(conn, evolutions_path(version, station.stop_id))
      open_editor_on(clean_view, closure)

      assert {:error, {:live_redirect, %{to: ^expected}}} =
               render_hook(clean_view, "calendar_depart", %{"path" => expected})

      # The address is a real page: the calendar route resolves this exact
      # identity and renders it rather than a not-found state.
      {:ok, calendar_view, _html} = live(conn, expected)
      assert render(calendar_view) =~ @punctuated_service
    end

    test "a calendar that has left the version is reported, and saving refuses the reference",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_pathway(organization, version)
      weekly_calendar(organization, version)
      closure = closure_on(organization, version, %{service_id: @weekly_service})

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      open_editor_on(view, closure)

      # Another session removes the referenced calendar's native rows after this
      # page loaded. The form is still open on the exact stored service ID.
      delete_calendar_rows!(organization, version, @weekly_service)

      open_dates(view)

      assert has_element?(view, "#closure-dates-missing")
      refute has_element?(view, "#closure-dates-months")
      assert has_element?(view, "#closure-dates-toggle[aria-expanded='true']")

      # Nothing was written by the read, and the entered values are kept.
      assert scoped_count(CalendarAttribute, organization, version) == 0
      assert has_element?(view, "#closure-calendar")

      view
      |> form("#closure-form", %{
        "closure" => %{
          "pathway_id" => "PW-WALK",
          "service_id" => @weekly_service,
          "start_time" => "09:00",
          "end_time" => "16:00",
          "note" => ""
        }
      })
      |> render_submit()

      # The context rejects the reference on the service field itself, and the
      # editor keeps every entered string.
      assert has_element?(view, "#closure-errors")
      assert has_element?(view, "#closure-errors-list", "Calendar")
      assert has_element?(view, "#closure-errors-list", "has no calendar or calendar dates")

      assert has_element?(view, "#closure-end[value='16:00']")
      assert has_element?(view, "#closure-editor[data-dirty='true']")

      assert scoped_count(CalendarAttribute, organization, version) == 0

      assert %{evolution: reloaded} =
               closure_row!(organization, version, station.stop_id, closure.id)

      assert reloaded.end_time == 54_000
      assert pathway_closure_count(organization, version, station.stop_id, "PW-WALK") == 1
    end
  end

  ## Oracles and small helpers

  defp calendar_row!(organization, version) do
    Repo.one!(
      from(c in GtfsCalendar,
        where:
          c.organization_id == ^organization.id and c.gtfs_version_id == ^version.id and
            c.service_id == ^@weekly_service
      )
    )
  end

  defp exceptions(organization, version, service_id) do
    Repo.all(
      from(d in CalendarDate,
        where:
          d.organization_id == ^organization.id and d.gtfs_version_id == ^version.id and
            d.service_id == ^service_id,
        order_by: [asc: d.date, asc: d.exception_type]
      )
    )
  end

  defp closure_row!(organization, version, stop_id, closure_id) do
    {:ok, station_data} = Gtfs.station_closures(organization.id, version.id, stop_id)

    Enum.find(station_data.closures, &(&1.evolution.id == closure_id)) ||
      flunk("the closure left the station snapshot")
  end

  defp pathway_closure_count(organization, version, stop_id, pathway_id) do
    {:ok, station_data} = Gtfs.station_closures(organization.id, version.id, stop_id)

    Enum.count(station_data.closures, &(&1.evolution.pathway_id == pathway_id))
  end

  defp delete_calendar_rows!(organization, version, service_id) do
    Repo.delete_all(
      from(c in GtfsCalendar,
        where:
          c.organization_id == ^organization.id and c.gtfs_version_id == ^version.id and
            c.service_id == ^service_id
      )
    )

    Repo.delete_all(
      from(d in CalendarDate,
        where:
          d.organization_id == ^organization.id and d.gtfs_version_id == ^version.id and
            d.service_id == ^service_id
      )
    )
  end

  # A confirmation dialog is open when the server rendered it open; the native
  # `open` attribute is the client hook's business, so the test reads the state
  # the server owns.
  defp dialog_open?(html, id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{id}[data-open='true']")
    |> Enum.count() > 0
  end
end
