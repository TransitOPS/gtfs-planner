defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesLive do
  @moduledoc """
  LiveView for one route's Schedules view: the timetable read plus the trip
  drawers, row actions, the sticky grid bar and the delete confirmations.

  The route, calendar, direction, pattern and stop columns are URL parameters, so
  reload, back and forward restore the same view; a missing, unknown or invalid
  value is canonicalized with a replace patch. Everything on the page comes from
  one scoped read through `GtfsPlanner.Gtfs.load_route_schedule/4` and the
  configured catalog adapter, whose production implementation is
  `GtfsPlanner.Gtfs.CatalogReadAdapter.Repo`.

  Sections are a stream: counts and flags live in separate assigns because a
  stream is neither enumerable nor countable, and a selection toggle re-inserts
  only the section it changed. Selection is never in the URL and clears when the
  parameters change. A failed refresh keeps the sections already on screen, so a
  read outage is never shown as an empty route.

  Every mutating event re-reads the editor role before it calls the context, and
  every identifier it uses is resolved against the page's own loaded scope or
  handed to the context, which resolves it again against the organization,
  version, route and calendar. A mutation reloads through the adapter afterwards
  and shows the vehicle "N → M" marker when the count moved.

  A bulk verb opens a reviewed command instead: the LiveView reviews it through
  the context, previews the reviewed times in the grid without writing, and
  applies it with the review's fingerprint as the fence (R3), so a trip another
  editor changed between the review and the apply is never overwritten.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1]

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Headsigns
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Schedules.FrequencyWindows
  alias GtfsPlanner.Gtfs.Schedules.Summary
  alias GtfsPlanner.Gtfs.Schedules.TimeEntry
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.AgentPanel
  alias GtfsPlannerWeb.EnsureRole
  alias GtfsPlannerWeb.Gtfs.ScheduleChangeComponents
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  on_mount({GtfsPlannerWeb.EnsureRole, :require_gtfs_access})

  @filter_keys ~w(service_id direction pattern stops custom)
  @drawer_fields ~w(pattern_id timed_pattern_id service_id start_time repeat every until
    run_as windows exact_times trip_headsign trip_short_name wheelchair_accessible
    bikes_allowed)
  # The trip details a frequency edit saves after its windows.
  @frequency_detail_keys ~w(service_id trip_headsign trip_short_name wheelchair_accessible
    bikes_allowed)
  @duplicate_offset_secs 1_800
  # A `:copy` offset is a whole minute inside ±24 h (TripChanges.validate_offset/1),
  # so a typed "first departure at" further away is not a time this page can paste.
  @max_copy_offset_secs 86_400
  @paste_time_error "Enter the time the first trip leaves, for example 16:30."
  @undo_limit 20
  @nudge_minutes [-5, -1, 1, 5]
  @max_shift_minutes 1_440
  @default_departure "06:00"
  @default_every "30"
  @default_until "09:00"
  # The Add drawer's frequency mode starts from one window the drawer can already
  # read, so switching the run-as choice lands on a valid editor instead of an
  # empty list (R8). A new window is two hours long, like the reference's.
  @default_window %{from: @default_departure, until: @default_until, every: @default_every}
  @window_hours 2

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Schedules")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:route_id, nil)
     |> assign(:route, nil)
     |> assign(:payload, nil)
     |> assign(:filters, nil)
     |> assign(:requested, %{})
     |> assign(:load_state, :loading)
     |> assign(:section_index, %{})
     |> assign(:sections_list, [])
     |> assign(:sections_empty?, true)
     |> assign(:rows_in_view, 0)
     |> assign(:custom_filter?, false)
     |> assign(:custom_count, 0)
     |> assign(:can_add?, false)
     |> assign(:add_reason, nil)
     |> assign(:any_trips?, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:selected_count, 0)
     |> assign(:grid_revision, 0)
     |> assign(:undo_stack, [])
     |> assign(:outcome, nil)
     |> assign(:just_changed, MapSet.new())
     |> assign(:cell_error, nil)
     |> assign(:change, nil)
     |> assign(:clipboard, nil)
     |> assign(:shortcuts_open?, false)
     |> assign(:shortcuts_return_focus_id, nil)
     |> assign(:vehicle_change, nil)
     |> assign(:vehicle_change_from, nil)
     |> assign(:keep_vehicle_change, false)
     |> assign(:drawer, nil)
     |> assign(:block_notice, nil)
     |> assign(:delete_dialog, nil)
     |> assign(:calendar_form, to_form(%{"service_id" => nil}))
     |> assign(:pattern_form, to_form(%{"pattern" => "all"}))
     |> stream_configure(:sections, dom_id: &"section-#{&1.pattern.route_pattern_id}")
     |> stream(:sections, [])
     |> AgentPanel.mount("service_queries")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    cleared_selection? = clearing_selection?(socket, params)

    socket =
      socket
      |> assign(:route_id, params["route_id"])
      |> assign(:requested, params)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:selected_count, 0)
      # A review names the trips the page loaded when it opened, so a parameter
      # change closes it (step 27's filter change clears the selection first).
      # The clipboard names the same rows, so a parameter change drops it too:
      # pasting is a page-session action, never a cross-view one (§7).
      |> assign(:change, nil)
      |> assign(:clipboard, nil)
      |> assign(:delete_dialog, nil)
      |> assign(:block_notice, nil)
      |> clear_vehicle_change()
      |> report_cleared_selection(cleared_selection?)

    if connected?(socket) do
      {:noreply, socket |> load_schedule(params) |> bind_agent_context()}
    else
      {:noreply, socket |> assign(:load_state, :loading) |> bind_agent_context()}
    end
  end

  # The helper conversation belongs to the route this page is showing, so the
  # context is replaced from ordinary parameter handling (INV-1). Navigating from
  # one route to another detaches the prior session and clears this panel's
  # transcript; a page whose route did not load falls back to the whole-version
  # context, which the Schedule pack refuses with the one unavailable result.
  defp bind_agent_context(socket) do
    identity =
      case socket.assigns[:route] do
        %GtfsPlanner.Gtfs.Route{} = route -> {:route, route.id}
        _other -> {:version, socket.assigns.current_gtfs_version.id}
      end

    AgentPanel.set_context(socket, Scope.context(identity))
  end

  # The selection is page state, so a parameter change clears it. Only a change
  # to a filter the user can see is worth explaining: the first render, a
  # canonicalizing replace patch and a dispatch that carries the same filters
  # report nothing, and a patch with nothing selected never says it cleared one.
  defp clearing_selection?(socket, params) do
    MapSet.size(socket.assigns.selected_ids) > 0 and
      Map.take(params, @filter_keys) != Map.take(socket.assigns.requested, @filter_keys)
  end

  defp report_cleared_selection(socket, false), do: socket

  defp report_cleared_selection(socket, true) do
    assign(socket, :outcome, %{
      tone: :info,
      text: "Selection cleared because the filter changed.",
      undo?: false
    })
  end

  @impl true
  def handle_event("filters", params, socket) do
    case socket.assigns.filters do
      nil ->
        {:noreply, socket}

      filters ->
        merged =
          merged_filters(filters, params, socket.assigns.custom_filter?)

        {:noreply, push_patch(socket, to: schedule_path(socket, merged))}
    end
  end

  @impl true
  def handle_event("toggle_trip", %{"trip" => trip_id}, socket) do
    case find_section(socket, trip_id) do
      nil ->
        {:noreply, socket}

      {_dom_id, section} ->
        selected =
          if MapSet.member?(socket.assigns.selected_ids, trip_id),
            do: MapSet.delete(socket.assigns.selected_ids, trip_id),
            else: MapSet.put(socket.assigns.selected_ids, trip_id)

        {:noreply, reselect(socket, section, selected)}
    end
  end

  @impl true
  def handle_event("toggle_section", %{"section" => dom_id}, socket) do
    case Map.get(socket.assigns.section_index, dom_id) do
      nil ->
        {:noreply, socket}

      section ->
        ids = Enum.map(section.rows, & &1.id)

        selected =
          if ids != [] and Enum.all?(ids, &MapSet.member?(socket.assigns.selected_ids, &1)),
            do: Enum.reduce(ids, socket.assigns.selected_ids, &MapSet.delete(&2, &1)),
            else: Enum.into(ids, socket.assigns.selected_ids)

        {:noreply, reselect(socket, section, selected)}
    end
  end

  @impl true
  def handle_event("select_range", %{"from" => from, "to" => to}, socket) do
    {:noreply, select_range(socket, from, to)}
  end

  def handle_event("select_range", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_all", _params, socket), do: {:noreply, select_all(socket)}

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, apply_selection(socket, MapSet.new())}
  end

  @impl true
  def handle_event(
        "cell_preview",
        %{"trip" => trip_id, "position" => position, "text" => text},
        socket
      ) do
    {:reply, cell_preview(socket, trip_id, position, text), socket}
  end

  def handle_event("cell_preview", _params, socket) do
    {:reply, %{ok: false, message: ScheduleComponents.save_failure_copy()}, socket}
  end

  @impl true
  def handle_event(
        "cell_commit",
        %{"trip" => trip_id, "position" => position, "text" => text, "mode" => mode},
        socket
      ) do
    case commit_cell(socket, trip_id, position, text, mode) do
      {:ok, socket} -> {:reply, %{ok: true}, socket}
      {:error, socket, message} -> {:reply, %{ok: false, message: message}, socket}
    end
  end

  def handle_event("cell_commit", _params, socket) do
    {:reply, %{ok: false, message: ScheduleComponents.save_failure_copy()}, socket}
  end

  @impl true
  def handle_event("cell_clear", %{"trip" => trip_id, "position" => position}, socket) do
    {:reply, %{}, clear_cell(socket, trip_id, position)}
  end

  def handle_event("cell_clear", _params, socket), do: {:reply, %{}, socket}

  @impl true
  def handle_event("nudge", %{} = params, socket) do
    {:noreply, nudge(socket, params)}
  end

  def handle_event("nudge", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("undo", _params, socket), do: {:noreply, undo(socket)}

  @impl true
  def handle_event("save_shortcut", _params, socket), do: {:noreply, save_shortcut(socket)}

  @impl true
  def handle_event("toggle_shortcuts", params, socket) do
    {:noreply, toggle_shortcuts(socket, params)}
  end

  @impl true
  def handle_event("open_change", %{"kind" => kind} = params, socket) do
    {:noreply, open_change(socket, kind, params["trip"])}
  end

  def handle_event("open_change", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_params", %{} = params, socket) do
    {:noreply, update_change(socket, params)}
  end

  def handle_event("change_params", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("apply_change", _params, socket), do: {:noreply, apply_change(socket)}

  @impl true
  def handle_event("refresh_change", _params, socket), do: {:noreply, refresh_change(socket)}

  @impl true
  def handle_event("cancel_change", _params, socket), do: {:noreply, cancel_change(socket)}

  # Copy trips keeps the selection's UUIDs in this process (INV-6, §7's
  # server-held clipboard) and reports the shortcut that pastes them. The paste
  # events are the grid hook's: `paste_trips` opens the dialog and replies
  # whether the server clipboard exists, so the hook reports a spreadsheet paste
  # only when this page has nothing to paste (AC-16).
  @impl true
  def handle_event("copy_trips", _params, socket), do: {:noreply, copy_trips(socket)}

  @impl true
  def handle_event("paste_trips", _params, socket) do
    {reply, socket} = paste_trips(socket)
    {:reply, reply, socket}
  end

  @impl true
  def handle_event("paste_text", _params, socket), do: {:noreply, paste_text(socket)}

  @impl true
  def handle_event("retry", _params, socket) do
    {:noreply, load_schedule(socket, socket.assigns.requested)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    switch_version(socket, version_id)
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    switch_version(socket, version_id)
  end

  # The shared banner's Reactivate: the step-9 status command with this page's
  # saved identity, projected from the scoped route read through the same
  # source shape the details workspace uses. The role is re-read first, like
  # every other mutating event here, and the schedule reloads so the banner
  # describes what is stored now.
  @impl true
  def handle_event("reactivate_route", _params, socket) do
    if editor_access?(socket) do
      do_reactivate_route(socket)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "You no longer have editor access to this organization. The route's status is unchanged."
       )}
    end
  end

  # --- drawers ---------------------------------------------------------------

  @impl true
  def handle_event("open_add_drawer", _params, socket) do
    case add_drawer_pattern(socket) do
      nil ->
        {:noreply, socket}

      pattern ->
        timing = List.first(pattern.timings)

        drawer =
          new_drawer(socket, :add, %{
            values: %{
              "pattern_id" => pattern.id,
              "timed_pattern_id" => timing && timing.id,
              "service_id" => socket.assigns.filters.service_id,
              "start_time" => @default_departure,
              "repeat" => "false",
              "every" => @default_every,
              "until" => @default_until,
              "run_as" => "scheduled",
              "windows" => [@default_window],
              "exact_times" => "1"
            },
            return_focus_id: "schedules-add-trips"
          })

        {:noreply,
         socket
         |> assign(:block_notice, nil)
         |> assign(:drawer, refresh_drawer(socket, drawer))}
    end
  end

  @impl true
  def handle_event("open_edit_drawer", %{"trip" => trip_id}, socket) do
    case find_row(socket, trip_id) do
      nil ->
        {:noreply, socket}

      row ->
        drawer =
          new_drawer(socket, :edit, %{
            trip: row,
            values: edit_values(socket, row),
            block_day_key: block_day_key(socket, row),
            return_focus_id: "trip-#{row.trip_id}-edit"
          })

        {:noreply,
         socket
         |> assign(:block_notice, nil)
         |> assign(:drawer, refresh_drawer(socket, drawer))}
    end
  end

  @impl true
  def handle_event("open_duplicate_drawer", %{"trip" => trip_id}, socket) do
    case find_row(socket, trip_id) do
      nil ->
        {:noreply, socket}

      row ->
        drawer =
          new_drawer(socket, :duplicate, %{
            trip: row,
            values: duplicate_values(socket, row),
            return_focus_id: "trip-#{row.trip_id}-menu"
          })

        {:noreply,
         socket
         |> assign(:block_notice, nil)
         |> assign(:drawer, refresh_drawer(socket, drawer))}
    end
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer, nil)}
  end

  @impl true
  def handle_event("trip_use_default_headsign", _params, socket) do
    case socket.assigns.drawer do
      %{mode: :edit} = drawer ->
        default = drawer_headsign_default(socket, drawer)

        drawer = %{
          drawer
          | values: Map.put(drawer.values, "trip_headsign", default || ""),
            errors: %{}
        }

        {:noreply, assign(socket, :drawer, refresh_drawer(socket, drawer))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("drawer_change", %{"drawer" => params}, socket) when is_map(params) do
    case socket.assigns.drawer do
      nil ->
        {:noreply, socket}

      drawer ->
        drawer = %{drawer | values: Map.merge(drawer.values, clean_values(params)), errors: %{}}
        {:noreply, assign(socket, :drawer, refresh_drawer(socket, drawer))}
    end
  end

  def handle_event("drawer_change", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("drawer_submit", %{"drawer" => params}, socket) when is_map(params) do
    case merge_drawer_values(socket, params) do
      nil -> {:noreply, socket}
      drawer -> submit_or_refuse(socket, drawer)
    end
  end

  def handle_event("drawer_submit", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("drawer_add_window", _params, socket) do
    case socket.assigns.drawer do
      %{values: %{"windows" => [_window | _rest] = windows} = values} = drawer ->
        windows = windows ++ [next_window(List.last(windows))]
        drawer = %{drawer | values: Map.put(values, "windows", windows), errors: %{}}

        {:noreply,
         socket
         |> assign(:drawer, refresh_drawer(socket, drawer))
         |> push_event("focus_scoped_target", %{id: "windows-#{length(windows) - 1}-from"})}

      _drawer ->
        {:noreply, socket}
    end
  end

  def handle_event("drawer_remove_window", params, socket) when is_map(params) do
    case socket.assigns.drawer do
      %{values: %{"windows" => [_window, _second | _rest] = windows} = values} = drawer ->
        windows = List.delete_at(windows, window_index(params["index"]))
        drawer = %{drawer | values: Map.put(values, "windows", windows), errors: %{}}

        # The remove button goes away with its row, so focus lands on the Add
        # window control rather than on the document body.
        {:noreply,
         socket
         |> assign(:drawer, refresh_drawer(socket, drawer))
         |> push_event("focus_scoped_target", %{id: "win-add"})}

      _drawer ->
        {:noreply, socket}
    end
  end

  def handle_event("drawer_remove_window", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reload_drawer", _params, socket) do
    case socket.assigns.drawer do
      %{mode: :edit, trip: row} = drawer ->
        case reload_schedule(socket) do
          {:ok, socket} ->
            fresh = find_row(socket, row.id) || row

            drawer = %{
              drawer
              | trip: fresh,
                values: edit_values(socket, fresh),
                errors: %{},
                problem: nil
            }

            {:noreply, assign(socket, :drawer, refresh_drawer(socket, drawer))}

          {:error, :not_found} ->
            {:noreply, route_not_found(socket)}

          {:error, :unavailable} ->
            {:noreply, assign(socket, :load_state, :unavailable)}
        end

      _drawer ->
        {:noreply, socket}
    end
  end

  # --- delete ----------------------------------------------------------------

  @impl true
  def handle_event("open_delete_trip", %{"trip" => trip_id}, socket) do
    case find_row(socket, trip_id) do
      nil ->
        {:noreply, socket}

      row ->
        return_focus =
          if socket.assigns.drawer, do: "trip-drawer-delete", else: "trip-#{row.trip_id}-menu"

        dialog = %{
          ids: [row.id],
          title: "Delete this trip?",
          confirm_label: "Delete 1 trip",
          detail: "Departs #{clock(row.start_secs)} · #{row_pattern_name(socket, row)}",
          frequency?: row.frequency?,
          service_id: socket.assigns.filters.service_id,
          return_focus_id: return_focus,
          transfer_count:
            Gtfs.count_trip_transfers(
              socket.assigns.current_organization.id,
              socket.assigns.current_gtfs_version.id,
              [row.trip_id]
            ),
          error: nil
        }

        {:noreply,
         socket
         |> assign(:drawer, nil)
         |> assign(:delete_dialog, dialog)}
    end
  end

  @impl true
  def handle_event("delete_selected", _params, socket) do
    if MapSet.size(socket.assigns.selected_ids) == 0 do
      {:noreply, socket}
    else
      selected =
        Enum.filter(all_rows(socket), &MapSet.member?(socket.assigns.selected_ids, &1.id))

      service_id = socket.assigns.filters.service_id
      label = calendar_label(socket.assigns.payload.calendars, service_id)

      dialog = %{
        ids: Enum.map(selected, & &1.id),
        title: "Delete #{length(selected)} trips from #{label}?",
        confirm_label: "Delete #{length(selected)} trips",
        detail: departures_detail(selected),
        frequency?: Enum.any?(selected, & &1.frequency?),
        service_id: service_id,
        return_focus_id: "bulk-delete",
        transfer_count:
          Gtfs.count_trip_transfers(
            socket.assigns.current_organization.id,
            socket.assigns.current_gtfs_version.id,
            Enum.map(selected, & &1.trip_id)
          ),
        error: nil
      }

      {:noreply, assign(socket, :delete_dialog, dialog)}
    end
  end

  @impl true
  def handle_event("close_delete", _params, socket) do
    {:noreply, assign(socket, :delete_dialog, nil)}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    {:noreply, delete_or_refuse(socket)}
  end

  defp submit_or_refuse(socket, nil), do: {:noreply, socket}

  defp submit_or_refuse(socket, drawer), do: submit_drawer(socket, drawer)

  defp delete_or_refuse(socket) do
    dialog = socket.assigns.delete_dialog

    if dialog == nil do
      socket
    else
      # Every identifier is re-resolved against what the page currently shows,
      # so a replayed or stale list deletes nothing.
      ids = visible_ids(socket, dialog.ids)

      if ids == [] do
        assign(socket, :delete_dialog, nil)
      else
        delete_visible(socket, dialog, ids)
      end
    end
  end

  defp delete_visible(socket, dialog, ids) do
    case Gtfs.delete_trips(socket.assigns.route_id, dialog.service_id, ids, audit_context(socket)) do
      {:ok, %{trips: trips, transfers: transfers}} ->
        deleted(socket, dialog, trips, transfers, ids)

      {:error, reason} ->
        dialog_problem(socket, dialog, reason)
    end
  end

  # --- loading ---------------------------------------------------------------

  defp load_schedule(socket, params) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    case Gtfs.load_route_schedule(
           organization_id,
           version_id,
           route_id,
           requested_filters(params)
         ) do
      {:ok, payload} -> apply_payload(socket, payload, params)
      {:error, :not_found} -> route_not_found(socket)
      {:error, :unavailable} -> assign(socket, :load_state, :unavailable)
    end
  end

  defp requested_filters(params) do
    %{
      "service_id" => params["service_id"],
      "direction" => params["direction"],
      "pattern" => params["pattern"],
      "stops" => params["stops"]
    }
  end

  defp apply_payload(socket, payload, params) do
    socket
    |> put_payload(payload)
    |> push_canonical(payload.filters, params)
  end

  defp put_payload(socket, payload) do
    custom? = custom_filter?(socket.assigns.requested)
    sections = display_sections(payload, custom?)

    socket
    |> assign(:route, payload.route)
    |> assign(:payload, payload)
    |> assign(:filters, payload.filters)
    |> assign(:custom_filter?, custom?)
    |> assign(:custom_count, Enum.sum(Enum.map(payload.sections, & &1.custom_trip_count)))
    |> assign(:load_state, :ready)
    |> assign(:sections_list, sections)
    |> assign(:sections_empty?, sections == [])
    |> assign(:rows_in_view, Enum.sum(Enum.map(sections, &length(&1.rows))))
    |> assign(:can_add?, can_add?(payload))
    |> assign(:add_reason, add_reason(payload))
    |> assign(:any_trips?, Enum.any?(payload.calendars, &(&1.route_trip_count > 0)))
    |> assign(:section_index, Map.new(sections, &{"section-#{&1.pattern.route_pattern_id}", &1}))
    |> assign(:calendar_form, to_form(%{"service_id" => payload.filters.service_id}))
    |> assign(:pattern_form, to_form(%{"pattern" => pattern_param(payload.filters.pattern)}))
    |> stream(:sections, sections, reset: true)
    |> maybe_vehicle_change(payload)
  end

  # A mutation reloads through the adapter without a patch, so the marker it may
  # have set survives until the next mutation or parameter change.
  defp reload_schedule(socket) do
    case Gtfs.load_route_schedule(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           socket.assigns.route_id,
           requested_filters(socket.assigns.requested)
         ) do
      {:ok, payload} -> {:ok, put_payload(socket, payload)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The timepoints timing lines come from the read; the All stops view recomputes
  # the same segments over the wider column set from the pattern's timing rows.
  # AC-22's Custom times filter is a page-level view over the rows the read
  # already scoped: it hides every row whose times do not come from a timing and
  # drops a section whose rows are all hidden, so an empty result is the
  # filtered-empty state instead of a page of empty cards.
  defp display_sections(payload, custom?) do
    timing_rows = timing_rows_by_id(payload.patterns)
    columns_key = if payload.filters.stops == :all, do: :all_columns, else: :columns

    payload.sections
    |> Enum.map(fn section ->
      columns = Map.fetch!(section, columns_key)
      rows = if custom?, do: Enum.filter(section.rows, & &1.custom?), else: section.rows

      Map.merge(section, %{
        rows: rows,
        stops: payload.filters.stops,
        columns: columns,
        timing_lines: timing_lines_for(section.timing_lines, columns, timing_rows),
        grid: %{preview: %{}, just_changed: MapSet.new(), cell_error: nil}
      })
    end)
    |> Enum.reject(&(custom? and &1.rows == []))
  end

  defp timing_rows_by_id(patterns) do
    for pattern <- patterns, timing <- Map.get(pattern, :timings, []), into: %{} do
      {Map.fetch!(timing, :id), Map.get(timing, :rows, [])}
    end
  end

  defp timing_lines_for(timing_lines, columns, timing_rows) do
    Enum.map(timing_lines, fn line ->
      case Map.get(timing_rows, line.timing_id) do
        nil ->
          line

        rows ->
          %{segments: segments, total_secs: total_secs} = Summary.timing_segments(rows, columns)
          %{line | segments: segments, total_secs: total_secs}
      end
    end)
  end

  defp push_canonical(socket, filters, params) do
    canonical = canonical_filters(filters, custom_filter?(params))

    if Map.take(params, @filter_keys) == canonical do
      socket
    else
      push_patch(socket, to: schedule_path(socket, canonical), replace: true)
    end
  end

  # The loaded sections carry an empty grid, so a re-streamed section takes the
  # current one: a selection change keeps the review's amber preview, the changed
  # tint and a refused cell's error.
  defp reselect(socket, section, selected) do
    socket
    |> assign(:selected_ids, selected)
    |> assign(:selected_count, MapSet.size(selected))
    |> stream_insert(:sections, Map.put(section, :grid, current_grid(socket)))
  end

  # A range or a select-all replaces the whole selection, so every section whose
  # rows changed re-streams and the ones that did not stay on screen untouched.
  defp apply_selection(socket, selected) do
    changed = MapSet.symmetric_difference(socket.assigns.selected_ids, selected)

    socket
    |> assign(:selected_ids, selected)
    |> assign(:selected_count, MapSet.size(selected))
    |> restream_changed_sections(changed)
  end

  defp restream_changed_sections(socket, changed) do
    grid = current_grid(socket)

    Enum.reduce(socket.assigns.sections_list, socket, fn section, socket ->
      if Enum.any?(section.rows, &MapSet.member?(changed, &1.id)) do
        stream_insert(socket, :sections, Map.put(section, :grid, grid))
      else
        socket
      end
    end)
  end

  # Shift+Up/Down walks the rows the page shows in document order, so the range
  # between two of them is inclusive and both ends must resolve against the
  # loaded sections: a row the current filters hid, a forged UUID or a malformed
  # payload is a no-op, and nothing outside the visible rows can be selected.
  defp select_range(socket, from, to) do
    case rows_between(socket, from, to) do
      nil -> socket
      ids -> apply_selection(socket, MapSet.new(ids))
    end
  end

  defp rows_between(socket, from, to) do
    rows = all_rows(socket)
    indexes = Map.new(Enum.with_index(rows), fn {row, index} -> {row.id, index} end)

    with first when is_integer(first) <- Map.get(indexes, from),
         last when is_integer(last) <- Map.get(indexes, to) do
      rows
      |> Enum.slice(min(first, last)..max(first, last))
      |> Enum.map(& &1.id)
    else
      _missing -> nil
    end
  end

  defp select_all(socket), do: apply_selection(socket, MapSet.new(all_rows(socket), & &1.id))

  # The vehicle "N → M" marker: the count before the mutation is kept in
  # `vehicle_change_from` and compared with the count the reload returns.
  defp maybe_vehicle_change(socket, payload) do
    case socket.assigns[:vehicle_change_from] do
      nil ->
        socket

      from ->
        to = payload.summary.vehicles.count

        socket
        |> assign(:vehicle_change_from, nil)
        |> assign(:vehicle_change, if(from != to, do: %{from: from, to: to}, else: nil))
    end
  end

  defp clear_vehicle_change(%{assigns: %{keep_vehicle_change: true}} = socket),
    do: assign(socket, :keep_vehicle_change, false)

  defp clear_vehicle_change(socket), do: assign(socket, :vehicle_change, nil)

  defp current_vehicle_count(%{assigns: %{payload: %{summary: %{vehicles: %{count: count}}}}}),
    do: count

  defp current_vehicle_count(_socket), do: nil

  defp route_not_found(socket) do
    version_id = socket.assigns.current_gtfs_version.id

    socket
    |> put_flash(:error, "Route not found")
    |> push_navigate(to: "/gtfs/#{version_id}/routes")
  end

  defp switch_version(socket, version_id) do
    organization_id = socket.assigns.current_organization.id
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(organization_id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      path =
        schedule_path_for(
          version_id,
          socket.assigns.route_id,
          canonical_filters_for_params(socket.assigns.filters, socket.assigns.requested)
        )

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  # --- scope resolution ------------------------------------------------------

  defp find_row(socket, trip_id) do
    case find_section(socket, trip_id) do
      nil -> nil
      {_dom_id, section} -> Enum.find(section.rows, &(&1.id == trip_id))
    end
  end

  defp find_section(socket, trip_id) do
    Enum.find(socket.assigns.section_index, fn {_dom_id, section} ->
      Enum.any?(section.rows, &(&1.id == trip_id))
    end)
  end

  defp visible_ids(socket, ids) do
    visible = MapSet.new(all_rows(socket), & &1.id)
    Enum.filter(ids, &MapSet.member?(visible, &1))
  end

  defp all_rows(socket), do: Enum.flat_map(socket.assigns.sections_list, & &1.rows)

  defp add_drawer_pattern(socket) do
    payload = socket.assigns.payload
    patterns = payload.patterns

    Enum.find(patterns, &(&1.id == payload.filters.pattern)) ||
      Enum.find(patterns, &(&1.direction_id == payload.filters.direction_id)) ||
      List.first(patterns)
  end

  # --- cell editing ------------------------------------------------------------

  # The reading request: parse through the page's one grammar with the trip's
  # preceding stored time and the cell's own value, and say what the default
  # Enter commit would do. Nothing is written.
  defp cell_preview(socket, trip_id, position, text) do
    with true <- editor_access?(socket),
         {:ok, context} <- cell_context(socket, trip_id, position),
         {:ok, %{secs: secs, reading: reading, note: note}} <-
           TimeEntry.parse(text, previous: context.previous, current: context.current) do
      %{
        ok: true,
        reading: reading,
        note: preview_note(note, secs),
        effect: preview_effect(context, secs)
      }
    else
      false -> %{ok: false, message: ScheduleComponents.error_message(:unauthorized)}
      :error -> %{ok: false, message: ScheduleComponents.error_message(:not_found)}
      {:error, reason} -> %{ok: false, message: ScheduleComponents.error_message(reason)}
    end
  end

  # One commit: parse the typed time with the same R2 grammar, apply `:edit_stop`
  # with the loaded row's `updated_at` as the fence (INV-2), then reload and
  # report the outcome. The reply carries no more than the client shows.
  defp commit_cell(socket, trip_id, position, text, mode_value) do
    with {:ok, mode} <- commit_mode(mode_value),
         {:ok, context} <- cell_context(socket, trip_id, position),
         {:ok, %{secs: secs}} <-
           TimeEntry.parse(text, previous: context.previous, current: context.current) do
      apply_cell_change(socket, context, mode, secs)
    else
      :invalid_mode -> {:error, socket, ScheduleComponents.save_failure_copy()}
      :error -> {:error, socket, ScheduleComponents.error_message(:not_found)}
      {:error, reason} -> {:error, socket, ScheduleComponents.error_message(reason)}
    end
  end

  # Delete/Backspace clears one stop time. The empty reply only ends the cell's
  # pending state; a refusal reaches the page through the re-streamed error state
  # and a cell the page cannot resolve through the grid bar. A cell with no stored
  # time (blank or estimated) has nothing to clear, so nothing is written.
  defp clear_cell(socket, trip_id, position) do
    case cell_context(socket, trip_id, position) do
      {:ok, context} ->
        if is_nil(context.current), do: socket, else: write_clear(socket, context)

      :error ->
        warning_outcome(socket, ScheduleComponents.error_message(:not_found))
    end
  end

  defp write_clear(socket, context) do
    command = edit_stop_command(socket, context, :clear, :later)
    fence = {:expected, %{context.row.id => context.row.updated_at}}

    case Gtfs.apply_trip_change(socket.assigns.route_id, command, fence, audit_context(socket)) do
      {:ok, result} -> committed_cell(socket, context, :clear, nil, result)
      {:error, {:refused, errors}} -> cell_error(socket, context, refusal_message(errors))
      {:error, reason} -> cell_error(socket, context, ScheduleComponents.error_message(reason))
    end
  end

  defp apply_cell_change(socket, context, mode, secs) do
    command = edit_stop_command(socket, context, secs, mode)
    fence = {:expected, %{context.row.id => context.row.updated_at}}

    case Gtfs.apply_trip_change(socket.assigns.route_id, command, fence, audit_context(socket)) do
      {:ok, result} ->
        {:ok, committed_cell(socket, context, mode, secs, result)}

      {:error, {:refused, errors}} ->
        message = refusal_message(errors)
        {:error, cell_error(socket, context, message), message}

      {:error, reason} ->
        message = ScheduleComponents.error_message(reason)
        {:error, cell_error(socket, context, message), message}
    end
  end

  # A successful write reloads once, then re-merges the grid state into the
  # re-streamed sections and bumps the revision so the hook re-applies its cursor
  # and editor (the reload rebuilds every section with an empty grid).
  defp committed_cell(socket, context, mode, secs, result) do
    message = cell_outcome(context, mode, secs, result)

    socket
    |> assign(:just_changed, MapSet.new(result.changed_trip_ids))
    |> assign(:cell_error, nil)
    |> assign(:outcome, %{tone: :info, text: message, undo?: true})
    |> push_undo(result.restore, message)
    |> reload_cell()
  end

  defp reload_cell(socket, touched_ids \\ MapSet.new()) do
    case reload_schedule(socket) do
      {:ok, socket} -> stream_grid_state(socket, touched_ids)
      {:error, :not_found} -> route_not_found(socket)
      {:error, :unavailable} -> assign(socket, :load_state, :unavailable)
    end
  end

  # The wait is on the sections whose grid state changed: the rows a review
  # previews, the rows a re-review or a closed change touched (so amber cells are
  # removed as well as added), the changed row's tint and the one cell a refusal
  # points at. Everything else keeps the empty grid the reload put on it.
  defp stream_grid_state(socket, touched_ids \\ MapSet.new()) do
    grid = current_grid(socket)
    socket = assign(socket, :grid_revision, socket.assigns.grid_revision + 1)

    socket.assigns.sections_list
    |> Enum.filter(&grid_section?(&1, grid, touched_ids))
    |> Enum.reduce(socket, &stream_insert(&2, :sections, Map.put(&1, :grid, grid)))
  end

  defp current_grid(socket) do
    %{
      preview: preview_map(socket.assigns.change),
      just_changed: socket.assigns.just_changed,
      cell_error: socket.assigns.cell_error
    }
  end

  defp grid_section?(section, grid, touched_ids) do
    Enum.any?(section.rows, fn row ->
      Map.has_key?(grid.preview, row.id) or
        MapSet.member?(touched_ids, row.id) or
        MapSet.member?(grid.just_changed, row.id) or
        match?(%{trip: trip} when trip == row.id, grid.cell_error)
    end)
  end

  # A change re-streams the sections it leaves as well as the ones it covers: a
  # re-review, a stale result or a closed surface must clear the amber cells the
  # previous preview drew.
  defp restream_change(socket, previous_ids) do
    stream_grid_state(socket, MapSet.new(previous_ids ++ preview_ids(socket.assigns.change)))
  end

  defp preview_map(%{review: %{preview: preview}}), do: preview
  defp preview_map(_change), do: %{}

  defp preview_ids(change), do: Map.keys(preview_map(change))

  defp cell_error(socket, context, message) do
    socket
    |> assign(:cell_error, %{
      trip: context.row.id,
      position: context.position,
      message: message
    })
    |> stream_grid_state()
  end

  defp push_undo(socket, nil, _message), do: socket

  defp push_undo(socket, payload, message) do
    entry = %{payload: payload, message: message}
    assign(socket, :undo_stack, Enum.take([entry | socket.assigns.undo_stack], @undo_limit))
  end

  defp edit_stop_command(socket, context, value, mode) do
    {:edit_stop, context.row.id,
     %{
       position: context.position,
       value: value,
       mode: mode,
       shown_positions: shown_positions(socket, context.section)
     }}
  end

  # The loaded row plus the two times R2 reads: the nearest preceding stored cell
  # (`nil` at the first stop) and the cell's own value. A position that names no
  # occurrence of this trip resolves to `:error` and writes nothing.
  defp cell_context(socket, trip_id, position) when is_integer(position) and position >= 1 do
    with {_dom_id, section} <- find_section(socket, trip_id),
         %{} = row <- Enum.find(section.rows, &(&1.id == trip_id)),
         true <- Map.has_key?(row.cells, position) do
      {:ok,
       %{
         section: section,
         row: row,
         position: position,
         previous: previous_cell_secs(row, position),
         current: cell_secs(Map.fetch!(row.cells, position))
       }}
    else
      _missing -> :error
    end
  end

  defp cell_context(_socket, _trip_id, _position), do: :error

  defp previous_cell_secs(row, position) do
    row.cells
    |> Enum.filter(fn {key, _cell} -> key < position end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.find_value(fn {_key, cell} -> cell_secs(cell) end)
  end

  defp cell_secs(%{missing?: true}), do: nil
  # An estimate is a blank stored time shown in italics; it is never read as stored.
  defp cell_secs(%{estimated?: true}), do: nil

  # The cell's text is the page's display clock (seconds only when nonzero), so
  # it reads back through the page's one grammar, not the storage clock parser.
  defp cell_secs(%{text: text}) do
    case TimeEntry.parse(text, []) do
      {:ok, %{secs: secs}} -> secs
      {:error, _reason} -> nil
    end
  end

  defp shown_positions(socket, section) do
    if socket.assigns.filters.stops == :all do
      :all
    else
      Enum.map(section.columns, & &1.position)
    end
  end

  defp commit_mode("later"), do: {:ok, :later}
  defp commit_mode("only"), do: {:ok, :only}
  defp commit_mode("anchor"), do: {:ok, :anchor}
  defp commit_mode(_value), do: :invalid_mode

  defp refusal_message([{:error, reason} | _rest]), do: ScheduleComponents.error_message(reason)
  defp refusal_message(_errors), do: ScheduleComponents.save_failure_copy()

  # The reading card's parenthetical: the service-day adjustments R2 can make,
  # spelled the way the timetable titles them.
  defp preview_note(nil, _secs), do: nil
  defp preview_note(:plus_12h, _secs), do: "12 hours later"
  defp preview_note(:next_day, secs), do: "#{human_clock(secs)} next day"

  # What Enter would do to the rest of the trip; nothing when the entry keeps the
  # current value or the cell has no time to move.
  defp preview_effect(%{current: nil}, _secs), do: nil
  defp preview_effect(%{current: current}, secs) when current == secs, do: nil

  defp preview_effect(%{row: row, position: position, current: current}, secs) do
    delta = signed_minutes(secs - current)

    if first_position?(row, position) do
      "the whole trip moves #{delta}" <> if(row.custom?, do: "", else: " and keeps its timing")
    else
      "later stops move #{delta}"
    end
  end

  # The one line the grid bar shows after a cell write (step 28 renders it): the
  # stop, the trip's departure and what moved, using the revision-2 copy.
  defp cell_outcome(%{position: position, row: row, section: section}, :clear, _secs, result) do
    "Cleared #{stop_name(section, position)} on the #{clock(row.start_secs)} trip." <>
      custom_note(row, result)
  end

  defp cell_outcome(
         %{position: position, row: row, current: current, section: section} = context,
         mode,
         secs,
         result
       ) do
    stop = stop_name(section, position)
    departs = clock(row.start_secs)
    first? = first_position?(row, position)

    title =
      if first? or mode == :anchor do
        "The #{departs} trip now leaves at #{cell_clock(first_departure(context, mode, secs))}."
      else
        "#{stop} on the #{departs} trip is now #{cell_clock(secs)}."
      end

    body =
      cond do
        current == nil ->
          nil

        first? ->
          nil

        mode == :anchor ->
          "Every stop moved #{signed_minutes(secs - current)}; #{stop} is at #{cell_clock(secs)}."

        mode == :later ->
          "#{later_stops(row, position)} moved #{signed_minutes(secs - current)}." <>
            custom_note(row, result)

        true ->
          "Only this stop changed." <> custom_note(row, result)
      end

    Enum.join(Enum.reject([title, body], &is_nil/1), " ")
  end

  defp first_departure(%{row: %{start_secs: start_secs}, current: current}, :anchor, secs)
       when is_integer(start_secs) and is_integer(current),
       do: start_secs + (secs - current)

  defp first_departure(%{row: row, position: position}, _mode, secs) do
    if first_position?(row, position), do: secs, else: row.start_secs
  end

  defp later_stops(row, position) do
    count = Enum.count(row.cells, fn {key, cell} -> key > position and cell_secs(cell) != nil end)
    "#{count} later #{if count == 1, do: "stop", else: "stops"}"
  end

  defp first_position?(row, position),
    do: position == row.cells |> Map.keys() |> Enum.min(fn -> nil end)

  defp stop_name(section, position) do
    case Enum.find(section.all_columns, &(&1.position == position)) do
      nil -> "stop #{position}"
      column -> column.stop_name
    end
  end

  # The reference's linkage line: a linked trip that stopped matching every timing
  # now has custom times.
  defp custom_note(row, result) do
    if not row.custom? and became_custom?(result) do
      " The trip now has custom times."
    else
      ""
    end
  end

  defp became_custom?(result) do
    Enum.any?(result.change_set.updates, fn update ->
      Map.get(update.fields, :pattern_derivation_state) == "custom"
    end)
  end

  defp signed_minutes(seconds) do
    sign = if seconds < 0, do: "−", else: "+"
    "#{sign}#{abs(round(seconds / 60))} min"
  end

  # The same clock the reading uses: seconds only when they are nonzero.
  defp cell_clock(secs) do
    formatted = GtfsTime.format(secs)

    if String.ends_with?(formatted, ":00"),
      do: String.replace_suffix(formatted, ":00", ""),
      else: formatted
  end

  defp human_clock(secs) do
    hour = rem(div(secs, 3_600), 24)
    minutes = div(rem(secs, 3_600), 60)

    {display_hour, meridiem} =
      cond do
        hour == 0 -> {12, "AM"}
        hour < 12 -> {hour, "AM"}
        hour == 12 -> {12, "PM"}
        true -> {hour - 12, "PM"}
      end

    "#{display_hour}:#{pad(minutes)} #{meridiem}"
  end

  # --- nudges and undo ---------------------------------------------------------

  # `]`/`[`/`}`/`{` (R12): an immediate R4 Shift of the selection, or of the cursor
  # row's trip when nothing is selected, by ±1 or ±5 whole minutes. The params carry
  # only a minute count and one trip UUID; the trips, their times and the fence all
  # come from the loaded rows (AC-11, AC-23, INV-2).
  defp nudge(socket, %{"minutes" => minutes} = params) do
    if nudge_minutes?(minutes) do
      case nudge_ids(socket, params["trip"]) do
        {:ok, ids} -> shift_trips(socket, ids, minutes)
        :not_found -> warning_outcome(socket, ScheduleComponents.error_message(:not_found))
        :none -> socket
      end
    else
      socket
    end
  end

  defp nudge(socket, _params), do: socket

  defp nudge_minutes?(value), do: is_integer(value) and value in @nudge_minutes

  # The selection wins over the cursor row; either way only rows this page loaded
  # can move, so a forged UUID resolves to `:not_found` and writes nothing.
  defp nudge_ids(socket, trip_id) do
    case visible_ids(socket, MapSet.to_list(socket.assigns.selected_ids)) do
      [] -> nudge_trip_id(socket, trip_id)
      ids -> {:ok, ids}
    end
  end

  defp nudge_trip_id(socket, trip_id) when is_binary(trip_id) do
    case find_row(socket, trip_id) do
      nil -> :not_found
      row -> {:ok, [row.id]}
    end
  end

  defp nudge_trip_id(_socket, _trip_id), do: :none

  # R4's Shift with the loaded rows' `updated_at` as the fence (INV-2) and no
  # `from_position`: every selected trip moves as a whole and keeps its block.
  defp shift_trips(socket, ids, minutes) do
    rows = Enum.map(ids, &find_row(socket, &1))
    command = {:shift, ids, minutes * 60, nil}
    fence = {:expected, Map.new(rows, &{&1.id, &1.updated_at})}

    case Gtfs.apply_trip_change(socket.assigns.route_id, command, fence, audit_context(socket)) do
      {:ok, result} -> nudged(socket, ids, minutes, result)
      {:error, {:refused, errors}} -> nudge_refused(socket, errors)
      {:error, reason} -> warning_outcome(socket, ScheduleComponents.error_message(reason))
    end
  end

  # A nudge keeps the selection, so the bar can repeat it; the outcome stays
  # undoable and the moved rows take the just-changed tint (AC-9).
  defp nudged(socket, ids, minutes, result) do
    message = nudge_outcome(length(ids), minutes)

    socket
    |> assign(:just_changed, MapSet.new(result.changed_trip_ids))
    |> assign(:cell_error, nil)
    |> assign(:outcome, %{tone: :info, text: message, undo?: true})
    |> push_undo(result.restore, message)
    |> reload_cell()
  end

  defp nudge_outcome(count, minutes) do
    trips = if count == 1, do: "1 trip", else: "#{count} trips"
    direction = if minutes > 0, do: "later", else: "earlier"
    "Moved #{trips} #{abs(minutes)} min #{direction}."
  end

  # The one R1 refusal a nudge reaches is a whole-trip move before 00:00; its copy
  # is the reference's, not the cell error's "Type a later time".
  defp nudge_refused(socket, errors) do
    case errors do
      [{:error, :negative_time} | _rest] ->
        warning_outcome(socket, "Nothing was shifted. A trip can't start before 00:00.")

      _other ->
        warning_outcome(socket, refusal_message(errors))
    end
  end

  # R10's Undo: the params are ignored, the newest entry (the payload this process
  # captured when it wrote) is popped and re-submitted to `Gtfs.restore_trips/3`.
  # A refusal consumes the entry: a payload is single-use and cannot be retried.
  defp undo(socket) do
    case socket.assigns.undo_stack do
      [] ->
        socket

      [entry | rest] ->
        restore_entry(assign(socket, :undo_stack, rest), entry)
    end
  end

  defp restore_entry(socket, %{payload: payload, message: message}) do
    case Gtfs.restore_trips(socket.assigns.route_id, payload, audit_context(socket)) do
      {:ok, result} ->
        undone(socket, result, message)

      {:error, {:not_restorable, :changed, ids}} ->
        undo_refused(socket, ids)

      {:error, {:not_restorable, :transfer_names_created_trip, ids}} ->
        undo_transfer_refused(socket, payload, ids)

      {:error, :calendar_not_found} ->
        warning_outcome(
          socket,
          "Nothing was undone. A service day from that change was deleted after it."
        )

      {:error, reason} ->
        warning_outcome(socket, ScheduleComponents.error_message(reason))
    end
  end

  # An undo tints the trips it put back and repeats the restored action's own
  # sentence; Undo stays available while the stack holds older entries.
  defp undone(socket, result, message) do
    socket
    |> assign(:just_changed, MapSet.new(result.restored_trip_ids))
    |> assign(:cell_error, nil)
    |> assign(:outcome, %{
      tone: :info,
      text: "Undid: " <> String.trim_trailing(message, ".") <> ".",
      undo?: socket.assigns.undo_stack != []
    })
    |> reload_cell()
  end

  # R10's first refusal: another writer changed a payload trip, so nothing is
  # restored and the page reloads to show that trip's current times (FH-26).
  defp undo_refused(socket, ids) do
    socket =
      socket
      |> assign(:just_changed, MapSet.new())
      |> assign(:cell_error, nil)
      |> reload_cell()

    assign(socket, :outcome, %{
      tone: :warning,
      text: undo_refused_copy(socket, ids),
      undo?: false
    })
  end

  # The refusal names the first changed trip whose row is on screen; a payload trip
  # gone from the rows falls back to the reference's deleted-trip sentence.
  defp undo_refused_copy(socket, ids) do
    case Enum.find_value(ids, &find_row(socket, &1)) do
      nil ->
        "Nothing was undone. A trip from that change was deleted after it."

      row ->
        "Nothing was undone. The #{clock(row.start_secs)} trip changed after your change. " <>
          "Its current times are shown."
    end
  end

  # R10's second refusal: a transfer names a created trip the restore would delete,
  # so nothing is restored and the warning names that trip (FH-27).
  defp undo_transfer_refused(socket, payload, ids) do
    warning_outcome(socket, transfer_undo_copy(payload, ids))
  end

  defp transfer_undo_copy(payload, ids) do
    names =
      payload
      |> Map.get(:created, [])
      |> Enum.filter(&(Map.get(&1, :id) in ids))
      |> Enum.map(&Map.get(&1, :trip_id))
      |> Enum.reject(&is_nil/1)

    case names do
      [] ->
        "Nothing was undone. A transfer record still names a trip this change created."

      [name] ->
        "Nothing was undone. A transfer record still names the #{name} trip this change created."

      names ->
        "Nothing was undone. Transfer records still name the #{Enum.join(names, ", ")} trips " <>
          "this change created."
    end
  end

  # Cmd/Ctrl+S: nothing to save, because each action already saved (R12).
  defp save_shortcut(socket) do
    if editor_access?(socket) do
      assign(socket, :outcome, %{tone: :info, text: "All changes are saved.", undo?: false})
    else
      warning_outcome(socket, ScheduleComponents.error_message(:unauthorized))
    end
  end

  # `?` in the grid and the filter bar's Keyboard shortcuts button both toggle
  # the sheet. The button names itself on the event, so a sheet it opened
  # returns focus to it after Close or Escape; a sheet opened from the grid
  # keeps the dialog's own restore, which hands focus back to the cell the key
  # was pressed on (the button id is the only value the event may name).
  defp toggle_shortcuts(socket, params) do
    open? = not socket.assigns.shortcuts_open?

    return_focus =
      cond do
        not open? -> socket.assigns.shortcuts_return_focus_id
        params["source"] == "button" -> "keyboard-shortcuts-button"
        true -> nil
      end

    socket
    |> assign(:shortcuts_open?, open?)
    |> assign(:shortcuts_return_focus_id, return_focus)
  end

  defp warning_outcome(socket, text) do
    assign(socket, :outcome, %{tone: :warning, text: text, undo?: false})
  end

  # --- reviewed bulk changes ---------------------------------------------------

  # The §4.5 review lifecycle. `open_change` builds a command from the selection
  # (or the named trip) and the kind's own defaults and reviews it without
  # writing; `change_params` re-reviews with the posted control values;
  # `apply_change` writes the reviewed command behind its fingerprint (INV-2);
  # `refresh_change` re-reviews after a stale result and `cancel_change` closes
  # the surface. The command, its review and the trip IDs stay in this process
  # (INV-6): the client sends a kind, one trip UUID and control values, never a
  # time, a fingerprint or a payload. Steps 31, 32 and 36 add their kinds by
  # adding an `open_reviewed_change/3` and a `change_command/2` clause; an
  # unknown kind is ignored rather than raising.
  defp open_change(socket, kind, trip_id) do
    if editor_access?(socket) do
      open_reviewed_change(socket, kind, trip_id)
    else
      warning_outcome(socket, ScheduleComponents.error_message(:unauthorized))
    end
  end

  defp open_reviewed_change(socket, "shift", _trip_id) do
    case visible_ids(socket, MapSet.to_list(socket.assigns.selected_ids)) do
      [] -> socket
      ids -> review_change(socket, :shift, ids, %{direction: 1, minutes: 5, from_position: nil})
    end
  end

  defp open_reviewed_change(socket, "timing", trip_id) do
    case timing_change_ids(socket, trip_id) do
      {:ok, ids} -> review_change(socket, :timing, ids, timing_params(socket, ids))
      :not_found -> warning_outcome(socket, ScheduleComponents.error_message(:not_found))
      :none -> socket
    end
  end

  # Copy to calendar and Change calendar act on the visible selection and open on
  # the page's first other service day, like the reference's Saturday default.
  defp open_reviewed_change(socket, "copy", _trip_id), do: open_calendar_change(socket, :copy)
  defp open_reviewed_change(socket, "move", _trip_id), do: open_calendar_change(socket, :move)

  # Paste copied trips opens on the clipboard's own trips, not the selection: the
  # clipboard survives clearing the selection (the reference's paste state clears
  # it before pasting). Duplicate acts on the visible selection and opens on the
  # current service day with the first departure 30 minutes later (R7).
  defp open_reviewed_change(socket, "paste", _trip_id) do
    case socket.assigns.clipboard do
      %{trip_ids: ids} -> open_paste(socket, ids)
      _empty -> socket
    end
  end

  defp open_reviewed_change(socket, "duplicate", _trip_id) do
    case visible_ids(socket, MapSet.to_list(socket.assigns.selected_ids)) do
      [] -> socket
      ids -> open_duplicate(socket, ids)
    end
  end

  # Convert opens on one frequency row: the only trip a `:convert_frequency`
  # command names. The Edit drawer's own Convert action arrives here too, so the
  # drawer closes with the dialog (the delete flow opens the dialog the same
  # way). A forged UUID is refused (FH-30) and a listed row has no dialog.
  defp open_reviewed_change(socket, "convert", trip_id) when is_binary(trip_id) do
    case find_row(socket, trip_id) do
      %{frequency?: true} = row ->
        socket
        |> assign(:drawer, nil)
        |> review_change(:convert, [row.id], %{})

      %{frequency?: false} ->
        socket

      nil ->
        warning_outcome(socket, ScheduleComponents.error_message(:not_found))
    end
  end

  # Convert plugs in here with its step's builder; an unknown kind is ignored.
  defp open_reviewed_change(socket, _kind, _trip_id), do: socket

  # Copy trips keeps the visible selection as this process's clipboard. It
  # writes nothing, so the outcome offers no Undo; the bar names the shortcut
  # that pastes them (the reference's own "Press ⌘V" copy).
  defp copy_trips(socket) do
    if editor_access?(socket) do
      case visible_ids(socket, MapSet.to_list(socket.assigns.selected_ids)) do
        [] ->
          socket

        ids ->
          socket
          |> assign(:clipboard, %{
            trip_ids: Enum.sort(ids),
            service_id: socket.assigns.filters.service_id
          })
          |> assign(:outcome, %{
            tone: :info,
            text: "#{trip_count_label(length(ids))} copied. Press ⌘V in the grid to paste.",
            undo?: false
          })
      end
    else
      warning_outcome(socket, ScheduleComponents.error_message(:unauthorized))
    end
  end

  # The hook asks whether this page holds trips to paste. With the clipboard set
  # the dialog opens on the trips it copied; without it the reply is false and
  # the hook reports a spreadsheet paste through `paste_text` (AC-16).
  defp paste_trips(socket) do
    clipboard? = not is_nil(socket.assigns.clipboard)

    socket =
      cond do
        not editor_access?(socket) ->
          warning_outcome(socket, ScheduleComponents.error_message(:unauthorized))

        clipboard? ->
          open_paste(socket, socket.assigns.clipboard.trip_ids)

        true ->
          socket
      end

    {%{clipboard: clipboard?}, socket}
  end

  # AC-16: text that did not come from Copy trips creates nothing.
  defp paste_text(socket) do
    assign(socket, :outcome, %{
      tone: :info,
      text:
        "Copied trips from this page can be pasted here. " <>
          "To paste a timetable from a spreadsheet, use Paste timetable.",
      undo?: false
    })
  end

  # The paste's command parameters: the target day, the times choice and anchor,
  # and the skip choice. The anchor is the clipboard's earliest *displayed* first
  # departure, because a copy offset is a whole minute (TripChanges.validate_offset/1)
  # while a stored clock may carry seconds the timetable never shows. With no
  # clipboard trip loaded any more there is nothing to anchor on, so the dialog
  # does not open.
  defp open_paste(socket, ids) do
    case copy_anchor_secs(socket, ids) do
      nil ->
        socket

      anchor ->
        params = %{
          service_id: default_paste_target(socket.assigns),
          mode: :same,
          first_departure: nil,
          skip_existing: true,
          anchor_secs: anchor
        }

        review_change(socket, :paste, ids, params)
    end
  end

  # R7's duplicate: the current service day and the selection's earliest first
  # departure 30 minutes later, which every selected trip's copy keeps as a
  # whole-minute offset.
  defp open_duplicate(socket, ids) do
    case copy_anchor_secs(socket, ids) do
      nil ->
        socket

      anchor ->
        params = %{
          service_id: socket.assigns.filters.service_id,
          mode: :at,
          first_departure: clock(anchor + @duplicate_offset_secs),
          skip_existing: true,
          anchor_secs: anchor
        }

        review_change(socket, :duplicate, ids, params)
    end
  end

  # The trips the paste reads as one set, in the order the review sorts them; the
  # anchor is the earliest of their displayed first departures.
  defp copy_anchor_secs(socket, ids) do
    ids
    |> Enum.flat_map(fn trip_id ->
      case find_row(socket, trip_id) do
        %{start_secs: secs} when is_integer(secs) -> [secs - rem(secs, 60)]
        _row -> []
      end
    end)
    |> Enum.min(fn -> nil end)
  end

  # The paste's default target is the page's first other service day, the copy
  # drawer's own default; a version with one service day pastes onto itself.
  defp default_paste_target(assigns) do
    current = assigns.filters.service_id

    case Enum.find(paste_target_options(assigns), &(&1.value != current)) do
      %{value: value} -> value
      nil -> current
    end
  end

  # Every service day of the version, the page's own included: a paste may stay on
  # the current day at a new first departure. Labelled the way the scope bar and
  # the copy drawer label service days.
  defp paste_target_options(assigns) do
    for calendar <- assigns.payload.calendars do
      name = calendar_label(assigns.payload.calendars, calendar.service_id)

      %{
        value: calendar.service_id,
        name: name,
        label: "#{name} · #{trip_count_label(calendar.route_trip_count)}"
      }
    end
  end

  # With no other service day there is nowhere to copy or move to, so the bar
  # says so rather than opening a drawer with no target (a one-calendar version
  # is reachable on a version whose calendars were all deleted).
  defp open_calendar_change(socket, kind) do
    ids = visible_ids(socket, MapSet.to_list(socket.assigns.selected_ids))

    case {ids, change_target_options(socket.assigns)} do
      {[], _options} ->
        socket

      {_ids, []} ->
        warning_outcome(socket, ScheduleComponents.error_message(:no_target_calendar))

      {ids, [%{value: service_id} | _rest]} ->
        params =
          if kind == :copy,
            do: %{service_id: service_id, skip_existing: true},
            else: %{service_id: service_id}

        review_change(socket, kind, ids, params)
    end
  end

  # The service days this page can copy or move to: every service day except the
  # one being shown, labelled the way the scope bar and the drawers label them.
  defp change_target_options(assigns) do
    source = assigns.filters.service_id

    for calendar <- assigns.payload.calendars, calendar.service_id != source do
      name = calendar_label(assigns.payload.calendars, calendar.service_id)

      %{
        value: calendar.service_id,
        name: name,
        label: "#{name} · #{trip_count_label(calendar.route_trip_count)}"
      }
    end
  end

  # Change timing acts on the selection, or on the one trip whose Timing cell
  # opened it when nothing is selected. Only a row this page loaded resolves; a
  # forged UUID is refused and never reviewed (FH-30).
  defp timing_change_ids(socket, trip_id) do
    case visible_ids(socket, MapSet.to_list(socket.assigns.selected_ids)) do
      [] -> change_named_trip(socket, trip_id)
      ids -> {:ok, ids}
    end
  end

  defp change_named_trip(socket, trip_id) when is_binary(trip_id) do
    case find_row(socket, trip_id) do
      nil -> :not_found
      row -> {:ok, [row.id]}
    end
  end

  defp change_named_trip(_socket, _trip_id), do: :none

  defp review_change(socket, kind, ids, params) do
    # Opening a change clears the last write's report and the rows it tinted, the
    # way the reference's strip takes the bar: the preview owns the grid state
    # while the change is open (the section re-stream removes the tint too).
    previous_ids =
      preview_ids(socket.assigns.change) ++ MapSet.to_list(socket.assigns.just_changed)

    change = %{
      kind: kind,
      ids: Enum.sort(ids),
      params: params,
      review: nil,
      refusal: nil,
      notice: nil,
      stale?: false,
      applying?: false
    }

    socket
    |> assign(:change, change)
    |> assign(:just_changed, MapSet.new())
    |> assign(:outcome, nil)
    |> load_change_review()
    |> restream_change(previous_ids)
  end

  # One review through the facade. The command is rebuilt from the change's own
  # trip IDs and control values, so a re-review, a refresh after a stale result
  # and the apply all name the same trips and the same parameters. A command that
  # cannot be formed yet (no minutes typed, no timing chosen) leaves the change
  # without a review; a review the engine refuses keeps its reason for the
  # surface to render.
  defp load_change_review(socket) do
    change = %{socket.assigns.change | notice: nil}

    case change_command(socket, change) do
      {:ok, command} ->
        case Gtfs.review_trip_change(socket.assigns.route_id, command, audit_context(socket)) do
          {:ok, review} ->
            assign(socket, :change, %{change | review: review, refusal: nil, stale?: false})

          {:error, reason} ->
            assign(socket, :change, %{change | review: nil, refusal: [{:error, reason}]})
        end

      {:error, reason} ->
        assign(socket, :change, %{change | review: nil, refusal: [{:error, reason}]})

      :incomplete ->
        assign(socket, :change, %{change | review: nil, refusal: nil})
    end
  end

  # The two kinds this step owns. `:shift` is R4 with the strip's whole-minute
  # delta and an optional displayed timepoint position; `:timing` is R5 with the
  # chosen timing of the selection's pattern.
  defp change_command(_socket, %{kind: :shift, ids: ids, params: params}) do
    minutes = params.minutes

    if is_integer(minutes) and minutes in 1..@max_shift_minutes do
      {:ok, {:shift, ids, params.direction * minutes * 60, params.from_position}}
    else
      :incomplete
    end
  end

  # Timings belong to a pattern, so a selection spanning patterns is refused
  # before any timing is reviewed, like the prototype.
  defp change_command(socket, %{kind: :timing, ids: ids} = change) do
    case {one_pattern?(socket, ids), change.params} do
      {false, _params} ->
        {:error, :multiple_patterns}

      {true, %{timing_id: timing_id}} when is_binary(timing_id) ->
        {:ok, {:set_timing, ids, timing_id}}

      {true, _params} ->
        {:error, :timed_pattern_required}
    end
  end

  # Copy to calendar is R7 at offset 0 to the chosen service day with the skip
  # choice the drawer posted; Change calendar is R6 to the chosen service day.
  defp change_command(_socket, %{kind: :copy, ids: ids, params: params}) do
    case params[:service_id] do
      service_id when is_binary(service_id) ->
        {:ok, {:copy, ids, service_id, 0, params[:skip_existing] != false}}

      _no_target ->
        {:error, :calendar_not_found}
    end
  end

  defp change_command(_socket, %{kind: :move, ids: ids, params: params}) do
    case params[:service_id] do
      service_id when is_binary(service_id) -> {:ok, {:move_calendar, ids, service_id}}
      _no_target -> {:error, :calendar_not_found}
    end
  end

  # Paste and Duplicate are R7 copies: the target day, the times choice and the
  # skip choice. "Same times" is offset 0; a new first departure is the typed
  # time minus the clipboard's anchor. A time the engine cannot express as a
  # whole-minute offset (±24 h) leaves the change without a review, so the dialog
  # keeps the input and shows its own error instead of a refusal.
  defp change_command(_socket, %{kind: :paste, ids: ids, params: params}) do
    copy_command(ids, params)
  end

  defp change_command(_socket, %{kind: :duplicate, ids: ids, params: params}) do
    copy_command(ids, params)
  end

  # Convert names one frequency trip; the engine's Convert planner expands its
  # stored windows into listed trips and removes the source (AC-19).
  defp change_command(_socket, %{kind: :convert, ids: [trip_id]}) when is_binary(trip_id) do
    {:ok, {:convert_frequency, trip_id}}
  end

  defp change_command(_socket, _change), do: :incomplete

  defp copy_command(ids, params) do
    case {params[:service_id], copy_offset(params)} do
      {service_id, {:ok, offset}} when is_binary(service_id) ->
        {:ok, {:copy, ids, service_id, offset, params[:skip_existing] != false}}

      {_service_id, :invalid} ->
        :incomplete

      _no_target ->
        {:error, :calendar_not_found}
    end
  end

  # The offset the typed first departure asks for: zero for "Same times", the
  # reading minus the anchor otherwise. Anything else — an unreadable time, a
  # seconds-precision reading, an offset beyond the engine's ±24 h — is `:invalid`.
  defp copy_offset(%{mode: :same}), do: {:ok, 0}

  defp copy_offset(%{mode: :at, first_departure: text, anchor_secs: anchor})
       when is_integer(anchor) and is_binary(text) do
    case TimeEntry.parse(text, []) do
      {:ok, %{secs: secs}} ->
        offset = secs - anchor

        if rem(offset, 60) == 0 and abs(offset) <= @max_copy_offset_secs,
          do: {:ok, offset},
          else: :invalid

      {:error, _reason} ->
        :invalid
    end
  end

  defp copy_offset(_params), do: :invalid

  # The strip's default timing: the pattern's first timing that not every
  # selected trip already uses (the prototype's default), falling back to the
  # pattern's first. A pattern with no timings has nothing to choose, so the
  # surface opens with `:timed_pattern_required`.
  defp timing_params(socket, ids) do
    timings = pattern_timings(socket, ids)
    used = MapSet.new(Enum.map(ids, &timed_pattern_of(socket, &1)))
    timing = Enum.find(timings, &(not MapSet.member?(used, &1.id))) || List.first(timings)

    %{timing_id: timing && timing.id}
  end

  defp timed_pattern_of(socket, trip_id) do
    case find_row(socket, trip_id) do
      nil -> nil
      row -> row.timed_pattern_id
    end
  end

  defp pattern_timings(socket, [trip_id | _rest]) do
    with %{} = row <- find_row(socket, trip_id),
         %{} = pattern <- change_pattern(socket, row.route_pattern_id) do
      pattern.timings
    else
      _missing -> []
    end
  end

  defp pattern_timings(_socket, []), do: []

  defp one_pattern?(socket, ids) do
    ids
    |> Enum.map(fn id -> socket |> find_row(id) |> row_pattern_id() end)
    |> Enum.uniq()
    |> length() == 1
  end

  defp row_pattern_id(%{route_pattern_id: pattern_id}), do: pattern_id
  defp row_pattern_id(_missing), do: nil

  defp change_pattern(socket, route_pattern_id) do
    Enum.find(socket.assigns.payload.patterns, &(&1.route_pattern_id == route_pattern_id))
  end

  # The posted control values are merged into the change's own parameter map. A
  # malformed, forged or unknown value is ignored, so the reviewed command can
  # only ever name the trips and positions the change opened with (FH-30, CR-5).
  defp update_change(socket, raw) do
    case socket.assigns.change do
      %{} = change ->
        if editor_access?(socket) do
          previous_ids = preview_ids(change)
          params = merge_change_params(socket, change, change_param_map(raw))

          socket
          |> assign(:change, %{change | params: params, refusal: nil, stale?: false})
          |> load_change_review()
          |> restream_change(previous_ids)
        else
          refuse_unauthorized(socket, change)
        end

      nil ->
        socket
    end
  end

  # A form posts its fields flat; a surface that nests them under its own key
  # posts `%{"change" => %{...}}`. Both shapes are read.
  defp change_param_map(%{"change" => params}) when is_map(params), do: params
  defp change_param_map(params) when is_map(params), do: params

  defp merge_change_params(socket, %{kind: :shift} = change, raw) do
    change.params
    |> merge_shift_direction(raw)
    |> merge_shift_minutes(raw)
    |> merge_shift_from_position(socket, change, raw)
  end

  defp merge_change_params(socket, %{kind: :timing} = change, raw) do
    case raw["timing_id"] do
      id when is_binary(id) ->
        if Enum.any?(pattern_timings(socket, change.ids), &(&1.id == id)),
          do: %{change.params | timing_id: id},
          else: change.params

      _other ->
        change.params
    end
  end

  defp merge_change_params(socket, %{kind: :copy} = change, raw) do
    change.params
    |> merge_change_target(socket, raw["service_id"])
    |> merge_change_skip(raw["skip_existing"])
  end

  defp merge_change_params(socket, %{kind: :move} = change, raw) do
    merge_change_target(change.params, socket, raw["service_id"])
  end

  # The paste dialog's own fields. The target must be a service day the dialog
  # offered (every service day of the version), the times choice is one of the
  # two the reference shows, and the typed first departure is kept verbatim so an
  # unreadable time stays in the input with its error (the command builder
  # decides whether it is usable).
  defp merge_change_params(socket, %{kind: :paste} = change, raw) do
    change.params
    |> merge_paste_target(socket, raw["service_id"])
    |> merge_paste_mode(raw["mode"])
    |> merge_paste_departure(raw["first_departure"])
    |> merge_change_skip(raw["skip_existing"])
  end

  # A duplicate is pinned to the current service day (R7), so it has no target
  # field to merge: only its first departure and skip choice reach the command.
  defp merge_change_params(_socket, %{kind: :duplicate} = change, raw) do
    change.params
    |> merge_paste_departure(raw["first_departure"])
    |> merge_change_skip(raw["skip_existing"])
  end

  # Convert has no controls to merge: its command is the change's own trip, so a
  # stray post cannot widen or alter it.
  defp merge_change_params(_socket, %{kind: :convert} = change, _raw), do: change.params

  # Only a service day the paste dialog offered can become the target, so a
  # forged id never widens the reviewed command (CR-5, FH-30).
  defp merge_paste_target(params, socket, value) when is_binary(value) do
    if Enum.any?(paste_target_options(socket.assigns), &(&1.value == value)),
      do: Map.put(params, :service_id, value),
      else: params
  end

  defp merge_paste_target(params, _socket, _value), do: params

  defp merge_paste_mode(params, value) when value in ["same", :same],
    do: Map.put(params, :mode, :same)

  defp merge_paste_mode(params, value) when value in ["at", :at],
    do: Map.put(params, :mode, :at)

  defp merge_paste_mode(params, _value), do: params

  # Only a service day the drawer offered can become the target, so a forged id
  # never widens the reviewed command (CR-5, FH-30).
  defp merge_change_target(params, socket, value) when is_binary(value) do
    if Enum.any?(change_target_options(socket.assigns), &(&1.value == value)),
      do: Map.put(params, :service_id, value),
      else: params
  end

  defp merge_change_target(params, _socket, _value), do: params

  # The skip checkbox posts "true"/"false" (the core input's hidden field); any
  # other value leaves the current choice alone.
  defp merge_change_skip(params, value) when value in ["true", "false", true, false],
    do: Map.put(params, :skip_existing, value in ["true", true])

  defp merge_change_skip(params, _value), do: params

  # The typed first departure is control text, so it is kept as typed: an
  # unreadable value must stay in the input with the dialog's own error rather
  # than snapping back to the previous reading.
  defp merge_paste_departure(params, value) when is_binary(value),
    do: Map.put(params, :first_departure, String.trim(value))

  defp merge_paste_departure(params, _value), do: params

  defp merge_shift_direction(params, raw) do
    case raw["direction"] do
      value when value in ["1", 1, "later"] -> %{params | direction: 1}
      value when value in ["-1", -1, "earlier"] -> %{params | direction: -1}
      _other -> params
    end
  end

  # A posted blank or malformed value clears the minutes, so the strip shows no
  # review and a disabled primary instead of applying the previous value the
  # field no longer shows.
  defp merge_shift_minutes(params, raw) do
    case Map.fetch(raw, "minutes") do
      {:ok, value} ->
        case shift_minutes(value) do
          {:ok, minutes} -> %{params | minutes: minutes}
          :error -> %{params | minutes: nil}
        end

      :error ->
        params
    end
  end

  defp shift_minutes(value) when is_integer(value), do: shift_minutes_integer(value)

  defp shift_minutes(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {minutes, ""} -> shift_minutes_integer(minutes)
      _other -> :error
    end
  end

  defp shift_minutes(_value), do: :error

  defp shift_minutes_integer(minutes) when minutes in 0..@max_shift_minutes, do: {:ok, minutes}
  defp shift_minutes_integer(_minutes), do: :error

  defp merge_shift_from_position(params, socket, change, raw) do
    case change_from_position(socket, change, raw["from_position"]) do
      {:ok, position} -> %{params | from_position: position}
      :error -> params
    end
  end

  # "Whole trip" arrives as an empty value or 0; any other position must be a
  # column this page displays, so a forged position cannot widen the shift
  # beyond what the strip offered.
  defp change_from_position(_socket, _change, value) when value in [nil, "", "0", 0],
    do: {:ok, nil}

  defp change_from_position(socket, change, value) do
    with {:ok, position} <- positive_position(value),
         true <- displayed_position?(socket, change.ids, position) do
      {:ok, position}
    else
      _other -> :error
    end
  end

  defp positive_position(value) when is_integer(value) and value >= 1, do: {:ok, value}

  defp positive_position(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {position, ""} when position >= 1 -> {:ok, position}
      _other -> :error
    end
  end

  defp positive_position(_value), do: :error

  defp displayed_position?(socket, [trip_id | _rest], position) do
    case find_section(socket, trip_id) do
      {_dom_id, section} -> Enum.any?(section.columns, &(&1.position == position))
      nil -> false
    end
  end

  defp displayed_position?(_socket, _ids, _position), do: false

  # The reviewed fingerprint is the only fence a bulk command accepts (R3,
  # INV-2). A stale result is replaced by the fresh review the engine re-planned
  # under lock and marked, so the surface offers Refresh instead of applying
  # (FH-33); a refused change keeps its review and carries the errors; any other
  # failure, a revoked editor role included, writes nothing and is rendered by the
  # open surface, because the strip, drawer or dialog covers the bar. A busy
  # write is a notice that leaves the primary enabled, so a repeat click retries.
  defp apply_change(socket) do
    case socket.assigns.change do
      %{review: %{}} = change ->
        if change.stale?, do: socket, else: submit_change(socket, change)

      _no_review ->
        socket
    end
  end

  defp submit_change(socket, %{review: %{command: command, fingerprint: fingerprint}} = change) do
    change = %{change | notice: nil}

    case Gtfs.apply_trip_change(
           socket.assigns.route_id,
           command,
           {:reviewed, fingerprint},
           audit_context(socket)
         ) do
      {:ok, result} ->
        applied_change(socket, change, result)

      {:error, {:stale_review, review}} ->
        previous_ids = preview_ids(socket.assigns.change)

        socket
        |> assign(:change, %{change | review: review, refusal: nil, stale?: true})
        |> restream_change(previous_ids)

      {:error, {:refused, errors}} ->
        assign(socket, :change, %{change | refusal: errors})

      {:error, :busy} ->
        assign(socket, :change, %{change | notice: ScheduleComponents.error_message(:busy)})

      # The open strip, drawer or dialog covers the bar, so the surface itself
      # renders the reason and disables its primary.
      {:error, reason} ->
        assign(socket, :change, %{change | refusal: [{:error, reason}]})
    end
  end

  # The open surface renders the refusal and disables its primary; the review
  # stays, so nothing on screen changes but the reason.
  defp refuse_unauthorized(socket, change) do
    assign(socket, :change, %{change | notice: nil, refusal: [{:error, :unauthorized}]})
  end

  # A successful apply is one write: the page reloads, the changed rows take the
  # just-changed tint, the outcome is undoable, and the surface and the selection
  # are cleared (the prototype's apply). The rows the preview covered are
  # re-streamed even when the reload leaves them out of `just_changed`, so no
  # amber cell survives the apply.
  defp applied_change(socket, change, result) do
    message = change_outcome(socket, change, result)
    undo? = not is_nil(result.restore)
    previous_ids = preview_ids(socket.assigns.change)

    socket
    |> assign(:change, nil)
    |> assign(:selected_ids, MapSet.new())
    |> assign(:selected_count, 0)
    |> assign(:just_changed, MapSet.new(result.changed_trip_ids))
    |> assign(:cell_error, nil)
    |> assign(:outcome, %{tone: :info, text: message, undo?: undo?})
    |> push_undo(result.restore, message)
    |> reload_cell(MapSet.new(previous_ids))
  end

  # What the bar says after an apply, in the prototype's words. A shift names the
  # minutes and direction and adds that blocks were kept when a shifted trip has
  # one; a timing change names the timing the trips took.
  defp change_outcome(socket, %{kind: :shift, params: params}, result) do
    direction = if params.direction > 0, do: "later", else: "earlier"

    kept =
      if Enum.any?(result.changed_trip_ids, &block_kept?(socket, &1)),
        do: " Blocks are kept.",
        else: ""

    "Shifted #{trip_count_label(length(result.changed_trip_ids))} #{params.minutes} min " <>
      "#{direction}.#{kept}"
  end

  defp change_outcome(socket, %{kind: :timing, params: %{timing_id: timing_id}}, result) do
    count = length(result.changed_trip_ids)
    verb = if count == 1, do: "now uses", else: "now use"

    "#{trip_count_label(count)} #{verb} #{timing_name(socket, timing_id)}."
  end

  # A copy names what it created and what the default skip left alone; a move
  # names the trips and the blocks they left (the reference's two bodies).
  defp change_outcome(socket, %{kind: :copy, params: params}, result) do
    skipped = consequence_count(result.change_set.consequences, :skipped_existing)

    "Copied #{trip_count_label(length(result.created_trip_ids))} to " <>
      "#{calendar_name(socket, params.service_id)}.#{skipped_clause(skipped)}"
  end

  defp change_outcome(socket, %{kind: :move, params: params}, result) do
    blocks = cleared_blocks(result.change_set.consequences)

    "Moved #{trip_count_label(length(result.changed_trip_ids))} to " <>
      "#{calendar_name(socket, params.service_id)}.#{cleared_block_clause(blocks)}"
  end

  # A paste and a duplicate name the day they added trips to and what the skip
  # choice left alone, the same shape as a copy's report.
  defp change_outcome(socket, %{kind: :paste, params: params}, result) do
    skipped = consequence_count(result.change_set.consequences, :skipped_existing)

    "Pasted #{trip_count_label(length(result.created_trip_ids))} on " <>
      "#{calendar_name(socket, params.service_id)}.#{skipped_clause(skipped)}"
  end

  defp change_outcome(socket, %{kind: :duplicate, params: params}, result) do
    skipped = consequence_count(result.change_set.consequences, :skipped_existing)

    "Duplicated #{trip_count_label(length(result.created_trip_ids))} on " <>
      "#{calendar_name(socket, params.service_id)}.#{skipped_clause(skipped)}"
  end

  # Convert names the listed trips it created. It is not undoable, so its outcome
  # offers no Undo (R10, AC-19).
  defp change_outcome(_socket, %{kind: :convert}, result) do
    count = length(result.created_trip_ids)
    noun = if count == 1, do: "scheduled trip", else: "scheduled trips"
    "Converted frequency service to #{count} #{noun}."
  end

  defp skipped_clause(0), do: " They start without a block."

  defp skipped_clause(1),
    do: " 1 trip was skipped because it already leaves at the same time."

  defp skipped_clause(count),
    do: " #{count} trips were skipped because they already leave at the same time."

  defp cleared_block_clause([]), do: " Blocks are kept."

  defp cleared_block_clause([block]),
    do: " 1 trip left block #{block}."

  defp cleared_block_clause(blocks),
    do: " #{length(blocks)} trips left block #{Enum.join(blocks, ", ")}."

  defp cleared_blocks(consequences) do
    consequences
    |> Enum.flat_map(fn
      {:note, {:cleared_block, _id, block}} -> [block]
      _consequence -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp consequence_count(consequences, tag) do
    Enum.count(consequences, &match?({:note, {^tag, _id, _block}}, &1))
  end

  defp block_kept?(socket, trip_id) do
    case find_row(socket, trip_id) do
      nil -> false
      row -> is_binary(row.block_id)
    end
  end

  defp timing_name(socket, timing_id), do: timing_label(socket.assigns, timing_id)

  defp timing_label(assigns, timing_id) do
    timings = Enum.flat_map(assigns.payload.patterns, &Map.get(&1, :timings, []))

    case Enum.find(timings, &(&1.id == timing_id)) do
      nil -> "the timing"
      timing -> timing.name
    end
  end

  defp refresh_change(socket) do
    case socket.assigns.change do
      %{} = change ->
        if editor_access?(socket) do
          previous_ids = preview_ids(change)

          socket
          |> assign(:change, %{change | stale?: false, refusal: nil})
          |> load_change_review()
          |> restream_change(previous_ids)
        else
          refuse_unauthorized(socket, change)
        end

      nil ->
        socket
    end
  end

  # Cancel keeps the selection so the verbs stay in reach (the prototype's close).
  defp cancel_change(socket) do
    case socket.assigns.change do
      %{} = change ->
        previous_ids = preview_ids(change)

        socket
        |> assign(:change, nil)
        |> restream_change(previous_ids)

      nil ->
        socket
    end
  end

  # The strip's view data: the who-label, the preview line, the consequence
  # context (the calendar the after-midnight note names), the Shift "Starting at"
  # options and the timing select. It reads the loaded sections the review was
  # planned against; the review itself stays the component's own input, so the
  # consequence copy has one home.
  defp change_strip_view(%{change: %{kind: kind} = change} = assigns)
       when kind in [:shift, :timing] do
    %{
      who: change_who(assigns, change),
      preview_lines: change_preview_lines(assigns, change),
      blocks_kept?: change_blocks_kept?(assigns, change),
      calendar_label: calendar_label(assigns.payload.calendars, assigns.filters.service_id),
      from_options: change_from_options(assigns, change),
      timing_options: change_timing_options(assigns, change),
      timing_label: change_timing_label(assigns, change)
    }
  end

  defp change_strip_view(_assigns), do: nil

  # The Change review drawer's loaded view data: the two service-day names, the
  # target options, the selected rows' trip numbers, departures and blocks, and
  # the control that returns focus when the drawer closes. The review itself
  # stays the component's own input, so its counts, inserts and notes have one
  # consumer.
  defp change_drawer_view(%{change: %{kind: kind} = change} = assigns)
       when kind in [:copy, :move] do
    options = change_target_options(assigns)
    target = Enum.find(options, &(&1.value == change.params[:service_id]))

    %{
      from: calendar_label(assigns.payload.calendars, assigns.filters.service_id),
      to: target && target.name,
      target_options: Enum.map(options, &{&1.label, &1.value}),
      rows: change_drawer_rows(assigns, change),
      return_focus_id: if(kind == :copy, do: "bulk-copy", else: "bulk-move")
    }
  end

  defp change_drawer_view(_assigns), do: nil

  # The selected trips in departure order, as the reviewed table shows them: the
  # natural trip ID, the departure (a frequency trip shows its window, the way
  # the drawer states it) and the block the trip carries now.
  defp change_drawer_rows(assigns, %{ids: ids}) do
    ids
    |> Enum.flat_map(fn trip_id ->
      case strip_row(assigns, trip_id) do
        nil ->
          []

        row ->
          [
            %{
              trip_id: row.id,
              label: row.trip_id,
              clock: row.frequency_label || row.start_cell.text,
              block_id: row.block_id
            }
          ]
      end
    end)
    |> Enum.sort_by(&{&1.clock, &1.label})
  end

  # The Convert dialog's loaded view data: the context line (the pattern, the
  # service day and the stored window summary), the service day and natural trip
  # ID the card names, the timing every departure follows and the focus the
  # dialog returns to when it closes. The review stays the component's own input,
  # so its inserts fill the departures table, its deletes and transfer note fill
  # the metrics and its consequences raise the refusal banner.
  defp convert_dialog_view(%{change: %{kind: :convert} = change} = assigns) do
    row = change.ids |> List.first() |> then(&strip_row(assigns, &1))

    %{
      context: convert_context(assigns, row),
      service_name: convert_service_name(assigns, row),
      trip_id: row && row.trip_id,
      departures_label: convert_departures_label(assigns, row),
      return_focus_id: row && "trip-#{row.trip_id}-edit"
    }
  end

  defp convert_dialog_view(_assigns), do: nil

  defp convert_context(assigns, row) do
    [
      convert_pattern_name(assigns, row),
      convert_service_name(assigns, row),
      convert_window_summary(row)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp convert_pattern_name(assigns, %{route_pattern_id: route_pattern_id}) do
    case Enum.find(assigns.payload.patterns, &(&1.route_pattern_id == route_pattern_id)) do
      nil -> nil
      pattern -> pattern.name
    end
  end

  defp convert_pattern_name(_assigns, _row), do: nil

  defp convert_service_name(assigns, %{service_id: service_id}) when is_binary(service_id) do
    calendar_label(assigns.payload.calendars, service_id)
  end

  defp convert_service_name(assigns, _row) do
    calendar_label(assigns.payload.calendars, assigns.filters.service_id)
  end

  # The reference's context fragment: the first window's headway and the span
  # every stored window covers. A row without stored windows contributes none.
  defp convert_window_summary(%{frequencies: [_ | _] = frequencies}) do
    windows = Enum.sort_by(frequencies, &stored_start_sort_key/1)
    first = hd(windows)
    last = List.last(windows)
    minutes = round((first.headway_secs || 0) / 60)

    "every #{minutes} min, #{stored_clock(first.start_time)}–#{stored_clock(last.end_time)}"
  end

  defp convert_window_summary(_row), do: nil

  defp stored_clock(value) do
    case GtfsTime.parse(value) do
      {:ok, secs} -> clock(secs)
      {:error, _reason} -> to_string(value)
    end
  end

  # The departures table's label names the timing each new trip follows, the way
  # the reference's does; a custom source follows its own stored times.
  defp convert_departures_label(assigns, %{timed_pattern_id: timing_id})
       when is_binary(timing_id) do
    "Departures, each a trip with #{timing_label(assigns, timing_id)} timing"
  end

  defp convert_departures_label(_assigns, _row), do: "Departures"

  # The paste and duplicate dialog's loaded view data: the context line (the
  # service day the trips come from and their departures, or the duplicate's own
  # day), every service day the target select offers, the typed-time error and
  # the focus the dialog returns to when it closes. The review stays the
  # component's own input, so its inserts and skips have one consumer.
  defp change_paste_view(%{change: %{kind: kind} = change} = assigns)
       when kind in [:paste, :duplicate] do
    duplicate? = kind == :duplicate
    prefix = if duplicate?, do: "duplicate", else: "paste"
    options = paste_target_options(assigns)
    target = Enum.find(options, &(&1.value == change.params[:service_id]))
    rows = paste_rows(assigns, change.ids)

    %{
      duplicate?: duplicate?,
      prefix: prefix,
      dialog_id: "#{prefix}-dialog",
      context: paste_context(assigns, change, duplicate?, target, rows),
      target_options: Enum.map(options, &{&1.label, &1.value}),
      target_name: target && target.name,
      same_help: paste_same_help(rows),
      time_error: paste_time_error(change.params),
      return_focus_id: paste_return_focus(assigns, change.ids),
      initial_focus_id:
        if(change.params[:mode] == :at, do: "#{prefix}-at", else: "#{prefix}-apply")
    }
  end

  defp change_paste_view(_assigns), do: nil

  # The clipboard's trips as the pages shows them, in either order; a row the
  # reload dropped contributes nothing here and the engine refuses its command.
  defp paste_rows(assigns, ids) do
    Enum.flat_map(ids, fn trip_id ->
      case strip_row(assigns, trip_id) do
        nil -> []
        row -> [row]
      end
    end)
  end

  # The copied departures' span, in the reference's "17:00–17:40" form, or nil
  # when no copied trip is loaded any more.
  defp paste_range(rows) do
    clocks =
      rows
      |> Enum.flat_map(fn row ->
        if is_integer(row.start_secs), do: [clock(row.start_secs)], else: []
      end)
      |> Enum.sort()

    case clocks do
      [] -> nil
      [single] -> single
      clocks -> "#{List.first(clocks)}–#{List.last(clocks)}"
    end
  end

  defp paste_pattern_names(assigns, rows) do
    rows
    |> Enum.map(& &1.route_pattern_id)
    |> Enum.uniq()
    |> Enum.flat_map(fn pattern_id ->
      case Enum.find(assigns.payload.patterns, &(&1.route_pattern_id == pattern_id)) do
        nil -> []
        pattern -> [pattern.name]
      end
    end)
    |> Enum.join(", ")
  end

  # The reference's context line: a paste names the source day and the pattern
  # the trips run on; a duplicate names the day it copies within (R7's current
  # service) and its departures.
  defp paste_context(_assigns, _change, true = _duplicate?, target, rows) do
    Enum.join(Enum.reject([target && target.name, paste_range(rows)], &is_nil/1), " · ")
  end

  defp paste_context(assigns, _change, _duplicate?, _target, rows) do
    source =
      calendar_label(assigns.payload.calendars, assigns.clipboard && assigns.clipboard.service_id)

    range = paste_range(rows)
    patterns = paste_pattern_names(assigns, rows)

    case {range, patterns} do
      {nil, ""} -> "Copied from #{source}"
      {nil, patterns} -> "Copied from #{source} · #{patterns}"
      {range, ""} -> "Copied from #{source}: #{range}"
      {range, patterns} -> "Copied from #{source}: #{range} · #{patterns}"
    end
  end

  defp paste_same_help(rows) do
    case paste_range(rows) do
      nil -> "As copied"
      range -> "#{range}, as copied"
    end
  end

  # The dialog's own error for a typed first departure the command cannot use.
  # An empty field is the choice's own "type a time" state, not an error yet.
  defp paste_time_error(params) do
    case params[:first_departure] do
      text when is_binary(text) and text != "" ->
        if copy_offset(params) == :invalid, do: @paste_time_error, else: nil

      _empty ->
        nil
    end
  end

  # Focus returns to the grid's own scroll region, the nearest stable element to
  # the row the pasted trips were copied from (the reference returns the cursor).
  defp paste_return_focus(assigns, [trip_id | _rest]) do
    case strip_section(assigns, trip_id) do
      {dom_id, _section} -> "#{dom_id}-table-container"
      nil -> nil
    end
  end

  defp paste_return_focus(_assigns, _ids), do: nil

  defp change_who(assigns, %{ids: [trip_id]}) do
    case strip_row(assigns, trip_id) do
      %{start_cell: %{text: text}} -> "the #{text} trip"
      _missing -> trip_count_label(1)
    end
  end

  defp change_who(_assigns, %{ids: ids}), do: trip_count_label(length(ids))

  # The reference's first consequence line: the reviewed first departures, the
  # earliest three shown and the rest counted.
  defp change_preview_lines(assigns, %{kind: :shift, review: %{preview: preview}} = change) do
    pairs =
      change.ids
      |> Enum.flat_map(fn trip_id ->
        with %{start_secs: old} when is_integer(old) <- strip_row(assigns, trip_id),
             %{} = cells <- Map.get(preview, trip_id),
             new when is_integer(new) <- Map.get(cells, 1) do
          [{old, new}]
        else
          _unreadable -> []
        end
      end)
      |> Enum.sort_by(&elem(&1, 0))

    case pairs do
      [] -> []
      pairs -> [shift_preview_line(pairs)]
    end
  end

  defp change_preview_lines(
         assigns,
         %{kind: :timing, params: %{timing_id: timing_id}, review: %{}} = change
       ) do
    with %{name: name, rows: rows} <- strip_timing(assigns, timing_id),
         {_dom_id, section} <- change_strip_section(assigns, change.ids),
         [%{stop_name: stop_name} | _rest] <- section.columns do
      [
        "Departures from #{stop_name} stay the same. #{name} takes " <>
          "#{timing_minutes(rows)} min end to end."
      ]
    else
      _missing -> []
    end
  end

  defp change_preview_lines(_assigns, _change), do: []

  defp shift_preview_line(pairs) do
    shown = Enum.take(pairs, 3)
    more = length(pairs) - length(shown)

    text =
      Enum.map_join(shown, ", ", fn {old, new} ->
        "#{clock(old)} → #{clock(new)}"
      end)

    if more > 0, do: "#{text}, and #{more} more.", else: "#{text}."
  end

  # A shift keeps every block (R4), so the reference's sentence is true whenever
  # a shifted trip carries one.
  defp change_blocks_kept?(assigns, %{kind: :shift, ids: ids}) do
    Enum.any?(ids, fn trip_id ->
      match?(%{block_id: block_id} when is_binary(block_id), strip_row(assigns, trip_id))
    end)
  end

  defp change_blocks_kept?(_assigns, _change), do: false

  # "Starting at" is offered only when every selected trip is on one pattern (the
  # reference's onePattern rule); its positions are the displayed timepoints, so
  # the value the strip posts is one the page actually shows.
  defp change_from_options(assigns, %{kind: :shift, ids: ids}) do
    case change_strip_section(assigns, ids) do
      {_dom_id, section} ->
        timepoints = section_timepoint_positions(assigns, section)

        [%{value: 0, label: "Whole trip", stop: nil}] ++
          for column <- section.columns,
              column.position > 1,
              MapSet.member?(timepoints, column.position) do
            %{value: column.position, label: "#{column.stop_name} onward", stop: column.stop_name}
          end

      nil ->
        []
    end
  end

  defp change_from_options(_assigns, _change), do: []

  # Every displayed timepoint the pattern's timings flag; a pattern whose timings
  # flag none falls back to the displayed columns, the same timepoint view
  # `Timetable` builds for it.
  defp section_timepoint_positions(assigns, section) do
    flagged =
      assigns.payload.patterns
      |> Enum.find(&(&1.route_pattern_id == section.pattern.route_pattern_id))
      |> case do
        nil ->
          []

        pattern ->
          for timing <- Map.get(pattern, :timings, []),
              row <- Map.get(timing, :rows, []),
              Map.get(row, :timepoint) == 1,
              do: Map.fetch!(row, :position)
      end

    case flagged do
      [] -> MapSet.new(section.columns, & &1.position)
      positions -> MapSet.new(positions)
    end
  end

  defp change_timing_options(assigns, %{kind: :timing, ids: ids}) do
    for timing <- strip_timings(assigns, ids) do
      {"#{timing.name} · #{timing_minutes(timing.rows)} min", timing.id}
    end
  end

  defp change_timing_options(_assigns, _change), do: []

  defp change_timing_label(assigns, %{kind: :timing, ids: [trip_id | _rest]}) do
    with %{route_pattern_id: pattern_id} <- strip_row(assigns, trip_id),
         %{name: name} <-
           Enum.find(assigns.payload.patterns, &(&1.route_pattern_id == pattern_id)) do
      "Timing for #{name}"
    else
      _missing -> "Timing"
    end
  end

  defp change_timing_label(_assigns, _change), do: nil

  defp strip_timings(assigns, [trip_id | _rest]) do
    with %{route_pattern_id: pattern_id} <- strip_row(assigns, trip_id),
         %{timings: timings} <-
           Enum.find(assigns.payload.patterns, &(&1.route_pattern_id == pattern_id)) do
      timings
    else
      _missing -> []
    end
  end

  defp strip_timings(_assigns, []), do: []

  defp strip_timing(assigns, timing_id) do
    assigns.payload.patterns
    |> Enum.flat_map(&Map.get(&1, :timings, []))
    |> Enum.find(&(&1.id == timing_id))
  end

  defp timing_minutes(rows) do
    rows
    |> Enum.map(fn row ->
      Map.get(row, :arrival_offset) || Map.get(row, :departure_offset) || 0
    end)
    |> Enum.max(fn -> 0 end)
    |> div(60)
  end

  # Every selected trip on one section's pattern, or nil when the selection spans
  # patterns (no "Starting at" and no one-pattern label then).
  defp change_strip_section(assigns, [trip_id | rest]) do
    case strip_section(assigns, trip_id) do
      {dom_id, section} ->
        if Enum.all?(rest, &match?({^dom_id, _section}, strip_section(assigns, &1))) do
          {dom_id, section}
        end

      nil ->
        nil
    end
  end

  defp change_strip_section(_assigns, []), do: nil

  # The assigns-shaped copies of find_section/2 and find_row/2: the strip view is
  # computed while rendering (the template has assigns, not a socket).
  defp strip_section(assigns, trip_id) do
    Enum.find(assigns.section_index, fn {_dom_id, section} ->
      Enum.any?(section.rows, &(&1.id == trip_id))
    end)
  end

  defp strip_row(assigns, trip_id) do
    case strip_section(assigns, trip_id) do
      nil -> nil
      {_dom_id, section} -> Enum.find(section.rows, &(&1.id == trip_id))
    end
  end

  # --- mutations -------------------------------------------------------------

  defp submit_drawer(socket, drawer) do
    case drawer_preview(socket, drawer) do
      %{error: nil} = preview ->
        apply_drawer(socket, %{drawer | preview: preview, errors: %{}, problem: nil})

      %{error: message, target: target} ->
        {:noreply, drawer_field_error(socket, drawer, target, message)}
    end
  end

  defp apply_drawer(socket, %{mode: :add} = drawer) do
    if drawer_run_as(drawer) == "frequency" do
      {:noreply, apply_frequency(socket, drawer)}
    else
      add_trips(socket, drawer)
    end
  end

  # A frequency trip's Edit drawer replaces the frequency notice with the windows
  # editor (step 35): a submit that moved a window or the riders-see choice writes
  # `:update_frequency`; a submit that left both as stored keeps today's metadata
  # edit, and a combined submit writes the windows first, then the details.
  defp apply_drawer(socket, %{mode: :edit} = drawer) do
    if drawer.frequency? do
      update_frequency(socket, drawer)
    else
      update_metadata(socket, drawer)
    end
  end

  defp apply_drawer(socket, %{mode: :duplicate} = drawer) do
    case duplicate_attrs(drawer) do
      {:ok, attrs} ->
        case Gtfs.duplicate_trip(
               socket.assigns.route_id,
               drawer.trip.id,
               attrs,
               audit_context(socket)
             ) do
          {:ok, trip} ->
            {:noreply, duplicated(socket, drawer, trip)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, drawer_changeset_error(socket, drawer, changeset)}

          {:error, reason} ->
            {:noreply, drawer_problem(socket, drawer, reason)}
        end

      {:error, field, message} ->
        {:noreply, drawer_field_error(socket, drawer, field, message)}
    end
  end

  # The Edit drawer's metadata save, unchanged from the page's own edit path,
  # fenced by the `updated_at` the drawer opened.
  defp update_metadata(socket, drawer) do
    case update_attrs(drawer) do
      {:ok, attrs} ->
        case Gtfs.update_trip(
               socket.assigns.route_id,
               drawer.trip.id,
               attrs,
               drawer.trip.updated_at,
               audit_context(socket)
             ) do
          {:ok, trip} ->
            {:noreply, saved_trip(socket, drawer, trip, attrs)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, drawer_changeset_error(socket, drawer, changeset)}

          {:error, reason} ->
            {:noreply, drawer_problem(socket, drawer, reason)}
        end

      {:error, field, message} ->
        {:noreply, drawer_field_error(socket, drawer, field, message)}
    end
  end

  defp update_frequency(socket, drawer) do
    case frequency_edit_command(drawer) do
      {:ok, command} ->
        apply_frequency_edit(socket, drawer, command)

      :unchanged ->
        update_metadata(socket, drawer)

      :error ->
        {:noreply,
         drawer_field_error(
           socket,
           drawer,
           :windows,
           ScheduleComponents.frequency_preview_error()
         )}
    end
  end

  # Frequency service is one command with no prior row to fence (`:add_frequency`
  # takes `:none`), so the drawer applies it directly, pushes the restore payload
  # for Undo and reports the write on the grid bar (AC-17, AC-21).
  defp apply_frequency(socket, drawer) do
    case frequency_command(drawer.values) do
      {:ok, command} ->
        apply_frequency_command(socket, drawer, command)

      :error ->
        drawer_field_error(
          socket,
          drawer,
          :windows,
          ScheduleComponents.frequency_preview_error()
        )
    end
  end

  defp apply_frequency_command(socket, drawer, command) do
    case Gtfs.apply_trip_change(socket.assigns.route_id, command, :none, audit_context(socket)) do
      {:ok, result} ->
        added_frequency(socket, drawer, command, result)

      {:error, {:refused, errors}} ->
        frequency_refused(socket, drawer, errors)

      {:error, %Ecto.Changeset{} = changeset} ->
        drawer_changeset_error(socket, drawer, changeset)

      {:error, reason} ->
        drawer_problem(socket, drawer, reason)
    end
  end

  # Adding frequency service is undoable (R10): the created trip takes the
  # just-changed tint, the bar names the service day and the span, and Undo holds
  # the restore payload the engine captured.
  defp added_frequency(socket, drawer, command, result) do
    message = frequency_outcome(socket, drawer, command)

    socket
    |> assign(:drawer, nil)
    |> assign(:cell_error, nil)
    |> assign(:just_changed, MapSet.new(result.created_trip_ids ++ result.changed_trip_ids))
    |> assign(:outcome, %{tone: :info, text: message, undo?: not is_nil(result.restore)})
    |> push_undo(result.restore, message)
    |> reload_cell()
  end

  defp frequency_outcome(socket, drawer, {:add_frequency, attrs}) do
    first = List.first(attrs.windows)
    last = List.last(attrs.windows)
    riders = if attrs.exact_times == 0, do: "every N minutes", else: "each departure time"
    day = calendar_name(socket, drawer.values["service_id"])

    "Added frequency service to #{day}: #{clock(first.start_secs)}–#{clock(last.end_secs)}. " <>
      "Riders see #{riders}."
  end

  # The R9 refusal is the run-as choice's own error: the service day is the field
  # the user changes, so the sentence stays under the choice cards and the one
  # primary is unavailable until something changes (FH-35, AC-20).
  defp frequency_refused(socket, drawer, errors) do
    case Enum.find(errors, &match?({:error, {:mixed_service, _details}}, &1)) do
      {:error, {:mixed_service, _details}} ->
        message =
          ScheduleComponents.mixed_service_choice_message(
            calendar_name(socket, drawer.values["service_id"])
          )

        drawer_field_error(socket, drawer, :run_as, message)

      _other ->
        drawer_problem(socket, drawer, {:refused, errors})
    end
  end

  # A frequency trip's window edit writes `:update_frequency` behind the row the
  # drawer opened (INV-2, R3): a stale page or a changed row writes nothing. The
  # trip's details save through the page's own `update_trip/5` path after the
  # windows, because the window write forces a new `updated_at` the details request
  # fences on (`update_trip/5` has no unfenced form).
  defp apply_frequency_edit(socket, drawer, command) do
    fence = {:expected, %{drawer.trip.id => drawer.trip.updated_at}}

    case Gtfs.apply_trip_change(socket.assigns.route_id, command, fence, audit_context(socket)) do
      {:ok, result} ->
        case write_frequency_details(socket, drawer, result) do
          {:ok, result} -> {:noreply, frequency_saved(socket, command, result)}
          {:error, socket} -> {:noreply, socket}
        end

      {:error, {:refused, errors}} ->
        {:noreply, drawer_problem(socket, drawer, {:refused, errors})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, drawer_changeset_error(socket, drawer, changeset)}

      {:error, reason} ->
        {:noreply, drawer_problem(socket, drawer, reason)}
    end
  end

  # A submit that changed only a window writes no details: its details equal the
  # drawer's prefill of the stored row (a blank accessibility shows as "0"), so
  # sending them would store 0 over a blank and add a second audit entry. Changed
  # details save through the page's `update_trip/5` fenced on the timestamp the
  # engine captured for the window write, since the row the drawer loaded is
  # already stale. That write forces a newer `updated_at`, so the result's restore
  # payload is re-fenced on it: Undo still restores the windows and template the
  # window write replaced, and the details are never part of its capture (R10).
  defp write_frequency_details(socket, drawer, result) do
    if frequency_details_unchanged?(socket, drawer) do
      {:ok, result}
    else
      update_frequency_details(socket, drawer, result)
    end
  end

  defp frequency_details_unchanged?(socket, drawer) do
    Map.take(drawer.values, @frequency_detail_keys) ==
      Map.take(edit_values(socket, drawer.trip), @frequency_detail_keys)
  end

  defp update_frequency_details(socket, drawer, result) do
    case {update_attrs(drawer), written_updated_at(result, drawer.trip.id)} do
      {{:ok, attrs}, %DateTime{} = updated_at} ->
        case Gtfs.update_trip(
               socket.assigns.route_id,
               drawer.trip.id,
               attrs,
               updated_at,
               audit_context(socket)
             ) do
          {:ok, trip} ->
            {:ok, refence_restore(result, drawer.trip.id, trip.updated_at)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error, frequency_details_failed(socket, drawer, changeset)}

          {:error, reason} ->
            {:error, frequency_details_failed(socket, drawer, reason)}
        end

      # `:update_frequency` is undoable, so the engine always captures the trip it
      # wrote and this branch is unreachable; a missing capture must not fence the
      # details on a guessed timestamp.
      {_attrs, _missing} ->
        {:error, drawer_problem(socket, drawer, :busy)}
    end
  end

  # The restore payload's fence is the `updated_at` the original write forced; a
  # later write in the same submit moves it, so the payload's entry is re-fenced on
  # the timestamp that write made.
  defp refence_restore(%{restore: %{trips: trips} = restore} = result, trip_id, updated_at) do
    trips =
      Enum.map(trips, fn
        %{id: ^trip_id} = entry -> %{entry | written_updated_at: updated_at}
        entry -> entry
      end)

    %{result | restore: %{restore | trips: trips}}
  end

  defp refence_restore(result, _trip_id, _updated_at), do: result

  # The windows are already saved when the details fail, so the row the drawer
  # still holds is stale: re-read the page so a retry fences on what was written
  # (and reads the windows the write stored) while the typed details stay.
  defp frequency_details_failed(socket, drawer, reason) do
    socket = reload_or_fail(socket)
    drawer = %{drawer | trip: find_row(socket, drawer.trip.id) || drawer.trip}

    case reason do
      %Ecto.Changeset{} = changeset ->
        drawer_changeset_error(socket, drawer, changeset)

      reason ->
        drawer_problem(socket, drawer, reason)
    end
  end

  # A window edit is undoable (R10): the bar names the saved span with Undo and the
  # drawer closes on the reloaded page.
  defp frequency_saved(socket, command, result) do
    message = frequency_update_outcome(command)

    socket
    |> assign(:drawer, nil)
    |> assign(:cell_error, nil)
    |> assign(:just_changed, MapSet.new(result.changed_trip_ids))
    |> assign(:outcome, %{tone: :info, text: message, undo?: not is_nil(result.restore)})
    |> push_undo(result.restore, message)
    |> reload_cell()
  end

  defp frequency_update_outcome({:update_frequency, _trip_id, %{windows: windows}}) do
    first = List.first(windows)
    last = List.last(windows)

    "Saved the frequency service #{clock(first.start_secs)}–#{clock(last.end_secs)}."
  end

  # The timestamp the engine forced on the changed trip, read from the restore
  # capture it also uses for Undo.
  defp written_updated_at(result, trip_id) do
    (result.restore || %{})
    |> Map.get(:trips, [])
    |> Enum.find_value(fn
      %{id: ^trip_id, written_updated_at: updated_at} -> updated_at
      _entry -> nil
    end)
  end

  defp add_trips(socket, drawer) do
    case create_attrs(drawer) do
      {:ok, attrs} ->
        case Gtfs.create_trips(socket.assigns.route_id, attrs, audit_context(socket)) do
          {:ok, %{trips: [first | _] = trips}} ->
            {:noreply, added(socket, attrs, trips, first)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, drawer_changeset_error(socket, drawer, changeset)}

          {:error, reason} ->
            {:noreply, drawer_problem(socket, drawer, reason)}
        end

      {:error, field, message} ->
        {:noreply, drawer_field_error(socket, drawer, field, message)}
    end
  end

  defp added(socket, attrs, trips, first) do
    label = calendar_label(socket.assigns.payload.calendars, attrs.service_id)

    socket
    |> put_flash(:info, "Added #{trip_count_label(length(trips))} to #{label}.")
    |> assign(:drawer, nil)
    |> assign(:vehicle_change_from, current_vehicle_count(socket))
    |> assign(:keep_vehicle_change, true)
    |> push_patch(to: schedule_path(socket, created_filters(socket, first, attrs.pattern_id)))
  end

  defp duplicated(socket, drawer, trip) do
    label = calendar_label(socket.assigns.payload.calendars, trip.service_id)

    socket
    |> put_flash(:info, "Duplicated the #{clock(row_start_secs(drawer))} trip to #{label}.")
    |> assign(:drawer, nil)
    |> assign(:vehicle_change_from, current_vehicle_count(socket))
    |> assign(:keep_vehicle_change, true)
    |> push_patch(
      to: schedule_path(socket, created_filters(socket, trip, pattern_id_for_trip(socket, trip)))
    )
  end

  # A save that changed the block or that never touched it leaves the drawer without
  # a notice: only a D2 clear and a block problem are worth saying out loud. The
  # notice is computed before the reload so it describes the save that just
  # happened, not the page the reload produced.
  defp saved_trip(socket, drawer, trip, attrs) do
    moved? = trip.service_id != socket.assigns.filters.service_id

    message =
      "Saved the #{clock(row_start_secs(drawer))} trip." <>
        if moved? do
          " Moved to #{calendar_label(socket.assigns.payload.calendars, trip.service_id)};" <>
            " it is no longer in this view."
        else
          ""
        end

    socket
    |> put_flash(:info, message)
    |> assign(:drawer, nil)
    |> assign(:vehicle_change_from, current_vehicle_count(socket))
    |> assign(:block_notice, block_notice(socket, drawer, trip, attrs))
    |> reload_or_fail()
  end

  # D2 clears the block inside the save; anything else keeps it. The two notices
  # are alternatives: a trip that lost its block has no block problem left to
  # report, and a trip that kept it is worth checking against its new times. A
  # block with no current problem says nothing (AC-18).
  defp block_notice(socket, drawer, trip, attrs) do
    cond do
      is_binary(drawer.trip.block_id) and is_nil(trip.block_id) ->
        %{
          kind: :block_cleared,
          block_id: drawer.trip.block_id,
          calendar_label: calendar_label(socket.assigns.payload.calendars, trip.service_id),
          link: blocks_link(socket, trip)
        }

      is_binary(trip.block_id) and block_affecting_change?(drawer.trip, attrs) ->
        case block_problems(socket, trip) do
          [] ->
            nil

          problems ->
            %{
              kind: :block_problems,
              block_id: trip.block_id,
              problems: problems,
              link: blocks_link(socket, trip)
            }
        end

      true ->
        nil
    end
  end

  # An unavailable check is not a save failure: the trip is saved, so a failed
  # advisory read simply reports nothing rather than a problem that may not exist.
  defp block_problems(socket, trip) do
    case Gtfs.block_problems_for_trips(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           [trip.trip_id]
         ) do
      {:ok, problems} -> problems
      {:error, _reason} -> []
    end
  end

  # The drawer prefills the timing and the departure from the row, so an edit that
  # changed neither submits the same values. Only a real change to the calendar, the
  # timing or the start is worth re-checking the block for.
  defp block_affecting_change?(row, attrs) do
    attrs[:service_id] != row.service_id or attrs[:timed_pattern_id] != row.timed_pattern_id or
      start_changed?(row, attrs[:start_time])
  end

  defp start_changed?(_row, nil), do: false

  defp start_changed?(row, start_time) do
    case parse_start_clock(start_time) do
      {:ok, start_secs, _value} -> start_secs != row.start_secs
      {:error, _field, _message} -> false
    end
  end

  # The Blocks deep link names the day the trip is easiest to find in and the trip
  # itself; a service with no active date has no day to open, so it gets no link.
  defp blocks_link(socket, trip) do
    case Gtfs.first_blocking_day_type_key(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           trip.service_id
         ) do
      {:ok, day_type_key} when is_binary(day_type_key) ->
        schedule_blocks_path(
          socket.assigns.current_gtfs_version.id,
          %{"day" => day_type_key, "trip" => trip.trip_id}
        )

      _other ->
        nil
    end
  end

  defp block_day_key(socket, row) do
    case Gtfs.first_blocking_day_type_key(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           row.service_id
         ) do
      {:ok, key} -> key
      {:error, _reason} -> nil
    end
  end

  defp deleted(socket, dialog, trips, transfers, ids) do
    selected = MapSet.difference(socket.assigns.selected_ids, MapSet.new(ids))
    label = calendar_label(socket.assigns.payload.calendars, dialog.service_id)

    socket
    |> put_flash(:info, "Deleted #{deleted_label(trips, transfers)} from #{label}.")
    |> assign(:delete_dialog, nil)
    |> assign(:selected_ids, selected)
    |> assign(:selected_count, MapSet.size(selected))
    |> assign(:vehicle_change_from, current_vehicle_count(socket))
    |> reload_or_fail()
  end

  # The flash names the removed transfers only when the transaction removed any,
  # and always keeps the trip count first.
  defp deleted_label(trips, 0), do: trip_count_label(trips)
  defp deleted_label(trips, 1), do: "#{trip_count_label(trips)} and 1 transfer record"

  defp deleted_label(trips, transfers),
    do: "#{trip_count_label(trips)} and #{transfers} transfer records"

  defp reload_or_fail(socket) do
    case reload_schedule(socket) do
      {:ok, socket} -> socket
      {:error, :not_found} -> route_not_found(socket)
      {:error, :unavailable} -> assign(socket, :load_state, :unavailable)
    end
  end

  # The banner's Reactivate: the step-9 status command with this page's saved
  # identity, projected from the scoped route read through the same source
  # shape the details workspace uses. The schedule reloads so the banner
  # describes what is stored now; a refused request says so instead of
  # claiming a change.
  defp do_reactivate_route(socket) do
    route = socket.assigns.route

    case Gtfs.set_route_active(
           route.route_id,
           true,
           Gtfs.route_source(route),
           audit_context(socket)
         ) do
      {:ok, %{route: _saved}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Route #{route.route_id} reactivated. The next export includes it.")
         |> reload_or_fail()}

      {:error, :not_found} ->
        {:noreply, route_not_found(socket)}

      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "The route was updated while this page was open, so the request was refused. The latest saved route is loaded."
         )
         |> reload_or_fail()}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You no longer have editor access to this organization. The route's status is unchanged."
         )}

      {:error, :busy} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The server is busy right now — the route is unchanged. Try again."
         )}

      {:error, _other} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The status could not be changed. The route is unchanged — try again."
         )}
    end
  end

  defp drawer_problem(socket, drawer, reason) do
    assign(socket, :drawer, %{drawer | problem: reason, errors: %{}})
  end

  defp dialog_problem(socket, dialog, reason) do
    assign(socket, :delete_dialog, %{
      dialog
      | error: ScheduleComponents.delete_error_message(reason)
    })
  end

  defp drawer_field_error(socket, drawer, field, message) do
    drawer = %{drawer | errors: Map.put(drawer.errors, field, message), problem: nil}

    socket
    |> assign(:drawer, drawer)
    |> push_event("focus_form_error", %{
      form_id: "trip-drawer-form",
      fallback_id: field_input_id(field)
    })
  end

  defp drawer_changeset_error(socket, drawer, changeset) do
    errors = Map.new(changeset.errors, fn {field, {message, _opts}} -> {field, message} end)

    socket
    |> assign(:drawer, %{drawer | errors: errors, problem: nil})
    |> push_event("focus_form_error", %{
      form_id: "trip-drawer-form",
      fallback_id: errors |> Map.keys() |> List.first() |> field_input_id()
    })
  end

  defp field_input_id(:pattern_id), do: "trip-pattern"
  defp field_input_id(:timed_pattern_id), do: "trip-timing"
  defp field_input_id(:service_id), do: "trip-calendar"
  defp field_input_id(:run_as), do: "trip-run-scheduled"
  defp field_input_id(:start_time), do: "trip-start"
  defp field_input_id(:every), do: "trip-every"
  defp field_input_id(:until), do: "trip-until"
  defp field_input_id(:trip_headsign), do: "trip-headsign"
  defp field_input_id(:trip_short_name), do: "trip-number"
  defp field_input_id(:wheelchair_accessible), do: "trip-access"
  defp field_input_id(:bikes_allowed), do: "trip-bikes"
  defp field_input_id(_field), do: nil

  # --- mutation payloads -----------------------------------------------------

  defp create_attrs(drawer) do
    values = drawer.values

    with {:ok, _start_secs, start_value} <- parse_start_clock(values["start_time"]),
         {:ok, repeat} <- repeat_attrs(values) do
      {:ok,
       %{
         pattern_id: values["pattern_id"],
         timed_pattern_id: values["timed_pattern_id"],
         service_id: values["service_id"],
         start_time: start_value,
         repeat: repeat
       }}
    else
      {:error, field, message} -> {:error, field, message}
    end
  end

  defp repeat_attrs(%{"repeat" => "true"} = values) do
    with {:ok, every} <- parse_every(values["every"]),
         {:ok, _until_secs, until_value} <- parse_until_clock(values["until"]) do
      {:ok, %{every_minutes: every, until: until_value}}
    end
  end

  defp repeat_attrs(_values), do: {:ok, nil}

  # Frequency service has no editable start or timing; a custom trip keeping its
  # times sends neither, so the context never sees a start without a timing.
  defp update_attrs(drawer) do
    values = drawer.values
    custom_kept? = drawer.custom? and values["timed_pattern_id"] in [nil, "custom"]

    attrs = %{
      service_id: values["service_id"],
      trip_headsign: values["trip_headsign"],
      trip_short_name: values["trip_short_name"],
      wheelchair_accessible: values["wheelchair_accessible"],
      bikes_allowed: values["bikes_allowed"]
    }

    cond do
      drawer.frequency? or custom_kept? ->
        {:ok, attrs}

      not is_binary(values["timed_pattern_id"]) or values["timed_pattern_id"] == "custom" ->
        {:error, :timed_pattern_id, "Choose a timing to change this trip's times."}

      true ->
        case parse_start_clock(values["start_time"]) do
          {:ok, _start_secs, start_value} ->
            {:ok,
             Map.merge(attrs, %{
               start_time: start_value,
               timed_pattern_id: values["timed_pattern_id"]
             })}

          {:error, field, message} ->
            {:error, field, message}
        end
    end
  end

  defp duplicate_attrs(drawer) do
    values = drawer.values

    if is_binary(values["timed_pattern_id"]) and values["timed_pattern_id"] != "custom" do
      case parse_start_clock(values["start_time"]) do
        {:ok, _start_secs, start_value} ->
          {:ok, %{start_time: start_value, timed_pattern_id: values["timed_pattern_id"]}}

        {:error, field, message} ->
          {:error, field, message}
      end
    else
      {:error, :timed_pattern_id, "Choose a timing for the duplicated trip."}
    end
  end

  defp created_filters(socket, trip, pattern_id) do
    filters = socket.assigns.filters

    %{}
    |> put_unless_default("service_id", trip.service_id, nil)
    |> put_unless_default("direction", direction_param(trip.direction_id), "0")
    |> put_unless_default("pattern", pattern_id, "all")
    |> put_unless_default("stops", stops_param(filters.stops), "timepoints")
  end

  defp pattern_id_for_trip(socket, trip) do
    case Enum.find(
           socket.assigns.payload.patterns,
           &(&1.route_pattern_id == trip.route_pattern_id)
         ) do
      nil -> socket.assigns.filters.pattern
      pattern -> pattern.id
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

  # --- drawer state ----------------------------------------------------------

  defp new_drawer(socket, mode, attrs) do
    row = Map.get(attrs, :trip)

    %{
      mode: mode,
      trip: row,
      values: Map.get(attrs, :values, %{}),
      return_focus_id: Map.get(attrs, :return_focus_id),
      errors: %{},
      problem: nil,
      custom?: is_map(row) and row.custom?,
      stops_differ?: is_map(row) and row.stops_differ?,
      frequency?: is_map(row) and row.frequency?,
      frequency_label: is_map(row) && row.frequency_label,
      trip_id: row && row.trip_id,
      block_day_key: Map.get(attrs, :block_day_key),
      route_label: route_label(socket.assigns.payload.route),
      preview: %{error: nil, target: nil, label: drawer_label(mode), meta: nil, range: nil}
    }
  end

  defp drawer_label(:add), do: "Add 1 trip"
  defp drawer_label(:edit), do: "Save trip"
  defp drawer_label(:duplicate), do: "Duplicate trip"

  defp drawer_run_as(%{values: values}), do: values["run_as"] || "scheduled"
  defp drawer_run_as(_drawer), do: "scheduled"

  defp preview_label(%{mode: :add} = drawer) do
    if drawer_run_as(drawer) == "frequency", do: "Add frequency service", else: "Add 1 trip"
  end

  defp preview_label(%{mode: mode}), do: drawer_label(mode)

  defp merge_drawer_values(socket, params) do
    case socket.assigns.drawer do
      nil -> nil
      drawer -> %{drawer | values: Map.merge(drawer.values, clean_values(params)), errors: %{}}
    end
  end

  defp clean_values(params) do
    values = Map.take(params, @drawer_fields)

    case Map.fetch(values, "windows") do
      {:ok, windows} -> Map.put(values, "windows", normalize_windows(windows))
      :error -> values
    end
  end

  # The editor posts `drawer[windows][<index>][from|until|every]`, so the rows
  # arrive as an index-keyed map of typed text and are stored as the component's
  # list shape. A list that reads to nothing keeps one default row: the editor
  # always holds at least one window (its remove button is disabled on the last
  # row), and a request that posts none is not allowed to empty it.
  defp normalize_windows(windows) when is_map(windows) do
    windows
    |> Enum.filter(fn {_index, row} -> is_map(row) end)
    |> Enum.sort_by(fn {index, _row} -> window_index(index) end)
    |> Enum.map(fn {_index, row} -> window_row(row) end)
    |> case do
      [] -> [@default_window]
      rows -> rows
    end
  end

  defp normalize_windows(windows) when is_list(windows), do: Enum.map(windows, &window_row/1)
  defp normalize_windows(_windows), do: [@default_window]

  defp window_row(row) when is_map(row) do
    %{
      from: window_text(row["from"]),
      until: window_text(row["until"]),
      every: window_text(row["every"])
    }
  end

  defp window_row(_row), do: @default_window

  defp window_text(value) when is_binary(value), do: value
  defp window_text(_value), do: ""

  defp window_index(index) do
    case Integer.parse(to_string(index)) do
      {value, _rest} -> value
      :error -> 0
    end
  end

  defp windows(values) do
    case values["windows"] do
      [_window | _rest] = windows -> windows
      _empty -> [@default_window]
    end
  end

  # A new row starts where the last one ends and keeps its gap, so the windows
  # touch and the list stays valid as typed (R8).
  defp next_window(%{until: until_text} = window) do
    case parse_clock_value(until_text) do
      {:ok, until_secs} ->
        %{
          from: clock(until_secs),
          until: clock(until_secs + @window_hours * 3_600),
          every: window.every
        }

      _invalid ->
        @default_window
    end
  end

  defp next_window(_window), do: @default_window

  # The headsign a blank field stores for the drawer's current pattern and timing
  # choice, through the one Headsigns rule (INV-2): the selected timing's own
  # headsign when it has one, else the pattern's. The pattern resolves exactly as
  # the drawer note resolves it, so the button always fills what the note names.
  defp drawer_headsign_default(socket, drawer) do
    patterns = socket.assigns.payload.patterns

    pattern =
      Enum.find(patterns, &(&1.id == drawer.values["pattern_id"])) ||
        Enum.find(patterns, &(&1.route_pattern_id == drawer.trip.route_pattern_id))

    timing = pattern && Enum.find(pattern.timings, &(&1.id == drawer.values["timed_pattern_id"]))

    Headsigns.effective_default(timing && timing.headsign, pattern && pattern.headsign)
  end

  defp edit_values(socket, row) do
    values = %{
      "pattern_id" => row_pattern_uuid(socket, row),
      "timed_pattern_id" => row.timed_pattern_id || "custom",
      "service_id" => row.service_id,
      "start_time" => clock(row.start_secs) || "",
      "trip_headsign" => row.trip_headsign || "",
      "trip_short_name" => row.trip_short_name || "",
      "wheelchair_accessible" => integer_string(row.wheelchair_accessible),
      "bikes_allowed" => integer_string(row.bikes_allowed)
    }

    if row.frequency? do
      Map.merge(values, %{
        "windows" => stored_windows(row),
        "exact_times" => stored_exact_times_choice(row)
      })
    else
      values
    end
  end

  defp duplicate_values(socket, row) do
    %{
      "pattern_id" => row_pattern_uuid(socket, row),
      "timed_pattern_id" => row.timed_pattern_id || first_timing_id(socket, row),
      "service_id" => row.service_id,
      "start_time" => clock((row.start_secs || 0) + @duplicate_offset_secs)
    }
  end

  defp row_pattern_uuid(socket, row) do
    case drawer_pattern(socket, row) do
      nil -> socket.assigns.filters.pattern
      pattern -> pattern.id
    end
  end

  defp first_timing_id(socket, row) do
    case drawer_pattern(socket, row) do
      %{timings: [timing | _]} -> timing.id
      _ -> nil
    end
  end

  defp drawer_pattern(socket, row) do
    Enum.find(socket.assigns.payload.patterns, &(&1.route_pattern_id == row.route_pattern_id))
  end

  defp integer_string(nil), do: "0"
  defp integer_string(value), do: to_string(value)

  defp row_pattern_name(socket, row) do
    case drawer_pattern(socket, row) do
      nil -> "no pattern"
      pattern -> pattern.name
    end
  end

  # --- previews --------------------------------------------------------------

  defp refresh_drawer(socket, drawer) do
    %{drawer | preview: drawer_preview(socket, drawer)}
  end

  defp drawer_preview(socket, %{mode: :add} = drawer) do
    if drawer_run_as(drawer) == "frequency" do
      frequency_add_preview(socket, drawer)
    else
      scheduled_add_preview(socket, drawer)
    end
  end

  defp drawer_preview(socket, %{mode: :edit} = drawer) do
    values = drawer.values
    timing = timing_for(preview_pattern(socket, drawer), values["timed_pattern_id"])
    total = timing_total_minutes(timing)

    meta =
      "#{preview_pattern_name(socket, drawer)} · #{calendar_name(socket, values["service_id"])}"

    cond do
      drawer.frequency? ->
        frequency_edit_preview(drawer, meta)

      drawer.custom? and values["timed_pattern_id"] in [nil, "custom"] ->
        %{
          error: nil,
          target: nil,
          label: "Save trip",
          meta: meta,
          range: nil,
          total_minutes: nil,
          sentence: "Custom times kept.",
          hint: "The existing stop times will stay unchanged."
        }

      true ->
        case parse_clock_value(values["start_time"]) do
          {:ok, start_secs} ->
            %{
              error: nil,
              target: nil,
              label: "Save trip",
              meta: meta,
              range: range_label(start_secs, total),
              total_minutes: total,
              sentence:
                drawer.custom? && "All custom stop times will be replaced by this timing.",
              hint: nil
            }

          _ ->
            error_preview(:start_time, ScheduleComponents.error_message(:invalid_time), drawer)
        end
    end
  end

  defp drawer_preview(socket, %{mode: :duplicate} = drawer) do
    values = drawer.values
    timing = timing_for(preview_pattern(socket, drawer), values["timed_pattern_id"])
    total = timing_total_minutes(timing)
    meta = "#{preview_pattern_name(socket, drawer)} · #{timing && timing.name}"

    case parse_clock_value(values["start_time"]) do
      {:ok, start_secs} ->
        %{
          error: nil,
          target: nil,
          label: "Duplicate trip",
          meta: meta,
          range: range_label(start_secs, total),
          total_minutes: total,
          sentence: "Creates one new trip on the same pattern.",
          hint: "The source trip does not change."
        }

      _ ->
        error_preview(:start_time, ScheduleComponents.error_message(:invalid_time), drawer)
    end
  end

  # The Edit drawer's card for a frequency trip: the same span and departures the
  # windows editor reads (the reference's result card), or the pointer at the row
  # that does not read, so the card never claims a preview the save could not
  # produce (AC-18).
  defp frequency_edit_preview(drawer, meta) do
    case read_windows(windows(drawer.values)) do
      {:ok, windows} -> frequency_preview(windows, meta, preview_label(drawer))
      :error -> error_preview(:windows, ScheduleComponents.frequency_preview_error(), drawer)
    end
  end

  # The frequency mode's card: the span the windows cover and how many departures
  # they add (the reference's result card). A row that does not read, or windows
  # that overlap, show the card's pointer to the highlighted window instead, so
  # nothing here claims a preview the command could not produce (AC-17).
  defp frequency_add_preview(socket, drawer) do
    values = drawer.values

    meta =
      "#{preview_pattern_name(socket, drawer)} · #{calendar_name(socket, values["service_id"])}"

    case read_windows(windows(values)) do
      {:ok, windows} -> frequency_preview(windows, meta, preview_label(drawer))
      :error -> error_preview(:windows, ScheduleComponents.frequency_preview_error(), drawer)
    end
  end

  defp frequency_preview(windows, meta, label) do
    first = List.first(windows)
    last = List.last(windows)
    departures = windows |> Enum.flat_map(&FrequencyWindows.departures/1) |> length()

    %{
      error: nil,
      target: nil,
      label: label,
      meta: meta,
      range: "#{clock(first.start_secs)}–#{clock(last.end_secs)}",
      total_minutes: nil,
      sentence:
        "About #{departures} departures. Not assigned to blocks; counted as ≈ in Trips per hour " <>
          "and Vehicles needed.",
      hint: nil
    }
  end

  # The typed rows read with the page's one grammar (CR-4) and validate with the
  # engine's own R8 rules, so the card and the command agree. The windows come
  # back in start order, which is the order the card's span and the command use.
  defp read_windows(rows) do
    case parsed_windows(rows) do
      {:ok, windows} ->
        case FrequencyWindows.validate(windows) do
          :ok -> {:ok, Enum.sort_by(windows, & &1.start_secs)}
          {:error, _errors} -> :error
        end

      :error ->
        :error
    end
  end

  defp parsed_windows(rows) do
    parsed = Enum.map(rows, &parsed_window/1)

    if Enum.all?(parsed, &match?({:ok, _window}, &1)) do
      {:ok, Enum.map(parsed, fn {:ok, window} -> window end)}
    else
      :error
    end
  end

  defp parsed_window(row) do
    with {:ok, start_secs} <- window_clock(row.from),
         {:ok, end_secs} <- window_clock(row.until),
         {:ok, headway_secs} <- window_headway(row.every) do
      {:ok, %{start_secs: start_secs, end_secs: end_secs, headway_secs: headway_secs}}
    end
  end

  defp window_clock(text) do
    case parse_clock_value(text) do
      {:ok, secs} -> {:ok, secs}
      {:error, _reason} -> :error
    end
  end

  defp window_headway(text) do
    case text |> to_string() |> String.trim() |> Integer.parse() do
      {minutes, ""} when minutes >= 1 -> {:ok, minutes * 60}
      _other -> :error
    end
  end

  # The `:add_frequency` command the drawer submits, built only from the drawer's
  # own choice and the text it read: the client sends no seconds (CR-5).
  defp frequency_command(values) do
    with {:ok, parsed} <- read_windows(windows(values)) do
      {:ok,
       {:add_frequency,
        %{
          pattern_id: values["pattern_id"],
          timed_pattern_id: values["timed_pattern_id"],
          service_id: values["service_id"],
          windows: parsed,
          exact_times: exact_times(values)
        }}}
    end
  end

  # The `:update_frequency` command the Edit drawer submits, built from the drawer's
  # own text and the stored rows it loaded (CR-5). The windows read and validate
  # with the page's one grammar (CR-4), and a typed list that still reads as the
  # stored one - with the riders-see choice still showing the stored choice - is
  # `:unchanged`, so an unrelated details edit submits through `update_trip/5`
  # alone and never rewrites the frequency rows (FH-9, AC-18).
  defp frequency_edit_command(drawer) do
    case read_windows(windows(drawer.values)) do
      {:ok, windows} ->
        choice = frequency_choice(drawer)

        if choice == :keep and windows == stored_parsed_windows(drawer.trip) do
          :unchanged
        else
          {:ok, {:update_frequency, drawer.trip.id, %{windows: windows, exact_times: choice}}}
        end

      :error ->
        :error
    end
  end

  # The riders-see choice is `:keep` while it still reads as the choice the stored
  # rows show, so an unrelated window edit leaves every stored per-row value -
  # including blank - unchanged (FH-9). A blank stored choice displays the default
  # (`1`) but never writes one.
  defp frequency_choice(drawer) do
    case drawer.values["exact_times"] do
      choice when choice in ["0", "1"] ->
        if choice == stored_exact_times_choice(drawer.trip),
          do: :keep,
          else: String.to_integer(choice)

      _other ->
        :keep
    end
  end

  # The choice the stored rows display: the headway choice only when every row
  # stored it, anything else (including a blank row) reads as the default.
  defp stored_exact_times_choice(row) do
    rows = row |> Map.get(:frequencies, []) |> List.wrap()

    if rows != [] and Enum.all?(rows, &(Map.get(&1, :exact_times) == 0)), do: "0", else: "1"
  end

  # The trip's stored rows in the editor's typed text, earliest first. A clock
  # that does not read stays as the raw stored text so the row shows its own
  # error rather than silently dropping a window, and a headway that is not a
  # whole number of minutes has no editor reading and shows the row's error.
  defp stored_windows(row) do
    row
    |> Map.get(:frequencies, [])
    |> List.wrap()
    |> Enum.sort_by(&stored_start_sort_key/1)
    |> Enum.map(fn frequency ->
      %{
        from: stored_clock_text(Map.get(frequency, :start_time)),
        until: stored_clock_text(Map.get(frequency, :end_time)),
        every: stored_headway_text(Map.get(frequency, :headway_secs))
      }
    end)
  end

  defp stored_start_sort_key(frequency) do
    case GtfsTime.parse(Map.get(frequency, :start_time)) do
      {:ok, secs} -> {0, secs}
      {:error, _reason} -> {1, to_string(Map.get(frequency, :start_time))}
    end
  end

  defp stored_clock_text(value) do
    case GtfsTime.parse(value) do
      {:ok, secs} -> clock(secs)
      {:error, _reason} -> if(is_binary(value), do: value, else: "")
    end
  end

  defp stored_headway_text(value)
       when is_integer(value) and value > 0 and rem(value, 60) == 0,
       do: to_string(div(value, 60))

  defp stored_headway_text(_value), do: ""

  # The stored rows read through the same grammar and order as the editor's own
  # `read_windows/1`, so an untouched form compares equal.
  defp stored_parsed_windows(row) do
    case parsed_windows(stored_windows(row)) do
      {:ok, windows} -> Enum.sort_by(windows, & &1.start_secs)
      :error -> :error
    end
  end

  # New service stores `1` (each departure time) unless the riders-see choice
  # picked the headway itself (R8).
  defp exact_times(values) do
    if values["exact_times"] == "0", do: 0, else: 1
  end

  defp scheduled_add_preview(socket, drawer) do
    values = drawer.values
    pattern = preview_pattern(socket, drawer)
    timing = timing_for(pattern, values["timed_pattern_id"])
    meta = "#{pattern && pattern.name} · #{calendar_name(socket, values["service_id"])}"

    case parse_clock_value(values["start_time"]) do
      {:error, _reason} ->
        error_preview(:start_time, ScheduleComponents.error_message(:invalid_time), drawer)

      {:ok, start_secs} ->
        add_preview(drawer, timing, start_secs, meta)
    end
  end

  defp add_preview(drawer, timing, start_secs, meta) do
    if drawer.values["repeat"] == "true" do
      repeat_preview(drawer, timing, start_secs, meta)
    else
      single_preview(timing, start_secs, meta)
    end
  end

  defp repeat_preview(drawer, timing, start_secs, meta) do
    if whole_number?(drawer.values["every"]) do
      repeat_window_preview(drawer, timing, start_secs, meta)
    else
      error_preview(:every, ScheduleComponents.error_message(:invalid_interval), drawer)
    end
  end

  defp repeat_window_preview(drawer, timing, start_secs, meta) do
    case parse_clock_value(drawer.values["until"]) do
      {:error, _reason} ->
        error_preview(:until, ScheduleComponents.error_message(:until_before_start), drawer)

      {:ok, until_secs} when until_secs < start_secs ->
        error_preview(:until, ScheduleComponents.error_message(:until_before_start), drawer)

      {:ok, until_secs} ->
        series_preview(drawer, timing, start_secs, until_secs, meta)
    end
  end

  defp series_preview(drawer, timing, start_secs, until_secs, meta) do
    every = String.to_integer(drawer.values["every"])

    case Schedules.series_starts(start_secs, every, until_secs) do
      {:ok, starts} -> add_series_preview(starts, every, timing, start_secs, meta)
      {:error, reason} -> error_preview(:until, ScheduleComponents.error_message(reason), drawer)
    end
  end

  defp add_series_preview(starts, every, timing, start_secs, meta) do
    total = timing_total_minutes(timing)
    count = length(starts)
    last = List.last(starts)

    %{
      error: nil,
      target: nil,
      label: add_label(count),
      meta: meta,
      range: range_label(start_secs, total),
      total_minutes: total,
      sentence:
        "Adds #{trip_count_label(count)}, #{clock(start_secs)} → #{clock(last)}" <>
          " every #{every} min.",
      hint: "Includes the end time only when a departure falls exactly on it."
    }
  end

  defp single_preview(timing, start_secs, meta) do
    total = timing_total_minutes(timing)

    %{
      error: nil,
      target: nil,
      label: add_label(1),
      meta: meta,
      range: range_label(start_secs, total),
      total_minutes: total,
      sentence: "Adds 1 trip.",
      hint: nil
    }
  end

  defp error_preview(target, message, drawer) do
    %{
      error: message,
      target: target,
      label: preview_label(drawer),
      meta: nil,
      range: nil,
      total_minutes: nil,
      sentence: nil,
      hint: nil
    }
  end

  defp preview_pattern(socket, drawer) do
    Enum.find(socket.assigns.payload.patterns, &(&1.id == drawer.values["pattern_id"])) ||
      (drawer.trip && drawer_pattern(socket, drawer.trip))
  end

  defp preview_pattern_name(socket, drawer) do
    case preview_pattern(socket, drawer) do
      nil -> "No pattern"
      pattern -> pattern.name
    end
  end

  defp timing_for(nil, _timed_pattern_id), do: nil

  defp timing_for(pattern, timed_pattern_id),
    do: Enum.find(pattern.timings, &(&1.id == timed_pattern_id))

  defp add_label(1), do: "Add 1 trip"
  defp add_label(count), do: "Add #{count} trips"

  defp trip_count_label(1), do: "1 trip"
  defp trip_count_label(count), do: "#{count} trips"

  defp range_label(start_secs, nil), do: "#{clock(start_secs)} → #{clock(start_secs)}"

  defp range_label(start_secs, total_minutes),
    do: "#{clock(start_secs)} → #{clock(start_secs + total_minutes * 60)}"

  defp timing_total_minutes(nil), do: nil

  defp timing_total_minutes(timing) do
    timing
    |> Map.get(:rows, [])
    |> Enum.map(&row_offset/1)
    # A blank row carries no offset; it is skipped rather than counted as midnight.
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
    |> div(60)
  end

  defp row_offset(row),
    do: Map.get(row, :arrival_offset) || Map.get(row, :departure_offset)

  defp row_start_secs(%{values: values}) do
    case parse_clock_value(values["start_time"]) do
      {:ok, secs} -> secs
      _ -> nil
    end
  end

  # --- parsing helpers -------------------------------------------------------

  # The drawer reads the page's one R2 grammar; the context takes HH:MM:SS.
  defp parse_start_clock(value) do
    case parse_clock_value(value) do
      {:ok, secs} -> {:ok, secs, seconds_to_clock(secs)}
      {:error, _reason} -> {:error, :start_time, ScheduleComponents.error_message(:invalid_time)}
    end
  end

  defp parse_until_clock(value) do
    case parse_clock_value(value) do
      {:ok, secs} -> {:ok, secs, seconds_to_clock(secs)}
      {:error, _reason} -> {:error, :until, ScheduleComponents.error_message(:until_before_start)}
    end
  end

  # A drawer has no cell time, so a relative reading has no `current:` and is
  # refused here like every other form outside R2.
  defp parse_clock_value(value) do
    case TimeEntry.parse(value, []) do
      {:ok, %{secs: secs}} -> {:ok, secs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_every(value) do
    if whole_number?(value) and String.to_integer(String.trim(value)) >= 1 do
      {:ok, String.to_integer(String.trim(value))}
    else
      {:error, :every, ScheduleComponents.error_message(:invalid_interval)}
    end
  end

  defp whole_number?(value) when is_binary(value),
    do: Regex.match?(~r/\A\d+\z/, String.trim(value))

  defp whole_number?(_value), do: false

  defp clock(nil), do: nil

  defp clock(secs) do
    secs
    |> GtfsTime.format()
    |> String.split(":")
    |> Enum.take(2)
    |> Enum.join(":")
  end

  defp seconds_to_clock(secs) do
    hours = div(secs, 3_600)
    minutes = div(rem(secs, 3_600), 60)

    pad(hours) <> ":" <> pad(minutes) <> ":00"
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  # --- URL parameters --------------------------------------------------------

  # A filter change carries the loaded view forward and overrides only the field
  # the control posted; canonicalization in the next `handle_params` still falls
  # back to a default for a value that does not exist in the new scope. The
  # Custom times chip posts `custom=1`/`custom=0`, and a control that does not
  # post the field carries the current view's filter forward.
  defp merged_filters(filters, params, custom?) do
    %{}
    |> put_unless_default("service_id", params["service_id"] || filters.service_id, nil)
    |> put_unless_default(
      "direction",
      params["direction"] || direction_param(filters.direction_id),
      "0"
    )
    |> put_unless_default("pattern", params["pattern"] || pattern_param(filters.pattern), "all")
    |> put_unless_default("stops", params["stops"] || stops_param(filters.stops), "timepoints")
    |> put_custom_param(merged_custom(params["custom"], custom?))
  end

  defp merged_custom("1", _current?), do: true
  defp merged_custom("0", _current?), do: false
  defp merged_custom(_absent, current?), do: current?

  defp canonical_filters_for_params(nil, params), do: Map.take(params, @filter_keys)

  defp canonical_filters_for_params(filters, params),
    do: canonical_filters(filters, custom_filter?(params))

  defp canonical_filters(filters, custom?) do
    %{}
    |> put_unless_default("service_id", filters.service_id, nil)
    |> put_unless_default("direction", direction_param(filters.direction_id), "0")
    |> put_unless_default("pattern", pattern_param(filters.pattern), "all")
    |> put_unless_default("stops", stops_param(filters.stops), "timepoints")
    |> put_custom_param(custom?)
  end

  # The canonical URL states the filter only when it is on, so `?custom=0` and
  # any other spelling of "off" is replaced with the plain view's URL.
  defp put_custom_param(query, true), do: Map.put(query, "custom", "1")
  defp put_custom_param(query, false), do: query

  defp custom_filter?(params), do: params["custom"] == "1"

  # A value equal to its default is left out of the URL, unlike Values.put_present/3's test.
  defp put_unless_default(query, _key, nil, _default), do: query
  defp put_unless_default(query, _key, value, value), do: query
  defp put_unless_default(query, key, value, _default), do: Map.put(query, key, value)

  defp direction_param(0), do: "0"
  defp direction_param(1), do: "1"
  defp direction_param(_direction), do: nil

  defp pattern_param(:all), do: "all"
  defp pattern_param(pattern) when is_binary(pattern), do: pattern
  defp pattern_param(_pattern), do: "all"

  defp stops_param(:all), do: "all"
  defp stops_param(_stops), do: "timepoints"

  defp schedule_path(socket, query) do
    schedule_path_for(socket.assigns.current_gtfs_version.id, socket.assigns.route_id, query)
  end

  defp schedule_path_for(version_id, route_id, query) do
    path = ~p"/gtfs/#{version_id}/routes/#{route_id}/schedules"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  # The Schedules action opens the paste page in the current scope: the
  # calendar and direction always travel, the pattern only when one is
  # selected. The paste page canonicalizes anything stale on arrival.
  defp paste_path(version_id, route_id, filters) do
    query =
      %{}
      |> put_unless_default("service_id", filters.service_id, nil)
      |> put_unless_default("direction", direction_param(filters.direction_id), nil)
      |> put_unless_default("pattern", pattern_param(filters.pattern), "all")

    path = ~p"/gtfs/#{version_id}/routes/#{route_id}/schedules/paste"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  defp schedule_blocks_path(version_id, query) do
    "/gtfs/#{version_id}/blocks?" <> URI.encode_query(query)
  end

  # --- presentation helpers --------------------------------------------------

  defp calendar_label(calendars, service_id) do
    case Enum.find(calendars, &(&1.service_id == service_id)) do
      nil -> service_id
      calendar -> calendar.name || calendar.service_id
    end
  end

  defp calendar_name(socket, service_id) do
    calendar_label(
      socket.assigns.payload.calendars,
      service_id || socket.assigns.filters.service_id
    )
  end

  defp direction_label(payload) do
    payload.direction_labels[payload.filters.direction_id]
  end

  defp pattern_name(payload) do
    case Enum.find(payload.patterns, &(&1.id == payload.filters.pattern)) do
      nil -> nil
      pattern -> pattern.name
    end
  end

  defp route_label(route), do: route.route_short_name || route.route_id

  defp can_add?(payload) do
    payload.calendars != [] and Enum.any?(payload.patterns, &(&1.timings != []))
  end

  defp add_reason(payload) do
    cond do
      payload.calendars == [] ->
        "Create a calendar before adding trips."

      payload.patterns == [] ->
        "Create a pattern before adding trips."

      not Enum.any?(payload.patterns, &(&1.timings != [])) ->
        "Add a timing to a pattern before adding trips."

      true ->
        nil
    end
  end

  # The confirmation lists what the delete removes: the first departures of the
  # selection in clock order, and how many more there are. A selected trip with no
  # readable time has no departure to list.
  @listed_departures 6

  defp departures_detail(selected) do
    times =
      selected
      |> Enum.map(& &1.start_secs)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()
      |> Enum.map(&clock/1)

    case {Enum.take(times, @listed_departures), length(times) - @listed_departures} do
      {[], _more} -> nil
      {shown, more} when more > 0 -> "Departures #{Enum.join(shown, ", ")} and #{more} more"
      {shown, _more} -> "Departures #{Enum.join(shown, ", ")}"
    end
  end

  # Adding a timing happens on the pattern that lacks one; with none to name, the
  # patterns list is the way in.
  defp timing_path(patterns, version_id, route_id) do
    base = "/gtfs/#{version_id}/routes/#{route_id}/patterns"

    case Enum.find(patterns, &(&1.timings == [])) do
      nil -> base
      pattern -> base <> "/" <> URI.encode(pattern.route_pattern_id, &URI.char_unreserved?/1)
    end
  end

  # The scope bar keeps the page's one primary for Add trips while nothing else
  # carries one: an empty view's own card when it offers to add the first trip,
  # or the grid bar's selection verbs (the design system's primary hand-off).
  defp add_primary?(can_add?, sections_empty?, filters, selected_count),
    do: selected_count == 0 and not (can_add? and sections_empty? and filters.pattern == :all)

  defp scope_visible?(%{calendars: calendars, patterns: patterns}),
    do: calendars != [] and patterns != []

  # --- render ----------------------------------------------------------------

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
      <div id="route-schedules" phx-hook="FormErrorFocus" class="ds-page">
        <.route_header
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:schedules}
          pattern_count={@payload && length(@payload.patterns)}
          loading={@load_state == :loading}
        />

        <p id="schedules-live-region" role="status" aria-live="polite" class="sr-only">
          <%= if @outcome do %>
            {@outcome.text}
          <% end %>
          <%= if @vehicle_change do %>
            Vehicles needed changed from {@vehicle_change.from} to {@vehicle_change.to}
          <% end %>
        </p>

        <div
          id="route-schedules-helper-focus"
          phx-hook=".RouteSchedulesHelperFocus"
          class={
            [
              # The panel leads at phone width, where it is stacked above the
              # schedule the "Open helper" button belongs to; `lg:grid` drops the
              # flex ordering so source order puts the schedule left again.
              "flex flex-col lg:grid lg:gap-6",
              @agent_open? && "lg:grid-cols-[minmax(0,1fr)_24rem]"
            ]
          }
        >
          <div class="min-w-0">
            <div id="route-schedules-helper-actions" class="flex justify-end">
              <.button
                :if={@route}
                id="agent-helper-open"
                type="button"
                phx-click="agent_open"
                aria-expanded={to_string(@agent_open?)}
                aria-controls="agent-panel"
                variant="quiet"
                class="-mt-2 min-h-11"
              >
                Open helper
              </.button>
            </div>

            <%= cond do %>
              <% @load_state == :loading and is_nil(@payload) -> %>
                <ScheduleComponents.loading_skeleton />
              <% true -> %>
                <ScheduleComponents.scope_bar
                  :if={@payload && scope_visible?(@payload)}
                  calendar_form={@calendar_form}
                  calendars={@payload.calendars}
                  filters={@filters}
                  direction_labels={@payload.direction_labels}
                  calendars_path={"/gtfs/#{@current_gtfs_version.id}/calendars"}
                  paste_path={paste_path(@current_gtfs_version.id, @route_id, @filters)}
                  can_add?={@can_add?}
                  add_reason={@add_reason}
                  add_primary?={
                    add_primary?(@can_add?, @sections_empty?, @filters, @selected_count) and
                      not ScheduleChangeComponents.change_strip?(@change)
                  }
                />

                <ScheduleComponents.connectivity_notice />

                <ScheduleComponents.unavailable_notice
                  :if={@load_state == :unavailable}
                  stale?={@payload != nil}
                />

                <div :if={@payload}>
                  <ScheduleComponents.unlinked_trips
                    :if={@payload.unlinked_trip_count > 0}
                    count={@payload.unlinked_trip_count}
                    patterns_path={~p"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns"}
                  />

                  <ScheduleComponents.block_notice :if={@block_notice} notice={@block_notice} />

                  <%= cond do %>
                    <% @payload.calendars == [] -> %>
                      <ScheduleComponents.no_calendars new_calendar_path={"/gtfs/#{@current_gtfs_version.id}/calendars/new"} />
                    <% @payload.patterns == [] -> %>
                      <ScheduleComponents.no_patterns
                        route={@payload.route}
                        new_pattern_path={
                          ~p"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns/new"
                        }
                      />
                    <% @sections_empty? -> %>
                      <ScheduleComponents.filter_bar
                        :if={@filters.pattern != :all or @custom_filter?}
                        pattern_form={@pattern_form}
                        patterns={@payload.patterns}
                        filters={@filters}
                        row_count={@rows_in_view}
                        custom_count={@custom_count}
                        custom_filter?={@custom_filter?}
                        calendar_label={calendar_label(@payload.calendars, @filters.service_id)}
                        direction_label={direction_label(@payload)}
                      />
                      <ScheduleComponents.custom_empty
                        :if={@custom_filter?}
                        calendar_label={calendar_label(@payload.calendars, @filters.service_id)}
                        direction_label={direction_label(@payload)}
                      />
                      <ScheduleComponents.no_trips
                        :if={not @custom_filter?}
                        route={@payload.route}
                        calendar_label={calendar_label(@payload.calendars, @filters.service_id)}
                        direction_label={direction_label(@payload)}
                        pattern_name={pattern_name(@payload)}
                        any_trips?={@any_trips?}
                        can_add?={@can_add?}
                        timing_path={
                          timing_path(@payload.patterns, @current_gtfs_version.id, @route_id)
                        }
                      />
                    <% true -> %>
                      <ScheduleComponents.planning_summary
                        summary={@payload.summary}
                        route={@payload.route}
                        calendar_label={calendar_label(@payload.calendars, @filters.service_id)}
                        direction_label={direction_label(@payload)}
                        vehicle_change={@vehicle_change}
                      />

                      <ScheduleComponents.filter_bar
                        pattern_form={@pattern_form}
                        patterns={@payload.patterns}
                        filters={@filters}
                        row_count={@rows_in_view}
                        custom_count={@custom_count}
                        custom_filter?={@custom_filter?}
                        calendar_label={calendar_label(@payload.calendars, @filters.service_id)}
                        direction_label={direction_label(@payload)}
                      />

                      <div
                        id="schedules-grid"
                        phx-hook="TimetableGrid"
                        data-grid-revision={@grid_revision}
                      >
                        <div id="schedules-sections" phx-update="stream" class="mt-3 space-y-6">
                          <div :for={{dom_id, section} <- @streams.sections} id={dom_id}>
                            <ScheduleComponents.section
                              section={section}
                              selected_ids={@selected_ids}
                              calendar_label={calendar_label(@payload.calendars, @filters.service_id)}
                              export_defaults_path={"/gtfs/#{@current_gtfs_version.id}/settings/export-defaults"}
                            />
                          </div>
                        </div>
                        <div id="cell-editor" phx-update="ignore"></div>
                      </div>

                      <% strip = change_strip_view(assigns) %>
                      <ScheduleChangeComponents.grid_bar
                        selected_count={@selected_count}
                        outcome={@outcome}
                        undo_stack={@undo_stack}
                        change={@change}
                        strip={strip}
                        version_name={@current_gtfs_version.name}
                      />
                  <% end %>

                  <ScheduleComponents.trip_drawer
                    drawer={@drawer}
                    patterns={@payload.patterns}
                    calendars={@payload.calendars}
                    blocks_path={"/gtfs/#{@current_gtfs_version.id}/blocks"}
                    patterns_path={~p"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns"}
                    version_name={@current_gtfs_version.name}
                    sections={@sections_list}
                  />

                  <% change_drawer = change_drawer_view(assigns) %>
                  <ScheduleChangeComponents.change_review_drawer
                    :if={change_drawer}
                    change={@change}
                    drawer={change_drawer}
                    version_name={@current_gtfs_version.name}
                  />

                  <% change_paste = change_paste_view(assigns) %>
                  <ScheduleChangeComponents.paste_dialog
                    :if={change_paste}
                    change={@change}
                    paste={change_paste}
                    version_name={@current_gtfs_version.name}
                  />

                  <% convert_dialog = convert_dialog_view(assigns) %>
                  <ScheduleChangeComponents.convert_dialog
                    :if={convert_dialog}
                    change={@change}
                    convert={convert_dialog}
                  />

                  <ScheduleComponents.delete_dialog
                    dialog={@delete_dialog}
                    version_name={@current_gtfs_version.name}
                  />

                  <ScheduleChangeComponents.shortcut_sheet
                    open={@shortcuts_open?}
                    return_focus_id={@shortcuts_return_focus_id}
                  />
                </div>
            <% end %>
          </div>

          <div
            :if={@agent_open?}
            class="order-first mb-5 min-w-0 lg:order-last lg:mb-0 lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)]"
          >
            <.agent_panel
              id="agent-panel"
              title={@agent_title}
              intro={@agent_intro}
              examples={@agent_examples}
              scope_line={helper_scope_line(assigns)}
              status={@agent_status}
              entries={@streams.agent_entries}
              form={@agent_form}
              notice={@agent_notice}
              entries_empty?={@agent_entries_empty?}
              composer_hint="Answers only. Nothing on this page changes."
            />
          </div>
        </div>

        <%!--
        The panel's focus listener belongs to the wrapper above, which survives both the panel and
        the schedule's own drawers. This hook only moves focus; it never decides focus for the
        server. --%>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".RouteSchedulesHelperFocus">
          export default {
            mounted() {
              this.handleEvent("agent:focus", ({id}) => document.getElementById(id)?.focus())
            }
          }
        </script>
      </div>
    </Layouts.app>
    """
  end

  # The panel names the route it is bound to, from the loaded route rather than
  # from the URL, so the line always agrees with the schedule below it.
  defp helper_scope_line(%{route: nil}), do: "Route · no route loaded"

  defp helper_scope_line(%{route: route} = assigns),
    do: "Route #{route.route_id} · #{assigns.current_gtfs_version.name}"
end
