defmodule GtfsPlanner.Gtfs.Rosters.RosterSchemaTest do
  @moduledoc """
  The roster storage rules: a run on at most one line per weekday, a line on at
  most one day per weekday, and an operator on at most one line per version.

  Every refusal is asserted against the real PostgreSQL indexes and foreign-key
  actions, because the changesets exist to map those rejections to fields.
  """

  use GtfsPlanner.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Operations.Operator

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @day_type_key "Wk1SjY3ZW5kbHk"
  @run_id "1005"
  @sign_on 5 * 3600
  @sign_off 12 * 3600

  defp insert_operator(organization_id, employee_id) do
    Repo.insert!(%Operator{
      organization_id: organization_id,
      employee_id: employee_id,
      display_name: "Operator #{employee_id}"
    })
  end

  defp line_changeset(organization_id, version_id, line_number, operator_id) do
    RosterLine.changeset(
      %RosterLine{
        organization_id: organization_id,
        gtfs_version_id: version_id,
        line_number: line_number,
        operator_id: operator_id
      },
      %{}
    )
  end

  defp insert_line(organization_id, version_id, line_number, operator_id \\ nil) do
    Repo.insert!(line_changeset(organization_id, version_id, line_number, operator_id))
  end

  defp insert_day(line, weekday, run_id) do
    Repo.insert(
      RosterLineDay.changeset(
        %RosterLineDay{
          roster_line_id: line.id,
          organization_id: line.organization_id,
          gtfs_version_id: line.gtfs_version_id,
          weekday: weekday,
          day_type_key: @day_type_key
        },
        %{"run_id" => run_id, "run_sign_on_secs" => @sign_on, "run_sign_off_secs" => @sign_off}
      )
    )
  end

  describe "a run on at most one line per weekday" do
    test "the second line of one version is refused the same run-day" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      first = insert_line(org.id, version.id, 1)
      second = insert_line(org.id, version.id, 2)

      assert {:ok, _day} = insert_day(first, 1, @run_id)

      assert {:error, changeset} = insert_day(second, 1, @run_id)
      assert %{run_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "the same run on another weekday of the same version inserts" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      first = insert_line(org.id, version.id, 1)
      second = insert_line(org.id, version.id, 2)

      assert {:ok, _day} = insert_day(first, 1, @run_id)
      assert {:ok, _day} = insert_day(second, 2, @run_id)
    end

    test "the same run-day on another version of the same organization inserts" do
      org = organization_fixture()
      one = gtfs_version_fixture(org.id)
      other = gtfs_version_fixture(org.id)
      first = insert_line(org.id, one.id, 1)
      second = insert_line(org.id, other.id, 1)

      assert {:ok, _day} = insert_day(first, 1, @run_id)
      assert {:ok, other_day} = insert_day(second, 1, @run_id)
      assert other_day.gtfs_version_id == other.id
    end

    test "two concurrent inserts of one run-day store exactly one row" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      first = insert_line(org.id, version.id, 1)
      second = insert_line(org.id, version.id, 2)

      parent = self()

      insert = fn line ->
        Sandbox.allow(Repo, parent, self())
        insert_day(line, 1, @run_id)
      end

      results =
        Enum.map([first, second], fn line -> Task.async(fn -> insert.(line) end) end)
        |> Task.await_many(5_000)

      assert Enum.count(results, &match?({:ok, _day}, &1)) == 1
      assert Enum.count(results, &match?({:error, _changeset}, &1)) == 1

      assert Repo.aggregate(
               from(d in RosterLineDay,
                 where: d.organization_id == ^org.id and d.gtfs_version_id == ^version.id
               ),
               :count
             ) == 1
    end
  end

  describe "an operator on at most one line per version" do
    test "one operator on two lines of one version is refused" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      operator = insert_operator(org.id, "E4101")
      insert_line(org.id, version.id, 1, operator.id)

      assert {:error, changeset} = Repo.insert(line_changeset(org.id, version.id, 2, operator.id))
      assert %{operator_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "one operator holds a line in each of two versions" do
      org = organization_fixture()
      one = gtfs_version_fixture(org.id)
      other = gtfs_version_fixture(org.id)
      operator = insert_operator(org.id, "E4101")

      # `insert_line/4` takes the operator's ID as an argument, so there is no
      # query here to pin: the assertion reads the value straight back.
      assert %RosterLine{operator_id: id} = insert_line(org.id, one.id, 1, operator.id)
      assert id == operator.id

      assert %RosterLine{operator_id: ^id} = insert_line(org.id, other.id, 1, operator.id)
    end
  end

  describe "foreign keys" do
    test "deleting an operator empties its lines instead of deleting them" do
      org = organization_fixture()
      one = gtfs_version_fixture(org.id)
      other = gtfs_version_fixture(org.id)
      operator = insert_operator(org.id, "E4101")
      first = insert_line(org.id, one.id, 1, operator.id)
      second = insert_line(org.id, other.id, 1, operator.id)

      Repo.delete!(operator)

      assert Repo.get!(RosterLine, first.id).operator_id == nil
      assert Repo.get!(RosterLine, second.id).operator_id == nil
    end

    test "deleting a line deletes its day rows" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      line = insert_line(org.id, version.id, 1)
      assert {:ok, day} = insert_day(line, 1, @run_id)

      Repo.delete!(line)

      refute Repo.get(RosterLineDay, day.id)
    end
  end

  describe "roster_line_days validation and constraints" do
    test "rejects a weekday outside 1 to 7" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      line = insert_line(org.id, version.id, 1)

      assert {:error, changeset} = insert_day(line, 0, @run_id)
      assert %{weekday: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} = insert_day(line, 8, @run_id)
      assert %{weekday: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects a run ID the numbering rules could never produce" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      line = insert_line(org.id, version.id, 1)

      assert {:error, changeset} = insert_day(line, 1, "bad id!")
      assert %{run_id: ["must be one to eight letters, digits or hyphens"]} = errors_on(changeset)
    end

    test "refuses a second day row for one line and weekday" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      line = insert_line(org.id, version.id, 1)
      assert {:ok, _day} = insert_day(line, 1, @run_id)

      assert {:error, changeset} = insert_day(line, 1, "2001")
      assert %{weekday: ["has already been taken"]} = errors_on(changeset)
    end

    test "requires a run ID and the run's two times" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)
      line = insert_line(org.id, version.id, 1)

      assert {:error, changeset} =
               Repo.insert(
                 RosterLineDay.changeset(
                   %RosterLineDay{
                     roster_line_id: line.id,
                     organization_id: org.id,
                     gtfs_version_id: version.id,
                     weekday: 1,
                     day_type_key: @day_type_key
                   },
                   %{}
                 )
               )

      assert %{
               run_id: ["can't be blank"],
               run_sign_on_secs: ["can't be blank"],
               run_sign_off_secs: ["can't be blank"]
             } = errors_on(changeset)
    end
  end
end
