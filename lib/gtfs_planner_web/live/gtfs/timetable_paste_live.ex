defmodule GtfsPlannerWeb.Gtfs.TimetablePasteLive do
  @moduledoc """
  Paste timetable page shell: the header, the schedule line and the setup
  empty states, plus the Change schedule drawer.

  Step 21 owns the shell: `handle_params` resolves the paste scope through
  `Gtfs.prepare_timetable_paste/5` with the LiveView's input (blank, so
  `review: nil`) and canonicalizes the `service_id`/`direction`/`pattern`
  URL parameters with a replace patch, like `RouteSchedulesLive`
  canonicalizes its filters. A foreign scope navigates back to Routes with
  a not-found flash, also like `RouteSchedulesLive`.

  Step 22 owns the scope drawer: `open_scope_drawer` drafts the current
  scope (every calendar from `Gtfs.list_calendars/3`, the draft direction's
  patterns with trip counts), `scope_draft_change` refilters the draft
  patterns when the calendar or direction changes, and `change_schedule`
  `push_patch`es the new params while the LiveView keeps `input.text`,
  clears the overrides/confirmations/decisions and re-reviews with the new
  scope on the patch.

  Step 23 owns the timetable step: the `#paste-form` (`phx-change="input"`,
  `phx-submit="read"`) wraps `TimetablePasteComponents.source_step/1` and
  the columns/review placeholders steps 24-28 fill. The `input` event stashes
  the text, layout and header without touching the database; the `read` event
  re-resolves the scope through `Gtfs.prepare_timetable_paste/5` with the
  full current input. Parse failures keep the text and render the specific
  inline message; success collapses the step and auto-advances to the review
  placeholder when no column issues remain. The review UI (steps 25-28)
  builds on the `input`/`review` assigns kept here. The
  version-switch events mirror `RouteSchedulesLive`; the unsaved-work
  confirmation arrives in step 30.

  Step 24 owns the columns step: the Use-as selects post back into the
  `input` event as `paste[overrides][<col>]`, which is diffed against the
  review's effective values so untouched columns never pin their automatic
  pick; `confirm_column` records a close-match confirmation. Both recompute
  the review purely from the loaded scope through
  `TimetablePaste.review/2` (no database read); `to_review` with issues
  shows the error summary and focuses it.

  Step 25 owns the review header controls: the How-to-apply radios
  (`paste[mode]`), the Fill-other-stops-from select
  (`paste[template_timing_id]`) and the Stops-view radios
  (`paste[stops_view]`) ride the same `input` event as native form fields.
  A mode or template change recomputes the review purely from the loaded
  scope, like an override edit; stops-view and filter changes only restash
  the input for display. `use_add` returns a refused Replace to Add mode;
  `paste_filter` records the row filter. The review matrix (step 26),
  decisions (step 27) and apply (step 28) build on the `input`/`review`
  assigns kept here.

  Step 26 owns the review matrix: the `#paste-rows` stream of row view
  models built by `TimetablePasteReview` from the plan changes, the
  `#paste-timing-note` popover behind the `paste_timing` events, and the
  Warnings filter step 25 deferred. Every path that assigns a review or
  changes the filter or stops view re-streams `:plan_rows` with
  `reset: true` through `put_plan_rows/1`; counts live in the separate
  `:plan_total`/`:plan_shown` assigns because streams are not countable.

  Step 27 owns the row decisions: the pattern select, the cell correction,
  the twelve-hour choice and the pairing radios post back through the
  `input` event as `paste[pattern_choices]`/`paste[cells]`/`paste[pairs]`
  (diffed like the column overrides, so untouched controls never write a
  decision), while the twelve-hour buttons and skip/restore/Add-anyway
  arrive as discrete `paste_*` events. Every decision event updates
  `input.decisions` and recomputes the review purely from the loaded scope
  (no database read). The `#paste-decisions` hidden input holds the
  Jason-encoded decisions, so a reconnect into a new process re-sends
  them with the form params and the `input` handler restores them.

  Step 28 owns the apply bar, the Replace and Discard confirmations and
  every apply outcome. `paste_apply` first surfaces open decisions in
  `#paste-review-errors` (focused, button still enabled), then opens
  `#paste-replace-confirm` for a Replace with removals or transfers, then
  re-checks the editor role like `RouteSchedulesLive.editor_access?/1`
  before calling `Gtfs.apply_timetable_paste/5`. `:stale_plan` keeps the
  input and offers Review again (which reloads the scope); `:busy` offers
  Apply again; an R9 `{:mixed_service, details}` refusal shows Schedules'
  refusal copy; anything else failed offers Try again with a reference id;
  a missing role shows the permission notice and writes nothing. Clicking
  Apply also marks the hidden `#paste-applying` flag, so a reconnect
  during the apply recovers through form recovery into the unknown
  notice instead of re-applying; a plain reconnect rebuilds the review
  and shows the reconnected notice. Success push-navigates to Schedules
  with the filters and a flash naming the change.

  Step 30 owns the leave and version-switch guards. A `switch_gtfs_version`
  with pasted text opens `#paste-switch-confirm` (`Keep reviewing` /
  `Switch version`) and only navigates on confirm, through
  `switch_version/2` like `RouteSchedulesLive`; an empty form navigates at
  once. In-app navigation the page cannot intercept server-side (the route
  tabs, the header) arrives through the colocated `.PasteLeaveGuard` hook
  as `paste_leave_guard`: with pasted text it opens `#paste-leave-confirm`
  (`Keep reviewing` / `Leave page`), otherwise it navigates at once. The
  hook also answers `beforeunload` while the form holds text, which covers
  the header version switcher's full-page navigation. The page's own Open
  Schedules link navigates through `paste_leave` behind `data-confirm`
  when dirty.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1, route_label: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.TimetablePaste
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.EnsureRole
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents
  alias GtfsPlannerWeb.Gtfs.TimetablePasteComponents
  alias GtfsPlannerWeb.Gtfs.TimetablePasteReview

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @scope_keys ~w(service_id direction pattern)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Paste timetable")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:route_id, nil)
     |> assign(:route, nil)
     |> assign(:scope, nil)
     |> assign(:requested, %{})
     |> assign(:input, fresh_paste_input())
     |> assign(:review, nil)
     |> assign(:paste_form, to_form(paste_form_params(), as: :paste))
     |> assign(:paste_error, nil)
     |> assign(:source_open, true)
     |> assign(:show_column_errors, false)
     |> assign(:scope_draft, nil)
     |> assign(:scope_form, to_form(%{}, as: :scope))
     |> assign(:scope_calendars, [])
     |> assign(:draft_scope, nil)
     |> assign(:plan_columns, [])
     |> assign(:plan_total, 0)
     |> assign(:plan_shown, 0)
     |> assign(:timing_note, nil)
     |> assign(:apply_notice, nil)
     |> assign(:failed_reference, nil)
     |> assign(:refusal_message, nil)
     |> assign(:paste_rejoined, rejoined_mount?(socket))
     |> assign(:replace_confirm, false)
     |> assign(:discard_confirm, false)
     |> assign(:switch_confirm, nil)
     |> assign(:leave_confirm, nil)
     |> assign(:show_review_errors, false)
     |> stream_configure(:plan_rows, dom_id: & &1.id)
     |> stream(:plan_rows, [])
     |> assign(:load_state, :loading)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:route_id, params["route_id"])
      |> assign(:requested, params)

    if connected?(socket) do
      {:noreply, load_scope(socket, params)}
    else
      {:noreply, assign(socket, :load_state, :loading)}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    guard_version_switch(socket, version_id)
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    guard_version_switch(socket, version_id)
  end

  # Step 22 owns the Change schedule drawer. Opening drafts the current
  # scope; the draft calendar/direction reload the draft scope for the
  # pattern options; submitting patches the URL and keeps the paste.
  @impl true
  def handle_event("open_scope_drawer", _params, socket) do
    case socket.assigns.scope do
      nil ->
        {:noreply, socket}

      scope ->
        calendars = load_scope_calendars(socket)
        draft = draft_params(scope)

        {:noreply,
         socket
         |> assign(:scope_calendars, calendars)
         |> assign(:scope_draft, draft)
         |> assign(:draft_scope, scope)
         |> assign(:scope_form, to_form(draft, as: :scope))}
    end
  end

  @impl true
  def handle_event("close_scope_drawer", _params, socket) do
    {:noreply, close_scope_drawer(socket)}
  end

  @impl true
  def handle_event("scope_draft_change", %{"scope" => params}, socket)
      when is_map(params) do
    case socket.assigns.scope_draft do
      nil ->
        {:noreply, socket}

      current ->
        draft = Map.merge(current, string_params(params))
        {draft, draft_scope} = refresh_draft_scope(socket, current, draft)

        {:noreply,
         socket
         |> assign(:scope_draft, draft)
         |> assign(:draft_scope, draft_scope)
         |> assign(:scope_form, to_form(draft, as: :scope))}
    end
  end

  @impl true
  def handle_event("scope_draft_change", _params, socket), do: {:noreply, socket}

  # Using the schedule patches the URL with the draft params. The LiveView
  # keeps `input.text`, clears the overrides/confirmations/decisions and
  # re-reviews with the new scope when the patch lands in `handle_params`.
  @impl true
  def handle_event("change_schedule", %{"scope" => params}, socket)
      when is_map(params) do
    case socket.assigns.scope_draft do
      nil ->
        {:noreply, socket}

      _draft ->
        query = schedule_query(params)

        {:noreply,
         socket
         |> close_scope_drawer()
         |> assign(:input, %{fresh_paste_input() | text: input_text(socket)})
         |> push_patch(to: paste_path(socket, query))}
    end
  end

  @impl true
  def handle_event("change_schedule", _params, socket), do: {:noreply, socket}

  # Step 23 owns the timetable step. Typing stashes the text, layout and
  # header into the input and rebuilds the form without touching the
  # database; only Read, Review again and Change schedule reload the scope
  # (review-recompute criterion). Clearing the textarea invalidates the last
  # read, so the stale review and error go away with it.
  # Step 24 extends the timetable step: the columns step's Use-as selects
  # arrive here as `paste[overrides][<col>]` alongside the text, layout and
  # header. Overrides are diffed against the review's effective values, so
  # re-submitting an untouched select never pins its automatic pick; a real
  # change recomputes the review purely from the loaded scope (no database
  # read) and advances to the review placeholder when the last issue
  # clears. Text, layout and header edits alone only stash, exactly like
  # step 23; clearing the textarea still invalidates the last read.
  # Step 25 extends the input event with the review header controls: the
  # mode and template fields recompute the review purely when they change
  # with the paste itself untouched; the stops-view radios and the filter
  # buttons only restash for display.
  # Step 26 extends the stash branch: a stops-view change re-streams the
  # matrix columns without recomputing the review (the plan is
  # view-independent, like the filter).
  # Step 27 extends the merge branch: pattern, cell and pairing controls
  # ride the same `input` event as structured `paste[pattern_choices]`,
  # `paste[cells]` and `paste[pairs]` params (diffed like the overrides, so
  # re-submitting an untouched control never writes a decision), and the
  # `#paste-decisions` hidden field round-trips the committed decisions. A
  # reconnect into a new process re-sends the form params: the collapsed
  # source step carries the text, layout and header as hidden backups
  # (`#paste-source-text` and friends, since the textarea itself unmounts),
  # so that shape rebuilds the review purely instead of waiting for Read
  # (step 28 adds the reconnected notice on top).
  @impl true
  def handle_event("input", %{"paste" => params}, socket) when is_map(params) do
    # Step 28: the `#paste-applying` flag is only ever `"true"` right after
    # an Apply click (the server always re-renders it `"false"`), so an
    # input event carrying it is form recovery after a reconnect during the
    # apply. Rebuild when the review is gone and show the unknown notice
    # instead of re-applying; the paste itself is never written twice.
    if params["applying"] == "true" do
      {:noreply, recover_applying(socket, params)}
    else
      {:noreply, paste_input(socket, params)}
    end
  end

  @impl true
  def handle_event("input", _params, socket), do: {:noreply, socket}

  # Reading re-resolves the scope through the facade with the full current
  # input (text, layout, header and whatever decisions/overrides later steps
  # add). A blank read names the empty fix; parse failures keep the text and
  # render the specific inline message; success collapses the step.
  @impl true
  def handle_event("read", params, socket) do
    paste_params =
      case params do
        %{"paste" => paste} when is_map(paste) -> paste
        _params -> %{}
      end

    old_input = current_input(socket)
    input = merge_paste_params(old_input, paste_params)
    input = merge_column_overrides(socket, old_input, input, paste_params, false)
    input = merge_decision_params(socket, old_input, input, paste_params, false)

    socket =
      socket
      |> assign(:input, input)
      |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))
      |> assign(:paste_rejoined, false)

    if blank_paste_text?(input.text) do
      {:noreply,
       socket
       |> assign(:review, nil)
       |> assign(:paste_error, :empty)
       |> assign(:source_open, true)}
    else
      {:noreply, read_paste(socket, input)}
    end
  end

  # Reopening keeps the text and the last review; the next Read replaces it.
  # A visible column error summary belongs to the columns stage, so it
  # goes away until the next Read or Review trips.
  @impl true
  def handle_event("edit_source", _params, socket) do
    {:noreply, socket |> assign(:source_open, true) |> assign(:show_column_errors, false)}
  end

  # Step 24 owns column confirmation: a close match joins the input's
  # confirmations and the review is recomputed purely from the loaded
  # scope. Confirming the last issue advances to the review placeholder
  # through the render conditions below.
  @impl true
  def handle_event("confirm_column", %{"col" => col}, socket) do
    with col when is_integer(col) <- parse_column(col),
         %{column_issues: [_ | _]} <- socket.assigns[:review] do
      input = current_input(socket)
      confirmations = MapSet.put(confirmation_set(input), col)
      input = %{input | confirmations: confirmations}

      {:noreply,
       socket
       |> assign(:input, input)
       |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))
       |> recompute_columns_review(input)}
    else
      _unchanged -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_column", _params, socket), do: {:noreply, socket}

  # Step 25 owns the refusal escape hatch: Use Add trips returns a
  # refused Replace to Add mode and recomputes the review purely from the
  # loaded scope. The button only renders on a refusal callout, so a
  # review is always present; the guard keeps the no-review path total.
  @impl true
  def handle_event("use_add", _params, socket) do
    input = %{current_input(socket) | mode: :add}

    socket =
      socket
      |> assign(:input, input)
      |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))

    {:noreply, maybe_recompute_review(socket, input)}
  end

  # Step 25 owns the row filter: a filter button only restashes the input
  # for display (step 26 reads it for the matrix). No recompute: the plan
  # is filter-independent.
  # Step 26 re-streams the matrix from the unchanged review when the
  # filter changes.
  @impl true
  def handle_event("paste_filter", params, socket) when is_map(params) do
    input = Map.put(current_input(socket), :filter, normalize_filter(params["filter"]))

    {:noreply,
     socket
     |> assign(:input, input)
     |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))
     |> put_plan_rows()}
  end

  @impl true
  def handle_event("paste_filter", _params, socket), do: {:noreply, socket}

  # Step 26 owns the timing note: a timing name button stores its
  # `pattern_id|name` ref and the matrix resolves the note content from
  # the current review and scope. Closing clears the ref. Neither touches
  # the row stream.
  @impl true
  def handle_event("paste_timing", params, socket) when is_map(params) do
    case params["ref"] do
      ref when is_binary(ref) and ref != "" -> {:noreply, assign(socket, :timing_note, ref)}
      _ref -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("paste_timing", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("paste_timing_close", _params, socket) do
    {:noreply, assign(socket, :timing_note, nil)}
  end

  # Step 27 owns the button-driven row decisions: the twelve-hour choice
  # and skip/restore/Add-anyway arrive as discrete events with the row
  # number (the pattern select, cell correction and pairing radios ride
  # the `input` event as native form fields instead). Each event writes
  # `input.decisions` and recomputes the review purely from the loaded
  # scope, like an override edit; the hidden `#paste-decisions` field
  # re-renders with the new decisions, so a reconnect restores them.
  @impl true
  def handle_event("paste_twelve", %{"row" => row, "choice" => choice}, socket) do
    {:noreply, update_row_decision(socket, row, &twelve_choice(&1, choice))}
  end

  @impl true
  def handle_event("paste_twelve", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("paste_skip", %{"row" => row}, socket) do
    {:noreply, update_row_decision(socket, row, &Map.put(&1, "skip", true))}
  end

  @impl true
  def handle_event("paste_skip", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("paste_restore", %{"row" => row}, socket) do
    {:noreply, update_row_decision(socket, row, &Map.delete(&1, "skip"))}
  end

  @impl true
  def handle_event("paste_restore", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("paste_keep", %{"row" => row}, socket) do
    {:noreply, update_row_decision(socket, row, &Map.put(&1, "keep", true))}
  end

  @impl true
  def handle_event("paste_keep", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("paste_unkeep", %{"row" => row}, socket) do
    {:noreply, update_row_decision(socket, row, &Map.delete(&1, "keep"))}
  end

  @impl true
  def handle_event("paste_unkeep", _params, socket), do: {:noreply, socket}

  # Saving a cell correction only recomputes: the correction itself rode
  # the form's `input` event when the field blurred (or the submit when
  # Enter read the paste), so the decisions are already current here.
  @impl true
  def handle_event("paste_cell_save", %{"row" => _row, "col" => _col}, socket) do
    {:noreply, maybe_recompute_review(socket, current_input(socket))}
  end

  @impl true
  def handle_event("paste_cell_save", _params, socket), do: {:noreply, socket}

  # Review trips with column issues shows the error summary and focuses
  # it; with no issues the review header is already showing.
  @impl true
  def handle_event("to_review", _params, socket) do
    case socket.assigns[:review] do
      %{column_issues: [_ | _]} ->
        {:noreply,
         socket
         |> assign(:show_column_errors, true)
         |> push_event("focus_scoped_target", %{id: "paste-column-errors"})}

      _review ->
        {:noreply, socket}
    end
  end

  # Step 28 owns the apply bar. With rows still needing a decision the
  # error summary renders with row links and takes focus while the button
  # stays enabled; a Replace with removals or transfers opens the Replace
  # confirmation first; otherwise the editor role is re-checked and the
  # paste is written through `Gtfs.apply_timetable_paste/5`.
  @impl true
  def handle_event("paste_apply", _params, socket) do
    case socket.assigns[:review] do
      %{plan: %{counts: %{needs_decision: open}}} when is_integer(open) and open > 0 ->
        {:noreply,
         socket
         |> assign(:show_review_errors, true)
         |> push_event("focus_scoped_target", %{id: "paste-review-errors"})}

      %{plan: plan} when is_map(plan) ->
        if replace_confirm_needed?(socket, plan) do
          {:noreply, assign(socket, :replace_confirm, true)}
        else
          {:noreply, do_apply(socket)}
        end

      _no_plan ->
        {:noreply, socket}
    end
  end

  # Confirming the Replace dialog writes through the same role re-check
  # and outcome mapping as a direct apply; cancelling only closes it.
  @impl true
  def handle_event("paste_replace_confirm", _params, socket) do
    {:noreply, socket |> assign(:replace_confirm, false) |> do_apply()}
  end

  @impl true
  def handle_event("paste_replace_cancel", _params, socket) do
    {:noreply, assign(socket, :replace_confirm, false)}
  end

  # Discarding asks first, then drops the text, overrides, confirmations
  # and decisions back to a blank paste; nothing was ever applied.
  @impl true
  def handle_event("paste_discard", _params, socket) do
    {:noreply, assign(socket, :discard_confirm, true)}
  end

  @impl true
  def handle_event("paste_discard_cancel", _params, socket) do
    {:noreply, assign(socket, :discard_confirm, false)}
  end

  @impl true
  def handle_event("paste_discard_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:input, fresh_paste_input())
     |> assign(:paste_form, to_form(paste_form_params(), as: :paste))
     |> assign(:paste_rejoined, false)
     |> assign(:review, nil)
     |> assign(:paste_error, nil)
     |> assign(:source_open, true)
     |> assign(:show_column_errors, false)
     |> assign(:show_review_errors, false)
     |> assign(:apply_notice, nil)
     |> assign(:failed_reference, nil)
     |> assign(:replace_confirm, false)
     |> assign(:discard_confirm, false)
     |> put_plan_rows()}
  end

  # Step 30 owns the leave and version-switch guards. A version switch
  # with pasted text opens `#paste-switch-confirm` instead of navigating;
  # confirming navigates through `switch_version/2` like
  # `RouteSchedulesLive`. In-app navigation the page cannot intercept
  # server-side (the route tabs, the header) arrives through the
  # `.PasteLeaveGuard` hook as `paste_leave_guard` with the link's `href`;
  # with pasted text it opens `#paste-leave-confirm`, otherwise it
  # navigates at once. The page's own Open Schedules link
  # (`paste_leave`, behind `data-confirm` when dirty) navigates at once
  # because the browser already asked.
  @impl true
  def handle_event("paste_switch_confirm", _params, socket) do
    case socket.assigns[:switch_confirm] do
      %{version_id: version_id} ->
        socket
        |> assign(:switch_confirm, nil)
        |> switch_version(version_id)

      _no_pending ->
        {:noreply, assign(socket, :switch_confirm, nil)}
    end
  end

  @impl true
  def handle_event("paste_switch_cancel", _params, socket) do
    {:noreply, assign(socket, :switch_confirm, nil)}
  end

  @impl true
  def handle_event("paste_leave_guard", %{"to" => to}, socket) do
    if safe_leave_path?(to) do
      if blank_paste_text?(input_text(socket)) do
        {:noreply, push_navigate(socket, to: to)}
      else
        {:noreply, assign(socket, :leave_confirm, %{to: to})}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("paste_leave_guard", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("paste_leave_confirm", _params, socket) do
    case socket.assigns[:leave_confirm] do
      %{to: to} ->
        {:noreply,
         socket
         |> assign(:leave_confirm, nil)
         |> push_navigate(to: to)}

      _no_pending ->
        {:noreply, assign(socket, :leave_confirm, nil)}
    end
  end

  @impl true
  def handle_event("paste_leave_cancel", _params, socket) do
    {:noreply, assign(socket, :leave_confirm, nil)}
  end

  @impl true
  def handle_event("paste_leave", _params, socket) do
    {:noreply, push_navigate(socket, to: leave_schedules_path(socket))}
  end

  # Review again reloads the scope around the kept input (text, columns
  # and decisions stay) and clears the outcome, for the stale and unknown
  # notices.
  @impl true
  def handle_event("paste_review_again", _params, socket) do
    {:noreply, review_again(socket)}
  end

  @impl true
  def handle_event("paste_dismiss_notice", _params, socket) do
    {:noreply, assign(socket, :apply_notice, nil)}
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
      <div id="timetable-paste" class="ds-page">
        <.route_header
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:schedules}
          loading={@load_state == :loading}
        />

        <TimetablePasteComponents.loading_skeleton :if={@load_state == :loading and is_nil(@scope)} />

        <div :if={@scope}>
          <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3 pb-5 pt-7">
            <div class="min-w-0">
              <h1
                id="paste-title"
                tabindex="-1"
                class="font-display text-[28px] font-semibold leading-tight tracking-[-0.025em] text-strong outline-none"
              >
                Paste timetable
              </h1>
              <p class="mt-1.5 text-sm text-muted">
                Add trips from a spreadsheet, or replace a schedule with it. Nothing changes until
                you apply.
              </p>
            </div>
          </div>

          <TimetablePasteComponents.scope_line
            calendar={@scope.calendar}
            direction_name={direction_name(@scope.direction_id)}
            pattern={chosen_pattern(@scope)}
          />

          <TimetablePasteComponents.setup_empty
            :if={setup_reason(@scope)}
            reason={setup_reason(@scope)}
            route_label={route_label(@scope.route)}
            direction_adjective={direction_adjective(@scope.direction_id)}
            calendars_path={"/gtfs/#{@current_gtfs_version.id}/calendars/new"}
            patterns_path={~p"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns/new"}
          />

          <TimetablePasteComponents.scope_drawer
            open={@scope_draft != nil}
            form={@scope_form}
            calendars={@scope_calendars}
            draft_scope={@draft_scope}
            review={@review}
            route_label={route_label(@scope.route)}
          />

          <TimetablePasteComponents.notices
            :if={is_nil(setup_reason(@scope))}
            notice={@apply_notice}
            failed_reference={@failed_reference}
            refusal_message={@refusal_message}
            scope={@scope}
            review={@review}
            version_id={@current_gtfs_version.id}
            route_id={@route_id}
            has_text={!blank_paste_text?(@input.text)}
          />

          <.form
            :if={is_nil(setup_reason(@scope))}
            id="paste-form"
            for={@paste_form}
            phx-change="input"
            phx-submit="read"
            phx-hook="FormErrorFocus"
            class="mt-4 grid gap-4"
          >
            <input
              type="hidden"
              id="paste-decisions"
              name="paste[decisions]"
              value={@paste_form[:decisions].value || "{}"}
            />
            <TimetablePasteComponents.source_step
              form={@paste_form}
              error={@paste_error}
              open={@source_open}
              review={@review}
            />
            <TimetablePasteComponents.columns_step
              :if={@review != nil and !@source_open and @review.column_issues != []}
              review={@review}
              scope={@scope}
              header?={@input.header?}
              show_errors={@show_column_errors}
            />
            <TimetablePasteComponents.review_header
              :if={@review != nil and !@source_open and @review.column_issues == []}
              review={@review}
              scope={@scope}
              input={@input}
              columns={@plan_columns}
              rows={@streams.plan_rows}
              shown={@plan_shown}
              timing_note={@timing_note}
              show_errors={@show_review_errors}
              notice={@apply_notice}
            />
          </.form>

          <TimetablePasteComponents.replace_confirm
            :if={@replace_confirm}
            open={true}
            review={@review}
            scope={@scope}
            input={@input}
          />
          <TimetablePasteComponents.discard_confirm :if={@discard_confirm} open={true} />
          <TimetablePasteComponents.switch_confirm
            :if={@switch_confirm}
            open={true}
            version_name={@switch_confirm.version_name}
          />
          <TimetablePasteComponents.leave_confirm :if={@leave_confirm} open={true} />
          <TimetablePasteComponents.leave_guard />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_scope(socket, params) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id
    input = socket.assigns[:input] || %{}

    case Gtfs.prepare_timetable_paste(
           organization_id,
           version_id,
           route_id,
           scope_params(params),
           input
         ) do
      {:ok, %{scope: scope, review: review}} -> apply_scope(socket, scope, review, params)
      {:error, :not_found} -> route_not_found(socket)
      {:error, reason} -> apply_paste_error(socket, params, reason)
    end
  end

  defp scope_params(params) do
    %{
      service_id: params["service_id"],
      direction: params["direction"],
      pattern: params["pattern"]
    }
  end

  defp apply_scope(socket, scope, review, params) do
    socket
    |> assign(:route, scope.route)
    |> assign(:scope, scope)
    |> assign(:review, review)
    |> assign(:paste_error, nil)
    |> assign(:source_open, is_nil(review))
    |> assign(:show_column_errors, false)
    |> assign(:load_state, :ready)
    |> put_plan_rows()
    |> push_canonical(scope, params)
  end

  # A parse failure is scope-independent, so the schedule line still
  # resolves: load the scope alone, then show the inline error with the text
  # kept. A blank input cannot fail the review, so any inner failure is the
  # missing route.
  defp apply_paste_error(socket, params, reason) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    case Gtfs.prepare_timetable_paste(
           organization_id,
           version_id,
           route_id,
           scope_params(params),
           %{}
         ) do
      {:ok, %{scope: scope}} ->
        socket
        |> assign(:route, scope.route)
        |> assign(:scope, scope)
        |> assign(:review, nil)
        |> assign(:paste_error, reason)
        |> assign(:source_open, true)
        |> assign(:load_state, :ready)
        |> put_plan_rows()
        |> push_canonical(scope, params)

      {:error, _reason} ->
        route_not_found(socket)
    end
  end

  # Reading re-resolves the current scope with the full input. Success
  # refreshes the scope and collapses the step; a parse failure keeps the
  # scope line and the text with the inline error.
  defp read_paste(socket, input) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    case Gtfs.prepare_timetable_paste(
           organization_id,
           version_id,
           route_id,
           read_scope_params(socket.assigns.scope),
           input
         ) do
      {:ok, %{scope: scope, review: nil}} ->
        socket
        |> assign(:route, scope.route)
        |> assign(:scope, scope)
        |> assign(:review, nil)
        |> assign(:paste_error, :empty)
        |> assign(:source_open, true)
        |> assign(:load_state, :ready)
        |> clear_apply_state()
        |> put_plan_rows()

      {:ok, %{scope: scope, review: review}} ->
        socket
        |> assign(:route, scope.route)
        |> assign(:scope, scope)
        |> assign(:review, review)
        |> assign(:paste_error, nil)
        |> assign(:source_open, false)
        |> assign(:show_column_errors, false)
        |> assign(:load_state, :ready)
        |> clear_apply_state()
        |> put_plan_rows()

      {:error, :not_found} ->
        route_not_found(socket)

      {:error, reason} ->
        socket
        |> assign(:review, nil)
        |> assign(:paste_error, reason)
        |> assign(:source_open, true)
        |> clear_apply_state()
        |> put_plan_rows()
    end
  end

  # A fresh Read supersedes any apply outcome or error summary.
  defp clear_apply_state(socket) do
    socket
    |> assign(:apply_notice, nil)
    |> assign(:failed_reference, nil)
    |> assign(:replace_confirm, false)
    |> assign(:discard_confirm, false)
    |> assign(:show_review_errors, false)
  end

  defp read_scope_params(nil), do: %{}

  defp read_scope_params(scope) do
    %{
      service_id: scope.calendar && scope.calendar.service_id,
      direction: direction_param(scope.direction_id),
      pattern: scope.pattern_id
    }
  end

  defp current_input(socket) do
    case socket.assigns[:input] do
      input when is_map(input) -> input
      _input -> fresh_paste_input()
    end
  end

  # Form params for the paste form. Only keys the form carries override the
  # input, so later steps' decisions/overrides ride along untouched. Step 25
  # adds the review header fields: the mode and stops-view radios and the
  # template select always submit their current pick, so merging is a plain
  # take (unlike the columns selects, no diffing is needed); the filter
  # buttons are not form fields and arrive through `paste_filter` instead.
  defp merge_paste_params(input, params) do
    %{
      input
      | text: paste_text(params, input),
        layout: paste_layout(params, input),
        header?: paste_header(params, input),
        mode: paste_mode(params, input),
        template_timing_id: paste_template(params, input),
        stops_view: paste_stops_view(params, input)
    }
  end

  defp paste_text(%{"text" => text}, _input) when is_binary(text), do: text
  defp paste_text(_params, input), do: input.text || ""

  defp paste_layout(%{"layout" => layout}, _input)
       when layout in ["auto", "trips_in_rows", "stops_in_rows"],
       do: String.to_atom(layout)

  defp paste_layout(_params, input), do: input.layout || :auto

  defp paste_header(%{"header" => header}, _input), do: header != "false"
  defp paste_header(_params, input), do: input.header? != false

  defp paste_mode(%{"mode" => mode}, _input) when mode in ["add", "replace"] do
    String.to_atom(mode)
  end

  defp paste_mode(_params, input), do: input.mode || :add

  defp paste_template(%{"template_timing_id" => id}, _input) when is_binary(id),
    do: Values.presence(id)

  defp paste_template(_params, input), do: input.template_timing_id

  defp paste_stops_view(%{"stops_view" => view}, _input) when view in ["pasted", "all"] do
    String.to_atom(view)
  end

  defp paste_stops_view(_params, input), do: input.stops_view || :pasted

  # Step 24 diffs the submitted Use-as selects against the current review's
  # effective values. A select re-submits its displayed pick whether or not
  # the person touched it, so storing every submission would pin each
  # automatic pick (and silently confirm every close match) into an
  # override. Only a real change writes or clears an override; anything
  # else leaves the input's overrides alone. Without a review there is
  # nothing to diff against, so the submitted selects are ignored — except
  # on form recovery into a new process (step 27), where the submitted
  # values are the last rendered picks and are taken wholesale so the
  # rebuilt review matches what the person saw.
  defp merge_column_overrides(socket, old_input, input, params, recovery?) do
    case params do
      %{"overrides" => submitted} when is_map(submitted) ->
        case socket.assigns[:review] do
          %{columns: columns} when is_list(columns) ->
            %{input | overrides: diff_overrides(columns, old_input.overrides, submitted)}

          _review when recovery? ->
            %{input | overrides: accept_overrides(submitted)}

          _no_review ->
            input
        end

      _no_overrides ->
        input
    end
  end

  defp diff_overrides(columns, current, submitted) do
    submitted = Map.new(submitted, fn {col, value} -> {to_string(col), value} end)
    current = current || %{}

    Enum.reduce(columns, current, fn column, acc ->
      case Map.fetch(submitted, Integer.to_string(column.col)) do
        :error -> acc
        {:ok, raw} -> diff_override_value(acc, column, raw)
      end
    end)
  end

  defp diff_override_value(acc, column, raw) do
    value = raw |> to_string_safe() |> String.trim()
    effective = TimetablePasteComponents.column_value(column)

    if value == "" or value == effective do
      Map.delete(acc, column.col)
    else
      Map.put(acc, column.col, value)
    end
  end

  # Recovery has no review to diff against, so the re-sent selects are
  # the committed picks: every non-blank value becomes an override.
  defp accept_overrides(submitted) do
    submitted
    |> Enum.map(fn {col, value} ->
      {to_decision_col(col), value |> to_string_safe() |> String.trim()}
    end)
    |> Enum.reject(fn {col, value} -> is_nil(col) or value == "" end)
    |> Map.new()
  end

  # Step 27 merges the row decisions. The `#paste-decisions` hidden field
  # carries the committed decisions as JSON on every submit, so decoding
  # it first keeps decisions across re-reviews and restores them on form
  # recovery; the structured pattern/cell/pairing fields then overlay the
  # freshest DOM state on top. Cell corrections are diffed against the
  # current review's raw grid cell (like the overrides), so an untouched
  # correction input never writes a decision; without a review there is
  # nothing to diff against and recovery takes them wholesale. Pattern
  # and pairing fields need no diffing: an unchosen select submits `""`
  # (which clears) and unchecked radios submit nothing at all.
  defp merge_decision_params(socket, old_input, input, params, recovery?) do
    base =
      case params["decisions"] do
        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, decoded} when is_map(decoded) -> canonical_decisions(decoded)
            _undecodable -> canonical_decisions(old_input.decisions)
          end

        decoded when is_map(decoded) ->
          canonical_decisions(decoded)

        _absent ->
          canonical_decisions(old_input.decisions)
      end

    decisions =
      base
      |> overlay_pattern_choices(params["pattern_choices"])
      |> overlay_pair_choices(params["pairs"])
      |> overlay_cell_corrections(socket, input, params["cells"], recovery?)
      |> prune_decisions()

    %{input | decisions: decisions}
  end

  defp overlay_pattern_choices(decisions, submitted) when is_map(submitted) do
    Enum.reduce(submitted, decisions, &overlay_pattern_choice/2)
  end

  defp overlay_pattern_choices(decisions, _submitted), do: decisions

  defp overlay_pattern_choice({row, raw}, acc) do
    case TimetablePaste.row_number(row) do
      nil -> acc
      row_num -> put_row_choice(acc, row_num, "pattern_id", raw)
    end
  end

  defp put_row_choice(acc, row_num, key, raw) do
    value = raw |> to_string_safe() |> String.trim()

    if value == "" do
      acc |> Map.update(row_num, %{}, &Map.delete(&1, key)) |> prune_decisions()
    else
      Map.update(acc, row_num, %{key => value}, &Map.put(&1, key, value))
    end
  end

  defp overlay_pair_choices(decisions, submitted) when is_map(submitted) do
    Enum.reduce(submitted, decisions, &overlay_pair_choice/2)
  end

  defp overlay_pair_choices(decisions, _submitted), do: decisions

  defp overlay_pair_choice({row, raw}, acc) do
    case TimetablePaste.row_number(row) do
      nil -> acc
      row_num -> put_row_choice(acc, row_num, "pair", raw)
    end
  end

  defp overlay_cell_corrections(decisions, _socket, _input, submitted, _recovery?)
       when not is_map(submitted),
       do: decisions

  defp overlay_cell_corrections(decisions, socket, input, submitted, recovery?) do
    review = if recovery?, do: nil, else: socket.assigns[:review]

    Enum.reduce(submitted, decisions, fn {row, cols}, acc ->
      overlay_row_cells(acc, row, cols, review, input)
    end)
  end

  defp overlay_row_cells(acc, row, cols, review, input) do
    with row_num when not is_nil(row_num) <- TimetablePaste.row_number(row),
         cols when is_map(cols) <- cols do
      Map.update(acc, row_num, overlay_cells(%{}, cols, review, input, row_num), fn current ->
        overlay_cells(current, cols, review, input, row_num)
      end)
    else
      _skip -> acc
    end
  end

  defp overlay_cells(current, cols, review, input, row_num) when is_map(current) do
    cells = if is_map(Map.get(current, "cells")), do: Map.get(current, "cells"), else: %{}

    updated =
      Enum.reduce(cols, cells, fn {col, raw}, acc ->
        overlay_cell_value(acc, col, raw, review, input, row_num)
      end)

    if map_size(updated) == 0 do
      Map.delete(current, "cells")
    else
      Map.put(current, "cells", updated)
    end
  end

  defp overlay_cell_value(acc, col, raw, review, input, row_num) do
    case to_decision_col(col) do
      nil -> acc
      col_num -> put_cell_value(acc, col_num, to_string_safe(raw), review, input, row_num)
    end
  end

  defp put_cell_value(acc, col_num, value, review, input, row_num) do
    if review_differs?(review, input, row_num, col_num, value) do
      Map.put(acc, col_num, value)
    else
      Map.delete(acc, col_num)
    end
  end

  # Without a review there is nothing to diff a correction against, so
  # recovery keeps every submitted value; otherwise only a value the
  # person actually changed (anything but the raw grid cell) is stored.
  defp review_differs?(nil, _input, _row, _col, _value), do: true

  defp review_differs?(review, input, row_num, col_num, value) do
    String.trim(value) != String.trim(raw_grid_cell(review, input, row_num, col_num))
  end

  defp raw_grid_cell(review, input, row_num, col_num) do
    grid = if is_map(review), do: Map.get(review, :grid, []), else: []
    header? = if is_map(input), do: Map.get(input, :header?, true) != false, else: true
    index = if header?, do: row_num, else: row_num - 1

    if is_list(grid) and is_integer(index) and index >= 0 do
      grid |> Enum.at(index, []) |> List.wrap() |> Enum.at(col_num, "") |> to_string_safe()
    else
      ""
    end
  end

  # Canonical decisions mirror `TimetablePaste.normalize_input/1`: integer
  # row keys, string inner keys, integer cell columns. Empty rows prune
  # away so untouched controls compare equal to no decision at all.
  defp canonical_decisions(decisions) when is_map(decisions) do
    decisions
    |> Enum.map(fn {row, decision} ->
      {TimetablePaste.row_number(row), canonical_decision(decision)}
    end)
    |> Enum.reject(fn {row, decision} -> is_nil(row) or decision == %{} end)
    |> Map.new()
  end

  defp canonical_decisions(_decisions), do: %{}

  defp canonical_decision(decision) when is_map(decision) do
    {cells, rest} = Map.split(decision, [:cells, "cells"])

    normalized =
      rest
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    case canonical_cells(cells) do
      cells when map_size(cells) == 0 -> normalized
      cells -> Map.put(normalized, "cells", cells)
    end
  end

  defp canonical_decision(_decision), do: %{}

  defp canonical_cells(taken) when is_map(taken) do
    taken
    |> Map.values()
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
    |> Enum.map(fn {col, value} -> {to_decision_col(col), to_string_safe(value)} end)
    |> Enum.reject(fn {col, _value} -> is_nil(col) end)
    |> Map.new()
  end

  defp canonical_cells(_taken), do: %{}

  defp prune_decisions(decisions) when is_map(decisions) do
    Map.reject(decisions, fn {_row, decision} -> not is_map(decision) or decision == %{} end)
  end

  defp prune_decisions(_decisions), do: %{}

  defp to_decision_col(col) when is_integer(col) and col >= 0, do: col

  defp to_decision_col(col) when is_binary(col) do
    case Integer.parse(String.trim(col)) do
      {num, ""} when num >= 0 -> num
      _parse -> nil
    end
  end

  defp to_decision_col(_col), do: nil

  # The hidden field round-trips through JSON, so rows and cell columns
  # encode as strings and decode back through the canonicalizer.
  defp encode_decisions(decisions) do
    json =
      decisions
      |> canonical_decisions()
      |> Enum.map(fn {row, decision} -> {Integer.to_string(row), json_decision(decision)} end)
      |> Map.new()

    case Jason.encode(json) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> "{}"
    end
  end

  defp json_decision(decision) when is_map(decision) do
    Map.new(decision, fn
      {"cells", cells} when is_map(cells) ->
        {"cells", Map.new(cells, fn {col, value} -> {to_string(col), value} end)}

      {key, value} ->
        {to_string(key), value}
    end)
  end

  # The review is recomputed only when the paste itself did not change:
  # an override edit with the same text, layout and header re-reviews the
  # loaded scope, while typing waits for Read like step 23.
  defp recompute_columns?(socket, old_input, input, params) do
    is_map(params["overrides"]) and input.text == old_input.text and
      input.layout == old_input.layout and input.header? == old_input.header? and
      not is_nil(socket.assigns[:scope]) and not is_nil(socket.assigns[:review])
  end

  # Step 25 recomputes on the same criterion for the review header's mode
  # and template fields: with the paste itself untouched, switching How to
  # apply or Fill-other-stops-from re-reviews the loaded scope (mode
  # changes the plan, the template changes the estimates). Stops view and
  # filter never recompute: they only restash for display.
  defp recompute_review_inputs?(socket, old_input, input) do
    not is_nil(socket.assigns[:scope]) and not is_nil(socket.assigns[:review]) and
      input.text == old_input.text and input.layout == old_input.layout and
      input.header? == old_input.header? and
      (input.mode != old_input.mode or
         input.template_timing_id != old_input.template_timing_id)
  end

  # Step 27 recomputes on the same criterion for the decision controls:
  # with the paste itself untouched, a changed pattern choice, cell
  # correction or pairing pick re-reviews the loaded scope. The merge
  # diffs untouched controls away, so re-submitting the form with the same
  # decisions never recomputes on its own.
  defp recompute_decisions?(socket, old_input, input) do
    not is_nil(socket.assigns[:scope]) and not is_nil(socket.assigns[:review]) and
      input.text == old_input.text and input.layout == old_input.layout and
      input.header? == old_input.header? and input.decisions != old_input.decisions
  end

  # Step 27 form recovery: a reconnect into a new process re-sends the
  # whole form with this process's text still blank, the params carrying
  # text and the hidden decisions field populated. Step 31 records whether
  # the connected mount is a rejoin (client `_mounts` > 0): a replay on a
  # rejoined mount rebuilds even with an empty decisions map, so a paste
  # with no attention rows still comes back. The decisions shape stays
  # because the ExUnit recovery tests simulate the replay with
  # `render_change` on a fresh mount (the test client always joins with
  # `_mounts` 0); on a fresh mount ordinary typing carries no decisions
  # and keeps stashing until Read. The flag is consumed by the first input
  # event either way.
  defp recovery_rebuild?(socket, old_input, params) do
    not is_nil(socket.assigns[:scope]) and is_nil(socket.assigns[:review]) and
      blank_paste_text?(old_input.text) and is_map(params) and
      is_binary(params["text"]) and String.trim(params["text"]) != "" and
      (socket.assigns[:paste_rejoined] == true or
         decisions_present?(params["decisions"]))
  end

  defp decisions_present?(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> map_size(decoded) > 0
      _undecodable -> false
    end
  end

  defp decisions_present?(decoded) when is_map(decoded), do: map_size(decoded) > 0
  defp decisions_present?(_decisions), do: false

  # A recovery replay is shaped exactly like ordinary typing, so the fresh
  # mount tells them apart with the client's `_mounts` connect param: the
  # first connected mount sends 0, every rejoin sends 1 or more. Without
  # the gate the first blur after pasting would rebuild the review instead
  # of waiting for Read.
  defp rejoined_mount?(socket) do
    if connected?(socket) do
      case get_connect_params(socket) do
        %{"_mounts" => mounts} when is_integer(mounts) -> mounts > 0
        _params -> false
      end
    else
      false
    end
  end

  # Rebuilds the review purely from the loaded scope on recovery: the
  # scope is fresh from `handle_params`, so decisions never cost a
  # database read. Success collapses the step like a Read; a parse
  # failure keeps the text with the inline error.
  # The ordinary paste input path step 23 owns (with step 24's column
  # overrides, step 25's review header fields, step 26's view restash and
  # step 27's decisions and recovery rebuild). Step 28 adds the
  # reconnected notice on top of a recovery rebuild.
  defp paste_input(socket, params) do
    old_input = current_input(socket)
    input = merge_paste_params(old_input, params)
    recovery? = recovery_rebuild?(socket, old_input, params)
    input = merge_column_overrides(socket, old_input, input, params, recovery?)
    input = merge_decision_params(socket, old_input, input, params, recovery?)

    socket =
      socket
      |> assign(:input, input)
      |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))
      |> assign(:paste_rejoined, false)

    socket =
      cond do
        blank_paste_text?(input.text) ->
          socket
          |> assign(:review, nil)
          |> assign(:paste_error, nil)
          |> assign(:source_open, true)
          |> assign(:show_column_errors, false)
          |> put_plan_rows()

        recovery? ->
          socket
          |> rebuild_recovered_review(input)
          |> assign(:apply_notice, :reconnected)
          |> push_event("focus_scoped_target", %{id: "paste-notice-reconnected"})

        recompute_columns?(socket, old_input, input, params) ->
          recompute_columns_review(socket, input)

        recompute_review_inputs?(socket, old_input, input) ->
          recompute_columns_review(socket, input)

        recompute_decisions?(socket, old_input, input) ->
          recompute_columns_review(socket, input)

        # Stops view only restashes for display; a change re-streams the
        # matrix columns from the current review.
        input.stops_view != old_input.stops_view ->
          put_plan_rows(socket)

        true ->
          socket
      end

    socket
  end

  defp rebuild_recovered_review(socket, input) do
    case TimetablePaste.review(socket.assigns.scope, input) do
      {:ok, review} ->
        socket
        |> assign(:review, review)
        |> assign(:paste_error, nil)
        |> assign(:source_open, false)
        |> assign(:show_column_errors, false)
        |> put_plan_rows()

      {:error, reason} ->
        socket
        |> assign(:review, nil)
        |> assign(:paste_error, reason)
        |> assign(:source_open, true)
        |> put_plan_rows()
    end
  end

  # Applies a discrete decision-event update to one row: unknown rows
  # leave the input alone, and an emptied row drops out of the map so it
  # compares equal to no decision at all.
  defp update_row_decision(socket, row, fun) when is_function(fun, 1) do
    case TimetablePaste.row_number(row) do
      nil ->
        socket

      row_num ->
        input = current_input(socket)
        decisions = canonical_decisions(input.decisions)
        updated = fun.(Map.get(decisions, row_num, %{}))

        decisions =
          if is_map(updated) and map_size(prune_row(updated)) > 0 do
            Map.put(decisions, row_num, prune_row(updated))
          else
            Map.delete(decisions, row_num)
          end

        input = %{input | decisions: decisions}

        socket
        |> assign(:input, input)
        |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))
        |> maybe_recompute_review(input)
    end
  end

  defp prune_row(decision) when is_map(decision) do
    {cells, rest} = Map.split(decision, [:cells, "cells"])

    pruned =
      rest
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false, 0] end)
      |> Map.new()

    merged_cells =
      cells |> Map.values() |> Enum.filter(&is_map/1) |> Enum.reduce(%{}, &Map.merge(&2, &1))

    if map_size(merged_cells) == 0 do
      pruned
    else
      Map.put(pruned, "cells", merged_cells)
    end
  end

  defp twelve_choice(decision, choice) when is_map(decision) do
    case choice do
      shift when shift in ["86400", "43200"] ->
        decision
        |> Map.put("shift", String.to_integer(shift))
        |> Map.delete("keep_early")

      "keep" ->
        decision |> Map.put("keep_early", true) |> Map.delete("shift")

      _choice ->
        decision
    end
  end

  defp twelve_choice(decision, _choice), do: decision

  # Recomputes when a review is showing; otherwise the input just rests
  # (the button that triggers this only renders on a refusal callout).
  defp maybe_recompute_review(socket, input) do
    if is_nil(socket.assigns[:scope]) or is_nil(socket.assigns[:review]) do
      socket
    else
      recompute_columns_review(socket, input)
    end
  end

  @review_filters ~w(all add change remove unchanged duplicate skipped needs_decision warnings)

  defp normalize_filter(filter) when filter in @review_filters, do: filter
  defp normalize_filter(_filter), do: "all"

  # Recomputes the review purely from the loaded scope: the scope was
  # already read for the last Read or patch, so overrides and
  # confirmations never cost a database read. Overrides cannot break
  # parsing, so a failure keeps the last review. Clearing the last issue
  # hides a visible error summary with it. Step 26 re-streams the matrix
  # from the recomputed review.
  defp recompute_columns_review(socket, input) do
    case socket.assigns[:scope] do
      nil ->
        socket

      scope ->
        case TimetablePaste.review(scope, input) do
          {:ok, review} ->
            socket
            |> assign(:review, review)
            |> assign(
              :show_column_errors,
              socket.assigns[:show_column_errors] == true and review.column_issues != []
            )
            |> assign(:show_review_errors, keep_review_errors?(socket, review))
            |> put_plan_rows()

          {:error, _reason} ->
            socket
        end
    end
  end

  # The apply-time error summary stays until every decision resolves,
  # like the column error summary step 24 owns.
  defp keep_review_errors?(socket, review) do
    socket.assigns[:show_review_errors] == true and review_needs_decision?(review)
  end

  defp review_needs_decision?(%{plan: %{counts: %{needs_decision: open}}})
       when is_integer(open),
       do: open > 0

  defp review_needs_decision?(_review), do: false

  # Streams the review matrix from the current review, scope and input
  # filter/stops view. Streams are not enumerable, so the rows are rebuilt
  # from the plan changes and reset on every recompute, filter or view
  # change; the totals live in separate assigns for the filter counts and
  # the empty state.
  defp put_plan_rows(socket) do
    info =
      TimetablePasteReview.build(
        socket.assigns[:review],
        socket.assigns[:scope],
        current_input(socket)
      )

    socket
    |> assign(:plan_columns, info.columns)
    |> assign(:plan_total, info.total)
    |> assign(:plan_shown, info.shown)
    |> stream(:plan_rows, info.rows, reset: true)
  end

  defp confirmation_set(%{confirmations: %MapSet{} = confirmations}), do: confirmations
  defp confirmation_set(_input), do: MapSet.new()

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_safe(_value), do: ""

  defp parse_column(col) when is_integer(col) and col >= 0, do: col

  defp parse_column(col) when is_binary(col) do
    case Integer.parse(String.trim(col)) do
      {number, ""} when number >= 0 -> number
      _parse -> nil
    end
  end

  defp parse_column(_col), do: nil

  defp paste_form_params(input \\ fresh_paste_input()) do
    %{
      "text" => input.text || "",
      "layout" => layout_param(input.layout),
      "header" => if(input.header? == false, do: "false", else: "true"),
      "mode" => if(input.mode == :replace, do: "replace", else: "add"),
      "template_timing_id" => input.template_timing_id || "",
      "stops_view" => if(input.stops_view == :all, do: "all", else: "pasted"),
      "decisions" => encode_decisions(input.decisions),
      "overrides" =>
        Map.new(input.overrides || %{}, fn {col, value} -> {to_string(col), value} end)
    }
  end

  defp layout_param(:trips_in_rows), do: "trips_in_rows"
  defp layout_param(:stops_in_rows), do: "stops_in_rows"
  defp layout_param(_layout), do: "auto"

  # A non-text paste counts as no paste, which canonical trimming would treat as present.
  defp blank_paste_text?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank_paste_text?(_text), do: true

  defp push_canonical(socket, scope, params) do
    canonical = canonical_scope_params(scope)

    if Map.take(params, @scope_keys) == canonical do
      socket
    else
      push_patch(socket, to: paste_path(socket, canonical), replace: true)
    end
  end

  defp canonical_scope_params(scope) do
    %{}
    |> put_service_id(scope.calendar && scope.calendar.service_id)
    |> Values.put_present("direction", direction_param(scope.direction_id))
    |> Values.put_present("pattern", scope.pattern_id)
  end

  defp direction_param(0), do: "0"
  defp direction_param(1), do: "1"
  defp direction_param(_direction), do: nil

  # --- Apply, confirm and outcomes (step 28) ----------------------------------

  # A Replace that would remove trips or drop transfers naming them always
  # asks first; Add mode and a Replace with nothing removed apply at once.
  defp replace_confirm_needed?(socket, plan) do
    current_input(socket).mode == :replace and
      (plan.counts.remove > 0 or (plan.transfers_removed || 0) > 0)
  end

  # The apply re-checks the editor role before writing (never from a
  # read-only role), then maps the writer result onto the outcome
  # notices. The paste and decisions stay on every failure.
  defp do_apply(socket) do
    if editor_access?(socket) do
      review = socket.assigns[:review]
      scope = socket.assigns[:scope]

      case Gtfs.apply_timetable_paste(
             socket.assigns.route_id,
             apply_scope_params(scope),
             current_input(socket),
             review.fingerprint,
             AuditContext.from_assigns(socket.assigns)
           ) do
        {:ok, summary} ->
          apply_success(socket, scope, summary)

        {:error, :stale_plan} ->
          apply_outcome(socket, :stale, "paste-notice-stale")

        {:error, :busy} ->
          apply_outcome(socket, :busy, "paste-notice-busy")

        # R9: the adds would mix listed trips and frequency service on a
        # pattern; the notice uses the refusal copy Schedules shows.
        {:error, {:mixed_service, _details} = reason} ->
          socket
          |> assign(:refusal_message, ScheduleComponents.error_message(reason))
          |> apply_outcome(:mixed_service, "paste-notice-mixed-service")

        {:error, _reason} ->
          socket
          |> assign(:failed_reference, failed_reference())
          |> apply_outcome(:failed, "paste-notice-failed")
      end
    else
      apply_outcome(socket, :permission, "paste-notice-permission")
    end
  end

  defp apply_outcome(socket, notice, focus_id) do
    socket
    |> assign(:apply_notice, notice)
    |> assign(:replace_confirm, false)
    |> assign(:show_review_errors, false)
    |> push_event("focus_scoped_target", %{id: focus_id})
  end

  # At apply time both the calendar and the direction are concrete, so
  # the scope params carry the prepared values, like the writer documents.
  defp apply_scope_params(scope) do
    %{
      service_id: scope.calendar && scope.calendar.service_id,
      direction_id: scope.direction_id,
      pattern_id: scope.pattern_id
    }
  end

  # Success lands on Schedules with the filters and a flash naming the
  # adds, changes, removals, timings created, transfers removed and the
  # vehicles change (AC-32).
  defp apply_success(socket, scope, summary) do
    socket
    |> put_flash(:info, apply_flash(scope, summary))
    |> push_navigate(to: apply_schedules_path(socket, scope))
  end

  defp apply_flash(scope, summary) do
    calendar = scope.calendar && (scope.calendar.name || scope.calendar.service_id)
    direction = if scope.direction_id == 1, do: "Inbound", else: "Outbound"

    counts =
      [
        {"Added", summary.added, "trip"},
        {"changed", summary.changed, "trip"},
        {"removed", summary.removed, "trip"}
      ]
      |> Enum.filter(fn {_label, count, _one} -> is_integer(count) and count > 0 end)
      |> Enum.map(fn {label, count, one} -> "#{label} #{count} #{Wording.noun(count, one)}" end)

    headline =
      case counts do
        [] -> "Applied the paste"
        counts -> Enum.join(counts, ", ") |> Wording.capitalize_first()
      end

    [
      "#{headline} on #{calendar} · #{direction}.",
      timing_flash(summary),
      transfer_flash(summary),
      vehicle_flash(summary)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp timing_flash(%{new_timings: []}), do: nil
  defp timing_flash(%{new_timings: [name]}), do: "Created timing: #{name}."

  defp timing_flash(%{new_timings: names}),
    do: "Created #{length(names)} timings: #{Enum.join(names, ", ")}."

  defp transfer_flash(%{transfers_removed: 0}), do: nil
  defp transfer_flash(%{transfers_removed: 1}), do: "Removed 1 transfer."
  defp transfer_flash(%{transfers_removed: count}), do: "Removed #{count} transfers."

  defp vehicle_flash(%{vehicles_before: count_before, vehicles_after: count_after}) do
    "Vehicles needed: #{count_before} → #{count_after}."
  end

  defp apply_schedules_path(socket, scope) do
    query = [
      service_id: scope.calendar && scope.calendar.service_id,
      direction: to_string(scope.direction_id),
      pattern: to_string(scope.pattern_id)
    ]

    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{socket.assigns.route_id}/schedules?#{query}"
  end

  # Review again reloads the scope around the kept input: the review is
  # rebuilt from what is stored now, so a stale plan recovers without
  # re-pasting. The text, columns and decisions are untouched.
  defp review_again(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id
    input = current_input(socket)

    case Gtfs.prepare_timetable_paste(
           organization_id,
           version_id,
           route_id,
           read_scope_params(socket.assigns.scope),
           input
         ) do
      {:ok, %{scope: scope, review: review}} ->
        socket
        |> assign(:route, scope.route)
        |> assign(:scope, scope)
        |> assign(:review, review)
        |> assign(:paste_error, nil)
        |> assign(:source_open, is_nil(review))
        |> assign(:show_column_errors, false)
        |> assign(:show_review_errors, false)
        |> assign(:apply_notice, nil)
        |> assign(:failed_reference, nil)
        |> assign(:replace_confirm, false)
        |> assign(:load_state, :ready)
        |> put_plan_rows()
        |> push_event("focus_scoped_target", %{id: "paste-apply-status"})

      {:error, :not_found} ->
        route_not_found(socket)

      {:error, _reason} ->
        socket
        |> assign(:failed_reference, failed_reference())
        |> apply_outcome(:failed, "paste-notice-failed")
    end
  end

  # Form recovery after a reconnect during the apply: the review may be
  # gone (a new process) or intact (the same process survived). Either
  # way the outcome is unknown — rebuild when needed, show
  # `#paste-notice-unknown` and never re-apply.
  defp recover_applying(socket, params) do
    if is_nil(socket.assigns[:review]) do
      old_input = current_input(socket)
      input = merge_paste_params(old_input, params)
      input = merge_column_overrides(socket, old_input, input, params, true)
      input = merge_decision_params(socket, old_input, input, params, true)

      socket
      |> assign(:input, input)
      |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))
      |> rebuild_recovered_review(input)
      |> apply_outcome(:unknown, "paste-notice-unknown")
    else
      apply_outcome(socket, :unknown, "paste-notice-unknown")
    end
  end

  defp failed_reference do
    <<a::binary-4, b::binary-4>> = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    "#{a}-#{b}"
  end

  # The membership is re-read from the database on every apply, like every
  # other mutating event in `RouteSchedulesLive`: the assign is only a
  # snapshot from mount, so a role revoked or a membership deactivated
  # while the page is open refuses the write.
  defp editor_access?(socket) do
    with %{id: user_id} <- socket.assigns[:current_user],
         %{id: organization_id} <- socket.assigns[:current_organization] do
      EnsureRole.editor_member?(user_id, organization_id)
    else
      _other -> false
    end
  end

  defp route_not_found(socket) do
    version_id = socket.assigns.current_gtfs_version.id

    socket
    |> put_flash(:error, "Route not found")
    |> push_navigate(to: "/gtfs/#{version_id}/routes")
  end

  # A version switch with pasted text opens the switch confirmation
  # instead of navigating; confirming navigates through switch_version/2.
  # An empty form navigates at once, like RouteSchedulesLive.
  defp guard_version_switch(socket, version_id) do
    if blank_paste_text?(input_text(socket)) do
      switch_version(socket, version_id)
    else
      {:noreply,
       assign(socket, :switch_confirm, %{
         version_id: version_id,
         version_name: switch_version_name(socket, version_id)
       })}
    end
  end

  defp switch_version_name(socket, version_id) do
    socket.assigns[:available_versions]
    |> List.wrap()
    |> Enum.find_value("another version", fn {id, name} ->
      if to_string(id) == to_string(version_id), do: name
    end)
  end

  # The leave guard only ever navigates to a same-origin path the hook
  # read off a link the page rendered; anything else is dropped, including a
  # protocol-relative "//host" or "/\\host" that would leave the origin.
  defp safe_leave_path?(to) when is_binary(to) do
    String.starts_with?(to, "/") and not String.starts_with?(to, ["//", "/\\"])
  end

  defp safe_leave_path?(_to), do: false

  defp leave_schedules_path(socket) do
    case socket.assigns[:scope] do
      nil ->
        ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{socket.assigns.route_id}/schedules"

      scope ->
        apply_schedules_path(socket, scope)
    end
  end

  defp switch_version(socket, version_id) do
    organization_id = socket.assigns.current_organization.id
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(organization_id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      query =
        case socket.assigns[:scope] do
          nil -> %{}
          scope -> canonical_scope_params(scope)
        end

      {:noreply,
       push_navigate(socket,
         to: paste_path_for(version_id, socket.assigns.route_id, query)
       )}
    else
      {:noreply, socket}
    end
  end

  defp paste_path(socket, query) do
    paste_path_for(socket.assigns.current_gtfs_version.id, socket.assigns.route_id, query)
  end

  defp paste_path_for(version_id, route_id, query) do
    ~p"/gtfs/#{version_id}/routes/#{route_id}/schedules/paste?#{query}"
  end

  # The blank paste input step 23's timetable step fills in: no text, no
  # overrides, confirmations or decisions, Add mode. `prepare_timetable_paste/5`
  # reviews it to `nil`, so the shell and the drawer render without a review
  # until the person pastes. `change_schedule` keeps the text and resets the
  # rest, so changing the schedule rebuilds the review from the same paste.
  # Step 25 adds the review header's display state: the Pasted stops view
  # and the All-rows filter. `TimetablePaste.review/2` ignores both, so
  # they never affect the plan or its fingerprint.
  defp fresh_paste_input do
    %{
      text: "",
      layout: :auto,
      header?: true,
      overrides: %{},
      confirmations: MapSet.new(),
      decisions: %{},
      mode: :add,
      template_timing_id: nil,
      stops_view: :pasted,
      filter: "all",
      stamp: paste_stamp(),
      block_rows: []
    }
  end

  # New timings are named `Pasted <Mon D> · A` (R10/AC-12): the stamp is
  # today's date in the codebase's `%b %-d` display convention. The
  # fingerprint excludes the stamp, so dating a paste never stales it.
  # The stamp is UTC today, not the agency's local day: it names when the paste was read.
  defp paste_stamp, do: Wording.short_date(Date.utc_today())

  defp input_text(socket) do
    case socket.assigns[:input] do
      %{text: text} when is_binary(text) -> text
      _input -> ""
    end
  end

  defp load_scope_calendars(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.list_calendars(organization_id, version_id) do
      {:ok, calendars} -> calendars
      {:error, _reason} -> []
    end
  end

  defp draft_params(scope) do
    %{
      "service_id" => scope.calendar && scope.calendar.service_id,
      "direction" => direction_param(scope.direction_id),
      "pattern" => scope.pattern_id
    }
  end

  defp string_params(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  # The draft scope backs the drawer's pattern options and trip counts. The
  # open reuses the loaded scope (a scope never depends on the input); a
  # calendar or direction change reloads it with an empty input, and a
  # pattern-only change keeps it. A failed reload keeps the previous options
  # rather than emptying the select; submitting still canonicalizes.
  defp refresh_draft_scope(socket, _current, draft) do
    draft_scope = socket.assigns.draft_scope

    if draft_scope == nil or draft_scope_stale?(draft_scope, draft) do
      case reload_draft_scope(socket, draft) do
        nil -> {draft, draft_scope}
        reloaded -> {fix_draft_pattern(draft, reloaded), reloaded}
      end
    else
      {draft, draft_scope}
    end
  end

  defp draft_scope_stale?(draft_scope, draft) do
    draft["service_id"] != draft_scope_service(draft_scope) or
      draft["direction"] != to_string(draft_scope.direction_id)
  end

  defp draft_scope_service(draft_scope) do
    draft_scope.calendar && draft_scope.calendar.service_id
  end

  defp reload_draft_scope(socket, draft) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    scope_params = %{
      service_id: exact_id_param(draft["service_id"]),
      direction: exact_id_param(draft["direction"])
    }

    case Gtfs.prepare_timetable_paste(
           organization_id,
           version_id,
           socket.assigns.route_id,
           scope_params,
           %{}
         ) do
      {:ok, %{scope: scope}} -> scope
      {:error, _reason} -> nil
    end
  end

  defp fix_draft_pattern(draft, draft_scope) do
    ids = Enum.map(draft_scope.patterns, & &1.id)

    if draft["pattern"] in ids do
      draft
    else
      Map.put(draft, "pattern", List.first(ids))
    end
  end

  defp schedule_query(params) do
    %{}
    |> put_service_id(exact_id_param(params["service_id"] || params[:service_id]))
    |> Values.put_present(
      "direction",
      schedule_direction(params["direction"] || params[:direction])
    )
    |> Values.put_present("pattern", exact_id_param(params["pattern"] || params[:pattern]))
  end

  defp schedule_direction(direction) when direction in ["0", "1"], do: direction
  defp schedule_direction(_direction), do: nil

  # Named exception: the scope lookup compares exact service_id bytes, so only a non-binary
  # or "" becomes nil; canonical trimming would make a stored " RAW " unmatchable.
  defp exact_id_param(value) when is_binary(value) and value != "", do: value
  defp exact_id_param(_value), do: nil

  # Imported service IDs keep their exact bytes, including an all-whitespace ID.
  # Omitting one from the URL would resolve a different calendar on the next patch.
  defp put_service_id(query, nil), do: query
  defp put_service_id(query, service_id), do: Map.put(query, "service_id", service_id)

  defp close_scope_drawer(socket) do
    socket
    |> assign(:scope_draft, nil)
    |> assign(:scope_form, to_form(%{}, as: :scope))
    |> assign(:draft_scope, nil)
  end

  defp chosen_pattern(%{patterns: patterns, pattern_id: pattern_id}) do
    Enum.find(patterns, &(&1.id == pattern_id))
  end

  defp setup_reason(%{calendar: nil}), do: :no_calendar
  defp setup_reason(%{patterns: []}), do: :no_pattern
  defp setup_reason(_scope), do: nil

  defp direction_name(0), do: "Outbound"
  defp direction_name(1), do: "Inbound"
  defp direction_name(_direction), do: "Outbound"

  defp direction_adjective(0), do: "outbound"
  defp direction_adjective(1), do: "inbound"
  defp direction_adjective(_direction), do: "outbound"
end
