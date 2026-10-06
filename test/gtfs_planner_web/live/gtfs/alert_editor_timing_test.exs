defmodule GtfsPlannerWeb.Gtfs.AlertEditorTimingTest do
  @moduledoc """
  Step 19: the timing answers save exactly what the preview shows (AC-20, CL-20).

  Every expectation is a literal from the specification's own rules - the R12
  example (Mon-Fri, 20:00 to 05:00, two weeks from Monday 5 October 2026, except
  Friday 9 October, yields nine occurrences), the `Completion` messages the
  editor refuses with, or a date and time named here - and never a value
  recomputed by the module under test. The only derived value is the notice
  default, which this file computes from the same rule the editor states: the
  later of today and seven days before the first date.

  The ids are the ones the templates give each control, and the agency zone is
  fixed in the fixture, so nothing here depends on the day the suite runs.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Gtfs.AuditContext

  # The specification's own recurrence example (R12, AC-20): weekly, first date
  # Monday 5 October 2026, two weeks, Monday to Friday, from 20:00 until 05:00,
  # except Friday 9 October.
  @first_date ~D[2026-10-05]
  @friday ~D[2026-10-09]
  # A Saturday inside the two weeks but outside the Monday-to-Friday pattern, so
  # naming it adds a date rather than removing one.
  @added_saturday ~D[2026-10-10]
  @night_start ~T[20:00:00]
  @night_end ~T[05:00:00]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "Route 1",
        route_long_name: "Coast Highway",
        route_type: 3
      })

    %{
      organization: organization,
      version: version,
      actor: actor,
      route: route,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "a current alert's end" do
    setup :editor_conn

    test "an estimated end asks for a check-in, not an end date", context do
      alert = now_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      assert has_element?(view, "#alert-question-title", "When should this alert end?")

      view
      |> element("#alert-timing-end-kind-estimated")
      |> render_click()

      # An estimate keeps the alert live, so it asks when staff check back and
      # never for a date it would expire on (AC-20).
      assert has_element?(view, "#timing-check-in")
      refute has_element?(view, "#timing-end-date")
      assert has_element?(view, "#alert-timing-end-kind-estimated[aria-pressed='true']")

      # Nothing else is answered yet, so Continue refuses with the sentence the
      # completion check owns.
      view |> element("#alert-timing-continue") |> render_click()

      assert has_element?(view, "#alert-timing-error", "Choose the date this started.")

      # A check-in is stored as the civil time it falls on, in the agency's own
      # clock, sixty minutes from the moment the editor chose it (CR-7). The
      # stored value is truncated to the second, so it is at least 3 599 s after
      # a clock read taken before the event.
      before_write = Alerts.agency_now(context.audit)

      render_change(view, "autosave", %{
        "check_in_offset" => "60",
        "alert" => %{"timing" => %{"start_date" => "2026-10-01", "start_time" => "08:00"}}
      })

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert NaiveDateTime.diff(saved.timing.check_in_at, before_write) >= 3_599
      assert saved.timing.start_date == ~D[2026-10-01]
      assert saved.timing.start_time == ~T[08:00:00]

      view |> element("#alert-timing-continue") |> render_click()

      assert has_element?(view, "#alert-question-title", "Why is this happening?")
    end

    test "a confirmed end asks for the date and the time", context do
      alert = now_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-end-kind-confirmed") |> render_click()

      assert has_element?(view, "#timing-end-date")
      assert has_element?(view, "#timing-end-time")
      refute has_element?(view, "#timing-check-in")

      render_change(view, "autosave", %{"alert" => %{"timing" => %{"end_time" => "17:30"}}})

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.timing.end_kind == :confirmed
      assert saved.timing.end_time == ~T[17:30:00]
    end

    test "a stored check-in is shown as the selected option", context do
      alert = now_alert(context)

      assert {:ok, _saved} =
               Alerts.save_draft(context.audit, alert.id, alert.revision, %{
                 "timing" => %{
                   "end_kind" => "estimated",
                   "check_in_at" => "2000-01-01T16:30:00"
                 }
               })

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      # The stored time never equals one of the offsets, which are measured from
      # a clock that moves on, so it is its own option and the selected one.
      assert has_element?(
               view,
               "#timing-check-in option[selected]",
               "Check back Jan 1, 4:30 PM"
             )

      assert has_element?(view, "#timing-check-in option", "In 30 minutes")
    end

    test "an end kind this question does not offer stores nothing", context do
      alert = now_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> render_click("choose_end_kind", %{"end_kind" => "whenever"})

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert is_nil(unchanged.timing.end_kind)
      assert unchanged.revision == alert.revision
    end
  end

  describe "a planned alert's recurrence" do
    setup :editor_conn

    test "the weekly pattern previews every occurrence the answer expands to", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      assert has_element?(view, "#alert-question-title", "When will service change?")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      choose_weekdays(view, 1..5)
      put_timing(view, %{"first_date" => Date.to_iso8601(@first_date), "weeks" => "2"})
      put_timing(view, %{"start_time" => "20:00", "end_time" => "05:00"})

      # Until is at or before From, so the period ends the following morning and
      # the card says so in words rather than in colour (R12, AC-20).
      assert has_element?(view, "#alert-timing-overnight", "Ends the following day.")
      assert has_element?(view, "#alert-timing-count", "10 days: Oct 5 to Oct 16")

      # Monday to Friday over two weeks: 5 to 9 October and 12 to 16 October.
      for day <- [0, 1, 2, 3, 4, 7, 8, 9, 10, 11] do
        date = Date.add(@first_date, day)

        assert has_element?(
                 view,
                 "#alert-timing-occurrence-#{Date.to_iso8601(date)}"
               )
      end

      refute has_element?(
               view,
               "#alert-timing-occurrence-#{Date.to_iso8601(@added_saturday)}"
             )

      # The preview names the window each night covers, including that it ends
      # the next morning.
      assert has_element?(
               view,
               "#alert-timing-occurrence-2026-10-05",
               "Monday, October 5"
             )

      assert render(view) =~ "8:00 PM to 5:00 AM (next day)"
    end

    test "a Once period reads as one period from its first date to its last", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-continuous") |> render_click()

      put_timing(view, %{
        "first_date" => "2026-10-05",
        "last_date" => "2026-10-07",
        "start_time" => "08:00",
        "end_time" => "18:00"
      })

      # Three days of one period, and both ends are named: the preview never
      # reports a three-day answer as one day (AC-20).
      assert has_element?(view, "#alert-timing-count", "3 days: Oct 5 to Oct 7")

      assert has_element?(
               view,
               "#alert-timing-occurrence-2026-10-05",
               "Monday, October 5 to Wednesday, October 7"
             )

      assert has_element?(
               view,
               "#alert-timing-occurrence-2026-10-05",
               "8:00 AM to 6:00 PM"
             )

      refute render(view) =~ "(next day)"
    end

    test "a Once period on one date reads as one day", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-continuous") |> render_click()

      put_timing(view, %{
        "first_date" => "2026-10-05",
        "last_date" => "2026-10-05",
        "start_time" => "08:00",
        "end_time" => "18:00"
      })

      assert has_element?(view, "#alert-timing-count", "1 day: Oct 5")
      refute has_element?(view, "#alert-timing-count", "1 days")
    end

    test "a Once period that ends before it starts says so", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-continuous") |> render_click()
      put_timing(view, %{"first_date" => "2026-10-09", "last_date" => "2026-10-05"})

      assert has_element?(
               view,
               "#alert-timing-error",
               "Choose an end date after the start date."
             )

      refute has_element?(view, "#alert-timing-preview")
    end

    test "removing one Friday takes it out of the pattern", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      choose_weekdays(view, 1..5)
      put_timing(view, %{"first_date" => Date.to_iso8601(@first_date), "weeks" => "2"})
      put_timing(view, %{"start_time" => "20:00", "end_time" => "05:00"})

      add_timing_date(view, @friday)

      # The Friday is stored as removed, and the nine remaining nights are what
      # the preview counts (R12).
      assert has_element?(view, "#alert-timing-count", "9 days: Oct 5 to Oct 16")
      assert has_element?(view, "#alert-timing-removed-2026-10-09", "Friday, October 9")
      refute has_element?(view, "#alert-timing-occurrence-2026-10-09")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.timing.removed_dates == [@friday]
      assert saved.timing.weeks == 2
      assert saved.timing.weekdays == [1, 2, 3, 4, 5]
      assert saved.timing.start_time == @night_start
      assert saved.timing.end_time == @night_end

      # Putting it back rejoins the pattern and stores nothing but its absence.
      view |> element("#alert-timing-removed-remove-2026-10-09") |> render_click()

      assert has_element?(view, "#alert-timing-count", "10 days: Oct 5 to Oct 16")
      assert {:ok, restored} = Alerts.get_alert(context.audit, alert.id)
      assert restored.timing.removed_dates == []
    end

    test "a date the pattern does not cover is added instead of removed", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      choose_weekdays(view, 1..5)
      put_timing(view, %{"first_date" => Date.to_iso8601(@first_date), "weeks" => "2"})
      put_timing(view, %{"start_time" => "20:00", "end_time" => "05:00"})

      add_timing_date(view, @added_saturday)

      assert has_element?(view, "#alert-timing-count", "11 days: Oct 5 to Oct 16")
      assert has_element?(view, "#alert-timing-added-2026-10-10", "Saturday, October 10")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.timing.added_dates == [@added_saturday]
      assert saved.timing.removed_dates == []
    end

    test "the notice date defaults to the later of today and seven days before", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      choose_weekdays(view, 1..5)
      put_timing(view, %{"first_date" => Date.to_iso8601(@first_date), "weeks" => "2"})
      put_timing(view, %{"start_time" => "20:00", "end_time" => "05:00"})

      today = context.audit |> Alerts.agency_now() |> NaiveDateTime.to_date()
      week_before = Date.add(@first_date, -7)
      expected = if Date.compare(week_before, today) == :gt, do: week_before, else: today

      # The default is named beside the input and the input itself is empty, so
      # nothing was stored by the edits above.
      assert render(view) =~
               "Left empty, riders are told from #{Calendar.strftime(expected, "%b %-d")}."

      refute view |> element("#timing-notice-on") |> render() =~ "value="
      assert {:ok, unstored} = Alerts.get_alert(context.audit, alert.id)
      assert unstored.timing.notice_on == nil

      # Choosing another date stores it, and it stops following the rule.
      put_timing(view, %{"notice_on" => "2026-09-30"})

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.timing.notice_on == ~D[2026-09-30]
    end

    test "an unrelated edit does not store the default notice date", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-weekly") |> render_click()

      # A first date more than a week out gives a default later than today, which
      # is the case a submitted default would store wrongly.
      far = context.audit |> Alerts.agency_now() |> NaiveDateTime.to_date() |> Date.add(30)

      view
      |> form("#alert-form", %{"alert" => %{"timing" => %{"first_date" => Date.to_iso8601(far)}}})
      |> render_change()

      view
      |> form("#alert-form", %{"alert" => %{"timing" => %{"weeks" => "2"}}})
      |> render_change()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.timing.first_date == far
      assert saved.timing.weeks == 2
      assert saved.timing.notice_on == nil

      assert render(view) =~
               "Left empty, riders are told from #{Calendar.strftime(Date.add(far, -7), "%b %-d")}."
    end

    test "an all-day answer has no times and no overnight note", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      choose_weekdays(view, 1..5)
      put_timing(view, %{"first_date" => Date.to_iso8601(@first_date), "weeks" => "2"})
      put_timing(view, %{"all_day" => "false", "start_time" => "20:00", "end_time" => "05:00"})

      assert has_element?(view, "#timing-day-start")

      # The checkbox sits beside its label and carries no click handler of its
      # own: ticking it is a change of the whole form, which is what the browser
      # sends.
      view
      |> form("#alert-form", %{"alert" => %{"timing" => %{"all_day" => "true"}}})
      |> render_change()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.timing.all_day == true

      refute has_element?(view, "#timing-day-start")
      refute has_element?(view, "#alert-timing-overnight")
      assert has_element?(view, "#alert-timing-count", "10 days: Oct 5 to Oct 16")
      assert render(view) =~ "All day"
    end

    test "the saved timing equals the values the question holds", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      choose_weekdays(view, 1..5)
      put_timing(view, %{"first_date" => Date.to_iso8601(@first_date), "weeks" => "2"})
      put_timing(view, %{"start_time" => "20:00", "end_time" => "05:00"})
      add_timing_date(view, @friday)
      add_timing_date(view, @added_saturday)

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)

      assert saved.timing.pattern == :weekly
      assert saved.timing.first_date == @first_date
      assert saved.timing.weeks == 2
      assert saved.timing.weekdays == [1, 2, 3, 4, 5]
      assert saved.timing.start_time == @night_start
      assert saved.timing.end_time == @night_end
      assert saved.timing.removed_dates == [@friday]
      assert saved.timing.added_dates == [@added_saturday]
      assert saved.timing.time_zone == "America/Los_Angeles"
    end

    test "Continue moves on once the pattern is answerable", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-continue") |> render_click()

      assert has_element?(view, "#alert-timing-error", "Choose when this repeats.")
      assert has_element?(view, "#alert-question-title", "When will service change?")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      choose_weekdays(view, 1..5)
      put_timing(view, %{"first_date" => Date.to_iso8601(@first_date), "weeks" => "2"})
      put_timing(view, %{"start_time" => "20:00", "end_time" => "05:00"})

      view |> element("#alert-timing-continue") |> render_click()

      assert has_element?(view, "#alert-question-title", "Why is this happening?")
    end

    test "a weekday this question does not offer stores nothing", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      choose_weekdays(view, 1..5)
      assert {:ok, before} = Alerts.get_alert(context.audit, alert.id)
      revision = before.revision

      view |> render_click("toggle_weekday", %{"day" => "9"})

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.timing.weekdays == [1, 2, 3, 4, 5]
      assert unchanged.revision == revision
    end
  end

  describe "the bounds the recurrence states" do
    setup :editor_conn

    test "more than fifty-two weeks is refused on the field itself", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      put_timing(view, %{"first_date" => Date.to_iso8601(@first_date)})
      put_timing(view, %{"weeks" => "53"})

      # The refusal keeps the typed value on screen and says so beside it, so
      # the reader fixes one field rather than retyping the answer (AC-16).
      assert has_element?(view, "#timing-weeks-error")
      assert view |> element("#timing-weeks") |> render() =~ ~s(value="53")

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert is_nil(unchanged.timing.weeks)
    end

    test "a pattern past the occurrence bound says so instead of listing dates", context do
      alert = planned_alert(context)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing")

      view |> element("#alert-timing-pattern-weekly") |> render_click()
      choose_weekdays(view, 1..7)
      put_timing(view, %{"first_date" => Date.to_iso8601(@first_date), "weeks" => "52"})
      put_timing(view, %{"start_time" => "08:00", "end_time" => "17:00"})

      assert has_element?(view, "#alert-timing-count", "364 days: Oct 5 to")

      # Fifty-two weeks of every weekday already reaches the calendar's own
      # limit, so the only way past the occurrence bound is dates the pattern
      # does not cover. Naming them is exactly what the bound exists to refuse.
      for offset <- 0..36 do
        date = Date.add(@first_date, 400 + offset)

        add_timing_date(view, date)
      end

      assert has_element?(
               view,
               "#alert-timing-error",
               "That's too many dates. Shorten the period or choose fewer days."
             )

      refute has_element?(view, "#alert-timing-preview")
    end
  end

  # -- Driving the question ------------------------------------------------

  # Every answer on this card is a cast field, so it arrives the way a browser
  # sends it: the whole form, under the timing embed.
  defp put_timing(view, attrs) do
    render_change(view, "autosave", %{"alert" => %{"timing" => attrs}})
    view
  end

  defp choose_weekdays(view, days) do
    Enum.each(days, fn day ->
      render_click(view, "toggle_weekday", %{"day" => Integer.to_string(day)})
    end)

    view
  end

  defp add_timing_date(view, date) do
    render_change(view, "autosave", %{"timing_date" => %{"date" => iso(date)}})
    render_click(view, "add_timing_date", %{})
    view
  end

  defp iso(date), do: Date.to_iso8601(date)

  # -- Fixtures ------------------------------------------------------------

  defp now_alert(context) do
    alert_fixture(context.audit, %{
      "urgency" => "now",
      "situation" => "delay",
      "scope" => %{"shape" => "routes", "route_ids" => [context.route.route_id]}
    })
  end

  defp planned_alert(context) do
    alert_fixture(context.audit, %{
      "urgency" => "planned",
      "situation" => "delay",
      "scope" => %{"shape" => "routes", "route_ids" => [context.route.route_id]}
    })
  end

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  defp edit_path(alert), do: "/alerts/#{alert.id}"

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end
end
