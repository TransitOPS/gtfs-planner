defmodule GtfsPlanner.Gtfs.TimetablePaste.ClipboardParser do
  @moduledoc """
  Parses timetable text pasted from Excel, Google Sheets or Numbers into a
  padded grid.

  The delimiter is a tab when a tab occurs outside a quoted cell, otherwise a
  comma. Quoted cells may contain doubled quotes, delimiters and newlines; an
  embedded newline never shifts later columns. A leading UTF-8 BOM is
  stripped, CRLF and LF record endings are accepted, cells are trimmed, empty
  rows and trailing empty columns are dropped, and ragged rows are padded with
  empty cells.

  Raw bounds stop scanning early: 200 KB of input, 501 non-empty records and
  501 fields per record. The exact trip and column limits apply after
  orientation in `TimetablePaste.review/2`.
  """

  @max_bytes 200 * 1024
  @max_records 501
  @max_fields 501

  @type delimiter :: :tab | :comma

  @type error ::
          {:too_large, non_neg_integer()}
          | {:too_many_rows, pos_integer()}
          | {:too_many_columns, pos_integer()}
          | {:unclosed_quote, pos_integer()}
          | :empty

  @spec parse(String.t(), keyword()) ::
          {:ok, %{grid: [[String.t()]], delimiter: delimiter()}} | {:error, error()}
  def parse(text, opts \\ []) when is_binary(text) do
    bytes = byte_size(text)

    if bytes > @max_bytes do
      {:error, {:too_large, bytes}}
    else
      content = strip_bom(text)
      delimiter = if tab_outside_quotes?(content, :field_start), do: :tab, else: :comma

      content
      |> scan(delimiter)
      |> finish(delimiter, Keyword.get(opts, :transpose, false))
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(text), do: text

  # R1: tab is the delimiter when a tab occurs outside a quoted cell.
  defp tab_outside_quotes?(<<>>, _state), do: false
  defp tab_outside_quotes?(<<?\t, _rest::binary>>, state) when state != :quoted, do: true

  defp tab_outside_quotes?(<<?", ?", rest::binary>>, :quoted),
    do: tab_outside_quotes?(rest, :quoted)

  defp tab_outside_quotes?(<<?", rest::binary>>, :field_start),
    do: tab_outside_quotes?(rest, :quoted)

  defp tab_outside_quotes?(<<?", rest::binary>>, :quoted),
    do: tab_outside_quotes?(rest, :after_quote)

  defp tab_outside_quotes?(<<?\n, rest::binary>>, _state),
    do: tab_outside_quotes?(rest, :field_start)

  defp tab_outside_quotes?(<<?\,, rest::binary>>, state) when state != :quoted,
    do: tab_outside_quotes?(rest, :field_start)

  defp tab_outside_quotes?(<<_byte, rest::binary>>, state), do: tab_outside_quotes?(rest, state)

  # Single pass over the clipboard text. `field` and `fields` accumulate the
  # current cell and the reversed cells of the current record; `records`
  # accumulates reversed non-empty records; `count` counts non-empty records
  # seen so far; `quote_line` is the line the current quoted cell opened on.
  defp scan(text, delimiter) do
    delim = if delimiter == :tab, do: ?\t, else: ?,
    scan(text, delim, :field_start, [], [], [], 1, 0, 0)
  end

  defp scan(<<>>, _delim, :quoted, _field, _fields, _records, _line, quote_line, _count) do
    {:error, {:unclosed_quote, quote_line}}
  end

  defp scan(<<>>, _delim, _state, field, fields, records, _line, _quote_line, count) do
    case add_record(records, fields, field, count) do
      {:cont, records, _count} -> {:ok, Enum.reverse(records)}
      {:error, _error} = error -> error
    end
  end

  defp scan(
         <<?", ?", rest::binary>>,
         delim,
         :quoted,
         field,
         fields,
         records,
         line,
         quote_line,
         count
       ) do
    scan(rest, delim, :quoted, ["\"" | field], fields, records, line, quote_line, count)
  end

  defp scan(
         <<?", rest::binary>>,
         delim,
         :field_start,
         field,
         fields,
         records,
         line,
         _quote_line,
         count
       ) do
    scan(rest, delim, :quoted, field, fields, records, line, line, count)
  end

  defp scan(
         <<?", rest::binary>>,
         delim,
         :quoted,
         field,
         fields,
         records,
         line,
         _quote_line,
         count
       ) do
    scan(rest, delim, :after_quote, field, fields, records, line, 0, count)
  end

  defp scan(
         <<?\n, rest::binary>>,
         delim,
         :quoted,
         field,
         fields,
         records,
         line,
         quote_line,
         count
       ) do
    scan(rest, delim, :quoted, ["\n" | field], fields, records, line + 1, quote_line, count)
  end

  defp scan(
         <<delim, rest::binary>>,
         delim,
         state,
         field,
         fields,
         records,
         line,
         _quote_line,
         count
       )
       when state != :quoted do
    case push_field(fields, field) do
      {:cont, fields} -> scan(rest, delim, :field_start, [], fields, records, line, 0, count)
      {:error, _error} = error -> error
    end
  end

  defp scan(<<?\n, rest::binary>>, delim, state, field, fields, records, line, _quote_line, count)
       when state != :quoted do
    case add_record(records, fields, field, count) do
      {:cont, records, count} ->
        scan(rest, delim, :field_start, [], [], records, line + 1, 0, count)

      {:error, _error} = error ->
        error
    end
  end

  defp scan(<<byte, rest::binary>>, delim, state, field, fields, records, line, quote_line, count) do
    state = if state == :field_start, do: :unquoted, else: state
    scan(rest, delim, state, [<<byte>> | field], fields, records, line, quote_line, count)
  end

  defp push_field(fields, field) do
    fields = [field |> Enum.reverse() |> IO.iodata_to_binary() | fields]

    if length(fields) > @max_fields do
      {:error, {:too_many_columns, length(fields)}}
    else
      {:cont, fields}
    end
  end

  defp add_record(records, fields, field, count) do
    case push_field(fields, field) do
      {:cont, fields} ->
        record = Enum.reverse(fields)

        if Enum.any?(record, &(String.trim(&1) != "")) do
          count = count + 1

          if count > @max_records do
            {:error, {:too_many_rows, count}}
          else
            {:cont, [record | records], count}
          end
        else
          {:cont, records, count}
        end

      {:error, _error} = error ->
        error
    end
  end

  defp finish({:error, _error} = error, _delimiter, _transpose?), do: error

  defp finish({:ok, records}, delimiter, transpose?) do
    grid =
      records
      |> Enum.map(fn record -> Enum.map(record, &String.trim/1) end)
      |> drop_trailing_empty_columns()
      |> pad_rows()

    grid = if transpose?, do: transpose(grid), else: grid

    if grid == [] do
      {:error, :empty}
    else
      {:ok, %{grid: grid, delimiter: delimiter}}
    end
  end

  defp drop_trailing_empty_columns([]), do: []

  defp drop_trailing_empty_columns(rows) do
    width = rows |> Enum.map(&length/1) |> Enum.max()
    kept = last_nonempty_column(rows, width - 1)
    Enum.map(rows, &Enum.take(&1, kept + 1))
  end

  defp last_nonempty_column(_rows, col) when col < 0, do: -1

  defp last_nonempty_column(rows, col) do
    if Enum.any?(rows, &(Enum.at(&1, col, "") != "")) do
      col
    else
      last_nonempty_column(rows, col - 1)
    end
  end

  defp pad_rows([]), do: []

  defp pad_rows(rows) do
    width = rows |> Enum.map(&length/1) |> Enum.max()
    Enum.map(rows, &(&1 ++ List.duplicate("", width - length(&1))))
  end

  defp transpose([]), do: []

  defp transpose([first | _] = rows) do
    for col <- 0..(length(first) - 1) do
      Enum.map(rows, &Enum.at(&1, col, ""))
    end
  end
end
