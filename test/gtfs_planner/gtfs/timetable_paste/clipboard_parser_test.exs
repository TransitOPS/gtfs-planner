defmodule GtfsPlanner.Gtfs.TimetablePaste.ClipboardParserTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.TimetablePaste.ClipboardParser

  @max_bytes 200 * 1024

  defp fixture(name) do
    __DIR__
    |> Path.join("../../../fixtures/timetable_paste")
    |> Path.join(name)
    |> File.read!()
  end

  describe "delimiter detection" do
    test "a tab outside a quoted cell selects tab delimiting" do
      assert ClipboardParser.parse("a\tb\nc\td") ==
               {:ok, %{grid: [["a", "b"], ["c", "d"]], delimiter: :tab}}
    end

    test "a tab inside a quoted CSV cell keeps comma delimiting and one cell" do
      assert ClipboardParser.parse("\"a\tb\",c") ==
               {:ok, %{grid: [["a\tb", "c"]], delimiter: :comma}}
    end

    test "detection restarts quote state on every record" do
      assert ClipboardParser.parse("\"x\"\n1,2") ==
               {:ok, %{grid: [["x", ""], ["1", "2"]], delimiter: :comma}}
    end
  end

  describe "quoted cells" do
    test "doubled quotes decode to one literal quote" do
      assert ClipboardParser.parse("\"a\"\"b\",c") ==
               {:ok, %{grid: [["a\"b", "c"]], delimiter: :comma}}
    end

    test "a quoted cell with an embedded newline does not shift later columns" do
      assert ClipboardParser.parse("a,\"multi\nline\",z\n1,2,3") ==
               {:ok,
                %{
                  grid: [["a", "multi\nline", "z"], ["1", "2", "3"]],
                  delimiter: :comma
                }}
    end

    test "quoted delimiters stay inside the cell" do
      assert ClipboardParser.parse("\"x,y\",\"2\t3\"") ==
               {:ok, %{grid: [["x,y", "2\t3"]], delimiter: :comma}}
    end

    test "an unclosed quote is reported on the line it started" do
      assert ClipboardParser.parse("a,b\n\"open") == {:error, {:unclosed_quote, 2}}
      assert ClipboardParser.parse("a\nb,\n\"start\nmore") == {:error, {:unclosed_quote, 3}}
    end
  end

  describe "normalization" do
    test "CRLF, BOM and ragged rows produce the same padded grid as the fixture expects" do
      text = <<0xEF, 0xBB, 0xBF>> <> "Trip\tBlock\r\n1001\t12\r\n1002"

      assert ClipboardParser.parse(text) ==
               {:ok,
                %{
                  grid: [["Trip", "Block"], ["1001", "12"], ["1002", ""]],
                  delimiter: :tab
                }}

      rectangular = <<0xEF, 0xBB, 0xBF>> <> "Trip\tBlock\r\n1001\t12\r\n1002\t\r\n"

      assert ClipboardParser.parse(rectangular) ==
               {:ok,
                %{
                  grid: [["Trip", "Block"], ["1001", "12"], ["1002", ""]],
                  delimiter: :tab
                }}
    end

    test "cells are trimmed and empty rows are dropped" do
      assert ClipboardParser.parse("a\tb\n\n  \t c  \n") ==
               {:ok, %{grid: [["a", "b"], ["", "c"]], delimiter: :tab}}
    end

    test "trailing empty columns are dropped but interior empty columns are kept" do
      assert ClipboardParser.parse("a,b,\n1,2,") ==
               {:ok, %{grid: [["a", "b"], ["1", "2"]], delimiter: :comma}}

      assert ClipboardParser.parse("a,,b\n1,,2") ==
               {:ok, %{grid: [["a", "", "b"], ["1", "", "2"]], delimiter: :comma}}
    end

    test "blank input is empty" do
      for text <- ["", <<0xEF, 0xBB, 0xBF>>, "  \n \n", ",,"] do
        assert ClipboardParser.parse(text) == {:error, :empty}
      end
    end
  end

  describe "raw bounds" do
    test "input over 200 KB returns {:too_large, bytes} without scanning" do
      oversized = String.duplicate("\"", @max_bytes + 1)
      assert ClipboardParser.parse(oversized) == {:error, {:too_large, @max_bytes + 1}}

      at_limit = String.duplicate("a\tb\n", 500) <> String.duplicate("c", @max_bytes - 500 * 4)
      assert {:ok, %{delimiter: :tab}} = ClipboardParser.parse(at_limit)
    end

    test "more than 501 non-empty records returns {:too_many_rows, n} early" do
      records_501 = Enum.map_join(1..501, "\n", &"r#{&1}\tc#{&1}")

      assert {:ok, %{grid: grid, delimiter: :tab}} = ClipboardParser.parse(records_501)
      assert length(grid) == 501

      assert ClipboardParser.parse(records_501 <> "\nr502\tc502") ==
               {:error, {:too_many_rows, 502}}
    end

    test "blank records do not count toward the record cap" do
      records = Enum.map_join(1..501, "\n", &"r#{&1}\tc#{&1}")

      assert {:ok, %{grid: grid}} = ClipboardParser.parse(records <> "\n\n\n")
      assert length(grid) == 501

      blank_column = String.duplicate("\n", 600) <> "a\tb\n"
      assert {:ok, %{grid: [["a", "b"]]}} = ClipboardParser.parse(blank_column)
    end

    test "more than 501 fields in one record returns {:too_many_columns, n}" do
      fields_501 = Enum.map_join(1..501, ",", &"f#{&1}")

      assert {:ok, %{grid: [grid]}} = ClipboardParser.parse(fields_501)
      assert length(grid) == 501

      assert ClipboardParser.parse(fields_501 <> ",f502") ==
               {:error, {:too_many_columns, 502}}
    end
  end

  describe "transpose" do
    test "transposes only when the option is set" do
      text = "Trip\tBlock\n1001\t12"

      assert ClipboardParser.parse(text) ==
               {:ok, %{grid: [["Trip", "Block"], ["1001", "12"]], delimiter: :tab}}

      assert ClipboardParser.parse(text, transpose: true) ==
               {:ok, %{grid: [["Trip", "1001"], ["Block", "12"]], delimiter: :tab}}
    end
  end

  describe "clipboard fixtures" do
    test "excel_tab.txt parses tab-delimited CRLF cells" do
      assert ClipboardParser.parse(fixture("excel_tab.txt")) ==
               {:ok,
                %{
                  grid: [
                    ["Trip", "Headsign", "Block"],
                    ["1001", "Riverside Terminal", "12"],
                    ["1002", "Riverside Terminal", "12"],
                    ["1003", "Hospital", ""]
                  ],
                  delimiter: :tab
                }}
    end

    test "sheets_tab.txt parses tab-delimited LF cells with quoted commas" do
      assert ClipboardParser.parse(fixture("sheets_tab.txt")) ==
               {:ok,
                %{
                  grid: [
                    ["Trip", "Block", "Headsign"],
                    ["1227", "101", "Downtown Express"],
                    ["1228", "101", "Main St, Annex"],
                    ["1229", "102", "Downtown Express"]
                  ],
                  delimiter: :tab
                }}
    end

    test "numbers_tab.txt parses tab-delimited LF cells with an empty cell" do
      assert ClipboardParser.parse(fixture("numbers_tab.txt")) ==
               {:ok,
                %{
                  grid: [
                    ["Trip", "Block", "Headsign"],
                    ["2201", "7", "Crosstown"],
                    ["2202", "7", "Crosstown"],
                    ["2203", "", "Short Turn"]
                  ],
                  delimiter: :tab
                }}
    end

    test "quoted_csv.txt keeps quoted commas, tabs, quotes and newlines in one cell" do
      assert ClipboardParser.parse(fixture("quoted_csv.txt")) ==
               {:ok,
                %{
                  grid: [
                    ["Route", "Trip", "Notes", ""],
                    ["15", "3001", "Evening run, via depot", ""],
                    ["15", "3002", "Log says \"hold\" at terminal", ""],
                    ["15", "3003", "Blocks\t12-14", ""],
                    ["15", "3004", "Multi-line\nnote", "checked"]
                  ],
                  delimiter: :comma
                }}
    end
  end
end
