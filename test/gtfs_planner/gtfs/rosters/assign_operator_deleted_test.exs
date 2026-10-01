defmodule GtfsPlanner.Gtfs.Rosters.AssignOperatorDeletedTest do
  @moduledoc """
  A pick for an operator that is deleted after the writer found it is
  `{:error, :not_found}` and writes nothing, not an exception.

  `Operations.delete_operator/3` takes no roster lock, so a delete can commit
  between `assign_roster_operator/3` reading the operator and updating the line.
  The SQL Sandbox shares one connection, so this does not run two sessions. A
  trigger deletes the picked operator as the pick's `UPDATE` starts instead: the
  lookup has already succeeded, and the foreign key refuses the write exactly as
  it would after a concurrent delete. The trigger's delete is part of the refused
  statement, so it is undone with it; the case asserts the writer's answer and the
  line, not the operator row. The trigger is created inside the test's
  transaction and rolled back with it. Creating it locks `roster_lines`, so the
  module does not run alongside the async ones.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/assign_operator_deleted_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Operations.Operator

  import GtfsPlanner.RunsFixtures

  test "a pick for an operator deleted after the lookup is not found and the line stays open" do
    world = runs_version_fixture()
    assert {:ok, %{id: line_id}} = Gtfs.create_roster_line(world.audit)

    operator =
      Repo.insert!(%Operator{
        organization_id: world.organization.id,
        employee_id: "E-1",
        display_name: "Aurelia Nowak"
      })

    delete_operator_when_picked!()

    assert {:error, :not_found} = Gtfs.assign_roster_operator(world.audit, line_id, operator.id)

    assert %RosterLine{operator_id: nil} = Repo.get!(RosterLine, line_id)
  end

  defp delete_operator_when_picked! do
    Repo.query!("""
    CREATE FUNCTION delete_picked_operator() RETURNS trigger AS $$
    BEGIN
      DELETE FROM operators WHERE id = NEW.operator_id;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER delete_picked_operator BEFORE UPDATE OF operator_id ON roster_lines
    FOR EACH ROW WHEN (NEW.operator_id IS NOT NULL)
    EXECUTE FUNCTION delete_picked_operator()
    """)
  end
end
