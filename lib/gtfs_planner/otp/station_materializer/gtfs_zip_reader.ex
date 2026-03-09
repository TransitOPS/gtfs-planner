defmodule GtfsPlanner.Otp.StationMaterializer.GtfsZipReader do
  @moduledoc """
  Strict reader for root-level GTFS text tables inside a zip archive.

  The reader:

  - loads only root-level `*.txt` entries
  - preserves CSV header order per table
  - rejects duplicate headers
  - emits blocking issues for malformed rows
  """

  @type issue :: %{
          required(:code) => atom(),
          required(:severity) => :blocking,
          required(:message) => String.t(),
          required(:context) => map()
        }

  @type row :: %{
          required(:line_number) => pos_integer(),
          required(:fields) => [String.t()],
          required(:values) => %{optional(String.t()) => String.t()}
        }

  @type table :: %{
          required(:header) => [String.t()],
          required(:rows) => [row()]
        }

  @type tables :: %{optional(String.t()) => table()}

  @spec read_tables(String.t()) :: {:ok, tables()} | {:error, [issue()]}
  def read_tables(zip_path) when is_binary(zip_path) do
    with true <- File.regular?(zip_path) || {:error, [zip_not_found_issue(zip_path)]},
         {:ok, entries} <- unzip_entries(zip_path) do
      entries
      |> root_txt_entries()
      |> Enum.sort_by(fn {name, _content} -> name end)
      |> Enum.reduce({%{}, []}, &parse_entry/2)
      |> to_read_result()
    end
  end

  defp unzip_entries(zip_path) do
    case :zip.unzip(String.to_charlist(zip_path), [:memory]) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, [unzip_failed_issue(zip_path, reason)]}
    end
  end

  defp root_txt_entries(entries) do
    Enum.flat_map(entries, fn {name, content} ->
      entry_name = to_string(name)

      if root_level_txt?(entry_name) do
        [{entry_name, content}]
      else
        []
      end
    end)
  end

  defp root_level_txt?(entry_name) do
    String.ends_with?(entry_name, ".txt") and Path.basename(entry_name) == entry_name
  end

  defp parse_entry({entry_name, content}, {tables_acc, issues_acc}) do
    case parse_table(entry_name, content) do
      {:ok, table} -> {Map.put(tables_acc, entry_name, table), issues_acc}
      {:error, issues} -> {tables_acc, issues_acc ++ issues}
    end
  end

  defp parse_table(entry_name, content) do
    lines = split_lines(content)

    case first_non_empty_line(lines) do
      nil ->
        {:ok, %{header: [], rows: []}}

      {header_line_number, header_line} ->
        case parse_csv_line(header_line) do
          {:ok, header} ->
            case validate_header_uniqueness(entry_name, header) do
              :ok -> parse_rows(entry_name, lines, header_line_number, header)
              {:error, issues} -> {:error, issues}
            end

          {:error, reason} ->
            {:error, [malformed_row_issue(entry_name, header_line_number, reason, header_line)]}
        end
    end
  end

  defp parse_rows(entry_name, lines, header_line_number, header) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {_line, line_number} -> line_number > header_line_number end)
    |> Enum.reduce({[], []}, fn {line, line_number}, {rows_acc, issues_acc} ->
      if String.trim(line) == "" do
        {rows_acc, issues_acc}
      else
        case parse_row(entry_name, header, line, line_number) do
          {:ok, row} -> {[row | rows_acc], issues_acc}
          {:error, issue} -> {rows_acc, [issue | issues_acc]}
        end
      end
    end)
    |> case do
      {rows, []} -> {:ok, %{header: header, rows: Enum.reverse(rows)}}
      {_rows, issues} -> {:error, Enum.reverse(issues)}
    end
  end

  defp parse_row(entry_name, header, line, line_number) do
    case parse_csv_line(line) do
      {:ok, fields} when length(fields) == length(header) ->
        {:ok,
         %{
           line_number: line_number,
           fields: fields,
           values: Map.new(Enum.zip(header, fields))
         }}

      {:ok, fields} ->
        {:error, malformed_row_issue(entry_name, line_number, :field_count_mismatch, fields)}

      {:error, reason} ->
        {:error, malformed_row_issue(entry_name, line_number, reason, line)}
    end
  end

  defp split_lines(content) when is_binary(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
  end

  defp first_non_empty_line(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.find(fn {line, _line_number} -> String.trim(line) != "" end)
    |> case do
      nil -> nil
      {line, line_number} -> {line_number, line}
    end
  end

  defp validate_header_uniqueness(entry_name, header) do
    duplicate_headers =
      header
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    case duplicate_headers do
      [] ->
        :ok

      duplicates ->
        {:error, [duplicate_headers_issue(entry_name, duplicates)]}
    end
  end

  defp to_read_result({tables, []}), do: {:ok, tables}
  defp to_read_result({_tables, issues}), do: {:error, issues}

  defp parse_csv_line(line) when is_binary(line) do
    parse_csv_chars(line, [], "", false)
  end

  defp parse_csv_chars(<<>>, fields, current, false) do
    {:ok, Enum.reverse([current | fields])}
  end

  defp parse_csv_chars(<<>>, _fields, _current, true) do
    {:error, :unclosed_quote}
  end

  defp parse_csv_chars(<<?", rest::binary>>, fields, current, false) do
    parse_csv_chars(rest, fields, current, true)
  end

  defp parse_csv_chars(<<?", rest::binary>>, fields, current, true) do
    case rest do
      <<?", rest2::binary>> -> parse_csv_chars(rest2, fields, current <> "\"", true)
      <<?,, rest2::binary>> -> parse_csv_chars(rest2, [current | fields], "", false)
      <<>> -> {:ok, Enum.reverse([current | fields])}
      _ -> {:error, :invalid_quote_placement}
    end
  end

  defp parse_csv_chars(<<?,, rest::binary>>, fields, current, false) do
    parse_csv_chars(rest, [current | fields], "", false)
  end

  defp parse_csv_chars(<<char::utf8, rest::binary>>, fields, current, in_quotes) do
    parse_csv_chars(rest, fields, current <> <<char::utf8>>, in_quotes)
  end

  defp zip_not_found_issue(zip_path) do
    %{
      code: :gtfs_zip_not_found,
      severity: :blocking,
      message: "GTFS zip file was not found",
      context: %{zip_path: zip_path}
    }
  end

  defp unzip_failed_issue(zip_path, reason) do
    %{
      code: :gtfs_zip_unzip_failed,
      severity: :blocking,
      message: "Failed to read GTFS zip archive",
      context: %{zip_path: zip_path, reason: inspect(reason)}
    }
  end

  defp duplicate_headers_issue(file_name, duplicate_headers) do
    %{
      code: :gtfs_duplicate_headers,
      severity: :blocking,
      message: "GTFS file has duplicate CSV headers",
      context: %{file_name: file_name, duplicate_headers: duplicate_headers}
    }
  end

  defp malformed_row_issue(file_name, line_number, reason, row) do
    %{
      code: :gtfs_malformed_row,
      severity: :blocking,
      message: "GTFS file contains malformed CSV row",
      context: %{
        file_name: file_name,
        line_number: line_number,
        reason: inspect(reason),
        row: inspect(row)
      }
    }
  end
end
