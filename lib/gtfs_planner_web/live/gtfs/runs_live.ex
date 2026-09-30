defmodule GtfsPlannerWeb.Gtfs.RunsLive do
  @moduledoc """
  The Runs page: one day type's runs, and the states the page can be in before
  it has any.

  This step builds the shell only — the head, the day-type scope bar and the
  load states. Later steps fill the plan card. The read is `Gtfs.load_runs/3`
  from step 12, called through the catalog read adapter like every other page
  read, so a stubbed adapter is enough to drive the failure state.

  ## Why the load is not in `mount/3`

  `BlocksLive` has one rule worth copying: **load only once connected**. A
  disconnected render is the static HTML a browser gets before the socket opens,
  and it must not be a version of the page that has already read the database —
  it is the same HTML the connected render will replace, and reading twice would
  make the first paint and the second disagree whenever the world moves between
  them. So the first render is the `:loading` skeleton, and `handle_params/3`
  loads on the connected pass.

  ## The day type comes from the URL, and the URL is the only source of it

  `?day=` is read in `handle_params/3` and nowhere else. There is no separate
  "selected day type" assign that a second code path could set, so the address
  bar and the page can never disagree — which matters more here than usual,
  because a run is scoped to its day type and `Runs.count_runs_for_trips/3` from
  step 19 counts `(day_type_key, run_id)` pairs. A page that showed one day type
  while the URL named another would report counts for a day it is not showing.

  ## `:unavailable` keeps what is on screen

  A read that fails is not a state the page moves into; it is a failure to move
  out of the state it is in. The runs already loaded stay rendered, the callout
  appears above them, and retry re-runs the same read against the same URL. The
  alternative — blanking the page — would destroy work the reader can still read
  and cannot get back, in exchange for a message they could have been given
  without the loss.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlannerWeb.Gtfs.RunsComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Runs")
     # Nothing is loaded yet. `:loading` is the honest first state and the one
     # the disconnected render shows, so the static HTML and the connected HTML
     # agree.
     |> assign(:load_state, :loading)
     |> assign(:runs_day, nil)
     |> assign(:day_types, [])
     |> assign(:day, nil)
     |> assign(:loaded_day_key, nil)
     # The summary drawer is closed and has never loaded its shares, so the
     # drawer cannot appear on a page whose day type has not loaded.
     |> assign(:drawer, nil)
     |> assign(:shares_state, :loading)
     |> assign(:shares, [])
     # The duty chart's state. `sort`/`dir`/`scale` are read from the URL and
     # nowhere else, for the same reason `?day=` is: a chart whose order or zoom
     # lives in an assign a second code path could set can disagree with its own
     # address bar, and a back button that does not restore the order the reader
     # had is a page that cannot be shared.
     |> assign(:sort, :sign_on)
     |> assign(:dir, :asc)
     |> assign(:scale, :day)
     |> assign(:view, :timeline)
     # The toast and its undo are EVENT state, not URL state, so they start here
     # rather than in `handle_params/3` beside `?day=` and `?panel=`. Starting them
     # empty is also what makes `toast/1` render NOTHING on first paint: a
     # `role="status"` region present with no text announces nothing and still
     # occupies the fixed box at the foot of the viewport.
     |> assign(:run, nil)
     |> assign(:toast, nil)
     |> assign(:undo, nil)
     |> assign(:rename_form, to_form(%{"run_id" => ""}, as: :run))
     |> assign(:rename_errors, [])
     |> assign(:move_form, to_form(%{"to" => ""}, as: :move))
     |> assign(:split_form, to_form(%{"gap" => "", "to" => ""}, as: :split))
     |> assign(:move_runs, [])
     |> assign(:piece_windows, %{})
     |> assign(:problems_open, false)
     |> assign(:next_run_id, "1")
     |> assign(:run_axis, nil)
     |> assign(:run_routes, %{})
     |> stream(:run_rows, [], dom_id: &run_dom_id/1)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    day = blank_to_nil(params["day"])
    sort = sort_key(params["sort"])
    dir = sort_dir(params["dir"])

    # A sort is a re-order of rows that are ALREADY loaded, so it must not
    # re-read the day: `ensure_day_loaded/1` would see its own guard and return
    # the socket untouched, and the rows would keep the order they had. So the
    # re-stream is asked for explicitly, here, where the change is known.
    resort? = socket.assigns.sort != sort or socket.assigns.dir != dir
    view = view_value(params["view"])
    # A VIEW change moves the same stream into a different `phx-update="stream"`
    # container — `#runs-timeline-body` and `#runs-list-body` are different
    # elements — so the rows have to be re-put, for the same reason a sort
    # re-streams. Without this, switching to the list and back renders an empty
    # one: the sort survives in the URL while the rows do not survive in the DOM.
    view_changed? = socket.assigns.view != view

    socket =
      socket
      |> assign(:day, day)
      |> assign(:sort, sort)
      |> assign(:dir, dir)
      |> assign(:scale, scale_value(params["scale"]))
      |> assign(:view, view)
      |> assign(:panel, panel_value(params["panel"]))
      |> assign(:run, blank_to_nil(params["run"]))
      |> ensure_day_loaded()

    socket =
      if (resort? or view_changed?) and is_map(socket.assigns.runs_day),
        do: stream_run_rows(socket),
        else: socket

    {:noreply, sync_run_drawer(socket)}
  end

  # **The URL opens the drawer, not just the button.** `?run=1001` has to be the
  # same page as pressing the Run button, or the link is a page that renders
  # without its drawer: a colleague opening the link sees the chart and not the
  # run, and the address bar says `run=1001` while the screen disagrees.
  #
  # It runs AFTER `ensure_day_loaded/1` because it looks the run up in the loaded
  # day — before the load, no run is findable and every drawer would be closed.
  # A `run` naming nothing is dropped rather than left in the path: a parameter
  # the page cannot honour is a parameter the next patch would carry forward.
  defp sync_run_drawer(socket) do
    case {socket.assigns.run, find_run(socket.assigns.runs_day, socket.assigns.run)} do
      {nil, _} ->
        assign(socket, :drawer, nil)

      {_run, nil} ->
        socket |> assign(:run, nil) |> assign(:drawer, nil)

      {run_id, _run} ->
        socket
        |> assign(:drawer, {:run, run_id})
        |> reset_rename_form()
        |> sync_run_context()
    end
  end

  # The sort keys this chart owns. A key the chart does not have is refused
  # rather than passed through, because `sort_by/2` would raise on an unknown
  # atom and a reader who edits the URL should get the default order, not a
  # crash.
  @sort_keys %{
    "id" => :id,
    "type" => :type,
    "sign_on" => :sign_on,
    "sign_off" => :sign_off,
    "spread" => :spread,
    "paid" => :paid,
    "status" => :status
  }

  defp sort_key(nil), do: :sign_on
  defp sort_key(key) when is_binary(key), do: Map.get(@sort_keys, key, :sign_on)
  defp sort_key(key) when is_atom(key) and not is_nil(key), do: sort_key(Atom.to_string(key))
  defp sort_key(_key), do: :sign_on

  defp sort_dir("desc"), do: :desc
  defp sort_dir(_dir), do: :asc

  defp scale_value("zoom"), do: :zoom
  defp scale_value(_scale), do: :day

  # The Timeline | List control is a URL param and nothing else, for the reason
  # `?day=` is: a view a reader cannot share, bookmark or return to with the back
  # button is not really the reader's. An unknown value is the timeline, so a
  # stale or hand-edited link lands on the page rather than on an error.
  defp view_value("list"), do: :list
  defp view_value(_view), do: :timeline

  # The Runs | Uncovered work tabs are a URL param for the reason `?day=` is: a
  # panel a reader cannot link to is a panel they have to find again. An unknown
  # value is the Runs panel, so a stale link lands on a page rather than an error.
  defp panel_value("uncovered"), do: :uncovered
  defp panel_value(_panel), do: :runs

  @count_tile_keys ~w(runs straight_share paid_hours on_vehicles longest_spread uncovered)

  @impl true
  def handle_event("select_day", %{"day" => day}, socket) do
    {:noreply, push_patch(socket, to: runs_path(socket, blank_to_nil(day)))}
  end

  def handle_event("retry", _params, socket) do
    # The reload is a real read, not a re-render: the point of retry is to find
    # out whether the database has come back. Clearing the loaded key through
    # `assign/3` is what makes `ensure_day_loaded/1` re-read rather than see its
    # own guard and return the socket untouched.
    {:noreply, socket |> assign(:loaded_day_key, nil) |> ensure_day_loaded()}
  end

  # Sorting the same key again reverses it; any other key starts ascending,
  # which is `BlocksLive`'s rule and the one a reader has already met. `sort` and
  # `dir` go into the URL rather than into an assign, so the order is shareable
  # and the back button restores it.
  def handle_event("sort", %{"key" => key}, socket) do
    if Map.has_key?(@sort_keys, key) do
      sort = Map.fetch!(@sort_keys, key)
      dir = if socket.assigns.sort == sort, do: toggle_dir(socket.assigns.dir), else: :asc

      {:noreply,
       push_patch(socket, to: runs_path(socket, socket.assigns.day, %{sort: key, dir: dir}))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_scale", %{"scale" => "zoom"}, socket) do
    {:noreply, push_patch(socket, to: runs_path(socket, socket.assigns.day, %{scale: "zoom"}))}
  end

  def handle_event("set_scale", %{"scale" => "day"}, socket) do
    {:noreply, push_patch(socket, to: runs_path(socket, socket.assigns.day, %{scale: "day"}))}
  end

  def handle_event("set_scale", _params, socket), do: {:noreply, socket}

  def handle_event("set_view", %{"view" => "list"}, socket) do
    {:noreply, push_patch(socket, to: runs_path(socket, socket.assigns.day, %{view: "list"}))}
  end

  def handle_event("set_view", %{"view" => "timeline"}, socket) do
    {:noreply, push_patch(socket, to: runs_path(socket, socket.assigns.day, %{view: "timeline"}))}
  end

  def handle_event("set_view", _params, socket), do: {:noreply, socket}

  def handle_event("set_panel", %{"panel" => "uncovered"}, socket) do
    {:noreply,
     push_patch(socket, to: runs_path(socket, socket.assigns.day, %{panel: "uncovered"}))}
  end

  def handle_event("set_panel", %{"panel" => "runs"}, socket) do
    {:noreply, push_patch(socket, to: runs_path(socket, socket.assigns.day, %{panel: "runs"}))}
  end

  def handle_event("set_panel", _params, socket), do: {:noreply, socket}

  # Create a run from one uncovered segment.
  #
  # **The segment is re-read from the loaded day, not taken from the button.**
  # The button names a block and a span; those three values FIND the segment in
  # `@runs_day.derived.uncovered`, and the moves are built from the trips that
  # segment actually has. Passing the button's own trip list would let a stale or
  # tampered `phx-value` write runs over trips nobody clicked — and the optimistic
  # check would not catch it, because the check asks whether each trip is still
  # unassigned, and a trip the page never showed is exactly the kind that is.
  #
  # Every move is `from: nil, to: :new`, and `apply_run_moves/4` resolves every
  # `:new` in one call to the SAME run: an operator covering three trips means one
  # run over them, not three runs of one trip each.
  def handle_event("create_run", params, socket) do
    case find_uncovered(socket.assigns.runs_day, params) do
      nil ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast(
           "That block is no longer uncovered. Reload to see the latest runs.",
           :refused
         )}

      segment ->
        moves = Enum.map(segment.trips, fn trip -> %{trip_id: trip.id, from: nil, to: :new} end)

        {:noreply,
         apply_moves(
           socket,
           moves,
           &created_text/1,
           "These trips changed since the page loaded. Reload to see the latest runs."
         )}
    end
  end

  # Undo the last move set, through the SAME call with the moves reversed.
  #
  # It is the same function and the same optimistic check by design: undo is not a
  # privileged path that trusts the page, it is an ordinary move set that happens
  # to run backwards. So a colleague who moved one of those trips in the meantime
  # refuses the undo rather than reverting their work — which is the card's third
  # case, and is why the refusal names what changed.
  def handle_event("undo", _params, socket) do
    case socket.assigns.undo do
      nil ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast("There is nothing to undo.", :refused)}

      %{moves: moves} ->
        # The undo assign is CLEARED whatever the write did.
        # `apply_run_moves/4` hands back the moves it just made, so a success that
        # re-armed the button would make Undo repeatable — and a second press
        # would apply the same reversal again, which is a re-APPLY wearing the
        # name of an undo. There is no stack: one edit, one Undo, then nothing
        # left to undo.
        {:noreply,
         socket
         |> apply_moves(
           moves,
           fn _id -> "Undone." end,
           "Can't undo: these runs changed since."
         )
         |> put_undo(nil)}
    end
  end

  def handle_event("dismiss_toast", _params, socket) do
    {:noreply, socket |> put_undo(nil) |> put_toast(nil)}
  end

  # Every strip tile opens the same drawer, and the pressed tile is the one the
  # reader pressed. The prototype sends each tile its own `data-act`; only the
  # summary drawer exists at this step, so all six open it — but the tile that
  # was clicked stays `aria-pressed`, because a control that shows nothing
  # pressed after the press is a control the reader cannot tell apart from one
  # that did nothing.
  #
  # `CoreComponents.count_strip/1` documents that a focusable `aria-disabled`
  # button can still dispatch, so the handler rejects an unknown key rather than
  # trusting it — a key this component does not own would mark a tile pressed
  # that does not exist.
  def handle_event("open_drawer", %{"key" => key}, socket) do
    # `is_map/1` rather than a truthiness check: `runs_day` is a map or `nil`,
    # and `and` refuses a non-boolean left side rather than treating a map as
    # true, which is the safer of the two surprises to get right.
    if is_map(socket.assigns.runs_day) and key in @count_tile_keys do
      {:noreply, socket |> assign(:drawer, {:summary, key}) |> start_shares_load()}
    else
      # No day type is loaded, or the key is not one of this strip's. The strip
      # is not rendered without a loaded day, so the first case is unreachable
      # from the page — and a no-op is still better than a drawer of zeros.
      {:noreply, socket}
    end
  end

  # The problems drawer, and the orphan removal inside it.
  #
  # The drawer is NOT URL state. Every other panel on this page is, because each
  # of them is a different LENS on the same day; the problems drawer is a reading
  # of what the other three already show, and adding `?problems=` would give the
  # page a fourth address for a thing the reader can reach from the count strip
  # in one click.
  def handle_event("open_problems", _params, socket) do
    # Opening the problems drawer closes the run drawer: two drawers at once
    # would stack, and the problems list is the way to REACH a run rather than
    # a place to read one.
    {:noreply, assign(socket, :problems_open, true)}
  end

  def handle_event("close_problems", _params, socket) do
    {:noreply, assign(socket, :problems_open, false)}
  end

  # Remove run assignments whose trips are no longer in this day type.
  #
  # These rows are already unusable: `Runs.load_runs/3` EXCLUDES them from every
  # run it derives, so they are on no chart, in no pay table and in no export.
  # They are what is left after a service group is removed. The drawer says how
  # many it will delete before the reader presses, and the count is the domain's
  # own, not a count taken from the list.
  def handle_event("remove_orphans", _params, socket) do
    %{day: day, current_organization: organization, current_gtfs_version: version} =
      socket.assigns

    case Gtfs.remove_run_orphans(organization.id, version.id, day) do
      # A COUNT, not `:ok`: the drawer says how many rows it deleted, and the
      # domain counts the rows it actually removed rather than the rows it
      # believed were there.
      {:ok, removed} when is_integer(removed) ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast("#{removed} old run assignments removed.", :done)
         |> load_day()
         |> assign(:problems_open, true)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast("Could not remove the old assignments. Reload and try again.", :refused)}
    end
  end

  def handle_event("open_run", %{"run" => run_id}, socket) do
    # A run is addressed by a URL parameter rather than by a number this page
    # hands out, for the reason `?day=` is: a drawer a reader cannot link to is a
    # drawer they have to find again, and a colleague cannot be shown the run you
    # are looking at. The handler refuses an unknown run rather than opening an
    # empty one.
    case find_run(socket.assigns.runs_day, run_id) do
      nil ->
        {:noreply, assign(socket, :drawer, nil)}

      run ->
        {:noreply,
         socket
         |> assign(:drawer, {:run, run.run_id})
         |> assign(:run, run.run_id)
         |> reset_rename_form()
         |> sync_run_context()}
    end
  end

  # Closing PATCHES, because the drawer is addressed by a parameter. Assigning
  # alone would close the panel while the address bar still said `?run=1001`, and
  # the next patch to rebuild the path would reopen it — step 26's rule about the
  # path being a record of the reader's whole state, applied to a control that
  # removes one of its entries.
  # Rename a run, from the drawer, through the SAME undo surface every other
  # write uses.
  #
  # `rename_run/5` hands back its own undo in the move shape, so the toast and the
  # Undo button need no new code here — step 28 built that surface once and this
  # is the first caller that is not a move. A caller that cannot reach Undo is a
  # caller with a different undo, and two undos is one too many.
  #
  # **The entry is kept on a refusal.** A rejected rename leaves the form showing
  # what the reader typed, with the reason under the field, because the reader's
  # next move is to fix the ID and re-submit — and a form that clears itself
  # makes them retype it from memory. Nothing is written on any refusal path.
  def handle_event("rename_run", %{"run" => %{"run_id" => new_id}}, socket) do
    %{day: day, current_organization: organization, current_gtfs_version: version} =
      socket.assigns

    case Gtfs.rename_run(organization.id, version.id, day, socket.assigns.run, new_id) do
      {:ok, %{undo: moves}} ->
        # `push_patch/2` returns a SOCKET, not `{:noreply, socket}` - the same
        # return-shape mistake step 28 recorded, reached again through a new
        # event. It fails the whole LiveView with an ArgumentError that dumps the
        # entire socket, user struct and all, before a single assertion runs.
        {:noreply,
         socket
         |> put_undo(%{moves: moves, trips: undo_trip_count(moves)})
         |> put_toast("Renamed to #{new_id}.", :done)
         # The form is NOT reset here. `push_patch/2` below re-enters
         # `handle_params/2`, which reaches `sync_run_drawer/1` and resets the
         # form on the way past. A mutation that deleted this line was caught by
         # NO test, because the patch does the same work - a no-op line, and
         # keeping it would mean believing the reader's next rename is protected
         # by a line that does nothing.
         # The drawer's run is addressed by the URL, so a rename has to move the
         # URL too: left at the old ID, the next patch would re-open a run that no
         # longer exists and the drawer would close under the reader.
         |> load_day()
         |> push_patch(to: runs_path(socket, socket.assigns.day, %{run: new_id}))}

      {:error, %Ecto.Changeset{} = changeset} ->
        # **The entry is kept, and the message is the domain's.**
        #
        # `rename_run/5` returns a SCHEMALESS changeset — `cast({%{}, ...})` — so
        # `to_form/1` refuses it ("data is not backed by a struct") and a
        # namespaced form over it traverses to an EMPTY error list even though
        # `Ecto.Changeset.traverse_errors/2` finds the message. So the form is
        # built from a plain map carrying what the reader typed, and the
        # traversed messages are handed to `CoreComponents.input/1` as its
        # `errors` attribute — which is what that component reads anyway.
        #
        # `as: :run` is required, not decorative: without it `to_form/1` cannot
        # generate a name for the input and raises "cannot generate name for
        # changeset", which takes the LiveView down on the FIRST refused rename.
        # The error path is the one that breaks, and the happy path looks fine.
        {:noreply,
         socket
         |> assign(:rename_form, to_form(%{"run_id" => new_id}, as: :run))
         |> assign(:rename_errors, rename_error_list(changeset))}

      {:error, :unknown_run} ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast("That run is no longer here. Close the drawer and open it again.", :refused)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast("That day is no longer available. Reload to see the latest runs.", :refused)}
    end
  end

  # Move ONE piece to another run, from the drawer.
  #
  # The piece is named by its POSITION in the drawer's own list, and the trips
  # come from that piece on the server. A form that posted `trip_id`s would let a
  # reader — or anything posting the form — move trips that are not in the piece
  # they are looking at, and the "From" in the page would be a claim rather than
  # the truth.
  #
  # `from:` is the run the drawer is showing, so a piece whose `from` has changed
  # underneath the page makes the write STALE and the shared optimistic check
  # refuses it. That is the whole protection: there is no separate "is this still
  # the right piece" test, because the moves themselves carry it.
  def handle_event("move_piece", %{"piece" => index, "move" => %{"to" => to}}, socket) do
    with {:ok, piece} <- piece_at(socket, index),
         {:ok, destination} <- destination(to) do
      moves =
        Enum.map(piece.trips, &%{trip_id: &1.id, from: socket.assigns.run, to: destination})

      {:noreply,
       apply_moves(
         socket,
         moves,
         moved_text(destination),
         "This run changed since the page loaded. Reload to see the latest runs.",
         fn socket, new_run_id -> follow_run(socket, new_run_id, destination) end
       )}
    else
      :no_piece ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast("That piece is no longer here. Reload to see the latest runs.", :refused)}

      :nothing_chosen ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast("Choose a run to move this piece to.", :refused)}
    end
  end

  # Split a piece at a relief handover, from the drawer.
  #
  # The trips that move are the ones AFTER the chosen gap — the gap is a
  # handover point, so the operator changes there and everything from the next
  # trip onward belongs to the other run. The gap is named by its POSITION in
  # the piece's own gap list, and the trips come from the drawer's own piece
  # list: a form that posted trip_ids could move work the reader is not looking
  # at, and one that posted a block-level gap index would be slicing the wrong
  # piece of a run whose second piece is the tail of a block.
  #
  # `from:` is the drawn run, so the same optimistic check as every other write
  # refuses a split whose trips have since changed hands.
  def handle_event(
        "split_piece",
        %{"piece" => index, "split" => %{"gap" => gap, "to" => to}},
        socket
      ) do
    with {:ok, piece} <- piece_at(socket, index),
         :ok <- both_chosen?(gap, to),
         {:ok, at} <- split_position(socket, piece, gap),
         {:ok, destination} <- destination(to),
         [_ | _] <- Enum.drop(piece.trips, at + 1) do
      moves =
        piece.trips
        |> Enum.drop(at + 1)
        |> Enum.map(&%{trip_id: &1.id, from: socket.assigns.run, to: destination})

      {:noreply,
       apply_moves(
         socket,
         moves,
         split_text(piece, at, destination),
         "This run changed since the page loaded. Reload to see the latest runs.",
         fn socket, new_run_id -> follow_run(socket, new_run_id, destination) end
       )}
    else
      :no_piece ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast("That piece is no longer here. Reload to see the latest runs.", :refused)}

      :no_relief ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast(
           "You can only split at a relief point. Reload to see the latest runs.",
           :refused
         )}

      :bad_gap ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast(
           "That relief point is no longer here. Reload to see the latest runs.",
           :refused
         )}

      :nothing_chosen ->
        {:noreply,
         socket
         |> put_undo(nil)
         |> put_toast("Choose a relief point and a run to split this piece at.", :refused)}
    end
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply,
     socket
     |> assign(:drawer, nil)
     |> assign(:run, nil)
     |> push_patch(to: runs_path(socket, socket.assigns.day, %{run: ""}))}
  end

  # The Run button and the piece buttons. The run drawer is step 29, so pressing
  # one must not silently do nothing — the buttons carry `aria-disabled` from
  # the day they stop being inert, and this clause is where step 29 replaces
  # them. It is LAST among the `handle_event` clauses on purpose: a catch-all
  # placed earlier would shadow the drawer events above it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The timer the reference's JS ran. It carries the toast's token so a timer set
  # for an EARLIER toast cannot dismiss a LATER one: without the token, a reader
  # who edits twice quickly watches the second confirmation vanish on the first
  # one's schedule.
  @impl true
  def handle_info({:dismiss_toast, token}, socket) do
    if socket.assigns.toast && socket.assigns.toast.token == token do
      {:noreply, socket |> put_undo(nil) |> put_toast(nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # One write, one toast, one undo — the shape steps 30, 31, 32 and 37 reuse.
  #
  # BOTH messages are parameters, and the success one is a function of the new
  # run id. They have to be: undo is this same function with the moves reversed,
  # and a shared success string had it announcing "New run created." after an
  # undo that had created nothing and deleted something. A caller that does not
  # get to say what happened cannot be trusted to describe it.
  #
  # `refusal` is the message for `:stale_moves`, and it is a parameter because the
  # two callers want different words for the same refusal. A create and an undo
  # are refused by one rule and mean different things by it: a create means the
  # page is behind, an undo means the work moved on without it. "These trips
  # changed" is true of both and useless for either.
  #
  # **Every path re-reads the day**, refusal included. A refusal means somebody
  # else moved these trips, so the page showing them as uncovered is now wrong in
  # the same direction the success path is: a page that says "these runs changed"
  # over a chart that still shows the old run has not told the reader anything
  # they can act on.
  # Everything the drawer's move forms need, recomputed from the day's runs and
  # the run being drawn.
  #
  # The CURRENT run is left out of the move targets: moving a piece to the run it
  # is already on is not a move, the domain allows it as a no-op, and offering it
  # would put a choice in the list that cannot mean anything.
  defp sync_run_context(socket) do
    day = socket.assigns.runs_day
    current = socket.assigns.run

    socket
    |> assign(:run_pieces, (find_run(day, current) || %{pieces: []}).pieces)
    |> assign(:next_run_id, Gtfs.next_run_id(run_ids(day)))
    |> assign(:move_runs, move_runs(day, current))
    |> assign(:piece_windows, piece_windows(day, current))
  end

  defp run_ids(day) do
    day.derived.runs |> Enum.map(& &1.run_id) |> Enum.sort()
  end

  # The relief windows of every block the drawn run touches, by block ID.
  #
  # These live on the BLOCK, not on the piece: `Pieces.derive/2` takes the
  # block's windows as input and carries only the derived `gaps` out, so a piece
  # cannot answer "where could this split" on its own. The card's rule — only
  # gaps that HAVE a window, and the FIRST window of a gap is the handover — is
  # the handover rule `Runs.Pieces` already documents, read here rather than
  # re-derived.
  defp piece_windows(day, current) do
    case find_run(day, current) do
      nil ->
        %{}

      run ->
        run.pieces
        |> Enum.map(& &1.block_id)
        |> Enum.uniq()
        |> Map.new(fn block_id ->
          block = Enum.find(day.day.blocks, &(&1.summary.block_id == block_id))
          {block_id, (block && block.windows) || []}
        end)
    end
  end

  # How many run assignments name trips that are no longer in this day type.
  #
  # Read from the domain's `:orphan_assignments` notice rather than counted from
  # anything on the page: the notice carries the count `Runs.load_runs/3`
  # already computed, and a second count here could disagree with it.
  defp orphan_count(findings) do
    case Enum.find(findings, &(&1.code == :orphan_assignments)) do
      %{detail: %{count: count}} -> count
      _none -> 0
    end
  end

  # The day's runs, minus the one being drawn, in sign-on order. The LABELS are
  # built by the component, which already owns the wording for a run's type —
  # a second spelling of "one piece" in the move select would be a move form that
  # called a run by a different name than the rest of the page does.
  defp move_runs(day, current) do
    day.derived.runs
    |> Enum.reject(&(&1.run_id == current))
    |> Enum.sort_by(&{&1.work.sign_on_secs, &1.run_id})
  end

  # The drawer's piece, by the position the fieldset named. Out of range is
  # refused rather than clamped: piece 9 of a 2-piece run is a page that no
  # longer matches the database, and guessing piece 2 would move the WRONG
  # vehicle work.
  defp piece_at(socket, index) do
    # The fieldset says "Piece 1", "Piece 2" — one-based, as a reader counts.
    # The list is zero-based, and `Enum.at(pieces, 1)` is the SECOND piece, so
    # the 1 is taken off here and nowhere else. With it left on, "Move piece 1"
    # moves piece 2's vehicle work and the page says it moved the right one.
    case Enum.at(socket.assigns.run_pieces, String.to_integer(index) - 1) do
      nil -> :no_piece
      piece -> {:ok, piece}
    end
  rescue
    ArgumentError -> :no_piece
  end

  # The gap's POSITION in the piece, one-based for the reader as with the piece
  # itself. Out of range is refused, not clamped: clamping gap 9 to the last gap
  # would split at a different point from the one named.
  # A split needs BOTH choices. `:ok <- false` would fall through the `with`
  # uncaught — `false` is not `:ok` and not one of the refusals — and take the
  # whole LiveView down on an ordinary unchosen select.
  defp both_chosen?(gap, to) do
    if chosen?(gap) and chosen?(to), do: :ok, else: :nothing_chosen
  end

  defp chosen?(""), do: false
  defp chosen?(_value), do: true

  defp split_position(socket, piece, gap) do
    at = String.to_integer(gap) - 1
    gap_entry = Enum.at(piece.gaps, at)

    cond do
      is_nil(gap_entry) -> :bad_gap
      not relief_window?(socket, piece, gap_entry) -> :no_relief
      true -> {:ok, at}
    end
  rescue
    ArgumentError -> :bad_gap
  end

  # Whether the block has a relief window at this gap.
  #
  # This is not belt and braces. The select only ever OFFERS gaps that have a
  # window, so a form posting an unoffered gap is a page that no longer matches
  # the data — and without this check the split simply happens at a gap where no
  # operator can change over, which is the one thing the control exists to
  # prevent. The SERVER decides, not the select.
  defp relief_window?(socket, piece, gap) do
    windows = Map.get(socket.assigns.piece_windows, piece.block_id, [])
    Enum.any?(windows, &(&1.gap_index == gap.index))
  end

  # The value the select carried, in the shape `apply_run_moves/4` wants.
  defp destination("__new"), do: {:ok, :new}
  defp destination(""), do: :nothing_chosen
  defp destination(run_id), do: {:ok, run_id}

  # This step's own success text, naming the run the piece ended up on.
  #
  # `apply_run_moves/4` returns `new_run_id: nil` whenever it made no run of its
  # own, which is exactly the "joined a run that already existed" case. A text
  # that branched on `nil` alone would say the same bare "Piece moved." for every
  # move into an existing run, naming nothing the reader just chose — so the
  # destination they picked is quoted back to them instead.
  defp moved_text(destination) do
    fn
      nil -> "Piece moved to run #{destination}."
      new_run_id -> "Piece moved to run #{new_run_id}."
    end
  end

  # A split's own success text: which block, how many trips changed run, and
  # where they went. The count is the thing a reader wants confirmed after a
  # split, and it comes from the piece and the gap rather than from prose.
  #
  # A split into a run that ALREADY existed returns `new_run_id: nil`, and the
  # text then names the run the reader chose rather than going blank — the same
  # rule step 30 and 31 settled on.
  defp split_text(piece, at, destination) do
    later_count = piece.trips |> Enum.drop(at + 1) |> length()

    fn new_run_id ->
      split_sentence(piece.block_id, later_count, target_id(new_run_id, destination))
    end
  end

  # Which run the trips ended up on. A split into a run that already existed
  # returns `new_run_id: nil`, and the run the READER chose is the one to name.
  defp target_id(new_run_id, :new), do: new_run_id
  defp target_id(_new_run_id, destination), do: destination

  defp split_sentence(block_id, later_count, target) do
    trips = if later_count == 1, do: "1 trip", else: "#{later_count} trips"
    "#{trips} from block #{block_id} moved to run #{target}."
  end

  # The drawer follows the PIECE. A piece moved into a run of its own leaves the
  # reader looking at a different run from the one they chose from, and a drawer
  # left on the source would show them a run that no longer holds what they just
  # moved. The number of a new run is only known AFTER the write, so this takes
  # the value `apply_run_moves/4` returned; for an existing run that value is
  # nil and the destination the reader chose is the one to follow.
  defp follow_run(socket, new_run_id, destination) do
    target = new_run_id || destination

    socket
    |> load_day()
    |> push_patch(to: runs_path(socket, socket.assigns.day, %{run: target}))
  end

  # `after_success` runs ONLY on a success, and is handed the socket and the
  # `new_run_id` the write returned. It exists so a caller that has something
  # more to do after a write — step 31 moving the drawer to the piece's new run —
  # does not have to learn the return shape a second time, and so no caller can
  # put that work on a REFUSAL, where the write never happened. A refusal must
  # leave the reader on what they were looking at.
  defp apply_moves(socket, moves, success, refusal, after_success \\ fn socket, _id -> socket end)

  defp apply_moves(socket, moves, success, refusal, after_success)
       when is_function(success, 1) and is_function(after_success, 2) do
    %{day: day, current_organization: organization, current_gtfs_version: version} =
      socket.assigns

    # An EMPTY move set is refused here, once, for every caller.
    #
    # `apply_run_moves/4` answers `[]` with `{:ok, changed_trips: 0}` — a
    # SUCCESS for a write that changed nothing. Left unguarded, a caller with
    # nothing to move (a segment or a piece that carries no trips) would show
    # "Piece moved to run 1002." and arm an Undo over zero moves, and the reader
    # would believe vehicle work had changed places when none had.
    #
    # No fixture in this package reaches it, so unlike the guards around it this
    # one is defence in depth rather than proof. It stays because the false
    # success is a property of the SHARED helper, and every caller — create a
    # run, move a piece, undo — would otherwise inherit it.
    case moves do
      [] ->
        socket
        |> put_undo(nil)
        |> put_toast("There is nothing to move.", :refused)
        |> load_day()

      _ ->
        apply_moves_now(
          socket,
          organization,
          version,
          day,
          moves,
          success,
          refusal,
          after_success
        )
    end
  end

  defp apply_moves_now(socket, organization, version, day, moves, success, refusal, after_success) do
    case Gtfs.apply_run_moves(organization.id, version.id, day, moves) do
      {:ok, %{new_run_id: id, undo: undo_moves}} ->
        socket
        |> put_undo(%{moves: undo_moves, trips: undo_trip_count(undo_moves)})
        |> put_toast(success.(id), :done)
        |> load_day()
        |> after_success.(id)

      {:error, :stale_moves} ->
        socket |> put_undo(nil) |> put_toast(refusal, :refused) |> load_day()

      {:error, {:invalid_trips, trips}} ->
        socket
        |> put_undo(nil)
        |> put_toast("#{length(trips)} trips on this block are not part of this day.", :refused)
        |> load_day()

      {:error, :not_found} ->
        socket
        |> put_undo(nil)
        |> put_toast("That day is no longer available. Reload to see the latest runs.", :refused)
        |> load_day()

      {:error, {:invalid_run_id, _run_id}} ->
        socket
        |> put_undo(nil)
        |> put_toast("That run ID is not usable. Reload to see the latest runs.", :refused)
    end
  end

  # This step's own success text. A write that made no run of its own — a move, a
  # split, a rename — has no number to quote, so it does not invent one, and
  # steps 30, 31 and 32 pass their own `success` in place of this.
  defp created_text(id), do: "Run #{id} created."

  defp undo_trip_count(undo_moves) do
    undo_moves |> Enum.map(& &1.trip_id) |> Enum.uniq() |> length()
  end

  # The toast, and the timer that takes it away.
  #
  # **10 s with an Undo and 4 s without**, the reference's own timing: an Undo the
  # reader cannot reach in time is not an Undo, and a confirmation with nothing to
  # take back has earned less of their attention. The Undo is assigned BEFORE the
  # toast, because the timeout reads it to choose.
  defp put_toast(socket, text, kind \\ :done)

  defp put_toast(socket, nil, _kind), do: assign(socket, :toast, nil)

  defp put_toast(socket, text, kind) do
    token = System.unique_integer([:positive, :monotonic])

    Process.send_after(
      self(),
      {:dismiss_toast, token},
      if(socket.assigns.undo, do: 10_000, else: 4_000)
    )

    assign(socket, :toast, %{text: text, kind: kind, token: token})
  end

  defp put_undo(socket, nil), do: assign(socket, :undo, nil)

  defp put_undo(socket, %{moves: moves} = undo) when is_list(moves),
    do: assign(socket, :undo, undo)

  # The segment the button names, found in the day's own uncovered list.
  #
  # Compared as STRINGS on purpose: `phx-value` arrives as a string and a segment
  # carries integers, so a straight `==` would find nothing and every Create run
  # would report the block as no longer uncovered.
  defp find_uncovered(nil, _params), do: nil

  defp find_uncovered(%{derived: %{uncovered: segments}}, params) do
    block = params["block"] || params["value-block"]
    start_secs = params["start"] || params["value-start"]
    end_secs = params["end"] || params["value-end"]

    Enum.find(segments, fn segment ->
      segment.block_id == block and
        to_string(segment.start_secs) == to_string(start_secs) and
        to_string(segment.end_secs) == to_string(end_secs)
    end)
  end

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(_dir), do: :asc

  # The share of every day type is a WHOLE-VERSION read — `Runs.day_type_shares/2`
  # exports movements, reads the crew rules and derives each day type — so it is
  # far more work than the day's own read and none of it is needed to draw the
  # strip. Loading it in the LiveView process would block the page on every
  # drawer open, and the drawer is opened by clicking a tile, so the reader would
  # feel the wait as the page hanging.
  #
  # The task captures only the two ids, never the socket, and `handle_async/3`
  # applies the result — the rule `station_diagram_live.ex` already states.
  defp start_shares_load(socket) do
    %{current_organization: organization, current_gtfs_version: version} = socket.assigns

    socket
    |> assign(:shares_state, :loading)
    |> assign(:shares, [])
    |> start_async(:shares, fn ->
      Gtfs.run_day_type_shares(organization.id, version.id)
    end)
  end

  @impl true
  def handle_async(:shares, {:ok, {:ok, shares}}, socket) do
    {:noreply, socket |> assign(:shares, shares) |> assign(:shares_state, :loaded)}
  end

  def handle_async(:shares, {:ok, {:error, _reason}}, socket) do
    # The version can stop being published between the page's read and this one.
    # The drawer's own day-type figures are still on screen, so the failure is
    # one line in one region rather than an error over the whole drawer.
    {:noreply, socket |> assign(:shares, []) |> assign(:shares_state, :failed)}
  end

  def handle_async(:shares, {:exit, reason}, socket) do
    # A task the reader has already moved on from — the drawer closed, the day
    # type changed — exits with `:shutdown`. That is not a failure to report.
    if reason == {:shutdown, :cancel} do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:shares, []) |> assign(:shares_state, :failed)}
    end
  end

  # `BlocksLive.ensure_day_loaded/1`'s rule: the disconnected render shows the
  # loading state, and a day type already loaded is not read again. The guard
  # matters because `handle_params/3` runs on every patch, so switching tabs or
  # changing a filter would otherwise re-read the whole day.
  defp ensure_day_loaded(socket) do
    cond do
      not connected?(socket) ->
        assign(socket, :load_state, :loading)

      socket.assigns.loaded_day_key == {:key, socket.assigns.day} ->
        socket

      true ->
        load_day(socket)
    end
  end

  defp load_day(socket) do
    %{day: day, current_organization: organization, current_gtfs_version: version} =
      socket.assigns

    case Gtfs.load_runs(organization.id, version.id, day) do
      {:ok, runs_day} ->
        socket
        |> assign(:runs_day, runs_day)
        |> assign(:day, runs_day.day.day_type.key)
        |> assign(:day_types, runs_day.day.day_types)
        |> assign(:loaded_day_key, {:key, runs_day.day.day_type.key})
        |> assign(:load_state, day_state(runs_day))
        |> stream_run_rows()
        # A reloaded day type closes the drawer. The shares are version-wide and
        # would still be right, but the drawer's *other* half is this day's
        # figures, and leaving a drawer open across a day-type change would show
        # the new day under the old day's figures for as long as the share read
        # took.
        |> assign(:drawer, nil)

      {:error, {:unknown_day_type, []}} ->
        # An EMPTY list is the version saying it has no day types at all, which
        # is a missing calendar rather than a day the reader mistyped. The two
        # are the same error shape from the read and different states here,
        # because the reader is sent to a different page for each.
        socket
        |> assign(:runs_day, nil)
        |> assign(:day, day)
        |> assign(:day_types, [])
        |> assign(:loaded_day_key, {:key, day})
        |> assign(:load_state, :no_dates)

      {:error, {:unknown_day_type, day_types}} ->
        # Nothing is applied on the reader's behalf: the page says which day
        # types exist and lets them choose. Falling back to the first would
        # silently show a day nobody asked for, and on a runs page a day is a
        # claim about whose work is whose.
        socket
        |> assign(:runs_day, nil)
        |> assign(:day, day)
        |> assign(:day_types, day_types)
        |> assign(:loaded_day_key, {:key, day})
        |> assign(:load_state, :unknown)

      {:error, _reason} ->
        # `runs_day` is deliberately untouched, so whatever is on screen stays.
        assign(socket, :load_state, :unavailable)
    end
  end

  # The rows are a stream, not an assign, so a sort re-sends one diff instead of
  # the whole table, and so a future step that adds or removes a run sends the
  # one row that changed. `reset: true` on every load and re-sort is what tells
  # LiveView the new order replaces the old one rather than adding to it.
  #
  # The sort is stable on run ID: two runs with the same paid time or the same
  # sign-on second are ordered by name, so clicking a header twice returns the
  # same order both times. Without the tiebreak, a re-sort that does not change
  # the key would shuffle rows that the reader has learned the positions of.
  defp stream_run_rows(socket) do
    runs_day = socket.assigns.runs_day
    %{sort: sort, dir: dir} = socket.assigns

    runs =
      runs_day.derived.runs
      |> Enum.sort_by(fn run -> {run.run_id} end)
      |> Enum.sort_by(&sort_value(&1, sort), sorter_comparator(dir))
      |> Enum.map(fn run -> %{id: "run-#{run.run_id}", run: run} end)

    socket
    |> assign(:run_axis, runs_day.derived.axis)
    |> assign(:run_routes, runs_day.day.routes)
    |> assign(:run_stop_names, run_stop_names(runs_day))
    |> stream(:run_rows, runs, reset: true, dom_id: &run_dom_id/1)
  end

  # `stream/4` would otherwise prefix every row with the STREAM's name, giving
  # `run_rows-run-1001`. The row is a run, and a run id is already a legal DOM
  # id, so the row keeps the name the prototype and the piece titles use.
  defp run_dom_id(%{id: id}), do: id

  # `Enum.sort_by/3`'s comparator is a two-argument function, so the direction
  # lives here rather than in a `> `/`< ` conditional at every key.
  defp sorter_comparator(:asc), do: &<=/2
  defp sorter_comparator(_dir), do: &>=/2

  # The status order is the severity of the run's WORST finding, so sorting by
  # Status brings the run that needs attention to the top rather than ordering
  # by a count and hiding a single error behind four notices.
  defp sort_value(run, :id), do: run.run_id
  defp sort_value(run, :type), do: type_rank(run.work.type)
  defp sort_value(run, :sign_on), do: {run.work.sign_on_secs, run.run_id}
  defp sort_value(run, :sign_off), do: {run.work.sign_off_secs, run.run_id}
  defp sort_value(run, :spread), do: {run.work.spread_secs, run.run_id}
  defp sort_value(run, :paid), do: {run.work.paid_secs, run.run_id}
  defp sort_value(run, :status), do: {status_rank(run.findings), run.run_id}

  defp type_rank(:one_piece), do: 0
  defp type_rank(:straight), do: 1
  defp type_rank(:split), do: 2

  defp status_rank(findings) do
    case Enum.min_by(findings, &severity_rank(&1.severity), fn -> nil end) do
      nil -> 99
      finding -> severity_rank(finding.severity)
    end
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:notice), do: 2
  defp severity_rank(_severity), do: 99

  # The five states, decided the same way `BlocksLive.day_state/1` decides its
  # own. A version with no dates and a version with no trips are different
  # problems with different fixes, and the reader is sent to a different page
  # for each.
  defp day_state(runs_day) do
    cond do
      runs_day.day.day_types == [] -> :no_dates
      runs_day.day.counts.blocks == 0 -> :empty
      true -> :loaded
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # `?day=` is dropped rather than rendered empty when no day type is selected,
  # `?day=` is dropped rather than rendered empty when no day type is selected,
  # so `/runs` and `/runs?day=` are the same URL and the first one the one a
  # reader bookmarks.
  #
  # Sort and scale patch the day type's own URL, keeping whatever the reader
  # already had, so changing the order never drops `?day=` and zooming never
  # resets it. A patch that rebuilt the path from scratch would silently send a
  # reader who had picked a day type back to the version's default day.
  #
  # A value equal to its default is left OUT rather than written, so the URL a
  # reader copies for the default view is the short one and the address bar does
  # not fill with `sort=sign_on&dir=asc`.
  #
  # **Everything except `day` is read off the socket unless the caller names it.**
  # A patch that named only `sort` and rebuilt the path from each parameter's own
  # default would take a reader off the List view and back to the Timeline every
  # time they re-sorted, and would drop the order they had chosen every time they
  # switched views. That is the same bug as dropping `?day=`, one step along: the
  # path is a record of the reader's whole state, so a patch that only knows about
  # one field cannot afford to guess about the rest.
  defp runs_path(socket, day, extra \\ %{}) do
    sort = to_string(Map.get(extra, :sort) || socket.assigns.sort)
    dir = Map.get(extra, :dir) || socket.assigns.dir
    view = to_string(Map.get(extra, :view) || socket.assigns.view)
    scale = to_string(Map.get(extra, :scale) || socket.assigns.scale)
    panel = to_string(Map.get(extra, :panel) || socket.assigns.panel)
    run = to_string(Map.get(extra, :run) || socket.assigns.run || "")

    params =
      [
        {"day", day},
        {"sort", if(sort != "sign_on", do: sort)},
        {"dir", if(dir == :desc, do: "desc")},
        {"scale", if(scale != "day", do: scale)},
        {"view", if(view != "timeline", do: view)},
        {"panel", if(panel != "runs", do: panel)},
        {"run", if(run != "", do: run)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join("&", fn {key, value} -> key <> "=" <> to_string(value) end)

    base = "/gtfs/#{socket.assigns.current_gtfs_version.id}/runs"
    if params == "", do: base, else: base <> "?" <> params
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
      width="wide"
    >
      <:sub_header>
        <.operations_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:runs} />
      </:sub_header>

      <RunsComponents.toast toast={@toast} undo={@undo} />

      <div id="runs-page" data-load-state={@load_state}>
        <div class="w-full space-y-4">
          <RunsComponents.page_head>
            <:actions>
              <RunsComponents.review_problems_button
                :if={@runs_day}
                findings={@runs_day.derived.findings}
                uncovered={@runs_day.derived.uncovered}
                open={@problems_open}
              />
            </:actions>
          </RunsComponents.page_head>

          <RunsComponents.unavailable_callout :if={@load_state == :unavailable} />

          <RunsComponents.scope_bar
            :if={@load_state == :loaded or @load_state == :unavailable}
            day_types={@day_types}
            selected={@day || ""}
          >
            <:counts>
              <RunsComponents.count_strip
                :if={@runs_day}
                stats={@runs_day.derived.stats}
                spread_limit_minutes={@runs_day.crew.max_spread_minutes}
                selected_key={selected_count_tile(@drawer)}
              />

              <RunsComponents.uncovered_callout
                :if={@runs_day}
                segments={@runs_day.derived.uncovered}
                duration_secs={@runs_day.derived.stats.uncovered.secs}
              />
            </:counts>
          </RunsComponents.scope_bar>

          <RunsComponents.plan_card
            :if={panel_state?(@load_state)}
            version_id={@current_gtfs_version.id}
          >
            <RunsComponents.page_state
              kind={@load_state}
              version_id={@current_gtfs_version.id}
              day_types={@day_types}
            />
          </RunsComponents.plan_card>

          <div :if={@load_state == :loaded or @load_state == :unavailable} class="mt-4">
            <div class="flex flex-wrap items-end justify-end gap-3 pb-3">
              <RunsComponents.tabs
                :if={@runs_day}
                panel={@panel}
                run_count={length(@runs_day.derived.runs)}
                uncovered_trips={uncovered_trip_count(@runs_day)}
                uncovered_segments={length(uncovered_segments(@runs_day))}
              />

              <.segmented_control
                :if={@panel == :runs}
                id="runs-view"
                name="view"
                legend="Runs view"
                legend_class="sr-only"
                options={[{"Timeline", "timeline"}, {"List", "list"}]}
                value={Atom.to_string(@view)}
                event="set_view"
                size={:sm}
                appearance={:joined}
                emphasis={:quiet}
              />

              <.segmented_control
                :if={@panel == :runs and @view == :timeline}
                id="runs-scale"
                name="scale"
                legend="Chart scale"
                legend_class="sr-only"
                options={[{"Whole day", "day"}, {"Zoom in", "zoom"}]}
                value={Atom.to_string(@scale)}
                event="set_scale"
                size={:sm}
                appearance={:joined}
                emphasis={:quiet}
              />
            </div>

            <RunsComponents.plan_card version_id={@current_gtfs_version.id}>
              <%= if @panel == :uncovered do %>
                <RunsComponents.uncovered
                  segments={uncovered_segments(@runs_day)}
                  windows={uncovered_windows(@runs_day)}
                  routes={@run_routes}
                  stop_names={@run_stop_names}
                />
              <% else %>
                <%= if @view == :list do %>
                  <RunsComponents.list
                    run_rows={@streams.run_rows}
                    sort={@sort}
                    dir={@dir}
                    day_label={day_label(@runs_day)}
                  />
                <% else %>
                  <RunsComponents.chart_key />
                  <RunsComponents.timeline
                    run_rows={@streams.run_rows}
                    axis={@run_axis}
                    routes={@run_routes}
                    sort={@sort}
                    dir={@dir}
                    scale={@scale}
                    crew={runs_crew(@runs_day)}
                  />
                <% end %>
              <% end %>
            </RunsComponents.plan_card>
          </div>

          <RunsComponents.page_footnote :if={@load_state == :loaded} />
        </div>
      </div>

      <RunsComponents.problems_drawer
        :if={@runs_day}
        open={@problems_open}
        findings={@runs_day.derived.findings}
        uncovered={@runs_day.derived.uncovered}
        uncovered_trips={@runs_day.derived.stats.uncovered.trips}
        orphan_count={orphan_count(@runs_day.derived.findings)}
        version_id={@current_gtfs_version.id}
        day_type_key={@day || ""}
        day_label={day_label(@runs_day)}
      />

      <RunsComponents.run_drawer
        :if={is_map(@runs_day) and selected_run(@runs_day, @drawer)}
        open?={match?({:run, _id}, @drawer)}
        run={selected_run(@runs_day, @drawer)}
        version_id={@current_gtfs_version.id}
        day_type_key={@day}
        crew={@runs_day.crew}
        stop_names={@run_stop_names}
        rename_form={@rename_form}
        rename_errors={@rename_errors}
        move_form={@move_form}
        split_form={@split_form}
        move_runs={@move_runs}
        piece_windows={@piece_windows}
        next_run_id={@next_run_id}
        return_focus_id={"runs-run-#{@run}"}
      />

      <RunsComponents.summary_drawer
        :if={is_map(@runs_day)}
        open?={match?({:summary, _key}, @drawer)}
        stats={@runs_day.derived.stats}
        crew={@runs_day.crew}
        max_piece_minutes={@runs_day.day.context.max_piece_minutes}
        relief_stop_ids={MapSet.to_list(@runs_day.day.context.relief_stop_ids) |> Enum.sort()}
        day_label={day_label(@runs_day)}
        day_type_key={@day}
        shares_state={@shares_state}
        shares={@shares}
      />
    </Layouts.app>
    """
  end

  # The count tile that is currently pressed, or nil when the drawer is closed.
  defp selected_count_tile({:summary, key}), do: key
  defp selected_count_tile(_drawer), do: nil

  # The run the drawer is showing, or nil.
  #
  # Re-found from the LOADED DAY on every render rather than held in an assign,
  # because the day is re-read after every write (step 28) and a drawer holding a
  # run struct would then be describing a version of the run that no longer
  # exists. One lookup over a list this size, on a render that already redraws the
  # chart.
  defp selected_run(%{derived: %{runs: runs}}, {:run, run_id}) do
    Enum.find(runs, &(&1.run_id == run_id))
  end

  defp selected_run(_runs_day, _drawer), do: nil

  # An empty rename form, for a run that has just been opened.
  #
  # Every way a drawer opens resets it, and the two ways are separate code: the
  # `open_run` click and the `?run=` URL. Only testing the click left the URL
  # branch unchecked, and a mutation that removed its reset survived every other
  # test in this gate.
  defp reset_rename_form(socket) do
    socket
    |> assign(:rename_form, to_form(%{"run_id" => ""}, as: :run))
    |> assign(:rename_errors, [])
  end

  # The domain's own message, taken out of Ecto's `{message, opts}` error tuple.
  #
  # `traverse_errors/2` returns a MAP of field to messages, and this form has one
  # field, so the map is flattened. Handing the map itself to
  # `CoreComponents.error/1` renders `{:run_id, ["is already used in this day
  # type"]}` as text — and raises, because a tuple is not `Phoenix.HTML.Safe`.
  #
  # The `opts` are dropped rather than interpreted. A branch that appended
  # `opts[:count]` survived every test in this gate, because no changeset the
  # rename path raises carries more than one error, and no reader has ever seen
  # the difference. Code that only a mutation can reach is still speculative, and
  # rewriting the domain's count here would put a second wording of its own
  # error in the page. If the domain starts counting, it starts saying so.
  defp rename_error_list(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.values()
    |> List.flatten()
  end

  # The run a button names, or nil. Same reason as `selected_run/2`.
  defp find_run(nil, _run_id), do: nil

  defp find_run(%{derived: %{runs: runs}}, run_id) do
    Enum.find(runs, &(&1.run_id == run_id))
  end

  # The drawer's subtitle is the LOADED day type's own label rather than its key,
  # which is a base64 hash a reader cannot check against anything — and rather
  # than every day type the version has, which would name days the drawer says
  # nothing about.
  defp day_label(nil), do: "this day"

  defp day_label(runs_day) do
    key = runs_day.day.day_type.key

    case Enum.find(runs_day.day.day_types, &(&1.key == key)) do
      %{label: label} -> label
      nil -> key
    end
  end

  # `:loaded` and `:unavailable` have no panel: the plan step fills the first
  # and `unavailable_callout/0` presents the second. Rendering a plan card
  # around nothing in either state would put an empty bordered box on the page,
  # which reads as a failure to load.
  defp panel_state?(state) when state in [:loading, :no_dates, :empty, :unknown], do: true
  defp panel_state?(_state), do: false

  # The crew rules for the loaded day, or nil.
  #
  # The chart's block renders in the `:unavailable` state as well as `:loaded`,
  # because a failed RELOAD keeps the runs already on screen. A failed FIRST
  # load has no `runs_day` at all, so this is a map check and not a truthiness
  # check — the same nil trap step 21 recorded on the count strip, reached here
  # through a different door. A nil crew makes the footnote's paid-break limit
  # read as an em dash, which is the right thing to say about a limit nobody set.
  # Every stop the day's trips name, as `%{stop_id => name}`.
  #
  # A relief window carries a `stop_id` and a time, and a reader needs the stop's
  # NAME to plan a change: "09:12 at BAY_B" is a stop code, and "09:12 at Bay B"
  # is a place. The name is already on the trips the day loaded, so this is a
  # projection of data the page is holding rather than a second read, and the
  # routes map beside it is built the same way.
  #
  # A window naming a stop no trip names keeps its id, because a window is real
  # whether or not the page can spell its stop.
  # The day's uncovered segments, or an empty list when there is no day. Every
  # read of them is guarded the same way, because the tools row renders in the
  # `:unavailable` state too and a failed FIRST load has no day at all - step 25's
  # nil trap, and this step adds three more doors onto the same room.
  defp uncovered_segments(nil), do: []
  defp uncovered_segments(%{derived: %{uncovered: uncovered}}), do: uncovered

  defp uncovered_windows(nil), do: %{}

  defp uncovered_windows(%{day: %{blocks: blocks}}),
    do: Map.new(blocks, &{&1.summary.block_id, &1.windows})

  defp uncovered_trip_count(nil), do: 0

  defp uncovered_trip_count(%{derived: %{uncovered: segments}}) do
    Enum.reduce(segments, 0, &(length(&1.trips) + &2))
  end

  defp run_stop_names(runs_day) do
    for block <- runs_day.day.blocks,
        trip <- block.trips,
        stop <- [trip.first_stop, trip.last_stop],
        is_map(stop),
        reduce: %{} do
      names -> Map.put_new(names, stop.stop_id, stop[:name] || stop.stop_id)
    end
  end

  defp runs_crew(runs_day) when is_map(runs_day), do: runs_day.crew
  defp runs_crew(_runs_day), do: nil
end
