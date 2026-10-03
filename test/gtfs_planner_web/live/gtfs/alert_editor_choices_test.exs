defmodule GtfsPlannerWeb.Gtfs.AlertEditorChoicesTest do
  @moduledoc """
  Step 16: a choice saves, advances and moves the focus, and Back loses nothing
  (AC-17, CL-17).

  Every expectation is a literal from the specification's step-sequence table
  (spec 4.3), the prototype's card copy, or the alert row's own answers - never
  a value recomputed by the module under test. The step names the card ids the
  templates give each choice, the situations and service-change kinds are
  `GtfsPlanner.Alerts.Alert`'s own, and the direction labels are the pattern
  headsigns the fixture writes.
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

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/Los_Angeles"})

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "a single choice" do
    setup :editor_conn

    test "choosing a situation saves it and patches to the next question", context do
      alert = alert_with(context, %{"urgency" => "now"})

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=situation")

      assert has_element?(view, "#situation-delay", "Delays")
      assert has_element?(view, "#situation-detour", "A different path, with stops skipped.")

      view |> element("#situation-detour") |> render_click()

      # The next question is the one the step-sequence table puts after
      # `situation` for a detour, and the answer is on the row.
      assert has_element?(view, "#alert-question-title", "Which routes are affected?")
      assert has_element?(view, "#alert-step-routes[aria-current='step']")

      # The focus target is the new question's own heading, and the element that
      # moves the focus to it is this question's own: LiveView keys its DOM
      # patch on an element's id, so a step-keyed wrapper is what makes
      # `phx-mounted` run again rather than only on the first question shown.
      assert has_element?(
               view,
               "#alert-question-title[tabindex='-1']",
               "Which routes are affected?"
             )

      assert has_element?(view, "#alert-question-heading-routes[phx-mounted]")
      refute has_element?(view, "#alert-question-heading-situation[phx-mounted]")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.situation == :detour
      assert saved.revision == 2
    end

    test "Back patches to the previous question and keeps the answer pressed", context do
      alert = alert_with(context, %{"urgency" => "now", "situation" => "detour"})

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=routes")

      assert has_element?(view, "#alert-question-title", "Which routes are affected?")

      view |> element("#alert-question-back") |> render_click()

      assert has_element?(view, "#alert-question-title", "What is happening?")
      assert has_element?(view, "#situation-detour[aria-pressed='true']")
      assert has_element?(view, "#situation-delay[aria-pressed='false']")

      # Back is navigation: it wrote nothing and dropped nothing.
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.situation == :detour
      assert saved.revision == alert.revision
    end

    test "a service change asks what changes before it asks about routes", context do
      alert = alert_with(context, %{"urgency" => "planned", "situation" => "service_change"})

      {:ok, view, _html} = live(context.conn, edit_path(alert) <> "?step=change")

      assert has_element?(view, "#alert-question-title", "What kind of service change?")
      assert has_element?(view, "#change-fewer_trips", "Fewer trips")
      assert has_element?(view, "#change-extra_service", "Extra service")
      assert has_element?(view, "#change-information", "Information for riders")

      view |> element("#change-fewer_trips") |> render_click()

      assert has_element?(view, "#alert-question-title", "Which routes are affected?")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.service_change_kind == :fewer_trips
    end

    test "a direction is optional and Both directions stores no direction", context do
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})

      patterns =
        Enum.map([0, 1], fn direction_id ->
          schedule_pattern_fixture(context.organization.id, context.version.id, %{
            route_id: "R1",
            route_pattern_id: "P-#{direction_id}",
            direction_id: direction_id,
            headsign: "To #{if direction_id == 0, do: "Lincoln City", else: "Newport"}",
            stops: [{"S1", 0, 0, 1}, {"S2", 600, 600, 0}]
          })
        end)

      service = calendar_fixture(context.organization.id, context.version.id)

      Enum.each(patterns, fn bundle ->
        schedule_trip_fixture(
          context.organization.id,
          context.version.id,
          "R1",
          bundle,
          %{service_id: service.service_id, trip_id: "T-#{bundle.pattern.direction_id}"}
        )
      end)

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "delay",
          "scope" => %{"shape" => "routes", "route_ids" => [route.id]}
        })

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=direction")

      assert has_element?(view, "#direction-both", "Both directions")
      assert has_element?(view, "#direction-0", "To Lincoln City")
      assert has_element?(view, "#direction-1", "To Newport")

      view |> element("#direction-1") |> render_click()

      assert has_element?(view, "#alert-question-title", "When should this alert end?")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.direction_id == 1

      # Going back and taking the other answer clears the number rather than
      # leaving the earlier one behind.
      view |> element("#alert-question-back") |> render_click()
      view |> element("#direction-both") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert is_nil(saved.scope.direction_id)
      assert saved.scope.route_ids == [route.id]
    end
  end

  describe "the mode question" do
    setup :editor_conn

    test "a version with one route type has no mode question", context do
      _bus =
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "R1",
          route_type: 3
        })

      alert = alert_with(context, %{"urgency" => "now", "situation" => "delay"})

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=situation")

      refute has_element?(view, "#alert-step-mode")

      # `steps_for/2` has no `mode` to patch to, so the URL falls back to the
      # question this alert does ask rather than raising.
      view |> element("#situation-delay") |> render_click()
      assert has_element?(view, "#alert-question-title", "Which routes are affected?")
      refute has_element?(view, "#alert-step-mode")
    end

    test "a version with two route types asks which service after the situation", context do
      _bus =
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "R1",
          route_type: 3
        })

      _tram =
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "R50",
          route_type: 0
        })

      alert = alert_with(context, %{"urgency" => "now", "situation" => "delay"})

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=situation")

      view |> element("#situation-delay") |> render_click()

      assert has_element?(view, "#alert-question-title", "Which service is affected?")
      assert has_element?(view, "#alert-step-mode[aria-current='step']")

      # The cards are this version's route types, named the way the routes page
      # names them rather than as GTFS numbers.
      assert has_element?(view, "#mode-3", "Bus")
      assert has_element?(view, "#mode-0", "Tram/Light Rail")

      view |> element("#mode-0") |> render_click()

      assert has_element?(view, "#alert-question-title", "Which routes are affected?")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.mode_route_type == 0
    end
  end

  describe "the routes multi-select" do
    setup :editor_conn

    test "choices are saved as they are made and Continue carries them on", context do
      coast =
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "R1",
          route_short_name: "Coast"
        })

      hospital =
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "R12",
          route_short_name: "Hospital"
        })

      alert = alert_with(context, %{"urgency" => "now", "situation" => "delay"})

      {:ok, view, _html} = live(context.conn, edit_path(alert) <> "?step=routes")

      assert has_element?(view, "#alert-question-title", "Which routes are affected?")
      assert has_element?(view, "#alert-routes-continue", "Continue")

      # Nothing is offered until the editor searches, so the list is always a
      # search result rather than the whole version.
      assert has_element?(view, "#alert-route-empty", "Type a route number or name")

      # A keystroke reaches the search as the field's own value; a form replay
      # would carry the same text under the field's name.
      render_keyup(view, "search_routes", %{"route_query" => "R"})

      assert has_element?(view, "#alert-route-#{coast.id}", "Coast")
      assert has_element?(view, "#alert-route-#{hospital.id}", "Hospital")

      view |> element("#alert-route-#{coast.id}") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.route_ids == [coast.id]

      view |> element("#alert-route-#{hospital.id}") |> render_click()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.route_ids == [coast.id, hospital.id]

      assert has_element?(view, "#alert-route-#{coast.id}[aria-pressed='true']")

      view |> element("#alert-routes-continue") |> render_click()

      assert has_element?(view, "#alert-question-title", "Which direction is affected?")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.route_ids == [coast.id, hospital.id]
      assert saved.scope.shape == :routes
    end

    test "Continue with nothing chosen says so and stays on the question", context do
      _coast = route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})
      alert = alert_with(context, %{"urgency" => "now", "situation" => "delay"})

      {:ok, view, _html} = live(context.conn, edit_path(alert) <> "?step=routes")

      revision = alert.revision

      view |> element("#alert-routes-continue") |> render_click()

      assert has_element?(view, "#alert-routes-error", "Choose at least one route")
      assert has_element?(view, "#alert-question-title", "Which routes are affected?")

      # Nothing was written by the refusal.
      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == revision
      assert unchanged.scope.route_ids == nil
    end

    test "the whole system is one choice and needs no Continue", context do
      _coast = route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})
      alert = alert_with(context, %{"urgency" => "now", "situation" => "suspension"})

      {:ok, view, _html} = live(context.conn, edit_path(alert) <> "?step=routes")

      assert has_element?(view, "#alert-routes-system", "The whole system")

      view |> element("#alert-routes-system") |> render_click()

      assert has_element?(view, "#alert-question-title", "When should this alert end?")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.scope.shape == :system
      assert saved.scope.route_ids == []
    end
  end

  describe "a stale card click" do
    setup :editor_conn

    test "shows the conflict and leaves the other editor's draft alone", context do
      alert = alert_with(context, %{"urgency" => "now"})

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=situation")

      # Another tab saves revision 2 while this editor still holds revision 1.
      assert {:ok, _other} =
               Alerts.save_draft(context.audit, alert.id, alert.revision, %{
                 "situation" => "delay"
               })

      view |> element("#situation-detour") |> render_click()

      # The click is refused with the conflict and its two ways forward, and the
      # editor stays on the question instead of crashing and remounting.
      assert has_element?(view, "#alert-conflict")
      assert has_element?(view, "#conflict-load-latest")
      assert has_element?(view, "#conflict-save-new")
      assert has_element?(view, "#alert-question-title", "What is happening?")
      assert has_element?(view, "#alert-save-status", "Not saved.")

      assert {:ok, row} = Alerts.get_alert(context.audit, alert.id)
      assert row.situation == :delay
      assert row.revision == alert.revision + 1
    end
  end

  describe "a stale card click followed by navigation" do
    setup :editor_conn

    test "Retry and Save alert do not overwrite the other editor's draft", context do
      alert = alert_with(context, %{"urgency" => "now"})

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=situation")

      assert {:ok, _other} =
               Alerts.save_draft(context.audit, alert.id, alert.revision, %{
                 "situation" => "delay"
               })

      view |> element("#situation-detour") |> render_click()
      assert has_element?(view, "#alert-conflict")

      # Walking to another question reloads the row at the other editor's
      # revision, and the refused click is still the draft this editor holds.
      view |> element("#alert-step-urgency") |> render_click()

      assert has_element?(view, "#alert-conflict")
      assert has_element?(view, "#conflict-save-new")
      refute has_element?(view, "#alert-save-retry")

      render_click(view, "retry_save")
      render_click(view, "save_alert")

      assert has_element?(view, "#alert-conflict")
      assert {:ok, row} = Alerts.get_alert(context.audit, alert.id)
      assert row.situation == :delay
      assert row.revision == alert.revision + 1
    end
  end

  describe "forged answers" do
    setup :editor_conn

    test "a card value that is not one of the choices advances nothing", context do
      alert = alert_with(context, %{"urgency" => "now"})

      {:ok, view, _html} = live(context.conn, edit_path(alert))

      render_click(view, "choose_situation", %{"situation" => "everything_cancelled"})
      render_click(view, "choose_mode", %{"route_type" => "bus"})
      render_click(view, "choose_direction", %{"direction" => "north"})

      assert has_element?(view, "#alert-question-title", "When are riders affected?")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.situation == nil
      assert saved.scope.shape == nil
    end
  end

  # -- Fixtures ------------------------------------------------------------

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  defp edit_path(alert), do: "/alerts/#{alert.id}"

  defp alert_with(context, attrs), do: alert_fixture(context.audit, attrs)

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
