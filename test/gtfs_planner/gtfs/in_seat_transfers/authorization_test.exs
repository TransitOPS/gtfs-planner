defmodule GtfsPlanner.Gtfs.InSeatTransfers.AuthorizationTest do
  @moduledoc """
  A revoked editor cannot write, replace or delete an in-seat record (AC-1, CL-1).

  The three facade commands read the actor's current membership inside their own
  transaction, so an editor deactivated or demoted after the page mounted gets
  `{:error, :forbidden}` with every transfer row and change log unchanged.

  `async: false` because these cases share the lane database.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = editor_fixture(organization)
    membership = Accounts.get_user_org_membership(actor.id, organization.id)

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "W",
      name: "Weekday",
      dates: [~D[2026-09-01], ~D[2026-09-02]]
    })

    first = block_trip(organization, version, route, "c", "10:00:00", "11:00:00")
    second = block_trip(organization, version, route, "d", "11:10:00", "12:10:00")
    stored = in_seat_transfer_fixture(organization.id, version.id, first, second)

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
      first: first,
      second: second,
      stored: stored,
      membership: membership,
      audit: audit
    }
  end

  test "a deactivated editor cannot replace a record", ctx do
    assert {:ok, %{{"c", "d"} => :ok}} =
             Gtfs.check_in_seat_connections(ctx.organization.id, ctx.version.id, [{"c", "d"}])

    before = snapshot(ctx)
    deactivate_membership_fixture(ctx.membership)

    assert {:error, :forbidden} =
             Gtfs.set_in_seat_connection(
               "c",
               "d",
               :must_reboard,
               [expected_row(ctx.stored)],
               ctx.audit
             )

    assert snapshot(ctx) == before
  end

  test "a deactivated editor cannot clear a record", ctx do
    before = snapshot(ctx)
    deactivate_membership_fixture(ctx.membership)

    assert {:error, :forbidden} =
             Gtfs.set_in_seat_connection(
               "c",
               "d",
               :not_stated,
               [expected_row(ctx.stored)],
               ctx.audit
             )

    assert snapshot(ctx) == before
  end

  test "a deactivated editor cannot write a reviewed group", ctx do
    before = snapshot(ctx)
    deactivate_membership_fixture(ctx.membership)

    assert {:error, :forbidden} =
             Gtfs.set_in_seat_connections(
               [%{pair: {"c", "d"}, expected: [expected_row(ctx.stored)]}],
               :must_reboard,
               ctx.audit
             )

    assert snapshot(ctx) == before
  end

  test "a deactivated editor cannot remove records", ctx do
    before = snapshot(ctx)
    deactivate_membership_fixture(ctx.membership)

    assert {:error, :forbidden} =
             Gtfs.remove_in_seat_records([{ctx.stored.id, ctx.stored.updated_at}], ctx.audit)

    assert snapshot(ctx) == before
  end

  test "a member who lost the editor role cannot remove records", ctx do
    before = snapshot(ctx)

    ctx.membership
    |> UserOrgMembership.changeset(%{roles: ["pathways_studio_admin"]})
    |> Repo.update!()

    assert {:error, :forbidden} =
             Gtfs.remove_in_seat_records([{ctx.stored.id, ctx.stored.updated_at}], ctx.audit)

    assert snapshot(ctx) == before
  end

  test "an actor from another organization cannot write this organization's records", ctx do
    outsider = editor_fixture(organization_fixture())
    before = snapshot(ctx)

    foreign = %{ctx.audit | actor_id: outsider.id, actor_email: outsider.email}

    assert {:error, :forbidden} =
             Gtfs.remove_in_seat_records([{ctx.stored.id, ctx.stored.updated_at}], foreign)

    assert snapshot(ctx) == before
  end

  defp block_trip(organization, version, route, trip_id, first_arrival, last_arrival) do
    blocked_trip_fixture(organization.id, version.id, route.route_id, %{
      trip_id: trip_id,
      service_id: "W",
      block_id: "202",
      first_arrival: first_arrival,
      last_arrival: last_arrival
    })
  end

  defp expected_row(row),
    do: %{id: row.id, transfer_type: row.transfer_type, updated_at: row.updated_at}

  defp snapshot(ctx) do
    %{
      transfers:
        Repo.all(
          from(t in Transfer,
            where:
              t.organization_id == ^ctx.organization.id and t.gtfs_version_id == ^ctx.version.id,
            order_by: [asc: t.id]
          )
        ),
      logs:
        Repo.all(
          from(l in ChangeLog,
            where: l.organization_id == ^ctx.organization.id,
            order_by: [asc: l.id]
          )
        )
    }
  end
end
