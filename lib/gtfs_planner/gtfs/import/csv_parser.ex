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

  `stream/2` parses a binary held in memory. `stream_file/3` applies the same
  contract to a file read in chunks, so memory use is bounded by one record
  rather than by the file.
  """

  alias GtfsPlanner.Gtfs.Import.ParseError

  @default_chunk_bytes 65_536
  @max_record_bytes 1_048_576

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

  @doc """
  Parses the CSV file at `path` under the same contract as `stream/2`, reading
  it in `:chunk_bytes` chunks (default 65,536) instead of loading it.

  The file is read twice. The first pass validates UTF-8 across chunk
  boundaries, counts records and parses the header, so invalid UTF-8 anywhere in
  the file returns `{:error, %ParseError{reason: :invalid_utf8}}` before any row
  event exists. The second pass runs lazily while `events` is enumerated; the
  file must stay readable and unchanged until then.

  A record longer than 1,048,576 bytes, not counting its line terminator, is
  rejected with `:record_too_long`: as a row event, or as the error return when
  it is the header. The scanner drops that record's bytes and resumes at the next
  record, so later rows keep their physical numbers, and an unterminated quote
  consumes the rest of the file as one rejected record instead of buffering it.

  Raises `File.Error` when `path` cannot be read.
  """
  @spec stream_file(String.t(), Path.t(), keyword()) ::
          {:ok, parsed_stream()} | {:error, ParseError.t()}
  def stream_file(file, path, opts \\ []) when is_binary(file) and is_binary(path) do
    chunk_bytes = Keyword.get(opts, :chunk_bytes, @default_chunk_bytes)

    with {:ok, summary} <- prescan(file, path, chunk_bytes) do
      stream_summary(summary, file, path, chunk_bytes)
    end
  end

  # Pass 1: validates UTF-8, counts nonblank records and keeps only the first
  # (the header).
  defp prescan(file, path, chunk_bytes) when is_integer(chunk_bytes) and chunk_bytes > 0 do
    initial = %{utf8_tail: "", scan: new_scan(), count: 0, header: nil}

    scanned =
      path
      |> File.stream!(chunk_bytes)
      |> Enum.reduce_while(initial, fn chunk, acc ->
        case validate_utf8(acc.utf8_tail, chunk) do
          {:ok, utf8_tail} ->
            {records, scan} = scan_chunk(chunk, acc.scan)
            {:cont, tally(%{acc | utf8_tail: utf8_tail, scan: scan}, records)}

          :error ->
            {:halt, :invalid_utf8}
        end
      end)

    case scanned do
      %{utf8_tail: ""} = acc -> {:ok, tally(acc, finish_scan(acc.scan))}
      _invalid -> parse_error(file, :invalid_utf8)
    end
  end

  defp tally(acc, records) do
    %{acc | count: acc.count + length(records), header: acc.header || List.first(records)}
  end

  # `String.valid?/1` only judges whole code points, so the trailing partial
  # sequence of a chunk (at most 3 bytes) is carried into the next chunk.
  defp validate_utf8(tail, chunk) do
    data = tail <> chunk
    size = byte_size(data)
    partial = incomplete_tail_size(data, size)

    if String.valid?(binary_part(data, 0, size - partial)) do
      {:ok, binary_part(data, size - partial, partial)}
    else
      :error
    end
  end

  defp incomplete_tail_size(data, size) do
    Enum.find(1..min(3, size)//1, 0, fn n ->
      incomplete_sequence?(binary_part(data, size - n, n))
    end)
  end

  defp incomplete_sequence?(<<lead, rest::binary>>) when lead in 0xC0..0xF7 do
    byte_size(rest) + 1 < utf8_length(lead)
  end

  defp incomplete_sequence?(_bytes), do: false

  defp utf8_length(lead) when lead < 0xE0, do: 2
  defp utf8_length(lead) when lead < 0xF0, do: 3
  defp utf8_length(_lead), do: 4

  defp stream_summary(%{count: 0}, file, _path, _chunk_bytes),
    do: parse_error(file, :empty_content)

  defp stream_summary(%{header: {row, :too_long}}, file, _path, _chunk_bytes),
    do: {:error, record_too_long(file, row)}

  defp stream_summary(%{count: count, header: {_row, line}}, file, path, chunk_bytes) do
    with {:ok, headers} <- parse_header(file, line) do
      events =
        path
        |> record_stream(chunk_bytes)
        |> Stream.drop(1)
        |> Stream.map(&record_event(file, headers, &1))

      {:ok, %{headers: headers, source_row_count: count - 1, events: events}}
    end
  end

  defp record_event(file, _headers, {row, :too_long}), do: {:error, record_too_long(file, row)}
  defp record_event(file, headers, {row, line}), do: parse_row(file, headers, line, row)

  defp record_too_long(file, row) do
    %ParseError{
      file: file,
      row: row,
      reason: :record_too_long,
      metadata: %{max_bytes: @max_record_bytes}
    }
  end

  # Pass 2: lazily yields `{row, line | :too_long}` for every nonblank record,
  # header included. `File.stream!/2` closes the file when enumeration ends or
  # halts.
  defp record_stream(path, chunk_bytes) do
    Stream.transform(
      File.stream!(path, chunk_bytes),
      &new_scan/0,
      &scan_chunk/2,
      fn scan -> {finish_scan(scan), scan} end,
      fn _scan -> :ok end
    )
  end

  # Record scanner. It applies the record-splitting rules of `split_records/6`
  # to bytes instead of code points, which is equivalent because only ASCII bytes
  # change state and UTF-8 continuation bytes are never ASCII. Scan state:
  #
  #   * `head` - bytes held until a leading BOM can be ruled in or out
  #   * `state` - quote state after the last scanned byte
  #   * `row` / `record_row` - physical row now, and where the record began
  #   * `buf` / `len` - reversed segments of the current record and their size;
  #     `buf` becomes `:too_long` once the record exceeds the limit
  defp new_scan, do: %{head: "", state: :field_start, row: 1, record_row: 1, buf: [], len: 0}

  defp scan_chunk(chunk, %{head: :done} = scan) do
    scan_bytes(chunk, 0, 0, byte_size(chunk), scan.state, scan.row, scan, [])
  end

  defp scan_chunk(chunk, %{head: head} = scan) do
    data = head <> chunk

    if byte_size(data) < 3 do
      {[], %{scan | head: data}}
    else
      scan_chunk(strip_bom(data), %{scan | head: :done})
    end
  end

  defp finish_scan(%{head: head} = scan) when head != :done do
    {records, scan} = scan_chunk(head, %{scan | head: :done})
    records ++ finish_scan(scan)
  end

  # Unlike an LF-terminated record, a lone CR at end of file stays in the record.
  defp finish_scan(scan) do
    case finish_record(scan, :eof) do
      nil -> []
      record -> [record]
    end
  end

  # Bytes from `seg` to `pos` belong to the current record and are copied out
  # only when the record ends or the chunk does.
  defp scan_bytes(chunk, pos, seg, size, state, row, scan, records) when pos == size do
    scan = %{buffer(scan, chunk, seg, pos) | state: state, row: row}
    {Enum.reverse(records), scan}
  end

  defp scan_bytes(chunk, pos, seg, size, state, row, scan, records) do
    case :binary.at(chunk, pos) do
      ?\n when state == :quoted ->
        scan_bytes(chunk, pos + 1, seg, size, state, row + 1, scan, records)

      ?\n ->
        scan = buffer(scan, chunk, seg, pos)
        records = prepend_record(finish_record(scan, :lf), records)
        scan = %{scan | buf: [], len: 0, record_row: row + 1}
        scan_bytes(chunk, pos + 1, pos + 1, size, :field_start, row + 1, scan, records)

      byte ->
        scan_bytes(chunk, pos + 1, seg, size, next_state(state, byte), row, scan, records)
    end
  end

  # `:quote_pending` is a quote seen inside a quoted field: a second quote makes
  # it a doubled quote, anything else makes it the closing quote.
  defp next_state(:quote_pending, ?"), do: :quoted
  defp next_state(:quote_pending, byte), do: next_state(:after_quote, byte)
  defp next_state(:quoted, ?"), do: :quote_pending
  defp next_state(:quoted, _byte), do: :quoted
  defp next_state(:malformed, _byte), do: :malformed
  defp next_state(:field_start, ?"), do: :quoted
  defp next_state(:field_start, ?,), do: :field_start
  defp next_state(:field_start, _byte), do: :unquoted
  defp next_state(:unquoted, ?"), do: :malformed
  defp next_state(:unquoted, ?,), do: :field_start
  defp next_state(:unquoted, _byte), do: :unquoted
  defp next_state(:after_quote, ?,), do: :field_start
  defp next_state(:after_quote, _byte), do: :malformed

  defp buffer(%{buf: :too_long} = scan, _chunk, _seg, _pos), do: scan
  defp buffer(scan, _chunk, seg, pos) when seg == pos, do: scan

  # The limit is checked one byte late so that a trailing CR, which the record
  # end trims, never decides it; `finish_record/2` applies the exact limit.
  defp buffer(%{buf: buf, len: len} = scan, chunk, seg, pos) do
    len = len + pos - seg

    if len > @max_record_bytes + 1 do
      %{scan | buf: :too_long}
    else
      %{scan | buf: [binary_part(chunk, seg, pos - seg) | buf], len: len}
    end
  end

  defp finish_record(%{buf: :too_long, record_row: row}, _terminator), do: {row, :too_long}

  defp finish_record(%{buf: buf, record_row: row}, terminator) do
    line = buf |> Enum.reverse() |> IO.iodata_to_binary() |> trim_terminator(terminator)

    cond do
      line == "" -> nil
      byte_size(line) > @max_record_bytes -> {row, :too_long}
      true -> {row, line}
    end
  end

  # The CR of a CRLF ending is not part of the record.
  defp trim_terminator(line, :lf) when line != "" do
    if :binary.last(line) == ?\r, do: binary_part(line, 0, byte_size(line) - 1), else: line
  end

  defp trim_terminator(line, _terminator), do: line

  defp prepend_record(nil, records), do: records
  defp prepend_record(record, records), do: [record | records]

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
