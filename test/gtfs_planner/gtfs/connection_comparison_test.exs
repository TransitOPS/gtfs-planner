defmodule GtfsPlanner.Gtfs.ConnectionComparisonTest do
  @moduledoc """
  Merge evidence (EV-7) for `ConnectionComparison.compare/4`: the exact current
  and candidate margins computed from one loaded snapshot, and the unresolved
  categories that must stay unresolved.

  Every expectation is hand-derived from the acceptance cases and the GTFS
  reference, not from a second invocation of the module under test:

    * 09:02:00 arrives at the loop's first visit to `CENTRAL-P1` and 09:08:00
      leaves `HARBOR`, so 32,880 - 32,520 = 360 seconds are available against the
      stored 300 second minimum, leaving a 60 second margin that meets the stated
      minimum. A candidate arriving at 09:07:00 leaves 60 seconds, a -240 second
      margin that falls below it, and a delta of -240 - 60 = -300.
    * 24:10:00 to 24:18:00 is 87,480 - 87,000 = 480 available seconds and a 180
      second margin. Both clocks stay above the 24-hour mark; nothing is wrapped
      or reduced by a guessed day.
    * A pair whose endpoints do not share one zone or one civil-date basis, whose
      trip is a `frequencies.txt` template, whose calendar cannot be read, or
      whose version states no minimum has no exact margin to compute, so each
      stays unresolved with its own reason instead of being normalized into one.
    * A pair that does not run on the requested date is `:not_applicable`, a
      best-ranked type 3 rule is `:prohibited` even beside an explicit supplied
      minimum, and in every case the whole request still classifies each
      requested pair without writing anything.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ConnectionComparison
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip

  # 2026-11-26 is a Thursday; `EXCEPTION` adds exactly this date and `DAILY` adds
  # the next civil date, which is what an endpoint offset of one names.
  @service_date ~D[2026-11-26]
  @next_date ~D[2026-11-27]
  @station "CENTRAL"
  @platform "CENTRAL-P1"
  @harbor "HARBOR"
  @away "AWAY"
  @arrival_trip "R1-0902"
  @departure_trip "R2-0908"
  @stored_minimum 300
  @zone "America/New_York"

  setup do
    {:ok, scope: connection_scope()}
  end

  describe "compare/4 exact margins (AC-7)" do
    test "computes current and candidate margins and the delta between them", %{scope: scope} do
      p = pair("p1", scope)
      digest = snapshot_digest(scope, [p])

      assert {:ok, report} =
               compare(
                 scope,
                 [p],
                 @service_date,
                 candidate(%{"p1" => clocks("09:07:00", "09:08:00")}, digest)
               )

      assert [row] = report.rows
      assert row.id == "p1"
      assert row.status == :comparable
      assert row.reason == nil

      # 09:08:00 - 09:02:00 = 360 available against the stored 300 minimum.
      assert row.current.arrival_time == "09:02:00"
      assert row.current.arrival_secs == secs("09:02:00")
      assert row.current.departure_time == "09:08:00"
      assert row.current.departure_secs == secs("09:08:00")
      assert row.current.available_seconds == 360
      assert row.current.margin_seconds == 60
      assert row.current.margin_status == :meets_stated_minimum

      # The supplied candidate is measured against the same stated minimum.
      assert row.candidate.arrival_time == "09:07:00"
      assert row.candidate.available_seconds == 60
      assert row.candidate.margin_seconds == -240
      assert row.candidate.margin_status == :below_stated_minimum

      assert row.delta_seconds == -300

      assert row.minimum.status == :resolved
      assert row.minimum.seconds == @stored_minimum
      assert row.minimum.provenance.kind == :stored_best

      assert report.totals == %{
               requested: 1,
               comparable: 1,
               unresolved: 0,
               not_applicable: 0,
               prohibited: 0,
               meets_stated_minimum: 1,
               below_stated_minimum: 1
             }

      assert report.completeness == %{
               complete?: true,
               requested: 1,
               classified: 1,
               withheld: 0
             }

      # The report is bound to the snapshot the approval named (CR-4).
      assert report.base_digest == digest

      assert report.scope == %{
               organization_id: scope.organization_id,
               gtfs_version_id: scope.gtfs_version_id
             }

      assert report.service_date == @service_date
      assert report.approved_route_ids == ["R1", "R2"]
      assert report.candidate.origin == :supplied
      assert report.candidate.evidence == :external_exact_supplied
      assert report.candidate.approval.label == "approval-1"
      assert report.candidate.approval.base_digest == digest
      assert report.resources.pair_limit == ConnectionComparison.pair_limit()
      assert report.resources.snapshot.requested == 1
      assert report.digest =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "keeps above-24-hour clocks intact without normalizing a day", %{scope: scope} do
      late_scope = late_hours_scope(scope)

      p = pair("p1", late_scope)
      digest = snapshot_digest(late_scope, [p])

      assert {:ok, report} =
               compare(
                 late_scope,
                 [p],
                 @service_date,
                 candidate(%{"p1" => clocks("24:12:00", "24:18:00")}, digest)
               )

      assert [row] = report.rows
      assert row.status == :comparable

      # 24:18:00 is 87,480 service-day seconds and 24:10:00 is 87,000, so the
      # 480 available seconds are used exactly as the feed records them.
      assert row.current.arrival_secs == 87_000
      assert row.current.departure_secs == 87_480
      assert row.current.available_seconds == 480
      assert row.current.margin_seconds == 180
      assert row.current.margin_status == :meets_stated_minimum

      assert row.candidate.available_seconds == 360
      assert row.candidate.margin_seconds == 60
      assert row.delta_seconds == -120
    end
  end

  describe "compare/4 unresolved categories (AC-8, AC-9)" do
    test "refuses to subtract two different date-offset bases", %{scope: scope} do
      p = pair("p1", scope, to_trip: scope.next_day_trip, to_offset: 1)
      digest = snapshot_digest(scope, [p])

      assert {:ok, report} =
               compare(
                 scope,
                 [p],
                 @service_date,
                 candidate(%{"p1" => clocks("09:07:00", "23:50:00")}, digest)
               )

      assert [row] = report.rows
      assert row.status == :unresolved
      assert row.reason == :mixed_date_offset_basis
      assert row.current == nil
      assert row.candidate == nil
      assert row.delta_seconds == nil
      assert report.completeness.complete? == false
      assert report.totals.unresolved == 1
    end

    test "refuses to subtract two agency zones", %{scope: scope} do
      mixed = mixed_zone_scope(scope)

      east_west =
        pair("p1", mixed, to_route: mixed.chicago_route, to_trip: mixed.chicago_trip)

      digest = snapshot_digest(mixed, [east_west])

      assert {:ok, report} =
               compare(
                 mixed,
                 [east_west],
                 @service_date,
                 candidate(%{"p1" => clocks("09:07:00", "09:08:00")}, digest)
               )

      assert [row] = report.rows
      assert row.status == :unresolved
      assert row.reason == :mixed_timezones
    end

    test "refuses a frequency template, including an exact_times 1 one", %{scope: scope} do
      frequency_fixture(scope.organization_id, scope.gtfs_version_id, @arrival_trip, %{
        start_time: "09:00:00",
        end_time: "12:00:00",
        headway_secs: 600,
        exact_times: 1
      })

      p = pair("p1", scope)
      digest = snapshot_digest(scope, [p])

      assert {:ok, report} =
               compare(
                 scope,
                 [p],
                 @service_date,
                 candidate(%{"p1" => clocks("09:07:00", "09:08:00")}, digest)
               )

      assert [row] = report.rows
      assert row.status == :unresolved
      assert row.reason == :frequency_template
    end

    test "keeps a pair that does not run on the date not applicable", %{scope: scope} do
      inactive = inactive_route_trip(scope)

      pairs = [
        pair("p1", scope, to_route: inactive.route, to_trip: inactive.trip),
        pair("p2", scope, to_route: scope.from_route, to_trip: scope.missing_trip)
      ]

      digest = snapshot_digest(scope, pairs)

      assert {:ok, report} =
               compare(
                 scope,
                 pairs,
                 @service_date,
                 candidate(%{"p1" => clocks("09:07:00", "09:08:00")}, digest)
               )

      assert [first, second] = report.rows

      assert first.id == "p1"
      assert first.status == :not_applicable
      assert first.reason == :inactive_route
      assert first.current == nil

      # `MISSING` has no weekly row and no addition on the requested Thursday.
      assert second.id == "p2"
      assert second.status == :not_applicable
      assert second.reason == :no_recorded_service

      assert report.totals.not_applicable == 2
      assert report.totals.comparable == 0
      assert report.completeness.withheld == 2
    end

    test "reports an unreadable calendar as unresolved", %{scope: scope} do
      p = pair("p1", scope, to_trip: scope.broken_trip)
      digest = snapshot_digest(scope, [p])

      assert {:ok, report} =
               compare(
                 scope,
                 [p],
                 @service_date,
                 candidate(%{"p1" => clocks("09:07:00", "09:08:00")}, digest)
               )

      assert [row] = report.rows
      assert row.status == :unresolved
      assert row.reason == :unreadable_calendar
    end

    test "keeps a prohibited minimum and an absent minimum out of the arithmetic", %{
      scope: scope
    } do
      prohibited = connection_scope(policy: :type3)

      p =
        pair("p1", prohibited,
          minimum: %{origin: :supplied, seconds: 240, approval: "approved-by-review"}
        )

      digest = snapshot_digest(prohibited, [p])

      assert {:ok, report} =
               compare(
                 prohibited,
                 [p],
                 @service_date,
                 candidate(%{"p1" => clocks("09:07:00", "09:08:00")}, digest)
               )

      assert [row] = report.rows
      assert row.status == :prohibited
      assert row.reason == :prohibited_by_best_rule
      assert row.current == nil
      assert row.delta_seconds == nil
      assert row.minimum.status == :prohibited

      # `AWAY` is not covered by any rule, so this version states no minimum for
      # it and the pair stays unresolved.
      absent = pair("p2", scope, from_trip: scope.away_trip, from_stop: @away)
      digest = snapshot_digest(scope, [absent])

      assert {:ok, report} =
               compare(
                 scope,
                 [absent],
                 @service_date,
                 candidate(%{"p2" => clocks("09:07:00", "09:08:00")}, digest)
               )

      assert [row] = report.rows
      assert row.status == :unresolved
      assert row.reason == :no_stated_minimum
      assert row.minimum.status == :absent

      # An explicitly supplied minimum answers an undetermined one, and its own
      # provenance records which rule left the version's minimum open.
      supplied =
        pair("p3", scope,
          from_trip: scope.away_trip,
          from_stop: @away,
          minimum: %{origin: :supplied, seconds: 240, approval: "approved-by-review"}
        )

      digest = snapshot_digest(scope, [supplied])

      assert {:ok, report} =
               compare(
                 scope,
                 [supplied],
                 @service_date,
                 candidate(%{"p3" => clocks("09:07:00", "09:08:00")}, digest)
               )

      assert [row] = report.rows
      assert row.status == :comparable
      assert row.minimum.origin == :supplied
      assert row.minimum.seconds == 240
      assert row.minimum.provenance.kind == :no_applicable_rule
      assert row.minimum.supplied.approval == "approved-by-review"

      # 360 available against the supplied 240 second minimum.
      assert row.current.available_seconds == 360
      assert row.current.margin_seconds == 120
      assert row.current.margin_status == :meets_stated_minimum
    end

    test "leaves a pair without usable candidate clocks unresolved", %{scope: scope} do
      p = pair("p1", scope)
      digest = snapshot_digest(scope, [p])

      assert {:ok, report} = compare(scope, [p], @service_date, candidate(%{}, digest))

      assert [row] = report.rows
      assert row.status == :unresolved
      assert row.reason == :missing_candidate_evidence
      assert row.current.available_seconds == 360
      assert row.candidate == nil
      assert row.delta_seconds == nil

      # An unparsable supplied clock is unknown, never zero.
      assert {:ok, report} =
               compare(
                 scope,
                 [p],
                 @service_date,
                 candidate(%{"p1" => clocks("25:99:00", "09:08:00")}, digest)
               )

      assert [row] = report.rows
      assert row.status == :unresolved
      assert row.reason == :unknown_candidate_time
      assert row.candidate == nil
    end

    test "refuses a candidate that no longer matches the loaded snapshot", %{scope: scope} do
      p = pair("p1", scope)
      stale = snapshot_digest(scope, [p])

      move_minimum(scope, 900)

      assert {:error, :stale} = compare(scope, [p], @service_date, candidate(%{}, stale))

      # A label with no binding to a snapshot cannot be shown as approved either.
      assert {:error, :stale} =
               compare(scope, [p], @service_date, %{
                 origin: :supplied,
                 times: %{},
                 approval: "approval-1"
               })

      assert {:ok, report} = compare(scope, [p], @service_date, nil)

      assert [row] = report.rows
      assert row.status == :unresolved
      assert row.reason == :missing_candidate_evidence
      assert report.base_digest != stale
      assert report.candidate == nil
    end

    test "classifies every requested pair and writes nothing", %{scope: scope} do
      comparable = pair("p1", scope)
      absent = pair("p2", scope, from_trip: scope.away_trip, from_stop: @away)

      digest = snapshot_digest(scope, [comparable, absent])
      before = row_counts(scope)

      assert {:ok, report} =
               compare(
                 scope,
                 [comparable, absent],
                 @service_date,
                 candidate(
                   %{
                     "p1" => clocks("09:07:00", "09:08:00"),
                     "p2" => clocks("09:07:00", "09:08:00")
                   },
                   digest
                 )
               )

      assert Enum.map(report.rows, & &1.id) == ["p1", "p2"]
      assert Enum.map(report.rows, & &1.status) == [:comparable, :unresolved]
      assert Enum.map(report.rows, & &1.reason) == [nil, :no_stated_minimum]

      assert report.totals.requested == 2
      assert report.totals.comparable == 1
      assert report.totals.unresolved == 1
      assert report.completeness.complete? == false
      assert report.completeness.withheld == 1

      # A comparison is a read: it leaves the scope exactly as it found it.
      assert row_counts(scope) == before
      assert audit_count(scope) == 0
    end

    test "refuses a malformed candidate", %{scope: scope} do
      p = pair("p1", scope)

      assert {:error, :invalid_input} =
               compare(scope, [p], @service_date, %{
                 origin: :supplied,
                 times: %{"p1" => %{arrival: "09:07:00"}},
                 approval: "approval-1"
               })

      assert {:error, :invalid_input} =
               compare(scope, [p], @service_date, %{
                 origin: :supplied,
                 times: %{"p1" => clocks("09:07:00", "09:08:00")},
                 approval: "approval-1",
                 extra: true
               })

      assert {:error, :invalid_input} =
               compare(scope, [p], @service_date, %{
                 origin: :native,
                 times: %{},
                 approval: "approval-1"
               })
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp connection_scope(opts \\ []) do
    organization = organization_fixture(%{alias: unique_alias()})
    version = gtfs_version_fixture(organization.id)

    agency =
      agency_fixture(organization.id, version.id, %{
        agency_id: "MAIN",
        agency_timezone: @zone
      })

    from_route =
      route_fixture(organization.id, version.id, %{route_id: "R1", agency_id: agency.agency_id})

    to_route =
      route_fixture(organization.id, version.id, %{route_id: "R2", agency_id: agency.agency_id})

    station_fixture(organization.id, version.id, @station)
    child_stop_fixture(organization.id, version.id, @station, %{stop_id: @platform})
    stop_fixture(organization.id, version.id, %{stop_id: @harbor})
    stop_fixture(organization.id, version.id, %{stop_id: @away})

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "EXCEPTION",
      date: @service_date,
      exception_type: 1
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "DAILY",
      date: @next_date,
      exception_type: 1
    })

    # A weekly row whose range ends before it starts is unreadable retained
    # source, which `ServiceDates` refuses instead of answering with an absence.
    Repo.insert!(%Calendar{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      service_id: "BROKEN",
      start_date: @next_date,
      end_date: @service_date,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 1,
      sunday: 1
    })

    arrival_trip =
      timed_trip(organization.id, version.id, "R1", @arrival_trip, "EXCEPTION", [
        {@platform, 1, "09:02:00"},
        {@platform, 5, "09:52:00"}
      ])

    departure_trip =
      timed_trip(organization.id, version.id, "R2", @departure_trip, "EXCEPTION", [
        {@harbor, 2, "09:08:00"}
      ])

    # `AWAY` is a stop this version holds that no stored rule covers.
    away_trip =
      timed_trip(organization.id, version.id, "R1", "R1-AWAY", "EXCEPTION", [
        {@away, 1, "09:02:00"}
      ])

    # `MISSING` has no weekly row and no addition, so its trip does not run on
    # the requested Thursday.
    missing_trip =
      timed_trip(organization.id, version.id, "R1", "R1-MISSING", "MISSING", [
        {@harbor, 2, "09:08:00"}
      ])

    broken_trip =
      timed_trip(organization.id, version.id, "R2", "R2-BROKEN", "BROKEN", [
        {@harbor, 2, "09:08:00"}
      ])

    next_day_trip =
      timed_trip(organization.id, version.id, "R2", "R2-2350", "DAILY", [
        {@harbor, 2, "23:50:00"}
      ])

    seed_policy(organization.id, version.id, Keyword.get(opts, :policy, :type2))

    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      organization: organization,
      version: version,
      from_route: from_route,
      to_route: to_route,
      arrival_trip: arrival_trip,
      departure_trip: departure_trip,
      away_trip: away_trip,
      missing_trip: missing_trip,
      broken_trip: broken_trip,
      next_day_trip: next_day_trip
    }
  end

  # Above-24-hour endpoints on the same routes, because their clocks are the only
  # thing under test in that case.
  defp late_hours_scope(scope) do
    arrival =
      timed_trip(scope.organization_id, scope.gtfs_version_id, "R1", "R1-2410", "EXCEPTION", [
        {@platform, 1, "24:10:00"}
      ])

    departure =
      timed_trip(scope.organization_id, scope.gtfs_version_id, "R2", "R2-2418", "EXCEPTION", [
        {@harbor, 2, "24:18:00"}
      ])

    %{scope | arrival_trip: arrival, departure_trip: departure}
  end

  # A second route whose agency states another zone: that pair's two endpoints
  # then have no shared time basis, which this module refuses to convert.
  defp mixed_zone_scope(scope) do
    agency =
      agency_fixture(scope.organization_id, scope.gtfs_version_id, %{
        agency_id: "OTHER",
        agency_timezone: "America/Chicago"
      })

    chicago_route =
      route_fixture(scope.organization_id, scope.gtfs_version_id, %{
        route_id: "R2C",
        agency_id: agency.agency_id
      })

    chicago_trip =
      timed_trip(scope.organization_id, scope.gtfs_version_id, "R2C", "R2C-0908", "EXCEPTION", [
        {@harbor, 2, "09:08:00"}
      ])

    Map.merge(scope, %{chicago_route: chicago_route, chicago_trip: chicago_trip})
  end

  defp inactive_route_trip(scope) do
    route =
      route_fixture(scope.organization_id, scope.gtfs_version_id, %{
        route_id: "R2X",
        active: false
      })

    trip =
      timed_trip(scope.organization_id, scope.gtfs_version_id, "R2X", "R2X-0908", "EXCEPTION", [
        {@harbor, 2, "09:08:00"}
      ])

    # `MISSING` has no weekly row and no addition on the requested Thursday.
    %{route: route, trip: trip}
  end

  defp unique_alias, do: "conncmp-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp station_fixture(organization_id, version_id, stop_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: "Central Station",
      location_type: 1
    })
  end

  defp timed_trip(organization_id, version_id, route_id, trip_id, service_id, stops) do
    trip =
      trip_fixture(organization_id, version_id, route_id, %{
        trip_id: trip_id,
        service_id: service_id,
        direction_id: 0
      })

    Enum.each(stops, fn {stop_id, sequence, time} ->
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end)

    trip
  end

  defp seed_policy(organization_id, version_id, policy) do
    case policy do
      :type3 ->
        transfer_fixture(organization_id, version_id, %{
          from_stop_id: @station,
          to_stop_id: @harbor,
          transfer_type: 3
        })

      _stored ->
        transfer_fixture(organization_id, version_id, %{
          from_stop_id: @station,
          to_stop_id: @harbor,
          transfer_type: 2,
          min_transfer_time: @stored_minimum
        })
    end
  end

  defp move_minimum(scope, seconds) do
    Repo.update_all(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization_id and
            t.gtfs_version_id == ^scope.gtfs_version_id
      ),
      set: [min_transfer_time: seconds]
    )

    :ok
  end

  # -- request shapes ---------------------------------------------------------

  defp pair(id, scope, opts \\ []) do
    %{
      id: id,
      from:
        endpoint(
          Keyword.get(opts, :from_route, scope.from_route),
          Keyword.get(opts, :from_trip, scope.arrival_trip),
          Keyword.get(opts, :from_stop, @platform),
          Keyword.get(opts, :from_sequence, 1),
          Keyword.get(opts, :from_offset, 0)
        ),
      to:
        endpoint(
          Keyword.get(opts, :to_route, scope.to_route),
          Keyword.get(opts, :to_trip, scope.departure_trip),
          Keyword.get(opts, :to_stop, @harbor),
          Keyword.get(opts, :to_sequence, 2),
          Keyword.get(opts, :to_offset, 0)
        ),
      minimum: Keyword.get(opts, :minimum, %{origin: :stored})
    }
  end

  defp endpoint(route, trip, stop_id, sequence, offset) do
    %{
      route_id: route.id,
      trip_id: trip.id,
      stop_id: stop_id,
      stop_sequence: sequence,
      service_date_offset: offset
    }
  end

  defp clocks(arrival, departure), do: %{arrival: arrival, departure: departure}

  defp candidate(times, base_digest) do
    %{
      origin: :supplied,
      times: times,
      approval: %{base_digest: base_digest, label: "approval-1"}
    }
  end

  # -- calls ------------------------------------------------------------------

  defp compare(scope, pairs, service_date, candidate) do
    ConnectionComparison.compare(scope, pairs, service_date, candidate)
  end

  # The digest a host would have seen when it approved its candidate, read
  # through the public load rather than recomputed here.
  defp snapshot_digest(scope, pairs) do
    assert {:ok, snapshot} = ConnectionComparison.load(scope, pairs, @service_date)
    snapshot.digest
  end

  defp secs(clock) do
    {:ok, value} = GtfsTime.parse(clock)
    value
  end

  defp row_counts(scope) do
    %{
      transfers:
        Repo.aggregate(
          from(t in Transfer, where: t.organization_id == ^scope.organization_id),
          :count
        ),
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
      calendar_dates:
        Repo.aggregate(
          from(d in CalendarDate, where: d.organization_id == ^scope.organization_id),
          :count
        )
    }
  end

  defp audit_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog, where: l.organization_id == ^scope.organization_id),
      :count
    )
  end
end
