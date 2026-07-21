defmodule GtfsPlannerWeb.DashboardLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import Ecto.Query

  @state_roots [
    "#dashboard-system-administrator",
    "#dashboard-organization",
    "#dashboard-no-version",
    "#dashboard-no-organization",
    "#dashboard-organization-unavailable",
    "#dashboard-no-task-access"
  ]

  describe "Dashboard authentication" do
    test "redirects unauthenticated users to login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, ~p"/")
    end
  end

  describe "Dashboard state matrix" do
    test "system administrator renders system administration root and primary manage organizations",
         %{conn: conn} do
      admin = system_administrator_fixture()
      conn = log_in_user(conn, admin)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-system-administrator")
      assert_single_h1(html, "System administration")
      assert html =~ admin.email

      assert has_element?(
               view,
               "#dashboard-system-administrator a.btn-primary[href=\"/admin/organizations\"]",
               "Manage organizations"
             )

      refute has_element?(view, "a.btn-active")
      refute html =~ "Welcome to Pathways Studio"
      refute has_element?(view, "a[href^=\"/gtfs/\"]")
      refute_tenant_disclosure(html)
    end

    test "editor with published version renders organization root and primary view routes", %{
      conn: conn
    } do
      {organization, version} = org_with_published_version("Editor Org")
      user = member_fixture(organization, ["pathways_studio_editor"])
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-organization")
      assert_single_h1(html, organization.name)

      assert has_element?(
               view,
               "#dashboard-organization a.btn-primary[href=\"/gtfs/#{version.id}/routes\"]",
               "View routes"
             )

      refute has_element?(view, "a", "Manage users")
      refute has_element?(view, "a.btn-active")
      refute html =~ "Welcome to Pathways Studio"
    end

    test "organization admin with published version renders primary manage users only", %{
      conn: conn
    } do
      {organization, _version} = org_with_published_version("Admin Org")
      user = member_fixture(organization, ["pathways_studio_admin"])
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-organization")
      assert_single_h1(html, organization.name)

      assert has_element?(
               view,
               "#dashboard-organization a.btn-primary[href=\"/admin/users\"]",
               "Manage users"
             )

      refute has_element?(view, "a", "View routes")
      refute has_element?(view, "a.btn-active")
    end

    test "editor plus organization admin renders primary view routes and secondary manage users",
         %{conn: conn} do
      {organization, version} = org_with_published_version("Both Roles Org")

      user =
        member_fixture(organization, ["pathways_studio_editor", "pathways_studio_admin"])

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-organization")
      assert_single_h1(html, organization.name)

      assert has_element?(
               view,
               "#dashboard-organization a.btn-primary[href=\"/gtfs/#{version.id}/routes\"]",
               "View routes"
             )

      assert has_element?(
               view,
               "#dashboard-organization a.btn-outline[href=\"/admin/users\"]",
               "Manage users"
             )

      refute has_element?(view, "a.btn-primary", "Manage users")
      refute has_element?(view, "a.btn-active")
    end

    test "active membership without published version renders no-version warning without gtfs links",
         %{conn: conn} do
      # create_organization seeds a published default; clear all versions so the
      # published-only latest query returns nil (staging-only is equivalent).
      organization = organization_fixture(%{name: "No Published Version Org"})
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization.id))
      {:ok, _staging} =
        Versions.create_staging_gtfs_version(organization.id, %{name: "Staging Only"})

      user = member_fixture(organization, ["pathways_studio_editor"])
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-no-version")
      assert_single_h1(html, organization.name)
      assert html =~ "No published GTFS version"
      refute has_element?(view, "a[href^=\"/gtfs/\"]")
      refute has_element?(view, "a", "View routes")
      refute has_element?(view, "a.btn-active")
      refute html =~ "Welcome to Pathways Studio"
    end

    test "missing session organization renders no-organization root without tenant metadata", %{
      conn: conn
    } do
      organization = organization_fixture(%{name: "Secret Tenant Name"})
      user = member_fixture(organization, ["pathways_studio_editor"])
      {:ok, _version} = Versions.create_gtfs_version(organization.id, %{name: "Hidden Version"})

      # Authenticated without organization_id in session → optional :missing.
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-no-organization")
      assert_single_h1(html, "Dashboard")
      refute html =~ organization.name
      refute html =~ "Hidden Version"
      refute html =~ "pathways_studio_editor"
      refute has_element?(view, "a[href^=\"/gtfs/\"]")
      refute has_element?(view, "a[href=\"/admin/users\"]")
      refute has_element?(view, "a[href=\"/admin/organizations\"]")
      assert html =~ "Organization access is required"
      assert html =~ "Contact an administrator"
    end

    test "stale or cross-tenant session organization renders unavailable without existence oracle",
         %{conn: _conn} do
      own_org = organization_fixture(%{name: "Own Tenant"})
      other_org = organization_fixture(%{name: "Other Tenant"})
      user = member_fixture(own_org, ["pathways_studio_editor"])
      {:ok, _} = Versions.create_gtfs_version(own_org.id, %{name: "Own Version"})
      missing_id = Ecto.UUID.generate()

      for {label, org_id, forbidden_name} <- [
            {"absent", missing_id, nil},
            {"cross-tenant", other_org.id, other_org.name}
          ] do
        conn =
          build_conn()
          |> log_in_user(user)
          |> Plug.Conn.put_session(:organization_id, org_id)

        {:ok, view, html} = live(conn, ~p"/")

        assert has_element?(view, "#dashboard-organization-unavailable"),
               "#{label} must render unavailable root"

        assert_single_state_root(view, "#dashboard-organization-unavailable")
        assert_single_h1(html, "Dashboard")
        refute html =~ own_org.name
        refute html =~ "Own Version"
        refute html =~ "pathways_studio_editor"

        if forbidden_name do
          refute html =~ forbidden_name
        end

        refute has_element?(view, "a[href^=\"/gtfs/\"]")
        refute has_element?(view, "a[href=\"/admin/users\"]")
        refute has_element?(view, "a[href=\"/admin/organizations\"]")
      end
    end

    test "active membership with no permitted product task renders no-task root", %{conn: conn} do
      {organization, _version} = org_with_published_version("No Task Org")
      # Membership exists but neither editor nor organization-admin product role.
      user = member_fixture(organization, [])
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, ~p"/")

      assert_single_state_root(view, "#dashboard-no-task-access")
      assert_single_h1(html, organization.name)
      refute has_element?(view, "a", "View routes")
      refute has_element?(view, "a", "Manage users")
      refute has_element?(view, "a[href^=\"/gtfs/\"]")
      refute has_element?(view, "a[href=\"/admin/users\"]")
      refute has_element?(view, "a.btn-active")
    end

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

      {:ok, renamed_other} = Versions.update_gtfs_version(non_current, %{name: "Renamed Other"})

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

      {:ok, renamed_current} = Versions.update_gtfs_version(current, %{name: "Renamed Current"})

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
