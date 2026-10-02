defmodule GtfsPlanner.Gtfs.TimetableComparisonTest do
  @moduledoc """
  Merge evidence (EV-7) for `TimetableComparison.compare/2`, `page/3` and
  `fresh_digest/2`: the deterministic reconciliation of one accepted approved
  source against one coherent feed snapshot.

  The five cases are the ones the step's execution card names:

    * the production entrypoint `compare/2` reconciles a hand-written
      2026-11-25..27 source against a weekday calendar removed on Thanksgiving
      plus an exception-only calendar that adds it back, and the Thanksgiving
      date difference is an explicit `date_mismatch`;
    * explicit school dates `[2026-11-25, 2026-11-27]` exclude Thanksgiving
      without a weekday guess, while a school policy with no supplied list stays
      unresolved and can never read as all matched;
    * a loop trip's first and second stop occurrence and its arrival and
      departure are compared separately, `24:10` differs from `00:10`, and a
      missing intermediate clock stays unknown rather than borrowing the other
      event;
    * exact and non-exact frequency windows stay typed exclusions that never
      become exact matches, and a duplicated source row or an ambiguous trip
      mapping produces unresolved witnesses;
    * more than the 50 witnesses of a page keep exact totals above the 500
      witness retention limit, with deterministic pages and a complete
      computation.

  Every expected value is written by hand from the GTFS Schedule reference and
  the fixture calendars, never from another call into the module under test:
  `WEEKDAY` runs Monday to Friday with the Thanksgiving removal, so 2026-11-25
  and 2026-11-27 are weekday service and 2026-11-26 is not; `HOLIDAY` has no
  weekly row and adds exactly 2026-11-26. `07:15:00` is 26,100 service-day
  seconds and `24:30:00` is 88,200, so a source reading of 00:10 (600) is a
  different clock, not the same one (AC-10, AC-11, AC-12, AC-13).
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimetableComparison
  alias GtfsPlanner.Gtfs.TimetableSource
  alias GtfsPlanner.Gtfs.Trip

  # The bulk-mismatch case inserts 260 trips and 260 stop times directly, so it
  # carries its own finite budget; the rest of the file runs in seconds.
  @moduletag timeout: 240_000

  @thanksgiving ~D[2026-11-26]
  @interval {~D[2026-11-25], ~D[2026-11-27]}
  @central "CENTRAL"
  @harbor "HARBOR"
  @loop "LOOP"

  describe "case 1: a reviewed interval against a removed weekday and an exception-only service" do
    setup do
      %{scope: harbor_scope()}
    end

    test "reconciles the hand-written date, occurrence and clock matrix", %{scope: scope} do
      source = accepted_source(weekday_params())

      assert {:ok, report} = TimetableComparison.compare(scope_of(scope), source)

      # The report identifies both sides: the reviewed source digest and the
      # exact feed content it was computed from.
      assert report.source_digest == source.digest
      assert report.feed_digest =~ ~r/\A[0-9a-f]{64}\z/
      assert report.interval == @interval

      # The scope is the route's seven `PA` inbound trips, narrowed by the
      # source's own reviewed direction and pattern.
      assert report.comparison_scope == %{
               route_id: "H8",
               direction_ids: [0],
               pattern_ids: ["PA"],
               source_rows: 3,
               feed_trips: 7
             }

      # The units are named, so a reader cannot sum overlapping categories into
      # an invented grand total.
      assert report.units == %{
               matched: "trip-date pairs",
               missing: "trip-date pairs",
               extra: "trip-date pairs",
               time_mismatch: "source cell, event and date comparisons",
               date_mismatch: "mapped trip and source row date differences"
             }

      # `WEEKDAY` runs 2026-11-25 and 2026-11-27 after the Thanksgiving
      # removal, and the source claims exactly those two dates. `H8-0715` and
      # `H8-0800` are therefore one matched pair on each date.
      assert report.totals.matched == 4

      # The source names `H8-1820`, which the exception-only calendar runs only
      # on Thanksgiving, so that date is missing; and it lists the two weekday
      # dates for it, which the feed does not run, so those are extra.
      # Three more weekday trips (`H8-UNLISTED`, `H8-LOOP`, `H8-LATE`) run both
      # dates and are named by nobody, which is six more missing pairs.
      assert report.totals.missing == 7
      assert report.totals.extra == 2

      # Every supplied clock the two listed weekday trips state equals the feed's.
      assert report.totals.time_mismatch == 0

      # `H8-1820` runs only the exception-only Thanksgiving date, so its mapped
      # trip differs on three dates: two the source added and one it left out.
      assert report.totals.date_mismatch == 3

      # Thanksgiving is missing from the source's own weekday claim, which is
      # exactly the difference this comparison exists to show.
      assert date_witnesses(report, :date_mismatch)
             |> Enum.map(& &1.date)
             |> Enum.uniq()
             |> Enum.sort() ==
               [~D[2026-11-25], ~D[2026-11-26], ~D[2026-11-27]]

      # The comparison is complete but not clean: the frequency trip's windows
      # are excluded, and nothing unresolved or excluded may read as all matched.
      assert report.computation == :complete
      refute report.clean?

      # The frequency templates are typed exclusions with their own window and
      # exactness, never expanded into matches or differences.
      assert length(report.exclusions) == 2

      assert Enum.sort(report.exclusions) ==
               [
                 {:frequency_template, "H8-FREQ", 72_000, 79_200, 1200, 0},
                 {:frequency_template, "H8-FREQ", 75_600, 79_200, 600, 1}
               ]

      assert Enum.sort(report.unresolved) == [
               {:frequency_template, "H8-FREQ", 0},
               {:frequency_template, "H8-FREQ", 1}
             ]

      # No frequency trip date leaked into matched, missing or extra, and no
      # frequency window was expanded into a departure.
      refute Enum.any?(Map.values(report.witnesses), fn witnesses ->
               Enum.any?(witnesses, &(&1.trip_id == "H8-FREQ"))
             end)

      refute Enum.any?(Map.values(report.witnesses), fn witnesses ->
               Enum.any?(witnesses, &is_integer(&1.source_clock))
             end)

      # Witnesses are sorted by date, then source row, then scoped trip id.
      assert Enum.map(report.witnesses.matched, &{&1.date, &1.source_row_id, &1.trip_id}) == [
               {~D[2026-11-25], 1, "H8-0715"},
               {~D[2026-11-25], 2, "H8-0800"},
               {~D[2026-11-27], 1, "H8-0715"},
               {~D[2026-11-27], 2, "H8-0800"}
             ]

      # Every matched witness names the pair it stands for, so a display can
      # render the row without re-reading the source.
      assert Enum.all?(report.witnesses.matched, &(&1.reason == :all_clocks_equal))

      # The comparison is read-only: the feed rows and the audit trail are
      # exactly what the fixture seeded.
      assert retained_counts(scope) == %{trips: 7, stop_times: 13, audit: 0}
    end

    test "the freshness digest follows the feed content, not a timestamp", %{scope: scope} do
      source = accepted_source(weekday_params())

      assert {:ok, first} = TimetableComparison.fresh_digest(scope_of(scope), source)
      assert {:ok, again} = TimetableComparison.fresh_digest(scope_of(scope), source)
      assert first == again

      assert {:ok, report} = TimetableComparison.compare(scope_of(scope), source)
      assert report.feed_digest == first

      # Moving one retained clock changes the exact content, so the digest
      # changes; a comparison taken before the move is detectably stale.
      Repo.update_all(
        from(s in StopTime,
          where:
            s.organization_id == ^scope.organization_id and
              s.gtfs_version_id == ^scope.gtfs_version_id and s.trip_id == "H8-0715" and
              s.stop_sequence == 1
        ),
        set: [departure_time: "07:16:00"]
      )

      refute TimetableComparison.fresh_digest(scope_of(scope), source) == {:ok, first}

      # An unaccepted source has no place in a freshness check either.
      assert {:error, :not_accepted} =
               TimetableComparison.fresh_digest(scope_of(scope), %{source | accepted?: false})
    end

    test "a foreign or revoked scope is refused before any comparison", %{scope: scope} do
      source = accepted_source(weekday_params())

      assert {:error, :not_found} =
               TimetableComparison.compare(
                 %{scope_of(scope) | route_id: Ecto.UUID.generate()},
                 source
               )

      assert {:error, :forbidden} =
               TimetableComparison.compare(
                 %{scope_of(scope) | actor_id: Ecto.UUID.generate()},
                 source
               )
    end
  end

  describe "case 2: explicit school dates, and a missing list" do
    setup do
      %{scope: harbor_scope()}
    end

    test "uses exactly the supplied school dates and never guesses Thanksgiving", %{scope: scope} do
      source = accepted_source(school_params())

      assert source.interval == @interval

      assert Enum.map(source.rows, & &1.dates) |> List.flatten() |> Enum.uniq() |> Enum.sort() ==
               [~D[2026-11-25], ~D[2026-11-27]]

      refute ~D[2026-11-26] in hd(source.rows).dates

      assert {:ok, report} = TimetableComparison.compare(scope_of(scope), source)

      # The same two weekday dates are matched, and Thanksgiving still differs
      # through the exception-only calendar rather than through a weekday rule.
      assert report.totals.matched == 4
      assert report.totals.date_mismatch == 3
      assert Enum.any?(report.witnesses.date_mismatch, &(&1.date == @thanksgiving))
      refute report.clean?
    end

    test "a school policy with no supplied list is unresolved and cannot be accepted", %{
      scope: scope
    } do
      params =
        weekday_params()
        |> Map.merge(%{
          "date_policy" => "school",
          "weekdays" => nil,
          "removed_dates" => [],
          "school_dates" => []
        })

      draft = draft_source(params)

      assert draft.unresolved == [{:missing_school_dates, @interval}]
      assert TimetableSource.blocking_reason?(hd(draft.unresolved))

      # It cannot be accepted, so no comparison may be built from it at all.
      assert {:error, {:unresolved, [{:missing_school_dates, @interval}]}} =
               TimetableSource.accept(draft, %{confirmed?: true})

      assert {:error, :not_accepted} = TimetableComparison.compare(scope_of(scope), draft)

      # Even if a host handed over a source flagged accepted, the absent school
      # list is a blocking reason: the computation is incomplete and no
      # all-match verdict is reachable from it.
      assert {:ok, report} =
               TimetableComparison.compare(scope_of(scope), %{draft | accepted?: true})

      assert report.computation == :incomplete
      refute report.clean?
      assert {:missing_school_dates, @interval} in report.unresolved
    end
  end

  describe "case 3: repeated occurrences, overnight clocks and unknown intermediates" do
    setup do
      %{scope: harbor_scope()}
    end

    test "compares each loop visit and each event separately", %{scope: scope} do
      source = accepted_source(loop_params())

      assert {:ok, report} = TimetableComparison.compare(scope_of(scope), source)

      # `H8-LOOP` visits CENTRAL, HARBOR and LOOP once and LOOP again, so the
      # source's two LOOP columns are two distinct occurrences of the same stop.
      occurrences =
        source.rows
        |> hd()
        |> Map.fetch!(:cells)
        |> Enum.map(& &1.occurrence)

      assert occurrences == [
               %{stop_id: @central, stop_sequence: 1},
               %{stop_id: @harbor, stop_sequence: 2},
               %{stop_id: @loop, stop_sequence: 3},
               %{stop_id: @loop, stop_sequence: 4}
             ]

      assert length(Enum.uniq(occurrences)) == 4

      # `H8-LOOP` departs CENTRAL after midnight on both reviewed dates, so
      # every cell of every mapped occurrence differs on both dates: four
      # occurrences, two events each, two dates.
      assert report.totals.matched == 0
      assert report.totals.time_mismatch == 16

      assert report.witnesses.time_mismatch
             |> Enum.map(& &1.stop_sequence)
             |> Enum.uniq()
             |> Enum.sort() ==
               [1, 2, 3, 4]

      # The last LOOP visit is the case the spec names: the source claims 24:10,
      # which is 87,000 service-day seconds, where the feed reads 00:10, which is
      # 600. They are different clocks, not the same one after midnight.
      final =
        Enum.find(report.witnesses.time_mismatch, fn witness ->
          witness.stop_sequence == 4 and witness.date == ~D[2026-11-25]
        end)

      assert final.trip_id == "H8-LOOP"
      assert final.event == :arrival
      assert final.source_clock == 87_000
      assert final.feed_clock == 600
      assert final.reason == :clock_differs

      # Arrival and departure of that one occurrence are two comparisons, so the
      # departure is a difference of its own rather than a repeat of the arrival.
      departure =
        Enum.find(report.witnesses.time_mismatch, fn witness ->
          witness.stop_sequence == 4 and witness.event == :departure and
            witness.date == ~D[2026-11-25]
        end)

      assert departure.source_clock == 87_000
      assert departure.feed_clock == 600

      assert report.computation == :complete
      refute report.clean?
    end

    test "a source clock that cannot be read is unresolved, never a match", %{scope: scope} do
      source = accepted_source(unreadable_clock_params())

      assert {:ok, report} = TimetableComparison.compare(scope_of(scope), source)

      # `H8-LATE` has no readable arrival, so the source's arrival claim has
      # nothing to equal and the pair cannot be matched. It is not a difference
      # either: nobody stated two different readable times.
      assert report.totals.matched == 0
      assert report.totals.time_mismatch == 0
      assert report.totals.extra == 0

      # Every other feed trip in the requested scope is listed by nobody: the two
      # reviewed weekday trips and the unlisted and loop trips on both dates, plus
      # the exception-only trip on Thanksgiving.
      assert report.totals.missing == 9

      assert {:unreadable_feed_clock, 1, "H8-LATE", @central, 1, :arrival} in report.unresolved

      refute report.clean?
    end
  end

  describe "case 4: frequency templates, duplicated rows and ambiguous mappings" do
    setup do
      %{scope: harbor_scope()}
    end

    test "both frequency windows stay excluded and never match", %{scope: scope} do
      source = accepted_source(weekday_params())
      assert {:ok, report} = TimetableComparison.compare(scope_of(scope), source)

      assert Enum.sort(report.exclusions) == [
               {:frequency_template, "H8-FREQ", 72_000, 79_200, 1200, 0},
               {:frequency_template, "H8-FREQ", 75_600, 79_200, 600, 1}
             ]

      # The frequency trip runs the two weekday dates, but because its departures
      # are templates it contributes no matched, missing or extra pair.
      assert report.totals.matched == 4
      assert report.totals.missing == 7
      assert report.totals.extra == 2
    end

    test "two source rows mapped to one trip are unresolved, never deduplicated", %{scope: scope} do
      params =
        weekday_params()
        |> put_in(["mapping", "rows"], %{
          "1" => %{"feed_trip_id" => "H8-0715"},
          "2" => %{"feed_trip_id" => "H8-0715"},
          "3" => %{"feed_trip_id" => "H8-0800"}
        })

      draft = draft_source(params)

      assert draft.unresolved == [{:duplicate_feed_trip, "H8-0715"}]
      assert TimetableSource.blocking_reason?({:duplicate_feed_trip, "H8-0715"})

      # A duplicate is a blocking reason, so no accepted source can carry one.
      # The comparator still discloses it if one is presented, so a duplicated
      # pair can never quietly read as two independent comparisons.
      assert {:error, {:unresolved, [{:duplicate_feed_trip, "H8-0715"}]}} =
               TimetableSource.accept(draft, %{confirmed?: true})

      assert {:error, :not_accepted} = TimetableComparison.compare(scope_of(scope), draft)
    end

    test "a mapped trip's Thanksgiving date difference is disclosed, not averaged away", %{
      scope: scope
    } do
      source = accepted_source(weekday_params())

      assert {:ok, report} = TimetableComparison.compare(scope_of(scope), source)

      thanksgiving =
        Enum.filter(report.witnesses.date_mismatch, &(&1.date == @thanksgiving))

      assert thanksgiving == [
               %{
                 category: :date_mismatch,
                 date: @thanksgiving,
                 source_row_id: 3,
                 trip_id: "H8-1820",
                 service_id: "HOLIDAY",
                 stop_id: nil,
                 stop_sequence: nil,
                 event: nil,
                 source_clock: nil,
                 feed_clock: nil,
                 reason: :missing_on_date
               }
             ]

      # The same Thanksgiving pair is also counted as one missing trip-date pair,
      # which is exactly the overlap the report's units declare.
      assert Enum.count(report.witnesses.missing, &(&1.date == @thanksgiving)) == 1

      assert report.computation == :complete
      refute report.clean?
    end
  end

  describe "case 5: exact totals with deterministic pages above the sample limit" do
    setup do
      %{scope: bulk_scope()}
    end

    test "counts every mismatch exactly while retaining only 500 witnesses", %{scope: scope} do
      source = accepted_source(bulk_params(), bulk_trip_scope())

      assert {:ok, report} = TimetableComparison.compare(scope_of(scope), source)

      # 260 weekday trips, each mapped to one occurrence whose arrival and
      # departure both claim 07:00 where the feed reads 07:15, on both reviewed
      # dates. Every one of those 1,040 event comparisons is a difference, so
      # the exact total is 1,040 while only 500 witnesses are retained.
      assert report.totals.time_mismatch == 1_040
      assert report.totals.matched == 0
      assert length(report.witnesses.time_mismatch) == 500

      # The retained sample is the first 500 in the deterministic sort order,
      # so the retained witness count and the exact total disagree honestly.
      assert {:ok, page} = TimetableComparison.page(report, :time_mismatch, 1)
      assert page.page_size == 50
      assert page.total == 1_040
      assert page.retained == 500
      assert length(page.witnesses) == 50

      # The retained 500 are the first 500 in sort order, so they are all on the
      # earlier date and run from the first source row to the two-hundred-and-fiftieth.
      assert Enum.uniq(Enum.map(page.witnesses, & &1.date)) == [~D[2026-11-25]]
      assert hd(page.witnesses).source_row_id == 1
      assert List.last(page.witnesses).source_row_id == 25

      assert {:ok, second} = TimetableComparison.page(report, :time_mismatch, 2)
      assert hd(second.witnesses).source_row_id == 26
      assert List.last(second.witnesses).source_row_id == 50

      # Ten full pages cover the retained sample exactly and the eleventh is empty,
      # because the sample stopped at 500 while the total did not: the retained
      # witnesses are the 250 earliest rows on the earlier date, so nothing from
      # the second reviewed date is displayed at all.
      assert {:ok, tenth} = TimetableComparison.page(report, :time_mismatch, 10)
      assert hd(tenth.witnesses).source_row_id == 226
      assert List.last(tenth.witnesses).source_row_id == 250

      assert {:ok, eleventh} = TimetableComparison.page(report, :time_mismatch, 11)
      assert eleventh.witnesses == []

      # A full page never implies a complete category, and an invented category
      # is refused rather than answered with an empty list.
      assert {:error, :unknown_category} = TimetableComparison.page(report, :invented, 1)
      assert {:error, :invalid_page} = TimetableComparison.page(report, :time_mismatch, 0)

      # A truncated witness sample is a display bound, not a computation bound:
      # the computation stayed complete and no all-match verdict is reachable.
      assert report.computation == :complete
      refute report.clean?
    end

    test "the same snapshot and source answer the same pages every time", %{scope: scope} do
      source = accepted_source(bulk_params(), bulk_trip_scope())

      assert {:ok, first} = TimetableComparison.compare(scope_of(scope), source)
      assert {:ok, second} = TimetableComparison.compare(scope_of(scope), source)

      assert second.feed_digest == first.feed_digest
      assert second.totals == first.totals
      assert second.witnesses == first.witnesses

      assert {:ok, page} = TimetableComparison.page(first, :time_mismatch, 3)
      assert {:ok, page_again} = TimetableComparison.page(second, :time_mismatch, 3)
      assert page == page_again
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # A holiday-replacement route: `WEEKDAY` is the recurring calendar removed on
  # Thanksgiving, `HOLIDAY` is exception-only, and the route runs two matched
  # weekday trips, one unlisted trip, one loop trip, one trip with an unreadable
  # arrival, one frequency trip and one exception-only trip.
  defp harbor_scope do
    organization = organization_fixture(%{alias: "ai04-step7-#{unique_suffix()}"})
    user = user_fixture(%{email: "ai04-step7-#{unique_suffix()}@example.com"})
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id)

    stop_fixture(organization.id, version.id, %{stop_id: @central, stop_name: "Central Station"})
    stop_fixture(organization.id, version.id, %{stop_id: @harbor, stop_name: "Harbor Yards"})
    stop_fixture(organization.id, version.id, %{stop_id: @loop, stop_name: "Loop Terminal"})

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})

    calendar_fixture(organization.id, version.id, weekday_calendar("WEEKDAY"))

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      date: @thanksgiving,
      exception_type: 2
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "HOLIDAY",
      date: @thanksgiving,
      exception_type: 1
    })

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: "PA",
        route_id: "H8",
        direction_id: 0,
        route_pattern_name: "Harbor inbound"
      })

    route_pattern_stop_fixture(pattern, @central, 1)
    route_pattern_stop_fixture(pattern, @harbor, 2)
    route_pattern_stop_fixture(pattern, @loop, 3)
    route_pattern_stop_fixture(pattern, @loop, 4)

    # Two listed weekday trips the source compares exactly.
    weekday_trip(organization.id, version.id, "H8-0715", pattern, [
      {@central, 1, "07:15:00", "07:15:00"},
      {@harbor, 2, "07:35:00", "07:35:00"}
    ])

    weekday_trip(organization.id, version.id, "H8-0800", pattern, [
      {@central, 1, "08:00:00", "08:00:00"},
      {@harbor, 2, "08:20:00", "08:20:00"}
    ])

    # An unlisted weekday trip: both of its dates are missing from the source.
    weekday_trip(organization.id, version.id, "H8-UNLISTED", pattern, [
      {@central, 1, "06:30:00", "06:30:00"}
    ])

    # A loop trip: the last occurrence is after midnight.
    weekday_trip(organization.id, version.id, "H8-LOOP", pattern, [
      {@central, 1, "24:10:00", "24:15:00"},
      {@harbor, 2, "24:20:00", "24:20:00"},
      {@loop, 3, "24:25:00", "24:25:00"},
      {@loop, 4, "00:10:00", "00:10:00"}
    ])

    # An unreadable arrival beside a readable after-midnight departure.
    weekday_trip(organization.id, version.id, "H8-LATE", pattern, [
      {@central, 1, nil, "24:30:00"}
    ])

    # A frequency trip with one exact and one non-exact window.
    weekday_trip(organization.id, version.id, "H8-FREQ", pattern, [
      {@harbor, 2, "20:00:00", "20:00:00"}
    ])

    frequency_fixture(organization.id, version.id, "H8-FREQ", %{
      start_time: "20:00:00",
      end_time: "22:00:00",
      headway_secs: 1200,
      exact_times: 0
    })

    frequency_fixture(organization.id, version.id, "H8-FREQ", %{
      start_time: "21:00:00",
      end_time: "22:00:00",
      headway_secs: 600,
      exact_times: 1
    })

    # The exception-only trip: Thanksgiving and nothing else.
    trip_for(organization.id, version.id, "H8-1820", pattern, %{service_id: "HOLIDAY"})
    |> seed_stop_times(organization.id, version.id, [
      {@central, 1, "18:20:00", "18:20:00"},
      {@harbor, 2, "18:40:00", "18:40:00"}
    ])

    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: user.id,
      route_id: route.id,
      organization: organization,
      membership: membership
    }
  end

  # 260 weekday trips, each with one occurrence whose two clocks the source
  # contradicts on both reviewed dates, so the mismatch total is 1,040: above the
  # 500-witness retention limit and above ten full pages of 50.
  defp bulk_scope do
    scope = harbor_scope()

    now = DateTime.utc_now()

    trips =
      for index <- 1..260 do
        %{
          id: Ecto.UUID.generate(),
          organization_id: scope.organization_id,
          gtfs_version_id: scope.gtfs_version_id,
          trip_id: "BULK-#{index}",
          route_id: "H8",
          service_id: "WEEKDAY",
          direction_id: 0,
          route_pattern_id: "PA",
          inserted_at: now,
          updated_at: now
        }
      end

    trips
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Repo.insert_all(Trip, &1))

    stop_times =
      for trip <- trips do
        %{
          id: Ecto.UUID.generate(),
          organization_id: scope.organization_id,
          gtfs_version_id: scope.gtfs_version_id,
          trip_id: trip.trip_id,
          stop_id: @central,
          stop_sequence: 1,
          arrival_time: "07:15:00",
          departure_time: "07:15:00",
          inserted_at: now,
          updated_at: now
        }
      end

    stop_times
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Repo.insert_all(StopTime, &1))

    scope
  end

  # `Gtfs.Trip.changeset/2` casts no `route_pattern_id`, so the reviewed pattern
  # is written onto the inserted trip the way pattern derivation writes it.
  defp trip_for(organization_id, version_id, trip_id, pattern, attrs) do
    organization_id
    |> trip_fixture(version_id, "H8", Map.put(attrs, :trip_id, trip_id))
    |> Ecto.Changeset.change(%{
      direction_id: pattern.direction_id,
      route_pattern_id: pattern.route_pattern_id
    })
    |> Repo.update!()
  end

  defp weekday_trip(organization_id, version_id, trip_id, pattern, stops) do
    trip_for(organization_id, version_id, trip_id, pattern, %{service_id: "WEEKDAY"})
    |> seed_stop_times(organization_id, version_id, stops)
  end

  defp seed_stop_times(trip, organization_id, version_id, stops) do
    Enum.each(stops, fn {stop_id, sequence, arrival, departure} ->
      stop_time_fixture(organization_id, version_id, trip.trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: arrival,
        departure_time: departure
      })
    end)

    trip
  end

  # Monday to Friday all year, with the Thanksgiving removal applied by the
  # fixture's `calendar_date`, so 2026-11-25 and 2026-11-27 are service and
  # 2026-11-26 is not.
  defp weekday_calendar(service_id) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    }
  end

  defp scope_of(scope) do
    %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      actor_id: scope.actor_id,
      route_id: scope.route_id
    }
  end

  # -- reviewed sources -------------------------------------------------------

  # The reviewed mapping is derived from the scoped feed rows the host would
  # already hold, so the source resolves the same trip ids the loader reads.
  defp native_scope(extra_trips) do
    %{
      patterns: [
        %{
          id: "PA",
          occurrences: [
            %{stop_id: @central, stop_sequence: 1},
            %{stop_id: @harbor, stop_sequence: 2},
            %{stop_id: @loop, stop_sequence: 3},
            %{stop_id: @loop, stop_sequence: 4}
          ]
        }
      ],
      trips:
        [
          %{
            id: "H8-0715",
            direction_id: 0,
            pattern_id: "PA",
            first_departure_secs: 26_100,
            service_id: "WEEKDAY"
          },
          %{
            id: "H8-0800",
            direction_id: 0,
            pattern_id: "PA",
            first_departure_secs: 28_800,
            service_id: "WEEKDAY"
          },
          %{
            id: "H8-LOOP",
            direction_id: 0,
            pattern_id: "PA",
            first_departure_secs: 87_000,
            service_id: "WEEKDAY"
          },
          %{
            id: "H8-LATE",
            direction_id: 0,
            pattern_id: "PA",
            first_departure_secs: 88_200,
            service_id: "WEEKDAY"
          },
          %{
            id: "H8-1820",
            direction_id: 0,
            pattern_id: "PA",
            first_departure_secs: 66_000,
            service_id: "HOLIDAY"
          }
        ] ++ extra_trips
    }
  end

  # The default `[]` marks the ordinary reviewed sheet: the scope the host
  # already holds for the route, with no bulk rows in it.
  defp draft_source(params, extra_trips \\ []) do
    params
    |> TimetableSource.normalize(native_scope(extra_trips))
    |> unwrap()
  end

  defp accepted_source(params, extra_trips \\ []) do
    params
    |> draft_source(extra_trips)
    |> TimetableSource.accept(%{confirmed?: true})
    |> unwrap()
  end

  defp bulk_trip_scope do
    Enum.map(1..260, fn index ->
      %{
        id: "BULK-#{index}",
        direction_id: 0,
        pattern_id: "PA",
        first_departure_secs: 26_100,
        service_id: "WEEKDAY"
      }
    end)
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: flunk("expected an accepted source, got #{inspect(reason)}")

  # The hand-written weekday sheet: three listed trips on the two weekday dates.
  defp weekday_params do
    %{
      "text" => "Trip\tCentral\tHarbor\n07:15\t07:35\n08:00\t08:20\n18:20\t18:40\n",
      "label" => "November 2026 approved sheet",
      "first_date" => "2026-11-25",
      "last_date" => "2026-11-27",
      "date_policy" => "weekly",
      "weekdays" => [1, 2, 3, 4, 5],
      "removed_dates" => ["2026-11-26"],
      "mapping" =>
        base_mapping(%{
          "1" => %{"feed_trip_id" => "H8-0715"},
          "2" => %{"feed_trip_id" => "H8-0800"},
          "3" => %{"feed_trip_id" => "H8-1820"}
        })
    }
  end

  defp school_params do
    weekday_params()
    |> Map.merge(%{
      "date_policy" => "school",
      "weekdays" => nil,
      "removed_dates" => [],
      "school_dates" => ["2026-11-25", "2026-11-27"]
    })
  end

  # The loop sheet: CENTRAL arrival and departure, HARBOR, and LOOP twice. The
  # final visit claims 24:10 where the feed reads 00:10.
  defp loop_params do
    %{
      "text" =>
        "Trip\tCentral arr\tCentral dep\tHarbor\tLoop\tLoop\n23:50\t23:55\t24:00\t24:05\t24:10\t24:10\n",
      "first_date" => "2026-11-25",
      "last_date" => "2026-11-27",
      "date_policy" => "weekly",
      "weekdays" => [1, 2, 3, 4, 5],
      "removed_dates" => ["2026-11-26"],
      "mapping" =>
        base_mapping(%{"1" => %{"feed_trip_id" => "H8-LOOP"}})
        |> put_in(["columns"], %{
          "0" => %{"stop_id" => @central, "stop_sequence" => 1, "side" => "arrival"},
          "1" => %{"stop_id" => @central, "stop_sequence" => 1, "side" => "departure"},
          "2" => %{"stop_id" => @harbor, "stop_sequence" => 2},
          "3" => %{"stop_id" => @loop, "stop_sequence" => 3},
          "4" => %{"stop_id" => @loop, "stop_sequence" => 4}
        })
    }
  end

  # A sheet whose only claim is an arrival on a trip whose retained arrival
  # cannot be read.
  defp unreadable_clock_params do
    %{
      "text" => "Trip\tCentral\n24:30\n",
      "first_date" => "2026-11-25",
      "last_date" => "2026-11-27",
      "date_policy" => "weekly",
      "weekdays" => [1, 2, 3, 4, 5],
      "removed_dates" => ["2026-11-26"],
      "mapping" =>
        base_mapping(%{"1" => %{"feed_trip_id" => "H8-LATE"}})
        |> put_in(["columns"], %{"0" => %{"stop_id" => @central, "stop_sequence" => 1}})
    }
  end

  # 260 listed rows, each claiming 07:00 arrival and departure where the bulk
  # feed reads 07:15 on both reviewed dates. One mapped occurrence contributes
  # two event comparisons per date, so the comparison is 1,040 time mismatches:
  # above the 500-witness retention limit while staying inside the source's own
  # 500 trip-row bound.
  defp bulk_params do
    row = "07:00"

    text =
      Enum.join(["Trip\tCentral" | Enum.map(1..260, fn _index -> row end)], "\n") <> "\n"

    rows =
      Map.new(1..260, fn index ->
        {to_string(index), %{"feed_trip_id" => "BULK-#{index}"}}
      end)

    %{
      "text" => text,
      "first_date" => "2026-11-25",
      "last_date" => "2026-11-27",
      "date_policy" => "weekly",
      "weekdays" => [1, 2, 3, 4, 5],
      "removed_dates" => ["2026-11-26"],
      "mapping" =>
        base_mapping(rows)
        |> put_in(["columns"], %{"0" => %{"stop_id" => @central, "stop_sequence" => 1}})
    }
  end

  defp base_mapping(rows) do
    %{
      "direction_id" => 0,
      "pattern_id" => "PA",
      "columns" => %{
        "0" => %{"stop_id" => @central, "stop_sequence" => 1},
        "1" => %{"stop_id" => @harbor, "stop_sequence" => 2}
      },
      "rows" => rows
    }
  end

  # -- expectations helpers ---------------------------------------------------

  defp date_witnesses(report, category), do: Map.fetch!(report.witnesses, category)

  defp unique_suffix, do: System.unique_integer([:positive])

  # Every case runs inside the sandboxed test transaction and only reads, so the
  # route's retained rows and the audit trail are unchanged by any comparison.
  defp retained_counts(scope) do
    %{
      trips:
        Repo.aggregate(
          from(t in Trip, where: t.organization_id == ^scope.organization_id),
          :count
        ),
      stop_times:
        Repo.aggregate(
          from(s in StopTime, where: s.organization_id == ^scope.organization_id),
          :count
        ),
      audit:
        Repo.aggregate(
          from(l in ChangeLog, where: l.organization_id == ^scope.organization_id),
          :count
        )
    }
  end
end
