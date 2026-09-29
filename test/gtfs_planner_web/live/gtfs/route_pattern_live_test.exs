defmodule GtfsPlannerWeb.Gtfs.RoutePatternLiveTest do
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

  # Adapter substitution exists only to simulate a read outage. Successful
  # reads and every write use the real context through the production Repo
  # adapter; this helper restores the previous configuration on exit.
  defp substitute_read_adapter(_context) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)

    :ok
  end

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{
        alias: "route-pattern-live-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{email: "pattern-editor-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  # The test database can hold rows this case did not create, so pattern reads
  # cover only this case's organization and version.
  defp own_patterns(organization, version) do
    from(p in RoutePattern,
      where: p.organization_id == ^organization.id and p.gtfs_version_id == ^version.id
    )
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

  defp pattern(organization, version, route, route_pattern_id, attrs \\ []) do
    route_pattern_fixture(
      organization.id,
      version.id,
      Map.merge(
        %{
          route_id: route.route_id,
          route_pattern_id: route_pattern_id,
          route_pattern_name: route_pattern_id,
          direction_id: 0
        },
        Map.new(attrs)
      )
    )
  end

  defp occurrences(pattern, stops) do
    stops
    |> Enum.with_index(1)
    |> Enum.map(fn {stop, position} ->
      route_pattern_stop_fixture(pattern, stop.stop_id, position)
    end)
  end

  defp timing(pattern, occurrence_rows, attrs) do
    attrs = Map.new(attrs)
    timing = timed_pattern_fixture(pattern, attrs)

    Enum.each(occurrence_rows, fn occurrence ->
      timed_pattern_stop_fixture(timing, occurrence, %{
        arrival_offset: Map.get(attrs, :arrival_offset, 0),
        departure_offset: Map.get(attrs, :departure_offset, 0)
      })
    end)

    timing
  end

  defp linked_trip(organization, version, route, pattern, timing, trip_id) do
    trip = trip_fixture(organization.id, version.id, route.route_id, %{trip_id: trip_id})

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })
  end

  defp stop_times(trip, organization, version, stops) do
    stops
    |> Enum.with_index(1)
    |> Enum.each(fn {stop, sequence} ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, stop.stop_id, %{
        stop_sequence: sequence,
        arrival_time: "08:0#{sequence}:00",
        departure_time: "08:0#{sequence}:00"
      })
    end)

    trip
  end

  defp index(html, needle) do
    {position, _length} = :binary.match(html, needle)
    position
  end

  defp assert_single_h1(html, expected_text) do
    h1s = Regex.scan(~r/<h1[^>]*>(.*?)<\/h1>/s, html)

    assert length(h1s) == 1, "expected exactly one H1, got #{length(h1s)}"

    [[_full, inner]] = h1s
    assert strip_tags(inner) == expected_text
  end

  defp strip_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp patterns_path(version, route), do: "/gtfs/#{version.id}/routes/#{route.route_id}/patterns"

  defp new_pattern_path(version, route),
    do: "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/new"

  defp pattern_path(version, route, pattern, query \\ "") do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}#{query}"
  end

  describe "patterns list" do
    setup :editor_scope

    test "groups patterns under neutral direction headings with typicality and counts in order",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "LIST1")
      stops = Enum.map(1..4, &stop(organization, version, "LIST1", &1))

      all_day =
        pattern(organization, version, route, "P-ALLDAY",
          direction_id: 0,
          route_pattern_sort_order: 1,
          route_pattern_typicality: 1,
          route_pattern_name: "All day",
          route_pattern_time_desc: "Weekday service"
        )

      evening =
        pattern(organization, version, route, "P-EVENING",
          direction_id: 0,
          route_pattern_sort_order: 2,
          route_pattern_typicality: 4,
          route_pattern_name: "Evening",
          route_pattern_time_desc: "Evenings only"
        )

      return =
        pattern(organization, version, route, "P-RETURN",
          direction_id: 1,
          route_pattern_sort_order: 0,
          route_pattern_typicality: 3,
          route_pattern_name: "Return"
        )

      all_day_occurrences = occurrences(all_day, Enum.take(stops, 4))
      evening_occurrences = occurrences(evening, Enum.take(stops, 2))
      return_occurrences = occurrences(return, Enum.take(stops, 3))

      all_day_timing = timing(all_day, all_day_occurrences, %{name: "Weekday"})
      timing(all_day, all_day_occurrences, %{name: "Weekend"})
      timing(evening, evening_occurrences, %{name: "Evening"})
      return_timing = timing(return, return_occurrences, %{name: "Return"})

      linked_trip(organization, version, route, all_day, all_day_timing, "T1")
      linked_trip(organization, version, route, all_day, all_day_timing, "T2")
      linked_trip(organization, version, route, return, return_timing, "T3")

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-list-container")
      assert has_element?(view, "#patterns-count", "3 patterns")
      assert has_element?(view, "#pattern-trip-count", "3 trips across all service days")

      html = render(view)
      assert index(html, "patterns-direction-0") < index(html, "patterns-P-ALLDAY")
      assert index(html, "patterns-P-ALLDAY") < index(html, "patterns-P-EVENING")
      assert index(html, "patterns-P-EVENING") < index(html, "patterns-direction-1")
      assert index(html, "patterns-direction-1") < index(html, "patterns-P-RETURN")

      assert has_element?(view, "#patterns-direction-0", "Direction 0")
      assert has_element?(view, "#patterns-direction-0", "2 patterns")
      assert has_element?(view, "#patterns-direction-1", "Direction 1")
      assert has_element?(view, "#patterns-direction-1", "1 pattern")

      assert has_element?(view, "#patterns-P-ALLDAY", "Weekday service")
      assert has_element?(view, "#patterns-P-ALLDAY", "2 timings")
      assert has_element?(view, "#patterns-P-ALLDAY", "Typical")
      assert has_element?(view, "#patterns-P-EVENING", "Detour")
      assert has_element?(view, "#patterns-P-RETURN", "Atypical")
      assert has_element?(view, "#patterns-P-RETURN", "No service description")
      assert has_element?(view, "#patterns-P-ALLDAY td[data-label='Stops']", "4")
      assert has_element?(view, "#patterns-P-EVENING td[data-label='Stops']", "2")
      assert has_element?(view, "#patterns-P-ALLDAY td[data-label='Trips']", "2")
      assert has_element?(view, "#patterns-P-RETURN td[data-label='Trips']", "1")
      assert has_element?(view, "#patterns-P-EVENING td[data-label='Trips']", "Not used yet")
      refute html =~ "Outbound"
      refute html =~ "Inbound"
    end

    test "first paint shows the loading skeleton and the connected page shows the ready list",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "LOAD1")
      stops = Enum.map(1..2, &stop(organization, version, "LOAD1", &1))
      loaded = pattern(organization, version, route, "P-LOAD", route_pattern_name: "Loaded")
      loaded_occurrences = occurrences(loaded, stops)
      loaded_timing = timing(loaded, loaded_occurrences, %{name: "Weekday"})
      linked_trip(organization, version, route, loaded, loaded_timing, "L1")
      path = patterns_path(version, route)

      static_html = conn |> get(path) |> html_response(200)
      assert static_html =~ "patterns-loading"
      assert static_html =~ "Loading patterns"
      refute static_html =~ "patterns-list-container"

      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#patterns-list-container")
      refute has_element?(view, "#patterns-loading")
    end

    test "a route with no trips and no patterns shows the first-pattern empty state",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "EMPTY1")

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-empty", "Add the first pattern")

      assert has_element?(
               view,
               "#patterns-create-empty[href='#{new_pattern_path(version, route)}']"
             )

      refute has_element?(view, "#patterns-unlinked")
      refute has_element?(view, "#patterns-build-blocked")
    end

    test "ungrouped trips show the unlinked state and building them creates a pattern",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "UNLINKED1")
      stops = Enum.map(1..3, &stop(organization, version, "UNLINKED1", &1))

      Enum.each(["U1", "U2"], fn trip_id ->
        organization.id
        |> trip_fixture(version.id, route.route_id, %{trip_id: trip_id, direction_id: 0})
        |> stop_times(organization, version, stops)
      end)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-unlinked", "Group your trips into patterns")
      assert has_element?(view, "#patterns-unlinked", "2 trips")
      assert has_element?(view, "#patterns-build", "Build patterns from trips")

      render_click(element(view, "#patterns-build"))

      refute has_element?(view, "#patterns-unlinked")
      assert has_element?(view, "#patterns-list-container")
      assert has_element?(view, "#patterns-count", "1 pattern")
      assert has_element?(view, "#patterns-build-summary", "Built 1 pattern from your trips")
      assert has_element?(view, "#patterns-build-summary", "2 trips are now in a pattern")
      assert Repo.aggregate(own_patterns(organization, version), :count) == 1
    end

    test "a custom-only route shows the honest blocked build state, not an error",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "CUSTOM1")
      stops = Enum.map(1..2, &stop(organization, version, "CUSTOM1", &1))

      trip =
        organization.id
        |> trip_fixture(version.id, route.route_id, %{trip_id: "C1", direction_id: 0})
        |> stop_times(organization, version, stops)

      trip_pattern_metadata_fixture(trip, %{
        pattern_derivation_state: "custom",
        pattern_derivation_reason: "timing_missing"
      })

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-build-blocked", "No trips to group")
      assert has_element?(view, "#patterns-build-blocked", "1")
      refute has_element?(view, "#patterns-unlinked")
      refute has_element?(view, "#patterns-unavailable")
      refute has_element?(view, "#patterns-derivation-error")
    end

    test "a build that finds nothing pending renders the blocked state instead of an error",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "RACE1")
      stops = Enum.map(1..2, &stop(organization, version, "RACE1", &1))

      trip =
        organization.id
        |> trip_fixture(version.id, route.route_id, %{trip_id: "R1", direction_id: 0})
        |> stop_times(organization, version, stops)

      {:ok, view, _html} = live(conn, patterns_path(version, route))
      assert has_element?(view, "#patterns-build")

      # The pending trip is reclassified between render and click.
      trip_pattern_metadata_fixture(trip, %{
        pattern_derivation_state: "custom",
        pattern_derivation_reason: "timing_missing"
      })

      render_click(element(view, "#patterns-build"))

      assert has_element?(view, "#patterns-build-blocked", "No trips to group")
      refute has_element?(view, "#patterns-unavailable")
      refute has_element?(view, "#patterns-derivation-error")
      refute render(view) =~ "could not be built"
    end

    test "a nonempty list with pending trips keeps its rows and offers the build retry",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "PARTIAL1")
      stops = Enum.map(1..3, &stop(organization, version, "PARTIAL1", &1))

      built = pattern(organization, version, route, "P-BUILT", route_pattern_name: "Built")
      built_occurrences = occurrences(built, stops)
      built_timing = timing(built, built_occurrences, %{name: "Weekday"})
      linked_trip(organization, version, route, built, built_timing, "B1")

      pending_stops = Enum.map(4..5, &stop(organization, version, "PARTIAL1", &1))

      organization.id
      |> trip_fixture(version.id, route.route_id, %{trip_id: "PENDING1", direction_id: 0})
      |> stop_times(organization, version, pending_stops)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-list-container")
      assert has_element?(view, "#patterns-P-BUILT")
      assert has_element?(view, "#patterns-partial", "1")
      assert has_element?(view, "#patterns-build-retry", "Build patterns from trips")
      refute has_element?(view, "#patterns-unlinked")
    end

    test "a failed refresh keeps the loaded rows and reports them as out of date",
         %{conn: conn, organization: organization, version: version} do
      substitute_read_adapter(%{})
      route = route(organization, version, "STALE1")
      stops = Enum.map(1..2, &stop(organization, version, "STALE1", &1))

      built = pattern(organization, version, route, "P-STALE", route_pattern_name: "Stale")
      built_occurrences = occurrences(built, stops)
      built_timing = timing(built, built_occurrences, %{name: "Weekday"})
      linked_trip(organization, version, route, built, built_timing, "S1")

      fail_reads = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :load_route_pattern_screen, fn org, ver, route_id, opts ->
        if :atomics.get(fail_reads, 1) == 1 do
          {:error, :unavailable}
        else
          CatalogReadAdapter.Repo.load_route_pattern_screen(org, ver, route_id, opts)
        end
      end)

      {:ok, view, _html} = live(conn, patterns_path(version, route))
      assert has_element?(view, "#patterns-P-STALE")

      :atomics.put(fail_reads, 1, 1)
      render_click(element(view, "#patterns-reload"))

      assert has_element?(view, "#patterns-P-STALE")
      assert has_element?(view, "#patterns-stale", "may be out of date")
      refute has_element?(view, "#patterns-unavailable")
    end

    test "losing the editor role keeps the rows under a warning and takes away every change",
         %{conn: conn, user: user, organization: organization, version: version} do
      route = route(organization, version, "REVOKE1")
      stops = Enum.map(1..2, &stop(organization, version, "REVOKE1", &1))

      built = pattern(organization, version, route, "P-REVOKE", route_pattern_name: "Kept")
      built_occurrences = occurrences(built, stops)
      built_timing = timing(built, built_occurrences, %{name: "Weekday"})
      linked_trip(organization, version, route, built, built_timing, "V1")

      {:ok, view, _html} = live(conn, patterns_path(version, route))
      assert has_element?(view, "#patterns-create")

      Accounts.get_user_org_membership(user.id, organization.id)
      |> Ecto.Changeset.change(roles: [])
      |> Repo.update!()

      render_click(element(view, "#patterns-reload"))

      assert has_element?(view, "#pattern-editor-revoked", "Your editing access was removed")
      assert has_element?(view, "#patterns-P-REVOKE")
      refute has_element?(view, "#patterns-create")
      refute has_element?(view, "#patterns-bulk-generate")
    end

    test "a derivation error renders a bounded error with retry on a nonempty list",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "ERROR1")
      stops = Enum.map(1..2, &stop(organization, version, "ERROR1", &1))

      built = pattern(organization, version, route, "P-ERROR", route_pattern_name: "Kept")
      built_occurrences = occurrences(built, stops)
      built_timing = timing(built, built_occurrences, %{name: "Weekday"})
      linked_trip(organization, version, route, built, built_timing, "E1")

      Repo.update_all(
        from(r in GtfsPlanner.Gtfs.Route, where: r.id == ^route.id),
        set: [pattern_derivation_error: "stop_times_unreadable"]
      )

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-list-container")
      assert has_element?(view, "#patterns-derivation-error", "stop_times_unreadable")
      assert has_element?(view, "#patterns-build-error-retry", "Build patterns from trips")
    end

    test "an unavailable read renders the error state with retry and recovers",
         %{conn: conn, organization: organization, version: version} do
      substitute_read_adapter(%{})
      route = route(organization, version, "UNAVAIL1")

      recover = :atomics.new(1, [])

      stub(CatalogReadAdapterMock, :load_route_pattern_screen, fn org, ver, route_id, opts ->
        if :atomics.get(recover, 1) == 1 do
          CatalogReadAdapter.Repo.load_route_pattern_screen(org, ver, route_id, opts)
        else
          {:error, :unavailable}
        end
      end)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-unavailable", "patterns didn’t load")
      assert has_element?(view, "#patterns-retry", "Reload patterns")

      :atomics.put(recover, 1, 1)
      render_click(element(view, "#patterns-retry"))

      refute has_element?(view, "#patterns-unavailable")
      assert has_element?(view, "#patterns-empty", "Add the first pattern")
    end
  end

  describe "pattern creation" do
    setup :editor_scope

    test "creation starts on Details and creates the pattern with its first timing",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "CREATE1")
      stops = Enum.map(1..3, &stop(organization, version, "CREATE1", &1, "Create Stop #{&1}"))

      {:ok, view, _html} = live(conn, new_pattern_path(version, route))

      assert has_element?(view, "#pattern-task-details[aria-current='page']")
      assert has_element?(view, "#pattern-details-form")
      assert has_element?(view, "#pattern-details-headsign")

      render_change(view, "validate_details", %{
        "pattern" => %{
          "name" => "Crosstown",
          "direction_id" => "1",
          "headsign" => "Harbor",
          "time_desc" => "Weekday service",
          "typicality" => "2",
          "sort_order" => "4"
        }
      })

      render_click(element(view, "#pattern-task-stops"))
      assert has_element?(view, "#pattern-task-stops[aria-current='page']")

      Enum.each(Enum.take(stops, 2), fn stop ->
        render_change(view, "choose_stop", %{"stop_id" => stop.stop_id})
      end)

      assert has_element?(view, "#pattern-stop-1", "Create Stop 1")
      assert has_element?(view, "#pattern-stop-2", "Create Stop 2")
      assert has_element?(view, "#edit-status", "Unsaved changes")

      render_click(element(view, "#pattern-create"))

      created =
        Repo.one!(
          from(p in own_patterns(organization, version),
            where: p.route_pattern_name == "Crosstown"
          )
        )

      assert created.route_id == route.route_id
      assert created.direction_id == 1
      assert created.headsign == "Harbor"
      assert created.route_pattern_time_desc == "Weekday service"
      assert created.route_pattern_typicality == 2
      assert created.route_pattern_sort_order == 4

      assert Repo.all(
               from(o in RoutePatternStop,
                 where: o.route_pattern_id == ^created.id,
                 order_by: o.position
               )
             )
             |> Enum.map(& &1.stop_id) == Enum.map(Enum.take(stops, 2), & &1.stop_id)

      timings = Repo.all(from(t in TimedPattern, where: t.route_pattern_id == ^created.id))
      assert [timing] = timings
      assert timing.name == "Timing A"

      rows =
        Repo.all(
          from(r in TimedPatternStop,
            where: r.timed_pattern_id == ^timing.id,
            order_by: r.inserted_at
          )
        )

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.arrival_offset == 0 and &1.departure_offset == 0))

      assert_redirect(
        view,
        pattern_path(version, route, created, "?task=timings")
      )
    end

    test "creation rejects fewer than two stops and keeps the staged values",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "CREATE2")

      {:ok, view, _html} = live(conn, new_pattern_path(version, route))

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => %{"name" => "Crosstown", "direction_id" => "1"}
      })

      assert has_element?(view, "#error", "at least two stops")
      assert has_element?(view, "#pattern-task-stops[aria-current='page']")
      assert Repo.aggregate(own_patterns(organization, version), :count) == 0

      # Staged details survive the failed submission and the task switch.
      render_click(element(view, "#pattern-task-details"))
      assert has_element?(view, "#pattern-details-name[value='Crosstown']")
    end

    test "creation refuses a repeated adjacent stop",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "CREATE3")
      stops = Enum.map(1..2, &stop(organization, version, "CREATE3", &1))

      {:ok, view, _html} = live(conn, new_pattern_path(version, route))

      render_change(view, "validate_details", %{"pattern" => %{"name" => "Loop"}})
      [first, second] = stops
      render_click(element(view, "#pattern-task-stops"))

      render_change(view, "choose_stop", %{"stop_id" => first.stop_id})
      render_change(view, "choose_stop", %{"stop_id" => second.stop_id})
      render_change(view, "choose_stop", %{"stop_id" => second.stop_id})

      assert has_element?(view, "#error", "already next to that position")
      assert Repo.aggregate(own_patterns(organization, version), :count) == 0
    end
  end

  describe "pattern details" do
    setup :editor_scope

    test "opening a pattern lands on Stops with its ordered stop list",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "DETAIL1")
      stops = Enum.map(1..3, &stop(organization, version, "DETAIL1", &1, "Detail Stop #{&1}"))

      pattern = pattern(organization, version, route, "P-DETAIL", route_pattern_name: "Detail")
      pattern_occurrences = occurrences(pattern, stops)
      timing = timing(pattern, pattern_occurrences, %{name: "Weekday"})
      linked_trip(organization, version, route, pattern, timing, "D1")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      assert has_element?(view, "#pattern-task-stops[aria-current='page']")
      assert has_element?(view, "#pattern-stop-1", "Detail Stop 1")
      assert has_element?(view, "#pattern-stop-1", "First stop")
      assert has_element?(view, "#pattern-stop-3", "Last stop")
      assert has_element?(view, "#edit-status", "Saved in this version")
      assert has_element?(view, "#published-version-notice", version.name)
    end

    test "details show the Pattern ID, save the fields and keep existing trip destinations",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "DETAIL2")
      stops = Enum.map(1..2, &stop(organization, version, "DETAIL2", &1))

      pattern =
        pattern(organization, version, route, "P-SAVE",
          route_pattern_name: "Before",
          headsign: "Old destination",
          route_pattern_typicality: 0
        )

      pattern_occurrences = occurrences(pattern, stops)
      timing = timing(pattern, pattern_occurrences, %{name: "Weekday"})
      trip = linked_trip(organization, version, route, pattern, timing, "D2")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=details"))

      assert has_element?(view, "#pattern-details-additional")
      assert has_element?(view, "#pattern-details-id", pattern.route_pattern_id)
      assert has_element?(view, "#pattern-details-form", "Headsign for new trips")

      assert has_element?(
               view,
               "#pattern-details-form",
               "Existing trip destinations stay unchanged"
             )

      refute has_element?(view, "#details-impact-dialog[data-open='true']")

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => %{
          "name" => "After",
          "direction_id" => "0",
          "headsign" => "New default",
          "time_desc" => "School days",
          "typicality" => "5",
          "sort_order" => "7"
        }
      })

      saved = Repo.get!(RoutePattern, pattern.id)
      assert saved.route_pattern_name == "After"
      assert saved.headsign == "New default"
      assert saved.route_pattern_time_desc == "School days"
      assert saved.route_pattern_typicality == 5
      assert saved.route_pattern_sort_order == 7
      assert Repo.get!(Trip, trip.id).trip_headsign == trip.trip_headsign
      assert has_element?(view, "#status", "saved")
    end

    test "a direction change is reviewed against its trip impact before it is applied",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "DETAIL3")
      stops = Enum.map(1..2, &stop(organization, version, "DETAIL3", &1))

      pattern =
        pattern(organization, version, route, "P-DIR",
          route_pattern_name: "Direction",
          direction_id: 0
        )

      pattern_occurrences = occurrences(pattern, stops)
      timing = timing(pattern, pattern_occurrences, %{name: "Weekday"})
      first_trip = linked_trip(organization, version, route, pattern, timing, "D3A")
      second_trip = linked_trip(organization, version, route, pattern, timing, "D3B")
      trip_pattern_metadata_fixture(first_trip, %{direction_id: 0})
      trip_pattern_metadata_fixture(second_trip, %{direction_id: 0})

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=details"))

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => %{"name" => "Direction", "direction_id" => "1", "typicality" => "0"}
      })

      assert has_element?(view, "#details-impact-dialog[data-open='true']", "Update 2 trips?")

      assert has_element?(
               view,
               "#details-impact-dialog",
               "changes #{version.name}, a published version"
             )

      assert Repo.get!(RoutePattern, pattern.id).direction_id == 0
      assert Repo.get!(Trip, first_trip.id).direction_id == 0

      render_click(element(view, "#details-impact-dialog-confirm"))

      assert Repo.get!(RoutePattern, pattern.id).direction_id == 1
      assert Repo.get!(Trip, first_trip.id).direction_id == 1
      assert Repo.get!(Trip, second_trip.id).direction_id == 1
      refute has_element?(view, "#details-impact-dialog[data-open='true']")

      audit =
        Repo.one(
          from(c in ChangeLog,
            where:
              c.organization_id == ^organization.id and c.gtfs_version_id == ^version.id and
                c.entity_type == "route_pattern" and c.action == "updated",
            order_by: [desc: c.inserted_at],
            limit: 1
          )
        )

      assert audit
    end

    test "a forged pattern id in the save parameters is ignored",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "DETAIL4")
      other_route = route(organization, version, "DETAIL4B")
      stops = Enum.map(1..2, &stop(organization, version, "DETAIL4", &1))
      other_stops = Enum.map(1..2, &stop(organization, version, "DETAIL4B", &1))

      pattern = pattern(organization, version, route, "P-FORGED", route_pattern_name: "Mine")
      occurrences(pattern, stops)

      other =
        pattern(organization, version, other_route, "P-OTHER", route_pattern_name: "Theirs")

      occurrences(other, other_stops)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=details"))

      render_submit(element(view, "#pattern-details-form"), %{
        "pattern" => %{
          "name" => "Mine after",
          "pattern_id" => other.route_pattern_id,
          "id" => other.id,
          "direction_id" => "0",
          "typicality" => "0"
        }
      })

      assert Repo.get!(RoutePattern, pattern.id).route_pattern_name == "Mine after"
      assert Repo.get!(RoutePattern, other.id).route_pattern_name == "Theirs"
    end
  end

  describe "pattern alignment task" do
    setup :editor_scope

    test "an existing pattern lists four ordered tasks and patches to the Alignment shell",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "ALIGN1")
      stops = Enum.map(1..3, &stop(organization, version, "ALIGN1", &1))

      pattern =
        pattern(organization, version, route, "P-ALIGN", route_pattern_name: "Alignment target")

      pattern_occurrences = occurrences(pattern, stops)
      selected_timing = timing(pattern, pattern_occurrences, %{name: "Weekday"})

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      html = render(view)

      assert index(html, "pattern-task-stops") < index(html, "pattern-task-timings")
      assert index(html, "pattern-task-timings") < index(html, "pattern-task-alignment")
      assert index(html, "pattern-task-alignment") < index(html, "pattern-task-details")

      assert has_element?(view, "#pattern-task-stops", "Stops")
      assert has_element?(view, "#pattern-task-timings", "Timings")
      assert has_element?(view, "#pattern-task-alignment", "Alignment")
      assert has_element?(view, "#pattern-task-details", "Details")

      render_click(element(view, "#pattern-task-alignment"))

      assert_patched(
        view,
        pattern_path(version, route, pattern, "?task=alignment&timing=#{selected_timing.id}")
      )

      assert has_element?(view, "#pattern-task-alignment[aria-current='page']")
      assert has_element?(view, "#alignment-task")
      assert has_element?(view, "h3#alignment-title", "Alignment")
      assert has_element?(view, "#alignment-status")
      assert has_element?(view, "#alignment-sections")
      assert has_element?(view, "#alignment-detail")
      assert has_element?(view, "#alignment-footer")
      refute has_element?(view, "#coming-soon")

      # Alignment has its own branch and never falls through to timings.
      refute has_element?(view, "#timing-select")
      refute has_element?(view, "#timing-rows")
    end

    test "direct query entry keeps one h1 and the pattern h2 above the Alignment h3",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "ALIGN2")
      stops = Enum.map(1..2, &stop(organization, version, "ALIGN2", &1))

      pattern =
        pattern(organization, version, route, "P-ALIGN2", route_pattern_name: "Direct alignment")

      pattern_occurrences = occurrences(pattern, stops)
      timing(pattern, pattern_occurrences, %{name: "Weekday"})

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      assert has_element?(view, "#pattern-task-alignment[aria-current='page']")
      assert has_element?(view, "#alignment-task")
      assert has_element?(view, "h2", "Direct alignment")
      assert has_element?(view, "h3#alignment-title", "Alignment")

      html = render(view)
      assert_single_h1(html, "ALIGN2 - ALIGN2 corridor")
      assert index(html, "<h1") < index(html, "<h2")
      assert index(html, "<h2") < index(html, "id=\"alignment-title\"")
    end

    test "creating with task=alignment stays in Details with only Details and Stops",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "ALIGN3")

      {:ok, view, _html} = live(conn, new_pattern_path(version, route) <> "?task=alignment")

      assert has_element?(view, "#pattern-task-details[aria-current='page']")
      assert has_element?(view, "#pattern-task-stops")
      refute has_element?(view, "#pattern-task-alignment")
      refute has_element?(view, "#pattern-task-timings")
      refute has_element?(view, "#coming-soon")
      assert has_element?(view, "#pattern-details-form")

      html = render(view)
      assert length(Regex.scan(~r/id="pattern-task-[a-z]+"/, html)) == 2
    end

    test "an unknown task still falls back to Stops and a missing pattern still redirects",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "ALIGN4")
      stops = Enum.map(1..2, &stop(organization, version, "ALIGN4", &1))
      pattern = pattern(organization, version, route, "P-ALIGN4", route_pattern_name: "Fallback")
      pattern_occurrences = occurrences(pattern, stops)
      timing(pattern, pattern_occurrences, %{name: "Weekday"})

      {:ok, view, _html} =
        live(conn, pattern_path(version, route, pattern, "?task=alignment-typo"))

      assert has_element?(view, "#pattern-task-stops[aria-current='page']")
      refute has_element?(view, "#pattern-task-alignment[aria-current='page']")
      refute has_element?(view, "#coming-soon")

      missing_path =
        "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/P-ALIGN4-MISSING?task=alignment"

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, missing_path)
      assert to == patterns_path(version, route)
    end
  end

  describe "pattern ID with reserved URL characters" do
    setup :editor_scope

    setup %{organization: organization, version: version} do
      route = route(organization, version, "SLASH1")
      stops = Enum.map(1..2, &stop(organization, version, "SLASH1", &1))
      pattern = pattern(organization, version, route, "QA/PAT 1")
      timing = timing(pattern, occurrences(pattern, stops), %{name: "Weekday"})

      %{
        timing: timing,
        encoded_path: "/gtfs/#{version.id}/routes/SLASH1/patterns/QA%2FPAT%201",
        patterns_path: "/gtfs/#{version.id}/routes/SLASH1/patterns"
      }
    end

    test "opens the pattern from the list by its encoded path", %{
      conn: conn,
      patterns_path: patterns_path,
      encoded_path: encoded_path
    } do
      {:ok, view, _html} = live(conn, patterns_path)

      render_click(element(view, "button[phx-click='open_pattern']"))

      assert_redirect(view, "#{encoded_path}?task=stops")
    end

    test "opens the Alignment task from the list by its encoded path", %{
      conn: conn,
      patterns_path: patterns_path,
      encoded_path: encoded_path
    } do
      {:ok, view, _html} = live(conn, patterns_path)

      render_click(element(view, "button[phx-click='open_pattern_alignment']"))

      assert_patched(view, "#{encoded_path}?task=alignment")
    end

    test "keeps the encoded path when switching tasks", %{
      conn: conn,
      timing: timing,
      encoded_path: encoded_path
    } do
      {:ok, view, _html} = live(conn, encoded_path)

      render_click(element(view, "#pattern-task-alignment"))

      assert_patched(view, "#{encoded_path}?task=alignment&timing=#{timing.id}")
      assert has_element?(view, "#pattern-task-alignment[aria-current='page']")
    end
  end

  describe "timing summaries" do
    setup :editor_scope

    test "loads timing summaries and only the selected timing's rows",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "TIMING1")
      stops = Enum.map(1..3, &stop(organization, version, "TIMING1", &1, "Timing Stop #{&1}"))

      pattern = pattern(organization, version, route, "P-TIMING", route_pattern_name: "Timing")
      pattern_occurrences = occurrences(pattern, stops)

      selected =
        timing(pattern, pattern_occurrences, %{
          name: "Weekday",
          arrival_offset: 60,
          departure_offset: 60
        })

      timing(pattern, pattern_occurrences, %{
        name: "Weekend",
        arrival_offset: 0,
        departure_offset: 0
      })

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      assert has_element?(view, "#pattern-task-timings[aria-current='page']")
      assert has_element?(view, "#timing-select")
      assert has_element?(view, "#timing-select option[value='#{selected.id}'][selected]")

      assigns = :sys.get_state(view.pid).socket.assigns

      assert length(assigns.timings) == 2

      assert Enum.all?(assigns.timings, fn summary ->
               not Ecto.assoc_loaded?(summary.timing.timed_pattern_stops) and
                 not Ecto.assoc_loaded?(summary.timing.route_pattern)
             end)

      assert assigns.selected_timing.id == selected.id
      assert length(assigns.selected_timing_rows) == 3

      assert Enum.map(assigns.selected_timing_rows, & &1.position) == [1, 2, 3]
      assert has_element?(view, "#timing-rows", "Timing Stop 1")
      assert has_element?(view, "#timing-arrival-1[value='01:00']")
      assert has_element?(view, "#timing-departure-1[value='01:00']")
      refute has_element?(view, "#timing-arrival-1[value='00:00']")
    end

    test "a timing belonging to another pattern is refused with an error, not a leak",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "TIMING2")
      other_route = route(organization, version, "TIMING2B")
      stops = Enum.map(1..2, &stop(organization, version, "TIMING2", &1))
      other_stops = Enum.map(1..2, &stop(organization, version, "TIMING2B", &1))

      pattern = pattern(organization, version, route, "P-MINE", route_pattern_name: "Mine")
      mine_occurrences = occurrences(pattern, stops)
      timing(pattern, mine_occurrences, %{name: "Mine timing"})

      other =
        pattern(organization, version, other_route, "P-THEIRS", route_pattern_name: "Theirs")

      other_occurrences = occurrences(other, other_stops)
      other_timing = timing(other, other_occurrences, %{name: "Theirs timing"})

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      render_change(view, "select_timing", %{"timing_id" => other_timing.id})

      assert has_element?(view, "#error", "not part of this pattern")
      refute render(view) =~ "Theirs timing"
      assert :sys.get_state(view.pid).socket.assigns.selected_timing.name == "Mine timing"
    end
  end

  describe "scope and access" do
    setup :editor_scope

    test "a pattern from another route or version returns not found",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "SCOPE1")
      other_route = route(organization, version, "SCOPE2")
      other_version = gtfs_version_fixture(organization.id)
      other_version_route = route(organization, other_version, "SCOPE1")

      other_stops = Enum.map(1..2, &stop(organization, version, "SCOPE2", &1))

      foreign = pattern(organization, version, other_route, "P-FOREIGN")
      occurrences(foreign, other_stops)

      cross_version_stops = Enum.map(1..2, &stop(organization, other_version, "SCOPE1", &1))

      cross_version =
        pattern(organization, other_version, other_version_route, "P-XVERSION")

      occurrences(cross_version, cross_version_stops)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, pattern_path(version, route, foreign))

      assert to == patterns_path(version, route)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, pattern_path(version, route, cross_version))

      assert to == patterns_path(version, route)
    end

    test "unauthenticated sessions cannot reach the pattern routes",
         %{organization: organization, version: version} do
      route = route(organization, version, "SCOPE3")

      conn =
        build_conn()
        |> init_test_session(%{})

      conn = get(conn, patterns_path(version, route))
      assert redirected_to(conn) == "/users/log_in"
    end

    test "members without the editor role cannot reach the pattern routes",
         %{conn: conn, organization: organization, version: version} do
      member =
        user_fixture(%{email: "pattern-member-#{System.unique_integer([:positive])}@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: member.id,
        organization_id: organization.id,
        roles: []
      })

      route = route(organization, version, "SCOPE4")
      member_conn = log_in_user(conn, member, organization: organization)

      assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
               live(member_conn, patterns_path(version, route))
    end
  end

  describe "dirty navigation" do
    setup :editor_scope

    test "both version-switch events require an explicit discard while dirty",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "DIRTY1")
      other_version = gtfs_version_fixture(organization.id)

      {:ok, view, _html} = live(conn, new_pattern_path(version, route))

      refute has_element?(view, "#discard-changes-dialog[data-open='true']")

      render_change(view, "validate_details", %{"pattern" => %{"name" => "Unsaved"}})
      assert has_element?(view, "#edit-status", "Unsaved changes")

      render_click(view, "switch_gtfs_version", %{"version" => other_version.id})

      assert has_element?(
               view,
               "#discard-changes-dialog[data-open='true']",
               "Discard unsaved changes"
             )

      assert has_element?(view, "#discard-changes-dialog-cancel", "Keep editing")

      render_click(element(view, "#discard-changes-dialog-cancel"))
      refute has_element?(view, "#discard-changes-dialog[data-open='true']")
      assert has_element?(view, "#pattern-details-name[value='Unsaved']")

      render_click(view, "gtfs_version_loaded", %{"version_id" => other_version.id})

      assert has_element?(view, "#discard-changes-dialog[data-open='true']")

      render_click(view, "discard_changes")

      assert_redirect(view, "/gtfs/#{other_version.id}/routes/#{route.route_id}/patterns/new")
    end

    test "an unchanged page switches versions without a confirmation",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "DIRTY2")
      other_version = gtfs_version_fixture(organization.id)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      render_click(view, "switch_gtfs_version", %{"version" => other_version.id})

      assert_redirect(view, "/gtfs/#{other_version.id}/routes/#{route.route_id}/patterns")
    end

    test "a task switch keeps staged details instead of discarding them",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "DIRTY3")
      stops = Enum.map(1..2, &stop(organization, version, "DIRTY3", &1))

      pattern = pattern(organization, version, route, "P-DIRTY", route_pattern_name: "Kept")
      pattern_occurrences = occurrences(pattern, stops)
      timing(pattern, pattern_occurrences, %{name: "Weekday"})

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=details"))

      render_change(view, "validate_details", %{"pattern" => %{"name" => "Kept after"}})
      assert has_element?(view, "#edit-status", "Unsaved changes")

      render_click(element(view, "#pattern-task-stops"))
      assert has_element?(view, "#pattern-task-stops[aria-current='page']")

      render_click(element(view, "#pattern-task-details"))
      assert has_element?(view, "#pattern-details-name[value='Kept after']")
      assert has_element?(view, "#edit-status", "Unsaved changes")
    end
  end
end
