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
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Headsigns
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimingFill
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Gtfs.RoutePatternAlignmentComponents
  alias GtfsPlannerWeb.Gtfs.RoutePatternAlignmentEvents
  alias GtfsPlannerWeb.Gtfs.RoutePatternComponents
  alias GtfsPlannerWeb.Gtfs.RoutePatternHeadsignComponents
  alias GtfsPlannerWeb.Gtfs.RoutePatternListComponents
  alias LiveSelect.Component, as: LiveSelectComponent

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

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
    undo_headsign apply_headsign_reset
    alignment_save_requested confirm_alignment_save alignment_conflict_keep_local
    alignment_generate_paths alignment_confirm_generate alignment_cancel_generation
    alignment_follow_streets confirm_bulk_generation reactivate_route
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
     |> assign(:build_summary, nil)
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
     |> assign(:timing_headsign_open?, false)
     |> assign(:preview_time, @default_preview)
     |> assign(:timing_error, nil)
     |> assign(:timing_blank_note, nil)
     |> assign(:blank_count, 0)
     |> assign(:fill, nil)
     |> assign(:fill_preview, nil)
     |> assign(:fill_distances, [])
     |> assign(:fill_coords, [])
     |> assign(:fill_sections, [])
     |> assign(:fill_method, :distance)
     |> assign(:retime, nil)
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
     |> assign(:alignment_generation, nil)
     |> assign(:alignment_follow, nil)
     |> assign(:alignment_generate_dialog, nil)
     |> assign(:alignment_generate_notice, nil)
     |> assign(:bulk_selected, nil)
     |> assign(:bulk_candidates, [])
     |> assign(:bulk_dialog, nil)
     |> assign(:bulk_result, nil)
     |> assign(:bulk_error, nil)
     |> assign(:alignment_bulk, nil)
     |> assign(:alignment_suggestions, %{})
     |> assign(:details_params, @creation_defaults)
     |> assign(:details_baseline, nil)
     |> assign(:details_form, details_form(@creation_defaults, []))
     |> assign(:dirty?, false)
     |> assign(:headsign_usage, nil)
     |> assign(:headsign_selection, nil)
     |> assign(:headsign_undo, nil)
     |> assign(:headsign_review, nil)
     |> assign(:headsign_siblings, [])
     |> assign(:patterns_editable, false)
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
    |> assign(:headsign_undo, nil)
    |> assign(:alignment_pending, nil)
    |> assign(:alignment_save_notice, nil)
    |> assign(:alignment_forced_local, [])
    |> assign(:alignment_import_dialog, nil)
    |> assign(:alignment_generate_dialog, nil)
    |> assign(:alignment_generate_notice, nil)
    |> assign(:alignment_generation, nil)
    |> assign(:bulk_dialog, nil)
    |> assign(:alignment_bulk, nil)
    |> assign(:alignment_follow, nil)
    |> cancel_async(:alignment_generation)
    |> cancel_async(:alignment_follow)
    |> cancel_async(:alignment_bulk)
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
         |> assign(:build_error, nil)
         |> put_build_summary(summary)
         |> load_screen()}

      {:error, :nothing_pending} ->
        {:noreply,
         socket
         |> assign(:build_state, :blocked)
         |> assign(:build_error, nil)
         |> assign(:build_summary, nil)
         |> load_screen()}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:build_state, :failed)
         |> assign(:build_error, build_error_message(reason))
         |> assign(:build_summary, nil)
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
     |> sync_headsign_selection()
     |> assign_dirty()}
  end

  def handle_event("validate_details", _params, socket), do: {:noreply, socket}

  # The inline update box: whether the save will also write the staged trips.
  # The box renders nothing while it is unchecked with trips staged, so the
  # toggle is the only way the selection reaches a save.
  @impl true
  def handle_event("toggle_headsign_update", _params, socket) do
    case socket.assigns.headsign_selection do
      %{update?: update?} = selection ->
        {:noreply, assign(socket, :headsign_selection, %{selection | update?: not update?})}

      nil ->
        {:noreply, socket}
    end
  end

  # The imported variant: adopting a carrying timing's value fills the field
  # without saving anything.
  @impl true
  def handle_event("use_timings_headsign", %{"value" => value}, socket) when is_binary(value) do
    params = Map.put(socket.assigns.details_params, "headsign", value)

    {:noreply,
     socket
     |> assign(:details_params, params)
     |> assign(:details_form, details_form(params, []))
     |> sync_headsign_selection()
     |> assign_dirty()
     |> push_event("focus_scoped_target", %{id: "pattern-details-headsign"})}
  end

  def handle_event("use_timings_headsign", _params, socket), do: {:noreply, socket}

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

  # Undo of the last headsign save, or of the review drawer's stored reset:
  # the recorded from/to values swap under the per-trip fence, so a trip edited
  # since the write reports stale and writes nothing. The drawer's own result
  # is undone first while it is on screen, and the drawer closes either way so
  # the confirmation (or the stale copy) is visible on the page.
  @impl true
  def handle_event("undo_headsign", _params, socket) do
    case active_headsign_undo(socket) do
      {_source, undo} when is_map(undo) ->
        case Gtfs.undo_headsign_update(pattern_uuid(socket), undo, audit_context(socket)) do
          {:ok, %{applied: applied}} ->
            {:noreply,
             socket
             |> saved(undo_saved_message(undo, applied), :details)
             |> drop_headsign_undo(active_source(socket))
             |> assign(:headsign_review, nil)}

          {:error, {:stale, _changed}} ->
            {:noreply,
             socket
             |> drop_headsign_undo(active_source(socket))
             |> assign(:headsign_review, nil)
             |> load_screen()
             |> assign(:error_message, undo_stale_message())}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:headsign_review, nil)
             |> reject_editor(reasons_message(reason), nil)}
        end

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("apply_details_review", _params, socket) do
    case socket.assigns.impact_dialog do
      %{operation: operation, fingerprint: fingerprint} ->
        socket |> assign(:impact_dialog, nil) |> apply_details(operation, fingerprint)

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_details_review", _params, socket) do
    {:noreply, assign(socket, :impact_dialog, nil)}
  end

  # --- headsign review drawer -------------------------------------------------

  # Change mode reuses the staged usage (already split on the stored default)
  # and the staged selection, exactly like the prototype's pending proposal;
  # an unchecked box opens the drawer with nothing preselected. It works for
  # both staging scopes: the usage assign holds the Details pattern scope or
  # the Running-times timing scope, whichever staged the box. Exceptions mode
  # renders the loading skeleton first and loads its own usage — the pattern's
  # or one timing's, named by the opener — without a from split, so the
  # followers group cannot leak into it.
  @impl true
  def handle_event("open_headsign_review", %{"mode" => "change"}, socket) do
    case socket.assigns do
      %{headsign_usage: %{} = usage, headsign_selection: %{ids: ids, update?: update?}} ->
        {:noreply,
         assign(socket, :headsign_review, %{
           mode: :change,
           state: :ready,
           scope: usage.scope,
           opener_id: headsign_change_opener_id(socket),
           usage: usage,
           selected: if(update?, do: ids, else: MapSet.new()),
           open_groups: [],
           change: %{from: usage.default, to: staged_headsign_to(socket)},
           reviewed: nil,
           undo: nil,
           done: nil
         })}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_headsign_review", %{"mode" => "exceptions"} = params, socket) do
    case review_scope(Map.get(params, "scope", "pattern")) do
      {:ok, scope} -> {:noreply, load_headsign_review(socket, scope)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("open_headsign_review", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_headsign_trip", %{"trip" => trip_id}, socket) do
    {:noreply,
     update_headsign_review(socket, fn review ->
       %{review | selected: headsign_toggle(review.selected, trip_id)}
     end)}
  end

  def handle_event("select_headsign_trip", _params, socket), do: {:noreply, socket}

  # A group checkbox adds all of its trips, and clears them once every trip is
  # already selected, like the prototype's native checkbox toggle.
  @impl true
  def handle_event("select_headsign_group", %{"group" => group}, socket) do
    {:noreply, toggle_headsign_group(socket, group_index(group))}
  end

  def handle_event("select_headsign_group", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("show_headsign_group", %{"group" => group}, socket) do
    {:noreply, open_headsign_group(socket, group_index(group))}
  end

  def handle_event("show_headsign_group", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_headsign_typos", _params, socket) do
    {:noreply,
     update_headsign_review(socket, fn review ->
       %{review | selected: MapSet.union(review.selected, typo_ids(review.usage))}
     end)}
  end

  # Change mode's hand-back: the drawer's selection becomes the inline box's
  # staged selection, so the save writes exactly what the editor chose. Like
  # the prototype, handing back an empty selection leaves the box unchecked —
  # nothing existing changes until trips are staged again.
  @impl true
  def handle_event("use_headsign_selection", _params, socket) do
    case socket.assigns do
      %{headsign_review: %{mode: :change, selected: selected}, headsign_selection: %{key: key}} ->
        {:noreply,
         socket
         |> assign(:headsign_selection, %{
           key: key,
           update?: MapSet.size(selected) > 0,
           ids: selected
         })
         |> assign(:headsign_review, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  # Exceptions mode's primary: every selected trip returns to its effective
  # default, fenced per trip on the value the loaded usage reviewed — not the
  # value at click time — so a trip changed since the drawer loaded rolls the
  # whole reset back into the stale state, which offers Refresh list.
  @impl true
  def handle_event("apply_headsign_reset", _params, socket) do
    case socket.assigns.headsign_review do
      %{mode: :exceptions, state: state, selected: selected, reviewed: reviewed} = review
      when state in [:ready, :failed, :done] and is_map(reviewed) ->
        apply_headsign_reset(socket, review, selected, reviewed)

      _ ->
        {:noreply, socket}
    end
  end

  # The stale state's Refresh list: read the usage again; the selection keeps
  # the ids that still differ, now reviewed at their current values.
  @impl true
  def handle_event("refresh_headsign_review", _params, socket) do
    case socket.assigns.headsign_review do
      %{mode: :exceptions, state: :stale} = review ->
        {:noreply,
         socket
         |> assign(:headsign_review, %{review | state: :loading})
         |> start_headsign_review_usage()}

      _ ->
        {:noreply, socket}
    end
  end

  # The review drawer's close: the header button, the footer cancel and the
  # Escape path all arrive here, and the drawer primitive returns focus to the
  # opener (unless the write is still in flight, which the drawer refuses).
  @impl true
  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :headsign_review, nil)}
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
       |> load_headsign_usage()
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
    {:noreply,
     socket
     |> RoutePatternAlignmentEvents.save_requested(params)
     |> assign_dirty()}
  end

  @impl true
  def handle_event("alignment_save_choice", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.save_choice(socket, params)}
  end

  @impl true
  def handle_event("confirm_alignment_save", params, socket) do
    {:noreply,
     socket
     |> RoutePatternAlignmentEvents.confirm_save(params)
     |> refresh_fill_distances()
     |> assign_dirty()}
  end

  @impl true
  def handle_event("alignment_cancel_save", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.cancel_save(socket, params)}
  end

  @impl true
  def handle_event("alignment_conflict_load_latest", params, socket) do
    {:noreply,
     socket
     |> RoutePatternAlignmentEvents.conflict_load_latest(params)
     |> refresh_fill_distances()}
  end

  @impl true
  def handle_event("alignment_conflict_keep_local", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.conflict_keep_local(socket, params)}
  end

  @impl true
  def handle_event("alignment_reload", params, socket) do
    {:noreply,
     socket
     |> RoutePatternAlignmentEvents.reload(params)
     |> refresh_fill_distances()}
  end

  @impl true
  def handle_event("alignment_generate_paths", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.generate(socket, params)}
  end

  @impl true
  def handle_event("alignment_confirm_generate", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.generate(socket, Map.put(params, "confirmed", true))}
  end

  @impl true
  def handle_event("alignment_cancel_generation", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.cancel_generation(socket, params)}
  end

  @impl true
  def handle_event("alignment_follow_streets", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.follow_streets(socket, params)}
  end

  @impl true
  def handle_event("toggle_bulk_select", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.toggle_bulk_select(socket, params)}
  end

  @impl true
  def handle_event("open_bulk", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.open_bulk(socket, params)}
  end

  @impl true
  def handle_event("confirm_bulk_generation", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.confirm_bulk(socket, params)}
  end

  @impl true
  def handle_event("cancel_bulk_generation", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.cancel_bulk(socket, params)}
  end

  @impl true
  def handle_event("review_bulk_suggestions", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.review_suggestions(socket, params)}
  end

  @impl true
  def handle_event("alignment_suggestions_applied", params, socket) do
    {:noreply,
     socket
     |> RoutePatternAlignmentEvents.suggestions_applied(params)
     |> assign_dirty()}
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
      {:noreply,
       socket
       |> assign(:timing_headsign_open?, false)
       |> load_screen(timing_id)
       |> put_timing_rows()
       |> clear_fill()
       |> assign(:timing_blank_note, nil)}
    end
  end

  def handle_event("select_timing", _params, socket), do: {:noreply, socket}

  # The disclosure's open state is a local assign, so unrelated patches keep
  # the body visible exactly as the editor left it.
  @impl true
  def handle_event("toggle_timing_headsign_disclosure", _params, socket) do
    {:noreply, assign(socket, :timing_headsign_open?, not socket.assigns.timing_headsign_open?)}
  end

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
        {message, blank_field} = blank_save_message(socket, rows, message)

        {:noreply,
         socket
         |> put_timing_rows(rows)
         |> assign(:timing_error, message)
         |> assign(:timing_blank_note, if(blank_field, do: message, else: nil))
         |> assign(:error_message, message)
         |> push_event("focus_form_error", %{
           form_id: "timing-form",
           fallback_id: blank_field || first_invalid_field(rows) || "timing-save"
         })}

      {:ok, attrs} ->
        review_timing(socket, attrs)
    end
  end

  @impl true
  def handle_event("apply_timing_review", _params, socket) do
    case socket.assigns.review do
      %{kind: :timing} = review ->
        socket
        |> assign(:applying?, true)
        |> apply_timing(review.operation, review.fingerprint, review.impact)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh_timing_review", _params, socket) do
    case timing_review_attrs(socket.assigns.review) do
      nil ->
        {:noreply, socket}

      attrs ->
        # Refresh the loaded source but keep the submitted rows, so a stale
        # review is re-run against the current values and counts instead of
        # silently reusing an old fingerprint.
        socket
        |> load_screen()
        |> assign(:applying?, false)
        |> assign(:error_message, nil)
        |> review_timing(attrs, true)
    end
  end

  @impl true
  def handle_event("retry_timing_review", _params, socket) do
    case timing_review_attrs(socket.assigns.review) do
      nil -> {:noreply, socket}
      attrs -> review_timing(socket, attrs)
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
     |> assign(:headsign_selection, nil)
     |> assign(:error_message, nil)
     |> assign(:timing_blank_note, nil)
     |> clear_fill()
     |> put_timing_rows()
     |> assign_dirty()}
  end

  # --- stop-time fill (spec 23) --------------------------------------------------
  #
  # Fill times between timepoints stages `TimingFill` estimates into the
  # normal `timing_edits` draft; saving still goes through the existing
  # timing review and materializes linked trips. These events only stage or
  # discard, so persistence stays behind the `save_timing` gate.
  @impl true
  def handle_event("open_fill", _params, socket) do
    case fill_staged_rows(socket) do
      [] ->
        {:noreply, socket}

      rows ->
        method = socket.assigns.fill_method
        scope = TimingFill.default_scope(rows)
        fill = %{scope: scope, method: method, only_anchor: nil}

        {:noreply,
         socket
         |> assign(:fill, fill)
         |> assign(:retime, nil)
         |> put_fill_preview(rows, fill)
         |> push_event("focus_scoped_target", %{id: "fill-title"})}
    end
  end

  @impl true
  def handle_event("change_fill", params, socket) do
    case socket.assigns.fill do
      nil ->
        {:noreply, socket}

      fill ->
        scope = parse_fill_scope(params["scope"]) || fill.scope
        method = parse_fill_method(params["method"]) || fill.method
        only_anchor = if scope == fill.scope, do: fill.only_anchor, else: nil
        fill = %{scope: scope, method: method, only_anchor: only_anchor}

        {:noreply,
         socket
         |> assign(:fill, fill)
         |> put_fill_preview(fill_staged_rows(socket), fill)}
    end
  end

  @impl true
  def handle_event("apply_fill", _params, socket) do
    case {socket.assigns.fill, socket.assigns.fill_preview} do
      {nil, _} ->
        {:noreply, socket}

      {_, nil} ->
        {:noreply, socket}

      {_fill, preview} ->
        case base_timing_rows(socket) do
          [] ->
            {:noreply, clear_fill(socket)}

          base_rows ->
            rows = base_rows |> TimingFill.apply_preview(preview) |> touch_estimated_rows()

            {:noreply,
             socket
             |> put_timing_edits(rows)
             |> put_timing_rows()
             |> assign(:timing_error, nil)
             |> assign(:timing_blank_note, nil)
             |> clear_fill()
             |> assign_dirty()
             |> push_event("focus_scoped_target", %{id: "timing-fill"})}
        end
    end
  end

  @impl true
  def handle_event("cancel_fill", _params, socket) do
    {:noreply,
     socket
     |> clear_fill()
     |> push_event("focus_scoped_target", %{id: "timing-fill"})}
  end

  # The re-estimate prompt opens the preview limited to the moved anchor, so
  # only the spans touching it are recalculated. Positions are 1-indexed in
  # the grid; `only_anchor` is the estimator's 0-based row index.
  @impl true
  def handle_event("reestimate", %{"anchor" => anchor}, socket) do
    with {position, ""} <- Integer.parse(to_string(anchor)),
         rows when rows != [] <- fill_staged_rows(socket),
         true <- Enum.any?(rows, &(&1.position == position)) do
      fill = %{scope: :between, method: socket.assigns.fill_method, only_anchor: position - 1}

      {:noreply,
       socket
       |> assign(:fill, fill)
       |> assign(:retime, nil)
       |> put_fill_preview(rows, fill)
       |> push_event("focus_scoped_target", %{id: "fill-title"})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reestimate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("dismiss_retime", _params, socket) do
    {:noreply, assign(socket, :retime, nil)}
  end

  # Fill-panel problem buttons name the stop input to fix; the
  # FormErrorFocus hook owns the page region and focuses it. This only
  # pushes a client event, so it stays outside `@editor_write_events`.
  @impl true
  def handle_event("focus_form_error", %{"id" => id}, socket) when is_binary(id) do
    {:noreply,
     push_event(socket, "focus_form_error", %{
       form_id: "timing-edit-form",
       fallback_id: id
     })}
  end

  def handle_event("focus_form_error", _params, socket), do: {:noreply, socket}

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
  def handle_event("open_pattern_alignment", params, socket) do
    {:noreply, RoutePatternAlignmentEvents.open_pattern_alignment(socket, params)}
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

  # The shared banner's Reactivate: the step-9 status command with this page's
  # saved identity, projected from the scoped route read through the same
  # source shape the details workspace uses. The screen reloads so the banner
  # and the counts describe what is stored now; a refused request says so and
  # reloads instead of claiming a change.
  @impl true
  def handle_event("reactivate_route", _params, socket) do
    route = socket.assigns.route

    case Gtfs.set_route_active(
           route.route_id,
           true,
           Gtfs.route_source(route),
           audit_context(socket)
         ) do
      {:ok, %{route: _saved}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Route #{route.route_id} reactivated. The next export includes it.")
         |> load_screen()}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "The route was updated while this page was open, so the request was refused. The latest saved route is loaded."
         )
         |> load_screen()}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You no longer have editor access to this organization. The route's status is unchanged."
         )}

      {:error, :busy} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The server is busy right now — the route is unchanged. Try again."
         )}

      {:error, _other} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The status could not be changed. The route is unchanged — try again."
         )}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    handle_version_switch(socket, version_id)
  end

  @impl true
  def handle_async(:alignment_generation, result, socket) do
    {:noreply,
     RoutePatternAlignmentEvents.handle_generation_result(socket, :alignment_generation, result)}
  end

  @impl true
  def handle_async(:alignment_follow, result, socket) do
    {:noreply,
     RoutePatternAlignmentEvents.handle_follow_result(socket, :alignment_follow, result)}
  end

  @impl true
  # Only fresh results re-stream the rows (the badges live inside the
  # streamed items): stale arrivals after a cancel or a revoked editor
  # touch no database and reload nothing.
  def handle_async(:alignment_bulk, result, socket) do
    {socket, reload?} =
      RoutePatternAlignmentEvents.handle_bulk_result(socket, :alignment_bulk, result)

    socket = if reload?, do: load_screen(socket), else: socket

    {:noreply, assign_dirty(socket)}
  end

  @impl true
  # The exceptions drawer's usage: fresh groups and fence values; a refresh
  # keeps the selected ids that still differ. Results for a drawer that has
  # since closed (or a change-mode drawer, which never loads) touch nothing.
  def handle_async(:headsign_review_usage, {:ok, {:ok, usage}}, socket) do
    case socket.assigns.headsign_review do
      %{mode: :exceptions} = review ->
        {:noreply,
         assign(socket, :headsign_review, %{
           review
           | state: :ready,
             usage: usage,
             selected: MapSet.intersection(review.selected, differing_ids(usage)),
             reviewed: reviewed_from_values(usage)
         })}

      _review ->
        {:noreply, socket}
    end
  end

  @impl true
  # A failed usage read cannot render groups, so the drawer closes with the
  # page's unavailable copy.
  def handle_async(:headsign_review_usage, _result, socket) do
    case socket.assigns.headsign_review do
      %{mode: :exceptions} ->
        {:noreply,
         socket
         |> assign(:headsign_review, nil)
         |> assign(:error_message, reasons_message(:unavailable))}

      _review ->
        {:noreply, socket}
    end
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
    assigns =
      assigns
      |> assign(:save_bar, save_bar_spec(assigns))
      |> assign(:headsign_view, headsign_view(assigns))
      |> assign(:timing_headsign_view, timing_headsign_view(assigns))
      |> assign(:headsign_result, headsign_result_view(assigns))

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
      <div
        id="pattern-editor"
        phx-hook="RoutePatternEditor"
        data-dirty={to_string(@dirty?)}
        data-offline={to_string(@offline?)}
        class={@live_action != :index && "ds-page"}
      >
        <div id="pattern-editor-content" phx-hook="FormErrorFocus">
          <RoutePatternComponents.status_regions
            error={@error_message}
            status={@status_message}
            hide_error?={@save_bar != nil}
            hide_status?={hide_status?(assigns)}
          />

          <%= cond do %>
            <% @live_action == :index -> %>
              <RoutePatternListComponents.page
                load_state={@load_state}
                route={@route}
                version={@current_gtfs_version}
                patterns={@streams.patterns}
                patterns_empty?={@patterns_empty?}
                pattern_count={@pattern_count}
                route_trip_count={@route_trip_count}
                pending_trip_count={@pending_trip_count}
                custom_trip_count={@custom_trip_count}
                derivation_error={@derivation_error}
                build_state={@build_state}
                build_error={@build_error}
                build_summary={@build_summary}
                stale?={@stale?}
                editable?={@patterns_editable}
                editor_revoked?={@editor_revoked?}
                new_path={~p"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns/new"}
                compare_path={
                  ~p"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns/compare"
                }
                bulk_candidates={@bulk_candidates}
                bulk_selected={@bulk_selected}
                bulk_dialog={@bulk_dialog}
                bulk_result={@bulk_result}
                bulk_error={@bulk_error}
                bulk_pending={@alignment_bulk != nil}
              />
            <% @load_state == :loading -> %>
              <.skeleton id="patterns-loading" label="Loading patterns" rows={3} aria-busy="true" />
            <% @load_state == :unavailable -> %>
              <div id="patterns-unavailable" class="mt-4">
                <.message kind="error" title="Patterns unavailable">
                  This route’s patterns could not be loaded. The rest of the app is unaffected.
                  <:action>
                    <button
                      id="patterns-retry"
                      type="button"
                      phx-click="reload_patterns"
                      class="btn btn-outline min-h-11"
                    >
                      <.icon name="hero-arrow-path" class="size-4" /> Retry
                    </button>
                  </:action>
                </.message>
              </div>
            <% @editor_revoked? -> %>
              <div id="pattern-editor-revoked" class="mt-4">
                <.message kind="error" title="Editing is no longer available">
                  Your editing access to this organization was removed, so this page can no
                  longer change patterns, timings or stops. Ask an administrator to restore the
                  editor role, then reload.
                  <:action>
                    <button
                      id="pattern-editor-reload"
                      type="button"
                      phx-click="reload_patterns"
                      class="btn btn-outline min-h-11"
                    >
                      <.icon name="hero-arrow-path" class="size-4" /> Reload
                    </button>
                  </:action>
                </.message>
              </div>
            <% @load_state == :ready -> %>
              <%= if @pattern || @live_action == :new do %>
                <RoutePatternComponents.pattern_detail_header
                  creating={@live_action == :new}
                  route={@route}
                  gtfs_version_id={@current_gtfs_version.id}
                  pattern_name={
                    if(@pattern,
                      do: @pattern.route_pattern_name || @pattern.route_pattern_id,
                      else: ""
                    )
                  }
                  direction_id={header_direction_id(assigns)}
                  toward={header_toward(assigns)}
                  stop_count={
                    if @live_action == :new, do: length(@staged_occurrences), else: @stop_count
                  }
                  trip_count={if @live_action == :new, do: 0, else: @detail_trip_count}
                  timing_count={length(@timings)}
                  task={@task}
                  tasks={
                    if(@live_action == :new,
                      do: [:details, :stops],
                      else: [:stops, :timings, :alignment, :details]
                    )
                  }
                  compare_path={
                    @pattern &&
                      ~p"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns/compare?#{[a: @pattern.route_pattern_id]}"
                  }
                  tab_chips={tab_chips(assigns)}
                  dirty?={@dirty?}
                  show_actions={@live_action == :show}
                />

                <RoutePatternComponents.connectivity_banner offline?={@offline?} />

                <div :if={@details_stale?} class="pt-4">
                  <.message
                    id="details-stale"
                    kind="warning"
                    title="This pattern changed since you reviewed it"
                  >
                    Refresh the review to see the current values and trip counts. Your edits are still here.
                    <:action>
                      <button
                        id="details-refresh-review"
                        type="button"
                        phx-click="refresh_details_review"
                        class="btn btn-outline min-h-11"
                      >
                        <.icon name="hero-arrow-path" class="size-4" /> Refresh review
                      </button>
                    </:action>
                  </.message>
                </div>

                <div :if={@headsign_result} class="pt-4">
                  <.message kind="success" id="headsign-result" title={@headsign_result.title}>
                    <span>
                      <%= if @headsign_result.trips > 0 do %>
                        {@headsign_result.trips_text} now {@headsign_result.trips_verb}
                        <RoutePatternHeadsignComponents.headsign_value value={@headsign_result.to} />.
                      <% else %>
                        Trips you add get
                        <RoutePatternHeadsignComponents.headsign_value value={@headsign_result.to} />.
                      <% end %>
                      <span :if={@headsign_result.differ > 0}>
                        {@headsign_result.differ_text}
                      </span>
                      Each change is in History.
                    </span>
                    <:action>
                      <div class="flex flex-wrap items-center gap-2">
                        <button
                          type="button"
                          id="headsign-undo"
                          phx-click="undo_headsign"
                          class="btn btn-outline min-h-11"
                        >
                          <.icon name="hero-arrow-uturn-left" class="size-4" /> Undo headsign change
                        </button>
                        <button
                          :if={@headsign_result.differ > 0}
                          type="button"
                          id="headsign-result-review"
                          phx-click="open_headsign_review"
                          phx-value-mode="exceptions"
                          phx-value-scope={@headsign_result.review_scope}
                          class="btn btn-outline min-h-11"
                        >
                          Review {@headsign_result.differ_trips}
                        </button>
                      </div>
                    </:action>
                  </.message>
                </div>

                <div
                  :if={
                    @task == :stops and
                      (map_size(@timing_edits) > 0 or map_size(@timing_headsign_edits) > 0)
                  }
                  class="pt-4"
                >
                  <.message
                    id="pattern-timing-drafts"
                    kind="warning"
                    title="Running-time edits are unsaved"
                  >
                    To save stop changes, save or discard the running-time edits first.
                    <:action>
                      <button
                        id="discard-timing-drafts"
                        type="button"
                        phx-click="discard_timing_drafts"
                        class="btn btn-outline min-h-11"
                      >
                        Discard timing edits
                      </button>
                    </:action>
                  </.message>
                </div>

                <div class="mt-5">
                  <%= cond do %>
                    <% @task == :details -> %>
                      <RoutePatternComponents.details_task
                        form={@details_form}
                        submit_event={
                          if(@live_action == :new, do: "create_pattern", else: "save_details")
                        }
                        pattern_id={if @pattern, do: @pattern.route_pattern_id, else: nil}
                        dirty?={@dirty?}
                        headsign_usage={@headsign_view.usage}
                        headsign_changed?={@headsign_view.changed?}
                        headsign_box={@headsign_view.box}
                        headsign_warnings={@headsign_view.warnings}
                      />
                    <% @task == :stops -> %>
                      <RoutePatternComponents.stops_task
                        creating={@live_action == :new}
                        stop_rows={stop_rows(assigns)}
                        ring_color={ring_color(@route)}
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
                          generation={@alignment_generation}
                          generate_dialog={@alignment_generate_dialog}
                          generate_notice={@alignment_generate_notice}
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
                        headsign_summary={@timing_headsign_view.summary}
                        headsign_open?={@timing_headsign_open?}
                        headsign_usage={@timing_headsign_view.usage}
                        headsign_changed?={@timing_headsign_view.changed?}
                        headsign_box={@timing_headsign_view.box}
                        headsign_warnings={@timing_headsign_view.warnings}
                        timing_error={@timing_error}
                        timing_blank_note={@timing_blank_note}
                        blank_count={@blank_count}
                        fill={@fill}
                        fill_preview={@fill_preview}
                        fill_distances={@fill_distances}
                        fill_coords={@fill_coords}
                        fill_sections={@fill_sections}
                        retime={@retime}
                        offline?={@offline?}
                        custom_trip_count={@detail_custom_trip_count}
                        dirty?={@timing_rows != [] and map_size(@timing_edits) > 0}
                        busy?={@applying? or @offline?}
                        filling?={@fill != nil}
                      />
                  <% end %>
                </div>

                <RoutePatternComponents.save_bar
                  :if={@save_bar}
                  primary={@save_bar.primary}
                  secondary={@save_bar.secondary}
                  status={@save_bar.status}
                  version_name={@current_gtfs_version.name}
                  creating={@live_action == :new}
                />
              <% else %>
                <div id="pattern-not-found" class="mt-4">
                  <.message kind="error" title="Pattern not found">
                    This pattern does not belong to the selected route and version.
                  </.message>
                </div>
              <% end %>
            <% true -> %>
              <div id="patterns-unavailable" class="mt-4">
                <.message kind="error" title="Patterns unavailable">
                  This route’s patterns could not be loaded.
                </.message>
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
          chrome="planner"
          return_focus_id="pattern-details-submit"
        >
          <p>
            Saving these details updates the trips that use this pattern.
            <strong class="text-strong">
              This changes {@current_gtfs_version.name}, a published version.
            </strong>
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
          chrome="planner"
        >
          <p>
            {unsaved_summary(assigns)} If you leave now, they are lost.
          </p>
        </.confirm_dialog>

        <RoutePatternHeadsignComponents.review_drawer
          :if={@headsign_review}
          open
          mode={@headsign_review.mode}
          usage={@headsign_review.usage}
          selected={@headsign_review.selected}
          open_groups={@headsign_review.open_groups}
          state={@headsign_review.state}
          done={@headsign_review.done}
          change={@headsign_review.change}
          scope_label={drawer_scope_label(assigns)}
          return_focus_id={@headsign_review.opener_id}
          version_label={@current_gtfs_version.name}
        />
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
      {:ok, screen} -> socket |> apply_screen(screen) |> load_headsign_usage()
      {:error, :not_found} -> not_found(socket)
      {:error, :timing_not_found} -> timing_not_found(socket)
      {:error, :unavailable} -> unavailable(socket)
    end
  end

  # The Details task's usage line and inline update box read the pattern
  # scope's usage; the Running-times disclosure reads the selected timing's
  # scope the same way. `from` splits the scope's followers out, so the box
  # knows which trips the new value reaches; a reload after a save or undo also
  # resets a selection staged against a different stored default.
  defp load_headsign_usage(
         %{assigns: %{task: :details, pattern: %RoutePattern{} = pattern}} = socket
       ) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    usage =
      case Gtfs.headsign_usage(organization_id, version_id, pattern.id, :pattern,
             from: Headsigns.normalize(pattern.headsign)
           ) do
        {:ok, usage} -> usage
        {:error, _not_found} -> nil
      end

    socket
    |> assign(:headsign_usage, usage)
    |> reset_headsign_selection()
  end

  defp load_headsign_usage(
         %{
           assigns: %{
             task: :timings,
             pattern: %RoutePattern{} = pattern,
             selected_timing: %TimedPattern{} = timing
           }
         } = socket
       ) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    usage =
      case Gtfs.headsign_usage(organization_id, version_id, pattern.id, {:timing, timing.id},
             from: Headsigns.effective_default(timing.headsign, pattern.headsign)
           ) do
        {:ok, usage} -> usage
        {:error, _not_found} -> nil
      end

    socket
    |> assign(:headsign_usage, usage)
    |> reset_headsign_selection()
  end

  # Other tasks never render the usage line, so only the read is dropped; the
  # staged selection survives a tab switch and is re-checked against the
  # stored default when the Details or Running-times task loads again.
  defp load_headsign_usage(socket), do: assign(socket, :headsign_usage, nil)

  # A selection staged against another scope or stored default is stale; the
  # current one is rebuilt from the fresh followers on the next dirty draft.
  defp reset_headsign_selection(
         %{assigns: %{headsign_usage: %{scope: scope, default: default}}} = socket
       ) do
    key = {scope, default}
    selection = socket.assigns.headsign_selection

    if is_map(selection) and selection.key == key do
      socket
    else
      assign(socket, :headsign_selection, nil)
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
      |> assign(:headsign_siblings, headsign_siblings(screen.patterns))
      |> assign(:load_state, :ready)
      |> assign(:stale?, false)
      |> then(fn socket ->
        {rows, preselected} = with_alignment(socket, screen.patterns)

        socket
        |> stream(:patterns, RoutePatternListComponents.stream_items(rows), reset: true)
        |> assign(:bulk_candidates, bulk_candidates(rows))
        |> assign(:patterns_editable, editor_access?(socket))
        |> preselect_bulk(preselected)
      end)
      |> apply_detail(screen.detail, previous_pattern_id)

    assign_dirty(socket)
  end

  # Route › Patterns shows every pattern's alignment status from one batched
  # `Gtfs.route_alignment_summary/3` read (step 35, still 5 queries for any
  # pattern count per step 34). Keyed by natural `route_pattern_id`; a
  # pattern absent from the summary renders Not exported through
  # `list_status/1`'s nil branch. The same read preselects the bulk
  # selection (step 36, AC-41): patterns with missing sections start
  # checked, and the selection stays sticky afterwards.
  defp with_alignment(socket, summaries) do
    summary =
      Gtfs.route_alignment_summary(
        socket.assigns.current_organization.id,
        socket.assigns.current_gtfs_version.id,
        socket.assigns.route_id
      )

    rows =
      Enum.map(summaries, fn summary_row ->
        Map.put(summary_row, :alignment, Map.get(summary, summary_row.pattern.route_pattern_id))
      end)

    preselected =
      rows
      |> Enum.filter(fn row -> bulk_missing?(row.alignment) end)
      |> Enum.map(fn row -> row.pattern.route_pattern_id end)

    {rows, preselected}
  end

  # AC-41 preselects the patterns with missing sections. The selection is
  # sticky: only the first load initializes it, later loads (saves,
  # switches, bulk results) keep the operator's toggles.
  defp preselect_bulk(socket, preselected) do
    if is_nil(socket.assigns[:bulk_selected]) do
      assign(socket, :bulk_selected, MapSet.new(preselected))
    else
      socket
    end
  end

  defp bulk_missing?(%{missing: missing}) when missing > 0, do: true
  defp bulk_missing?(_status), do: false

  # The patterns "Generate missing paths" can offer: each with how many sections
  # still lack a path, named the way the list names them.
  defp bulk_candidates(rows) do
    for row <- rows, bulk_missing?(row.alignment) do
      %{
        id: row.pattern.route_pattern_id,
        name: RoutePatternListComponents.pattern_name(row.pattern),
        missing: row.alignment.missing
      }
    end
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
    |> put_fill_context(nil)
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
      |> put_fill_context(pattern)
    else
      params = details_params_from_pattern(pattern)

      socket
      |> put_details(params, params)
      |> reset_editing_state()
      |> put_fill_context(pattern)
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
    |> assign(:timing_blank_note, nil)
    |> assign(:review, nil)
    |> assign(:applying?, false)
    |> clear_fill()
    |> assign(:headsign_selection, nil)
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
    |> assign(:headsign_selection, nil)
    |> put_timing_rows()
  end

  defp reset_editing_state(socket, :stops) do
    socket
    |> assign(:staged_occurrences, loaded_occurrences(socket.assigns.occurrences))
    |> assign(:stops_dirty?, false)
    |> assign(:review, nil)
    |> assign(:applying?, false)
    |> clear_fill()
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
    |> assign(:timing_headsign_open?, false)
    |> assign(:preview_time, @default_preview)
    |> assign(:timing_error, nil)
    |> assign(:timing_blank_note, nil)
    |> assign(:review, nil)
    |> assign(:timing_dialog, nil)
    |> assign(:blocked_dialog, nil)
    |> assign(:timing_delete_dialog, nil)
    |> assign(:pattern_delete_dialog, nil)
    |> assign(:applying?, false)
    |> assign(:headsign_selection, nil)
    |> assign(:headsign_undo, nil)
    |> assign(:headsign_review, nil)
    |> assign(:stop_search_options, [])
    |> assign(:stop_search_results, [])
    |> assign(:stop_search_truncated?, false)
    |> assign(:stop_search_status, @search_idle)
    |> assign(:stop_search_form, stop_search_form())
    |> assign(:insert_after, "")
    |> assign(:insert_form, insert_form(""))
    |> clear_fill()
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

  defp timing_headsign(socket), do: stored_timing_headsign(socket.assigns)

  defp stored_timing_headsign(%{selected_timing: %{headsign: headsign}}) when is_binary(headsign),
    do: headsign

  defp stored_timing_headsign(_assigns), do: ""

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

  # The reviewed details operation carries the inline update box's selection
  # only when the headsign itself changed and the box is checked; an empty
  # selection keeps the reviewed operation's existing 2-tuple shape.
  defp details_operation(socket, attrs) do
    selection = socket.assigns.headsign_selection

    if Map.has_key?(attrs, :headsign) and is_map(selection) and selection.update? and
         MapSet.size(selection.ids) > 0 do
      {:details, attrs, %{headsign_trip_ids: MapSet.to_list(selection.ids)}}
    else
      {:details, attrs}
    end
  end

  defp submit_details_review(socket, attrs) do
    audit = audit_context(socket)
    operation = details_operation(socket, attrs)

    case Gtfs.review(
           pattern_uuid(socket),
           operation,
           socket.assigns.source_fingerprint,
           audit
         ) do
      {:ok, %{fingerprint: fingerprint, impact: %{trips_affected: affected}}} when affected > 0 ->
        {:noreply,
         assign(socket, :impact_dialog, %{
           operation: operation,
           fingerprint: fingerprint,
           trips_affected: affected
         })}

      {:ok, %{fingerprint: fingerprint}} ->
        apply_details(socket, operation, fingerprint)

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

  defp apply_details(socket, operation, fingerprint) do
    audit = audit_context(socket)

    case Gtfs.apply_review(pattern_uuid(socket), operation, fingerprint, audit) do
      {:ok, %{trips_updated: updated, headsign_undo: undo}} ->
        # For a details apply, trips_updated counts only direction updates (all
        # the pattern's trips), so the headsign writes are a subset of them and
        # max is the distinct trip count the status line names.
        message = affected_message(max(updated, (undo && length(undo.trips)) || 0))

        {:noreply,
         socket
         |> saved(message, :details)
         |> assign(:headsign_undo, headsign_undo_state(undo, :pattern))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:details_stale?, reason == :stale_review)
         |> assign(:error_message, reasons_message(reason))}
    end
  end

  # --- headsign selection staging -------------------------------------------------------------

  # The inline update box's staged selection, keyed by the scope and stored
  # default like the prototype's staged proposal: created from the usage read
  # the first time a draft becomes dirty, preserved while the key is unchanged
  # (the editor's toggle and review edits survive typing), and rebuilt when a
  # reload brings a different default (after a save or undo). The Details task
  # stages the pattern scope; the Running-times field stages its timing's
  # scope into the same staged shape.
  defp sync_headsign_selection(%{assigns: %{task: :timings}} = socket) do
    case socket.assigns do
      %{headsign_usage: %{} = usage} ->
        # Only a staged edit can be dirty: the prototype's timingDraft rule.
        # An unstaged field shows the stored value and never opens the box.
        draft = staged_timing_headsign(socket)

        if draft != nil and headsign_dirty?(usage, draft) do
          sync_dirty_headsign_selection(socket, usage)
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp sync_headsign_selection(%{assigns: %{headsign_usage: %{} = usage}} = socket) do
    if headsign_dirty?(usage, socket.assigns.details_params["headsign"]) do
      sync_dirty_headsign_selection(socket, usage)
    else
      socket
    end
  end

  defp sync_headsign_selection(socket), do: socket

  defp sync_dirty_headsign_selection(socket, usage) do
    key = {usage.scope, usage.default}
    selection = socket.assigns.headsign_selection

    if is_map(selection) and selection.key == key do
      socket
    else
      assign(socket, :headsign_selection, %{
        key: key,
        update?: headsign_update_default(usage.default, staged_headsign_value(socket)),
        ids: MapSet.new(follower_ids(usage))
      })
    end
  end

  # The Running-times field's staged draft, or nil before any edit — the
  # box only appears once the editor types. Accepts a socket or a render
  # assigns map.
  defp staged_timing_headsign(%{assigns: assigns}), do: staged_timing_headsign(assigns)

  defp staged_timing_headsign(assigns),
    do: Map.get(assigns.timing_headsign_edits, assigns.selected_timing_id)

  # The staged draft value whose emptiness decides the box's default: the
  # Details field's value, or for a timing draft the effective default the
  # blank falls back to (the pattern's headsign).
  defp staged_headsign_value(%{assigns: %{task: :timings}} = socket),
    do: timing_draft_to(socket.assigns)

  defp staged_headsign_value(socket), do: socket.assigns.details_params["headsign"]

  # The effective default a timing draft would save: the edited value when
  # present, else the pattern's headsign.
  defp timing_draft_to(%{pattern: %RoutePattern{} = pattern} = assigns) do
    Headsigns.effective_default(
      Headsigns.normalize(staged_timing_headsign(assigns)),
      pattern.headsign
    )
  end

  defp timing_draft_to(assigns), do: Headsigns.normalize(staged_timing_headsign(assigns))

  # The box appears when the draft stops following the stored default, by the
  # shared rule — a padded edit of the same value shows no box.
  defp headsign_dirty?(usage, draft) do
    not Headsigns.follows?(draft, usage.default)
  end

  # Checked by default; unchecked only when the edit would leave the scope
  # with no default at all — a timing blank falls back to the pattern's
  # headsign, so it stays checked (clearing from blank stays checked too — it
  # still gives trips a headsign).
  defp headsign_update_default(from, draft) do
    not (is_nil(Headsigns.normalize(draft)) and not is_nil(from))
  end

  defp follower_ids(%{groups: groups}) do
    case Enum.find(groups, &(&1.kind == :follows)) do
      %{trips: trips} -> Enum.map(trips, & &1.id)
      nil -> []
    end
  end

  # --- headsign review drawer wiring -------------------------------------------

  # The primary is disabled without a selection; a forced event writes nothing.
  defp apply_headsign_reset(socket, review, selected, reviewed) do
    if MapSet.size(selected) == 0 do
      {:noreply, socket}
    else
      selections =
        selected
        |> MapSet.to_list()
        |> Enum.map(&%{id: &1, from: Map.fetch!(reviewed, &1)})

      socket =
        socket
        |> assign(:headsign_review, %{review | state: :applying, done: nil})
        |> reset_headsign_trips(selections, review)

      {:noreply, socket}
    end
  end

  # The drawer's context line names the scope: the pattern, or the timing
  # whose usage the editor opened (the prototype's “{name} timing”).
  defp drawer_scope_label(%{headsign_review: %{scope: {:timing, timing_id}}, timings: timings}) do
    case Enum.find(timings, &(&1.timing.id == timing_id)) do
      %{timing: %TimedPattern{name: name}} -> "#{name} timing"
      _ -> "timing"
    end
  end

  defp drawer_scope_label(%{pattern: %RoutePattern{} = pattern}), do: pattern.route_pattern_name
  defp drawer_scope_label(_assigns), do: nil

  # The undo the visible UI offers: the review drawer's stored reset while it
  # is open, else the last save's banner offer.
  defp active_headsign_undo(socket) do
    case socket.assigns do
      %{headsign_review: %{undo: %{} = undo}} -> {:review, undo}
      %{headsign_undo: %{undo: %{} = undo}} -> {:save, undo}
      _ -> nil
    end
  end

  defp active_source(socket) do
    case active_headsign_undo(socket) do
      {source, _undo} -> source
      nil -> nil
    end
  end

  # A completed or failed undo retires only the offer it acted on; an older
  # save's undo stays valid and keeps its banner offer.
  defp drop_headsign_undo(socket, :save), do: assign(socket, :headsign_undo, nil)
  defp drop_headsign_undo(socket, _source), do: socket

  # The exceptions drawer's own usage read: nothing is preselected, so the
  # read runs without a from split and the followers group cannot leak in. The
  # scope is the opener's — the pattern, or the timing whose disclosure opened it.
  defp load_headsign_review(socket, scope) do
    socket
    |> assign(:headsign_review, %{
      mode: :exceptions,
      state: :loading,
      scope: scope,
      opener_id: review_opener_id(scope),
      usage: nil,
      selected: MapSet.new(),
      open_groups: [],
      change: nil,
      reviewed: nil,
      undo: nil,
      done: nil
    })
    |> start_headsign_review_usage()
  end

  # Focus returns inside the timing disclosure when the drawer was opened from
  # its usage line; the component default covers the Details openers.
  defp review_opener_id({:timing, _timing_id}), do: "timing-headsign-usage-review"
  defp review_opener_id(_scope), do: nil

  # The read runs as an async task so the skeleton renders first, like the
  # alignment loads on this LiveView.
  defp start_headsign_review_usage(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    pattern_id = socket.assigns.pattern.id
    scope = socket.assigns.headsign_review.scope

    start_async(socket, :headsign_review_usage, fn ->
      Gtfs.headsign_usage(organization_id, version_id, pattern_id, scope, [])
    end)
  end

  defp reset_headsign_trips(socket, selections, review) do
    case Gtfs.reset_trip_headsigns(
           pattern_uuid(socket),
           review.scope,
           selections,
           audit_context(socket)
         ) do
      {:ok, %{applied: applied, undo: undo}} ->
        socket = saved(socket, affected_message(length(applied)), :details)
        usage = socket.assigns.headsign_usage || review.usage

        assign(socket, :headsign_review, %{
          review
          | state: :done,
            done: reset_done_message(applied, usage),
            undo: undo,
            selected: MapSet.new()
        })

      {:error, {:stale, _changed}} ->
        assign(socket, :headsign_review, %{review | state: :stale})

      {:error, _reason} ->
        assign(socket, :headsign_review, %{review | state: :failed})
    end
  end

  # The drawer's reset result, per the prototype: what the written trips show
  # now, and how many trips still differ (the fresh counts the post-write
  # reload brought back).
  defp reset_done_message(applied, usage) do
    count = length(applied)
    kept = usage.differ

    body =
      if kept > 0 do
        "#{kept} #{trip_noun(kept)} kept a different headsign. Each change is in History."
      else
        "Every trip now shows #{done_word(usage.default)}. Each change is in History."
      end

    %{
      title:
        "#{count} #{trip_noun(count)} now #{if(count == 1, do: "shows", else: "show")} " <>
          done_word(usage.default),
      body: body
    }
  end

  defp done_word(nil), do: "no headsign"
  defp done_word(value), do: value

  # Selection events only mutate a drawer that can act on them.
  defp update_headsign_review(socket, fun) do
    case socket.assigns.headsign_review do
      %{state: state} = review when state != :applying and state != :loading ->
        assign(socket, :headsign_review, fun.(review))

      _review ->
        socket
    end
  end

  defp headsign_toggle(selected, trip_id) do
    if MapSet.member?(selected, trip_id) do
      MapSet.delete(selected, trip_id)
    else
      MapSet.put(selected, trip_id)
    end
  end

  defp toggle_headsign_group(socket, nil), do: socket

  defp toggle_headsign_group(socket, index) do
    update_headsign_review(socket, fn review ->
      toggle_review_group(review, index)
    end)
  end

  defp toggle_review_group(%{usage: %{groups: groups}} = review, index) do
    case Enum.at(groups, index) do
      %{trips: trips} ->
        %{review | selected: toggle_group_selection(review.selected, trips)}

      nil ->
        review
    end
  end

  defp toggle_review_group(review, _index), do: review

  # Like the prototype's group checkbox: a click on an all-selected group
  # clears it, any other state selects the whole group.
  defp toggle_group_selection(selected, trips) do
    ids = MapSet.new(trips, & &1.id)

    if MapSet.subset?(ids, selected) do
      MapSet.difference(selected, ids)
    else
      MapSet.union(selected, ids)
    end
  end

  defp open_headsign_group(socket, nil), do: socket

  defp open_headsign_group(socket, index) do
    update_headsign_review(socket, fn
      %{open_groups: open_groups} = review ->
        if index in open_groups do
          review
        else
          %{review | open_groups: open_groups ++ [index]}
        end
    end)
  end

  defp typo_ids(%{groups: groups}) do
    groups
    |> Enum.filter(& &1.likely_typo)
    |> Enum.flat_map(& &1.trips)
    |> MapSet.new(& &1.id)
  end

  defp typo_ids(_usage), do: MapSet.new()

  # The drawer's group indices arrive as phx-value strings from the browser.
  defp group_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {index, ""} -> index
      _ -> nil
    end
  end

  defp group_index(_value), do: nil

  defp draft_headsign(socket), do: Headsigns.normalize(socket.assigns.details_params["headsign"])

  # Every trip id the usage's groups still hold — the ids a selection can act
  # on after a refresh.
  defp differing_ids(%{groups: groups}) do
    Enum.reduce(groups, MapSet.new(), fn group, acc ->
      MapSet.union(acc, MapSet.new(group.trips, & &1.id))
    end)
  end

  # The fence values from the loaded usage: each trip's normalized headsign at
  # load time, so the reset fences on what the editor reviewed rather than the
  # value at click time.
  defp reviewed_from_values(%{groups: groups}) do
    groups
    |> Enum.flat_map(& &1.trips)
    |> Map.new(fn trip -> {trip.id, Headsigns.normalize(trip.headsign)} end)
  end

  # The Details field's companions, derived once per render: the usage line
  # while the field matches the stored default, and the wording warnings plus
  # the update box while it is edited.
  defp headsign_view(%{headsign_usage: %{} = usage} = assigns) do
    if headsign_dirty?(usage, assigns.details_params["headsign"]) do
      %{
        usage: usage,
        changed?: true,
        box: headsign_box(usage, assigns),
        warnings: headsign_warnings(assigns)
      }
    else
      %{usage: usage, changed?: false, box: nil, warnings: nil}
    end
  end

  defp headsign_view(_assigns), do: %{usage: nil, changed?: false, box: nil, warnings: nil}

  # The Running-times disclosure's companions, derived once per render: the
  # timing scope's usage line while the field matches the stored effective
  # default, and the warnings plus update box while it is edited. The box's
  # target is the next effective default: the edited value, or the pattern's
  # headsign when the edit clears the timing's own. The closed summary names
  # the shown value and where it comes from, whatever the draft state.
  defp timing_headsign_view(%{headsign_usage: %{} = usage} = assigns) do
    draft = staged_timing_headsign(assigns)
    summary = timing_headsign_summary(assigns)

    if draft != nil and headsign_dirty?(usage, draft) do
      %{
        usage: usage,
        summary: summary,
        changed?: true,
        box: headsign_box(usage, assigns, timing_draft_to(assigns)),
        warnings: headsign_warnings_for(assigns, draft)
      }
    else
      %{usage: usage, summary: summary, changed?: false, box: nil, warnings: nil}
    end
  end

  defp timing_headsign_view(assigns),
    do: %{
      usage: nil,
      summary: timing_headsign_summary(assigns),
      changed?: false,
      box: nil,
      warnings: nil
    }

  # The closed disclosure's summary: the timing's own headsign when it sets
  # one, else the pattern's, with the source word the prototype shows.
  defp timing_headsign_summary(%{selected_timing: %TimedPattern{} = timing} = assigns) do
    own = Headsigns.normalize(timing.headsign)
    pattern_value = Headsigns.normalize(assigns.pattern && assigns.pattern.headsign)

    %{value: own || pattern_value, own?: not is_nil(own), pattern_value: pattern_value}
  end

  defp timing_headsign_summary(_assigns),
    do: %{value: nil, own?: false, pattern_value: nil}

  defp headsign_box(usage, assigns) do
    headsign_box(usage, assigns, Headsigns.normalize(assigns.details_params["headsign"]))
  end

  defp headsign_box(usage, assigns, to) do
    followers = follower_trips(usage)
    follower_id_set = MapSet.new(followers, & &1.id)
    selection = assigns.headsign_selection

    {selected_follow, extra, update?} =
      if is_map(selection) do
        selected_follow = MapSet.size(MapSet.intersection(selection.ids, follower_id_set))
        {selected_follow, MapSet.size(selection.ids) - selected_follow, selection.update?}
      else
        {0, 0, false}
      end

    %{
      from: usage.default,
      to: to,
      followers: length(followers),
      selected_follow: selected_follow,
      extra: extra,
      others: max(usage.differ - extra, 0),
      shielded: usage.shielded,
      update?: update?
    }
  end

  defp follower_trips(%{groups: groups}) do
    case Enum.find(groups, &(&1.kind == :follows)) do
      %{trips: trips} -> trips
      nil -> []
    end
  end

  # Wording warnings for the Details draft, with the route's name facts and
  # the one sibling pattern whose headsign matches except for case. The
  # Headsigns module owns every comparison; `Headsigns.difference/3` re-labels
  # the case-equal sibling so the warning can name it. Byte-equal siblings stay
  # out of the lint context: AC-20 warns on "equal except for case", and only a
  # byte difference leaves the note a sibling to name.
  defp headsign_warnings(assigns) do
    headsign_warnings_for(assigns, assigns.details_params["headsign"])
  end

  defp headsign_warnings_for(assigns, draft) do
    siblings = Enum.reject(assigns.headsign_siblings, &(&1.id == pattern_id(assigns.pattern)))

    sibling =
      Enum.find(siblings, fn candidate ->
        match?(%{kind: :case_or_spacing}, Headsigns.difference(candidate.headsign, draft, nil))
      end)

    %{
      warnings:
        Headsigns.lint(draft, %{
          route_short_name: assigns.route && assigns.route.route_short_name,
          route_long_name: assigns.route && assigns.route.route_long_name,
          sibling_headsigns: siblings |> Enum.map(& &1.headsign) |> Enum.reject(&(&1 == draft))
        }),
      value: draft,
      sibling: sibling && %{name: sibling.name, headsign: sibling.headsign},
      route: assigns.route && assigns.route.route_short_name
    }
  end

  defp pattern_id(%RoutePattern{id: id}), do: id
  defp pattern_id(_pattern), do: nil

  # The route's patterns with the name the list shows, captured at load for
  # the sibling-case warning. The loaded pattern is filtered out by id later.
  defp headsign_siblings(patterns) do
    Enum.map(patterns, fn row ->
      %{
        id: row.pattern.id,
        name: RoutePatternListComponents.pattern_name(row.pattern),
        headsign: row.pattern.headsign
      }
    end)
  end

  # The AC-10 success banner: what the save changed and the two actions —
  # Undo headsign change and, while trips still differ, Review M trips. It is
  # bound to `headsign_undo`, so a remount drops it with the undo offer. The
  # review action names the saved scope, so it reopens the drawer that scope.
  defp headsign_result_view(%{headsign_undo: %{undo: undo, scope: scope}} = assigns)
       when is_map(undo) do
    trips = undo.trips
    differ = usage_differ_for_scope(assigns)

    %{
      title:
        if(trips == [],
          do: "Headsign saved",
          else: "Headsign saved · #{length(trips)} #{trip_noun(length(trips))} updated"
        ),
      to: headsign_undo_to(undo),
      trips: length(trips),
      trips_text: "#{length(trips)} #{trip_noun(length(trips))}",
      trips_verb: if(length(trips) == 1, do: "shows", else: "show"),
      differ: differ,
      differ_text:
        "#{differ} #{trip_noun(differ)} #{if(differ == 1, do: "shows", else: "show")} a different headsign.",
      differ_trips: "#{differ} #{trip_noun(differ)}",
      review_scope: review_scope_value(scope)
    }
  end

  defp headsign_result_view(_assigns), do: nil

  # The differ line counts the saved scope's fresh usage, which the reload
  # after the save loaded; another task's usage describes another scope and
  # counts nothing here.
  defp usage_differ_for_scope(%{
         headsign_undo: %{scope: scope},
         headsign_usage: %{scope: scope} = usage
       }),
       do: usage.differ

  defp usage_differ_for_scope(_assigns), do: 0

  defp review_scope_value(:pattern), do: "pattern"
  defp review_scope_value({:timing, timing_id}), do: to_string(timing_id)

  defp headsign_undo_to(%{default: %{to: to}}) when is_binary(to), do: to
  defp headsign_undo_to(%{default: %{to: nil}}), do: nil
  defp headsign_undo_to(%{trips: [%{to: to} | _]}), do: to
  defp headsign_undo_to(_undo), do: nil

  defp headsign_undo_state(nil, _scope), do: nil
  defp headsign_undo_state(undo, scope), do: %{undo: undo, scope: scope}

  # The undo confirmation: the restored default (named by its owning scope —
  # pattern or timing) and each trip's restored value.
  defp undo_saved_message(undo, applied) do
    parts =
      [default_part(undo), trips_part(applied)]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "Headsign change undone."
      parts -> "Headsign change undone. " <> Enum.join(parts, " ")
    end
  end

  defp default_part(%{default: %{scope: {:timing, _timing_id}, from: from}}),
    do: "The timing’s headsign is #{default_word(from)} again."

  defp default_part(%{default: %{from: from}}),
    do: "The pattern’s headsign is #{default_word(from)} again."

  defp default_part(_undo), do: nil

  defp trips_part([]), do: nil

  defp trips_part(applied) do
    count = length(applied)
    froms = Enum.uniq(Enum.map(applied, & &1.from))

    value =
      if length(froms) == 1,
        do: default_word(hd(froms)),
        else: "their earlier headsign"

    "#{count} #{trip_noun(count)} #{if(count == 1, do: "shows", else: "show")} #{value} again."
  end

  defp default_word(nil), do: "blank"
  defp default_word(value), do: value

  # AC-11: the fence refused the undo because a trip or the default moved on;
  # nothing was written and the audit trail holds the current values.
  defp undo_stale_message do
    "The trips changed since the headsign was saved, so the change can no longer be undone. Nothing was changed. Check History to see the current headsigns."
  end

  defp headsign_only_change?(assigns) do
    case assigns.details_baseline do
      baseline when is_map(baseline) ->
        changed_keys(assigns.details_params, baseline) == ["headsign"]

      _baseline ->
        false
    end
  end

  defp changed_keys(params, baseline) do
    params
    |> Enum.reject(fn {field, value} -> Map.get(baseline, field) == value end)
    |> Enum.map(fn {field, _value} -> field end)
    |> Enum.sort()
  end

  defp headsign_save_status(assigns) do
    count = headsign_selected_count(assigns)

    if count > 0 do
      "Saving updates #{count} #{trip_noun(count)}"
    else
      "Saving changes trips you add later, not existing trips"
    end
  end

  defp headsign_selected_count(assigns) do
    case assigns.headsign_selection do
      %{update?: true} = selection -> MapSet.size(selection.ids)
      _selection -> 0
    end
  end

  defp trip_noun(1), do: "trip"
  defp trip_noun(_count), do: "trips"

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

        if impact.trips_affected == 0 and not resequences_times?(socket.assigns.review) and
             stop_review_ready?(socket.assigns.review, socket) do
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
    review =
      Map.merge(review, %{
        blocks: stop_review_blocks(socket, review),
        resequenced?: resequences_times?(review)
      })

    assign(socket, :review, review)
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
        resequenced: resequenced_rows(socket, estimates, timing.id, rows, shift),
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

  # The retained stops whose time changed because the stop order changed, in
  # staged order, with the proposed time each one now carries in this timing.
  defp resequenced_rows(socket, estimates, timing_id, rows, shift) do
    resequenced_ids =
      for %{resequenced: true, timing_id: ^timing_id, id: id} <- estimates,
          into: MapSet.new(),
          do: id

    for {occurrence, index} <- Enum.with_index(socket.assigns.staged_occurrences),
        MapSet.member?(resequenced_ids, occurrence.id) do
      row = Enum.at(rows, index) || %{}

      %{
        id: occurrence.id,
        name: stop_name(socket.assigns.stops, occurrence.stop_id),
        arrival: raw_review_offset(row[:arrival_offset], shift),
        departure: raw_review_offset(row[:departure_offset], shift)
      }
    end
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
  # added stop on a used pattern does, because applying it changes trips. A
  # reorder that changes times needs one on any pattern, because the times move
  # to the timing rows even when no trip uses the pattern.
  defp stop_review_ready_assigns?(assigns, review \\ nil) do
    review = review || assigns.review

    case review do
      %{kind: :stops, error: nil} ->
        cond do
          Map.get(review.impact || %{}, :trips_affected, 0) == 0 and
              not resequences_times?(review) ->
            true

          not stop_review_requires_ack?(assigns, review) ->
            true

          true ->
            Enum.all?(Map.get(review, :blocks, []), & &1.acknowledged)
        end

      _ ->
        false
    end
  end

  defp stop_review_requires_ack?(assigns, review \\ nil) do
    review = review || assigns.review

    resequences_times?(review) or
      (proposes_added_stop?(review) and assigns.detail_trip_count > 0)
  end

  defp resequences_times?(%{proposed: proposed}) when is_map(proposed) do
    proposed |> Map.get(:estimates) |> Kernel.||([]) |> Enum.any?(& &1[:resequenced])
  end

  defp resequences_times?(_review), do: false

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
        stored_arrival: offset_input(row.arrival_offset),
        stored_departure: offset_input(row.departure_offset),
        timepoint: row.timepoint == 1,
        estimated: false,
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
    |> assign(:blank_count, Enum.count(rows, &blank_row?/1))
    |> assign(
      :timing_headsign,
      Map.get(socket.assigns.timing_headsign_edits, socket.assigns.selected_timing_id) ||
        timing_headsign(socket)
    )
  end

  # --- stop-time fill helpers (spec 23) ----------------------------------------

  defp clear_fill(socket) do
    socket
    |> assign(:fill, nil)
    |> assign(:fill_preview, nil)
    |> assign(:retime, nil)
  end

  # Staged rows for the selected timing in the shape `TimingFill` expects.
  # LiveView rows already carry `:position`, `:arrival`, `:departure`,
  # `:timepoint` and `:estimated`, so they pass through directly.
  defp fill_staged_rows(socket) do
    case socket.assigns.selected_timing_id do
      nil -> []
      _ -> base_timing_rows(socket)
    end
  end

  defp put_fill_preview(socket, rows, fill) do
    preview =
      TimingFill.preview(
        rows,
        socket.assigns.fill_distances,
        socket.assigns.fill_coords,
        scope: fill.scope,
        method: fill.method,
        only_anchor: fill.only_anchor
      )

    assign(socket, :fill_preview, preview)
  end

  defp parse_fill_scope("missing"), do: :missing
  defp parse_fill_scope("between"), do: :between
  defp parse_fill_scope(_scope), do: nil

  defp parse_fill_method("distance"), do: :distance
  defp parse_fill_method("even"), do: :even
  defp parse_fill_method(_method), do: nil

  # Estimates only reach linked trips when the save sees them as edits, so
  # applied rows mark their arrival and departure touched.
  defp touch_estimated_rows(rows) do
    Enum.map(rows, fn row ->
      if Map.get(row, :estimated) do
        touched = Map.get(row, :touched) || MapSet.new()
        %{row | touched: touched |> MapSet.put(:arrival) |> MapSet.put(:departure)}
      else
        row
      end
    end)
  end

  # A manual edit replaces any estimate on that row: the staged value is the
  # operator's own, so the estimated mark goes even when the text matches.
  defp clear_estimated_on_manual_change(row, index) do
    if row.position == index, do: %{row | estimated: false}, else: row
  end

  # While the panel is open the preview follows every keystroke; otherwise a
  # timepoint move raises the re-estimate prompt. `retime_candidates/5` is
  # pure, so this costs no query and never reloads distances.
  defp refresh_fill_after_row_change(socket, base_rows, edited_rows) do
    case socket.assigns.fill do
      nil ->
        candidate =
          TimingFill.retime_candidates(
            base_rows,
            edited_rows,
            socket.assigns.fill_distances,
            socket.assigns.fill_coords,
            method: socket.assigns.fill_method
          )

        assign(socket, :retime, candidate)

      fill ->
        put_fill_preview(socket, edited_rows, fill)
    end
  end

  # Editor distances load with the Running times task and refresh on the
  # existing stops and alignment save reloads, never per row change
  # (criteria "Distances load once"). A pattern without saved alignment
  # still resolves; missing sections fall back per R5 downstream.
  defp put_fill_context(socket, nil) do
    socket
    |> assign(:fill_distances, [])
    |> assign(:fill_coords, [])
    |> assign(:fill_sections, [])
    |> assign(:fill_method, :distance)
  end

  defp put_fill_context(socket, pattern) do
    resolved = Alignments.resolve(pattern)

    socket
    |> assign(:fill_distances, Alignments.estimate_distances(resolved))
    |> assign(:fill_coords, Enum.map(resolved.visits, &visit_coord/1))
    |> assign(:fill_sections, fill_sections(resolved))
    |> assign(:fill_method, fill_method(socket))
  end

  # Section geometry for the fill preview map, paired with the endpoint
  # visits so positions stay exact even when a visit repeats a stop. Only
  # JSON-safe geometry crosses to the client; the payload builder decides
  # what draws (path, straight connector, or nothing).
  defp fill_sections(%{visits: visits, sections: sections}) do
    visits
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.zip(sections)
    |> Enum.map(fn {[from, to], section} ->
      %{from: from.position, to: to.position, kind: section.kind, points: section.points || []}
    end)
  end

  # Alignment saves reload only the alignment model (not the screen), so the
  # LiveView refreshes fill distances there. An open preview is recomputed
  # from the current staged rows so it never goes stale.
  defp refresh_fill_distances(socket) do
    socket = put_fill_context(socket, socket.assigns[:pattern])

    case socket.assigns.fill do
      nil -> socket
      fill -> put_fill_preview(socket, fill_staged_rows(socket), fill)
    end
  end

  defp visit_coord(%{lat: lat, lon: lon})
       when is_number(lat) and is_number(lon),
       do: {lat, lon}

  defp visit_coord(_visit), do: nil

  defp fill_method(socket) do
    case ExportDefaults.get(socket.assigns.current_organization.id) do
      %{estimate_method: method} when method in [:distance, :even] -> method
      _ -> :distance
    end
  end

  # A save blocked only by empty stops names the count and offers Fill; any
  # invalid text keeps the existing field error. Validation halts at the
  # first bad row, so the flagged row must itself be blank for the message
  # to apply.
  defp blank_save_message(socket, marked_rows, fallback_message) do
    rows = base_timing_rows(socket)

    with true <- failed_on_blank?(marked_rows),
         blanks when blanks != [] <- Enum.filter(rows, &blank_stop?/1),
         false <- Enum.any?(rows, &invalid_text_row?/1) do
      count = length(blanks)
      first = hd(blanks)

      field =
        if blank_time?(first.arrival),
          do: "timing-arrival-#{first.position}",
          else: "timing-departure-#{first.position}"

      {"#{count} #{blank_stop_noun(count)} times before you can save.", field}
    else
      _ -> {fallback_message, nil}
    end
  end

  defp failed_on_blank?(rows) do
    Enum.any?(rows, fn row ->
      (Map.get(row, :arrival_error) && blank_time?(Map.get(row, :arrival))) ||
        (Map.get(row, :departure_error) && blank_time?(Map.get(row, :departure)))
    end)
  end

  defp blank_row?(row),
    do: blank_time?(Map.get(row, :arrival)) or blank_time?(Map.get(row, :departure))

  defp blank_stop?(row), do: blank_row?(row)

  defp blank_time?(nil), do: true
  defp blank_time?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_time?(_value), do: false

  defp invalid_text_row?(row) do
    invalid_text?(row.arrival) or invalid_text?(row.departure)
  end

  defp invalid_text?(value) when is_binary(value) do
    String.trim(value) != "" and match?({:error, _}, GtfsTime.parse_offset(value))
  end

  defp invalid_text?(_value), do: false

  defp blank_stop_noun(1), do: "stop needs"
  defp blank_stop_noun(_count), do: "stops need"

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
          |> sync_headsign_selection()

        {:noreply, assign_dirty(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp validate_timing_row_change(socket, position, field, params) do
    with {index, ""} <- Integer.parse(to_string(position)),
         rows when is_list(rows) <- base_timing_rows(socket),
         true <- Enum.any?(rows, &(&1.position == index)) do
      edited =
        rows
        |> Enum.map(&merge_row_params(&1, params))
        |> Enum.map(&mark_row_touched(&1, index, field))
        |> Enum.map(&clear_estimated_on_manual_change(&1, index))

      {:noreply,
       socket
       |> put_timing_edits(edited)
       |> put_timing_rows()
       |> assign(:timing_error, nil)
       |> assign(:timing_blank_note, nil)
       |> refresh_fill_after_row_change(rows, edited)
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
  # its posted values and a row that is absent keeps the staged one. The
  # timepoint checkbox posts a hidden "0" when unchecked, so a missing key keeps
  # the staged flag.
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
            timepoint: Map.get(values, "timepoint", timepoint_param(row.timepoint)) == "1"
        }
    end
  end

  defp timepoint_param(true), do: "1"
  defp timepoint_param(_), do: "0"

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

    # A headsign-only save sends no rows: the write re-materializes nothing
    # and the review's trips_affected stays 0 (CR-3), so no dialog opens.
    attrs =
      if timing_rows_edited?(socket) do
        %{
          rows:
            parsed
            |> Enum.with_index()
            |> Enum.map(fn {%{row: row, arrival_offset: arrival, departure_offset: departure},
                            index} ->
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
            |> fill_unset_timepoints()
        }
      else
        %{}
      end

    changed_headsign(socket, attrs)
  end

  defp timing_rows_edited?(socket) do
    Map.has_key?(socket.assigns.timing_edits, socket.assigns.selected_timing_id)
  end

  # GTFS reads an empty timepoint as exact, but the editor shows an unset row as
  # unchecked. Once any row holds an explicit value, the rest are written as 0 so
  # the export matches the checkboxes; a timing that never set one stays all nil.
  defp fill_unset_timepoints(rows) do
    if Enum.all?(rows, &is_nil(&1.timepoint)),
      do: rows,
      else: Enum.map(rows, &%{&1 | timepoint: &1.timepoint || 0})
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
    operation = timing_operation(socket, attrs)

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

  # The staged update-box selection rides the timing save in the 4-tuple form
  # and is re-validated scope-side; an unchecked box or an empty selection
  # keeps the 3-tuple, which writes nothing beyond the submitted attrs.
  defp timing_operation(socket, attrs) do
    selection = socket.assigns.headsign_selection
    timing_id = socket.assigns.selected_timing.id

    if Map.has_key?(attrs, :headsign) and is_map(selection) and selection.update? and
         MapSet.size(selection.ids) > 0 do
      {:timing, timing_id, attrs, %{headsign_trip_ids: MapSet.to_list(selection.ids)}}
    else
      {:timing, timing_id, attrs}
    end
  end

  defp apply_timing(socket, operation, fingerprint, _impact) do
    case Gtfs.apply_review(pattern_uuid(socket), operation, fingerprint, audit_context(socket)) do
      {:ok, %{trips_updated: updated, headsign_undo: undo}} ->
        # trips_updated counts the row re-materialization (the timing's whole
        # trip set when rows are present); the headsign writes are a subset of
        # it, and max is the distinct count the status line names.
        message = affected_message(max(updated, (undo && length(undo.trips)) || 0))

        {:noreply,
         socket
         |> saved(message, timing_scope(operation))
         |> assign(:headsign_undo, headsign_undo_state(undo, timing_scope(operation)))}

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

  # The timing review's submitted attrs, from either operation form (the
  # 4-tuple carries the headsign selection the dialog confirm replays).
  defp timing_review_attrs(%{kind: :timing, operation: {:timing, _timing_id, attrs, _selection}}),
    do: attrs

  defp timing_review_attrs(%{kind: :timing, operation: {:timing, _timing_id, attrs}}), do: attrs
  defp timing_review_attrs(_review), do: nil

  # A timing save only clears the draft it saved; adding a timing clears none.
  defp timing_scope({:timing, timing_id, _attrs, _selection}), do: {:timing, timing_id}
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

  # --- editor presentation -----------------------------------------------------

  # What is unsaved in each task, from the same state `assign_dirty/2` reads.
  defp tab_dirty(assigns) do
    creating? = assigns.live_action == :new

    %{
      stops: assigns.stops_dirty? or (creating? and assigns.staged_occurrences != []),
      timings: map_size(assigns.timing_edits) > 0 or map_size(assigns.timing_headsign_edits) > 0,
      alignment:
        (is_map(assigns.alignment_state) and assigns.alignment_state.dirty_positions != []) or
          map_size(assigns[:alignment_suggestions] || %{}) > 0,
      details: details_changed?(assigns)
    }
  end

  defp details_changed?(%{live_action: :new} = assigns),
    do: assigns.details_params != @creation_defaults

  defp details_changed?(%{details_baseline: nil}), do: false
  defp details_changed?(assigns), do: assigns.details_params != assigns.details_baseline

  defp tab_chips(%{live_action: :new} = assigns) do
    dirty = tab_dirty(assigns)

    %{
      details: if(dirty.details, do: :started),
      stops: {:count, length(assigns.staged_occurrences)}
    }
  end

  defp tab_chips(assigns) do
    dirty = tab_dirty(assigns)

    %{
      stops: if(dirty.stops, do: :unsaved, else: {:count, assigns.stop_count}),
      timings: if(dirty.timings, do: :unsaved, else: {:count, length(assigns.timings)}),
      alignment: alignment_chip(assigns, dirty.alignment),
      details: if(dirty.details, do: :unsaved)
    }
  end

  defp alignment_chip(_assigns, true), do: :unsaved

  defp alignment_chip(%{alignment: %{status: %{missing: missing}}}, false) when missing > 0,
    do: {:missing, missing}

  defp alignment_chip(%{alignment: %{status: %{blocked: blocked}}}, false) when blocked > 0,
    do: :blocked

  defp alignment_chip(_assigns, false), do: nil

  # Where trips head, for the line under the title: the pattern's headsign, or
  # while creating the typed headsign or the last stop added so far.
  defp header_toward(%{live_action: :new} = assigns) do
    typed = String.trim(assigns.details_params["headsign"] || "")

    cond do
      typed != "" -> typed
      assigns.staged_occurrences == [] -> nil
      true -> stop_name(assigns.stops, List.last(assigns.staged_occurrences).stop_id)
    end
  end

  defp header_toward(%{pattern: %{headsign: headsign}}) when is_binary(headsign) do
    case String.trim(headsign) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp header_toward(_assigns), do: nil

  # The route color as a normalized hex for the stop rings, or nil when there is
  # none or it would not show against the white list (a near-white route color
  # keeps the ink ring, as the route badge keeps its edge).
  defp ring_color(route) do
    with {:ok, hex} <- RouteIdentity.normalize_hex(route && Map.get(route, :route_color)),
         true <- RouteIdentity.contrast_ratio(hex, "FFFFFF") >= 3.0 do
      hex
    else
      _ -> nil
    end
  end

  # The status region's own copy is hidden when the bar shows the same message.
  # The alignment task keeps it in view while a draft is open, because the hook's
  # guidance ("Click the line to add a point") is not an outcome of any save.
  defp hide_status?(%{save_bar: nil}), do: false

  defp hide_status?(%{task: :alignment} = assigns),
    do: assigns.save_bar.status.text == assigns.status_message

  defp hide_status?(_assigns), do: true

  # The save bar for the current task, or nil when the task has nothing to
  # save: a pattern with no timing to edit, or an alignment still loading.
  defp save_bar_spec(%{load_state: :ready, editor_revoked?: false} = assigns) do
    # While the fill panel is open the staged estimates are not yet timing
    # edits, so no task offers a save bar until the operator applies or cancels.
    if assigns[:fill] != nil do
      nil
    else
      if assigns.pattern || assigns.live_action == :new do
        dirty = tab_dirty(assigns)
        busy? = assigns.applying? or assigns.offline?
        bar_for(assigns.task, assigns.live_action == :new, dirty, busy?, assigns)
      end
    end
  end

  defp save_bar_spec(_assigns), do: nil

  defp bar_for(:timings, false, _dirty, _busy?, %{timings: []}), do: nil
  defp bar_for(:alignment, _creating?, _dirty, _busy?, %{alignment: nil}), do: nil

  defp bar_for(:stops, true, _dirty, busy?, assigns) do
    %{
      primary: %{
        id: "pattern-create",
        label: "Create pattern",
        click: "create_pattern",
        commit: true,
        disabled?: busy?
      },
      secondary: nil,
      status: bar_message(assigns) || creation_status(assigns)
    }
  end

  defp bar_for(:details, true, _dirty, busy?, assigns) do
    %{
      primary: %{
        id: "pattern-details-submit",
        label: "Create pattern",
        form: "pattern-details-form",
        commit: true,
        disabled?: busy?
      },
      secondary: nil,
      status: bar_message(assigns) || creation_status(assigns)
    }
  end

  defp bar_for(:stops, false, dirty, busy?, assigns) do
    blocker = stop_edit_blocker_assigns(assigns)

    %{
      primary: %{
        id: "pattern-save-stops",
        label: "Save stops",
        click: "save_stops",
        commit: true,
        disabled?: busy? or blocker != nil or not dirty.stops,
        title: blocker
      },
      secondary: nil,
      status:
        bar_status(
          assigns,
          dirty.stops,
          "You have unsaved stop changes.",
          blocker_status(blocker)
        )
    }
  end

  defp bar_for(:timings, false, dirty, busy?, assigns) do
    selected_edited? = selected_timing_edited?(assigns)
    headsign_only? = timing_headsign_only_edited?(assigns)

    other =
      if dirty.timings and not selected_edited?,
        do: "Another timing has unsaved edits. Choose it to save them."

    status =
      if headsign_only? do
        bar_status(assigns, selected_edited?, headsign_save_status(assigns), other)
      else
        bar_status(assigns, selected_edited?, "You have unsaved running-time edits.", other)
      end

    %{
      primary: %{
        id: "timing-save",
        label: if(headsign_only?, do: "Save headsign", else: "Save running times"),
        click: "save_timing",
        commit: true,
        disabled?: busy? or not selected_edited?
      },
      secondary:
        if(dirty.timings,
          do: %{
            id: "discard-timing-drafts",
            label: "Discard timing edits",
            click: "discard_timing_drafts"
          }
        ),
      status: status
    }
  end

  # AC-9: while only the headsign is dirty the bar names the narrower save and
  # says what the checked box will update, or that existing trips stay until
  # the editor adds them. Any other detail change keeps the wider save.
  defp bar_for(:details, false, dirty, busy?, assigns) do
    headsign_only? = headsign_only_change?(assigns)

    status =
      if headsign_only? do
        bar_status(assigns, dirty.details, headsign_save_status(assigns), nil)
      else
        bar_status(assigns, dirty.details, "You have unsaved detail changes.", nil)
      end

    %{
      primary: %{
        id: "pattern-details-submit",
        label: if(headsign_only?, do: "Save headsign", else: "Save details"),
        form: "pattern-details-form",
        commit: true,
        pending_label: "Saving…",
        disabled?: busy? or not dirty.details
      },
      secondary: nil,
      status: status
    }
  end

  defp bar_for(:alignment, false, dirty, _busy?, assigns) do
    save =
      RoutePatternAlignmentComponents.save_state(%{
        alignment: assigns.alignment,
        editable?: assigns.alignment_editable,
        offline?: assigns.offline?,
        applying?: assigns.applying?,
        dirty_positions: assigns.alignment_state.dirty_positions,
        generating?: not is_nil(assigns.alignment_generation)
      })

    count = length(assigns.alignment_state.dirty_positions)

    %{
      primary: %{
        id: "alignment-save",
        label: "Save alignment",
        click:
          JS.dispatch("alignment:action", to: "#alignment-map-root", detail: %{action: "save"}),
        commit: "alignment",
        disabled?: not save.enabled?,
        title: save.title
      },
      secondary:
        if(dirty.alignment and assigns.alignment_state.dirty_positions != [],
          do: %{
            id: "alignment-discard",
            label: "Discard changes",
            click: "alignment_open_discard"
          }
        ),
      status:
        bar_status(
          assigns,
          dirty.alignment,
          "#{count} #{if count == 1, do: "section has", else: "sections have"} unsaved paths.",
          nil
        )
    }
  end

  defp bar_for(_task, _creating?, _dirty, _busy?, _assigns), do: nil

  defp selected_timing_edited?(assigns) do
    id = assigns.selected_timing_id

    id != nil and
      (Map.has_key?(assigns.timing_edits, id) or Map.has_key?(assigns.timing_headsign_edits, id))
  end

  # The disclosure's headsign is the selected timing's only staged change, so
  # the bar names the narrower save like the Details task does.
  defp timing_headsign_only_edited?(assigns) do
    id = assigns.selected_timing_id

    id != nil and Map.has_key?(assigns.timing_headsign_edits, id) and
      not Map.has_key?(assigns.timing_edits, id)
  end

  # The usage line's phx-value scope: "pattern", or a timing uuid that is cast
  # before any query touches it; the usage read then validates it against the
  # loaded pattern and organization scope.
  defp review_scope("pattern"), do: {:ok, :pattern}

  defp review_scope(value) do
    case Ecto.UUID.cast(value) do
      {:ok, timing_id} -> {:ok, {:timing, timing_id}}
      :error -> :error
    end
  end

  # The change drawer's preview target: the Details draft's new value, or for
  # a timing draft the effective default the blank falls back to.
  defp staged_headsign_to(%{assigns: %{task: :timings}} = socket),
    do: timing_draft_to(socket.assigns)

  defp staged_headsign_to(socket), do: draft_headsign(socket)

  # Focus returns to the box's review link inside whichever disclosure staged it.
  defp headsign_change_opener_id(%{assigns: %{task: :timings}}),
    do: "timing-headsign-update-review"

  defp headsign_change_opener_id(_socket), do: nil

  # The status line: a rejected action's error stays in view where the person
  # acted; an unsaved task says so; a saved outcome shows until the next edit.
  defp bar_status(assigns, dirty?, dirty_text, idle_text) do
    cond do
      msg = bar_message(assigns) -> msg
      assigns.offline? -> %{tone: :warning, text: "Reconnect to save. Your edits are kept."}
      dirty? -> %{tone: :warning, text: dirty_text}
      msg = bar_outcome(assigns) -> msg
      idle_text -> %{tone: :neutral, text: idle_text}
      true -> %{tone: :neutral, text: "Nothing to save yet."}
    end
  end

  defp bar_outcome(%{status_message: message}) when is_binary(message) and message != "",
    do: %{tone: :success, text: message}

  defp bar_outcome(_assigns), do: nil

  defp bar_message(%{error_message: error}) when is_binary(error) and error != "",
    do: %{tone: :error, text: error}

  defp bar_message(_assigns), do: nil

  defp blocker_status(nil), do: nil

  defp blocker_status(_blocker),
    do: "Stops can’t change while custom-time trips use this pattern."

  defp stop_edit_blocker_assigns(%{live_action: :new}), do: nil

  defp stop_edit_blocker_assigns(%{detail_custom_trip_count: count}) when count > 0,
    do: "Stops can’t change while custom-time trips use this pattern."

  defp stop_edit_blocker_assigns(_assigns), do: nil

  # What a new pattern still needs, or that it is ready: creation always
  # validates on click, so the button stays available and names the gap.
  defp creation_status(assigns) do
    needs =
      [
        if(String.trim(assigns.details_params["name"] || "") == "", do: "a pattern name"),
        case length(assigns.staged_occurrences) do
          0 -> "at least two stops"
          1 -> "one more stop"
          _ -> nil
        end
      ]
      |> Enum.reject(&is_nil/1)

    if needs == [] do
      %{tone: :ready, text: "Ready to create. It starts with one timing set to zero."}
    else
      %{
        tone: :neutral,
        text:
          "To create the pattern, add #{Enum.join(needs, " and ")}. It starts with one timing set to zero."
      }
    end
  end

  # The unsaved work the leave-page dialog names.
  defp unsaved_summary(assigns) do
    dirty = tab_dirty(assigns)

    parts =
      [
        if(dirty.stops, do: "stop changes"),
        if(dirty.timings, do: "running-time edits"),
        if(dirty.alignment, do: "unsaved paths"),
        if(dirty.details, do: "detail changes")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "You have unsaved changes on this page."
      parts -> "You have #{Enum.join(parts, ", ")} on this page."
    end
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

    dirty? = dirty? or other_changes_dirty?(socket)

    if socket.assigns.dirty? == dirty? do
      socket
    else
      push_event(assign(socket, :dirty?, dirty?), "route_pattern_dirty", %{dirty: dirty?})
    end
  end

  defp other_changes_dirty?(socket) do
    socket.assigns.stops_dirty? or alignment_dirty?(socket) or
      map_size(socket.assigns[:alignment_suggestions] || %{}) > 0 or
      (socket.assigns.live_action == :new and socket.assigns.staged_occurrences != []) or
      map_size(socket.assigns.timing_edits) > 0 or
      map_size(socket.assigns.timing_headsign_edits) > 0
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
    assign(socket, :build_summary, %{
      created: Map.get(summary, :patterns_created, 0),
      linked: Map.get(summary, :trips_linked, 0),
      custom: Map.get(summary, :trips_custom, 0)
    })
  end

  defp affected_message(0), do: "Changes saved in this version."

  defp affected_message(1), do: "Changes saved in this version. 1 trip updated."

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
    do: "Acknowledge the proposed stop values for every timing before saving."

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
    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{socket.assigns.route_id}/patterns"
  end

  defp version_patterns_path(socket, version_id) do
    ~p"/gtfs/#{version_id}/routes/#{socket.assigns.route_id}/patterns"
  end

  defp pattern_path(socket, pattern_id, query) do
    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{socket.assigns.route_id}/patterns/#{pattern_id}" <>
      query
  end

  defp task_path(socket, task) do
    base =
      case socket.assigns.live_action do
        :new -> "#{patterns_path(socket)}/new"
        _ -> pattern_path(socket, socket.assigns.pattern_id, "")
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
