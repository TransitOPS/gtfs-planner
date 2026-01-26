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

  # Determines appropriate ordering for GTFS output based on schema
  defp order_by_for_schema(query, schema) do
    cond do
      # StopTime must be ordered by trip_id, then stop_sequence
      schema == GtfsPlanner.Gtfs.StopTime ->
        order_by(query, [s], [asc: s.trip_id, asc: s.stop_sequence])

      # Shape must be ordered by shape_id, then shape_pt_sequence
      schema == GtfsPlanner.Gtfs.Shape ->
        order_by(query, [s], [asc: s.shape_id, asc: s.shape_pt_sequence])

      # Most schemas can be ordered by their primary GTFS ID field
      # This provides deterministic output
      has_field?(schema, :stop_id) ->
        order_by(query, [s], asc: s.stop_id)

      has_field?(schema, :route_id) ->
        order_by(query, [s], asc: s.route_id)

      has_field?(schema, :trip_id) ->
        order_by(query, [s], asc: s.trip_id)

      has_field?(schema, :agency_id) ->
        order_by(query, [s], asc: s.agency_id)

      has_field?(schema, :service_id) ->
        order_by(query, [s], asc: s.service_id)

      has_field?(schema, :fare_id) ->
        order_by(query, [s], asc: s.fare_id)

      has_field?(schema, :pathway_id) ->
        order_by(query, [s], asc: s.pathway_id)

      has_field?(schema, :level_id) ->
        order_by(query, [s], asc: s.level_id)

      has_field?(schema, :attribution_id) ->
        order_by(query, [s], asc: s.attribution_id)

      # Default: order by inserted_at for consistent output when timestamps are present
      has_field?(schema, :inserted_at) ->
        order_by(query, [s], asc: s.inserted_at)

      # Fallback: order by primary key id if available
      has_field?(schema, :id) ->
        order_by(query, [s], asc: s.id)

      # Final fallback: leave query order unchanged if no known ordering field exists
      true ->
        query
    end
  end

  # Check if schema has a field
  defp has_field?(schema, field_name) do
    field_name in schema.__schema__(:fields)
  end
end