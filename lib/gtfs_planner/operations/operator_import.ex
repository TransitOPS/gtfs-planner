defmodule GtfsPlanner.Operations.OperatorImport do
  @moduledoc """
  Pure classification of a parsed operators CSV into rows to add, rows to
  update and rows to skip with a reason.

  Only `employee_id`, `display_name` and `seniority_number` are read; every
  other column the file carries is listed in `ignored_columns` and never
  reaches an operator. Nothing here touches the database:
  `GtfsPlanner.Operations` owns which employee IDs already exist and the write,
  and passes the existing IDs in.

  An invalid row is skipped with a reason rather than blocking the file, so an
  HR list with one bad value still imports the rest; the review names each
  skipped row.
  """

  alias GtfsPlanner.Operations.Tods

  @employee_id_max 64
  @display_name_max 120
  @seniority_max 99_999

  @mapped_headers ["employee_id", "display_name", "seniority_number"]

  @type row :: %{
          row: pos_integer(),
          employee_id: String.t(),
          display_name: String.t(),
          seniority_number: pos_integer() | nil | :keep
        }

  @type preview :: %{
          add: [row()],
          update: [row()],
          skipped: [Tods.row_note()],
          ignored_columns: [String.t()]
        }

  @doc """
  Splits parsed operator rows into add, update and skipped.

  `existing_ids` is the set of employee IDs the organization already holds: a
  row carrying one of them is an update, any other valid row is an add. A row
  repeating an earlier row's employee ID is skipped and names that first row.

  `seniority_number` is `:keep` when the file has no `seniority_number` column
  at all — the stored number then stays — and `nil` when the column is present
  but blank.
  """
  @spec classify(Tods.parsed(), MapSet.t(String.t())) :: preview()
  def classify(%{kind: :operators, headers: headers, rows: rows}, existing_ids) do
    keep_seniority? = "seniority_number" not in headers

    {add, update, skipped, _first_rows} =
      Enum.reduce(rows, {[], [], [], %{}}, fn {row, values}, acc ->
        classify_row(row, values, existing_ids, keep_seniority?, acc)
      end)

    %{
      add: Enum.reverse(add),
      update: Enum.reverse(update),
      skipped: Enum.reverse(skipped),
      ignored_columns: Enum.reject(headers, &(&1 in @mapped_headers))
    }
  end

  defp classify_row(row, values, existing_ids, keep_seniority?, acc) do
    employee_id = value(values, "employee_id")
    display_name = value(values, "display_name")

    case row_error(employee_id, display_name, values, keep_seniority?) do
      nil ->
        accept_or_reject(
          acc,
          row,
          %{
            row: row,
            employee_id: employee_id,
            display_name: display_name,
            seniority_number: seniority_number(values, keep_seniority?)
          },
          existing_ids
        )

      reason ->
        skip(acc, row, employee_id, reason)
    end
  end

  defp row_error(employee_id, display_name, values, keep_seniority?) do
    cond do
      employee_id == "" ->
        "Employee ID is blank."

      String.length(employee_id) > @employee_id_max ->
        "Employee ID is longer than #{@employee_id_max} characters."

      display_name == "" ->
        "Display name is blank."

      String.length(display_name) > @display_name_max ->
        "Display name is longer than #{@display_name_max} characters."

      true ->
        seniority_error(value(values, "seniority_number"), keep_seniority?)
    end
  end

  defp seniority_error(_raw, true), do: nil

  defp seniority_error("", _keep_seniority?), do: nil

  defp seniority_error(raw, _keep_seniority?) do
    case Integer.parse(raw) do
      {number, ""} when number >= 1 and number <= @seniority_max -> nil
      _other -> "Seniority number must be a whole number from 1 to 99,999."
    end
  end

  defp seniority_number(_values, true), do: :keep
  defp seniority_number(values, false), do: parse_seniority(value(values, "seniority_number"))

  defp parse_seniority(""), do: nil

  # Only reached once `seniority_error/2` accepted the value; the fallback keeps
  # a later reordering from turning a bad cell into a crash.
  defp parse_seniority(raw) do
    case Integer.parse(raw) do
      {number, ""} -> number
      _other -> nil
    end
  end

  # Mirrors `Tods.classify/1`: a repeat is reported against the first row that
  # was accepted with that ID, so a row skipped for its own reason neither
  # claims the ID nor is blamed for a later one. An accepted row lands in
  # exactly one of add and update: a stored employee ID is an update only, and
  # an apply would otherwise insert the row it also updates.
  defp accept_or_reject({add, update, skipped, first_rows}, row, new_row, existing_ids) do
    case Map.fetch(first_rows, new_row.employee_id) do
      {:ok, first_row} ->
        {add, update,
         [
           note(row, new_row.employee_id, "Repeats #{new_row.employee_id} from row #{first_row}.")
           | skipped
         ], first_rows}

      :error ->
        first_rows = Map.put(first_rows, new_row.employee_id, row)

        if MapSet.member?(existing_ids, new_row.employee_id) do
          {add, [new_row | update], skipped, first_rows}
        else
          {[new_row | add], update, skipped, first_rows}
        end
    end
  end

  defp skip({add, update, skipped, first_rows}, row, id, reason) do
    {add, update, [note(row, id, reason) | skipped], first_rows}
  end

  defp note(row, id, reason), do: %{row: row, id: id_or_nil(id), reason: reason}

  defp id_or_nil(""), do: nil
  defp id_or_nil(id), do: id

  defp value(values, column) do
    values |> Map.get(column) |> trim()
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
end
