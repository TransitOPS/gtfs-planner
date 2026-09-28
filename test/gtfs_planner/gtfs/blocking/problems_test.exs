defmodule GtfsPlanner.Gtfs.Blocking.ProblemsTest do
  @moduledoc """
  Merge evidence (EV-16) for the Schedules block-problem read and the Blocks link target.

  One case covers each observation EV-16 rejects FH-14 with:

  - an overlap inside `{A, B}` (143 dates) reports one problem with that day type's
    key and its 143 dates;
  - the same overlap on two day types reports one problem with both keys in list
    order and the summed dates;
  - a short layover and a stale in-seat record naming the trip are reported, while a
    `:repositions` notice is not;
  - a trip without a block and a trip the version does not hold report no problems;
  - `first_day_type_key/3` returns the first day type in list order containing the
    service — the one a keyless day load resolves — and `:none` for a service with no
    active date;
  - the reads stay inside the organization and the version, and take a constant
    number of queries without locking a trip row.

  Every value goes through the ordinary facade `Gtfs.block_problems_for_trips/3` and
  `Gtfs.first_blocking_day_type_key/3`, so the adapter the Schedules page uses is on
  the path. The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/problems_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Versions

  setup do
    %{scope: new_scope()}
  end

  describe "block_problems_for_trips/3" do
    test "reports an overlap with the trip's day type key and date count", %{scope: scope} do
      weekendless_services(scope)
      a = trip(scope, %{trip_id: "a", service_id: "A", block_id: "101"})

      _b =
        trip(scope, %{
          trip_id: "b",
          service_id: "B",
          block_id: "101",
          first: "08:30:00",
          last: "09:30:00"
        })

      day_type = day_type(scope, ["A", "B"])
      assert day_type.date_count == 143

      assert problems(scope, [a.trip_id]) ==
               {:ok,
                [
                  %{
                    code: :overlap,
                    block_id: "101",
                    day_type_keys: [day_type.key],
                    date_count: 143
                  }
                ]}
    end

    test "groups one overlap spanning two day types and sums their date counts",
         %{scope: scope} do
      split_services(scope)
      a = trip(scope, %{trip_id: "a", service_id: "A", block_id: "101"})

      _b =
        trip(scope, %{
          trip_id: "b",
          service_id: "B",
          block_id: "101",
          first: "08:30:00",
          last: "09:30:00"
        })

      _x = trip(scope, %{trip_id: "x", service_id: "X"})

      monday = day_type(scope, ["A", "B", "X"])
      tuesday = day_type(scope, ["A", "B", "Y"])
      assert monday.date_count == 52
      assert tuesday.date_count == 52
      assert monday.trip_count == 3
      assert tuesday.trip_count == 2

      # A runs on both Tuesdays and Mondays, so the day types containing it are the
      # list order the problem's keys must follow: more trips first.
      assert [monday.key, tuesday.key] ==
               day_types(scope) |> Enum.filter(&("A" in &1.service_ids)) |> Enum.map(& &1.key)

      assert problems(scope, [a.trip_id]) ==
               {:ok,
                [
                  %{
                    code: :overlap,
                    block_id: "101",
                    day_type_keys: [monday.key, tuesday.key],
                    date_count: 104
                  }
                ]}
    end

    test "reports a short layover and a stale in-seat record, not a repositioning notice",
         %{scope: scope} do
      weekday_service(scope)
      shared = stop_fixture(scope.organization.id, scope.version.id)

      untracked =
        stop_fixture(scope.organization.id, scope.version.id, %{stop_lat: nil, stop_lon: nil})

      layover_from =
        trip(scope, %{
          trip_id: "layover_from",
          service_id: "WK",
          block_id: "101",
          first: "08:00:00",
          last: "09:00:00",
          last_stop: shared.stop_id
        })

      _layover_to =
        trip(scope, %{
          trip_id: "layover_to",
          service_id: "WK",
          block_id: "101",
          first: "09:02:00",
          last: "10:00:00",
          first_stop: shared.stop_id
        })

      # The move pair's five-minute gap is no layover warning, and its stop without
      # coordinates is a `:repositions` notice, which the read must not report.
      move_from =
        trip(scope, %{
          trip_id: "move_from",
          service_id: "WK",
          block_id: "102",
          first: "08:00:00",
          last: "09:00:00",
          last_stop: untracked.stop_id
        })

      _move_to =
        trip(scope, %{
          trip_id: "move_to",
          service_id: "WK",
          block_id: "102",
          first: "09:05:00",
          last: "10:00:00"
        })

      record_from =
        trip(scope, %{
          trip_id: "record_from",
          service_id: "WK",
          block_id: "103",
          first: "08:00:00",
          last: "09:00:00"
        })

      _record_between =
        trip(scope, %{
          trip_id: "record_between",
          service_id: "WK",
          block_id: "103",
          first: "09:05:00",
          last: "10:00:00"
        })

      record_to =
        trip(scope, %{
          trip_id: "record_to",
          service_id: "WK",
          block_id: "103",
          first: "10:05:00",
          last: "11:00:00"
        })

      in_seat_transfer_fixture(scope.organization.id, scope.version.id, record_from, record_to)

      key = day_type(scope, ["WK"]).key

      assert problems(scope, [layover_from.trip_id, move_from.trip_id, record_from.trip_id]) ==
               {:ok,
                [
                  %{code: :short_layover, block_id: "101", day_type_keys: [key], date_count: 261},
                  %{code: :in_seat_stale, block_id: "103", day_type_keys: [key], date_count: 261}
                ]}
    end

    test "a trip without a block has no problems", %{scope: scope} do
      weekday_service(scope)
      unblocked = trip(scope, %{trip_id: "unblocked", service_id: "WK"})

      assert problems(scope, [unblocked.trip_id]) == {:ok, []}
    end

    test "a trip the version does not hold has no problems", %{scope: scope} do
      weekday_service(scope)

      assert problems(scope, ["missing"]) == {:ok, []}
    end

    test "reports only problems that involve a requested trip", %{scope: scope} do
      weekday_service(scope)
      p = trip(scope, %{trip_id: "p", service_id: "WK", block_id: "201"})

      _q =
        trip(scope, %{
          trip_id: "q",
          service_id: "WK",
          block_id: "201",
          first: "08:30:00",
          last: "09:30:00"
        })

      z =
        trip(scope, %{
          trip_id: "z",
          service_id: "WK",
          block_id: "201",
          first: "10:00:00",
          last: "11:00:00"
        })

      # The overlap names p and q; z shares the block but neither of its findings.
      assert problems(scope, [p.trip_id]) ==
               {:ok,
                [
                  %{
                    code: :overlap,
                    block_id: "201",
                    day_type_keys: [day_type(scope, ["WK"]).key],
                    date_count: 261
                  }
                ]}

      assert problems(scope, [z.trip_id]) == {:ok, []}
    end

    test "stays inside the organization and the version", %{scope: scope} do
      weekday_service(scope)
      _a = trip(scope, %{trip_id: "shared", service_id: "WK", block_id: "301"})

      _b =
        trip(scope, %{
          trip_id: "shared_2",
          service_id: "WK",
          block_id: "301",
          first: "08:30:00",
          last: "09:30:00"
        })

      foreign = foreign_scope()
      weekday_service(foreign)
      _foreign_a = trip(foreign, %{trip_id: "shared", service_id: "WK", block_id: "301"})

      _foreign_b =
        trip(foreign, %{
          trip_id: "shared_2",
          service_id: "WK",
          block_id: "301",
          first: "08:30:00",
          last: "09:30:00"
        })

      # The foreign organization holds the same natural trip IDs, so a read that
      # forgot its scope would report the foreign overlap as well.
      assert problems(scope, ["shared"]) ==
               {:ok,
                [
                  %{
                    code: :overlap,
                    block_id: "301",
                    day_type_keys: [day_type(scope, ["WK"]).key],
                    date_count: 261
                  }
                ]}

      {:ok, staging} =
        Versions.create_staging_gtfs_version(scope.organization.id, %{name: "Staging"})

      assert Gtfs.block_problems_for_trips(scope.organization.id, staging.id, ["shared"]) ==
               {:error, :not_found}

      assert Gtfs.block_problems_for_trips(Ecto.UUID.generate(), scope.version.id, ["shared"]) ==
               {:error, :not_found}

      assert Gtfs.first_blocking_day_type_key(scope.organization.id, staging.id, "WK") ==
               {:error, :not_found}

      assert Gtfs.first_blocking_day_type_key(foreign.organization.id, scope.version.id, "WK") ==
               {:error, :not_found}
    end

    test "reads in a constant number of queries and locks no trip row", %{scope: scope} do
      split_services(scope)
      a1 = trip(scope, %{trip_id: "a1", service_id: "A", block_id: "401"})

      a2 =
        trip(scope, %{
          trip_id: "a2",
          service_id: "A",
          block_id: "402",
          first: "10:00:00",
          last: "11:00:00"
        })

      b1 =
        trip(scope, %{
          trip_id: "b1",
          service_id: "B",
          block_id: "401",
          first: "08:30:00",
          last: "09:30:00"
        })

      y1 =
        trip(scope, %{
          trip_id: "y1",
          service_id: "Y",
          block_id: "402",
          first: "10:30:00",
          last: "11:30:00"
        })

      {one, one_queries} = query_log(fn -> problems(scope, [a1.trip_id]) end)

      {batch, batch_queries} =
        query_log(fn -> problems(scope, [a1.trip_id, a2.trip_id, b1.trip_id, y1.trip_id]) end)

      assert {:ok, [_ | _]} = one
      assert {:ok, [_ | _]} = batch
      assert length(batch_queries) == length(one_queries)

      # Every writer in the package locks trip rows with `FOR UPDATE` and the blocking
      # lock with `pg_advisory_xact_lock` (INV-1); this read takes neither.
      assert Enum.all?(batch_queries, &(not String.contains?(String.upcase(&1), "FOR UPDATE")))
      assert Enum.all?(batch_queries, &(not String.contains?(&1, "pg_advisory")))
    end
  end

  describe "first_day_type_key/3" do
    test "returns the key of the first day type in list order containing the service",
         %{scope: scope} do
      split_services(scope)
      _a = trip(scope, %{trip_id: "a", service_id: "A"})
      _b1 = trip(scope, %{trip_id: "b1", service_id: "B"})
      _b2 = trip(scope, %{trip_id: "b2", service_id: "B"})
      _b3 = trip(scope, %{trip_id: "b3", service_id: "B"})
      _x1 = trip(scope, %{trip_id: "x1", service_id: "X"})
      _x2 = trip(scope, %{trip_id: "x2", service_id: "X"})

      monday = day_type(scope, ["A", "B", "X"])
      tuesday = day_type(scope, ["A", "B", "Y"])
      assert monday.date_count == 52
      assert monday.trip_count == 6
      assert tuesday.trip_count == 4

      # The list order is trip count descending, so the Monday day type is first:
      # the link must target that one, never a later day type that also contains A.
      assert first_day_type_key(scope, "A") == {:ok, monday.key}
      assert first_day_type_key(scope, "B") == {:ok, monday.key}
      assert first_day_type_key(scope, "Y") == {:ok, tuesday.key}

      # It is the key a keyless day load resolves, and the canonical pure key for the
      # day type's services (INV-6).
      assert {:ok, day} = Gtfs.load_blocking_day(scope.organization.id, scope.version.id, nil)
      assert day.day_type.key == monday.key
      assert monday.key == DayTypes.key(["A", "B", "X"])
    end

    test "a service with no active date has no day type", %{scope: scope} do
      weekday_service(scope)

      calendar_service_fixture(scope.organization.id, scope.version.id, %{
        service_id: "NODATES",
        name: "No dates",
        dates: []
      })

      assert first_day_type_key(scope, "NODATES") == {:ok, :none}
      assert first_day_type_key(scope, "WK") == {:ok, day_type(scope, ["WK"]).key}
    end
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

  defp foreign_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{
      organization: organization,
      version: version,
      route: route_fixture(organization.id, version.id)
    }
  end

  # A and B run on every weekday from 2026-01-05 through 2026-07-22, so `{A, B}` is
  # the one day type and holds 143 dates.
  defp weekendless_services(scope) do
    weekdays = %{monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1}
    range = [start_date: ~D[2026-01-05], end_date: ~D[2026-07-22]]

    service(scope, "A", weekdays, range)
    service(scope, "B", weekdays, range)
  end

  # A and B run Monday and Tuesday, X Monday alone and Y Tuesday alone, so
  # `{A, B, X}` and `{A, B, Y}` are two day types that both contain A and B.
  defp split_services(scope) do
    service(scope, "A", %{monday: 1, tuesday: 1})
    service(scope, "B", %{monday: 1, tuesday: 1})
    service(scope, "X", %{monday: 1})
    service(scope, "Y", %{tuesday: 1})
  end

  defp weekday_service(scope) do
    service(scope, "WK", %{monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1})
  end

  defp service(scope, service_id, weekdays, range \\ []) do
    calendar_service_fixture(
      scope.organization.id,
      scope.version.id,
      %{
        service_id: service_id,
        name: service_id,
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 0
      }
      |> Map.merge(Map.new(weekdays))
      |> Map.merge(Map.new(range))
    )
  end

  # A trip on the scope's route; `:first` and `:last` are its endpoint clocks.
  defp trip(scope, attrs) do
    attrs = Map.new(attrs)
    {first, attrs} = Map.pop(attrs, :first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      scope.organization.id,
      scope.version.id,
      scope.route.route_id,
      attrs
      |> Map.put(:first_arrival, first)
      |> Map.put(:first_departure, first)
      |> Map.put(:last_arrival, last)
      |> Map.put(:last_departure, last)
    )
  end

  defp problems(scope, trip_ids) do
    Gtfs.block_problems_for_trips(scope.organization.id, scope.version.id, trip_ids)
  end

  defp first_day_type_key(scope, service_id) do
    Gtfs.first_blocking_day_type_key(scope.organization.id, scope.version.id, service_id)
  end

  defp day_types(scope) do
    {:ok, calendars} = Calendars.list_calendars(scope.organization.id, scope.version.id)
    DayTypes.derive(calendars)
  end

  defp day_type(scope, service_ids) do
    case Enum.find(day_types(scope), &(&1.service_ids == service_ids)) do
      nil -> flunk("no day type for #{inspect(service_ids)}")
      day_type -> day_type
    end
  end

  # Ecto runs a repo telemetry handler in the process that issued the query, so
  # recording only this test's own messages keeps other tests' queries out.
  defp query_log(fun) do
    test_pid = self()
    handler_id = "blocking-problems-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, pid ->
        if self() == pid, do: send(pid, {handler_id, metadata[:query] || ""})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    try do
      {fun.(), drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
