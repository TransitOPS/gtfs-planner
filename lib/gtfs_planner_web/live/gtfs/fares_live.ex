defmodule GtfsPlannerWeb.Gtfs.FaresLive do
  @moduledoc """
  The Fares zone workspace for Settings › This version › Fares, built from the
  TransitOps application design system. The page leads back to Settings with a
  link and puts its one primary action where the task is: Create zone in the
  header, Assign zone in the selection bar while stops are selected, or the
  empty state's own action.

  The Fares section is two LiveViews as of step 32. This one serves only the
  Zones tab, at `/settings/fares/zones`, and
  `GtfsPlannerWeb.Gtfs.FareEditorLive` serves Prices, Where fares apply,
  Transfers and Checks. The shared `fares_tabs/1` strip navigates between them,
  so a tab change is a real navigation between the two pages rather than a patch
  within one. The Zones tab's own query state (`?zone=`, `?filter=`, `?q=`,
  `?page=`) still stays in the URL as the stops are filtered and assigned.

  Access is authorized at mount through `EnsureRole`, following the other GTFS
  pages: there is no view-only GTFS role, and `Gtfs.FareZones` enforces the
  organization and version scope on every read the workspace performs. The
  workspace's data arrives in one operational read through
  `Gtfs.load_fare_workspace/3`, so a lost database connection resolves to one
  load-error state with a single recovery action instead of a blank page, a
  partial workspace, or a crash reported as downtime.

  The disconnected render shows the skeleton; the connected load resolves to
  `:ready` or `:unavailable`, and `reload` re-runs the same load. The Zones tab
  renders the version's inventory, the filter the URL asked for and the stop
  list below the stage header.

  The stop list is the page's second URL state owner: searching patches `?q=`
  and drops `?page=`, and pagination patches `?page=`, both keeping the current
  filter so a control never silently changes which stops are listed. The search
  field handles its form's change and submit events alike, so pressing Enter
  cannot hand the form to the browser and reload the page with the filter
  dropped. Each load resets the `:stops` stream to the page
  `FareZones.list_stops/3` returned, so the rows are data and the table itself is
  not re-rendered per row.

  The selection is the opposite: `@selection` is a `MapSet` of stop UUIDs held in
  the socket and deliberately kept out of the URL, so it survives a search, a
  filter and a page (AC-24) without ever being shareable as a stale link. The
  page's rows, `select_page` and `select_matching` all join it, `clear_selection`
  empties it, and a checkbox sends the one ID it toggles. That ID comes from the
  browser, so it is validated against this version's own boardable stops before
  it joins the selection: an ID of another organization, another version, a
  station or a malformed value changes nothing. `@matching_ids` holds the whole
  match of the current filter and search, refreshed by every load, so the head can
  offer "Select all N matching" and the bar can count what the filter cannot show.
  The rows are re-streamed when the selection changes, so a checkbox rendered by
  the server and the state behind it never disagree.

  `@assignment` is the review a selection is committed through and `@undo` the
  report of the save that happened. Opening a review is a read: `preview_assignment/4`
  reports from current database values what each selected stop would change to, and
  the dialog states it before anything is written. `apply_assignment/2` writes the
  reviewed changes, and the review it was written from is what is passed along, so
  a stop that changed since the review can only produce a stale result, never a
  silent overwrite. Nothing about a failed or stale save closes the dialog: the
  review is the operator's work, and it stays on screen with the reason it could not
  be saved until they cancel it, refresh it or succeed. A successful save hands the
  applied changes to `@undo`, which is the only state Undo runs from and which the
  next save replaces, a tab change clears and a version switch cannot carry.

  The zone drawer is the page's create and edit surface for zone metadata. It
  opens from the header's `Create zone` action, from the first-use state's
  `Create first zone`, or from the stage header's `Edit zone` while a zone filter
  is selected, and it always sends the zone's exact stored ID as the edit key, so
  the domain can keep an imported `" A"` byte-for-byte through a name-only edit.
  The form is `FareZones.change_zone/2`'s changeset, so it validates what the
  write will do; the write is `create_zone/2` or `update_zone/3`, and a duplicate
  ID, a zone another editor removed and a pair that is no longer a published
  version of the organization each leave the drawer open with its input and a
  visible reason (AC-12, AC-13, AC-14, AC-15, AC-26). A successful save clears
  `@undo`, reports what it did, and moves the filter to the zone it wrote.

  When the inventory carries no zone at all, the workspace is replaced by the
  first-use state (AC-22). A filter that matches no stop is not that state: an
  empty filter renders the list's own empty message.

  The delete dialog is the zone drawer's destructive exit. `Delete zone…` in an
  edit drawer closes it and opens the confirm, which captures the zone's
  counts as the fence `delete_zone/4` compares against and states what the
  deletion changes before anything is written: the zone's counts, the member
  stop types it also moves, the replacement select with its label, and either
  the warning or the empty zone's own sentence (AC-27). A zone fare rules use
  can only be deleted through another inventory zone, and nothing is chosen for
  the operator: the confirm stays disabled, with its reason, until a replacement
  is picked, and a version with no other zone never enables it. A refused write keeps the dialog
  open on freshly read values: a stale result states the counts the zone now has
  and fences the next confirm against them, and a zone another editor removed
  closes the dialog with what happened. Success patches to All stops and reports
  "Zone deleted." (AC-16, AC-26).

  The Zones tab's map is the stage's other membership surface. `@view` decides
  whether the map is shown beside the list or the list takes the stage, and the
  map itself carries no state here: the `FareZoneMap` hook mounts, replies to
  `fare_zone_map_ready` with the whole `map_snapshot/1`, and the server answers
  every later change with the narrowest delta the protocol has - a selection
  change, the stops an assignment moved, the colors a metadata edit changed, the
  whole snapshot after a rename or a delete, and the filter. `@map_mounted?`
  records whether a hook is mounted to receive them, so nothing is pushed at a
  map that is not there, and `@map_state` records the one failure the map has:
  `map_unavailable` replaces the frame with the reference's copy and its two ways
  out, and Retry map renders the hook again, where the next mount hydrates from a
  fresh reply rather than from deltas it never received (CR-8, AC-29).

  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]

  import GtfsPlannerWeb.Gtfs.FaresComponents,
    only: [
      assignment_dialog: 1,
      delete_zone_dialog: 1,
      first_use_empty: 1,
      load_error: 1,
      loading: 1,
      map_legend: 1,
      map_unavailable: 1,
      saved_callout: 1,
      selection_bar: 1,
      stage_header: 1,
      stop_list: 1,
      stop_search: 1,
      zone_drawer: 1,
      zone_inventory: 1,
      zone_map: 1
    ]

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1, message: 1]

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.AgentPanel

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The outcomes AC-25 and AC-26 fix, named once so the same failure is never
  # described two ways.
  @unknown_zone_message "That zone no longer exists. Choose another zone."

  @invalid_selection_message "Some selected stops are no longer in this version. Clear your selection and select again."

  @save_failed_message "Changes couldn’t be saved. Your edits are still here."

  # The helper handoff's refusals. Each names what stopped the review and what to
  # do next; none changes the page's own state (AC-6).
  @helper_unavailable_notice "That prepared assignment is no longer available. Ask the helper again."

  @helper_close_first_notice "Close the open review, drawer or dialog first, then review the assignment again."

  @helper_selection_notice "Clear your selection first, or select exactly the prepared stops."

  @helper_changed_notice "The routes' stops or zones changed after this was prepared. Ask the helper again."

  @helper_zone_gone_notice "The target zone is no longer in this version. Ask the helper again."

  @undo_stale_message "Undo wasn’t applied because some stops changed after the save."

  # AC-13 and AC-15's drawer outcomes, named once so one outcome is never
  # described two ways.
  @zone_missing_message "This zone no longer exists. Another change removed it."

  @zone_created_message "Zone created. Select stops from All stops to get started."

  @zone_updated_message "Zone updated."

  # AC-26's delete outcomes, named once for the same reason as the drawer's.
  @zone_deleted_message "Zone deleted."

  @delete_missing_message "This zone no longer exists."

  # The color a new zone starts with, the reference's own default.
  @new_zone_color "ochre"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Fares")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:load_state, :loading)
     |> assign(:inventory, nil)
     |> assign(:checks, nil)
     |> assign(:stop_page, nil)
     |> assign(:filter, :all)
     |> assign(:q, nil)
     |> assign(:page, 1)
     |> assign(:selection, MapSet.new())
     |> assign(:matching_ids, MapSet.new())
     |> assign(:assignment, nil)
     |> assign(:undo, nil)
     |> assign(:workspace_action, nil)
     |> assign(:zone_drawer_open, false)
     |> assign(:zone_drawer_zone_id, nil)
     |> assign(:zone_drawer_entry, nil)
     |> assign(:zone_form, new_zone_form())
     |> assign(:zone_error, nil)
     |> assign(:zone_return_focus_id, nil)
     |> assign(:zone_delete, nil)
     |> assign(:zone_delete_return_focus_id, nil)
     |> assign(:notice, nil)
     |> assign(:view, :map)
     |> assign(:map_state, :ready)
     |> assign(:map_mounted?, false)
     |> assign(:map_filter, nil)
     |> assign(:map_snapshot_after_load, false)
     |> stream(:stops, [])
     |> AgentPanel.mount("fare_zones")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action
    {filter, q, page} = zones_params(action, params)

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:q, q)
      |> assign(:page, page)
      |> assign(:undo, undo_after_patch(socket, action))
      |> assign(:notice, notice_after_patch(socket, action))
      |> assign(:workspace_action, action)
      # A patch that leaves the Zones tab removes the map root with the rest of
      # the stage, so the hook it held is gone and must not be pushed to until a
      # new one mounts and hydrates (CR-8).
      |> assign(:map_mounted?, socket.assigns.map_mounted? and action == :zones)

    if connected?(socket) do
      {:noreply, load_workspace(socket)}
    else
      # The static render ships the skeleton; the connected mount owns the load.
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load_workspace(socket)}

  # Searching patches `q` and drops `page`: a new search starts at its own first
  # page. The filter stays, so a search inside a zone keeps listing that zone.
  #
  # The form's `phx-submit` sends this same event, so pressing Enter is handled
  # here instead of letting the browser make its own GET request, which would
  # replace the whole query string and silently drop the zone, the unassigned
  # filter and the page the operator was reading. A submit that does not change
  # the query - Enter after the debounced change has already patched, or Enter in
  # an untouched field - keeps the page it was reading.
  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    query = search_query(q)

    if query == search_query(socket.assigns.q) do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: zones_url(socket, query))}
    end
  end

  # Pagination keeps both the filter and the search, so page 2 shows the next
  # page of the same list instead of the next page of everything.
  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: zones_url(socket, page: Values.positive_integer(page, 1)))}
  end

  # One checkbox. The ID arrives from the browser, so it is validated against
  # this version's own boardable stops before it can join the selection; a
  # malformed value, a stopped row of another organization or version, or a
  # station of this one leaves the selection exactly as it was (CR-5, INV-1).
  # Deselecting needs no read: removing an ID can never add a stop the version
  # does not have.
  @impl true
  def handle_event("toggle_stop", %{"id" => id}, socket) do
    {:noreply, toggle_stop(socket, id)}
  end

  def handle_event("toggle_stop", _params, socket), do: {:noreply, socket}

  # The page's own rows, already read as boardable stops of this version, so the
  # selection grows by one page and one stream re-render.
  @impl true
  def handle_event("select_page", _params, socket) do
    {:noreply, select(socket, page_ids(socket))}
  end

  # The whole match of the current filter and search, from the load's own read.
  @impl true
  def handle_event("select_matching", _params, socket) do
    {:noreply, select(socket, socket.assigns.matching_ids)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, socket |> assign_selection(MapSet.new()) |> restream_page()}
  end

  # The map's handshake. A newly mounted hook asks for the whole state and draws
  # from this reply alone, so Retry map, List -> Map + list and a tab return each
  # begin from the current points, colors, selection and filter rather than from
  # whatever deltas an earlier mount happened to receive (CR-8, AC-29). The reply
  # is the same payload a later `fare_zone_snapshot` carries.
  @impl true
  def handle_event("fare_zone_map_ready", _params, socket) do
    {:reply, map_snapshot(socket),
     socket
     |> assign(:map_mounted?, socket.assigns.map_state == :ready)
     |> assign(:map_filter, socket.assigns.filter)}
  end

  # A box dragged on the map. The IDs arrive from the browser, so each one is
  # cast and then resolved against this version's own boardable stops before it
  # can join the selection: a malformed value, a stop of another organization or
  # version, or a station of this one is dropped without reaching a query
  # (CR-5, INV-1). The selection grows by what remains.
  @impl true
  def handle_event("select_stops", %{"ids" => ids}, socket) when is_list(ids) do
    {:noreply, select(socket, MapSet.new(known_stop_ids(socket, ids)))}
  end

  def handle_event("select_stops", _params, socket), do: {:noreply, socket}

  # The hook reports the one map failure it can have - Leaflet is missing, or the
  # first tile did not load - and the frame becomes the reference's fallback. The
  # root goes with it, so the map is not mounted until Retry map renders it again.
  @impl true
  def handle_event("map_unavailable", _params, socket) do
    {:noreply, socket |> assign(:map_state, :unavailable) |> unmount_map()}
  end

  @impl true
  def handle_event("retry_map", _params, socket) do
    {:noreply, assign(socket, :map_state, :ready)}
  end

  # Use stop list is the fallback's other way out: the same List view the stage
  # header's switch selects, so the map stops rendering and the list takes the
  # stage.
  @impl true
  def handle_event("use_stop_list", _params, socket) do
    {:noreply, socket |> assign(:view, :list) |> assign(:map_mounted?, false)}
  end

  # Which of the two views the stage shows. It is a display choice rather than
  # URL state, so it stays in the socket; leaving the map view removes the hook's
  # root and returning renders a fresh one that hydrates from its own reply.
  @impl true
  def handle_event("set_view", %{"view" => view}, socket) when view in ["map", "list"] do
    {:noreply,
     socket
     |> assign(:view, String.to_existing_atom(view))
     |> assign(:map_mounted?, false)}
  end

  def handle_event("set_view", _params, socket), do: {:noreply, socket}

  # Opening a review is a read: the domain reports, from current database values,
  # what each selected stop would change to, and which of its sibling platforms
  # the selection does not cover (AC-9). The target of an assign review is the
  # zone the operator is filtering by when the inventory still carries it, else
  # the first zone; an unassign review has no target at all, which the domain
  # reads as nil.
  @impl true
  def handle_event("open_assignment", %{"mode" => "assign"}, socket) do
    {:noreply, open_assignment(socket, :assign)}
  end

  def handle_event("open_assignment", %{"mode" => "unassign"}, socket) do
    {:noreply, open_assignment(socket, :unassign)}
  end

  def handle_event("open_assignment", _params, socket), do: {:noreply, socket}

  # The select's value is a zone ID of this version's inventory, byte-exact. A
  # value the inventory does not carry is a zone another editor removed, so the
  # review is rebuilt against the current inventory with that said out loud.
  @impl true
  def handle_event("change_assignment_target", %{"target" => target}, socket)
      when is_binary(target) do
    case socket.assigns.assignment do
      %{mode: :assign} -> {:noreply, review(socket, :assign, target: target)}
      _assignment -> {:noreply, socket}
    end
  end

  def handle_event("change_assignment_target", _params, socket), do: {:noreply, socket}

  # A refresh re-reads the review from current values, so a stale review becomes
  # savable again with the counts the database now reports. The target is kept:
  # choosing it was part of the work the operator must not lose.
  @impl true
  def handle_event("refresh_assignment", _params, socket) do
    case socket.assigns.assignment do
      %{mode: mode, target: target} ->
        {:noreply, socket |> load_workspace() |> review(mode, target: target)}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_assignment", _params, socket) do
    {:noreply, assign(socket, :assignment, nil)}
  end

  # Save writes exactly the reviewed changes. Success clears the selection and
  # reloads the workspace, so the rows and the inventory show what was written,
  # and hands the applied changes to Undo; every other outcome leaves the dialog
  # open with the review intact and names what happened.
  @impl true
  def handle_event("apply_assignment", _params, socket) do
    {:noreply, apply_assignment(socket)}
  end

  @impl true
  def handle_event("undo_assignment", _params, socket) do
    {:noreply, undo_assignment(socket)}
  end

  # The helper's prepared card asks for its review. The entry ID comes from the
  # browser, so it is parsed, looked up in this socket's own conversation and
  # checked against the current data before anything on the page changes.
  @impl true
  def handle_event("agent_review_prepared", %{"entry" => id}, socket) do
    {:noreply, review_prepared_assignment(socket, id)}
  end

  def handle_event("agent_review_prepared", _params, socket), do: {:noreply, socket}

  # Opening the drawer is a read of the inventory the page already holds: create
  # starts from an empty form, and edit starts from the entry the panel shows,
  # whose exact stored `zone_id` bytes are the form's own ID value and the key
  # every later call carries. An ID no longer in the inventory changes nothing.
  @impl true
  def handle_event("open_zone_drawer", params, socket) when is_map(params) do
    {:noreply, open_zone_drawer(socket, params)}
  end

  def handle_event("open_zone_drawer", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_zone_drawer", _params, socket) do
    {:noreply, close_zone_drawer(socket)}
  end

  # Validation is the domain's own form changeset, so the drawer rejects exactly
  # what the write would reject and an unchanged field is not a change at all.
  @impl true
  def handle_event("validate_zone", %{"zone" => params}, socket) do
    {:noreply, validate_zone(socket, params)}
  end

  def handle_event("validate_zone", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_zone", %{"zone" => params}, socket) do
    {:noreply, save_zone(socket, params)}
  end

  def handle_event("save_zone", _params, socket), do: {:noreply, socket}

  # `Delete zone…` in an edit drawer. The drawer closes because the confirm
  # replaces it, and the zone's counts are captured now: they are the fence
  # `delete_zone/4` compares against, so the write can only see a zone whose
  # membership is what the operator was shown (AC-16).
  @impl true
  def handle_event("open_delete_zone", params, socket) when is_map(params) do
    {:noreply, open_delete_zone(socket, params)}
  end

  def handle_event("open_delete_zone", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_replacement", %{"replacement" => replacement}, socket)
      when is_binary(replacement) do
    {:noreply, change_replacement(socket, replacement)}
  end

  def handle_event("change_replacement", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_delete_zone", _params, socket) do
    {:noreply, assign(socket, :zone_delete, nil)}
  end

  @impl true
  def handle_event("delete_zone", _params, socket) do
    {:noreply, delete_zone(socket)}
  end

  # Copy of GaragesLive's version handlers, pointed at the current tab so a
  # version switch keeps the operator on the workspace view they were reading.
  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: zones_path(version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: zones_path(version_id))}
    else
      {:noreply, socket}
    end
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
      <div id="fares-page" class="ds-page">
        <.back_link id="settings-back" navigate={~p"/gtfs/#{@current_gtfs_version.id}/settings"}>
          Settings
        </.back_link>

        <.header>
          Fares
          <:subtitle>
            What riders pay and which fare each ride charges. Exports include both GTFS fare formats.
          </:subtitle>
          <%!-- One primary per view, and it follows the task: Create zone while no
          stop is selected, then Assign zone in the selection bar. A first-use or
          empty state carries its own single primary, so the header's goes away. --%>
          <:actions :if={@live_action == :zones and not first_use?(assigns)}>
            <.button
              :if={@load_state == :ready}
              id="agent-helper-open"
              type="button"
              phx-click="agent_open"
              aria-expanded={to_string(@agent_open?)}
              aria-controls="agent-panel"
              variant="quiet"
              class="min-h-11"
            >
              Open helper
            </.button>
            <.button
              id="fare-zone-create"
              variant={if MapSet.size(@selection) > 0, do: "secondary", else: "primary"}
              class="min-h-11"
              phx-click="open_zone_drawer"
              phx-value-opener_id="fare-zone-create"
              disabled={@load_state != :ready}
            >
              <.icon name="hero-plus" class="size-4" /> Create zone
            </.button>
          </:actions>
        </.header>

        <.fares_tabs
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@live_action}
          checks_count={if @load_state == :ready, do: checks_count(@checks), else: nil}
          checks_tone={if @load_state == :ready, do: checks_tone(@checks), else: nil}
        />

        <%!-- The workspace and the helper panel share one row from 1024px. Below that the
        panel stacks above the workspace, where the `Open helper` button that opened it
        sits. The panel's focus listener belongs to this wrapper, which survives the
        panel and the assignment dialog. --%>
        <div
          id="fares-helper-layout"
          phx-hook=".FaresHelperFocus"
          class={[
            "flex flex-col lg:grid lg:gap-6",
            @agent_open? && "lg:grid-cols-[minmax(0,1fr)_24rem]"
          ]}
        >
          <div class="min-w-0">
            <%!-- One column that may shrink below its content: a card is `overflow-clip`,
            so without `minmax(0, 1fr)` a wide table would stretch the page instead. --%>
            <div class="mt-4 grid grid-cols-1 gap-4">
              <.loading :if={@load_state == :loading} />

              <.message :if={@notice} id="fare-zone-notice" kind="success" title={@notice} />

              <.load_error :if={@load_state == :unavailable} />

              <%= if @load_state == :ready do %>
                <.first_use_empty :if={@live_action == :zones and @inventory.zones == []} />

                <.saved_callout
                  :if={@undo && @live_action == :zones && @inventory.zones != []}
                  undo={@undo}
                />

                <section
                  :if={@live_action == :zones and @inventory.zones != []}
                  id="fare-zones-panel"
                  aria-label="Fare zones and stops"
                  class="overflow-clip rounded-card border border-subtle bg-white"
                >
                  <div class="flex flex-wrap items-end gap-x-5 gap-y-3 px-4 py-3 sm:px-5">
                    <.zone_inventory
                      inventory={@inventory}
                      filter={@filter}
                      patch_base={~p"/gtfs/#{@current_gtfs_version.id}/settings/fares/zones"}
                    />
                    <.stop_search q={@q} />
                  </div>

                  <.stage_header
                    title={stage_title(@filter, @inventory)}
                    subtitle={stage_subtitle(@filter, @inventory)}
                    view={@view}
                  >
                    <:actions :if={stage_zone_id(@filter, @inventory)}>
                      <.button
                        id="fare-zone-edit"
                        variant="secondary"
                        class="min-h-11"
                        phx-click="open_zone_drawer"
                        phx-value-zone_id={stage_zone_id(@filter, @inventory)}
                        phx-value-opener_id="fare-zone-edit"
                      >
                        Edit zone
                      </.button>
                    </:actions>
                  </.stage_header>

                  <%!-- The workspace is one fixed-height region from 1024px: the map and
                  the list are equal columns and each scrolls on its own, so the map never
                  leaves the screen while the list scrolls. Below that they stack, map
                  first. --%>
                  <div
                    id="fare-zone-stage"
                    class={[
                      "grid grid-cols-1",
                      @view == :map && "lg:h-[clamp(420px,calc(100dvh-486px),760px)] lg:grid-cols-2",
                      @view == :list && "lg:h-[clamp(420px,calc(100dvh-486px),760px)]"
                    ]}
                  >
                    <%!-- The map is the stage's first surface in Map and list view:
                    choosing List removes the root and its hook, and Retry map renders it
                    again, where the new mount hydrates from its own reply. The legend
                    stays under the fallback: the colors it names are the ones the list
                    shows. --%>
                    <div
                      :if={@view == :map}
                      id="fare-zone-map-panel"
                      class="flex min-h-0 min-w-0 flex-col max-lg:border-b max-lg:border-subtle lg:border-r lg:border-subtle"
                    >
                      <.zone_map :if={@map_state == :ready} />
                      <.map_unavailable :if={@map_state == :unavailable} />
                      <.map_legend zones={@inventory.zones} />
                    </div>

                    <.stop_list
                      stops={@streams.stops}
                      stop_page={@stop_page}
                      zones={@inventory.zones}
                      filter={@filter}
                      q={@q}
                      view={@view}
                      patch_base={~p"/gtfs/#{@current_gtfs_version.id}/settings/fares/zones"}
                      selection={@selection}
                      matching_count={MapSet.size(@matching_ids)}
                    />
                  </div>

                  <.selection_bar selection={@selection} matching_ids={@matching_ids} />
                </section>
              <% end %>
            </div>
          </div>

          <div
            :if={@agent_open?}
            class="order-first mb-5 mt-4 min-w-0 lg:order-last lg:mb-0 lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)]"
          >
            <.agent_panel
              id="agent-panel"
              title={@agent_title}
              intro={@agent_intro}
              examples={@agent_examples}
              scope_line={"Fare zones · #{@current_gtfs_version.name}"}
              status={@agent_status}
              entries={@streams.agent_entries}
              form={@agent_form}
              notice={@agent_notice}
              entries_empty?={@agent_entries_empty?}
              review_label="Review assignment"
              composer_hint="Prepares a review. You save it on this page."
            />
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".FaresHelperFocus">
          export default {
            mounted() {
              this.handleEvent("agent:focus", ({id}) => document.getElementById(id)?.focus())
            }
          }
        </script>

        <.assignment_dialog
          :if={@assignment}
          assignment={@assignment}
          zones={inventory_zones(assigns)}
        />

        <.delete_zone_dialog
          :if={@zone_delete}
          zone_delete={@zone_delete}
          zones={inventory_zones(assigns)}
          return_focus_id={@zone_delete_return_focus_id}
        />

        <.zone_drawer
          open={@zone_drawer_open}
          entity={@zone_drawer_entry}
          form={@zone_form}
          version_name={@current_gtfs_version.name}
          error={@zone_error}
          return_focus_id={@zone_return_focus_id}
        />
      </div>
    </Layouts.app>
    """
  end

  # The Zones tab's first-use state replaces the workspace, so the header's Create
  # zone goes with it: the empty state carries the one primary. Before the load
  # resolves there is no inventory to judge, so the header action shows (disabled).
  defp first_use?(%{load_state: :ready, inventory: %{zones: []}}), do: true
  defp first_use?(_assigns), do: false

  # The stop page is only meaningful on the Zones tab, where the filter, search
  # and page come from the URL. `filter=unassigned` is its own key so a zone
  # literally named "unassigned" cannot collide with the unassigned filter.
  defp zones_params(:zones, params) do
    {stop_filter(params), Values.presence(params["q"]),
     Values.positive_integer(params["page"], 1)}
  end

  defp zones_params(_action, _params), do: {:all, nil, 1}

  defp stop_filter(%{"zone" => zone}) when is_binary(zone) and zone != "", do: {:zone, zone}
  defp stop_filter(%{"filter" => "unassigned"}), do: :unassigned
  defp stop_filter(_params), do: :all

  # The stop list's search and pagination both patch the Zones path, carrying the
  # filter that is currently selected. The filter's value is byte-exact and the
  # query is assembled by `URI.encode_query/1`, so a zone ID with a space or a
  # reserved character survives the round trip.
  defp zones_url(socket, query) do
    path = ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/settings/fares/zones"
    query = stop_filter_query(socket.assigns.filter) ++ query

    case query do
      [] -> path
      query -> path <> "?" <> URI.encode_query(query)
    end
  end

  defp stop_filter_query(:unassigned), do: [filter: "unassigned"]
  defp stop_filter_query({:zone, zone_id}), do: [zone: zone_id]
  defp stop_filter_query(:all), do: []

  defp search_query(q) when is_binary(q) and q != "", do: [q: q]
  defp search_query(_q), do: []

  defp load_workspace(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    opts = [
      filter: socket.assigns.filter,
      q: socket.assigns.q,
      page: socket.assigns.page
    ]

    case Gtfs.load_fare_workspace(organization_id, gtfs_version_id, opts) do
      {:ok, %{inventory: inventory, checks: checks, stops: stop_page}} ->
        socket
        |> assign(:inventory, inventory)
        |> assign(:checks, checks)
        |> assign(:stop_page, stop_page)
        |> assign(:matching_ids, matching_ids(organization_id, gtfs_version_id, socket))
        |> stream(:stops, stop_page.entries, reset: true)
        |> assign(:load_state, :ready)
        |> resolve_zone_filter(inventory)
        |> sync_map_filter()
        |> push_pending_map_snapshot()

      {:error, :unavailable} ->
        # The previous load stays in assigns so a failed refresh never erases
        # values a later step can still render; the state decides what is shown.
        # The stage body goes with the error callout, so the map's hook is gone
        # and nothing is pushed to it until Reload renders a fresh one.
        socket
        |> assign(:load_state, :unavailable)
        |> unmount_map()
    end
  end

  # The filter the map dims by is a delta, so it is pushed when it actually
  # changed: a search or a page patch reloads the workspace without touching it.
  defp sync_map_filter(socket) do
    if socket.assigns.map_mounted? and socket.assigns.map_filter != socket.assigns.filter do
      socket
      |> assign(:map_filter, socket.assigns.filter)
      |> push_event("fare_zone_filter", %{filter: map_filter_payload(socket.assigns.filter)})
    else
      socket
    end
  end

  # A rename or a delete invalidates the whole map state - the stored IDs every
  # point carries moved with it - so the snapshot cannot be built from the
  # inventory the write replaced. The write marks the next load, which is the
  # first moment the fresh state is in hand, and this pushes the snapshot from
  # exactly there.
  defp push_pending_map_snapshot(socket) do
    if socket.assigns.map_snapshot_after_load do
      socket
      |> assign(:map_snapshot_after_load, false)
      |> push_map_snapshot()
    else
      socket
    end
  end

  # The current filter and search match as UUIDs, kept beside the page so the
  # head can offer "Select all N matching" without a second round trip per click,
  # and so the bar can count the selection the filter cannot show. One scoped
  # read per load: a page of 10,000 stops is one 222 ms query (EV-11), and the
  # selection itself holds UUIDs only.
  defp matching_ids(organization_id, gtfs_version_id, socket) do
    organization_id
    |> FareZones.matching_stop_ids(gtfs_version_id,
      filter: socket.assigns.filter,
      q: socket.assigns.q
    )
    |> MapSet.new()
  end

  # The rows this browser rendered, which the load already restricted to the
  # version's boardable stops, so no second read is needed to select the page.
  defp page_ids(%{assigns: %{stop_page: %{entries: entries}}}), do: MapSet.new(entries, & &1.id)
  defp page_ids(_socket), do: MapSet.new()

  defp toggle_stop(socket, id) do
    cond do
      MapSet.member?(socket.assigns.selection, id) ->
        socket
        |> assign_selection(MapSet.delete(socket.assigns.selection, id))
        |> restream_stop(id)

      known_stop?(socket, id) ->
        socket
        |> assign_selection(MapSet.put(socket.assigns.selection, id))
        |> restream_stop(id)

      true ->
        socket
    end
  end

  # The IDs a dragged box reported, cast and then filtered to this version's own
  # boardable stops in one scoped read. Casting first matters: the domain compares
  # UUIDs in SQL, so a value that is not a UUID is dropped before it can raise,
  # and the read's scope drops UUIDs of another organization or version, stations
  # and unlocated stops alike.
  defp known_stop_ids(socket, ids) do
    uuids =
      ids
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)

    case uuids do
      [] ->
        []

      uuids ->
        FareZones.matching_stop_ids(
          socket.assigns.current_organization.id,
          socket.assigns.current_gtfs_version.id,
          ids: uuids
        )
    end
  end

  # The one read a checkbox can cause: a valid UUID that this version's own
  # boardable stops contain. Anything else - an ID from another organization or
  # version, a station, or a value that is not a UUID at all - is dropped before
  # it reaches the query, so a crafted event cannot select a row of another tenant
  # or raise on the cast.
  defp known_stop?(socket, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        FareZones.matching_stop_ids(
          socket.assigns.current_organization.id,
          socket.assigns.current_gtfs_version.id,
          ids: [uuid]
        ) == [uuid]

      :error ->
        false
    end
  end

  defp select(socket, ids) do
    socket
    |> assign_selection(MapSet.union(socket.assigns.selection, ids))
    |> restream_page()
  end

  # The one place the selection changes, so the map's delta is never forgotten:
  # the hook rings newly selected stops and drops the rings of removed ones, and
  # it learns of both from this push rather than from a re-render it cannot see
  # (the root is `phx-update="ignore"`). A change is pushed only while a hook is
  # mounted; a map that mounts later receives the whole selection in its reply.
  defp assign_selection(socket, selection) do
    added = selection |> MapSet.difference(socket.assigns.selection) |> MapSet.to_list()
    removed = socket.assigns.selection |> MapSet.difference(selection) |> MapSet.to_list()

    socket = assign(socket, :selection, selection)

    if socket.assigns.map_mounted? and (added != [] or removed != []) do
      push_event(socket, "fare_zone_selection", %{added: added, removed: removed})
    else
      socket
    end
  end

  # Re-sending the page's rows keeps each rendered checkbox with the state behind
  # it. The toggled row is inserted in place, so the browser keeps the focus the
  # operator toggled it with.
  defp restream_stop(socket, id) do
    case Enum.find(page_entries(socket), &(&1.id == id)) do
      nil -> socket
      stop -> stream_insert(socket, :stops, stop)
    end
  end

  defp restream_page(socket) do
    stream(socket, :stops, page_entries(socket), reset: true)
  end

  defp page_entries(%{assigns: %{stop_page: %{entries: entries}}}), do: entries
  defp page_entries(_socket), do: []

  # A tab change replaces the workspace the assignment belonged to, so the Undo of
  # the previous save goes with it; a filter, search or page patch inside the Zones
  # tab keeps the same action and keeps Undo in reach (AC-25). A version switch
  # navigates and remounts the LiveView, so its own state is already empty.
  #
  # The comparison is against the action the last handled URL belonged to, not
  # against `socket.assigns.live_action`: LiveView assigns the incoming action
  # before it calls this function, so that comparison would always be true and no
  # tab change would ever end Undo.
  defp undo_after_patch(socket, action) do
    if action == socket.assigns.workspace_action, do: socket.assigns.undo, else: nil
  end

  # What a zone save reported belongs to the same workspace a patch inside the
  # Zones tab keeps, so it survives a filter, search or page patch and goes with
  # the tab when the operator leaves it.
  defp notice_after_patch(socket, action) do
    if action == socket.assigns.workspace_action, do: socket.assigns.notice, else: nil
  end

  # The create form with the reference's default color already selected, so a
  # new zone does not silently start on the palette's first entry.
  defp new_zone_form do
    to_form(FareZones.change_zone(nil, %{"color" => @new_zone_color}), as: :zone)
  end

  # A create opens an empty form; an edit opens the entry the panel shows, whose
  # exact stored ID bytes drive the changeset's byte-for-byte decision and whose
  # counts become the drawer's summary. An edit whose ID is no longer in the
  # inventory is ignored: the click raced the change that removed the zone.
  defp open_zone_drawer(socket, %{"zone_id" => zone_id} = params) when is_binary(zone_id) do
    case zone_entry(socket, zone_id) do
      nil ->
        socket

      entry ->
        socket
        |> assign(:zone_drawer_open, true)
        |> assign(:zone_drawer_zone_id, entry.zone_id)
        |> assign(:zone_drawer_entry, entry)
        |> assign(:zone_form, to_form(FareZones.change_zone(zone_struct(entry), %{}), as: :zone))
        |> assign(:zone_error, nil)
        |> assign(:zone_return_focus_id, params["opener_id"])
    end
  end

  defp open_zone_drawer(socket, params) do
    socket
    |> assign(:zone_drawer_open, true)
    |> assign(:zone_drawer_zone_id, nil)
    |> assign(:zone_drawer_entry, nil)
    |> assign(:zone_form, new_zone_form())
    |> assign(:zone_error, nil)
    |> assign(:zone_return_focus_id, params["opener_id"])
  end

  defp close_zone_drawer(socket) do
    socket
    |> assign(:zone_drawer_open, false)
    |> assign(:zone_drawer_zone_id, nil)
    |> assign(:zone_drawer_entry, nil)
    |> assign(:zone_form, new_zone_form())
    |> assign(:zone_error, nil)
  end

  # The closed drawer's form is inert but still in the page, so a save and a
  # validate both do nothing while it is closed: no leftover field value can
  # create a zone the operator is not looking at.
  defp validate_zone(%{assigns: %{zone_drawer_open: false}} = socket, _params), do: socket

  defp validate_zone(socket, params) do
    changeset =
      socket
      |> zone_changeset(params)
      |> Map.put(:action, :validate)

    assign(socket, :zone_form, to_form(changeset, as: :zone))
  end

  # The domain's own form changeset for the drawer: nil creates, an entry edits.
  defp zone_changeset(socket, params) do
    case socket.assigns.zone_drawer_entry do
      nil -> FareZones.change_zone(nil, params)
      entry -> FareZones.change_zone(zone_struct(entry), params)
    end
  end

  # `change_zone/2` reads the stored identity and metadata off the struct, so the
  # form makes the same byte-for-byte decision the write will - without a second
  # read, from the entry the page already loaded (CR-1).
  defp zone_struct(%{zone_id: zone_id, name: name, color: color}) do
    %FareZone{zone_id: zone_id, name: name, color: color}
  end

  defp save_zone(%{assigns: %{zone_drawer_open: false}} = socket, _params), do: socket

  defp save_zone(socket, params) do
    audit = AuditContext.from_assigns(socket.assigns)

    case socket.assigns.zone_drawer_zone_id do
      nil -> save_new_zone(socket, audit, params)
      current_zone_id -> save_zone_edit(socket, audit, current_zone_id, params)
    end
  end

  defp save_new_zone(socket, audit, params) do
    case FareZones.create_zone(audit, params) do
      {:ok, zone} ->
        zone_saved(socket, zone, @zone_created_message, nil)

      {:error, %Ecto.Changeset{} = changeset} ->
        zone_form_error(socket, changeset)

      {:error, :not_found} ->
        assign(socket, :zone_error, @save_failed_message)

      {:error, :forbidden} ->
        socket |> validate_zone(params) |> assign(:zone_error, @save_failed_message)
    end
  end

  defp save_zone_edit(socket, audit, current_zone_id, params) do
    case FareZones.update_zone(audit, current_zone_id, params) do
      {:ok, zone} ->
        zone_saved(socket, zone, @zone_updated_message, current_zone_id)

      {:error, %Ecto.Changeset{} = changeset} ->
        zone_form_error(socket, changeset)

      {:error, :not_found} ->
        zone_edit_not_found(socket, current_zone_id)

      {:error, :forbidden} ->
        socket |> validate_zone(params) |> assign(:zone_error, @save_failed_message)
    end
  end

  # An edit's `:not_found` is one of two things, and each has its own copy: the
  # zone left the inventory between opening the drawer and saving, or the pair is
  # no longer a published version of the organization. Reading the workspace
  # again is what tells them apart, and it also puts the inventory the operator
  # now faces on screen while the drawer stays open with its input.
  defp zone_edit_not_found(socket, current_zone_id) do
    socket = load_workspace(socket)

    if zone_entry(socket, current_zone_id) do
      assign(socket, :zone_error, @save_failed_message)
    else
      assign(socket, :zone_error, @zone_missing_message)
    end
  end

  # A rejected field keeps its message and the operator's input: `to_form/2` reads
  # the changeset's params, so the typed name and color survive beside the error.
  # The hook moves focus to the first invalid field when there is one.
  defp zone_form_error(socket, changeset) do
    socket
    |> assign(:zone_form, to_form(Map.put(changeset, :action, :validate), as: :zone))
    |> push_event("focus_form_error", %{
      form_id: "fare-zone-form",
      fallback_id: "fare-zone-drawer-error"
    })
  end

  # A write happened, so the drawer closes, Undo of the previous assignment save
  # is no longer what the page is about, and the workspace the save changed is read
  # again. The saved zone becomes the filter the way clicking its row does - so a
  # create shows the new zone's own list - except when an edit kept the ID, where
  # the URL already names exactly that zone.
  #
  # `previous_zone_id` is the edit key the write ran under: nil for a create, and
  # the exact stored ID for an edit, which is what tells a rename from a metadata
  # edit. A create adds no point and no color to the map; a metadata edit changes
  # only the zone's name and color; a rename moves the ID every member's point
  # carries, so the map's whole state is stale (CR-8).
  defp zone_saved(socket, zone, message, previous_zone_id) do
    socket =
      socket
      |> close_zone_drawer()
      |> assign(:undo, nil)
      |> assign(:notice, message)

    cond do
      is_binary(previous_zone_id) and previous_zone_id != zone.zone_id ->
        socket
        |> assign(:map_snapshot_after_load, true)
        |> push_patch(to: zone_filter_url(socket, zone.zone_id))

      socket.assigns.filter == {:zone, zone.zone_id} ->
        socket = load_workspace(socket)

        # An edit kept the ID, so the map's points, selection and filter are
        # unchanged and only the zone's name and color are new.
        if is_binary(previous_zone_id), do: push_map_zones(socket), else: socket

      true ->
        push_patch(socket, to: zone_filter_url(socket, zone.zone_id))
    end
  end

  # A zone filter is its own URL state, so the saved zone is patched as its own
  # query key on the verified route rather than appended to the filter that was
  # current (CR-7).
  defp zone_filter_url(socket, zone_id) do
    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/settings/fares/zones?#{[zone: zone_id]}"
  end

  # The inventory entry of a zone filter's exact ID, byte-for-byte.
  defp zone_entry(socket, zone_id) do
    Enum.find(inventory_zones(socket.assigns), &(&1.zone_id == zone_id))
  end

  # Opening the delete dialog is a read of the inventory the page already holds:
  # an ID no longer in it changes nothing, because the click raced the change
  # that removed the zone. Nothing is chosen for the operator: an unreferenced
  # zone starts at No zone, which keeps its stops and only drops their zone, and a
  # zone fare rules use starts with no replacement, so the confirm stays disabled
  # until the operator names the zone that takes over.
  defp open_delete_zone(socket, %{"zone_id" => zone_id} = params) when is_binary(zone_id) do
    case zone_entry(socket, zone_id) do
      nil ->
        socket

      entry ->
        socket
        |> close_zone_drawer()
        |> assign(:zone_delete, delete_state(socket, entry))
        |> assign(:zone_delete_return_focus_id, params["opener_id"])
    end
  end

  defp open_delete_zone(socket, _params), do: socket

  # The dialog's own state. `expected` is the fence and `zone` what the dialog
  # renders; a replacement is kept only while it is one this zone's write would
  # accept, so a value another editor invalidated falls back to no choice instead
  # of leaving the select on a zone that no longer exists.
  defp delete_state(socket, entry, opts \\ []) do
    zones = inventory_zones(socket.assigns)
    replacement = Keyword.get(opts, :replacement)

    replacement = if valid_delete_replacement?(replacement, entry, zones), do: replacement

    %{
      zone: entry,
      replacement: replacement,
      expected: %{stop_count: entry.stop_count, rule_count: entry.rule_count},
      error: Keyword.get(opts, :error),
      stale: Keyword.get(opts, :stale)
    }
  end

  # No choice is a valid state of the dialog: for an unreferenced zone it means No
  # zone, and for a zone fare rules use it is the dialog before the operator has
  # chosen, whose confirm is disabled. A crafted confirm in that state reaches the
  # domain, which refuses it as `:replacement_required`. A chosen zone must be
  # another zone of the inventory, which is exactly what the domain accepts.
  defp valid_delete_replacement?(replacement, entry, zones) do
    cond do
      is_nil(replacement) -> true
      not is_binary(replacement) -> false
      replacement == entry.zone_id -> false
      true -> Enum.any?(zones, &(&1.zone_id == replacement))
    end
  end

  # The select's value arrives from the browser, so it is validated against this
  # version's own inventory before it becomes the replacement: a crafted value
  # changes nothing rather than reaching the write as an invalid one.
  defp change_replacement(%{assigns: %{zone_delete: nil}} = socket, _value), do: socket

  defp change_replacement(socket, value) do
    delete = socket.assigns.zone_delete
    replacement = if value == "", do: nil, else: value

    if valid_delete_replacement?(replacement, delete.zone, inventory_zones(socket.assigns)) do
      assign(socket, :zone_delete, %{delete | replacement: replacement})
    else
      socket
    end
  end

  # Confirming runs the one domain call the step promises and nothing else. The
  # counts the dialog showed travel with it, so a stop or rule that moved since
  # it opened is a refusal rather than a silent move (AC-16).
  defp delete_zone(%{assigns: %{zone_delete: nil}} = socket), do: socket

  defp delete_zone(socket) do
    delete = socket.assigns.zone_delete

    case FareZones.delete_zone(
           AuditContext.from_assigns(socket.assigns),
           delete.zone.zone_id,
           delete.replacement,
           delete.expected
         ) do
      {:ok, _result} ->
        # A write happened, so the workspace is the base path the reference
        # reports from (All stops), the previous assignment save's Undo is no
        # longer what the page is about, and the dialog is done. Deleting a zone
        # moves the stored ID on every member stop and can remove a zone from the
        # map's colors, so the write marks the next load and that load pushes the
        # snapshot: the map is never left drawing the deleted zone.
        socket
        |> assign(:zone_delete, nil)
        |> assign(:undo, nil)
        |> assign(:notice, @zone_deleted_message)
        |> assign(:map_snapshot_after_load, true)
        |> push_patch(
          to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/settings/fares/zones"
        )

      # Another editor changed the zone since the dialog opened. Nothing was
      # written: the dialog stays open on the freshly read entry, states the
      # counts the zone now has, and fences the next confirm against them.
      {:error, {:stale, _zone}} ->
        reopen_delete(socket, :stale)

      {:error, :invalid_replacement} ->
        reopen_delete(socket, :replacement_gone)

      {:error, :replacement_required} ->
        reopen_delete(socket, :replacement_gone)

      {:error, :not_found} ->
        socket
        |> load_workspace()
        |> close_delete(@delete_missing_message)

      {:error, :forbidden} ->
        assign(socket, :zone_delete, %{delete | error: @save_failed_message})
    end
  end

  # A refused delete re-reads the workspace first, so the dialog's counts, its
  # replacement select and the list behind it describe the database as it is
  # now. The dialog stays open with its reason unless the zone itself is gone.
  defp reopen_delete(socket, reason) do
    delete = socket.assigns.zone_delete
    socket = load_workspace(socket)

    case zone_entry(socket, delete.zone.zone_id) do
      nil ->
        close_delete(socket, @delete_missing_message)

      entry ->
        assign(
          socket,
          :zone_delete,
          delete_state(socket, entry, delete_refusal(reason, entry, delete))
        )
    end
  end

  # The two refusals the dialog has copy for. A stale result states the counts
  # it just read, so the sentence and the fence beside it can never disagree; a
  # replacement another editor removed reports the save failure and lets the
  # re-read select offer the zones that exist now.
  defp delete_refusal(:stale, entry, delete) do
    [
      replacement: delete.replacement,
      stale: %{stop_count: entry.stop_count, rule_count: entry.rule_count}
    ]
  end

  defp delete_refusal(:replacement_gone, _entry, delete) do
    [replacement: delete.replacement, error: @save_failed_message]
  end

  defp close_delete(socket, notice) do
    socket
    |> assign(:zone_delete, nil)
    |> assign(:notice, notice)
  end

  defp open_assignment(socket, mode) do
    if MapSet.size(socket.assigns.selection) == 0 do
      socket
    else
      review(socket, mode, [])
    end
  end

  # The review the dialog shows, rebuilt from current values every time it is
  # opened, refreshed or given a new target. An assign review with no target is
  # not one: the domain reads a nil target as "unassign", so an empty inventory
  # stops here with the reason the dialog shows instead of previewing that write.
  #
  # Errors are returned as state rather than thrown: a stale selection and a zone
  # that left the inventory are ordinary outcomes of editing the same version from
  # two places, and both must leave the review on screen (AC-26).
  defp review(socket, mode, opts) do
    target = if mode == :assign, do: Keyword.get(opts, :target, default_target(socket)), else: nil
    error = Keyword.get(opts, :error)
    origin = current_origin(socket)

    if mode == :assign and is_nil(target) do
      assign(socket, :assignment, assignment_state(mode, nil, nil, error, origin))
    else
      case preview(socket, target) do
        {:ok, preview} ->
          assign(socket, :assignment, assignment_state(mode, target, preview, error, origin))

        {:error, :unknown_zone} when mode == :assign ->
          socket
          |> load_workspace()
          |> review(:assign, error: @unknown_zone_message)

        {:error, _reason} ->
          assign(
            socket,
            :assignment,
            assignment_state(mode, target, nil, error || @invalid_selection_message, origin)
          )
      end
    end
  end

  # A review the helper opened keeps its origin while the editor changes the target
  # or the review is rebuilt; a manual review has none.
  defp current_origin(%{assigns: %{assignment: %{origin: origin}}}), do: origin
  defp current_origin(_socket), do: nil

  # The helper handoff. Every refusal is a notice in the panel and no change to the
  # page: an open review, drawer or delete dialog is the editor's work, and a
  # selection of other stops is too. A prepared assignment opens only when the
  # entry is this conversation's, the routes still serve exactly the prepared stops
  # with the zones they had, and the target zone still exists.
  defp review_prepared_assignment(socket, id) do
    with {:ok, entry_id} <- parse_entry_id(id),
         :ok <- require_ready(socket),
         :ok <- require_no_open_work(socket),
         {:ok, prepared} <- fetch_prepared(socket, entry_id),
         {:ok, %{predicate: predicate, stop_ids: stop_ids, target: target} = command} <-
           zone_command(prepared),
         :ok <- require_compatible_selection(socket, stop_ids),
         {:ok, selection} <- current_selection(socket, command),
         :ok <- require_target(socket, stop_ids, predicate, target) do
      open_prepared_assignment(socket, entry_id, prepared, command, selection)
    else
      {:refuse, notice} -> assign(socket, :agent_notice, notice)
    end
  end

  defp parse_entry_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {entry_id, ""} when entry_id > 0 -> {:ok, entry_id}
      _other -> {:refuse, @helper_unavailable_notice}
    end
  end

  defp parse_entry_id(_id), do: {:refuse, @helper_unavailable_notice}

  defp require_ready(%{assigns: %{load_state: :ready, inventory: %{}}}), do: :ok
  defp require_ready(_socket), do: {:refuse, @helper_unavailable_notice}

  defp require_no_open_work(socket) do
    assigns = socket.assigns

    if assigns.assignment || assigns.zone_drawer_open || assigns.zone_delete,
      do: {:refuse, @helper_close_first_notice},
      else: :ok
  end

  defp fetch_prepared(socket, entry_id) do
    case Agents.prepared(
           socket.assigns.agent_session,
           socket.assigns.agent_conversation_id,
           entry_id
         ) do
      {:ok, prepared} -> {:ok, prepared}
      _stale_or_unknown -> {:refuse, @helper_unavailable_notice}
    end
  end

  defp zone_command(%{command: {:zone_assignment, %{stop_ids: [_ | _]} = command}}),
    do: {:ok, command}

  defp zone_command(_prepared), do: {:refuse, @helper_unavailable_notice}

  # The page holds either nothing or exactly the prepared stops: a different
  # selection is work the handoff must not replace.
  defp require_compatible_selection(socket, stop_ids) do
    selection = socket.assigns.selection

    if MapSet.size(selection) == 0 or selection == MapSet.new(stop_ids),
      do: :ok,
      else: {:refuse, @helper_selection_notice}
  end

  defp current_selection(socket, command) do
    case FareZones.route_selection(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           command.predicate
         ) do
      {:ok, %{fingerprint: fingerprint, stops: stops} = selection}
      when fingerprint == command.fingerprint ->
        if Enum.sort(Enum.map(stops, & &1.id)) == Enum.sort(command.stop_ids),
          do: {:ok, selection},
          else: {:refuse, @helper_changed_notice}

      _changed_or_unresolved ->
        {:refuse, @helper_changed_notice}
    end
  end

  defp require_target(socket, stop_ids, _predicate, target) do
    case FareZones.preview_assignment(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           stop_ids,
           target
         ) do
      {:ok, _preview} -> :ok
      {:error, :unknown_zone} -> {:refuse, @helper_zone_gone_notice}
      {:error, :invalid_selection} -> {:refuse, @helper_changed_notice}
    end
  end

  # Each selected stop's other serving routes, by name: the part of the helper's
  # summary the review shows per row.
  defp other_routes(selection, predicate) do
    Map.new(selection.stops, fn stop ->
      names =
        (stop.route_ids -- predicate.route_ids)
        |> Enum.map(&Map.fetch!(selection.route_names, &1))

      {stop.id, names}
    end)
  end

  # The review opens on exactly the prepared stops, against the prepared target,
  # and remembers which card of which conversation it came from.
  defp open_prepared_assignment(socket, entry_id, prepared, command, selection) do
    origin = %{
      session_pid: socket.assigns.agent_session,
      conversation_id: socket.assigns.agent_conversation_id,
      entry_id: entry_id,
      command: {:zone_assignment, command},
      summary: prepared.summary,
      stop_routes: other_routes(selection, command.predicate),
      return_focus_id: "agent-prepared-#{entry_id}",
      changed?: false
    }

    socket
    |> assign_selection(MapSet.new(command.stop_ids))
    |> restream_page()
    |> assign(:agent_notice, nil)
    |> assign(:assignment, %{origin: origin})
    |> review(:assign, target: command.target)
  end

  defp preview(socket, target) do
    FareZones.preview_assignment(
      socket.assigns.current_organization.id,
      socket.assigns.current_gtfs_version.id,
      MapSet.to_list(socket.assigns.selection),
      target
    )
  end

  defp assignment_state(mode, target, preview, error, origin) do
    %{mode: mode, target: target, preview: preview, error: error, stale: 0, origin: origin}
  end

  # Only a current review with something to save is a write. A review whose
  # preview carries no changes has nothing to write, and the dialog says why its
  # button is disabled instead of silently doing nothing.
  defp apply_assignment(%{assigns: %{assignment: nil}} = socket), do: socket
  defp apply_assignment(%{assigns: %{assignment: %{preview: nil}}} = socket), do: socket

  defp apply_assignment(%{assigns: %{assignment: %{preview: %{changes: []}}}} = socket),
    do: socket

  defp apply_assignment(socket) do
    assignment = socket.assigns.assignment

    case FareZones.apply_assignment(
           AuditContext.from_assigns(socket.assigns),
           assignment.preview.changes
         ) do
      {:ok, %{applied: applied}} ->
        # The review is done: the selection it was made from is cleared, and the
        # workspace is read again so the rows show the zones that were written.
        # The map is told both changes - the selection it can no longer ring and
        # the stops whose zone moved - instead of re-reading its own state.
        socket =
          socket
          |> assign_selection(MapSet.new())
          |> load_workspace()
          |> assign(:assignment, nil)
          |> push_map_points_changed(applied)

        assign(socket, :undo, %{
          kind: "success",
          applied: applied,
          message: assigned_copy(assignment.mode, applied, zone_name(socket, assignment.target))
        })

      # A stale result is the whole point of the fence: nothing was written, the
      # stops that moved are counted, and the review stays open to be refreshed.
      {:error, {:stale, stops}} ->
        assign(socket, :assignment, %{assignment | stale: length(stops)})

      {:error, :unknown_zone} ->
        # The target left the inventory since the review was opened: read the
        # workspace again so the select offers the zones that exist now, and
        # review the first valid target with the operator told why theirs is gone.
        socket
        |> load_workspace()
        |> review(assignment.mode, error: @unknown_zone_message)

      {:error, :invalid_selection} ->
        assign(socket, :assignment, %{assignment | error: @invalid_selection_message})

      {:error, :not_found} ->
        assign(socket, :assignment, %{assignment | error: @save_failed_message})

      {:error, :forbidden} ->
        assign(socket, :assignment, %{assignment | error: @save_failed_message})
    end
  end

  defp undo_assignment(%{assigns: %{undo: nil}} = socket), do: socket
  defp undo_assignment(%{assigns: %{undo: %{applied: nil}}} = socket), do: socket

  # Undo runs from the applied changes of the save it reports and nowhere else, so
  # it can only restore what this socket wrote. It restores the exact previous zone
  # bytes, including a zone that left the inventory in the meantime.
  defp undo_assignment(socket) do
    case FareZones.undo_assignment(
           AuditContext.from_assigns(socket.assigns),
           socket.assigns.undo.applied
         ) do
      {:ok, %{applied: applied}} ->
        # `applied` is the undo's own change list, so its `to` is the zone each stop
        # was restored to; the map restyles exactly those stops.
        socket
        |> load_workspace()
        |> assign(:undo, %{kind: "success", applied: nil, message: "Change undone."})
        |> push_map_points_changed(applied)

      {:error, reason} ->
        socket
        |> reload_after_undo(reason)
        |> assign(:undo, %{kind: "error", applied: nil, message: undo_failure_copy(reason)})
    end
  end

  # Undo's own failures: the stops changed after the save it refers to, or the pair
  # is no longer a published version of the organization. Either way nothing was
  # written, the callout states which happened, and the change is not offered again.
  defp undo_failure_copy(:not_found), do: @save_failed_message
  defp undo_failure_copy(:forbidden), do: @save_failed_message
  defp undo_failure_copy(_stale_or_invalid), do: @undo_stale_message

  defp reload_after_undo(socket, :not_found), do: socket
  defp reload_after_undo(socket, :forbidden), do: socket
  defp reload_after_undo(socket, _reason), do: load_workspace(socket)

  defp assigned_copy(:assign, applied, zone_name) do
    "#{Wording.count_noun(length(applied), "stop")} assigned to #{zone_name}."
  end

  defp assigned_copy(:unassign, applied, _zone_name) do
    "#{Wording.count_noun(length(applied), "stop")} unassigned."
  end

  # The inventory's zones, from the LiveView's assigns (the render reads them too,
  # so this takes the assigns map rather than the socket).
  defp inventory_zones(%{inventory: nil}), do: []
  defp inventory_zones(%{inventory: inventory}), do: inventory.zones

  # The whole state a newly mounted map draws from: the version's located
  # boardable points, the color each zone ID has, the selection and the filter. It
  # answers the hook's handshake and is the payload of every `fare_zone_snapshot`,
  # so a remount can never depend on deltas an earlier mount received (CR-8).
  # Points come from the domain's own read, and the colors are the palette hex
  # values the panel and the list already use for the same zones.
  defp map_snapshot(socket) do
    %{
      points:
        FareZones.list_stop_points(
          socket.assigns.current_organization.id,
          socket.assigns.current_gtfs_version.id
        ),
      zones: map_zones(socket),
      selected: socket.assigns.selection |> MapSet.to_list() |> Enum.sort(),
      filter: map_filter_payload(socket.assigns.filter)
    }
  end

  defp map_zones(socket) do
    Map.new(inventory_zones(socket.assigns), fn zone ->
      {zone.zone_id, %{name: zone.name, color: FareZone.color_hex(zone.color)}}
    end)
  end

  # The filter as the hook reads it: a kind it can match, and the exact stored
  # zone ID bytes of a zone filter (INV-3).
  defp map_filter_payload(:all), do: %{kind: "all", zone_id: nil}
  defp map_filter_payload(:unassigned), do: %{kind: "unassigned", zone_id: nil}
  defp map_filter_payload({:zone, zone_id}), do: %{kind: "zone", zone_id: zone_id}

  # `@map_mounted?` is the single gate on every push: a hook that is not in the
  # page has no `handleEvent` to receive one, and a map that mounts later
  # hydrates from its own reply instead.
  defp push_map_snapshot(socket) do
    if socket.assigns.map_mounted? do
      socket
      |> assign(:map_filter, socket.assigns.filter)
      |> push_event("fare_zone_snapshot", map_snapshot(socket))
    else
      socket
    end
  end

  defp push_map_zones(socket) do
    if socket.assigns.map_mounted? do
      push_event(socket, "fare_zone_zones", %{zones: map_zones(socket)})
    else
      socket
    end
  end

  # The stops an assignment save or Undo moved, as `[stop id, zone id or nil]`.
  # A stop the map does not draw (no coordinates) has no marker to restyle and the
  # hook skips it, which is AC-7's located boardable point set.
  defp push_map_points_changed(socket, applied) do
    changes = Enum.map(applied, fn change -> [change.id, change.to] end)

    if socket.assigns.map_mounted? and changes != [] do
      push_event(socket, "fare_zone_points_changed", %{changes: changes})
    else
      socket
    end
  end

  # No map root is in the page (List view, the fallback, a failed load or another
  # tab), so nothing is pushed at it until a new hook mounts and hydrates.
  defp unmount_map(socket) do
    socket
    |> assign(:map_mounted?, false)
    |> assign(:map_filter, nil)
  end

  # The zone the current filter names when the inventory still carries it, else the
  # first zone of the inventory. The IDs are compared byte-for-byte.
  defp default_target(socket) do
    zones = inventory_zones(socket.assigns)

    case socket.assigns.filter do
      {:zone, zone_id} ->
        if Enum.any?(zones, &(&1.zone_id == zone_id)), do: zone_id, else: first_zone_id(zones)

      _filter ->
        first_zone_id(zones)
    end
  end

  defp first_zone_id([%{zone_id: zone_id} | _rest]), do: zone_id
  defp first_zone_id(_zones), do: nil

  # The target's display name for the report of what was written, or its exact ID
  # when the inventory carries no record for it.
  defp zone_name(_socket, nil), do: nil

  defp zone_name(socket, target) do
    case Enum.find(inventory_zones(socket.assigns), &(&1.zone_id == target)) do
      nil -> target
      zone -> zone.name
    end
  end

  # A `zone` value the inventory does not carry - a stale link, or a zone renamed
  # or deleted since the URL was made - shows All stops rather than a filter that
  # matches nothing. The IDs are compared byte-for-byte, never trimmed.
  #
  # The stop page in hand was read for the unknown filter, so it is read again
  # for :all: the list below the header must describe the filter the header and
  # the inventory show. Reading the inventory first is not an option, because
  # the workspace arrives in one load (and this LiveView issues no query of its
  # own).
  defp resolve_zone_filter(%{assigns: %{filter: {:zone, zone_id}}} = socket, inventory) do
    if Enum.any?(inventory.zones, &(&1.zone_id == zone_id)) do
      socket
    else
      socket |> assign(:filter, :all) |> load_workspace()
    end
  end

  defp resolve_zone_filter(socket, _inventory), do: socket

  # The exact stored ID of the zone the current filter names, which the stage
  # header's `Edit zone` action carries as the drawer's edit key (INV-3).
  defp stage_zone_id({:zone, zone_id}, inventory) do
    case Enum.find(inventory.zones, &(&1.zone_id == zone_id)) do
      nil -> nil
      zone -> zone.zone_id
    end
  end

  defp stage_zone_id(_filter, _inventory), do: nil

  # The stage names the stops the filter shows. A zone filter is named by the
  # zone's display name, or by its exact ID when the inventory has no record.
  defp stage_title(:all, _inventory), do: "All stops"
  defp stage_title(:unassigned, _inventory), do: "Stops with no zone"

  defp stage_title({:zone, zone_id}, inventory) do
    case Enum.find(inventory.zones, &(&1.zone_id == zone_id)) do
      nil -> zone_id
      zone -> zone.name
    end
  end

  # Counts are the filter's own: boardable stops of the version, of the zone, or
  # without a zone. A zone's count is its boardable membership, so a zone carried
  # only by stations reads 0 and "Empty zone".
  defp stage_subtitle(:all, inventory),
    do: "#{Wording.count_noun(inventory.boardable_count, "stop")} in this version"

  defp stage_subtitle(:unassigned, inventory),
    do:
      "#{Wording.count_noun(inventory.unassigned_count, "stop")} · trip planners can’t price zone-based journeys that use them"

  defp stage_subtitle({:zone, zone_id}, inventory) do
    case Enum.find(inventory.zones, &(&1.zone_id == zone_id)) do
      nil ->
        "#{Wording.count_noun(0, "stop")} · Zone ID #{zone_id}"

      zone ->
        "#{Wording.count_noun(zone.stop_count, "stop")}#{empty_zone_note(zone)} · #{zone_rules_note(zone)} · Zone ID #{zone_id}"
    end
  end

  defp empty_zone_note(%{stop_count: 0}), do: " · Empty zone"
  defp empty_zone_note(_zone), do: ""

  defp zone_rules_note(%{rule_count: 0}), do: "no fare rules use it"
  defp zone_rules_note(%{rule_count: 1}), do: "used by 1 fare rule"
  defp zone_rules_note(%{rule_count: count}), do: "used by #{count} fare rules"

  # One issue per stopless referenced zone and per fare whose rules trip planners
  # combine, plus one for unassigned stops. The caller passes nil while the
  # workspace load has not resolved, so the badge never claims a clean version on
  # data nobody has read yet.
  defp checks_count(%{
         stopless_referenced: stopless,
         unassigned_count: unassigned,
         combined_fares: combined
       }) do
    length(stopless) + length(combined) + if unassigned > 0, do: 1, else: 0
  end

  # The tab's mark reads as the worst finding: a zone rules use with no stops is
  # a repair, stops with no zone a review, and neither is all clear.
  defp checks_tone(%{stopless_referenced: [_ | _]}), do: :error
  defp checks_tone(%{unassigned_count: unassigned}) when unassigned > 0, do: :warning
  defp checks_tone(_checks), do: :ok

  defp zones_path(version_id), do: ~p"/gtfs/#{version_id}/settings/fares/zones"
end
