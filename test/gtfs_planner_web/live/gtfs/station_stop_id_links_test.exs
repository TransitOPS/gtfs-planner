defmodule GtfsPlannerWeb.Gtfs.StationStopIdLinksTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

  # GTFS stop_id is free text, so a station can carry `/` and a space.
  @tabs "nav[aria-label='Station views']"

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    {:ok, other_version} = Versions.create_gtfs_version(organization.id, %{name: "Second"})

    station =
      stop_fixture(organization.id, version.id, %{
        stop_id: "QA/STN 1",
        stop_name: "Slash Station",
        location_type: 1
      })

    level = level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})

    {:ok, _stop_level} =
      insert_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        stop_id: station.stop_id,
        level_id: level.level_id
      })

    %{
      conn: log_in_user(conn, user, organization: organization),
      version: version,
      other_version: other_version,
      base: "/gtfs/#{version.id}/stops/QA%2FSTN%201",
      other_base: "/gtfs/#{other_version.id}/stops/QA%2FSTN%201"
    }
  end

  defp tab_href(view, suffix) do
    [href] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#{@tabs} a[href$='#{suffix}']")
      |> LazyHTML.attribute("href")

    href
  end

  defp view_nav_href(view, id) do
    [href] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("##{id}")
      |> LazyHTML.attribute("href")

    href
  end

  describe "station tabs for a stop ID with reserved URL characters" do
    test "link every tab by its encoded path", %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, base)

      assert has_element?(view, "#{@tabs} a[href='#{base}'][aria-current='page']", "Details")
      assert has_element?(view, "#{@tabs} a[href='#{base}/diagram']", "Floorplans")
      assert has_element?(view, "#{@tabs} a[href='#{base}/report']", "Reports")
      assert has_element?(view, "#{@tabs} a[href='#{base}/reachability']", "Reachability")
      assert has_element?(view, "#{@tabs} a[href='#{base}/evolutions']", "Closures")
    end

    test "open the Floorplans page from its tab link", %{conn: conn, base: base} do
      {:ok, details_view, _html} = live(conn, base)
      href = tab_href(details_view, "/diagram")

      {:ok, diagram_view, _html} = live(conn, href)

      assert has_element?(
               diagram_view,
               "#{@tabs} a[href='#{base}/diagram'][aria-current='page']",
               "Floorplans"
             )
    end

    test "open the Reports page from its tab link", %{conn: conn, base: base} do
      {:ok, details_view, _html} = live(conn, base)
      href = tab_href(details_view, "/report")

      {:ok, report_view, _html} = live(conn, href)
      render_async(report_view, 5_000)

      assert has_element?(
               report_view,
               "#{@tabs} a[href='#{base}/report'][aria-current='page']",
               "Reports"
             )
    end

    test "open the Reachability page from its tab link", %{conn: conn, base: base} do
      {:ok, details_view, _html} = live(conn, base)
      href = tab_href(details_view, "/reachability")

      {:ok, reachability_view, _html} = live(conn, href)

      assert has_element?(
               reachability_view,
               "#{@tabs} a[href='#{base}/reachability'][aria-current='page']",
               "Reachability"
             )
    end

    test "open the Closures page from its tab link", %{conn: conn, base: base} do
      {:ok, details_view, _html} = live(conn, base)
      href = tab_href(details_view, "/evolutions")

      {:ok, evolutions_view, _html} = live(conn, href)

      assert has_element?(
               evolutions_view,
               "#{@tabs} a[href='#{base}/evolutions'][aria-current='page']",
               "Closures"
             )
    end
  end

  describe "switching GTFS version from a stop ID with reserved URL characters" do
    test "keeps the encoded stop on the Details page", %{
      conn: conn,
      base: base,
      other_version: other_version,
      other_base: other_base
    } do
      {:ok, view, _html} = live(conn, base)

      render_hook(view, "switch_gtfs_version", %{"version" => to_string(other_version.id)})

      assert_redirect(view, other_base)
    end

    test "keeps the encoded stop when the stored version differs on the Details page", %{
      conn: conn,
      base: base,
      other_version: other_version,
      other_base: other_base
    } do
      {:ok, view, _html} = live(conn, base)

      render_hook(view, "gtfs_version_loaded", %{"version_id" => to_string(other_version.id)})

      assert_redirect(view, other_base)
    end

    test "keeps the encoded stop on the Floorplans page", %{
      conn: conn,
      base: base,
      other_version: other_version,
      other_base: other_base
    } do
      {:ok, view, _html} = live(conn, "#{base}/diagram")

      render_hook(view, "gtfs_version_loaded", %{"version_id" => to_string(other_version.id)})

      assert_redirect(view, "#{other_base}/diagram")
    end

    test "keeps the encoded stop on the Reports page", %{
      conn: conn,
      base: base,
      other_version: other_version,
      other_base: other_base
    } do
      {:ok, view, _html} = live(conn, "#{base}/report")
      render_async(view, 5_000)

      render_hook(view, "gtfs_version_loaded", %{"version_id" => to_string(other_version.id)})

      assert_redirect(view, "#{other_base}/report")
    end

    test "keeps the encoded stop on the Reachability page", %{
      conn: conn,
      base: base,
      other_version: other_version,
      other_base: other_base
    } do
      {:ok, view, _html} = live(conn, "#{base}/reachability")

      render_hook(view, "gtfs_version_loaded", %{"version_id" => to_string(other_version.id)})

      assert_redirect(view, "#{other_base}/reachability")
    end
  end

  describe "the Evolutions page's own links for a stop ID with reserved URL characters" do
    test "build the encoded evolutions address and load it", %{conn: conn, base: base} do
      {:ok, view, _html} = live(conn, "#{base}/evolutions")

      # The view switch is the page's own path builder. With the stop ID's `/`
      # left raw the link names a stop "QA" and no such route, so the address is
      # asserted exactly rather than by a prefix.
      href = view_nav_href(view, "evolutions-tab-closures")
      assert href == "#{base}/evolutions"

      assert has_element?(
               view,
               "#evolutions-tab-access[href='#{base}/evolutions/access']"
             )

      # Following the page's own link is what has to land on the Closures view.
      {:ok, closures_view, _html} = live(conn, href)

      assert has_element?(
               closures_view,
               "#evolutions-tab-closures[aria-current='page']",
               "Schedule closures"
             )
    end
  end

  describe "Floorplans deep link for a stop ID with reserved URL characters" do
    test "patches to the encoded diagram path once the journal opens", %{
      conn: conn,
      base: base
    } do
      {:ok, view, _html} = live(conn, "#{base}/diagram?journal=open")
      render_async(view, 5_000)

      assert has_element?(view, "#station-journal-panel")
      assert_patch(view, "#{base}/diagram")
    end
  end
end
