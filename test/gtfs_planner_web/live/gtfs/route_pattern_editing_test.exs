defmodule GtfsPlannerWeb.Gtfs.RoutePatternEditingTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "route-pattern-editing-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "pattern-editing-#{System.unique_integer([:positive])}@example.com"})

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

  defp stop(organization, version, route_id, index, name \\ nil) do
    stop_fixture(organization.id, version.id, %{
      stop_id: "#{route_id}_S#{index}",
      stop_name: name || "#{route_id} Stop #{index}",
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
      pattern_derivation_state: if(timing, do: "linked", else: "custom"),
      pattern_derivation_reason: if(timing, do: nil, else: "missing_times")
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

  # A route with three stops ordered across five typical offsets.
  defp three_stop_pattern(
         organization,
         version,
         route_id,
         offsets \\ [{0, 0}, {240, 300}, {600, 660}]
       ) do
    route = route(organization, version, route_id)
    stops = for index <- 1..3, do: stop(organization, version, route_id, index)
    pattern = pattern(organization, version, route, "P-#{route_id}")
    occurrence_rows = occurrences(pattern, stops)
    timing_row = timing(pattern, occurrence_rows, "Weekday", offsets)

    %{
      route: route,
      stops: stops,
      pattern: pattern,
      occurrences: occurrence_rows,
      timing: timing_row
    }
  end

  # The same pattern with one linked trip whose stop times match the offsets.
  defp used_pattern(organization, version, route_id) do
    context = three_stop_pattern(organization, version, route_id)

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
          {"08:04:00", "08:05:00"},
          {"08:10:00", "08:11:00"}
        ]
      )

    Map.put(context, :trip, trip)
  end

  defp pattern_path(version, route, pattern, suffix) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}#{suffix}"
  end

  defp occurrence_rows(pattern) do
    Repo.all(
      from(o in RoutePatternStop, where: o.route_pattern_id == ^pattern.id, order_by: o.position)
    )
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
    |> Enum.map(&{&1.stop_id, &1.stop_sequence, &1.arrival_time, &1.departure_time})
  end

  defp arrival_clocks(trip), do: trip_clocks(trip) |> Enum.map(&elem(&1, 2))

  defp trip_timepoints(trip) do
    Repo.all(
      from(st in StopTime,
        where: st.trip_id == ^trip.trip_id,
        order_by: st.stop_sequence,
        select: st.timepoint
      )
    )
  end

  defp timepoints(timing), do: timing |> timing_rows() |> Enum.map(& &1.timepoint)

  # Writes stored timepoints row by row, as an import or an earlier save leaves them.
  defp set_timepoints(timing, values) do
    timing
    |> timing_rows()
    |> Enum.zip(values)
    |> Enum.each(fn {row, value} ->
      row |> Ecto.Changeset.change(timepoint: value) |> Repo.update!()
    end)
  end

  # Edits one control through the rendered timing form, so the change event carries
  # every row's current values exactly as a browser posts them. A checkbox takes
  # its value "1"; a form cannot untick one, so that test posts the row itself.
  defp edit_timing_field(view, position, field, value) do
    position = Integer.to_string(position)

    view
    |> form("#timing-edit-form", %{"timing" => %{position => %{field => value}}})
    |> render_change(%{"_target" => ["timing", position, field]})
  end

  # The test database can hold change logs this case did not create, so the count
  # covers only the case's organization.
  defp audit_count(organization) do
    Repo.aggregate(from(l in ChangeLog, where: l.organization_id == ^organization.id), :count)
  end

  # The timing editor posts one form, so a change carries the whole row map and
  # names the changed control in `_target`.
  defp change_timing(view, position, field, value) do
    render_change(view, "validate_timing_row", %{
      "timing" => %{Integer.to_string(position) => %{field => value}},
      "_target" => ["timing", Integer.to_string(position), field]
    })
  end

  defp set_review_values(view, timing_id, key, values) do
    render_change(view, "update_review_value", %{
      "review" => %{timing_id => %{key => values}},
      "_target" => ["review", timing_id, key, "arrival"]
    })
  end

  # Types into the review dialog through its real form: the element is located
  # in the DOM, its rendered input values are collected, and only the edited
  # fields are overridden, exactly as a browser change event does.
  defp fill_review_values(view, timing_id, key, values) do
    view
    |> form("#stop-review-values-form")
    |> render_change(%{
      "review" => %{timing_id => %{key => values}},
      "_target" => ["review", timing_id, key, "arrival"]
    })
  end

  describe "final conflict and draft regressions" do
    setup :editor_scope

    test "rename preserves timing drafts and structural save requires explicit discard", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern} = three_stop_pattern(org, version, "DRAFT2")
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern, "?task=timings"))
      change_timing(view, 2, "departure", "06:00")
      render_click(view, "open_timing_dialog", %{"mode" => "rename"})
      render_change(view, "validate_timing_dialog", %{"name" => "Renamed"})
      render_click(view, "confirm_timing_dialog")
      assert has_element?(view, "#timing-departure-2[value='06:00']")
      render_click(view, "switch_task", %{"task" => "stops"})
      render_click(view, "save_stops")
      render_click(view, "switch_task", %{"task" => "timings"})
      assert has_element?(view, "#timing-departure-2[value='06:00']")
      render_click(view, "switch_task", %{"task" => "stops"})
      render_click(view, "remove_stop", %{"index" => "3"})
      render_click(view, "save_stops")
      assert has_element?(view, "#error", "Save your timing edits")
      assert length(occurrence_rows(pattern)) == 3
      view |> element("#discard-timing-drafts") |> render_click()
      render_click(view, "save_stops")
      assert length(occurrence_rows(pattern)) == 2
      refute has_element?(view, "#edit-status", "Unsaved changes")
    end

    test "stale copy and delete events preserve the session instead of nesting callback tuples",
         %{conn: conn, organization: org, version: version} do
      %{route: route, pattern: pattern} = three_stop_pattern(org, version, "ERROR2")
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern, "?task=stops"))
      render_click(view, "open_delete_pattern")
      pattern |> Ecto.Changeset.change(route_pattern_name: "Concurrent") |> Repo.update!()
      render_click(view, "confirm_delete_pattern")
      assert has_element?(view, "#error", "changed since")
      render_click(view, "copy_pattern")
      assert has_element?(view, "#error", "changed since")
      render_click(view, "open_delete_pattern")
      assert has_element?(view, "#error", "changed since")
      assert Repo.get!(RoutePattern, pattern.id)
    end

    test "stale timing before review has refresh recovery and invalid text identifies its row", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern} = used_pattern(org, version, "EARLY2")
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern, "?task=timings"))
      change_timing(view, 2, "arrival", "bogus")
      render_click(view, "save_timing")
      assert has_element?(view, "#timing-arrival-2[aria-invalid='true']")
      change_timing(view, 2, "arrival", "04:30")
      pattern |> Ecto.Changeset.change(route_pattern_name: "Concurrent") |> Repo.update!()
      render_click(view, "save_timing")
      assert has_element?(view, "#timing-review-refresh")
      view |> element("#timing-review-refresh") |> render_click()
      refute has_element?(view, "#timing-review-dialog-confirm[disabled]")
      view |> element("#timing-review-dialog-confirm") |> render_click()
      assert has_element?(view, "#status", "1 trips updated")
    end

    test "details stale before review and before apply can refresh without losing input", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern} = used_pattern(org, version, "DETAIL2")
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern, "?task=details"))
      pattern |> Ecto.Changeset.change(route_pattern_name: "Concurrent") |> Repo.update!()

      view
      |> form("#pattern-details-form", pattern: %{name: "My draft", direction_id: "1"})
      |> render_submit()

      assert has_element?(view, "#details-refresh-review")
      view |> element("#details-refresh-review") |> render_click()
      assert has_element?(view, "#pattern-details-name[value='My draft']")

      Repo.get!(RoutePattern, pattern.id)
      |> Ecto.Changeset.change(route_pattern_sort_order: 99)
      |> Repo.update!()

      render_click(view, "apply_details_review")
      assert has_element?(view, "#details-refresh-review")
      view |> element("#details-refresh-review") |> render_click()
      render_click(view, "apply_details_review")
      assert Repo.get!(RoutePattern, pattern.id).route_pattern_name == "My draft"
      log = Repo.one!(from l in ChangeLog, where: l.entity_id == ^pattern.id)
      assert log.changed_fields["affected_trips"] == %{"from" => nil, "to" => 1}
    end

    test "remove-first insertion edits use the old origin and invalid explicit input blocks apply",
         %{conn: conn, organization: org, version: version} do
      %{route: route, pattern: pattern, timing: timing, trip: trip} =
        used_pattern(org, version, "ORIGIN2")

      extra = stop(org, version, "ORIGIN2", 99, "Inserted")
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern, "?task=stops"))
      render_click(view, "remove_stop", %{"index" => "1"})

      render_change(view, "live_select_change", %{
        "id" => "pattern-stop-search",
        "text" => "Inserted"
      })

      render_change(view, "set_insert_after", %{"insert" => %{"insert_after" => "1"}})
      render_change(view, "choose_stop", %{"stop_search" => %{"stop_id" => extra.stop_id}})
      render_click(view, "save_stops")
      assert has_element?(view, "#stop-review-value-#{timing.id}-new-1-arrival[value='07:30']")
      fill_review_values(view, timing.id, "new-1", %{"arrival" => "oops", "departure" => "08:00"})
      assert has_element?(view, "#stop-review-dialog-confirm[disabled]")
      fill_review_values(view, timing.id, "new-1", %{"arrival" => "07:30", "departure" => ""})
      assert has_element?(view, "#stop-review-dialog-confirm[disabled]")

      fill_review_values(view, timing.id, "new-1", %{"arrival" => "07:30", "departure" => "08:00"})

      render_click(view, "acknowledge_review_timing", %{"timing_id" => timing.id})
      render_click(view, "apply_stop_review")
      assert arrival_clocks(trip) == ["08:04:00", "08:07:30", "08:10:00"]
    end

    test "switching versions from a pattern opens the new version Patterns tab", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern} = three_stop_pattern(org, version, "VERSION2")
      other = gtfs_version_fixture(org.id)
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern, "?task=timings"))
      render_click(view, "switch_gtfs_version", %{"version" => other.id})
      assert_redirect(view, "/gtfs/#{other.id}/routes/#{route.route_id}/patterns")
    end

    test "build errors remain visible when no pattern exists", %{
      conn: conn,
      organization: org,
      version: version
    } do
      route = route(org, version, "BUILD2")

      route
      |> Ecto.Changeset.change(pattern_derivation_error: "stop_times_unreadable")
      |> Repo.update!()

      {:ok, view, _} = live(conn, "/gtfs/#{version.id}/routes/#{route.route_id}/patterns")
      assert has_element?(view, "#patterns-derivation-error", "stop_times_unreadable")
      assert has_element?(view, "#patterns-build-error-retry")
    end

    test "prepend may repeat the nonadjacent last stop", %{
      conn: conn,
      organization: org,
      version: version
    } do
      %{route: route, pattern: pattern, stops: stops} = three_stop_pattern(org, version, "LOOP2")
      last = List.last(stops)
      {:ok, view, _} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_change(view, "live_select_change", %{
        "id" => "pattern-stop-search",
        "text" => last.stop_id
      })

      render_change(view, "set_insert_after", %{"insert" => %{"insert_after" => "-1"}})
      render_change(view, "choose_stop", %{"stop_search" => %{"stop_id" => last.stop_id}})
      assert has_element?(view, "#pattern-stop-1", last.stop_name)
      assert has_element?(view, "#pattern-stop-4", last.stop_name)
    end
  end

  describe "stop search" do
    setup :editor_scope

    test "search is scoped to the version, ordered by name/ID and capped at 20 matches",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "SEARCH1")

      for index <- 1..24 do
        stop(
          organization,
          version,
          "SEARCH1",
          index,
          "Search #{String.pad_leading(Integer.to_string(index), 2, "0")}"
        )
      end

      stop_fixture(organization.id, version.id, %{
        stop_id: "SEARCH1_STATION",
        stop_name: "Search Station",
        location_type: 1
      })

      other_version = gtfs_version_fixture(organization.id)

      stop_fixture(organization.id, other_version.id, %{
        stop_id: "SEARCH1_FOREIGN",
        stop_name: "Search Foreign",
        location_type: 0
      })

      pattern = pattern(organization, version, route, "P-SEARCH1")

      occurrence_rows =
        occurrences(pattern, [
          stop(organization, version, "SEARCH1", 90),
          stop(organization, version, "SEARCH1", 91)
        ])

      timing(pattern, occurrence_rows, "Timing A", [{0, 0}, {0, 0}])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_change(view, "live_select_change", %{
        "id" => "pattern-stop-search",
        "text" => "Search"
      })

      assert has_element?(view, "#pattern-stop-search-status", "20 matches")
      assert has_element?(view, "#pattern-stop-search-hint", "Refine")
      assert has_element?(view, "#pattern-stop-option-SEARCH1_S1", "Search 01")
      assert has_element?(view, "#pattern-stop-option-SEARCH1_S1", "SEARCH1_S1")
      assert has_element?(view, "#pattern-stop-option-SEARCH1_S20")
      refute has_element?(view, "#pattern-stop-option-SEARCH1_S21")
      refute has_element?(view, "#pattern-stop-option-SEARCH1_STATION")
      refute has_element?(view, "#pattern-stop-option-SEARCH1_FOREIGN")
    end

    test "search reports no matches without offering an unrelated stop",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern} =
        three_stop_pattern(organization, version, "SEARCH2", [{0, 0}, {0, 0}, {0, 0}])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_change(view, "live_select_change", %{
        "id" => "pattern-stop-search",
        "text" => "Nowhere at all"
      })

      assert has_element?(view, "#pattern-stop-search-status", "No stops match")
      refute has_element?(view, "#pattern-stop-option-SEARCH2_S1")
    end
  end

  describe "editing the stop list" do
    setup :editor_scope

    test "an unused pattern reorders and removes stops, saving the occurrence order",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, stops: stops, pattern: pattern} =
        three_stop_pattern(organization, version, "EDIT1", [{0, 0}, {0, 0}, {0, 0}])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      assert has_element?(view, "#pattern-stops[data-dirty='false']")

      render_click(view, "move_stop", %{"index" => "2", "direction" => "-1"})

      assert_push_event(view, "route_pattern_focus", %{id: "pattern-stop-1"})
      assert has_element?(view, "#pattern-stop-1", "EDIT1 Stop 2")
      assert has_element?(view, "#pattern-stop-2", "EDIT1 Stop 1")
      assert has_element?(view, "#pattern-stops[data-dirty='true']")

      render_click(view, "remove_stop", %{"index" => "3"})
      refute has_element?(view, "#pattern-stop-3")

      render_click(view, "save_stops")

      refute has_element?(view, "#stop-review-dialog[data-open='true']")
      assert has_element?(view, "#status", "Changes saved in this version")

      assert occurrence_rows(pattern) |> Enum.map(& &1.stop_id) == [
               Enum.at(stops, 1).stop_id,
               Enum.at(stops, 0).stop_id
             ]

      assert audit_count(organization) == 1
    end

    test "an unused pattern with real times reorders after the proposed times are acknowledged",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, stops: stops, pattern: pattern, occurrences: [first, second, third]} =
        timed =
        three_stop_pattern(organization, version, "EDIT1T", [{0, 0}, {300, 360}, {900, 900}])

      set_timepoints(timed.timing, [1, 0, 1])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_click(view, "move_stop", %{"index" => "2", "direction" => "-1"})
      render_click(view, "save_stops")

      assert has_element?(view, "#stop-review-dialog[data-open='true']")
      assert has_element?(view, "#stop-review-reorder-note", "keeps its times by position")
      assert has_element?(view, "#stop-review-resequenced-#{timed.timing.id}-#{second.id}")
      assert has_element?(view, "#stop-review-resequenced-#{timed.timing.id}-#{first.id}")
      refute has_element?(view, "#stop-review-resequenced-#{timed.timing.id}-#{third.id}")
      assert has_element?(view, "#stop-review-dialog-confirm[disabled]")
      assert occurrence_rows(pattern) |> Enum.map(& &1.id) == [first.id, second.id, third.id]
      assert audit_count(organization) == 0

      render_click(view, "acknowledge_review_timing", %{"timing_id" => timed.timing.id})
      refute has_element?(view, "#stop-review-dialog-confirm[disabled]")

      render_click(view, "apply_stop_review")

      refute has_element?(view, "#stop-review-dialog[data-open='true']")
      assert has_element?(view, "#status", "Changes saved in this version")

      assert occurrence_rows(pattern) |> Enum.map(& &1.stop_id) == [
               Enum.at(stops, 1).stop_id,
               Enum.at(stops, 0).stop_id,
               Enum.at(stops, 2).stop_id
             ]

      assert timing_rows(timed.timing)
             |> Enum.map(&{&1.route_pattern_stop_id, &1.arrival_offset, &1.departure_offset}) == [
               {second.id, 0, 0},
               {first.id, 300, 360},
               {third.id, 900, 900}
             ]

      assert timepoints(timed.timing) == [0, 1, 1]
    end

    test "a stop list shorter than two stops is refused without writing",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern} =
        three_stop_pattern(organization, version, "EDIT2", [{0, 0}, {0, 0}, {0, 0}])

      original = Enum.map(occurrence_rows(pattern), &{&1.id, &1.position})

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_click(view, "remove_stop", %{"index" => "2"})
      render_click(view, "remove_stop", %{"index" => "2"})
      render_click(view, "save_stops")

      assert has_element?(view, "#error", "at least two stops")
      assert Enum.map(occurrence_rows(pattern), &{&1.id, &1.position}) == original
      assert audit_count(organization) == 0
    end

    test "an added interior stop is estimated, acknowledged per timing and retains retained clocks",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "EDIT3")
      stops = for index <- 1..3, do: stop(organization, version, "EDIT3", index)
      pattern = pattern(organization, version, route, "P-EDIT3")
      occurrence_rows = occurrences(pattern, stops)
      first_timing = timing(pattern, occurrence_rows, "Weekday", [{0, 0}, {240, 300}, {600, 660}])
      other_timing = timing(pattern, occurrence_rows, "Weekend", [{0, 0}, {300, 360}, {720, 780}])

      trip =
        linked_trip(organization, version, route, pattern, first_timing, "EDIT3_T1", stops, [
          {"08:00:00", "08:00:00"},
          {"08:04:00", "08:05:00"},
          {"08:10:00", "08:11:00"}
        ])

      extra = stop(organization, version, "EDIT3", 99, "EDIT3 Inserted")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_change(view, "live_select_change", %{
        "id" => "pattern-stop-search",
        "text" => "Inserted"
      })

      render_change(view, "set_insert_after", %{"insert" => %{"insert_after" => "1"}})
      render_change(view, "choose_stop", %{"stop_search" => %{"stop_id" => extra.stop_id}})

      assert has_element?(view, "#pattern-stop-2", "EDIT3 Inserted")
      assert has_element?(view, "#pattern-stops[data-dirty='true']")

      render_click(view, "save_stops")

      assert has_element?(view, "#stop-review-dialog[data-open='true']")
      assert has_element?(view, "#stop-review-dialog-title", "Update 1 trip?")
      assert has_element?(view, "#stop-review-timing-#{first_timing.id}")
      assert has_element?(view, "#stop-review-timing-#{other_timing.id}")
      assert has_element?(view, "#stop-review-dialog-body", "a published version")
      assert has_element?(view, "#stop-review-dialog-confirm[disabled]")

      render_click(view, "acknowledge_review_timing", %{"timing_id" => first_timing.id})
      assert has_element?(view, "#stop-review-dialog-confirm[disabled]")

      render_click(view, "acknowledge_review_timing", %{"timing_id" => other_timing.id})
      refute has_element?(view, "#stop-review-dialog-confirm[disabled]")

      render_click(view, "apply_stop_review")

      refute has_element?(view, "#stop-review-dialog[data-open='true']")
      assert has_element?(view, "#status", "1 trips updated")

      assert occurrence_rows(pattern) |> Enum.map(& &1.stop_id) == [
               Enum.at(stops, 0).stop_id,
               extra.stop_id,
               Enum.at(stops, 1).stop_id,
               Enum.at(stops, 2).stop_id
             ]

      assert trip_clocks(trip) == [
               {Enum.at(stops, 0).stop_id, 1, "08:00:00", "08:00:00"},
               {extra.stop_id, 2, "08:02:00", "08:02:00"},
               {Enum.at(stops, 1).stop_id, 3, "08:04:00", "08:05:00"},
               {Enum.at(stops, 2).stop_id, 4, "08:10:00", "08:11:00"}
             ]

      assert timing_rows(other_timing) |> Enum.map(&{&1.arrival_offset, &1.departure_offset}) == [
               {0, 0},
               {150, 150},
               {300, 360},
               {720, 780}
             ]
    end

    test "changing a reviewed added value invalidates the acknowledgement and the fingerprint",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, timing: timing_row, trip: trip} =
        used_pattern(organization, version, "EDIT4")

      extra = stop(organization, version, "EDIT4", 99, "EDIT4 Inserted")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_change(view, "live_select_change", %{
        "id" => "pattern-stop-search",
        "text" => "Inserted"
      })

      render_change(view, "set_insert_after", %{"insert" => %{"insert_after" => "1"}})
      render_change(view, "choose_stop", %{"stop_search" => %{"stop_id" => extra.stop_id}})
      render_click(view, "save_stops")

      render_click(view, "acknowledge_review_timing", %{"timing_id" => timing_row.id})
      refute has_element?(view, "#stop-review-dialog-confirm[disabled]")

      set_review_values(view, timing_row.id, "new-1", %{"arrival" => "03:00"})

      set_review_values(view, timing_row.id, "new-1", %{
        "arrival" => "03:00",
        "departure" => "03:00"
      })

      assert has_element?(view, "#stop-review-ack-#{timing_row.id}[data-acknowledged='false']")
      assert has_element?(view, "#stop-review-dialog-confirm[disabled]")

      render_click(view, "apply_stop_review")
      assert arrival_clocks(trip) == ["08:00:00", "08:04:00", "08:10:00"]

      render_click(view, "acknowledge_review_timing", %{"timing_id" => timing_row.id})
      render_click(view, "apply_stop_review")

      assert arrival_clocks(trip) == ["08:00:00", "08:03:00", "08:04:00", "08:10:00"]
    end

    test "a cancelled stop review writes nothing and keeps the staged order",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, trip: trip} = used_pattern(organization, version, "EDIT5")

      original = Enum.map(occurrence_rows(pattern), & &1.id)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_click(view, "remove_stop", %{"index" => "3"})
      render_click(view, "save_stops")

      assert has_element?(view, "#stop-review-dialog[data-open='true']")
      render_click(view, "cancel_review")

      refute has_element?(view, "#stop-review-dialog[data-open='true']")
      assert Enum.map(occurrence_rows(pattern), & &1.id) == original
      assert arrival_clocks(trip) == ["08:00:00", "08:04:00", "08:10:00"]
      assert audit_count(organization) == 0
      # The staged edit survives the cancellation, so the editor keeps its work.
      refute has_element?(view, "#pattern-stop-3")
      assert has_element?(view, "#pattern-stops[data-dirty='true']")
    end

    test "removing the first stop rebases the trip start and keeps retained clock times",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, stops: stops, pattern: pattern, timing: timing_row, trip: trip} =
        used_pattern(organization, version, "EDIT8")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_click(view, "remove_stop", %{"index" => "1"})
      render_click(view, "save_stops")

      assert has_element?(view, "#stop-review-dialog[data-open='true']")
      assert has_element?(view, "#stop-review-dialog-title", "Update 1 trip?")
      assert has_element?(view, "#stop-review-dialog-body", "start shifts by 05:00")
      # A removal adds no stop values, so no acknowledgement is required.
      refute has_element?(view, "#stop-review-dialog-confirm[disabled]")

      render_click(view, "apply_stop_review")

      assert has_element?(view, "#status", "1 trips updated")

      assert occurrence_rows(pattern) |> Enum.map(& &1.stop_id) == [
               Enum.at(stops, 1).stop_id,
               Enum.at(stops, 2).stop_id
             ]

      # The retained absolute clocks do not move; the trip start shifts from
      # 08:00 to the new first departure at 08:05.
      assert trip_clocks(trip) == [
               {Enum.at(stops, 1).stop_id, 1, "08:04:00", "08:05:00"},
               {Enum.at(stops, 2).stop_id, 2, "08:10:00", "08:11:00"}
             ]

      assert timing_rows(timing_row) |> Enum.map(&{&1.arrival_offset, &1.departure_offset}) == [
               {-60, 0},
               {300, 360}
             ]
    end

    test "a used pattern refuses reordering and custom trips block the stop list",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, stops: stops, pattern: pattern} =
        used_pattern(organization, version, "EDIT6")

      _custom =
        linked_trip(organization, version, route, pattern, nil, "EDIT6_C1", stops, [
          {"07:00:00", "07:00:00"},
          {"07:04:00", "07:05:00"},
          {"07:10:00", "07:11:00"}
        ])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      assert has_element?(
               view,
               "#pattern-stops-custom",
               "keep the stop times they were imported with"
             )

      assert has_element?(view, "#pattern-stops-custom", "Copy the pattern")
      assert has_element?(view, "#pattern-remove-stop-1[disabled]")
      refute has_element?(view, "#pattern-stop-2-move-up")

      render_click(view, "move_stop", %{"index" => "2", "direction" => "-1"})
      assert has_element?(view, "#error", "Copy the pattern")
      assert has_element?(view, "#pattern-stop-1", "EDIT6 Stop 1")

      render_click(view, "remove_stop", %{"index" => "3"})
      assert has_element?(view, "#error", "keep their imported stop times")
      assert length(occurrence_rows(pattern)) == 3
      assert audit_count(organization) == 0
    end

    test "an added stop on an unused pattern is reviewed without an Update trips confirmation",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "EDIT7")
      stops = for index <- 1..2, do: stop(organization, version, "EDIT7", index)
      pattern = pattern(organization, version, route, "P-EDIT7")
      occurrence_rows = occurrences(pattern, stops)
      timing_row = timing(pattern, occurrence_rows, "Timing A", [{0, 0}, {60, 60}])
      extra = stop(organization, version, "EDIT7", 99, "EDIT7 Last")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_change(view, "live_select_change", %{"id" => "pattern-stop-search", "text" => "Last"})

      render_change(view, "set_insert_after", %{"insert" => %{"insert_after" => "1"}})
      render_change(view, "choose_stop", %{"stop_search" => %{"stop_id" => extra.stop_id}})
      render_click(view, "save_stops")

      refute has_element?(view, "#stop-review-dialog[data-open='true']")
      assert has_element?(view, "#status", "Changes saved in this version")
      assert length(occurrence_rows(pattern)) == 3

      assert timing_rows(timing_row) |> Enum.map(& &1.arrival_offset) == [0, 30, 60]
    end
  end

  describe "editing timings" do
    setup :editor_scope

    test "elapsed inputs round-trip and the signed first arrival is labelled",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern} =
        three_stop_pattern(organization, version, "TIME1", [{-60, 0}, {240, 300}, {600, 660}])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      assert has_element?(view, "#timing-arrival-1[value='-01:00']")
      assert has_element?(view, "#timing-departure-1[value='00:00']")
      assert has_element?(view, "#timing-arrival-2[value='04:00']")
      assert has_element?(view, "#timing-row-1", "Arrival relative to first departure")
      assert has_element?(view, "#timing-origin", "Times are measured from the first departure")
      assert has_element?(view, "#timing-row-2", "Timepoint")
      assert has_element?(view, "#timing-boarding-2", "Boarding")
      assert has_element?(view, "#timing-pickup-2")
      assert has_element?(view, "#timing-dropoff-2")
      assert has_element?(view, "#timing-stop-headsign-2")
      assert has_element?(view, "#timing-headsign")
      assert has_element?(view, "#timing-help", "Phone the agency")
    end

    test "attribute disclosures retain values across timing selection and validation errors",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, occurrences: occurrence_rows, timing: first} =
        three_stop_pattern(organization, version, "TIME2", [{0, 0}, {60, 60}, {120, 120}])

      second = timing(pattern, occurrence_rows, "Weekend", [{0, 0}, {90, 90}, {180, 180}])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      change_timing(view, 2, "pickup", "2")

      change_timing(view, 2, "headsign", "Downtown only")

      render_change(view, "select_timing", %{"timing_id" => second.id})
      render_change(view, "select_timing", %{"timing_id" => first.id})

      assert has_element?(view, "#timing-pickup-2", "Phone the agency")
      assert has_element?(view, "#timing-stop-headsign-2[value='Downtown only']")

      change_timing(view, 1, "departure", "01:00")

      render_click(view, "save_timing")

      assert has_element?(view, "#error", "first departure")
      assert has_element?(view, "#timing-departure-1[aria-invalid='true']")
      assert_push_event(view, "focus_form_error", %{form_id: "timing-form"})
      assert has_element?(view, "#timing-pickup-2", "Phone the agency")
      assert audit_count(organization) == 0
      assert timing_rows(first) |> Enum.map(& &1.departure_offset) == [0, 60, 120]
    end

    test "chronology is validated before any write",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, timing: timing_row} =
        three_stop_pattern(organization, version, "TIME3")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      change_timing(view, 2, "arrival", "-06:00")

      render_click(view, "save_timing")

      assert has_element?(view, "#error", "previous departure")
      assert audit_count(organization) == 0
      assert timing_rows(timing_row) |> Enum.map(& &1.arrival_offset) == [0, 240, 600]

      change_timing(view, 2, "arrival", "04:00")

      change_timing(view, 2, "departure", "03:00")

      render_click(view, "save_timing")

      assert has_element?(view, "#error", "Departure must be at or after arrival")
      assert audit_count(organization) == 0
    end

    test "a timing save updates exactly its linked trips from their existing first departure",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "TIME4")
      stops = for index <- 1..3, do: stop(organization, version, "TIME4", index)
      pattern = pattern(organization, version, route, "P-TIME4")
      occurrence_rows = occurrences(pattern, stops)
      first = timing(pattern, occurrence_rows, "Weekday", [{0, 0}, {240, 300}, {600, 660}])
      other = timing(pattern, occurrence_rows, "Weekend", [{0, 0}, {300, 360}, {720, 780}])

      first_trip =
        linked_trip(organization, version, route, pattern, first, "TIME4_T1", stops, [
          {"08:00:00", "08:00:00"},
          {"08:04:00", "08:05:00"},
          {"08:10:00", "08:11:00"}
        ])

      second_trip =
        linked_trip(organization, version, route, pattern, other, "TIME4_T2", stops, [
          {"09:00:00", "09:00:00"},
          {"09:05:00", "09:06:00"},
          {"09:12:00", "09:13:00"}
        ])

      custom =
        linked_trip(organization, version, route, pattern, nil, "TIME4_T3", stops, [
          {"07:00:00", "07:00:00"},
          {"07:07:00", "07:08:00"},
          {"07:15:00", "07:16:00"}
        ])

      second_before = Enum.map(timing_rows(other), & &1.id)
      custom_before = trip_clocks(custom)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      change_timing(view, 2, "departure", "06:00")

      render_change(view, "preview_timing", %{"preview_time" => "25:00"})
      assert has_element?(view, "#timing-preview-1", "01:00 +1 day")

      render_change(view, "preview_timing", %{"preview_time" => "08:00"})
      assert has_element?(view, "#timing-preview-1", "08:00")
      assert has_element?(view, "#timing-preview-3", "08:10")

      render_click(view, "save_timing")

      assert has_element?(view, "#timing-review-dialog[data-open='true']")
      assert has_element?(view, "#timing-review-dialog-title", "Update 1 trip?")

      render_click(view, "apply_timing_review")

      refute has_element?(view, "#timing-review-dialog[data-open='true']")
      assert has_element?(view, "#status", "1 trips updated")

      assert trip_clocks(first_trip) == [
               {Enum.at(stops, 0).stop_id, 1, "08:00:00", "08:00:00"},
               {Enum.at(stops, 1).stop_id, 2, "08:04:00", "08:06:00"},
               {Enum.at(stops, 2).stop_id, 3, "08:10:00", "08:11:00"}
             ]

      assert Enum.map(timing_rows(other), & &1.id) == second_before
      assert arrival_clocks(second_trip) == ["09:00:00", "09:05:00", "09:12:00"]
      assert trip_clocks(custom) == custom_before
    end

    test "a timing save keeps another task's staged stops and another timing's draft",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, occurrences: occurrence_rows, timing: first} =
        three_stop_pattern(organization, version, "SAVE9", [{0, 0}, {240, 300}, {600, 660}])

      second = timing(pattern, occurrence_rows, "Weekend", [{0, 0}, {300, 360}, {720, 780}])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      # A staged stop removal on the Stops task, then a draft on the other timing.
      render_click(view, "remove_stop", %{"index" => "3"})
      render_click(view, "switch_task", %{"task" => "timings"})

      render_change(view, "select_timing", %{"timing_id" => second.id})
      change_timing(view, 2, "departure", "06:00")
      assert has_element?(view, "#timing-departure-2[value='06:00']")

      # Saving the selected timing clears only that timing's draft.
      render_change(view, "select_timing", %{"timing_id" => first.id})
      change_timing(view, 2, "departure", "06:00")
      render_click(view, "save_timing")

      assert audit_count(organization) == 1
      assert has_element?(view, "#status", "Changes saved in this version.")

      render_click(view, "switch_task", %{"task" => "stops"})
      refute has_element?(view, "#pattern-stop-3")
      assert has_element?(view, "#pattern-stops[data-dirty='true']")

      render_click(view, "switch_task", %{"task" => "timings"})
      render_change(view, "select_timing", %{"timing_id" => second.id})
      assert has_element?(view, "#timing-departure-2[value='06:00']")
    end

    test "timings can be added from a copy or blank, renamed, and deletion blocks a used or last timing",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, timing: first} =
        used_pattern(organization, version, "TIME5")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      render_click(view, "open_timing_dialog", %{"mode" => "add"})
      assert has_element?(view, "#timing-dialog[data-open='true']")

      render_change(view, "validate_timing_dialog", %{
        "name" => "Weekend",
        "source_timing_id" => first.id
      })

      render_click(view, "confirm_timing_dialog")

      copied = Repo.get_by!(TimedPattern, route_pattern_id: pattern.id, name: "Weekend")

      assert timing_rows(copied) |> Enum.map(&{&1.arrival_offset, &1.departure_offset}) == [
               {0, 0},
               {240, 300},
               {600, 660}
             ]

      render_click(view, "select_timing", %{"timing_id" => copied.id})
      render_click(view, "open_timing_dialog", %{"mode" => "rename"})

      render_change(view, "validate_timing_dialog", %{"name" => "Weekend service"})
      render_click(view, "confirm_timing_dialog")

      assert Repo.get!(TimedPattern, copied.id).name == "Weekend service"

      # A used timing refuses deletion with its dependency explained.
      render_click(view, "select_timing", %{"timing_id" => first.id})
      render_click(view, "open_delete_timing")

      assert has_element?(view, "#pattern-blocked-dialog[data-open='true']", "1 trip")
      refute has_element?(view, "#pattern-blocked-dialog", "Move trips")
      render_click(view, "close_blocked_dialog")
      assert Repo.get(TimedPattern, first.id)

      # An unused timing deletes after confirmation.
      render_click(view, "select_timing", %{"timing_id" => copied.id})
      render_click(view, "open_delete_timing")

      assert has_element?(view, "#timing-delete-dialog[data-open='true']")
      render_click(view, "confirm_delete_timing")

      refute Repo.get(TimedPattern, copied.id)

      # The last timing cannot be removed.
      render_click(view, "select_timing", %{"timing_id" => first.id})
      render_click(view, "open_delete_timing")

      assert has_element?(
               view,
               "#pattern-blocked-dialog[data-open='true']",
               "at least one timing"
             )

      render_click(view, "close_blocked_dialog")
      assert Repo.get(TimedPattern, first.id)

      # A blank timing starts at zero for every stop.
      render_click(view, "open_timing_dialog", %{"mode" => "add"})

      render_change(view, "validate_timing_dialog", %{"name" => "Blank", "source_timing_id" => ""})

      render_click(view, "confirm_timing_dialog")

      blank = Repo.get_by!(TimedPattern, route_pattern_id: pattern.id, name: "Blank")

      assert timing_rows(blank) |> Enum.map(&{&1.arrival_offset, &1.departure_offset}) ==
               [{0, 0}, {0, 0}, {0, 0}]
    end

    test "ticking timepoints on an unset timing stores the unticked stops as 0 and carries them to trips",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, timing: timing_row, trip: trip} =
        used_pattern(organization, version, "TPT1")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      edit_timing_field(view, 1, "timepoint", "1")
      edit_timing_field(view, 3, "timepoint", "1")

      render_click(view, "save_timing")
      render_click(view, "apply_timing_review")

      assert timepoints(timing_row) == [1, 0, 1]
      assert trip_timepoints(trip) == [1, 0, 1]
    end

    test "editing only a departure leaves an unset timing's timepoints unset",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, timing: timing_row} =
        three_stop_pattern(organization, version, "TPT2")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      edit_timing_field(view, 3, "departure", "12:00")

      render_click(view, "save_timing")

      assert has_element?(view, "#status", "Changes saved in this version.")
      assert timing_rows(timing_row) |> Enum.map(& &1.departure_offset) == [0, 300, 720]
      assert timepoints(timing_row) == [nil, nil, nil]
    end

    test "a save that leaves a stored timepoint unset beside marked ones writes it as 0",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, timing: timing_row} =
        three_stop_pattern(organization, version, "TPT3")

      set_timepoints(timing_row, [1, nil, 1])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      refute has_element?(view, "#timing-timepoint-2[checked]")

      edit_timing_field(view, 2, "pickup", "2")

      render_click(view, "save_timing")

      assert has_element?(view, "#status", "Changes saved in this version.")
      assert timepoints(timing_row) == [1, 0, 1]
      assert timing_rows(timing_row) |> Enum.map(& &1.pickup_type) == [nil, 2, nil]
    end

    test "unticking a marked timepoint stores 0",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, timing: timing_row} =
        three_stop_pattern(organization, version, "TPT4")

      set_timepoints(timing_row, [1, 1, 1])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      # A browser omits an unticked checkbox from the posted row.
      render_change(view, "validate_timing_row", %{
        "timing" => %{"2" => %{"arrival" => "04:00", "departure" => "05:00"}},
        "_target" => ["timing", "2", "timepoint"]
      })

      refute has_element?(view, "#timing-timepoint-2[checked]")

      render_click(view, "save_timing")

      assert timepoints(timing_row) == [1, 0, 1]
    end
  end

  describe "review conflicts and duplicate submission" do
    setup :editor_scope

    test "a stale second-session apply keeps edits and offers Refresh review",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, timing: timing_row, trip: trip} =
        used_pattern(organization, version, "CONFLICT1")

      extra = stop(organization, version, "CONFLICT1", 99, "CONFLICT1 Inserted")

      {:ok, stale_view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      {:ok, other_view, _html} =
        live(conn, pattern_path(version, route, pattern, "?task=details"))

      render_change(stale_view, "live_select_change", %{
        "id" => "pattern-stop-search",
        "text" => "Inserted"
      })

      render_change(stale_view, "set_insert_after", %{"insert" => %{"insert_after" => "1"}})

      render_change(stale_view, "choose_stop", %{
        "stop_search" => %{"stop_id" => extra.stop_id}
      })

      render_click(stale_view, "save_stops")
      assert has_element?(stale_view, "#stop-review-dialog[data-open='true']")
      render_click(stale_view, "acknowledge_review_timing", %{"timing_id" => timing_row.id})

      # The other session changes the pattern while the review is open.
      render_submit(element(other_view, "#pattern-details-form"), %{
        "pattern" => %{"name" => "Renamed later"}
      })

      render_click(stale_view, "apply_stop_review")

      assert has_element?(stale_view, "#stop-review-error", "changed since")
      assert has_element?(stale_view, "#stop-review-refresh", "Refresh review")
      assert has_element?(stale_view, "#pattern-stop-2", "CONFLICT1 Inserted")
      assert arrival_clocks(trip) == ["08:00:00", "08:04:00", "08:10:00"]

      render_click(stale_view, "refresh_review")

      assert has_element?(stale_view, "#stop-review-dialog[data-open='true']")
      assert has_element?(stale_view, "#stop-review-dialog-title", "Update 1 trip?")
      render_click(stale_view, "acknowledge_review_timing", %{"timing_id" => timing_row.id})
      render_click(stale_view, "apply_stop_review")

      assert arrival_clocks(trip) == ["08:00:00", "08:02:00", "08:04:00", "08:10:00"]
      assert length(occurrence_rows(pattern)) == 4
    end

    test "a stale timing apply offers Refresh review and recomputes the impact",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, stops: stops, pattern: pattern, trip: trip} =
        used_pattern(organization, version, "TCONFLICT1")

      {:ok, stale_view, _html} =
        live(conn, pattern_path(version, route, pattern, "?task=timings"))

      {:ok, other_view, _html} =
        live(conn, pattern_path(version, route, pattern, "?task=details"))

      change_timing(stale_view, 2, "departure", "06:00")
      render_click(stale_view, "save_timing")
      assert has_element?(stale_view, "#timing-review-dialog[data-open='true']")
      assert has_element?(stale_view, "#timing-review-dialog-title", "Update 1 trip?")

      # The other session changes the pattern while the timing review is open.
      render_submit(
        element(other_view, "#pattern-details-form"),
        %{"pattern" => %{"name" => "Renamed later"}}
      )

      logs_before = audit_count(organization)

      render_click(stale_view, "apply_timing_review")

      assert has_element?(stale_view, "#timing-review-error", "changed since")
      assert has_element?(stale_view, "#timing-review-refresh", "Refresh review")
      # The submitted rows survive the stale rejection.
      assert has_element?(stale_view, "#timing-departure-2[value='06:00']")
      assert arrival_clocks(trip) == ["08:00:00", "08:04:00", "08:10:00"]
      assert audit_count(organization) == logs_before

      render_click(stale_view, "refresh_timing_review")

      assert has_element?(stale_view, "#timing-review-dialog[data-open='true']")
      assert has_element?(stale_view, "#timing-review-dialog-title", "Update 1 trip?")
      assert has_element?(stale_view, "#timing-departure-2[value='06:00']")

      render_click(stale_view, "apply_timing_review")

      assert has_element?(stale_view, "#status", "1 trips updated")

      assert trip_clocks(trip) == [
               {Enum.at(stops, 0).stop_id, 1, "08:00:00", "08:00:00"},
               {Enum.at(stops, 1).stop_id, 2, "08:04:00", "08:06:00"},
               {Enum.at(stops, 2).stop_id, 3, "08:10:00", "08:11:00"}
             ]
    end

    test "a repeated apply writes one reviewed operation",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern, timing: timing_row, trip: trip} =
        used_pattern(organization, version, "CONFLICT2")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_click(view, "remove_stop", %{"index" => "3"})
      render_click(view, "save_stops")
      render_click(view, "acknowledge_review_timing", %{"timing_id" => timing_row.id})

      render_click(view, "apply_stop_review")
      render_click(view, "apply_stop_review")

      assert audit_count(organization) == 1
      assert length(trip_clocks(trip)) == 2
    end

    test "a save that needs explicit end-stop values renders real inputs and applies them",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, stops: stops, pattern: pattern, timing: timing_row, trip: trip} =
        used_pattern(organization, version, "CONFLICT3")

      extra = stop(organization, version, "CONFLICT3", 99, "CONFLICT3 Last")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_change(view, "live_select_change", %{"id" => "pattern-stop-search", "text" => "Last"})

      render_change(view, "choose_stop", %{"stop_search" => %{"stop_id" => extra.stop_id}})
      render_click(view, "save_stops")

      assert has_element?(view, "#stop-review-dialog[data-open='true']")
      assert has_element?(view, "#stop-review-error", "Enter arrival and departure")
      assert has_element?(view, "#stop-review-retry", "Try review again")
      assert has_element?(view, "#stop-review-dialog-confirm[disabled]")

      # The terminal addition has real arrival/departure inputs to fill, so the
      # values the proposal requires can actually be provided.
      assert has_element?(
               view,
               "#stop-review-value-#{timing_row.id}-new-1-arrival[name='review[#{timing_row.id}][new-1][arrival]']"
             )

      assert has_element?(
               view,
               "#stop-review-value-#{timing_row.id}-new-1-departure[name='review[#{timing_row.id}][new-1][departure]']"
             )

      fill_review_values(view, timing_row.id, "new-1", %{"arrival" => "20:00"})

      assert has_element?(
               view,
               "#stop-review-value-#{timing_row.id}-new-1-arrival[value='20:00']"
             )

      fill_review_values(view, timing_row.id, "new-1", %{
        "arrival" => "20:00",
        "departure" => "30:00"
      })

      render_click(view, "retry_review")
      refute has_element?(view, "#stop-review-error", "Enter arrival and departure")

      render_click(view, "acknowledge_review_timing", %{"timing_id" => timing_row.id})
      render_click(view, "apply_stop_review")

      assert trip_clocks(trip) == [
               {Enum.at(stops, 0).stop_id, 1, "08:00:00", "08:00:00"},
               {Enum.at(stops, 1).stop_id, 2, "08:04:00", "08:05:00"},
               {Enum.at(stops, 2).stop_id, 3, "08:10:00", "08:11:00"},
               {extra.stop_id, 4, "08:20:00", "08:30:00"}
             ]

      assert has_element?(view, "#pattern-stop-4", "CONFLICT3 Last")
    end
  end

  describe "permission loss on a connected session" do
    setup :editor_scope

    test "a revoked editor role denies mutation events and renders unavailable editing",
         %{conn: conn, organization: organization, version: version, user: user} do
      %{route: route, pattern: pattern, trip: trip} = used_pattern(organization, version, "ACL1")

      before_name = Repo.get!(RoutePattern, pattern.id).route_pattern_name

      {:ok, stops_view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      {:ok, details_view, _html} =
        live(conn, pattern_path(version, route, pattern, "?task=details"))

      {:ok, timing_view, _html} =
        live(conn, pattern_path(version, route, pattern, "?task=timings"))

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      membership |> Ecto.Changeset.change(roles: []) |> Repo.update!()

      # Every connected session keeps its socket, but the mutation boundary
      # re-checks the current membership before writing anything.
      render_click(stops_view, "remove_stop", %{"index" => "3"})
      render_click(stops_view, "save_stops")

      render_submit(
        element(details_view, "#pattern-details-form"),
        %{"pattern" => %{"name" => "Unauthorized rename"}}
      )

      change_timing(timing_view, 2, "departure", "06:00")
      render_click(timing_view, "save_timing")

      assert Repo.get!(RoutePattern, pattern.id).route_pattern_name == before_name
      assert length(occurrence_rows(pattern)) == 3
      assert audit_count(organization) == 0
      assert arrival_clocks(trip) == ["08:00:00", "08:04:00", "08:10:00"]

      for view <- [stops_view, details_view, timing_view] do
        assert has_element?(view, "#pattern-editor-revoked", "Editing is no longer available")
      end

      # Reloading keeps the page unavailable while the role is still missing.
      render_click(stops_view, "reload_patterns")
      assert has_element?(stops_view, "#pattern-editor-revoked")

      # Restoring the role and reloading brings the editor back instead of
      # leaving a sticky unavailable page.
      Accounts.get_user_org_membership(user.id, organization.id)
      |> Ecto.Changeset.change(roles: ["pathways_studio_editor"])
      |> Repo.update!()

      render_click(stops_view, "reload_patterns")
      refute has_element?(stops_view, "#pattern-editor-revoked")
      assert has_element?(stops_view, "#pattern-stops")
    end
  end

  describe "pattern lifecycle from the editor" do
    setup :editor_scope

    test "a used pattern refuses deletion and an unused pattern deletes after confirmation",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, stops: stops, pattern: used} = used_pattern(organization, version, "LIFE1")

      unused = pattern(organization, version, route, "P-LIFE-UNUSED")
      unused_occurrences = occurrences(unused, Enum.take(stops, 2))
      timing(unused, unused_occurrences, "Timing A", [{0, 0}, {60, 60}])

      {:ok, view, _html} = live(conn, pattern_path(version, route, used, "?task=stops"))

      render_click(view, "open_delete_pattern")

      assert has_element?(view, "#pattern-blocked-dialog[data-open='true']", "1 trip")
      refute has_element?(view, "#pattern-blocked-dialog", "Move trips")
      render_click(view, "close_blocked_dialog")
      assert Repo.get(RoutePatternStop, hd(occurrence_rows(used)).id)

      {:ok, unused_view, _html} = live(conn, pattern_path(version, route, unused, "?task=stops"))

      render_click(unused_view, "open_delete_pattern")
      assert has_element?(unused_view, "#pattern-delete-dialog[data-open='true']")

      render_click(unused_view, "confirm_delete_pattern")

      assert_redirect(unused_view, "/gtfs/#{version.id}/routes/#{route.route_id}/patterns")
      refute Repo.get_by(RoutePattern, route_pattern_id: "P-LIFE-UNUSED")
    end

    test "copy duplicates stops and timings without assigning trips",
         %{conn: conn, organization: organization, version: version} do
      %{route: route, pattern: pattern} = used_pattern(organization, version, "LIFE2")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=stops"))

      render_click(view, "copy_pattern")

      copied =
        Repo.one!(
          from(p in RoutePattern,
            where:
              p.route_id == ^route.route_id and
                p.route_pattern_name == ^"#{pattern.route_pattern_name} copy"
          )
        )

      assert_redirect(view, pattern_path(version, route, copied, "?task=stops"))

      assert copied.id != pattern.id
      assert length(occurrence_rows(copied)) == 3
      copied_timing = Repo.one!(from(t in TimedPattern, where: t.route_pattern_id == ^copied.id))
      assert length(timing_rows(copied_timing)) == 3

      assert Repo.aggregate(
               from(t in Trip, where: t.route_pattern_id == ^copied.route_pattern_id),
               :count
             ) == 0
    end
  end
end
