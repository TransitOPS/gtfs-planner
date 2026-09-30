defmodule GtfsPlanner.Gtfs.Blocking.UnmatchedInSeatTest do
  @moduledoc """
  Merge evidence (EV-10) for R8 through the version-level read (AC-8, CL-7, rejects FH-8):

  - A record naming two unblocked trips is listed with reason `:no_block`.
  - A record naming a trip the version does not hold is listed with
    `:trip_missing`.
  - A record whose trips share no date, and whose to-trip does not run the day
    after any date of the from-trip, is listed with `:no_shared_date`.
  - A matching record, a `{:not_next, _}` record and a next-service-day
    continuation are not listed: a not-next record is still reachable on a day
    type, and a continuation is not a broken record.
  - The rows come back ordered by `from_trip_id` then `to_trip_id`, the version's
    own order.
  - The query count is the same for 10 and for 40 records, so a version with
    thousands of records costs no more than one with ten.
  - A version of another organization is `{:error, :not_found}`.

  Every case runs through the ordinary `Gtfs.unmatched_in_seat_records/2` facade
  and the production read adapter, inside the SQL Sandbox transaction of one
  lane-owned local database, so every fixture row is rolled back. The focused gate
  command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 mix test test/gtfs_planner/gtfs/blocking/unmatched_in_seat_test.exs`.

  `async: false` because these cases share the lane database and one of them
  attaches a repo telemetry handler.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.GtfsTime

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    %{scope: new_scope()}
  end

  describe "the three reasons no block reaches" do
    test "a record naming two unblocked trips is listed", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      a = pool_trip(scope, "a", "06:00:00", "07:00:00")
      b = pool_trip(scope, "b", "08:00:00", "09:00:00")

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, [listed]} = unmatched(organization, version)

      assert listed.reason == :no_block
      assert listed.id == record.id
      assert listed.from_trip_id == "a"
      assert listed.to_trip_id == "b"
      assert listed.transfer_type == 4
      assert listed.updated_at == record.updated_at
    end

    test "a record naming one blocked and one unblocked trip is listed", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      a = block_trip(scope, "a", "06:00:00", "07:00:00", "7")
      b = pool_trip(scope, "b", "08:00:00", "09:00:00")

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, [listed]} = unmatched(organization, version)

      assert listed.reason == :no_block
      assert listed.id == record.id
    end

    test "a record naming a trip the version does not hold is listed", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      block_trip(scope, "a", "06:00:00", "07:00:00", "7")
      stop = stop_fixture(organization.id, version.id)

      record =
        transfer_fixture(organization.id, version.id, %{
          transfer_type: 5,
          from_trip_id: "a",
          to_trip_id: "ghost",
          from_stop_id: stop.stop_id,
          to_stop_id: stop.stop_id
        })

      assert {:ok, [listed]} = unmatched(organization, version)

      assert listed.reason == :trip_missing
      assert listed.id == record.id
      assert listed.from_trip_id == "a"
      assert listed.to_trip_id == "ghost"
      assert listed.transfer_type == 5
    end

    test "a record whose trips share no date is listed", %{scope: scope} do
      %{organization: organization, version: version} = scope

      # W runs on the first three days of September and S a week later, so the two
      # share no date and the to-trip does not run the day after any of the
      # from-trip's either. Both trips are blocked, so the reason can only be the
      # missing shared date.
      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      _later =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "S",
          name: "Later",
          dates: [~D[2026-09-10]]
        })

      a = block_trip(scope, "a", "06:00:00", "07:00:00", "7", "W")
      b = block_trip(scope, "b", "08:00:00", "09:00:00", "8", "S")

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, [listed]} = unmatched(organization, version)

      assert listed.reason == :no_shared_date
      assert listed.id == record.id
    end
  end

  describe "the records R8 excludes" do
    test "a matching record is not listed", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      a = block_trip(scope, "a", "06:00:00", "07:00:00", "7")
      b = block_trip(scope, "b", "07:10:00", "08:10:00", "7")

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, []} = unmatched(organization, version)
      assert record.id
    end

    test "a record that is not next on a day type is not listed", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      # C runs between the record's pair in the same block, so R6 reports the
      # record stale not-next on the day type. It is still reachable there, which
      # is why R8 leaves it to the day-type scope.
      a = block_trip(scope, "a", "06:00:00", "07:00:00", "7")
      _c = block_trip(scope, "c", "07:10:00", "08:00:00", "7")
      b = block_trip(scope, "b", "08:10:00", "09:10:00", "7")

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, []} = unmatched(organization, version)
      assert record.id
    end

    test "a record that is not next because the trips are in different blocks is not listed",
         %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      a = block_trip(scope, "a", "06:00:00", "07:00:00", "7")
      b = block_trip(scope, "b", "07:10:00", "08:10:00", "8")

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      assert {:ok, []} = unmatched(organization, version)
      assert record.id
    end

    test "a next-service-day continuation is not listed", %{scope: scope} do
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

      a = block_trip(scope, "a", "06:00:00", "07:00:00", "7", "W")
      b = block_trip(scope, "b", "08:00:00", "09:00:00", "8", "S")

      record = in_seat_transfer_fixture(organization.id, version.id, a, b)

      # The rule's state is the unconfirmed continuation, not a stale record, so
      # the version does not list it: the day type pair is the right scope.
      assert {:ok, []} = unmatched(organization, version)
      assert record.id
    end

    test "a type 0–3 record is never listed", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      stop = stop_fixture(organization.id, version.id)

      # Two unblocked trips and a plain type 0 stop-to-stop rule between their
      # stops: the record is not an in-seat record at all, and the type filter
      # is what keeps it out rather than the rule.
      pool_trip(scope, "a", "06:00:00", "07:00:00", stop)
      pool_trip(scope, "b", "08:00:00", "09:00:00", stop)

      record =
        transfer_fixture(organization.id, version.id, %{
          transfer_type: 0,
          from_stop_id: stop.stop_id,
          to_stop_id: stop.stop_id
        })

      assert {:ok, []} = unmatched(organization, version)
      assert record.id
    end
  end

  describe "the listing itself" do
    test "lists only the unmatched records of a version that holds several kinds",
         %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      stop = stop_fixture(organization.id, version.id)

      # A, C and B share one block and one stop, so A -> C and C -> B are the
      # consecutive pairs and A -> B is not. The read must exclude both matching
      # records and the not-next one, and keep only the two broken ones.
      a = block_trip(scope, "a", "06:00:00", "07:00:00", "7", "W", stop)
      c = block_trip(scope, "c", "07:10:00", "08:00:00", "7", "W", stop)
      b = block_trip(scope, "b", "08:10:00", "09:10:00", "7", "W", stop)
      _matching = in_seat_transfer_fixture(organization.id, version.id, a, c)
      _not_next = in_seat_transfer_fixture(organization.id, version.id, a, b)

      pool_a = pool_trip(scope, "pool_a", "10:00:00", "11:00:00")
      pool_b = pool_trip(scope, "pool_b", "12:00:00", "13:00:00")
      no_block = in_seat_transfer_fixture(organization.id, version.id, pool_a, pool_b)

      missing =
        transfer_fixture(organization.id, version.id, %{
          transfer_type: 4,
          from_trip_id: "ghost",
          to_trip_id: "pool_b"
        })

      assert {:ok, listed} = unmatched(organization, version)

      assert Enum.map(listed, & &1.id) == [missing.id, no_block.id]
      assert Enum.map(listed, & &1.reason) == [:trip_missing, :no_block]
    end

    test "orders the rows by from_trip_id then to_trip_id", %{scope: scope} do
      %{organization: organization, version: version} = scope

      _weekday =
        calendar_service_fixture(organization.id, version.id, %{
          service_id: "W",
          name: "Weekday",
          dates: @weekday_dates
        })

      pairs = [{"m", "a"}, {"a", "b"}, {"a", "z"}, {"b", "a"}, {"a", "an"}]

      for {from_trip_id, to_trip_id} <- pairs do
        transfer_fixture(organization.id, version.id, %{
          transfer_type: 4,
          from_trip_id: from_trip_id,
          to_trip_id: to_trip_id
        })
      end

      assert {:ok, listed} = unmatched(organization, version)

      assert Enum.map(listed, &{&1.from_trip_id, &1.to_trip_id}) == [
               {"a", "an"},
               {"a", "b"},
               {"a", "z"},
               {"b", "a"},
               {"m", "a"}
             ]

      assert Enum.all?(listed, &(&1.reason == :trip_missing))
    end

    test "a version of another organization is not found", %{scope: scope} do
      %{organization: organization, version: version} = scope
      %{organization: other, version: other_version} = new_scope()

      assert {:ok, []} = unmatched(organization, version)
      assert Gtfs.unmatched_in_seat_records(other.id, other_version.id) == {:ok, []}
      assert Gtfs.unmatched_in_seat_records(other.id, version.id) == {:error, :not_found}

      assert Gtfs.unmatched_in_seat_records(organization.id, other_version.id) ==
               {:error, :not_found}
    end
  end

  describe "the query count" do
    test "is the same for 10 and for 40 records" do
      small = records_scope(10)
      large = records_scope(40)

      {small_result, small_queries} =
        count_queries(fn ->
          Gtfs.unmatched_in_seat_records(small.organization.id, small.version.id)
        end)

      {large_result, large_queries} =
        count_queries(fn ->
          Gtfs.unmatched_in_seat_records(large.organization.id, large.version.id)
        end)

      assert {:ok, small_records} = small_result
      assert {:ok, large_records} = large_result

      assert length(small_records) == 10
      assert length(large_records) == 40
      assert small_queries == large_queries
    end
  end

  # A version holding `record_count` type 4 records, each between two real but
  # unblocked trips, so every record is listed and the trips the records name are
  # actually read. Two trips per record keep the sets disjoint.
  defp records_scope(record_count) do
    scope = new_scope()
    %{organization: organization, version: version} = scope

    _weekday =
      calendar_service_fixture(organization.id, version.id, %{
        service_id: "W",
        name: "Weekday",
        dates: @weekday_dates
      })

    trips =
      for index <- 1..(record_count * 2) do
        start_secs = 21_600 + index * 600

        pool_trip(
          scope,
          "pool_#{index}",
          GtfsTime.format(start_secs),
          GtfsTime.format(start_secs + 300)
        )
      end

    trips
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.each(fn [from_trip, to_trip] ->
      in_seat_transfer_fixture(organization.id, version.id, from_trip, to_trip)
    end)

    scope
  end

  defp unmatched(organization, version) do
    Gtfs.unmatched_in_seat_records(organization.id, version.id)
  end

  defp block_trip(
         scope,
         trip_id,
         first_arrival,
         last_arrival,
         block_id,
         service_id \\ "W",
         stop \\ nil
       )

  defp block_trip(scope, trip_id, first_arrival, last_arrival, block_id, service_id, stop) do
    attrs = %{
      trip_id: trip_id,
      service_id: service_id,
      block_id: block_id,
      first_arrival: first_arrival,
      last_arrival: last_arrival
    }

    attrs =
      case stop do
        nil -> attrs
        stop -> Map.put(attrs, :first_stop, stop.stop_id)
      end

    blocked_trip(scope, attrs)
  end

  defp pool_trip(scope, trip_id, first_arrival, last_arrival, stop \\ nil) do
    attrs = %{
      trip_id: trip_id,
      first_arrival: first_arrival,
      last_arrival: last_arrival
    }

    attrs =
      case stop do
        nil -> attrs
        stop -> Map.put(attrs, :first_stop, stop.stop_id)
      end

    blocked_trip(scope, attrs)
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

  # Ecto runs a repo telemetry handler in the process that issued the query, so
  # counting only this test's own messages keeps other tests' queries out.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = "blocking-unmatched-#{System.unique_integer([:positive])}"

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
