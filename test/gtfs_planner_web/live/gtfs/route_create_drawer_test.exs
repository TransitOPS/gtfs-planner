defmodule GtfsPlannerWeb.Gtfs.RouteCreateDrawerTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts

  defp editor_scope(%{conn: conn}) do
    organization = organization_fixture()

    user =
      user_fixture(%{
        email: "route-create-drawer-#{System.unique_integer([:positive])}@example.com"
      })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp open_drawer(view) do
    view |> element("#new-route-trigger") |> render_click()
  end

  defp unused_route_params do
    fields =
      ~w(route_id route_short_name route_long_name route_type agency_id route_desc route_url route_color route_text_color)

    params =
      fields
      |> Map.new(&{&1, ""})
      |> Map.put("route_long_name", "Crosstown")

    Map.merge(params, Map.new(fields, &{"_unused_" <> &1, ""}))
  end

  describe "opening and validating" do
    setup :editor_scope

    test "Create route opens the drawer with the route form", %{conn: conn, version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      assert has_element?(view, "#new-route-form-panel #new-route-form")

      doc = LazyHTML.from_fragment(render(view))
      assert Enum.count(LazyHTML.query(doc, "[id='new-route-drawer']")) == 1

      option_values = LazyHTML.attribute(LazyHTML.query(doc, "#route_route_type option"), "value")
      assert Enum.count(option_values, &(&1 != "")) == 10
    end

    test "the drawer is closed until opened", %{conn: conn, version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#new-route-drawer-overlay[data-open='false']")
      refute has_element?(view, "#new-route-form")
    end

    test "agency select lists this version's agencies only", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      agency_fixture(organization.id, version.id, %{agency_id: "A1", agency_name: "Alpha Transit"})

      agency_fixture(organization.id, version.id, %{agency_id: "A2", agency_name: "Beta Transit"})

      other_version = gtfs_version_fixture(organization.id)

      agency_fixture(organization.id, other_version.id, %{
        agency_id: "A3",
        agency_name: "Gamma Transit"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      html = render(view)
      assert html =~ "Alpha Transit (A1)"
      assert html =~ "Beta Transit (A2)"
      refute html =~ "Gamma Transit (A3)"

      labels =
        LazyHTML.query(LazyHTML.from_fragment(html), "#new-route-form-panel label span.label")

      assert "Agency" in Enum.map(labels, &LazyHTML.text/1)
    end

    test "agency select is omitted when the version has no agencies", %{
      conn: conn,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      refute has_element?(view, "#route_agency_id")
    end

    test "trigger is secondary beside the first-use import action", %{
      conn: conn,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#new-route-trigger.btn-outline")

      assert has_element?(
               view,
               "#routes-first-use-empty",
               "Routes appear here after you import a GTFS feed or create a route."
             )

      assert has_element?(view, "#routes-first-use-empty", "Import feed")
    end

    test "trigger is primary on a populated catalog", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route_fixture(organization.id, version.id, %{route_id: "POP1"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#new-route-trigger.btn-primary")
    end

    test "closing clears the entered values", %{conn: conn, version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      view
      |> form("#new-route-form", route: %{route_long_name: "Crosstown"})
      |> render_change()

      view |> element("#new-route-drawer-close") |> render_click()
      refute has_element?(view, "#new-route-form")

      open_drawer(view)
      assert has_element?(view, "#route_route_long_name")
      refute has_element?(view, "#route_route_long_name[value='Crosstown']")
    end

    test "validation hides errors for unused fields", %{conn: conn, version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      render_change(view, "validate_new_route", %{"route" => unused_route_params()})

      refute has_element?(view, "#route_route_id-error")
      refute has_element?(view, "#route_route_type-error")
    end

    test "validation shows the error for a used blank field", %{conn: conn, version: version} do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      open_drawer(view)

      params = Map.delete(unused_route_params(), "_unused_route_id")

      render_change(view, "validate_new_route", %{"route" => params})

      assert has_element?(view, "#route_route_id-error")
    end
  end
end
