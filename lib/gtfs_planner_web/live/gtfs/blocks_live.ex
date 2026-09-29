defmodule GtfsPlannerWeb.Gtfs.BlocksLive do
  @moduledoc """
  LiveView for Operations › Blocks.

  Blocks shows which trips one vehicle works in sequence for a day type, and it
  is the only place a block is edited. This page owns the day-type scope, the
  whole-day count strip, the Service dates, Checks, Peak and Minimum layover
  drawers and every page state; the timeline, the List view, the unassigned pool
  and the trip, gap and block drawers render inside the same page.

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

  `drawer=driving_times&pair=stop:<id>|stop:<id>` and `drawer=operator_changes`
  are the planning-input drawers the gap drawer links to (AC-38). They are page
  drawers rather than a stack entry, so the link that opens one clears the stack:
  one open panel over the page, and a link that reopens the same drawer.
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

  @drawers %{
    "service_dates" => :service_dates,
    "checks" => :checks,
    "problems" => :checks,
    # The plan figures send `plan_summary` (AC-34, AC-35). The old `peak` key
    # maps to the same drawer so an older link still opens the page's plan
    # summary rather than a drawer that no longer exists.
    "plan_summary" => :plan_summary,
    "peak" => :plan_summary,
    # The two planning-input drawers are reached from a link that names them in
    # the URL, so `?drawer=driving_times&pair=…` opens the same drawer a click
    # does (step 41, step 42). Nothing renders them until those steps build them.
    "driving_times" => :driving_times,
    "operator_changes" => :operator_changes
  }

  # The settings save keeps the reader's value when the save is refused, so the
  # sentence names the value rather than a generic failure.
  @layover_save_failed "The minimum could not be saved. Your value is retained. Try again."

  @sort_keys %{
    "block" => :block,
    "garage" => :garage,
    "out" => :out,
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
  @empty_figures %{vehicles: 0, minimum: 0, riders: 0}

  # The Plan summary's chart counts the same 15-minute bins as the day load's own
  # `bins`, so the width is one constant rather than two that could drift.
  @bin_secs 900

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
     |> assign(:layover, %{params: %{}, error: nil})
     |> assign(:block_attributes, nil)
     |> assign_empty_derived()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    state = parse_state(params, socket.assigns.current_gtfs_version)

    {:noreply,
     socket
     |> assign(:state, state)
     |> ensure_day_loaded()
     |> resolve_drawers()
     |> assign_page_rows_if_loaded()}
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
    route = blank_to_nil(params["route"])

    # AC-24: a route filter keeps only the selected trips that run on that route.
    # The selection is not in the URL, so it is pruned before the patch and both
    # stream keys carry it, which re-sends the page with its new checked state.
    socket =
      socket
      |> assign(:selection, retain_on_route(socket, route))
      |> assign_selected_trips()

    patch(socket, %{route: route, status: status, page: 1, pool_page: 1})
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

  # The row checkbox toggles one trip by its UUID, so the selection survives a
  # page change and a trip that leaves the page keeps its place in it (AC-24).
  def handle_event("toggle_trip", %{"trip" => trip_id}, socket) do
    case find_day_trip(socket.assigns.day, trip_id) do
      nil ->
        {:noreply, socket}

      trip ->
        {:noreply, put_selection(socket, toggle_selection(socket.assigns.selection, trip.id))}
    end
  end

  def handle_event("toggle_trip", _params, socket), do: {:noreply, socket}

  # “Select this page” adds every trip the current pool page or List page holds
  # to the selection, so a large selection is built a page at a time (AC-24).
  def handle_event("select_page", _params, socket) do
    selection = MapSet.union(socket.assigns.selection, visible_page_ids(socket.assigns))

    {:noreply, put_selection(socket, selection)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, put_selection(socket, MapSet.new())}
  end

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

  # The bulk bar opens the same form for the whole selection. The selection scope
  # previews its ineligible trips from their own flags, so a repeating or untimed
  # trip is named before the reader submits rather than silently dropped — and
  # the apply still refuses the command if eligibility is all that changed
  # (R10, FH-18). “Use eligible trips” drops them and keeps the dialog open on
  # what remains (AC-24).
  def handle_event("open_assign", %{"scope" => "selection", "eligible" => "true"}, socket) do
    {:noreply, use_eligible_selection(socket)}
  end

  def handle_event("open_assign", %{"scope" => "selection"}, socket) do
    case socket.assigns.selected_trips do
      [] -> {:noreply, socket}
      trips -> {:noreply, assign(socket, :assign, new_selection_assign(trips))}
    end
  end

  def handle_event("open_assign", _params, socket), do: {:noreply, socket}

  # One search event serves both pickers: the assignment form's and the block
  # drawer's merge form. The change event belongs to the form, so the handler
  # keeps the checked radio as well as the narrowed search (the form is
  # re-rendered on every event). The two forms can both be on the page, so the
  # payload key decides which one the search belongs to.
  def handle_event("search_destination", params, socket) do
    cond do
      socket.assigns.block_action && Map.has_key?(params, "block_action") ->
        {:noreply, save_block_action(socket, params)}

      socket.assigns.assign ->
        {:noreply, assign(socket, :assign, put_form_params(socket.assigns.assign, params))}

      true ->
        {:noreply, socket}
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

  # The block drawer's three actions (AC-27). The block a command acts on comes
  # from the loaded day's own drawer and a remove-all's trip IDs from the same
  # block, so a crafted event can never name another block or trip (CR-4); the
  # submit then runs the same reviewed command path as an assignment (CL-18).
  def handle_event("submit_block_action", params, socket) do
    case socket.assigns.block_action do
      nil ->
        {:noreply, socket}

      action ->
        action = put_block_action_params(action, params)

        case block_command(action) do
          {:ok, command} ->
            run_command(assign(socket, :block_action, action), command, nil)

          {:error, message} ->
            {:noreply, assign(socket, :block_action, %{action | error: message})}
        end
    end
  end

  # A change recomputes the preview from the loaded day types and drops the
  # refusal, so a reader who answers the inline error sees the preview for the
  # value they just chose rather than a stale sentence.
  def handle_event("block_attributes_change", params, socket) do
    {:noreply, put_block_attributes(socket, params, nil)}
  end

  # The one attribute write this drawer offers (AC-37). The form exists only on a
  # loaded day type with a block open, so a submit from another page state is not
  # a save; the context then validates, locks and decides the confirmation.
  def handle_event("save_block_attributes", _params, %{assigns: %{day_type: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_block_attributes", params, socket) do
    socket = put_block_attributes(socket, params, nil)

    case socket.assigns.block_attributes do
      nil -> {:noreply, socket}
      attributes -> submit_block_attributes(socket, attributes)
    end
  end

  # “Remove from block” runs the same reviewed command path as an assignment, so
  # a removal that adds a problem opens the review too (R10, AC-26). The bulk bar
  # removes every blocked trip of the selection; the ones already in the pool are
  # not part of the command (AC-24).
  def handle_event("unassign", %{"scope" => "trip", "trip" => trip_id}, socket) do
    case find_day_trip(socket.assigns.day, trip_id) do
      nil -> {:noreply, socket}
      trip -> run_command(socket, {:unassign, [trip.id]}, nil)
    end
  end

  def handle_event("unassign", %{"scope" => "selection"}, socket) do
    case blocked_selected_ids(socket) do
      [] -> {:noreply, socket}
      ids -> run_command(socket, {:unassign, ids}, nil)
    end
  end

  def handle_event("unassign", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_review", _params, socket) do
    case socket.assigns.review do
      %{command: command, fingerprint: fingerprint} ->
        run_reviewed(socket, command, fingerprint)

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

  # The Minimum layover drawer's field sends its change event through the same
  # fixed event name as its opener (CR-8): the value the reader typed is kept and
  # re-validated, so the field error appears before a save rather than only after
  # one (AC-28). The opener itself sends only a key and starts from the stored
  # value, so re-opening the drawer never shows a previous refusal.
  def handle_event("open_drawer", %{"layover" => values} = params, socket) when is_map(values) do
    {:noreply, put_layover(socket, layover_params(params), nil)}
  end

  # The two planning-input drawers are part of the URL, because a link names what
  # it opens: the gap drawer's “Enter a known driving time” names the pair it is
  # about, so the drawer can highlight and focus that row (AC-38, step 41). They
  # are page drawers, so the drawer stack is dropped rather than stacked under
  # them — the reference opens one drawer over another, and two open panels would
  # cover the page twice.
  def handle_event("open_drawer", %{"key" => key} = params, socket)
      when key in ["driving_times", "operator_changes"] do
    patch(socket, %{
      trip: nil,
      gap: nil,
      block: nil,
      drawer: key,
      pair: blank_to_nil(params["pair"])
    })
  end

  def handle_event("open_drawer", %{"key" => key}, socket) do
    case key do
      "unassigned" ->
        if socket.assigns.counts.unassigned > 0 do
          patch(socket, %{panel: :pool, pool_page: 1}, clear_selection: true)
        else
          {:noreply, socket}
        end

      "layover" ->
        {:noreply, socket |> put_layover(%{}, nil) |> assign(:open_drawer, :layover)}

      key ->
        case Map.fetch(@drawers, key) do
          {:ok, drawer} -> {:noreply, assign(socket, :open_drawer, drawer)}
          :error -> {:noreply, socket}
        end
    end
  end

  # `spec.md` names the payload `drawer`; the page's own controls send `key`.
  # Both open the same drawer through the reader above, so a later control
  # written to the spec's letter is not silently swallowed. Mirrors the
  # catch-all on `set_panel` / `set_view` / `set_scale`.
  def handle_event("open_drawer", %{"drawer" => key}, socket),
    do: handle_event("open_drawer", %{"key" => key}, socket)

  def handle_event("open_drawer", _params, socket), do: {:noreply, socket}

  # The trip, gap and block drawers are part of the URL, so closing one drops the
  # parameters as well as the panel-only drawer's own state; the other drawers
  # keep the URL they had. The panel drawers render over the page, so one of them
  # opens alongside whichever URL drawer the page had.
  def handle_event("close_drawer", _params, socket) do
    socket = assign(socket, :open_drawer, nil)

    socket =
      if match?(%{scope: :selection}, socket.assigns.assign),
        do: assign(socket, :assign, nil),
        else: socket

    state = socket.assigns.state

    if state.trip || state.gap || state.block || state.drawer || state.pair do
      patch(socket, %{trip: nil, gap: nil, block: nil, drawer: nil, pair: nil},
        clear_command: true
      )
    else
      {:noreply, socket}
    end
  end

  # The one write in the Minimum layover drawer (AC-28). The drawer only exists
  # on a loaded day type and only its own field is read, so a submit from another
  # page state or without a value is not a save. `save_layover/2` then re-reads
  # the role first, like `run_command/3` (AC-31), lets the context validate the
  # value rather than re-deriving that here, and reloads the day so the layover
  # warnings and the Problems count use the new minimum (AC-5). A field error
  # keeps the drawer and the reader's value; a version that is no longer
  # published keeps both with the drawer's own sentence.
  def handle_event("save_layover", _params, %{assigns: %{day_type: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_layover", params, socket) do
    case layover_params(params) do
      %{"min_layover_minutes" => _value} = attrs -> save_layover(socket, attrs)
      # The field is the whole form, so a submit that carries no value at all (a
      # crafted event, or a payload of another shape) is not a save.
      _no_value -> {:noreply, socket}
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

  def handle_event("open_block", _params, socket), do: {:noreply, socket}

  def handle_event("retry", _params, socket) do
    {:noreply, socket |> load_day() |> resolve_drawers() |> assign_page_rows_if_loaded()}
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
      if Keyword.get(opts, :clear_selection, false) do
        socket
        |> assign(:selection, MapSet.new())
        |> assign_selected_trips()
      else
        socket
      end

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
      block: blank_to_nil(params["block"]),
      drawer: blank_to_nil(params["drawer"]),
      pair: blank_to_nil(params["pair"])
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
      {"block", state.block},
      {"drawer", state.drawer},
      {"pair", state.pair}
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
        socket

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
  # holds the panel and the view as well as the filters, the page and the
  # selection: a container the client holds is replaced when any of them changes,
  # and a replaced stream container is empty until the page is sent again, so the
  # reset must happen on that change too. The selection is in the key because a
  # checkbox is rendered inside its row, so a selection change re-sends the page
  # with the new checked state (AGENTS.md streams rule). `load_day/1` and the
  # empty states clear the key, so a reload always resends.
  defp assign_timeline(socket) do
    %{state: state} = socket.assigns
    visible = visible_blocks(socket.assigns.day.blocks, state)
    page = effective_page(state.page, length(visible))
    rows = visible |> Enum.drop((page - 1) * @page_size) |> Enum.take(@page_size)

    key =
      {state.panel, state.view, state.route, state.status, state.sort, state.dir, page,
       socket.assigns.selection}

    socket =
      assign(socket,
        visible_count: length(visible),
        timeline_page_ids: page_trip_ids(rows, state.route)
      )

    if socket.assigns.timeline_key == key do
      socket
    else
      socket
      |> assign(:timeline_key, key)
      |> stream(:block_rows, rows, reset: true)
      |> stream(:list_rows, rows, reset: true)
    end
  end

  # The visible page of the pool: the route filter over the pool's own order
  # (first departure, then untimed trips by trip ID), then one page of 100 rows,
  # streamed so a filter, a page or the selection replaces the container. The key
  # holds the panel because the pool table exists only while the Unassigned panel
  # is shown, and a stream container that is replaced must be filled again; the
  # selection is in the key for the same reason as the List view's rows.
  defp assign_pool(socket) do
    %{state: state} = socket.assigns
    visible = visible_pool(socket.assigns.day.pool, state.route)
    page = effective_page(state.pool_page, length(visible))
    rows = visible |> Enum.drop((page - 1) * @page_size) |> Enum.take(@page_size)
    key = {state.panel, state.route, page, socket.assigns.selection}

    socket =
      assign(socket,
        pool_visible_count: length(visible),
        pool_page_ids: MapSet.new(rows, & &1.id)
      )

    if socket.assigns.pool_key == key do
      socket
    else
      socket
      |> assign(:pool_key, key)
      |> stream(:pool_rows, rows, reset: true)
    end
  end

  defp visible_pool(pool, nil), do: pool
  defp visible_pool(pool, route_id), do: Enum.filter(pool, &(&1.route_id == route_id))

  # The page's own trip UUIDs: every trip of the page's blocks the route filter
  # keeps, which is exactly the List view's rows. A trip of another route is not
  # a row on the page, so it is neither selected nor counted as elsewhere.
  defp page_trip_ids(blocks, route_id) do
    blocks
    |> Enum.flat_map(& &1.trips)
    |> Enum.filter(&(is_nil(route_id) or &1.route_id == route_id))
    |> MapSet.new(& &1.id)
  end

  # Both streamed pages are re-derived together, so the timeline, the List view
  # and the pool stay in step on a day, filter, page or selection change.
  defp assign_page_rows(socket), do: socket |> assign_timeline() |> assign_pool()

  # The page is streamed once each cycle, after the drawer resolution has had its
  # chance to move it (`trip=`, `gap=` and `block=` override the requested page).
  # Streaming in `load_day/1` as well would queue the first page and then the
  # overriding one, and a stream reset never discards inserts already queued in
  # the same render, so both pages would render (AC-29).
  defp assign_page_rows_if_loaded(%{assigns: %{day: nil}} = socket), do: socket
  defp assign_page_rows_if_loaded(socket), do: assign_page_rows(socket)

  # --- the cross-page selection (step 26) --------------------------------------

  # The selection is a MapSet of trip UUIDs, so it survives a page change, a
  # panel change and a sort; it is not in the URL, so a reload starts empty and
  # the page clears it on a day or version change (AC-24). `selected_trips` is the
  # same selection resolved against the loaded day, which is what the bar counts,
  # the eligibility preview and the bulk commands read — an id the day no longer
  # holds is never counted, and every streamed row is re-sent when the selection
  # changes because the checkbox is rendered inside its row (AGENTS.md streams
  # rule).
  defp put_selection(%{assigns: %{day: nil}} = socket, _selection), do: socket

  defp put_selection(socket, selection) do
    socket
    |> assign(:selection, selection)
    |> assign_selected_trips()
    |> assign_page_rows()
  end

  defp assign_selected_trips(socket) do
    assign(socket, :selected_trips, selected_trips(socket.assigns.day, socket.assigns.selection))
  end

  defp selected_trips(nil, _selection), do: []

  defp selected_trips(day, selection) do
    day
    |> day_trips()
    |> Enum.filter(&MapSet.member?(selection, &1.id))
  end

  # A day holds every trip of its day type exactly once: in the block named by
  # its `block_id` or in the pool (AC-2).
  defp day_trips(day), do: Enum.flat_map(day.blocks, & &1.trips) ++ day.pool

  defp toggle_selection(selected, id) do
    if MapSet.member?(selected, id),
      do: MapSet.delete(selected, id),
      else: MapSet.put(selected, id)
  end

  # A route filter keeps only the selected trips that run on that route; clearing
  # the filter keeps the whole selection (AC-24).
  defp retain_on_route(socket, nil), do: socket.assigns.selection

  defp retain_on_route(socket, route_id) do
    socket.assigns.selected_trips
    |> Enum.filter(&(&1.route_id == route_id))
    |> MapSet.new(& &1.id)
  end

  # A selection only ever resolves against a loaded day, but a reload can drop a
  # trip the previous day type held; the pruned set is what the bar then counts.
  defp retain_in_day(selection, day) do
    if MapSet.size(selection) == 0 do
      selection
    else
      MapSet.intersection(selection, MapSet.new(day_trips(day), & &1.id))
    end
  end

  # The trips the current page holds: the pool's own page in the Unassigned panel
  # and the page's blocks' trips in the Blocks panel, where the List view's rows
  # and the timeline's bars are the same page of blocks (AC-24).
  defp visible_page_ids(%{state: %{panel: :pool}} = assigns), do: assigns.pool_page_ids
  defp visible_page_ids(assigns), do: assigns.timeline_page_ids

  # What the selection bar prints: the whole selection, how much of it the
  # current page does not hold (“1 on other pages”), and whether any selected
  # trip still has a block, because only those can be removed.
  defp bulk_summary(assigns) do
    selected = assigns.selected_trips
    visible = visible_page_ids(assigns)

    %{
      count: length(selected),
      elsewhere: Enum.count(selected, &(not MapSet.member?(visible, &1.id))),
      removable?: Enum.any?(selected, & &1.block_id)
    }
  end

  # The selection's affected dates: every date of every day type one of the
  # selected trips runs in, summed the way the review's effect cards count them,
  # so the bulk form's scope line means the same thing as the trip form's
  # (AC-24).
  defp selection_dates(assigns) do
    services = MapSet.new(assigns.selected_trips, & &1.service_id)

    assigns.day_types
    |> Enum.filter(fn day_type ->
      Enum.any?(day_type.service_ids, &MapSet.member?(services, &1))
    end)
    |> Enum.map(& &1.date_count)
    |> Enum.sum()
  end

  # The trips of the selection that still have a block on this day type: the bulk
  # bar's “Remove from block” command names exactly those (AC-24).
  defp blocked_selected_ids(socket) do
    socket.assigns.selected_trips
    |> Enum.filter(& &1.block_id)
    |> Enum.map(& &1.id)
  end

  # “Change selection” returns focus to whichever opener the reader used: the
  # bulk bar's “Assign N trips” for a selection, the trip drawer's own control
  # for one trip, and the block drawer's own control for one of its three
  # actions (AC-27).
  defp review_focus(%{assign: %{scope: :selection}}), do: "bulk-assign"
  defp review_focus(%{assign: %{scope: :trip}}), do: "trip-change-assignment"
  defp review_focus(%{block_action: %{kind: :rename}}), do: "block-rename-id"
  defp review_focus(%{block_action: %{kind: :merge}}), do: "block-merge-search"
  defp review_focus(%{block_attributes: %{block_id: _}}), do: "block-garage"
  defp review_focus(%{block_action: %{kind: :remove_all}}), do: "block-remove-all"
  defp review_focus(_assigns), do: "trip-change-assignment"

  # “Use eligible trips” drops every ineligible trip from the selection and keeps
  # the dialog open on the rest; a selection left with nothing to assign closes
  # the dialog, because there is nothing left to choose a destination for.
  defp use_eligible_selection(socket) do
    eligible = Enum.filter(socket.assigns.selected_trips, &BlocksComponents.eligible?/1)
    socket = put_selection(socket, MapSet.new(eligible, & &1.id))

    case eligible do
      [] -> assign(socket, :assign, nil)
      trips -> assign(socket, :assign, new_selection_assign(trips))
    end
  end

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
        gap = resolve_gap(day, state.gap, not is_nil(socket.assigns.max_piece_minutes))
        {socket, trip} = resolve_trip_view(socket, day, state.trip)

        socket
        |> assign(:trip_view, trip)
        |> assign(:gap_view, if(is_nil(trip), do: gap))
        |> assign(:block_view, if(is_nil(trip) and is_nil(gap), do: block))
        |> assign(:back_block, if(block, do: block.summary.block_id))
        |> assign(:open_drawer, Map.get(@drawers, state.drawer) || socket.assigns.open_drawer)
        |> assign(:block_action, block_action_state(socket.assigns.block_action, block))
        |> assign(
          :block_attributes,
          block_attributes_state(socket.assigns.block_attributes, block)
        )

      _other ->
        assign(socket,
          trip_view: nil,
          gap_view: nil,
          block_view: nil,
          back_block: nil,
          block_action: nil,
          block_attributes: nil
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
  # block's own gap entry (R5's handoff and the layover seconds), the block's own
  # movement for that gap (its drive, its source and the wait behind it) and the
  # relief windows of that same gap, so neither is recomputed or re-derived here.
  # Operator changes are read as "checked" only while a relief limit is set, which
  # is the same rule the timeline's own relief mark follows.
  defp resolve_gap(_day, nil, _relief_checked?), do: nil

  defp resolve_gap(day, gap, relief_checked?) do
    case String.split(gap, "|") do
      [from_id, to_id] -> find_gap(day, from_id, to_id, relief_checked?)
      _other -> nil
    end
  end

  defp find_gap(day, from_id, to_id, relief_checked?) do
    Enum.find_value(day.blocks, fn block ->
      gap_entry(day, block, from_id, to_id, relief_checked?)
    end)
  end

  defp gap_entry(day, block, from_id, to_id, relief_checked?) do
    with from when not is_nil(from) <- Enum.find(block.trips, &(&1.id == from_id)),
         to when not is_nil(to) <- Enum.find(block.trips, &(&1.id == to_id)),
         gap when not is_nil(gap) <-
           Enum.find(block.gaps, &(&1.from_id == from_id and &1.to_id == to_id)) do
      {movement, index} = movement_gap(block, from_id, to_id)

      %{
        block_id: block.summary.block_id,
        from: from,
        to: to,
        gap: gap,
        movement: movement,
        windows: if(index, do: Enum.filter(block.windows, &(&1.gap_index == index)), else: []),
        relief_checked?: relief_checked?,
        day_label: day.day_type && day.day_type.label,
        records: pair_records(day.in_seat, from, to),
        short?: short_layover?(block, from_id, to_id)
      }
    else
      _other -> nil
    end
  end

  # The block's own movement for the pair and the index its relief windows carry.
  # The windows name their gap by that index, so the drawer reads the two together
  # rather than matching a window's trip IDs that it does not hold.
  defp movement_gap(block, from_id, to_id) do
    block.movements.gaps
    |> Enum.with_index()
    |> Enum.find(fn {movement, _index} ->
      movement.from_id == from_id and movement.to_id == to_id
    end)
    |> case do
      nil -> {nil, nil}
      {movement, index} -> {movement, index}
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
    day |> day_trips() |> Enum.find(&(&1.trip_id == trip_id))
  end

  defp find_day_trip_by_id(nil, _id), do: nil

  defp find_day_trip_by_id(day, id) do
    day |> day_trips() |> Enum.find(&(&1.id == id))
  end

  # The page holding the trip: its block's own panel and page for a blocked trip,
  # the pool's for an unassigned one. An unassigned trip is rendered by the pool
  # panel alone, so following one there — after an unassign, or through a `trip=`
  # deep link (AC-26, AC-29) — switches the panel as well as the page, and the
  # reverse switch names the Blocks panel again once the trip is in a block. The
  # same visible order the page slices decides the page, so the resolved page is
  # the one that renders the trip; a filter that hides it leaves the requested
  # page in place.
  defp override_trip_page(socket, trip) do
    %{state: state, day: day} = socket.assigns

    state =
      if is_nil(trip.block_id) do
        override_page(
          %{state | panel: :pool, page: 1},
          :pool_page,
          visible_pool(day.pool, state.route),
          & &1.id,
          trip.id
        )
      else
        block_ids = Enum.map(visible_blocks(day.blocks, state), & &1.summary.block_id)
        override_page(%{state | panel: :blocks}, :page, block_ids, & &1, trip.block_id)
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

  # The trip's calendar label: a day type whose only service is this trip's
  # calendar names that calendar; when no such day type exists the row names the
  # service id rather than a joined day-type label. The day load carries no
  # per-service name, so this derives the label from the same day types every
  # other surface prints.
  defp calendar_label(day_types, trip) do
    case Enum.find(day_types, &(&1.service_ids == [trip.service_id])) do
      %{label: label} -> label
      nil -> trip.service_id
    end
  end

  # --- reviewed block commands (step 25) --------------------------------------

  # A confirmed review re-runs the command the review carries, so a confirmation
  # writes exactly what was reviewed. An attribute save is one of those commands
  # (`{:attributes, block_id, garage_id, vehicle_type_id}`, R12), so it takes the
  # same path as an assignment rather than a second reviewed implementation.
  defp run_reviewed(socket, {:attributes, block_id, garage_id, vehicle_type_id}, confirmation) do
    run_attributes(socket, block_id, garage_id, vehicle_type_id, confirmation)
  end

  defp run_reviewed(socket, command, confirmation), do: run_command(socket, command, confirmation)

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
    |> assign_page_rows_if_loaded()
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
      [_first | _rest] -> "their blocks"
      [] -> "its block"
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
    socket =
      case socket.assigns.assign do
        nil -> socket
        assign -> assign(socket, :assign, %{assign | error: nil, ineligible: []})
      end

    socket =
      case socket.assigns.block_action do
        nil -> socket
        action -> assign(socket, :block_action, %{action | error: nil})
      end

    case socket.assigns.block_attributes do
      nil -> socket
      attributes -> assign(socket, :block_attributes, %{attributes | error: nil})
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
  # changes, so a retry repeats exactly the reviewed command (AC-26). A block
  # drawer action keeps its own control's sentence and the value the reader
  # typed (AC-27).
  defp refuse(socket, reason) do
    message = command_error(reason, socket.assigns.block_action)

    cond do
      socket.assigns.assign ->
        assign(socket, :assign, %{socket.assigns.assign | error: message})

      socket.assigns.block_action ->
        assign(socket, :block_action, %{socket.assigns.block_action | error: message})

      true ->
        put_flash(socket, :error, message)
    end
  end

  defp command_error(:busy, _state), do: "Another change is being saved. Try again."
  defp command_error(:not_found, _state), do: "That trip isn't in this version."
  defp command_error(:unknown_day_type, _state), do: "This day type isn't in this version."

  # A rename onto the block's own ID is the one `:invalid_command` the drawer can
  # cause, and it gets its own sentence (AC-27).
  defp command_error(:invalid_command, %{kind: :rename, block_id: block_id, rename: value})
       when is_binary(value) do
    if String.trim(value) == block_id,
      do: "Enter a different block ID.",
      else: "That change isn't valid."
  end

  defp command_error(:invalid_command, _state), do: "That change isn't valid."

  defp command_error(:invalid_block_id, _state),
    do: "Enter a block ID of 1 to 255 characters."

  # A taken ID names the ID the reader typed, so the sentence says which one to
  # change (AC-27).
  defp command_error(:block_id_taken, %{kind: :rename, rename: value}) when is_binary(value),
    do: "Block #{String.trim(value)} already runs on these dates. Choose another ID or merge."

  defp command_error(:block_id_taken, _state),
    do: "That block ID already runs on these dates. Choose another ID or merge."

  defp command_error(:too_many_trips, _state), do: "This change touches too many trips."

  defp command_error({:audit_failed, _reason}, _state),
    do: "The change couldn't be saved. Nothing was written."

  defp command_error(_reason, _state), do: "The change couldn't be saved. Try again."

  # The sentence a review shows above itself when the confirmation failed: the
  # pending form's own failure, whichever form opened the review (AC-26, AC-27).
  defp pending_error(%{assign: %{error: error}}) when is_binary(error), do: error
  defp pending_error(%{block_action: %{error: error}}) when is_binary(error), do: error
  defp pending_error(%{block_attributes: %{error: error}}) when is_binary(error), do: error
  defp pending_error(_assigns), do: nil

  # --- the block's garage and vehicle type (step 38) --------------------------

  # The drawer's own state, rebuilt from the loaded block whenever that block
  # changes (a day-type switch, a reload or another writer's trip), so the two
  # pickers start on the resolution the day load already made and never on a
  # previous block's values. A block whose calendars disagree has no single
  # garage to start on, so the picker starts on the prompt and the save asks for
  # one (AC-37, R4).
  defp block_attributes_state(_state, nil), do: nil

  defp block_attributes_state(%{block_id: block_id} = state, %{summary: %{block_id: block_id}}),
    do: state

  defp block_attributes_state(_state, %{summary: %{block_id: block_id}} = block) do
    %{garage_id: garage_id, vehicle_type_id: type_id} = block.resolution

    %{
      block_id: block_id,
      garage_id: if(block.resolution.conflict, do: "", else: garage_id || ""),
      vehicle_type_id: type_id || "",
      error: nil
    }
  end

  defp block_attributes_form(nil), do: nil

  defp block_attributes_form(attributes) do
    to_form(
      %{"garage_id" => attributes.garage_id, "vehicle_type_id" => attributes.vehicle_type_id},
      as: :block_attributes
    )
  end

  # A block whose calendars name different garages has no garage to save, and the
  # context would store `nil` for it and resolve the block from its route instead.
  # That is a different plan from the one on screen, so the save is refused here
  # with the sentence under the field and focus on the picker (AC-37). Every
  # other value goes to the context, which owns the validation, the lock and the
  # confirmation decision (AC-19, INV-7).
  defp submit_block_attributes(
         %{assigns: %{block_view: %{resolution: %{conflict: [_ | _]}}}} = socket,
         %{garage_id: ""}
       ) do
    {:noreply,
     socket
     |> assign(
       :block_attributes,
       %{socket.assigns.block_attributes | error: "Choose one garage for this block."}
     )
     |> push_event("focus_scoped_target", %{id: "block-garage"})}
  end

  defp submit_block_attributes(socket, attributes) do
    run_attributes(
      socket,
      attributes.block_id,
      attributes.garage_id,
      attributes.vehicle_type_id,
      nil
    )
  end

  defp run_attributes(
         %{assigns: %{day_type: nil}} = socket,
         _block,
         _garage,
         _type,
         _confirmation
       ),
       do: {:noreply, socket}

  # The one attribute write this drawer offers (AC-37). It runs on the same
  # reviewed path as every other apply on the page: the editor role is re-read
  # from the membership first, the audit context comes from the socket and the
  # block from the loaded drawer's own resolution, so a crafted event can never
  # name another block (CR-4). The context then takes the version lock, rebuilds
  # the context under it and decides the confirmation (AC-19, INV-7).
  defp run_attributes(socket, block_id, garage_id, vehicle_type_id, confirmation) do
    if editor_access?(socket) do
      case Gtfs.set_block_attributes(
             socket.assigns.day_type.key,
             block_id,
             %{"garage_id" => garage_id, "vehicle_type_id" => vehicle_type_id},
             audit_context(socket),
             confirmation
           ) do
        {:ok, _result} -> {:noreply, attributes_applied(socket, block_id)}
        {:needs_confirmation, review} -> {:noreply, show_review(socket, review, false)}
        {:error, {:stale_review, review}} -> {:noreply, show_review(socket, review, true)}
        {:error, reason} -> {:noreply, refuse_attributes(socket, reason)}
      end
    else
      {:noreply, put_flash(socket, :error, @permission_message)}
    end
  end

  # A saved attribute reloads the day so the block's own resolution, its garage
  # travel and the row's Garage · type cell all read the row that was just
  # written (INV-9), and drops the review. The patch takes the block out of the
  # URL, which closes the drawer and leaves the reader looking at the row the
  # flash names; the reference has no post-save state of its own, so closing is
  # this page's existing rule for a command the drawer owns (AC-37).
  #
  # This pushes the patch itself rather than going through `patch/3`, which
  # returns the `{:noreply, socket}` tuple its callers hand straight back to
  # `handle_event/3`; wrapping that again crashes the LiveView after the write
  # has already landed.
  defp attributes_applied(socket, block_id) do
    socket
    |> load_day()
    |> resolve_drawers()
    |> assign(:review, nil)
    |> assign(:review_stale?, false)
    |> assign(:block_attributes, nil)
    |> put_flash(:info, "Block #{block_id} saved")
    |> then(&push_patch(&1, to: blocks_path(Map.merge(&1.assigns.state, %{block: nil}))))
  end

  # A refused save keeps the form, its values and its review, so a retry repeats
  # exactly the reviewed save; only the sentence changes (AC-26, AC-37).
  defp refuse_attributes(socket, reason) do
    message = command_error(reason, nil)

    case socket.assigns.block_attributes do
      nil -> put_flash(socket, :error, message)
      attributes -> assign(socket, :block_attributes, %{attributes | error: message})
    end
  end

  # The form sends its two fields as `block_attributes[...]`; a value that is not
  # a string (a crafted event, or a repeated parameter) keeps the one on screen
  # rather than reaching the context.
  defp put_block_attributes(socket, params, error) do
    case socket.assigns.block_attributes do
      nil ->
        socket

      attributes ->
        values = block_attributes_params(params)

        assign(socket, :block_attributes, %{
          attributes
          | garage_id: block_attributes_string(values["garage_id"], attributes.garage_id),
            vehicle_type_id:
              block_attributes_string(values["vehicle_type_id"], attributes.vehicle_type_id),
            error: error
        })
    end
  end

  defp block_attributes_params(%{"block_attributes" => values}) when is_map(values), do: values
  defp block_attributes_params(params), do: params

  defp block_attributes_string(value, _current) when is_binary(value), do: value
  defp block_attributes_string(_value, current), do: current

  # --- the assignment form (step 25) -----------------------------------------

  defp new_assign(trip), do: new_assign(:trip, [trip])

  # A selection-scoped form holds the whole selection: its trip count (which the
  # form's own line already prints), whether any of its trips has a block to
  # remove, and the ineligible trips their own flags refuse, named before any
  # submit (AC-24).
  defp new_selection_assign(trips), do: new_assign(:selection, trips)

  defp new_assign(scope, trips) do
    %{
      scope: scope,
      trips: trips,
      trip_ids: Enum.map(trips, & &1.id),
      blocked?: Enum.any?(trips, & &1.block_id),
      target: nil,
      search: "",
      error: nil,
      ineligible: trips |> Enum.reject(&BlocksComponents.eligible?/1) |> Enum.map(& &1.id)
    }
  end

  defp put_form_params(assign, params) do
    values =
      case Map.get(params, "assign") do
        %{} = values -> values
        _ -> %{}
      end

    %{
      assign
      | search: block_action_string(Map.get(values, "search"), assign.search),
        target: destination_target(Map.get(values, "destination"), assign.target)
    }
  end

  defp destination_target("new", _current), do: :new
  defp destination_target("none", _current), do: :none
  defp destination_target(block_id, _current) when is_binary(block_id), do: block_id
  defp destination_target(_value, current), do: current

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

  # --- the block drawer's actions (step 27) ----------------------------------

  # The drawer's three actions share one state, rebuilt from the loaded day's own
  # block whenever that block or its trips change (a day-type switch, a reload or
  # another writer's trip). The trip IDs a remove-all unassigns come from that
  # block, so no parameter names them (CR-4), and the rename field starts on the
  # block's own ID, so resubmitting it unchanged is the “Enter a different block
  # ID.” case rather than a silent no-op (AC-27).
  defp block_action_state(_action, nil), do: nil

  defp block_action_state(action, %{summary: %{block_id: block_id}} = block) do
    trip_ids = Enum.map(block.trips, & &1.id)

    if match?(%{block_id: ^block_id, trip_ids: ^trip_ids}, action) do
      action
    else
      %{
        block_id: block_id,
        trip_ids: trip_ids,
        kind: nil,
        rename: block_id,
        merge: "",
        search: "",
        error: nil
      }
    end
  end

  defp save_block_action(socket, params) do
    assign(socket, :block_action, put_block_action_params(socket.assigns.block_action, params))
  end

  # The two forms send their fields as `block_action[...]` and the remove-all
  # button sends `phx-value-action`, so one payload shape is read here. A value
  # that is not a string (a crafted event, or a repeated parameter) is ignored
  # rather than passed on to the context.
  defp put_block_action_params(action, params) do
    values = Map.merge(block_action_params(params), Map.take(params, ["action"]))

    %{
      action
      | kind: block_action_kind(values["action"]) || action.kind,
        rename: block_action_string(values["block_id"], action.rename),
        merge: block_action_string(values["destination"], action.merge),
        search: block_action_string(values["search"], action.search)
    }
  end

  defp block_action_params(%{"block_action" => values}) when is_map(values), do: values
  defp block_action_params(params), do: params

  defp block_action_string(value, _current) when is_binary(value), do: value
  defp block_action_string(_value, current), do: current

  defp block_action_kind("rename"), do: :rename
  defp block_action_kind("merge"), do: :merge
  defp block_action_kind("remove_all"), do: :remove_all
  defp block_action_kind(_action), do: nil

  # The three actions are the context's own commands (Mutation): a rename trims
  # its ID here (the context trims again and refuses an empty or over-long one),
  # a merge joins an ID the picker offered, and remove-all unassigns the block's
  # trips on the selected day type. An action with no destination or no kind is
  # refused with the shared sentence instead of reaching the context.
  defp block_command(%{kind: :rename, block_id: block_id, rename: value})
       when is_binary(value),
       do: {:ok, {:rename, block_id, String.trim(value)}}

  defp block_command(%{kind: :merge, block_id: block_id, merge: destination})
       when is_binary(destination) and destination != "",
       do: {:ok, {:merge, block_id, destination}}

  defp block_command(%{kind: :merge}), do: {:error, "Choose a destination block."}

  defp block_command(%{kind: :remove_all, trip_ids: [_ | _] = ids}), do: {:ok, {:unassign, ids}}

  defp block_command(_action), do: {:error, command_error(:invalid_command, nil)}

  # The merge picker offers the day type's other blocks — never the block being
  # merged, and no “New block” or “No block”, because a merge always joins an
  # existing ID (AC-13, reference picker).
  defp merge_destinations(%{block_action: nil}), do: {[], 0}

  defp merge_destinations(%{block_action: action, destination_blocks: blocks}) do
    blocks
    |> Enum.reject(&(&1.block_id == action.block_id))
    |> destination_options(action.search)
  end

  defp block_action_form(nil), do: nil

  defp block_action_form(action) do
    to_form(
      %{"block_id" => action.rename, "search" => action.search},
      as: :block_action
    )
  end

  # --- the minimum-layover drawer (step 28) ----------------------------------

  # The drawer's transient state: the value the reader typed (or `%{}` for the
  # stored one) and a drawer-level sentence for a save the changeset cannot
  # explain. The form itself is the context's own changeset, so the page never
  # re-derives `Blocking`'s validation (AC-9).
  defp put_layover(socket, params, error),
    do: assign(socket, :layover, %{params: params, error: error})

  # Only the one stored value is read from the drawer's form. A crafted payload
  # cannot name an organization or a version (those come from the socket, CR-4),
  # and anything but a map is ignored rather than passed to the context.
  defp layover_params(%{"layover" => values}) when is_map(values),
    do: Map.take(values, ["min_layover_minutes"])

  defp layover_params(_params), do: %{}

  # The form the drawer renders: the stored minimum with the reader's own value
  # on top, so an out-of-range value keeps both the input and the context's field
  # error (AC-28). The `:validate` action is what makes an Ecto changeset render
  # its own field errors — without it `Phoenix.HTML.FormData.Ecto.Changeset`
  # drops every error — and the value the reader sent stays in the field.
  defp layover_form(assigns) do
    to_form(
      Blocking.change_settings(
        %{min_layover_minutes: assigns.min_layover_minutes},
        assigns.layover.params
      ),
      as: :layover,
      action: :validate
    )
  end

  # The save itself: one scoped write through the context's own upsert, which
  # decides whether the version is publishable and whether the value is a whole
  # number from 0 to 120 (AC-9). Only its result decides what the page shows.
  defp save_layover(socket, attrs) do
    if editor_access?(socket) do
      case Gtfs.update_blocking_settings(
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
             attrs
           ) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> put_layover(%{}, nil)
           |> assign(:open_drawer, nil)
           |> load_day()
           |> resolve_drawers()
           |> assign_page_rows_if_loaded()
           |> put_flash(:info, "Minimum layover saved.")}

        # The context's changeset carries the field error: the drawer shows it
        # under the input and the value the reader typed stays in the field.
        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_layover(socket, attrs, nil)}

        {:error, _reason} ->
          {:noreply, put_layover(socket, attrs, @layover_save_failed)}
      end
    else
      # The refusal is the drawer's own sentence: the drawer is a top-layer
      # `<dialog>` and the page flash renders behind it (AC-31).
      {:noreply, put_layover(socket, attrs, @permission_message)}
    end
  end

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
    selection = retain_in_day(socket.assigns.selection, day)

    socket
    |> assign(:selection, selection)
    |> assign(:selected_trips, selected_trips(day, selection))
    |> assign(
      day_types: day.day_types,
      day_type: day.day_type,
      counts: day.counts,
      figures: day.figures,
      fleet: fleet_table_rows(day),
      fleet_shortfalls: fleet_shortfall_rows(day),
      plan_chart: plan_chart(day),
      longest_stretch: day.longest_stretch,
      relief_stop_count: MapSet.size(day.context.relief_stop_ids),
      estimated?: day.estimated_pairs > 0,
      repeating?: day.peak.excluded_frequency > 0,
      errors?: Enum.any?(day.findings, &(&1.severity == :error)),
      garages?: map_size(day.context.garages) > 0,
      vehicles?: day.context.fleet != [],
      peak: day.peak,
      axis: timeline_axis(day),
      max_piece_minutes: day.settings.max_piece_minutes,
      routes: day.routes,
      findings: day.findings,
      in_seat: day.in_seat,
      mixed_timezones?: day.mixed_timezones?,
      trip_labels: trip_labels(day),
      findings_by_trip: findings_by_trip(day.findings),
      destination_blocks: Enum.map(day.blocks, &destination_option/1),
      min_layover_minutes: day.settings.min_layover_minutes,
      untimed_trips: Enum.filter(day.unplottable, & &1.block_id),
      # The Garage and Vehicle type form's pickers read the planning inputs the
      # day load already gathered, in the order a reader scans them (INV-9).
      garages: garage_options(day.context.garages),
      vehicle_types: vehicle_type_options(day.context.vehicle_types),
      # The per-route requirements behind the form's two help lines. They are
      # planning inputs like the rest of the context and are read here only to
      # explain a value, never to resolve one (R4).
      route_settings: day.context.route_settings
    )
  end

  # The garage picker lists the organization's garages by name, the vehicle type
  # picker its types with the limit each one carries, so the form's help line can
  # name the hours a type allows without a second read.
  defp garage_options(garages) do
    garages
    |> Map.values()
    |> Enum.map(&%{id: &1.id, name: &1.name})
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  defp vehicle_type_options(types) do
    types
    |> Map.values()
    |> Enum.map(&%{id: &1.id, name: &1.name, max_out_minutes: &1.max_out_minutes})
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  # The timeline's axis spans the day's *platform* spans, not only its trips, so
  # a garage pull-out before the first departure and a pull-back after the last
  # arrival are on the track rather than clipped off its left and right edges.
  # The movements are the platform spans R2 and R3 already derived, and the
  # hours are snapped outwards so the axis keeps the whole-hour ticks the axis
  # has always printed. A day with no plottable trip has no span and no axis.
  defp timeline_axis(%{axis: nil}), do: nil

  defp timeline_axis(day) do
    Enum.reduce(day.blocks, day.axis, fn block, axis ->
      movements = block.movements

      case {movements.platform_start_secs, movements.platform_end_secs} do
        {start, finish} when is_integer(start) and is_integer(finish) ->
          %{
            start_secs: min(axis.start_secs, hour_floor(start)),
            end_secs: max(axis.end_secs, hour_ceil(finish))
          }

        _no_span ->
          axis
      end
    end)
  end

  defp hour_floor(secs), do: Integer.floor_div(secs, 3600) * 3600

  defp hour_ceil(secs) do
    if rem(secs, 3600) == 0, do: secs, else: hour_floor(secs) + 3600
  end

  defp assign_empty_derived(socket) do
    socket
    |> assign(
      day_types: [],
      day_type: nil,
      counts: @empty_counts,
      figures: @empty_figures,
      fleet: [],
      fleet_shortfalls: [],
      plan_chart: nil,
      longest_stretch: nil,
      relief_stop_count: 0,
      estimated?: false,
      repeating?: false,
      errors?: false,
      garages?: false,
      vehicles?: false,
      peak: @empty_peak,
      axis: nil,
      max_piece_minutes: nil,
      routes: %{},
      findings: [],
      in_seat: %{},
      trip_view: nil,
      gap_view: nil,
      block_view: nil,
      back_block: nil,
      block_action: nil,
      mixed_timezones?: false,
      trip_labels: %{},
      findings_by_trip: %{},
      destination_blocks: [],
      min_layover_minutes: nil,
      untimed_trips: [],
      garages: [],
      vehicle_types: [],
      route_settings: %{},
      selected_trips: [],
      pool_page_ids: MapSet.new(),
      timeline_page_ids: MapSet.new(),
      visible_count: 0,
      timeline_key: nil,
      pool_visible_count: 0,
      pool_key: nil
    )
    |> stream(:block_rows, [], reset: true)
    |> stream(:list_rows, [], reset: true)
    |> stream(:pool_rows, [], reset: true)
  end

  # The count strip and the Plan summary chart use the same 15-minute bins, so
  # the bin width is one constant rather than two that could drift apart.
  @bin_secs 900

  # The count strip and the Plan summary chart use the same 15-minute bins, so
  # the bin width is one constant rather than two that could drift apart.
  @bin_secs 900

  # The plan figures of one day type, as Day loading step 4 derived them, and the
  # short fleet rows with the garage and type names the day resolved, so
  # `render/1` prints numbers and words rather than re-deriving either (CR-6).
  # A row is short only against a real listing, so `at_secs` is always set here.
  defp fleet_shortfall_rows(day) do
    for %{status: :short} = row <- day.fleet do
      %{
        garage: garage_name(day.context.garages, row.garage_id),
        type: vehicle_type_name(day.context.vehicle_types, row.vehicle_type_id),
        needed: row.needed,
        listed: row.listed,
        at_secs: row.at_secs
      }
    end
  end

  # Every fleet row of the Plan summary's table, in `Fleet.rows/2`'s own order
  # (typed rows then the garage total, garages in order), with the garage and
  # type names the day resolved (INV-9). The `:all` row is the garage's total,
  # which the table prints muted and never charts, because a bar above a total
  # is checked twice over. Each row carries its own index rather than the
  # row's UUIDs, so the table's DOM ids stay short and stable.
  defp fleet_table_rows(day) do
    day.fleet
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      %{
        index: index,
        garage: garage_name(day.context.garages, row.garage_id),
        type: vehicle_type_name(day.context.vehicle_types, row.vehicle_type_id),
        garage_id: row.garage_id,
        vehicle_type_id: row.vehicle_type_id,
        needed: row.needed,
        listed: row.listed,
        at_secs: row.at_secs,
        total?: row.vehicle_type_id == :all,
        short?: row.status == :short
      }
    end)
  end

  # The Plan summary's chart for the day's fleet rows: one garage · type's
  # vehicles out per 15-minute bin against that row's own listing. The focused
  # row is the first short row, else the first typed row — never a garage total,
  # which is the sum of the typed rows and would chart the same demand twice. A
  # day with no typed row at all has no focus and prints the table without a
  # chart.
  #
  # The bars are counted by `Blocking.Summary.bins/2` over the focused row's own
  # blocks, which is the same count `Fleet.rows/2` peaks for that row, so the
  # chart's tallest bar and the table's `needed` can never disagree. The scale
  # is the taller of the peak and the listing, so a listing above every bar
  # draws its line above them all instead of off the top.
  defp plan_chart(day) do
    rows = fleet_table_rows(day)

    with row when not is_nil(row) <-
           Enum.find(rows, &(&1.short? and not &1.total?)) || Enum.find(rows, &(not &1.total?)),
         bins when bins != [] <- row_bins(day, row) do
      top = Enum.max([row.needed, row.listed, 1])

      %{
        row: row,
        bins: bins,
        listed_height: BlocksComponents.bar_height(row.listed, top),
        bars:
          Enum.map(bins, fn bin ->
            bin
            |> Map.put(:height, BlocksComponents.bar_height(bin.count, top))
            |> Map.put(:over_listed?, bin.count > row.listed)
          end)
      }
    else
      _no_focus -> nil
    end
  end

  # The blocks a row counts: a typed row is its garage's blocks of that type, a
  # garage total is every block of that garage. `Fleet.rows/2` peaks over
  # exactly these spans, so the bins and the row's `needed` are one count.
  defp row_bins(day, row) do
    day.blocks
    |> Enum.filter(fn block ->
      block.resolution.garage_id == row.garage_id and
        (row.total? or block.resolution.vehicle_type_id == row.vehicle_type_id)
    end)
    |> Enum.map(& &1.summary)
    |> Summary.bins(@bin_secs)
  end

  # A garage or type the context no longer carries cannot reach a short row —
  # a block resolves both through the same context — so the fallbacks here are
  # for a deleted name, never for a planned one.
  defp garage_name(garages, garage_id) do
    case Map.fetch(garages, garage_id) do
      {:ok, %{name: name}} -> name
      :error -> "Unknown garage"
    end
  end

  defp vehicle_type_name(_vehicle_types, :all), do: "All types"

  defp vehicle_type_name(vehicle_types, vehicle_type_id) do
    case Map.fetch(vehicle_types, vehicle_type_id) do
      {:ok, %{name: name}} -> name
      :error -> "Any type"
    end
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

    {merge_options, merge_total} = merge_destinations(assigns)

    assigns =
      assigns
      |> assign(:assign_form, assign_form(assigns.assign))
      |> assign(:block_action_form, block_action_form(assigns.block_action))
      |> assign(:layover_form, layover_form(assigns))
      |> assign(:destination_options, options)
      |> assign(:destination_total, total)
      |> assign(:merge_options, merge_options)
      |> assign(:merge_total, merge_total)
      |> assign(:bulk, bulk_summary(assigns))
      |> assign(:selection_dates, selection_dates(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
      frame={:wide}
    >
      <:sub_header>
        <.operations_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:blocks} />
      </:sub_header>

      <div id="blocks-page">
        <section class="min-h-screen bg-base-100">
          <div class="w-full space-y-4">
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
                  min_layover_minutes={@min_layover_minutes}
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
                  figures={@figures}
                  peak={@peak}
                  open_drawer={@open_drawer}
                />

                <BlocksComponents.plan_notices
                  fleet_shortfalls={@fleet_shortfalls}
                  garages?={@garages?}
                  vehicles?={@vehicles?}
                  version_id={@state.version_id}
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
                  max_piece_minutes={@max_piece_minutes}
                  routes={@routes}
                  selected_ids={@selection}
                  bulk={@bulk}
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
                <BlocksComponents.plan_summary_drawer
                  open={@open_drawer == :plan_summary}
                  figures={@figures}
                  fleet_rows={@fleet}
                  chart={@plan_chart}
                  day_type={@day_type}
                  min_layover_minutes={@min_layover_minutes}
                  longest_stretch={@longest_stretch}
                  max_piece_minutes={@max_piece_minutes}
                  relief_stop_count={@relief_stop_count}
                  estimated?={@estimated?}
                  repeating?={@repeating?}
                  errors?={@errors?}
                  garages?={@garages?}
                  vehicles?={@vehicles?}
                  version_id={@state.version_id}
                />
                <BlocksComponents.layover_drawer
                  open={@open_drawer == :layover}
                  form={@layover_form}
                  error={@layover.error}
                />

                <%= case @trip_view do %>
                  <% {:trip, trip, day_types} -> %>
                    <BlocksComponents.trip_drawer
                      open={true}
                      trip={trip}
                      routes={@routes}
                      version_id={@state.version_id}
                      calendar_label={calendar_label(day_types, trip)}
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
                    movement={gap.movement}
                    windows={gap.windows}
                    relief_checked?={gap.relief_checked?}
                    day_label={gap.day_label}
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
                    movements={block.movements}
                    max_piece_minutes={@max_piece_minutes}
                    action={@block_action}
                    form={@block_action_form}
                    merge_options={@merge_options}
                    merge_total={@merge_total}
                    attributes={@block_attributes}
                    attributes_form={block_attributes_form(@block_attributes)}
                    garages={@garages}
                    vehicle_types={@vehicle_types}
                    route_settings={@route_settings}
                    day_types={@day_types}
                    selected_day_type={@day_type}
                  />
                <% end %>

                <%!-- The selection-scoped form sits in its own dialog (the trip
                drawer holds the single-trip one); the review renders after it, so
                a confirmation is the top of the stack. --%>
                <BlocksComponents.assign_dialog
                  :if={@assign && @assign.scope == :selection}
                  assign={@assign}
                  form={@assign_form}
                  options={@destination_options}
                  total={@destination_total}
                  total_dates={@selection_dates}
                />

                <BlocksComponents.review_dialog
                  review={@review}
                  stale?={@review_stale?}
                  error={pending_error(assigns)}
                  day_type={@day_type}
                  version_name={@current_gtfs_version.name}
                  return_focus_id={review_focus(assigns)}
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
