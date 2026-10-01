defmodule GtfsPlannerWeb.Gtfs.RostersLive do
  @moduledoc """
  LiveView for Operations › Rosters.

  Rosters is the version's weekly lines: one operator's week of runs, repeated
  through the service period. This step owns the page shell and the states the
  page can be in before it has any lines — the head, the loading skeleton and the
  version that has no runs to build from. The grid, the open work, the pick row
  and the export section arrive with the steps that own them.

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
  write rather than trusting the mount-time snapshot. `RunsLive` asks the same
  question the same way. The list starts with `add_line` and grows with the
  steps that add writes; a write that is not in it is not a write, which is why
  the list is the whole of the page's write surface rather than a per-handler
  guard nobody can enumerate.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Rosters.Candidates
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.EnsureRole
  alias GtfsPlannerWeb.Gtfs.RostersComponents
  alias Plug.Conn.Query

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The events that write. Mount checks the editor role once; these re-read the
  # membership before each write. `add_line` and `create_line_from_run` are step
  # 30's; they were named here from the start so the head's control and the guard
  # that covers it were introduced together.
  #
  # The slot drawer's three actions are writes and are listed with it. Opening
  # the drawer and choosing a candidate are reads of the roster already on the
  # socket, so they re-check no membership.
  @write_events ~w(
    add_line
    create_line_from_run
    set_day
    set_group
    clear_day
    add_to_line
    add_to_new_line
  )

  # A role revoked while the page is open is not an error the reader caused and
  # is not a validation problem, so it is a refusal said once, in the page's own
  # toast rather than in a field.
  @editor_access_lost "You no longer have editor access to this organization."

  # The write the editor guard refused, so the drawer's own refusal is the one
  # sentence the reader is told rather than a silent nothing.
  @write_refused "Nothing was saved."

  # The full weekday name. The grid's own module has the same list for the same
  # reason: the confirmation toast names the day a planner just changed.
  @weekday_names ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  # The version went unpublished between the session hook and this read. The
  # reader has no roster to look at, and the hook's own answer is the one to give.
  @version_not_found "GTFS version not found"

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
     |> assign(:operators_count, 0)
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
     |> stream(:roster_lines, [], dom_id: &roster_line_dom_id/1)
     |> attach_hook(:editor_access, :handle_event, &require_editor/3)}
  end

  # The row's DOM id is its line number, not the line's id: a row is addressed
  # by where it sits in the week, and the line number is what the grid shows.
  defp roster_line_dom_id(line), do: "rosters-line-#{line.line_number}"

  defp require_editor(event, _params, socket) when event in @write_events do
    if editor_access?(socket) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_toast(@editor_access_lost, :refused)
       |> put_flash(:error, @editor_access_lost)}
    end
  end

  defp require_editor(_event, _params, socket), do: {:cont, socket}

  # The membership read lives in `EnsureRole.editor_member?/2` so this page and
  # Runs ask the same question the same way.
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
        # The organization's operator list is not part of the roster
        # composition (a line's own operator is), so this count is the one
        # figure the scope bar needs that the composition does not answer.
        |> assign(:operators_count, length(Operations.list_operators(organization.id)))
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
    %{roster: roster, filter: filter, sort: sort, dir: dir} = socket.assigns
    lines = roster.lines |> Enum.filter(&visible?(&1, filter)) |> sorted(sort, dir)

    # The count is carried rather than read back off the stream: a `LiveStream`
    # is not enumerable, and the filter row and the empty row both need to know
    # whether anything was left.
    socket
    |> assign(:shown_count, length(lines))
    |> stream(:roster_lines, lines, reset: true)
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
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
             line_id,
             weekday,
             run_id
           ) do
      {:noreply,
       saved(socket, result.short_rests, "Set #{weekday_name(weekday)} to run #{run_id}.")}
    else
      {:error, reason} -> {:noreply, refuse(socket, reason)}
      _no_slot -> {:noreply, socket}
    end
  end

  def handle_event("set_group", _params, socket) do
    with %{line_id: line_id, weekday: weekday, run_id: run_id} <- writable_slot(socket),
         {:ok, _result} <-
           Gtfs.set_roster_weekday_group(
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
             line_id,
             weekday,
             run_id
           ) do
      {:noreply, saved(socket, [], "Set #{group_label(socket, weekday)} to run #{run_id}.")}
    else
      {:error, reason} -> {:noreply, refuse(socket, reason)}
      _no_slot -> {:noreply, socket}
    end
  end

  def handle_event("clear_day", _params, socket) do
    with %{line_id: line_id, weekday: weekday} <- writable_slot(socket),
         {:ok, _result} <-
           Gtfs.clear_roster_slot(
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
             line_id,
             weekday
           ) do
      {:noreply, saved(socket, [], "Cleared #{weekday_name(weekday)}.")}
    else
      {:error, reason} -> {:noreply, refuse(socket, reason)}
      _no_slot -> {:noreply, socket}
    end
  end

  # ── Open work ──────────────────────────────────────────────────────────────
  #
  # Two writes live here, and both create a line through the real writer:
  # `Gtfs.create_roster_line/2` for the head's "Add line", and
  # `Gtfs.create_roster_line_from_run/4` for a card's "Create Mon–Fri line".
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
    case Gtfs.create_roster_line(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id
         ) do
      {:ok, line} ->
        socket = socket |> clear_open_work() |> assign(:new_line_id, line.id) |> load_roster()

        {:noreply,
         socket
         |> open_new_line_drawer(line.id)
         |> put_toast("Line #{line.line_number} added.", :done)}

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
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           day_type_key,
           run_id
         ) do
      {:ok, line} ->
        socket = socket |> clear_open_work() |> assign(:new_line_id, line.id) |> load_roster()

        {:noreply, put_toast(socket, created_sentence(socket, line, run_id), :done)}

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
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
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
      {:error, reason} -> {:noreply, refuse_add_to_line(socket, reason)}
      _nothing_to_add -> {:noreply, socket}
    end
  end

  # "Create new line" is two writes, because the spec asks for a line holding
  # this run on this day rather than for a line and a later set. The first write
  # is `create_roster_line/2` and the second is the same `set_roster_slot/5` the
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

  # Any other event is ignored. This clause is last among the `handle_event`
  # clauses on purpose: a catch-all placed earlier would shadow the real
  # handlers above it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp create_line_for_add(socket, weekday, run_id) do
    case Gtfs.create_roster_line(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id
         ) do
      {:ok, line} -> add_run_to_new_line(socket, line, weekday, run_id)
      {:error, :not_found} -> {:noreply, refuse_add_to_line(socket, :not_found)}
    end
  end

  defp add_run_to_new_line(socket, line, weekday, run_id) do
    case Gtfs.set_roster_slot(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           line.id,
           weekday,
           run_id
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> close_add()
         |> saved(
           result.short_rests,
           "Line #{line.line_number} created with run #{run_id} on #{weekday_name(weekday)}."
         )}

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

      <div id="rosters-page" class="ds-page" data-load-state={@load_state}>
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
      </div>

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
    </Layouts.app>
    """
  end
end
