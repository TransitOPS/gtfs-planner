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
     |> assign(:last_run, nil)
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

        if connected?(socket) and active_run do
          Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(active_run.id))
        end

        active_run = Reachability.get_active_run(organization_id, gtfs_version_id, stop_id)
        last_run = latest_finished_run(organization_id, gtfs_version_id, stop_id)

        {:noreply,
         socket
         |> assign(:station, station)
         |> assign(:stop_id, stop_id)
         |> assign(:topology, topology)
         |> assign(:active_run, active_run)
         |> assign(:last_run, last_run)
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
        log_run_error(reason)
        {:noreply, assign(socket, :run_error, run_error_message(reason))}
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
      gtfs_version_id = socket.assigns.current_gtfs_version.id
      stop_id = socket.assigns.stop_id

      {:noreply,
       socket
       |> assign(:active_run, nil)
       |> assign(:running?, false)
       |> assign(:last_run, run)
       |> push_navigate(
         to: ~p"/gtfs/#{gtfs_version_id}/station-reachability/#{run.id}?stop_id=#{stop_id}"
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reachability_run_failed, run_id, reason}, socket) do
    if socket.assigns[:active_run] && socket.assigns.active_run.id == run_id do
      log_run_error(reason)

      {:noreply,
       socket
       |> assign(:active_run, nil)
       |> assign(:running?, false)
       |> assign(:run_error, run_error_message(reason))}
    else
      {:noreply, socket}
    end
  end

  defp run_error_message(:station_not_found), do: "The station could not be found."
  defp run_error_message(:run_in_progress), do: "A run is already in progress for this station."

  defp run_error_message(:battery_too_large),
    do: "This station has too many pairs to test automatically."

  defp run_error_message(_reason),
    do: "The reachability run could not be completed. Please try again."

  defp log_run_error(reason) do
    require Logger
    Logger.error("Station reachability run failed: #{inspect(reason)}")
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
                <span class="loading loading-spinner loading-sm"></span> Running...
              <% else %>
                Run reachability tests
              <% end %>
            </button>
            <span :if={@topology} class="text-sm text-base-content/70 tabular-nums">
              {@topology.pair_count} pairs will be tested
            </span>
          </div>

          <%= if @run_error do %>
            <.callout kind="error" title="Reachability run could not start" role="alert">
              {@run_error}
            </.callout>
          <% end %>
        <% else %>
          <.empty_battery />
        <% end %>

        <.last_run run={@last_run} gtfs_version={@current_gtfs_version} stop_id={@stop_id} />
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
    <div class="bg-base-100 border border-base-300 rounded-box p-3 text-center">
      <div class="text-2xl font-bold tabular-nums">{@value}</div>
      <div class="text-xs text-base-content/70">{@label}</div>
    </div>
    """
  end

  defp empty_battery(assigns) do
    ~H"""
    <.empty_state id="reachability-empty-battery" title="No testable pairs" class="bg-base-100">
      This station needs at least one entrance and one platform connected by pathways
      to run reachability tests. Add entrances, platforms, and pathways in Floorplans.
    </.empty_state>
    """
  end

  attr :run, :map, default: nil
  attr :gtfs_version, :map, required: true
  attr :stop_id, :string, required: true

  # Runs are ephemeral: each one supersedes the last, so only the latest result
  # is worth an affordance. The full run list stays out of the UI.
  defp last_run(assigns) do
    ~H"""
    <div
      :if={@run}
      id="last-reachability-run"
      class="flex flex-wrap items-center gap-x-4 gap-y-2 bg-base-100 border border-base-300 rounded-box px-4 py-3"
    >
      <span class="text-sm font-medium">Last run</span>
      <.status_badge status={@run.status} />
      <span class="text-sm text-base-content/70 tabular-nums">
        {Calendar.strftime(@run.inserted_at, "%b %d, %Y at %H:%M")}
      </span>
      <.link
        navigate={~p"/gtfs/#{@gtfs_version.id}/station-reachability/#{@run.id}?stop_id=#{@stop_id}"}
        class="ml-auto inline-flex min-h-11 items-center text-sm font-medium text-primary hover:underline"
      >
        View results
      </.link>
    </div>
    """
  end

  # An in-progress run is already represented by the run button's busy state.
  defp latest_finished_run(organization_id, gtfs_version_id, stop_id) do
    organization_id
    |> Reachability.list_recent_runs(gtfs_version_id, stop_id, 5)
    |> Enum.find(&(&1.status in ["completed", "failed"]))
  end
end
