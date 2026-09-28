defmodule GtfsPlannerWeb.Gtfs.AgenciesLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"

  # A per-call address: the shared `user_fixture/1` counter restarts with each
  # BEAM run, so a row an unboxed test left in the shared database can collide
  # with it inside the fixture. The prefix keeps this file out of that range.
  defp editor_email do
    "agencies-list-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
  end

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = user_fixture(%{email: editor_email()})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, version: version}
  end

  defp create_agency(organization, version, attrs) do
    {:ok, agency} =
      Gtfs.create_agency(
        Map.merge(%{organization_id: organization.id, gtfs_version_id: version.id}, attrs)
      )

    agency
  end

  defp create_route(organization, version, attrs) do
    {:ok, route} =
      Gtfs.create_route(
        Map.merge(
          %{organization_id: organization.id, gtfs_version_id: version.id, route_type: 3},
          attrs
        )
      )

    route
  end

  defp agency_attributes(agency_id, name, host, timezone \\ "America/New_York") do
    %{
      agency_id: agency_id,
      agency_name: name,
      agency_url: "https://#{host}",
      agency_timezone: timezone
    }
  end

  defp routes(organization, version, agency_id, count) do
    for index <- 1..count//1 do
      create_route(organization, version, %{
        route_id: "#{agency_id}_#{index}",
        route_short_name: "#{index}",
        agency_id: agency_id
      })
    end
  end

  defp rows(doc), do: LazyHTML.query(doc, "#agencies tr")

  defp cell(row, label), do: LazyHTML.query(row, "td[data-label='#{label}']")

  defp cell_text(row, label) do
    row |> cell(label) |> LazyHTML.text() |> String.trim()
  end

  # The Agency cell carries the name and the website host as two lines.
  defp cell_lines(row, label) do
    row
    |> cell(label)
    |> LazyHTML.query("div")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # The Agency cell carries the name on the button that opens the row (step 18)
  # and the website host as the line under it.
  defp names(doc) do
    Enum.map(rows(doc), fn row ->
      row
      |> LazyHTML.query("td[data-label='Agency'] button")
      |> LazyHTML.text()
      |> String.trim()
    end)
  end

  defp hosts(doc), do: Enum.map(rows(doc), &(&1 |> cell_lines("Agency") |> List.last()))

  defp header_sorts(doc) do
    doc
    |> LazyHTML.query("#agencies-container thead th")
    |> Enum.map(&LazyHTML.attribute(&1, "aria-sort"))
  end

  defp count_labels(doc) do
    doc
    |> LazyHTML.query("#agencies a[aria-label]")
    |> Enum.map(&LazyHTML.attribute(&1, "aria-label"))
  end

  defp count_hrefs(doc) do
    doc
    |> LazyHTML.query("#agencies a[aria-label]")
    |> Enum.map(&LazyHTML.attribute(&1, "href"))
  end

  defp text_of(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  describe "the list" do
    setup :editor_setup

    test "lists every agency with its website host, timezone and route count, ordered by name",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      create_agency(
        organization,
        version,
        agency_attributes("NCT", "North Coast Transit", "northcoast.example")
      )

      create_agency(
        organization,
        version,
        agency_attributes("HBR", "Harbor Shuttle", "harbor.example")
      )

      create_agency(
        organization,
        version,
        agency_attributes("RCT", "Riverside Community Transport", "riverside.example")
      )

      routes(organization, version, "NCT", 5)
      routes(organization, version, "HBR", 2)

      # A route with no agency does not count toward any row while the version
      # has more than one agency (R5).
      create_route(organization, version, %{route_id: "NO_AGENCY", route_short_name: "X"})

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      # The literal route wins: this is the page, not the Coming soon placeholder
      # the section route used to render.
      assert text_of(doc, "h1") == "Agencies"

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#settings-nav a[aria-current='page']"),
               "href"
             ) ==
               [agencies_path(version.id)]

      refute has_element?(view, "#coming-soon-status")
      refute has_element?(view, "#agencies-empty")

      assert names(doc) == [
               "Harbor Shuttle",
               "North Coast Transit",
               "Riverside Community Transport"
             ]

      assert hosts(doc) == ["harbor.example", "northcoast.example", "riverside.example"]

      assert Enum.map(rows(doc), &cell_text(&1, "Timezone")) == [
               "America/New_York",
               "America/New_York",
               "America/New_York"
             ]

      assert count_labels(doc) == [
               ["View 2 routes for Harbor Shuttle"],
               ["View 5 routes for North Coast Transit"],
               ["View 0 routes for Riverside Community Transport"]
             ]

      assert cell_text(Enum.at(rows(doc), 1), "Routes") |> String.starts_with?("5")

      # One timezone, so the band names it and no row needs review.
      band = text_of(doc, "#agencies-timezone-band")

      assert band =~ "One timezone for this version"
      assert band =~ "America/New_York · Used by all agencies and their schedules."

      refute has_element?(view, "#agencies-timezone-callout")
      refute has_element?(view, "#agencies tr td div", "Needs review")
    end

    test "one agency still renders the one-row list", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      create_agency(
        organization,
        version,
        agency_attributes("NCT", "North Coast Transit", "northcoast.example")
      )

      routes(organization, version, "NCT", 2)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert has_element?(view, "#agencies")
      assert Enum.count(rows(doc)) == 1
      assert names(doc) == ["North Coast Transit"]
      assert text_of(doc, "h1") == "Agencies"

      # The list, not a single-agency detail view: the band and the table stay.
      assert has_element?(view, "#agencies-timezone-band")
      refute has_element?(view, "#agencies-empty")
    end

    test "count links carry the agency filter, or none when the version has one agency", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      create_agency(
        organization,
        version,
        agency_attributes("NCT", "North Coast Transit", "northcoast.example")
      )

      create_agency(
        organization,
        version,
        agency_attributes("HBR", "Harbor Shuttle", "harbor.example")
      )

      routes(organization, version, "NCT", 5)
      routes(organization, version, "HBR", 2)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert Enum.zip(names(doc), count_hrefs(doc)) == [
               {"Harbor Shuttle", ["/gtfs/#{version.id}/routes?agency_id=HBR"]},
               {"North Coast Transit", ["/gtfs/#{version.id}/routes?agency_id=NCT"]}
             ]

      # A second published version of the same organization, so the session's
      # organization scope stays valid.
      single_version = gtfs_version_fixture(organization.id)

      create_agency(
        organization,
        single_version,
        agency_attributes("SOLO", "Solo Transit", "solo.example")
      )

      routes(organization, single_version, "SOLO", 2)

      # Blank-agency routes count toward the only agency, and the unfiltered
      # Routes list says the same thing as one filtered to it (R5, AC-9).
      for index <- 1..3//1 do
        create_route(organization, single_version, %{
          route_id: "BLANK_#{index}",
          route_short_name: "#{index}"
        })
      end

      {:ok, single_view, _html} = live(conn, agencies_path(single_version.id))
      single_doc = LazyHTML.from_fragment(render(single_view))

      assert count_labels(single_doc) == [["View 5 routes for Solo Transit"]]
      assert count_hrefs(single_doc) == [["/gtfs/#{single_version.id}/routes"]]
    end

    test "sorts by name, timezone and route count from the headers", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      create_agency(
        organization,
        version,
        agency_attributes("NCT", "North Coast Transit", "northcoast.example")
      )

      create_agency(
        organization,
        version,
        agency_attributes("HBR", "Harbor Shuttle", "harbor.example")
      )

      create_agency(
        organization,
        version,
        agency_attributes("RCT", "Riverside Community Transport", "riverside.example")
      )

      routes(organization, version, "NCT", 5)
      routes(organization, version, "HBR", 2)

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      # Name ascending is the initial order.
      doc = LazyHTML.from_fragment(render(view))

      assert names(doc) == [
               "Harbor Shuttle",
               "North Coast Transit",
               "Riverside Community Transport"
             ]

      assert header_sorts(doc) == [["ascending"], ["none"], ["none"]]

      render_click(view, "sort", %{"key" => "routes"})

      doc = LazyHTML.from_fragment(render(view))

      assert names(doc) == [
               "Riverside Community Transport",
               "Harbor Shuttle",
               "North Coast Transit"
             ]

      assert header_sorts(doc) == [["none"], ["none"], ["ascending"]]

      # The second click on the same header reverses the order.
      render_click(view, "sort", %{"key" => "routes"})

      doc = LazyHTML.from_fragment(render(view))

      assert names(doc) == [
               "North Coast Transit",
               "Harbor Shuttle",
               "Riverside Community Transport"
             ]

      assert header_sorts(doc) == [["none"], ["none"], ["descending"]]

      # A different header starts that column ascending again.
      render_click(view, "sort", %{"key" => "timezone"})

      doc = LazyHTML.from_fragment(render(view))

      assert header_sorts(doc) == [["none"], ["ascending"], ["none"]]
    end
  end

  describe "the timezone state" do
    setup :editor_setup

    test "names the reason and flags the rows when the agencies disagree", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      create_agency(
        organization,
        version,
        agency_attributes("NCT", "North Coast Transit", "northcoast.example", "America/New_York")
      )

      create_agency(
        organization,
        version,
        agency_attributes("LFT", "Lakefront Transit", "lakefront.example", "America/Chicago")
      )

      routes(organization, version, "NCT", 1)
      routes(organization, version, "LFT", 1)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      # The list stays: the version keeps both agencies and their counts.
      assert Enum.count(rows(doc)) == 2

      assert has_element?(
               view,
               "#agencies-timezone-callout",
               "Agencies use different timezones"
             )

      assert text_of(doc, "#agencies-timezone-callout") =~ "Choose one timezone for this version."
      assert text_of(doc, "#agencies-timezone-band") =~ "Needs review"

      for row <- rows(doc) do
        assert cell_text(row, "Timezone") =~ "Needs review"
      end

      assert cell_text(Enum.at(rows(doc), 0), "Timezone") =~ "America/Chicago"
      assert cell_text(Enum.at(rows(doc), 1), "Timezone") =~ "America/New_York"
    end

    test "names an unrecognized zone and keeps the resolved zone quiet", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      create_agency(
        organization,
        version,
        agency_attributes("BAD", "Bad Zone Transit", "bad.example", "Nowhere/Nothing")
      )

      routes(organization, version, "BAD", 1)

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      assert has_element?(
               view,
               "#agencies-timezone-callout",
               "The agency timezone isn’t recognized"
             )

      assert has_element?(view, "#agencies-timezone-band", "Needs review")
    end
  end

  describe "the first-use empty state" do
    setup :editor_setup

    test "counts the routes that have no agency", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      for index <- 1..3//1 do
        create_route(organization, version, %{
          route_id: "NO_AGENCY_#{index}",
          route_short_name: "#{index}"
        })
      end

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert has_element?(view, "#agencies-empty", "Give your service a name")
      assert text_of(doc, "#agencies-empty") =~ "3 routes have no agency yet."

      assert text_of(doc, "#agencies-empty") =~
               "Creating the first agency assigns these routes to it."

      # No list, no band and no callout without an agency.
      refute has_element?(view, "#agencies")
      refute has_element?(view, "#agencies-timezone-band")
      refute has_element?(view, "#agencies-timezone-callout")

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#agencies-support-note a"),
               "href"
             ) == ["/gtfs/#{version.id}/import"]
    end

    test "reads one route without an agency in the singular", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      create_route(organization, version, %{route_id: "ONLY", route_short_name: "1"})

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      assert has_element?(view, "#agencies-empty", "1 route has no agency yet.")
    end
  end

  describe "the Settings overview" do
    setup :editor_setup

    test "lists Agencies as an available page", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings")
      doc = LazyHTML.from_fragment(render(view))

      assert has_element?(view, "#settings-entry-agencies a", "Agencies")
      assert text_of(doc, "#settings-entry-agencies") =~ "Available"
      refute text_of(doc, "#settings-entry-agencies") =~ "Coming soon"

      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-entry-agencies a"), "href") ==
               [agencies_path(version.id)]
    end
  end

  describe "access and version switching" do
    setup :editor_setup

    test "members without the editor role cannot reach the page", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      member = user_fixture(%{email: editor_email()})

      Accounts.create_user_org_membership(%{
        user_id: member.id,
        organization_id: organization.id,
        roles: []
      })

      member_conn = log_in_user(conn, member, organization: organization)

      assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
               live(member_conn, agencies_path(version.id))
    end

    test "an explicit selection of another published version keeps the section", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, other_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Second Version"})

      selected_version_id = to_string(other_version.id)

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      render_hook(view, "switch_gtfs_version", %{"version" => selected_version_id})

      assert_push_event(view, "gtfs_version_selected", %{version_id: ^selected_version_id})
      assert_redirect(view, agencies_path(other_version.id))

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})

      {:ok, stored_view, _html} = live(conn, agencies_path(version.id))

      render_hook(stored_view, "gtfs_version_loaded", %{"version_id" => staging.id})

      refute_redirected(stored_view)
    end
  end
end
