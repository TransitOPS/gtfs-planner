defmodule GtfsPlannerWeb.Gtfs.AlertEditorAutosaveTest do
  @moduledoc """
  Step 15: autosave never loses typed work and never overwrites a newer
  revision (AC-16, R6, CL-16).

  Every expectation is a literal from the specification's rules and the
  prototype: the status words are the three the prototype's save bar uses, the
  conflict copy is the sentence AC-16 fixes, and the refused save is over the
  header length `Alerts.MessageAnswer` documents. Nothing here recomputes an
  expected value with the module under test.

  The stale cases drive `render_change/3` with the base revision a *second
  writer* would still be holding, which is what LiveView form recovery replays
  after a reconnect. That replay is the failure this step exists to prevent
  (PM-1), so it is exercised directly rather than simulated: no test-only path
  injects an old revision, the params carry it exactly as the hidden field does.
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

  describe "autosave" do
    setup :editor_conn

    test "a change with a header and revision 1 saves revision 2 and reads Saved", context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      view
      |> form("#alert-form",
        alert: %{"revision" => "1", "message" => %{"header" => "Route 1 buses delayed"}}
      )
      |> render_change()

      assert has_element?(view, "#alert-save-status", "Saved")

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.revision == 2
      assert saved.message.header == "Route 1 buses delayed"
    end

    test "the status never reads Saved before the server has acknowledged", context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      # A refused save is the observable case: the bar says what happened, not
      # what was attempted.
      view
      |> form("#alert-form",
        alert: %{"revision" => "1", "message" => %{"header" => String.duplicate("a", 121)}}
      )
      |> render_change()

      refute has_element?(view, "#alert-save-status", "Saved")
      assert has_element?(view, "#alert-save-status", "Not saved.")
    end

    test "the form carries the base revision a recovery would replay", context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      assert view
             |> element("input[name='alert[revision]']")
             |> render() =~ ~s(value="1")
    end
  end

  describe "a stale change" do
    setup :editor_conn

    test "carrying an old revision renders the conflict and leaves the row alone",
         context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      # Another process saves revision 2 while this editor still holds 1.
      assert {:ok, _other} =
               Alerts.save_draft(context.audit, alert.id, 1, %{
                 "message" => %{"header" => "Saved by the other editor"}
               })

      view
      |> form("#alert-form",
        alert: %{"revision" => "1", "message" => %{"header" => "Typed here"}}
      )
      |> render_change()

      assert has_element?(view, "#alert-conflict")
      assert has_element?(view, "#alert-conflict", "another tab or by another editor")
      assert has_element?(view, "#alert-conflict", "aren't saved")
      assert has_element?(view, "#conflict-load-latest")
      assert has_element?(view, "#conflict-save-new")

      # The row is still the other editor's revision 2: a stale write never
      # overwrites (R6).
      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == 2
      assert unchanged.message.header == "Saved by the other editor"

      # The typed value is still on screen, because the other side of the
      # conflict is the one that may become a new alert.
      assert view |> element("#alert_message_header") |> render() =~ "Typed here"
    end

    test "the conflict banner offers no way to overwrite", context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      assert {:ok, _other} =
               Alerts.save_draft(context.audit, alert.id, 1, %{
                 "message" => %{"header" => "Saved by the other editor"}
               })

      view
      |> form("#alert-form",
        alert: %{"revision" => "1", "message" => %{"header" => "Typed here"}}
      )
      |> render_change()

      banner = view |> element("#alert-conflict") |> render()

      for word <- ["overwrite", "Replace", "Force"] do
        refute banner =~ word
      end
    end

    test "Load latest shows the newer saved draft", context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      assert {:ok, _other} =
               Alerts.save_draft(context.audit, alert.id, 1, %{
                 "message" => %{"header" => "Saved by the other editor"}
               })

      view
      |> form("#alert-form",
        alert: %{"revision" => "1", "message" => %{"header" => "Typed here"}}
      )
      |> render_change()

      assert view |> element("#conflict-load-latest") |> render_click()

      refute has_element?(view, "#alert-conflict")
      assert has_element?(view, "#alert-save-status", "Saved")
      assert view |> element("#alert_message_header") |> render() =~ "Saved by the other editor"
    end

    test "Save as new alert creates a second alert holding the local values and opens it",
         context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      assert {:ok, _other} =
               Alerts.save_draft(context.audit, alert.id, 1, %{
                 "message" => %{"header" => "Saved by the other editor"}
               })

      view
      |> form("#alert-form",
        alert: %{"revision" => "1", "message" => %{"header" => "Typed here"}}
      )
      |> render_change()

      assert view |> element("#conflict-save-new") |> render_click()

      # The conflict row is untouched, and exactly one copy was made holding
      # this editor's values.
      assert {:ok, original} = Alerts.get_alert(context.audit, alert.id)
      assert original.revision == 2
      assert original.message.header == "Saved by the other editor"

      assert [copy] = Repo.all(Alerts.Alert) |> Enum.reject(&(&1.id == alert.id))
      assert copy.message.header == "Typed here"

      assert_redirect(view, ~r|/gtfs/#{context.version.id}/alerts/#{copy.id}|)
    end
  end

  describe "a refused save" do
    setup :editor_conn

    test "keeps the typed header, shows the field error and offers Retry", context do
      alert = message_alert(context)
      long = String.duplicate("a", 121)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      view
      |> form("#alert-form", alert: %{"revision" => "1", "message" => %{"header" => long}})
      |> render_change()

      # Nothing on screen was cleared: the refused sentence is still the input's
      # value (AC-16).
      assert view |> element("#alert_message_header") |> render() =~ long
      assert has_element?(view, "#alert_message_header-error", "120 character")
      assert has_element?(view, "#alert-save-status", "Not saved.")
      assert has_element?(view, "#alert-save-retry")

      # And nothing was written.
      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == 1
      assert unchanged.message.header == "Route 1 buses delayed"
    end

    test "Retry sends the same values again and keeps them when it is refused",
         context do
      alert = message_alert(context)
      long = String.duplicate("a", 121)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      view
      |> form("#alert-form", alert: %{"revision" => "1", "message" => %{"header" => long}})
      |> render_change()

      assert view |> element("#alert-save-retry") |> render_click()

      # Retry is the same write attempted again with the values this editor
      # holds, so a refusal that is still a refusal changes nothing and loses
      # nothing.
      assert has_element?(view, "#alert-save-status", "Not saved.")
      assert view |> element("#alert_message_header") |> render() =~ long

      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == 1

      # Editing again carries the new value, which does save.
      view
      |> form("#alert-form",
        alert: %{"revision" => "1", "message" => %{"header" => "Short enough"}}
      )
      |> render_change()

      assert has_element?(view, "#alert-save-status", "Saved")
      refute has_element?(view, "#alert-save-retry")
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.revision == 2
      assert saved.message.header == "Short enough"
    end
  end

  describe "Save and close" do
    setup :editor_conn

    test "saves and returns to the list", context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      view
      |> form("#alert-form",
        alert: %{"revision" => "1", "message" => %{"header" => "Typed then closed"}}
      )
      |> render_submit()

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.revision == 2
      assert saved.message.header == "Typed then closed"

      assert_redirect(view, "/gtfs/#{context.version.id}/alerts")
    end

    test "a refused save keeps the editor open rather than leaving", context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      view
      |> form("#alert-form",
        alert: %{"revision" => "1", "message" => %{"header" => String.duplicate("a", 121)}}
      )
      |> render_submit()

      assert has_element?(view, "#alert-question")
      assert has_element?(view, "#alert-save-status", "Not saved.")

      # Nothing was written and nothing was left behind.
      assert {:ok, unchanged} = Alerts.get_alert(context.audit, alert.id)
      assert unchanged.revision == 1
    end
  end

  describe "identity the form cannot set" do
    setup :editor_conn

    test "a revision that does not parse is not written as the alert's own", context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      # Sent as a raw event rather than through `form/3`, because a real form
      # could not hold this value: the point is what the handler does with a
      # revision it cannot read (CR-2).
      render_change(view, %{
        "alert" => %{"revision" => "not-a-revision", "message" => %{"header" => "Forged"}}
      })

      # It falls back to the revision this editor last saw, so the write lands
      # on the row's own revision and never on one the event named.
      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.revision == 2
      assert saved.message.header == "Forged"
    end

    test "a forged organization, version or completion flag is ignored", context do
      alert = message_alert(context)

      {:ok, view, _html} = live(context.conn, message_path(context, alert))

      render_change(view, %{
        "alert" => %{
          "revision" => "1",
          "organization_id" => Ecto.UUID.generate(),
          "gtfs_version_id" => Ecto.UUID.generate(),
          "complete" => "true",
          "message" => %{"header" => "Forged identity"}
        }
      })

      assert {:ok, saved} = Alerts.get_alert(context.audit, alert.id)
      assert saved.organization_id == context.organization.id
      assert saved.gtfs_version_id == context.version.id
      refute saved.complete
    end
  end

  # -- Fixtures ------------------------------------------------------------

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  # An alert that already answers enough questions to reach the message step, so
  # the message fields are the ones the autosave form is exercised through.
  defp message_alert(context) do
    alert_fixture(context.audit, %{
      "urgency" => "now",
      "situation" => "delay",
      "scope" => %{"shape" => "system"},
      "message" => %{"header" => "Route 1 buses delayed", "description" => "Water main work."}
    })
  end

  defp message_path(context, alert) do
    "/gtfs/#{context.version.id}/alerts/#{alert.id}?mode=form&step=message"
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
