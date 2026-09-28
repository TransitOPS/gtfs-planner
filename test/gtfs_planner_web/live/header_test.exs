defmodule GtfsPlannerWeb.HeaderTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  describe "Header - Unauthenticated Users (Auth Layout)" do
    test "displays Pathways Studio brand with semantic tokens", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      html = html_response(conn, 200)

      assert html =~ "text-brand"
      assert html =~ "Pathways Studio"
      assert html =~ "bg-brand"
    end

    test "does not display logout button", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      html = html_response(conn, 200)

      refute html =~ "/users/log_out"
    end

    test "auth layout uses semantic border not shadow", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      html = html_response(conn, 200)

      assert html =~ "border-base-300"
      refute html =~ "shadow"
    end
  end

  describe "Header - Authenticated Users" do
    test "displays the GTFS Planner logo brand link without an organization", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#app-brand[aria-label='GTFS Planner, go to home']"
             )

      assert has_element?(
               view,
               "#app-brand-logo[src='/images/gtfs-planner-logo.svg']"
             )

      brand_html = view |> element("#app-brand") |> render()
      assert brand_html =~ ~s(alt="")

      # Logo only: no divider and no organization name without an organization.
      refute has_element?(view, "#app-brand span")

      # The header no longer carries the text wordmark; only the logo image remains.
      refute has_element?(view, "#app-brand .font-display")
    end

    test "shows the organization name inside the brand link", %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#app-brand span.text-muted",
               organization.name
             )
    end

    test "omits the divider and organization name when there is no organization", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#app-brand-logo")
      refute has_element?(view, "#app-brand span")
    end

    test "a Planner editor gets the GTFS Planner logo with the organization name", %{
      conn: conn
    } do
      organization = organization_fixture(%{product: :planner})
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#app-brand[aria-label='GTFS Planner, go to home']"
             )

      assert has_element?(
               view,
               "#app-brand-logo[src='/images/gtfs-planner-logo.svg']"
             )

      brand_html = view |> element("#app-brand") |> render()
      assert brand_html =~ ~s(alt="")
      assert brand_html =~ organization.name
      assert has_element?(view, "#app-brand span[aria-hidden='true']")
    end

    test "a Pathways editor gets the Pathways Studio logo with the organization name", %{
      conn: conn
    } do
      organization = organization_fixture(%{product: :pathways})
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#app-brand[aria-label='Pathways Studio, go to home']"
             )

      assert has_element?(
               view,
               "#app-brand-logo[src='/images/pathways-studio-logo.svg']"
             )

      brand_html = view |> element("#app-brand") |> render()
      assert brand_html =~ ~s(alt="")
      assert brand_html =~ organization.name
      assert has_element?(view, "#app-brand span[aria-hidden='true']")
    end

    test "a system administrator without an organization gets the Planner logo only", %{
      conn: conn
    } do
      admin = user_fixture()
      membership_org = organization_fixture()

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: admin.id,
          organization_id: membership_org.id,
          roles: ["administrator"]
        })

      conn = log_in_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations")

      assert has_element?(
               view,
               "#app-brand[aria-label='GTFS Planner, go to home']"
             )

      assert has_element?(
               view,
               "#app-brand-logo[src='/images/gtfs-planner-logo.svg']"
             )

      refute has_element?(view, "#app-brand span")
    end

    test "account menu trigger is labeled and paneled with the email", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      # The visible trigger is the account's initials; identity is in the
      # accessible name and the panel.
      trigger_html =
        view
        |> element("#app-header #user-menu [data-user-menu-trigger][aria-haspopup='menu']")
        |> render()

      assert trigger_html =~ user.email
      assert trigger_html =~ "bg-navy-100"
      refute trigger_html =~ "hero-user-circle"
      assert has_element?(view, "#user-menu-panel", "Signed in as")
      assert has_element?(view, "#user-menu-panel", user.email)
    end

    test "log out is a menu item with visible label and 44px target", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#user-menu-panel a[href='/users/log_out'][role='menuitem']",
               "Log out"
             )

      assert has_element?(view, "#user-menu-panel a[href='/users/log_out'].min-h-11")
    end

    test "logout item uses correct method and path", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "href=\"/users/log_out\""
      assert html =~ "data-method=\"delete\""
      assert has_element?(view, "#user-menu-panel a[href='/users/log_out']")
    end

    test "header wraps without horizontal overflow", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#app-header .flex-wrap")
    end

    test "navigation renders inside the header", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#app-header nav#main-navigation[aria-label='Main navigation']")
    end

    test "role-aware main navigation is a plain link list without daisyUI pills", %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/routes")

      for {id, label} <- [
            {"nav-routes", "Routes"},
            {"nav-calendars", "Calendars"},
            {"nav-operations", "Operations"},
            {"nav-stops", "Stops & stations"},
            {"nav-flex", "Flex"},
            {"nav-gtfs", "GTFS"}
          ] do
        assert has_element?(view, "#main-navigation ##{id}", label)
      end

      assert has_element?(view, "#main-navigation #nav-routes[aria-current='page']")
      refute has_element?(view, "#main-navigation svg")
      assert has_element?(view, "#main-navigation #nav-gtfs[href='/gtfs/#{version.id}/export']")

      assert has_element?(
               view,
               "#main-navigation #nav-operations[href='/gtfs/#{version.id}/blocks']"
             )

      refute has_element?(view, "#main-navigation a[href$='/import']")
    end

    test "Profile settings lives in the account menu, not the task nav", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "#app-header #user-menu-panel a[href='/users/settings']",
               "Profile settings"
             )

      refute has_element?(
               view,
               "#app-header nav[aria-label='Main navigation'] a[href='/users/settings']"
             )
    end

    test "no Settings link renders in the main navigation for an editor", %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/routes")

      refute has_element?(view, "#main-navigation a[href*='settings']")

      assert has_element?(
               view,
               "#user-menu-panel #settings-link[href='/gtfs/#{version.id}/settings']"
             )
    end

    test "an editor's Settings entry is current on the version Settings family", %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/settings")

      assert has_element?(view, "#settings-link[aria-current='page']")
      assert has_element?(view, "[data-user-menu-trigger][data-current='true']")
    end

    test "an org-admin-only login opens the account menu and follows Settings to Users",
         %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_admin"]
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/")

      # The menu names the organization and gives the admin fallback copy.
      assert has_element?(view, "#user-menu-panel", organization.name)

      assert has_element?(
               view,
               "#user-menu-panel #settings-link[href='/admin/users'][role='menuitem']",
               "Settings"
             )

      assert has_element?(view, "#user-menu-panel #settings-link", "Organization name, users")

      # Following it reaches the unchanged Users page through the real router.
      assert {:error, {:live_redirect, %{to: "/admin/users"}}} =
               view |> element("#settings-link") |> render_click()
    end

    test "an org-admin-only login keeps Users reachable and marks Settings current",
         %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_admin"]
      })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#settings-link[href='/admin/users'][aria-current='page']")
      assert has_element?(view, "[data-user-menu-trigger][data-current='true']")
    end

    test "an editor without a version has no Settings item and no organization label",
         %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      # organization_fixture/1 seeds a default published version, so the
      # versionless editor state must be built explicitly: removing it makes
      # AssignOrganization assign a nil current_gtfs_version.
      Repo.delete_all(from v in GtfsVersion, where: v.organization_id == ^organization.id)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#settings-link")
      refute has_element?(view, "#user-menu-panel p.text-muted", organization.name)
    end

    test "an editor with a version keeps the version Settings as an organization administrator",
         %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor", "pathways_studio_admin"]
      })

      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/")

      # The version target wins over the organization-administrator fallback.
      assert has_element?(
               view,
               "#user-menu-panel #settings-link[href='/gtfs/#{version.id}/settings']"
             )

      assert has_element?(
               view,
               "#user-menu-panel #settings-link",
               "Agencies, fares, exports, garages, fleet"
             )
    end

    test "a login without an organization has no Settings item", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#settings-link")
    end

    test "the account trigger shows the viewer's initials", %{conn: conn} do
      user = user_fixture(%{email: "dana@northcoast.example"})
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#user-menu [data-user-menu-trigger] span", "D")
      assert has_element?(view, "#user-menu [data-user-menu-trigger] span.bg-navy-100")

      assert has_element?(
               view,
               "[data-user-menu-trigger][aria-label='Account menu for dana@northcoast.example']"
             )
    end

    test "Profile settings is active on settings and inactive on dashboard", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, settings_view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(
               settings_view,
               "#app-header #user-menu-panel a[href='/users/settings'][aria-current='page']",
               "Profile settings"
             )

      {:ok, dash_view, _html} = live(conn, ~p"/")

      refute has_element?(
               dash_view,
               "#app-header #user-menu-panel a[href='/users/settings'][aria-current='page']"
             )

      assert has_element?(
               dash_view,
               "#app-header #user-menu-panel a[href='/users/settings']:not([aria-current])"
             )
    end

    test "optional account context assigns status without requiring organization", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")

      # Dashboard remains reachable with no session organization (optional mode).
      assert html =~ "Pathways Studio"
      assert has_element?(view, "#dashboard-no-organization")
      assert has_element?(view, "#app-header #user-menu-panel a[href='/users/settings']")
    end

    test "design routes remain reachable without optional organization assigns", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/design/navigation")

      assert html =~ "Navigation"
      assert has_element?(view, "#ds-page-navigation")
      assert has_element?(view, "#app-header #user-menu-panel a[href='/users/settings']")
    end

    test "a Pathways editor sees four task areas and no Operations or Flex", %{conn: conn} do
      organization = organization_fixture(%{product: :pathways})
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/routes")

      for {id, label} <- [
            {"nav-routes", "Routes"},
            {"nav-calendars", "Calendars"},
            {"nav-stops", "Stops & stations"},
            {"nav-gtfs", "GTFS"}
          ] do
        assert has_element?(view, "#main-navigation ##{id}", label)
      end

      refute has_element?(view, "#main-navigation #nav-operations")
      refute has_element?(view, "#main-navigation #nav-flex")
    end

    test "a Planner editor's Settings entry points at version Settings", %{conn: conn} do
      organization = organization_fixture(%{product: :planner})
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/routes")

      assert has_element?(
               view,
               "#user-menu-panel #settings-link[href='/gtfs/#{version.id}/settings']",
               "Settings"
             )

      assert has_element?(
               view,
               "#user-menu-panel #settings-link",
               "Agencies, fares, exports, garages, fleet"
             )
    end

    test "a Pathways editor who is also an org admin gets the Users Settings entry", %{conn: conn} do
      organization = organization_fixture(%{product: :pathways})
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor", "pathways_studio_admin"]
      })

      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/routes")

      assert has_element?(
               view,
               "#user-menu-panel #settings-link[href='/admin/users']",
               "Settings"
             )

      assert has_element?(
               view,
               "#user-menu-panel #settings-link",
               "Organization name, users"
             )
    end

    test "a Pathways editor without admin has no Settings entry", %{conn: conn} do
      organization = organization_fixture(%{product: :pathways})
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/gtfs/#{version.id}/routes")

      refute has_element?(view, "#settings-link")
    end
  end

  describe "Document titles" do
    test "root title uses Pathways Studio suffix with page title", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "· Pathways Studio</title>"
      assert html =~ ~s(data-default="Pathways Studio")
      assert html =~ ~s(data-suffix=" · Pathways Studio")
    end

    test "settings title uses Pathways Studio shell", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/users/settings")

      assert html =~ "· Pathways Studio</title>"
      assert html =~ ~s(data-default="Pathways Studio")
      assert html =~ ~s(data-suffix=" · Pathways Studio")
    end

    test "auth page renders Pathways Studio brand", %{conn: conn} do
      conn = get(conn, ~p"/users/log_in")
      html = html_response(conn, 200)

      assert html =~ "Pathways Studio"
    end
  end
end
