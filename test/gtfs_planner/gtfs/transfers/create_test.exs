defmodule GtfsPlanner.Gtfs.Transfers.CreateTest do
  @moduledoc """
  Merge evidence (EV-9) for creating general transfer rules.

  `Transfers.create_general/2` and its `Gtfs.create_general_transfer/2` facade must
  create a types 0-3 rule from the audit context's scope, refuse a bad reference with
  a field-keyed message and no write, recover a duplicate key after the rollback,
  write exactly one in-transaction `"transfer"` audit log, and retry a serialization
  failure or a deadlock before `:busy`.

  The cases run against the shared literal network (`TransfersFixtures`) through the
  public functions, the real table constraints and a real audit-rejection trigger, so
  a create that skips server validation, raises on a duplicate, writes an unaudited
  row or does not retry 40001/40P01 is rejected here. EV-9 does not prove the
  SERIALIZABLE interleavings (EV-12), the update and delete paths (EV-10, EV-11), the
  LiveView form (EV-20) or the validator verdict (EV-14).

  The focused command is deferred to branch review:
  `MIX_TEST_PARTITION=_xfer15 mix test test/gtfs_planner/gtfs/transfers/create_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Mox

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.TransfersFixtures

  # The retry cases swap :gtfs_planner, :reviewed_apply_transaction, so the module
  # is non-async and restores the previous adapter after each test.
  setup do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

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

  describe "creation" do
    test "uses the audit context's organization and version, ignoring a submitted tenant", ctx do
      other = organization_fixture()

      assert {:ok, transfer} =
               create(
                 %{
                   "from_stop_id" => "CEN-A",
                   "to_stop_id" => "CEN-C",
                   "transfer_type" => "0",
                   "organization_id" => other.id,
                   "gtfs_version_id" => Ecto.UUID.generate()
                 },
                 ctx
               )

      assert transfer.organization_id == ctx.organization.id
      assert transfer.gtfs_version_id == ctx.version.id
      assert transfer.transfer_type == 0
      assert transfer.min_transfer_time == nil
      assert Repo.get!(Transfer, transfer.id) == transfer
    end

    test "creates a station rule, a route pair, a trip-and-route pair and an inactive route",
         ctx do
      assert {:ok, station} =
               create(
                 %{
                   "from_stop_id" => "CEN",
                   "to_stop_id" => "CEN",
                   "transfer_type" => "2",
                   "min_transfer_time" => "180"
                 },
                 ctx
               )

      assert station.transfer_type == 2
      assert station.min_transfer_time == 180

      assert {:ok, route_pair} =
               create(
                 %{
                   "from_stop_id" => "MKT",
                   "to_stop_id" => "MKT",
                   "from_route_id" => "12",
                   "to_route_id" => "24",
                   "transfer_type" => "1"
                 },
                 ctx
               )

      assert {route_pair.from_route_id, route_pair.to_route_id} == {"12", "24"}
      assert route_pair.min_transfer_time == nil

      assert {:ok, trip_and_route} =
               create(
                 %{
                   "from_stop_id" => "CEN",
                   "to_stop_id" => "HBR",
                   "from_route_id" => "12",
                   "from_trip_id" => "12-0815",
                   "to_route_id" => "24",
                   "transfer_type" => "0"
                 },
                 ctx
               )

      # 12-0815 stops at the child platform CEN-A, which the station endpoint covers.
      assert trip_and_route.from_trip_id == "12-0815"

      assert {:ok, inactive} =
               create(
                 %{
                   "from_stop_id" => "MKT",
                   "to_stop_id" => "HBR",
                   "from_route_id" => "99",
                   "from_trip_id" => "99-0700",
                   "transfer_type" => "0"
                 },
                 ctx
               )

      assert inactive.from_route_id == "99"
    end

    test "creates through the Gtfs facade and observes the same audit", ctx do
      assert {:ok, transfer} = Gtfs.create_general_transfer(valid_attrs(), ctx.audit)
      assert transfer.from_stop_id == "CEN-A"
      assert [log] = transfer_logs(ctx)
      assert log.entity_id == transfer.id
    end
  end

  describe "reference validation" do
    test "refuses an entrance stop and a stop absent from the version", ctx do
      refusal(
        %{"from_stop_id" => "CEN-E", "to_stop_id" => "CEN-C", "transfer_type" => "0"},
        ctx,
        :from_stop_id,
        "Choose a stop, platform or station"
      )

      refusal(
        %{"from_stop_id" => "GHOST", "to_stop_id" => "CEN-C", "transfer_type" => "0"},
        ctx,
        :from_stop_id,
        "Choose a stop or station in this version"
      )

      other_version = gtfs_version_fixture(ctx.organization.id)

      stop_fixture(ctx.organization.id, other_version.id, %{
        stop_id: "ELSEWHERE",
        stop_name: "Elsewhere"
      })

      refusal(
        %{"from_stop_id" => "ELSEWHERE", "to_stop_id" => "CEN-C", "transfer_type" => "0"},
        ctx,
        :from_stop_id,
        "Choose a stop or station in this version"
      )
    end

    test "refuses a missing route, a missing trip, a wrong-route trip and a trip that does not stop here",
         ctx do
      refusal(
        %{
          "from_stop_id" => "MKT",
          "to_stop_id" => "HBR",
          "from_route_id" => "R404",
          "transfer_type" => "0"
        },
        ctx,
        :from_route_id,
        "Choose a route in this version"
      )

      refusal(
        %{
          "from_stop_id" => "MKT",
          "to_stop_id" => "HBR",
          "from_trip_id" => "T404",
          "transfer_type" => "0"
        },
        ctx,
        :from_trip_id,
        "Choose a trip in this version"
      )

      refusal(
        %{
          "from_stop_id" => "MKT",
          "to_stop_id" => "HBR",
          "from_route_id" => "24",
          "from_trip_id" => "12-0815",
          "transfer_type" => "0"
        },
        ctx,
        :from_trip_id,
        "This trip is on a different route"
      )

      refusal(
        %{
          "from_stop_id" => "MUS",
          "to_stop_id" => "HBR",
          "from_trip_id" => "12-0815",
          "transfer_type" => "0"
        },
        ctx,
        :from_trip_id,
        "This trip doesn't stop here"
      )
    end

    test "treats another version's route and trip as missing", ctx do
      other_version = gtfs_version_fixture(ctx.organization.id)

      route_fixture(ctx.organization.id, other_version.id, %{route_id: "FOR-12"})
      trip_fixture(ctx.organization.id, other_version.id, "FOR-12", %{trip_id: "FOR-0815"})

      refusal(
        %{
          "from_stop_id" => "MKT",
          "to_stop_id" => "HBR",
          "from_route_id" => "FOR-12",
          "transfer_type" => "0"
        },
        ctx,
        :from_route_id,
        "Choose a route in this version"
      )

      refusal(
        %{
          "from_stop_id" => "MKT",
          "to_stop_id" => "HBR",
          "from_trip_id" => "FOR-0815",
          "transfer_type" => "0"
        },
        ctx,
        :from_trip_id,
        "Choose a trip in this version"
      )
    end

    test "refuses transfer_type 4 with the inclusion error and writes nothing", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               create(
                 %{
                   "from_trip_id" => "12-0815",
                   "to_trip_id" => "24-0840",
                   "transfer_type" => "4"
                 },
                 ctx
               )

      assert "Choose one of the four transfer types" in errors_on(changeset)[:transfer_type]
      assert transfer_count(ctx) == 0
      assert transfer_logs(ctx) == []
    end
  end

  describe "duplicate keys" do
    test "returns the existing general row's id and type after the rollback", ctx do
      existing =
        transfer_fixture(ctx.organization.id, ctx.version.id, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          transfer_type: 0
        })

      assert {:error, {:duplicate, collision}} =
               create(
                 %{"from_stop_id" => "CEN-A", "to_stop_id" => "CEN-C", "transfer_type" => "3"},
                 ctx
               )

      assert collision == %{id: existing.id, transfer_type: 0}
      assert transfer_count(ctx) == 1
      assert transfer_logs(ctx) == []
    end

    test "returns an in-seat row that holds the same key", ctx do
      in_seat =
        transfer_fixture(ctx.organization.id, ctx.version.id, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_trip_id: "12-1010",
          to_trip_id: "24-0920",
          transfer_type: 4
        })

      assert {:error, {:duplicate, collision}} =
               create(
                 %{
                   "from_stop_id" => "MKT",
                   "to_stop_id" => "HBR",
                   "from_trip_id" => "12-1010",
                   "to_trip_id" => "24-0920",
                   "transfer_type" => "0"
                 },
                 ctx
               )

      assert collision == %{id: in_seat.id, transfer_type: 4}
      assert transfer_count(ctx) == 1
      assert transfer_logs(ctx) == []
    end
  end

  describe "audit" do
    test "writes exactly one created log with the R9 envelope and snapshot", ctx do
      assert {:ok, transfer} = create(valid_attrs(), ctx)

      assert [log] = transfer_logs(ctx)
      assert log.entity_type == "transfer"
      assert log.action == "created"
      assert log.entity_id == transfer.id
      assert log.entity_external_id == "CEN-A→CEN-C"
      assert log.organization_id == ctx.organization.id
      assert log.gtfs_version_id == ctx.version.id
      assert log.actor_id == ctx.actor.id

      assert MapSet.new(Map.keys(log.changed_fields)) ==
               MapSet.new(~w(before after operation_id affected_transfer_ids))

      assert log.changed_fields["before"] == nil
      assert log.changed_fields["after"] == Transfer.audit_snapshot(transfer)
      assert log.changed_fields["affected_transfer_ids"] == [transfer.id]
      assert {:ok, _uuid} = Ecto.UUID.cast(log.changed_fields["operation_id"])
    end

    test "a rejecting audit trigger raises and leaves no transfer row", ctx do
      install_transfer_audit_rejection_trigger!()

      assert_raise Postgrex.Error, fn -> create(valid_attrs(), ctx) end

      remove_transfer_audit_rejection_trigger!()

      assert transfer_count(ctx) == 0
      assert transfer_logs(ctx) == []
    end
  end

  describe "retry loop" do
    setup :verify_on_exit!

    test "returns :busy after three serialization failures and writes nothing", ctx do
      use_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, 3, fn _transaction ->
        raise postgrex_error("40001", "serialization failure")
      end)

      assert {:error, :busy} = create(valid_attrs(), ctx)
      assert transfer_count(ctx) == 0
      assert transfer_logs(ctx) == []
    end

    test "retries a deadlock and commits through the ordinary sandbox adapter", ctx do
      use_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, fn _transaction ->
        Application.put_env(
          :gtfs_planner,
          :reviewed_apply_transaction,
          ReviewedApplyTransaction.Sandbox
        )

        raise postgrex_error("40P01", "deadlock detected")
      end)

      assert {:ok, transfer} = create(valid_attrs(), ctx)
      assert transfer.from_stop_id == "CEN-A"
      assert [log] = transfer_logs(ctx)
      assert log.entity_id == transfer.id
    end
  end

  defp create(attrs, ctx), do: Transfers.create_general(attrs, ctx.audit)

  defp valid_attrs do
    %{"from_stop_id" => "CEN-A", "to_stop_id" => "CEN-C", "transfer_type" => "0"}
  end

  defp refusal(attrs, ctx, field, message) do
    assert {:error, %Ecto.Changeset{} = changeset} = create(attrs, ctx)
    assert message in (errors_on(changeset)[field] || [])
    assert transfer_count(ctx) == 0
    assert transfer_logs(ctx) == []
  end

  defp transfer_count(ctx) do
    Repo.aggregate(
      from(t in Transfer,
        where: t.organization_id == ^ctx.organization.id and t.gtfs_version_id == ^ctx.version.id
      ),
      :count
    )
  end

  defp transfer_logs(ctx) do
    Repo.all(
      from(cl in ChangeLog,
        where:
          cl.organization_id == ^ctx.organization.id and cl.gtfs_version_id == ^ctx.version.id and
            cl.entity_type == "transfer",
        order_by: [asc: cl.inserted_at]
      )
    )
  end

  defp use_transaction_mock do
    Application.put_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransactionMock
    )
  end

  defp postgrex_error(code, message) do
    Postgrex.Error.exception(postgres: %{code: code, severity: "ERROR", message: message})
  end

  # Test-only fault injection: a constraint trigger on `change_logs` raises on the
  # next transfer audit insert, after the transfer row is written. It is created
  # inside the sandbox transaction, so the guaranteed test rollback removes it, and
  # the test also drops it explicitly. No production failure switch exists.
  defp install_transfer_audit_rejection_trigger! do
    Repo.query!("""
    CREATE FUNCTION transfer_audit_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'transfer' THEN
        RAISE EXCEPTION 'transfer audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER transfer_audit_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION transfer_audit_rejection();
    """)
  end

  defp remove_transfer_audit_rejection_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS transfer_audit_rejection_trigger ON change_logs")
    Repo.query!("DROP FUNCTION IF EXISTS transfer_audit_rejection()")
  end
end
