defmodule GtfsPlannerWeb.Gtfs.RoutePatternLive do
  @moduledoc """
  LiveView for the route pattern editor.

  It renders the route's Patterns list, the creation flow and the pattern
  Stops/Timings/Alignment/Details tasks from the scoped
  `GtfsPlanner.Gtfs.RoutePatterns` reads. The Alignment task renders the
  server-side workspace from `Gtfs.alignment_editor/4` (sections, statuses
  and export state); map drawing and saving arrive in later steps. Every identifier used for a write comes from a loaded
  server record: the route and pattern are resolved from the URL inside the
  loaded organization/version scope, and a pattern or timing from another scope
  resolves to `not_found`. Access uses the existing editor guard, and a lost
  database connection renders as unavailable reading with an explicit retry.

  Structural and timing edits are staged here and only ever applied through the
  reviewed `Gtfs.review/4` → `Gtfs.apply_review/4` path. The affected counts the
  review dialogs show come from the review result, and every added-stop value has
  to be acknowledged per timing before the final apply is enabled.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.RoutePatternAlignmentComponents
  alias GtfsPlannerWeb.Gtfs.RoutePatternAlignmentEvents
  alias GtfsPlannerWeb.Gtfs.RoutePatternComponents
  alias LiveSelect.Component, as: LiveSelectComponent

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # Mount-time access is not enough: these events can write pattern/timing data,
  # so each one re-checks the actor's current organization membership at the
  # server mutation boundary.
  @editor_write_events ~w(
    build_patterns save_details apply_details_review create_pattern
    save_stops update_review_value acknowledge_review_timing refresh_review
    retry_review apply_stop_review save_timing apply_timing_review
    refresh_timing_review retry_timing_review confirm_timing_dialog
    confirm_delete_timing copy_pattern confirm_delete_pattern
    alignment_save_requested confirm_alignment_save alignment_conflict_keep_local
  )

  @detail_fields ~w(name direction_id headsign time_desc typicality sort_order)
  @creation_defaults %{
    "name" => "",
    "direction_id" => "0",
    "headsign" => "",
    "time_desc" => "",
    "typicality" => "0",
    "sort_order" => ""
  }
  @default_preview "08:00"
  @search_idle "Type a stop name or stop ID to search this version’s stops."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Patterns")
     |> assign(:editor_revoked?, false)
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:route, nil)
     |> assign(:route_id, nil)
     |> assign(:pattern_id, nil)
     |> assign(:loaded_pattern_id, :none)
     |> assign(:load_state, :loading)
     |> assign(:stale?, false)
     |> assign(:patterns_empty?, true)
     |> assign(:pattern_count, 0)
     |> assign(:route_trip_count, 0)
     |> assign(:pending_trip_count, 0)
     |> assign(:custom_trip_count, 0)
     |> assign(:derivation_error, nil)
     |> assign(:build_state, :idle)
     |> assign(:build_error, nil)
     |> assign(:task, :stops)
     |> assign(:pattern, nil)
     |> assign(:occurrences, [])
     |> assign(:stops, %{})
     |> assign(:stop_count, 0)
     |> assign(:detail_trip_count, 0)
     |> assign(:detail_custom_trip_count, 0)
     |> assign(:timings, [])
     |> assign(:selected_timing, nil)
     |> assign(:selected_timing_id, nil)
     |> assign(:selected_timing_rows, [])
     |> assign(:source_fingerprint, nil)
     |> assign(:timing_options, [])
     |> assign(:timing_form, to_form(%{}))
     |> assign(:stop_choices, [])
     |> assign(:staged_occurrences, [])
     |> assign(:staged_key_seq, 0)
     |> assign(:stops_dirty?, false)
     |> assign(:stop_search_options, [])
     |> assign(:stop_search_results, [])
     |> assign(:stop_search_truncated?, false)
     |> assign(:stop_search_status, @search_idle)
     |> assign(:stop_search_form, stop_search_form())
     |> assign(:insert_after, "")
     |> assign(:insert_form, insert_form(""))
     |> assign(:timing_rows, [])
     |> assign(:timing_edits, %{})
     |> assign(:timing_headsign_edits, %{})
     |> assign(:timing_headsign, "")
     |> assign(:preview_time, @default_preview)
     |> assign(:timing_error, nil)
     |> assign(:review, nil)
     |> assign(:timing_dialog, nil)
     |> assign(:blocked_dialog, nil)
     |> assign(:timing_delete_dialog, nil)
     |> assign(:pattern_delete_dialog, nil)
     |> assign(:offline?, false)
     |> assign(:applying?, false)
     |> assign(:alignment, nil)
     |> assign(
       :alignment_state,
       %{
         dirty_positions: [],
         selected: 1,
         mode: "pan",
         selected_point_count: 0,
         point_count: 0,
         can_undo: false,
         can_redo: false,
         flagged_positions: [],
         review_positions: []
       }
     )
     |> assign(:alignment_dialog, nil)
     |> assign(:alignment_discard_dialog, nil)
     |> assign(:alignment_delete_dialog, nil)
     |> assign(:alignment_simplify_dialog, nil)
     |> assign(:alignment_import_dialog, nil)
     |> assign(:alignment_notice, nil)
     |> assign(:alignment_pending, nil)
     |> assign(:alignment_save_notice, nil)
     |> assign(:alignment_forced_local, [])
     |> assign(:alignment_editable, false)
     |> assign(:details_params, @creation_defaults)
     |> assign(:details_baseline, nil)
     |> assign(:details_form, details_form(@creation_defaults, []))
     |> assign(:dirty?, false)
     |> assign(:impact_dialog, nil)
     |> assign(:pending_navigation, nil)
     |> assign(:details_stale?, false)
     |> assign(:error_message, nil)
     |> assign(:status_message, nil)
     |> stream(:patterns, [])
     |> attach_hook(:editor_write_gate, :handle_event, &editor_write_gate/3)}
  end

  defp editor_write_gate(event, _params, socket) do
    if event in @editor_write_events and not editor_access?(socket) do
      {:halt, revoke_editor_access(socket)}
    else
      {:cont, socket}
    end
  end

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

  # A lost role or membership renders unavailable editing and closes every open
  # confirmation, so nothing is committed through a connection that was opened
  # while the actor still had access.
  defp revoke_editor_access(socket) do
    socket
    |> assign(:editor_revoked?, true)
    |> assign(:applying?, false)
    |> assign(:review, nil)
    |> assign(:timing_dialog, nil)
    |> assign(:timing_delete_dialog, nil)
    |> assign(:pattern_delete_dialog, nil)
    |> assign(:blocked_dialog, nil)
    |> assign(:impact_dialog, nil)
    |> assign(:status_message, nil)
    |> assign(:alignment_pending, nil)
    |> assign(:alignment_save_notice, nil)
    |> assign(:alignment_forced_local, [])
    |> assign(:alignment_import_dialog, nil)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action
    pattern_id = params["route_pattern_id"]
    timing_id = params["timing"]

    socket =
      socket
      |> assign(:route_id, params["route_id"])
      |> assign(:pattern_id, pattern_id)
      |> assign(:task, resolve_task(action, params["task"]))

    socket =
      cond do
        not connected?(socket) ->
          assign(socket, :load_state, :loading)

        reload_needed?(socket, pattern_id, timing_id) ->
          load_screen(socket, timing_id)

        true ->
          socket
      end

    case RoutePatternAlignmentEvents.ensure_loaded(socket) do
      {:ok, socket} -> {:noreply, socket}
      {:error, :not_found} -> {:noreply, not_found(socket)}
    end
  end

  @impl true
  def handle_event("reload_patterns", _params, socket) do
    {:noreply,
     socket
     |> assign(:editor_revoked?, not editor_access?(socket))
     |> load_screen()}
  end

  @impl true
  def handle_event("build_patterns", _params, socket) do
    socket = assign(socket, :build_state, :building)

    result = Gtfs.build_route_patterns(socket.assigns.route_id, audit_context(socket))

    case result do
      {:ok, summary} ->
        {:noreply,
         socket
         |> assign(:build_state, :idle)
         |> put_build_summary(summary)
         |> load_screen()}

      {:error, :nothing_pending} ->
        {:noreply, socket |> assign(:build_state, :blocked) |> load_screen()}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:build_state, :failed)
         |> assign(:build_error, build_error_message(reason))
         |> load_screen()}
    end
  end

  # --- details ---------------------------------------------------------------

  @impl true
  def handle_event("validate_details", %{"pattern" => params}, socket) do
    params = merge_details_params(socket.assigns.details_params, params)

    {:noreply,
     socket
     |> assign(:details_params, params)
     |> assign(:details_form, details_form(params, []))
     |> assign_dirty()}
  end

  def handle_event("validate_details", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_details", %{"pattern" => params}, socket) do
    params = merge_details_params(socket.assigns.details_params, params)

    case validate_details(params) do
      {:ok, attrs} ->
        socket
        |> assign(:details_params, params)
        |> assign(:details_form, details_form(params, []))
        |> review_details(attrs)

      {:error, errors, message} ->
        {:noreply, reject_details(socket, params, errors, message)}
    end
  end

  def handle_event("save_details", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("apply_details_review", _params, socket) do
    case socket.assigns.impact_dialog do
      %{attrs: attrs, fingerprint: fingerprint} ->
        socket |> assign(:impact_dialog, nil) |> apply_details(attrs, fingerprint)

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_details_review", _params, socket) do
    {:noreply, assign(socket, :impact_dialog, nil)}
  end

  # --- creation --------------------------------------------------------------

  @impl true
  def handle_event("create_pattern", params, socket) when is_map(params) do
    params =
      merge_details_params(socket.assigns.details_params, Map.get(params, "pattern", %{}))

    with :ok <- validate_staged_stops(socket.assigns.staged_occurrences),
         {:ok, attrs} <- validate_details(params) do
      attrs = Map.put(attrs, :stops, Enum.map(socket.assigns.staged_occurrences, & &1.stop_id))

      case Gtfs.create_pattern(socket.assigns.route_id, attrs, audit_context(socket)) do
        {:ok, pattern} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Pattern created with its first timing. Set its running times next."
           )
           |> push_navigate(to: pattern_path(socket, pattern.route_pattern_id, "?task=timings"))}

        {:error, reason} ->
          {:noreply, reject_creation(socket, params, reason)}
      end
    else
      {:error, message} when is_binary(message) ->
        {:noreply, reject_creation_stops(socket, params, message)}

      {:error, errors, message} ->
        {:noreply, reject_details(socket, params, errors, message)}
    end
  end

  def handle_event("create_pattern", _params, socket), do: {:noreply, socket}

  # --- stop search and staging ----------------------------------------------

  @impl true
  def handle_event("live_select_change", %{"id" => id, "text" => text}, socket) do
    case Gtfs.search_pattern_stops(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           text
         ) do
      {:ok, %{stops: stops, truncated?: truncated?}} ->
        options = Enum.map(stops, &%{label: &1.stop_name, value: &1.stop_id})
        send_update(LiveSelectComponent, id: id, options: options, hide_dropdown: false)

        {:noreply,
         socket
         |> assign(:stop_search_options, options)
         |> assign(:stop_search_results, stops)
         |> assign(:stop_search_truncated?, truncated?)
         |> assign(:stop_search_status, search_status(text, stops))}

      {:error, :unavailable} ->
        send_update(LiveSelectComponent, id: id, options: [], hide_dropdown: false)

        {:noreply,
         socket
         |> assign(:stop_search_options, [])
         |> assign(:stop_search_results, [])
         |> assign(:stop_search_truncated?, false)
         |> assign(:stop_search_status, "Stop search is temporarily unavailable. Try again.")}
    end
  end

  def handle_event("live_select_change", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_insert_after", %{"insert" => %{"insert_after" => value}}, socket) do
    value = to_string(value)

    {:noreply, socket |> assign(:insert_after, value) |> assign(:insert_form, insert_form(value))}
  end

  def handle_event("set_insert_after", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("choose_stop", params, socket) when is_map(params) do
    stop_id = params["stop_id"] || get_in(params, ["stop_search", "stop_id"]) || ""

    case resolve_stop(socket, stop_id) do
      nil when stop_id in [nil, ""] -> {:noreply, socket}
      nil -> {:noreply, assign(socket, :error_message, "Choose a stop from the search results.")}
      stop -> {:noreply, stage_stop(socket, stop)}
    end
  end

  def handle_event("choose_stop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("move_stop", %{"index" => index, "direction" => direction}, socket) do
    with {position, ""} <- Integer.parse(to_string(index)),
         {delta, ""} <- Integer.parse(to_string(direction)),
         true <- delta in [-1, 1] do
      move_staged_stop(socket, position, position + delta)
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("move_stop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("remove_stop", %{"index" => index}, socket) do
    case Integer.parse(to_string(index)) do
      {position, ""} -> remove_staged_stop(socket, position)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("remove_stop", _params, socket), do: {:noreply, socket}

  # --- stop review and apply ------------------------------------------------

  @impl true
  def handle_event("save_stops", _params, socket) do
    case stop_save_blocker(socket) do
      nil ->
        socket = assign(socket, :error_message, nil)

        case validate_staged_stops(socket.assigns.staged_occurrences) do
          :ok -> start_stop_review(socket)
          {:error, message} -> reject_editor(socket, message, "pattern-save-stops")
        end

      message ->
        reject_editor(socket, message, nil)
    end
  end

  @impl true
  def handle_event("acknowledge_review_timing", %{"timing_id" => timing_id}, socket) do
    case socket.assigns.review do
      %{kind: :stops} = review ->
        acks =
          if MapSet.member?(review.acks, timing_id),
            do: MapSet.delete(review.acks, timing_id),
            else: MapSet.put(review.acks, timing_id)

        {:noreply, put_stop_review(socket, %{review | acks: acks})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("acknowledge_review_timing", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "update_review_value",
        %{"review" => values, "_target" => [_root, timing_id | _rest]},
        socket
      )
      when is_map(values) do
    case socket.assigns.review do
      %{kind: :stops} = review ->
        # A changed value invalidates that timing's acknowledgement and the
        # review fingerprint, so the reviewer has to confirm the new value.
        review = %{
          review
          | values: values,
            acks: MapSet.delete(review.acks, timing_id),
            fingerprint: nil,
            error: nil
        }

        refresh_stop_review(socket, review)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("update_review_value", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("apply_stop_review", _params, socket) do
    case socket.assigns.review do
      %{kind: :stops} = review when review != nil ->
        if stop_review_ready?(review, socket) do
          apply_stop_operation(socket, review)
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_review", _params, socket) do
    {:noreply, assign(socket, :review, nil)}
  end

  @impl true
  def handle_event("refresh_review", _params, socket) do
    case socket.assigns.review do
      %{kind: :stops} = review ->
        # Refresh the loaded source but keep every staged edit, so a stale
        # review is re-run against the current values instead of silently
        # accepting new counts.
        socket = socket |> load_screen() |> assign(:error_message, nil)
        refresh_stop_review(socket, %{review | acks: MapSet.new(), fingerprint: nil})

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_review", _params, socket) do
    case socket.assigns.review do
      %{kind: :stops} = review ->
        refresh_stop_review(socket, %{review | error: nil})

      _ ->
        {:noreply, socket}
    end
  end

  # --- timings ---------------------------------------------------------------

  @impl true
  def handle_event("switch_task", %{"task" => task}, socket) do
    resolved = resolve_task(socket.assigns.live_action, task)

    if socket.assigns.task == :alignment and resolved != :alignment and
         alignment_dirty?(socket) do
      # An unsaved alignment draft blocks task switches the same way other
      # editor guards do: stash the task path and reuse the existing
      # discard dialog instead of patching away the draft.
      {:noreply, assign(socket, :pending_navigation, task_path(socket, resolved))}
    else
      {:noreply,
       socket
       |> assign(:task, resolved)
       |> assign(:error_message, nil)
       |> push_patch(to: task_path(socket, resolved))}
    end
  end

  @impl true
  def handle_event("alignment_select_section", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.select_section(socket, params)}
  end

  @impl true
  def handle_event("alignment_hook_ready", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.hook_ready(socket, params)}
  end

  @impl true
  def handle_event("alignment_map_error", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.map_error(socket, params)}
  end

  @impl true
  def handle_event("alignment_map_ok", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.map_ok(socket, params)}
  end

  @impl true
  def handle_event("alignment_retry_tiles", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.retry_tiles(socket, params)}
  end

  @impl true
  def handle_event("alignment_open_help", _params, socket) do
    {:noreply, RoutePatternAlignmentEvents.set_dialog(socket, :help)}
  end

  @impl true
  def handle_event("alignment_draft_state", params, socket) do
    {:noreply,
     socket
     |> RoutePatternAlignmentEvents.draft_state(params)
     |> assign_dirty()}
  end

  @impl true
  def handle_event("alignment_close_help", _params, socket) do
    {:noreply, RoutePatternAlignmentEvents.set_dialog(socket, nil)}
  end

  @impl true
  def handle_event("alignment_close_dialog", _params, socket) do
    {:noreply, RoutePatternAlignmentEvents.close_dialogs(socket)}
  end

  @impl true
  def handle_event("alignment_open_discard", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.open_discard(socket, params)}
  end

  @impl true
  def handle_event("alignment_confirm_discard", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.confirm_discard(socket, params)}
  end

  @impl true
  def handle_event("alignment_open_delete", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.open_delete(socket, params)}
  end

  @impl true
  def handle_event("alignment_confirm_delete", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.confirm_delete(socket, params)}
  end

  @impl true
  def handle_event("alignment_open_simplify", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.open_simplify(socket, params)}
  end

  @impl true
  def handle_event("alignment_simplify_tolerance", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.simplify_tolerance(socket, params)}
  end

  @impl true
  def handle_event("alignment_confirm_simplify", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.confirm_simplify(socket, params)}
  end

  @impl true
  def handle_event("alignment_open_import", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.open_import(socket, params)}
  end

  @impl true
  def handle_event("alignment_import_choice", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.import_choice(socket, params)}
  end

  @impl true
  def handle_event("alignment_confirm_import", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.confirm_import(socket, params)}
  end

  @impl true
  def handle_event("alignment_simplify_result", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.simplify_result(socket, params)}
  end

  @impl true
  def handle_event("alignment_action_notice", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.action_notice(socket, params)}
  end

  @impl true
  def handle_event("alignment_save_requested", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.save_requested(socket, params)}
  end

  @impl true
  def handle_event("alignment_save_choice", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.save_choice(socket, params)}
  end

  @impl true
  def handle_event("confirm_alignment_save", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.confirm_save(socket, params)}
  end

  @impl true
  def handle_event("alignment_cancel_save", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.cancel_save(socket, params)}
  end

  @impl true
  def handle_event("alignment_conflict_load_latest", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.conflict_load_latest(socket, params)}
  end

  @impl true
  def handle_event("alignment_conflict_keep_local", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.conflict_keep_local(socket, params)}
  end

  @impl true
  def handle_event("alignment_reload", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.reload(socket, params)}
  end

  @impl true
  def handle_event("alignment_review_again", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.review_again(socket, params)}
  end

  @impl true
  def handle_event("select_timing", %{"timing_id" => timing_id}, socket) do
    if timing_id == socket.assigns.selected_timing_id do
      {:noreply, socket}
    else
      {:noreply, socket |> load_screen(timing_id) |> put_timing_rows()}
    end
  end

  def handle_event("select_timing", _params, socket), do: {:noreply, socket}

  # The timing editor posts one form; `_target` names the control the operator
  # changed, so only that field is marked as edited and every other staged value
  # (including a stored nil attribute) is preserved.
  @impl true
  def handle_event(
        "validate_timing_row",
        %{"_target" => ["timing", position, field]} = params,
        socket
      ) do
    validate_timing_row_change(socket, position, field, params["timing"] || %{})
  end

  def handle_event("validate_timing_row", %{"_target" => ["timing_headsign"]} = params, socket) do
    change_timing_headsign(socket, params)
  end

  def handle_event("validate_timing_row", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("preview_timing", %{"preview_time" => value}, socket) do
    {:noreply, socket |> assign(:preview_time, to_string(value)) |> put_timing_rows()}
  end

  def handle_event("preview_timing", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_timing", _params, socket) do
    case selected_timing_operation(socket) do
      {:error, [], :no_changes} ->
        {:noreply, annotate(socket, "No changes to save.")}

      {:error, rows, message} ->
        {:noreply,
         socket
         |> put_timing_rows(rows)
         |> assign(:timing_error, message)
         |> assign(:error_message, message)
         |> push_event("focus_form_error", %{
           form_id: "timing-form",
           fallback_id: first_invalid_field(rows) || "timing-save"
         })}

      {:ok, attrs} ->
        review_timing(socket, attrs)
    end
  end

  @impl true
  def handle_event("apply_timing_review", _params, socket) do
    case socket.assigns.review do
      %{kind: :timing} = review ->
        socket = assign(socket, :applying?, true)

        case Gtfs.apply_review(
               pattern_uuid(socket),
               review.operation,
               review.fingerprint,
               audit_context(socket)
             ) do
          {:ok, %{trips_updated: updated}} ->
            {:noreply, saved(socket, affected_message(updated), timing_scope(review.operation))}

          {:error, reason} ->
            {:noreply, timing_review_failure(socket, review, reason)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh_timing_review", _params, socket) do
    case socket.assigns.review do
      %{kind: :timing, operation: {:timing, _timing_id, attrs}} ->
        # Refresh the loaded source but keep the submitted rows, so a stale
        # review is re-run against the current values and counts instead of
        # silently reusing an old fingerprint.
        socket
        |> load_screen()
        |> assign(:applying?, false)
        |> assign(:error_message, nil)
        |> review_timing(attrs, true)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_timing_review", _params, socket) do
    case socket.assigns.review do
      %{kind: :timing, operation: {:timing, _timing_id, attrs}} -> review_timing(socket, attrs)
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_timing_review", _params, socket) do
    {:noreply, assign(socket, :review, nil)}
  end

  @impl true
  def handle_event("discard_timing_drafts", _params, socket) do
    {:noreply,
     socket
     |> assign(:timing_edits, %{})
     |> assign(:timing_headsign_edits, %{})
     |> assign(:error_message, nil)
     |> put_timing_rows()
     |> assign_dirty()}
  end

  @impl true
  def handle_event("guard_editor_navigation", %{"path" => path}, socket) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
      do: guard_navigation(socket, path),
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_details_review", _params, socket) do
    socket =
      socket |> load_screen() |> assign(:error_message, nil) |> assign(:details_stale?, false)

    case validate_details(socket.assigns.details_params) do
      {:ok, attrs} ->
        submit_details_review(socket, attrs)

      {:error, errors, message} ->
        {:noreply, reject_details(socket, socket.assigns.details_params, errors, message)}
    end
  end

  # --- timing CRUD -----------------------------------------------------------

  @impl true
  def handle_event("open_timing_dialog", %{"mode" => mode}, socket)
      when mode in ["add", "rename"] do
    dialog = %{
      mode: if(mode == "add", do: :add, else: :rename),
      name: if(mode == "rename", do: timing_name(socket), else: ""),
      source_timing_id: "",
      source_options: timing_source_options(socket),
      error: nil
    }

    {:noreply, assign(socket, :timing_dialog, dialog)}
  end

  def handle_event("open_timing_dialog", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate_timing_dialog", params, socket) do
    case socket.assigns.timing_dialog do
      nil ->
        {:noreply, socket}

      dialog ->
        dialog =
          dialog
          |> Map.put(:name, Map.get(params, "name", dialog.name))
          |> Map.put(
            :source_timing_id,
            Map.get(params, "source_timing_id", dialog.source_timing_id)
          )
          |> Map.put(:error, nil)

        {:noreply, assign(socket, :timing_dialog, dialog)}
    end
  end

  @impl true
  def handle_event("close_timing_dialog", _params, socket) do
    {:noreply, assign(socket, :timing_dialog, nil)}
  end

  @impl true
  def handle_event("confirm_timing_dialog", _params, socket) do
    case socket.assigns.timing_dialog do
      nil ->
        {:noreply, socket}

      dialog ->
        confirm_timing_dialog(socket, dialog)
    end
  end

  @impl true
  def handle_event("open_delete_timing", _params, socket) do
    case socket.assigns.selected_timing do
      nil ->
        {:noreply, socket}

      timing ->
        case Gtfs.review(
               pattern_uuid(socket),
               {:delete_timing, timing.id},
               socket.assigns.source_fingerprint,
               audit_context(socket)
             ) do
          {:ok, %{fingerprint: fingerprint}} ->
            {:noreply,
             assign(socket, :timing_delete_dialog, %{
               timing_id: timing.id,
               name: timing.name,
               fingerprint: fingerprint
             })}

          {:error, :last_timing} ->
            blocked(
              socket,
              "Keep this timing",
              "A pattern needs at least one timing. Add another timing first."
            )

          {:error, :timing_in_use} ->
            blocked(
              socket,
              "Keep this timing",
              "#{timing_trip_label(socket, timing)}. Trip assignment and removal are outside this interface. Copy the pattern to work on separate service."
            )

          {:error, reason} ->
            reject_editor(socket, reasons_message(reason), "timing-delete")
        end
    end
  end

  @impl true
  def handle_event("confirm_delete_timing", _params, socket) do
    case socket.assigns.timing_delete_dialog do
      nil ->
        {:noreply, socket}

      %{timing_id: timing_id, fingerprint: fingerprint} ->
        case Gtfs.apply_review(
               pattern_uuid(socket),
               {:delete_timing, timing_id},
               fingerprint,
               audit_context(socket)
             ) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(:timing_delete_dialog, nil)
             |> saved("Timing deleted.", {:timing, timing_id})}

          {:error, reason} ->
            socket
            |> assign(:timing_delete_dialog, nil)
            |> reject_editor(reasons_message(reason), "timing-delete")
        end
    end
  end

  @impl true
  def handle_event("close_blocked_dialog", _params, socket) do
    {:noreply,
     socket
     |> assign(:blocked_dialog, nil)
     |> assign(:timing_delete_dialog, nil)
     |> assign(:pattern_delete_dialog, nil)}
  end

  # --- pattern lifecycle -----------------------------------------------------

  @impl true
  def handle_event("copy_pattern", _params, socket) do
    case reviewed_apply(socket, :copy, nil) do
      {:ok, %{pattern: copied}} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Pattern copied with its stops and timings. No trips were copied."
         )
         |> push_navigate(to: pattern_path(socket, copied.route_pattern_id, "?task=stops"))}

      {:error, reason} ->
        reject_editor(socket, reasons_message(reason), "pattern-copy")
    end
  end

  @impl true
  def handle_event("open_delete_pattern", _params, socket) do
    case reviewed_apply_review_only(socket, :delete) do
      {:ok, %{fingerprint: fingerprint}} ->
        {:noreply,
         assign(socket, :pattern_delete_dialog, %{
           name: pattern_label(socket),
           fingerprint: fingerprint
         })}

      {:error, :pattern_in_use} ->
        blocked(
          socket,
          "This pattern is in use",
          "#{trip_count_text(socket.assigns.detail_trip_count)} still #{trip_verb(socket.assigns.detail_trip_count)} this pattern. Trip assignment and removal are outside this interface. Copy the pattern to work on separate service."
        )

      {:error, reason} ->
        reject_editor(socket, reasons_message(reason), "pattern-delete")
    end
  end

  @impl true
  def handle_event("confirm_delete_pattern", _params, socket) do
    case socket.assigns.pattern_delete_dialog do
      nil ->
        {:noreply, socket}

      %{fingerprint: fingerprint} ->
        case Gtfs.apply_review(pattern_uuid(socket), :delete, fingerprint, audit_context(socket)) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(:pattern_delete_dialog, nil)
             |> put_flash(:info, "Pattern deleted.")
             |> push_navigate(to: patterns_path(socket))}

          {:error, reason} ->
            socket
            |> assign(:pattern_delete_dialog, nil)
            |> reject_editor(reasons_message(reason), "pattern-delete")
        end
    end
  end

  # --- navigation and connectivity ------------------------------------------

  @impl true
  def handle_event("open_pattern", %{"pattern-id" => pattern_id}, socket) do
    guard_navigation(socket, pattern_path(socket, pattern_id, "?task=stops"))
  end

  @impl true
  def handle_event("back_to_patterns", _params, socket) do
    guard_navigation(socket, patterns_path(socket))
  end

  @impl true
  def handle_event("discard_changes", _params, socket) do
    case socket.assigns.pending_navigation do
      nil -> {:noreply, socket}
      path -> {:noreply, push_navigate(socket, to: path)}
    end
  end

  @impl true
  def handle_event("keep_editing", _params, socket) do
    {:noreply, assign(socket, :pending_navigation, nil)}
  end

  @impl true
  def handle_event("editor_offline", _params, socket) do
    {:noreply, assign(socket, :offline?, true)}
  end

  @impl true
  def handle_event("editor_reconnected", _params, socket) do
    {:noreply,
     socket
     |> assign(:offline?, false)
     |> annotate("Reconnected. Your edits are ready to save.")}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    handle_version_switch(socket, version_id)
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    handle_version_switch(socket, version_id)
  end

  defp handle_version_switch(socket, version_id) do
    organization_id = socket.assigns.current_organization.id
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(organization_id, version_id) do
      path =
        case socket.assigns.live_action do
          :new -> version_patterns_path(socket, version_id) <> "/new"
          :show -> version_patterns_path(socket, version_id)
          _ -> version_patterns_path(socket, version_id)
        end

      if socket.assigns.dirty? do
        {:noreply, assign(socket, :pending_navigation, path)}
      else
        socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
        {:noreply, push_navigate(socket, to: path)}
      end
    else
      {:noreply, socket}
    end
  end

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <:sub_header :if={@route}>
        <.route_sub_nav
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:patterns}
        />
      </:sub_header>

      <div
        id="pattern-editor"
        phx-hook="RoutePatternEditor"
        data-dirty={to_string(@dirty?)}
        data-offline={to_string(@offline?)}
        class="mt-8"
      >
        <div id="pattern-editor-content" phx-hook="FormErrorFocus">
          <RoutePatternComponents.status_regions
            error={@error_message}
            status={@status_message}
          />

          <%= cond do %>
            <% @load_state == :loading -> %>
              <.skeleton id="patterns-loading" label="Loading patterns" rows={3} aria-busy="true" />
            <% @load_state == :unavailable -> %>
              <div id="patterns-unavailable" class="mt-2">
                <.callout kind="error" title="Patterns unavailable">
                  This route’s patterns could not be loaded. The rest of the app is unaffected.
                  <button
                    id="patterns-retry"
                    type="button"
                    phx-click="reload_patterns"
                    class="btn btn-sm btn-outline mt-2 min-h-11"
                  >
                    Retry
                  </button>
                </.callout>
              </div>
            <% @editor_revoked? -> %>
              <div id="pattern-editor-revoked" class="mt-2">
                <.callout kind="error" title="Editing unavailable">
                  Your editing access to this organization was removed, so this page can no
                  longer change patterns, timings or stops. Ask an administrator to restore the
                  editor role, then reload.
                  <button
                    id="pattern-editor-reload"
                    type="button"
                    phx-click="reload_patterns"
                    class="btn btn-sm btn-outline mt-2 min-h-11"
                  >
                    Reload
                  </button>
                </.callout>
              </div>
            <% @load_state == :ready and @live_action == :index -> %>
              <RoutePatternComponents.pattern_list_states
                patterns={@streams.patterns}
                patterns_empty?={@patterns_empty?}
                pattern_count={@pattern_count}
                route_trip_count={@route_trip_count}
                pending_trip_count={@pending_trip_count}
                custom_trip_count={@custom_trip_count}
                derivation_error={@derivation_error}
                build_state={@build_state}
                build_error={@build_error}
                stale?={@stale?}
                new_path={"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns/new"}
              />
            <% @load_state == :ready -> %>
              <%= if @pattern || @live_action == :new do %>
                <RoutePatternComponents.pattern_detail_header
                  creating={@live_action == :new}
                  pattern_name={
                    if(@pattern,
                      do: @pattern.route_pattern_name || @pattern.route_pattern_id,
                      else: ""
                    )
                  }
                  direction_id={header_direction_id(assigns)}
                  stop_count={
                    if @live_action == :new, do: length(@staged_occurrences), else: @stop_count
                  }
                  trip_count={if @live_action == :new, do: 0, else: @detail_trip_count}
                  task={@task}
                  tasks={
                    if(@live_action == :new,
                      do: [:details, :stops],
                      else: [:stops, :timings, :alignment, :details]
                    )
                  }
                  dirty?={@dirty?}
                  version_name={@current_gtfs_version.name}
                  show_actions={@live_action == :show}
                />

                <RoutePatternComponents.connectivity_banner offline?={@offline?} />
                <button
                  :if={@details_stale?}
                  id="details-refresh-review"
                  type="button"
                  phx-click="refresh_details_review"
                  class="btn btn-outline min-h-11"
                >
                  Refresh review
                </button>
                <button
                  :if={
                    @task == :stops and
                      (map_size(@timing_edits) > 0 or map_size(@timing_headsign_edits) > 0)
                  }
                  id="discard-timing-drafts"
                  type="button"
                  phx-click="discard_timing_drafts"
                  class="btn btn-outline min-h-11"
                >
                  Discard timing edits
                </button>

                <%= cond do %>
                  <% @task == :details -> %>
                    <RoutePatternComponents.details_task
                      form={@details_form}
                      submit_event={
                        if(@live_action == :new, do: "create_pattern", else: "save_details")
                      }
                      submit_label={
                        if(@live_action == :new, do: "Create pattern", else: "Save details")
                      }
                      pattern_id={if @pattern, do: @pattern.route_pattern_id, else: nil}
                      dirty?={@dirty?}
                    />
                  <% @task == :stops -> %>
                    <RoutePatternComponents.stops_task
                      creating={@live_action == :new}
                      stop_rows={stop_rows(assigns)}
                      custom_trip_count={detail_custom_trip_count(assigns)}
                      trip_count={if @live_action == :new, do: 0, else: @detail_trip_count}
                      timing_count={max(length(@timings), 1)}
                      reorderable?={reorderable?(assigns)}
                      dirty?={@stops_dirty? or (@live_action == :new and @staged_occurrences != [])}
                      search_form={@stop_search_form}
                      search_options={@stop_search_options}
                      search_status={@stop_search_status}
                      search_truncated?={@stop_search_truncated?}
                      insert_form={@insert_form}
                      busy?={@applying? or @offline?}
                    />
                  <% @task == :alignment -> %>
                    <%= if @alignment do %>
                      <RoutePatternAlignmentComponents.alignment_task
                        alignment={@alignment}
                        state={@alignment_state}
                        notice={@alignment_notice}
                        dialog_open={@alignment_dialog == :help}
                        editable?={@alignment_editable}
                        offline?={@offline?}
                        applying?={@applying?}
                        pending={@alignment_pending}
                        save_notice={@alignment_save_notice}
                        version_name={@current_gtfs_version.name}
                        organization_name={@current_organization.name}
                        delete_dialog={@alignment_delete_dialog}
                        discard_dialog={@alignment_discard_dialog}
                        simplify_dialog={@alignment_simplify_dialog}
                        import_dialog={@alignment_import_dialog}
                      />
                    <% else %>
                      <.skeleton
                        id="alignment-loading"
                        label="Loading alignment"
                        rows={3}
                        aria-busy="true"
                      />
                    <% end %>
                  <% true -> %>
                    <RoutePatternComponents.timings_task
                      timings={@timings}
                      selected_timing={@selected_timing}
                      timing_rows={@timing_rows}
                      timing_form={@timing_form}
                      timing_options={@timing_options}
                      preview_time={@preview_time}
                      timing_headsign={@timing_headsign}
                      custom_trip_count={@detail_custom_trip_count}
                      dirty?={@timing_rows != [] and map_size(@timing_edits) > 0}
                      busy?={@applying? or @offline?}
                    />
                <% end %>
              <% else %>
                <div id="pattern-not-found" class="mt-2">
                  <.callout kind="error" title="Pattern not found">
                    This pattern does not belong to the selected route and version.
                  </.callout>
                </div>
              <% end %>
            <% true -> %>
              <div id="patterns-unavailable" class="mt-2">
                <.callout kind="error" title="Patterns unavailable">
                  This route’s patterns could not be loaded.
                </.callout>
              </div>
          <% end %>
        </div>

        <RoutePatternComponents.stop_review_dialog
          review={stop_review(@review)}
          confirm_label={stop_review_confirm_label(stop_review(@review))}
          ready?={stop_review_ready_assigns?(assigns)}
          requires_acknowledgement?={stop_review_requires_ack?(assigns)}
          version_name={@current_gtfs_version.name}
        />

        <RoutePatternComponents.timing_review_dialog
          review={timing_review(@review)}
          version_name={@current_gtfs_version.name}
        />

        <RoutePatternComponents.timing_dialog dialog={@timing_dialog} />

        <RoutePatternComponents.timing_delete_dialog dialog={@timing_delete_dialog} />

        <RoutePatternComponents.pattern_delete_dialog dialog={@pattern_delete_dialog} />

        <RoutePatternComponents.blocked_dialog dialog={@blocked_dialog} />

        <.confirm_dialog
          id="details-impact-dialog"
          open={@impact_dialog != nil}
          title={impact_title(@impact_dialog)}
          confirm_label="Update trips"
          pending_label="Updating…"
          on_confirm="apply_details_review"
          on_cancel="cancel_details_review"
          described_by="details-impact-dialog-body"
          confirm_variant="primary"
        >
          <p>
            Saving this pattern updates the trips below.
            <strong>This changes {@current_gtfs_version.name}, a published version.</strong>
          </p>
        </.confirm_dialog>

        <.confirm_dialog
          id="discard-changes-dialog"
          open={@pending_navigation != nil}
          title="Discard unsaved changes?"
          confirm_label="Discard changes"
          cancel_label="Keep editing"
          pending_label="Discarding…"
          on_confirm="discard_changes"
          on_cancel="keep_editing"
          described_by="discard-changes-dialog-body"
        >
          <p>
            Your unsaved changes were not saved. Keeping editing keeps them on this page.
          </p>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  # --- loading ---------------------------------------------------------------

  defp reload_needed?(socket, pattern_id, timing_id) do
    socket.assigns.load_state != :ready or
      socket.assigns.loaded_pattern_id != pattern_id or
      (not is_nil(timing_id) and timing_id != socket.assigns.selected_timing_id)
  end

  defp load_screen(socket, timing_id \\ nil) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    opts = [
      pattern_id: socket.assigns.pattern_id,
      timing_id: timing_id || socket.assigns.selected_timing_id,
      include_stop_choices: socket.assigns.live_action == :new
    ]

    case Gtfs.load_route_pattern_screen(organization_id, version_id, route_id, opts) do
      {:ok, screen} -> apply_screen(socket, screen)
      {:error, :not_found} -> not_found(socket)
      {:error, :timing_not_found} -> timing_not_found(socket)
      {:error, :unavailable} -> unavailable(socket)
    end
  end

  # A timing outside the loaded pattern is refused without leaking the other
  # pattern's data, and the page falls back to the pattern's first timing.
  defp timing_not_found(socket) do
    socket
    |> assign(:error_message, "That timing is not part of this pattern.")
    |> assign(:selected_timing_id, nil)
    |> load_screen()
  end

  defp apply_screen(socket, screen) do
    previous_pattern_id = socket.assigns.loaded_pattern_id

    socket =
      socket
      |> assign(:route, screen.route)
      |> assign(:patterns_empty?, screen.patterns == [])
      |> assign(:pattern_count, length(screen.patterns))
      |> assign(
        :route_trip_count,
        screen.pending_trip_count + screen.custom_trip_count + screen.linked_trip_count
      )
      |> assign(:pending_trip_count, screen.pending_trip_count)
      |> assign(:custom_trip_count, screen.custom_trip_count)
      |> assign(:derivation_error, screen.derivation_error)
      |> assign(:stop_choices, screen.stop_choices)
      |> assign(:load_state, :ready)
      |> assign(:stale?, false)
      |> stream(:patterns, screen.patterns, reset: true)
      |> apply_detail(screen.detail, previous_pattern_id)

    assign_dirty(socket)
  end

  defp apply_detail(socket, nil, _previous_pattern_id) do
    socket
    |> assign(:loaded_pattern_id, nil)
    |> assign(:pattern, nil)
    |> assign(:occurrences, [])
    |> assign(:stops, %{})
    |> assign(:stop_count, 0)
    |> assign(:detail_trip_count, 0)
    |> assign(:detail_custom_trip_count, 0)
    |> assign(:timings, [])
    |> assign(:selected_timing, nil)
    |> assign(:selected_timing_id, nil)
    |> assign(:selected_timing_rows, [])
    |> assign(:source_fingerprint, nil)
    |> assign(:timing_options, [])
    |> reset_editing_state()
  end

  defp apply_detail(socket, detail, previous_pattern_id) do
    pattern = detail.pattern
    selected = detail.selected_timing

    socket =
      socket
      |> assign(:loaded_pattern_id, pattern.route_pattern_id)
      |> assign(:pattern, pattern)
      |> assign(:occurrences, detail.occurrences)
      |> assign(:stops, detail.stops)
      |> assign(:stop_count, detail.stop_count)
      |> assign(:detail_trip_count, detail.trip_count)
      |> assign(:detail_custom_trip_count, Map.get(detail, :custom_trip_count, 0))
      |> assign(:timings, detail.timings)
      |> assign(:selected_timing, selected)
      |> assign(:selected_timing_id, selected && selected.id)
      |> assign(:selected_timing_rows, detail.selected_timing_rows)
      |> assign(:source_fingerprint, detail.source_fingerprint)
      |> assign(:timing_options, timing_options(detail.timings))

    if previous_pattern_id == pattern.route_pattern_id do
      socket
      |> refresh_selected_timing()
      |> put_timing_rows()
    else
      params = details_params_from_pattern(pattern)

      socket
      |> put_details(params, params)
      |> reset_editing_state()
    end
  end

  # A completed save only drops the draft it saved. Unrelated staged stop edits
  # and other timings' drafts stay on the page until the operator saves or
  # explicitly discards them; a creation load or pattern switch drops everything.
  defp reset_editing_state(socket, {:timing, timing_id}) do
    socket
    |> assign(:timing_edits, Map.delete(socket.assigns.timing_edits, timing_id))
    |> assign(:timing_headsign_edits, Map.delete(socket.assigns.timing_headsign_edits, timing_id))
    |> assign(:timing_error, nil)
    |> assign(:review, nil)
    |> assign(:applying?, false)
    |> put_timing_rows()
  end

  defp reset_editing_state(socket, :timing_add) do
    socket
    |> assign(:timing_dialog, nil)
    |> assign(:review, nil)
    |> assign(:applying?, false)
    |> put_timing_rows()
  end

  defp reset_editing_state(socket, :details) do
    params = details_params_from_pattern(socket.assigns.pattern)

    socket
    |> put_details(params, params)
    |> assign(:review, nil)
    |> assign(:applying?, false)
    |> put_timing_rows()
  end

  defp reset_editing_state(socket, :stops) do
    socket
    |> assign(:staged_occurrences, loaded_occurrences(socket.assigns.occurrences))
    |> assign(:stops_dirty?, false)
    |> assign(:review, nil)
    |> assign(:applying?, false)
    |> put_timing_rows()
  end

  defp reset_editing_state(socket) do
    socket
    |> assign(:staged_occurrences, loaded_occurrences(socket.assigns.occurrences))
    |> assign(:staged_key_seq, 0)
    |> assign(:stops_dirty?, false)
    |> assign(:timing_edits, %{})
    |> assign(:timing_headsign_edits, %{})
    |> assign(:timing_rows, [])
    |> assign(:timing_headsign, timing_headsign(socket))
    |> assign(:preview_time, @default_preview)
    |> assign(:timing_error, nil)
    |> assign(:review, nil)
    |> assign(:timing_dialog, nil)
    |> assign(:blocked_dialog, nil)
    |> assign(:timing_delete_dialog, nil)
    |> assign(:pattern_delete_dialog, nil)
    |> assign(:applying?, false)
    |> assign(:stop_search_options, [])
    |> assign(:stop_search_results, [])
    |> assign(:stop_search_truncated?, false)
    |> assign(:stop_search_status, @search_idle)
    |> assign(:stop_search_form, stop_search_form())
    |> assign(:insert_after, "")
    |> assign(:insert_form, insert_form(""))
    |> put_timing_rows()
  end

  defp loaded_occurrences(occurrences) do
    Enum.map(occurrences, fn occurrence ->
      %{key: nil, id: occurrence.id, stop_id: occurrence.stop_id}
    end)
  end

  defp refresh_selected_timing(socket) do
    timing_id = socket.assigns.selected_timing_id

    if timing_id && Map.has_key?(socket.assigns.timing_edits, timing_id) do
      socket
    else
      assign(
        socket,
        :timing_headsign,
        Map.get(socket.assigns.timing_headsign_edits, timing_id, timing_headsign(socket))
      )
    end
  end

  defp timing_headsign(socket) do
    case socket.assigns.selected_timing do
      %{headsign: headsign} when is_binary(headsign) -> headsign
      _ -> ""
    end
  end

  # A creation load never discards staged input: the page keeps whatever the
  # editor has already entered until the pattern is created.
  defp not_found(socket) do
    version_id = socket.assigns.current_gtfs_version.id

    case socket.assigns.live_action do
      :index ->
        socket
        |> put_flash(:error, "Route not found")
        |> push_navigate(to: "/gtfs/#{version_id}/routes")

      _ ->
        socket
        |> put_flash(:error, "Pattern not found")
        |> push_navigate(to: patterns_path(socket))
    end
  end

  defp unavailable(socket) do
    if socket.assigns.load_state == :ready do
      assign(socket, :stale?, true)
    else
      socket
      |> assign(:load_state, :unavailable)
      |> stream(:patterns, [], reset: true)
    end
  end

  # --- details ---------------------------------------------------------------

  defp review_details(socket, attrs) do
    attrs = changed_attrs(socket.assigns.pattern, attrs)

    if attrs == %{} do
      {:noreply, annotate(socket, "No changes to save.")}
    else
      submit_details_review(socket, attrs)
    end
  end

  defp submit_details_review(socket, attrs, confirm? \\ false) do
    audit = audit_context(socket)

    case Gtfs.review(
           pattern_uuid(socket),
           {:details, attrs},
           socket.assigns.source_fingerprint,
           audit
         ) do
      {:ok, %{fingerprint: fingerprint, impact: %{trips_affected: affected}}}
      when affected > 0 or confirm? ->
        {:noreply,
         assign(socket, :impact_dialog, %{
           attrs: attrs,
           fingerprint: fingerprint,
           trips_affected: affected
         })}

      {:ok, %{fingerprint: fingerprint}} ->
        apply_details(socket, attrs, fingerprint)

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:details_stale?, reason == :stale_review)
         |> assign(:error_message, reasons_message(reason))}
    end
  end

  # Only attributes that differ from the loaded pattern are submitted, so an
  # unchanged direction never asks for an impact review and the review
  # fingerprint describes the change the user actually made.
  defp changed_attrs(%RoutePattern{} = pattern, attrs) do
    attrs
    |> Enum.reject(fn {field, value} -> Map.get(pattern, field) == value end)
    |> Map.new()
  end

  defp changed_attrs(_pattern, attrs), do: attrs

  defp apply_details(socket, attrs, fingerprint) do
    audit = audit_context(socket)

    case Gtfs.apply_review(pattern_uuid(socket), {:details, attrs}, fingerprint, audit) do
      {:ok, %{trips_updated: updated}} ->
        {:noreply, saved(socket, affected_message(updated), :details)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:details_stale?, reason == :stale_review)
         |> assign(:error_message, reasons_message(reason))}
    end
  end

  defp reject_details(socket, params, errors, message) do
    socket
    |> assign(:details_params, params)
    |> assign(:details_form, details_form(params, errors))
    |> assign(:error_message, message)
    |> assign(:task, :details)
    |> push_event("focus_form_error", %{form_id: "pattern-details-form", fallback_id: nil})
  end

  defp reject_creation(socket, params, reason) do
    {errors, message} = creation_rejection(reason)

    socket
    |> assign(:details_params, params)
    |> assign(:details_form, details_form(params, errors))
    |> assign(:error_message, message)
    |> assign(:task, if(reason == :at_least_two_stops, do: :stops, else: :details))
    |> push_event("focus_form_error", %{form_id: "pattern-details-form", fallback_id: nil})
  end

  defp reject_creation_stops(socket, params, message) do
    socket
    |> assign(:details_params, params)
    |> assign(:details_form, details_form(params, []))
    |> assign(:error_message, message)
    |> assign(:task, :stops)
  end

  defp creation_rejection(:at_least_two_stops) do
    {[], "Add at least two stops before creating the pattern."}
  end

  defp creation_rejection(:adjacent_duplicate_stops) do
    {[], "This stop is already next to that position. Remove one of them."}
  end

  defp creation_rejection(:invalid_input) do
    {[], "The submitted values could not be saved. Check the form and try again."}
  end

  defp creation_rejection(%Ecto.Changeset{} = changeset) do
    {changeset_errors(changeset), changeset_message(changeset)}
  end

  defp creation_rejection(other), do: {[], reasons_message(other)}

  defp merge_details_params(current, incoming) when is_map(incoming) do
    Enum.reduce(@detail_fields, current, fn field, acc ->
      case Map.fetch(incoming, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp merge_details_params(current, _incoming), do: current

  defp validate_details(params) do
    with {:ok, name} <- require_name(params),
         {:ok, direction_id} <- parse_direction(params),
         {:ok, typicality} <- parse_typicality(params),
         {:ok, order} <- parse_sort_order(params) do
      {:ok,
       %{
         route_pattern_name: name,
         direction_id: direction_id,
         headsign: blank_to_nil(params["headsign"]),
         route_pattern_time_desc: blank_to_nil(params["time_desc"]),
         route_pattern_typicality: typicality,
         route_pattern_sort_order: order
       }}
    else
      {:error, field, message} -> {:error, [{field, message}], message}
    end
  end

  defp require_name(params) do
    case params["name"] do
      name when is_binary(name) ->
        if String.trim(name) == "",
          do: {:error, :name, "Enter a pattern name."},
          else: {:ok, String.trim(name)}

      _ ->
        {:error, :name, "Enter a pattern name."}
    end
  end

  defp parse_direction(params) do
    case params["direction_id"] do
      "0" -> {:ok, 0}
      "1" -> {:ok, 1}
      0 -> {:ok, 0}
      1 -> {:ok, 1}
      _ -> {:error, :direction_id, "Choose direction 0 or direction 1."}
    end
  end

  defp parse_typicality(params) do
    case params["typicality"] do
      value when value in ["0", "1", "2", "3", "4", "5"] -> {:ok, String.to_integer(value)}
      value when value in [0, 1, 2, 3, 4, 5] -> {:ok, value}
      _ -> {:error, :typicality, "Choose a use on this route from the list."}
    end
  end

  defp parse_sort_order(params) do
    case params["sort_order"] do
      value when value in [nil, ""] ->
        {:ok, nil}

      value ->
        case to_string(value) |> Integer.parse() do
          {order, ""} when order >= 0 -> {:ok, order}
          _ -> {:error, :sort_order, "Use a whole number of zero or more."}
        end
    end
  end

  # --- staged stops ----------------------------------------------------------

  defp validate_staged_stops(occurrences) do
    stop_ids = Enum.map(occurrences, & &1.stop_id)

    cond do
      length(stop_ids) < 2 ->
        {:error, "Add at least two stops before saving."}

      Enum.any?(Enum.chunk_every(stop_ids, 2, 1, :discard), fn [a, b] -> a == b end) ->
        {:error, "This stop is already next to that position. Remove one of them."}

      true ->
        :ok
    end
  end

  defp stop_edit_blocker(socket) do
    cond do
      socket.assigns.live_action == :new ->
        nil

      socket.assigns.detail_custom_trip_count > 0 ->
        "These trips keep their imported stop times, so this stop list cannot change. Copy the pattern to work on separate service."

      true ->
        nil
    end
  end

  defp resolve_stop(socket, stop_id) when is_binary(stop_id) and stop_id != "" do
    Enum.find(socket.assigns.stop_search_results, &(&1.stop_id == stop_id)) ||
      Enum.find(socket.assigns.stop_choices, &(&1.stop_id == stop_id)) ||
      lookup_eligible_stop(socket, stop_id)
  end

  defp resolve_stop(_socket, _stop_id), do: nil

  defp lookup_eligible_stop(socket, stop_id) do
    case Gtfs.search_pattern_stops(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           stop_id
         ) do
      {:ok, %{stops: stops}} -> Enum.find(stops, &(&1.stop_id == stop_id))
      _ -> nil
    end
  end

  defp stage_stop(socket, stop) do
    occurrences = socket.assigns.staged_occurrences
    index = insert_index(socket.assigns.insert_after, length(occurrences))
    left = if index > 0, do: Enum.at(occurrences, index - 1), else: nil
    right = Enum.at(occurrences, index)

    if (left != nil and left.stop_id == stop.stop_id) or
         (right != nil and right.stop_id == stop.stop_id) do
      assign(socket, :error_message, "This stop is already next to that position.")
    else
      sequence = socket.assigns.staged_key_seq + 1
      entry = %{key: "new-#{sequence}", id: nil, stop_id: stop.stop_id}
      occurrences = List.insert_at(occurrences, index, entry)

      send_update(LiveSelectComponent, id: "pattern-stop-search", options: [], value: nil)

      socket
      |> assign(:staged_occurrences, occurrences)
      |> assign(:staged_key_seq, sequence)
      |> assign(:stops, Map.put(socket.assigns.stops, stop.stop_id, stop))
      |> assign(:stop_search_form, stop_search_form())
      |> assign(:stop_search_options, [])
      |> assign(:stop_search_results, [])
      |> assign(:stop_search_truncated?, false)
      |> assign(:stop_search_status, @search_idle)
      |> assign(:error_message, nil)
      |> assign_stops_dirty()
      |> assign_dirty()
    end
  end

  defp insert_index(value, length) do
    case Integer.parse(to_string(value || "")) do
      {index, ""} when index >= 1 -> min(index, length)
      {index, ""} when index <= -1 -> 0
      _ -> length
    end
  end

  defp move_staged_stop(socket, position, target) do
    occurrences = socket.assigns.staged_occurrences

    cond do
      socket.assigns.detail_custom_trip_count > 0 ->
        reject_editor(
          socket,
          "These trips keep their imported stop times, so this stop list cannot change. Copy the pattern to work on separate service.",
          nil
        )

      socket.assigns.live_action == :show and socket.assigns.detail_trip_count > 0 ->
        reject_editor(socket, "Copy the pattern to change the stop order.", nil)

      position < 1 or position > length(occurrences) ->
        {:noreply, socket}

      target < 1 or target > length(occurrences) ->
        {:noreply, socket}

      true ->
        occurrences = swap(occurrences, position - 1, target - 1)

        {:noreply,
         socket
         |> assign(:staged_occurrences, occurrences)
         |> assign(:error_message, nil)
         |> assign_stops_dirty()
         |> assign_dirty()
         |> push_event("route_pattern_focus", %{id: "pattern-stop-#{target}"})}
    end
  end

  defp swap(list, left, right) do
    list
    |> List.replace_at(left, Enum.at(list, right))
    |> List.replace_at(right, Enum.at(list, left))
  end

  defp remove_staged_stop(socket, position) do
    cond do
      socket.assigns.detail_custom_trip_count > 0 and socket.assigns.live_action == :show ->
        reject_editor(
          socket,
          "These trips keep their imported stop times, so this stop list cannot change. Copy the pattern to work on separate service.",
          nil
        )

      position < 1 or position > length(socket.assigns.staged_occurrences) ->
        {:noreply, socket}

      true ->
        occurrences = List.delete_at(socket.assigns.staged_occurrences, position - 1)

        {:noreply,
         socket
         |> assign(:staged_occurrences, occurrences)
         |> assign(:error_message, nil)
         |> assign_stops_dirty()
         |> assign_dirty()}
    end
  end

  defp assign_stops_dirty(socket) do
    assign(socket, :stops_dirty?, staged_stops_dirty?(socket))
  end

  defp staged_stops_dirty?(socket) do
    staged =
      Enum.map(socket.assigns.staged_occurrences, &{&1.id, &1.stop_id})

    loaded =
      Enum.map(socket.assigns.occurrences, &{&1.id, &1.stop_id})

    staged != loaded
  end

  # --- stop review -----------------------------------------------------------

  defp stop_save_blocker(socket) do
    if socket.assigns.stops_dirty? and
         (map_size(socket.assigns.timing_edits) > 0 or
            map_size(socket.assigns.timing_headsign_edits) > 0) do
      "Save your timing edits before changing stops, or discard timing edits below. Your stop edits are still here."
    else
      stop_edit_blocker(socket)
    end
  end

  defp start_stop_review(socket) do
    review = %{
      kind: :stops,
      values: %{},
      acks: MapSet.new(),
      proposed: %{},
      impact: %{trips_affected: 0},
      fingerprint: nil,
      error: nil,
      busy: false
    }

    refresh_stop_review(socket, review)
  end

  defp refresh_stop_review(socket, review) do
    operation = stop_operation(socket, review.values, review.acks)

    case Gtfs.preview_stop_edit(pattern_uuid(socket), operation, audit_context(socket)) do
      {:ok, %{proposed: proposed, impact: impact}} ->
        review = %{
          review
          | proposed: proposed,
            impact: impact,
            error: nil,
            busy: false,
            fingerprint: nil
        }

        socket = socket |> assign(:error_message, nil) |> put_stop_review(review)

        if impact.trips_affected == 0 and stop_review_ready?(socket.assigns.review, socket) do
          apply_stop_operation(socket, socket.assigns.review)
        else
          {:noreply, socket}
        end

      {:error, :explicit_terminal_values_required} ->
        {:noreply,
         put_stop_review(socket, %{
           review
           | error: %{
               message:
                 "Enter arrival and departure for the added end stop in every timing, then review again.",
               action: :retry
             }
         })}

      {:error, reason} ->
        {:noreply,
         put_stop_review(socket, %{
           review
           | error: %{message: reasons_message(reason), action: :retry}
         })}
    end
  end

  defp put_stop_review(socket, review) do
    assign(socket, :review, Map.put(review, :blocks, stop_review_blocks(socket, review)))
  end

  defp stop_review_blocks(socket, review) do
    proposed = review.proposed || %{}
    rows_by_timing = Map.new(Map.get(proposed, :timing_rows, []), &{&1.timing_id, &1.rows})
    estimates = Map.get(proposed, :estimates, []) || []

    # Added stops come from the staged list, not from a successful proposal: a
    # terminal insertion needs its arrival/departure inputs rendered before any
    # proposal can exist, so staff can supply the values it asks for.
    added =
      socket.assigns.staged_occurrences
      |> Enum.with_index()
      |> Enum.filter(fn {occurrence, _index} -> is_nil(occurrence.id) end)

    Enum.map(socket.assigns.timings, fn %{timing: timing, trip_count: trip_count} ->
      rows = Map.get(rows_by_timing, timing.id, [])
      supplied = Map.get(review.values, timing.id, %{})

      shift =
        Enum.find_value(Map.get(proposed, :start_shifts, []), 0, fn item ->
          if item.timing_id == timing.id, do: item.start_shift
        end)

      %{
        timing_id: timing.id,
        name: timing.name,
        trip_count_label: trip_count_text(trip_count),
        shift: shift_label(Map.get(proposed, :start_shifts, []), timing.id),
        acknowledged: MapSet.member?(review.acks, timing.id),
        added:
          Enum.map(added, fn {occurrence, index} ->
            row = Enum.at(rows, index) || %{}
            values = Map.get(supplied, occurrence.key, %{})

            %{
              invalid?: invalid_review_values?(values),
              key: occurrence.key,
              name: stop_name(socket.assigns.stops, occurrence.stop_id),
              arrival:
                values["arrival"] ||
                  raw_review_offset(row[:arrival_offset], shift),
              departure:
                values["departure"] ||
                  raw_review_offset(row[:departure_offset], shift),
              estimated?:
                values == %{} and
                  Enum.any?(estimates, &(&1[:key] == occurrence.key))
            }
          end)
      }
    end)
  end

  defp invalid_review_values?(values) when map_size(values) == 0, do: false

  defp invalid_review_values?(values),
    do: not Enum.all?(["arrival", "departure"], &is_integer(elapsed_seconds(values[&1])))

  defp raw_review_offset(value, shift) when is_integer(value), do: offset_input(value + shift)
  defp raw_review_offset(_value, _shift), do: ""

  defp shift_label(shifts, timing_id) when is_list(shifts) do
    case Enum.find(shifts, &(Map.get(&1, :timing_id) == timing_id)) do
      %{start_shift: shift} when is_integer(shift) and shift != 0 -> GtfsTime.format_offset(shift)
      _ -> nil
    end
  end

  defp shift_label(_shifts, _timing_id), do: nil

  defp stop_review_ready?(review, socket), do: stop_review_ready_assigns?(socket.assigns, review)

  # A removal-only edit adds no stop values, so it needs no acknowledgement; an
  # added stop on a used pattern does, because applying it changes trips.
  defp stop_review_ready_assigns?(assigns, review \\ nil) do
    review = review || assigns.review

    case review do
      %{kind: :stops, error: nil} ->
        cond do
          Map.get(review.impact || %{}, :trips_affected, 0) == 0 -> true
          not stop_review_requires_ack?(assigns, review) -> true
          true -> Enum.all?(Map.get(review, :blocks, []), & &1.acknowledged)
        end

      _ ->
        false
    end
  end

  defp stop_review_requires_ack?(assigns, review \\ nil) do
    proposes_added_stop?(review || assigns.review) and assigns.detail_trip_count > 0
  end

  defp proposes_added_stop?(%{proposed: proposed}) do
    proposed
    |> Kernel.||(%{})
    |> Map.get(:occurrences, [])
    |> Enum.any?(&is_nil(&1.id))
  end

  defp proposes_added_stop?(_review), do: false

  defp stop_review_confirm_label(%{kind: :stops} = review) do
    if Map.get(review.impact, :trips_affected, 0) > 0, do: "Update trips", else: "Save stops"
  end

  defp stop_review_confirm_label(_review), do: "Update trips"

  defp stop_operation(socket, values, acks) do
    {:stops, stop_entries(socket), reviewed_values(socket, values, acks)}
  end

  defp stop_entries(socket) do
    Enum.map(socket.assigns.staged_occurrences, fn occurrence ->
      if occurrence.id,
        do: %{id: occurrence.id, stop_id: occurrence.stop_id},
        else: %{key: occurrence.key, stop_id: occurrence.stop_id}
    end)
  end

  defp reviewed_values(socket, values, acks) do
    Enum.reduce(socket.assigns.timings, %{}, fn %{timing: timing}, acc ->
      entry =
        socket
        |> supplied_values(values, timing.id)
        |> Map.put(:acknowledged, MapSet.member?(acks, timing.id))

      Map.put(acc, timing.id, entry)
    end)
  end

  defp supplied_values(_socket, values, timing_id) do
    values
    |> Map.get(timing_id, %{})
    |> Enum.reduce(%{}, fn {key, fields}, acc ->
      arrival = elapsed_seconds(fields["arrival"])
      departure = elapsed_seconds(fields["departure"])

      Map.put(acc, key, %{arrival_offset: arrival, departure_offset: departure})
    end)
  end

  defp apply_stop_operation(socket, review) do
    socket = assign(socket, :applying?, true)
    operation = stop_operation(socket, review.values, review.acks)

    case Gtfs.review(
           pattern_uuid(socket),
           operation,
           socket.assigns.source_fingerprint,
           audit_context(socket)
         ) do
      {:ok, %{fingerprint: fingerprint}} ->
        case Gtfs.apply_review(
               pattern_uuid(socket),
               operation,
               fingerprint,
               audit_context(socket)
             ) do
          {:ok, %{trips_updated: updated}} ->
            {:noreply, saved(socket, affected_message(updated), :stops)}

          {:error, reason} ->
            {:noreply, stop_review_failure(socket, review, reason)}
        end

      {:error, reason} ->
        {:noreply, stop_review_failure(socket, review, reason)}
    end
  end

  defp stop_review_failure(socket, review, :stale_review) do
    put_stop_review(assign(socket, :applying?, false), %{
      review
      | error: %{
          message:
            "This pattern changed since you reviewed it. Refresh the review to see the current values and counts; your edits are still here.",
          action: :refresh
        }
    })
  end

  defp stop_review_failure(socket, review, reason) do
    put_stop_review(assign(socket, :applying?, false), %{
      review
      | error: %{message: reasons_message(reason), action: :retry}
    })
  end

  # --- timings ---------------------------------------------------------------

  defp base_timing_rows(socket) do
    timing_id = socket.assigns.selected_timing_id

    case timing_id && Map.get(socket.assigns.timing_edits, timing_id) do
      rows when is_list(rows) -> rows
      _ -> loaded_timing_rows(socket)
    end
  end

  defp loaded_timing_rows(socket) do
    Enum.map(socket.assigns.selected_timing_rows, fn row ->
      %{
        position: row.position,
        stop_id: row.stop_id,
        name: stop_name(socket.assigns.stops, row.stop_id),
        arrival: offset_input(row.arrival_offset),
        departure: offset_input(row.departure_offset),
        timepoint: row.timepoint == 1,
        pickup:
          if(is_integer(row.pickup_type), do: Integer.to_string(row.pickup_type), else: "0"),
        drop_off:
          if(is_integer(row.drop_off_type), do: Integer.to_string(row.drop_off_type), else: "0"),
        stop_headsign: row.stop_headsign || "",
        stored: %{
          timepoint: row.timepoint,
          pickup_type: row.pickup_type,
          drop_off_type: row.drop_off_type,
          stop_headsign: row.stop_headsign
        },
        touched: MapSet.new(),
        arrival_error: nil,
        departure_error: nil
      }
    end)
  end

  defp put_timing_edits(socket, rows) do
    timing_id = socket.assigns.selected_timing_id

    if timing_id do
      assign(socket, :timing_edits, Map.put(socket.assigns.timing_edits, timing_id, rows))
    else
      socket
    end
  end

  defp put_timing_rows(socket, rows \\ nil) do
    rows = rows || base_timing_rows(socket)

    socket
    |> assign(:timing_rows, Enum.map(rows, &with_preview(&1, socket.assigns.preview_time)))
    |> assign(
      :timing_headsign,
      Map.get(socket.assigns.timing_headsign_edits, socket.assigns.selected_timing_id) ||
        timing_headsign(socket)
    )
  end

  defp change_timing_headsign(socket, params) do
    case params["timing_headsign"] do
      value when is_binary(value) ->
        timing_id = socket.assigns.selected_timing_id

        socket =
          socket
          |> assign(
            :timing_headsign_edits,
            Map.put(socket.assigns.timing_headsign_edits, timing_id, value)
          )
          |> assign(:timing_headsign, value)

        {:noreply, assign_dirty(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp validate_timing_row_change(socket, position, field, params) do
    with {index, ""} <- Integer.parse(to_string(position)),
         rows when is_list(rows) <- base_timing_rows(socket),
         true <- Enum.any?(rows, &(&1.position == index)) do
      rows =
        rows
        |> Enum.map(&merge_row_params(&1, params))
        |> Enum.map(&mark_row_touched(&1, index, field))

      {:noreply,
       socket
       |> put_timing_edits(rows)
       |> put_timing_rows()
       |> assign(:timing_error, nil)
       |> assign_dirty()}
    else
      _ -> {:noreply, socket}
    end
  end

  defp mark_row_touched(row, index, field) do
    if row.position == index,
      do: %{row | touched: MapSet.put(row.touched, field_atom(field))},
      else: row
  end

  # The form posts every row input, so a row that is present in the params takes
  # its posted values and a row that is absent keeps the staged one.
  defp merge_row_params(row, params) do
    case Map.get(params, Integer.to_string(row.position)) do
      nil ->
        row

      values ->
        %{
          row
          | arrival: Map.get(values, "arrival", row.arrival),
            departure: Map.get(values, "departure", row.departure),
            pickup: Map.get(values, "pickup", row.pickup),
            drop_off: Map.get(values, "drop_off", row.drop_off),
            stop_headsign: Map.get(values, "headsign", row.stop_headsign),
            timepoint: Map.get(values, "timepoint") == "1"
        }
    end
  end

  defp with_preview(row, preview) do
    Map.merge(row, %{
      preview_arrival: preview_label(preview, elapsed_seconds(row.arrival)),
      preview_departure: preview_label(preview, elapsed_seconds(row.departure))
    })
  end

  defp elapsed_seconds(value) do
    case parse_elapsed(value) do
      {:ok, seconds} -> seconds
      _ -> nil
    end
  end

  defp field_atom("drop_off"), do: :drop_off
  defp field_atom(field), do: String.to_existing_atom(field)

  defp selected_timing_operation(%{assigns: %{selected_timing: nil}}), do: {:error, [], nil}

  defp selected_timing_operation(socket) do
    rows = base_timing_rows(socket)

    if timing_edited?(socket) do
      case validate_timing_values(rows) do
        {:ok, parsed} -> {:ok, timing_attributes(socket, rows, parsed)}
        {:error, rows, message} -> {:error, rows, message}
      end
    else
      {:error, [], :no_changes}
    end
  end

  defp timing_edited?(socket) do
    timing_id = socket.assigns.selected_timing_id

    Map.has_key?(socket.assigns.timing_edits, timing_id) or
      Map.has_key?(socket.assigns.timing_headsign_edits, timing_id)
  end

  defp validate_timing_values([]), do: {:error, [], "Add a timing before saving."}

  defp validate_timing_values(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case validate_timing_row(row, index, previous_departure(acc)) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, message, field} -> {:halt, {:error, {message, field}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, parsed}
      {:error, {message, field}} -> {:error, mark_invalid(rows, field), message}
    end
  end

  defp previous_departure([]), do: nil
  defp previous_departure(acc), do: acc |> List.last() |> Map.get(:departure_offset)

  defp validate_timing_row(row, index, preceding) do
    with {:ok, arrival} <- parse_elapsed_field(row.arrival, {row.position, :arrival}),
         {:ok, departure} <- parse_elapsed_field(row.departure, {row.position, :departure}) do
      cond do
        departure < arrival ->
          {:error, "Departure must be at or after arrival.", {row.position, :departure}}

        index == 0 and departure != 0 ->
          {:error, "The first departure must be 00:00; other times are measured from it.",
           {row.position, :departure}}

        index > 0 and arrival < preceding ->
          {:error, "Arrival must be at or after the previous departure.",
           {row.position, :arrival}}

        true ->
          {:ok, %{row: row, arrival_offset: arrival, departure_offset: departure}}
      end
    end
  end

  defp parse_elapsed_field(value, field) do
    case parse_elapsed(value) do
      {:ok, seconds} ->
        {:ok, seconds}

      {:error, message} ->
        {:error, message, field}
    end
  end

  defp parse_elapsed(value) when is_integer(value), do: {:ok, value}

  defp parse_elapsed(value) when is_binary(value) do
    case GtfsTime.parse_offset(value) do
      {:ok, seconds} -> {:ok, seconds}
      {:error, _reason} -> {:error, "Enter an elapsed time such as 04:30."}
    end
  end

  defp parse_elapsed(_value), do: {:error, "Enter an elapsed time such as 04:30."}

  defp mark_invalid(rows, {position, field}) do
    Enum.map(rows, fn row ->
      cond do
        row.position == position and field == :arrival -> %{row | arrival_error: true}
        row.position == position and field == :departure -> %{row | departure_error: true}
        true -> row
      end
    end)
  end

  defp first_invalid_field(rows) do
    Enum.find_value(rows, fn row ->
      cond do
        row.arrival_error -> "timing-arrival-#{row.position}"
        row.departure_error -> "timing-departure-#{row.position}"
        true -> nil
      end
    end)
  end

  defp timing_attributes(socket, rows, parsed) do
    occurrences = socket.assigns.occurrences
    stored = Enum.map(rows, & &1.stored)

    attrs = %{
      rows:
        parsed
        |> Enum.with_index()
        |> Enum.map(fn {%{row: row, arrival_offset: arrival, departure_offset: departure}, index} ->
          occurrence = Enum.at(occurrences, index)
          stored_row = Enum.at(stored, index)

          %{
            route_pattern_stop_id: occurrence && occurrence.id,
            arrival_offset: arrival,
            departure_offset: departure,
            timepoint: touched_value(row, :timepoint, stored_row),
            pickup_type: touched_value(row, :pickup, stored_row),
            drop_off_type: touched_value(row, :drop_off, stored_row),
            stop_headsign: touched_value(row, :headsign, stored_row)
          }
        end)
    }

    changed_headsign(socket, attrs)
  end

  # An edited field takes its staged value; an untouched field keeps the stored
  # value, so an imported nil attribute survives a save that never touched it.
  defp touched_value(row, field, stored) do
    if MapSet.member?(row.touched || MapSet.new(), field) do
      edited_value(row, field)
    else
      stored_value(stored, field)
    end
  end

  defp edited_value(row, :timepoint), do: if(row.timepoint, do: 1, else: 0)
  defp edited_value(row, :pickup), do: String.to_integer(row.pickup)
  defp edited_value(row, :drop_off), do: String.to_integer(row.drop_off)
  defp edited_value(row, :headsign), do: blank_to_nil(row.stop_headsign)

  defp stored_value(stored, :timepoint), do: Map.get(stored, :timepoint)
  defp stored_value(stored, :pickup), do: Map.get(stored, :pickup_type)
  defp stored_value(stored, :drop_off), do: Map.get(stored, :drop_off_type)
  defp stored_value(stored, :headsign), do: Map.get(stored, :stop_headsign)

  defp changed_headsign(socket, attrs) do
    headsign = Map.get(socket.assigns.timing_headsign_edits, socket.assigns.selected_timing_id)

    if is_binary(headsign), do: Map.put(attrs, :headsign, blank_to_nil(headsign)), else: attrs
  end

  defp review_timing(socket, attrs, confirm? \\ false) do
    operation = {:timing, socket.assigns.selected_timing.id, attrs}

    case Gtfs.review(
           pattern_uuid(socket),
           operation,
           socket.assigns.source_fingerprint,
           audit_context(socket)
         ) do
      {:ok, %{fingerprint: fingerprint, impact: %{trips_affected: 0} = impact}}
      when not confirm? ->
        apply_timing(socket, operation, fingerprint, impact)

      {:ok, %{fingerprint: fingerprint, impact: impact}} ->
        {:noreply,
         socket
         |> assign(:applying?, false)
         |> assign(:review, %{
           kind: :timing,
           operation: operation,
           fingerprint: fingerprint,
           impact: impact,
           error: nil,
           busy: false
         })}

      {:error, reason} ->
        {:noreply,
         timing_review_failure(
           socket,
           %{
             kind: :timing,
             operation: operation,
             fingerprint: nil,
             impact: %{trips_affected: 0},
             error: nil,
             busy: false
           },
           reason
         )}
    end
  end

  defp apply_timing(socket, operation, fingerprint, _impact) do
    case Gtfs.apply_review(pattern_uuid(socket), operation, fingerprint, audit_context(socket)) do
      {:ok, %{trips_updated: updated}} ->
        {:noreply, saved(socket, affected_message(updated), timing_scope(operation))}

      {:error, reason} ->
        {:noreply,
         timing_review_failure(
           socket,
           %{
             kind: :timing,
             operation: operation,
             fingerprint: nil,
             impact: %{trips_affected: 0},
             error: nil,
             busy: false
           },
           reason
         )}
    end
  end

  defp timing_review_failure(socket, review, :stale_review) do
    socket
    |> assign(:applying?, false)
    |> assign(:review, %{
      review
      | error: %{
          message:
            "This pattern changed since you reviewed it. Refresh the review to see the current counts and confirm the save again; your edits are still here.",
          action: :refresh
        },
        busy: false
    })
  end

  defp timing_review_failure(socket, review, reason) do
    socket
    |> assign(:applying?, false)
    |> assign(:review, %{
      review
      | error: %{message: reasons_message(reason), action: :retry},
        busy: false
    })
  end

  # A timing save only clears the draft it saved; adding a timing clears none.
  defp timing_scope({:timing, timing_id, _attrs}), do: {:timing, timing_id}
  defp timing_scope(_operation), do: :timing_add

  defp timing_review(%{kind: :timing} = review), do: review
  defp timing_review(_review), do: nil

  defp stop_review(%{kind: :stops} = review), do: review
  defp stop_review(_review), do: nil

  # --- timing CRUD -----------------------------------------------------------

  defp confirm_timing_dialog(socket, dialog) do
    name = dialog.name |> to_string() |> String.trim()

    cond do
      name == "" ->
        {:noreply,
         assign(socket, :timing_dialog, %{dialog | error: "Enter a unique timing name."})}

      name_taken?(socket, dialog, name) ->
        {:noreply,
         assign(socket, :timing_dialog, %{dialog | error: "Enter a unique timing name."})}

      dialog.mode == :add ->
        apply_timing_dialog(
          socket,
          {:add_timing, %{name: name, source_timing_id: dialog.source_timing_id}},
          dialog
        )

      true ->
        apply_timing_dialog(
          socket,
          {:timing, socket.assigns.selected_timing_id, %{name: name}},
          dialog
        )
    end
  end

  defp apply_timing_dialog(socket, operation, dialog) do
    case Gtfs.review(
           pattern_uuid(socket),
           operation,
           socket.assigns.source_fingerprint,
           audit_context(socket)
         ) do
      {:ok, %{fingerprint: fingerprint}} ->
        case Gtfs.apply_review(
               pattern_uuid(socket),
               operation,
               fingerprint,
               audit_context(socket)
             ) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(:timing_dialog, nil)
             |> saved(timing_dialog_saved_message(dialog), timing_dialog_scope(dialog, socket))}

          {:error, reason} ->
            {:noreply, assign(socket, :timing_dialog, %{dialog | error: reasons_message(reason)})}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :timing_dialog, %{dialog | error: reasons_message(reason)})}
    end
  end

  defp timing_dialog_saved_message(%{mode: :add}), do: "Timing added."
  defp timing_dialog_saved_message(_dialog), do: "Timing renamed."

  # Name-only operations do not persist row or headsign drafts.
  defp timing_dialog_scope(%{mode: :rename}, _socket),
    do: :timing_add

  defp timing_dialog_scope(_dialog, _socket), do: :timing_add

  defp name_taken?(socket, dialog, name) do
    selected_id = socket.assigns.selected_timing_id

    Enum.any?(socket.assigns.timings, fn %{timing: timing} ->
      String.downcase(timing.name) == String.downcase(name) and
        not (dialog.mode == :rename and timing.id == selected_id)
    end)
  end

  defp timing_name(socket) do
    case socket.assigns.selected_timing do
      %{name: name} when is_binary(name) -> name
      _ -> ""
    end
  end

  defp timing_source_options(socket) do
    Enum.map(socket.assigns.timings, fn %{timing: timing, trip_count: count} ->
      %{value: timing.id, label: "#{timing.name} · #{trip_count_text(count)}"}
    end)
  end

  defp timing_trip_label(socket, timing) do
    count =
      Enum.find_value(socket.assigns.timings, 0, fn %{timing: candidate, trip_count: count} ->
        if candidate.id == timing.id, do: count
      end)

    "#{trip_count_text(count)} #{trip_verb(count)} #{timing.name}"
  end

  defp blocked(socket, title, message) do
    {:noreply,
     socket
     |> assign(:blocked_dialog, %{title: title, message: message})
     |> assign(:error_message, nil)}
  end

  defp reviewed_apply(socket, operation, _unused) do
    with {:ok, %{fingerprint: fingerprint}} <- reviewed_apply_review_only(socket, operation) do
      Gtfs.apply_review(pattern_uuid(socket), operation, fingerprint, audit_context(socket))
    end
  end

  defp reviewed_apply_review_only(socket, operation) do
    Gtfs.review(
      pattern_uuid(socket),
      operation,
      socket.assigns.source_fingerprint,
      audit_context(socket)
    )
  end

  # --- helpers ---------------------------------------------------------------

  # Review and apply take the pattern's database identity, which always comes
  # from the loaded server record rather than from the browser.
  defp pattern_uuid(socket), do: socket.assigns.pattern && socket.assigns.pattern.id

  defp guard_navigation(socket, path) do
    if socket.assigns.dirty? do
      {:noreply, assign(socket, :pending_navigation, path)}
    else
      {:noreply, push_navigate(socket, to: path)}
    end
  end

  defp resolve_task(:new, "stops"), do: :stops
  defp resolve_task(:new, _task), do: :details
  defp resolve_task(_action, "timings"), do: :timings
  defp resolve_task(_action, "alignment"), do: :alignment
  defp resolve_task(_action, "details"), do: :details
  defp resolve_task(_action, "stops"), do: :stops
  defp resolve_task(_action, _task), do: :stops

  defp pattern_label(socket) do
    case socket.assigns.pattern do
      %{route_pattern_name: name} when is_binary(name) and name != "" -> name
      %{route_pattern_id: id} -> id
      _ -> "this pattern"
    end
  end

  defp stop_rows(assigns) do
    rows = assigns.staged_occurrences

    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, position} ->
      %{
        position: position,
        key: row.key,
        id: row.id,
        stop_id: row.stop_id,
        name: stop_name(assigns.stops, row.stop_id),
        last?: position == length(rows)
      }
    end)
  end

  defp stop_name(stops, stop_id) do
    case Map.get(stops, stop_id) do
      %{stop_name: name} when is_binary(name) and name != "" -> name
      _ -> stop_id
    end
  end

  defp reorderable?(assigns) do
    assigns.live_action == :new or
      (assigns.detail_custom_trip_count == 0 and assigns.detail_trip_count == 0)
  end

  defp detail_custom_trip_count(assigns) do
    if assigns.live_action == :new, do: 0, else: assigns.detail_custom_trip_count
  end

  defp search_status(text, stops) do
    case String.trim(to_string(text || "")) do
      "" ->
        @search_idle

      _query ->
        search_result_status(stops)
    end
  end

  defp search_result_status([]), do: "No stops match that search."
  defp search_result_status([_stop]), do: "1 match"
  defp search_result_status(stops), do: "#{length(stops)} matches"

  defp preview_label(preview, offset) when is_integer(offset) do
    case preview_seconds(preview) do
      {:ok, seconds} -> clock_label(seconds + offset)
      :error -> "—"
    end
  end

  defp preview_label(_preview, _offset), do: "—"

  # The preview accepts the prototype's `H+:MM[:SS]` clock form and is display
  # only: it never writes a trip start.
  defp preview_seconds(value) when is_binary(value) do
    parts = String.split(String.trim(value), ":")

    with true <- length(parts) in [2, 3],
         {:ok, hours} <- parse_integer_part(Enum.at(parts, 0)),
         {:ok, minutes} <- parse_integer_part(Enum.at(parts, 1)),
         true <- minutes < 60,
         {:ok, seconds} <- preview_seconds_part(parts) do
      {:ok, hours * 3600 + minutes * 60 + seconds}
    else
      _ -> :error
    end
  end

  defp preview_seconds(_value), do: :error

  defp preview_seconds_part([_h, _m]), do: {:ok, 0}

  defp preview_seconds_part([_h, _m, s]) do
    case parse_integer_part(s) do
      {:ok, seconds} when seconds < 60 -> {:ok, seconds}
      _ -> :error
    end
  end

  defp parse_integer_part(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp parse_integer_part(_value), do: :error

  defp clock_label(total) do
    day = div(total, 86_400)
    seconds = rem(total, 86_400)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    remainder = rem(seconds, 60)

    clock =
      if remainder == 0 do
        pad(hours) <> ":" <> pad(minutes)
      else
        pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(remainder)
      end

    if day > 0, do: clock <> " +#{day} day", else: clock
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp offset_input(nil), do: ""
  defp offset_input(seconds) when is_integer(seconds), do: GtfsTime.format_offset(seconds)
  defp offset_input(_value), do: ""

  defp trip_count_text(1), do: "1 trip"
  defp trip_count_text(count), do: "#{count} trips"

  defp trip_verb(1), do: "uses"
  defp trip_verb(_count), do: "use"

  defp stop_search_form, do: to_form(%{"stop_id" => nil}, as: :stop_search)

  defp insert_form(insert_after) do
    to_form(%{"insert_after" => insert_after}, as: :insert)
  end

  defp timing_options(timings) do
    Enum.map(timings, fn %{timing: timing, trip_count: trip_count} ->
      {timing_option_label(timing.name, trip_count), timing.id}
    end)
  end

  defp timing_option_label(name, 1), do: "#{name} · 1 trip"
  defp timing_option_label(name, count), do: "#{name} · #{count} trips"

  defp header_direction_id(assigns) do
    case assigns.pattern do
      %{direction_id: direction_id} -> direction_id
      nil -> header_creation_direction(assigns.details_params["direction_id"])
    end
  end

  defp header_creation_direction("1"), do: 1
  defp header_creation_direction(_value), do: 0

  defp details_params_from_pattern(pattern) do
    %{
      "name" => pattern.route_pattern_name || "",
      "direction_id" => to_string(pattern.direction_id),
      "headsign" => pattern.headsign || "",
      "time_desc" => pattern.route_pattern_time_desc || "",
      "typicality" => to_string(pattern.route_pattern_typicality || 0),
      "sort_order" =>
        if(is_nil(pattern.route_pattern_sort_order),
          do: "",
          else: to_string(pattern.route_pattern_sort_order)
        )
    }
  end

  defp put_details(socket, params, baseline) do
    socket
    |> assign(:details_params, params)
    |> assign(:details_baseline, baseline)
    |> assign(:details_form, details_form(params, []))
    |> assign_dirty(baseline != nil and params != baseline)
  end

  defp details_form(params, errors) do
    to_form(params, as: :pattern, errors: errors)
  end

  defp details_dirty?(socket, params) do
    case {socket.assigns.live_action, socket.assigns.details_baseline} do
      {:new, _baseline} ->
        params != @creation_defaults or socket.assigns.staged_occurrences != []

      {_action, nil} ->
        false

      {_action, baseline} ->
        params != baseline
    end
  end

  defp assign_dirty(socket, dirty? \\ nil) do
    dirty? =
      if is_boolean(dirty?),
        do: dirty?,
        else: details_dirty?(socket, socket.assigns.details_params)

    dirty? =
      dirty? or socket.assigns.stops_dirty? or
        alignment_dirty?(socket) or
        (socket.assigns.live_action == :new and socket.assigns.staged_occurrences != []) or
        map_size(socket.assigns.timing_edits) > 0 or
        map_size(socket.assigns.timing_headsign_edits) > 0

    if socket.assigns.dirty? == dirty? do
      socket
    else
      push_event(assign(socket, :dirty?, dirty?), "route_pattern_dirty", %{dirty: dirty?})
    end
  end

  # An alignment draft is dirty while the hook reports dirty positions.
  # Read defensively: sockets that never mounted the Alignment task still
  # carry the mount-time `%{dirty_positions: []}` shape.
  defp alignment_dirty?(socket) do
    case socket.assigns[:alignment_state] do
      %{dirty_positions: [_ | _]} -> true
      _ -> false
    end
  end

  defp reject_editor(socket, message, field_id) do
    socket = assign(socket, :error_message, message)

    if field_id do
      {:noreply, push_event(socket, "focus_scoped_target", %{id: field_id})}
    else
      {:noreply, socket}
    end
  end

  defp saved(socket, message, scope) do
    socket
    |> assign(:review, nil)
    |> assign(:applying?, false)
    |> load_screen()
    |> reset_editing_state(scope)
    |> assign_dirty()
    |> annotate(message)
  end

  defp annotate(socket, message), do: assign(socket, :status_message, message)

  defp put_build_summary(socket, summary) do
    created = Map.get(summary, :patterns_created, 0)
    linked = Map.get(summary, :trips_linked, 0)
    custom = Map.get(summary, :trips_custom, 0)

    annotate(
      socket,
      "Patterns built from existing trips: #{created} patterns created, " <>
        "#{linked} trips linked, #{custom} kept as custom."
    )
  end

  defp affected_message(0), do: "Changes saved in this version."

  defp affected_message(updated),
    do: "Changes saved in this version. #{updated} trips updated."

  defp impact_title(%{trips_affected: affected}), do: "Update #{affected} trips?"
  defp impact_title(_dialog), do: "Update trips?"

  defp build_error_message(:not_found), do: "This route is no longer available."

  defp build_error_message(reason),
    do: "Building patterns failed (#{bounded_reason(reason)}). No trips were changed."

  defp bounded_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp bounded_reason(reason) when is_binary(reason), do: reason
  defp bounded_reason(_reason), do: "unexpected_error"

  defp reasons_message(:not_found), do: "That pattern is no longer available."

  defp reasons_message(:stale_review),
    do: "This pattern changed since the page loaded. Reload the pattern and try again."

  defp reasons_message(:invalid_input),
    do: "The submitted values could not be saved. Check the form and try again."

  defp reasons_message(:pattern_in_use), do: "Trips still use this pattern."
  defp reasons_message(:timing_in_use), do: "Trips still use this timing."
  defp reasons_message(:last_timing), do: "A pattern keeps at least one timing."

  defp reasons_message(:custom_trips_block_stop_edit),
    do:
      "These trips keep their imported stop times, so this stop list cannot change. Copy the pattern to work on separate service."

  defp reasons_message(:at_least_two_stops), do: "Add at least two stops before saving."
  defp reasons_message(:retained_occurrence_required), do: "Keep at least one saved stop."

  defp reasons_message(:invalid_occurrence_order),
    do: "Copy the pattern to change the stop order."

  defp reasons_message(:adjacent_duplicate_stops),
    do: "This stop is already next to that position."

  defp reasons_message(:timing_acknowledgement_required),
    do: "Acknowledge the added stop values for every timing before saving."

  defp reasons_message(:explicit_terminal_values_required),
    do: "Enter arrival and departure for the added end stop in every timing."

  defp reasons_message(:invalid_chronology),
    do: "Check the arrival and departure order before saving."

  defp reasons_message(%Ecto.Changeset{} = changeset), do: changeset_message(changeset)

  defp reasons_message(:unavailable),
    do: "The data store is temporarily unavailable. Your edits are still here."

  defp reasons_message(_reason),
    do: "The change could not be saved. Your edits are still here."

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map(fn {field, [message | _]} -> {field, message} end)
  end

  defp changeset_message(changeset) do
    case changeset_errors(changeset) do
      [{_field, message} | _] -> "The change could not be saved: #{message}."
      [] -> "The change could not be saved. Check the form and try again."
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp patterns_path(socket) do
    "/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{socket.assigns.route_id}/patterns"
  end

  defp version_patterns_path(socket, version_id) do
    "/gtfs/#{version_id}/routes/#{socket.assigns.route_id}/patterns"
  end

  defp pattern_path(socket, pattern_id, query) do
    "/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{socket.assigns.route_id}/patterns/#{pattern_id}#{query}"
  end

  defp task_path(socket, task) do
    base =
      case socket.assigns.live_action do
        :new -> "#{patterns_path(socket)}/new"
        _ -> "#{patterns_path(socket)}/#{socket.assigns.pattern_id}"
      end

    "#{base}?#{task_query(socket, task)}"
  end

  defp task_query(socket, task) do
    task = task || socket.assigns.task

    case socket.assigns.selected_timing_id do
      nil -> "task=#{task}"
      timing_id -> "task=#{task}&timing=#{timing_id}"
    end
  end

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      station_stop_id: nil,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end
end
