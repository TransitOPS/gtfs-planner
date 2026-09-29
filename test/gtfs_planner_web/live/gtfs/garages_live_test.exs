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

  @garages_path "/settings/garages"
  @fleet_path "/settings/fleet"

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

  # The retired Blocks path segments are assembled here so the retired paths
  # appear only in the negative assertion that they are unrecognized.
  defp retired_blocks_path(version_id, page) do
    "/gtfs/#{version_id}/" <> Enum.join(["blocks", page], "/")
  end

  defp main_nav_current(doc) do
    LazyHTML.query(doc, "nav[aria-label='Main navigation'] a[aria-current='page']")
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

  describe "Settings navigation and scope" do
    setup :editor_setup

    test "the Garages page leads back to Settings and says what its garages apply to", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      assert has_element?(view, "h1", "Garages")

      assert has_element?(
               view,
               "a#settings-back[href='/gtfs/#{version.id}/settings']",
               "Settings"
             )

      assert has_element?(
               view,
               "#garages-scope",
               "Applies to every service version at #{organization.name}."
             )

      assert has_element?(
               view,
               "#garages-scope",
               "only which stops the ID check compares against"
             )

      # The Settings back link replaces the tab bar, and a Settings page carries no
      # current main-navigation task.
      refute has_element?(view, "#settings-nav")
      assert Enum.empty?(main_nav_current(LazyHTML.from_fragment(render(view))))
    end

    test "the Fleet page leads back to Settings and says what its vehicles apply to", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@fleet_path}")

      assert has_element?(view, "h1", "Fleet")

      assert has_element?(
               view,
               "a#settings-back[href='/gtfs/#{version.id}/settings']",
               "Settings"
             )

      assert has_element?(
               view,
               "#fleet-scope",
               "Applies to every service version at #{organization.name}."
             )

      refute has_element?(view, "#settings-nav")
      assert Enum.empty?(main_nav_current(LazyHTML.from_fragment(render(view))))
    end
  end

  describe "retired Blocks routes" do
    setup :editor_setup

    test "the retired Blocks paths are not recognized", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      for page <- ["garages", "fleet"] do
        retired = get(conn, retired_blocks_path(version.id, page))

        assert retired.status == 404
        refute retired.resp_body =~ "Add your first garage"
      end
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

    test "a foreign-organization or absent selection changes nothing through either event", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      for version_id <- [foreign_version.id, Ecto.UUID.generate()] do
        render_hook(view, "switch_gtfs_version", %{"version" => to_string(version_id)})
        refute_push_event(view, "gtfs_version_selected", %{version_id: _})
        refute_redirected(view)

        render_hook(view, "gtfs_version_loaded", %{"version_id" => to_string(version_id)})
        refute_redirected(view)
      end
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
      assert has_element?(view, "#add-garage-empty", "Create garage")
      assert has_element?(view, "#garages-first-use-empty #import-tods", "Import garages")
      refute has_element?(view, "#garages-table")
      refute has_element?(view, "#garages-status")
      refute has_element?(view, "#garage-conflicts")
    end

    test "the header offers create and import only once a garage exists", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, empty_view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")
      refute has_element?(empty_view, "#add-garage")

      garage_fixture(organization.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      assert has_element?(view, "#add-garage", "Create garage")
      assert has_element?(view, "#import-tods", "Import garages")
      refute has_element?(view, "#garages-first-use-empty")
    end
  end

  describe "garage list" do
    setup :editor_setup

    test "#garages-table shows name, ID, location, vehicles and a filtered Fleet link", %{
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

      # A garage with vehicles links its count to the Fleet list filtered to it.
      assert has_element?(
               view,
               "tr#garages-#{with_address.id} td[data-label='Vehicles'] a[href='/gtfs/#{version.id}#{@fleet_path}?garage=#{with_address.id}']",
               "2 vehicles"
             )

      # A garage without vehicles says so instead of linking to an empty list.
      assert has_element?(
               view,
               "tr#garages-#{without_address.id} td[data-label='Vehicles']",
               "None yet"
             )

      refute has_element?(view, "tr#garages-#{without_address.id} a")

      assert has_element?(view, "#garages-status", "2 garages · 2 vehicles assigned")
    end

    test "a single garage and a single vehicle are counted in the singular", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      garage = garage_fixture(organization.id)
      vehicle_fixture(organization.id, %{"garage_id" => garage.id})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      assert has_element?(view, "#garages-status", "1 garage · 1 vehicle assigned")

      assert has_element?(
               view,
               "tr#garages-#{garage.id} td[data-label='Vehicles'] a",
               "1 vehicle"
             )
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

      assert has_element?(
               view,
               "#garage-conflicts",
               "Operations export is blocked: 1 garage ID matches a stop"
             )

      conflicts_html = view |> element("#garage-conflicts") |> render()

      assert conflicts_html =~ conflict.name
      assert conflicts_html =~ conflict.garage_id
      assert conflicts_html =~ "Shared stop"
      refute conflicts_html =~ other_version_garage.garage_id
      refute conflicts_html =~ "Only in V2"
    end

    test "several matches are counted in the title and each named beside its stop", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      garage_fixture(organization.id, %{"garage_id" => "STOP_A", "name" => "North yard"})
      garage_fixture(organization.id, %{"garage_id" => "STOP_B", "name" => "South yard"})
      stop_fixture(organization.id, version.id, %{stop_id: "STOP_A", stop_name: "Alder Street"})
      stop_fixture(organization.id, version.id, %{stop_id: "STOP_B", stop_name: "Birch Street"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")

      assert has_element?(
               view,
               "#garage-conflicts",
               "Operations export is blocked: 2 garage IDs match stops"
             )

      assert has_element?(view, "#garage-conflicts", "Give each garage below a different ID")
      assert has_element?(view, "#garage-conflicts li", "North yard")
      assert has_element?(view, "#garage-conflicts li", "Birch Street")
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
