defmodule GtfsPlannerWeb.Gtfs.AlertEditorReviewTest do
  @moduledoc """
  Step 22: the review reads the alert back, and **Save alert** is the action
  that either reports what is missing or finishes the draft (AC-23, FH-23).

  Every expectation is a literal: the six messages
  `GtfsPlanner.Alerts.Completion.errors/1` writes for a delay that has answered
  only its first two questions, the sentence AC-23 fixes for a `:no_service`
  alert, the summary `GtfsPlanner.Alerts.Recurrence.summary/1` builds for this
  fixture's own Monday-to-Friday window, and this fixture's own route, stops
  and cause. Nothing here recomputes an expectation with the module under test.

  The ids are the ones the templates give each part, so nothing depends on copy
  or layout. The alert is written only through `Alerts.create_alert/2` and
  `Alerts.save_draft/4` (INV-1) and read back through `Alerts.get_alert/2`.

  What this file cannot check is the focus itself: LiveViewTest does not run the
  client, so the summary's `phx-mounted` focus command is proved by the
  `@review` browser block and only the summary it targets is proved here.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext

  # The rider message this fixture's planned delay carries, written by an
  # operator rather than filled from a script: the review shows these words
  # exactly, and its first line is the alert's own When summary so the "Says
  # when" guideline can be checked against it.
  @header "Route 1 buses are running late tonight"
  @when_summary "Mon–Fri, 8 PM to 5 AM the next day, Oct 5 to Oct 23"

  @description @when_summary <>
                 ", Route 1 buses to Lincoln City are late because of roadwork. " <>
                 "Allow extra time."

  # The closed stop's own message.
  @closed_header "NE 6th St stop closed"

  @closed_description "Oct 1, 8 AM to 12 PM, NE 6th St is closed. Use NE 12th St instead."

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    actor = editor_fixture(organization)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})

    %{first: first, middle: middle, last: last} =
      stops(organization, version, [
        {"S6", "NE 6th St"},
        {"S12", "NE 12th St"},
        {"S20", "NE 20th St"}
      ])

    route = route(organization, version, first, middle, last)

    %{
      organization: organization,
      version: version,
      actor: actor,
      route: route,
      first: first,
      middle: middle,
      last: last,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "an alert that is not finished" do
    setup :editor_conn

    test "#save-alert lists the questions still unanswered, each one linking to its step",
         context do
      # A delay that has answered only the first two questions, so every
      # remaining answer is one this step's own sequence names.
      alert = alert_fixture(context.audit, %{"urgency" => "now", "situation" => "delay"})

      {:ok, view, _html} = live(context.conn, review_path(context, alert))

      assert view |> element("#save-alert") |> render_click()

      # The refusal is a list, not a dead end, and the list is the one
      # `Alerts.Completion.errors/1` produced for this draft: the routes, the
      # three answers a current disruption's timing asks for, and the two the
      # wording asks for (AC-23).
      assert has_element?(view, "#review-errors", "This alert is not finished yet")

      assert review_messages(view) == [
               "Choose at least one route.",
               "Choose the date this started.",
               "Choose the time of day this applies.",
               "Say when this is expected to end.",
               "Write the headline riders will see.",
               "Describe what to expect and what to do instead."
             ]

      # Each question is a way through to the editor's own URL for the step
      # that answers it, so the summary is a list of doors rather than a
      # paragraph of advice.
      assert review_links(view) == [
               review_path(context, alert, :routes),
               review_path(context, alert, :timing),
               review_path(context, alert, :timing),
               review_path(context, alert, :timing),
               review_path(context, alert, :message),
               review_path(context, alert, :message)
             ]

      # The reader is still on the review, and the draft is untouched: a
      # refused save changes nothing in the database (R6, AC-16).
      assert has_element?(view, "#alert-question-title", "Review alert")
      refute_redirected(view)
      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == alert.revision
      assert unchanged.complete == false
    end

    test "the same step finishes the alert once the questions are answered", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now", "situation" => "delay"})

      {:ok, view, _html} = live(context.conn, review_path(context, alert))

      assert view |> element("#save-alert") |> render_click()
      assert has_element?(view, "#review-errors")

      # Somebody else answers the rest, through the one writer this editor
      # also uses (INV-1). Nothing about the save action itself changed: the
      # same button reads the row it finds.
      {:ok, answered} =
        Alerts.save_draft(context.audit, alert.id, alert.revision, %{
          "scope" => %{"shape" => "routes", "route_ids" => [context.route.id]},
          "timing" => %{
            "start_date" => "2026-10-01",
            "start_time" => "08:00",
            "end_kind" => "unknown",
            "check_in_at" => "2026-10-01 09:30:00"
          },
          "message" => %{"header" => @header, "description" => @description}
        })

      assert answered.complete == true

      {:ok, reloaded, _html} = live(context.conn, review_path(context, alert))

      # Arriving at a finished alert offers nothing to report.
      refute has_element?(reloaded, "#review-errors")

      assert reloaded |> element("#save-alert") |> render_click()

      flash = assert_redirect(reloaded, alerts_path(context.version))
      assert flash["info"] == "Alert saved."
    end
  end

  describe "a complete alert" do
    setup :editor_conn

    test "#save-alert returns to the list with the flash it says it does", context do
      alert = planned_delay(context)
      {:ok, view, _html} = live(context.conn, review_path(context, alert))

      # Nothing is outstanding, so the one action finishes the draft and says
      # so. The draft itself is already saved: every answer was written as it
      # was given, and this action only says that the alert is whole (AC-23).
      assert view |> element("#save-alert") |> render_click()

      flash = assert_redirect(view, alerts_path(context.version))
      assert flash["info"] == "Alert saved."

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.complete == true
      assert saved.revision == alert.revision
    end

    test "the review shows the header and description exactly as saved, and the When summary",
         context do
      alert = planned_delay(context)
      {:ok, view, _html} = live(context.conn, review_path(context, alert))

      # The wording is the operator's, character for character: the review
      # never re-generates it, and it is the same string the row stores
      # (AC-23, FH-22).
      assert has_element?(view, "#review-header", @header)
      assert has_element?(view, "#review-description", @description)

      # The facts beside it come from the derivations the Rider preview reads,
      # so the two readings of this alert cannot disagree.
      assert has_element?(view, "#review-when", @when_summary)
      assert has_element?(view, "#review-where", "Route 1")
      assert has_element?(view, "#review-what", "Delays")
      assert has_element?(view, "#review-why", "Construction or roadwork")
      assert has_element?(view, "#review-effect", "Delays")
      assert has_element?(view, "#review-riders")
      assert has_element?(view, "#review-details")

      # The guidelines' own results are the ones the message step showed, and
      # they are advisory here as they are there (AC-12, AC-22).
      assert has_element?(view, "#review-guidelines")
      assert has_element?(view, "#review-check-short", "Short message is 38 characters.")
      assert has_element?(view, "#review-check-when", "Says when.")
    end

    test "a stop-closed alert says what no service does to a rider's trip plan", context do
      alert = closed_stop(context)
      {:ok, view, _html} = live(context.conn, review_path(context, alert))

      # AC-23 fixes this sentence, and it is the only consequence the review
      # states: no service is the one effect that changes what a trip planner
      # suggests rather than only what an app displays.
      assert has_element?(
               view,
               "#review-no-service",
               "Trip planners may show these trips as cancelled."
             )

      assert has_element?(view, "#review-effect", "No service")
      assert has_element?(view, "#review-header", @closed_header)
      assert has_element?(view, "#review-description", @closed_description)
      assert has_element?(view, "#review-where", "Route 1 · 1 stop")
    end

    test "a delay carries no no-service consequence", context do
      alert = planned_delay(context)
      {:ok, view, _html} = live(context.conn, review_path(context, alert))

      refute has_element?(view, "#review-no-service")
    end

    test "nothing on the review offers a publication state or an action", context do
      alert = closed_stop(context)
      {:ok, view, _html} = live(context.conn, review_path(context, alert))

      html = render(view)

      # Saving an alert never publishes one in this package, so no Live,
      # Scheduled, Ended, End, Publish, Schedule or feed word appears anywhere
      # on this step, in any case (R2, CR-1).
      refute html =~ ~r/publish/i
      refute html =~ ~r/schedul/i

      # The actions the step offers are the two that save: the review's own
      # **Save alert**, and the editor's **Save and close**.
      assert has_element?(view, "#save-alert.btn-primary", "Save alert")
      assert has_element?(view, "#alert-save-close.btn-outline", "Save and close")
      assert has_element?(view, "#alert-save-bar")
    end
  end

  # -- Fixtures ------------------------------------------------------------

  # A planned weekly delay with wording somebody wrote: the alert the review
  # is mostly about, because it is complete and its text is the operator's. It
  # holds only the answers the planned timing card collects: a planned alert
  # has no end kind, and its weekly pattern already bounds its end.
  defp planned_delay(context) do
    alert_fixture(context.audit, %{
      "urgency" => "planned",
      "situation" => "delay",
      "cause" => "construction",
      "scope" => %{"shape" => "routes", "route_ids" => [context.route.id]},
      "timing" => %{
        "pattern" => "weekly",
        "first_date" => "2026-10-05",
        "weeks" => 3,
        "weekdays" => [1, 2, 3, 4, 5],
        "start_time" => "20:00:00",
        "end_time" => "05:00:00"
      },
      "message" => %{
        "header" => @header,
        "description" => @description,
        "customized" => true
      }
    })
  end

  # A closed stop with a confirmed end, which is the situation whose effect
  # changes a rider's trip plan.
  defp closed_stop(context) do
    alert_fixture(context.audit, %{
      "urgency" => "now",
      "situation" => "stop_closed",
      "cause" => "construction",
      "scope" => %{
        "shape" => "stop_all_routes",
        "stop_ids" => [context.first.id],
        "route_ids" => [context.route.id]
      },
      "timing" => %{
        "start_date" => "2026-10-01",
        "start_time" => "08:00:00",
        "end_kind" => "confirmed",
        "end_date" => "2026-10-02",
        "end_time" => "12:00:00"
      },
      "message" => %{
        "header" => @closed_header,
        "description" => @closed_description
      }
    })
  end

  defp stops(organization, version, rows) do
    rows
    |> Enum.map(fn {stop_id, stop_name} ->
      {:ok, stop} =
        insert_stop(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop_id,
          stop_name: stop_name,
          location_type: 0,
          stop_lat: Decimal.new("44.6210"),
          stop_lon: Decimal.new("-124.0490")
        })

      stop
    end)
    |> case do
      [first, middle, last] -> %{first: first, middle: middle, last: last}
    end
  end

  # One route with the three stops in riders' order, its own direction named
  # by destination, and one trip - which is what gives the alert a route label
  # and a destination for the wording's fill-ins.
  defp route(organization, version, first, middle, last) do
    {:ok, route} =
      insert_route(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        route_id: "R1",
        route_short_name: "Route 1",
        route_long_name: "Coast Highway",
        route_type: 3
      })

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: "R1",
        direction_id: 0,
        headsign: "Lincoln City",
        stops: Enum.map([first, middle, last], &{&1.stop_id, 0, 0, 0})
      })

    service = calendar_fixture(organization.id, version.id)

    schedule_trip_fixture(organization.id, version.id, "R1", bundle, %{
      service_id: service.service_id,
      trip_id: "T-R1"
    })

    route
  end

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  defp review_path(context, alert),
    do: review_path(context, alert, :review)

  defp review_path(context, alert, step),
    do: "/gtfs/#{context.version.id}/alerts/#{alert.id}?mode=form&step=#{step}"

  defp alerts_path(version), do: "/gtfs/#{version.id}/alerts"

  # The questions the summary lists, read from the rendered summary rather than
  # from `Alerts.Completion.errors/1`, so the order an operator reads is the
  # order asserted here.
  defp review_messages(view), do: view |> summary_links() |> Enum.map(&LazyHTML.text/1)

  defp review_links(view) do
    view
    |> summary_links()
    |> Enum.flat_map(&LazyHTML.attribute(&1, "href"))
  end

  defp summary_links(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#review-errors a")
  end

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
