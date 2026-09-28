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

  Filtering and the connection map arrive with their own steps, so this LiveView
  owns the shell and the general rules list today.

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
  @owned_params ~w(sort_by sort_dir page rule)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Transfers")
     |> assign(:catalog_state, :ready)
     |> assign(:catalog, nil)
     |> assign(:sort_by, :from)
     |> assign(:sort_dir, :asc)
     |> assign(:page, 1)
     |> assign(:per_page, 50)
     |> assign(:total_count, 0)
     |> assign(:selected_id, nil)
     |> assign(:rule, nil)
     |> assign(:page_rows, %{})
     |> assign(:page_ids, nil)
     |> assign(:url_params, %{})
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
            <.rules_table
              :if={rules?(@catalog_state, @catalog)}
              rows={@streams.transfers}
              selected_id={@selected_id}
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              page={@page}
              per_page={@per_page}
              total_count={@total_count}
            />
            <.first_use :if={first_use?(@catalog_state, @catalog)} />
          </:list>
          <:context>
            <.context_empty />
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
    sort_by = Map.get(@sort_keys, url_params["sort_by"]) || :from
    sort_dir = Map.get(@sort_dirs, url_params["sort_dir"]) || :asc
    page = parse_page(url_params["page"])
    rule = parse_rule(url_params["rule"])

    opts = [sort_by: sort_by, sort_dir: sort_dir, page: page, rule: rule]

    case Gtfs.load_transfer_catalog(organization_id, gtfs_version_id, opts) do
      {:ok, catalog} ->
        previous_selected_id = socket.assigns.selected_id
        selection = catalog.selected

        socket =
          socket
          |> assign(:sort_by, sort_by)
          |> assign(:sort_dir, sort_dir)
          |> assign(:page, catalog.page)
          |> assign(:per_page, catalog.per_page)
          |> assign(:total_count, catalog.total_count)
          |> assign(:selected_id, selection && selection.id)
          |> assign(:rule, canonical_rule(rule, selection))
          |> assign(:catalog, catalog)
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
         |> assign(:sort_by, sort_by)
         |> assign(:sort_dir, sort_dir)
         |> assign(:catalog, nil)
         |> assign(:catalog_state, :unavailable)
         |> assign(:selected_id, nil)
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

  defp canonical_params(assigns) do
    assigns
    |> list_params([])
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp list_path(socket, overrides) do
    version_id = socket.assigns.current_gtfs_version.id
    ~p"/gtfs/#{version_id}/transfers?#{list_params(socket.assigns, overrides)}"
  end

  defp list_params(assigns, overrides) do
    sort_by = Keyword.get(overrides, :sort_by, assigns.sort_by)
    sort_dir = Keyword.get(overrides, :sort_dir, assigns.sort_dir)
    page = Keyword.get(overrides, :page, assigns.page)
    rule = Keyword.get(overrides, :rule, assigns.rule)

    []
    |> sort_params(sort_by, sort_dir)
    |> page_params(page)
    |> rule_params(rule)
  end

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

  # A version with general rules lists them, whether or not a filter hides them
  # (the filtered-empty state arrives with filtering).
  defp rules?(:ready, %{counts: %{general: general}}), do: general > 0
  defp rules?(_catalog_state, _catalog), do: false

  # First use is a version with no general rules at all, including one whose only
  # rows are in-seat records, whose mutations belong to Blocks.
  defp first_use?(:ready, %{counts: %{general: 0}}), do: true
  defp first_use?(_catalog_state, _catalog), do: false

  defp transfers_target(version_id), do: ~p"/gtfs/#{version_id}/transfers"
end
