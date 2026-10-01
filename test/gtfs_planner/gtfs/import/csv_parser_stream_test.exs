defmodule GtfsPlanner.Gtfs.Import.CsvParserStreamTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Gtfs.Import.ParseError

  @filename "stops.txt"
  @bom <<0xEF, 0xBB, 0xBF>>
  @max_record_bytes 1_048_576
  @chunk_sizes [1, 7, 64, 65_536]

  # The inputs of csv_parser_test.exs, then inputs that put a BOM, CRLF, doubled
  # quotes, a quote before LF and multi-byte characters on chunk boundaries.
  # stream/2 is the oracle: it is exercised by csv_parser_test.exs.
  @cases [
    {"LF content", "stop_id,Stop Name,stop_lat\nS1,Main St,1.0\nS2,Second Ave,2.0"},
    {"CRLF content", "a,b\r\n1,2\r\n3,4\r\n"},
    {"leading BOM", @bom <> "a,b\n1,2"},
    {"blank physical lines", "a,b\n\n1,2\n\n3,4\n"},
    {"quoted commas, doubled quotes and empty fields",
     ~s(id,name,note\n1,"quoted,value","say ""hi"""\n2,,plain)},
    {"BOM after the first byte", "a" <> @bom <> "b\n1x"},
    {"empty content", ""},
    {"blank-only content", "\n\r\n"},
    {"invalid UTF-8", <<0xFF, 0xFE>>},
    {"blank header name", "a,,\nb,c"},
    {"duplicate header name", "a,a\n1,2"},
    {"wrong field count", "a,b,c\n1,2\n3,4,5\n6,7,8"},
    {"unterminated quote", "a,b\n1,\"unterminated"},
    {"quote in an unquoted field", "a,b\n1,val\"ue"},
    {"text after a closing quote", ~s(a,b\n1,"closed"trailing)},
    {"embedded LF in a quoted value", "a,b\n1,\"two\nlines\"\n3,4"},
    {"embedded tab", "a,b\n1,\t2"},
    {"embedded CR", "a,b\n1,\r2"},
    {"lone terminal CR", "a,b\n1,2\r"},
    {"header only", "a,b\n"},
    {"one-byte file", "a"},
    {"BOM only", @bom},
    {"first two bytes of a BOM", <<0xEF, 0xBB>>},
    {"BOM with CRLF and quoted values", @bom <> "a,b\r\n\"1\",\"2\"\r\n"},
    {"doubled quotes only", "a,b\n\"\"\"\",\"\"\n"},
    {"closing quote before LF", "a,b\n1,\"x\"\n\"y\",2"},
    {"blank line inside a quoted value", "a,b\n1,\"x\n\ny\"\n3,4\n"},
    {"CRLF inside a quoted value", "a,b\r\n1,\"x\r\ny\"\r\n3,4\r\n"},
    {"trailing blank lines", "a,b\n1,2\n\n\r\n"},
    {"header after blank lines", "\n\na,b\n1,2\n"},
    {"LF inside a quoted header name", "\"a\nb\",c\n1,2\n"},
    {"multi-byte characters", "name,city\nCafé,Zürich\n日本,東京\n😀,x\n"},
    {"truncated multi-byte character at end of file", "a,b\n1," <> <<0xE2, 0x82>>},
    {"surrogate code point", "a,b\n1," <> <<0xED, 0xA0, 0x80>>},
    {"overlong encoding", "a,b\n1," <> <<0xC0, 0xAF>>}
  ]

  # Mirrors the generated combinations in csv_parser_test.exs.
  combination_cases =
    for ending <- ["\n", "\r\n"],
        header <- ["a,b", "a,B", "a,a"],
        row <- ["1,2", "3,4", "x,y", "1,\"quoted,comma\"", "m,n", ""] do
      content = header <> ending <> row
      {"generated #{inspect(content)}", content}
    end

  @combination_cases combination_cases

  setup do
    dir =
      Path.join(System.tmp_dir!(), "csv_parser_stream_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  describe "stream_file/3 matches stream/2" do
    for {name, content} <- @cases ++ @combination_cases, chunk_bytes <- @chunk_sizes do
      test "#{name}, #{chunk_bytes}-byte chunks", %{dir: dir} do
        path = write_file(dir, unquote(content))

        assert snapshot(CsvParser.stream_file(@filename, path, chunk_bytes: unquote(chunk_bytes))) ==
                 snapshot(CsvParser.stream(@filename, unquote(content)))
      end
    end
  end

  describe "stream_file/3 strict contract" do
    test "quoted LF is one forbidden-control event and the next record keeps its physical row",
         %{dir: dir} do
      path = write_file(dir, "a,b\n\"x\ny\",z\nc,d\n")

      {:ok, %{source_row_count: count, events: events}} =
        CsvParser.stream_file(@filename, path, chunk_bytes: 3)

      assert count == 2

      assert [
               {:error,
                %ParseError{
                  file: @filename,
                  row: 2,
                  reason: :forbidden_control_character,
                  metadata: %{character: ?\n}
                }},
               {:ok, 4, %{"a" => "c", "b" => "d"}}
             ] = Enum.to_list(events)
    end

    test "invalid UTF-8 at byte 200,000 returns invalid_utf8 instead of a stream", %{dir: dir} do
      valid = "a,b\n" <> String.duplicate("1,2\n", 60_000)
      <<before::binary-size(200_000), _byte, rest::binary>> = valid
      path = write_file(dir, before <> <<0xFF>> <> rest)

      assert {:error, %ParseError{file: @filename, row: nil, reason: :invalid_utf8}} =
               CsvParser.stream_file(@filename, path)
    end

    # "a,b\n1," is 6 bytes, so the 4-byte character starts at byte 6 and these
    # chunk sizes cut it after its first, second and third byte.
    for chunk_bytes <- [7, 8, 9] do
      test "a 4-byte character split by #{chunk_bytes}-byte chunks is accepted", %{dir: dir} do
        path = write_file(dir, "a,b\n1,😀\n")

        assert {:ok, %{headers: ["a", "b"], source_row_count: 1, events: events}} =
                 CsvParser.stream_file(@filename, path, chunk_bytes: unquote(chunk_bytes))

        assert Enum.to_list(events) == [{:ok, 2, %{"a" => "1", "b" => "😀"}}]
      end
    end

    test "a BOM split across chunks is stripped", %{dir: dir} do
      path = write_file(dir, @bom <> "a,b\n1,2\n")

      assert {:ok, %{headers: ["a", "b"], events: events}} =
               CsvParser.stream_file(@filename, path, chunk_bytes: 2)

      assert Enum.to_list(events) == [{:ok, 2, %{"a" => "1", "b" => "2"}}]
    end

    test "CRLF endings produce the same events as LF", %{dir: dir} do
      lf = write_file(dir, "a,b\n1,\"x,y\"\n\n3,4\n")
      crlf = write_file(dir, "a,b\r\n1,\"x,y\"\r\n\r\n3,4\r\n")

      assert snapshot(CsvParser.stream_file(@filename, crlf, chunk_bytes: 3)) ==
               snapshot(CsvParser.stream_file(@filename, lf, chunk_bytes: 3))
    end

    test "raises File.Error when the file is missing", %{dir: dir} do
      assert_raise File.Error, fn ->
        CsvParser.stream_file(@filename, Path.join(dir, "missing.txt"))
      end
    end
  end

  describe "stream_file/3 record size limit" do
    test "a 2 MiB record is one record_too_long event and the next record keeps its row",
         %{dir: dir} do
      path = write_file(dir, "a,b\n1," <> String.duplicate("x", 2 * 1_048_576) <> "\n3,4\n")

      {:ok, %{source_row_count: count, events: events}} = CsvParser.stream_file(@filename, path)

      assert count == 2

      assert [
               {:error,
                %ParseError{
                  file: @filename,
                  row: 2,
                  reason: :record_too_long,
                  metadata: %{max_bytes: @max_record_bytes}
                }},
               {:ok, 3, %{"a" => "3", "b" => "4"}}
             ] = Enum.to_list(events)
    end

    test "a record of exactly 1,048,576 bytes is accepted", %{dir: dir} do
      path = write_file(dir, "a,b\n" <> record_of(@max_record_bytes) <> "\n3,4\n")

      {:ok, %{events: events}} = CsvParser.stream_file(@filename, path, chunk_bytes: 1000)

      assert [{:ok, 2, %{"a" => "1", "b" => value}}, {:ok, 3, %{"a" => "3", "b" => "4"}}] =
               Enum.to_list(events)

      assert byte_size(value) == @max_record_bytes - 2
    end

    test "a record of 1,048,577 bytes is rejected", %{dir: dir} do
      path = write_file(dir, "a,b\n" <> record_of(@max_record_bytes + 1) <> "\n3,4\n")

      {:ok, %{events: events}} = CsvParser.stream_file(@filename, path, chunk_bytes: 1000)

      assert [
               {:error, %ParseError{row: 2, reason: :record_too_long}},
               {:ok, 3, %{"a" => "3", "b" => "4"}}
             ] = Enum.to_list(events)
    end

    test "the CR of a CRLF ending does not count toward the limit", %{dir: dir} do
      path = write_file(dir, "a,b\r\n" <> record_of(@max_record_bytes) <> "\r\n3,4\r\n")

      {:ok, %{events: events}} = CsvParser.stream_file(@filename, path, chunk_bytes: 1000)

      assert [{:ok, 2, %{"a" => "1"}}, {:ok, 3, %{"a" => "3", "b" => "4"}}] =
               Enum.to_list(events)
    end

    test "an oversized quoted record preserves the physical row of the record after it",
         %{dir: dir} do
      quoted = "1,\"" <> String.duplicate("x\n", 600_000) <> "\""
      path = write_file(dir, "a,b\n" <> quoted <> "\n3,4\n")

      {:ok, %{source_row_count: count, events: events}} = CsvParser.stream_file(@filename, path)

      assert count == 2

      assert [
               {:error, %ParseError{row: 2, reason: :record_too_long}},
               {:ok, 600_003, %{"a" => "3", "b" => "4"}}
             ] = Enum.to_list(events)
    end

    test "an unterminated quote rejects the rest of the file as one record", %{dir: dir} do
      path = write_file(dir, "a,b\n1,\"" <> String.duplicate("x\n", 600_000))

      {:ok, %{source_row_count: count, events: events}} = CsvParser.stream_file(@filename, path)

      assert count == 1
      assert [{:error, %ParseError{row: 2, reason: :record_too_long}}] = Enum.to_list(events)
    end

    test "an oversized header returns record_too_long", %{dir: dir} do
      path = write_file(dir, "a," <> String.duplicate("x", 2 * 1_048_576) <> "\n1,2\n")

      assert {:error,
              %ParseError{
                file: @filename,
                row: 1,
                reason: :record_too_long,
                metadata: %{max_bytes: @max_record_bytes}
              }} = CsvParser.stream_file(@filename, path)
    end
  end

  # A data record of `size` bytes: `1,` then padding.
  defp record_of(size), do: "1," <> String.duplicate("x", size - 2)

  defp write_file(dir, content) do
    path = Path.join(dir, "#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    path
  end

  defp snapshot({:ok, %{headers: headers, source_row_count: count, events: events}}),
    do: {:ok, headers, count, Enum.to_list(events)}

  defp snapshot({:error, %ParseError{}} = error), do: error
end
