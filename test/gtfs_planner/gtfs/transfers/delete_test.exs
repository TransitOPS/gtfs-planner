defmodule GtfsPlanner.Gtfs.Transfers.DeleteTest do
  @moduledoc """
  Merge evidence (EV-11) for deleting general transfer rules.

  `Transfers.delete_general/3`, `Transfers.delete_general_many/2` and their
  `Gtfs.delete_general_transfer/3` and `Gtfs.delete_general_transfers/2` facades must
  delete a types 0-3 rule only when the caller's expected timestamp matches, delete an
  exact `{id, updated_at}` batch all-or-nothing, refuse a missing, foreign, other-version
  or type 4/5 target without touching a row, and write exactly one in-transaction
  `"deleted"` audit log per row with the stored snapshot, a shared operation id and every
  affected id.

  Deletion checks scope, type and freshness only, so the damaged rows here — a missing
  stop, a missing route, a missing trip and an entrance stop — must delete without
  reference validation. A list filter never defines the batch's scope; the caller
  enumerates exact pairs.

  The cases run against the shared literal network (`TransfersFixtures`) through the
  public functions, the real table constraints and a real audit-rejection trigger, so a
  delete that reaches a type 4/5 or foreign row, ignores staleness, applies a filter as
  scope, writes a partial batch or audits the wrong snapshot is rejected here. EV-11 does
  not prove the LiveView bulk confirm and exact-pair collection (EV-24), the SERIALIZABLE
  interleavings (EV-12) or the create and update paths (EV-9, EV-10).

  The focused command is deferred to branch review:
  `MIX_TEST_PARTITION=_xfer15 mix test test/gtfs_planner/gtfs/transfers/delete_test.exs`.
  """
  # The audit case below installs a constraint trigger on `change_logs`, and creating a
  # trigger takes SHARE ROW EXCLUSIVE on that table. An async module would hold that lock
  # for the life of its sandbox transaction and stall every concurrently running test that
  # writes a change log, so the module runs in the synchronous group like the identical
  # case in create_test.exs.
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.TransfersFixtures

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)
    actor = user_fixture()

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  describe "single delete" do
    test "deletes the row and writes one deleted log with the stored snapshot", ctx do
      row = rule(ctx, %{transfer_type: 2, min_transfer_time: 180})
      snapshot = Transfer.audit_snapshot(row)

      assert {:ok, deleted} = delete(row.id, row.updated_at, ctx)

      assert deleted.id == row.id
      assert Repo.get(Transfer, row.id) == nil

      assert [log] = transfer_logs(ctx)
      assert log.entity_type == "transfer"
      assert log.action == "deleted"
      assert log.entity_id == row.id
      assert log.entity_external_id == "CEN-A→CEN-C"
      assert log.organization_id == ctx.organization.id
      assert log.gtfs_version_id == ctx.version.id
      assert log.actor_id == ctx.actor.id

      assert MapSet.new(Map.keys(log.changed_fields)) ==
               MapSet.new(~w(before after operation_id affected_transfer_ids))

      assert log.changed_fields["before"] == snapshot
      assert log.changed_fields["after"] == nil
      assert log.changed_fields["affected_transfer_ids"] == [row.id]
      assert {:ok, _uuid} = Ecto.UUID.cast(log.changed_fields["operation_id"])
    end

    test "accepts the ISO 8601 string form of the stored updated_at", ctx do
      row = rule(ctx, %{transfer_type: 0})

      assert {:ok, deleted} = delete(row.id, DateTime.to_iso8601(row.updated_at), ctx)

      assert deleted.id == row.id
      assert Repo.get(Transfer, row.id) == nil
    end
  end

  describe "freshness" do
    test "refuses a different, nil and unparseable expected_updated_at and deletes nothing",
         ctx do
      row = rule(ctx, %{transfer_type: 2, min_transfer_time: 180})
      later = DateTime.add(row.updated_at, 1, :second)

      for expected <- [later, nil, "not-a-date"] do
        assert {:error, :stale} = delete(row.id, expected, ctx)
      end

      assert Repo.get!(Transfer, row.id) == row
      assert transfer_logs(ctx) == []
    end
  end

  describe "scope" do
    test "refuses a type 4 row, a foreign row, an unknown UUID and a non-UUID", ctx do
      in_seat =
        transfer_fixture(ctx.organization.id, ctx.version.id, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_trip_id: "12-1010",
          to_trip_id: "24-0920",
          transfer_type: 4
        })

      other_version = gtfs_version_fixture(ctx.organization.id)

      foreign =
        transfer_fixture(ctx.organization.id, other_version.id, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          transfer_type: 0
        })

      other_organization = organization_fixture()
      other_org_version = gtfs_version_fixture(other_organization.id)

      tenant =
        transfer_fixture(other_organization.id, other_org_version.id, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          transfer_type: 0
        })

      for id <- [in_seat.id, foreign.id, tenant.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :not_found} = delete(id, in_seat.updated_at, ctx)
      end

      assert Repo.get!(Transfer, in_seat.id) == in_seat
      assert Repo.get!(Transfer, foreign.id) == foreign
      assert Repo.get!(Transfer, tenant.id) == tenant
      assert transfer_logs(ctx) == []
      assert logs_for(other_organization.id, other_org_version.id) == []
    end
  end

  describe "bulk delete" do
    test "deletes three exact pairs with one shared operation id and every affected id", ctx do
      first = rule(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})
      second = rule(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 1})

      third =
        rule(ctx, %{
          from_stop_id: "MUS",
          to_stop_id: "CEN-A",
          transfer_type: 2,
          min_transfer_time: 120
        })

      pairs = [
        {first.id, first.updated_at},
        {second.id, second.updated_at},
        {third.id, third.updated_at}
      ]

      assert {:ok, 3} = Gtfs.delete_general_transfers(pairs, ctx.audit)

      assert Repo.get(Transfer, first.id) == nil
      assert Repo.get(Transfer, second.id) == nil
      assert Repo.get(Transfer, third.id) == nil

      logs = transfer_logs(ctx)
      assert length(logs) == 3
      assert Enum.all?(logs, &(&1.action == "deleted"))

      assert MapSet.new(Enum.map(logs, & &1.entity_id)) ==
               MapSet.new([first.id, second.id, third.id])

      assert [operation_id] = Enum.uniq(Enum.map(logs, & &1.changed_fields["operation_id"]))
      assert {:ok, _uuid} = Ecto.UUID.cast(operation_id)

      affected = Enum.sort([first.id, second.id, third.id])

      for log <- logs do
        assert Enum.sort(log.changed_fields["affected_transfer_ids"]) == affected
        assert log.changed_fields["after"] == nil
      end
    end

    test "refuses a type 4 pair and deletes nothing", ctx do
      first = rule(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})
      second = rule(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      in_seat =
        transfer_fixture(ctx.organization.id, ctx.version.id, %{
          from_stop_id: "MUS",
          to_stop_id: "HBR",
          from_trip_id: "12-1010",
          to_trip_id: "24-0920",
          transfer_type: 4
        })

      pairs = [
        {first.id, first.updated_at},
        {in_seat.id, in_seat.updated_at},
        {second.id, second.updated_at}
      ]

      assert {:error, :not_found} = delete_many(pairs, ctx)

      assert Repo.get!(Transfer, first.id) == first
      assert Repo.get!(Transfer, second.id) == second
      assert Repo.get!(Transfer, in_seat.id) == in_seat
      assert transfer_logs(ctx) == []
    end

    test "refuses a batch with a missing id and deletes nothing", ctx do
      first = rule(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})
      second = rule(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      pairs = [
        {first.id, first.updated_at},
        {Ecto.UUID.generate(), DateTime.utc_now()},
        {second.id, second.updated_at}
      ]

      assert {:error, :not_found} = delete_many(pairs, ctx)
      assert Repo.get!(Transfer, first.id) == first
      assert Repo.get!(Transfer, second.id) == second
      assert transfer_logs(ctx) == []
    end

    test "refuses a batch with one stale member and deletes nothing", ctx do
      first = rule(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})
      second = rule(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})
      third = rule(ctx, %{from_stop_id: "MUS", to_stop_id: "CEN-A", transfer_type: 1})

      pairs = [
        {first.id, first.updated_at},
        {second.id, second.updated_at},
        {third.id, DateTime.add(third.updated_at, 1, :second)}
      ]

      assert {:error, :stale} = delete_many(pairs, ctx)

      assert Repo.get!(Transfer, first.id) == first
      assert Repo.get!(Transfer, second.id) == second
      assert Repo.get!(Transfer, third.id) == third
      assert transfer_logs(ctx) == []
    end

    test "refuses the same id with two different timestamps", ctx do
      row = rule(ctx, %{transfer_type: 2, min_transfer_time: 180})

      pairs = [
        {row.id, row.updated_at},
        {row.id, DateTime.add(row.updated_at, 1, :second)}
      ]

      assert {:error, :stale} = delete_many(pairs, ctx)
      assert Repo.get!(Transfer, row.id) == row
      assert transfer_logs(ctx) == []
    end

    test "refuses case variants of one id with two different timestamps", ctx do
      row = rule(ctx, %{transfer_type: 2, min_transfer_time: 180})
      variant = String.upcase(row.id)
      assert variant != row.id

      pairs = [
        {row.id, row.updated_at},
        {variant, DateTime.add(row.updated_at, 1, :second)}
      ]

      assert {:error, :stale} = delete_many(pairs, ctx)
      assert Repo.get!(Transfer, row.id) == row
      assert transfer_logs(ctx) == []
    end

    test "treats case variants of one id with the same timestamp as one target", ctx do
      row = rule(ctx, %{transfer_type: 2, min_transfer_time: 180})

      pairs = [{row.id, row.updated_at}, {String.upcase(row.id), row.updated_at}]

      assert {:ok, 1} = delete_many(pairs, ctx)
      assert Repo.get(Transfer, row.id) == nil
      assert [log] = transfer_logs(ctx)
      assert log.changed_fields["affected_transfer_ids"] == [row.id]
    end

    test "treats a repeated id with the same timestamp as one target", ctx do
      row = rule(ctx, %{transfer_type: 2, min_transfer_time: 180})

      pairs = [{row.id, row.updated_at}, {row.id, row.updated_at}]

      assert {:ok, 1} = delete_many(pairs, ctx)
      assert Repo.get(Transfer, row.id) == nil
      assert [log] = transfer_logs(ctx)
      assert log.changed_fields["affected_transfer_ids"] == [row.id]
    end

    test "returns :invalid_input for an empty list and a malformed element", ctx do
      row = rule(ctx, %{transfer_type: 0})

      assert {:error, :invalid_input} = delete_many([], ctx)

      malformed = [
        [{row.id}],
        [{row.id, 123}],
        [{row.id, nil}],
        [%{id: row.id, updated_at: row.updated_at}],
        "not-a-list"
      ]

      for pairs <- malformed do
        assert {:error, :invalid_input} = delete_many(pairs, ctx)
      end

      assert Repo.get!(Transfer, row.id) == row
      assert transfer_logs(ctx) == []
    end
  end

  describe "damaged rows" do
    test "deletes rows naming a missing stop, route or trip and an entrance, singly and in bulk",
         ctx do
      ghost =
        transfer_fixture(ctx.organization.id, ctx.version.id, %{
          from_stop_id: "GHOST",
          to_stop_id: "HBR",
          transfer_type: 0
        })

      missing_route =
        transfer_fixture(ctx.organization.id, ctx.version.id, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "R404",
          transfer_type: 0
        })

      missing_trip =
        transfer_fixture(ctx.organization.id, ctx.version.id, %{
          from_stop_id: "MUS",
          to_stop_id: "HBR",
          from_trip_id: "T404",
          transfer_type: 0
        })

      entrance =
        transfer_fixture(ctx.organization.id, ctx.version.id, %{
          from_stop_id: "CEN-E",
          to_stop_id: "CEN-C",
          transfer_type: 0
        })

      ghost_snapshot = Transfer.audit_snapshot(ghost)

      assert {:ok, _deleted} = delete(ghost.id, ghost.updated_at, ctx)
      assert Repo.get(Transfer, ghost.id) == nil
      assert hd(transfer_logs(ctx)).changed_fields["before"] == ghost_snapshot

      damaged = [missing_route, missing_trip, entrance]
      snapshots = Map.new(damaged, &{&1.id, Transfer.audit_snapshot(&1)})

      assert {:ok, 3} = delete_many(Enum.map(damaged, &{&1.id, &1.updated_at}), ctx)

      for row <- damaged do
        assert Repo.get(Transfer, row.id) == nil
      end

      logs = Enum.reject(transfer_logs(ctx), &(&1.entity_id == ghost.id))
      assert length(logs) == 3

      for log <- logs do
        assert log.changed_fields["before"] == Map.fetch!(snapshots, log.entity_id)
      end
    end
  end

  describe "audit" do
    test "an audit rejection rolls the whole batch back and leaves every row", ctx do
      first = rule(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})
      second = rule(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})
      pairs = [{first.id, first.updated_at}, {second.id, second.updated_at}]

      install_transfer_delete_audit_rejection_trigger!()

      assert_raise Postgrex.Error, fn -> delete_many(pairs, ctx) end

      remove_transfer_delete_audit_rejection_trigger!()

      assert Repo.get!(Transfer, first.id) == first
      assert Repo.get!(Transfer, second.id) == second
      assert transfer_logs(ctx) == []
    end
  end

  defp delete(id, expected_updated_at, ctx),
    do: Gtfs.delete_general_transfer(id, expected_updated_at, ctx.audit)

  defp delete_many(pairs, ctx), do: Gtfs.delete_general_transfers(pairs, ctx.audit)

  defp rule(ctx, attrs) do
    transfer_fixture(
      ctx.organization.id,
      ctx.version.id,
      Map.merge(%{from_stop_id: "CEN-A", to_stop_id: "CEN-C"}, attrs)
    )
  end

  defp transfer_logs(ctx), do: logs_for(ctx.organization.id, ctx.version.id)

  defp logs_for(organization_id, gtfs_version_id) do
    Repo.all(
      from(cl in ChangeLog,
        where:
          cl.organization_id == ^organization_id and cl.gtfs_version_id == ^gtfs_version_id and
            cl.entity_type == "transfer",
        order_by: [asc: cl.inserted_at]
      )
    )
  end

  # Test-only fault injection: a constraint trigger on `change_logs` raises on the next
  # transfer audit insert, after the batch delete has run. It is created inside the
  # sandbox transaction, so the guaranteed test rollback removes it, and the test also
  # drops it explicitly. The names are unique to this file and the module is non-async,
  # so no other test can contend for them. No production failure switch exists.
  #
  # The raise stays recoverable: `delete_general_many/2` opens the outermost
  # `Repo.transaction/1` that the case issues, and the sandbox adapter turns that begin on
  # the already-transactional connection into a savepoint. The 23514 therefore unwinds
  # only to that savepoint, and the enclosing sandbox transaction is still usable for the
  # `DROP TRIGGER` and the reloads that follow.
  defp install_transfer_delete_audit_rejection_trigger! do
    Repo.query!("""
    CREATE FUNCTION transfer_delete_audit_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'transfer' THEN
        RAISE EXCEPTION 'transfer delete audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER transfer_delete_audit_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION transfer_delete_audit_rejection();
    """)
  end

  defp remove_transfer_delete_audit_rejection_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS transfer_delete_audit_rejection_trigger ON change_logs")
    Repo.query!("DROP FUNCTION IF EXISTS transfer_delete_audit_rejection()")
  end
end
