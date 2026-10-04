defmodule GtfsPlannerWeb.Gtfs.TransfersLive do
  @moduledoc """
  LiveView for managing the version's transfer rules.

  The page is the Routes area's second tab: a title bar over one bordered
  workspace, with the version's general rules on the left and the selected
  connection's context on the right. The catalog load runs synchronously through
  `Gtfs.load_transfer_catalog/3` on mount, so the states this shell renders are
  decided before the first paint. A lost database connection shows the list
  pane's load failure with a retry; a version without general rules shows the
  first-use state; an unavailable or empty load never leaves the workspace
  border as the only signal.

  The list's sort column, direction, page and selected rule live in the URL, as
  they do on Routes. Every param is parsed into a known value — the sort keys
  through an explicit table, never `String.to_atom/1` — and a request whose list
  differs from what the params asked for (a dropped value, a clamped page, a rule
  that is not in the view) patches the canonical URL instead of leaving the URL
  and the rendered list disagreeing. Sorting and paging drop the selected rule;
  selecting a row keeps the rest of the params.

  Filtering and search are in the URL too: the search term, the stop, route and
  type filters and the Needs attention toggle each patch the list and drop the
  page and the selected rule, and a filtered list that hides every rule shows its
  own empty state rather than first use. Every applied filter is also a removable
  chip in the count row, and `@rule` is the rule the URL names: below 1024px it
  decides whether the rule or the list has the screen, while the first row is
  still selected (and drawn) on a wide screen when the URL names none.

  The context pane's map region draws whatever connection the pane describes: the
  selected rule in list mode and the open draft in editor mode, each time as a
  `transfer_map:show` push carrying that connection's endpoints. The hook reports
  the map's own state with the generation this mount assigned, so a delayed report
  from a previous mount is ignored (R10); a failure replaces the canvas with the
  "Map unavailable" panel and "Retry map" asks the hook for the same connection
  again, while the list, the inspector and the form keep working. A pick session
  carries the next id and the side it answers: the hook's bounds are resolved to
  this version's stops for the candidate markers, a candidate is accepted only for
  the session that is still running and only if it names a stop or station of this
  version, and a pick sets that side's stop, drops the route and trip it had and
  marks the draft dirty. Pick mode is left by its own cancel control, by Escape or
  by closing the editor.

  The page holds two views of the same version. `@view` is `:general` (types 0–3,
  the default) or `:in_seat` (types 4 and 5), it lives in the URL as `view=in_seat`
  and only when it is the in-seat view, and the chips switch between them by
  dropping the filters, the page and the selected rule, because a filter and a
  selection belong to the view they were chosen in. The valid `type` values and
  the Needs attention flag follow the view: a type outside the view's range and an
  attention flag in the in-seat view are dropped rather than answered with an
  empty list. The in-seat view is read-only (R1): no control it renders reaches a
  write, and the later steps that add the create button, the row checkboxes, the
  editor and the delete flow read `@view` and render in the general view only.

  The context pane renders the selected rule's inspector from the same catalog
  load that produced the list: the selected row and the general rows that compete
  with it. "Inspect reverse rule" patches the rule to the row's exact mirror and
  drops the filters and the page, because the mirror has to be in the list the
  page shows; "Compare rules" opens the compare view over the same two assigns
  without reloading, and a new load closes it. Every read stays scoped to the
  socket's organization and version, and nothing here mutates a row (R1).

  The create editor replaces the list pane while a draft is open and keeps the
  draft in `@editor`: the eight GTFS fields the operator has entered, the scope
  they chose, the two resolved stops, the option lists the current scope shows,
  the form built from those fields, and whether the draft differs from the one it
  opened with. A change arrives as the whole draft, and the event's `_target`
  says which field moved: a changed stop clears that side's route and trip and
  re-resolves the stop for its hint, a changed route clears that side's trip, and
  a changed scope applies the scope's own rule — routes require both routes, and
  a saved rule stores no selector the chosen scope does not render. Option lists
  come from the step 7 facades, and the stop search from
  `Gtfs.search_transfer_stops/3` through the `LiveSelect` component. Saving goes
  through `Gtfs.create_general_transfer/2` with the socket's audit context, so the
  editor can only ever create a type 0–3 rule of this organization and version,
  and every refusal keeps the draft on screen.

  The same editor serves an existing rule. `:edit` mode holds the catalog row it
  opened with, so the draft carries the row's stored values — including a stored
  selector the version no longer offers, which the option lists keep with the
  reason it is not one of the stop's own choices — and saving sends that row's own
  `updated_at` through `Gtfs.update_general_transfer/4`, which refuses a rule that
  changed in the meantime with the reload path instead of overwriting it. "Create
  reverse rule" opens the same editor as an unsaved create draft with the six key
  fields mirrored, and the duplicate callout's "Open existing rule" and the
  compare view's "Edit rule" name another rule in the URL and open its editor
  after the load, through `@open_editor_for`.

  Version switching keeps the action and accepts only a published version of the
  current organization. A foreign, staging or absent version leaves both the
  socket and the client's selection untouched, as on the other GTFS pages.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.TransferComponents
  import GtfsPlannerWeb.PlannerComponents, only: [drawer_footer: 1, drawer_scroll: 1]

  import GtfsPlannerWeb.Gtfs.TransferHelperComponents,
    only: [
      policy_outcome: 1,
      policy_outcome?: 2,
      policy_review_body: 1,
      transfer_policy_source: 1
    ]

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.AgentPanel
  alias LiveSelect.Component, as: LiveSelectComponent

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # Untrusted sort params resolve through these tables; an unknown key or
  # direction is dropped rather than turned into an atom.
  @sort_keys %{"from" => :from, "to" => :to, "type" => :type, "min_time" => :min_time}
  @sort_dirs %{"asc" => :asc, "desc" => :desc}
  @owned_params ~w(view q stop route type attention sort_by sort_dir page rule)

  # A type filter is read only inside the current view's range: the general view
  # lists types 0–3, the in-seat view the read-only types 4 and 5.
  @general_types 0..3
  @in_seat_types 4..5

  # The editor's draft carries the eight GTFS fields as strings; anything else a
  # form or a crafted event submits is read by `Transfer.editor_changeset/2`'s own
  # cast, which takes only these and knows nothing of a tenant (CR-1).
  @editor_params ~w(from_stop_id to_stop_id from_route_id to_route_id from_trip_id to_trip_id
                    transfer_type min_transfer_time)

  # The scope is a workflow choice, so it is parsed through its own table, and it
  # decides which selectors the draft may keep and the rule may store.
  @scopes %{"stops" => :stops, "routes" => :routes, "custom" => :custom}
  @selector_params %{
    stops: ~w(from_route_id to_route_id from_trip_id to_trip_id),
    routes: ~w(from_trip_id to_trip_id),
    custom: []
  }

  # The two stop searches the editor renders: a LiveSelect change names the
  # component it came from, which is the only place a side is decided, and a
  # picked stop is sent back to the same component.
  @stop_components %{from: "transfer-from-stop", to: "transfer-to-stop"}
  @stop_component_sides Map.new(@stop_components, fn {side, id} -> {id, side} end)

  @empty_filters %{q: nil, stop: nil, route: nil, type: nil, attention: false}

  # The applied filters a chip can remove, by the key its button sends.
  @filter_keys %{"q" => :q, "type" => :type, "stop" => :stop, "route" => :route}

  # --- transfer helper -------------------------------------------------------

  # The source the helper may read is the one selection this page's own editor
  # draft states, so every direction, type and time in it came from an operator
  # form action rather than from the model (INV-1, INV-2).
  @source_kind "transfer_policy"
  @source_schema_version 1
  @selection_id_prefix "selection"
  @empty_policy_counts %{saved: 0, skipped: 0, conflict: 0, not_applied: 0}

  # The helper's refusals this page renders next to its own draft, so an operator
  # reads the same sentence the pack returned to the model.
  @prepared_missing_notice "That prepared change is no longer in this conversation. Ask the helper again."
  @source_error "This version or your access changed, so the helper has no transfer rules to work from."

  # An entry whose proposal did not apply exactly stays unconfirmed rather than
  # claiming a receipt the operator did not earn (INV-7).
  @prepared_edited_notice "Only part of the helper's proposal was saved. Ask the helper again for the rest."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Transfers")
     |> assign(:catalog_state, :ready)
     |> assign(:catalog, nil)
     |> assign(:view, :general)
     |> assign(:sort_by, :from)
     |> assign(:sort_dir, :asc)
     |> assign(:page, 1)
     |> assign(:per_page, 50)
     |> assign(:total_count, 0)
     |> assign(:selected_id, nil)
     |> assign(:selected, nil)
     |> assign(:competitors, [])
     |> assign(:compare_open?, false)
     |> assign(:rule, nil)
     |> assign(:page_rows, %{})
     |> assign(:page_ids, nil)
     |> assign(:url_params, %{})
     |> assign(:filters_open?, false)
     |> assign(:checked, %{})
     |> assign(:delete_dialog, nil)
     |> assign(:editor, nil)
     |> assign(:pending_discard, nil)
     |> assign(:open_editor_for, nil)
     |> assign(:back_path, "")
     |> assign(:map_generation, Ecto.UUID.generate())
     |> assign(:map_extent, map_extent(socket))
     |> assign(:map_state, :ready)
     |> assign(:map_missing, [])
     |> assign(:pick, nil)
     |> assign(:next_pick_id, 1)
     |> assign_filters(@empty_filters)
     |> assign(:policy_selections, [])
     |> assign(:policy_review, nil)
     |> assign(:policy_remaining, [])
     |> assign(:policy_origin, nil)
     |> assign(:policy_open?, false)
     |> assign(:policy_pending?, false)
     |> assign(:policy_status, nil)
     |> assign(:policy_notice, nil)
     |> assign(:policy_counts, @empty_policy_counts)
     |> assign(:policy_generation, 0)
     |> assign(:policy_return_focus, "transfer-policy-select")
     |> stream(:transfers, [])
     |> AgentPanel.mount("transfers")}
  end

  # The reviewed apply runs in this page's own async task under a generation the
  # socket carries, so the result of a superseded review never rewrites the review
  # now on screen (AC-5, AC-12).
  @impl true
  def handle_async({:transfer_policy_apply, generation}, result, socket) do
    if generation == socket.assigns.policy_generation do
      {:noreply, settle_policy(socket, result)}
    else
      # Presentation only: a committed operation is never described as cancelled
      # here, and the review the reviewer reopened keeps its own state. The
      # operator is told an answer went unanswered, so they re-read the list.
      {:noreply,
       assign(
         socket,
         :policy_notice,
         "A confirmation went unanswered. Refresh the list to see what it wrote."
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    url_params = Map.take(params, @owned_params)

    socket =
      socket
      |> assign(:url_params, url_params)
      |> assign(:in_seat_path, in_seat_path(socket))

    {:noreply, socket} = load_catalog(socket, url_params)

    {:noreply, open_pending_editor(socket)}
  end

  @impl true
  def handle_event("retry_load", _params, socket) do
    load_catalog(socket, socket.assigns.url_params)
  end

  @impl true
  def handle_event("sort", %{"key" => key}, socket) do
    case Map.get(@sort_keys, key) do
      nil ->
        {:noreply, socket}

      sort_by ->
        sort_dir = next_sort_dir(socket, sort_by)

        {:noreply,
         push_patch(clear_checked(socket),
           to: list_path(socket, sort_by: sort_by, sort_dir: sort_dir, page: 1, rule: nil)
         )}
    end
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply,
     push_patch(clear_checked(socket),
       to: list_path(socket, page: Values.positive_integer(page, 1), rule: nil)
     )}
  end

  @impl true
  def handle_event("select_rule", %{"id" => id}, socket) do
    case Ecto.UUID.cast(id) do
      {:ok, rule} -> {:noreply, push_patch(socket, to: list_path(socket, rule: rule))}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = merge_filters(socket.assigns.filters, params, socket.assigns.view)

    {:noreply,
     push_patch(clear_checked(socket),
       to: list_path(socket, filters: filters, page: 1, rule: nil)
     )}
  end

  @impl true
  def handle_event("search", params, socket) do
    filters = %{socket.assigns.filters | q: Values.presence(Map.get(params, "q"))}

    {:noreply,
     push_patch(clear_checked(socket),
       to: list_path(socket, filters: filters, page: 1, rule: nil)
     )}
  end

  @impl true
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, :filters_open?, not socket.assigns.filters_open?)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    # The bare list of the current view: the view param stays, every filter, the
    # page, the selection and the checked rules are dropped.
    {:noreply, push_patch(clear_checked(socket), to: list_path(socket, clear_overrides()))}
  end

  @impl true
  def handle_event("remove_filter", %{"key" => key}, socket) do
    case Map.get(@filter_keys, key) do
      nil ->
        {:noreply, socket}

      filter ->
        filters = Map.put(socket.assigns.filters, filter, nil)

        {:noreply,
         push_patch(clear_checked(socket),
           to: list_path(socket, filters: filters, page: 1, rule: nil)
         )}
    end
  end

  @impl true
  def handle_event("toggle_attention", _params, socket) do
    # Only the general view has attention reasons; a crafted event in the other
    # view changes nothing.
    if socket.assigns.view == :general do
      filters = %{socket.assigns.filters | attention: not socket.assigns.filters.attention}

      {:noreply,
       push_patch(clear_checked(socket),
         to: list_path(socket, filters: filters, page: 1, rule: nil)
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_view", %{"view" => value}, socket) do
    # The chips switch the list to a view whose rows are a different set, so the
    # filters, the page, the selected rule and the checked rules are left behind
    # with the old view.
    {:noreply,
     push_patch(clear_checked(socket),
       to: list_path(socket, view: parse_view(value), filters: @empty_filters, page: 1, rule: nil)
     )}
  end

  @impl true
  def handle_event("inspect_reverse", _params, socket) do
    case reverse_rule(socket) do
      nil -> {:noreply, socket}
      reverse_id -> {:noreply, push_patch(socket, to: reverse_path(socket, reverse_id))}
    end
  end

  @impl true
  def handle_event("open_compare", _params, socket) do
    if socket.assigns.competitors == [] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :compare_open?, true)}
    end
  end

  @impl true
  def handle_event("close_compare", _params, socket) do
    {:noreply, assign(socket, :compare_open?, false)}
  end

  @impl true
  def handle_event("toggle_check", %{"id" => id}, socket) do
    # Only a row of the shown page of the general view can be checked, so a
    # crafted event cannot check an in-seat, foreign, other-page or vanished row
    # (CR-1, CR-5).
    if selectable?(socket, id) do
      {:noreply, toggle_checked(socket, id)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_check_all", _params, socket) do
    {:noreply, toggle_all_shown(socket)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    # The checked rows are re-streamed so their checkboxes render unchecked.
    ids = Map.keys(socket.assigns.checked)
    {:noreply, socket |> clear_checked() |> restream_rows(ids)}
  end

  @impl true
  def handle_event("delete_selected", _params, socket) do
    {:noreply, open_delete_dialog(socket, checked_rows(socket), "transfers-delete-selected")}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    case socket.assigns.selected do
      %{transfer: %{transfer_type: type}} = row when type in @general_types ->
        {:noreply, open_delete_dialog(socket, [row], "transfer-inspector-delete")}

      _row ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_dialog, nil)}
  end

  @impl true
  def handle_event("apply_delete", _params, socket) do
    {:noreply, apply_delete(socket)}
  end

  @impl true
  def handle_event("open_create", _params, socket) do
    if socket.assigns.view == :general and is_nil(socket.assigns.editor) do
      editor = new_editor(socket)
      {:noreply, socket |> assign(:editor, editor) |> show_draft_map(editor)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_edit", params, socket) do
    case editable_row(socket, Map.get(params, "id")) do
      nil -> {:noreply, socket}
      row -> {:noreply, assign(socket, :editor, edit_editor(socket, row))}
    end
  end

  @impl true
  def handle_event("reverse_draft", _params, socket) do
    case {socket.assigns.view, socket.assigns.editor, socket.assigns.selected} do
      {:general, nil, %{transfer: %{transfer_type: type}} = row} when type in @general_types ->
        editor = reverse_editor(socket, row)

        # The draft mirrors the rule, so the map has to draw the mirrored
        # connection rather than the rule it was opened from (R7).
        {:noreply, socket |> assign(:editor, editor) |> show_draft_map(editor)}

      _other ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_existing", params, socket) do
    id = Map.get(params, "id")

    case socket.assigns.editor do
      %{error: {:duplicate, %{id: ^id}}} -> guard(socket, {:open_existing, id})
      _editor -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("compare_edit", params, socket) do
    id = Map.get(params, "id")

    if socket.assigns.compare_open? and known_rule_id?(socket, id) do
      {:noreply, open_rule(socket, id)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reload_rule", _params, socket) do
    case socket.assigns.editor do
      %{mode: :edit, row: %{id: id}} ->
        {:noreply,
         socket
         |> assign(:open_editor_for, id)
         |> push_patch(to: list_path(socket, rule: id))}

      _editor ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("editor_change", params, socket) do
    case socket.assigns.editor do
      nil -> {:noreply, socket}
      editor -> {:noreply, change_draft(socket, editor, params)}
    end
  end

  @impl true
  def handle_event("live_select_change", params, socket) do
    {:noreply, search_stops(socket, params)}
  end

  # --- transfer helper -------------------------------------------------------

  @impl true
  def handle_event("transfer_policy_select", _params, socket) do
    {:noreply, admit_policy_source(socket)}
  end

  @impl true
  def handle_event("transfer_policy_clear", _params, socket) do
    {:noreply, reset_policy(socket)}
  end

  # Removing one selection drops it from the admitted source with the others, so
  # the helper never reads a direction the operator took back.
  @impl true
  def handle_event("transfer_policy_remove", %{"id" => id}, socket) do
    selections = Enum.reject(socket.assigns.policy_selections, &(&1["id"] == id))

    {:noreply,
     socket
     |> assign(:policy_selections, selections)
     |> push_policy_context()}
  end

  def handle_event("transfer_policy_remove", _params, socket), do: {:noreply, socket}

  # The prepared card hands over one entry id and nothing else: the proposal this
  # page reviews is the one that entry prepared, never one the client names.
  @impl true
  def handle_event("agent_review_prepared", %{"entry" => id}, socket) do
    {:noreply, review_prepared_change(socket, id)}
  end

  def handle_event("agent_review_prepared", _params, socket), do: {:noreply, socket}

  # Re-reads the open review from the catalog the reviewer is looking at, so what
  # they confirm is what the fence compares.
  @impl true
  def handle_event("transfer_policy_review", _params, socket) do
    {:noreply, refresh_policy_review(socket)}
  end

  # A second confirmation while the first is in flight is refused: the reviewed
  # change is already being applied.
  @impl true
  def handle_event(
        "transfer_policy_apply",
        _params,
        %{assigns: %{policy_pending?: true}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("transfer_policy_apply", _params, socket),
    do: {:noreply, dispatch_policy(socket)}

  # Skipping writes nothing and counts the item, so a partly applied sequence
  # reads truthfully.
  @impl true
  def handle_event("transfer_policy_skip", _params, socket) do
    {:noreply, skip_policy_item(socket)}
  end

  @impl true
  def handle_event("transfer_policy_close", _params, socket) do
    {:noreply, close_policy(socket)}
  end

  @impl true
  def handle_event("save", params, socket), do: {:noreply, submit_draft(socket, params)}

  @impl true
  def handle_event("retry_save", params, socket), do: {:noreply, submit_draft(socket, params)}

  @impl true
  def handle_event("cancel_editor", _params, socket), do: guard(socket, :cancel)

  # The client half of the guard: the `DraftGuard` hook intercepts a same-origin
  # link click while the draft is dirty and sends the path here instead of
  # navigating. A path this page did not author is refused (R10); so is a
  # payload the hook never sends, which must not raise out of the handler.
  @impl true
  def handle_event("transfer_depart", %{"path" => path}, socket) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      guard(socket, {:navigate, path})
    else
      {:noreply, socket}
    end
  end

  def handle_event("transfer_depart", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("discard_changes", _params, socket) do
    case socket.assigns.pending_discard do
      nil -> {:noreply, socket}
      action -> {:noreply, socket |> assign(:pending_discard, nil) |> discard_action(action)}
    end
  end

  @impl true
  def handle_event("keep_editing", _params, socket) do
    {:noreply, assign(socket, :pending_discard, nil)}
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      guard(socket, {:switch_version, version_id})
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: transfers_target(version_id))}
    else
      {:noreply, socket}
    end
  end

  # --- connection map and pick-on-map ----------------------------------------

  # The hook reports the map's own state with the generation it mounted with, so a
  # delayed report from a previous mount cannot speak for this one (R10). Only the
  # two failure states and `ready` are known; anything else leaves the page as it
  # was.
  @impl true
  def handle_event("transfer_map_state", params, socket) do
    if Map.get(params, "generation") == socket.assigns.map_generation do
      {:noreply, assign_map_state(socket, Map.get(params, "state"))}
    else
      {:noreply, socket}
    end
  end

  # "Retry map" shows the canvas again and asks the hook for the same connection:
  # it redraws its tiles and remeasures the container it has held all along.
  @impl true
  def handle_event("retry_map", _params, socket) do
    {:noreply, socket |> assign(:map_state, :ready) |> push_event("transfer_map:retry", %{})}
  end

  # A pick session belongs to the open draft and to the next pick id. The hook
  # echoes that id on every candidate and pick, so a session that has ended cannot
  # answer for the next one (CR-6).
  @impl true
  def handle_event("start_pick", %{"side" => value}, socket) do
    with true <- editor_open?(socket.assigns.editor, socket.assigns.view),
         side when not is_nil(side) <- pick_side(value) do
      pick = %{id: socket.assigns.next_pick_id, side: side, truncated?: false}

      {:noreply,
       socket
       |> assign(:pick, pick)
       |> assign(:next_pick_id, pick.id + 1)
       |> push_event("transfer_map:pick_start", %{
         pick_id: pick.id,
         side: pick_side_value(side)
       })}
    else
      _refused -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_pick", _params, socket), do: {:noreply, end_pick(socket)}

  # The candidates are this version's own stops inside the box the hook reports.
  # The read parses and clamps the box, and a box it refuses pushes nothing.
  @impl true
  def handle_event("transfer_map_bounds", params, socket) do
    with %{id: id} <- socket.assigns.pick,
         true <- Map.get(params, "pick_id") == id,
         {:ok, candidates} <-
           Gtfs.transfer_stops_in_bounds(organization_id(socket), version_id(socket), params) do
      {:noreply,
       socket
       |> assign(:pick, %{socket.assigns.pick | truncated?: candidates.truncated?})
       |> push_event("transfer_map:pick_candidates", %{
         pick_id: id,
         stops: candidates.stops,
         truncated: candidates.truncated?
       })}
    else
      _refused -> {:noreply, socket}
    end
  end

  # A pick names one side and one stop. The id is resolved inside this page's own
  # version before it can reach the draft, so an entrance, an unknown id, another
  # version's stop or a stale session leaves the draft exactly as it was (R2,
  # R10).
  @impl true
  def handle_event("transfer_map_pick", params, socket) do
    with %{id: id, side: side} <- socket.assigns.pick,
         true <- Map.get(params, "pick_id") == id,
         true <- editor_open?(socket.assigns.editor, socket.assigns.view),
         stop_id when is_binary(stop_id) <- Map.get(params, "stop_id"),
         {:ok, stop} <-
           Gtfs.fetch_transfer_stop(organization_id(socket), version_id(socket), stop_id) do
      {:noreply, apply_pick(socket, side, stop)}
    else
      _refused -> {:noreply, socket}
    end
  end

  defp assign_map_state(socket, "ready"), do: assign(socket, :map_state, :ready)

  defp assign_map_state(socket, state) when state in ["imagery_unavailable", "fatal"],
    do: assign(socket, :map_state, :unavailable)

  defp assign_map_state(socket, _unknown), do: socket

  defp map_extent(socket),
    do: Gtfs.transfer_version_extent(organization_id(socket), version_id(socket))

  # The map protocol's two names for one side of the connection.
  defp pick_side("a"), do: :from
  defp pick_side("b"), do: :to
  defp pick_side(_value), do: nil

  defp pick_side_value(:from), do: "a"
  defp pick_side_value(:to), do: "b"

  # A pick is over: the hook is told which session ended, so its candidate markers
  # go and later bounds pushes are dropped there too.
  defp end_pick(socket) do
    case socket.assigns.pick do
      nil ->
        socket

      %{id: id} ->
        socket |> assign(:pick, nil) |> push_event("transfer_map:pick_end", %{pick_id: id})
    end
  end

  # A picked stop is that side's answer: the route and trip it had were answered
  # for the stop that is gone, so both go, and the option lists follow the new
  # stop. `LiveSelect` keeps the option list it first rendered across a parent
  # re-render, so the picked stop's label travels with its value.
  defp apply_pick(socket, side, stop) do
    editor = socket.assigns.editor

    params =
      editor.params
      |> Map.put("#{side}_stop_id", stop.stop_id)
      |> Map.drop(["#{side}_route_id", "#{side}_trip_id"])
      |> strip_selectors(editor.scope)

    editor = %{editor | params: params}
    editor = put_draft_stop(editor, side, stop)
    editor = refresh_options(socket, editor)

    editor = %{
      editor
      | dirty?: params != editor.initial,
        form: editor_form(socket, params, :validate)
    }

    send_update(LiveSelectComponent,
      id: Map.fetch!(@stop_components, side),
      value: stop.stop_id,
      options: [%{label: stop_label(stop), value: stop.stop_id, hint: stop_hint(stop)}]
    )

    socket
    |> put_editor(editor)
    |> end_pick()
    |> show_draft_map(editor)
  end

  defp put_draft_stop(editor, :from, stop), do: %{editor | from_stop: stop}
  defp put_draft_stop(editor, :to, stop), do: %{editor | to_stop: stop}

  # The connection the context pane describes is the connection the map draws: the
  # selected rule in list mode and the draft in editor mode. `fit` asks the hook
  # for the connection's own view, and the same payload names the endpoints the
  # version holds without coordinates.
  # A load in list mode brings the map back to the selected rule. A load while a
  # draft is open leaves the map drawing that draft, which is the connection the
  # context pane describes then.
  defp show_loaded_map(%{assigns: %{editor: nil}} = socket, selection),
    do: show_selected_map(socket, selection)

  defp show_loaded_map(socket, _selection), do: socket

  defp show_selected_map(socket, nil), do: assign(socket, :map_missing, [])

  defp show_selected_map(socket, %{from: from, to: to}) do
    push_map(socket, %{from_stop_id: from.stop_id, to_stop_id: to.stop_id})
  end

  defp show_draft_map(socket, editor) do
    push_map(socket, %{
      from_stop_id: editor.params["from_stop_id"],
      to_stop_id: editor.params["to_stop_id"]
    })
  end

  defp push_map(socket, endpoints) do
    payload = Gtfs.transfer_map_payload(organization_id(socket), version_id(socket), endpoints)

    socket
    |> assign(:map_missing, payload.missing_coordinates)
    |> push_event("transfer_map:show", Map.put(payload, :fit, true))
  end

  # --- transfer helper -------------------------------------------------------

  # A selection the helper may read is one direction from the operator's own open
  # draft, plus the rows they ticked to keep. Every value comes from the
  # server-held editor and catalog, never from a client payload (INV-1). A draft
  # with no direction is refused here rather than sent on.
  defp admit_policy_source(socket) do
    case socket.assigns.editor do
      %{mode: :create} = editor ->
        stage_policy_selection(socket, editor)

      _other ->
        assign(
          socket,
          :policy_notice,
          "Open a new transfer rule first, then ask the helper to work on it."
        )
    end
  end

  # The draft stays open and stays on screen: staging a selection offers the rule
  # to the helper, it never saves it and never closes what the operator is writing.
  defp stage_policy_selection(socket, editor) do
    case policy_selection(socket, editor) do
      {:ok, selection} ->
        socket
        |> assign(:policy_selections, socket.assigns.policy_selections ++ [selection])
        |> push_policy_context()

      :incomplete ->
        assign(
          socket,
          :policy_notice,
          "Choose both stops before asking the helper to work on this rule."
        )
    end
  end

  defp policy_selection(socket, %{params: params}) do
    from = policy_side(params, "from_stop_id", "from_route_id", "from_trip_id")
    to = policy_side(params, "to_stop_id", "to_route_id", "to_trip_id")

    case {from["stop_id"], to["stop_id"]} do
      {from_stop, to_stop} when is_binary(from_stop) and is_binary(to_stop) ->
        type = policy_type(params["transfer_type"])

        {:ok,
         %{
           "id" => "#{@selection_id_prefix}-#{length(socket.assigns.policy_selections) + 1}",
           "from" => from,
           "to" => to,
           "transfer_type" => type,
           "min_time" => policy_min_time(params, type),
           "protected_ids" => socket.assigns.checked |> Map.keys() |> Enum.sort()
         }}

      _incomplete ->
        :incomplete
    end
  end

  # A side carries the stop the operator chose plus the selectors this draft's
  # scope states; an unfilled selector is absent, never an empty string the pack
  # would read as a stated one.
  defp policy_side(params, stop_key, route_key, trip_key) do
    %{
      "stop_id" => Values.presence(params[stop_key]),
      "route_id" => Values.presence(params[route_key]),
      "trip_id" => Values.presence(params[trip_key])
    }
  end

  defp policy_type(value) when is_binary(value) do
    case Integer.parse(value) do
      {type, ""} -> type
      _other -> 2
    end
  end

  defp policy_type(type) when is_integer(type), do: type

  # Only a minimum-time rule states a time, and only in seconds. The page's own
  # editor is where any other unit would be refused, so a draft reaching here
  # never carried one (INV-8).
  defp policy_min_time(params, 2) do
    case params["min_transfer_time"] do
      value when is_binary(value) and value != "" ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> %{"value" => seconds, "unit" => "seconds"}
          _other -> nil
        end

      _empty ->
        nil
    end
  end

  defp policy_min_time(_params, _type), do: nil

  # The admitted context is the one the helper reads for the rest of this
  # conversation. A context the server did not build is never handed on, and a
  # refused admission leaves the panel with no source to read at all
  # (INV-2, INV-11).
  defp push_policy_context(socket) do
    base = Scope.context({:version, version_id(socket)})

    case Scope.with_source_snapshot(base, %{kind: @source_kind, payload: policy_payload(socket)}) do
      {:ok, context} ->
        socket
        |> assign(:policy_notice, nil)
        |> AgentPanel.set_context(context)

      {:error, _reason} ->
        socket
        |> assign(:policy_selections, [])
        |> assign(:policy_notice, @source_error)
        |> AgentPanel.set_context(base)
    end
  end

  defp policy_payload(socket) do
    %{
      "schema_version" => @source_schema_version,
      "selections" => Enum.map(socket.assigns.policy_selections, &selection_payload/1)
    }
  end

  defp selection_payload(selection) do
    %{
      "id" => selection["id"],
      "from" => selection["from"],
      "to" => selection["to"],
      "transfer_type" => selection["transfer_type"],
      "min_time" => selection["min_time"],
      "protected_ids" => selection["protected_ids"]
    }
  end

  # Clearing the selection drops the snapshot with it, so the panel has nothing to
  # read until the operator supplies a direction again.
  defp reset_policy(socket) do
    socket
    |> assign(:policy_selections, [])
    |> assign(:policy_notice, nil)
    |> AgentPanel.set_context(Scope.context({:version, version_id(socket)}))
  end

  # --- prepared review -------------------------------------------------------

  # The prepared card hands over one entry id and this page asks the session for
  # that entry's own proposal. Only a transfer-policy sequence prepared against
  # the source this page admitted is reviewed; anything else is refused, and a
  # proposal whose source digest no longer matches is dropped rather than
  # reviewed (INV-5, INV-10).
  defp review_prepared_change(socket, id) do
    with {entry_id, ""} when entry_id > 0 <- Integer.parse(to_string(id)),
         {:ok,
          %{
            command: %{
              kind: :transfer_policy_sequence,
              items: [_first | _rest] = items,
              source_digest: digest
            }
          }} <-
           Agents.prepared(
             socket.assigns.agent_session,
             socket.assigns.agent_conversation_id,
             entry_id
           ),
         :ok <- policy_digest_matches(socket, digest) do
      open_policy_review(socket, entry_id, items, digest)
    else
      _other ->
        assign(socket, :agent_notice, @prepared_missing_notice)
    end
  end

  # The admitted snapshot's own digest is what the helper prepared against, so a
  # proposal built from an earlier selection never reaches this page's review.
  defp policy_digest_matches(socket, digest) do
    case socket.assigns.agent_context do
      %{source_snapshot: %{digest: admitted}} -> if admitted == digest, do: :ok, else: :error
      _no_snapshot -> :error
    end
  end

  # A sequence closed or skipped after some of its rules were saved is not opened
  # again from its first rule: that rule would read as a new one and be refused as
  # a duplicate, with the rules after it out of reach. The helper is asked again
  # for the rest instead. Simplification: only the entry opened last is remembered
  # (`policy_origin`); an older partly saved card opened after another proposal
  # reviews from its first rule, and Apply still refuses the saved rule. Tracking
  # the saved rules per entry would close that.
  defp open_policy_review(
         %{assigns: %{policy_origin: %{entry_id: entry_id, saved: saved}}} = socket,
         entry_id,
         items,
         _digest
       )
       when saved > 0 and saved < length(items),
       do: assign(socket, :agent_notice, @prepared_edited_notice)

  # Every item of the sequence gets its own review against the catalog as it
  # stands now, so each confirmation the operator gives covers exactly one rule.
  defp open_policy_review(socket, entry_id, items, digest) do
    case review_next(socket, items) do
      {:ok, review, rest, refused} ->
        socket
        |> assign(:policy_review, review)
        |> assign(:policy_remaining, rest)
        |> assign(:policy_origin, %{
          session_pid: socket.assigns.agent_session,
          conversation_id: socket.assigns.agent_conversation_id,
          entry_id: entry_id,
          saved: 0,
          command: %{kind: :transfer_policy_sequence, items: items, source_digest: digest}
        })
        |> assign(:policy_open?, true)
        |> assign(:policy_pending?, false)
        |> assign(:policy_generation, socket.assigns.policy_generation + 1)
        |> assign(:policy_return_focus, "agent-prepared-#{entry_id}")
        # The outcome shown is this proposal's, not a running total of earlier ones.
        |> assign(:policy_status, nil)
        |> assign(:policy_counts, @empty_policy_counts)
        |> count_refused(refused)

      {:none, refused} ->
        assign(socket, :agent_notice, policy_refusal_message(none_reviewed_reason(refused)))
    end
  end

  # The first item that reviews cleanly against the catalog as it stands, the items
  # after it, and the reasons the earlier ones were refused.
  defp review_next(socket, items), do: review_next(socket, items, [])

  defp review_next(_socket, [], refused), do: {:none, Enum.reverse(refused)}

  defp review_next(socket, [item | rest], refused) do
    case review_policy_item(socket, item) do
      {:ok, review} -> {:ok, review, rest, Enum.reverse(refused)}
      {:error, reason} -> review_next(socket, rest, [reason | refused])
    end
  end

  defp none_reviewed_reason([reason]), do: reason
  defp none_reviewed_reason(_several), do: :empty

  defp count_refused(socket, refused) do
    counts = Enum.reduce(refused, socket.assigns.policy_counts, &count_policy_outcome(&2, &1))

    assign(socket, :policy_counts, counts)
  end

  defp review_policy_item(socket, item) do
    Transfers.review_policy_change(
      policy_scope(socket),
      item,
      AuditContext.from_assigns(socket.assigns)
    )
  end

  defp policy_scope(socket),
    do: %{organization_id: organization_id(socket), gtfs_version_id: version_id(socket)}

  defp policy_refusal_message(:empty),
    do:
      "The helper's proposal no longer reads against these transfer rules, so nothing was reviewed."

  defp policy_refusal_message(:stale),
    do: "A competing transfer rule changed, so this proposal was not reviewed."

  defp policy_refusal_message(:forbidden),
    do: "You may not change that transfer rule, so this proposal was not reviewed."

  defp policy_refusal_message(:not_found),
    do: "That transfer rule is gone, so this proposal was not reviewed."

  defp policy_refusal_message({:conflict, _witnesses}),
    do: "A competing transfer rule would change meaning, so this proposal was not reviewed."

  defp policy_refusal_message(_other),
    do: "This proposal could not be reviewed against the current transfer rules."

  # A refusal the catalog itself gives is shown with the drawer still open and
  # the operator's draft untouched: nothing is retried or undone on their behalf.
  defp settle_policy(socket, {:ok, {:applied, {:error, reason}}}) do
    socket
    |> assign(:policy_pending?, false)
    |> assign(:policy_counts, count_policy_outcome(socket.assigns.policy_counts, reason))
    |> assign(:policy_status, "Not applied: " <> policy_apply_refusal(reason))
    |> refresh_policy_review()
  end

  # A saved rule changes the catalog every remaining item was reviewed against, so
  # each is reviewed again against the catalog as it now stands (AC-5): the first
  # that still reviews opens next, and every one the new catalog refuses is counted
  # rather than applied from a stale read.
  defp settle_policy(socket, {:ok, {:applied, {:ok, transfer}}}) do
    counts = socket.assigns.policy_counts

    socket
    |> assign(:policy_pending?, false)
    |> assign(:policy_counts, %{counts | saved: counts.saved + 1})
    |> update_policy_origin(&%{&1 | saved: &1.saved + 1})
    |> reload_policy_catalog()
    |> review_remaining(policy_saved_message(transfer), socket.assigns.policy_remaining)
  end

  # An exit or an answer this page does not recognize is left unconfirmed: the
  # drawer says the attempt was not confirmed and the catalog is re-read, rather
  # than claiming a write either way (AC-12).
  defp settle_policy(socket, _other) do
    socket
    |> assign(:policy_pending?, false)
    |> assign(:policy_status, "Not confirmed. Re-read the transfer rules before trying again.")
    |> reload_policy_catalog()
  end

  defp review_remaining(socket, saved_message, remaining) do
    case review_next(socket, remaining) do
      {:ok, review, rest, refused} ->
        socket
        |> assign(:policy_review, review)
        |> assign(:policy_remaining, rest)
        |> assign(:policy_generation, socket.assigns.policy_generation + 1)
        |> assign(:policy_status, saved_message <> " Review the next rule.")
        |> count_refused(refused)

      {:none, refused} ->
        socket
        |> assign(:policy_review, nil)
        |> assign(:policy_open?, false)
        |> assign(:policy_remaining, [])
        |> assign(:policy_status, saved_message)
        |> count_refused(refused)
        |> record_policy_applied()
    end
  end

  defp update_policy_origin(%{assigns: %{policy_origin: nil}} = socket, _update), do: socket

  defp update_policy_origin(socket, update),
    do: assign(socket, :policy_origin, update.(socket.assigns.policy_origin))

  defp policy_saved_message(transfer),
    do:
      "Saved transfer type #{transfer.transfer_type} from #{transfer.from_stop_id} to #{transfer.to_stop_id}."

  defp count_policy_outcome(counts, {:conflict, _witnesses}),
    do: %{counts | conflict: counts.conflict + 1, not_applied: counts.not_applied + 1}

  defp count_policy_outcome(counts, _reason),
    do: %{counts | not_applied: counts.not_applied + 1}

  defp policy_apply_refusal(:stale), do: "a competing transfer rule changed."
  defp policy_apply_refusal(:forbidden), do: "you may not change that transfer rule."
  defp policy_apply_refusal(:not_found), do: "that transfer rule is gone."

  defp policy_apply_refusal({:conflict, _witnesses}),
    do: "a competing transfer rule would change meaning."

  defp policy_apply_refusal({:duplicate, _collision}), do: "an identical rule already exists."
  defp policy_apply_refusal(:protected), do: "that rule is protected from this change."
  defp policy_apply_refusal(_other), do: "the change could not be applied."

  # Re-reads the review on screen from the catalog the reviewer is looking at, so
  # what they confirm is what the fence will compare (AC-4).
  defp refresh_policy_review(socket) do
    case socket.assigns.policy_review do
      %{command: command} ->
        case review_policy_item(socket, command) do
          {:ok, review} -> assign(socket, :policy_review, review)
          {:error, reason} -> assign(socket, :policy_notice, policy_refusal_message(reason))
        end

      _none ->
        socket
    end
  end

  # Only Apply runs the reviewed apply, against the reviewed change itself and the
  # audit this page's own scope built. No other path on this page writes from a
  # proposal.
  defp dispatch_policy(socket) do
    case socket.assigns.policy_review do
      nil ->
        socket

      review ->
        generation = socket.assigns.policy_generation + 1
        audit = AuditContext.from_assigns(socket.assigns)

        socket
        |> assign(:policy_generation, generation)
        |> assign(:policy_pending?, true)
        |> start_async({:transfer_policy_apply, generation}, fn ->
          {:applied, Transfers.apply_reviewed_policy_change(review, audit)}
        end)
    end
  end

  # A receipt is recorded with the exact command the entry prepared, and only when
  # every item of that sequence was saved. A partly applied proposal leaves the
  # entry unconfirmed and says so, rather than claiming a whole (INV-7).
  defp record_policy_applied(%{assigns: %{policy_origin: nil}} = socket), do: socket

  defp record_policy_applied(%{assigns: %{policy_origin: origin}} = socket) do
    if origin.saved == length(origin.command.items) do
      record_policy_receipt(socket, origin)
    else
      assign(socket, :agent_notice, @prepared_edited_notice)
    end
  end

  defp record_policy_receipt(socket, origin) do
    case Agents.record_applied(
           origin.session_pid,
           origin.conversation_id,
           origin.entry_id,
           origin.command
         ) do
      :ok ->
        socket

      {:error, :command_changed} ->
        assign(socket, :agent_notice, @prepared_edited_notice)

      _stale_or_ended ->
        socket
    end
  end

  # The saved rule is not on this page until the catalog behind it is read again.
  defp reload_policy_catalog(socket) do
    {:noreply, socket} = load_catalog(socket, socket.assigns.url_params)

    socket
  end

  # Skipping counts the item and leaves the rest of the proposal unapplied; it
  # writes nothing.
  defp skip_policy_item(socket) do
    remaining = socket.assigns.policy_remaining

    socket
    |> assign(:policy_review, nil)
    |> assign(:policy_open?, false)
    |> assign(:policy_pending?, false)
    |> assign(:policy_remaining, remaining)
    |> assign(:policy_counts, %{
      socket.assigns.policy_counts
      | skipped: socket.assigns.policy_counts.skipped + 1 + length(remaining),
        not_applied: socket.assigns.policy_counts.not_applied + length(remaining)
    })
    |> assign(:policy_status, skipped_message(socket.assigns.policy_origin))
  end

  defp skipped_message(%{saved: saved}) when saved > 0,
    do: "Skipped. The rules already saved from this proposal stay saved."

  defp skipped_message(_origin), do: "Skipped. Nothing was written for this proposal."

  # Closing bumps the generation, so a result still in flight lands on no review
  # at all (AC-12).
  defp close_policy(socket) do
    socket
    |> abandon_unreviewed()
    |> assign(:policy_open?, false)
    |> assign(:policy_pending?, false)
    |> assign(:policy_review, nil)
    |> assign(:policy_generation, socket.assigns.policy_generation + 1)
  end

  # Closing leaves the rule on screen and the rules after it unapplied. When an
  # earlier rule of the sequence was saved they are counted as not applied, the
  # "Review the next rule." status of a drawer that is gone is replaced, and the
  # entry is reported as partly saved, as when the rest is refused. With nothing
  # saved the proposal is untouched and can be reviewed again from its first rule.
  # A rule whose apply is still in flight has no known outcome, so it is not counted.
  defp abandon_unreviewed(
         %{assigns: %{policy_review: %{}, policy_pending?: false, policy_origin: %{saved: saved}}} =
           socket
       )
       when saved > 0 do
    counts = socket.assigns.policy_counts
    unreviewed = 1 + length(socket.assigns.policy_remaining)

    socket
    |> assign(:policy_counts, %{counts | not_applied: counts.not_applied + unreviewed})
    |> assign(:policy_remaining, [])
    |> assign(:policy_status, "Closed. The rules already saved from this proposal stay saved.")
    |> assign(:agent_notice, @prepared_edited_notice)
  end

  defp abandon_unreviewed(socket), do: socket

  # --- create editor ---------------------------------------------------------

  # The draft the editor holds: the eight GTFS fields as the operator entered them,
  # the scope they chose, the two resolved stops, the options the scope shows, the
  # form built from those fields, and whether the draft still equals the one it
  # opened with.
  defp new_editor(socket) do
    params = blank_params()

    %{
      mode: :create,
      scope: :stops,
      params: params,
      form: editor_form(socket, params, nil),
      from_stop: nil,
      to_stop: nil,
      options: empty_options(),
      initial: params,
      dirty?: false,
      error: nil
    }
  end

  # A new draft is a minimum-time rule with no time: the reference's prefilled 180
  # seconds would become a stored decision the operator never made.
  defp blank_params do
    %{
      "from_stop_id" => "",
      "to_stop_id" => "",
      "from_route_id" => "",
      "to_route_id" => "",
      "from_trip_id" => "",
      "to_trip_id" => "",
      "transfer_type" => "2",
      "min_transfer_time" => ""
    }
  end

  defp empty_options, do: %{from_routes: [], to_routes: [], from_trips: [], to_trips: []}

  # The editor opens on a stored rule with the values the row holds: the eight
  # GTFS fields, the scope those selectors imply, the two stops the version
  # resolves (or the row's own endpoint when the stored stop is gone) and the
  # option lists, which keep a stored selector with the reason it is not among the
  # stop's own options (AC-19).
  defp edit_editor(socket, row) do
    params = edit_params(row.transfer)

    editor = %{
      mode: :edit,
      row: row,
      scope: draft_scope(params),
      params: params,
      form: editor_form(socket, params, nil),
      from_stop: edit_stop(socket, row.from),
      to_stop: edit_stop(socket, row.to),
      options: empty_options(),
      initial: params,
      dirty?: false,
      error: nil
    }

    refresh_options(socket, editor)
  end

  # "Create reverse rule" opens the same editor a new rule gets, with the six key
  # fields mirrored and the effect copied. Nothing is written until save, and the
  # draft already differs from the one a new rule starts with (R7).
  defp reverse_editor(socket, row) do
    transfer = row.transfer

    params = %{
      "from_stop_id" => stored_value(transfer.to_stop_id),
      "to_stop_id" => stored_value(transfer.from_stop_id),
      "from_route_id" => stored_value(transfer.to_route_id),
      "to_route_id" => stored_value(transfer.from_route_id),
      "from_trip_id" => stored_value(transfer.to_trip_id),
      "to_trip_id" => stored_value(transfer.from_trip_id),
      "transfer_type" => stored_value(transfer.transfer_type),
      "min_transfer_time" => stored_value(transfer.min_transfer_time)
    }

    editor = %{
      mode: :create,
      scope: draft_scope(params),
      params: params,
      form: editor_form(socket, params, nil),
      from_stop: edit_stop(socket, row.to),
      to_stop: edit_stop(socket, row.from),
      options: empty_options(),
      initial: blank_params(),
      dirty?: params != blank_params(),
      error: nil
    }

    refresh_options(socket, editor)
  end

  # The stored rule as the draft's eight fields, the way a form reads them. The
  # selectors are kept exactly as stored, including the ones the version no longer
  # offers (AC-19).
  defp edit_params(transfer) do
    %{
      "from_stop_id" => stored_value(transfer.from_stop_id),
      "to_stop_id" => stored_value(transfer.to_stop_id),
      "from_route_id" => stored_value(transfer.from_route_id),
      "to_route_id" => stored_value(transfer.to_route_id),
      "from_trip_id" => stored_value(transfer.from_trip_id),
      "to_trip_id" => stored_value(transfer.to_trip_id),
      "transfer_type" => stored_value(transfer.transfer_type),
      "min_transfer_time" => stored_value(transfer.min_transfer_time)
    }
  end

  # The scope a rule's own selectors imply: a trip narrows further than a route,
  # and a rule with neither is the stop pair it names.
  defp draft_scope(params) do
    cond do
      draft_present?(params, "from_trip_id") or draft_present?(params, "to_trip_id") -> :custom
      draft_present?(params, "from_route_id") or draft_present?(params, "to_route_id") -> :routes
      true -> :stops
    end
  end

  defp draft_present?(params, key), do: Values.presence(Map.get(params, key)) != nil

  defp stored_value(nil), do: ""
  defp stored_value(value) when is_binary(value), do: value
  defp stored_value(value), do: to_string(value)

  # A stored stop resolves through the page's own version, exactly as a chosen one
  # does; when the version no longer holds it, the row's endpoint still has to show
  # as the field's value, so the field carries a minimal option built from it.
  defp edit_stop(_socket, nil), do: nil
  defp edit_stop(_socket, %{stop_id: nil}), do: nil

  defp edit_stop(socket, endpoint) do
    case Gtfs.fetch_transfer_stop(organization_id(socket), version_id(socket), endpoint.stop_id) do
      {:ok, stop} -> stop
      :error -> missing_stop_option(endpoint)
    end
  end

  defp missing_stop_option(endpoint) do
    %{
      stop_id: endpoint.stop_id,
      stop_name: endpoint.name,
      location_type: endpoint.location_type,
      platform_code: endpoint.platform_code,
      parent_name: nil,
      child_count: endpoint.child_count,
      lat: nil,
      lon: nil,
      missing?: true
    }
  end

  # Only a general rule the page has loaded can be opened for editing: an id of
  # the other view, another page, version or organization is not a row here, so a
  # crafted event cannot load a rule the list is not showing (CR-1, CR-6).
  defp editable_row(socket, id) when is_binary(id) do
    if socket.assigns.view == :general and is_nil(socket.assigns.editor) do
      Map.get(socket.assigns.page_rows, id)
    end
  end

  defp editable_row(_socket, _id), do: nil

  # `@open_editor_for` names the rule whose editor a patch should open. It opens
  # only once the load has made that rule the selection, so the editor always
  # describes a row the page is showing, and the assign is spent either way.
  defp open_pending_editor(%{assigns: %{open_editor_for: id}} = socket) when is_binary(id) do
    socket = assign(socket, :open_editor_for, nil)

    case socket.assigns.selected do
      %{id: ^id} = row -> assign(socket, :editor, edit_editor(socket, row))
      _row -> socket
    end
  end

  defp open_pending_editor(socket), do: socket

  # Another rule's editor is reached by naming it in the URL: the patch clears the
  # filters, the page and the checked rules, the load selects the rule, and
  # `handle_params/3` opens it.
  defp open_rule(socket, id) do
    socket
    |> clear_checked()
    |> assign(:editor, nil)
    |> assign(:compare_open?, false)
    |> assign(:open_editor_for, id)
    |> push_patch(
      to: list_path(socket, view: :general, filters: @empty_filters, page: 1, rule: id)
    )
  end

  # Every way out of a dirty draft waits behind the same question (AC-20). The
  # action runs immediately when there is no draft to lose, so Cancel and the
  # departure paths keep their ordinary behavior for a clean editor.
  defp guard(socket, action) do
    if dirty_draft?(socket) do
      {:noreply, assign(socket, :pending_discard, action)}
    else
      {:noreply, discard_action(socket, action)}
    end
  end

  defp dirty_draft?(socket) do
    case socket.assigns.editor do
      %{dirty?: true} -> true
      _editor -> false
    end
  end

  defp discard_action(socket, :cancel), do: close_editor(socket)
  defp discard_action(socket, {:open_existing, id}), do: open_rule(socket, id)
  defp discard_action(socket, {:navigate, path}), do: push_navigate(socket, to: path)

  defp discard_action(socket, {:switch_version, version_id}) do
    socket
    |> push_event("gtfs_version_selected", %{version_id: version_id})
    |> push_navigate(to: transfers_target(version_id))
  end

  defp close_editor(socket) do
    socket
    |> assign(:editor, nil)
    |> end_pick()
    |> restream_list()
    |> show_selected_map(socket.assigns.selected)
  end

  # The editor replaces the list pane, so the rows the stream last sent landed in a
  # container the DOM no longer had. Opening the editor without a patch (the create
  # button or a row's Edit) leaves the stream holding nothing pending, so closing it
  # re-sends every row of the page the pane shows again. `push_patch` paths (save,
  # deleted rule, version switch) reload the catalog and re-stream themselves.
  defp restream_list(%{assigns: %{catalog: %{rows: rows}}} = socket),
    do: stream(socket, :transfers, rows, reset: true)

  defp restream_list(socket), do: socket

  # The rules the compare view lists: the selected rule and its competitors.
  defp known_rule_id?(socket, id) do
    id in [socket.assigns.selected_id | Enum.map(socket.assigns.competitors, & &1.id)]
  end

  defp editor_form(socket, params, action) do
    Transfer.editor_changeset(editor_base(socket), params)
    |> form_for(action)
  end

  # The changeset carries the errors the form shows, so its action decides which of
  # them are visible: a draft that has not been used has none, a changed draft is
  # `:validate`, and a refused save is `:insert`.
  defp form_for(changeset, action), do: to_form(put_form_action(changeset, action), as: :transfer)

  defp put_form_action(changeset, nil), do: changeset
  defp put_form_action(changeset, action), do: Map.put(changeset, :action, action)

  # The organization and the version come from the socket, never from a form or an
  # event, so a draft can only ever be saved inside the page's own version (R10).
  defp editor_base(socket) do
    %Transfer{
      organization_id: organization_id(socket),
      gtfs_version_id: version_id(socket)
    }
  end

  # One change carries the whole draft back. `_target` names the field that moved,
  # and the dependents follow it: a new stop clears that side's route and trip and
  # resolves the stop again, a new route clears that side's trip, and a new scope
  # drops every selector the scope does not render. Anything else is only merged,
  # so an absent or unknown target cannot silently clear the operator's work.
  defp change_draft(socket, editor, params) do
    scope = parse_scope(Map.get(params, "scope"), editor.scope)
    target = editor_target(params)

    # The endpoints the map already draws, read before this change lands.
    endpoints = draft_endpoints(editor)

    editor = %{
      editor
      | scope: scope,
        params:
          editor.params
          |> Map.merge(Map.take(submitted_values(params), @editor_params))
          |> strip_selectors(scope)
    }

    editor = clear_dependents(editor, target)
    editor = refresh_stop(socket, editor, target)
    editor = refresh_options(socket, editor)

    editor = %{
      editor
      | dirty?: editor.params != editor.initial,
        form: editor_form(socket, editor.params, :validate)
    }

    socket = put_editor(socket, editor)

    # The map answers the draft's two endpoints. A change to anything else — the
    # scope, a route, the minimum time — redraws the same connection, and a fit on
    # every keystroke would fight the operator's own view of the map.
    if draft_endpoints(editor) == endpoints do
      socket
    else
      show_draft_map(socket, editor)
    end
  end

  defp draft_endpoints(editor) do
    {editor.params["from_stop_id"], editor.params["to_stop_id"]}
  end

  defp clear_dependents(editor, "from_stop_id"),
    do: clear_params(editor, ~w(from_route_id from_trip_id))

  defp clear_dependents(editor, "from_route_id"), do: clear_params(editor, ~w(from_trip_id))

  defp clear_dependents(editor, "to_stop_id"),
    do: clear_params(editor, ~w(to_route_id to_trip_id))

  defp clear_dependents(editor, "to_route_id"), do: clear_params(editor, ~w(to_trip_id))

  # A new scope is a different question about the connection, and its selectors
  # were answered for the old one: all four are dropped, so a route chosen under
  # "a route pair" never reappears as the narrower scope's answer.
  defp clear_dependents(editor, "scope"),
    do: clear_params(editor, ~w(from_route_id to_route_id from_trip_id to_trip_id))

  defp clear_dependents(editor, _target), do: editor

  defp clear_params(editor, keys) do
    %{editor | params: Enum.reduce(keys, editor.params, &Map.put(&2, &1, nil))}
  end

  defp refresh_stop(socket, editor, "from_stop_id"),
    do: %{editor | from_stop: load_stop(socket, editor.params["from_stop_id"])}

  defp refresh_stop(socket, editor, "to_stop_id"),
    do: %{editor | to_stop: load_stop(socket, editor.params["to_stop_id"])}

  defp refresh_stop(_socket, editor, _target), do: editor

  # The chosen stop resolves through the page's own version (R10), so a foreign or
  # unreachable id leaves the draft without a stop and the save refuses it with the
  # server's own field error instead of a hint built from another version's stop.
  defp load_stop(socket, stop_id) do
    case Values.presence(stop_id) do
      nil ->
        nil

      stop_id ->
        case Gtfs.fetch_transfer_stop(organization_id(socket), version_id(socket), stop_id) do
          {:ok, stop} -> stop
          :error -> nil
        end
    end
  end

  # The options the current scope renders, rebuilt from the draft: route options
  # follow that side's stop and trip options that side's route and stop. A scope
  # that renders no selectors keeps none, so a narrowed scope cannot save a
  # selector it no longer shows.
  defp refresh_options(_socket, %{scope: :stops} = editor),
    do: %{editor | options: empty_options()}

  defp refresh_options(socket, editor) do
    options = %{
      from_routes: draft_route_options(socket, editor, :from),
      to_routes: draft_route_options(socket, editor, :to),
      from_trips: draft_trip_options(socket, editor, :from),
      to_trips: draft_trip_options(socket, editor, :to)
    }

    %{editor | options: options}
  end

  defp draft_route_options(socket, editor, side) do
    Gtfs.transfer_route_options(
      organization_id(socket),
      version_id(socket),
      draft_param(editor, "#{side}_stop_id"),
      draft_param(editor, "#{side}_route_id")
    )
  end

  defp draft_trip_options(socket, editor, side) do
    Gtfs.transfer_trip_options(
      organization_id(socket),
      version_id(socket),
      draft_param(editor, "#{side}_route_id"),
      draft_param(editor, "#{side}_stop_id"),
      side,
      draft_param(editor, "#{side}_trip_id")
    )
  end

  # The stop search a LiveSelect asks for. Only the editor's own two searches are
  # answered, each from this version's selectable stops (R2), so the widget's list
  # holds nothing the page could not store.
  defp search_stops(socket, params) do
    with %{editor: %{mode: mode}, view: :general} when mode in [:create, :edit] <-
           socket.assigns,
         id when is_binary(id) <- Map.get(params, "id"),
         true <- Map.has_key?(@stop_component_sides, id),
         text when is_binary(text) <- Map.get(params, "text") do
      %{stops: stops} =
        Gtfs.search_transfer_stops(organization_id(socket), version_id(socket), text)

      send_update(LiveSelectComponent,
        id: id,
        options:
          Enum.map(stops, &%{label: stop_label(&1), value: &1.stop_id, hint: stop_hint(&1)})
      )

      socket
    else
      _other -> socket
    end
  end

  defp submit_draft(socket, params) do
    case socket.assigns.editor do
      nil -> socket
      editor -> apply_submission(socket, editor, params)
    end
  end

  # A save submits the whole form and a retry re-submits what the draft holds. The
  # draft takes the submitted fields under the scope's own rule, and the changeset
  # reads the submission as it arrived, so a crafted tenant or type value is
  # refused or ignored by `Transfer.editor_changeset/2` rather than by a second
  # check here (CR-1).
  defp apply_submission(socket, editor, params) do
    scope = parse_scope(Map.get(params, "scope"), editor.scope)
    values = submitted_values(params)

    draft =
      editor.params
      |> Map.merge(Map.take(values, @editor_params))
      |> strip_selectors(scope)

    submitted = Map.merge(draft, Map.drop(values, @editor_params))
    editor = %{editor | scope: scope, params: draft, dirty?: draft != editor.initial}

    case route_pair_errors(draft, scope) do
      [] -> save_rule(socket, editor, submitted)
      errors -> refuse_route_pair(socket, editor, submitted, errors)
    end
  end

  defp save_rule(socket, %{mode: :edit} = editor, submitted),
    do: update_rule(socket, editor, submitted)

  defp save_rule(socket, editor, submitted), do: create_rule(socket, editor, submitted)

  defp create_rule(socket, editor, submitted) do
    case Gtfs.create_general_transfer(submitted, AuditContext.from_assigns(socket.assigns)) do
      {:ok, transfer} ->
        saved(socket, transfer)

      {:error, %Ecto.Changeset{} = changeset} ->
        refused(socket, editor, changeset)

      {:error, {:duplicate, collision}} ->
        put_editor(socket, %{editor | error: {:duplicate, collision}})

      {:error, :forbidden} ->
        put_editor(socket, %{editor | error: :forbidden})

      # A create has no stored row to be stale or missing, so every refusal that is
      # not a field error, duplicate or permission refusal is the server's generic
      # failure: the draft stays and the operator can retry.
      {:error, _reason} ->
        put_editor(socket, %{editor | error: :busy})
    end
  end

  # An edit writes the row the editor opened with, carrying the `updated_at` that
  # row had then, so a rule that changed in the meantime is refused instead of
  # overwritten (R8).
  defp update_rule(socket, editor, submitted) do
    case Gtfs.update_general_transfer(
           editor.row.id,
           submitted,
           editor.row.transfer.updated_at,
           AuditContext.from_assigns(socket.assigns)
         ) do
      {:ok, transfer} ->
        saved(socket, transfer)

      {:error, %Ecto.Changeset{} = changeset} ->
        refused(socket, editor, changeset)

      {:error, {:duplicate, collision}} ->
        put_editor(socket, %{editor | error: {:duplicate, collision}})

      {:error, :forbidden} ->
        put_editor(socket, %{editor | error: :forbidden})

      # The row moved on while the editor was open: the draft is kept, because the
      # operator's entries are not what is wrong, and the reload path leads to the
      # stored values.
      {:error, :stale} ->
        put_editor(socket, %{editor | error: :stale})

      {:error, :not_found} ->
        rule_gone(socket)

      {:error, _reason} ->
        put_editor(socket, %{editor | error: :busy})
    end
  end

  defp saved(socket, transfer) do
    socket
    |> end_pick()
    |> assign(:editor, nil)
    |> put_flash(:info, "Transfer rule saved in #{socket.assigns.current_gtfs_version.name}.")
    |> push_patch(to: list_path(socket, rule: transfer.id))
  end

  defp refused(socket, editor, changeset) do
    socket
    |> put_editor(%{editor | form: form_for(changeset, :insert), error: nil})
    |> push_event("focus_form_error", %{form_id: "transfer-form"})
  end

  # A rule another writer deleted while the editor was open: the draft has nothing
  # left to write, so the editor closes and the list loads again without it.
  defp rule_gone(socket) do
    socket
    |> end_pick()
    |> assign(:editor, nil)
    |> put_flash(:info, "This rule is no longer in this version.")
    |> push_patch(to: list_path(socket, rule: nil))
  end

  # "A route pair at selected stops" is a requirement of the scope rather than of a
  # field, and the server has nothing to refuse yet, so the pair is checked here and
  # the message lands on the select that is missing.
  defp refuse_route_pair(socket, editor, submitted, errors) do
    changeset =
      Enum.reduce(errors, Transfer.editor_changeset(editor_base(socket), submitted), fn
        {field, message}, changeset -> Ecto.Changeset.add_error(changeset, field, message)
      end)

    socket
    |> put_editor(%{editor | form: form_for(changeset, :insert), error: nil})
    |> push_event("focus_form_error", %{form_id: "transfer-form"})
  end

  defp route_pair_errors(_params, scope) when scope != :routes, do: []

  defp route_pair_errors(params, :routes) do
    []
    |> put_route_error(:from_route_id, params["from_route_id"], "Choose an arriving route")
    |> put_route_error(:to_route_id, params["to_route_id"], "Choose a departing route")
  end

  defp put_route_error(errors, field, value, message) do
    case Values.presence(value) do
      nil -> errors ++ [{field, message}]
      _value -> errors
    end
  end

  defp strip_selectors(params, scope) do
    Enum.reduce(Map.fetch!(@selector_params, scope), params, &Map.put(&2, &1, nil))
  end

  defp parse_scope(value, current) do
    case value do
      scope when is_binary(scope) -> Map.get(@scopes, scope, current)
      _value -> current
    end
  end

  defp submitted_values(%{"transfer" => %{} = values}), do: values
  defp submitted_values(_params), do: %{}

  # The scope select is the one control outside the form's own namespace, so its
  # change arrives as the whole form with `["scope"]` as the target.
  defp editor_target(params) do
    case Map.get(params, "_target") do
      [field] when is_binary(field) -> field
      [_form, field] when is_binary(field) -> field
      _target -> nil
    end
  end

  # A draft value the facade queries may read: anything that is not a string is not
  # a stop, route or trip id this page could have chosen.
  defp draft_param(editor, key) do
    case editor.params[key] do
      value when is_binary(value) -> Values.presence(value)
      _value -> nil
    end
  end

  # The editor replaces the general view's list pane in both modes. It is a
  # general-view surface, so a draft still open when the page patches to the other
  # view waits behind the general chip instead of rendering over the in-seat rows.
  defp editor_open?(nil, _view), do: false
  defp editor_open?(_editor, :general), do: true
  defp editor_open?(_editor, _view), do: false

  defp list_mode?(nil, _view), do: true
  defp list_mode?(_editor, :general), do: false
  defp list_mode?(_editor, _view), do: true

  # Where a type 4/5 collision points (R1): the bare in-seat list of this version.
  defp in_seat_path(socket) do
    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/transfers?view=in_seat"
  end

  defp organization_id(socket), do: socket.assigns.current_organization.id
  defp version_id(socket), do: socket.assigns.current_gtfs_version.id

  defp put_editor(socket, editor), do: assign(socket, :editor, editor)

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
      <:sub_header>
        <.routes_tabs gtfs_version_id={@current_gtfs_version.id} active_tab={:transfers} />
      </:sub_header>

      <div id="transfers-page" class="ds-page">
        <.header>
          Transfers
          <:subtitle>
            Rules that tell trip planners where riders can change routes, how much time they need, and where a connection won’t work.
          </:subtitle>
          <%!--
          Two independent calls to action: the helper, offered wherever the general workspace is, and the
          create action, which the first-use panel carries instead while a version has no rules. --%>
          <:actions :if={create_action?(assigns) or helper_action?(assigns)}>
            <.button
              :if={helper_action?(assigns)}
              id="agent-helper-open"
              type="button"
              phx-click="agent_open"
              aria-expanded={to_string(@agent_open?)}
              aria-controls="agent-panel"
              variant="quiet"
              class="min-h-11"
            >
              Open helper
            </.button>
            <.button
              :if={create_action?(assigns)}
              id="transfers-create"
              type="button"
              class="min-h-11"
              phx-click="open_create"
            >
              <.icon name="hero-plus" class="size-4" /> Create transfer rule
            </.button>
          </:actions>
        </.header>

        <%!--
        The panel's focus listener belongs to this persistent element, not to the panel: the
        closing panel cannot own a handler that runs after its own removal. It owns no other DOM,
        so the patch cycle ignores it. --%>
        <div id="transfer-helper-focus" phx-hook=".TransferHelperFocus" phx-update="ignore"></div>

        <%!--
        What a reviewed proposal did stays on the page once its drawer closes; while the drawer is open
        the same status and counts render inside it, so each id exists once. --%>
        <section
          :if={not @policy_open? and policy_outcome?(@policy_status, @policy_counts)}
          id="transfer-policy-outcome"
          aria-label="Helper proposal outcome"
          class="mt-4 rounded-lg border border-subtle p-3"
        >
          <.policy_outcome status={@policy_status} counts={@policy_counts} />
        </section>

        <%!--
        The grid gives the workspace the full width while the panel is closed and a fixed 24rem
        column while it is open, and the workspace column is hidden at phone width so the panel
        replaces the list. --%>
        <div class={["lg:grid lg:gap-6", @agent_open? && "lg:grid-cols-[minmax(0,1fr)_24rem]"]}>
          <div class={@agent_open? && "hidden lg:block"}>
            <.workspace detail={workspace_detail(assigns)} class="mt-6">
              <:list>
                <.load_failure
                  :if={@catalog_state == :unavailable}
                  version_name={@current_gtfs_version.name}
                />
                <div :if={@catalog_state == :ready}>
                  <.editor
                    :if={editor_open?(@editor, @view)}
                    editor={@editor}
                    version_name={@current_gtfs_version.name}
                    in_seat_path={@in_seat_path}
                  />
                  <div :if={list_mode?(@editor, @view)}>
                    <.view_chips view={@view} counts={@catalog.counts} />
                    <.first_use :if={first_use?(@catalog, @view)}>
                      <:action>
                        <.button
                          id="transfers-first-use-create"
                          type="button"
                          class="min-h-11"
                          phx-click="open_create"
                        >
                          <.icon name="hero-plus" class="size-4" /> Create transfer rule
                        </.button>
                      </:action>
                    </.first_use>
                    <div :if={list?(@catalog, @view)}>
                      <.list_toolbar
                        search_form={@search_form}
                        filter_form={@filter_form}
                        filter_options={@catalog.filter_options}
                        filter_count={filter_count(@filters)}
                        filters_open?={@filters_open?}
                      />
                      <.rule_count
                        total_count={@total_count}
                        all_count={view_count(@catalog, @view)}
                        in_seat?={@view == :in_seat}
                        chips={filter_chips(@filters, @catalog.filter_options)}
                        attention?={@filters.attention}
                        checked_count={checked_count(@checked)}
                      />
                      <.no_results
                        :if={@total_count == 0}
                        all_count={view_count(@catalog, @view)}
                        in_seat?={@view == :in_seat}
                      />
                      <.rules_table
                        :if={@total_count > 0}
                        rows={@streams.transfers}
                        selected_id={@selected_id}
                        sort_by={@sort_by}
                        sort_dir={@sort_dir}
                        page={@page}
                        per_page={@per_page}
                        total_count={@total_count}
                        in_seat?={@view == :in_seat}
                        checked={@checked}
                        all_checked?={all_shown_checked?(@page_ids, @checked)}
                      />
                    </div>
                    <.in_seat_empty :if={in_seat_empty?(@catalog, @view)} />
                  </div>
                </div>
              </:list>
              <:context :if={@catalog_state == :ready}>
                <.back_to_list :if={not editor_open?(@editor, @view) and @selected} path={@back_path} />
                <.map_region
                  :if={editor_open?(@editor, @view) or not is_nil(@selected)}
                  editor_open?={editor_open?(@editor, @view)}
                  pick={@pick}
                  map_state={@map_state}
                  generation={@map_generation}
                  extent={@map_extent}
                  missing={@map_missing}
                />
                <.draft_preview :if={editor_open?(@editor, @view)} editor={@editor} />
                <.inspector
                  :if={not editor_open?(@editor, @view) and @selected}
                  row={@selected}
                  competitors={@competitors}
                  version_id={@current_gtfs_version.id}
                  in_seat?={@view == :in_seat}
                />
                <.context_empty
                  :if={not editor_open?(@editor, @view) and is_nil(@selected)}
                  none?={not list?(@catalog, @view)}
                  in_seat?={@view == :in_seat}
                />
              </:context>
            </.workspace>

            <.compare_dialog
              :if={@catalog_state == :ready and not editor_open?(@editor, @view) and @compare_open?}
              row={@selected}
              competitors={@competitors}
            />
            <.delete_dialog
              :if={@delete_dialog}
              dialog={@delete_dialog}
              version_name={@current_gtfs_version.name}
            />
            <.discard_dialog open={not is_nil(@pending_discard)} mode={@editor && @editor.mode} />
          </div>

          <div
            :if={@agent_open?}
            class="flex min-w-0 lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)]"
          >
            <.agent_panel
              id="agent-panel"
              title={@agent_title}
              intro={@agent_intro}
              examples={@agent_examples}
              scope_line={"Transfers · " <> @current_gtfs_version.name}
              status={@agent_status}
              entries={@streams.agent_entries}
              form={@agent_form}
              notice={@agent_notice}
              entries_empty?={@agent_entries_empty?}
              review_label={&agent_review_label/1}
            />
          </div>
        </div>

        <.drawer
          :if={@policy_open?}
          id="transfer-policy-drawer"
          chrome="planner"
          open={@policy_open?}
          pending={@policy_pending?}
          on_close="transfer_policy_close"
          title="Review prepared transfer rule"
          initial_focus={:heading}
          return_focus_id={@policy_return_focus}
          class="max-w-[560px]"
        >
          <:lede>The helper proposed this. Nothing is saved until you confirm.</:lede>
          <.drawer_scroll>
            <p
              :if={@policy_notice}
              id="transfer-policy-notice"
              role="status"
              class="text-[13px] text-muted"
            >
              {@policy_notice}
            </p>
            <.policy_outcome status={@policy_status} counts={@policy_counts} />
            <.policy_review_body :if={@policy_review} review={@policy_review} />
          </.drawer_scroll>
          <.drawer_footer>
            <.button
              id="transfer-policy-refresh"
              type="button"
              phx-click="transfer_policy_review"
              variant="quiet"
            >
              Re-read rules
            </.button>
            <.button
              id="transfer-policy-skip"
              type="button"
              phx-click="transfer_policy_skip"
              variant="secondary"
              disabled={@policy_pending?}
            >
              Skip
            </.button>
            <.button
              id="transfer-policy-confirm"
              type="button"
              phx-click="transfer_policy_apply"
              disabled={@policy_pending? or is_nil(@policy_review)}
            >
              {if @policy_pending?, do: "Applying…", else: "Apply reviewed change"}
            </.button>
          </.drawer_footer>
        </.drawer>

        <.transfer_policy_source
          :if={editor_open?(@editor, @view)}
          selections={@policy_selections}
          notice={@policy_notice}
        />
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TransferHelperFocus">
        export default {
          mounted() {
            this.handleEvent("agent:focus", ({id}) => document.getElementById(id)?.focus())
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # The helper is offered wherever the general workspace is, which is the only
  # place a transfer-policy draft exists to admit. An unavailable catalog has no
  # rules to read, and the in-seat list is a different policy with no draft here.
  defp helper_action?(assigns),
    do: assigns.catalog_state == :ready and assigns.view == :general

  # The panel's action label is named for this page's one prepared command kind, so
  # a button label never promises another page's review (INV-1).
  defp agent_review_label(_prepared), do: "Review prepared transfer rule"

  # The header's one primary is the create action, except where the first-use panel
  # carries it: a version without rules has nothing to compare, so the panel is the
  # page's one call to action.
  defp create_action?(assigns) do
    assigns.catalog_state == :ready and assigns.view == :general and
      is_nil(assigns.editor) and not first_use?(assigns.catalog, assigns.view)
  end

  # Which pane has the screen below 1024px: the rule the URL names, or the list.
  # The editor shows its form over its preview, except while a pick asks for a stop
  # on the map, when the map has the screen.
  defp workspace_detail(%{catalog_state: :unavailable}), do: "none"

  defp workspace_detail(%{editor: editor, view: view, pick: pick} = assigns) do
    cond do
      editor_open?(editor, view) -> if(pick, do: "open", else: "both")
      not is_nil(assigns.rule) and not is_nil(assigns.selected) -> "open"
      true -> "closed"
    end
  end

  # How many rows the view holds before any filter: the whole of what the chip
  # counts, so the count row can say "5 of 13".
  defp view_count(%{counts: counts}, :general), do: counts.general
  defp view_count(%{counts: counts}, :in_seat), do: counts.in_seat

  # A load runs the catalog for the requested params and then canonicalizes: the
  # socket keeps what the list actually shows, and the URL follows it in one
  # patch when a requested param was dropped, clamped or resolved differently.
  defp load_catalog(socket, url_params) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    view = parse_view(url_params["view"])
    filters = parse_filters(url_params, view)
    sort_by = Map.get(@sort_keys, url_params["sort_by"]) || :from
    sort_dir = Map.get(@sort_dirs, url_params["sort_dir"]) || :asc
    page = Values.positive_integer(url_params["page"], 1)
    rule = parse_rule(url_params["rule"])

    opts = [
      view: view,
      search: filters.q,
      stop: filters.stop,
      route: filters.route,
      type: filters.type,
      attention: filters.attention,
      sort_by: sort_by,
      sort_dir: sort_dir,
      page: page,
      rule: rule
    ]

    case Gtfs.load_transfer_catalog(organization_id, gtfs_version_id, opts) do
      {:ok, catalog} ->
        previous_selected_id = socket.assigns.selected_id
        selection = catalog.selected

        socket =
          socket
          |> assign_filters(filters)
          |> assign(:sort_by, sort_by)
          |> assign(:sort_dir, sort_dir)
          |> assign(:page, catalog.page)
          |> assign(:per_page, catalog.per_page)
          |> assign(:total_count, catalog.total_count)
          |> assign(:selected_id, selection && selection.id)
          |> assign(:selected, selection)
          |> assign(:competitors, catalog.competitors)
          |> assign(:compare_open?, false)
          |> assign(:rule, canonical_rule(rule, selection))
          |> assign(:catalog, catalog)
          |> assign(:view, view)
          |> assign(:catalog_state, :ready)
          |> stream_rows(catalog, previous_selected_id)
          |> show_loaded_map(selection)

        # Below 1024px an open rule has a way back to the same list without it.
        socket = assign(socket, :back_path, list_path(socket, rule: nil))

        if canonical_params(socket.assigns) == url_params do
          {:noreply, socket}
        else
          {:noreply, push_patch(socket, to: list_path(socket, []))}
        end

      {:error, :unavailable} ->
        {:noreply,
         socket
         |> assign_filters(filters)
         |> assign(:sort_by, sort_by)
         |> assign(:sort_dir, sort_dir)
         |> assign(:view, view)
         |> assign(:catalog, nil)
         |> assign(:catalog_state, :unavailable)
         |> assign(:selected_id, nil)
         |> assign(:selected, nil)
         |> assign(:competitors, [])
         |> assign(:compare_open?, false)
         |> assign(:page_rows, %{})
         |> assign(:page_ids, nil)
         |> stream(:transfers, [], reset: true)}
    end
  end

  # The stream is replaced whenever the page's rows or their order changed. When
  # the same rows come back in the same order, only the selection can have
  # changed, so only the row that lost its highlight and the row that gained one
  # are re-streamed.
  defp stream_rows(socket, catalog, previous_selected_id) do
    rows = catalog.rows
    ids = Enum.map(rows, & &1.id)
    row_map = Map.new(rows, &{&1.id, &1})

    socket =
      if is_list(socket.assigns.page_ids) and ids == socket.assigns.page_ids and
           row_map == socket.assigns.page_rows do
        restream_selection(socket, row_map, previous_selected_id, socket.assigns.selected_id)
      else
        stream(socket, :transfers, rows, reset: true)
      end

    socket
    |> assign(:page_ids, ids)
    |> assign(:page_rows, row_map)
  end

  defp restream_selection(socket, row_map, previous_selected_id, selected_id) do
    [previous_selected_id, selected_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(socket, fn id, socket ->
      case Map.fetch(row_map, id) do
        {:ok, row} -> stream_insert(socket, :transfers, row)
        :error -> socket
      end
    end)
  end

  defp next_sort_dir(socket, sort_by) do
    if socket.assigns.sort_by == sort_by and socket.assigns.sort_dir == :asc,
      do: :desc,
      else: :asc
  end

  # A rule survives canonicalization only when the catalog selected the row it
  # names; a rule outside the current list is dropped so the URL and the list
  # agree.
  defp canonical_rule(nil, _selection), do: nil
  defp canonical_rule(rule, %{id: id}) when id == rule, do: rule
  defp canonical_rule(_rule, _selection), do: nil

  # The mirror the catalog resolved inside this view, or nil when the selected
  # rule has none. A control that is only rendered with a mirror still guards
  # against a stale payload.
  defp reverse_rule(%{assigns: %{selected: %{reverse_id: reverse_id}}}), do: reverse_id
  defp reverse_rule(_socket), do: nil

  # The mirror has to be in the list the page shows, so its selection drops the
  # filters and returns to the first page with the rule named; the sort and the
  # direction are the operator's, not the filter's.
  defp reverse_path(socket, reverse_id) do
    list_path(socket, filters: @empty_filters, page: 1, rule: reverse_id)
  end

  defp canonical_params(assigns) do
    assigns
    |> list_params([])
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp list_path(socket, overrides) do
    version_id = socket.assigns.current_gtfs_version.id
    ~p"/gtfs/#{version_id}/transfers?#{list_params(socket.assigns, overrides)}"
  end

  # "Clear filters" returns the current view's bare list: the default sort, the
  # first page and no selected rule, exactly as the unfiltered URL reads.
  defp clear_overrides do
    [filters: @empty_filters, sort_by: :from, sort_dir: :asc, page: 1, rule: nil]
  end

  defp list_params(assigns, overrides) do
    view = Keyword.get(overrides, :view, assigns.view)
    filters = Keyword.get(overrides, :filters, assigns.filters)
    sort_by = Keyword.get(overrides, :sort_by, assigns.sort_by)
    sort_dir = Keyword.get(overrides, :sort_dir, assigns.sort_dir)
    page = Keyword.get(overrides, :page, assigns.page)
    rule = Keyword.get(overrides, :rule, assigns.rule)

    []
    |> view_params(view)
    |> filter_params(filters)
    |> sort_params(sort_by, sort_dir)
    |> page_params(page)
    |> rule_params(rule)
  end

  # The general view is the page's plain list, so only the in-seat view names
  # itself in the URL; an unknown view value canonicalizes back to the plain list.
  defp view_params(params, :in_seat), do: params ++ [view: "in_seat"]
  defp view_params(params, _view), do: params

  # The filters the URL carries, in the page contract's order. `attention` is
  # written as its own flag rather than the form's "true", so the parsed value and
  # the canonical URL are comparable as strings.
  defp filter_params(params, filters) do
    params
    |> put_param(:q, filters.q)
    |> put_param(:stop, filters.stop)
    |> put_param(:route, filters.route)
    |> put_param(:type, filters.type)
    |> put_param(:attention, attention_param(filters.attention))
  end

  # A false attention flag is an absent param, not the string "false": the flag is
  # written only when the checkbox is on.
  defp attention_param(true), do: 1
  defp attention_param(_attention), do: nil

  # An ordered keyword list, not a map: this stays local, not Values.put_present/3.
  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: params ++ [{key, value}]

  # The default sort is omitted, so a plain list keeps a clean URL and only a
  # deliberate sort, page or selection names its param.
  defp sort_params(params, :from, :asc), do: params

  defp sort_params(params, sort_by, sort_dir),
    do: params ++ [sort_by: sort_by, sort_dir: sort_dir]

  defp page_params(params, page) when page > 1, do: params ++ [page: page]
  defp page_params(params, _page), do: params

  defp rule_params(params, nil), do: params
  defp rule_params(params, rule), do: params ++ [rule: rule]

  defp parse_rule(value) do
    case Ecto.UUID.cast(value) do
      {:ok, rule} -> rule
      :error -> nil
    end
  end

  # The filters arrive as untrusted URL params or form values. A blank or absent
  # value means "no filter"; a repeated param (a list) is not a value at all, so
  # every parser has a catch-all and nothing reaches the catalog unvalidated.
  defp parse_view("in_seat"), do: :in_seat
  defp parse_view(_value), do: :general

  defp parse_filters(url_params, view) do
    %{
      q: Values.presence(Map.get(url_params, "q")),
      stop: Values.presence(Map.get(url_params, "stop")),
      route: Values.presence(Map.get(url_params, "route")),
      type: parse_type(Map.get(url_params, "type"), view),
      attention: view == :general and Map.get(url_params, "attention") == "1"
    }
  end

  # The filter form owns the three selects; the search term is the other form's,
  # and Needs attention is a toggle of its own, so both survive a select change.
  defp merge_filters(filters, params, view) do
    %{
      filters
      | stop: Values.presence(Map.get(params, "stop")),
        route: Values.presence(Map.get(params, "route")),
        type: parse_type(Map.get(params, "type"), view)
    }
  end

  defp assign_filters(socket, filters) do
    socket
    |> assign(:filters, filters)
    |> assign(:search_form, to_form(%{"q" => filters.q || ""}))
    |> assign(:filter_form, to_form(filter_form_values(filters)))
  end

  defp filter_form_values(filters) do
    %{
      "stop" => filters.stop || "",
      "route" => filters.route || "",
      "type" => (filters.type && to_string(filters.type)) || ""
    }
  end

  # A type is a filter only inside the range of the view being listed: 4 in the
  # general view is dropped rather than answered with an empty list, and the
  # in-seat view accepts only its own two types.
  defp parse_type(value, view) when is_binary(value) do
    case Integer.parse(value) do
      {type, ""} -> if valid_type?(type, view), do: type, else: nil
      _other -> nil
    end
  end

  defp parse_type(_value, _view), do: nil

  defp valid_type?(type, :in_seat), do: type in @in_seat_types
  defp valid_type?(type, _view), do: type in @general_types

  # How many of the two selects behind More filters apply; search and kind are in
  # the toolbar row, and each applied filter is a chip.
  defp filter_count(filters) do
    Enum.count([filters.stop, filters.route], &(&1 != nil))
  end

  # The applied filters as removable chips, in the toolbar's order: what the
  # search says, the kind, the stop and the route, each named as the operator
  # chose it.
  defp filter_chips(filters, options) do
    [
      filters.q && %{key: "q", label: "“#{filters.q}”"},
      filters.type && %{key: "type", label: type_label(filters.type)},
      filters.stop && %{key: "stop", label: stop_chip_label(filters.stop, options.stops)},
      filters.route && %{key: "route", label: route_chip_label(filters.route, options.routes)}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp stop_chip_label(stop_id, stops) do
    case Enum.find(stops, &(&1.stop_id == stop_id)) do
      %{name: name} when is_binary(name) and name != "" -> name
      _option -> stop_id
    end
  end

  defp route_chip_label(route_id, routes) do
    case Enum.find(routes, &(&1.route_id == route_id)) do
      %{route_short_name: short} when is_binary(short) and short != "" -> "Route #{short}"
      _option -> "Route #{route_id}"
    end
  end

  # The list is the current view's own rows, whether or not a filter hides them
  # (that case renders the filtered-empty state inside the same list).
  defp list?(%{counts: counts}, :general), do: counts.general > 0
  defp list?(%{counts: counts}, :in_seat), do: counts.in_seat > 0

  # First use is a version with no general rules at all, including one whose only
  # rows are in-seat records, whose mutations belong to Blocks.
  defp first_use?(%{counts: %{general: 0}}, :general), do: true
  defp first_use?(_catalog, _view), do: false

  # A version with general rules but no in-seat records says where those records
  # are managed instead of offering a first-use action of its own.
  defp in_seat_empty?(%{counts: %{in_seat: 0}}, :in_seat), do: true
  defp in_seat_empty?(_catalog, _view), do: false

  # --- selection and deletion ------------------------------------------------

  # The count bar's own numbers: how many rules are checked, and whether the whole
  # shown page is. `@checked` only ever names rows of the current page, so the two
  # agree.
  defp checked_count(checked), do: map_size(checked)

  defp all_shown_checked?(ids, checked) when is_list(ids),
    do: ids != [] and Enum.all?(ids, &Map.has_key?(checked, &1))

  defp all_shown_checked?(_ids, _checked), do: false

  defp clear_checked(socket), do: assign(socket, :checked, %{})

  # The checked set is the shown page's own ids mapped to the `updated_at` each
  # row carried when it was checked: that exact pair, never the filter, the
  # search, the sort or the page, is what a deletion may name (R8, CR-5).
  defp selectable?(socket, id) when is_binary(id),
    do: socket.assigns.view == :general and Map.has_key?(socket.assigns.page_rows, id)

  defp selectable?(_socket, _id), do: false

  defp toggle_checked(socket, id) do
    checked =
      if Map.has_key?(socket.assigns.checked, id) do
        Map.delete(socket.assigns.checked, id)
      else
        Map.put(socket.assigns.checked, id, checked_at(socket, id))
      end

    socket
    |> assign(:checked, checked)
    |> restream_row(id)
  end

  # The timestamp a deletion has to match: the one the row carried when it was
  # checked, and the loaded row's own for a row the operator never checked, which
  # is what the inspector's Delete uses.
  defp checked_at(socket, id) do
    Map.get(socket.assigns.checked, id) || row_timestamp(socket, id)
  end

  defp row_timestamp(socket, id) do
    case Map.fetch(socket.assigns.page_rows, id) do
      {:ok, row} -> row.transfer.updated_at
      :error -> nil
    end
  end

  defp toggle_all_shown(%{assigns: %{view: view, page_ids: ids}} = socket)
       when view != :general or ids in [nil, []],
       do: socket

  defp toggle_all_shown(socket) do
    ids = socket.assigns.page_ids

    if all_shown_checked?(ids, socket.assigns.checked) do
      socket
      |> clear_checked()
      |> restream_rows(ids)
    else
      checked = Map.new(ids, &{&1, checked_at(socket, &1)})

      socket
      |> assign(:checked, checked)
      |> restream_rows(ids)
    end
  end

  # The rows a deletion may name, in the order the page shows them, so the dialog
  # lists them the way the table does.
  defp checked_rows(socket) do
    socket.assigns.page_ids
    |> List.wrap()
    |> Enum.filter(&Map.has_key?(socket.assigns.checked, &1))
    |> Enum.map(&Map.fetch!(socket.assigns.page_rows, &1))
  end

  # A streamed row reaches the client again only when it is inserted again, so the
  # rows whose checkbox moved are re-streamed for the new state to render.
  defp restream_row(socket, id) do
    case Map.fetch(socket.assigns.page_rows, id) do
      {:ok, row} -> stream_insert(socket, :transfers, row)
      :error -> socket
    end
  end

  defp restream_rows(socket, ids), do: Enum.reduce(ids, socket, &restream_row(&2, &1))

  # The dialog carries the rows it will delete and the exact pairs those rows had
  # when they were checked, so a confirm sends what the operator saw; an empty
  # selection opens nothing at all.
  defp open_delete_dialog(socket, [], _return_focus_id), do: assign(socket, :delete_dialog, nil)

  defp open_delete_dialog(socket, rows, return_focus_id) do
    pairs = Enum.map(rows, &{&1.id, checked_at(socket, &1.id)})

    assign(socket, :delete_dialog, %{
      rows: rows,
      pairs: pairs,
      error: nil,
      return_focus_id: return_focus_id
    })
  end

  # A confirmed deletion sends the captured pairs. Success clears the selection,
  # closes the dialog and reloads the list without a selected rule; a refusal
  # keeps the dialog open with its reason, because the rows the click captured no
  # longer match what a confirm would delete (R8). Nothing is deleted
  # optimistically and no id and no timestamp come from the client.
  defp apply_delete(%{assigns: %{delete_dialog: nil}} = socket), do: socket

  defp apply_delete(socket) do
    dialog = socket.assigns.delete_dialog

    case delete_rows(dialog.pairs, AuditContext.from_assigns(socket.assigns)) do
      {:ok, count} ->
        socket
        |> clear_checked()
        |> assign(:delete_dialog, nil)
        |> put_flash(:info, deleted_message(count))
        |> push_patch(to: list_path(socket, rule: nil))

      {:error, reason} ->
        assign(socket, :delete_dialog, %{dialog | error: delete_error(reason)})
    end
  end

  # One pair goes through the single-rule facade and several through the batch
  # one; both answer how many rules they deleted.
  defp delete_rows([{id, updated_at}], audit) do
    case Gtfs.delete_general_transfer(id, updated_at, audit) do
      {:ok, _rule} -> {:ok, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_rows(pairs, audit), do: Gtfs.delete_general_transfers(pairs, audit)

  defp deleted_message(1), do: "1 transfer rule deleted."
  defp deleted_message(count), do: "#{count} transfer rules deleted."

  # The refusals the delete facades document; anything else is a server failure
  # the operator can retry.
  defp delete_error(:stale), do: :stale
  defp delete_error(:not_found), do: :not_found
  defp delete_error(:forbidden), do: :forbidden
  defp delete_error(_reason), do: :busy

  defp transfers_target(version_id), do: ~p"/gtfs/#{version_id}/transfers"
end
