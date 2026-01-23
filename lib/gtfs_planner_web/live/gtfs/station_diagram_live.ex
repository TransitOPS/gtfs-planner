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
          levels =
            Gtfs.list_levels(organization_id, gtfs_version_id)
            |> Enum.sort_by(& &1.level_index)

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
    pathways = Gtfs.list_pathways_for_level(organization_id, gtfs_version_id, level.id)

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
      >
        <.header>
          {@station.stop_name || @stop_id}
          <:subtitle>Station ID: {@stop_id}</:subtitle>
          <:actions>
            <.link
              navigate={"/gtfs/#{@current_gtfs_version.id}/stops/#{@stop_id}"}
              class="btn btn-ghost btn-sm"
            >
              Back to Details
            </.link>
          </:actions>
        </.header>

        <.toolbar
          levels={@levels}
          active_level={@active_level}
          mode={@mode}
          uploads={@uploads}
          diagram_error={@diagram_error}
        />

        <.diagram_canvas
          station={@station}
          active_level={@active_level}
          streams={@streams}
          active_point_id={@active_point_id}
          pending_xy={@pending_xy}
          mode={@mode}
          uploads={@uploads}
        />

        <.child_stop_drawer
          pending_xy={@pending_xy}
          selected_stop_id={@selected_stop_id}
          child_stop_form={@child_stop_form}
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

        <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoSubmitUpload">
          export default {
            mounted() {
              const form = this.el;
              const fileInput = form.querySelector('input[type="file"]');
              if (fileInput) {
                fileInput.addEventListener("change", () => {
                  // Small delay to ensure LiveView has processed the file
                  setTimeout(() => {
                    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
                  }, 100);
                });
              }
            }
          }
        </script>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".DiagramCanvas">
          export default {
            mounted() {
              const svg = this.el;
              let viewBox = { x: 0, y: 0, w: 100, h: 100 };
              let scale = 1;
              const minScale = 0.5;
              const maxScale = 5;
              let isPanning = false;
              let panStart = { x: 0, y: 0 };

              svg.addEventListener("wheel", (e) => {
                e.preventDefault();
                if (e.ctrlKey || e.metaKey) {
                  const delta = e.deltaY > 0 ? 1.1 : 0.9;
                  const newScale = Math.min(maxScale, Math.max(minScale, scale * delta));

                  if (newScale !== scale) {
                    const rect = svg.getBoundingClientRect();
                    const mouseX = (e.clientX - rect.left) / rect.width * viewBox.w + viewBox.x;
                    const mouseY = (e.clientY - rect.top) / rect.height * viewBox.h + viewBox.y;

                    const newW = 100 / newScale;
                    const newH = 100 / newScale;

                    viewBox.x = mouseX - (mouseX - viewBox.x) * (newW / viewBox.w);
                    viewBox.y = mouseY - (mouseY - viewBox.y) * (newH / viewBox.h);
                    viewBox.w = newW;
                    viewBox.h = newH;
                    scale = newScale;

                    svg.setAttribute("viewBox", `${viewBox.x} ${viewBox.y} ${viewBox.w} ${viewBox.h}`);
                  }
                } else {
                  const panSpeed = 0.5;
                  viewBox.x += e.deltaX * panSpeed / scale;
                  viewBox.y += e.deltaY * panSpeed / scale;
                  svg.setAttribute("viewBox", `${viewBox.x} ${viewBox.y} ${viewBox.w} ${viewBox.h}`);
                }
              }, { passive: false });

              svg.addEventListener("mousedown", (e) => {
                if (e.button === 1 || (e.button === 0 && e.shiftKey)) {
                  isPanning = true;
                  panStart = { x: e.clientX, y: e.clientY };
                  svg.style.cursor = "grabbing";
                  e.preventDefault();
                }
              });

              svg.addEventListener("mousemove", (e) => {
                if (isPanning) {
                  const rect = svg.getBoundingClientRect();
                  const dx = (e.clientX - panStart.x) / rect.width * viewBox.w;
                  const dy = (e.clientY - panStart.y) / rect.height * viewBox.h;
                  viewBox.x -= dx;
                  viewBox.y -= dy;
                  panStart = { x: e.clientX, y: e.clientY };
                  svg.setAttribute("viewBox", `${viewBox.x} ${viewBox.y} ${viewBox.w} ${viewBox.h}`);
                }
              });

              svg.addEventListener("mouseup", () => {
                isPanning = false;
                svg.style.cursor = "crosshair";
              });

              svg.addEventListener("mouseleave", () => {
                isPanning = false;
                svg.style.cursor = "crosshair";
              });

              svg.addEventListener("click", (e) => {
                if (e.shiftKey) return;
                const pt = svg.createSVGPoint();
                pt.x = e.clientX;
                pt.y = e.clientY;
                const svgPt = pt.matrixTransform(svg.getScreenCTM().inverse());
                const x = Math.round(svgPt.x * 100) / 100;
                const y = Math.round(svgPt.y * 100) / 100;
                this.pushEvent("canvas_click", { x, y });
              });

              svg.addEventListener("gesturestart", (e) => e.preventDefault());
              svg.addEventListener("gesturechange", (e) => e.preventDefault());
            }
          }
        </script>
      </Layouts.app>
    <% end %>
    """
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

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
    case socket.assigns.mode do
      :add ->
        form = to_form(%{"stop_id" => "", "stop_name" => "", "location_type" => "0"})

        {:noreply,
         socket
         |> assign(:pending_xy, %{x: x, y: y})
         |> assign(:selected_stop_id, nil)
         |> assign(:child_stop_form, form)}

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
            {:noreply,
             socket
             |> stream_insert(:child_stops, stop)
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
        {:noreply,
         socket
         |> stream_delete(:pathways, deleted_pathway)
         |> assign(:pathway_error, nil)}

      {:error, _changeset} ->
        {:noreply, assign(socket, :pathway_error, "Failed to delete pathway")}
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

    level_attrs = %{
      level_id: params["level_id"],
      level_name: params["level_name"],
      level_index: parse_int(params["level_index"]),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    case socket.assigns.show_level_modal do
      :add ->
        case Gtfs.create_level(level_attrs) do
          {:ok, new_level} ->
            levels =
              Gtfs.list_levels(organization_id, gtfs_version_id)
              |> Enum.sort_by(& &1.level_index)

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
            levels =
              Gtfs.list_levels(organization_id, gtfs_version_id)
              |> Enum.sort_by(& &1.level_index)

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
    clicked_stop = find_stop_near_point(child_stops, x, y, 3.0)

    case {socket.assigns.active_point_id, clicked_stop} do
      {nil, nil} ->
        {:noreply, socket}

      {nil, stop} ->
        {:noreply, assign(socket, :active_point_id, stop.id)}

      {_first_id, nil} ->
        {:noreply, assign(socket, :active_point_id, nil)}

      {first_id, stop} when first_id == stop.id ->
        {:noreply, assign(socket, :active_point_id, nil)}

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
      dx = coord["x"] - x
      dy = coord["y"] - y
      :math.sqrt(dx * dx + dy * dy) <= radius
    end)
  end

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
      is_bidirectional: 1,
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    case Gtfs.create_pathway(attrs) do
      {:ok, pathway} ->
        pathway = %{pathway | from_stop: from_stop, to_stop: to_stop}

        {:noreply,
         socket
         |> stream_insert(:pathways, pathway)
         |> assign(:active_point_id, nil)
         |> assign(:pathway_error, nil)}

      {:error, _changeset} ->
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
end