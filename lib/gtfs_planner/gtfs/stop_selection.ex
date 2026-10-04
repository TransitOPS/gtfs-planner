defmodule GtfsPlanner.Gtfs.StopSelection do
  @moduledoc """
  Resolves pasted stop references to stops inside one organization and version,
  without ever guessing.

  A line is a stop ID, a stop code or an exact stop name. Each line is resolved by
  the first tier that matches anything, in this order: `stop_id` (case-sensitive),
  `stop_code` (case-sensitive), then `stop_name` equal after trimming
  (case-sensitive). A tier with one match resolves the line; a tier with two or more
  returns every candidate for the editor to choose from. Nothing is fuzzy, ignores
  case or reads a wildcard: each tier is one `IN` query over the whole list. The read
  writes nothing, and a stop of another organization or version never appears.

  Directional twins such as `Main St @ St Paul EB` and `... WB` stay separate: two
  lines naming two stops are two matches, and one line naming both is ambiguous.
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  # Engineering ceilings of the approval form, not editor limits.
  @max_lines 100
  @max_line_length 200
  @max_candidates 10
  @tiers [:stop_id, :stop_code, :stop_name]

  @type basis :: :stop_id | :stop_code | :stop_name
  @type summary :: %{
          uuid: Ecto.UUID.t(),
          stop_id: String.t(),
          stop_name: String.t() | nil,
          stop_code: String.t() | nil,
          location_type: integer() | nil,
          parent_station: String.t() | nil
        }

  @doc """
  Resolves `refs`, a list of strings, as described in the module doc.

  Lines are trimmed, blanks dropped and exact repeats collapsed to the first. More
  than 100 remaining lines is `{:error, :too_many}`; a non-string, or a line over 200
  characters, is `{:error, :invalid_input}`.

  `resolved` lists each stop once with every line that named it and the basis of its
  first line; `ambiguous` lists each line a tier matched more than once with at most 10
  candidates sorted by `stop_id` and their exact `candidate_total`; `unresolved` keeps
  input order.
  """
  @spec resolve(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()]) ::
          {:ok,
           %{
             resolved: [%{refs: [String.t()], basis: basis(), stop: summary()}],
             ambiguous: [
               %{
                 ref: String.t(),
                 basis: basis(),
                 candidates: [summary()],
                 candidate_total: pos_integer()
               }
             ],
             unresolved: [String.t()]
           }}
          | {:error, :too_many | :invalid_input}
  def resolve(organization_id, gtfs_version_id, refs)
      when is_binary(organization_id) and is_binary(gtfs_version_id) and is_list(refs) do
    with {:ok, lines} <- normalize(refs) do
      matches = match_lines(lines, organization_id, gtfs_version_id)
      {:ok, assemble(lines, matches)}
    end
  end

  def resolve(_organization_id, _gtfs_version_id, _refs), do: {:error, :invalid_input}

  defp normalize(refs) do
    cond do
      not Enum.all?(refs, &is_binary/1) ->
        {:error, :invalid_input}

      Enum.any?(refs, &(String.length(&1) > @max_line_length)) ->
        {:error, :invalid_input}

      true ->
        lines = refs |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
        if length(lines) > @max_lines, do: {:error, :too_many}, else: {:ok, lines}
    end
  end

  # The first tier with any match decides a line, so a later tier is only asked about
  # the lines the earlier ones left, in one query over those lines.
  defp match_lines(lines, organization_id, gtfs_version_id) do
    {matches, _remaining} =
      Enum.reduce(@tiers, {%{}, lines}, fn tier, {matches, remaining} ->
        found = lookup(tier, remaining, organization_id, gtfs_version_id)
        {Map.merge(matches, found), Enum.reject(remaining, &Map.has_key?(found, &1))}
      end)

    matches
  end

  defp lookup(_tier, [], _organization_id, _gtfs_version_id), do: %{}

  defp lookup(tier, lines, organization_id, gtfs_version_id) do
    organization_id
    |> scoped(gtfs_version_id)
    |> tier_query(tier, lines)
    |> Repo.all()
    |> Enum.group_by(fn {line, _stop} -> line end, fn {_line, stop} -> summary(stop) end)
    |> Map.new(fn {line, stops} -> {line, {tier, Enum.sort_by(stops, & &1.stop_id)}} end)
  end

  defp scoped(organization_id, gtfs_version_id) do
    from(stop in Stop,
      where: stop.organization_id == ^organization_id and stop.gtfs_version_id == ^gtfs_version_id
    )
  end

  defp tier_query(query, :stop_id, lines),
    do: from(stop in query, where: stop.stop_id in ^lines, select: {stop.stop_id, stop})

  defp tier_query(query, :stop_code, lines),
    do: from(stop in query, where: stop.stop_code in ^lines, select: {stop.stop_code, stop})

  defp tier_query(query, :stop_name, lines) do
    from(stop in query,
      where: fragment("btrim(?)", stop.stop_name) in ^lines,
      select: {fragment("btrim(?)", stop.stop_name), stop}
    )
  end

  defp summary(stop) do
    %{
      uuid: stop.id,
      stop_id: stop.stop_id,
      stop_name: stop.stop_name,
      stop_code: stop.stop_code,
      location_type: stop.location_type,
      parent_station: stop.parent_station
    }
  end

  defp assemble(lines, matches) do
    {resolved, ambiguous, unresolved} =
      Enum.reduce(lines, {[], [], []}, fn line, {resolved, ambiguous, unresolved} ->
        case Map.get(matches, line) do
          nil ->
            {resolved, ambiguous, [line | unresolved]}

          {basis, [stop]} ->
            {[{line, basis, stop} | resolved], ambiguous, unresolved}

          {basis, stops} ->
            row = %{
              ref: line,
              basis: basis,
              candidates: Enum.take(stops, @max_candidates),
              candidate_total: length(stops)
            }

            {resolved, [row | ambiguous], unresolved}
        end
      end)

    %{
      resolved: collapse(Enum.reverse(resolved)),
      ambiguous: Enum.reverse(ambiguous),
      unresolved: Enum.reverse(unresolved)
    }
  end

  # Several lines that name one stop are one match listing all its lines, in input order.
  defp collapse(resolved) do
    {order, by_uuid} =
      Enum.reduce(resolved, {[], %{}}, fn {line, basis, stop}, {order, by_uuid} ->
        case by_uuid do
          %{} when is_map_key(by_uuid, stop.uuid) ->
            {order, Map.update!(by_uuid, stop.uuid, &%{&1 | refs: &1.refs ++ [line]})}

          _first_line ->
            {[stop.uuid | order],
             Map.put(by_uuid, stop.uuid, %{refs: [line], basis: basis, stop: stop})}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(by_uuid, &1))
  end
end
