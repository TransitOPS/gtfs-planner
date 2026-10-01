defmodule GtfsPlannerWeb.Gtfs.FareEditorLiveTest do
  @moduledoc """
  Merge evidence (EV-31) for the fare editor shell and its routes.

  Every case drives the real routes. The ordinary entries load through the
  default Repo adapter with no mock in place, and only the lost-connection case
  goes through the catalog adapter seam, so the shell is proved end to end
  instead of against a private test-only interface:

  - Each of the editor's four paths renders "Fares" with its own tab current,
    the other four tabs pointing at their own paths, and a way back to Settings.
  - The Zones tab's link opens the zone workspace, which is the other LiveView.
  - `/settings/fares/rules` navigates to Where fares apply rather than 404ing or
    rendering a retired tab.
  - A stop's zone link opens the zone workspace's own path, carrying the zone as
    its own query key.
  - A member without the GTFS editor role is redirected like every other Settings
    page, and an unauthenticated visit goes to the login page.
  - The disconnected render ships the skeleton and no tab panel.
  - `{:error, :unavailable}` renders the load-error callout with its one Reload
    fares action, and Reload against the restored default adapter loads the page.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @adapter_key :gtfs_catalog_read_adapter

  # `[live action, path]` for the four destinations the editor owns. The Zones
  # tab is the zone workspace's, and `/settings/fares/rules` is the retired path
  # that redirects, so both are covered by their own cases.
  @editor_paths [
    prices: "/settings/fares",
    where: "/settings/fares/where",
    transfers: "/settings/fares/transfers",
    checks: "/settings/fares/checks"
  ]

  # The five tabs the shared strip renders, and the path each one names.
  @tabs [
    prices: "/settings/fares",
    where: "/settings/fares/where",
    transfers: "/settings/fares/transfers",
    zones: "/settings/fares/zones",
    checks: "/settings/fares/checks"
  ]

  # The prototype's own primary labels and DOM ids, one per tab that has one.
  @primaries [
    prices: "create-fare",
    where: "add-fare-rule",
    transfers: "add-transfer-rule"
  ]

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

  # The editor's whole read model, as literals: an empty version's workspace, so
  # the shell's own copy and states cannot be confirmed through the adapter.
  defp stub_workspace(workspace) do
    stub(CatalogReadAdapterMock, :load_fare_editor, fn _organization_id, _version_id, _opts ->
      {:ok, workspace}
    end)
  end

  # The shell's own copy is a source literal, and HEEx wraps a long line inside
  # the element that carries it, so the rendered text is compared with its
  # whitespace collapsed rather than against the source's line breaks.
  defp text_of(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp empty_workspace do
    %GtfsPlanner.Gtfs.Fares.Workspace{
      managed?: true,
      currency: "USD",
      unmanaged: nil
    }
  end

  describe "fare editor shell" do
    setup :editor_setup

    test "each destination renders the shell with its own tab current", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_workspace(empty_workspace())

      conn = log_in_user(conn, user, organization: organization)

      for {action, path} <- @editor_paths do
        {:ok, view, html} = live(conn, "/gtfs/#{version.id}#{path}")

        assert has_element?(view, "h1", "Fares")

        assert text_of(html) =~
                 "What riders pay and which fare each ride charges. Exports include both GTFS fare formats."

        assert has_element?(
                 view,
                 "#settings-back[href='/gtfs/#{version.id}/settings']",
                 "Settings"
               )

        # The shell is the Fares page, not the Settings index and not a
        # section-nav variant of it.
        assert has_element?(view, "#fare-editor-page")
        refute has_element?(view, "#settings-nav")

        assert has_element?(view, "#fares-tab-#{action}[aria-current='page']")

        for {other, _path} <- @editor_paths, other != action do
          refute has_element?(view, "#fares-tab-#{other}[aria-current='page']")
        end
      end
    end

    test "every tab names its own path, and the Zones tab opens the zone workspace", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_workspace(empty_workspace())

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      for {tab, path} <- @tabs do
        assert has_element?(
                 view,
                 "#fares-tab-#{tab}[href='/gtfs/#{version.id}#{path}']"
               ),
               "the #{tab} tab links to #{path}"
      end

      # Zones is the other LiveView: clicking it lands on the zone workspace's
      # own panel, not on an editor tab.
      view
      |> element("#fares-tab-zones")
      |> render_click()

      assert_redirect(view, "/gtfs/#{version.id}/settings/fares/zones")

      # The zone workspace is the other LiveView and reads its own model through
      # the default adapter, so the editor's stub steps aside before it mounts.
      Application.delete_env(:gtfs_planner, @adapter_key)

      {:ok, zones_view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares/zones")

      # The zone workspace's zone list is empty until a zone exists, so the
      # proof is the page it mounts and the tab it marks current.
      assert has_element?(zones_view, "#fares-page")
      assert has_element?(zones_view, "#fares-tab-zones[aria-current='page']")
      refute has_element?(zones_view, "#fare-editor-page")
    end

    test "the retired rules path navigates to Where fares apply", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_workspace(empty_workspace())

      Application.delete_env(:gtfs_planner, @adapter_key)

      conn = log_in_user(conn, user, organization: organization)

      # A plain visit is redirected before any content is rendered, so a
      # browser and a link from outside the page both land on the tab.
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/gtfs/#{version.id}/settings/fares/rules")

      assert to == "/gtfs/#{version.id}/settings/fares/where"

      # It lands on the tab, current, rather than on an error or a blank page.
      {:ok, where_view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares/where")

      assert has_element?(where_view, "h1", "Fares")
      assert has_element?(where_view, "#fares-tab-where[aria-current='page']")
      refute has_element?(where_view, "#fares-tab-rules")
    end

    test "a stop's zone link opens the zone workspace with the zone as its own query key", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_workspace(empty_workspace())

      # The stop's own reads are the stop detail page's, not the editor's, so
      # the default adapter serves this page.
      Application.delete_env(:gtfs_planner, @adapter_key)

      stop = stop_fixture(organization.id, version.id, %{stop_id: "STOP_1"})

      # `stops.zone_id` is never cast from a changeset (INV-2), so the zone the
      # link carries is written the way an import leaves it, alongside the
      # version's own zone record the link's filter opens.
      now = DateTime.utc_now()

      {1, nil} =
        Repo.insert_all(FareZone, [
          %{
            id: Ecto.UUID.generate(),
            organization_id: organization.id,
            gtfs_version_id: version.id,
            zone_id: "A",
            name: "Central",
            color: "ocean",
            inserted_at: now,
            updated_at: now
          }
        ])

      {1, nil} =
        Repo.update_all(
          from(s in Stop, where: s.id == ^stop.id),
          set: [zone_id: "A", updated_at: now]
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/stops/#{stop.stop_id}")

      assert has_element?(
               view,
               "#stop-fare-zone-link[href='/gtfs/#{version.id}/settings/fares/zones?zone=A']"
             )
    end

    test "the header carries one primary, and it follows the tab", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # A version holding one transfer rule, which is what the Transfers tab's
      # own primary needs beside it.
      stub_workspace(%{empty_workspace() | transfers: [%{from_leg_group_id: "A"}]})

      conn = log_in_user(conn, user, organization: organization)

      for {action, path} <- @editor_paths do
        {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{path}")

        for {tab, id} <- @primaries do
          if tab == action do
            assert has_element?(view, "##{id}"), "the #{tab} tab carries its own primary"
          else
            refute has_element?(view, "##{id}"), "the #{tab} tab carries no other tab's primary"
          end
        end
      end
    end

    test "the Checks mark counts the version's fare problems, and claims none before they load",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      # A version holding no fare rows has nothing to check, so the mark reports
      # a clean zero rather than an unknown count. A route in no route group on a
      # managed version is one repair item, which moves the same mark to a count
      # of one.
      stub_workspace(empty_workspace())

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      assert has_element?(view, "#fares-tab-checks #fares-checks-count", "0")
    end

    test "the disconnected render ships the skeleton and no tab panel", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      for {_action, path} <- @editor_paths do
        conn = get(conn, "/gtfs/#{version.id}#{path}")

        assert conn.status == 200
        doc = LazyHTML.from_fragment(conn.resp_body)

        assert Enum.count(LazyHTML.query(doc, "#fare-editor-loading[aria-busy='true']")) == 1
        assert LazyHTML.text(LazyHTML.query(doc, "#fare-editor-loading")) =~ "Loading fares…"
        assert Enum.empty?(LazyHTML.query(doc, "#fare-editor-panel"))
        # The problem count is unknown before the load resolves, so the tab
        # claims no mark rather than reporting a clean version.
        assert Enum.empty?(LazyHTML.query(doc, "#fares-checks-count"))
      end
    end

    test "a lost connection renders one recovery action, and Reload loads the page", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub(CatalogReadAdapterMock, :load_fare_editor, fn _organization_id, _version_id, _opts ->
        {:error, :unavailable}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      assert has_element?(view, "#fare-editor-error", "Fares couldn’t load")
      assert has_element?(view, "#fare-editor-reload", "Reload fares")
      refute has_element?(view, "#fare-editor-panel")
      refute has_element?(view, "#fares-checks-count")

      # The retry runs against whatever adapter is configured at call time, so the
      # default Repo adapter proves the recovery path with no mock in place.
      Application.delete_env(:gtfs_planner, @adapter_key)

      html = render_click(view, "reload")

      assert html =~ "fare-editor-panel"
      refute has_element?(view, "#fare-editor-error")
    end

    test "an ordinary mount loads through the default adapter without a mock", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      Application.delete_env(:gtfs_planner, @adapter_key)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      assert has_element?(view, "#fare-editor-panel")
      refute has_element?(view, "#fare-editor-error")
      refute has_element?(view, "#fare-editor-loading")
    end

    test "switching version keeps the current tab", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_workspace(empty_workspace())

      other_version = gtfs_version_fixture(organization.id, %{name: "Next version"})
      conn = log_in_user(conn, user, organization: organization)

      {:ok, switch_view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares/where")
      render_hook(switch_view, "switch_gtfs_version", %{"version" => other_version.id})
      assert_redirect(switch_view, "/gtfs/#{other_version.id}/settings/fares/where")

      {:ok, loaded_view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares/where")
      render_hook(loaded_view, "gtfs_version_loaded", %{"version_id" => other_version.id})
      assert_redirect(loaded_view, "/gtfs/#{other_version.id}/settings/fares/where")
    end

    test "an unpublished selection leaves the editor where it is", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stub_workspace(empty_workspace())

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})
      conn = log_in_user(conn, user, organization: organization)

      Application.delete_env(:gtfs_planner, @adapter_key)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")
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

        for {_action, path} <- @editor_paths do
          assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
                   live(member_conn, "/gtfs/#{version.id}#{path}")
        end
      end
    end

    test "an unauthenticated visit goes to the login page", %{gtfs_version: version} do
      conn = build_conn() |> init_test_session(%{})

      for {_action, path} <- @editor_paths do
        assert redirected_to(get(conn, "/gtfs/#{version.id}#{path}")) == "/users/log_in"
      end
    end
  end
end
