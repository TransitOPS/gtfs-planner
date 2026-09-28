defmodule GtfsPlannerWeb.Gtfs.BlocksLive do
  @moduledoc """
  LiveView for Operations › Blocks.

  Blocks shows which trips one vehicle works in sequence for a day type, and it
  is the only place a block is edited. This page owns the day-type scope, the
  whole-day count strip, the Service dates, Checks and Peak drawers and every
  page state; the timeline, the List view, the unassigned pool and the trip, gap
  and block drawers render inside the same page.

  The page mounts through the ordinary `:gtfs_routes` session, which decides
  whether a request reaches it; the editor guard is declared here because a
  session alone grants no GTFS access. Mount carries no page state and never
  patches the URL, so a link to `/blocks` always lands on the page itself.
  Version switching keeps the page on the new version and accepts only a
  published version of the current organization.

  The whole loaded day lives in the server-only `:day` assign, which `render/1`
  never reads: the render assigns (`:day_types`, `:day_type`, `:counts`,
  `:peak`, `:bins`, `:axis`, the trip's in-seat records and the rest) are derived
  from it, so a route filter, a page change or a drawer never re-reads the trips
  (CR-6). A load runs when the connected page has no day for the requested key;
  every other URL change only re-renders. An unknown `day` key keeps its recovery
  state and applies no default (INV-6), and a failed load keeps the last loaded
  day on screen.

  `trip=` is a deep link to one trip's read-only drawer: `handle_params/3`
  resolves it against the loaded day, opens `#trip-drawer` on the page that holds
  the trip (overriding a requested `page`/`pool_page`), and shows
  `#blocks-trip-elsewhere` with the trip's own day types or the unavailable
  sentence when the loaded day type or the version does not hold it (AC-29).

  `gap=` (`<from trip uuid>|<to trip uuid>`) and `block=` are the other two
  drawers, and the three together are a small stack: `block=` keeps its context
  in the URL while a gap or a trip is open on top of it, so the gap and trip
  drawers offer “Back to block <id>”. The top of the stack is the one drawer
  rendered open (trip, then gap, then block), one URL change resolves it against
  the loaded day and no drawer reaches into the day in `render/1` (CR-6).
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Summary
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.EnsureRole
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

  # The timeline and the List view hold one page of the day type's blocks and the
  # Unassigned panel one page of its pool trips. Every page is derived from the
  # loaded day, so paging, sorting and the filters never re-read trips (CR-6).
  @page_size 100

  # A page number is clamped to a positive integer. `@max_page` is the absolute
  # guard against a crafted URL; the day's own page count is applied when the page
  # is sliced, so an out-of-range page renders the last page's rows rather than a
  # page the pager would deny. The URL keeps the requested page (EV-19).
  @max_page 10_000

  @empty_counts %{blocks: 0, trips: 0, unassigned: 0, problems: 0, notices: 0}
  @empty_peak %{count: 0, at_secs: nil, excluded_unassigned: 0, excluded_frequency: 0}

  # The destination picker offers at most this many matches, so a day type with
  # thousands of blocks still narrows by search rather than by scrolling (AC-26).
  @destination_limit 25

  @permission_message "You don't have permission to change blocks in this version."

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
     |> stream(:list_rows, [], dom_id: &block_dom_id/1)
     |> stream(:pool_rows, [], dom_id: &pool_dom_id/1)
     |> assign(:assign, nil)
     |> assign(:review, nil)
     |> assign(:review_stale?, false)
     |> assign_empty_derived()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    state = parse_state(params, socket.assigns.current_gtfs_version)

    {:noreply,
     socket
     |> assign(:state, state)
     |> ensure_day_loaded()
     |> resolve_drawers()}
  end

  @impl true
  def handle_event("select_day", %{"day" => day}, socket) do
    patch(socket, %{day: blank_to_nil(day), trip: nil, page: 1, pool_page: 1},
      clear_selection: true,
      clear_command: true
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

  def handle_event("paginate_pool", %{"page" => page}, socket) do
    patch(socket, %{pool_page: page_number(page)})
  end

  # The row checkbox is inert until step 26 owns the cross-page selection state.
  def handle_event("toggle_trip", _params, socket), do: {:noreply, socket}

  # “Select this page” selects the whole page in step 26's bulk selection.
  def handle_event("select_page", _params, socket), do: {:noreply, socket}

  # The assignment form lives in the trip drawer, so opening it from a pool row
  # patches `trip=` to open that drawer; a trip already in the URL keeps its URL,
  # including any `block=` context its “Back to block” link reads. Step 26 adds
  # the `selection` scope beside this one.
  def handle_event("open_assign", %{"scope" => "trip", "trip" => trip_id}, socket) do
    case find_day_trip(socket.assigns.day, trip_id) do
      nil ->
        {:noreply, socket}

      trip ->
        socket = assign(socket, :assign, new_assign(trip))

        if socket.assigns.state.trip == trip.trip_id do
          {:noreply, socket}
        else
          patch(socket, %{trip: trip.trip_id, gap: nil, block: nil})
        end
    end
  end

  def handle_event("open_assign", _params, socket), do: {:noreply, socket}

  # The search input carries the whole form, so the handler keeps the checked
  # radio as well as the narrowed search (the form is re-rendered on every event).
  def handle_event("search_destination", params, socket) do
    case socket.assigns.assign do
      nil -> {:noreply, socket}
      assign -> {:noreply, assign(socket, :assign, put_form_params(assign, params))}
    end
  end

  def handle_event("submit_assign", params, socket) do
    case socket.assigns.assign do
      nil ->
        {:noreply, socket}

      assign ->
        assign =
          assign
          |> put_form_params(params)
          |> Map.merge(%{error: nil, ineligible: []})

        case command(assign) do
          {:ok, command} -> run_command(assign(socket, :assign, assign), command, nil)
          {:error, message} -> {:noreply, assign(socket, :assign, %{assign | error: message})}
        end
    end
  end

  # “Remove from block” runs the same reviewed command path as an assignment, so
  # a removal that adds a problem opens the review too (R10, AC-26).
  def handle_event("unassign", %{"scope" => "trip", "trip" => trip_id}, socket) do
    case find_day_trip(socket.assigns.day, trip_id) do
      nil -> {:noreply, socket}
      trip -> run_command(socket, {:unassign, [trip.id]}, nil)
    end
  end

  def handle_event("unassign", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_review", _params, socket) do
    case socket.assigns.review do
      %{command: command, fingerprint: fingerprint} ->
        run_command(socket, command, fingerprint)

      _other ->
        {:noreply, socket}
    end
  end

  # “Change selection” closes the review and leaves the form with its chosen
  # target, so the reader can pick another destination without reopening the
  # drawer.
  def handle_event("cancel_review", _params, socket) do
    {:noreply, assign(socket, review: nil, review_stale?: false)}
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

  # `spec.md` names the payload `drawer`; the page's own controls send `key`.
  # Mirrors the catch-all on `set_panel` / `set_view` / `set_scale`.
  def handle_event("open_drawer", _params, socket), do: {:noreply, socket}

  # The trip, gap and block drawers are part of the URL, so closing one drops the
  # parameters as well as the panel-only drawer's own state; the other drawers
  # keep the URL they had. The panel drawers render over the page, so one of them
  # opens alongside whichever URL drawer the page had.
  def handle_event("close_drawer", _params, socket) do
    socket = assign(socket, :open_drawer, nil)

    if socket.assigns.state.trip || socket.assigns.state.gap || socket.assigns.state.block do
      patch(socket, %{trip: nil, gap: nil, block: nil}, clear_command: true)
    else
      {:noreply, socket}
    end
  end

  # A trip opened from another drawer keeps that drawer's `block` in the URL, so
  # the trip drawer can offer “Back to block <id>”; a trip opened from a bar or a
  # marker carries no `block` and drops any the URL held. Every drawer clears the
  # other two, so one URL never holds a stack of two open drawers.
  def handle_event("open_trip", %{"trip" => trip_id} = params, socket) do
    patch(
      socket,
      %{trip: blank_to_nil(trip_id), gap: nil, block: blank_to_nil(params["block"])},
      close_drawer: true
    )
  end

  # The pair is the two trip UUIDs the gap bar or the block drawer's gap note
  # sent; the URL carries them as one `gap=` parameter so the drawer is a deep
  # link too.
  def handle_event("open_gap", params, socket) do
    patch(
      socket,
      %{
        gap: gap_param(params["from"], params["to"]),
        trip: nil,
        block: blank_to_nil(params["block"])
      },
      close_drawer: true
    )
  end

  def handle_event("open_block", %{"block" => block_id}, socket) do
    patch(socket, %{block: blank_to_nil(block_id), trip: nil, gap: nil}, close_drawer: true)
  end

  def handle_event("retry", _params, socket) do
    {:noreply, socket |> load_day() |> resolve_drawers()}
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

    socket =
      if Keyword.get(opts, :clear_command, false),
        do: assign(socket, assign: nil, review: nil, review_stale?: false),
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
      gap: blank_to_nil(params["gap"]),
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

  # The two trip UUIDs of a gap, in the one URL parameter the drawer reads back.
  # UUIDs hold no `|`, so the separator cannot be ambiguous; anything else closes
  # the drawer rather than opening a half pair.
  defp gap_param(from, to) do
    case {blank_to_nil(from), blank_to_nil(to)} do
      {nil, _to} -> nil
      {_from, nil} -> nil
      {from, to} -> from <> "|" <> to
    end
  end

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
      {"gap", state.gap},
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
        assign_page_rows(socket)

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
        # Neither key holds the day, so a reload clears both. The pool's key is
        # unchanged by a day-type switch, so without this it would keep the
        # previous day's rows under the new day's pager, counts and peak.
        |> assign(:timeline_key, nil)
        |> assign(:pool_key, nil)
        |> assign_derived(day)
        |> assign_page_rows()

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
  # chosen sort over the whole day type, then one page of 100 rows. The timeline
  # and the List view are two densities of the same page, so each has its own
  # stream (a stream belongs to one container) and one key gates both. The key
  # holds the panel and the view as well as the filters and the page: a container
  # the client holds is replaced when any of them changes, and a replaced stream
  # container is empty until the page is sent again, so the reset must happen on
  # that change too. `load_day/1` and the empty states clear the key, so a reload
  # always resends.
  defp assign_timeline(socket) do
    %{state: state} = socket.assigns
    visible = visible_blocks(socket.assigns.day.blocks, state)
    page = effective_page(state.page, length(visible))

    key =
      {state.panel, state.view, state.route, state.status, state.sort, state.dir, page}

    socket = assign(socket, :visible_count, length(visible))

    if socket.assigns.timeline_key == key do
      socket
    else
      rows = visible |> Enum.drop((page - 1) * @page_size) |> Enum.take(@page_size)

      socket
      |> assign(:timeline_key, key)
      |> stream(:block_rows, rows, reset: true)
      |> stream(:list_rows, rows, reset: true)
    end
  end

  # The visible page of the pool: the route filter over the pool's own order
  # (first departure, then untimed trips by trip ID), then one page of 100 rows,
  # streamed so a filter or page change replaces the container. The key holds the
  # panel because the pool table exists only while the Unassigned panel is shown,
  # and a stream container that is replaced must be filled again.
  defp assign_pool(socket) do
    %{state: state} = socket.assigns
    visible = visible_pool(socket.assigns.day.pool, state.route)
    page = effective_page(state.pool_page, length(visible))
    key = {state.panel, state.route, page}

    socket = assign(socket, :pool_visible_count, length(visible))

    if socket.assigns.pool_key == key do
      socket
    else
      rows = visible |> Enum.drop((page - 1) * @page_size) |> Enum.take(@page_size)

      socket
      |> assign(:pool_key, key)
      |> stream(:pool_rows, rows, reset: true)
    end
  end

  defp visible_pool(pool, nil), do: pool
  defp visible_pool(pool, route_id), do: Enum.filter(pool, &(&1.route_id == route_id))

  # Both streamed pages are re-derived together, so the timeline, the List view
  # and the pool stay in step on a day, filter or page change.
  defp assign_page_rows(socket), do: socket |> assign_timeline() |> assign_pool()

  # The drawer stack of the current URL: a trip sits on top of a gap, which sits
  # on top of a block, and only the top one renders open. The block is resolved
  # first, because it is what a gap and a trip opened from it keep as their way
  # back; the resolved block also decides whether “Back to block <id>” appears at
  # all, so a stale `block=` in the URL cannot offer a block the day type does not
  # hold. Resolution needs the loaded day: the disconnected first paint keeps its
  # skeleton, and an unavailable or unknown day keeps its own state with no drawer.
  defp resolve_drawers(socket) do
    case {connected?(socket), socket.assigns.day} do
      {true, day} when not is_nil(day) ->
        state = socket.assigns.state
        block = find_block(day, state.block)
        gap = resolve_gap(day, state.gap)
        {socket, trip} = resolve_trip_view(socket, day, state.trip)

        socket
        |> assign(:trip_view, trip)
        |> assign(:gap_view, if(is_nil(trip), do: gap))
        |> assign(:block_view, if(is_nil(trip) and is_nil(gap), do: block))
        |> assign(:back_block, if(block, do: block.summary.block_id))

      _other ->
        assign(socket,
          trip_view: nil,
          gap_view: nil,
          block_view: nil,
          back_block: nil
        )
    end
  end

  # A `trip` deep link resolves to that trip's drawer on the page that holds it
  # (AC-29). The trip's day types come from `Blocking.trip_day_types/3`, the one
  # derivation the day load also uses, so the drawer's all-dates scope and an
  # “another day type” notice agree with the loaded day (INV-6, CR-2). The page
  # holding the trip overrides the requested `page`/`pool_page` (Pages), which is
  # why the resolved page is written back before either streamed page is sliced.
  defp resolve_trip_view(socket, _day, nil), do: {socket, nil}

  defp resolve_trip_view(socket, day, trip_id) do
    case find_day_trip(day, trip_id) do
      nil ->
        {socket, resolve_absent_trip(socket, trip_id)}

      trip ->
        socket = override_trip_page(socket, trip)
        {socket, {:trip, trip, trip_day_types(socket, trip_id)}}
    end
  end

  # A trip the day type does not hold still names its own day types; a trip the
  # version does not hold is the unavailable notice.
  defp resolve_absent_trip(socket, trip_id) do
    case trip_day_types_result(socket, trip_id) do
      {:ok, day_types} -> {:elsewhere, trip_id, day_types}
      :error -> {:unknown, trip_id}
    end
  end

  defp find_block(_day, nil), do: nil

  defp find_block(day, block_id) do
    Enum.find(day.blocks, &(&1.summary.block_id == block_id))
  end

  # A `gap` deep link names the pair of consecutive trips; the drawer reads the
  # block's own gap entry (R5's handoff and the layover seconds) and the day's
  # own records for the pair, so neither is recomputed or re-derived here.
  defp resolve_gap(_day, nil), do: nil

  defp resolve_gap(day, gap) do
    case String.split(gap, "|") do
      [from_id, to_id] -> find_gap(day, from_id, to_id)
      _other -> nil
    end
  end

  defp find_gap(day, from_id, to_id) do
    Enum.find_value(day.blocks, fn block ->
      gap_entry(day, block, from_id, to_id)
    end)
  end

  defp gap_entry(day, block, from_id, to_id) do
    with from when not is_nil(from) <- Enum.find(block.trips, &(&1.id == from_id)),
         to when not is_nil(to) <- Enum.find(block.trips, &(&1.id == to_id)),
         gap when not is_nil(gap) <-
           Enum.find(block.gaps, &(&1.from_id == from_id and &1.to_id == to_id)) do
      %{
        block_id: block.summary.block_id,
        from: from,
        to: to,
        gap: gap,
        records: pair_records(day.in_seat, from, to),
        short?: short_layover?(block, from_id, to_id)
      }
    else
      _other -> nil
    end
  end

  # Every type 4/5 record naming both trips of the pair, whichever of the two
  # trips the day's own map lists it under (INV-3: a record is read, never
  # written, and one whose pair has no hosting gap is still shown).
  defp pair_records(in_seat, from, to) do
    (Map.get(in_seat, from.id, []) ++ Map.get(in_seat, to.id, []))
    |> Enum.filter(&(&1.row.from_trip_id == from.trip_id and &1.row.to_trip_id == to.trip_id))
    |> Enum.uniq()
  end

  # The short-layover warning is the block's own finding for the pair, so the
  # drawer and the timeline's gap bar read the same verdict.
  defp short_layover?(block, from_id, to_id) do
    Enum.any?(block.findings, fn finding ->
      finding.code == :short_layover and
        MapSet.new(finding.trip_ids) == MapSet.new([from_id, to_id])
    end)
  end

  defp trip_day_types(socket, trip_id) do
    case trip_day_types_result(socket, trip_id) do
      {:ok, day_types} -> day_types
      :error -> []
    end
  end

  defp trip_day_types_result(socket, trip_id) do
    %{current_organization: organization, current_gtfs_version: version} = socket.assigns

    case Blocking.trip_day_types(organization.id, version.id, trip_id) do
      {:ok, %{day_types: day_types}} -> {:ok, day_types}
      {:error, _reason} -> :error
    end
  end

  # A trip's drawer and the assignment form both name it by its natural trip ID;
  # an unloaded day holds no trip at all.
  defp find_day_trip(nil, _trip_id), do: nil

  defp find_day_trip(day, trip_id) do
    (Enum.flat_map(day.blocks, & &1.trips) ++ day.pool)
    |> Enum.find(&(&1.trip_id == trip_id))
  end

  defp find_day_trip_by_id(nil, _id), do: nil

  defp find_day_trip_by_id(day, id) do
    (Enum.flat_map(day.blocks, & &1.trips) ++ day.pool)
    |> Enum.find(&(&1.id == id))
  end

  # The page holding the trip: its block's own page for a blocked trip, the pool's
  # page for an unassigned one. The same visible order the page slices decides it,
  # so the resolved page is the one that renders the trip; a filter that hides it
  # leaves the requested page in place.
  defp override_trip_page(socket, trip) do
    %{state: state, day: day} = socket.assigns

    state =
      if is_nil(trip.block_id) do
        override_page(state, :pool_page, visible_pool(day.pool, state.route), & &1.id, trip.id)
      else
        block_ids = Enum.map(visible_blocks(day.blocks, state), & &1.summary.block_id)
        override_page(state, :page, block_ids, & &1, trip.block_id)
      end

    socket
    |> assign(:state, state)
    |> assign_page_rows()
  end

  defp override_page(state, key, values, identity, wanted) do
    case Enum.find_index(values, &(identity.(&1) == wanted)) do
      nil -> state
      index -> Map.put(state, key, div(index, @page_size) + 1)
    end
  end

  # The trip's calendar label: the day type with the fewest services containing
  # the trip's service names the calendar exactly when that day type holds one
  # service. The day load carries no per-service name, so this derives the label
  # from the same day types every other surface prints.
  defp calendar_label([]), do: "—"

  defp calendar_label(day_types) do
    day_types
    |> Enum.min_by(&length(&1.service_ids))
    |> Map.fetch!(:label)
  end

  # --- reviewed block commands (step 25) --------------------------------------

  # Every apply on this page goes through here (CR-8): the editor role is
  # re-read from the membership first, so a role revoked while the page is open
  # refuses the next write, and the audit context is built from the socket rather
  # than from any parameter (CR-4). The context resolves the command against the
  # organization, version and selected day type again, so a crafted event can
  # never widen the scope.
  defp run_command(%{assigns: %{day_type: nil}} = socket, _command, _confirmation),
    do: {:noreply, socket}

  defp run_command(socket, command, confirmation) do
    if editor_access?(socket) do
      case Gtfs.apply_block_change(
             socket.assigns.day_type.key,
             command,
             audit_context(socket),
             confirmation
           ) do
        {:ok, result} -> applied(socket, command, result)
        {:needs_confirmation, review} -> {:noreply, show_review(socket, review, false)}
        {:error, {:stale_review, review}} -> {:noreply, show_review(socket, review, true)}
        {:error, {:ineligible, ids}} -> {:noreply, refuse_ineligible(socket, ids)}
        {:error, reason} -> {:noreply, refuse(socket, reason)}
      end
    else
      {:noreply, put_flash(socket, :error, @permission_message)}
    end
  end

  # A write reloads the day, drops the form and the review and follows the first
  # changed trip to the page that holds it, so the reader sees the row the flash
  # names (AC-26). Nothing here re-derives a review: the result carries the one
  # the context built.
  defp applied(socket, command, result) do
    socket = load_day(socket)

    socket =
      case result.changed_trip_ids do
        [first | _rest] -> follow_changed_trip(socket, first)
        [] -> socket
      end

    socket
    |> assign(assign: nil, review: nil, review_stale?: false)
    |> put_flash(:info, success_message(command, result))
    # A successful command also clears step 26's selection, because those trips
    # are no longer the trips the reader selected.
    |> then(&patch(&1, %{trip: nil, gap: nil, block: nil}, clear_selection: true))
  end

  defp follow_changed_trip(socket, trip_id) do
    case find_day_trip_by_id(socket.assigns.day, trip_id) do
      nil -> socket
      trip -> override_trip_page(socket, trip)
    end
  end

  defp success_message(_command, %{changed_trip_ids: []}),
    do: "No assignment changed. The trip already has this block."

  defp success_message({:assign, _ids, _target}, result) do
    "Assigned #{count_label(length(result.changed_trip_ids))} to block #{result.block_id}."
  end

  defp success_message({:unassign, _ids}, result) do
    "Removed #{count_label(length(result.changed_trip_ids))} from #{source_label(result.review)}."
  end

  defp success_message(_command, _result), do: "Saved the block change."

  defp source_label(%{changes: changes}) do
    case changes |> Enum.map(& &1.from) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [block_id] -> "block #{block_id}"
      _other -> "its block"
    end
  end

  defp source_label(_review), do: "its block"

  # The review keeps the command and its fingerprint, so confirming re-runs it
  # under the lock and writes only when the recomputed fingerprint still matches
  # (AC-12). The failure sentence is cleared by the new review.
  defp show_review(socket, review, stale?) do
    socket
    |> clear_command_error()
    |> assign(review: review, review_stale?: stale?)
  end

  defp clear_command_error(socket) do
    case socket.assigns.assign do
      nil -> socket
      assign -> assign(socket, :assign, %{assign | error: nil, ineligible: []})
    end
  end

  # An ineligible trip is named in the form rather than dropped: the reason comes
  # from the trip's own flags, so the reader sees which rule refused it (FH-18).
  defp refuse_ineligible(socket, ids) do
    case socket.assigns.assign do
      nil ->
        put_flash(socket, :error, "Some selected trips can't be assigned to a block.")

      assign ->
        assign(socket, :assign, %{assign | ineligible: ids, error: nil})
    end
  end

  # A failed save keeps the form, its target and its review: only the sentence
  # changes, so a retry repeats exactly the reviewed command (AC-26).
  defp refuse(socket, reason) do
    message = command_error(reason)

    case socket.assigns.assign do
      nil -> put_flash(socket, :error, message)
      assign -> assign(socket, :assign, %{assign | error: message})
    end
  end

  defp command_error(:busy), do: "Another change is being saved. Try again."
  defp command_error(:not_found), do: "That trip isn't in this version."
  defp command_error(:unknown_day_type), do: "This day type isn't in this version."
  defp command_error(:invalid_command), do: "That change isn't valid."

  defp command_error(:invalid_block_id),
    do: "Enter a block ID of 1 to 255 characters."

  defp command_error(:block_id_taken),
    do: "That block ID already runs on these dates. Choose another."

  defp command_error(:too_many_trips), do: "This change touches too many trips."

  defp command_error({:audit_failed, _reason}),
    do: "The change couldn't be saved. Nothing was written."

  defp command_error(_reason), do: "The change couldn't be saved. Try again."

  # --- the assignment form (step 25) -----------------------------------------

  defp new_assign(trip) do
    %{
      scope: :trip,
      trips: [trip],
      trip_ids: [trip.id],
      blocked?: not is_nil(trip.block_id),
      target: nil,
      search: "",
      error: nil,
      ineligible: []
    }
  end

  defp put_form_params(assign, params) do
    values = Map.get(params, "assign", %{})

    %{
      assign
      | search: Map.get(values, "search", assign.search),
        target: destination_target(Map.get(values, "destination"), assign.target)
    }
  end

  defp destination_target(nil, current), do: current
  defp destination_target("new", _current), do: :new
  defp destination_target("none", _current), do: :none
  defp destination_target(block_id, _current), do: block_id

  defp command(%{target: nil}), do: {:error, "Choose a destination block."}
  defp command(%{target: :new, trip_ids: ids}), do: {:ok, {:assign, ids, :new}}
  defp command(%{target: :none, trip_ids: ids}), do: {:ok, {:unassign, ids}}
  defp command(%{target: target, trip_ids: ids}), do: {:ok, {:assign, ids, target}}

  defp assign_form(nil), do: nil

  defp assign_form(assign) do
    to_form(
      %{"search" => assign.search, "destination" => destination_value(assign.target)},
      as: :assign
    )
  end

  defp destination_value(nil), do: "new"
  defp destination_value(:new), do: "new"
  defp destination_value(:none), do: "none"
  defp destination_value(block_id), do: block_id

  # The destination options are the day type's own block IDs, filtered by a
  # case-insensitive substring, with an exact match first and at most 25 entries
  # (AC-26). `total` is the match count before the cap, so the form can say the
  # list was cut rather than pretending it is complete.
  defp destination_options(blocks, nil),
    do: {Enum.take(blocks, @destination_limit), length(blocks)}

  defp destination_options(blocks, search) do
    needle = search |> String.trim() |> String.downcase()

    matched =
      blocks
      |> Enum.filter(&String.contains?(String.downcase(&1.block_id), needle))
      |> Enum.sort_by(&(String.downcase(&1.block_id) != needle))

    {Enum.take(matched, @destination_limit), length(matched)}
  end

  defp destination_option(block) do
    %{block_id: block.summary.block_id, detail: destination_detail(block.summary)}
  end

  defp destination_detail(%{trip_count: count, start_secs: nil}), do: count_label(count)

  defp destination_detail(%{trip_count: count, start_secs: start, end_secs: finish}) do
    "#{count_label(count)} · #{BlocksComponents.clock(start)}–#{BlocksComponents.clock(finish)}"
  end

  defp count_label(1), do: "1 trip"
  defp count_label(count), do: "#{count} trips"

  # --- editor authority ------------------------------------------------------

  # The role is re-read from the membership on every mutating event, so a role
  # revoked while the page is open refuses the next write. This is the stricter
  # form of the `has_role?(@user_roles, :pathways_studio_editor)` check: the
  # assign is only a snapshot from mount (AC-31).
  defp editor_access?(socket) do
    EnsureRole.has_role?(live_roles(socket), :pathways_studio_editor)
  end

  defp live_roles(socket) do
    with %{id: user_id} <- socket.assigns[:current_user],
         %{id: organization_id} <- socket.assigns[:current_organization],
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(user_id, organization_id) do
      membership.roles || []
    else
      _ -> []
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

  defp pool_dom_id(trip), do: "pool-" <> Base.url_encode64(trip.trip_id, padding: false)

  # Each finding names trips by UUID, and the List view, the pool and the
  # untimed list print a trip's own findings. Grouping once per load keeps that
  # lookup out of the render path (CR-6).
  defp findings_by_trip(findings) do
    findings
    |> Enum.flat_map(fn finding -> Enum.map(finding.trip_ids, &{&1, finding}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

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
      in_seat: day.in_seat,
      mixed_timezones?: day.mixed_timezones?,
      trip_labels: trip_labels(day),
      findings_by_trip: findings_by_trip(day.findings),
      destination_blocks: Enum.map(day.blocks, &destination_option/1),
      untimed_trips: Enum.filter(day.unplottable, & &1.block_id)
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
      in_seat: %{},
      trip_view: nil,
      gap_view: nil,
      block_view: nil,
      back_block: nil,
      mixed_timezones?: false,
      trip_labels: %{},
      findings_by_trip: %{},
      destination_blocks: [],
      untimed_trips: [],
      visible_count: 0,
      timeline_key: nil,
      pool_visible_count: 0,
      pool_key: nil
    )
    |> stream(:block_rows, [], reset: true)
    |> stream(:list_rows, [], reset: true)
    |> stream(:pool_rows, [], reset: true)
  end

  # Each finding names trips by UUID; a deep link names them by their natural
  # trip ID, so the drawer maps one to the other without reading the day.
  defp trip_labels(day) do
    (Enum.flat_map(day.blocks, & &1.trips) ++ day.pool ++ day.unplottable)
    |> Map.new(&{&1.id, &1.trip_id})
  end

  @impl true
  def render(assigns) do
    {options, total} =
      destination_options(
        assigns.destination_blocks,
        assigns.assign && assigns.assign.search
      )

    assigns =
      assigns
      |> assign(:assign_form, assign_form(assigns.assign))
      |> assign(:destination_options, options)
      |> assign(:destination_total, total)

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

                <BlocksComponents.workspace
                  state={@state}
                  counts={@counts}
                  visible_count={@visible_count}
                  pool_visible_count={@pool_visible_count}
                  page_size={@page_size}
                  block_rows={@streams.block_rows}
                  list_rows={@streams.list_rows}
                  pool_rows={@streams.pool_rows}
                  untimed_trips={@untimed_trips}
                  findings_by_trip={@findings_by_trip}
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

                <%= case @trip_view do %>
                  <% {:trip, trip, day_types} -> %>
                    <BlocksComponents.trip_drawer
                      open={true}
                      trip={trip}
                      routes={@routes}
                      version_id={@state.version_id}
                      calendar_label={calendar_label(day_types)}
                      day_types={day_types}
                      findings={Map.get(@findings_by_trip, trip.id, [])}
                      in_seat={Map.get(@in_seat, trip.id, [])}
                      back_block={@back_block}
                      assign={@assign}
                      assign_form={@assign_form}
                      destination_options={@destination_options}
                      destination_total={@destination_total}
                    />
                  <% {:elsewhere, trip_id, day_types} -> %>
                    <BlocksComponents.trip_elsewhere
                      open={true}
                      trip_id={trip_id}
                      day_types={day_types}
                      version_id={@state.version_id}
                    />
                  <% {:unknown, trip_id} -> %>
                    <BlocksComponents.trip_elsewhere
                      open={true}
                      trip_id={trip_id}
                      version_id={@state.version_id}
                    />
                  <% _other -> %>
                <% end %>

                <%= if gap = @gap_view do %>
                  <BlocksComponents.gap_drawer
                    open={true}
                    from={gap.from}
                    to={gap.to}
                    gap={gap.gap}
                    block_id={gap.block_id}
                    records={gap.records}
                    short?={gap.short?}
                    back_block={@back_block}
                  />
                <% end %>

                <%= if block = @block_view do %>
                  <BlocksComponents.block_drawer
                    open={true}
                    block={block}
                    routes={@routes}
                    findings_by_trip={@findings_by_trip}
                  />
                <% end %>

                <BlocksComponents.review_dialog
                  review={@review}
                  stale?={@review_stale?}
                  error={@assign && @assign.error}
                  day_type={@day_type}
                  version_name={@current_gtfs_version.name}
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
