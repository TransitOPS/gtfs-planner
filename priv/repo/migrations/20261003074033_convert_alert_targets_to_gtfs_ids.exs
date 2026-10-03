defmodule GtfsPlanner.Repo.Migrations.ConvertAlertTargetsToGtfsIds do
  use Ecto.Migration

  @moduledoc """
  Stores the exact GTFS feed ID of each route, stop and trip an alert targets,
  instead of the `routes.id`, `stops.id` or `trips.id` row UUID.

  Only the private authoring data changes: the `scope` answer (`route_ids`,
  `stop_ids`, the stretch ends, the boarding alternative, route/stop pairs and
  cancelled trips) and the `target_reference` capture (entry and unresolved keys).
  A trip keeps its `service_date` and `start_time`. Accepted and confirmed public
  snapshots in `alert_publications` already hold feed IDs and are not read or
  written, and no revision, timestamp or source version moves.

  A legacy value resolves, in order, from the alert's own trusted capture (the
  GTFS ID it was captured with) and from the row the UUID names inside the
  alert's organization and source version. The two must agree when both exist.
  The migration runs in one transaction under table locks, resolves every
  reference before writing anything, and refuses when one cannot be resolved
  (an unknown UUID, a deleted source version or a target the version no longer
  holds) or when the capture and the row disagree. The error names each alert,
  field and value so the row can be corrected; nothing is guessed or dropped.

  `scope_digest` is removed from a converted capture: it hashes the answer with
  the old UUIDs, nothing reads it, and recomputing it here would copy the
  application's algorithm into a frozen migration.

  `down` resolves each feed ID back to the row UUID of the scoped entity and
  refuses when any is missing, because a UUID cannot be reconstructed otherwise.
  The removed digest is not restored.
  """

  # Where each kind of target lives: the table and the column that holds its feed ID.
  @tables %{
    route: {"routes", "route_id"},
    stop: {"stops", "stop_id"},
    trip: {"trips", "trip_id"}
  }

  # Every place a target identity is stored. `:list` is an array of IDs, `:value`
  # a single ID, `:entries` an array of maps whose listed keys hold IDs.
  @scope_specs [
    {"route_ids", {:list, :route}},
    {"stop_ids", {:list, :stop}},
    {"stretch_from_stop_id", {:value, :stop}},
    {"stretch_to_stop_id", {:value, :stop}},
    {"alternative_stop_id", {:value, :stop}},
    {"route_stop_pairs", {:entries, [{"route_id", :route}, {"stop_id", :stop}]}},
    {"trips", {:entries, [{"trip_id", :trip}]}}
  ]

  @capture_specs [
    {"routes", {:entries, [{"id", :route}]}},
    {"stops", {:entries, [{"id", :stop}]}},
    {"unresolved_routes", {:list, :route}},
    {"unresolved_stops", {:list, :stop}},
    {"route_stops", {:entries, [{"route_id", :route}, {"stop_id", :stop}]}},
    {"trips", {:entries, [{"id", :trip}]}}
  ]

  def up, do: convert(:up, "alert targets could not be converted to GTFS IDs")

  def down do
    convert(
      :down,
      "alert targets cannot be restored to row UUIDs because their scoped row is missing"
    )
  end

  defp convert(direction, failure) do
    lock_tables()

    plans = Enum.map(load_alerts(), &plan(direction, &1))

    case Enum.flat_map(plans, & &1.errors) do
      [] ->
        Enum.each(plans, &write/1)

      errors ->
        raise Ecto.MigrationError, message: failure <> ":\n" <> Enum.join(errors, "\n")
    end
  end

  # Writers are held out between the checks and the writes, so no target can be
  # renamed, deleted or retargeted in between.
  defp lock_tables do
    repo().query!("""
    LOCK TABLE #{qualified(:service_alerts)}, #{qualified(:routes)},
      #{qualified(:stops)}, #{qualified(:trips)}
    IN SHARE ROW EXCLUSIVE MODE
    """)
  end

  defp load_alerts do
    %{rows: rows} =
      repo().query!("""
      SELECT id, organization_id, source_gtfs_version_id, scope, target_reference
      FROM #{qualified(:service_alerts)}
      ORDER BY id
      """)

    for [id, organization_id, version_id, scope, reference] <- rows do
      %{
        id: id,
        organization_id: organization_id,
        version_id: version_id,
        scope: scope,
        reference: reference
      }
    end
  end

  # Resolves every reference of one alert, then rewrites it. A plan with errors
  # is never written.
  defp plan(direction, alert) do
    refs = target_refs(alert)
    rows = scoped_rows(direction, alert, refs)
    captured = if direction == :up, do: capture_map(alert.reference), else: %{}

    resolved =
      Map.new(refs, fn {kind, value, _field} ->
        {{kind, value}, resolve(direction, kind, value, captured, rows)}
      end)

    errors =
      for {kind, value, field} <- refs,
          {:error, reason} <- [Map.fetch!(resolved, {kind, value})] do
        "  service_alerts id=#{Ecto.UUID.load!(alert.id)} " <>
          "organization_id=#{Ecto.UUID.load!(alert.organization_id)} " <>
          "field=#{field} value=#{inspect(value)} reason=#{reason}"
      end

    if errors == [] do
      converted = fn kind, value, _field, acc ->
        {:ok, new} = Map.fetch!(resolved, {kind, value})
        {new, acc}
      end

      {scope, reference, _acc} = rewrite(alert, converted, [])

      %{alert: alert, errors: [], scope: scope, reference: drop_digest(reference, refs)}
    else
      %{alert: alert, errors: errors}
    end
  end

  defp write(%{errors: [_ | _]}), do: :ok

  defp write(%{alert: alert, scope: scope, reference: reference}) do
    if scope != alert.scope or reference != alert.reference do
      repo().query!(
        "UPDATE #{qualified(:service_alerts)} SET scope = $2, target_reference = $3 WHERE id = $1",
        [alert.id, scope, reference]
      )
    end
  end

  # The digest describes the answer with its old identities, so it is stale as
  # soon as one is converted.
  defp drop_digest(reference, []), do: reference
  defp drop_digest(reference, _refs), do: Map.delete(reference, "scope_digest")

  # -- Targets --------------------------------------------------------------

  defp target_refs(alert) do
    {_scope, _reference, refs} =
      rewrite(
        alert,
        fn kind, value, field, acc -> {value, [{kind, value, field} | acc]} end,
        []
      )

    Enum.reverse(refs)
  end

  defp rewrite(alert, fun, acc) do
    {scope, acc} = walk(alert.scope, @scope_specs, "scope", fun, acc)

    {reference, acc} =
      case alert.reference do
        %{"selectors" => %{} = selectors} = reference ->
          {selectors, acc} =
            walk(selectors, @capture_specs, "target_reference.selectors", fun, acc)

          {Map.put(reference, "selectors", selectors), acc}

        reference ->
          {reference, acc}
      end

    {scope, reference, acc}
  end

  defp walk(map, specs, prefix, fun, acc) when is_map(map) do
    Enum.reduce(specs, {map, acc}, fn {key, spec}, {current, acc} ->
      case Map.fetch(current, key) do
        {:ok, value} ->
          {value, acc} = walk_value(value, spec, "#{prefix}.#{key}", fun, acc)
          {Map.put(current, key, value), acc}

        :error ->
          {current, acc}
      end
    end)
  end

  defp walk(other, _specs, _prefix, _fun, acc), do: {other, acc}

  defp walk_value(list, {:list, kind}, field, fun, acc) when is_list(list),
    do: Enum.map_reduce(list, acc, &visit(kind, &1, field, fun, &2))

  defp walk_value(value, {:value, kind}, field, fun, acc),
    do: visit(kind, value, field, fun, acc)

  defp walk_value(list, {:entries, keys}, field, fun, acc) when is_list(list) do
    Enum.map_reduce(list, acc, fn
      %{} = entry, acc ->
        Enum.reduce(keys, {entry, acc}, fn {key, kind}, {entry, acc} ->
          case Map.fetch(entry, key) do
            {:ok, value} ->
              {value, acc} = visit(kind, value, "#{field}.#{key}", fun, acc)
              {Map.put(entry, key, value), acc}

            :error ->
              {entry, acc}
          end
        end)

      other, acc ->
        {other, acc}
    end)
  end

  defp walk_value(other, _spec, _field, _fun, acc), do: {other, acc}

  defp visit(_kind, nil, _field, _fun, acc), do: {nil, acc}
  defp visit(kind, value, field, fun, acc), do: fun.(kind, value, field, acc)

  # -- Resolution -----------------------------------------------------------

  # Up, a legacy UUID resolves from the alert's capture and from the scoped row;
  # when both name a GTFS ID they must be the same one. Down, a feed ID resolves
  # only through the scoped row.
  defp resolve(:up, kind, value, captured, rows) do
    uuid = canonical_uuid(value)
    from_capture = uuid && Map.get(captured, {kind, uuid})
    from_row = uuid && get_in(rows, [kind, uuid])

    cond do
      is_nil(uuid) -> {:error, :unresolved}
      from_capture == :conflict -> {:error, :contradictory}
      from_capture && from_row && from_capture != from_row -> {:error, :contradictory}
      from_capture -> {:ok, from_capture}
      from_row -> {:ok, from_row}
      true -> {:error, :unresolved}
    end
  end

  defp resolve(:down, kind, value, _captured, rows) do
    case get_in(rows, [kind, value]) do
      nil -> {:error, :unresolved}
      uuid -> {:ok, uuid}
    end
  end

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp canonical_uuid(_value), do: nil

  # The GTFS ID the capture recorded for each legacy UUID, or `:conflict` when
  # its entries name more than one.
  defp capture_map(%{"selectors" => %{} = selectors}) do
    [
      captured_pairs(selectors["routes"], "id", "gtfs_id", :route),
      captured_pairs(selectors["stops"], "id", "gtfs_id", :stop),
      captured_pairs(selectors["route_stops"], "route_id", "route_gtfs_id", :route),
      captured_pairs(selectors["route_stops"], "stop_id", "stop_gtfs_id", :stop),
      captured_pairs(selectors["trips"], "id", "gtfs_id", :trip)
    ]
    |> Enum.concat()
    |> Enum.reduce(%{}, fn {key, gtfs_id}, acc ->
      Map.update(acc, key, gtfs_id, &if(&1 == gtfs_id, do: &1, else: :conflict))
    end)
  end

  defp capture_map(_reference), do: %{}

  defp captured_pairs(entries, id_key, gtfs_key, kind) when is_list(entries) do
    for %{} = entry <- entries,
        uuid = canonical_uuid(entry[id_key]),
        gtfs_id = entry[gtfs_key],
        is_binary(gtfs_id) and gtfs_id != "" do
      {{kind, uuid}, gtfs_id}
    end
  end

  defp captured_pairs(_entries, _id_key, _gtfs_key, _kind), do: []

  # The rows the alert's references name inside its own organization and source
  # version. An alert with no source version has none.
  defp scoped_rows(_direction, %{version_id: nil}, _refs), do: %{}

  defp scoped_rows(direction, alert, refs) do
    for {kind, {table, column}} <- @tables, into: %{} do
      values = for {^kind, value, _field} <- refs, do: value
      {kind, kind_rows(direction, alert, table, column, values)}
    end
  end

  defp kind_rows(:up, alert, table, column, values) do
    uuids = values |> Enum.map(&canonical_uuid/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    query_rows(
      alert,
      "SELECT id::text, #{column} FROM #{qualified(table)}",
      "id = ANY($3)",
      Enum.map(uuids, &Ecto.UUID.dump!/1)
    )
  end

  defp kind_rows(:down, alert, table, column, values) do
    query_rows(
      alert,
      "SELECT #{column}, id::text FROM #{qualified(table)}",
      "#{column} = ANY($3)",
      values |> Enum.filter(&is_binary/1) |> Enum.uniq()
    )
  end

  defp query_rows(_alert, _select, _match, []), do: %{}

  defp query_rows(alert, select, match, keys) do
    %{rows: rows} =
      repo().query!(
        "#{select} WHERE organization_id = $1 AND gtfs_version_id = $2 AND #{match}",
        [alert.organization_id, alert.version_id, keys]
      )

    Map.new(rows, fn [key, value] -> {key, value} end)
  end

  defp qualified(name) do
    case prefix() do
      nil -> to_string(name)
      schema -> ~s("#{String.replace(schema, "\"", "\"\"")}".#{name})
    end
  end
end
