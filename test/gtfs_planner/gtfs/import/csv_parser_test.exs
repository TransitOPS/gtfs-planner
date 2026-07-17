defmodule GtfsPlanner.Gtfs.Import.CsvParserTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Gtfs.Import.ParseError

  @filename "stops.txt"

  describe "stream/2 valid content" do
    test "LF content yields case-sensitive headers, exact count, one event per nonblank record, rows from 2" do
      content = "stop_id,Stop Name,stop_lat\nS1,Main St,1.0\nS2,Second Ave,2.0"

      {:ok, %{headers: headers, source_row_count: count, events: events}} =
        CsvParser.stream(@filename, content)

      assert headers == ["stop_id", "Stop Name", "stop_lat"]
      assert count == 2

      assert Enum.to_list(events) == [
               {:ok, 2, %{"stop_id" => "S1", "Stop Name" => "Main St", "stop_lat" => "1.0"}},
               {:ok, 3, %{"stop_id" => "S2", "Stop Name" => "Second Ave", "stop_lat" => "2.0"}}
             ]
    end

    test "CRLF content is accepted" do
      content = "a,b\r\n1,2\r\n3,4\r\n"
      {:ok, %{source_row_count: count, events: events}} = CsvParser.stream(@filename, content)
      assert count == 2

      assert Enum.to_list(events) == [
               {:ok, 2, %{"a" => "1", "b" => "2"}},
               {:ok, 3, %{"a" => "3", "b" => "4"}}
             ]
    end

    test "leading UTF-8 BOM is stripped" do
      content = <<0xEF, 0xBB, 0xBF>> <> "a,b\n1,2"
      {:ok, %{headers: headers}} = CsvParser.stream(@filename, content)
      assert headers == ["a", "b"]
    end

    test "blank physical lines are skipped without consuming a data row number" do
      content = "a,b\n\n1,2\n\n3,4\n"
      {:ok, %{source_row_count: count, events: events}} = CsvParser.stream(@filename, content)
      assert count == 2

      assert Enum.to_list(events) == [
               {:ok, 3, %{"a" => "1", "b" => "2"}},
               {:ok, 5, %{"a" => "3", "b" => "4"}}
             ]
    end

    test "quoted commas, doubled quotes, and empty fields parse exactly" do
      content = ~s(id,name,note\n1,"quoted,value","say ""hi"""\n2,,plain)
      {:ok, %{events: events}} = CsvParser.stream(@filename, content)

      assert Enum.to_list(events) == [
               {:ok, 2, %{"id" => "1", "name" => "quoted,value", "note" => ~s(say "hi")}},
               {:ok, 3, %{"id" => "2", "name" => "", "note" => "plain"}}
             ]
    end

    test "BOM anywhere other than the start is not stripped" do
      bom = <<0xEF, 0xBB, 0xBF>>
      content = "a" <> bom <> "b\n1x"
      {:ok, %{headers: headers}} = CsvParser.stream(@filename, content)
      assert headers == ["a" <> bom <> "b"]
    end
  end

  describe "stream/2 errors" do
    test "empty content returns :empty_content" do
      assert {:error, %ParseError{file: @filename, reason: :empty_content}} =
               CsvParser.stream(@filename, "")
    end

    test "blank-only content returns :empty_content" do
      assert {:error, %ParseError{file: @filename, reason: :empty_content}} =
               CsvParser.stream(@filename, "\n\r\n")
    end

    test "invalid UTF-8 returns :invalid_utf8" do
      assert {:error, %ParseError{file: @filename, reason: :invalid_utf8}} =
               CsvParser.stream(@filename, <<0xFF, 0xFE>>)
    end

    test "blank header name returns :blank_header" do
      assert {:error, %ParseError{file: @filename, reason: :blank_header}} =
               CsvParser.stream(@filename, "a,,\nb,c")
    end

    test "duplicate header name returns :duplicate_header" do
      assert {:error, %ParseError{file: @filename, reason: :duplicate_header}} =
               CsvParser.stream(@filename, "a,a\n1,2")
    end

    test "wrong field count returns :wrong_field_count per row, no row loss" do
      content = "a,b,c\n1,2\n3,4,5\n6,7,8"
      {:ok, %{events: events}} = CsvParser.stream(@filename, content)

      assert Enum.to_list(events) == [
               {:error,
                %ParseError{
                  file: @filename,
                  row: 2,
                  reason: :wrong_field_count,
                  metadata: %{expected: 3, actual: 2}
                }},
               {:ok, 3, %{"a" => "3", "b" => "4", "c" => "5"}},
               {:ok, 4, %{"a" => "6", "b" => "7", "c" => "8"}}
             ]
    end

    test "unterminated open quote returns :unterminated_quote" do
      content = "a,b\n1,\"unterminated"
      {:ok, %{events: events}} = CsvParser.stream(@filename, content)

      assert Enum.to_list(events) == [
               {:error,
                %ParseError{
                  file: @filename,
                  row: 2,
                  reason: :unterminated_quote,
                  metadata: %{position: :end_of_line}
                }}
             ]
    end

    test "quote in an unquoted field returns :malformed_quote" do
      content = "a,b\n1,val\"ue"
      {:ok, %{events: events}} = CsvParser.stream(@filename, content)

      assert Enum.to_list(events) == [
               {:error,
                %ParseError{
                  file: @filename,
                  row: 2,
                  reason: :malformed_quote
                }}
             ]
    end

    test "text after a closing quote returns :malformed_quote" do
      content = ~s(a,b\n1,"closed"trailing)
      {:ok, %{events: events}} = CsvParser.stream(@filename, content)

      assert [{:error, %ParseError{row: 2, reason: :malformed_quote}}] =
               Enum.to_list(events)
    end

    test "embedded LF in a quoted value is one forbidden-control event and preserves later physical rows" do
      content = "a,b\n1,\"two\nlines\"\n3,4"

      {:ok, %{source_row_count: count, events: events}} = CsvParser.stream(@filename, content)

      assert count == 2

      assert [
               {:error, %ParseError{row: 2, reason: :forbidden_control_character}},
               {:ok, 4, %{"a" => "3", "b" => "4"}}
             ] = Enum.to_list(events)
    end

    test "embedded tab in value returns :forbidden_control_character" do
      content = "a,b\n1,\t2"
      {:ok, %{events: events}} = CsvParser.stream(@filename, content)

      assert [
               {:error,
                %ParseError{file: @filename, row: 2, reason: :forbidden_control_character}}
             ] =
               Enum.to_list(events)
    end

    test "embedded CR in value returns :forbidden_control_character" do
      content = "a,b\n1,\r2"
      {:ok, %{events: events}} = CsvParser.stream(@filename, content)

      assert [
               {:error,
                %ParseError{file: @filename, row: 2, reason: :forbidden_control_character}}
             ] =
               Enum.to_list(events)
    end

    test "lone terminal CR is not stripped as a record ending" do
      {:ok, %{events: events}} = CsvParser.stream(@filename, "a,b\n1,2\r")

      assert [{:error, %ParseError{row: 2, reason: :forbidden_control_character}}] =
               Enum.to_list(events)
    end
  end

  describe "bounded combination invariants" do
    test "every nonblank record produces exactly one event across generated cases" do
      for ending <- ["\n", "\r\n"],
          header <- ["a,b", "a,B", "a,a"],
          row <- ["1,2", "3,4", "x,y", "1,\"quoted,comma\"", "m,n", ""] do
        content = header <> ending <> Enum.join(row_cases(row), ending)

        case CsvParser.stream(@filename, content) do
          {:error, _} ->
            :ok

          {:ok, %{source_row_count: count, events: events}} ->
            events = Enum.to_list(events)
            expected = if row == "", do: 0, else: 1
            assert count == expected
            assert length(events) == expected
        end
      end
    end

    defp row_cases(row) do
      case row do
        "" -> []
        other -> [other]
      end
    end
  end

  describe "parse_line/1 delegation contract" do
    test "simple line" do
      assert CsvParser.parse_line("value1,value2,value3") ==
               {:ok, ["value1", "value2", "value3"]}
    end

    test "quoted fields" do
      assert CsvParser.parse_line(~s(value1,"quoted,value",value3)) ==
               {:ok, ["value1", "quoted,value", "value3"]}
    end

    test "escaped quotes" do
      assert CsvParser.parse_line(~s("quoted ""value"" here",normal)) ==
               {:ok, ["quoted \"value\" here", "normal"]}
    end

    test "empty fields" do
      assert CsvParser.parse_line("value1,,value3") == {:ok, ["value1", "", "value3"]}
      assert CsvParser.parse_line(",,") == {:ok, ["", "", ""]}
    end

    test "trailing comma" do
      assert CsvParser.parse_line("value1,value2,") == {:ok, ["value1", "value2", ""]}
    end

    test "malformed lines return an error without a source row" do
      assert {:error, %ParseError{row: nil, reason: :unterminated_quote}} =
               CsvParser.parse_line(~s("unterminated))

      assert {:error, %ParseError{row: nil, reason: :malformed_quote}} =
               CsvParser.parse_line(~s(value"quote))
    end
  end
end
