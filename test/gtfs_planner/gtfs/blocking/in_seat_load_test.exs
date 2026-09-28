defmodule GtfsPlanner.Gtfs.Blocking.InSeatLoadTest do
  @moduledoc """
  Merge evidence (EV-7) for R6 through the day load (AC-7, CL-4, rejects FH-4):

  - A record naming a trip of the viewed day type and a trip that runs only in
    another day type is returned and evaluated; the `{:stale, {:not_next, [...]}}`
    state names the day type both trips run in, not the one on screen.
  - A record whose other trip runs on the day after a date of the first is the
    unconfirmed next-service-day continuation, not an invalid record.
  - A record naming a trip the version does not hold is `{:stale, :trip_missing}`.
  - A record for a pair that is not consecutive is listed under both named trips
    when both are in the day type, and under the day-type trip alone when the other
    runs elsewhere.
  - A stale record adds an `:in_seat_stale` warning to the day's findings and
    counts and raises its block's status; a matching record adds none of that, and
    a record between two unassigned trips still warns with no block on the finding.
  - A record whose two trips are blocked into different blocks is stale `not_next`
    on the day type both run in, not matching.
  - A stopless record that matches is not called "stops changed".
  - The query count is the same for 10 and for 40 records.

  Every case runs through the ordinary `Gtfs.load_blocking_day/3` entry and the
  production `CatalogReadAdapter.Repo`, inside the SQL Sandbox transaction of one
  lane-owned local database, so every fixture row is rolled back. The focused gate
  command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/in_seat_load_test.exs`.

  `async: false` because these cases share the lane database and one of them
  attaches a repo telemetry handler.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.GtfsTime

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    %{scope: new_scope()}
  end

  describe "R6 over every day type both trips run in" do
    test "a record not next on another day type is stale on the viewed one", %{scope: scope} do
      %{organization: organization, version: version} = scope

      # W runs on 1 and 2 September, S on 2 and 3 September, so {W,S} is
      # 2 September and the viewed {W} is 1 September. B and the trip between the
      # pair run on S only, so the viewed day type holds no trip between them.
      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: [~D[2026-09-01], ~D[2026-09-02]]
        })

      _school =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "S",
          name: "School",
          dates: [~D[2026-09-02], ~D[2026-09-03]]
        })

      a =
        blocked_trip(scope, %{
          trip_id: "a",
          service_id: "W",
          block_id: "7",
          first_arrival: "06:00:00",
          last_arrival: "07:00:00"
        })

      _x =
        blocked_trip(scope, %{
          trip_id: "x",
          service_id: "S",
          block_id: "7",
          first_arrival: "07:05:00",
          last_arrival: "08:05:00"
        })

      b =
        blocked_trip(scope, %{
          trip_id: "b",
          service_id: "S",
          block_id: "7",
          first_arrival: "08:10:00",
          last_arrival: "09:10:00"
        })

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, day} =
               Gtfs.load_blocking_day(organization.id, version.id, DayTypes.key(["W"]))

      assert day.day_type.service_ids == ["W"]
      assert day.counts.trips == 1
      assert Enum.map(block(day, "7").trips, & &1.trip_id) == ["a"]

      not_next = %{key: DayTypes.key(["W", "S"]), label: "School + Weekday", date_count: 1}

      assert day.in_seat == %{
               a.id => [
                 %{row: in_seat_row(record), state: {:stale, {:not_next, [not_next]}}}
               ]
             }

      assert day.findings == [
               %{
                 code: :in_seat_stale,
                 severity: :warning,
                 block_id: "7",
                 trip_ids: [a.id, b.id],
                 transfer_id: record.id,
                 detail: %{reason: {:not_next, [not_next]}}
               }
             ]

      assert day.counts.problems == 1
      assert day.counts.notices == 0
      assert block(day, "7").summary.status == :warning
      assert block(day, "7").summary.status_code == :in_seat_stale
    end
  end

  describe "a record whose other trip runs elsewhere" do
    test "a trip running only on the next day is an unconfirmed continuation", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: [~D[2026-09-01]]
        })

      _school =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "S",
          name: "School",
          dates: [~D[2026-09-02]]
        })

      a = blocked_trip(scope, %{trip_id: "a", service_id: "W", block_id: "7"})
      b = blocked_trip(scope, %{trip_id: "b", service_id: "S", block_id: "8"})

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, day} =
               Gtfs.load_blocking_day(organization.id, version.id, DayTypes.key(["W"]))

      assert day.day_type.service_ids == ["W"]
      assert day.counts.trips == 1

      assert day.in_seat == %{
               a.id => [
                 %{row: in_seat_row(record), state: {:unconfirmed, :next_service_day}}
               ]
             }

      assert day.findings == [
               %{
                 code: :in_seat_unconfirmed,
                 severity: :notice,
                 block_id: "7",
                 trip_ids: [a.id, b.id],
                 transfer_id: record.id,
                 detail: %{reason: :next_service_day}
               }
             ]

      assert day.counts.problems == 0
      assert day.counts.notices == 1
      assert block(day, "7").summary.status == :notice
      assert block(day, "7").summary.status_code == :in_seat_unconfirmed
    end

    test "a record naming a trip the version does not hold is trip_missing", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      a = blocked_trip(scope, %{trip_id: "a", service_id: "W", block_id: "7"})
      stop = stop_fixture(organization.id, version.id)

      record =
        transfer_fixture(organization.id, version.id, %{
          transfer_type: 5,
          from_trip_id: "a",
          to_trip_id: "ghost",
          from_stop_id: stop.stop_id,
          to_stop_id: stop.stop_id
        })

      assert {:ok, day} =
               Gtfs.load_blocking_day(organization.id, version.id, DayTypes.key(["W"]))

      assert day.in_seat == %{
               a.id => [%{row: in_seat_row(record), state: {:stale, :trip_missing}}]
             }

      assert day.findings == [
               %{
                 code: :in_seat_stale,
                 severity: :warning,
                 block_id: "7",
                 trip_ids: [a.id],
                 transfer_id: record.id,
                 detail: %{reason: :trip_missing}
               }
             ]

      assert day.counts.problems == 1
      assert block(day, "7").summary.status == :warning
      assert block(day, "7").summary.status_code == :in_seat_stale
    end
  end

  describe "the findings a record contributes" do
    test "a record for a pair that is not consecutive is listed under both trips", %{
      scope: scope
    } do
      {day, a, b, record} = not_next_day(scope)
      not_next = %{key: DayTypes.key(["W"]), label: "Weekday", date_count: 3}

      assert Enum.sort(Map.keys(day.in_seat)) == Enum.sort([a.id, b.id])

      assert day.in_seat[a.id] == [
               %{row: in_seat_row(record), state: {:stale, {:not_next, [not_next]}}}
             ]

      assert day.in_seat[b.id] == day.in_seat[a.id]
    end

    test "a record between two different blocks is stale not_next", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      # Both trips are blocked, but into two different blocks, so R6 can never
      # find the second following the first: the day type both services run in
      # must still be evaluated, otherwise the record would read as matching.
      a =
        blocked_trip(scope, %{
          trip_id: "a",
          service_id: "W",
          block_id: "7",
          first_arrival: "06:00:00",
          last_arrival: "07:00:00"
        })

      b =
        blocked_trip(scope, %{
          trip_id: "b",
          service_id: "W",
          block_id: "8",
          first_arrival: "07:10:00",
          last_arrival: "08:10:00"
        })

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, day} =
               Gtfs.load_blocking_day(organization.id, version.id, DayTypes.key(["W"]))

      not_next = %{key: DayTypes.key(["W"]), label: "Weekday", date_count: 3}

      assert day.in_seat == %{
               a.id => [%{row: in_seat_row(record), state: {:stale, {:not_next, [not_next]}}}],
               b.id => [%{row: in_seat_row(record), state: {:stale, {:not_next, [not_next]}}}]
             }

      assert day.findings == [
               %{
                 code: :in_seat_stale,
                 severity: :warning,
                 block_id: "7",
                 trip_ids: [a.id, b.id],
                 transfer_id: record.id,
                 detail: %{reason: {:not_next, [not_next]}}
               }
             ]

      assert day.counts.problems == 1
      assert day.counts.notices == 0
      assert block(day, "7").summary.status == :warning
      assert block(day, "7").summary.status_code == :in_seat_stale
      assert block(day, "8").summary.status == :ok
      assert block(day, "8").summary.status_code == nil
    end

    test "a stale record is a warning in the findings, the counts and the block status", %{
      scope: scope
    } do
      {day, a, b, record} = not_next_day(scope)
      not_next = %{key: DayTypes.key(["W"]), label: "Weekday", date_count: 3}

      assert day.counts.trips == 3
      assert day.counts.problems == 1
      assert day.counts.notices == 0

      assert [%{code: :in_seat_stale, severity: :warning, transfer_id: transfer_id} = finding] =
               day.findings

      assert finding.trip_ids == [a.id, b.id]
      assert finding.block_id == "7"
      assert finding.detail == %{reason: {:not_next, [not_next]}}
      assert transfer_id == record.id

      assert block(day, "7").summary.status == :warning
      assert block(day, "7").summary.status_code == :in_seat_stale

      assert Enum.any?(
               block(day, "7").findings,
               &(&1.code == :in_seat_stale and &1.transfer_id == record.id)
             )
    end

    test "a record between two pool trips is listed under both without a block", %{
      scope: scope
    } do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      a = blocked_trip(scope, %{trip_id: "a", service_id: "W"})

      b =
        blocked_trip(scope, %{
          trip_id: "b",
          service_id: "W",
          first_arrival: "08:30:00",
          last_arrival: "09:30:00"
        })

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, day} =
               Gtfs.load_blocking_day(organization.id, version.id, DayTypes.key(["W"]))

      assert day.blocks == []

      assert day.in_seat == %{
               a.id => [%{row: in_seat_row(record), state: {:stale, :no_block}}],
               b.id => [%{row: in_seat_row(record), state: {:stale, :no_block}}]
             }

      assert day.findings == [
               %{
                 code: :in_seat_stale,
                 severity: :warning,
                 block_id: nil,
                 trip_ids: [a.id, b.id],
                 transfer_id: record.id,
                 detail: %{reason: :no_block}
               }
             ]

      assert day.counts == %{
               blocks: 0,
               trips: 2,
               unassigned: 2,
               problems: 1,
               notices: 0
             }
    end

    test "a matching stopless record is in the day and adds no finding", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      stop = stop_fixture(organization.id, version.id)

      a =
        blocked_trip(scope, %{
          trip_id: "a",
          service_id: "W",
          block_id: "7",
          first_arrival: "06:00:00",
          last_arrival: "07:00:00",
          first_stop: stop.stop_id,
          last_stop: stop.stop_id
        })

      b =
        blocked_trip(scope, %{
          trip_id: "b",
          service_id: "W",
          block_id: "7",
          first_arrival: "07:10:00",
          last_arrival: "08:10:00",
          first_stop: stop.stop_id,
          last_stop: stop.stop_id
        })

      # A type 4 record without stops is what the transfer-integrity work allows;
      # the rule must not call it "stops changed" (FH-4).
      record =
        transfer_fixture(organization.id, version.id, %{
          transfer_type: 4,
          from_trip_id: "a",
          to_trip_id: "b"
        })

      assert {:ok, day} =
               Gtfs.load_blocking_day(organization.id, version.id, DayTypes.key(["W"]))

      assert day.in_seat == %{
               a.id => [%{row: in_seat_row(record), state: :matches}],
               b.id => [%{row: in_seat_row(record), state: :matches}]
             }

      assert day.findings == []
      assert day.counts.problems == 0
      assert day.counts.notices == 0
      assert block(day, "7").summary.status == :ok
      assert block(day, "7").summary.status_code == nil
    end
  end

  describe "the query count" do
    test "is the same for 10 and for 40 records" do
      small = records_scope(10)
      large = records_scope(40)

      {small_result, small_queries} =
        count_queries(fn ->
          Gtfs.load_blocking_day(small.organization.id, small.version.id, DayTypes.key(["W"]))
        end)

      {large_result, large_queries} =
        count_queries(fn ->
          Gtfs.load_blocking_day(large.organization.id, large.version.id, DayTypes.key(["W"]))
        end)

      assert {:ok, small_day} = small_result
      assert {:ok, large_day} = large_result

      assert map_size(small_day.in_seat) == 10
      assert map_size(large_day.in_seat) == 10
      assert small_queries == large_queries
    end
  end

  # A, C and B share one block on one day type with C between the record's pair, so
  # A -> B is not a consecutive pair and the record has no hosting gap. The three
  # trips share one stop, so the block's own checks add no notice.
  defp not_next_day(scope) do
    %{organization: organization, version: version} = scope

    _weekday =
      calendar_service_fixture(organization.id, version.id, %{
        service_id: "W",
        name: "Weekday",
        dates: @weekday_dates
      })

    stop = stop_fixture(organization.id, version.id)

    a = block_trip(scope, stop, "a", "06:00:00", "07:00:00")
    _c = block_trip(scope, stop, "c", "07:10:00", "08:00:00")
    b = block_trip(scope, stop, "b", "08:10:00", "09:10:00")

    record = in_seat_transfer_fixture(organization.id, version.id, a, b)

    assert {:ok, day} =
             Gtfs.load_blocking_day(organization.id, version.id, DayTypes.key(["W"]))

    {day, a, b, record}
  end

  # One block of ten trips on one day type, with `record_count` of the ninety
  # ordered pairs between them stored as type 4 records.
  defp records_scope(record_count) do
    scope = new_scope()
    %{organization: organization, version: version} = scope

    _weekday =
      calendar_service_fixture(organization.id, version.id, %{
        service_id: "W",
        name: "Weekday",
        dates: @weekday_dates
      })

    stop = stop_fixture(organization.id, version.id)

    trips =
      for index <- 1..10 do
        start_secs = 21_600 + index * 600

        block_trip(
          scope,
          stop,
          "trip_#{index}",
          GtfsTime.format(start_secs),
          GtfsTime.format(start_secs + 300)
        )
      end

    trips
    |> record_pairs()
    |> Enum.take(record_count)
    |> Enum.each(fn {from, to} ->
      in_seat_transfer_fixture(organization.id, version.id, from, to)
    end)

    scope
  end

  defp record_pairs(trips) do
    for from <- trips, to <- trips, from.trip_id != to.trip_id, do: {from, to}
  end

  defp block_trip(scope, stop, trip_id, first_arrival, last_arrival) do
    blocked_trip(scope, %{
      trip_id: trip_id,
      service_id: "W",
      block_id: "7",
      first_arrival: first_arrival,
      last_arrival: last_arrival,
      first_stop: stop.stop_id,
      last_stop: stop.stop_id
    })
  end

  defp new_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{
      organization: organization,
      version: version,
      route: route_fixture(organization.id, version.id)
    }
  end

  # A test that only cares about block membership, service or scope passes no
  # times, so `blocked_trip_fixture/4` keeps its own defaults; the cases that assert
  # on times pass both.
  defp blocked_trip(scope, attrs) do
    blocked_trip_fixture(
      scope.organization.id,
      scope.version.id,
      scope.route.route_id,
      Map.put_new(Map.new(attrs), :service_id, "W")
    )
  end

  defp in_seat_row(record) do
    %{
      id: record.id,
      from_trip_id: record.from_trip_id,
      to_trip_id: record.to_trip_id,
      transfer_type: record.transfer_type,
      from_stop_id: record.from_stop_id,
      to_stop_id: record.to_stop_id
    }
  end

  defp block(day, block_id), do: Enum.find(day.blocks, &(&1.summary.block_id == block_id))

  # Ecto runs a repo telemetry handler in the process that issued the query, so
  # counting only this test's own messages keeps other tests' queries out.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = "blocking-in-seat-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, _metadata, pid ->
        if self() == pid, do: send(pid, {:blocking_query, handler_id})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    try do
      {fun.(), drain_queries(handler_id, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, count) do
    receive do
      {:blocking_query, ^handler_id} -> drain_queries(handler_id, count + 1)
    after
      0 -> count
    end
  end
end
