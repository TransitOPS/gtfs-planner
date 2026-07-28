defmodule GtfsPlannerWeb.Gtfs.StationReachabilityLive do
  @moduledoc """
  LiveView for station-level reachability validation.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Station Reachability")
     |> assign(:station, nil)
     |> assign(:stop_id, nil)
     |> assign(:topology, nil)
     |> assign(:active_run, nil)
     |> assign(:recent_runs, [])
     |> assign(:running?, false)
     |> assign(:run_error, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"stop_id" => stop_id}, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Station not found")
         |> push_navigate(to: ~p"/gtfs/#{gtfs_version_id}/stops")}

      station ->
        topology =
          case Reachability.topology_summary(organization_id, gtfs_version_id, stop_id) do
            {:ok, summary} -> summary
            {:error, _} -> nil
          end

        active_run = Reachability.get_active_run(organization_id, gtfs_version_id, stop_id)
        recent_runs = Reachability.list_recent_runs(organization_id, gtfs_version_id, stop_id, 5)

        if connected?(socket) and active_run do
          Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(active_run.id))
        end

        {:noreply,
         socket
         |> assign(:station, station)
         |> assign(:stop_id, stop_id)
         |> assign(:topology, topology)
         |> assign(:active_run, active_run)
         |> assign(:recent_runs, recent_runs)
         |> assign(:running?, active_run != nil)
         |> assign(:run_error, nil)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("run_reachability", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    stop_id = socket.assigns.stop_id

    case Reachability.start_run(organization_id, gtfs_version_id, stop_id) do
      {:ok, run} ->
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run.id))

        {:noreply,
         socket
         |> assign(:active_run, run)
         |> assign(:running?, true)
         |> assign(:run_error, nil)}

      {:error, :run_in_progress} ->
        {:noreply, put_flash(socket, :info, "A run is already in progress for this station.")}

      {:error, :battery_too_large} ->
        {:noreply,
         assign(
           socket,
           :run_error,
           "This station has too many entrance/platform combinations for automated testing. Please contact support."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :run_error, "Failed to start run: #{inspect(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      stop_id = socket.assigns.stop_id
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/stops/#{stop_id}/reachability")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:reachability_run_completed, run_id}, socket) do
    if socket.assigns[:active_run] && socket.assigns.active_run.id == run_id do
      run = Reachability.get_run(run_id)
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id
      stop_id = socket.assigns.stop_id

      recent_runs = Reachability.list_recent_runs(organization_id, gtfs_version_id, stop_id, 5)

      {:noreply,
       socket
       |> assign(:active_run, nil)
       |> assign(:running?, false)
       |> assign(:recent_runs, recent_runs)
       |> push_navigate(
         to: ~p"/gtfs/#{gtfs_version_id}/station-reachability/#{run.id}?stop_id=#{stop_id}"
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reachability_run_failed, run_id, reason}, socket) do
    if socket.assigns[:active_run] && socket.assigns.active_run.id == run_id do
      {:noreply,
       socket
       |> assign(:active_run, nil)
       |> assign(:running?, false)
       |> assign(:run_error, "Run failed: #{inspect(reason)}")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
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
      <:sub_header>
        <.station_sub_nav
          station={@station}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:reachability}
        />
      </:sub_header>

      <section id="station-reachability" class="space-y-6">
        <.header>
          Reachability
          <:subtitle>
            In-station structural reachability between entrances and platforms.
          </:subtitle>
        </.header>

        <%= if @topology && @topology.pair_count > 0 do %>
          <.topology_summary topology={@topology} />

          <div class="flex items-center gap-4">
            <button
              id="run-reachability-btn"
              class="btn btn-primary"
              phx-click="run_reachability"
              disabled={@running?}
            >
              <%= if @running? do %>
                <span class="loading loading-spinner loading-sm"></span>
                Running...
              <% else %>
                Run reachability tests
              <% end %>
            </button>
            <span :if={@topology} class="text-sm text-base-content/60">
              {@topology.pair_count} pairs will be tested
            </span>
          </div>

          <%= if @run_error do %>
            <div class="alert alert-error">
              <.icon name="hero-exclamation-circle" class="h-5 w-5" />
              <span>{@run_error}</span>
            </div>
          <% end %>
        <% else %>
          <.empty_battery />
        <% end %>

        <.recent_runs runs={@recent_runs} gtfs_version={@current_gtfs_version} stop_id={@stop_id} />
      </section>
    </Layouts.app>
    """
  end

  attr :topology, :map, required: true

  defp topology_summary(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-4 sm:grid-cols-5">
      <.stat_card label="Entrances" value={@topology.entrance_count} />
      <.stat_card label="Platforms" value={@topology.platform_count} />
      <.stat_card label="Pathways" value={@topology.pathway_count} />
      <.stat_card label="Levels" value={@topology.level_count} />
      <.stat_card label="Test Pairs" value={@topology.pair_count} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 p-3 text-center">
      <div class="text-2xl font-bold">{@value}</div>
      <div class="text-xs text-base-content/60">{@label}</div>
    </div>
    """
  end

  defp empty_battery(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 p-8 text-center">
      <.icon name="hero-map" class="mx-auto h-12 w-12 text-base-content/30" />
      <h3 class="mt-4 text-lg font-medium">No testable pairs</h3>
      <p class="mt-2 text-sm text-base-content/60">
        This station needs at least one entrance and one platform connected by pathways
        to run reachability tests. Add entrances, platforms, and pathways in the station
        diagram editor.
      </p>
    </div>
    """
  end

  attr :runs, :list, required: true
  attr :gtfs_version, :map, required: true
  attr :stop_id, :string, required: true

  defp recent_runs(assigns) do
    ~H"""
    <div :if={@runs != []}>
      <h3 class="text-sm font-semibold text-base-content/70">Recent Runs</h3>
      <div class="mt-2 overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Status</th>
              <th>Engine</th>
              <th>Errors</th>
              <th>Warnings</th>
              <th>Duration</th>
              <th>Date</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs}>
              <td>
                <.status_badge status={run.status} label={run.status} />
              </td>
              <td>{run.engine || "legacy"}</td>
              <td>{run.errors_count}</td>
              <td>{run.warnings_count}</td>
              <td>{run.duration_ms && "#{div(run.duration_ms, 1000)}s"}</td>
              <td>{Calendar.strftime(run.inserted_at, "%b %d, %H:%M")}</td>
              <td>
                <.link
                  navigate={~p"/gtfs/#{@gtfs_version.id}/station-reachability/#{run.id}?stop_id=#{@stop_id}"}
                  class="btn btn-ghost btn-xs"
                >
                  View
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
