defmodule GtfsPlanner.Gtfs do
  @moduledoc """
  The Gtfs context.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AlignmentInference
  alias GtfsPlanner.Gtfs.Area
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.BookingRule
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Coordinates
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareLegJoinRule
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.FeedInfo
  alias GtfsPlanner.Gtfs.FloorplanTransform
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.JournalPhoto
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Location
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.StationEditingStatus
  alias GtfsPlanner.Gtfs.StationNaming
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Timeframe
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Validations.WalkabilityTest

  require Logger

  @type list_stations_opts :: [
          route_id: String.t() | nil,
          direction_id: integer() | nil,
          wheelchair_boarding: integer() | String.t() | nil,
          search: String.t() | nil,
          sort_by: atom() | nil,
          sort_dir: :asc | :desc | nil,
          page: pos_integer() | nil,
          per_page: pos_integer() | nil,
          location_type: 0 | 1 | 2 | 3 | 4 | String.t() | nil
        ]

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
    |> maybe_search(opts[:search])
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
  Returns the list of route patterns for a specific route.

  ## Examples

      iex> list_route_patterns_for_route(organization_id, gtfs_version_id, route_id)
      [%RoutePattern{}, ...]
  """
  def list_route_patterns_for_route(organization_id, gtfs_version_id, route_id) do
    from(rp in RoutePattern,
      where:
        rp.organization_id == ^organization_id and rp.gtfs_version_id == ^gtfs_version_id and
          rp.route_id == ^route_id,
      order_by: [asc: rp.direction_id, asc: rp.route_pattern_sort_order]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of levels for an organization and GTFS version.
  """
  def count_levels(organization_id, gtfs_version_id) do
    from(l in Level,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
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
  Returns all levels for organization and GTFS version.
  """
  def list_all_levels(organization_id, gtfs_version_id) do
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
  Updates a level, cascading level_id changes to all referencing entities
  within the same organization and GTFS version.

  When level_id is unchanged, delegates to update_level/2.
  """
  def update_level_with_cascade(%Level{} = level, attrs) do
    new_level_id = attrs[:level_id] || attrs["level_id"]

    if new_level_id == level.level_id or is_nil(new_level_id) do
      update_level(level, attrs)
    else
      mapping = %{level.level_id => new_level_id}
      now = DateTime.utc_now()

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:update_level, fn _repo, _changes ->
          level
          |> Level.changeset(attrs)
          |> Repo.update()
        end)
        |> Ecto.Multi.run(:cascade_references, fn repo, _changes ->
          {:ok,
           update_level_id_references(
             repo,
             mapping,
             level.organization_id,
             level.gtfs_version_id,
             now
           )}
        end)

      case Repo.transaction(multi) do
        {:ok, %{update_level: updated_level}} ->
          broadcast({:ok, updated_level}, [:levels, :updated])

        {:error, :update_level, changeset, _changes} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes a stop_level association.
  """
  def delete_stop_level(%StopLevel{} = stop_level) do
    Repo.delete(stop_level)
    |> broadcast([:stop_levels, :deleted])
  end

  @doc """
  Updates a stop_level's diagram filename.
  """
  def update_stop_level_diagram(%StopLevel{} = stop_level, filename) do
    stop_level
    |> StopLevel.changeset(%{
      diagram_filename: filename,
      scale_point_a: nil,
      scale_point_b: nil,
      scale_distance_meters: nil,
      scale_meters_per_unit: nil
    })
    |> Repo.update()
    |> broadcast([:stop_levels, :updated])
  end

  @doc """
  Updates a stop_level's diagram calibration.
  """
  def update_stop_level_scale(%StopLevel{} = stop_level, attrs) do
    stop_level
    |> StopLevel.scale_changeset(attrs)
    |> Repo.update()
    |> broadcast([:stop_levels, :updated])
  end

  @doc """
  Updates a stop_level's floorplan alignment.
  """
  def update_stop_level_alignment(%StopLevel{} = stop_level, attrs) do
    stop_level
    |> StopLevel.alignment_changeset(attrs)
    |> Repo.update()
    |> broadcast([:stop_levels, :updated])
  end

  @doc """
  Saves a stop_level's floorplan alignment.
  """
  def save_stop_level_alignment(%StopLevel{} = stop_level, attrs) do
    stop_level
    |> StopLevel.alignment_changeset(attrs)
    |> Repo.update()
    |> broadcast([:stop_levels, :updated])
  end

  @doc """
  Clears a stop_level's floorplan alignment.
  """
  def clear_stop_level_alignment(%StopLevel{} = stop_level) do
    update_stop_level_alignment(stop_level, %{
      floorplan_center_lat: nil,
      floorplan_center_lon: nil,
      floorplan_scale_mpp: nil,
      floorplan_rotation_deg: nil
    })
  end

  @doc """
  Derives geographic coordinates for eligible child stops of a station level
  using its saved floorplan alignment.

  Eligible stops are those attached (directly or transitively) to the parent
  station, pinned to the active level, and having a `diagram_coordinate` that
  normalizes via `Coordinates.normalize_point/1`.

  Returns `{:ok, entries}` where each entry is a map with `:stop_id`,
  `:stop_name`, `:lat`, and `:lon`. Returns `{:error, :alignment_missing}` when
  any of the four alignment fields on the stop level are nil,
  `{:error, :invalid_image_dims}` when image dimensions are not positive
  integers, or `{:error, {:transform, reason}}` when the coordinate transform
  rejects an input.

  ## Examples

      iex> derive_child_stop_coords(stop_level, 1024, 768)
      {:ok, [%{stop_id: "...", stop_name: "Platform 1", lat: 40.7128, lon: -74.0060}]}
  """
  @spec derive_child_stop_coords(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok,
           [%{stop_id: Ecto.UUID.t(), stop_name: String.t() | nil, lat: float(), lon: float()}]}
          | {:error, :alignment_missing | :invalid_image_dims | {:transform, atom()}}
  def derive_child_stop_coords(%StopLevel{} = stop_level, image_w, image_h) do
    with {:ok, alignment} <- extract_alignment(stop_level),
         :ok <- validate_positive_image_dims(image_w, image_h) do
      stop_level.stop_id
      |> list_child_stops_for_level(stop_level.level_id)
      |> Enum.filter(& &1.on_active_level)
      |> Enum.reduce_while({:ok, []}, fn stop, {:ok, acc} ->
        case Coordinates.normalize_point(stop.diagram_coordinate) do
          nil ->
            {:cont, {:ok, acc}}

          %{x: x, y: y} ->
            case FloorplanTransform.svg_to_lat_lon(alignment, image_w, image_h, %{x: x, y: y}) do
              {:ok, {lat, lon}} ->
                entry = %{stop_id: stop.id, stop_name: stop.stop_name, lat: lat, lon: lon}
                {:cont, {:ok, [entry | acc]}}

              {:error, reason} ->
                {:halt, {:error, {:transform, reason}}}
            end
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _} = error -> error
      end
    end
  end

  defp extract_alignment(%StopLevel{} = stop_level) do
    case StopLevel.alignment_transform(stop_level) do
      {:ok, alignment} -> {:ok, alignment}
      {:error, :alignment_missing} -> {:error, :alignment_missing}
      {:error, :invalid_alignment} -> {:error, :alignment_missing}
    end
  end

  defp validate_positive_image_dims(w, h)
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: :ok

  defp validate_positive_image_dims(_, _), do: {:error, :invalid_image_dims}

  @doc """
  Saves floorplan alignment for an active stop_level and applies it to the
  active level child stops in a single transaction.

  Returns `{:ok, %{active_stop_level: stop_level, apply_result: result}}`
  on success, where `result` includes only active-level apply data.
  """
  @spec save_and_apply_stop_level_alignment(
          Ecto.UUID.t(),
          map(),
          pos_integer(),
          pos_integer()
        ) ::
          {:ok,
           %{
             active_stop_level: StopLevel.t(),
             apply_result: %{
               touched_stop_count: non_neg_integer()
             }
           }}
          | {:error,
             :not_found
             | :invalid_input
             | :alignment_missing
             | :invalid_image_dims
             | {:transform, atom()}
             | Ecto.Changeset.t()
             | term()}
  def save_and_apply_stop_level_alignment(
        active_stop_level_id,
        proposed_alignment_attrs,
        image_w,
        image_h
      )
      when is_binary(active_stop_level_id) and is_map(proposed_alignment_attrs) do
    Logger.debug(fn ->
      "[ALIGN_APPLY_DEBUG] start save_and_apply_stop_level_alignment " <>
        inspect(%{
          active_stop_level_id: active_stop_level_id,
          proposed_alignment_attrs: proposed_alignment_attrs,
          image_w: image_w,
          image_h: image_h
        })
    end)

    with :ok <- validate_positive_image_dims(image_w, image_h) do
      transaction_result =
        Repo.transaction(fn ->
          case load_stop_level_for_update(active_stop_level_id) do
            nil ->
              Repo.rollback(:not_found)

            %StopLevel{} = active_stop_level ->
              old_alignment_snapshot = stop_level_alignment_snapshot(active_stop_level)

              Logger.debug(fn ->
                "[ALIGN_APPLY_DEBUG] active_stop_level_loaded " <>
                  inspect(%{
                    active_stop_level_id: active_stop_level.id,
                    old_alignment_snapshot: old_alignment_snapshot
                  })
              end)

              with {:ok, updated_stop_level} <-
                     active_stop_level
                     |> StopLevel.alignment_changeset(proposed_alignment_attrs)
                     |> Repo.update(),
                   {:ok, active_derived} <-
                     derive_child_stop_coords(updated_stop_level, image_w, image_h),
                   {:ok, active_updated_stops} <- persist_derived_coords_in_tx(active_derived),
                   # Pins anchor on diagram coordinates like nodes; their lat/lon
                   # is optional enrichment re-imputed here whenever the level is
                   # (re)aligned, using the client-supplied image dims — never at
                   # sync time.
                   {:ok, active_derived_pins} <-
                     derive_pin_coords(updated_stop_level, image_w, image_h),
                   {:ok, _active_updated_pins} <-
                     persist_derived_pin_coords_in_tx(active_derived_pins) do
                Logger.debug(fn ->
                  "[ALIGN_APPLY_DEBUG] active_stop_level_persisted " <>
                    inspect(%{
                      active_stop_level_id: updated_stop_level.id,
                      updated_alignment_snapshot:
                        stop_level_alignment_snapshot(updated_stop_level)
                    })
                end)

                apply_result = %{
                  touched_stop_count: length(active_updated_stops)
                }

                %{
                  active_stop_level: updated_stop_level,
                  active_updated_stops: active_updated_stops,
                  apply_result: apply_result
                }
              else
                {:error, reason} ->
                  Logger.warning(fn ->
                    "[ALIGN_APPLY_DEBUG] transaction_rollback " <>
                      inspect(%{active_stop_level_id: active_stop_level.id, reason: reason})
                  end)

                  Repo.rollback(reason)
              end
          end
        end)

      case transaction_result do
        {:ok,
         %{
           active_stop_level: updated_stop_level,
           active_updated_stops: active_updated_stops,
           apply_result: apply_result
         }} ->
          broadcast({:ok, updated_stop_level}, [:stop_levels, :updated])

          Enum.each(active_updated_stops, fn stop ->
            broadcast({:ok, stop}, [:stops, :updated])
          end)

          {:ok,
           %{
             active_stop_level: updated_stop_level,
             apply_result: apply_result
           }}

        {:error, reason} ->
          Logger.warning(fn ->
            "[ALIGN_APPLY_DEBUG] save_and_apply_failed " <>
              inspect(%{active_stop_level_id: active_stop_level_id, reason: reason})
          end)

          {:error, reason}
      end
    end
  end

  def save_and_apply_stop_level_alignment(_, _, _, _), do: {:error, :invalid_input}

  defp load_stop_level_for_update(stop_level_id) when is_binary(stop_level_id) do
    from(sl in StopLevel, where: sl.id == ^stop_level_id, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp stop_level_alignment_snapshot(%StopLevel{} = stop_level) do
    %{
      floorplan_center_lat: stop_level.floorplan_center_lat,
      floorplan_center_lon: stop_level.floorplan_center_lon,
      floorplan_scale_mpp: stop_level.floorplan_scale_mpp,
      floorplan_rotation_deg: stop_level.floorplan_rotation_deg
    }
  end

  @doc """
  Applies the saved floorplan alignment to persist `stop_lat`/`stop_lon` on every
  eligible child stop of `stop_level`.

  Derives coordinates via `derive_child_stop_coords/3`, then updates all derived
  stops atomically in a single `Repo.transaction`. Each successful update emits a
  `[:stops, :updated]` broadcast. A single failed changeset rolls back every write
  in the call.

  Returns `{:ok, count}` with the number of updated stops, `{:ok, 0}` when no
  eligible stops exist, or `{:error, reason}` on derivation or persistence failure.
  """
  @spec apply_alignment_to_child_stops(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()}
          | {:error, :alignment_missing | :invalid_image_dims | {:transform, atom()} | term()}
  def apply_alignment_to_child_stops(%StopLevel{} = stop_level, image_w, image_h) do
    with {:ok, derived} <- derive_child_stop_coords(stop_level, image_w, image_h) do
      persist_derived_coords(derived)
    end
  end

  defp persist_derived_coords([]), do: {:ok, 0}

  defp persist_derived_coords(derived) when is_list(derived) do
    transaction_result =
      Repo.transaction(fn ->
        Enum.map(derived, fn entry ->
          case update_derived_stop_coords(entry) do
            {:ok, updated_stop} -> updated_stop
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end)

    case transaction_result do
      {:ok, updated_stops} ->
        Enum.each(updated_stops, fn stop ->
          broadcast({:ok, stop}, [:stops, :updated])
        end)

        {:ok, length(updated_stops)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_derived_coords_in_tx(derived) when is_list(derived) do
    derived
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, updated_stops} ->
      case update_derived_stop_coords(entry) do
        {:ok, updated_stop} ->
          {:cont, {:ok, [updated_stop | updated_stops]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, updated_stops} -> {:ok, Enum.reverse(updated_stops)}
      {:error, _} = error -> error
    end
  end

  defp update_derived_stop_coords(%{stop_id: stop_id, lat: lat, lon: lon}) do
    case Repo.get(Stop, stop_id) do
      nil ->
        {:error, :stop_not_found}

      %Stop{} = stop ->
        stop
        |> Stop.changeset(%{
          stop_lat: Decimal.from_float(lat),
          stop_lon: Decimal.from_float(lon)
        })
        |> Repo.update()
    end
  end

  # Derives lat/lon enrichment for every `pin` journal entry anchored to this
  # level, mirroring `derive_child_stop_coords/3` for nodes: the canonical anchor
  # is the pin's diagram coordinate; lat/lon is computed via the same
  # `FloorplanTransform.svg_to_lat_lon/4` using the level's alignment and the
  # client-supplied image dims. A pin whose diagram point can't normalize is
  # skipped (its lat/lon is left untouched). Returns `{:error, :alignment_missing}`
  # when the level isn't aligned so the alignment write can't silently produce
  # geo-less pins on an aligned level.
  defp derive_pin_coords(%StopLevel{} = stop_level, image_w, image_h) do
    with {:ok, alignment} <- extract_alignment(stop_level),
         :ok <- validate_positive_image_dims(image_w, image_h) do
      stop_level.id
      |> list_pin_entries_for_level()
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case Coordinates.normalize_point(%{x: entry.diagram_x, y: entry.diagram_y}) do
          nil ->
            {:cont, {:ok, acc}}

          %{x: x, y: y} ->
            case FloorplanTransform.svg_to_lat_lon(alignment, image_w, image_h, %{x: x, y: y}) do
              {:ok, {lat, lon}} ->
                {:cont, {:ok, [%{id: entry.id, lat: lat, lon: lon} | acc]}}

              {:error, reason} ->
                {:halt, {:error, {:transform, reason}}}
            end
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _} = error -> error
      end
    end
  end

  defp list_pin_entries_for_level(stop_level_id) do
    from(e in JournalEntry,
      where: e.target_type == "pin" and e.stop_level_id == ^stop_level_id
    )
    |> Repo.all()
  end

  defp persist_derived_pin_coords_in_tx(derived) when is_list(derived) do
    derived
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, updated} ->
      case update_derived_pin_coords(entry) do
        {:ok, updated_entry} -> {:cont, {:ok, [updated_entry | updated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, Enum.reverse(updated)}
      {:error, _} = error -> error
    end
  end

  defp update_derived_pin_coords(%{id: id, lat: lat, lon: lon}) do
    case Repo.get(JournalEntry, id) do
      nil ->
        {:error, :journal_entry_not_found}

      %JournalEntry{} = entry ->
        entry
        |> Ecto.Changeset.change(lat: lat, lon: lon)
        |> Repo.update()
    end
  end

  @doc """
  Infers floorplan alignment for `stop_level` from anchored child stops and
  eligible cross-level elevator pathways.

  Returns the inferred alignment plus lists of anchors used and candidates that
  were excluded with reasons. Does not persist any data.
  """
  @spec infer_level_alignment(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok,
           %{
             inferred_alignment: map(),
             anchors_used: [map()],
             excluded_anchors: [map()]
           }}
          | {:error,
             :alignment_prerequisites_missing
             | :insufficient_anchors
             | :degenerate_geometry
             | :high_residual
             | :invalid_input
             | :not_found}
  def infer_level_alignment(nil, _image_w, _image_h), do: {:error, :not_found}

  def infer_level_alignment(%StopLevel{level_id: nil}, _image_w, _image_h),
    do: {:error, :alignment_prerequisites_missing}

  def infer_level_alignment(%StopLevel{} = stop_level, image_w, image_h) do
    with :ok <- validate_positive_image_dims(image_w, image_h) do
      direct = direct_candidates_for(stop_level)
      cross = cross_level_candidates_for(stop_level)

      {anchors, exclusions} = AlignmentInference.select_anchors(direct, cross)

      case AlignmentInference.infer_alignment(anchors, image_w, image_h) do
        {:ok, inferred} ->
          {:ok,
           %{
             inferred_alignment: inferred,
             anchors_used: anchors,
             excluded_anchors: exclusions
           }}

        {:error, _} = error ->
          error
      end
    else
      {:error, :invalid_image_dims} -> {:error, :invalid_input}
      other -> other
    end
  end

  @doc """
  Infers and persists floorplan alignment for `stop_level`.

  Calls `infer_level_alignment/3` and, on success, writes the inferred
  `floorplan_*` fields via `StopLevel.alignment_changeset/2`. Emits a
  `[:stop_levels, :updated]` broadcast only on successful update.
  """
  @spec save_inferred_level_alignment(StopLevel.t(), pos_integer(), pos_integer()) ::
          {:ok, StopLevel.t(), map()}
          | {:error,
             :alignment_prerequisites_missing
             | :insufficient_anchors
             | :degenerate_geometry
             | :high_residual
             | :invalid_input
             | :not_found
             | Ecto.Changeset.t()}
  def save_inferred_level_alignment(%StopLevel{} = stop_level, image_w, image_h) do
    with {:ok, %{inferred_alignment: inferred} = result} <-
           infer_level_alignment(stop_level, image_w, image_h),
         {:ok, updated} <- persist_inferred_alignment(stop_level, inferred) do
      broadcast({:ok, updated}, [:stop_levels, :updated])
      {:ok, updated, result}
    end
  end

  def save_inferred_level_alignment(nil, _image_w, _image_h), do: {:error, :not_found}

  defp persist_inferred_alignment(%StopLevel{} = stop_level, inferred) do
    stop_level
    |> StopLevel.alignment_changeset(%{
      floorplan_center_lat: inferred.center_lat,
      floorplan_center_lon: inferred.center_lon,
      floorplan_scale_mpp: inferred.scale_mpp,
      floorplan_rotation_deg: inferred.rotation_deg
    })
    |> Repo.update()
  end

  defp direct_candidates_for(%StopLevel{} = stop_level) do
    stop_level.stop_id
    |> list_child_stops_for_level(stop_level.level_id)
    |> Enum.filter(& &1.on_active_level)
    |> Enum.map(fn stop ->
      {sx, sy} = svg_xy_from_coordinate(stop.diagram_coordinate)

      %{
        stop_id: stop.id,
        svg_x: sx,
        svg_y: sy,
        lat: decimal_to_float(stop.stop_lat),
        lon: decimal_to_float(stop.stop_lon)
      }
    end)
  end

  defp cross_level_candidates_for(%StopLevel{} = stop_level) do
    pathways =
      list_pathways_for_level(
        stop_level.organization_id,
        stop_level.gtfs_version_id,
        stop_level.level_id,
        stop_level.stop_id
      )
      |> Enum.filter(& &1.is_cross_level)

    target_level = Repo.get!(Level, stop_level.level_id)
    partner_level_indexes = load_partner_level_indexes(pathways, stop_level, target_level)

    pathways
    |> Enum.map(fn pathway ->
      case cross_level_endpoints(pathway) do
        {target_stop, partner_stop} ->
          partner_index = Map.get(partner_level_indexes, partner_stop.level_id)
          delta = level_index_delta(target_level.level_index, partner_index)
          build_cross_level_candidate(pathway, target_stop, partner_stop, delta)

        nil ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp cross_level_endpoints(%{from_on_active_level: true, to_on_active_level: false} = p),
    do: {p.from_stop, p.to_stop}

  defp cross_level_endpoints(%{from_on_active_level: false, to_on_active_level: true} = p),
    do: {p.to_stop, p.from_stop}

  defp cross_level_endpoints(_), do: nil

  defp build_cross_level_candidate(_pathway, _target_stop, %Stop{parent_station: nil}, _delta),
    do: nil

  defp build_cross_level_candidate(_pathway, _target_stop, %Stop{parent_station: ""}, _delta),
    do: nil

  defp build_cross_level_candidate(_pathway, _target_stop, _partner_stop, nil), do: nil

  defp build_cross_level_candidate(pathway, target_stop, partner_stop, delta) do
    {sx, sy} = svg_xy_from_coordinate(target_stop.diagram_coordinate)

    %{
      stop_id: target_stop.id,
      pathway_id: pathway.id,
      pathway_mode: pathway.pathway_mode,
      level_index_delta: delta,
      svg_x: sx,
      svg_y: sy,
      lat: decimal_to_float(partner_stop.stop_lat),
      lon: decimal_to_float(partner_stop.stop_lon)
    }
  end

  defp load_partner_level_indexes(pathways, stop_level, target_level) do
    partner_level_ids =
      pathways
      |> Enum.flat_map(fn pathway ->
        case cross_level_endpoints(pathway) do
          {_target, partner} -> [partner.level_id]
          nil -> []
        end
      end)
      |> Enum.reject(&(is_nil(&1) or &1 == target_level.level_id))
      |> Enum.uniq()

    case partner_level_ids do
      [] ->
        %{}

      ids ->
        from(l in Level,
          where:
            l.organization_id == ^stop_level.organization_id and
              l.gtfs_version_id == ^stop_level.gtfs_version_id and
              l.level_id in ^ids,
          select: {l.level_id, l.level_index}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  defp level_index_delta(_target_index, nil), do: nil
  defp level_index_delta(target_index, partner_index), do: abs(partner_index - target_index)

  defp svg_xy_from_coordinate(coord) do
    case Coordinates.normalize_point(coord) do
      %{x: x, y: y} -> {x, y}
      nil -> {nil, nil}
    end
  end

  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n * 1.0
  defp decimal_to_float(_), do: nil

  @doc """
  Recalculates pathway lengths for same-level pathways on a station level.

  Returns `{:ok, count}` where count is the number of pathways whose lengths were updated.
  """
  def recalculate_pathway_lengths_for_level(
        %StopLevel{} = stop_level,
        organization_id,
        gtfs_version_id,
        level_id,
        parent_station_id
      ) do
    organization_id
    |> list_pathways_for_level(gtfs_version_id, level_id, parent_station_id)
    |> Enum.reject(& &1.is_cross_level)
    |> Enum.sort_by(& &1.pathway_id, :asc)
    |> Enum.reduce_while({:ok, 0}, fn pathway, {:ok, count} ->
      case calculate_pathway_length(stop_level, pathway.from_stop, pathway.to_stop) do
        %Decimal{} = length ->
          case pathway
               |> Pathway.changeset(%{length: length})
               |> Repo.update() do
            {:ok, _updated_pathway} -> {:cont, {:ok, count + 1}}
            {:error, changeset} -> {:halt, {:error, changeset}}
          end

        _ ->
          {:cont, {:ok, count}}
      end
    end)
  end

  @doc """
  Saves stop-level calibration and recalculates same-level pathway lengths atomically.
  """
  def save_scale_and_recalculate(
        %StopLevel{} = stop_level,
        scale_attrs,
        organization_id,
        gtfs_version_id,
        level_id,
        parent_station_id
      ) do
    transaction_result =
      Repo.transaction(fn ->
        with {:ok, updated_stop_level} <-
               stop_level
               |> StopLevel.scale_changeset(scale_attrs)
               |> Repo.update(),
             {:ok, recalculated_count} <-
               recalculate_pathway_lengths_for_level(
                 updated_stop_level,
                 organization_id,
                 gtfs_version_id,
                 level_id,
                 parent_station_id
               ) do
          %{stop_level: updated_stop_level, recalculated_count: recalculated_count}
        else
          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case transaction_result do
      {:ok, result} ->
        broadcast({:ok, result.stop_level}, [:stop_levels, :updated])
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clears a stop_level's diagram calibration.
  """
  def clear_stop_level_scale(%StopLevel{} = stop_level) do
    update_stop_level_scale(stop_level, %{
      scale_point_a: nil,
      scale_point_b: nil,
      scale_distance_meters: nil,
      scale_meters_per_unit: nil
    })
  end

  @doc """
  Calculates a pathway length in meters from two stops and a calibrated stop_level.
  Returns nil when calibration or coordinates are unavailable.
  """
  def calculate_pathway_length(%StopLevel{} = stop_level, %Stop{} = from_stop, %Stop{} = to_stop) do
    with %{x: from_x, y: from_y} <- Coordinates.normalize_point(from_stop.diagram_coordinate),
         %{x: to_x, y: to_y} <- Coordinates.normalize_point(to_stop.diagram_coordinate),
         %Decimal{} = meters_per_unit <- stop_level.scale_meters_per_unit,
         :gt <- Decimal.compare(meters_per_unit, Decimal.new(0)) do
      svg_distance =
        :math.sqrt(:math.pow(to_x - from_x, 2) + :math.pow(to_y - from_y, 2))

      svg_distance
      |> Decimal.from_float()
      |> Decimal.mult(meters_per_unit)
      |> Decimal.round(2)
    else
      _ -> nil
    end
  end

  def calculate_pathway_length(_, _, _), do: nil

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
  Returns the count of stops for an organization and GTFS version.
  """
  def count_stops(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of stops for an organization and GTFS version.
  """
  def list_stops(organization_id, gtfs_version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.stop_name]
    )
    |> Repo.all()
  end

  @doc """
  Returns a map of stop_id to list of routes serving that stop.
  """
  def get_routes_for_stops(organization_id, gtfs_version_id, stop_ids) do
    query =
      from(st in StopTime,
        join: t in Trip,
        on:
          st.trip_id == t.trip_id and st.organization_id == t.organization_id and
            st.gtfs_version_id == t.gtfs_version_id,
        join: r in Route,
        on:
          t.route_id == r.route_id and t.organization_id == r.organization_id and
            t.gtfs_version_id == r.gtfs_version_id,
        where:
          st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id and
            st.stop_id in ^stop_ids,
        distinct: [st.stop_id, r.route_id],
        order_by: [asc: r.route_short_name],
        select:
          {st.stop_id,
           %{
             route_id: r.route_id,
             route_short_name: r.route_short_name,
             route_color: r.route_color,
             route_text_color: r.route_text_color
           }}
      )

    Repo.all(query)
    |> Enum.group_by(fn {stop_id, _} -> stop_id end, fn {_, route} -> route end)
  end

  @doc """
  Returns a list of routes that serve at least one station (stop with no parent).
  """
  def list_routes_serving_stations(organization_id, gtfs_version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      where: fragment("EXISTS (
        SELECT 1 FROM stop_times st
        JOIN trips t ON st.trip_id = t.trip_id AND st.organization_id = t.organization_id AND st.gtfs_version_id = t.gtfs_version_id
        JOIN stops s ON st.stop_id = s.stop_id AND st.organization_id = s.organization_id AND st.gtfs_version_id = s.gtfs_version_id
        WHERE t.route_id = ? AND t.organization_id = ? AND t.gtfs_version_id = ?
        AND s.parent_station IS NULL
      )", r.route_id, r.organization_id, r.gtfs_version_id),
      order_by: [asc: r.route_short_name, asc: r.route_id],
      select: %{
        route_id: r.route_id,
        route_short_name: r.route_short_name,
        route_color: r.route_color
      }
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of stations (stops with no parent) for an organization and GTFS version.

  Accepts optional filters, search, sort, and pagination via opts keyword list.

  ## Examples

      iex> list_stations(organization_id, gtfs_version_id)
      [%Stop{}, ...]
  """
  def list_stations(organization_id, gtfs_version_id, opts \\ []) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          is_nil(s.parent_station)
    )
    |> maybe_filter_location_type(opts[:location_type])
    |> maybe_filter_route(opts[:route_id], organization_id, gtfs_version_id)
    |> maybe_filter_direction(opts[:direction_id], organization_id, gtfs_version_id)
    |> maybe_filter_wheelchair(opts[:wheelchair_boarding])
    |> maybe_search_stops(opts[:search])
    |> apply_stop_sort(opts[:sort_by], opts[:sort_dir])
    |> paginate(opts[:page], opts[:per_page])
    |> Repo.all()
  end

  @doc """
  Returns the count of stations (stops with no parent) for an organization and GTFS version.

  Accepts optional filters via opts keyword list.

  ## Examples

      iex> count_stations(organization_id, gtfs_version_id)
      42
  """
  def count_stations(organization_id, gtfs_version_id, opts \\ []) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          is_nil(s.parent_station)
    )
    |> maybe_filter_location_type(opts[:location_type])
    |> maybe_filter_route(opts[:route_id], organization_id, gtfs_version_id)
    |> maybe_filter_direction(opts[:direction_id], organization_id, gtfs_version_id)
    |> maybe_filter_wheelchair(opts[:wheelchair_boarding])
    |> maybe_search_stops(opts[:search])
    |> Repo.aggregate(:count)
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
  Gets the active station editing status for an organization, GTFS version, and station.
  """
  @spec get_station_editing_status(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          StationEditingStatus.t() | nil
  def get_station_editing_status(organization_id, gtfs_version_id, station_id) do
    from(s in StationEditingStatus,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
          s.station_id == ^station_id,
      preload: [:user]
    )
    |> Repo.one()
  end

  @doc """
  Subscribes to station editing status updates for an organization, GTFS version, and station.
  """
  @spec subscribe_station_editing_status(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, term()}
  def subscribe_station_editing_status(organization_id, gtfs_version_id, station_id) do
    Phoenix.PubSub.subscribe(
      GtfsPlanner.PubSub,
      station_editing_status_topic(organization_id, gtfs_version_id, station_id)
    )
  end

  @doc """
  Creates or replaces the active editing status for a station.
  """
  @spec set_station_editing_status(Ecto.UUID.t(), Ecto.UUID.t(), Stop.t(), Accounts.User.t()) ::
          {:ok, StationEditingStatus.t()} | {:error, Ecto.Changeset.t()}
  def set_station_editing_status(
        organization_id,
        gtfs_version_id,
        %Stop{} = station,
        %Accounts.User{} = user
      ) do
    started_at = DateTime.utc_now()

    attrs = %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      station_id: station.id,
      user_id: user.id,
      started_at: started_at
    }

    Repo.transaction(fn ->
      lock_station_editing_status!(organization_id, gtfs_version_id, station.id)

      %StationEditingStatus{}
      |> StationEditingStatus.changeset(attrs)
      |> Repo.insert(
        on_conflict: [set: [user_id: user.id, started_at: started_at]],
        conflict_target: [:organization_id, :gtfs_version_id, :station_id],
        returning: true
      )
      |> case do
        {:ok, status} ->
          status = Repo.preload(status, :user)
          :ok = broadcast_station_editing_status(status)
          {:ok, status}

        {:error, changeset} ->
          {:error, changeset}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clears the active station editing status for an organization, GTFS version, and station.
  """
  @spec clear_station_editing_status(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def clear_station_editing_status(organization_id, gtfs_version_id, station_id) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        lock_station_editing_status!(organization_id, gtfs_version_id, station_id)

        from(s in StationEditingStatus,
          where:
            s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
              s.station_id == ^station_id
        )
        |> Repo.delete_all()

        :ok =
          broadcast_station_editing_status(
            organization_id,
            gtfs_version_id,
            station_id,
            nil
          )
      end)

    :ok
  end

  defp broadcast_station_editing_status(%StationEditingStatus{} = status) do
    broadcast_station_editing_status(
      status.organization_id,
      status.gtfs_version_id,
      status.station_id,
      status
    )
  end

  defp broadcast_station_editing_status(organization_id, gtfs_version_id, station_id, status) do
    Phoenix.PubSub.broadcast(
      GtfsPlanner.PubSub,
      station_editing_status_topic(organization_id, gtfs_version_id, station_id),
      {:station_editing_status_updated, status}
    )
  end

  defp station_editing_status_topic(organization_id, gtfs_version_id, station_id) do
    "station_editing_status:#{organization_id}:#{gtfs_version_id}:#{station_id}"
  end

  defp lock_station_editing_status!(organization_id, gtfs_version_id, station_id) do
    topic = station_editing_status_topic(organization_id, gtfs_version_id, station_id)

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext($1)::bigint)",
      [topic]
    )

    :ok
  end

  @doc """
  Returns a station-scoped snapshot used to build deterministic station reports.

  The snapshot includes the parent station stop, station child stops, station levels,
  and pathways touching station child stops (with `from_stop` and `to_stop` populated).
  """
  @spec get_station_report_snapshot(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok,
           %{
             station: Stop.t(),
             child_stops: [Stop.t()],
             levels: [map()],
             pathways: [Pathway.t()]
           }}
          | {:error, :not_found}
  def get_station_report_snapshot(organization_id, gtfs_version_id, stop_id) do
    case get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
      %Stop{} = station ->
        snapshot = %{
          station: station,
          child_stops: list_child_stops_for_parent(organization_id, gtfs_version_id, station.id),
          levels: list_levels_for_station(organization_id, gtfs_version_id, station.id),
          pathways: list_pathways_for_station(organization_id, gtfs_version_id, station.id)
        }

        {:ok, snapshot}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a unique stop_id within an organization and GTFS version.

  Uses the provided base stop_id if available, otherwise appends `_2`, `_3`, etc.
  """
  def unique_stop_id(organization_id, gtfs_version_id, base_stop_id, exclude_stop_id \\ nil) do
    escaped_base_stop_id = escape_like_pattern(base_stop_id)

    query =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            fragment(
              "? LIKE ? ESCAPE ?",
              s.stop_id,
              ^"#{escaped_base_stop_id}%",
              ^"\\"
            ),
        select: s.stop_id
      )

    query =
      if is_nil(exclude_stop_id) do
        query
      else
        where(query, [s], s.stop_id != ^exclude_stop_id)
      end

    existing_ids =
      query
      |> Repo.all()
      |> MapSet.new()

    if MapSet.member?(existing_ids, base_stop_id) do
      suffix =
        Stream.iterate(2, &(&1 + 1))
        |> Enum.find(fn n ->
          candidate = "#{base_stop_id}_#{n}"
          not MapSet.member?(existing_ids, candidate)
        end)

      case suffix do
        nil ->
          raise "Unable to generate unique stop_id for #{inspect(base_stop_id)}"

        n ->
          "#{base_stop_id}_#{n}"
      end
    else
      base_stop_id
    end
  end

  @doc """
  Generates a kebab-case stop_id from a stop name with a two-digit sequence suffix.

  Tries `{kebab}-01`, `{kebab}-02`, etc. until finding one that does not collide
  with existing stop_ids in the same organization and version. The optional
  `exclude_stop_id` is ignored during collision checks (useful when renaming a stop
  so its own current ID is not treated as a collision).
  """
  def generate_kebab_stop_id(organization_id, gtfs_version_id, stop_name, exclude_stop_id \\ nil) do
    kebab =
      case Stop.kebabify(stop_name) do
        "" -> "stop"
        k -> k
      end

    escaped_kebab = escape_like_pattern(kebab)

    query =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            fragment(
              "? LIKE ? ESCAPE ?",
              s.stop_id,
              ^"#{escaped_kebab}-%",
              ^"\\"
            ),
        select: s.stop_id
      )

    query =
      if is_nil(exclude_stop_id) do
        query
      else
        where(query, [s], s.stop_id != ^exclude_stop_id)
      end

    existing_ids =
      query
      |> Repo.all()
      |> MapSet.new()

    seq =
      1..99
      |> Enum.find(fn n ->
        candidate = "#{kebab}-#{String.pad_leading(Integer.to_string(n), 2, "0")}"
        not MapSet.member?(existing_ids, candidate)
      end)

    case seq do
      nil ->
        {:error, "Unable to generate unique stop ID — all sequences exhausted"}

      n ->
        {:ok, "#{kebab}-#{String.pad_leading(Integer.to_string(n), 2, "0")}"}
    end
  end

  defp escape_like_pattern(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
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
  Creates a stop for import workflows using permissive parent/level validation.
  """
  def import_create_stop(attrs \\ %{}) do
    %Stop{}
    |> Stop.import_changeset(attrs)
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
  Updates a stop, cascading stop_id changes to all referencing records when the
  stop_id is modified. Delegates to `update_stop/2` when the stop_id is unchanged.
  """
  def update_stop_with_cascade(%Stop{} = stop, attrs) do
    new_stop_id = attrs[:stop_id] || attrs["stop_id"]

    if new_stop_id == stop.stop_id or is_nil(new_stop_id) do
      update_stop(stop, attrs)
    else
      mapping = %{stop.stop_id => new_stop_id}
      now = DateTime.utc_now()

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:update_stop, fn _repo, _changes ->
          stop
          |> Stop.changeset(attrs)
          |> Repo.update()
        end)
        |> Ecto.Multi.run(:cascade_references, fn repo, _changes ->
          {:ok,
           update_stop_id_references(
             repo,
             mapping,
             stop.organization_id,
             stop.gtfs_version_id,
             now
           )}
        end)

      case Repo.transaction(multi) do
        {:ok, %{update_stop: updated_stop}} ->
          broadcast({:ok, updated_stop}, [:stops, :updated])

        {:error, :update_stop, changeset, _changes} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Updates a stop for import workflows using permissive parent/level validation.
  """
  def import_update_stop(%Stop{} = stop, attrs) do
    stop
    |> Stop.import_changeset(attrs)
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
  Deletes a child stop and its connected pathways in a single transaction.

  Scopes the lookup to the given organization, version, and parent station
  to prevent cross-tenant mutations.
  """
  @spec delete_child_stop(integer(), integer(), String.t(), integer()) ::
          {:ok, Stop.t()} | {:error, :not_found | term()}
  def delete_child_stop(organization_id, gtfs_version_id, station_stop_id, stop_id) do
    descendants = descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id)

    stop_query =
      from(s in Stop,
        where:
          s.id == ^stop_id and
            s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id in subquery(descendants)
      )

    case Repo.one(stop_query) do
      nil ->
        {:error, :not_found}

      stop ->
        Ecto.Multi.new()
        |> delete_pathways_for_stop_multi(organization_id, gtfs_version_id, stop.stop_id)
        |> Ecto.Multi.delete(:stop, stop)
        |> Repo.transaction()
        |> case do
          {:ok, %{stop: deleted_stop}} ->
            broadcast({:ok, deleted_stop}, [:stops, :deleted])

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Removes a child stop from the station diagram by clearing its
  `diagram_coordinate` and `level_id`, and deletes connected pathways
  so no dangling references remain.

  Scopes the update to the given organization, version, and parent station
  to prevent cross-tenant mutations.
  """
  @spec remove_child_stop_from_diagram(integer(), integer(), String.t(), integer()) ::
          {:ok, Stop.t()} | {:error, :not_found | term()}
  def remove_child_stop_from_diagram(organization_id, gtfs_version_id, station_stop_id, stop_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    descendants = descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id)

    stop_query =
      from(s in Stop,
        where:
          s.id == ^stop_id and
            s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id in subquery(descendants)
      )

    case Repo.one(stop_query) do
      nil ->
        {:error, :not_found}

      stop ->
        update_query =
          from(s in Stop, where: s.id == ^stop_id)

        Ecto.Multi.new()
        |> delete_pathways_for_stop_multi(organization_id, gtfs_version_id, stop.stop_id)
        |> Ecto.Multi.update_all(:stop, update_query,
          set: [diagram_coordinate: nil, level_id: nil, updated_at: now]
        )
        |> Repo.transaction()
        |> case do
          {:ok, _} ->
            Repo.get!(Stop, stop_id)
            |> then(&{:ok, &1})
            |> broadcast([:stops, :updated])

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
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
    parent_station = Repo.get!(Stop, parent_station_id)

    descendants =
      descendant_stop_ids_query(organization_id, gtfs_version_id, parent_station.stop_id)

    from(s in Stop,
      left_join: l in Level,
      on:
        l.level_id == s.level_id and
          l.organization_id == ^organization_id and
          l.gtfs_version_id == ^gtfs_version_id,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id in subquery(descendants),
      order_by: [asc: s.stop_name],
      select: s,
      select_merge: %{level: l}
    )
    |> Repo.all()
  end

  @doc """
  Returns deterministic station-scope stop_ids for a station stop_id.

  Scope includes:
  - the station stop_id itself
  - direct children where parent_station equals station stop_id
  - boarding-area grandchildren where location_type is 4 and parent_station references a direct child
  """
  @spec list_station_scope_stop_ids(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :station_not_found}
  def list_station_scope_stop_ids(organization_id, gtfs_version_id, station_stop_id)
      when is_binary(station_stop_id) do
    case get_stop_by_stop_id(organization_id, gtfs_version_id, station_stop_id) do
      nil ->
        {:error, :station_not_found}

      _station ->
        descendant_stop_ids =
          organization_id
          |> descendant_stop_ids_query(gtfs_version_id, station_stop_id)
          |> Repo.all()

        {:ok,
         descendant_stop_ids
         |> Kernel.++([station_stop_id])
         |> Enum.uniq()
         |> Enum.sort()}
    end
  end

  @doc """
  Returns the list of levels for a specific station with stop counts.
  Uses a hybrid approach: combines levels from child stops with levels from stop_levels table.

  ## Examples

      iex> list_levels_for_station(organization_id, gtfs_version_id, parent_station_id)
      [%{level: %Level{}, stop_count: 5}, ...]
  """
  def list_levels_for_station(organization_id, gtfs_version_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)

    descendants =
      descendant_stop_ids_query(organization_id, gtfs_version_id, parent_station.stop_id)

    # Query 1: Levels from child stops that have a level_id set
    levels_from_stops =
      from(s in Stop,
        join: l in Level,
        on:
          l.level_id == s.level_id and
            l.organization_id == ^organization_id and
            l.gtfs_version_id == ^gtfs_version_id,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id in subquery(descendants) and
            not is_nil(s.level_id),
        group_by: l.id,
        select: %{level_id: l.id, stop_count: count(s.id)}
      )
      |> Repo.all()
      |> Enum.into(%{}, fn %{level_id: id, stop_count: count} -> {id, count} end)

    # Query 2: Levels from stop_levels table (expressing intent)
    levels_from_stop_levels =
      from(sl in StopLevel,
        join: l in Level,
        on: sl.level_id == l.id,
        where:
          sl.organization_id == ^organization_id and
            sl.gtfs_version_id == ^gtfs_version_id and
            sl.stop_id == ^parent_station_id,
        select: %{level: l, stop_level: sl, diagram_filename: sl.diagram_filename}
      )
      |> Repo.all()

    # Combine: unique list of level IDs from both sources
    all_level_ids =
      (Map.keys(levels_from_stops) ++ Enum.map(levels_from_stop_levels, & &1.level.id))
      |> Enum.uniq()

    levels_from_stop_levels_by_id =
      Map.new(levels_from_stop_levels, fn %{level: level} = level_data ->
        {level.id, level_data}
      end)

    missing_level_ids =
      all_level_ids
      |> Enum.reject(&Map.has_key?(levels_from_stop_levels_by_id, &1))

    missing_levels_by_id =
      if missing_level_ids == [] do
        %{}
      else
        from(l in Level,
          where: l.id in ^missing_level_ids,
          select: {l.id, l}
        )
        |> Repo.all()
        |> Map.new()
      end

    # Build final result with stop counts and diagram filenames
    all_level_ids
    |> Enum.map(fn level_id ->
      # Get level from stop_levels query if available (includes diagram_filename)
      from_stop_levels = Map.get(levels_from_stop_levels_by_id, level_id)

      level =
        if from_stop_levels do
          from_stop_levels.level
        else
          case Map.fetch(missing_levels_by_id, level_id) do
            {:ok, level} ->
              level

            :error ->
              raise Ecto.NoResultsError,
                queryable: Level,
                query: "level not found for id #{inspect(level_id)} in list_levels_for_station/3"
          end
        end

      stop_count = Map.get(levels_from_stops, level_id, 0)
      diagram_filename = if from_stop_levels, do: from_stop_levels.diagram_filename, else: nil
      stop_level = if from_stop_levels, do: from_stop_levels.stop_level, else: nil

      %{
        level: level,
        stop_count: stop_count,
        diagram_filename: diagram_filename,
        stop_level: stop_level
      }
    end)
    |> Enum.sort_by(& &1.level.level_index, :asc)
  end

  @doc """
  Lists stop_level rows for a station within an organization/version scope.

  Results are deterministically ordered by `level_index`, then `stop_levels.id`.
  Each row preloads its associated `level` for adjacency and propagation logic.
  """
  @spec list_stop_levels_for_station(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          [StopLevel.t()]
  def list_stop_levels_for_station(organization_id, gtfs_version_id, station_id) do
    from(sl in StopLevel,
      join: l in assoc(sl, :level),
      where:
        sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id and
          sl.stop_id == ^station_id,
      order_by: [asc: l.level_index, asc: sl.id],
      preload: [level: l]
    )
    |> Repo.all()
  end

  @doc """
  Gets a stop_level by stop_id and level_id.
  """
  def get_stop_level(organization_id, gtfs_version_id, stop_id, level_id) do
    from(sl in StopLevel,
      where:
        sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id and
          sl.stop_id == ^stop_id and
          sl.level_id == ^level_id
    )
    |> Repo.one()
  end

  @doc """
  Returns true if the given level is associated with any station other than `station_id`.
  """
  def level_used_by_other_stations?(organization_id, gtfs_version_id, level_id, station_id) do
    from(sl in StopLevel,
      where:
        sl.organization_id == ^organization_id and
          sl.gtfs_version_id == ^gtfs_version_id and
          sl.level_id == ^level_id and
          sl.stop_id != ^station_id
    )
    |> Repo.exists?()
  end

  @doc """
  Removes a level association from a station while preserving the shared level record.
  """
  def remove_level_from_station(
        organization_id,
        gtfs_version_id,
        station_id,
        station_stop_id,
        level_id
      ) do
    Repo.transaction(fn ->
      level = get_level!(level_id)

      from(s in Stop,
        where: s.parent_station == ^station_stop_id and s.level_id == ^level.level_id
      )
      |> Repo.update_all(set: [level_id: nil, diagram_coordinate: nil])

      with %StopLevel{} = stop_level <-
             get_stop_level(organization_id, gtfs_version_id, station_id, level_id),
           {:ok, _deleted_stop_level} <- Repo.delete(stop_level) do
        :removed
      else
        nil -> :removed
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :removed} -> {:ok, :removed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a stop_level association.
  """
  def create_stop_level(attrs \\ %{}) do
    %StopLevel{}
    |> StopLevel.changeset(attrs)
    |> Repo.insert()
    |> broadcast([:stop_levels, :created])
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
    with %Stop{} = parent_station <- Repo.get(Stop, parent_station_id),
         %Level{} = level <- Repo.get(Level, level_id) do
      descendants =
        descendant_stop_ids_query(
          parent_station.organization_id,
          parent_station.gtfs_version_id,
          parent_station.stop_id
        )

      from(s in Stop,
        where:
          s.stop_id in subquery(descendants) and
            s.organization_id == ^parent_station.organization_id and
            s.gtfs_version_id == ^parent_station.gtfs_version_id,
        order_by: [asc: s.stop_name]
      )
      |> Repo.all()
      |> Enum.map(fn stop ->
        # Add a virtual field indicating if this stop is on the active level
        Map.put(stop, :on_active_level, stop.level_id == level.level_id)
      end)
    else
      _ -> []
    end
  end

  @doc """
  Returns pathways where the from_stop is on the specified level
  and both endpoints belong to the specified parent station.

  ## Examples

      iex> list_pathways_for_level(org_id, version_id, level_id, parent_station_id)
      [%Pathway{from_stop: %Stop{}, to_stop: %Stop{}}, ...]
  """
  def list_pathways_for_level(organization_id, gtfs_version_id, level_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)
    level = Repo.get!(Level, level_id)

    descendants =
      descendant_stop_ids_query(organization_id, gtfs_version_id, parent_station.stop_id)

    from(p in Pathway,
      join: from_stop in Stop,
      on:
        p.from_stop_id == from_stop.stop_id and
          from_stop.organization_id == ^organization_id and
          from_stop.gtfs_version_id == ^gtfs_version_id,
      join: to_stop in Stop,
      on:
        p.to_stop_id == to_stop.stop_id and
          to_stop.organization_id == ^organization_id and
          to_stop.gtfs_version_id == ^gtfs_version_id,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (from_stop.level_id == ^level.level_id or to_stop.level_id == ^level.level_id) and
          from_stop.stop_id in subquery(descendants) and
          to_stop.stop_id in subquery(descendants),
      order_by: [asc: p.pathway_id],
      select: p,
      select_merge: %{from_stop: from_stop, to_stop: to_stop}
    )
    |> Repo.all()
    |> Enum.map(fn pathway ->
      # Add flags indicating if this is a cross-level pathway
      from_on_level = pathway.from_stop.level_id == level.level_id
      to_on_level = pathway.to_stop.level_id == level.level_id
      is_cross_level = from_on_level != to_on_level

      Map.merge(pathway, %{
        is_cross_level: is_cross_level,
        from_on_active_level: from_on_level,
        to_on_active_level: to_on_level
      })
    end)
  end

  @doc """
  Returns pathways where from_stop or to_stop is a child of the given station.

  ## Examples

      iex> list_pathways_for_station(org_id, version_id, parent_id)
      [%Pathway{from_stop: %Stop{}, to_stop: %Stop{}}, ...]
  """
  def list_pathways_for_station(organization_id, gtfs_version_id, parent_station_id) do
    parent_station = Repo.get!(Stop, parent_station_id)

    descendants =
      descendant_stop_ids_query(organization_id, gtfs_version_id, parent_station.stop_id)

    from(p in Pathway,
      join: from_stop in Stop,
      on:
        p.from_stop_id == from_stop.stop_id and
          from_stop.organization_id == ^organization_id and
          from_stop.gtfs_version_id == ^gtfs_version_id,
      join: to_stop in Stop,
      on:
        p.to_stop_id == to_stop.stop_id and
          to_stop.organization_id == ^organization_id and
          to_stop.gtfs_version_id == ^gtfs_version_id,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (p.from_stop_id in subquery(descendants) or
             p.to_stop_id in subquery(descendants)),
      order_by: [asc: p.pathway_id],
      select: p,
      select_merge: %{from_stop: from_stop, to_stop: to_stop}
    )
    |> Repo.all()
  end

  @doc """
  All station-journal entries for a station (any target), oldest first. See the
  companion app's `specs/api/station-journal.md`.
  """
  def list_journal_entries_for_station(organization_id, gtfs_version_id, station_id) do
    from(e in JournalEntry,
      where:
        e.organization_id == ^organization_id and
          e.gtfs_version_id == ^gtfs_version_id and
          e.station_id == ^station_id,
      order_by: [asc: e.captured_at, asc: e.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Upsert a station-journal entry by its client-generated `id` (idempotent). On
  conflict, the mutable fields are replaced (last-write-wins on `body` /
  `closed_at` / `closed_by`); scoping and authorship are preserved from the
  original insert.

  A `pin` entry's canonical anchor is its diagram coordinate (`stop_level_id` +
  `diagram_x/y`), exactly like a node's `diagram_coordinate`. Sync never sets
  `lat`/`lon`: that geographic enrichment is imputed at level-alignment time (see
  `save_and_apply_stop_level_alignment/4`) and is therefore omitted from the
  `on_conflict` replace list so a later metadata re-sync can't reset an
  alignment-imputed lat/lon back to nil.
  """
  def upsert_journal_entry(attrs) do
    %JournalEntry{}
    |> JournalEntry.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :body,
           :closed_at,
           :closed_by,
           :target_type,
           :target_id,
           :stop_level_id,
           :diagram_x,
           :diagram_y,
           :updated_at
         ]},
      conflict_target: :id
    )
  end

  @doc """
  Upsert a journal photo by its client-generated `id` (idempotent on retry). On
  conflict the mutable metadata is replaced; scoping and the owning entry are
  preserved from the original insert. See the companion app's
  `specs/api/station-journal.md`.
  """
  def upsert_journal_photo(attrs) do
    %JournalPhoto{}
    |> JournalPhoto.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:filename, :content_type, :byte_size, :width, :height, :updated_at]},
      conflict_target: :id
    )
  end

  @doc """
  All journal photos whose owning entry belongs to the given (org, version,
  station), oldest first. Used to nest photos under their entries in the bundle.
  """
  def list_journal_photos_for_station(organization_id, gtfs_version_id, station_id) do
    from(p in JournalPhoto,
      join: e in JournalEntry,
      on: e.id == p.journal_entry_id,
      where:
        e.organization_id == ^organization_id and
          e.gtfs_version_id == ^gtfs_version_id and
          e.station_id == ^station_id,
      order_by: [asc: p.captured_at, asc: p.inserted_at]
    )
    |> Repo.all()
  end

  defp descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id) do
    direct_child_ids =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.parent_station == ^station_stop_id,
        select: s.stop_id
      )

    from(s in Stop,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          (s.parent_station == ^station_stop_id or
             (s.location_type == 4 and s.parent_station in subquery(direct_child_ids))),
      select: s.stop_id
    )
  end

  @doc """
  Returns pathways where the given stop_id is either the from_stop or to_stop.

  ## Examples

      iex> list_pathways_for_stop(org_id, version_id, "stop_123")
      [%Pathway{}, ...]
  """
  def list_pathways_for_stop(organization_id, gtfs_version_id, stop_id) do
    from(p in Pathway,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and
          (p.from_stop_id == ^stop_id or p.to_stop_id == ^stop_id),
      order_by: [asc: p.pathway_id]
    )
    |> Repo.all()
  end

  @doc """
  Returns the count of pathways for an organization and GTFS version.
  """
  def count_pathways(organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
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
  Gets a single pathway, returning `nil` if it does not exist.
  """
  def get_pathway(id), do: Repo.get(Pathway, id)

  @doc """
  Gets a single pathway by its GTFS pathway_id within an org+version scope.

  Returns `nil` if no matching pathway exists.
  """
  def get_pathway_by_pathway_id(organization_id, gtfs_version_id, pathway_id) do
    from(p in Pathway,
      where:
        p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id and
          p.pathway_id == ^pathway_id
    )
    |> Repo.one()
  end

  @doc """
  Gets a single pathway with manually populated from_stop and to_stop.

  Raises `Ecto.NoResultsError` if the Pathway does not exist.

  ## Examples

      iex> get_pathway_with_stops!(id)
      %Pathway{from_stop: %Stop{}, to_stop: %Stop{}}

      iex> get_pathway_with_stops!(Ecto.UUID.generate())
      ** (Ecto.NoResultsError)
  """
  def get_pathway_with_stops!(id) do
    pathway = Repo.get!(Pathway, id)

    from_stop =
      get_stop_by_stop_id(pathway.organization_id, pathway.gtfs_version_id, pathway.from_stop_id)

    to_stop =
      get_stop_by_stop_id(pathway.organization_id, pathway.gtfs_version_id, pathway.to_stop_id)

    %{pathway | from_stop: from_stop, to_stop: to_stop}
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

  # Agency functions

  @doc """
  Returns the count of agencies for an organization and GTFS version.
  """
  def count_agencies(organization_id, gtfs_version_id) do
    from(a in Agency,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of agencies for an organization and GTFS version.
  """
  def list_agencies(organization_id, gtfs_version_id) do
    from(a in Agency,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: a.agency_name]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single agency by UUID.
  """
  def get_agency!(id), do: Repo.get!(Agency, id)

  @doc """
  Gets an agency by its agency_id within an organization and GTFS version.
  """
  def get_agency_by_agency_id(organization_id, gtfs_version_id, agency_id) do
    from(a in Agency,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
          a.agency_id == ^agency_id
    )
    |> Repo.one()
  end

  @doc """
  Creates an agency.

  ## Examples

      iex> create_agency(%{organization_id: org_id, gtfs_version_id: version_id, agency_name: "Transit Agency"})
      {:ok, %Agency{}}

      iex> create_agency(%{agency_name: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_agency(attrs \\ %{}) do
    %Agency{}
    |> Agency.changeset(attrs)
    |> Repo.insert()
  end

  # Area functions

  @doc """
  Returns the list of areas for an organization and GTFS version.
  """
  def list_areas(organization_id, gtfs_version_id) do
    from(a in Area,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: a.area_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single area by UUID.
  """
  def get_area!(id), do: Repo.get!(Area, id)

  @doc """
  Gets an area by its area_id within an organization and GTFS version.
  """
  def get_area_by_area_id(organization_id, gtfs_version_id, area_id) do
    from(a in Area,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
          a.area_id == ^area_id
    )
    |> Repo.one()
  end

  # Attribution functions

  @doc """
  Returns the count of attributions for an organization and GTFS version.
  """
  def count_attributions(organization_id, gtfs_version_id) do
    from(a in Attribution,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of attributions for an organization and GTFS version.
  """
  def list_attributions(organization_id, gtfs_version_id) do
    from(a in Attribution,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single attribution by UUID.
  """
  def get_attribution!(id), do: Repo.get!(Attribution, id)

  # BookingRule functions

  @doc """
  Returns the list of booking rules for an organization and GTFS version.
  """
  def list_booking_rules(organization_id, gtfs_version_id) do
    from(b in BookingRule,
      where: b.organization_id == ^organization_id and b.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: b.booking_rule_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single booking rule by UUID.
  """
  def get_booking_rule!(id), do: Repo.get!(BookingRule, id)

  @doc """
  Gets a booking rule by its booking_rule_id within an organization and GTFS version.
  """
  def get_booking_rule_by_booking_rule_id(organization_id, gtfs_version_id, booking_rule_id) do
    from(b in BookingRule,
      where:
        b.organization_id == ^organization_id and b.gtfs_version_id == ^gtfs_version_id and
          b.booking_rule_id == ^booking_rule_id
    )
    |> Repo.one()
  end

  # FareAttribute functions

  @doc """
  Returns the count of fare attributes for an organization and GTFS version.
  """
  def count_fare_attributes(organization_id, gtfs_version_id) do
    from(f in FareAttribute,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of fare attributes for an organization and GTFS version.
  """
  def list_fare_attributes(organization_id, gtfs_version_id) do
    from(f in FareAttribute,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.fare_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare attribute by UUID.
  """
  def get_fare_attribute!(id), do: Repo.get!(FareAttribute, id)

  @doc """
  Gets a fare attribute by its fare_id within an organization and GTFS version.
  """
  def get_fare_attribute_by_fare_id(organization_id, gtfs_version_id, fare_id) do
    from(f in FareAttribute,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
          f.fare_id == ^fare_id
    )
    |> Repo.one()
  end

  # FareLegJoinRule functions

  @doc """
  Returns the list of fare leg join rules for an organization and GTFS version.
  """
  def list_fare_leg_join_rules(organization_id, gtfs_version_id) do
    from(f in FareLegJoinRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare leg join rule by UUID.
  """
  def get_fare_leg_join_rule!(id), do: Repo.get!(FareLegJoinRule, id)

  # FareLegRule functions

  @doc """
  Returns the list of fare leg rules for an organization and GTFS version.
  """
  def list_fare_leg_rules(organization_id, gtfs_version_id) do
    from(f in FareLegRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare leg rule by UUID.
  """
  def get_fare_leg_rule!(id), do: Repo.get!(FareLegRule, id)

  # FareMedia functions

  @doc """
  Returns the list of fare media for an organization and GTFS version.
  """
  def list_fare_media(organization_id, gtfs_version_id) do
    from(f in FareMedia,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.fare_media_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare media by UUID.
  """
  def get_fare_media!(id), do: Repo.get!(FareMedia, id)

  @doc """
  Gets a fare media by its fare_media_id within an organization and GTFS version.
  """
  def get_fare_media_by_fare_media_id(organization_id, gtfs_version_id, fare_media_id) do
    from(f in FareMedia,
      where:
        f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
          f.fare_media_id == ^fare_media_id
    )
    |> Repo.one()
  end

  # FareProduct functions

  @doc """
  Returns the list of fare products for an organization and GTFS version.
  """
  def list_fare_products(organization_id, gtfs_version_id) do
    from(f in FareProduct,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.fare_product_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare product by UUID.
  """
  def get_fare_product!(id), do: Repo.get!(FareProduct, id)

  # FareRule functions

  @doc """
  Returns the count of fare rules for an organization and GTFS version.
  """
  def count_fare_rules(organization_id, gtfs_version_id) do
    from(f in FareRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of fare rules for an organization and GTFS version.
  """
  def list_fare_rules(organization_id, gtfs_version_id) do
    from(f in FareRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare rule by UUID.
  """
  def get_fare_rule!(id), do: Repo.get!(FareRule, id)

  # FareTransferRule functions

  @doc """
  Returns the list of fare transfer rules for an organization and GTFS version.
  """
  def list_fare_transfer_rules(organization_id, gtfs_version_id) do
    from(f in FareTransferRule,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  @doc """
  Gets a single fare transfer rule by UUID.
  """
  def get_fare_transfer_rule!(id), do: Repo.get!(FareTransferRule, id)

  # FeedInfo functions

  @doc """
  Returns the count of feed info for an organization and GTFS version.
  """
  def count_feed_info(organization_id, gtfs_version_id) do
    from(f in FeedInfo,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the feed info for an organization and GTFS version.
  """
  def get_feed_info(organization_id, gtfs_version_id) do
    from(f in FeedInfo,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.one()
  end

  @doc """
  Gets a single feed info by UUID.
  """
  def get_feed_info!(id), do: Repo.get!(FeedInfo, id)

  # Frequency functions

  @doc """
  Returns the count of frequencies for an organization and GTFS version.
  """
  def count_frequencies(organization_id, gtfs_version_id) do
    from(f in Frequency,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of frequencies for an organization and GTFS version.
  """
  def list_frequencies(organization_id, gtfs_version_id) do
    from(f in Frequency,
      where: f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: f.trip_id, asc: f.start_time]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single frequency by UUID.
  """
  def get_frequency!(id), do: Repo.get!(Frequency, id)

  # Location functions

  @doc """
  Returns the list of locations for an organization and GTFS version.
  """
  def list_locations(organization_id, gtfs_version_id) do
    from(l in Location,
      where: l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: l.location_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single location by UUID.
  """
  def get_location!(id), do: Repo.get!(Location, id)

  @doc """
  Gets a location by its location_id within an organization and GTFS version.
  """
  def get_location_by_location_id(organization_id, gtfs_version_id, location_id) do
    from(l in Location,
      where:
        l.organization_id == ^organization_id and l.gtfs_version_id == ^gtfs_version_id and
          l.location_id == ^location_id
    )
    |> Repo.one()
  end

  # Network functions

  @doc """
  Returns the list of networks for an organization and GTFS version.
  """
  def list_networks(organization_id, gtfs_version_id) do
    from(n in Network,
      where: n.organization_id == ^organization_id and n.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: n.network_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single network by UUID.
  """
  def get_network!(id), do: Repo.get!(Network, id)

  @doc """
  Gets a network by its network_id within an organization and GTFS version.
  """
  def get_network_by_network_id(organization_id, gtfs_version_id, network_id) do
    from(n in Network,
      where:
        n.organization_id == ^organization_id and n.gtfs_version_id == ^gtfs_version_id and
          n.network_id == ^network_id
    )
    |> Repo.one()
  end

  # RiderCategory functions

  @doc """
  Returns the list of rider categories for an organization and GTFS version.
  """
  def list_rider_categories(organization_id, gtfs_version_id) do
    from(r in RiderCategory,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: r.rider_category_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single rider category by UUID.
  """
  def get_rider_category!(id), do: Repo.get!(RiderCategory, id)

  @doc """
  Gets a rider category by its rider_category_id within an organization and GTFS version.
  """
  def get_rider_category_by_rider_category_id(organization_id, gtfs_version_id, rider_category_id) do
    from(r in RiderCategory,
      where:
        r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
          r.rider_category_id == ^rider_category_id
    )
    |> Repo.one()
  end

  # RouteNetwork functions

  @doc """
  Returns the list of route networks for an organization and GTFS version.
  """
  def list_route_networks(organization_id, gtfs_version_id) do
    from(r in RouteNetwork,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: r.network_id, asc: r.route_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single route network by UUID.
  """
  def get_route_network!(id), do: Repo.get!(RouteNetwork, id)

  # Shape functions

  @doc """
  Returns the count of shapes for an organization and GTFS version.
  """
  def count_shapes(organization_id, gtfs_version_id) do
    from(s in Shape,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of shapes for an organization and GTFS version.
  """
  def list_shapes(organization_id, gtfs_version_id) do
    from(s in Shape,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.shape_id, asc: s.shape_pt_sequence]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single shape by UUID.
  """
  def get_shape!(id), do: Repo.get!(Shape, id)

  # StopArea functions

  @doc """
  Returns the list of stop areas for an organization and GTFS version.
  """
  def list_stop_areas(organization_id, gtfs_version_id) do
    from(s in StopArea,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: s.area_id, asc: s.stop_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single stop area by UUID.
  """
  def get_stop_area!(id), do: Repo.get!(StopArea, id)

  # Timeframe functions

  @doc """
  Returns the list of timeframes for an organization and GTFS version.
  """
  def list_timeframes(organization_id, gtfs_version_id) do
    from(t in Timeframe,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.timeframe_group_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single timeframe by UUID.
  """
  def get_timeframe!(id), do: Repo.get!(Timeframe, id)

  # Transfer functions

  @doc """
  Returns the count of transfers for an organization and GTFS version.
  """
  def count_transfers(organization_id, gtfs_version_id) do
    from(t in Transfer,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of transfers for an organization and GTFS version.
  """
  def list_transfers(organization_id, gtfs_version_id) do
    from(t in Transfer,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.from_stop_id, asc: t.to_stop_id]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single transfer by UUID.
  """
  def get_transfer!(id), do: Repo.get!(Transfer, id)

  # Translation functions

  @doc """
  Returns the list of translations for an organization and GTFS version.
  """
  def list_translations(organization_id, gtfs_version_id) do
    from(t in Translation,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id,
      order_by: [asc: t.table_name, asc: t.field_name, asc: t.language]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single translation by UUID.
  """
  def get_translation!(id), do: Repo.get!(Translation, id)

  # Trip functions

  @doc """
  Returns the count of trips for an organization and GTFS version.
  """
  def count_trips(organization_id, gtfs_version_id) do
    from(t in Trip,
      where: t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Creates a trip.
  """
  def create_trip(attrs \\ %{}) do
    %Trip{}
    |> Trip.changeset(attrs)
    |> Repo.insert()
  end

  # StopTime functions

  @doc """
  Returns the count of stop times for an organization and GTFS version.
  """
  def count_stop_times(organization_id, gtfs_version_id) do
    from(s in StopTime,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Creates a stop time.
  """
  def create_stop_time(attrs \\ %{}) do
    %StopTime{}
    |> StopTime.changeset(attrs)
    |> Repo.insert()
  end

  # Calendar functions

  @doc """
  Returns the count of calendars for an organization and GTFS version.
  """
  def count_calendars(organization_id, gtfs_version_id) do
    from(c in Calendar,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  # CalendarDate functions

  @doc """
  Returns the count of calendar dates for an organization and GTFS version.
  """
  def count_calendar_dates(organization_id, gtfs_version_id) do
    from(c in CalendarDate,
      where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.aggregate(:count)
  end

  def get_file_inventory(organization_id, gtfs_version_id, export_type) do
    if export_type == :pathways do
      [
        {"stops.txt", count_stops(organization_id, gtfs_version_id)},
        {"levels.txt", count_levels(organization_id, gtfs_version_id)},
        {"pathways.txt", count_pathways(organization_id, gtfs_version_id)}
      ]
    else
      [
        {"agency.txt", count_agencies(organization_id, gtfs_version_id)},
        {"stops.txt", count_stops(organization_id, gtfs_version_id)},
        {"routes.txt", count_routes(organization_id, gtfs_version_id)},
        {"trips.txt", count_trips(organization_id, gtfs_version_id)},
        {"stop_times.txt", count_stop_times(organization_id, gtfs_version_id)},
        {"calendar.txt", count_calendars(organization_id, gtfs_version_id)},
        {"calendar_dates.txt", count_calendar_dates(organization_id, gtfs_version_id)},
        {"fare_attributes.txt", count_fare_attributes(organization_id, gtfs_version_id)},
        {"fare_rules.txt", count_fare_rules(organization_id, gtfs_version_id)},
        {"shapes.txt", count_shapes(organization_id, gtfs_version_id)},
        {"frequencies.txt", count_frequencies(organization_id, gtfs_version_id)},
        {"transfers.txt", count_transfers(organization_id, gtfs_version_id)},
        {"pathways.txt", count_pathways(organization_id, gtfs_version_id)},
        {"levels.txt", count_levels(organization_id, gtfs_version_id)},
        {"feed_info.txt", count_feed_info(organization_id, gtfs_version_id)},
        {"attributions.txt", count_attributions(organization_id, gtfs_version_id)}
      ]
    end
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

  defp maybe_filter_wheelchair(query, nil), do: query
  defp maybe_filter_wheelchair(query, ""), do: query

  defp maybe_filter_wheelchair(query, wheelchair_boarding) do
    where(query, [s], s.wheelchair_boarding == ^wheelchair_boarding)
  end

  defp maybe_filter_location_type(query, nil), do: query
  defp maybe_filter_location_type(query, ""), do: query

  defp maybe_filter_location_type(query, location_type) do
    where(query, [s], s.location_type == ^location_type)
  end

  defp maybe_filter_route(query, nil, _organization_id, _gtfs_version_id), do: query
  defp maybe_filter_route(query, "", _organization_id, _gtfs_version_id), do: query

  defp maybe_filter_route(query, route_id, organization_id, gtfs_version_id) do
    # Step 1: Get representative trip_ids from route_patterns (typically 2-4 trips)
    # This is much faster than scanning all trips for a route
    representative_trip_ids =
      from(rp in RoutePattern,
        where:
          rp.route_id == ^route_id and
            rp.organization_id == ^organization_id and
            rp.gtfs_version_id == ^gtfs_version_id and
            not is_nil(rp.representative_trip_id),
        select: rp.representative_trip_id
      )
      |> Repo.all()

    # Step 2: Get stop_ids using route_patterns (fast) or all trips (fallback)
    stop_ids =
      if representative_trip_ids != [] do
        # Fast path: Query only 2-4 representative trips
        from(st in StopTime,
          where:
            st.trip_id in ^representative_trip_ids and
              st.organization_id == ^organization_id and
              st.gtfs_version_id == ^gtfs_version_id,
          distinct: true,
          select: st.stop_id
        )
        |> Repo.all()
      else
        # Fallback: For data without route_patterns, query all trips
        from(st in StopTime,
          join: t in Trip,
          on:
            st.trip_id == t.trip_id and
              st.organization_id == t.organization_id and
              st.gtfs_version_id == t.gtfs_version_id,
          where:
            t.route_id == ^route_id and
              t.organization_id == ^organization_id and
              t.gtfs_version_id == ^gtfs_version_id,
          distinct: true,
          select: st.stop_id
        )
        |> Repo.all()
      end

    # Step 3: Filter stops using IN clause (efficient with index)
    where(query, [s], s.stop_id in ^stop_ids)
  end

  defp maybe_filter_direction(query, nil, _organization_id, _gtfs_version_id), do: query
  defp maybe_filter_direction(query, "", _organization_id, _gtfs_version_id), do: query

  defp maybe_filter_direction(query, direction_id, organization_id, gtfs_version_id) do
    # Filter stations by direction_id
    # Find stops that are served by trips with the specified direction_id
    stop_ids =
      from(st in StopTime,
        join: t in Trip,
        on:
          st.trip_id == t.trip_id and
            st.organization_id == t.organization_id and
            st.gtfs_version_id == t.gtfs_version_id,
        where:
          t.direction_id == ^direction_id and
            t.organization_id == ^organization_id and
            t.gtfs_version_id == ^gtfs_version_id,
        distinct: true,
        select: st.stop_id
      )
      |> Repo.all()

    where(query, [s], s.stop_id in ^stop_ids)
  end

  defp maybe_search_stops(query, nil), do: query
  defp maybe_search_stops(query, ""), do: query

  defp maybe_search_stops(query, term) do
    pattern = "%#{term}%"
    where(query, [s], ilike(s.stop_id, ^pattern) or ilike(s.stop_name, ^pattern))
  end

  defp apply_stop_sort(query, sort_by, sort_dir)
       when sort_by in [:stop_id, :stop_name, :location_type] and sort_dir in [:asc, :desc] do
    order_by(query, [s], [{^sort_dir, field(s, ^sort_by)}])
  end

  defp apply_stop_sort(query, _sort_by, _sort_dir) do
    order_by(query, [s], asc: s.stop_name)
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

  defp delete_pathways_for_stop_multi(multi, organization_id, gtfs_version_id, stop_id) do
    pathway_query =
      from(p in Pathway,
        where:
          p.organization_id == ^organization_id and
            p.gtfs_version_id == ^gtfs_version_id and
            (p.from_stop_id == ^stop_id or p.to_stop_id == ^stop_id)
      )

    Ecto.Multi.delete_all(multi, :pathways, pathway_query)
  end

  # ============================================================================
  # Station Naming
  # ============================================================================

  @doc """
  Builds a preview of the station naming convention without writing.

  When `selected_ids` is provided, the preview rows, collision checks, and updated
  reference counts are limited to that subset while preserving the naming derived
  from the full station descendant set.

  Returns
  `{:ok, %{rows: [...], renamed_stops_count: n, updated_pathways_count: n, updated_references_count: n}}`
  or `{:error, reason}`.
  """
  def preview_station_naming(organization_id, gtfs_version_id, station_stop_id),
    do:
      preview_station_naming(organization_id, gtfs_version_id, station_stop_id, :structured, nil)

  def preview_station_naming(organization_id, gtfs_version_id, station_stop_id, style),
    do: preview_station_naming(organization_id, gtfs_version_id, station_stop_id, style, nil)

  def preview_station_naming(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        style,
        selected_ids
      ) do
    descendant_ids = descendant_stop_ids_query(organization_id, gtfs_version_id, station_stop_id)

    child_stops =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id in subquery(descendant_ids) and
            s.location_type in [0, 2, 3, 4],
        order_by: [asc: s.stop_id]
      )
      |> Repo.all()

    case child_stops do
      [] ->
        {:error, :no_stops}

      _ ->
        child_stop_ids = Enum.map(child_stops, & &1.stop_id)

        pathways =
          from(p in Pathway,
            where:
              p.organization_id == ^organization_id and
                p.gtfs_version_id == ^gtfs_version_id and
                (p.from_stop_id in ^child_stop_ids or p.to_stop_id in ^child_stop_ids)
          )
          |> Repo.all()

        naming_map =
          case style do
            :kebab -> StationNaming.build_kebab_naming_map(child_stops)
            _structured -> StationNaming.build_naming_map(child_stops, pathways, station_stop_id)
          end

        rows =
          if selected_ids do
            Enum.filter(naming_map, fn %{old_id: old_id} ->
              MapSet.member?(selected_ids, old_id)
            end)
          else
            naming_map
          end

        old_id_set = MapSet.new(rows, & &1.old_id)

        # Query only candidate new IDs (excluding IDs that are being renamed in this operation).
        candidate_new_ids =
          rows
          |> Enum.map(& &1.new_id)
          |> MapSet.new()
          |> MapSet.difference(old_id_set)
          |> MapSet.to_list()

        existing_ids =
          case candidate_new_ids do
            [] ->
              MapSet.new()

            _ ->
              from(s in Stop,
                where:
                  s.organization_id == ^organization_id and
                    s.gtfs_version_id == ^gtfs_version_id and
                    s.stop_id in ^candidate_new_ids,
                select: s.stop_id
              )
              |> Repo.all()
              |> MapSet.new()
          end

        case rows do
          [] ->
            {:error, :no_stops}

          _ ->
            case StationNaming.detect_collisions(rows, existing_ids) do
              [] ->
                reference_counts =
                  count_stop_id_references(organization_id, gtfs_version_id, old_id_set)

                {:ok,
                 %{
                   rows: rows,
                   renamed_stops_count: length(rows),
                   updated_pathways_count: reference_counts.pathways,
                   updated_references_count: reference_counts.total
                 }}

              collisions ->
                {:error, {:naming_collision, collisions}}
            end
        end
    end
  end

  @doc """
  Applies the station naming convention transactionally.

  Performs a two-phase rename to avoid transient ID collisions:
  1) child stop IDs old -> temporary IDs
  2) references old -> temporary
  3) child stop IDs temporary -> final IDs
  4) references temporary -> final IDs

  When `selected_ids` is provided via `apply_station_naming/5`, only that subset
  of previewed child stops is renamed. Passing an empty `MapSet` is a no-op and
  returns zero updated counts.

  Returns `{:ok, %{renamed_stops: n, updated_pathways: n, updated_references: n}}`
  or `{:error, reason}`.
  """
  def apply_station_naming(organization_id, gtfs_version_id, station_stop_id),
    do:
      do_apply_station_naming(organization_id, gtfs_version_id, station_stop_id, :structured, nil)

  def apply_station_naming(organization_id, gtfs_version_id, station_stop_id, style),
    do: do_apply_station_naming(organization_id, gtfs_version_id, station_stop_id, style, nil)

  def apply_station_naming(
        organization_id,
        gtfs_version_id,
        station_stop_id,
        style,
        selected_ids
      ),
      do:
        do_apply_station_naming(
          organization_id,
          gtfs_version_id,
          station_stop_id,
          style,
          selected_ids
        )

  defp do_apply_station_naming(
         organization_id,
         gtfs_version_id,
         station_stop_id,
         style,
         selected_ids
       ) do
    case preview_station_naming(
           organization_id,
           gtfs_version_id,
           station_stop_id,
           style,
           selected_ids
         ) do
      {:ok, preview} ->
        old_to_new = Map.new(preview.rows, fn %{old_id: old, new_id: new} -> {old, new} end)
        old_to_temp = build_temp_stop_id_map(preview.rows)

        temp_to_new =
          Map.new(old_to_temp, fn {old_id, temp_id} ->
            {temp_id, Map.fetch!(old_to_new, old_id)}
          end)

        now = DateTime.utc_now()

        multi =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:rename_stops_to_temp, fn repo, _changes ->
            {:ok,
             update_stop_field_values(
               repo,
               :stop_id,
               old_to_temp,
               organization_id,
               gtfs_version_id,
               now
             )}
          end)
          |> Ecto.Multi.run(:update_refs_to_temp, fn repo, _changes ->
            {:ok,
             update_stop_id_references(
               repo,
               old_to_temp,
               organization_id,
               gtfs_version_id,
               now
             )}
          end)
          |> Ecto.Multi.run(:rename_stops_to_final, fn repo, _changes ->
            {:ok,
             update_stop_field_values(
               repo,
               :stop_id,
               temp_to_new,
               organization_id,
               gtfs_version_id,
               now
             )}
          end)
          |> Ecto.Multi.run(:update_refs_to_final, fn repo, _changes ->
            {:ok,
             update_stop_id_references(
               repo,
               temp_to_new,
               organization_id,
               gtfs_version_id,
               now
             )}
          end)

        case Repo.transaction(multi) do
          {:ok, %{rename_stops_to_final: renamed, update_refs_to_final: refs}} ->
            {:ok,
             %{
               renamed_stops: renamed,
               updated_pathways: refs.pathways,
               updated_references: refs.total
             }}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end

      {:error, :no_stops} when is_struct(selected_ids, MapSet) ->
        {:ok, %{renamed_stops: 0, updated_pathways: 0, updated_references: 0}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_temp_stop_id_map(rows) do
    Map.new(rows, fn %{old_id: old_id} ->
      {old_id, "__tmp_station_naming_#{Ecto.UUID.generate()}_#{Stop.slugify(old_id)}"}
    end)
  end

  defp count_stop_id_references(organization_id, gtfs_version_id, stop_ids) do
    stop_id_list = MapSet.to_list(stop_ids)

    if stop_id_list == [] do
      empty_stop_id_reference_counts()
    else
      pathways_from =
        from(p in Pathway,
          where:
            p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id and
              p.from_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      pathways_to =
        from(p in Pathway,
          where:
            p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id and
              p.to_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      stop_times =
        from(st in StopTime,
          where:
            st.organization_id == ^organization_id and st.gtfs_version_id == ^gtfs_version_id and
              st.stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      transfers_from =
        from(t in Transfer,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
              t.from_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      transfers_to =
        from(t in Transfer,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
              t.to_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      stop_areas =
        from(sa in StopArea,
          where:
            sa.organization_id == ^organization_id and
              sa.gtfs_version_id == ^gtfs_version_id and
              sa.stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      fare_leg_join_rules_from =
        from(fl in FareLegJoinRule,
          where:
            fl.organization_id == ^organization_id and
              fl.gtfs_version_id == ^gtfs_version_id and
              fl.from_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      fare_leg_join_rules_to =
        from(fl in FareLegJoinRule,
          where:
            fl.organization_id == ^organization_id and
              fl.gtfs_version_id == ^gtfs_version_id and
              fl.to_stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      parent_stations =
        from(s in Stop,
          where:
            s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
              s.parent_station in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      translations =
        from(t in Translation,
          where:
            t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
              t.table_name == "stops" and t.record_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      walkability_tests =
        from(wt in WalkabilityTest,
          where:
            wt.organization_id == ^organization_id and
              wt.gtfs_version_id == ^gtfs_version_id and
              wt.stop_id in ^stop_id_list
        )
        |> Repo.aggregate(:count)

      %{
        pathways: pathways_from + pathways_to,
        stop_times: stop_times,
        transfers: transfers_from + transfers_to,
        stop_areas: stop_areas,
        fare_leg_join_rules: fare_leg_join_rules_from + fare_leg_join_rules_to,
        parent_stations: parent_stations,
        translations: translations,
        walkability_tests: walkability_tests
      }
      |> with_total_stop_id_reference_counts()
    end
  end

  defp update_level_id_references(repo, mapping, organization_id, gtfs_version_id, now) do
    stops =
      update_stop_field_values(repo, :level_id, mapping, organization_id, gtfs_version_id, now)

    translations =
      mapping
      |> Enum.reduce(0, fn {old_id, new_id}, count ->
        {updated_count, _} =
          from(t in Translation,
            where:
              t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
                t.table_name == "levels" and t.record_id == ^old_id
          )
          |> repo.update_all(set: [record_id: new_id, updated_at: now])

        count + updated_count
      end)

    %{stops: stops, translations: translations}
  end

  defp update_stop_id_references(repo, mapping, organization_id, gtfs_version_id, now) do
    pathways_from =
      update_schema_field_values(
        repo,
        Pathway,
        :from_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    pathways_to =
      update_schema_field_values(
        repo,
        Pathway,
        :to_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    stop_times =
      update_schema_field_values(
        repo,
        StopTime,
        :stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    transfers_from =
      update_schema_field_values(
        repo,
        Transfer,
        :from_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    transfers_to =
      update_schema_field_values(
        repo,
        Transfer,
        :to_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    stop_areas =
      update_schema_field_values(
        repo,
        StopArea,
        :stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    fare_leg_join_rules_from =
      update_schema_field_values(
        repo,
        FareLegJoinRule,
        :from_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    fare_leg_join_rules_to =
      update_schema_field_values(
        repo,
        FareLegJoinRule,
        :to_stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    parent_stations =
      update_stop_field_values(
        repo,
        :parent_station,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    translations =
      mapping
      |> Enum.reduce(0, fn {old_id, new_id}, count ->
        {updated_count, _} =
          from(t in Translation,
            where:
              t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
                t.table_name == "stops" and t.record_id == ^old_id
          )
          |> repo.update_all(set: [record_id: new_id, updated_at: now])

        count + updated_count
      end)

    walkability_tests =
      update_schema_field_values(
        repo,
        WalkabilityTest,
        :stop_id,
        mapping,
        organization_id,
        gtfs_version_id,
        now
      )

    %{
      pathways: pathways_from + pathways_to,
      stop_times: stop_times,
      transfers: transfers_from + transfers_to,
      stop_areas: stop_areas,
      fare_leg_join_rules: fare_leg_join_rules_from + fare_leg_join_rules_to,
      parent_stations: parent_stations,
      translations: translations,
      walkability_tests: walkability_tests
    }
    |> with_total_stop_id_reference_counts()
  end

  defp update_stop_field_values(repo, field, mapping, organization_id, gtfs_version_id, now) do
    mapping
    |> Enum.reduce(0, fn {old_id, new_id}, count ->
      {updated_count, _} =
        from(s in Stop,
          where:
            s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
              field(s, ^field) == ^old_id
        )
        |> repo.update_all(set: [{field, new_id}, {:updated_at, now}])

      count + updated_count
    end)
  end

  defp update_schema_field_values(
         repo,
         schema,
         field,
         mapping,
         organization_id,
         gtfs_version_id,
         now
       ) do
    mapping
    |> Enum.reduce(0, fn {old_id, new_id}, count ->
      {updated_count, _} =
        from(row in schema,
          where:
            row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
              field(row, ^field) == ^old_id
        )
        |> repo.update_all(set: [{field, new_id}, {:updated_at, now}])

      count + updated_count
    end)
  end

  defp with_total_stop_id_reference_counts(counts) do
    Map.put(counts, :total, Enum.sum(Map.values(counts)))
  end

  defp empty_stop_id_reference_counts do
    %{
      pathways: 0,
      stop_times: 0,
      transfers: 0,
      stop_areas: 0,
      fare_leg_join_rules: 0,
      parent_stations: 0,
      translations: 0,
      walkability_tests: 0,
      total: 0
    }
  end

  defp broadcast({:ok, result}, event_topic) do
    broadcast_result =
      case event_topic do
        [:levels, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "levels", {event_topic, result})

        [:stops, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "stops", {event_topic, result})

        [:pathways, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "pathways", {event_topic, result})

        [:stop_levels, _] ->
          Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, "stop_levels", {event_topic, result})
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

  # ============================================================================
  # Change Log / Audit
  # ============================================================================

  @doc """
  Records a change log entry for a mutation.

  `entity_or_nil` is the entity before the mutation (nil for creates).
  `action` is "created", "updated", or "deleted".
  `attrs` is the attribute map being applied (used to compute changed_fields for "updated").

  Returns `:ok` — failures are logged to Logger and the mutation proceeds normally.
  """
  @spec record_change(AuditContext.t(), atom(), struct() | nil, String.t(), map()) :: :ok
  def record_change(%AuditContext{} = ctx, entity_type, entity_or_nil, action, attrs \\ %{}) do
    snapshot = build_snapshot(entity_type, entity_or_nil)
    changed_fields_attrs = changed_fields_attrs(action, entity_type, attrs)
    changed_fields = build_changed_fields(action, snapshot, changed_fields_attrs)

    entity_external_id = entity_external_id_for(entity_type, entity_or_nil, attrs)
    entity_id = entity_id_for(entity_or_nil)

    %ChangeLog{}
    |> ChangeLog.changeset(%{
      entity_type: Atom.to_string(entity_type),
      entity_id: entity_id,
      entity_external_id: entity_external_id,
      station_stop_id: ctx.station_stop_id,
      actor_id: ctx.actor_id,
      actor_email: ctx.actor_email,
      snapshot: snapshot,
      changed_fields: changed_fields,
      action: action,
      organization_id: ctx.organization_id,
      gtfs_version_id: ctx.gtfs_version_id
    })
    |> Repo.insert()
    |> then(fn
      {:ok, _log} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to insert change_log: #{inspect(changeset.errors)}")
        :ok
    end)
  end

  defp changed_fields_attrs("updated", entity_type, attrs),
    do: reversible_attrs_for(entity_type, attrs)

  defp changed_fields_attrs(_action, _entity_type, attrs), do: attrs

  @doc """
  Returns change log entries for a specific entity, most recent first.
  """
  def list_change_logs_for_entity(organization_id, gtfs_version_id, entity_type, entity_id) do
    from(cl in ChangeLog,
      where:
        cl.organization_id == ^organization_id and
          cl.gtfs_version_id == ^gtfs_version_id and
          cl.entity_type == ^entity_type and
          cl.entity_id == ^entity_id,
      order_by: [desc: cl.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single change log entry.

  Raises `Ecto.NoResultsError` if the entry does not exist.
  """
  def get_change_log!(id), do: Repo.get!(ChangeLog, id)

  @doc """
  Gets a single change log entry, returning `nil` if it does not exist.
  """
  def get_change_log(id), do: Repo.get(ChangeLog, id)

  @doc """
  Returns the list of identity field names (as strings) for an entity type.

  Identity fields are preserved across rollback and excluded from rollback diffs.
  """
  def identity_fields_for("stop"), do: ~w(stop_id)
  def identity_fields_for("pathway"), do: ~w(pathway_id from_stop_id to_stop_id)
  def identity_fields_for("level"), do: ~w(level_id)

  @doc """
  Returns the list of reversible field names (as strings) for an entity type.
  """
  @spec reversible_fields_for(String.t() | atom()) :: [String.t()]
  def reversible_fields_for(:stop), do: reversible_fields_for("stop")

  def reversible_fields_for("stop"),
    do: ~w(
        stop_name
        stop_desc
        stop_lat
        stop_lon
        location_type
        wheelchair_boarding
        platform_code
        diagram_coordinate
        parent_station
        level_id
      )

  def reversible_fields_for(:pathway), do: reversible_fields_for("pathway")

  def reversible_fields_for("pathway"),
    do: ~w(
        pathway_mode
        is_bidirectional
        traversal_time
        length
        stair_count
        max_slope
        min_width
        signposted_as
        reversed_signposted_as
        field_notes
        field_completed_at
      )

  def reversible_fields_for(:level), do: reversible_fields_for("level")
  def reversible_fields_for("level"), do: ~w(level_name level_index)

  @doc """
  Builds a normalized snapshot map for a stop, pathway, or level entity.

  Used by rollback preview to compare a current entity against a stored snapshot
  with equivalent value normalization (e.g. Decimal → string).
  """
  def entity_snapshot(entity_type, entity), do: build_snapshot(entity_type, entity)

  @doc """
  Rolls back a stop, pathway, or level to the state captured in a change log entry.

  Only works for "updated" entries. Produces a new "rolled_back" change log entry
  attributed to `audit_ctx`. Identity fields (stop_id, pathway_id, level_id,
  from_stop_id, to_stop_id) are preserved.

  Returns `{:ok, entity}` or `{:error, reason}`.
  """
  @spec rollback_entity(ChangeLog.t(), AuditContext.t()) ::
          {:ok, Stop.t() | Pathway.t() | Level.t()} | {:error, atom()}
  def rollback_entity(%ChangeLog{} = log, %AuditContext{} = audit_ctx)
      when audit_ctx.organization_id != log.organization_id or
             audit_ctx.gtfs_version_id != log.gtfs_version_id do
    {:error, :unauthorized}
  end

  def rollback_entity(%ChangeLog{} = log, %AuditContext{} = audit_ctx) do
    with {:ok, target_snapshot} <- rollback_target_snapshot(log),
         {:ok, entity} <- rollback_entity_for_log(log),
         :ok <- ensure_rollback_changes_entity(log.entity_type, entity, target_snapshot) do
      update_attrs = snapshot_to_update_attrs(log.entity_type, target_snapshot)
      rollback_entity_transaction(update_attrs, log, audit_ctx, entity)
    end
  end

  @doc """
  Calculates the snapshot an entity should be restored to for a rollback.
  """
  @spec rollback_target_snapshot(ChangeLog.t()) :: {:ok, map()} | {:error, atom()}
  def rollback_target_snapshot(%ChangeLog{action: action})
      when action in ["created", "deleted"] do
    {:error, :cannot_rollback_create_or_delete}
  end

  def rollback_target_snapshot(%ChangeLog{action: action, snapshot: nil})
      when action in ["updated", "rolled_back"] do
    {:error, :missing_rollback_snapshot}
  end

  def rollback_target_snapshot(%ChangeLog{
        action: action,
        entity_type: entity_type,
        snapshot: snapshot,
        changed_fields: changed_fields
      })
      when action in ["updated", "rolled_back"] do
    target_snapshot =
      snapshot
      |> fill_snapshot_from_changed_fields(changed_fields)
      |> then(&sanitize_rollback_snapshot(entity_type, &1))

    {:ok, target_snapshot}
  end

  @doc """
  Returns changed field names that can be previewed and applied by rollback.
  """
  @spec rollback_previewable_fields(ChangeLog.t()) :: [String.t()]
  def rollback_previewable_fields(%ChangeLog{} = log) do
    changed_field_names =
      log.changed_fields
      |> Kernel.||(%{})
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    reversible_field_names =
      log.entity_type
      |> reversible_fields_for()
      |> MapSet.new()

    changed_field_names
    |> MapSet.intersection(reversible_field_names)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp update_entity_without_broadcast(%Stop{} = stop, attrs) do
    stop
    |> Stop.changeset(attrs)
    |> Repo.update()
  end

  defp update_entity_without_broadcast(%Pathway{} = pathway, attrs) do
    pathway
    |> Pathway.changeset(attrs)
    |> Repo.update()
  end

  defp update_entity_without_broadcast(%Level{} = level, attrs) do
    level
    |> Level.changeset(attrs)
    |> Repo.update()
  end

  defp broadcast_topic_for(%Stop{}), do: [:stops, :updated]
  defp broadcast_topic_for(%Pathway{}), do: [:pathways, :updated]
  defp broadcast_topic_for(%Level{}), do: [:levels, :updated]

  # -- Snapshot helpers --

  defp build_snapshot(_entity_type, nil), do: nil

  defp build_snapshot(:stop, %Stop{} = stop), do: snapshot_stop(stop)
  defp build_snapshot(:pathway, %Pathway{} = pw), do: snapshot_pathway(pw)
  defp build_snapshot(:level, %Level{} = level), do: snapshot_level(level)
  defp build_snapshot("stop", %Stop{} = stop), do: snapshot_stop(stop)
  defp build_snapshot("pathway", %Pathway{} = pw), do: snapshot_pathway(pw)
  defp build_snapshot("level", %Level{} = level), do: snapshot_level(level)
  defp build_snapshot(_, _), do: nil

  defp snapshot_stop(stop) do
    %{
      stop_name: stop.stop_name,
      stop_desc: stop.stop_desc,
      stop_lat: jsonify(stop.stop_lat),
      stop_lon: jsonify(stop.stop_lon),
      location_type: stop.location_type,
      wheelchair_boarding: stop.wheelchair_boarding,
      platform_code: stop.platform_code,
      diagram_coordinate: stop.diagram_coordinate,
      parent_station: stop.parent_station,
      level_id: stop.level_id
    }
  end

  defp snapshot_pathway(pw) do
    %{
      from_stop_id: pw.from_stop_id,
      to_stop_id: pw.to_stop_id,
      pathway_mode: pw.pathway_mode,
      is_bidirectional: pw.is_bidirectional,
      traversal_time: pw.traversal_time,
      length: jsonify(pw.length),
      stair_count: pw.stair_count,
      max_slope: jsonify(pw.max_slope),
      min_width: jsonify(pw.min_width),
      signposted_as: pw.signposted_as,
      reversed_signposted_as: pw.reversed_signposted_as,
      field_notes: pw.field_notes,
      field_completed_at: jsonify(pw.field_completed_at)
    }
  end

  defp snapshot_level(level) do
    %{level_name: level.level_name, level_index: level.level_index}
  end

  # -- Entity identity helpers --

  defp entity_id_for(nil), do: nil
  defp entity_id_for(%{id: id}), do: id

  defp entity_external_id_for(_entity_type, nil, attrs) do
    cond do
      attrs[:stop_id] -> attrs[:stop_id]
      attrs["stop_id"] -> attrs["stop_id"]
      attrs[:pathway_id] -> attrs[:pathway_id]
      attrs["pathway_id"] -> attrs["pathway_id"]
      attrs[:level_id] -> attrs[:level_id]
      attrs["level_id"] -> attrs["level_id"]
      true -> nil
    end
  end

  defp entity_external_id_for(:stop, %Stop{} = stop, _attrs), do: stop.stop_id
  defp entity_external_id_for(:pathway, %Pathway{} = pw, _attrs), do: pw.pathway_id
  defp entity_external_id_for(:level, %Level{} = level, _attrs), do: level.level_id

  defp entity_module_for("stop"), do: Stop
  defp entity_module_for("pathway"), do: Pathway
  defp entity_module_for("level"), do: Level

  # -- Diff and rollback helpers --

  defp build_changed_fields(action, snapshot, attrs)
       when action == "updated" and not is_nil(snapshot) do
    snapshot_str_keys = stringify_map_keys(snapshot)

    attrs
    |> stringify_map_keys()
    |> Enum.reduce(%{}, fn {field, new_value}, acc ->
      current_value = Map.get(snapshot_str_keys, field)

      if same_value?(current_value, new_value) do
        acc
      else
        Map.put(acc, field, %{
          "from" => normalize_value(current_value),
          "to" => normalize_value(new_value)
        })
      end
    end)
  end

  defp build_changed_fields(_action, _snapshot, _attrs), do: nil

  @spec reversible_attrs_for(String.t() | atom(), map()) :: map()
  defp reversible_attrs_for(entity_type, attrs) when is_map(attrs) do
    change_log_fields = change_log_fields_for(entity_type)

    Map.filter(attrs, fn {key, _value} ->
      to_string(key) in change_log_fields
    end)
  end

  defp change_log_fields_for(:pathway), do: change_log_fields_for("pathway")

  defp change_log_fields_for("pathway"),
    do: reversible_fields_for("pathway") ++ ~w(from_stop_id to_stop_id)

  defp change_log_fields_for(entity_type), do: reversible_fields_for(entity_type)

  defp fill_snapshot_from_changed_fields(snapshot, changed_fields) when is_map(changed_fields) do
    Enum.reduce(changed_fields, snapshot, fn
      {field, %{"from" => from}}, acc ->
        put_missing_snapshot_field(acc, field, from)

      _entry, acc ->
        acc
    end)
  end

  defp fill_snapshot_from_changed_fields(snapshot, _changed_fields), do: snapshot

  @spec sanitize_rollback_snapshot(String.t(), map()) :: map()
  defp sanitize_rollback_snapshot(entity_type, snapshot) when is_map(snapshot) do
    reversible_fields = reversible_fields_for(entity_type)

    Map.filter(snapshot, fn {key, _value} ->
      to_string(key) in reversible_fields
    end)
  end

  defp rollback_entity_for_log(log) do
    case Repo.get(entity_module_for(log.entity_type), log.entity_id) do
      nil -> {:error, :entity_not_found}
      entity -> {:ok, entity}
    end
  end

  defp ensure_rollback_changes_entity(entity_type, entity, target_snapshot) do
    if rollback_would_change_entity?(entity_type, entity, target_snapshot) do
      :ok
    else
      {:error, :already_matches_current}
    end
  end

  defp rollback_entity_transaction(update_attrs, log, audit_ctx, entity) do
    log
    |> rollback_multi(audit_ctx, entity, update_attrs)
    |> Repo.transaction()
    |> handle_rollback_transaction_result(log)
  end

  defp rollback_multi(log, audit_ctx, entity, update_attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:update_entity, fn _repo, _changes ->
      update_entity_without_broadcast(entity, update_attrs)
    end)
    |> Ecto.Multi.run(:rollback_log, fn _repo, _changes ->
      insert_rollback_log(log, audit_ctx, entity, update_attrs)
    end)
  end

  defp handle_rollback_transaction_result({:ok, %{update_entity: updated_entity}}, _log) do
    broadcast({:ok, updated_entity}, broadcast_topic_for(updated_entity))
    {:ok, updated_entity}
  end

  defp handle_rollback_transaction_result(
         {:error, :update_entity, %Ecto.Changeset{} = changeset, _changes},
         log
       ) do
    Logger.error(
      "Rollback update failed change_log_id=#{log.id} entity_type=#{log.entity_type} entity_id=#{log.entity_id} errors=#{inspect(changeset.errors)}"
    )

    {:error, changeset}
  end

  defp handle_rollback_transaction_result({:error, :update_entity, reason, _changes}, _log) do
    {:error, reason}
  end

  defp handle_rollback_transaction_result({:error, :rollback_log, reason, _changes}, _log) do
    Logger.error("Failed to insert rollback change_log: #{inspect(reason)}")
    {:error, :rollback_log_failed}
  end

  defp rollback_would_change_entity?(entity_type, entity, target_snapshot) do
    current_snapshot =
      entity_type
      |> entity_snapshot(entity)
      |> stringify_map_keys()

    identity_fields = identity_fields_for(entity_type)

    target_snapshot
    |> stringify_map_keys()
    |> Map.drop(identity_fields)
    |> Enum.any?(fn {field, target_value} ->
      current_value = Map.get(current_snapshot, field)
      not same_value?(current_value, target_value)
    end)
  end

  defp put_missing_snapshot_field(snapshot, field, value) do
    if snapshot_field_present?(snapshot, field) do
      snapshot
    else
      Map.put(snapshot, field, value)
    end
  end

  defp snapshot_field_present?(snapshot, field) do
    Map.has_key?(snapshot, field) or snapshot_has_existing_atom_key?(snapshot, field)
  end

  defp snapshot_has_existing_atom_key?(snapshot, field) when is_binary(field) do
    case safe_string_to_existing_atom(field) do
      {:ok, atom_key} -> Map.has_key?(snapshot, atom_key)
      :error -> false
    end
  end

  defp snapshot_has_existing_atom_key?(_snapshot, _field), do: false

  defp same_value?(a, b), do: normalize_value(a) == normalize_value(b)

  defp normalize_value(nil), do: nil
  defp normalize_value(%Decimal{} = d), do: Decimal.to_string(d)

  defp normalize_value(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp normalize_value(%NaiveDateTime{} = ndt) do
    ndt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
  end

  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value) when is_number(value), do: value
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(%_{} = struct), do: inspect(struct)
  defp normalize_value(value) when is_map(value), do: value
  defp normalize_value(value) when is_list(value), do: value

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp jsonify(nil), do: nil
  defp jsonify(value), do: normalize_value(value)

  defp snapshot_to_update_attrs(_entity_type, nil), do: %{}

  defp snapshot_to_update_attrs(entity_type, snapshot) when is_map(snapshot) do
    snapshot
    |> then(&sanitize_rollback_snapshot(entity_type, &1))
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key_str = to_string(key)

      case safe_string_to_existing_atom(key_str) do
        {:ok, atom_key} -> Map.put(acc, atom_key, value)
        :error -> acc
      end
    end)
  end

  defp safe_string_to_existing_atom(str) do
    try do
      {:ok, String.to_existing_atom(str)}
    rescue
      ArgumentError -> :error
    end
  end

  defp insert_rollback_log(
         %ChangeLog{} = log,
         %AuditContext{} = ctx,
         current_entity,
         update_attrs
       ) do
    pre_rollback_snapshot = build_snapshot(log.entity_type, current_entity)

    %ChangeLog{}
    |> ChangeLog.changeset(%{
      entity_type: log.entity_type,
      entity_id: log.entity_id,
      entity_external_id: log.entity_external_id,
      station_stop_id: log.station_stop_id,
      actor_id: ctx.actor_id,
      actor_email: ctx.actor_email,
      snapshot: pre_rollback_snapshot,
      changed_fields: rollback_changed_fields(pre_rollback_snapshot, update_attrs),
      action: "rolled_back",
      rolled_back_to_log_id: log.id,
      organization_id: log.organization_id,
      gtfs_version_id: log.gtfs_version_id
    })
    |> Repo.insert()
  end

  defp rollback_changed_fields(pre_rollback_snapshot, update_attrs) do
    current = stringify_map_keys(pre_rollback_snapshot)
    target = stringify_map_keys(update_attrs)

    target
    |> Enum.reduce(%{}, fn {field, target_value}, acc ->
      current_value = Map.get(current, field)

      if same_value?(current_value, target_value) do
        acc
      else
        Map.put(acc, field, %{"from" => current_value, "to" => target_value})
      end
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      changed -> changed
    end
  end
end
