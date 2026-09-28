defmodule GtfsPlannerWeb.Gtfs.BlocksLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

  @subtitle "A block is one vehicle's sequence of trips."

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

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  describe "the Blocks page shell" do
    setup :editor_setup

    test "an editor sees the heading, its subtitle and the Operations sub-navigation",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      assert page_title(view) == "Blocks · Pathways Studio"

      doc = LazyHTML.from_fragment(render(view))

      assert Enum.count(LazyHTML.query(doc, "#blocks-page")) == 1
      assert Enum.count(LazyHTML.query(doc, "h1")) == 1
      assert LazyHTML.text(LazyHTML.query(doc, "h1")) |> String.trim() == "Blocks"

      assert LazyHTML.text(LazyHTML.query(doc, "#blocks-page p")) |> String.trim() ==
               @subtitle

      assert Enum.count(LazyHTML.query(doc, "#operations-sub-nav a")) == 3

      assert LazyHTML.attribute(LazyHTML.query(doc, "#operations-tab-blocks"), "aria-current") ==
               ["page"]

      assert Enum.count(LazyHTML.query(doc, "#operations-sub-nav a[aria-current='page']")) == 1

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#operations-sub-nav a[aria-current='page']"),
               "href"
             ) == [blocks_path(version.id)]
    end

    test "mounting the page leaves the URL on /blocks",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      # A mount-time patch reports itself to this process as a navigation
      # message. The page owns no URL state, so a link to /blocks must not be
      # rewritten before the user does anything.
      refute_received {_ref, {:patch, _topic, _opts}}
      refute_redirected(view)
    end
  end

  describe "access" do
    setup :editor_setup

    test "a member without the editor role cannot reach the page",
         %{conn: conn, organization: organization, version: version} do
      for roles <- [[], ["pathways_studio_admin"]] do
        member = member_with_roles(organization, roles)
        member_conn = log_in_user(conn, member, organization: organization)

        assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
                 live(member_conn, blocks_path(version.id))
      end
    end

    test "an unauthenticated visit follows the login redirect", %{version: version} do
      conn = build_conn() |> init_test_session(%{})

      assert redirected_to(get(conn, blocks_path(version.id))) == "/users/log_in"
    end

    test "missing, staging and foreign-organization versions redirect to the dashboard",
         %{conn: conn, user: user, organization: organization} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      for version_id <- [Ecto.UUID.generate(), staging.id, foreign_version.id] do
        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
                 live(conn, blocks_path(version_id))
      end
    end
  end

  describe "version switching" do
    setup :editor_setup

    test "an explicit selection keeps the page in the new version",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

      assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})
      assert_redirect(view, blocks_path(other_version.id))
    end

    test "a stored selection navigates to the same page in the new version",
         %{conn: conn, user: user, organization: organization, version: version} do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

      render_hook(view, "gtfs_version_loaded", %{"version_id" => to_string(other_version.id)})

      assert_redirect(view, blocks_path(other_version.id))
      refute_push_event(view, "gtfs_version_selected", %{version_id: _})
    end

    test "a stored selection of the current version changes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, blocks_path(version.id))

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
      {:ok, view, _html} = live(conn, blocks_path(version.id))

      for version_id <- [staging.id, foreign_version.id, Ecto.UUID.generate()] do
        render_hook(view, "switch_gtfs_version", %{"version" => to_string(version_id)})
        refute_push_event(view, "gtfs_version_selected", %{version_id: _})
        refute_redirected(view)
      end
    end
  end
end
