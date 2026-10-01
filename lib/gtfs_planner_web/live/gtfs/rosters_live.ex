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
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.EnsureRole
  alias GtfsPlannerWeb.Gtfs.RostersComponents
  alias Plug.Conn.Query

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The events that write. Mount checks the editor role once; these re-read the
  # membership before each write. Step 30 gives `add_line` its write; it is
  # named here from the start so the head's control and the guard that covers it
  # are introduced together.
  @write_events ~w(add_line)

  # A role revoked while the page is open is not an error the reader caused and
  # is not a validation problem, so it is a refusal said once, in the page's own
  # toast rather than in a field.
  @editor_access_lost "You no longer have editor access to this organization."

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

  # Any other event is ignored. This clause is last among the `handle_event`
  # clauses on purpose: a catch-all placed earlier would shadow the real
  # handlers above it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
