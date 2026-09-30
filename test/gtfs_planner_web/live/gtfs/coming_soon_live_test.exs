defmodule GtfsPlannerWeb.Gtfs.ComingSoonLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

  # The standalone placeholder destinations with the area bar each one must
  # render, the link it must mark current, and the tab count of that bar. Flex
  # left this list with step 19: `/flex` is `Gtfs.FlexLive`'s list now.
  @standalone_destinations [
    %{
      path: "/rosters",
      title: "Rosters",
      sections: 4,
      bar: "#operations-sub-nav",
      current: "/rosters",
      tabs: 3
    }
  ]

  @placeholder_paths [
    "/rosters"
  ]

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, version: version}
  end

  defp member_with_roles(organization, roles) do
    member = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: member.id,
      organization_id: organization.id,
      roles: roles
    })

    member
  end

  describe "placeholder destinations" do
    setup :editor_setup

    for destination <- @standalone_destinations do
      test "#{destination.path} renders #{destination.title} with its area navigation",
           %{conn: conn, user: user, organization: organization, version: version} do
        conn = log_in_user(conn, user, organization: organization)

        {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{unquote(destination.path)}")

        doc = LazyHTML.from_fragment(render(view))

        assert Enum.count(LazyHTML.query(doc, "h1")) == 1

        assert LazyHTML.text(LazyHTML.query(doc, "h1")) |> String.trim() ==
                 unquote(destination.title)

        assert LazyHTML.text(LazyHTML.query(doc, "#coming-soon-scope")) |> String.trim() ==
                 "This version: #{version.name}"

        assert Enum.count(LazyHTML.query(doc, "#coming-soon-sections li")) ==
                 unquote(destination.sections)

        assert has_element?(view, "#coming-soon-status", "Coming soon")

        bar = unquote(destination.bar)

        assert Enum.count(LazyHTML.query(doc, "#{bar} a")) == unquote(destination.tabs)

        assert LazyHTML.attribute(
                 LazyHTML.query(doc, "#{bar} a[aria-current='page']"),
                 "href"
               ) == ["/gtfs/#{version.id}#{unquote(destination.current)}"]

        assert Enum.count(LazyHTML.query(doc, "#{bar} a[aria-current='page']")) == 1
      end
    end
  end

  describe "access" do
    setup :editor_setup

    test "members without the editor role cannot reach any placeholder destination",
         %{conn: conn, organization: organization, version: version} do
      for roles <- [[], ["pathways_studio_admin"]] do
        member = member_with_roles(organization, roles)
        member_conn = log_in_user(conn, member, organization: organization)

        for path <- @placeholder_paths do
          assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
                   live(member_conn, "/gtfs/#{version.id}#{path}")
        end
      end
    end

    test "unauthenticated visits follow the existing login redirect", %{version: version} do
      conn = build_conn() |> init_test_session(%{})

      for path <- @placeholder_paths do
        assert redirected_to(get(conn, "/gtfs/#{version.id}#{path}")) == "/users/log_in"
      end
    end

    test "missing, staging and foreign-organization versions redirect to the dashboard",
         %{conn: conn, user: user, organization: organization} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      for version_id <- [Ecto.UUID.generate(), staging.id, foreign_version.id] do
        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
                 live(conn, "/gtfs/#{version_id}/rosters")
      end
    end
  end

  describe "version switching" do
    setup :editor_setup

    test "an explicit selection keeps the action in the new version",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      for path <- ["/rosters"] do
        {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{path}")

        render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

        assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})

        assert_redirect(view, "/gtfs/#{other_version.id}#{path}")
      end
    end

    test "a stored selection navigates to the same action in the new version",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/rosters")

      render_hook(view, "gtfs_version_loaded", %{"version_id" => to_string(other_version.id)})

      assert_redirect(view, "/gtfs/#{other_version.id}/rosters")
      refute_push_event(view, "gtfs_version_selected", %{version_id: _})
    end

    test "a stored selection of the current version changes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/rosters")

      for version_id <- [to_string(version.id), nil] do
        render_hook(view, "gtfs_version_loaded", %{"version_id" => version_id})
        refute_redirected(view)
      end
    end

    test "staging, foreign and absent selections neither navigate nor report a selection",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/rosters")

      for version_id <- [staging.id, foreign_version.id, Ecto.UUID.generate()] do
        render_hook(view, "switch_gtfs_version", %{"version" => to_string(version_id)})
        refute_push_event(view, "gtfs_version_selected", %{version_id: _})
        refute_redirected(view)
      end
    end
  end
end
