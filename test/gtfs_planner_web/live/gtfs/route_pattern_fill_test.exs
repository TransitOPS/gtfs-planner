# Step 12 LiveView test: fill state machine in Running times (spec
# 23-stop-time-interpolation, EV-12; AC-22, AC-23). Mounted through the
# authenticated router with the real Gtfs facade; linked trips' stop times are
# re-selected with independent Repo queries after the review applies.
defmodule GtfsPlannerWeb.Gtfs.RoutePatternFillTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "route-pattern-fill-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "pattern-fill-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp route(organization, version, route_id) do
    route_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_short_name: route_id,
      route_long_name: "#{route_id} corridor"
    })
  end

  defp stop(organization, version, route_id, index, lat) do
    stop_fixture(organization.id, version.id, %{
      stop_id: "#{route_id}_S#{index}",
      stop_name: "#{route_id} Stop #{index}",
      stop_lat: lat,
      stop_lon: "-74.0",
      location_type: 0
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

  defp occurrences(pattern, stops) do
    stops
    |> Enum.with_index(1)
    |> Enum.map(fn {stop, position} ->
      route_pattern_stop_fixture(pattern, stop.stop_id, position)
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

  defp linked_trip(organization, version, route, pattern, timing, trip_id, stops, times) do
    trip = trip_fixture(organization.id, version.id, route.route_id, %{trip_id: trip_id})

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing && timing.id,
      pattern_derivation_state: "linked",
      pattern_derivation_reason: nil
    })

    stops
    |> Enum.zip(times)
    |> Enum.with_index(1)
    |> Enum.each(fn {{stop, {arrival, departure}}, sequence} ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, stop.stop_id, %{
        stop_sequence: sequence,
        arrival_time: arrival,
        departure_time: departure
      })
    end)

    trip
  end

  # Three stops on a straight north-south line, so distance fill splits the
  # 0→600 s span into an exact 300 s half for the middle stop.
  defp three_stop_pattern(
         organization,
         version,
         route_id,
         offsets \\ [{0, 0}, {300, 300}, {600, 660}]
       ) do
    route = route(organization, version, route_id)

    stops = [
      stop(organization, version, route_id, 1, "40.0"),
      stop(organization, version, route_id, 2, "40.005"),
      stop(organization, version, route_id, 3, "40.01")
    ]

    pattern = pattern(organization, version, route, "P-#{route_id}")
    occurrence_rows = occurrences(pattern, stops)
    timing_row = timing(pattern, occurrence_rows, "Weekday", offsets)

    %{route: route, stops: stops, pattern: pattern, timing: timing_row}
  end

  defp used_pattern(organization, version, route_id) do
    # The stored middle offset (04:00) deliberately differs from the distance
    # fill estimate (05:00): a submitted vector that matches the stored timing
    # row-for-row is a no-op by design, so the save only reaches linked trips
    # when the applied estimate is a genuine change.
    context =
      three_stop_pattern(organization, version, route_id, [{0, 0}, {240, 240}, {600, 660}])

    trip =
      linked_trip(
        organization,
        version,
        context.route,
        context.pattern,
        context.timing,
        "#{route_id}_T1",
        context.stops,
        [
          {"08:00:00", "08:00:00"},
          {nil, nil},
          {"08:10:00", "08:11:00"}
        ]
      )

    Map.put(context, :trip, trip)
  end

  defp pattern_path(version, route, pattern) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=timings"
  end

  defp set_timepoints(timing, values) do
    timing
    |> timing_rows()
    |> Enum.zip(values)
    |> Enum.each(fn {row, value} ->
      row |> Ecto.Changeset.change(timepoint: value) |> Repo.update!()
    end)
  end

  defp timing_rows(timing) do
    Repo.all(
      from(r in TimedPatternStop,
        join: o in RoutePatternStop,
        on: o.id == r.route_pattern_stop_id,
        where: r.timed_pattern_id == ^timing.id,
        order_by: o.position
      )
    )
  end

  defp trip_clocks(trip) do
    Repo.all(from(st in StopTime, where: st.trip_id == ^trip.trip_id, order_by: st.stop_sequence))
    |> Enum.map(&{&1.arrival_time, &1.departure_time, &1.timepoint})
  end

  defp change_timing(view, position, field, value, extra \\ %{}) do
    render_change(view, "validate_timing_row", %{
      "timing" => %{Integer.to_string(position) => Map.merge(%{field => value}, extra)},
      "_target" => ["timing", Integer.to_string(position), field]
    })
  end

  defp blank_middle(view) do
    change_timing(view, 2, "arrival", "")
    change_timing(view, 2, "departure", "")
  end

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "fill panel" do
    setup :editor_scope

    test "opening fill shows the panel with scope :missing and hides the save bar", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern, timing: timing} =
        three_stop_pattern(org, version, "FILL1")

      set_timepoints(timing, [1, 0, 1])
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern))
      blank_middle(view)
      assert has_element?(view, "#pattern-save-bar")

      render_click(view, "open_fill")

      assert has_element?(view, "#fill-panel")
      assert has_element?(view, "#fill-title")
      assert has_element?(view, "#fill-scope-missing[checked]")
      assert has_element?(view, "#fill-method-distance[checked]")
      assert has_element?(view, "#fill-summary", "Fills 1 stop")
      assert has_element?(view, "#fill-apply", "Fill 1 stop")
      refute has_element?(view, "#pattern-save-bar")
      assert has_element?(view, "#timing-select[disabled]")
      assert has_element?(view, "#timing-add[disabled]")
      assert has_element?(view, "#timing-rename[disabled]")
      assert has_element?(view, "#timing-delete[disabled]")
    end

    test "changing scope and method recomputes the preview", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern, timing: timing} =
        three_stop_pattern(org, version, "FILL2")

      set_timepoints(timing, [1, 0, 1])
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern))
      blank_middle(view)
      render_click(view, "open_fill")
      assert has_element?(view, "#fill-summary", "Fills 1 stop")

      render_change(view, "change_fill", %{"scope" => "between", "method" => "even"})

      assert has_element?(view, "#fill-scope-between[checked]")
      assert has_element?(view, "#fill-method-even[checked]")
      assert has_element?(view, "#fill-summary", "Recalculates")
    end

    test "applying fill stages estimates and saving writes them to linked trips", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern, timing: timing, trip: trip} =
        used_pattern(org, version, "FILL3")

      set_timepoints(timing, [1, 0, 1])
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern))
      blank_middle(view)
      render_click(view, "open_fill")
      render_click(view, "apply_fill")

      assert has_element?(view, "#timing-arrival-2[value='05:00']")
      assert has_element?(view, "#timing-departure-2[value='05:00']")
      assert has_element?(view, "#timing-arrival-2[data-estimated]")
      refute has_element?(view, "#fill-panel")

      render_click(view, "save_timing")
      assert has_element?(view, "#timing-review-dialog")

      render_click(view, "apply_timing_review")

      assert [
               {"08:00:00", "08:00:00", _},
               {"08:05:00", "08:05:00", 0},
               {"08:10:00", "08:11:00", _}
             ] = trip_clocks(trip)

      assert render(view) =~ "trips updated"
    end

    test "a manual change to an estimated row clears its estimated mark", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern, timing: timing} =
        three_stop_pattern(org, version, "FILL4")

      set_timepoints(timing, [1, 0, 1])
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern))
      blank_middle(view)
      render_click(view, "open_fill")
      render_click(view, "apply_fill")
      assert has_element?(view, "#timing-arrival-2[data-estimated]")

      change_timing(view, 2, "arrival", "06:00")

      assert has_element?(view, "#timing-arrival-2[value='06:00']")
      refute has_element?(view, "#timing-arrival-2[data-estimated]")
    end

    test "cancel leaves the staged edits unchanged", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern, timing: timing} =
        three_stop_pattern(org, version, "FILL5")

      set_timepoints(timing, [1, 0, 1])
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern))
      blank_middle(view)
      render_click(view, "open_fill")
      assert has_element?(view, "#fill-panel")

      render_click(view, "cancel_fill")

      refute has_element?(view, "#fill-panel")
      assert view |> element("#timing-arrival-2") |> render() =~ ~s(value="")
      assert view |> element("#timing-departure-2") |> render() =~ ~s(value="")
      assert live_assigns(view).fill == nil
    end

    test "distances load with Running times and stay put across row changes", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern} = three_stop_pattern(org, version, "FILL6")
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern))

      distances = live_assigns(view).fill_distances
      assert length(distances) == 3
      assert Enum.all?(distances, &is_number/1)

      change_timing(view, 2, "departure", "06:00")
      change_timing(view, 2, "departure", "05:30")
      change_timing(view, 3, "arrival", "09:00")

      assert live_assigns(view).fill_distances == distances
    end

    test "moving a timepoint shows the re-estimate prompt with a limited preview", %{
      conn: conn,
      organization: org,
      version: version
    } do
      route = route(org, version, "FILL7")

      stops = [
        stop(org, version, "FILL7", 1, "40.0"),
        stop(org, version, "FILL7", 2, "40.005"),
        stop(org, version, "FILL7", 3, "40.01"),
        stop(org, version, "FILL7", 4, "40.015")
      ]

      pattern = pattern(org, version, route, "P-FILL7")
      occurrence_rows = occurrences(pattern, stops)

      timing =
        timing(pattern, occurrence_rows, "Weekday", [
          {0, 0},
          {300, 300},
          {450, 450},
          {900, 960}
        ])

      set_timepoints(timing, [1, 1, 0, 1])
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern))

      change_timing(view, 2, "departure", "07:00", %{"timepoint" => "1"})

      assert has_element?(view, "#timing-retime", "Stop 2 moved by 02:00 later")
      assert has_element?(view, "#timing-retime", "1 stop would move")

      render_click(view, "reestimate", %{"anchor" => "2"})

      assert has_element?(view, "#fill-panel")
      assert has_element?(view, "#fill-scope-between[checked]")
      refute has_element?(view, "#timing-retime")
      assert live_assigns(view).fill.only_anchor == 1
    end

    test "saving with only blank errors names the count and offers fill", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern, timing: timing} =
        three_stop_pattern(org, version, "FILL8")

      set_timepoints(timing, [1, 0, 1])
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern))
      blank_middle(view)

      render_click(view, "save_timing")

      assert has_element?(
               view,
               "#timing-blank-note",
               "1 stop needs times before you can save."
             )

      assert has_element?(view, "#timing-blank-fill")

      render_click(view, "open_fill")
      assert has_element?(view, "#fill-panel")
    end

    test "the fill method follows the organization export defaults", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern, timing: timing} =
        three_stop_pattern(org, version, "FILL9")

      set_timepoints(timing, [1, 0, 1])
      {:ok, _} = ExportDefaults.update(org.id, %{estimate_method: :even})
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern))
      blank_middle(view)

      render_click(view, "open_fill")

      assert has_element?(view, "#fill-method-even[checked]")
    end
  end
end
