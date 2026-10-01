defmodule GtfsPlanner.Operations.OperatorImportApplyTest do
  @moduledoc """
  Organization-scoped operator import previews and atomic applies.

  Every expected value is written from the uploaded CSV by hand: the add, update
  and skipped rows, the ignored columns and the stored rows are all read off the
  literal file text, so no production function computes an expectation. Cases
  invoke the real `GtfsPlanner.Operations`/`Repo` composition and compare the
  rows re-read from the `operators` table before and after apply, so a stored
  column the file did not carry, a wiped seniority number, a lost UUID or a
  refusal that still wrote fails the suite.

  Rows are created inside the SQL Sandbox transaction and rolled back.

  Run with:
  `MIX_ENV=test MIX_TEST_PARTITION=_rosters09 mix test test/gtfs_planner/operations/operator_import_apply_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Operations.Tods

  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures

  # A phone column the import must never store, and a seniority column the
  # second file leaves out.
  @with_phone "employee_id,display_name,seniority_number,phone\n" <>
                "E4101,Ana Nowak,12,555-0100\n" <>
                "E4200,Bo Silva,7,555-0101\n"

  @without_seniority "employee_id,display_name\nE4101,Ana Nowak Renamed\n"

  defp parsed!(content, file \\ "operators.csv") do
    assert {:ok, parsed} = Tods.parse(:operators, file, content)
    parsed
  end

  defp create_operator(organization_id, attrs) do
    {:ok, operator} =
      Operations.create_operator(organization_id, operations_actor(organization_id), attrs)

    operator
  end

  defp attrs(employee_id, display_name, seniority_number) do
    %{
      "employee_id" => employee_id,
      "display_name" => display_name,
      "seniority_number" => seniority_number
    }
  end

  # Reads the stored row through `list_operators/1`, the organization's only
  # operator reader, so the assertions see the columns an import wrote.
  defp lookup(organization_id, employee_id) do
    Enum.find(Operations.list_operators(organization_id), &(&1.employee_id == employee_id))
  end

  # {seniority_number, display_name} per stored operator, so the values are
  # asserted literally rather than through an ordering the import does not own.
  defp stored(organization_id, employee_id) do
    operator = lookup(organization_id, employee_id)
    {operator.seniority_number, operator.display_name}
  end

  describe "preview_operator_import/2" do
    test "adds a new employee ID, updates a stored one and lists the unused column" do
      organization = organization_fixture()
      create_operator(organization.id, attrs("E4101", "Old Name", 3))

      preview = Operations.preview_operator_import(organization.id, parsed!(@with_phone))

      assert preview.add == [
               %{row: 3, employee_id: "E4200", display_name: "Bo Silva", seniority_number: 7}
             ]

      assert preview.update == [
               %{row: 2, employee_id: "E4101", display_name: "Ana Nowak", seniority_number: 12}
             ]

      assert preview.ignored_columns == ["phone"]
      assert stored(organization.id, "E4101") == {3, "Old Name"}
    end

    test "marks every row :keep when the file has no seniority column" do
      organization = organization_fixture()
      create_operator(organization.id, attrs("E4101", "Old Name", 3))

      preview = Operations.preview_operator_import(organization.id, parsed!(@without_seniority))

      assert preview.update == [
               %{
                 row: 2,
                 employee_id: "E4101",
                 display_name: "Ana Nowak Renamed",
                 seniority_number: :keep
               }
             ]
    end
  end

  describe "apply_operator_import/4" do
    test "adds new operators and updates existing ones with the file's values" do
      organization = organization_fixture()
      existing = create_operator(organization.id, attrs("E4101", "Old Name", 3))
      existing_id = existing.id

      parsed = parsed!(@with_phone)
      preview = Operations.preview_operator_import(organization.id, parsed)

      assert {:ok, %{added: 1, updated: 1}} =
               Operations.apply_operator_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert stored(organization.id, "E4101") == {12, "Ana Nowak"}
      assert stored(organization.id, "E4200") == {7, "Bo Silva"}

      # The update kept the stored row's identity.
      assert lookup(organization.id, "E4101").id == existing_id
    end

    test "adds a file with more rows than one insert statement can bind" do
      organization = organization_fixture()

      # Eight bound columns per operator, so 9,000 rows are 72,000 parameters and
      # a single statement is over PostgreSQL's 65,535 cap. The file is well under
      # the import's size limit.
      content =
        "employee_id,display_name,seniority_number\n" <>
          Enum.map_join(1..9_000, fn number -> "E#{number},Operator #{number},#{number}\n" end)

      parsed = parsed!(content)
      preview = Operations.preview_operator_import(organization.id, parsed)

      assert {:ok, %{added: 9_000, updated: 0}} =
               Operations.apply_operator_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert Repo.aggregate(
               from(o in Operator, where: o.organization_id == ^organization.id),
               :count
             ) ==
               9_000

      assert stored(organization.id, "E9000") == {9_000, "Operator 9000"}
    end

    test "stores no column the file's mapped headers do not carry" do
      organization = organization_fixture()
      create_operator(organization.id, attrs("E4101", "Old Name", 3))

      parsed = parsed!(@with_phone)
      preview = Operations.preview_operator_import(organization.id, parsed)

      assert {:ok, %{added: 1, updated: 1}} =
               Operations.apply_operator_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      stored_rows =
        Operator
        |> where([o], o.organization_id == ^organization.id)
        |> Repo.all()

      assert length(stored_rows) == 2

      for row <- stored_rows do
        refute inspect(row) =~ "555-01"
      end
    end

    test "leaves stored seniority numbers unchanged when the file has no seniority column" do
      organization = organization_fixture()
      create_operator(organization.id, attrs("E4101", "Old Name", 3))

      parsed = parsed!(@without_seniority)
      preview = Operations.preview_operator_import(organization.id, parsed)

      assert {:ok, %{added: 0, updated: 1}} =
               Operations.apply_operator_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert stored(organization.id, "E4101") == {3, "Ana Nowak Renamed"}
    end

    test "clears a stored seniority number when the file's cell is blank" do
      organization = organization_fixture()
      create_operator(organization.id, attrs("E4101", "Old Name", 3))

      content = "employee_id,display_name,seniority_number\nE4101,Ana Nowak,\n"
      parsed = parsed!(content)
      preview = Operations.preview_operator_import(organization.id, parsed)

      assert {:ok, %{added: 0, updated: 1}} =
               Operations.apply_operator_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert stored(organization.id, "E4101") == {nil, "Ana Nowak"}
    end

    test "refuses with a fresh preview and writes nothing when an operator appeared since the preview" do
      organization = organization_fixture()
      parsed = parsed!(@with_phone)
      preview = Operations.preview_operator_import(organization.id, parsed)

      assert preview.add == [
               %{row: 2, employee_id: "E4101", display_name: "Ana Nowak", seniority_number: 12},
               %{row: 3, employee_id: "E4200", display_name: "Bo Silva", seniority_number: 7}
             ]

      assert preview.update == []

      arrived = create_operator(organization.id, attrs("E4101", "Aurelia Nowak", 10))

      assert {:error, {:preview_changed, fresh}} =
               Operations.apply_operator_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert fresh.add == [
               %{row: 3, employee_id: "E4200", display_name: "Bo Silva", seniority_number: 7}
             ]

      assert fresh.update == [
               %{row: 2, employee_id: "E4101", display_name: "Ana Nowak", seniority_number: 12}
             ]

      # Nothing was written: the late arrival is untouched and no add exists.
      assert stored(organization.id, "E4101") == {10, "Aurelia Nowak"}
      assert lookup(organization.id, "E4200") == nil
      assert Repo.get(Operator, arrived.id).display_name == "Aurelia Nowak"
    end

    test "records the acting user and leaves another organization's operators untouched" do
      organization = organization_fixture()
      other = organization_fixture()
      actor = operations_actor(organization.id)

      create_operator(organization.id, attrs("E4101", "Old Name", 3))
      foreign = create_operator(other.id, attrs("E4101", "Foreign Operator", 1))

      parsed = parsed!(@with_phone)
      preview = Operations.preview_operator_import(organization.id, parsed)

      assert {:ok, %{added: 1, updated: 1}} =
               Operations.apply_operator_import(organization.id, actor, parsed, preview)

      assert lookup(organization.id, "E4101").updated_by_id == actor.id
      assert lookup(organization.id, "E4200").updated_by_id == actor.id
      assert stored(other.id, "E4101") == {1, "Foreign Operator"}
      assert Repo.get(Operator, foreign.id).display_name == "Foreign Operator"
    end

    test "ignores a skipped row and a repeated ID" do
      organization = organization_fixture()
      create_operator(organization.id, attrs("E4101", "Old Name", 3))

      content =
        "employee_id,display_name,seniority_number\nE4101,Ana Nowak,12\n" <>
          "E4101,Ana Again,13\n,No Id,4\n"

      parsed = parsed!(content)
      preview = Operations.preview_operator_import(organization.id, parsed)

      assert preview.update == [
               %{row: 2, employee_id: "E4101", display_name: "Ana Nowak", seniority_number: 12}
             ]

      assert preview.add == []

      assert preview.skipped == [
               %{row: 3, id: "E4101", reason: "Repeats E4101 from row 2."},
               %{row: 4, id: nil, reason: "Employee ID is blank."}
             ]

      assert {:ok, %{added: 0, updated: 1}} =
               Operations.apply_operator_import(
                 organization.id,
                 operations_actor(organization.id),
                 parsed,
                 preview
               )

      assert stored(organization.id, "E4101") == {12, "Ana Nowak"}
    end
  end
end
