defmodule GtfsPlannerWeb.Gtfs.StationDiagramLive do
  @moduledoc """
  LiveView for the station diagram editor.
  Allows users to view floor plan diagrams, add/edit child stops by clicking,
  create pathways by connecting stops, and switch between levels.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationDiagramComponents
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Station Diagram")
     |> assign(:user_roles, user_roles)
     |> assign(:mode, :view)
     |> assign(:wheelchair_minority, nil)
     |> assign(:pending_xy, nil)
     |> assign(:selected_stop_id, nil)
     |> assign(:active_point_id, nil)
     |> assign(:selected_from_stop, nil)
     |> assign(:cross_level_stop_ids, MapSet.new())
     |> assign(:child_stop_form, to_form(%{}))
     |> assign(:unassigned_child_stops, [])
     |> assign(:show_level_modal, nil)
     |> assign(:level_form, to_form(%{}))
     |> assign(:level_shared, false)
     |> assign(:level_id_manually_edited, false)
     |> assign(:pathway_error, nil)
     |> assign(:diagram_error, nil)
     |> assign(:reposition_mode, false)
     |> assign(:reposition_search, "")
     |> assign(:reposition_stops, [])
     |> assign(:editing_child_stop, nil)
     |> assign(:editing_level, false)
     |> assign(:show_pathway_drawer, false)
     |> assign(:editing_pathway, nil)
     |> assign(:pathway_form, to_form(%{}))
     |> assign(:available_levels, [])
     |> assign(:level_mode, :existing)
     |> allow_upload(:diagram,
       accept: ~w(.png .jpg .jpeg .svg),
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = _params, _uri, socket) do
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

        # Only show levels that are not already assigned to this station
        available_levels =
          Gtfs.list_all_levels(organization_id, gtfs_version_id)
          |> Enum.reject(&(&1.id in station_level_ids))
          |> Enum.sort_by(&(&1.level_name || &1.level_id), :asc)

        # Complete picklist of all levels for stop form dropdown
        all_levels = Gtfs.list_all_levels(organization_id, gtfs_version_id)

        active_level =
          Enum.find(levels, List.first(levels), fn l -> l.level_index == 0.0 end)

        socket =
          socket
          |> assign(:stop_id, stop_id)
          |> assign(:station, station)
          |> assign(:levels, levels)
          |> assign(:available_levels, available_levels)
          |> assign(:all_levels, all_levels)
          |> assign(:active_level, active_level)

        socket = load_level_data(socket, active_level)

        {:noreply, socket}
    end
  end

  defp load_level_data(socket, nil) do
    socket
    |> stream(:child_stops, [], reset: true)
    |> stream(:pathways, [], reset: true)
    |> assign(:child_stops_list, [])
    |> assign(:unassigned_child_stops, [])
    |> assign(:pathways_list, [])
    |> assign(:wheelchair_minority, nil)
    |> assign(:active_stop_level, nil)
  end

  defp load_level_data(socket, level) do
    station = socket.assigns.station
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    stop_level = Gtfs.get_stop_level(organization_id, gtfs_version_id, station.id, level.id)
    all_child_stops = Gtfs.list_child_stops_for_level(station.id, level.id)
    wheelchair_minority = compute_wheelchair_minority(all_child_stops)
    child_stops_on_level = Enum.filter(all_child_stops, & &1.on_active_level)

    unassigned_child_stops =
      Enum.filter(all_child_stops, fn stop -> stop.level_id in [nil, ""] end)

    level_pathways =
      Gtfs.list_pathways_for_level(organization_id, gtfs_version_id, level.id, station.id)

    active_level_stop_ids = active_level_stop_ids(all_child_stops, level)
    connected_stop_ids = connected_stop_ids(level_pathways, active_level_stop_ids)

    visible_canvas_stops =
      visible_canvas_stops(all_child_stops, active_level_stop_ids, connected_stop_ids)

    cross_level_stop_ids =
      Gtfs.list_cross_level_stop_ids(organization_id, gtfs_version_id, station.id)

    socket
    |> stream(:child_stops, visible_canvas_stops, reset: true)
    |> stream(:pathways, level_pathways, reset: true)
    |> assign(:child_stops_list, child_stops_on_level)
    |> assign(:unassigned_child_stops, unassigned_child_stops)
    |> assign(:pathways_list, level_pathways)
    |> assign(:wheelchair_minority, wheelchair_minority)
    |> assign(:active_stop_level, stop_level)
    |> assign(:cross_level_stop_ids, cross_level_stop_ids)
  end

  defp active_level_stop_ids(all_child_stops, level) do
    all_child_stops
    |> Enum.filter(&(&1.level_id == level.level_id))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp connected_stop_ids(level_pathways, active_level_stop_ids) do
    level_pathways
    |> Enum.reduce(MapSet.new(), fn pathway, connected_ids ->
      from_stop_id = pathway.from_stop.id
      to_stop_id = pathway.to_stop.id

      if MapSet.member?(active_level_stop_ids, from_stop_id) or
           MapSet.member?(active_level_stop_ids, to_stop_id) do
        connected_ids
        |> MapSet.put(from_stop_id)
        |> MapSet.put(to_stop_id)
      else
        connected_ids
      end
    end)
  end

  defp visible_canvas_stops(all_child_stops, active_level_stop_ids, connected_stop_ids) do
    Enum.filter(all_child_stops, fn stop ->
      MapSet.member?(active_level_stop_ids, stop.id) or
        MapSet.member?(connected_stop_ids, stop.id)
    end)
  end

  defp compute_wheelchair_minority(child_stops) do
    {accessible_count, inaccessible_count} =
      Enum.reduce(child_stops, {0, 0}, fn stop, {accessible, inaccessible} ->
        case stop.wheelchair_boarding do
          1 -> {accessible + 1, inaccessible}
          2 -> {accessible, inaccessible + 1}
          _ -> {accessible, inaccessible}
        end
      end)

    cond do
      accessible_count < inaccessible_count -> 1
      inaccessible_count < accessible_count -> 2
      true -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="diagram-page" data-immersive={if @mode in [:add, :connect], do: "true"}>
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
            levels={@levels}
            active_level={@active_level}
            mode={@mode}
            uploads={@uploads}
            has_diagram={@active_stop_level && @active_stop_level.diagram_filename}
            diagram_error={@diagram_error}
          />
          <.diagram_action_strip
            mode={@mode}
            selected_from_stop={@selected_from_stop}
            has_diagram={@active_stop_level && @active_stop_level.diagram_filename}
            levels={@levels}
            active_level={@active_level}
          />
          <div id="diagram-canvas-wrapper" class="w-full px-4 sm:px-6 lg:px-8 py-4">
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
              cross_level_stop_ids={@cross_level_stop_ids}
              wheelchair_minority={@wheelchair_minority}
              diagram_error={@diagram_error}
              organization_id={@current_organization.id}
            />
          </div>
        </:sub_header>

        <.child_stop_drawer
          pending_xy={@pending_xy}
          selected_stop_id={@selected_stop_id}
          child_stop_form={@child_stop_form}
          mode={@mode}
          all_levels={@all_levels}
          editing_level={@editing_level}
          active_level={@active_level}
          reposition_mode={@reposition_mode}
          reposition_search={@reposition_search}
          reposition_stops={@reposition_stops}
        />

        <.pathway_drawer
          open={@show_pathway_drawer}
          pathway_form={@pathway_form}
          editing_pathway={@editing_pathway}
        />

        <.level_sidebar
          show_level_modal={@show_level_modal}
          level_form={@level_form}
          available_levels={@available_levels}
          level_mode={@level_mode}
          editing_level_uuid={if @show_level_modal == :edit && @active_level, do: @active_level.id}
          level_shared={@level_shared}
        />

        <.lists_section
          child_stops_list={@child_stops_list}
          unassigned_child_stops={@unassigned_child_stops}
          pathways_list={@pathways_list}
          pathway_error={@pathway_error}
        />
      </Layouts.app>
    </div>
    """
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
         valid_version_for_org?(version_id, current_organization.id) do
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
         |> assign(:active_level, selected_level)
         |> assign(:pending_xy, nil)
         |> assign(:diagram_error, nil)
         |> reset_reposition_state()
         |> load_level_data(selected_level)}
    end
  end

  def handle_event("switch_level", _params, socket) do
    {:noreply, assign(socket, :diagram_error, "Malformed level selection request")}
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => mode}, socket) do
    mode_atom = String.to_existing_atom(mode)

    socket =
      if socket.assigns.mode == :connect do
        assign(socket, :selected_from_stop, nil)
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:mode, mode_atom)
     |> reset_reposition_state()
     |> assign(:pending_xy, nil)
     |> assign(:active_point_id, nil)}
  end

  @impl true
  def handle_event("canvas_click", %{"x" => x, "y" => y}, socket) do
    x = to_float(x)
    y = to_float(y)

    case socket.assigns.mode do
      :add ->
        level_id =
          if socket.assigns.active_level, do: socket.assigns.active_level.level_id, else: ""

        form =
          to_form(%{
            "stop_id" => "",
            "stop_name" => "",
            "location_type" => "3",
            "level_id" => level_id,
            "wheelchair_boarding" => "0",
            "platform_code" => ""
          })

        {:noreply,
         socket
         |> reset_reposition_state()
         |> assign(:pending_xy, %{x: x, y: y})
         |> assign(:selected_stop_id, nil)
         |> assign(:editing_level, false)
         |> assign(:child_stop_form, form)}

      # In :view and :connect modes, stop selection is handled by the SVG
      # hit-target circles via phx-click="stop_clicked" — no proximity search needed.
      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    {:noreply,
     socket
     |> reset_reposition_state()
     |> assign(:pending_xy, nil)
     |> assign(:selected_stop_id, nil)
     |> assign(:child_stop_form, to_form(%{}))}
  end

  @impl true
  def handle_event("enter_reposition_mode", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station

    reposition_stops =
      Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, station.id)

    {:noreply,
     socket
     |> assign(:reposition_mode, true)
     |> assign(:reposition_search, "")
     |> assign(:reposition_stops, reposition_stops)}
  end

  @impl true
  def handle_event("exit_reposition_mode", _params, socket) do
    {:noreply, reset_reposition_state(socket)}
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
  def handle_event("reposition_stop", %{"id" => id}, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station
    pending_xy = socket.assigns.pending_xy
    active_level = socket.assigns.active_level
    stop = Gtfs.get_stop(id)

    cond do
      is_nil(stop) ->
        {:noreply, put_flash(socket, :error, "Invalid stop selection")}

      stop.organization_id != organization_id or stop.gtfs_version_id != gtfs_version_id ->
        {:noreply, put_flash(socket, :error, "Invalid stop selection")}

      stop.parent_station != station.stop_id ->
        {:noreply, put_flash(socket, :error, "Invalid stop selection")}

      is_nil(pending_xy) or is_nil(active_level) ->
        {:noreply, put_flash(socket, :error, "Failed to re-position stop")}

      true ->
        attrs = %{
          diagram_coordinate: %{"x" => pending_xy.x, "y" => pending_xy.y},
          level_id: active_level.level_id
        }

        case Gtfs.update_stop(stop, attrs) do
          {:ok, _updated_stop} ->
            {:noreply,
             socket
             |> refresh_lists()
             |> assign(:pending_xy, nil)
             |> assign(:selected_stop_id, nil)
             |> assign(:child_stop_form, to_form(%{}))
             |> reset_reposition_state()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to re-position stop")}
        end
    end
  end

  @impl true
  def handle_event("stop_clicked", %{"id" => id}, socket) do
    case socket.assigns.mode do
      :connect ->
        handle_stop_selection(id, socket)

      :add ->
        {:noreply, socket}

      _view ->
        handle_event("edit_child_stop", %{"id" => id}, socket)
    end
  end

  @impl true
  def handle_event("edit_child_stop", %{"id" => id}, socket) do
    stop = Gtfs.get_stop!(id)
    coord = stop.diagram_coordinate
    pending_xy = %{x: to_float(coord["x"]), y: to_float(coord["y"])}

    form =
      to_form(%{
        "stop_id" => stop.stop_id,
        "stop_name" => stop.stop_name,
        "location_type" => to_string(stop.location_type),
        "level_id" => stop.level_id,
        "wheelchair_boarding" => to_optional_string(stop.wheelchair_boarding),
        "platform_code" => stop.platform_code || ""
      })

    {:noreply,
     socket
     |> reset_reposition_state()
     |> assign(:pending_xy, pending_xy)
     |> assign(:selected_stop_id, stop.id)
     |> assign(:editing_level, false)
     |> assign(:child_stop_form, form)}
  end

  @impl true
  def handle_event("toggle_level_edit", _params, socket) do
    {:noreply, assign(socket, :editing_level, !socket.assigns.editing_level)}
  end

  @impl true
  def handle_event("validate_child_stop", params, socket) do
    {:noreply, assign(socket, :child_stop_form, to_form(params))}
  end

  @impl true
  def handle_event("save_child_stop", params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station
    pending_xy = socket.assigns.pending_xy

    stop_attrs = %{
      stop_id: params["stop_id"],
      stop_name: params["stop_name"],
      location_type: String.to_integer(params["location_type"]),
      parent_station: station.stop_id,
      level_id: params["level_id"],
      wheelchair_boarding: parse_optional_int(params["wheelchair_boarding"]),
      platform_code: blank_to_nil(params["platform_code"]),
      diagram_coordinate: %{"x" => pending_xy.x, "y" => pending_xy.y},
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    case socket.assigns.selected_stop_id do
      nil ->
        case Gtfs.create_stop(stop_attrs) do
          {:ok, stop} ->
            {:noreply,
             socket
             |> stream_insert(:child_stops, stop)
             |> refresh_lists()
             |> assign(:pending_xy, nil)
             |> assign(:selected_stop_id, nil)
             |> assign(:child_stop_form, to_form(%{}))}

          {:error, changeset} ->
            {:noreply, assign(socket, :child_stop_form, to_form(changeset))}
        end

      stop_id ->
        stop = Gtfs.get_stop!(stop_id)

        case Gtfs.update_stop(stop, stop_attrs) do
          {:ok, updated_stop} ->
            {:noreply,
             socket
             |> stream_insert(:child_stops, updated_stop)
             |> refresh_lists()
             |> assign(:pending_xy, nil)
             |> assign(:selected_stop_id, nil)
             |> assign(:child_stop_form, to_form(%{}))}

          {:error, changeset} ->
            {:noreply, assign(socket, :child_stop_form, to_form(changeset))}
        end
    end
  end

  @impl true
  def handle_event("delete_child_stop", %{"id" => stop_id}, socket) do
    stop = Gtfs.get_stop!(stop_id)
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    # Delete any pathways connected to this stop
    pathways_to_delete =
      Gtfs.list_pathways_for_stop(organization_id, gtfs_version_id, stop.stop_id)

    # Delete pathways from database and remove from stream
    socket =
      Enum.reduce(pathways_to_delete, socket, fn pathway, acc_socket ->
        case Gtfs.delete_pathway(pathway) do
          {:ok, _deleted_pathway} ->
            acc_socket

          {:error, _} ->
            acc_socket
        end
      end)

    # Delete the stop itself
    case Gtfs.delete_stop(stop) do
      {:ok, _deleted_stop} ->
        {:noreply,
         socket
         |> refresh_lists()
         |> assign(:pending_xy, nil)
         |> assign(:selected_stop_id, nil)
         |> assign(:child_stop_form, to_form(%{}))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete child stop")
         |> assign(:pending_xy, nil)
         |> assign(:selected_stop_id, nil)
         |> assign(:child_stop_form, to_form(%{}))}
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
    pathway = Gtfs.get_pathway!(pathway_id)

    case Gtfs.delete_pathway(pathway) do
      {:ok, deleted_pathway} ->
        updated_list = Enum.reject(socket.assigns.pathways_list, &(&1.id == deleted_pathway.id))

        {:noreply,
         socket
         |> stream_delete(:pathways, deleted_pathway)
         |> assign(:pathways_list, updated_list)
         |> assign(:pathway_error, nil)
         |> assign(:show_pathway_drawer, false)
         |> assign(:editing_pathway, nil)
         |> assign(:pathway_form, to_form(%{}))}

      {:error, _changeset} ->
        {:noreply, assign(socket, :pathway_error, "Failed to delete pathway")}
    end
  end

  @impl true
  def handle_event("edit_pathway", %{"id" => id}, socket) do
    if socket.assigns.mode == :add do
      {:noreply, socket}
    else
      pathway = Gtfs.get_pathway_with_stops!(id)

      form =
        to_form(%{
          "pathway_id" => pathway.pathway_id,
          "pathway_mode" => to_string(pathway.pathway_mode),
          "is_bidirectional" => pathway.is_bidirectional,
          "traversal_time" => pathway.traversal_time,
          "length" => pathway.length,
          "stair_count" => pathway.stair_count,
          "min_width" => pathway.min_width,
          "signposted_as" => pathway.signposted_as,
          "reversed_signposted_as" => pathway.reversed_signposted_as
        })

      {:noreply,
       socket
       |> assign(:editing_pathway, pathway)
       |> assign(:pathway_form, form)
       |> assign(:show_pathway_drawer, true)}
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
  def handle_event("close_pathway_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_pathway_drawer, false)
     |> assign(:editing_pathway, nil)
     |> assign(:pathway_form, to_form(%{}))}
  end

  @impl true
  def handle_event("save_pathway", params, socket) do
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
         |> assign(:pathway_form, to_form(%{}))}

      pathway.organization_id != organization_id or pathway.gtfs_version_id != gtfs_version_id ->
        {:noreply,
         socket
         |> assign(:pathway_error, "Unauthorized pathway access.")
         |> assign(:pathway_form, to_form(%{}))}

      is_nil(pathway.from_stop) or is_nil(pathway.to_stop) ->
        {:noreply,
         socket
         |> assign(:pathway_error, "Pathway is not fully associated with stops.")
         |> assign(:pathway_form, to_form(%{}))}

      pathway.from_stop.parent_station != station.stop_id or
          pathway.to_stop.parent_station != station.stop_id ->
        {:noreply,
         socket
         |> assign(:pathway_error, "Unauthorized pathway access.")
         |> assign(:pathway_form, to_form(%{}))}

      true ->
        case Gtfs.update_pathway(pathway, attrs) do
          {:ok, updated_pathway} ->
            from_stop =
              Gtfs.get_stop_by_stop_id(
                organization_id,
                gtfs_version_id,
                updated_pathway.from_stop_id
              )

            to_stop =
              Gtfs.get_stop_by_stop_id(
                organization_id,
                gtfs_version_id,
                updated_pathway.to_stop_id
              )

            updated_pathway = %{updated_pathway | from_stop: from_stop, to_stop: to_stop}

            updated_list =
              Enum.map(socket.assigns.pathways_list, fn p ->
                if p.id == updated_pathway.id, do: updated_pathway, else: p
              end)

            {:noreply,
             socket
             |> stream_insert(:pathways, updated_pathway)
             |> assign(:pathways_list, updated_list)
             |> assign(:show_pathway_drawer, false)
             |> assign(:editing_pathway, nil)
             |> assign(:pathway_form, to_form(%{}))
             |> assign(:pathway_error, nil)}

          {:error, changeset} ->
            {:noreply, assign(socket, :pathway_form, to_form(changeset))}
        end
    end
  end

  @impl true
  def handle_event("upload_diagram", _params, socket) do
    # This event is triggered on file selection - we just need to wait for save_diagram
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_diagram", _params, socket) do
    station = socket.assigns.station
    active_level = socket.assigns.active_level

    if is_nil(active_level) do
      {:noreply, assign(socket, :diagram_error, "No active level selected")}
    else
      stop_level_result =
        case socket.assigns.active_stop_level do
          nil ->
            Gtfs.create_stop_level(%{
              stop_id: station.id,
              level_id: active_level.id,
              organization_id: socket.assigns.current_organization.id,
              gtfs_version_id: socket.assigns.current_gtfs_version.id
            })

          existing ->
            {:ok, existing}
        end

      case stop_level_result do
        {:error, _changeset} ->
          {:noreply, assign(socket, :diagram_error, "Failed to associate level with station")}

        {:ok, stop_level} ->
          uploaded_files =
            consume_uploaded_entries(socket, :diagram, fn %{path: path}, entry ->
              uploads_base = Application.get_env(:gtfs_planner, :uploads_path)

              storage_filename =
                build_diagram_storage_filename(stop_level.level_id, entry.client_name)

              dest_dir =
                Path.join([
                  uploads_base,
                  "diagrams",
                  to_string(socket.assigns.current_organization.id),
                  station.stop_id
                ])

              File.mkdir_p!(dest_dir)

              dest_path = Path.join(dest_dir, storage_filename)
              File.cp!(path, dest_path)

              {:ok, storage_filename}
            end)

          case uploaded_files do
            [filename | _] ->
              case Gtfs.update_stop_level_diagram(stop_level, filename) do
                {:ok, updated_stop_level} ->
                  {:noreply,
                   socket
                   |> assign(:active_stop_level, updated_stop_level)
                   |> assign(:diagram_error, nil)}

                {:error, _changeset} ->
                  {:noreply, assign(socket, :diagram_error, "Failed to save diagram")}
              end

            [] ->
              {:noreply, socket}
          end
      end
    end
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
        levels_data = Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)
        levels = Enum.map(levels_data, & &1.level)
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
         |> load_level_data(active_level)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove level from station.")}
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
                   |> load_level_data(level)}

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
               |> load_level_data(new_level)}

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

        case Gtfs.update_level(level, level_attrs) do
          {:ok, updated_level} ->
            levels_data =
              Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)

            levels = Enum.map(levels_data, & &1.level)

            {:noreply,
             socket
             |> assign(:levels, levels)
             |> assign(:active_level, updated_level)
             |> assign(:show_level_modal, nil)
             |> assign(:level_form, to_form(%{}))}

          {:error, changeset} ->
            {:noreply, assign(socket, :level_form, to_form(changeset))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp handle_stop_selection(id, socket) do
    case socket.assigns.active_point_id do
      nil ->
        # First stop selected - set it as active
        stop = Gtfs.get_stop!(id)

        {:noreply,
         socket
         |> stream_insert(:child_stops, stop)
         |> assign(:active_point_id, id)
         |> assign(:selected_from_stop, stop)}

      ^id ->
        # Clicking same stop - deselect it
        stop = Gtfs.get_stop!(id)

        {:noreply,
         socket
         |> stream_insert(:child_stops, stop)
         |> assign(:active_point_id, nil)
         |> assign(:selected_from_stop, nil)}

      first_stop_id ->
        # Second stop selected - create pathway between them
        create_pathway_between_stops(socket, first_stop_id, id)
    end
  end

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
    case Float.parse(str) do
      {val, _} -> Decimal.from_float(val)
      :error -> nil
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

  defp build_diagram_storage_filename(level_id, client_name) do
    extension =
      client_name
      |> Path.extname()
      |> String.downcase()
      |> String.replace(~r/[^.a-z0-9]/, "")

    safe_extension = if extension == "", do: ".bin", else: extension
    safe_level_id = level_id |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    token = System.unique_integer([:positive, :monotonic])

    "lvl_#{safe_level_id}_#{token}#{safe_extension}"
  end

  defp create_pathway_between_stops(socket, from_stop_id, to_stop_id) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    from_stop = Gtfs.get_stop!(from_stop_id)
    to_stop = Gtfs.get_stop!(to_stop_id)

    pathway_id = "pw_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

    attrs = %{
      pathway_id: pathway_id,
      from_stop_id: from_stop.stop_id,
      to_stop_id: to_stop.stop_id,
      pathway_mode: 1,
      is_bidirectional: true,
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    case Gtfs.create_pathway(attrs) do
      {:ok, _pathway} ->
        {:noreply,
         socket
         |> refresh_lists()
         # Re-stream to remove highlight
         |> stream_insert(:child_stops, from_stop)
         |> assign(:active_point_id, nil)
         |> assign(:selected_from_stop, nil)
         |> assign(:pathway_error, nil)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:active_point_id, nil)
         |> assign(:pathway_error, "Failed to create pathway")}
    end
  end

  defp valid_version_for_org?(version_id, organization_id) do
    try do
      case Versions.get_gtfs_version(version_id) do
        nil -> false
        version -> version.organization_id == organization_id
      end
    rescue
      _ -> false
    end
  end

  defp reset_reposition_state(socket) do
    socket
    |> assign(:reposition_mode, false)
    |> assign(:reposition_search, "")
    |> assign(:reposition_stops, [])
  end

  defp refresh_lists(socket), do: load_level_data(socket, socket.assigns.active_level)
end
