defmodule GtfsPlanner.Gtfs.DatedChangeTimesTest do
  @moduledoc """
  Merge evidence (EV-4) for `DatedChangePlan.project_times/3`: exact
  service-day clocks that a 24-hour day cannot hold, a dwell that survives the
  shift, and every case that must refuse to state an exact departure.

  Expectations are hand-derived from GTFS clock arithmetic, not from a second
  call into the module under test. Each `HH:MM:SS` is converted to seconds here
  from its own parts, and the shifted value is written out as the literal
  `H:MM:SS` a reader can check:

    * `25:10:00` = 90,600 s, `+300` = 90,900 s = `25:15:00` on the same service
      day. It is never `01:15:00` and never the next service date.
    * A dwell of five minutes keeps its length: `25:12:00`/`25:17:00` becomes
      `25:17:00`/`25:22:00`, and the departure still follows the arrival.
    * `00:05:00` = 300 s with `-600` is -300 s, below zero, so it is refused
      rather than wrapped to a clock the service day never had.
    * `596523:14:07` is 2,147,483,647 s, the largest second `GtfsTime` accepts.
      `+300` is past it, so the projection refuses instead of wrapping.
    * A blank arrival is unknown in both positions. The stop's own departure is
      not a stand-in for it, so nothing states a departure that was never there.
    * A frequency window is a template, not a listed occurrence, so it is
      disclosed exactly as stored and no occurrence clock is invented for it.
  ## What these cases do not establish

  Nothing here proves concurrent visibility or the loader's own admission: that
  is EV-2's subject, and these cases consume the snapshot `load/2` produced and
  the partitions `partition/2` returned. These cases assert the clock projection
  only; a refusal returned here is about the projection.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.ConcurrencyHelpers
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.DatedChangePlan
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @holiday ~D[2026-11-11]
  @first ~D[2026-11-02]
  @last ~D[2026-11-13]
  @central "CENTRAL"
  @harbor_stop "HARBOR"

  @nine ~w(2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06 2026-11-09 2026-11-10
           2026-11-12 2026-11-13)

  # The row shape the report consumes: clocks in native seconds, and nothing
  # that could carry a date or a wrapped value instead.
  @clock_keys [
    :before_arrival,
    :before_departure,
    :stop_sequence,
    :temporary_arrival,
    :temporary_departure,
    :trip_id
  ]

  setup do
    {:ok, supervisor: start_supervised!({Task.Supervisor, []})}
  end

  describe "project_times/3 service-day clocks (AC-8)" do
    test "moves a 25:10 departure to 25:15 on the original service day", %{
      supervisor: supervisor
    } do
      times = times_scope(supervisor)
      {:ok, accepted} = accept([times.exact.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      assert {:ok, projection} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      assert projection.timing == :complete
      assert projection.unresolved == []
      assert projection.delta_seconds == 300
      assert projection.input_digest == accepted.input_digest
      assert projection.dependency_digest == snapshot.dependency_digest
      assert projection.schema_version == 1

      # 25:10:00 is 90,600 s; +300 s is 90,900 s, which is 25:15:00 and not
      # 01:15:00 of any other day.
      assert [first, dwell, last] = projection.projected_clocks

      assert first.trip_id == times.exact.id
      assert first.before_arrival == 90_600
      assert first.temporary_arrival == 90_900
      assert first.before_departure == 90_600
      assert first.temporary_departure == 90_900

      # A five-minute dwell keeps its length: the arrival moves to 25:17:00
      # (91,020 s) and the departure to 25:22:00 (91,320 s), so the two fields
      # moved separately and stayed separate.
      assert dwell.stop_sequence == 2
      assert dwell.before_arrival == 90_720
      assert dwell.temporary_arrival == 91_020
      assert dwell.before_departure == 91_020
      assert dwell.temporary_departure == 91_320
      assert dwell.temporary_departure - dwell.temporary_arrival == 300
      assert dwell.temporary_departure - dwell.before_departure == 300

      # 25:20:00 is 91,200 s; +300 s is 91,500 s, which is 25:25:00 - still the
      # same service day, and still past 24:00.
      assert last.stop_sequence == 3
      assert last.before_departure == 91_200
      assert last.temporary_departure == 91_500

      # Every row carries clocks only, so no date or wrapped value can ride
      # along with them.
      assert Enum.all?(projection.projected_clocks, &(Enum.sort(Map.keys(&1)) == @clock_keys))

      assert Enum.map(projection.projected_clocks, & &1.stop_sequence) == [1, 2, 3]
    end

    test "projects the temporary dates and leaves the normal dates' clocks alone", %{
      supervisor: supervisor
    } do
      times = times_scope(supervisor)
      {:ok, accepted} = accept([times.exact.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, [partition]} = DatedChangePlan.partition(snapshot, accepted)

      assert {:ok, projection} = DatedChangePlan.project_times(snapshot, accepted, [partition])

      # Nine of the interval's ten weekdays are affected; the removed 2026-11-11
      # is not a date the original service runs at all.
      assert dates(partition.temporary_dates) == @nine

      # The three proposed clocks are the temporary dates' clocks, one row per
      # stored stop. The 251 normal dates are not proposed at all: they keep the
      # `before_*` clocks, which are the stored ones.
      assert length(projection.projected_clocks) == 3
      assert length(partition.normal_dates) == 260 - 9

      for row <- projection.projected_clocks do
        assert row.temporary_arrival == row.before_arrival + 300
        assert row.temporary_departure == row.before_departure + 300
      end

      # The unselected trip of the same calendar is a partition member, not a
      # projected clock: the plan never claims its timing.
      assert partition.unaffected_trip_ids == [times.other.id]
      assert Enum.all?(projection.projected_clocks, &(&1.trip_id == times.exact.id))
    end

    test "binds the projection to the source, the snapshot and the partitions", %{
      supervisor: supervisor
    } do
      times = times_scope(supervisor)
      {:ok, accepted} = accept([times.exact.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      assert {:ok, first} = DatedChangePlan.project_times(snapshot, accepted, partitions)
      assert {:ok, second} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      # The same three inputs project the same clocks and the same identity, so
      # a host can tell one analysis from another without re-reading anything.
      assert first == second
      assert first.partitions_digest =~ ~r/\A[0-9a-f]{64}\z/

      # A different partition of the same snapshot is a different analysis.
      [partition] = partitions

      assert {:ok, other} =
               DatedChangePlan.project_times(snapshot, accepted, [
                 %{partition | temporary_dates: List.delete(partition.temporary_dates, @first)}
               ])

      refute other.partitions_digest == first.partitions_digest
      assert other.projected_clocks == first.projected_clocks
    end
  end

  describe "project_times/3 refuses to state an exact departure (AC-8)" do
    test "a projected second below zero is unknown, never wrapped", %{supervisor: supervisor} do
      times = times_scope(supervisor)

      # 00:05:00 is 300 s; -600 s is -300 s, which is not a service-day second.
      {:ok, accepted} = accept([times.edge.id], @first, @last, "-600")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      assert {:ok, projection} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      assert projection.timing == :unresolved
      assert [row] = projection.projected_clocks
      assert row.before_arrival == 300
      assert row.before_departure == 300
      assert row.temporary_arrival == :unknown
      assert row.temporary_departure == :unknown

      # Both fields of the stop are reported, each naming its own clock.
      assert projection.unresolved == [
               reason(times.edge, :negative_time, 1, :arrival),
               reason(times.edge, :negative_time, 1, :departure)
             ]
    end

    test "a projected second past the supported range is unknown, never wrapped", %{
      supervisor: supervisor
    } do
      times = times_scope(supervisor)

      # 596523:14:07 is 2,147,483,647 s, the last second `GtfsTime` accepts;
      # +300 s is past it.
      {:ok, accepted} = accept([times.ceiling.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      assert {:ok, projection} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      assert projection.timing == :unresolved
      assert [row] = projection.projected_clocks
      assert row.before_departure == 2_147_483_647
      assert row.temporary_departure == :unknown
      assert row.temporary_arrival == :unknown

      assert projection.unresolved == [
               reason(times.ceiling, :time_overflow, 1, :arrival),
               reason(times.ceiling, :time_overflow, 1, :departure)
             ]
    end

    test "a blank arrival stays unknown and never falls back to the departure", %{
      supervisor: supervisor
    } do
      times = times_scope(supervisor)
      {:ok, accepted} = accept([times.blank.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      assert {:ok, projection} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      assert projection.timing == :unresolved
      assert [first, second] = projection.projected_clocks

      # The first stop stores no arrival. Its departure of 06:05:00 is 21,900 s
      # and moves to 22,200 s (06:10:00), but the missing arrival stays unknown
      # in both positions: the departure is not a stand-in for it.
      assert first.before_arrival == :unknown
      assert first.temporary_arrival == :unknown
      assert first.before_departure == 21_900
      assert first.temporary_departure == 22_200

      # The stop that does store both clocks projects both.
      assert second.before_arrival == 22_200
      assert second.temporary_arrival == 22_500
      assert second.temporary_departure == 22_500

      assert projection.unresolved == [reason(times.blank, :unknown_clock, 1, :arrival)]
    end

    test "a clock the native reader cannot parse is unknown", %{supervisor: supervisor} do
      times = times_scope(supervisor)

      update_stop_time(times.organization, times.exact.trip_id, 1, "6:0:00", "06:00:00")

      {:ok, accepted} = accept([times.exact.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      assert {:ok, projection} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      assert projection.timing == :unresolved
      assert [first | _rest] = projection.projected_clocks
      assert first.before_arrival == :unknown
      assert first.temporary_arrival == :unknown
      # The readable departure of the same stop still moves: one unreadable field
      # does not take the other one down with it.
      assert first.before_departure == 21_600
      assert first.temporary_departure == 21_900
      assert projection.unresolved == [reason(times.exact, :invalid_clock, 1, :arrival)]
    end

    test "a frequency window is disclosed and never becomes a listed service", %{
      supervisor: supervisor
    } do
      times = times_scope(supervisor)
      {:ok, accepted} = accept([times.frequency.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      assert {:ok, projection} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      # A headway window is a template. Its stored window is disclosed and the
      # trip's stop times are not projected into an occurrence departure.
      assert projection.projected_clocks == []
      assert projection.timing == :unresolved

      assert [window] = projection.frequency_windows

      assert window == %{
               trip_id: times.frequency.id,
               service_id: "SPECIAL",
               start_time: "09:00:00",
               end_time: "12:00:00",
               headway_secs: 1_200,
               exact_times: 0
             }

      assert projection.unresolved == [reason(times.frequency, :frequency_not_exact, nil, nil)]
    end

    test "a listed trip with no stored stop times has no clock to state", %{
      supervisor: supervisor
    } do
      times = times_scope(supervisor)
      {:ok, accepted} = accept([times.bare.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      assert {:ok, projection} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      assert projection.projected_clocks == []
      assert projection.frequency_windows == []
      assert projection.timing == :unresolved
      assert projection.unresolved == [reason(times.bare, :no_listed_stop_times, nil, nil)]
    end

    test "a partition with no temporary date proposes no clock", %{supervisor: supervisor} do
      times = times_scope(supervisor)

      # 2026-11-07 and 2026-11-08 are a Saturday and a Sunday the calendar does
      # not run, so this is a complete plan that would change nothing.
      {:ok, accepted} = accept([times.exact.id], ~D[2026-11-07], ~D[2026-11-08], "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      assert [partition] = partitions
      assert partition.temporary_dates == []

      assert {:ok, projection} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      assert projection.projected_clocks == []
      assert projection.timing == :complete
      assert projection.unresolved == []
    end

    test "writes nothing while projecting", %{supervisor: supervisor} do
      times = times_scope(supervisor)
      {:ok, accepted} = accept([times.exact.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      before = row_counts(times)

      assert {:ok, _projection} = DatedChangePlan.project_times(snapshot, accepted, partitions)

      assert row_counts(times) == before
      assert audit_count(times) == 0
    end
  end

  describe "project_times/3 source binding (AC-8, INV-2)" do
    test "refuses a source, a snapshot or a partition this projection is not of", %{
      supervisor: supervisor
    } do
      times = times_scope(supervisor)
      {:ok, accepted} = accept([times.exact.id], @first, @last, "+300")
      {:ok, snapshot} = load(times, accepted)
      {:ok, [partition]} = DatedChangePlan.partition(snapshot, accepted)

      # A tampered source is not an accepted intent at all: its digest no longer
      # describes it.
      assert {:error, {:incomplete, :invalid_accepted_source}} =
               DatedChangePlan.project_times(snapshot, %{accepted | delta_seconds: 900}, [
                 partition
               ])

      assert {:error, {:incomplete, :invalid_accepted_source}} =
               DatedChangePlan.project_times(snapshot, %{accepted | trip_ids: []}, [partition])

      # A second valid source for a different interval: the snapshot was not
      # read for it.
      {:ok, other} = accept([times.exact.id], @first, ~D[2026-11-20], "+300")

      assert {:error, {:incomplete, :snapshot_source_mismatch}} =
               DatedChangePlan.project_times(snapshot, other, [partition])

      # A read with no trips or no digest is not a snapshot this projection can
      # read clocks from.
      assert {:error, {:incomplete, :invalid_snapshot}} =
               DatedChangePlan.project_times(%{snapshot | trips: []}, accepted, [partition])

      assert {:error, {:incomplete, :invalid_snapshot}} =
               DatedChangePlan.project_times(Map.delete(snapshot, :dependency_digest), accepted, [
                 partition
               ])

      assert {:error, {:incomplete, :invalid_snapshot}} =
               DatedChangePlan.project_times(:not_a_snapshot, accepted, [partition])

      # A partition that is not `partition/2`'s own row shape is refused rather
      # than projected.
      assert {:error, {:incomplete, :invalid_partitions}} =
               DatedChangePlan.project_times(snapshot, accepted, [
                 Map.put(partition, :delta_seconds, 300)
               ])

      assert {:error, {:incomplete, :invalid_partitions}} =
               DatedChangePlan.project_times(snapshot, accepted, [])

      assert {:error, {:incomplete, :invalid_partitions}} =
               DatedChangePlan.project_times(snapshot, accepted, [
                 %{partition | temporary_dates: partition.normal_dates}
               ])

      # A partition claiming a trip outside this read's own selection would
      # project clocks the editor never accepted.
      assert {:error, {:incomplete, {:unselected_trip, trip_id}}} =
               DatedChangePlan.project_times(snapshot, accepted, [
                 %{partition | selected_trip_ids: [times.other.id]}
               ])

      assert trip_id == times.other.id

      # ... and a partition filing a real selected trip under another service.
      assert {:error, {:incomplete, {:partition_service_mismatch, trip_id}}} =
               DatedChangePlan.project_times(snapshot, accepted, [
                 %{partition | service_id: "OTHER"}
               ])

      assert trip_id == times.exact.id

      # Two partitions of the same service describe two plans, not one.
      assert {:error, {:incomplete, :duplicate_partition_service}} =
               DatedChangePlan.project_times(snapshot, accepted, [partition, partition])
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # The Harbor Transit dataset for clock projection. `WEEKDAY` is the shared
  # 2026 weekday calendar with the removed holiday and holds the >24h trip plus
  # the unselected `H12-1`; `SPECIAL` is a second calendar of the same shape
  # holding the trips that differ only in what they store, so each case selects
  # exactly the trip it is about and never meets another case's calendar users.
  # `H12-1` is never selected, so every case also has an unaffected user. The
  # fixtures commit on their own connections, so the loader takes the production
  # snapshot boundary; each case removes exactly its organization.
  defp times_scope(supervisor) do
    times = in_task(supervisor, fn -> build_times_scope() end)
    commit_cleanup(times.organization_ids)
    times
  end

  defp build_times_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    for {stop_id, stop_name} <- [{@central, "Central Station"}, {@harbor_stop, "Harbor Yards"}] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
    end

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})
    route_fixture(organization.id, version.id, %{route_id: "H12"})

    calendar_fixture(organization.id, version.id, weekday("WEEKDAY"))
    calendar_fixture(organization.id, version.id, weekday("SPECIAL"))

    for service_id <- ["WEEKDAY", "SPECIAL"] do
      calendar_date_fixture(organization.id, version.id, %{
        service_id: service_id,
        date: @holiday,
        exception_type: 2
      })
    end

    exact =
      service_trip(organization.id, version.id, "H8-1", "WEEKDAY", [
        {@central, 1, "25:10:00", "25:10:00"},
        {@central, 2, "25:12:00", "25:17:00"},
        {@harbor_stop, 3, "25:20:00", "25:20:00"}
      ])

    frequency =
      service_trip(organization.id, version.id, "H8-2", "SPECIAL", [
        {@central, 1, "09:00:00", "09:00:00"},
        {@harbor_stop, 2, "09:15:00", "09:15:00"}
      ])

    frequency_fixture(organization.id, version.id, frequency.trip_id, %{
      start_time: "09:00:00",
      end_time: "12:00:00",
      headway_secs: 1_200,
      exact_times: 0
    })

    blank =
      service_trip(organization.id, version.id, "H8-3", "SPECIAL", [
        {@central, 1, nil, "06:05:00"},
        {@harbor_stop, 2, "06:10:00", "06:10:00"}
      ])

    edge =
      service_trip(organization.id, version.id, "H8-4", "SPECIAL", [
        {@central, 1, "00:05:00", "00:05:00"}
      ])

    ceiling =
      service_trip(organization.id, version.id, "H8-5", "SPECIAL", [
        {@central, 1, "596523:14:07", "596523:14:07"}
      ])

    # A listed trip the feed stores no stop times for.
    bare =
      trip_fixture(organization.id, version.id, "H8", %{trip_id: "H8-6", service_id: "SPECIAL"})

    other =
      service_trip(organization.id, version.id, "H12-1", "WEEKDAY", [
        {@central, 1, "07:00:00", "07:00:00"},
        {@harbor_stop, 2, "07:20:00", "07:20:00"}
      ])

    user = user_fixture()
    organization_membership_fixture(user, organization)

    %{
      organization: organization,
      version: version,
      exact: exact,
      frequency: frequency,
      blank: blank,
      edge: edge,
      ceiling: ceiling,
      bare: bare,
      other: other,
      user: user,
      organization_ids: [organization.id],
      scope: scope(organization, version, route, user)
    }
  end

  defp service_trip(organization_id, version_id, trip_id, service_id, stops) do
    trip =
      trip_fixture(organization_id, version_id, "H8", %{trip_id: trip_id, service_id: service_id})

    for {stop_id, sequence, arrival, departure} <- stops do
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: arrival,
        departure_time: departure
      })
    end

    trip
  end

  # A clock the native reader cannot parse, stored behind the fixture's valid
  # default. `GtfsTime` requires two-digit minutes and seconds, so a one-digit
  # minute such as "6:0:00" is a corrupt-but-well-shaped value it will not read.
  defp update_stop_time(organization, trip_id, stop_sequence, arrival_time, departure_time) do
    # Committed from its own autocommit connection: a write made in the test
    # process would stay in the sandbox transaction until ExUnit rolls it back,
    # which is after `on_exit` runs, so it would hold row locks the
    # committed-fixture cleanup needs.
    unboxed(fn ->
      {1, _result} =
        Repo.update_all(
          from(t in StopTime,
            where:
              t.organization_id == ^organization.id and t.trip_id == ^trip_id and
                t.stop_sequence == ^stop_sequence
          ),
          set: [arrival_time: arrival_time, departure_time: departure_time]
        )

      :ok
    end)
  end

  defp weekday(service_id) do
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

  defp scope(organization, version, route, user) do
    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "service_queries",
      version_name: version.name,
      resource_context: Scope.context({:route, route.id})
    }
  end

  defp load(times, accepted), do: DatedChangePlan.load(times.scope, accepted)

  defp accept(selected, first_date, last_date, delta_seconds) do
    {:ok, draft} =
      DatedChangePlan.normalize_intent(
        %{
          "first_date" => Date.to_iso8601(first_date),
          "last_date" => Date.to_iso8601(last_date),
          "delta_seconds" => delta_seconds,
          "approval_note" => "Approved for the winter timetable review.",
          "source_label" => "Winter review"
        },
        selected
      )

    DatedChangePlan.accept_intent(draft, selected)
  end

  defp reason(trip, reason, stop_sequence, clock) do
    %{
      reason: reason,
      service_id: trip.service_id,
      trip_id: trip.id,
      stop_sequence: stop_sequence,
      clock: clock
    }
  end

  defp dates(dates), do: Enum.map(dates, &Date.to_iso8601/1)

  # -- counts and fixture plumbing -------------------------------------------

  defp row_counts(times) do
    %{
      trips:
        Repo.aggregate(
          from(t in Trip, where: t.organization_id == ^times.organization.id),
          :count
        ),
      stop_times:
        Repo.aggregate(
          from(s in StopTime, where: s.organization_id == ^times.organization.id),
          :count
        ),
      calendar_dates:
        Repo.aggregate(
          from(d in CalendarDate, where: d.organization_id == ^times.organization.id),
          :count
        )
    }
  end

  defp audit_count(times) do
    Repo.aggregate(
      from(l in ChangeLog, where: l.organization_id == ^times.organization.id),
      :count
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp in_task(supervisor, fun) do
    supervisor
    |> Task.Supervisor.async_nolink(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(30_000)
  end

  # `on_exit` runs after the test process has exited, so a `start_supervised!/1`
  # supervisor is already dead here; the cleanup owns its own unboxed
  # connection, as `stations/stop_levels_test.exs` does.
  defp commit_cleanup(organization_ids) do
    on_exit(fn ->
      ConcurrencyHelpers.unboxed(fn ->
        ConcurrencyHelpers.delete_committed_members!(organization_ids)
        ConcurrencyHelpers.delete_committed_scope!(organization_ids)
      end)
    end)
  end
end
