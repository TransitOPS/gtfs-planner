defmodule GtfsPlannerWeb.Gtfs.RouteAgencyOnboardingLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Repo

  # The first-agency onboarding, its assign-routes callout and the handoff to the
  # New route drawer (AC-24, AC-25; CL-19, EV-28). Every case drives the real
  # router and the real `FeedSettings` writes against the local test PostgreSQL
  # under the SQL sandbox, so the state the page renders is the state the context
  # stored.
  defp editor_scope(%{conn: conn}) do
    organization = organization_fixture()

    user =
      user_fixture(%{
        email: "routes-onboarding-#{System.unique_integer([:positive])}@example.com"
      })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp scoped_agencies(organization, version) do
    Repo.all(
      from a in Agency,
        where: a.organization_id == ^organization.id and a.gtfs_version_id == ^version.id,
        order_by: a.agency_name
    )
  end

  defp scoped_routes(organization, version) do
    Repo.all(
      from r in Route,
        where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id,
        order_by: r.route_id
    )
  end

  defp agency_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        agency_name: "North Coast Transit",
        agency_url: "https://northcoast.example",
        agency_timezone: "America/Chicago"
      },
      attrs
    )
  end

  describe "a version with no agency and no routes" do
    setup :editor_scope

    test "shows the onboarding instead of the first-use empty state", %{
      conn: conn,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-agency-onboarding")
      refute has_element?(view, "#routes-first-use-empty")

      assert has_element?(view, "#routes-agency-onboarding", "Before your first route")

      assert has_element?(
               view,
               "#routes-agency-onboarding",
               "Who operates this service?"
             )

      assert has_element?(
               view,
               "#routes-agency-onboarding",
               "Journey planners need an agency name, website, and timezone. Set those once, then create your first route."
             )

      assert has_element?(view, "#routes-set-up-agency", "Set up agency")

      assert has_element?(
               view,
               "#routes-onboarding-import[href='/gtfs/#{version.id}/import']",
               "Import an existing GTFS feed instead"
             )

      # The agency is the page's primary action here, so Create route steps back
      # to the secondary treatment it has beside the first-use import action.
      assert has_element?(view, "#new-route-trigger.btn-outline")
    end

    test "the onboarding button opens the agency drawer with the timezone field", %{
      conn: conn,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#routes-set-up-agency") |> render_click()

      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='true']")
      assert has_element?(view, "#routes-agency-form")
      assert has_element?(view, "#routes-agency-drawer-title", "Set up your agency")

      # The version's first agency carries the schedule timezone field and the
      # datalist the server validates against (R2, INV-4).
      assert has_element?(view, "#routes-agency-form_agency_timezone")
      assert has_element?(view, "#routes-agency-form_agency_timezone-zones")
      assert has_element?(view, "#routes-agency-form_agency_name")
      assert has_element?(view, "#routes-agency-form_agency_url")
      assert has_element?(view, "#routes-agency-unsaved-guard[data-dirty='false']")

      # The onboarding state no longer has a route drawer to open.
      refute has_element?(view, "#new-route-form")
    end

    test "the header Create route opens the agency drawer instead of the route drawer", %{
      conn: conn,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#new-route-trigger") |> render_click()

      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='true']")
      assert has_element?(view, "#routes-agency-form")
      refute has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      refute has_element?(view, "#new-route-form")
    end

    test "saving the agency opens the New route drawer with it selected", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#routes-set-up-agency") |> render_click()

      view
      |> form("#routes-agency-form", agency: agency_attrs())
      |> render_submit()

      assert [agency] = scoped_agencies(organization, version)
      assert agency.agency_name == "North Coast Transit"
      assert agency.agency_url == "https://northcoast.example"
      assert agency.agency_timezone == "America/Chicago"
      assert agency.agency_id == "north_coast_transit"

      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-info", "North Coast Transit created.")
      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")

      # The handoff reads the version's agencies back from the database, so the
      # drawer offers the agency it just created and nothing stale (FH-33).
      # The version now has exactly one agency, so the shared control is the
      # read-only agency, not a select.
      assert has_element?(view, "#new-route-agency-name", "North Coast Transit")

      assert has_element?(view, "#new-route-agency[value='north_coast_transit']")

      # ... and the route that drawer creates carries that agency, with the
      # identifier the command allocates rather than one the drawer invented.
      view
      |> form("#new-route-form", route: %{route_type: "3", route_short_name: "E1"})
      |> render_submit()

      assert [route] = scoped_routes(organization, version)
      assert route.route_id == "E1"
      assert route.agency_id == "north_coast_transit"
      assert_redirect(view, "/gtfs/#{version.id}/routes/E1?created=1")
    end

    test "an invalid submit marks the fields and creates nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#routes-set-up-agency") |> render_click()

      view
      |> form("#routes-agency-form",
        agency: %{agency_name: "", agency_url: "northcoast.example", agency_timezone: "Mars/Base"}
      )
      |> render_submit()

      assert has_element?(view, "#routes-agency-form_agency_name-error")
      assert has_element?(view, "#routes-agency-form_agency_url-error")
      assert has_element?(view, "#routes-agency-form_agency_timezone-error")
      assert has_element?(view, "#routes-agency-form-error")

      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='true']")
      assert scoped_agencies(organization, version) == []

      assert_push_event(view, "focus_form_error", %{
        form_id: "routes-agency-form",
        fallback_id: "routes-agency-form-error"
      })
    end
  end

  describe "a version with routes and no agency" do
    setup :editor_scope

    test "shows the callout beside the catalog", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route_fixture(organization.id, version.id, %{route_id: "UN1"})
      route_fixture(organization.id, version.id, %{route_id: "UN2"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      assert has_element?(view, "#routes-no-agency")
      assert has_element?(view, "#routes-no-agency", "These routes have no agency")

      assert has_element?(
               view,
               "#routes-no-agency",
               "Set up the agency that operates them. Creating it assigns it to all 2 routes."
             )

      assert has_element?(view, "#routes-set-up-agency", "Set up agency")
      refute has_element?(view, "#routes-agency-onboarding")
      refute has_element?(view, "#routes-first-use-empty")

      # The catalog is still the page's main content.
      assert has_element?(view, "#routes a", "UN1")
      assert has_element?(view, "#routes a", "UN2")
    end

    test "setting the agency up assigns both routes and flashes the count", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route_fixture(organization.id, version.id, %{route_id: "UN1"})
      route_fixture(organization.id, version.id, %{route_id: "UN2"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#routes-set-up-agency") |> render_click()

      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='true']")

      view
      |> form("#routes-agency-form", agency: agency_attrs())
      |> render_submit()

      assert [agency] = scoped_agencies(organization, version)
      assert agency.agency_id == "north_coast_transit"

      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='false']")

      assert has_element?(
               view,
               "#flash-info",
               "North Coast Transit created. 2 routes now use it."
             )

      # The catalog reloads through the patch, so the callout is gone and the
      # routes now name the agency that claimed them (R6, AC-25).
      refute has_element?(view, "#routes-no-agency")
      assert_patch(view)

      # The route drawer is only for creating the first route; assigning existing
      # routes does not open it (AC-25).
      refute has_element?(view, "#new-route-drawer-overlay[data-open='true']")
      refute has_element?(view, "#new-route-form")

      assert Enum.map(scoped_routes(organization, version), & &1.agency_id) == [
               "north_coast_transit",
               "north_coast_transit"
             ]
    end

    test "filters that match nothing keep the constrained empty state", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route_fixture(organization.id, version.id, %{route_id: "UN1"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes?search=nonexistent")

      assert has_element?(view, "#routes-constrained-empty")
      refute has_element?(view, "#routes-no-agency")
      refute has_element?(view, "#routes-agency-onboarding")
    end

    test "a changed draft asks to discard before it closes", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route_fixture(organization.id, version.id, %{route_id: "UN1"})

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#routes-set-up-agency") |> render_click()

      view
      |> form("#routes-agency-form", agency: %{agency_name: "North"})
      |> render_change()

      assert has_element?(view, "#routes-agency-unsaved-guard[data-dirty='true']")
      assert has_element?(view, "#routes-agency-unsaved", "Unsaved changes")

      view |> element("#routes-agency-drawer-close") |> render_click()

      assert has_element?(view, "#routes-agency-discard[role='alertdialog']")
      assert has_element?(view, "#routes-agency-discard-title", "Discard unsaved changes?")
      assert has_element?(view, "#routes-agency-discard-body", "Your entries will be lost.")

      # Keep editing: the drawer stays up with the draft intact.
      view |> element("#routes-agency-discard-cancel") |> render_click()

      assert has_element?(view, "#routes-agency-form_agency_name[value='North']")
      refute has_element?(view, "#routes-agency-discard")

      # Discard: nothing was created and the next open starts blank.
      view |> element("#routes-agency-drawer-close") |> render_click()
      view |> element("#routes-agency-discard-confirm") |> render_click()

      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='false']")
      assert scoped_agencies(organization, version) == []

      view |> element("#routes-set-up-agency") |> render_click()
      refute has_element?(view, "#routes-agency-form_agency_name[value='North']")
    end
  end

  describe "write boundary" do
    setup :editor_scope

    test "a submit while the drawer is closed writes nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      render_submit(view, "save_agency_setup", %{"agency" => agency_attrs()})

      assert scoped_agencies(organization, version) == []
    end

    test "crafted scope and unexposed fields neither move the row nor are stored", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#routes-set-up-agency") |> render_click()

      render_submit(view, "save_agency_setup", %{
        "agency" => %{
          "agency_name" => "Sneaky Transit",
          "agency_url" => "https://sneaky.example",
          "agency_timezone" => "America/Chicago",
          "agency_id" => "HACKED",
          "organization_id" => other_organization.id,
          "gtfs_version_id" => other_version.id
        }
      })

      assert [agency] = scoped_agencies(organization, version)
      assert agency.agency_id == "sneaky_transit"
      assert agency.organization_id == organization.id
      assert agency.gtfs_version_id == version.id

      assert Repo.aggregate(
               from(a in Agency, where: a.gtfs_version_id == ^other_version.id),
               :count
             ) == 0
    end

    test "a removed editor role blocks the create", %{
      conn: conn,
      organization: organization,
      version: version,
      user: user
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#routes-set-up-agency") |> render_click()

      Accounts.get_user_org_membership(user.id, organization.id)
      |> Ecto.Changeset.change(roles: [])
      |> Repo.update!()

      view
      |> form("#routes-agency-form", agency: agency_attrs())
      |> render_submit()

      assert scoped_agencies(organization, version) == []
      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-error", "no longer have editor access")
    end

    # The version can gain agencies while this drawer is open. The context reads
    # the version's own agency set under its lock, so the write follows the state
    # it finds rather than the state the drawer was opened with (INV-2, FH-33).
    test "a version that gained one agency makes this a later agency", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#routes-set-up-agency") |> render_click()

      agency_fixture(organization.id, version.id, %{
        agency_id: "EARLY",
        agency_name: "Early Transit",
        agency_timezone: "America/Los_Angeles"
      })

      view
      |> form("#routes-agency-form", agency: agency_attrs())
      |> render_submit()

      assert [early, late] = scoped_agencies(organization, version)
      assert early.agency_id == "EARLY"
      assert late.agency_name == "North Coast Transit"
      # A later agency takes the zone the version already holds (R2).
      assert late.agency_timezone == "America/Los_Angeles"

      assert has_element?(view, "#new-route-drawer-overlay[data-open='true']")

      # The version now holds two agencies, so the drawer's shared control is
      # the select, and it opens on the agency the editor just created.
      assert has_element?(view, "#new-route-agency option[selected][value='north_coast_transit']")
      assert has_element?(view, "#new-route-agency option", "Early Transit")
    end

    test "a version that gained disagreeing zones refuses and writes nothing", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes")

      view |> element("#routes-set-up-agency") |> render_click()

      agency_fixture(organization.id, version.id, %{
        agency_id: "EAST",
        agency_name: "East Transit",
        agency_timezone: "America/New_York"
      })

      agency_fixture(organization.id, version.id, %{
        agency_id: "WEST",
        agency_name: "West Transit",
        agency_timezone: "America/Los_Angeles"
      })

      view
      |> form("#routes-agency-form", agency: agency_attrs())
      |> render_submit()

      assert Enum.map(scoped_agencies(organization, version), & &1.agency_id) == ["EAST", "WEST"]
      assert has_element?(view, "#routes-agency-drawer-overlay[data-open='false']")
      assert has_element?(view, "#flash-error", "no longer share one timezone")
      refute has_element?(view, "#new-route-drawer-overlay[data-open='true']")
    end
  end
end
