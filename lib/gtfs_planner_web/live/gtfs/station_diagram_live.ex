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
          levels = Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)

          active_level =
            Enum.find(levels, List.first(levels), fn l -> l.level_index == 0.0 end)

          socket =
            socket
            |> assign(:stop_id, stop_id)
            |> assign(:station, station)
            |> assign(:levels, levels)
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
  end

  defp load_level_data(socket, level) do
    station = socket.assigns.station
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    child_stops = Gtfs.list_child_stops_for_level(station.id, level.id)
    pathways = Gtfs.list_pathways_for_level(organization_id, gtfs_version_id, level.id, station.id)

    socket
    |> stream(:child_stops, child_stops, reset: true)
    |> stream(:pathways, pathways, reset: true)
    |> assign(:child_stops_list, child_stops)
    |> assign(:pathways_list, pathways)
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
            has_diagram={@active_level && @active_level.diagram_filename}
            diagram_error={@diagram_error}
          />
          <div class="w-full px-4 sm:px-6 lg:px-8 py-4">
            <.diagram_canvas
              station={@station}
              active_level={@active_level}
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
        />

        <.lists_section
          child_stops_list={@child_stops_list}
          pathways_list={@pathways_list}
          pathway_error={@pathway_error}
        />
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
      parent_station_id: station.id,
      level_id: level.id,
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
    pathway = Gtfs.get_pathway!(id) |> GtfsPlanner.Repo.preload([:from_stop, :to_stop])

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

    case Gtfs.update_pathway(editing_pathway, attrs) do
      {:ok, updated_pathway} ->
        updated_pathway = GtfsPlanner.Repo.preload(updated_pathway, [:from_stop, :to_stop])

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

  @impl true
  def handle_event("upload_diagram", _params, socket) do
    # This event is triggered on file selection - we just need to wait for save_diagram
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_diagram", _params, socket) do
    station = socket.assigns.station
    level = socket.assigns.active_level

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
        case Gtfs.update_level_diagram(level, filename) do
          {:ok, updated_level} ->
            levels =
              Enum.map(socket.assigns.levels, fn l ->
                if l.id == updated_level.id, do: updated_level, else: l
              end)

            {:noreply,
             socket
             |> assign(:active_level, updated_level)
             |> assign(:levels, levels)
             |> assign(:diagram_error, nil)}

          {:error, _changeset} ->
            {:noreply, assign(socket, :diagram_error, "Failed to save diagram")}
        end

      [] ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_add_level", _params, socket) do
    form = to_form(%{"level_id" => "", "level_name" => "", "level_index" => "0"})

    {:noreply,
     socket
     |> assign(:show_level_modal, :add)
     |> assign(:level_form, form)
     |> assign(:level_id_manually_edited, false)}
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

    level_attrs = %{
      level_id: params["level_id"],
      level_name: params["level_name"],
      level_index: parse_int(params["level_index"]),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      parent_station_id: station.id
    }

    case socket.assigns.show_level_modal do
      :add ->
        case Gtfs.create_level(level_attrs) do
          {:ok, new_level} ->
            station = socket.assigns.station
            levels = Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)

            {:noreply,
             socket
             |> assign(:levels, levels)
             |> assign(:active_level, new_level)
             |> assign(:show_level_modal, nil)
             |> assign(:level_form, to_form(%{}))
             |> load_level_data(new_level)}

          {:error, changeset} ->
            {:noreply, assign(socket, :level_form, to_form(changeset))}
        end

      :edit ->
        level = socket.assigns.active_level

        case Gtfs.update_level(level, level_attrs) do
          {:ok, updated_level} ->
            station = socket.assigns.station
            levels = Gtfs.list_levels_for_station(organization_id, gtfs_version_id, station.id)

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
      from_stop_id: from_stop.id,
      to_stop_id: to_stop.id,
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
end