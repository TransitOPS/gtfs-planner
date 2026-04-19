defmodule GtfsPlannerWeb.Gtfs.StationDiagramComponents do
  @moduledoc """
  Function components for the station diagram editor.
  Extracted from StationDiagramLive to improve modularity and readability.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents

  alias GtfsPlanner.Gtfs.Coordinates
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Pathway
  alias LiveSelect.Component
  alias Phoenix.LiveView.JS

  @stop_label_font_size 0.72
  @stop_label_stroke_width 0.17
  @stop_label_line_height 0.84
  @stop_label_char_width 0.42
  @stop_label_box_padding_x 0.40
  @stop_label_box_padding_y 0.12
  @stop_label_box_stroke 0.08
  @stop_label_max_line_chars 18
  @stop_label_max_lines 3

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
          id="diagram-upload-form-toolbar"
          phx-change="upload_diagram"
        >
          <label class="btn btn-sm btn-ghost cursor-pointer">
            Upload Diagram
            <.live_file_input upload={@uploads.diagram} id="toolbar-diagram-upload" class="hidden" />
          </label>
        </form>
        <span :for={error <- upload_errors(@uploads.diagram)} class="text-error text-sm">
          {diagram_upload_error_to_string(error)}
        </span>
        <%= for entry <- @uploads.diagram.entries do %>
          <span :for={error <- upload_errors(@uploads.diagram, entry)} class="text-error text-sm">
            {diagram_upload_error_to_string(error)}
          </span>
        <% end %>
        <span :if={@diagram_error} class="text-error text-sm">{@diagram_error}</span>
      </div>

      <.mode_toggle mode={@mode} />
    </div>
    """
  end

  defp diagram_upload_error_to_string(:too_large), do: "File is too large (max 10 MB)"

  defp diagram_upload_error_to_string(:not_accepted),
    do: "File type not accepted (PNG, JPG, JPEG, SVG only)"

  defp diagram_upload_error_to_string(:too_many_files),
    do: "Only one file can be uploaded at a time"

  defp diagram_upload_error_to_string(:external_client_failure), do: "Upload failed"
  defp diagram_upload_error_to_string({:error, reason}), do: reason
  defp diagram_upload_error_to_string(error) when is_binary(error), do: error
  defp diagram_upload_error_to_string(_), do: "Upload error"

  attr :mode, :atom, required: true
  attr :has_diagram, :boolean, default: true

  defp mode_toggle(assigns) do
    ~H"""
    <div class="join">
      <button
        type="button"
        class={[
          "btn join-item",
          @mode == :view && "bg-blue-600 text-white hover:bg-blue-700",
          @mode != :view && "bg-white text-blue-600 hover:bg-blue-50 border-blue-300"
        ]}
        phx-click="switch_mode"
        phx-value-mode="view"
      >
        View
      </button>
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
  attr :measurement_enabled, :boolean, default: false
  attr :ruler_point_a, :any, default: nil
  attr :ruler_point_b, :any, default: nil
  attr :has_scale, :boolean, default: false
  attr :scale_status, :any, default: nil
  attr :levels, :list, default: []
  attr :active_level, :any, default: nil

  def diagram_action_strip(assigns) do
    ~H"""
    <%= if @levels != [] do %>
      <div
        id="diagram-action-strip"
        class="sticky top-0 z-10 bg-blue-50 border-b border-blue-200"
      >
        <div class="flex items-center justify-between px-4 py-3">
          <div class="flex min-w-0 flex-1 items-center gap-2">
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
                <% @mode == :view -> %>
                  <span class="text-sm text-blue-700 font-medium">
                    {view_mode_instruction(@measurement_enabled, @ruler_point_a, @ruler_point_b)}
                  </span>
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
          <div class="ml-auto flex items-center gap-2">
            <%= if @mode == :view and @has_diagram do %>
              <form id="stop-search-form" phx-submit="search_stop" class="flex items-center">
                <input
                  type="text"
                  name="stop_id_query"
                  placeholder="Find stop_id"
                  aria-label="Search by stop ID"
                  class="input input-sm input-bordered bg-white w-40"
                  autocomplete="off"
                />
              </form>
              <%= if @measurement_enabled do %>
                <button
                  type="button"
                  class="btn btn-sm bg-orange-500 text-white hover:bg-orange-600"
                  phx-click="toggle_measurement"
                >
                  Cancel Set Scale
                </button>
              <% else %>
                <%= if @has_scale do %>
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost text-blue-700 hover:bg-blue-100"
                    phx-click="clear_calibration"
                  >
                    Clear Scale
                  </button>
                <% else %>
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost text-blue-700 hover:bg-blue-100"
                    phx-click="toggle_measurement"
                  >
                    Set Scale
                  </button>
                <% end %>
              <% end %>
            <% end %>
            <.mode_toggle mode={@mode} has_diagram={@has_diagram} />
          </div>
        </div>
        <%= if @scale_status do %>
          <div
            id="scale-status"
            role="status"
            aria-live="polite"
            class="flex items-center gap-2 px-4 pb-2 text-sm text-blue-800"
          >
            <span>{@scale_status}</span>
            <button
              type="button"
              class="btn btn-ghost btn-sm text-blue-700 hover:text-blue-900 hover:bg-blue-100"
              phx-click="dismiss_scale_status"
              aria-label="Dismiss status"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
        <% end %>
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
  attr :cross_level_badges_by_stop, :map, default: %{}
  attr :diagram_error, :string, default: nil
  attr :organization_id, :string, required: true
  attr :ruler_point_a, :any, default: nil
  attr :ruler_point_b, :any, default: nil
  attr :scale_point_a, :any, default: nil
  attr :scale_point_b, :any, default: nil
  attr :measurement_enabled, :boolean, default: false

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
            class={[
              "w-full block",
              if(@mode == :view, do: "cursor-default", else: "cursor-crosshair")
            ]}
          >
            <image
              href={@image_href}
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
            selected_stop_id={@selected_stop_id}
            mode={@mode}
            cross_level_badges_by_stop={@cross_level_badges_by_stop}
            ruler_point_a={@ruler_point_a}
            ruler_point_b={@ruler_point_b}
            scale_point_a={@scale_point_a}
            scale_point_b={@scale_point_b}
            measurement_enabled={@measurement_enabled}
          />
          <div
            id="diagram-edit-tooltip"
            class="diagram-edit-tooltip is-hidden"
            role="tooltip"
            aria-hidden="true"
          >
          </div>
          <.diagram_hints_and_legend has_scale={@scale_point_a != nil and @scale_point_b != nil} />
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
    case active_stop_level do
      %{diagram_filename: filename} when is_binary(filename) ->
        station_dir = PathSafety.stop_storage_dir(station.stop_id)
        token = URI.encode_www_form(filename)
        encoded_filename = URI.encode(filename)

        if is_binary(station_dir) do
          "/uploads/diagrams/#{organization_id}/#{station_dir}/#{encoded_filename}?v=#{token}"
        else
          nil
        end

      _ ->
        nil
    end
  end

  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :pending_xy, :any
  attr :selected_stop_id, :any
  attr :mode, :atom, required: true
  attr :cross_level_badges_by_stop, :map, default: %{}
  attr :ruler_point_a, :any, default: nil
  attr :ruler_point_b, :any, default: nil
  attr :scale_point_a, :any, default: nil
  attr :scale_point_b, :any, default: nil
  attr :measurement_enabled, :boolean, default: false

  defp diagram_overlay(assigns) do
    ~H"""
    <svg
      id="diagram-overlay"
      data-mode={@mode}
      data-measurement-enabled={if @measurement_enabled, do: "true", else: "false"}
      class="absolute inset-0 w-full h-full pointer-events-none"
      viewBox="0 0 100 100"
      preserveAspectRatio="xMidYMid meet"
    >
      <defs>
        <marker
          id="pathway-arrow"
          viewBox="0 0 6 6"
          refX="6"
          refY="3"
          markerWidth="1.5"
          markerHeight="1.5"
          orient="auto-start-reverse"
          markerUnits="userSpaceOnUse"
        >
          <path
            d="M 0 0 L 6 3 L 0 6 z"
            fill="#FF00FF"
            stroke="#FF00FF"
            stroke-width="0.35"
            stroke-linejoin="round"
          />
        </marker>
      </defs>

      <.pathways_layer streams={@streams} mode={@mode} />
      <.ruler_line
        :if={@measurement_enabled and @ruler_point_a}
        point_a={@ruler_point_a}
        point_b={@ruler_point_b}
        style={:draft}
      />
      <.stops_layer
        streams={@streams}
        active_point_id={@active_point_id}
        mode={@mode}
        measurement_enabled={@measurement_enabled}
        cross_level_badges_by_stop={@cross_level_badges_by_stop}
      />
      <.ruler_line
        :if={(@mode == :view and @scale_point_a) && @scale_point_b}
        point_a={@scale_point_a}
        point_b={@scale_point_b}
        style={:saved}
      />
      <.pending_marker
        :if={@pending_xy && @mode == :add && @selected_stop_id == nil}
        pending_xy={@pending_xy}
      />
    </svg>
    """
  end

  attr :streams, :any, required: true
  attr :mode, :atom, required: true

  defp pathways_layer(assigns) do
    ~H"""
    <g id="pathways-svg" phx-update="stream">
      <%= for {dom_id, pathway} <- @streams.pathways do %>
        <%= if pathway.from_stop.diagram_coordinate && pathway.to_stop.diagram_coordinate do %>
          <.pathway_element id={dom_id} pathway={pathway} mode={@mode} />
        <% end %>
      <% end %>
    </g>
    """
  end

  attr :id, :string, required: true
  attr :pathway, :any, required: true
  attr :mode, :atom, required: true

  defp pathway_element(assigns) do
    from_coordinate = assigns.pathway.from_stop.diagram_coordinate
    to_coordinate = assigns.pathway.to_stop.diagram_coordinate

    x1 = from_coordinate["x"]
    y1 = from_coordinate["y"]
    x2 = to_coordinate["x"]
    y2 = to_coordinate["y"]
    {line_x1, line_y1, line_x2, line_y2} = parallel_offset(x1, y1, x2, y2, 0.0)

    one_way? = assigns.pathway.is_bidirectional != true

    forward_label_text =
      Map.get(assigns.pathway, :display_signposted_as, assigns.pathway.signposted_as)

    reverse_label_text =
      Map.get(
        assigns.pathway,
        :display_reversed_signposted_as,
        assigns.pathway.reversed_signposted_as
      )

    has_forward_label? = present_text?(forward_label_text)

    has_reverse_label? =
      assigns.pathway.is_bidirectional == true and present_text?(reverse_label_text)

    assigns =
      assigns
      |> assign(:x1, line_x1)
      |> assign(:y1, line_y1)
      |> assign(:x2, line_x2)
      |> assign(:y2, line_y2)
      |> assign(:one_way?, one_way?)
      |> assign(:stroke_mult, if(Map.get(assigns.pathway, :is_paired), do: 1.8, else: 1.0))
      |> assign(:opacity, "1")
      |> assign(:forward_label_text, forward_label_text)
      |> assign(:reverse_label_text, reverse_label_text)
      |> assign(:has_forward_label?, has_forward_label?)
      |> assign(:has_reverse_label?, has_reverse_label?)
      |> assign(:editable?, assigns.mode == :view)

    ~H"""
    <g
      id={@id}
      opacity={@opacity}
      class="group cursor-pointer pointer-events-auto"
      data-from-stop-id={@pathway.from_stop.id}
      data-to-stop-id={@pathway.to_stop.id}
      data-editable={if @editable?, do: "pathway"}
      data-tooltip={if @editable?, do: "Click to edit pathway"}
      data-tooltip-color={if @editable?, do: "#FF00FF"}
      tabindex={if @editable?, do: "0"}
      aria-label={if @editable?, do: pathway_aria_label(@pathway)}
      phx-click={if @editable?, do: "edit_pathway"}
      phx-value-id={if @editable?, do: @pathway.id}
    >
      <line
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        stroke="transparent"
        stroke-width="2"
        data-pathway-hit="true"
        data-base-stroke="2"
      />
      <line
        :if={@editable?}
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        stroke="transparent"
        stroke-width="0.8"
        data-pathway-tooltip-hit="true"
        data-tooltip-trigger="true"
        data-base-stroke="0.8"
      />

      <%= case @pathway.pathway_mode do %>
        <% 1 -> %>
          <.pathway_walkway
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 2 -> %>
          <.pathway_stairs
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 3 -> %>
          <.pathway_moving_sidewalk
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 4 -> %>
          <.pathway_escalator
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 5 -> %>
          <.pathway_elevator
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 6 -> %>
          <.pathway_fare_gate
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% 7 -> %>
          <.pathway_exit_gate
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
        <% _ -> %>
          <.pathway_walkway
            x1={@x1}
            y1={@y1}
            x2={@x2}
            y2={@y2}
            mode={@mode}
            one_way?={@one_way?}
            stroke_mult={@stroke_mult}
          />
      <% end %>

      <.pathway_label
        :if={@has_forward_label?}
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        text={@forward_label_text}
        side={:forward}
      />
      <.pathway_label
        :if={@has_reverse_label?}
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        text={@reverse_label_text}
        side={:reverse}
      />
    </g>
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_walkway(assigns) do
    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-line="true"
      data-pathway-end-trim="1.1"
      data-base-stroke={0.30 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_stairs(assigns) do
    assigns =
      assign(
        assigns,
        :ticks,
        center_ticks(assigns.x1, assigns.y1, assigns.x2, assigns.y2, 1, 0.5, 0.6)
      )

    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-line="true"
      data-pathway-end-trim="1.1"
      data-base-stroke={0.30 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      :for={tick <- @ticks}
      x1={tick.x1}
      y1={tick.y1}
      x2={tick.x2}
      y2={tick.y2}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="round"
      data-pathway-center-tick="true"
      data-base-stroke={0.26 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_moving_sidewalk(assigns) do
    assigns =
      assign(
        assigns,
        :cross_segments,
        center_cross(assigns.x1, assigns.y1, assigns.x2, assigns.y2, 0.6)
      )

    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-line="true"
      data-pathway-end-trim="1.1"
      data-base-stroke={0.30 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      :for={segment <- @cross_segments}
      x1={segment.x1}
      y1={segment.y1}
      x2={segment.x2}
      y2={segment.y2}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="round"
      data-pathway-center-cross="true"
      data-base-stroke={0.26 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_escalator(assigns) do
    assigns =
      assign(
        assigns,
        :ticks,
        center_ticks(assigns.x1, assigns.y1, assigns.x2, assigns.y2, 3, 0.5, 0.6)
      )

    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-line="true"
      data-pathway-end-trim="1.1"
      data-base-stroke={0.30 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      :for={tick <- @ticks}
      x1={tick.x1}
      y1={tick.y1}
      x2={tick.x2}
      y2={tick.y2}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="round"
      data-pathway-center-bar="true"
      data-base-stroke={0.26 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_elevator(assigns) do
    {mid_x, mid_y} = pathway_midpoint(assigns.x1, assigns.y1, assigns.x2, assigns.y2)
    length = pathway_length(assigns.x1, assigns.y1, assigns.x2, assigns.y2)

    {unit_x, unit_y} =
      if length > 0.0 do
        {(assigns.x2 - assigns.x1) / length, (assigns.y2 - assigns.y1) / length}
      else
        {1.0, 0.0}
      end

    half_size = 1.0

    connector_to_x = mid_x - unit_x * half_size
    connector_to_y = mid_y - unit_y * half_size
    connector_from_x = mid_x + unit_x * half_size
    connector_from_y = mid_y + unit_y * half_size

    assigns =
      assigns
      |> assign(:mid_x, mid_x)
      |> assign(:mid_y, mid_y)
      |> assign(:connector_to_x, connector_to_x)
      |> assign(:connector_to_y, connector_to_y)
      |> assign(:connector_from_x, connector_from_x)
      |> assign(:connector_from_y, connector_from_y)

    ~H"""
    <line
      x1={@x1}
      y1={@y1}
      x2={@connector_to_x}
      y2={@connector_to_y}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      data-pathway-connector="true"
      data-pathway-end-trim-start="1.1"
      data-base-stroke={0.26 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    <line
      x1={@connector_from_x}
      y1={@connector_from_y}
      x2={@x2}
      y2={@y2}
      stroke="#FF00FF"
      stroke-width="0.26"
      stroke-linecap="butt"
      marker-end="url(#pathway-arrow)"
      data-pathway-connector="true"
      data-pathway-end-trim-end="1.1"
      data-base-stroke={0.26 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    <rect
      x={@mid_x - 0.5}
      y={@mid_y - 0.5}
      width="1"
      height="1"
      fill="#FFFFFF"
      stroke="#FF00FF"
      stroke-width="0.30"
      data-pathway-elevator-box="true"
      data-center-x={@mid_x}
      data-center-y={@mid_y}
      data-base-width="1"
      data-base-height="1"
      data-base-stroke={0.30 * @stroke_mult}
      class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
    />
    <text
      x={@mid_x}
      y={@mid_y}
      fill="#FF00FF"
      font-size="0.275"
      text-anchor="middle"
      dominant-baseline="central"
      data-pathway-elevator-text="true"
      data-center-x={@mid_x}
      data-center-y={@mid_y}
      data-base-font-size="0.275"
      class="pointer-events-none select-none transition-colors group-hover:fill-[#FF4500]"
    >
      ↕
    </text>
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_fare_gate(assigns) do
    {rail_a_x1, rail_a_y1, rail_a_x2, rail_a_y2} =
      parallel_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, 0.28)

    {rail_b_x1, rail_b_y1, rail_b_x2, rail_b_y2} =
      parallel_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, -0.28)

    assigns =
      assigns
      |> assign(:rail_a_x1, rail_a_x1)
      |> assign(:rail_a_y1, rail_a_y1)
      |> assign(:rail_a_x2, rail_a_x2)
      |> assign(:rail_a_y2, rail_a_y2)
      |> assign(:rail_b_x1, rail_b_x1)
      |> assign(:rail_b_y1, rail_b_y1)
      |> assign(:rail_b_x2, rail_b_x2)
      |> assign(:rail_b_y2, rail_b_y2)

    ~H"""
    <line
      x1={@rail_a_x1}
      y1={@rail_a_y1}
      x2={@rail_a_x2}
      y2={@rail_a_y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="round"
      data-pathway-rail="true"
      data-rail-base-offset="0.28"
      data-rail-base-stroke={0.30 * @stroke_mult}
      data-base-stroke={0.30 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      x1={@rail_b_x1}
      y1={@rail_b_y1}
      x2={@rail_b_x2}
      y2={@rail_b_y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="round"
      data-pathway-rail="true"
      data-rail-base-offset="-0.28"
      data-rail-base-stroke={0.30 * @stroke_mult}
      data-base-stroke={0.30 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="transparent"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-arrow-guide="true"
      data-pathway-end-trim="1.1"
      data-base-stroke={0.30 * @stroke_mult}
      class="pointer-events-none"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :mode, :atom, required: true
  attr :one_way?, :boolean, required: true
  attr :stroke_mult, :float, default: 1.0

  defp pathway_exit_gate(assigns) do
    {rail_a_x1, rail_a_y1, rail_a_x2, rail_a_y2} =
      parallel_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, 0.16)

    {rail_b_x1, rail_b_y1, rail_b_x2, rail_b_y2} =
      parallel_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, -0.16)

    assigns =
      assigns
      |> assign(:rail_a_x1, rail_a_x1)
      |> assign(:rail_a_y1, rail_a_y1)
      |> assign(:rail_a_x2, rail_a_x2)
      |> assign(:rail_a_y2, rail_a_y2)
      |> assign(:rail_b_x1, rail_b_x1)
      |> assign(:rail_b_y1, rail_b_y1)
      |> assign(:rail_b_x2, rail_b_x2)
      |> assign(:rail_b_y2, rail_b_y2)

    ~H"""
    <line
      x1={@rail_a_x1}
      y1={@rail_a_y1}
      x2={@rail_a_x2}
      y2={@rail_a_y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="round"
      data-pathway-rail="true"
      data-rail-base-offset="0.16"
      data-rail-base-stroke={0.30 * @stroke_mult}
      data-base-stroke={0.30 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      x1={@rail_b_x1}
      y1={@rail_b_y1}
      x2={@rail_b_x2}
      y2={@rail_b_y2}
      stroke="#FF00FF"
      stroke-width="0.30"
      stroke-linecap="round"
      data-pathway-rail="true"
      data-rail-base-offset="-0.16"
      data-rail-base-stroke={0.30 * @stroke_mult}
      data-base-stroke={0.30 * @stroke_mult}
      class={
        if(@mode == :add,
          do: "",
          else: "pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
        )
      }
    />
    <line
      x1={@x1}
      y1={@y1}
      x2={@x2}
      y2={@y2}
      stroke="transparent"
      stroke-width="0.30"
      stroke-linecap="butt"
      marker-start={if @one_way?, do: nil, else: "url(#pathway-arrow)"}
      marker-end="url(#pathway-arrow)"
      data-pathway-arrow-guide="true"
      data-pathway-end-trim="1.1"
      data-base-stroke={0.30 * @stroke_mult}
      class="pointer-events-none"
    />
    """
  end

  attr :x1, :float, required: true
  attr :y1, :float, required: true
  attr :x2, :float, required: true
  attr :y2, :float, required: true
  attr :text, :string, required: true
  attr :side, :atom, required: true

  defp pathway_label(assigns) do
    {mid_x, mid_y} = pathway_midpoint(assigns.x1, assigns.y1, assigns.x2, assigns.y2)

    {offset_x, offset_y} =
      label_offset(assigns.x1, assigns.y1, assigns.x2, assigns.y2, assigns.side)

    {rotation, flipped?} =
      pathway_label_angle_metadata(assigns.x1, assigns.y1, assigns.x2, assigns.y2)

    display_text = direction_indicator(assigns.text, assigns.side, flipped?)

    assigns =
      assigns
      |> assign(:mid_x, mid_x)
      |> assign(:mid_y, mid_y)
      |> assign(:offset_x, offset_x)
      |> assign(:offset_y, offset_y)
      |> assign(:x, mid_x + offset_x)
      |> assign(:y, mid_y + offset_y)
      |> assign(:rotation, rotation)
      |> assign(:display_text, display_text)

    ~H"""
    <text
      x={@x}
      y={@y}
      transform={"rotate(#{@rotation}, #{@x}, #{@y})"}
      fill="#FF00FF"
      stroke="#FFFFFF"
      stroke-width="0.2"
      paint-order="stroke fill"
      font-size="0.78"
      text-anchor="middle"
      dominant-baseline="central"
      data-pathway-label="true"
      data-midpoint-x={@mid_x}
      data-midpoint-y={@mid_y}
      data-offset-x={@offset_x}
      data-offset-y={@offset_y}
      data-rotation={@rotation}
      data-base-font-size="0.78"
      data-base-stroke="0.2"
      class="pointer-events-none select-none transition-colors group-hover:fill-[#FF4500]"
    >
      {@display_text}
    </text>
    """
  end

  attr :streams, :any, required: true
  attr :active_point_id, :any
  attr :mode, :atom, required: true
  attr :measurement_enabled, :boolean, default: false
  attr :cross_level_badges_by_stop, :map, default: %{}

  defp stops_layer(assigns) do
    assigns =
      assigns
      |> assign(:stop_label_font_size, @stop_label_font_size)
      |> assign(:stop_label_stroke_width, @stop_label_stroke_width)
      |> assign(:stop_label_line_height, @stop_label_line_height)
      |> assign(:stop_label_box_padding_x, @stop_label_box_padding_x)
      |> assign(:stop_label_box_padding_y, @stop_label_box_padding_y)
      |> assign(:stop_label_box_stroke, @stop_label_box_stroke)

    ~H"""
    <g id="stops-svg" phx-update="stream">
      <%= for {dom_id, stop} <- @streams.child_stops do %>
        <%= if stop.diagram_coordinate do %>
          <% cx = stop.diagram_coordinate["x"] %>
          <% cy = stop.diagram_coordinate["y"] %>
          <% active_fill = if(@active_point_id == stop.id, do: "#FF4500", else: "#0080FF") %>
          <% label = stop_label_text(stop) %>
          <% label_layout = stop_label_layout(label) %>
          <% label_offset_x = stop_label_x_offset(stop.location_type) %>
          <% label_offset_y = stop_label_y_offset(stop.location_type) %>
          <% label_x = cx + label_offset_x %>
          <% label_y = cy + label_offset_y %>
          <% stop_aria_label = stop_aria_label(stop) %>
          <g
            id={dom_id}
            class="group pointer-events-auto"
            data-stop-id={stop.id}
            data-stop-center-x={cx}
            data-stop-center-y={cy}
            data-editable="stop"
            data-tooltip={stop_tooltip_text(@mode, @measurement_enabled)}
            data-tooltip-color={active_fill}
            tabindex="0"
            aria-label={stop_aria_label}
          >
            <rect
              x={cx - 1.75}
              y={cy - 1.75}
              width="3.5"
              height="3.5"
              fill="transparent"
              stroke="transparent"
              stroke-width="0"
              data-stop-hit-target="true"
              data-location-type={stop.location_type}
              data-center-x={cx}
              data-center-y={cy}
              class="cursor-pointer"
              phx-click="stop_clicked"
              phx-value-id={stop.id}
            />
            <rect
              x={cx - 0.9}
              y={cy - 0.9}
              width="1.8"
              height="1.8"
              fill="transparent"
              stroke="transparent"
              stroke-width="0"
              data-stop-tooltip-hit="true"
              data-tooltip-trigger="true"
              data-center-x={cx}
              data-center-y={cy}
              class="cursor-pointer"
              phx-click="stop_clicked"
              phx-value-id={stop.id}
            />
            <%= case stop.location_type do %>
              <% 0 -> %>
                <rect
                  x={cx - 0.5}
                  y={cy - 1.6}
                  width="1.0"
                  height="2.0"
                  rx="0.2"
                  fill={active_fill}
                  stroke="#FFFFFF"
                  stroke-width="0.12"
                  paint-order="stroke fill"
                  class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
                  data-stop-marker="true"
                  data-location-type={stop.location_type}
                  data-center-x={cx}
                  data-center-y={cy}
                />
              <% 2 -> %>
                <rect
                  x={cx - 0.5}
                  y={cy - 1.6}
                  width="1.0"
                  height="2.0"
                  rx="0.2"
                  fill="#FFFFFF"
                  stroke={active_fill}
                  stroke-width="0.16"
                  class="pointer-events-none transition-colors group-hover:stroke-[#FF4500]"
                  data-stop-marker="true"
                  data-location-type={stop.location_type}
                  data-center-x={cx}
                  data-center-y={cy}
                />
              <% 4 -> %>
                <rect
                  x={cx - 0.6}
                  y={cy - 0.96}
                  width="1.2"
                  height="1.2"
                  rx="0.2"
                  fill={active_fill}
                  stroke="#FFFFFF"
                  stroke-width="0.12"
                  paint-order="stroke fill"
                  class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
                  data-stop-marker="true"
                  data-location-type={stop.location_type}
                  data-center-x={cx}
                  data-center-y={cy}
                />
              <% _ -> %>
                <circle
                  cx={cx}
                  cy={cy}
                  r="0.6"
                  fill={active_fill}
                  stroke="#FFFFFF"
                  stroke-width="0.12"
                  paint-order="stroke fill"
                  class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
                  data-stop-marker="true"
                  data-location-type={stop.location_type}
                  data-center-x={cx}
                  data-center-y={cy}
                />
            <% end %>
            <rect
              :if={label_layout}
              x={label_x - @stop_label_box_padding_x}
              y={label_y - @stop_label_box_padding_y}
              width={label_layout.box_width}
              height={label_layout.box_height}
              rx="0.16"
              fill="transparent"
              fill-opacity="0"
              stroke="transparent"
              stroke-width={@stop_label_box_stroke}
              paint-order="stroke fill"
              data-stop-label-box="true"
              data-center-x={cx}
              data-center-y={cy}
              data-label-offset-x={label_offset_x}
              data-label-offset-y={label_offset_y}
              data-base-width={label_layout.box_width}
              data-base-height={label_layout.box_height}
              data-base-padding-x={@stop_label_box_padding_x}
              data-base-padding-y={@stop_label_box_padding_y}
              data-base-stroke={@stop_label_box_stroke}
              data-label-line-count={label_layout.line_count}
              class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
            />
            <text
              :if={label_layout}
              x={label_x}
              y={label_y}
              font-family="Inter, sans-serif"
              font-weight="500"
              font-size={@stop_label_font_size}
              letter-spacing="0.01em"
              fill={active_fill}
              stroke="#FFFFFF"
              stroke-width={@stop_label_stroke_width}
              paint-order="stroke fill"
              text-anchor="start"
              dominant-baseline="hanging"
              data-stop-label="true"
              data-center-x={cx}
              data-center-y={cy}
              data-label-offset-x={label_offset_x}
              data-label-offset-y={label_offset_y}
              data-base-font-size={@stop_label_font_size}
              data-base-stroke={@stop_label_stroke_width}
              data-base-line-height={@stop_label_line_height}
              data-label-line-count={label_layout.line_count}
              data-label-truncated={if label_layout.truncated?, do: "true", else: "false"}
              class="pointer-events-none transition-colors group-hover:fill-[#FF4500]"
            >
              <%= for {line, index} <- Enum.with_index(label_layout.lines) do %>
                <tspan x={label_x} dy={if(index == 0, do: "0", else: @stop_label_line_height)}>
                  {line}
                </tspan>
              <% end %>
            </text>
            <.cross_level_badges
              stop={stop}
              mode={@mode}
              cross_level_badges_by_stop={@cross_level_badges_by_stop}
            />
          </g>
        <% end %>
      <% end %>
    </g>
    """
  end

  defp stop_label_text(stop) do
    case stop.location_type do
      0 -> stop_name_with_platform(stop)
      4 -> stop_name_with_platform(stop)
      _ -> present_text(stop.stop_name) |> maybe_upcase()
    end
  end

  defp stop_label_layout(nil), do: nil

  defp stop_label_layout(label_text) do
    {lines, truncated?} =
      wrap_stop_label_lines(label_text, @stop_label_max_line_chars, @stop_label_max_lines)

    line_count = length(lines)
    max_line_chars = lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    text_width = max_line_chars * @stop_label_char_width
    text_height = line_count * @stop_label_line_height

    %{
      lines: lines,
      truncated?: truncated?,
      line_count: line_count,
      box_width: text_width + @stop_label_box_padding_x * 2,
      box_height: text_height + @stop_label_box_padding_y * 2
    }
  end

  defp wrap_stop_label_lines(label_text, max_line_chars, max_lines)
       when is_binary(label_text) and max_line_chars > 0 and max_lines > 0 do
    tokens =
      label_text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.flat_map(&split_long_label_token(&1, max_line_chars))

    {lines, current_line} =
      Enum.reduce(tokens, {[], nil}, fn token, {lines, current_line} ->
        candidate =
          case current_line do
            nil -> token
            "" -> token
            _ -> "#{current_line} #{token}"
          end

        if String.length(candidate) <= max_line_chars do
          {lines, candidate}
        else
          {lines ++ [current_line], token}
        end
      end)

    lines =
      case current_line do
        nil -> lines
        "" -> lines
        _ -> lines ++ [current_line]
      end

    if length(lines) <= max_lines do
      {lines, false}
    else
      kept_lines = Enum.take(lines, max_lines)
      index = max_lines - 1
      final_line = kept_lines |> Enum.at(index) |> truncate_label_line(max_line_chars)
      {List.replace_at(kept_lines, index, final_line), true}
    end
  end

  defp split_long_label_token(token, max_line_chars)
       when is_binary(token) and max_line_chars > 0 do
    if String.length(token) <= max_line_chars do
      [token]
    else
      token
      |> String.graphemes()
      |> Enum.chunk_every(max_line_chars)
      |> Enum.map(&Enum.join/1)
    end
  end

  defp truncate_label_line(nil, _max_line_chars), do: "..."

  defp truncate_label_line(line, max_line_chars)
       when is_binary(line) and max_line_chars > 0 do
    room = max(max_line_chars - 3, 0)
    String.slice(line, 0, room) <> "..."
  end

  defp view_mode_instruction(true, nil, _point_b), do: "Click first ruler point"
  defp view_mode_instruction(true, _point_a, nil), do: "Click second ruler point"
  defp view_mode_instruction(true, _point_a, _point_b), do: "Enter real-world distance and save"
  defp view_mode_instruction(false, _point_a, _point_b), do: "Click a stop to view or edit"

  defp stop_name_with_platform(stop) do
    name = present_text(stop.stop_name)
    platform = present_text(stop.platform_code)

    case {name, platform} do
      {nil, nil} -> nil
      {name, nil} -> name
      {nil, platform} -> platform
      {name, platform} -> "#{name} · #{platform}"
    end
    |> maybe_upcase()
  end

  defp present_text(value) when is_binary(value) do
    text = String.trim(value)
    if text == "", do: nil, else: text
  end

  defp present_text(_), do: nil

  defp maybe_upcase(nil), do: nil
  defp maybe_upcase(text), do: String.upcase(text)

  defp stop_aria_label(stop) do
    stop_id = present_text(stop.stop_id) || "Unknown"

    case present_text(stop.stop_name) do
      nil -> "Stop #{stop_id}"
      stop_name -> "Stop #{stop_name} (#{stop_id})"
    end
  end

  defp stop_label_x_offset(_location_type), do: 0.15

  defp stop_label_y_offset(4), do: 0.72
  defp stop_label_y_offset(_location_type), do: 0.9

  defp stop_tooltip_text(:view, false), do: "Click to edit, hold to move"
  defp stop_tooltip_text(:view, true), do: "Editing disabled while measuring"
  defp stop_tooltip_text(:connect, _measurement_enabled), do: "Select stop to create pathway"
  defp stop_tooltip_text(_mode, _measurement_enabled), do: "Click to edit stop"

  defp pathway_aria_label(pathway) do
    mode_label = Pathway.mode_label(pathway.pathway_mode)
    from_label = pathway_stop_display(pathway.from_stop)
    to_label = pathway_stop_display(pathway.to_stop)

    "#{mode_label} pathway from #{from_label} to #{to_label}"
  end

  defp cross_level_badge_tooltip(mode_label), do: "#{mode_label} pathway. Click to edit pathway"
  defp cross_level_badge_aria_label(mode_label), do: "Cross-level #{mode_label} pathway"

  attr :stop, :any, required: true
  attr :mode, :atom, required: true
  attr :cross_level_badges_by_stop, :map, required: true

  defp cross_level_badges(assigns) do
    badges =
      assigns.cross_level_badges_by_stop
      |> Map.get(assigns.stop.id, [])
      |> Enum.with_index()

    assigns =
      assigns
      |> assign(:badges, badges)
      |> assign(:editable?, assigns.mode == :view)

    ~H"""
    <%= if @stop.diagram_coordinate do %>
      <% cx = @stop.diagram_coordinate["x"] %>
      <% cy = @stop.diagram_coordinate["y"] %>
      <%= for {badge, index} <- @badges do %>
        <% badge_offset_x = 1.35 + index * 1.25 %>
        <% mode_label = Pathway.mode_label(badge.pathway_mode) %>
        <g
          id={"cross-level-badge-#{badge.pathway_id}"}
          class="group pointer-events-auto cursor-pointer"
          data-cross-level-pathway-badge="true"
          data-pathway-id={badge.pathway_id}
          data-tooltip={if @editable?, do: cross_level_badge_tooltip(mode_label)}
          data-tooltip-color={if @editable?, do: "#FF00FF"}
          tabindex={if @editable?, do: "0"}
          aria-label={if @editable?, do: cross_level_badge_aria_label(mode_label)}
          phx-click={if @editable?, do: "edit_pathway"}
          phx-value-id={if @editable?, do: badge.pathway_id}
        >
          <rect
            x={cx + badge_offset_x - 0.45}
            y={cy - 0.45}
            width="0.9"
            height="0.9"
            fill="transparent"
            stroke="transparent"
            stroke-width="0"
            data-cross-level-badge-hit="true"
            data-base-size="0.9"
            data-tooltip-trigger="true"
            data-center-x={cx}
            data-center-y={cy}
            data-badge-offset-x={badge_offset_x}
          />
          <title>{mode_label}</title>
          <%= if badge.pathway_mode in [2, 4] do %>
            <.cross_level_stairs_icon
              center_x={cx}
              center_y={cy}
              offset_x={badge_offset_x}
              fill="#FF00FF"
              editable?={@editable?}
            />
          <% else %>
            <.cross_level_elevator_icon
              center_x={cx}
              center_y={cy}
              offset_x={badge_offset_x}
              fill="#FF00FF"
              editable?={@editable?}
            />
          <% end %>
        </g>
      <% end %>
    <% end %>
    """
  end

  attr :center_x, :float, required: true
  attr :center_y, :float, required: true
  attr :offset_x, :float, required: true
  attr :fill, :string, required: true
  attr :editable?, :boolean, required: true

  defp cross_level_stairs_icon(assigns) do
    s = 0.3
    size = 3 * s
    x0 = assigns.center_x + assigns.offset_x - size / 2
    y0 = assigns.center_y - size / 2

    d =
      "M #{x0} #{y0 + size}" <>
        " L #{x0} #{y0 + 2 * s}" <>
        " L #{x0 + s} #{y0 + 2 * s}" <>
        " L #{x0 + s} #{y0 + s}" <>
        " L #{x0 + 2 * s} #{y0 + s}" <>
        " L #{x0 + 2 * s} #{y0}" <>
        " L #{x0 + 3 * s} #{y0}" <>
        " L #{x0 + 3 * s} #{y0 + size}" <>
        " Z"

    assigns = assign(assigns, :d, d)

    ~H"""
    <path
      d={@d}
      fill={@fill}
      data-tooltip-trigger={if @editable?, do: "true"}
      data-cross-level-badge-stairs="true"
      data-center-x={@center_x}
      data-center-y={@center_y}
      data-badge-offset-x={@offset_x}
    />
    """
  end

  attr :center_x, :float, required: true
  attr :center_y, :float, required: true
  attr :offset_x, :float, required: true
  attr :fill, :string, required: true
  attr :editable?, :boolean, required: true

  defp cross_level_elevator_icon(assigns) do
    cx = assigns.center_x + assigns.offset_x
    cy = assigns.center_y

    d =
      "M #{cx} #{cy - 0.45}" <>
        " L #{cx + 0.35} #{cy - 0.05}" <>
        " L #{cx - 0.35} #{cy - 0.05}" <>
        " Z" <>
        " M #{cx} #{cy + 0.45}" <>
        " L #{cx + 0.35} #{cy + 0.05}" <>
        " L #{cx - 0.35} #{cy + 0.05}" <>
        " Z"

    assigns = assign(assigns, :d, d)

    ~H"""
    <path
      d={@d}
      fill={@fill}
      data-tooltip-trigger={if @editable?, do: "true"}
      data-cross-level-badge-elevator="true"
      data-center-x={@center_x}
      data-center-y={@center_y}
      data-badge-offset-x={@offset_x}
    />
    """
  end

  attr :pending_xy, :any, required: true

  defp pending_marker(assigns) do
    ~H"""
    <polygon
      points={"#{@pending_xy.x},#{@pending_xy.y - 1} #{@pending_xy.x - 0.75},#{@pending_xy.y + 0.5} #{@pending_xy.x + 0.75},#{@pending_xy.y + 0.5}"}
      data-cx={@pending_xy.x}
      data-cy={@pending_xy.y}
      fill="#f97316"
      stroke="#fff"
      stroke-width="0.15"
    />
    """
  end

  attr :point_a, :any, required: true
  attr :point_b, :any, default: nil
  attr :style, :atom, required: true

  defp ruler_line(assigns) do
    point_a = Coordinates.normalize_point(assigns.point_a)
    point_b = Coordinates.normalize_point(assigns.point_b)

    cond do
      point_a == nil ->
        ~H""

      point_b == nil and assigns.style == :draft ->
        assigns =
          assigns
          |> assign(:ax, point_a.x)
          |> assign(:ay, point_a.y)
          |> assign(:line_color, "#f97316")

        ~H"""
        <g class="pointer-events-none">
          <circle
            cx={@ax}
            cy={@ay}
            r="0.35"
            fill="#ffffff"
            stroke={@line_color}
            stroke-width="0.13"
            data-ruler-endpoint="true"
            data-center-x={@ax}
            data-center-y={@ay}
            data-base-radius="0.35"
            data-base-stroke="0.13"
          />
        </g>
        """

      point_b == nil ->
        ~H""

      true ->
        {mid_x, mid_y} = pathway_midpoint(point_a.x, point_a.y, point_b.x, point_b.y)
        top_node = if point_a.y <= point_b.y, do: point_a, else: point_b
        saved_label? = assigns.style == :saved
        label_anchor_x = if(saved_label?, do: top_node.x, else: mid_x)
        label_anchor_y = if(saved_label?, do: top_node.y, else: mid_y)
        label_offset_x = if(saved_label?, do: 0.5, else: 0.0)
        label_offset_y = if(saved_label?, do: 0.0, else: -0.9)

        assigns =
          assigns
          |> assign(:ax, point_a.x)
          |> assign(:ay, point_a.y)
          |> assign(:bx, point_b.x)
          |> assign(:by, point_b.y)
          |> assign(:mx, mid_x)
          |> assign(:my, mid_y)
          |> assign(:line_color, if(saved_label?, do: "#16a34a", else: "#f97316"))
          |> assign(:label_text, if(saved_label?, do: "SCALE", else: "Measure"))
          |> assign(:saved_label?, saved_label?)
          |> assign(:label_anchor_x, label_anchor_x)
          |> assign(:label_anchor_y, label_anchor_y)
          |> assign(:label_offset_x, label_offset_x)
          |> assign(:label_offset_y, label_offset_y)

        ~H"""
        <g
          class={
            if @style == :saved, do: "cursor-pointer pointer-events-auto", else: "pointer-events-none"
          }
          data-ruler-type={if @style == :saved, do: "saved"}
        >
          <line
            :if={@style == :saved}
            x1={@ax}
            y1={@ay}
            x2={@bx}
            y2={@by}
            stroke="transparent"
            stroke-width="1.5"
            data-ruler-hit-area="true"
          />
          <line
            x1={@ax}
            y1={@ay}
            x2={@bx}
            y2={@by}
            stroke={@line_color}
            stroke-width="0.25"
            data-ruler-line="true"
            data-base-stroke="0.25"
          />
          <circle
            cx={@ax}
            cy={@ay}
            r="0.35"
            fill="#ffffff"
            stroke={@line_color}
            stroke-width="0.13"
            data-ruler-endpoint="true"
            data-center-x={@ax}
            data-center-y={@ay}
            data-base-radius="0.35"
            data-base-stroke="0.13"
          />
          <circle
            cx={@bx}
            cy={@by}
            r="0.35"
            fill="#ffffff"
            stroke={@line_color}
            stroke-width="0.13"
            data-ruler-endpoint="true"
            data-center-x={@bx}
            data-center-y={@by}
            data-base-radius="0.35"
            data-base-stroke="0.13"
          />
          <text
            x={@label_anchor_x + @label_offset_x}
            y={@label_anchor_y + @label_offset_y}
            fill={@line_color}
            stroke="#ffffff"
            stroke-width="0.16"
            paint-order="stroke fill"
            font-size="0.78"
            font-weight="600"
            text-anchor={if @saved_label?, do: "start", else: "middle"}
            dominant-baseline="central"
            data-ruler-label="true"
            data-midpoint-x={@mx}
            data-midpoint-y={@my}
            data-label-anchor-x={if @saved_label?, do: @label_anchor_x}
            data-label-anchor-y={if @saved_label?, do: @label_anchor_y}
            data-label-offset-x={if @saved_label?, do: @label_offset_x}
            data-label-offset-y={@label_offset_y}
            data-base-font-size="0.78"
            data-base-stroke="0.16"
            class="select-none"
          >
            {@label_text}
          </text>
        </g>
        """
    end
  end

  attr :has_scale, :boolean, default: false

  defp diagram_hints_and_legend(assigns) do
    ~H"""
    <div class="absolute bottom-2 left-2 z-10 flex items-center gap-3 bg-black/50 text-white text-xs rounded-lg px-3 py-1.5 backdrop-blur-sm">
      <span>Scroll to pan · Ctrl+Scroll to zoom</span>
      <span
        :if={!@has_scale}
        class="badge badge-xs border bg-amber-100 border-amber-300 text-amber-900"
      >
        No scale
      </span>
      <button
        type="button"
        phx-click={JS.toggle(to: "#diagram-legend-panel")}
        class="btn btn-xs btn-ghost text-white border-white/30 hover:bg-white/20"
      >
        Show Key
      </button>
    </div>
    <div
      id="diagram-legend-panel"
      class="hidden absolute bottom-12 left-2 z-10 bg-white border border-base-300 rounded-lg shadow-lg p-4 max-h-[70vh] overflow-y-auto w-72"
    >
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold text-sm">Key</h3>
        <button
          type="button"
          phx-click={JS.toggle(to: "#diagram-legend-panel")}
          class="btn btn-ghost btn-xs"
          aria-label="Close legend"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>

      <div class="mb-4">
        <h4 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
          Child Stops
        </h4>
        <div class="space-y-1.5">
          <div class="flex items-center gap-2 text-sm">
            <svg width="14" height="22" class="shrink-0">
              <rect x="2" y="2" width="10" height="18" rx="1" fill="#0080FF" />
            </svg>
            <span>Platform</span>
          </div>
          <div class="flex items-center gap-2 text-sm">
            <svg width="14" height="22" class="shrink-0">
              <rect
                x="2"
                y="2"
                width="10"
                height="18"
                rx="1"
                fill="#fff"
                stroke="#0080FF"
                stroke-width="1.5"
              />
            </svg>
            <span>Entrance / Exit</span>
          </div>
          <div class="flex items-center gap-2 text-sm">
            <svg width="14" height="14" class="shrink-0">
              <circle cx="7" cy="7" r="6" fill="#0080FF" />
            </svg>
            <span>Generic Node</span>
          </div>
          <div class="flex items-center gap-2 text-sm">
            <svg width="14" height="14" class="shrink-0">
              <rect x="1" y="1" width="12" height="12" rx="1" fill="#0080FF" />
            </svg>
            <span>Boarding Area</span>
          </div>
          <div class="flex items-center gap-2 text-sm">
            <svg width="16" height="16" class="shrink-0">
              <path d="M 3 14 L 3 10 L 6 10 L 6 6 L 9 6 L 9 2 L 13 2 L 13 14 Z" fill="#FF00FF" />
            </svg>
            <span>Cross-level Stairs</span>
          </div>
          <div class="flex items-center gap-2 text-sm">
            <svg width="16" height="16" class="shrink-0">
              <path d="M 8 2 L 12 7 L 4 7 Z M 8 14 L 12 9 L 4 9 Z" fill="#FF00FF" />
            </svg>
            <span>Cross-level Elevator</span>
          </div>
        </div>
      </div>

      <div>
        <h4 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
          Pathways
        </h4>
        <div class="space-y-1.5">
          <%!-- Mode 1: Walkway — solid line, bidirectional arrows --%>
          <div class="flex items-center gap-2 text-sm">
            <svg width="40" height="10" class="shrink-0">
              <polygon points="3,1 0,5 3,9" fill="#FF00FF" />
              <line x1="3" y1="5" x2="37" y2="5" stroke="#FF00FF" stroke-width="2" />
              <polygon points="37,1 40,5 37,9" fill="#FF00FF" />
            </svg>
            <span>Walkway</span>
          </div>
          <%!-- Mode 2: Stairs — solid line, one center tick, bidirectional arrows --%>
          <div class="flex items-center gap-2 text-sm">
            <svg width="40" height="12" class="shrink-0">
              <polygon points="3,2 0,6 3,10" fill="#FF00FF" />
              <line x1="3" y1="6" x2="37" y2="6" stroke="#FF00FF" stroke-width="2" />
              <line x1="20" y1="1" x2="20" y2="11" stroke="#FF00FF" stroke-width="1.2" />
              <polygon points="37,2 40,6 37,10" fill="#FF00FF" />
            </svg>
            <span>Stairs</span>
          </div>
          <%!-- Mode 3: Moving Sidewalk — solid line, center X, forward arrow --%>
          <div class="flex items-center gap-2 text-sm">
            <svg width="40" height="12" class="shrink-0">
              <line x1="0" y1="6" x2="37" y2="6" stroke="#FF00FF" stroke-width="2" />
              <line x1="16" y1="1" x2="24" y2="11" stroke="#FF00FF" stroke-width="1.2" />
              <line x1="24" y1="1" x2="16" y2="11" stroke="#FF00FF" stroke-width="1.2" />
              <polygon points="37,2 40,6 37,10" fill="#FF00FF" />
            </svg>
            <span>Moving Sidewalk</span>
          </div>
          <%!-- Mode 4: Escalator — solid line, three center bars, forward arrow --%>
          <div class="flex items-center gap-2 text-sm">
            <svg width="40" height="12" class="shrink-0">
              <line x1="0" y1="6" x2="37" y2="6" stroke="#FF00FF" stroke-width="2" />
              <line x1="16" y1="1" x2="16" y2="11" stroke="#FF00FF" stroke-width="1.2" />
              <line x1="20" y1="1" x2="20" y2="11" stroke="#FF00FF" stroke-width="1.2" />
              <line x1="24" y1="1" x2="24" y2="11" stroke="#FF00FF" stroke-width="1.2" />
              <polygon points="37,2 40,6 37,10" fill="#FF00FF" />
            </svg>
            <span>Escalator</span>
          </div>
          <%!-- Mode 5: Elevator — solid line, center box with ↕, bidirectional arrows --%>
          <div class="flex items-center gap-2 text-sm">
            <svg width="40" height="16" class="shrink-0">
              <polygon points="3,4 0,8 3,12" fill="#FF00FF" />
              <line x1="3" y1="8" x2="13" y2="8" stroke="#FF00FF" stroke-width="2" />
              <rect
                x="13"
                y="1"
                width="14"
                height="14"
                rx="2"
                fill="#fff"
                stroke="#FF00FF"
                stroke-width="1.5"
              />
              <text
                x="20"
                y="8"
                text-anchor="middle"
                dominant-baseline="central"
                font-family="Inter, sans-serif"
                font-size="9"
                fill="#FF00FF"
              >
                ↕
              </text>
              <line x1="27" y1="8" x2="37" y2="8" stroke="#FF00FF" stroke-width="2" />
              <polygon points="37,4 40,8 37,12" fill="#FF00FF" />
            </svg>
            <span>Elevator</span>
          </div>
          <%!-- Mode 6: Fare Gate — two parallel rails, forward arrow --%>
          <div class="flex items-center gap-2 text-sm">
            <svg width="40" height="12" class="shrink-0">
              <line x1="0" y1="4" x2="33" y2="4" stroke="#FF00FF" stroke-width="1.5" />
              <line x1="0" y1="8" x2="33" y2="8" stroke="#FF00FF" stroke-width="1.5" />
              <polygon points="35,2 40,6 35,10" fill="#FF00FF" />
            </svg>
            <span>Fare Gate</span>
          </div>
          <%!-- Mode 7: Exit Gate — two parallel rails, forward arrow --%>
          <div class="flex items-center gap-2 text-sm">
            <svg width="40" height="12" class="shrink-0">
              <line x1="0" y1="4" x2="33" y2="4" stroke="#FF00FF" stroke-width="1.5" />
              <line x1="0" y1="8" x2="33" y2="8" stroke="#FF00FF" stroke-width="1.5" />
              <polygon points="35,2 40,6 35,10" fill="#FF00FF" />
            </svg>
            <span>Exit Gate</span>
          </div>
        </div>
      </div>
    </div>
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
  attr :editing_level, :boolean, default: false
  attr :stop_id_mode, :atom, default: :auto
  attr :active_level, :any, default: nil
  attr :reposition_mode, :boolean, default: false
  attr :reposition_search, :string, default: ""
  attr :reposition_stops, :list, default: []
  attr :platform_options, :list, default: []

  def child_stop_drawer(assigns) do
    show_toggle =
      assigns.mode == :add && assigns.pending_xy != nil && assigns.selected_stop_id == nil

    drawer_title =
      cond do
        assigns.reposition_mode && is_nil(assigns.selected_stop_id) ->
          "Re-Position Child Stop"

        assigns.selected_stop_id ->
          "Edit Child Stop"

        true ->
          "Child Stop"
      end

    assigns =
      assigns
      |> assign(:drawer_title, drawer_title)
      |> assign(:show_toggle, show_toggle)

    ~H"""
    <.drawer
      id="child-stop-drawer"
      open={@pending_xy != nil && (@mode == :add || (@mode == :view && @selected_stop_id != nil))}
      on_close="close_drawer"
      title={@drawer_title}
      class="max-w-lg"
    >
      <:header_actions>
        <div :if={@show_toggle} class="join">
          <button
            id="enter-new-stop-mode"
            type="button"
            class={[
              "btn btn-sm join-item shadow-none",
              !@reposition_mode && "bg-emerald-700 text-white border-emerald-700 hover:bg-emerald-800",
              @reposition_mode && "bg-white text-emerald-800 border-emerald-300 hover:bg-emerald-100"
            ]}
            phx-click="exit_reposition_mode"
          >
            New Stop
          </button>
          <button
            id="enter-reposition-mode"
            type="button"
            class={[
              "btn btn-sm join-item shadow-none",
              @reposition_mode && "bg-emerald-700 text-white border-emerald-700 hover:bg-emerald-800",
              !@reposition_mode && "bg-white text-emerald-800 border-emerald-300 hover:bg-emerald-100"
            ]}
            phx-click="enter_reposition_mode"
          >
            Re-Position
          </button>
        </div>
      </:header_actions>

      <.reposition_stop_view
        :if={@pending_xy && @reposition_mode && @selected_stop_id == nil}
        reposition_stops={@reposition_stops}
        reposition_search={@reposition_search}
        active_level={@active_level}
      />

      <.child_stop_form
        :if={@pending_xy && !(@reposition_mode && @selected_stop_id == nil)}
        child_stop_form={@child_stop_form}
        platform_options={@platform_options}
        selected_stop_id={@selected_stop_id}
        pending_xy={@pending_xy}
        all_levels={@all_levels}
        editing_level={@editing_level}
        stop_id_mode={@stop_id_mode}
        active_level={@active_level}
      />
    </.drawer>
    """
  end

  attr :reposition_stops, :list, default: []
  attr :reposition_search, :string, default: ""
  attr :active_level, :any, default: nil

  defp reposition_stop_view(assigns) do
    normalized_search =
      assigns.reposition_search
      |> to_string()
      |> String.trim()
      |> String.downcase()

    filtered_stops =
      Enum.filter(assigns.reposition_stops, fn stop ->
        if normalized_search == "" do
          true
        else
          stop_id = stop.stop_id |> to_string() |> String.downcase()
          stop_name = stop.stop_name |> to_string() |> String.downcase()

          String.contains?(stop_id, normalized_search) or
            String.contains?(stop_name, normalized_search)
        end
      end)

    unpositioned_stops =
      Enum.filter(filtered_stops, fn stop ->
        is_nil(stop.diagram_coordinate) or stop.level_id in [nil, ""]
      end)

    positioned_stops =
      Enum.filter(filtered_stops, fn stop ->
        stop.diagram_coordinate != nil and not is_nil(assigns.active_level) and
          stop.level_id == assigns.active_level.level_id
      end)

    search_form = to_form(%{"query" => assigns.reposition_search}, as: :search)

    assigns =
      assigns
      |> assign(:search_form, search_form)
      |> assign(:unpositioned_stops, unpositioned_stops)
      |> assign(:positioned_stops, positioned_stops)

    ~H"""
    <div class="space-y-6">
      <.form
        for={@search_form}
        id="reposition-search-form"
        phx-change="reposition_search"
        phx-submit="reposition_search"
      >
        <.input
          field={@search_form[:query]}
          id="reposition-search-input"
          type="text"
          label="Search Child Stops"
          placeholder="Search by stop ID or name"
          phx-debounce="200"
        />
      </.form>

      <section class="space-y-2">
        <h3 class="text-sm font-semibold text-base-content/70">
          Unpositioned child stops
        </h3>
        <div class="overflow-x-auto">
          <table id="unpositioned-stops-table" class="table table-sm">
            <thead class="bg-gray-200">
              <tr>
                <th>Stop ID</th>
                <th>Name</th>
                <th>Type</th>
                <th class="text-right">Action</th>
              </tr>
            </thead>
            <tbody>
              <%= for stop <- @unpositioned_stops do %>
                <tr id={"unpositioned-stop-row-#{stop.id}"}>
                  <td>{stop.stop_id}</td>
                  <td>{stop.stop_name || "—"}</td>
                  <td>{Stop.location_type_label(stop.location_type)}</td>
                  <td class="text-right">
                    <button
                      type="button"
                      class="btn btn-primary btn-xs"
                      phx-click="reposition_stop"
                      phx-value-id={stop.id}
                    >
                      Place here
                    </button>
                  </td>
                </tr>
              <% end %>
              <tr :if={@unpositioned_stops == []}>
                <td colspan="4" class="text-sm text-base-content/60">
                  No matching unpositioned stops.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="space-y-2">
        <h3 class="text-sm font-semibold text-base-content/70">
          Positioned stops on this level
        </h3>
        <div class="overflow-x-auto">
          <table id="positioned-stops-table" class="table table-sm">
            <thead class="bg-gray-200">
              <tr>
                <th>Stop ID</th>
                <th>Name</th>
                <th>Type</th>
                <th class="text-right">Action</th>
              </tr>
            </thead>
            <tbody>
              <%= for stop <- @positioned_stops do %>
                <tr id={"positioned-stop-row-#{stop.id}"}>
                  <td>{stop.stop_id}</td>
                  <td>{stop.stop_name || "—"}</td>
                  <td>{Stop.location_type_label(stop.location_type)}</td>
                  <td class="text-right">
                    <button
                      type="button"
                      class="btn btn-outline btn-xs"
                      phx-click="reposition_stop"
                      phx-value-id={stop.id}
                    >
                      Move here
                    </button>
                  </td>
                </tr>
              <% end %>
              <tr :if={@positioned_stops == []}>
                <td colspan="4" class="text-sm text-base-content/60">
                  No matching positioned stops on this level.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  attr :child_stop_form, :any, required: true
  attr :selected_stop_id, :any
  attr :pending_xy, :any, required: true
  attr :all_levels, :list, required: true
  attr :editing_level, :boolean, default: false
  attr :stop_id_mode, :atom, default: :auto
  attr :active_level, :any, default: nil
  attr :platform_options, :list, default: []

  defp child_stop_form(assigns) do
    # Location type options for select (GTFS spec allows 0-4 for child stops)
    # Note: Type 1 (Station) can be used for hierarchical stations in complex transit hubs
    location_type_options = [
      {"0 - Stop/Platform", "0"},
      {"1 - Station", "1"},
      {"2 - Entrance/Exit", "2"},
      {"3 - Generic Node", "3"},
      {"4 - Boarding Area", "4"}
    ]

    wheelchair_boarding_options = [
      {"— Unspecified", ""},
      {"0 - No info", "0"},
      {"1 - Accessible", "1"},
      {"2 - Not accessible", "2"}
    ]

    current_level_id =
      assigns.child_stop_form[:level_id].value ||
        if(assigns.active_level, do: assigns.active_level.level_id, else: nil)

    current_level_display = level_display_name(assigns.all_levels, current_level_id)
    location_type = parse_optional_int(assigns.child_stop_form[:location_type].value) || 3

    assigns =
      assigns
      |> assign(:location_type_options, location_type_options)
      |> assign(:wheelchair_boarding_options, wheelchair_boarding_options)
      |> assign(:current_level_id, current_level_id || "")
      |> assign(:current_level_display, current_level_display)
      |> assign(:is_new_stop, assigns.selected_stop_id == nil)
      |> assign(:location_type, location_type)
      |> assign(:show_platform_code, location_type in [0, 4])

    ~H"""
    <.simple_form
      for={@child_stop_form}
      id="child-stop-form"
      phx-submit="save_child_stop"
      phx-change="validate_child_stop"
    >
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

      <%= if @stop_id_mode == :auto && @is_new_stop do %>
        <div class="space-y-2">
          <label class="text-sm font-medium leading-6 text-zinc-800">
            Stop ID
          </label>
          <p class="w-full input input-lg bg-base-200 flex items-center font-mono text-sm">
            {if @child_stop_form[:stop_id].value in [nil, ""],
              do: "Type a name above",
              else: @child_stop_form[:stop_id].value}
          </p>
          <.input field={@child_stop_form[:stop_id]} type="hidden" />
          <button
            type="button"
            class="link link-primary text-xs"
            phx-click="toggle_stop_id_mode"
          >
            Set manually
          </button>
        </div>
      <% else %>
        <div class="space-y-2">
          <.input
            field={@child_stop_form[:stop_id]}
            type="text"
            label="Stop ID"
            placeholder="e.g., platform-2-01"
            required={@is_new_stop && @stop_id_mode == :manual}
            class="w-full input input-lg"
          />
          <p :if={!@is_new_stop} class="text-xs text-base-content/60">
            Leave blank to auto-generate from stop name
          </p>
          <button
            :if={@is_new_stop}
            type="button"
            class="link link-primary text-xs"
            phx-click="toggle_stop_id_mode"
          >
            Auto-generate
          </button>
        </div>
      <% end %>

      <.input
        field={@child_stop_form[:wheelchair_boarding]}
        type="select"
        label="Accessible"
        options={@wheelchair_boarding_options}
        help="Optional"
      />

      <.input
        :if={@show_platform_code}
        field={@child_stop_form[:platform_code]}
        type="text"
        label="Platform"
        placeholder="e.g., 2A"
        help="Optional"
      />

      <.input
        :if={@location_type == 4 && @platform_options != []}
        field={@child_stop_form[:parent_platform]}
        type="select"
        label="Parent Platform"
        options={[{"— None (under station)", ""} | @platform_options]}
        help="Optional"
      />

      <p
        :if={@location_type == 4 && @platform_options == []}
        id="parent-platform-info"
        class="text-sm text-base-content/70"
      >
        No platforms defined for this station yet.
      </p>

      <div class="grid grid-cols-2 gap-4">
        <.input
          field={@child_stop_form[:stop_lat]}
          type="number"
          label="Latitude"
          placeholder="e.g., 40.7128"
          step="0.000001"
          min="-90"
          max="90"
          help="Optional"
        />
        <.input
          field={@child_stop_form[:stop_lon]}
          type="number"
          label="Longitude"
          placeholder="e.g., -74.0060"
          step="0.000001"
          min="-180"
          max="180"
          help="Optional"
        />
      </div>

      <%= if @selected_stop_id != nil && @editing_level do %>
        <.input
          field={@child_stop_form[:level_id]}
          id="child-stop-level-id-select"
          type="select"
          label="Level"
          options={
            Enum.map(@all_levels, fn level ->
              {"#{level.level_name || level.level_id} (#{trunc(level.level_index)})", level.level_id}
            end)
          }
          help="GTFS level for this child stop"
        />
      <% else %>
        <.input
          field={@child_stop_form[:level_id]}
          id="child-stop-level-id-hidden"
          type="hidden"
          value={@current_level_id}
        />
        <div class="space-y-2">
          <label class="text-sm font-medium leading-6 text-zinc-800">
            {if @selected_stop_id == nil, do: "Current Level", else: "Level"}
          </label>
          <p class="w-full input input-lg bg-base-200 flex items-center">
            {@current_level_display}
          </p>

          <button
            :if={@selected_stop_id != nil}
            type="button"
            class="link link-primary text-xs"
            phx-click="toggle_level_edit"
          >
            Change
          </button>
        </div>
      <% end %>

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

    <div
      :if={@selected_stop_id}
      id="remove-from-diagram-section"
      class="mt-8 pt-6 border-t border-base-200"
    >
      <div class="bg-warning/5 border border-warning/20 rounded-lg p-4">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="text-zinc-700 font-medium">Remove from Diagram</h3>
            <p class="text-xs text-zinc-500 mt-1">
              Clears placement. The stop record is kept, but connected pathways are deleted.
            </p>
          </div>
          <button
            id="remove-from-diagram-button"
            type="button"
            class="btn btn-warning btn-sm btn-active text-white"
            phx-click="remove_from_diagram"
            phx-value-id={@selected_stop_id}
            data-confirm="Remove this stop from the diagram? It will move to the unassigned list."
          >
            Remove
          </button>
        </div>
      </div>
    </div>

    <div :if={@selected_stop_id} class="mt-4">
      <div class="bg-error/5 border border-error/20 rounded-lg p-4">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="text-zinc-700 font-medium">Delete Child Stop</h3>
            <p class="text-xs text-zinc-500 mt-1">
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

  defp level_display_name(_levels, nil), do: "Unassigned"
  defp level_display_name(_levels, ""), do: "Unassigned"

  defp level_display_name(levels, level_id) do
    case Enum.find(levels, fn level -> level.level_id == level_id end) do
      nil -> level_id
      level -> "#{level.level_name || level.level_id} (#{trunc(level.level_index)})"
    end
  end

  defp parse_optional_int(nil), do: nil
  defp parse_optional_int(""), do: nil

  defp parse_optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_optional_int(value) when is_integer(value), do: value
  defp parse_optional_int(_), do: nil

  defp pathway_midpoint(x1, y1, x2, y2), do: {(x1 + x2) / 2, (y1 + y2) / 2}

  defp pathway_length(x1, y1, x2, y2) do
    dx = x2 - x1
    dy = y2 - y1
    :math.sqrt(dx * dx + dy * dy)
  end

  defp perpendicular_unit(x1, y1, x2, y2) do
    length = pathway_length(x1, y1, x2, y2)

    if length <= 0.0 do
      {0.0, -1.0}
    else
      dx = x2 - x1
      dy = y2 - y1
      {-dy / length, dx / length}
    end
  end

  defp center_ticks(x1, y1, x2, y2, count, spacing, extent) do
    length = pathway_length(x1, y1, x2, y2)

    if count <= 0 or spacing <= 0 or extent <= 0 or length <= 0 do
      []
    else
      dx = x2 - x1
      dy = y2 - y1
      unit_x = dx / length
      unit_y = dy / length
      {perp_x, perp_y} = perpendicular_unit(x1, y1, x2, y2)
      half_extent = extent / 2
      {mid_x, mid_y} = pathway_midpoint(x1, y1, x2, y2)
      start_offset = -((count - 1) / 2)

      0..(count - 1)
      |> Enum.map(fn index ->
        along = (start_offset + index) * spacing
        center_x = mid_x + unit_x * along
        center_y = mid_y + unit_y * along

        %{
          x1: center_x - perp_x * half_extent,
          y1: center_y - perp_y * half_extent,
          x2: center_x + perp_x * half_extent,
          y2: center_y + perp_y * half_extent
        }
      end)
    end
  end

  defp center_cross(x1, y1, x2, y2, size) do
    length = pathway_length(x1, y1, x2, y2)

    if size <= 0 or length <= 0 do
      []
    else
      {mid_x, mid_y} = pathway_midpoint(x1, y1, x2, y2)
      unit_x = (x2 - x1) / length
      unit_y = (y2 - y1) / length
      {perp_x, perp_y} = perpendicular_unit(x1, y1, x2, y2)
      diagonal_half = size / 2 / :math.sqrt(2)

      [
        %{
          x1: mid_x - (unit_x + perp_x) * diagonal_half,
          y1: mid_y - (unit_y + perp_y) * diagonal_half,
          x2: mid_x + (unit_x + perp_x) * diagonal_half,
          y2: mid_y + (unit_y + perp_y) * diagonal_half
        },
        %{
          x1: mid_x - (unit_x - perp_x) * diagonal_half,
          y1: mid_y - (unit_y - perp_y) * diagonal_half,
          x2: mid_x + (unit_x - perp_x) * diagonal_half,
          y2: mid_y + (unit_y - perp_y) * diagonal_half
        }
      ]
    end
  end

  defp parallel_offset(x1, y1, x2, y2, offset) do
    {perp_x, perp_y} = perpendicular_unit(x1, y1, x2, y2)

    {
      x1 + perp_x * offset,
      y1 + perp_y * offset,
      x2 + perp_x * offset,
      y2 + perp_y * offset
    }
  end

  defp label_offset(x1, y1, x2, y2, side) do
    {perp_x, perp_y} = perpendicular_unit(x1, y1, x2, y2)
    {above_x, above_y} = canonical_label_side(perp_x, perp_y)
    distance = 0.95

    case side do
      :reverse -> {-above_x * distance, -above_y * distance}
      _ -> {above_x * distance, above_y * distance}
    end
  end

  defp canonical_label_side(perp_x, perp_y) when perp_y < 0, do: {perp_x, perp_y}
  defp canonical_label_side(perp_x, perp_y) when perp_y > 0, do: {-perp_x, -perp_y}
  defp canonical_label_side(perp_x, perp_y) when perp_x > 0, do: {-perp_x, -perp_y}
  defp canonical_label_side(perp_x, perp_y), do: {perp_x, perp_y}

  defp pathway_label_angle_metadata(x1, y1, x2, y2) do
    angle = :math.atan2(y2 - y1, x2 - x1) * 180 / :math.pi()
    {pathway_label_rotation(angle), pathway_label_flipped?(angle)}
  end

  defp pathway_label_flipped?(angle) when angle > 90, do: true
  defp pathway_label_flipped?(angle) when angle < -90, do: true
  defp pathway_label_flipped?(_angle), do: false

  defp direction_indicator(text, :forward, false), do: "#{text} →"
  defp direction_indicator(text, :forward, true), do: "← #{text}"
  defp direction_indicator(text, :reverse, false), do: "← #{text}"
  defp direction_indicator(text, :reverse, true), do: "#{text} →"

  defp pathway_label_rotation(angle) when angle > 90, do: angle - 180
  defp pathway_label_rotation(angle) when angle < -90, do: angle + 180
  defp pathway_label_rotation(angle), do: angle

  # ============================================================================
  # Ruler Drawer
  # ============================================================================

  attr :open, :boolean, required: true
  attr :ruler_form, :any, required: true

  def ruler_drawer(assigns) do
    ~H"""
    <.drawer
      id="ruler-drawer"
      open={@open}
      on_close="close_ruler_drawer"
      title="Diagram Scale"
      class="max-w-xl"
    >
      <.simple_form for={@ruler_form} id="ruler-form" phx-submit="save_ruler">
        <.input
          field={@ruler_form[:distance_meters]}
          type="number"
          label="Distance (meters)"
          step="0.01"
          min="0.01"
          required
          help="Enter the real-world distance between the two selected points."
        />

        <:actions>
          <div class="flex-1"></div>
          <button type="submit" class="btn btn-primary btn-active">
            Save Scale
          </button>
        </:actions>
      </.simple_form>
    </.drawer>
    """
  end

  # ============================================================================
  # Pathway Drawer
  # ============================================================================

  attr :open, :boolean, required: true
  attr :pathway_form, :any, required: true
  attr :editing_pathway, :any
  attr :editing_pathway_pair, :list, default: []
  attr :active_pathway_tab, :atom, default: :first
  attr :pathway_form_dirty, :boolean, default: false
  attr :has_scale, :boolean, default: false
  attr :pathway_error, :string, default: nil

  def pathway_drawer(assigns) do
    ~H"""
    <.drawer
      id="pathway-drawer"
      open={@open}
      on_close="close_pathway_drawer"
      title="Edit Pathway"
      class="max-w-4xl"
    >
      <:header_actions>
        <div class="flex items-center gap-2">
          <span
            :if={@pathway_form_dirty}
            id="pathway-dirty-indicator"
            class="badge badge-warning badge-sm"
          >
            Unsaved changes
          </span>
          <div
            :if={@open and length(@editing_pathway_pair) == 2}
            id="pathway-pair-tabs"
            class="flex gap-1"
          >
            <button
              id="pathway-tab-first"
              type="button"
              phx-click="switch_pathway_tab"
              phx-value-tab="first"
              data-confirm={if @pathway_form_dirty, do: "Discard unsaved pathway changes?"}
              aria-selected={if @active_pathway_tab == :first, do: "true", else: "false"}
              class={[
                "btn btn-xs",
                if(@active_pathway_tab == :first, do: "btn-primary btn-active", else: "btn-ghost")
              ]}
            >
              First Pathway
            </button>
            <button
              id="pathway-tab-second"
              type="button"
              phx-click="switch_pathway_tab"
              phx-value-tab="second"
              data-confirm={if @pathway_form_dirty, do: "Discard unsaved pathway changes?"}
              aria-selected={if @active_pathway_tab == :second, do: "true", else: "false"}
              class={[
                "btn btn-xs",
                if(@active_pathway_tab == :second, do: "btn-primary btn-active", else: "btn-ghost")
              ]}
            >
              Second Pathway
            </button>
          </div>
          <button
            :if={
              (length(@editing_pathway_pair) == 1 and @editing_pathway) &&
                not Map.get(@editing_pathway, :is_cross_level, false)
            }
            id="add-second-pathway-btn"
            type="button"
            class="btn btn-xs btn-outline"
            phx-click="add_second_pathway"
            data-confirm={if @pathway_form_dirty, do: "Discard unsaved pathway changes?"}
          >
            Add Second Pathway
          </button>
        </div>
      </:header_actions>

      <.pathway_preview
        :if={@open and @editing_pathway}
        editing_pathway={@editing_pathway}
        pathway_form={@pathway_form}
      />

      <div :if={@open and @editing_pathway} class="mt-6"></div>

      <.pathway_form
        :if={@open}
        pathway_form={@pathway_form}
        editing_pathway={@editing_pathway}
        has_scale={@has_scale}
        pathway_error={@pathway_error}
      />
    </.drawer>
    """
  end

  attr :editing_pathway, :any, required: true
  attr :pathway_form, :any, required: true

  defp pathway_preview(assigns) do
    from_stop = assigns.editing_pathway.from_stop
    to_stop = assigns.editing_pathway.to_stop

    # Read mode, bidirectional, and signage from form values so the preview
    # updates live as the user edits, falling back to the saved pathway.
    form = assigns.pathway_form
    pathway = assigns.editing_pathway

    mode =
      parse_preview_int(form[:pathway_mode] && form[:pathway_mode].value, pathway.pathway_mode)

    bidirectional? =
      case form[:is_bidirectional] && form[:is_bidirectional].value do
        val when val in [true, "true", "1", 1] -> true
        val when val in [false, "false", "0", 0] -> false
        nil -> pathway.is_bidirectional
        _ -> pathway.is_bidirectional
      end

    signposted_as =
      if form[:signposted_as], do: form[:signposted_as].value, else: pathway.signposted_as

    reversed_signposted_as =
      if form[:reversed_signposted_as],
        do: form[:reversed_signposted_as].value,
        else: pathway.reversed_signposted_as

    from_id =
      case from_stop do
        %Stop{} = s -> s.stop_id
        _ -> "?"
      end

    to_id =
      case to_stop do
        %Stop{} = s -> s.stop_id
        _ -> "?"
      end

    from_name =
      case from_stop do
        %Stop{} = s -> s.stop_name || s.stop_id
        _ -> "Unknown"
      end

    to_name =
      case to_stop do
        %Stop{} = s -> s.stop_name || s.stop_id
        _ -> "Unknown"
      end

    has_forward_sign? = present_text?(signposted_as)
    has_reverse_sign? = bidirectional? and present_text?(reversed_signposted_as)

    assigns =
      assigns
      |> assign(:mode, mode)
      |> assign(:bidirectional?, bidirectional?)
      |> assign(:from_id, from_id)
      |> assign(:to_id, to_id)
      |> assign(:from_name, from_name)
      |> assign(:to_name, to_name)
      |> assign(:signposted_as, signposted_as)
      |> assign(:reversed_signposted_as, reversed_signposted_as)
      |> assign(:has_forward_sign?, has_forward_sign?)
      |> assign(:has_reverse_sign?, has_reverse_sign?)

    ~H"""
    <div class="bg-base-200 rounded-lg px-3 py-2 -mx-2">
      <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-0.5">
        Pathway Diagram
      </h4>
      <svg
        data-pathway-preview="true"
        viewBox="0 0 480 40"
        class="w-full"
        aria-label={"Pathway from #{@from_id} to #{@to_id}"}
      >
        <defs>
          <marker
            id="preview-arrow"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="5"
            markerHeight="5"
            orient="auto-start-reverse"
          >
            <path d="M 0 0 L 10 5 L 0 10 z" fill="#FF00FF" />
          </marker>
        </defs>

        <%!-- From node --%>
        <g>
          <title>{@from_name}</title>
          <circle cx="14" cy="16" r="5" fill="#0080FF" />
          <text
            x="0"
            y="32"
            text-anchor="start"
            font-family="Inter, sans-serif"
            font-size="7"
            fill="#0080FF"
            font-weight="600"
          >
            {@from_id}
          </text>
        </g>

        <%!-- To node --%>
        <g>
          <title>{@to_name}</title>
          <circle cx="466" cy="16" r="5" fill="#0080FF" />
          <text
            x="480"
            y="32"
            text-anchor="end"
            font-family="Inter, sans-serif"
            font-size="7"
            fill="#0080FF"
            font-weight="600"
          >
            {@to_id}
          </text>
        </g>

        <%!-- Signage above the line --%>
        <text
          :if={@has_forward_sign?}
          x="240"
          y="8"
          text-anchor="middle"
          font-family="Inter, sans-serif"
          font-size="7"
          fill="#888"
        >
          {@signposted_as} →
        </text>

        <%!-- Pathway line with mode-specific visuals --%>
        {pathway_preview_line(assigns)}

        <%!-- Signage below the line --%>
        <text
          :if={@has_reverse_sign?}
          x="240"
          y="26"
          text-anchor="middle"
          font-family="Inter, sans-serif"
          font-size="7"
          fill="#888"
        >
          ← {@reversed_signposted_as}
        </text>
      </svg>

      <div class="flex justify-center">
        <button
          type="button"
          class="btn btn-xs btn-outline bg-white"
          phx-click="flip_pathway"
          phx-value-id={@editing_pathway.id}
        >
          Flip direction
        </button>
      </div>
    </div>
    """
  end

  defp parse_preview_int(nil, fallback), do: fallback

  defp parse_preview_int(val, fallback) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> fallback
    end
  end

  defp parse_preview_int(val, _fallback) when is_integer(val), do: val
  defp parse_preview_int(_val, fallback), do: fallback

  defp pathway_preview_line(%{mode: 1} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="#FF00FF"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    """
  end

  defp pathway_preview_line(%{mode: 2} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="#FF00FF"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="240" y1="11" x2="240" y2="21" stroke="#FF00FF" stroke-width="1" />
    """
  end

  defp pathway_preview_line(%{mode: 3} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="#FF00FF"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="236" y1="11" x2="244" y2="21" stroke="#FF00FF" stroke-width="1" />
    <line x1="244" y1="11" x2="236" y2="21" stroke="#FF00FF" stroke-width="1" />
    """
  end

  defp pathway_preview_line(%{mode: 4} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="#FF00FF"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="234" y1="11" x2="234" y2="21" stroke="#FF00FF" stroke-width="1" />
    <line x1="240" y1="11" x2="240" y2="21" stroke="#FF00FF" stroke-width="1" />
    <line x1="246" y1="11" x2="246" y2="21" stroke="#FF00FF" stroke-width="1" />
    """
  end

  defp pathway_preview_line(%{mode: 5} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="215"
      y2="16"
      stroke="#FF00FF"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
    />
    <rect x="215" y="8" width="50" height="16" rx="2" fill="white" stroke="#FF00FF" stroke-width="1" />
    <text
      x="240"
      y="16"
      text-anchor="middle"
      dominant-baseline="central"
      font-family="Inter, sans-serif"
      font-size="10"
      fill="#FF00FF"
    >
      &#x2195;
    </text>
    <line
      x1="265"
      y1="16"
      x2="458"
      y2="16"
      stroke="#FF00FF"
      stroke-width="1.2"
      marker-end="url(#preview-arrow)"
    />
    """
  end

  defp pathway_preview_line(%{mode: 6} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="14"
      x2="458"
      y2="14"
      stroke="#FF00FF"
      stroke-width="1"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="22" y1="18" x2="458" y2="18" stroke="#FF00FF" stroke-width="1" />
    """
  end

  defp pathway_preview_line(%{mode: 7} = assigns) do
    ~H"""
    <line
      x1="22"
      y1="14"
      x2="458"
      y2="14"
      stroke="#FF00FF"
      stroke-width="1"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    <line x1="22" y1="18" x2="458" y2="18" stroke="#FF00FF" stroke-width="1" />
    """
  end

  defp pathway_preview_line(assigns) do
    ~H"""
    <line
      x1="22"
      y1="16"
      x2="458"
      y2="16"
      stroke="#FF00FF"
      stroke-width="1.2"
      marker-start={if @bidirectional?, do: "url(#preview-arrow)", else: nil}
      marker-end="url(#preview-arrow)"
    />
    """
  end

  attr :pathway_form, :any, required: true
  attr :editing_pathway, :any
  attr :has_scale, :boolean, default: false
  attr :pathway_error, :string, default: nil

  defp pathway_form(assigns) do
    # Build pathway mode options using Pathway module functions
    pathway_mode_options =
      Pathway.pathway_modes()
      |> Enum.sort_by(fn {_name, mode_value} -> mode_value end)
      |> Enum.map(fn {_name, mode_value} ->
        {Pathway.mode_label(mode_value), to_string(mode_value)}
      end)

    assigns = assign(assigns, :pathway_mode_options, pathway_mode_options)

    ~H"""
    <.simple_form
      for={@pathway_form}
      id="pathway-form"
      phx-submit="save_pathway"
      phx-change="pathway_form_changed"
    >
      <%!-- ID is hidden as it's auto-managed or readonly --%>
      <.input field={@pathway_form[:pathway_id]} type="hidden" />
      <p :if={@pathway_error} id="pathway-form-error" class="mb-4 text-error text-sm">
        {@pathway_error}
      </p>

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

        <div>
          <.input
            field={@pathway_form[:length]}
            type="number"
            label="Length (m)"
            step="0.01"
            min="0"
            help="Horizontal length in meters."
          />
          <button
            :if={
              @has_scale and @editing_pathway != nil and
                blank_pathway_length_value?(@pathway_form[:length].value)
            }
            type="button"
            class="mt-1 text-sm font-medium link link-primary justify-start"
            phx-click="calculate_pathway_length"
          >
            Calculate length?
          </button>
        </div>

        <.input
          field={@pathway_form[:min_width]}
          type="number"
          label="Min Width (m)"
          step="0.01"
          min="0"
          placeholder="Not specified"
          help="Optional. Recommended if narrower than 1 meter."
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
          :if={truthy_input_value?(@pathway_form[:is_bidirectional].value)}
          field={@pathway_form[:reversed_signposted_as]}
          type="text"
          label="Reversed Signposted As"
          help="Text on signs for the reverse direction."
        />
      </div>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_pathway_drawer">
          Cancel
        </button>
        <div class="flex-1"></div>
        <button type="submit" class="btn btn-primary btn-active">
          Update Pathway
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

  defp blank_pathway_length_value?(nil), do: true

  defp blank_pathway_length_value?(value) when is_binary(value) do
    String.trim(value) == ""
  end

  defp blank_pathway_length_value?(_value), do: false

  defp truthy_input_value?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy_input_value?(_value), do: false

  # ============================================================================
  # Level Sidebar
  # ============================================================================

  attr :show_level_modal, :atom
  attr :level_form, :any, required: true
  attr :available_levels, :list, default: []
  attr :level_mode, :atom, default: :existing
  attr :editing_level_uuid, :string, default: nil
  attr :level_shared, :boolean, default: false

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
        editing_level_uuid={@editing_level_uuid}
        level_shared={@level_shared}
      />
    </.drawer>
    """
  end

  attr :level_form, :any, required: true
  attr :show_level_modal, :atom, required: true
  attr :available_levels, :list, default: []
  attr :level_mode, :atom, default: :existing
  attr :editing_level_uuid, :string, default: nil
  attr :level_shared, :boolean, default: false

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
      <div
        :if={@show_level_modal == :edit && @level_shared}
        class="bg-info/10 border border-info/30 rounded-lg p-3 flex items-start gap-2"
      >
        <.icon name="hero-information-circle" class="w-5 h-5 text-info shrink-0 mt-0.5" />
        <p class="text-sm text-info-content">
          This level is shared. Changes here will apply everywhere it's used, not just this station.
        </p>
      </div>

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

    <div
      :if={@show_level_modal == :edit && @editing_level_uuid}
      class="mt-8 pt-6 border-t border-base-200"
    >
      <div class="bg-error/5 border border-error/20 rounded-lg p-4">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="text-error font-medium">Remove from this station</h3>
            <p class="text-xs text-error/70 mt-1">
              Unassigns all child stops on this level and removes the diagram. The level itself won't be deleted.
            </p>
          </div>
          <button
            type="button"
            class="btn btn-error btn-sm btn-active text-white"
            phx-click="remove_level_from_station"
            phx-value-id={@editing_level_uuid}
            data-confirm="Remove this level from the station? Child stops on this level will become unassigned."
          >
            Remove Level
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Walkability Test Drawer
  # ============================================================================

  attr :open, :boolean, required: true
  attr :walkability_stop, :any, default: nil
  attr :walkability_form, :any, required: true
  attr :walkability_selected_address, :string, default: nil
  attr :walkability_selected_lat, :any, default: nil
  attr :walkability_selected_lon, :any, default: nil
  attr :walkability_error, :string, default: nil
  attr :walkability_field_errors, :map, default: %{}
  attr :walkability_mode, :atom, default: :create
  attr :editing_walkability_test, :any, default: nil

  def walkability_test_drawer(assigns) do
    ~H"""
    <.drawer
      id="walkability-test-drawer"
      open={@open}
      on_close="close_walkability_drawer"
      title={
        if @walkability_mode == :edit,
          do: "Edit Reachability Test Case",
          else: "Add a Reachability Test Case"
      }
      class="max-w-3xl"
    >
      <.walkability_test_form
        :if={@open && @walkability_stop}
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
    </.drawer>
    """
  end

  attr :walkability_stop, :any, default: nil
  attr :walkability_form, :any, required: true
  attr :walkability_selected_address, :string, default: nil
  attr :walkability_selected_lat, :any, default: nil
  attr :walkability_selected_lon, :any, default: nil
  attr :walkability_error, :string, default: nil
  attr :walkability_field_errors, :map, default: %{}
  attr :walkability_mode, :atom, default: :create
  attr :editing_walkability_test, :any, default: nil

  defp walkability_test_form(assigns) do
    ~H"""
    <div class="space-y-6">
      <div
        :if={@walkability_error}
        id="walkability-error"
        phx-hook="ScrollIntoView"
        class="px-4 py-3 bg-error/10 border border-error/20 rounded-lg"
      >
        <p class="text-sm font-medium text-base-content">{@walkability_error}</p>
      </div>

      <div class="p-4 bg-base-200 rounded-lg">
        <h4 class="font-bold text-sm uppercase tracking-wide text-base-content/50 mb-4">
          Stop Information
        </h4>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
          <div>
            <span class="block text-xs font-semibold text-base-content/40">Stop ID</span>
            <span class="font-medium">{@walkability_stop.stop_id}</span>
          </div>
          <div>
            <span class="block text-xs font-semibold text-base-content/40">Name</span>
            <span class="font-medium">{@walkability_stop.stop_name || "—"}</span>
          </div>
          <div>
            <span class="block text-xs font-semibold text-base-content/40">Type</span>
            <span class="font-medium">
              {Stop.location_type_label(@walkability_stop.location_type)}
            </span>
          </div>
          <div>
            <span class="block text-xs font-semibold text-base-content/40">Accessible</span>
            <span class="font-medium">
              {Stop.wheelchair_boarding_label(@walkability_stop.wheelchair_boarding) || "—"}
            </span>
          </div>
        </div>
      </div>

      <div>
        <h4 class="font-bold text-sm uppercase tracking-wide text-base-content/50 mb-2">
          Start Address
        </h4>
        <p class="text-sm text-base-content/70 mb-4">
          Search and select a nearby address for where the trip will begin.
        </p>

        <.form
          for={@walkability_form}
          id="walkability-test-form"
          phx-change="walkability_form_change"
          phx-submit="save_walkability_test"
        >
          <.live_component
            module={Component}
            id="walkability_address_autocomplete_component"
            field={@walkability_form[:address_autocomplete]}
            options={[]}
            debounce={300}
            placeholder="Type at least 3 characters..."
            update_min_len={3}
            dropdown_class="bg-base-300 border border-base-content/20 shadow-lg mt-1 text-base-content"
            option_class="px-4 py-2.5 border-b border-base-content/10 last:border-b-0 text-base-content"
            active_option_class="bg-primary text-primary-content"
            available_option_class="hover:bg-base-content/10 cursor-pointer transition-colors"
            text_input_class="input input-bordered w-full live-select-input"
          >
            <:option :let={option}>
              <div class="flex flex-col">
                <span class="font-medium">{option.label}</span>
              </div>
            </:option>
          </.live_component>

          <%= if @walkability_selected_lat && @walkability_selected_lon do %>
            <div class="mt-3 border border-base-content/20 bg-base-200/50 px-3 py-2 rounded-md">
              <p class="text-sm font-medium mb-2">{@walkability_selected_address}</p>
              <div class="grid grid-cols-2 gap-4 text-sm">
                <div>
                  <span class="text-base-content/70">Lat</span>
                  <span class="ml-2 font-mono">{@walkability_selected_lat}</span>
                </div>
                <div>
                  <span class="text-base-content/70">Lon</span>
                  <span class="ml-2 font-mono">{@walkability_selected_lon}</span>
                </div>
              </div>
            </div>
          <% end %>

          <div class="mt-10 mb-3 uppercase text-base font-semibold text-base-content">
            Description
          </div>

          <.input
            field={@walkability_form[:description]}
            type="textarea"
            label="Description"
            help="What does this test case verify?"
            placeholder="e.g., Route from hotel entrance to platform 3"
          />

          <div class="mt-10 mb-3 uppercase text-base font-semibold text-base-content">
            Expected outcome
          </div>

          <.input
            field={@walkability_form[:expected_traversable]}
            type="checkbox"
            label="Route is expected to be traversable"
          />
          <.input
            field={@walkability_form[:expected_wheelchair_accessible]}
            type="checkbox"
            label="Route is expected to be wheelchair accessible"
          />

          <div class="mt-10 mb-3 uppercase text-base font-semibold text-base-content">
            Expected metrics
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <.input
              field={@walkability_form[:expected_min_duration_seconds]}
              type="number"
              label="Min duration (s)"
              min="0"
              step="1"
              help="Acceptable range for walking time."
              errors={Map.get(@walkability_field_errors, :expected_min_duration_seconds, [])}
            />
            <.input
              field={@walkability_form[:expected_max_duration_seconds]}
              type="number"
              label="Max duration (s)"
              min="0"
              step="1"
              errors={Map.get(@walkability_field_errors, :expected_max_duration_seconds, [])}
            />
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <.input
              field={@walkability_form[:expected_min_distance_meters]}
              type="number"
              label="Min distance (m)"
              min="0"
              step="1"
              help="Acceptable range for walking distance."
              errors={Map.get(@walkability_field_errors, :expected_min_distance_meters, [])}
            />
            <.input
              field={@walkability_form[:expected_max_distance_meters]}
              type="number"
              label="Max distance (m)"
              min="0"
              step="1"
              errors={Map.get(@walkability_field_errors, :expected_max_distance_meters, [])}
            />
          </div>

          <div class="mt-6 flex items-center gap-3">
            <button type="button" class="btn btn-ghost" phx-click="close_walkability_drawer">
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-active"
              disabled={is_nil(@walkability_selected_address)}
            >
              {if @walkability_mode == :edit, do: "Save Test Case", else: "Create a Test Case"}
            </button>
          </div>

          <div
            :if={@walkability_mode == :edit && @editing_walkability_test}
            id="walkability-test-delete-section"
            class="mt-8 border border-error/30 rounded-lg p-4 bg-error/5"
          >
            <h5 class="font-semibold text-sm text-error">Delete this test case</h5>
            <p class="text-sm text-base-content/70 mt-1">
              This removes the test case from this stop.
            </p>
            <button
              type="button"
              id="walkability-test-delete-in-form"
              class="btn btn-outline btn-error mt-3"
              phx-click="delete_walkability_test"
              phx-value-id={@editing_walkability_test.id}
              data-confirm="Delete this walkability test case?"
            >
              Delete Test Case
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Lists Section
  # ============================================================================

  # ============================================================================
  # Naming Drawer
  # ============================================================================

  attr :open, :boolean, default: false
  attr :style, :atom, default: :kebab
  attr :preview_rows, :list, default: []
  attr :renamed_stops_count, :integer, default: 0
  attr :updated_pathways_count, :integer, default: 0
  attr :applying?, :boolean, default: false
  attr :error, :string, default: nil
  attr :excluded_ids, :any, default: %MapSet{}

  def naming_drawer(assigns) do
    ~H"""
    <.drawer
      id="naming-drawer"
      open={@open}
      on_close="close_naming_drawer"
      title="Apply naming convention"
    >
      <div class="space-y-6">
        <div :if={@style == :kebab} class="prose prose-sm max-w-none">
          <p>
            Renames child stops using a kebab-case version of each stop's name
            with a sequence number:
          </p>
          <code class="block bg-base-200 px-3 py-2 rounded text-sm">
            {"{name}-{seq}"}
          </code>
          <dl class="mt-3 text-sm space-y-1 not-prose">
            <div class="flex gap-2">
              <dt class="font-medium min-w-[5rem]">name</dt>
              <dd class="text-base-content/70">Stop name, lowercased and hyphenated</dd>
            </div>
            <div class="flex gap-2">
              <dt class="font-medium min-w-[5rem]">seq</dt>
              <dd class="text-base-content/70">Two-digit sequence for stops with the same name</dd>
            </div>
          </dl>
        </div>

        <div :if={@style == :structured} class="prose prose-sm max-w-none">
          <p>
            Renames child stops using a deterministic convention based on each stop's
            type, highest-priority connected pathway, and level:
          </p>
          <code class="block bg-base-200 px-3 py-2 rounded text-sm">
            {"{station}_{type}_{feature}_{level}_{seq}"}
          </code>
          <dl class="mt-3 text-sm space-y-1 not-prose">
            <div class="flex gap-2">
              <dt class="font-medium min-w-[5rem]">station</dt>
              <dd class="text-base-content/70">Parent station stop_id, slugified</dd>
            </div>
            <div class="flex gap-2">
              <dt class="font-medium min-w-[5rem]">type</dt>
              <dd class="text-base-content/70">platform, entrance, node, or boarding</dd>
            </div>
            <div class="flex gap-2">
              <dt class="font-medium min-w-[5rem]">feature</dt>
              <dd class="text-base-content/70">
                Highest-priority pathway mode (elevator, escalator, stairs, etc.) or general
              </dd>
            </div>
            <div class="flex gap-2">
              <dt class="font-medium min-w-[5rem]">level</dt>
              <dd class="text-base-content/70">Level ID, slugified (or nolvl)</dd>
            </div>
            <div class="flex gap-2">
              <dt class="font-medium min-w-[5rem]">seq</dt>
              <dd class="text-base-content/70">Two-digit sequence within each group</dd>
            </div>
          </dl>
        </div>

        <div class="flex gap-1">
          <button
            type="button"
            class={[
              "btn btn-sm flex-1",
              @style == :kebab && "btn-primary",
              @style != :kebab && "btn-ghost"
            ]}
            phx-click="change_naming_style"
            phx-value-style="kebab"
          >
            Name-based
          </button>
          <button
            type="button"
            class={[
              "btn btn-sm flex-1",
              @style == :structured && "btn-primary",
              @style != :structured && "btn-ghost"
            ]}
            phx-click="change_naming_style"
            phx-value-style="structured"
          >
            Structured
          </button>
        </div>

        <div :if={@error} class="alert alert-error text-sm">
          {@error}
        </div>

        <div :if={@preview_rows == [] and is_nil(@error)} class="text-sm text-base-content/60">
          No child stops to rename for this station.
        </div>

        <div :if={@preview_rows != []}>
          <h3 class="text-sm font-medium mb-2">Preview</h3>
          <div class="overflow-x-auto max-h-64 border border-base-200 rounded">
            <table class="table table-xs table-pin-rows">
              <thead>
                <tr>
                  <th class="w-8">
                    <input
                      type="checkbox"
                      class="checkbox checkbox-xs"
                      checked={MapSet.size(@excluded_ids) == 0}
                      aria-label="Select all child stops for renaming"
                      phx-click="toggle_naming_select_all"
                    />
                  </th>
                  <th>Current stop_id</th>
                  <th>New stop_id</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @preview_rows}
                  id={"naming-row-#{row.old_id}"}
                  class={MapSet.member?(@excluded_ids, row.old_id) && "opacity-40"}
                >
                  <td class="w-8">
                    <input
                      type="checkbox"
                      class="checkbox checkbox-xs"
                      checked={not MapSet.member?(@excluded_ids, row.old_id)}
                      aria-label={"Select #{row.old_id} for renaming"}
                      phx-click="toggle_naming_row"
                      phx-value-id={row.old_id}
                    />
                  </td>
                  <td class="font-mono text-xs">{row.old_id}</td>
                  <td class="font-mono text-xs">{row.new_id}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <p class="text-sm text-base-content/70 mt-3">
            <span :if={MapSet.size(@excluded_ids) > 0}>
              <span class="font-medium">{@renamed_stops_count}</span>
              of <span class="font-medium">{length(@preview_rows)}</span>
              child stops selected for renaming.
            </span>
            <span :if={MapSet.size(@excluded_ids) == 0}>
              <span class="font-medium">{@renamed_stops_count}</span>
              {if(@renamed_stops_count == 1, do: "child stop", else: "child stops")} will be renamed.
            </span>
            <span class="font-medium">{@updated_pathways_count}</span>
            {if(@updated_pathways_count == 1, do: "pathway reference", else: "pathway references")}
            {if(MapSet.size(@excluded_ids) > 0,
              do: " will be updated for the selected stops.",
              else: " will be updated."
            )}
          </p>
        </div>

        <div class="flex justify-end gap-2 pt-2 border-t border-base-200">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="close_naming_drawer">
            Cancel
          </button>
          <button
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="apply_naming_convention"
            phx-disable-with="Applying…"
            disabled={
              @preview_rows == [] || @applying? || @error ||
                MapSet.size(@excluded_ids) == length(@preview_rows)
            }
          >
            Apply naming convention
          </button>
        </div>
      </div>
    </.drawer>
    """
  end

  # ============================================================================
  # Lists Section
  # ============================================================================

  attr :active_level, :any, default: nil
  attr :child_stops_list, :list, required: true
  attr :unassigned_child_stops, :list, required: true
  attr :pathways_list, :list, required: true
  attr :pathway_error, :string
  attr :walkability_test_stop_ids, :any, default: %{}
  attr :walkability_tests_list, :list, default: []

  def lists_section(assigns) do
    ~H"""
    <div id="lists-section" class="mt-4 space-y-8">
      <.child_stops_table
        child_stops_list={@child_stops_list}
        walkability_test_stop_ids={@walkability_test_stop_ids}
      />
      <.walkability_tests_table walkability_tests_list={@walkability_tests_list} />
      <.unassigned_stops_table
        :if={@unassigned_child_stops != []}
        child_stops_list={@unassigned_child_stops}
      />
      <.pathways_table
        pathways_list={@pathways_list}
        pathway_error={@pathway_error}
        active_level={@active_level}
      />
    </div>
    """
  end

  attr :child_stops_list, :list, required: true
  attr :walkability_test_stop_ids, :any, default: %{}

  defp child_stops_table(assigns) do
    ~H"""
    <div>
      <h2 class="text-base font-semibold mb-2">Child Stops on Level</h2>
      <div class="bg-base-100 overflow-hidden [&_thead_th]:bg-base-300">
        <%= if @child_stops_list == [] do %>
          <p class="px-4 py-3 text-sm text-base-content/60">No child stops on this level.</p>
        <% else %>
          <.table
            id="child-stops-table"
            rows={@child_stops_list}
            row_id={&"child-stop-row-#{&1.id}"}
          >
            <:col :let={stop} label="Stop ID">
              <button
                type="button"
                class="link link-primary font-medium"
                phx-click="edit_child_stop"
                phx-value-id={stop.id}
              >
                {stop.stop_id}
              </button>
            </:col>
            <:col :let={stop} label="Name">{stop.stop_name || "—"}</:col>
            <:col :let={stop} label="Type">
              <span class="badge badge-ghost badge-sm">
                {Stop.location_type_label(stop.location_type)}
              </span>
            </:col>
            <:col :let={stop} label="Platform">{stop.platform_code || "—"}</:col>
            <:col :let={stop} label="Accessible">
              {Stop.wheelchair_boarding_label(stop.wheelchair_boarding) || "—"}
            </:col>
            <:col :let={stop} label="Reachability Tests">
              <div class="space-y-1">
                <%= if count = Map.get(@walkability_test_stop_ids, stop.stop_id) do %>
                  <span class="text-sm">
                    {count} {if count == 1, do: "test case", else: "test cases"}
                  </span>
                <% else %>
                  <span class="text-base-content/30 text-sm">—</span>
                <% end %>
                <button
                  type="button"
                  class="link text-sm block"
                  phx-click="open_walkability_drawer"
                  phx-value-id={stop.id}
                >
                  Add a test case
                </button>
              </div>
            </:col>
          </.table>
        <% end %>
      </div>
    </div>
    """
  end

  attr :child_stops_list, :list, required: true

  defp unassigned_stops_table(assigns) do
    ~H"""
    <div>
      <h2 class="text-base font-semibold mb-2">
        Child Stops Not Assigned to a Level
      </h2>
      <div class="bg-base-100 overflow-hidden [&_thead_th]:bg-base-300">
        <.table
          id="unassigned-stops-table"
          rows={@child_stops_list}
          row_id={&"unassigned-stop-row-#{&1.id}"}
        >
          <:col :let={stop} label="Stop ID">
            <button
              type="button"
              class="link link-primary font-medium"
              phx-click="edit_child_stop"
              phx-value-id={stop.id}
            >
              {stop.stop_id}
            </button>
          </:col>
          <:col :let={stop} label="Name">{stop.stop_name || "—"}</:col>
          <:col :let={stop} label="Type">
            <span class="badge badge-ghost badge-sm">
              {Stop.location_type_label(stop.location_type)}
            </span>
          </:col>
          <:col :let={stop} label="Platform">{stop.platform_code || "—"}</:col>
          <:col :let={stop} label="Accessible">
            {Stop.wheelchair_boarding_label(stop.wheelchair_boarding) || "—"}
          </:col>
        </.table>
      </div>
    </div>
    """
  end

  attr :walkability_tests_list, :list, default: []

  defp walkability_tests_table(assigns) do
    ~H"""
    <div>
      <h2 class="text-base font-semibold mb-2">Reachability Test Cases</h2>
      <div class="bg-base-100 overflow-hidden [&_thead_th]:bg-base-300">
        <%= if @walkability_tests_list == [] do %>
          <p class="px-4 py-3 text-sm text-base-content/60">
            No reachability test cases on this level.
          </p>
        <% else %>
          <.table
            id="walkability-tests-table"
            rows={@walkability_tests_list}
            row_id={&"walkability-test-row-#{&1.id}"}
          >
            <:col :let={test_case} label="Stop">
              <button
                type="button"
                id={"walkability-test-stop-#{test_case.id}"}
                class="link link-primary font-medium"
                phx-click="edit_walkability_test"
                phx-value-id={test_case.id}
              >
                {test_case.stop_id}
              </button>
            </:col>
            <:col :let={test_case} label="Start Address">
              <div class="max-w-80">
                <p class="truncate" title={test_case.address}>{test_case.address}</p>
              </div>
            </:col>
            <:col :let={test_case} label="Expected">
              <div class="space-y-0.5">
                <p class="text-sm">
                  {if test_case.expected_traversable, do: "Traversable", else: "Not traversable"} / {if test_case.expected_wheelchair_accessible,
                    do: "Wheelchair",
                    else: "No wheelchair"}
                </p>
                <p
                  :if={present_text?(test_case.description)}
                  class="text-xs text-base-content/60 truncate"
                >
                  {test_case.description}
                </p>
              </div>
            </:col>
            <:col :let={test_case} label="Updated">
              <span class="tabular-nums text-sm">{format_timestamp(test_case.updated_at)}</span>
            </:col>
          </.table>
        <% end %>
      </div>
    </div>
    """
  end

  attr :pathways_list, :list, required: true
  attr :pathway_error, :string
  attr :active_level, :any, default: nil

  defp pathways_table(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-2 mb-2">
        <h2 class="text-base font-semibold">Pathways on Level</h2>
        <span :if={@pathway_error} class="text-error text-sm">{@pathway_error}</span>
      </div>
      <div class="bg-base-100 overflow-hidden [&_thead_th]:bg-base-300">
        <%= if @pathways_list == [] do %>
          <p class="px-4 py-3 text-sm text-base-content/60">No pathways on this level.</p>
        <% else %>
          <.table
            id="pathways-table"
            rows={@pathways_list}
            row_id={&"pathway-row-#{&1.id}"}
          >
            <:col :let={pathway} label="From">
              <button
                type="button"
                class="link link-primary font-medium"
                phx-click="edit_pathway"
                phx-value-id={pathway.id}
              >
                {pathway_stop_display(pathway.from_stop)}
              </button>
            </:col>
            <:col :let={pathway} label="To">{pathway_stop_display(pathway.to_stop)}</:col>
            <:col :let={pathway} label="Mode">
              <span class="badge badge-ghost badge-sm">
                {Pathway.mode_label(pathway.pathway_mode)}
              </span>
            </:col>
            <:col :let={pathway} label="Bidirectional">
              {if pathway.is_bidirectional, do: "Yes", else: "No"}
            </:col>
            <:col :let={pathway} label="Cross-Level">
              {cross_level_target_level(pathway, @active_level)}
            </:col>
            <:col :let={pathway} label="Signage">
              <div class="space-y-1">
                <%= if !present_text?(pathway.signposted_as) && !present_text?(pathway.reversed_signposted_as) do %>
                  <p class="text-sm leading-tight">—</p>
                <% end %>

                <div :if={present_text?(pathway.signposted_as)} class="space-y-0.5">
                  <p class="text-xs font-medium text-base-content/70">Forward</p>
                  <p class="text-sm leading-tight">{pathway.signposted_as}</p>
                </div>

                <div :if={present_text?(pathway.reversed_signposted_as)} class="space-y-0.5">
                  <p class="text-xs font-medium text-base-content/70">Reverse</p>
                  <p class="text-sm leading-tight">{pathway.reversed_signposted_as}</p>
                </div>
              </div>
            </:col>
            <:col :let={pathway} label="Time (s)">
              <span class="tabular-nums text-right block">{pathway.traversal_time || "—"}</span>
            </:col>
            <:col :let={pathway} label="Length (m)">
              <span class="tabular-nums text-right block">
                {format_decimal(pathway.length) || "—"}
              </span>
            </:col>
          </.table>
        <% end %>
      </div>
    </div>
    """
  end

  defp pathway_stop_display(%Stop{} = stop), do: stop.stop_name || stop.stop_id
  defp pathway_stop_display(_), do: "Unknown"

  defp cross_level_target_level(pathway, active_level) do
    active_level_id = if active_level, do: active_level.level_id, else: nil
    from_level_id = pathway.from_stop && pathway.from_stop.level_id
    to_level_id = pathway.to_stop && pathway.to_stop.level_id

    cond do
      from_level_id in [nil, ""] or to_level_id in [nil, ""] ->
        "—"

      from_level_id == to_level_id ->
        "—"

      active_level_id in [nil, ""] ->
        to_level_id

      from_level_id == active_level_id ->
        to_level_id

      to_level_id == active_level_id ->
        from_level_id

      true ->
        to_level_id
    end
  end

  defp format_decimal(nil), do: nil
  defp format_decimal(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  defp format_decimal(value), do: to_string(value)

  defp format_timestamp(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  defp format_timestamp(_), do: "—"

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_), do: false
end
