defmodule GtfsPlanner.Gtfs.Blocking.ConnectionChecksTest do
  @moduledoc """
  Merge evidence (EV-4) for the shared in-seat write rule (R1, CL-1, rejects FH-1, FH-2).

  One case covers each observation EV-4 rejects with:

  - the shared-trip fixture is refused for A → B with the no-school day type's label,
    its date count and the intervening trip X, although the pair is consecutive in the
    school day type and consecutive in the other block all the way through;
  - a pair that is consecutive in every day type both its trips run in is `:ok`;
  - a pair naming a trip of another version is `{:stale, :trip_missing}`;
  - a version of another organization is `{:error, :not_found}`;
  - `Blocking.lock_and_check_connections!/2`, called inside a caller's transaction,
    returns the same checks as the read plus the locked from/to trip rows, so the
    pre-check and a save cannot disagree (FH-2);
  - a pair whose second trip departs before the first arrives is the unconfirmed
    coupling, not a refusal to write.

  Every read goes through the ordinary facade `Gtfs.check_in_seat_connections/3` and
  every locked check through `Blocking.lock_and_check_connections!/2` in the caller's
  `Repo.transaction`, so the production composition is on the path. The focused gate
  command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/connection_checks_test.exs`.

  `async: false` because these cases share the lane database and the locked case opens
  its own transaction.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Repo

  # `W` runs on all three dates, so A, B, C and D share every date both of their
  # trips run in. `SCHOOL` runs on the last two and `NS` on the first, which derives
  # the two day types {School, Weekday} and {No school + Weekday}.
  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    %{scope: new_scope()}
  end

  describe "check_in_seat_connections/3" do
    test "a pair not consecutive on one day type is refused naming that day type", %{
      scope: scope
    } do
      %{a: a, b: b, c: c, d: d} = shared_trip_fixture(scope)
      no_school = DayTypes.key(["NS", "W"])

      failing = [
        %{key: no_school, label: "No school + Weekday", date_count: 1, next_trip_id: "X"}
      ]

      assert {:ok, checks} = check(scope, [ab(a, b), ab(c, d)])

      assert checks == %{
               ab(a, b) => {:refused, {:stale, {:not_next, failing}}},
               ab(c, d) => :ok
             }
    end

    test "a pair consecutive in every shared day type is ok", %{scope: scope} do
      %{a: a, b: b, c: c, d: d} = shared_trip_fixture(scope)

      assert {:ok, checks} = check(scope, [ab(c, d)])

      assert checks == %{ab(c, d) => :ok}
    end

    test "a pair naming a trip of another version is trip_missing", %{scope: scope} do
      %{a: a} = shared_trip_fixture(scope)
      other_version = gtfs_version_fixture(scope.organization.id)
      _foreign = trip(scope, %{trip_id: "foreign", version_id: other_version.id})

      assert {:ok, checks} = check(scope, [ab(a, "foreign")])

      assert checks == %{{"a", "foreign"} => {:refused, {:stale, :trip_missing}}}
    end

    test "a version of another organization is not found", %{scope: scope} do
      %{a: a, b: b} = shared_trip_fixture(scope)
      other = new_scope()

      assert {:error, :not_found} =
               Gtfs.check_in_seat_connections(scope.organization.id, other.version.id, [ab(a, b)])
    end

    test "a pair whose second trip departs before the first arrives is a coupling", %{
      scope: scope
    } do
      %{e: e, f: f} = shared_trip_fixture(scope)

      assert {:ok, checks} = check(scope, [ab(e, f)])

      assert checks == %{{"e", "f"} => {:refused, {:unconfirmed, :coupling}}}
    end
  end

  describe "lock_and_check_connections!/2" do
    test "returns the read's checks with the locked trip rows", %{scope: scope} do
      %{a: a, b: b, c: c, d: d, e: e, f: f} = shared_trip_fixture(scope)
      pairs = [ab(a, b), ab(c, d), ab(e, f)]

      no_school = DayTypes.key(["NS", "W"])

      failing = [
        %{key: no_school, label: "No school + Weekday", date_count: 1, next_trip_id: "X"}
      ]

      assert {:ok, read_checks} = check(scope, pairs)

      assert {:ok, locked} =
               Repo.transaction(fn ->
                 Blocking.lock_and_check_connections!(scope.audit, pairs)
               end)

      assert summarize(locked) == %{
               ab(a, b) => %{
                 from: "a",
                 to: "b",
                 check: {:refused, {:stale, {:not_next, failing}}}
               },
               ab(c, d) => %{from: "c", to: "d", check: :ok},
               ab(e, f) => %{from: "e", to: "f", check: {:refused, {:unconfirmed, :coupling}}}
             }

      assert Map.new(locked, fn {pair, result} -> {pair, result.check} end) == read_checks
    end

    test "a pair naming a trip of another version is a nil row and trip_missing", %{
      scope: scope
    } do
      %{a: a} = shared_trip_fixture(scope)
      other_version = gtfs_version_fixture(scope.organization.id)
      _foreign = trip(scope, %{trip_id: "foreign", version_id: other_version.id})

      assert {:ok, locked} =
               Repo.transaction(fn ->
                 Blocking.lock_and_check_connections!(scope.audit, [ab(a, "foreign")])
               end)

      assert summarize(locked) == %{
               {"a", "foreign"} => %{
                 from: "a",
                 to: nil,
                 check: {:refused, {:stale, :trip_missing}}
               }
             }
    end
  end

  # The locked trip rows carry the whole `Queries.trip_row/0` shape; the check is what
  # this gate observes, so the trips are reduced to their natural IDs.
  defp summarize(locked) do
    Map.new(locked, fn {pair, result} ->
      {pair,
       %{
         from: result.from && result.from.trip_id,
         to: result.to && result.to.trip_id,
         check: result.check
       }}
    end)
  end

  # R1's counterexample: A and B share block 101 in both day types, but on the
  # no-school date trip X runs on `NS` between them, so the pair may not be written.
  # C and D are consecutive in block 202 on every date, and E and F overlap in block
  # 303, so the coupling state is observable too.
  defp shared_trip_fixture(scope) do
    calendar_service_fixture(scope.organization.id, scope.version.id, %{
      service_id: "W",
      name: "Weekday",
      dates: @weekday_dates
    })

    calendar_service_fixture(scope.organization.id, scope.version.id, %{
      service_id: "SCHOOL",
      name: "School",
      dates: Enum.drop(@weekday_dates, 1)
    })

    calendar_service_fixture(scope.organization.id, scope.version.id, %{
      service_id: "NS",
      name: "No school",
      dates: Enum.take(@weekday_dates, 1)
    })

    a = trip(scope, %{trip_id: "a", block_id: "101", first: "06:00:00", last: "07:00:00"})

    _x =
      trip(scope, %{
        trip_id: "X",
        service_id: "NS",
        block_id: "101",
        first: "07:05:00",
        last: "08:05:00"
      })

    b = trip(scope, %{trip_id: "b", block_id: "101", first: "08:10:00", last: "09:10:00"})

    c = trip(scope, %{trip_id: "c", block_id: "202", first: "10:00:00", last: "11:00:00"})
    d = trip(scope, %{trip_id: "d", block_id: "202", first: "11:10:00", last: "12:10:00"})

    e = trip(scope, %{trip_id: "e", block_id: "303", first: "14:00:00", last: "15:00:00"})
    f = trip(scope, %{trip_id: "f", block_id: "303", first: "14:30:00", last: "15:30:00"})

    %{a: a, b: b, c: c, d: d, e: e, f: f}
  end

  # A pair may name a trip this version does not hold, so the id is passed as a
  # bare string there while every other case passes the trip row.
  defp ab(from, to), do: {trip_id(from), trip_id(to)}

  defp trip_id(%{trip_id: trip_id}), do: trip_id
  defp trip_id(trip_id) when is_binary(trip_id), do: trip_id

  defp check(scope, pairs) do
    Gtfs.check_in_seat_connections(scope.organization.id, scope.version.id, pairs)
  end

  # A trip on the scope's route, defaulting to the `W` service. `:version_id` names the
  # version the trip is written into, which is how the trip_missing case holds a trip
  # this version does not have.
  defp trip(scope, attrs) do
    attrs = Map.new(attrs)

    blocked_trip_fixture(
      scope.organization.id,
      Map.get(attrs, :version_id, scope.version.id),
      scope.route.route_id,
      attrs
      |> Map.take([:trip_id, :service_id, :block_id])
      |> Map.put_new(:service_id, "W")
      |> Map.merge(%{
        first_arrival: Map.get(attrs, :first, "08:00:00"),
        last_arrival: Map.get(attrs, :last, "09:00:00")
      })
    )
  end

  defp new_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      route: route_fixture(organization.id, version.id),
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end
end
