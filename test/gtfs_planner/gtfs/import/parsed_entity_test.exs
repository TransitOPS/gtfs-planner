defmodule GtfsPlanner.Gtfs.Import.ParsedEntityTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Import.ParseError
  alias GtfsPlanner.Gtfs.Import.ParsedEntity

  defp atomize(row_map) do
    Enum.into(row_map, %{}, fn {k, v} -> {String.to_atom(k), v} end)
  end

  describe "parse/5" do
    test "nil input returns :not_uploaded" do
      assert ParsedEntity.parse(nil, :level, "levels.txt", :level_id, fn row -> {:ok, row} end) ==
               :not_uploaded
    end

    test "complete input returns {:ok, ParsedEntity} keyed by natural-key value with exact row count" do
      content = "level_id,level_name\nL1,Platform\nL2,Mezzanine\n"
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, fn row -> {:ok, atomize(row)} end)

      assert {:ok, entity} = result
      assert entity.entity_type == :level
      assert entity.filename == "levels.txt"
      assert entity.source_row_count == 2
      assert entity.records_by_key == %{"L1" => %{level_id: "L1", level_name: "Platform"}, "L2" => %{level_id: "L2", level_name: "Mezzanine"}}
    end

    test "a valid header-only file returns {:ok, ParsedEntity} with empty records_by_key" do
      content = "level_id,level_name\n"
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, fn row -> {:ok, atomize(row)} end)

      assert {:ok, entity} = result
      assert entity.records_by_key == %{}
      assert entity.source_row_count == 0
    end

    test "missing natural-key header returns {:error, ParseFailure} with :missing_natural_key_header" do
      content = "other_id,level_name\nL1,Platform\n"
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, fn row -> {:ok, atomize(row)} end)

      assert {:error, failure} = result
      assert failure.entity_type == :level
      assert failure.filename == "levels.txt"
      assert failure.total_error_count == 1
      assert [%ParseError{reason: :missing_natural_key_header, file: "levels.txt"}] = failure.diagnostics
    end

    test "blank natural key returns {:error, ParseFailure} with :blank_natural_key" do
      content = "level_id,level_name\n,Platform\n"
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, fn row -> {:ok, atomize(row)} end)

      assert {:error, failure} = result
      assert [%ParseError{reason: :blank_natural_key, row: 2}] = failure.diagnostics
    end

    test "duplicate natural key returns {:error, ParseFailure} with :duplicate_natural_key" do
      content = "level_id,level_name\nL1,Platform\nL1,Second\n"
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, fn row -> {:ok, atomize(row)} end)

      assert {:error, failure} = result
      assert [%ParseError{reason: :duplicate_natural_key, row: 3, metadata: %{key: "L1"}}] = failure.diagnostics
      assert failure.preview_records_by_key == %{"L1" => %{level_id: "L1", level_name: "Platform"}}
    end

    test "structural row error returns {:error, ParseFailure} with the matching reason" do
      content = "level_id,level_name\nL1\n"
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, fn row -> {:ok, atomize(row)} end)

      assert {:error, failure} = result
      assert [%ParseError{reason: :wrong_field_count, row: 2}] = failure.diagnostics
    end

    test "semantic conversion error returns {:error, ParseFailure} with :semantic_row and bounded reason" do
      content = "level_id,level_name\nL1,Platform\n"
      row_parser = fn _row -> {:error, :bad_level} end
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, row_parser)

      assert {:error, failure} = result
      assert [%ParseError{reason: :semantic_row, row: 2, metadata: %{cause: :bad_level}}] = failure.diagnostics
    end

    test "a raising parser callback returns {:error, ParseFailure} with :unexpected_parser_failure and sanitized log" do
      content = "level_id,level_name\nL1,Platform\n"
      row_parser = fn _row -> raise "boom details" end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, row_parser)
          assert {:error, failure} = result
          assert [%ParseError{reason: :unexpected_parser_failure, row: 2}] = failure.diagnostics
        end)

      assert log =~ "levels.txt"
      assert log =~ "level"
      assert log =~ "RuntimeError"
      refute log =~ "boom details"
      refute log =~ "Platform"
    end

    test "a throwing parser callback returns {:error, ParseFailure} with :unexpected_parser_failure" do
      content = "level_id,level_name\nL1,Platform\n"
      row_parser = fn _row -> throw(:weird) end
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, row_parser)

      assert {:error, failure} = result
      assert [%ParseError{reason: :unexpected_parser_failure, row: 2}] = failure.diagnostics
    end

    test "an exiting parser callback returns {:error, ParseFailure} with :unexpected_parser_failure" do
      content = "level_id,level_name\nL1,Platform\n"
      row_parser = fn _row -> exit(:kill) end
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, row_parser)

      assert {:error, failure} = result
      assert [%ParseError{reason: :unexpected_parser_failure, row: 2}] = failure.diagnostics
    end

    test "with more than 100 errors, diagnostics stop at 100 while total_error_count is exact and truncated? is true" do
      header = "level_id,level_name\n"
      rows = Enum.map(1..250, fn i -> "#{i}\n" end)
      content = header <> Enum.join(rows)

      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, fn row -> {:ok, atomize(row)} end)

      assert {:error, failure} = result
      assert failure.total_error_count == 250
      assert failure.truncated? == true
      assert length(failure.diagnostics) == 100
      assert failure.first_error_row == 2
      assert failure.last_error_row == 251
    end

    test "an error on the final row after valid rows still prevents {:ok, ...}" do
      rows = Enum.map(1..50, fn i -> "L#{i},Name#{i}\n" end) ++ ["Ldup,Dup\n", "L1,Again\n"]
      content = "level_id,level_name\n" <> Enum.join(rows)

      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, fn row -> {:ok, atomize(row)} end)

      assert {:error, failure} = result
      assert failure.last_error_row == 53
      assert Enum.any?(failure.diagnostics, fn %ParseError{reason: :duplicate_natural_key} -> true; _ -> false end)
    end

    test "duplicate keys retain the first-seen record deterministically in preview_records_by_key" do
      content = "level_id,level_name\nL1,First\nL1,Second\n"
      result = ParsedEntity.parse(%{filename: "levels.txt", content: content}, :level, "levels.txt", :level_id, fn row -> {:ok, atomize(row)} end)

      assert {:error, failure} = result
      assert failure.preview_records_by_key == %{"L1" => %{level_id: "L1", level_name: "First"}}
    end
  end
end
