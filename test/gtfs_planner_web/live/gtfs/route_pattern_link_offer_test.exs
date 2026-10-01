defmodule GtfsPlannerWeb.Gtfs.RoutePatternLinkOfferTest do
  @moduledoc """
  The link offer a hand-made pattern carries: the message after a create, the
  review that precedes a link, and what a confirmed link writes.

  The fixture is the North Coast Transit supplement
  `GtfsPlannerWeb.Gtfs.RoutePatternGroupingLiveTest` describes: 13 stops, 18
  direction-less trips over that order and 6 over its first six stops, on a
  service called "Summer weekday supplement". The saved 13-stop pattern is what
  the operator's new pattern duplicates in this scenario, and the 6-trip short
  order is what a pattern with unrelated stops must not match.

  Every expected value here is a literal from that scenario, the GTFS reference
  and the spec's rules; nothing computes one.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @full_trips 18
  @short_trips 6
  @stop_count 13
  @short_stop_count 6
  @service "SU1"
  @service_description "Summer weekday supplement"
  @pattern_name "Newport Transit Center – Lincoln City"

  setup %{conn: conn} do
    organization =
      organization_fixture(%{alias: "link-offer-#{System.unique_integer([:positive])}"})

    user =
      user_fixture(%{email: "link-offer-#{System.unique_integer([:positive])}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  describe "the offer after a create" do
    test "names the 18 trips whose stop order the new pattern serves", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      scope = build_scenario(organization, version, "LNK1")

      path = create_pattern(conn, version, "LNK1", scope.stops)
      {:ok, view, _html} = live(conn, path)

      # The URL the create navigated to carries the marker that asks for the
      # offer.
      assert has_element?(view, "#link-offer")
      assert text(view, "#link-offer") =~ "Created #{@pattern_name}"
      assert text(view, "#link-offer") =~ "18 trips"
      assert text(view, "#link-offer") =~ "13 stops"
      assert text(view, "#link-offer") =~ "serve these same 13 stops in the same order"
      assert has_element?(view, "#link-open", "Link 18 trips")
      assert has_element?(view, "#link-dismiss", "Not now")
    end

    test "is offered on the Patterns list for the same pattern", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      scope = build_scenario(organization, version, "LNK2")
      path = create_pattern(conn, version, "LNK2", scope.stops)
      {:ok, view, _html} = live(conn, path)
      pattern_id = created_pattern_uuid(organization, "LNK2")

      # Patching to the list with the marker left on is the same LiveView
      # reaching its other surface, so the offer is the one the editor showed
      # rather than a second decision made per page.
      html = render_patch(view, "/gtfs/#{version.id}/routes/LNK2/patterns?link=#{pattern_id}")

      assert html =~ ~s(id="link-offer")
      assert text_in(html, "#link-offer") =~ "18 trips"
      assert html =~ ~s(id="link-open")
      assert html =~ "Link 18 trips"
    end

    test "is offered to no pattern whose stops the trips do not serve", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      scope = build_scenario(organization, version, "LNK3")
      # The short turn's first two stops are a real stop order no left-out group
      # serves, so a pattern over them has nothing to offer to link.
      unrelated = Enum.take(scope.stops, 2)

      path = create_pattern(conn, version, "LNK3", unrelated)
      {:ok, view, _html} = live(conn, path)

      refute has_element?(view, "#link-offer")
      refute has_element?(view, "#pattern-link-offer")
    end
  end

  describe "the review before a link" do
    test "lists the trips, the direction it writes and what changes", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      scope = build_scenario(organization, version, "LNK4")
      path = create_pattern(conn, version, "LNK4", scope.stops)
      {:ok, view, _html} = live(conn, path)

      render_click(view, "link_open")

      assert has_element?(view, "#link-review[data-open='true']")
      assert text(view, "#link-review") =~ "Link 18 trips to #{@pattern_name}?"
      assert text(view, "#link-review") =~ "in the same order, with no direction"
      assert text(view, "#link-review") =~ "Trips linked"
      assert text(view, "#link-review") =~ "18"
      assert text(view, "#link-review") =~ "New timings"
      assert text(view, "#link-review") =~ "New problems"
      assert has_element?(view, "#link-review-trips")
      assert text(view, "#link-review") =~ "None"
      assert text(view, "#link-review") =~ @service_description
      assert text(view, "#link-review") =~ "What changes"
      assert text(view, "#link-review") =~ "They keep their own times"
      assert text(view, "#link-review") =~ "Stops, headsigns and service days don’t change"
      # The safe answer is the one the dialog opens on, and it writes nothing.
      assert has_element?(view, "#link-review-cancel", "Keep trips separate")
      assert has_element?(view, "#link-review-confirm", "Link 18 trips")
    end

    test "writes nothing until the confirm is pressed", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      scope = build_scenario(organization, version, "LNK5")
      before = linkage(organization)
      path = create_pattern(conn, version, "LNK5", scope.stops)
      {:ok, view, _html} = live(conn, path)

      render_click(view, "link_open")
      render_click(view, "link_cancel")

      assert linkage(organization) == before
      refute has_element?(view, "#link-review[data-open='true']")
    end
  end

  describe "a confirmed link" do
    test "joins the 18 trips to the new pattern with a timing named after their service", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      scope = build_scenario(organization, version, "LNK6")
      path = create_pattern(conn, version, "LNK6", scope.stops)
      {:ok, view, _html} = live(conn, path)

      render_click(view, "link_open")
      render_click(view, "link_confirm")

      # The apply sends the pattern's own UUID as the target, so the trips join
      # the hand-made pattern rather than the saved one it duplicates. A trip's
      # own column carries the pattern's natural ID, which is what proves which
      # pattern took them.
      pattern_id = created_pattern_id(organization, "LNK6")
      pattern_uuid = created_pattern_uuid(organization, "LNK6")

      assert linked(organization, "full") == %{0 => @full_trips, :pattern_id => @full_trips}
      # The short order's trips were not in the confirmed group, so none of them
      # joined anything.
      assert linked(organization, "short") == %{0 => 0, :pattern_id => 0}
      assert trips_point_at(organization, "full", pattern_id)

      # Rule 6 named the new timing after the one service the trips run on.
      timings = timing_names(organization, pattern_uuid)

      assert @service_description in timings

      assert has_element?(view, "#link-done")
      assert text(view, "#link-done") =~ "Linked 18 trips to #{@pattern_name}"
      # The offer is gone: its trips are no longer left out.
      refute has_element?(view, "#link-offer")
    end

    test "is refused for an editor revoked after the offer opened and links nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      scope = build_scenario(organization, version, "LNK8")
      path = create_pattern(conn, version, "LNK8", scope.stops)
      {:ok, view, _html} = live(conn, path)
      before = linkage(organization)

      render_click(view, "link_open")

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      render_click(view, "link_confirm")

      assert text(view, "#link-review-error") =~ "You no longer have editor access"
      assert linkage(organization) == before
    end

    test "leaves the short order's trips as they are", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      scope = build_scenario(organization, version, "LNK7")
      path = create_pattern(conn, version, "LNK7", scope.stops)
      {:ok, view, _html} = live(conn, path)

      render_click(view, "link_open")
      render_click(view, "link_confirm")

      # Only the group whose stop order matched was confirmed, so the 6-trip
      # short order is still custom and undirected.
      assert directions(organization, "short") == %{nil => @short_trips}
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Stages each stop through the editor's own stop picker and then presses the
  # save bar's create action. A create answers with a `push_navigate`, so this
  # returns the path that navigate names rather than a view: the caller opens
  # it, which is what remounting the LiveView on the new pattern's own URL
  # means.
  defp create_pattern(conn, version, route_id, stop_ids) do
    view = elem(live(conn, "/gtfs/#{version.id}/routes/#{route_id}/patterns/new"), 1)

    Enum.each(stop_ids, fn stop_id ->
      render_change(view, "choose_stop", %{"stop_search" => %{"stop_id" => stop_id}})
    end)

    case render_click(view, "create_pattern", %{
           "pattern" => %{
             "name" => @pattern_name,
             "direction_id" => "0",
             "headsign" => "",
             "time_desc" => "",
             "typicality" => "0",
             "sort_order" => ""
           }
         }) do
      {:error, {:live_redirect, %{to: path}}} -> path
      _other -> flunk("creating a pattern should navigate to the new pattern")
    end
  end

  # The natural `route_pattern_id` is what a trip's own column carries once it
  # has joined a pattern.
  defp created_pattern_id(organization, route_id) do
    Repo.one!(
      from(p in GtfsPlanner.Gtfs.RoutePattern,
        where: p.organization_id == ^organization.id and p.route_id == ^route_id,
        select: p.route_pattern_id
      )
    )
  end

  # The UUID is what the offer's URL marker, a timing row and a confirmed target
  # all name; a trip's own column carries the natural ID instead.
  defp created_pattern_uuid(organization, route_id) do
    Repo.one!(
      from(p in GtfsPlanner.Gtfs.RoutePattern,
        where: p.organization_id == ^organization.id and p.route_id == ^route_id,
        select: p.id
      )
    )
  end

  defp trips_point_at(organization, label, route_pattern_id) do
    group_trips(organization, label)
    |> Enum.all?(&(&1.route_pattern_id == route_pattern_id))
  end

  defp text(view, selector), do: view |> render() |> text_in(selector)

  defp text_in(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Everything a refused or unconfirmed link must leave untouched.
  defp linkage(organization) do
    from(t in Trip, where: t.organization_id == ^organization.id)
    |> Repo.all()
    |> Enum.map(&{&1.trip_id, &1.direction_id, &1.route_pattern_id, &1.pattern_derivation_state})
    |> Enum.sort()
  end

  # The direction a group's trips ended up with and how many joined a pattern.
  defp linked(organization, label) do
    trips = group_trips(organization, label)

    linked_count = Enum.count(trips, &(&1.route_pattern_id != nil))

    %{
      0 => Enum.count(trips, &(&1.direction_id == 0)),
      pattern_id: linked_count
    }
  end

  defp directions(organization, label) do
    organization |> group_trips(label) |> Enum.map(& &1.direction_id) |> Enum.frequencies()
  end

  defp group_trips(organization, label) do
    prefix = "supplement_#{label}_%"

    Repo.all(
      from(t in Trip,
        where: t.organization_id == ^organization.id and like(t.trip_id, ^prefix)
      )
    )
  end

  defp timing_names(organization, route_pattern_uuid) do
    Repo.all(
      from(tp in GtfsPlanner.Gtfs.TimedPattern,
        where:
          tp.organization_id == ^organization.id and tp.route_pattern_id == ^route_pattern_uuid,
        select: tp.name
      )
    )
    |> Enum.sort()
  end

  # --- fixture ---------------------------------------------------------------
  # The scenario step 20's grouping review describes: 13 stops, one saved
  # 13-stop pattern in Direction 0, 18 direction-less trips over that same order
  # and 6 over its first six, all on one named service.
  defp build_scenario(organization, version, route_id) do
    org_id = organization.id
    version_id = version.id

    route_fixture(org_id, version_id, %{route_id: route_id, route_short_name: route_id})

    scope = insert_stops(org_id, version_id, route_id)

    calendar_attribute_fixture(org_id, version_id, %{
      service_id: @service,
      service_description: @service_description
    })

    insert_group(org_id, version_id, route_id, "full", scope.stops, @full_trips)

    short = Enum.take(scope.stops, @short_stop_count)
    insert_group(org_id, version_id, route_id, "short", short, @short_trips)

    scope
  end

  # Thirteen boarding stops on one meridian.
  defp insert_stops(org_id, version_id, route_id) do
    stops =
      for index <- 1..@stop_count do
        stop_fixture(org_id, version_id, %{
          stop_id: "#{route_id}_S#{index}",
          stop_name: "Line Stop #{index - 1}",
          location_type: 0,
          stop_lat: 44.0 + index * 0.001,
          stop_lon: -124.0
        }).stop_id
      end

    %{stops: stops}
  end

  defp insert_group(org_id, version_id, route_id, label, stop_ids, count) do
    band = if label == "full", do: 1, else: 2

    for index <- 1..count do
      trip_id = "supplement_#{label}_#{index}"

      org_id
      |> trip_fixture(version_id, route_id, %{
        trip_id: trip_id,
        service_id: @service,
        shape_id: "shape_#{label}"
      })
      |> trip_pattern_metadata_fixture(%{
        direction_id: nil,
        pattern_derivation_state: "custom",
        pattern_derivation_reason: "missing_direction"
      })

      insert_vector(org_id, version_id, trip_id, stop_ids, band)
    end
  end

  # One minute per stop, and a `stop_sequence` band per group, so the two stop
  # orders are two groups rather than one merged order.
  defp insert_vector(org_id, version_id, trip_id, stop_ids, band) do
    stop_ids
    |> Enum.with_index()
    |> Enum.each(fn {stop_id, index} ->
      minutes = 7 * 60 + index
      time = :io_lib.format("~2..0B:~2..0B:00", [div(minutes, 60), rem(minutes, 60)])

      insert_stop_time(
        org_id,
        version_id,
        trip_id,
        stop_id,
        band * 1000 + index + 1,
        to_string(time)
      )
    end)
  end

  defp insert_stop_time(org_id, version_id, trip_id, stop_id, sequence, time) do
    stop_time_fixture(org_id, version_id, trip_id, stop_id, %{
      stop_sequence: sequence,
      arrival_time: time,
      departure_time: time
    })
  end
end
