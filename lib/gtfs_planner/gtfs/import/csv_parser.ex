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
      content
      |> strip_bom()
      |> stream_valid_content(file)
    else
      parse_error(file, :invalid_utf8)
    end
  end

  defp stream_valid_content("", file), do: parse_error(file, :empty_content)

  defp stream_valid_content(content, file) do
    {records, source_row_count} = split_records(content)
    stream_records(records, source_row_count, file)
  end

  defp stream_records([], _source_row_count, file), do: parse_error(file, :empty_content)

  defp stream_records([{_line_number, header_line} | data_records], source_row_count, file) do
    with {:ok, headers} <- parse_header(file, header_line) do
      events =
        Stream.map(data_records, fn {row, line} ->
          parse_row(file, headers, line, row)
        end)

      {:ok, %{headers: headers, source_row_count: source_row_count, events: events}}
    end
  end

  defp parse_error(file, reason), do: {:error, %ParseError{file: file, reason: reason}}

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp split_records(content) do
    records = split_records(content, :field_start, [], [], 1, 1)
    {records, max(length(records) - 1, 0)}
  end

  defp split_records(<<>>, _state, current, records, record_row, _physical_row) do
    records
    |> add_record(record_row, current)
    |> Enum.reverse()
  end

  defp split_records(<<?\n, rest::binary>>, :quoted, current, records, record_row, physical_row) do
    split_records(rest, :quoted, ["\n" | current], records, record_row, physical_row + 1)
  end

  defp split_records(<<?\n, rest::binary>>, _state, current, records, record_row, physical_row) do
    records = add_record(records, record_row, trim_crlf_cr(current))

    split_records(rest, :field_start, [], records, physical_row + 1, physical_row + 1)
  end

  defp split_records(<<?", ?", rest::binary>>, :quoted, current, records, record_row, row) do
    split_records(rest, :quoted, ["\"", "\"" | current], records, record_row, row)
  end

  defp split_records(<<?", rest::binary>>, state, current, records, record_row, row) do
    next_state =
      case state do
        :field_start -> :quoted
        :quoted -> :after_quote
        :unquoted -> :malformed
        :after_quote -> :malformed
        :malformed -> :malformed
      end

    split_records(rest, next_state, ["\"" | current], records, record_row, row)
  end

  defp split_records(<<?,, rest::binary>>, state, current, records, record_row, row) do
    next_state =
      case state do
        :quoted -> :quoted
        :malformed -> :malformed
        _ -> :field_start
      end

    split_records(rest, next_state, ["," | current], records, record_row, row)
  end

  defp split_records(<<char::utf8, rest::binary>>, state, current, records, record_row, row) do
    next_state =
      case state do
        :field_start -> :unquoted
        :after_quote -> :malformed
        other -> other
      end

    split_records(rest, next_state, [<<char::utf8>> | current], records, record_row, row)
  end

  defp add_record(records, _row, []), do: records

  defp add_record(records, row, reversed_chars) do
    line = reversed_chars |> Enum.reverse() |> IO.iodata_to_binary()
    if line == "", do: records, else: [{row, line} | records]
  end

  # The reverse accumulator starts with CR only when the LF that ended this
  # record was part of CRLF. A lone terminal CR reaches the field parser.
  defp trim_crlf_cr(["\r" | rest]), do: rest
  defp trim_crlf_cr(current), do: current

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
    parse_csv_fields(line, [], "", :field_start, "", nil)
  end

  defp parse_csv_fields(line, file, row) do
    parse_csv_fields(line, [], "", :field_start, file, row)
  end

  defp parse_csv_fields("", fields, current, state, _file, _row)
       when state in [:field_start, :unquoted, :after_quote] do
    {:ok, Enum.reverse([current | fields])}
  end

  defp parse_csv_fields("", _fields, _current, :quoted, file, row) do
    {:error,
     %ParseError{
       file: file,
       row: row,
       reason: :unterminated_quote,
       metadata: %{position: :end_of_line}
     }}
  end

  defp parse_csv_fields("", _fields, _current, :malformed, file, row) do
    malformed_quote(file, row)
  end

  defp parse_csv_fields(<<?\", rest::binary>>, fields, current, :field_start, file, row) do
    parse_csv_fields(rest, fields, current, :quoted, file, row)
  end

  defp parse_csv_fields(<<?\", ?\", rest::binary>>, fields, current, :quoted, file, row) do
    parse_csv_fields(rest, fields, current <> "\"", :quoted, file, row)
  end

  defp parse_csv_fields(<<?\", rest::binary>>, fields, current, :quoted, file, row) do
    parse_csv_fields(rest, fields, current, :after_quote, file, row)
  end

  defp parse_csv_fields(<<?,, rest::binary>>, fields, current, state, file, row)
       when state in [:field_start, :unquoted, :after_quote] do
    parse_csv_fields(rest, [current | fields], "", :field_start, file, row)
  end

  defp parse_csv_fields(<<?\", _rest::binary>>, _fields, _current, state, file, row)
       when state in [:unquoted, :after_quote, :malformed] do
    malformed_quote(file, row)
  end

  defp parse_csv_fields(<<char::utf8, _rest::binary>>, _fields, _current, :after_quote, file, row) do
    if forbidden_control?(char),
      do: forbidden_control(file, row, char),
      else: malformed_quote(file, row)
  end

  defp parse_csv_fields(<<char::utf8, rest::binary>>, fields, current, state, file, row) do
    if forbidden_control?(char) do
      forbidden_control(file, row, char)
    else
      next_state = if state == :field_start, do: :unquoted, else: state
      parse_csv_fields(rest, fields, current <> <<char::utf8>>, next_state, file, row)
    end
  end

  defp malformed_quote(file, row) do
    {:error, %ParseError{file: file, row: row, reason: :malformed_quote}}
  end

  defp forbidden_control(file, row, char) do
    {:error,
     %ParseError{
       file: file,
       row: row,
       reason: :forbidden_control_character,
       metadata: %{character: char}
     }}
  end

  defp forbidden_control?(?\t), do: true
  defp forbidden_control?(?\r), do: true
  defp forbidden_control?(?\n), do: true
  defp forbidden_control?(_), do: false
end
