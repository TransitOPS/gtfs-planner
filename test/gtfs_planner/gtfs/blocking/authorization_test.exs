defmodule GtfsPlanner.Gtfs.Blocking.AuthorizationTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs

  alias GtfsPlanner.Gtfs.{
    BlockAttribute,
    Blocking,
    BlockingSetting,
    ChangeLog,
    DeadheadTime,
    ReliefPoint,
    RouteOperatingSetting,
    Trip
  }

  alias GtfsPlanner.Repo

  setup do
    world = runs_version_fixture()
    membership = Accounts.get_user_org_membership(world.audit.actor_id, world.organization.id)
    %{world: world, membership: membership}
  end

  test "revoked editor cannot write rules, references, relief or block changes", %{
    world: world,
    membership: membership
  } do
    pair = {"stop:BAY_A", "stop:VC"}
    assert {:ok, _} = Gtfs.put_deadhead_time(world.audit, pair, 9)
    before = snapshot(world)
    trip = hd(world.blocks["101"])
    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} = Blocking.update_settings(world.audit, %{min_layover_minutes: 8})

    assert {:error, :forbidden} =
             Gtfs.update_blocking_settings(world.audit, %{min_layover_minutes: 8})

    assert {:error, :forbidden} =
             Gtfs.update_route_operating_settings(world.audit, [
               %{route_id: world.route.route_id, garage_id: world.garage.id}
             ])

    assert {:error, :forbidden} = Gtfs.put_deadhead_time(world.audit, pair, 12)
    assert {:error, :forbidden} = Gtfs.clear_deadhead_time(world.audit, pair)

    assert {:error, :forbidden} =
             Gtfs.update_relief_settings(world.audit, world.day_type_key, %{
               max_piece_minutes: 360,
               marked: []
             })

    assert {:error, :forbidden} =
             Gtfs.apply_block_change(world.day_type_key, {:unassign, [trip.id]}, world.audit)

    assert {:error, :forbidden} =
             Gtfs.set_block_attributes(
               world.day_type_key,
               "101",
               %{"garage_id" => world.garage.id},
               world.audit
             )

    assert {:error, :forbidden} =
             Gtfs.apply_block_plan(world.day_type_key, %{mode: :unassigned_only}, world.audit)

    assert snapshot(world) == before
    assert is_map(Gtfs.get_blocking_settings(world.organization.id, world.version.id))
  end

  test "removed editor role is refused before an attribute-only plan can write", %{
    world: world,
    membership: membership
  } do
    before = snapshot(world)

    membership
    |> UserOrgMembership.changeset(%{roles: ["pathways_studio_admin"]})
    |> Repo.update!()

    assert {:error, :forbidden} =
             Gtfs.apply_block_plan(
               world.day_type_key,
               %{mode: :replace_all, moves: []},
               world.audit
             )

    assert snapshot(world) == before
  end

  defp snapshot(world) do
    for schema <- [
          Trip,
          ChangeLog,
          BlockingSetting,
          RouteOperatingSetting,
          DeadheadTime,
          ReliefPoint,
          BlockAttribute
        ],
        into: %{} do
      {schema,
       Repo.all(
         from(row in schema,
           where:
             row.organization_id == ^world.organization.id and
               row.gtfs_version_id == ^world.version.id,
           order_by: [asc: row.id]
         )
       )}
    end
  end
end
