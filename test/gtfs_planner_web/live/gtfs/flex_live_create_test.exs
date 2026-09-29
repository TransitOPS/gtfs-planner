defmodule GtfsPlannerWeb.Gtfs.FlexLiveCreateTest do
  @moduledoc """
  Merge evidence (EV-21) for the Flex create drawer and the copy action.

  The drawer is the Flex list's only way to add a service (AC-4). These cases
  judge it as the editor sees it: the header's button opens it with both kinds
  and the booked-stops pointer, a kind answer adds the one-name question, and
  the "no" answer advises one service per name. A submit that misses an answer
  lists every missing answer at once, links each item to its field, moves focus
  to the summary and writes nothing; a complete submit creates the service —
  area or detour, with no detour distance chosen — and navigates to its page.

  The copy action is judged the same way (AC-6, R14): it renders only on a
  version with no services, offers this organization's other published versions
  — never another organization's or an unpublished one — asks for confirmation
  by naming the version being copied from, and copies every service with its
  areas. A version that holds services offers no copy action at all.

  The focused command is deferred to branch review:
  `mix test test/gtfs_planner_web/live/gtfs/flex_live_create_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Geometry

  describe "the create drawer" do
    setup :editor_with_flex_version

    test "the header button opens the drawer with both kinds and no stops kind", ctx do
      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.version))

      loaded(view)

      refute has_element?(view, "#create-drawer-overlay[data-open='true']")

      view |> element("#create-service") |> render_click()

      document = doc(view)

      # The drawer is open, and nothing has answered its first question yet:
      # the header's button opens the question itself rather than a kind.
      assert has_element?(view, "#create-drawer-overlay[data-open='true']")
      assert attribute(document, "#create-drawer-overlay", "data-initial-focus") == "heading"
      assert attribute(document, "#create-drawer-overlay", "data-initial-focus-id") == nil

      assert attribute(document, "#create-drawer-overlay", "data-return-focus-id") ==
               "create-service"

      assert text_of(document, "#create-drawer-title") == "Create flex service"
      assert text_of(document, "#create-drawer-description") == ctx.version.name

      assert text_of(document, "#create-pattern-area") =~ "Rides anywhere in an area"
      assert text_of(document, "#create-pattern-route") =~ "A route that detours on request"
      assert attribute(document, "#create-pattern-area", "name") == "create[kind]"
      assert attribute(document, "#create-pattern-area", "checked") == nil

      # There is no third kind: a stop served only when booked stays on the
      # route's timetable, which is what the pointer above the name answers.
      assert LazyHTML.query(document, "#create-pattern-stops") == []
      assert text_of(document, "#create-drawer-content") =~ "Booking required"

      # The one-name question belongs to the area kind, and the drawer starts
      # without one.
      assert LazyHTML.query(document, "#create-named-one") == []
      assert LazyHTML.query(document, "#create-route_id") == []
      assert LazyHTML.query(document, "#create_name") != []
    end

    test "the first-use buttons open the drawer with their kind already chosen", ctx do
      empty_version = gtfs_version_fixture(ctx.organization.id)
      {:ok, view, _html} = live(ctx.conn, flex_path(empty_version))

      loaded(view)

      view |> element("#flex-create-area") |> render_click()

      document = doc(view)

      assert attribute(document, "#create-drawer-overlay", "data-initial-focus-id") ==
               "create_name"

      assert attribute(document, "#create-drawer-overlay", "data-return-focus-id") ==
               "flex-create-area"

      assert has_element?(view, "#create-pattern-area[checked]")

      assert text_of(document, "#create-drawer-content") =~
               "Do riders know the areas by one name?"

      assert has_element?(view, "#create-named-one[checked]")
    end

    test "choosing no to the one-name question advises one service per name", ctx do
      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.version))

      loaded(view)
      view |> element("#create-service") |> render_click()

      html =
        view
        |> element("#create-form")
        |> render_change(%{"create" => %{"kind" => "area"}})

      assert html =~ "Do riders know the areas by one name?"
      assert html =~ "Towns can still have their own hours"
      refute html =~ "Create one service for each name"

      html =
        view
        |> element("#create-form")
        |> render_change(%{"create" => %{"kind" => "area", "named" => "several"}})

      assert html =~
               "Create one service for each name, such as Newport Dial-a-Ride and Toledo Flex"

      assert has_element?(view, "#create-named-several[checked]")

      # The detour kind asks for its route instead, and keeps the names it was
      # given if the editor flips back.
      html =
        view |> element("#create-form") |> render_change(%{"create" => %{"kind" => "detour"}})

      refute html =~ "Do riders know the areas by one name?"
      assert has_element?(view, "#create_route_id")
      assert html =~ "20 Valley Line"
    end

    test "a submit with no kind or name lists every missing answer and writes nothing", ctx do
      before = service_names(ctx.organization.id, ctx.version.id)

      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.version))

      loaded(view)
      view |> element("#create-service") |> render_click()

      view
      |> element("#create-form")
      |> render_submit(%{"create" => %{"kind" => "", "name" => ""}})

      assert_push_event(view, "focus_scoped_target", %{id: "create-error-summary"})

      document = doc(view)

      assert text_of(document, "#create-error-summary") =~
               "Answer 2 questions to create the service"

      assert summary_links(document) == ["#create-pattern-area", "#create_name"]

      assert text_of(document, "#create-error-summary") =~ "Choose how the service works."
      assert text_of(document, "#create-error-summary") =~ "Enter the service name riders see."
      assert attribute(document, "#create-pattern-area", "aria-invalid") == "true"
      assert attribute(document, "#create_name", "aria-invalid") == "true"

      assert service_names(ctx.organization.id, ctx.version.id) == before
    end

    test "a detour with no route is refused on its own question", ctx do
      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.version))

      loaded(view)
      view |> element("#create-service") |> render_click()

      view
      |> element("#create-form")
      |> render_change(%{"create" => %{"kind" => "detour"}})

      view
      |> element("#create-form")
      |> render_submit(%{"create" => %{"route_id" => "", "name" => "Toledo Call-ahead"}})

      document = doc(view)

      assert text_of(document, "#create-error-summary") =~
               "Answer one question to create the service"

      assert summary_links(document) == ["#create_route_id"]
      assert text_of(document, "#create-error-summary") =~ "Choose the route that detours."
      assert attribute(document, "#create_route_id", "aria-invalid") == "true"
      assert service_names(ctx.organization.id, ctx.version.id) == representative_names()
    end

    test "an area service is created from its kind and name and opens its page", ctx do
      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.version))

      loaded(view)
      view |> element("#create-service") |> render_click()

      view
      |> element("#create-form")
      |> render_change(%{"create" => %{"kind" => "area", "named" => "one"}})

      view
      |> element("#create-form")
      |> render_submit(%{"create" => %{"name" => "Seniors’ Shopper"}})

      service = service_named(ctx.organization.id, ctx.version.id, "Seniors’ Shopper")

      # The key follows R11 from the name, and the service has nothing but the
      # answers the drawer collected: no hours, no areas, no distance.
      assert service.key == "seniors-shopper"
      assert service.kind == :area
      assert service.route_id == nil
      assert service.areas == []

      assert_redirect(view, "/gtfs/#{ctx.version.id}/flex/#{service.id}")
    end

    test "a detour service is created on its route with no distance chosen", ctx do
      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.version))

      loaded(view)
      view |> element("#create-service") |> render_click()

      view
      |> element("#create-form")
      |> render_change(%{"create" => %{"kind" => "detour"}})

      view
      |> element("#create-form")
      |> render_submit(%{"create" => %{"route_id" => "20", "name" => "Toledo Call-ahead"}})

      service = service_named(ctx.organization.id, ctx.version.id, "Toledo Call-ahead")

      assert service.kind == :detour
      assert service.route_id == "20"
      assert service.distance_m == nil

      assert_redirect(view, "/gtfs/#{ctx.version.id}/flex/#{service.id}")
    end

    test "closing the drawer keeps the version unchanged", ctx do
      before = service_names(ctx.organization.id, ctx.version.id)

      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.version))

      loaded(view)
      view |> element("#create-service") |> render_click()

      view
      |> element("#create-form")
      |> render_submit(%{"create" => %{"kind" => "", "name" => ""}})

      view |> element("#create-drawer-close") |> render_click()

      assert has_element?(view, "#create-drawer-overlay[data-open='false']")
      assert LazyHTML.query(doc(view), "#create-error-summary") == []
      assert service_names(ctx.organization.id, ctx.version.id) == before
    end
  end

  describe "the copy action" do
    setup :editor_with_source_and_empty_version

    test "copies the chosen version's services, geometry included", ctx do
      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.empty_version))

      loaded(view)

      document = doc(view)

      assert text_of(document, "#flex-copy-title") == "Copy flex services from another version"

      # The select offers this organization's other published versions that hold
      # a service: the source version, and nothing else in this fixture.
      assert select_options(document, "#copy_source_version_id") == [
               {"Choose a version", ""},
               {ctx.source_version.name, to_string(ctx.source_version.id)}
             ]

      # The copy asks first, and names the version it will copy from.
      assert has_element?(view, "#copy-confirm[data-open='false']")

      view
      |> element("#flex-copy-form")
      |> render_submit(%{"copy" => %{"source_version_id" => to_string(ctx.source_version.id)}})

      assert has_element?(view, "#copy-confirm[data-open='true']")

      assert text_of(doc(view), "#copy-confirm-body") =~
               "Every flex service in #{ctx.source_version.name}"

      assert Flex.list_services(ctx.organization.id, ctx.empty_version.id) == []

      view |> element("#copy-confirm-confirm") |> render_click()

      copied = service_names(ctx.organization.id, ctx.empty_version.id)

      assert copied == representative_names()
      assert render(view) =~ "3 flex services copied from #{ctx.source_version.name}"
      assert has_element?(view, "#flex-services")

      # R14 copies the areas with the service, geometry included.
      dial_a_ride =
        service_named(ctx.organization.id, ctx.empty_version.id, "Newport Dial-a-Ride")

      assert Enum.map(dial_a_ride.areas, & &1.key) == ["a1", "a2"]
      assert %{"type" => "Polygon"} = geometry_of(dial_a_ride)

      # The version now holds services, so the copy action is gone and a second
      # copy is impossible.
      refute has_element?(view, "#flex-copy")
      refute has_element?(view, "#flex-first-use")
    end

    test "offers no copy action and copies nothing when no source is chosen", ctx do
      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.empty_version))

      loaded(view)

      view
      |> element("#flex-copy-form")
      |> render_submit(%{"copy" => %{"source_version_id" => ""}})

      assert has_element?(view, "#flex-copy-error", "Choose a version to copy from.")
      assert Flex.list_services(ctx.organization.id, ctx.empty_version.id) == []
    end

    test "offers only this organization's published versions", ctx do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      flex_representative_fixture(other_organization, other_version)

      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.empty_version))

      loaded(view)

      # A crafted event naming another organization's version copies nothing,
      # and the confirmation never opens.
      view
      |> element("#flex-copy-form")
      |> render_submit(%{"copy" => %{"source_version_id" => to_string(other_version.id)}})

      assert has_element?(view, "#flex-copy-error", "Choose one of this organization’s versions.")
      assert has_element?(view, "#copy-confirm[data-open='false']")
      assert Flex.list_services(ctx.organization.id, ctx.empty_version.id) == []

      # The other organization's own services are untouched.
      assert length(Flex.list_services(other_organization.id, other_version.id)) == 3
    end

    test "does not offer a version that holds no flex service", ctx do
      empty_source = gtfs_version_fixture(ctx.organization.id)
      flex_feed_fixture(ctx.organization, empty_source)

      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.empty_version))

      loaded(view)

      # A version with no flex service cannot be a source, so it is not offered.
      refute Enum.any?(select_options(doc(view), "#copy_source_version_id"), fn {_label, value} ->
               value == to_string(empty_source.id)
             end)

      view
      |> element("#flex-copy-form")
      |> render_submit(%{"copy" => %{"source_version_id" => to_string(empty_source.id)}})

      assert has_element?(view, "#flex-copy-error", "Choose one of this organization’s versions.")
      assert Flex.list_services(ctx.organization.id, ctx.empty_version.id) == []
    end

    test "a version with services shows no copy action", ctx do
      {:ok, view, _html} = live(ctx.conn, flex_path(ctx.source_version))

      loaded(view)

      refute has_element?(view, "#flex-first-use")
      refute has_element?(view, "#flex-copy")
      assert has_element?(view, "#create-service")
    end
  end

  # --- setup ------------------------------------------------------------------

  defp editor_with_flex_version(%{conn: conn}) do
    organization = organization_fixture()
    user = editor_for(organization)
    version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      user: user,
      version: version,
      feed: flex_representative_fixture(organization, version)
    }
  end

  # The copy action needs a source version with services and a target version
  # with none, both published and both this organization's.
  defp editor_with_source_and_empty_version(%{conn: conn}) do
    organization = organization_fixture()
    user = editor_for(organization)
    source_version = gtfs_version_fixture(organization.id)
    empty_version = gtfs_version_fixture(organization.id)

    flex_representative_fixture(organization, source_version)
    flex_feed_fixture(organization, empty_version)

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      user: user,
      source_version: source_version,
      empty_version: empty_version
    }
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

  # --- helpers ----------------------------------------------------------------

  defp flex_path(version), do: "/gtfs/#{version.id}/flex"

  # The first paint of the list defers its read, so the static response carries
  # the loading placeholder and the connected socket loads the rest. Waiting on
  # `:sys.get_state/1` is what makes the assertions read the settled socket: the
  # queued load is handled before the reply, with no sleep.
  defp loaded(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp attribute(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp summary_links(document) do
    document |> LazyHTML.query("#create-error-summary a") |> LazyHTML.attribute("href")
  end

  defp select_options(document, selector) do
    document
    |> LazyHTML.query("#{selector} option")
    |> Enum.map(fn option ->
      {option |> LazyHTML.text() |> String.trim(),
       option |> LazyHTML.attribute("value") |> List.first()}
    end)
  end

  defp representative_names, do: ["Newport Access", "Newport Dial-a-Ride", "Valley Line detours"]

  defp service_names(organization_id, version_id) do
    organization_id
    |> Flex.list_services(version_id)
    |> Enum.map(& &1.name)
  end

  defp service_named(organization_id, version_id, name) do
    organization_id
    |> Flex.list_services(version_id)
    |> Enum.find(&(&1.name == name))
  end

  defp geometry_of(service) do
    [area | _rest] = service.areas

    Geometry.get_geojson([area.id]) |> Map.fetch!(area.id)
  end
end
