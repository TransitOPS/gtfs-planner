defmodule GtfsPlannerWeb.Gtfs.StationReachabilityLive do
  @moduledoc """
  LiveView for station-level reachability validation.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts
  alias GtfsPlannerWeb.StationWorkspace

  import GtfsPlannerWeb.Gtfs.StationReachabilityComponents
  import GtfsPlannerWeb.ResultComponents, only: [tone_badge: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

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
        {:noreply, put_flash(socket, :info, "A check is already running for this station.")}

      {:error, :battery_too_large} ->
        {:noreply, assign(socket, :run_error, run_error_message(:battery_too_large))}

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
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/stops/#{stop_id}/reachability")}
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

  defp run_error_message(:station_not_found) do
    %{
      title: "This station couldn't be found.",
      body: "Open it again from Stops & stations, then run the check."
    }
  end

  defp run_error_message(:run_in_progress) do
    %{title: "A check is already running for this station.", body: "Wait for it to finish."}
  end

  defp run_error_message(:battery_too_large) do
    %{
      title: "This station is too large to check in one run.",
      body: "It has too many walks to test automatically. Contact support."
    }
  end

  defp run_error_message(_reason) do
    %{
      title: "The check couldn't finish.",
      body:
        "Something went wrong while testing this station, so there's no new result. Run the check again. If it fails again, contact support."
    }
  end

  defp log_run_error(reason) do
    require Logger
    Logger.error("Station reachability run failed: #{inspect(reason)}")
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    battery? = assigns.topology != nil and assigns.topology.pair_count > 0

    assigns =
      assigns
      |> assign(:battery?, battery?)
      # Each walk is planned twice, on foot and step-free, so the battery
      # holds two entries per walk.
      |> assign(:walks, if(battery?, do: div(assigns.topology.pair_count, 2)))

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
        <StationWorkspace.station_header
          title={@station.stop_name || @station.stop_id}
          stop_id={@station.stop_id}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:reachability}
        >
          <:meta>Station</:meta>
        </StationWorkspace.station_header>
      </:sub_header>

      <div id="station-reachability" class="ds-page pb-16 pt-6">
        <div :if={@run_error} class="mb-6">
          <.message id="run-error" kind="error" title={@run_error.title}>
            {@run_error.body}
          </.message>
        </div>

        <section
          aria-labelledby="station-reachability-title"
          class="flex flex-wrap items-start justify-between gap-x-10 gap-y-5 pb-8"
        >
          <div class="max-w-[64ch]">
            <h2
              id="station-reachability-title"
              class="font-display text-[30px] font-semibold leading-[1.1] tracking-[-0.025em] text-strong sm:text-[36px]"
            >
              Can riders get around this station?
            </h2>
            <p class="mt-3 text-base text-muted">
              This check tests every walk between the street and the platforms, and from platform
              to platform, using the pathways in your data. It tests each walk on foot and step-free.
            </p>
          </div>

          <div :if={@battery?} class="flex flex-col gap-2 max-sm:w-full sm:items-end">
            <.button
              id="run-reachability-btn"
              phx-click="run_reachability"
              disabled={@running?}
              data-unavailable={@running?}
              class="min-h-11 max-sm:w-full"
            >
              <%= if @running? do %>
                <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" /> Checking…
              <% else %>
                <.icon name="hero-play" class="size-4" /> Run check
              <% end %>
            </.button>
            <p id="run-reachability-hint" class="text-[13px] text-muted tabular-nums">
              <%= if @running? do %>
                Results open here when the check finishes.
              <% else %>
                Tests {@walks} {if @walks == 1, do: "walk", else: "walks"}, each on foot and step-free
              <% end %>
            </p>
          </div>
        </section>

        <div class="grid items-start gap-8 lg:grid-cols-[minmax(0,1fr)_380px]">
          <div class="grid min-w-0 gap-6">
            <.progress_card
              :if={@running?}
              title={
                if @walks,
                  do: "Checking #{count_label(@walks, "walk", "walks")}",
                  else: "Checking this station"
              }
            >
              Testing each walk on foot and step-free. The results open here when the check
              finishes. You can leave this page; the check keeps running.
            </.progress_card>

            <.last_run run={@last_run} gtfs_version={@current_gtfs_version} stop_id={@stop_id} />

            <.never_run :if={@battery? and is_nil(@last_run) and not @running?} />

            <.empty_battery
              :if={not @battery?}
              gtfs_version={@current_gtfs_version}
              stop_id={@stop_id}
            />

            <.coverage
              :if={@battery?}
              topology={@topology}
              version={@current_gtfs_version}
            />
          </div>

          <.reachable_aside
            battery?={@battery?}
            gtfs_version={@current_gtfs_version}
            stop_id={@stop_id}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp never_run(assigns) do
    ~H"""
    <section
      id="last-reachability-run-none"
      aria-labelledby="last-reachability-run-none-title"
      class="rounded-card border border-subtle bg-white p-5 sm:p-6"
    >
      <h3 id="last-reachability-run-none-title" class="text-[13px] font-bold text-muted">
        Latest result
      </h3>
      <p class="mt-2 font-display text-[24px] font-semibold leading-tight tracking-[-0.02em] text-strong">
        This station hasn't been checked yet.
      </p>
      <p class="mt-2 max-w-[60ch] text-sm text-muted">
        Select <strong class="font-semibold text-strong">Run check</strong>
        to find out whether riders can reach every platform, and whether riders who can't use
        stairs can too.
      </p>
    </section>
    """
  end

  attr :gtfs_version, :map, required: true
  attr :stop_id, :string, required: true

  defp empty_battery(assigns) do
    ~H"""
    <section
      id="reachability-empty-battery"
      aria-labelledby="reachability-empty-battery-title"
      class="rounded-card border border-subtle bg-white p-5 sm:p-6"
    >
      <h3
        id="reachability-empty-battery-title"
        class="font-display text-[26px] font-semibold leading-tight tracking-[-0.02em] text-strong"
      >
        There's nothing to test yet.
      </h3>
      <p class="mt-2 max-w-[56ch] text-sm text-default">
        A walk needs a place to start and a place to end. This station needs at least one
        entrance and one platform. Add them in Floorplans, then connect them with pathways so
        riders can walk between them.
      </p>
      <div class="mt-5">
        <.link
          id="open-floorplans"
          navigate={~p"/gtfs/#{@gtfs_version.id}/stops/#{@stop_id}/diagram"}
          class="inline-flex min-h-11 items-center justify-center rounded-control bg-action px-5 text-sm font-[650] text-white no-underline hover:bg-action-hover"
        >
          Open floorplans
        </.link>
      </div>
    </section>
    """
  end

  attr :run, :map, default: nil
  attr :gtfs_version, :map, required: true
  attr :stop_id, :string, required: true

  # Runs are ephemeral: each one supersedes the last, so only the latest result
  # is worth an affordance. The full run list stays out of the UI.
  defp last_run(%{run: nil} = assigns), do: ~H""

  defp last_run(assigns) do
    assigns =
      assigns
      |> assign(:failed?, assigns.run.status == "failed")
      |> assign(
        :results_path,
        ~p"/gtfs/#{assigns.gtfs_version.id}/station-reachability/#{assigns.run.id}?stop_id=#{assigns.stop_id}"
      )

    ~H"""
    <section
      id="last-reachability-run"
      aria-labelledby="last-reachability-run-title"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class={[
        "border-l-4 px-5 py-5 sm:px-7 sm:py-6",
        if(@failed?, do: "border-error-line", else: "border-subtle")
      ]}>
        <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
          <h3 id="last-reachability-run-title" class="text-[13px] font-bold text-muted">
            Latest result
          </h3>
          <%= if @failed? do %>
            <.tone_badge tone="error">Didn't finish</.tone_badge>
          <% else %>
            <.tone_badge tone="neutral" icon="hero-check-circle">Completed</.tone_badge>
          <% end %>
        </div>
        <%= if @failed? do %>
          <p class="mt-3 max-w-[34ch] text-balance font-display text-[26px] font-semibold leading-[1.15] tracking-[-0.02em] text-strong sm:max-w-[40ch]">
            The last check stopped before it finished.
          </p>
          <p class="mt-2 text-sm text-muted tabular-nums">
            Started {format_time(@run.inserted_at)} · no walks were scored
          </p>
        <% else %>
          <p class="mt-3 text-sm text-default tabular-nums">
            Checked {format_time(@run.inserted_at)}
          </p>
        <% end %>
      </div>
      <div class="flex flex-wrap items-center justify-between gap-3 border-t border-subtle bg-canvas px-6 py-3 sm:px-8">
        <p :if={@failed?} class="text-[13px] text-muted">Run the check again to get a result.</p>
        <.link
          navigate={@results_path}
          class="ml-auto inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong no-underline hover:bg-canvas"
        >
          {if @failed?, do: "View details", else: "View results"}
          <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      </div>
    </section>
    """
  end

  attr :topology, :map, required: true
  attr :version, :map, required: true

  defp coverage(assigns) do
    ~H"""
    <section
      id="reachability-coverage"
      aria-labelledby="reachability-coverage-title"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle bg-canvas px-5 py-4 sm:px-6">
        <h3 id="reachability-coverage-title" class="text-lg font-bold text-strong">
          What the check covers
        </h3>
        <p class="mt-0.5 text-[13px] text-muted">
          Entrances, platforms and pathways in {@version.name}.
        </p>
      </div>
      <dl class="grid grid-cols-2 gap-x-6 gap-y-5 p-5 sm:grid-cols-4 sm:p-6">
        <.coverage_count
          label="Entrances"
          note="Where riders enter and leave"
          value={@topology.entrance_count}
        />
        <.coverage_count label="Platforms" note="Where riders board" value={@topology.platform_count} />
        <.coverage_count label="Pathways" note="Links between places" value={@topology.pathway_count} />
        <.coverage_count label="Levels" note="Floors in the station" value={@topology.level_count} />
      </dl>
      <div class="border-t border-subtle px-5 py-4 sm:px-6">
        <p class="text-sm text-default tabular-nums">
          The check tests {count_label(div(@topology.pair_count, 2), "walk", "walks")}.
          Each walk is tested twice, on foot and step-free: {@topology.pair_count} checks in total.
        </p>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :note, :string, required: true
  attr :value, :integer, required: true

  defp coverage_count(assigns) do
    ~H"""
    <div>
      <dt class="text-[13px] font-bold text-muted">{@label}</dt>
      <dd class="mt-1 font-display text-[30px] font-semibold leading-tight text-strong tabular-nums">
        {@value}
      </dd>
      <dd class="text-[13px] text-muted">{@note}</dd>
    </div>
    """
  end

  attr :battery?, :boolean, required: true
  attr :gtfs_version, :map, required: true
  attr :stop_id, :string, required: true

  # What "reachable" means is what makes a result readable, so it stays on
  # screen instead of behind a disclosure.
  defp reachable_aside(assigns) do
    ~H"""
    <aside
      id="reachability-meaning"
      aria-labelledby="reachability-meaning-title"
      class="rounded-card bg-canvas p-5 sm:p-6 lg:sticky lg:top-6"
    >
      <h3 id="reachability-meaning-title" class="text-lg font-bold text-strong">
        What “reachable” means
      </h3>
      <p class="mt-2 text-sm text-default">
        A walk is reachable when a rider can get from one place in the station to another using
        only the pathways in your data. Each walk is tested two ways.
      </p>

      <div class="mt-5 grid gap-5">
        <div class="flex gap-3">
          <span class="flex size-9 shrink-0 items-center justify-center rounded-control bg-white text-strong">
            <.mode_icon mode={:walking} />
          </span>
          <div>
            <p class="text-sm font-bold text-strong">On foot</p>
            <p class="mt-0.5 text-sm text-default">
              Any pathway counts: walkways, stairs, escalators, elevators, moving walkways and fare
              gates. If a walk fails here, the two places aren't connected at all.
            </p>
          </div>
        </div>
        <div class="flex gap-3">
          <span class="flex size-9 shrink-0 items-center justify-center rounded-control bg-white text-strong">
            <.mode_icon mode={:wheelchair} />
          </span>
          <div>
            <p class="text-sm font-bold text-strong">Step-free</p>
            <p class="mt-0.5 text-sm text-default">
              Stairs and escalators are taken out. Riders who use wheelchairs, push strollers, use
              walkers or can't manage stairs need a route of level walkways, ramps and elevators.
              If a walk works on foot but fails here, it's an accessibility gap.
            </p>
          </div>
        </div>
      </div>

      <div class="mt-5 border-t border-subtle pt-4">
        <p class="text-sm font-bold text-strong">What the check can't tell you</p>
        <p class="mt-0.5 text-sm text-default">
          It reads your pathway data. It doesn't know whether an elevator is out of service today,
          how steep a ramp is or how wide a door is.
        </p>
        <p class="mt-3 text-[13px] text-muted">
          Routing follows the rules trip planners such as OpenTripPlanner use inside stations, so
          results show how your feed will behave once it's published.
        </p>
      </div>

      <.link
        :if={@battery?}
        id="fix-in-floorplans"
        navigate={~p"/gtfs/#{@gtfs_version.id}/stops/#{@stop_id}/diagram"}
        class="mt-2 inline-flex min-h-11 items-center gap-1 text-sm font-semibold text-action no-underline hover:underline"
      >
        Fix gaps in Floorplans <.icon name="hero-arrow-right" class="size-4" />
      </.link>
    </aside>
    """
  end

  # An in-progress run is already represented by the run button's busy state.
  defp latest_finished_run(organization_id, gtfs_version_id, stop_id) do
    organization_id
    |> Reachability.list_recent_runs(gtfs_version_id, stop_id, 5)
    |> Enum.find(&(&1.status in ["completed", "failed"]))
  end
end
