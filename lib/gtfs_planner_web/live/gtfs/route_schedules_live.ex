defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesLive do
  @moduledoc """
  LiveView for one route's Schedules view: the timetable read plus the trip
  drawers, row actions, bulk toolbar and delete confirmations.

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
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Schedules.Summary
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.EnsureRole
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @filter_keys ~w(service_id direction pattern stops)
  @drawer_fields ~w(pattern_id timed_pattern_id service_id start_time repeat every until
    trip_headsign trip_short_name wheelchair_accessible bikes_allowed)
  @duplicate_offset_secs 1_800
  @default_departure "06:00"
  @default_every "30"
  @default_until "09:00"

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
     |> assign(:can_add?, false)
     |> assign(:add_reason, nil)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:selected_count, 0)
     |> assign(:vehicle_change, nil)
     |> assign(:vehicle_change_from, nil)
     |> assign(:keep_vehicle_change, false)
     |> assign(:drawer, nil)
     |> assign(:block_notice, nil)
     |> assign(:delete_dialog, nil)
     |> assign(:calendar_form, to_form(%{"service_id" => nil}))
     |> assign(:pattern_form, to_form(%{"pattern" => "all"}))
     |> stream_configure(:sections, dom_id: &"section-#{&1.pattern.route_pattern_id}")
     |> stream(:sections, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:route_id, params["route_id"])
      |> assign(:requested, params)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:selected_count, 0)
      |> assign(:delete_dialog, nil)
      |> assign(:block_notice, nil)
      |> clear_vehicle_change()

    if connected?(socket) do
      {:noreply, load_schedule(socket, params)}
    else
      {:noreply, assign(socket, :load_state, :loading)}
    end
  end

  @impl true
  def handle_event("filters", params, socket) do
    case socket.assigns.filters do
      nil ->
        {:noreply, socket}

      filters ->
        {:noreply, push_patch(socket, to: schedule_path(socket, merged_filters(filters, params)))}
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
  def handle_event("clear_selection", _params, socket) do
    socket =
      socket
      |> assign(:selected_ids, MapSet.new())
      |> assign(:selected_count, 0)

    {:noreply,
     Enum.reduce(socket.assigns.sections_list, socket, &stream_insert(&2, :sections, &1))}
  end

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
              "until" => @default_until
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
        detail: nil,
        frequency?: Enum.any?(selected, & &1.frequency?),
        service_id: service_id,
        return_focus_id: "schedules-delete-selected",
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

  defp submit_or_refuse(socket, drawer) do
    if editor_access?(socket) do
      submit_drawer(socket, drawer)
    else
      {:noreply, unauthorized(socket, drawer)}
    end
  end

  defp delete_or_refuse(socket) do
    dialog = socket.assigns.delete_dialog

    cond do
      dialog == nil ->
        socket

      not editor_access?(socket) ->
        dialog_problem(socket, dialog, :unauthorized)

      true ->
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
    sections = display_sections(payload)

    socket
    |> assign(:route, payload.route)
    |> assign(:payload, payload)
    |> assign(:filters, payload.filters)
    |> assign(:load_state, :ready)
    |> assign(:sections_list, sections)
    |> assign(:sections_empty?, sections == [])
    |> assign(:rows_in_view, Enum.sum(Enum.map(sections, &length(&1.rows))))
    |> assign(:can_add?, can_add?(payload))
    |> assign(:add_reason, add_reason(payload))
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
  defp display_sections(payload) do
    timing_rows = timing_rows_by_id(payload.patterns)
    columns_key = if payload.filters.stops == :all, do: :all_columns, else: :columns

    Enum.map(payload.sections, fn section ->
      columns = Map.fetch!(section, columns_key)

      Map.merge(section, %{
        stops: payload.filters.stops,
        columns: columns,
        timing_lines: timing_lines_for(section.timing_lines, columns, timing_rows)
      })
    end)
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
    canonical = canonical_filters(filters)

    if Map.take(params, @filter_keys) == canonical do
      socket
    else
      push_patch(socket, to: schedule_path(socket, canonical), replace: true)
    end
  end

  defp reselect(socket, section, selected) do
    socket
    |> assign(:selected_ids, selected)
    |> assign(:selected_count, MapSet.size(selected))
    |> stream_insert(:sections, section)
  end

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

  defp apply_drawer(socket, %{mode: :edit} = drawer) do
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

  defp unauthorized(socket, drawer) do
    socket
    |> put_flash(:error, ScheduleComponents.error_message(:unauthorized))
    |> assign(:drawer, %{drawer | problem: :unauthorized, errors: %{}})
  end

  defp drawer_problem(socket, drawer, reason) do
    assign(socket, :drawer, %{drawer | problem: reason, errors: %{}})
  end

  defp dialog_problem(socket, dialog, reason) do
    assign(socket, :delete_dialog, %{dialog | error: ScheduleComponents.error_message(reason)})
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
    |> put_param("service_id", trip.service_id, nil)
    |> put_param("direction", direction_param(trip.direction_id), "0")
    |> put_param("pattern", pattern_id, "all")
    |> put_param("stops", stops_param(filters.stops), "timepoints")
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

  defp merge_drawer_values(socket, params) do
    case socket.assigns.drawer do
      nil -> nil
      drawer -> %{drawer | values: Map.merge(drawer.values, clean_values(params)), errors: %{}}
    end
  end

  defp clean_values(params), do: Map.take(params, @drawer_fields)

  defp edit_values(socket, row) do
    %{
      "pattern_id" => row_pattern_uuid(socket, row),
      "timed_pattern_id" => row.timed_pattern_id || "custom",
      "service_id" => row.service_id,
      "start_time" => clock(row.start_secs) || "",
      "trip_headsign" => row.trip_headsign || "",
      "trip_short_name" => row.trip_short_name || "",
      "wheelchair_accessible" => integer_string(row.wheelchair_accessible),
      "bikes_allowed" => integer_string(row.bikes_allowed)
    }
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

  defp drawer_preview(socket, %{mode: :edit} = drawer) do
    values = drawer.values
    timing = timing_for(preview_pattern(socket, drawer), values["timed_pattern_id"])
    total = timing_total_minutes(timing)

    meta =
      "#{preview_pattern_name(socket, drawer)} · #{calendar_name(socket, values["service_id"])}"

    cond do
      drawer.frequency? ->
        %{
          error: nil,
          target: nil,
          label: "Save trip",
          meta: nil,
          range: drawer.frequency_label,
          total_minutes: nil,
          sentence: "Frequency window stays unchanged.",
          hint: nil
        }

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
      label: if(drawer.mode == :add, do: "Add 1 trip", else: drawer_label(drawer.mode)),
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
    |> Enum.map(fn row ->
      Map.get(row, :arrival_offset) || Map.get(row, :departure_offset) || 0
    end)
    |> Enum.max(fn -> 0 end)
    |> div(60)
  end

  defp row_start_secs(%{values: values}) do
    case parse_clock_value(values["start_time"]) do
      {:ok, secs} -> secs
      _ -> nil
    end
  end

  # --- parsing helpers -------------------------------------------------------

  # The drawer takes HH:MM (or H:MM); the context takes HH:MM:SS.
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

  defp parse_clock_value(value) when is_binary(value) do
    value = String.trim(value)
    normalized = if Regex.match?(~r/\A\d{1,3}:[0-5]\d\z/, value), do: value <> ":00", else: value

    case GtfsTime.parse(normalized) do
      {:ok, secs} -> {:ok, secs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_clock_value(_value), do: {:error, :invalid_time}

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
  # back to a default for a value that does not exist in the new scope.
  defp merged_filters(filters, params) do
    %{}
    |> put_param("service_id", params["service_id"] || filters.service_id, nil)
    |> put_param("direction", params["direction"] || direction_param(filters.direction_id), "0")
    |> put_param("pattern", params["pattern"] || pattern_param(filters.pattern), "all")
    |> put_param("stops", params["stops"] || stops_param(filters.stops), "timepoints")
  end

  defp canonical_filters_for_params(nil, params), do: Map.take(params, @filter_keys)

  defp canonical_filters_for_params(filters, _params), do: canonical_filters(filters)

  defp canonical_filters(filters) do
    %{}
    |> put_param("service_id", filters.service_id, nil)
    |> put_param("direction", direction_param(filters.direction_id), "0")
    |> put_param("pattern", pattern_param(filters.pattern), "all")
    |> put_param("stops", stops_param(filters.stops), "timepoints")
  end

  defp put_param(query, _key, nil, _default), do: query
  defp put_param(query, _key, value, value), do: query
  defp put_param(query, key, value, _default), do: Map.put(query, key, value)

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
    path = "/gtfs/#{version_id}/routes/#{route_id}/schedules"

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
      payload.calendars == [] -> "Add a calendar before adding trips."
      payload.patterns == [] -> "Add a pattern before adding trips."
      not Enum.any?(payload.patterns, &(&1.timings != [])) -> "Add a timing before adding trips."
      true -> nil
    end
  end

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
      <:sub_header :if={@route}>
        <.route_sub_nav
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:schedules}
        />
      </:sub_header>

      <div id="route-schedules" phx-hook="FormErrorFocus" class="mt-8 space-y-6">
        <p id="schedules-live-region" role="status" aria-live="polite" class="text-sm">
          <%= if @vehicle_change do %>
            changed from {@vehicle_change.from} to {@vehicle_change.to}
          <% end %>
        </p>

        <%= cond do %>
          <% @load_state == :loading and is_nil(@payload) -> %>
            <.skeleton id="schedules-loading" label="Loading schedules">
              <div class="space-y-3">
                <div :for={_row <- 1..4} class="flex items-center gap-4">
                  <div class="size-4 shrink-0 bg-base-300"></div>
                  <div class="h-4 w-16 shrink-0 bg-base-300"></div>
                  <div class="h-4 flex-1 bg-base-300"></div>
                  <div class="h-4 flex-1 bg-base-300"></div>
                  <div class="h-4 flex-1 bg-base-300"></div>
                  <div class="h-4 w-24 shrink-0 bg-base-300"></div>
                  <div class="h-4 w-16 shrink-0 bg-base-300"></div>
                  <div class="h-4 w-12 shrink-0 bg-base-300"></div>
                </div>
              </div>
            </.skeleton>
          <% true -> %>
            <ScheduleComponents.connectivity_notice />

            <div :if={@load_state == :unavailable} id="schedules-unavailable">
              <.callout kind="error" title="Schedules couldn't be loaded">
                Your trips haven't changed. Try loading them again.
                <button
                  id="schedules-retry"
                  type="button"
                  phx-click="retry"
                  class="btn btn-sm btn-outline mt-2 min-h-11"
                >
                  Retry
                </button>
              </.callout>
            </div>

            <div :if={@payload} class="space-y-6">
              <ScheduleComponents.controls
                calendar_form={@calendar_form}
                pattern_form={@pattern_form}
                calendars={@payload.calendars}
                patterns={@payload.patterns}
                filters={@filters}
                direction_labels={@payload.direction_labels}
                calendars_path={"/gtfs/#{@current_gtfs_version.id}/calendars"}
                can_add?={@can_add?}
                add_reason={@add_reason}
              />

              <ScheduleComponents.unlinked_trips
                :if={@payload.unlinked_trip_count > 0}
                count={@payload.unlinked_trip_count}
                patterns_path={"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns"}
              />

              <ScheduleComponents.sections_meta
                :if={@payload.calendars != []}
                row_count={@rows_in_view}
                calendar_label={calendar_label(@payload.calendars, @filters.service_id)}
                direction_label={direction_label(@payload)}
                stops={@filters.stops}
              />

              <ScheduleComponents.block_notice :if={@block_notice} notice={@block_notice} />

              <%= cond do %>
                <% @payload.calendars == [] -> %>
                  <ScheduleComponents.no_calendars calendars_path={"/gtfs/#{@current_gtfs_version.id}/calendars"} />
                <% @payload.patterns == [] -> %>
                  <ScheduleComponents.no_patterns patterns_path={"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns"} />
                <% @sections_empty? -> %>
                  <ScheduleComponents.no_trips
                    calendar_label={calendar_label(@payload.calendars, @filters.service_id)}
                    direction_label={direction_label(@payload)}
                    pattern_name={pattern_name(@payload)}
                  />
                <% true -> %>
                  <ScheduleComponents.planning_summary
                    summary={@payload.summary}
                    route={@payload.route}
                    calendar_label={calendar_label(@payload.calendars, @filters.service_id)}
                    direction_label={direction_label(@payload)}
                    vehicle_change={@vehicle_change}
                  />

                  <ScheduleComponents.bulk_toolbar selected_count={@selected_count} />

                  <div id="schedules-sections" phx-update="stream" class="space-y-8">
                    <div :for={{dom_id, section} <- @streams.sections} id={dom_id}>
                      <ScheduleComponents.section
                        section={section}
                        selected_ids={@selected_ids}
                      />
                    </div>
                  </div>
              <% end %>

              <ScheduleComponents.trip_drawer
                drawer={@drawer}
                patterns={@payload.patterns}
                calendars={@payload.calendars}
                blocks_path={"/gtfs/#{@current_gtfs_version.id}/blocks"}
                patterns_path={"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns"}
              />

              <ScheduleComponents.delete_dialog dialog={@delete_dialog} />
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
