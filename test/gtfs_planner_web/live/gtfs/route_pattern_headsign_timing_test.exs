defmodule GtfsPlannerWeb.Gtfs.RoutePatternHeadsignTimingTest do
  @moduledoc """
  LiveView coverage for the Running-times timing headsign disclosure (EV-13):
  the closed summary and the opened usage line, the headsign-only save that
  opens no timing review dialog and re-materializes no stop times, clearing a
  timing's own headsign onto the pattern's, the Undo fence on the timing
  scope, the row edit that still opens the review dialog, and the timing
  scope's review drawer.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Repo

  setup %{conn: conn} do
    organization =
      organization_fixture(%{
        alias: "headsign-timing-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{email: "headsign-timing-#{System.unique_integer([:positive])}@example.com"})

    {:ok, _membership} =
      GtfsPlanner.Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  # The disclosure's staged shape: pattern headsign "Lincoln City", one
  # "Weekday" timing with no own headsign, and five linked trips on it — three
  # followers, one likely typo, one differing value. Every trip carries a stop
  # time row, so a save that re-materialized them would move `updated_at`.
  defp lincoln_timing(organization, version, pattern_id) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "HS_#{pattern_id}",
        route_short_name: "HS",
        route_long_name: "Headsign corridor"
      })

    stops = Enum.map(1..2, &stop(organization, version, "HS_#{pattern_id}", &1))

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: pattern_id,
        route_pattern_name: "Lincoln runs",
        headsign: "Lincoln City",
        direction_id: 0
      })

    occurrences =
      stops
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, position} ->
        route_pattern_stop_fixture(pattern, stop.stop_id, position)
      end)

    timing = timed_pattern_fixture(pattern, %{name: "Weekday"})

    Enum.each(occurrences, fn occurrence ->
      timed_pattern_stop_fixture(timing, occurrence, %{
        arrival_offset: 0,
        departure_offset: 0
      })
    end)

    trips =
      [
        {"T1", "Lincoln City"},
        {"T2", "Lincoln City"},
        {"T3", "Lincoln City"},
        {"T4", "Lincoln city"},
        {"T5", "Roads End via Lincoln City"}
      ]
      |> Enum.map(fn {suffix, headsign} ->
        linked_trip(
          organization,
          version,
          route,
          pattern,
          timing,
          "#{pattern_id}_#{suffix}",
          stops,
          headsign: headsign
        )
      end)

    %{
      route: route,
      pattern: pattern,
      timing: timing,
      follower_trips: Enum.take(trips, 3),
      typo_trip: Enum.at(trips, 3),
      other_trip: Enum.at(trips, 4)
    }
  end

  # The card's School days timing: its own headsign over two trips that show it.
  defp school_timing(organization, version, pattern_id) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "HS_#{pattern_id}",
        route_short_name: "HS",
        route_long_name: "Headsign corridor"
      })

    stops = Enum.map(1..2, &stop(organization, version, "HS_#{pattern_id}", &1))

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: pattern_id,
        route_pattern_name: "School runs",
        headsign: "Lincoln City",
        direction_id: 0
      })

    occurrences =
      stops
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, position} ->
        route_pattern_stop_fixture(pattern, stop.stop_id, position)
      end)

    timing =
      timed_pattern_fixture(pattern, %{
        name: "School days",
        headsign: "Lincoln City via Taft High"
      })

    Enum.each(occurrences, fn occurrence ->
      timed_pattern_stop_fixture(timing, occurrence, %{
        arrival_offset: 0,
        departure_offset: 0
      })
    end)

    trips =
      Enum.map(1..2, fn index ->
        linked_trip(
          organization,
          version,
          route,
          pattern,
          timing,
          "#{pattern_id}_T#{index}",
          stops,
          headsign: "Lincoln City via Taft High"
        )
      end)

    %{route: route, pattern: pattern, timing: timing, trips: trips}
  end

  defp linked_trip(organization, version, route, pattern, timing, trip_id, stops, attrs) do
    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: trip_id,
        trip_headsign: attrs[:headsign],
        direction_id: 0
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked",
      direction_id: 0
    })

    Enum.with_index(stops, 1)
    |> Enum.each(fn {stop, sequence} ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, stop.stop_id, %{
        stop_sequence: sequence,
        arrival_time: "08:0#{sequence - 1}:00",
        departure_time: "08:0#{sequence - 1}:00"
      })
    end)

    trip
  end

  defp stop(organization, version, route_id, index) do
    stop_fixture(organization.id, version.id, %{
      stop_id: "#{route_id}_S#{index}",
      stop_name: "Stop #{index}",
      location_type: 0
    })
  end

  defp timings_path(version, route, pattern) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=timings"
  end

  defp edit_timing_headsign(view, value) do
    render_change(view, "validate_timing_row", %{
      "timing_headsign" => value,
      "_target" => ["timing_headsign"]
    })
  end

  defp trip_headsigns(trips) do
    trips
    |> Enum.map(&Repo.reload!(&1).trip_headsign)
    |> Enum.frequencies()
  end

  defp stop_time_stamps(trips) do
    trip_ids = Enum.map(trips, & &1.trip_id)

    StopTime
    |> where([st], st.trip_id in ^trip_ids)
    |> select([st], {st.id, st.updated_at})
    |> Repo.all()
    |> Enum.sort()
  end

  defp open_disclosure(view) do
    render_click(element(view, "#timing-headsign-summary"))
  end

  describe "the timing headsign disclosure" do
    test "the closed summary names the pattern's value and opening shows the timing's usage",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_timing(organization, version, "HS-TDISC")

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      assert has_element?(view, "#timing-headsign-summary", "Headsign:")
      assert has_element?(view, "#timing-headsign-summary", "Lincoln City")
      assert has_element?(view, "#timing-headsign-summary", "from the pattern")
      assert has_element?(view, "#timing-headsign-summary", "Change")
      assert has_element?(view, "#timing-headsign-summary", "2 of 5 trips differ")
      refute has_element?(view, "#timing-headsign-disclosure[open]")

      open_disclosure(view)

      assert has_element?(view, "#timing-headsign-disclosure[open]")
      refute has_element?(view, "#timing-headsign-summary", "this timing’s own")
      assert has_element?(view, "#timing-headsign[value='']")
      assert has_element?(view, "#timing-headsign-form", "Headsign for Weekday (optional)")

      assert has_element?(
               view,
               "#timing-headsign-help",
               "Leave blank to use the pattern’s headsign, Lincoln City"
             )

      assert has_element?(view, "#timing-headsign-usage", "Used by 5 trips")
      assert has_element?(view, "#timing-headsign-usage", "2 show a different headsign")
      assert has_element?(view, "#timing-headsign-usage-review", "Review 2 trips")

      # Closing the disclosure again hides the field.
      open_disclosure(view)

      refute has_element?(view, "#timing-headsign-disclosure[open]")
    end

    test "editing stages the update box and the Save headsign bar",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_timing(organization, version, "HS-TBOX")

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      open_disclosure(view)
      edit_timing_headsign(view, "Lincoln City via Taft High")

      assert has_element?(
               view,
               "#timing-headsign-update-box",
               "Also update 3 trips that show Lincoln City"
             )

      assert has_element?(view, "#timing-headsign-update-toggle[checked]")
      assert has_element?(view, "#pattern-save-bar #timing-save", "Save headsign")
      assert has_element?(view, "#pattern-save-status", "Saving updates 3 trips")
      refute has_element?(view, "#timing-headsign-usage")

      # Returning the field to the stored value brings the usage line and the
      # usage line's save label back — the staged edit entry itself survives
      # (the timing editor's key-based dirtiness, like its row cells), so the
      # bar keeps offering the padded save.
      edit_timing_headsign(view, "Lincoln City")

      assert has_element?(view, "#timing-headsign-usage", "Used by 5 trips")
      refute has_element?(view, "#timing-headsign-update-box")
    end
  end

  describe "saving" do
    test "a headsign-only save writes the trips without the dialog and leaves stop times alone",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_timing(organization, version, "HS-TSAVE")
      trips = context.follower_trips ++ [context.typo_trip, context.other_trip]
      stamps_before = stop_time_stamps(trips)

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      open_disclosure(view)
      edit_timing_headsign(view, "Lincoln City via Taft High")

      render_click(view, "save_timing")

      refute has_element?(view, "#timing-review-dialog[data-open='true']")
      assert trip_headsigns(context.follower_trips) == %{"Lincoln City via Taft High" => 3}
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln city"
      assert Repo.reload!(context.other_trip).trip_headsign == "Roads End via Lincoln City"
      assert stop_time_stamps(trips) == stamps_before

      # The reload after the save names the timing's own value now.
      assert has_element?(view, "#timing-headsign-summary", "Lincoln City via Taft High")
      assert has_element?(view, "#timing-headsign-summary", "this timing’s own")

      assert has_element?(view, "#headsign-result", "Headsign saved · 3 trips updated")
      assert has_element?(view, "#headsign-result", "3 trips now show Lincoln City via Taft High")
      assert has_element?(view, "#headsign-result", "2 trips show a different headsign.")
      assert has_element?(view, "#headsign-undo", "Undo headsign change")
      assert has_element?(view, "#pattern-save-status", "3 trips updated")
      assert has_element?(view, "#timing-headsign-usage", "2 show a different headsign")
    end

    test "clearing a timing's own headsign gives its trips the pattern's",
         %{conn: conn, organization: organization, version: version} do
      context = school_timing(organization, version, "HS-TOWN")

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      assert has_element?(view, "#timing-headsign-summary", "Lincoln City via Taft High")
      assert has_element?(view, "#timing-headsign-summary", "this timing’s own")

      open_disclosure(view)
      edit_timing_headsign(view, "")

      assert has_element?(
               view,
               "#timing-headsign-update-box",
               "Also update 2 trips that show Lincoln City via Taft High"
             )

      # A blank timing value still means the pattern's headsign, so the box
      # starts checked and the save writes it.
      assert has_element?(view, "#timing-headsign-update-toggle[checked]")

      render_click(view, "save_timing")

      refute has_element?(view, "#timing-review-dialog[data-open='true']")
      assert Repo.reload!(context.timing).headsign == nil
      assert trip_headsigns(context.trips) == %{"Lincoln City" => 2}

      assert has_element?(view, "#timing-headsign-summary", "Lincoln City")
      assert has_element?(view, "#timing-headsign-summary", "from the pattern")
      assert has_element?(view, "#timing-headsign-usage", "Used by 2 trips")
      assert has_element?(view, "#timing-headsign-usage", "all show this headsign")
    end
  end

  describe "undo" do
    test "undo restores the timing's own headsign and its trips",
         %{conn: conn, organization: organization, version: version} do
      context = school_timing(organization, version, "HS-TUNDO")

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      open_disclosure(view)
      edit_timing_headsign(view, "")
      render_click(view, "save_timing")

      assert trip_headsigns(context.trips) == %{"Lincoln City" => 2}

      render_click(element(view, "#headsign-undo"))

      assert Repo.reload!(context.timing).headsign == "Lincoln City via Taft High"

      assert trip_headsigns(context.trips) == %{"Lincoln City via Taft High" => 2}

      assert has_element?(view, "#pattern-save-status", "Headsign change undone")

      assert has_element?(
               view,
               "#pattern-save-status",
               "The timing’s headsign is Lincoln City via Taft High again"
             )

      refute has_element?(view, "#headsign-result")

      assert has_element?(view, "#timing-headsign-summary", "Lincoln City via Taft High")
      assert has_element?(view, "#timing-headsign-summary", "this timing’s own")
      assert has_element?(view, "#timing-headsign-usage", "all show this headsign")
    end
  end

  describe "row edits" do
    test "a row time edit still opens the timing review dialog",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_timing(organization, version, "HS-TROW")

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      render_change(view, "validate_timing_row", %{
        "timing" => %{"2" => %{"arrival" => "04:00", "departure" => "06:00"}},
        "_target" => ["timing", "2", "departure"]
      })

      render_click(view, "save_timing")

      assert has_element?(view, "#timing-review-dialog[data-open='true']")
      assert has_element?(view, "#timing-review-dialog-title", "Update 5 trips?")

      render_click(element(view, "#timing-review-dialog-confirm"))

      refute has_element?(view, "#timing-review-dialog[data-open='true']")
      assert has_element?(view, "#pattern-save-status", "5 trips updated")
      assert has_element?(view, "#timing-headsign-summary", "from the pattern")
    end
  end

  describe "the timing scope review drawer" do
    test "the usage line's drawer fixes a typo inside the timing's scope",
         %{conn: conn, organization: organization, version: version} do
      context = lincoln_timing(organization, version, "HS-TDRAW")

      {:ok, view, _html} = live(conn, timings_path(version, context.route, context.pattern))

      open_disclosure(view)
      html = render_click(element(view, "#timing-headsign-usage-review"))
      assert html =~ "Loading trips…"

      render_async(view)

      assert has_element?(view, "#headsign-review-drawer", "Trips with a different headsign")
      assert has_element?(view, "#headsign-review-drawer", "Weekday timing")
      assert has_element?(view, "#headsign-review-drawer", "3 of 5 trips show")
      assert has_element?(view, "#headsign-review-drawer", "Lincoln city")
      assert has_element?(view, "#headsign-review-drawer", "Likely typo")

      # Escape hands focus back to the timing usage line's opener; the test
      # dispatches the event the key and the header close button both reach.
      render_click(view, "close_drawer", %{})

      refute has_element?(view, "#headsign-review-drawer")

      render_click(element(view, "#timing-headsign-usage-review"))
      render_async(view)

      render_click(view, "select_headsign_typos")

      assert has_element?(view, "#headsign-review-drawer-apply", "Change 1 trip to Lincoln City")

      render_click(element(view, "#headsign-review-drawer-apply"))

      assert has_element?(view, "#headsign-review-drawer-done", "1 trip now shows Lincoln City")
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln City"

      # CR-6: the write reloaded the timing usage behind the drawer.
      assert has_element?(view, "#timing-headsign-usage", "1 shows a different headsign")

      render_click(element(view, "#headsign-review-drawer-undo"))

      refute has_element?(view, "#headsign-review-drawer")
      assert Repo.reload!(context.typo_trip).trip_headsign == "Lincoln city"

      assert has_element?(view, "#timing-headsign-usage", "2 show a different headsign")
    end
  end
end
