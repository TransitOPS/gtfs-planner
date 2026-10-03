defmodule GtfsPlannerWeb.Gtfs.EditorDeactivationLiveTest do
  @moduledoc """
  EV-19 / step 24: a membership deactivated after the page mounted is refused at
  the LiveView, and the write it tried to reach does not happen.

  Every case opens the ordinary page through the router as an active editor,
  deactivates that membership with the lifecycle column the application's own
  deactivation path sets (`deactivate_membership_fixture/1`), then sends the
  mutation event over the connected socket. The assertions read the stored rows
  after the event, so a refusal is observed as an absent write and not only as a
  rendered message.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "editor-deactivation-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{
        email: "editor-deactivation-#{System.unique_integer([:positive])}@example.com"
      })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  # The same lifecycle column the real deactivation path sets; the page is
  # already mounted when this runs.
  defp deactivate_membership!(user, organization) do
    Accounts.get_user_org_membership(user.id, organization.id)
    |> deactivate_membership_fixture()
  end

  defp route(organization, version, route_id, attrs \\ %{}) do
    route_fixture(
      organization.id,
      version.id,
      Map.merge(
        %{
          route_id: route_id,
          route_short_name: route_id,
          route_long_name: "#{route_id} corridor"
        },
        attrs
      )
    )
  end

  defp stop(organization, version, stop_id, attrs \\ %{}) do
    stop_fixture(
      organization.id,
      version.id,
      Map.merge(%{stop_id: stop_id, stop_name: stop_id}, attrs)
    )
  end

  defp coord_stop(organization, version, stop_id, name, lat, lon) do
    stop(organization, version, stop_id, %{
      stop_name: name,
      stop_lat: Decimal.new(lat),
      stop_lon: Decimal.new(lon)
    })
  end

  defp pattern(organization, version, route, route_pattern_id) do
    route_pattern_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      route_pattern_id: route_pattern_id,
      route_pattern_name: route_pattern_id,
      direction_id: 0
    })
  end

  defp occurrences(pattern, stop_ids) do
    stop_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)
  end

  defp timing(pattern, occurrence_rows, name, offsets) do
    timing = timed_pattern_fixture(pattern, %{name: name})

    occurrence_rows
    |> Enum.zip(offsets)
    |> Enum.each(fn {occurrence, {arrival, departure}} ->
      timed_pattern_stop_fixture(timing, occurrence, %{
        arrival_offset: arrival,
        departure_offset: departure
      })
    end)

    timing
  end

  # A route with three stops ordered across five typical offsets.
  defp three_stop_pattern(organization, version, route_id) do
    route = route(organization, version, route_id)
    stops = for index <- 1..3, do: stop(organization, version, "#{route_id}_S#{index}")
    pattern = pattern(organization, version, route, "P-#{route_id}")
    rows = occurrences(pattern, Enum.map(stops, & &1.stop_id))
    timing = timing(pattern, rows, "Weekday", [{0, 0}, {240, 300}, {600, 660}])

    %{route: route, stops: stops, pattern: pattern, occurrences: rows, timing: timing}
  end

  defp pattern_path(version, route, pattern, suffix) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}#{suffix}"
  end

  defp pattern_stops(pattern) do
    Repo.all(
      from(o in RoutePatternStop,
        where: o.route_pattern_id == ^pattern.id,
        order_by: o.position,
        select: {o.position, o.stop_id}
      )
    )
  end

  # --- paste page fixtures ---------------------------------------------------

  defp paste_path(version, route, query \\ %{}) do
    path = "/gtfs/#{version.id}/routes/#{route.route_id}/schedules/paste"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  # The client follows one server patch. `render_patch/2` re-renders the view at
  # the path and leaves its own patch message in the mailbox.
  defp follow(view, path) do
    html = render_patch(view, path)
    assert_patched(view, path)
    html
  end

  defp weekly_calendar(organization, version, service_id, name) do
    calendar_fixture(organization.id, version.id, %{service_id: service_id})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name,
      service_schedule_name: name
    })

    service_id
  end

  # One Weekday outbound trip on a zero-dwell Main pattern, so pasting one row
  # of matching offsets is a single Add change.
  defp paste_route(%{organization: organization, version: version}) do
    route = route(organization, version, "DEACT")
    weekday = weekly_calendar(organization, version, "DEACT_WKD", "Weekday")

    Enum.each(1..3, fn index ->
      stop(organization, version, "DEACT_S#{index}", %{stop_name: "Deactivation Stop #{index}"})
    end)

    main =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "DEACT-MAIN",
        route_pattern_name: "Main",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"DEACT_S1", 0, 0, 1},
          {"DEACT_S2", 300, 300, 1},
          {"DEACT_S3", 600, 600, 1}
        ]
      })

    schedule_trip_fixture(organization.id, version.id, route.route_id, main, %{
      service_id: weekday,
      trip_id: "DEACT_T0800",
      trip_short_name: "1209",
      start_time: "08:00:00"
    })

    %{route: route, service_id: weekday, main: main}
  end

  defp open_paste(view, version, %{route: route, service_id: service_id, main: main}) do
    follow(
      view,
      paste_path(version, route, %{
        "service_id" => service_id,
        "direction" => "0",
        "pattern" => main.pattern.id
      })
    )
  end

  defp read_paste(view) do
    render_submit(view, "read", %{
      "paste" => %{
        "text" =>
          "Deactivation Stop 1\tDeactivation Stop 2\tDeactivation Stop 3\n09:00\t09:05\t09:10",
        "layout" => "auto",
        "header" => "true"
      }
    })
  end

  defp service_trip_count(organization, version, service_id) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^organization.id and
            t.gtfs_version_id == ^version.id and t.service_id == ^service_id
      ),
      :count
    )
  end

  # --- alignment fixtures ----------------------------------------------------

  defp alignment_base_stops(organization, version) do
    coord_stop(organization, version, "S1", "Stop One", "40.712800", "-74.006000")
    coord_stop(organization, version, "S2", "Stop Two", "40.713800", "-74.005000")
  end

  defp section_at(pattern, position) do
    pattern
    |> Alignments.resolve()
    |> Map.fetch!(:sections)
    |> Enum.find(&(&1.position == position))
  end

  defp set_entry(section, points) do
    %{
      "position" => section.position,
      "from_occurrence_id" => section.from_occurrence_id,
      "to_stop_id" => section.to_stop_id,
      "op" => "set",
      "points" => points,
      "base" => %{
        "segment_id" => section.revision.segment_id,
        "lock_version" => section.revision.lock_version
      }
    }
  end

  defp alignment_segments_count(organization, version) do
    Repo.aggregate(
      from(s in AlignmentSegment,
        where: s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id
      ),
      :count
    )
  end

  defp alignment_shape_count(organization, version) do
    Repo.aggregate(
      from(s in Shape,
        where: s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id
      ),
      :count
    )
  end

  describe "timetable paste" do
    setup :editor_scope

    test "a member deactivated after mount is refused and no trip is added",
         %{conn: conn} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(context.version, paste.route))
      open_paste(view, context.version, paste)
      read_paste(view)

      assert has_element?(view, "#paste-apply", "Apply 1 change")
      assert service_trip_count(context.organization, context.version, paste.service_id) == 1

      deactivate_membership!(context.user, context.organization)

      render_click(view, "paste_apply")
      refute_redirected(view)

      assert has_element?(view, "#paste-notice-permission")
      assert service_trip_count(context.organization, context.version, paste.service_id) == 1
      assert Repo.get_by(Trip, trip_id: "DEACT-0-DEACT_WKD-0900") == nil
    end

    test "an active editor's paste still applies", %{conn: conn} = context do
      paste = paste_route(context)

      {:ok, view, _html} = live(conn, paste_path(context.version, paste.route))
      open_paste(view, context.version, paste)
      read_paste(view)

      assert has_element?(view, "#paste-apply", "Apply 1 change")

      redirect = render_click(view, "paste_apply")

      assert {:error, {:live_redirect, %{to: to}}} = redirect
      assert to =~ "/gtfs/#{context.version.id}/routes/#{paste.route.route_id}/schedules"
      assert to =~ "service_id=#{paste.service_id}"

      assert service_trip_count(context.organization, context.version, paste.service_id) == 2

      assert %Trip{} = Repo.get_by(Trip, trip_id: "DEACT-0-DEACT_WKD-0900")
    end
  end

  describe "route schedules" do
    setup :editor_scope

    test "a member deactivated after mount cannot reactivate the route",
         %{conn: conn} = context do
      route = route(context.organization, context.version, "DEACT_INACT", %{active: false})

      {:ok, view, _html} =
        live(conn, "/gtfs/#{context.version.id}/routes/#{route.route_id}/schedules")

      assert has_element?(view, "#route-reactivate", "Reactivate route")

      deactivate_membership!(context.user, context.organization)

      view |> element("#route-reactivate") |> render_click()

      assert has_element?(view, "#route-inactive-banner")
      assert has_element?(view, "#flash-error", "no longer have editor access")
      refute Repo.get!(Route, route.id).active
    end
  end

  describe "route pattern stops" do
    setup :editor_scope

    test "a member deactivated after mount cannot save staged stop changes",
         %{conn: conn} = context do
      %{route: route, pattern: pattern} =
        three_stop_pattern(context.organization, context.version, "DEACT_PAT")

      before = pattern_stops(pattern)
      assert length(before) == 3

      {:ok, view, _html} =
        live(conn, pattern_path(context.version, route, pattern, "?task=stops"))

      deactivate_membership!(context.user, context.organization)

      render_click(view, "remove_stop", %{"index" => "3"})
      render_click(view, "save_stops")

      assert has_element?(view, "#pattern-editor-revoked")
      assert pattern_stops(pattern) == before
    end
  end

  describe "pattern alignment" do
    setup :editor_scope

    test "a member deactivated after mount cannot save an alignment draft",
         %{conn: conn} = context do
      alignment_base_stops(context.organization, context.version)
      route = route(context.organization, context.version, "DEACT_ALIGN")
      pattern = pattern(context.organization, context.version, route, "P-DEACT-ALIGN")
      occurrences(pattern, ["S1", "S2"])

      {:ok, view, _html} =
        live(conn, pattern_path(context.version, route, pattern, "?task=alignment"))

      deactivate_membership!(context.user, context.organization)

      draft = [set_entry(section_at(Repo.reload!(pattern), 1), [[-74.005500, 40.713100]])]
      render_hook(view, "alignment_save_requested", %{"sections" => draft})

      assert has_element?(view, "#pattern-editor-revoked")
      assert has_element?(view, "#alignment-save-notice", "Your draft is still here")
      assert alignment_segments_count(context.organization, context.version) == 0
      assert alignment_shape_count(context.organization, context.version) == 0
    end
  end
end
