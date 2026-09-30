defmodule GtfsPlanner.Gtfs.InSeatTransfers.SetConnectionsTest do
  @moduledoc """
  Merge evidence (EV-8) for the bulk guarded connection write (R6, CL-6; AC-7;
  rejects FH-7).

  One case covers each observation EV-8 rejects with:

  - R6 — five pairs in one call, one refused by R1 and one stale under the guard,
    give three saved pairs and two skipped with their own reasons, and the skipped
    pairs are left exactly as they were (FH-7: one skip must not abort the batch);
  - R3/INV-5 — every `"transfer"` change log of one call shares the returned
    operation id, and no row outside the listed pairs' records is written;
  - R6 — `:not_stated` deletes the pairs' records and is never refused, not even for
    the pair R1 refuses;
  - R6 — 501 entries are `:too_many` and two entries for one pair are
    `:invalid_input`, both before a transaction opens;
  - R5/R6 — a pair naming a trip this version does not hold is skipped with
    `:not_found` while the other pairs save.

  Every case goes through the ordinary facade `Gtfs.set_in_seat_connections/3` over
  the same calendar and block fixture the rule and single-write gates use, so the
  production composition is on the path. The focused gate command is deferred to
  branch review:
  `MIX_TEST_PARTITION=_seat11 mix test test/gtfs_planner/gtfs/in_seat_transfers/set_connections_test.exs`.

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
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup do
    %{scope: new_scope()}
  end

  describe "R6 — one transaction, per-pair reasons" do
    test "one refused pair and one stale pair leave the other three saved", %{scope: scope} do
      %{a: a, b: b, c: c, d: d, e: e, f: f, g: g, h: h, i: i, j: j} = bulk_trip_fixture(scope)
      stored = in_seat_transfer_fixture(scope.organization.id, scope.version.id, e, f)
      rows_before = transfer_row_count(scope)

      entries = [
        entry(a, b, []),
        entry(c, d, []),
        entry(e, f, []),
        entry(g, h, []),
        entry(i, j, [])
      ]

      assert {:ok, %{saved: saved, skipped: skipped, operation_id: operation_id}} =
               save_all(scope, entries, :stay_on_board)

      assert operation_id

      # The refused pair (trip X runs between A and B on the no-school day type) and
      # the stale pair (a stored row the review did not list) are reported, and the
      # other three pairs commit with the batch (FH-7).
      assert saved == [{c.trip_id, d.trip_id}, {g.trip_id, h.trip_id}, {i.trip_id, j.trip_id}]

      assert [
               %{pair: {_, "b"}, reason: {:refused, {:stale, {:not_next, _}}}},
               %{pair: {_, "f"}, reason: :stale}
             ] = skipped

      # R2: each saved pair holds one type 4 row carrying the two endpoint stops.
      for {from_trip, to_trip} <- [{c, d}, {g, h}, {i, j}] do
        assert [%Transfer{transfer_type: 4} = row] = pair_rows(scope, from_trip, to_trip)
        assert row.from_stop_id == last_stop_id(scope, from_trip)
        assert row.to_stop_id == first_stop_id(scope, to_trip)
      end

      # The refused pair wrote nothing, and the stale pair still holds the row the
      # review saw, untouched.
      assert pair_rows(scope, a, b) == []
      assert [untouched] = pair_rows(scope, e, f)
      assert untouched.id == stored.id
      assert untouched.updated_at == stored.updated_at

      # No row outside the saved pairs' records was written.
      assert transfer_row_count(scope) == rows_before + 3
    end

    test "every log of one call shares the returned operation id", %{scope: scope} do
      %{c: c, d: d, e: e, f: f, g: g, h: h} = bulk_trip_fixture(scope)
      in_seat_transfer_fixture(scope.organization.id, scope.version.id, e, f)

      entries = [entry(c, d, []), entry(e, f, expected_rows(scope, e, f)), entry(g, h, [])]

      assert {:ok, %{saved: saved, skipped: [], operation_id: operation_id}} =
               save_all(scope, entries, :must_reboard)

      assert saved == [{c.trip_id, d.trip_id}, {e.trip_id, f.trip_id}, {g.trip_id, h.trip_id}]

      logs = change_logs(scope)
      assert length(logs) == 3
      assert Enum.all?(logs, &(get_in(&1, ["operation_id"]) == operation_id))
      assert transfer_logs(scope) == ["created", "updated", "created"]
    end

    test "a call in which nothing changes reports no operation id", %{scope: scope} do
      %{c: c, d: d, g: g, h: h} = bulk_trip_fixture(scope)

      assert {:ok, %{saved: saved, operation_id: operation_id}} =
               save_all(scope, [entry(c, d, []), entry(g, h, [])], :stay_on_board)

      assert saved == [{c.trip_id, d.trip_id}, {g.trip_id, h.trip_id}]
      assert operation_id

      assert {:ok, %{saved: ^saved, skipped: [], operation_id: nil}} =
               save_all(
                 scope,
                 [
                   entry(c, d, expected_rows(scope, c, d)),
                   entry(g, h, expected_rows(scope, g, h))
                 ],
                 :stay_on_board
               )

      assert length(transfer_logs(scope)) == 2
    end

    test ":not_stated deletes the records and is never refused", %{scope: scope} do
      %{a: a, b: b, c: c, d: d} = bulk_trip_fixture(scope)
      in_seat_transfer_fixture(scope.organization.id, scope.version.id, c, d)

      entries = [
        entry(a, b, []),
        entry(c, d, expected_rows(scope, c, d))
      ]

      assert {:ok, %{saved: saved, skipped: [], operation_id: operation_id}} =
               save_all(scope, entries, :not_stated)

      # A and B are the pair R1 refuses; "Not stated" writes no record, so it is
      # never refused and the pair is not reported as skipped.
      assert saved == [{a.trip_id, b.trip_id}, {c.trip_id, d.trip_id}]
      assert operation_id
      assert pair_rows(scope, a, b) == []
      assert pair_rows(scope, c, d) == []
      assert transfer_logs(scope) == ["deleted"]
    end

    test "a pair holding two rows is replaced by one row inside the batch", %{scope: scope} do
      %{c: c, d: d, g: g, h: h} = bulk_trip_fixture(scope)

      stopless =
        transfer_fixture(scope.organization.id, scope.version.id, %{
          from_trip_id: c.trip_id,
          to_trip_id: d.trip_id,
          transfer_type: 4
        })

      drift =
        transfer_fixture(scope.organization.id, scope.version.id, %{
          from_trip_id: c.trip_id,
          to_trip_id: d.trip_id,
          from_stop_id: "DRIFT",
          to_stop_id: "DRIFT",
          transfer_type: 5
        })

      expected = [expected_row(stopless), expected_row(drift)]

      assert {:ok, %{saved: [{_, _}], skipped: [], operation_id: operation_id}} =
               save_all(scope, [entry(c, d, expected), entry(g, h, [])], :must_reboard)

      assert operation_id

      # The kept row is the pair's first by id, rewritten with the endpoint stops,
      # and the other row is deleted: one row for the pair (R3).
      assert [kept] = pair_rows(scope, c, d)
      assert kept.transfer_type == 5
      assert kept.from_stop_id == last_stop_id(scope, c)
      assert kept.to_stop_id == first_stop_id(scope, d)
      assert Enum.sort(transfer_logs(scope)) == ["created", "deleted", "updated"]
      assert Enum.all?(change_logs(scope), &(get_in(&1, ["operation_id"]) == operation_id))
    end

    test "a pair naming a trip this version does not hold is skipped with :not_found", %{
      scope: scope
    } do
      %{a: a, c: c, d: d} = bulk_trip_fixture(scope)

      entries = [entry(a, "not-a-trip", []), entry(c, d, [])]

      assert {:ok, %{saved: saved, skipped: skipped, operation_id: operation_id}} =
               save_all(scope, entries, :stay_on_board)

      assert saved == [{c.trip_id, d.trip_id}]
      assert skipped == [%{pair: {a.trip_id, "not-a-trip"}, reason: :not_found}]
      assert operation_id
      assert pair_rows(scope, c, d) |> length() == 1
      assert transfer_logs(scope) == ["created"]
    end
  end

  describe "R6 — the input is checked before a transaction opens" do
    test "more than 500 entries is :too_many and writes nothing", %{scope: scope} do
      %{c: c, d: d} = bulk_trip_fixture(scope)
      rows_before = transfer_row_count(scope)
      entries = for _ <- 1..501, do: entry(c, d, [])

      assert {:error, :too_many} = save_all(scope, entries, :stay_on_board)
      assert transfer_row_count(scope) == rows_before
      assert transfer_logs(scope) == []
    end

    test "two entries for one pair is :invalid_input and writes nothing", %{scope: scope} do
      %{c: c, d: d} = bulk_trip_fixture(scope)
      rows_before = transfer_row_count(scope)

      assert {:error, :invalid_input} =
               save_all(scope, [entry(c, d, []), entry(c, d, [])], :stay_on_board)

      assert transfer_row_count(scope) == rows_before
      assert transfer_logs(scope) == []
    end

    test "a malformed entry is :invalid_input and writes nothing", %{scope: scope} do
      %{c: c, d: d} = bulk_trip_fixture(scope)
      rows_before = transfer_row_count(scope)

      assert {:error, :invalid_input} =
               save_all(scope, [%{pair: c.trip_id, expected: []}], :stay_on_board)

      assert {:error, :invalid_input} =
               save_all(
                 scope,
                 [%{pair: {c.trip_id, d.trip_id}, expected: [%{id: c.trip_id}]}],
                 :stay_on_board
               )

      assert {:error, :invalid_input} = save_all(scope, "all of them", :stay_on_board)
      assert transfer_row_count(scope) == rows_before
      assert transfer_logs(scope) == []
    end

    test "an unknown setting is :invalid_choice and writes nothing", %{scope: scope} do
      %{c: c, d: d} = bulk_trip_fixture(scope)
      rows_before = transfer_row_count(scope)

      assert {:error, :invalid_choice} = save_all(scope, [entry(c, d, [])], :stay_aboard)

      assert transfer_row_count(scope) == rows_before
      assert transfer_logs(scope) == []
    end
  end

  # -- Observation helpers --------------------------------------------------

  defp entry(from_trip, to_trip, expected),
    do: %{pair: {from_trip.trip_id, to_trip.trip_id}, expected: expected}

  defp save_all(scope, entries, choice),
    do: Gtfs.set_in_seat_connections(entries, choice, scope.audit)

  defp pair_rows(scope, from_trip, to_trip) do
    Repo.all(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id and t.from_trip_id == ^from_trip.trip_id and
            t.to_trip_id == ^to_trip.trip_id,
        order_by: [asc: t.id]
      )
    )
  end

  defp expected_rows(scope, from_trip, to_trip) do
    scope |> pair_rows(from_trip, to_trip) |> Enum.map(&expected_row/1)
  end

  defp expected_row(row),
    do: %{id: row.id, transfer_type: row.transfer_type, updated_at: row.updated_at}

  # Every transfer row of this scope, so a case can assert that the batch wrote
  # only the saved pairs' records.
  defp transfer_row_count(scope) do
    Repo.one!(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id,
        select: count(t.id)
      )
    )
  end

  # The `"transfer"` change logs of this scope in reading order; the operation id
  # of R9's shape travels in `changed_fields`, beside the before/after snapshots.
  defp change_logs(scope) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^scope.organization.id and l.entity_type == "transfer",
        order_by: [asc: l.id],
        select: l.changed_fields
      )
    )
  end

  defp transfer_logs(scope) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^scope.organization.id and l.entity_type == "transfer",
        order_by: [asc: l.id],
        select: l.action
      )
    )
  end

  # R1's counterexample (A and B) beside four pairs that are consecutive on every
  # date, so one call can carry a refused pair, a stale pair and three written ones.
  defp bulk_trip_fixture(scope) do
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
    e = trip(scope, %{trip_id: "e", block_id: "303", first: "10:00:00", last: "11:00:00"})
    f = trip(scope, %{trip_id: "f", block_id: "303", first: "11:10:00", last: "12:10:00"})
    g = trip(scope, %{trip_id: "g", block_id: "404", first: "10:00:00", last: "11:00:00"})
    h = trip(scope, %{trip_id: "h", block_id: "404", first: "11:10:00", last: "12:10:00"})
    i = trip(scope, %{trip_id: "i", block_id: "505", first: "10:00:00", last: "11:00:00"})
    j = trip(scope, %{trip_id: "j", block_id: "505", first: "11:10:00", last: "12:10:00"})

    %{a: a, b: b, c: c, d: d, e: e, f: f, g: g, h: h, i: i, j: j}
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
