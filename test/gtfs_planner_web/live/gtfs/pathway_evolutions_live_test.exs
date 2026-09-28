defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsLiveTest do
  @moduledoc """
  The Evolutions destination through its ordinary route: the station tab that
  opens it, the scoped closure list it renders, its empty and unreachable
  states, the exact natural IDs its search and links carry, and the editor
  guard around it. Assertions are authored from AC-1, AC-7, AC-36 and AC-39,
  not from the implementation's internals.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

  @station_stop %{
    stop_id: "EVOLUTIONS_STATION",
    stop_name: "Evolutions Test Station",
    location_type: 1,
    parent_station: nil
  }

  # A slash and a space in one pathway ID: a `?pathway=` link has to carry the
  # exact value, encoded, and the search has to match it exactly.
  @punctuated_pathway_id "PW-E/2 main"

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

  defp evolutions_path(version, stop_id) do
    "/gtfs/#{version.id}/stops/#{stop_id}/evolutions"
  end

  defp assert_missing_station(result, version_id) do
    assert {:error, {:live_redirect, %{to: to, flash: %{"error" => "Station not found"}}}} =
             result

    assert to == "/gtfs/#{version_id}/stops"
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#closures-list tr[data-closure-id]")
    |> Enum.map(&LazyHTML.attribute(&1, "data-closure-id"))
    |> List.flatten()
  end

  # One station with an entrance, a mezzanine and a platform, three pathways
  # (including a punctuated elevator ID) and two closures on one native
  # calendar: an ordinary daytime window and one that runs into the next
  # service day.
  defp station_with_closures(organization, version) do
    station = stop_fixture(organization.id, version.id, @station_stop)

    entrance =
      stop_fixture(organization.id, version.id, %{
        stop_id: "EVOLUTIONS_ENTRANCE",
        stop_name: "North entrance",
        location_type: 2,
        parent_station: station.stop_id
      })

    mezzanine =
      stop_fixture(organization.id, version.id, %{
        stop_id: "EVOLUTIONS_MEZZANINE",
        stop_name: "Mezzanine hall",
        location_type: 0,
        parent_station: station.stop_id
      })

    platform =
      stop_fixture(organization.id, version.id, %{
        stop_id: "EVOLUTIONS_PLATFORM",
        stop_name: "Platform 1",
        location_type: 0,
        parent_station: station.stop_id
      })

    walkway =
      pathway_fixture(organization.id, version.id, entrance.stop_id, mezzanine.stop_id, %{
        pathway_id: "PW-WALK",
        pathway_mode: 1,
        is_bidirectional: true
      })

    elevator =
      pathway_fixture(organization.id, version.id, mezzanine.stop_id, platform.stop_id, %{
        pathway_id: @punctuated_pathway_id,
        pathway_mode: 5,
        is_bidirectional: true
      })

    stairs =
      pathway_fixture(organization.id, version.id, mezzanine.stop_id, platform.stop_id, %{
        pathway_id: "PW-STAIR",
        pathway_mode: 2,
        is_bidirectional: false
      })

    calendar_fixture(organization.id, version.id, %{service_id: "CAL_DAILY"})

    daytime =
      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: elevator.pathway_id,
        service_id: "CAL_DAILY",
        start_time: 32_400,
        end_time: 54_000
      })

    overnight =
      pathway_evolution_fixture(organization.id, version.id, %{
        pathway_id: stairs.pathway_id,
        service_id: "CAL_DAILY",
        start_time: 79_200,
        end_time: 93_600
      })

    %{
      station: station,
      entrance: entrance,
      mezzanine: mezzanine,
      platform: platform,
      walkway: walkway,
      elevator: elevator,
      stairs: stairs,
      daytime: daytime,
      overnight: overnight
    }
  end

  describe "the station closure list" do
    setup :editor_setup

    test "opens through the station tab, which marks Evolutions current exactly once",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime, overnight: overnight} =
        station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      doc = LazyHTML.from_fragment(render(view))

      assert Enum.count(LazyHTML.query(doc, "h1")) == 1

      assert LazyHTML.text(LazyHTML.query(doc, "h1")) |> String.trim() ==
               station.stop_name

      assert has_element?(view, "#closures-title", "Closures at this station")
      assert has_element?(view, "#closures-count", "2 closures")

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#station-sub-nav a[aria-current='page']"),
               "href"
             ) == [evolutions_path(version, station.stop_id)]

      assert Enum.count(LazyHTML.query(doc, "#station-sub-nav a[aria-current='page']")) == 1

      # No placeholder copy survives anywhere on the page.
      refute render(view) =~ "Coming soon"
      refute has_element?(view, "#coming-soon")

      # The rows are the station's closures, keyed by their own UUIDs, and each
      # one names the pathway, its exact ID, the calendar and the window.
      assert Enum.sort(row_ids(view)) == Enum.sort([daytime.id, overnight.id])

      assert has_element?(
               view,
               "#closure-open-#{daytime.evolution.id}",
               "Elevator · Mezzanine hall ↔ Platform 1"
             )

      assert render(view) =~ @punctuated_pathway_id
      assert render(view) =~ "CAL_DAILY"
      assert render(view) =~ "09:00–15:00"
      assert render(view) =~ "22:00–26:00"
      assert render(view) =~ "Ends the next day"

      # The stream container is marked, which is what the stream API requires
      # for row inserts and removals to be applied to it.
      assert LazyHTML.attribute(LazyHTML.query(doc, "#closures-list"), "phx-update") == ["stream"]

      # Outcomes are announced in a polite live region, not by color.
      assert has_element?(view, ~s(#evolutions-status[role="status"][aria-live="polite"]))
    end

    test "the keyboard list marks one row current and keeps the other row addressable",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      assert has_element?(view, "#closure-open-#{daytime.evolution.id}[aria-current='false']")

      html =
        view
        |> element("#closure-open-#{daytime.evolution.id}")
        |> render_click()

      assert html =~ ~s(aria-current="true")
      assert has_element?(view, "#evolutions-status", "Selected closure on Elevator")
      assert row_ids(view) |> length() == 2
    end

    test "search narrows to one exact pathway ID, punctuation included",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime, mezzanine: mezzanine, entrance: entrance} =
        station_with_closures(organization, version)

      # A second pathway whose ID starts with the first one: an exact ID is
      # never widened into a longer one.
      prefix_pathway =
        pathway_fixture(organization.id, version.id, mezzanine.stop_id, entrance.stop_id, %{
          pathway_id: "#{@punctuated_pathway_id} extension",
          pathway_mode: 1,
          is_bidirectional: true
        })

      prefix_closure =
        pathway_evolution_fixture(organization.id, version.id, %{
          pathway_id: prefix_pathway.pathway_id,
          service_id: "CAL_DAILY",
          start_time: 61_200,
          end_time: 64_800
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      assert length(row_ids(view)) == 3

      html =
        view
        |> form("#closures-search-form", %{"search" => @punctuated_pathway_id})
        |> render_change()

      assert row_ids(view) == [daytime.id]
      refute html =~ prefix_closure.id
      assert html =~ "1 of 3 closures match"
    end

    test "a filtered empty result differs from a first-use station",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      refute has_element?(view, "#closures-filtered-empty")

      filtered =
        view
        |> form("#closures-search-form", %{"search" => "no such closure"})
        |> render_change()

      assert filtered =~ "closures-filtered-empty"
      assert has_element?(view, "#closures-filtered-empty", "No closures match “no such closure”")
      assert has_element?(view, "#closures-filtered-empty", "Clear search")
      refute has_element?(view, "#closures-empty")
      assert has_element?(view, "#closures-count", "0 of 2 closures match")

      cleared =
        view
        |> element("#closures-clear-search")
        |> render_click()

      assert row_ids(view) |> length() == 2
      assert cleared =~ "Showing every closure at this station"
      refute has_element?(view, "#closures-filtered-empty")

      # A station with pathways and calendars but nothing scheduled is the
      # first-use state: it offers to create one instead of clearing a search.
      empty_station =
        stop_fixture(organization.id, version.id, %{
          @station_stop
          | stop_id: "EVOLUTIONS_EMPTY",
            stop_name: "Evolutions Empty Station"
        })

      {:ok, empty_view, _html} = live(conn, evolutions_path(version, empty_station.stop_id))

      assert has_element?(
               empty_view,
               "#closures-empty",
               "No closures scheduled at Evolutions Empty Station"
             )

      assert has_element?(empty_view, "#closures-empty #new-closure", "Create closure")
      refute has_element?(empty_view, "#closures-filtered-empty")
      refute has_element?(empty_view, "#closures-count")
    end

    test "?pathway selects the exact pathway and ignores a foreign one",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime, elevator: elevator} =
        station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)

      linked =
        evolutions_path(version, station.stop_id) <>
          "?pathway=" <> URI.encode_www_form(@punctuated_pathway_id)

      {:ok, view, _html} = live(conn, linked)

      assert row_ids(view) == [daytime.id]

      assert has_element?(
               view,
               "#closures-search[value='#{@punctuated_pathway_id}']"
             )

      assert has_element?(view, "#pathway-option-#{elevator.id}[aria-current='true']")
      assert has_element?(view, "#closure-pathway-list #pathway-option-#{elevator.id}")

      foreign =
        evolutions_path(version, station.stop_id) <>
          "?pathway=" <> URI.encode_www_form("PW-OTHER")

      {:ok, foreign_view, _html} = live(conn, foreign)

      assert foreign_view |> row_ids() |> length() == 2
      refute has_element?(foreign_view, "#closure-pathway-list button[aria-current='true']")
    end

    test "?closure selects one closure of this station and exposes nothing else",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)

      linked = evolutions_path(version, station.stop_id) <> "?closure=#{daytime.evolution.id}"
      {:ok, view, _html} = live(conn, linked)

      assert has_element?(view, "#closure-open-#{daytime.evolution.id}[aria-current='true']")
      assert has_element?(view, "#evolutions-status", "Selected closure on Elevator")
      assert row_ids(view) |> length() == 2

      foreign = evolutions_path(version, station.stop_id) <> "?closure=#{Ecto.UUID.generate()}"
      {:ok, foreign_view, _html} = live(conn, foreign)

      assert row_ids(foreign_view) |> length() == 2
      refute render(foreign_view) =~ "Selected closure on"
    end

    test "pathways are listed with their exact IDs for later selection",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, elevator: elevator, stairs: stairs, walkway: walkway} =
        station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      doc = LazyHTML.from_fragment(render(view))

      assert Enum.count(LazyHTML.query(doc, "#closure-pathway-list button")) == 3

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#pathway-option-#{elevator.id}"),
               "data-pathway-id"
             ) == [@punctuated_pathway_id]

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#pathway-option-#{stairs.id}"),
               "data-pathway-id"
             ) == ["PW-STAIR"]

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#pathway-option-#{walkway.id}"),
               "data-pathway-id"
             ) == ["PW-WALK"]

      # A directional pathway reads with one arrow, a bidirectional one with two.
      assert render(view) =~ "Mezzanine hall → Platform 1"
      assert render(view) =~ "Mezzanine hall ↔ Platform 1"
    end

    test "the no-pathways state explains what to do instead",
         %{conn: conn, user: user, organization: organization, version: version} do
      station =
        stop_fixture(organization.id, version.id, %{
          @station_stop
          | stop_id: "EVOLUTIONS_NO_PATHWAYS",
            stop_name: "Evolutions No Pathway Station"
        })

      stop_fixture(organization.id, version.id, %{
        stop_id: "EVOLUTIONS_NO_PATHWAYS_CHILD",
        stop_name: "Unconnected platform",
        location_type: 0,
        parent_station: station.stop_id
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      assert has_element?(view, "#closures-no-pathways", "has no pathways yet")
      refute has_element?(view, "#closures-empty")
      refute has_element?(view, "#closure-locator")

      assert has_element?(
               view,
               "#closures-open-floorplans[href='/gtfs/#{version.id}/stops/#{station.stop_id}/diagram']",
               "Open floorplans"
             )
    end

    test "the no-calendars state points at the calendars page",
         %{conn: conn, user: user, organization: organization, version: version} do
      station = stop_fixture(organization.id, version.id, @station_stop)

      platform =
        stop_fixture(organization.id, version.id, %{
          stop_id: "EVOLUTIONS_NOCAL_PLATFORM",
          stop_name: "Platform without calendars",
          location_type: 0,
          parent_station: station.stop_id
        })

      pathway_fixture(organization.id, version.id, station.id, platform.stop_id, %{
        pathway_id: "PW-NOCAL",
        pathway_mode: 1,
        is_bidirectional: true
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      assert has_element?(view, "#closures-no-calendars", "No calendars in #{version.name}")
      refute has_element?(view, "#closures-no-pathways")

      assert has_element?(
               view,
               "#closures-open-calendars[href='/gtfs/#{version.id}/calendars']",
               "Open calendars"
             )
    end
  end

  describe "station scope" do
    setup :editor_setup

    test "an absent, foreign, unpublished or non-station target is not found",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_closures(organization, version)

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      foreign_station =
        stop_fixture(other_organization.id, other_version.id, %{
          @station_stop
          | stop_id: "EVOLUTIONS_FOREIGN",
            stop_name: "Foreign Evolutions Station"
        })

      platform =
        stop_fixture(organization.id, version.id, %{
          stop_id: "EVOLUTIONS_NOT_A_STATION",
          stop_name: "Not A Station",
          location_type: 0
        })

      {:ok, other_local_version} =
        Versions.create_gtfs_version(organization.id, %{name: "Other Version"})

      local_other_version_station =
        stop_fixture(organization.id, other_local_version.id, %{
          @station_stop
          | stop_id: "EVOLUTIONS_OTHER_VERSION",
            stop_name: "Other Version Station"
        })

      conn = log_in_user(conn, user, organization: organization)

      assert_missing_station(live(conn, evolutions_path(version, "NO_SUCH_STATION")), version.id)

      assert_missing_station(
        live(conn, evolutions_path(version, foreign_station.stop_id)),
        version.id
      )

      assert_missing_station(
        live(conn, evolutions_path(version, local_other_version_station.stop_id)),
        version.id
      )

      assert_missing_station(live(conn, evolutions_path(version, platform.stop_id)), version.id)

      # The refusal reads no closure, pathway or calendar of the target scope.
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))
      refute render(view) =~ "Foreign Evolutions Station"
      refute render(view) =~ "Other Version Station"
    end

    test "a station in another organization with the same external ID shows the local rows",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_closures(organization, version)

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      other_station =
        stop_fixture(other_organization.id, other_version.id, %{
          @station_stop
          | stop_name: "Foreign Evolutions Station"
        })

      other_platform =
        stop_fixture(other_organization.id, other_version.id, %{
          stop_id: "FOREIGN_PLATFORM",
          stop_name: "Foreign platform",
          location_type: 0,
          parent_station: other_station.stop_id
        })

      pathway_fixture(
        other_organization.id,
        other_version.id,
        other_station.id,
        other_platform.stop_id,
        %{
          pathway_id: "PW-FOREIGN",
          pathway_mode: 1,
          is_bidirectional: true
        }
      )

      pathway_evolution_fixture(other_organization.id, other_version.id, %{
        pathway_id: "PW-FOREIGN",
        service_id: "SVC_FOREIGN",
        start_time: 3_600,
        end_time: 7_200
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      html = render(view)

      assert html =~ station.stop_name
      assert html =~ "PW-E/2 main"
      refute html =~ "Foreign Evolutions Station"
      refute html =~ "PW-FOREIGN"
      refute html =~ "SVC_FOREIGN"
    end
  end

  describe "access" do
    setup :editor_setup

    test "a signed-in member without the editor role is redirected",
         %{conn: conn, organization: organization, version: version} do
      member = member_with_roles(organization, ["pathways_studio_admin"])
      member_conn = log_in_user(conn, member, organization: organization)

      assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
               live(member_conn, evolutions_path(version, "EVOLUTIONS_STATION"))

      roleless = member_with_roles(organization, [])
      roleless_conn = log_in_user(conn, roleless, organization: organization)

      assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
               live(roleless_conn, evolutions_path(version, "EVOLUTIONS_STATION"))
    end

    test "an unauthenticated visit follows the existing login redirect",
         %{version: version} do
      conn = build_conn() |> init_test_session(%{})

      assert redirected_to(get(conn, evolutions_path(version, "EVOLUTIONS_STATION"))) ==
               "/users/log_in"
    end
  end
end
