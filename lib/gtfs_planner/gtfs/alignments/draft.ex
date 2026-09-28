defmodule GtfsPlanner.Gtfs.Alignments.Draft do
  @moduledoc """
  Normalizes untrusted browser draft sections against a resolved pattern.

  Pure R16 trust-boundary validation: the hook owns draft geometry and the
  server only receives dirty sections, so every number, op string, identity
  pair and count is re-checked here before `review_save/3` (step 10) sees it.
  Stored `[lon, lat]` axis order is preserved end to end (INV-1); section
  identity is `(from_occurrence_id, to_stop_id)` per INV-6. Known op strings
  are mapped explicitly; `String.to_atom/1` is never used on input.
  """

  alias GtfsPlanner.Gtfs.AlignmentSegment

  @max_save_points 50_000

  @type op :: %{
          position: pos_integer(),
          op: :set | :delete | :use_shared,
          points: [[float()]],
          base: %{segment_id: Ecto.UUID.t() | nil, lock_version: pos_integer() | nil},
          from_occurrence_id: Ecto.UUID.t(),
          to_stop_id: String.t()
        }

  @doc """
  Turns hook draft sections into validated ops.

  Returns `{:error, :stale_stops}` when a draft identity pair no longer
  matches the resolved section, and `{:error, {:invalid_draft, reason}}`
  otherwise. An empty draft is `{:ok, []}` only for a complete pattern whose
  export is not `:current` (a materialize-only save); otherwise `:empty`.
  """
  @spec normalize([map()], map()) ::
          {:ok, [op()]} | {:error, :stale_stops | {:invalid_draft, atom()}}
  def normalize([], resolved) do
    status = Map.get(resolved, :status, %{})
    missing = Map.get(status, :missing, 1)
    blocked = Map.get(status, :blocked, 1)
    export = Map.get(status, :export, :none)

    if missing == 0 and blocked == 0 and export != :current do
      {:ok, []}
    else
      {:error, {:invalid_draft, :empty}}
    end
  end

  def normalize(params, resolved) when is_list(params) do
    sections =
      resolved |> Map.get(:sections, []) |> Map.new(fn section -> {section.position, section} end)

    max_points = AlignmentSegment.max_points()

    result =
      Enum.reduce_while(params, {:ok, [], MapSet.new(), 0}, fn entry, {:ok, acc, seen, total} ->
        case normalize_entry(entry, sections, seen, max_points) do
          {:ok, op, count} ->
            {:cont, {:ok, [op | acc], MapSet.put(seen, op.position), total + count}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, reversed, _seen, total} ->
        if total > @max_save_points do
          {:error, {:invalid_draft, :too_many_points}}
        else
          {:ok, Enum.reverse(reversed)}
        end

      {:error, _} = error ->
        error
    end
  end

  def normalize(_params, _resolved), do: {:error, {:invalid_draft, :malformed}}

  defp normalize_entry(entry, sections, seen, max_points) when is_map(entry) do
    with {:ok, position} <- parse_position(entry),
         {:ok, section} <- lookup_section(sections, seen, position),
         :ok <- check_identity(entry, section),
         {:ok, op} <- parse_op(entry),
         {:ok, base} <- parse_base(entry),
         :ok <- check_op_kind(op, section),
         {:ok, points} <- parse_points(entry, op, max_points) do
      {:ok,
       %{
         position: position,
         op: op,
         points: points,
         base: base,
         from_occurrence_id: section.from_occurrence_id,
         to_stop_id: section.to_stop_id
       }, length(points)}
    end
  end

  defp normalize_entry(_entry, _sections, _seen, _max_points),
    do: {:error, {:invalid_draft, :malformed}}

  defp parse_position(%{"position" => position}) when is_integer(position), do: {:ok, position}
  defp parse_position(_entry), do: {:error, {:invalid_draft, :malformed}}

  defp lookup_section(sections, seen, position) do
    case Map.get(sections, position) do
      nil -> {:error, {:invalid_draft, :unknown_section}}
      section when is_map(section) -> lookup_seen(seen, position, section)
    end
  end

  defp lookup_seen(seen, position, section) do
    if MapSet.member?(seen, position) do
      {:error, {:invalid_draft, :duplicate_section}}
    else
      {:ok, section}
    end
  end

  defp check_identity(entry, section) do
    if entry["from_occurrence_id"] == section.from_occurrence_id and
         entry["to_stop_id"] == section.to_stop_id do
      :ok
    else
      {:error, :stale_stops}
    end
  end

  defp parse_op(%{"op" => "set"}), do: {:ok, :set}
  defp parse_op(%{"op" => "delete"}), do: {:ok, :delete}
  defp parse_op(%{"op" => "use_shared"}), do: {:ok, :use_shared}
  defp parse_op(_entry), do: {:error, {:invalid_draft, :malformed}}

  defp parse_base(entry) do
    case Map.get(entry, "base") do
      nil ->
        {:ok, %{segment_id: nil, lock_version: nil}}

      base when is_map(base) ->
        segment_id = Map.get(base, "segment_id")
        lock_version = Map.get(base, "lock_version")

        if (is_nil(segment_id) or is_binary(segment_id)) and
             (is_nil(lock_version) or is_integer(lock_version)) do
          {:ok, %{segment_id: segment_id, lock_version: lock_version}}
        else
          {:error, {:invalid_draft, :malformed}}
        end

      _base ->
        {:error, {:invalid_draft, :malformed}}
    end
  end

  # Sections without coordinates accept no draft ops; the stops must be
  # fixed first. Blocked zero-length sections stay drawable: the editor
  # offers "Draw manually" on them (R5's remedy), so a manual set passes
  # here like any drawable section.
  defp check_op_kind(_op, %{kind: :blocked, blocked_reason: :no_coordinates}),
    do: {:error, {:invalid_draft, :blocked_section}}

  defp check_op_kind(:set, _section), do: :ok
  defp check_op_kind(:delete, %{kind: :missing}), do: {:error, {:invalid_draft, :invalid_op}}
  defp check_op_kind(:delete, _section), do: :ok
  defp check_op_kind(:use_shared, %{kind: :override}), do: :ok
  defp check_op_kind(:use_shared, _section), do: {:error, {:invalid_draft, :invalid_op}}

  # Non-set ops carry no geometry; any sent points are ignored.
  defp parse_points(_entry, op, _max_points) when op != :set, do: {:ok, []}

  defp parse_points(%{"points" => points}, :set, max_points),
    do: normalize_points(points, max_points)

  defp parse_points(_entry, :set, _max_points), do: {:error, {:invalid_draft, :malformed}}

  defp normalize_points(points, max_points) when is_list(points) do
    if length(points) > max_points do
      {:error, {:invalid_draft, :too_many_points}}
    else
      Enum.reduce_while(points, {:ok, []}, fn pair, {:ok, acc} ->
        case normalize_pair(pair) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    end
  end

  defp normalize_points(_points, _max_points), do: {:error, {:invalid_draft, :malformed}}

  # JSON numbers may arrive as integers; strings and other shapes are invalid.
  # The JSON wire format admits only finite numbers, so is_number plus the
  # range check covers the R16 "finite numbers in range" bound.
  defp normalize_pair([lon, lat]) when is_number(lon) and is_number(lat) do
    lon_f = lon * 1.0
    lat_f = lat * 1.0

    cond do
      lon_f < -180 or lon_f > 180 or lat_f < -90 or lat_f > 90 ->
        {:error, {:invalid_draft, :out_of_range}}

      true ->
        {:ok, [lon_f, lat_f]}
    end
  end

  defp normalize_pair(_pair), do: {:error, {:invalid_draft, :malformed}}
end
