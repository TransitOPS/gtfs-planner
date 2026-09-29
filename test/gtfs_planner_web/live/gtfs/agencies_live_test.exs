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

  # The Routes link of a table row, or of the one agency's summary.
  @route_links "#agencies a[aria-label], #agency-summary a[aria-label]"

  defp count_labels(doc) do
    doc
    |> LazyHTML.query(@route_links)
    |> Enum.map(&LazyHTML.attribute(&1, "aria-label"))
  end

  defp count_hrefs(doc) do
    doc
    |> LazyHTML.query(@route_links)
    |> Enum.map(&LazyHTML.attribute(&1, "href"))
  end

  defp text_of(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()
  end

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

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

      # The way back to the Settings overview replaces the section tab bar.
      assert LazyHTML.attribute(LazyHTML.query(doc, "#settings-back"), "href") ==
               ["/gtfs/#{version.id}/settings"]

      refute has_element?(view, "#settings-nav")
      refute has_element?(view, "#coming-soon-status")
      refute has_element?(view, "#agencies-empty")

      assert names(doc) == [
               "Harbor Shuttle",
               "North Coast Transit",
               "Riverside Community Transport"
             ]

      assert hosts(doc) == ["harbor.example", "northcoast.example", "riverside.example"]

      assert count_labels(doc) == [
               ["View 2 routes for Harbor Shuttle"],
               ["View 5 routes for North Coast Transit"],
               ["View 0 routes for Riverside Community Transport"]
             ]

      assert cell_text(Enum.at(rows(doc), 1), "Routes") |> String.starts_with?("5")

      # One timezone is a fact about the version, so the panel names it and the
      # table carries no Timezone column and no row needs review.
      assert has_element?(view, "#agencies-timezone-band", "Schedule timezone")
      assert text_of(doc, "#agencies-timezone-value") == "America/New_York"

      assert text_of(doc, "#agencies-timezone-band") =~
               "Every agency in this version shares it."

      refute has_element?(view, "#agencies td[data-label='Timezone']")
      refute has_element?(view, "#agencies-timezone-callout")
      refute has_element?(view, "#agencies", "Needs review")
    end

    test "one agency reads as a summary of what riders see, not as a one-row list", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      agency =
        create_agency(
          organization,
          version,
          Map.merge(agency_attributes("NCT", "North Coast Transit", "northcoast.example"), %{
            agency_phone: "(541) 555-0140",
            agency_email: "riders@northcoast.example",
            agency_lang: "en"
          })
        )

      routes(organization, version, "NCT", 2)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert has_element?(view, "#agency-summary")
      refute has_element?(view, "#agencies")
      refute has_element?(view, "#agencies-empty")
      assert text_of(doc, "h1") == "Agencies"

      assert text_of(doc, "#agency-summary-name") == "North Coast Transit"

      assert LazyHTML.attribute(LazyHTML.query(doc, "#agency-summary-website"), "href") ==
               ["https://northcoast.example"]

      assert text_of(doc, "#agency-summary-phone") == "(541) 555-0140"
      assert text_of(doc, "#agency-summary-email") == "riders@northcoast.example"

      assert LazyHTML.attribute(LazyHTML.query(doc, "#agency-summary-email a"), "href") ==
               ["mailto:riders@northcoast.example"]

      assert text_of(doc, "#agency-summary-fare") == "Not set"
      assert text_of(doc, "#agency-summary-language") == "English (en)"
      assert text_of(doc, "#agency-summary-route-count") == "2"

      # The GTFS terms sit behind a disclosure, and the timezone in its panel.
      assert text_of(doc, "#agency-summary-technical") =~ "NCT"
      assert text_of(doc, "#agency-summary-technical") =~ "America/New_York"
      assert has_element?(view, "#agencies-timezone-band")

      # Edit details is the one row-level action, and it opens the agency.
      assert has_element?(view, "#agency-open-#{agency.id}", "Edit details")
    end

    test "creating a second agency turns the summary into a table of both", %{
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

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      assert has_element?(view, "#agency-summary")
      refute has_element?(view, "#agencies")

      view |> element("#agencies-create") |> render_click()

      # The version already holds a zone, so the drawer takes it instead of asking.
      refute has_element?(view, "#agency-form_agency_timezone")

      view
      |> form("#agency-form", %{
        "agency" => %{"agency_name" => "Harbor Shuttle", "agency_url" => "https://harbor.example"}
      })
      |> render_submit()

      doc = LazyHTML.from_fragment(render(view))

      refute has_element?(view, "#agency-summary")
      assert names(doc) == ["Harbor Shuttle", "North Coast Transit"]
      assert hosts(doc) == ["harbor.example", "northcoast.example"]
      assert has_element?(view, "#agencies-create.btn-primary")
    end

    test "an imported address that is not a plain web address or email stays text", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      create_agency(
        organization,
        version,
        Map.merge(agency_attributes("ODD", "Odd Transit", "odd.example"), %{
          agency_url: "javascript:alert(1)",
          agency_email: "call the office",
          agency_fare_url: "fares soon"
        })
      )

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      refute has_element?(view, "#agency-summary-website")
      refute has_element?(view, "#agency-summary a[href^='javascript:']")
      refute has_element?(view, "#agency-summary-email a")
      refute has_element?(view, "#agency-summary-fare a")
      assert text_of(doc, "#agency-summary-email") == "call the office"
      assert text_of(doc, "#agency-summary-fare") == "fares soon"
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

    test "encodes an agency ID with reserved URL characters and filters the routes by it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      create_agency(
        organization,
        version,
        agency_attributes("A&B 1", "Ampersand Transit", "ampersand.example")
      )

      create_agency(
        organization,
        version,
        agency_attributes("HBR", "Harbor Shuttle", "harbor.example")
      )

      [ampersand_route] = routes(organization, version, "A&B 1", 1)
      [harbor_route] = routes(organization, version, "HBR", 1)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      assert Enum.zip(names(doc), count_hrefs(doc)) == [
               {"Ampersand Transit", ["/gtfs/#{version.id}/routes?agency_id=A%26B+1"]},
               {"Harbor Shuttle", ["/gtfs/#{version.id}/routes?agency_id=HBR"]}
             ]

      [href] =
        doc
        |> LazyHTML.query("#agencies a[aria-label*='Ampersand']")
        |> LazyHTML.attribute("href")

      {:ok, routes_view, _html} = live(conn, href)

      assert has_element?(routes_view, "tr#routes-#{ampersand_route.id}")
      refute has_element?(routes_view, "tr#routes-#{harbor_route.id}")
      assert has_element?(routes_view, "select[name='agency_id'] option[selected]", "A&B 1")
    end

    test "sorts by name and route count from the headers", %{
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

      # Name ascending is the initial order. The Rider contact column does not
      # sort, and the Timezone column is absent while the agencies agree.
      doc = LazyHTML.from_fragment(render(view))

      assert names(doc) == [
               "Harbor Shuttle",
               "North Coast Transit",
               "Riverside Community Transport"
             ]

      assert header_sorts(doc) == [["ascending"], [], ["none"]]

      render_click(view, "sort", %{"key" => "routes"})

      doc = LazyHTML.from_fragment(render(view))

      assert names(doc) == [
               "Riverside Community Transport",
               "Harbor Shuttle",
               "North Coast Transit"
             ]

      assert header_sorts(doc) == [["none"], [], ["ascending"]]

      # The second click on the same header reverses the order.
      render_click(view, "sort", %{"key" => "routes"})

      doc = LazyHTML.from_fragment(render(view))

      assert names(doc) == [
               "North Coast Transit",
               "Harbor Shuttle",
               "Riverside Community Transport"
             ]

      assert header_sorts(doc) == [["none"], [], ["descending"]]
    end

    test "sorts by timezone from the Timezone column that a timezone problem adds", %{
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

      create_agency(
        organization,
        version,
        agency_attributes("DEN", "Front Range Transit", "frontrange.example", "America/Denver")
      )

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      doc = LazyHTML.from_fragment(render(view))

      assert names(doc) == ["Front Range Transit", "Lakefront Transit", "North Coast Transit"]
      assert header_sorts(doc) == [["ascending"], [], ["none"], ["none"]]

      # A different header starts that column ascending, and America/Chicago
      # sorts before America/Denver and America/New_York.
      render_click(view, "sort", %{"key" => "timezone"})

      doc = LazyHTML.from_fragment(render(view))

      assert names(doc) == ["Lakefront Transit", "Front Range Transit", "North Coast Transit"]
      assert header_sorts(doc) == [["none"], [], ["ascending"], ["none"]]
    end

    test "shows the phone first and the email under it, and says when neither is set", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      create_agency(
        organization,
        version,
        Map.merge(agency_attributes("BOTH", "Both Transit", "both.example"), %{
          agency_phone: "(541) 555-0140",
          agency_email: "both@example.com"
        })
      )

      create_agency(
        organization,
        version,
        Map.merge(agency_attributes("MAIL", "Mail Transit", "mail.example"), %{
          agency_email: "mail@example.com"
        })
      )

      create_agency(
        organization,
        version,
        agency_attributes("NONE", "None Transit", "none.example")
      )

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      doc = LazyHTML.from_fragment(render(view))

      # Rows are in name order: Both, Mail, None.
      assert Enum.map(rows(doc), &(&1 |> cell("Rider contact") |> LazyHTML.text() |> squish())) ==
               ["(541) 555-0140 both@example.com", "mail@example.com", "No contact details"]
    end

    test "the primary action follows the state of the page", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      only =
        create_agency(
          organization,
          version,
          agency_attributes("NCT", "North Coast Transit", "northcoast.example")
        )

      # One agency: editing it is the common task, so Create agency steps back.
      {:ok, view, _html} = live(conn, agencies_path(version.id))

      assert has_element?(view, "#agency-open-#{only.id}.btn-primary")
      assert has_element?(view, "#agencies-create.btn-outline")
      refute has_element?(view, "#agencies-create.btn-primary")

      create_agency(
        organization,
        version,
        agency_attributes("HBR", "Harbor Shuttle", "harbor.example")
      )

      # Two agreeing agencies: adding another is the primary.
      {:ok, view, _html} = live(conn, agencies_path(version.id))

      assert has_element?(view, "#agencies-create.btn-primary")

      create_agency(
        organization,
        version,
        agency_attributes("LFT", "Lakefront Transit", "lakefront.example", "America/Chicago")
      )

      # A timezone problem outranks both, so resolving it is the only primary.
      {:ok, view, _html} = live(conn, agencies_path(version.id))

      assert has_element?(view, "#agencies-resolve-timezones.btn-primary")
      assert has_element?(view, "#agencies-create.btn-outline")
      refute has_element?(view, "#agencies-create.btn-primary")
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

    test "lists Agencies as a working page, without the Coming soon badge", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings")
      doc = LazyHTML.from_fragment(render(view))

      assert has_element?(view, "#settings-entry-agencies-title", "Agencies")
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
