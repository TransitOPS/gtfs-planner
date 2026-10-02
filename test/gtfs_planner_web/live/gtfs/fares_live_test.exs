defmodule GtfsPlannerWeb.Gtfs.FaresLiveTest do
  @moduledoc """
  Merge evidence (EV-12) for the Fare zones workspace shell and its routes.

  Every case drives the real routes and the real `FareZones` reads, through the
  catalog adapter seam for the unavailable case and through the default Repo
  adapter for the ordinary entry, so the shell's state machine is proved end to
  end instead of against a private test-only interface:

  - The Zones path renders "Fares" with the Zones tab current and a way back to
    Settings.
  - A member without the editor role is redirected like every other Settings
    page, and an unauthenticated visit goes to the login page.
  - The disconnected render ships the skeleton and no tab panel.
  - `{:error, :unavailable}` renders the load-error callout; Reload against the
    restored default adapter renders the workspace panel.
  - An ordinary mount takes the default Repo adapter with no mock in place.
  - Version switching stays on the Zones tab.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Versions

  @adapter_key :gtfs_catalog_read_adapter

  # `[live action, path]` for the one destination this LiveView serves. The
  # editor owns Prices, Where fares apply, Transfers and Checks from step 32;
  # `fare_editor_live_test.exs` covers those, and this file keeps the Zones tab.
  @paths [zones: "/settings/fares/zones"]

  setup :verify_on_exit!

  setup do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)
  end

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, gtfs_version: gtfs_version}
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

  # The workspace load the mock returns. Counts and entries are literals, so the
  # shell cases cannot confirm their own output through the adapter.
  defp stub_workspace(overrides \\ %{}) do
    stub(CatalogReadAdapterMock, :load_fare_workspace, fn _organization_id, _version_id, _opts ->
      {:ok,
       Map.merge(
         %{
           inventory: %{
             zones: [
               %{
                 zone_id: "A",
                 name: "Central",
                 color: "ocean",
                 declared?: true,
                 stop_count: 0,
                 other_stop_count: 0,
                 rule_count: 0
               }
             ],
             unassigned_count: 0,
             boardable_count: 0
           },
           checks: %{
             stopless_referenced: [],
             unassigned_count: 0,
             empty_declared: [],
             rules_reference_zones?: false,
             combined_fares: []
           },
           stops: %{
             entries: [],
             total_count: 0,
             page: 1,
             per_page: 100,
             without_location_count: 0
           }
         },
         overrides
       )}
    end)
  end

  defp insert_zone(user, organization, version) do
    {:ok, zone} =
      FareZones.create_zone(
        %GtfsPlanner.Gtfs.AuditContext{
          actor_id: user.id,
          actor_email: user.email,
          organization_id: organization.id,
          gtfs_version_id: version.id
        },
        %{
          "name" => "Central",
          "zone_id" => "A",
          "color" => "ocean"
        }
      )

    zone
  end

  describe "workspace shell" do
    setup :editor_setup

    test "the Zones destination renders its workspace and shared tab strip", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_workspace()

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/settings/fares/zones")

      assert has_element?(view, "h1", "Fares")

      assert html =~
               "What riders pay and which fare each ride charges. Exports include both GTFS fare formats."

      assert has_element?(view, "#settings-back[href='/gtfs/#{version.id}/settings']", "Settings")
      refute has_element?(view, "#settings-nav")
      assert has_element?(view, "#fares-tab-zones[aria-current='page']")
      assert has_element?(view, "#fare-zones-panel")
      refute has_element?(view, "#fare-rules-panel")
      refute has_element?(view, "#fare-checks-panel")
    end

    test "the disconnected render ships the skeleton and no tab panel", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      for {_action, path} <- @paths do
        conn = get(conn, "/gtfs/#{version.id}#{path}")

        assert conn.status == 200
        doc = LazyHTML.from_fragment(conn.resp_body)

        assert Enum.count(LazyHTML.query(doc, "#fare-zones-loading[aria-busy='true']")) == 1
        assert LazyHTML.text(LazyHTML.query(doc, "#fare-zones-loading")) =~ "Loading fares…"
        assert Enum.empty?(LazyHTML.query(doc, "#fare-zones-panel"))
        # The issue count is unknown before the load resolves, so the tab claims
        # no badge rather than reporting a clean version.
        assert Enum.empty?(LazyHTML.query(doc, "#fares-checks-count"))
      end
    end

    test "a lost connection renders one recovery action, and Reload loads the workspace", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub(CatalogReadAdapterMock, :load_fare_workspace, fn _organization_id,
                                                            _version_id,
                                                            _opts ->
        {:error, :unavailable}
      end)

      insert_zone(user, organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares/zones")

      assert has_element?(view, "#fare-zones-error", "Fares couldn’t load")

      assert has_element?(
               view,
               "#fare-zones-error",
               "Your saved zones and rules haven’t changed."
             )

      assert has_element?(view, "#fare-zones-reload", "Reload fares")
      refute has_element?(view, "#fare-zones-panel")
      refute has_element?(view, "#fares-checks-count")

      # The retry runs against whatever adapter is configured at call time, so the
      # default Repo adapter proves the recovery path with no mock in place.
      Application.delete_env(:gtfs_planner, @adapter_key)

      html = render_click(view, "reload")

      assert html =~ "fare-zones-panel"
      refute has_element?(view, "#fare-zones-error")
    end

    test "an ordinary mount loads through the default adapter without a mock", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.delete_env(:gtfs_planner, @adapter_key)

      insert_zone(user, organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares/zones")

      assert has_element?(view, "#fare-zones-panel")
      refute has_element?(view, "#fare-zones-error")
      refute has_element?(view, "#fare-zones-loading")
    end

    test "switching version keeps the current tab", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_workspace()

      other_version = gtfs_version_fixture(organization.id, %{name: "Next version"})
      conn = log_in_user(conn, user, organization: organization)

      {:ok, switch_view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares/zones")
      render_hook(switch_view, "switch_gtfs_version", %{"version" => other_version.id})
      assert_redirect(switch_view, "/gtfs/#{other_version.id}/settings/fares/zones")

      {:ok, loaded_view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares/zones")
      render_hook(loaded_view, "gtfs_version_loaded", %{"version_id" => other_version.id})
      assert_redirect(loaded_view, "/gtfs/#{other_version.id}/settings/fares/zones")
    end

    test "an unpublished selection leaves the workspace where it is", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_workspace()

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares/zones")
      render_hook(view, "switch_gtfs_version", %{"version" => staging.id})

      refute_push_event(view, "gtfs_version_selected", %{version_id: _})
      refute_redirected(view)
    end
  end

  describe "access" do
    setup :editor_setup

    test "a member without the editor role is redirected from every destination", %{
      conn: conn,
      organization: organization,
      gtfs_version: version
    } do
      for roles <- [[], ["pathways_studio_admin"]] do
        member = member_with_roles(organization, roles)
        member_conn = log_in_user(conn, member, organization: organization)

        for {_action, path} <- @paths do
          assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
                   live(member_conn, "/gtfs/#{version.id}#{path}")
        end
      end
    end

    test "an unauthenticated visit goes to the login page", %{gtfs_version: version} do
      conn = build_conn() |> init_test_session(%{})

      for {_action, path} <- @paths do
        assert redirected_to(get(conn, "/gtfs/#{version.id}#{path}")) == "/users/log_in"
      end
    end
  end
end
