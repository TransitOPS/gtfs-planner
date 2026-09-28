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

  require Phoenix.LiveView

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
      model =
        Alignments.hook_model(alignment,
          editable: editable?,
          suggestions: bulk_sections(socket, alignment.route_pattern_id)
        )

      Phoenix.LiveView.push_event(socket, "alignment:load", %{model: model})
    end
  end

  # Pending bulk suggestions for one pattern, as the hook's
  # `alignment:suggestions` section entries (step 36). Anything else —
  # no entry, an acked entry, a misshapen one — loads a clean model.
  defp bulk_sections(socket, route_pattern_id) do
    case (socket.assigns[:alignment_suggestions] || %{})[route_pattern_id] do
      %{sections: sections} when is_list(sections) -> sections
      _ -> []
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

  @doc "Closes the help, discard, delete, simplify, import, generate, bulk and save dialogs."
  def close_dialogs(socket) do
    socket
    |> Component.assign(:alignment_dialog, nil)
    |> Component.assign(:alignment_discard_dialog, nil)
    |> Component.assign(:alignment_delete_dialog, nil)
    |> Component.assign(:alignment_simplify_dialog, nil)
    |> Component.assign(:alignment_import_dialog, nil)
    |> Component.assign(:alignment_generate_dialog, nil)
    |> Component.assign(:bulk_dialog, nil)
    |> Component.assign(:alignment_pending, nil)
  end

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
    validate_draft_value(key, raw)
  end

  defp validate_draft_value(:dirty_positions, positions) when is_list(positions) do
    if valid_draft_positions?(positions), do: {:ok, Enum.sort(positions)}, else: :error
  end

  defp validate_draft_value(:selected, position) when is_integer(position) and position >= 1,
    do: {:ok, position}

  defp validate_draft_value(:mode, mode) when mode in ["pan", "edit"], do: {:ok, mode}

  defp validate_draft_value(key, count)
       when key in [:selected_point_count, :point_count] and is_integer(count) and count >= 0,
       do: {:ok, count}

  defp validate_draft_value(key, value)
       when key in [:can_undo, :can_redo] and is_boolean(value),
       do: {:ok, value}

  defp validate_draft_value(key, positions)
       when key in [:flagged_positions, :review_positions] and is_list(positions) do
    if valid_draft_positions?(positions), do: {:ok, positions}, else: :error
  end

  defp validate_draft_value(_key, _raw), do: :error

  defp valid_draft_positions?(positions),
    do: Enum.all?(positions, &(is_integer(&1) and &1 >= 1))

  @simplify_tolerances [5, 10, 25]
  @default_tolerance 10

  @doc """
  Opens the alignment discard dialog for a dirty draft.

  Viewers, clean drafts and sockets without a loaded model leave the
  socket unchanged. Confirming pushes a fresh `alignment:load` so the
  hook drops its drafts; the server dirty state clears when the hook
  re-pushes `alignment_draft_state` with no dirty positions.
  """
  def open_discard(socket, _params) do
    if editable?(socket) and alignment_dirty?(socket) and
         not is_nil(socket.assigns[:alignment]) do
      Component.assign(socket, :alignment_discard_dialog, true)
    else
      socket
    end
  end

  @doc """
  Confirms the alignment discard dialog: closes it and pushes the saved
  hook model so the hook redraws without drafts (CR-5). The dirty badges
  stay until the hook's next `alignment_draft_state` confirms the clean
  state; viewers or a missing model simply close the dialog.
  """
  def confirm_discard(socket, _params) do
    socket = Component.assign(socket, :alignment_discard_dialog, nil)

    case {editable?(socket), socket.assigns[:alignment]} do
      {true, alignment} when not is_nil(alignment) ->
        model =
          Alignments.hook_model(alignment,
            editable: socket.assigns[:alignment_editable] == true,
            suggestions: []
          )

        Phoenix.LiveView.push_event(socket, "alignment:load", %{model: model})

      _ ->
        socket
    end
  end

  @doc """
  Opens a pattern's Alignment task from the Route › Patterns list (step 35).

  A dirty editor (staged stop edits, timing edits or alignment drafts,
  all folded into `dirty?`) stashes the alignment path in the existing
  `pending_navigation` discard dialog instead of patching away the draft;
  a clean click patches in the same LiveView process, so no remount drops
  suggestions or hook state.
  """
  def open_pattern_alignment(socket, %{"pattern-id" => pattern_id})
      when is_binary(pattern_id) do
    path = "#{patterns_path(socket)}/#{pattern_id}?task=alignment"

    if socket.assigns[:dirty?] do
      Component.assign(socket, :pending_navigation, path)
    else
      Phoenix.LiveView.push_patch(socket, to: path)
    end
  end

  def open_pattern_alignment(socket, _params), do: socket

  @doc """
  Opens the delete dialog for a saved section.

  Viewers and unknown positions leave the socket unchanged; the dialog
  carries its own position so confirming never acts on a re-selected
  section.
  """
  def open_delete(socket, %{"position" => position_param}) do
    with true <- editable?(socket),
         {position, ""} <- parse_position(position_param),
         %{alignment: %{sections: sections, visits: visits}} <- socket.assigns,
         section when not is_nil(section) <-
           Enum.find(sections, &(&1.position == position)),
         true <- section.kind in [:override, :shared] do
      names = visit_names(visits, position)

      Component.assign(socket, :alignment_delete_dialog, %{
        position: position,
        from: names.from,
        to: names.to
      })
    else
      _ -> socket
    end
  end

  def open_delete(socket, _params), do: socket

  @doc """
  Confirms the delete dialog: closes it and pushes
  `alignment:delete_section` for the hook's delete draft (CR-5). The
  hook announces the draft change through `alignment_action_notice`.
  """
  def confirm_delete(socket, _params) do
    case {editable?(socket), socket.assigns[:alignment_delete_dialog]} do
      {true, %{position: position}} ->
        socket
        |> Component.assign(:alignment_delete_dialog, nil)
        |> Phoenix.LiveView.push_event("alignment:delete_section", %{
          position: position
        })

      _ ->
        Component.assign(socket, :alignment_delete_dialog, nil)
    end
  end

  @doc "Opens the simplify dialog for a section with a 10 m default."
  def open_simplify(socket, %{"position" => position_param}) do
    with true <- editable?(socket),
         {position, ""} <- parse_position(position_param),
         %{alignment: %{sections: sections}} <- socket.assigns,
         true <- Enum.any?(sections, &(&1.position == position)) do
      Component.assign(socket, :alignment_simplify_dialog, %{
        position: position,
        tolerance: @default_tolerance
      })
    else
      _ -> socket
    end
  end

  def open_simplify(socket, _params), do: socket

  @doc "Keeps the simplify tolerance to the 5/10/25 m options."
  def simplify_tolerance(socket, %{"tolerance_m" => tolerance_param}) do
    with %{tolerance: _} <- socket.assigns[:alignment_simplify_dialog],
         {tolerance, ""} <- parse_tolerance(tolerance_param),
         true <- tolerance in @simplify_tolerances do
      Component.assign(socket, :alignment_simplify_dialog, %{
        socket.assigns[:alignment_simplify_dialog]
        | tolerance: tolerance
      })
    else
      _ -> socket
    end
  end

  def simplify_tolerance(socket, _params), do: socket

  @doc """
  Confirms the simplify dialog: closes it and pushes
  `alignment:simplify` with the selected tolerance. The hook reports the
  removed count through `alignment_simplify_result`.
  """
  def confirm_simplify(socket, _params) do
    case {editable?(socket), socket.assigns[:alignment_simplify_dialog]} do
      {true, %{position: position, tolerance: tolerance}} ->
        socket
        |> Component.assign(:alignment_simplify_dialog, nil)
        |> Phoenix.LiveView.push_event("alignment:simplify", %{
          position: position,
          tolerance_m: tolerance
        })

      _ ->
        Component.assign(socket, :alignment_simplify_dialog, nil)
    end
  end

  @doc """
  Reports the hook's simplify outcome in the page status region: how
  many points were removed (Undo restores them), or that nothing
  changed at this tolerance.
  """
  def simplify_result(socket, %{"removed" => removed})
      when is_integer(removed) and removed > 0 do
    Component.assign(
      socket,
      :status_message,
      "#{removed} #{points_noun(removed)} removed. Undo restores them."
    )
  end

  def simplify_result(socket, %{"removed" => 0}) do
    Component.assign(
      socket,
      :status_message,
      "No points can be removed at this tolerance. Path unchanged."
    )
  end

  def simplify_result(socket, _params), do: socket

  @doc """
  Announces a hook section action (draw, clear, use_shared, delete) in
  the page status region. Draft-local like `draft_state`: no database
  write, outside `@editor_write_events`.
  """
  def action_notice(socket, %{"message" => message})
      when is_binary(message) and byte_size(message) > 0 do
    Component.assign(socket, :status_message, String.slice(message, 0, 300))
  end

  def action_notice(socket, _params), do: socket

  @doc """
  Opens the import review dialog for a pattern on imported shapes (step 29).

  Viewers and patterns without imported shapes leave the socket
  unchanged. The dialog pre-selects the first shape (shapes arrive sorted
  by ID); divergent choices update it through `import_choice/2`.
  Conversion itself is client-only (CR-9): confirming only pushes
  `alignment:convert` for the hook to draft, never writes.
  """
  def open_import(socket, _params) do
    with true <- editable?(socket),
         %{alignment: %{imported_shapes: [%{shape_id: first} | _]}} <- socket.assigns do
      Component.assign(socket, :alignment_import_dialog, %{shape_id: first})
    else
      _ -> socket
    end
  end

  @doc """
  Records the divergent shape choice from the import dialog form (step 29).

  Read-only like `save_choice/2`: only a shape the loaded model actually
  references is kept, so a stale form never converts a foreign shape.
  """
  def import_choice(socket, params) when is_map(params) do
    case {editable?(socket), socket.assigns[:alignment_import_dialog], socket.assigns[:alignment]} do
      {true, %{shape_id: _}, %{imported_shapes: shapes}} when is_list(shapes) ->
        wanted = import_choice_param(params)

        if wanted in Enum.map(shapes, & &1.shape_id) do
          Component.assign(socket, :alignment_import_dialog, %{shape_id: wanted})
        else
          socket
        end

      _ ->
        socket
    end
  end

  def import_choice(socket, _params), do: socket

  @doc """
  Confirms the import dialog: closes it and pushes `alignment:convert`
  with the chosen shape so the hook drafts every section (CR-5, CR-9).
  A closed dialog or an unknown shape only closes, never pushes.
  """
  def confirm_import(socket, _params) do
    case {editable?(socket), socket.assigns[:alignment_import_dialog], socket.assigns[:alignment]} do
      {true, %{shape_id: wanted}, %{imported_shapes: shapes}} when is_list(shapes) ->
        socket =
          socket
          |> Component.assign(:alignment_import_dialog, nil)
          |> Component.assign(
            :status_message,
            "Editable draft created. Original shape retained until you save."
          )

        if wanted in Enum.map(shapes, & &1.shape_id) do
          Phoenix.LiveView.push_event(socket, "alignment:convert", %{shape_id: wanted})
        else
          socket
        end

      _ ->
        Component.assign(socket, :alignment_import_dialog, nil)
    end
  end

  defp import_choice_param(%{"import_shape" => wanted}) when is_binary(wanted), do: wanted
  defp import_choice_param(%{import_shape: wanted}) when is_binary(wanted), do: wanted
  defp import_choice_param(_params), do: nil

  @generation_key :alignment_generation

  @doc """
  Starts street-path generation (step 32).

  A `"position"` param generates one section, asking first through the
  replace dialog when the section already has saved points. `"retry"`
  regenerates the notice's failed positions. No position generates every
  missing section. `"confirmed"` runs the replace dialog's stored
  positions. Viewers, an in-flight generation, an open save review and an
  empty target leave the socket unchanged; nothing is written (CR-9).
  The save-review guard keeps a routed suggestion from landing as a draft
  while the user is confirming an older geometry.
  """
  def generate(socket, params) when is_map(params) do
    cond do
      generation_blocked?(socket) ->
        socket

      Map.has_key?(params, "confirmed") or Map.has_key?(params, :confirmed) ->
        confirm_generate(socket)

      Map.has_key?(params, "retry") or Map.has_key?(params, :retry) ->
        retry_generate(socket)

      true ->
        position_or_missing(socket, params)
    end
  end

  def generate(socket, _params), do: socket

  defp generation_blocked?(socket) do
    not editable?(socket) or not is_nil(socket.assigns[:alignment_generation]) or
      not is_nil(socket.assigns[:alignment_pending]) or is_nil(socket.assigns[:alignment])
  end

  @doc """
  Starts the async street-routing request for the given positions (step 32).

  Runs `Gtfs.suggest_alignment_paths/5` under `start_async`, so the map
  stays interactive while routing. The token (a fresh ref plus the
  pattern's natural ID) lets `handle_generation_result/3` drop stale
  arrivals after a cancel or a pattern switch.
  """
  def start_generation(socket, positions) when is_list(positions) and positions != [] do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id
    pattern = socket.assigns.pattern
    route_pattern_id = pattern.route_pattern_id

    generation = %{
      token: :erlang.make_ref(),
      positions: positions,
      pattern_id: route_pattern_id
    }

    socket
    |> Component.assign(:alignment_generation, generation)
    |> Component.assign(:alignment_generate_notice, nil)
    |> Phoenix.LiveView.start_async(@generation_key, fn ->
      Gtfs.suggest_alignment_paths(
        organization_id,
        version_id,
        route_id,
        route_pattern_id,
        positions
      )
    end)
  end

  def start_generation(socket, _positions), do: socket

  @doc """
  Cancels in-flight street-path generation (step 32).

  Clears the token before `cancel_async`, so a response that already left
  the task is dropped by `handle_generation_result/3` instead of pushing
  suggestions. Pushes nothing.
  """
  def cancel_generation(socket, _params) do
    socket
    |> Component.assign(:alignment_generation, nil)
    |> Phoenix.LiveView.cancel_async(@generation_key)
  end

  @doc """
  Handles the async street-routing result (step 32).

  A cleared token (cancel), a pattern mismatch (the user switched patterns
  while routing) or a revoked editor drops the result with no push, so a
  stale result never lands on another section or pattern (FH-42).
  Otherwise pushes `alignment:suggestions` with `review: true` for the
  routed positions and shows the ready status; failures show a notice with
  Retry and Draw manually and push nothing. Exits and unexpected errors
  show the unavailable notice. Nothing is written (CR-9).
  """
  def handle_generation_result(socket, _key, {:ok, {:ok, %{suggestions: _, failed: _} = result}}) do
    case generation_context(socket) do
      {:ok, _generation} -> apply_generation_result(socket, result)
      :stale -> Component.assign(socket, :alignment_generation, nil)
    end
  end

  def handle_generation_result(socket, _key, _result) do
    case generation_context(socket) do
      {:ok, _generation} ->
        socket
        |> Component.assign(:alignment_generation, nil)
        |> Component.assign(:alignment_generate_notice, %{kind: :unavailable, failures: []})

      :stale ->
        Component.assign(socket, :alignment_generation, nil)
    end
  end

  # A result is live only while its generation is still current, on the
  # same pattern, for an editor. Anything else is stale.
  defp generation_context(socket) do
    with %{pattern_id: pattern_id} <- socket.assigns[:alignment_generation],
         %{route_pattern_id: current} <- socket.assigns[:pattern],
         true <- pattern_id == current,
         true <- editable?(socket) do
      {:ok, socket.assigns[:alignment_generation]}
    else
      _ -> :stale
    end
  end

  defp apply_generation_result(socket, %{suggestions: suggestions, failed: failed}) do
    socket = Component.assign(socket, :alignment_generation, nil)

    socket =
      if map_size(failed) > 0 do
        Component.assign(socket, :alignment_generate_notice, generate_notice(socket, failed))
      else
        Component.assign(socket, :alignment_generate_notice, nil)
      end

    sections =
      suggestions
      |> Enum.sort_by(fn {position, _points} -> position end)
      |> Enum.map(fn {position, points} -> %{position: position, points: points} end)

    if sections == [] do
      socket
    else
      socket
      |> Component.assign(
        :status_message,
        "Suggested path ready. Review the streets before saving."
      )
      |> Phoenix.LiveView.push_event("alignment:suggestions", %{
        sections: sections,
        review: true
      })
    end
  end

  # `:no_route` names each failed section; every other failure (timeout,
  # rate limiting, unavailability, missing key, invalid responses and
  # unreachable validation positions) shares the unavailable notice.
  # The API key never appears in either (AC-37).
  defp generate_notice(socket, failed) do
    visits_by_position = visits_by_position(socket)

    {no_route, unavailable} =
      Enum.split_with(failed, fn {_position, reason} -> reason == :no_route end)

    failures =
      Enum.map(no_route ++ unavailable, fn {position, _reason} ->
        failure_entry(visits_by_position, position)
      end)

    if unavailable == [] do
      %{kind: :no_route, failures: failures}
    else
      %{kind: :unavailable, failures: failures}
    end
  end

  defp failure_entry(visits_by_position, position) do
    from = Map.get(visits_by_position, position, %{})
    to = Map.get(visits_by_position, position + 1, %{})

    %{
      position: position,
      from: Map.get(from, :name, ""),
      to: Map.get(to, :name, "")
    }
  end

  defp visits_by_position(socket) do
    case socket.assigns[:alignment] do
      %{visits: visits} -> Map.new(visits, &{&1.position, &1})
      _ -> %{}
    end
  end

  defp confirm_generate(socket) do
    case socket.assigns[:alignment_generate_dialog] do
      %{positions: positions} when is_list(positions) and positions != [] ->
        socket
        |> Component.assign(:alignment_generate_dialog, nil)
        |> start_generation(positions)

      _ ->
        Component.assign(socket, :alignment_generate_dialog, nil)
    end
  end

  defp retry_generate(socket) do
    case socket.assigns[:alignment_generate_notice] do
      %{failures: [%{position: _} | _] = failures} ->
        start_generation(socket, Enum.map(failures, & &1.position))

      _ ->
        socket
    end
  end

  defp position_or_missing(socket, params) do
    case generation_position(params) do
      {:position, position} -> generate_position(socket, position)
      :missing -> generate_missing(socket)
      :invalid -> socket
    end
  end

  defp generation_position(%{"position" => param}), do: generation_position_value(param)
  defp generation_position(%{position: param}), do: generation_position_value(param)
  defp generation_position(_params), do: :missing

  defp generation_position_value(param) do
    case parse_position(param) do
      {position, ""} -> {:position, position}
      _ -> :invalid
    end
  end

  defp generate_position(socket, position) do
    section =
      case socket.assigns[:alignment] do
        %{sections: sections} -> Enum.find(sections, &(&1.position == position))
        _ -> nil
      end

    cond do
      is_nil(section) -> socket
      section.points != [] -> open_generate_dialog(socket, position)
      true -> start_generation(socket, [position])
    end
  end

  defp generate_missing(socket) do
    positions =
      case socket.assigns[:alignment] do
        %{sections: sections} ->
          sections
          |> Enum.filter(&(&1.kind == :missing))
          |> Enum.map(& &1.position)

        _ ->
          []
      end

    start_generation(socket, positions)
  end

  defp open_generate_dialog(socket, position) do
    names = visit_names(visit_list(socket), position)

    Component.assign(socket, :alignment_generate_dialog, %{
      positions: [position],
      from: names.from,
      to: names.to
    })
  end

  defp visit_list(socket) do
    case socket.assigns[:alignment] do
      %{visits: visits} -> visits
      _ -> []
    end
  end

  @follow_key :alignment_follow

  @doc """
  Routes street geometry between two selected neighbours (step 33).

  The hook pushes the selected run's 0-based interior indexes with the
  neighbouring `[lon, lat]` points (`from`/`to`: the adjacent interior
  points, or the stop anchors when the run touches an end). The position
  is validated against the loaded alignment model, the indexes against
  the section's interior length, and the coordinates against finite range
  before any routing call — forged values push nothing and route nothing.
  Runs under `start_async` like step 32's generation, so the map stays
  interactive; the result lands as `alignment:follow_result` and failures
  reuse the generation notice. Nothing is written (CR-9).
  """
  def follow_streets(socket, params) when is_map(params) do
    cond do
      not editable?(socket) ->
        socket

      not is_nil(socket.assigns[:alignment_follow]) ->
        socket

      true ->
        case follow_request(socket, params) do
          {:ok, request} -> start_follow(socket, request)
          :invalid -> reject_follow(socket, params)
        end
    end
  end

  def follow_streets(socket, _params), do: socket

  @doc """
  Handles the async follow-streets result (step 33).

  A cleared token (superseded flight), a pattern mismatch (the user
  switched patterns while routing) or a revoked editor drops the result
  with no push, mirroring `handle_generation_result/3`. Success pushes
  `alignment:follow_result` with the echoed run bounds and the routed
  interior points; `:no_route` shows the no-path notice naming the
  section, every other failure the unavailable notice. Nothing is
  written (CR-9).
  """
  def handle_follow_result(socket, _key, {:ok, {:ok, points}}) do
    case follow_context(socket) do
      {:ok, follow} -> apply_follow_result(socket, follow, points)
      :stale -> Component.assign(socket, :alignment_follow, nil)
    end
  end

  def handle_follow_result(socket, _key, {:ok, {:error, reason}}) do
    case follow_context(socket) do
      {:ok, %{position: position}} ->
        fail_follow(socket, %{position => reason})

      :stale ->
        Component.assign(socket, :alignment_follow, nil)
    end
  end

  def handle_follow_result(socket, _key, _result) do
    case follow_context(socket) do
      {:ok, %{position: position}} ->
        fail_follow(socket, %{position => :unavailable})

      :stale ->
        Component.assign(socket, :alignment_follow, nil)
    end
  end

  defp follow_request(socket, params) do
    with {:position, position} <- follow_position(socket, params),
         {:ok, start_index} <- follow_index(params, "start_index"),
         {:ok, end_index} <- follow_index(params, "end_index"),
         true <- start_index <= end_index,
         %{points: points} <- follow_section(socket, position),
         true <- end_index < follow_bound(params, points),
         {:ok, from} <- follow_endpoint(params, "from"),
         {:ok, to} <- follow_endpoint(params, "to") do
      {:ok,
       %{position: position, start_index: start_index, end_index: end_index, from: from, to: to}}
    else
      _ -> :invalid
    end
  end

  # A rejected run names its section through the routing notice instead of
  # failing silent with the button left enabled; a forged position with no
  # section pushes nothing.
  defp reject_follow(socket, params) do
    case follow_position(socket, params) do
      {:position, position} -> fail_follow(socket, %{position => :invalid_response})
      :invalid -> socket
    end
  end

  # The hook indexes its run against the effective (draft) interior, which a
  # committed-but-unsaved draft can make longer than the saved points the
  # server holds; bound the run against the pushed draft length when it is
  # a valid count, falling back to the saved length otherwise.
  defp follow_bound(params, points) do
    case params["interior_length"] || params[:interior_length] do
      length when is_integer(length) and length >= 0 -> length
      _ -> length(points)
    end
  end

  defp follow_position(socket, params) do
    raw = params["position"] || params[:position]

    case parse_position(raw) do
      {position, ""} ->
        case follow_section(socket, position) do
          nil -> :invalid
          _section -> {:position, position}
        end

      _ ->
        :invalid
    end
  end

  defp follow_section(socket, position) do
    case socket.assigns[:alignment] do
      %{sections: sections} -> Enum.find(sections, &(&1.position == position))
      _ -> nil
    end
  end

  defp follow_index(params, key) do
    case params[key] || params[String.to_atom(key)] do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> :invalid
    end
  end

  # Coordinates arrive as `[lon, lat]` lists from the hook's push; the
  # range check here mirrors `Alignments.suggest_between/2` so invalid
  # values are rejected before any routing call (and before `start_async`
  # even spawns).
  defp follow_endpoint(params, key) do
    case params[key] || params[String.to_atom(key)] do
      [lon, lat] -> follow_coords(lon, lat)
      _ -> :invalid
    end
  end

  defp follow_coords(lon, lat)
       when is_number(lon) and is_number(lat) and lon >= -180 and lon <= 180 and
              lat >= -90 and lat <= 90 do
    {:ok, [lon * 1.0, lat * 1.0]}
  end

  defp follow_coords(_lon, _lat), do: :invalid

  defp start_follow(socket, request) do
    %{from: from, to: to} = request
    route_pattern_id = socket.assigns.pattern.route_pattern_id

    follow =
      Map.merge(request, %{
        token: :erlang.make_ref(),
        pattern_id: route_pattern_id
      })

    socket
    |> Component.assign(:alignment_follow, follow)
    |> Component.assign(:alignment_generate_notice, nil)
    |> Phoenix.LiveView.start_async(@follow_key, fn ->
      Gtfs.suggest_alignment_between(from, to)
    end)
  end

  # A result is live only while its follow is still current, on the same
  # pattern, for an editor. Anything else is stale.
  defp follow_context(socket) do
    with %{pattern_id: pattern_id} <- socket.assigns[:alignment_follow],
         %{route_pattern_id: current} <- socket.assigns[:pattern],
         true <- pattern_id == current,
         true <- editable?(socket) do
      {:ok, socket.assigns[:alignment_follow]}
    else
      _ -> :stale
    end
  end

  defp apply_follow_result(socket, follow, points) when is_list(points) do
    socket
    |> Component.assign(:alignment_follow, nil)
    |> Phoenix.LiveView.push_event("alignment:follow_result", %{
      position: follow.position,
      start_index: follow.start_index,
      end_index: follow.end_index,
      points: points
    })
  end

  defp apply_follow_result(socket, %{position: position}, _points) do
    fail_follow(socket, %{position => :invalid_response})
  end

  defp fail_follow(socket, failed) do
    socket
    |> Component.assign(:alignment_follow, nil)
    |> Component.assign(:alignment_generate_notice, generate_notice(socket, failed))
  end

  @bulk_key :alignment_bulk
  @bulk_section_limit 200

  @doc """
  Toggles one pattern in the Route › Patterns bulk selection (step 36).

  Selection is LiveView-local (a MapSet of natural ids); viewers leave
  the socket unchanged. Unknown ids toggle harmlessly: `open_bulk/2`
  counts only missing sections of scoped patterns.
  """
  def toggle_bulk_select(socket, %{"pattern-id" => route_pattern_id})
      when is_binary(route_pattern_id) do
    if bulk_editor?(socket) do
      selected = socket.assigns[:bulk_selected] || MapSet.new()

      selected =
        if MapSet.member?(selected, route_pattern_id),
          do: MapSet.delete(selected, route_pattern_id),
          else: MapSet.put(selected, route_pattern_id)

      Component.assign(socket, :bulk_selected, selected)
    else
      socket
    end
  end

  def toggle_bulk_select(socket, _params), do: socket

  @doc """
  Opens the bulk-generation confirmation (step 36, AC-41).

  Counts the selected patterns' missing sections through the batched
  `Gtfs.route_alignment_summary/3` read (step 34, still 5 queries).
  Viewers and an empty selection leave the socket unchanged; a selection
  over 200 sections opens the capped dialog with no confirm action.
  """
  def open_bulk(socket, _params) do
    if bulk_editor?(socket) do
      selected =
        (socket.assigns[:bulk_selected] || MapSet.new())
        |> MapSet.to_list()
        |> Enum.filter(&is_binary/1)
        |> Enum.sort()

      summary =
        Gtfs.route_alignment_summary(
          socket.assigns.current_organization.id,
          socket.assigns.current_gtfs_version.id,
          socket.assigns.route_id
        )

      {total, count} =
        Enum.reduce(selected, {0, 0}, fn route_pattern_id, {total, count} ->
          count_bulk_missing(summary, route_pattern_id, total, count)
        end)

      if total == 0 and count == 0 do
        socket
      else
        Component.assign(socket, :bulk_dialog, bulk_dialog(total, count, selected))
      end
    else
      socket
    end
  end

  defp bulk_dialog(total, _count, _selected) when total > @bulk_section_limit,
    do: %{too_many: true, total: total}

  defp bulk_dialog(total, count, selected),
    do: %{total: total, pattern_count: count, pattern_ids: selected}

  defp count_bulk_missing(summary, route_pattern_id, total, count) do
    case Map.get(summary, route_pattern_id) do
      %{missing: missing} when missing > 0 -> {total + missing, count + 1}
      _ -> {total, count}
    end
  end

  @doc """
  Starts bulk street-path generation (step 36).

  Runs `Gtfs.suggest_missing_alignments/4` under `start_async` so the
  list stays interactive while routing (at most 2 concurrent requests
  server-side). The token lets `handle_bulk_result/3` drop stale
  arrivals after a cancel or a revoked editor. Viewers, a missing
  dialog, an in-flight bulk run and an empty or over-cap selection
  leave the socket unchanged; nothing is written (CR-9).
  """
  def confirm_bulk(socket, _params) do
    with true <- bulk_editor?(socket),
         %{total: total, pattern_ids: pattern_ids}
         when is_list(pattern_ids) and total > 0 and total <= @bulk_section_limit <-
           socket.assigns[:bulk_dialog],
         nil <- socket.assigns[:alignment_bulk] do
      organization_id = socket.assigns.current_organization.id
      version_id = socket.assigns.current_gtfs_version.id
      route_id = socket.assigns.route_id

      socket
      |> Component.assign(:bulk_dialog, nil)
      |> Component.assign(:bulk_result, nil)
      |> Component.assign(:alignment_bulk, %{token: :erlang.make_ref(), pattern_ids: pattern_ids})
      |> Component.assign(:status_message, "Finding street paths…")
      |> Phoenix.LiveView.start_async(@bulk_key, fn ->
        Gtfs.suggest_missing_alignments(organization_id, version_id, route_id, pattern_ids)
      end)
    else
      _ -> socket
    end
  end

  @doc """
  Cancels in-flight bulk generation (step 36).

  Clears the token before `cancel_async`, so a response that already
  left the task is dropped by `handle_bulk_result/3`. Pushes nothing.
  """
  def cancel_bulk(socket, _params) do
    socket
    |> Component.assign(:alignment_bulk, nil)
    |> Component.assign(:status_message, nil)
    |> Phoenix.LiveView.cancel_async(@bulk_key)
  end

  @doc """
  Handles the async bulk street-routing result (step 36).

  A cleared token (cancel) or a revoked editor drops the result, so a
  stale result never suggests paths for another route state and never
  touches the database. Otherwise the per-pattern results render with
  Review actions, successful suggestions wait in `alignment_suggestions`
  for their editor hand-off, and failures keep a draw follow-up.
  Nothing is written (CR-9).

  Returns `{socket, reload?}`: only fresh results need the LiveView to
  re-stream the rows, since the badges live inside the streamed items.
  """
  def handle_bulk_result(socket, _key, {:ok, {:ok, %{patterns: _} = result}}) do
    case bulk_context(socket) do
      {:ok, _bulk} -> {apply_bulk_result(socket, result), true}
      :stale -> {Component.assign(socket, :alignment_bulk, nil), false}
    end
  end

  def handle_bulk_result(socket, _key, {:ok, {:error, :too_many_sections}}) do
    case bulk_context(socket) do
      {:ok, _bulk} ->
        {socket
         |> Component.assign(:alignment_bulk, nil)
         |> Component.assign(
           :status_message,
           "Too many sections selected. Select fewer patterns (limit 200)."
         ), false}

      :stale ->
        {Component.assign(socket, :alignment_bulk, nil), false}
    end
  end

  def handle_bulk_result(socket, _key, _result) do
    case bulk_context(socket) do
      {:ok, _bulk} ->
        {socket
         |> Component.assign(:alignment_bulk, nil)
         |> Component.assign(
           :status_message,
           "Street routing is unavailable. Draw the sections or try again later."
         ), false}

      :stale ->
        {Component.assign(socket, :alignment_bulk, nil), false}
    end
  end

  # A bulk result is live only while its flight is still current, for an
  # editor. Anything else is stale.
  defp bulk_context(socket) do
    with %{token: _} <- socket.assigns[:alignment_bulk],
         true <- bulk_editor?(socket) do
      {:ok, socket.assigns[:alignment_bulk]}
    else
      _ -> :stale
    end
  end

  defp apply_bulk_result(socket, %{patterns: patterns} = result) do
    suggestions =
      patterns
      |> Enum.flat_map(fn {route_pattern_id, entry} ->
        sections =
          entry.suggestions
          |> Enum.sort_by(fn {position, _points} -> position end)
          |> Enum.map(fn {position, points} -> %{position: position, points: points} end)

        if sections == [], do: [], else: [{route_pattern_id, %{sections: sections}}]
      end)
      |> Map.new()

    pending = Map.merge(socket.assigns[:alignment_suggestions] || %{}, suggestions)

    generated = Enum.count(patterns, fn {_id, entry} -> map_size(entry.suggestions) > 0 end)

    socket
    |> Component.assign(:alignment_bulk, nil)
    |> Component.assign(:bulk_result, result)
    |> Component.assign(:alignment_suggestions, pending)
    |> Component.assign(
      :status_message,
      bulk_ready_message(result, generated)
    )
  end

  defp bulk_ready_message(%{generated: generated, total: total}, _pattern_count) do
    if generated == total,
      do: "Suggestions ready. Review each path before saving.",
      else: "#{generated} of #{total} sections generated. Review the suggestions."
  end

  @doc """
  Hands one pattern's bulk suggestions to its Alignment task (step 36).

  Suggestions live in the LiveView process, so the hand-off stays in
  the same process with `push_patch` (no remount drops them). The
  editor's `hook_ready` then embeds them in `alignment:load`, the hook
  applies them as dirty drafts and acks with
  `alignment_suggestions_applied`. Patterns without pending suggestions
  leave the socket unchanged.
  """
  def review_suggestions(socket, %{"pattern-id" => route_pattern_id})
      when is_binary(route_pattern_id) do
    if Map.has_key?(socket.assigns[:alignment_suggestions] || %{}, route_pattern_id) or
         bulk_reviewable?(socket, route_pattern_id) do
      Phoenix.LiveView.push_patch(socket,
        to: "#{patterns_path(socket)}/#{route_pattern_id}?task=alignment"
      )
    else
      socket
    end
  end

  def review_suggestions(socket, _params), do: socket

  # A bulk entry with any routed or failed sections is reviewable even
  # after its suggestions were acked: the editor still needs the draw
  # follow-up for failed sections.
  defp bulk_reviewable?(socket, route_pattern_id) do
    case socket.assigns[:bulk_result] do
      %{patterns: patterns} when is_map(patterns) ->
        case Map.get(patterns, route_pattern_id) do
          %{total: total} when total > 0 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Drops one pattern's pending bulk suggestions after the hook applied
  them as dirty drafts (step 36). The LiveView pipes `assign_dirty`
  after this, so the draft keeps the navigation guard armed.
  """
  def suggestions_applied(socket, %{"route_pattern_id" => route_pattern_id})
      when is_binary(route_pattern_id) do
    Component.assign(
      socket,
      :alignment_suggestions,
      Map.delete(socket.assigns[:alignment_suggestions] || %{}, route_pattern_id)
    )
  end

  def suggestions_applied(socket, _params), do: socket

  # The bulk list needs route-level editing access, not the per-pattern
  # `alignment_editable` model flag (which is false until an Alignment
  # task loads). Fresh membership read like every other write boundary.
  defp bulk_editor?(socket), do: editor_access?(socket)

  @doc """
  Reviews the hook's dirty sections for saving (step 28).

  The hook owns draft geometry (CR-5); it pushes only dirty sections with
  their visit identity, op, points and load-time base. With no choices,
  confirmations or blockers the review applies immediately; otherwise the
  scope dialog opens with "Only this pattern" checked by default.
  Blockers open the blocked dialog with no writes; stale bases open the
  conflict dialog; stale identities show the stale-stops notice. A save
  already in review is ignored so a double submit never queues two saves.
  A save requested while street-path generation is in flight is likewise
  ignored: the review would snapshot pre-generation geometry and the
  arriving suggestion would land as a draft behind it, so the user
  finishes or cancels generation first and then saves once.
  """
  def save_requested(socket, params) when is_map(params) do
    if save_blocked?(socket) do
      push_save_settled(socket)
    else
      draft = save_sections(params)
      audit = save_audit_context(socket)
      pattern = socket.assigns.pattern

      handle_save_request(socket, draft, Gtfs.review_alignment_save(pattern.id, draft, audit))
    end
  end

  def save_requested(socket, _params), do: push_save_settled(socket)

  defp save_blocked?(socket) do
    is_nil(socket.assigns[:alignment]) or is_nil(socket.assigns[:pattern]) or
      not is_nil(socket.assigns[:alignment_pending]) or
      not is_nil(socket.assigns[:alignment_generation])
  end

  defp handle_save_request(socket, draft, {:ok, review}),
    do: handle_save_review(socket, draft, review)

  defp handle_save_request(socket, _draft, {:error, :stale_stops}),
    do: save_notice(socket, :stale_stops)

  defp handle_save_request(socket, draft, {:error, {:conflict, current}}),
    do: open_conflict(socket, draft, current)

  defp handle_save_request(socket, _draft, {:error, {:invalid_draft, _reason}}),
    do: save_notice(socket, :save_error)

  defp handle_save_request(socket, _draft, {:error, :not_found}),
    do: save_notice(socket, {:error, "This pattern is no longer available."})

  @doc """
  Records a scope choice from the save dialog form (step 28).

  Read-only like `draft_state`: the dialog re-renders from the stored
  scopes, and confirming applies them. Unknown positions and values are
  ignored, so a stale form never corrupts the pending review.
  """
  def save_choice(socket, params) when is_map(params) do
    case socket.assigns[:alignment_pending] do
      %{kind: :save, review: review} = pending ->
        scopes = merge_save_scopes(pending.scopes, params, review)
        Component.assign(socket, :alignment_pending, %{pending | scopes: scopes})

      _ ->
        socket
    end
  end

  def save_choice(socket, _params), do: socket

  @doc """
  Applies the pending save review with the dialog's scope choices (step 28).

  Positions without an explicit choice fall back to the stored default
  ("Only this pattern" for scope choices, shared for shared deletions);
  keep-local positions recorded by `conflict_keep_local/2` fill any
  remaining gap as local without overriding an explicit shared choice.
  Confirming a review that names replaced shapes carries
  `confirm_replacements: true` (INV-5: the dialog named each shape and
  trip count before this click).
  """
  def confirm_save(socket, _params) do
    case socket.assigns[:alignment_pending] do
      %{kind: :save, draft: draft, fingerprint: fingerprint, review: review} = pending ->
        forced = socket.assigns[:alignment_forced_local] || []
        scopes = fill_save_scopes(pending.scopes, review, forced)

        choices = %{
          "scopes" => scopes,
          "confirm_replacements" => review.requires_confirmation? == true
        }

        apply_save(socket, draft, choices, fingerprint)

      _ ->
        push_save_settled(socket)
    end
  end

  @doc """
  Cancels the save review: the dialog closes and the hook draft is kept.
  """
  def cancel_save(socket, _params) do
    socket
    |> Component.assign(:alignment_pending, nil)
    |> push_save_settled()
  end

  @doc """
  Discards the conflicted draft and loads the latest saved model (step 28).
  """
  def conflict_load_latest(socket, _params) do
    socket
    |> Component.assign(:alignment_pending, nil)
    |> Component.assign(:alignment_forced_local, [])
    |> Component.assign(:alignment_save_notice, nil)
    |> Component.assign(
      :status_message,
      "Latest shared path loaded. Your draft was discarded."
    )
    |> reload_alignment_model()
  end

  @doc """
  Keeps the conflicted draft as a local draft (step 28).

  Pushes `alignment:rebase` with the latest base revisions so the hook's
  points survive against the newer shared path, and records the
  conflicted positions so the next review auto-selects local scope and
  applies as an override without reopening the scope dialog.
  """
  def conflict_keep_local(socket, _params) do
    case socket.assigns[:alignment_pending] do
      %{kind: :conflict, current: current} = pending ->
        positions = Enum.map(current, & &1.position)
        forced = Enum.uniq((socket.assigns[:alignment_forced_local] || []) ++ positions)

        socket
        |> Component.assign(:alignment_pending, nil)
        |> Component.assign(:alignment_forced_local, forced)
        |> Component.assign(
          :status_message,
          "Draft kept for this pattern. Review and save when ready."
        )
        |> Phoenix.LiveView.push_event("alignment:rebase", %{
          bases: rebase_bases(pending.draft, current)
        })

      _ ->
        push_save_settled(socket)
    end
  end

  @doc "Reloads the alignment model after stops changed (step 28)."
  def reload(socket, _params) do
    socket
    |> Component.assign(:alignment_pending, nil)
    |> Component.assign(:alignment_forced_local, [])
    |> Component.assign(:alignment_save_notice, nil)
    |> Component.assign(
      :status_message,
      "Latest stops loaded. Review the new sections before saving."
    )
    |> reload_alignment_model()
  end

  @doc """
  Clears a stale review so the next Save re-reviews (step 28). The hook
  draft is untouched.
  """
  def review_again(socket, _params) do
    socket
    |> Component.assign(:alignment_pending, nil)
    |> Component.assign(:alignment_save_notice, nil)
    |> push_save_settled()
  end

  defp save_sections(%{"sections" => sections}) when is_list(sections), do: sections
  defp save_sections(%{sections: sections}) when is_list(sections), do: sections
  defp save_sections(_params), do: []

  defp save_audit_context(socket) do
    %GtfsPlanner.Gtfs.AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      station_stop_id: nil,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  # Applies immediately only when every choice is already decided: no
  # blockers, no replaced shapes awaiting confirmation (INV-5), no shared
  # deletion another pattern still uses, and every scope choice covered by
  # a keep-local position. Anything else opens the scope dialog with
  # "Only this pattern" checked by default.
  defp handle_save_review(socket, draft, review) do
    blockers =
      review.blockers ++ Enum.flat_map(review.sections, & &1.shared_blockers)

    if blockers != [] do
      open_blocked(socket, draft, review, blockers)
    else
      forced = socket.assigns[:alignment_forced_local] || []
      scope_positions = for s <- review.sections, s.action == :choose_scope, do: s.position

      delete_positions =
        for s <- review.sections, s.action == :delete_shared and s.affected != [], do: s.position

      open? =
        review.requires_confirmation? or scope_positions -- forced != [] or delete_positions != []

      if open? do
        scopes =
          Map.new(scope_positions, &{to_string(&1), "local"})
          |> Map.merge(Map.new(delete_positions, &{to_string(&1), "shared"}))

        socket
        |> Component.assign(:alignment_pending, %{
          kind: :save,
          draft: draft,
          fingerprint: review.fingerprint,
          review: review,
          scopes: scopes
        })
        |> push_save_settled()
      else
        choices = %{
          "scopes" => Map.new(scope_positions, &{to_string(&1), "local"}),
          "confirm_replacements" => false
        }

        apply_save(socket, draft, choices, review.fingerprint)
      end
    end
  end

  defp open_blocked(socket, draft, review, blockers) do
    socket
    |> Component.assign(:alignment_pending, %{
      kind: :blocked,
      draft: draft,
      fingerprint: nil,
      review: review,
      scopes: %{},
      blockers: blockers
    })
    |> push_save_settled()
  end

  defp open_conflict(socket, draft, current) do
    socket
    |> Component.assign(:alignment_pending, %{kind: :conflict, draft: draft, current: current})
    |> push_save_settled()
  end

  defp save_notice(socket, notice) do
    socket
    |> Component.assign(:alignment_pending, nil)
    |> Component.assign(:alignment_save_notice, notice)
    |> push_save_settled()
  end

  # Merges the dialog form's scope radios into the stored defaults.
  # Only positions the review asks about with a valid value are kept.
  defp merge_save_scopes(stored, params, review) do
    raw =
      case params do
        %{"scopes" => scopes} when is_map(scopes) -> scopes
        %{scopes: scopes} when is_map(scopes) -> scopes
        _ -> %{}
      end

    askable =
      review.sections
      |> Enum.filter(&(&1.action == :choose_scope))
      |> Map.new(&{to_string(&1.position), true})

    Enum.reduce(raw, stored, fn {position, value}, acc ->
      key = to_string(position)

      if Map.has_key?(askable, key) and value in ["local", "shared"] do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  # Fills choices the form never sent: stored defaults first, then
  # keep-local positions as local, without overriding an explicit
  # shared choice.
  defp fill_save_scopes(stored, review, forced) do
    Enum.reduce(review.sections, stored, fn section, acc ->
      fill_save_scope(section, acc, forced)
    end)
  end

  defp fill_save_scope(section, acc, forced) do
    key = to_string(section.position)

    cond do
      needs_local_default?(section, acc, key) ->
        Map.put(acc, key, "local")

      needs_shared_default?(section, acc, key) ->
        Map.put(acc, key, "shared")

      section.action == :choose_scope and section.position in forced and
          Map.get(acc, key) not in ["local", "shared"] ->
        Map.put(acc, key, "local")

      true ->
        acc
    end
  end

  defp needs_local_default?(section, acc, key),
    do: section.action == :choose_scope and not Map.has_key?(acc, key)

  defp needs_shared_default?(section, acc, key),
    do: section.action == :delete_shared and section.affected != [] and not Map.has_key?(acc, key)

  defp apply_save(socket, draft, choices, fingerprint) do
    socket = Component.assign(socket, :applying?, true)
    audit = save_audit_context(socket)
    pattern = socket.assigns.pattern

    case Gtfs.apply_alignment_save(pattern.id, draft, choices, fingerprint, audit) do
      {:ok, result} -> handle_save_result(socket, result)
      {:error, {:conflict, current}} -> handle_apply_conflict(socket, draft, current)
      {:error, :stale_review} -> save_notice(assign_applying(socket, false), :stale_review)
      {:error, {:blocked, blockers}} -> handle_apply_blocked(socket, draft, blockers)
      {:error, :busy} -> save_notice(assign_applying(socket, false), :busy)
      {:error, _reason} -> save_notice(assign_applying(socket, false), :save_error)
    end
  end

  defp assign_applying(socket, value), do: Component.assign(socket, :applying?, value)

  # A successful apply persists the drafts the hook pushed for review, so
  # the server's dirty/flagged mirror is definitionally clean once the fresh
  # model loads. The hook drops its drafts on that load (CR-5) without
  # pushing, so without this reset the badges would read ◷ Unsaved until the
  # next hook gesture. Discard keeps its confirmed-clean handshake (the
  # guards suite pins it); rebase keeps the mirror because the hook keeps
  # its points.
  defp clear_draft_mirror(socket) do
    mirror = %{dirty_positions: [], flagged_positions: []}

    case socket.assigns[:alignment_state] do
      state when is_map(state) ->
        Component.assign(socket, :alignment_state, Map.merge(state, mirror))

      _ ->
        Component.assign(socket, :alignment_state, mirror)
    end
  end

  defp handle_save_result(socket, result) do
    trips = Map.get(result, :trips_updated, 0)

    socket
    |> assign_applying(false)
    |> Component.assign(:alignment_pending, nil)
    |> Component.assign(:alignment_forced_local, [])
    |> Component.assign(:alignment_save_notice, nil)
    |> Component.assign(:status_message, "Alignment saved. #{trips} #{trip_noun(trips)} updated.")
    |> clear_draft_mirror()
    |> reload_alignment_model()
  end

  defp handle_apply_conflict(socket, draft, current) do
    socket
    |> assign_applying(false)
    |> open_conflict(draft, current)
  end

  defp handle_apply_blocked(socket, draft, blockers) do
    review =
      case socket.assigns[:alignment_pending] do
        %{review: review} -> review
        _ -> nil
      end

    socket
    |> assign_applying(false)
    |> open_blocked(draft, review, blockers)
  end

  defp trip_noun(1), do: "trip"
  defp trip_noun(_), do: "trips"

  # Latest base revisions for the drafted positions, so the hook keeps
  # its points against the newer shared path after "Keep as local draft".
  defp rebase_bases(draft, current) do
    revisions = Map.new(current, &{&1.position, &1.revision})

    draft
    |> Enum.map(fn entry -> entry_position(entry) end)
    |> Enum.uniq()
    |> Enum.map(fn position ->
      revision = Map.get(revisions, position, %{segment_id: nil, lock_version: nil})

      %{
        position: position,
        segment_id: revision.segment_id,
        lock_version: revision.lock_version
      }
    end)
  end

  defp entry_position(%{"position" => position}) when is_integer(position), do: position
  defp entry_position(%{position: position}) when is_integer(position), do: position
  defp entry_position(_entry), do: nil

  # Reloads the read model and pushes it to the hook (CR-5): the hook
  # redraws without drafts, and the server badges clear when the hook
  # confirms the clean state, like the discard handshake (step 27).
  defp reload_alignment_model(socket) do
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
        model = Alignments.hook_model(alignment, editable: editable?, suggestions: [])

        socket
        |> Component.assign(:alignment, alignment)
        |> Component.assign(:alignment_state, fresh_state(socket.assigns.alignment_state))
        |> Component.assign(:alignment_editable, editable?)
        |> Component.assign(:alignment_notice, notice_for(alignment, editable?))
        |> Phoenix.LiveView.push_event("alignment:load", %{model: model})

      {:error, :not_found} ->
        socket
    end
  end

  # Releases the hook's in-flight save guard on every path that does not
  # end in alignment:load or alignment:rebase.
  defp push_save_settled(socket),
    do: Phoenix.LiveView.push_event(socket, "alignment:save_settled", %{})

  defp points_noun(1), do: "point"
  defp points_noun(_), do: "points"

  defp parse_tolerance(value) when is_binary(value) do
    case Integer.parse(value) do
      {tolerance, ""} when tolerance > 0 -> {tolerance, ""}
      _ -> :error
    end
  end

  defp parse_tolerance(value) when is_integer(value) and value > 0,
    do: {value, ""}

  defp parse_tolerance(_value), do: :error

  defp editable?(socket), do: socket.assigns[:alignment_editable] == true

  # Same Route › Patterns base the LiveView's own `patterns_path/1` builds;
  # kept local so the list cell never drifts from the router paths.
  defp patterns_path(socket) do
    "/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{socket.assigns.route_id}/patterns"
  end

  defp alignment_dirty?(socket) do
    case socket.assigns[:alignment_state] do
      %{dirty_positions: [_ | _]} -> true
      _ -> false
    end
  end

  defp visit_names(visits, position) do
    from = Enum.find(visits, &(&1.position == position)) || %{}
    to = Enum.find(visits, &(&1.position == position + 1)) || %{}
    %{from: Map.get(from, :name, ""), to: Map.get(to, :name, "")}
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
         |> Component.assign(:alignment_dialog, nil)
         |> Component.assign(:alignment_discard_dialog, nil)
         |> Component.assign(:alignment_delete_dialog, nil)
         |> Component.assign(:alignment_simplify_dialog, nil)
         |> Component.assign(:alignment_import_dialog, nil)
         |> Component.assign(:alignment_generate_dialog, nil)
         |> Component.assign(:alignment_generate_notice, nil)
         |> Component.assign(:alignment_generation, nil)
         |> Phoenix.LiveView.cancel_async(:alignment_generation)
         |> Component.assign(:alignment_follow, nil)
         |> Phoenix.LiveView.cancel_async(:alignment_follow)
         |> Component.assign(:alignment_pending, nil)
         |> Component.assign(:alignment_save_notice, nil)
         |> Component.assign(:alignment_forced_local, [])}

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
