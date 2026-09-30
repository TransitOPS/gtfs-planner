defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesEstimatesTest do
  # EV-15: custom trips preview the export estimate read-only in Schedules.
  #
  # Estimated cells render in italics with a title and legend, the note above
  # the table names the trips with blanks, not-estimable trips keep their
  # blanks with the reason, linked trips and estimation-off show stored values
  # only, and nothing writes the stored stop times.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "schedules-est-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "schedules-est-#{System.unique_integer([:positive])}@example.com"})

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

  defp schedules_path(version, route, query \\ %{}) do
    path = "/gtfs/#{version.id}/routes/#{route.route_id}/schedules"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  # One direction-0 pattern with three stops, one linked trip with full times,
  # one custom trip estimable from its first and last times, and one custom
  # trip with no time at its last stop.
  defp estimate_route(%{organization: organization, version: version}) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "EST1",
        route_short_name: "E1",
        route_long_name: "Estimates One"
      })

    calendar_fixture(organization.id, version.id, %{service_id: "EST_WKD"})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "EST_WKD",
      service_description: "Weekday",
      service_schedule_name: "Weekday"
    })

    for {stop_id, name} <- [{"EST_S1", "First"}, {"EST_S2", "Middle"}, {"EST_S3", "Last"}] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: name})
    end

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "EST-P1",
        route_pattern_name: "Downtown",
        timing_name: "Standard",
        stops: [
          {"EST_S1", 0, 0, 1},
          {"EST_S2", 300, 300, 0},
          {"EST_S3", 600, 600, 1}
        ]
      })

    schedule_trip_fixture(organization.id, version.id, route.route_id, bundle, %{
      service_id: "EST_WKD",
      trip_id: "EST_LINKED",
      start_time: "07:00:00"
    })

    schedule_trip_fixture(organization.id, version.id, route.route_id, bundle, %{
      service_id: "EST_WKD",
      trip_id: "EST_FILL",
      state: "custom",
      timed_pattern_id: nil,
      stop_times: [
        {"EST_S1", "08:00:00", "08:00:00"},
        {"EST_S2", nil, nil},
        {"EST_S3", "08:10:00", "08:10:00"}
      ]
    })

    schedule_trip_fixture(organization.id, version.id, route.route_id, bundle, %{
      service_id: "EST_WKD",
      trip_id: "EST_NOLAST",
      state: "custom",
      timed_pattern_id: nil,
      stop_times: [
        {"EST_S1", "09:00:00", "09:00:00"},
        {"EST_S2", nil, nil},
        {"EST_S3", nil, nil}
      ]
    })

    %{route: route, bundle: bundle}
  end

  defp stored_pairs(organization, version) do
    from(st in StopTime,
      where: st.organization_id == ^organization.id and st.gtfs_version_id == ^version.id,
      order_by: [asc: st.trip_id, asc: st.stop_sequence],
      select: {st.trip_id, st.arrival_time, st.departure_time}
    )
    |> Repo.all()
  end

  describe "schedules estimate preview" do
    setup [:editor_scope, :estimate_route]

    test "renders estimated cells, note and legend without writing stop times", %{
      conn: conn,
      organization: organization,
      version: version,
      route: route
    } do
      before = stored_pairs(organization, version)
      assert {"EST_FILL", "08:00:00", "08:00:00"} in before
      assert {"EST_FILL", nil, nil} in before

      # The estimate cell only renders for a visible estimated stop, so mount
      # with every stop shown (the deterministic QA tour prescribes ?stops=all
      # for this surface).
      {:ok, view, _html} = live(conn, schedules_path(version, route, %{"stops" => "all"}))

      assert has_element?(view, "#trip-EST_FILL")
      assert has_element?(view, "#trip-EST_NOLAST")

      html = render(view)

      # The filled middle cell carries the export estimate (600 s across one
      # blank stop with no distances falls back to an even share: 08:05).
      assert html =~ "Estimated when exported: 08:05. Not saved in this trip."
      assert html =~ "italic tabular-nums text-cyan-800"

      # The note above the table names both trips with blanks and links out.
      assert has_element?(
               view,
               "#section-EST-P1-estimate-note",
               "2 trips have missing times"
             )

      assert html =~ "Exports estimate them by distance along the path."

      assert has_element?(
               view,
               "#section-EST-P1-estimate-note a",
               "Export defaults"
             )

      # The footer legend explains the italics; the reason badge names the
      # trip that cannot be estimated.
      assert has_element?(view, "#section-EST-P1-estimate-legend", "estimated when exported")

      assert has_element?(
               view,
               "#trip-EST_NOLAST-estimate-problem",
               "No time at last stop"
             )

      # Stored values stay stored: the linked trip shows its own times with no
      # estimate marking, and there is no bulk save action (spec 18 owns it).
      refute has_element?(view, "#trip-EST_LINKED-estimate-problem")
      refute html =~ "Save estimates"

      # Mount changed nothing on disk, and navigating the same page (timepoints
      # to all stops) changes nothing either.
      assert stored_pairs(organization, version) == before

      render_patch(view, schedules_path(version, route, %{"stops" => "all"}))
      assert_patched(view, schedules_path(version, route, %{"stops" => "all"}))
      assert stored_pairs(organization, version) == before
    end

    test "estimation off renders stored values only", %{
      conn: conn,
      organization: organization,
      version: version,
      route: route
    } do
      {:ok, _} = ExportDefaults.update(organization.id, %{estimate_missing_times: false})

      {:ok, view, _html} = live(conn, schedules_path(version, route))
      html = render(view)

      assert has_element?(view, "#trip-EST_FILL")
      refute html =~ "Estimated when exported"
      refute has_element?(view, "#section-EST-P1-estimate-legend")
      refute has_element?(view, "#trip-EST_NOLAST-estimate-problem")

      # The blank middle cell still shows the stored blank.
      assert html =~ "—"
    end
  end
end
