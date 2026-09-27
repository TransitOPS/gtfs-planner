defmodule GtfsPlannerWeb.Gtfs.GaragesLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

  @garages_path "/blocks/garages"
  @fleet_path "/blocks/fleet"

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

  defp member_without_editor_role(organization) do
    member =
      user_fixture(%{email: "garages-member-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: member.id,
      organization_id: organization.id,
      roles: []
    })

    member
  end

  defp blocks_pill(doc, version_id) do
    LazyHTML.query(
      doc,
      "nav[aria-label='Main navigation'] a[href='/gtfs/#{version_id}/blocks/garages']"
    )
  end

  defp sub_nav_links(doc) do
    doc
    |> LazyHTML.query("#blocks-sub-nav a")
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  describe "access" do
    setup :editor_setup

    test "an editor loads Garages on its normal route", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      assert has_element?(view, "#garages-first-use-empty", "Add your first garage")
    end

    test "a member without pathways_studio_editor is redirected from Garages and Fleet", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      member = member_without_editor_role(organization)

      for path <- [@garages_path, @fleet_path] do
        member_conn = log_in_user(conn, member, organization: organization)

        assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
                 live(member_conn, "/gtfs/#{version.id}#{path}")
      end
    end
  end

  describe "Blocks navigation and scope" do
    setup :editor_setup

    test "the Blocks pill is current on Garages and links to it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      doc = LazyHTML.from_fragment(render(view))

      pill = blocks_pill(doc, version.id)
      assert Enum.count(pill) == 1
      assert LazyHTML.attribute(pill, "aria-current") == ["page"]

      assert sub_nav_links(doc) == ["Garages", "Fleet"]

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#blocks-sub-nav a[aria-current='page']"),
               "href"
             ) == ["/gtfs/#{version.id}#{@garages_path}"]

      assert render(view) =~ "Shared across all service versions for #{organization.name}."
    end

    test "the Fleet route loads for an editor and keeps one current Blocks pill", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@fleet_path}")

      assert has_element?(view, "h1", "Fleet")

      doc = LazyHTML.from_fragment(render(view))

      pill = blocks_pill(doc, version.id)
      assert Enum.count(pill) == 1
      assert LazyHTML.attribute(pill, "aria-current") == ["page"]

      assert sub_nav_links(doc) == ["Garages", "Fleet"]

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#blocks-sub-nav a[aria-current='page']"),
               "href"
             ) == ["/gtfs/#{version.id}#{@fleet_path}"]

      assert render(view) =~ "Shared across all service versions for #{organization.name}."
    end
  end

  describe "version switching" do
    setup :editor_setup

    test "both version events navigate to Garages for the new version", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, other_version} = Versions.create_gtfs_version(organization.id, %{name: "V2"})

      {:ok, switch_view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")
      render_hook(switch_view, "switch_gtfs_version", %{"version" => to_string(other_version.id)})
      assert_redirect(switch_view, "/gtfs/#{other_version.id}#{@garages_path}")

      {:ok, loaded_view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      render_hook(loaded_view, "gtfs_version_loaded", %{
        "version_id" => to_string(other_version.id)
      })

      assert_redirect(loaded_view, "/gtfs/#{other_version.id}#{@garages_path}")
    end

    test "an unpublished version never navigates Garages", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      render_hook(view, "switch_gtfs_version", %{"version" => to_string(staging.id)})
      refute_redirected(view)
    end

    test "Fleet keeps its query string across a version switch", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, other_version} = Versions.create_gtfs_version(organization.id, %{name: "V2"})

      garage = garage_fixture(organization.id)
      query = "garage=#{garage.id}&q=bus"

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@fleet_path}?#{query}")

      render_hook(view, "switch_gtfs_version", %{"version" => to_string(other_version.id)})

      assert_redirect(view, "/gtfs/#{other_version.id}#{@fleet_path}?#{query}")
    end
  end

  describe "first use" do
    setup :editor_setup

    test "an organization without garages sees the empty state, not a table", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      assert has_element?(view, "#garages-first-use-empty", "Add your first garage")
      assert has_element?(view, "#add-garage-empty", "Add garage")
      refute has_element?(view, "#garages-table")
      refute has_element?(view, "#garages-status")
      refute has_element?(view, "#garage-conflicts")
    end
  end

  describe "garage list" do
    setup :editor_setup

    test "#garages-table shows name, ID, location, count and a filtered Fleet link", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      with_address =
        garage_fixture(organization.id, %{
          "garage_id" => "garage_main",
          "name" => "Main garage",
          "address" => "1 Depot Way"
        })

      without_address =
        garage_fixture(organization.id, %{
          "garage_id" => "garage_east",
          "name" => "East garage",
          "address" => nil
        })

      vehicle_fixture(organization.id, %{"garage_id" => with_address.id})
      vehicle_fixture(organization.id, %{"garage_id" => with_address.id})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      assert has_element?(view, "#garages-table")
      refute has_element?(view, "#garages-first-use-empty")

      assert has_element?(view, "tr#garages-#{with_address.id}", "Main garage")
      assert has_element?(view, "tr#garages-#{with_address.id}", "garage_main")
      assert has_element?(view, "tr#garages-#{with_address.id}", "1 Depot Way")
      assert has_element?(view, "tr#garages-#{with_address.id}", "40.7128, -74.0060")
      assert has_element?(view, "tr#garages-#{without_address.id}", "East garage")
      refute has_element?(view, "tr#garages-#{without_address.id}", "1 Depot Way")

      assert has_element?(
               view,
               "a[href='/gtfs/#{version.id}#{@fleet_path}?garage=#{with_address.id}']",
               "View vehicles"
             )

      doc = LazyHTML.from_fragment(render(view))
      counts = LazyHTML.query(doc, "#garages-table td[data-label='Vehicles']")

      assert Enum.count(counts) == 2
      assert LazyHTML.attribute(counts, "class") |> Enum.uniq() == ["text-right"]
      assert Enum.map(counts, &String.trim(LazyHTML.text(&1))) |> Enum.sort() == ["0", "2"]

      assert has_element?(view, "#garages-status", "2 garages · 2 vehicles assigned")
    end
  end

  describe "garage conflicts" do
    setup :editor_setup

    test "#garage-conflicts names current-version matches and ignores other versions", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      conflict =
        garage_fixture(organization.id, %{"garage_id" => "SHARED_STOP", "name" => "Depot"})

      other_version_garage = garage_fixture(organization.id, %{"garage_id" => "OTHER_STOP"})

      stop_fixture(organization.id, version.id, %{
        stop_id: "SHARED_STOP",
        stop_name: "Shared stop"
      })

      {:ok, other_version} = Versions.create_gtfs_version(organization.id, %{name: "V2"})

      stop_fixture(organization.id, other_version.id, %{
        stop_id: "OTHER_STOP",
        stop_name: "Only in V2"
      })

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      conflicts_html = view |> element("#garage-conflicts") |> render()

      assert conflicts_html =~ conflict.name
      assert conflicts_html =~ conflict.garage_id
      assert conflicts_html =~ "Shared stop"
      refute conflicts_html =~ other_version_garage.garage_id
      refute conflicts_html =~ "Only in V2"
    end

    test "no callout renders when no garage ID matches a stop", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      garage_fixture(organization.id, %{"garage_id" => "garage_far"})
      stop_fixture(organization.id, version.id, %{stop_id: "STOP1", stop_name: "A stop"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      refute has_element?(view, "#garage-conflicts")
    end
  end
end
