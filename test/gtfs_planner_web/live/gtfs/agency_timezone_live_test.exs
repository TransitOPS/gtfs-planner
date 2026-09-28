defmodule GtfsPlannerWeb.Gtfs.AgencyTimezoneLiveTest do
  @moduledoc """
  The version timezone drawer on the Agencies page: choose, review, apply, the
  stale review and the resolve path (AC-10, AC-17, AC-18; CL-14, EV-18).

  Every case drives the page through the real router and the real context calls
  the LiveView makes, so a case that passes here passed `FeedSettings`' review
  and apply with the LiveView's own audit context. Stored zones are asserted
  after each refusal as well as after the successful apply: the drawer exists to
  change stored data, so "no write" is only worth claiming by reading the rows
  back.
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

  @open_drawer "#agency-timezone-drawer-overlay[data-open='true']"
  @closed_drawer "#agency-timezone-drawer-overlay[data-open='false']"
  @ack_error "Confirm that the selected timezone is used by these schedules before applying it."

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"

  # A per-call address: the shared `user_fixture/1` counter restarts with each
  # BEAM run, so a row an unboxed test left in the shared database can collide
  # with it inside the fixture. The prefix keeps this file out of that range.
  defp editor_email do
    "agencies-timezone-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
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

  defp create_routes(organization, version, agency_id, count) do
    for index <- 1..count//1 do
      {:ok, _route} =
        Gtfs.create_route(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          agency_id: agency_id,
          route_id: "#{agency_id}_#{index}",
          route_short_name: "#{index}",
          route_type: 3
        })
    end
  end

  # One timezone for the version: two agencies that agree on America/New_York.
  defp agreed_version(organization, version) do
    create_agency(organization, version, "NCT", "North Coast Transit", "America/New_York")
    create_agency(organization, version, "HBR", "Harbor Shuttle", "America/New_York")
    create_routes(organization, version, "NCT", 2)
    create_routes(organization, version, "HBR", 1)
  end

  # A conflicting version whose agencies hold neither the reviewed zone nor each
  # other's, so every row of the review shows a real change (AC-10, R3).
  defp conflicting_version(organization, version) do
    create_agency(organization, version, "NCT", "North Coast Transit", "America/New_York")
    create_agency(organization, version, "LFT", "Lakefront Transit", "America/Denver")
    create_routes(organization, version, "NCT", 2)
    create_routes(organization, version, "LFT", 1)
  end

  # The zones as stored, read through the same scoped context read the page uses.
  defp stored_zones(organization, version) do
    organization.id
    |> Gtfs.list_agencies(version.id)
    |> Map.new(&{&1.agency_id, &1.agency_timezone})
  end

  defp open_drawer(view, opener), do: view |> element(opener) |> render_click()

  defp review(view, zone) do
    view
    |> form("#agency-timezone-form", %{"timezone" => %{"zone" => zone}})
    |> render_submit()
  end

  defp apply_review(view, acknowledged?) do
    view
    |> form("#agency-timezone-review-form", %{
      "timezone" => %{"acknowledged" => to_string(acknowledged?)}
    })
    |> render_submit()
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

  # One list item's text on a single line: the drawer's rows sit in the page
  # differently at each width, so the readings compare text rather than layout.
  defp item_rows(doc, selector) do
    doc
    |> LazyHTML.query("#{selector} li")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp zone_options(doc) do
    doc
    |> LazyHTML.query("#agency-timezone-zone-zones option")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
  end

  describe "choosing a zone" do
    setup :editor_setup

    test "the band action opens the drawer on the stored zone, with the accepted zones and the agencies",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      agreed_version(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      # Closed is closed: the drawer holds no zone field to submit by accident.
      assert has_element?(view, @closed_drawer)
      refute has_element?(view, "#agency-timezone-form")
      refute has_element?(view, "#agency-timezone-zone")

      open_drawer(view, "#agencies-change-timezone")

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-timezone-drawer-title", "Change version timezone")

      assert has_element?(
               view,
               "#agency-timezone-drawer-scope",
               "#{version.name} · #{organization.name}"
             )

      # The resolved zone is the starting point, and the field says where a zone
      # may come from: the same list the server validates against (INV-4).
      assert has_element?(view, "#agency-timezone-zone[value='America/New_York']")
      assert has_element?(view, "#agency-timezone-zone[list='agency-timezone-zone-zones']")
      assert has_element?(view, "#agency-timezone-zone[autocomplete='off']")

      assert has_element?(
               view,
               "#agency-timezone-zone-help",
               "Search by city or enter an IANA timezone, such as America/New_York."
             )

      doc = LazyHTML.from_fragment(render(view))

      assert zone_options(doc) == DisplayClock.zone_names()
      assert "America/New_York" in zone_options(doc)

      assert text_of(doc, "#agency-timezone-impact") =~
               "This affects every agency in #{version.name}"

      assert text_of(doc, "#agency-timezone-impact") =~
               "Clock times will stay the same. Their timezone interpretation will change. Review affected schedules before exporting."

      # The drawer names the agencies from the same read the list page uses.
      assert item_rows(doc, "#agency-timezone-current") ==
               ["Harbor Shuttle America/New_York", "North Coast Transit America/New_York"]

      assert item_rows(doc, "#agency-timezone-current") ==
               organization.id
               |> FeedSettings.list_agencies(version.id)
               |> Enum.map(&"#{&1.agency.agency_name} #{&1.agency.agency_timezone}")

      assert has_element?(view, "#agency-timezone-review")
      assert has_element?(view, "#agency-timezone-cancel")
      refute has_element?(view, "#agency-timezone-ack")
    end

    test "an invalid zone marks its field, keeps the entry and opens no review",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      agreed_version(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_drawer(view, "#agencies-change-timezone")

      review(view, "Not/a_zone")

      assert has_element?(view, @open_drawer)

      assert has_element?(
               view,
               "#agency-timezone-zone-error",
               "Choose a valid timezone, such as America/New_York."
             )

      assert has_element?(view, "#agency-timezone-zone[aria-invalid='true']")

      # The entry survives the refusal, and nothing was reviewed or written.
      assert has_element?(view, "#agency-timezone-zone[value='Not/a_zone']")
      refute has_element?(view, "#agency-timezone-review-form")
      refute has_element?(view, "#agency-timezone-review-list")

      assert stored_zones(organization, version) == %{
               "HBR" => "America/New_York",
               "NCT" => "America/New_York"
             }

      # A valid zone then opens the review and clears the field error.
      review(view, "America/Chicago")

      assert has_element?(view, "#agency-timezone-review-form")
      refute has_element?(view, "#agency-timezone-zone-error")
    end

    test "the callout action resolves a conflicting version from a blank zone",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      conflicting_version(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      assert has_element?(view, "#agencies-timezone-callout", "Agencies use different timezones")

      # Both entry points reach the one drawer: the band's generic action and the
      # callout's reason-specific one.
      assert has_element?(view, "#agencies-change-timezone")
      assert has_element?(view, "#agencies-resolve-timezones")

      open_drawer(view, "#agencies-resolve-timezones")

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-timezone-drawer-title", "Resolve agency timezones")

      # An unresolved version has no zone to change, so the field starts blank.
      assert has_element?(view, "#agency-timezone-zone[value='']")
      refute has_element?(view, "#agency-timezone-zone[value='America/New_York']")
    end

    test "a version with no agencies offers no timezone action",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      # One route still without an agency, which is what the empty state counts.
      {:ok, _route} =
        Gtfs.create_route(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          route_id: "NO_AGENCY",
          route_short_name: "1",
          route_type: 3
        })

      {:ok, view, _html} = live(conn, agencies_path(version.id))

      assert has_element?(view, "#agencies-empty")
      refute has_element?(view, "#agencies-change-timezone")
      refute has_element?(view, "#agencies-resolve-timezones")
      refute has_element?(view, "#agencies-timezone-band")
    end
  end

  describe "reviewing and applying" do
    setup :editor_setup

    test "the review lists every agency with its zone, the new zone and its route count",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      conflicting_version(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_drawer(view, "#agencies-change-timezone")

      review(view, "America/Chicago")

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-timezone-drawer-title", "Review timezone change")

      doc = LazyHTML.from_fragment(render(view))

      assert item_rows(doc, "#agency-timezone-review-list") == [
               "Lakefront Transit America/Denver → America/Chicago 1 route",
               "North Coast Transit America/New_York → America/Chicago 2 routes"
             ]

      assert text_of(doc, "#agency-timezone-review-summary") =~
               "2 agencies will use America/Chicago"

      assert text_of(doc, "#agency-timezone-review-summary") =~
               "Only #{version.name} changes. Other versions keep their current timezone."

      assert text_of(doc, "#agency-timezone-not-converted") =~
               "Route and trip clock times are not converted. Check calendars, schedules, and overnight service after this change."

      # The review names the change; the zone field belongs to the choose step,
      # so the reviewed zone never round-trips through the client (INV-3, CR-9).
      refute has_element?(view, "#agency-timezone-zone")
      refute has_element?(view, "#agency-timezone-form")

      assert has_element?(view, "#agency-timezone-ack")
      assert has_element?(view, "#agency-timezone-apply[phx-disable-with='Applying…']")
      assert has_element?(view, "#agency-timezone-back")
    end

    test "apply without the acknowledgement names the missing confirmation and writes nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      conflicting_version(organization, version)
      before = stored_zones(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_drawer(view, "#agencies-change-timezone")
      review(view, "America/Chicago")

      apply_review(view, false)

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-timezone-ack-error", @ack_error)
      assert has_element?(view, "#agency-timezone-ack[aria-invalid='true']")
      assert has_element?(view, "#agency-timezone-apply")

      assert_push_event(view, "focus_form_error", %{
        form_id: "agency-timezone-review-form",
        fallback_id: "agency-timezone-ack"
      })

      assert stored_zones(organization, version) == before

      assert %{fallback?: true, fallback_reason: :conflicting} =
               DisplayClock.resolve_zone(organization.id, version.id)

      # The acknowledgement clears the error and leaves the same review.
      apply_review(view, true)

      refute has_element?(view, "#agency-timezone-ack-error")
      assert has_element?(view, @closed_drawer)

      assert has_element?(
               view,
               "#flash-info",
               "Timezone updated for 2 agencies. Review affected schedules before exporting."
             )

      assert stored_zones(organization, version) == %{
               "LFT" => "America/Chicago",
               "NCT" => "America/Chicago"
             }

      assert %{timezone: "America/Chicago", fallback?: false} =
               DisplayClock.resolve_zone(organization.id, version.id)

      # The page behind the drawer reloaded: one zone, named in the band.
      doc = LazyHTML.from_fragment(render(view))

      assert text_of(doc, "#agencies-timezone-band") =~
               "America/Chicago · Used by all agencies and their schedules."

      refute has_element?(view, "#agencies-timezone-callout")
      refute has_element?(view, "#agency-timezone-form")
    end

    test "an agency added after the review makes apply stale, and Review again lists it",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      conflicting_version(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_drawer(view, "#agencies-change-timezone")
      review(view, "America/Chicago")

      # Another editor creates an agency while the review is on screen, so the
      # review no longer describes the version it would rewrite (AC-18, INV-3).
      create_agency(organization, version, "RIV", "Riverside Transit", "America/New_York")
      before = stored_zones(organization, version)

      apply_review(view, true)

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-timezone-drawer-title", "Review timezone change")

      assert has_element?(
               view,
               "#agency-timezone-stale",
               "The agencies changed during your review"
             )

      assert has_element?(view, "#agency-timezone-stale", "Nothing was changed.")
      assert has_element?(view, "#agency-timezone-review-again")
      refute has_element?(view, "#agency-timezone-apply")
      refute has_element?(view, "#agency-timezone-ack")
      refute has_element?(view, "#flash-info")

      assert stored_zones(organization, version) == before

      # Review again reads the version as it now is, with the zone the server
      # already holds.
      view |> element("#agency-timezone-review-again") |> render_click()

      assert has_element?(view, "#agency-timezone-drawer-title", "Review timezone change")
      refute has_element?(view, "#agency-timezone-stale")
      assert has_element?(view, "#agency-timezone-apply")

      doc = LazyHTML.from_fragment(render(view))

      assert item_rows(doc, "#agency-timezone-review-list") == [
               "Lakefront Transit America/Denver → America/Chicago 1 route",
               "North Coast Transit America/New_York → America/Chicago 2 routes",
               "Riverside Transit America/New_York → America/Chicago 0 routes"
             ]

      assert text_of(doc, "#agency-timezone-review-summary") =~
               "3 agencies will use America/Chicago"

      apply_review(view, true)

      assert has_element?(view, @closed_drawer)
      assert has_element?(view, "#flash-info", "Timezone updated for 3 agencies.")

      assert stored_zones(organization, version) == %{
               "LFT" => "America/Chicago",
               "NCT" => "America/Chicago",
               "RIV" => "America/Chicago"
             }
    end

    test "Back keeps the chosen zone on an unresolved version, and closing drops the review",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      conflicting_version(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_drawer(view, "#agencies-change-timezone")

      # The version has no single zone, so this drawer resolves one: the title
      # names that step, not a change to a zone the version does not have.
      assert has_element?(view, "#agency-timezone-drawer-title", "Resolve agency timezones")

      review(view, "America/Chicago")
      view |> element("#agency-timezone-back") |> render_click()

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-timezone-drawer-title", "Resolve agency timezones")
      assert has_element?(view, "#agency-timezone-zone[value='America/Chicago']")
      refute has_element?(view, "#agency-timezone-review-list")

      view |> element("#agency-timezone-cancel") |> render_click()

      assert has_element?(view, @closed_drawer)
      refute has_element?(view, "#agency-timezone-form")

      # Reopening starts from the stored state again, not from the draft.
      open_drawer(view, "#agencies-change-timezone")

      assert has_element?(view, "#agency-timezone-zone[value='']")
    end

    test "Back keeps the chosen zone on a version whose zone resolves",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      agreed_version(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_drawer(view, "#agencies-change-timezone")

      # One zone for the version, so the same surface changes that zone.
      assert has_element?(view, "#agency-timezone-drawer-title", "Change version timezone")
      assert has_element?(view, "#agency-timezone-zone[value='America/New_York']")

      review(view, "America/Chicago")
      view |> element("#agency-timezone-back") |> render_click()

      assert has_element?(view, @open_drawer)
      assert has_element?(view, "#agency-timezone-drawer-title", "Change version timezone")
      assert has_element?(view, "#agency-timezone-zone[value='America/Chicago']")
      refute has_element?(view, "#agency-timezone-review-list")
      assert has_element?(view, "#agency-timezone-form")

      # Closing drops the draft: reopening shows the stored zone, not the
      # reviewed one.
      view |> element("#agency-timezone-cancel") |> render_click()

      assert has_element?(view, @closed_drawer)
      open_drawer(view, "#agencies-change-timezone")

      assert has_element?(view, "#agency-timezone-zone[value='America/New_York']")
    end
  end

  describe "access" do
    setup :editor_setup

    test "a membership deactivated after the drawer opened refuses review and apply, writing nothing",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)
      conflicting_version(organization, version)
      before = stored_zones(organization, version)

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_drawer(view, "#agencies-change-timezone")
      review(view, "America/Chicago")

      Accounts.get_user_org_membership(user.id, organization.id)
      |> deactivate_membership_fixture()

      apply_review(view, true)

      assert has_element?(view, @closed_drawer)

      assert has_element?(
               view,
               "#flash-error",
               "You no longer have editor access to this organization."
             )

      assert stored_zones(organization, version) == before

      # The same refusal covers the review step, which authorizes on its own.
      open_drawer(view, "#agencies-change-timezone")
      review(view, "America/Chicago")

      assert has_element?(view, @closed_drawer)
      assert has_element?(view, "#flash-error", "no longer have editor access")
      assert stored_zones(organization, version) == before
    end

    test "a member without the editor role cannot reach the page",
         %{conn: conn, organization: organization, version: version} do
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
  end
end
