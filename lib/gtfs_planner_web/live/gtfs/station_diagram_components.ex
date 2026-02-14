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
            Upload Diagram
            <.live_file_input upload={@uploads.diagram} id="toolbar-diagram-upload" class="hidden" />
          </label>
        </form>
        <span :if={@diagram_error} class="text-error text-sm">{@diagram_error}</span>
      </div>

      <.mode_toggle mode={@mode} />
    </div>
    """
  end

  attr :mode, :atom, required: true
  attr :has_diagram, :boolean, default: true

  defp mode_toggle(assigns) do
    ~H"""
    <div class="join">
      <button
        type="button"
        class={[
          "btn join-item",
          @mode == :add && "bg-blue-600 text-white hover:bg-blue-700",
          @mode != :add && "bg-white text-blue-600 hover:bg-blue-50 border-blue-300",
          !@has_diagram && "opacity-50 cursor-not-allowed"
        ]}
        phx-click="switch_mode"
        phx-value-mode="add"
        disabled={!@has_diagram}
      >
        Add Stop
      </button>
      <button
        type="button"
        class={[
          "btn join-item",
          @mode == :connect && "bg-blue-600 text-white hover:bg-blue-700",
          @mode != :connect && "bg-white text-blue-600 hover:bg-blue-50 border-blue-300",
          !@has_diagram && "opacity-50 cursor-not-allowed"
        ]}
        phx-click="switch_mode"
        phx-value-mode="connect"
        disabled={!@has_diagram}
      >
        Connect
      </button>
    </div>
    """
  end

  # ============================================================================
  # Diagram Action Strip
  # ============================================================================

  attr :mode, :atom, required: true
  attr :selected_from_stop, :any, default: nil
  attr :has_diagram, :boolean, required: true
  attr :levels, :list, default: []
  attr :active_level, :any, default: nil

  def diagram_action_strip(assigns) do
    ~H"""
    <%= if @levels != [] do %>
      <div class="sticky top-0 z-10 flex items-center justify-between px-4 py-3 bg-blue-50 border-b border-blue-200">
        <div class="flex items-center gap-2">
          <form phx-change="switch_level" class="flex items-center gap-2">
            <label class="text-sm font-medium text-blue-900">Level:</label>
            <select class="select select-sm select-bordered bg-white" name="level_id">
              <%= for level <- @levels do %>
                <option value={level.id} selected={@active_level && level.id == @active_level.id}>
                  {level.level_name || level.level_id}
                </option>
              <% end %>
            </select>
          </form>
          <%= if @has_diagram do %>
            <%= cond do %>
              <% @mode == :add -> %>
                <span class="text-sm text-blue-700 font-medium">
                  Click diagram to add a child stop
                </span>
              <% @mode == :connect && @selected_from_stop == nil -> %>
                <span class="text-sm text-blue-700 font-medium">
                  Choose a child stop to begin pathway
                </span>
              <% @mode == :connect && @selected_from_stop != nil -> %>
                <span class="text-sm text-blue-700 font-medium">
                  From: {@selected_from_stop.stop_name || @selected_from_stop.stop_id} — select destination stop
                </span>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm text-blue-700 hover:text-blue-900 hover:bg-blue-100"
                  phx-click="clear_from_selection"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              <% true -> %>
                <span class="text-sm text-blue-700"></span>
            <% end %>
          <% end %>
        </div>

        <.mode_toggle mode={@mode} has_diagram={@has_diagram} />
      </div>
    <% end %>
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
  attr :cross_level_stop_ids, :any, default: MapSet.new()
  attr :diagram_error, :string, default: nil
  attr :organization_id, :string, required: true

  def diagram_canvas(assigns) do
    canvas_key = diagram_canvas_key(assigns.active_level, assigns.active_stop_level)

    image_href =
      diagram_image_href(assigns.organization_id, assigns.station, assigns.active_stop_level)

    assigns =
      assigns
      |> assign(:canvas_key, canvas_key)
      |> assign(:image_href, image_href)

    ~H"""
    <div class="relative bg-base-200 border border-base-300 rounded-lg overflow-hidden">
      <%= cond do %>
        <% @active_stop_level && @active_stop_level.diagram_filename -> %>
          <svg
            id={"diagram-canvas-#{@canvas_key}"}
            phx-hook="DiagramCanvas"
            data-canvas-key={@canvas_key}
            viewBox="0 0 100 100"
            preserveAspectRatio="xMidYMid meet"
            class="w-full block cursor-crosshair"
          >
            <image
              href={@image_href}
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
            cross_level_stop_ids={@cross_level_stop_ids}
          />
        <% @active_level -> %>
          <.empty_diagram_state />
        <% true -> %>
          <.no_level_state />
      <% end %>
    </div>
    """
  end

  defp diagram_canvas_key(active_level, active_stop_level) do
    level_part = if active_level, do: to_string(active_level.id), else: "no-level"

    file_part =
      if active_stop_level, do: active_stop_level.diagram_filename || "no-file", else: "no-file"

    safe_level = String.replace(level_part, ~r/[^A-Za-z0-9_-]/, "_")
    safe_file = String.replace(file_part, ~r/[^A-Za-z0-9_.-]/, "_")
    "#{safe_level}-#{safe_file}"
  end

  defp diagram_image_href(organization_id, station, active_stop_level) do
    case active_stop_level.diagram_filename do
      filename when is_binary(filename) ->
        token = URI.encode_www_form(filename)
        "/uploads/diagrams/#{organization_id}/#{station.stop_id}/#{filename}?v=#{token}"

      _ ->
        nil
    end
  end

  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :pending_xy, :any
  attr :selected_stop_id, :any
  attr :mode, :atom, required: true
  attr :cross_level_stop_ids, :any, default: MapSet.new()

  defp diagram_overlay(assigns) do
    ~H"""
    <svg
      id="diagram-overlay"
      class="absolute inset-0 w-full h-full pointer-events-none"
      viewBox="0 0 100 100"
      preserveAspectRatio="xMidYMid meet"
    >
      <.pathways_layer streams={@streams} />
      <.stops_layer
        streams={@streams}
        active_point_id={@active_point_id}
        mode={@mode}
        cross_level_stop_ids={@cross_level_stop_ids}
      />
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
  attr :cross_level_stop_ids, :any, default: MapSet.new()

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
            stroke={
              cond do
                @active_point_id == stop.id -> "#1e40af"
                MapSet.member?(@cross_level_stop_ids, stop.id) -> "#f59e0b"
                true -> "#fff"
              end
            }
            stroke-width={if MapSet.member?(@cross_level_stop_ids, stop.id), do: "0.25", else: "0.15"}
            class="cursor-pointer pointer-events-auto"
            phx-click="stop_clicked"
            phx-value-id={stop.id}
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
      <p class="text-base-content/40 text-xs">
        Use the "Upload Diagram" button in the navigation bar above.
      </p>
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
  attr :mode, :atom, required: true
  attr :all_levels, :list, required: true

  def child_stop_drawer(assigns) do
    ~H"""
    <.drawer
      id="child-stop-drawer"
      open={@pending_xy != nil && @mode == :add}
      on_close="close_drawer"
      title={if @selected_stop_id, do: "Edit Child Stop", else: "Add Child Stop"}
      class="max-w-3xl"
    >
      <.child_stop_form
        :if={@pending_xy}
        child_stop_form={@child_stop_form}
        selected_stop_id={@selected_stop_id}
        pending_xy={@pending_xy}
        all_levels={@all_levels}
      />
    </.drawer>
    """
  end

  attr :child_stop_form, :any, required: true
  attr :selected_stop_id, :any
  attr :pending_xy, :any, required: true
  attr :all_levels, :list, required: true

  defp child_stop_form(assigns) do
    # Location type options for select (GTFS spec allows 0-4 for child stops)
    # Note: Type 1 (Station) can be used for hierarchical stations in complex transit hubs
    # Type 0 (Stop/Platform) removed - Generic Node (3) is the default for child stops
    location_type_options = [
      {"1 - Station", "1"},
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
        field={@child_stop_form[:level_id]}
        type="select"
        label="Level"
        options={
          [{"— No Level —", ""}] ++
            Enum.map(@all_levels, fn level ->
              {"#{level.level_name || level.level_id} (#{trunc(level.level_index)})", level.level_id}
            end)
        }
        help="GTFS level for this child stop"
      />

      <:actions>
        <div class="flex-1"></div>
        <button type="button" class="btn btn-ghost" phx-click="close_drawer">
          Cancel
        </button>
        <button type="submit" class="btn btn-primary btn-active">
          {if @selected_stop_id, do: "Update Stop", else: "Create Stop"}
        </button>
      </:actions>
    </.simple_form>

    <div :if={@selected_stop_id} class="mt-8 pt-6 border-t border-base-200">
      <div class="bg-error/5 border border-error/20 rounded-lg p-4">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="text-error font-medium">Delete Child Stop</h3>
            <p class="text-xs text-error/70 mt-1">
              This will also delete any pathways connected to this stop.
            </p>
          </div>
          <button
            type="button"
            class="btn btn-error btn-sm btn-active text-white"
            phx-click="delete_child_stop"
            phx-value-id={@selected_stop_id}
            data-confirm="Are you sure you want to delete this child stop? Any pathways connected to it will also be deleted."
          >
            Delete Stop
          </button>
        </div>
      </div>
    </div>
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
      class="max-w-4xl"
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
      <%!-- ID is hidden as it's auto-managed or readonly --%>
      <.input field={@pathway_form[:pathway_id]} type="hidden" />

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <.input
          field={@pathway_form[:pathway_mode]}
          type="select"
          label="Pathway Mode"
          options={@pathway_mode_options}
          required
          help="Type of connection (e.g., walkway, stairs, elevator)."
        />

        <div>
          <label class="text-sm font-medium leading-6 text-zinc-800">
            Bidirectional
          </label>
          <div class="mt-2">
            <.input
              field={@pathway_form[:is_bidirectional]}
              type="checkbox"
              label="Can be traversed in both directions?"
            />
          </div>
        </div>
      </div>

      <div class="mt-10 mb-3 uppercase text-base font-semibold text-base-content">
        Metrics
      </div>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <.input
          field={@pathway_form[:traversal_time]}
          type="number"
          label="Traversal Time (s)"
          step="1"
          min="0"
          help="Average time to traverse in seconds."
        />

        <.input
          field={@pathway_form[:length]}
          type="number"
          label="Length (m)"
          step="0.01"
          min="0"
          help="Horizontal length in meters."
        />

        <.input
          field={@pathway_form[:min_width]}
          type="number"
          label="Min Width (m)"
          step="0.01"
          min="0"
          help="Minimum width for accessibility."
        />
      </div>

      <%= if @pathway_form[:pathway_mode].value == "2" do %>
        <div class="mt-4">
          <.input
            field={@pathway_form[:stair_count]}
            type="number"
            label="Stair Count"
            step="1"
            min="0"
            help="Total number of steps (up is positive)."
          />
        </div>
      <% end %>

      <div class="mt-10 mb-3 uppercase text-base font-semibold text-base-content">
        Signage
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <.input
          field={@pathway_form[:signposted_as]}
          type="text"
          label="Signposted As"
          help="Text on signs guiding to this pathway."
        />

        <.input
          :if={@pathway_form[:is_bidirectional].value == true}
          field={@pathway_form[:reversed_signposted_as]}
          type="text"
          label="Reversed Signposted As"
          help="Text on signs for the reverse direction."
        />
      </div>

      <div :if={@editing_pathway} class="mt-8 p-6 bg-base-200 rounded-lg">
        <h4 class="font-bold text-sm uppercase tracking-wide text-base-content/50 mb-4">
          Connection Details
        </h4>
        <div class="grid grid-cols-2 gap-4 text-sm">
          <div>
            <span class="block text-xs font-semibold text-base-content/40">From Stop</span>
            <span class="font-medium">
              {case @editing_pathway.from_stop do
                %Stop{} = stop -> stop.stop_name || stop.stop_id
                _ -> "Unknown stop"
              end}
            </span>
          </div>
          <div>
            <span class="block text-xs font-semibold text-base-content/40">To Stop</span>
            <span class="font-medium">
              {case @editing_pathway.to_stop do
                %Stop{} = stop -> stop.stop_name || stop.stop_id
                _ -> "Unknown stop"
              end}
            </span>
          </div>
        </div>
      </div>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_pathway_drawer">
          Cancel
        </button>
        <div class="flex-1"></div>
        <button type="submit" class="btn btn-primary btn-active">
          Save Pathway
        </button>
      </:actions>
    </.simple_form>

    <div :if={@editing_pathway} class="mt-8 pt-6 border-t border-base-200">
      <div class="bg-error/5 border border-error/20 rounded-lg p-4">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="text-error font-medium">Delete Pathway</h3>
            <p class="text-xs text-error/70 mt-1">This action cannot be undone.</p>
          </div>
          <button
            type="button"
            class="btn btn-error btn-sm btn-active text-white"
            phx-click="delete_pathway"
            phx-value-id={@editing_pathway.id}
            data-confirm="Are you sure you want to delete this pathway? This action cannot be undone."
          >
            Delete Pathway
          </button>
        </div>
      </div>
    </div>
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
      class="max-w-3xl"
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
        <button type="submit" class="btn btn-primary btn-active">
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
