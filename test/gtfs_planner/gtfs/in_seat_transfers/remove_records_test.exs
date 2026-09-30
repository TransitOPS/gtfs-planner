defmodule GtfsPlanner.Gtfs.InSeatTransfers.RemoveRecordsTest do
  @moduledoc """
  Merge evidence (EV-9) for the audited in-seat record removal (R7, CL-7; AC-8;
  rejects FH-8).

  One case covers each observation EV-9 rejects with:

  - R7 — two listed type 4/5 rows with their own `updated_at` are both deleted,
    the call answers `{:ok, 2}`, and each deletion has its own `"deleted"` change
    log sharing one operation id and naming the removed row's stored snapshot
    (FH-8: misses logs, or a per-row query that never happens because the batch is
    one lock and one delete);
  - R7 — a listed type 2 row's id is `{:error, :not_found}` with nothing deleted:
    removal reaches a types 4–5 row only;
  - R7/INV-4 — one stale member makes the whole request `{:error, :stale}` and
    deletes nothing, so a batch is never partially removed (FH-8: partially deletes
    a stale batch);
  - R5/R7 — an id of another version is `{:error, :not_found}` with nothing
    deleted;
  - R7 — an empty list and a malformed pair are `{:error, :invalid_input}` before a
    transaction opens;
  - R7/INV-4 — an ISO 8601 string `updated_at` is accepted like a `DateTime`;
  - R7 — removal runs no reference validation, so a row an import left damaged
    (drifted stops naming no trip) is still removable.

  Every case goes through the ordinary facade `Gtfs.remove_in_seat_records/2`, so
  the production composition is on the path. The focused gate command is deferred to
  branch review:
  `MIX_TEST_PARTITION=_seat11 mix test test/gtfs_planner/gtfs/in_seat_transfers/remove_records_test.exs`.

  `async: false` because these cases share the lane database.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    other_version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{
      organization: organization,
      version: version,
      other_version: other_version,
      actor: actor,
      audit: audit
    }
  end

  describe "R7 — exactly the listed rows" do
    test "two listed rows are deleted and each deletion is audited", ctx do
      first = in_seat_row(ctx, %{transfer_type: 4, from_trip_id: "c", to_trip_id: "d"})
      second = in_seat_row(ctx, %{transfer_type: 5, from_trip_id: "e", to_trip_id: "f"})
      kept = in_seat_row(ctx, %{transfer_type: 4, from_trip_id: "g", to_trip_id: "h"})
      rows_before = transfer_row_count(ctx)

      assert {:ok, 2} = remove([target(first), target(second)], ctx)

      assert Repo.get(Transfer, first.id) == nil
      assert Repo.get(Transfer, second.id) == nil
      assert Repo.get(Transfer, kept.id) == kept
      assert transfer_row_count(ctx) == rows_before - 2

      assert [first_log, second_log] = transfer_logs(ctx)

      assert first_log.action == "deleted"
      assert first_log.entity_id == first.id
      assert first_log.entity_type == "transfer"
      assert first_log.changed_fields["before"] == Transfer.audit_snapshot(first)
      assert first_log.changed_fields["after"] == nil
      assert second_log.action == "deleted"
      assert second_log.entity_id == second.id

      # One operation id for the command, and both affected ids named by each log,
      # so one log reconstructs the whole removal (INV-5).
      operation_id = first_log.changed_fields["operation_id"]
      assert {:ok, _uuid} = Ecto.UUID.cast(operation_id)
      assert second_log.changed_fields["operation_id"] == operation_id

      assert Enum.sort(first_log.changed_fields["affected_transfer_ids"]) ==
               Enum.sort([first.id, second.id])

      assert Enum.sort(second_log.changed_fields["affected_transfer_ids"]) ==
               Enum.sort([first.id, second.id])
    end

    test "a damaged imported row is removed without reference validation", ctx do
      damaged =
        in_seat_row(ctx, %{
          transfer_type: 4,
          from_trip_id: "imported-a",
          to_trip_id: "imported-b",
          from_stop_id: "GONE",
          to_stop_id: "GONE"
        })

      assert {:ok, 1} = remove([target(damaged)], ctx)
      assert Repo.get(Transfer, damaged.id) == nil
      assert [log] = transfer_logs(ctx)
      assert log.action == "deleted"
    end
  end

  describe "R7 — the refusals delete nothing" do
    test "a type 0-3 row's id is not found with nothing deleted", ctx do
      general = in_seat_row(ctx, %{transfer_type: 2, from_stop_id: "A", to_stop_id: "B"})
      kept = in_seat_row(ctx, %{transfer_type: 4, from_trip_id: "g", to_trip_id: "h"})

      assert {:error, :not_found} = remove([target(general), target(kept)], ctx)

      # Neither the type 0-3 row nor its list-mate is touched.
      assert Repo.get(Transfer, general.id) == general
      assert Repo.get(Transfer, kept.id) == kept
      assert transfer_logs(ctx) == []
    end

    test "an unknown id is not found with nothing deleted", ctx do
      kept = in_seat_row(ctx, %{transfer_type: 5, from_trip_id: "g", to_trip_id: "h"})

      assert {:error, :not_found} =
               remove([target(kept), {Ecto.UUID.generate(), DateTime.utc_now()}], ctx)

      assert Repo.get(Transfer, kept.id) == kept
      assert transfer_logs(ctx) == []
    end

    test "one stale member makes the whole request stale with nothing deleted", ctx do
      fresh = in_seat_row(ctx, %{transfer_type: 4, from_trip_id: "c", to_trip_id: "d"})
      stale = in_seat_row(ctx, %{transfer_type: 5, from_trip_id: "e", to_trip_id: "f"})

      assert {:error, :stale} =
               remove(
                 [
                   {fresh.id, fresh.updated_at},
                   {stale.id, DateTime.add(stale.updated_at, -1, :second)}
                 ],
                 ctx
               )

      # The fresh member of the stale batch keeps its row, so no batch is ever
      # partially removed.
      assert Repo.get(Transfer, fresh.id) == fresh
      assert Repo.get(Transfer, stale.id) == stale
      assert transfer_logs(ctx) == []
    end

    test "an id of another version is not found with nothing deleted", ctx do
      foreign =
        transfer_fixture(ctx.organization.id, ctx.other_version.id, %{
          transfer_type: 4,
          from_trip_id: "foreign-a",
          to_trip_id: "foreign-b"
        })

      assert {:error, :not_found} = remove([target(foreign)], ctx)

      # The other version's row is untouched and the row carries no deletion here.
      assert Repo.get(Transfer, foreign.id) == foreign
      assert transfer_logs(ctx) == []
    end
  end

  describe "R7 — the input is checked before a transaction opens" do
    test "an empty list and a malformed pair are invalid input", ctx do
      row = in_seat_row(ctx, %{transfer_type: 4, from_trip_id: "c", to_trip_id: "d"})

      assert {:error, :invalid_input} = remove([], ctx)
      assert {:error, :invalid_input} = remove([{row.id}], ctx)
      assert {:error, :invalid_input} = remove([{:not, {row.id, row.updated_at}}], ctx)
      assert {:error, :invalid_input} = remove([{row.id, %{year: 2026}}, 42], ctx)

      assert Repo.get(Transfer, row.id) == row
      assert transfer_logs(ctx) == []
    end
  end

  test "an ISO 8601 string updated_at is accepted like a DateTime", ctx do
    row = in_seat_row(ctx, %{transfer_type: 5, from_trip_id: "e", to_trip_id: "f"})

    assert {:ok, 1} = remove([{row.id, DateTime.to_iso8601(row.updated_at)}], ctx)

    assert Repo.get(Transfer, row.id) == nil
    assert [log] = transfer_logs(ctx)
    assert log.action == "deleted"
    assert log.entity_id == row.id
  end

  # -- Observation helpers --------------------------------------------------

  defp remove(pairs, ctx), do: Gtfs.remove_in_seat_records(pairs, ctx.audit)

  defp target(row), do: {row.id, row.updated_at}

  # A type 4/5 record of this scope's version whose trips name nothing: removal
  # never evaluates the rule, so a row needs no trips to be listed or deleted.
  defp in_seat_row(ctx, attrs) do
    transfer_fixture(ctx.organization.id, ctx.version.id, Map.new(attrs))
  end

  defp transfer_row_count(ctx) do
    Repo.one!(
      from(t in Transfer,
        where:
          t.organization_id == ^ctx.organization.id and
            t.gtfs_version_id == ^ctx.version.id,
        select: count(t.id)
      )
    )
  end

  defp transfer_logs(ctx) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^ctx.organization.id and l.entity_type == "transfer",
        order_by: [asc: l.id]
      )
    )
  end
end
