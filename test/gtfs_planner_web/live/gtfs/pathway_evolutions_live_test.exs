defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsLiveTest do
  @moduledoc """
  The Evolutions destination through its ordinary route: the station tab that
  opens it, the scoped closure list it renders, its empty and unreachable
  states, the exact natural IDs its search and links carry, the editor guard
  around it, and the confirmed deletion of a saved closure. Assertions are
  authored from AC-1, AC-6, AC-7, AC-36, AC-37 and AC-39, not from the
  implementation's internals.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.PathwayEvolutions
  alias GtfsPlanner.Repo
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

  # A confirmation dialog is open when the server rendered it open; the native
  # `open` attribute is the client hook's business, so the test reads the state
  # the server owns.
  defp dialog_open?(html, id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{id}[data-open='true']")
    |> Enum.count() > 0
  end

  # Changing one field of the open editor the way a reader does: the whole tuple
  # is submitted and only the named values differ from the saved row.
  defp change_editor(view, values) do
    view |> form("#closure-form", %{"closure" => values}) |> render_change()
  end

  # Fills the open editor's form and submits it, the way an editor does after
  # choosing Create closure or a row in the list. Values default to the tuple
  # the fixture station already holds, so a caller only names what it changes.
  defp save_new_closure(view, overrides) do
    view |> element("#new-closure") |> render_click()

    params =
      Map.merge(
        %{
          "pathway_id" => "PW-WALK",
          "service_id" => "CAL_DAILY",
          "start_time" => "10:00",
          "end_time" => "12:00",
          "note" => ""
        },
        overrides
      )

    view |> form("#closure-form", %{"closure" => params}) |> render_submit()
  end

  # One closure row of this station's snapshot, addressed by its exact natural
  # ID and service-day start rather than by a UUID the caller cannot know.
  defp closure_on!(organization, version, stop_id, pathway_id, start_time) do
    {:ok, station_data} = Gtfs.station_closures(organization.id, version.id, stop_id)

    Enum.find(station_data.closures, fn row ->
      row.evolution.pathway_id == pathway_id and row.evolution.start_time == start_time
    end) || flunk("no closure on #{pathway_id} starting at #{start_time}")
  end

  # A change committed by another session through the ordinary context, using
  # the fingerprint the row had when this test read it.
  defp edit_from_another_session!(organization, version, user, stop_id, id, attrs) do
    row = Repo.get!(PathwayEvolution, id)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: stop_id,
      actor_id: user.id,
      actor_email: user.email
    }

    {:ok, _result} =
      Gtfs.update_pathway_evolution(id, attrs, PathwayEvolutions.fingerprint(row), audit)
  end

  defp revoke_editor_role!(user, organization) do
    membership = Accounts.get_user_org_membership(user.id, organization.id)
    {:ok, _revoked} = Accounts.update_user_org_membership(membership, %{roles: []})
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
               "#closure-open-#{daytime.id}",
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

      assert has_element?(view, "#closure-open-#{daytime.id}[aria-current='false']")

      html =
        view
        |> element("#closure-open-#{daytime.id}")
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

      linked = evolutions_path(version, station.stop_id) <> "?closure=#{daytime.id}"
      {:ok, view, _html} = live(conn, linked)

      assert has_element?(view, "#closure-open-#{daytime.id}[aria-current='true']")
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

  describe "the closure editor" do
    setup :editor_setup

    test "creating a closure persists one audited row that reloads identically",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      # The idle editor says nothing is selected and offers no form to save.
      assert has_element?(view, "#closure-idle", "No closure selected")
      refute has_element?(view, "#closure-form")

      view |> element("#new-closure") |> render_click()

      assert has_element?(view, "#closure-editor-title", "New closure")
      assert_push_event(view, "focus_scoped_target", %{id: "closure-pathway"})

      # The pickers offer this station's pathways and the version's native
      # calendars, by their exact natural IDs.
      assert has_element?(view, "#closure-pathway option[value='#{@punctuated_pathway_id}']")
      assert has_element?(view, "#closure-calendar option[value='CAL_DAILY']")

      html =
        view
        |> form("#closure-form", %{
          "closure" => %{
            "pathway_id" => @punctuated_pathway_id,
            "service_id" => "CAL_DAILY",
            "start_time" => "10:00",
            "end_time" => "11:30",
            "note" => "Morning inspection."
          }
        })
        |> render_submit()

      assert html =~ "Closure saved."
      assert has_element?(view, "#closure-editor-title", "Edit closure")
      assert has_element?(view, "#closure-start[value='10:00']")
      assert has_element?(view, "#closure-end[value='11:30']")
      assert render(view) =~ "Morning inspection."
      assert row_ids(view) |> length() == 3

      created =
        closure_on!(organization, version, station.stop_id, @punctuated_pathway_id, 36_000)

      assert created.evolution.end_time == 41_400
      assert created.evolution.note == "Morning inspection."

      assert [log] =
               Gtfs.list_change_logs_for_entity(
                 organization.id,
                 version.id,
                 "pathway_evolution",
                 created.evolution.id
               )

      assert log.action == "created"
      assert log.actor_id == user.id
      assert log.organization_id == organization.id
      assert log.gtfs_version_id == version.id
      assert log.station_stop_id == station.stop_id
      assert log.changed_fields["after"]["start_time"] == 36_000
      assert log.changed_fields["after"]["pathway_id"] == @punctuated_pathway_id

      # A second mount rebuilds the same row from stored state.
      {:ok, reloaded, _html} = live(conn, evolutions_path(version, station.stop_id))

      assert reloaded |> row_ids() |> length() == 3
      assert has_element?(reloaded, "#closure-#{created.evolution.id}", "10:00–11:30")
    end

    test "an invalid window keeps the entered strings and marks the first invalid field",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      assert has_element?(view, "#closure-editor[data-closure-id='#{daytime.id}']")
      assert has_element?(view, "#closure-start[value='09:00']")

      html =
        view
        |> form("#closure-form", %{
          "closure" => %{
            "pathway_id" => @punctuated_pathway_id,
            "service_id" => "CAL_DAILY",
            "start_time" => "23:00",
            "end_time" => "02:00",
            "note" => ""
          }
        })
        |> render_submit()

      assert html =~ "Closure not saved"
      assert has_element?(view, "#closure-start[value='23:00']")
      assert has_element?(view, "#closure-end[value='02:00']")
      assert has_element?(view, "#closure-end[aria-invalid='true']")
      assert has_element?(view, "#closure-errors-list", "must be later than the start time")

      assert_push_event(view, "focus_form_error", %{
        form_id: "closure-form",
        fallback_id: "closure-errors"
      })

      # The refused save wrote nothing.
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 54_000
    end

    test "editing persists the new window with one updated audit and a no-op save writes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      submitted_at = Repo.get!(PathwayEvolution, daytime.id).updated_at

      html =
        view
        |> form("#closure-form", %{
          "closure" => %{
            "pathway_id" => @punctuated_pathway_id,
            "service_id" => "CAL_DAILY",
            "start_time" => "09:00",
            "end_time" => "16:00",
            "note" => "Extended."
          }
        })
        |> render_submit()

      assert html =~ "Closure saved."
      assert has_element?(view, "#closure-end[value='16:00']")
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 57_600

      assert [update_log] =
               Gtfs.list_change_logs_for_entity(
                 organization.id,
                 version.id,
                 "pathway_evolution",
                 daytime.id
               )

      assert update_log.action == "updated"
      assert update_log.station_stop_id == station.stop_id
      assert update_log.changed_fields["before"]["end_time"] == 54_000
      assert update_log.changed_fields["after"]["end_time"] == 57_600

      # The same values again are a no-op: no row write and no new audit.
      html =
        view
        |> form("#closure-form", %{
          "closure" => %{
            "pathway_id" => @punctuated_pathway_id,
            "service_id" => "CAL_DAILY",
            "start_time" => "09:00",
            "end_time" => "16:00",
            "note" => "Extended."
          }
        })
        |> render_submit()

      assert html =~ "No changes to save."

      assert length(
               Gtfs.list_change_logs_for_entity(
                 organization.id,
                 version.id,
                 "pathway_evolution",
                 daytime.id
               )
             ) == 1

      assert Repo.get!(PathwayEvolution, daytime.id).updated_at == submitted_at
    end

    test "a duplicate tuple opens the existing closure of this station and writes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#new-closure") |> render_click()

      html =
        view
        |> form("#closure-form", %{
          "closure" => %{
            "pathway_id" => @punctuated_pathway_id,
            "service_id" => "CAL_DAILY",
            "start_time" => "09:00",
            "end_time" => "15:00",
            "note" => ""
          }
        })
        |> render_submit()

      assert html =~ "This closure already exists."
      assert has_element?(view, "#closure-duplicate", "Another closure has the same pathway")
      assert has_element?(view, "#closure-open-existing", "Open existing closure")
      assert_push_event(view, "focus_scoped_target", %{id: "closure-errors"})

      # Nothing was written and no row was added.
      assert row_ids(view) |> length() == 2

      assert Gtfs.list_change_logs_for_entity(
               organization.id,
               version.id,
               "pathway_evolution",
               daytime.id
             ) == []

      view |> element("#closure-open-existing") |> render_click()

      # The link opens exactly the scoped tuple that already exists here.
      assert has_element?(view, "#closure-editor[data-closure-id='#{daytime.id}']")
      assert has_element?(view, "#closure-editor-title", "Edit closure")
      assert has_element?(view, "#closure-start[value='09:00']")
      assert has_element?(view, "#closure-end[value='15:00']")
      refute has_element?(view, "#closure-duplicate")
    end

    test "a stale save keeps the entries and Reload closure adopts the persisted row",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      # Another session changes the row after this editor loaded it.
      edit_from_another_session!(organization, version, user, station.stop_id, daytime.id, %{
        end_time: "16:00",
        note: "Changed elsewhere."
      })

      html =
        view
        |> form("#closure-form", %{
          "closure" => %{
            "pathway_id" => @punctuated_pathway_id,
            "service_id" => "CAL_DAILY",
            "start_time" => "09:00",
            "end_time" => "17:00",
            "note" => ""
          }
        })
        |> render_submit()

      assert html =~ "Closure changed after you opened it"
      assert has_element?(view, "#closure-end[value='17:00']")
      assert has_element?(view, "#save-closure[disabled]")
      assert_push_event(view, "focus_scoped_target", %{id: "closure-stale"})

      # The stale submission wrote nothing: the other session's value stands.
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 57_600

      view |> element("#closure-reload") |> render_click()

      refute has_element?(view, "#closure-stale")
      assert has_element?(view, "#closure-end[value='16:00']")
      assert render(view) =~ "Closure reloaded."
      refute has_element?(view, "#save-closure[disabled]")
    end

    test "a revoked role keeps the entered values and shows the forbidden outcome",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()
      revoke_editor_role!(user, organization)

      html =
        view
        |> form("#closure-form", %{
          "closure" => %{
            "pathway_id" => @punctuated_pathway_id,
            "service_id" => "CAL_DAILY",
            "start_time" => "09:00",
            "end_time" => "17:00",
            "note" => "Still mine."
          }
        })
        |> render_submit()

      assert html =~ "You no longer have permission to edit closures."

      # The mounted page survives and the entered values are kept.
      assert has_element?(view, "#closure-end[value='17:00']")
      assert render(view) =~ "Still mine."
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 54_000
    end

    test "overlap and no-active-dates notices are truthful after a save",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station} = station_with_closures(organization, version)

      # A calendar whose only weekly days never fall inside its range: it has no
      # active service dates at all.
      calendar_fixture(organization.id, version.id, %{
        service_id: "CAL_DARK",
        start_date: ~D[2026-01-03],
        end_date: ~D[2026-01-04]
      })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      # A first closure on the walkway has nothing to warn about.
      save_new_closure(view, %{
        "pathway_id" => "PW-WALK",
        "service_id" => "CAL_DAILY",
        "start_time" => "10:00",
        "end_time" => "12:00"
      })

      assert row_ids(view) |> length() == 3
      refute has_element?(view, "#closure-notice-overlap")

      # A second window on the same pathway and service names the window it
      # overlaps.
      save_new_closure(view, %{
        "pathway_id" => "PW-WALK",
        "service_id" => "CAL_DAILY",
        "start_time" => "11:00",
        "end_time" => "13:00"
      })

      assert has_element?(view, "#closure-notice-overlap", "also closes 10:00–12:00")
      assert has_element?(view, "#closure-notice-overlap", "Every day service")

      # A calendar with no active dates saves and says the closure does not
      # apply yet.
      save_new_closure(view, %{
        "pathway_id" => "PW-WALK",
        "service_id" => "CAL_DARK",
        "start_time" => "10:00",
        "end_time" => "12:00"
      })

      assert has_element?(view, "#closure-notice-no-active-dates", "does not run on any date")
      refute has_element?(view, "#closure-notice-overlap")
      assert row_ids(view) |> length() == 5
    end

    test "a saved closure links to its exact preview instant; an unsaved or dirty one does not",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, walkway: walkway} = station_with_closures(organization, version)

      # One agency zone pinned to UTC and a dates-only calendar with exactly two
      # active dates, one either side of today, so the expected link is exact.
      agency_fixture(organization.id, version.id, %{agency_timezone: "UTC"})

      today = Date.utc_today()
      past = Date.add(today, -30)
      future = Date.add(today, 30)

      for date <- [past, future] do
        calendar_date_fixture(organization.id, version.id, %{
          service_id: "CAL_SPAN",
          date: date,
          exception_type: 1
        })
      end

      closure =
        pathway_evolution_fixture(organization.id, version.id, %{
          pathway_id: walkway.pathway_id,
          service_id: "CAL_SPAN",
          start_time: 32_400,
          end_time: 54_000
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      refute has_element?(view, "#preview-closure-impact")
      refute has_element?(view, "#closure-preview-unavailable")

      # An unsaved closure cannot claim an instant.
      view |> element("#new-closure") |> render_click()

      assert has_element?(
               view,
               "#closure-preview-unavailable",
               "Save the closure to preview its access impact."
             )

      refute has_element?(view, "#preview-closure-impact")

      # A persisted unchanged closure links to the earliest active date on or
      # after the agency's today, at its exact service time.
      view |> element("#closure-open-#{closure.id}") |> render_click()

      expected =
        "/gtfs/#{version.id}/stops/#{station.stop_id}/evolutions/access" <>
          "?date=#{Date.to_iso8601(future)}&time=09%3A00%3A00"

      assert has_element?(view, "#preview-closure-impact[href='#{expected}']")
      refute has_element?(view, "#closure-preview-unavailable")

      # Editing a field withholds the link until the entry is saved or
      # discarded, so a preview never describes unsaved input.
      view
      |> form("#closure-form", %{
        "closure" => %{
          "pathway_id" => walkway.pathway_id,
          "service_id" => "CAL_SPAN",
          "start_time" => "09:00",
          "end_time" => "16:00",
          "note" => ""
        }
      })
      |> render_change()

      assert has_element?(
               view,
               "#closure-preview-unavailable",
               "Save or discard your edits"
             )

      refute has_element?(view, "#preview-closure-impact")
    end

    test "a calendar with no active dates says why a preview cannot be chosen",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, walkway: walkway} = station_with_closures(organization, version)
      agency_fixture(organization.id, version.id, %{agency_timezone: "UTC"})

      calendar_fixture(organization.id, version.id, %{
        service_id: "CAL_DARK",
        start_date: ~D[2026-01-03],
        end_date: ~D[2026-01-04]
      })

      closure =
        pathway_evolution_fixture(organization.id, version.id, %{
          pathway_id: walkway.pathway_id,
          service_id: "CAL_DARK",
          start_time: 32_400,
          end_time: 54_000
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{closure.id}") |> render_click()

      assert has_element?(
               view,
               "#closure-preview-unavailable",
               "has no active service dates"
             )

      refute has_element?(view, "#preview-closure-impact")
    end

    test "a missing agency zone withholds the preview without blocking authoring",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, walkway: walkway} = station_with_closures(organization, version)

      closure =
        pathway_evolution_fixture(organization.id, version.id, %{
          pathway_id: walkway.pathway_id,
          service_id: "CAL_DAILY",
          start_time: 32_400,
          end_time: 54_000
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{closure.id}") |> render_click()

      assert has_element?(
               view,
               "#closure-preview-unavailable",
               "agency time zone is unavailable"
             )

      assert has_element?(view, "#closure-preview-unavailable", "authoring still works")
      refute has_element?(view, "#preview-closure-impact")

      # The form itself is untouched and still saves.
      save_new_closure(view, %{
        "pathway_id" => walkway.pathway_id,
        "service_id" => "CAL_DAILY",
        "start_time" => "14:00",
        "end_time" => "15:00"
      })

      assert render(view) =~ "Closure saved."
    end
  end

  # Step 19 / EV-7: unsaved input is never dropped silently. An in-app link, a
  # row switch and the start of a new closure all wait for the same explicit
  # choice, and only the dialog's own confirmation runs the interrupted action.
  describe "unsaved closure edits" do
    setup :editor_setup

    test "a dirty form asks before switching rows and honors keep or discard",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime, overnight: overnight} =
        station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      # The editor mounts the dirty guard hook with the saved tuple the client
      # compares the form against, and nothing is unsaved yet.
      assert has_element?(
               view,
               ~s(#closure-editor[phx-hook="CalendarEditor"][data-dirty="false"])
             )

      assert has_element?(view, "#closure-editor[data-dirty-baseline]")
      refute has_element?(view, "#closure-dirty-chip")
      assert has_element?(view, "#discard-closure", "Close")

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      # One typed field is unsaved input: the chip says so in words and the
      # footer's second action becomes the discard action.
      change_editor(view, %{
        "pathway_id" => @punctuated_pathway_id,
        "service_id" => "CAL_DAILY",
        "start_time" => "09:00",
        "end_time" => "16:00",
        "note" => ""
      })

      assert has_element?(view, ~s(#closure-editor[data-dirty="true"]))
      assert has_element?(view, "#closure-dirty-chip", "Unsaved changes")
      assert has_element?(view, "#discard-closure", "Discard edits")

      # Selecting another row interrupts instead of switching.
      asked = view |> element("#closure-open-#{overnight.id}") |> render_click()

      assert dialog_open?(asked, "closure-dirty-dialog")
      assert has_element?(view, "#closure-dirty-dialog-title", "Discard closure edits?")
      assert has_element?(view, "#closure-dirty-dialog-cancel", "Keep editing")
      assert has_element?(view, "#closure-dirty-dialog-confirm", "Discard edits")

      assert has_element?(
               view,
               "#closure-dirty-body",
               "Your changes to Elevator · Mezzanine hall ↔ Platform 1 are not saved. " <>
                 "Discarding restores the saved closure."
             )

      # The row that was asked for is not open, and nothing was written.
      assert has_element?(view, "#closure-end[value='16:00']")
      assert has_element?(view, "#closure-editor-title", "Edit closure")
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 54_000

      # Keeping the edits leaves every entered string in place.
      kept = view |> element("#closure-dirty-dialog-cancel") |> render_click()

      refute dialog_open?(kept, "closure-dirty-dialog")
      assert has_element?(view, "#closure-end[value='16:00']")
      assert has_element?(view, "#evolutions-status", "Your unsaved changes are still here.")
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 54_000

      # Asking again and discarding opens the other row on its persisted values.
      assert view
             |> element("#closure-open-#{overnight.id}")
             |> render_click()
             |> dialog_open?("closure-dirty-dialog")

      discarded = view |> element("#closure-dirty-dialog-confirm") |> render_click()

      refute dialog_open?(discarded, "closure-dirty-dialog")
      assert has_element?(view, "#closure-end[value='26:00']")
      assert has_element?(view, "#evolutions-status", "Closure edits discarded.")
      refute has_element?(view, "#closure-dirty-chip")
      assert has_element?(view, "#discard-closure", "Close")
    end

    test "a link departure waits for the same choice and a foreign path is refused",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      change_editor(view, %{
        "pathway_id" => @punctuated_pathway_id,
        "service_id" => "CAL_DAILY",
        "start_time" => "09:00",
        "end_time" => "16:00",
        "note" => ""
      })

      path = "/gtfs/#{version.id}/stops"

      # The client hook pushes the address it was about to open; the dialog holds
      # it until the reader chooses.
      asked = render_hook(view, "calendar_depart", %{"path" => path})

      assert dialog_open?(asked, "closure-dirty-dialog")
      assert has_element?(view, "#closure-end[value='16:00']")

      refute dialog_open?(render_hook(view, "keep_editing", %{}), "closure-dirty-dialog")
      assert has_element?(view, "#closure-end[value='16:00']")

      # A path outside this application is refused outright: no dialog is kept,
      # and no pending navigation can be confirmed later.
      for foreign <- [
            "https://evil.example/gtfs/#{version.id}/stops",
            "//evil.example/gtfs/#{version.id}/stops",
            "javascript:alert(1)",
            "gtfs/#{version.id}/stops"
          ] do
        refute dialog_open?(
                 render_hook(view, "calendar_depart", %{"path" => foreign}),
                 "closure-dirty-dialog"
               )
      end

      assert has_element?(view, "#closure-end[value='16:00']")

      # Discarding runs the interrupted navigation itself.
      render_hook(view, "calendar_depart", %{"path" => path})

      assert {:error, {:live_redirect, %{to: ^path}}} = render_hook(view, "discard_edits", %{})
    end

    test "the footer restores a dirty row in place and closes a clean inspector",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      change_editor(view, %{
        "pathway_id" => @punctuated_pathway_id,
        "service_id" => "CAL_DAILY",
        "start_time" => "09:00",
        "end_time" => "16:00",
        "note" => ""
      })

      assert has_element?(view, "#discard-closure", "Discard edits")

      discarded = view |> element("#discard-closure") |> render_click()

      assert has_element?(view, "#closure-end[value='15:00']")

      assert has_element?(
               view,
               "#evolutions-status",
               "Closure edits discarded. The saved closure is shown."
             )

      refute has_element?(view, "#closure-dirty-chip")
      assert has_element?(view, "#discard-closure", "Close")
      assert has_element?(view, ~s(#closure-editor[data-closure-id="#{daytime.id}"]))
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 54_000
      refute dialog_open?(discarded, "closure-dirty-dialog")

      # A clean inspector closes to the idle card and says so.
      closed = view |> element("#discard-closure") |> render_click()

      assert has_element?(view, "#closure-idle", "No closure selected")
      refute has_element?(view, "#closure-form")
      assert has_element?(view, "#evolutions-status", "Closure closed.")
      assert_push_event(view, "focus_scoped_target", %{id: "closure-idle-title"})
      refute dialog_open?(closed, "closure-dirty-dialog")
    end

    test "a dirty form asks before starting a new closure and discarding clears the draft",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime, walkway: walkway} =
        station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      change_editor(view, %{
        "pathway_id" => @punctuated_pathway_id,
        "service_id" => "CAL_DAILY",
        "start_time" => "09:00",
        "end_time" => "16:00",
        "note" => ""
      })

      # The header's Create closure action is guarded the same way.
      asked = view |> element("#new-closure") |> render_click()

      assert dialog_open?(asked, "closure-dirty-dialog")
      assert has_element?(view, "#closure-end[value='16:00']")
      assert has_element?(view, "#closure-editor-title", "Edit closure")

      refute dialog_open?(
               view |> element("#closure-dirty-dialog-cancel") |> render_click(),
               "closure-dirty-dialog"
             )

      assert has_element?(view, "#closure-end[value='16:00']")

      # Discarding abandons the draft and opens the new-closure form on nothing.
      view |> element("#new-closure") |> render_click()
      discarded = view |> element("#closure-dirty-dialog-confirm") |> render_click()

      refute dialog_open?(discarded, "closure-dirty-dialog")
      assert has_element?(view, "#closure-editor-title", "New closure")
      assert has_element?(view, "#closure-start[value='']")
      assert has_element?(view, "#closure-end[value='']")
      refute has_element?(view, "#closure-dirty-chip")
      assert_push_event(view, "focus_scoped_target", %{id: "closure-pathway"})

      # Opening a new closure from the pathway list preselects it; that alone is
      # not unsaved input.
      view |> element("#pathway-option-#{walkway.id}") |> render_click()

      refute has_element?(view, "#closure-dirty-chip")
      assert has_element?(view, "#discard-closure", "Close")

      # Typing into the new form makes it dirty, and discarding abandons it
      # instead of leaving a half-filled draft behind.
      change_editor(view, %{
        "pathway_id" => walkway.pathway_id,
        "service_id" => "CAL_DAILY",
        "start_time" => "10:00",
        "end_time" => "",
        "note" => ""
      })

      assert has_element?(view, "#discard-closure", "Discard edits")

      view |> element("#discard-closure") |> render_click()

      assert has_element?(view, "#closure-idle", "No closure selected")
      assert has_element?(view, "#evolutions-status", "New closure discarded.")
      refute has_element?(view, "#closure-form")
    end
  end

  describe "deleting a closure" do
    setup :editor_setup

    test "a confirmed delete removes one audited row and keeps its calendar and pathway",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime, overnight: overnight} =
        station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      # Delete is offered only for a persisted row, and the confirmation names
      # the saved pathway, calendar and window before anything is removed.
      view |> element("#closure-open-#{daytime.id}") |> render_click()
      assert has_element?(view, "#delete-closure", "Delete closure")

      asked = view |> element("#delete-closure") |> render_click()

      assert dialog_open?(asked, "closure-delete-dialog")
      assert has_element?(view, "#closure-delete-dialog-title", "Delete this closure?")

      assert has_element?(
               view,
               "#closure-delete-pathway",
               "Elevator · Mezzanine hall ↔ Platform 1"
             )

      assert has_element?(view, "#closure-delete-pathway", @punctuated_pathway_id)
      assert has_element?(view, "#closure-delete-calendar", "CAL_DAILY")
      assert has_element?(view, "#closure-delete-window", "09:00–15:00")
      assert has_element?(view, "#closure-delete-calendar-note", "CAL_DAILY")
      assert render(view) =~ "stays unchanged."
      assert has_element?(view, "#closure-delete-dialog-cancel", "Keep closure")
      assert has_element?(view, "#closure-delete-dialog-confirm", "Delete closure")

      assert has_element?(
               view,
               "#closure-delete-dialog[data-return-focus-id='delete-closure']"
             )

      # The confirmation's own render is the busy state: both actions are
      # disabled and the confirm action says what is happening.
      pending = view |> element("#closure-delete-dialog-confirm") |> render_click()

      assert dialog_open?(pending, "closure-delete-dialog")
      assert has_element?(view, "#closure-delete-dialog[data-pending='true']")
      assert has_element?(view, "#closure-delete-dialog-confirm[disabled]", "Deleting…")
      assert has_element?(view, "#closure-delete-dialog-cancel[disabled]")

      # The delete itself runs after that busy render.
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#evolutions-status", "Closure deleted. CAL_DAILY is unchanged.")
      refute dialog_open?(render(view), "closure-delete-dialog")
      assert has_element?(view, "#closure-idle", "No closure selected")
      assert row_ids(view) == [overnight.id]
      assert_push_event(view, "focus_scoped_target", %{id: "closures-list"})

      # The row is gone; its pathway and calendar are not part of a delete.
      assert Repo.get(PathwayEvolution, daytime.id) == nil

      assert {:ok, station_data} =
               Gtfs.station_closures(organization.id, version.id, station.stop_id)

      assert Enum.map(station_data.closures, & &1.evolution.id) == [overnight.id]
      assert Enum.any?(station_data.pathways, &(&1.pathway_id == @punctuated_pathway_id))

      assert {:ok, calendars} = Gtfs.closure_calendars(organization.id, version.id)
      assert Enum.any?(calendars, &(&1.service_id == "CAL_DAILY"))

      # One audited delete with the scope this page owns.
      assert [log] =
               Gtfs.list_change_logs_for_entity(
                 organization.id,
                 version.id,
                 "pathway_evolution",
                 daytime.id
               )

      assert log.action == "deleted"
      assert log.actor_id == user.id
      assert log.organization_id == organization.id
      assert log.gtfs_version_id == version.id
      assert log.station_stop_id == station.stop_id
      assert log.changed_fields["before"]["end_time"] == 54_000

      # A second mount rebuilds the list without the deleted row.
      {:ok, reloaded, _html} = live(conn, evolutions_path(version, station.stop_id))
      assert reloaded |> row_ids() == [overnight.id]
    end

    test "cancelling the delete keeps the row and a dirty form's values",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime, overnight: overnight} =
        station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      # A delete has its own explicit confirmation, so the dirty guard does not
      # intercept it: the dialog names the saved row, not the unsaved entry.
      change_editor(view, %{
        "pathway_id" => @punctuated_pathway_id,
        "service_id" => "CAL_DAILY",
        "start_time" => "09:00",
        "end_time" => "16:00",
        "note" => ""
      })

      assert has_element?(view, "#closure-dirty-chip", "Unsaved changes")

      asked = view |> element("#delete-closure") |> render_click()

      assert dialog_open?(asked, "closure-delete-dialog")
      assert has_element?(view, "#closure-end[value='16:00']")

      window_text =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#closure-delete-window")
        |> LazyHTML.text()
        |> String.trim()

      # The dialog names the saved window, not the unsaved 16:00 in the form.
      assert window_text == "09:00–15:00"

      cancelled = view |> element("#closure-delete-dialog-cancel") |> render_click()

      refute dialog_open?(cancelled, "closure-delete-dialog")
      assert has_element?(view, "#closure-end[value='16:00']")
      assert has_element?(view, "#closure-dirty-chip", "Unsaved changes")
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 54_000

      assert Gtfs.list_change_logs_for_entity(
               organization.id,
               version.id,
               "pathway_evolution",
               daytime.id
             ) == []

      # An overnight window is named with its own note, in text.
      view |> element("#discard-closure") |> render_click()
      view |> element("#closure-open-#{overnight.id}") |> render_click()
      view |> element("#delete-closure") |> render_click()

      assert has_element?(view, "#closure-delete-window", "22:00–26:00")
      assert has_element?(view, "#closure-delete-window", "Ends the next day")
    end

    test "a stale fingerprint refuses the delete and preserves the row and entries",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      change_editor(view, %{
        "pathway_id" => @punctuated_pathway_id,
        "service_id" => "CAL_DAILY",
        "start_time" => "09:00",
        "end_time" => "16:00",
        "note" => ""
      })

      # Another session changes the same row after this editor loaded it, so
      # the fingerprint the editor holds is no longer the row's.
      edit_from_another_session!(organization, version, user, station.stop_id, daytime.id, %{
        end_time: "17:00",
        note: "Changed elsewhere."
      })

      view |> element("#delete-closure") |> render_click()
      view |> element("#closure-delete-dialog-confirm") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#closure-stale", "Closure changed after you opened it")
      assert has_element?(view, "#closure-end[value='16:00']")
      assert has_element?(view, "#evolutions-status", "Delete refused")
      assert has_element?(view, "#closure-reload", "Reload closure")
      refute dialog_open?(render(view), "closure-delete-dialog")

      # Nothing was deleted: the other session's row stands, and the only audit
      # this row has is that session's update.
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 61_200

      assert [log] =
               Gtfs.list_change_logs_for_entity(
                 organization.id,
                 version.id,
                 "pathway_evolution",
                 daytime.id
               )

      assert log.action == "updated"
    end

    test "a revoked role refuses the delete and keeps the entered values",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime} = station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()

      change_editor(view, %{
        "pathway_id" => @punctuated_pathway_id,
        "service_id" => "CAL_DAILY",
        "start_time" => "09:00",
        "end_time" => "16:00",
        "note" => "Still mine."
      })

      revoke_editor_role!(user, organization)

      view |> element("#delete-closure") |> render_click()
      view |> element("#closure-delete-dialog-confirm") |> render_click()
      _ = :sys.get_state(view.pid)

      assert render(view) =~ "You no longer have permission to edit closures."
      assert has_element?(view, "#evolutions-status", "Delete refused")
      assert has_element?(view, "#closure-end[value='16:00']")
      assert render(view) =~ "Still mine."
      assert Repo.get!(PathwayEvolution, daytime.id).end_time == 54_000

      assert Gtfs.list_change_logs_for_entity(
               organization.id,
               version.id,
               "pathway_evolution",
               daytime.id
             ) == []
    end

    test "a repeated confirmation cannot delete twice",
         %{conn: conn, user: user, organization: organization, version: version} do
      %{station: station, daytime: daytime, overnight: overnight} =
        station_with_closures(organization, version)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, evolutions_path(version, station.stop_id))

      view |> element("#closure-open-#{daytime.id}") |> render_click()
      view |> element("#delete-closure") |> render_click()

      # The second confirmation arrives while the first is pending: the busy
      # state refuses it, so only one delete can ever run.
      view |> element("#closure-delete-dialog-confirm") |> render_click()
      view |> element("#closure-delete-dialog-confirm") |> render_click()
      _ = :sys.get_state(view.pid)

      assert Repo.get(PathwayEvolution, daytime.id) == nil
      assert Repo.aggregate(PathwayEvolution, :count) == 1
      assert row_ids(view) == [overnight.id]

      assert [log] =
               Gtfs.list_change_logs_for_entity(
                 organization.id,
                 version.id,
                 "pathway_evolution",
                 daytime.id
               )

      assert log.action == "deleted"
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
