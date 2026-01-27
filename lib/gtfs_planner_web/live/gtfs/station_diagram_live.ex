defmodule GtfsPlannerWeb.Gtfs.StationDiagramLive do
  @moduledoc """
  LiveView for the station diagram editor.
  Allows users to view floor plan diagrams, add/edit child stops by clicking,
  create pathways by connecting stops, and switch between levels.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StationDiagramComponents

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:gtfs_version_pending] do
      {:ok,
       socket
       |> assign(:page_title, "Station Diagram")
       |> assign(:pending_version_resolution, true)}
    else
      user_roles = get_user_roles(socket)

      {:ok,
       socket
       |> assign(:page_title, "Station Diagram")
       |> assign(:user_roles, user_roles)
       |> assign(:mode, :add)
       |> assign(:pending_xy, nil)
       |> assign(:selected_stop_id, nil)
       |> assign(:active_point_id, nil)
       |> assign(:child_stop_form, to_form(%{}))
       |> assign(:show_level_modal, nil)
       |> assign(:level_form, to_form(%{}))
       |> assign(:level_id_manually_edited, false)
       |> assign(:pathway_error, nil)
       |> assign(:diagram_error, nil)
       |> assign(:editing_child_stop, nil)
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
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = _params, _uri, socket) do
    if socket.assigns[:pending_version_resolution] do
      {:noreply, socket}
    else
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

          active_level =
            Enum.find(levels, List.first(levels), fn l -> l.level_index == 0.0 end)

          socket =
            socket
            |> assign(:stop_id, stop_id)
            |> assign(:station, station)
            |> assign(:levels, levels)
            |> assign(:available_levels, available_levels)
            |> assign(:active_level, active_level)

          socket = load_level_data(socket, active_level)

          {:noreply, socket}
      end
    end
  end

  defp load_level_data(socket, nil) do
    socket
    |> stream(:child_stops, [], reset: true)
    |> stream(:pathways, [], reset: true)
    |> assign(:child_stops_list, [])
    |> assign(:pathways_list, [])
    |> assign(:active_stop_level, nil)
    |> assign(:graph_data, %{nodes: [], edges: [], width: 400, height: 200})
  end

  defp load_level_data(socket, level) do
    station = socket.assigns.station
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    stop_level = Gtfs.get_stop_level(organization_id, gtfs_version_id, station.id, level.id)
    child_stops = Gtfs.list_child_stops_for_level(station.id, level.id)

    pathways =
      Gtfs.list_pathways_for_level(organization_id, gtfs_version_id, level.id, station.id)

    # Build graph data for single-level SVG visualization
    graph_data = build_pathways_graph(child_stops, pathways)

    socket
    |> stream(:child_stops, child_stops, reset: true)
    |> stream(:pathways, pathways, reset: true)
    |> assign(:child_stops_list, child_stops)
    |> assign(:pathways_list, pathways)
    |> assign(:active_stop_level, stop_level)
    |> assign(:graph_data, graph_data)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if assigns[:pending_version_resolution] do %>
      <div
        id="gtfs-version-resolver"
        phx-hook="GtfsVersionHook"
        data-organization-id={@current_organization.id}
      >
        <div class="flex items-center justify-center min-h-screen">
          <div class="text-center">
            <div class="loading loading-spinner loading-lg"></div>
            <p class="mt-4 text-base-content/60">Loading GTFS version...</p>
          </div>
        </div>
      </div>
    <% else %>
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
          <div class="w-full px-4 sm:px-6 lg:px-8 py-4">
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
            />
          </div>
        </:sub_header>

        <.child_stop_drawer
          pending_xy={@pending_xy}
          selected_stop_id={@selected_stop_id}
          child_stop_form={@child_stop_form}
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
        />

        <.lists_section
          child_stops_list={@child_stops_list}
          pathways_list={@pathways_list}
          pathway_error={@pathway_error}
        />

        <%= if @active_level && @graph_data.nodes != [] do %>
          <div class="mx-4 sm:mx-6 lg:mx-8 mt-8">
            <h2 class="text-lg font-semibold mb-4">Pathways Graph</h2>
            <div class="bg-base-100 border border-base-300 rounded-lg p-4 overflow-x-auto">
              <%!-- Legend --%>
              <div class="flex flex-wrap gap-4 mb-4 text-sm">
                <div class="flex items-center gap-2">
                  <span class="font-medium">Nodes:</span>
                  <span class="flex items-center gap-1">
                    <span class="w-3 h-3 rounded-full bg-blue-500"></span> Platform
                  </span>
                  <span class="flex items-center gap-1">
                    <span class="w-3 h-3 rounded-full bg-green-500"></span> Station
                  </span>
                  <span class="flex items-center gap-1">
                    <span class="w-3 h-3 rounded-full bg-amber-500"></span> Entrance
                  </span>
                  <span class="flex items-center gap-1">
                    <span class="w-3 h-3 rounded-full bg-gray-500"></span> Node
                  </span>
                  <span class="flex items-center gap-1">
                    <span class="w-3 h-3 rounded-full bg-purple-500"></span> Boarding
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <span class="font-medium">Edges:</span>
                  <span class="flex items-center gap-1">
                    <span class="w-4 h-0.5 bg-gray-500"></span> Walkway
                  </span>
                  <span class="flex items-center gap-1">
                    <span class="w-4 h-0.5 bg-amber-500 border-dashed border-t-2 border-amber-500">
                    </span>
                    Stairs
                  </span>
                  <span class="flex items-center gap-1">
                    <span class="w-4 h-0.5 bg-blue-500"></span> Elevator
                  </span>
                </div>
              </div>

              <%!-- SVG Graph --%>
              <svg
                width={@graph_data.width}
                height={@graph_data.height}
                class="bg-base-200 rounded"
                viewBox={"0 0 #{@graph_data.width} #{@graph_data.height}"}
              >
                <%!-- Draw edges first (behind nodes) --%>
                <%= for edge <- @graph_data.edges do %>
                  <line
                    x1={edge.from_x}
                    y1={edge.from_y}
                    x2={edge.to_x}
                    y2={edge.to_y}
                    stroke={pathway_stroke_color(edge.pathway_mode)}
                    stroke-width="2"
                    stroke-dasharray={pathway_stroke_dash(edge.pathway_mode)}
                  />
                  <%!-- Arrow for directional pathways --%>
                  <%= if not edge.is_bidirectional do %>
                    <polygon
                      points={arrow_points(edge.from_x, edge.from_y, edge.to_x, edge.to_y)}
                      fill={pathway_stroke_color(edge.pathway_mode)}
                    />
                  <% end %>
                <% end %>

                <%!-- Draw nodes --%>
                <%= for node <- @graph_data.nodes do %>
                  <g>
                    <%!-- Node circle --%>
                    <circle
                      cx={node.x}
                      cy={node.y}
                      r="12"
                      fill={node_fill_color(node.location_type)}
                      stroke="#fff"
                      stroke-width="2"
                    />
                    <%!-- Node label --%>
                    <text
                      x={node.x}
                      y={node.y + 28}
                      text-anchor="middle"
                      class="text-xs fill-base-content"
                      font-size="10"
                    >
                      {truncate_label(node.label, 12)}
                    </text>
                  </g>
                <% end %>
              </svg>
            </div>
          </div>
        <% end %>
      </Layouts.app>
    <% end %>
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

    # Try to use the stored version_id from localStorage
    version_to_use =
      if version_id && valid_version_for_org?(version_id, current_organization.id) do
        version_id
      else
        # Fall back to latest version or current version
        case socket.assigns[:latest_gtfs_version] do
          {:ok, version} -> to_string(version.id)
          {:error, :no_versions} -> nil
          # Already on a valid route
          nil -> current_version_id
        end
      end

    # Only navigate if switching to a different version
    if version_to_use && version_to_use != current_version_id do
      path = "/gtfs/#{version_to_use}/stops/#{stop_id}/diagram"
      {:noreply, push_navigate(socket, to: path)}
    else
      # Already on correct version, do nothing
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_level", params, socket) do
    level_id = params["level_id"]
    level = Enum.find(socket.assigns.levels, fn l -> to_string(l.id) == level_id end)

    {:noreply,
     socket
     |> assign(:active_level, level)
     |> assign(:pending_xy, nil)
     |> assign(:active_point_id, nil)
     |> load_level_data(level)}
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => mode}, socket) do
    mode_atom = String.to_existing_atom(mode)

    {:noreply,
     socket
     |> assign(:mode, mode_atom)
     |> assign(:pending_xy, nil)
     |> assign(:active_point_id, nil)}
  end

  @impl true
  def handle_event("canvas_click", %{"x" => x, "y" => y}, socket) do
    IO.inspect({x, y}, label: "DEBUG: canvas_click received")
    IO.inspect(socket.assigns.mode, label: "DEBUG: current mode")

    case socket.assigns.mode do
      :add ->
        child_stops = get_child_stops_with_coordinates(socket)
        clicked_stop = find_stop_near_point(child_stops, x, y, 5.0)

        case clicked_stop do
          nil ->
            # No stop found - create new stop
            form = to_form(%{"stop_id" => "", "stop_name" => "", "location_type" => "0"})

            {:noreply,
             socket
             |> assign(:pending_xy, %{x: x, y: y})
             |> assign(:selected_stop_id, nil)
             |> assign(:child_stop_form, form)}

          stop ->
            # Stop found - edit existing stop
            coord = stop.diagram_coordinate
            pending_xy = %{x: to_float(coord["x"]), y: to_float(coord["y"])}

            form =
              to_form(%{
                "stop_id" => stop.stop_id,
                "stop_name" => stop.stop_name,
                "location_type" => to_string(stop.location_type)
              })

            {:noreply,
             socket
             |> assign(:pending_xy, pending_xy)
             |> assign(:selected_stop_id, stop.id)
             |> assign(:child_stop_form, form)}
        end

      :connect ->
        handle_connect_click(socket, x, y)
    end
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_xy, nil)
     |> assign(:selected_stop_id, nil)
     |> assign(:child_stop_form, to_form(%{}))}
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
        "location_type" => to_string(stop.location_type)
      })

    {:noreply,
     socket
     |> assign(:pending_xy, pending_xy)
     |> assign(:selected_stop_id, stop.id)
     |> assign(:child_stop_form, form)}
  end

  @impl true
  def handle_event("save_child_stop", params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    station = socket.assigns.station
    level = socket.assigns.active_level
    pending_xy = socket.assigns.pending_xy

    stop_attrs = %{
      stop_id: params["stop_id"],
      stop_name: params["stop_name"],
      location_type: String.to_integer(params["location_type"]),
      parent_station: station.stop_id,
      level_id: level.level_id,
      diagram_coordinate: %{"x" => pending_xy.x, "y" => pending_xy.y},
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    case socket.assigns.selected_stop_id do
      nil ->
        case Gtfs.create_stop(stop_attrs) do
          {:ok, stop} ->
            updated_list = [stop | socket.assigns.child_stops_list]

            {:noreply,
             socket
             |> stream_insert(:child_stops, stop)
             |> assign(:child_stops_list, updated_list)
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
            updated_list =
              Enum.map(socket.assigns.child_stops_list, fn s ->
                if s.id == updated_stop.id, do: updated_stop, else: s
              end)

            {:noreply,
             socket
             |> stream_insert(:child_stops, updated_stop)
             |> assign(:child_stops_list, updated_list)
             |> assign(:pending_xy, nil)
             |> assign(:selected_stop_id, nil)
             |> assign(:child_stop_form, to_form(%{}))}

          {:error, changeset} ->
            {:noreply, assign(socket, :child_stop_form, to_form(changeset))}
        end
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
    stop_level = socket.assigns.active_stop_level

    if is_nil(stop_level) do
      {:noreply, assign(socket, :diagram_error, "No active level selected")}
    else
      uploaded_files =
        consume_uploaded_entries(socket, :diagram, fn %{path: path}, entry ->
          dest_dir = Path.join(["priv", "static", "uploads", "diagrams", station.stop_id])
          File.mkdir_p!(dest_dir)

          dest_path = Path.join(dest_dir, entry.client_name)
          File.cp!(path, dest_path)

          {:ok, entry.client_name}
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

    {:noreply,
     socket
     |> assign(:show_level_modal, :edit)
     |> assign(:level_form, form)
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

  defp to_snakecase_id(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]+/, "_")
    |> String.trim("_")
  end

  defp to_snakecase_id(_), do: ""

  defp handle_connect_click(socket, x, y) do
    child_stops = get_child_stops_with_coordinates(socket)
    IO.inspect(length(child_stops), label: "DEBUG: child_stops with coords count")

    Enum.each(child_stops, fn stop ->
      coord = stop.diagram_coordinate
      coord_x = to_float(coord["x"])
      coord_y = to_float(coord["y"])
      distance = :math.sqrt((coord_x - x) * (coord_x - x) + (coord_y - y) * (coord_y - y))

      IO.inspect({stop.stop_id, coord, {coord_x, coord_y}, {x, y}, distance},
        label: "DEBUG: stop info"
      )
    end)

    clicked_stop = find_stop_near_point(child_stops, x, y, 5.0)
    IO.inspect(clicked_stop && clicked_stop.stop_id, label: "DEBUG: clicked_stop")

    case {socket.assigns.active_point_id, clicked_stop} do
      {nil, nil} ->
        {:noreply, socket}

      {nil, stop} ->
        # Re-stream the stop to force UI re-render with new active_point_id
        {:noreply,
         socket
         |> stream_insert(:child_stops, stop)
         |> assign(:active_point_id, stop.id)}

      {_first_id, nil} ->
        # Re-stream the previously selected stop to remove highlight
        prev_stop = Gtfs.get_stop!(socket.assigns.active_point_id)

        {:noreply,
         socket
         |> stream_insert(:child_stops, prev_stop)
         |> assign(:active_point_id, nil)}

      {first_id, stop} when first_id == stop.id ->
        # Clicking same stop deselects it - re-stream to update UI
        {:noreply,
         socket
         |> stream_insert(:child_stops, stop)
         |> assign(:active_point_id, nil)}

      {first_id, stop} ->
        create_pathway_between_stops(socket, first_id, stop.id)
    end
  end

  defp get_child_stops_with_coordinates(socket) do
    station = socket.assigns.station
    level = socket.assigns.active_level

    if level do
      Gtfs.list_child_stops_for_level(station.id, level.id)
      |> Enum.filter(&(&1.diagram_coordinate != nil))
    else
      []
    end
  end

  defp find_stop_near_point(stops, x, y, radius) do
    Enum.find(stops, fn stop ->
      coord = stop.diagram_coordinate
      # Ensure floats for consistent arithmetic (JSONB may return integers)
      coord_x = to_float(coord["x"])
      coord_y = to_float(coord["y"])
      dx = coord_x - x
      dy = coord_y - y
      :math.sqrt(dx * dx + dy * dy) <= radius
    end)
  end

  defp to_float(val) when is_float(val), do: val
  defp to_float(val) when is_integer(val), do: val / 1
  defp to_float(val) when is_binary(val), do: String.to_float(val)
  defp to_float(nil), do: 0.0

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
      {:ok, pathway} ->
        pathway = %{pathway | from_stop: from_stop, to_stop: to_stop}
        updated_list = [pathway | socket.assigns.pathways_list]

        {:noreply,
         socket
         |> stream_insert(:pathways, pathway)
         |> assign(:pathways_list, updated_list)
         # Re-stream to remove highlight
         |> stream_insert(:child_stops, from_stop)
         |> assign(:active_point_id, nil)
         |> assign(:pathway_error, nil)}

      {:error, changeset} ->
        IO.inspect(changeset, label: "DEBUG: pathway creation FAILED")

        {:noreply,
         socket
         |> assign(:active_point_id, nil)
         |> assign(:pathway_error, "Failed to create pathway")}
    end
  end

  defp get_user_roles(socket) do
    user = socket.assigns[:current_user]
    organization = socket.assigns[:current_organization]

    case GtfsPlanner.Accounts.get_user_org_membership(user.id, organization.id) do
      %UserOrgMembership{roles: roles} when is_list(roles) -> roles
      _ -> []
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

  # Build graph data structure for single-level SVG visualization
  # Returns %{nodes: [...], edges: [...], width: int, height: int}
  defp build_pathways_graph(child_stops, pathways) do
    if child_stops == [] do
      %{nodes: [], edges: [], width: 400, height: 200}
    else
      # Create stop_id -> stop map (kept for potential future use)
      _stop_map = Map.new(child_stops, fn s -> {s.stop_id, s} end)

      # Horizontal spacing for single-level layout
      node_spacing_x = 120
      padding = 60

      # Calculate node positions (single row, horizontal layout)
      nodes =
        child_stops
        |> Enum.with_index()
        |> Enum.map(fn {stop, col} ->
          x = padding + col * node_spacing_x
          y = 100

          %{
            id: stop.stop_id,
            label: stop.stop_id,
            x: x,
            y: y,
            location_type: stop.location_type
          }
        end)

      # Create node position lookup
      node_pos_map = Map.new(nodes, fn n -> {n.id, {n.x, n.y}} end)

      # Build edges from pathways (already filtered by level)
      edges =
        pathways
        |> Enum.filter(fn p ->
          Map.has_key?(node_pos_map, p.from_stop_id) and Map.has_key?(node_pos_map, p.to_stop_id)
        end)
        |> Enum.map(fn p ->
          {from_x, from_y} = Map.get(node_pos_map, p.from_stop_id)
          {to_x, to_y} = Map.get(node_pos_map, p.to_stop_id)

          %{
            from_id: p.from_stop_id,
            to_id: p.to_stop_id,
            from_x: from_x,
            from_y: from_y,
            to_x: to_x,
            to_y: to_y,
            pathway_mode: p.pathway_mode,
            is_bidirectional: p.is_bidirectional
          }
        end)

      # Calculate SVG dimensions
      max_x = nodes |> Enum.map(& &1.x) |> Enum.max(fn -> 0 end)

      width = max(max_x + padding + 60, 400)
      height = 240

      %{nodes: nodes, edges: edges, width: width, height: height}
    end
  end

  # Get stroke color for pathway mode
  defp pathway_stroke_color(mode) do
    case mode do
      1 -> "#6b7280"
      2 -> "#f59e0b"
      3 -> "#8b5cf6"
      4 -> "#ec4899"
      5 -> "#3b82f6"
      6 -> "#ef4444"
      7 -> "#10b981"
      _ -> "#9ca3af"
    end
  end

  # Get stroke dash array for pathway mode
  defp pathway_stroke_dash(mode) do
    case mode do
      # Stairs - dashed
      2 -> "4,4"
      # Escalator - dotted
      4 -> "2,2"
      # Elevator - long dash
      5 -> "8,4"
      # Fare/Exit gates - dash-dot
      6 -> "6,2,2,2"
      7 -> "6,2,2,2"
      # Default solid
      _ -> "none"
    end
  end

  # Get node fill color based on location_type
  defp node_fill_color(location_type) do
    case location_type do
      # Platform
      0 -> "#3b82f6"
      # Station
      1 -> "#10b981"
      # Entrance/Exit
      2 -> "#f59e0b"
      # Generic node
      3 -> "#6b7280"
      # Boarding area
      4 -> "#8b5cf6"
      _ -> "#9ca3af"
    end
  end

  # Calculate arrow points for directional pathway edges
  defp arrow_points(from_x, from_y, to_x, to_y) do
    # Calculate direction vector
    dx = to_x - from_x
    dy = to_y - from_y
    len = :math.sqrt(dx * dx + dy * dy)

    # Normalize and scale
    if len > 0 do
      nx = dx / len
      ny = dy / len

      # Arrow tip position (slightly before the target node)
      tip_x = to_x - nx * 14
      tip_y = to_y - ny * 14

      # Arrow size
      arrow_len = 8
      arrow_width = 4

      # Perpendicular vector
      px = -ny
      py = nx

      # Arrow base points
      base_x = tip_x - nx * arrow_len
      base_y = tip_y - ny * arrow_len

      left_x = base_x + px * arrow_width
      left_y = base_y + py * arrow_width

      right_x = base_x - px * arrow_width
      right_y = base_y - py * arrow_width

      "#{tip_x},#{tip_y} #{left_x},#{left_y} #{right_x},#{right_y}"
    else
      "0,0 0,0 0,0"
    end
  end

  # Truncate label to max length
  defp truncate_label(label, max_len) when is_binary(label) do
    if String.length(label) > max_len do
      String.slice(label, 0, max_len - 1) <> "..."
    else
      label
    end
  end

  defp truncate_label(label, _max_len), do: to_string(label)
end
