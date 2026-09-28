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

  Version switching keeps the action and accepts only a published version of the
  current organization. A foreign, staging or absent version leaves both the
  socket and the client's selection untouched, as on the other GTFS pages.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.TransferComponents

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

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
     |> assign_filters(@empty_filters)
     |> stream(:transfers, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    url_params = Map.take(params, @owned_params)
    load_catalog(assign(socket, :url_params, url_params), url_params)
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
         push_patch(socket,
           to: list_path(socket, sort_by: sort_by, sort_dir: sort_dir, page: 1, rule: nil)
         )}
    end
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: list_path(socket, page: parse_page(page), rule: nil))}
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

    {:noreply, push_patch(socket, to: list_path(socket, filters: filters, page: 1, rule: nil))}
  end

  @impl true
  def handle_event("search", params, socket) do
    filters = %{socket.assigns.filters | q: parse_string(Map.get(params, "q"))}

    {:noreply, push_patch(socket, to: list_path(socket, filters: filters, page: 1, rule: nil))}
  end

  @impl true
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, :filters_open?, not socket.assigns.filters_open?)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    # The bare list of the current view: the view param stays, every filter, the
    # page and the selection are dropped.
    {:noreply, push_patch(socket, to: list_path(socket, clear_overrides()))}
  end

  @impl true
  def handle_event("switch_view", %{"view" => value}, socket) do
    # The chips switch the list to a view whose rows are a different set, so the
    # filters, the page and the selected rule are left behind with the old view.
    {:noreply,
     push_patch(socket,
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
        </.header>

        <.workspace>
          <:list>
            <.load_failure :if={@catalog_state == :unavailable} />
            <div :if={@catalog_state == :ready}>
              <.view_chips view={@view} counts={@catalog.counts} />
              <.first_use :if={first_use?(@catalog, @view)} />
              <div :if={list?(@catalog, @view)}>
                <.list_toolbar
                  search_form={@search_form}
                  filter_form={@filter_form}
                  filter_options={@catalog.filter_options}
                  filter_count={filter_count(@filters)}
                  filters_open?={@filters_open?}
                  in_seat?={@view == :in_seat}
                />
                <.rule_count total_count={@total_count} in_seat?={@view == :in_seat} />
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
                />
              </div>
              <.in_seat_empty :if={in_seat_empty?(@catalog, @view)} />
            </div>
          </:list>
          <:context>
            <.inspector
              :if={@selected}
              row={@selected}
              competitors={@competitors}
              compare_open?={@compare_open?}
              version_id={@current_gtfs_version.id}
              in_seat?={@view == :in_seat}
            />
            <.context_empty :if={is_nil(@selected)} />
            <.compare_dialog
              :if={@compare_open?}
              row={@selected}
              competitors={@competitors}
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

  defp transfers_target(version_id), do: ~p"/gtfs/#{version_id}/transfers"
end
