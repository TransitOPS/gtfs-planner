defmodule GtfsPlannerWeb.Gtfs.TimetableComparisonLiveTest do
  @moduledoc """
  Step 8 (EV-8): the provider-independent approved comparison on the ordinary
  Paste page.

  Every test drives production composition: the real Paste route, the real
  `#paste-form` read, the real `#timetable-source-form` submit, the real
  `#timetable-compare` click and the real `TimetableComparison` loader behind
  them. The helper is never opened, so the comparison is proved to work with the
  provider path unused; the one place the pack is exercised drives
  `Dispatch.call/4` on the registered pack with the page's own scope, which is
  the same call the panel makes.

  The expected numbers are written by hand from the fixture below. The shared
  fixture is one route, one weekday calendar (Monday to Friday, 2026-01-01 to
  2026-12-31) with Thanksgiving 2026-11-26 removed, one three-stop pattern
  with typical offsets 0/300/600 and two existing trips at 06:00 and 07:00. A
  source reviewed over 2026-11-02 through 2026-11-30 with Thanksgiving removed
  covers exactly 20 service dates, the feed runs both trips on exactly those 20,
  and every pasted clock is the clock the feed stores, so both pasted rows match
  on every date: 40 matched trip-date pairs and nothing else. Adding one trip
  nobody in the source names makes 20 of those pairs missing, and ten thousand
  and one extra trips on the route exceed the loader's own work ceiling.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # The over-cap case inserts the loader's own trip ceiling directly.
  @moduletag timeout: 240_000

  @first_date "2026-11-02"
  @last_date "2026-11-30"
  @thanksgiving "2026-11-26"
  @async_timeout 30_000
  @calendar "CMP_WKD"
  @pattern "CMP-MAIN"
  @first_trip "CMP_T360"
  @second_trip "CMP_T420"

  setup do
    organization =
      organization_fixture(%{alias: "timetable-cmp-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "timetable-cmp-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(build_conn(), user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  describe "the approved comparison with the helper unused" do
    test "compares the accepted source, states the server's own totals and writes nothing",
         context do
      route = comparison_route(context)
      {:ok, view, _html} = live(context.conn, paste_path(context.version, route))
      view = read_and_accept(view)

      # The helper was never opened, so nothing about this answer came from a
      # model: the card is reachable and the panel is closed (AC-16).
      refute has_element?(view, "#agent-panel")

      assert has_element?(view, "#timetable-compare")
      assert has_element?(view, "#timetable-comparison", "Not compared yet")
      assert has_element?(view, "#timetable-comparison-freshness")

      before_writes = written_counts(context)

      view = compare(view)

      # Both pasted rows resolved to an existing feed trip and every supplied
      # clock equals it, so the reviewed 20 dates are 40 matched trip-date
      # pairs with nothing missing, extra, mismatched, unresolved or excluded.
      assert has_element?(view, "#timetable-comparison-clean")

      assert has_element?(
               view,
               "#timetable-comparison-clean",
               "Every compared trip-date pair matches the feed"
             )

      assert has_element?(view, "#timetable-comparison-total-matched", "40")
      assert has_element?(view, "#timetable-comparison-total-missing", "0")
      assert has_element?(view, "#timetable-comparison-total-extra", "0")
      assert has_element?(view, "#timetable-comparison-total-time_mismatch", "0")
      assert has_element?(view, "#timetable-comparison-total-date_mismatch", "0")

      assert has_element?(
               view,
               "#timetable-comparison-checked",
               "compared against the feed just now"
             )

      assert has_element?(
               view,
               "#timetable-comparison-sample",
               "0 in the whole comparison, 0 retained as examples, 0 shown on page 1"
             )

      # A clean comparison reads the feed and stores nothing at all.
      assert written_counts(context) == before_writes
    end

    test "pages fifty of fifty-one witnesses honestly and pages through them", context do
      route = long_interval_route(context)
      {:ok, view, _html} = live(context.conn, paste_path(context.version, route))

      # The source lists exactly the one date the feed runs, so the 51 other
      # feed dates of the reviewed interval are 51 missing trip-date pairs and
      # 51 explicit date differences.
      interval_end = last_weekday_with(@first_date, 52)

      render_submit(view, "read", %{
        "paste" => %{"text" => single_row_text(), "layout" => "auto", "header" => "true"}
      })

      render_submit(view, "source_review", %{
        "source" =>
          source_params(%{
            "date_policy" => "school",
            "weekdays" => [],
            "school_dates" => @first_date,
            "first_date" => @first_date,
            "last_date" => Date.to_iso8601(interval_end)
          })
      })

      assert has_element?(view, "#timetable-source-accepted", "1 service date")

      view = compare(view)

      assert has_element?(view, "#timetable-comparison-differences")
      refute has_element?(view, "#timetable-comparison-clean")
      assert has_element?(view, "#timetable-comparison-total-missing", "51")
      assert has_element?(view, "#timetable-comparison-total-matched", "1")

      # The whole comparison is 51, the bounded sample kept all 51, and this
      # page shows 50 of them: the display limit is stated, not implied.
      assert has_element?(
               view,
               "#timetable-comparison-sample",
               "51 in the whole comparison, 51 retained as examples, 50 shown on page 1"
             )

      assert has_element?(view, "#timetable-comparison-next")

      view |> element("#timetable-comparison-next") |> render_click()
      render_async(view, @async_timeout)

      assert has_element?(
               view,
               "#timetable-comparison-sample",
               "1 shown on page 2"
             )

      refute has_element?(view, "#timetable-comparison-next")
    end

    test "an unresolved cell and an out-of-interval date never read as a match", context do
      route = comparison_route(context)
      {:ok, view, _html} = live(context.conn, paste_path(context.version, route))

      # "TBD" is not a clock this timetable can read, and the added date is
      # outside the interval, so the source is accepted with two disclosures
      # and the comparison must not read clean (AC-12, INV-3).
      render_submit(view, "read", %{
        "paste" => %{"text" => unresolved_text(), "layout" => "auto", "header" => "true"}
      })

      render_submit(view, "source_review", %{
        "source" => source_params(%{"added_dates" => "2026-10-05"})
      })

      assert has_element?(view, "#timetable-source-accepted")
      assert has_element?(view, "#timetable-source-unresolved", "TBD")

      view = compare(view)

      refute has_element?(view, "#timetable-comparison-clean")
      assert has_element?(view, "#timetable-comparison-differences")

      assert has_element?(
               view,
               "#timetable-comparison-differences",
               "could not be read as a match"
             )

      assert has_element?(view, "#timetable-comparison-unresolved", "unknown_source_clock")

      # The row whose clock could not be read is disclosed rather than matched,
      # and the other row's dates still match exactly.
      assert has_element?(view, "#timetable-comparison-total-matched", "20")
    end

    test "a scope larger than the loader's own work ceiling is refused, never matched",
         context do
      route = comparison_route(context)
      {:ok, view, _html} = live(context.conn, paste_path(context.version, route))
      view = read_and_accept(view)

      # Ten thousand and one extra trips is one more than the loader's own trip
      # ceiling, so it refuses the whole scope instead of answering about part
      # of it. They are committed after the source was accepted, so nothing about
      # the reviewed mapping changes.
      seed_bulk_trips(context, route, 10_001)

      view = compare(view)

      assert has_element?(view, "#timetable-comparison-unavailable")
      assert has_element?(view, "#timetable-comparison-unavailable", "10003 trips in scope")
      refute has_element?(view, "#timetable-comparison-clean")
      refute has_element?(view, "#timetable-comparison-totals")
    end
  end

  describe "the comparison lifecycle" do
    test "an edited source, a reopened drawer and a rerun leave only the current result",
         context do
      route = comparison_route(context)
      {:ok, view, _html} = live(context.conn, paste_path(context.version, route))
      view = read_and_accept(view)

      view = compare(view)
      assert has_element?(view, "#timetable-comparison-clean")

      # Editing the accepted source releases it, so the report that described
      # it is gone with it and a task still in flight cannot put it back.
      render_change(view, "source_change", %{
        "source" => source_params(%{"notes" => "Corrected."})
      })

      refute has_element?(view, "#timetable-comparison-clean")
      refute has_element?(view, "#timetable-comparison-totals")

      # Neither closing and reopening the schedule drawer nor opening the helper
      # can restore it.
      render_click(view, "open_scope_drawer", %{})
      assert has_element?(view, "#timetable-source-form")
      render_click(view, "close_scope_drawer", %{})

      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")
      view |> element("#agent-panel-close") |> render_click()

      refute has_element?(view, "#timetable-comparison-totals")
      refute has_element?(view, "#timetable-comparison-clean")
      assert has_element?(view, "#timetable-comparison", "Accept the reviewed source")

      # The source is accepted again with a different interval and the rerun
      # answers for that source alone.
      render_submit(view, "source_review", %{
        "source" =>
          source_params(%{
            "label" => "Harbor printed table",
            "notes" => "Corrected.",
            "removed_dates" => "",
            "first_date" => "2026-12-01",
            "last_date" => "2026-12-04"
          })
      })

      assert has_element?(view, "#timetable-source-accepted", "4 service dates")

      view = compare(view)

      assert has_element?(view, "#timetable-comparison-clean", "8 trip-date pairs match")
      assert has_element?(view, "#timetable-comparison-total-matched", "8")
      # The earlier report's 40 pairs are gone for good.
      refute has_element?(view, "#timetable-comparison-total-matched", "40")
    end

    test "accepting an edited source marks the report stale instead of leaving it current",
         context do
      route = comparison_route(context)
      {:ok, view, _html} = live(context.conn, paste_path(context.version, route))
      view = read_and_accept(view)

      view = compare(view)
      assert has_element?(view, "#timetable-comparison-total-matched", "40")

      render_submit(view, "source_review", %{
        "source" => source_params(%{"notes" => "Friday corrected."})
      })

      # The source is half of what the report was read against, so the numbers
      # stay on screen beside the notice that they describe the source as it
      # was accepted.
      assert has_element?(view, "#timetable-comparison-stale", "edited source")
      assert has_element?(view, "#timetable-comparison-total-matched", "40")
      refute has_element?(view, "#timetable-comparison-clean")

      # The rerun replaces the stale report with one for the accepted source.
      view = compare(view)
      assert has_element?(view, "#timetable-comparison-total-matched", "40")
      refute has_element?(view, "#timetable-comparison-stale")
    end

    test "a committed feed change makes the report stale and a rerun shows the new numbers",
         context do
      {route, pattern} = comparison_route_with_pattern(context)
      {:ok, view, _html} = live(context.conn, paste_path(context.version, route))
      view = read_and_accept(view)

      view = compare(view)
      assert has_element?(view, "#timetable-comparison-clean")

      # A trip nobody in the accepted source names is committed to the route's
      # own feed, so the report's digest no longer describes the feed.
      add_trip(context, pattern, route, "CMP_T480", "08:00:00")

      view = check_freshness(view)

      assert has_element?(view, "#timetable-comparison-stale")

      assert has_element?(
               view,
               "#timetable-comparison-stale",
               "The feed changed after this comparison ran"
             )

      # The stale report keeps the numbers it found, beside the notice that
      # they describe a feed this page has not re-read.
      assert has_element?(view, "#timetable-comparison-total-matched", "40")
      refute has_element?(view, "#timetable-comparison-clean")

      view = compare(view)

      assert has_element?(view, "#timetable-comparison-differences", "20 differences")
      assert has_element?(view, "#timetable-comparison-total-matched", "40")
      assert has_element?(view, "#timetable-comparison-total-missing", "20")
      refute has_element?(view, "#timetable-comparison-stale")
    end
  end

  describe "the read-only pack comparison" do
    test "answers from the same server report the page shows, whatever the model says",
         context do
      {route, pattern} = comparison_route_with_pattern(context)
      {:ok, view, _html} = live(context.conn, paste_path(context.version, route))
      view = read_and_accept(view)

      add_trip(context, pattern, route, "CMP_T480", "08:00:00")

      view = compare(view)
      assert has_element?(view, "#timetable-comparison-differences")

      # The same tool the panel calls, through the dispatch fence, on the
      # page's own accepted source context.
      assert {:ok, result, evidence} =
               Agents.Dispatch.call(
                 agents_packs(),
                 pack_scope(view),
                 "compare_approved_timetable",
                 "{}"
               )

      assert result["clean"] == false
      assert result["computation"] == "complete"
      assert get_in(result, ["totals", "matched", "total"]) == 40
      assert get_in(result, ["totals", "missing", "total"]) == 20
      assert get_in(result, ["totals", "matched", "unit"]) == "trip-date pairs"

      # The card's numbers are the report's own, and its links are the existing
      # typed route reference: nothing a model says creates a URL (AC-15).
      assert evidence.total == 20
      assert evidence.total_label == "differences against the current feed"
      assert [%{kind: "route", id: "CMP1"}] = evidence.resources
      assert evidence.digest == socket_assigns(view).timetable_comparison.source_digest

      for value <- tool_strings(result) ++ tool_strings(evidence) do
        refute value =~ "http"
      end
    end

    test "refuses an identity or source argument it does not declare", context do
      route = comparison_route(context)
      {:ok, view, _html} = live(context.conn, paste_path(context.version, route))
      view = read_and_accept(view)

      assert {:tool_error, message} =
               Agents.Dispatch.call(
                 agents_packs(),
                 pack_scope(view),
                 "compare_approved_timetable",
                 Jason.encode!(%{"route_id" => "CMP1"})
               )

      assert message =~ "route_id"
    end
  end

  # --- Fixtures ---------------------------------------------------------------

  # One route, one weekday calendar, one three-stop outbound pattern and the two
  # trips the pasted rows ask for, so each pasted row resolves to exactly one
  # feed trip and every supplied clock is one the feed already stores.
  defp comparison_route(context) do
    {route, _bundle} = comparison_route_with_pattern(context)
    route
  end

  defp comparison_route_with_pattern(context) do
    route =
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "CMP1",
        route_short_name: "14",
        route_long_name: "Harbor – Union"
      })

    calendar_fixture(context.organization.id, context.version.id, %{service_id: @calendar})

    calendar_attribute_fixture(context.organization.id, context.version.id, %{
      service_id: @calendar,
      service_description: "Weekday",
      service_schedule_name: "Weekday"
    })

    # The feed really does not run Thanksgiving, so a source that removes that
    # date agrees with it rather than inventing a difference.
    calendar_date_fixture(context.organization.id, context.version.id, %{
      service_id: @calendar,
      date: Date.from_iso8601!(@thanksgiving),
      exception_type: 2
    })

    Enum.each(1..3, fn index ->
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "CMP_S#{index}",
        stop_name: "Comparison Stop #{index}"
      })
    end)

    pattern =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: @pattern,
        route_pattern_name: "Main",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"CMP_S1", 0, 0, 1},
          {"CMP_S2", 300, 300, 1},
          {"CMP_S3", 600, 600, 1}
        ]
      })

    Enum.each([{@first_trip, "06:00:00"}, {@second_trip, "07:00:00"}], fn {trip_id, start} ->
      schedule_trip_fixture(
        context.organization.id,
        context.version.id,
        route.route_id,
        pattern,
        %{
          service_id: @calendar,
          trip_id: trip_id,
          start_time: start,
          trip_headsign: "Union Depot"
        }
      )
    end)

    {route, pattern}
  end

  # The same route with one trip and one calendar that runs every weekday of
  # the year, so a source listing one date of a long interval leaves exactly
  # 51 feed dates it does not list.
  defp long_interval_route(context) do
    route =
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "CMP2",
        route_short_name: "15"
      })

    calendar_fixture(context.organization.id, context.version.id, %{
      service_id: @calendar,
      start_date: Date.from_iso8601!("2026-01-01"),
      end_date: Date.from_iso8601!("2027-12-31")
    })

    Enum.each(1..3, fn index ->
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "CMP_S#{index}",
        stop_name: "Comparison Stop #{index}"
      })
    end)

    pattern =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: @pattern,
        route_pattern_name: "Main",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"CMP_S1", 0, 0, 1},
          {"CMP_S2", 300, 300, 1},
          {"CMP_S3", 600, 600, 1}
        ]
      })

    schedule_trip_fixture(context.organization.id, context.version.id, route.route_id, pattern, %{
      service_id: @calendar,
      trip_id: @first_trip,
      start_time: "06:00:00",
      trip_headsign: "Union Depot"
    })

    route
  end

  defp add_trip(context, pattern, route, trip_id, start_time) do
    schedule_trip_fixture(context.organization.id, context.version.id, route.route_id, pattern, %{
      service_id: @calendar,
      trip_id: trip_id,
      start_time: start_time,
      trip_headsign: "Union Depot"
    })
    |> Map.fetch!(:trip)
  end

  # The loader reads its trips from the route's own scope, so the ceiling is
  # exercised with real rows on that route rather than with a stubbed limit.
  defp seed_bulk_trips(context, route, count) do
    now = DateTime.utc_now()

    rows =
      Enum.map(0..(count - 1), fn index ->
        %{
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          route_id: route.route_id,
          service_id: @calendar,
          trip_id: "CMP_BULK_#{index}",
          direction_id: 0,
          route_pattern_id: @pattern,
          inserted_at: now,
          updated_at: now
        }
      end)

    rows
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Repo.insert_all(Trip, &1))
  end

  defp paste_path(version, route),
    do: "/gtfs/#{version.id}/routes/#{route.route_id}/schedules/paste"

  defp exact_text do
    "Trip\tComparison Stop 1\tComparison Stop 2\tComparison Stop 3\n" <>
      "101\t06:00\t06:05\t06:10\n102\t07:00\t07:05\t07:10"
  end

  defp single_row_text do
    "Trip\tComparison Stop 1\tComparison Stop 2\tComparison Stop 3\n" <>
      "101\t06:00\t06:05\t06:10"
  end

  defp unresolved_text do
    "Trip\tComparison Stop 1\tComparison Stop 2\tComparison Stop 3\n" <>
      "101\t06:00\t06:05\tTBD\n102\t07:00\t07:05\t07:10"
  end

  defp read_and_accept(view) do
    render_submit(view, "read", %{
      "paste" => %{"text" => exact_text(), "layout" => "auto", "header" => "true"}
    })

    render_submit(view, "source_review", %{"source" => source_params(%{})})

    assert has_element?(view, "#timetable-source-accepted")

    view
  end

  defp source_params(overrides) do
    Map.merge(
      %{
        "label" => "Harbor printed table",
        "revision" => "rev 3",
        "notes" => "",
        "first_date" => @first_date,
        "last_date" => @last_date,
        "date_policy" => "weekly",
        "weekdays" => ~w(1 2 3 4 5),
        "school_dates" => "",
        "added_dates" => "",
        "removed_dates" => @thanksgiving,
        "confirm" => "true"
      },
      overrides
    )
  end

  # The last date of the interval that holds exactly `count` ISO weekdays, from
  # the fixture calendar's own Monday-to-Friday service.
  defp last_weekday_with(first, count) do
    first = Date.from_iso8601!(first)

    first
    |> Date.range(Date.add(first, count * 7))
    |> Enum.filter(&(Date.day_of_week(&1) in [1, 2, 3, 4, 5]))
    |> Enum.take(count)
    |> List.last()
  end

  defp written_counts(context) do
    %{
      trips: Repo.aggregate(count_query(Trip, context), :count),
      change_logs: Repo.aggregate(count_query(ChangeLog, context), :count)
    }
  end

  defp count_query(schema, context) do
    from(row in schema,
      where:
        row.organization_id == ^context.organization.id and
          row.gtfs_version_id == ^context.version.id
    )
  end

  # The comparison runs in the page's own task, so the click returns before its
  # result lands; the task is waited for rather than assumed.
  defp compare(view) do
    view |> element("#timetable-compare") |> render_click()
    render_async(view, @async_timeout)
    view
  end

  defp check_freshness(view) do
    view |> element("#timetable-comparison-freshness") |> render_click()
    render_async(view, @async_timeout)
    view
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp agents_packs, do: GtfsPlanner.Agents.Packs.Timetables

  defp pack_scope(view) do
    %Scope{
      organization_id: socket_assigns(view).current_organization.id,
      gtfs_version_id: socket_assigns(view).current_gtfs_version.id,
      user_id: socket_assigns(view).current_user.id,
      user_email: socket_assigns(view).current_user.email,
      pack_id: "timetables",
      version_name: socket_assigns(view).current_gtfs_version.name,
      resource_context: socket_assigns(view).agent_context
    }
  end

  defp tool_strings(term) when is_binary(term), do: [term]
  defp tool_strings(term) when is_atom(term), do: []
  defp tool_strings(term) when is_number(term), do: []

  defp tool_strings(term) when is_list(term), do: Enum.flat_map(term, &tool_strings/1)

  defp tool_strings(%_{} = struct),
    do: struct |> Map.from_struct() |> Map.values() |> tool_strings()

  defp tool_strings(term) when is_map(term), do: term |> Map.values() |> tool_strings()
end
