defmodule GtfsPlannerWeb.Gtfs.BlocksLive do
  @moduledoc """
  LiveView for Operations › Blocks.

  Blocks shows which trips one vehicle works in sequence for a day type, and it
  is the only place a block is edited. This page owns the day-type scope, the
  whole-day count strip, the Service dates, Checks and Peak drawers and every
  page state; the timeline, the pool and the trip, gap and block drawers arrive
  in later steps and render inside the same page.

  The page mounts through the ordinary `:gtfs_routes` session, which decides
  whether a request reaches it; the editor guard is declared here because a
  session alone grants no GTFS access. Mount carries no page state and never
  patches the URL, so a link to `/blocks` always lands on the page itself.
  Version switching keeps the page on the new version and accepts only a
  published version of the current organization.

  The whole loaded day lives in the server-only `:day` assign, which `render/1`
  never reads: the render assigns (`:day_types`, `:day_type`, `:counts`,
  `:peak`, `:bins`, `:axis` and the rest) are derived from it, so a route filter,
  a page change or a drawer never re-reads the trips (CR-6). A load runs when
  the connected page has no day for the requested key; every other URL change
  only re-renders. An unknown `day` key keeps its recovery state and applies no
  default (INV-6), and a failed load keeps the last loaded day on screen.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking.Summary
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.BlocksComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @drawers %{"service_dates" => :service_dates, "checks" => :checks, "peak" => :peak}

  @sort_keys %{
    "block" => :block,
    "trips" => :trips,
    "start" => :start,
    "end" => :end,
    "hours" => :hours,
    "status" => :status
  }

  # The timeline holds one page of the day type's blocks. The filtered, sorted
  # list is derived from the loaded day, so paging, sorting and the filters never
  # re-read trips (CR-6).
  @page_size 100

  # A page number is clamped to a positive integer. `@max_page` is the absolute
  # guard against a crafted URL; the day's own page count is applied when the page
  # is sliced, so an out-of-range page renders the last page's rows rather than a
  # page the pager would deny. The URL keeps the requested page (EV-19).
  @max_page 10_000

  @empty_counts %{blocks: 0, trips: 0, unassigned: 0, problems: 0, notices: 0}
  @empty_peak %{count: 0, at_secs: nil, excluded_unassigned: 0, excluded_frequency: 0}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Blocks")
     |> assign(:day, nil)
     |> assign(:loaded_day_key, nil)
     |> assign(:page_size, @page_size)
     |> assign(:load_state, :loading)
     |> assign(:open_drawer, nil)
     |> assign(:selection, MapSet.new())
     |> assign(:visible_count, 0)
     |> assign(:timeline_key, nil)
     |> stream(:block_rows, [], dom_id: &block_dom_id/1)
     |> assign_empty_derived()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    state = parse_state(params, socket.assigns.current_gtfs_version)

    {:noreply, socket |> assign(:state, state) |> ensure_day_loaded()}
  end

  @impl true
  def handle_event("select_day", %{"day" => day}, socket) do
    patch(socket, %{day: blank_to_nil(day), trip: nil, page: 1, pool_page: 1},
      clear_selection: true
    )
  end

  def handle_event("filter", params, socket) do
    status = if params["status"] == "problems", do: :problems, else: :all

    patch(socket, %{route: blank_to_nil(params["route"]), status: status, page: 1, pool_page: 1})
  end

  def handle_event("set_panel", %{"panel" => "blocks"}, socket) do
    patch(socket, %{panel: :blocks})
  end

  def handle_event("set_panel", %{"panel" => "pool"}, socket) do
    patch(socket, %{panel: :pool, pool_page: 1})
  end

  def handle_event("set_panel", _params, socket), do: {:noreply, socket}

  def handle_event("set_view", %{"view" => "timeline"}, socket) do
    patch(socket, %{view: :timeline})
  end

  def handle_event("set_view", %{"view" => "list"}, socket) do
    patch(socket, %{view: :list})
  end

  def handle_event("set_view", _params, socket), do: {:noreply, socket}

  def handle_event("set_scale", %{"scale" => "day"}, socket) do
    patch(socket, %{scale: :day})
  end

  def handle_event("set_scale", %{"scale" => "zoom"}, socket) do
    patch(socket, %{scale: :zoom})
  end

  def handle_event("set_scale", _params, socket), do: {:noreply, socket}

  # Sorting the same key again reverses it; any other key starts ascending. The
  # sort covers the whole day type, so it returns to page 1 (AC-22).
  def handle_event("sort", %{"key" => key}, socket) do
    case Map.fetch(@sort_keys, key) do
      {:ok, sort} ->
        patch(socket, %{sort: sort, dir: toggled_dir(socket.assigns.state, sort), page: 1})

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    patch(socket, %{page: page_number(page)})
  end

  def handle_event("open_drawer", %{"key" => key}, socket) do
    case key do
      "unassigned" ->
        if socket.assigns.counts.unassigned > 0 do
          patch(socket, %{panel: :pool, pool_page: 1}, clear_selection: true)
        else
          {:noreply, socket}
        end

      key ->
        case Map.fetch(@drawers, key) do
          {:ok, drawer} -> {:noreply, assign(socket, :open_drawer, drawer)}
          :error -> {:noreply, socket}
        end
    end
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :open_drawer, nil)}
  end

  def handle_event("open_trip", %{"trip" => trip_id}, socket) do
    patch(socket, %{trip: blank_to_nil(trip_id)}, close_drawer: true)
  end

  def handle_event("open_block", %{"block" => block_id}, socket) do
    patch(socket, %{block: blank_to_nil(block_id)}, close_drawer: true)
  end

  def handle_event("retry", _params, socket) do
    {:noreply, load_day(socket)}
  end

  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/blocks")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/blocks")}
    else
      {:noreply, socket}
    end
  end

  defp patch(socket, overrides, opts \\ []) do
    socket =
      if Keyword.get(opts, :clear_selection, false),
        do: assign(socket, :selection, MapSet.new()),
        else: socket

    socket =
      if Keyword.get(opts, :close_drawer, false),
        do: assign(socket, :open_drawer, nil),
        else: socket

    {:noreply, push_patch(socket, to: blocks_path(Map.merge(socket.assigns.state, overrides)))}
  end

  # The URL state (Pages). Unknown values fall back to their default; the day key
  # is kept as given so an unknown key can reach its recovery state (INV-6).
  defp parse_state(params, version) do
    %{
      version_id: to_string(version.id),
      day: blank_to_nil(params["day"]),
      panel: if(params["panel"] == "pool", do: :pool, else: :blocks),
      view: if(params["view"] == "list", do: :list, else: :timeline),
      route: blank_to_nil(params["route"]),
      status: if(params["status"] == "problems", do: :problems, else: :all),
      sort: sort(params["sort"]),
      dir: if(params["dir"] == "desc", do: :desc, else: :asc),
      scale: if(params["scale"] == "zoom", do: :zoom, else: :day),
      page: page_number(params["page"]),
      pool_page: page_number(params["pool_page"]),
      trip: blank_to_nil(params["trip"]),
      block: blank_to_nil(params["block"])
    }
  end

  defp sort(value) when is_map_key(@sort_keys, value), do: Map.fetch!(@sort_keys, value)

  defp sort(_value), do: :block

  defp toggled_dir(%{sort: sort, dir: :asc}, sort), do: :desc
  defp toggled_dir(_state, _sort), do: :asc

  defp page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page >= 1 -> min(page, @max_page)
      _other -> 1
    end
  end

  defp page_number(_value), do: 1

  # Every non-default parameter, in a fixed order, so a patch carries only what
  # the reader needs and an empty day type stays at `/blocks` (CR-7).
  defp blocks_path(state) do
    case path_params(state) do
      [] -> "/gtfs/#{state.version_id}/blocks"
      params -> "/gtfs/#{state.version_id}/blocks?" <> URI.encode_query(params)
    end
  end

  defp path_params(state) do
    [
      {"day", state.day},
      {"panel", optional(state.panel == :pool, "pool")},
      {"view", optional(state.view == :list, "list")},
      {"route", state.route},
      {"status", optional(state.status == :problems, "problems")},
      {"sort", optional(state.sort != :block, Atom.to_string(state.sort))},
      {"dir", optional(state.dir == :desc, "desc")},
      {"scale", optional(state.scale == :zoom, "zoom")},
      {"page", page_param(state.page)},
      {"pool_page", page_param(state.pool_page)},
      {"trip", state.trip},
      {"block", state.block}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp optional(true, value), do: value
  defp optional(false, _value), do: nil

  defp page_param(1), do: nil
  defp page_param(page), do: Integer.to_string(page)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp ensure_day_loaded(socket) do
    cond do
      not connected?(socket) ->
        assign(socket, :load_state, :loading)

      socket.assigns.loaded_day_key == {:key, socket.assigns.state.day} ->
        assign_timeline(socket)

      true ->
        load_day(socket)
    end
  end

  defp load_day(socket) do
    %{state: state, current_organization: organization, current_gtfs_version: version} =
      socket.assigns

    case Gtfs.load_blocking_day(organization.id, version.id, state.day) do
      {:ok, day} ->
        socket
        |> assign(:state, normalize_route(state, day))
        |> assign(:day, day)
        |> assign(:loaded_day_key, {:key, state.day})
        |> assign(:load_state, day_state(day))
        |> assign(:timeline_key, nil)
        |> assign_derived(day)
        |> assign_timeline()

      {:error, {:unknown_day_type, day_types}} ->
        socket
        |> assign(:day, nil)
        |> assign(:loaded_day_key, {:key, state.day})
        |> assign(:load_state, :unknown)
        |> assign_empty_derived()
        |> assign(:day_types, day_types)

      {:error, _reason} ->
        # A database outage keeps whatever is already on screen; only the callout
        # changes, so the reader can retry with the same URL.
        assign(socket, :load_state, :unavailable)
    end
  end

  defp day_state(day) do
    cond do
      day.day_types == [] -> :no_dates
      day.counts.trips == 0 -> :empty
      true -> :loaded
    end
  end

  defp normalize_route(%{route: nil} = state, _day), do: state

  defp normalize_route(state, day) do
    if Map.has_key?(day.routes, state.route), do: state, else: %{state | route: nil}
  end

  # The visible page of the day type's blocks: the route and status filters, the
  # chosen sort over the whole day type, then one page of 100 rows, streamed so a
  # sort, filter or page change replaces the container. `load_day/1` and the empty
  # states clear `:timeline_key`, so a reload always resends; an unrelated patch
  # (a drawer, a deep link) leaves the stream alone.
  defp assign_timeline(socket) do
    visible = visible_blocks(socket.assigns.day.blocks, socket.assigns.state)
    page = effective_page(socket.assigns.state.page, length(visible))

    key =
      {socket.assigns.state.route, socket.assigns.state.status, socket.assigns.state.sort,
       socket.assigns.state.dir, page}

    socket = assign(socket, :visible_count, length(visible))

    if socket.assigns.timeline_key == key do
      socket
    else
      rows = visible |> Enum.drop((page - 1) * @page_size) |> Enum.take(@page_size)

      socket
      |> assign(:timeline_key, key)
      |> stream(:block_rows, rows, reset: true)
    end
  end

  defp effective_page(page, visible_count) do
    min(page, max(div(visible_count + @page_size - 1, @page_size), 1))
  end

  defp visible_blocks(blocks, state) do
    by_id = Map.new(blocks, &{&1.summary.block_id, &1})

    blocks
    |> Enum.filter(
      &(block_on_route?(&1, state.route) and block_matching_status?(&1, state.status))
    )
    |> Enum.map(& &1.summary)
    |> Summary.sort_blocks(state.sort, state.dir)
    |> Enum.map(&by_id[&1.block_id])
  end

  defp block_on_route?(_block, nil), do: true

  defp block_on_route?(block, route_id) do
    Enum.any?(block.trips, &(&1.route_id == route_id))
  end

  defp block_matching_status?(_block, :all), do: true
  defp block_matching_status?(block, :problems), do: block.summary.status in [:error, :warning]

  # The stream needs a stable id per block, and a block ID may hold any Unicode;
  # the URL-safe Base64 token keeps the id within ASCII (Setup and hazards).
  defp block_dom_id(block),
    do: "block-" <> Base.url_encode64(block.summary.block_id, padding: false)

  defp assign_derived(socket, day) do
    assign(socket,
      day_types: day.day_types,
      day_type: day.day_type,
      counts: day.counts,
      peak: day.peak,
      bins: day.bins,
      axis: day.axis,
      routes: day.routes,
      findings: day.findings,
      mixed_timezones?: day.mixed_timezones?,
      trip_labels: trip_labels(day)
    )
  end

  defp assign_empty_derived(socket) do
    socket
    |> assign(
      day_types: [],
      day_type: nil,
      counts: @empty_counts,
      peak: @empty_peak,
      bins: [],
      axis: nil,
      routes: %{},
      findings: [],
      mixed_timezones?: false,
      trip_labels: %{},
      visible_count: 0,
      timeline_key: nil
    )
    |> stream(:block_rows, [], reset: true)
  end

  # Each finding names trips by UUID; a deep link names them by their natural
  # trip ID, so the drawer maps one to the other without reading the day.
  defp trip_labels(day) do
    (Enum.flat_map(day.blocks, & &1.trips) ++ day.pool ++ day.unplottable)
    |> Map.new(&{&1.id, &1.trip_id})
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
        <.operations_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:blocks} />
      </:sub_header>

      <div id="blocks-page">
        <section class="min-h-screen bg-base-100">
          <div class="mx-auto w-full max-w-7xl space-y-4">
            <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <.header>
                Blocks
                <:subtitle>A block is one vehicle's sequence of trips.</:subtitle>
              </.header>

              <button
                :if={@load_state == :loaded}
                id="blocks-review-checks"
                type="button"
                phx-click="open_drawer"
                phx-value-key="checks"
                class="btn btn-sm min-h-11"
              >
                Review checks
              </button>
            </div>

            <.callout
              :if={@load_state == :unavailable}
              id="blocks-unavailable"
              kind="error"
              title="We couldn't load blocks."
            >
              Your saved assignments haven't changed.
              <button
                id="blocks-retry"
                type="button"
                phx-click="retry"
                class="link link-primary min-h-11"
              >
                Retry loading
              </button>
            </.callout>

            <%= cond do %>
              <% @load_state == :loading -> %>
                <BlocksComponents.page_state kind={:loading} />
              <% @load_state == :no_dates -> %>
                <BlocksComponents.page_state kind={:no_dates} version_id={@state.version_id} />
              <% @load_state == :empty -> %>
                <BlocksComponents.page_state kind={:empty} version_id={@state.version_id} />
              <% @load_state == :unknown -> %>
                <BlocksComponents.page_state kind={:unknown} day_types={@day_types} />
              <% @day_type -> %>
                <BlocksComponents.scope_header
                  day_types={@day_types}
                  day_type={@day_type}
                  routes={@routes}
                  state={@state}
                />

                <.callout
                  :if={@mixed_timezones?}
                  id="blocks-mixed-timezones"
                  kind="warning"
                  title="Agencies in this version use different timezones."
                >
                  Times are shown as stored.
                </.callout>

                <BlocksComponents.summary_strip
                  day_type={@day_type}
                  counts={@counts}
                  peak={@peak}
                  open_drawer={@open_drawer}
                />

                <%!-- The workspace holds the timeline; the List view and the
                Unassigned panel arrive in step 22. --%>
                <BlocksComponents.workspace
                  state={@state}
                  counts={@counts}
                  visible_count={@visible_count}
                  page_size={@page_size}
                  block_rows={@streams.block_rows}
                  axis={@axis}
                  routes={@routes}
                />

                <BlocksComponents.service_dates_drawer
                  open={@open_drawer == :service_dates}
                  day_type={@day_type}
                />
                <BlocksComponents.checks_drawer
                  open={@open_drawer == :checks}
                  findings={@findings}
                  trip_labels={@trip_labels}
                />
                <BlocksComponents.peak_drawer
                  open={@open_drawer == :peak}
                  peak={@peak}
                  bins={@bins}
                  axis={@axis}
                />
              <% true -> %>
            <% end %>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
