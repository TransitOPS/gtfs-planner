defmodule GtfsPlannerWeb.Gtfs.FlexLiveTest do
  @moduledoc """
  Judges the Flex list page (EV-18, AC-3, CL-14).

  The page is the version's flex workspace: one row per service in name order
  with its hours summary, booking summary and readiness badge, the export-state
  line, the first-use question when the version has none, and the map card the
  `FlexAreaMap` hook draws from the load's `map` payload. The load's states are
  judged through the catalog read adapter seam the repository already uses for
  the other operational list loads: the disconnected render carries the loading
  placeholder, a lost connection is the retryable error, and `retry` re-runs the
  same load.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.ComingSoon

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

  describe "the services list" do
    setup :editor_with_flex_version

    test "renders one row per service with its hours, booking and status in name order", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      feed: feed
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))

      html = loaded(view)
      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.text(LazyHTML.query(doc, "h1")) |> String.trim() == "Flex"

      assert LazyHTML.text(LazyHTML.query(doc, "#flex-services-count")) |> String.trim() ==
               "3 flex services"

      assert row_names(doc) == ["Newport Access", "Newport Dial-a-Ride", "Valley Line detours"]

      # The row's primary identifier is the link to the service.
      assert row_hrefs(doc) ==
               Enum.map([feed.services.registered, feed.services.area, feed.services.detour], fn
                 service -> "/gtfs/#{version.id}/flex/#{service.id}"
               end)

      registered = row_text(doc, "Newport Access")
      assert registered =~ "Anywhere in Newport Access Area"
      assert registered =~ "Newport Access Area only: Weekdays 8:00 am–5:00 pm"
      assert registered =~ "Call, 2 hr ahead"
      assert registered =~ "Ready · 1 suggestion"

      dial_a_ride = row_text(doc, "Newport Dial-a-Ride")
      assert dial_a_ride =~ "Anywhere in Newport or Toledo"
      assert dial_a_ride =~ "Newport only: Weekdays 7:00 am–6:00 pm"
      assert dial_a_ride =~ "Toledo only: Weekdays 9:00 am–3:00 pm"
      assert dial_a_ride =~ "Newport only: Saturdays 6:00 pm–1:00 am (next day)"
      assert dial_a_ride =~ "Online or call, by 4 pm, 1 business day ahead"
      assert dial_a_ride =~ "Ready · 1 suggestion"

      detour = row_text(doc, "Valley Line detours")
      assert detour =~ "Detours up to ¼ mile from Route 20"
      assert detour =~ "On Route 20 trips: weekdays and Saturdays, 9:00 am–3:00 pm only"
      assert detour =~ "Call, by 4 pm, 1 business day ahead"
      assert detour =~ "Ready"

      assert has_element?(view, "#create-service", "Create flex service")
      refute has_element?(view, "#flex-first-use")
    end

    test "shows the first-use question when the version has no service", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      # The same version without the services: first use is an empty list, not a
      # failure and not the populated table.
      for service <- Flex.list_services(organization.id, version.id) do
        :ok = Flex.delete_service(flex_audit_fixture(organization.id, version.id), service.id)
      end

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))

      html = loaded(view)

      assert has_element?(view, "#flex-first-use", "What kind of on-demand service do you run?")
      assert has_element?(view, "#flex-create-area", "Rides anywhere in an area")
      assert has_element?(view, "#flex-create-detour", "A route that detours on request")

      assert has_element?(
               view,
               "#flex-first-use",
               "Stops served only when booked?"
             )

      refute has_element?(view, "#flex-services")
      refute has_element?(view, "#flex-services-count")
      refute has_element?(view, "#create-service")
      refute has_element?(view, "#flex-list-error")

      # The map card names what it draws when there is nothing to draw yet.
      assert has_element?(view, "#flex-list-map-title", "Fixed routes in this version")
      assert has_element?(view, "#flex-list-map[phx-update=ignore]")
      assert html =~ "Exports also write a flex file"
    end

    test "lists an inactive service with its neutral badge", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      feed: feed
    } do
      {:ok, _inactive} =
        Flex.set_active(flex_audit_fixture(organization.id, version.id), feed.services.detour.id, false)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))

      row = row_text(LazyHTML.from_fragment(loaded(view)), "Valley Line detours")

      assert row =~ "Inactive"
      refute row =~ "Ready"
    end
  end

  describe "the map payload" do
    setup :editor_with_flex_version

    test "answers flex_map_ready with the stored areas, the route lines and the connecting stops",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version,
           feed: feed
         } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))
      loaded(view)

      # The card's hook asks for the map once it mounts.
      render_hook(view, "flex_map_ready", %{})

      assert_push_event(view, "flex_map:load", %{
        areas: areas,
        routes: routes,
        stops: stops
      })

      stored =
        (feed.services.area.areas ++ feed.services.registered.areas)
        |> Enum.map(& &1.id)

      # Every active service's stored area, from `Flex.Geometry.get_geojson/1`;
      # the detour service has none and the list of areas is complete.
      assert Enum.sort(Enum.map(areas, & &1.id)) == Enum.sort(stored)
      assert Enum.all?(areas, &(&1.geojson["type"] == "MultiPolygon"))

      # One line per fixed route: Route 20's shape, and Route 1's stops because
      # its trips name no shape.
      assert Enum.map(routes, & &1.id) == ["1", "20"]

      assert Enum.find(routes, &(&1.id == "1")).coordinates == [
               [-124.04, 44.6],
               [-124.03, 44.61]
             ]

      # The dial-a-ride's connecting stops, with the coordinates the map draws.
      assert Enum.sort(Enum.map(stops, & &1.id)) == ["DPB", "OTR"]
      assert Enum.all?(stops, &(&1.hub and is_float(&1.lat) and is_float(&1.lon)))
    end

    test "an inactive service contributes nothing to the map", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      feed: feed
    } do
      {:ok, _inactive} =
        Flex.set_active(flex_audit_fixture(organization.id, version.id), feed.services.area.id, false)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))
      loaded(view)

      render_hook(view, "flex_map_ready", %{})

      assert_push_event(view, "flex_map:load", %{areas: areas, stops: stops})

      assert Enum.map(areas, & &1.id) == Enum.map(feed.services.registered.areas, & &1.id)
      assert stops == []
    end
  end

  describe "the map payload without a load" do
    setup :use_mock_adapter

    test "a failed load answers flex_map_ready with nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      stub_flex_list({:error, :unavailable})

      {:ok, view, _html} = live(conn, flex_path(version))
      loaded(view)

      # The page already shows the retryable error; the map must not draw a
      # half-loaded version.
      render_hook(view, "flex_map_ready", %{})

      refute_push_event(view, "flex_map:load", %{})
    end
  end

  describe "tenant scope" do
    setup :editor_with_version

    test "never lists another organization's or version's services", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      # The page's version holds no service; a sibling version of the same
      # organization and another organization's version each hold one.
      sibling_version = gtfs_version_fixture(organization.id)

      {:ok, _sibling_service} =
        Flex.create_service(flex_audit_fixture(organization.id, sibling_version.id), %{
          name: "Sibling Version Service",
          kind: :area
        })

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, _other_service} =
        Flex.create_service(flex_audit_fixture(other_organization.id, other_version.id), %{
          name: "Other Organization Service",
          kind: :area
        })

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))

      assert has_element?(view, "#flex-first-use")

      html = loaded(view)

      refute html =~ "Sibling Version Service"
      refute html =~ "Other Organization Service"
    end
  end

  describe "the export-state line" do
    setup :editor_with_flex_version

    test "reads the flex-file sentence, the off warning and the only-feed sentence", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))

      assert has_element?(view, "#flex-exports", "Exports also write a flex file")
      refute has_element?(view, "#flex-exports", "Exports leave flex out")

      {:ok, _defaults} = ExportDefaults.update(organization.id, %{include_flex: false})

      {:ok, off_view, _html} = live(conn, flex_path(version))

      assert has_element?(off_view, "#flex-exports", "Exports leave flex out.")
      assert has_element?(off_view, "#flex-exports", "Change in Settings › Export defaults")
      refute has_element?(off_view, "#flex-exports", "Exports also write a flex file")

      # A version with no fixed route publishes the flex file as its only feed (R15).
      {:ok, _defaults} = ExportDefaults.update(organization.id, %{include_flex: true})
      empty_version = gtfs_version_fixture(organization.id)

      {:ok, service} =
        Flex.create_service(flex_audit_fixture(organization.id, empty_version.id), %{
          name: "Coastal Dial-a-Ride",
          kind: :area
        })

      {:ok, _service} =
        Flex.save_service(
          flex_audit_fixture(organization.id, empty_version.id),
          service,
          %{phone: "(541) 555-0199"},
          []
        )

      {:ok, only_view, _html} = live(conn, flex_path(empty_version))

      assert has_element?(only_view, "#flex-exports", "Your flex file is your only feed")
      refute has_element?(only_view, "#flex-exports", "Exports leave flex out")
    end

    test "a version with no services still reads the switch", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      version = gtfs_version_fixture(organization.id)

      {:ok, _defaults} = ExportDefaults.update(organization.id, %{include_flex: false})

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))

      assert has_element?(view, "#flex-first-use")
      assert has_element?(view, "#flex-exports", "Exports leave flex out.")
    end
  end

  describe "load states through the adapter seam" do
    setup :use_mock_adapter

    test "loading, unavailable and retry stay distinct", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_flex_list({:error, :unavailable})

      {:ok, view, static_html} = live(conn, flex_path(version))

      # The first paint is the loading placeholder; the connected load settles.
      assert static_html =~ "flex-loading"
      refute static_html =~ "flex-list-error"

      error = loaded(view)

      assert error =~ "flex-list-error"
      assert error =~ "Couldn’t load flex services."
      refute error =~ "flex-services-count"
      refute error =~ "flex-first-use"

      # Retry re-runs the same load and recovers.
      stub_flex_list({:ok, empty_load()})

      assert render_click(view, "retry") =~ "flex-loading"
      assert loaded(view) =~ "flex-first-use"
    end

    test "a version with no service is an empty list, not a failed read", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      stub_flex_list({:ok, empty_load()})

      {:ok, view, _html} = live(conn, flex_path(version))

      html = loaded(view)

      assert html =~ "flex-first-use"
      refute html =~ "flex-services-count"
      refute html =~ "flex-list-error"
    end
  end

  describe "access" do
    test "a Pathways organization reaches the route while the nav omits Flex", %{conn: conn} do
      organization = organization_fixture(%{product: :pathways})
      user = editor_for(organization)
      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))

      assert has_element?(view, "h1", "Flex")
      refute has_element?(view, "#main-navigation #nav-flex")
    end

    test "a Planner organization sees the Flex nav item on the page", %{conn: conn} do
      organization = organization_fixture()
      user = editor_for(organization)
      version = gtfs_version_fixture(organization.id)
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, flex_path(version))

      assert has_element?(view, "h1", "Flex")
      assert has_element?(view, "#main-navigation #nav-flex", "Flex")
    end

    test "members without the editor role cannot reach the page", %{conn: conn} do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      for roles <- [[], ["pathways_studio_admin"]] do
        member = user_fixture()

        Accounts.create_user_org_membership(%{
          user_id: member.id,
          organization_id: organization.id,
          roles: roles
        })

        member_conn = log_in_user(conn, member, organization: organization)

        assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
                 live(member_conn, flex_path(version))
      end
    end

    test "unauthenticated visits follow the existing login redirect", %{conn: _conn} do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      conn = build_conn() |> init_test_session(%{})

      assert redirected_to(get(conn, flex_path(version))) == "/users/log_in"
    end
  end

  describe "version switching" do
    setup :editor_with_flex_version

    test "an explicit selection keeps the Flex list in the new version", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      conn = log_in_user(conn, user, organization: organization)
      selected_version_id = to_string(other_version.id)

      {:ok, view, _html} = live(conn, flex_path(version))

      render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

      assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})

      assert_redirect(view, "/gtfs/#{other_version.id}/flex")
    end
  end

  describe "the Coming soon catalog" do
    test "no longer describes flex" do
      # `feature/1` answers for the catalog's own keys only, so `:flex` has no
      # clause; the atom is built at runtime because the compiler can prove the
      # literal is not a catalog key.
      key = String.to_existing_atom("flex")

      assert_raise FunctionClauseError, fn -> ComingSoon.feature(key) end
    end
  end

  # --- setup ------------------------------------------------------------------

  defp editor_with_flex_version(_context) do
    organization = organization_fixture()
    user = editor_for(organization)
    version = gtfs_version_fixture(organization.id)

    %{
      user: user,
      organization: organization,
      version: version,
      feed: flex_representative_fixture(organization, version)
    }
  end

  defp use_mock_adapter(context) do
    swap_adapter(CatalogReadAdapterMock)
    editor_with_version(context)
  end

  # The adapter seam replaces the whole load, so these cases need a published
  # version to open, not a version that holds flex data.
  defp editor_with_version(_context) do
    organization = organization_fixture()
    user = editor_for(organization)

    %{user: user, organization: organization, version: gtfs_version_fixture(organization.id)}
  end

  defp editor_for(organization) do
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    user
  end

  defp swap_adapter(adapter) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)

    case adapter do
      nil -> Application.delete_env(:gtfs_planner, @adapter_key)
      module -> Application.put_env(:gtfs_planner, @adapter_key, module)
    end

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)
  end

  defp stub_flex_list(result) do
    stub(CatalogReadAdapterMock, :load_flex_list, fn _organization_id, _version_id -> result end)
  end

  defp empty_load do
    %{
      services: [],
      calendars: %{},
      map: %{areas: [], routes: [], stops: []},
      routes: [],
      has_fixed_routes?: true,
      include_flex: true
    }
  end

  # --- helpers ----------------------------------------------------------------

  defp flex_path(version), do: "/gtfs/#{version.id}/flex"

  # The first paint of the list defers its read, so the static response carries
  # the loading placeholder and the connected socket loads the rows. Waiting on
  # `:sys.get_state/1` is what makes the assertion read the settled socket: the
  # queued load is handled before the reply, with no sleep.
  defp loaded(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  defp row_names(doc) do
    doc
    |> LazyHTML.query("#flex-services tr td:first-child a")
    |> Enum.map(fn link -> link |> LazyHTML.text() |> String.trim() end)
  end

  defp row_hrefs(doc) do
    doc
    |> LazyHTML.query("#flex-services tr td:first-child a")
    |> LazyHTML.attribute("href")
  end

  # One row's whole text, found by the service name it links to, so an assertion
  # ties its hours, booking and status to that service's row.
  defp row_text(doc, name) do
    doc
    |> LazyHTML.query("#flex-services tr")
    |> Enum.find_value(fn row ->
      text = row |> LazyHTML.text() |> String.trim()
      if String.contains?(text, name), do: text
    end)
  end
end
