defmodule GtfsPlanner.Gtfs do
  @moduledoc """
  The Gtfs context.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Stop

  require Logger

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
  Returns levels used by child stops of a station.

  ## Examples

      iex> list_levels_for_station(org_id, version_id, parent_id)
      [%{level: %Level{}, stop_count: 3}, ...]
  """
  def list_levels_for_station(organization_id, gtfs_version_id, parent_station_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          s.parent_station_id == ^parent_station_id and
          not is_nil(s.level_id),
      join: l in Level,
      on: l.id == s.level_id,
      group_by: [l.id, l.level_id, l.level_name, l.level_index],
      select: %{
        level: l,
        stop_count: count(s.id)
      },
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