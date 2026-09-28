defmodule GtfsPlannerWeb.Gtfs.AgencyCreateLiveTest do
  @moduledoc """
  The create agency drawer on the Agencies page: first and later agencies, the
  unresolved-zone redirect, validation and the discard question (AC-12, AC-13;
  CL-15, EV-20).

  Every case drives the page through the real router and the real context
  functions the LiveView calls, so a case that passes here went through
  `FeedSettings.change_agency/2` and `create_agency/2` with the LiveView's own
  audit context. What a save stores is read back through the same scoped context
  read the page uses: the drawer exists to write rows, so "no write" and "which
  zone" are only worth claiming from the stored state.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedSettings

  @open_drawer "#agency-drawer-overlay[data-open='true']"
  @closed_drawer "#agency-drawer-overlay[data-open='false']"
  @open_timezone_drawer "#agency-timezone-drawer-overlay[data-open='true']"
  @website_error "must be a full web address starting with https:// or http://"
  @timezone_help "Search by city or enter an IANA timezone, such as America/New_York."
  @zone_callout "Schedule timezone for this version. To update every agency together, use Change timezone on the agency list."

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"

  # A per-call address: the shared `user_fixture/1` counter restarts with each
  # BEAM run, so a row an unboxed test left in the shared database can collide
  # with it inside the fixture. The prefix keeps this file out of that range.
  defp editor_email do
    "agencies-create-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
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

  # Rows are built through the context functions the application writes with, so
  # nothing a changeset refuses can hide inside a fixture.
  defp create_agency(organization, version, agency_id, name, timezone) do
    {:ok, agency} =
      Gtfs.create_agency(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        agency_id: agency_id,
        agency_name: name,
        agency_url: "https://#{String.downcase(agency_id)}.example",
        agency_timezone: timezone
      })

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

  # The rows as stored, read through the same scoped read the step-16 drawer
  # asserts with: `Gtfs.list_agencies/2` returns the `%Agency{}` rows themselves,
  # in that read's own order (name ascending), so an expectation below reads as
  # the page's own name sort.
  defp stored_agencies(organization, version) do
    organization.id
    |> Gtfs.list_agencies(version.id)
    |> Enum.map(&{&1.agency_id, &1.agency_name, &1.agency_timezone})
  end

  # Two agencies that disagree: the version has no single zone (R2).
  defp conflicting_version(organization, version) do
    create_agency(organization, version, "NCT", "North Coast Transit", "America/New_York")
    create_agency(organization, version, "LFT", "Lakefront Transit", "America/Chicago")
  end

  # The route counts the page's own read model reports: `FeedSettings.list_agencies/2`
  # wraps each row with its count, so a backfilled route counts toward the agency
  # it was assigned to (R6). `Gtfs.list_agencies/2` above is the rows-only read.
  defp route_counts(organization, version) do
    organization.id
    |> FeedSettings.list_agencies(version.id)
    |> Map.new(&{&1.agency.agency_id, &1.route_count})
  end

  defp open_create(view, opener), do: view |> element(opener) |> render_click()

  defp create_form(view, params), do: form(view, "#agency-form", %{"agency" => params})

  defp submit_create(view, params), do: view |> create_form(params) |> render_submit()

  defp change_create(view, params), do: view |> create_form(params) |> render_change()

  defp valid_params(name, host) do
    %{
      "agency_name" => name,
      "agency_url" => "https://#{host}",
      "agency_timezone" => "America/New_York"
    }
  end

  defp text_of(doc, selector) do
    doc
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    # The template wraps long copy across source lines, so the rendered text
    # carries that indentation: compare readings, not source formatting.
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Every visible field label in the form, in the order the drawer renders them.
  defp field_labels(doc) do
    doc
    |> LazyHTML.query("#agency-form label .label")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp zone_options(doc) do
    doc
    |> LazyHTML.query("#agency-form_agency_timezone-zones option")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
  end

  describe "creating the first agency" do
    setup :editor_setup

    test "the empty state action opens the form with the timezone field", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      create_route(organization, version, %{route_id: "NO_AGENCY", route_short_name: "1"})

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      # A version with no agency offers creation from its empty state, and the
      # drawer is closed until it is asked for.
      assert has_element?(view, "#agencies-empty", "Give your service a name")
      assert has_element?(view, "#agencies-create-first", "Create first agency")
      refute has_element?(view, @open_drawer)
      refute has_element?(view, "#agency-form")

      open_create(view, "#agencies-create-first")

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-drawer-title", "Create agency")
      assert has_element?(view, "#agency-drawer-scope", "#{version.name} · #{organization.name}")

      assert text_of(LazyHTML.from_fragment(render(view)), "#agency-drawer-scope") ==
               "#{version.name} · #{organization.name}"

      # The first agency is the one that decides the version's zone, so it is the
      # one drawer with a timezone field — the shared `timezone_input/1`.
      assert has_element?(view, "#agency-form_agency_name")
      assert has_element?(view, "#agency-form_agency_url[type='url']")

      assert has_element?(
               view,
               "#agency-form_agency_timezone[list='agency-form_agency_timezone-zones']"
             )

      assert has_element?(view, "#agency-form_agency_timezone[autocomplete='off']")
      assert has_element?(view, "#agency-form_agency_timezone-help", @timezone_help)
      refute has_element?(view, "#agency-zone-callout")

      doc = LazyHTML.from_fragment(render(view))

      # The suggestion list is exactly the list the server validates against
      # (INV-4), and no name outside it is offered.
      assert zone_options(doc) == DisplayClock.zone_names()
      assert "America/New_York" in zone_options(doc)
      assert "Not/a_zone" not in zone_options(doc)

      # Agency identity, then rider contact, in the prototype's order and with
      # its optional markers.
      assert field_labels(doc) == [
               "Agency name",
               "Website",
               "Schedule timezone",
               "Language (optional)",
               "Phone (optional)",
               "Email (optional)",
               "Fare website (optional)"
             ]

      assert has_element?(
               view,
               "#agency-form_agency_phone-help",
               "Keep the local formatting riders recognize."
             )

      # The drawer cannot send the row's identifiers: the changeset owns them.
      refute has_element?(view, "#agency-form input[name='agency[agency_id]']")
      refute has_element?(view, "#agency-form input[name='agency[organization_id]']")
      refute has_element?(view, "#agency-form input[name='agency[gtfs_version_id]']")
    end

    test "saving the first agency stores its zone, assigns the unassigned routes and flashes", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      create_route(organization, version, %{route_id: "NO_AGENCY", route_short_name: "1"})

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_create(view, "#agencies-create-first")

      submit_create(view, %{
        "agency_name" => "North Coast Transit",
        "agency_url" => "https://northcoast.example",
        "agency_timezone" => "America/Chicago"
      })

      assert has_element?(view, @closed_drawer)
      assert has_element?(view, "#flash-info", "North Coast Transit created.")

      # The stored row is what the drawer asked for: the slug ID (R1) and the
      # zone the editor validated (R2).
      assert stored_agencies(organization, version) == [
               {"north_coast_transit", "North Coast Transit", "America/Chicago"}
             ]

      # The create transaction assigned the version's unassigned route in the
      # same write (R6), which the row's count now reports.
      assert route_counts(organization, version) == %{"north_coast_transit" => 1}
      assert DisplayClock.resolve_zone(organization.id, version.id).timezone == "America/Chicago"

      # The page behind the drawer reloaded: the list replaces the empty state.
      refute has_element?(view, "#agencies-empty")
      assert has_element?(view, "#agencies", "North Coast Transit")
      assert has_element?(view, "#agencies-create", "Create agency")
    end
  end

  describe "creating a later agency" do
    setup :editor_setup

    test "the form shows the version zone instead of a field and stores that zone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      create_agency(organization, version, "NYC", "New York Transit", "America/New_York")

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_create(view, "#agencies-create")

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-drawer-title", "Create agency")

      # The version holds one zone, so a later agency takes it rather than
      # choosing one (R2): no field, no suggestion list, and the zone named where
      # the field would be.
      refute has_element?(view, "#agency-form_agency_timezone")
      refute has_element?(view, "#agency-form_agency_timezone-zones")

      doc = LazyHTML.from_fragment(render(view))

      assert text_of(doc, "#agency-zone-callout") =~ "America/New_York"
      assert text_of(doc, "#agency-zone-callout") =~ @zone_callout

      assert field_labels(doc) == [
               "Agency name",
               "Website",
               "Language (optional)",
               "Phone (optional)",
               "Email (optional)",
               "Fare website (optional)"
             ]

      # This form has no timezone field, so the submission carries none and the
      # context takes the version's zone: the stored zone is America/New_York.
      submit_create(view, %{
        "agency_name" => "Harbor Shuttle",
        "agency_url" => "https://harbor.example"
      })

      assert has_element?(view, @closed_drawer)
      assert has_element?(view, "#flash-info", "Harbor Shuttle created.")

      assert stored_agencies(organization, version) == [
               {"harbor_shuttle", "Harbor Shuttle", "America/New_York"},
               {"NYC", "New York Transit", "America/New_York"}
             ]

      assert DisplayClock.resolve_zone(organization.id, version.id).timezone == "America/New_York"
    end

    test "the create form keeps the optional imported fields and stores them", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      create_agency(organization, version, "NYC", "New York Transit", "America/New_York")

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_create(view, "#agencies-create")

      submit_create(view, %{
        "agency_name" => "Harbor Shuttle",
        "agency_url" => "https://harbor.example",
        "agency_lang" => "en",
        "agency_phone" => "+1 (555) 010-0100",
        "agency_email" => "harbor@example.test",
        "agency_fare_url" => "https://harbor.example/fares"
      })

      assert has_element?(view, "#flash-info", "Harbor Shuttle created.")

      stored =
        organization.id
        |> Gtfs.list_agencies(version.id)
        |> Enum.find(&(&1.agency_id == "harbor_shuttle"))

      assert stored.agency_lang == "en"
      assert stored.agency_phone == "+1 (555) 010-0100"
      assert stored.agency_email == "harbor@example.test"
      assert stored.agency_fare_url == "https://harbor.example/fares"
      assert stored.agency_timezone == "America/New_York"
    end
  end

  describe "validation" do
    setup :editor_setup

    test "a change event after the drawer closes leaves the page running", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      render_hook(view, "validate_agency", %{"agency" => %{"agency_name" => "Late"}})

      assert has_element?(view, @closed_drawer)
      assert stored_agencies(organization, version) == []
    end

    test "a scheme-less website marks its field, asks for focus and creates nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_create(view, "#agencies-create-first")

      submit_create(view, %{
        "agency_name" => "North Coast Transit",
        "agency_url" => "www.example.com",
        "agency_timezone" => "America/New_York"
      })

      # The drawer stays open on the draft, names the failed save and marks the
      # field the changeset refused (R9).
      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-form-error", "Nothing was created.")
      assert has_element?(view, "#agency-form_agency_url[aria-invalid='true']")
      assert has_element?(view, "#agency-form_agency_url-error", @website_error)
      assert has_element?(view, "#agency-form_agency_url[value='www.example.com']")
      refute has_element?(view, "#flash-info")

      assert_push_event(view, "focus_form_error", %{
        form_id: "agency-form",
        fallback_id: "agency-form-error"
      })

      assert stored_agencies(organization, version) == []

      # An empty submit marks every required field and still writes nothing.
      submit_create(view, %{"agency_name" => "", "agency_url" => "", "agency_timezone" => ""})

      assert has_element?(view, "#agency-form_agency_name[aria-invalid='true']")
      assert has_element?(view, "#agency-form_agency_url[aria-invalid='true']")
      assert has_element?(view, "#agency-form_agency_timezone[aria-invalid='true']")
      assert_push_event(view, "focus_form_error", %{form_id: "agency-form"})
      assert stored_agencies(organization, version) == []

      # An unknown zone is refused by the same field the timezone drawer uses,
      # and a valid one then creates the agency.
      submit_create(view, %{
        "agency_name" => "North Coast Transit",
        "agency_url" => "https://northcoast.example",
        "agency_timezone" => "Not/a_zone"
      })

      assert has_element?(view, "#agency-form_agency_timezone[aria-invalid='true']")

      assert has_element?(
               view,
               "#agency-form_agency_timezone-error",
               "must be a valid timezone, such as America/New_York"
             )

      assert stored_agencies(organization, version) == []

      submit_create(view, %{
        "agency_name" => "North Coast Transit",
        "agency_url" => "https://northcoast.example",
        "agency_timezone" => "America/Chicago"
      })

      assert has_element?(view, @closed_drawer)
      assert has_element?(view, "#flash-info", "North Coast Transit created.")
    end
  end

  describe "an unresolved version zone" do
    setup :editor_setup

    test "Create agency opens the timezone drawer instead of the create form", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      conflicting_version(organization, version)
      before = stored_agencies(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_create(view, "#agencies-create")

      # The create action could not open a form that would be refused, so the
      # flow that resolves the version's zone opens under its own note (AC-13).
      assert has_element?(view, @open_timezone_drawer)
      assert has_element?(view, "#agency-timezone-drawer-title", "Resolve agency timezones")

      assert has_element?(
               view,
               "#agency-timezone-notice",
               "Choose one timezone before adding an agency."
             )

      refute has_element?(view, @open_drawer)
      refute has_element?(view, "#agency-form")
      assert stored_agencies(organization, version) == before

      # Closing drops the note with the drawer.
      view |> element("#agency-timezone-cancel") |> render_click()
      refute has_element?(view, "#agency-timezone-notice")

      # Resolving the zone is what unblocks creation: the next create action
      # opens the form, with the resolved zone as the callout (AC-12, AC-13).
      open_create(view, "#agencies-create")

      view
      |> form("#agency-timezone-form", %{"timezone" => %{"zone" => "America/Chicago"}})
      |> render_submit()

      view
      |> form("#agency-timezone-review-form", %{
        "timezone" => %{"acknowledged" => "true"}
      })
      |> render_submit()

      assert has_element?(view, "#flash-info", "Timezone updated for 2 agencies.")

      open_create(view, "#agencies-create")

      assert has_element?(view, @open_drawer)
      refute has_element?(view, "#agency-form_agency_timezone")
      assert has_element?(view, "#agency-zone-callout", "America/Chicago")
    end

    test "the server refuses a create whose version zone became unresolved", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      create_agency(organization, version, "NYC", "New York Transit", "America/New_York")

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_create(view, "#agencies-create")

      # A second agency whose zone disagrees appears while the drawer is open, so
      # the version no longer resolves a zone: the save is refused with no write
      # and the timezone flow opens.
      create_agency(organization, version, "LFT", "Lakefront Transit", "America/Chicago")

      # The drawer was opened while the version held one agency, so its form has
      # no timezone field: the submission carries none, exactly as the page sends
      # it, and the refused save still writes nothing.
      params = %{
        "agency_name" => "Harbor Shuttle",
        "agency_url" => "https://harbor.example"
      }

      submit_create(view, params)

      assert has_element?(view, @open_timezone_drawer)
      assert has_element?(view, "#agency-timezone-drawer-title", "Resolve agency timezones")

      assert has_element?(
               view,
               "#agency-timezone-notice",
               "Choose one timezone before adding an agency."
             )

      refute has_element?(view, @open_drawer)
      refute has_element?(view, "#flash-info")

      assert stored_agencies(organization, version) == [
               {"LFT", "Lakefront Transit", "America/Chicago"},
               {"NYC", "New York Transit", "America/New_York"}
             ]
    end
  end

  describe "an unsaved draft" do
    setup :editor_setup

    test "closing a changed form asks before discarding, and Discard creates nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      create_agency(organization, version, "NYC", "New York Transit", "America/New_York")
      before = stored_agencies(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_create(view, "#agencies-create")

      # An untouched form closes without a question.
      view |> element("#agency-drawer-close") |> render_click()
      assert has_element?(view, @closed_drawer)
      refute has_element?(view, "#agency-discard")

      open_create(view, "#agencies-create")
      change_create(view, %{"agency_name" => "Harbor Shuttle"})

      assert has_element?(view, "#agency-unsaved", "Unsaved changes")
      assert has_element?(view, "#agency-unsaved-guard[data-dirty='true']")

      # Cancel asks, and the close button is the same asking handler the
      # `OverlayDialog` hook clicks for Escape and the backdrop.
      view |> element("#agency-cancel") |> render_click()

      assert has_element?(view, "#agency-discard[role='alertdialog']")
      assert has_element?(view, "#agency-discard-title", "Discard unsaved changes?")
      assert has_element?(view, "#agency-discard-body", "Your entries will be lost.")
      assert has_element?(view, "#agency-discard-confirm", "Discard changes")
      assert has_element?(view, "#agency-discard-cancel", "Keep editing")

      assert has_element?(
               view,
               "#agency-drawer-close[data-dialog-dismiss][phx-click='close_agency_drawer']"
             )

      # Keep editing keeps both the drawer and the entries.
      view |> element("#agency-discard-cancel") |> render_click()

      refute has_element?(view, "#agency-discard")
      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-form_agency_name[value='Harbor Shuttle']")

      # Discard closes the drawer without creating anything.
      view |> element("#agency-drawer-close") |> render_click()
      view |> element("#agency-discard-confirm") |> render_click()

      assert has_element?(view, @closed_drawer)
      refute has_element?(view, "#agency-discard")
      assert stored_agencies(organization, version) == before

      # The discarded draft is gone: reopening shows the stored state, so the name
      # field carries no value at all — an empty text input renders no `value`.
      open_create(view, "#agencies-create")

      assert LazyHTML.attribute(
               LazyHTML.query(LazyHTML.from_fragment(render(view)), "#agency-form_agency_name"),
               "value"
             ) == []

      assert has_element?(view, "#agency-unsaved-guard[data-dirty='false']")
      refute has_element?(view, "#agency-unsaved")
    end
  end

  describe "access" do
    setup :editor_setup

    test "a membership deactivated after the drawer opened refuses the create", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_create(view, "#agencies-create-first")
      change_create(view, valid_params("North Coast Transit", "northcoast.example"))

      Accounts.get_user_org_membership(user.id, organization.id)
      |> deactivate_membership_fixture()

      submit_create(view, valid_params("North Coast Transit", "northcoast.example"))

      assert has_element?(view, @closed_drawer)

      assert has_element?(
               view,
               "#flash-error",
               "You no longer have editor access to this organization."
             )

      assert stored_agencies(organization, version) == []
    end
  end
end
