defmodule GtfsPlannerWeb.Gtfs.StationDiagramLive do
  @moduledoc """
  LiveView for the station diagram editor.
  Allows users to view floor plan diagrams, add/edit child stops by clicking,
  create pathways by connecting stops, and switch between levels.

  ## History lifecycle

  The stop, pathway, and level History tabs are served by one stable
  `:history_load` async task. Starting a load cancels its predecessor, bumps a
  generation counter, and records the full scope
  `{organization_id, gtfs_version_id, station_stop_id, entity_type, entity_id,
  generation}`. The task closure captures that scope — plain ids, never the
  socket — and returns it with its result, so `handle_async/3` applies a result
  only while it still describes the open panel. Switching entity, hiding the
  drawer, or starting a replacement load therefore cannot be overwritten by
  superseded work, and a cancelled task's exit is not an error.

  The task also resolves the agency display zone once and localizes the whole
  ordered timestamp collection in one batch. Localization decorates only:
  stored UTC change-log rows are never written by this path.
  """
  use GtfsPlannerWeb, :live_view
  require Logger

  import GtfsPlannerWeb.Gtfs.StationDiagramComponents
  import GtfsPlannerWeb.Gtfs.StationJournalComponents, only: [journal_panel: 1]
  alias GtfsPlanner.Geocoding
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Coordinates
  alias GtfsPlanner.Gtfs.DiagramStorage
  alias GtfsPlanner.Gtfs.DiagramUploadValidator
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.StationJournal.Scope, as: JournalScope
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Otp.Lifecycle
  alias GtfsPlanner.Otp.Materializer
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.DiagramPalette
  alias GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents
  alias LiveSelect.Component, as: LiveSelectComponent
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @history_key :history_load
  @journal_load_key :journal_load

  @type journal_filter :: :open | :all
  @type journal_state :: :idle | :loading | :ready | :error
  @type journal_load_intent :: :counts_only | :full | :observe_scrolled
  @type journal_load_reason ::
          :station_load | :open | :filter | :retry | :refresh | :pubsub | :returned_to_top
  @type journal_request :: %{
          scope_key: {Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()},
          generation: pos_integer(),
          intent: journal_load_intent(),
          reason: journal_load_reason(),
          filter: journal_filter()
        }
  @type journal_payload :: %{
          entries: [GtfsPlanner.Gtfs.JournalEntry.t()],
          open_count: non_neg_integer(),
          closed_count: non_neg_integer(),
          entry_ids: MapSet.t(Ecto.UUID.t()),
          signature: [
            {Ecto.UUID.t(), DateTime.t(), DateTime.t() | nil, [Ecto.UUID.t()]}
          ],
          authors: %{optional(Ecto.UUID.t()) => GtfsPlanner.Accounts.User.t()},
          targets: %{optional(Ecto.UUID.t()) => map()},
          zone: GtfsPlanner.Gtfs.DisplayClock.zone_resolution(),
          local_times: %{
            optional({Ecto.UUID.t(), :captured | :closed}) => NaiveDateTime.t()
          },
          now: NaiveDateTime.t()
        }

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Station Diagram")
     |> assign(:user_roles, user_roles)
     |> stream_configure(:journal_entries,
       dom_id: fn entry -> "journal-entries-#{entry.id}" end
     )
     |> assign(:journal_load_generation, 0)
     |> reset_journal()
     |> assign(:mode, :view)
     |> assign(:station_editing_status, nil)
     |> assign(:show_diagram_upload_drawer, false)
     |> assign(:stop_search_form, to_form(%{"stop_id_query" => ""}))
     |> assign(:measurement_enabled, false)
     |> assign(:scale_status, nil)
     |> assign(:placement_status, nil)
     |> assign(:ruler_point_a, nil)
     |> assign(:ruler_point_b, nil)
     |> assign(:show_ruler_drawer, false)
     |> assign(:ruler_form, to_form(%{"distance_meters" => ""}, as: :ruler))
     |> assign(:pending_xy, nil)
     |> assign(:selected_stop_id, nil)
     |> assign(:dragging_stop_id, nil)
     |> assign(:active_point_id, nil)
     |> assign(:selected_from_stop, nil)
     |> assign(:cross_level_badges_by_stop, %{})
     |> assign(:child_stop_form, to_form(%{}))
     |> assign(:unassigned_child_stops, [])
     |> assign(:show_level_modal, nil)
     |> assign(:level_form, to_form(%{}))
     |> assign(:level_shared, false)
     |> assign(:level_id_manually_edited, false)
     |> assign(:pathway_error, nil)
     |> assign(:diagram_error, nil)
     |> assign(:upload_phase, :idle)
     |> assign(:pending_diagram_upload, nil)
     |> assign(:diagram_replacement_confirmation, nil)
     |> assign(:confirmation, nil)
     |> assign(:pending_action, nil)
     |> assign(:confirmation_execution?, false)
     |> assign(:reposition_mode, false)
     |> assign(:reposition_search, "")
     |> assign(:reposition_stops, [])
     |> assign(:reposition_x, "")
     |> assign(:reposition_y, "")
     |> assign(:platform_options, [])
     |> assign(:platform_stop_ids, MapSet.new())
     |> assign(:editing_child_stop, nil)
     |> assign(:editing_level, false)
     |> assign(:stop_id_mode, :auto)
     |> assign(:show_pathway_drawer, false)
     |> assign(:editing_pathway, nil)
     |> assign(:editing_pathway_pair, [])
     |> assign(:active_pathway_tab, :first)
     |> assign(:pathway_form_dirty, false)
     |> assign(:pathway_form, to_form(%{}))
     |> assign(:pathway_pair_counts, %{})
     |> assign(:available_levels, [])
     |> assign(:level_mode, :existing)
     |> assign(:show_walkability_drawer, false)
     |> assign(:walkability_stop, nil)
     |> assign(:walkability_form, to_form(default_walkability_form_params(), as: :walkability))
     |> assign(:walkability_selected_address, nil)
     |> assign(:walkability_selected_lat, nil)
     |> assign(:walkability_selected_lon, nil)
     |> assign(:walkability_selected_result, nil)
     |> assign(:walkability_last_results, [])
     |> assign(:walkability_error, nil)
     |> assign(:walkability_field_errors, %{})
     |> assign(:walkability_test_stop_ids, %{})
     |> assign(:walkability_tests_list, [])
     |> assign(:walkability_mode, :create)
     |> assign(:editing_walkability_test, nil)
     |> assign(:show_naming_drawer, false)
     |> assign(:naming_style, :kebab)
     |> assign(:naming_preview, [])
     |> assign(:naming_renamed_stops_count, 0)
     |> assign(:naming_updated_pathways_count, 0)
     |> assign(:naming_applying?, false)
     |> assign(:naming_error, nil)
     |> assign(:naming_status, nil)
     |> assign(:naming_excluded_ids, MapSet.new())
     |> assign(:other_levels, [])
     |> assign(:other_levels_floorplan, MapSet.new())
     |> assign(:other_levels_stops, MapSet.new())
     |> assign(:other_level_counts_cache, %{})
     |> assign(:other_level_markers_cache, %{})
     |> assign(:audit_ctx, nil)
     |> assign(:history_generation, 0)
     |> reset_history()
     |> assign(:floorplan_image_w, nil)
     |> assign(:floorplan_image_h, nil)
     |> assign(:map_generation, "unmounted")
     |> assign(:map_state, :initializing)
     |> assign(:coordinate_preview, nil)
     |> assign(:coordinate_confirmation, false)
     |> assign(:coordinate_apply_form, to_form(%{"phrase" => ""}, as: :coordinate_preview))
     |> assign(:station_stop_levels_cache, empty_station_stop_levels_cache())
     |> allow_upload(:diagram,
       accept: ~w(.png .jpg .jpeg),
       max_file_size: 10_000_000,
       max_entries: 1,
       auto_upload: true,
       progress: &handle_diagram_upload_progress/3
     )}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = params, _uri, socket) do
    if same_station_already_loaded?(socket, stop_id) do
      {:noreply, maybe_open_child_stop_from_params(socket, params)}
    else
      socket = discard_pending_diagram_upload(socket)
      load_station_and_levels(socket, stop_id, params)
    end
  end

  defp same_station_already_loaded?(socket, stop_id) do
    case socket.assigns do
      %{station: %{stop_id: ^stop_id}, active_level: %{}} -> true
      _ -> false
    end
  end

  defp load_station_and_levels(socket, stop_id, params) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
      nil ->
        {:noreply, push_navigate(socket, to: "/gtfs/#{gtfs_version_id}/stops")}

      station ->
        # levels is now a list of maps: %{level: Level, stop_count: count}
        levels_data =
          Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)

        levels = Enum.map(levels_data, & &1.level)
        station_level_ids = Enum.map(levels, & &1.id)

        # Complete picklist of all levels for stop form dropdown
        all_levels = Gtfs.list_all_levels(organization_id, gtfs_version_id)

        # Only show levels that are not already assigned to this station
        available_levels =
          all_levels
          |> Enum.reject(&(&1.id in station_level_ids))
          |> Enum.sort_by(&(&1.level_name || &1.level_id), :asc)

        active_level =
          Enum.find(levels, List.first(levels), fn l -> l.level_index == 0.0 end)

        socket =
          socket
          # A station change moves the history scope, so any in-flight history
          # work is abandoned and its result can no longer match.
          |> cancel_async(@history_key)
          |> reset_history()
          |> cancel_async(@journal_load_key)
          |> reset_journal()
          |> assign(:stop_id, stop_id)
          |> assign(:station, station)
          |> assign(:levels, levels)
          |> assign(:available_levels, available_levels)
          |> assign(:all_levels, all_levels)
          |> assign(:active_level, active_level)
          |> assign(:show_walkability_drawer, false)
          |> assign(:walkability_stop, nil)
          |> assign(
            :walkability_form,
            to_form(default_walkability_form_params(), as: :walkability)
          )
          |> clear_walkability_selection()
          |> assign(:walkability_last_results, [])
          |> assign(:walkability_mode, :create)
          |> assign(:editing_walkability_test, nil)

        socket = cleanup_stale_diagram_candidates(socket)

        socket = load_station_stop_levels_cache(socket)

        socket = assign(socket, :audit_ctx, build_audit_ctx(socket))

        socket =
          if connected?(socket) do
            :ok =
              Gtfs.subscribe_station_editing_status(
                organization_id,
                gtfs_version_id,
                station.id
              )

            station_editing_status =
              Gtfs.get_station_editing_status(organization_id, gtfs_version_id, station.id)

            assign(socket, :station_editing_status, station_editing_status)
          else
            socket
          end

        socket =
          socket
          |> assign(:show_diagram_upload_drawer, false)
          |> load_level_data(active_level)
          |> maybe_open_child_stop_from_params(params)
          |> setup_station_journal()

        {:noreply, socket}
    end
  end

  defp load_station_stop_levels_cache(socket) do
    stop_levels =
      case socket.assigns do
        %{
          current_organization: %{id: organization_id},
          current_gtfs_version: %{id: gtfs_version_id}
        } ->
          case socket.assigns[:station] do
            %Stop{id: station_id} ->
              Gtfs.list_stop_levels_for_station(organization_id, gtfs_version_id, station_id)

            _ ->
              []
          end

        _ ->
          []
      end

    cache = normalize_station_stop_levels_cache(stop_levels)

    socket
    |> assign(:station_stop_levels_cache, cache)
  end

  defp normalize_station_stop_levels_cache(stop_levels) when is_list(stop_levels) do
    ordered_stop_levels =
      Enum.sort_by(stop_levels, fn stop_level ->
        {station_stop_level_index_sort_key(stop_level), stop_level.id}
      end)

    %{
      ordered: ordered_stop_levels,
      by_level_id: Map.new(ordered_stop_levels, &{&1.level_id, &1}),
      by_stop_level_id: Map.new(ordered_stop_levels, &{&1.id, &1})
    }
  end

  defp normalize_station_stop_levels_cache(_stop_levels), do: empty_station_stop_levels_cache()

  defp station_stop_level_index_sort_key(%StopLevel{level: %{level_index: level_index}})
       when not is_nil(level_index),
       do: level_index

  defp station_stop_level_index_sort_key(_stop_level), do: 9.0e15

  defp empty_station_stop_levels_cache do
    %{ordered: [], by_level_id: %{}, by_stop_level_id: %{}}
  end

  defp refresh_level_and_stop_level_cache(socket, level) do
    socket
    |> load_level_data(level)
    |> load_station_stop_levels_cache()
  end

  defp build_audit_ctx(socket) do
    %{
      current_organization: %{id: organization_id},
      current_gtfs_version: %{id: gtfs_version_id},
      current_user: %{id: actor_id, email: actor_email},
      station: %{stop_id: station_stop_id}
    } = socket.assigns

    %AuditContext{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      station_stop_id: station_stop_id,
      actor_id: actor_id,
      actor_email: actor_email
    }
  end

  defp pending_diagram_upload_value(nil, _key), do: nil
  defp pending_diagram_upload_value(pending, key), do: Map.get(pending, key)

  @impl true
  def handle_info(:clear_edit_child_stop_param, socket) do
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station_stop_id = socket.assigns.station.stop_id

    {:noreply,
     push_patch(socket, to: "/gtfs/#{gtfs_version_id}/stops/#{station_stop_id}/diagram")}
  end

  @impl true
  def handle_info({:station_editing_status_updated, status}, socket) do
    {:noreply, assign(socket, :station_editing_status, status)}
  end

  @impl true
  def handle_info(
        {:station_journal_changed, station_id},
        %{assigns: %{journal_scope: %JournalScope{station_id: station_id}}} = socket
      ) do
    intent = journal_pubsub_intent(socket)

    {:noreply, load_journal(socket, intent, :pubsub, socket.assigns.journal_filter)}
  end

  def handle_info({:station_journal_changed, _station_id}, socket), do: {:noreply, socket}

  defp load_level_data(socket, nil) do
    socket
    |> stream(:child_stops, [], reset: true)
    |> stream(:pathways, [], reset: true)
    |> reset_ruler_state()
    |> assign(:child_stops_list, [])
    |> assign(:child_stops_total, 0)
    |> assign(:child_stops_with_geo, 0)
    |> assign(:anchor_count, 0)
    |> assign(:cross_level_pathway_total, 0)
    |> assign(:cross_level_pathway_with_geo, 0)
    |> assign(:unassigned_child_stops, [])
    |> assign(:pathways_list, [])
    |> assign(:active_stop_level, nil)
    |> assign(:cross_level_badges_by_stop, %{})
    |> assign(:walkability_test_stop_ids, %{})
    |> assign(:walkability_tests_list, [])
    |> assign(:platform_options, [])
    |> assign(:platform_stop_ids, MapSet.new())
    |> assign(:pathway_pair_counts, %{})
    |> assign(:other_level_markers_cache, %{})
    |> assign(:other_level_counts_cache, %{})
    |> assign(:other_levels, [])
  end

  defp load_level_data(socket, level) do
    station = socket.assigns.station
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    stop_level = Gtfs.get_stop_level(organization_id, gtfs_version_id, station.id, level.id)
    all_child_stops = Gtfs.list_child_stops_for_level(station.id, level.id)
    child_stops_on_level = Enum.filter(all_child_stops, & &1.on_active_level)
    child_stop_ids = Enum.map(child_stops_on_level, & &1.stop_id)
    platforms_for_station = station_platform_options(all_child_stops, station.stop_id)
    platform_stop_ids = platforms_for_station |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    walkability_test_stop_ids =
      Validations.stop_ids_with_walkability_tests(organization_id, child_stop_ids)

    walkability_tests_list =
      Validations.list_walkability_tests_for_stop_ids(
        organization_id,
        gtfs_version_id,
        child_stop_ids
      )

    unassigned_child_stops =
      Enum.filter(all_child_stops, fn stop -> stop.level_id in [nil, ""] end)

    level_pathways =
      Gtfs.list_pathways_for_level(organization_id, gtfs_version_id, level.id, station.id)

    active_level_stop_ids = active_level_stop_ids(all_child_stops, level)
    cross_level_badges_by_stop = cross_level_badges_by_stop(level_pathways, active_level_stop_ids)
    visible_canvas_stops = child_stops_on_level
    {same_level_pathways, pathway_pair_counts} = decorate_same_level_pathways(level_pathways)

    child_stops_total = length(child_stops_on_level)

    child_stops_with_geo =
      Enum.count(child_stops_on_level, fn s ->
        not is_nil(s.stop_lat) and not is_nil(s.stop_lon)
      end)

    anchor_count =
      Enum.count(child_stops_on_level, fn s ->
        not is_nil(s.diagram_coordinate) and not is_nil(s.stop_lat) and not is_nil(s.stop_lon)
      end)

    cross_level_pathways = Enum.filter(level_pathways, & &1.is_cross_level)
    cross_level_pathway_total = length(cross_level_pathways)

    cross_level_pathway_with_geo =
      Enum.count(cross_level_pathways, fn p ->
        other = if p.from_on_active_level, do: p.to_stop, else: p.from_stop
        not is_nil(other.stop_lat) and not is_nil(other.stop_lon)
      end)

    socket
    |> stream(:child_stops, visible_canvas_stops, reset: true)
    |> stream(:pathways, same_level_pathways, reset: true)
    |> reset_ruler_state()
    |> assign(:child_stops_list, child_stops_on_level)
    |> assign(:child_stops_total, child_stops_total)
    |> assign(:child_stops_with_geo, child_stops_with_geo)
    |> assign(:anchor_count, anchor_count)
    |> assign(:cross_level_pathway_total, cross_level_pathway_total)
    |> assign(:cross_level_pathway_with_geo, cross_level_pathway_with_geo)
    |> assign(:unassigned_child_stops, unassigned_child_stops)
    |> assign(:pathways_list, level_pathways)
    |> assign(:active_stop_level, stop_level)
    |> assign(:cross_level_badges_by_stop, cross_level_badges_by_stop)
    |> assign(:walkability_test_stop_ids, walkability_test_stop_ids)
    |> assign(:walkability_tests_list, walkability_tests_list)
    |> assign(:platform_options, platforms_for_station)
    |> assign(:platform_stop_ids, platform_stop_ids)
    |> assign(:pathway_pair_counts, pathway_pair_counts)
    |> assign(:other_level_markers_cache, %{})
    |> assign(:other_level_counts_cache, %{})
    |> assign_other_levels()
    |> push_child_stop_markers()
  end

  defp assign_other_levels(socket) do
    if socket.assigns[:mode] == :map do
      socket
      |> populate_other_level_caches()
      |> then(&assign(&1, :other_levels, build_other_levels(&1)))
    else
      assign(socket, :other_levels, [])
    end
  end

  defp push_child_stop_markers(socket) do
    if socket.assigns[:mode] == :map do
      active_payload = active_child_stop_payload(socket)
      total = length(socket.assigns[:child_stops_list] || [])

      require Logger

      Logger.info(
        "StationDiagram map pins: #{length(active_payload.stops)} geo-coded / #{total} child stops on level"
      )

      socket
      |> push_event("set_active_child_stops", active_payload)
      |> push_other_levels()
    else
      socket
    end
  end

  defp push_other_levels(socket) do
    if socket.assigns[:mode] == :map do
      {levels, socket} =
        socket.assigns
        |> Map.get(:other_levels, [])
        |> Enum.flat_map_reduce(socket, &other_level_render/2)

      push_event(socket, "set_other_levels", %{
        active_level_id: active_level_id(socket),
        levels: levels
      })
    else
      socket
    end
  end

  defp other_level_render(row, socket) do
    floorplan = other_level_floorplan(socket, row)

    {stops, socket} =
      if row.stops_on? and row.stops_eligible? do
        other_level_markers(socket, row.level_id)
      else
        {[], socket}
      end

    if is_nil(floorplan) and stops == [] do
      {[], socket}
    else
      render = %{
        level_id: row.level_id,
        level_index: row.level_index,
        color: row.color,
        floorplan: floorplan,
        stops: stops
      }

      {[render], socket}
    end
  end

  defp other_level_floorplan(socket, %{floorplan_on?: true, floorplan_eligible?: true} = row) do
    case other_level_stop_level(socket, row.level_id) do
      %StopLevel{} = stop_level ->
        case other_level_diagram_url(socket, stop_level) do
          nil ->
            nil

          url ->
            %{
              url: url,
              center_lat: stop_level.floorplan_center_lat,
              center_lon: stop_level.floorplan_center_lon,
              scale_mpp: stop_level.floorplan_scale_mpp,
              rotation_deg: stop_level.floorplan_rotation_deg
            }
        end

      _ ->
        nil
    end
  end

  defp other_level_floorplan(_socket, _row), do: nil

  defp other_level_stop_level(socket, level_id) do
    socket.assigns
    |> Map.get(:station_stop_levels_cache, empty_station_stop_levels_cache())
    |> Map.get(:ordered, [])
    |> Enum.find(&(&1.level_id == level_id))
  end

  defp other_level_diagram_url(socket, %StopLevel{diagram_filename: filename})
       when is_binary(filename) and filename != "" do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns[:station]
    station_dir = station && PathSafety.stop_storage_dir(station.stop_id)

    if is_binary(station_dir) and is_binary(gtfs_version_id) do
      token = URI.encode_www_form(filename)
      encoded_filename = URI.encode(filename)

      "/uploads/diagrams/#{organization_id}/#{gtfs_version_id}/#{station_dir}/#{encoded_filename}?v=#{token}"
    end
  end

  defp other_level_diagram_url(_socket, _stop_level), do: nil

  defp active_level_id(socket) do
    case socket.assigns[:active_level] do
      %{level_id: level_id} -> level_id
      _ -> nil
    end
  end

  defp active_child_stop_payload(socket) do
    active_level_id =
      case socket.assigns[:active_level] do
        %{level_id: level_id} -> level_id
        _ -> nil
      end

    %{stops: child_stop_markers(socket), level_id: active_level_id}
  end

  defp other_level_markers(socket, level_id) do
    station = socket.assigns[:station]
    cache = Map.get(socket.assigns, :other_level_markers_cache, %{})

    cond do
      is_nil(station) or is_nil(level_id) ->
        {[], socket}

      is_map_key(cache, level_id) ->
        {Map.get(cache, level_id, []), socket}

      true ->
        markers = level_child_stop_markers(socket, station, level_id)
        {markers, assign(socket, :other_level_markers_cache, Map.put(cache, level_id, markers))}
    end
  end

  defp level_child_stop_markers(socket, %Stop{} = station, level_id) when is_binary(level_id) do
    level_stops =
      station.id
      |> Gtfs.list_child_stops_for_level(level_id)
      |> Enum.filter(& &1.on_active_level)

    badges_by_stop = other_level_badges(socket, station, level_id, level_stops)

    level_stops
    |> Enum.map(&child_stop_marker(&1, badges_by_stop))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&marker_has_geo?/1)
  end

  defp level_child_stop_markers(_socket, _station, _level_id), do: []

  # Cross-level stairs/elevator badges for a non-active level: load that level's
  # pathways and key the badges to that level's stops, mirroring the active-level
  # computation in cross_level_badges_by_stop/2.
  defp other_level_badges(socket, %Stop{} = station, level_id, level_stops) do
    with %StopLevel{level: %{id: internal_level_id}} when not is_nil(internal_level_id) <-
           other_level_stop_level(socket, level_id) do
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id

      pathways =
        Gtfs.list_pathways_for_level(
          organization_id,
          gtfs_version_id,
          internal_level_id,
          station.id
        )

      level_stop_ids = level_stops |> Enum.map(& &1.id) |> MapSet.new()
      cross_level_badges_by_stop(pathways, level_stop_ids)
    else
      _ -> %{}
    end
  end

  defp child_stop_markers(socket) do
    badges_by_stop = Map.get(socket.assigns, :cross_level_badges_by_stop, %{})

    socket.assigns
    |> Map.get(:child_stops_list, [])
    |> Enum.map(&child_stop_marker(&1, badges_by_stop))
    |> Enum.reject(&is_nil/1)
  end

  # Active-level child stops always render in the diagram base blue
  # (DIAGRAM_BASE_COLOR = "#0080FF" in assets/js/stop_icon_symbols.js). Blue is
  # reserved for the level the operator is editing, so the other-level palette
  # excludes the blue/cyan band entirely — an overlay must never be mistaken for
  # the active level. `other_level_palette_distinct?/0` guards this invariant.
  @active_level_color "#0080FF"
  @other_level_palette ~w(#16a34a #d97706 #db2777 #7c3aed #ca8a04 #dc2626 #0d9488 #c026d3)

  # Minimum straight RGB distance an other-level color must keep from the active
  # color. The replaced blue (#2563eb) and cyan (#0891b2) sat at 51 and 79; every
  # retained color is >= 121, so 100 cleanly separates "too similar" from "clear".
  @min_active_color_distance 100

  defp build_other_levels(socket) do
    active_level_id =
      case socket.assigns[:active_level] do
        %{id: id} -> id
        _ -> nil
      end

    station = socket.assigns[:station]
    floorplan_on = Map.get(socket.assigns, :other_levels_floorplan, MapSet.new())
    stops_on = Map.get(socket.assigns, :other_levels_stops, MapSet.new())
    counts_cache = Map.get(socket.assigns, :other_level_counts_cache, %{})

    socket.assigns
    |> Map.get(:station_stop_levels_cache, empty_station_stop_levels_cache())
    |> Map.get(:ordered, [])
    |> Enum.reject(&(&1.level_id == active_level_id))
    |> Enum.map(&other_level_view(&1, station, floorplan_on, stops_on, counts_cache))
  end

  defp populate_other_level_caches(socket) do
    active_level_id =
      case socket.assigns[:active_level] do
        %{id: id} -> id
        _ -> nil
      end

    station = socket.assigns[:station]

    counts =
      socket.assigns
      |> Map.get(:station_stop_levels_cache, empty_station_stop_levels_cache())
      |> Map.get(:ordered, [])
      |> Enum.reject(&(&1.level_id == active_level_id))
      |> Map.new(fn stop_level ->
        {stop_level.level_id, other_level_stop_counts(station, stop_level.level_id)}
      end)

    socket
    |> assign(:other_level_counts_cache, counts)
    |> assign(:other_level_markers_cache, %{})
  end

  defp other_level_view(%StopLevel{} = stop_level, station, floorplan_on, stops_on, counts_cache) do
    level_id = stop_level.level_id
    level_index = stop_level_index(stop_level)

    {geo_stop_count, total_stop_count} =
      Map.get_lazy(counts_cache, level_id, fn -> other_level_stop_counts(station, level_id) end)

    has_diagram? = is_binary(stop_level.diagram_filename) and stop_level.diagram_filename != ""
    has_alignment? = StopLevel.alignment_complete?(stop_level)

    row = %{
      level_id: level_id,
      name: other_level_name(stop_level),
      level_index: level_index,
      color: other_level_color(level_index),
      has_diagram?: has_diagram?,
      has_alignment?: has_alignment?,
      geo_stop_count: geo_stop_count,
      total_stop_count: total_stop_count,
      floorplan_on?: MapSet.member?(floorplan_on, level_id),
      stops_on?: MapSet.member?(stops_on, level_id)
    }

    row
    |> Map.put(:floorplan_eligible?, other_level_floorplan_eligible?(row))
    |> Map.put(:stops_eligible?, other_level_stops_eligible?(row))
  end

  defp other_level_stop_counts(%Stop{} = station, level_id) when is_binary(level_id) do
    stops =
      station.id
      |> Gtfs.list_child_stops_for_level(level_id)
      |> Enum.filter(& &1.on_active_level)

    geo =
      Enum.count(stops, fn s ->
        not is_nil(s.stop_lat) and not is_nil(s.stop_lon)
      end)

    {geo, length(stops)}
  end

  defp other_level_stop_counts(_station, _level_id), do: {0, 0}

  defp other_level_name(%StopLevel{level: %{level_name: name}})
       when is_binary(name) and name != "",
       do: name

  defp other_level_name(%StopLevel{level_id: level_id}), do: level_id

  defp other_level_color(level_index) when is_number(level_index) do
    Enum.at(@other_level_palette, Integer.mod(trunc(level_index), length(@other_level_palette)))
  end

  defp other_level_color(_level_index), do: List.first(@other_level_palette)

  @doc """
  Color reserved for the active level's overlay. Mirrors `DIAGRAM_BASE_COLOR`
  in `assets/js/stop_icon_symbols.js`; other-level colors must stay distinct
  from it so operators never confuse an overlay with the level they are editing.
  """
  def active_level_color, do: @active_level_color

  @doc "Qualitative palette assigned to other-level overlays by level index."
  def other_level_palette, do: @other_level_palette

  @doc """
  True when every other-level palette color stays at least
  `#{@min_active_color_distance}` RGB units from `active_level_color/0`, keeping
  overlays visually distinct from the active level.
  """
  def other_level_palette_distinct? do
    Enum.all?(@other_level_palette, fn color ->
      color_distance(color, @active_level_color) >= @min_active_color_distance
    end)
  end

  @doc "Straight RGB Euclidean distance between two `#rrggbb` colors."
  def color_distance(<<?#, _::binary>> = a, <<?#, _::binary>> = b) do
    {ar, ag, ab} = rgb_channels(a)
    {br, bg, bb} = rgb_channels(b)

    :math.sqrt(:math.pow(ar - br, 2) + :math.pow(ag - bg, 2) + :math.pow(ab - bb, 2))
  end

  defp rgb_channels(<<?#, r::binary-2, g::binary-2, b::binary-2>>) do
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  defp other_level_floorplan_eligible?(%{
         has_diagram?: has_diagram?,
         has_alignment?: has_alignment?
       }),
       do: has_diagram? and has_alignment?

  defp other_level_stops_eligible?(%{geo_stop_count: geo_stop_count}),
    do: geo_stop_count > 0

  defp child_stop_marker(stop, badges_by_stop) do
    lat = marker_float(stop.stop_lat)
    lon = marker_float(stop.stop_lon)
    diagram_coordinate = marker_diagram_coordinate(stop)
    has_geo? = is_float(lat) and is_float(lon)

    if has_geo? or diagram_coordinate do
      %{
        stop_id: stop.stop_id,
        stop_name: stop.stop_name,
        platform_code: stop.platform_code,
        location_type: stop.location_type,
        lat: if(has_geo?, do: lat, else: nil),
        lon: if(has_geo?, do: lon, else: nil),
        diagram_coordinate: diagram_coordinate,
        badges: stop_badges(badges_by_stop, stop.id)
      }
    end
  end

  defp marker_diagram_coordinate(stop) do
    Coordinates.normalize_point(stop.diagram_coordinate)
  end

  defp marker_has_geo?(%{lat: lat, lon: lon}) when is_float(lat) and is_float(lon), do: true
  defp marker_has_geo?(_marker), do: false

  defp stop_badges(badges_by_stop, stop_id) do
    badges_by_stop
    |> Map.get(stop_id, [])
    |> Enum.map(&%{pathway_mode: &1.pathway_mode, pathway_id: &1.pathway_id})
  end

  defp marker_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp marker_float(n) when is_number(n), do: n * 1.0
  defp marker_float(_), do: nil

  defp station_platform_options(all_child_stops, station_stop_id) do
    all_child_stops
    |> Enum.filter(&(&1.location_type == 0 and &1.parent_station == station_stop_id))
    |> Enum.sort_by(&(&1.stop_name || &1.stop_id), :asc)
    |> Enum.map(fn stop ->
      label =
        if stop.stop_name,
          do: "#{stop.stop_id} - #{stop.stop_name}",
          else: stop.stop_id

      {label, stop.stop_id}
    end)
  end

  defp stop_belongs_to_station?(stop, station_stop_id, platform_stop_ids) do
    stop.parent_station == station_stop_id or
      MapSet.member?(platform_stop_ids, stop.parent_station)
  end

  defp active_level_stop_ids(all_child_stops, level) do
    all_child_stops
    |> Enum.filter(&(&1.level_id == level.level_id))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp cross_level_badges_by_stop(level_pathways, active_level_stop_ids) do
    level_pathways
    |> Enum.reduce(%{}, fn pathway, badges_by_stop ->
      stop_id =
        cond do
          pathway.from_stop.level_id in [nil, ""] or pathway.to_stop.level_id in [nil, ""] ->
            nil

          pathway.from_stop.level_id == pathway.to_stop.level_id ->
            nil

          MapSet.member?(active_level_stop_ids, pathway.from_stop.id) ->
            pathway.from_stop.id

          MapSet.member?(active_level_stop_ids, pathway.to_stop.id) ->
            pathway.to_stop.id

          true ->
            nil
        end

      if stop_id do
        badge = %{pathway_id: pathway.id, pathway_mode: pathway.pathway_mode}
        Map.update(badges_by_stop, stop_id, [badge], &[badge | &1])
      else
        badges_by_stop
      end
    end)
    |> Map.new(fn {stop_id, badges} ->
      {stop_id, Enum.sort_by(badges, & &1.pathway_id, :asc)}
    end)
  end

  @impl true
  def render(assigns) do
    has_diagram =
      not is_nil(assigns.active_stop_level && assigns.active_stop_level.diagram_filename)

    assigns =
      assigns
      |> assign(:has_diagram, has_diagram)
      |> assign(:active_level_name, active_level_name(assigns[:active_level]))

    ~H"""
    <div
      id="diagram-page"
      phx-hook="JournalPanelHook"
      style={DiagramPalette.css_custom_properties()}
      data-user-id={@current_user.id}
      data-immersive={if @mode in [:add, :connect, :map], do: "true"}
    >
      <Layouts.app
        flash={@flash}
        current_user={@current_user}
        current_organization={@current_organization}
        user_roles={@user_roles}
        current_path={@current_path}
        current_gtfs_version={assigns[:current_gtfs_version]}
        available_versions={assigns[:available_versions] || []}
      >
        <:sub_header>
          <.station_sub_nav
            station={@station}
            gtfs_version_id={@current_gtfs_version.id}
            active_tab={:diagram}
          >
            <:actions>
              <.editing_presence_control
                station_editing_status={@station_editing_status}
                current_user={@current_user}
              />
            </:actions>
          </.station_sub_nav>
          <.diagram_action_strip
            :if={@levels != []}
            mode={@mode}
            selected_from_stop={@selected_from_stop}
            has_diagram={@has_diagram}
            measurement_enabled={@measurement_enabled}
            ruler_point_a={@ruler_point_a}
            ruler_point_b={@ruler_point_b}
            has_scale={scale_configured?(@active_stop_level)}
            scale_status={@scale_status}
            active_stop_level={@active_stop_level}
            levels={@levels}
            active_level={@active_level}
            active_level_name={@active_level_name}
            other_levels={@other_levels}
            enabled_count={MapSet.size(MapSet.union(@other_levels_floorplan, @other_levels_stops))}
            child_stops_list={@child_stops_list}
            stop_search_form={@stop_search_form}
            station={@station}
            journal_scope={@journal_scope}
            journal_open_count={@journal_open_count}
            journal_panel_open?={@journal_panel_open?}
          />
          <section
            id="floorplan-workspace"
            tabindex="-1"
            aria-labelledby="floorplan-workspace-heading"
            class="scroll-mt-16 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-inset"
          >
            <%= if @mode == :map do %>
              <div id="map-canvas-wrapper" class="w-full px-4 sm:px-6 lg:px-8 py-4">
                <h2 id="floorplan-workspace-heading" class="sr-only">Align floorplan</h2>
                <.map_canvas
                  station={@station}
                  active_level={@active_level}
                  active_stop_level={@active_stop_level}
                  organization_id={@current_organization.id}
                  gtfs_version_id={@current_gtfs_version.id}
                  align_center_lat={@active_stop_level && @active_stop_level.floorplan_center_lat}
                  align_center_lon={@active_stop_level && @active_stop_level.floorplan_center_lon}
                  align_scale_mpp={@active_stop_level && @active_stop_level.floorplan_scale_mpp}
                  align_rotation_deg={@active_stop_level && @active_stop_level.floorplan_rotation_deg}
                  image_natural_width={@floorplan_image_w}
                  image_natural_height={@floorplan_image_h}
                  child_stops_total={@child_stops_total}
                  child_stops_with_geo={@child_stops_with_geo}
                  anchor_count={@anchor_count}
                  cross_level_pathway_total={@cross_level_pathway_total}
                  cross_level_pathway_with_geo={@cross_level_pathway_with_geo}
                  other_levels_floorplan_count={MapSet.size(@other_levels_floorplan)}
                  map_generation={@map_generation}
                  map_state={@map_state}
                  coordinate_preview={@coordinate_preview}
                  coordinate_confirmation={@coordinate_confirmation}
                  coordinate_apply_form={@coordinate_apply_form}
                />
              </div>
            <% else %>
              <div
                id="diagram-workspace"
                class="diagram-workspace flex min-h-0 min-w-0 w-full items-stretch overflow-hidden"
              >
                <h2 id="floorplan-workspace-heading" class="sr-only">Floorplan workspace</h2>
                <.journal_panel
                  :if={@journal_panel_open? && @journal_scope}
                  journal_scope={@journal_scope}
                  journal_entries={@streams.journal_entries}
                  journal_state={@journal_state}
                  journal_filter={@journal_filter}
                  journal_loaded_once?={@journal_loaded_once?}
                  journal_refresh_error?={@journal_refresh_error?}
                  journal_open_count={@journal_open_count}
                  journal_closed_count={@journal_closed_count}
                  journal_visible_count={@journal_visible_count}
                  journal_expanded_id={@journal_expanded_id}
                  journal_undo_ids={@journal_undo_ids}
                  journal_pending_new_ids={@journal_pending_new_ids}
                  journal_authors={@journal_authors}
                  journal_targets={@journal_targets}
                  journal_local_times={@journal_local_times}
                  journal_display_zone={@journal_display_zone}
                  journal_now={@journal_now}
                  journal_live_message={@journal_live_message}
                  journal_error_message={@journal_error_message}
                />
                <div
                  id="diagram-canvas-wrapper"
                  class="min-w-0 flex-1 overflow-auto overscroll-contain px-4 py-4 sm:px-6 lg:px-8"
                >
                  <.diagram_canvas
                    station={@station}
                    active_level={@active_level}
                    active_stop_level={@active_stop_level}
                    streams={@streams}
                    active_point_id={@active_point_id}
                    pending_xy={@pending_xy}
                    selected_stop_id={@selected_stop_id}
                    mode={@mode}
                    uploads={@uploads}
                    cross_level_badges_by_stop={@cross_level_badges_by_stop}
                    diagram_error={@diagram_error}
                    organization_id={@current_organization.id}
                    gtfs_version_id={@current_gtfs_version.id}
                    ruler_point_a={@ruler_point_a}
                    ruler_point_b={@ruler_point_b}
                    scale_point_a={scale_point(@active_stop_level, :scale_point_a)}
                    scale_point_b={scale_point(@active_stop_level, :scale_point_b)}
                    measurement_enabled={@measurement_enabled}
                    has_diagram={@has_diagram}
                    upload={@uploads.diagram}
                    upload_phase={@upload_phase}
                  />
                </div>
              </div>
            <% end %>
          </section>
        </:sub_header>

        <.child_stop_drawer
          pending_xy={@pending_xy}
          selected_stop_id={@selected_stop_id}
          child_stop_form={@child_stop_form}
          platform_options={@platform_options}
          stop_id_mode={@stop_id_mode}
          mode={@mode}
          all_levels={@all_levels}
          editing_level={@editing_level}
          active_level={@active_level}
          reposition_mode={@reposition_mode}
          reposition_search={@reposition_search}
          reposition_stops={@reposition_stops}
          reposition_x={@reposition_x}
          reposition_y={@reposition_y}
          history_open_for={@history_open_for}
          history_entries={@history_entries}
          history_state={@history_state}
          history_filter_form={@history_filter_form}
          history_field_filter={@history_field_filter}
          history_zone={@history_zone}
          history_local_times={@history_local_times}
          history_today={@history_today}
          history_now={@history_now}
          rollback_preview={@rollback_preview}
        />

        <.pathway_drawer
          open={@show_pathway_drawer}
          pathway_form={@pathway_form}
          editing_pathway={@editing_pathway}
          editing_pathway_pair={@editing_pathway_pair}
          active_pathway_tab={@active_pathway_tab}
          pathway_form_dirty={@pathway_form_dirty}
          has_scale={scale_configured?(@active_stop_level)}
          pathway_error={@pathway_error}
          history_open_for={@history_open_for}
          history_entries={@history_entries}
          history_state={@history_state}
          history_filter_form={@history_filter_form}
          history_field_filter={@history_field_filter}
          history_zone={@history_zone}
          history_local_times={@history_local_times}
          history_today={@history_today}
          history_now={@history_now}
          rollback_preview={@rollback_preview}
        />

        <.ruler_drawer
          open={@show_ruler_drawer}
          ruler_form={@ruler_form}
        />

        <.level_sidebar
          show_level_modal={@show_level_modal}
          level_form={@level_form}
          available_levels={@available_levels}
          level_mode={@level_mode}
          editing_level_uuid={if @show_level_modal == :edit && @active_level, do: @active_level.id}
          level_shared={@level_shared}
          history_open_for={@history_open_for}
          history_entries={@history_entries}
          history_state={@history_state}
          history_filter_form={@history_filter_form}
          history_field_filter={@history_field_filter}
          history_zone={@history_zone}
          history_local_times={@history_local_times}
          history_today={@history_today}
          history_now={@history_now}
          rollback_preview={@rollback_preview}
        />

        <.walkability_test_drawer
          open={@show_walkability_drawer}
          walkability_stop={@walkability_stop}
          walkability_form={@walkability_form}
          walkability_selected_address={@walkability_selected_address}
          walkability_selected_lat={@walkability_selected_lat}
          walkability_selected_lon={@walkability_selected_lon}
          walkability_error={@walkability_error}
          walkability_field_errors={@walkability_field_errors}
          walkability_mode={@walkability_mode}
          editing_walkability_test={@editing_walkability_test}
        />

        <.naming_drawer
          open={@show_naming_drawer}
          style={@naming_style}
          preview_rows={@naming_preview}
          renamed_stops_count={@naming_renamed_stops_count}
          updated_pathways_count={@naming_updated_pathways_count}
          applying?={@naming_applying?}
          error={@naming_error}
          excluded_ids={@naming_excluded_ids}
        />

        <div :if={@naming_status} role="status" aria-live="polite" class="mx-4 sm:mx-6 lg:mx-8 mt-2">
          <div class="alert alert-success alert-soft text-sm">
            <span>{@naming_status}</span>
            <button type="button" class="btn btn-ghost btn-xs" phx-click="dismiss_naming_status">
              Dismiss
            </button>
          </div>
        </div>

        <div
          :if={@placement_status}
          id="placement-status"
          role="status"
          aria-live="polite"
          class="mx-4 sm:mx-6 lg:mx-8 mt-2"
        >
          <div class="alert alert-info alert-soft text-sm">
            <span>{@placement_status}</span>
            <button type="button" class="btn btn-ghost btn-xs" phx-click="dismiss_placement_status">
              Dismiss
            </button>
          </div>
        </div>

        <.confirm_dialog
          id="station-diagram-confirmation"
          open={not is_nil(@confirmation)}
          title={confirmation_value(@confirmation, :title)}
          confirm_label={confirmation_value(@confirmation, :confirm_label)}
          pending_label={confirmation_value(@confirmation, :pending_label)}
          on_confirm="confirm_destructive_action"
          on_cancel="cancel_confirmation"
          pending={not is_nil(@pending_action)}
          return_focus_id={confirmation_value(@confirmation, :origin_id, nil)}
          described_by="station-diagram-confirmation-body"
        >
          {confirmation_value(@confirmation, :description)}
        </.confirm_dialog>

        <.confirm_dialog
          id="diagram-replacement-confirmation"
          open={not is_nil(@diagram_replacement_confirmation)}
          title={
            if @diagram_replacement_confirmation,
              do: "Replace diagram?",
              else: "Confirm diagram replacement"
          }
          confirm_label={
            if @diagram_replacement_confirmation, do: "Replace diagram", else: "Confirm replacement"
          }
          pending_label={
            if @diagram_replacement_confirmation,
              do: "Replacing diagram…",
              else: "Confirming replacement…"
          }
          on_confirm="confirm_diagram_replacement"
          on_cancel="cancel_diagram_replacement"
          pending={@upload_phase in [:validating, :probing_candidate, :committing]}
          return_focus_id="level-control-trigger"
          described_by="diagram-replacement-confirmation-body"
        >
          Replacing this diagram resets its calibration. Alignment and placed stop coordinates remain.
        </.confirm_dialog>

        <.diagram_upload_drawer
          :if={@levels != []}
          open={@show_diagram_upload_drawer}
          upload={@uploads.diagram}
          active_level={@active_level}
          active_level_name={@active_level_name}
          upload_phase={@upload_phase}
          diagram_error={@diagram_error}
          has_diagram={@has_diagram}
        />

        <div
          id="diagram-candidate-probe"
          phx-hook="DiagramCandidateProbe"
          phx-update="ignore"
          aria-hidden="true"
        >
        </div>
        <span
          id="diagram-candidate-identity"
          class="hidden"
          data-candidate-ref={pending_diagram_upload_value(@pending_diagram_upload, :candidate_ref)}
        >
        </span>

        <.lists_section
          active_level={@active_level}
          child_stops_list={@child_stops_list}
          unassigned_child_stops={@unassigned_child_stops}
          pathways_list={@pathways_list}
          pathway_error={@pathway_error}
          walkability_test_stop_ids={@walkability_test_stop_ids}
          walkability_tests_list={@walkability_tests_list}
        />
      </Layouts.app>
    </div>
    """
  end

  @impl true
  def handle_event(
        "open_journal",
        _params,
        %{assigns: %{journal_scope: %JournalScope{}}} = socket
      ) do
    {:noreply, open_journal_panel(socket, persist?: true)}
  end

  def handle_event("open_journal", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_journal", _params, socket) do
    {:noreply,
     close_journal_panel(socket,
       persist?: true,
       focus_selector: "#journal-trigger"
     )}
  end

  @impl true
  def handle_event(
        "set_journal_filter",
        %{"journal_filter" => filter},
        %{assigns: %{journal_scope: %JournalScope{}}} = socket
      )
      when filter in ["open", "all"] do
    filter = String.to_existing_atom(filter)

    {:noreply,
     socket
     |> assign(:journal_undo_ids, MapSet.new())
     |> assign(:journal_expanded_id, nil)
     |> assign(:journal_pending_new_ids, MapSet.new())
     |> load_journal(:full, :filter, filter)}
  end

  def handle_event("set_journal_filter", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "select_journal_entry",
        %{"id" => entry_id},
        %{assigns: %{journal_scope: %JournalScope{}}} = socket
      ) do
    {:noreply, select_journal_entry(socket, entry_id)}
  end

  def handle_event("select_journal_entry", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "close_journal_entry",
        %{"id" => entry_id},
        %{assigns: %{journal_scope: %JournalScope{}}} = socket
      ) do
    {:noreply, mutate_journal_entry(socket, entry_id, :close)}
  end

  def handle_event("close_journal_entry", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "reopen_journal_entry",
        %{"id" => entry_id},
        %{assigns: %{journal_scope: %JournalScope{}}} = socket
      ) do
    {:noreply, mutate_journal_entry(socket, entry_id, :reopen)}
  end

  def handle_event("reopen_journal_entry", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "undo_journal_close",
        %{"id" => entry_id},
        %{assigns: %{journal_scope: %JournalScope{}}} = socket
      ) do
    {:noreply, mutate_journal_entry(socket, entry_id, :undo)}
  end

  def handle_event("undo_journal_close", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "refresh_journal",
        _params,
        %{assigns: %{journal_scope: %JournalScope{}}} = socket
      ) do
    reason = if socket.assigns.journal_loaded_once?, do: :refresh, else: :retry

    {:noreply,
     socket
     |> assign(:journal_undo_ids, MapSet.new())
     |> load_journal(:full, reason, socket.assigns.journal_filter)}
  end

  def handle_event("refresh_journal", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("journal_scroll_state", %{"at_top" => at_top}, socket)
      when is_boolean(at_top) do
    {:noreply, update_journal_scroll_state(socket, at_top)}
  end

  def handle_event("journal_scroll_state", %{"at_top" => at_top}, socket)
      when at_top in ["true", "false"] do
    {:noreply, update_journal_scroll_state(socket, at_top == "true")}
  end

  def handle_event("journal_scroll_state", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("restore_journal_panel", %{"open" => open?}, socket)
      when is_boolean(open?) do
    {:noreply, restore_journal_panel(socket, open?)}
  end

  def handle_event("restore_journal_panel", %{"open" => open?}, socket)
      when open? in ["true", "false"] do
    {:noreply, restore_journal_panel(socket, open? == "true")}
  end

  def handle_event("restore_journal_panel", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "request_confirmation",
        %{"action" => action, "id" => id, "origin" => origin_id},
        socket
      ) do
    case confirmation_payload(socket, action, id, origin_id) do
      {:ok, confirmation} ->
        {:noreply, assign(socket, :confirmation, confirmation)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "This action is no longer available.")}
    end
  end

  def handle_event("request_confirmation", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_confirmation", _params, socket) do
    {:noreply, clear_confirmation(socket)}
  end

  @impl true
  def handle_event("confirm_destructive_action", _params, socket) do
    case socket.assigns.confirmation do
      %{event: event, id: id} = confirmation ->
        case confirmation_payload(
               socket,
               Atom.to_string(confirmation.action),
               id,
               confirmation.origin_id
             ) do
          {:ok, _fresh_confirmation} ->
            socket =
              socket
              |> assign(:pending_action, confirmation.action)
              |> assign(:confirmation_execution?, true)

            case event do
              "remove_from_diagram" ->
                handle_event(event, %{"id" => id}, socket)

              "delete_child_stop" ->
                handle_event(event, %{"id" => id}, socket)

              "delete_pathway" ->
                handle_event(event, %{"id" => id}, socket)

              "remove_level_from_station" ->
                handle_event(event, %{"id" => id}, socket)

              "delete_walkability_test" ->
                handle_event(event, %{"id" => id}, socket)

              _ ->
                {:noreply,
                 socket
                 |> assign(:pending_action, nil)
                 |> assign(:confirmation_execution?, false)
                 |> clear_confirmation()
                 |> put_flash(:error, "Unsupported confirmation action.")}
            end

          {:error, _reason} ->
            {:noreply,
             socket
             |> clear_confirmation()
             |> put_flash(:error, "This action is no longer available.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    stop_id = socket.assigns[:stop_id]

    if version_id && stop_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      path = "/gtfs/#{version_id}/stops/#{stop_id}/diagram"
      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_level", %{"level_id" => level_id}, socket) do
    level =
      Enum.find(socket.assigns.levels, fn existing_level ->
        to_string(existing_level.id) == level_id
      end)

    case level do
      nil ->
        {:noreply, assign(socket, :diagram_error, "Invalid level selection")}

      selected_level ->
        {:noreply,
         socket
         |> discard_pending_diagram_upload()
         |> disable_measurement()
         |> assign(:active_level, selected_level)
         |> assign(:pending_xy, nil)
         |> assign(:diagram_error, nil)
         |> assign(:show_diagram_upload_drawer, false)
         |> assign(:show_walkability_drawer, false)
         |> assign(:walkability_stop, nil)
         |> assign(
           :walkability_form,
           to_form(default_walkability_form_params(), as: :walkability)
         )
         |> clear_walkability_selection()
         |> assign(:walkability_last_results, [])
         |> assign(:walkability_mode, :create)
         |> assign(:editing_walkability_test, nil)
         |> reset_reposition_state()
         |> load_station_stop_levels_cache()
         |> assign(:other_levels_floorplan, MapSet.new())
         |> assign(:other_levels_stops, MapSet.new())
         |> reset_map_workflow()
         |> load_level_data(selected_level)}
    end
  end

  def handle_event("switch_level", _params, socket) do
    {:noreply, assign(socket, :diagram_error, "Malformed level selection request")}
  end

  @impl true
  def handle_event("toggle_other_level_floorplan", %{"level-id" => id}, socket) do
    {:noreply, toggle_other_level(socket, :other_levels_floorplan, id, :floorplan_eligible?)}
  end

  @impl true
  def handle_event("toggle_other_level_floorplan", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_other_level_stops", %{"level-id" => id}, socket) do
    {:noreply, toggle_other_level(socket, :other_levels_stops, id, :stops_eligible?)}
  end

  @impl true
  def handle_event("toggle_other_level_stops", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("clear_other_levels", _params, socket) do
    {:noreply,
     socket
     |> assign(:other_levels_floorplan, MapSet.new())
     |> assign(:other_levels_stops, MapSet.new())
     |> assign_other_levels()
     |> push_other_levels()}
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => mode}, socket) do
    case parse_mode(mode) do
      {:ok, mode_atom} ->
        restore_mode_focus? = journal_mode_focus_transition?(socket, mode_atom)

        socket =
          if socket.assigns.mode == :connect do
            assign(socket, :selected_from_stop, nil)
          else
            socket
          end

        socket =
          socket
          |> transition_journal_mode(mode_atom)
          |> assign(:mode, mode_atom)
          |> assign(:dragging_stop_id, nil)
          |> reset_reposition_state()
          |> assign(:pending_xy, nil)
          |> assign(:active_point_id, nil)
          |> maybe_disable_measurement_for_mode(mode_atom)
          |> restream_mode_dependent_layers()
          |> assign(:other_levels_floorplan, MapSet.new())
          |> assign(:other_levels_stops, MapSet.new())
          |> reset_map_workflow()
          |> assign_other_levels()
          |> push_child_stop_markers()
          |> maybe_focus_journal_mode(mode_atom, restore_mode_focus?)

        {:noreply, socket}

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid mode selection")}
    end
  end

  def handle_event("switch_mode", _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid mode selection")}
  end

  @impl true
  def handle_event("toggle_measurement", _params, socket) do
    if socket.assigns.mode != :view do
      {:noreply, socket}
    else
      measurement_enabled = not socket.assigns.measurement_enabled

      socket =
        socket
        |> assign(:measurement_enabled, measurement_enabled)
        |> maybe_reset_ruler_for_measurement_toggle(measurement_enabled)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("canvas_click", %{"x" => x, "y" => y}, socket) do
    x = to_float(x)
    y = to_float(y)

    case socket.assigns.mode do
      :view ->
        {:noreply, handle_view_measure_click(socket, x, y)}

      :add ->
        if socket.assigns.reposition_mode do
          {:noreply,
           socket
           |> assign(:pending_xy, %{x: x, y: y})
           |> assign(:reposition_x, Float.to_string(x))
           |> assign(:reposition_y, Float.to_string(y))}
        else
          level_id =
            if socket.assigns.active_level, do: socket.assigns.active_level.level_id, else: ""

          form =
            to_form(%{
              "stop_id" => "",
              "stop_name" => "",
              "location_type" => "3",
              "level_id" => level_id,
              "wheelchair_boarding" => "0",
              "platform_code" => "",
              "stop_lat" => "",
              "stop_lon" => "",
              "x" => Float.to_string(x),
              "y" => Float.to_string(y)
            })

          {:noreply,
           socket
           |> reset_reposition_state()
           |> assign(:pending_xy, %{x: x, y: y})
           |> assign(:selected_stop_id, nil)
           |> assign(:editing_level, false)
           |> assign(:stop_id_mode, :auto)
           |> assign(:child_stop_form, form)}
        end

      # In :connect mode, stop selection is handled by the SVG
      # hit-target circles via phx-click="stop_clicked" — no proximity search needed.
      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_create_form", _params, socket) do
    level_id =
      if socket.assigns.active_level, do: socket.assigns.active_level.level_id, else: ""

    form =
      to_form(%{
        "stop_id" => "",
        "stop_name" => "",
        "location_type" => "3",
        "level_id" => level_id,
        "wheelchair_boarding" => "0",
        "platform_code" => "",
        "stop_lat" => "",
        "stop_lon" => "",
        "x" => "",
        "y" => ""
      })

    {:noreply,
     socket
     |> reset_reposition_state()
     |> assign(:pending_xy, %{x: nil, y: nil})
     |> assign(:selected_stop_id, nil)
     |> assign(:editing_level, false)
     |> assign(:stop_id_mode, :auto)
     |> assign(:child_stop_form, form)}
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    socket = restream_active_stop(socket)

    {:noreply,
     socket
     |> reset_reposition_state()
     |> assign(:pending_xy, nil)
     |> assign(:selected_stop_id, nil)
     |> assign(:active_point_id, nil)
     |> assign(:child_stop_form, to_form(%{}))}
  end

  @impl true
  def handle_event("enter_reposition_mode", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    reposition_stops =
      Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, station.id)

    pending_xy = socket.assigns.pending_xy

    {:noreply,
     socket
     |> assign(:reposition_mode, true)
     |> assign(:reposition_search, "")
     |> assign(:reposition_stops, reposition_stops)
     |> assign(:reposition_x, if(pending_xy, do: to_optional_string(pending_xy.x), else: ""))
     |> assign(:reposition_y, if(pending_xy, do: to_optional_string(pending_xy.y), else: ""))}
  end

  @impl true
  def handle_event("exit_reposition_mode", _params, socket) do
    {:noreply, reset_reposition_state(socket)}
  end

  @impl true
  def handle_event("validate_reposition_coordinates", params, socket) do
    {:noreply,
     socket
     |> assign(:reposition_x, params["x"] || "")
     |> assign(:reposition_y, params["y"] || "")}
  end

  @impl true
  def handle_event("reposition_search", %{"search" => %{"query" => search}}, socket) do
    {:noreply, assign(socket, :reposition_search, search)}
  end

  @impl true
  def handle_event("reposition_search", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("reposition_stop", params, socket) do
    active_level = socket.assigns.active_level

    with {:ok, x, y} <- reposition_read_coordinates(params, socket),
         {:ok, stop} <- reposition_validate_stop(params, socket),
         false <- is_nil(active_level) do
      do_reposition_stop(socket, stop, x, y, active_level.level_id)
    else
      {:error, :invalid_coordinate} ->
        {:noreply, put_flash(socket, :error, "Failed to re-position stop")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}

      true ->
        {:noreply, put_flash(socket, :error, "Failed to re-position stop")}
    end
  end

  @impl true
  def handle_event("stop_clicked", %{"id" => id}, socket) do
    case socket.assigns.mode do
      :connect ->
        handle_stop_selection(id, socket)

      :add ->
        {:noreply, socket}

      :view ->
        if socket.assigns.measurement_enabled do
          {:noreply, socket}
        else
          handle_event("edit_child_stop", %{"id" => id}, socket)
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("drag_start", %{"id" => id}, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station
    stop = Gtfs.get_stop(id)

    cond do
      socket.assigns.mode != :view ->
        Logger.debug("drag_start ignored: mode is not view",
          mode: socket.assigns.mode,
          stop_id: id
        )

        {:noreply, socket}

      is_nil(stop) ->
        Logger.debug("drag_start ignored: stop not found", stop_id: id)
        {:noreply, socket}

      stop.organization_id != organization_id or stop.gtfs_version_id != gtfs_version_id ->
        Logger.debug("drag_start ignored: organization/version mismatch",
          stop_id: id,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        )

        {:noreply, socket}

      not stop_belongs_to_station?(
        stop,
        station.stop_id,
        socket.assigns.platform_stop_ids
      ) ->
        Logger.debug("drag_start ignored: stop does not belong to station",
          stop_id: id,
          station_stop_id: station.stop_id
        )

        {:noreply, socket}

      is_nil(stop.diagram_coordinate) ->
        Logger.debug("drag_start ignored: stop has no diagram coordinates", stop_id: id)
        {:noreply, socket}

      true ->
        Logger.debug("drag_start accepted", stop_id: id)
        {:noreply, assign(socket, :dragging_stop_id, stop.id)}
    end
  end

  @impl true
  def handle_event("drag_start", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("drag_end", %{"id" => id, "x" => x, "y" => y}, socket) do
    Logger.debug("drag_end received",
      stop_id: id,
      x: x,
      y: y,
      dragging_stop_id: socket.assigns.dragging_stop_id
    )

    with dragging_stop_id when not is_nil(dragging_stop_id) <- socket.assigns.dragging_stop_id,
         true <- to_string(dragging_stop_id) == to_string(id),
         {:ok, parsed_x} <- parse_svg_coordinate(x),
         {:ok, parsed_y} <- parse_svg_coordinate(y),
         %Stop{} = stop <- Gtfs.get_stop(id),
         true <- stop.organization_id == socket.assigns.current_organization.id,
         true <- stop.gtfs_version_id == socket.assigns.current_gtfs_version.id,
         true <-
           stop_belongs_to_station?(
             stop,
             socket.assigns.station.stop_id,
             socket.assigns.platform_stop_ids
           ) do
      attrs = %{diagram_coordinate: %{"x" => parsed_x, "y" => parsed_y}}

      if coords_unchanged?(stop.diagram_coordinate, parsed_x, parsed_y) do
        {:noreply, assign(socket, :dragging_stop_id, nil)}
      else
        case Gtfs.update_stop(stop, attrs) do
          {:ok, updated_stop} ->
            Logger.debug("drag_end persisted", stop_id: id, x: parsed_x, y: parsed_y)

            maybe_record_change(
              socket.assigns.audit_ctx,
              :stop,
              stop,
              updated_stop,
              attrs
            )

            {:noreply,
             socket
             |> stream_insert(:child_stops, updated_stop)
             |> assign(:dragging_stop_id, nil)
             |> load_pathways_for_level(socket.assigns.active_level)
             |> maybe_refresh_history_entries("stop", updated_stop.id)}

          {:error, _changeset} ->
            Logger.debug("drag_end failed to persist", stop_id: id)

            {:noreply,
             socket
             |> assign(:dragging_stop_id, nil)
             |> put_flash(:error, "Failed to re-position stop")}
        end
      end
    else
      _ ->
        Logger.debug("drag_end rejected",
          stop_id: id,
          x: x,
          y: y,
          dragging_stop_id: socket.assigns.dragging_stop_id
        )

        {:noreply,
         socket
         |> assign(:dragging_stop_id, nil)
         |> put_flash(:error, "Invalid drag position")}
    end
  end

  @impl true
  def handle_event("drag_end", _params, socket) do
    {:noreply,
     socket
     |> assign(:dragging_stop_id, nil)
     |> put_flash(:error, "Invalid drag position")}
  end

  @impl true
  def handle_event("drag_cancel", _params, socket) do
    Logger.debug("drag_cancel received", dragging_stop_id: socket.assigns.dragging_stop_id)
    {:noreply, assign(socket, :dragging_stop_id, nil)}
  end

  @impl true
  def handle_event("cancel_placement", _params, socket) do
    socket = restream_active_stop(socket)

    {:noreply,
     socket
     |> assign(:placement_status, "Placement cancelled")
     |> assign(:pending_xy, nil)
     |> assign(:selected_stop_id, nil)
     |> assign(:active_point_id, nil)
     |> assign(:reposition_x, "")
     |> assign(:reposition_y, "")
     |> assign(:child_stop_form, to_form(%{}))
     |> reset_reposition_state()}
  end

  @impl true
  def handle_event("dismiss_placement_status", _params, socket) do
    {:noreply, assign(socket, :placement_status, nil)}
  end

  @impl true
  def handle_event("edit_child_stop", %{"id" => id}, socket) do
    stop = Gtfs.get_stop!(id)

    socket =
      case stop_diagram_point(stop) do
        {:ok, pending_xy} ->
          socket
          |> close_journal_panel(persist?: false)
          |> open_edit_sidebar(stop, pending_xy)

        :error ->
          put_flash(socket, :error, ~s(Stop "#{stop.stop_id}" has no diagram position))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search_stop", %{"stop_id_query" => query}, socket) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:noreply, socket}
    else
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id
      station = socket.assigns.station

      case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, query) do
        nil ->
          {:noreply, put_flash(socket, :error, "Stop \"#{query}\" not found")}

        stop ->
          platform_stop_ids =
            platform_stop_ids_for_station(organization_id, gtfs_version_id, station)

          belongs_to_station =
            stop.parent_station == station.stop_id or
              MapSet.member?(platform_stop_ids, stop.parent_station)

          diagram_point = stop_diagram_point(stop)

          cond do
            not belongs_to_station ->
              {:noreply,
               put_flash(socket, :error, "Stop \"#{query}\" does not belong to this station")}

            diagram_point == :error ->
              {:noreply, put_flash(socket, :error, "Stop \"#{query}\" has no diagram position")}

            true ->
              level =
                Enum.find(socket.assigns.levels, fn l ->
                  l.level_id == stop.level_id
                end)

              cond do
                is_nil(level) ->
                  {:noreply,
                   put_flash(
                     socket,
                     :error,
                     ~s(Stop "#{query}" is not assigned to a known station level)
                   )}

                true ->
                  socket =
                    if level.id != socket.assigns.active_level.id do
                      socket
                      |> disable_measurement()
                      |> assign(:active_level, level)
                      |> assign(:pending_xy, nil)
                      |> assign(:diagram_error, nil)
                      |> assign(:show_walkability_drawer, false)
                      |> assign(:walkability_stop, nil)
                      |> assign(
                        :walkability_form,
                        to_form(default_walkability_form_params(), as: :walkability)
                      )
                      |> clear_walkability_selection()
                      |> assign(:walkability_last_results, [])
                      |> assign(:walkability_mode, :create)
                      |> assign(:editing_walkability_test, nil)
                      |> reset_reposition_state()
                      |> load_station_stop_levels_cache()
                      |> load_level_data(level)
                    else
                      socket
                    end

                  {:ok, pending_xy} = diagram_point

                  {:noreply,
                   socket
                   |> open_edit_sidebar(stop, pending_xy)
                   |> push_event("center_on_stop", pending_xy)}
              end
          end
      end
    end
  end

  @impl true
  def handle_event("search_stop", %{"stop_id_query" => _query}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search_stop", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_level_edit", _params, socket) do
    {:noreply, assign(socket, :editing_level, !socket.assigns.editing_level)}
  end

  @impl true
  def handle_event("validate_child_stop", params, socket) do
    params =
      case socket.assigns.stop_id_mode do
        :auto ->
          generated_stop_id =
            Stop.generate_stop_id(
              parse_int(params["location_type"] || "3"),
              params["stop_name"] || ""
            )

          Map.put(params, "stop_id", generated_stop_id)

        :manual ->
          params
      end

    location_type = parse_int(params["location_type"] || "3")

    params =
      if location_type == 4 do
        Map.put_new(params, "parent_platform", "")
      else
        Map.put(params, "parent_platform", "")
      end

    {:noreply, assign(socket, :child_stop_form, to_form(params))}
  end

  @impl true
  def handle_event("toggle_stop_id_mode", _params, socket) do
    case socket.assigns.stop_id_mode do
      :auto ->
        {:noreply, assign(socket, :stop_id_mode, :manual)}

      :manual ->
        current_form = socket.assigns.child_stop_form
        current_params = current_form.params || %{}
        stop_name = current_params["stop_name"] || current_form[:stop_name].value || ""

        location_type =
          current_params["location_type"] || current_form[:location_type].value || "3"

        generated_stop_id =
          Stop.generate_stop_id(
            parse_int(location_type),
            stop_name
          )

        updated_params =
          current_params
          |> Map.put("stop_name", stop_name)
          |> Map.put("location_type", location_type)
          |> Map.put("stop_id", generated_stop_id)

        {:noreply,
         socket
         |> assign(:stop_id_mode, :auto)
         |> assign(:child_stop_form, to_form(updated_params))}
    end
  end

  @impl true
  def handle_event("save_child_stop", params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    with {:ok, x} <- parse_finite_float(params["x"]),
         {:ok, y} <- parse_finite_float(params["y"]) do
      location_type = parse_int(params["location_type"] || "3")
      selected_parent_platform = blank_to_nil(params["parent_platform"])
      platform_stop_ids = platform_stop_ids_for_station(organization_id, gtfs_version_id, station)

      parent_station =
        if location_type == 4 and MapSet.member?(platform_stop_ids, selected_parent_platform) do
          selected_parent_platform
        else
          station.stop_id
        end

      stop_id =
        if socket.assigns.stop_id_mode == :auto and socket.assigns.selected_stop_id == nil and
             params["stop_id"] not in [nil, ""] do
          Gtfs.unique_stop_id(organization_id, gtfs_version_id, params["stop_id"])
        else
          params["stop_id"]
        end

      stop_attrs = %{
        stop_id: stop_id,
        stop_name: params["stop_name"],
        location_type: location_type,
        parent_station: parent_station,
        level_id: params["level_id"],
        wheelchair_boarding: parse_optional_int(params["wheelchair_boarding"]),
        platform_code: blank_to_nil(params["platform_code"]),
        stop_lat: params["stop_lat"],
        stop_lon: params["stop_lon"],
        diagram_coordinate: %{"x" => x, "y" => y},
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      }

      case socket.assigns.selected_stop_id do
        nil ->
          case Gtfs.create_stop(stop_attrs) do
            {:ok, stop} ->
              Gtfs.record_change(
                socket.assigns.audit_ctx,
                :stop,
                stop,
                "created",
                stop_attrs
              )

              {:noreply,
               socket
               |> stream_insert(:child_stops, stop)
               |> refresh_lists()
               |> assign(
                 :placement_status,
                 "Stop placed at (#{Float.to_string(x)}, #{Float.to_string(y)})"
               )
               |> assign(:pending_xy, nil)
               |> assign(:selected_stop_id, nil)
               |> assign(:active_point_id, nil)
               |> assign(:child_stop_form, to_form(%{}))}

            {:error, changeset} ->
              {:noreply, assign(socket, :child_stop_form, to_form(changeset))}
          end

        selected_id ->
          stop = Gtfs.get_stop!(selected_id)

          stop_attrs_result =
            if stop_attrs.stop_id in [nil, ""] do
              case Gtfs.generate_kebab_stop_id(
                     organization_id,
                     gtfs_version_id,
                     stop_attrs.stop_name,
                     stop.stop_id
                   ) do
                {:ok, generated} -> {:ok, %{stop_attrs | stop_id: generated}}
                {:error, msg} -> {:error, msg}
              end
            else
              {:ok, stop_attrs}
            end

          {result, applied_attrs} =
            case stop_attrs_result do
              {:error, msg} ->
                changeset =
                  stop
                  |> Stop.changeset(stop_attrs)
                  |> Ecto.Changeset.add_error(:stop_id, msg)
                  |> Map.put(:action, :validate)

                {{:error, changeset}, stop_attrs}

              {:ok, resolved_attrs} ->
                update_result =
                  if resolved_attrs.stop_id != stop.stop_id do
                    Gtfs.update_stop_with_cascade(stop, resolved_attrs)
                  else
                    Gtfs.update_stop(stop, resolved_attrs)
                  end

                {update_result, resolved_attrs}
            end

          case result do
            {:ok, updated_stop} ->
              Gtfs.record_change(
                socket.assigns.audit_ctx,
                :stop,
                stop,
                "updated",
                applied_attrs
              )

              refresh_plan =
                child_stop_refresh_plan(stop, updated_stop, socket.assigns.active_level)

              {:noreply,
               socket
               |> assign(:placement_status, "Stop updated")
               |> close_child_stop_drawer_after_save()
               |> apply_child_stop_save_refresh(refresh_plan, updated_stop)
               |> maybe_refresh_history_entries("stop", updated_stop.id)}

            {:error, changeset} ->
              {:noreply, assign(socket, :child_stop_form, to_form(changeset))}
          end
      end
    else
      {:error, :invalid_coordinate} ->
        {:noreply,
         socket
         |> put_flash(:error, "Diagram X and Y must be valid finite numbers")
         |> assign(:child_stop_form, to_form(params))}
    end
  end

  @impl true
  def handle_event("remove_from_diagram", %{"id" => stop_id}, socket) do
    if confirmed_action?(socket, :remove_from_diagram, stop_id) do
      do_remove_from_diagram(stop_id, socket)
    else
      {:noreply, reject_unconfirmed_action(socket)}
    end
  end

  @impl true
  def handle_event("delete_child_stop", %{"id" => stop_id}, socket) do
    if confirmed_action?(socket, :delete_child_stop, stop_id) do
      do_delete_child_stop(stop_id, socket)
    else
      {:noreply, reject_unconfirmed_action(socket)}
    end
  end

  @impl true
  def handle_event(
        "create_pathway",
        %{"from_stop_id" => from_stop_id, "to_stop_id" => to_stop_id},
        socket
      ) do
    create_pathway_between_stops(socket, from_stop_id, to_stop_id)
  end

  @impl true
  def handle_event("delete_pathway", %{"id" => pathway_id}, socket) do
    if confirmed_action?(socket, :delete_pathway, pathway_id) do
      do_delete_pathway(pathway_id, socket)
    else
      {:noreply, reject_unconfirmed_action(socket)}
    end
  end

  @impl true
  def handle_event("edit_pathway", %{"id" => id}, socket) do
    if socket.assigns.mode == :add do
      {:noreply, socket}
    else
      pathway = Gtfs.get_pathway_with_stops!(id)

      {:noreply,
       socket
       |> close_journal_panel(persist?: false)
       |> open_pathway_drawer(pathway)}
    end
  end

  @impl true
  def handle_event("switch_pathway_tab", %{"tab" => tab}, socket)
      when tab in ["first", "second"] do
    with pair when is_list(pair) <- socket.assigns.editing_pathway_pair,
         pathway when not is_nil(pathway) <- pathway_for_tab(pair, tab) do
      active_tab = if tab == "second", do: :second, else: :first

      {:noreply,
       socket
       |> assign(:active_pathway_tab, active_tab)
       |> assign(:pathway_form_dirty, false)
       |> assign(:editing_pathway, pathway)
       |> assign(:pathway_form, to_form(pathway_form_params(pathway)))
       |> assign(:pathway_error, nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("switch_pathway_tab", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_second_pathway", _params, socket) do
    editing_pathway = socket.assigns.editing_pathway

    cond do
      is_nil(editing_pathway) or Map.get(editing_pathway, :is_cross_level, false) ->
        {:noreply, socket}

      true ->
        from_stop = editing_pathway.from_stop
        to_stop = editing_pathway.to_stop
        pair_key = normalize_pair_key(from_stop.stop_id, to_stop.stop_id)
        pair_count = Map.get(socket.assigns.pathway_pair_counts || %{}, pair_key, 0)

        if pair_count >= 2 do
          {:noreply, assign(socket, :pathway_error, "This stop pair already has two pathways")}
        else
          organization_id = socket.assigns.current_organization.id
          gtfs_version_id = socket.assigns.current_gtfs_version.id
          pathway_id = "pw_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

          attrs =
            %{
              pathway_id: pathway_id,
              from_stop_id: from_stop.stop_id,
              to_stop_id: to_stop.stop_id,
              pathway_mode: 1,
              is_bidirectional: true,
              organization_id: organization_id,
              gtfs_version_id: gtfs_version_id
            }
            |> maybe_put_auto_pathway_length(socket, from_stop, to_stop)

          case Gtfs.create_pathway(attrs) do
            {:ok, pathway} ->
              Gtfs.record_change(
                socket.assigns.audit_ctx,
                :pathway,
                pathway,
                "created",
                attrs
              )

              loaded_pathway = Gtfs.get_pathway_with_stops!(pathway.id)
              refreshed_socket = refresh_lists(socket)

              pathway_pair =
                pair_siblings_for(loaded_pathway, refreshed_socket.assigns.pathways_list)

              {:noreply,
               refreshed_socket
               |> assign(:show_pathway_drawer, true)
               |> assign(:editing_pathway_pair, pathway_pair)
               |> assign(:active_pathway_tab, tab_for_pathway(pathway_pair, loaded_pathway))
               |> assign(:pathway_form_dirty, false)
               |> assign(:editing_pathway, loaded_pathway)
               |> assign(:pathway_form, to_form(pathway_form_params(loaded_pathway)))
               |> assign(:pathway_error, nil)}

            {:error, _changeset} ->
              {:noreply, assign(socket, :pathway_error, "Failed to create pathway")}
          end
        end
    end
  end

  @impl true
  def handle_event("clear_from_selection", _params, socket) do
    socket =
      if socket.assigns.selected_from_stop do
        stop = socket.assigns.selected_from_stop
        stream_insert(socket, :child_stops, stop)
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:selected_from_stop, nil)
     |> assign(:active_point_id, nil)}
  end

  @impl true
  def handle_event("select_from_stop", %{"from_id" => ""}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_from_stop", %{"from_id" => from_id}, socket) do
    # If same stop is already selected, no-op
    socket =
      if socket.assigns.selected_from_stop && socket.assigns.selected_from_stop.id == from_id do
        socket
      else
        # Deselect current from-stop if any (clear shared selection state)
        socket =
          if socket.assigns.selected_from_stop do
            stop = socket.assigns.selected_from_stop

            socket
            |> stream_insert(:child_stops, stop)
            |> assign(:selected_from_stop, nil)
            |> assign(:active_point_id, nil)
          else
            socket
          end

        # Select new from-stop through shared handle_stop_selection
        case handle_stop_selection(from_id, socket) do
          {:noreply, socket} -> socket
          _ -> socket
        end
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_to_stop", %{"to_id" => ""}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_to_stop", %{"to_id" => to_id}, socket) do
    handle_stop_selection(to_id, socket)
  end

  @impl true
  def handle_event("close_pathway_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_pathway_drawer, false)
     |> assign(:editing_pathway_pair, [])
     |> assign(:active_pathway_tab, :first)
     |> assign(:pathway_form_dirty, false)
     |> assign(:editing_pathway, nil)
     |> assign(:pathway_form, to_form(%{}))}
  end

  @impl true
  def handle_event("pathway_form_changed", params, socket) do
    form_params =
      case Map.get(params, "pathway") do
        nil -> Map.drop(params, ["_target"])
        nested -> nested
      end

    {:noreply,
     socket
     |> assign(:pathway_form, to_form(form_params))
     |> assign(:pathway_error, nil)
     |> assign(:pathway_form_dirty, true)}
  end

  @impl true
  def handle_event("save_ruler", %{"ruler" => %{"distance_meters" => distance_input}}, socket) do
    active_stop_level = socket.assigns.active_stop_level
    point_a = socket.assigns.ruler_point_a
    point_b = socket.assigns.ruler_point_b

    socket =
      assign(socket, :ruler_form, to_form(%{"distance_meters" => distance_input}, as: :ruler))

    with %{} <- point_a,
         %{} <- point_b,
         %Decimal{} = distance_meters <- parse_positive_decimal(distance_input),
         svg_distance when svg_distance >= 0.001 <- euclidean_distance(point_a, point_b),
         %StopLevel{} = stop_level <- active_stop_level do
      meters_per_unit = Decimal.div(distance_meters, Decimal.from_float(svg_distance))

      attrs = %{
        scale_point_a: point_a,
        scale_point_b: point_b,
        scale_distance_meters: distance_meters,
        scale_meters_per_unit: meters_per_unit
      }

      case Gtfs.save_scale_and_recalculate(
             stop_level,
             attrs,
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
             socket.assigns.active_level.id,
             socket.assigns.station.id
           ) do
        {:ok, %{stop_level: updated_stop_level, recalculated_count: recalculated_count}} ->
          {:noreply,
           socket
           |> assign(:active_stop_level, updated_stop_level)
           |> assign(:measurement_enabled, false)
           |> reset_ruler_state()
           |> assign(
             :scale_status,
             "Scale updated - #{recalculated_count} pathway length(s) recalculated"
           )}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:ruler_form, to_form(%{"distance_meters" => distance_input}, as: :ruler))
           |> assign(:scale_status, "Failed to save scale")}
      end
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Distance must be greater than 0 meters")}

      svg_distance when is_float(svg_distance) ->
        {:noreply, put_flash(socket, :error, "Choose two distinct points for calibration")}

      _ ->
        {:noreply, put_flash(socket, :error, "Choose two points and enter a valid distance")}
    end
  end

  def handle_event("save_ruler", _params, socket) do
    {:noreply, put_flash(socket, :error, "Choose two points and enter a valid distance")}
  end

  @impl true
  def handle_event("clear_ruler", _params, socket) do
    {:noreply, reset_ruler_state(socket)}
  end

  @impl true
  def handle_event("close_ruler_drawer", _params, socket) do
    {:noreply, reset_ruler_state(socket)}
  end

  @impl true
  def handle_event("dismiss_scale_status", _params, socket) do
    {:noreply, assign(socket, :scale_status, nil)}
  end

  @impl true
  def handle_event("clear_calibration", _params, socket) do
    case socket.assigns.active_stop_level do
      %StopLevel{} = stop_level ->
        case Gtfs.clear_stop_level_scale(stop_level) do
          {:ok, cleared_stop_level} ->
            {:noreply,
             socket
             |> assign(:active_stop_level, cleared_stop_level)
             |> reset_ruler_state()
             |> assign(:scale_status, "Scale removed - pathway measurements unchanged")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to clear diagram scale")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "save_alignment",
        %{"generation" => generation} = params,
        socket
      ) do
    if current_map_generation?(socket, generation) do
      save_alignment(params, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_alignment", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "preview_coordinate_application",
        %{
          "generation" => generation,
          "center_lat" => lat,
          "center_lon" => lon,
          "scale_mpp" => mpp,
          "rotation_deg" => rot
        },
        socket
      ) do
    stop_level = socket.assigns.active_stop_level
    image_w = socket.assigns.floorplan_image_w
    image_h = socket.assigns.floorplan_image_h

    cond do
      not current_map_generation?(socket, generation) ->
        {:noreply, socket}

      is_nil(stop_level) ->
        {:noreply, put_flash(socket, :error, "No level selected")}

      is_nil(image_w) or is_nil(image_h) ->
        {:noreply, put_flash(socket, :error, apply_alignment_error_message(:invalid_image_dims))}

      true ->
        attrs = %{
          floorplan_center_lat: lat,
          floorplan_center_lon: lon,
          floorplan_scale_mpp: mpp,
          floorplan_rotation_deg: rot
        }

        case Gtfs.preview_stop_level_coordinate_application(
               stop_level.id,
               attrs,
               image_w,
               image_h
             ) do
          {:ok, preview} ->
            {:noreply,
             socket
             |> assign(:coordinate_preview, Map.put(preview, :generation, generation))
             |> assign(:coordinate_confirmation, false)
             |> assign(
               :coordinate_apply_form,
               to_form(%{"phrase" => ""}, as: :coordinate_preview)
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               alignment_changeset_error_message("Could not save alignment", changeset)
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, apply_alignment_error_message(reason))}
        end
    end
  end

  def handle_event("preview_coordinate_application", _params, socket), do: {:noreply, socket}

  # The former immediate persistence event is deliberately inert. Map hooks
  # now submit only a generation-tagged preview request, and the server-owned
  # confirmation below is the sole route to coordinate persistence.
  def handle_event("save_and_apply_alignment", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_coordinate_preview_confirmation", _params, socket) do
    if current_coordinate_preview?(socket) do
      {:noreply, assign(socket, :coordinate_confirmation, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_coordinate_preview", _params, socket) do
    {:noreply,
     socket
     |> assign(:coordinate_confirmation, false)
     |> assign(:coordinate_apply_form, to_form(%{"phrase" => ""}, as: :coordinate_preview))}
  end

  @impl true
  def handle_event(
        "apply_coordinate_preview",
        %{"coordinate_preview" => %{"phrase" => "APPLY"}},
        socket
      ) do
    case socket.assigns.coordinate_preview do
      %{generation: generation} = preview ->
        if current_map_generation?(socket, generation) do
          case Gtfs.apply_stop_level_coordinate_preview(Map.delete(preview, :generation)) do
            {:ok, %{active_stop_level: updated, touched_stop_count: count}} ->
              {:noreply,
               socket
               |> assign(:active_stop_level, updated)
               |> assign(:coordinate_preview, nil)
               |> assign(:coordinate_confirmation, false)
               |> assign(:other_level_markers_cache, %{})
               |> assign(:other_level_counts_cache, %{})
               |> load_station_stop_levels_cache()
               |> refresh_lists()
               |> put_flash(:info, "Applied coordinates to #{count} child stops")}

            {:error, reason} when reason in [:stale_preview, :busy] ->
              {:noreply,
               socket
               |> clear_coordinate_preview()
               |> put_flash(:error, coordinate_preview_error_message(reason))}

            {:error, _reason} ->
              {:noreply,
               socket
               |> clear_coordinate_preview()
               |> put_flash(:error, "Could not apply coordinate preview")}
          end
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("apply_coordinate_preview", _params, socket) do
    {:noreply, put_flash(socket, :error, "Type APPLY to confirm coordinate changes")}
  end

  @impl true
  def handle_event(
        "set_image_natural_size",
        %{"generation" => generation, "w" => w, "h" => h},
        socket
      ) do
    case {current_map_generation?(socket, generation), coerce_positive_integer(w),
          coerce_positive_integer(h)} do
      {true, {:ok, w_int}, {:ok, h_int}} ->
        {:noreply,
         socket
         |> assign(:floorplan_image_w, w_int)
         |> assign(:floorplan_image_h, h_int)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_image_natural_size", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("map_ready", %{"generation" => generation}, socket) do
    if current_map_generation?(socket, generation),
      do: {:noreply, push_child_stop_markers(socket)},
      else: {:noreply, socket}
  end

  def handle_event("map_ready", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("map_state", %{"generation" => generation, "state" => state}, socket) do
    if current_map_generation?(socket, generation) and
         state in ~w(initializing ready imagery_unavailable buildings_degraded offline reconnecting fatal) do
      {:noreply, assign(socket, :map_state, map_state_from_string(state))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("map_state", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry_map_alignment", _params, socket) do
    {:noreply,
     socket
     |> assign(:map_state, :reconnecting)
     |> push_event("retry_map_alignment", %{generation: socket.assigns.map_generation})}
  end

  @impl true
  def handle_event("infer_alignment", _params, socket) do
    stop_level = socket.assigns.active_stop_level
    image_w = socket.assigns.floorplan_image_w
    image_h = socket.assigns.floorplan_image_h

    if is_nil(stop_level) or is_nil(image_w) or is_nil(image_h) do
      {:noreply,
       put_flash(socket, :error, "Infer alignment requires an active level and floorplan image")}
    else
      case Gtfs.save_inferred_level_alignment(stop_level, image_w, image_h) do
        {:ok, updated, %{inferred_alignment: %{anchor_count: n, rmse_meters: rmse}}} ->
          rmse_str = :erlang.float_to_binary(rmse, decimals: 2)
          socket = assign(socket, :active_stop_level, updated)

          case Gtfs.apply_alignment_to_child_stops(updated, image_w, image_h) do
            {:ok, count} ->
              {:noreply,
               socket
               |> refresh_lists()
               |> put_flash(
                 :info,
                 "Set lat/lon for #{count} child stops (#{n} anchors, RMSE #{rmse_str} m)"
               )}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, apply_alignment_error_message(reason))}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, infer_alignment_error_message(reason))}
      end
    end
  end

  @impl true
  def handle_event("scale_line_click", _params, socket) do
    stop_level = socket.assigns.active_stop_level

    case stop_level do
      %StopLevel{} when not is_nil(stop_level.scale_distance_meters) ->
        distance_str = Decimal.to_string(stop_level.scale_distance_meters)

        {:noreply,
         socket
         |> assign(:measurement_enabled, true)
         |> assign(:ruler_point_a, scale_point(stop_level, :scale_point_a))
         |> assign(:ruler_point_b, scale_point(stop_level, :scale_point_b))
         |> assign(:show_ruler_drawer, true)
         |> assign(:ruler_form, to_form(%{"distance_meters" => distance_str}, as: :ruler))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_walkability_drawer", %{"id" => id}, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station
    stop = Gtfs.get_stop(id)

    cond do
      is_nil(stop) ->
        {:noreply, put_flash(socket, :error, "Invalid stop selection")}

      stop.organization_id != organization_id or stop.gtfs_version_id != gtfs_version_id ->
        {:noreply, put_flash(socket, :error, "Invalid stop selection")}

      not stop_belongs_to_station?(
        stop,
        station.stop_id,
        socket.assigns.platform_stop_ids
      ) ->
        {:noreply, put_flash(socket, :error, "Invalid stop selection")}

      true ->
        {:noreply,
         socket
         |> assign(:show_walkability_drawer, true)
         |> assign(:walkability_stop, stop)
         |> assign(
           :walkability_form,
           to_form(default_walkability_form_params(), as: :walkability)
         )
         |> clear_walkability_selection()
         |> assign(:walkability_last_results, [])
         |> assign(:walkability_error, nil)
         |> assign(:walkability_field_errors, %{})
         |> assign(:walkability_mode, :create)
         |> assign(:editing_walkability_test, nil)}
    end
  end

  @impl true
  def handle_event("edit_walkability_test", %{"id" => id}, socket) do
    case Validations.get_walkability_test(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Walkability test not found.")}

      walkability_test ->
        case validate_walkability_test_scope(socket, walkability_test) do
          {:ok, stop} ->
            form_params = walkability_test_form_params(walkability_test)

            {:noreply,
             socket
             |> assign(:show_walkability_drawer, true)
             |> assign(:walkability_stop, stop)
             |> assign(:walkability_form, to_form(form_params, as: :walkability))
             |> assign(:walkability_selected_address, walkability_test.address)
             |> assign(:walkability_selected_lat, walkability_test.address_lat)
             |> assign(:walkability_selected_lon, walkability_test.address_lon)
             |> assign(:walkability_selected_result, nil)
             |> assign(:walkability_last_results, [])
             |> assign(:walkability_error, nil)
             |> assign(:walkability_field_errors, %{})
             |> assign(:walkability_mode, :edit)
             |> assign(:editing_walkability_test, walkability_test)}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  @impl true
  def handle_event("close_walkability_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_walkability_drawer, false)
     |> assign(:walkability_stop, nil)
     |> assign(:walkability_form, to_form(default_walkability_form_params(), as: :walkability))
     |> clear_walkability_selection()
     |> assign(:walkability_last_results, [])
     |> assign(:walkability_error, nil)
     |> assign(:walkability_field_errors, %{})
     |> assign(:walkability_mode, :create)
     |> assign(:editing_walkability_test, nil)}
  end

  # --------------------------------------------------------------------------
  # Naming drawer events
  # --------------------------------------------------------------------------

  @impl true
  def handle_event("open_naming_drawer", _params, socket) do
    style = socket.assigns.naming_style

    {:noreply,
     socket
     |> assign(:show_naming_drawer, true)
     |> load_naming_preview(style)}
  end

  @impl true
  def handle_event("change_naming_style", %{"style" => style_str}, socket) do
    style = if style_str == "structured", do: :structured, else: :kebab

    {:noreply,
     socket
     |> assign(:naming_style, style)
     |> load_naming_preview(style)}
  end

  @impl true
  def handle_event("close_naming_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_naming_drawer, false)
     |> assign(:naming_style, :kebab)
     |> assign(:naming_preview, [])
     |> assign(:naming_renamed_stops_count, 0)
     |> assign(:naming_updated_pathways_count, 0)
     |> assign(:naming_applying?, false)
     |> assign(:naming_error, nil)
     |> assign(:naming_excluded_ids, MapSet.new())}
  end

  @impl true
  def handle_event("toggle_naming_row", %{"id" => old_id}, socket) do
    preview_ids = naming_preview_id_set(socket.assigns.naming_preview)
    excluded = MapSet.intersection(socket.assigns.naming_excluded_ids, preview_ids)

    excluded =
      cond do
        not MapSet.member?(preview_ids, old_id) ->
          excluded

        MapSet.member?(excluded, old_id) ->
          MapSet.delete(excluded, old_id)

        true ->
          MapSet.put(excluded, old_id)
      end

    {:noreply, assign_naming_selection(socket, excluded)}
  end

  @impl true
  def handle_event("toggle_naming_select_all", _params, socket) do
    preview = socket.assigns.naming_preview
    preview_ids = naming_preview_id_set(preview)
    excluded = MapSet.intersection(socket.assigns.naming_excluded_ids, preview_ids)

    {excluded, selected_count} =
      if MapSet.size(excluded) == 0 do
        {preview_ids, 0}
      else
        {MapSet.new(), length(preview)}
      end

    {:noreply,
     socket
     |> assign_naming_selection(excluded)
     |> assign(:naming_renamed_stops_count, selected_count)}
  end

  @impl true
  def handle_event(
        "apply_naming_convention",
        _params,
        %{assigns: %{naming_applying?: true}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("apply_naming_convention", _params, socket) do
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    station_stop_id = socket.assigns.station.stop_id
    style = socket.assigns.naming_style
    excluded = socket.assigns.naming_excluded_ids

    selected_ids =
      socket.assigns.naming_preview
      |> MapSet.new(& &1.old_id)
      |> MapSet.difference(excluded)

    socket = assign(socket, :naming_applying?, true)

    case Gtfs.apply_station_naming(org_id, version_id, station_stop_id, style, selected_ids) do
      {:ok, %{renamed_stops: stops, updated_pathways: pathways}} ->
        status =
          "Renamed #{stops} #{ngettext("child stop", "child stops", stops)}, " <>
            "updated #{pathways} #{ngettext("pathway reference", "pathway references", pathways)}."

        {:noreply,
         socket
         |> assign(:show_naming_drawer, false)
         |> assign(:naming_style, :kebab)
         |> assign(:naming_preview, [])
         |> assign(:naming_applying?, false)
         |> assign(:naming_error, nil)
         |> assign(:naming_excluded_ids, MapSet.new())
         |> assign(:naming_status, status)
         |> refresh_lists()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:naming_applying?, false)
         |> assign(:naming_error, "Failed to apply naming: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("dismiss_naming_status", _params, socket) do
    {:noreply, assign(socket, :naming_status, nil)}
  end

  @impl true
  def handle_event("set_station_editing_status", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.set_station_editing_status(
           organization_id,
           gtfs_version_id,
           socket.assigns.station,
           socket.assigns.current_user
         ) do
      {:ok, status} ->
        {:noreply, assign(socket, :station_editing_status, status)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to set station editing status")}
    end
  end

  @impl true
  def handle_event("clear_station_editing_status", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    :ok =
      Gtfs.clear_station_editing_status(
        organization_id,
        gtfs_version_id,
        socket.assigns.station.id
      )

    {:noreply, assign(socket, :station_editing_status, nil)}
  end

  @impl true
  def handle_event("open_diagram_upload_drawer", _params, socket) do
    has_diagram =
      not is_nil(
        socket.assigns.active_stop_level && socket.assigns.active_stop_level.diagram_filename
      )

    cond do
      is_nil(socket.assigns.active_level) ->
        {:noreply, socket}

      not has_diagram ->
        {:noreply, socket}

      socket.assigns.upload_phase in [:uploading, :validating, :probing_candidate, :committing] ->
        {:noreply, socket}

      true ->
        {:noreply, assign(socket, :show_diagram_upload_drawer, true)}
    end
  end

  @impl true
  def handle_event("close_diagram_upload_drawer", _params, socket) do
    socket =
      case socket.assigns.upload_phase do
        phase when phase in [:uploading, :validating, :probing_candidate] ->
          socket

        _ ->
          cancel_all_diagram_uploads(socket)
      end

    {:noreply, assign(socket, :show_diagram_upload_drawer, false)}
  end

  @impl true
  def handle_event(
        "live_select_change",
        %{"text" => text, "id" => "walkability_address_autocomplete_component"},
        socket
      ) do
    case Geocoding.autocomplete(text) do
      {:ok, results} ->
        options =
          Enum.map(results, fn result ->
            %{
              label: result.formatted_address,
              value: result,
              option: result.formatted_address
            }
          end)

        send_update(LiveSelectComponent,
          id: "walkability_address_autocomplete_component",
          options: options
        )

        {:noreply, assign(socket, :walkability_last_results, results)}

      {:error, _reason} ->
        send_update(LiveSelectComponent,
          id: "walkability_address_autocomplete_component",
          options: []
        )

        {:noreply, assign(socket, :walkability_last_results, [])}
    end
  end

  @impl true
  def handle_event("live_select_change", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("live_select_blur", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("walkability_form_change", %{"walkability" => walkability_params}, socket) do
    # Persist all form field values across re-renders
    current_params = socket.assigns.walkability_form.params || %{}
    merged_params = Map.merge(current_params, walkability_params)
    socket = assign(socket, :walkability_form, to_form(merged_params, as: :walkability))

    case Map.get(walkability_params, "address_autocomplete") do
      selection when is_binary(selection) and selection != "" ->
        {:noreply, apply_walkability_selection_from_form(socket, selection)}

      "" ->
        {:noreply, clear_walkability_selection(socket)}

      _ ->
        # Ignore text-input-only changes (e.g. blur/debounce cycles) so a valid
        # selected address is not accidentally cleared.
        {:noreply, socket}
    end
  end

  def handle_event("walkability_form_change", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("run_walkability_tests", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    walkability_tests = socket.assigns.walkability_tests_list

    case walkability_tests do
      [] ->
        {:noreply, put_flash(socket, :error, "No reachability test cases to run.")}

      _tests ->
        purge_otp_artifact(organization_id, gtfs_version_id)

        case Materializer.get_or_build_gtfs_zip(organization_id, gtfs_version_id) do
          {:ok, _zip_path, _meta} ->
            {:noreply,
             put_flash(
               socket,
               :info,
               "Reachability test run started. Export preparation complete."
             )}

          {:error, _issues} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Could not prepare GTFS export for reachability test run."
             )}
        end
    end
  end

  @impl true
  def handle_event("save_walkability_test", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    stop = socket.assigns.walkability_stop
    address = socket.assigns.walkability_selected_address
    address_lat = socket.assigns.walkability_selected_lat
    address_lon = socket.assigns.walkability_selected_lon
    form_params = socket.assigns.walkability_form.params || %{}

    cond do
      is_nil(stop) ->
        {:noreply,
         socket
         |> put_flash(:error, "Select a stop before saving.")
         |> assign(:walkability_error, "Select a stop before saving.")
         |> assign(:walkability_field_errors, %{})
         |> push_event("scroll_to_error", %{id: "walkability-error"})}

      is_nil(address) or is_nil(address_lat) or is_nil(address_lon) ->
        {:noreply,
         socket
         |> put_flash(:error, "Select an address from autocomplete.")
         |> assign(:walkability_error, "Select an address from autocomplete.")
         |> assign(:walkability_field_errors, %{})
         |> push_event("scroll_to_error", %{id: "walkability-error"})}

      true ->
        attrs = %{
          stop_id: stop.stop_id,
          address: address,
          address_lat: address_lat,
          address_lon: address_lon,
          description: form_params["description"],
          expected_traversable: form_params["expected_traversable"] == "true",
          expected_wheelchair_accessible: form_params["expected_wheelchair_accessible"] == "true",
          expected_min_duration_seconds:
            parse_optional_integer(form_params["expected_min_duration_seconds"]),
          expected_max_duration_seconds:
            parse_optional_integer(form_params["expected_max_duration_seconds"]),
          expected_min_distance_meters:
            parse_optional_integer(form_params["expected_min_distance_meters"]),
          expected_max_distance_meters:
            parse_optional_integer(form_params["expected_max_distance_meters"])
        }

        case socket.assigns.walkability_mode do
          :edit ->
            save_walkability_test_edit(socket, organization_id, attrs)

          :create ->
            save_walkability_test_create(socket, organization_id, attrs)
        end
    end
  end

  @impl true
  def handle_event("delete_walkability_test", %{"id" => id}, socket) do
    if confirmed_action?(socket, :delete_walkability_test, id) do
      do_delete_walkability_test(id, socket)
    else
      {:noreply, reject_unconfirmed_action(socket)}
    end
  end

  @impl true
  def handle_event("calculate_pathway_length", _params, socket) do
    editing_pathway = socket.assigns.editing_pathway
    active_stop_level = socket.assigns.active_stop_level

    cond do
      is_nil(editing_pathway) ->
        {:noreply, assign(socket, :pathway_error, "Pathway not found.")}

      not scale_configured?(active_stop_level) ->
        {:noreply, assign(socket, :pathway_error, "Scale is not configured for this level.")}

      is_nil(editing_pathway.from_stop) or is_nil(editing_pathway.to_stop) ->
        {:noreply, assign(socket, :pathway_error, "Pathway is not fully associated with stops.")}

      editing_pathway.from_stop.level_id != editing_pathway.to_stop.level_id ->
        {:noreply,
         assign(socket, :pathway_error, "Length calculation requires stops on the same level.")}

      true ->
        case Gtfs.calculate_pathway_length(
               active_stop_level,
               editing_pathway.from_stop,
               editing_pathway.to_stop
             ) do
          %Decimal{} = calculated_length ->
            current_params = socket.assigns.pathway_form.params || %{}
            formatted_length = format_pathway_length_for_form(calculated_length)
            updated_params = Map.put(current_params, "length", formatted_length)

            {:noreply,
             socket
             |> assign(:pathway_form, to_form(updated_params))
             |> assign(:pathway_error, nil)}

          _ ->
            {:noreply,
             assign(
               socket,
               :pathway_error,
               "Could not calculate length from current stop coordinates."
             )}
        end
    end
  end

  @impl true
  def handle_event("save_pathway", params, socket) do
    params = Map.get(params, "pathway", params)
    editing_pathway = socket.assigns.editing_pathway

    attrs = %{
      pathway_mode: parse_int(params["pathway_mode"]),
      is_bidirectional: params["is_bidirectional"] == "true",
      traversal_time: parse_optional_int(params["traversal_time"]),
      length: parse_optional_decimal(params["length"]),
      stair_count: parse_optional_int(params["stair_count"]),
      min_width: parse_optional_decimal(params["min_width"]),
      signposted_as: params["signposted_as"],
      reversed_signposted_as: params["reversed_signposted_as"]
    }

    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    pathway = editing_pathway

    cond do
      is_nil(pathway) ->
        {:noreply,
         socket
         |> assign(:pathway_error, "Pathway not found.")
         |> assign(:pathway_form, to_form(params))}

      pathway.organization_id != organization_id or pathway.gtfs_version_id != gtfs_version_id ->
        {:noreply,
         socket
         |> assign(:pathway_error, "Unauthorized pathway access.")
         |> assign(:pathway_form, to_form(params))}

      is_nil(pathway.from_stop) or is_nil(pathway.to_stop) ->
        {:noreply,
         socket
         |> assign(:pathway_error, "Pathway is not fully associated with stops.")
         |> assign(:pathway_form, to_form(params))}

      not stop_belongs_to_station?(
        pathway.from_stop,
        station.stop_id,
        socket.assigns.platform_stop_ids
      ) or
          not stop_belongs_to_station?(
            pathway.to_stop,
            station.stop_id,
            socket.assigns.platform_stop_ids
          ) ->
        {:noreply,
         socket
         |> assign(:pathway_error, "Unauthorized pathway access.")
         |> assign(:pathway_form, to_form(params))}

      true ->
        case Gtfs.update_pathway(pathway, attrs) do
          {:ok, updated_pathway} ->
            maybe_record_change(
              socket.assigns.audit_ctx,
              :pathway,
              pathway,
              updated_pathway,
              attrs
            )

            {:noreply,
             socket
             |> apply_pathway_save_refresh(pathway, updated_pathway)
             |> close_pathway_drawer_after_save()
             |> maybe_refresh_history_entries("pathway", updated_pathway.id)}

          {:error, changeset} ->
            {:noreply, assign(socket, :pathway_form, to_form(changeset))}
        end
    end
  end

  @impl true
  def handle_event("flip_pathway", %{"id" => id}, socket) do
    pathway =
      try do
        Gtfs.get_pathway_with_stops!(id)
      rescue
        Ecto.NoResultsError -> nil
        Ecto.Query.CastError -> nil
      end

    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    cond do
      is_nil(pathway) ->
        {:noreply, assign(socket, :pathway_error, "Pathway not found.")}

      pathway.organization_id != organization_id or pathway.gtfs_version_id != gtfs_version_id ->
        {:noreply, assign(socket, :pathway_error, "Unauthorized pathway access.")}

      is_nil(pathway.from_stop) or is_nil(pathway.to_stop) ->
        {:noreply, assign(socket, :pathway_error, "Pathway is not fully associated with stops.")}

      not stop_belongs_to_station?(
        pathway.from_stop,
        station.stop_id,
        socket.assigns.platform_stop_ids
      ) or
          not stop_belongs_to_station?(
            pathway.to_stop,
            station.stop_id,
            socket.assigns.platform_stop_ids
          ) ->
        {:noreply, assign(socket, :pathway_error, "Unauthorized pathway access.")}

      true ->
        # Read current form values so pending edits are preserved through the flip.
        form = socket.assigns.pathway_form
        form_signposted = form[:signposted_as] && form[:signposted_as].value
        form_reversed = form[:reversed_signposted_as] && form[:reversed_signposted_as].value

        flip_attrs = %{
          from_stop_id: pathway.to_stop_id,
          to_stop_id: pathway.from_stop_id,
          # Swap signage from form values (preserves pending edits)
          signposted_as: form_reversed,
          reversed_signposted_as: form_signposted,
          # Preserve other pending form edits
          pathway_mode: parse_int(form[:pathway_mode] && form[:pathway_mode].value),
          is_bidirectional:
            (form[:is_bidirectional] && form[:is_bidirectional].value) in [true, "true"],
          traversal_time:
            parse_optional_int(form[:traversal_time] && form[:traversal_time].value),
          length: parse_optional_decimal(form[:length] && form[:length].value),
          stair_count: parse_optional_int(form[:stair_count] && form[:stair_count].value),
          min_width: parse_optional_decimal(form[:min_width] && form[:min_width].value)
        }

        case Gtfs.update_pathway(pathway, flip_attrs) do
          {:ok, updated_pathway} ->
            maybe_record_change(
              socket.assigns.audit_ctx,
              :pathway,
              pathway,
              updated_pathway,
              flip_attrs
            )

            refreshed_socket = refresh_lists(socket)
            reloaded = Gtfs.get_pathway_with_stops!(updated_pathway.id)

            pathway_pair =
              pair_siblings_for(
                %{from_stop_id: reloaded.from_stop_id, to_stop_id: reloaded.to_stop_id},
                refreshed_socket.assigns.pathways_list
              )

            active_pathway_tab =
              case pathway_pair do
                [_first, second] ->
                  if reloaded.id == second.id, do: :second, else: :first

                _ ->
                  :first
              end

            {:noreply,
             refreshed_socket
             |> assign(:editing_pathway, reloaded)
             |> assign(:editing_pathway_pair, pathway_pair)
             |> assign(:active_pathway_tab, active_pathway_tab)
             |> assign(:pathway_form, to_form(pathway_form_params(reloaded)))
             |> assign(:pathway_form_dirty, false)
             |> assign(:pathway_error, nil)
             |> maybe_refresh_history_entries("pathway", reloaded.id)}

          {:error, changeset} ->
            detail =
              changeset
              |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
              |> Enum.map_join("; ", fn {field, msgs} ->
                "#{field}: #{Enum.join(msgs, ", ")}"
              end)

            message =
              if detail == "",
                do: "Failed to flip pathway direction.",
                else: "Failed to flip: #{detail}"

            {:noreply, assign(socket, :pathway_error, message)}
        end
    end
  end

  @impl true
  def handle_event("flip_pathway", _params, socket) do
    {:noreply, assign(socket, :pathway_error, "Pathway not found.")}
  end

  @impl true
  def handle_event("upload_diagram", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_diagram_replacement", _params, socket) do
    case socket.assigns.pending_diagram_upload do
      %{entry_ref: _entry_ref} = pending
      when socket.assigns.upload_phase == :awaiting_replacement_confirmation ->
        {:noreply, stage_uploaded_diagram_candidate(socket, pending)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_diagram_replacement", _params, socket) do
    {:noreply, discard_pending_diagram_upload(socket)}
  end

  @impl true
  def handle_event("cancel_diagram_upload", %{"ref" => entry_ref}, socket) do
    socket =
      case socket.assigns.pending_diagram_upload do
        %{entry_ref: ^entry_ref} -> discard_pending_diagram_upload(socket)
        _ -> cancel_upload(socket, :diagram, entry_ref)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("diagram_candidate_probe_result", params, socket) do
    {:noreply, handle_diagram_candidate_probe_result(socket, params)}
  end

  @impl true
  def handle_event("save_diagram", _params, socket) do
    # Compatibility no-op: diagram uploads complete via allow_upload progress callback.
    {:noreply, socket}
  end

  @impl true
  def handle_event("open_add_level", _params, socket) do
    form =
      to_form(%{
        "mode" => "existing",
        "existing_level_id" => "",
        "level_id" => "",
        "level_name" => "",
        "level_index" => "0"
      })

    {:noreply,
     socket
     |> assign(:show_level_modal, :add)
     |> assign(:level_form, form)
     |> assign(:level_mode, :existing)
     |> assign(:level_id_manually_edited, false)}
  end

  @impl true
  def handle_event("level_mode_changed", %{"mode" => mode}, socket) do
    mode_atom = if mode == "new", do: :new, else: :existing
    {:noreply, assign(socket, :level_mode, mode_atom)}
  end

  @impl true
  def handle_event("open_edit_level", _params, socket) do
    level = socket.assigns.active_level

    form =
      to_form(%{
        "level_id" => level.level_id,
        "level_name" => level.level_name || "",
        "level_index" => to_string(level.level_index)
      })

    level_shared =
      Gtfs.level_used_by_other_stations?(
        socket.assigns.current_organization.id,
        socket.assigns.current_gtfs_version.id,
        level.id,
        socket.assigns.station.id
      )

    {:noreply,
     socket
     |> assign(:show_level_modal, :edit)
     |> assign(:level_form, form)
     |> assign(:level_shared, level_shared)
     |> assign(:level_id_manually_edited, true)}
  end

  @impl true
  def handle_event("close_level_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_level_modal, nil)
     |> assign(:level_form, to_form(%{}))}
  end

  @impl true
  def handle_event("remove_level_from_station", %{"id" => level_uuid}, socket) do
    if confirmed_action?(socket, :remove_level_from_station, level_uuid) do
      do_remove_level_from_station(level_uuid, socket)
    else
      {:noreply, reject_unconfirmed_action(socket)}
    end
  end

  @impl true
  def handle_event("level_id_changed", %{"value" => _value}, socket) do
    # Mark level_id as manually edited when user modifies it directly
    {:noreply, assign(socket, :level_id_manually_edited, true)}
  end

  @impl true
  def handle_event("level_name_changed", %{"level_name" => name} = params, socket) do
    current_form = socket.assigns.level_form
    current_index = current_form[:level_index].value || "0"

    # Get the level_id from params (user's current input) or from form
    current_level_id = params["level_id"] || current_form[:level_id].value || ""

    # Only auto-generate level_id if user hasn't manually edited it
    level_id =
      if socket.assigns.level_id_manually_edited do
        current_level_id
      else
        station_stop_id = socket.assigns.station.stop_id |> String.upcase()
        snakecase_name = to_snakecase_id(name)

        if snakecase_name == "" do
          ""
        else
          "#{station_stop_id}_#{snakecase_name}"
        end
      end

    form =
      to_form(%{
        "level_id" => level_id,
        "level_name" => name,
        "level_index" => current_index
      })

    {:noreply, assign(socket, :level_form, form)}
  end

  @impl true
  def handle_event("save_level", params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    case socket.assigns.show_level_modal do
      :add ->
        if socket.assigns.level_mode == :existing do
          existing_level_id = params["existing_level_id"]

          cond do
            existing_level_id in [nil, ""] ->
              {:noreply, put_flash(socket, :error, "Please select a level to add.")}

            level = Gtfs.get_level(existing_level_id) ->
              case Gtfs.create_stop_level(%{
                     stop_id: station.id,
                     level_id: level.id,
                     organization_id: organization_id,
                     gtfs_version_id: gtfs_version_id
                   }) do
                {:ok, _stop_level} ->
                  levels_data =
                    Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)

                  levels = Enum.map(levels_data, & &1.level)

                  {:noreply,
                   socket
                   |> assign(:levels, levels)
                   |> assign(:active_level, level)
                   |> assign(:show_level_modal, nil)
                   |> assign(:level_form, to_form(%{}))
                   |> refresh_level_and_stop_level_cache(level)}

                {:error, changeset} ->
                  {:noreply, assign(socket, :level_form, to_form(changeset))}
              end

            true ->
              {:noreply, put_flash(socket, :error, "Selected level could not be found.")}
          end
        else
          level_attrs = %{
            level_id: params["level_id"],
            level_name: params["level_name"],
            level_index: parse_int(params["level_index"]),
            organization_id: organization_id,
            gtfs_version_id: gtfs_version_id
          }

          case Gtfs.create_level(level_attrs) do
            {:ok, new_level} ->
              Gtfs.record_change(
                socket.assigns.audit_ctx,
                :level,
                new_level,
                "created",
                level_attrs
              )

              # Create the association
              {:ok, _stop_level} =
                Gtfs.create_stop_level(%{
                  stop_id: station.id,
                  level_id: new_level.id,
                  organization_id: organization_id,
                  gtfs_version_id: gtfs_version_id
                })

              levels_data =
                Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)

              levels = Enum.map(levels_data, & &1.level)
              # Refresh available levels list since we added one
              available_levels = Gtfs.list_all_levels(organization_id, gtfs_version_id)

              {:noreply,
               socket
               |> assign(:levels, levels)
               |> assign(:available_levels, available_levels)
               |> assign(:active_level, new_level)
               |> assign(:show_level_modal, nil)
               |> assign(:level_form, to_form(%{}))
               |> refresh_level_and_stop_level_cache(new_level)}

            {:error, changeset} ->
              {:noreply, assign(socket, :level_form, to_form(changeset))}
          end
        end

      :edit ->
        level = socket.assigns.active_level

        level_attrs = %{
          level_id: params["level_id"],
          level_name: params["level_name"],
          level_index: parse_int(params["level_index"])
        }

        case Gtfs.update_level_with_cascade(level, level_attrs) do
          {:ok, updated_level} ->
            maybe_record_change(
              socket.assigns.audit_ctx,
              :level,
              level,
              updated_level,
              Gtfs.entity_snapshot(:level, updated_level)
            )

            levels_data =
              Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)

            levels = Enum.map(levels_data, & &1.level)

            {:noreply,
             socket
             |> assign(:levels, levels)
             |> assign(:active_level, updated_level)
             |> assign(:show_level_modal, nil)
             |> assign(:level_form, to_form(%{}))
             |> refresh_level_and_stop_level_cache(updated_level)
             |> maybe_refresh_history_entries("level", updated_level.id)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :level_form, to_form(changeset))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to update level")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("show_history", %{"entity-type" => type, "entity-id" => id}, socket)
      when type in ["stop", "pathway", "level"] and is_binary(id) do
    if entity_belongs_to_current_station?(socket, type, id) do
      {:noreply,
       socket
       |> assign(:history_open_for, {type, id})
       |> assign(:history_entries, [])
       |> assign_history_filter("all")
       |> assign(:rollback_preview, nil)
       |> start_history_load(type, id, :initial_loading)}
    else
      {:noreply, put_flash(socket, :error, "History not available for this entity.")}
    end
  end

  def handle_event("show_history", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unable to load history: invalid request")}
  end

  @impl true
  def handle_event("hide_history", _params, socket) do
    {:noreply, reset_history(cancel_async(socket, @history_key))}
  end

  @impl true
  def handle_event("retry_history", _params, socket) do
    case socket.assigns.history_open_for do
      {type, id} ->
        state = if socket.assigns.history_entries == [], do: :initial_loading, else: :refreshing
        {:noreply, start_history_load(socket, type, id, state)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_history_filter", _params, socket) do
    {:noreply, assign_history_filter(socket, "all")}
  end

  # The entity type is read from server-owned state, never from the payload, so
  # a crafted request cannot widen the accepted filter vocabulary.
  @impl true
  def handle_event("filter_history", %{"key" => key}, socket) when is_binary(key) do
    case socket.assigns.history_open_for do
      {type, _id} ->
        if ChangeHistoryComponents.valid_filter_key?(type, key) do
          {:noreply, assign_history_filter(socket, key)}
        else
          {:noreply,
           socket
           |> assign_history_filter("all")
           |> put_flash(:error, "Unknown history filter")}
        end

      _ ->
        {:noreply, assign_history_filter(socket, "all")}
    end
  end

  def handle_event("filter_history", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("preview_rollback_change_log", %{"log-id" => log_id}, socket)
      when is_binary(log_id) do
    case Gtfs.get_change_log(log_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unable to preview rollback: change log not found")}

      log ->
        handle_rollback_preview_request(socket, log)
    end
  end

  def handle_event("preview_rollback_change_log", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unable to preview rollback: invalid parameters")}
  end

  @impl true
  def handle_event("cancel_rollback_preview", _params, socket) do
    {:noreply, assign(socket, :rollback_preview, nil)}
  end

  @impl true
  # Editor-role authorization is enforced by the
  # `{EnsureRole, :require_gtfs_access}` on_mount hook for this LiveView, which
  # already requires the `:pathways_studio_editor` role. An in-handler role
  # check would be redundant: if the user reaches this handler, they have
  # already passed mount-time authorization.
  def handle_event("confirm_rollback_change_log", %{"log-id" => log_id}, socket)
      when is_binary(log_id) do
    case socket.assigns.rollback_preview do
      %{log: %{id: ^log_id}} = preview ->
        case Gtfs.rollback_entity(preview.log, socket.assigns.audit_ctx) do
          {:ok, entity} ->
            # The panel takes focus immediately so the destroyed confirm button
            # never strands it on <body>; when the refreshed history arrives,
            # focus moves on to the entry that replaced it.
            {:noreply,
             socket
             |> apply_rollback_entity_refresh(preview.entity_type, entity)
             |> refresh_history_entries(preview.entity_type, preview.entity_id)
             |> assign(:rollback_preview, nil)
             |> assign(:history_focus_newest?, true)
             |> put_flash(:info, "Change reverted.")
             |> focus_history_target("history-#{preview.entity_type}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:rollback_preview, nil)
             |> put_flash(:error, rollback_error_message(reason))
             |> focus_rollback_fallback(log_id)}
        end

      _ ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "This change has already been reverted or the preview is stale."
         )
         |> focus_rollback_fallback(log_id)}
    end
  end

  def handle_event("confirm_rollback_change_log", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unable to revert change: invalid parameters")}
  end

  # -- Asynchronous history loading ------------------------------------------

  @impl true
  def handle_async(@journal_load_key, {:ok, {request, result}}, socket) do
    if request == socket.assigns.journal_request do
      {:noreply, apply_journal_result(socket, request, result)}
    else
      {:noreply, socket}
    end
  end

  # Task exits do not carry the complete request identity and therefore cannot
  # mutate journal state. Observable task failures are caught in the task and
  # returned with their request; cancellation and superseded exits are inert.
  def handle_async(@journal_load_key, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(@history_key, {:ok, {:loaded, scope, result}}, socket) do
    if scope == socket.assigns.history_scope do
      {:noreply,
       socket
       |> assign(:history_entries, result.entries)
       |> assign(:history_zone, result.zone)
       |> assign(:history_local_times, result.local_times)
       |> assign(:history_today, result.today)
       |> assign(:history_now, result.now)
       |> assign(:history_state, :ready)
       |> focus_replacement_entry(result.entries)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(@history_key, {:ok, {:load_failed, scope, _reason}}, socket) do
    if scope == socket.assigns.history_scope do
      {:noreply, assign(socket, :history_state, :error)}
    else
      {:noreply, socket}
    end
  end

  # A cancelled task was superseded on purpose; it is never a failure.
  def handle_async(@history_key, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  # An exit carries no scope, so it can only be trusted once `load_history/1`
  # isolates every failure it can observe into a scoped `{:load_failed, ...}`.
  # What is left here is an external kill of the task the panel is waiting on.
  def handle_async(@history_key, {:exit, _reason}, socket) do
    if socket.assigns.history_state in [:initial_loading, :refreshing] do
      {:noreply, assign(socket, :history_state, :error)}
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp stop_level_index(%StopLevel{level: %{level_index: level_index}})
       when is_number(level_index),
       do: level_index * 1.0

  defp stop_level_index(_stop_level), do: nil

  defp infer_alignment_error_message(:insufficient_anchors),
    do: "Not enough anchor stops to infer alignment"

  defp infer_alignment_error_message(:degenerate_geometry),
    do: "Anchor stops are too close together to infer alignment"

  defp infer_alignment_error_message(:high_residual),
    do: "Inferred alignment residual exceeds tolerance"

  defp infer_alignment_error_message(:invalid_input),
    do: "Invalid floorplan image dimensions"

  defp infer_alignment_error_message(:alignment_prerequisites_missing),
    do: "Active level is missing required alignment data"

  defp infer_alignment_error_message(:not_found), do: "Active level not found"
  defp infer_alignment_error_message(%Ecto.Changeset{}), do: "Could not save inferred alignment"

  defp coerce_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp coerce_positive_integer(value) when is_float(value) and value > 0 do
    {:ok, trunc(value)}
  end

  defp coerce_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 ->
        {:ok, int}

      _ ->
        case Float.parse(value) do
          {float, ""} when float > 0 -> {:ok, trunc(float)}
          _ -> :error
        end
    end
  end

  defp coerce_positive_integer(_), do: :error

  defp apply_alignment_error_message(:alignment_missing), do: "Save alignment before applying"
  defp apply_alignment_error_message(:invalid_image_dims), do: "Floorplan image not ready"
  defp apply_alignment_error_message({:transform, _}), do: "Invalid alignment values"
  defp apply_alignment_error_message(_), do: "Could not apply alignment"

  defp reset_map_workflow(socket) do
    socket
    |> assign(:map_generation, Ecto.UUID.generate())
    |> assign(:map_state, :initializing)
    |> assign(:floorplan_image_w, nil)
    |> assign(:floorplan_image_h, nil)
    |> clear_coordinate_preview()
  end

  defp clear_coordinate_preview(socket) do
    socket
    |> assign(:coordinate_preview, nil)
    |> assign(:coordinate_confirmation, false)
    |> assign(:coordinate_apply_form, to_form(%{"phrase" => ""}, as: :coordinate_preview))
  end

  defp current_map_generation?(socket, generation) when is_binary(generation) do
    socket.assigns.mode == :map and socket.assigns.map_generation == generation
  end

  defp current_map_generation?(_socket, _generation), do: false

  defp current_coordinate_preview?(socket) do
    case socket.assigns.coordinate_preview do
      %{generation: generation, stop_level_id: stop_level_id} ->
        current_map_generation?(socket, generation) and
          match?(%StopLevel{id: ^stop_level_id}, socket.assigns.active_stop_level)

      _ ->
        false
    end
  end

  defp coordinate_preview_error_message(:stale_preview),
    do: "The station changed. Preview the coordinate changes again."

  defp coordinate_preview_error_message(:busy),
    do: "The coordinate update is busy. Preview the coordinate changes again."

  defp map_state_from_string("initializing"), do: :initializing
  defp map_state_from_string("ready"), do: :ready
  defp map_state_from_string("imagery_unavailable"), do: :imagery_unavailable
  defp map_state_from_string("buildings_degraded"), do: :buildings_degraded
  defp map_state_from_string("offline"), do: :offline
  defp map_state_from_string("reconnecting"), do: :reconnecting
  defp map_state_from_string("fatal"), do: :fatal

  defp save_alignment(
         %{
           "center_lat" => lat,
           "center_lon" => lon,
           "scale_mpp" => mpp,
           "rotation_deg" => rot
         },
         socket
       ) do
    case socket.assigns.active_stop_level do
      %StopLevel{} = stop_level ->
        attrs = %{
          floorplan_center_lat: lat,
          floorplan_center_lon: lon,
          floorplan_scale_mpp: mpp,
          floorplan_rotation_deg: rot
        }

        case Gtfs.save_stop_level_alignment(stop_level, attrs) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:active_stop_level, updated)
             |> load_station_stop_levels_cache()
             |> put_flash(:info, "Alignment saved")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               alignment_changeset_error_message("Could not save alignment", changeset)
             )}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No level selected")}
    end
  end

  defp alignment_changeset_error_message(prefix, %Ecto.Changeset{} = changeset) do
    detail =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)
      |> Enum.flat_map(fn {field, messages} ->
        Enum.map(messages, fn message -> "#{field} #{message}" end)
      end)
      |> Enum.join("; ")

    if detail == "" do
      prefix
    else
      "#{prefix}: #{detail}"
    end
  end

  defp apply_rollback_entity_refresh(socket, "stop", %Gtfs.Stop{} = stop) do
    if stop.parent_station == socket.assigns.station.stop_id do
      refresh_current_station_stop_after_rollback(socket, stop)
    else
      refresh_external_station_stop_after_rollback(socket, stop)
    end
  end

  defp apply_rollback_entity_refresh(socket, "pathway", %Gtfs.Pathway{} = pathway) do
    refreshed_socket = refresh_lists(socket)

    case refreshed_socket.assigns.editing_pathway do
      %{id: id} when id == pathway.id ->
        reloaded = Gtfs.get_pathway_with_stops!(pathway.id)

        pathway_pair =
          pair_siblings_for(
            %{from_stop_id: reloaded.from_stop_id, to_stop_id: reloaded.to_stop_id},
            refreshed_socket.assigns.pathways_list
          )

        refreshed_socket
        |> assign(:editing_pathway, reloaded)
        |> assign(:editing_pathway_pair, pathway_pair)
        |> assign(:pathway_form, to_form(pathway_form_params(reloaded)))
        |> assign(:pathway_form_dirty, false)

      _ ->
        refreshed_socket
    end
  end

  defp apply_rollback_entity_refresh(socket, "level", %Gtfs.Level{} = level) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    levels_data = Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)
    levels = Enum.map(levels_data, & &1.level)

    socket = assign(socket, :levels, levels)

    socket =
      case socket.assigns.active_level do
        %{id: id} when id == level.id ->
          socket
          |> assign(:active_level, level)
          |> refresh_level_and_stop_level_cache(level)

        _ ->
          socket
      end

    socket
  end

  defp refresh_current_station_stop_after_rollback(socket, stop) do
    socket
    |> stream_insert(:child_stops, stop)
    |> maybe_reopen_selected_stop_after_rollback(stop)
    |> refresh_lists()
  end

  defp maybe_reopen_selected_stop_after_rollback(socket, stop) do
    if socket.assigns.selected_stop_id == stop.id do
      open_edit_sidebar(socket, stop, socket.assigns.pending_xy)
    else
      socket
    end
  end

  defp refresh_external_station_stop_after_rollback(socket, stop) do
    socket
    |> maybe_clear_selected_stop_after_rollback(stop)
    |> refresh_lists()
  end

  defp maybe_clear_selected_stop_after_rollback(socket, stop) do
    if socket.assigns.selected_stop_id == stop.id do
      socket
      |> assign(:selected_stop_id, nil)
      |> assign(:active_point_id, nil)
      |> assign(:pending_xy, nil)
      |> assign(:editing_level, false)
      |> assign(:child_stop_form, to_form(%{}))
    else
      socket
    end
  end

  # ---------------------------------------------------------------------------
  # Scoped station-journal lifecycle
  # ---------------------------------------------------------------------------

  defp reset_journal(socket) do
    socket
    |> stream(:journal_entries, [], reset: true)
    |> assign(:journal_scope, nil)
    |> assign(:journal_panel_open?, false)
    |> assign(:journal_filter, :open)
    |> assign(:journal_state, :idle)
    |> assign(:journal_request, nil)
    |> assign(:journal_open_count, 0)
    |> assign(:journal_closed_count, 0)
    |> assign(:journal_visible_count, 0)
    |> assign(:journal_loaded_once?, false)
    |> assign(:journal_refresh_error?, false)
    |> assign(:journal_expanded_id, nil)
    |> assign(:journal_undo_ids, MapSet.new())
    |> assign(:journal_rendered_entry_ids, MapSet.new())
    |> assign(:journal_pending_new_ids, MapSet.new())
    |> assign(:journal_rendered_signature, [])
    |> assign(:journal_observed_signature, [])
    |> assign(:journal_at_top?, true)
    |> assign(:journal_restore_after_align?, false)
    |> assign(:journal_authors, %{})
    |> assign(:journal_targets, %{})
    |> assign(:journal_local_times, %{})
    |> assign(:journal_display_zone, nil)
    |> assign(:journal_now, nil)
    |> assign(:journal_live_message, nil)
    |> assign(:journal_error_message, nil)
  end

  defp journal_pubsub_intent(socket) do
    cond do
      not socket.assigns.journal_panel_open? -> :counts_only
      socket.assigns.journal_at_top? -> :full
      true -> :observe_scrolled
    end
  end

  defp open_journal_panel(socket, opts) do
    persist? = Keyword.fetch!(opts, :persist?)

    if journal_panel_allowed?(socket) and not socket.assigns.journal_panel_open? do
      socket =
        socket
        |> assign(:journal_panel_open?, true)
        |> assign(:journal_restore_after_align?, false)
        |> load_journal(:full, :open, socket.assigns.journal_filter)

      if persist? do
        push_event(socket, "journal-panel-preference", %{open: true})
      else
        socket
      end
    else
      socket
    end
  end

  defp close_journal_panel(socket, opts) do
    persist? = Keyword.fetch!(opts, :persist?)
    focus_selector = Keyword.get(opts, :focus_selector)
    was_open? = socket.assigns.journal_panel_open?

    socket =
      socket
      |> assign(:journal_panel_open?, false)
      |> maybe_cancel_hidden_journal_load(was_open?)

    socket =
      if persist? and was_open? do
        push_event(socket, "journal-panel-preference", %{open: false})
      else
        socket
      end

    if was_open? and is_binary(focus_selector) do
      push_event(socket, "journal-focus", %{selector: focus_selector})
    else
      socket
    end
  end

  defp maybe_cancel_hidden_journal_load(
         %{assigns: %{journal_request: %{intent: intent}}} = socket,
         true
       )
       when intent in [:full, :observe_scrolled] do
    socket
    |> cancel_async(@journal_load_key)
    |> assign(:journal_request, nil)
    |> assign(:journal_state, if(socket.assigns.journal_loaded_once?, do: :ready, else: :idle))
  end

  defp maybe_cancel_hidden_journal_load(socket, _was_open?), do: socket

  defp journal_panel_allowed?(%{assigns: %{journal_scope: %JournalScope{}, mode: mode}}),
    do: mode in [:view, :add, :connect]

  defp journal_panel_allowed?(_socket), do: false

  defp restore_journal_panel(socket, false) do
    close_journal_panel(socket, persist?: false)
  end

  defp restore_journal_panel(socket, true) do
    open_journal_panel(socket, persist?: false)
  end

  defp update_journal_scroll_state(socket, at_top?) do
    socket = assign(socket, :journal_at_top?, at_top?)

    if at_top? and socket.assigns.journal_panel_open? and
         socket.assigns.journal_observed_signature != socket.assigns.journal_rendered_signature do
      load_journal(socket, :full, :returned_to_top, socket.assigns.journal_filter)
    else
      socket
    end
  end

  defp select_journal_entry(socket, entry_id) do
    with {:ok, entry_id} <- Ecto.UUID.cast(entry_id),
         {:ok, payload} <- safe_fetch_journal_payload(socket.assigns.journal_scope),
         %{} <- journal_payload_entry(payload, entry_id) do
      previous_id = socket.assigns.journal_expanded_id
      expanded_id = if previous_id == entry_id, do: nil, else: entry_id

      socket
      |> assign_journal_presentation(payload)
      |> assign(:journal_expanded_id, expanded_id)
      |> assign(:journal_error_message, nil)
      |> restream_journal_rows(payload, [previous_id, entry_id])
      |> push_event("journal-focus", %{selector: "#journal-entry-toggle-#{entry_id}"})
    else
      _ -> journal_action_failed(socket)
    end
  end

  defp mutate_journal_entry(socket, entry_id, transition) do
    with {:ok, entry_id} <- Ecto.UUID.cast(entry_id),
         {:ok, _entry} <-
           run_journal_transition(socket.assigns.journal_scope, entry_id, transition) do
      refresh_mutated_journal_entry(socket, entry_id, transition)
    else
      _ -> journal_action_failed(socket)
    end
  end

  defp run_journal_transition(scope, entry_id, :close) do
    Gtfs.close_journal_entry(scope, entry_id)
  rescue
    exception ->
      Logger.error("station_journal_close_failed", reason: Exception.message(exception))
      {:error, exception}
  end

  defp run_journal_transition(scope, entry_id, transition) when transition in [:reopen, :undo] do
    Gtfs.reopen_journal_entry(scope, entry_id)
  rescue
    exception ->
      Logger.error("station_journal_reopen_failed", reason: Exception.message(exception))
      {:error, exception}
  end

  defp refresh_mutated_journal_entry(socket, entry_id, transition) do
    with {:ok, payload} <- safe_fetch_journal_payload(socket.assigns.journal_scope),
         %{} = entry <- journal_payload_entry(payload, entry_id) do
      undo_ids =
        journal_undo_ids_after_transition(socket.assigns.journal_undo_ids, entry_id, transition)

      socket
      |> assign(:journal_undo_ids, undo_ids)
      |> assign_authoritative_mutation_snapshot(payload, entry_id)
      |> stream_insert(:journal_entries, entry)
      |> assign(:journal_state, :ready)
      |> assign(:journal_refresh_error?, false)
      |> assign(:journal_error_message, nil)
      |> assign(:journal_live_message, journal_transition_message(transition))
      |> push_event("journal-focus", %{
        selector: journal_transition_focus_selector(entry_id, transition)
      })
    else
      _ -> journal_mutation_refresh_failed(socket)
    end
  end

  defp journal_undo_ids_after_transition(undo_ids, entry_id, :close),
    do: MapSet.put(undo_ids, entry_id)

  defp journal_undo_ids_after_transition(undo_ids, entry_id, transition)
       when transition in [:reopen, :undo],
       do: MapSet.delete(undo_ids, entry_id)

  defp journal_transition_message(:close), do: "Entry closed."

  defp journal_transition_message(transition) when transition in [:reopen, :undo],
    do: "Entry reopened."

  defp journal_transition_focus_selector(entry_id, :close),
    do: "#journal-undo-entry-#{entry_id}"

  defp journal_transition_focus_selector(entry_id, transition)
       when transition in [:reopen, :undo],
       do: "#journal-close-entry-#{entry_id}"

  defp assign_authoritative_mutation_snapshot(socket, payload, entry_id) do
    socket =
      socket
      |> assign_journal_presentation(payload)
      |> assign(:journal_visible_count, journal_visible_count(socket, payload))

    if socket.assigns.journal_at_top? do
      socket
      |> assign(:journal_rendered_entry_ids, payload.entry_ids)
      |> assign(:journal_pending_new_ids, MapSet.new())
      |> assign(:journal_rendered_signature, payload.signature)
      |> assign(:journal_observed_signature, payload.signature)
    else
      socket
      |> assign(
        :journal_rendered_signature,
        replace_journal_signature_entry(
          socket.assigns.journal_rendered_signature,
          payload.signature,
          entry_id
        )
      )
      |> assign(:journal_observed_signature, payload.signature)
      |> assign(
        :journal_pending_new_ids,
        MapSet.difference(payload.entry_ids, socket.assigns.journal_rendered_entry_ids)
      )
    end
  end

  defp replace_journal_signature_entry(rendered_signature, payload_signature, entry_id) do
    case Enum.find(payload_signature, &(elem(&1, 0) == entry_id)) do
      nil ->
        rendered_signature

      replacement ->
        Enum.map(rendered_signature, &if(elem(&1, 0) == entry_id, do: replacement, else: &1))
    end
  end

  defp journal_visible_count(socket, payload) do
    payload.entries
    |> visible_journal_entries(socket.assigns.journal_filter, socket.assigns.journal_undo_ids)
    |> length()
  end

  defp assign_journal_presentation(socket, payload) do
    socket
    |> assign_journal_counts(payload)
    |> assign(:journal_authors, payload.authors)
    |> assign(:journal_targets, payload.targets)
    |> assign(:journal_local_times, payload.local_times)
    |> assign(:journal_display_zone, payload.zone)
    |> assign(:journal_now, payload.now)
  end

  defp restream_journal_rows(socket, payload, entry_ids) do
    entry_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(socket, fn entry_id, socket ->
      case journal_payload_entry(payload, entry_id) do
        nil -> socket
        entry -> stream_insert(socket, :journal_entries, entry)
      end
    end)
  end

  defp journal_payload_entry(payload, entry_id) do
    Enum.find(payload.entries, &(&1.id == entry_id))
  end

  defp safe_fetch_journal_payload(scope) do
    {:ok, fetch_journal_payload(scope, %{})}
  rescue
    exception ->
      Logger.error("station_journal_refresh_failed", reason: Exception.message(exception))
      {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp journal_action_failed(socket) do
    socket
    |> assign(:journal_error_message, "The journal entry could not be changed.")
    |> assign(:journal_live_message, "The journal entry was not changed. Try again.")
  end

  defp journal_mutation_refresh_failed(socket) do
    socket
    |> assign(:journal_state, :error)
    |> assign(:journal_refresh_error?, true)
    |> assign(
      :journal_error_message,
      "The entry changed, but the journal could not be refreshed."
    )
    |> assign(
      :journal_live_message,
      "The entry changed. Refresh the journal to see its latest state."
    )
  end

  defp transition_journal_mode(socket, :map) do
    restore? = socket.assigns.journal_panel_open?

    socket
    |> close_journal_panel(persist?: false)
    |> assign(:journal_restore_after_align?, restore?)
  end

  defp transition_journal_mode(%{assigns: %{mode: :map}} = socket, next_mode)
       when next_mode in [:view, :add, :connect] do
    restore? = socket.assigns.journal_restore_after_align?
    socket = assign(socket, :journal_restore_after_align?, false)

    if restore? and match?(%JournalScope{}, socket.assigns.journal_scope) do
      socket
      |> assign(:journal_panel_open?, true)
      |> load_journal(:full, :open, socket.assigns.journal_filter)
    else
      socket
    end
  end

  defp transition_journal_mode(socket, _next_mode), do: socket

  defp journal_mode_focus_transition?(socket, :map),
    do: socket.assigns.journal_panel_open?

  defp journal_mode_focus_transition?(%{assigns: %{mode: :map}} = socket, next_mode)
       when next_mode in [:view, :add, :connect],
       do: socket.assigns.journal_restore_after_align?

  defp journal_mode_focus_transition?(_socket, _next_mode), do: false

  defp maybe_focus_journal_mode(socket, mode, true) do
    push_event(socket, "journal-focus", %{selector: "#diagram-mode-option-#{mode}"})
  end

  defp maybe_focus_journal_mode(socket, _mode, false), do: socket

  defp open_pathway_drawer(socket, pathway) do
    pathway_pair = pair_siblings_for(pathway, socket.assigns.pathways_list)
    form = to_form(pathway_form_params(pathway))

    active_pathway_tab =
      case pathway_pair do
        [_first_pathway, second_pathway] ->
          if pathway.id == second_pathway.id or pathway.pathway_id == second_pathway.pathway_id,
            do: :second,
            else: :first

        _ ->
          :first
      end

    socket
    |> assign(:editing_pathway_pair, pathway_pair)
    |> assign(:active_pathway_tab, active_pathway_tab)
    |> assign(:pathway_form_dirty, false)
    |> assign(:editing_pathway, pathway)
    |> assign(:pathway_form, form)
    |> assign(:show_pathway_drawer, true)
  end

  defp setup_station_journal(socket) do
    %{
      current_organization: %{id: organization_id},
      current_gtfs_version: %{id: gtfs_version_id},
      current_user: %{id: actor_id},
      station: %{id: station_id}
    } = socket.assigns

    case Gtfs.resolve_station_journal_scope(
           organization_id,
           gtfs_version_id,
           station_id,
           actor_id
         ) do
      {:ok, scope} ->
        socket
        |> assign(:journal_scope, scope)
        |> maybe_start_station_journal(scope)

      {:error, _reason} ->
        socket
    end
  end

  defp maybe_start_station_journal(socket, scope) do
    if connected?(socket) do
      subscribe_and_load_station_journal(socket, scope)
    else
      socket
    end
  end

  defp subscribe_and_load_station_journal(socket, scope) do
    case Gtfs.subscribe_station_journal(scope) do
      :ok ->
        load_journal(socket, :counts_only, :station_load, socket.assigns.journal_filter)

      {:error, reason} ->
        Logger.warning("station_journal_subscription_failed", reason: inspect(reason))
        load_journal(socket, :counts_only, :station_load, socket.assigns.journal_filter)
    end
  end

  defp load_journal(
         %{assigns: %{journal_scope: %JournalScope{} = scope}} = socket,
         intent,
         reason,
         filter
       )
       when intent in [:counts_only, :full, :observe_scrolled] and
              reason in [
                :station_load,
                :open,
                :filter,
                :retry,
                :refresh,
                :pubsub,
                :returned_to_top
              ] and
              filter in [:open, :all] do
    generation = socket.assigns.journal_load_generation + 1

    request = %{
      scope_key: journal_scope_key(scope),
      generation: generation,
      intent: intent,
      reason: reason,
      filter: filter
    }

    socket
    |> cancel_async(@journal_load_key)
    |> assign(:journal_load_generation, generation)
    |> assign(:journal_request, request)
    |> assign(:journal_state, :loading)
    |> assign(:journal_refresh_error?, false)
    |> assign(:journal_error_message, nil)
    |> start_async(@journal_load_key, fn -> run_journal_load(scope, request) end)
  end

  defp journal_scope_key(%JournalScope{} = scope) do
    {scope.organization_id, scope.gtfs_version_id, scope.station_id}
  end

  defp run_journal_load(scope, request) do
    result =
      try do
        {:ok, fetch_journal_payload(scope, request)}
      rescue
        exception -> {:error, exception}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    {request, result}
  end

  # All journal reads and presentation decoration happen in the task. The
  # LiveView receives one coherent snapshot and never performs follow-up reads
  # while applying it.
  defp fetch_journal_payload(%JournalScope{} = scope, _request) do
    source = journal_source()
    entries = source.list_station_journal(scope, status: :all, order: :desc)

    authors =
      scope.organization_id
      |> Organizations.list_users_in_organization()
      |> Map.new(fn %{user: user} -> {user.id, user} end)

    targets = fetch_journal_targets(source, scope)
    zone = source.resolve_display_zone(scope.organization_id, scope.gtfs_version_id)
    {local_times, now} = localize_journal_times(source, entries, zone)

    %{
      entries: entries,
      open_count: Enum.count(entries, &is_nil(&1.closed_at)),
      closed_count: Enum.count(entries, &(not is_nil(&1.closed_at))),
      entry_ids: MapSet.new(entries, & &1.id),
      signature: journal_signature(entries),
      authors: authors,
      targets: targets,
      zone: zone,
      local_times: local_times,
      now: now
    }
  end

  defp fetch_journal_targets(source, %JournalScope{} = scope) do
    node_targets =
      scope.organization_id
      |> source.list_child_stops_for_parent(scope.gtfs_version_id, scope.station_id)
      |> Map.new(fn stop -> {stop.id, %{label: target_label(stop.stop_name, stop.stop_id)}} end)

    pathway_targets =
      scope.organization_id
      |> source.list_pathways_for_station(scope.gtfs_version_id, scope.station_id)
      |> Map.new(fn pathway ->
        {pathway.id, %{label: target_label(pathway.pathway_id, pathway.id)}}
      end)

    pin_targets =
      scope.organization_id
      |> source.list_stop_levels_for_station(scope.gtfs_version_id, scope.station_id)
      |> Map.new(fn stop_level ->
        label = target_label(stop_level.level.level_name, stop_level.level.level_id)
        {stop_level.id, %{label: label}}
      end)

    node_targets
    |> Map.merge(pathway_targets)
    |> Map.merge(pin_targets)
  end

  defp target_label(primary, _fallback) when is_binary(primary) and primary != "", do: primary
  defp target_label(_primary, fallback), do: to_string(fallback)

  defp localize_journal_times(source, entries, zone) do
    tagged_times =
      Enum.flat_map(entries, fn entry ->
        [{{entry.id, :captured}, entry.captured_at}] ++
          if(is_nil(entry.closed_at), do: [], else: [{{entry.id, :closed}, entry.closed_at}])
      end)

    [now | localized_times] =
      source.localize_display_times(
        [DateTime.utc_now() | Enum.map(tagged_times, &elem(&1, 1))],
        zone
      )

    local_times =
      tagged_times
      |> Enum.zip(localized_times)
      |> Map.new(fn {{{entry_id, kind}, _utc}, local} -> {{entry_id, kind}, local} end)

    {local_times, now}
  end

  defp journal_signature(entries) do
    Enum.map(entries, fn entry ->
      {entry.id, entry.updated_at, entry.closed_at, Enum.map(entry.photos, & &1.id)}
    end)
  end

  defp journal_source do
    Application.get_env(:gtfs_planner, :station_journal_source, Gtfs)
  end

  defp apply_journal_result(socket, request, {:ok, payload}) do
    apply_journal_payload(socket, request, payload)
  end

  defp apply_journal_result(socket, _request, {:error, _reason}) do
    loaded_once? = socket.assigns.journal_loaded_once?

    socket
    |> assign(:journal_request, nil)
    |> assign(:journal_state, :error)
    |> assign(:journal_refresh_error?, loaded_once?)
    |> assign(:journal_error_message, "Journal entries could not be loaded.")
  end

  defp apply_journal_payload(socket, %{intent: :counts_only}, payload) do
    socket
    |> assign_journal_counts(payload)
    |> assign(:journal_observed_signature, payload.signature)
    |> finish_journal_load()
  end

  defp apply_journal_payload(socket, %{intent: :full} = request, payload) do
    entries =
      visible_journal_entries(payload.entries, request.filter, socket.assigns.journal_undo_ids)

    pending_ids = socket.assigns.journal_pending_new_ids

    socket =
      if reset_journal_stream?(socket, request, payload) do
        stream(socket, :journal_entries, entries, reset: true)
      else
        socket
      end

    socket
    |> assign_journal_counts(payload)
    |> assign(:journal_filter, request.filter)
    |> assign(:journal_visible_count, length(entries))
    |> assign(:journal_loaded_once?, true)
    |> assign(:journal_rendered_entry_ids, payload.entry_ids)
    |> assign(:journal_pending_new_ids, MapSet.new())
    |> assign(:journal_rendered_signature, payload.signature)
    |> assign(:journal_observed_signature, payload.signature)
    |> assign(:journal_authors, payload.authors)
    |> assign(:journal_targets, payload.targets)
    |> assign(:journal_local_times, payload.local_times)
    |> assign(:journal_display_zone, payload.zone)
    |> assign(:journal_now, payload.now)
    |> finish_journal_load()
    |> apply_journal_refresh_effects(request, entries, pending_ids)
  end

  defp apply_journal_payload(socket, %{intent: :observe_scrolled}, payload) do
    pending_ids = MapSet.difference(payload.entry_ids, socket.assigns.journal_rendered_entry_ids)

    socket
    |> assign_journal_counts(payload)
    |> assign(:journal_observed_signature, payload.signature)
    |> assign(:journal_pending_new_ids, pending_ids)
    |> finish_journal_load()
  end

  defp assign_journal_counts(socket, payload) do
    socket
    |> assign(:journal_open_count, payload.open_count)
    |> assign(:journal_closed_count, payload.closed_count)
  end

  defp finish_journal_load(socket) do
    socket
    |> assign(:journal_request, nil)
    |> assign(:journal_state, :ready)
    |> assign(:journal_refresh_error?, false)
    |> assign(:journal_error_message, nil)
  end

  defp visible_journal_entries(entries, :all, _undo_ids), do: entries

  defp visible_journal_entries(entries, :open, undo_ids) do
    Enum.filter(entries, fn entry ->
      is_nil(entry.closed_at) or MapSet.member?(undo_ids, entry.id)
    end)
  end

  defp reset_journal_stream?(socket, request, payload) do
    request.reason in [:filter, :retry, :refresh] or
      payload.signature != socket.assigns.journal_rendered_signature
  end

  defp apply_journal_refresh_effects(socket, request, entries, pending_ids)
       when request.reason in [:refresh, :returned_to_top] do
    socket = push_event(socket, "journal-scroll-top", %{})

    case Enum.find(entries, &MapSet.member?(pending_ids, &1.id)) do
      nil ->
        socket

      entry ->
        push_event(socket, "journal-focus", %{selector: "#journal-entry-toggle-#{entry.id}"})
    end
  end

  defp apply_journal_refresh_effects(socket, _request, _entries, _pending_ids), do: socket

  # ---------------------------------------------------------------------------
  # Scoped history lifecycle
  # ---------------------------------------------------------------------------

  defp reset_history(socket) do
    socket
    |> assign(:history_open_for, nil)
    |> assign(:history_scope, nil)
    |> assign(:history_state, :idle)
    |> assign(:history_entries, [])
    |> assign(:history_zone, nil)
    |> assign(:history_local_times, %{})
    |> assign(:history_today, nil)
    |> assign(:history_now, nil)
    |> assign_history_filter("all")
    |> assign(:rollback_preview, nil)
    |> assign(:history_focus_newest?, false)
  end

  defp assign_history_filter(socket, key) do
    socket
    |> assign(:history_field_filter, key)
    |> assign(:history_filter_form, to_form(%{"key" => key}))
  end

  defp start_history_load(socket, entity_type, entity_id, state) do
    generation = socket.assigns.history_generation + 1

    scope =
      {socket.assigns.current_organization.id, socket.assigns.current_gtfs_version.id,
       socket.assigns.station.stop_id, entity_type, entity_id, generation}

    socket
    |> assign(:history_generation, generation)
    |> assign(:history_scope, scope)
    |> assign(:history_state, state)
    |> cancel_async(@history_key)
    |> start_async(@history_key, fn -> load_history(scope) end)
  end

  # Runs in the task process. It receives ids only and returns its own scope so
  # the LiveView can decide whether the answer is still wanted. The zone is
  # resolved once and the whole ordered collection localized in one batch.
  # Failures are isolated here and reported as a scoped result: an unhandled
  # raise or exit would otherwise arrive as an unscoped `{:exit, reason}` and
  # let a superseded task error the entity that replaced it.
  defp load_history({organization_id, gtfs_version_id, _station_stop_id, type, id, _gen} = scope) do
    source = history_source()
    entries = source.list_change_logs_for_entity(organization_id, gtfs_version_id, type, id)
    zone = source.resolve_display_zone(organization_id, gtfs_version_id)

    [now_local | locals] =
      source.localize_display_times(
        [DateTime.utc_now() | Enum.map(entries, & &1.inserted_at)],
        zone
      )

    {:loaded, scope,
     %{
       entries: entries,
       zone: zone,
       local_times: entries |> Enum.zip(locals) |> Map.new(fn {e, at} -> {e.id, at} end),
       today: NaiveDateTime.to_date(now_local),
       now: now_local
     }}
  rescue
    exception -> {:load_failed, scope, exception}
  catch
    kind, reason -> {:load_failed, scope, {kind, reason}}
  end

  # Resolved per call so the history boundary can be exercised deterministically
  # in tests without recompiling this module. Production always uses the context.
  defp history_source do
    Application.get_env(:gtfs_planner, :station_history_source, Gtfs)
  end

  defp refresh_history_entries(socket, entity_type, entity_id) do
    start_history_load(socket, entity_type, entity_id, :refreshing)
  end

  # -- Deterministic rollback focus -------------------------------------------
  #
  # Every rollback outcome ends somewhere useful and inside the open panel. The
  # scoped `FormErrorFocus` hook mounted on `#history-<entity>` only focuses ids
  # it contains, so an event can never pull focus into another region.
  defp focus_history_target(socket, id) do
    push_event(socket, "focus_scoped_target", %{id: id})
  end

  # A failed or stale confirm has no preview left to return to. Focus the entry
  # action it names, but only when that entry is genuinely listed — the id comes
  # from the request, so it is never interpolated into a focus target unverified.
  defp focus_rollback_fallback(socket, log_id) do
    case socket.assigns.history_open_for do
      {entity_type, _id} ->
        if Enum.any?(socket.assigns.history_entries, &(&1.id == log_id)) do
          focus_history_target(socket, "history-entry-action-#{log_id}")
        else
          focus_history_target(socket, "history-#{entity_type}")
        end

      _ ->
        socket
    end
  end

  defp focus_replacement_entry(%{assigns: %{history_focus_newest?: true}} = socket, entries) do
    socket = assign(socket, :history_focus_newest?, false)

    case Enum.reject(entries, &(&1.action == "rolled_back")) do
      [newest | _] -> focus_history_target(socket, "history-entry-#{newest.id}")
      [] -> socket
    end
  end

  defp focus_replacement_entry(socket, _entries), do: socket

  defp maybe_refresh_history_entries(socket, entity_type, entity_id) do
    if socket.assigns.history_open_for == {entity_type, entity_id} do
      refresh_history_entries(socket, entity_type, entity_id)
    else
      socket
    end
  end

  defp rollback_error_message(:cannot_rollback_create_or_delete),
    do: "This type of change cannot be reverted."

  defp rollback_error_message(:entity_not_found),
    do: "The target entity no longer exists."

  defp rollback_error_message(:rollback_log_failed),
    do: "Unable to record the revert. Please try again."

  defp rollback_error_message(:missing_rollback_snapshot),
    do: "This change has no snapshot and cannot be reverted."

  defp rollback_error_message(:already_matches_current),
    do: "This change already matches the current state."

  defp rollback_error_message(_), do: "Unable to revert change."

  @spec rollback_preview_for(GtfsPlanner.Gtfs.ChangeLog.t()) :: {:ok, map()} | {:error, atom()}
  defp rollback_preview_for(log) do
    with {:ok, entity} <- rollback_preview_entity(log),
         {:ok, target_snapshot} <- Gtfs.rollback_target_snapshot(log),
         {:ok, field_changes} <- rollback_preview_field_changes(log, entity, target_snapshot) do
      {:ok,
       %{
         log: log,
         entity_type: log.entity_type,
         entity_id: log.entity_id,
         entity_name: rollback_entity_name(log.entity_type, entity),
         natural_key:
           rollback_entity_natural_key(log.entity_type, entity) || log.entity_external_id,
         field_changes: field_changes
       }}
    end
  end

  # The preview names the thing it is about to change. Both values come from the
  # currently loaded entity, never from the change log's stored snapshot, so the
  # heading describes the record as it stands right now.
  defp rollback_entity_name("stop", %Gtfs.Stop{} = stop), do: stop.stop_name || stop.stop_id

  defp rollback_entity_name("level", %Gtfs.Level{} = level),
    do: level.level_name || level.level_id

  defp rollback_entity_name("pathway", %Gtfs.Pathway{} = pathway),
    do: pathway.signposted_as || pathway.pathway_id

  defp rollback_entity_name(_type, _entity), do: nil

  defp rollback_entity_natural_key("stop", %Gtfs.Stop{} = stop), do: stop.stop_id
  defp rollback_entity_natural_key("pathway", %Gtfs.Pathway{} = pathway), do: pathway.pathway_id
  defp rollback_entity_natural_key("level", %Gtfs.Level{} = level), do: level.level_id
  defp rollback_entity_natural_key(_type, _entity), do: nil

  defp handle_rollback_preview_request(socket, log) do
    if rollback_preview_available?(socket, log) do
      {:noreply, assign_rollback_preview(socket, log)}
    else
      {:noreply, put_flash(socket, :error, "Unable to preview rollback: entity no longer exists")}
    end
  end

  defp rollback_preview_available?(socket, log) do
    rollback_log_in_current_scope?(socket, log) and
      entity_belongs_to_current_station?(socket, log.entity_type, log.entity_id)
  end

  defp assign_rollback_preview(socket, log) do
    case rollback_preview_for(log) do
      {:ok, preview} ->
        assign(socket, :rollback_preview, preview)

      {:error, :entity_not_found} ->
        put_flash(socket, :error, "Unable to preview rollback: entity no longer exists")

      {:error, :already_matches_current} ->
        socket
        |> assign(:rollback_preview, nil)
        |> put_flash(:error, rollback_error_message(:already_matches_current))

      {:error, _reason} ->
        put_flash(socket, :error, "Unable to preview rollback")
    end
  end

  defp rollback_preview_entity(log) do
    case load_current_entity(log.entity_type, log.entity_id) do
      nil -> {:error, :entity_not_found}
      entity -> {:ok, entity}
    end
  end

  defp rollback_preview_field_changes(log, entity, target_snapshot) do
    current_snapshot =
      log.entity_type
      |> Gtfs.entity_snapshot(entity)
      |> stringify_keys()

    target_snapshot = stringify_keys(target_snapshot)

    field_changes =
      log
      |> rollback_preview_keys(current_snapshot, target_snapshot)
      |> Enum.reduce([], &rollback_preview_change(&1, current_snapshot, target_snapshot, &2))
      |> Enum.sort_by(& &1.field)

    if field_changes == [] do
      {:error, :already_matches_current}
    else
      {:ok, field_changes}
    end
  end

  defp rollback_preview_keys(log, current_snapshot, target_snapshot) do
    previewable_fields = rollback_preview_field_set(log)

    target_snapshot
    |> Map.keys()
    |> Kernel.++(Map.keys(current_snapshot))
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(previewable_fields, &1))
  end

  defp rollback_preview_field_set(log) do
    reversible_fields =
      log.entity_type
      |> Gtfs.reversible_fields_for()
      |> MapSet.new()

    changed_fields =
      log.changed_fields
      |> Kernel.||(%{})
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    if MapSet.subset?(changed_fields, reversible_fields) do
      reversible_fields
    else
      log
      |> Gtfs.rollback_previewable_fields()
      |> MapSet.new()
    end
  end

  defp rollback_preview_change(key, current_snapshot, target_snapshot, acc) do
    current = Map.get(current_snapshot, key)
    restored = Map.get(target_snapshot, key)

    if current == restored do
      acc
    else
      [%{field: key, current: current, restored: restored} | acc]
    end
  end

  defp load_current_entity("stop", id), do: Gtfs.get_stop(id)
  defp load_current_entity("pathway", id), do: Gtfs.get_pathway(id)
  defp load_current_entity("level", id), do: Gtfs.get_level(id)
  defp load_current_entity(_, _), do: nil

  defp rollback_log_in_current_scope?(socket, log) do
    log.organization_id == socket.assigns.current_organization.id and
      log.gtfs_version_id == socket.assigns.current_gtfs_version.id and
      log.station_stop_id == socket.assigns.station.stop_id
  end

  defp entity_belongs_to_current_station?(socket, "stop", id) when is_binary(id) do
    case Gtfs.get_stop(id) do
      nil ->
        false

      %Gtfs.Stop{} = stop ->
        stop.id == socket.assigns.station.id or
          stop.stop_id == socket.assigns.station.stop_id or
          stop.parent_station == socket.assigns.station.stop_id or
          MapSet.member?(socket.assigns.platform_stop_ids, stop.parent_station)
    end
  end

  defp entity_belongs_to_current_station?(socket, "pathway", id) when is_binary(id) do
    case Gtfs.get_pathway(id) do
      nil ->
        false

      pathway ->
        organization_id = socket.assigns.current_organization.id
        gtfs_version_id = socket.assigns.current_gtfs_version.id
        station_stop_id = socket.assigns.station.stop_id
        platform_stop_ids = socket.assigns.platform_stop_ids

        from_stop =
          Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, pathway.from_stop_id)

        to_stop =
          Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, pathway.to_stop_id)

        endpoint_matches?(from_stop, station_stop_id, platform_stop_ids) or
          endpoint_matches?(to_stop, station_stop_id, platform_stop_ids)
    end
  end

  defp entity_belongs_to_current_station?(socket, "level", id) when is_binary(id) do
    Enum.any?(socket.assigns.levels, fn level -> level.id == id end)
  end

  defp entity_belongs_to_current_station?(_socket, _type, _id), do: false

  defp endpoint_matches?(nil, _station_stop_id, _platform_stop_ids), do: false

  defp endpoint_matches?(%Gtfs.Stop{} = stop, station_stop_id, platform_stop_ids) do
    stop.parent_station == station_stop_id or
      MapSet.member?(platform_stop_ids, stop.parent_station)
  end

  # Records an "updated" change log entry only if the persisted entity actually
  # differs from the pre-mutation entity. Skips no-op writes that would otherwise
  # produce empty diff log rows.
  #
  # Compares each `attrs` key against the pre-entity value rather than relying
  # solely on snapshot equality — some tracked fields (e.g. `:diagram_coordinate`)
  # are not part of the rollback snapshot but still represent meaningful changes.
  defp maybe_record_change(audit_ctx, entity_type, pre_entity, post_entity, attrs)
       when is_map(attrs) do
    if no_op_change?(pre_entity, post_entity, attrs) do
      :ok
    else
      Gtfs.record_change(audit_ctx, entity_type, pre_entity, "updated", attrs)
    end
  end

  defp no_op_change?(_pre_entity, _post_entity, attrs) when map_size(attrs) == 0, do: true

  defp no_op_change?(pre_entity, _post_entity, attrs) do
    Enum.all?(attrs, fn {key, new_value} ->
      pre_value = entity_field(pre_entity, key)
      normalize_compare(pre_value) == normalize_compare(new_value)
    end)
  end

  defp entity_field(nil, _key), do: nil

  defp entity_field(entity, key) when is_atom(key) do
    Map.get(entity, key)
  end

  defp entity_field(entity, key) when is_binary(key) do
    case safe_to_existing_atom(key) do
      {:ok, atom} -> Map.get(entity, atom)
      :error -> nil
    end
  end

  defp safe_to_existing_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> :error
  end

  defp normalize_compare(%Decimal{} = d), do: Decimal.to_string(d)
  defp normalize_compare(value), do: value

  defp coords_unchanged?(%{"x" => current_x, "y" => current_y}, parsed_x, parsed_y) do
    coord_equal?(current_x, parsed_x) and coord_equal?(current_y, parsed_y)
  end

  defp coords_unchanged?(_other, _parsed_x, _parsed_y), do: false

  defp coord_equal?(a, b) when is_number(a) and is_number(b), do: a == b

  defp coord_equal?(a, b) do
    to_string(a) == to_string(b)
  end

  defp stringify_keys(nil), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp handle_stop_selection(id, socket) do
    case fetch_intent_stop(socket, id) do
      {:ok, stop} ->
        case socket.assigns.active_point_id do
          nil ->
            # First stop selected - set it as active
            {:noreply,
             socket
             |> stream_insert(:child_stops, stop)
             |> assign(:active_point_id, stop.id)
             |> assign(:selected_from_stop, stop)}

          active_point_id when active_point_id == stop.id ->
            # Clicking same stop - deselect it
            {:noreply,
             socket
             |> stream_insert(:child_stops, stop)
             |> assign(:active_point_id, nil)
             |> assign(:selected_from_stop, nil)}

          first_stop_id ->
            # Second stop selected - create pathway between them
            create_pathway_between_stops(socket, first_stop_id, stop.id)
        end

      {:error, :not_found} ->
        {:noreply, assign(socket, :pathway_error, "Invalid stop selection")}
    end
  end

  defp normalize_pair_key(stop_id_a, stop_id_b) do
    if stop_id_a <= stop_id_b do
      {stop_id_a, stop_id_b}
    else
      {stop_id_b, stop_id_a}
    end
  end

  defp build_pair_counts(pathways) do
    Enum.reduce(pathways, %{}, fn pathway, counts ->
      pair_key = normalize_pair_key(pathway.from_stop_id, pathway.to_stop_id)
      Map.update(counts, pair_key, 1, &(&1 + 1))
    end)
  end

  defp decorate_same_level_pathways(level_pathways) do
    same_level_pathways = Enum.reject(level_pathways, & &1.is_cross_level)
    pathway_pair_counts = build_pair_counts(same_level_pathways)

    pair_siblings_by_key =
      Enum.group_by(same_level_pathways, &normalize_pair_key(&1.from_stop_id, &1.to_stop_id))

    decorated_pathways =
      Enum.map(same_level_pathways, fn pathway ->
        pair_key = normalize_pair_key(pathway.from_stop_id, pathway.to_stop_id)
        is_paired = Map.get(pathway_pair_counts, pair_key, 0) >= 2

        pair_siblings =
          Map.get(pair_siblings_by_key, pair_key, [])
          |> Enum.sort_by(&pathway_pair_sort_key/1, :asc)

        {display_signposted_as, display_reversed_signposted_as} =
          pair_display_signage(pathway, pair_siblings)

        pathway
        |> Map.from_struct()
        |> Map.put(:is_paired, is_paired)
        |> Map.put(:display_signposted_as, display_signposted_as)
        |> Map.put(:display_reversed_signposted_as, display_reversed_signposted_as)
      end)

    {decorated_pathways, pathway_pair_counts}
  end

  defp pair_siblings_for(pathway, pathways_list) do
    pair_key = normalize_pair_key(pathway.from_stop_id, pathway.to_stop_id)

    pathways_list
    |> Enum.filter(fn sibling ->
      not sibling.is_cross_level and
        normalize_pair_key(sibling.from_stop_id, sibling.to_stop_id) == pair_key
    end)
    |> Enum.sort_by(&pathway_pair_sort_key/1, :asc)
  end

  # Targeted save-refresh helpers (issue #652).
  #
  # These repair only the state a single child-stop or pathway mutation can
  # invalidate, instead of falling back to the broad refresh_lists/1 path. They
  # MUST NOT rebuild other-level overlay caches, walkability, platform options,
  # or push other-level markers. Map-mode marker re-pushes go directly through
  # set_active_child_stops (active_child_stop_payload/1), never
  # push_child_stop_markers/1.

  # Classify a child-stop edit by how widely it invalidates active-level state.
  defp child_stop_refresh_plan(old_stop, new_stop, _active_level) do
    cond do
      old_stop.stop_id != new_stop.stop_id or
        old_stop.level_id != new_stop.level_id or
        old_stop.parent_station != new_stop.parent_station or
          old_stop.location_type != new_stop.location_type ->
        :full_level

      old_stop.diagram_coordinate != new_stop.diagram_coordinate or
        old_stop.stop_lat != new_stop.stop_lat or
          old_stop.stop_lon != new_stop.stop_lon ->
        :stop_and_pathways

      true ->
        :stop_only
    end
  end

  defp apply_child_stop_save_refresh(socket, plan, new_stop)
       when plan in [:stop_only, :stop_and_pathways, :full_level] do
    apply_child_stop_refresh_plan(socket, plan, new_stop)
  end

  defp apply_child_stop_refresh_plan(socket, :stop_only, new_stop) do
    socket
    |> replace_child_stop_in_list(new_stop)
    |> stream_insert(:child_stops, Map.put(new_stop, :on_active_level, true))
    |> push_active_child_stop_markers()
  end

  defp apply_child_stop_refresh_plan(socket, :stop_and_pathways, new_stop) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station
    active_level = socket.assigns.active_level

    touching_pathways =
      Gtfs.list_pathways_for_stop_on_level(
        organization_id,
        gtfs_version_id,
        active_level.id,
        station.id,
        new_stop.stop_id
      )

    socket
    |> replace_child_stop_in_list(new_stop)
    |> stream_insert(:child_stops, Map.put(new_stop, :on_active_level, true))
    |> recompute_summary_counts()
    |> merge_pathways_in_list(touching_pathways)
    |> recompute_pathway_decoration()
    |> stream_same_level_pathways(touching_pathways)
    |> recompute_cross_level_badges()
    |> push_active_child_stop_markers()
  end

  defp apply_child_stop_refresh_plan(socket, :full_level, _new_stop) do
    refresh_lists(socket)
  end

  defp apply_pathway_save_refresh(socket, _old_pathway, updated_pathway) do
    active_level = socket.assigns.active_level

    reloaded =
      updated_pathway.id
      |> Gtfs.get_pathway_with_stops!()
      |> merge_active_level_flags(active_level)

    badges_before = socket.assigns.cross_level_badges_by_stop

    pair_key = normalize_pair_key(reloaded.from_stop_id, reloaded.to_stop_id)

    socket =
      socket
      |> replace_pathway_in_list(reloaded)
      |> recompute_pathway_decoration()
      |> stream_same_level_pathways_for_pair(pair_key)
      |> recompute_cross_level_badges()

    maybe_push_markers_on_badge_change(socket, badges_before)
  end

  # Re-push active child-stop markers in map mode only when cross-level badge
  # content changed (a cross-level pathway_mode edit alters marker badges).
  defp maybe_push_markers_on_badge_change(socket, badges_before) do
    if socket.assigns.cross_level_badges_by_stop != badges_before do
      push_active_child_stop_markers(socket)
    else
      socket
    end
  end

  # --- granular list/stream/recompute repairs ---

  defp replace_child_stop_in_list(socket, stop) do
    list =
      Enum.map(socket.assigns.child_stops_list, fn existing ->
        if existing.id == stop.id, do: Map.put(stop, :on_active_level, true), else: existing
      end)

    assign(socket, :child_stops_list, list)
  end

  defp replace_pathway_in_list(socket, pathway) do
    list =
      Enum.map(socket.assigns.pathways_list, fn existing ->
        if existing.id == pathway.id, do: pathway, else: existing
      end)

    assign(socket, :pathways_list, list)
  end

  # Merge reloaded pathways touching a stop into :pathways_list by id, keeping
  # untouched pathways unchanged.
  defp merge_pathways_in_list(socket, pathways) do
    reloaded_ids = MapSet.new(pathways, & &1.id)

    retained =
      Enum.reject(socket.assigns.pathways_list, &MapSet.member?(reloaded_ids, &1.id))

    assign(socket, :pathways_list, retained ++ pathways)
  end

  # Recompute same-level decoration and pair counts from :pathways_list and
  # reset the :pathways stream, mirroring load_level_data/2.
  defp recompute_pathway_decoration(socket) do
    {same_level_pathways, pathway_pair_counts} =
      decorate_same_level_pathways(socket.assigns.pathways_list)

    socket
    |> stream(:pathways, same_level_pathways, reset: true)
    |> assign(:pathway_pair_counts, pathway_pair_counts)
  end

  # Stream the decorated same-level members of the affected unordered pairs for
  # the supplied (raw) pathways, so paired display signage stays consistent.
  defp stream_same_level_pathways(socket, pathways) do
    pathways
    |> Enum.map(&normalize_pair_key(&1.from_stop_id, &1.to_stop_id))
    |> Enum.uniq()
    |> Enum.reduce(socket, &stream_same_level_pathways_for_pair(&2, &1))
  end

  defp stream_same_level_pathways_for_pair(socket, pair_key) do
    {decorated, _counts} = decorate_same_level_pathways(socket.assigns.pathways_list)

    decorated
    |> Enum.filter(&(normalize_pair_key(&1.from_stop_id, &1.to_stop_id) == pair_key))
    |> Enum.reduce(socket, &stream_insert(&2, :pathways, &1))
  end

  # Recompute active-level summary counts from :child_stops_list and
  # :pathways_list, mirroring load_level_data/2.
  defp recompute_summary_counts(socket) do
    child_stops_on_level =
      Enum.filter(socket.assigns.child_stops_list, & &1.on_active_level)

    child_stops_total = length(child_stops_on_level)

    child_stops_with_geo =
      Enum.count(child_stops_on_level, fn s ->
        not is_nil(s.stop_lat) and not is_nil(s.stop_lon)
      end)

    anchor_count =
      Enum.count(child_stops_on_level, fn s ->
        not is_nil(s.diagram_coordinate) and not is_nil(s.stop_lat) and not is_nil(s.stop_lon)
      end)

    cross_level_pathways = Enum.filter(socket.assigns.pathways_list, & &1.is_cross_level)
    cross_level_pathway_total = length(cross_level_pathways)

    cross_level_pathway_with_geo =
      Enum.count(cross_level_pathways, fn p ->
        other = if p.from_on_active_level, do: p.to_stop, else: p.from_stop
        not is_nil(other.stop_lat) and not is_nil(other.stop_lon)
      end)

    socket
    |> assign(:child_stops_total, child_stops_total)
    |> assign(:child_stops_with_geo, child_stops_with_geo)
    |> assign(:anchor_count, anchor_count)
    |> assign(:cross_level_pathway_total, cross_level_pathway_total)
    |> assign(:cross_level_pathway_with_geo, cross_level_pathway_with_geo)
  end

  # Recompute :cross_level_badges_by_stop from :pathways_list and the current
  # active-level child stops, mirroring load_level_data/2.
  defp recompute_cross_level_badges(socket) do
    active_level_stop_ids =
      socket.assigns.child_stops_list
      |> Enum.filter(& &1.on_active_level)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    badges =
      cross_level_badges_by_stop(socket.assigns.pathways_list, active_level_stop_ids)

    assign(socket, :cross_level_badges_by_stop, badges)
  end

  # Re-derive the virtual active-level flags for a reloaded pathway from the
  # current active level, matching list_pathways_for_level/4.
  defp merge_active_level_flags(pathway, active_level) do
    from_on_level = pathway.from_stop.level_id == active_level.level_id
    to_on_level = pathway.to_stop.level_id == active_level.level_id

    Map.merge(pathway, %{
      is_cross_level: from_on_level != to_on_level,
      from_on_active_level: from_on_level,
      to_on_active_level: to_on_level
    })
  end

  # Direct map-mode re-push of active child-stop markers. Never routes through
  # push_child_stop_markers/1 (which also re-pushes other levels).
  defp push_active_child_stop_markers(socket) do
    if socket.assigns[:mode] == :map do
      push_event(socket, "set_active_child_stops", active_child_stop_payload(socket))
    else
      socket
    end
  end

  defp pair_display_signage(pathway, [first, second]) do
    if pathway.pathway_id == first.pathway_id do
      {
        combine_pair_signage(first.signposted_as, second.signposted_as),
        combine_pair_signage(first.reversed_signposted_as, second.reversed_signposted_as)
      }
    else
      {nil, nil}
    end
  end

  defp pair_display_signage(pathway, _pair_siblings) do
    {pathway.signposted_as, pathway.reversed_signposted_as}
  end

  defp combine_pair_signage(signage_a, signage_b) do
    has_a? = non_blank_text?(signage_a)
    has_b? = non_blank_text?(signage_b)

    cond do
      has_a? and has_b? ->
        "#{String.trim(signage_a)} // #{String.trim(signage_b)}"

      has_a? ->
        String.trim(signage_a)

      has_b? ->
        String.trim(signage_b)

      true ->
        nil
    end
  end

  defp non_blank_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank_text?(_value), do: false

  defp pathway_pair_sort_key(pathway) do
    {pathway.from_stop_id, pathway.to_stop_id, pathway.pathway_id}
  end

  defp tab_for_pathway([_first_pathway, second_pathway], pathway) do
    if pathway.id == second_pathway.id, do: :second, else: :first
  end

  defp tab_for_pathway(_pathway_pair, _pathway), do: :first

  defp pathway_for_tab([first_pathway], "first"), do: first_pathway
  defp pathway_for_tab([first_pathway, _second_pathway], "first"), do: first_pathway
  defp pathway_for_tab([_first_pathway, second_pathway], "second"), do: second_pathway
  defp pathway_for_tab(_pathways, _tab), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {val, _} -> val
      :error -> 0
    end
  end

  defp parse_int(_), do: 0

  defp parse_optional_int(nil), do: nil
  defp parse_optional_int(""), do: nil

  defp parse_optional_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {val, _} -> val
      :error -> nil
    end
  end

  defp parse_optional_int(val) when is_integer(val), do: val
  defp parse_optional_int(_), do: nil

  defp parse_optional_decimal(nil), do: nil
  defp parse_optional_decimal(""), do: nil

  defp parse_optional_decimal(str) when is_binary(str) do
    case Decimal.parse(String.trim(str)) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp parse_optional_decimal(val) when is_float(val), do: Decimal.from_float(val)
  defp parse_optional_decimal(%Decimal{} = val), do: val
  defp parse_optional_decimal(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp to_optional_string(nil), do: ""
  defp to_optional_string(value), do: to_string(value)

  defp to_snakecase_id(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]+/, "_")
    |> String.trim("_")
  end

  defp to_snakecase_id(_), do: ""

  defp to_float(val) when is_float(val), do: val
  defp to_float(val) when is_integer(val), do: val / 1

  defp to_float(val) when is_binary(val) do
    case Float.parse(val) do
      {parsed, _rest} -> parsed
      :error -> 0.0
    end
  end

  defp to_float(nil), do: 0.0

  defp parse_finite_float(nil), do: {:error, :invalid_coordinate}
  defp parse_finite_float(""), do: {:error, :invalid_coordinate}

  defp parse_finite_float(val) when is_integer(val), do: {:ok, val / 1}
  defp parse_finite_float(val) when is_float(val), do: {:ok, val}
  defp parse_finite_float(val) when is_integer(val), do: {:ok, val / 1}

  defp parse_finite_float(val) when is_binary(val) do
    case Float.parse(val) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_coordinate}
    end
  end

  defp parse_finite_float(_), do: {:error, :invalid_coordinate}

  defp parse_mode("view"), do: {:ok, :view}
  defp parse_mode("add"), do: {:ok, :add}
  defp parse_mode("connect"), do: {:ok, :connect}
  defp parse_mode("map"), do: {:ok, :map}
  defp parse_mode(_), do: :error

  defp toggle_other_level(socket, mapset_assign, level_id, eligibility_key) do
    current = Map.get(socket.assigns, mapset_assign, MapSet.new())

    updated =
      cond do
        MapSet.member?(current, level_id) ->
          MapSet.delete(current, level_id)

        other_level_eligible?(socket, level_id, eligibility_key) ->
          MapSet.put(current, level_id)

        true ->
          current
      end

    socket
    |> assign(mapset_assign, updated)
    |> assign_other_levels()
    |> push_other_levels()
  end

  defp other_level_eligible?(socket, level_id, eligibility_key) do
    socket.assigns
    |> Map.get(:other_levels, [])
    |> Enum.find(&(&1.level_id == level_id))
    |> case do
      nil -> false
      row -> Map.get(row, eligibility_key, false)
    end
  end

  defp parse_svg_coordinate(value) do
    with {:ok, parsed} <- parse_float(value),
         true <- parsed >= 0.0 and parsed <= 100.0 do
      {:ok, Float.round(parsed, 2)}
    else
      _ -> :error
    end
  end

  defp parse_float(value) when is_float(value), do: {:ok, value}
  defp parse_float(value) when is_integer(value), do: {:ok, value / 1}

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_float(_), do: :error

  defp maybe_disable_measurement_for_mode(socket, :view), do: socket
  defp maybe_disable_measurement_for_mode(socket, _mode), do: disable_measurement(socket)

  defp maybe_reset_ruler_for_measurement_toggle(socket, true), do: reset_ruler_state(socket)
  defp maybe_reset_ruler_for_measurement_toggle(socket, false), do: reset_ruler_state(socket)

  defp disable_measurement(socket) do
    socket
    |> assign(:measurement_enabled, false)
    |> reset_ruler_state()
  end

  defp reset_ruler_state(socket) do
    socket
    |> assign(:ruler_point_a, nil)
    |> assign(:ruler_point_b, nil)
    |> assign(:show_ruler_drawer, false)
    |> assign(:ruler_form, to_form(%{"distance_meters" => ""}, as: :ruler))
    |> assign(:scale_status, nil)
  end

  defp handle_view_measure_click(socket, x, y) do
    if socket.assigns.measurement_enabled do
      handle_measure_click(socket, x, y)
    else
      socket
    end
  end

  defp handle_measure_click(socket, x, y) do
    point = %{"x" => x, "y" => y}

    cond do
      is_nil(socket.assigns.ruler_point_a) ->
        socket
        |> assign(:ruler_point_a, point)
        |> assign(:ruler_point_b, nil)
        |> assign(:show_ruler_drawer, false)

      is_nil(socket.assigns.ruler_point_b) ->
        socket
        |> assign(:ruler_point_b, point)
        |> assign(:show_ruler_drawer, true)

      true ->
        socket
        |> assign(:ruler_point_a, point)
        |> assign(:ruler_point_b, nil)
        |> assign(:show_ruler_drawer, false)
        |> assign(:ruler_form, to_form(%{"distance_meters" => ""}, as: :ruler))
    end
  end

  defp parse_positive_decimal(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Decimal.parse(trimmed) do
      {decimal, ""} ->
        if Decimal.compare(decimal, Decimal.new(0)) == :gt, do: decimal, else: nil

      _ ->
        nil
    end
  end

  defp parse_positive_decimal(_), do: nil

  defp euclidean_distance(point_a, point_b) do
    with %{x: ax, y: ay} <- Coordinates.normalize_point(point_a),
         %{x: bx, y: by} <- Coordinates.normalize_point(point_b) do
      :math.sqrt(:math.pow(bx - ax, 2) + :math.pow(by - ay, 2))
    else
      _ -> 0.0
    end
  end

  defp scale_point(nil, _field), do: nil

  defp scale_point(stop_level, field) do
    value = Map.get(stop_level, field)
    if Coordinates.normalize_point(value), do: value, else: nil
  end

  defp scale_configured?(nil), do: false

  defp scale_configured?(stop_level) do
    not is_nil(scale_point(stop_level, :scale_point_a)) and
      not is_nil(scale_point(stop_level, :scale_point_b)) and
      match?(%Decimal{}, stop_level.scale_distance_meters) and
      match?(%Decimal{}, stop_level.scale_meters_per_unit)
  end

  defp maybe_put_auto_pathway_length(attrs, socket, from_stop, to_stop) do
    active_level = socket.assigns.active_level
    active_stop_level = socket.assigns.active_stop_level

    same_level? =
      active_level &&
        from_stop.level_id == active_level.level_id &&
        to_stop.level_id == active_level.level_id

    length =
      if same_level? and scale_configured?(active_stop_level) do
        Gtfs.calculate_pathway_length(active_stop_level, from_stop, to_stop)
      else
        nil
      end

    if length do
      Map.put(attrs, :length, length)
    else
      attrs
    end
  end

  defp format_pathway_length_for_form(%Decimal{} = length) do
    rounded = Decimal.round(length, 2)
    normalized = Decimal.to_string(rounded, :normal)

    case String.split(normalized, ".", parts: 2) do
      [integer] ->
        integer <> ".00"

      [integer, fractional] ->
        integer <> "." <> String.pad_trailing(String.slice(fractional, 0, 2), 2, "0")
    end
  end

  defp pathway_form_params(pathway) do
    %{
      "pathway_id" => pathway.pathway_id,
      "pathway_mode" => to_string(pathway.pathway_mode),
      "is_bidirectional" => pathway.is_bidirectional,
      "traversal_time" => pathway.traversal_time,
      "length" => pathway.length,
      "stair_count" => pathway.stair_count,
      "min_width" => pathway.min_width,
      "signposted_as" => pathway.signposted_as,
      "reversed_signposted_as" => pathway.reversed_signposted_as
    }
  end

  defp handle_diagram_upload_progress(:diagram, entry, socket) do
    socket =
      cond do
        not entry.done? -> assign(socket, :upload_phase, :uploading)
        socket.assigns.upload_phase not in [:idle, :uploading, :failed, :succeeded] -> socket
        true -> begin_diagram_upload(socket, entry)
      end

    {:noreply, socket}
  end

  defp begin_diagram_upload(socket, entry) do
    case active_stop_level_for_upload(socket) do
      {:ok, stop_level} ->
        socket = assign(socket, :active_stop_level, stop_level)
        pending = upload_identity(socket, stop_level, entry.ref)

        if is_binary(stop_level.diagram_filename) and stop_level.diagram_filename != "" do
          socket
          |> assign(:upload_phase, :awaiting_replacement_confirmation)
          |> assign(:pending_diagram_upload, pending)
          |> assign(:diagram_replacement_confirmation, %{entry_ref: entry.ref})
          |> assign(:diagram_error, nil)
        else
          stage_uploaded_diagram_candidate(socket, pending)
        end

      {:error, message} ->
        upload_failed(socket, message)
    end
  end

  defp active_stop_level_for_upload(socket) do
    station = socket.assigns.station
    active_level = socket.assigns.active_level

    cond do
      is_nil(active_level) ->
        {:error, "Select a level before uploading a diagram."}

      match?(%StopLevel{}, socket.assigns.active_stop_level) ->
        {:ok, socket.assigns.active_stop_level}

      true ->
        Gtfs.create_stop_level(%{
          stop_id: station.id,
          level_id: active_level.id,
          organization_id: socket.assigns.current_organization.id,
          gtfs_version_id: socket.assigns.current_gtfs_version.id
        })
        |> case do
          {:ok, stop_level} -> {:ok, stop_level}
          {:error, _changeset} -> {:error, "Unable to prepare this level for a diagram."}
        end
    end
  end

  defp upload_identity(socket, stop_level, entry_ref) do
    %{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      station_stop_id: socket.assigns.station.stop_id,
      stop_level_id: stop_level.id,
      entry_ref: entry_ref
    }
  end

  defp stage_uploaded_diagram_candidate(socket, pending) do
    socket =
      socket
      |> assign(:upload_phase, :validating)
      |> assign(:pending_diagram_upload, pending)
      |> assign(:diagram_replacement_confirmation, nil)
      |> assign(:diagram_error, nil)

    case find_upload_entry(socket, pending.entry_ref) do
      nil -> upload_failed(socket, "The diagram upload is no longer available. Select it again.")
      entry -> consume_and_stage_diagram_candidate(socket, entry, pending)
    end
  end

  defp find_upload_entry(socket, entry_ref) do
    Enum.find(socket.assigns.uploads.diagram.entries, &(&1.ref == entry_ref))
  end

  defp consume_and_stage_diagram_candidate(socket, entry, pending) do
    case consume_uploaded_entry(socket, entry, &store_diagram_candidate(&1, entry, pending)) do
      {:candidate, filename} ->
        stage_candidate_probe(socket, pending, filename)

      {:error, reason} ->
        Logger.warning("station diagram candidate validation failed: #{inspect(reason)}")
        upload_failed(socket, "The selected file is not a valid PNG or JPEG diagram.")

      {:postpone, postponed_socket} ->
        postponed_socket
    end
  end

  defp store_diagram_candidate(%{path: path}, entry, pending) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{extension: extension}} <-
           DiagramUploadValidator.validate(entry.client_name, binary),
         {:ok, filename} <-
           DiagramStorage.store_candidate(
             pending.organization_id,
             pending.gtfs_version_id,
             pending.station_stop_id,
             extension,
             binary
           ) do
      {:ok, {:candidate, filename}}
    else
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  defp stage_candidate_probe(socket, pending, filename) do
    if Versions.published_gtfs_version_for_org?(pending.organization_id, pending.gtfs_version_id) do
      candidate_ref = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      pending = Map.merge(pending, %{candidate_filename: filename, candidate_ref: candidate_ref})

      socket
      |> assign(:upload_phase, :probing_candidate)
      |> assign(:pending_diagram_upload, pending)
      |> push_event("probe_diagram_candidate", %{
        candidate_ref: candidate_ref,
        url: candidate_url(pending, filename)
      })
    else
      delete_candidate_and_fail(
        socket,
        pending,
        filename,
        "This version is not published. Select a diagram after publication."
      )
    end
  end

  defp candidate_url(pending, filename) do
    station_dir = PathSafety.stop_storage_dir(pending.station_stop_id)

    "/uploads/diagrams/#{pending.organization_id}/#{pending.gtfs_version_id}/#{station_dir}/#{URI.encode(filename)}?candidate=1"
  end

  defp handle_diagram_candidate_probe_result(socket, %{"candidate_ref" => ref, "result" => result})
       when result in ["ready", "failed"] do
    case socket.assigns.pending_diagram_upload do
      %{candidate_ref: ^ref} = pending when socket.assigns.upload_phase == :probing_candidate ->
        resolve_diagram_candidate_probe(socket, pending, result)

      _ ->
        socket
    end
  end

  defp handle_diagram_candidate_probe_result(socket, _params), do: socket

  defp resolve_diagram_candidate_probe(socket, pending, result) do
    case pending_identity_current?(socket, pending) do
      true when result == "ready" ->
        commit_diagram_candidate(socket, pending)

      true ->
        delete_candidate_and_fail(
          socket,
          pending,
          pending.candidate_filename,
          "The diagram could not be opened. Select another file."
        )

      false ->
        delete_candidate_and_reset(socket, pending)
    end
  end

  defp pending_identity_current?(socket, pending) do
    current = socket.assigns

    current.current_organization.id == pending.organization_id and
      current.current_gtfs_version.id == pending.gtfs_version_id and
      current.station.stop_id == pending.station_stop_id and
      match?(%StopLevel{id: id} when id == pending.stop_level_id, current.active_stop_level)
  end

  defp commit_diagram_candidate(socket, pending) do
    case DiagramStorage.commit_candidate(
           socket.assigns.active_stop_level,
           pending.candidate_filename
         ) do
      {:ok, updated_stop_level} ->
        socket
        |> assign(:active_stop_level, updated_stop_level)
        |> assign(:upload_phase, :succeeded)
        |> assign(:pending_diagram_upload, nil)
        |> disable_measurement()
        |> assign(:diagram_error, nil)

      {:error, _reason} ->
        delete_candidate_and_fail(
          socket,
          pending,
          pending.candidate_filename,
          "The diagram could not be saved. Your previous diagram is unchanged."
        )
    end
  end

  defp discard_pending_diagram_upload(socket) do
    socket
    |> cleanup_pending_candidate()
    |> cancel_pending_upload_entry()
    |> assign(:upload_phase, :idle)
    |> assign(:pending_diagram_upload, nil)
    |> assign(:diagram_replacement_confirmation, nil)
  end

  defp delete_candidate_and_fail(socket, pending, filename, message) do
    socket = delete_candidate(socket, pending, filename)
    upload_failed(socket, message)
  end

  defp delete_candidate_and_reset(socket, pending) do
    socket
    |> delete_candidate(pending, pending.candidate_filename)
    |> assign(:upload_phase, :idle)
    |> assign(:pending_diagram_upload, nil)
  end

  defp upload_failed(socket, message) do
    socket
    |> assign(:upload_phase, :failed)
    |> assign(:pending_diagram_upload, nil)
    |> assign(:diagram_replacement_confirmation, nil)
    |> assign(:diagram_error, message)
  end

  defp cleanup_pending_candidate(socket) do
    case socket.assigns.pending_diagram_upload do
      %{candidate_filename: filename} = pending -> delete_candidate(socket, pending, filename)
      _ -> socket
    end
  end

  defp delete_candidate(socket, pending, filename) do
    case DiagramStorage.delete_unreferenced_candidate(
           pending.organization_id,
           pending.gtfs_version_id,
           pending.station_stop_id,
           filename
         ) do
      :ok ->
        socket

      {:error, reason} ->
        Logger.warning("station diagram candidate cleanup failed: #{inspect(reason)}")
        socket
    end
  end

  defp cancel_pending_upload_entry(socket) do
    case socket.assigns.pending_diagram_upload do
      %{entry_ref: entry_ref} -> cancel_upload(socket, :diagram, entry_ref)
      _ -> socket
    end
  end

  defp cleanup_stale_diagram_candidates(socket) do
    if connected?(socket) and socket.assigns[:station] do
      cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)

      case DiagramStorage.cleanup_stale_candidates(
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
             socket.assigns.station.stop_id,
             cutoff
           ) do
        {:ok, _count} ->
          socket

        {:error, reason} ->
          Logger.warning("station diagram stale candidate cleanup failed: #{inspect(reason)}")
          socket
      end
    else
      socket
    end
  end

  defp stop_display_label(stop) do
    case stop.stop_name do
      name when is_binary(name) and name != "" -> name
      _ -> stop.stop_id
    end
  end

  defp create_pathway_between_stops(socket, from_stop_id, to_stop_id) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    with {:ok, from_stop} <- fetch_intent_stop(socket, from_stop_id),
         {:ok, to_stop} <- fetch_intent_stop(socket, to_stop_id),
         pair_key = normalize_pair_key(from_stop.stop_id, to_stop.stop_id),
         pair_count = Map.get(socket.assigns.pathway_pair_counts || %{}, pair_key, 0),
         false <- pair_count >= 2 do
      pathway_id = "pw_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

      attrs =
        %{
          pathway_id: pathway_id,
          from_stop_id: from_stop.stop_id,
          to_stop_id: to_stop.stop_id,
          pathway_mode: 1,
          is_bidirectional: true,
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id
        }
        |> maybe_put_auto_pathway_length(socket, from_stop, to_stop)

      case Gtfs.create_pathway(attrs) do
        {:ok, pathway} ->
          Gtfs.record_change(
            socket.assigns.audit_ctx,
            :pathway,
            pathway,
            "created",
            attrs
          )

          loaded_pathway = Gtfs.get_pathway_with_stops!(pathway.id)
          refreshed_socket = refresh_lists(socket)

          pathway_pair =
            pair_siblings_for(loaded_pathway, refreshed_socket.assigns.pathways_list)

          {:noreply,
           refreshed_socket
           # Re-stream to remove highlight
           |> stream_insert(:child_stops, from_stop)
           |> assign(:editing_pathway_pair, pathway_pair)
           |> assign(:active_pathway_tab, tab_for_pathway(pathway_pair, loaded_pathway))
           |> assign(:pathway_form_dirty, false)
           |> assign(:editing_pathway, loaded_pathway)
           |> assign(:pathway_form, to_form(pathway_form_params(loaded_pathway)))
           |> assign(:show_pathway_drawer, true)
           |> assign(:active_point_id, nil)
           |> assign(:selected_from_stop, nil)
           |> assign(
             :placement_status,
             "Pathway created #{stop_display_label(from_stop)} → #{stop_display_label(to_stop)}"
           )
           |> assign(:pathway_error, nil)}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> assign(:show_pathway_drawer, false)
           |> assign(:editing_pathway_pair, [])
           |> assign(:active_pathway_tab, :first)
           |> assign(:pathway_form_dirty, false)
           |> assign(:editing_pathway, nil)
           |> assign(:active_point_id, nil)
           |> assign(:pathway_error, "Failed to create pathway")}
      end
    else
      true ->
        {:noreply, assign(socket, :pathway_error, "This stop pair already has two pathways")}

      {:error, :not_found} ->
        {:noreply, assign(socket, :pathway_error, "Invalid stop selection")}
    end
  end

  defp reset_reposition_state(socket) do
    socket
    |> assign(:reposition_mode, false)
    |> assign(:reposition_search, "")
    |> assign(:reposition_stops, [])
  end

  # Reads the coordinate from the server-tracked `reposition_x`/`reposition_y`
  # assigns rather than the row button's `phx-value-*`. The assigns are kept
  # current by `validate_reposition_coordinates` (typed) and `canvas_click`
  # (clicked); because LiveView processes those events before the row-action
  # click that follows them, the assign is always the value the operator last
  # entered. Reading a render-time `phx-value` snapshot could commit a stale
  # coordinate if the click fired before the field's change re-render landed.
  defp reposition_read_coordinates(_params, socket) do
    with {:ok, x} <- parse_finite_float(socket.assigns.reposition_x),
         {:ok, y} <- parse_finite_float(socket.assigns.reposition_y) do
      {:ok, x, y}
    end
  end

  defp reposition_validate_stop(params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    reposition_stops = socket.assigns.reposition_stops
    id = params["id"]
    stop = if id, do: Gtfs.get_stop(id)

    cond do
      is_nil(stop) ->
        {:error, "Invalid stop selection"}

      stop.organization_id != organization_id or stop.gtfs_version_id != gtfs_version_id ->
        {:error, "Invalid stop selection"}

      not Enum.any?(reposition_stops, &(&1.id == stop.id)) ->
        {:error, "Invalid stop selection"}

      true ->
        {:ok, stop}
    end
  end

  defp do_reposition_stop(socket, stop, x, y, level_id) do
    attrs = %{
      diagram_coordinate: %{"x" => x, "y" => y},
      level_id: level_id
    }

    case Gtfs.update_stop(stop, attrs) do
      {:ok, updated_stop} ->
        maybe_record_change(
          socket.assigns.audit_ctx,
          :stop,
          stop,
          updated_stop,
          attrs
        )

        {:noreply,
         socket
         |> refresh_lists()
         |> assign(
           :placement_status,
           "Stop re-positioned to (#{Float.to_string(x)}, #{Float.to_string(y)})"
         )
         |> assign(:pending_xy, nil)
         |> assign(:selected_stop_id, nil)
         |> assign(:reposition_x, "")
         |> assign(:reposition_y, "")
         |> assign(:child_stop_form, to_form(%{}))
         |> reset_reposition_state()
         |> maybe_refresh_history_entries("stop", updated_stop.id)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to re-position stop")}
    end
  end

  defp maybe_open_child_stop_from_params(socket, %{"edit_child_stop_id" => id} = _params) do
    case resolve_child_stop_intent(socket, id) do
      {:ok, stop, pending_xy, level} ->
        if connected?(socket), do: send(self(), :clear_edit_child_stop_param)

        socket
        |> switch_active_level_if_needed(level)
        |> open_edit_sidebar(stop, pending_xy)

      {:error, reason} ->
        put_flash(socket, :error, child_stop_intent_error_message(reason))
    end
  end

  defp maybe_open_child_stop_from_params(socket, _params), do: socket

  defp resolve_child_stop_intent(socket, id) do
    with {:ok, stop} <- fetch_intent_stop(socket, id),
         :ok <- ensure_stop_in_station_scope(socket, stop),
         {:ok, pending_xy} <- fetch_intent_diagram_point(stop),
         {:ok, level} <- fetch_intent_level(socket, stop) do
      {:ok, stop, pending_xy, level}
    end
  end

  defp fetch_intent_stop(socket, id) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Stop{} = stop <- Gtfs.get_stop(uuid),
         true <- stop.organization_id == organization_id,
         true <- stop.gtfs_version_id == gtfs_version_id do
      {:ok, stop}
    else
      _ -> {:error, :not_found}
    end
  end

  defp ensure_stop_in_station_scope(socket, stop) do
    station = socket.assigns.station
    platform_stop_ids = socket.assigns[:platform_stop_ids] || MapSet.new()

    if stop_belongs_to_station?(stop, station.stop_id, platform_stop_ids) do
      :ok
    else
      {:error, :out_of_scope}
    end
  end

  defp fetch_intent_diagram_point(stop) do
    case stop_diagram_point(stop) do
      {:ok, pending_xy} -> {:ok, pending_xy}
      :error -> {:error, :missing_coordinate}
    end
  end

  defp fetch_intent_level(socket, stop) do
    case Enum.find(socket.assigns.levels, &(&1.level_id == stop.level_id)) do
      nil -> {:error, :unknown_level}
      level -> {:ok, level}
    end
  end

  defp child_stop_intent_error_message(:not_found), do: "Stop not found"
  defp child_stop_intent_error_message(:out_of_scope), do: "Stop does not belong to this station"
  defp child_stop_intent_error_message(:missing_coordinate), do: "Stop has no diagram coordinate"

  defp child_stop_intent_error_message(:unknown_level),
    do: "Stop is not assigned to a known station level"

  defp switch_active_level_if_needed(socket, level) do
    if level.id == socket.assigns.active_level.id do
      socket
    else
      socket
      |> disable_measurement()
      |> assign(:active_level, level)
      |> assign(:pending_xy, nil)
      |> assign(:diagram_error, nil)
      |> reset_reposition_state()
      |> load_level_data(level)
    end
  end

  defp open_edit_sidebar(socket, stop, pending_xy) do
    station = socket.assigns.station
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    platform_stop_ids = platform_stop_ids_for_station(organization_id, gtfs_version_id, station)

    parent_platform =
      if stop.location_type == 4 and
           MapSet.member?(platform_stop_ids, stop.parent_station) do
        stop.parent_station
      else
        ""
      end

    form =
      to_form(%{
        "stop_id" => stop.stop_id,
        "stop_name" => stop.stop_name,
        "location_type" => to_string(stop.location_type),
        "parent_platform" => parent_platform,
        "level_id" => stop.level_id,
        "wheelchair_boarding" => to_optional_string(stop.wheelchair_boarding),
        "platform_code" => stop.platform_code || "",
        "stop_lat" => to_optional_string(stop.stop_lat),
        "stop_lon" => to_optional_string(stop.stop_lon),
        "x" => to_optional_string(pending_xy.x),
        "y" => to_optional_string(pending_xy.y)
      })

    socket
    |> reset_reposition_state()
    |> stream_insert(:child_stops, stop)
    |> assign(:pending_xy, pending_xy)
    |> assign(:selected_stop_id, stop.id)
    |> assign(:active_point_id, stop.id)
    |> assign(:editing_level, false)
    |> assign(:stop_id_mode, :manual)
    |> assign(:child_stop_form, form)
  end

  defp stop_diagram_point(stop) do
    coord = stop.diagram_coordinate

    with %{} <- coord,
         {:ok, x} <- parse_diagram_coordinate(Map.get(coord, "x") || Map.get(coord, :x)),
         {:ok, y} <- parse_diagram_coordinate(Map.get(coord, "y") || Map.get(coord, :y)) do
      {:ok, %{x: x, y: y}}
    else
      _ -> :error
    end
  end

  defp parse_diagram_coordinate(value) when is_float(value), do: {:ok, value}
  defp parse_diagram_coordinate(value) when is_integer(value), do: {:ok, value / 1}

  defp parse_diagram_coordinate(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_diagram_coordinate(_), do: :error

  defp restream_active_stop(socket) do
    case socket.assigns.active_point_id do
      nil ->
        socket

      active_point_id ->
        case Gtfs.get_stop(active_point_id) do
          nil -> socket
          stop -> stream_insert(socket, :child_stops, stop)
        end
    end
  end

  defp refresh_lists(socket), do: load_level_data(socket, socket.assigns.active_level)

  # Mirrors the "close_drawer" handler assigns, without reloading entities or
  # restreaming. Save flows perform their own targeted stream/list repairs.
  defp close_child_stop_drawer_after_save(socket) do
    socket
    |> reset_reposition_state()
    |> assign(:pending_xy, nil)
    |> assign(:selected_stop_id, nil)
    |> assign(:active_point_id, nil)
    |> assign(:child_stop_form, to_form(%{}))
  end

  # Mirrors the "close_pathway_drawer" handler assigns, plus :pathway_error -> nil,
  # without reloading entities or changing persisted data.
  defp close_pathway_drawer_after_save(socket) do
    socket
    |> assign(:show_pathway_drawer, false)
    |> assign(:editing_pathway_pair, [])
    |> assign(:active_pathway_tab, :first)
    |> assign(:pathway_form_dirty, false)
    |> assign(:editing_pathway, nil)
    |> assign(:pathway_form, to_form(%{}))
    |> assign(:pathway_error, nil)
  end

  defp restream_mode_dependent_layers(socket) do
    child_stops = socket.assigns[:child_stops_list] || []
    pathways = socket.assigns[:pathways_list] || []
    {same_level_pathways, pathway_pair_counts} = decorate_same_level_pathways(pathways)

    socket
    |> stream(:child_stops, child_stops, reset: true)
    |> stream(:pathways, same_level_pathways, reset: true)
    |> assign(:pathway_pair_counts, pathway_pair_counts)
  end

  defp load_pathways_for_level(socket, nil) do
    socket
    |> stream(:pathways, [], reset: true)
    |> assign(:pathways_list, [])
    |> assign(:cross_level_badges_by_stop, %{})
    |> assign(:pathway_pair_counts, %{})
  end

  defp load_pathways_for_level(socket, level) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    all_child_stops = Gtfs.list_child_stops_for_level(station.id, level.id)

    level_pathways =
      Gtfs.list_pathways_for_level(organization_id, gtfs_version_id, level.id, station.id)

    active_level_stop_ids = active_level_stop_ids(all_child_stops, level)
    cross_level_badges = cross_level_badges_by_stop(level_pathways, active_level_stop_ids)
    {same_level_pathways, pathway_pair_counts} = decorate_same_level_pathways(level_pathways)

    socket
    |> stream(:pathways, same_level_pathways, reset: true)
    |> assign(:pathways_list, level_pathways)
    |> assign(:cross_level_badges_by_stop, cross_level_badges)
    |> assign(:pathway_pair_counts, pathway_pair_counts)
  end

  defp platform_stop_ids_for_station(organization_id, gtfs_version_id, station) do
    Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, station.id)
    |> Enum.filter(&(&1.location_type == 0 and &1.parent_station == station.stop_id))
    |> Enum.map(& &1.stop_id)
    |> MapSet.new()
  end

  defp save_walkability_test_create(socket, organization_id, attrs) do
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Validations.create_walkability_test(organization_id, gtfs_version_id, attrs) do
      {:ok, _walkability_test} ->
        purge_otp_artifact(organization_id, gtfs_version_id)

        {:noreply,
         socket
         |> reset_walkability_drawer()
         |> refresh_lists()}

      {:error, changeset} ->
        error_message =
          if duplicate_walkability_test?(changeset) do
            "This address is already registered for this stop."
          else
            "Failed to create test case."
          end

        field_errors = extract_field_errors(changeset)

        {:noreply,
         socket
         |> put_flash(:error, error_message)
         |> assign(:walkability_error, error_message)
         |> assign(:walkability_field_errors, field_errors)
         |> push_event("scroll_to_error", %{id: "walkability-error"})}
    end
  end

  defp save_walkability_test_edit(socket, organization_id, attrs) do
    editing_walkability_test = socket.assigns.editing_walkability_test

    cond do
      is_nil(editing_walkability_test) ->
        {:noreply, put_flash(socket, :error, "Walkability test not found.")}

      true ->
        case Validations.get_walkability_test(editing_walkability_test.id) do
          nil ->
            {:noreply, put_flash(socket, :error, "Walkability test not found.")}

          walkability_test when walkability_test.organization_id != organization_id ->
            {:noreply, put_flash(socket, :error, "Unauthorized walkability test access.")}

          walkability_test ->
            case validate_walkability_test_scope(socket, walkability_test) do
              {:ok, _stop} ->
                case Validations.update_walkability_test(walkability_test, attrs) do
                  {:ok, _walkability_test} ->
                    purge_otp_artifact(organization_id, socket.assigns.current_gtfs_version.id)

                    {:noreply,
                     socket
                     |> reset_walkability_drawer()
                     |> refresh_lists()
                     |> put_flash(:info, "Walkability test updated.")}

                  {:error, changeset} ->
                    error_message =
                      if duplicate_walkability_test?(changeset) do
                        "This address is already registered for this stop."
                      else
                        "Failed to update test case."
                      end

                    field_errors = extract_field_errors(changeset)

                    {:noreply,
                     socket
                     |> put_flash(:error, error_message)
                     |> assign(:walkability_error, error_message)
                     |> assign(:walkability_field_errors, field_errors)
                     |> push_event("scroll_to_error", %{id: "walkability-error"})}
                end

              {:error, message} ->
                {:noreply, put_flash(socket, :error, message)}
            end
        end
    end
  end

  defp reset_walkability_drawer(socket) do
    socket
    |> assign(:show_walkability_drawer, false)
    |> assign(:walkability_stop, nil)
    |> assign(:walkability_form, to_form(default_walkability_form_params(), as: :walkability))
    |> clear_walkability_selection()
    |> assign(:walkability_last_results, [])
    |> assign(:walkability_error, nil)
    |> assign(:walkability_field_errors, %{})
    |> assign(:walkability_mode, :create)
    |> assign(:editing_walkability_test, nil)
  end

  defp default_walkability_form_params(overrides \\ %{}) do
    Map.merge(
      %{
        "address_autocomplete" => "",
        "description" => "",
        "expected_traversable" => false,
        "expected_wheelchair_accessible" => false,
        "expected_min_duration_seconds" => "",
        "expected_max_duration_seconds" => "",
        "expected_min_distance_meters" => "",
        "expected_max_distance_meters" => ""
      },
      overrides
    )
  end

  defp walkability_test_form_params(walkability_test) do
    default_walkability_form_params(%{
      "address_autocomplete" => walkability_test.address,
      "description" => walkability_test.description || "",
      "expected_traversable" => walkability_test.expected_traversable || false,
      "expected_wheelchair_accessible" =>
        walkability_test.expected_wheelchair_accessible || false,
      "expected_min_duration_seconds" =>
        to_optional_string(walkability_test.expected_min_duration_seconds),
      "expected_max_duration_seconds" =>
        to_optional_string(walkability_test.expected_max_duration_seconds),
      "expected_min_distance_meters" =>
        to_optional_string(walkability_test.expected_min_distance_meters),
      "expected_max_distance_meters" =>
        to_optional_string(walkability_test.expected_max_distance_meters)
    })
  end

  defp validate_walkability_test_scope(socket, walkability_test) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    stop = Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, walkability_test.stop_id)
    active_level_stop_ids = MapSet.new(Enum.map(socket.assigns.child_stops_list, & &1.stop_id))

    cond do
      walkability_test.organization_id != organization_id ->
        {:error, "Unauthorized walkability test access."}

      walkability_test.gtfs_version_id != gtfs_version_id ->
        {:error, "Unauthorized walkability test access."}

      is_nil(stop) ->
        {:error, "Walkability test stop not found."}

      not stop_belongs_to_station?(
        stop,
        station.stop_id,
        socket.assigns.platform_stop_ids
      ) ->
        {:error, "Unauthorized walkability test access."}

      not MapSet.member?(active_level_stop_ids, walkability_test.stop_id) ->
        {:error, "Walkability test is not on the active level."}

      true ->
        {:ok, stop}
    end
  end

  defp do_remove_from_diagram(stop_id, socket) do
    socket = clear_confirmation(socket)
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    station_stop_id = socket.assigns.station.stop_id

    case Gtfs.remove_child_stop_from_diagram(org_id, version_id, station_stop_id, stop_id) do
      {:ok, _stop} ->
        {:noreply,
         socket
         |> refresh_lists()
         |> put_flash(:info, "Stop removed from diagram.")
         |> assign(:pending_xy, nil)
         |> assign(:selected_stop_id, nil)
         |> assign(:active_point_id, nil)
         |> assign(:child_stop_form, to_form(%{}))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Stop not found for this station.")
         |> assign(:pending_xy, nil)
         |> assign(:selected_stop_id, nil)
         |> assign(:child_stop_form, to_form(%{}))}
    end
  end

  defp do_delete_child_stop(stop_id, socket) do
    socket = clear_confirmation(socket)
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    station_stop_id = socket.assigns.station.stop_id

    case Gtfs.delete_child_stop(org_id, version_id, station_stop_id, stop_id) do
      {:ok, deleted_stop} ->
        Gtfs.record_change(socket.assigns.audit_ctx, :stop, deleted_stop, "deleted", %{})

        {:noreply,
         socket
         |> refresh_lists()
         |> assign(:pending_xy, nil)
         |> assign(:selected_stop_id, nil)
         |> assign(:active_point_id, nil)
         |> assign(:child_stop_form, to_form(%{}))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete child stop")
         |> assign(:pending_xy, nil)
         |> assign(:selected_stop_id, nil)
         |> assign(:child_stop_form, to_form(%{}))}
    end
  end

  defp do_delete_pathway(pathway_id, socket) do
    socket = clear_confirmation(socket)

    case pathway_for_deletion(socket, pathway_id) do
      {:ok, pathway} -> delete_pathway_and_refresh(socket, pathway)
      {:error, message} -> {:noreply, assign(socket, :pathway_error, message)}
    end
  end

  defp pathway_for_deletion(socket, pathway_id) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station
    pathway = Enum.find(socket.assigns.pathways_list, &(&1.id == pathway_id))

    cond do
      is_nil(pathway) or pathway.organization_id != organization_id or
          pathway.gtfs_version_id != gtfs_version_id ->
        {:error, "Unauthorized pathway access."}

      is_nil(pathway.from_stop) or is_nil(pathway.to_stop) ->
        {:error, "Pathway is not fully associated with stops."}

      not stop_belongs_to_station?(
        pathway.from_stop,
        station.stop_id,
        socket.assigns.platform_stop_ids
      ) or
          not stop_belongs_to_station?(
            pathway.to_stop,
            station.stop_id,
            socket.assigns.platform_stop_ids
          ) ->
        {:error, "Unauthorized pathway access."}

      true ->
        {:ok, pathway}
    end
  end

  defp delete_pathway_and_refresh(socket, pathway) do
    case Gtfs.delete_pathway(pathway) do
      {:ok, _deleted_pathway} ->
        Gtfs.record_change(socket.assigns.audit_ctx, :pathway, pathway, "deleted", %{})
        refreshed_socket = refresh_lists(socket)

        remaining_siblings =
          pair_siblings_for(
            %{from_stop_id: pathway.from_stop_id, to_stop_id: pathway.to_stop_id},
            refreshed_socket.assigns.pathways_list
          )

        next_socket = update_pathway_drawer(refreshed_socket, remaining_siblings)

        {:noreply, assign(next_socket, :pathway_error, nil)}

      {:error, _changeset} ->
        {:noreply, assign(socket, :pathway_error, "Failed to delete pathway")}
    end
  end

  defp update_pathway_drawer(refreshed_socket, [remaining_pathway]) do
    refreshed_pathway = Gtfs.get_pathway_with_stops!(remaining_pathway.id)

    refreshed_socket
    |> assign(:show_pathway_drawer, true)
    |> assign(:editing_pathway_pair, [refreshed_pathway])
    |> assign(:active_pathway_tab, :first)
    |> assign(:pathway_form_dirty, false)
    |> assign(:editing_pathway, refreshed_pathway)
    |> assign(:pathway_form, to_form(pathway_form_params(refreshed_pathway)))
  end

  defp update_pathway_drawer(refreshed_socket, _remaining_siblings) do
    refreshed_socket
    |> assign(:show_pathway_drawer, false)
    |> assign(:editing_pathway_pair, [])
    |> assign(:active_pathway_tab, :first)
    |> assign(:pathway_form_dirty, false)
    |> assign(:editing_pathway, nil)
    |> assign(:pathway_form, to_form(%{}))
  end

  defp do_delete_walkability_test(id, socket) do
    socket = clear_confirmation(socket)
    organization_id = socket.assigns.current_organization.id

    case Validations.get_walkability_test(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Walkability test not found.")}

      walkability_test ->
        with {:ok, _stop} <- validate_walkability_test_scope(socket, walkability_test),
             {:ok, _deleted} <- Validations.delete_walkability_test(walkability_test) do
          purge_otp_artifact(organization_id, socket.assigns.current_gtfs_version.id)
          {:noreply, socket |> reset_walkability_drawer() |> refresh_lists()}
        else
          {:error, message} when is_binary(message) ->
            {:noreply, put_flash(socket, :error, message)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to delete walkability test.")}
        end
    end
  end

  defp do_remove_level_from_station(level_uuid, socket) do
    socket = clear_confirmation(socket)
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    case Gtfs.remove_level_from_station(
           organization_id,
           gtfs_version_id,
           station.id,
           station.stop_id,
           level_uuid
         ) do
      {:ok, :removed} ->
        levels =
          Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)
          |> Enum.map(& &1.level)

        station_level_ids = Enum.map(levels, & &1.id)

        available_levels =
          Gtfs.list_all_levels(organization_id, gtfs_version_id)
          |> Enum.reject(&(&1.id in station_level_ids))
          |> Enum.sort_by(&(&1.level_name || &1.level_id), :asc)

        active_level = List.first(levels)

        {:noreply,
         socket
         |> assign(:levels, levels)
         |> assign(:available_levels, available_levels)
         |> assign(:active_level, active_level)
         |> assign(:show_level_modal, nil)
         |> assign(:level_form, to_form(%{}))
         |> refresh_level_and_stop_level_cache(active_level)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove level from station.")}
    end
  end

  defp confirmation_payload(socket, "remove_from_diagram", id, origin_id) do
    with {:ok, stop} <- confirmation_child_stop(socket, id) do
      count = connected_pathway_count(socket, stop.stop_id)

      {:ok,
       confirmation(
         :remove_from_diagram,
         "remove_from_diagram",
         stop.id,
         origin_id,
         "Remove stop from diagram?",
         "This clears its placement and deletes #{count} connected #{pluralize(count, "pathway")}. The stop stays in this station.",
         "Remove stop"
       )}
    end
  end

  defp confirmation_payload(socket, "delete_child_stop", id, origin_id) do
    with {:ok, stop} <- confirmation_child_stop(socket, id) do
      count = connected_pathway_count(socket, stop.stop_id)

      {:ok,
       confirmation(
         :delete_child_stop,
         "delete_child_stop",
         stop.id,
         origin_id,
         "Delete stop?",
         "This permanently deletes #{stop.stop_name || stop.stop_id} and #{count} connected #{pluralize(count, "pathway")}.",
         "Delete stop"
       )}
    end
  end

  defp confirmation_payload(socket, "delete_pathway", id, origin_id) do
    with {:ok, pathway} <- confirmation_pathway(socket, id) do
      {:ok,
       confirmation(
         :delete_pathway,
         "delete_pathway",
         pathway.id,
         origin_id,
         "Delete pathway?",
         "This permanently deletes pathway #{pathway.pathway_id} between its selected stops.",
         "Delete pathway"
       )}
    end
  end

  defp confirmation_payload(socket, "remove_level_from_station", id, origin_id) do
    with {:ok, level, child_stop_count} <- confirmation_level(socket, id) do
      {:ok,
       confirmation(
         :remove_level_from_station,
         "remove_level_from_station",
         level.id,
         origin_id,
         "Remove level from station?",
         "This unassigns #{child_stop_count} child #{pluralize(child_stop_count, "stop")} and removes this level's diagram. The shared level record stays available.",
         "Remove level"
       )}
    end
  end

  defp confirmation_payload(socket, "delete_walkability_test", id, origin_id) do
    with {:ok, walkability_test} <- confirmation_walkability_test(socket, id) do
      {:ok,
       confirmation(
         :delete_walkability_test,
         "delete_walkability_test",
         walkability_test.id,
         origin_id,
         "Delete walkability test?",
         "This permanently deletes the selected walkability test case.",
         "Delete test"
       )}
    end
  end

  defp confirmation_payload(_socket, _action, _id, _origin_id), do: {:error, :unknown_action}

  defp confirmation(action, event, id, origin_id, title, description, confirm_label) do
    %{
      action: action,
      event: event,
      id: id,
      origin_id: safe_focus_origin(origin_id),
      title: title,
      description: description,
      confirm_label: confirm_label,
      pending_label: pending_label(action)
    }
  end

  defp confirmation_child_stop(socket, id) do
    with {:ok, stop} <- fetch_intent_stop(socket, id),
         :ok <- ensure_stop_in_station_scope(socket, stop) do
      {:ok, stop}
    end
  end

  defp confirmation_pathway(socket, id) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Pathway{} = pathway <- Gtfs.get_pathway(uuid),
         true <- pathway.organization_id == organization_id,
         true <- pathway.gtfs_version_id == gtfs_version_id,
         loaded_pathway <- Gtfs.get_pathway_with_stops!(uuid),
         false <- is_nil(loaded_pathway.from_stop),
         false <- is_nil(loaded_pathway.to_stop),
         true <-
           stop_belongs_to_station?(
             loaded_pathway.from_stop,
             socket.assigns.station.stop_id,
             socket.assigns.platform_stop_ids
           ),
         true <-
           stop_belongs_to_station?(
             loaded_pathway.to_stop,
             socket.assigns.station.stop_id,
             socket.assigns.platform_stop_ids
           ) do
      {:ok, loaded_pathway}
    else
      _ -> {:error, :out_of_scope}
    end
  end

  defp confirmation_level(socket, id) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         level when not is_nil(level) <- Gtfs.get_level(uuid),
         stop_level when not is_nil(stop_level) <-
           Gtfs.get_stop_level(organization_id, gtfs_version_id, station.id, uuid) do
      count =
        Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, station.id)
        |> Enum.count(&(&1.level_id == level.level_id))

      _ = stop_level
      {:ok, level, count}
    else
      _ -> {:error, :out_of_scope}
    end
  end

  defp confirmation_walkability_test(socket, id) do
    case Validations.get_walkability_test(id) do
      nil ->
        {:error, :not_found}

      walkability_test ->
        case validate_walkability_test_scope(socket, walkability_test) do
          {:ok, _stop} -> {:ok, walkability_test}
          {:error, _reason} -> {:error, :out_of_scope}
        end
    end
  end

  defp connected_pathway_count(socket, stop_id) do
    Gtfs.list_pathways_for_stop(
      socket.assigns.current_organization.id,
      socket.assigns.current_gtfs_version.id,
      stop_id
    )
    |> length()
  end

  defp confirmed_action?(socket, action, id) do
    socket.assigns.confirmation_execution? and
      match?(%{action: ^action, id: ^id}, socket.assigns.confirmation)
  end

  defp reject_unconfirmed_action(socket) do
    socket
    |> clear_confirmation()
    |> put_flash(:error, "Confirm this action before making changes.")
  end

  defp clear_confirmation(socket) do
    socket
    |> assign(:confirmation, nil)
    |> assign(:pending_action, nil)
    |> assign(:confirmation_execution?, false)
  end

  defp confirmation_value(confirmation, key, default \\ "")
  defp confirmation_value(nil, _key, default), do: default
  defp confirmation_value(confirmation, key, default), do: Map.get(confirmation, key, default)

  defp pending_label(:remove_from_diagram), do: "Removing stop…"
  defp pending_label(:delete_child_stop), do: "Deleting stop…"
  defp pending_label(:delete_pathway), do: "Deleting pathway…"
  defp pending_label(:remove_level_from_station), do: "Removing level…"
  defp pending_label(:delete_walkability_test), do: "Deleting test…"

  defp safe_focus_origin(origin_id) when is_binary(origin_id) do
    if Regex.match?(~r/^[A-Za-z][A-Za-z0-9_-]*$/, origin_id), do: origin_id, else: nil
  end

  defp safe_focus_origin(_origin_id), do: nil

  defp pluralize(1, singular), do: singular
  defp pluralize(_count, singular), do: "#{singular}s"

  defp clear_walkability_selection(socket) do
    current_params = socket.assigns.walkability_form.params || %{}
    preserved = Map.drop(current_params, ["address_autocomplete"])
    updated_params = default_walkability_form_params(preserved)

    socket
    |> assign(:walkability_form, to_form(updated_params, as: :walkability))
    |> assign(:walkability_selected_address, nil)
    |> assign(:walkability_selected_lat, nil)
    |> assign(:walkability_selected_lon, nil)
    |> assign(:walkability_selected_result, nil)
  end

  defp apply_walkability_selection(socket, result) do
    current_params = socket.assigns.walkability_form.params || %{}

    updated_params =
      default_walkability_form_params(
        Map.merge(current_params, %{"address_autocomplete" => result.formatted_address})
      )

    socket
    |> assign(:walkability_form, to_form(updated_params, as: :walkability))
    |> assign(:walkability_selected_address, result.formatted_address)
    |> assign(:walkability_selected_lat, result.lat)
    |> assign(:walkability_selected_lon, result.lon)
    |> assign(:walkability_selected_result, result)
  end

  defp normalize_geocoding_result(%Geocoding.Result{} = result), do: {:ok, result}

  defp normalize_geocoding_result(%{} = result) do
    with formatted_address when is_binary(formatted_address) <-
           Map.get(result, "formatted_address"),
         lat when is_float(lat) <- Map.get(result, "lat"),
         lon when is_float(lon) <- Map.get(result, "lon") do
      {:ok,
       %Geocoding.Result{
         formatted_address: formatted_address,
         lat: lat,
         lon: lon,
         city: Map.get(result, "city"),
         state: Map.get(result, "state"),
         country: Map.get(result, "country")
       }}
    else
      _ -> :error
    end
  end

  defp normalize_geocoding_result(_result), do: :error

  defp apply_walkability_selection_from_form(socket, selection) do
    with {:ok, decoded_selection} <- decode_live_select_selection(selection),
         {:ok, result} <- normalize_geocoding_result(decoded_selection) do
      apply_walkability_selection(socket, result)
    else
      _ ->
        socket.assigns.walkability_last_results
        |> Enum.find(fn result -> result.formatted_address == selection end)
        |> case do
          nil -> clear_walkability_selection(socket)
          result -> apply_walkability_selection(socket, result)
        end
    end
  end

  defp decode_live_select_selection(selection) when is_binary(selection) do
    {:ok, LiveSelect.decode(selection)}
  rescue
    _ -> :error
  end

  defp parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_optional_integer(_), do: nil

  defp extract_field_errors(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.group_by(fn {field, _} -> field end, fn {_, {msg, opts}} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp duplicate_walkability_test?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          opts[:constraint_name] in [
            "walkability_tests_organization_id_stop_id_address_index",
            "walkability_tests_organization_id_gtfs_version_id_stop_id_addre"
          ]

      _ ->
        false
    end)
  end

  defp load_naming_preview(socket, style) do
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    station_stop_id = socket.assigns.station.stop_id

    case Gtfs.preview_station_naming(org_id, version_id, station_stop_id, style) do
      {:ok, preview} ->
        socket
        |> assign(:naming_preview, preview.rows)
        |> assign(:naming_renamed_stops_count, preview.renamed_stops_count)
        |> assign(:naming_updated_pathways_count, preview.updated_pathways_count)
        |> assign(:naming_error, nil)
        |> assign(:naming_excluded_ids, MapSet.new())

      {:error, :no_stops} ->
        socket
        |> assign(:naming_preview, [])
        |> assign(:naming_renamed_stops_count, 0)
        |> assign(:naming_updated_pathways_count, 0)
        |> assign(:naming_error, nil)

      {:error, {:naming_collision, collisions}} ->
        socket
        |> assign(:naming_preview, [])
        |> assign(:naming_renamed_stops_count, 0)
        |> assign(:naming_updated_pathways_count, 0)
        |> assign(:naming_applying?, false)
        |> assign(:naming_error, "Naming collision detected: #{Enum.join(collisions, ", ")}")
    end
  end

  defp assign_naming_selection(socket, excluded_ids) do
    preview_ids = naming_preview_id_set(socket.assigns.naming_preview)
    excluded_ids = MapSet.intersection(excluded_ids, preview_ids)
    selected_ids = MapSet.difference(preview_ids, excluded_ids)
    {updated_pathways_count, error} = naming_selected_preview_state(socket, selected_ids)

    socket
    |> assign(:naming_excluded_ids, excluded_ids)
    |> assign(:naming_renamed_stops_count, MapSet.size(selected_ids))
    |> assign(:naming_updated_pathways_count, updated_pathways_count)
    |> assign(:naming_error, error)
  end

  defp naming_selected_preview_state(socket, selected_ids) do
    if MapSet.size(selected_ids) == 0 do
      {0, nil}
    else
      org_id = socket.assigns.current_organization.id
      version_id = socket.assigns.current_gtfs_version.id
      station_stop_id = socket.assigns.station.stop_id
      style = socket.assigns.naming_style

      case Gtfs.preview_station_naming(org_id, version_id, station_stop_id, style, selected_ids) do
        {:ok, preview} ->
          {preview.updated_pathways_count, nil}

        {:error, :no_stops} ->
          {0, nil}

        {:error, {:naming_collision, collisions}} ->
          {0, "Naming collision detected: #{Enum.join(collisions, ", ")}"}

        {:error, reason} ->
          {0, "Failed to preview naming: #{inspect(reason)}"}
      end
    end
  end

  defp naming_preview_id_set(preview_rows), do: MapSet.new(preview_rows, & &1.old_id)

  defp purge_otp_artifact(organization_id, gtfs_version_id) do
    case Lifecycle.purge_artifact_on_success(organization_id, gtfs_version_id) do
      {:ok, :purged} -> :ok
      {:ok, :not_found} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp cancel_all_diagram_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.diagram.entries, socket, fn entry, acc ->
      cancel_upload(acc, :diagram, entry.ref)
    end)
  end

  defp active_level_name(nil), do: ""

  defp active_level_name(level) do
    level.level_name || level.level_id
  end
end
