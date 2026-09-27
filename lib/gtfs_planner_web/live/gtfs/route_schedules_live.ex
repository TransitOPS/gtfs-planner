defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesLive do
  @moduledoc """
  LiveView for one route's Schedules read view.

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

  This view reads only. The Add trips, Edit, Duplicate and Delete controls appear
  once the write path is wired; until then the page renders selection checkboxes
  and no control that could promise a mutation.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Schedules.Summary
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @filter_keys ~w(service_id direction pattern stops)

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
     |> assign(:sections_empty?, true)
     |> assign(:rows_in_view, 0)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:selected_count, 0)
     |> assign(:vehicle_change, nil)
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
      |> assign(:vehicle_change, nil)

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
    case Enum.find(socket.assigns.section_index, fn {_dom_id, section} ->
           Enum.any?(section.rows, &(&1.id == trip_id))
         end) do
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
    sections = display_sections(payload)

    socket =
      socket
      |> assign(:route, payload.route)
      |> assign(:payload, payload)
      |> assign(:filters, payload.filters)
      |> assign(:load_state, :ready)
      |> assign(:sections_empty?, sections == [])
      |> assign(:rows_in_view, Enum.sum(Enum.map(sections, &length(&1.rows))))
      |> assign(
        :section_index,
        Map.new(sections, &{"section-#{&1.pattern.route_pattern_id}", &1})
      )
      |> assign(:calendar_form, to_form(%{"service_id" => payload.filters.service_id}))
      |> assign(:pattern_form, to_form(%{"pattern" => pattern_param(payload.filters.pattern)}))
      |> stream(:sections, sections, reset: true)

    push_canonical(socket, payload.filters, params)
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

  # --- presentation helpers --------------------------------------------------

  defp calendar_label(calendars, service_id) do
    case Enum.find(calendars, &(&1.service_id == service_id)) do
      nil -> service_id
      calendar -> calendar.name || calendar.service_id
    end
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

      <div id="route-schedules" class="mt-8 space-y-6">
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

                  <div id="schedules-sections" phx-update="stream" class="space-y-8">
                    <div :for={{dom_id, section} <- @streams.sections} id={dom_id}>
                      <ScheduleComponents.section section={section} selected_ids={@selected_ids} />
                    </div>
                  </div>
              <% end %>
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
