defmodule GtfsPlannerWeb.Components.GtfsVersionSwitcherTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.OrganizationsFixtures

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
      current = Versions.get_gtfs_version!(socket.assigns.current_version.id)

      {:noreply,
       socket
       |> Phoenix.Component.assign(:versions, versions)
       |> Phoenix.Component.assign(:current_version, current)}
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
    test "renders an accessible rename button", %{conn: conn, current: current, org: org} do
      {:ok, view, _html} = mount_host(conn, current, org)

      assert has_element?(
               view,
               ~s(#gtfs-version-switcher [aria-label="Rename version"][title="Rename version"])
             )
    end

    test "rename button has a 44px-minimum target", %{conn: conn, current: current, org: org} do
      {:ok, view, _html} = mount_host(conn, current, org)

      html =
        view
        |> element(~s(#gtfs-version-switcher [aria-label="Rename version"]))
        |> render()

      assert html =~ "min-h-11"
      assert html =~ "h-11"
      assert html =~ "w-11"
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
      |> element(~s(#gtfs-version-switcher [aria-label="Rename version"]))
      |> render_click()

      assert has_element?(view, "#gtfs-version-rename-form")

      form_html = view |> element("#gtfs-version-rename-form") |> render()
      assert form_html =~ ~s(value="Current Version")
    end

    test "validate surfaces duplicate-name error", %{
      conn: conn,
      current: current,
      org: org,
      other: other
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element(~s(#gtfs-version-switcher [aria-label="Rename version"]))
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
      |> element(~s(#gtfs-version-switcher [aria-label="Rename version"]))
      |> render_click()

      assert has_element?(view, "#gtfs-version-rename-form")

      view
      |> element("#gtfs-version-rename-form button[phx-click=\"cancel_edit\"]")
      |> render_click()

      refute has_element?(view, "#gtfs-version-rename-form")
      assert Versions.get_gtfs_version!(current.id).name == current.name
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
      |> element(~s(#gtfs-version-switcher [aria-label="Rename version"]))
      |> render_click()

      view
      |> form("#gtfs-version-rename-form", gtfs_version: %{name: "Renamed Version"})
      |> render_submit()

      refute has_element?(view, "#gtfs-version-rename-form")
      assert has_element?(view, "#gtfs-version-select option", "Renamed Version")
      assert Versions.get_gtfs_version!(current.id).name == "Renamed Version"
    end

    test "duplicate name keeps form visible and does not modify the DB", %{
      conn: conn,
      current: current,
      org: org,
      other: other
    } do
      {:ok, view, _html} = mount_host(conn, current, org)

      view
      |> element(~s(#gtfs-version-switcher [aria-label="Rename version"]))
      |> render_click()

      html =
        view
        |> form("#gtfs-version-rename-form", gtfs_version: %{name: other.name})
        |> render_submit()

      assert html =~ "A version with this name already exists"
      assert has_element?(view, "#gtfs-version-rename-form")
      assert Versions.get_gtfs_version!(current.id).name == "Current Version"
    end
  end
end
