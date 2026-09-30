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
      |> ensure_day_loaded()

    socket =
      if (resort? or view_changed?) and socket.assigns.runs_day,
        do: stream_run_rows(socket),
        else: socket

    {:noreply, socket}
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

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer, nil)}
  end

  # The Run button and the piece buttons. The run drawer is step 29, so pressing
  # one must not silently do nothing — the buttons carry `aria-disabled` from
  # the day they stop being inert, and this clause is where step 29 replaces
  # them. It is LAST among the `handle_event` clauses on purpose: a catch-all
  # placed earlier would shadow the drawer events above it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

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

    params =
      [
        {"day", day},
        {"sort", if(sort != "sign_on", do: sort)},
        {"dir", if(dir == :desc, do: "desc")},
        {"scale", if(scale != "day", do: scale)},
        {"view", if(view != "timeline", do: view)}
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

      <div id="runs-page" data-load-state={@load_state}>
        <div class="w-full space-y-4">
          <RunsComponents.page_head />

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
              <.segmented_control
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
                :if={@view == :timeline}
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
            </RunsComponents.plan_card>
          </div>

          <RunsComponents.page_footnote :if={@load_state == :loaded} />
        </div>
      </div>

      <RunsComponents.summary_drawer
        :if={@runs_day}
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
  defp runs_crew(runs_day) when is_map(runs_day), do: runs_day.crew
  defp runs_crew(_runs_day), do: nil
end
