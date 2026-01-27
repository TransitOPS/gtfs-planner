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
          phx-hook="AutoSubmitUpload"
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
  attr :active_stop_level, :any, default: nil
  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :pending_xy, :any
  attr :selected_stop_id, :any
  attr :mode, :atom, required: true
  attr :uploads, :any, required: true

  def diagram_canvas(assigns) do
    ~H"""
    <div class="relative bg-base-200 border border-base-300 rounded-lg overflow-hidden">
      <%= cond do %>
        <% @active_stop_level && @active_stop_level.diagram_filename -> %>
          <svg
            id="diagram-canvas"
            phx-hook="DiagramCanvas"
            phx-update="ignore"
            viewBox="0 0 100 100"
            preserveAspectRatio="xMidYMid meet"
            class="w-full block cursor-crosshair"
          >
            <image
              href={"/uploads/diagrams/#{@station.stop_id}/#{@active_stop_level.diagram_filename}"}
              x="0"
              y="0"
              width="100"
              height="100"
              preserveAspectRatio="xMidYMid slice"
            />
          </svg>
          <.diagram_overlay
            streams={@streams}
            active_point_id={@active_point_id}
            pending_xy={@pending_xy}
            selected_stop_id={@selected_stop_id}
            mode={@mode}
          />
        <% @active_level -> %>
          <.empty_diagram_state uploads={@uploads} />
        <% true -> %>
          <.no_level_state />
      <% end %>
    </div>
    """
  end

  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :pending_xy, :any
  attr :selected_stop_id, :any
  attr :mode, :atom, required: true

  defp diagram_overlay(assigns) do
    ~H"""
    <svg
      id="diagram-overlay"
      class="absolute inset-0 w-full h-full pointer-events-none"
      viewBox="0 0 100 100"
      preserveAspectRatio="xMidYMid meet"
    >
      <.pathways_layer streams={@streams} />
      <.stops_layer streams={@streams} active_point_id={@active_point_id} mode={@mode} />
      <.pending_marker
        :if={@pending_xy && @mode == :add && @selected_stop_id == nil}
        pending_xy={@pending_xy}
      />
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
            phx-click="edit_pathway"
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
  attr :mode, :atom, required: true

  defp stops_layer(assigns) do
    ~H"""
    <g id="stops-svg" phx-update="stream">
      <%= for {dom_id, stop} <- @streams.child_stops do %>
        <%= if stop.diagram_coordinate do %>
          <circle
            id={dom_id <> "-circle"}
            cx={stop.diagram_coordinate["x"]}
            cy={stop.diagram_coordinate["y"]}
            r="0.75"
            fill={if @active_point_id == stop.id, do: "#1e40af", else: "#06b6d4"}
            stroke="#fff"
            stroke-width="0.15"
            class={if @mode != :connect, do: "cursor-pointer pointer-events-auto", else: ""}
            phx-click={if @mode != :connect, do: "edit_child_stop", else: nil}
            phx-value-id={if @mode != :connect, do: stop.id, else: nil}
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
      points={"#{@pending_xy.x},#{@pending_xy.y - 1} #{@pending_xy.x - 0.75},#{@pending_xy.y + 0.5} #{@pending_xy.x + 0.75},#{@pending_xy.y + 0.5}"}
      fill="#f97316"
      stroke="#fff"
      stroke-width="0.15"
    />
    """
  end

  attr :uploads, :any, required: true

  defp empty_diagram_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-24 px-8 text-center">
      <div class="text-base-content/40 mb-4">
        <.icon name="hero-map" class="h-12 w-12 mx-auto" />
      </div>
      <p class="text-base-content/80 font-medium mb-1">No diagram for this level</p>
      <p class="text-base-content/50 text-sm mb-6 max-w-xs">
        Upload a floor plan to place stops and draw pathways on this level.
      </p>
      <form
        id="diagram-upload-form-empty"
        phx-change="upload_diagram"
        phx-submit="save_diagram"
        phx-hook="AutoSubmitUpload"
      >
        <label class="btn btn-primary btn-sm">
          Upload Diagram <.live_file_input upload={@uploads.diagram} class="hidden" />
        </label>
      </form>
    </div>
    """
  end

  defp no_level_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-24 px-8 text-center">
      <div class="text-base-content/40 mb-4">
        <.icon name="hero-squares-plus" class="h-12 w-12 mx-auto" />
      </div>
      <p class="text-base-content/80 font-medium mb-1">No levels defined</p>
      <p class="text-base-content/50 text-sm max-w-xs">
        Add a level to this station before uploading a floor plan diagram.
      </p>
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
  # Pathway Drawer
  # ============================================================================

  attr :open, :boolean, required: true
  attr :pathway_form, :any, required: true
  attr :editing_pathway, :any

  def pathway_drawer(assigns) do
    ~H"""
    <.drawer
      id="pathway-drawer"
      open={@open}
      on_close="close_pathway_drawer"
      title="Edit Pathway"
    >
      <.pathway_form :if={@open} pathway_form={@pathway_form} editing_pathway={@editing_pathway} />
    </.drawer>
    """
  end

  attr :pathway_form, :any, required: true
  attr :editing_pathway, :any

  defp pathway_form(assigns) do
    # Build pathway mode options using Pathway module functions
    pathway_mode_options =
      Pathway.pathway_modes()
      |> Enum.map(fn {_name, mode_value} ->
        {Pathway.mode_label(mode_value), to_string(mode_value)}
      end)

    assigns = assign(assigns, :pathway_mode_options, pathway_mode_options)

    ~H"""
    <.simple_form for={@pathway_form} id="pathway-form" phx-submit="save_pathway">
      <.input
        field={@pathway_form[:pathway_id]}
        type="text"
        label="Pathway ID"
        readonly
        class="w-full input input-lg bg-base-200"
      />

      <.input
        field={@pathway_form[:pathway_mode]}
        type="select"
        label="Pathway Mode"
        options={@pathway_mode_options}
        required
      />

      <.input
        field={@pathway_form[:is_bidirectional]}
        type="checkbox"
        label="Bidirectional"
      />

      <.input
        field={@pathway_form[:traversal_time]}
        type="number"
        label="Traversal Time (seconds)"
        step="1"
      />

      <.input
        field={@pathway_form[:length]}
        type="number"
        label="Length (meters)"
        step="0.01"
      />

      <.input
        :if={@pathway_form[:pathway_mode].value == "2"}
        field={@pathway_form[:stair_count]}
        type="number"
        label="Stair Count"
        step="1"
      />

      <.input
        field={@pathway_form[:min_width]}
        type="number"
        label="Minimum Width (meters)"
        step="0.01"
      />

      <.input
        field={@pathway_form[:signposted_as]}
        type="text"
        label="Signposted As"
      />

      <.input
        :if={@pathway_form[:is_bidirectional].value == true}
        field={@pathway_form[:reversed_signposted_as]}
        type="text"
        label="Reversed Signposted As"
      />

      <div :if={@editing_pathway} class="mt-4 p-4 bg-base-200 rounded">
        <div class="text-sm font-medium mb-2">Connected Stops</div>
        <div class="text-sm">
          <div>
            From: {case @editing_pathway.from_stop do
              %Stop{} = stop -> stop.stop_name || stop.stop_id
              _ -> "Unknown stop"
            end}
          </div>
          <div>
            To: {case @editing_pathway.to_stop do
              %Stop{} = stop -> stop.stop_name || stop.stop_id
              _ -> "Unknown stop"
            end}
          </div>
        </div>
      </div>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_pathway_drawer">
          Cancel
        </button>
        <button
          :if={@editing_pathway}
          type="button"
          class="btn btn-error"
          phx-click="delete_pathway"
          phx-value-id={@editing_pathway.id}
        >
          Delete
        </button>
        <div class="flex-1"></div>
        <button type="submit" class="btn btn-primary">
          Save Pathway
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
  attr :available_levels, :list, default: []
  attr :level_mode, :atom, default: :existing

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
        available_levels={@available_levels}
        level_mode={@level_mode}
      />
    </.drawer>
    """
  end

  attr :level_form, :any, required: true
  attr :show_level_modal, :atom, required: true
  attr :available_levels, :list, default: []
  attr :level_mode, :atom, default: :existing

  defp level_form(assigns) do
    ~H"""
    <div :if={@show_level_modal == :add} class="mb-6">
      <div class="form-control">
        <label class="label cursor-pointer justify-start gap-4">
          <input
            type="radio"
            name="mode"
            class="radio radio-primary"
            checked={@level_mode == :existing}
            phx-click="level_mode_changed"
            phx-value-mode="existing"
          />
          <span class="label-text">Use existing level</span>
        </label>
      </div>
      <div class="form-control">
        <label class="label cursor-pointer justify-start gap-4">
          <input
            type="radio"
            name="mode"
            class="radio radio-primary"
            checked={@level_mode == :new}
            phx-click="level_mode_changed"
            phx-value-mode="new"
          />
          <span class="label-text">Create new level</span>
        </label>
      </div>
    </div>

    <.simple_form
      for={@level_form}
      id="level-form"
      phx-submit="save_level"
    >
      <%= if @show_level_modal == :add && @level_mode == :existing do %>
        <%= if @available_levels == [] do %>
          <div class="p-4 bg-base-200 rounded-lg text-center">
            <p class="text-base-content/60 mb-2">All levels are already assigned to this station</p>
            <p class="text-sm text-base-content/40">Switch to "Create new level" to add a new one</p>
          </div>
        <% else %>
          <.input
            field={@level_form[:existing_level_id]}
            type="select"
            label="Select Level"
            options={
              Enum.map(
                @available_levels,
                &{"#{&1.level_name || &1.level_id} (#{trunc(&1.level_index)})", &1.id}
              )
            }
            prompt="Choose a level..."
            required
          />
        <% end %>
      <% else %>
        <.input
          field={@level_form[:level_name]}
          type="text"
          label="Level Name"
          placeholder="e.g., Ground Floor"
          phx-change="level_name_changed"
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
      <% end %>

      <:actions>
        <div class="flex-1"></div>
        <button type="button" class="btn btn-ghost" phx-click="close_level_modal">
          Cancel
        </button>
        <button type="submit" class="btn btn-primary">
          {if @show_level_modal == :add, do: "Save", else: "Update Level"}
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
            class="px-4 py-2 flex justify-between items-center cursor-pointer hover:bg-base-200"
            phx-click="edit_child_stop"
            phx-value-id={stop.id}
          >
            <span class="font-medium">{stop.stop_id}</span>
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
            class="px-4 py-2 flex justify-between items-center cursor-pointer hover:bg-base-200"
            phx-click="edit_pathway"
            phx-value-id={pathway.id}
          >
            <span>
              {pathway.from_stop_id} → {pathway.to_stop_id}
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
