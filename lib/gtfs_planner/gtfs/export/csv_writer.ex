defmodule GtfsPlanner.Gtfs.Export.CsvWriter do
  @moduledoc """
  Handles CSV serialization with GTFS-compliant escaping and formatting.

  GTFS CSV rules:
  - Fields containing commas, quotes, or newlines must be quoted
  - Quotes within quoted fields are escaped by doubling them
  - nil values are exported as empty strings
  - Booleans are exported as 0 (false) or 1 (true)
  """

  @doc """
  Writes CSV header line to file handle.

  ## Examples

      write_header(file, %{fields: [{"stop_id", :stop_id}, {"stop_name", :stop_name}]})
      # Writes: stop_id,stop_name\n
  """
  def write_header(file_handle, field_spec) do
    header_line =
      field_spec.fields
      |> Enum.map(fn {csv_field_name, _source} -> csv_field_name end)
      |> Enum.join(",")

    IO.write(file_handle, header_line <> "\n")
  end

  @doc """
  Writes a single record as a CSV row to file handle.

  Transforms the Ecto struct to CSV format using the field spec,
  resolving foreign key lookups via the lookup_maps.

  ## Examples

      record = %Stop{stop_id: "S1", stop_name: "Main St", parent_station_id: uuid}
      lookup_maps = %{stop: %{uuid => "STATION1"}}
      write_row(file, record, stops_spec, lookup_maps)
      # Writes: S1,Main St,STATION1\n
  """
  def write_row(file_handle, record, field_spec, lookup_maps) do
    csv_values =
      field_spec.fields
      |> Enum.map(fn {_csv_field_name, source} ->
        value = extract_value(record, source, lookup_maps)
        format_and_escape(value)
      end)
      |> Enum.join(",")

    IO.write(file_handle, csv_values <> "\n")
  end

  # Extracts value from record based on source specification
  defp extract_value(record, source, _lookup_maps) when is_atom(source) do
    Map.get(record, source)
  end

  defp extract_value(record, {:lookup, db_field, lookup_key}, lookup_maps) do
    uuid = Map.get(record, db_field)
    lookup_map = Map.get(lookup_maps, lookup_key, %{})
    Map.get(lookup_map, uuid)
  end

  # Formats and escapes a value for GTFS CSV output
  defp format_and_escape(value) do
    formatted = format_value(value)
    escape_field(formatted)
  end

  @doc """
  Formats Elixir values to GTFS string representation.

  - nil → ""
  - true → "1"
  - false → "0"
  - Decimal → string representation
  - Date → YYYYMMDD format
  - Everything else → to_string/1
  """
  def format_value(nil), do: ""
  def format_value(true), do: "1"
  def format_value(false), do: "0"

  def format_value(%Decimal{} = decimal) do
    Decimal.to_string(decimal)
  end

  def format_value(%Date{} = date) do
    date
    |> Date.to_iso8601()
    |> String.replace("-", "")
  end

  def format_value(value) when is_binary(value), do: value
  def format_value(value), do: to_string(value)

  @doc """
  Escapes field value per GTFS CSV rules.

  Fields containing commas, quotes, or newlines are wrapped in quotes.
  Quotes within quoted fields are doubled.

  ## Examples

      escape_field("simple")
      # => "simple"

      escape_field("has, comma")
      # => "\"has, comma\""

      escape_field("has \"quote\"")
      # => "\"has \"\"quote\"\"\""
  """
  def escape_field(""), do: ""

  def escape_field(value) do
    if needs_quoting?(value) do
      escaped = String.replace(value, "\"", "\"\"")
      "\"#{escaped}\""
    else
      value
    end
  end

  # Check if value needs to be quoted
  defp needs_quoting?(value) do
    String.contains?(value, [",", "\"", "\n", "\r"])
  end
end