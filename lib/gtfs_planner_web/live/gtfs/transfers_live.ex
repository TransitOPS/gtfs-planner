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
  type filters and the Needs attention checkbox each patch the list and drop the
  page and the selected rule, and a filtered list that hides every rule shows its
  own empty state rather than first use. The connection map arrives with its own
  step.

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

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Versions
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
  # component it came from, which is the only place a side is decided.
  @stop_component_sides %{"transfer-from-stop" => :from, "transfer-to-stop" => :to}

  @empty_filters %{q: nil, stop: nil, route: nil, type: nil, attention: false}

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
     |> assign(:open_editor_for, nil)
     |> assign_filters(@empty_filters)
     |> stream(:transfers, [])}
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
     push_patch(clear_checked(socket), to: list_path(socket, page: parse_page(page), rule: nil))}
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
    filters = %{socket.assigns.filters | q: parse_string(Map.get(params, "q"))}

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
      {:noreply, assign(socket, :editor, new_editor(socket))}
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
        {:noreply, assign(socket, :editor, reverse_editor(socket, row))}

      _other ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_existing", params, socket) do
    id = Map.get(params, "id")

    case socket.assigns.editor do
      %{error: {:duplicate, %{id: ^id}}} -> open_rule(socket, id)
      _editor -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("compare_edit", params, socket) do
    id = Map.get(params, "id")

    if socket.assigns.compare_open? and known_rule_id?(socket, id) do
      open_rule(socket, id)
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

  @impl true
  def handle_event("save", params, socket), do: {:noreply, submit_draft(socket, params)}

  @impl true
  def handle_event("retry_save", params, socket), do: {:noreply, submit_draft(socket, params)}

  @impl true
  def handle_event("cancel_editor", _params, socket) do
    {:noreply, assign(socket, :editor, nil)}
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: transfers_target(version_id))}
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

  defp draft_present?(params, key), do: parse_string(Map.get(params, key)) != nil

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
      lon: nil
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

    put_editor(socket, %{
      editor
      | dirty?: editor.params != editor.initial,
        form: editor_form(socket, editor.params, :validate)
    })
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
    case parse_string(stop_id) do
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
        options: Enum.map(stops, &%{label: stop_label(&1), value: &1.stop_id})
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
    case Gtfs.create_general_transfer(submitted, audit_context(socket)) do
      {:ok, transfer} ->
        saved(socket, transfer)

      {:error, %Ecto.Changeset{} = changeset} ->
        refused(socket, editor, changeset)

      {:error, {:duplicate, collision}} ->
        put_editor(socket, %{editor | error: {:duplicate, collision}})

      # A create has no stored row to be stale or missing, so every refusal that is
      # not a field error or a duplicate is the server's generic failure: the draft
      # stays and the operator can retry.
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
           audit_context(socket)
         ) do
      {:ok, transfer} ->
        saved(socket, transfer)

      {:error, %Ecto.Changeset{} = changeset} ->
        refused(socket, editor, changeset)

      {:error, {:duplicate, collision}} ->
        put_editor(socket, %{editor | error: {:duplicate, collision}})

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
    |> assign(:editor, nil)
    |> put_flash(:info, "Transfer saved in #{socket.assigns.current_gtfs_version.name}.")
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
    case parse_string(value) do
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
      value when is_binary(value) -> parse_string(value)
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

  # The audit context every write is attributed to, as the calendar and schedule
  # pages build it.
  defp audit_context(socket) do
    %AuditContext{
      organization_id: organization_id(socket),
      gtfs_version_id: version_id(socket),
      station_stop_id: nil,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
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
      <:sub_header>
        <.routes_tabs gtfs_version_id={@current_gtfs_version.id} active_tab={:transfers} />
      </:sub_header>

      <div id="transfers-page">
        <.header>
          Transfers
          <:subtitle>Help riders make the right connection.</:subtitle>
          <:actions :if={@catalog_state == :ready and @view == :general and is_nil(@editor)}>
            <.button id="transfers-create" type="button" class="min-h-11" phx-click="open_create">
              Create transfer
            </.button>
          </:actions>
        </.header>

        <.workspace>
          <:list>
            <.load_failure :if={@catalog_state == :unavailable} />
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
                      variant="secondary"
                      size="sm"
                      class="min-h-11"
                      phx-click="open_create"
                    >
                      Create transfer
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
                    in_seat?={@view == :in_seat}
                  />
                  <.rule_count
                    total_count={@total_count}
                    checked_count={checked_count(@checked)}
                    all_checked?={all_shown_checked?(@page_ids, @checked)}
                    in_seat?={@view == :in_seat}
                  />
                  <.no_results :if={@total_count == 0} />
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
                  />
                </div>
                <.in_seat_empty :if={in_seat_empty?(@catalog, @view)} />
              </div>
            </div>
          </:list>
          <:context>
            <.draft_preview :if={editor_open?(@editor, @view)} editor={@editor} />
            <.inspector
              :if={not editor_open?(@editor, @view) and @selected}
              row={@selected}
              competitors={@competitors}
              compare_open?={@compare_open?}
              version_id={@current_gtfs_version.id}
              in_seat?={@view == :in_seat}
            />
            <.context_empty :if={not editor_open?(@editor, @view) and is_nil(@selected)} />
            <.compare_dialog
              :if={not editor_open?(@editor, @view) and @compare_open?}
              row={@selected}
              competitors={@competitors}
            />
            <.delete_dialog
              :if={@delete_dialog}
              dialog={@delete_dialog}
              version_name={@current_gtfs_version.name}
            />
          </:context>
        </.workspace>
      </div>
    </Layouts.app>
    """
  end

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
    page = parse_page(url_params["page"])
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

  defp parse_page(nil), do: 1

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _other -> 1
    end
  end

  defp parse_page(_value), do: 1

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
      q: parse_string(Map.get(url_params, "q")),
      stop: parse_string(Map.get(url_params, "stop")),
      route: parse_string(Map.get(url_params, "route")),
      type: parse_type(Map.get(url_params, "type"), view),
      attention: view == :general and Map.get(url_params, "attention") == "1"
    }
  end

  # The filter form owns the three selects and the checkbox; the search term is
  # the other form's, and survives a filter change.
  defp merge_filters(filters, params, view) do
    %{
      filters
      | stop: parse_string(Map.get(params, "stop")),
        route: parse_string(Map.get(params, "route")),
        type: parse_type(Map.get(params, "type"), view),
        attention: view == :general and parse_checkbox(Map.get(params, "attention"))
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
      "type" => (filters.type && to_string(filters.type)) || "",
      "attention" => to_string(filters.attention)
    }
  end

  defp parse_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_string(_value), do: nil

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

  # `<.input type="checkbox">` renders a hidden "false" beside the checked
  # "true", so one form change arrives as both values for the one name; the box
  # is on only when a "true" is among them.
  defp parse_checkbox("true"), do: true
  defp parse_checkbox(values) when is_list(values), do: "true" in values
  defp parse_checkbox(_value), do: false

  defp filter_count(filters) do
    Enum.count([filters.stop, filters.route, filters.type], &(&1 != nil))
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

    case delete_rows(dialog.pairs, delete_audit_context(socket)) do
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

  # The organization and the version come from the socket, never from a client
  # payload, so a deletion can only land in the page's own version (R10); the
  # actor is the signed-in user, as the other GTFS pages build it (R9).
  defp delete_audit_context(socket) do
    %GtfsPlanner.Gtfs.AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      station_stop_id: nil,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  defp deleted_message(1), do: "1 transfer rule deleted."
  defp deleted_message(count), do: "#{count} transfer rules deleted."

  # The refusals the delete facades document; anything else is a server failure
  # the operator can retry.
  defp delete_error(:stale), do: :stale
  defp delete_error(:not_found), do: :not_found
  defp delete_error(_reason), do: :busy

  defp transfers_target(version_id), do: ~p"/gtfs/#{version_id}/transfers"
end
