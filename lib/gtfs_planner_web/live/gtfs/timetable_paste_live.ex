defmodule GtfsPlannerWeb.Gtfs.TimetablePasteLive do
  @moduledoc """
  Paste timetable page shell: the header, the schedule line and the setup
  empty states.

  Step 21 of the timetable paste import owns the shell only. `handle_params`
  resolves the paste scope through `Gtfs.prepare_timetable_paste/5` with an
  empty input (scope only, `review: nil`) and canonicalizes the
  `service_id`/`direction`/`pattern` URL parameters with a replace patch, like
  `RouteSchedulesLive` canonicalizes its filters. A foreign scope navigates
  back to Routes with a not-found flash, also like `RouteSchedulesLive`.

  The Change schedule drawer (step 22), the timetable step (step 23) and the
  review UI (steps 25-28) build on this shell: the `open_scope_drawer` event is
  inert until step 22 wires the drawer. The version-switch events mirror
  `RouteSchedulesLive`; the unsaved-work confirmation arrives in step 30.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1, route_label: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.TimetablePasteComponents

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
    switch_version(socket, version_id)
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    switch_version(socket, version_id)
  end

  # Inert until step 22 builds the Change schedule drawer. The button is part
  # of the shell contract now, so later steps only add the drawer and this
  # handler's body.
  @impl true
  def handle_event("open_scope_drawer", _params, socket) do
    {:noreply, socket}
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
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_scope(socket, params) do
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
      {:ok, %{scope: scope, review: nil}} -> apply_scope(socket, scope, params)
      {:ok, %{scope: scope}} -> apply_scope(socket, scope, params)
      {:error, :not_found} -> route_not_found(socket)
    end
  end

  defp scope_params(params) do
    %{
      service_id: params["service_id"],
      direction: params["direction"],
      pattern: params["pattern"]
    }
  end

  defp apply_scope(socket, scope, params) do
    socket
    |> assign(:route, scope.route)
    |> assign(:scope, scope)
    |> assign(:load_state, :ready)
    |> push_canonical(scope, params)
  end

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
    |> put_param("service_id", scope.calendar && scope.calendar.service_id)
    |> put_param("direction", direction_param(scope.direction_id))
    |> put_param("pattern", scope.pattern_id)
  end

  defp put_param(query, _key, nil), do: query
  defp put_param(query, key, value), do: Map.put(query, key, value)

  defp direction_param(0), do: "0"
  defp direction_param(1), do: "1"
  defp direction_param(_direction), do: nil

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
    path = "/gtfs/#{version_id}/routes/#{route_id}/schedules/paste"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
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
