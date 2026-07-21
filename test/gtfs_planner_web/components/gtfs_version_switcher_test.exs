defmodule GtfsPlannerWeb.Components.GtfsVersionSwitcherTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  defmodule HostLive do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      current = GtfsPlanner.Repo.get!(GtfsVersion, session["current_version_id"])
      versions = Versions.list_gtfs_versions_for_dropdown(session["organization_id"])

      {:ok,
       socket
       |> Phoenix.Component.assign(:current_version, current)
       |> Phoenix.Component.assign(:versions, versions)
       |> Phoenix.Component.assign(:organization_id, session["organization_id"])}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={GtfsPlannerWeb.Components.GtfsVersionSwitcher}
        id="gtfs-version-switcher"
        current_version={@current_version}
        versions={@versions}
        organization_id={@organization_id}
      />
      """
    end

    def handle_info({:gtfs_version_renamed, _}, socket) do
      org_id = socket.assigns.organization_id
      versions = Versions.list_gtfs_versions_for_dropdown(org_id)

      current =
        Versions.get_published_gtfs_version_for_org!(org_id, socket.assigns.current_version.id)

      {:noreply,
       socket
       |> Phoenix.Component.assign(:versions, versions)
       |> Phoenix.Component.assign(:current_version, current)}
    end

    def handle_info({:swap_current_version, version_id}, socket) do
      version =
        Versions.get_published_gtfs_version_for_org!(socket.assigns.organization_id, version_id)

      {:noreply, Phoenix.Component.assign(socket, :current_version, version)}
    end

    def handle_info(_, socket), do: {:noreply, socket}
  end

  setup do
    org = organization_fixture()
    {:ok, current} = Versions.create_gtfs_version(org.id, %{name: "Current Version"})
    {:ok, other} = Versions.create_gtfs_version(org.id, %{name: "Other Version"})
    %{org: org, current: current, other: other}
  end

  defp mount_host(conn, current, org) do
    live_isolated(conn, HostLive,
      session: %{"current_version_id" => current.id, "organization_id" => org.id}
    )
  end

  describe "rename affordance" do
    test "renders a rename item as the first row in the dropdown", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      assert has_element?(view, "#gtfs-version-panel #gtfs-version-rename", "Rename version")
    end

    test "rename item has a 44px-minimum target", %{conn: conn, current: current, org: org} do
      {:ok, view, _html} = mount_host(conn, current, org)

      html =
        view
        |> element("#gtfs-version-rename")
        |> render()

      assert html =~ "min-h-11"
    end
  end

  describe "edit mode" do
    test "clicking rename reveals the form prefilled with current name", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element("#gtfs-version-rename")
      |> render_click()

      assert has_element?(view, "#gtfs-version-rename-form")

      form_html = view |> element("#gtfs-version-rename-form") |> render()
      # Prefilled via the input value; the label stays a short, stable noun so a
      # long current name cannot distort the inline editor.
      assert form_html =~ ~s(value="Current Version")
      assert form_html =~ "Version name"
    end

    test "validate surfaces duplicate-name error", %{
      conn: conn,
      current: current,
      org: org,
      other: other
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element("#gtfs-version-rename")
      |> render_click()

      html =
        view
        |> form("#gtfs-version-rename-form", gtfs_version: %{name: other.name})
        |> render_change()

      assert html =~ "A version with this name already exists"
    end

    test "cancel exits edit mode without updating the DB", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element("#gtfs-version-rename")
      |> render_click()

      assert has_element?(view, "#gtfs-version-rename-form")

      view
      |> element("#gtfs-version-rename-form button[phx-click=\"cancel_edit\"]")
      |> render_click()

      refute has_element?(view, "#gtfs-version-rename-form")
      assert Versions.get_published_gtfs_version_for_org!(org.id, current.id).name == current.name
    end
  end

  describe "save" do
    test "valid new name persists and exits edit mode", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element("#gtfs-version-rename")
      |> render_click()

      view
      |> form("#gtfs-version-rename-form", gtfs_version: %{name: "Renamed Version"})
      |> render_submit()

      refute has_element?(view, "#gtfs-version-rename-form")
      assert has_element?(view, "#gtfs-version-panel [data-version-option]", "Renamed Version")

      assert Versions.get_published_gtfs_version_for_org!(org.id, current.id).name ==
               "Renamed Version"
    end

    test "duplicate name keeps form visible and does not modify the DB", %{
      conn: conn,
      current: current,
      org: org,
      other: other
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element("#gtfs-version-rename")
      |> render_click()

      html =
        view
        |> form("#gtfs-version-rename-form", gtfs_version: %{name: other.name})
        |> render_submit()

      assert html =~ "A version with this name already exists"
      assert has_element?(view, "#gtfs-version-rename-form")

      assert Versions.get_published_gtfs_version_for_org!(org.id, current.id).name ==
               "Current Version"
    end

    test "trims surrounding whitespace before persisting", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element("#gtfs-version-rename")
      |> render_click()

      view
      |> form("#gtfs-version-rename-form", gtfs_version: %{name: "  Renamed  "})
      |> render_submit()

      refute has_element?(view, "#gtfs-version-rename-form")
      assert Versions.get_published_gtfs_version_for_org!(org.id, current.id).name == "Renamed"
    end

    test "submitting the unchanged current name succeeds without a duplicate error", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element("#gtfs-version-rename")
      |> render_click()

      html =
        view
        |> form("#gtfs-version-rename-form", gtfs_version: %{name: current.name})
        |> render_submit()

      refute html =~ "A version with this name already exists"
      refute has_element?(view, "#gtfs-version-rename-form")
      assert Versions.get_published_gtfs_version_for_org!(org.id, current.id).name == current.name
    end
  end

  describe "edit state reset" do
    test "exits edit mode when the parent swaps current_version", %{
      conn: conn,
      current: current,
      org: org,
      other: other
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element("#gtfs-version-rename")
      |> render_click()

      assert has_element?(view, "#gtfs-version-rename-form")

      send(view.pid, {:swap_current_version, other.id})
      _ = render(view)

      refute has_element?(view, "#gtfs-version-rename-form")

      form_html = view |> element("#gtfs-version-switcher") |> render()
      assert form_html =~ "Other Version"
    end
  end

  describe "pending and failure regions" do
    test "renders a hidden pending element with switching copy", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      assert has_element?(view, "#gtfs-version-pending[hidden]")
      pending_html = view |> element("#gtfs-version-pending") |> render()
      assert pending_html =~ "Switching version"
    end

    test "renders a hidden failure region with retry button", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      assert has_element?(view, "#gtfs-version-failure[hidden]")
      assert has_element?(view, "#gtfs-version-retry")
    end

    test "pending element carries no live-region announcement contract (decision 0.12)", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      pending_html = view |> element("#gtfs-version-pending") |> render()
      assert pending_html =~ "Switching version"
      refute pending_html =~ "aria-live"
    end

    test "failure region carries no alert-role announcement contract (decision 0.12)", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      failure_html = view |> element("#gtfs-version-failure") |> render()
      assert failure_html =~ "Version switch failed"
      refute failure_html =~ ~s(role="alert")
    end
  end

  describe "rename pending state" do
    test "rename submit button shows task-specific pending label", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element("#gtfs-version-rename")
      |> render_click()

      submit_html = view |> element("#gtfs-version-rename-form button[type=submit]") |> render()
      assert submit_html =~ ~s(phx-disable-with="Saving name…")
    end
  end

  describe "published-only options" do
    test "switcher options exclude staging, importing, and failed versions", %{
      conn: conn,
      current: current,
      org: org
    } do
      {:ok, staging} = Versions.create_staging_gtfs_version(org.id, %{name: "Staging Version"})

      {:ok, importing_staging} =
        Versions.create_staging_gtfs_version(org.id, %{name: "Importing Version"})

      {:ok, _importing} = Versions.claim_staging_gtfs_version(org.id, importing_staging.id)

      {:ok, failed_staging} =
        Versions.create_staging_gtfs_version(org.id, %{name: "Failed Version"})

      {:ok, _failed} = Versions.fail_unpublished_gtfs_version(org.id, failed_staging.id)

      {:ok, view, _html} = mount_host(conn, current, org)

      assert has_element?(view, "#gtfs-version-panel [data-version-option]", "Current Version")
      assert has_element?(view, "#gtfs-version-panel [data-version-option]", "Other Version")
      refute has_element?(view, "#gtfs-version-panel [data-version-option]", "Staging Version")
      refute has_element?(view, "#gtfs-version-panel [data-version-option]", "Importing Version")
      refute has_element?(view, "#gtfs-version-panel [data-version-option]", "Failed Version")

      refute has_element?(
               view,
               ~s(#gtfs-version-panel [data-version-option][data-version-id="#{staging.id}"])
             )
    end
  end

  describe "AssignOrganization refresh hook" do
    setup %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()

      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_admin"]
      })

      {:ok, older} = Versions.create_gtfs_version(organization.id, %{name: "Older Version"})
      {:ok, newer} = Versions.create_gtfs_version(organization.id, %{name: "Newer Version"})

      conn =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_session(:organization_id, organization.id)

      # AssignOrganization picks the latest (most-recently-created) as current.
      %{conn: conn, organization: organization, current: newer, non_current: older}
    end

    test "refreshes available_versions and updates current_gtfs_version when the current version is renamed",
         %{conn: conn, current: current} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      {:ok, renamed} = Versions.update_gtfs_version(current, %{name: "Newer Renamed"})
      send(view.pid, {:gtfs_version_renamed, renamed})
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.current_gtfs_version.id == current.id
      assert assigns.current_gtfs_version.name == "Newer Renamed"
      assert {current.id, "Newer Renamed"} in assigns.available_versions
    end

    test "refreshes available_versions but leaves current_gtfs_version unchanged when a non-current version is renamed",
         %{conn: conn, current: current, non_current: non_current} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assigns_before = :sys.get_state(view.pid).socket.assigns
      assert assigns_before.current_gtfs_version.id == current.id
      assert assigns_before.current_gtfs_version.name == current.name

      {:ok, renamed_other} = Versions.update_gtfs_version(non_current, %{name: "Older Renamed"})
      send(view.pid, {:gtfs_version_renamed, renamed_other})
      _ = render(view)

      assigns_after = :sys.get_state(view.pid).socket.assigns

      assert assigns_after.current_gtfs_version.id == current.id
      assert assigns_after.current_gtfs_version.name == current.name

      assert {non_current.id, "Older Renamed"} in assigns_after.available_versions
      refute {non_current.id, "Older Version"} in assigns_after.available_versions
      assert {current.id, current.name} in assigns_after.available_versions
    end
  end
end
