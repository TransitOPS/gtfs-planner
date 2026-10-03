defmodule GtfsPlannerWeb.Gtfs.AlertOrganizationRoutesTest do
  @moduledoc """
  Step 8: Alerts belongs to the organization, so its list, editor and settings
  are reached without a selected GTFS version (AC-8, AC-10, CL-5).

  Three things are proved here, at the routes the reader actually uses.

  First, an organization with no schedule at all can open `/alerts`, reach the
  editor through ordinary navigation and create a private system alert. Nothing
  in that path needs a version, and the row it writes carries the organization
  rather than a version.

  Second, a versioned bookmark redirects to the organization page and nothing
  else: the alert identity it named is the only thing carried across, a version
  of another organization is refused outright, and an alert identifier of another
  organization reveals nothing.

  Third, the literal `new` and `settings` segments are never read as an alert
  identifier, and a member with no organization in context reaches the explicit
  unavailable state rather than a page that reads an assign nobody made.

  Every expectation is a literal from the contract; none of them is recomputed
  by the module under test.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  describe "an organization with no schedule" do
    setup do
      organization = organization_fixture()
      actor = editor_fixture(organization)

      # `organization_fixture/1` seeds a default published version, so the
      # versionless organization this suite is about must be built explicitly:
      # removing it is what makes AssignOrganization assign a nil
      # `current_gtfs_version`, which is the state the contract names.
      delete_versions!(from v in GtfsVersion, where: v.organization_id == ^organization.id)

      %{
        organization: organization,
        actor: actor,
        conn: log_in_user(build_conn(), actor, organization: organization)
      }
    end

    test "the list opens without a version and says there is no active schedule", context do
      assert {:ok, view, _html} = live(context.conn, "/alerts")

      assert has_element?(view, "#alerts-page")

      # Alerts resolve against the active schedule, and this organization has none,
      # so the list offers neither rows nor a way to start one.
      assert has_element?(view, "#alerts-no-active")
      refute has_element?(view, "#alerts-first-use")
      refute has_element?(view, "#create-alert-first-use")
      refute has_element?(view, "#create-alert")

      # The organization's first task is Alerts, and it points at the
      # organization path rather than at a version this organization has not got.
      assert has_element?(view, "#main-navigation #nav-alerts[href='/alerts']")

      # No version is selected or selectable, so the switcher has nothing to show.
      refute has_element?(view, "#gtfs-version-switcher")
    end

    test "an editor creates a private system alert at the organization's editor route",
         context do
      assert {:ok, view, _html} = live(context.conn, "/alerts/new")
      assert has_element?(view, "#alert-urgency-now", "Happening now")

      assert view |> element("#alert-urgency-now") |> render_click()

      assert [alert] = Repo.all(Alert)
      assert alert.organization_id == context.organization.id
      assert alert.created_by_id == context.actor.id
      assert alert.source_gtfs_version_id == nil
      assert alert.timezone == nil
      assert alert.urgency == :now

      # The draft the editor was sent to is the row's own URL, with no version.
      assert_redirect(view, "/alerts/#{alert.id}?mode=form&step=situation")
    end

    test "a system-scope answer is the whole selection when there is no schedule", context do
      assert {:ok, view, _html} = live(context.conn, "/alerts/new")

      assert has_element?(view, "#alert-urgency-now", "Happening now")

      # The start card is the urgency question. Answering it creates the private
      # draft and sends the reader to the situation question, which is where the
      # scope answer lives - it is not on this card.
      assert view |> element("#alert-urgency-now") |> render_click()

      assert [created] = Repo.all(Alert)
      situation_path = "/alerts/#{created.id}?mode=form&step=situation"
      assert_redirect(view, situation_path)

      assert {:ok, view, _html} = live(context.conn, situation_path)
      assert view |> element("#situation-delay") |> render_click()

      # With no schedule there is no route to name, so the routes question offers
      # the whole system, and that answer is the entire selection.
      assert has_element?(view, "#alert-routes-system", "The whole system")
      assert view |> element("#alert-routes-system") |> render_click()

      # The delay is stored and the scope is the whole system, on a draft that
      # still carries no version: the organization has none to carry.
      assert [alert] = Repo.all(Alert)
      assert alert.situation == :delay
      assert alert.scope.shape == :system
      assert alert.organization_id == context.organization.id
      assert alert.source_gtfs_version_id == nil
    end

    test "alert settings opens without a version", context do
      assert {:ok, view, _html} = live(context.conn, "/alerts/settings")

      assert has_element?(view, "#alert-settings-page")
      assert has_element?(view, "#alert-settings-tab-scripts")
      assert has_element?(view, "#alert-settings-tab-guidelines")
    end
  end

  describe "an old versioned bookmark" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      actor = editor_fixture(organization)

      audit = audit_context(organization, version, actor)
      alert = alert_fixture(audit, %{"urgency" => "now"})

      %{
        organization: organization,
        version: version,
        actor: actor,
        alert: alert,
        audit: audit,
        conn: log_in_user(build_conn(), actor, organization: organization)
      }
    end

    test "the list redirects to the organization's list", context do
      conn = get(context.conn, "/gtfs/#{context.version.id}/alerts")

      assert redirected_to(conn) == "/alerts"
    end

    test "the editor's start card redirects to the organization's start card", context do
      conn = get(context.conn, "/gtfs/#{context.version.id}/alerts/new")

      assert redirected_to(conn) == "/alerts/new"
    end

    test "the settings page redirects to the organization's settings page", context do
      conn = get(context.conn, "/gtfs/#{context.version.id}/settings/alerts")

      assert redirected_to(conn) == "/alerts/settings"
    end

    test "one alert keeps its identity and is read from the organization", context do
      conn = get(context.conn, "/gtfs/#{context.version.id}/alerts/#{context.alert.id}")

      assert redirected_to(conn) == "/alerts/#{context.alert.id}"

      assert {:ok, view, _html} = live(context.conn, "/alerts/#{context.alert.id}")

      assert has_element?(view, "#alert-editor")
      assert has_element?(view, "#alert-back-link[href='/alerts']")
    end

    test "a version of another organization is refused, not forwarded", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               live(context.conn, "/gtfs/#{other_version.id}/alerts")

      assert flash["error"] == "GTFS version not found"
    end

    test "a bookmark read without a session is sent to sign in", context do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               live(build_conn(), "/gtfs/#{context.version.id}/alerts/#{context.alert.id}")
    end

    test "an alert of another organization reveals nothing", context do
      other_organization = organization_fixture()
      other_actor = editor_fixture(other_organization)
      other_version = gtfs_version_fixture(other_organization.id)

      foreign =
        alert_fixture(audit_context(other_organization, other_version, other_actor), %{
          "urgency" => "now",
          "message" => %{"header" => "Foreign header", "description" => "Foreign description."}
        })

      # The editor refuses during mount: the reader is taken straight to the
      # organization list with the error, so no foreign wording is ever rendered.
      assert {:error,
              {:live_redirect,
               %{to: "/alerts", flash: %{"error" => "That alert is not available here."}}}} =
               live(context.conn, "/alerts/#{foreign.id}")
    end

    test "an identifier that is not an alert reveals nothing", context do
      assert {:error,
              {:live_redirect,
               %{to: "/alerts", flash: %{"error" => "That alert is not available here."}}}} =
               live(context.conn, "/alerts/#{Ecto.UUID.generate()}")
    end
  end

  describe "the literal segments" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      actor = editor_fixture(organization)

      %{
        organization: organization,
        version: version,
        actor: actor,
        conn: log_in_user(build_conn(), actor, organization: organization)
      }
    end

    test "/alerts/new is the editor's start card, not an alert named new", context do
      assert {:ok, view, _html} = live(context.conn, "/alerts/new")

      assert has_element?(view, "#alert-editor")
      assert has_element?(view, "#alert-question-title", "When are riders affected?")
    end

    test "/alerts/settings is the settings page, not an alert named settings", context do
      assert {:ok, view, _html} = live(context.conn, "/alerts/settings")

      assert has_element?(view, "#alert-settings-page")
      refute has_element?(view, "#alert-editor")
    end
  end

  describe "a member with no organization in context" do
    setup do
      organization = organization_fixture()
      administrator = user_fixture()

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: administrator.id,
          organization_id: organization.id,
          roles: ["administrator"]
        })

      %{
        organization: organization,
        administrator: administrator,
        conn: log_in_user(build_conn(), administrator)
      }
    end

    test "the list answers with the explicit unavailable state", context do
      assert {:ok, view, _html} = live(context.conn, "/alerts")

      assert has_element?(view, "#alerts-page")
      assert has_element?(view, "#alerts-organization-required", "Alerts need an organization.")
      refute has_element?(view, "#alerts-first-use")
      refute has_element?(view, "#create-alert")
    end

    test "the editor answers with the explicit unavailable state and writes nothing", context do
      assert {:ok, view, _html} = live(context.conn, "/alerts/new")

      assert has_element?(view, "#alert-editor-organization-required")
      refute has_element?(view, "#alert-urgency-now")
      assert Repo.aggregate(Alert, :count) == 0
    end

    test "the settings page answers with the explicit unavailable state", context do
      assert {:ok, view, _html} = live(context.conn, "/alerts/settings")

      assert has_element?(view, "#alert-settings-organization-required")
      refute has_element?(view, "#alert-settings-scripts")
    end

    test "an editor with the editor role is refused at login without an organization", context do
      actor = editor_fixture(context.organization)

      # `:organization_required` is `:default` plus the explicit unavailable state
      # for a system administrator without an organization. A member of neither
      # kind hits the shared required clause, so the refusal is the login page and
      # its reason - not the administrator surface that member cannot use.
      assert {:error,
              {:redirect,
               %{
                 to: "/users/log_in",
                 flash: %{
                   "error" =>
                     "Your account has no organization assigned. Contact an administrator."
                 }
               }}} = live(log_in_user(build_conn(), actor), "/alerts")
    end
  end

  # -- Fixtures ------------------------------------------------------------

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
