defmodule GtfsPlanner.Operations.OperatorDeleteTest do
  @moduledoc """
  `Operations.delete_operator/3` is an organization-scoped hard delete whose
  foreign key leaves the held lines open.

  The rows are the real ones: an operator is created through
  `Operations.create_operator/3`, and each held line is created and given its
  pick through the `Gtfs` facade writers the page calls, so a line that survives
  the delete is a line that existed. Both effects are read back from the tables
  — the operator row with `Repo.get/2`, the lines with `roster_lines.operator_id`
  — because "the row is gone" and "the line still exists and shows Open" are
  claims about what is stored, not about what the delete returned.

  The world is `RunsFixtures.runs_version_fixture/1`, a published version in its
  own organization; a second published version of that same organization is the
  second place the operator holds a line, since domain rule 12 names held lines
  in any version.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/operations/operator_delete_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Operator

  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    %{world: runs_version_fixture()}
  end

  describe "delete_operator/3" do
    test "deletes an operator holding lines in two versions and empties both lines", %{
      world: world
    } do
      operator = create_operator(world)
      first = held_line(world, operator.id)
      other_version = gtfs_version_fixture(world.organization.id)
      second = held_line(%{world | version: other_version}, operator.id)

      # Before the delete the lines hold the operator in both versions.
      assert stored_operator(world, first.id) == operator.id
      assert stored_operator(%{world | version: other_version}, second.id) == operator.id

      assert {:ok, deleted} =
               Operations.delete_operator(
                 world.organization.id,
                 operations_actor(world.organization.id),
                 operator.id
               )

      assert deleted.id == operator.id
      assert deleted.employee_id == "E4101"

      # The row is gone, for this organization and every reader.
      assert Repo.get(Operator, operator.id) == nil
      assert Operations.get_operator(world.organization.id, operator.id) == nil

      # Both lines survive with no operator, so both show Open.
      assert stored_operator(world, first.id) == nil
      assert stored_operator(%{world | version: other_version}, second.id) == nil
      assert Enum.map([first, second], &Repo.get(RosterLine, &1.id).operator_id) == [nil, nil]
      assert Enum.map([first, second], &Repo.get(RosterLine, &1.id).line_number) == [1, 1]

      # The delete left the operator holding nothing anywhere in the
      # organization, which is what makes the lines available again.
      assert Gtfs.roster_operator_holdings(world.organization.id, operator.id) == []
    end

    test "an operator of another organization is not found and the row remains", %{world: world} do
      theirs = runs_version_fixture()
      foreign = create_operator(theirs, "E4200", "Bo Lindqvist", 8)

      assert {:error, :not_found} =
               Operations.delete_operator(
                 world.organization.id,
                 operations_actor(world.organization.id),
                 foreign.id
               )

      assert Repo.get(Operator, foreign.id) == foreign
      assert Operations.get_operator(theirs.organization.id, foreign.id).id == foreign.id
    end

    test "a malformed, missing or already deleted id is not found and writes nothing", %{
      world: world
    } do
      operator = create_operator(world)
      line = held_line(world, operator.id)

      assert {:ok, _deleted} =
               Operations.delete_operator(
                 world.organization.id,
                 operations_actor(world.organization.id),
                 operator.id
               )

      for bad_id <- ["not-a-uuid", 42, nil, Ecto.UUID.generate(), operator.id] do
        assert {:error, :not_found} =
                 Operations.delete_operator(
                   world.organization.id,
                   operations_actor(world.organization.id),
                   bad_id
                 )
      end

      assert stored_operator(world, line.id) == nil
    end

    test "an operator holding no line deletes without a reader or a locker", %{world: world} do
      operator = create_operator(world)

      assert {:ok, deleted} =
               Operations.delete_operator(
                 world.organization.id,
                 operations_actor(world.organization.id),
                 operator.id
               )

      assert deleted.id == operator.id
      assert Repo.get(Operator, operator.id) == nil
      assert Enum.map(Operations.list_operators(world.organization.id), & &1.id) == []
    end
  end

  defp create_operator(
         world,
         employee_id \\ "E4101",
         display_name \\ "Aurelia Nowak",
         seniority \\ 10
       ) do
    {:ok, operator} =
      Operations.create_operator(
        world.organization.id,
        operations_actor(world.organization.id),
        %{
          "employee_id" => employee_id,
          "display_name" => display_name,
          "seniority_number" => seniority
        }
      )

    operator
  end

  # A new line of this version holding this operator, written through the facade
  # writers the page calls.
  defp held_line(world, operator_id) do
    assert {:ok, %{id: id, line_number: number}} =
             Gtfs.create_roster_line(world_audit(world))

    assert {:ok, %{line_number: ^number}} =
             Gtfs.assign_roster_operator(
               world_audit(world),
               id,
               operator_id
             )

    %{id: id, line_number: number}
  end

  # The stored pick, read back from the table rather than from a writer's answer.
  defp stored_operator(world, line_id) do
    Repo.one(
      from(l in RosterLine,
        where:
          l.id == ^line_id and l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id,
        select: l.operator_id
      )
    )
  end
end
