defmodule GtfsPlannerWeb.Gtfs.RouteDetailLive do
  @moduledoc """
  Route › Details: the route's saved values, editable in the shared route form
  controls, beside the reserved map column.

  The whole workspace comes from one operational read, `Gtfs.load_route_editor/3`
  through the configured catalog read adapter (default
  `GtfsPlanner.Gtfs.CatalogReadAdapter.Repo`): the route, its trusted source, the
  version's agency options and mode counts, and the last route audit entry. A
  foreign or unpublished scope is not-found and a lost database connection is
  unavailable, and the two are never presented as each other.

  The header states saved identity, not draft identity: the badge, the name, the
  mode and the `Agency · Route ID · Last saved` line all read the saved route and
  its last audit entry, and a route with no audit entry reads as unknown/imported
  attribution rather than borrowing a recent actor. The form controls are the
  shared stateless ones (`RouteFormComponents`), so Details and the create drawer
  cannot drift into two field grammars.

  A draft is preview, never truth (R7, C-2, INV-6): every form change re-validates
  the submitted values through the same `Route.editor_changeset/3` a save will use,
  applies the valid changes to the saved row for the header/chip preview, and
  names the changed fields in the sticky save bar. Invalid input keeps the saved
  value and its own error line rather than reaching a style attribute.

  Status belongs to the step-9 command (`Gtfs.set_route_active/4`) with the saved
  identity this workspace loaded: Deactivate confirms first and only then writes
  boolean false with its audit; Reactivate and Undo act at once because they are
  the safe direction. A dirty draft resolves save/discard/keep-editing before the
  status review opens. Only explicit false is inactive: NULL and true show the
  active state everywhere (INV-4). The saved eligibility re-reads on re-entry and
  after reconnect without rebasing a draft; older exports are always described as
  unchanged.

  Save goes through the audited update command (`Gtfs.update_route/5`): the
  submission carries the trusted base source the workspace was loaded with, and
  the command decides. A clean save writes the draft minus base and its route
  audit atomically; a rejected or failed save keeps the draft on screen; a
  no-op save writes nothing. When another editor saved first, the command
  returns the fresh current source and a field-level comparison instead of
  writing, and the workspace shows that comparison: disjoint changes are
  offered one deliberate "Save both changes", overlapping fields require an
  explicit per-field keep-mine/use-saved choice, and "Discard my changes"
  reloads the latest saved values. A merge submission is bound to the revision
  the comparison was displayed with, so a third writer's save is re-presented
  as a fresh comparison instead of being overwritten.

  Dirty navigation is guarded (AC-22): the client hook intercepts tabs, internal
  links, browser back and version selection before they dispatch, and this
  LiveView owns the "Leave without saving?" dialog. Keep editing restores the
  page untouched; Discard leaves writing nothing; Save and continue commits the
  server-held draft and navigates only after the command succeeds. Cancelling a
  version change never dispatches the selected-version global state, and a
  native beforeunload warning covers every other full-page departure.
  """
  use GtfsPlannerWeb, :live_view
  require Logger
  alias Ecto.Changeset
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Gtfs.RouteFormComponents

  import GtfsPlannerWeb.PlannerComponents,
    only: [back_link: 1, form_error_summary: 1, message: 1]

  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1, route_label: 1]
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The dirty save bar names the fields a save would change, in the editor's own
  # order, the way the reference names them.
  @detail_field_labels [
    route_short_name: "Route number",
    route_long_name: "Route name",
    route_type: "Mode",
    route_color: "Route color",
    route_text_color: "Text color",
    route_desc: "Description",
    route_url: "Web page",
    agency_id: "Agency",
    route_sort_order: "Display order",
    continuous_pickup: "Pickup between stops",
    continuous_drop_off: "Drop-off between stops",
    network_id: "Network"
  ]

  # The fields the header itself shows, so the "Unsaved preview" chip marks a
  # header that is describing a draft rather than the saved row.
  @preview_fields [
    :route_short_name,
    :route_long_name,
    :route_type,
    :route_color,
    :route_text_color
  ]

  # The toast the reference shows when a conflict is discarded or a base-equal
  # draft meets a changed current: the latest saved values are loaded.
  @discard_reload_message "Loaded the latest saved route. Your changes were discarded."

  # The deletion review's lead categories: what an operator counts before
  # agreeing to delete. Every other category is in the review's disclosure.
  @delete_lead_keys ~w(patterns trips transfers fare_rules)
  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Route Details")
     |> assign(:user_roles, user_roles)
     |> assign(:active_tab, :details)
     |> assign(:route_state, :loading)
     |> assign(:focus_heading?, false)
     |> assign(:route_form, nil)
     |> assign(:agencies, [])
     |> assign(:mode_counts, [])
     |> assign(:warning_candidates, [])
     |> assign(:geometry_status, nil)
     |> assign(:route_map_data, nil)
     |> assign(:show_context, false)
     |> assign(:route_context, nil)
     |> assign(:route_context_status, nil)
     |> assign(:route_context_bounds, nil)
     |> assign(:route_context_cursor, nil)
     |> assign(:last_saved, nil)
     |> assign(:draft_route, nil)
     |> assign(:route_text_mode, nil)
     |> assign(:changed_fields, [])
     |> assign(:field_warnings, field_warnings_for_clean_load(nil, [], [], nil))
     |> assign(:merge, nil)
     |> assign(:save_outcome, nil)
     |> assign(:pending_navigation, nil)
     |> assign(:details_blocked?, false)
     |> assign(:active_state, nil)
     |> assign(:status_dialog, nil)
     |> assign(:status_outcome, nil)
     |> assign(:usage, nil)
     |> assign(:delete_review, nil)
     |> assign(:delete_changes, [])
     |> assign(:delete_previous_categories, nil)
     |> assign(:delete_ack_error, nil)
     |> assign(:delete_acknowledged?, false)
     |> assign(:delete_error, nil)
     |> assign(:delete_pending, false)
     |> assign(:delete_task, nil)}
  end

  @impl true
  def handle_params(%{"route_id" => route_id} = params, _uri, socket) do
    active_tab = socket.assigns[:live_action] || :details

    socket =
      socket
      |> assign(:route_id, route_id)
      |> assign(:active_tab, active_tab)
      # The create drawer lands here with `?created=1`; this is the only arrival
      # that moves focus, so a later tab switch or reload reads normally.
      |> assign(:focus_heading?, params["created"] in ["1", "true"])

    {:noreply, load_route_workspace(socket)}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    {:noreply, load_route_workspace(socket)}
  end

  # --- other-route context (R7, step 31) --------------------------------------

  # The hook pushes this when the operator toggles "Show other routes" and on
  # every map move while it is on. Events are handled sequentially in this one
  # LiveView process, so the newest event always wins: turning context off
  # clears every context assign before anything older could render, and no
  # in-flight read can outlive it — a stale viewport response can never
  # replace newer state (AC-27). The checkbox and its keyboard operation stay
  # the hook's; this boundary only ever sees the resulting event.
  @impl true
  def handle_event("route_context_viewport", params, socket) do
    if socket.assigns.route_state == :ready and params["enabled"] in [true, "true"] do
      load_route_context(socket, params["bounds"], nil)
    else
      {:noreply, clear_route_context(socket)}
    end
  end

  # The partial strip's "Show more routes": the next keyset page for the
  # viewport the operator is still looking at, appended to what is shown.
  @impl true
  def handle_event("more_route_context", _params, socket) do
    context = socket.assigns.route_context

    if socket.assigns.show_context and is_map(context) and is_binary(context.next_cursor) do
      case context_map_read(socket, socket.assigns.route_context_bounds, context.next_cursor) do
        {:ok, page} ->
          merged = %{
            context
            | partial: page.partial,
              next_cursor: page.next_cursor,
              routes: context.routes ++ page.routes
          }

          {:noreply,
           socket
           |> assign(:route_context, merged)
           |> assign(:route_context_status, :ok)
           |> assign(:route_context_cursor, merged.next_cursor)}

        {:error, _reason} ->
          {:noreply, assign(socket, :route_context_status, :error)}
      end
    else
      {:noreply, socket}
    end
  end

  # The strip's Retry: a full page-one reload for the last viewport the hook
  # reported, replacing whatever is on screen. A failed load keeps the last
  # good bounds (nil on the very first failure), so retry repeats a transient
  # loss instead of repeating a malformed request.
  @impl true
  def handle_event("retry_route_context", _params, socket) do
    if socket.assigns.show_context and socket.assigns.route_context_bounds do
      load_route_context(socket, socket.assigns.route_context_bounds, nil)
    else
      {:noreply, socket}
    end
  end

  # Every form change re-validates the draft and reports which fields a save
  # would change. The draft stays on screen (the invalid values are echoed back),
  # the changed fields drive the sticky save bar, and nothing is written.
  @impl true
  def handle_event("validate_route_details", params, socket) do
    {:noreply, assign_details_draft(socket, detail_attrs(params), :validate)}
  end

  # Save is the audited update command the form's Ctrl/Cmd+S shortcut emits as
  # one ordinary submit. The draft is re-validated first so a rejected save
  # loses nothing (AC-21), then the command — carrying the trusted base source
  # the workspace was loaded with — decides what the submission means (R4).
  @impl true
  def handle_event("save_route_details", params, socket) do
    if socket.assigns.route_state == :ready and not socket.assigns.details_blocked? do
      attrs = detail_attrs(params)
      socket = assign_details_draft(socket, attrs, :validate)
      run_details_save(socket, attrs, params)
    else
      {:noreply, socket}
    end
  end

  # The client pushes this once its socket is back after a disconnect with the
  # workspace on screen (AC-23). Before the offline block clears, the scope and
  # membership are revalidated here: a revoked editor keeps the draft with the
  # save disabled, and a still-authorized editor gets the block cleared. The
  # workspace is never re-read for this — the trusted base source this socket
  # loaded stays the save's base, so a fresh read can never silently rebase a
  # draft the operator has not reviewed (R2, CL-7).
  @impl true
  def handle_event("recover_route_details", _params, socket) do
    if socket.assigns.route_state != :ready or socket.assigns.details_blocked? do
      {:noreply, socket}
    else
      recover_route_details(socket)
    end
  end

  # Cancel restores the saved row and its preview; during a merge it reloads
  # the latest saved values instead, because the route's saved truth has moved
  # on from the row the draft was started from. Either way it writes nothing
  # (AC-19/AC-21), and the advisories go back to the loaded workspace's.
  @impl true
  def handle_event("discard_route_details", _params, socket) do
    {:noreply, discard_details(socket)}
  end

  # The merge panel's own discard: same honest outcome as the save bar's
  # discard during a conflict — the draft is thrown away and the latest saved
  # values are loaded (the reference's "Loaded the latest saved route" toast).
  @impl true
  def handle_event("discard_merge", _params, socket) do
    {:noreply, reload_latest_saved(socket, @discard_reload_message)}
  end

  # --- route status (R4, step 9 command) -------------------------------------

  # Deactivate opens the status review. A dirty draft resolves first (R4): the
  # click holds behind the leave dialog's save/discard/keep-editing actions and
  # the review opens only after the draft is resolved, so a lifecycle decision
  # is never made against unreviewed work.
  @impl true
  def handle_event("open_deactivate_route", _params, socket) do
    if socket.assigns.route_state == :ready and not socket.assigns.details_blocked? do
      if details_dirty?(socket) do
        {:noreply, assign(socket, :pending_navigation, :status_review)}
      else
        {:noreply, open_status_review(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  # "Keep active" closes the review with nothing dispatched and nothing written.
  @impl true
  def handle_event("cancel_deactivate_route", _params, socket) do
    {:noreply, assign(socket, :status_dialog, nil)}
  end

  # The review's confirm: the step-9 command with the workspace's saved source.
  @impl true
  def handle_event("confirm_deactivate_route", _params, socket) do
    if socket.assigns.status_dialog != nil and socket.assigns.route_state == :ready do
      {:noreply, run_route_status(socket, false)}
    else
      {:noreply, socket}
    end
  end

  # Reactivate from the banner, the status row or the Undo action after a
  # deactivation. The safe direction acts without a confirmation; the command
  # still reauthorizes and rechecks the saved identity in its own transaction.
  @impl true
  def handle_event("reactivate_route", _params, socket) do
    if socket.assigns.route_state == :ready and not socket.assigns.details_blocked? do
      {:noreply, run_route_status(socket, true)}
    else
      {:noreply, socket}
    end
  end

  # --- reviewed deletion (R5, the step-11/12 commands) -----------------------

  # Delete opens the reviewed impact first: the review is the step-11 command,
  # so the dialog never guesses an impact from the page's cached counts. A
  # dirty draft resolves first (R4), exactly like the status review.
  @impl true
  def handle_event("open_delete_route", _params, socket) do
    if socket.assigns.route_state == :ready and not socket.assigns.details_blocked? do
      if details_dirty?(socket) do
        {:noreply, assign(socket, :pending_navigation, :delete_review)}
      else
        {:noreply, open_delete_review(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  # "Keep route" closes the review with nothing dispatched and nothing written.
  # A pending apply cannot be cancelled from here: the command owns the
  # transaction and its outcome speaks for itself (AC-24's locked pending).
  @impl true
  def handle_event("cancel_delete_route", _params, socket) do
    if socket.assigns.delete_pending do
      {:noreply, socket}
    else
      {:noreply, clear_delete_dialog(socket)}
    end
  end

  # The acknowledgement checkbox's own change event: a shown acknowledgement
  # error clears as soon as the operator acknowledges (the reference's
  # behavior), and nothing is written. The checkbox state is server-owned, so
  # the patch that clears the error keeps the box ticked.
  @impl true
  def handle_event("acknowledge_delete", params, socket) do
    {:noreply,
     socket
     |> assign(:delete_ack_error, nil)
     |> assign(:delete_acknowledged?, get_in(params, ["delete", "acknowledged"]) == "on")}
  end

  # The review's confirm: the step-12 command with the reviewed fingerprint and
  # a fresh acknowledgement. The complete review refuses an unchecked box at
  # the boundary — the server's `false` acknowledgement refusal stays the
  # authority (R5), the dialog error is the fast local path.
  @impl true
  def handle_event("confirm_delete_route", params, socket) do
    acknowledged? = get_in(params, ["delete", "acknowledged"]) == "on"
    confirm_delete(socket, acknowledged?)
  end

  # The empty plan's single deliberate click is its own acknowledgement: there
  # is nothing beyond the route row to acknowledge (R5's simple dialog). The
  # event only works for an actually-empty plan — a complete review is never
  # confirmed without its checkbox.
  @impl true
  def handle_event("confirm_delete_route_simple", _params, socket) do
    case socket.assigns.delete_review do
      %{empty?: true} -> confirm_delete(socket, true)
      _other -> {:noreply, socket}
    end
  end

  # "Deactivate instead" swaps the irreversible review for the reversible one:
  # the delete dialog closes and the deactivate confirmation opens.
  @impl true
  def handle_event("delete_deactivate_instead", _params, socket) do
    if socket.assigns.delete_review != nil and not socket.assigns.delete_pending do
      {:noreply, socket |> clear_delete_dialog() |> open_status_review()}
    else
      {:noreply, socket}
    end
  end

  # --- dirty navigation ------------------------------------------------------

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket),
    do: handle_version_switch(socket, version_id)

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket),
    do: handle_version_switch(socket, version_id)

  # The client guard intercepts a same-origin link (tabs, the back button in its
  # click form, header and list links) before the browser dispatches it and asks
  # the server what to do; the server owns the dialog. A clean page navigates
  # straight away. Browser history traversal arrives through the same event
  # after the client restored the URL, so the destination is guarded identically.
  @impl true
  def handle_event("guard_details_navigation", %{"path" => path}, socket) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
      do: guard_navigation(socket, path),
      else: {:noreply, socket}
  end

  def handle_event("guard_details_navigation", _params, socket), do: {:noreply, socket}

  # Keep editing closes the dialog with nothing dispatched and nothing written:
  # the draft, the focused controls and the URL are exactly as they were (AC-22).
  @impl true
  def handle_event("leave_keep_editing", _params, socket) do
    {:noreply, assign(socket, :pending_navigation, nil)}
  end

  # Discard leaves without saving: the draft dies with this resolution and the
  # saved row is never touched. A cross-version destination keeps the switcher's
  # selected-version state in step, exactly as an unguarded switch would. When
  # the held action was opening the status review, the resolved draft is followed
  # by that review (R4's dirty-details resolution).
  @impl true
  def handle_event("leave_discard", _params, socket) do
    case socket.assigns.pending_navigation do
      nil ->
        {:noreply, socket}

      :status_review ->
        {:noreply, socket |> discard_details() |> clear_pending() |> open_status_review()}

      :delete_review ->
        {:noreply, socket |> discard_details() |> clear_pending() |> open_delete_review()}

      path ->
        {:noreply, guarded_navigate(socket, path)}
    end
  end

  # "Save and continue" commits the server-held draft and only then navigates:
  # run_details_save consumes the pending destination, so a rejected or conflicted
  # save keeps the operator on the page with the draft and its errors (AC-22).
  @impl true
  def handle_event("leave_save_route", _params, socket) do
    if socket.assigns.route_state == :ready do
      attrs = draft_attrs(socket)
      socket = assign_details_draft(socket, attrs, :validate)
      run_details_save(socket, attrs, %{"leave_nav" => "true"})
    else
      {:noreply, socket}
    end
  end

  # The leave dialog submits the draft the server already validated: every
  # keystroke reached it through the form's phx-change before the guard could
  # open, so the stored params are the on-screen draft, never a second grammar.
  defp draft_attrs(socket), do: socket.assigns.route_form.source.params

  # --- reviewed deletion helpers (R5) -----------------------------------------

  defp confirm_delete(socket, acknowledged?) do
    review = socket.assigns.delete_review

    cond do
      is_nil(review) or socket.assigns.delete_pending ->
        # A closed review, a replayed confirm or a second confirm while the
        # apply is pending cannot start a second delete (AC-24's locked
        # pending): the controls are disabled and this boundary refuses too.
        {:noreply, socket}

      not review.empty? and not acknowledged? ->
        {:noreply,
         socket
         |> assign(
           :delete_ack_error,
           "Check the box to confirm that the route and everything listed above should be deleted."
         )
         |> push_event("focus_scoped_target", %{id: "route-delete-ack"})}

      true ->
        {:noreply, start_route_delete(socket, review)}
    end
  end

  # One delete at a time: the command runs in a supervised task so the pending
  # state renders and every competing control stays locked (R5's async apply).
  # The task ref is matched in handle_info, so a late or foreign message can
  # never classify as this delete's result.
  defp start_route_delete(socket, review) do
    route_id = socket.assigns.route.route_id
    audit = audit_context(socket)

    task =
      Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn ->
        Gtfs.delete_route(route_id, review.fingerprint, true, audit)
      end)

    socket
    |> assign(:delete_task, task)
    |> assign(:delete_pending, true)
    |> assign(:delete_ack_error, nil)
    |> assign(:delete_error, nil)
  end

  @impl true
  def handle_info({ref, result}, socket) do
    if socket.assigns.delete_task && socket.assigns.delete_task.ref == ref do
      {:noreply,
       classify_route_delete(
         socket |> assign(:delete_task, nil) |> assign(:delete_pending, false),
         result
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if socket.assigns.delete_task && socket.assigns.delete_task.ref == ref do
      Logger.error("Route delete task crashed: #{inspect(reason)}")

      classify_route_delete(
        socket |> assign(:delete_task, nil) |> assign(:delete_pending, false),
        {:error, :task_crashed}
      )
    else
      {:noreply, socket}
    end
  end

  # The draft resolver behind both discard paths: restore the loaded row and
  # its advisories, or reload the latest saved values during a merge. Either
  # way nothing is written (AC-19/AC-21).
  defp discard_details(socket) do
    if socket.assigns.merge do
      reload_latest_saved(socket, @discard_reload_message)
    else
      route = socket.assigns.route

      socket
      |> assign(:route_form, route_form(route))
      |> assign(:draft_route, route)
      |> assign(:route_text_mode, nil)
      |> assign(:changed_fields, [])
      |> assign(
        :field_warnings,
        field_warnings_for_clean_load(
          route,
          socket.assigns.agencies,
          socket.assigns.warning_candidates,
          socket.assigns.geometry_status
        )
      )
    end
  end

  defp clear_pending(socket), do: assign(socket, :pending_navigation, nil)

  defp recover_route_details(socket) do
    if editor_access?(socket) do
      {:noreply,
       socket
       |> assign(:details_blocked?, false)
       |> refresh_eligibility()
       |> push_event("route_recovery", %{
         state: "retryable",
         message: "Connection restored. Your changes are preserved — you can save again."
       })}
    else
      message =
        "Connection restored, but you no longer have editor access to this organization. Your changes are still here, but you can't save them."

      {:noreply,
       socket
       |> assign(:details_blocked?, true)
       |> assign(:save_outcome, {:error, message})
       |> push_event("route_recovery", %{state: "blocked", message: message})}
    end
  end

  # Reconnect revalidates eligibility (AC-23): the saved status re-reads on its
  # own so the banner and the status row describe what is stored now. The draft
  # is never rebased — the trusted base source this socket loaded stays the
  # save's base (step 26). A transient read failure keeps the displayed state;
  # the next save or status action still reports the stored truth.
  defp refresh_eligibility(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_route_by_route_id(organization_id, gtfs_version_id, socket.assigns.route_id) do
      %Route{} = fresh ->
        assign(socket, :active_state, if(fresh.active == false, do: :inactive, else: :active))

      _missing ->
        socket
    end
  rescue
    DBConnection.ConnectionError -> socket
  end

  # Mount-time access is not enough for a write: the membership may have lost
  # the editor role or been deactivated since this socket connected.
  defp editor_access?(socket) do
    with %{id: user_id} <- socket.assigns[:current_user],
         %{id: organization_id} <- socket.assigns[:current_organization],
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(user_id, organization_id),
         true <- is_nil(membership.deactivated_at) do
      GtfsPlannerWeb.EnsureRole.has_role?(membership.roles, :pathways_studio_editor)
    else
      _other -> false
    end
  end

  # Version selection is guarded like every other departure: a dirty draft holds
  # the switch behind the leave dialog instead of dispatching it, so cancelling
  # never moves the selected-version global state or the current URL (AC-22).
  # An unchanged page navigates at once, with the switcher's stored selection
  # following the navigation the server starts.
  defp handle_version_switch(socket, version_id) do
    organization_id = socket.assigns.current_organization.id
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    route_id = socket.assigns[:route_id]

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(organization_id, version_id) do
      path = version_route_path(version_id, route_id)

      if details_dirty?(socket) do
        {:noreply, assign(socket, :pending_navigation, path)}
      else
        {:noreply, guarded_navigate(socket, path)}
      end
    else
      {:noreply, socket}
    end
  end

  defp guard_navigation(socket, path) do
    if details_dirty?(socket),
      do: {:noreply, assign(socket, :pending_navigation, path)},
      else: {:noreply, guarded_navigate(socket, path)}
  end

  # An open merge is unsaved work too: the honest discard is leaving without a
  # write, and a save must resolve the conflict first (R4, step 24).
  defp details_dirty?(socket),
    do: socket.assigns.changed_fields != [] or socket.assigns.merge != nil

  # Navigate to a guarded destination. A path into another version keeps the
  # selected-version global state (the switcher's stored selection) in step with
  # the navigation, the same write an unguarded switch would have made.
  defp guarded_navigate(socket, path) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    socket =
      case Regex.run(~r{^/gtfs/([^/]+)(/|$)}, path) do
        [_, version_id, _rest] ->
          if version_id == current_version_id do
            socket
          else
            push_event(socket, "gtfs_version_selected", %{version_id: version_id})
          end

        nil ->
          socket
      end

    push_navigate(socket, to: path)
  end

  defp version_route_path(version_id, route_id) do
    if route_id,
      do: ~p"/gtfs/#{version_id}/routes/#{route_id}",
      else: "/gtfs/#{version_id}/routes"
  end

  # The context read goes through the same facade chain as the current route's
  # map (RouteDetailLive -> Gtfs.route_context_map/4 ->
  # GtfsPlanner.Gtfs.Routes.Map.route_context_map/4). A success records the
  # bounds that produced it, so Retry and "Show more" repeat the viewport the
  # operator is actually looking at; a rejection keeps the previous page on
  # screen and the previous bounds, with the strip explaining the failure.
  defp load_route_context(socket, bounds, cursor) do
    case context_map_read(socket, bounds, cursor) do
      {:ok, context} ->
        {:noreply,
         socket
         |> assign(:show_context, true)
         |> assign(:route_context, context)
         |> assign(:route_context_status, :ok)
         |> assign(:route_context_cursor, context.next_cursor)
         |> assign(:route_context_bounds, bounds)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:show_context, true)
         |> assign(:route_context_status, :error)}
    end
  end

  defp context_map_read(socket, bounds, cursor) do
    Gtfs.route_context_map(
      socket.assigns.current_organization.id,
      socket.assigns.current_gtfs_version.id,
      socket.assigns.route.route_id,
      %{bounds: bounds, cursor: cursor}
    )
  end

  # The context layer describes *other* routes, so it survives a same-route
  # reload (a save) untouched and resets when a different route opens — a
  # stale current-route exclusion can never survive a route change.
  defp keep_route_context(socket, route) do
    previous = socket.assigns[:route]

    if previous != nil and previous.id != route.id do
      clear_route_context(socket)
    else
      socket
    end
  end

  defp clear_route_context(socket) do
    socket
    |> assign(:show_context, false)
    |> assign(:route_context, nil)
    |> assign(:route_context_status, nil)
    |> assign(:route_context_bounds, nil)
    |> assign(:route_context_cursor, nil)
  end

  # One workspace read, one classification. A missing/foreign scope redirects to
  # the scoped list with a flash and an unavailable database keeps the route on
  # screen behind its retry action; neither is rendered as the other.
  defp load_route_workspace(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.load_route_editor(organization_id, gtfs_version_id, socket.assigns.route_id) do
      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Route not found")
        |> push_navigate(to: "/gtfs/#{gtfs_version_id}/routes")

      {:error, :unavailable} ->
        assign(socket, :route_state, :unavailable)
        |> assign(:route_map_data, nil)

      {:ok, workspace} ->
        # The map read (R7, seam S-3) runs beside the editor read and fails
        # independently: its classification drives the boarding advisory, and
        # its payload drives the saved route map. Neither reaches the other.
        route_map_data =
          Gtfs.route_map(organization_id, gtfs_version_id, workspace.route.route_id)

        socket
        |> assign(:route, workspace.route)
        |> assign(:source, workspace.source)
        |> assign(:agencies, workspace.agencies)
        |> assign(:mode_counts, workspace.mode_counts)
        |> assign(:warning_candidates, workspace.warning_candidates)
        |> assign(:geometry_status, geometry_status(route_map_data))
        |> assign(:route_map_data, route_map_data)
        |> assign(:last_saved, workspace.last_saved)
        |> assign(:route_form, route_form(workspace.route))
        |> assign(:draft_route, workspace.route)
        |> assign(:route_text_mode, nil)
        |> assign(:changed_fields, [])
        |> assign(
          :field_warnings,
          field_warnings_for_clean_load(
            workspace.route,
            workspace.agencies,
            workspace.warning_candidates,
            geometry_status(route_map_data)
          )
        )
        |> assign(:merge, nil)
        |> assign(:save_outcome, nil)
        |> assign(:route_state, :ready)
        |> assign(:details_blocked?, false)
        |> assign(
          :active_state,
          if(workspace.route.active == false, do: :inactive, else: :active)
        )
        |> assign(:status_dialog, nil)
        |> assign(:status_outcome, nil)
        |> assign(:usage, Map.get(workspace, :usage))
        |> assign(:delete_review, nil)
        |> assign(:delete_changes, [])
        |> assign(:delete_previous_categories, nil)
        |> assign(:delete_ack_error, nil)
        |> assign(:delete_acknowledged?, false)
        |> assign(:delete_error, nil)
        |> assign(:delete_pending, false)
        |> assign(:delete_task, nil)
        |> keep_route_context(workspace.route)
        |> assign(
          :transfer_count,
          related_transfers(organization_id, gtfs_version_id, workspace.route)
        )
    end
  end

  # A freshly loaded workspace warns about nothing: the saved row is not a
  # draft, so imported values are presented without an advisory the operator
  # did not earn (AC-20). The map read fails independently of the editor read:
  # its failure only silences the boarding advisory, never the workspace.
  defp field_warnings_for_clean_load(route, agencies, candidates, geometry_status) do
    RouteFormComponents.field_warnings(%{
      draft: route || %{},
      changed: [],
      current_uuid: (route && route.id) || nil,
      candidates: candidates,
      agencies: agencies,
      geometry: geometry_status
    })
  end

  # The boarding advisory's own count comes from the step-17 map projection:
  # patterns whose connector sections are known missing. A failed read is
  # `:unavailable` — unknown geometry is never reported as missing (R7).
  defp geometry_status({:ok, route_map}) do
    %{
      patterns_missing: Enum.count(route_map.patterns, &pattern_missing_paths?/1),
      patterns: length(route_map.patterns)
    }
  end

  defp geometry_status({:error, _failure}), do: :unavailable

  defp pattern_missing_paths?(%{sections: sections}),
    do: Enum.any?(sections, &(&1.status == :missing))

  # The saved route rendered through the same editor changeset a save will use,
  # with no submitted values: the controls read the persisted row, and the form
  # already understands the field grammar the save path validates (R1/R4).
  defp route_form(route) do
    to_form(Route.editor_changeset(route, %{}, :edit), as: :route)
  end

  # One command call, every outcome classified. `base` is the trusted source
  # minted when the workspace loaded, so a replaced UUID, a changed scope or a
  # third writer's save can never authorize a silent overwrite (AC-9, CL-3).
  # A "Save and continue" submission carries the guarded destination: the save
  # consumes it, so only a committed save navigates and every other outcome —
  # rejection, conflict, a lost route — keeps the operator here with the draft.
  defp run_details_save(socket, attrs, params) do
    pending = details_save_pending(socket, params)
    socket = clear_pending(socket)
    choices = details_save_choices(socket, params)

    case Gtfs.update_route(
           socket.assigns.route.route_id,
           attrs,
           socket.assigns.source,
           choices,
           audit_context(socket)
         ) do
      {:ok, %{route: _saved}} when is_binary(pending) ->
        {:noreply, guarded_navigate(socket, pending)}

      {:ok, %{route: saved}} ->
        {:noreply, saved_details_continue(socket, saved, pending)}

      {:error, {:conflict, payload}} ->
        {:noreply, present_conflict(socket, payload)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, save_rejected(socket, changeset)}

      {:error, reason} ->
        {:noreply, details_save_failure(socket, reason)}
    end
  end

  # Only a navigation guarded by the leave dialog carries the draft into the
  # next page; any other pending marker waits for the save's own outcome.
  defp details_save_pending(socket, params) do
    if params["leave_nav"] == "true", do: socket.assigns.pending_navigation, else: nil
  end

  # A deliberate merge applies only on a merge submission of an open merge.
  defp details_save_choices(socket, params) do
    if merge_submission?(params) and socket.assigns.merge != nil,
      do: merge_choices(socket, params),
      else: %{}
  end

  # The save that unblocked a held review continues into it (R4).
  defp saved_details_continue(socket, saved, :status_review),
    do: saved_details(socket, saved) |> open_status_review()

  defp saved_details_continue(socket, saved, :delete_review),
    do: saved_details(socket, saved) |> open_delete_review()

  defp saved_details_continue(socket, saved, _pending),
    do: saved_details(socket, saved)

  # Each failure keeps the draft on screen and names what happened to it.
  defp details_save_failure(socket, :not_found) do
    route_gone(
      socket,
      "This route is no longer in this version. Open it again from the route list."
    )
  end

  # The same natural ID exists again, but it is a different route with a
  # different UUID: the old draft never authorizes it (AC-9).
  defp details_save_failure(socket, :stale) do
    route_gone(
      socket,
      "This route was deleted and created again with the same route ID. Open the new route from the route list."
    )
  end

  defp details_save_failure(socket, :forbidden) do
    save_not_saved(
      socket,
      "Not saved: your editor access was removed. Your changes are still on this page, but you can't save them. Ask an admin to restore editor access."
    )
  end

  defp details_save_failure(socket, :busy) do
    save_not_saved(
      socket,
      "Not saved: the server is busy right now. Your changes are still here — try Save again."
    )
  end

  # The mutation and its audit commit together, so nothing was changed.
  defp details_save_failure(socket, :failed_audit) do
    save_not_saved(
      socket,
      "Not saved: your changes could not be recorded. Nothing was changed — try Save again."
    )
  end

  defp details_save_failure(socket, _other) do
    save_not_saved(
      socket,
      "Not saved: something went wrong. Your changes are still here — try Save again."
    )
  end

  # A clean save (or a deliberate merge) reloads the workspace through the
  # ordinary production read, so the form, the attribution line and the fresh
  # source all describe what is actually stored now (INV-6). A no-op save
  # reports exactly that instead of claiming a change was saved.
  defp saved_details(socket, saved) do
    message =
      if saved.updated_at == socket.assigns.route.updated_at do
        {:saved, "Nothing to save — the route already matches your draft."}
      else
        {:saved, "Changes to Route #{saved.route_id} saved."}
      end

    socket
    |> load_route_workspace()
    |> assign(:save_outcome, message)
    |> push_event("focus_scoped_target", %{id: "route-title"})
  end

  # Another editor saved first. A draft with nothing of its own (base-equal)
  # has no merge to offer: the latest saved values are loaded and the operator
  # is told what happened, never shown a merge against a draft that changes
  # nothing. Otherwise the workspace displays the command's comparison: the
  # fresh current source binds every later merge choice to the revision that
  # was displayed (R4), and the attribution line is refreshed so "saved by"
  # names the editor who actually saved last.
  defp present_conflict(socket, payload) do
    if socket.assigns.changed_fields == [] do
      reload_latest_saved(
        socket,
        "Another editor saved this route while it was open. The latest saved values are loaded."
      )
    else
      socket
      |> assign(:merge, payload)
      |> assign(:save_outcome, nil)
      |> refresh_conflict_attribution()
      |> push_event("focus_scoped_target", %{id: "route-conflict"})
    end
  end

  defp refresh_conflict_attribution(socket) do
    case Gtfs.load_route_editor(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           socket.assigns.route_id
         ) do
      {:ok, workspace} ->
        socket
        |> assign(:last_saved, workspace.last_saved)
        |> assign(:agencies, workspace.agencies)
        |> assign(:mode_counts, workspace.mode_counts)
        |> assign(:warning_candidates, workspace.warning_candidates)

      _failure ->
        socket
    end
  end

  defp reload_latest_saved(socket, message) do
    socket
    |> load_route_workspace()
    |> put_flash(:info, message)
  end

  # A rolled-back changeset is the command's own verdict on the submitted
  # values: the draft keeps every typed value, the invalid fields carry their
  # inline errors, and the message region names what to fix.
  defp save_rejected(socket, changeset) do
    socket
    |> assign(:route_form, changeset |> Map.put(:action, :validate) |> to_form(as: :route))
    |> assign(:save_outcome, {:invalid, "Not saved. Fix these fields, then save again."})
    |> push_event("focus_form_error", %{
      form_id: "route-details-form",
      fallback_id: "route-details-form-message"
    })
  end

  defp save_not_saved(socket, message) do
    socket
    |> assign(:save_outcome, {:error, message})
    |> push_event("focus_scoped_target", %{id: "route-details-form-message"})
  end

  defp route_gone(socket, message) do
    socket
    |> put_flash(:error, message)
    |> push_navigate(to: "/gtfs/#{socket.assigns.current_gtfs_version.id}/routes")
  end

  # --- route status helpers (R4, step 9 command) ------------------------------

  # One status command call, every outcome classified. The saved identity is the
  # workspace's source: a real change reauthorizes inside the transaction, locks
  # the scoped version first and writes boolean state with its audit; a request
  # for already-effective state is a no-op that writes nothing (INV-4). Every
  # outcome reloads through the ordinary production read, so the banner, the
  # chip and the status row can never disagree with the stored row (INV-6).
  defp run_route_status(socket, desired_active) do
    route = socket.assigns.route

    case Gtfs.set_route_active(
           route.route_id,
           desired_active,
           socket.assigns.source,
           audit_context(socket)
         ) do
      {:ok, %{route: saved}} ->
        message = route_status_message(saved)

        socket
        |> load_route_workspace()
        |> assign(:status_outcome, %{message: message, undo?: saved.active == false})
        |> focus_status_outcome()

      {:error, :not_found} ->
        route_gone(
          socket,
          "This route is no longer in this version. Open it again from the route list."
        )

      # The stored revision moved underneath this socket, so the request was
      # refused and nothing was written. The reload shows the current state and
      # the Undo offer is dropped — a refused change is never re-applied.
      {:error, :stale} ->
        socket
        |> load_route_workspace()
        |> assign(
          :status_outcome,
          %{
            message:
              "The route changed just now, so the status request was refused. The latest saved route is loaded.",
            undo?: false,
            kind: "warning"
          }
        )
        |> focus_status_outcome()

      {:error, :forbidden} ->
        status_refused(
          socket,
          "Your editor access was removed. The route's status is unchanged — ask an admin to restore editor access."
        )

      {:error, :busy} ->
        status_refused(
          socket,
          "The server is busy right now. The route's status is unchanged — try again."
        )

      {:error, _other} ->
        status_refused(
          socket,
          "The status could not be changed. The route is unchanged — try again."
        )
    end
  end

  # Older exports are never described as changed: only the next export is
  # affected (AC-12), and the Undo action stays available right after a
  # deactivation — a real command call with the reloaded saved identity.
  defp route_status_message(saved) do
    if saved.active == false do
      "Route #{saved.route_id} deactivated. The next export leaves it out."
    else
      "Route #{saved.route_id} reactivated. The next export includes it."
    end
  end

  defp status_refused(socket, message) do
    socket
    |> assign(:status_dialog, nil)
    |> assign(:status_outcome, %{message: message, undo?: false, kind: "warning"})
    |> focus_status_outcome()
  end

  defp focus_status_outcome(socket) do
    push_event(socket, "focus_scoped_target", %{id: "route-status-outcome"})
  end

  # The status review payload: the counts the confirmation's export copy names.
  # Transfers come from the page's own count, trips and fare rules from the
  # workspace read (the R6 closure a future export leaves out). A count that was
  # not read keeps its sentence truthful without a number.
  defp open_status_review(socket) do
    usage = socket.assigns.usage || %{}

    assign(socket, :status_dialog, %{
      ref: route_label(socket.assigns.route),
      trips: Map.get(usage, :trips),
      transfers: socket.assigns.transfer_count,
      fare_rules: Map.get(usage, :fare_rules)
    })
  end

  defp deactivate_ref(route) do
    if route.route_short_name in [nil, ""], do: route.route_id, else: route.route_short_name
  end

  # The reviewed impact comes from the step-11 command, never the page's cached
  # counts: one serializable read names exactly what would be deleted and what
  # is kept. Opening failures keep the page and speak in the status outcome
  # region — the delete row lives in the same Status and removal section.
  defp open_delete_review(socket) do
    route = socket.assigns.route

    case Gtfs.review_route_deletion(route.route_id, audit_context(socket)) do
      {:ok, review} ->
        socket
        |> assign(:delete_review, review)
        |> assign(:delete_changes, [])
        |> assign(:delete_ack_error, nil)
        |> assign(:delete_acknowledged?, false)
        |> assign(:delete_error, nil)

      {:error, :not_found} ->
        route_gone(
          socket,
          "This route is no longer in this version. Open it again from the route list."
        )

      {:error, :forbidden} ->
        delete_open_refused(
          socket,
          "Your editor access was removed, so the route can't be deleted. Ask an admin to restore editor access."
        )

      {:error, :busy} ->
        delete_open_refused(
          socket,
          "The server is busy right now. Nothing was deleted — try Delete route again."
        )

      # A malformed cross-route timing reference blocks the whole review
      # atomically (AC-31); the route and every row are unchanged.
      {:error, :malformed_cross_route_timing} ->
        delete_open_refused(
          socket,
          "This route can't be deleted: a timing row links this route's trips to another route's patterns. Nothing was deleted. Fix the schedules first, or deactivate the route to keep the data."
        )

      {:error, _other} ->
        delete_open_refused(
          socket,
          "The deletion review could not be loaded. Nothing was deleted — try Delete route again."
        )
    end
  rescue
    DBConnection.ConnectionError ->
      delete_open_refused(
        socket,
        "The route data is unavailable right now. Nothing was deleted — try Delete route again."
      )
  end

  defp delete_open_refused(socket, message) do
    socket
    |> assign(:status_outcome, %{message: message, undo?: false, kind: "warning"})
    |> focus_status_outcome()
  end

  defp clear_delete_dialog(socket) do
    socket
    |> assign(:delete_review, nil)
    |> assign(:delete_changes, [])
    |> assign(:delete_ack_error, nil)
    |> assign(:delete_acknowledged?, false)
    |> assign(:delete_error, nil)
  end

  # The title says the consequence and names the route the way a sentence
  # would ("Delete Route 12?"); the empty plan and the complete review share it.
  defp delete_dialog_title(route), do: "Delete #{route_label(route)}?"

  defp delete_dialog_describedby(%{empty?: true}), do: "route-delete-simple-body"
  defp delete_dialog_describedby(_review), do: "route-delete-panel"

  # One command result, every outcome classified. Success navigates to the
  # scoped list with the actual removed counts (AC-24); a stale fingerprint
  # re-renders the fresh review, explains the changes, clears the
  # acknowledgement and deletes nothing (AC-13); every refusal keeps the route
  # and says so truthfully.
  defp classify_route_delete(socket, result) do
    route = socket.assigns.route

    case result do
      {:ok, %{deleted: deleted}} ->
        socket
        |> put_flash(:info, route_deleted_message(route, deleted))
        |> push_navigate(to: "/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?deleted=1")

      {:error, {:stale_review, fresh}} ->
        present_stale_delete_review(socket, fresh)

      {:error, :not_found} ->
        route_gone(
          socket,
          "This route is no longer in this version. Open it again from the route list."
        )

      {:error, :forbidden} ->
        delete_refused(
          socket,
          "Your editor access was removed. Nothing was deleted — ask an admin to restore editor access."
        )

      {:error, :busy} ->
        delete_refused(
          socket,
          "The server is busy right now. Nothing was deleted — try Delete route again."
        )

      {:error, :malformed_cross_route_timing} ->
        delete_refused(
          socket,
          "This route can't be deleted: a timing row links this route's trips to another route's patterns. Nothing was deleted. Fix the schedules first, or deactivate the route to keep the data."
        )

      {:error, :not_acknowledged} ->
        delete_refused(socket, "The deletion was not acknowledged. Nothing was deleted.")

      {:error, _other} ->
        delete_refused(
          socket,
          "The deletion could not be completed. Nothing was deleted — try Delete route again."
        )
    end
  end

  # A stale apply re-renders the review from the freshly recomputed snapshot
  # and re-clears the acknowledgement, so only a fresh confirm can apply it.
  defp present_stale_delete_review(socket, fresh) do
    previous_categories =
      case socket.assigns.delete_review do
        %{categories: categories} -> categories
        _other -> []
      end

    changes = Gtfs.deletion_review_changes(previous_categories, fresh.categories)

    socket
    |> assign(:delete_review, fresh)
    |> assign(:delete_changes, changes)
    |> assign(:delete_previous_categories, previous_categories)
    |> assign(:delete_ack_error, nil)
    |> assign(:delete_acknowledged?, false)
    |> assign(:delete_error, nil)
    |> push_event("focus_scoped_target", %{id: "route-delete-ack"})
  end

  defp delete_refused(socket, message) do
    socket
    |> assign(:delete_error, message)
    |> push_event("focus_scoped_target", %{id: "route-delete-error"})
  end

  # The list flash names the actual result (AC-24): the checked summary's real
  # removed counts, never the review's estimate alone.
  defp route_deleted_message(route, deleted) do
    patterns = Map.get(deleted, "patterns", 0)
    trips = Map.get(deleted, "trips", 0)
    ref = deactivate_ref(route)
    name = route_display_name(route)

    cond do
      patterns > 0 and trips > 0 ->
        "#{ref} #{name} deleted, with its #{plural_count(patterns, "pattern")} and #{plural_count(trips, "trip")}."

      patterns > 0 ->
        "#{ref} #{name} deleted, with its #{plural_count(patterns, "pattern")}."

      trips > 0 ->
        "#{ref} #{name} deleted, with its #{plural_count(trips, "trip")}."

      true ->
        "Route #{ref} deleted."
    end
  end

  defp plural_count(1, word), do: "1 #{word}"
  defp plural_count(count, word) when is_integer(count), do: "#{count} #{word}s"

  # The review's rows: every affected category in the review's own order
  # (AC-13), named the way an operator counts them, its scoped identities kept
  # for the disclosure, and after a stale apply the reviewed-then count struck
  # through beside the fresh one and a contents chip on equal-total changes. The
  # categories an operator counts (patterns, trips, transfer rules, fare rules)
  # and any row that changed while the review was open lead the table; if the
  # route has none of those, every row does.
  defp delete_impact_rows(assigns) do
    review = assigns.delete_review
    changed = Map.new(assigns.delete_changes, &{&1.key, &1.markers})
    previous = Map.new(assigns.delete_previous_categories || [], &{&1.key, &1})

    rows =
      for category <- review.categories,
          (category.key != "route" and category.count > 0) or
            Map.has_key?(changed, category.key) do
        markers = Map.get(changed, category.key, [])
        previous_category = previous[category.key]

        %{
          key: category.key,
          label: delete_category_label(category),
          count: category.count,
          previous_count:
            if(:count_changed in markers and previous_category != nil,
              do: previous_category.count,
              else: nil
            ),
          contents_changed?: :contents_changed in markers,
          primary?: category.key in @delete_lead_keys or markers != [],
          identities: identities_preview(category.identities)
        }
      end

    if Enum.any?(rows, & &1.primary?), do: rows, else: Enum.map(rows, &%{&1 | primary?: true})
  end

  defp delete_category_label(%{key: "patterns"}), do: "Patterns"
  defp delete_category_label(%{key: "transfers"}), do: "Transfer rules that mention it"
  defp delete_category_label(%{key: "pattern_stops"}), do: "Stops in patterns"
  defp delete_category_label(%{key: "timed_patterns"}), do: "Running-time sets"
  defp delete_category_label(%{key: "timed_pattern_stops"}), do: "Running-time rows"
  defp delete_category_label(%{key: "frequencies"}), do: "Frequency rules"
  defp delete_category_label(%{key: "blocks"}), do: "Vehicle blocks affected"
  defp delete_category_label(%{key: "route_networks"}), do: "Network links"
  defp delete_category_label(%{label: label}), do: label

  # Identities are disclosed, not truncated away: the first few are named and
  # the rest are counted, so the dialog stays one screen on a route-sized plan
  # while every identity remains inside the review the fingerprint binds.
  defp identities_preview(identities) do
    shown = Enum.take(identities, 3)
    hidden = length(identities) - length(shown)

    cond do
      identities == [] -> ""
      hidden > 0 -> Enum.join(shown, ", ") <> " and #{hidden} more"
      true -> Enum.join(shown, ", ")
    end
  end

  # "Stops stay: the 31 stops this route serves remain in this version." No stop
  # is ever deleted with a route, so the sentence is always there; it counts the
  # stops the removed trips served when there are any.
  defp delete_stays_sentence(review) do
    case Enum.find(review.retained, &(&1.key == "stops")) do
      %{count: 1} ->
        "Stops stay: the 1 stop this route serves remains in this version."

      %{count: count} when count > 1 ->
        "Stops stay: the #{count} stops this route serves remain in this version."

      _none ->
        "Stops stay: no stop is deleted."
    end
  end

  defp delete_retained_lines(review) do
    for entry <- review.retained, entry.count > 0 do
      preview = identities_preview(entry.identities)

      if preview == "" do
        "#{entry.label} (#{entry.count})"
      else
        "#{entry.label} (#{entry.count}: #{preview})"
      end
    end
  end

  # Removed trips leave their blocks naturally; the review counts the affected
  # distinct block IDs and the dialog says what that means (R5's table).
  defp delete_blocks_note(review) do
    case Enum.find(review.categories, &(&1.key == "blocks")) do
      %{count: count} when count > 1 ->
        "#{count} vehicle blocks lose these trips and keep their others."

      %{count: 1} ->
        "1 vehicle block loses these trips and keeps its others."

      _other ->
        nil
    end
  end

  # The stale apply's explanation (R5): no actor and no action is invented —
  # the review changed, and the highlighted rows below say which. Equal totals
  # with changed contents get their own sentence, so same counts are never
  # read as same data (AC-13).
  defp delete_banner(changes) do
    cond do
      Enum.any?(changes, &(:count_changed in &1.markers)) ->
        %{kind: :counts, text: "The counts changed while this was open."}

      changes != [] ->
        %{
          kind: :contents,
          text: "The contents changed while this was open, even though the counts are the same."
        }

      true ->
        nil
    end
  end

  # The acknowledgement repeats the counts the table shows, so agreeing is
  # agreeing to those numbers.
  defp delete_ack_label(review, route) do
    patterns = category_count(review, "patterns")
    trips = category_count(review, "trips")
    label = route_label(route)

    cond do
      patterns > 0 and trips > 0 ->
        "I understand this permanently deletes #{label}, its #{plural_count(patterns, "pattern")} and #{plural_count(trips, "trip")}."

      patterns > 0 ->
        "I understand this permanently deletes #{label} and its #{plural_count(patterns, "pattern")}."

      trips > 0 ->
        "I understand this permanently deletes #{label} and its #{plural_count(trips, "trip")}."

      true ->
        "I understand this permanently deletes #{label} and the records listed here."
    end
  end

  defp category_count(review, key) do
    case Enum.find(review.categories, &(&1.key == key)) do
      %{count: count} -> count
      _other -> 0
    end
  end

  # The delete row's own help line, from the page's already-read counts. The
  # exact impact is always the review that opens next, so an unknown count
  # keeps the sentence general instead of guessing one.
  defp delete_row_help(assigns) do
    patterns = geometry_patterns(assigns[:geometry_status])
    trips = assigns[:usage] && Map.get(assigns[:usage], :trips)
    label = route_label(assigns.route)

    cond do
      is_integer(patterns) and is_integer(trips) and patterns == 0 and trips == 0 ->
        "#{label} has no patterns or trips yet. The review confirms what would go with it."

      is_integer(patterns) and is_integer(trips) ->
        "Permanently removes #{label}, #{dependents_phrase(patterns, trips)}. Stops are kept."

      true ->
        "Permanently removes #{label} and what belongs only to it. Stops are kept. The review counts it first."
    end
  end

  # "its 2 patterns and 70 trips", leaving out a count of zero.
  defp dependents_phrase(patterns, trips) do
    counted =
      for {count, word} <- [{patterns, "pattern"}, {trips, "trip"}], count > 0 do
        plural_count(count, word)
      end

    "its " <> Enum.join(counted, " and ")
  end

  defp geometry_patterns(%{patterns: count}) when is_integer(count), do: count
  defp geometry_patterns(_other), do: nil

  # The deactivate confirmation names what the next export leaves out: "The next
  # export leaves out Route 12, its 70 trips, and the 4 transfer rules that
  # mention it." A count that was not read keeps its sentence truthful without a
  # number instead of guessing one.
  defp deactivate_consequence(dialog) do
    parts =
      Enum.reject(
        [
          dialog.ref,
          positive?(dialog.trips) && "its #{plural_count(dialog.trips, "trip")}",
          positive?(dialog.transfers) &&
            "the #{plural_count(dialog.transfers, "transfer rule")} that " <>
              if(dialog.transfers == 1, do: "mentions", else: "mention") <> " it",
          positive?(dialog.fare_rules) && "its #{plural_count(dialog.fare_rules, "fare rule")}"
        ],
        &(&1 == false)
      )

    "The next export leaves out #{to_sentence(parts)}."
  end

  defp to_sentence([one]), do: one
  defp to_sentence([a, b]), do: "#{a} and #{b}"

  defp to_sentence(parts),
    do: Enum.join(Enum.drop(parts, -1), ", ") <> ", and " <> List.last(parts)

  defp count_phrase(1, word), do: "1 #{word}"
  defp count_phrase(count, word) when is_integer(count), do: "#{count} #{word}s"

  defp positive?(count) when is_integer(count) and count > 0, do: true
  defp positive?(_other), do: false

  defp route_status_help(:inactive),
    do: "Left out when you export this version. Exports you already ran keep the route."

  defp route_status_help(_active),
    do: "Included when you export this version."

  defp field_label(field) do
    Keyword.get(@detail_field_labels, field, Phoenix.Naming.humanize(field))
  end

  # The merge panel's submit button is the only control named `merge_confirm`,
  # so a deliberate merge is exactly the submission that used it — the sticky
  # bar's Save stays a plain submission that the command rechecks.
  defp merge_submission?(params), do: params["merge_confirm"] == "true"

  defp merge_choices(socket, params) do
    fields =
      case params do
        %{"merge" => %{"fields" => fields}} when is_map(fields) ->
          fields
          |> copy_coupled_color_choice()
          |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

        _other ->
          %{}
      end

    # The command's contract carries per-field resolutions at the top level of
    # `choices` (compare_edit/4 picks the `@edit_fields` keys and ignores the
    # caller-owned binding keys), so the panel's choices are flattened in.
    %{
      confirm_merge: true,
      # Bound to the revision the comparison was displayed with; the command
      # rechecks it against the freshly locked row on every submission (R4).
      current_updated_at: socket.assigns.merge.source.updated_at
    }
    |> Map.merge(fields)
  end

  # The color pair is one edit unit, so the panel's single radio group names
  # one member and the choice is copied to the other before validation.
  defp copy_coupled_color_choice(fields) do
    cond do
      value = fields["route_color"] -> Map.put(fields, "route_text_color", value)
      value = fields["route_text_color"] -> Map.put(fields, "route_color", value)
      true -> fields
    end
  end

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  # The submitted form data: the `route[...]` fields plus the top-level transient
  # `text_mode` the shared color radios carry (R1 keeps it out of the schema).
  defp detail_attrs(%{"route" => attrs} = payload) when is_map(attrs),
    do: Map.put(attrs, "text_mode", payload["text_mode"])

  defp detail_attrs(payload), do: payload

  # One draft, four projections of it: the form the operator keeps editing, the
  # saved row with the valid changes applied (the header/chip preview), the
  # fields a save would change (the save bar), and the advisories the changed
  # values earn (AC-20). The dirty set is the changeset's own changes, so the
  # bar, the warnings and the save path cannot disagree about what changed.
  defp assign_details_draft(socket, attrs, action) do
    changeset =
      socket.assigns.route
      |> Route.editor_changeset(attrs, :edit)
      |> Map.put(:action, action)

    changed = changed_fields(changeset)
    draft_route = Changeset.apply_changes(changeset)

    socket
    |> assign(:route_form, to_form(changeset, as: :route))
    |> assign(:route_text_mode, attrs["text_mode"])
    |> assign(:draft_route, draft_route)
    |> assign(:changed_fields, changed)
    |> assign(:field_warnings, field_warnings(socket, draft_route, changed))
  end

  # The draft's own advisories: computed from the same applied draft the header
  # previews, against the workspace's scoped candidates (this route's own UUID
  # excluded), this version's agencies and the map projection's geometry status.
  # Only a changed relevant field warns, so the saved row the operator has not
  # touched never does (AC-20).
  defp field_warnings(socket, draft_route, changed) do
    RouteFormComponents.field_warnings(%{
      draft: draft_route,
      changed: changed,
      current_uuid: socket.assigns.route.id,
      candidates: socket.assigns.warning_candidates,
      agencies: socket.assigns.agencies,
      geometry: socket.assigns.geometry_status
    })
  end

  defp changed_fields(changeset) do
    changed = Map.keys(changeset.changes)

    for {field, _label} <- @detail_field_labels, field in changed, do: field
  end

  # The boarding advisory's action stays where the reference puts it: the
  # surface where the missing paths are added. The advisory itself is computed
  # against the saved map projection; only the destination is added here.
  defp boarding_href(nil, _version_id, _route_id), do: nil

  defp boarding_href(%{patterns_missing: _} = warning, version_id, route_id) do
    Map.put(warning, :href, ~p"/gtfs/#{version_id}/routes/#{route_id}/patterns")
  end

  defp changed_field_labels(fields) do
    for {field, label} <- @detail_field_labels, field in fields, do: label
  end

  # The dialog body names the draft the way the reference does — the route and
  # the fields that would be lost; an open merge names the collision instead.
  defp leave_message(_merge, route, fields) when fields != [] do
    "#{route_label(route)} has unsaved changes to: " <>
      Enum.join(changed_field_labels(fields), ", ") <> ". If you leave now, they are lost."
  end

  defp leave_message(_merge, _route, _fields) do
    "Another editor saved this route while it was open. Leaving now discards your unresolved draft."
  end

  # "Unsaved: Route color · Ctrl+S saves", with the reference's three-name
  # limit, so the bar stays one line at 375px.
  defp changed_fields_summary(fields) do
    labels = changed_field_labels(fields)

    Enum.join(Enum.take(labels, 3), ", ") <> more_labels(length(labels))
  end

  defp more_labels(count) when count > 3, do: " and #{count - 3} more"
  defp more_labels(_count), do: ""

  defp preview?(fields), do: Enum.any?(fields, &(&1 in @preview_fields))

  # The comparison table's rows, in editor order. `mine` is the draft's changed
  # set; `theirs` is what the command's comparison says the current has that
  # the draft does not: disjoint-theirs plus divergent overlaps. An identical
  # overlap shows the same value in both columns, so the table never claims a
  # disagreement that is not there.
  defp conflict_rows(merge, mine, draft) do
    comparison = merge.comparison
    divergent = MapSet.new(comparison.conflicting)
    compatible = MapSet.new(comparison.compatible)
    mine_set = MapSet.new(mine)
    theirs_only = MapSet.difference(MapSet.union(compatible, divergent), mine_set)

    mine_set
    |> MapSet.union(theirs_only)
    |> MapSet.to_list()
    |> editor_order()
    |> Enum.map(fn field ->
      in_theirs? = MapSet.member?(compatible, field) or MapSet.member?(divergent, field)

      %{
        label: field_label(field),
        mine:
          if(MapSet.member?(mine_set, field),
            do: display_value(field, Map.get(draft, field)),
            else: "No change"
          ),
        theirs:
          if(in_theirs?,
            do: display_value(field, Map.fetch!(merge.source.original, field)),
            else: "No change"
          )
      }
    end)
  end

  defp editor_order(fields), do: for({f, _} <- @detail_field_labels, f in fields, do: f)

  # The choice groups the merge panel renders for overlapping fields: one
  # group per field, with the coupled color pair collapsed into a single
  # group that names `route_color` (the command treats the pair as one unit).
  defp choice_groups(conflicting) do
    {pair, rest} =
      Enum.split_with(conflicting, &(&1 in [:route_color, :route_text_color]))

    rest_groups = Enum.map(editor_order(rest), &%{field: &1, label: field_label(&1)})

    if pair == [] do
      rest_groups
    else
      [%{field: :route_color, label: "Route colors"} | rest_groups]
    end
  end

  defp display_value(_field, nil), do: "—"

  defp display_value(field, value) when field in [:route_color, :route_text_color] do
    if value in [nil, ""], do: "—", else: "##{value}"
  end

  defp display_value(_field, value) when is_integer(value), do: Integer.to_string(value)
  defp display_value(_field, value) when is_binary(value), do: value
  defp display_value(_field, value), do: to_string(value)

  defp conflict_saved_by(merge, last_saved, current_user) do
    actor =
      case last_saved do
        %{actor_email: email}
        when is_binary(email) and email != "" and email != current_user.email ->
          email

        %{actor_id: id} when is_binary(id) ->
          id

        _other ->
          nil
      end

    saved_at =
      case merge.source.updated_at do
        %DateTime{} = at -> " at " <> Calendar.strftime(at, "%H:%M")
        _other -> ""
      end

    if actor do
      "#{actor} saved this route#{saved_at} while you were editing"
    else
      "Another editor saved this route#{saved_at} while you were editing"
    end
  end

  defp conflict_intro(:confirmation_required),
    do:
      "Nothing of yours is saved yet. You changed different fields, so both sets of changes can be kept."

  defp conflict_intro(:choices_required),
    do:
      "Nothing of yours is saved yet. You both changed some of the same fields — choose which value to keep for each below."

  defp conflict_intro(_other),
    do: "Nothing of yours is saved yet. Review the changes below."

  # "Agency · Route ID · Last saved": the saved agency resolved against this
  # version's agency options (falling back to the stored ID when the option is
  # gone), the natural ID, and the last route audit entry. A route with no audit
  # entry reads as imported/unknown attribution instead of borrowing an actor.
  defp saved_identity(route, agencies, last_saved) do
    [
      agency_label(route, agencies),
      "Route ID #{route.route_id}",
      "Last saved " <> last_saved_label(last_saved)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp agency_label(%{agency_id: nil}, _agencies), do: nil

  defp agency_label(%{agency_id: agency_id}, agencies) do
    case Enum.find(agencies, &(&1.agency_id == agency_id)) do
      %{agency_name: name} when is_binary(name) and name != "" -> name
      _none -> agency_id
    end
  end

  defp last_saved_label(nil), do: "never — imported or unknown attribution"

  defp last_saved_label(%{saved_at: %DateTime{} = saved_at} = saved) do
    "#{Calendar.strftime(saved_at, "%b %-d, %Y at %H:%M")} UTC by #{actor_label(saved)}"
  end

  defp last_saved_label(%{action: action} = saved), do: "#{action} by #{actor_label(saved)}"

  defp actor_label(%{actor_email: email}) when is_binary(email) and email != "", do: email
  defp actor_label(%{actor_id: actor_id}) when is_binary(actor_id), do: actor_id
  defp actor_label(_saved), do: "unknown attribution"

  # The related-transfer count is a direct facade call, never the catalog adapter
  # (CR-15): the details page's own read may be a substituted adapter, but the
  # count is the same predicate the filtered list uses (CR-4).
  defp related_transfers(organization_id, gtfs_version_id, route) do
    Gtfs.count_general_transfers(organization_id, gtfs_version_id, route: route.route_id)
  end

  # A route's display name follows the GTFS preference order, the same chain the
  # catalog and the create drawer use, so the heading never reads as blank.
  defp route_display_name(route) do
    route.route_long_name || route.route_short_name || route.route_id
  end

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
      <div id="route-detail-page" class="ds-page">
        <%= case @route_state do %>
          <% :unavailable -> %>
            <.back_link id="route-back" navigate={~p"/gtfs/#{@current_gtfs_version.id}/routes"}>
              Routes
            </.back_link>
            <div class="mt-4 max-w-[680px]">
              <.message id="route-unavailable" kind="error" title="This route didn't load">
                The route data didn't respond, so nothing is shown. Nothing has changed.
                <:action>
                  <.button
                    id="route-retry"
                    type="button"
                    variant="secondary"
                    class="min-h-11"
                    phx-click="retry"
                    phx-disable-with="Trying again…"
                  >
                    Try again
                  </.button>
                </:action>
              </.message>
            </div>
          <% :ready -> %>
            <%!-- The header states saved identity through the shared route header:
                   the badge, name and mode preview a draft (with the Unsaved tag)
                   while the identifying line stays the saved attribution
                   (AC-19, INV-6). --%>
            <div
              id="route-details-workspace"
              phx-hook="FormErrorFocus"
              data-focus-on-mount={if @focus_heading?, do: "route-title", else: nil}
            >
              <.route_header
                route={@draft_route}
                gtfs_version_id={@current_gtfs_version.id}
                active_tab={@active_tab}
                identifier={saved_identity(@route, @agencies, @last_saved)}
                preview={preview?(@changed_fields)}
                dirty={@changed_fields != [] or @merge != nil}
                focus_title={@focus_heading?}
                trip_count={@usage && Map.get(@usage, :trips)}
              />

              <%= cond do %>
                <% @active_tab == :details -> %>
                  <div
                    id="route-details-columns"
                    class="mt-6 grid items-start gap-6 pb-10 lg:grid-cols-[minmax(0,600px)_minmax(0,1fr)] xl:gap-8"
                  >
                    <div class="min-w-0">
                      <.form
                        :if={@route_form}
                        for={@route_form}
                        id="route-details-form"
                        novalidate
                        phx-change="validate_route_details"
                        phx-submit="save_route_details"
                        data-recovery="true"
                        data-recovery-event="recover_route_details"
                        class="rounded-card border border-subtle bg-white"
                      >
                        <div class="grid grid-cols-1 gap-8 p-5 sm:p-6">
                          <%!-- Connectivity state the client hook owns: hidden while
                           connected, filled locally while offline and with the
                           server's revalidation outcome after reconnect. The
                           server never writes it, so a queued stale event
                           cannot present a stale connectivity state. --%>
                          <p
                            id="route-details-recovery"
                            role="status"
                            hidden
                            class="text-[13px] text-default"
                          >
                          </p>
                          <%!-- One announcement region for the outcomes a save can
                           have: a saved confirmation, a rejected-save error,
                           or the merge comparison another editor's save
                           produced. It takes focus so the result is announced
                           and reachable from the keyboard (AC-28). --%>
                          <div
                            :if={@merge || @save_outcome}
                            id="route-details-form-message"
                            tabindex="-1"
                            class="grid gap-3 outline-none"
                          >
                            <RouteFormComponents.merge_conflict
                              :if={@merge}
                              merge={@merge}
                              saved_by={conflict_saved_by(@merge, @last_saved, @current_user)}
                              intro={conflict_intro(@merge.comparison.status)}
                              rows={conflict_rows(@merge, @changed_fields, @draft_route)}
                              groups={choice_groups(@merge.comparison.conflicting)}
                            />
                            <.message
                              :if={match?({:saved, _}, @save_outcome)}
                              id="route-details-saved"
                              kind="success"
                              title={elem(@save_outcome, 1)}
                            />
                            <.form_error_summary
                              :if={match?({:invalid, _}, @save_outcome)}
                              id="route-details-save-error"
                              title={elem(@save_outcome, 1)}
                              failures={
                                RouteFormComponents.error_failures(@route_form, "route-details")
                              }
                              class=""
                            />
                            <.message
                              :if={match?({:error, _}, @save_outcome)}
                              id="route-details-save-error"
                              kind="error"
                              title={elem(@save_outcome, 1)}
                            />
                          </div>

                          <section
                            aria-labelledby="route-details-identity-title"
                            class="grid gap-6"
                          >
                            <div>
                              <h2
                                id="route-details-identity-title"
                                class="text-base font-bold tracking-normal text-strong"
                              >
                                Name and appearance
                              </h2>
                              <p class="mt-1 text-[13px] text-muted">
                                What riders see in trip planners and on signs.
                              </p>
                            </div>

                            <RouteFormComponents.identity_fields
                              form={@route_form}
                              prefix="route-details"
                              mode_counts={@mode_counts}
                              agency_options={@agencies}
                              short_warning={@field_warnings[:short]}
                            />

                            <RouteFormComponents.color_fields
                              form={@route_form}
                              prefix="route-details"
                              text_mode={@route_text_mode}
                              heading_badge_id="route-badge"
                              nav_guard
                              nav_dirty={@changed_fields != [] or @merge != nil}
                              similar_warning={@field_warnings[:similar]}
                            />
                          </section>

                          <section
                            aria-labelledby="route-details-rider-title"
                            class="grid gap-6 border-t border-subtle pt-6"
                          >
                            <h2
                              id="route-details-rider-title"
                              class="text-base font-bold tracking-normal text-strong"
                            >
                              Rider information
                            </h2>

                            <RouteFormComponents.rider_fields
                              form={@route_form}
                              prefix="route-details"
                              url_warning={@field_warnings[:url]}
                            />
                          </section>

                          <RouteFormComponents.additional_details
                            form={@route_form}
                            prefix="route-details"
                            route_id={@route.route_id}
                            boarding_warning={
                              boarding_href(
                                @field_warnings[:boarding],
                                @current_gtfs_version.id,
                                @route.route_id
                              )
                            }
                          />
                        </div>

                        <%!-- The design system's save bar, the last row of the form
                             card and sticky at the bottom of the window: status
                             text at the left, Discard changes, then the one
                             primary. It shows only while a draft differs from
                             the saved row and names the fields a save would
                             change. Save is an ordinary submit, so Ctrl/Cmd+S
                             (wired in the route details editor hook) submits the
                             same way. --%>
                        <div
                          id="route-details-save-bar"
                          hidden={@changed_fields == []}
                          class="sticky bottom-0 z-20 flex flex-wrap items-center gap-x-3 gap-y-2 rounded-b-card border-t border-subtle bg-white px-5 py-3 shadow-[0_-8px_24px_#0a13300d] sm:px-6"
                        >
                          <p
                            id="route-details-save-bar-text"
                            class="min-w-0 basis-full text-[13px] text-default sm:basis-0 sm:flex-1"
                          >
                            <span class="font-[650] text-strong">Unsaved:</span>
                            {changed_fields_summary(@changed_fields)}.
                            <span class="text-muted">Press Ctrl+S or ⌘S to save.</span>
                          </p>
                          <div class="flex shrink-0 items-center gap-3 max-sm:ml-auto">
                            <.button
                              id="route-details-discard"
                              type="button"
                              variant="secondary"
                              class="min-h-11"
                              phx-click="discard_route_details"
                            >
                              Discard changes
                            </.button>
                            <.button
                              type="submit"
                              id="route-save"
                              class="min-h-11"
                              disabled={@details_blocked?}
                              phx-disable-with="Saving…"
                            >
                              Save changes
                            </.button>
                          </div>
                        </div>
                      </.form>

                      <%!-- The design system's lifecycle card, last in reading order:
                           row one is the saved eligibility with its one next
                           action, row two the reviewed deletion. Deactivate
                           confirms first and names the consequence; Reactivate
                           and Undo act at once because they are the safe
                           direction. --%>
                      <section
                        id="route-status-section"
                        aria-labelledby="route-status-title"
                        class="mt-6"
                      >
                        <h2 id="route-status-title" class="text-base font-bold text-strong">
                          Status and removal
                        </h2>
                        <%!-- The outcome a status action can have: a deactivation
                             with its real Undo action, a reactivation, or a
                             truthful refusal. Focus lands here so the result is
                             announced (AC-28). --%>
                        <.message
                          :if={@status_outcome}
                          id="route-status-outcome"
                          tabindex="-1"
                          kind={Map.get(@status_outcome, :kind, "success")}
                          title={@status_outcome.message}
                          class="mt-3 outline-none"
                        >
                          <:action :if={@status_outcome.undo?}>
                            <.button
                              id="route-status-undo"
                              type="button"
                              variant="secondary"
                              class="min-h-11"
                              phx-click="reactivate_route"
                            >
                              Undo
                            </.button>
                          </:action>
                        </.message>
                        <div class="mt-3 divide-y divide-subtle rounded-card border border-subtle bg-white">
                          <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3 px-5 py-4">
                            <div class="min-w-0 flex-1 basis-[260px]">
                              <p class="flex items-center gap-2 text-sm font-[650] text-strong">
                                <%= if @active_state == :inactive do %>
                                  <.icon name="hero-eye-slash" class="size-4 shrink-0 text-muted" />Inactive
                                <% else %>
                                  <span
                                    aria-hidden="true"
                                    class="size-2.5 shrink-0 rounded-full bg-success-line"
                                  >
                                  </span>
                                  Active
                                <% end %>
                              </p>
                              <p class="mt-1 text-[13px] text-muted">
                                {route_status_help(@active_state)}
                              </p>
                            </div>
                            <.button
                              :if={@active_state != :inactive}
                              id="route-deactivate"
                              type="button"
                              variant="secondary"
                              class="min-h-11"
                              phx-click="open_deactivate_route"
                              disabled={@details_blocked?}
                            >
                              Deactivate route
                            </.button>
                            <.button
                              :if={@active_state == :inactive}
                              id="route-reactivate-details"
                              type="button"
                              variant="secondary"
                              class="min-h-11"
                              phx-click="reactivate_route"
                              disabled={@details_blocked?}
                            >
                              Reactivate route
                            </.button>
                          </div>

                          <%!-- The reviewed deletion row: the button opens the
                               step-11 review first, so this help line counts what
                               the page already read and the review confirms the
                               exact impact. --%>
                          <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3 px-5 py-4">
                            <div class="min-w-0 flex-1 basis-[260px]">
                              <p class="text-sm font-[650] text-strong">Delete route</p>
                              <p class="mt-1 text-[13px] text-muted">
                                {delete_row_help(assigns)}
                              </p>
                            </div>
                            <.button
                              id="route-delete"
                              type="button"
                              variant="secondary"
                              class="btn-outline-danger min-h-11"
                              phx-click="open_delete_route"
                              disabled={@details_blocked?}
                            >
                              <.icon name="hero-trash" class="size-4" />Delete route
                            </.button>
                          </div>
                        </div>
                      </section>

                      <%!-- The deactivate confirmation the review opens: what the
                           next export leaves out, and the honest note that
                           exports already run still include the route. Keep
                           active is the safe default focus. --%>
                      <.confirm_dialog
                        id="route-status-confirm"
                        chrome="planner"
                        open={@status_dialog != nil}
                        title={if @status_dialog, do: "Deactivate #{@status_dialog.ref}?", else: ""}
                        cancel_label="Keep active"
                        cancel_id="route-status-keep"
                        on_cancel="cancel_deactivate_route"
                        confirm_label="Deactivate route"
                        confirm_id="route-status-confirm-go"
                        pending_label="Deactivating…"
                        on_confirm="confirm_deactivate_route"
                        described_by="route-status-confirm-body"
                      >
                        <div :if={@status_dialog} class="grid gap-2">
                          <p>{deactivate_consequence(@status_dialog)}</p>
                          <p>
                            Patterns and schedules stay in this version and you can keep editing
                            them. Exports you already ran keep the route. Reactivate it at any time
                            to include it again.
                          </p>
                        </div>
                      </.confirm_dialog>

                      <%!-- The reviewed-deletion dialog the delete row opens: the
                           step-11 impact, what stays and Deactivate instead for
                           an active route, and a fresh acknowledgement that every
                           stale apply re-clears. The empty entire plan gets the
                           simple confirmation (R5). Keep route is the safe
                           default focus; Delete route stays unavailable until the
                           acknowledgement is checked. --%>
                      <.confirm_dialog
                        id="route-delete-review"
                        chrome="planner"
                        size="xl"
                        open={@delete_review != nil}
                        title={if @delete_review, do: delete_dialog_title(@route), else: ""}
                        cancel_label="Keep route"
                        cancel_id="route-delete-keep"
                        on_cancel="cancel_delete_route"
                        confirm_label="Delete route"
                        confirm_id="route-delete-go"
                        pending_label="Deleting…"
                        on_confirm="confirm_delete_route_simple"
                        confirm_form={
                          if @delete_review && not @delete_review.empty?, do: "route-delete-form"
                        }
                        confirm_disabled={
                          @delete_review != nil and not @delete_review.empty? and
                            not @delete_acknowledged?
                        }
                        pending={@delete_pending}
                        return_focus_id="route-delete"
                        described_by={delete_dialog_describedby(@delete_review)}
                      >
                        <RouteFormComponents.delete_review_panel
                          :if={@delete_review && not @delete_review.empty?}
                          rows={delete_impact_rows(assigns)}
                          stays={delete_stays_sentence(@delete_review)}
                          retained_lines={delete_retained_lines(@delete_review)}
                          blocks_note={delete_blocks_note(@delete_review)}
                          banner={delete_banner(@delete_changes)}
                          ack_label={delete_ack_label(@delete_review, @route)}
                          ack_error={@delete_ack_error}
                          acknowledged={@delete_acknowledged?}
                          error={@delete_error}
                          pending={@delete_pending}
                          deactivate_instead?={@active_state != :inactive}
                        />

                        <RouteFormComponents.delete_simple_panel
                          :if={@delete_review && @delete_review.empty?}
                          label={route_label(@route)}
                          error={@delete_error}
                        />
                      </.confirm_dialog>

                      <%!-- The leave dialog the client guard opens: tabs, internal
                           links, browser back and version selection hold here
                           while a draft is dirty. Keep editing restores the page
                           untouched, Discard leaves writing nothing, and Save and
                           continue commits the server-held draft and only then
                           navigates (AC-22). --%>
                      <.confirm_dialog
                        id="route-details-leave"
                        chrome="planner"
                        size="lg"
                        open={@pending_navigation != nil}
                        title="Leave without saving?"
                        cancel_label="Keep editing"
                        cancel_id="route-details-leave-cancel"
                        on_cancel="leave_keep_editing"
                        confirm_label="Save and continue"
                        confirm_id="route-details-leave-save"
                        pending_label="Saving…"
                        on_confirm="leave_save_route"
                        confirm_variant="primary"
                        described_by="route-details-leave-body"
                      >
                        {leave_message(@merge, @route, @changed_fields)}
                        <:extra_action>
                          <.button
                            id="route-details-leave-discard"
                            type="button"
                            variant="secondary"
                            class="min-h-11"
                            phx-click="leave_discard"
                          >
                            Discard changes
                          </.button>
                        </:extra_action>
                      </.confirm_dialog>
                    </div>

                    <%!-- The saved route map (step 30): the step-17 projection drawn
                       by the RouteDetailsMap hook beside the pattern list that
                       is the map's text equivalent. The panel renders the
                       truth the map read returned: real geometry, the empty
                       state, or an honest failure. --%>
                    <aside
                      id="route-details-map-region"
                      class="min-w-0 lg:sticky lg:top-4 lg:self-start"
                    >
                      <.route_map_panel
                        route_map_data={@route_map_data}
                        route={@route}
                        draft_route={@draft_route}
                        usage={@usage}
                        transfer_count={@transfer_count}
                        gtfs_version_id={@current_gtfs_version.id}
                        show_context={@show_context}
                        route_context={@route_context}
                        route_context_status={@route_context_status}
                      />
                    </aside>
                  </div>
                <% true -> %>
                  <div></div>
              <% end %>
            </div>
          <% _ -> %>
            <p
              id="route-loading"
              role="status"
              class="inline-flex min-h-11 items-center text-sm text-muted"
            >
              Loading route…
            </p>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # -- Saved route map (spec 16, step 30) --------------------------------------

  # The panel around the ignored `#route-map` container. Everything the map
  # draws comes from the step-17 projection carried in `@route_map_data`; the
  # panel itself renders the pattern list that is the map's text equivalent,
  # the legend, the controls and the honest degraded states (R7, AC-25/26).
  attr :route_map_data, :any, required: true
  attr :route, :any, required: true
  attr :draft_route, :any, required: true
  attr :usage, :any, required: true
  attr :transfer_count, :any, required: true
  attr :gtfs_version_id, :string, required: true
  attr :show_context, :boolean, required: true
  attr :route_context, :any, required: true
  attr :route_context_status, :any, required: true

  def route_map_panel(assigns) do
    ~H"""
    <section
      aria-labelledby="route-map-title"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-center justify-between gap-x-4 px-4 py-1.5">
        <h2 id="route-map-title" class="text-base font-bold tracking-normal text-strong">
          Where it runs
        </h2>
        <label
          :if={route_map_context_available?(@route_map_data)}
          for="route-map-context-toggle"
          class="inline-flex min-h-11 cursor-pointer items-center gap-2 text-[13px] font-[650] text-default"
        >
          <input
            type="checkbox"
            id="route-map-context-toggle"
            class="size-4 accent-action"
            checked={@show_context}
          /> Show other routes
        </label>
      </div>

      <%= case @route_map_data do %>
        <% {:ok, map} -> %>
          <%= if route_map_has_geometry?(map) do %>
            <div
              id="route-map-frame"
              class="relative h-[clamp(300px,44vh,440px)] overflow-hidden border-y border-subtle bg-map-paper"
            >
              <div
                id="route-map"
                phx-hook="RouteDetailsMap"
                phx-update="ignore"
                data-map-payload={route_map_payload_json(map)}
                data-map-context={route_map_context_json(@route_context)}
                data-map-colors={route_map_colors_json(@draft_route)}
                class="absolute inset-0 z-0 bg-map-paper"
              >
              </div>
              <p id="route-map-alt" class="sr-only">{route_map_alt_text(map, @route)}</p>
              <%!-- 44px zoom/fit controls: the map itself is not a tab stop, so
                     these and the pattern list are the keyboard equivalents. --%>
              <div class="absolute right-3 top-3 z-10 grid overflow-hidden rounded-control border border-subtle bg-white shadow-float">
                <button
                  type="button"
                  id="route-map-zoom-in"
                  aria-label="Zoom in"
                  title="Zoom in"
                  class="inline-flex size-11 items-center justify-center text-strong hover:bg-canvas"
                >
                  <.icon name="hero-plus" class="size-5" />
                </button>
                <button
                  type="button"
                  id="route-map-zoom-out"
                  aria-label="Zoom out"
                  title="Zoom out"
                  class="inline-flex size-11 items-center justify-center border-t border-subtle text-strong hover:bg-canvas"
                >
                  <.icon name="hero-minus" class="size-5" />
                </button>
                <button
                  type="button"
                  id="route-map-fit"
                  aria-label="Fit route"
                  title="Fit route"
                  class="inline-flex size-11 items-center justify-center border-t border-subtle text-strong hover:bg-canvas"
                >
                  <.icon name="hero-arrows-pointing-out" class="size-5" />
                </button>
              </div>

              <%!-- The highlighted pattern's card; the hook fills and shows it. --%>
              <div
                id="route-map-card"
                hidden
                class="absolute left-3 top-3 z-10 max-w-[300px] rounded-control border border-subtle bg-white px-3 py-2 text-[13px] shadow-float"
              >
              </div>

              <%!-- Cooperative wheel zoom: plain wheel scrolls the page behind this
                     hint; Ctrl/Cmd + wheel zooms the map. --%>
              <p
                id="route-map-hint"
                hidden
                class="pointer-events-none absolute inset-0 z-10 flex items-center justify-center bg-navy-800/45 text-sm font-[650] text-white"
              >
                Hold Ctrl or ⌘ and scroll to zoom the map
              </p>

              <%!-- Tile failure: the vectors and this list stay; the hook shows and
                     clears this banner around its own tile retry. --%>
              <div
                id="route-map-tiles-unavailable"
                hidden
                role="status"
                class="absolute inset-x-3 bottom-10 z-10 flex flex-wrap items-center gap-x-3 gap-y-1 rounded-control border border-warning-line bg-warning-bg px-3 py-2 text-[13px] text-warning-fg shadow-float"
              >
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
                <span class="min-w-0 flex-1">
                  Street map unavailable. Route lines and stops are drawn on a plain
                  background.
                </span>
                <button
                  type="button"
                  id="route-map-tiles-retry"
                  class="inline-flex min-h-11 items-center font-[650] underline"
                >
                  Retry map
                </button>
              </div>

              <p class="pointer-events-none absolute bottom-1.5 right-3 z-10 rounded-badge bg-white/85 px-1.5 text-[11px] text-map-label">
                © OpenStreetMap contributors · Geoapify
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-x-5 gap-y-1 border-b border-subtle px-4 py-2 text-[13px] text-default">
              <span class="inline-flex items-center gap-2">
                <svg width="26" height="8" aria-hidden="true">
                  <line
                    class="route-map-swatch"
                    x1="1"
                    y1="4"
                    x2="25"
                    y2="4"
                    stroke={route_map_swatch_stroke(@draft_route)}
                    stroke-width="3.5"
                    stroke-linecap="round"
                  />
                </svg>
                Path saved
              </span>
              <span class="inline-flex items-center gap-2">
                <svg width="26" height="8" aria-hidden="true">
                  <line
                    class="route-map-swatch"
                    x1="1"
                    y1="4"
                    x2="25"
                    y2="4"
                    stroke={route_map_swatch_stroke(@draft_route)}
                    stroke-width="3.5"
                    stroke-dasharray="4 4"
                  />
                </svg>
                Straight between stops, no path yet
              </span>
            </div>

            <%!-- Other-route context (AC-27): off by default; when on, the
                   strip announces the result and stays honest about a page
                   that is not the whole viewport yet. --%>
            <div
              :if={@show_context}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-subtle px-4 py-2 text-[13px] text-default"
            >
              <%= case @route_context_status do %>
                <% :ok -> %>
                  <p id="route-map-context-status" role="status" class="min-w-0 flex-1">
                    {route_map_context_status_text(@route_context)}
                  </p>
                  <button
                    :if={@route_context.partial}
                    type="button"
                    id="route-map-context-more"
                    phx-click="more_route_context"
                    class="inline-flex min-h-11 items-center font-[650] underline"
                  >
                    Show more routes
                  </button>
                <% :error -> %>
                  <p
                    id="route-map-context-status"
                    role="status"
                    class="min-w-0 flex-1 text-warning-fg"
                  >
                    Couldn't load nearby routes. This route and its editor are
                    unaffected.
                  </p>
                  <button
                    type="button"
                    id="route-map-context-retry"
                    phx-click="retry_route_context"
                    class="inline-flex min-h-11 items-center font-[650] underline"
                  >
                    Retry
                  </button>
              <% end %>
            </div>

            <div class="flex items-baseline justify-between gap-3 px-4 pb-1 pt-3">
              <h3 class="text-[13px] font-[650] text-default">Patterns</h3>
              <p :if={route_map_trips(@usage)} class="text-[13px] tabular-nums text-muted">
                {route_map_trips(@usage)} {if route_map_trips(@usage) == 1,
                  do: "trip",
                  else: "trips"}
              </p>
            </div>
            <ul id="route-map-pattern-list" class="pb-1">
              <li :for={pattern <- map.patterns}>
                <% metrics = route_map_pattern_metrics(pattern) %>
                <.link
                  navigate={
                    ~p"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}/patterns/#{pattern.route_pattern_id}"
                  }
                  data-map-highlight={pattern.route_pattern_id}
                  data-map-kind="pattern"
                  data-on="false"
                  class="group flex min-h-[52px] items-center gap-3 px-4 py-1.5 text-default no-underline hover:bg-canvas focus-visible:bg-canvas data-[on=true]:bg-selection"
                >
                  <svg width="28" height="10" class="shrink-0" aria-hidden="true">
                    <line
                      class="route-map-swatch"
                      x1="2"
                      y1="5"
                      x2="26"
                      y2="5"
                      stroke={route_map_swatch_stroke(@draft_route)}
                      stroke-width="4"
                      stroke-linecap={if metrics.dashed > 0, do: "butt", else: "round"}
                      stroke-dasharray={if metrics.dashed > 0, do: "5 4", else: nil}
                    />
                  </svg>
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-sm font-[650] text-strong group-hover:underline">
                      {pattern.route_pattern_name || pattern.route_pattern_id}
                    </span>
                    <span class="block text-[13px] text-muted">
                      {RoutePattern.direction_label(pattern.direction_id)} · {metrics.stops}
                      {if metrics.stops == 1, do: "stop", else: "stops"}{route_map_gap_text(metrics)}
                    </span>
                  </span>
                </.link>
              </li>
            </ul>
            <div :if={map.imported_shape_variants != []} class="border-t border-subtle px-4 pb-1 pt-3">
              <h3 class="text-[13px] font-[650] text-default">Imported shapes</h3>
            </div>
            <ul id="route-map-variant-list" class="pb-1">
              <li :for={variant <- map.imported_shape_variants}>
                <% vmetrics = route_map_variant_metrics(variant) %>
                <button
                  type="button"
                  data-map-highlight={variant.shape_id}
                  data-map-kind="variant"
                  data-on="false"
                  title="Highlight this shape on the map"
                  class="flex min-h-[52px] w-full items-center gap-3 px-4 py-1.5 text-left text-default hover:bg-canvas focus-visible:bg-canvas data-[on=true]:bg-selection"
                >
                  <svg width="28" height="10" class="shrink-0" aria-hidden="true">
                    <line
                      class="route-map-swatch"
                      x1="2"
                      y1="5"
                      x2="26"
                      y2="5"
                      stroke={route_map_swatch_stroke(@draft_route)}
                      stroke-width="4"
                      stroke-linecap="round"
                      stroke-dasharray={if vmetrics.saved, do: nil, else: "5 4"}
                    />
                  </svg>
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-sm font-[650] text-strong">{variant.label}</span>
                    <span class="block text-[13px] text-muted">
                      {length(variant.route_pattern_ids)}
                      {if length(variant.route_pattern_ids) == 1, do: "pattern", else: "patterns"} ·
                      shape {variant.shape_id}{route_map_variant_gap_text(vmetrics)}
                    </span>
                  </span>
                </button>
              </li>
            </ul>
          <% else %>
            <div class="border-y border-subtle bg-map-paper">
              <div class="flex items-center justify-center p-6">
                <div class="max-w-[340px] rounded-card border border-subtle bg-white p-5 text-center shadow-float">
                  <h3 class="text-base font-bold tracking-normal text-strong">No patterns yet</h3>
                  <p class="mt-1.5 text-sm text-default">
                    A pattern is the list of stops a trip serves, in order. The map draws the
                    route once it has one.
                  </p>
                  <.link
                    id="route-map-first-pattern"
                    navigate={~p"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}/patterns"}
                    class="mt-4 inline-flex min-h-11 items-center justify-center gap-2 rounded-control bg-action px-4 text-sm font-[650] text-white hover:bg-action-hover"
                  >
                    <.icon name="hero-plus" class="size-4" />Create pattern
                  </.link>
                </div>
              </div>
            </div>
          <% end %>
        <% _ -> %>
          <div class="border-y border-subtle bg-map-paper px-4 py-6">
            <div
              id="route-map-unavailable"
              role="status"
              class="mx-auto max-w-[340px] rounded-card border border-warning-line bg-warning-bg p-5 text-center text-warning-fg"
            >
              <p class="text-sm font-[650]">Map geometry unavailable</p>
              <p class="mt-1.5 text-sm">
                We couldn't load what to draw. Nothing is invented in its place, and the editor
                is unaffected.
              </p>
              <button
                id="route-map-retry"
                type="button"
                phx-click="retry"
                class="mt-4 inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control-border bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
              >
                Reload map
              </button>
            </div>
          </div>
      <% end %>

      <div class="flex flex-wrap gap-x-6 gap-y-0 border-t border-subtle px-4 py-1">
        <p class="text-[13px] text-muted">
          <.link
            id="route-transfers-link"
            navigate={~p"/gtfs/#{@gtfs_version_id}/transfers?#{[route: @route.route_id]}"}
            class="font-[650] text-action underline underline-offset-2 hover:no-underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            Transfers here ({@transfer_count})
          </.link>
        </p>
      </div>
    </section>
    """
  end

  defp route_map_has_geometry?(map),
    do: map.patterns != [] or map.imported_shape_variants != []

  # "Show other routes" exists only where a current-route map exists to add
  # context to — the prototype shows the checkbox only with patterns.
  defp route_map_context_available?({:ok, map}), do: route_map_has_geometry?(map)
  defp route_map_context_available?(_route_map_data), do: false

  defp route_map_context_status_text(%{routes: [], partial: _}),
    do: "No other routes in this view have maps."

  defp route_map_context_status_text(%{routes: routes, partial: true}),
    do: "Showing the first #{length(routes)} nearby routes. More are in this view."

  defp route_map_context_status_text(%{routes: routes}),
    do: "Showing all #{length(routes)} nearby routes in this view."

  # The context payload as JSON for the hook. Absent (nil) when context is
  # off, so the attribute disappears and the hook clears its layer.
  defp route_map_context_json(nil), do: nil

  defp route_map_context_json(%{routes: routes}) do
    Jason.encode!(%{
      routes:
        Enum.map(routes, fn route ->
          %{
            route_id: route.route_id,
            route_short_name: route.route_short_name,
            route_long_name: route.route_long_name,
            route_color: route.route_color,
            route_text_color: route.route_text_color,
            active: route.active,
            sections: Enum.map(route.sections, &route_map_geometry_json/1),
            imported_shape_variants:
              Enum.map(route.imported_shape_variants, &route_map_geometry_json/1)
          }
        end)
    })
  end

  defp route_map_trips(usage) when is_map(usage), do: Map.get(usage, :trips)
  defp route_map_trips(_usage), do: nil

  # The map payload as JSON. The projection's coordinates already are JSON
  # numbers in `[lon, lat]` order and pass through untouched; the status,
  # source and unlocated-reason atoms become the strings the hook keys on.
  # Nothing else is added: the hook draws what the read returned or nothing.
  defp route_map_payload_json(map) do
    %{
      route_uuid: map.route_uuid,
      route_id: map.route_id,
      status: Atom.to_string(map.status),
      saved_alignment: Atom.to_string(map.saved_alignment),
      patterns:
        Enum.map(map.patterns, fn pattern ->
          %{
            route_pattern_id: pattern.route_pattern_id,
            direction_id: pattern.direction_id,
            route_pattern_name: pattern.route_pattern_name,
            visits: Enum.map(pattern.visits, &route_map_geometry_json/1),
            sections: Enum.map(pattern.sections, &route_map_geometry_json/1)
          }
        end),
      imported_shape_variants:
        Enum.map(map.imported_shape_variants, fn variant ->
          variant
          |> route_map_geometry_json()
          |> Map.merge(%{
            shape_id: variant.shape_id,
            variant: variant.variant,
            label: variant.label,
            route_pattern_ids: variant.route_pattern_ids
          })
        end)
    }
    |> Jason.encode!()
  end

  defp route_map_geometry_json(entry) do
    scalars =
      entry
      |> Map.take([:source, :status, :position, :stop_id, :from_position, :to_position])
      |> Enum.into(%{}, fn
        {key, value} when is_atom(value) and not is_nil(value) -> {key, Atom.to_string(value)}
        {key, value} -> {key, value}
      end)

    scalars =
      case Map.fetch(entry, :coordinates) do
        {:ok, coordinates} -> Map.put(scalars, :coordinates, coordinates)
        :error -> scalars
      end

    reasons =
      entry
      |> Map.get(:unlocated, [])
      |> Enum.map(fn unlocated ->
        %{ref: unlocated.ref, reason: Atom.to_string(unlocated.reason)}
      end)

    Map.put(scalars, :unlocated, reasons)
  end

  defp route_map_colors_json(route) do
    Jason.encode!(%{
      route_color: route.route_color || "",
      route_text_color: route.route_text_color || ""
    })
  end

  defp route_map_alt_text(map, route) do
    case map.patterns do
      [] ->
        "Route #{route.route_id} has no patterns to map yet."

      patterns ->
        first = List.first(patterns)
        from = (List.first(first.visits) || %{})[:stop_id] || "its first stop"
        to = (List.last(first.visits) || %{})[:stop_id] || "its last stop"

        count = length(patterns)

        "Map of #{route_display_name(route)} (#{route.route_id}): #{count} " <>
          if(count == 1, do: "pattern", else: "patterns") <>
          " from #{from} to #{to}. The pattern list below the map has the same information."
    end
  end

  defp route_map_swatch_stroke(draft_route) do
    hex =
      case RouteIdentity.normalize_hex(draft_route && draft_route.route_color) do
        {:ok, hex} -> hex
        :error -> "FFFFFF"
      end

    if hex == "FFFFFF", do: "#7A8698", else: "##{hex}"
  end

  # The row metrics mirror the hook's draw rule exactly: a missing section is
  # "without a path yet" (drawn dashed) only when both endpoint visits have
  # coordinates; anything else is not shown, with its unlocated reason named
  # instead of invented geometry (INV-5).
  defp route_map_pattern_metrics(pattern) do
    located =
      for visit <- pattern.visits, Map.has_key?(visit, :coordinates), into: MapSet.new() do
        visit.position
      end

    problem_sections =
      Enum.filter(pattern.sections, &(&1.status in [:missing, :unavailable]))

    {dashed, hidden} =
      Enum.split_with(problem_sections, fn section ->
        section.status == :missing and
          MapSet.member?(located, section.from_position) and
          MapSet.member?(located, section.to_position)
      end)

    reasons =
      hidden
      |> Enum.flat_map(&route_map_unlocated_reasons/1)
      |> Enum.uniq()
      |> Enum.map(&route_map_unlocated_phrase/1)

    %{
      stops: length(pattern.visits),
      dashed: length(dashed),
      hidden: length(hidden),
      reasons: reasons
    }
  end

  defp route_map_variant_metrics(variant) do
    reasons =
      variant
      |> route_map_unlocated_reasons()
      |> Enum.uniq()
      |> Enum.map(&route_map_unlocated_phrase/1)

    %{saved: variant.status == :saved, reasons: reasons}
  end

  defp route_map_unlocated_reasons(entry),
    do: Enum.map(Map.get(entry, :unlocated, []), & &1.reason)

  defp route_map_unlocated_phrase(:coordinates_absent), do: "a stop has no coordinates"
  defp route_map_unlocated_phrase(:stop_not_found), do: "a referenced stop is missing"
  defp route_map_unlocated_phrase(:shape_points_absent), do: "the shape has no points"
  defp route_map_unlocated_phrase(_other), do: "the path is unknown"

  defp route_map_gap_text(%{dashed: 0, hidden: 0}), do: ""

  defp route_map_gap_text(%{dashed: dashed, hidden: hidden, reasons: reasons}) do
    parts =
      Enum.concat([
        if(dashed > 0,
          do: ["#{count_phrase(dashed, "section")} without a path yet"],
          else: []
        ),
        if(hidden > 0,
          do: [
            "#{count_phrase(hidden, "section")} not shown: #{Enum.join(reasons, ", ")}"
          ],
          else: []
        )
      ])

    " · " <> Enum.join(parts, " · ")
  end

  defp route_map_variant_gap_text(%{saved: true}), do: ""
  defp route_map_variant_gap_text(%{reasons: []}), do: " · not shown"

  defp route_map_variant_gap_text(%{reasons: reasons}),
    do: " · not shown: #{Enum.join(reasons, ", ")}"
end
