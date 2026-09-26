defmodule GtfsPlanner.Gtfs.Export.StreamBuilder do
  @moduledoc """
  Builds Ecto streaming queries and lookup maps for GTFS export.

  All streams use batch processing with `max_rows: 1000` to avoid
  memory exhaustion when processing large datasets.
  """

  import Ecto.Query

  @doc """
  Streams records for the given schema filtered by organization and version.

  Returns an Ecto stream that fetches records in batches of 1000.

  ## Examples

      StreamBuilder.stream_records(Repo, Stop, org_id, version_id)
      |> Enum.each(fn stop -> ... end)
  """
  def stream_records(repo, schema, organization_id, gtfs_version_id) do
    schema
    |> where([s], s.organization_id == ^organization_id)
    |> where([s], s.gtfs_version_id == ^gtfs_version_id)
    |> order_by_for_schema(schema)
    |> repo.stream(max_rows: 1000)
  end

  @doc """
  Builds lookup map for stops: UUID → stop_id string.

  ## Examples

      build_stop_lookup(Repo, org_id, version_id)
      # => %{uuid1 => "STOP1", uuid2 => "STOP2", ...}
  """
  def build_stop_lookup(repo, organization_id, gtfs_version_id) do
    alias GtfsPlanner.Gtfs.Stop

    Stop
    |> where([s], s.organization_id == ^organization_id)
    |> where([s], s.gtfs_version_id == ^gtfs_version_id)
    |> select([s], {s.id, s.stop_id})
    |> repo.all()
    |> Map.new()
  end

  @doc """
  Builds lookup map for levels: UUID → level_id string.

  ## Examples

      build_level_lookup(Repo, org_id, version_id)
      # => %{uuid1 => "L1", uuid2 => "L2", ...}
  """
  def build_level_lookup(repo, organization_id, gtfs_version_id) do
    alias GtfsPlanner.Gtfs.Level

    Level
    |> where([l], l.organization_id == ^organization_id)
    |> where([l], l.gtfs_version_id == ^gtfs_version_id)
    |> select([l], {l.id, l.level_id})
    |> repo.all()
    |> Map.new()
  end

  # Primary GTFS ID fields in preference order, used when a schema needs a
  # deterministic single-field sort but has no multi-field identity such as a
  # trip's `stop_sequence` or a route pattern's `route_pattern_id`.
  @ordering_fields [
    :stop_id,
    :route_id,
    :trip_id,
    :agency_id,
    :service_id,
    :fare_id,
    :pathway_id,
    :level_id,
    :attribution_id,
    :inserted_at,
    :id
  ]

  # Determines appropriate ordering for GTFS output based on schema
  defp order_by_for_schema(query, GtfsPlanner.Gtfs.StopTime) do
    order_by(query, [s], asc: s.trip_id, asc: s.stop_sequence)
  end

  # Route patterns share a route_id, so the pattern identity breaks the tie
  defp order_by_for_schema(query, GtfsPlanner.Gtfs.RoutePattern) do
    order_by(query, [s], asc: s.route_id, asc: s.route_pattern_id)
  end

  defp order_by_for_schema(query, GtfsPlanner.Gtfs.Shape) do
    order_by(query, [s], asc: s.shape_id, asc: s.shape_pt_sequence)
  end

  defp order_by_for_schema(query, schema) do
    case Enum.find(@ordering_fields, &has_field?(schema, &1)) do
      nil -> query
      field -> order_by(query, [s], asc: field(s, ^field))
    end
  end

  # Check if schema has a field
  defp has_field?(schema, field_name) do
    field_name in schema.__schema__(:fields)
  end
end
