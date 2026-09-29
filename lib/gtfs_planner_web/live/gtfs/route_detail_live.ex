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
  alias Ecto.Changeset
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Gtfs.RouteFormComponents
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
     |> assign(:usage, nil)}
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

      {:ok, workspace} ->
        geometry_status =
          organization_id
          |> Gtfs.route_map(gtfs_version_id, workspace.route.route_id)
          |> geometry_status()

        socket
        |> assign(:route, workspace.route)
        |> assign(:source, workspace.source)
        |> assign(:agencies, workspace.agencies)
        |> assign(:mode_counts, workspace.mode_counts)
        |> assign(:warning_candidates, workspace.warning_candidates)
        |> assign(:geometry_status, geometry_status)
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
            geometry_status
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
    pending = if params["leave_nav"] == "true", do: socket.assigns.pending_navigation, else: nil
    socket = clear_pending(socket)

    choices =
      if merge_submission?(params) and socket.assigns.merge != nil,
        do: merge_choices(socket, params),
        else: %{}

    case Gtfs.update_route(
           socket.assigns.route.route_id,
           attrs,
           socket.assigns.source,
           choices,
           audit_context(socket)
         ) do
      {:ok, %{route: _saved}} when is_binary(pending) ->
        {:noreply, guarded_navigate(socket, pending)}

      # The save that unblocked the status review continues into it (R4).
      {:ok, %{route: saved}} when pending == :status_review ->
        {:noreply, saved_details(socket, saved) |> open_status_review()}

      {:ok, %{route: saved}} ->
        {:noreply, saved_details(socket, saved)}

      {:error, {:conflict, payload}} ->
        {:noreply, present_conflict(socket, payload)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, save_rejected(socket, changeset)}

      {:error, :not_found} ->
        {:noreply,
         route_gone(
           socket,
           "This route is no longer in this version. Open it again from the route list."
         )}

      # The same natural ID exists again, but it is a different route with a
      # different UUID: the old draft never authorizes it (AC-9).
      {:error, :stale} ->
        {:noreply,
         route_gone(
           socket,
           "This route was deleted and created again with the same route ID. Open the new route from the route list."
         )}

      {:error, :forbidden} ->
        {:noreply,
         save_not_saved(
           socket,
           "Not saved: your editor access was removed. Your changes are still on this page, but you can't save them. Ask an admin to restore editor access."
         )}

      {:error, :busy} ->
        {:noreply,
         save_not_saved(
           socket,
           "Not saved: the server is busy right now. Your changes are still here — try Save again."
         )}

      # The mutation and its audit commit together, so nothing was changed.
      {:error, :failed_audit} ->
        {:noreply,
         save_not_saved(
           socket,
           "Not saved: your changes could not be recorded. Nothing was changed — try Save again."
         )}

      {:error, _other} ->
        {:noreply,
         save_not_saved(
           socket,
           "Not saved: something went wrong. Your changes are still here — try Save again."
         )}
    end
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
    |> push_event("focus_scoped_target", %{id: "route-details-heading"})
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
    |> assign(:save_outcome, {:error, "Not saved. " <> save_error_summary(changeset)})
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
            undo?: false
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
    |> assign(:status_outcome, %{message: message, undo?: false})
    |> focus_status_outcome()
  end

  defp focus_status_outcome(socket) do
    push_event(socket, "focus_scoped_target", %{id: "route-status-outcome"})
  end

  # The status review payload: the counts the confirmation's export copy names.
  # Patterns come from the already-read map projection, transfers from the
  # page's own count, trips and fare rules from the workspace read (the R6
  # closure a future export leaves out). A count that was not read keeps its
  # sentence truthful without a number.
  defp open_status_review(socket) do
    route = socket.assigns.route
    usage = socket.assigns.usage || %{}

    patterns =
      case socket.assigns.geometry_status do
        %{patterns: count} when is_integer(count) -> count
        _other -> nil
      end

    assign(socket, :status_dialog, %{
      ref: deactivate_ref(route),
      name: route_display_name(route),
      patterns: patterns,
      trips: Map.get(usage, :trips),
      transfers: socket.assigns.transfer_count,
      fare_rules: Map.get(usage, :fare_rules)
    })
  end

  defp deactivate_ref(route) do
    if route.route_short_name in [nil, ""], do: route.route_id, else: route.route_short_name
  end

  # The confirmation's own copy pieces. A count that was not read keeps its
  # sentence truthful without a number instead of guessing one.
  defp patterns_phrase(nil), do: "its patterns"
  defp patterns_phrase(1), do: "its 1 pattern"
  defp patterns_phrase(count) when is_integer(count), do: "its #{count} patterns"

  defp trips_item(0), do: "the route itself"

  defp trips_item(1), do: "the route and its 1 trip with its stop times"

  defp trips_item(count) when is_integer(count),
    do: "the route and its #{count} trips with their stop times"

  defp count_phrase(1, word), do: "1 #{word}"
  defp count_phrase(count, word) when is_integer(count), do: "#{count} #{word}s"

  defp positive?(count) when is_integer(count) and count > 0, do: true
  defp positive?(_other), do: false

  defp route_status_help(:inactive),
    do: "Reactivate to include the route and its trips in the next export."

  defp route_status_help(_active),
    do:
      "Deactivate a seasonal or suspended route to leave it out of exports. Its patterns and schedules stay here."

  defp save_error_summary(changeset) do
    errors =
      changeset.errors
      |> Enum.take(3)
      |> Enum.map(fn {field, {message, _opts}} ->
        "#{field_label(field)}: #{message}"
      end)

    if errors == [] do
      "Fix the highlighted fields below."
    else
      "Fix the highlighted fields below — " <> Enum.join(errors, "; ") <> "."
    end
  end

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
    Map.put(warning, :href, "/gtfs/#{version_id}/routes/#{route_id}/patterns")
  end

  defp changed_field_labels(fields) do
    for {field, label} <- @detail_field_labels, field in fields, do: label
  end

  # The dialog body names the draft the way the reference does — the route and
  # the fields that would be lost; an open merge names the collision instead.
  defp leave_message(_merge, route, fields) when fields != [] do
    "Your changes to Route #{route.route_id} aren't saved: " <>
      Enum.join(changed_field_labels(fields), ", ") <> "."
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
      <:sub_header :if={@route_state == :ready}>
        <.route_sub_nav
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@active_tab}
          inactive={@active_state == :inactive}
          trip_count={@usage && Map.get(@usage, :trips)}
        />
      </:sub_header>

      <%= case @route_state do %>
        <% :unavailable -> %>
          <div class="mt-8">
            <.callout kind="error" title="Route data unavailable" id="route-unavailable">
              We could not load this route. Please try again.
              <button
                id="route-retry"
                phx-click="retry"
                class="btn btn-sm btn-outline mt-2"
              >
                Retry
              </button>
            </.callout>
          </div>
        <% :ready -> %>
          <%= cond do %>
            <% @active_tab == :details -> %>
              <%!-- The reference's two-column Details composition: the form column,
                     and the sticky map column step 30 fills. The disclosure, the
                     field order and the header below are this step's; the map
                     region is reserved and empty on purpose. --%>
              <div
                id="route-details-workspace"
                phx-hook="FormErrorFocus"
                data-focus-on-mount={if @focus_heading?, do: "route-details-heading", else: nil}
                class="mt-7 grid gap-8 pb-10 lg:grid-cols-[minmax(0,560px)_minmax(0,1fr)] xl:gap-12"
              >
                <div class="min-w-0">
                  <%!-- Saved identity: the badge, name, mode and attribution the
                         route actually has now. While a draft differs, the badge,
                         name and mode preview the draft and the chip says so; the
                         attribution line stays saved truth (AC-19, INV-6). --%>
                  <div id="route-details-header" class="grid gap-2">
                    <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
                      <span id="route-details-badge">
                        <RouteIdentity.route_badge
                          route={@draft_route}
                          class="h-10 min-w-11 text-[20px] font-extrabold"
                        />
                      </span>
                      <h1
                        id="route-details-heading"
                        tabindex="-1"
                        class="min-w-0 text-[32px] font-semibold tracking-[-0.02em] text-strong outline-none"
                      >
                        {route_display_name(@draft_route)}
                      </h1>
                      <span
                        id="route-details-mode-label"
                        class="rounded-badge bg-canvas px-2 py-1 text-[13px] font-[650] leading-none text-default"
                      >
                        {Route.route_type_label(@draft_route.route_type)}
                      </span>
                      <span
                        :if={preview?(@changed_fields)}
                        id="route-details-unsaved-preview"
                        class="inline-flex items-center gap-1.5 rounded-badge bg-warning/10 px-2 py-1 text-[13px] font-[650] leading-none text-warning"
                      >
                        <.icon name="hero-pencil-square" class="size-3.5" />Unsaved preview
                      </span>
                    </div>
                    <p id="route-details-saved-identity" class="text-[13px] text-muted">
                      {saved_identity(@route, @agencies, @last_saved)}
                    </p>
                  </div>

                  <.form
                    :if={@route_form}
                    for={@route_form}
                    id="route-details-form"
                    novalidate
                    phx-change="validate_route_details"
                    phx-submit="save_route_details"
                    data-recovery="true"
                    data-recovery-event="recover_route_details"
                    class="mt-5 grid grid-cols-1 gap-8"
                  >
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
                      <p
                        :if={match?({:saved, _}, @save_outcome)}
                        id="route-details-saved"
                        role="status"
                        class="rounded-control border border-success bg-success/10 px-4 py-3 text-sm text-default"
                      >
                        {elem(@save_outcome, 1)}
                      </p>
                      <p
                        :if={match?({:error, _}, @save_outcome)}
                        id="route-details-save-error"
                        role="alert"
                        class="rounded-control border border-error-line bg-error-bg px-4 py-3 text-sm text-error-fg"
                      >
                        {elem(@save_outcome, 1)}
                      </p>
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

                    <%!-- The reference's sticky save bar: it appears only when a
                           draft differs from the saved row, names the fields a
                           save would change, and offers Discard and Save. Save is
                           an ordinary submit, so Ctrl/Cmd+S (wired in the route
                           details editor hook) submits the same way. --%>
                    <div
                      id="route-details-save-bar"
                      hidden={@changed_fields == []}
                      class="sticky bottom-0 z-20 flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-subtle bg-white px-4 py-3 shadow-[0_-8px_24px_#0a13300d]"
                    >
                      <p
                        id="route-details-save-bar-text"
                        class="min-w-0 flex-1 basis-[220px] text-[13px] text-default"
                      >
                        <span class="font-[650] text-strong">Unsaved:</span> {changed_fields_summary(
                          @changed_fields
                        )} <span class="text-muted">· Ctrl+S saves</span>
                      </p>
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
                        class="min-h-11 min-w-[140px]"
                        disabled={@details_blocked?}
                        phx-disable-with="Saving…"
                      >
                        Save changes
                      </.button>
                    </div>
                  </.form>

                  <%!-- The reference's Status and removal row: saved eligibility
                         with the deactivate confirmation and Reactivate. The
                         delete row is the reviewed-deletion step's surface and
                         stays out until then. --%>
                  <section
                    id="route-status-section"
                    aria-labelledby="route-status-title"
                    class="mt-10 border-t border-subtle pt-6"
                  >
                    <h2
                      id="route-status-title"
                      class="text-base font-bold tracking-normal text-strong"
                    >
                      Status and removal
                    </h2>
                    <%!-- The outcome a status action can have: a deactivation
                           with its real Undo action, a reactivation, or a
                           truthful refusal. Focus lands here so the result is
                           announced (AC-28). --%>
                    <div
                      :if={@status_outcome}
                      id="route-status-outcome"
                      tabindex="-1"
                      class="mt-3 grid gap-2 rounded-control border border-success bg-success/10 px-4 py-3 text-sm text-default outline-none"
                    >
                      <p role="status">{@status_outcome.message}</p>
                      <.button
                        :if={@status_outcome.undo?}
                        id="route-status-undo"
                        type="button"
                        variant="secondary"
                        class="min-h-11 self-start"
                        phx-click="reactivate_route"
                      >
                        <.icon name="hero-arrow-path" class="ml-1 size-4" />Undo
                      </.button>
                    </div>
                    <div class="mt-3 divide-y divide-subtle rounded-card border border-subtle">
                      <div class="flex flex-wrap items-center justify-between gap-4 p-4">
                        <div class="min-w-0 flex-1 basis-[260px]">
                          <p class="flex items-center gap-2 text-sm font-[650] text-strong">
                            <%= if @active_state == :inactive do %>
                              <.icon name="hero-eye-slash" class="size-4 shrink-0" />Inactive: left
                              out of exports
                            <% else %>
                              <span class="size-2.5 shrink-0 rounded-full bg-success"></span>
                              Active: included in exports
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
                          phx-click="open_deactivate_route"
                          disabled={@details_blocked?}
                        >
                          <.icon name="hero-eye-slash" class="ml-1 size-4" />Deactivate route
                        </.button>
                        <.button
                          :if={@active_state == :inactive}
                          id="route-reactivate-details"
                          type="button"
                          variant="secondary"
                          phx-click="reactivate_route"
                          disabled={@details_blocked?}
                        >
                          <.icon name="hero-arrow-path" class="ml-1 size-4" />Reactivate route
                        </.button>
                      </div>
                    </div>
                  </section>

                  <%!-- The deactivate confirmation the review opens: what stays,
                         what the next export leaves out, and the honest note
                         that exports already run still include the route. Keep
                         active is the safe default focus. --%>
                  <dialog
                    id="route-status-confirm"
                    phx-mounted={JS.ignore_attributes("open")}
                    phx-hook="OverlayDialog"
                    data-open={to_string(@status_dialog != nil)}
                    data-close-on-backdrop="false"
                    data-pending="false"
                    aria-labelledby="route-status-confirm-title"
                    aria-describedby="route-status-confirm-body"
                    role={if @status_dialog, do: "alertdialog", else: nil}
                    aria-modal={if @status_dialog, do: "true", else: nil}
                    inert={if @status_dialog, do: nil, else: ""}
                    aria-hidden={if @status_dialog, do: nil, else: "true"}
                    class="m-0 border-0 w-full h-full bg-transparent p-0"
                  >
                    <div class="w-full h-full flex items-center justify-center p-4">
                      <div
                        :if={@status_dialog}
                        class="w-full max-w-sm border border-base-300 bg-base-100 p-5"
                      >
                        <h3 id="route-status-confirm-title" class="font-semibold">
                          Deactivate {@status_dialog.ref}?
                        </h3>
                        <div
                          id="route-status-confirm-body"
                          class="mt-1 text-sm text-base-content/70"
                        >
                          <p>
                            {@status_dialog.ref} {@status_dialog.name} stays in this version, and
                            you can keep editing {patterns_phrase(@status_dialog.patterns)} and
                            schedules. The next export leaves out:
                          </p>
                          <ul class="mt-2 grid list-disc gap-1 pl-5">
                            <li>{trips_item(@status_dialog.trips)}</li>
                            <li :if={positive?(@status_dialog.transfers)}>
                              {count_phrase(@status_dialog.transfers, "transfer")} that name the
                              route or its trips
                            </li>
                            <li :if={positive?(@status_dialog.fare_rules)}>
                              {count_phrase(@status_dialog.fare_rules, "fare rule")} for the route
                            </li>
                          </ul>
                          <p class="mt-3 text-muted">
                            Exports you already ran still include it. Reactivate the route at any
                            time to include it again.
                          </p>
                        </div>
                        <div class="mt-4 flex flex-wrap items-center justify-end gap-2">
                          <button
                            id="route-status-keep"
                            type="button"
                            data-dialog-dismiss
                            class="h-[44px] min-w-[44px] border border-control-border px-4 text-sm font-semibold"
                            phx-click="cancel_deactivate_route"
                          >
                            Keep active
                          </button>
                          <button
                            id="route-status-confirm-go"
                            type="button"
                            class="h-[44px] min-w-[44px] bg-primary px-4 text-sm font-semibold text-primary-content"
                            phx-click="confirm_deactivate_route"
                            phx-disable-with="Deactivating…"
                          >
                            Deactivate route
                          </button>
                        </div>
                      </div>
                    </div>
                  </dialog>

                  <%!-- The leave dialog the client guard opens: tabs, internal
                         links, browser back and version selection hold here
                         while a draft is dirty. Keep editing restores the page
                         untouched, Discard leaves writing nothing, and Save and
                         continue commits the server-held draft and only then
                         navigates (AC-22). --%>
                  <dialog
                    id="route-details-leave"
                    phx-mounted={JS.ignore_attributes("open")}
                    phx-hook="OverlayDialog"
                    data-open={to_string(@pending_navigation != nil)}
                    data-close-on-backdrop="false"
                    data-pending="false"
                    aria-labelledby="route-details-leave-title"
                    aria-describedby="route-details-leave-body"
                    role={if @pending_navigation, do: "alertdialog", else: nil}
                    aria-modal={if @pending_navigation, do: "true", else: nil}
                    inert={if @pending_navigation, do: nil, else: ""}
                    aria-hidden={if @pending_navigation, do: nil, else: "true"}
                    class="m-0 border-0 w-full h-full bg-transparent p-0"
                  >
                    <div class="w-full h-full flex items-center justify-center p-4">
                      <div class="w-full max-w-sm border border-base-300 bg-base-100 p-5">
                        <h3 id="route-details-leave-title" class="font-semibold">
                          Leave without saving?
                        </h3>
                        <div id="route-details-leave-body" class="mt-1 text-sm text-base-content/70">
                          {leave_message(@merge, @route, @changed_fields)}
                        </div>
                        <div class="mt-4 flex flex-wrap items-center justify-end gap-2">
                          <button
                            id="route-details-leave-discard"
                            type="button"
                            class="mr-auto h-[44px] min-w-[44px] border border-control-border px-4 text-sm font-semibold"
                            phx-click="leave_discard"
                          >
                            Discard changes
                          </button>
                          <button
                            id="route-details-leave-cancel"
                            type="button"
                            data-dialog-dismiss
                            class="h-[44px] min-w-[44px] border border-control-border px-4 text-sm font-semibold"
                            phx-click="leave_keep_editing"
                          >
                            Keep editing
                          </button>
                          <button
                            id="route-details-leave-save"
                            type="button"
                            class="h-[44px] min-w-[44px] bg-primary px-4 text-sm font-semibold text-primary-content"
                            phx-click="leave_save_route"
                            phx-disable-with="Saving…"
                          >
                            Save and continue
                          </button>
                        </div>
                      </div>
                    </div>
                  </dialog>

                  <div class="mt-8 border-t border-subtle pt-4">
                    <p class="text-[13px] text-muted">
                      <.link
                        id="route-transfers-link"
                        navigate={
                          ~p"/gtfs/#{@current_gtfs_version.id}/transfers?#{[route: @route.route_id]}"
                        }
                        class="font-[650] text-action underline underline-offset-2 hover:no-underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                      >
                        Transfers here ({@transfer_count})
                      </.link>
                    </p>
                  </div>
                </div>

                <%!-- Step 30 renders the saved route map and its pattern list in
                       this sticky column. It is reserved here and deliberately
                       empty rather than filled with invented geometry. --%>
                <aside
                  id="route-details-map-region"
                  class="min-w-0 lg:sticky lg:top-4 lg:self-start"
                >
                </aside>
              </div>
            <% true -> %>
              <div></div>
          <% end %>
        <% _ -> %>
          <div></div>
      <% end %>
    </Layouts.app>
    """
  end
end
