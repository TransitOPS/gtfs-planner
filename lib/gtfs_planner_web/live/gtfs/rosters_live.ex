defmodule GtfsPlannerWeb.Gtfs.RostersLive do
  @moduledoc """
  LiveView for Operations › Rosters.

  Rosters is the version's weekly lines: one operator's week of runs, repeated
  through the service period. This step owns the page shell and the states the
  page can be in before it has any lines — the head, the loading skeleton and the
  version that has no runs to build from. The grid, the open work and the export
  section arrive with the steps that own them.

  The page mounts through the ordinary `:gtfs_routes` session, which decides
  whether a request reaches it; the editor guard is declared here because a
  session alone grants no GTFS access. Mount carries no page state and never
  patches the URL, so a link to `/rosters` always lands on the page itself.
  Version switching keeps the page on the new version and accepts only a
  published version of the current organization.

  ## The read is the export's composition, and it happens once connected

  `Gtfs.load_roster/2` is the export's whole-version composition
  (`Blocking.export_movements/2` and `Runs.derive_version/3`, then
  `Rosters.Roster.build/1`), reached through the catalog read adapter like every
  other page read, so a stubbed adapter is enough to drive a lost connection. It
  is called from `handle_params/3` and only when connected, for `BlocksLive`'s
  reason: a disconnected render is the static HTML a browser gets before the
  socket opens, and it must not be a version of the page that has already read
  the database. So the first render is the `:loading` skeleton, and the connected
  render replaces it.

  The composition is not recomputed to answer a question it already answers.
  "This version has no runs" is `roster.summary.run_days_total == 0` — the count
  the same composition produced for the count strip step 25 draws — rather than a
  second walk of the day types' runs (INV-15).

  ## The filter and the order are the URL

  `?filter=`, `?sort=` and `?dir=` are read in `handle_params/3` and nowhere
  else, and `rosters_path/3` is the only way this page writes a path: a filter or
  an order a reader cannot share, bookmark or step back through is not really
  the reader's. Every patch is rebuilt from the socket's own state, so changing
  one of the three never drops the other two, and a value equal to its default
  is left out — `/rosters` is the all-lines, line-number order the reader
  bookmarks. An unknown value is the default, so a stale or hand-edited link
  lands on the page rather than on an error.

  ## Writes re-read the membership, and the list is one list

  Mount checks the editor role once. The `:editor_access` hook re-reads the
  membership through `EnsureRole.editor_member?/2` before each event in
  `@write_events`, so a role revoked while the page is open refuses the next
  write rather than trusting the mount-time snapshot. That check is the page's
  fast feedback, not the boundary: every writer locks the actor's editor
  membership inside its own transaction and answers `{:error, :forbidden}`
  (`Authorization.lock_editor!/1`, as `RunsLive`'s writers do), and a refusal
  from there is the same toast, so a role revoked between the hook and the write
  is refused too. The list starts with `add_line` and grows with the steps that
  add writes; a write that is not in it is not a write, which is why the list is
  the whole of the page's write surface rather than a per-handler guard nobody
  can enumerate.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Rosters.AssignmentsExport
  alias GtfsPlanner.Gtfs.Rosters.Candidates
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.EnsureRole
  alias GtfsPlannerWeb.Gtfs.RosterOperatorsComponents
  alias GtfsPlannerWeb.Gtfs.RostersComponents
  alias Plug.Conn.Query

  import GtfsPlannerWeb.Gtfs.OperationsComponents, only: [tods_review_current?: 2]

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The events that write. Mount checks the editor role once; these re-read the
  # membership before each write. `add_line` and `create_line_from_run` are step
  # 30's; they were named here from the start so the head's control and the guard
  # that covers it were introduced together.
  #
  # The slot drawer's three actions are writes and are listed with it. Opening
  # the drawer and choosing a candidate are reads of the roster already on the
  # socket, so they re-check no membership.
  #
  # The pick row is the same shape: opening and cancelling are reads of the
  # roster this socket holds, and `save_pick` is the one write.
  @write_events ~w(
    add_line
    create_line_from_run
    set_day
    set_group
    clear_day
    add_to_line
    add_to_new_line
    confirm_delete_line
    save_pick
    save_operator
    confirm_delete_operator
    apply_operator_import
    save_settings
  )

  # A role revoked while the page is open is not an error the reader caused and
  # is not a validation problem, so it is a refusal said once, in the page's own
  # toast rather than in a field.
  @editor_access_lost "You no longer have editor access to this organization."

  # The write the editor guard refused, so the drawer's own refusal is the one
  # sentence the reader is told rather than a silent nothing.
  @write_refused "Nothing was saved."

  # A pick refused for anything other than a conflict is an id this page never
  # offered. The submitted id is cast and looked up inside the caller's
  # organization by the writer, so this sentence says what the page can know and
  # nothing about another tenant's operator.
  @operator_not_offered "That operator is not on this organization's list. Choose another operator."

  # The operator the confirmation named is gone by the time the editor confirms
  # it. Both the form and the confirmation close and the page says why in its own
  # toast: a form for an operator that no longer exists is a lie, and there is no
  # card left to own the sentence.
  @operator_gone "That operator is no longer on this organization's list."

  # The operators drawer's two addresses a push names: the form the submit is
  # about, and the panel that lists the failures when the form has no invalid
  # field to focus. The list heading is the drawer's own `<h2>`, which the drawer
  # chrome gives a stable id and a `tabindex`.
  @operator_form_id "rosters-operator-form"
  @operator_form_error_id "rosters-operator-form-errors"
  @operators_title_id "rosters-operators-drawer-title"

  # The import view's own message, so the refusal the context hands back is
  # moved to rather than scrolled past.
  @operator_import_error_id "rosters-import-error"

  # The settings form and its summary: the form the save pushes focus into, and
  # the panel that lists the failures when a field error has no control to land
  # on. Both are this drawer's own addresses.
  @settings_form_id "rosters-settings-form"
  @settings_errors_id "rosters-settings-errors"

  # The version went unpublished between the settings drawer opening and the
  # save. The drawer keeps its entries and says this, because the entries are
  # the planner's work and the version's state is not a reason to retype them.
  @settings_not_found "That version is no longer published, so nothing was saved."

  # The import review with nothing in it: the drawer stays open with no file
  # chosen, and every path into it — opening, cancelling, a new file, a refused
  # apply's own reset — starts from here.
  @empty_operator_import %{
    filename: nil,
    parsed: nil,
    preview: nil,
    parse_error: nil,
    stale?: false
  }

  # The full weekday name. The grid's own module has the same list for the same
  # reason: the confirmation toast names the day a planner just changed.
  @weekday_names ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  # The version went unpublished between the session hook and this read. The
  # reader has no roster to look at, and the hook's own answer is the one to give.
  @version_not_found "GTFS version not found"

  # The line the confirmation named is gone by the time the planner confirms it.
  # Both overlays close and the page says why in its own toast: there is no
  # drawer left to own the sentence.
  @line_gone "That line is no longer on this version."

  # A lost connection is a pause, not a state the page moves into: the page keeps
  # the roster it last read and draws `#rosters-unavailable` above it, with the
  # retry that ends the pause. On a first load there is nothing to keep, so the
  # flash carries the reason and the loading panel stays.
  @roster_unreadable "The roster could not be read. Reload to try again."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Rosters")
     # Nothing is loaded yet. `:loading` is the honest first state and the one
     # the disconnected render shows, so the static HTML and the connected HTML
     # agree.
     |> assign(:load_state, :loading)
     |> assign(:roster, nil)
     |> assign(:day_types, [])
     |> assign(:operators_count, 0)
     # The export section's rows, warnings and counts, computed from the loaded
     # composition and not inside `render/1`, for the open work's reason.
     |> assign(:assignments, nil)
     # The URL's three params start at their defaults, which are also the
     # values `rosters_path/3` leaves out of a patch: `/rosters` and
     # `/rosters?filter=all` are the same page, and the short one is the one a
     # reader bookmarks.
     |> assign(:filter, "all")
     |> assign(:sort, :line)
     |> assign(:dir, :asc)
     |> assign(:shown_count, 0)
     |> assign(:loaded_version_id, nil)
     # The toast is event state, not page state, so it starts empty. Starting it
     # empty is also what makes `RostersComponents.toast/1` render nothing on
     # first paint: a `role="status"` region present with no text announces
     # nothing and still occupies the fixed box at the foot of the viewport.
     |> assign(:toast, nil)
     |> assign(:slot, nil)
     # The line a write just created, so the grid can point at it. Cleared by
     # the next write, because a highlight is about the change the planner just
     # made and nothing else (see `clear_new_line/1`).
     |> assign(:new_line_id, nil)
     # The refusal a create left on one open-run card, `%{run_id:, text:}`. It
     # is page state rather than a toast because it belongs to a card, and it is
     # cleared by the next write for the same reason as the toast.
     |> assign(:open_work_refusal, nil)
     # The add-to-line drawer's data. Like `:slot`, it is built by the event
     # that changes it and never inside `render/1`, for the same reason.
     |> assign(:add_to_line, nil)
     # The line drawer and the delete confirmation it opens. `:line` is the
     # composition's own line — the map the grid's row was drawn from — and
     # `:delete_line` is what the confirmation names. Neither is ever built in
     # `render/1`, for the slot drawer's reason.
     |> assign(:line, nil)
     |> assign(:delete_line, nil)
     # The pick row, the line being picked and the operators on offer for it.
     # Built by the events that change it, like the drawers, for the same
     # reason.
     |> assign(:pick, nil)
     # The operators drawer, in whichever of its two views it is. `:operators` is
     # the list the drawer is showing — `Operations.list_operators/1` in its own
     # order, plus the line each one holds in *this* version — and
     # `:operator_form` is the add/edit form, which replaces the list inside the
     # same drawer rather than opening another surface. Both are built by the
     # events that change them, for the slot drawer's reason.
     |> assign(:operators, nil)
     |> assign(:operator_form, nil)
     # The delete confirmation and what it names. Built by the events that change
     # it, for the drawers' reason: `:holdings` is a read of every version's
     # picks, and an assign made during a render would cost the page its
     # streamed rows.
     |> assign(:delete_operator, nil)
     # The import view of the same drawer, in whichever of its three states the
     # file is in: no file, a file the browser is still sending, a parse that
     # returned a message, or a review. It is event state like the others, and
     # the upload that fills it is declared once here.
     |> assign(:operator_import, nil)
     # The roster settings drawer: the base week, the two checks and the fixed
     # days-off rule. Event state like every other surface on this page, and
     # built by the events that change it rather than inside `render/1`.
     |> assign(:settings, nil)
     |> allow_upload(:operators_file,
       accept: ~w(.csv .txt),
       max_entries: 1,
       max_file_size: Tods.max_import_bytes(),
       auto_upload: true,
       progress: &handle_operators_file_progress/3
     )
     |> stream(:roster_lines, [], dom_id: &roster_row_dom_id/1)
     |> attach_hook(:editor_access, :handle_event, &require_editor/3)}
  end

  # The row's DOM id is its line number, not the line's id: a row is addressed
  # by where it sits in the week, and the line number is what the grid shows.
  # The pick row is a row of the same stream under a key of its own, so opening
  # and closing a pick inserts and removes one row and leaves the lines around it
  # exactly as they were.
  defp roster_row_dom_id({:line, line}), do: "rosters-line-#{line.line_number}"
  defp roster_row_dom_id({:pick, pick}), do: "rosters-pick-#{pick.line_number}"

  defp require_editor(event, _params, socket) when event in @write_events do
    if editor_access?(socket) do
      {:cont, socket}
    else
      {:halt, editor_refusal(socket)}
    end
  end

  defp require_editor(_event, _params, socket), do: {:cont, socket}

  # What a refused write says, whether the hook above or the writer's own
  # `{:error, :forbidden}` caught it. The drawer or form that was open is left as
  # it is, so what the editor typed is still there.
  defp editor_refusal(socket) do
    socket
    |> put_toast(@editor_access_lost, :refused)
    |> put_flash(:error, @editor_access_lost)
  end

  # An early check on the membership, so a revoked editor is refused before a
  # writer is called. It is advisory: the writers repeat it under lock.
  defp editor_access?(socket) do
    with %{id: user_id} <- socket.assigns[:current_user],
         %{id: organization_id} <- socket.assigns[:current_organization] do
      EnsureRole.editor_member?(user_id, organization_id)
    else
      _other -> false
    end
  end

  # The toast, and the timer that takes it away. The token is what keeps a timer
  # set for an earlier toast from dismissing a later one: without it, a reader
  # who acts twice quickly watches the second message vanish on the first one's
  # schedule.
  defp put_toast(socket, text, kind) do
    token = System.unique_integer([:positive, :monotonic])
    Process.send_after(self(), {:dismiss_toast, token}, 4_000)

    assign(socket, :toast, %{text: text, kind: kind, token: token})
  end

  # The failed refresh and the grid's disabled controls are one sentence, and it
  # is written once — by the component that owns it, for the same reason the head
  # reads it from there.
  defp paused_reason, do: RostersComponents.refresh_paused_reason()

  @impl true
  def handle_info({:dismiss_toast, token}, socket) do
    if socket.assigns.toast && socket.assigns.toast.token == token do
      {:noreply, assign(socket, :toast, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The filter and the order come from the URL, and the URL is the only source of
  # them.
  #
  # `?filter=`, `?sort=` and `?dir=` are read in `handle_params/3` and nowhere
  # else, for the reason `?day=` is on the Runs page: a view a reader cannot
  # link to, bookmark or step back through with the back button is not really
  # the reader's. There is no separate "selected filter" assign a second code
  # path could set, so the address bar and the rows cannot disagree.
  #
  # A change to any of the three re-streams the rows rather than re-reading the
  # roster: `ensure_roster_loaded/1` would see its own guard and return the
  # socket untouched, and the week would keep the order and the rows it had. So
  # the re-stream is asked for explicitly, where the change is known.
  @impl true
  def handle_params(params, _uri, socket) do
    filter = filter_value(params["filter"])
    sort = sort_key(params["sort"])
    dir = sort_dir(params["dir"])

    view_changed? =
      socket.assigns.filter != filter or socket.assigns.sort != sort or socket.assigns.dir != dir

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:sort, sort)
      |> assign(:dir, dir)
      |> ensure_roster_loaded()

    {:noreply, if(view_changed?, do: stream_roster_lines(socket), else: socket)}
  end

  # The filters the row bar owns. An unknown value is `all`, so a stale or
  # hand-edited link lands on the page rather than on an error.
  defp filter_value("open"), do: "open"
  defp filter_value("problems"), do: "problems"
  defp filter_value("stale"), do: "stale"
  defp filter_value(_filter), do: "all"

  # The sorts this grid owns: the line's own number, its weekly paid time and
  # the operator who holds it. A key the grid does not have is refused rather
  # than passed through, because `sort_header/1` resolves its key as an existing
  # atom and a reader who edits the URL should get the default order, not a
  # crash.
  @sort_keys %{"line" => :line, "paid" => :paid, "operator" => :operator}

  defp sort_key(nil), do: :line
  defp sort_key(key) when is_binary(key), do: Map.get(@sort_keys, key, :line)
  defp sort_key(key) when is_atom(key) and not is_nil(key), do: sort_key(Atom.to_string(key))
  defp sort_key(_key), do: :line

  defp sort_dir("desc"), do: :desc
  defp sort_dir(_dir), do: :asc

  # `BlocksLive.ensure_day_loaded/1`'s rule: the disconnected render shows the
  # loading state, and a roster already loaded is not read again. The guard
  # matters because `handle_params/3` runs on every patch.
  defp ensure_roster_loaded(socket) do
    cond do
      not connected?(socket) ->
        assign(socket, :load_state, :loading)

      socket.assigns.loaded_version_id == to_string(socket.assigns.current_gtfs_version.id) ->
        socket

      true ->
        load_roster(socket)
    end
  end

  defp load_roster(socket) do
    %{current_organization: organization, current_gtfs_version: version} = socket.assigns

    case Gtfs.load_roster(organization.id, version.id) do
      {:ok, view} ->
        socket
        |> assign(:roster, view.roster)
        # The version's day types with their dates, which the composition used to
        # resolve the base week and which the settings drawer offers as the
        # choices for each weekday. Reading them off the same composition is what
        # keeps a weekday's select and the week the grid shows from being two
        # different calendars (INV-15).
        |> assign(:day_types, view.day_types)
        # The organization's operator list is not part of the roster
        # composition (a line's own operator is), so this count is the one
        # figure the scope bar needs that the composition does not answer.
        |> assign(:operators_count, length(Operations.list_operators(organization.id)))
        # The export section reads `AssignmentsExport.rows/1` over the same
        # roster, day types and `run_days` this composition just produced, with
        # `services: nil` because the page shows rows and not service IDs. It is
        # the export's own pure function, so the preview and the warnings are the
        # file's own view of this snapshot rather than a second reading of it
        # (INV-14).
        |> assign(
          :assignments,
          AssignmentsExport.rows(%{
            roster: view.roster,
            day_types: view.day_types,
            run_days: view.run_days,
            services: nil
          })
        )
        |> assign(:loaded_version_id, to_string(version.id))
        |> assign(:load_state, roster_state(view.roster))
        # Re-streamed on every read, keyed by line, so a roster that changed
        # one line's days patches that row rather than redrawing the week. The
        # stream is what a filter or a sort patches instead of the list it is
        # reading.
        |> stream_roster_lines()

      {:error, :not_found} ->
        # The session hook already refused a version that is not this
        # organization's published one, so this is a version that went
        # unpublished between the hook and this read. `push_navigate/2` is the
        # redirect itself, so the flash and the navigation leave together; the
        # loaded roster is not assigned, because there is none to keep.
        socket
        |> assign(:roster, nil)
        |> put_flash(:error, @version_not_found)
        |> push_navigate(to: ~p"/")

      {:error, :unavailable} ->
        # `roster` is deliberately untouched, so whatever is on screen stays — and
        # so does the streamed grid, which is part of that same last roster. A
        # first load that fails has nothing on screen, so it keeps the loading
        # panel and says why in the flash rather than leaving a blank region.
        socket
        |> assign(
          :load_state,
          if(socket.assigns.roster, do: :unavailable, else: :loading)
        )
        |> put_flash(:error, @roster_unreadable)
    end
  end

  # The rows on screen are the roster's lines, narrowed by `?filter=` and put in
  # `?sort=` order. Both are read from the composition the page already has:
  # a line's findings and stale states are `Roster.build/1`'s words and nothing
  # here decides what counts as a problem or as a stale slot (INV-15).
  defp stream_roster_lines(%{assigns: %{roster: nil}} = socket), do: socket

  defp stream_roster_lines(socket) do
    %{roster: roster, filter: filter, sort: sort, dir: dir, pick: pick} = socket.assigns
    lines = roster.lines |> Enum.filter(&visible?(&1, filter)) |> sorted(sort, dir)

    # The count is carried rather than read back off the stream: a `LiveStream`
    # is not enumerable, and the filter row and the empty row both need to know
    # whether anything was left.
    socket
    |> assign(:shown_count, length(lines))
    |> stream(:roster_lines, grid_rows(lines, pick), reset: true)
  end

  # The pick row goes into the same stream as the lines, directly after the line
  # it belongs to. A stream never redraws a row that is already on screen, so a
  # pick row drawn beside the streamed lines would not appear when the pick
  # opened; as an item of the stream it is inserted under its line and removed
  # when the pick closes, and no other row is disturbed.
  defp grid_rows(lines, nil), do: Enum.map(lines, &{:line, &1})

  defp grid_rows(lines, %{line_number: number} = pick) do
    Enum.flat_map(lines, fn line ->
      if line.line_number == number, do: [{:line, line}, {:pick, pick}], else: [{:line, line}]
    end)
  end

  # An open line is a line nobody has picked, so it is a line the reader is
  # looking for. A problem is a line the composition has something to say about.
  defp visible?(line, "open"), do: is_nil(line.operator)
  defp visible?(line, "problems"), do: line.findings != []
  defp visible?(line, "stale"), do: stale?(line)
  defp visible?(_line, "all"), do: true

  defp stale?(line), do: Enum.any?(line.findings, &(&1.code == :stale_slot))

  # Every order ends in the line number, so two lines that compare equal — two
  # lines with no paid time, two with the same operator — keep a stable order
  # instead of being reshuffled by every re-stream.
  defp sorted(lines, :line, dir), do: Enum.sort_by(lines, & &1.line_number, sorter(dir))

  defp sorted(lines, :paid, dir),
    do: Enum.sort_by(lines, & &1.paid_secs, sorter(dir))

  # Operator orders by display name. An open line has no operator, and it is last
  # in both directions: it is the one row of the three orders with no name to
  # place, and a reader sorting by operator is reading names. So the direction
  # reverses the named lines only.
  defp sorted(lines, :operator, dir) do
    assigned = Enum.filter(lines, &(not is_nil(&1.operator)))
    open = Enum.filter(lines, &is_nil(&1.operator))

    named =
      Enum.sort_by(assigned, &operator_name(&1), sorter(dir))

    named ++ open
  end

  defp operator_name(%{operator: %{display_name: name}}), do: String.downcase(name)
  defp operator_name(_line), do: ""

  defp sorter(:desc), do: :desc
  defp sorter(:asc), do: :asc

  # "No runs" is the composition's own run-day total, not a second walk of the
  # day types (INV-15). A version with day types but no runs to place, and a
  # version with no calendars at all, are the same answer here: there is nothing
  # to build a line from.
  defp roster_state(%{summary: %{run_days_total: 0}}), do: :no_runs
  defp roster_state(_roster), do: :ready

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/rosters")}
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
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/rosters")}
    else
      {:noreply, socket}
    end
  end

  # The retry in `#rosters-unavailable`. It is a read, so it is not in
  # `@write_events` and re-checks no membership: the only thing that can end the
  # pause is another successful read. A successful one replaces the last roster
  # and leaves the pause; a failed one keeps the pause, the roster and the
  # message.
  def handle_event("retry_load", _params, socket) do
    {:noreply, load_roster(socket)}
  end

  @filter_values %{"all" => true, "open" => true, "problems" => true, "stale" => true}

  # The four filter options. This is a URL param and nothing else, for the
  # reason `?day=` is: a filter a reader cannot share or step back through is
  # not really the reader's. The path is rebuilt from the socket, so changing the
  # filter keeps the order they had chosen.
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    if Map.has_key?(@filter_values, filter) do
      {:noreply, push_patch(socket, to: rosters_path(socket, filter))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_filter", _params, socket), do: {:noreply, socket}

  # Sorting the same key again reverses it; any other key starts ascending,
  # which is `BlocksLive`'s rule and the one a reader has already met.
  def handle_event("sort", %{"key" => key}, socket) do
    if Map.has_key?(@sort_keys, key) do
      dir =
        if socket.assigns.sort == Map.fetch!(@sort_keys, key),
          do: toggle_dir(socket.assigns.dir),
          else: :asc

      {:noreply,
       push_patch(socket,
         to: rosters_path(socket, socket.assigns.filter, %{sort: key, dir: dir})
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("sort", _params, socket), do: {:noreply, socket}

  # "Show stale slots" is the filter that already exists, so it patches the same
  # URL the filter row patches, keeping whatever order the reader had chosen.
  def handle_event("show_stale", _params, socket) do
    {:noreply, push_patch(socket, to: rosters_path(socket, "stale"))}
  end

  def handle_event("dismiss_toast", _params, socket) do
    {:noreply, assign(socket, :toast, nil)}
  end

  # ── The slot drawer ────────────────────────────────────────────────────────
  #
  # Opening a slot and choosing a candidate are reads of the roster this socket
  # already holds, so neither re-reads the membership and neither is in
  # `@write_events`. The three writes below are.
  #
  # The drawer's whole data is built when an event changes it, not inside
  # `render/1`. Assigning inside `render/1` invalidates the change tracker for
  # the whole template, and a `LiveStream` re-rendered that way loses its rows —
  # so the drawer's data is `Candidates`' answer over the roster this socket
  # already holds, kept on `:slot` and read by `RostersComponents.slot_drawer/1`
  # (INV-15). Every event that changes the drawer goes through `open_slot/4`,
  # which is the one place that builds it.
  def handle_event("open_slot", %{"line" => line_id, "weekday" => weekday}, socket) do
    with {:ok, weekday} <- slot_weekday(weekday),
         {:ok, slot} <- open_slot(socket, line_id, weekday, nil) do
      {:noreply, assign(socket, :slot, slot)}
    else
      :error -> {:noreply, socket}
    end
  end

  def handle_event("choose_candidate", %{"run" => run_id}, socket) do
    case socket.assigns.slot do
      %{line_id: line_id, weekday: weekday} ->
        case open_slot(socket, line_id, weekday, run_id) do
          # A run this drawer does not offer is not a choice, so the selection
          # stays where it was rather than naming a run no action can take.
          {:ok, slot} -> {:noreply, assign(socket, :slot, slot)}
          :error -> {:noreply, socket}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("close_slot", _params, socket) do
    {:noreply, assign(socket, :slot, nil)}
  end

  # The three writes. Each one reloads the roster on success — the drawer closes
  # and the grid redraws from the composition, so the short rests a manual edit
  # is allowed to leave are the grid's own findings rather than a sentence this
  # page keeps — and on a refusal keeps the drawer open with the reason drawn in
  # it, because a refusal that closes the drawer reads as the page having lost
  # the planner's work.
  def handle_event("set_day", _params, socket) do
    with %{line_id: line_id, weekday: weekday, run_id: run_id} <- writable_slot(socket),
         {:ok, result} <-
           Gtfs.set_roster_slot(
             AuditContext.from_assigns(socket.assigns),
             line_id,
             weekday,
             run_id
           ) do
      {:noreply,
       saved(socket, result.short_rests, "Set #{weekday_name(weekday)} to run #{run_id}.")}
    else
      {:error, :forbidden} -> {:noreply, editor_refusal(socket)}
      {:error, reason} -> {:noreply, refuse(socket, reason)}
      _no_slot -> {:noreply, socket}
    end
  end

  def handle_event("set_group", _params, socket) do
    with %{line_id: line_id, weekday: weekday, run_id: run_id} <- writable_slot(socket),
         {:ok, _result} <-
           Gtfs.set_roster_weekday_group(
             AuditContext.from_assigns(socket.assigns),
             line_id,
             weekday,
             run_id
           ) do
      {:noreply, saved(socket, [], "Set #{group_label(socket, weekday)} to run #{run_id}.")}
    else
      {:error, :forbidden} -> {:noreply, editor_refusal(socket)}
      {:error, reason} -> {:noreply, refuse(socket, reason)}
      _no_slot -> {:noreply, socket}
    end
  end

  def handle_event("clear_day", _params, socket) do
    with %{line_id: line_id, weekday: weekday} <- writable_slot(socket),
         {:ok, _result} <-
           Gtfs.clear_roster_slot(AuditContext.from_assigns(socket.assigns), line_id, weekday) do
      {:noreply, saved(socket, [], "Cleared #{weekday_name(weekday)}.")}
    else
      {:error, :forbidden} -> {:noreply, editor_refusal(socket)}
      {:error, reason} -> {:noreply, refuse(socket, reason)}
      _no_slot -> {:noreply, socket}
    end
  end

  # ── Open work ──────────────────────────────────────────────────────────────
  #
  # Two writes live here, and both create a line through the real writer:
  # `Gtfs.create_roster_line/1` for the head's "Add line", and
  # `Gtfs.create_roster_line_from_run/3` for a card's "Create Mon–Fri line".
  #
  # "Add line" opens the new line's Monday drawer afterwards, because an empty
  # week with no way to fill it is a dead end: the planner's next move is to
  # choose Monday's run. The drawer is built by the same `open_slot/4` the grid
  # uses, from the roster re-read after the write.
  #
  # A create from a card names the line it built, so the grid can highlight that
  # row and scroll to it. The highlight is one change deep: `clear_new_line/1`
  # drops it on the next write, because a row still tinted after the planner has
  # moved on is a mark about something that is no longer the last thing they did.
  def handle_event("add_line", _params, socket) do
    case Gtfs.create_roster_line(AuditContext.from_assigns(socket.assigns)) do
      {:ok, line} ->
        socket = socket |> clear_open_work() |> assign(:new_line_id, line.id) |> load_roster()

        {:noreply,
         socket
         |> open_new_line_drawer(line.id)
         |> put_toast("Line #{line.line_number} added.", :done)}

      {:error, :forbidden} ->
        {:noreply, socket |> clear_open_work() |> editor_refusal()}

      {:error, :not_found} ->
        # The head's control is not on a card, so its refusal is the page's own
        # toast rather than a card message: there is nowhere on a card for it.
        {:noreply, socket |> clear_open_work() |> put_toast(@version_not_found, :refused)}
    end
  end

  def handle_event(
        "create_line_from_run",
        %{"day_type" => day_type_key, "run" => run_id},
        socket
      ) do
    case Gtfs.create_roster_line_from_run(
           AuditContext.from_assigns(socket.assigns),
           day_type_key,
           run_id
         ) do
      {:ok, line} ->
        socket = socket |> clear_open_work() |> assign(:new_line_id, line.id) |> load_roster()

        {:noreply, put_toast(socket, created_sentence(socket, line, run_id), :done)}

      {:error, :forbidden} ->
        {:noreply, socket |> clear_open_work() |> editor_refusal()}

      {:error, reason} ->
        {:noreply, refuse_open_work(socket, run_id, reason)}
    end
  end

  # ── Add an open run to a line ──────────────────────────────────────────────
  #
  # Opening the drawer and choosing the day or the line are reads of the roster
  # this socket already holds, so they re-check no membership and are not in
  # `@write_events`; the two writes at the bottom of this section are.
  #
  # The whole drawer's data is built by `open_add_to_line/4`, for the same reason
  # the slot drawer's is: an assign made during `render/1` costs the page its
  # streamed rows. The lines on offer are `Candidates.lines_for_open_run/3`'s
  # rows in that function's order, so what a planner chooses from is the same
  # computation on screen and under the lock (INV-15).
  def handle_event(
        "open_add_to_line",
        %{"day_type" => day_type_key, "run" => run_id},
        socket
      ) do
    case open_add_to_line(socket, day_type_key, run_id, nil) do
      # One overlay at a time: the page has a single drawer slot, so opening
      # this one closes a slot drawer left open from the grid.
      {:ok, add} -> {:noreply, socket |> assign(:slot, nil) |> assign(:add_to_line, add)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("choose_add_day", %{"weekday" => weekday}, socket) do
    with %{day_type_key: key, run_id: run_id} <- chosen_add_run(socket),
         {:ok, weekday} <- slot_weekday(weekday),
         {:ok, add} <- open_add_to_line(socket, key, run_id, weekday) do
      {:noreply, assign(socket, :add_to_line, add)}
    else
      _not_this_drawer -> {:noreply, socket}
    end
  end

  # A line this drawer is not offering is not a choice, so the selection stays
  # where it was rather than naming a line the write could not take. The id is
  # checked against the drawn rows, which is what keeps a hand-built event from
  # reaching a line of another version.
  def handle_event("choose_add_line", %{"line" => line_id}, socket) do
    case socket.assigns.add_to_line do
      %{lines: lines} = add ->
        if Enum.any?(lines, &(&1.line.id == line_id)) do
          {:noreply, assign(socket, :add_to_line, %{add | selected_line_id: line_id})}
        else
          {:noreply, socket}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("close_add_to_line", _params, socket) do
    {:noreply, assign(socket, :add_to_line, nil)}
  end

  # The write onto a line that already exists. The roster is re-read and the
  # drawer closes on success, because the run is no longer open work and the
  # card it came from is gone; a refusal keeps the drawer with the writer's own
  # sentence in it, because a refusal that closes a drawer reads as the page
  # having lost the planner's work.
  def handle_event("add_to_line", _params, socket) do
    with %{run_id: run_id, weekday: weekday, selected_line_id: line_id} <- writable_add(socket),
         number when not is_nil(number) <- add_line_number(socket, line_id),
         {:ok, result} <-
           Gtfs.set_roster_slot(
             AuditContext.from_assigns(socket.assigns),
             line_id,
             weekday,
             run_id
           ) do
      {:noreply,
       socket
       |> close_add()
       |> saved(
         result.short_rests,
         "Added run #{run_id} to line #{number} on #{weekday_name(weekday)}."
       )}
    else
      {:error, :forbidden} -> {:noreply, editor_refusal(socket)}
      {:error, reason} -> {:noreply, refuse_add_to_line(socket, reason)}
      _nothing_to_add -> {:noreply, socket}
    end
  end

  # "Create new line" is two writes, because the spec asks for a line holding
  # this run on this day rather than for a line and a later set. The first write
  # is `create_roster_line/1` and the second is the same `set_roster_slot/4` the
  # line above uses. A refusal of the second leaves the empty line standing —
  # deleting it would be a third write hiding a fact the planner needs to see —
  # and says so, in the drawer, over the roster the second write was refused
  # against.
  def handle_event("add_to_new_line", _params, socket) do
    case writable_add(socket) do
      %{run_id: run_id, weekday: weekday} -> create_line_for_add(socket, weekday, run_id)
      _no_writable_add -> {:noreply, socket}
    end
  end

  # ── The line drawer ───────────────────────────────────────────────────────
  #
  # Opening the drawer and asking to delete the line are reads of the roster
  # this socket already holds: the drawer draws the composition's own line and
  # the confirmation's run-day count is that line's own stored days. Neither
  # re-checks the membership, so neither is in `@write_events`. The delete is.
  def handle_event("open_line", %{"line" => line_id}, socket) do
    case socket.assigns.roster do
      nil ->
        {:noreply, socket}

      roster ->
        case Enum.find(roster.lines, &(&1.id == line_id)) do
          # A line this version's roster does not hold is not a choice, so the
          # click is ignored rather than opening a drawer describing work that is
          # not there. Opening this one closes a slot or add-to-line drawer left
          # open, because the page has a single drawer slot.
          nil ->
            {:noreply, socket}

          line ->
            {:noreply,
             socket |> assign(:slot, nil) |> assign(:add_to_line, nil) |> assign(:line, line)}
        end
    end
  end

  def handle_event("close_line", _params, socket) do
    {:noreply, assign(socket, :line, nil)}
  end

  # The confirmation names the line and its run-days, both read off the drawer
  # that is open rather than re-read from the page, so the drawer and the
  # confirmation cannot be describing different lines.
  def handle_event("ask_delete_line", _params, socket) do
    case socket.assigns.line do
      nil ->
        {:noreply, socket}

      line ->
        {:noreply,
         assign(socket, :delete_line, %{
           line_id: line.id,
           line_number: line.line_number,
           run_days: map_size(line.slots),
           picked?: not is_nil(line.operator)
         })}
    end
  end

  def handle_event("cancel_delete_line", _params, socket) do
    {:noreply, assign(socket, :delete_line, nil)}
  end

  # The delete. The line's days go with it through the foreign key, so every run
  # it held returns to open work; the roster is re-read afterwards, so the grid
  # and the open-work cards below it redraw from the composition rather than
  # from a row this page removed itself. The count in the toast is the writer's
  # own answer, which is what the confirmation named.
  #
  # The line's row is gone afterwards, and its link went with it, so focus is
  # pushed to the grid's own heading through the page's scoped `FormErrorFocus`
  # hook instead of being dropped at the top of the document.
  def handle_event("confirm_delete_line", _params, socket) do
    case socket.assigns.delete_line do
      %{line_id: line_id} ->
        delete_line(socket, line_id)

      nil ->
        {:noreply, socket}
    end
  end

  # ── The operators drawer ───────────────────────────────────────────────────
  #
  # Operators are the one roster input the organization owns across every
  # version, so this drawer is not version-scoped; only its Line column is, and
  # that column is read off the roster this socket already holds rather than
  # re-derived (INV-15).
  #
  # Opening the drawer, choosing an operator to edit, validating and cancelling
  # are all reads of state this socket already holds, so none of them re-checks
  # the membership and none is in `@write_events`. `save_operator` is.
  #
  # The whole drawer's data is built by the events that change it, never inside
  # `render/1`, for the slot drawer's reason: an assign made during a render
  # costs the page its streamed rows.
  def handle_event("open_operators", _params, socket) do
    {:noreply,
     socket
     |> assign(:slot, nil)
     |> assign(:add_to_line, nil)
     |> assign(:line, nil)
     |> assign(:pick, nil)
     |> assign(:operator_form, nil)
     |> put_operators(load_operators(socket))}
  end

  def handle_event("close_operators", _params, socket) do
    {:noreply, close_operators(socket)}
  end

  def handle_event("new_operator", _params, socket) do
    {:noreply, open_operator_form(socket, nil, %{})}
  end

  # An operator this drawer is not showing is not a choice, so the click is
  # ignored rather than opening a form for an operator this page never offered.
  # The submitted id is also cast and looked up inside the caller's
  # organization by the writer (the "Scoped identities" criterion), so this check
  # is a convenience rather than the boundary.
  def handle_event("edit_operator", %{"id" => operator_id}, socket) do
    case drawn_operator(socket, operator_id) do
      nil ->
        {:noreply, socket}

      operator ->
        {:noreply, open_operator_form(socket, operator, operator_params(operator))}
    end
  end

  # Blur is the moment the page believes a field is finished, so the error for a
  # field is drawn from the blur that left it and not before: a reader halfway
  # through an employee ID is not told the employee ID is wrong while typing it.
  # The rules are the writer's own changeset run with the `:validate` action, so
  # the page invents no validation of its own.
  def handle_event("validate_operator", %{"operator" => params} = payload, socket) do
    case socket.assigns.operator_form do
      nil ->
        {:noreply, socket}

      form_state ->
        changeset =
          form_state.base
          |> operator_changeset(params, :validate)
          |> only_touched_errors(form_state.touched |> touch(payload["_target"]))

        {:noreply, put_operator_form(socket, form_state, changeset, form_state.failures)}
    end
  end

  def handle_event("validate_operator", _params, socket), do: {:noreply, socket}

  # A write with no form open is not a write, and neither is one whose operator
  # this socket no longer holds: the form carries the id it was opened for, so a
  # hand-built event cannot reach another operator than the one on screen.
  def handle_event("save_operator", %{"operator" => params}, socket) do
    case writable_operator(socket, socket.assigns.operator_form) do
      nil ->
        {:noreply, socket}

      form_state ->
        changeset = operator_changeset(form_state.base, params, operator_action(form_state))

        if changeset.valid? do
          write_operator(socket, form_state, params)
        else
          # The submit is the one moment every field is finished, so every error
          # is drawn and the first invalid field takes focus: a refusal that only
          # marked the fields the editor happened to blur leaves them guessing.
          {:noreply,
           socket
           |> put_operator_form(form_state, changeset, operator_failures(changeset))
           |> push_event("focus_form_error", %{
             form_id: @operator_form_id,
             fallback_id: @operator_form_error_id
           })}
        end
    end
  end

  def handle_event("save_operator", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_operator", _params, socket) do
    case socket.assigns.operator_form do
      nil ->
        {:noreply, socket}

      _form ->
        {:noreply,
         socket
         |> assign(:operator_form, nil)
         |> put_operators(load_operators(socket))}
    end
  end

  # The delete confirmation names the operator and the lines their picks empty.
  # Those lines are read across every version of the organization with
  # `Gtfs.roster_operator_holdings/2`, not off this version's roster: a hard
  # delete empties a pick in each of them, so naming only the one on screen
  # would leave the reader to find the others themselves.
  #
  # It is a read of state this socket could name without writing, so it is not in
  # `@write_events`; only `confirm_delete_operator` is.
  def handle_event("ask_delete_operator", %{"id" => operator_id}, socket) do
    case drawn_operator(socket, operator_id) do
      nil ->
        {:noreply, socket}

      operator ->
        {:noreply,
         assign(socket, :delete_operator, %{
           operator_id: operator.id,
           name: operator.display_name,
           holdings:
             Gtfs.roster_operator_holdings(socket.assigns.current_organization.id, operator.id)
         })}
    end
  end

  def handle_event("cancel_delete_operator", _params, socket) do
    {:noreply, assign(socket, :delete_operator, nil)}
  end

  # The delete. `Operations.delete_operator/3` is a hard delete whose foreign key
  # leaves every held line open, in this version and in every other; the roster
  # is re-read afterwards so the grid redraws from the composition rather than
  # from a pick this page removed itself.
  #
  # The confirmation carries the id it was opened for, so a hand-built event
  # cannot reach another operator than the one on screen, and the writer scopes
  # the id to the caller's organization anyway.
  def handle_event("confirm_delete_operator", _params, socket) do
    case socket.assigns.delete_operator do
      %{operator_id: operator_id} ->
        delete_operator(socket, operator_id)

      nil ->
        {:noreply, socket}
    end
  end

  # ── The operator import ───────────────────────────────────────────────────
  #
  # Upload, then review, then apply. The page owns the file, the parse and the
  # write; `RosterOperatorsComponents.operator_import/1` owns the copy. The apply
  # is a write and is in `@write_events`; opening the view, acknowledging the
  # file input's change, cancelling the upload and going back to the list are
  # not, and each changes only what this page already holds.
  def handle_event("open_operator_import", params, socket) do
    opener_id = params["opener_id"] || "rosters-import-operators"

    {:noreply,
     socket
     |> discard_operator_upload()
     |> assign(:operator_import, Map.put(@empty_operator_import, :opener_id, opener_id))}
  end

  def handle_event("cancel_operator_import", _params, socket) do
    {:noreply,
     socket
     |> discard_operator_upload()
     |> assign(:operator_import, nil)
     |> put_operators(load_operators(socket))}
  end

  # Cancelling an upload that has not finished, or replacing a review with a
  # file still on its way, leaves the drawer with nothing to apply.
  def handle_event("cancel_operator_upload", %{"ref" => ref}, socket) do
    {:noreply, socket |> cancel_upload(:operators_file, ref) |> reset_operator_import()}
  end

  def handle_event("cancel_operator_upload", _params, socket), do: {:noreply, socket}

  # LiveView routes the file input's change through the drawer's form, so the
  # form declares a change event; the drawer holds no other form state to check.
  def handle_event("validate_operator_import", _params, socket), do: {:noreply, socket}

  def handle_event("apply_operator_import", _params, socket) do
    state = socket.assigns.operator_import

    # An apply with no reviewed file, or with a replacement still uploading, is
    # an event this page never offered: the same rule the drawer draws the
    # unavailable primary from, so the control and the write cannot disagree.
    if is_map(state) and is_map(state.parsed) and
         tods_review_current?(state.preview, socket.assigns.uploads.operators_file) do
      apply_reviewed_operator_import(socket, state.parsed, state.preview)
    else
      {:noreply, socket}
    end
  end

  # ── The pick row ──────────────────────────────────────────────────────────
  #
  # The pick is a record of what a bid agreed, not a proposal the page decides
  # anything about: the row offers the organization's operators in seniority
  # order, `Gtfs.assign_roster_operator/3` records or clears, and the writer's
  # own refusal is the sentence the row shows.
  #
  # Opening a pick and cancelling one are reads of the roster this socket already
  # holds — the row is the composition's own line and the operator list — so
  # neither re-checks the membership and neither is in `@write_events`.
  # `save_pick` is.
  def handle_event("open_pick", %{"line" => line_id}, socket) do
    case pick_line(socket, line_id) do
      # A line this version's roster does not hold is not a choice, so the click
      # is ignored rather than opening a row describing a line that is not there.
      nil ->
        {:noreply, socket}

      line ->
        {:noreply,
         socket
         |> put_pick(open_pick(socket, line))
         |> focus_pick_operator()}
    end
  end

  def handle_event("cancel_pick", _params, socket) do
    case socket.assigns.pick do
      nil ->
        {:noreply, socket}

      pick ->
        focus_id = pick_focus_id(socket, pick.line_number)

        {:noreply,
         socket
         |> put_pick(nil)
         |> push_event("focus_scoped_target", %{id: focus_id})}
    end
  end

  # The line is read off the open row rather than trusted as submitted: a
  # hand-built event naming another line cannot reach a writer with a line id
  # the page is not showing, and the row that is open is the row being saved.
  def handle_event("save_pick", %{"line" => line_id, "operator" => operator}, socket) do
    case socket.assigns.pick do
      %{line_id: ^line_id, line_number: number} ->
        save_pick(socket, line_id, number, operator)

      _no_pick ->
        {:noreply, socket}
    end
  end

  def handle_event("save_pick", _params, socket), do: {:noreply, socket}

  # Roster settings. Opening and validating are reads of state this socket
  # already holds — the loaded roster's own rules and its day types — so neither
  # re-checks the membership and neither is in `@write_events`. `save_settings`
  # is a write and is.
  #
  # The settings the form edits are `roster.rules`: the same three values the
  # composition already read for the grid, the count strip and the scope bar, so
  # the drawer cannot open on a different set of rules than the page is showing
  # (INV-15). They are *not* re-read through `get_roster_settings/2` here: that
  # would be a second answer to a question the composition has answered.
  def handle_event("open_settings", _params, socket) do
    {:noreply, open_settings(socket)}
  end

  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, :settings, nil)}
  end

  # Blur is the moment the page believes a number is finished, so the error for
  # it is drawn from the blur that left it and not before. The rules are the
  # writer's own changeset run with the `:validate` action, so the page invents
  # no validation of its own.
  def handle_event("validate_settings", %{"settings" => params} = payload, socket) do
    case socket.assigns.settings do
      nil ->
        {:noreply, socket}

      form_state ->
        changeset =
          form_state.base
          |> settings_changeset(params, :validate)
          |> only_touched_errors(form_state.touched |> touch(settings_target(payload["_target"])))

        {:noreply, put_settings(socket, form_state, changeset, form_state.failures)}
    end
  end

  def handle_event("validate_settings", _params, socket), do: {:noreply, socket}

  # The submit is the one moment every field is finished, so every error is drawn
  # and the first invalid control takes focus. A refused save keeps the drawer
  # open with what was typed: a refusal that closes the drawer reads as the page
  # having lost the planner's work.
  def handle_event("save_settings", %{"settings" => params}, socket) do
    case socket.assigns.settings do
      nil ->
        {:noreply, socket}

      form_state ->
        changeset = settings_changeset(form_state.base, params, :update)

        if changeset.valid? do
          write_settings(socket, form_state, params)
        else
          {:noreply,
           socket
           |> put_settings(form_state, changeset, settings_failures(changeset))
           |> push_event("focus_form_error", %{
             form_id: @settings_form_id,
             fallback_id: @settings_errors_id
           })}
        end
    end
  end

  def handle_event("save_settings", _params, socket), do: {:noreply, socket}

  # Any other event is ignored. This clause is last among the `handle_event`
  # clauses on purpose: a catch-all placed earlier would shadow the real
  # handlers above it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A base-week select is addressed as `["settings", "roster_day_types", "1"]`,
  # and the error the writer puts on it is on `:roster_day_types` — one field,
  # however many weekdays it names. Blurring any of the seven therefore counts
  # as touching that one field, or the message would vanish the moment a planner
  # picked a different day type, before they had read it.
  defp settings_target(target) when is_list(target) do
    if "roster_day_types" in target, do: ["roster_day_types"], else: target
  end

  defp settings_target(target), do: target

  # The write. Both arguments come from the socket, never from the submitted
  # params (domain rule 17): a submitted organization is not a thing this form
  # can say.
  #
  # On success the roster is re-read and the drawer closes, exactly as the Runs
  # crew-rules drawer does after its save: the rules feed every derived run and
  # the base week feeds every slot, so the scope bar, the count strip and the
  # grid all have to show the new values rather than the ones this socket
  # remembers. The toast is the prototype's sentence, and the base-week change
  # is already visible in the grid as "Base week changed" on the slots it
  # invalidates — that marking is the composition's, not this page's.
  defp write_settings(socket, form_state, params) do
    case Gtfs.update_roster_settings(AuditContext.from_assigns(socket.assigns), params) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> assign(:settings, nil)
         |> load_roster()
         |> put_toast("Roster settings saved. Every line was checked again.", :done)
         |> push_event("focus_scoped_target", %{id: "rosters-settings-button"})}

      # The role was revoked after the drawer opened. The drawer stays open with
      # the entries as they were typed, and the page's toast says why.
      {:error, :forbidden} ->
        {:noreply, editor_refusal(socket)}

      # The version went unpublished between the drawer opening and the save.
      # The writer refuses the write, so the drawer says why and keeps the
      # entries: the planner typed them and nothing about the version's state
      # makes them worth retyping.
      {:error, :not_found} ->
        {:noreply,
         put_settings(
           socket,
           form_state,
           settings_changeset(form_state.base, params, :update),
           []
         )
         |> put_settings_notice(@settings_not_found)}

      # A changeset error the client-side pass did not reach — a value the
      # domain casts differently, or a day type a calendar change has made
      # unusable. Its field errors are shown under their own inputs, the entries
      # are kept, and the writer's action is restored, because a form built from
      # a changeset with no action shows none of its errors.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_settings(
           form_state,
           Map.put(changeset, :action, :update),
           settings_failures(changeset)
         )
         |> push_event("focus_form_error", %{
           form_id: @settings_form_id,
           fallback_id: @settings_errors_id
         })}
    end
  end

  # The form opens on the roster this socket is showing, so the drawer's numbers
  # and selects are the ones the grid and the scope bar are already using. Every
  # other surface this page can be in is closed first, for the operators drawer's
  # reason: two drawers at once is two sets of pending input.
  defp open_settings(socket) do
    case socket.assigns.roster do
      nil ->
        socket

      roster ->
        form_state = %{base: roster.rules, touched: MapSet.new(), failures: []}

        socket
        |> assign(:slot, nil)
        |> assign(:add_to_line, nil)
        |> assign(:line, nil)
        |> assign(:pick, nil)
        |> assign(:delete_operator, nil)
        |> close_operators()
        |> put_settings(form_state, settings_changeset(roster.rules, %{}, :validate), [])
    end
  end

  defp put_settings(socket, form_state, changeset, failures) do
    assign(
      socket,
      :settings,
      Map.merge(form_state, %{form: to_form(changeset, as: :settings), failures: failures})
    )
  end

  defp put_settings_notice(socket, notice) do
    assign(socket, :settings, Map.put(socket.assigns.settings, :notice, notice))
  end

  # The writer's own changeset, run with the action that decides what is drawn.
  # `:validate` never writes and `:update` only reaches the writer when the same
  # changeset says it is valid, so there is one set of rules on the page and in
  # the write (domain rule 13).
  defp settings_changeset(base, params, action),
    do: Gtfs.change_roster_settings(base, params) |> Map.put(:action, action)

  # The submit's failures, one link per field, in field order. The base week is
  # one entry whatever it holds, because the writer reports one message at a time
  # and the sentence names the weekday to change.
  defp settings_failures(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} ->
      %{href: "##{settings_field_id(field)}", msg: "#{settings_label(field)}: #{message}"}
    end)
    |> Enum.sort_by(& &1.href)
  end

  defp settings_field_id(:min_rest_minutes), do: "rosters-settings-rest"
  defp settings_field_id(:weekly_hours_warn_above), do: "rosters-settings-warn"
  defp settings_field_id(:roster_day_types), do: "rosters-settings-base-week"
  defp settings_field_id(field), do: "settings_#{field}"

  defp settings_label(:min_rest_minutes), do: "Minimum rest"
  defp settings_label(:weekly_hours_warn_above), do: "Warn above weekly hours"
  defp settings_label(:roster_day_types), do: "Base week"
  defp settings_label(field), do: to_string(field)

  # The write. On success the roster is re-read and the row closes, so the
  # Operator column and the open-work count are the composition's own words and
  # not this page's memory of what it just did. On a refusal the row stays open
  # with the writer's own sentence and the select takes focus, because a refusal
  # that closes the row reads as the page having lost the planner's work.
  defp save_pick(socket, line_id, number, operator) do
    case Gtfs.assign_roster_operator(
           AuditContext.from_assigns(socket.assigns),
           line_id,
           Values.presence(operator)
         ) do
      {:ok, _result} ->
        # The roster is re-read first and the focus target read off the result:
        # a pick recorded under the Open filter takes the line off the grid, and
        # the control that opened the row went with it.
        saved_pick = socket |> clear_open_work() |> assign(:pick, nil) |> load_roster()
        focus_id = pick_focus_id(saved_pick, number)

        {:noreply,
         saved_pick
         |> put_toast(pick_sentence(saved_pick, number), :done)
         |> push_event("focus_scoped_target", %{id: focus_id})}

      {:error, {:operator_holds, other_line, name}} ->
        # The roster is re-read and the row rebuilt with the refusal already in
        # it, because the refusal is about a line that exists now and this
        # socket's copy of the roster does not: the operator who was just refused
        # is no longer on offer, and an offer that still showed them would invite
        # the same refusal again. The row is built once and streamed once — a
        # stream never redraws a row that is already on screen, so a refusal
        # assigned after the row was inserted would never be drawn.
        refused =
          socket
          |> clear_open_work()
          |> assign(:pick, nil)
          |> load_roster()
          |> reopen_pick(number, pick_conflict(name, other_line))

        {:noreply, focus_pick_operator(refused)}

      {:error, :forbidden} ->
        {:noreply, editor_refusal(socket)}

      {:error, :not_found} ->
        refuse_pick_not_found(socket, number)
    end
  end

  # A refusal that is not a conflict is a line that went, or an operator this
  # page never offered. A line that is still drawn keeps its row and the reason;
  # a line that is gone takes the row with it, because a row describing work that
  # is not there is a lie, and the page's own toast carries the fact.
  defp refuse_pick_not_found(socket, number) do
    socket = clear_open_work(socket) |> assign(:pick, nil) |> load_roster()

    case pick_line_number(socket, number) do
      nil ->
        {:noreply,
         socket
         |> put_toast(@line_gone, :refused)
         |> push_event("focus_scoped_target", %{id: lines_title_id()})}

      _line_still_there ->
        {:noreply,
         socket
         |> reopen_pick(number, @operator_not_offered)
         |> focus_pick_operator()}
    end
  end

  # A line another session recorded while this row was open. The writer's own
  # refusal names both halves — who holds what, and where — so the sentence does
  # too, and the select is focused because the next move is choosing again.
  defp pick_conflict(name, line_number) do
    "#{name} already holds line #{line_number}. Another session recorded that pick. " <>
      "Choose another operator."
  end

  # The row is rebuilt from the roster that was just re-read, so the offer after
  # a refusal is the one the page would make now rather than the one it made when
  # the pick was opened. The refusal is part of that build: the row is a stream
  # item, and a stream item is drawn once, so a refusal assigned after the row
  # was inserted would never be drawn.
  defp reopen_pick(socket, number, refusal) do
    case pick_line_number(socket, number) do
      nil -> socket
      line -> put_pick(socket, open_pick(socket, line, refusal))
    end
  end

  # The pick row is a row of the grid's stream, so every change to it re-streams
  # the grid: that is how the row appears under its line and how it goes away
  # again. `nil` closes the row.
  defp put_pick(socket, pick), do: socket |> assign(:pick, pick) |> stream_roster_lines()

  # The pick row's whole data, built when the event that opens it runs and never
  # inside `render/1`, for the slot drawer's reason. The line is the
  # composition's own, and the offer is `Operations.list_operators/1` — the
  # organization's single operator order — minus every operator who already
  # holds a line in this version, because one operator holds at most one line
  # here. The writer refuses on exactly that rule, so the offer on screen and
  # the refusal under the lock are one computation (domain rule 11, INV-15).
  defp open_pick(socket, line, refusal \\ nil) do
    %{
      line: line,
      line_id: line.id,
      line_number: line.line_number,
      operators: free_operators(socket),
      selected: line.operator && line.operator.id,
      refusal: refusal
    }
  end

  defp free_operators(socket) do
    holders =
      socket.assigns.roster.lines
      |> Enum.map(& &1.operator)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(& &1.id)

    socket.assigns.current_organization.id
    |> Operations.list_operators()
    |> Enum.reject(&MapSet.member?(holders, &1.id))
  end

  # What the pick did, in the words the grid draws it with: the operator is read
  # off the reloaded composition's own line rather than off what was submitted,
  # so the toast and the cell cannot describe different picks.
  defp pick_sentence(socket, number) do
    case pick_line_number(socket, number) do
      %{operator: %{display_name: name}} ->
        "Pick recorded: #{name} holds line #{number}."

      _cleared_or_gone ->
        "Line #{number} is open."
    end
  end

  # Where focus goes once the row is gone. It is the control that opened the row,
  # unless the row is no longer drawn — recording a pick under the Open filter
  # takes the line off the grid entirely, and its button went with it. The
  # section heading is the grid's own focus target for exactly that, the way the
  # delete's is.
  defp pick_focus_id(socket, number) do
    if pick_row_drawn?(socket, number), do: pick_button_id(number), else: lines_title_id()
  end

  defp pick_row_drawn?(%{assigns: %{roster: nil}}, _number), do: false

  defp pick_row_drawn?(socket, number) do
    filter = socket.assigns.filter

    Enum.any?(
      socket.assigns.roster.lines,
      &(&1.line_number == number and visible?(&1, filter))
    )
  end

  defp focus_pick_operator(socket),
    do: push_event(socket, "focus_scoped_target", %{id: "rosters-pick-operator"})

  defp pick_button_id(number), do: "rosters-record-pick-#{number}"

  defp lines_title_id, do: "rosters-lines-title"

  defp pick_line(%{assigns: %{roster: nil}}, _line_id), do: nil

  defp pick_line(socket, line_id),
    do: Enum.find(socket.assigns.roster.lines, &(&1.id == line_id))

  defp pick_line_number(%{assigns: %{roster: nil}}, _number), do: nil

  defp pick_line_number(socket, number),
    do: Enum.find(socket.assigns.roster.lines, &(&1.line_number == number))

  # ── The operators drawer ───────────────────────────────────────────────────
  #
  # The list is `Operations.list_operators/1` in that function's own order — the
  # single order every operator list in the app reads (domain rule 11, AC-4) — and
  # the lines map is this version's own lines, read off the composition the
  # socket already holds rather than re-derived (INV-15).
  defp load_operators(socket) do
    operators = Operations.list_operators(socket.assigns.current_organization.id)

    %{
      operators: operators,
      lines: operator_lines(socket.assigns.roster, operators)
    }
  end

  # The Line column is about *this version's* week, so an operator is mapped to
  # a line only when that line is in the roster on screen. Two lines cannot hold
  # one operator here (the pick writer refuses it), so the map cannot disagree
  # with itself.
  defp operator_lines(%{lines: lines}, operators) do
    known = MapSet.new(operators, & &1.id)

    for %{operator: %{id: operator_id}, line_number: number} <- lines,
        MapSet.member?(known, operator_id),
        into: %{},
        do: {operator_id, number}
  end

  defp operator_lines(_no_roster, _operators), do: %{}

  defp put_operators(socket, %{operators: operators} = list) do
    socket |> assign(:operators, list) |> assign(:operators_count, length(operators))
  end

  defp close_operators(socket) do
    socket
    |> discard_operator_upload()
    |> assign(:operators, nil)
    |> assign(:operator_form, nil)
    |> assign(:operator_import, nil)
  end

  defp drawn_operator(%{assigns: %{operators: %{operators: operators}}}, operator_id) do
    Enum.find(operators, &(to_string(&1.id) == to_string(operator_id)))
  end

  defp drawn_operator(_no_drawer, _operator_id), do: nil

  # The form opens on the operator's own values, so editing a name never asks
  # the editor to retype it. A new form opens on a blank `%Operator{}`: the
  # changeset is the writer's, and a blank one is what an empty form is.
  defp open_operator_form(socket, operator, params) do
    base = operator || %Operator{}

    form_state = %{
      base: base,
      editing_id: operator && operator.id,
      name: operator && operator.display_name,
      line_number: operator_line_number(socket, operator),
      touched: MapSet.new(),
      failures: []
    }

    socket
    |> close_operator_form()
    |> assign(:operator_form, form_state)
    |> put_operator_form(form_state, operator_changeset(base, params, :validate), [])
  end

  defp close_operator_form(socket), do: assign(socket, :operator_form, nil)

  # The drawer's whole form data, rebuilt by the event that changes it. The
  # line an operator holds is re-read from the roster on every open rather than
  # carried on the form, because a pick recorded elsewhere while the drawer was
  # open would otherwise name a line this form no longer describes.
  defp put_operator_form(socket, form_state, changeset, failures) do
    form_state =
      form_state
      |> Map.put(:form, to_form(changeset, as: :operator))
      |> Map.put(:failures, failures)

    assign(socket, :operator_form, form_state)
  end

  defp operator_line_number(_socket, nil), do: nil

  defp operator_line_number(%{assigns: %{operators: %{lines: lines}}}, operator),
    do: Map.get(lines, operator.id)

  # The writer's own changeset, run with the action that decides what is drawn.
  # `:validate` never writes and `:insert`/`:update` only reach the writer when
  # the same changeset says it is valid, so there is one set of rules on the page
  # and in the write (the "One owner for roster storage" criterion, domain rule
  # 13).
  #
  # A blank seniority reaches the changeset as `""`, which `cast/3` reads as an
  # absent value. It must not be dropped from the params first: on an edit, a
  # missing key leaves the stored number in place, and the form would put it back.
  defp operator_changeset(base, params, action),
    do: Operator.changeset(base, params) |> Map.put(:action, action)

  # A write with no form open is not a write, and neither is one whose operator
  # this socket no longer holds: the form carries the id it was opened for, and
  # the writer casts it inside the caller's organization, so a hand-built event
  # cannot reach another tenant's operator.
  defp writable_operator(socket, %{editing_id: id} = form_state)
       when not is_nil(id) do
    if drawn_operator(socket, id), do: form_state
  end

  defp writable_operator(_socket, %{editing_id: nil} = form_state), do: form_state

  defp writable_operator(_socket, _no_form), do: nil

  defp operator_action(%{editing_id: nil}), do: :insert
  defp operator_action(_editing), do: :update

  # The blur that leaves a field is the moment the page believes it is finished,
  # so the field is added to the touched set here and the error for it drawn
  # afterwards. `_target` is the form event's own field path, so the field that
  # was left is the one that becomes finished.
  defp touch(touched, nil), do: touched
  defp touch(touched, target) when is_list(target), do: touch(touched, List.last(target))
  defp touch(touched, field) when is_binary(field), do: MapSet.put(touched, to_string(field))

  defp touch(touched, _target), do: touched

  # Errors are drawn for a field only once that field has been blurred. The
  # changeset still carries them all — it is the writer's and it is not edited —
  # so only what the form shows is narrowed.
  defp only_touched_errors(changeset, touched) do
    %{changeset | errors: Enum.filter(changeset.errors, &(to_string(elem(&1, 0)) in touched))}
  end

  # The submit's failures, one link per field, in field order. The sentence is
  # the writer's own message with the field's label in front of it, which is what
  # makes a link and its target read as the same problem.
  defp operator_failures(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} ->
      %{href: "##{operator_field_id(field)}", msg: "#{label_for(field)}: #{message}"}
    end)
    |> Enum.sort_by(& &1.href)
  end

  # The input's own id. `to_form(changeset, as: :operator)` names the form
  # `operator`, so its fields are `operator_employee_id` and so on — the same ids
  # a summary link has to point at for the link to be the control it names.
  defp operator_field_id(field), do: "operator_#{field}"

  defp label_for(:employee_id), do: "Employee ID"
  defp label_for(:display_name), do: "Display name"
  defp label_for(:seniority_number), do: "Seniority number"
  defp label_for(field), do: to_string(field)

  # The write. Both writers take the organization and the acting user from the
  # socket, never from the submitted params (domain rule 17): a submitted
  # organization is not a thing this form can say. The actor is `%{id: …}`
  # because that is the only field `Operations` reads.
  defp write_operator(socket, form_state, params) do
    result =
      case form_state.editing_id do
        nil ->
          Operations.create_operator(
            socket.assigns.current_organization.id,
            operator_actor(socket),
            params
          )

        operator_id ->
          Operations.update_operator(
            socket.assigns.current_organization.id,
            operator_actor(socket),
            operator_id,
            params
          )
      end

    case result do
      {:ok, operator} ->
        # The list is re-read after the write, so the row on screen and the row
        # in the database are the same row and the order on screen is the
        # organization's order rather than this page's memory of what it just
        # did. Focus goes to the list heading because the form is gone and the
        # control that opened it may be too — a new operator is a row that was
        # not there when the editor last looked.
        {:noreply,
         socket
         |> close_operator_form()
         |> put_operators(load_operators(socket))
         |> put_toast(
           "#{operator.display_name} #{if form_state.editing_id, do: "saved", else: "added"}.",
           :done
         )
         |> push_event("focus_scoped_target", %{id: @operators_title_id})}

      {:error, %Ecto.Changeset{} = changeset} ->
        # A refused write — a duplicate employee ID names the operator who holds
        # it — keeps the form with what the editor typed, because a refusal that
        # closes the form reads as the page having lost their work. The refusal
        # is the writer's own sentence, and it is drawn for every field it
        # names: a refusal is not live validation, so nothing is held back
        # waiting for a blur. The writer's changeset carries no action, and a
        # form built from a changeset with no action shows none of its errors, so
        # the action the submit had is put back before it is drawn.
        {:noreply,
         socket
         |> put_operator_form(
           form_state,
           Map.put(changeset, :action, operator_action(form_state)),
           operator_failures(changeset)
         )
         |> touch_failed_fields(changeset)
         |> push_event("focus_form_error", %{
           form_id: @operator_form_id,
           fallback_id: @operator_form_error_id
         })}

      {:error, :forbidden} ->
        # The form stays open with what the editor typed.
        {:noreply, editor_refusal(socket)}

      {:error, :not_found} ->
        # The operator went while the form was open. A form for an operator that
        # is not there is a lie, so the form closes and the list is re-read; the
        # fact is the page's own toast because there is no field left to own it.
        {:noreply,
         socket
         |> close_operator_form()
         |> put_operators(load_operators(socket))
         |> put_toast("That operator is no longer on this organization's list.", :refused)}
    end
  end

  # The refusal is the writer's own sentence under the field it names. The form's
  # changesets already carry it, so this only marks the failed fields as
  # finished: a refusal must not be drawn for a field the editor never left, and
  # must be drawn for every field it did.
  defp touch_failed_fields(socket, changeset) do
    form_state = socket.assigns.operator_form

    assign(
      socket,
      :operator_form,
      %{form_state | touched: all_operator_fields(changeset)}
    )
  end

  defp all_operator_fields(changeset),
    do: MapSet.new(changeset.errors, fn {field, _error} -> to_string(field) end)

  defp operator_actor(socket), do: %{id: socket.assigns.current_user.id}

  defp operator_params(operator) do
    %{
      "employee_id" => operator.employee_id,
      "display_name" => operator.display_name,
      "seniority_number" => operator.seniority_number
    }
  end

  # The upload. A file that finished uploading is parsed and previewed at once,
  # so the drawer always shows the plan for the file the editor chose. A file
  # still on its way replaces the review on screen: whatever was reviewed before
  # it must not stay applicable while this one is sent.
  defp handle_operators_file_progress(:operators_file, entry, socket) do
    if entry.done? do
      {:noreply, review_operators_file(socket, entry)}
    else
      {:noreply, reset_operator_import(socket)}
    end
  end

  # An upload that completes after the editor left the import view is consumed
  # and dropped: reopening the drawer starts from no file rather than from a
  # review of a file nobody chose in this view.
  defp review_operators_file(%{assigns: %{operator_import: nil}} = socket, entry) do
    _ = consume_uploaded_entry(socket, entry, & &1)
    socket
  end

  defp review_operators_file(socket, entry) do
    file = entry.client_name
    organization_id = socket.assigns.current_organization.id

    case consume_uploaded_entry(socket, entry, fn uploaded ->
           {:ok, parse_operators_file(uploaded, file)}
         end) do
      {:ok, parsed} ->
        put_operator_import(socket, %{
          filename: file,
          parsed: parsed,
          preview: Operations.preview_operator_import(organization_id, parsed),
          parse_error: nil,
          stale?: false
        })

      {:error, message} ->
        put_operator_import(socket, %{
          filename: file,
          parsed: nil,
          preview: nil,
          parse_error: message,
          stale?: false
        })
    end
  end

  defp parse_operators_file(%{path: path}, file) do
    case File.read(path) do
      {:ok, content} -> Tods.parse(:operators, file, content)
      {:error, _reason} -> {:error, "#{file} could not be read."}
    end
  end

  # The write. Organization and acting user come from the socket, never from the
  # file: a file cannot say which organization it is for, and a submitted
  # organization is not a thing this page can be asked (domain rule 17). Only
  # the three mapped fields reach a row, and the skipped ones never reach a row
  # at all (`Operations.apply_operator_import/4`).
  defp apply_reviewed_operator_import(socket, parsed, preview) do
    organization_id = socket.assigns.current_organization.id

    case Operations.apply_operator_import(
           organization_id,
           operator_actor(socket),
           parsed,
           preview
         ) do
      {:ok, %{added: added, updated: updated}} ->
        # The list is re-read after the write, so the row on screen and the row
        # in the database are the same row; the drawer goes back to the list
        # because the import is finished and the list is what the editor came
        # for. The counts in the toast are the ones the review just showed.
        {:noreply,
         socket
         |> discard_operator_upload()
         |> assign(:operator_import, nil)
         |> put_operators(load_operators(socket))
         |> put_toast(import_notice(added, updated, preview.skipped), :done)
         |> push_event("focus_scoped_target", %{id: @operators_title_id})}

      {:error, {:preview_changed, fresh}} ->
        # Somebody else changed the organization's operators between the review
        # and the apply. The context recomputed the plan and wrote nothing, so
        # the fresh review replaces the old one in place — the editor sees what
        # the file would do *now* — and the message says why the counts moved.
        {:noreply,
         socket
         |> put_operator_import(%{preview: fresh, stale?: true})
         |> push_event("focus_scoped_target", %{id: @operator_import_error_id})}

      {:error, :forbidden} ->
        # The reviewed file stays in the drawer, so nothing the editor chose is
        # lost.
        {:noreply, editor_refusal(socket)}
    end
  end

  defp import_notice(added, updated, skipped) do
    "#{added} #{if added == 1, do: "operator", else: "operators"} added, #{updated} updated. #{length(skipped)} #{if length(skipped) == 1, do: "row was", else: "rows were"} skipped."
  end

  # A new file, a cancel, a fresh review and the start of the view all leave the
  # drawer with nothing to apply, and the opener id survives so the dialog can
  # still return focus to the control that opened the view.
  defp reset_operator_import(socket) do
    case socket.assigns.operator_import do
      nil -> socket
      state -> assign(socket, :operator_import, Map.merge(state, @empty_operator_import))
    end
  end

  defp put_operator_import(socket, changes) do
    state = socket.assigns.operator_import || Map.put(@empty_operator_import, :opener_id, nil)

    assign(socket, :operator_import, Map.merge(state, changes))
  end

  defp discard_operator_upload(socket) do
    Enum.reduce(socket.assigns.uploads.operators_file.entries, socket, fn entry, acc ->
      cancel_upload(acc, :operators_file, entry.ref)
    end)
  end

  defp delete_operator(socket, operator_id) do
    case Operations.delete_operator(
           socket.assigns.current_organization.id,
           operator_actor(socket),
           operator_id
         ) do
      {:ok, operator} ->
        socket =
          socket
          |> assign(:delete_operator, nil)
          |> close_operator_form()
          |> clear_open_work()
          |> load_roster()
          |> put_operators(load_operators(socket))

        {:noreply,
         socket
         |> put_toast("#{operator.display_name} deleted.", :done)
         |> push_event("focus_scoped_target", %{id: @operators_title_id})}

      {:error, :not_found} ->
        # The operator went while the confirmation was up. The form and the
        # confirmation both close, and the reason is the page's own toast because
        # there is no drawer left to own it.
        socket =
          socket
          |> assign(:delete_operator, nil)
          |> close_operator_form()
          |> clear_open_work()
          |> load_roster()
          |> put_operators(load_operators(socket))

        {:noreply, put_toast(socket, @operator_gone, :refused)}

      {:error, :forbidden} ->
        {:noreply, editor_refusal(socket)}
    end
  end

  defp delete_line(socket, line_id) do
    case Gtfs.delete_roster_line(AuditContext.from_assigns(socket.assigns), line_id) do
      {:ok, %{line_number: number, run_days: run_days}} ->
        socket =
          socket
          |> assign(:delete_line, nil)
          |> assign(:line, nil)
          |> clear_open_work()
          |> load_roster()

        {:noreply,
         socket
         |> put_toast(
           "Line #{number} deleted. Its #{RostersComponents.plural_run_days(run_days)} to open work.",
           :done
         )
         |> push_event("focus_scoped_target", %{id: "rosters-lines-title"})}

      {:error, :not_found} ->
        # The line went while the confirmation was up: another planner, or a
        # version that went unpublished. A drawer for a line that is not there
        # would be a lie, so both overlays close and the roster is re-read, and
        # the reason is the page's own toast because there is no card and no
        # drawer left to own it.
        socket =
          socket
          |> assign(:delete_line, nil)
          |> assign(:line, nil)
          |> clear_open_work()
          |> load_roster()

        {:noreply, put_toast(socket, @line_gone, :refused)}

      {:error, :forbidden} ->
        {:noreply, editor_refusal(socket)}
    end
  end

  defp create_line_for_add(socket, weekday, run_id) do
    case Gtfs.create_roster_line(AuditContext.from_assigns(socket.assigns)) do
      {:ok, line} -> add_run_to_new_line(socket, line, weekday, run_id)
      {:error, :forbidden} -> {:noreply, editor_refusal(socket)}
      {:error, :not_found} -> {:noreply, refuse_add_to_line(socket, :not_found)}
    end
  end

  defp add_run_to_new_line(socket, line, weekday, run_id) do
    case Gtfs.set_roster_slot(AuditContext.from_assigns(socket.assigns), line.id, weekday, run_id) do
      {:ok, result} ->
        {:noreply,
         socket
         |> close_add()
         |> saved(
           result.short_rests,
           "Line #{line.line_number} created with run #{run_id} on #{weekday_name(weekday)}."
         )}

      # The role was revoked between the two writes, so the empty line the first
      # one made is on the roster now and the drawer has nothing left to do.
      {:error, :forbidden} ->
        {:noreply,
         socket |> close_add() |> clear_open_work() |> load_roster() |> editor_refusal()}

      {:error, reason} ->
        # The line exists now, so the roster is re-read before the drawer is
        # rebuilt: the new empty line belongs in the list the planner is about
        # to choose from. The refusal is then the drawer's, over that roster.
        socket = clear_open_work(socket) |> load_roster()
        add = socket.assigns.add_to_line

        case open_add_to_line(socket, add.day_type_key, run_id, weekday) do
          {:ok, rebuilt} ->
            text =
              add_new_line_refusal(
                line.line_number,
                reason,
                add_refusal_context(rebuilt, line.line_number)
              )

            {:noreply, assign(socket, :add_to_line, %{rebuilt | refusal: text})}

          # The run is no longer open at all, so there is no drawer to say it in
          # and the page's own toast is what is left to carry the fact.
          :error ->
            {:noreply,
             put_toast(
               close_add(socket),
               add_new_line_refusal(
                 line.line_number,
                 reason,
                 add_refusal_context(add, line.line_number)
               ),
               :refused
             )}
        end
    end
  end

  defp add_new_line_refusal(number, reason, context) do
    "Line #{number} was created, but the run was not added to it. " <>
      refusal_words(reason, context)
  end

  defp refusal_words(:not_found, _context), do: @write_refused

  defp refusal_words(refusal, context),
    do: RostersComponents.refusal_text(refusal, context)

  defp close_add(socket), do: assign(socket, :add_to_line, nil)

  # The drawer's data for one run on one day. The run has to be one the
  # composition still holds open, on the day type the card named, and on a
  # weekday it is open on — so a stale card, a foreign day type or a weekday the
  # run was taken on is `:error` rather than a drawer describing work that is
  # not there.
  #
  # `weekday` `nil` means "the first day the run is open on", which is what a
  # click on the card should select.
  defp open_add_to_line(socket, day_type_key, run_id, weekday) do
    with roster when not is_nil(roster) <- socket.assigns.roster,
         group when not is_nil(group) <- add_group(roster, day_type_key),
         %{run_id: ^run_id} = run <- Enum.find(group.open_runs, &(&1.run_id == run_id)) do
      open_add_to_line_day(roster, group, run, weekday || List.first(run.open_weekdays))
    else
      _not_open_here -> :error
    end
  end

  defp open_add_to_line_day(roster, group, run, weekday) do
    if Enum.member?(run.open_weekdays, weekday) do
      lines = Candidates.lines_for_open_run(roster, run.run_id, weekday)

      {:ok,
       %{
         run: run.run,
         open_weekdays: run.open_weekdays,
         run_id: run.run_id,
         day_type_key: group.day_type.key,
         day_type_label: group.day_type.label,
         group_label: group.label,
         weekday: weekday,
         lines: lines,
         # The version's own rest rule, read in with the drawer so a refusal can
         # name the minimum without the component reaching for the roster.
         min_rest_minutes: roster.rules.min_rest_minutes,
         selected_line_id: first_line_id(lines),
         pending?: false,
         refusal: nil
       }}
    else
      :error
    end
  end

  defp add_group(roster, day_type_key) do
    Enum.find(roster.groups, &(&1.day_type.key == day_type_key))
  end

  defp first_line_id([%{line: line} | _rest]), do: line.id
  defp first_line_id([]), do: nil

  defp chosen_add_run(%{assigns: %{add_to_line: %{day_type_key: key, run_id: run_id}}}),
    do: %{day_type_key: key, run_id: run_id}

  defp chosen_add_run(_no_drawer), do: nil

  # A write with nothing chosen is not a write, and neither is one against a
  # drawer the socket no longer holds.
  defp writable_add(%{assigns: %{add_to_line: %{pending?: false} = add}}), do: add
  defp writable_add(_no_writable_add), do: nil

  # The number the confirmation names, read from the row the planner chose in
  # the drawer's own list rather than re-derived.
  defp add_line_number(socket, line_id) do
    case socket.assigns.add_to_line do
      %{lines: lines} ->
        Enum.find_value(lines, &(&1.line.id == line_id && &1.line.line_number))

      nil ->
        nil
    end
  end

  # A refusal keeps the drawer exactly as it was drawn and puts the writer's own
  # sentence where the planner is already looking. The list is not rebuilt: the
  # writer refused, so nothing this socket knows about changed — a run another
  # line took meanwhile is precisely why the write says so.
  defp refuse_add_to_line(socket, reason) do
    add = socket.assigns.add_to_line

    assign(clear_open_work(socket), :add_to_line, %{
      add
      | refusal:
          refusal_words(
            reason,
            add_refusal_context(add, add_line_number(socket, add.selected_line_id))
          )
    })
  end

  defp add_refusal_context(add, line_number) do
    %{
      run_id: add.run_id,
      weekday: add.weekday,
      line_number: line_number,
      min_rest_minutes: add.min_rest_minutes
    }
  end

  # What the create did, in the words the grid draws it with: the days it took,
  # and the line's days off read from the reloaded composition rather than
  # computed here (INV-15). A line the filter leaves off screen still says what
  # it is in the toast, because a confirmation nobody can find is not one.
  defp created_sentence(socket, %{id: id, line_number: number, weekdays: weekdays}, run_id) do
    built = Enum.find(socket.assigns.roster.lines, &(&1.id == id))

    days = Enum.map_join(weekdays, ", ", &weekday_name/1)

    case built do
      nil ->
        "Line #{number} created: run #{run_id}, #{days}."

      line ->
        "Line #{number} created: run #{run_id}, #{days}. Days off #{RostersComponents.days_off_text(line)}."
    end
  end

  # The new line's Monday drawer. `open_slot/4` is the one place that builds a
  # slot drawer, so the head's entry point and a grid cell produce the same
  # drawer from the same roster — and neither does so inside `render/1`.
  defp open_new_line_drawer(socket, line_id) do
    case open_slot(socket, line_id, 1, nil) do
      {:ok, slot} -> assign(socket, :slot, slot)
      :error -> socket
    end
  end

  # A refusal is one sentence, on the card it belongs to. The writer's own
  # answer is what is written out, so the reason on the card and the reason the
  # writer refused with cannot describe the same refusal differently.
  defp refuse_open_work(socket, run_id, reason) do
    text =
      case reason do
        # The version went unpublished between the roster read and the write.
        # The card is still on screen, so the reason goes on the card; the
        # sentence is the page's own "nothing happened", because a refusal that
        # is not `Candidates`\'s has no builder wording to give it.
        :not_found ->
          @write_refused

        refusal ->
          RostersComponents.refusal_text(refusal, open_work_context(socket, run_id))
      end

    socket
    |> clear_new_line()
    |> assign(:open_work_refusal, %{run_id: run_id, text: text})
  end

  defp open_work_context(socket, run_id) do
    %{
      run_id: run_id,
      weekday: nil,
      line_number: nil,
      min_rest_minutes: socket.assigns.roster.rules.min_rest_minutes
    }
  end

  # The highlight and the refusal are one change deep, and they are cleared
  # together because they are the same thing: what the last write did.
  defp clear_open_work(socket) do
    socket |> clear_new_line() |> assign(:open_work_refusal, nil)
  end

  defp clear_new_line(socket), do: assign(socket, :new_line_id, nil)

  # The weekday arrives from a `phx-value-weekday` attribute, so it is cast
  # rather than compared: a hand-built event naming "9" or "monday" is not a
  # weekday, and `in 1..7` would answer the wrong question about a string.
  defp slot_weekday(weekday) when weekday in 1..7, do: {:ok, weekday}

  defp slot_weekday(weekday) when is_binary(weekday) do
    case Integer.parse(weekday) do
      {day, ""} when day in 1..7 -> {:ok, day}
      _not_a_weekday -> :error
    end
  end

  defp slot_weekday(_weekday), do: :error

  # A write while another one is in flight, or one with nothing chosen, is not a
  # write. `run_id` is `nil` on a day with no candidates, where the Set actions
  # are not drawn at all.
  defp writable_slot(socket) do
    case socket.assigns.slot do
      %{pending?: false, run_id: run_id} = slot when not is_nil(run_id) -> slot
      _no_writable_slot -> nil
    end
  end

  # The roster re-read and the drawer close. `short_rests` is the writer's own
  # answer about the week the write leaves, and a manual per-day edit is allowed
  # to leave short rest where a builder never would, so the toast says so: the
  # grid carries the warning on the day, and the toast names it here.
  defp saved(socket, short_rests, text) do
    socket = socket |> assign(:slot, nil) |> clear_open_work() |> load_roster()

    if short_rests == [] do
      put_toast(socket, text, :done)
    else
      [first | _rest] = short_rests

      put_toast(
        socket,
        text <>
          " " <>
          rest_sentence(first, socket.assigns.roster.rules.min_rest_minutes),
        :refused
      )
    end
  end

  # A refusal keeps the drawer and puts the reason where the planner is already
  # looking. The sentence is `RostersComponents.refusal_text/2` over the same
  # refusal the writer returned, so the reason on screen and the reason the
  # writer gave are one string.
  defp refuse(socket, reason) do
    text =
      case reason do
        :not_found -> @write_refused
        refusal -> RostersComponents.refusal_text(refusal, refusal_context(socket))
      end

    %{line_id: line_id, weekday: weekday} = socket.assigns.slot
    {:ok, slot} = open_slot(socket, line_id, weekday, socket.assigns.slot.run_id)

    assign(clear_open_work(socket), :slot, %{slot | refusal: text})
  end

  defp refusal_context(socket) do
    slot = socket.assigns.slot
    line = Enum.find(socket.assigns.roster.lines, &(&1.id == slot.line_id))

    %{
      run_id: slot.run_id,
      weekday: slot.weekday,
      line_number: line && line.line_number,
      min_rest_minutes: socket.assigns.roster.rules.min_rest_minutes
    }
  end

  defp rest_sentence(short_rest, min_rest_minutes) do
    RostersComponents.short_rest_sentence(short_rest, min_rest_minutes)
  end

  defp weekday_name(weekday), do: Enum.at(@weekday_names, weekday - 1)

  # The group's own label, so the confirmation says the same "Mon–Fri" the
  # button it answers is named after.
  defp group_label(socket, weekday) do
    case Enum.find(socket.assigns.roster.groups, &(weekday in &1.weekdays)) do
      %{label: label} -> label
      _no_group -> weekday_name(weekday)
    end
  end

  # The drawer's data for one line and weekday: the composition's own line and
  # slot, `Rosters.Candidates`' candidates in its order, and its answer on
  # whether the group's action is available. A line this version's roster does
  # not hold, a weekday outside the week, and a run the drawer does not offer
  # are all `:error` rather than a drawer describing work that is not there.
  #
  # `run_id` `nil` means "the drawer opens on the day's own run, or the first
  # candidate" — what a click without a choice should select.
  defp open_slot(socket, line_id, weekday, run_id) do
    case socket.assigns.roster do
      nil ->
        :error

      roster ->
        with line when not is_nil(line) <- Enum.find(roster.lines, &(&1.id == line_id)),
             true <- weekday in 1..7 do
          view = Candidates.slot_candidates(roster, line_id, weekday)
          run_id = offered_run(view, run_id)

          {:ok,
           slot_data(line, weekday, run_id, view, group_state(roster, line_id, weekday, run_id))}
        else
          _unknown -> :error
        end
    end
  end

  defp slot_data(line, weekday, run_id, view, group_state) do
    %{
      line_id: line.id,
      weekday: weekday,
      line: line,
      current: view.current,
      group: view.group,
      candidates: view.candidates,
      run_id: run_id,
      group_state: group_state,
      pending?: false,
      refusal: nil
    }
  end

  # The run a drawer selects: the one named, when this day's candidates offer
  # it, and otherwise the day's own run or its first candidate.
  defp offered_run(view, run_id) do
    if run_id in Enum.map(view.candidates, & &1.run_id), do: run_id, else: default_run(view)
  end

  defp group_state(_roster, _line_id, _weekday, nil), do: nil

  defp group_state(roster, line_id, weekday, run_id) do
    Candidates.group_availability(roster, line_id, weekday, run_id)
  end

  # The day's current run leads, as the prototype leads it; otherwise the first
  # candidate in `Candidates`' own order.
  defp default_run(%{current: %{run_id: run_id}, candidates: candidates}) do
    if run_id in Enum.map(candidates, & &1.run_id), do: run_id
  end

  defp default_run(%{candidates: [candidate | _rest]}), do: candidate.run_id
  defp default_run(_view), do: nil

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(_dir), do: :asc

  # The page's own path, with the reader's whole view in it and no default in
  # it. Every parameter except the filter is read off the socket unless the
  # caller names it, so a sort never drops a filter the reader had picked and a
  # filter never drops the order; a value equal to its default is left out
  # rather than written, so the URL a reader copies for the default view is the
  # short one and the address bar does not fill with `?filter=all`.
  defp rosters_path(socket, filter, extra \\ %{}) do
    sort = to_string(Map.get(extra, :sort) || socket.assigns.sort)
    dir = to_string(Map.get(extra, :dir) || socket.assigns.dir)

    query =
      [
        {"filter", not_the_default(filter, "all")},
        {"sort", not_the_default(sort, "line")},
        {"dir", not_the_default(dir, "asc")}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Query.encode()

    base = "/gtfs/#{socket.assigns.current_gtfs_version.id}/rosters"
    if query == "", do: base, else: base <> "?" <> query
  end

  # The value unless it is the default, so the default never appears in the URL.
  # One rule for all three fields rather than three inline `if`s, so "the default
  # is omitted" is stated once.
  defp not_the_default(value, default), do: if(value == default, do: nil, else: value)

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
      width="wide"
    >
      <:sub_header>
        <.operations_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:rosters} />
      </:sub_header>

      <RostersComponents.toast toast={@toast} />

      <div id="rosters-page" class="ds-page" data-load-state={@load_state} phx-hook="FormErrorFocus">
        <RostersComponents.page_head state={@load_state} />
        <%!-- The prototype draws the scope bar in every state and hides the count strip and the
        messages when the version has no runs: there is nothing to count, nothing stale and
        nothing to pick, and the no-runs panel says all of that in one sentence. --%>
        <div
          :if={@roster}
          class="rounded-card border border-subtle bg-white"
        >
          <RostersComponents.scope_bar roster={@roster} operators_count={@operators_count} />
          <RostersComponents.count_strip
            :if={@load_state in [:ready, :unavailable]}
            roster={@roster}
            class="border-t border-subtle px-5 py-3"
          />
        </div>

        <RostersComponents.messages
          :if={@roster && @load_state in [:ready, :unavailable]}
          roster={@roster}
          operators_count={@operators_count}
          unavailable?={@load_state == :unavailable}
          version_id={@current_gtfs_version.id}
        />

        <RostersComponents.page_state
          :if={@load_state in [:loading, :no_runs]}
          kind={@load_state}
          version_id={@current_gtfs_version.id}
        />

        <%!-- First use is the version that has runs and no lines. The no-runs state is a
        different fact with a different next move, and it has already said it. --%>
        <RostersComponents.no_lines :if={
          @roster && @load_state == :ready && @roster.summary.lines == 0
        } />

        <%!-- The lines section's own heading, whether the section below it is the
        grid or the first-use panel. It is kept in the document outside the grid
        card for focus as much as for the name: deleting a line takes its row and
        its link with it, and deleting the last line takes the grid card too, so
        the page hands focus here rather than dropping a reader at the top of the
        document. --%>
        <h2
          :if={@roster && @load_state in [:ready, :unavailable]}
          id="rosters-lines-title"
          class="sr-only"
          tabindex="-1"
        >
          Roster lines
        </h2>

        <%!-- The grid, below the page's own figures. It is drawn only where there are
        lines to draw: with no runs the no-runs panel has already said so, and with runs
        and no lines the first-use panel has. --%>
        <div
          :if={@roster && @load_state in [:ready, :unavailable] && @roster.summary.lines > 0}
          class="rounded-card border border-subtle bg-white"
        >
          <RostersComponents.filter_row
            roster={@roster}
            filter={@filter}
            shown={@shown_count}
            locked?={@load_state == :unavailable}
          />
          <RostersComponents.grid
            roster={@roster}
            rows={@streams.roster_lines}
            shown={@shown_count}
            sort={@sort}
            dir={@dir}
            locked?={@load_state == :unavailable}
            paused_reason={if @load_state == :unavailable, do: paused_reason()}
            new_line_id={@new_line_id}
            pick={@pick}
          />
        </div>

        <%!-- Open work is below the grid and drawn whenever the roster is, including with no lines at
        all: the first-use panel points here, and a week with runs but no lines has nothing above it
        to offer. It is not drawn in the loading or no-runs states, which have said all they have to
        say and have nothing open to list. --%>
        <RostersComponents.open_work
          :if={@roster && @load_state in [:ready, :unavailable]}
          roster={@roster}
          locked?={@load_state == :unavailable}
          refusal={@open_work_refusal}
        />

        <%!-- The export section is below everything that can change what the file
        would carry, and it is drawn whenever the roster is: what the export says
        is a fact about the whole version, not about one line. The loading and
        no-runs states have nothing to describe there and have said why. --%>
        <RostersComponents.export_section
          :if={@roster && @assignments && @load_state in [:ready, :unavailable]}
          assignments={@assignments}
          version_id={@current_gtfs_version.id}
        />

        <%!-- The operators drawer is inside the page region rather than beside it,
        the way `FlexLive`'s create drawer is. The design system scopes
        `.form-error-summary` under `.ds-page`, so a drawer's own refused submit
        is styled by the same rules as the page's only because the drawer is
        inside that region. --%>
        <RosterOperatorsComponents.operators_drawer
          :if={@operators && is_nil(@operator_form) && is_nil(@operator_import)}
          open
          operators={@operators.operators}
          lines={@operators.lines}
          on_close="close_operators"
        />

        <RosterOperatorsComponents.operator_import
          :if={@operator_import}
          open
          import_state={@operator_import}
          upload={@uploads.operators_file}
        />

        <RostersComponents.settings_drawer
          :if={@settings}
          open
          form={@settings.form}
          day_types={@day_types}
          base_week={@roster.base_week}
          failures={@settings.failures}
          notice={@settings[:notice]}
        />

        <RosterOperatorsComponents.operator_form
          :if={@operator_form}
          open
          form={@operator_form.form}
          editing={not is_nil(@operator_form.editing_id)}
          name={@operator_form.name}
          line_number={@operator_form.line_number}
          failures={@operator_form.failures}
          operator_id={@operator_form.editing_id}
        />
      </div>

      <RosterOperatorsComponents.delete_operator_confirm
        :if={@delete_operator}
        open
        name={@delete_operator.name}
        holdings={@delete_operator.holdings}
        version_id={@current_gtfs_version.id}
      />

      <RostersComponents.slot_drawer
        :if={@slot}
        open
        line={@slot.line}
        weekday={@slot.weekday}
        current={@slot.current}
        group={@slot.group}
        candidates={@slot.candidates}
        selected_run_id={@slot.run_id}
        group_state={@slot.group_state}
        pending?={@slot.pending?}
        refusal={@slot.refusal}
        min_rest_minutes={@roster.rules.min_rest_minutes}
      />

      <RostersComponents.add_to_line_drawer
        :if={@add_to_line}
        open
        run={@add_to_line.run}
        open_weekdays={@add_to_line.open_weekdays}
        weekday={@add_to_line.weekday}
        lines={@add_to_line.lines}
        selected_line_id={@add_to_line.selected_line_id}
        day_type_label={@add_to_line.day_type_label}
        group_label={@add_to_line.group_label}
        pending?={@add_to_line.pending?}
        refusal={@add_to_line.refusal}
        min_rest_minutes={@add_to_line.min_rest_minutes}
      />

      <RostersComponents.line_drawer
        :if={@line}
        open
        line={@line}
        locked?={@load_state == :unavailable}
        on_close="close_line"
      />

      <RostersComponents.delete_line_confirm
        :if={@delete_line}
        open
        line_number={@delete_line.line_number}
        run_days={@delete_line.run_days}
        picked?={@delete_line.picked?}
      />
    </Layouts.app>
    """
  end
end
