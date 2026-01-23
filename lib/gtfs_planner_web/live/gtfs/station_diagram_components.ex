defmodule GtfsPlannerWeb.Gtfs.StationDiagramComponents do
  @moduledoc """
  Function components for the station diagram editor.
  Extracted from StationDiagramLive to improve modularity and readability.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Pathway

  # ============================================================================
  # Toolbar
  # ============================================================================

  attr :levels, :list, required: true
  attr :active_level, :any, required: true
  attr :mode, :atom, required: true
  attr :uploads, :any, required: true
  attr :diagram_error, :string, default: nil

  def toolbar(assigns) do
    ~H"""
    <div class="mt-6 flex flex-wrap items-center gap-4">
      <form phx-change="switch_level" class="flex items-center gap-2">
        <label class="text-sm font-medium">Level:</label>
        <select class="select select-sm select-bordered" name="level_id">
          <%= for level <- @levels do %>
            <option value={level.id} selected={@active_level && level.id == @active_level.id}>
              {level.level_name || level.level_id} ({trunc(level.level_index)})
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

      <div :if={@active_level} class="flex items-center gap-2">
        <form
          id="diagram-upload-form"
          phx-change="upload_diagram"
          phx-submit="save_diagram"
          phx-hook=".AutoSubmitUpload"
        >
          <label class="btn btn-sm btn-ghost cursor-pointer">
            Upload Diagram <.live_file_input upload={@uploads.diagram} class="hidden" />
          </label>
        </form>
        <span :if={@diagram_error} class="text-error text-sm">{@diagram_error}</span>
      </div>

      <.mode_toggle mode={@mode} />
    </div>
    """
  end

  attr :mode, :atom, required: true

  defp mode_toggle(assigns) do
    ~H"""
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
    """
  end

  # ============================================================================
  # Diagram Canvas
  # ============================================================================

  attr :station, :any, required: true
  attr :active_level, :any, required: true
  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :pending_xy, :any
  attr :mode, :atom, required: true
  attr :uploads, :any, required: true

  def diagram_canvas(assigns) do
    ~H"""
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
        <.diagram_overlay
          streams={@streams}
          active_point_id={@active_point_id}
          pending_xy={@pending_xy}
          mode={@mode}
        />
      <% else %>
        <.empty_diagram_state uploads={@uploads} />
      <% end %>
    </div>
    """
  end

  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :pending_xy, :any
  attr :mode, :atom, required: true

  defp diagram_overlay(assigns) do
    ~H"""
    <svg
      class="absolute inset-0 w-full h-full pointer-events-none"
      viewBox="0 0 100 100"
      preserveAspectRatio="xMidYMid meet"
    >
      <.pathways_layer streams={@streams} />
      <.stops_layer streams={@streams} active_point_id={@active_point_id} />
      <.pending_marker :if={@pending_xy && @mode == :add} pending_xy={@pending_xy} />
    </svg>
    """
  end

  attr :streams, :any, required: true

  defp pathways_layer(assigns) do
    ~H"""
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
    """
  end

  attr :streams, :any, required: true
  attr :active_point_id, :any

  defp stops_layer(assigns) do
    ~H"""
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
    """
  end

  attr :pending_xy, :any, required: true

  defp pending_marker(assigns) do
    ~H"""
    <polygon
      points={"#{@pending_xy.x},#{@pending_xy.y - 2} #{@pending_xy.x - 1.5},#{@pending_xy.y + 1} #{@pending_xy.x + 1.5},#{@pending_xy.y + 1}"}
      fill="#f97316"
      stroke="#fff"
      stroke-width="0.3"
    />
    """
  end

  attr :uploads, :any, required: true

  defp empty_diagram_state(assigns) do
    ~H"""
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
    """
  end

  # ============================================================================
  # Child Stop Drawer
  # ============================================================================

  attr :pending_xy, :any
  attr :selected_stop_id, :any
  attr :child_stop_form, :any, required: true

  def child_stop_drawer(assigns) do
    ~H"""
    <.drawer
      id="child-stop-drawer"
      open={@pending_xy != nil}
      on_close="close_drawer"
      title={if @selected_stop_id, do: "Edit Child Stop", else: "Add Child Stop"}
    >
      <.child_stop_form
        :if={@pending_xy}
        child_stop_form={@child_stop_form}
        selected_stop_id={@selected_stop_id}
        pending_xy={@pending_xy}
      />
    </.drawer>
    """
  end

  attr :child_stop_form, :any, required: true
  attr :selected_stop_id, :any
  attr :pending_xy, :any, required: true

  defp child_stop_form(assigns) do
    # Location type options for select
    location_type_options = [
      {"0 - Stop/Platform", "0"},
      {"2 - Entrance/Exit", "2"},
      {"3 - Generic Node", "3"},
      {"4 - Boarding Area", "4"}
    ]

    assigns = assign(assigns, :location_type_options, location_type_options)

    ~H"""
    <.simple_form for={@child_stop_form} id="child-stop-form" phx-submit="save_child_stop">
      <.input
        field={@child_stop_form[:stop_id]}
        type="text"
        label="Stop ID"
        placeholder="e.g., stop_001"
        required
        readonly={@selected_stop_id != nil}
        class={[
          @selected_stop_id && "w-full input input-lg bg-base-200",
          !@selected_stop_id && "w-full input input-lg"
        ]}
      />

      <.input
        field={@child_stop_form[:stop_name]}
        type="text"
        label="Stop Name"
        placeholder="e.g., Platform A"
        required
      />

      <.input
        field={@child_stop_form[:location_type]}
        type="select"
        label="Location Type"
        options={@location_type_options}
      />

      <.input
        type="text"
        name="position"
        id="position-display"
        label="Position"
        value={"#{Float.round(@pending_xy.x, 2)}, #{Float.round(@pending_xy.y, 2)}"}
        readonly
        class="w-full input input-lg bg-base-200"
        help="X, Y coordinates on diagram (0-100 scale)"
      />

      <:actions>
        <div class="flex-1"></div>
        <button type="button" class="btn btn-ghost" phx-click="close_drawer">
          Cancel
        </button>
        <button type="submit" class="btn btn-primary">
          {if @selected_stop_id, do: "Update Stop", else: "Create Stop"}
        </button>
      </:actions>
    </.simple_form>
    """
  end

  # ============================================================================
  # Level Sidebar
  # ============================================================================

  attr :show_level_modal, :atom
  attr :level_form, :any, required: true

  def level_sidebar(assigns) do
    ~H"""
    <.drawer
      id="level-sidebar"
      open={@show_level_modal != nil}
      on_close="close_level_modal"
      title={if @show_level_modal == :add, do: "Add Level", else: "Edit Level"}
    >
      <.level_form
        :if={@show_level_modal}
        level_form={@level_form}
        show_level_modal={@show_level_modal}
      />
    </.drawer>
    """
  end

  attr :level_form, :any, required: true
  attr :show_level_modal, :atom, required: true

  defp level_form(assigns) do
    ~H"""
    <.simple_form
      for={@level_form}
      id="level-form"
      phx-submit="save_level"
      phx-change="level_name_changed"
    >
      <.input
        field={@level_form[:level_name]}
        type="text"
        label="Level Name"
        placeholder="e.g., Ground Floor"
        help="Optional display name"
      />

      <.input
        field={@level_form[:level_id]}
        type="text"
        label="Level ID"
        placeholder="e.g., STATION_GROUND_FLOOR"
        phx-blur="level_id_changed"
        help="Auto-generated from level name, or enter a custom ID"
      />

      <.input
        field={@level_form[:level_index]}
        type="number"
        label="Level Index"
        step="1"
        required
        help="Floor number (0 = ground, negative = below, positive = above)"
      />

      <:actions>
        <div class="flex-1"></div>
        <button type="button" class="btn btn-ghost" phx-click="close_level_modal">
          Cancel
        </button>
        <button type="submit" class="btn btn-primary">
          {if @show_level_modal == :add, do: "Create Level", else: "Update Level"}
        </button>
      </:actions>
    </.simple_form>
    """
  end

  # ============================================================================
  # Lists Section
  # ============================================================================

  attr :child_stops_list, :list, required: true
  attr :pathways_list, :list, required: true
  attr :pathway_error, :string

  def lists_section(assigns) do
    ~H"""
    <div class="mt-4 grid grid-cols-1 md:grid-cols-2 gap-4">
      <.child_stops_list child_stops_list={@child_stops_list} />
      <.pathways_list pathways_list={@pathways_list} pathway_error={@pathway_error} />
    </div>
    """
  end

  attr :child_stops_list, :list, required: true

  defp child_stops_list(assigns) do
    ~H"""
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
    """
  end

  attr :pathways_list, :list, required: true
  attr :pathway_error, :string

  defp pathways_list(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-2 mb-2">
        <h3 class="font-medium">Pathways on Level</h3>
        <span :if={@pathway_error} class="text-error text-sm">{@pathway_error}</span>
      </div>
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
              {Pathway.mode_label(pathway.pathway_mode)}
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
