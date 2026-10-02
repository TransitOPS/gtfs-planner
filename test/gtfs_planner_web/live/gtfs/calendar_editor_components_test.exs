defmodule GtfsPlannerWeb.Gtfs.CalendarEditorComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlannerWeb.Gtfs.CalendarEditorComponents, as: Editor

  @today ~D[2026-09-28]

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp weekly(days, first \\ ~D[2026-03-02], last \\ ~D[2026-03-31]) do
    flags =
      Map.new(
        ~w(monday tuesday wednesday thursday friday saturday sunday)a,
        &{&1, if(&1 in days, do: 1, else: 0)}
      )

    struct(Calendar, Map.merge(flags, %{service_id: "x", start_date: first, end_date: last}))
  end

  defp removal(date), do: %CalendarDate{service_id: "x", date: date, exception_type: 2}
  defp addition(date), do: %CalendarDate{service_id: "x", date: date, exception_type: 1}

  defp source(overrides) do
    Map.merge(
      %{
        warnings: [],
        usage: %{trip_count: 2, route_ids: ["1"], routes: [%{route_id: "1", trip_count: 2}]},
        active_dates: [@today],
        today: @today
      },
      Map.new(overrides)
    )
  end

  describe "date_span/2" do
    test "names one date once when both ends match" do
      assert Editor.date_span(~D[2026-11-26], ~D[2026-11-26]) == "Nov 26, 2026"
    end

    test "drops the repeated month and year inside one month" do
      assert Editor.date_span(~D[2027-03-08], ~D[2027-03-12]) == "Mar 8 – 12, 2027"
    end

    test "drops the repeated year across months" do
      assert Editor.date_span(~D[2026-09-05], ~D[2026-10-10]) == "Sep 5 – Oct 10, 2026"
    end

    test "names both years across a year boundary" do
      assert Editor.date_span(~D[2026-12-24], ~D[2027-01-01]) == "Dec 24, 2026 – Jan 1, 2027"
    end
  end

  describe "status/1" do
    test "reads Ended for a calendar whose last service day has passed, even with trips" do
      source = source(warnings: [%{reason: :ended, last_date: ~D[2026-09-01]}])

      assert Editor.status(source) == {:neutral, "Ended"}
    end

    test "reads Ends today on the last service day" do
      warning = %{reason: :ends_soon, last_date: @today, days_remaining: 0}

      assert Editor.status(source(warnings: [warning])) == {:warning, "Ends today"}
    end

    test "counts the days left when the calendar ends soon" do
      warning = %{reason: :ends_soon, last_date: ~D[2026-10-01], days_remaining: 3}

      assert Editor.status(source(warnings: [warning])) == {:warning, "Ends in 3 days"}
    end

    test "reads No service for a calendar with no service days" do
      assert Editor.status(source(warnings: [%{reason: :no_service}], active_dates: [])) ==
               {:warning, "No service"}
    end

    test "reads Not used by trips when no trip uses the calendar" do
      usage = %{trip_count: 0, route_ids: [], routes: []}

      assert Editor.status(source(usage: usage)) == {:neutral, "Not used by trips"}
    end

    test "reads Runs today for a used calendar that serves today" do
      assert Editor.status(source([])) == {:success, "Runs today"}
    end

    test "reads Scheduled for a used calendar that does not serve today" do
      assert Editor.status(source(active_dates: [~D[2026-10-05]])) == {:neutral, "Scheduled"}
    end
  end

  describe "lede/1" do
    test "names a Monday to Friday range and counts its service days" do
      source = %{
        kind: :weekly,
        calendar: weekly(~w(monday tuesday wednesday thursday friday)a),
        active_dates: [~D[2026-03-02], ~D[2026-03-03]]
      }

      assert Editor.lede(source) == "Runs Monday to Friday · Mar 2 – 31, 2026 · 2 service days"
    end

    test "names two adjacent days with and" do
      source = %{kind: :weekly, calendar: weekly(~w(saturday sunday)a), active_dates: []}

      assert Editor.lede(source) =~ "Runs Saturday and Sunday"
    end

    test "lists days that are not in a row" do
      source = %{
        kind: :weekly,
        calendar: weekly(~w(monday wednesday friday)a),
        active_dates: []
      }

      assert Editor.lede(source) =~ "Runs Monday, Wednesday and Friday"
    end

    test "says a single day runs alone" do
      source = %{kind: :weekly, calendar: weekly(~w(saturday)a), active_dates: []}

      assert Editor.lede(source) =~ "Runs Saturday only"
    end

    test "says every day when all seven run" do
      days = ~w(monday tuesday wednesday thursday friday saturday sunday)a
      source = %{kind: :weekly, calendar: weekly(days), active_dates: []}

      assert Editor.lede(source) =~ "Runs every day"
    end

    test "counts chosen dates and gives their span" do
      source = %{
        kind: :dates_only,
        calendar: nil,
        active_dates: [~D[2027-02-20], ~D[2027-02-28]]
      }

      assert Editor.lede(source) == "Runs only on chosen dates · 2 dates, Feb 20 – 28, 2027"
    end

    test "says no date has been added yet" do
      source = %{kind: :dates_only, calendar: nil, active_dates: []}

      assert Editor.lede(source) == "Runs only on chosen dates · none added yet"
    end
  end

  describe "usage_line/1" do
    test "says no trips use an unused calendar" do
      assert Editor.usage_line(%{trip_count: 0, routes: []}) == "No trips use this calendar yet"
    end

    test "agrees the verb with a single trip" do
      usage = %{trip_count: 1, routes: [%{route_id: "1", trip_count: 1}]}

      assert Editor.usage_line(usage) == "1 trip on 1 route uses this calendar"
    end

    test "counts routes and trips" do
      usage = %{
        trip_count: 5,
        routes: [%{route_id: "1", trip_count: 3}, %{route_id: "2", trip_count: 2}]
      }

      assert Editor.usage_line(usage) == "5 trips on 2 routes use this calendar"
    end
  end

  describe "warning_line/3" do
    test "asks a weekly calendar that ended to extend its end date" do
      line = Editor.warning_line(%{reason: :ended, last_date: ~D[2026-09-01]}, :weekly)

      assert line ==
               "This calendar ended on Sep 1, 2026, so its trips no longer run. Extend the end date to bring service back."
    end

    test "asks a chosen-dates calendar that ended to add dates" do
      line = Editor.warning_line(%{reason: :ended, last_date: ~D[2026-09-01]}, :dates_only)

      assert line =~ "Add service dates to bring it back."
    end

    test "says a calendar that ends today ends today" do
      warning = %{reason: :ends_soon, last_date: @today, days_remaining: 0}

      assert Editor.warning_line(warning, :weekly) =~ "Ends today, on Sep 28, 2026."
    end

    test "puts the range in a removal outside the regular dates when the caller knows it" do
      warning = %{reason: :outside_range, exception: :removed, date: ~D[2026-08-29]}

      assert Editor.warning_line(warning, :weekly, "Sep 5 – Oct 10, 2026") ==
               "Sat, Aug 29, 2026 is outside the regular dates (Sep 5 – Oct 10, 2026), so this day off changes nothing."
    end

    test "says an addition outside the regular dates runs because it is stored on its own" do
      warning = %{reason: :outside_range, exception: :added, date: ~D[2026-08-29]}

      assert Editor.warning_line(warning, :weekly) ==
               "Sat, Aug 29, 2026 is outside the regular dates. It runs only because it is stored as its own change."
    end

    test "says a redundant extra day changes nothing" do
      warning = %{reason: :redundant_addition, exception: :added, date: ~D[2026-09-12]}

      assert Editor.warning_line(warning, :weekly) =~ "already runs on the regular schedule"
    end
  end

  describe "actionable/1 and review_warnings/1" do
    test "leave a break's coverage gap out of the warnings a person acts on" do
      gap = %{reason: :coverage_gap, first_date: @today, last_date: @today, service_days: 3}
      ended = %{reason: :ended, last_date: @today}

      assert Editor.actionable([gap, ended]) == [ended]
    end

    test "keep only what a change would leave with no effect or outside the range" do
      no_service = %{reason: :no_service}
      ends_soon = %{reason: :ends_soon, last_date: @today, days_remaining: 3}

      assert Editor.review_warnings([ends_soon, no_service]) == [no_service]
    end
  end

  describe "weekday_toggles/1" do
    @options Enum.map(
               ~w(monday tuesday wednesday thursday friday saturday sunday),
               &{String.capitalize(&1), &1}
             )

    defp toggles(extra) do
      render_component(
        &Editor.weekday_toggles/1,
        Keyword.merge(
          [
            id: "calendar-weekdays",
            name: "calendar[weekdays][]",
            options: @options,
            selected: ["monday", "friday"],
            presets: [{"Weekdays", ~w(monday)}, {"Every day", ~w(monday)}]
          ],
          extra
        )
      )
    end

    test "submits each day under the weekdays list and checks the selected ones" do
      html = toggles([])

      assert Enum.count(
               LazyHTML.query(doc(html), "input[type=checkbox][name='calendar[weekdays][]']")
             ) ==
               7

      assert Enum.count(LazyHTML.query(doc(html), "#calendar-weekdays-monday[checked]")) == 1
      assert Enum.empty?(LazyHTML.query(doc(html), "#calendar-weekdays-tuesday[checked]"))
    end

    test "gives the assistive name of each day in full" do
      html = toggles([])

      assert doc(html)
             |> LazyHTML.query("label:has(#calendar-weekdays-monday) .sr-only")
             |> LazyHTML.text() ==
               "Monday"
    end

    test "offers quick sets with ids that carry no spaces" do
      html = toggles([])

      assert Enum.count(LazyHTML.query(doc(html), "#calendar-preset-weekdays")) == 1
      assert Enum.count(LazyHTML.query(doc(html), "#calendar-preset-every-day")) == 1
    end

    test "marks the group invalid and ties the error to it" do
      html = toggles(error: "Choose at least one service day.")
      group = LazyHTML.query(doc(html), "#calendar-weekdays")

      assert LazyHTML.attribute(group, "aria-invalid") == ["true"]
      assert LazyHTML.attribute(group, "aria-describedby") == ["calendar-weekdays-error"]

      assert doc(html) |> LazyHTML.query("#calendar-weekdays-error") |> LazyHTML.text() =~
               "Choose at least one service day."
    end
  end

  describe "preview_card/1" do
    defp preview(kind, calendar, exceptions) do
      render_component(&Editor.preview_card/1,
        month_grid: ServiceDates.month_grid(calendar, exceptions, ~D[2026-03-01]),
        kind: kind,
        dirty?: false,
        today: ~D[2026-03-04]
      )
    end

    test "labels each cell with its weekday, date and state" do
      html = preview("weekly", weekly(~w(monday)a), [removal(~D[2026-03-09])])

      cell = LazyHTML.query(doc(html), "#month-cell-2026-03-09")

      assert LazyHTML.attribute(cell, "aria-label") == ["Mon, Mar 9, 2026: Day off, no service"]
    end

    test "marks today in its label" do
      html = preview("weekly", weekly(~w(wednesday)a), [])

      cell = LazyHTML.query(doc(html), "#month-cell-2026-03-04")

      assert LazyHTML.attribute(cell, "aria-label") == ["Wed, Mar 4, 2026: Runs, today"]
    end

    test "reads an added date on a weekly calendar as extra service" do
      html = preview("weekly", weekly(~w(monday)a), [addition(~D[2026-03-14])])

      cell = LazyHTML.query(doc(html), "#month-cell-2026-03-14")

      assert LazyHTML.attribute(cell, "aria-label") == ["Sat, Mar 14, 2026: Extra service"]
    end

    test "reads an added date on a chosen-dates calendar as a day it runs" do
      html = preview("dates_only", nil, [addition(~D[2026-03-14])])

      cell = LazyHTML.query(doc(html), "#month-cell-2026-03-14")

      assert LazyHTML.attribute(cell, "aria-label") == ["Sat, Mar 14, 2026: Runs"]
    end

    test "leaves the day-off and extra-service keys out of a chosen-dates legend" do
      legend = preview("dates_only", nil, []) |> doc() |> LazyHTML.query("#months-legend")

      refute LazyHTML.text(legend) =~ "Day off"
      refute LazyHTML.text(legend) =~ "Extra service"
    end
  end

  describe "change_list/1" do
    defp changes(kind, calendar, exceptions) do
      render_component(&Editor.change_list/1,
        kind: kind,
        calendar: calendar,
        periods: ServiceDates.periods(calendar, exceptions),
        exceptions: exceptions,
        warnings: ServiceDates.warnings(calendar, exceptions, @today)
      )
    end

    test "says what a calendar with no changes runs" do
      html = changes(:weekly, weekly(~w(monday)a), [])

      assert doc(html) |> LazyHTML.query("#calendar-changes-empty") |> LazyHTML.text() =~
               "No days off or extra service yet"
    end

    test "shows a break once with its dates one disclosure away, and its single days apart" do
      exceptions = [
        removal(~D[2026-03-09]),
        removal(~D[2026-03-10]),
        removal(~D[2026-03-11]),
        removal(~D[2026-03-23])
      ]

      html = changes(:weekly, weekly(~w(monday tuesday wednesday)a), exceptions)
      page = doc(html)

      assert Enum.count(LazyHTML.query(page, "#calendar-break-2026-03-09")) == 1
      assert Enum.count(LazyHTML.query(page, "#calendar-break-2026-03-09 details li")) == 3
      assert Enum.count(LazyHTML.query(page, "tr#calendar-exception-chips-2026-03-23")) == 1
      assert Enum.empty?(LazyHTML.query(page, "tr#calendar-exception-chips-2026-03-10"))

      assert LazyHTML.text(LazyHTML.query(page, "#calendar-changes-summary")) =~
               "1 day off · 1 break · 0 extra service days"
    end

    test "restores a whole break through its stored dates" do
      exceptions = [
        removal(~D[2026-03-09]),
        removal(~D[2026-03-10]),
        removal(~D[2026-03-11])
      ]

      html = changes(:weekly, weekly(~w(monday tuesday wednesday)a), exceptions)

      button = LazyHTML.query(doc(html), "#periods-remove-break-break-2026-03-09")

      assert LazyHTML.attribute(button, "phx-click") == ["remove_break"]
      assert LazyHTML.attribute(button, "phx-value-dates") == ["2026-03-09,2026-03-10,2026-03-11"]
    end

    test "says a redundant extra day has no effect on its own row" do
      html = changes(:weekly, weekly(~w(monday)a), [addition(~D[2026-03-09])])

      row = LazyHTML.query(doc(html), "#calendar-exception-chips-2026-03-09")

      assert LazyHTML.text(row) =~ "No effect: this day already runs on the regular schedule."
    end

    test "offers Remove date, not Restore service, on a chosen-dates calendar" do
      html = changes(:dates_only, nil, [addition(~D[2026-03-09])])

      button = LazyHTML.query(doc(html), "#calendar-exception-chips-remove-2026-03-09")

      assert LazyHTML.text(button) =~ "Remove date"
      assert LazyHTML.attribute(button, "phx-click") == ["remove_date"]
    end
  end

  describe "service_strip/1" do
    defp strip(calendar, exceptions, today \\ @today) do
      render_component(&Editor.service_strip/1,
        kind: if(calendar, do: :weekly, else: :dates_only),
        calendar: calendar,
        periods: ServiceDates.periods(calendar, exceptions),
        active_dates: ServiceDates.active_dates(calendar, exceptions),
        today: today,
        list_path: "/gtfs/v1/calendars"
      )
    end

    test "draws periods and breaks in date order and describes the whole schedule" do
      exceptions = [
        removal(~D[2026-03-04]),
        removal(~D[2026-03-05]),
        removal(~D[2026-03-06])
      ]

      html =
        strip(weekly(~w(monday tuesday wednesday thursday friday)a), exceptions, ~D[2026-03-20])

      page = doc(html)

      ids = page |> LazyHTML.query("[id^=periods-segment-]") |> LazyHTML.attribute("id")

      assert ids == [
               "periods-segment-period-2026-03-02",
               "periods-segment-break-2026-03-04",
               "periods-segment-period-2026-03-07"
             ]

      label = page |> LazyHTML.query("#periods-timeline") |> LazyHTML.attribute("aria-label")

      assert label == [
               "Service from Mar 2, 2026 to Mar 31, 2026: 2 periods, 1 break, 0 days off, 0 extra service days."
             ]
    end

    test "states each break's coverage gap under the strip instead of as a warning" do
      exceptions = [
        removal(~D[2026-03-04]),
        removal(~D[2026-03-05]),
        removal(~D[2026-03-06])
      ]

      html = strip(weekly(~w(monday tuesday wednesday thursday friday)a), exceptions)

      assert doc(html) |> LazyHTML.query("#periods-gaps") |> LazyHTML.text() =~
               "No service Mar 4 – 6, 2026 (3 service days)."
    end

    test "draws nothing for a chosen-dates calendar with no dates" do
      assert strip(nil, []) |> doc() |> LazyHTML.query("#periods-timeline") |> Enum.count() == 0
    end

    test "draws each chosen date on a chosen-dates strip" do
      html = strip(nil, [addition(~D[2026-03-14]), addition(~D[2026-03-15])])

      ids = doc(html) |> LazyHTML.query("[id^=periods-segment-]") |> LazyHTML.attribute("id")

      assert ids == ["periods-segment-date-2026-03-14", "periods-segment-date-2026-03-15"]
    end
  end
end
