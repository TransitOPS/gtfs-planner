defmodule GtfsPlanner.Operations.Tods do
  @moduledoc """
  Pure TODS file parsing, classification and export row mapping for garages and
  vehicles.

  `parse/3` runs the shared strict CSV parser over an uploaded
  `stops_supplement.txt` or `vehicles.txt`; `classify/1` splits the parsed rows
  into accepted, skipped and error rows. Nothing here touches the database —
  `GtfsPlanner.Operations` owns every decision that depends on stored records,
  such as add versus update and the coordinates a new garage needs.
  Accepted rows carry the destination field atoms for the columns the file
  actually has (`:name`, `:lat`, `:lon` for garages; `:vehicle_label`,
  `:license_plate` for vehicles). A present column appears with its trimmed
  value, possibly `""` for a blank; an absent column is missing from the map, so
  the caller can apply the TODS absent/blank rules.

  The `*_spec/0` functions are the export's column specs for the six files an
  operations export may write. Four of them — the movement supplements
  `calendar_dates_supplement.txt`, `routes_supplement.txt`, `trips_supplement.txt`
  and `stop_times_supplement.txt` — hold the rows `GtfsPlanner.Gtfs.Blocking.TodsExport`
  derives; their column names are that module's row keys, and this module is the
  one place the file's shape is written down.
  """

  alias GtfsPlanner.Gtfs.Import.{CsvParser, ParseError}
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Vehicle

  @max_import_bytes 2_000_000
  @max_value_length 255

  # Compared after `String.trim |> String.downcase`, so the accepted list can
  # grow from evidence without changing the classification order.
  @garage_location_types ["garage"]

  @garage_id_format ~r/^[A-Za-z0-9_.:-]+$/

  @id_headers %{garages: "stop_id", vehicles: "vehicle_id"}

  @mapped_headers %{
    garages: ["stop_id", "stop_name", "stop_lat", "stop_lon", "TODS_location_type", "TODS_delete"],
    vehicles: ["vehicle_id", "vehicle_label", "license_plate"]
  }

  @field_atoms %{
    garages: %{"stop_name" => :name, "stop_lat" => :lat, "stop_lon" => :lon},
    vehicles: %{"vehicle_label" => :vehicle_label, "license_plate" => :license_plate}
  }

  @length_checked_columns %{
    garages: ["stop_id", "stop_name"],
    vehicles: ["vehicle_id", "vehicle_label", "license_plate"]
  }

  @coordinate_columns [{"stop_lat", -90, 90}, {"stop_lon", -180, 180}]

  @type kind :: :garages | :vehicles

  @type parsed :: %{
          kind: kind(),
          headers: [String.t()],
          rows: [{pos_integer(), %{String.t() => String.t()}}]
        }

  @type row_note :: %{row: pos_integer(), id: String.t() | nil, reason: String.t()}

  @type preview :: %{
          kind: kind(),
          add: [String.t()],
          update: [String.t()],
          skipped: [row_note()],
          errors: [row_note()],
          ignored_columns: [String.t()]
        }

  @doc """
  Maximum accepted upload size in bytes.
  """
  @spec max_import_bytes() :: pos_integer()
  def max_import_bytes, do: @max_import_bytes

  @doc """
  Parses one TODS file into its headers and physical rows.

  Returns `{:error, message}` for content above `max_import_bytes/0`, for a CSV
  parser error (the message names the row when the parser knows it) and for a
  missing ID column. Nothing may be previewed or applied after a structural
  error. `file` is the uploaded filename and is used for diagnostics only.
  """
  @spec parse(kind(), String.t(), binary()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(kind, file, content) when kind in [:garages, :vehicles] and is_binary(content) do
    if byte_size(content) > @max_import_bytes do
      {:error, "#{file} is too large (limit #{@max_import_bytes} bytes)."}
    else
      parse_content(kind, file, content)
    end
  end

  defp parse_content(kind, file, content) do
    case CsvParser.stream(file, content) do
      {:ok, %{headers: headers, events: events}} -> build_parsed(kind, file, headers, events)
      {:error, %ParseError{} = error} -> {:error, describe_parse_error(error)}
    end
  end

  defp build_parsed(kind, file, headers, events) do
    with :ok <- validate_header(kind, file, headers),
         {:ok, rows} <- collect_rows(events) do
      {:ok, %{kind: kind, headers: headers, rows: rows}}
    end
  end

  @doc """
  Splits parsed rows into accepted, skipped and error rows.

  Garage rows follow the prepared order: `TODS_delete = 1`, then an absent or
  blank `TODS_location_type` (both would change or add a public stop), then a
  location type outside `garage`. Surviving rows are trimmed and validated
  before a repeated ID is reported against the first accepted row that carried
  it. Foreign columns are ignored and listed in `ignored_columns`.
  """
  @spec classify(parsed()) :: %{
          accepted: [%{row: pos_integer(), id: String.t(), fields: map()}],
          skipped: [row_note()],
          errors: [row_note()],
          ignored_columns: [String.t()]
        }
  def classify(%{kind: kind, headers: headers, rows: rows}) do
    {accepted, skipped, errors, _first_rows} =
      Enum.reduce(rows, {[], [], [], %{}}, fn {row, values}, acc ->
        classify_row(kind, row, values, acc)
      end)

    %{
      accepted: Enum.reverse(accepted),
      skipped: Enum.reverse(skipped),
      errors: Enum.reverse(errors),
      ignored_columns: Enum.reject(headers, &(&1 in @mapped_headers[kind]))
    }
  end

  @doc """
  Column spec for the exported `stops_supplement.txt`.

  `location_type` is always `0` and `TODS_location_type` always `garage`, so a
  consumer's merged view only learns that the stop is a garage.
  """
  @spec stops_supplement_spec() :: %{filename: String.t(), fields: [{String.t(), atom()}]}
  def stops_supplement_spec do
    %{
      filename: "stops_supplement.txt",
      fields: [
        {"stop_id", :stop_id},
        {"stop_name", :stop_name},
        {"stop_lat", :stop_lat},
        {"stop_lon", :stop_lon},
        {"location_type", :location_type},
        {"TODS_location_type", :tods_location_type}
      ]
    }
  end

  @doc """
  Column spec for the exported `vehicles.txt`.
  """
  @spec vehicles_spec() :: %{filename: String.t(), fields: [{String.t(), atom()}]}
  def vehicles_spec do
    %{
      filename: "vehicles.txt",
      fields: [
        {"vehicle_id", :vehicle_id},
        {"vehicle_label", :vehicle_label},
        {"license_plate", :license_plate}
      ]
    }
  end

  @doc """
  Column spec for the exported `calendar_dates_supplement.txt`.

  A movement carries no revenue, so the public calendar has no service for it;
  this file is where a consumer learns that a supplement service runs on one
  date. Every row is an addition (`exception_type` `1`), which is what
  `Blocking.TodsExport` writes.
  """
  @spec calendar_dates_supplement_spec() :: %{
          filename: String.t(),
          fields: [{String.t(), atom()}]
        }
  def calendar_dates_supplement_spec do
    %{
      filename: "calendar_dates_supplement.txt",
      fields: [
        {"service_id", :service_id},
        {"date", :date},
        {"exception_type", :exception_type}
      ]
    }
  end

  @doc """
  Column spec for the exported `routes_supplement.txt`.

  One row: the deadhead route every movement runs on, named by
  `Blocking.TodsExport`.
  """
  @spec routes_supplement_spec() :: %{filename: String.t(), fields: [{String.t(), atom()}]}
  def routes_supplement_spec do
    %{
      filename: "routes_supplement.txt",
      fields: [
        {"route_id", :route_id},
        {"route_short_name", :route_short_name},
        {"route_long_name", :route_long_name},
        {"route_type", :route_type}
      ]
    }
  end

  @doc """
  Column spec for the exported `trips_supplement.txt`.

  `TODS_trip_type` is the movement's kind as a consumer reads it: `pull-out`,
  `pull-back` or `deadhead`.
  """
  @spec trips_supplement_spec() :: %{filename: String.t(), fields: [{String.t(), atom()}]}
  def trips_supplement_spec do
    %{
      filename: "trips_supplement.txt",
      fields: [
        {"route_id", :route_id},
        {"service_id", :service_id},
        {"trip_id", :trip_id},
        {"TODS_trip_type", :tods_trip_type}
      ]
    }
  end

  @doc """
  Column spec for the exported `stop_times_supplement.txt`.

  A movement's two rows are its endpoints; `arrival_time` equals
  `departure_time` at both, because a deadhead has no dwell.
  """
  @spec stop_times_supplement_spec() :: %{filename: String.t(), fields: [{String.t(), atom()}]}
  def stop_times_supplement_spec do
    %{
      filename: "stop_times_supplement.txt",
      fields: [
        {"trip_id", :trip_id},
        {"arrival_time", :arrival_time},
        {"departure_time", :departure_time},
        {"stop_id", :stop_id},
        {"stop_sequence", :stop_sequence}
      ]
    }
  end

  @doc """
  Maps a garage to its `stops_supplement.txt` row.
  """
  @spec garage_export_row(Garage.t()) :: map()
  def garage_export_row(%Garage{} = garage) do
    %{
      stop_id: garage.garage_id,
      stop_name: garage.name,
      stop_lat: garage.lat,
      stop_lon: garage.lon,
      location_type: 0,
      tods_location_type: "garage"
    }
  end

  @doc """
  Maps a vehicle to its `vehicles.txt` row.
  """
  @spec vehicle_export_row(Vehicle.t()) :: map()
  def vehicle_export_row(%Vehicle{} = vehicle) do
    %{
      vehicle_id: vehicle.vehicle_id,
      vehicle_label: vehicle.vehicle_label,
      license_plate: vehicle.license_plate
    }
  end

  defp classify_row(:garages, row, values, acc) do
    id = value(values, "stop_id")
    delete = value(values, "TODS_delete")
    location_type = value(values, "TODS_location_type")

    cond do
      delete == "1" ->
        skip(acc, row, id, "Requests a deletion; deletions are not imported.")

      location_type == "" ->
        skip(acc, row, id, "Changes or adds a public stop; not imported.")

      String.downcase(location_type) not in @garage_location_types ->
        skip(acc, row, id, "Not a garage (TODS_location_type: #{location_type}).")

      true ->
        reason = garage_error(id, values)
        accept_or_reject(acc, row, id, reason, fields(:garages, values))
    end
  end

  defp classify_row(:vehicles, row, values, acc) do
    id = value(values, "vehicle_id")
    reason = vehicle_error(id, values)
    accept_or_reject(acc, row, id, reason, fields(:vehicles, values))
  end

  defp garage_error(id, values) do
    cond do
      id == "" ->
        "Stop ID is required."

      not Regex.match?(@garage_id_format, id) ->
        "Stop ID may contain only letters, numbers, periods, underscores, colons and hyphens."

      true ->
        length_error(:garages, values) || coordinate_error(values)
    end
  end

  defp vehicle_error("", _values), do: "Vehicle ID is required."

  defp vehicle_error(_id, values), do: length_error(:vehicles, values)

  defp length_error(kind, values) do
    Enum.find_value(@length_checked_columns[kind], fn column ->
      if String.length(value(values, column)) > @max_value_length do
        "#{column} is longer than #{@max_value_length} characters."
      end
    end)
  end

  defp coordinate_error(values) do
    Enum.find_value(@coordinate_columns, fn {column, low, high} ->
      case parse_coordinate(value(values, column)) do
        :blank ->
          nil

        :not_a_number ->
          "#{column} is not a number."

        {:ok, number} when number < low or number > high ->
          "#{column} must be between #{low} and #{high}."

        {:ok, _number} ->
          nil
      end
    end)
  end

  defp parse_coordinate(""), do: :blank

  defp parse_coordinate(raw) do
    case Float.parse(raw) do
      {number, ""} -> {:ok, number}
      _other -> :not_a_number
    end
  end

  # Only columns present in the file appear in the map: a blank value must stay
  # distinguishable from an absent column for the caller's TODS field rules.
  defp fields(kind, values) do
    Enum.reduce(@field_atoms[kind], %{}, fn {column, field}, acc ->
      if Map.has_key?(values, column), do: Map.put(acc, field, value(values, column)), else: acc
    end)
  end

  defp accept_or_reject({accepted, skipped, errors, first_rows}, row, id, nil, fields) do
    case Map.fetch(first_rows, id) do
      {:ok, first_row} ->
        {accepted, skipped, [note(row, id, "Repeats #{id} from row #{first_row}.") | errors],
         first_rows}

      :error ->
        {[%{row: row, id: id, fields: fields} | accepted], skipped, errors,
         Map.put(first_rows, id, row)}
    end
  end

  defp accept_or_reject({accepted, skipped, errors, first_rows}, row, id, reason, _fields) do
    {accepted, skipped, [note(row, id, reason) | errors], first_rows}
  end

  defp skip({accepted, skipped, errors, first_rows}, row, id, reason) do
    {accepted, [note(row, id, reason) | skipped], errors, first_rows}
  end

  defp note(row, id, reason), do: %{row: row, id: id_or_nil(id), reason: reason}

  defp id_or_nil(""), do: nil
  defp id_or_nil(id), do: id

  defp value(values, column) do
    values |> Map.get(column) |> trim()
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)

  defp validate_header(kind, file, headers) do
    id_header = @id_headers[kind]

    if id_header in headers do
      :ok
    else
      {:error, "#{file} is missing the #{id_header} column."}
    end
  end

  defp collect_rows(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, row, values}, {:ok, acc} ->
        {:cont, {:ok, [{row, values} | acc]}}

      {:error, %ParseError{} = error}, {:ok, _acc} ->
        {:halt, {:error, describe_parse_error(error)}}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, message} -> {:error, message}
    end
  end

  defp describe_parse_error(%ParseError{file: file, row: row, reason: reason}) do
    label = parse_reason_label(reason)

    cond do
      not is_binary(file) -> label
      is_integer(row) -> "#{file} row #{row}: #{label}"
      true -> "#{file}: #{label}"
    end
  end

  # Kept in step with the Import page's operator-facing wording for the reasons
  # `CsvParser.stream/2` can produce; this module needs it because `parse/3`
  # returns a message rather than the ParseError struct.
  defp parse_reason_label(:empty_content), do: "File is empty"
  defp parse_reason_label(:invalid_utf8), do: "File uses an unsupported text encoding"
  defp parse_reason_label(:blank_header), do: "Column name is blank"
  defp parse_reason_label(:duplicate_header), do: "Column name is duplicated"
  defp parse_reason_label(:wrong_field_count), do: "Row has the wrong number of values"
  defp parse_reason_label(:unterminated_quote), do: "Quoted value is not closed"
  defp parse_reason_label(:malformed_quote), do: "Quoted value is malformed"

  defp parse_reason_label(:forbidden_control_character),
    do: "Row contains an invalid line break or tab"

  defp parse_reason_label(reason) when is_atom(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ")
  end
end
