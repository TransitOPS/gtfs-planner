defmodule GtfsPlannerWeb.Gtfs.BlocksLive do
  @moduledoc """
  LiveView for Operations › Blocks.

  Blocks shows which trips one vehicle works in sequence for a service day, and
  it is the only place a block is edited. This page owns the service-day scope,
  the whole-day count strip and plan figures, the Service dates, Checks, Plan
  summary, Block rules, Driving times, Operator changes and Suggest blocks
  drawers, the suggestion preview and every page state; the timeline, the List
  view, the unassigned pool and the trip, gap and block drawers render inside the
  same page.

  The page mounts through the ordinary `:gtfs_routes` session, which decides
  whether a request reaches it; the editor guard is declared here because a
  session alone grants no GTFS access. Mount carries no page state and never
  patches the URL, so a link to `/blocks` always lands on the page itself.
  Version switching keeps the page on the new version and accepts only a
  published version of the current organization.

  The whole loaded day lives in the server-only `:day` assign, which `render/1`
  never reads: the render assigns (`:day_types`, `:day_type`, `:counts`,
  `:peak`, `:bins`, `:axis`, the trip's in-seat records and the rest) are derived
  from it, so a route filter, a page change or a drawer never re-reads the trips.
  A load runs when the connected page has no day for the requested key;
  every other URL change only re-renders. An unknown `day` key keeps its recovery
  state and applies no default, and a failed load keeps the last loaded
  day on screen.

  `trip=` is a deep link to one trip's read-only drawer: `handle_params/3`
  resolves it against the loaded day, opens `#trip-drawer` on the page that holds
  the trip (overriding a requested `page`/`pool_page`), and shows
  `#blocks-trip-elsewhere` with the trip's own day types or the unavailable
  sentence when the loaded day type or the version does not hold it.

  `gap=` (`<from trip uuid>|<to trip uuid>`) and `block=` are the other two
  drawers, and the three together are a small stack: `block=` keeps its context
  in the URL while a gap or a trip is open on top of it, so the gap and trip
  drawers offer “Back to block <id>”. The top of the stack is the one drawer
  rendered open (trip, then gap, then block), one URL change resolves it against
  the loaded day and no drawer reaches into the day in `render/1`.

  `drawer=driving_times&pair=stop:<id>|stop:<id>` and `drawer=operator_changes`
  are the planning-input drawers the gap drawer links to. They are page
  drawers rather than a stack entry, so the link that opens one clears the stack:
  one open panel over the page, and a link that reopens the same drawer.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Summary
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.EnsureRole
  alias GtfsPlannerWeb.Gtfs.BlocksComponents

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @drawers %{
    "service_dates" => :service_dates,
    "checks" => :checks,
    "problems" => :checks,
    # The plan figures send `plan_summary`. The old `peak` key
    # maps to the same drawer so an older link still opens the page's plan
    # summary rather than a drawer that no longer exists.
    "plan_summary" => :plan_summary,
    "peak" => :plan_summary,
    # The two planning-input drawers are reached from a link that names them in
    # the URL, so `?drawer=driving_times&pair=…` opens the same drawer a click
    # does.
    "driving_times" => :driving_times,
    "operator_changes" => :operator_changes,
    # The Suggest blocks drawer is a page drawer too, and the selection bar's
    # “Rebuild selected blocks” reaches it by patching `?drawer=suggest`. The
    # Block rules key is
    # here for the same reason: the suggest drawer's “Block rules” link is a
    # navigation, not a panel swap, so the URL it leaves behind is one the page
    # can resolve again.
    "suggest" => :suggest,
    "block_rules" => :block_rules
  }

  # The settings save keeps the reader's value when the save is refused, so the
  # sentence names the value rather than a generic failure.
  @block_rules_save_failed "These block rules could not be saved. Your entries are retained. Try again."

  # The two writers of the Block rules drawer run in separate transactions, so a
  # settings save that succeeds and a route save that is refused leaves the
  # settings stored. The flash says exactly that, rather than claiming the whole
  # save failed.
  @block_rules_partial "Block rules saved; route garages need fixing."

  # The Block rules drawer's transient state: the settings values the reader
  # typed, the interlining segment they chose, the per-route values the table
  # posted, the one entry per version route the table renders, the refusals the
  # route writer returned keyed by `{route_id, field}`, and a drawer-level
  # sentence for a save the context cannot explain.
  @empty_block_rules %{
    params: %{},
    interlining: nil,
    routes: [],
    route_params: %{},
    route_errors: %{},
    error: nil
  }

  # The Driving times drawer's transient state: the version and day type the
  # rows were read for, the rows themselves, the minutes the reader typed keyed by
  # the `from|to` reference pair, the row errors of a refused save, whether the
  # “Estimated only” filter is on, and a drawer-level sentence.
  @empty_driving_times %{
    key: nil,
    pairs: [],
    params: %{},
    errors: %{},
    estimated_only?: false,
    error: nil
  }

  # The drawer's own sentences. It is a top-layer `<dialog>`, so the page flash
  # renders behind it and cannot carry a refusal the reader is looking at.
  @driving_times_unreadable "These driving times couldn't be read. Your entries are kept."
  @driving_times_unknown_pair "That driving time isn't in this service day."
  @driving_times_nothing_to_reset "That driving time had nothing to reset."

  @driving_times_save_failed "These driving times could not be saved. Your entries are retained. Try again."

  # The row error, over the range the context's changeset
  # enforces on a driving time.
  @driving_minutes_error "Enter 0–600 min."

  # The Operator changes drawer's transient state: the version and day type the
  # candidates were read for, the candidates themselves, the limit the reader
  # typed so far, the ticked candidate IDs so far, and a drawer-level sentence.
  @empty_operator_changes %{
    key: nil,
    candidates: [],
    limit: "",
    marked: nil,
    limit_error: nil,
    error: nil
  }

  # The drawer's own sentences. Its error is the top-layer dialog's own, not the
  # page flash behind it.
  @operator_changes_unreadable "These operator changes couldn't be read. Your entries are kept."

  @operator_changes_save_failed "These operator changes could not be saved. Your entries are retained. Try again."

  # The limit error, over the range the context's changeset
  # enforces on the relief limit.
  @operator_limit_error "Enter a whole number from 60 to 720, or leave it blank."

  # The researched common contract limit, pre-filled when the version has none.
  @default_piece_minutes 330

  # The Suggest blocks drawer's transient state. The scope is the mode the
  # reader chose, `:too_large` the trips the generator refused to plan, and
  # `:busy` the one suggestion being built at a time. Everything else the drawer
  # prints is derived from the loaded day.
  @empty_suggest %{scope: :unassigned_only, too_large: nil, error: nil, busy: false}

  # The panel's own data, empty until a plan is previewed. It is a render assign
  # rather than something `render/1` derives, so the render never reads the loaded
  # day.
  @empty_suggestion %{
    plan: nil,
    scope: nil,
    picked: [],
    minimum: 0,
    fixed: 0,
    existing: 0,
    changed_block_ids: MapSet.new()
  }

  # A scope of no selection cannot reach the generator's `{:selected, ids}` mode,
  # so a payload that asks for one is refused here in the drawer's own
  # words rather than turned into a scope the reader did not choose.
  @suggest_no_selection "Select blocks on the timeline first."

  @suggest_unavailable "A suggestion could not be built. Your blocks are unchanged. Try again."

  # A suggestion is one bounded read of the day type, so it runs
  # under `start_async` the way the page's other bounded reads do: the drawer shows
  # that it is working instead of freezing on the button, and the result is applied
  # when it arrives.
  @suggest_preview_key :suggest_preview

  # Applying a suggestion is the page's own state: the result of the
  # last attempt, and the applied message that outlives the preview it belongs
  # to. `:none` is a preview with nothing to say, `:pending` a write in flight,
  # and `:stale`, `:busy` and `:failed` the three answers that keep the preview
  # and offer another attempt.
  @empty_apply %{status: :none, title: nil, message: nil, reason: nil}

  # The replace-all confirmation, its own assign rather than part of the result:
  # it is a question the reader is asked, not an outcome.
  @no_replace %{open?: false, moves: 0, days: []}

  # Applying is one bounded write under the blocking lock, so it runs under
  # `start_async` the way the page's other bounded work does: the panel shows
  # that it is working, a second click while it runs is refused, and the result
  # is applied when it arrives.
  @apply_suggestion_key :suggest_apply

  # The three answers in the page's own words. A stale plan is named
  # by what the reader must do about it rather than by an input the page cannot
  # see: `apply_block_plan/3` reports `:stale_plan` without saying which setting,
  # trip or driving time moved, so the message names the class of change and
  # turns Apply off with its reason beside it.
  @apply_stale_title "This suggestion is out of date."
  @apply_stale_message "A driving time, trip, block or setting changed after this preview was built. Nothing was applied. Suggest again before applying."

  @apply_stale_reason "Apply is off until the suggestion is built again from the current blocks."

  @apply_busy_title "Another change to this version's blocks was saving."
  @apply_busy_message "Nothing was applied. Apply again in a moment."

  @apply_failed_title "The suggestion couldn't be saved."
  @apply_failed_message "Your blocks are unchanged. Try again, or discard the suggestion."

  @apply_pending_title "Applying the suggestion…"
  @apply_pending_message "The trips are moving to their new blocks. Nothing is saved until this finishes."

  @sort_keys %{
    "block" => :block,
    "garage" => :garage,
    "out" => :out,
    "hours" => :hours,
    "status" => :status
  }

  # The timeline and the List view hold one page of the day type's blocks and the
  # Unassigned panel one page of its pool trips. Every page is derived from the
  # loaded day, so paging, sorting and the filters never re-read trips.
  @page_size 100

  # A page number is clamped to a positive integer. `@max_page` is the absolute
  # guard against a crafted URL; the day's own page count is applied when the page
  # is sliced, so an out-of-range page renders the last page's rows rather than a
  # page the pager would deny. The URL keeps the requested page.
  @max_page 10_000

  @empty_counts %{blocks: 0, trips: 0, unassigned: 0, problems: 0, notices: 0}
  @empty_peak %{count: 0, at_secs: nil, excluded_unassigned: 0, excluded_frequency: 0}
  @empty_figures %{vehicles: 0, minimum: 0, riders: 0}

  # The Plan summary's chart counts the same 15-minute bins as the day load's own
  # `bins`, so the width is one constant rather than two that could drift.
  @bin_secs 900

  # The destination picker offers at most this many matches, so a day type with
  # thousands of blocks still narrows by search rather than by scrolling.
  @destination_limit 25

  @permission_message "You don't have permission to change blocks in this version."

  @subtitle "A block is one vehicle's trips for a service day, in order. Check that they fit, and give every trip a vehicle."

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
     # The block selection is the Blocks tab's own cross-page selection of block
     # IDs, kept beside the trip selection rather than inside it: the two are
     # never read together, so selecting blocks cannot change what the Unassigned
     # panel's bar counts and selecting trips cannot change this one.
     |> assign(:block_selection, MapSet.new())
     |> assign(:visible_count, 0)
     |> assign(:timeline_key, nil)
     |> stream(:block_rows, [], dom_id: &block_dom_id/1)
     |> stream(:list_rows, [], dom_id: &block_dom_id/1)
     |> stream(:pool_rows, [], dom_id: &pool_dom_id/1)
     |> assign(:assign, nil)
     |> assign(:review, nil)
     |> assign(:review_stale?, false)
     |> assign(:block_rules, @empty_block_rules)
     |> assign(:driving_times, @empty_driving_times)
     |> assign(:operator_changes, @empty_operator_changes)
     |> assign(:suggest, @empty_suggest)
     |> assign(:plan_preview, nil)
     |> assign(:runs_touched, 0)
     |> assign(:preview_day, nil)
     |> assign(:suggestion, @empty_suggestion)
     |> assign(:apply, @empty_apply)
     |> assign(:replace, @no_replace)
     |> assign(:applied, nil)
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
  # A day type is a different plan, so its blocks are not the blocks the reader
  # was selecting; the trip selection clears with it.
  def handle_event("select_day", %{"day" => _day}, %{assigns: %{plan_preview: plan}} = socket)
      when not is_nil(plan) do
    # A preview is a proposal over one day type. Changing what it was built from
    # would leave the panel describing a plan the page no longer shows, so the
    # control is disabled while it is up and its event is refused here as well: a
    # disabled control that still fired would be a lie about the page's state.
    {:noreply, socket}
  end

  def handle_event("select_day", %{"day" => day}, socket) do
    patch(socket, %{day: blank_to_nil(day), trip: nil, page: 1, pool_page: 1},
      clear_selection: true,
      clear_block_selection: true,
      clear_command: true
    )
  end

  # The day select is disabled while a suggestion is previewed, so a change event
  # from its form carries no day at all. That is not a day change and must not
  # take the page down with it: a form that names nothing changes nothing.
  def handle_event("select_day", _params, socket), do: {:noreply, socket}

  def handle_event("filter", params, socket) do
    status = if params["status"] == "problems", do: :problems, else: :all
    route = blank_to_nil(params["route"])

    # A route filter keeps only the selected trips that run on that route.
    # The selection is not in the URL, so it is pruned before the patch and both
    # stream keys carry it, which re-sends the page with its new checked state.
    # The block selection is not pruned: the filters narrow which blocks a
    # rebuild would plan, and a block the reader picked under one filter is not
    # a block the reader picked under the next, so the filter clears it.
    socket =
      socket
      |> assign(:selection, retain_on_route(socket, route))
      |> assign_selected_trips()
      |> assign(block_selection: MapSet.new(), selected_blocks: [])

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
  # sort covers the whole day type, so it returns to page 1.
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
  # page change and a trip that leaves the page keeps its place in it.
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
  # to the selection, so a large selection is built a page at a time.
  def handle_event("select_page", _params, socket) do
    selection = MapSet.union(socket.assigns.selection, visible_page_ids(socket.assigns))

    {:noreply, put_selection(socket, selection)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, put_selection(socket, MapSet.new())}
  end

  # --- the block selection ------------------------------------

  # The row checkbox toggles one block by its own block ID, so the selection
  # survives a page change and a sort exactly as the trip selection does, and the
  # two events are distinct: `toggle_block` never reads the trip selection and
  # `toggle_trip` never reads this one.
  def handle_event(
        "toggle_block",
        %{"block" => _block_id},
        %{assigns: %{plan_preview: plan}} = socket
      )
      when not is_nil(plan),
      do: {:noreply, socket}

  def handle_event("toggle_block", %{"block" => block_id}, socket) do
    case find_block(socket.assigns.day, block_id) do
      nil ->
        {:noreply, socket}

      block ->
        selection = toggle_block_selection(socket.assigns.block_selection, block.summary.block_id)
        {:noreply, put_block_selection(socket, selection)}
    end
  end

  def handle_event("toggle_block", _params, socket), do: {:noreply, socket}

  # The header checkbox selects the whole page, and unselects it when the page is
  # already selected, so one control builds and clears a page-sized selection.
  def handle_event("select_block_page", _params, %{assigns: %{plan_preview: plan}} = socket)
      when not is_nil(plan),
      do: {:noreply, socket}

  def handle_event("select_block_page", _params, socket) do
    selection =
      toggle_block_page(socket.assigns.block_selection, socket.assigns.timeline_block_ids)

    {:noreply, put_block_selection(socket, selection)}
  end

  # Rebuilding selected blocks only carries the reader to the Suggest blocks
  # drawer's “Selected blocks” scope, and only with a selection to plan.
  def handle_event("rebuild_selected", _params, socket) do
    if MapSet.size(socket.assigns.block_selection) == 0 do
      {:noreply, socket}
    else
      patch(socket, %{drawer: "suggest"})
    end
  end

  def handle_event("clear_block_selection", _params, socket) do
    {:noreply, put_block_selection(socket, MapSet.new())}
  end

  # The assignment form lives in the trip drawer, so opening it from a pool row
  # patches `trip=` to open that drawer; a trip already in the URL keeps its URL,
  # including any `block=` context its “Back to block” link reads. The
  # `selection` scope sits beside this one.
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
  # the apply still refuses the command if eligibility is all that changed.
  # “Use eligible trips” drops them and keeps the dialog open on
  # what remains.
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

  # The block drawer's three actions. The block a command acts on comes
  # from the loaded day's own drawer and a remove-all's trip IDs from the same
  # block, so a crafted event can never name another block or trip; the
  # submit then runs the same reviewed command path as an assignment.
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

  # The one attribute write this drawer offers. The form exists only on a
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
  # a removal that adds a problem opens the review too. The bulk bar
  # removes every blocked trip of the selection; the ones already in the pool are
  # not part of the command.
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

  # The Block rules drawer's form sends its change event through its own name:
  # the values the reader typed are kept and re-validated, so a field
  # error appears before a save rather than only after one. The Route
  # switches control is its own form and posts the same event with only
  # `interlining`, so one handler covers both: a payload with the form's own
  # `block_rules` map replaces the settings values, and one with `interlining`
  # replaces only that segment. A crafted payload of another shape changes
  # nothing.
  def handle_event("block_rules_change", params, socket) do
    {:noreply, put_block_rules(socket, params, nil)}
  end

  # The two planning-input drawers are part of the URL, because a link names what
  # it opens: the gap drawer's “Enter a known driving time” names the pair it is
  # about, so the drawer can highlight and focus that row. They
  # are page drawers, so the drawer stack is dropped rather than stacked under
  # them — two open panels would cover the page twice.
  def handle_event(
        "open_drawer",
        %{"key" => key} = _params,
        %{assigns: %{plan_preview: plan}} = socket
      )
      when not is_nil(plan) and key in ["block_rules", "driving_times", "suggest"] do
    # The rules and the driving times a plan was built on, and the drawer that
    # builds another, are all off while a preview is up.
    {:noreply, socket}
  end

  def handle_event("open_drawer", %{"key" => key} = params, socket)
      when key in ["driving_times", "operator_changes", "suggest"] do
    patch(socket, %{
      trip: nil,
      gap: nil,
      block: nil,
      drawer: key,
      pair: blank_to_nil(params["pair"])
    })
  end

  # The Suggest blocks drawer's “Block rules” link is a navigation, not a panel
  # swap: the rules are another drawer's own state, so opening one leaves the
  # suggest drawer rather than covering the page twice, and the URL names the
  # drawer that is open. The page header's own Block rules button keeps its
  # panel behaviour, which no URL change can undo.
  def handle_event(
        "open_drawer",
        %{"key" => "block_rules"} = params,
        %{assigns: %{open_drawer: :suggest}} = socket
      ) do
    socket
    |> load_block_rules()
    |> patch(%{
      trip: nil,
      gap: nil,
      block: nil,
      drawer: "block_rules",
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

      "block_rules" ->
        {:noreply, socket |> load_block_rules() |> assign(:open_drawer, :block_rules)}

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

  # The Suggest blocks drawer's own two events. Choosing a scope is a
  # client-side answer the page keeps, not a URL change: the drawer is reached by
  # `?drawer=suggest` and the scope is one of the generator's modes, so a reader
  # who opens the drawer again is offered the scope that is offered now — the
  # block selection, when there is one, or unassigned trips.
  def handle_event("suggest_scope_change", %{"scope" => scope}, socket) do
    if suggest_scope?(scope) do
      {:noreply,
       put_suggest(socket, %{
         socket.assigns.suggest
         | scope: suggest_scope_name(scope),
           too_large: nil
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_event("suggest_scope_change", _params, socket), do: {:noreply, socket}

  # Preview builds the plan and stores it; it writes nothing. A
  # second submit while one is being built is refused, and a submit on a page with
  # no loaded day type is not a preview at all.
  def handle_event("preview_suggestion", _params, %{assigns: %{day_type: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("preview_suggestion", _params, %{assigns: %{suggest: %{busy: true}}} = socket),
    do: {:noreply, socket}

  def handle_event("preview_suggestion", _params, socket) do
    socket =
      put_suggest(socket, %{socket.assigns.suggest | busy: true, error: nil, too_large: nil})

    request = suggest_request(socket)

    # The task hands the request back with its result: the page cannot read the
    # closure, and the pairing is what tells a late result from a stale one.
    {:noreply,
     start_async(socket, @suggest_preview_key, fn -> {request, run_suggestion(request)} end)}
  end

  # Discarding a suggestion puts the saved day back on the page. Nothing was
  # written to produce the preview, so there is nothing to undo here: the plan is
  # dropped, the loaded day is re-derived, and the timeline is re-sent with the
  # markers gone.
  def handle_event("discard_suggestion", _params, %{assigns: %{plan_preview: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("discard_suggestion", _params, socket) do
    {:noreply, drop_preview(socket)}
  end

  # “Suggest again” reopens the drawer on the scope the discarded plan was built
  # with, so a reader who changes their mind about the scope does not have to
  # choose it again, and the panel's own `:suggest` assign still carries it.
  def handle_event("suggest_again", _params, %{assigns: %{plan_preview: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("suggest_again", _params, socket) do
    patch(drop_preview(socket), %{trip: nil, gap: nil, block: nil, drawer: "suggest", pair: nil})
  end

  # --- applying a suggestion ----------------------------------

  # Apply writes the previewed plan, so it is refused in the states where there
  # is nothing to write or where a write is already in flight: a second click
  # while one runs is dropped rather than queued, and the plan's own fingerprint
  # is what stops a stale preview being written twice. A rebuild is
  # confirmed first, because it replaces hand-tuned blocks (PM-5); the other two
  # scopes apply directly.
  def handle_event("apply_suggestion", _params, %{assigns: %{plan_preview: nil}} = socket),
    do: {:noreply, socket}

  def handle_event(
        "apply_suggestion",
        _params,
        %{assigns: %{apply: %{status: :pending}}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("apply_suggestion", _params, %{assigns: %{apply: %{status: :stale}}} = socket),
    do: {:noreply, socket}

  def handle_event("apply_suggestion", _params, %{assigns: %{day_type: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("apply_suggestion", _params, socket) do
    if socket.assigns.suggestion.scope == :replace_all and
         not socket.assigns.replace.open? do
      {:noreply, assign(socket, :replace, replace_confirmation(socket))}
    else
      {:noreply, start_apply(socket)}
    end
  end

  # “Keep current blocks” closes the confirmation and changes nothing: the
  # preview, its figures and its buttons are exactly as they were.
  def handle_event("cancel_replace", _params, socket) do
    {:noreply, assign(socket, :replace, @no_replace)}
  end

  def handle_event("confirm_replace", _params, %{assigns: %{replace: %{open?: false}}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_replace", _params, socket) do
    socket =
      socket
      |> assign(:replace, @no_replace)
      |> start_apply()

    {:noreply, socket}
  end

  # The applied message is the reader's own; it is not a route, so dismissing it
  # is a panel-only answer and leaves the applied plan and the cleared selection
  # where they are.
  def handle_event("dismiss_applied", _params, socket) do
    {:noreply, assign(socket, :applied, nil)}
  end

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

  # The two writes in the Block rules drawer. The drawer only
  # exists on a loaded day type, so a submit from another page state is not a
  # save. The settings are saved first through the context's own upsert, which
  # decides whether the version is publishable and whether each value is inside
  # its range; a field error keeps the drawer and every entry the reader
  # typed, and the route table is not written at all. Only after the settings
  # writer accepts the row are the per-route garages and types saved, and only
  # then does the day reload so the blocks, warnings and scope button use the new
  # rules. A version that is no longer published keeps the entries with the
  # drawer's own sentence.
  def handle_event("save_block_rules", _params, %{assigns: %{day_type: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_block_rules", params, socket) do
    if editor_access?(socket) do
      case Gtfs.update_blocking_settings(
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
             block_rules_attrs(socket, params)
           ) do
        {:ok, _setting} ->
          save_route_settings(socket, params)

        # The context's changeset carries the field error: the drawer shows it
        # under the input and every value the reader typed stays put. Focus lands
        # on the first invalid control, with the summary as the fallback.
        {:error, %Ecto.Changeset{}} ->
          {:noreply,
           push_event(put_block_rules(socket, params, nil), "focus_form_error", %{
             form_id: "block-rules-form",
             fallback_id: "block-rules-errors"
           })}

        {:error, _reason} ->
          {:noreply, put_block_rules(socket, params, @block_rules_save_failed)}
      end
    else
      # The refusal is the drawer's own sentence: the drawer is a top-layer
      # `<dialog>` and the page flash renders behind it.
      {:noreply, put_block_rules(socket, params, @permission_message)}
    end
  end

  # The Driving times drawer's three events, all in the loaded day type's scope.
  # None of them is a save on its own: the filter only narrows what the
  # drawer shows, a reset writes one row, and the save writes the rows whose
  # minutes differ from the ones the drawer listed.
  def handle_event("filter_driving_times", params, socket) do
    state = socket.assigns.driving_times
    estimated_only? = params["estimated_only"] == "true"

    # The checkbox and the rows share one form, so its change event carries every
    # row the reader typed as well as the filter: hiding the entered rows must not
    # discard an entry someone has not saved yet.
    {:noreply,
     assign(socket, :driving_times, %{
       put_driving_draft(state, driving_times_params(params))
       | estimated_only?: estimated_only?
     })}
  end

  def handle_event("reset_driving_time", _params, %{assigns: %{day_type: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("reset_driving_time", %{"pair" => pair}, socket) do
    state = socket.assigns.driving_times

    with true <- editor_access?(socket),
         {from_ref, to_ref} <- listed_pair(state, pair),
         :ok <-
           Gtfs.clear_deadhead_time(
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
             {from_ref, to_ref}
           ) do
      {:noreply,
       socket
       |> redraw_driving_times(state)
       |> put_flash(:info, "Driving time reset to its estimate.")}
    else
      false ->
        {:noreply, put_driving_error(socket, state, @permission_message)}

      nil ->
        {:noreply, put_driving_error(socket, state, @driving_times_unknown_pair)}

      {:error, :not_found} ->
        {:noreply, put_driving_error(socket, state, @driving_times_nothing_to_reset)}

      {:error, _reason} ->
        {:noreply, put_driving_error(socket, state, @driving_times_save_failed)}
    end
  end

  def handle_event("reset_driving_time", _params, socket), do: {:noreply, socket}

  def handle_event("save_driving_times", _params, %{assigns: %{day_type: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_driving_times", params, socket) do
    state = socket.assigns.driving_times
    submitted = driving_times_params(params)
    {entries, errors} = driving_time_entries(state, submitted)

    cond do
      not editor_access?(socket) ->
        {:noreply,
         put_driving_error(socket, put_driving_draft(state, submitted), @permission_message)}

      errors != %{} ->
        # A bad entry stores nothing at all: the drawer keeps every value the
        # reader typed, each refused row prints its own message, and focus lands
        # on the first input the shared component marked invalid.
        {:noreply,
         socket
         |> assign(:driving_times, %{state | params: submitted, errors: errors})
         |> push_event("focus_form_error", %{form_id: "driving-times-form"})}

      entries == [] ->
        {:noreply,
         socket
         |> assign(:driving_times, %{state | params: %{}, errors: %{}})
         |> put_flash(:info, "No changes")}

      true ->
        save_driving_entries(socket, state, entries)
    end
  end

  # The Operator changes drawer's one event. The limit and the
  # marks are the version's own settings, so the save is a single call to
  # `Gtfs.update_relief_settings/4`: the page validates the limit itself and
  # nothing is written when it refuses, and a save that reaches the context
  # reloads the day so the warnings, the timeline's change marks and the Plan
  # summary all redraw from the stored answer.
  def handle_event("save_operator_changes", _params, %{assigns: %{day_type: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_operator_changes", params, socket) do
    state = socket.assigns.operator_changes
    limit = params["limit"] |> to_string() |> String.trim()
    marked = listed_marks(state, params["marked"])

    if editor_access?(socket) do
      save_operator_changes(socket, state, limit, marked)
    else
      # The refusal is the drawer's own sentence: the drawer is a top-layer
      # `<dialog>` and the page flash renders behind it.
      {:noreply, put_operator_error(socket, state, limit, marked, @permission_message)}
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
      if Keyword.get(opts, :clear_block_selection, false),
        do: assign(socket, block_selection: MapSet.new(), selected_blocks: []),
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
  # is kept as given so an unknown key can reach its recovery state.
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
  # the reader needs and an empty day type stays at `/blocks`.
  #
  # `drawer` carries the page's own drawers, including the Suggest blocks drawer
  # that `rebuild_selected` opens.
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
        # A reloaded day is a different plan, so a suggestion previewed over the
        # last one is dropped rather than drawn over rows it no longer describes.
        |> assign(:plan_preview, nil)
        |> assign(:runs_touched, 0)
        |> assign(:preview_day, nil)
        |> assign(:suggestion, @empty_suggestion)
        |> assign(:apply, @empty_apply)
        |> assign(:replace, @no_replace)
        |> assign(:applied, nil)
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
  # with the new checked state (AGENTS.md streams rule). The block selection is in
  # the key for the same reason: its checkbox is rendered inside the same streamed
  # row, and a stream does not re-render on an assign change. `load_day/1` and the
  # empty states clear the key, so a reload always resends.
  defp assign_timeline(socket) do
    %{state: state} = socket.assigns
    visible = visible_blocks(drawn_day(socket).blocks, state)
    page = effective_page(state.page, length(visible))
    rows = visible |> Enum.drop((page - 1) * @page_size) |> Enum.take(@page_size)

    key =
      {state.panel, state.view, state.route, state.status, state.sort, state.dir, page,
       socket.assigns.selection, socket.assigns.block_selection,
       not is_nil(socket.assigns.plan_preview)}

    socket =
      assign(socket,
        visible_count: length(visible),
        timeline_page_ids: page_trip_ids(rows, state.route),
        timeline_block_ids: MapSet.new(rows, & &1.summary.block_id)
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
    visible = visible_pool(drawn_day(socket).pool, state.route)
    page = effective_page(state.pool_page, length(visible))
    rows = visible |> Enum.drop((page - 1) * @page_size) |> Enum.take(@page_size)

    key =
      {state.panel, state.route, page, socket.assigns.selection,
       not is_nil(socket.assigns.plan_preview)}

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

  # The day the rows are drawn from. While a suggestion is previewed that is the
  # proposal's own day — a block the plan creates is a row, and a trip the plan
  # places has left the pool — while `:day` stays the saved day, so discarding
  # needs no reload and a later apply still matches the plan's fingerprint.
  # The two are the same map when nothing is previewed.
  defp drawn_day(socket), do: socket.assigns.preview_day || socket.assigns.day

  # Both streamed pages are re-derived together, so the timeline, the List view
  # and the pool stay in step on a day, filter, page or selection change.
  defp assign_page_rows(socket), do: socket |> assign_timeline() |> assign_pool()

  # The page is streamed once each cycle, after the drawer resolution has had its
  # chance to move it (`trip=`, `gap=` and `block=` override the requested page).
  # Streaming in `load_day/1` as well would queue the first page and then the
  # overriding one, and a stream reset never discards inserts already queued in
  # the same render, so both pages would render.
  defp assign_page_rows_if_loaded(%{assigns: %{day: nil}} = socket), do: socket
  defp assign_page_rows_if_loaded(socket), do: assign_page_rows(socket)

  # --- the cross-page selection --------------------------------------

  # The selection is a MapSet of trip UUIDs, so it survives a page change, a
  # panel change and a sort; it is not in the URL, so a reload starts empty and
  # the page clears it on a day or version change. `selected_trips` is the
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
  # its `block_id` or in the pool.
  defp day_trips(day), do: Enum.flat_map(day.blocks, & &1.trips) ++ day.pool

  defp toggle_selection(selected, id) do
    if MapSet.member?(selected, id),
      do: MapSet.delete(selected, id),
      else: MapSet.put(selected, id)
  end

  # --- the block selection -------------------------------------

  # A MapSet of block IDs, resolved against the loaded day the same way the trip
  # selection is: `selected_blocks` is what the bar counts and what the Suggest
  # blocks drawer will plan, so a block the day no longer holds is never counted.
  defp put_block_selection(%{assigns: %{day: nil}} = socket, _selection), do: socket

  defp put_block_selection(socket, selection) do
    socket
    |> assign(:block_selection, selection)
    |> assign(:selected_blocks, selected_blocks(socket.assigns.day, selection))
    |> assign_page_rows()
  end

  defp selected_blocks(nil, _selection), do: []

  defp selected_blocks(day, selection) do
    Enum.filter(day.blocks, &MapSet.member?(selection, &1.summary.block_id))
  end

  defp toggle_block_selection(selected, block_id) do
    if MapSet.member?(selected, block_id),
      do: MapSet.delete(selected, block_id),
      else: MapSet.put(selected, block_id)
  end

  # The header checkbox's one rule: a page that is already wholly selected is
  # unselected, and any other page is added whole. An empty page changes nothing.
  defp toggle_block_page(selection, page_ids) do
    if MapSet.size(page_ids) > 0 and MapSet.subset?(page_ids, selection),
      do: MapSet.difference(selection, page_ids),
      else: MapSet.union(selection, page_ids)
  end

  # A route filter keeps only the selected trips that run on that route; clearing
  # the filter keeps the whole selection.
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

  # The block selection's own pruning: a reload can drop a block the previous day
  # type held, and a block that is gone is not a block a rebuild can plan.
  defp retain_blocks_in_day(selection, day) do
    if MapSet.size(selection) == 0 do
      selection
    else
      MapSet.intersection(selection, MapSet.new(day.blocks, & &1.summary.block_id))
    end
  end

  # The trips the current page holds: the pool's own page in the Unassigned panel
  # and the page's blocks' trips in the Blocks panel, where the List view's rows
  # and the timeline's bars are the same page of blocks.
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
  # so the bulk form's scope line means the same thing as the trip form's.
  defp selection_dates(assigns) do
    services = MapSet.new(assigns.selected_trips, & &1.service_id)

    assigns.day_types
    |> Enum.filter(fn day_type ->
      Enum.any?(day_type.service_ids, &MapSet.member?(services, &1))
    end)
    |> Enum.map(& &1.date_count)
    |> Enum.sum()
  end

  # The page has one primary action. A previewed suggestion hands it to the panel's
  # Apply suggestion; a selection of trips hands it to the selection bar's Assign
  # and a selection of blocks to its Rebuild selected blocks; a service day with
  # trips but no blocks hands it to the first-use panel's “Choose trips for a
  # block” while that panel is on screen; otherwise the header's Review action
  # holds it.
  defp primary_owner(assigns, bulk) do
    cond do
      assigns.load_state != :loaded -> :head
      not is_nil(assigns.plan_preview) -> :preview
      bulk.count > 0 -> :bulk
      assigns.selected_blocks != [] -> :blocks
      first_use_panel?(assigns) -> :empty
      true -> :head
    end
  end

  defp first_use_panel?(assigns) do
    assigns.state.panel == :blocks and assigns.counts.blocks == 0 and
      assigns.counts.unassigned > 0
  end

  # The header action counts the work: it names the problems while there are any.
  defp review_label(0), do: "Review checks"
  defp review_label(1), do: "Review 1 problem"
  defp review_label(count), do: "Review #{count} problems"

  # The trips of the selection that still have a block on this day type: the bulk
  # bar's “Remove from block” command names exactly those.
  defp blocked_selected_ids(socket) do
    socket.assigns.selected_trips
    |> Enum.filter(& &1.block_id)
    |> Enum.map(& &1.id)
  end

  # “Change selection” returns focus to whichever opener the reader used: the
  # bulk bar's “Assign N trips” for a selection, the trip drawer's own control
  # for one trip, and the block drawer's own control for one of its three
  # actions.
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
        |> resolve_driving_times(day, Map.get(@drawers, state.drawer))
        |> resolve_operator_changes(day, Map.get(@drawers, state.drawer))
        |> resolve_suggest(Map.get(@drawers, state.drawer))

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

  # A `trip` deep link resolves to that trip's drawer on the page that holds it.
  # The trip's day types come from `Blocking.trip_day_types/3`, the one
  # derivation the day load also uses, so the drawer's all-dates scope and an
  # “another day type” notice agree with the loaded day. The page
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
  # block's own gap entry (its handoff and the layover seconds), the block's own
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
  # trips the day's own map lists it under (a record is read, never
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
  # deep link — switches the panel as well as the page, and the
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

  # --- reviewed block commands --------------------------------------

  # A confirmed review re-runs the command the review carries, so a confirmation
  # writes exactly what was reviewed. An attribute save is one of those commands
  # (`{:attributes, block_id, garage_id, vehicle_type_id}`), so it takes the
  # same path as an assignment rather than a second reviewed implementation.
  defp run_reviewed(socket, {:attributes, block_id, garage_id, vehicle_type_id}, confirmation) do
    run_attributes(socket, block_id, garage_id, vehicle_type_id, confirmation)
  end

  defp run_reviewed(socket, command, confirmation), do: run_command(socket, command, confirmation)

  # Every apply on this page goes through here: the editor role is
  # re-read from the membership first, so a role revoked while the page is open
  # refuses the next write, and the audit context is built from the socket rather
  # than from any parameter. The context resolves the command against the
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
  # names. Nothing here re-derives a review: the result carries the one
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
    # A successful command also clears the trip selection, because those trips
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
  # under the lock and writes only when the recomputed fingerprint still matches.
  # The failure sentence is cleared by the new review.
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
  # from the trip's own flags, so the reader sees which rule refused it.
  defp refuse_ineligible(socket, ids) do
    case socket.assigns.assign do
      nil ->
        put_flash(socket, :error, "Some selected trips can't be assigned to a block.")

      assign ->
        assign(socket, :assign, %{assign | ineligible: ids, error: nil})
    end
  end

  # A failed save keeps the form, its target and its review: only the sentence
  # changes, so a retry repeats exactly the reviewed command. A block
  # drawer action keeps its own control's sentence and the value the reader
  # typed.
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

  defp command_error(:busy, _state), do: "Another change is being saved. Try again in a moment."

  defp command_error(:not_found, _state),
    do: "That trip isn't in this version anymore. Reload blocks."

  defp command_error(:unknown_day_type, _state), do: "This service day isn't in this version."

  # A rename onto the block's own ID is the one `:invalid_command` the drawer can
  # cause, and it gets its own sentence.
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
  # change.
  defp command_error(:block_id_taken, %{kind: :rename, rename: value}) when is_binary(value),
    do: "Block #{String.trim(value)} already runs on these dates. Choose another ID or merge."

  defp command_error(:block_id_taken, _state),
    do: "That block ID already runs on these dates. Choose another ID or merge."

  defp command_error(:too_many_trips, _state),
    do: "This change touches more than 500 trips. Select fewer trips."

  defp command_error({:audit_failed, _reason}, _state),
    do: "The change couldn't be saved. Nothing was written."

  defp command_error(_reason, _state), do: "The change couldn't be saved. Try again."

  # The sentence a review shows above itself when the confirmation failed: the
  # pending form's own failure, whichever form opened the review.
  defp pending_error(%{assign: %{error: error}}) when is_binary(error), do: error
  defp pending_error(%{block_action: %{error: error}}) when is_binary(error), do: error
  defp pending_error(%{block_attributes: %{error: error}}) when is_binary(error), do: error
  defp pending_error(_assigns), do: nil

  # --- the block's garage and vehicle type --------------------------

  # The drawer's own state, rebuilt from the loaded block whenever that block
  # changes (a day-type switch, a reload or another writer's trip), so the two
  # pickers start on the resolution the day load already made and never on a
  # previous block's values. A block whose calendars disagree has no single
  # garage to start on, so the picker starts on the prompt and the save asks for
  # one.
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
  # with the sentence under the field and focus on the picker. Every
  # other value goes to the context, which owns the validation, the lock and the
  # confirmation decision.
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

  # The one attribute write this drawer offers. It runs on the same
  # reviewed path as every other apply on the page: the editor role is re-read
  # from the membership first, the audit context comes from the socket and the
  # block from the loaded drawer's own resolution, so a crafted event can never
  # name another block. The context then takes the version lock, rebuilds
  # the context under it and decides the confirmation.
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
  # written, and drops the review. The patch takes the block out of the
  # URL, which closes the drawer and leaves the reader looking at the row the
  # flash names; the drawer has no post-save state of its own, so closing is this
  # page's existing rule for a command the drawer owns.
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
  # exactly the reviewed save; only the sentence changes.
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

  # --- the assignment form -----------------------------------------

  defp new_assign(trip), do: new_assign(:trip, [trip])

  # A selection-scoped form holds the whole selection: its trip count (which the
  # form's own line already prints), whether any of its trips has a block to
  # remove, and the ineligible trips their own flags refuse, named before any
  # submit.
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
  # case-insensitive substring, with an exact match first and at most 25 entries.
  # `total` is the match count before the cap, so the form can say the
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

  # --- the block drawer's actions ----------------------------------

  # The drawer's three actions share one state, rebuilt from the loaded day's own
  # block whenever that block or its trips change (a day-type switch, a reload or
  # another writer's trip). The trip IDs a remove-all unassigns come from that
  # block, so no parameter names them, and the rename field starts on the
  # block's own ID, so resubmitting it unchanged is the “Enter a different block
  # ID.” case rather than a silent no-op.
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
  # existing ID.
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

  # --- the Block rules drawer --------------------------------------

  # Opening the drawer reads the version's routes once, so the Route garages
  # table lists every route whether or not a row is stored for it. The read is
  # scoped to the socket's own organization and version, and the settings
  # values come from the day load the page already holds rather than a second
  # read. Re-opening starts from the stored values, so a previous refusal never
  # reappears.
  defp load_block_rules(socket) do
    routes =
      Gtfs.list_route_operating_settings(
        socket.assigns.current_organization.id,
        socket.assigns.current_gtfs_version.id
      )

    put_block_rules(socket, routes)
  end

  defp put_block_rules(socket, routes) do
    assign(socket, :block_rules, %{@empty_block_rules | routes: routes})
  end

  # The drawer's transient state after a change event or a refused save. The
  # settings values, the interlining segment, and the per-route values each come
  # from the payload when it carries them, and are kept otherwise, so a change
  # to the Route switches control does not discard the typed numbers. The route
  # refusals clear on every change, because the entry they named has just been
  # edited.
  defp put_block_rules(socket, params, error, route_errors \\ %{}) do
    state = socket.assigns.block_rules

    assign(socket, :block_rules, %{
      state
      | params: Map.merge(state.params, block_rules_params(params)),
        interlining: params["interlining"] || state.interlining,
        route_params: Map.merge(state.route_params, route_settings_params(params)),
        route_errors: route_errors,
        error: error
    })
  end

  # Only the drawer's own settings fields are read from the payload, so a
  # crafted event cannot name an organization or a version (those come from the
  # socket), and the relief limit the drawer does not show is not read
  # from it either.
  defp block_rules_params(%{"block_rules" => values}) when is_map(values),
    do:
      Map.take(
        values,
        ~w(min_layover_minutes max_block_minutes pull_out_buffer_minutes default_garage_id deadhead_speed_kmh deadhead_circuity)
      )

  defp block_rules_params(_params), do: %{}

  # The route table's values, keyed by the route the payload named, so a reader's
  # own two selects are kept and anything not posted falls back to the stored
  # value. A payload naming a route the version does not have is stored here but
  # never reaches the writer, which builds its batch from the routes it read.
  defp route_settings_params(%{"route_settings" => values}) when is_map(values) do
    Map.new(values, fn {route_id, entry} ->
      {route_id,
       %{
         "garage_id" => entry["garage_id"],
         "required_vehicle_type_id" => entry["required_vehicle_type_id"]
       }}
    end)
  end

  defp route_settings_params(_params), do: %{}

  # The form the drawer renders: the stored settings with the reader's own values
  # on top, so an out-of-range value keeps both the input and the context's field
  # error. The `:validate` action is what makes an Ecto changeset render
  # its own field errors — without it `Phoenix.HTML.FormData.Ecto.Changeset`
  # drops every error — and the values the reader sent stay in the fields. The
  # relief limit is carried through from the stored settings, because the writer
  # replaces every column of the row and this drawer does not own that value.
  defp block_rules_form(assigns) do
    to_form(
      Blocking.change_settings(assigns.settings, assigns.block_rules.params),
      as: :block_rules,
      action: :validate
    )
  end

  # The attributes the settings writer validates: the reader's own values, the
  # interlining segment they chose (or the stored one), and the stored relief
  # limit. Nothing else from the payload is read.
  defp block_rules_attrs(socket, params) do
    state = socket.assigns.block_rules

    Map.merge(state.params, %{
      "interlining" => state.interlining || to_string(socket.assigns.settings.interlining),
      "max_piece_minutes" => blank_or_int(socket.assigns.settings.max_piece_minutes)
    })
    |> Map.merge(block_rules_params(params))
  end

  defp blank_or_int(nil), do: ""
  defp blank_or_int(value), do: to_string(value)

  # One row per route of the version, in the order the reader read them, with the
  # reader's own two values on top of the stored ones so a refused save keeps
  # every select where the reader put it.
  defp block_rules_rows(assigns) do
    submitted = assigns.block_rules.route_params

    Enum.map(assigns.block_rules.routes, fn route ->
      values = Map.get(submitted, route.route_id, %{})

      %{
        route_id: route.route_id,
        garage_id: Map.get(values, "garage_id", route.garage_id),
        required_vehicle_type_id:
          Map.get(values, "required_vehicle_type_id", route.required_vehicle_type_id)
      }
    end)
  end

  # The summary counts the entries that need fixing: the settings fields carrying
  # a context error, plus each route row the route writer refused.
  defp block_rules_error_count(form, route_errors) do
    field_errors =
      form.source
      |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> map_size()

    field_errors + (route_errors |> Enum.uniq_by(&elem(&1, 0)) |> length())
  end

  # The settings are stored by the time this runs, so the batch is built from the
  # routes the drawer read with the reader's own values on top. Every route is
  # included, so clearing a select stores `nil` rather than leaving the last
  # saved value. On a full success the drawer closes and the day reloads, so the
  # blocks, warnings and the scope button are drawn from the new rules; on a
  # refusal the drawer stays open with the entry's own message, and the flash
  # says the settings are already stored rather than claiming a failed save.
  defp save_route_settings(socket, params) do
    case Gtfs.update_route_operating_settings(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           route_setting_entries(socket, params)
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(:block_rules, @empty_block_rules)
         |> assign(:open_drawer, nil)
         |> load_day()
         |> resolve_drawers()
         |> assign_page_rows_if_loaded()
         |> put_flash(:info, "Block rules saved.")}

      {:error, {:invalid, invalid}} ->
        {:noreply,
         socket
         |> put_block_rules(params, nil, route_errors(socket, invalid))
         |> push_event("focus_form_error", %{
           form_id: "block-rules-form",
           fallback_id: "block-rules-errors"
         })
         |> put_flash(:error, @block_rules_partial)}

      {:error, _reason} ->
        {:noreply, put_block_rules(socket, params, @block_rules_save_failed)}
    end
  end

  # One entry per route the drawer read, with the reader's own two values when
  # the table posted them and the stored value otherwise.
  defp route_setting_entries(socket, params) do
    state = socket.assigns.block_rules
    submitted = Map.merge(state.route_params, route_settings_params(params))

    Enum.map(state.routes, fn route ->
      values = Map.get(submitted, route.route_id, %{})

      %{
        route_id: route.route_id,
        garage_id: Map.get(values, "garage_id", route.garage_id),
        required_vehicle_type_id:
          Map.get(values, "required_vehicle_type_id", route.required_vehicle_type_id)
      }
    end)
  end

  # The refusals keyed by the entry and field they name, so each row's own select
  # shows its own message instead of a drawer-level sentence. A refusal for a
  # route the drawer does not show is dropped rather than printed on another
  # route's row.
  defp route_errors(socket, invalid) do
    shown = MapSet.new(Enum.map(socket.assigns.block_rules.routes, & &1.route_id))

    Enum.reduce(invalid, %{}, fn
      %{route_id: route_id, field: _field, message: _message}, errors
      when route_id in [nil] ->
        errors

      %{route_id: route_id, field: field, message: message}, errors ->
        if MapSet.member?(shown, route_id) do
          Map.put_new(errors, {route_id, field}, message)
        else
          errors
        end
    end)
  end

  # One writer call per changed row, in the order the drawer listed them, and the
  # day reloads once at the end so the blocks, the gap bars and the scope button
  # are drawn under the new times. A row the context refuses keeps the drawer's
  # own sentence, so the page says what actually happened rather than claiming a
  # whole failed save.
  defp save_driving_entries(socket, state, entries) do
    result =
      Enum.reduce_while(entries, {:ok, 0}, fn {_key, pair, minutes}, {:ok, count} ->
        case Gtfs.put_deadhead_time(
               socket.assigns.current_organization.id,
               socket.assigns.current_gtfs_version.id,
               pair,
               minutes
             ) do
          {:ok, _row} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, count} when count > 0 ->
        {:noreply,
         socket
         |> redraw_driving_times(state)
         |> put_flash(:info, driving_times_entered(count))}

      {:ok, 0} ->
        {:noreply,
         socket
         |> assign(:driving_times, %{state | params: %{}, errors: %{}})
         |> put_flash(:info, "No changes")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_driving_error(socket, state, @driving_times_save_failed)}

      {:error, _reason} ->
        {:noreply, put_driving_error(socket, state, @driving_times_save_failed)}
    end
  end

  defp driving_times_entered(1), do: "1 driving time entered"
  defp driving_times_entered(count), do: "#{count} driving times entered"

  # The reload after a stored change: the day redraws and the rows are read
  # again, so the row a reader just entered shows its Entered badge and its reset
  # button. The draft goes with them, because those minutes are the version's
  # now; the “Estimated only” filter is the reader's own choice rather than a
  # value, so it survives the reload.
  defp redraw_driving_times(socket, state) do
    only = state.estimated_only?

    socket
    |> assign(:driving_times, %{@empty_driving_times | estimated_only?: only})
    |> load_day()
    |> resolve_drawers()
    |> assign_page_rows_if_loaded()
    |> keep_driving_filter(only)
  end

  defp keep_driving_filter(socket, estimated_only?) do
    assign(socket, :driving_times, %{
      socket.assigns.driving_times
      | estimated_only?: estimated_only?
    })
  end

  defp put_driving_error(socket, state, message) do
    assign(socket, :driving_times, %{state | error: message})
  end

  defp put_driving_draft(state, submitted) do
    %{state | params: Map.merge(state.params, submitted)}
  end

  # Only the drawer's own inputs are read, and only the rows it listed are looked
  # up, so a crafted event cannot name a reference the day type does not drive.
  defp driving_times_params(%{"minutes" => values}) when is_map(values) do
    Map.new(values, fn {key, value} -> {key, to_string(value)} end)
  end

  defp driving_times_params(_params), do: %{}

  # The ordered pair of one listed row, in the stored `from|to` form
  # `list_deadhead_pairs/3` hands out. A pair the drawer does not show is `nil`,
  # so neither a reset nor a save can write a reference from the payload.
  defp listed_pair(state, key) do
    case Enum.find(state.pairs, &(pair_key(&1) == key)) do
      %{from: from, to: to} -> {from, to}
      _other -> nil
    end
  end

  # One entry per row whose minutes differ from the ones the drawer listed, and
  # one error per row whose value is not a whole number of minutes in 0–600. A
  # row the version cannot measure lists no minutes at all, so a blank input
  # there is a row with no entry rather than a refused one — otherwise one
  # unmeasurable pair would block every other row of the day.
  defp driving_time_entries(state, submitted) do
    {entries, errors} =
      Enum.reduce(state.pairs, {[], %{}}, fn pair, {entries, errors} ->
        key = pair_key(pair)

        # A row the filter is hiding is not in the payload at all, so the value
        # to judge is the one the reader typed for it earlier, not the listed
        # value: hiding a row must not throw away an entry.
        value =
          Map.get(submitted, key) || Map.get(state.params, key) || minutes_text(pair.minutes)

        if String.trim(value) == "" and is_nil(pair.minutes) do
          {entries, errors}
        else
          reduce_minutes_entry({entries, errors}, key, pair, value)
        end
      end)

    {Enum.reverse(entries), errors}
  end

  defp reduce_minutes_entry({entries, errors}, key, pair, value) do
    case minutes_entry(value) do
      {:ok, minutes} when minutes == pair.minutes ->
        {entries, errors}

      {:ok, minutes} ->
        {[{key, {pair.from, pair.to}, minutes} | entries], errors}

      :error ->
        {entries, Map.put(errors, key, @driving_minutes_error)}
    end
  end

  defp minutes_entry(value) do
    trimmed = String.trim(value)

    cond do
      not Regex.match?(~r/\A\d+\z/, trimmed) -> :error
      String.to_integer(trimmed) > 600 -> :error
      true -> {:ok, String.to_integer(trimmed)}
    end
  end

  defp pair_key(%{from: from, to: to}), do: from <> "|" <> to

  # The Driving times drawer lists the loaded day type's pairs through the
  # context's own `list_deadhead_pairs/3`, so a row's minutes and source are the
  # ones the day's movements were built from. The read happens here, in
  # the URL change that opens the drawer, and never in `render/1`. A draft
  # is kept while the same version and day type stay on screen, so opening the
  # drawer again, filtering it or pressing a gap drawer's link does not discard
  # what was typed; a day type or version change drops it, because those minutes
  # belonged to another day's pairs.
  defp resolve_driving_times(
         %{assigns: %{driving_times: %{key: key}}} = socket,
         day,
         :driving_times
       )
       when not is_nil(key) and not is_nil(day) do
    if key == driving_times_key(socket, day) do
      socket
    else
      load_driving_times(socket, day)
    end
  end

  defp resolve_driving_times(%{assigns: %{day: day}} = socket, day, :driving_times)
       when not is_nil(day),
       do: load_driving_times(socket, day)

  defp resolve_driving_times(socket, _day, _drawer), do: socket

  defp load_driving_times(socket, day) do
    key = driving_times_key(socket, day)

    case Gtfs.list_deadhead_pairs(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           day.day_type && day.day_type.key
         ) do
      {:ok, pairs} ->
        assign(socket, :driving_times, %{@empty_driving_times | key: key, pairs: pairs})

      {:error, _reason} ->
        assign(socket, :driving_times, %{
          @empty_driving_times
          | key: key,
            error: @driving_times_unreadable
        })
    end
  end

  defp driving_times_key(socket, day),
    do: {socket.assigns.state.version_id, day.day_type && day.day_type.key}

  # The Operator changes drawer reads the same day load's candidates through the
  # context's own `list_relief_candidates/3`, in the URL change that opens it and
  # never in `render/1`. A draft is kept while the same version and day
  # type stay on screen, so opening the drawer again does not discard what was
  # typed; a day type or version change drops it, because those marks belonged to
  # another day's candidates.
  defp resolve_operator_changes(
         %{assigns: %{operator_changes: %{key: key}}} = socket,
         day,
         :operator_changes
       )
       when not is_nil(key) and not is_nil(day) do
    if key == operator_changes_key(socket, day) do
      socket
    else
      load_operator_changes(socket, day)
    end
  end

  defp resolve_operator_changes(%{assigns: %{day: day}} = socket, day, :operator_changes)
       when not is_nil(day),
       do: load_operator_changes(socket, day)

  defp resolve_operator_changes(socket, _day, _drawer), do: socket

  defp load_operator_changes(socket, day) do
    key = operator_changes_key(socket, day)

    case Gtfs.list_relief_candidates(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           day.day_type && day.day_type.key
         ) do
      {:ok, candidates} ->
        assign(socket, :operator_changes, %{
          @empty_operator_changes
          | key: key,
            candidates: candidates,
            limit: piece_limit_text(socket.assigns.settings.max_piece_minutes)
        })

      {:error, _reason} ->
        assign(socket, :operator_changes, %{
          @empty_operator_changes
          | key: key,
            error: @operator_changes_unreadable
        })
    end
  end

  defp operator_changes_key(socket, day),
    do: {socket.assigns.state.version_id, day.day_type && day.day_type.key}

  # --- the Suggest blocks drawer ----------------------------

  # The drawer's scope is derived, not read: the reader chose it, and opening the
  # drawer is the moment the choice is made. A block selection is an explicit
  # answer about which blocks to plan again, so it is the scope offered when the
  # timeline has one — which is what “Rebuild selected blocks” means; with no
  # selection the day type's unassigned trips are the safe default, and the
  # rebuild-all scope stays one click away.
  defp resolve_suggest(socket, :suggest) do
    assign(socket, :suggest, %{@empty_suggest | scope: suggest_scope(socket)})
  end

  defp resolve_suggest(socket, _drawer), do: assign(socket, :suggest, @empty_suggest)

  defp suggest_scope(%{assigns: %{selected_blocks: [_ | _]}}), do: :selected
  defp suggest_scope(%{assigns: %{suggest_pool_count: 0}}), do: :replace_all
  defp suggest_scope(_socket), do: :unassigned_only

  # The page action's own reason for being off. A version with no garage cannot
  # produce a suggestion, and a suggestion already on the page is not replaced by
  # another one: the reader discards or re-opens it first.
  defp suggest_title(false, _previewing?), do: "Add a garage in Settings first"

  defp suggest_title(_garages?, true),
    do: "Discard the suggestion before suggesting again."

  defp suggest_title(_garages?, _previewing?), do: nil

  @scopes [:unassigned_only, :selected, :replace_all]

  # A radio carries its scope as the string the drawer's option values use, while
  # the rest of the page works in the atoms `suggest_mode/2` and the panel take.
  # The value is therefore read by name: a payload that is not one of the three
  # names changes nothing, and a payload that is one of them is stored as the
  # atom the rest of the page compares against — a scope the reader chose but the
  # page ignored would plan the default scope and say it had planned the chosen
  # one.
  defp suggest_scope?(value) when is_binary(value),
    do: Enum.any?(@scopes, &(to_string(&1) == value))

  defp suggest_scope?(value), do: value in @scopes

  defp suggest_scope_name(value) when is_binary(value),
    do: Enum.find(@scopes, &(to_string(&1) == value))

  defp suggest_scope_name(value), do: if(value in @scopes, do: value)

  defp put_suggest(socket, state), do: assign(socket, :suggest, state)

  # The three scopes are the generator's three modes, so the drawer carries the
  # names a reader reads and the context carries the modes. The selected
  # mode names the blocks the reader actually selected, in the order the timeline
  # lists them, so the plan and the bar agree on which blocks are in scope.
  defp suggest_mode(:unassigned_only, _socket), do: :unassigned_only
  defp suggest_mode(:replace_all, _socket), do: :replace_all

  defp suggest_mode(:selected, socket),
    do: {:selected, Enum.map(socket.assigns.selected_blocks, & &1.summary.block_id)}

  # The request carries the identity of what was asked for, so a result that
  # arrives after the reader changed the day type, the version or the scope is
  # dropped rather than shown as a plan for something else. The organization
  # travels in it too, because the task that reads the plan has no socket.
  defp suggest_request(socket) do
    scope = socket.assigns.suggest.scope

    {socket.assigns.current_organization.id, socket.assigns.state.version_id,
     socket.assigns.day_type && socket.assigns.day_type.key, scope, suggest_mode(scope, socket)}
  end

  # The context call itself: the facade's `suggest_blocks/4`, which reads the
  # version's rows and writes nothing.
  defp run_suggestion({organization_id, version_id, day_type_key, _scope, mode}) do
    Gtfs.suggest_blocks(organization_id, version_id, day_type_key, mode)
  end

  # The result is one of the context's own answers, and each is handled where it
  # belongs: a plan is stored and the drawer closes, a too-large scope keeps the
  # drawer open with its count and writes no preview, and a scope with no
  # selection is refused in the drawer's own words.
  #
  # A stored plan is drawn on the page by `Blocking.preview_day/2`, which is pure:
  # the render assigns come from the proposal, the saved day in `:day` is
  # untouched, and no row is written. The preview is derived
  # here rather than in `render/1` for that reason, and the timeline is
  # re-streamed so a row that is now a different block arrives with its marker.
  defp apply_suggestion(socket, {:ok, plan}) do
    socket =
      socket
      |> assign(:plan_preview, plan)
      |> assign_runs_touched(plan)
      |> put_suggest(%{@empty_suggest | scope: socket.assigns.suggest.scope})
      |> assign(:open_drawer, nil)
      |> assign(:timeline_key, nil)
      |> show_preview(plan)
      |> assign_page_rows()

    patch(socket, %{trip: nil, gap: nil, block: nil, drawer: nil, pair: nil})
  end

  # These three answer the callback rather than an event handler, so each returns
  # `{:noreply, socket}`. The success clause above already does, through `patch/2`.
  defp apply_suggestion(socket, {:error, {:too_large, trips}}) do
    {:noreply, put_suggest(socket, %{socket.assigns.suggest | busy: false, too_large: trips})}
  end

  defp apply_suggestion(socket, {:error, :no_selection}) do
    {:noreply,
     put_suggest(socket, %{socket.assigns.suggest | busy: false, error: @suggest_no_selection})}
  end

  defp apply_suggestion(socket, {:error, _reason}) do
    {:noreply,
     put_suggest(socket, %{socket.assigns.suggest | busy: false, error: @suggest_unavailable})}
  end

  # The dialog names the trips the rebuild would move and the day types it would
  # change, from the plan the reader is looking at rather than from a count typed
  # into the dialog.
  defp replace_confirmation(socket) do
    plan = socket.assigns.plan_preview

    %{
      open?: true,
      moves: length(plan.moves),
      days: Enum.map(plan.review.effects, & &1.day_type.label)
    }
  end

  # How many runs contain the trips this suggestion moves, computed once here
  # rather than in the render.
  #
  # A render-time query would be wrong twice over: `render/1` must stay a pure
  # function of its assigns, and a preview is re-rendered on every event on the
  # page — a sort, a scale change, a selected trip. The count is a fact about the
  # plan, not about the page, so it is taken where the plan is stored.
  #
  # It reflects the runs as they are saved, because a Blocks preview writes
  # nothing until Apply.
  defp assign_runs_touched(socket, plan) do
    trip_ids = plan.moves |> Enum.map(& &1.trip.id) |> Enum.uniq()

    count =
      Gtfs.count_runs_for_trips(
        socket.assigns.current_organization.id,
        socket.assigns.current_gtfs_version.id,
        trip_ids
      )

    assign(socket, :runs_touched, count)
  end

  # The write itself: one `start_async` task over the plan this page is showing,
  # carrying the request that named it, so a result that arrives after the reader
  # discarded the suggestion or switched day type is dropped rather than shown as
  # this plan's outcome.
  defp start_apply(socket) do
    if editor_access?(socket) do
      request = apply_request(socket)

      socket =
        socket
        |> assign(:apply, %{
          status: :pending,
          title: @apply_pending_title,
          message: @apply_pending_message,
          reason: nil
        })
        |> assign(:applied, nil)

      start_async(socket, @apply_suggestion_key, fn -> {request, run_apply(request)} end)
    else
      put_flash(socket, :error, @permission_message)
    end
  end

  defp apply_request(socket) do
    %{
      organization_id: socket.assigns.current_organization.id,
      version_id: socket.assigns.current_gtfs_version.id,
      day_type_key: socket.assigns.day_type && socket.assigns.day_type.key,
      plan: socket.assigns.plan_preview,
      audit: audit_context(socket)
    }
  end

  # The context call itself: the facade's `apply_block_plan/3`, which is the one
  # write path for a plan.
  defp run_apply(request) do
    Gtfs.apply_block_plan(request.day_type_key, request.plan, request.audit)
  end

  # The plan's own fingerprint is the identity: a preview that was discarded,
  # rebuilt or replaced by a day switch is a different plan, and a result about
  # the old one must not repaint the page.
  defp request_matches?(%{plan: plan}, plan), do: true
  defp request_matches?(_request, _plan), do: false

  # The three answers and the success:
  #
  #   * `:stale_plan` keeps the preview and turns Apply off, because the plan the
  #     reader reviewed is not the plan the context would write; “Suggest again”
  #     is the primary action and the reason is printed beside the button.
  #   * `:busy` and `{:audit_failed, _}` keep the preview and the buttons, with
  #     “Apply again”, because nothing was written and the same attempt is worth
  #     repeating.
  #   * `{:ok, _}` drops the preview, clears the block selection, reloads the day
  #     so the rows are the applied plan's, and leaves the applied message where
  #     the panel was.
  defp apply_apply_result(socket, plan, {:ok, _result}) do
    days = Enum.map_join(plan.review.effects, " and ", & &1.day_type.label)
    moves = length(plan.moves)

    socket =
      socket
      |> load_day()
      |> assign(:apply, @empty_apply)
      |> assign(:replace, @no_replace)
      |> assign(:applied, %{
        moves: moves,
        message:
          "#{moves} #{plural(moves, "trip")} changed block across #{days}. " <>
            "Each trip's change history lists its previous block."
      })
      # A successful apply clears the block selection: those blocks were
      # rebuilt, so a selection of them describes work that is already done.
      |> assign(:block_selection, MapSet.new())
      |> assign(:selected_blocks, [])
      # The reloaded day is streamed again, so the rows are the applied plan's and
      # carry no "Changed · not saved" marker: the change is saved now.
      |> assign_page_rows_if_loaded()

    {:noreply, push_event(socket, "focus_scoped_target", %{id: "suggestion-applied"})}
  end

  defp apply_apply_result(socket, _plan, {:error, :stale_plan}) do
    socket =
      put_apply(
        socket,
        :stale,
        @apply_stale_title,
        @apply_stale_message,
        @apply_stale_reason
      )
      |> assign(:replace, @no_replace)

    {:noreply, push_event(socket, "focus_scoped_target", %{id: "suggestion-apply-message"})}
  end

  defp apply_apply_result(socket, _plan, {:error, :busy}) do
    {:noreply,
     push_event(
       put_apply(socket, :busy, @apply_busy_title, @apply_busy_message),
       "focus_scoped_target",
       %{id: "suggestion-apply-message"}
     )}
  end

  defp apply_apply_result(socket, _plan, {:error, _reason}) do
    {:noreply,
     push_event(
       put_apply(socket, :failed, @apply_failed_title, @apply_failed_message),
       "focus_scoped_target",
       %{id: "suggestion-apply-message"}
     )}
  end

  defp put_apply(socket, status, title, message, reason \\ nil) do
    assign(socket, :apply, %{
      status: status,
      title: title,
      message: message,
      reason: reason
    })
  end

  # The three scope cards. Each carries the generator's
  # own mode under the name a reader reads, the trips the scope would plan, and
  # whether it can be chosen at all on this day type. “Selected blocks” names the
  # blocks in the timeline's own order, so the drawer, the selection bar and the
  # mode the plan was built from are the same list.
  defp suggest_scope_options(assigns) do
    selected = Enum.map(assigns.selected_blocks, & &1.summary.block_id)
    unassigned = assigns.suggest_pool_count

    [
      %{
        value: :unassigned_only,
        title: "Unassigned trips only",
        description:
          "Keep current blocks. Add the #{unassigned} unassigned #{plural(unassigned, "trip")} to existing or new blocks.",
        disabled?: unassigned == 0
      },
      %{
        value: :selected,
        title: "Selected blocks#{selected_title(selected)}",
        description:
          if(selected == [],
            do: @suggest_no_selection,
            else:
              "Plan these blocks’ trips again. Other blocks and unassigned trips stay as they are."
          ),
        disabled?: selected == []
      },
      %{
        value: :replace_all,
        title: "Rebuild this service day’s blocks",
        description:
          "Plan every scheduled trip again. Hand-tuned blocks may change; applying asks you to confirm.",
        disabled?: false
      }
    ]
  end

  defp selected_title([]), do: ""
  defp selected_title(selected), do: " (#{Enum.join(selected, ", ")})"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  # The rules the suggestion would use, read from the loaded day's own settings
  # and relief marks. They are the same answers the Block rules and Operator
  # changes drawers print, taken from the same load, so the drawer cannot describe
  # rules the generator would not apply.
  defp suggest_rules(assigns) do
    settings = assigns.settings

    [
      {"Minimum layover", "#{assigns.min_layover_minutes} min"},
      {"Longest time out", longest_time_out(Map.get(settings, :max_block_minutes))},
      {"Route switches", route_switches(Map.get(settings, :interlining))},
      {"Operator changes",
       operator_changes(Map.get(settings, :max_piece_minutes), assigns.relief_stop_count)}
    ]
  end

  defp longest_time_out(nil), do: "Vehicle type limits"
  defp longest_time_out(minutes), do: "#{minutes} min"

  defp route_switches(:same_stop), do: "Same stop only"
  defp route_switches(:none), do: "Not allowed"
  defp route_switches(_any), do: "Anywhere"

  defp operator_changes(nil, _marks), do: "Not checked"
  defp operator_changes(minutes, marks), do: "Within #{minutes} min · #{marks} marked"

  # The repeating trips of the day type, named as the GTFS names them. Repeating
  # service is never blocked, so every one of them is in the pool and the note is
  # exactly the set of trips no scope of the drawer can plan.
  defp repeating_trip_ids(day),
    do: day.pool |> Enum.filter(& &1.frequency?) |> Enum.map(& &1.trip_id)

  # With no stored limit the field is pre-filled with the researched common
  # contract limit rather than left blank, because a blank limit is a real
  # answer — it turns the checks off — and an empty field would offer that answer
  # before the reader has read it.
  defp piece_limit_text(nil), do: to_string(@default_piece_minutes)
  defp piece_limit_text(minutes), do: to_string(minutes)

  # A refusal the limit field can explain is that field's own error, so the
  # shared `input` marks the field invalid and the drawer's focus hook moves
  # focus onto it; anything else is the drawer's own sentence above the form.
  defp put_operator_limit_error(socket, state, limit, marked, message) do
    assign(socket, :operator_changes, %{
      state
      | limit: limit,
        marked: marked,
        limit_error: message,
        error: nil
    })
  end

  defp put_operator_error(socket, state, limit, marked, message) do
    assign(socket, :operator_changes, %{
      state
      | limit: limit,
        marked: marked,
        limit_error: nil,
        error: message
    })
  end

  # The ticked candidate IDs of a submitted form, narrowed to the candidates the
  # drawer listed, so a crafted payload cannot mark a stop the day type does not
  # offer as one. The context recomputes them under its own lock anyway; this
  # keeps the tick the reader is shown and the tick that is written the same set.
  defp listed_marks(state, marked) when is_list(marked) do
    candidates = MapSet.new(state.candidates, & &1.stop_id)

    marked
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
    |> MapSet.intersection(candidates)
    |> MapSet.to_list()
  end

  # An unticked form posts no `marked` key at all, which is the reader's decision
  # to clear every mark rather than a payload to be discarded; a crafted
  # non-list value reads the same way, because clearing marks is the one answer
  # that cannot reach a stop the drawer did not offer.
  defp listed_marks(_state, _not_a_list), do: []

  # The one write this drawer owns. The page judges the limit against the same
  # 60–720 range the context's changeset enforces, so a value the page accepts
  # is one the context accepts; a refusal the page cannot explain (an unpublished
  # version, an unknown day type) keeps the drawer and every entry with its own
  # sentence. A save reloads the day so the checks, the timeline's change marks
  # and the Plan summary read the stored answer rather than the draft.
  defp save_operator_changes(socket, state, limit, marked) do
    case piece_limit_entry(limit) do
      :error ->
        {:noreply,
         socket
         |> put_operator_limit_error(state, limit, marked, @operator_limit_error)
         |> push_event("focus_form_error", %{
           form_id: "operator-changes-form",
           fallback_id: "operator-changes-limit"
         })}

      {:ok, minutes} ->
        write_operator_changes(socket, state, minutes, marked, limit)
    end
  end

  defp write_operator_changes(socket, state, minutes, marked, limit) do
    case Gtfs.update_relief_settings(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           socket.assigns.day_type && socket.assigns.day_type.key,
           %{max_piece_minutes: minutes, marked: marked}
         ) do
      {:ok, :ok} ->
        socket =
          socket
          |> assign(:operator_changes, @empty_operator_changes)
          |> load_day()
          |> resolve_drawers()
          |> assign_page_rows_if_loaded()
          |> put_flash(:info, operator_changes_saved(minutes))

        {:noreply, close_operator_drawer(socket)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_operator_limit_error(socket, state, limit, marked, @operator_limit_error)}

      {:error, _reason} ->
        {:noreply,
         put_operator_error(socket, state, limit, marked, @operator_changes_save_failed)}
    end
  end

  defp operator_changes_saved(nil), do: "Operator checks turned off"
  defp operator_changes_saved(_minutes), do: "Operator changes saved"

  # The save closes the drawer: the page behind it is
  # where the answer is read, and the flash only renders once the top-layer
  # dialog is gone. The `open_drawer` assign is cleared as well as the
  # URL parameter, because `resolve_drawers/1` keeps the last open panel when the
  # URL names none — patching the parameter alone would reload the day's answers
  # and leave the drawer standing on top of them.
  defp close_operator_drawer(socket) do
    socket = assign(socket, :open_drawer, nil)
    state = socket.assigns.state

    if state.drawer == "operator_changes" do
      push_patch(socket, to: blocks_path(%{state | drawer: nil}))
    else
      socket
    end
  end

  # The limit is 60–720 or blank, exactly the range the context's changeset
  # enforces on the relief limit. A blank limit stores `nil`, which turns
  # the `:no_relief_opportunity` checks off rather than refusing the save.
  defp piece_limit_entry(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:ok, nil}

      not Regex.match?(~r/\A\d+\z/, trimmed) ->
        :error

      String.to_integer(trimmed) < 60 or String.to_integer(trimmed) > 720 ->
        :error

      true ->
        {:ok, String.to_integer(trimmed)}
    end
  end

  # One row per listed pair, in the context's own order, with the index the input
  # id and the row id use. The index is assigned before the “Estimated only” filter
  # narrows the rows, so a filter change never renames an input the reader is
  # typing into. The minutes shown are the ones the reader typed for this row, or
  # the listed value, or a blank for a pair the version cannot measure.
  defp driving_times_rows(assigns) do
    state = assigns.driving_times
    highlight = blank_to_nil(assigns.state.pair)

    state.pairs
    |> Enum.with_index()
    |> Enum.map(fn {pair, index} -> driving_time_row(pair, index, state, highlight) end)
    |> Enum.filter(fn row -> not state.estimated_only? or row.source == :estimated end)
  end

  defp driving_time_row(pair, index, state, highlight) do
    key = pair_key(pair)

    %{
      key: key,
      dom_id: "driving-time-row-#{index}",
      input_id: "driving-minutes-#{index}",
      from_label: pair.from_label,
      to_label: pair.to_label,
      uses: pair.uses,
      source: pair.source,
      value: Map.get(state.params, key) || minutes_text(pair.minutes),
      error: Map.get(state.errors, key),
      highlighted?: key == highlight
    }
  end

  defp minutes_text(nil), do: ""
  defp minutes_text(minutes), do: Integer.to_string(minutes)

  # The drawer focuses the row a link named, and the first field otherwise.
  defp driving_times_focus_id(rows) do
    case Enum.find(rows, & &1.highlighted?) do
      nil -> nil
      row -> row.input_id
    end
  end

  defp driving_times_estimated_count(pairs) do
    Enum.count(pairs, &(&1.source == :estimated))
  end

  # One row per candidate the context listed, in that order, with the index the
  # row and checkbox ids use. A tick the reader has made and not yet saved is
  # the drawer's own, so a refused save shows exactly the marks the reader
  # chose rather than the stored ones.
  defp operator_changes_rows(assigns) do
    state = assigns.operator_changes

    state.candidates
    |> Enum.with_index()
    |> Enum.map(fn {candidate, index} ->
      %{
        dom_id: "operator-candidate-row-#{index}",
        input_id: "operator-candidate-#{index}",
        stop_id: candidate.stop_id,
        name: candidate.name,
        station?: candidate.station?,
        child_names: candidate.child_names,
        waits: candidate.waits,
        marked?: operator_marked?(state, candidate)
      }
    end)
  end

  defp operator_marked?(%{marked: nil}, candidate), do: candidate.marked?
  defp operator_marked?(state, candidate), do: candidate.stop_id in state.marked

  # --- editor authority ------------------------------------------------------

  # The role is re-read from the membership on every mutating event, so a role
  # revoked while the page is open refuses the next write. This is the stricter
  # form of the `has_role?(@user_roles, :pathways_studio_editor)` check: the
  # assign is only a snapshot from mount.
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
  # the URL-safe Base64 token keeps the id within ASCII.
  defp block_dom_id(block),
    do: "block-" <> Base.url_encode64(block.summary.block_id, padding: false)

  defp pool_dom_id(trip), do: "pool-" <> Base.url_encode64(trip.trip_id, padding: false)

  # Each finding names trips by UUID, and the List view, the pool and the
  # untimed list print a trip's own findings. Grouping once per load keeps that
  # lookup out of the render path.
  defp findings_by_trip(findings) do
    findings
    |> Enum.flat_map(fn finding -> Enum.map(finding.trip_ids, &{&1, finding}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp assign_derived(socket, day) do
    selection = retain_in_day(socket.assigns.selection, day)
    block_selection = retain_blocks_in_day(socket.assigns.block_selection, day)

    socket
    |> assign(:selection, selection)
    |> assign(:selected_trips, selected_trips(day, selection))
    |> assign(:block_selection, block_selection)
    |> assign(:selected_blocks, selected_blocks(day, block_selection))
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
      # The Suggest blocks drawer's two day facts: how many trips the
      # unassigned scope would plan, and which repeating service is left out of
      # every scope. Both come from the day's own pool, so the drawer and the
      # generator read the same trips. Repeating service is never blocked,
      # so it is always in the pool.
      suggest_pool_count: Enum.count(day.pool, &(not &1.frequency?)),
      suggest_repeating_trip_ids: repeating_trip_ids(day),
      estimated?: day.estimated_pairs > 0,
      estimated_pairs: day.estimated_pairs,
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
      # The whole settings row, so the Block rules drawer renders every
      # field from the day load rather than a second read.
      settings: day.settings,
      untimed_trips: Enum.filter(day.unplottable, & &1.block_id),
      # The Garage and Vehicle type form's pickers read the planning inputs the
      # day load already gathered, in the order a reader scans them.
      garages: garage_options(day.context.garages),
      vehicle_types: vehicle_type_options(day.context.vehicle_types),
      # The per-route requirements behind the form's two help lines. They are
      # planning inputs like the rest of the context and are read here only to
      # explain a value, never to resolve one.
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
  # The movements are the platform spans the block movements already derived, and the
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
      suggest_pool_count: 0,
      suggest_repeating_trip_ids: [],
      estimated?: false,
      estimated_pairs: 0,
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
      settings: %{},
      untimed_trips: [],
      garages: [],
      vehicle_types: [],
      route_settings: %{},
      selected_trips: [],
      selected_blocks: [],
      block_selection: MapSet.new(),
      pool_page_ids: MapSet.new(),
      timeline_page_ids: MapSet.new(),
      timeline_block_ids: MapSet.new(),
      visible_count: 0,
      timeline_key: nil,
      pool_visible_count: 0,
      pool_key: nil
    )
    |> stream(:block_rows, [], reset: true)
    |> stream(:list_rows, [], reset: true)
    |> stream(:pool_rows, [], reset: true)
  end

  # The plan figures of one day type, as the day load derived them, and the
  # short fleet rows with the garage and type names the day resolved, so
  # `render/1` prints numbers and words rather than re-deriving either.
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
  # type names the day resolved. The `:all` row is the garage's total,
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
  def handle_async(@suggest_preview_key, {:ok, {request, result}}, socket) do
    if request == suggest_request(socket) do
      # `apply_suggestion/2` answers the callback's own `{:noreply, socket}`
      # where the preview lands, so its result is returned as it stands.
      apply_suggestion(socket, result)
    else
      # A day type, version or scope changed while the suggestion was being
      # built, so the plan describes a scope the reader is no longer looking at.
      {:noreply, socket}
    end
  end

  # A task that exited rather than returning carries no plan, and no refusal the
  # drawer can explain: the drawer's own sentence, and no preview.
  def handle_async(@suggest_preview_key, {:exit, _reason}, socket) do
    {:noreply,
     put_suggest(socket, %{socket.assigns.suggest | busy: false, error: @suggest_unavailable})}
  end

  # The apply's own result, in the same place as the preview's because both are
  # this page's asynchronous work and both must be able to drop a late result.
  def handle_async(@apply_suggestion_key, {:ok, {request, result}}, socket) do
    if request_matches?(request, socket.assigns.plan_preview) do
      apply_apply_result(socket, request.plan, result)
    else
      # The preview on the page is no longer the plan this result belongs to, so
      # the panel drops its own pending state and nothing else.
      {:noreply, put_apply(socket, :none, nil, nil)}
    end
  end

  # A task that exited rather than returning wrote nothing the page can report;
  # the failure sentence is the same one an audit failure gets.
  def handle_async(@apply_suggestion_key, {:exit, _reason}, socket) do
    {:noreply, put_apply(socket, :failed, @apply_failed_title, @apply_failed_message)}
  end

  # Dropping the preview is one step whatever the reader does next, so the day is
  # re-derived from the loaded day rather than from the previewed one, and the
  # timeline key is cleared so the container is replaced.
  defp drop_preview(socket) do
    socket
    |> assign(:plan_preview, nil)
    |> assign(:runs_touched, 0)
    |> assign(:preview_day, nil)
    |> assign(:suggestion, @empty_suggestion)
    |> assign(:apply, @empty_apply)
    |> assign(:replace, @no_replace)
    |> assign(:timeline_key, nil)
    |> assign_derived(socket.assigns.day)
    |> assign_page_rows()
  end

  # Everything the Suggested blocks panel renders, derived here rather than in
  # `render/1` so the render never reaches into the loaded day. The plan's
  # own numbers are read by the panel; the two this page owns are the minimum
  # vehicle count, which is the proposal's day load figure, and the problems the
  # plan takes away, which is the saved day's problems the proposal's no longer
  # has, keyed by `Checks.finding_key/1` — the key the review and the day load
  # count problems by, so “2 fixed” is never a second opinion about what a problem
  # is.
  defp show_preview(socket, plan) do
    preview = Blocking.preview_day(socket.assigns.day, plan)

    socket
    |> assign(:suggestion, %{
      plan: plan,
      scope: plan.mode && suggest_scope_of(plan.mode),
      picked: picked_blocks(plan.mode),
      minimum: preview.figures.minimum,
      fixed: fixed_problem_count(socket.assigns.day, preview),
      existing: existing_problem_count(socket.assigns.day, plan),
      # Both ends of every move, because a block that loses a trip and one that
      # gains one are both changed rows, and a new block has no `from` at all.
      changed_block_ids:
        plan.moves
        |> Enum.flat_map(fn move -> Enum.reject([move.from, move.to], &is_nil/1) end)
        |> MapSet.new()
    })
    |> assign(:preview_day, preview)
    |> assign_derived(preview)
  end

  defp suggest_scope_of(:unassigned_only), do: :unassigned_only
  defp suggest_scope_of({:selected, _ids}), do: :selected
  defp suggest_scope_of(:replace_all), do: :replace_all

  defp picked_blocks({:selected, ids}), do: ids
  defp picked_blocks(_mode), do: []

  # The saved day's own problems that the plan does not add: the day type's
  # errors and warnings less the keys the review lists as added, so “N existing
  # problems remain” counts what a reader sees on the page rather than only the
  # blocks the plan touched.
  defp existing_problem_count(day, plan) do
    added =
      plan.review.effects
      |> Enum.flat_map(& &1.added)
      |> MapSet.new(&Checks.finding_key/1)

    day.findings
    |> Enum.filter(&(&1.severity in [:error, :warning]))
    |> Enum.reject(&(Checks.finding_key(&1) in added))
    |> length()
  end

  defp fixed_problem_count(day, preview) do
    after_keys =
      preview.findings
      |> Enum.map(&Checks.finding_key/1)
      |> MapSet.new()

    day.findings
    |> Enum.filter(&(&1.severity in [:error, :warning]))
    |> Enum.reject(&(Checks.finding_key(&1) in after_keys))
    |> length()
  end

  @impl true
  def render(assigns) do
    {options, total} =
      destination_options(
        assigns.destination_blocks,
        assigns.assign && assigns.assign.search
      )

    {merge_options, merge_total} = merge_destinations(assigns)
    bulk = bulk_summary(assigns)

    block_rules_form = block_rules_form(assigns)
    driving_rows = driving_times_rows(assigns)
    operator_rows = operator_changes_rows(assigns)

    assigns =
      assigns
      |> assign(:driving_times_rows, driving_rows)
      |> assign(:operator_changes_rows, operator_rows)
      |> assign(:assign_form, assign_form(assigns.assign))
      |> assign(:block_action_form, block_action_form(assigns.block_action))
      |> assign(:block_rules_form, block_rules_form)
      |> assign(
        :block_rules_error_count,
        block_rules_error_count(block_rules_form, assigns.block_rules.route_errors)
      )
      |> assign(:destination_options, options)
      |> assign(:destination_total, total)
      |> assign(:merge_options, merge_options)
      |> assign(:merge_total, merge_total)
      |> assign(:bulk, bulk)
      |> assign(:selection_dates, selection_dates(assigns))
      |> assign(:primary, primary_owner(assigns, bulk))
      |> assign(:subtitle, @subtitle)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
      width="wide"
    >
      <:sub_header>
        <.operations_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:blocks} />
      </:sub_header>

      <div id="blocks-page" class="ds-page">
        <.header>
          Blocks
          <:subtitle>{@subtitle}</:subtitle>
          <%!-- The header's Review action is the page's primary until the selection
          bar, the first-use panel or a previewed suggestion takes it. --%>
          <:actions :if={@load_state == :loaded}>
            <%!-- A suggestion is built from garages, so a version with none cannot
            produce one; the button says why it is off rather than opening a drawer
            that could only fail. --%>
            <.button
              id="blocks-suggest"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="open_drawer"
              phx-value-key="suggest"
              disabled={not @garages? or not is_nil(@plan_preview)}
              title={suggest_title(@garages?, not is_nil(@plan_preview))}
            >
              Suggest blocks
            </.button>
            <.button
              id="blocks-review-checks"
              type="button"
              variant={if @primary == :head, do: "primary", else: "secondary"}
              class="min-h-11"
              phx-click="open_drawer"
              phx-value-key="checks"
            >
              {review_label(@counts.problems)}
            </.button>
          </:actions>
        </.header>

        <div class="space-y-4">
          <.message
            :if={@load_state == :unavailable}
            id="blocks-unavailable"
            kind="error"
            title="We couldn't load blocks."
          >
            Your saved assignments haven't changed. Reload to try again.
            <:action>
              <.button
                id="blocks-retry"
                type="button"
                variant="secondary"
                class="min-h-11"
                phx-click="retry"
              >
                <.icon name="hero-arrow-path" class="size-4" /> Reload blocks
              </.button>
            </:action>
          </.message>

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
              <.message
                :if={@mixed_timezones?}
                id="blocks-mixed-timezones"
                kind="warning"
                title="Agencies in this version use different time zones."
              >
                Times are shown as stored, so trips from different agencies may not line up.
              </.message>

              <div class="rounded-card border border-subtle bg-white">
                <BlocksComponents.scope_header
                  day_types={@day_types}
                  day_type={@day_type}
                  routes={@routes}
                  state={@state}
                  min_layover_minutes={@min_layover_minutes}
                  estimated_pairs={@estimated_pairs}
                  preview?={not is_nil(@plan_preview)}
                />
                <BlocksComponents.summary_strip
                  day_type={@day_type}
                  counts={@counts}
                  figures={@figures}
                  peak={@peak}
                  preview?={not is_nil(@plan_preview)}
                />
              </div>

              <BlocksComponents.plan_notices
                fleet_shortfalls={@fleet_shortfalls}
                garages?={@garages?}
                vehicles?={@vehicles?}
                version_id={@state.version_id}
              />

              <%!-- The panel sits between the notices and the workbench so the
              proposal, the counts above and the rows it changes are all on one
              screen: a preview is a reading of the page, not a replacement of it. --%>
              <BlocksComponents.suggestion_panel
                :if={not is_nil(@plan_preview)}
                plan={@suggestion.plan}
                day_type={@day_type}
                scope={@suggestion.scope}
                runs_touched={@runs_touched}
                version_id={@current_gtfs_version.id}
                picked={@suggestion.picked}
                minimum={@suggestion.minimum}
                existing_problems={@suggestion.existing}
                fixed_problems={@suggestion.fixed}
                repeating_trip_ids={@suggest_repeating_trip_ids}
                estimated_pairs={@estimated_pairs}
                apply={@apply}
              />

              <%!-- The applied message takes the panel's place once the plan is
              saved: there is no preview left to read, and the sentence that
              outlives it is the page's answer to what changed. --%>
              <BlocksComponents.suggestion_applied
                :if={is_nil(@plan_preview) and not is_nil(@applied)}
                applied={@applied}
              />

              <BlocksComponents.suggestion_replace_dialog
                :if={not is_nil(@plan_preview)}
                replace={@replace}
                day_type={@day_type}
                pending={@apply.status == :pending}
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
                selected_block_ids={@block_selection}
                page_block_ids={@timeline_block_ids}
                block_selected_count={length(@selected_blocks)}
                bulk={@bulk}
                primary={@primary}
                preview?={not is_nil(@plan_preview)}
                changed_block_ids={@suggestion.changed_block_ids}
              />

              <BlocksComponents.service_dates_drawer
                open={@open_drawer == :service_dates}
                day_type={@day_type}
              />
              <BlocksComponents.checks_drawer
                open={@open_drawer == :checks}
                day_type={@day_type}
                findings={@findings}
                trip_labels={@trip_labels}
              />
              <BlocksComponents.plan_summary_drawer
                open={@open_drawer == :plan_summary}
                figures={@figures}
                peak={@peak}
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
              <BlocksComponents.block_rules_drawer
                open={@open_drawer == :block_rules}
                form={@block_rules_form}
                interlining={@block_rules.interlining || to_string(@settings.interlining)}
                routes={@routes}
                route_rows={block_rules_rows(assigns)}
                route_errors={@block_rules.route_errors}
                garages={@garages}
                vehicle_types={@vehicle_types}
                error={@block_rules.error}
                error_count={@block_rules_error_count}
              />

              <BlocksComponents.driving_times_drawer
                open={@open_drawer == :driving_times}
                rows={@driving_times_rows}
                day_label={@day_type.label}
                circuity={@settings.deadhead_circuity}
                speed={@settings.deadhead_speed_kmh}
                estimated_only?={@driving_times.estimated_only?}
                estimated_count={driving_times_estimated_count(@driving_times.pairs)}
                total_count={length(@driving_times.pairs)}
                focus_id={driving_times_focus_id(@driving_times_rows)}
                error={@driving_times.error}
              />

              <BlocksComponents.operator_changes_drawer
                open={@open_drawer == :operator_changes}
                rows={@operator_changes_rows}
                limit={@operator_changes.limit}
                limit_error={@operator_changes.limit_error}
                error={@operator_changes.error}
              />

              <BlocksComponents.suggest_drawer
                open={@open_drawer == :suggest}
                scope={@suggest.scope}
                options={suggest_scope_options(assigns)}
                rules={suggest_rules(assigns)}
                estimated_pairs={@estimated_pairs}
                repeating_trip_ids={@suggest_repeating_trip_ids}
                operator_checked?={not is_nil(@max_piece_minutes)}
                too_large={@suggest.too_large}
                error={@suggest.error}
                busy={@suggest.busy}
                day_label={@day_type.label}
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
      </div>
    </Layouts.app>
    """
  end
end
