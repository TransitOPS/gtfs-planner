defmodule GtfsPlanner.Gtfs.Schedules.DeleteTripsTransferAuditTest do
  @moduledoc """
  Merge evidence (EV-11) for the audited removal of transfers by trip deletion
  (R11, CL-9; AC-10; rejects FH-10).

  One case covers each observation EV-11 rejects with:

  - R11 — deleting a trip named by two transfer rows answers
    `{:ok, %{trips: 1, transfers: 2}}` and writes two `"deleted"` `"transfer"`
    change logs, each carrying that row's before snapshot and both affected
    transfer ids, sharing the trip log's `operation_id` (FH-10: transfers still
    removed unaudited, or the counts change);
  - R11 — a trip no transfer names removes none and writes no transfer log
    (FH-10: an empty cleanup still logs);
  - R11 — a general type 0–3 row naming the deleted trip is removed and audited
    by the same cleanup, with the same counts, because the scope is the existing
    `trip_transfers_query/3` rather than a type 4/5 filter;
  - INV-5 — a refused change log for a transfer rolls the whole deletion back,
    so the trip and every transfer remain and no log is written (FH-10: a
    deletion that commits rows the audit could not record).

  Every case runs through the production composition `Gtfs.delete_trips/4` →
  `Schedules.delete_trips/4`, and the audit failure is the audit layer's own
  refused changeset, produced by a context whose actor is missing, so the
  production transaction runs for real.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 mix test test/gtfs_planner/gtfs/schedules/delete_trips_transfer_audit_test.exs`.
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
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    scope = schedule_scope!(organization, version, audit, "10a")

    %{
      organization: organization,
      version: version,
      audit: audit,
      scope: scope
    }
  end

  test "a trip named by two transfers removes and audits both under one operation", ctx do
    trip = trip!(ctx, "10a-0", "06:00:00")
    follower = trip!(ctx, "10a-1", "07:00:00")

    inbound =
      transfer_fixture(ctx.organization.id, ctx.version.id, %{
        transfer_type: 4,
        from_trip_id: follower.trip_id,
        to_trip_id: trip.trip_id,
        from_stop_id: "B",
        to_stop_id: "A"
      })

    outbound =
      transfer_fixture(ctx.organization.id, ctx.version.id, %{
        transfer_type: 5,
        from_trip_id: trip.trip_id,
        to_trip_id: "10a-2",
        from_stop_id: "A",
        to_stop_id: "B"
      })

    assert {:ok, %{trips: 1, transfers: 2}} =
             Gtfs.delete_trips(ctx.scope.route_id, ctx.scope.service, [trip.id], ctx.audit)

    # The counts are the ones the existing cleanup reported, and the rows are gone.
    assert Repo.get(Transfer, inbound.id) == nil
    assert Repo.get(Transfer, outbound.id) == nil
    assert Repo.get(Trip, trip.id) == nil

    assert [inbound_log, outbound_log] = transfer_logs(ctx)
    assert inbound_log.action == "deleted"
    assert outbound_log.action == "deleted"
    assert inbound_log.entity_id == inbound.id
    assert outbound_log.entity_id == outbound.id
    assert Enum.all?([inbound_log, outbound_log], &(&1.entity_type == "transfer"))

    # Each log reconstructs its own row, and names every affected row.
    assert inbound_log.changed_fields["before"] == Transfer.audit_snapshot(inbound)
    assert outbound_log.changed_fields["before"] == Transfer.audit_snapshot(outbound)
    assert Enum.all?([inbound_log, outbound_log], &(&1.changed_fields["after"] == nil))

    affected = Enum.sort([inbound.id, outbound.id])

    assert Enum.all?(
             [inbound_log, outbound_log],
             &(&1.changed_fields["affected_transfer_ids"] == affected)
           )

    # One operation id for the whole deletion, shared with the trip logs (R11).
    operation_id = inbound_log.changed_fields["operation_id"]
    assert {:ok, _uuid} = Ecto.UUID.cast(operation_id)
    assert outbound_log.changed_fields["operation_id"] == operation_id

    assert [trip_log] = trip_logs(ctx)
    assert trip_log.action == "deleted"
    assert trip_log.entity_id == trip.id
    assert trip_log.changed_fields["operation_id"] == operation_id
  end

  test "a trip no transfer names writes no transfer log", ctx do
    trip = trip!(ctx, "10b-0", "06:00:00")
    _other = trip!(ctx, "10b-1", "07:00:00")

    kept =
      transfer_fixture(ctx.organization.id, ctx.version.id, %{
        transfer_type: 4,
        from_trip_id: "unrelated-a",
        to_trip_id: "unrelated-b",
        from_stop_id: "A",
        to_stop_id: "B"
      })

    assert {:ok, %{trips: 1, transfers: 0}} =
             Gtfs.delete_trips(ctx.scope.route_id, ctx.scope.service, [trip.id], ctx.audit)

    assert transfer_logs(ctx) == []
    assert Repo.get(Transfer, kept.id) == kept
    assert [trip_log] = trip_logs(ctx)
    assert trip_log.action == "deleted"
  end

  test "a general type 0-3 transfer naming the trip is removed and audited too", ctx do
    trip = trip!(ctx, "10c-0", "06:00:00")

    general =
      transfer_fixture(ctx.organization.id, ctx.version.id, %{
        transfer_type: 3,
        from_trip_id: "10c-1",
        to_trip_id: trip.trip_id,
        from_stop_id: "B",
        to_stop_id: "A"
      })

    assert {:ok, %{trips: 1, transfers: 1}} =
             Gtfs.delete_trips(ctx.scope.route_id, ctx.scope.service, [trip.id], ctx.audit)

    assert Repo.get(Transfer, general.id) == nil
    assert [log] = transfer_logs(ctx)
    assert log.action == "deleted"
    assert log.entity_id == general.id
    assert log.changed_fields["before"] == Transfer.audit_snapshot(general)
    assert log.changed_fields["affected_transfer_ids"] == [general.id]

    assert [trip_log] = trip_logs(ctx)
    assert log.changed_fields["operation_id"] == trip_log.changed_fields["operation_id"]
  end

  test "a refused transfer audit rolls the whole deletion back", ctx do
    trip = trip!(ctx, "10d-0", "06:00:00")

    transfer =
      transfer_fixture(ctx.organization.id, ctx.version.id, %{
        transfer_type: 4,
        from_trip_id: trip.trip_id,
        to_trip_id: "10d-1",
        from_stop_id: "A",
        to_stop_id: "B"
      })

    stop_times_before = Repo.all(from(st in StopTime, where: st.trip_id == ^trip.trip_id))

    # The audit layer refuses every log for a context whose actor is missing, and
    # the transfer log is the first one this deletion writes, so the failure is
    # the transfer's.
    assert {:error, %Ecto.Changeset{}} =
             Gtfs.delete_trips(ctx.scope.route_id, ctx.scope.service, [trip.id], %{
               ctx.audit
               | actor_id: nil
             })

    # The trip, its stop times and its transfer all survive: no row is removed
    # without a log (INV-5).
    assert Repo.get(Trip, trip.id) == trip
    assert Repo.get(Transfer, transfer.id) == transfer

    assert Repo.all(from(st in StopTime, where: st.trip_id == ^trip.trip_id)) == stop_times_before

    assert transfer_logs(ctx) == []
    assert trip_logs(ctx) == []
  end

  # -- Observation helpers --------------------------------------------------

  defp trip!(ctx, suffix, start_time) do
    schedule_trip_fixture(
      ctx.organization.id,
      ctx.version.id,
      ctx.scope.route_id,
      ctx.scope.bundle,
      %{
        trip_id: "#{ctx.scope.route_id}-#{suffix}",
        service_id: ctx.scope.service,
        start_time: start_time
      }
    ).trip
  end

  defp transfer_logs(ctx) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^ctx.organization_id and l.entity_type == "transfer",
        order_by: [asc: l.id]
      )
    )
  end

  defp trip_logs(ctx) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^ctx.organization_id and l.entity_type == "trip",
        order_by: [asc: l.id]
      )
    )
  end

  defp schedule_scope!(organization, version, audit, route_id) do
    route_fixture(organization.id, version.id, %{route_id: route_id})

    service =
      Gtfs.create_calendar(
        %{
          service_id: "svc_#{System.unique_integer([:positive])}",
          name: "Delete audit #{route_id}",
          kind: :weekly,
          monday: 1,
          tuesday: 1,
          wednesday: 1,
          thursday: 1,
          friday: 1,
          saturday: 0,
          sunday: 0,
          start_date: ~D[2026-01-05],
          end_date: ~D[2026-02-27]
        },
        audit
      )
      |> then(fn {:ok, result} -> result.service_id end)

    bundle =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route_id,
        direction_id: 0,
        stops: [{"A", 0, 0, 1}, {"B", 300, 330, 1}]
      })

    %{route_id: route_id, service: service, bundle: bundle}
  end
end
