defmodule GtfsPlanner.Gtfs.Import.CsvParser do
  @moduledoc """
  GTFS-specific structural CSV parsing.

  This is a GTFS parser, not a generic RFC 4180 parser; multiline field values
  are invalid under the GTFS contract. It strips one leading UTF-8 BOM only at
  the beginning of the header, accepts LF and CRLF record endings, preserves
  case-sensitive header names, accepts commas and doubled quotes inside quoted
  fields, and returns physical data-row numbers beginning at 2. It rejects
  invalid UTF-8, empty content, blank or duplicate header names, wrong field
  counts, unterminated or malformed quoting, and tabs or embedded
  carriage-return/newline characters in values. Blank physical lines may be
  ignored, but every nonblank data record must produce exactly one row event.
  """

  alias GtfsPlanner.Gtfs.Import.ParseError

  @type row_event ::
          {:ok, pos_integer(), %{required(String.t()) => String.t()}}
          | {:error, ParseError.t()}

  @type parsed_stream :: %{
          headers: [String.t()],
          source_row_count: non_neg_integer(),
          events: Enumerable.t()
        }

  @spec stream(String.t(), binary()) ::
          {:ok, parsed_stream()} | {:error, ParseError.t()}

  def stream(file, content) when is_binary(content) do
    if String.valid?(content) do
      content = strip_bom(content)

      if content == "" do
        {:error, %ParseError{file: file, reason: :empty_content}}
      else
        {records, source_row_count} = split_records(content)
        {_line_number, header_line} = hd(records)
        headers = parse_header(file, header_line)

        case headers do
          {:ok, headers} ->
            data_records = tl(records)

            events =
              data_records
              |> Stream.map(fn {row, line} ->
                parse_row(file, headers, line, row)
              end)

            {:ok, %{headers: headers, source_row_count: source_row_count, events: events}}

          {:error, error} ->
            {:error, error}
        end
      end
    else
      {:error, %ParseError{file: file, reason: :invalid_utf8}}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp split_records(content) do
    lines = String.split(content, "\n")

    {records, nonblank_count, _physical} =
      Enum.reduce(lines, {[], 0, 0}, fn line, {acc, count, physical} ->
        line = trim_cr(line)
        physical = physical + 1

        if line == "" do
          {acc, count, physical}
        else
          {[{physical, line} | acc], count + 1, physical}
        end
      end)

    {Enum.reverse(records), max(nonblank_count - 1, 0)}
  end

  defp trim_cr(<<>>), do: <<>>
  defp trim_cr(line) do
    size = byte_size(line)
    last = :binary.part(line, size - 1, 1)
    if last == "\r", do: :binary.part(line, 0, size - 1), else: line
  end

  defp parse_header(file, line) do
    case parse_csv_fields(line, file, 1) do
      {:ok, fields} ->
        validate_header_names(file, fields, [], MapSet.new())

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_header_names(_file, [], acc, _seen) do
    {:ok, Enum.reverse(acc)}
  end

  defp validate_header_names(file, [name | rest], acc, seen) do
    if name == "" do
      {:error, %ParseError{file: file, reason: :blank_header}}
    else
      if MapSet.member?(seen, name) do
        {:error,
         %ParseError{
           file: file,
           reason: :duplicate_header,
           metadata: %{header: name}
         }}
      else
        validate_header_names(file, rest, [name | acc], MapSet.put(seen, name))
      end
    end
  end

  defp parse_row(file, headers, line, row) do
    case parse_csv_fields(line, file, row) do
      {:ok, fields} ->
        if length(fields) == length(headers) do
          {:ok, row, Enum.zip(headers, fields) |> Map.new()}
        else
          {:error,
           %ParseError{
             file: file,
             row: row,
             reason: :wrong_field_count,
             metadata: %{expected: length(headers), actual: length(fields)}
           }}
        end

      {:error, error} ->
        {:error, %{error | row: row}}
    end
  end

  @doc false
  def parse_line(line) when is_binary(line) do
    parse_csv_fields(line, [], "", false, 0, "", 0)
  end

  defp parse_csv_fields(line, file, row) do
    parse_csv_fields(line, [], "", false, 0, file, row)
  end

  defp parse_csv_fields("", fields, current, false, _pos, _file, _row) do
    {:ok, Enum.reverse([current | fields])}
  end

  defp parse_csv_fields("", _fields, _current, true, _pos, file, row) do
    {:error,
     %ParseError{
       file: file,
       row: row,
       reason: :unterminated_quote,
       metadata: %{position: :end_of_line}
     }}
  end

  defp parse_csv_fields(<<char::utf8, rest::binary>>, fields, current, in_quotes, pos, file, row) do
    case {char, in_quotes} do
      {?\", false} ->
        parse_csv_fields(rest, fields, current, true, pos + 1, file, row)

      {?\", true} ->
        case rest do
          <<?\", rest2::binary>> ->
            parse_csv_fields(rest2, fields, current <> "\"", true, pos + 2, file, row)

          _ ->
            parse_csv_fields(rest, fields, current, false, pos + 1, file, row)
        end

      {?,, false} ->
        parse_csv_fields(rest, [current | fields], "", false, pos + 1, file, row)

      {char, true} ->
        if forbidden_control?(char) do
          {:error,
           %ParseError{
             file: file,
             row: row,
             reason: :forbidden_control_character,
             metadata: %{character: char}
           }}
        else
          parse_csv_fields(rest, fields, current <> <<char::utf8>>, true, pos + 1, file, row)
        end

      {char, false} ->
        if forbidden_control?(char) do
          {:error,
           %ParseError{
             file: file,
             row: row,
             reason: :forbidden_control_character,
             metadata: %{character: char}
           }}
        else
          parse_csv_fields(rest, fields, current <> <<char::utf8>>, false, pos + 1, file, row)
        end
    end
  end

  defp forbidden_control?(?\t), do: true
  defp forbidden_control?(?\r), do: true
  defp forbidden_control?(?\n), do: true
  defp forbidden_control?(_), do: false
end
