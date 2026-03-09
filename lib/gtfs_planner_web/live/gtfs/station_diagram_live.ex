defmodule GtfsPlannerWeb.Gtfs.StationDiagramLive do
  @moduledoc """
  LiveView for the station diagram editor.
  Allows users to view floor plan diagrams, add/edit child stops by clicking,
  create pathways by connecting stops, and switch between levels.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationDiagramComponents
  alias GtfsPlanner.Geocoding
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Coordinates
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopLevel
  alias GtfsPlanner.Otp.Lifecycle
  alias GtfsPlanner.Otp.Materializer
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Versions
  alias LiveSelect.Component, as: LiveSelectComponent
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Station Diagram")
     |> assign(:user_roles, user_roles)
     |> assign(:mode, :view)
     |> assign(:measurement_enabled, false)
     |> assign(:scale_status, nil)
     |> assign(:ruler_point_a, nil)
     |> assign(:ruler_point_b, nil)
     |> assign(:show_ruler_drawer, false)
     |> assign(:ruler_form, to_form(%{"distance_meters" => ""}, as: :ruler))
     |> assign(:pending_xy, nil)
     |> assign(:selected_stop_id, nil)
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
     |> assign(:reposition_mode, false)
     |> assign(:reposition_search, "")
     |> assign(:reposition_stops, [])
     |> assign(:platform_options, [])
     |> assign(:platform_stop_ids, MapSet.new())
     |> assign(:editing_child_stop, nil)
     |> assign(:editing_level, false)
     |> assign(:stop_id_mode, :auto)
     |> assign(:show_pathway_drawer, false)
     |> assign(:editing_pathway, nil)
     |> assign(:pathway_form, to_form(%{}))
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
     |> allow_upload(:diagram,
       accept: ~w(.png .jpg .jpeg .svg),
       max_file_size: 10_000_000,
       max_entries: 1,
       auto_upload: true,
       progress: &handle_diagram_upload_progress/3
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

        socket = load_level_data(socket, active_level)

        {:noreply, socket}
    end
  end

  defp load_level_data(socket, nil) do
    socket
    |> stream(:child_stops, [], reset: true)
    |> stream(:pathways, [], reset: true)
    |> reset_ruler_state()
    |> assign(:child_stops_list, [])
    |> assign(:unassigned_child_stops, [])
    |> assign(:pathways_list, [])
    |> assign(:active_stop_level, nil)
    |> assign(:cross_level_badges_by_stop, %{})
    |> assign(:walkability_test_stop_ids, %{})
    |> assign(:walkability_tests_list, [])
    |> assign(:platform_options, [])
    |> assign(:platform_stop_ids, MapSet.new())
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
      Validations.list_walkability_tests_for_stop_ids(organization_id, child_stop_ids)

    unassigned_child_stops =
      Enum.filter(all_child_stops, fn stop -> stop.level_id in [nil, ""] end)

    level_pathways =
      Gtfs.list_pathways_for_level(organization_id, gtfs_version_id, level.id, station.id)

    active_level_stop_ids = active_level_stop_ids(all_child_stops, level)
    cross_level_badges_by_stop = cross_level_badges_by_stop(level_pathways, active_level_stop_ids)
    visible_canvas_stops = Enum.filter(all_child_stops, & &1.on_active_level)
    same_level_pathways = Enum.reject(level_pathways, & &1.is_cross_level)

    socket
    |> stream(:child_stops, visible_canvas_stops, reset: true)
    |> stream(:pathways, same_level_pathways, reset: true)
    |> reset_ruler_state()
    |> assign(:child_stops_list, child_stops_on_level)
    |> assign(:unassigned_child_stops, unassigned_child_stops)
    |> assign(:pathways_list, level_pathways)
    |> assign(:active_stop_level, stop_level)
    |> assign(:cross_level_badges_by_stop, cross_level_badges_by_stop)
    |> assign(:walkability_test_stop_ids, walkability_test_stop_ids)
    |> assign(:walkability_tests_list, walkability_tests_list)
    |> assign(:platform_options, platforms_for_station)
    |> assign(:platform_stop_ids, platform_stop_ids)
  end

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
            measurement_enabled={@measurement_enabled}
            ruler_point_a={@ruler_point_a}
            ruler_point_b={@ruler_point_b}
            has_scale={scale_configured?(@active_stop_level)}
            scale_status={@scale_status}
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
              cross_level_badges_by_stop={@cross_level_badges_by_stop}
              diagram_error={@diagram_error}
              organization_id={@current_organization.id}
              ruler_point_a={@ruler_point_a}
              ruler_point_b={@ruler_point_b}
              scale_point_a={scale_point(@active_stop_level, :scale_point_a)}
              scale_point_b={scale_point(@active_stop_level, :scale_point_b)}
              measurement_enabled={@measurement_enabled}
            />
          </div>
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
        />

        <.pathway_drawer
          open={@show_pathway_drawer}
          pathway_form={@pathway_form}
          editing_pathway={@editing_pathway}
          has_scale={scale_configured?(@active_stop_level)}
          pathway_error={@pathway_error}
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
         |> disable_measurement()
         |> assign(:active_level, selected_level)
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
         |> load_level_data(selected_level)}
    end
  end

  def handle_event("switch_level", _params, socket) do
    {:noreply, assign(socket, :diagram_error, "Malformed level selection request")}
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => mode}, socket) do
    case parse_mode(mode) do
      {:ok, mode_atom} ->
        socket =
          if socket.assigns.mode == :connect do
            assign(socket, :selected_from_stop, nil)
          else
            socket
          end

        socket =
          socket
          |> assign(:mode, mode_atom)
          |> reset_reposition_state()
          |> assign(:pending_xy, nil)
          |> assign(:active_point_id, nil)
          |> maybe_disable_measurement_for_mode(mode_atom)
          |> restream_active_stop()
          |> restream_mode_dependent_streams()

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
            "stop_lon" => ""
          })

        {:noreply,
         socket
         |> reset_reposition_state()
         |> assign(:pending_xy, %{x: x, y: y})
         |> assign(:selected_stop_id, nil)
         |> assign(:editing_level, false)
         |> assign(:stop_id_mode, :auto)
         |> assign(:child_stop_form, form)}

      # In :connect mode, stop selection is handled by the SVG
      # hit-target circles via phx-click="stop_clicked" — no proximity search needed.
      _ ->
        {:noreply, socket}
    end
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
    pending_xy = socket.assigns.pending_xy
    active_level = socket.assigns.active_level
    reposition_stops = socket.assigns.reposition_stops
    stop = Gtfs.get_stop(id)

    cond do
      is_nil(stop) ->
        {:noreply, put_flash(socket, :error, "Invalid stop selection")}

      stop.organization_id != organization_id or stop.gtfs_version_id != gtfs_version_id ->
        {:noreply, put_flash(socket, :error, "Invalid stop selection")}

      not Enum.any?(reposition_stops, &(&1.id == stop.id)) ->
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
  def handle_event("edit_child_stop", %{"id" => id}, socket) do
    stop = Gtfs.get_stop!(id)
    coord = stop.diagram_coordinate
    pending_xy = %{x: to_float(coord["x"]), y: to_float(coord["y"])}
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
        "stop_lon" => to_optional_string(stop.stop_lon)
      })

    {:noreply,
     socket
     |> reset_reposition_state()
     |> stream_insert(:child_stops, stop)
     |> assign(:pending_xy, pending_xy)
     |> assign(:selected_stop_id, stop.id)
     |> assign(:active_point_id, stop.id)
     |> assign(:editing_level, false)
     |> assign(:stop_id_mode, :manual)
     |> assign(:child_stop_form, form)}
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
    pending_xy = socket.assigns.pending_xy
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
             |> assign(:active_point_id, nil)
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
             |> assign(:active_point_id, nil)
             |> assign(:child_stop_form, to_form(%{}))}

          {:error, changeset} ->
            {:noreply, assign(socket, :child_stop_form, to_form(changeset))}
        end
    end
  end

  @impl true
  def handle_event("remove_from_diagram", %{"id" => stop_id}, socket) do
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

  @impl true
  def handle_event("delete_child_stop", %{"id" => stop_id}, socket) do
    org_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    station_stop_id = socket.assigns.station.stop_id

    case Gtfs.delete_child_stop(org_id, version_id, station_stop_id, stop_id) do
      {:ok, _deleted_stop} ->
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
      {:ok, _deleted_pathway} ->
        {:noreply,
         socket
         |> refresh_lists()
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
      form = to_form(pathway_form_params(pathway))

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
    organization_id = socket.assigns.current_organization.id

    case Validations.get_walkability_test(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Walkability test not found.")}

      walkability_test ->
        case validate_walkability_test_scope(socket, walkability_test) do
          {:ok, _stop} ->
            case Validations.delete_walkability_test(walkability_test) do
              {:ok, _deleted} ->
                purge_otp_artifact(organization_id, socket.assigns.current_gtfs_version.id)

                {:noreply,
                 socket
                 |> reset_walkability_drawer()
                 |> refresh_lists()}

              {:error, _changeset} ->
                {:noreply, put_flash(socket, :error, "Failed to delete walkability test.")}
            end

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
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
          {:ok, _updated_pathway} ->
            {:noreply,
             socket
             |> refresh_lists()
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
    # Upload is handled by allow_upload progress callback when entries complete.
    {:noreply, socket}
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

  defp parse_mode("view"), do: {:ok, :view}
  defp parse_mode("add"), do: {:ok, :add}
  defp parse_mode("connect"), do: {:ok, :connect}
  defp parse_mode(_), do: :error

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

  defp handle_diagram_upload_progress(:diagram, entry, socket) do
    socket =
      if entry.done? do
        persist_uploaded_diagram(socket, entry)
      else
        socket
      end

    {:noreply, socket}
  end

  defp persist_uploaded_diagram(socket, entry) do
    station = socket.assigns.station
    active_level = socket.assigns.active_level

    cond do
      is_nil(active_level) ->
        assign(socket, :diagram_error, "No active level selected")

      true ->
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
            assign(socket, :diagram_error, "Failed to associate level with station")

          {:ok, stop_level} ->
            case consume_uploaded_entry(socket, entry, fn %{path: path} ->
                   uploads_base = Application.get_env(:gtfs_planner, :uploads_path)
                   station_dir = PathSafety.stop_storage_dir(station.stop_id)

                   storage_filename =
                     build_diagram_storage_filename(stop_level.level_id, entry.client_name)

                   with true <- is_binary(station_dir),
                        true <- PathSafety.safe_path_component?(storage_filename),
                        diagrams_root <-
                          Path.join([
                            uploads_base,
                            "diagrams",
                            to_string(socket.assigns.current_organization.id)
                          ]),
                        dest_dir <- Path.join(diagrams_root, station_dir),
                        dest_path <- Path.join(dest_dir, storage_filename),
                        :ok <- PathSafety.ensure_within_root(diagrams_root, dest_dir),
                        :ok <- PathSafety.ensure_within_root(diagrams_root, dest_path),
                        :ok <- File.mkdir_p(dest_dir),
                        :ok <- File.cp(path, dest_path) do
                     {:ok, {:saved, storage_filename}}
                   else
                     false -> {:ok, {:error, :unsafe_path_component}}
                     {:error, reason} -> {:ok, {:error, reason}}
                   end
                 end) do
              {:saved, filename} when is_binary(filename) ->
                persist_stop_level_diagram(socket, stop_level, filename)

              {:error, _reason} ->
                assign(socket, :diagram_error, "Invalid diagram upload path")

              {:postpone, postponed_socket} ->
                postponed_socket
            end
        end
    end
  end

  defp persist_stop_level_diagram(socket, stop_level, filename) do
    case Gtfs.update_stop_level_diagram(stop_level, filename) do
      {:ok, updated_stop_level} ->
        socket
        |> assign(:active_stop_level, updated_stop_level)
        |> disable_measurement()
        |> assign(:diagram_error, nil)

      {:error, _changeset} ->
        assign(socket, :diagram_error, "Failed to save diagram")
    end
  end

  defp create_pathway_between_stops(socket, from_stop_id, to_stop_id) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    from_stop = Gtfs.get_stop!(from_stop_id)
    to_stop = Gtfs.get_stop!(to_stop_id)

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
        loaded_pathway = Gtfs.get_pathway_with_stops!(pathway.id)

        {:noreply,
         socket
         |> refresh_lists()
         # Re-stream to remove highlight
         |> stream_insert(:child_stops, from_stop)
         |> assign(:editing_pathway, loaded_pathway)
         |> assign(:pathway_form, to_form(pathway_form_params(loaded_pathway)))
         |> assign(:show_pathway_drawer, true)
         |> assign(:active_point_id, nil)
         |> assign(:selected_from_stop, nil)
         |> assign(:pathway_error, nil)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:show_pathway_drawer, false)
         |> assign(:editing_pathway, nil)
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

  defp platform_stop_ids_for_station(organization_id, gtfs_version_id, station) do
    Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, station.id)
    |> Enum.filter(&(&1.location_type == 0 and &1.parent_station == station.stop_id))
    |> Enum.map(& &1.stop_id)
    |> MapSet.new()
  end

  defp restream_mode_dependent_streams(socket) do
    same_level_pathways = Enum.reject(socket.assigns.pathways_list, & &1.is_cross_level)

    socket
    |> stream(:child_stops, socket.assigns.child_stops_list, reset: true)
    |> stream(:pathways, same_level_pathways, reset: true)
  end

  defp save_walkability_test_create(socket, organization_id, attrs) do
    case Validations.create_walkability_test(organization_id, attrs) do
      {:ok, _walkability_test} ->
        purge_otp_artifact(organization_id, socket.assigns.current_gtfs_version.id)

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
          opts[:constraint_name] == "walkability_tests_organization_id_stop_id_address_index"

      _ ->
        false
    end)
  end

  defp purge_otp_artifact(organization_id, gtfs_version_id) do
    case Lifecycle.purge_artifact_on_success(organization_id, gtfs_version_id) do
      {:ok, :purged} -> :ok
      {:ok, :not_found} -> :ok
      {:error, _reason} -> :ok
    end
  end
end
