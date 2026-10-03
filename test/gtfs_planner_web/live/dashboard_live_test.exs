defmodule GtfsPlannerWeb.DashboardLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Home
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import Ecto.Query

  @state_roots [
    "#dashboard-system-administrator",
    "#dashboard-no-organization",
    "#dashboard-organization-unavailable",
    "#dashboard-no-version",
    "#dashboard-no-task-access",
    "#home-admin-only",
    "#home-planner",
    "#home-pathways"
  ]

  describe "Dashboard authentication" do
    test "redirects unauthenticated users to login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/")
    end
  end

  describe "Dashboard state matrix" do
    test "a system administrator sees the organizations card and one primary action", %{
      conn: conn
    } do
      admin = system_administrator_fixture()
      conn = log_in_user(conn, admin)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-system-administrator")
      assert_single_h1(html, "System administration")
      assert has_element?(view, "#home-lede", organization_count_label())
      assert has_element?(view, "#system-admin", "Organizations")

      assert has_element?(
               view,
               "#dashboard-system-administrator a[href='/admin/organizations'].bg-action",
               "Manage organizations"
             )

      assert has_element?(
               view,
               "#dashboard-system-administrator a[href='/admin/organizations/new']",
               "Create organization"
             )

      assert_at_most_one_primary(html)
      refute has_element?(view, "a[href^='/gtfs/']")
      refute_tenant_disclosure(html)
    end

    test "a session without an organization sees the no-organization state without tenant data",
         %{conn: conn} do
      organization = organization_fixture(%{name: "Secret Tenant Name"})
      admin = member_fixture(organization, ["pathways_studio_admin"])
      {:ok, _version} = Versions.create_gtfs_version(organization.id, %{name: "Hidden Version"})
      user = member_fixture(organization, ["pathways_studio_editor"])

      # Authenticated without organization_id in session → optional :missing.
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-no-organization")
      assert_single_h1(html, "Home")

      assert has_element?(
               view,
               "#dashboard-no-organization",
               "Your account is not part of an organization yet"
             )

      assert has_element?(
               view,
               "#dashboard-no-organization a[href='/users/log_out']",
               "Log out"
             )

      assert has_element?(view, "#user-menu-panel", user.email)

      refute html =~ organization.name
      refute html =~ admin.email
      refute html =~ "Hidden Version"
      refute has_element?(view, "a[href^='/gtfs/']")
      refute has_element?(view, "a[href='/admin/users']")
      refute has_element?(view, "a[href='/admin/organizations']")
      refute_tenant_disclosure(html)
      assert_at_most_one_primary(html)
    end

    test "a session naming an unknown organization sees the unavailable state", %{conn: conn} do
      own_org = organization_fixture(%{name: "Own Tenant"})
      admin = member_fixture(own_org, ["pathways_studio_admin"])
      user = member_fixture(own_org, ["pathways_studio_editor"])
      {:ok, _version} = Versions.create_gtfs_version(own_org.id, %{name: "Own Version"})

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session(:organization_id, Ecto.UUID.generate())

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-organization-unavailable")
      assert_single_h1(html, "Home")

      assert has_element?(
               view,
               "#dashboard-organization-unavailable",
               "Your account is not part of an organization yet"
             )

      assert has_element?(
               view,
               "#dashboard-organization-unavailable a[href='/users/log_out']",
               "Log out"
             )

      refute html =~ own_org.name
      refute html =~ "Own Version"
      refute html =~ admin.email
      refute has_element?(view, "a[href^='/gtfs/']")
      refute has_element?(view, "a[href='/admin/users']")
      refute has_element?(view, "a[href='/admin/organizations']")
      refute_tenant_disclosure(html)
      assert_at_most_one_primary(html)
    end

    test "a session naming another organization sees the unavailable state without its data",
         %{conn: conn} do
      own_org = organization_fixture(%{name: "Own Tenant"})
      user = member_fixture(own_org, ["pathways_studio_editor"])
      other_org = organization_fixture(%{name: "Other Tenant"})
      other_admin = member_fixture(other_org, ["pathways_studio_admin"])
      {:ok, _version} = Versions.create_gtfs_version(other_org.id, %{name: "Other Version"})

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session(:organization_id, other_org.id)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-organization-unavailable")
      assert_single_h1(html, "Home")
      refute html =~ own_org.name
      refute html =~ other_org.name
      refute html =~ other_admin.email
      refute html =~ "Other Version"
      refute has_element?(view, "a[href^='/gtfs/']")
      refute has_element?(view, "a[href='/admin/users']")
      refute has_element?(view, "a[href='/admin/organizations']")
      refute_tenant_disclosure(html)
    end

    test "a member without a published version sees the no-version state with the active administrators",
         %{conn: conn} do
      # create_organization seeds a published default; clear all versions so the
      # published-only latest query returns nil (staging-only is equivalent).
      organization = organization_fixture(%{name: "No Published Version Org"})
      delete_versions!(from(v in GtfsVersion, where: v.organization_id == ^organization.id))

      {:ok, _staging} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Staging Only"})

      admin = member_fixture(organization, ["pathways_studio_admin"])

      deactivated_admin = member_fixture(organization, ["pathways_studio_admin"])

      {:ok, _} =
        Organizations.deactivate_user_in_organization(
          admin,
          deactivated_admin.id,
          organization.id
        )

      user = member_fixture(organization, ["pathways_studio_editor"])
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-no-version")
      assert_single_h1(html, organization.name)

      assert has_element?(
               view,
               "#dashboard-no-version",
               "There is no service data to work on yet"
             )

      assert has_element?(view, "#org-admins", admin.email)
      refute has_element?(view, "#org-admins", deactivated_admin.email)
      refute has_element?(view, "a[href^='/gtfs/']")
      refute has_element?(view, "a[href='/admin/users']")
      assert_at_most_one_primary(html)
    end

    test "a Pathways organization without a version keeps the shared no-version copy", %{
      conn: conn
    } do
      organization = organization_fixture(%{name: "Pathways No Version Org", product: :pathways})
      delete_versions!(from(v in GtfsVersion, where: v.organization_id == ^organization.id))

      {:ok, _staging} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Staging Only"})

      user = member_fixture(organization, ["pathways_studio_editor"])
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-no-version")
      assert_single_h1(html, organization.name)

      assert has_element?(
               view,
               "#dashboard-no-version",
               "There is no service data to work on yet"
             )

      # An access state renders no region, so a retry for a working page's
      # region must not load one against the missing version.
      render_click(view, "retry", %{"region" => "status"})

      assert_single_state_root(view, "#dashboard-no-version")
    end

    test "a member with no editing role sees the no-task state with the active administrators",
         %{conn: conn} do
      {organization, _version} = org_with_published_version("No Task Org")
      admin = member_fixture(organization, ["pathways_studio_admin"])

      deactivated_admin = member_fixture(organization, ["pathways_studio_admin"])

      {:ok, _} =
        Organizations.deactivate_user_in_organization(
          admin,
          deactivated_admin.id,
          organization.id
        )

      # Membership exists but neither editor nor organization-admin product role.
      user = member_fixture(organization, [])
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-no-task-access")
      assert_single_h1(html, organization.name)

      assert has_element?(
               view,
               "#dashboard-no-task-access",
               "Your account is in #{organization.name} but cannot edit yet"
             )

      assert has_element?(view, "#org-admins", admin.email)
      refute has_element?(view, "#org-admins", deactivated_admin.email)
      refute has_element?(view, "a[href^='/gtfs/']")
      refute has_element?(view, "a[href='/admin/users']")
      assert_at_most_one_primary(html)
    end

    test "an organization administrator without an editing role sees the admin-only state",
         %{conn: conn} do
      {organization, _version} = org_with_published_version("Admin Only Org")
      admin = member_fixture(organization, ["pathways_studio_admin"])
      active_member = member_fixture(organization, ["pathways_studio_editor"])

      deactivated = member_fixture(organization, ["pathways_studio_editor"])

      {:ok, _} =
        Organizations.deactivate_user_in_organization(admin, deactivated.id, organization.id)

      conn = log_in_user(conn, admin, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#home-admin-only")
      assert_single_h1(html, organization.name)
      assert has_element?(view, "#home-admin-only", "People at #{organization.name}")

      # Two active members: the administrator and the editor. The deactivated
      # member is not counted.
      assert has_element?(view, "#home-admin-only", "2 people have access today.")
      refute html =~ active_member.email

      assert has_element?(
               view,
               "#home-admin-only a[href='/admin/users'].bg-action",
               "Manage users"
             )

      assert has_element?(
               view,
               "#home-admin-only a[href='/admin/users/organization-settings']",
               "Organization settings"
             )

      assert has_element?(
               view,
               "#home-admin-only",
               "Editing routes, calendars and stops needs the Editor role."
             )

      refute has_element?(view, "#home-admin-only a[href^='/gtfs/']")
      assert_at_most_one_primary(html)
    end

    test "a Pathways organization administrator gets the Pathways wording", %{conn: conn} do
      organization = organization_fixture(%{name: "Pathways Admin Org", product: :pathways})

      {:ok, _version} =
        Versions.create_gtfs_version(organization.id, %{name: "Pathways Published"})

      admin = member_fixture(organization, ["pathways_studio_admin"])

      conn = log_in_user(conn, admin, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#home-admin-only")
      assert_single_h1(html, organization.name)
      assert has_element?(view, "#home-admin-only", "so they can map stations")
      assert has_element?(view, "#home-admin-only", "Editing stations needs the Editor role.")
      assert has_element?(view, "#app-brand-logo[src='/images/pathways-studio-logo.svg']")

      assert has_element?(
               view,
               "#home-admin-only a[href='/admin/users'].bg-action",
               "Manage users"
             )

      assert_at_most_one_primary(html)
    end

    test "an editor in a planner organization sees the planner page head", %{conn: conn} do
      {organization, version} = org_with_published_version("Planner Editor Org")
      user = member_fixture(organization, ["pathways_studio_editor"])

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#home-planner")
      assert_single_h1(html, version.name)
      refute has_element?(view, "#users-strip")
      assert_one_primary_after_regions_load(view)
    end

    test "an editor in a pathways organization sees the station board head", %{conn: conn} do
      organization = organization_fixture(%{name: "Pathways Editor Org", product: :pathways})

      {:ok, _version} =
        Versions.create_gtfs_version(organization.id, %{name: "Pathways Published"})

      user = member_fixture(organization, ["pathways_studio_editor"])

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#home-pathways")
      assert_single_h1(html, "Stations")
      assert has_element?(view, "#app-brand-logo[src='/images/pathways-studio-logo.svg']")
      refute has_element?(view, "#users-strip")
      assert_one_primary_after_regions_load(view)
    end

    test "an editor who is also an organization administrator sees the People row", %{conn: conn} do
      {organization, version} = org_with_published_version("Editor Admin Org")

      user =
        member_fixture(organization, ["pathways_studio_editor", "pathways_studio_admin"])

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#home-planner")
      assert_single_h1(html, version.name)
      assert has_element?(view, "#users-strip")
      assert_one_primary_after_regions_load(view)
    end
  end

  describe "Dashboard source constraints" do
    test "does not load context aliases or duplicate Accounts Organizations Versions queries in module",
         %{conn: conn} do
      source = File.read!("lib/gtfs_planner_web/live/dashboard_live.ex")

      refute source =~ "alias GtfsPlanner.Accounts"
      refute source =~ "alias GtfsPlanner.Organizations"
      refute source =~ "alias GtfsPlanner.Versions"
      refute source =~ "get_user_org_context"
      refute source =~ "get_gtfs_version_context"
      refute source =~ "handle_info"

      # Smoke: still mounts via hook-owned assigns.
      admin = system_administrator_fixture()
      conn = log_in_user(conn, admin)
      assert {:ok, _view, _html} = live(conn, ~p"/")
    end
  end

  describe "handle_info({:gtfs_version_renamed, _}, socket) via AssignOrganization hook" do
    test "refreshes available_versions and leaves current_gtfs_version unchanged when a non-current version is renamed",
         %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_admin"]
      })

      {:ok, _newest} = Versions.create_gtfs_version(organization.id, %{name: "Newest Version"})

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session(:organization_id, organization.id)

      {:ok, view, _html} = live(conn, ~p"/")

      assigns_before = :sys.get_state(view.pid).socket.assigns
      current_id_before = assigns_before.current_gtfs_version.id

      {non_current_id, _name} =
        Enum.find(assigns_before.available_versions, fn {id, _name} -> id != current_id_before end)

      non_current = Versions.get_published_gtfs_version_for_org!(organization.id, non_current_id)
      original_name = non_current.name

      editor = editor_fixture(organization)
      scope = %{actor_id: editor.id, organization_id: organization.id}

      {:ok, renamed_other} =
        Versions.update_gtfs_version(scope, non_current.id, %{name: "Renamed Other"})

      send(view.pid, {:gtfs_version_renamed, renamed_other})
      _ = render(view)

      assigns_after = :sys.get_state(view.pid).socket.assigns

      assert assigns_after.current_gtfs_version.id == current_id_before
      assert {non_current_id, "Renamed Other"} in assigns_after.available_versions
      refute {non_current_id, original_name} in assigns_after.available_versions
    end

    test "updates current_gtfs_version when the renamed version is the current one",
         %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_admin"]
      })

      {:ok, _other} = Versions.create_gtfs_version(organization.id, %{name: "Other Version"})

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session(:organization_id, organization.id)

      {:ok, view, _html} = live(conn, ~p"/")

      assigns_before = :sys.get_state(view.pid).socket.assigns
      current = assigns_before.current_gtfs_version

      editor = editor_fixture(organization)
      scope = %{actor_id: editor.id, organization_id: organization.id}

      {:ok, renamed_current} =
        Versions.update_gtfs_version(scope, current.id, %{name: "Renamed Current"})

      send(view.pid, {:gtfs_version_renamed, renamed_current})
      _ = render(view)

      assigns_after = :sys.get_state(view.pid).socket.assigns

      assert assigns_after.current_gtfs_version.id == current.id
      assert assigns_after.current_gtfs_version.name == "Renamed Current"
      assert {current.id, "Renamed Current"} in assigns_after.available_versions
    end

    test "is a safe no-op for administrators without a current_organization", %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["administrator"]
      })

      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/")

      assigns_before = :sys.get_state(view.pid).socket.assigns
      assert assigns_before.current_organization == nil
      assert assigns_before.current_gtfs_version == nil
      assert assigns_before.organization_context_status == :system_administrator

      send(view.pid, {:gtfs_version_renamed, %{id: Ecto.UUID.generate(), name: "X"}})
      _ = render(view)

      assigns_after = :sys.get_state(view.pid).socket.assigns
      assert assigns_after.current_organization == nil
      assert assigns_after.current_gtfs_version == nil
      assert assigns_after.available_versions == assigns_before.available_versions
    end
  end

  defp system_administrator_fixture do
    admin = user_fixture()
    org = organization_fixture()

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: admin.id,
        organization_id: org.id,
        roles: ["administrator"]
      })

    admin
  end

  defp member_fixture(organization, roles) do
    user = user_fixture()

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: roles
      })

    user
  end

  defp org_with_published_version(name) do
    organization = organization_fixture(%{name: name})
    {:ok, version} = Versions.create_gtfs_version(organization.id, %{name: "Published"})
    {organization, version}
  end

  defp assert_single_state_root(view, expected_id) do
    assert has_element?(view, expected_id)

    for id <- @state_roots, id != expected_id do
      refute has_element?(view, id)
    end
  end

  defp assert_single_h1(html, expected_text) do
    h1s = Regex.scan(~r/<h1[^>]*>(.*?)<\/h1>/s, html)

    assert length(h1s) == 1, "expected exactly one H1, got #{length(h1s)}"

    [[_full, inner]] = h1s
    text = inner |> strip_tags() |> String.trim()
    assert text == expected_text
  end

  defp assert_at_most_one_primary(html) do
    primaries =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(".bg-action")
      |> Enum.to_list()

    assert length(primaries) <= 1,
           "expected at most one primary action, found #{length(primaries)}"
  end

  # A working page's primary action lives in its async regions, so the count is
  # only meaningful once they have loaded. The wait allows for the full suite's
  # database load.
  defp assert_one_primary_after_regions_load(view) do
    primaries =
      view
      |> render_async(2_000)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".bg-action")
      |> Enum.to_list()

    assert length(primaries) == 1,
           "expected exactly one primary action, found #{length(primaries)}"
  end

  defp organization_count_label do
    case Home.organization_count() do
      1 -> "1 organization"
      count -> "#{count} organizations"
    end
  end

  defp strip_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
  end

  defp refute_tenant_disclosure(html) do
    # System admin must not surface another tenant's identity from session noise.
    refute html =~ "pathways_studio_editor"
    refute html =~ "pathways_studio_admin"
  end
end
