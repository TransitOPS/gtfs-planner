defmodule GtfsPlannerWeb.Gtfs.StationDiagramLive do
  @moduledoc """
  LiveView for the station diagram editor.
  Allows users to view floor plan diagrams, add/edit child stops by clicking,
  create pathways by connecting stops, and switch between levels.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop

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
          {:noreply,
           socket
           |> put_flash(:error, "Station not found")
           |> push_navigate(to: "/gtfs/#{gtfs_version_id}/stops")}

        station ->
          levels = Gtfs.list_levels(organization_id, gtfs_version_id)

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

        <div class="mt-6 flex flex-wrap items-center gap-4">
          <form phx-change="switch_level" class="flex items-center gap-2">
            <label class="text-sm font-medium">Level:</label>
            <select
              class="select select-sm select-bordered"
              name="level_id"
            >
              <%= for level <- @levels do %>
                <option value={level.id} selected={@active_level && level.id == @active_level.id}>
                  {level.level_name || level.level_id}
                </option>
              <% end %>
            </select>
          </form>

          <button type="button" class="btn btn-sm btn-ghost" phx-click="open_add_level">
            Add Level
          </button>

          <button
            :if={@active_level}
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="open_edit_level"
          >
            Edit Level
          </button>

          <form
            :if={@active_level}
            id="diagram-upload-form"
            phx-change="upload_diagram"
            phx-submit="save_diagram"
            phx-hook=".AutoSubmitUpload"
          >
            <label class="btn btn-sm btn-ghost cursor-pointer">
              Upload Diagram <.live_file_input upload={@uploads.diagram} class="hidden" />
            </label>
          </form>

          <div class="join">
            <button
              type="button"
              class={["btn btn-sm join-item", @mode == :add && "btn-active"]}
              phx-click="switch_mode"
              phx-value-mode="add"
            >
              Add Stop
            </button>
            <button
              type="button"
              class={["btn btn-sm join-item", @mode == :connect && "btn-active"]}
              phx-click="switch_mode"
              phx-value-mode="connect"
            >
              Connect
            </button>
          </div>
        </div>

        <div class="mt-6 relative bg-base-200 border border-base-300 rounded-lg overflow-hidden aspect-video">
          <%= if @active_level && @active_level.diagram_filename do %>
            <svg
              id="diagram-canvas"
              phx-hook=".DiagramCanvas"
              phx-update="ignore"
              viewBox="0 0 100 100"
              preserveAspectRatio="xMidYMid meet"
              class="w-full h-full cursor-crosshair"
            >
              <image
                href={"/uploads/diagrams/#{@station.stop_id}/#{@active_level.diagram_filename}"}
                x="0"
                y="0"
                width="100"
                height="100"
                preserveAspectRatio="xMidYMid meet"
              />
            </svg>
            <%!-- Pathway lines rendered outside phx-update="ignore" --%>
            <svg
              class="absolute inset-0 w-full h-full pointer-events-none"
              viewBox="0 0 100 100"
              preserveAspectRatio="xMidYMid meet"
            >
              <g id="pathways-svg" phx-update="stream">
                <%= for {dom_id, pathway} <- @streams.pathways do %>
                  <%= if pathway.from_stop.diagram_coordinate && pathway.to_stop.diagram_coordinate do %>
                    <g
                      id={dom_id}
                      class="cursor-pointer pointer-events-auto"
                      phx-click="delete_pathway"
                      phx-value-id={pathway.id}
                    >
                      <%!-- Invisible wider line for easier clicking --%>
                      <line
                        x1={pathway.from_stop.diagram_coordinate["x"]}
                        y1={pathway.from_stop.diagram_coordinate["y"]}
                        x2={pathway.to_stop.diagram_coordinate["x"]}
                        y2={pathway.to_stop.diagram_coordinate["y"]}
                        stroke="transparent"
                        stroke-width="2"
                      />
                      <%!-- Visible line --%>
                      <line
                        x1={pathway.from_stop.diagram_coordinate["x"]}
                        y1={pathway.from_stop.diagram_coordinate["y"]}
                        x2={pathway.to_stop.diagram_coordinate["x"]}
                        y2={pathway.to_stop.diagram_coordinate["y"]}
                        stroke="#0891b2"
                        stroke-width="0.5"
                        stroke-linecap="round"
                        class="hover:stroke-error transition-colors"
                      />
                    </g>
                  <% end %>
                <% end %>
              </g>
              <g id="stops-svg" phx-update="stream">
                <%= for {dom_id, stop} <- @streams.child_stops do %>
                  <%= if stop.diagram_coordinate do %>
                    <circle
                      id={dom_id <> "-circle"}
                      cx={stop.diagram_coordinate["x"]}
                      cy={stop.diagram_coordinate["y"]}
                      r="1.5"
                      fill={if @active_point_id == stop.id, do: "#1e40af", else: "#06b6d4"}
                      stroke="#fff"
                      stroke-width="0.3"
                    />
                  <% end %>
                <% end %>
              </g>
              <%= if @pending_xy && @mode == :add do %>
                <polygon
                  points={"#{@pending_xy.x},#{@pending_xy.y - 2} #{@pending_xy.x - 1.5},#{@pending_xy.y + 1} #{@pending_xy.x + 1.5},#{@pending_xy.y + 1}"}
                  fill="#f97316"
                  stroke="#fff"
                  stroke-width="0.3"
                />
              <% end %>
            </svg>
          <% else %>
            <div class="absolute inset-0 flex flex-col items-center justify-center text-base-content/60">
              <p class="mb-4">No floor plan uploaded</p>
              <form
                id="diagram-upload-form-empty"
                phx-change="upload_diagram"
                phx-submit="save_diagram"
                phx-hook=".AutoSubmitUpload"
              >
                <label class="btn btn-primary btn-sm">
                  Upload Diagram <.live_file_input upload={@uploads.diagram} class="hidden" />
                </label>
              </form>
            </div>
          <% end %>
        </div>

        <%!-- Child Stop Drawer --%>
        <div
          id="drawer-overlay"
          class={[
            "fixed inset-0 bg-black/30 z-40 transition-opacity duration-300",
            if(@pending_xy, do: "opacity-100", else: "opacity-0 pointer-events-none")
          ]}
          phx-click="close_drawer"
        >
        </div>
        <aside
          id="child-stop-drawer"
          class={[
            "fixed top-0 right-0 h-full w-full max-w-[480px] min-w-[320px] bg-base-100 shadow-xl border-l border-base-200 z-50 transition-transform duration-300",
            if(@pending_xy, do: "translate-x-0", else: "translate-x-full")
          ]}
        >
          <div class="p-6 h-full flex flex-col">
            <div class="flex items-center justify-between mb-6">
              <h2 class="text-lg font-semibold">
                {if @selected_stop_id, do: "Edit Child Stop", else: "Add Child Stop"}
              </h2>
              <button type="button" class="btn btn-ghost btn-sm btn-circle" phx-click="close_drawer">
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>

            <.form
              :if={@pending_xy}
              for={@child_stop_form}
              id="child-stop-form"
              phx-submit="save_child_stop"
              class="flex-1 flex flex-col"
            >
              <div class="space-y-4 flex-1">
                <fieldset class="fieldset">
                  <legend class="fieldset-legend">Stop ID</legend>
                  <input
                    type="text"
                    name="stop_id"
                    value={@child_stop_form[:stop_id].value}
                    class="input w-full"
                    placeholder="e.g., stop_001"
                    required
                    readonly={@selected_stop_id != nil}
                  />
                </fieldset>

                <fieldset class="fieldset">
                  <legend class="fieldset-legend">Stop Name</legend>
                  <input
                    type="text"
                    name="stop_name"
                    value={@child_stop_form[:stop_name].value}
                    class="input w-full"
                    placeholder="e.g., Platform A"
                    required
                  />
                </fieldset>

                <fieldset class="fieldset">
                  <legend class="fieldset-legend">Location Type</legend>
                  <select name="location_type" class="select w-full">
                    <option value="0" selected={@child_stop_form[:location_type].value == "0"}>
                      0 - Stop/Platform
                    </option>
                    <option value="2" selected={@child_stop_form[:location_type].value == "2"}>
                      2 - Entrance/Exit
                    </option>
                    <option value="3" selected={@child_stop_form[:location_type].value == "3"}>
                      3 - Generic Node
                    </option>
                    <option value="4" selected={@child_stop_form[:location_type].value == "4"}>
                      4 - Boarding Area
                    </option>
                  </select>
                </fieldset>

                <fieldset class="fieldset">
                  <legend class="fieldset-legend">Position</legend>
                  <input
                    type="text"
                    value={"#{Float.round(@pending_xy.x, 2)}, #{Float.round(@pending_xy.y, 2)}"}
                    class="input w-full"
                    readonly
                  />
                  <p class="label text-xs">X, Y coordinates on diagram (0-100 scale)</p>
                </fieldset>
              </div>

              <div class="flex gap-3 mt-6 pt-4 border-t border-base-200">
                <button type="submit" class="btn btn-primary flex-1">
                  {if @selected_stop_id, do: "Update", else: "Create"}
                </button>
                <button type="button" class="btn btn-ghost" phx-click="close_drawer">
                  Cancel
                </button>
              </div>
            </.form>
          </div>
        </aside>

        <%!-- Level Form Modal --%>
        <dialog id="level-modal" class={["modal", @show_level_modal && "modal-open"]}>
          <div class="modal-box">
            <div class="flex items-center justify-between mb-4">
              <h3 class="font-semibold text-lg">
                {if @show_level_modal == :add, do: "Add Level", else: "Edit Level"}
              </h3>
              <button
                type="button"
                class="btn btn-ghost btn-sm btn-circle"
                phx-click="close_level_modal"
              >
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>

            <.form
              :if={@show_level_modal}
              for={@level_form}
              id="level-form"
              phx-submit="save_level"
              class="space-y-4"
            >
              <fieldset class="fieldset">
                <legend class="fieldset-legend">Level ID</legend>
                <input
                  type="text"
                  name="level_id"
                  value={@level_form[:level_id].value}
                  class="input w-full"
                  placeholder="e.g., L1"
                  required
                  readonly={@show_level_modal == :edit}
                />
                <p class="label text-xs">Unique identifier for this level</p>
              </fieldset>

              <fieldset class="fieldset">
                <legend class="fieldset-legend">Level Name</legend>
                <input
                  type="text"
                  name="level_name"
                  value={@level_form[:level_name].value}
                  class="input w-full"
                  placeholder="e.g., Ground Floor"
                />
                <p class="label text-xs">Optional display name</p>
              </fieldset>

              <fieldset class="fieldset">
                <legend class="fieldset-legend">Level Index</legend>
                <input
                  type="number"
                  name="level_index"
                  value={@level_form[:level_index].value}
                  class="input w-full"
                  step="0.5"
                  required
                />
                <p class="label text-xs">Vertical order (0 = ground, negative = below, positive = above)</p>
              </fieldset>

              <div class="modal-action">
                <button type="submit" class="btn btn-primary">
                  {if @show_level_modal == :add, do: "Create", else: "Update"}
                </button>
                <button type="button" class="btn btn-ghost" phx-click="close_level_modal">
                  Cancel
                </button>
              </div>
            </.form>
          </div>
          <form method="dialog" class="modal-backdrop">
            <button type="button" phx-click="close_level_modal">close</button>
          </form>
        </dialog>

        <div class="mt-4 grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <h3 class="font-medium mb-2">Child Stops on Level</h3>
            <div
              id="child-stops-list"
              class="bg-base-100 border border-base-300 rounded-lg divide-y divide-base-300"
            >
              <%= if @child_stops_list == [] do %>
                <div class="px-4 py-2 text-base-content/60">
                  No stops on this level
                </div>
              <% else %>
                <div
                  :for={stop <- @child_stops_list}
                  id={"child-stop-list-#{stop.id}"}
                  class="px-4 py-2 flex justify-between items-center"
                >
                  <span class="font-medium">{stop.stop_name || stop.stop_id}</span>
                  <span class="badge badge-ghost badge-sm">
                    {Stop.location_type_label(stop.location_type)}
                  </span>
                </div>
              <% end %>
            </div>
          </div>

          <div>
            <h3 class="font-medium mb-2">Pathways on Level</h3>
            <div
              id="pathways-list"
              class="bg-base-100 border border-base-300 rounded-lg divide-y divide-base-300"
            >
              <%= if @pathways_list == [] do %>
                <div class="px-4 py-2 text-base-content/60">
                  No pathways on this level
                </div>
              <% else %>
                <div
                  :for={pathway <- @pathways_list}
                  id={"pathway-list-#{pathway.id}"}
                  class="px-4 py-2 flex justify-between items-center"
                >
                  <span>
                    {pathway.from_stop.stop_name || pathway.from_stop.stop_id} → {pathway.to_stop.stop_name ||
                      pathway.to_stop.stop_id}
                  </span>
                  <span class="badge badge-outline badge-sm">
                    {GtfsPlanner.Gtfs.Pathway.mode_label(pathway.pathway_mode)}
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        </div>

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

  @impl true
  def handle_event("switch_level", params, socket) do
    level_id = params["level_id"]
    level = Enum.find(socket.assigns.levels, fn l -> to_string(l.id) == level_id end)

    IO.inspect(params, label: "switch_level params")
    IO.inspect(level_id, label: "level_id")
    IO.inspect(level, label: "found level")

    socket =
      socket
      |> assign(:active_level, level)
      |> assign(:pending_xy, nil)
      |> assign(:active_point_id, nil)
      |> load_level_data(level)
      |> put_flash(:info, "Switched to level: #{if level, do: level.level_name || level.level_id, else: "nil"}")

    {:noreply, socket}
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
             |> assign(:child_stop_form, to_form(%{}))
             |> put_flash(:info, "Child stop created")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:child_stop_form, to_form(changeset))
             |> put_flash(:error, "Failed to create child stop")}
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
             |> assign(:child_stop_form, to_form(%{}))
             |> put_flash(:info, "Child stop updated")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:child_stop_form, to_form(changeset))
             |> put_flash(:error, "Failed to update child stop")}
        end
    end
  end

  @impl true
  def handle_event("create_pathway", %{"from_stop_id" => from_stop_id, "to_stop_id" => to_stop_id}, socket) do
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
         |> put_flash(:info, "Pathway deleted")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete pathway")}
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
             |> put_flash(:info, "Diagram uploaded")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to save diagram")}
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
     |> assign(:level_form, form)}
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
     |> assign(:level_form, form)}
  end

  @impl true
  def handle_event("close_level_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_level_modal, nil)
     |> assign(:level_form, to_form(%{}))}
  end

  @impl true
  def handle_event("save_level", params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    level_attrs = %{
      level_id: params["level_id"],
      level_name: params["level_name"],
      level_index: parse_float(params["level_index"]),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    }

    case socket.assigns.show_level_modal do
      :add ->
        case Gtfs.create_level(level_attrs) do
          {:ok, new_level} ->
            levels = Gtfs.list_levels(organization_id, gtfs_version_id)

            {:noreply,
             socket
             |> assign(:levels, levels)
             |> assign(:active_level, new_level)
             |> assign(:show_level_modal, nil)
             |> assign(:level_form, to_form(%{}))
             |> load_level_data(new_level)
             |> put_flash(:info, "Level created")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:level_form, to_form(changeset))
             |> put_flash(:error, "Failed to create level")}
        end

      :edit ->
        level = socket.assigns.active_level

        case Gtfs.update_level(level, level_attrs) do
          {:ok, updated_level} ->
            levels = Gtfs.list_levels(organization_id, gtfs_version_id)

            {:noreply,
             socket
             |> assign(:levels, levels)
             |> assign(:active_level, updated_level)
             |> assign(:show_level_modal, nil)
             |> assign(:level_form, to_form(%{}))
             |> put_flash(:info, "Level updated")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:level_form, to_form(changeset))
             |> put_flash(:error, "Failed to update level")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp parse_float(str) when is_binary(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> 0.0
    end
  end

  defp parse_float(_), do: 0.0

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
         |> put_flash(:info, "Pathway created")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:active_point_id, nil)
         |> put_flash(:error, "Failed to create pathway")}
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