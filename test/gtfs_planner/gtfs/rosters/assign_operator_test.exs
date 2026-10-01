defmodule GtfsPlanner.Gtfs.Rosters.AssignOperatorTest do
  @moduledoc """
  `assign_roster_operator/3` is the pick: it records, changes and clears the
  operator of a line, refuses an operator who already holds a line in the same
  version by naming it, and refuses an operator of another organization without
  writing anything.

  Every case goes through the `Gtfs` facade, the path the Rosters page calls, so
  the delegate is on the path being tested rather than bypassed. The stored pick
  is read back from `roster_lines.operator_id` and composed state through
  `Gtfs.load_roster/2`, because "the pick is recorded" and "the line shows Open"
  are claims about what was written, not about what was returned.

  The world is `RunsFixtures.runs_version_fixture/1`: a published version in its
  own organization. Lines are created through `Gtfs.create_roster_line/1` rather
  than inserted, so each one is a line the page could have made. Operators are
  inserted through `Operator.changeset/2` — `Operations`' writers arrive in
  steps 18 and 19 — which is all the pick needs: a row of this organization that
  the write can be scoped against.

  "Aurelia Nowak" holds line 7 in the refusal case because a refusal has to name
  the line and the person, and the numbers are read from the table rather than
  assumed: whichever line the write loses to is the one named.

  The concurrency case runs two `Task`s over the SQL Sandbox owner's connection
  with `Sandbox.allow/3`, the arrangement this repository's other task-based
  cases use, and asserts that the operator ends up on exactly one line and that
  the loser is told which line won.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `mix test test/gtfs_planner/gtfs/rosters/assign_operator_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Operations.Operator

  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  setup do
    %{world: runs_version_fixture()}
  end

  describe "assign_roster_operator/3" do
    test "records the operator on the line, re-read from the table", %{world: world} do
      line = new_line(world)
      operator = operator_fixture(world, "E-1", "Aurelia Nowak", 7)

      assert {:ok, %{line_number: 1}} = assign(world, line, operator.id)

      assert stored_operator(world, line) == operator.id
      assert composed_operator(load_roster(world), 1).id == operator.id

      # Clearing reaches the state it was asked for and the line shows Open.
      assert {:ok, %{line_number: 1}} = assign(world, line, nil)
      assert stored_operator(world, line) == nil
      assert composed_operator(load_roster(world), 1) == nil
    end

    test "changing the operator replaces the earlier pick", %{world: world} do
      line = new_line(world)
      first = operator_fixture(world, "E-1", "Aurelia Nowak", 7)
      second = operator_fixture(world, "E-2", "Bo Lindqvist", 8)

      assert {:ok, _saved} = assign(world, line, first.id)
      assert {:ok, %{line_number: 1}} = assign(world, line, second.id)

      assert stored_operator(world, line) == second.id
      assert composed_operator(load_roster(world), 1).display_name == "Bo Lindqvist"

      # The operator who gave the line up holds nothing, which is what makes the
      # line available again.
      assert held_line_numbers(world, first.id) == []
    end

    test "an operator who already holds a line is refused and names it", %{world: world} do
      holder = new_line(world)
      asker = new_line(world)
      operator = operator_fixture(world, "E-7", "Aurelia Nowak", 7)

      assert {:ok, %{line_number: 1}} = assign(world, holder, operator.id)

      assert {:error, {:operator_holds, 1, "Aurelia Nowak"}} = assign(world, asker, operator.id)

      # Nothing was written: the asker is still open and the holder kept the pick.
      assert stored_operator(world, asker) == nil
      assert held_line_numbers(world, operator.id) == [1]
    end

    test "the same operator may hold a line in another version", %{world: world} do
      line = new_line(world)
      operator = operator_fixture(world, "E-1", "Aurelia Nowak", 7)

      assert {:ok, %{line_number: 1}} = assign(world, line, operator.id)
      assert {:ok, %{line_number: 1}} = assign(world, line, operator.id)

      # A second published version of the same organization is a separate
      # numbering and a separate index, so the operator holds a line there too.
      other_version = gtfs_version_fixture(world.organization.id)
      other_world = %{world | version: other_version}
      other_line = new_line(other_world)

      assert {:ok, %{line_number: 1}} = assign(other_world, other_line, operator.id)

      assert held_line_numbers(world, operator.id) == [1]
      assert held_line_numbers(other_world, operator.id) == [1]
    end

    test "an operator of another organization is not found and writes nothing", %{world: world} do
      line = new_line(world)
      theirs = runs_version_fixture()
      foreign = operator_fixture(theirs, "E-1", "Aurelia Nowak", 7)

      assert {:error, :not_found} = assign(world, line, foreign.id)
      assert stored_operator(world, line) == nil
    end

    test "a malformed, missing or absent operator id is refused, and nil clears", %{world: world} do
      line = new_line(world)
      operator = operator_fixture(world, "E-1", "Aurelia Nowak", 7)

      assert {:ok, %{line_number: 1}} = assign(world, line, operator.id)

      for bad_id <- ["not-a-uuid", 42, Ecto.UUID.generate()] do
        assert {:error, :not_found} = assign(world, line, bad_id)
      end

      # The line keeps the pick it had: no refusal wrote anything.
      assert stored_operator(world, line) == operator.id
      assert {:ok, %{line_number: 1}} = assign(world, line, nil)
    end

    test "a line of another version or organization, and an unpublished version, are not found",
         %{world: world} do
      line = new_line(world)
      operator = operator_fixture(world, "E-1", "Aurelia Nowak", 7)

      theirs = runs_version_fixture()
      their_line = new_line(theirs)
      their_operator = operator_fixture(theirs, "E-1", "Bo Lindqvist", 8)

      # Every call is made in *this* world's scope with an id that belongs to
      # theirs, is malformed, or is absent: the caller's own line and operator
      # never appear here, because a pick this version can make is not a refusal.
      for {bad_line, bad_operator} <- [
            {their_line.id, their_operator.id},
            {their_line.id, "not-a-uuid"},
            {"not-a-uuid", operator.id},
            {nil, operator.id}
          ] do
        assert {:error, :not_found} =
                 Gtfs.assign_roster_operator(
                   world_audit(world),
                   bad_line,
                   bad_operator
                 )
      end

      assert stored_operator(world, line) == nil
      assert stored_operator(theirs, their_line) == nil

      # An unpublished version is refused the same way, with the pick unwritten.
      staged = staged_version(world)
      assert {:error, :not_found} = assign(staged, line, operator.id)
      assert stored_operator(world, line) == nil
    end
  end

  describe "two writers at once" do
    test "the same operator on two lines leaves one holder and one named refusal", %{world: world} do
      first = new_line(world)
      second = new_line(world)
      operator = operator_fixture(world, "E-1", "Aurelia Nowak", 7)
      parent = self()

      # Both writers run the real writer on the real facade, over the sandbox
      # owner's connection, and neither sees the other's half-finished work
      # before the index decides.
      results =
        [first, second]
        |> Enum.map(fn line ->
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            Gtfs.assign_roster_operator(
              world_audit(world),
              line.id,
              operator.id
            )
          end)
        end)
        |> Enum.map(&Task.await(&1, 30_000))

      {ok, refused} = Enum.split_with(results, &match?({:ok, _}, &1))

      assert [{:ok, %{line_number: _winner}}] = ok

      # The loser is told which line won rather than being left to guess, and
      # the operator is on exactly one line (AC-19).
      assert [{:error, {:operator_holds, holder_line, "Aurelia Nowak"}}] = refused
      assert held_line_numbers(world, operator.id) == [holder_line]
    end
  end

  defp assign(world, line, operator_id) do
    Gtfs.assign_roster_operator(world_audit(world), line.id, operator_id)
  end

  defp new_line(world) do
    assert {:ok, %{id: id, line_number: number}} =
             Gtfs.create_roster_line(world_audit(world))

    %{id: id, line_number: number}
  end

  defp load_roster(world) do
    {:ok, %{roster: roster}} = Gtfs.load_roster(world.organization.id, world.version.id)
    roster
  end

  defp composed_operator(roster, line_number) do
    roster.lines
    |> Enum.find(&(&1.line_number == line_number))
    |> Map.fetch!(:operator)
  end

  # The stored pick, read back from the table rather than from a writer's answer.
  defp stored_operator(world, line) do
    Repo.one(
      from(l in RosterLine,
        where:
          l.id == ^line.id and l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id,
        select: l.operator_id
      )
    )
  end

  # The version's line numbers this operator holds, counted in the table so
  # "one line per operator" is observed where the refusal's effect would be.
  defp held_line_numbers(world, operator_id) do
    Repo.all(
      from(l in RosterLine,
        where:
          l.organization_id == ^world.organization.id and
            l.gtfs_version_id == ^world.version.id and l.operator_id == ^operator_id,
        select: l.line_number,
        order_by: l.line_number
      )
    )
  end

  # An operator of the world's own organization, inserted through the schema's
  # changeset because `Operations`' writers arrive in steps 18 and 19. Only the
  # three business fields are set: a pick stores no personal data of its own.
  defp operator_fixture(world, employee_id, display_name, seniority_number) do
    Repo.insert!(
      %Operator{organization_id: world.organization.id}
      |> Operator.changeset(%{
        employee_id: employee_id,
        display_name: display_name,
        seniority_number: seniority_number
      })
    )
  end

  # The version as a draft: every roster writer refuses an unpublished version,
  # the same as a version of another organization.
  defp staged_version(world) do
    {1, _} =
      Repo.update_all(
        from(v in GtfsPlanner.Versions.GtfsVersion, where: v.id == ^world.version.id),
        set: [publication_status: "staging", published_at: nil]
      )

    world
  end
end
