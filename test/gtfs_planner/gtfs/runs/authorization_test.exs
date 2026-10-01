defmodule GtfsPlanner.Gtfs.Runs.AuthorizationTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{BlockingSetting, TripRun}
  alias GtfsPlanner.Repo

  setup do
    world = runs_version_fixture()
    trip = hd(world.blocks["101"])

    trip_run_fixture(world.organization.id, world.version.id, %{
      trip: trip,
      day_type_key: world.day_type_key,
      run_id: "1001"
    })

    membership = Accounts.get_user_org_membership(world.audit.actor_id, world.organization.id)
    %{world: world, trip: trip, membership: membership}
  end

  test "revoked actor is refused by all five writers without changing roster or crew", %{
    world: world,
    trip: trip,
    membership: membership
  } do
    assert {:ok, plan} =
             Gtfs.suggest_runs(
               world.organization.id,
               world.version.id,
               world.day_type_key,
               :replace_all
             )

    before = snapshot(world)
    deactivate_membership_fixture(membership)

    moves = [%{trip_id: trip.id, from: "1001", to: "2001"}]
    assert {:error, :forbidden} = Gtfs.apply_run_moves(world.audit, world.day_type_key, moves)
    assert {:error, :forbidden} = Gtfs.rename_run(world.audit, world.day_type_key, "1001", "2001")
    assert {:error, :forbidden} = Gtfs.remove_run_orphans(world.audit, world.day_type_key)
    assert {:error, :forbidden} = Gtfs.apply_run_plan(world.audit, plan)

    assert {:error, :forbidden} =
             Gtfs.update_crew_settings(world.audit, %{paid_break_max_minutes: 40})

    assert snapshot(world) == before

    assert {:ok, _day} =
             Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

    assert {:ok, _plan} =
             Gtfs.suggest_runs(
               world.organization.id,
               world.version.id,
               world.day_type_key,
               :replace_all
             )
  end

  test "removed editor role refuses a direct move while preserving its prior assignment", %{
    world: world,
    trip: trip,
    membership: membership
  } do
    before = snapshot(world)

    membership
    |> UserOrgMembership.changeset(%{roles: ["pathways_studio_admin"]})
    |> Repo.update!()

    assert {:error, :forbidden} =
             Gtfs.apply_run_moves(world.audit, world.day_type_key, [
               %{trip_id: trip.id, from: "1001", to: nil}
             ])

    assert snapshot(world) == before
  end

  defp snapshot(world) do
    for schema <- [TripRun, BlockingSetting], into: %{} do
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
