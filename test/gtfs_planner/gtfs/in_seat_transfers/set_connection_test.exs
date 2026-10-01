defmodule GtfsPlanner.Gtfs.InSeatTransfers.SetConnectionTest do
  @moduledoc """
  Merge evidence (EV-5) for the single guarded connection write (R1–R5, CL-1, CL-2,
  CL-3, CL-5; AC-1 … AC-6; rejects FH-1, FH-2, FH-3, FH-4, FH-6).

  One case covers each observation EV-5 rejects with:

  - R1 — a pair that is consecutive in one block on the school day type but has
    trip X between its trips on the no-school day type is refused with that day
    type's label, date count and intervening trip, and writes no row and no log
    (FH-1);
  - R1/CR-2 — the refusal is the save's own answer, not a pre-check's: it is
    produced under the locks by the same `InSeat.state/2` rule, so the drawer's
    pre-check and the save cannot disagree (FH-2);
  - R2 — the written row is type 4, names the pair, stores the from-trip's last
    and the to-trip's first `stop_time` stop, and carries nil routes and no
    minimum time (FH-3);
  - R3 — a pair holding an imported stopless type 4 and a type 5 is replaced by
    exactly one type 5 row, with every change logged and all of one command's
    logs sharing one operation id (FH-4);
  - R3 — a choice that changes nothing writes no log and returns
    `operation_id: nil`;
  - R2 — a type 4 row whose `to_stop_id` drifted from the to-trip's first stop is
    rewritten by re-choosing stay on board, with one `"updated"` log, and the pair
    becomes `:matches`;
  - R4 — an `expected` list that omits a stored row is `{:error, :stale}` with no
    write;
  - R5 — a trip of another version is `{:error, :not_found}` with no write, and a
    foreign organization writes nothing (FH-6);
  - R3 — `:not_stated` deletes every row of the pair, logs each deletion, and is
    never refused.

  Every case goes through the ordinary facade `Gtfs.set_in_seat_connection/5` over
  the same `shared_trip_fixture/1` the rule gate uses, so the production
  composition is on the path. The focused gate command is deferred to branch
  review:
  `mix test test/gtfs_planner/gtfs/in_seat_transfers/set_connection_test.exs`.

  `async: false` because these cases share the lane database.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    %{scope: new_scope()}
  end

  describe "R1 — the write rule" do
    test "a pair not consecutive on one day type is refused and writes nothing", %{scope: scope} do
      %{a: a, b: b} = shared_trip_fixture(scope)
      no_school = DayTypes.key(["NS", "W"])

      failing = [
        %{key: no_school, label: "No school + Weekday", date_count: 1, next_trip_id: "X"}
      ]

      assert {:error, {:refused, {:stale, {:not_next, failures}}}} =
               save(scope, a, b, :stay_on_board, [])

      assert failures == failing
      assert pair_rows(scope, a, b) == []
      assert transfer_logs(scope) == []
    end

    test "the refusal is the same answer the read pre-check gives", %{scope: scope} do
      %{a: a, b: b} = shared_trip_fixture(scope)

      assert {:ok, checks} =
               Gtfs.check_in_seat_connections(scope.organization.id, scope.version.id, [
                 {a.trip_id, b.trip_id}
               ])

      assert {:error, {:refused, {:stale, {:not_next, _}}}} =
               save(scope, a, b, :stay_on_board, [])

      # The read carried the refusal the locked save then repeated, so the drawer's
      # pre-check and the save cannot disagree without a race (FH-2).
      assert {:refused, _state} = checks[{"a", "b"}]
    end

    test ":not_stated is never refused", %{scope: scope} do
      %{a: a, b: b} = shared_trip_fixture(scope)
      in_seat_transfer_fixture(scope.organization.id, scope.version.id, a, b)

      assert {:ok, %{choice: :not_stated, transfer: nil, operation_id: operation_id}} =
               save(scope, a, b, :not_stated, expected_rows(scope, a, b))

      assert operation_id
      assert pair_rows(scope, a, b) == []
      assert transfer_logs(scope) == ["deleted"]
    end
  end

  describe "R2 — the written stops" do
    test "the row stores the endpoint stops with no route or minimum time", %{scope: scope} do
      %{c: c, d: d} = shared_trip_fixture(scope)

      assert {:ok, %{choice: :stay_on_board, transfer: transfer, operation_id: operation_id}} =
               save(scope, c, d, :stay_on_board, [])

      assert operation_id
      assert transfer.transfer_type == 4
      assert transfer.from_trip_id == "c"
      assert transfer.to_trip_id == "d"
      assert transfer.from_stop_id == last_stop_id(scope, c)
      assert transfer.to_stop_id == first_stop_id(scope, d)
      assert transfer.from_route_id == nil
      assert transfer.to_route_id == nil
      assert transfer.min_transfer_time == nil

      # The stops are the trips' own `stop_time` rows, not a parent station and not
      # an imported row's stored value (FH-3).
      assert transfer.from_stop_id != transfer.to_stop_id
      assert pair_rows(scope, c, d) |> length() == 1
      assert transfer_logs(scope) == ["created"]
    end
  end

  describe "R3 — one record per pair, every change audited" do
    test "a stopless type 4 plus a type 5 leaves exactly one audited type 5 row", %{scope: scope} do
      %{c: c, d: d} = shared_trip_fixture(scope)

      imported =
        transfer_fixture(scope.organization.id, scope.version.id, %{
          from_trip_id: c.trip_id,
          to_trip_id: d.trip_id,
          transfer_type: 4
        })

      extra =
        transfer_fixture(scope.organization.id, scope.version.id, %{
          from_trip_id: c.trip_id,
          to_trip_id: d.trip_id,
          from_stop_id: "DRIFT",
          to_stop_id: "DRIFT",
          transfer_type: 5
        })

      expected = [expected_row(imported), expected_row(extra)]

      assert {:ok, %{choice: :must_reboard, transfer: transfer, operation_id: operation_id}} =
               save(scope, c, d, :must_reboard, expected)

      rows = pair_rows(scope, c, d)
      assert length(rows) == 1
      assert transfer.transfer_type == 5
      assert transfer.transfer_type == hd(rows).transfer_type
      assert transfer.from_stop_id == last_stop_id(scope, c)
      assert transfer.to_stop_id == first_stop_id(scope, d)

      # The kept row is the first by id and every change is logged: either two
      # "deleted" and one "created", or one "updated" and one "deleted".
      logs = transfer_logs(scope)

      assert Enum.sort(logs) in [
               ["created", "deleted", "deleted"],
               ["deleted", "updated"]
             ]

      assert Enum.all?(change_logs(scope), &(get_in(&1, ["operation_id"]) == operation_id))
    end

    test "choosing the saved setting on a matching record writes no log", %{scope: scope} do
      %{c: c, d: d} = shared_trip_fixture(scope)

      assert {:ok, _first} = save(scope, c, d, :must_reboard, [])
      before = pair_rows(scope, c, d)

      assert {:ok, %{choice: :must_reboard, transfer: transfer, operation_id: nil}} =
               save(scope, c, d, :must_reboard, expected_rows(scope, c, d))

      assert transfer.updated_at == hd(before).updated_at
      assert pair_rows(scope, c, d) == before
      assert transfer_logs(scope) == ["created"]
    end

    test "a drifted record is rewritten by re-choosing its saved type", %{scope: scope} do
      %{c: c, d: d} = shared_trip_fixture(scope)

      drifted =
        transfer_fixture(scope.organization.id, scope.version.id, %{
          from_trip_id: c.trip_id,
          to_trip_id: d.trip_id,
          from_stop_id: last_stop_id(scope, c),
          to_stop_id: "DUP_OLD",
          transfer_type: 4
        })

      assert {:ok, %{choice: :stay_on_board, transfer: transfer, operation_id: operation_id}} =
               save(scope, c, d, :stay_on_board, [expected_row(drifted)])

      assert operation_id
      assert transfer.id == drifted.id
      assert transfer.to_stop_id == first_stop_id(scope, d)
      assert transfer.from_stop_id == last_stop_id(scope, c)
      assert transfer_logs(scope) == ["updated"]

      # The rewritten row is the pair's one matching record (R2, AC-6).
      assert pair_state(scope, c, d) == :matches
    end

    test ":not_stated deletes every row of the pair and logs each deletion", %{scope: scope} do
      %{c: c, d: d} = shared_trip_fixture(scope)

      first =
        transfer_fixture(scope.organization.id, scope.version.id, %{
          from_trip_id: c.trip_id,
          to_trip_id: d.trip_id,
          transfer_type: 4
        })

      second =
        transfer_fixture(scope.organization.id, scope.version.id, %{
          from_trip_id: c.trip_id,
          to_trip_id: d.trip_id,
          from_stop_id: "OTHER",
          to_stop_id: "OTHER",
          transfer_type: 5
        })

      assert {:ok, %{choice: :not_stated, transfer: nil, operation_id: operation_id}} =
               save(scope, c, d, :not_stated, [expected_row(first), expected_row(second)])

      assert operation_id
      assert pair_rows(scope, c, d) == []
      assert transfer_logs(scope) == ["deleted", "deleted"]
      assert Enum.all?(change_logs(scope), &(get_in(&1, ["operation_id"]) == operation_id))
    end
  end

  describe "R4 — the expected-state guard" do
    test "an expected list omitting a stored row is stale with no write", %{scope: scope} do
      %{c: c, d: d} = shared_trip_fixture(scope)
      stored = in_seat_transfer_fixture(scope.organization.id, scope.version.id, c, d)

      assert {:error, :stale} = save(scope, c, d, :stay_on_board, [])

      assert pair_rows(scope, c, d) |> Enum.map(& &1.id) == [stored.id]
      assert transfer_logs(scope) == []
    end

    test "an expected row whose timestamp is stale is refused with no write", %{scope: scope} do
      %{c: c, d: d} = shared_trip_fixture(scope)
      stored = in_seat_transfer_fixture(scope.organization.id, scope.version.id, c, d)

      assert {:error, :stale} =
               save(scope, c, d, :stay_on_board, [
                 %{id: stored.id, transfer_type: 4, updated_at: shifted(stored.updated_at)}
               ])

      assert transfer_logs(scope) == []
    end

    test "a stored type the expected list does not name is stale", %{scope: scope} do
      %{c: c, d: d} = shared_trip_fixture(scope)
      stored = in_seat_transfer_fixture(scope.organization.id, scope.version.id, c, d)

      assert {:error, :stale} =
               save(scope, c, d, :stay_on_board, [
                 %{id: stored.id, transfer_type: 5, updated_at: stored.updated_at}
               ])

      assert transfer_logs(scope) == []
    end
  end

  describe "R5 — scope" do
    test "a trip of another version is not found with no write", %{scope: scope} do
      %{a: a} = shared_trip_fixture(scope)
      other_version = gtfs_version_fixture(scope.organization.id)
      _foreign = trip(scope, %{trip_id: "foreign", version_id: other_version.id})

      assert {:error, :not_found} = save(scope, a, "foreign", :stay_on_board, [])
      assert pair_rows(scope, a, "foreign") == []
      assert transfer_logs(scope) == []
    end

    test "a version of another organization writes nothing", %{scope: scope} do
      %{c: c, d: d} = shared_trip_fixture(scope)
      other = new_scope()

      assert {:error, :not_found} =
               Gtfs.set_in_seat_connection(
                 c.trip_id,
                 d.trip_id,
                 :stay_on_board,
                 [],
                 other.audit
               )

      assert pair_rows(scope, c, d) == []
      assert transfer_logs(scope) == []
    end
  end

  test "an unknown choice is refused before a transaction opens", %{scope: scope} do
    %{c: c, d: d} = shared_trip_fixture(scope)

    assert {:error, :invalid_choice} = save(scope, c, d, :stay_aboard, [])
    assert pair_rows(scope, c, d) == []
    assert transfer_logs(scope) == []
  end

  # -- Observation helpers --------------------------------------------------

  defp save(scope, from_trip, to_trip, choice, expected) do
    Gtfs.set_in_seat_connection(
      trip_id(from_trip),
      trip_id(to_trip),
      choice,
      expected,
      scope.audit
    )
  end

  # A pair may name a trip this version does not hold, so the id is passed as a
  # bare string there while every other case passes the trip row.
  defp trip_id(%{trip_id: trip_id}), do: trip_id
  defp trip_id(trip_id) when is_binary(trip_id), do: trip_id

  defp pair_rows(scope, from_trip, to_trip) do
    Repo.all(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id and
            t.from_trip_id == ^trip_id(from_trip) and t.to_trip_id == ^trip_id(to_trip),
        order_by: [asc: t.id]
      )
    )
  end

  defp expected_rows(scope, from_trip, to_trip) do
    scope |> pair_rows(from_trip, to_trip) |> Enum.map(&expected_row/1)
  end

  defp expected_row(row),
    do: %{id: row.id, transfer_type: row.transfer_type, updated_at: row.updated_at}

  # One second past the stored timestamp: a different `updated_at` never matches.
  defp shifted(%DateTime{} = updated_at) do
    DateTime.add(updated_at, 1, :second)
  end

  # The pair's one record state, read from the production day load, so the drift
  # case asserts the promise (`:matches`) from the same `InSeat.state/2` the
  # Blocks page reads rather than from a second rule (INV-2).
  defp pair_state(scope, from_trip, to_trip) do
    assert {:ok, day} = Gtfs.load_blocking_day(scope.organization.id, scope.version.id, nil)

    entries = Map.get(day.in_seat, from_trip.id, [])

    entry =
      Enum.find(entries, fn candidate ->
        candidate.row.from_trip_id == trip_id(from_trip) and
          candidate.row.to_trip_id == trip_id(to_trip)
      end)

    assert entry, "the day load lists no in-seat record for the pair"

    entry.state
  end

  # The `"transfer"` change logs of this scope in reading order; the operation id
  # of R9's shape travels in `changed_fields`, beside the before/after snapshots.
  defp change_logs(scope) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^scope.organization.id and l.entity_type == "transfer",
        order_by: [asc: l.inserted_at, asc: l.id],
        select: l.changed_fields
      )
    )
  end

  defp transfer_logs(scope) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^scope.organization.id and l.entity_type == "transfer",
        order_by: [asc: l.inserted_at, asc: l.id],
        select: l.action
      )
    )
  end

  # R1's counterexample: A and B share block 101 in both day types, but on the
  # no-school date trip X runs on `NS` between them, so the pair may not be
  # written. C and D are consecutive in block 202 on every date.
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

    %{a: a, b: b, c: c, d: d}
  end

  defp trip(scope, attrs) do
    attrs = Map.new(attrs)

    blocked_trip_fixture(
      scope.organization.id,
      Map.get(attrs, :version_id, scope.version.id),
      scope.route.route_id,
      attrs
      |> Map.take([:trip_id, :service_id, :block_id, :first_stop, :last_stop])
      |> Map.put_new(:service_id, "W")
      |> Map.merge(%{
        first_arrival: Map.get(attrs, :first, "08:00:00"),
        last_arrival: Map.get(attrs, :last, "09:00:00")
      })
    )
  end

  defp first_stop_id(scope, trip), do: endpoint_stop_id(scope, trip, :asc)

  defp last_stop_id(scope, trip), do: endpoint_stop_id(scope, trip, :desc)

  defp endpoint_stop_id(scope, trip, direction) do
    Repo.one!(
      from(st in StopTime,
        where:
          st.organization_id == ^scope.organization.id and
            st.gtfs_version_id == ^scope.version.id and st.trip_id == ^trip.trip_id,
        order_by: [{^direction, st.stop_sequence}],
        limit: 1,
        select: st.stop_id
      )
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
