defmodule GtfsPlannerWeb.Gtfs.AlertSettingsLiveTest do
  @moduledoc """
  Step 23: Settings › Alerts manages the organization's message scripts and
  writing guidelines, and a built-in script is read-only (AC-24, AC-11, FH-24).

  Every expectation is a literal: the eight built-in keys and names from
  `GtfsPlanner.Alerts.BuiltInScripts`, the eight built-in row ids the page
  builds, the changeset error `AlertScript.changeset/2` writes for an unknown
  placeholder, and the two sentences the card fixes ("Someone else changed these
  guidelines. Reload to see their version." and the forbidden notice). Nothing
  here recomputes an expectation with the module under test.

  Scripts are stored only through `Alerts.create_script/2` and
  `Alerts.copy_built_in_script/2`, guidelines only through
  `Alerts.save_guidelines/3`, and every read is `Alerts.list_scripts/1` or
  `Alerts.get_guidelines/1`, so a row this file proves exists is a row an editor
  path can write.

  The forbidden case reaches `{:error, :forbidden}` the only way it is reachable
  in the application: `EnsureRole` refuses a member without the editor role at
  mount, so the membership is revoked while the drawer is open and the next save
  is what the command refuses. `GtfsPlanner.Authorization.Roles` defines no
  viewer role, so an empty role list is what a member without it holds.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.AlertSettings
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  # The eight built-in scripts, in the order `BuiltInScripts.scripts/0` lists
  # them. A built-in row's id is `builtin-<key>`, so its copy button is
  # `#copy-builtin-<key>`.
  @built_in_keys ~w(
    detour
    delay
    stop_moved
    stop_closed
    no_service_day
    accessibility
    rider_information
    suspension
  )

  # The organization script this file writes through the production command.
  @org_script %{
    "name" => "Route detour",
    "situation" => "detour",
    "header_template" => "[route] detour: [stop] not served",
    "description_template" =>
      "[route] toward [direction] is not serving [stop]. Board at [alternate stop] instead."
  }

  @placeholder_error_prefix "names \"[headline]\", which this app does not fill in."

  @stale_guidelines "Someone else changed these guidelines. Reload to see their version."
  @forbidden_notice "You no longer have permission to change the organization's alert wording."

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fall 2026 service"})
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "the scripts tab" do
    setup :editor_conn

    test "organization scripts come first, then the read-only built-ins", context do
      {:ok, org_script} = Alerts.create_script(context.audit, @org_script)

      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#scripts tr")
        |> LazyHTML.attribute("id")

      assert Enum.take(ids, 1) == [org_script.id]
      assert Enum.drop(ids, 1) == Enum.map(@built_in_keys, &"builtin-#{&1}")

      # The built-ins are the read-only ones: each has a copy control and no
      # Edit, which is what keeps a default uniform across tenants.
      for key <- @built_in_keys do
        assert has_element?(view, "#copy-builtin-#{key}")
        refute has_element?(view, "#edit-script-builtin-#{key}")
      end

      assert has_element?(view, "#edit-script-#{org_script.id}", "Edit")
      assert has_element?(view, "#scripts-status", "1 script of your own")
      assert has_element?(view, "#scripts-status", "8 built-ins to copy")
    end

    test "an organization with no scripts of its own still reads the built-ins", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "#scripts-status", "0 scripts of your own")
      assert has_element?(view, "#copy-builtin-detour")
      refute has_element?(view, "#scripts-first-use")
    end

    test "the built-in rows name the situation a script is offered for", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      assert has_element?(view, "#script-for-builtin-detour", "Detour")
      assert has_element?(view, "#script-for-builtin-no_service_day", "Cancelled departures")
    end

    test "the page carries no publication state or action", context do
      {:ok, _view, html} = live(context.conn, alerts_path(context.version))

      for word <- ["Publish", "Schedule", "Data sent to apps", "Alert feed"] do
        refute html =~ word
      end
    end
  end

  describe "the script drawer" do
    setup :editor_conn

    test "Create script opens the drawer with the placeholder reference", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      html =
        view
        |> element("#create-script")
        |> render_click()

      assert html =~ "Create script"
      assert has_element?(view, "#script-form")
      assert has_element?(view, "#script-name")
      assert has_element?(view, "#script-situation")

      # Every placeholder the fill can replace is named, so an operator writes a
      # template the vocabulary can actually fill.
      for placeholder <- ["route", "direction", "stop", "first skipped", "when", "minutes"] do
        assert has_element?(view, "#fill-in-#{placeholder}")
      end

      assert has_element?(view, "#script-save", "Create script")
    end

    test "a refused save shows the field error and keeps what was typed", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      view |> element("#create-script") |> render_click()

      html =
        view
        |> form("#script-form", %{
          "script" => %{
            "name" => "Detour notice",
            "situation" => "detour",
            "header_template" => "[route] detour: [headline]",
            "description_template" => "[route] is not serving [stop]."
          }
        })
        |> render_submit()

      # The error is on the field that caused it, and the entered templates are
      # still in the form: a refusal must not cost the operator their wording.
      assert has_element?(view, "#script-header-error", @placeholder_error_prefix)
      assert has_element?(view, "#script-header[value='[route] detour: [headline]']")
      assert has_element?(view, "#script-description[value='[route] is not serving [stop].']")
      assert html =~ "Script not saved"
      assert has_element?(view, "#script-form")

      # Nothing was stored.
      assert own_script_names(context.audit) == []
    end

    test "a saved script is listed, then edited through the drawer", context do
      {:ok, _script} = Alerts.create_script(context.audit, @org_script)
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      html =
        view
        |> element("#script-name-#{Enum.at(Alerts.list_scripts(context.audit), 0).id}")
        |> render_click()

      assert html =~ "Edit script"
      assert has_element?(view, "#script-name[value='Route detour']")
      assert has_element?(view, "#script-save", "Save changes")

      view
      |> form("#script-form", %{
        "script" => %{
          "name" => "Route detour notice",
          "situation" => "detour",
          "header_template" => "[route] detour: [first skipped] not served",
          "description_template" => "[route] toward [direction] is not serving [first skipped]."
        }
      })
      |> render_submit()

      assert has_element?(view, "#script-notice", "Route detour notice saved.")

      assert has_element?(
               view,
               "#script-name-#{Enum.at(Alerts.list_scripts(context.audit), 0).id}"
             )
    end

    test "Copy to edit creates an organization script and opens it in the drawer", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      html =
        view
        |> element("#copy-builtin-detour")
        |> render_click()

      assert html =~ "Edit script"

      scripts = Alerts.list_scripts(context.audit)
      copy = Enum.find(scripts, &(&1.name == "Detour, stops skipped"))

      # The copy carries the built-in's own wording unchanged, so an
      # organization starts from the recommended wording rather than a blank.
      assert copy.built_in? == false

      assert copy.header_template ==
               "Route [route] detour: [first skipped] to [last skipped] not served"

      assert copy.description_template =~ "[when], Route [route] buses [direction] are detoured"

      # It is now an editable organization row: it has an Edit and no copy
      # control, and the drawer is open on that row's own id.
      assert has_element?(view, "#edit-script-#{copy.id}")
      refute has_element?(view, "#copy-builtin-detour")
      assert has_element?(view, "#script-name[value='Detour, stops skipped']")
    end

    test "copying the same built-in twice is a second variant, not a failure", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      view |> element("#copy-builtin-detour") |> render_click()
      view |> element("#script-cancel") |> render_click()
      view |> element("#copy-builtin-detour") |> render_click()

      names =
        context.audit
        |> Alerts.list_scripts()
        |> Enum.filter(&(not &1.built_in?))
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["Detour, stops skipped", "Detour, stops skipped (2)"]
    end

    test "delete removes the organization's own script only", context do
      {:ok, org_script} = Alerts.create_script(context.audit, @org_script)
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      view |> element("#script-name-#{org_script.id}") |> render_click()
      html = view |> element("#script-delete") |> render_click()

      assert html =~ "Route detour deleted."
      refute has_element?(view, "#edit-script-#{org_script.id}")
      assert has_element?(view, "#copy-builtin-detour")
    end

    test "a revoked role saves nothing and reports the forbidden outcome", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version))

      view |> element("#create-script") |> render_click()
      revoke_editor_role!(context.actor, context.organization)

      html =
        view
        |> form("#script-form", %{
          "script" => %{
            "name" => "Too late",
            "situation" => "detour",
            "header_template" => "[route] detour",
            "description_template" => "[route] is not serving [stop]."
          }
        })
        |> render_submit()

      assert html =~ @forbidden_notice

      # Nothing was written and the drawer is still open with the draft in it.
      assert own_script_names(context.audit) == []

      assert has_element?(view, "#script-name[value='Too late']")
    end
  end

  describe "the guidelines tab" do
    setup :editor_conn

    test "?tab=guidelines shows the recommended text at revision 0", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version) <> "?tab=guidelines")

      assert has_element?(view, "#guidelines-tab[aria-selected='true']")
      assert has_element?(view, "#guidelines-revision", "Recommended guidelines, not changed yet")
      assert has_element?(view, "#save-guidelines", "Save guidelines")

      # Reading settings never writes a row (AC-11).
      assert Repo.aggregate(AlertSettings, :count) == 0
    end

    test "Save guidelines stores the text and advances the revision", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version) <> "?tab=guidelines")

      view
      |> form("#guidelines-form", %{
        "guidelines" => %{"guidelines" => "Our own wording.", "revision" => "0"}
      })
      |> render_submit()

      assert has_element?(view, "#guidelines-notice", "Guidelines saved.")
      assert has_element?(view, "#guidelines-revision", "Revision 1")
      assert Alerts.get_guidelines(context.audit) == %{text: "Our own wording.", revision: 1}
    end

    test "a stale revision is refused with the conflict sentence and overwrites nothing",
         context do
      {:ok, _first} = Alerts.save_guidelines(context.audit, "First wording.", 0)

      {:ok, view, _html} = live(context.conn, alerts_path(context.version) <> "?tab=guidelines")

      html =
        view
        |> form("#guidelines-form", %{
          "guidelines" => %{"guidelines" => "Older wording.", "revision" => "0"}
        })
        |> render_submit()

      assert html =~ @stale_guidelines
      assert has_element?(view, "#guidelines-notice", @stale_guidelines)
      assert has_element?(view, "#guidelines-reload")

      # The other save stands and this one kept its text.
      assert Alerts.get_guidelines(context.audit) == %{text: "First wording.", revision: 1}
      assert has_element?(view, "#guidelines-text[value='Older wording.']")

      view |> element("#guidelines-reload") |> render_click()
      refute has_element?(view, "#guidelines-reload")
      assert has_element?(view, "#guidelines-text[value='First wording.']")
    end

    test "a revoked role saves nothing and reports the forbidden outcome", context do
      {:ok, _first} = Alerts.save_guidelines(context.audit, "First wording.", 0)
      {:ok, view, _html} = live(context.conn, alerts_path(context.version) <> "?tab=guidelines")

      revoke_editor_role!(context.actor, context.organization)

      html =
        view
        |> form("#guidelines-form", %{
          "guidelines" => %{"guidelines" => "Too late.", "revision" => "1"}
        })
        |> render_submit()

      assert html =~ @forbidden_notice
      assert Alerts.get_guidelines(context.audit) == %{text: "First wording.", revision: 1}
    end

    test "an unknown tab falls back to the scripts tab rather than raising", context do
      {:ok, view, _html} = live(context.conn, alerts_path(context.version) <> "?tab=feed")

      assert has_element?(view, "#scripts-table")
      refute has_element?(view, "#guidelines-card")
    end
  end

  describe "access" do
    setup :editor_conn

    test "a member without the editor role cannot reach the page", context do
      member = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: member.id,
        organization_id: context.organization.id,
        roles: []
      })

      conn = log_in_user(build_conn(), member, organization: context.organization)

      assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
               live(conn, alerts_path(context.version))
    end

    test "the page reaches its own page ahead of the section route", context do
      conn = log_in_user(build_conn(), context.actor, organization: context.organization)

      # "alerts" is a built destination, so it never reaches `SettingsLive`'s
      # section lookup, which would answer "That settings section doesn’t exist."
      assert {:ok, view, _html} = live(conn, alerts_path(context.version))
      assert has_element?(view, "#alert-settings-page")
      assert has_element?(view, "#alert-settings-tabs")
    end
  end

  defp editor_conn(context) do
    %{
      context
      | conn: log_in_user(build_conn(), context.actor, organization: context.organization)
    }
  end

  defp alerts_path(version), do: "/gtfs/#{version.id}/settings/alerts"

  # The organization's own scripts only: `Alerts.list_scripts/1` also returns the
  # read-only built-ins, and a refusal here is about the page's own writes.
  defp own_script_names(audit) do
    audit
    |> Alerts.list_scripts()
    |> Enum.reject(& &1.built_in?)
    |> Enum.map(& &1.name)
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

  defp revoke_editor_role!(user, organization) do
    membership = Accounts.get_user_org_membership(user.id, organization.id)
    {:ok, _revoked} = Accounts.update_user_org_membership(membership, %{roles: []})
  end
end
