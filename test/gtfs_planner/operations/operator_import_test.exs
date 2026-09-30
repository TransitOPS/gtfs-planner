defmodule GtfsPlanner.Operations.OperatorImportTest do
  @moduledoc """
  Parsing and classification of an operators CSV.

  Every file is a literal string, so the expected rows, skip reasons and
  ignored columns below are read off the upload by hand. Names and employee IDs
  are synthetic; an ID that already exists is passed in as `existing_ids`,
  which is all this pure module needs to tell an update from an add.

  The module is pure and reads no stored record, so `async: true` and no
  sandbox are right here.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Operations.OperatorImport
  alias GtfsPlanner.Operations.Tods

  @four_columns "employee_id,display_name,seniority_number,phone\n" <>
                  "E4101,Ana Nowak,12,555-0100\n" <>
                  "E4200,Bo Silva,,555-0101\n"

  describe "parse/3" do
    test "reads an operators CSV into headers and physical rows" do
      content = "employee_id,display_name,seniority_number\nE4101,Ana Nowak,12\n"

      assert {:ok, %{kind: :operators, headers: headers, rows: rows}} =
               Tods.parse(:operators, "operators.csv", content)

      assert headers == ["employee_id", "display_name", "seniority_number"]

      assert rows == [
               {2,
                %{
                  "employee_id" => "E4101",
                  "display_name" => "Ana Nowak",
                  "seniority_number" => "12"
                }}
             ]
    end

    test "refuses a file without the employee_id column" do
      assert Tods.parse(:operators, "operators.csv", "display_name\nAna Nowak\n") ==
               {:error, "operators.csv is missing the employee_id column."}
    end
  end

  describe "classify/2" do
    test "splits rows into add and update and lists columns not used" do
      preview = classify(@four_columns, MapSet.new(["E4101"]))

      assert preview.add == [
               %{row: 3, employee_id: "E4200", display_name: "Bo Silva", seniority_number: nil}
             ]

      assert preview.update == [
               %{row: 2, employee_id: "E4101", display_name: "Ana Nowak", seniority_number: 12}
             ]

      assert preview.ignored_columns == ["phone"]
    end

    test "trims every value it reads" do
      preview = classify("employee_id,display_name\n  E4101  ,  Ana Nowak  \n", MapSet.new())

      assert preview.add == [
               %{row: 2, employee_id: "E4101", display_name: "Ana Nowak", seniority_number: :keep}
             ]
    end

    test "skips a blank employee ID" do
      assert classify_skip_reason("employee_id,display_name\n,Ana Nowak\n") ==
               %{row: 2, id: nil, reason: "Employee ID is blank."}
    end

    test "skips an employee ID longer than 64 characters" do
      long_id = String.duplicate("E", 65)

      assert classify_skip_reason("employee_id,display_name\n#{long_id},Ana Nowak\n") ==
               %{row: 2, id: long_id, reason: "Employee ID is longer than 64 characters."}
    end

    test "skips a blank display name" do
      assert classify_skip_reason("employee_id,display_name\nE4101,  \n") ==
               %{row: 2, id: "E4101", reason: "Display name is blank."}
    end

    test "skips a display name longer than 120 characters" do
      long_name = String.duplicate("N", 121)

      assert classify_skip_reason("employee_id,display_name\nE4101,#{long_name}\n") ==
               %{row: 2, id: "E4101", reason: "Display name is longer than 120 characters."}
    end

    test "skips a seniority number that is not a whole number from 1 to 99,999" do
      reason = "Seniority number must be a whole number from 1 to 99,999."

      for raw <- ["12a", "0", "100000", "1.5", "-3"] do
        content = "employee_id,display_name,seniority_number\nE4101,Ana Nowak,#{raw}\n"

        assert classify_skip_reason(content) == %{row: 2, id: "E4101", reason: reason},
               "expected #{raw} to be skipped"
      end
    end

    test "reads the highest accepted seniority numbers" do
      preview =
        classify(
          "employee_id,display_name,seniority_number\nE4101,Ana Nowak,1\nE4102,Bo Silva,99999\n",
          MapSet.new()
        )

      assert Enum.map(preview.add, & &1.seniority_number) == [1, 99_999]
    end

    test "gives a blank seniority number as nil when the column is present" do
      preview =
        classify("employee_id,display_name,seniority_number\nE4101,Ana Nowak, \n", MapSet.new())

      assert preview.add == [
               %{row: 2, employee_id: "E4101", display_name: "Ana Nowak", seniority_number: nil}
             ]
    end

    test "keeps every seniority number when the file has no such column" do
      preview =
        classify(
          "employee_id,display_name\nE4101,Ana Nowak\nE4102,Bo Silva\n",
          MapSet.new(["E4102"])
        )

      assert Enum.map(preview.add, & &1.seniority_number) == [:keep]
      assert Enum.map(preview.update, & &1.seniority_number) == [:keep]
      assert preview.ignored_columns == []
    end

    test "skips a repeated employee ID naming the first row that carried it" do
      content =
        "employee_id,display_name,seniority_number\n" <>
          "E4200,Bo Silva,\n" <>
          "E4101,Ana Nowak,12\n" <>
          "E4101,Ada Nowak,13\n"

      preview = classify(content, MapSet.new())

      assert preview.skipped == [
               %{row: 4, id: "E4101", reason: "Repeats E4101 from row 3."}
             ]

      assert Enum.map(preview.add ++ preview.update, & &1.row) == [2, 3]
    end

    test "blames the repeat on the first row, not a row skipped for its own reason" do
      content =
        "employee_id,display_name,seniority_number\n" <>
          "E4101,Ana Nowak,12\n" <>
          "E4101,,12\n" <>
          "E4101,Ada Nowak,13\n"

      preview = classify(content, MapSet.new())

      assert preview.skipped == [
               %{row: 3, id: "E4101", reason: "Display name is blank."},
               %{row: 4, id: "E4101", reason: "Repeats E4101 from row 2."}
             ]

      assert [%{row: 2}] = preview.update
    end

    test "does not repeat an employee ID that the organization already holds" do
      preview =
        classify(
          "employee_id,display_name\nE4101,Ana Nowak\nE4101,Ada Nowak\n",
          MapSet.new(["E4101"])
        )

      assert [%{row: 2}] = preview.update
      assert preview.add == []
      assert [%{row: 3, reason: "Repeats E4101 from row 2."}] = preview.skipped
    end
  end

  defp classify(content, existing_ids) do
    assert {:ok, parsed} = Tods.parse(:operators, "operators.csv", content)

    OperatorImport.classify(parsed, existing_ids)
  end

  defp classify_skip_reason(content) do
    assert %{skipped: [note]} = classify(content, MapSet.new())
    note
  end
end
