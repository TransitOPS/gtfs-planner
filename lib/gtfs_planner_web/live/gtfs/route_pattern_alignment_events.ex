defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentEvents do
  @moduledoc """
  Alignment task event bodies for `RoutePatternLive` (CR-8).

  The LiveView keeps only assigns, `handle_params` loading and one-line
  delegations here. Loading goes through the production
  `Gtfs.alignment_editor/4` read model in the current organization/version
  scope (INV-2); a pattern from another scope resolves to `:not_found` like
  every other task. Selection is read-only: positions come from the loaded
  sections, so an unknown position leaves the socket unchanged, and this
  module never writes.
  """

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias Phoenix.Component

  @doc """
  Loads the alignment editor model when the Alignment task shows a pattern
  whose model is absent or belongs to another pattern. Returns
  `{:ok, socket}` or `{:error, :not_found}`; idempotent across `switch_task`
  patches for the same pattern.
  """
  def ensure_loaded(socket) do
    assigns = socket.assigns

    if alignment_route?(assigns) do
      current = assigns.alignment
      pattern_id = assigns.pattern.route_pattern_id

      if not is_nil(current) and current.route_pattern_id == pattern_id do
        {:ok, socket}
      else
        load_alignment(socket)
      end
    else
      {:ok, Component.assign(socket, :alignment, nil)}
    end
  end

  @doc "Selects a loaded section; unknown positions leave the socket unchanged."
  def select_section(socket, %{"position" => position_param}) do
    with {position, ""} <- parse_position(position_param),
         %{alignment: %{sections: sections}} <- socket.assigns,
         true <- Enum.any?(sections, &(&1.position == position)) do
      socket
      |> Component.assign(:alignment_state, %{
        socket.assigns.alignment_state
        | selected: position
      })
      |> Phoenix.LiveView.push_event("alignment:select", %{position: position})
    else
      _ -> socket
    end
  end

  def select_section(socket, _params), do: socket

  @doc """
  Pushes the saved hook model after the map hook mounts.

  The model comes from the production `Gtfs.alignment_editor/4` result
  already on the socket (INV-2); points stay `[lon, lat]` (INV-1) and the
  route colour fallback was decided server-side. A socket without a loaded
  model answers nothing.
  """
  def hook_ready(socket, _params) do
    %{alignment: alignment, alignment_editable: editable?} = socket.assigns

    if is_nil(alignment) do
      socket
    else
      model = Alignments.hook_model(alignment, editable: editable?, suggestions: [])
      Phoenix.LiveView.push_event(socket, "alignment:load", %{model: model})
    end
  end

  @doc "Shows the tile-failure notice; the sections stay usable."
  def map_error(socket, _params),
    do: Component.assign(socket, :alignment_notice, :map_error)

  @doc "Clears the tile-failure notice, restoring the load-time notice."
  def map_ok(socket, _params) do
    if socket.assigns[:alignment_notice] == :map_error do
      Component.assign(
        socket,
        :alignment_notice,
        notice_for(socket.assigns[:alignment], socket.assigns[:alignment_editable])
      )
    else
      socket
    end
  end

  @doc "Asks the hook to rebuild its tile layer after a tile failure."
  def retry_tiles(socket, _params),
    do: Phoenix.LiveView.push_event(socket, "alignment:retry_tiles", %{})

  @doc "Opens or closes the alignment help dialog."
  def set_dialog(socket, dialog), do: Component.assign(socket, :alignment_dialog, dialog)

  @draft_state_fields %{
    "dirty_positions" => :dirty_positions,
    "selected" => :selected,
    "mode" => :mode,
    "selected_point_count" => :selected_point_count,
    "point_count" => :point_count,
    "can_undo" => :can_undo,
    "can_redo" => :can_redo,
    "flagged_positions" => :flagged_positions,
    "review_positions" => :review_positions
  }

  @doc """
  Stores the hook-owned draft state (step 24).

  The hook owns draft geometry, selection and undo (CR-5); the LiveView
  keeps only this state mirror for later badge wiring (step 27 owns the
  badges). Unknown fields are dropped and invalid values are ignored, so a
  stale or foreign payload never corrupts the state shape. Read-only like
  selection: no database write, outside `@editor_write_events`.
  """
  def draft_state(socket, params) when is_map(params) do
    current = socket.assigns.alignment_state

    patch =
      Enum.reduce(@draft_state_fields, %{}, fn {wire, key}, acc ->
        case fetch_draft_value(params, wire, key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    Component.assign(socket, :alignment_state, Map.merge(current, patch))
  end

  def draft_state(socket, _params), do: socket

  defp fetch_draft_value(params, wire, key) do
    raw = Map.get(params, wire, Map.get(params, key, :missing))

    case {key, raw} do
      {:dirty_positions, positions} when is_list(positions) ->
        if Enum.all?(positions, &(is_integer(&1) and &1 >= 1)) do
          {:ok, Enum.sort(positions)}
        else
          :error
        end

      {:selected, position} when is_integer(position) and position >= 1 ->
        {:ok, position}

      {:mode, mode} when mode in ["pan", "edit"] ->
        {:ok, mode}

      {count_key, count}
      when count_key in [:selected_point_count, :point_count] and is_integer(count) and
             count >= 0 ->
        {:ok, count}

      {flag_key, value}
      when flag_key in [:can_undo, :can_redo] and is_boolean(value) ->
        {:ok, value}

      {positions_key, positions}
      when positions_key in [:flagged_positions, :review_positions] and is_list(positions) ->
        if Enum.all?(positions, &(is_integer(&1) and &1 >= 1)) do
          {:ok, positions}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp alignment_route?(assigns) do
    assigns.task == :alignment and assigns.load_state == :ready and
      assigns.live_action == :show and not is_nil(assigns.pattern)
  end

  defp load_alignment(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    pattern = socket.assigns.pattern

    case Gtfs.alignment_editor(
           organization_id,
           version_id,
           socket.assigns.route_id,
           pattern.route_pattern_id
         ) do
      {:ok, alignment} ->
        editable? = editor_access?(socket)

        {:ok,
         socket
         |> Component.assign(:alignment, alignment)
         |> Component.assign(:alignment_state, fresh_state(socket.assigns.alignment_state))
         |> Component.assign(:alignment_editable, editable?)
         |> Component.assign(:alignment_notice, notice_for(alignment, editable?))
         |> Component.assign(:alignment_dialog, nil)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # The single notice decision, shared by the load boundary and the tile
  # recovery path so `map_ok` restores exactly what the load showed.
  defp notice_for(nil, _editable?), do: nil
  defp notice_for(_alignment, false), do: :read_only

  defp notice_for(alignment, true) do
    cond do
      alignment.status.export == :stale -> :out_of_date
      alignment.status.export == :imported -> :imported_shape
      true -> nil
    end
  end

  defp fresh_state(state) when is_map(state), do: %{state | selected: 1}
  defp fresh_state(_state), do: %{selected: 1}

  defp parse_position(value) when is_binary(value) do
    case Integer.parse(value) do
      {position, ""} when position >= 1 -> {position, ""}
      _ -> :error
    end
  end

  defp parse_position(value) when is_integer(value) and value >= 1, do: {value, ""}
  defp parse_position(_value), do: :error

  # Fresh membership read at the load boundary, mirroring the LiveView's
  # editor gate: only the display (notice, disabled save) depends on it here,
  # and every future write event re-checks at its own mutation boundary.
  defp editor_access?(socket) do
    with %{id: user_id} <- socket.assigns[:current_user],
         %{id: organization_id} <- socket.assigns[:current_organization],
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(user_id, organization_id) do
      GtfsPlannerWeb.EnsureRole.has_role?(membership.roles, :pathways_studio_editor)
    else
      _ -> false
    end
  end
end
