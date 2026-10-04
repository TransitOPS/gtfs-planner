defmodule GtfsPlannerWeb.Gtfs.AlertEditorLiveTest do
  @moduledoc """
  Step 14: the editor shell keeps its URL state, its version and the reader's
  authoring preference (AC-15, R1, CL-15).

  Every expectation is a literal from the specification's rules and the
  prototype, not a value recomputed by the module under test. The step names the
  card checks come from the step-sequence table in specification 4.3; the timing
  summary the preview shows is the literal sentence `Alerts.Recurrence.summary/1`
  derives, and the situations are the ones the table gives that sequence for.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  import Ecto.Query, only: [from: 2]

  # The words this package must never show on an editor surface: the publication
  # states and actions of the prototype's earlier revision, which package 30
  # removed because saving an alert never publishes one (R2, CR-1).
  @publication_copy ["Live", "Scheduled", "Ended", "End alert", "feed"]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    other_version = gtfs_version_fixture(organization.id, %{name: "Winter 2027 service"})
    # The editor is organization-owned, so the version its reads and writes
    # resolve against is the organization's active schedule, not one named in the
    # URL or selected in the navbar. The second version is backdated so the first
    # stays the navbar's, the same idiom `test/support/browser_seed.exs` uses.
    Repo.update!(
      Ecto.Changeset.change(other_version, published_at: ~U[2020-01-01 00:00:00.000000Z])
    )

    actor = editor_fixture(organization)
    activate_version!(organization, version, actor)
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

  describe "a new alert" do
    setup :editor_conn

    test "/alerts/new renders the frame and writes no row", context do
      assert Repo.aggregate(GtfsPlanner.Alerts.Alert, :count) == 0

      {:ok, view, _html} = live(context.conn, new_path())

      assert has_element?(view, "#alert-editor")
      assert has_element?(view, "#alert-back-link", "Alerts")
      assert has_element?(view, "#alert-question-title", "When are riders affected?")
      assert has_element?(view, "#alert-urgency-now", "Happening now")
      assert has_element?(view, "#alert-urgency-planned", "Starts later")
      assert has_element?(view, "#alert-preview", "Rider preview")
      assert has_element?(view, "#alert-mode")
      assert has_element?(view, "#alert-save-bar")

      # Nothing was written: opening and abandoning the editor leaves no row.
      assert Repo.aggregate(GtfsPlanner.Alerts.Alert, :count) == 0
    end

    test "the first answer creates the alert and navigates to its own URL", context do
      {:ok, view, _html} = live(context.conn, new_path())

      assert view
             |> element("#alert-urgency-now")
             |> render_click()

      assert [alert] = Repo.all(GtfsPlanner.Alerts.Alert)

      assert_redirect(
        view,
        "/alerts/#{alert.id}?mode=form&step=situation"
      )

      assert alert.urgency == :now
      assert alert.revision == 1
      assert alert.organization_id == context.organization.id
      assert alert.source_gtfs_version_id == context.version.id
      assert alert.created_by_id == context.actor.id
    end

    test "the editor carries no publication state or action", context do
      {:ok, _view, html} = live(context.conn, new_path())
      text = LazyHTML.text(LazyHTML.from_fragment(html))

      for word <- @publication_copy do
        refute text =~ word, "expected no #{word} on the alert editor"
      end
    end
  end

  describe "URL state" do
    setup :editor_conn

    test "?step and ?mode restore the question and the mode after a reload", context do
      alert = alert_with(context, %{"urgency" => "now", "situation" => "detour"})

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing&mode=form")

      assert has_element?(view, "#alert-question-title", "When should this alert end?")
      assert has_element?(view, "#alert-step-timing[aria-current='step']")
      assert page_title(view) =~ "Update alert"

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=timing&mode=form")

      assert has_element?(view, "#alert-question-title", "When should this alert end?")
    end

    test "without ?mode the editor opens in the reader's stored preference", context do
      {:ok, user} =
        Accounts.update_alert_authoring_mode(context.actor, :assistant)

      alert = alert_with(context, %{"urgency" => "now"})

      {:ok, view, _html} = live(context.conn, edit_path(alert))

      assert has_element?(view, "#alert-assistant")
      refute has_element?(view, "#alert-question")

      assert user.alert_authoring_mode == :assistant
    end

    test "an unknown step falls back to the first question rather than raising", context do
      alert = alert_with(context, %{"urgency" => "now", "situation" => "delay"})

      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=nonsense")

      assert has_element?(view, "#alert-question-title", "When are riders affected?")
    end
  end

  describe "the authoring preference" do
    setup :editor_conn

    test "Make default stores the mode the editor is in and then reads Default", context do
      {:ok, _user} = Accounts.update_alert_authoring_mode(context.actor, :assistant)

      {:ok, view, _html} = live(context.conn, new_path() <> "?mode=form")

      assert has_element?(view, "#make-default-mode", "Make default")
      refute has_element?(view, "#alert-mode-default")

      assert view |> element("#make-default-mode") |> render_click()

      assert Accounts.get_user!(context.actor.id).alert_authoring_mode == :form
      assert has_element?(view, "#alert-mode-default", "Default")
      refute has_element?(view, "#make-default-mode")
    end

    test "a reader whose stored preference is the current mode sees Default, not the link",
         context do
      {:ok, view, _html} = live(context.conn, new_path())

      assert Accounts.get_user!(context.actor.id).alert_authoring_mode == :form
      assert has_element?(view, "#alert-mode-default", "Default")
      refute has_element?(view, "#make-default-mode")
    end
  end

  describe "the version an alert belongs to" do
    setup :editor_conn

    test "an alert of another version opens, because the alert belongs to the organization",
         context do
      # Written against the organization's other version: the version is where an
      # alert's selectors came from, not who owns it, so the editor opens it
      # (step 7, AC-9). The editor still refuses another organization's alert,
      # which its own case beside this one proves.
      agency_fixture(context.organization.id, context.other_version.id)

      alert =
        alert_fixture(
          %{context.audit | gtfs_version_id: context.other_version.id},
          %{"urgency" => "now", "situation" => "delay"}
        )

      assert {:ok, view, _html} = live(context.conn, edit_path(alert))
      assert has_element?(view, "#alert-editor")

      # The alert's answers are still exactly what the editor stored.
      assert {:ok, found} = Alerts.get_alert(context.audit, alert.id)
      assert found.urgency == :now
      assert found.situation == :delay
    end

    test "an alert of another organization redirects with an error", context do
      other_organization = organization_fixture()
      other_actor = editor_fixture(other_organization)
      other_version = gtfs_version_fixture(other_organization.id)
      agency_fixture(other_organization.id, other_version.id)

      alert =
        alert_fixture(
          audit_context(other_organization, other_version, other_actor),
          %{"urgency" => "now", "situation" => "delay"}
        )

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(context.conn, edit_path(alert))

      assert to == alerts_path()
      assert Phoenix.Flash.get(flash, :error) =~ "not available"
    end

    test "an unknown alert id redirects with an error", context do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(context.conn, "/alerts/#{Ecto.UUID.generate()}")

      assert to == alerts_path()
      assert Phoenix.Flash.get(flash, :error) =~ "not available"
    end
  end

  describe "the step progress" do
    setup :editor_conn

    test "a detour lists its own questions and ends with reason, message and review", context do
      alert = alert_with(context, %{"urgency" => "now", "situation" => "detour"})

      {:ok, view, _html} = live(context.conn, edit_path(alert))

      assert progress_labels(view) == [
               "Timing",
               "Situation",
               "Routes",
               "Stops",
               "Alternative",
               "Times",
               "Reason",
               "Message",
               "Review"
             ]
    end

    test "a multimodal version adds Mode after Situation", context do
      route_fixture(context.organization.id, context.version.id, %{route_type: 3})
      route_fixture(context.organization.id, context.version.id, %{route_type: 0})
      alert = alert_with(context, %{"urgency" => "now", "situation" => "detour"})

      {:ok, view, _html} = live(context.conn, edit_path(alert))

      assert progress_labels(view) == [
               "Timing",
               "Situation",
               "Mode",
               "Routes",
               "Stops",
               "Alternative",
               "Times",
               "Reason",
               "Message",
               "Review"
             ]
    end

    test "a chosen stop that another route serves adds the shared question", context do
      chosen =
        route_fixture(context.organization.id, context.version.id, %{route_id: "R1"})

      other = route_fixture(context.organization.id, context.version.id, %{route_id: "R2"})

      shared =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: "SHARED",
          stop_name: "Newport Transit Center"
        })

      service = calendar_fixture(context.organization.id, context.version.id)

      # Both routes serve the one stop through a real trip, which is the only
      # thing `Alerts.routes_at_stops/2` reads.
      for route <- [chosen, other] do
        bundle =
          schedule_pattern_fixture(context.organization.id, context.version.id, %{
            route_id: route.route_id,
            route_pattern_id: "P-#{route.route_id}",
            stops: [{"SHARED", 0, 0, 1}]
          })

        schedule_trip_fixture(
          context.organization.id,
          context.version.id,
          route.route_id,
          bundle,
          %{service_id: service.service_id, trip_id: "T-#{route.route_id}"}
        )
      end

      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "stop_closed",
          "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [shared.stop_id]}
        })

      # The alert names the stop but not the other route, so the shared question
      # applies; naming both routes would remove it.
      {:ok, view, _html} = live(context.conn, edit_path(alert))
      assert "Shared" in progress_labels(view)

      both =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "stop_closed",
          "scope" => %{
            "shape" => "route_stops",
            "route_ids" => [chosen.route_id, other.route_id],
            "stop_ids" => [shared.stop_id]
          }
        })

      {:ok, view, _html} = live(context.conn, edit_path(both))
      refute "Shared" in progress_labels(view)
    end

    test "an answered question carries a check, an unanswered one its position", context do
      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "delay",
          "cause" => "weather",
          "message" => message()
        })

      # The current question shows its position, so the check is read on a step
      # after the first one.
      {:ok, view, _html} =
        live(context.conn, edit_path(alert) <> "?step=message")

      assert has_element?(view, "#alert-step-urgency .hero-check")
      assert has_element?(view, "#alert-step-timing", "5.")
      refute has_element?(view, "#alert-step-timing .hero-check")
    end
  end

  describe "the Rider preview" do
    setup :editor_conn

    test "it shows the saved header and the When summary of the saved timing", context do
      alert =
        alert_with(context, %{
          "urgency" => "now",
          "situation" => "delay",
          "scope" => %{"shape" => "system"},
          "message" => %{
            "header" => "Route 1 buses delayed",
            "description" => "Water main work on Main St."
          },
          "timing" => %{
            "start_date" => "2026-10-05",
            "start_time" => "08:00:00",
            "end_kind" => "confirmed",
            "end_date" => "2026-10-07",
            "end_time" => "17:00:00"
          }
        })

      {:ok, view, _html} = live(context.conn, edit_path(alert))

      assert has_element?(view, "#alert-preview-header", "Route 1 buses delayed")
      # A confirmed end names its end date, so the When line covers 5 to 7 October.
      assert has_element?(view, "#alert-preview-when", "Oct 5")
      assert has_element?(view, "#alert-preview-when", "Oct 7")
      assert has_element?(view, "#alert-preview-what", "Delays")
    end

    test "an alert with nothing saved says so in words", context do
      {:ok, view, _html} = live(context.conn, new_path())

      assert has_element?(view, "#alert-preview-empty", "Your rider message will appear here")
      assert has_element?(view, "#alert-preview-when", "Not chosen yet")
    end
  end

  describe "Delete alert" do
    setup :editor_conn

    test "the confirmation names the alert, and confirming deletes it", context do
      alert =
        alert_with(context, %{"urgency" => "now", "situation" => "delay", "message" => message()})

      {:ok, view, _html} = live(context.conn, edit_path(alert))

      assert view |> element("#delete-alert") |> render_click()

      assert has_element?(view, "#delete-alert-dialog[data-open='true']")

      assert has_element?(
               view,
               "#delete-alert-dialog-body",
               "Delete Route 1 buses delayed? This can't be undone."
             )

      assert view |> element("#delete-alert-dialog-confirm") |> render_click()

      assert_redirect(view, alerts_path())
      assert Alerts.get_alert(context.audit, alert.id) == {:error, :not_found}
    end

    test "cancelling keeps the alert", context do
      alert = alert_with(context, %{"urgency" => "now", "situation" => "delay"})

      {:ok, view, _html} = live(context.conn, edit_path(alert))

      assert view |> element("#delete-alert") |> render_click()
      assert view |> element("#delete-alert-dialog-cancel") |> render_click()

      assert {:ok, _found} = Alerts.get_alert(context.audit, alert.id)
      refute has_element?(view, "#delete-alert-dialog[data-open='true']")
    end
  end

  describe "targets the active schedule lacks" do
    setup :editor_conn
    setup :missing_stop_alert

    test "the raw ID is listed with the active schedule's name, and an unrelated edit keeps it",
         context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      assert has_element?(view, "#alert-target-repair", "Fall 2026 service")
      assert has_element?(view, "#alert-repair-0", "OLD_ANNEX")

      assert has_element?(
               view,
               "#alert-repair-0-note",
               "Stop OLD_ANNEX is not in the active schedule"
             )

      # Nothing is staged, so there is nothing to apply and the panel says why.
      assert has_element?(view, "#alert-repair-apply[disabled]")
      assert has_element?(view, "#alert-repair-hint", "Remove or Replace")

      view
      |> form("#alert-form",
        alert: %{
          "revision" => "#{context.alert.revision}",
          "message" => %{"header" => "Annex closed for work"}
        }
      )
      |> render_change()

      assert {:ok, saved} = Alerts.get_alert(context.audit, context.alert.id)
      assert saved.message.header == "Annex closed for work"

      # The original ID, its capture, the zone and the provenance are untouched: an
      # edit that names no target never retargets.
      assert saved.scope.stop_ids == ["OLD_ANNEX"]
      assert saved.target_reference == context.alert.target_reference
      assert saved.timezone == context.alert.timezone
      assert saved.source_gtfs_version_id == context.alert.source_gtfs_version_id

      assert has_element?(view, "#alert-repair-0", "OLD_ANNEX")
      assert has_element?(view, "#message-header[value='Annex closed for work']")
    end

    test "a replacement is picked from the active schedule and nothing changes until Apply",
         context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      view |> element("#alert-repair-replace-0") |> render_click()
      assert has_element?(view, "#alert-repair-picker-0")
      assert has_element?(view, "#alert-repair-status", "Search the active schedule")

      search_replacements(view, 0, "Harbor")
      render_async(view)

      assert has_element?(view, "#alert-repair-status", "1 in the active schedule")
      assert has_element?(view, "#alert-repair-option-0-NEW_HARBOR", "Harbor Station")
      refute has_element?(view, "#alert-repair-option-0-OLD_ANNEX")

      view |> element("#alert-repair-option-0-NEW_HARBOR") |> render_click()

      assert has_element?(view, "#alert-repair-0-staged", "Harbor Station (NEW_HARBOR)")
      refute has_element?(view, "#alert-repair-picker-0")
      refute has_element?(view, "#alert-repair-apply[disabled]")

      # Staged is not saved: the alert still names the old stop.
      assert {:ok, staged} = Alerts.get_alert(context.audit, context.alert.id)
      assert staged.scope.stop_ids == ["OLD_ANNEX"]
      assert staged.revision == context.alert.revision

      view |> element("#alert-repair-apply") |> render_click()

      assert {:ok, repaired} = Alerts.get_alert(context.audit, context.alert.id)
      assert repaired.scope.stop_ids == ["NEW_HARBOR"]
      assert repaired.revision == context.alert.revision + 1
      assert repaired.source_gtfs_version_id == context.version.id
      assert repaired.timezone == context.alert.timezone
      assert [%{"gtfs_id" => "NEW_HARBOR"}] = repaired.target_reference["selectors"]["stops"]

      refute has_element?(view, "#alert-target-repair")
      assert has_element?(view, "#alert-repair-done", "Targets updated.")
      assert has_element?(view, "#alert-repair-done", "Fall 2026 service")
      assert has_element?(view, "#alert-save-status", "Saved")
      assert_push_event(view, "focus_scoped_target", %{id: "alert-question-title"})
    end

    test "removing a target is staged, can be undone, and is applied the same way", context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      view |> element("#alert-repair-remove-0") |> render_click()
      assert has_element?(view, "#alert-repair-0-staged", "Will be removed")

      view |> element("#alert-repair-undo-0") |> render_click()
      refute has_element?(view, "#alert-repair-0-staged")
      assert has_element?(view, "#alert-repair-apply[disabled]")

      view |> element("#alert-repair-remove-0") |> render_click()
      view |> element("#alert-repair-apply") |> render_click()

      assert {:ok, repaired} = Alerts.get_alert(context.audit, context.alert.id)
      assert repaired.scope.stop_ids == []
      assert repaired.message.header == context.alert.message.header
      refute has_element?(view, "#alert-target-repair")
    end

    test "a repair applied over a newer revision offers Load latest and keeps the staged change",
         context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      view |> element("#alert-repair-remove-0") |> render_click()

      # Another editor saves the alert while the removal is staged.
      assert {:ok, newer} =
               Alerts.save_draft(
                 context.audit,
                 context.alert.id,
                 context.alert.revision,
                 %{"message" => %{"header" => "Annex closed for work"}},
                 schedule_opts(context.audit)
               )

      view |> element("#alert-repair-apply") |> render_click()

      # Nothing typed is waiting, so there is nothing to save as a new alert, and the
      # save bar does not claim the alert is unsaved.
      assert has_element?(view, "#alert-conflict")
      assert has_element?(view, "#conflict-load-latest")
      refute has_element?(view, "#conflict-save-new")
      refute has_element?(view, "#alert-save-status", "Not saved")

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, context.alert.id)
      assert unchanged.scope.stop_ids == ["OLD_ANNEX"]
      assert unchanged.revision == newer.revision

      view |> element("#conflict-load-latest") |> render_click()

      refute has_element?(view, "#alert-conflict")
      assert has_element?(view, "#alert-repair-0-staged", "Will be removed")
      assert has_element?(view, "#message-header[value='Annex closed for work']")

      view |> element("#alert-repair-apply") |> render_click()

      assert {:ok, repaired} = Alerts.get_alert(context.audit, context.alert.id)
      assert repaired.scope.stop_ids == []
      assert repaired.revision == newer.revision + 1
    end

    test "a refused apply keeps every staged change and names what still does not fit",
         context do
      second = stop_fixture(context.organization.id, context.version.id, %{stop_id: "OLD_DOCK"})

      {:ok, with_two} =
        Alerts.save_draft(
          context.audit,
          context.alert.id,
          context.alert.revision,
          %{"scope" => %{"stop_ids" => ["OLD_ANNEX", "OLD_DOCK"]}},
          schedule_opts(context.audit)
        )

      Repo.delete!(second)

      {:ok, view, _html} = live(context.conn, edit_path(with_two) <> "?step=message")

      assert has_element?(view, "#alert-repair-1", "OLD_DOCK")

      view |> element("#alert-repair-replace-0") |> render_click()
      search_replacements(view, 0, "Harbor")
      render_async(view)
      view |> element("#alert-repair-option-0-NEW_HARBOR") |> render_click()

      # OLD_DOCK is still named, so the proposal as a whole does not fit.
      view |> element("#alert-repair-apply") |> render_click()

      assert has_element?(view, "#alert-repair-error", "not applied")

      # The focus push names this paragraph, and only a focusable element can take it.
      assert has_element?(view, "#alert-repair-error[tabindex='-1']")
      assert_push_event(view, "focus_scoped_target", %{id: "alert-repair-error"})

      assert has_element?(
               view,
               "#alert-repair-error",
               "Stop OLD_DOCK is not in the active schedule"
             )

      refute has_element?(view, "#alert-repair-error", "OLD_ANNEX")
      assert has_element?(view, "#alert-repair-0-staged", "Harbor Station")

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, with_two.id)
      assert unchanged.scope.stop_ids == ["OLD_ANNEX", "OLD_DOCK"]
      assert unchanged.revision == with_two.revision

      # Staging the second removal completes the proposal, and it applies.
      view |> element("#alert-repair-remove-1") |> render_click()
      refute has_element?(view, "#alert-repair-error")
      view |> element("#alert-repair-apply") |> render_click()

      assert {:ok, repaired} = Alerts.get_alert(context.audit, with_two.id)
      assert repaired.scope.stop_ids == ["NEW_HARBOR"]
    end

    test "a pick that the current search did not offer is refused", context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      view |> element("#alert-repair-replace-0") |> render_click()
      search_replacements(view, 0, "Harbor")
      render_async(view, 5_000)

      # A stop of this organization that the schedule has but the search did not return,
      # and one it never had, are both outside what the picker offered.
      stop_fixture(context.organization.id, context.version.id, %{stop_id: "NOT_OFFERED"})

      for forged <- ["NOT_OFFERED", "FOREIGN", ""] do
        render_hook(view, "repair_choose", %{"index" => "0", "id" => forged})
        refute has_element?(view, "#alert-repair-0-staged")
      end

      assert {:ok, same} = Alerts.get_alert(context.audit, context.alert.id)
      assert same.scope.stop_ids == ["OLD_ANNEX"]
    end
  end

  describe "when the active schedule changes" do
    setup :editor_conn
    setup :route_alert

    test "typed values are kept, saving what reads no schedule continues, and Reload targets reads the new one",
         context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")
      too_long = String.duplicate("a", 121)

      view
      |> form("#alert-form",
        alert: %{
          "revision" => "#{context.alert.revision}",
          "message" => %{"header" => too_long}
        }
      )
      |> render_change()

      assert has_element?(view, "#alert-save-status", "Not saved.")

      switch_active!(context, context.other_version)
      settle(view)

      assert has_element?(view, "#alert-active-changed", "The active schedule changed")
      assert has_element?(view, "#alert-reload-targets", "Reload targets")

      # What was typed is still typed, and its refused save is still retryable.
      assert has_element?(view, "#message-header[value='#{too_long}']")
      assert has_element?(view, "#alert-save-retry")
      refute has_element?(view, "#alert-question-body[disabled]")

      # A message edit reads no schedule, so it saves under the old token.
      view
      |> form("#alert-form",
        alert: %{
          "revision" => "#{context.alert.revision}",
          "message" => %{"header" => "Route 1 delayed"}
        }
      )
      |> render_change()

      assert {:ok, saved} = Alerts.get_alert(context.audit, context.alert.id)
      assert saved.message.header == "Route 1 delayed"
      assert saved.scope.route_ids == ["A_ONLY"]

      view |> element("#alert-reload-targets") |> render_click()

      refute has_element?(view, "#alert-active-changed")
      assert has_element?(view, "#message-header[value='Route 1 delayed']")

      # The alert's route is not in the new active schedule, which the reload now says.
      assert has_element?(view, "#alert-repair-0", "A_ONLY")
      assert has_element?(view, "#alert-target-repair", "Fall 2026 service") == false
      assert has_element?(view, "#alert-target-repair", "Winter 2027 service")
      assert_push_event(view, "focus_scoped_target", %{id: "alert-target-repair"})

      assert {:ok, after_reload} = Alerts.get_alert(context.audit, context.alert.id)
      assert after_reload.scope.route_ids == ["A_ONLY"]
      assert after_reload.revision == saved.revision
    end

    test "choosing targets pauses until Reload targets, which offers only the new schedule's",
         context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=routes")

      view |> element("#alert-route-search") |> render_keyup(%{"value" => "Alpha 1"})
      assert has_element?(view, "#alert-route-A_ONLY")

      switch_active!(context, context.other_version)
      settle(view)

      assert has_element?(view, "#alert-question-body[disabled]")

      # A hand-made event is refused too: no search runs against the schedule the page
      # no longer trusts, and nothing is written.
      render_hook(view, "search_routes", %{"value" => "Alpha 2"})
      render_hook(view, "toggle_route", %{"id" => "B_ONLY"})
      refute has_element?(view, "#alert-route-A_SECOND")
      refute has_element?(view, "#alert-route-B_ONLY")

      assert {:ok, same} = Alerts.get_alert(context.audit, context.alert.id)
      assert same.scope.route_ids == ["A_ONLY"]
      assert same.revision == context.alert.revision

      view |> element("#alert-reload-targets") |> render_click()

      refute has_element?(view, "#alert-question-body[disabled]")
      refute has_element?(view, "#alert-route-A_ONLY")

      view |> element("#alert-route-search") |> render_keyup(%{"value" => "Beta"})
      assert has_element?(view, "#alert-route-B_ONLY")

      view |> element("#alert-route-search") |> render_keyup(%{"value" => "Alpha"})
      refute has_element?(view, "#alert-route-A_ONLY")

      # Reloading did not touch what the alert saved.
      assert {:ok, still} = Alerts.get_alert(context.audit, context.alert.id)
      assert still.scope.route_ids == ["A_ONLY"]
      assert still.revision == context.alert.revision
    end

    test "a target added from the new schedule is labelled from it, not from the alert's source",
         context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=routes")

      switch_active!(context, context.other_version)
      settle(view)
      view |> element("#alert-reload-targets") |> render_click()

      view |> element("#alert-route-search") |> render_keyup(%{"value" => "Beta"})
      view |> element("#alert-route-B_ONLY") |> render_click()

      # A private partial correction: the new route is validated against the active
      # schedule, the old one stays, and the alert's source version is not rewritten.
      assert {:ok, saved} = Alerts.get_alert(context.audit, context.alert.id)
      assert saved.scope.route_ids == ["A_ONLY", "B_ONLY"]
      assert saved.source_gtfs_version_id == context.version.id

      assert has_element?(view, "#alert-preview-where", "Beta 2")
    end

    test "a write refused as stale raises the same notice when the broadcast never arrived",
         context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=routes")

      move_without_notice(context, context.other_version)
      refute has_element?(view, "#alert-active-changed")

      render_hook(view, "toggle_route", %{"id" => "A_ONLY"})

      assert has_element?(view, "#alert-active-changed")
      assert has_element?(view, "#alert-question-body[disabled]")
      refute render(view) =~ "Reload the page"

      assert {:ok, same} = Alerts.get_alert(context.audit, context.alert.id)
      assert same.scope.route_ids == ["A_ONLY"]
      assert same.revision == context.alert.revision
    end

    test "a notice that is not newer than the held token changes nothing", context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=routes")
      held = current_token(context)

      send(view.pid, {:active_schedule_changed, held})
      settle(view)

      refute has_element?(view, "#alert-active-changed")
      refute has_element?(view, "#alert-question-body[disabled]")
    end
  end

  describe "a search that is no longer the one on screen" do
    setup :editor_conn
    setup :missing_stop_alert

    test "an active change cancels the search, and its exit and result are dropped", context do
      stop_fixture(context.organization.id, context.other_version.id, %{
        stop_id: "WINTER_HARBOR",
        stop_name: "Harbor Winter"
      })

      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      view |> element("#alert-repair-replace-0") |> render_click()

      Repo.checkout(fn ->
        # Every read the search task makes waits for this connection, so the query is
        # pending until the function returns.
        search_replacements(view, 0, "Harbor")
        assert has_element?(view, "#alert-repair-status", "Searching")
        assert [{{:repair_search, _request}, pid}] = pending_searches(view)
        monitor = Process.monitor(pid)

        # Another editor chooses the winter schedule while the search is pending.
        switch_active!(context, context.other_version)
        settle(view)

        # The task was cancelled, and its exit changed nothing on screen.
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
        settle(view)

        assert has_element?(view, "#alert-active-changed")
        refute has_element?(view, "#alert-repair-picker-0")
        refute has_element?(view, "#alert-repair-search-error")
        assert pending_searches(view) == []
      end)

      settle(view)

      # Reloading offers the new schedule's stop, not the old one's.
      view |> element("#alert-reload-targets") |> render_click()
      view |> element("#alert-repair-replace-0") |> render_click()
      search_replacements(view, 0, "Harbor")
      render_async(view)

      assert has_element?(view, "#alert-repair-option-0-WINTER_HARBOR", "Harbor Winter")
      refute has_element?(view, "#alert-repair-option-0-NEW_HARBOR")
    end

    test "results and exits of searches a closed and reopened picker left behind are dropped",
         context do
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "OLD_CENTRAL",
        stop_name: "Central Station"
      })

      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      view |> element("#alert-repair-replace-0") |> render_click()

      Repo.checkout(fn ->
        # The first search would answer with Central Station and the second ends
        # without an answer. Each is left behind by closing and reopening the picker,
        # which has asked nothing since.
        search_replacements(view, 0, "Central")
        reopen_picker(view)
        search_replacements(view, 0, "Annex")
        reopen_picker(view)

        assert [_central, {_key, annex}] = pending_searches(view)
        end_search(view, annex)
        settle(view)
      end)

      render_async(view)

      # Both ended after the picker moved on, so neither shows: not the answer, not
      # the failure.
      assert has_element?(view, "#alert-repair-status", "Search the active schedule")
      refute has_element?(view, "#alert-repair-option-0-OLD_CENTRAL")
      refute has_element?(view, "#alert-repair-search-error")

      # The picker still works: a new search is the one on screen.
      search_replacements(view, 0, "Harbor")
      render_async(view)

      assert has_element?(view, "#alert-repair-option-0-NEW_HARBOR")
      refute has_element?(view, "#alert-repair-option-0-OLD_CENTRAL")
    end

    test "a later query in the same open picker replaces the one still pending", context do
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "OLD_CENTRAL",
        stop_name: "Central Station"
      })

      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      view |> element("#alert-repair-replace-0") |> render_click()

      Repo.checkout(fn ->
        # Two queries, neither answered yet, and the picker was never closed.
        search_replacements(view, 0, "Central")
        search_replacements(view, 0, "Harbor")
        assert [_central, _harbor] = pending_searches(view)
      end)

      render_async(view)

      # Only the query on screen is shown, however the two answers arrive.
      assert has_element?(view, "#alert-repair-option-0-NEW_HARBOR", "Harbor Station")
      refute has_element?(view, "#alert-repair-option-0-OLD_CENTRAL")
      assert has_element?(view, "#alert-repair-status", "1 in the active schedule")
    end

    test "an earlier query that ends without an answer says nothing once a later one is on screen",
         context do
      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      view |> element("#alert-repair-replace-0") |> render_click()

      Repo.checkout(fn ->
        search_replacements(view, 0, "Central")
        search_replacements(view, 0, "Harbor")
        assert [{_key, central}, _harbor] = pending_searches(view)
        end_search(view, central)
        settle(view)

        # The later query is still pending, and the earlier one's exit did not fail it.
        assert has_element?(view, "#alert-repair-status", "Searching")
        refute has_element?(view, "#alert-repair-search-error")
      end)

      render_async(view)

      refute has_element?(view, "#alert-repair-search-error")
      assert has_element?(view, "#alert-repair-option-0-NEW_HARBOR")
    end

    test "clearing the query drops the answer of the search it replaces", context do
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "OLD_CENTRAL",
        stop_name: "Central Station"
      })

      {:ok, view, _html} = live(context.conn, edit_path(context.alert) <> "?step=message")

      view |> element("#alert-repair-replace-0") |> render_click()

      Repo.checkout(fn ->
        search_replacements(view, 0, "Central")
        search_replacements(view, 0, "")
      end)

      render_async(view)

      assert has_element?(view, "#alert-repair-status", "Search the active schedule")
      refute has_element?(view, "#alert-repair-option-0-OLD_CENTRAL")
    end

    test "a search that fails while it is the current one says so and can be tried again",
         context do
      second = stop_fixture(context.organization.id, context.version.id, %{stop_id: "OLD_B"})

      {:ok, with_two} =
        Alerts.save_draft(
          context.audit,
          context.alert.id,
          context.alert.revision,
          %{"scope" => %{"stop_ids" => ["OLD_ANNEX", "OLD_B"]}},
          schedule_opts(context.audit)
        )

      Repo.delete!(second)

      {:ok, view, _html} = live(context.conn, edit_path(with_two) <> "?step=message")

      view |> element("#alert-repair-remove-0") |> render_click()
      view |> element("#alert-repair-replace-1") |> render_click()

      Repo.checkout(fn ->
        search_replacements(view, 1, "Harbor")
        assert [{_key, pid}] = pending_searches(view)
        end_search(view, pid)
        settle(view)
      end)

      assert has_element?(view, "#alert-repair-search-error", "The search failed")
      assert has_element?(view, "#alert-repair-0-staged", "Will be removed")

      search_replacements(view, 1, "Harbor")
      render_async(view)

      refute has_element?(view, "#alert-repair-search-error")
      assert has_element?(view, "#alert-repair-option-1-NEW_HARBOR")
    end
  end

  describe "selectors the active schedule holds but cannot honour" do
    setup :editor_conn

    test "a missing route is replaced, and a pair and a stretch no trip serves are removed",
         context do
      alert = served_route_alert(context)

      {:ok, view, _html} = live(context.conn, edit_path(alert) <> "?step=message")

      assert has_element?(view, "#alert-repair-0", "R2")
      assert has_element?(view, "#alert-repair-0-note", "Route R2 is not in the active schedule")
      assert has_element?(view, "#alert-repair-1", "SA on R1")
      assert has_element?(view, "#alert-repair-1-note", "Route R1 does not serve stop SA")
      assert has_element?(view, "#alert-repair-2", "SA to SB")
      assert has_element?(view, "#alert-repair-2-note", "No trip runs from stop SA to stop SB")

      # Only an ID can be replaced by a pick; a pair or a stretch can only be removed.
      assert has_element?(view, "#alert-repair-replace-0")
      refute has_element?(view, "#alert-repair-replace-1")
      refute has_element?(view, "#alert-repair-replace-2")

      view |> element("#alert-repair-replace-0") |> render_click()
      search_replacements(view, 0, "Express")
      render_async(view)
      view |> element("#alert-repair-option-0-R3") |> render_click()

      view |> element("#alert-repair-remove-1") |> render_click()
      view |> element("#alert-repair-remove-2") |> render_click()
      view |> element("#alert-repair-apply") |> render_click()

      assert {:ok, repaired} = Alerts.get_alert(context.audit, alert.id)
      assert repaired.scope.route_ids == ["R1", "R3"]
      assert repaired.scope.stop_ids == ["SA", "SB"]
      assert repaired.scope.route_stop_pairs == []
      assert repaired.scope.stretch_from_stop_id == nil
      assert repaired.scope.stretch_to_stop_id == nil
      assert repaired.revision == alert.revision + 1

      refute has_element?(view, "#alert-target-repair")
      assert has_element?(view, "#alert-repair-done")
    end

    test "a dated trip that no longer runs and a trip the schedule lacks are removed",
         context do
      alert = dated_trip_alert(context)

      {:ok, view, _html} = live(context.conn, edit_path(alert) <> "?step=message")

      assert has_element?(view, "#alert-repair-0", "T1 on 2026-10-06")
      assert has_element?(view, "#alert-repair-0-note", "Trip T1 does not run on 2026-10-06")
      assert has_element?(view, "#alert-repair-1", "T9 on 2026-10-05")
      assert has_element?(view, "#alert-repair-1-note", "Trip T9 is not in the active schedule")
      refute has_element?(view, "#alert-repair-replace-0")
      refute has_element?(view, "#alert-repair-replace-1")

      view |> element("#alert-repair-remove-0") |> render_click()
      view |> element("#alert-repair-remove-1") |> render_click()
      view |> element("#alert-repair-apply") |> render_click()

      # The trip that still runs on its date stays.
      assert {:ok, repaired} = Alerts.get_alert(context.audit, alert.id)

      assert Enum.map(repaired.scope.trips, &{&1.trip_id, &1.service_date}) == [
               {"T1", ~D[2026-10-05]}
             ]

      refute has_element?(view, "#alert-target-repair")
    end
  end

  describe "no active schedule" do
    setup :editor_conn

    test "/alerts/new offers no question and writes nothing", context do
      clear_pointer(context)

      {:ok, view, _html} = live(context.conn, new_path())

      assert has_element?(view, "#alert-editor-no-active", "No active schedule")
      assert has_element?(view, "#alert-choose-schedule[href='/alerts']")
      refute has_element?(view, "#alert-question")
      refute has_element?(view, "#alert-form")
      refute has_element?(view, "#alert-save-bar")
      refute has_element?(view, "#alert-mode")

      # Hand-made events that would start a draft are refused by the command.
      render_hook(view, "choose_urgency", %{"urgency" => "now"})

      render_hook(view, "assistant_start", %{"assistant" => %{"note" => "Route 1 is late"}})

      assert Repo.aggregate(GtfsPlanner.Alerts.Alert, :count) == 0
    end

    test "choosing a schedule elsewhere offers Reload targets, which opens the editor", context do
      clear_pointer(context)
      {:ok, view, _html} = live(context.conn, new_path())

      switch_active!(context, context.version)
      settle(view)

      assert has_element?(view, "#alert-active-changed")
      view |> element("#alert-reload-targets") |> render_click()

      refute has_element?(view, "#alert-editor-no-active")
      refute has_element?(view, "#alert-active-changed")
      assert has_element?(view, "#alert-question-title", "When are riders affected?")
      assert has_element?(view, "#alert-urgency-now")
      assert Repo.aggregate(GtfsPlanner.Alerts.Alert, :count) == 0
    end

    test "an existing alert keeps its draft, Save and close and Delete alert", context do
      alert = alert_with(context, %{"urgency" => "now", "situation" => "delay"})
      clear_pointer(context)

      {:ok, view, _html} = live(context.conn, edit_path(alert) <> "?step=routes")

      assert has_element?(view, "#alert-editor-no-active", "No active schedule")
      assert has_element?(view, "#alert-form")
      assert has_element?(view, "#delete-alert")
      assert has_element?(view, "#alert-save-close")
      assert has_element?(view, "#alert-question-body[disabled]")
      refute has_element?(view, "#alert-target-repair")

      render_hook(view, "toggle_route", %{"id" => "A_ONLY"})
      assert {:ok, same} = Alerts.get_alert(context.audit, alert.id)
      assert same.revision == alert.revision

      # What reads no schedule still saves, and the alert can still be deleted.
      {:ok, view, _html} = live(context.conn, edit_path(alert) <> "?step=message")

      # Arriving at the message step wrote the wording a script produces, so the
      # revision to edit from is the one the page now holds.
      assert {:ok, wording} = Alerts.get_alert(context.audit, alert.id)

      view
      |> form("#alert-form",
        alert: %{"revision" => "#{wording.revision}", "message" => %{"header" => "Delayed"}}
      )
      |> render_change()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.message.header == "Delayed"

      view |> element("#delete-alert") |> render_click()
      view |> element("#delete-alert-dialog-confirm") |> render_click()
      assert Alerts.get_alert(context.audit, alert.id) == {:error, :not_found}
    end
  end

  describe "access" do
    test "a member without the editor role is refused the editor", context do
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])
      conn = log_in_user(build_conn(), viewer, organization: context.organization)

      assert {:error, {:redirect, %{to: path}}} = live(conn, new_path())
      assert path == "/admin/organizations"
    end
  end

  # -- Fixtures ------------------------------------------------------------

  # An alert about a stop the active schedule had when it was written and no longer has.
  defp missing_stop_alert(context) do
    old =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "OLD_ANNEX",
        stop_name: "Annex"
      })

    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: "NEW_HARBOR",
      stop_name: "Harbor Station"
    })

    alert =
      alert_with(context, %{
        "urgency" => "now",
        "situation" => "stop_closed",
        "cause" => "construction",
        "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [old.stop_id]},
        "message" => message()
      })

    Repo.delete!(old)

    %{alert: alert}
  end

  # An alert about a route of the active schedule. The other version has a different
  # route, so choosing it makes the alert's route missing.
  defp route_alert(context) do
    route_fixture(context.organization.id, context.version.id, %{
      route_id: "A_ONLY",
      route_short_name: "Alpha 1"
    })

    route_fixture(context.organization.id, context.version.id, %{
      route_id: "A_SECOND",
      route_short_name: "Alpha 2"
    })

    route_fixture(context.organization.id, context.other_version.id, %{
      route_id: "B_ONLY",
      route_short_name: "Beta 2"
    })

    alert =
      alert_with(context, %{
        "urgency" => "now",
        "situation" => "delay",
        "cause" => "weather",
        "scope" => %{"shape" => "routes", "route_ids" => ["A_ONLY"]},
        "message" => message()
      })

    %{alert: alert}
  end

  # A route that is gone, plus a pair and a stretch on a route whose trips stopped
  # serving both stops after the alert was written. The pair and the stretch exist
  # in the schedule but do not fit it, so they are reported as such, not as missing.
  defp served_route_alert(context) do
    organization_id = context.organization.id
    version_id = context.version.id

    for {route_id, name} <- [{"R1", "1"}, {"R2", "2"}, {"R3", "Express"}] do
      route_fixture(organization_id, version_id, %{route_id: route_id, route_short_name: name})
    end

    for {stop_id, name} <- [{"SA", "Alpha"}, {"SB", "Beta"}] do
      stop_fixture(organization_id, version_id, %{stop_id: stop_id, stop_name: name})
    end

    trip_fixture(organization_id, version_id, "R1", %{trip_id: "T1", service_id: "weekday"})

    for {stop_id, sequence} <- [{"SA", 1}, {"SB", 2}] do
      stop_time_fixture(organization_id, version_id, "T1", stop_id, %{stop_sequence: sequence})
    end

    alert =
      alert_with(context, %{
        "urgency" => "now",
        "situation" => "detour",
        "cause" => "construction",
        "scope" => %{
          "shape" => "route_stops",
          "route_ids" => ["R1", "R2"],
          "stop_ids" => ["SA", "SB"],
          "route_stop_pairs" => [%{"route_id" => "R1", "stop_id" => "SA"}],
          "stretch_from_stop_id" => "SA",
          "stretch_to_stop_id" => "SB"
        },
        "message" => message()
      })

    Repo.delete!(
      Repo.get_by!(GtfsPlanner.Gtfs.Route,
        organization_id: organization_id,
        gtfs_version_id: version_id,
        route_id: "R2"
      )
    )

    Repo.delete_all(GtfsPlanner.Gtfs.StopTime)

    alert
  end

  # A trip on two dates and a trip that is later removed. A service exception then
  # takes the second date away, so the trip exists but does not run that day.
  defp dated_trip_alert(context) do
    organization_id = context.organization.id
    version_id = context.version.id

    route_fixture(organization_id, version_id, %{route_id: "R1", route_short_name: "1"})
    calendar_fixture(organization_id, version_id, %{service_id: "weekday"})
    trip_fixture(organization_id, version_id, "R1", %{trip_id: "T1", service_id: "weekday"})

    gone =
      trip_fixture(organization_id, version_id, "R1", %{trip_id: "T9", service_id: "weekday"})

    alert =
      alert_with(context, %{
        "urgency" => "now",
        "situation" => "cancelled_trips",
        "cause" => "maintenance",
        "scope" => %{
          "shape" => "trips",
          "route_ids" => ["R1"],
          "trips" => [
            %{"trip_id" => "T1", "service_date" => "2026-10-06"},
            %{"trip_id" => "T9", "service_date" => "2026-10-05"},
            %{"trip_id" => "T1", "service_date" => "2026-10-05"}
          ]
        },
        "message" => message()
      })

    Repo.delete!(gone)

    calendar_date_fixture(organization_id, version_id, %{
      service_id: "weekday",
      date: ~D[2026-10-06],
      exception_type: 2
    })

    alert
  end

  defp session_scope(context),
    do: %{actor_id: context.actor.id, organization_id: context.organization.id}

  defp current_token(context) do
    {:ok, %{token: token}} = Versions.active_schedule(session_scope(context))
    token
  end

  defp switch_active!(context, version) do
    {:ok, _active} =
      Versions.set_active_schedule(session_scope(context), version.id, current_token(context))
  end

  # A selection the page was not told about: no broadcast leaves this update.
  defp move_without_notice(context, version) do
    Repo.update_all(
      from(o in Organization, where: o.id == ^context.organization.id),
      set: [active_gtfs_version_id: version.id],
      inc: [active_gtfs_version_revision: 1]
    )
  end

  # The legacy state a published schedule can sit in with no pointer.
  defp clear_pointer(context) do
    Repo.update_all(
      from(o in Organization, where: o.id == ^context.organization.id),
      set: [active_gtfs_version_id: nil]
    )
  end

  defp search_replacements(view, index, query) do
    view
    |> form("#alert-repair-search-form-#{index}")
    |> render_change(%{"repair_query" => query})
  end

  # Ends a search the way a crashed task ends. The view is unlinked from the task
  # first (from inside the view), so LiveView learns of it through its own monitor and
  # reports an exit, instead of the exit signal taking the view down with the task.
  defp end_search(view, pid) do
    monitor = Process.monitor(pid)

    :sys.replace_state(view.pid, fn state ->
      Process.unlink(pid)
      state
    end)

    capture_log(fn ->
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    end)
  end

  defp reopen_picker(view) do
    view |> element("#alert-repair-close") |> render_click()
    view |> element("#alert-repair-replace-0") |> render_click()
  end

  # Returns once the view has handled everything sent to it, and the client has the
  # result, so an assertion reads the state that message produced.
  defp settle(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  # The replacement searches the view is waiting on, keyed by LiveView's own task
  # reference: `{key, pid}` for each task that has not ended.
  defp pending_searches(view) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> then(&(&1.private[:live_async] || %{}))
    |> Enum.filter(fn {{name, _request}, {_ref, _pid, :start}} -> name == :repair_search end)
    |> Enum.sort_by(fn {{_name, request}, _task} -> request end)
    |> Enum.map(fn {key, {_ref, pid, :start}} -> {key, pid} end)
    |> Enum.filter(fn {_key, pid} -> Process.alive?(pid) end)
  end

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  defp new_path, do: "/alerts/new"
  defp alerts_path, do: "/alerts"

  defp edit_path(alert), do: "/alerts/#{alert.id}"

  # The progress row in reading order, as the reader sees it. Each step is a
  # link or a disabled span with the same id, so both are read the same way.
  defp progress_labels(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#alert-progress [id^='alert-step-']")
    |> Enum.flat_map(fn element ->
      element
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.replace(~r/^\d+\.\s*/, "")
      |> String.trim()
      |> then(&[&1])
    end)
  end

  defp alert_with(context, attrs) do
    alert_fixture(context.audit, attrs)
  end

  defp message do
    %{
      "header" => "Route 1 buses delayed",
      "description" => "Water main work on Main St. Use Route 2 instead."
    }
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
