defmodule GtfsPlannerWeb.Gtfs.AlertEditorDeparturesTest do
  @moduledoc """
  Step 18: a cancelled departure is a trip on a service date, never a name
  (AC-19, CL-19).

  Every expectation is a literal from the specification's departure rules (spec
  AC-19, AC-10, R1) or from this file's own fixture trips and their times, never
  a value recomputed by the module under test. The ids are the ones the
  templates give each control, and the dates are fixed rather than read from the
  clock, so a test run on a Sunday asserts the same thing as one on a Monday.
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
  alias GtfsPlanner.Repo

  # The dates the specification's own example uses: a Monday and the Saturday
  # after it, inside the fixture calendars' range.
  @monday ~D[2026-10-05]
  @saturday ~D[2026-10-10]
  # A Monday past the end of both fixture calendars, so nothing runs on it.
  @out_of_service ~D[2027-01-04]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    other_version = gtfs_version_fixture(organization.id, %{name: "Spring 2026 service"})
    # The editor is organization-owned, so the version its reads resolve against
    # is the organization's latest published one, not one named in the URL. The
    # second fixture is backdated so the first stays that version, the same idiom
    # `test/support/browser_seed.exs` uses for the same reason.
    Repo.update!(
      Ecto.Changeset.change(other_version, published_at: ~U[2020-01-01 00:00:00.000000Z])
    )

    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})
    agency_fixture(organization.id, other_version.id, %{agency_timezone: "America/Los_Angeles"})

    %{
      organization: organization,
      version: version,
      other_version: other_version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the departures question" do
    setup :editor_conn

    test "the date lists only the departures running on it", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      assert has_element?(view, "#alert-question-title", "Which departures will not run?")

      add_date(view, @monday)

      # Monday is weekday service: the two weekday trips and not the Saturday
      # one, which is running the next morning (AC-10).
      assert has_element?(
               view,
               "label[for='alert-departure-2026-10-05-#{schedule.early.trip_id}']",
               "8:15 AM to Lincoln City"
             )

      assert has_element?(view, "#alert-departure-2026-10-05-#{schedule.late.trip_id}")
      refute has_element?(view, "#alert-departure-2026-10-05-#{schedule.weekend.trip_id}")

      add_date(view, @saturday)

      # Saturday is weekend service: the one weekend trip, and not the two
      # weekday ones (AC-10).
      assert has_element?(view, "#alert-departure-2026-10-10-#{schedule.weekend.trip_id}")
      refute has_element?(view, "#alert-departure-2026-10-10-#{schedule.early.trip_id}")
      refute has_element?(view, "#alert-departure-2026-10-10-#{schedule.late.trip_id}")
    end

    test "adding a date keeps the date the question opened on", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      # With nothing named, the question offers the agency's own today.
      today = context.audit |> Alerts.agency_now() |> NaiveDateTime.to_date()
      later = Date.add(today, 3)

      assert has_element?(view, "#alert-departures-#{Date.to_iso8601(today)}")

      add_date(view, later)

      assert has_element?(view, "#alert-departures-#{Date.to_iso8601(today)}")
      assert has_element?(view, "#alert-departures-#{Date.to_iso8601(later)}")
    end

    test "a date the route does not run says so", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      add_date(view, @out_of_service)

      assert has_element?(
               view,
               "#alert-departures-empty-2027-01-04",
               "No departures run on this date."
             )
    end

    test "a departure past midnight says it is the next day", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      add_date(view, @monday)

      # The night trip's first stop time is 24:40, so its clock says so rather
      # than reading as an earlier departure (AC-10).
      assert has_element?(
               view,
               "label[for='alert-departure-2026-10-05-#{schedule.night.trip_id}']",
               "12:40 AM (next day) to Downtown"
             )
    end

    test "two departures on one date are saved with that service date", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      add_date(view, @monday)

      view |> element("#alert-departure-2026-10-05-#{schedule.early.trip_id}") |> render_click()
      view |> element("#alert-departure-2026-10-05-#{schedule.late.trip_id}") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.shape == :trips

      assert saved.scope.trips |> Enum.map(&{&1.trip_id, &1.service_date}) |> Enum.sort() ==
               Enum.sort([{schedule.early.trip_id, @monday}, {schedule.late.trip_id, @monday}])

      assert has_element?(
               view,
               "#alert-departure-2026-10-05-#{schedule.early.trip_id}[checked]"
             )

      # Choosing the same departure again takes it back out.
      view |> element("#alert-departure-2026-10-05-#{schedule.late.trip_id}") |> render_click()

      assert {:ok, one} = Alerts.get_alert(context.audit, alert.id)
      assert [%{trip_id: trip_id, service_date: @monday}] = one.scope.trips
      assert trip_id == schedule.early.trip_id
    end

    test "choosing a departure keeps the frequency start time another departure stored",
         context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, alert} =
        Alerts.save_draft(context.audit, alert.id, alert.revision, %{
          "scope" => %{
            "shape" => "trips",
            "trips" => [
              %{
                "trip_id" => schedule.early.trip_id,
                "service_date" => "2026-10-05",
                "start_time" => "25:15:00"
              }
            ]
          }
        })

      {:ok, view, _html} = live(context.conn, edit_path(alert) <> "?step=departures")

      view |> element("#alert-departure-2026-10-05-#{schedule.late.trip_id}") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)

      assert saved.scope.trips
             |> Enum.map(&{&1.trip_id, &1.service_date, &1.start_time})
             |> Enum.sort() ==
               Enum.sort([
                 {schedule.early.trip_id, @monday, "25:15:00"},
                 {schedule.late.trip_id, @monday, nil}
               ])
    end

    test "a second date gets its own checklist and its own pairs", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      add_date(view, @monday)
      view |> element("#alert-departure-2026-10-05-#{schedule.early.trip_id}") |> render_click()

      add_date(view, @saturday)
      view |> element("#alert-departure-2026-10-10-#{schedule.weekend.trip_id}") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)

      assert saved.scope.trips |> Enum.map(&{&1.trip_id, &1.service_date}) |> Enum.sort() ==
               Enum.sort([
                 {schedule.early.trip_id, @monday},
                 {schedule.weekend.trip_id, @saturday}
               ])

      # The selection belongs to the date it was made on, so Saturday's own
      # checklist shows only Saturday's choice as chosen.
      assert has_element?(
               view,
               "#alert-departure-2026-10-05-#{schedule.early.trip_id}[checked]"
             )

      assert has_element?(
               view,
               "#alert-departure-2026-10-10-#{schedule.weekend.trip_id}[checked]"
             )
    end

    test "removing a date removes its pairs and nothing else", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      add_date(view, @monday)
      view |> element("#alert-departure-2026-10-05-#{schedule.early.trip_id}") |> render_click()
      add_date(view, @saturday)
      view |> element("#alert-departure-2026-10-10-#{schedule.weekend.trip_id}") |> render_click()

      view
      |> element("#alert-remove-date-2026-10-10")
      |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert [%{trip_id: trip_id, service_date: @monday}] = saved.scope.trips
      assert trip_id == schedule.early.trip_id

      refute has_element?(view, "#alert-departures-2026-10-10")
      assert has_element?(view, "#alert-departures-2026-10-05")

      # Removing a date that held no selection is only a change to the list the
      # editor is looking at, so it moves no revision.
      revision = saved.revision

      add_date(view, @saturday)
      view |> element("#alert-remove-date-2026-10-10") |> render_click()

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == revision
    end

    test "Continue refuses to move on with nothing chosen", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      view |> element("#alert-departures-continue") |> render_click()

      assert has_element?(
               view,
               "#alert-departures-error",
               "Choose at least one departure"
             )

      assert has_element?(view, "#alert-question-title", "Which departures will not run?")

      add_date(view, @monday)
      view |> element("#alert-departure-2026-10-05-#{schedule.early.trip_id}") |> render_click()
      view |> element("#alert-departures-continue") |> render_click()

      assert has_element?(view, "#alert-question-title", "Why is this happening?")
    end

    test "a trip the schedule does not offer for that date is not stored", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      add_date(view, @monday)
      revision = alert.revision

      # The Saturday trip is not running on the Monday, so naming it saves
      # nothing (AC-10, R1).
      view
      |> render_click("toggle_departure", %{
        "trip_id" => schedule.weekend.trip_id,
        "date" => Date.to_iso8601(@monday)
      })

      # Nor is a trip of another version, whatever date it is named with.
      other_route =
        route_fixture(context.organization.id, context.other_version.id, %{
          route_id: "R99",
          route_short_name: "Route 99",
          route_type: 3
        })

      their_audit = audit_context(context.organization, context.other_version, context.actor)

      other =
        serving_trip(
          %{context | audit: their_audit},
          other_route,
          "T-OTHER",
          "weekday",
          0,
          "Somewhere Else",
          "08:15:00"
        )

      view
      |> render_click("toggle_departure", %{
        "trip_id" => other.trip_id,
        "date" => Date.to_iso8601(@monday)
      })

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.scope.trips == []
      assert unchanged.revision == revision
    end

    test "a date that is not a date adds nothing", context do
      schedule = schedule(context)
      alert = cancelled_alert(context, schedule.route)

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=departures")

      render_change(view, "autosave", %{"service_date" => %{"date" => "not-a-date"}})
      render_click(view, "add_service_date", %{})

      assert has_element?(view, "#alert-departures-error", "Choose a date to add")
      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == alert.revision
    end
  end

  # -- Fixtures ------------------------------------------------------------

  # One route, one stop, two calendars and four trips: two on weekday service,
  # one on weekend service, and one that departs after midnight. Every expected
  # label below is read off these fixtures' own times and headsigns.
  defp schedule(context) do
    route =
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "R1",
        route_short_name: "Route 1",
        route_long_name: "Coast Highway",
        route_type: 3
      })

    calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

    calendar_fixture(context.organization.id, context.version.id, %{
      service_id: "weekend",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 1
    })

    %{
      route: route,
      early: serving_trip(context, route, "T-0815", "weekday", 0, "Lincoln City", "08:15:00"),
      late: serving_trip(context, route, "T-0930", "weekday", 0, "Lincoln City", "09:30:00"),
      weekend: serving_trip(context, route, "T-1015", "weekend", 0, "Lincoln City", "10:15:00"),
      night: serving_trip(context, route, "T-2440", "weekday", 0, "Downtown", "24:40:00")
    }
  end

  defp serving_trip(context, route, trip_id, service_id, direction_id, headsign, departure) do
    version_id = context.audit.gtfs_version_id

    stop =
      stop_fixture(context.organization.id, version_id, %{
        stop_id: "S_#{trip_id}",
        stop_name: "Newport Transit Center"
      })

    trip =
      trip_fixture(context.organization.id, version_id, route.route_id, %{
        trip_id: trip_id,
        service_id: service_id,
        direction_id: direction_id,
        trip_headsign: headsign
      })

    stop_time_fixture(
      context.organization.id,
      version_id,
      trip.trip_id,
      stop.stop_id,
      %{stop_sequence: 1, departure_time: departure}
    )

    trip
  end

  defp add_date(view, date) do
    render_change(view, "autosave", %{"service_date" => %{"date" => Date.to_iso8601(date)}})
    render_click(view, "add_service_date", %{})
    view
  end

  defp cancelled_alert(context, route) do
    alert_fixture(context.audit, %{
      "urgency" => "now",
      "situation" => "cancelled_trips",
      "scope" => %{"shape" => "routes", "route_ids" => [route.route_id]}
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
