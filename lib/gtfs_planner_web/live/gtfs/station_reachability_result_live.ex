defmodule GtfsPlannerWeb.Gtfs.StationReachabilityResultLive do
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Reachability
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.Legacy
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Validation Results")
     |> assign(:stop_id, nil)
     |> assign(:run, nil)
     |> assign(:legacy?, false)
     |> assign(:legacy_results, [])
     |> assign(:envelope, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"validation_id" => validation_id} = params, _uri, socket) do
    run = Validations.get_validation_run!(validation_id)
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    if run.organization_id != organization_id do
      {:noreply,
       socket
       |> put_flash(:error, "Unauthorized access to validation run")
       |> push_navigate(to: ~p"/gtfs/#{gtfs_version_id}/export")}
    else
      if run.run_type != "station_reachability" do
        {:noreply, push_navigate(socket, to: ~p"/gtfs/#{gtfs_version_id}/validation/#{run.id}")}
      else
        if connected?(socket) and run.status in ["pending", "started", "running"] do
          Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Reachability.topic(run.id))
        end

        legacy? = Legacy.legacy_station_run?(run)

        socket =
          socket
          |> assign(:stop_id, Map.get(params, "stop_id"))
          |> assign(:validation_id, validation_id)
          |> assign(:run, run)
          |> assign(:legacy?, legacy?)

        socket =
          if legacy? do
            legacy_results = Legacy.list_run_results(run.id)
            assign(socket, :legacy_results, legacy_results)
          else
            envelope = run.result_json
            assign(socket, :envelope, envelope)
          end

        validation_runs_history =
          Validations.list_validation_runs(organization_id, gtfs_version_id)

        {:noreply, stream(socket, :validation_runs, validation_runs_history)}
      end
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:reachability_run_completed, run_id}, socket) do
    if socket.assigns[:validation_id] == run_id do
      run = Reachability.get_run(run_id)

      {:noreply,
       socket
       |> assign(:run, run)
       |> assign(:envelope, run.result_json)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reachability_run_failed, run_id, _reason}, socket) do
    if socket.assigns[:validation_id] == run_id do
      run = Reachability.get_run(run_id)
      {:noreply, assign(socket, :run, run)}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      validation_id = socket.assigns[:validation_id]

      if validation_id do
        {:noreply,
         push_navigate(socket, to: "/gtfs/#{version_id}/station-reachability/#{validation_id}")}
      else
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="drawer drawer-end">
      <input id="validation-history-drawer" type="checkbox" class="drawer-toggle" />
      <div class="drawer-content">
        <Layouts.app
          flash={@flash}
          current_user={@current_user}
          current_organization={@current_organization}
          user_roles={@user_roles}
          current_path={@current_path}
          current_gtfs_version={assigns[:current_gtfs_version]}
          available_versions={assigns[:available_versions] || []}
        >
          <.header>
            Station Reachability Results
            <:subtitle>
              {run_subtitle(@run)}
            </:subtitle>
            <:actions>
              <label for="validation-history-drawer" class="btn btn-outline btn-sm">
                View History
              </label>
              <%= if @stop_id do %>
                <.link
                  navigate={~p"/gtfs/#{@current_gtfs_version.id}/stops/#{@stop_id}/reachability"}
                  class="btn btn-outline btn-sm"
                >
                  Back to Reachability
                </.link>
              <% end %>
            </:actions>
          </.header>

          <div class="mt-6">
            <.status_badge
              status={@run.status}
              label={String.upcase(@run.status)}
              class="origin-left scale-[1.3]"
            />
          </div>

          <%= cond do %>
            <% @run.status == "failed" -> %>
              <.failed_state run={@run} />
            <% @run.status in ["pending", "started", "running"] -> %>
              <.running_state />
            <% @legacy? -> %>
              <.legacy_results run={@run} results={@legacy_results} />
            <% true -> %>
              <.new_engine_results envelope={@envelope} />
          <% end %>
        </Layouts.app>
      </div>

      <div class="drawer-side z-40">
        <label for="validation-history-drawer" class="drawer-overlay"></label>
        <div class="w-80 border-l border-base-300 bg-base-100 p-4">
          <h3 class="text-lg font-semibold">Run History</h3>
          <div id="validation-runs-history" phx-update="stream" class="mt-4 space-y-2">
            <div
              :for={{id, run} <- @streams.validation_runs}
              id={id}
              class="rounded border border-base-200 p-2 text-sm"
            >
              <div class="flex items-center justify-between">
                <span class="font-medium">{run.run_type}</span>
                <.status_badge status={run.status} label={run.status} />
              </div>
              <div class="mt-1 text-xs text-base-content/60">
                {Calendar.strftime(run.inserted_at, "%b %d, %Y %H:%M")}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :run, :map, required: true

  defp failed_state(assigns) do
    ~H"""
    <section class="mt-6 rounded-lg border border-red-300 bg-white" role="alert">
      <div class="flex items-start gap-3 px-5 py-4">
        <.icon name="hero-exclamation-triangle" class="mt-0.5 h-5 w-5 shrink-0 text-red-600" />
        <div>
          <h3 class="text-base font-semibold text-gray-900">Validation Failed</h3>
          <p class="mt-1 text-sm text-gray-700">
            {@run.error_details || "The reachability run failed unexpectedly."}
          </p>
        </div>
      </div>
    </section>
    """
  end

  defp running_state(assigns) do
    ~H"""
    <section class="mt-6 rounded-lg border border-blue-200 bg-blue-50 p-5">
      <div class="flex items-center gap-3">
        <span class="loading loading-spinner loading-md text-blue-600"></span>
        <p class="text-sm text-blue-800">
          Reachability analysis is running. Results will appear automatically.
        </p>
      </div>
    </section>
    """
  end

  attr :run, :map, required: true
  attr :results, :list, required: true

  defp legacy_results(assigns) do
    ~H"""
    <section class="mt-6">
      <div class="rounded-lg border border-amber-200 bg-amber-50 p-4">
        <div class="flex items-start gap-2">
          <.icon name="hero-information-circle" class="mt-0.5 h-5 w-5 text-amber-600" />
          <p class="text-sm text-amber-800">
            This run used the retired street-address engine and is not directly comparable
            to in-station structural reachability results.
          </p>
        </div>
      </div>

      <div class="mt-4 overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Test</th>
              <th>Origin</th>
              <th>Destination</th>
              <th>Status</th>
              <th>Duration</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={result <- @results}>
              <td>{result.walkability_test && result.walkability_test.name}</td>
              <td>{result.origin_description}</td>
              <td>{result.destination_description}</td>
              <td>
                <.status_badge
                  status={if(result.reachable, do: "completed", else: "failed")}
                  label={if(result.reachable, do: "reachable", else: "unreachable")}
                />
              </td>
              <td>{result.duration_seconds && "#{result.duration_seconds}s"}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :envelope, :map, required: true

  defp new_engine_results(assigns) do
    ~H"""
    <section class="mt-6 space-y-6">
      <%= if @envelope && @envelope["diagnostics"] != [] do %>
        <.diagnostics_section diagnostics={@envelope["diagnostics"]} />
      <% end %>

      <%= if @envelope do %>
        <.topology_section envelope={@envelope} />
        <.pair_matrix pairs={@envelope["pairs"]} />
      <% end %>
    </section>
    """
  end

  attr :diagnostics, :list, required: true

  defp diagnostics_section(assigns) do
    ~H"""
    <div class="rounded-lg border border-amber-200 bg-amber-50 p-4">
      <h4 class="flex items-center gap-2 text-sm font-semibold text-amber-800">
        <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
        Graph Diagnostics ({length(@diagnostics)})
      </h4>
      <ul class="mt-2 space-y-1">
        <li :for={diag <- @diagnostics} class="text-sm text-amber-700">
          <span class="font-medium">[{diag["severity"]}]</span>
          {diag["message"]}
          <span :if={diag["entity_id"]} class="text-amber-600">({diag["entity_id"]})</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :envelope, :map, required: true

  defp topology_section(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
      <.stat_card label="Entrances" value={@envelope["topology"]["entrance_count"]} />
      <.stat_card label="Platforms" value={@envelope["topology"]["platform_count"]} />
      <.stat_card label="Pathways" value={@envelope["topology"]["pathway_count"]} />
      <.stat_card label="Levels" value={@envelope["topology"]["level_count"]} />
    </div>
    <div class="flex items-center gap-4">
      <span class="badge badge-lg" data-outcome={@envelope["outcome"]}>
        {String.upcase(@envelope["outcome"])}
      </span>
      <span class="text-sm text-base-content/60">
        {@envelope["totals"]["reachable"]} reachable /
        {@envelope["totals"]["pair_count"]} pairs
        ({@envelope["duration_ms"]}ms)
      </span>
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

  attr :pairs, :list, required: true

  defp pair_matrix(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm" id="pair-matrix">
        <thead>
          <tr>
            <th>#</th>
            <th>Kind</th>
            <th>Mode</th>
            <th>From</th>
            <th>To</th>
            <th>Outcome</th>
            <th>Duration</th>
            <th>Distance</th>
            <th>Steps</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={pair <- @pairs}
            class={if pair["outcome"] != "reachable", do: "bg-red-50 font-medium"}
          >
            <td>{pair["index"]}</td>
            <td>{pair["kind"]}</td>
            <td>
              <span class="badge badge-sm badge-ghost">{pair["mode"]}</span>
            </td>
            <td title={pair["from_stop_id"]}>{pair["from_stop_name"] || pair["from_stop_id"]}</td>
            <td title={pair["to_stop_id"]}>{pair["to_stop_name"] || pair["to_stop_id"]}</td>
            <td>
              <.outcome_badge outcome={pair["outcome"]} />
            </td>
            <td>{pair["duration_seconds"] && "#{pair["duration_seconds"]}s"}</td>
            <td>{pair["distance_meters"] && "#{Float.round(pair["distance_meters"], 1)}m"}</td>
            <td>{pair["step_count"]}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :outcome, :string, required: true

  defp outcome_badge(assigns) do
    ~H"""
    <span
      class={[
        "badge badge-sm",
        case @outcome do
          "reachable" -> "badge-success"
          "unreachable" -> "badge-error"
          "invalid" -> "badge-warning"
          _ -> "badge-ghost"
        end
      ]}
      data-outcome={@outcome}
    >
      <%= if @outcome == "unreachable" do %>
        <.icon name="hero-x-circle" class="mr-0.5 h-3 w-3" />
      <% end %>
      {@outcome}
    </span>
    """
  end

  defp run_subtitle(run) do
    case run.status do
      "completed" -> "Completed #{Calendar.strftime(run.completed_at, "%b %d, %Y at %H:%M")}"
      "failed" -> "Failed"
      _ -> "In progress"
    end
  end
end
