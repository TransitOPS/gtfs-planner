defmodule GtfsPlanner.Gtfs.Rosters.AuthorizationTest do
  @moduledoc """
  Every roster writer checks the actor's current editor membership inside its own
  transaction, before it locks the version, and a refused actor writes nothing.

  The actor is the editor `RunsFixtures.runs_version_fixture/1` made. The cases
  revoke that membership after the line, its day, the operator and the settings
  row exist, then call each writer directly through the `Gtfs` facade — the
  path the Rosters page calls — so a page that skipped its own role check would
  still be refused, and the stored rows are compared before and after.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/authorization_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Operations

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures

  @moduletag timeout: 120_000

  @monday 1
  @tuesday 2

  setup do
    world = runs_version_fixture()

    for {block_id, run_id} <- [{"101", "2001"}, {"102", "2002"}],
        trip <- world.blocks[block_id] do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: world.day_type_key,
        run_id: run_id
      })
    end

    assert {:ok, %{id: line_id}} = Gtfs.create_roster_line(world.audit)
    assert {:ok, _result} = Gtfs.set_roster_slot(world.audit, line_id, @monday, "2001")

    assert {:ok, operator} =
             Operations.create_operator(world.organization.id, %{id: world.audit.actor_id}, %{
               "employee_id" => "E4101",
               "display_name" => "Aurelia Nowak"
             })

    assert {:ok, _settings} =
             Gtfs.update_roster_settings(world.audit, %{
               min_rest_minutes: 540,
               weekly_hours_warn_above: 50
             })

    membership = Accounts.get_user_org_membership(world.audit.actor_id, world.organization.id)

    %{world: world, line_id: line_id, operator: operator, membership: membership}
  end

  test "a deactivated editor is refused by every roster writer and nothing is written", %{
    world: world,
    line_id: line_id,
    operator: operator,
    membership: membership
  } do
    before = snapshot(world)
    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} =
             Gtfs.update_roster_settings(world.audit, %{min_rest_minutes: 480})

    assert {:error, :forbidden} = Gtfs.create_roster_line(world.audit)

    assert {:error, :forbidden} =
             Gtfs.create_roster_line_from_run(world.audit, world.day_type_key, "2002")

    assert {:error, :forbidden} = Gtfs.set_roster_slot(world.audit, line_id, @tuesday, "2002")

    assert {:error, :forbidden} =
             Gtfs.set_roster_weekday_group(world.audit, line_id, @monday, "2002")

    assert {:error, :forbidden} = Gtfs.clear_roster_slot(world.audit, line_id, @monday)
    assert {:error, :forbidden} = Gtfs.assign_roster_operator(world.audit, line_id, operator.id)
    assert {:error, :forbidden} = Gtfs.delete_roster_line(world.audit, line_id)

    assert snapshot(world) == before
  end

  test "an actor whose editor role was removed is refused and the line keeps its day", %{
    world: world,
    line_id: line_id,
    membership: membership
  } do
    before = snapshot(world)

    membership
    |> UserOrgMembership.changeset(%{roles: ["pathways_studio_admin"]})
    |> Repo.update!()

    assert {:error, :forbidden} = Gtfs.set_roster_slot(world.audit, line_id, @monday, "2002")

    assert snapshot(world) == before
  end

  test "an editor of another organization is refused", %{world: world, line_id: line_id} do
    outsider = editor_fixture(organization_fixture())
    audit = %{world.audit | actor_id: outsider.id, actor_email: outsider.email}
    before = snapshot(world)

    assert {:error, :forbidden} = Gtfs.create_roster_line(audit)
    assert {:error, :forbidden} = Gtfs.delete_roster_line(audit, line_id)

    assert snapshot(world) == before
  end

  test "a revoked editor is refused before the version is looked at", %{
    world: world,
    line_id: line_id,
    membership: membership
  } do
    deactivate_membership_fixture(membership)
    unknown_version = %{world.audit | gtfs_version_id: Ecto.UUID.generate()}

    assert {:error, :forbidden} = Gtfs.create_roster_line(unknown_version)
    assert {:error, :forbidden} = Gtfs.set_roster_slot(unknown_version, line_id, @monday, "2001")
  end

  defp snapshot(world) do
    for schema <- [RosterLine, RosterLineDay, BlockingSetting], into: %{} do
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
