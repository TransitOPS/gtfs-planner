defmodule GtfsPlanner.Gtfs do
  @moduledoc """
  The Gtfs context.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop

  require Logger

  @doc """
  Returns the list of routes for an organization and GTFS version.

  Accepts optional filters, search, sort, and pagination via opts keyword list.

  ## Examples

      iex> list_routes(organization_id, gtfs_version_id)
      [%Route{}, ...]

      iex> list_routes(organization_id, gtfs_version_id, route_type: 3, search: "express")
      [%Route{}, ...]
  """
  def list_routes(organization_id, gtfs_version_id, opts \\ []) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id
    )
    |> maybe_filter_type(opts[:route_type])
    |> maybe_filter_agency(opts[:agency_id])
    |> maybe_filter_active(opts[:active])
    |> maybe_search(opts[:search])
    |> apply_sort(opts[:sort_by], opts[:sort_dir])
    |> paginate(opts[:page], opts[:per_page])
    |> Repo.all()
  end

  @doc """
  Returns the count of routes for an organization and GTFS version.

  Accepts optional filters via opts keyword list.

  ## Examples

      iex> count_routes(organization_id, gtfs_version_id)
      42

      iex> count_routes(organization_id, gtfs_version_id, route_type: 3)
      15
  """
  def count_routes(organization_id, gtfs_version_id, opts \\ []) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id
    )
    |> maybe_filter_type(opts[:route_type])
    |> maybe_filter_agency(opts[:agency_id])
    |> maybe_filter_active(opts[:active])
    |> Repo.aggregate(:count)
  end

  @doc """
  Gets a single route.

  Raises `Ecto.NoResultsError` if the Route does not exist.

  ## Examples

      iex> get_route!(id)
      %Route{}

      iex> get_route!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_route!(id), do: Repo.get!(Route, id)

  @doc """
  Gets a route by its route_id within an organization and GTFS version.

  Returns nil if the route does not exist.

  ## Examples

      iex> get_route_by_route_id(organization_id, gtfs_version_id, "R1")
      %Route{}

      iex> get_route_by_route_id(organization_id, gtfs_version_id, "nonexistent")
      nil
  """
  def get_route_by_route_id(organization_id, gtfs_version_id, route_id) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.route_id == ^route_id
    )
    |> Repo.one()
  end

  @doc """
  Creates a route.

  ## Examples

      iex> create_route(%{organization_id: org_id, gtfs_version_id: version_id, route_id: "R1", route_type: 3, route_short_name: "1"})
      {:ok, %Route{}}

      iex> create_route(%{route_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_route(attrs \\ %{}) do
    %Route{}
    |> Route.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a list of distinct route types for an organization and GTFS version.

  ## Examples

      iex> list_distinct_route_types(organization_id, gtfs_version_id)
      [0, 1, 3]
  """
  def list_distinct_route_types(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      distinct: true,
      select: r.route_type,
      order_by: r.route_type
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of distinct agency IDs for an organization and GTFS version.

  ## Examples

      iex> list_distinct_agencies(organization_id, gtfs_version_id)
      ["agency1", "agency2"]
  """
  def list_distinct_agencies(organization_id, gtfs_version_id) do
    from(r in Route,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          not is_nil(r.agency_id),
      distinct: true,
      select: r.agency_id,
      order_by: r.agency_id
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of levels for an organization and GTFS version.

  ## Examples

      iex> list_levels(organization_id, gtfs_version_id)
      [%Level{}, ...]
  """
  def list_levels(organization_id, gtfs_version_id) do
    from(l in Level,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: l.level_index]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single level.

  Returns nil if the Level does not exist.

  ## Examples

      iex> get_level(id)
      %Level{}

      iex> get_level(Ecto.UUID.generate())
      nil
  """
  def get_level(id), do: Repo.get(Level, id)

  @doc """
  Gets a single level.

  Raises `Ecto.NoResultsError` if the Level does not exist.

  ## Examples

      iex> get_level!(id)
      %Level{}

      iex> get_level!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_level!(id), do: Repo.get!(Level, id)

  @doc """
  Gets a level by its level_id within an organization and GTFS version.

  Returns nil if the level does not exist.

  ## Examples

      iex> get_level_by_level_id(organization_id, gtfs_version_id, "L1")
      %Level{}

      iex> get_level_by_level_id(organization_id, gtfs_version_id, "nonexistent")
      nil
  """
  def get_level_by_level_id(organization_id, gtfs_version_id, level_id) do
    from(l in Level,
      where:
        l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id and
          l.level_id == ^level_id
    )
    |> Repo.one()
  end

  @doc """
  Creates a level.

  ## Examples

      iex> create_level(%{organization_id: org_id, gtfs_version_id: version_id, level_id: "L1", level_index: 0.0})
      {:ok, %Level{}}

      iex> create_level(%{level_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_level(attrs \\ %{}) do
    %Level{}
    |> Level.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:levels, :created])
  end

  @doc """
  Updates a level.

  ## Examples

      iex> update_level(level, %{level_name: "Ground Floor"})
      {:ok, %Level{}}

      iex> update_level(level, %{level_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_level(%Level{} = level, attrs) do
    level
    |> Level.changeset(attrs)
    |> Repo.update()
    |> broadcast([:levels, :updated])
  end

  @doc """
  Updates a level's diagram filename.

  ## Examples

      iex> update_level_diagram(level, "floor_plan.png")
      {:ok, %Level{}}

      iex> update_level_diagram(level, nil)
      {:ok, %Level{}}
  """
  def update_level_diagram(%Level{} = level, filename) do
    level
    |> Level.changeset(%{diagram_filename: filename})
    |> Repo.update()
    |> broadcast([:levels, :updated])
  end

  @doc """
  Deletes a level.

  ## Examples

      iex> delete_level(level)
      {:ok, %Level{}}

      iex> delete_level(level)
      {:error, %Ecto.Changeset{}}
  """
  def delete_level(%Level{} = level) do
    Repo.delete(level)
    |> broadcast([:levels, :deleted])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking level changes.

  ## Examples

      iex> change_level(level)
      %Ecto.Changeset{data: %Level{}}
  """
  def change_level(%Level{} = level, attrs \\ %{}) do
    Level.changeset(level, attrs)
  end

  @doc """
  Returns the list of stops for an organization and GTFS version.

  ## Examples

      iex> list_stops(organization_id, gtfs_version_id)
      [%Stop{}, ...]
  """
  def list_stops(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.stop_name]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of stations (stops with no parent) for an organization and GTFS version.

  ## Examples

      iex> list_stations(organization_id, gtfs_version_id)
      [%Stop{}, ...]
  """
  def list_stations(organization_id, gtfs_version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          is_nil(s.parent_station_id),
      order_by: [asc: s.stop_name]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single stop.

  Returns nil if the Stop does not exist.

  ## Examples

      iex> get_stop(id)
      %Stop{}

      iex> get_stop(Ecto.UUID.generate())
      nil
  """
  def get_stop(id), do: Repo.get(Stop, id)

  @doc """
  Gets a single stop.

  Raises `Ecto.NoResultsError` if the Stop does not exist.

  ## Examples

      iex> get_stop!(id)
      %Stop{}

      iex> get_stop!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_stop!(id), do: Repo.get!(Stop, id)

  @doc """
  Gets a stop by its stop_id within an organization and GTFS version.

  Returns nil if the stop does not exist.

  ## Examples

      iex> get_stop_by_stop_id(organization_id, gtfs_version_id, "stop_123")
      %Stop{}

      iex> get_stop_by_stop_id(organization_id, gtfs_version_id, "nonexistent")
      nil
  """
  def get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id == ^stop_id
    )
    |> Repo.one()
  end

  @doc """
  Creates a stop.

  ## Examples

      iex> create_stop(%{organization_id: org_id, gtfs_version_id: version_id, stop_id: "stop_123", stop_name: "Central Station"})
      {:ok, %Stop{}}

      iex> create_stop(%{stop_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_stop(attrs \\ %{}) do
    %Stop{}
    |> Stop.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:stops, :created])
  end

  @doc """
  Updates a stop.

  ## Examples

      iex> update_stop(stop, %{stop_name: "Updated Station Name"})
      {:ok, %Stop{}}

      iex> update_stop(stop, %{stop_id: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_stop(%Stop{} = stop, attrs) do
    stop
    |> Stop.changeset(attrs)
    |> Repo.update()
    |> broadcast([:stops, :updated])
  end

  @doc """
  Deletes a stop.

  ## Examples

      iex> delete_stop(stop)
      {:ok, %Stop{}}

      iex> delete_stop(stop)
      {:error, %Ecto.Changeset{}}
  """
  def delete_stop(%Stop{} = stop) do
    Repo.delete(stop)
    |> broadcast([:stops, :deleted])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking stop changes.

  ## Examples

      iex> change_stop(stop)
      %Ecto.Changeset{data: %Stop{}}
  """
  def change_stop(%Stop{} = stop, attrs \\ %{}) do
    Stop.changeset(stop, attrs)
  end

  @doc """
  Returns child stops for a parent station, preloading level association.

  ## Examples

      iex> list_child_stops_for_parent(org_id, version_id, parent_id)
      [%Stop{level: %Level{}}, ...]
  """
  def list_child_stops_for_parent(organization_id, gtfs_version_id, parent_station_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          s.parent_station_id == ^parent_station_id,
      order_by: [asc: s.stop_name],
      preload: [:level]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of levels for a specific station.

  ## Examples

      iex> list_levels_for_station(organization_id, gtfs_version_id, parent_station_id)
      [%Level{}, ...]
  """
  def list_levels_for_station(organization_id, gtfs_version_id, parent_station_id) do
    from(l in Level,
      where:
        l.organization_id == ^organization_id and
          l.gtfs_version_id == ^gtfs_version_id and
          l.parent_station_id == ^parent_station_id,
      order_by: [asc: l.level_index]
    )
    |> Repo.all()
  end

  @doc """
  Updates a stop's diagram coordinate.

  ## Examples

      iex> update_stop_diagram_coordinate(stop, %{x: 50.5, y: 25.0})
      {:ok, %Stop{}}
  """
  def update_stop_diagram_coordinate(%Stop{} = stop, %{x: _, y: _} = coordinate) do
    stop
    |> Stop.changeset(%{diagram_coordinate: coordinate})
    |> Repo.update()
    |> broadcast([:stops, :updated])
  end

  @doc """
  Returns child stops for a parent station filtered by level.

  ## Examples

      iex> list_child_stops_for_level(parent_station_id, level_id)
      [%Stop{}, ...]
  """
  def list_child_stops_for_level(parent_station_id, level_id) do
    from(s in Stop,
      where: s.parent_station_id == ^parent_station_id and s.level_id == ^level_id,
      order_by: [asc: s.stop_name]
    )
    |> Repo.all()
  end

  @doc """
  Returns pathways where both from_stop and to_stop have the specified level_id
  and belong to the specified parent station.

  ## Examples

      iex> list_pathways_for_level(org_id, version_id, level_id, parent_station_id)
      [%Pathway{from_stop: %Stop{}, to_stop: %Stop{}}, ...]
  """
  def list_pathways_for_level(organization_id, gtfs_version_id, level_id, parent_station_id) do
    from(p in Pathway,
      join: from_stop in Stop,
      on: p.from_stop_id == from_stop.id,
      join: to_stop in Stop,
      on: p.to_stop_id == to_stop.id,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          from_stop.level_id == ^level_id and
          to_stop.level_id == ^level_id and
          from_stop.parent_station_id == ^parent_station_id and
          to_stop.parent_station_id == ^parent_station_id,
      order_by: [asc: p.pathway_id],
      preload: [:from_stop, :to_stop]
    )
    |> Repo.all()
  end

  @doc """
  Returns pathways where from_stop or to_stop is a child of the given station.

  ## Examples

      iex> list_pathways_for_station(org_id, version_id, parent_id)
      [%Pathway{from_stop: %Stop{}, to_stop: %Stop{}}, ...]
  """
  def list_pathways_for_station(organization_id, gtfs_version_id, parent_station_id) do
    child_stop_ids =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.parent_station_id == ^parent_station_id,
        select: s.id
      )

    from(p in Pathway,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (p.from_stop_id in subquery(child_stop_ids) or
             p.to_stop_id in subquery(child_stop_ids)),
      order_by: [asc: p.pathway_id],
      preload: [:from_stop, :to_stop]
    )
    |> Repo.all()
  end

  def list_pathways(organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: p.pathway_id]
    )
    |> Repo.all()
  end

  @doc """
  Creates a pathway.

  ## Examples

      iex> create_pathway(%{pathway_id: "P1", pathway_mode: 1, ...})
      {:ok, %Pathway{}}
  """
  def create_pathway(attrs \\ %{}) do
    %Pathway{}
    |> Pathway.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:pathways, :created])
  end

  @doc """
  Gets a single pathway.

  Raises `Ecto.NoResultsError` if the Pathway does not exist.

  ## Examples

      iex> get_pathway!(id)
      %Pathway{}

      iex> get_pathway!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_pathway!(id), do: Repo.get!(Pathway, id)

  @doc """
  Gets a single pathway with preloaded from_stop and to_stop associations.

  Raises `Ecto.NoResultsError` if the Pathway does not exist.

  ## Examples

      iex> get_pathway_with_stops!(id)
      %Pathway{from_stop: %Stop{}, to_stop: %Stop{}}

      iex> get_pathway_with_stops!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_pathway_with_stops!(id) do
    Repo.get!(Pathway, id) |> Repo.preload([:from_stop, :to_stop])
  end

  @doc """
  Updates a pathway.

  ## Examples

      iex> update_pathway(pathway, %{pathway_mode: 2})
      {:ok, %Pathway{}}

      iex> update_pathway(pathway, %{pathway_mode: nil})
      {:error, %Ecto.Changeset{}}
  """
  def update_pathway(%Pathway{} = pathway, attrs) do
    pathway
    |> Pathway.changeset(attrs)
    |> Repo.update()
    |> broadcast([:pathways, :updated])
  end

  @doc """
  Deletes a pathway.

  ## Examples

      iex> delete_pathway(pathway)
      {:ok, %Pathway{}}

      iex> delete_pathway(pathway)
      {:error, %Ecto.Changeset{}}
  """
  def delete_pathway(%Pathway{} = pathway) do
    Repo.delete(pathway)
    |> broadcast([:pathways, :deleted])
  end

  # Private helper functions

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, ""), do: query

  defp maybe_filter_type(query, route_type) do
    where(query, [r], r.route_type == ^route_type)
  end

  defp maybe_filter_agency(query, nil), do: query
  defp maybe_filter_agency(query, ""), do: query

  defp maybe_filter_agency(query, agency_id) do
    where(query, [r], r.agency_id == ^agency_id)
  end

  defp maybe_filter_active(query, nil), do: query
  defp maybe_filter_active(query, "all"), do: query
  defp maybe_filter_active(query, ""), do: query

  defp maybe_filter_active(query, "true") do
    where(query, [r], r.active == true)
  end

  defp maybe_filter_active(query, "false") do
    where(query, [r], r.active == false)
  end

  defp maybe_search(query, nil), do: query
  defp maybe_search(query, ""), do: query

  defp maybe_search(query, term) do
    search_pattern = "%#{term}%"

    where(
      query,
      [r],
      ilike(r.route_id, ^search_pattern) or
        ilike(r.route_short_name, ^search_pattern) or
        ilike(r.route_long_name, ^search_pattern)
    )
  end

  defp apply_sort(query, nil, _sort_dir), do: order_by(query, [r], asc: r.route_id)
  defp apply_sort(query, _sort_by, nil), do: order_by(query, [r], asc: r.route_id)

  defp apply_sort(query, sort_by, sort_dir)
       when sort_by in [:route_id, :route_short_name, :route_long_name, :route_type, :active] and
              sort_dir in [:asc, :desc] do
    order_by(query, [r], [{^sort_dir, field(r, ^sort_by)}])
  end

  defp apply_sort(query, _sort_by, _sort_dir), do: order_by(query, [r], asc: r.route_id)

  defp paginate(query, nil, _per_page), do: paginate(query, 1, 25)
  defp paginate(query, _page, nil), do: paginate(query, 1, 25)

  defp paginate(query, page, per_page) when is_integer(page) and is_integer(per_page) do
    offset = (page - 1) * per_page
    query |> limit(^per_page) |> offset(^offset)
  end

  defp paginate(query, _page, _per_page), do: paginate(query, 1, 25)

  defp broadcast({:ok, result}, event_topic) do
    broadcast_result =
      case event_topic do
        [:levels, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "levels", {event_topic, result})

        [:stops, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "stops", {event_topic, result})

        [:pathways, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "pathways", {event_topic, result})
      end

    case broadcast_result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to broadcast #{inspect(event_topic)} event: #{inspect(reason)}")
    end

    {:ok, result}
  end

  defp broadcast({:error, reason}, _event_topic) do
    {:error, reason}
  end
end