defmodule GtfsPlanner.Gtfs.Transfers.UpdateTest do
  @moduledoc """
  Merge evidence (EV-10) for changing general transfer rules.

  `Transfers.update_general/4` and its `Gtfs.update_general_transfer/4` facade must
  change a types 0-3 rule only when the caller's expected timestamp matches the
  stored row, store nil for a type that carries no minimum time, refuse a bad
  reference with a field-keyed message and no write, recover a duplicate key after
  the rollback, return the row untouched when the submitted values change nothing,
  and write exactly one in-transaction `"updated"` audit log with the before and
  after snapshots.

  The cases run against the shared literal network (`TransfersFixtures`) through the
  public functions, the real table constraints and a real audit-rejection trigger,
  so an update that reaches a type 4/5 or foreign row, ignores staleness, writes on
  a no-op or audits the wrong snapshots is rejected here. EV-10 does not prove the
  SERIALIZABLE interleavings of two concurrent updates or of an update against trip
  deletion (EV-12), the delete paths (EV-11), the LiveView edit form (EV-21) or the
  retry counts already covered for the shared loop by EV-9.

  The focused command is deferred to branch review:
  `MIX_TEST_PARTITION=_xfer15 mix test test/gtfs_planner/gtfs/transfers/update_test.exs`.
  """
  # The audit case below installs a constraint trigger on `change_logs`, and creating a
  # trigger takes SHARE ROW EXCLUSIVE on that table. An async module would hold that lock
  # for the life of its sandbox transaction and stall every concurrently running test that
  # writes a change log, so the module runs in the synchronous group like the identical
  # cases in create_test.exs and delete_test.exs.
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.TransfersFixtures

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    TransfersFixtures.transfer_network_fixture(organization.id, version.id)
    actor = user_fixture()
    organization_membership_fixture(actor, organization)

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

  describe "changing a general rule" do
    test "changes the minimum time with the stored updated_at and advances it", ctx do
      row = general_rule(ctx, %{transfer_type: 2, min_transfer_time: 180})

      assert {:ok, updated} =
               update(
                 row.id,
                 %{
                   "from_stop_id" => "CEN-A",
                   "to_stop_id" => "CEN-C",
                   "transfer_type" => "2",
                   "min_transfer_time" => "240"
                 },
                 row.updated_at,
                 ctx
               )

      assert updated.id == row.id
      assert updated.transfer_type == 2
      assert updated.min_transfer_time == 240
      assert DateTime.compare(updated.updated_at, row.updated_at) == :gt
      assert reload(row.id) == updated
    end

    test "accepts the ISO 8601 string form of the stored updated_at", ctx do
      row = general_rule(ctx, %{transfer_type: 2, min_transfer_time: 180})

      assert {:ok, updated} =
               update(
                 row.id,
                 %{"transfer_type" => "2", "min_transfer_time" => "300"},
                 DateTime.to_iso8601(row.updated_at),
                 ctx
               )

      assert updated.min_transfer_time == 300
      assert DateTime.compare(updated.updated_at, row.updated_at) == :gt
    end

    test "stores nil when the rule changes to a type that carries no minimum time", ctx do
      row = general_rule(ctx, %{transfer_type: 2, min_transfer_time: 180})

      assert {:ok, updated} =
               update(
                 row.id,
                 %{"transfer_type" => "1", "min_transfer_time" => "300"},
                 row.updated_at,
                 ctx
               )

      assert updated.transfer_type == 1
      assert updated.min_transfer_time == nil
      assert reload(row.id).min_transfer_time == nil
    end

    test "returns the row untouched and writes nothing when no value changes", ctx do
      typed = general_rule(ctx, %{transfer_type: 2, min_transfer_time: 180})

      assert {:ok, returned} =
               update(
                 typed.id,
                 %{
                   "from_stop_id" => "CEN-A",
                   "to_stop_id" => "CEN-C",
                   "transfer_type" => "2",
                   "min_transfer_time" => "180"
                 },
                 typed.updated_at,
                 ctx
               )

      assert returned == typed
      assert transfer_logs(ctx) == []

      plain = general_rule(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      assert {:ok, plain_returned} =
               update(
                 plain.id,
                 %{
                   "from_stop_id" => "MKT",
                   "to_stop_id" => "HBR",
                   "transfer_type" => "0",
                   "min_transfer_time" => nil
                 },
                 plain.updated_at,
                 ctx
               )

      assert plain_returned == plain
      assert reload(plain.id).updated_at == plain.updated_at
      assert transfer_logs(ctx) == []
    end
  end

  describe "freshness" do
    test "refuses a different, nil and unparseable expected_updated_at without a write", ctx do
      row = general_rule(ctx, %{transfer_type: 2, min_transfer_time: 180})
      later = DateTime.add(row.updated_at, 1, :second)

      for expected <- [later, nil, "not-a-date"] do
        assert {:error, :stale} =
                 update(row.id, %{"min_transfer_time" => "240"}, expected, ctx)
      end

      assert reload(row.id) == row
      assert transfer_logs(ctx) == []
    end
  end

  describe "scope" do
    test "refuses a type 4 row, a foreign row, an unknown UUID and a non-UUID", ctx do
      in_seat =
        general_rule(ctx, %{
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
        assert {:error, :not_found} =
                 update(id, %{"transfer_type" => "1"}, in_seat.updated_at, ctx)
      end

      assert reload(in_seat.id) == in_seat
      assert reload(foreign.id) == foreign
      assert reload(tenant.id) == tenant
      assert transfer_logs(ctx) == []
      assert logs_for(other_organization.id, other_org_version.id) == []
    end

    test "refuses a crafted transfer_type 4 and ignores a submitted tenant", ctx do
      row = general_rule(ctx, %{transfer_type: 0})
      other = organization_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               update(
                 row.id,
                 %{
                   "transfer_type" => "4",
                   "organization_id" => other.id,
                   "gtfs_version_id" => Ecto.UUID.generate()
                 },
                 row.updated_at,
                 ctx
               )

      assert "Choose one of the four transfer types" in errors_on(changeset)[:transfer_type]
      assert reload(row.id) == row
      assert transfer_logs(ctx) == []
    end
  end

  describe "reference validation" do
    test "refuses a trip that does not stop at the rule's from stop", ctx do
      row = general_rule(ctx, %{from_stop_id: "MUS", to_stop_id: "HBR", transfer_type: 0})

      assert {:error, %Ecto.Changeset{} = changeset} =
               update(row.id, %{"from_trip_id" => "12-0815"}, row.updated_at, ctx)

      assert "This trip doesn't stop here" in errors_on(changeset)[:from_trip_id]
      assert reload(row.id) == row
      assert transfer_logs(ctx) == []
    end
  end

  describe "duplicate keys" do
    test "returns the other row's id and type and leaves the target unchanged", ctx do
      other = general_rule(ctx, %{from_stop_id: "MKT", to_stop_id: "MKT", transfer_type: 0})
      row = general_rule(ctx, %{transfer_type: 0})

      assert {:error, {:duplicate, collision}} =
               update(
                 row.id,
                 %{"from_stop_id" => "MKT", "to_stop_id" => "MKT"},
                 row.updated_at,
                 ctx
               )

      assert collision == %{id: other.id, transfer_type: 0}
      assert reload(row.id) == row
      assert transfer_logs(ctx) == []
    end
  end

  describe "audit" do
    test "writes one updated log with the before and after snapshots", ctx do
      row = general_rule(ctx, %{transfer_type: 2, min_transfer_time: 180})
      before_snapshot = Transfer.audit_snapshot(row)

      assert {:ok, updated} =
               Gtfs.update_general_transfer(
                 row.id,
                 %{"min_transfer_time" => "240"},
                 row.updated_at,
                 ctx.audit
               )

      assert [log] = transfer_logs(ctx)
      assert log.entity_type == "transfer"
      assert log.action == "updated"
      assert log.entity_id == row.id
      assert log.entity_external_id == "CEN-A→CEN-C"
      assert log.organization_id == ctx.organization.id
      assert log.gtfs_version_id == ctx.version.id
      assert log.actor_id == ctx.actor.id

      assert MapSet.new(Map.keys(log.changed_fields)) ==
               MapSet.new(~w(before after operation_id affected_transfer_ids))

      assert log.changed_fields["before"] == before_snapshot
      assert log.changed_fields["after"] == Transfer.audit_snapshot(updated)
      assert log.changed_fields["affected_transfer_ids"] == [row.id]
      assert {:ok, _uuid} = Ecto.UUID.cast(log.changed_fields["operation_id"])
    end

    test "a rejecting audit trigger raises and leaves the stored row unchanged", ctx do
      row = general_rule(ctx, %{transfer_type: 2, min_transfer_time: 180})

      install_transfer_update_audit_rejection_trigger!()

      assert_raise Postgrex.Error, fn ->
        update(row.id, %{"min_transfer_time" => "240"}, row.updated_at, ctx)
      end

      remove_transfer_update_audit_rejection_trigger!()

      assert reload(row.id) == row
      assert transfer_logs(ctx) == []
    end
  end

  defp update(id, attrs, expected_updated_at, ctx),
    do: Transfers.update_general(id, attrs, expected_updated_at, ctx.audit)

  defp general_rule(ctx, attrs) do
    transfer_fixture(
      ctx.organization.id,
      ctx.version.id,
      Map.merge(%{from_stop_id: "CEN-A", to_stop_id: "CEN-C"}, attrs)
    )
  end

  defp reload(id), do: Repo.get!(Transfer, id)

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

  # Test-only fault injection: a constraint trigger on `change_logs` raises on the
  # next transfer audit insert, after the transfer row is updated. It is created
  # inside the sandbox transaction, so the guaranteed test rollback removes it, and
  # the test also drops it explicitly. The names are unique to this file so a
  # concurrent async write test can never contend for them. No production failure
  # switch exists.
  defp install_transfer_update_audit_rejection_trigger! do
    Repo.query!("""
    CREATE FUNCTION transfer_update_audit_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'transfer' THEN
        RAISE EXCEPTION 'transfer audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER transfer_update_audit_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION transfer_update_audit_rejection();
    """)
  end

  defp remove_transfer_update_audit_rejection_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS transfer_update_audit_rejection_trigger ON change_logs")
    Repo.query!("DROP FUNCTION IF EXISTS transfer_update_audit_rejection()")
  end
end
