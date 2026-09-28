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

  @doc "Closes the help, discard, delete, simplify, import and save dialogs."
  def close_dialogs(socket) do
    socket
    |> Component.assign(:alignment_dialog, nil)
    |> Component.assign(:alignment_discard_dialog, nil)
    |> Component.assign(:alignment_delete_dialog, nil)
    |> Component.assign(:alignment_simplify_dialog, nil)
    |> Component.assign(:alignment_import_dialog, nil)
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

  @doc """
  Reviews the hook's dirty sections for saving (step 28).

  The hook owns draft geometry (CR-5); it pushes only dirty sections with
  their visit identity, op, points and load-time base. With no choices,
  confirmations or blockers the review applies immediately; otherwise the
  scope dialog opens with "Only this pattern" checked by default.
  Blockers open the blocked dialog with no writes; stale bases open the
  conflict dialog; stale identities show the stale-stops notice. A save
  already in review is ignored so a double submit never queues two saves.
  """
  def save_requested(socket, params) when is_map(params) do
    cond do
      is_nil(socket.assigns[:alignment]) or is_nil(socket.assigns[:pattern]) ->
        push_save_settled(socket)

      not is_nil(socket.assigns[:alignment_pending]) ->
        push_save_settled(socket)

      true ->
        draft = save_sections(params)
        audit = save_audit_context(socket)
        pattern = socket.assigns.pattern

        case Gtfs.review_alignment_save(pattern.id, draft, audit) do
          {:ok, review} ->
            handle_save_review(socket, draft, review)

          {:error, :stale_stops} ->
            save_notice(socket, :stale_stops)

          {:error, {:conflict, current}} ->
            open_conflict(socket, draft, current)

          {:error, {:invalid_draft, _reason}} ->
            save_notice(socket, :save_error)

          {:error, :not_found} ->
            save_notice(socket, {:error, "This pattern is no longer available."})
        end
    end
  end

  def save_requested(socket, _params), do: push_save_settled(socket)

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
      key = to_string(section.position)

      cond do
        section.action == :choose_scope and not Map.has_key?(acc, key) ->
          Map.put(acc, key, "local")

        section.action == :delete_shared and section.affected != [] and
            not Map.has_key?(acc, key) ->
          Map.put(acc, key, "shared")

        section.action == :choose_scope and section.position in forced and
            Map.get(acc, key) not in ["local", "shared"] ->
          Map.put(acc, key, "local")

        true ->
          acc
      end
    end)
  end

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
