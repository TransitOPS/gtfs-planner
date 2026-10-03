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

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  # The words this package must never show on an editor surface: the publication
  # states and actions of the prototype's earlier revision, which package 30
  # removed because saving an alert never publishes one (R2, CR-1).
  @publication_copy ["Live", "Scheduled", "Ended", "End alert", "feed"]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    other_version = gtfs_version_fixture(organization.id, %{name: "Winter 2027 service"})
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
          "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [shared.id]}
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
            "route_ids" => [chosen.id, other.id],
            "stop_ids" => [shared.id]
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
