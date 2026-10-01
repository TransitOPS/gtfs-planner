defmodule GtfsPlanner.Gtfs.Transfers.AuthorizationTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{AuditContext, ChangeLog, Transfer}

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    stop_fixture(organization.id, version.id, stop_id: "S1")
    stop_fixture(organization.id, version.id, stop_id: "S2")
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)

    first =
      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "S1",
        to_stop_id: "S2",
        transfer_type: 0
      })

    second =
      transfer_fixture(organization.id, version.id, %{
        from_stop_id: "S2",
        to_stop_id: "S1",
        transfer_type: 2,
        min_transfer_time: 120
      })

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
      membership: membership,
      audit: audit,
      first: first,
      second: second
    }
  end

  test "a deactivated editor cannot create a general transfer", ctx do
    deactivate_membership_fixture(ctx.membership)

    assert {:error, :forbidden} =
             Gtfs.create_general_transfer(
               %{"from_stop_id" => "S1", "to_stop_id" => "S2", "transfer_type" => "1"},
               ctx.audit
             )

    assert_unchanged(ctx)
  end

  test "a deactivated editor cannot update a general transfer", ctx do
    deactivate_membership_fixture(ctx.membership)

    assert {:error, :forbidden} =
             Gtfs.update_general_transfer(
               ctx.first.id,
               %{"min_transfer_time" => "240"},
               ctx.first.updated_at,
               ctx.audit
             )

    assert_unchanged(ctx)
  end

  test "a deactivated editor cannot delete one general transfer", ctx do
    deactivate_membership_fixture(ctx.membership)

    assert {:error, :forbidden} =
             Gtfs.delete_general_transfer(ctx.first.id, ctx.first.updated_at, ctx.audit)

    assert_unchanged(ctx)
  end

  test "a deactivated editor cannot delete a batch of general transfers", ctx do
    deactivate_membership_fixture(ctx.membership)

    assert {:error, :forbidden} =
             Gtfs.delete_general_transfers(
               [{ctx.first.id, ctx.first.updated_at}, {ctx.second.id, ctx.second.updated_at}],
               ctx.audit
             )

    assert_unchanged(ctx)
  end

  defp assert_unchanged(ctx) do
    assert Repo.get!(Transfer, ctx.first.id) == ctx.first
    assert Repo.get!(Transfer, ctx.second.id) == ctx.second

    refute Repo.exists?(
             from(t in Transfer,
               where:
                 t.organization_id == ^ctx.organization.id and
                   t.gtfs_version_id == ^ctx.version.id,
               where: t.id not in ^[ctx.first.id, ctx.second.id]
             )
           )

    refute Repo.exists?(
             from(l in ChangeLog,
               where:
                 l.organization_id == ^ctx.organization.id and
                   l.gtfs_version_id == ^ctx.version.id,
               where: l.entity_type == "transfer"
             )
           )
  end
end
