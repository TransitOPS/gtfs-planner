defmodule GtfsPlannerWeb.Gtfs.AgencyDeleteLiveTest do
  @moduledoc """
  The delete agency flow on the Agencies page: the disabled last agency, the
  receiving-agency choice, the review, the apply, the no-routes path, the
  fare-reference block and the stale review (AC-19, AC-20, AC-21, AC-22; CL-17,
  EV-24).

  Every case drives the page through the real router and the real context calls
  the LiveView makes, so a case that passes here reviewed and applied the
  deletion through `FeedSettings.review_agency_deletion/3` and
  `delete_agency/4` with the LiveView's own audit context. What a deletion did is
  read back from the stored rows — the agency's presence, each route's
  `agency_id` and the receiving agency's count — so "nothing moved" and "these
  routes moved" are claimed from the data and not from the drawer, and the stale
  case moves the version the way another editor's write would between the review
  and the apply.
  """

  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.GtfsFixtures
  alias GtfsPlanner.Repo

  @open_drawer "#agency-drawer-overlay[data-open='true']"
  @closed_drawer "#agency-drawer-overlay[data-open='false']"
  @editor_access "You no longer have editor access to this organization."
  @last_agency_reason "This is the last agency in the version and can't be deleted."
  @target_required "Choose the agency that will receive these routes."
  @review_total "The move and deletion must succeed together. If this review becomes out of date, nothing is changed."

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"

  # A per-call address: the shared `user_fixture/1` counter restarts with each
  # BEAM run, so a row an unboxed test left in the shared database can collide
  # with it inside the fixture. The prefix keeps this file out of that range.
  defp editor_email do
    "agencies-delete-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
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
  defp create_agency(organization, version, agency_id, name) do
    {:ok, agency} =
      GtfsFixtures.insert_agency(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        agency_id: agency_id,
        agency_name: name,
        agency_url: "https://#{String.downcase(agency_id)}.example",
        agency_timezone: "America/New_York"
      })

    agency
  end

  # A route needs a short or a long name (`Route.changeset/2` refuses one with
  # neither), so a call site that supplies neither gets the route ID as its short
  # name instead of a changeset the fixture cannot insert.
  defp create_route(organization, version, attrs) do
    attrs =
      Map.merge(
        %{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          route_type: 3
        },
        attrs
      )

    attrs =
      if attrs[:route_short_name] || attrs[:route_long_name] do
        attrs
      else
        Map.put(attrs, :route_short_name, attrs[:route_id])
      end

    {:ok, route} = GtfsFixtures.insert_route(attrs)

    route
  end

  # A fare attribute with no editor in this package: it supplies the reference the
  # deletion has to refuse, so a raw insert is the fixture and not a second write
  # path.
  defp insert_fare_attribute(organization, version, attrs) do
    %FareAttribute{}
    |> FareAttribute.changeset(
      Map.merge(
        %{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          price: Decimal.new("2.50"),
          currency_type: "USD",
          payment_method: 0
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp open_edit(view, agency), do: view |> element("#agency-open-#{agency.id}") |> render_click()

  defp start_delete(view), do: render_click(view, "start_delete", %{})

  defp review_deletion(view, target_id) do
    view
    |> form("#agency-delete-form", %{"agency_delete" => %{"target_id" => target_id}})
    |> render_submit()
  end

  # An agency with no routes renders no receiving-agency control at all, so its
  # review step is submitted as the form is: with none of the fields it does not
  # render.
  defp review_without_a_choice(view) do
    view |> element("#agency-delete-form") |> render_submit()
  end

  defp apply_deletion(view), do: render_click(view, "apply_delete", %{})

  defp refresh_review(view), do: render_click(view, "refresh_delete_review", %{})

  # The rows the page itself lists with, so an expectation reads the same shape
  # the drawer renders: `FeedSettings.list_agencies/2` wraps each agency in its
  # route count, unlike the context's bare agency rows.
  defp agency_rows(organization, version) do
    FeedSettings.list_agencies(organization.id, version.id)
  end

  # The row as stored, read through the scoped read the page lists with, so an
  # expectation reads the same fields the deletion either left in place or
  # removed.
  defp stored_agency(organization, version, agency_id) do
    organization
    |> agency_rows(version)
    |> Enum.find(&(&1.agency.agency_id == agency_id))
  end

  defp route_count(organization, version, agency_id) do
    organization
    |> agency_rows(version)
    |> Enum.find_value(0, fn row ->
      if row.agency.agency_id == agency_id, do: row.route_count
    end)
  end

  # Each route's stored `agency_id`, read through the scoped read: a move is only
  # claimed from the rows that carry the reference.
  defp route_agency(organization, version, route_id) do
    case Gtfs.get_route_by_route_id(organization.id, version.id, route_id) do
      nil -> nil
      route -> route.agency_id
    end
  end

  defp route_ids_on(organization, version, agency_id) do
    organization.id
    |> Gtfs.list_routes(version.id)
    |> Enum.filter(&(&1.agency_id == agency_id))
    |> Enum.map(& &1.route_id)
    |> Enum.sort()
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

  # Each row's own cells, in the order the row renders them. A flex row's cells
  # carry no whitespace between them in the markup — the layout's `gap-4` is what
  # separates them — so joining a row into one string reads "r1 FirstKeep route
  # ID". Reading the cells separately also fails when a row loses either one.
  defp row_cells(view, container) do
    view
    |> element(container)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{container} li")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.query("span")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
    end)
  end

  # Every option of a select, in the order the drawer offers them: the list is
  # what proves the other agencies are choosable and the agency itself is not.
  defp option_labels(doc, selector) do
    doc
    |> LazyHTML.query("#{selector} option")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # The values the receiving-agency select submits, read from the rendered
  # markup: exactly one option carries `selected`, so a select that lost its
  # value and a select that marks two choices both fail here. LazyHTML returns an
  # attribute's values as a list, one per root element.
  defp selected_targets(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#agency-delete-form_target_id option[selected]")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
  end

  describe "the last agency (AC-19)" do
    setup :editor_setup

    test "is disabled with its reason and the server refuses the deletion", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      agency = create_agency(organization, version, "SOLO", "Solo Transit")
      create_route(organization, version, %{route_id: "s1", agency_id: "SOLO"})

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, agency)

      # The footer still offers the action, and the action names why it cannot be
      # used: one agency has no receiving agency and the version cannot end up
      # with none.
      assert has_element?(view, "#agency-delete[disabled]", "Delete agency")

      assert text_of(LazyHTML.from_fragment(render(view)), "#agency-delete-reason") ==
               @last_agency_reason

      # A disabled control is refused by the browser and by the server, so the
      # event that would open the flow changes nothing either.
      start_delete(view)

      assert has_element?(view, @open_drawer)
      refute has_element?(view, "#agency-delete-choose")
      refute has_element?(view, "#agency-delete-review")
      assert stored_agency(organization, version, "SOLO")
      assert route_ids_on(organization, version, "SOLO") == ["s1"]
    end
  end

  describe "deleting an agency with routes (AC-20)" do
    setup :editor_setup

    test "chooses a receiving agency, reviews the routes and moves them on apply", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      alpha = create_agency(organization, version, "ALPHA", "Alpha Transit")
      bravo = create_agency(organization, version, "BETA", "Beta Transit")

      create_route(organization, version, %{
        route_id: "r2",
        route_short_name: "2",
        route_long_name: "Second",
        agency_id: "ALPHA"
      })

      create_route(organization, version, %{
        route_id: "r1",
        route_short_name: "1",
        route_long_name: "First",
        agency_id: "ALPHA"
      })

      create_route(organization, version, %{
        route_id: "r3",
        route_short_name: "3",
        route_long_name: "Third",
        agency_id: "BETA"
      })

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, alpha)
      start_delete(view)

      assert has_element?(view, "#agency-delete-choose")
      assert has_element?(view, "#agency-drawer-title", "Delete Alpha Transit?")

      assert text_of(LazyHTML.from_fragment(render(view)), "#agency-delete-identity") ==
               "Agency ID ALPHA · 2 routes"

      # The receiving agency is the other agencies of this version only, and the
      # prompt is the missing choice rather than an option.
      assert option_labels(
               LazyHTML.from_fragment(render(view)),
               "#agency-delete-form_target_id"
             ) == ["Choose agency", "Beta Transit"]

      assert has_element?(view, "#agency-delete-review-submit", "Review deletion")

      # Reviewing without a choice is refused beside the field the editor used.
      review_deletion(view, "")

      assert has_element?(view, "#agency-delete-choose")
      refute has_element?(view, "#agency-delete-review")

      assert text_of(
               LazyHTML.from_fragment(render(view)),
               "#agency-delete-form_target_id-error"
             ) == @target_required

      review_deletion(view, bravo.id)

      assert has_element?(view, "#agency-delete-review")
      assert has_element?(view, "#agency-drawer-title", "Review agency removal")

      summary = text_of(LazyHTML.from_fragment(render(view)), "#agency-delete-summary")

      assert summary =~ "Alpha Transit will be deleted"
      assert summary =~ "2 routes will move to Beta Transit. No routes will be deleted."
      refute has_element?(view, "#agency-delete-translations")

      # The reviewed list is exactly the routes that carry the agency's own ID, in
      # the context's order, and each row names the route and says its ID is kept.
      assert row_cells(view, "#agency-delete-routes") == [
               ["r1 First", "Keep route ID"],
               ["r2 Second", "Keep route ID"]
             ]

      assert text_of(LazyHTML.from_fragment(render(view)), "#agency-delete-total") ==
               @review_total

      assert has_element?(view, "#agency-delete-apply", "Move routes and delete")

      # Back returns to the receiving-agency step with the choice the editor
      # already made still selected, and the same command reviews again.
      render_click(view, "start_delete", %{})

      assert has_element?(view, "#agency-delete-choose")
      refute has_element?(view, "#agency-delete-review")

      assert selected_targets(view) == [bravo.id]

      review_deletion(view, bravo.id)

      assert has_element?(view, "#agency-delete-review")

      apply_deletion(view)

      assert has_element?(view, @closed_drawer)

      assert has_element?(
               view,
               "#flash-info",
               "Alpha Transit deleted. 2 routes moved to Beta Transit."
             )

      refute stored_agency(organization, version, "ALPHA")
      assert route_agency(organization, version, "r1") == "BETA"
      assert route_agency(organization, version, "r2") == "BETA"
      assert route_agency(organization, version, "r3") == "BETA"
      assert route_count(organization, version, "BETA") == 3

      # One agency is left, so the page behind the drawer is its summary.
      assert has_element?(view, "#agency-summary-name", "Beta Transit")
      assert has_element?(view, "#agency-summary-route-count", "3")
      refute has_element?(view, "#agencies")
      refute has_element?(view, "#agency-summary", "Alpha Transit")
    end
  end

  describe "deleting an agency without routes (AC-20)" do
    setup :editor_setup

    test "reviews without a receiving agency and deletes on apply", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      gamma = create_agency(organization, version, "GAMMA", "Gamma Transit")
      create_agency(organization, version, "BETA", "Beta Transit")
      create_route(organization, version, %{route_id: "r3", agency_id: "BETA"})

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, gamma)
      start_delete(view)

      assert has_element?(view, "#agency-delete-choose")

      # Nothing can move, so nothing is asked for: no receiving agency field and
      # the step says what the deletion removes.
      refute has_element?(view, "#agency-delete-form_target_id")

      assert text_of(LazyHTML.from_fragment(render(view)), "#agency-delete-identity") ==
               "Agency ID GAMMA · 0 routes"

      review_without_a_choice(view)

      assert has_element?(view, "#agency-delete-review")

      assert text_of(LazyHTML.from_fragment(render(view)), "#agency-delete-summary") =~
               "No routes or fare references need to move."

      refute has_element?(view, "#agency-delete-routes li")
      assert has_element?(view, "#agency-delete-apply", "Delete agency")

      apply_deletion(view)

      assert has_element?(view, "#flash-info", "Gamma Transit deleted.")
      refute stored_agency(organization, version, "GAMMA")
      # The other agency and its route are untouched.
      assert stored_agency(organization, version, "BETA")
      assert route_agency(organization, version, "r3") == "BETA"
    end
  end

  describe "blocking references (AC-21)" do
    setup :editor_setup

    test "lists the fare attribute that names the agency and offers no deletion", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      alpha = create_agency(organization, version, "ALPHA", "Alpha Transit")
      bravo = create_agency(organization, version, "BETA", "Beta Transit")
      create_route(organization, version, %{route_id: "r1", agency_id: "ALPHA"})

      fare =
        insert_fare_attribute(organization, version, %{fare_id: "F1", agency_id: "ALPHA"})

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, alpha)
      start_delete(view)

      # The fare attribute blocks the deletion even though a receiving agency was
      # available and the routes could have moved.
      review_deletion(view, bravo.id)

      assert has_element?(view, "#agency-delete-blocked")

      # The blocker explanation reads as the prototype's sentence and names the
      # reference the list below it carries.
      blocked = LazyHTML.from_fragment(render(view))

      assert text_of(blocked, "#agency-delete-blocked-callout p.font-bold") ==
               "Alpha Transit cannot be deleted yet"

      assert text_of(blocked, "#agency-delete-blocked-callout p.font-bold") ==
               "Alpha Transit cannot be deleted yet"

      assert text_of(blocked, "#agency-delete-blocked-callout") =~
               "A fare attribute still refers to this agency. Reassign those references " <>
                 "before moving routes and deleting the agency."

      assert row_cells(view, "#agency-delete-blockers") == [["Fare attribute", "F1"]]

      # Nothing is applied from here: the step offers the way back to the agency
      # and the way out, and no Delete agency or apply action at all.
      assert has_element?(view, "#agency-delete-back-to-agency", "Back to agency")
      assert has_element?(view, "#agency-delete-close", "Close")
      refute has_element?(view, "#agency-delete")
      refute has_element?(view, "#agency-delete-apply")
      refute has_element?(view, "#agency-delete-review")

      # Back to agency returns to the form the drawer opened with.
      render_click(view, "back_to_agency", %{})

      refute has_element?(view, "#agency-delete-blocked")
      assert has_element?(view, "#agency-form_agency_name[value='Alpha Transit']")

      assert Repo.get(FareAttribute, fare.id)
      assert stored_agency(organization, version, "ALPHA")
      assert route_agency(organization, version, "r1") == "ALPHA"
    end
  end

  describe "a version that moved after the review (AC-22)" do
    setup :editor_setup

    test "applies to nothing, offers Refresh review and reviews the new route", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      alpha = create_agency(organization, version, "ALPHA", "Alpha Transit")
      bravo = create_agency(organization, version, "BETA", "Beta Transit")

      create_route(organization, version, %{
        route_id: "r1",
        route_long_name: "First",
        agency_id: "ALPHA"
      })

      create_route(organization, version, %{
        route_id: "r2",
        route_long_name: "Second",
        agency_id: "ALPHA"
      })

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, alpha)
      start_delete(view)
      review_deletion(view, bravo.id)

      assert row_cells(view, "#agency-delete-routes") == [
               ["r1 First", "Keep route ID"],
               ["r2 Second", "Keep route ID"]
             ]

      # Another editor adds a route to the agency after the review, which is what
      # the reviewed fingerprint binds.
      create_route(organization, version, %{
        route_id: "r3",
        route_long_name: "Third",
        agency_id: "ALPHA"
      })

      apply_deletion(view)

      assert has_element?(view, "#agency-delete-stale")

      assert text_of(LazyHTML.from_fragment(render(view)), "#agency-delete-stale-notice") =~
               "The agencies or routes changed during your review"

      assert text_of(LazyHTML.from_fragment(render(view)), "#agency-delete-stale-notice") =~
               "Nothing was moved or deleted."

      # The stale review cannot be applied again: Refresh review is the way on.
      assert has_element?(view, "#agency-delete-apply[disabled]")
      assert has_element?(view, "#agency-delete-refresh", "Refresh review")

      # Nothing changed: the agency is there, its routes still point at it, and
      # the receiving agency holds nothing.
      assert stored_agency(organization, version, "ALPHA")
      assert route_ids_on(organization, version, "ALPHA") == ["r1", "r2", "r3"]
      assert route_count(organization, version, "BETA") == 0

      refresh_review(view)

      refute has_element?(view, "#agency-delete-stale")
      assert has_element?(view, "#agency-delete-review")

      assert row_cells(view, "#agency-delete-routes") == [
               ["r1 First", "Keep route ID"],
               ["r2 Second", "Keep route ID"],
               ["r3 Third", "Keep route ID"]
             ]

      # The refreshed review is the command the next apply uses.
      apply_deletion(view)

      assert has_element?(
               view,
               "#flash-info",
               "Alpha Transit deleted. 3 routes moved to Beta Transit."
             )

      refute stored_agency(organization, version, "ALPHA")
      assert route_ids_on(organization, version, "BETA") == ["r1", "r2", "r3"]
    end
  end

  describe "scope and authority (AC-28)" do
    setup :editor_setup

    test "another version's routes and another organization's fares neither move nor block", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      alpha = create_agency(organization, version, "ALPHA", "Alpha Transit")
      bravo = create_agency(organization, version, "BETA", "Beta Transit")
      create_route(organization, version, %{route_id: "r1", agency_id: "ALPHA"})

      # The same agency ID in another version of this organization, and a fare
      # attribute in another organization: neither is this version's state, so the
      # move takes nothing from the first and the second blocks nothing.
      other_version = gtfs_version_fixture(organization.id)
      create_route(organization, other_version, %{route_id: "other-1", agency_id: "ALPHA"})

      other_organization = organization_fixture()
      other_org_version = gtfs_version_fixture(other_organization.id)

      other_fare =
        insert_fare_attribute(other_organization, other_org_version, %{
          fare_id: "F-OTHER",
          agency_id: "ALPHA"
        })

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, alpha)
      start_delete(view)
      review_deletion(view, bravo.id)

      assert has_element?(view, "#agency-delete-review")
      refute has_element?(view, "#agency-delete-blocked")

      apply_deletion(view)

      assert has_element?(
               view,
               "#flash-info",
               "Alpha Transit deleted. 1 route moved to Beta Transit."
             )

      refute stored_agency(organization, version, "ALPHA")

      # The other version's route still names the agency ID it always named, and
      # the other organization's row is untouched.
      assert route_agency(organization, other_version, "other-1") == "ALPHA"
      assert Repo.get(FareAttribute, other_fare.id)
      assert route_ids_on(organization, other_version, "ALPHA") == ["other-1"]
    end

    test "a membership demoted after the drawer opened writes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      alpha = create_agency(organization, version, "ALPHA", "Alpha Transit")
      bravo = create_agency(organization, version, "BETA", "Beta Transit")
      create_route(organization, version, %{route_id: "r1", agency_id: "ALPHA"})

      {:ok, view, _html} = live(conn, agencies_path(version.id))
      open_edit(view, alpha)
      start_delete(view)

      Accounts.get_user_org_membership(user.id, organization.id)
      |> deactivate_membership_fixture()

      review_deletion(view, bravo.id)

      assert has_element?(view, @closed_drawer)
      assert has_element?(view, "#flash-error", @editor_access)
      assert stored_agency(organization, version, "ALPHA")
      assert route_agency(organization, version, "r1") == "ALPHA"
    end
  end
end
