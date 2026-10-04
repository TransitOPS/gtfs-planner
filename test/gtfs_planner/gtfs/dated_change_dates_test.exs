defmodule GtfsPlanner.Gtfs.DatedChangeDatesTest do
  @moduledoc """
  Merge evidence (EV-3) for `DatedChangePlan.partition/2`: complete original
  service dates, a partition that neither invents nor discards one, shared
  calendar users left whole, and truthful refusal above the enumeration cap.

  Expectations are hand-derived from the GTFS Schedule reference and from
  independent calendar arithmetic, not from a second call into the module under
  test. `ServiceDates.active_dates/2` is the evaluator production reuses, so
  asserting its own output would only prove it agrees with itself.

    * `WEEKDAY` runs Monday to Friday over 2026-01-01..2026-12-31 and loses
      2026-11-11 to a `calendar_dates` removal. 2026 is 365 days starting on a
      Thursday, so it holds 261 weekdays; the removal leaves 260. The requested
      interval 2026-11-02..2026-11-13 holds ten weekdays, so nine of them are
      affected and the removed 11th is absent from D entirely.
    * `MULTIYEAR` covers 2026-01-01..2027-12-31 with the same five service
      weekdays - 261 in 2026 and 261 in 2027, since 2027 is another 365-day year
      starting on a Friday - plus two additions on a Saturday and a Sunday.
      Neither addition is a weekly service day, so D holds 524 dates. It has no
      removal, so all ten weekdays of the requested interval are affected,
      which is what distinguishes it from `WEEKDAY`.
    * `DATES_ONLY` has no weekly row at all, so D is exactly its two additions:
      one inside the requested interval and one a year outside it.
    * Route `H12` is never selected and shares `WEEKDAY`, so it keeps all 260
      original dates while `H8` is partitioned.
    * An interval inside the calendar's range but on its two non-service days
      yields an empty T, an N equal to D, and a complete analysis.

  The cap cases use the same arithmetic production counts - inclusive weekly
  span plus one cell per exception row, summed over unique loaded calendars.
  A calendar spanning 199,998 days with two exceptions spends exactly 200,000
  cells and is admitted; one day more is refused before any enumeration, so no
  200,000-date fixture is created to prove the boundary.

  ## What these cases do not establish

  Nothing here proves concurrent visibility or the loader's own admission: that
  is EV-2's subject, and these cases consume the snapshot `load/2` produced. A
  refusal returned here is about the partition only.
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
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @work_cell_cap 200_000

  @holiday ~D[2026-11-11]
  @first ~D[2026-11-02]
  @central "CENTRAL"
  @harbor_stop "HARBOR"

  @nine ~w(2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06 2026-11-09 2026-11-10
           2026-11-12 2026-11-13)
  @ten ~w(2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06 2026-11-09 2026-11-10
           2026-11-11 2026-11-12 2026-11-13)

  # 2026 holds 261 weekdays and loses one to the removal: 260 original dates.
  @weekday_dates 260
  # MULTIYEAR holds 261 + 261 weekly dates plus two additions on non-service days.
  @multiyear_dates 524

  setup do
    {:ok, supervisor: start_supervised!({Task.Supervisor, []})}
  end

  describe "partition/2 original dates (AC-6)" do
    test "splits a weekday calendar into exactly its nine affected dates", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept([harbor.trip.id], ~D[2026-11-02], ~D[2026-11-13])
      {:ok, snapshot} = load(harbor, accepted)

      assert {:ok, [partition]} = DatedChangePlan.partition(snapshot, accepted)

      assert partition.service_id == "WEEKDAY"
      assert partition.selected_trip_ids == [harbor.trip.id]

      # Nine of the interval's ten weekdays: the removed 11th is not one of them.
      assert dates(partition.temporary_dates) == @nine
      assert length(partition.temporary_dates) == 9

      # D is the whole 2026 weekday year, not the two requested weeks.
      assert length(partition.original_dates) == @weekday_dates
      assert ~D[2026-01-01] in partition.original_dates
      assert ~D[2026-12-31] in partition.original_dates

      # Both interval endpoints are inside T, inclusive at each end.
      assert partition.temporary_dates |> List.first() == ~D[2026-11-02]
      assert partition.temporary_dates |> List.last() == ~D[2026-11-13]

      # T and N are disjoint and their union is exactly D. D is ascending, and
      # T then N is not, so the union is compared as the set it is.
      assert disjoint?(partition)
      assert MapSet.new(union(partition)) == MapSet.new(partition.original_dates)
      assert length(partition.normal_dates) == @weekday_dates - 9
      assert sorted?(partition.original_dates)
      assert sorted?(partition.temporary_dates)
      assert sorted?(partition.normal_dates)

      # A date the original service never ran stays out of both partitions.
      refute @holiday in partition.original_dates
      refute @holiday in partition.temporary_dates
      refute @holiday in partition.normal_dates
    end

    test "refuses a snapshot that was not read for this accepted source", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept([harbor.trip.id], ~D[2026-11-02], ~D[2026-11-13])
      {:ok, snapshot} = load(harbor, accepted)

      other = %{accepted | last_date: ~D[2026-11-20]}

      assert {:error, {:incomplete, :invalid_accepted_source}} =
               DatedChangePlan.partition(snapshot, other)

      # A second valid source for a different interval: its own digest is
      # correct, so the only thing wrong with it here is that the snapshot was
      # not read for it.
      [first, second_last] = [@first, ~D[2026-11-20]]
      {:ok, other} = accept([harbor.trip.id], first, second_last)

      assert {:error, {:incomplete, :snapshot_source_mismatch}} =
               DatedChangePlan.partition(snapshot, other)

      # A snapshot naming no usable selection is incomplete, not an empty plan.
      assert {:error, {:incomplete, :invalid_snapshot}} =
               DatedChangePlan.partition(Map.delete(snapshot, :selected_trip_ids), accepted)

      assert {:error, {:incomplete, {:unselected_trip, trip_id}}} =
               DatedChangePlan.partition(%{snapshot | trips: []}, accepted)

      assert trip_id == harbor.trip.id
    end
  end

  describe "partition/2 complete original sets (AC-6, AC-7)" do
    test "partitions three calendars, keeping outside additions and exception-only service", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)

      selected = [harbor.trip.id, harbor.multiyear_trip.id, harbor.only_trip.id]
      {:ok, accepted} = accept(selected, ~D[2026-11-02], ~D[2026-11-13])
      {:ok, snapshot} = load(harbor, accepted)

      assert {:ok, partitions} = DatedChangePlan.partition(snapshot, accepted)

      # One partition per selected calendar, ordered by service id.
      assert Enum.map(partitions, & &1.service_id) == ["DATES_ONLY", "MULTIYEAR", "WEEKDAY"]

      by_service = Map.new(partitions, &{&1.service_id, &1})

      # `MULTIYEAR` has no removal, so all ten weekdays of the interval are
      # affected, and its two outside additions survive in the normal partition.
      multiyear = by_service["MULTIYEAR"]

      assert dates(multiyear.temporary_dates) == @ten
      assert length(multiyear.original_dates) == @multiyear_dates
      assert ~D[2027-03-06] in multiyear.original_dates
      assert ~D[2027-07-04] in multiyear.original_dates
      assert ~D[2027-03-06] in multiyear.normal_dates
      assert ~D[2027-07-04] in multiyear.normal_dates
      assert disjoint?(multiyear)
      assert MapSet.new(union(multiyear)) == MapSet.new(multiyear.original_dates)

      # Exception-only service: D is exactly the two additions, one inside the
      # interval and one a year outside it, with no weekly range at all.
      dates_only = by_service["DATES_ONLY"]

      assert dates(dates_only.original_dates) == ["2026-11-04", "2027-02-02"]
      assert dates(dates_only.temporary_dates) == ["2026-11-04"]
      assert dates(dates_only.normal_dates) == ["2027-02-02"]
      assert disjoint?(dates_only)

      # The shared calendar's other route keeps the removal-free nine dates and
      # is reported beside the selected trip as an unaffected user.
      weekday = by_service["WEEKDAY"]

      assert dates(weekday.temporary_dates) == @nine
      # Both unselected trips of `WEEKDAY` - H8's own second trip and H12's -
      # keep the calendar whole beside the one selected trip.
      assert weekday.unaffected_trip_ids ==
               [harbor.second_trip.id, harbor.other_trip.id] |> Enum.sort()

      assert length(weekday.original_dates) == @weekday_dates

      # Nothing was written to separate the calendars.
      assert row_counts(harbor) == harbor.seeded
      assert audit_count(harbor) == 0
    end

    test "leaves an unselected trip of the same calendar with all of D", %{supervisor: supervisor} do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept([harbor.trip.id], ~D[2026-11-02], ~D[2026-11-13])
      {:ok, snapshot} = load(harbor, accepted)

      assert {:ok, [partition]} = DatedChangePlan.partition(snapshot, accepted)

      # The version's other trip on `WEEKDAY` keeps the same 260 original dates
      # the calendar defines: partitioning H8 does not shrink the calendar
      # underneath H12.
      assert partition.unaffected_trip_ids ==
               [harbor.second_trip.id, harbor.other_trip.id] |> Enum.sort()

      assert length(partition.original_dates) == @weekday_dates
      assert partition.original_dates == expected_weekday_dates()

      assert row_counts(harbor) == harbor.seeded
      assert audit_count(harbor) == 0
    end

    test "an interval of only non-service days is a complete no-op analysis", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)

      # 2026-11-07..2026-11-08 is a Saturday and a Sunday inside the calendar's
      # own range, so `WEEKDAY` runs on neither day.
      {:ok, accepted} = accept([harbor.trip.id], ~D[2026-11-07], ~D[2026-11-08])
      {:ok, snapshot} = load(harbor, accepted)

      assert {:ok, [partition]} = DatedChangePlan.partition(snapshot, accepted)

      assert partition.temporary_dates == []
      assert partition.normal_dates == partition.original_dates
      assert length(partition.original_dates) == @weekday_dates
    end
  end

  describe "partition/2 enumeration admission (AC-5)" do
    test "admits exactly the work-cell cap and refuses one cell more before enumerating", %{
      supervisor: supervisor
    } do
      exact = cap_scope(supervisor, @work_cell_cap)
      {:ok, accepted} = accept([exact.trip.id], ~D[2026-11-02], ~D[2026-11-13])
      {:ok, snapshot} = load(exact, accepted)

      # 199,998 inclusive weekly days plus two exception rows is exactly
      # 200,000 cells, so the boundary is admitted rather than refused. The
      # calendar serves no weekday, so its D is exactly its two additions and
      # the admitted enumeration really did walk the whole span.
      assert {:ok, [partition]} = DatedChangePlan.partition(snapshot, accepted)
      assert partition.service_id == "WIDE"
      assert dates(partition.original_dates) == ["2026-11-04", "2027-02-02"]

      over = cap_scope(supervisor, @work_cell_cap + 1)
      {:ok, over_accepted} = accept([over.trip.id], ~D[2026-11-02], ~D[2026-11-13])
      {:ok, over_snapshot} = load(over, over_accepted)

      # One cell more is incomplete, and the reason names the count and the cap
      # so nothing downstream can read it as a complete, partial answer.
      assert {:error, {:incomplete, {:date_work_cap_exceeded, 200_001, @work_cell_cap}}} =
               DatedChangePlan.partition(over_snapshot, over_accepted)
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # The Harbor Transit dataset. `WEEKDAY` is the shared calendar with the
  # removed holiday, `MULTIYEAR` is a two-year calendar with additions on days
  # its weekly range does not serve, and `DATES_ONLY` has no weekly row. The
  # fixtures commit on their own connections, so the loader takes the
  # production snapshot boundary; each case removes exactly its organizations.
  defp harbor_scope(supervisor) do
    harbor = in_task(supervisor, fn -> build_harbor_scope() end)
    commit_cleanup(harbor.organization_ids)
    harbor
  end

  defp build_harbor_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    for {stop_id, stop_name} <- [{@central, "Central Station"}, {@harbor_stop, "Harbor Yards"}] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
    end

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})
    route_fixture(organization.id, version.id, %{route_id: "H12"})

    calendar_fixture(
      organization.id,
      version.id,
      weekday("WEEKDAY", ~D[2026-01-01], ~D[2026-12-31])
    )

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      date: @holiday,
      exception_type: 2
    })

    calendar_fixture(
      organization.id,
      version.id,
      weekday("MULTIYEAR", ~D[2026-01-01], ~D[2027-12-31])
    )

    for date <- [~D[2027-03-06], ~D[2027-07-04]] do
      calendar_date_fixture(organization.id, version.id, %{
        service_id: "MULTIYEAR",
        date: date,
        exception_type: 1
      })
    end

    for date <- [~D[2026-11-04], ~D[2027-02-02]] do
      calendar_date_fixture(organization.id, version.id, %{
        service_id: "DATES_ONLY",
        date: date,
        exception_type: 1
      })
    end

    trip = service_trip(organization.id, version.id, "H8-1", "WEEKDAY")
    second_trip = service_trip(organization.id, version.id, "H8-2", "WEEKDAY")
    other_trip = service_trip(organization.id, version.id, "H12-1", "WEEKDAY")
    multiyear_trip = service_trip(organization.id, version.id, "H8-3", "MULTIYEAR")
    only_trip = service_trip(organization.id, version.id, "H8-4", "DATES_ONLY")

    user = user_fixture()
    organization_membership_fixture(user, organization)

    harbor = %{
      organization: organization,
      version: version,
      trip: trip,
      second_trip: second_trip,
      other_trip: other_trip,
      multiyear_trip: multiyear_trip,
      only_trip: only_trip,
      user: user,
      organization_ids: [organization.id]
    }

    Map.merge(harbor, %{
      scope: scope(organization, version, route, user),
      seeded: row_counts_for(organization)
    })
  end

  # The cap case needs one calendar spanning the whole admitted workload, so it
  # gets its own organization. Its weekdays are all off, which keeps D empty
  # without weakening the span the cap is counting.
  defp cap_scope(supervisor, cells) do
    scope = in_task(supervisor, fn -> build_cap_scope(cells) end)
    commit_cleanup(scope.organization_ids)
    scope
  end

  defp build_cap_scope(cells) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})
    stop_fixture(organization.id, version.id, %{stop_id: @central, stop_name: "Central Station"})
    stop_fixture(organization.id, version.id, %{stop_id: @harbor_stop, stop_name: "Harbor Yards"})

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})
    first = ~D[1000-01-01]
    last = Date.add(first, cells - 3)

    calendar_fixture(organization.id, version.id, %{
      service_id: "WIDE",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 0,
      start_date: first,
      end_date: last
    })

    for date <- [~D[2026-11-04], ~D[2027-02-02]] do
      calendar_date_fixture(organization.id, version.id, %{
        service_id: "WIDE",
        date: date,
        exception_type: 1
      })
    end

    trip = service_trip(organization.id, version.id, "H8-1", "WIDE")
    user = user_fixture()
    organization_membership_fixture(user, organization)

    %{
      organization: organization,
      version: version,
      trip: trip,
      scope: scope(organization, version, route, user),
      organization_ids: [organization.id]
    }
  end

  defp service_trip(organization_id, version_id, trip_id, service_id) do
    trip =
      trip_fixture(organization_id, version_id, "H8", %{
        trip_id: trip_id,
        service_id: service_id
      })

    for {stop_id, sequence, time} <- [{@central, 1, "06:00:00"}, {@harbor_stop, 2, "06:15:00"}] do
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end

    trip
  end

  defp weekday(service_id, first, last) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: first,
      end_date: last
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

  defp accept(selected, first_date, last_date) do
    {:ok, draft} =
      DatedChangePlan.normalize_intent(
        %{
          "first_date" => Date.to_iso8601(first_date),
          "last_date" => Date.to_iso8601(last_date),
          "delta_seconds" => "+300",
          "approval_note" => "Approved for the winter timetable review.",
          "source_label" => "Winter review"
        },
        selected
      )

    DatedChangePlan.accept_intent(draft, selected)
  end

  # -- independent date oracle -----------------------------------------------

  # The weekday year derived here from the calendar's own rule rather than from
  # the module under test: every Monday..Friday of the inclusive range, less the
  # one removed date.
  defp expected_weekday_dates do
    ~D[2026-01-01]
    |> Date.range(~D[2026-12-31])
    |> Enum.filter(&(Date.day_of_week(&1) in 1..5))
    |> Enum.reject(&(&1 == @holiday))
  end

  defp dates(dates), do: Enum.map(dates, &Date.to_iso8601/1)

  defp sorted?(dates), do: dates == Enum.sort_by(dates, & &1, Date)

  defp disjoint?(partition),
    do:
      MapSet.disjoint?(MapSet.new(partition.temporary_dates), MapSet.new(partition.normal_dates))

  defp union(partition), do: partition.temporary_dates ++ partition.normal_dates

  # -- counts and fixture plumbing -------------------------------------------

  defp load(harbor, accepted), do: DatedChangePlan.load(harbor.scope, accepted)

  defp row_counts(harbor) do
    %{
      trips:
        Repo.aggregate(
          from(t in Trip, where: t.organization_id == ^harbor.organization.id),
          :count
        ),
      calendar_dates:
        Repo.aggregate(
          from(d in CalendarDate, where: d.organization_id == ^harbor.organization.id),
          :count
        )
    }
  end

  defp row_counts_for(organization) do
    %{
      trips:
        Repo.aggregate(
          from(t in Trip, where: t.organization_id == ^organization.id),
          :count
        ),
      calendar_dates:
        Repo.aggregate(
          from(d in CalendarDate, where: d.organization_id == ^organization.id),
          :count
        )
    }
  end

  defp audit_count(harbor) do
    Repo.aggregate(
      from(l in ChangeLog, where: l.organization_id == ^harbor.organization.id),
      :count
    )
  end

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
