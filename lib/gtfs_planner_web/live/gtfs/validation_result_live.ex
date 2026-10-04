defmodule GtfsPlannerWeb.Gtfs.ValidationResultLive do
  @moduledoc """
  LiveView for one validation run at `/gtfs/:version/validation/:validation_id`.

  The same route serves three kinds of run, so the page has one branch per state:

    * a MobilityData run that completed: a summary, then the findings grouped by
      severity as disclosures (Problems open, the rest closed);
    * an older OpenTripPlanner walk-test run (`pathways_tests`), which is
      read-only history: summary, coverage and per-check roll-ups, and one
      disclosure per test;
    * a run that is starting or running, has failed, or has no report yet.

  A run that belongs to another organization or version is redirected to Export
  before anything renders. Which findings are open lives on the server
  (`expanded_codes`), so the disclosures survive a re-render.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.Evidence
  alias GtfsPlannerWeb.AgentPanel

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1]

  import GtfsPlannerWeb.ResultComponents,
    only: [result_details: 1, result_section: 1, result_summary: 1, tone_badge: 1]

  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Layouts
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @pathways_failure_messages %{
    no_walkability_tests: "No walk tests are set up for this version.",
    query_failure: "Some walk tests couldn't get a route from the routing engine.",
    scoring_failure: "Results couldn't be scored against the expected times and distances.",
    pathways_runner_spawn_failed: "The walk tests couldn't start.",
    pathways_persistence_failed: "The walk tests ran, but their results couldn't be saved.",
    pathways_export_prep_failed:
      "This version's data couldn't be prepared for the routing engine.",
    pathways_task_crashed: "The walk tests stopped unexpectedly.",
    pathways_status_unavailable: "The walk tests' progress couldn't be read.",
    pathways_run_not_found: "This walk test run no longer exists.",
    pathways_invalid_run_type: "This run isn't a walk test run.",
    pathways_results_unavailable: "The results couldn't be loaded."
  }

  @pathways_failure_codes %{
    "no_walkability_tests" => :no_walkability_tests,
    "query_failure" => :query_failure,
    "scoring_failure" => :scoring_failure,
    "pathways_runner_spawn_failed" => :pathways_runner_spawn_failed,
    "pathways_persistence_failed" => :pathways_persistence_failed,
    "pathways_export_prep_failed" => :pathways_export_prep_failed,
    "pathways_task_crashed" => :pathways_task_crashed,
    "pathways_status_unavailable" => :pathways_status_unavailable,
    "pathways_run_not_found" => :pathways_run_not_found,
    "pathways_invalid_run_type" => :pathways_invalid_run_type,
    "pathways_results_unavailable" => :pathways_results_unavailable
  }

  @pathways_criteria_overview_definitions [
    %{kind: "expected_traversable", label: "Can be walked"},
    %{kind: "duration_seconds_range", label: "Walk time"},
    %{kind: "distance_meters_range", label: "Distance"},
    %{kind: "expected_wheelchair_accessible", label: "Wheelchair accessible"}
  ]

  # The validator's three severities, in the plain words the page uses for them.
  # `other` catches a severity this page doesn't recognize, so no finding is hidden.
  @finding_sections [
    %{
      key: "error",
      tone: "error",
      title: "Problems to fix before publishing",
      lede:
        "These break the GTFS standard. Trip planners may reject the feed or show riders the wrong trips."
    },
    %{
      key: "warning",
      tone: "warning",
      title: "Suggestions",
      lede:
        "These won't block publishing. They improve what riders see, so fix them when you can."
    },
    %{
      key: "info",
      tone: "info",
      title: "Notes",
      lede: "For your information. No action is needed unless something looks wrong."
    },
    %{
      key: "other",
      tone: "neutral",
      title: "Other findings",
      lede: "The validator reported these with a severity this page doesn't recognize."
    }
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Validation results")
     |> assign(:user_roles, user_roles)
     |> assign(:history_open, false)
     |> assign(:expanded_codes, MapSet.new())
     |> assign(:pathways_failure, nil)
     |> assign(:pathways_failure_message, nil)
     |> assign(:pathways_failure_diagnostics, [])
     |> assign(:pathways_case_results, [])
     |> assign(:feed_quality_available?, false)
     |> assign(:feed_quality, nil)
     |> assign(:feed_quality_digest, nil)
     |> assign(:feed_quality_samples, [])
     |> assign(:requested_instance_ref, nil)
     |> AgentPanel.mount("feed_quality")}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"validation_id" => validation_id}, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    # The run is resolved inside this organization and version before any
    # report JSON is read, so a foreign, absent or malformed id is the same
    # redirect and never another organization's report (INV-1, AC-1).
    case Validations.fetch_scoped_run(organization_id, gtfs_version_id, validation_id) do
      {:error, :unavailable} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unauthorized access to validation run")
         |> push_navigate(to: ~p"/gtfs/#{gtfs_version_id}/export")}

      {:ok, run} ->
        validation_runs_history =
          Validations.list_validation_runs(organization_id, gtfs_version_id)

        {run, pathways_case_results} = load_pathways_render_data(run)
        pathways_failure = pathways_failure(run)
        pathways_failure_message = pathways_failure_message(run)
        pathways_failure_diagnostics = pathways_failure_diagnostics(run)

        socket =
          socket
          |> assign(:validation_id, validation_id)
          |> assign(:run, run)
          |> assign(:expanded_codes, default_expanded_codes(run))
          |> assign(:pathways_failure, pathways_failure)
          |> assign(:pathways_failure_message, pathways_failure_message)
          |> assign(:pathways_failure_diagnostics, pathways_failure_diagnostics)
          |> assign(:pathways_case_results, pathways_case_results)
          |> stream(:validation_runs, validation_runs_history)

        {:noreply, assign_feed_quality(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("feed_quality_refresh", _params, socket) do
    {:noreply, assign_feed_quality(socket)}
  end

  # The native Inspect target action is the only way a finding becomes approved
  # for the helper: it resolves the reference server-side first, then pins it in
  # the panel's own context. A model explanation can never approve an edit, and
  # nothing is written or applied here.
  @impl Phoenix.LiveView
  def handle_event("feed_quality_inspect", %{"instance_ref" => instance_ref}, socket)
      when is_binary(instance_ref) do
    case Evidence.locate(feed_quality_scope(socket), socket.assigns.run.id, instance_ref) do
      {:ok, %{targets: [_ | _]}} ->
        socket = assign(socket, :requested_instance_ref, instance_ref)

        socket =
          AgentPanel.set_context(socket, feed_quality_context(socket))

        {:noreply,
         assign(
           socket,
           :agent_notice,
           "This finding is approved for navigation. Ask the helper for its handoff."
         )}

      # A sample that names no single current record has nothing to navigate to,
      # so it is never approved.
      _unresolved ->
        {:noreply,
         assign(socket, :agent_notice, "That finding does not resolve to a current record.")}
    end
  end

  def handle_event("feed_quality_inspect", _params, socket), do: {:noreply, socket}

  # Review options is the Export page's control; the helper cannot prepare it
  # here, so a prepared-change event on this page changes nothing.
  def handle_event("agent_review_prepared", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      validation_id = socket.assigns[:validation_id]

      if validation_id do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/validation/#{validation_id}")}
      else
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_notice", %{"code" => code}, socket) do
    expanded_codes = socket.assigns.expanded_codes

    updated_codes =
      if MapSet.member?(expanded_codes, code) do
        MapSet.delete(expanded_codes, code)
      else
        MapSet.put(expanded_codes, code)
      end

    {:noreply, assign(socket, :expanded_codes, updated_codes)}
  end

  # Expand all / Collapse all for one severity section: collapse when every
  # finding in it is open, otherwise open them all.
  @impl Phoenix.LiveView
  def handle_event("toggle_section", %{"section" => key}, socket) do
    expanded_codes = socket.assigns.expanded_codes
    codes = socket.assigns.run |> notices() |> section_codes(key)

    updated_codes =
      if all_expanded?(codes, expanded_codes) do
        MapSet.difference(expanded_codes, MapSet.new(codes))
      else
        MapSet.union(expanded_codes, MapSet.new(codes))
      end

    {:noreply, assign(socket, :expanded_codes, updated_codes)}
  end

  @impl Phoenix.LiveView
  def handle_event("open_history", _params, socket) do
    {:noreply, assign(socket, :history_open, true)}
  end

  @impl Phoenix.LiveView
  def handle_event("close_history", _params, socket) do
    {:noreply, assign(socket, :history_open, false)}
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
      <div id="validation-result-page" class="ds-page pb-16">
        <.back_link id="back-to-export" navigate={~p"/gtfs/#{@current_gtfs_version.id}/export"}>
          Back to export
        </.back_link>

        <.header>
          Validation results
          <:subtitle>
            {validation_lede(@run, @current_gtfs_version)}
            <span id="validation-run-meta" class="mt-2 block tabular-nums">{run_meta(@run)}</span>
          </:subtitle>
          <:actions>
            <.button
              :if={@feed_quality_available?}
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
            <.button id="open-history" variant="secondary" class="min-h-11" phx-click="open_history">
              <.icon name="hero-list-bullet" class="size-4" /> View history
            </.button>
          </:actions>
        </.header>

        <%!--
        The panel's focus listener belongs to this persistent wrapper, not to the panel: the
        closing panel cannot own a handler that runs after its own removal. The grid gives the
        report the full width while the panel is closed and a fixed 24rem column while it is
        open, and the report column is hidden at phone width so the panel replaces it. The
        panel stays inside the design-system page, so it takes the page's colours and focus
        rings. --%>
        <div
          id="validation-helper-focus"
          phx-hook=".ValidationHelperFocus"
          class={["lg:grid lg:gap-6", @agent_open? && "lg:grid-cols-[minmax(0,1fr)_24rem]"]}
        >
          <div class={["min-w-0", @agent_open? && "hidden lg:block"]}>
            <section
              :if={@feed_quality_available?}
              id="feed-quality-evidence"
              class="mt-2 rounded-card border border-control bg-white px-5 py-4"
            >
              <h2 class="text-sm font-bold text-strong">Feed quality</h2>
              <p id="feed-quality-samples" class="mt-1 text-[13px] text-default tabular-nums">
                {findings_label(@feed_quality)} · {@feed_quality.retained_instances} retained samples · {@feed_quality.completeness}
              </p>
              <p
                :if={@feed_quality.limits != []}
                id="feed-quality-limits"
                class="mt-1 text-[13px] text-muted"
              >
                {Enum.join(@feed_quality.limits, " ")}
              </p>
              <p id="feed-quality-provenance" class="mt-1 text-[13px] text-muted">
                Validator {validator_label(@feed_quality.validator_version)} · report digest {short_digest(
                  @feed_quality_digest
                )}
              </p>
              <p id="feed-quality-unmapped" class="mt-1 text-[13px] text-muted">
                {unmapped_label(@feed_quality_samples)}
              </p>
              <div id="feed-quality-inspect-target" class="mt-2 flex flex-wrap items-center gap-2">
                <%= for {sample, index} <- Enum.with_index(@feed_quality_samples), sample.resolved? do %>
                  <button
                    id={"feed-quality-inspect-#{index}"}
                    type="button"
                    phx-click="feed_quality_inspect"
                    phx-value-instance_ref={sample.ref}
                    class="rounded-control border border-control px-2 py-1 text-[13px] font-semibold text-action"
                  >
                    Inspect target {index + 1}
                  </button>
                <% end %>
                <button
                  id="feed-quality-refresh"
                  type="button"
                  phx-click="feed_quality_refresh"
                  class="text-[13px] font-semibold text-action"
                >
                  Refresh findings
                </button>
              </div>
            </section>

            <%= cond do %>
              <% @run.status == "failed" and @pathways_failure -> %>
                <.pathways_failure_card
                  failure={@pathways_failure}
                  message={@pathways_failure_message}
                  diagnostics={@pathways_failure_diagnostics}
                  version={@current_gtfs_version}
                />
              <% @run.status == "failed" -> %>
                <.validation_failure_card run={@run} version={@current_gtfs_version} />
              <% @run.status in ["started", "running"] -> %>
                <.checking_card status={@run.status} />
              <% @run.status == "completed" and not is_nil(@run.result_json) and @run.run_type == "pathways_tests" -> %>
                <.walk_results
                  run={@run}
                  cases={@pathways_case_results}
                  version={@current_gtfs_version}
                />
              <% @run.status == "completed" and not is_nil(@run.result_json) -> %>
                <.mobility_results
                  run={@run}
                  expanded_codes={@expanded_codes}
                  version={@current_gtfs_version}
                />
              <% true -> %>
                <.no_result_card version={@current_gtfs_version} />
            <% end %>
          </div>

          <div
            :if={@agent_open?}
            class="flex min-w-0 lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)]"
          >
            <.agent_panel
              id="agent-panel"
              title={@agent_title}
              intro={@agent_intro}
              examples={@agent_examples}
              scope_line={"Validation · " <> @current_gtfs_version.name}
              status={@agent_status}
              entries={@streams.agent_entries}
              form={@agent_form}
              notice={@agent_notice}
              entries_empty?={@agent_entries_empty?}
            />
          </div>
        </div>
      </div>

      <.drawer
        id="validation-history"
        chrome="planner"
        title="Validation history"
        open={@history_open}
        on_close="close_history"
        return_focus_id="open-history"
        class="max-w-[440px]"
      >
        <:lede>{@current_gtfs_version.name} · most recent checks first</:lede>
        <ol
          id="validation-runs-list"
          phx-update="stream"
          class="min-h-0 flex-1 divide-y divide-subtle overflow-y-auto"
        >
          <li :for={{dom_id, run} <- @streams.validation_runs} id={dom_id}>
            <.link
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/validation/#{run.id}"}
              aria-current={if run.id == @run.id, do: "page"}
              class="block px-5 py-4 text-default no-underline hover:bg-canvas aria-[current=page]:bg-selection"
            >
              <span class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
                <span class="text-sm font-bold tabular-nums text-strong">
                  {run_time(run.started_at)}
                </span>
                <.tone_badge tone={history_tone(run.status)}>
                  {history_status(run.status)}
                </.tone_badge>
              </span>
              <span class="mt-1 block text-[13px] text-muted">
                {history_type(run.run_type)}<span :if={run.id == @run.id}> · You're viewing this one</span>
              </span>
              <span
                :if={history_counts(run)}
                class="mt-0.5 block text-[13px] tabular-nums text-default"
              >
                {history_counts(run)}
              </span>
            </.link>
          </li>
        </ol>
        <p class="border-t border-subtle px-5 py-3 text-[13px] text-muted">
          Shows the last 20 checks for this version.
        </p>
      </.drawer>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ValidationHelperFocus">
        export default {
          mounted() {
            this.handleEvent("agent:focus", ({id}) => document.getElementById(id)?.focus())
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # ── Completed MobilityData run ──

  attr :run, :map, required: true
  attr :expanded_codes, :any, required: true
  attr :version, :map, required: true

  defp mobility_results(assigns) do
    notices = notices(assigns.run)

    assigns =
      assigns
      |> assign(:summary, mobility_summary(assigns.run, notices))
      |> assign(:sections, finding_sections(notices))

    ~H"""
    <.result_summary
      id="validation-summary"
      tone={@summary.tone}
      badge={@summary.badge}
      title={@summary.title}
    >
      {@summary.body}
      <:metric
        id="validation-count-errors"
        value_id="validation-count-errors-value"
        label="Problems"
        value={@run.errors_count}
        tone="error"
      >
        Blocking issues
      </:metric>
      <:metric
        id="validation-count-warnings"
        value_id="validation-count-warnings-value"
        label="Suggestions"
        value={@run.warnings_count}
        tone="warning"
      >
        Potential issues
      </:metric>
      <:metric
        id="validation-count-infos"
        value_id="validation-count-infos-value"
        label="Notes"
        value={@run.infos_count}
        tone="info"
      >
        Informational notices
      </:metric>
      <:foot>
        This page shows the check from {run_time(@run.completed_at || @run.started_at)}. Fixed something?
        <.export_link version={@version}>Run validation again from Export</.export_link>
        to update these results.
      </:foot>
    </.result_summary>

    <div id="validation-findings" class="mt-8 grid gap-8">
      <.result_section
        :for={section <- @sections}
        id={"findings-#{section.key}"}
        tone={section.tone}
        title={section.title}
        count={length(section.findings)}
        lede={section.lede}
      >
        <:action>
          <button
            type="button"
            id={"toggle-findings-#{section.key}"}
            phx-click="toggle_section"
            phx-value-section={section.key}
            aria-label={
              if section_expanded?(section, @expanded_codes),
                do: "Collapse all #{section_noun(section)}",
                else: "Expand all #{section_noun(section)}"
            }
            class="inline-flex min-h-11 items-center rounded-control px-2 text-sm font-semibold text-action hover:bg-white focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          >
            {if section_expanded?(section, @expanded_codes), do: "Collapse all", else: "Expand all"}
          </button>
        </:action>
        <div class="hidden grid-cols-[1.25rem_minmax(0,1fr)_9rem] gap-x-4 border-b border-subtle px-5 py-2 text-[13px] font-semibold text-muted sm:grid">
          <span></span><span>Finding</span><span class="text-right">Occurrences</span>
        </div>
        <div class="divide-y divide-subtle">
          <.finding
            :for={group <- section.findings}
            group={group}
            open?={MapSet.member?(@expanded_codes, group["code"])}
          />
        </div>
      </.result_section>
    </div>

    <.result_details id="validation-run-details" title="Details about this check">
      <.run_facts rows={mobility_facts(@run, @version)} />
    </.result_details>
    """
  end

  attr :group, :map, required: true
  attr :open?, :boolean, required: true

  defp finding(assigns) do
    group = assigns.group
    code = group["code"]
    total = get_total_notices(group)

    assigns =
      assigns
      |> assign(:code, code)
      |> assign(:dom, dom_token(code))
      |> assign(:title, humanize_code(code))
      |> assign(:total, total)
      |> assign(
        :context,
        [extract_filename(group), extract_sample_context(group)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")
        |> case do
          "" -> nil
          text -> text
        end
      )
      |> assign(:samples, get_sample_notices(group))

    ~H"""
    <details id={"finding-#{@dom}"} class="group" open={@open?}>
      <summary
        phx-click="toggle_notice"
        phx-value-code={@code}
        class="grid min-h-14 cursor-pointer list-none grid-cols-[1.25rem_minmax(0,1fr)] items-start gap-x-4 gap-y-1 px-5 py-3.5 hover:bg-canvas sm:grid-cols-[1.25rem_minmax(0,1fr)_9rem] sm:items-center [&::-webkit-details-marker]:hidden"
      >
        <.icon
          name="hero-chevron-right"
          class="mt-0.5 size-5 text-muted transition-transform group-open:rotate-90 sm:mt-0"
        />
        <span class="min-w-0">
          <span class="block text-[15px] font-bold leading-snug text-strong">{@title}</span>
          <span :if={@context} class="mt-0.5 block truncate text-[13px] leading-snug text-muted">
            {@context}
          </span>
        </span>
        <span class="col-start-2 text-[13px] tabular-nums sm:col-start-auto sm:text-right">
          <strong class="font-semibold text-strong">{Wording.count(@total)}</strong>
          {if @total == 1, do: "occurrence", else: "occurrences"}
        </span>
      </summary>
      <div class="px-5 pb-7 pt-2 sm:pl-14">
        <div :if={@samples != []} class="overflow-hidden rounded-card border border-subtle">
          <table
            id={"finding-samples-#{@dom}"}
            class="vr-stack w-full border-collapse text-left text-sm"
          >
            <caption class="sr-only">Example places the validator found: {@title}</caption>
            <thead>
              <tr class="bg-canvas text-[13px] font-semibold text-strong">
                <th scope="col" class="px-4 py-2.5 text-left">File</th>
                <th scope="col" class="px-4 py-2.5 text-left">Line</th>
                <th scope="col" class="px-4 py-2.5 text-left">Column</th>
                <th scope="col" class="px-4 py-2.5 text-left">Message</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={sample <- @samples} class="border-t border-subtle align-top">
                <td data-label="File" class="px-4 py-2.5">{sample["filename"] || "-"}</td>
                <td data-label="Line" class="px-4 py-2.5 tabular-nums">
                  {sample["csvRowNumber"] || "-"}
                </td>
                <td data-label="Column" class="px-4 py-2.5">{sample["csvFieldName"] || "-"}</td>
                <td data-label="Message" class="px-4 py-2.5">
                  <span class="whitespace-pre-wrap">{sample["message"] || "-"}</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@samples == []} class="text-sm text-muted">
          The validator gave no example rows for this finding.
        </p>
        <p class="mt-3 break-words text-[13px] text-muted">
          Validator code
          <code id={"finding-code-#{@dom}"} class="break-all font-mono text-[12px] text-default">
            {@code}
          </code>
        </p>
      </div>
    </details>
    """
  end

  # ── Run states that are not a report ──

  attr :status, :string, required: true

  defp checking_card(assigns) do
    ~H"""
    <.result_summary
      id="validation-progress"
      role="status"
      tone="info"
      badge={if @status == "started", do: "Starting", else: "Checking"}
      title={if @status == "started", do: "Starting the check.", else: "Checking your feed."}
    >
      Results appear on this page when the check finishes. This page doesn't update by itself:
      reload it to see the latest.
      <:extra>
        <div
          class="ds-indeterminate mt-5 max-w-[44rem]"
          role="progressbar"
          aria-label="Validation in progress"
        >
        </div>
      </:extra>
    </.result_summary>
    """
  end

  attr :run, :map, required: true
  attr :version, :map, required: true

  defp validation_failure_card(assigns) do
    ~H"""
    <.result_summary
      id="validation-failure"
      role="alert"
      tone="error"
      badge="Check didn't finish"
      title="The check stopped before it could judge your feed."
    >
      This isn't a clean result: the feed wasn't judged, and nothing in your data changed. <.export_link version={
        @version
      }>Run validation again from Export</.export_link>. If it stops again, send the technical details below to support.
    </.result_summary>

    <.result_details id="validation-failure-details" title="Technical details for support" open>
      <dl class="grid grid-cols-[minmax(0,1fr)] gap-x-8 gap-y-2 text-sm sm:grid-cols-[10rem_minmax(0,1fr)]">
        <dt class="text-muted">Run ID</dt>
        <dd><code class="break-all font-mono text-[13px]">{@run.id}</code></dd>
        <dt class="text-muted">Stopped</dt>
        <dd class="tabular-nums">{run_time(@run.completed_at || @run.started_at)}</dd>
        <dt class="text-muted">Reported</dt>
        <dd>
          <pre
            id="validation-failure-raw"
            class="whitespace-pre-wrap break-words rounded-control border border-subtle bg-canvas p-3 font-mono text-xs leading-relaxed text-default"
          >{failure_summary(@run)}</pre>
        </dd>
      </dl>
    </.result_details>
    """
  end

  attr :version, :map, required: true

  defp no_result_card(assigns) do
    ~H"""
    <.result_summary
      id="validation-no-result"
      tone="neutral"
      badge="No results yet"
      title="There are no results to show."
    >
      This check hasn't produced a report. It may still be queued. Reload in a moment, or <.export_link version={
        @version
      }>run validation again from Export</.export_link>.
    </.result_summary>
    """
  end

  attr :version, :map, required: true
  slot :inner_block, required: true

  defp export_link(assigns) do
    ~H"""
    <.link
      phx-no-format
      navigate={~p"/gtfs/#{@version.id}/export"}
      class="font-semibold text-action underline underline-offset-4 hover:text-action-hover"
    >{render_slot(@inner_block)}</.link>
    """
  end

  attr :failure, :map, required: true
  attr :message, :string, default: nil
  attr :diagnostics, :list, default: []
  attr :version, :map, required: true

  defp pathways_failure_card(assigns) do
    ~H"""
    <.result_summary
      id="pathways-failure"
      role="alert"
      tone="error"
      badge="Walk tests didn't finish"
      title={@failure.title}
      title_id="pathways-failure-title"
    >
      This isn't a clean result, and nothing in your data changed.
      <:extra>
        <div class="mt-5 max-w-[44rem] rounded-card border border-subtle bg-canvas px-4 py-3 text-sm leading-relaxed">
          <p id="pathways-failure-status-message">
            <strong class="font-bold text-strong">What happened:</strong> {@message}
          </p>
          <p
            :if={@failure.summary != @message}
            id="pathways-failure-summary"
            class="mt-1 text-muted"
          >
            {@failure.summary}
          </p>
        </div>

        <section
          :if={@failure.blocking_issues != []}
          id="pathways-failure-blocking-issues"
          class="mt-5"
        >
          <h3 class="text-[13px] font-bold text-strong">Blocking issues</h3>
          <ul class="mt-2 grid gap-2 text-sm">
            <li
              :for={issue <- @failure.blocking_issues}
              class="border-l-2 border-error-line pl-3"
            >
              <p>{issue.message}</p>
              <p :if={issue.context_summary} class="mt-1 font-mono text-xs text-muted">
                {issue.context_summary}
              </p>
            </li>
          </ul>
        </section>

        <section :if={@failure.checks != []} id="pathways-failure-checks" class="mt-5">
          <h3 class="text-[13px] font-bold text-strong">Recommended checks</h3>
          <ul class="mt-2 list-disc pl-5 text-sm">
            <li :for={check <- @failure.checks}>{check}</li>
          </ul>
        </section>
      </:extra>
      <:foot>
        <.older_result_note version={@version} />
      </:foot>
    </.result_summary>

    <.result_details
      :if={@diagnostics != []}
      id="pathways-failure-diagnostics"
      title="Technical details for support"
    >
      <dl class="grid grid-cols-[minmax(0,1fr)] gap-x-8 gap-y-2 text-sm sm:grid-cols-[10rem_minmax(0,1fr)]">
        <%= for detail <- @diagnostics do %>
          <dt class="text-muted">{detail.label}</dt>
          <%= cond do %>
            <% detail.label == "Build log excerpt" -> %>
              <dd class="min-w-0">
                <pre class="whitespace-pre-wrap break-words rounded-control border border-subtle bg-canvas p-3 font-mono text-xs leading-relaxed text-default">{detail.value}</pre>
              </dd>
            <% detail.label in ["Likely GTFS source", "Likely cause"] -> %>
              <dd class="min-w-0">{detail.value}</dd>
            <% true -> %>
              <dd class="min-w-0 break-all font-mono text-[13px]">{detail.value}</dd>
          <% end %>
        <% end %>
      </dl>
    </.result_details>
    """
  end

  attr :version, :map, required: true

  defp older_result_note(assigns) do
    ~H"""
    <.icon name="hero-information-circle" class="mr-1 size-3.5 align-[-2px]" />
    This is an older result. Walk tests used OpenTripPlanner and are no longer run. New checks test the feed itself:
    <.export_link version={@version}>run validation from Export</.export_link>.
    """
  end

  # ── Older walk-test run ──

  attr :run, :map, required: true
  attr :cases, :list, required: true
  attr :version, :map, required: true

  defp walk_results(assigns) do
    overview = pathways_trip_overview(assigns.cases)

    assigns =
      assigns
      |> assign(:overview, overview)
      |> assign(:summary, walk_summary(overview))
      |> assign(:criteria_rows, pathways_criteria_overview(assigns.cases))
      |> assign(:case_checks, pathways_case_criteria_checks(assigns.cases))

    ~H"""
    <.result_summary
      id="pathways-trip-visualization-overview"
      tone={@summary.tone}
      badge={@summary.badge}
      title={@summary.title}
    >
      {@summary.body}
      <:metric
        id="pathways-trip-overview-pass-count"
        value_id="pathways-trip-overview-pass-count-value"
        label="Passed"
        value={format_pathways_overview_count(Map.get(@overview, :pass_count, 0))}
        tone="success"
      >
        <span id="pathways-trip-overview-total-tests">
          of
          <span id="pathways-trip-overview-total-tests-value">
            {format_pathways_overview_count(Map.get(@overview, :total_tests, 0))}
          </span>
          tests
        </span>
      </:metric>
      <:metric
        id="pathways-trip-overview-warning-count"
        value_id="pathways-trip-overview-warning-count-value"
        label="Need review"
        value={format_pathways_overview_count(Map.get(@overview, :warning_count, 0))}
        tone="warning"
      >
        Walkable, but outside expected range
      </:metric>
      <:metric
        id="pathways-trip-overview-fail-count"
        value_id="pathways-trip-overview-fail-count-value"
        label="Failed"
        value={format_pathways_overview_count(Map.get(@overview, :fail_count, 0))}
        tone="error"
      >
        Not walkable, or no answer
      </:metric>
      <:foot>
        <.older_result_note version={@version} />
      </:foot>
    </.result_summary>

    <div class="mt-8 grid gap-6 lg:grid-cols-2">
      <.pathways_trip_stats_section trip_overview={@overview} />
      <.pathways_criteria_comparison_section criteria_overview_rows={@criteria_rows} />
    </div>

    <div :if={@cases != []} class="mt-8">
      <.result_section
        id="pathways-case-results"
        title="Each walk test"
        count={length(@cases)}
        lede="Open a test to see what was checked and the walking directions."
      >
        <div class="hidden grid-cols-[1.25rem_minmax(0,1fr)_8.5rem_7rem_6rem] gap-x-4 border-b border-subtle px-5 py-2 text-[13px] font-semibold text-muted sm:grid">
          <span></span><span>From address to stop</span><span>Result</span>
          <span class="text-right">Walk time</span><span class="text-right">Distance</span>
        </div>
        <div class="divide-y divide-subtle">
          <.walk_case
            :for={row <- @cases}
            row={row}
            checks={Map.get(@case_checks, row.order_index, [])}
          />
        </div>
      </.result_section>
    </div>

    <.result_details id="validation-run-details" title="Details about this run">
      <.run_facts rows={walk_facts(@run, @version)} />
    </.result_details>
    """
  end

  attr :row, :map, required: true
  attr :checks, :list, required: true

  defp walk_case(assigns) do
    row = assigns.row
    status = pathways_case_display_status(row)
    steps = pathways_itinerary_step_rows(row.itinerary_steps_json)
    tone = walk_tone(status)

    issues =
      if status == "pass", do: [], else: pathways_case_issues(row)

    assigns =
      assigns
      |> assign(:index, row.order_index)
      |> assign(:status, status)
      |> assign(:tone, tone)
      |> assign(:steps, steps)
      |> assign(:issues, issues)

    ~H"""
    <details id={"pathways-case-row-#{@index}"} class="group" data-result={@status}>
      <summary class="grid min-h-14 cursor-pointer list-none grid-cols-[1.25rem_minmax(0,1fr)] items-start gap-x-4 gap-y-1 px-5 py-3.5 hover:bg-canvas sm:grid-cols-[1.25rem_minmax(0,1fr)_8.5rem_7rem_6rem] sm:items-center [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="mt-0.5 size-5 text-muted transition-transform group-open:rotate-90 sm:mt-0"
        />
        <span class="min-w-0">
          <span class="block break-words text-[15px] font-bold leading-snug text-strong">
            {pathways_case_origin(@row)}
          </span>
          <span class="mt-0.5 block break-words text-[13px] leading-snug text-muted">
            To stop {pathways_case_destination(@row)}<span :if={@issues != []}> · {Enum.join(@issues, ", ")}</span>
          </span>
        </span>
        <span class="col-start-2 sm:col-start-auto">
          <.tone_badge tone={@tone}>{walk_result_label(@status)}</.tone_badge>
        </span>
        <span class="col-start-2 text-[13px] tabular-nums sm:col-start-auto sm:text-right">
          <span class="text-muted sm:hidden">Walk time: </span>{format_pathways_seconds(
            @row.duration_seconds
          )}
        </span>
        <span class="col-start-2 text-[13px] tabular-nums sm:col-start-auto sm:text-right">
          <span class="text-muted sm:hidden">Distance: </span>{format_pathways_meters(
            @row.distance_meters
          )}
        </span>
      </summary>
      <div class="grid gap-x-10 gap-y-6 px-5 pb-7 pt-2 lg:grid-cols-2 lg:pl-14">
        <p class="text-[13px] text-muted lg:col-span-2">
          Test ID
          <code class="break-all font-mono text-[12px] text-default">{@row.walkability_test_id}</code>
        </p>
        <div id={"pathways-case-criteria-#{@index}"} class="min-w-0">
          <h3 class="text-[13px] font-bold text-strong">What was checked</h3>
          <%= if @checks == [] do %>
            <p
              id={"pathways-case-criteria-empty-#{@index}"}
              class="mt-2 rounded-card border border-subtle bg-canvas px-4 py-3 text-sm text-muted"
            >
              No expected criteria configured.
            </p>
          <% else %>
            <div class="mt-2 overflow-hidden rounded-card border border-subtle">
              <table
                id={"pathways-case-criteria-table-#{@index}"}
                class="vr-stack w-full border-collapse text-left text-sm"
              >
                <caption class="sr-only">Checks for this walk test</caption>
                <thead>
                  <tr class="bg-canvas text-[13px] font-semibold text-strong">
                    <th scope="col" class="px-4 py-2.5 text-left">Criterion</th>
                    <th scope="col" class="px-4 py-2.5 text-left">Expected</th>
                    <th scope="col" class="px-4 py-2.5 text-left">Actual</th>
                    <th scope="col" class="px-4 py-2.5 text-left">Status</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={check <- @checks}
                    id={"pathways-case-criteria-check-#{@index}-#{check.kind}"}
                    class="border-t border-subtle"
                  >
                    <th scope="row" class="px-4 py-2.5 text-left font-normal text-strong">
                      {check.label}
                    </th>
                    <td data-label="Expected" class="px-4 py-2.5 tabular-nums">
                      {format_pathways_criteria_value(check.expected)}
                    </td>
                    <td data-label="Actual" class="px-4 py-2.5 tabular-nums">
                      {format_pathways_criteria_value(check.actual)}
                    </td>
                    <td data-label="Status" class="px-4 py-2.5">
                      <span class={[
                        "inline-flex items-center gap-1.5 font-semibold",
                        pathways_criteria_status_class(check.status)
                      ]}>
                        <.icon name={pathways_criteria_status_icon(check.status)} class="size-4" />
                        {pathways_criteria_status_label(check.status)}
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
        <div id={"pathways-case-itinerary-#{@index}"} class="min-w-0">
          <h3
            id={"pathways-case-itinerary-heading-#{@index}"}
            class="text-[13px] font-bold text-strong"
          >
            Walking directions
            <span class="font-normal text-muted">
              · leaves {format_pathways_time(@row.itinerary_start_time)}, arrives {format_pathways_time(
                @row.itinerary_end_time
              )}
            </span>
          </h3>
          <%= if pathways_empty_itinerary?(@steps) do %>
            <p
              id={"pathways-case-itinerary-empty-#{@index}"}
              class="mt-2 rounded-card border border-subtle bg-canvas px-4 py-3 text-sm text-muted"
            >
              {pathways_empty_itinerary_text()}
            </p>
          <% else %>
            <div class="mt-2 overflow-hidden rounded-card border border-subtle">
              <table
                id={"pathways-case-itinerary-table-#{@index}"}
                class="vr-stack w-full border-collapse text-left text-sm"
              >
                <caption class="sr-only">Step-by-step walking directions</caption>
                <thead>
                  <tr class="bg-canvas text-[13px] font-semibold text-strong">
                    <th scope="col" class="px-4 py-2.5 text-left">Step</th>
                    <th scope="col" class="px-4 py-2.5 text-left">Mode</th>
                    <th scope="col" class="px-4 py-2.5 text-left">Street</th>
                    <th scope="col" class="px-4 py-2.5 text-left">Turn</th>
                    <th scope="col" class="px-4 py-2.5 text-left">Heading</th>
                    <th scope="col" class="px-4 py-2.5 text-right">Distance (m)</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={step <- @steps}
                    id={"pathways-case-itinerary-step-#{@index}-#{step.leg_index}-#{step.step_index}"}
                    class="border-t border-subtle"
                  >
                    <th scope="row" class="px-4 py-2.5 text-left font-normal tabular-nums">
                      {step.step_index + 1}
                    </th>
                    <td data-label="Mode" class="px-4 py-2.5">{step.mode}</td>
                    <td data-label="Street" class="px-4 py-2.5 text-strong">{step.street_name}</td>
                    <td data-label="Turn" class="px-4 py-2.5">{step.relative_direction}</td>
                    <td data-label="Heading" class="px-4 py-2.5">{step.absolute_direction}</td>
                    <td data-label="Distance (m)" class="px-4 py-2.5 tabular-nums sm:text-right">
                      {format_pathways_distance(step.distance_meters)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
    </details>
    """
  end

  attr :criteria_overview_rows, :list, default: []

  def pathways_criteria_comparison_section(assigns) do
    ~H"""
    <.result_section
      id="pathways-criteria-comparison-overview"
      title="How each check did"
      lede="Across every test that set an expectation."
    >
      <div>
        <table class="vr-stack w-full border-collapse text-sm">
          <thead>
            <tr class="text-[13px] font-semibold text-muted">
              <th scope="col" class="px-5 py-2.5 text-left">Check</th>
              <th scope="col" class="whitespace-nowrap px-3 py-2.5 text-right">Set up</th>
              <th scope="col" class="px-3 py-2.5 text-right">Checked</th>
              <th scope="col" class="px-3 py-2.5 text-right">Passed</th>
              <th scope="col" class="px-3 py-2.5 text-right">Failed</th>
              <th scope="col" class="whitespace-nowrap px-3 py-2.5 text-right">Not checked</th>
              <th scope="col" class="whitespace-nowrap px-5 py-2.5 text-right">Pass rate</th>
            </tr>
          </thead>
          <tbody class="tabular-nums">
            <tr :if={@criteria_overview_rows == []} id="pathways-criteria-comparison-empty">
              <td colspan="7" class="border-t border-subtle px-5 py-3 text-muted">
                No criteria checks available.
              </td>
            </tr>

            <tr
              :for={criterion <- @criteria_overview_rows}
              id={"pathways-criteria-comparison-row-#{pathways_criteria_overview_kind(criterion)}"}
              class="border-t border-subtle"
            >
              <th
                scope="row"
                id={"pathways-criteria-comparison-label-#{pathways_criteria_overview_kind(criterion)}"}
                class="px-5 py-2.5 text-left font-normal text-strong sm:whitespace-nowrap"
              >
                {Map.get(criterion, :label)}
              </th>
              <td
                id={
                  "pathways-criteria-comparison-configured-#{pathways_criteria_overview_kind(criterion)}"
                }
                data-label="Set up"
                class="px-3 py-2.5 sm:text-right"
              >
                {format_pathways_overview_count(Map.get(criterion, :configured_count, 0))}
              </td>
              <td
                id={
                  "pathways-criteria-comparison-evaluated-#{pathways_criteria_overview_kind(criterion)}"
                }
                data-label="Checked"
                class="px-3 py-2.5 sm:text-right"
              >
                {format_pathways_overview_count(Map.get(criterion, :evaluated_count, 0))}
              </td>
              <td
                id={"pathways-criteria-comparison-pass-#{pathways_criteria_overview_kind(criterion)}"}
                data-label="Passed"
                class="px-3 py-2.5 sm:text-right"
              >
                {format_pathways_overview_count(Map.get(criterion, :pass_count, 0))}
              </td>
              <td
                id={"pathways-criteria-comparison-fail-#{pathways_criteria_overview_kind(criterion)}"}
                data-label="Failed"
                class="px-3 py-2.5 sm:text-right"
              >
                {format_pathways_overview_count(Map.get(criterion, :fail_count, 0))}
              </td>
              <td
                id={
                  "pathways-criteria-comparison-not-evaluated-#{pathways_criteria_overview_kind(criterion)}"
                }
                data-label="Not checked"
                class="px-3 py-2.5 sm:text-right"
              >
                {format_pathways_overview_count(Map.get(criterion, :not_evaluated_count, 0))}
              </td>
              <td
                id={"pathways-criteria-comparison-pass-rate-#{pathways_criteria_overview_kind(criterion)}"}
                data-label="Pass rate"
                class="px-5 py-2.5 font-semibold text-strong sm:text-right"
              >
                {format_pathways_overview_percentage(Map.get(criterion, :pass_rate, 0.0))}%
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.result_section>
    """
  end

  attr :trip_overview, :map, default: %{}

  def pathways_trip_stats_section(assigns) do
    assigns =
      assigns
      |> assign(:duration, Map.get(assigns.trip_overview, :duration_seconds, %{}))
      |> assign(:distance, Map.get(assigns.trip_overview, :distance_meters, %{}))

    ~H"""
    <.result_section
      id="pathways-trip-visualization-stats"
      title="Walk time and distance"
      lede="Only tests that returned a route have a time and distance."
    >
      <div class="overflow-x-auto" id="pathways-trip-visualization-comparison">
        <table class="w-full border-collapse text-sm">
          <thead>
            <tr class="text-[13px] font-semibold text-muted">
              <th scope="col" class="px-5 py-2.5 text-left"><span class="sr-only">Measure</span></th>
              <th scope="col" class="px-3 py-2.5 text-right sm:px-5">Walk time</th>
              <th scope="col" class="px-3 py-2.5 text-right sm:px-5">Distance</th>
            </tr>
          </thead>
          <tbody class="tabular-nums">
            <tr class="border-t border-subtle">
              <th scope="row" class="px-5 py-2.5 text-left font-normal text-strong">
                Tests with a result
              </th>
              <td
                id="pathways-trip-overview-duration-available"
                class="px-3 py-2.5 text-right sm:px-5"
              >
                {format_pathways_overview_count(Map.get(@duration, :available_count, 0))}
              </td>
              <td
                id="pathways-trip-overview-distance-available"
                class="px-3 py-2.5 text-right sm:px-5"
              >
                {format_pathways_overview_count(Map.get(@distance, :available_count, 0))}
              </td>
            </tr>
            <tr class="border-t border-subtle">
              <th scope="row" class="px-5 py-2.5 text-left font-normal text-strong">
                Tests without one
              </th>
              <td
                id="pathways-trip-overview-duration-unavailable"
                class="px-3 py-2.5 text-right sm:px-5"
              >
                {format_pathways_overview_count(Map.get(@duration, :unavailable_count, 0))}
              </td>
              <td
                id="pathways-trip-overview-distance-unavailable"
                class="px-3 py-2.5 text-right sm:px-5"
              >
                {format_pathways_overview_count(Map.get(@distance, :unavailable_count, 0))}
              </td>
            </tr>
            <tr class="border-t border-subtle">
              <th scope="row" class="px-5 py-2.5 text-left font-normal text-strong">Coverage</th>
              <td
                id="pathways-trip-overview-duration-availability-rate"
                class="px-3 py-2.5 text-right sm:px-5"
              >
                {format_pathways_overview_percentage(Map.get(@duration, :availability_rate, 0.0))}%
              </td>
              <td
                id="pathways-trip-overview-distance-availability-rate"
                class="px-3 py-2.5 text-right sm:px-5"
              >
                {format_pathways_overview_percentage(Map.get(@distance, :availability_rate, 0.0))}%
              </td>
            </tr>
            <tr class="border-t border-subtle">
              <th scope="row" class="px-5 py-2.5 text-left font-normal text-strong">Shortest</th>
              <td id="pathways-trip-overview-duration-min" class="px-3 py-2.5 text-right sm:px-5">
                {format_pathways_seconds(Map.get(@duration, :min))}
              </td>
              <td id="pathways-trip-overview-distance-min" class="px-3 py-2.5 text-right sm:px-5">
                {format_pathways_meters(Map.get(@distance, :min))}
              </td>
            </tr>
            <tr class="border-t border-subtle">
              <th scope="row" class="px-5 py-2.5 text-left font-normal text-strong">Longest</th>
              <td id="pathways-trip-overview-duration-max" class="px-3 py-2.5 text-right sm:px-5">
                {format_pathways_seconds(Map.get(@duration, :max))}
              </td>
              <td id="pathways-trip-overview-distance-max" class="px-3 py-2.5 text-right sm:px-5">
                {format_pathways_meters(Map.get(@distance, :max))}
              </td>
            </tr>
            <tr class="border-t border-subtle">
              <th scope="row" class="px-5 py-2.5 text-left font-normal text-strong">Average</th>
              <td id="pathways-trip-overview-duration-average" class="px-3 py-2.5 text-right sm:px-5">
                {format_pathways_seconds(Map.get(@duration, :average))}
              </td>
              <td id="pathways-trip-overview-distance-average" class="px-3 py-2.5 text-right sm:px-5">
                {format_pathways_meters(Map.get(@distance, :average))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </.result_section>
    """
  end

  # Run facts shown under "Details about this check": a label, a value and
  # whether the value is an identifier that reads in the monospace face.
  attr :rows, :list, required: true

  defp run_facts(assigns) do
    ~H"""
    <dl class="grid grid-cols-[minmax(0,1fr)] gap-x-8 gap-y-2 text-sm sm:grid-cols-[10rem_minmax(0,1fr)]">
      <%= for {label, value, kind} <- @rows, value do %>
        <dt class="text-muted">{label}</dt>
        <dd class={["min-w-0 tabular-nums", kind == :id && "break-all font-mono text-[13px]"]}>
          {value}
        </dd>
      <% end %>
    </dl>
    """
  end

  # ── Presentation helpers ──

  # -- Feed quality helper ----------------------------------------------------

  # Only a supported completed MobilityData report has helper reads; every other
  # engine or state keeps the native report and no helper button.
  defp assign_feed_quality(socket) do
    run = socket.assigns.run

    if run.status == "completed" and run.run_type in ["mobility_data", "mobility_data_flex"] and
         not is_nil(run.result_json) do
      scope = feed_quality_scope(socket)

      case Evidence.findings(scope, %{run_id: run.id, limit: 3}) do
        {:ok, report} ->
          socket =
            socket
            |> assign(:feed_quality_available?, true)
            |> assign(:feed_quality_digest, report.digest)
            |> assign(:feed_quality_samples, inspect_samples(scope, run, report))
            |> assign(:feed_quality, feed_quality_summary(report, run))

          AgentPanel.set_context(socket, feed_quality_context(socket))

        {:error, _reason} ->
          unavailable_feed_quality(socket)
      end
    else
      unavailable_feed_quality(socket)
    end
  end

  defp unavailable_feed_quality(socket) do
    socket
    |> assign(:feed_quality_available?, false)
    |> assign(:feed_quality, nil)
    |> assign(:feed_quality_digest, nil)
    |> assign(:feed_quality_samples, [])
    |> AgentPanel.set_context(Scope.context({:version, socket.assigns.current_gtfs_version.id}))
  end

  # A group page carries totals only; `limits` says in words what those totals
  # leave out, and drops the page's own "more groups" disclosure, which is about
  # the three groups this host asked for and not about the report.
  defp feed_quality_summary(report, run) do
    %{
      total_instances: report.total_instances,
      retained_instances: report.retained_instances,
      completeness: report.completeness,
      unknown_total?: Enum.any?(report.exclusions, &(&1.reason == "groups_without_stored_total")),
      limits: Enum.flat_map(report.exclusions, &limit_sentence/1),
      validator_version: run.validator_version
    }
  end

  defp limit_sentence(%{reason: "sampled_instance_groups", count: count}),
    do: ["Groups with only a sample of their findings: #{count}."]

  defp limit_sentence(%{reason: "groups_without_stored_total", count: count}),
    do: ["Groups with no stored total: #{count}."]

  defp limit_sentence(%{reason: "unknown_severity_groups", count: count}),
    do: ["Groups with a severity other than error, warning or info: #{count}."]

  defp limit_sentence(_page_exclusion), do: []

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, noun), do: "#{count} #{noun}s"

  # At most three retained samples of the first group that kept any are offered
  # as native Inspect targets, each checked against the current records now: the
  # report's own disclosures stay in the page below, and a sample that names no
  # single current record is reported rather than offered.
  defp inspect_samples(scope, run, report) do
    with %{code: code, severity: severity} <-
           Enum.find(report.groups, &(&1.retained_instances > 0)),
         {:ok, page} <-
           Evidence.findings(scope, %{
             run_id: run.id,
             code: code,
             severity: severity,
             limit: 3
           }) do
      page.groups
      |> Enum.flat_map(& &1.instances)
      |> Enum.take(3)
      |> Enum.map(&inspect_sample(scope, run, &1))
    else
      _none -> []
    end
  end

  defp inspect_sample(scope, run, instance) do
    case Evidence.locate(scope, run.id, instance.ref) do
      {:ok, %{targets: [_ | _]}} ->
        %{ref: instance.ref, resolved?: true, reasons: []}

      {:ok, %{unresolved: unresolved}} ->
        %{ref: instance.ref, resolved?: false, reasons: Enum.map(unresolved, & &1.reason)}

      {:error, _reason} ->
        %{ref: instance.ref, resolved?: false, reasons: ["not_readable"]}
    end
  end

  # The host's own fingerprint of the section: run, report digest and the one
  # approved instance reference. No report JSON, path, log or actor travels.
  defp feed_quality_context(socket) do
    run = socket.assigns.run

    payload =
      %{
        "schema_version" => 1,
        "section" => "validation",
        "run_ref" => run.id,
        "report_digest" => socket.assigns.feed_quality_digest || "none"
      }
      |> put_requested_instance(socket.assigns.requested_instance_ref)

    case Scope.with_source_snapshot(
           Scope.context({:version, socket.assigns.current_gtfs_version.id}),
           %{kind: "feed_quality", payload: payload}
         ) do
      {:ok, context} -> context
      {:error, _reason} -> Scope.context({:version, socket.assigns.current_gtfs_version.id})
    end
  end

  defp put_requested_instance(payload, ref) when is_binary(ref),
    do: Map.put(payload, "requested_instance_ref", ref)

  defp put_requested_instance(payload, _ref), do: payload

  defp feed_quality_scope(socket) do
    user = socket.assigns.current_user

    %Scope{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "feed_quality",
      version_name: socket.assigns.current_gtfs_version.name,
      resource_context: socket.assigns.agent_context
    }
  end

  defp validator_label(nil), do: "unknown"
  defp validator_label(version), do: version

  defp short_digest(nil), do: "unknown"
  defp short_digest(digest) when byte_size(digest) >= 12, do: binary_part(digest, 0, 12) <> "…"
  defp short_digest(digest), do: digest

  # An unknown total is never a clean zero: with every total unknown the page
  # says so, and with some unknown the counted ones are a lower bound.
  defp findings_label(%{unknown_total?: false, total_instances: total}),
    do: count_label(total, "finding")

  defp findings_label(%{total_instances: 0}), do: "Total unknown"
  defp findings_label(%{total_instances: total}), do: "At least #{count_label(total, "finding")}"

  defp unmapped_label([]), do: "No retained sample to match to a current record."

  defp unmapped_label(samples) do
    unmapped = Enum.reject(samples, & &1.resolved?)

    case unmapped do
      [] ->
        "Every sampled finding names a current record."

      _some ->
        "#{length(unmapped)} of #{length(samples)} sampled findings name no current record: " <>
          (unmapped
           |> Enum.flat_map(& &1.reasons)
           |> Enum.uniq()
           |> Enum.map_join(", ", &reason_label/1)) <>
          "."
    end
  end

  defp reason_label("no_current_record"), do: "no such record in this version"
  defp reason_label("duplicate_current_records"), do: "several records share the key"
  defp reason_label("row_number_is_not_a_record"), do: "only a file row"
  defp reason_label("no_typed_destination_for_pathway"), do: "a pathway has no page here"
  defp reason_label("trip_route_not_current"), do: "the trip's route is not current"
  defp reason_label(_other), do: "not readable"

  defp validation_lede(%{run_type: "pathways_tests"}, version) do
    "Older results: whether riders could walk from each test address to a stop in #{version.name}."
  end

  defp validation_lede(%{run_type: "mobility_data_flex"}, version) do
    "Flex file: what the MobilityData GTFS validator found in #{version.name}."
  end

  defp validation_lede(_run, version) do
    "What the MobilityData GTFS validator found in #{version.name}."
  end

  defp run_meta(%{status: "completed", run_type: "pathways_tests"} = run) do
    join_meta([
      "Ran " <> run_time(run.completed_at || run.started_at),
      duration_text(run.duration_ms)
    ])
  end

  defp run_meta(%{status: "completed"} = run) do
    join_meta([
      "Checked " <> run_time(run.completed_at || run.started_at),
      duration_text(run.duration_ms)
    ])
  end

  defp run_meta(%{status: "failed"} = run) do
    "Stopped " <> run_time(run.completed_at || run.started_at)
  end

  defp run_meta(run), do: "Started " <> run_time(run.started_at)

  defp join_meta(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  defp duration_text(nil), do: nil
  defp duration_text(ms) when is_integer(ms) and ms < 1000, do: "Took under 1 s"
  defp duration_text(ms) when is_integer(ms), do: "Took " <> format_pathways_seconds(ms / 1000)
  defp duration_text(_ms), do: nil

  # Run times are stored in UTC; the agency time zone isn't applied here. A
  # run object built by hand may have no start instant, so the words for that
  # stay here rather than in the shared formatter.
  defp run_time(%DateTime{} = time) do
    DisplayClock.format_datetime(time)
  end

  defp run_time(_time), do: "at an unknown time"

  defp mobility_facts(run, version) do
    [
      {"Status", "Completed", :text},
      {"Checked with", "MobilityData GTFS validator", :text},
      {"Version", version.name, :text},
      {"Started", run_time(run.started_at), :text},
      {"Finished", run.completed_at && run_time(run.completed_at), :text},
      {"Run ID", run.id, :id}
    ]
  end

  defp walk_facts(run, version) do
    [
      {"Status", "Completed", :text},
      {"Checked with", "Walk tests (OpenTripPlanner, retired)", :text},
      {"Version", version.name, :text},
      {"Started", run_time(run.started_at), :text},
      {"Finished", run.completed_at && run_time(run.completed_at), :text},
      {"Run ID", run.id, :id}
    ]
  end

  # The headline counts the run's own numbers and claims no more than the
  # severity names do: problems are blocking issues, suggestions are potential
  # ones, notes are information.
  defp mobility_summary(run, notices) do
    cond do
      notices == [] ->
        %{
          tone: "success",
          badge: "No issues",
          title: "No validation issues found!",
          body: "Your GTFS data passed all checks."
        }

      run.errors_count > 0 ->
        %{
          tone: "error",
          badge: "Problems found",
          title: "#{Wording.count_noun(run.errors_count || 0, "problem", "problems")} to fix.",
          body: "Start with the problems. Suggestions and notes below matter less."
        }

      run.warnings_count > 0 ->
        %{
          tone: "warning",
          badge: "Suggestions only",
          title:
            "No problems. #{Wording.count_noun(run.warnings_count || 0, "suggestion", "suggestions")} to review.",
          body: "Suggestions are potential issues. Notes are for your information."
        }

      true ->
        %{
          tone: "info",
          badge: "Notes only",
          title: "No problems or suggestions.",
          body: "The notes below are for your information."
        }
    end
  end

  defp walk_summary(%{total_tests: 0}) do
    %{
      tone: "neutral",
      badge: "No walk tests",
      title: "This run has no walk test results.",
      body:
        "The run finished, but it didn't include any walk tests, so there is nothing to pass or fail."
    }
  end

  defp walk_summary(%{fail_count: failed, total_tests: total}) when failed > 0 do
    %{
      tone: "error",
      badge: "Some walk tests failed",
      title: "#{failed} of #{total} walk tests failed.",
      body: walk_summary_body()
    }
  end

  defp walk_summary(%{warning_count: warned, total_tests: total}) when warned > 0 do
    %{
      tone: "warning",
      badge: "Walk tests need review",
      title: "#{warned} of #{total} walk tests need review.",
      body: walk_summary_body()
    }
  end

  defp walk_summary(%{total_tests: total}) do
    %{
      tone: "success",
      badge: "Walk tests passed",
      title: "All #{total} walk tests passed.",
      body: walk_summary_body()
    }
  end

  defp walk_summary_body do
    "Each test checks that a rider can walk from an address to a stop, and that the walk takes about as long as expected."
  end

  defp walk_tone("pass"), do: "success"
  defp walk_tone("warning"), do: "warning"
  defp walk_tone(_failed), do: "error"

  defp walk_result_label("pass"), do: "Passed"
  defp walk_result_label("warning"), do: "Needs review"
  defp walk_result_label(_failed), do: "Failed"

  defp history_status("completed"), do: "Completed"
  defp history_status("failed"), do: "Didn't finish"
  defp history_status("running"), do: "Running"
  defp history_status("started"), do: "Starting"
  defp history_status(_pending), do: "Waiting"

  defp history_tone("completed"), do: "success"
  defp history_tone("failed"), do: "error"
  defp history_tone("running"), do: "info"
  defp history_tone(_other), do: "neutral"

  defp history_type("mobility_data"), do: "Validation"
  defp history_type("pathways_tests"), do: "Older walk tests"
  defp history_type("station_reachability"), do: "Station reachability"
  defp history_type(other), do: humanize_code(other)

  # Problems, suggestions and notes name validator severities, so a walk-test
  # run's history row shows its type and status without them.
  defp history_counts(%{status: "completed", run_type: type} = run)
       when type != "pathways_tests" do
    Enum.join(
      [
        Wording.count_noun(run.errors_count || 0, "problem", "problems"),
        Wording.count_noun(run.warnings_count || 0, "suggestion", "suggestions"),
        Wording.count_noun(run.infos_count || 0, "note", "notes")
      ],
      " · "
    )
  end

  defp history_counts(_run), do: nil

  # ── Findings ──

  defp notices(%{result_json: %{"notices" => notices}}) when is_list(notices), do: notices
  defp notices(_run), do: []

  defp severity_key(group) do
    case group["severity"] do
      severity when is_binary(severity) ->
        case String.downcase(severity) do
          key when key in ["error", "warning", "info"] -> key
          _other -> "other"
        end

      _other ->
        "other"
    end
  end

  # Only sections that have findings, biggest cleanup first inside each.
  defp finding_sections(notices) do
    by_key = Enum.group_by(notices, &severity_key/1)

    for section <- @finding_sections,
        findings = Map.get(by_key, section.key, []),
        findings != [] do
      Map.put(section, :findings, Enum.sort_by(findings, &notice_sort_key/1))
    end
  end

  defp notice_sort_key(group) do
    case get_total_notices(group) do
      total when is_integer(total) -> -total
      _other -> 0
    end
  end

  defp section_codes(notices, key) do
    notices
    |> finding_sections()
    |> Enum.find(&(&1.key == key))
    |> case do
      nil -> []
      section -> Enum.map(section.findings, & &1["code"])
    end
  end

  defp all_expanded?(codes, expanded_codes) do
    Enum.all?(codes, &MapSet.member?(expanded_codes, &1))
  end

  defp section_expanded?(section, expanded_codes) do
    section.findings |> Enum.map(& &1["code"]) |> all_expanded?(expanded_codes)
  end

  defp section_noun(%{key: "error"}), do: "problems"
  defp section_noun(%{key: "warning"}), do: "suggestions"
  defp section_noun(%{key: "info"}), do: "notes"
  defp section_noun(_section), do: "other findings"

  # Problems open by default: they are the work. The rest open on request.
  defp default_expanded_codes(%{status: "completed", run_type: type} = run)
       when type != "pathways_tests" do
    run |> notices() |> section_codes("error") |> MapSet.new()
  end

  defp default_expanded_codes(_run), do: MapSet.new()

  defp humanize_code(code) when is_binary(code) and code != "" do
    text = String.replace(code, "_", " ")
    String.upcase(String.first(text)) <> String.slice(text, 1..-1//1)
  end

  defp humanize_code(_code), do: "Unnamed finding"

  # A validator code becomes part of a DOM id, so anything outside the id
  # alphabet is replaced.
  defp dom_token(code) when is_binary(code), do: String.replace(code, ~r/[^A-Za-z0-9_-]/, "-")
  defp dom_token(_code), do: "unknown"

  defp get_sample_notices(notice_group) do
    notice_group
    |> Map.get("notices", [])
    |> List.first()
    |> case do
      nil -> []
      notice -> Map.get(notice, "sampleNotices", [])
    end
  end

  defp get_total_notices(notice_group) do
    notice_group
    |> Map.get("notices", [])
    |> List.first()
    |> case do
      nil -> 0
      notice -> Map.get(notice, "totalNotices", 0)
    end
  end

  defp extract_filename(notice_group) do
    notices = notice_group["notices"] || []
    sample_notices = List.first(notices)

    if sample_notices do
      sample_list = sample_notices["sampleNotices"] || []
      first_sample = List.first(sample_list)

      if first_sample && first_sample["filename"] do
        first_sample["filename"]
      else
        nil
      end
    else
      nil
    end
  end

  defp extract_sample_context(notice_group) do
    notices = notice_group["notices"] || []
    sample_notices = List.first(notices)

    if sample_notices do
      sample_list = sample_notices["sampleNotices"] || []

      # Extract up to 3 sample identifiers
      samples =
        sample_list
        |> Enum.take(3)
        |> Enum.map(fn sample ->
          cond do
            sample["stopId"] -> sample["stopId"]
            sample["routeId"] -> sample["routeId"]
            sample["stopName"] -> sample["stopName"]
            sample["fieldName"] -> sample["fieldName"]
            true -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      case samples do
        [] -> nil
        items -> Enum.join(items, ", ")
      end
    else
      nil
    end
  end

  defp format_pathways_overview_count(count) when is_integer(count), do: Wording.count(count)
  defp format_pathways_overview_count(_count), do: "0"

  defp format_pathways_overview_percentage(value) when is_number(value) do
    value
    |> normalize_pathways_numeric_value()
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_pathways_overview_percentage(_value), do: "0.0"

  defp pathways_criteria_overview_kind(criterion) when is_map(criterion) do
    criterion
    |> Map.get(:kind, Map.get(criterion, "kind", "criterion"))
    |> to_string()
  end

  defp pathways_criteria_overview_kind(_criterion), do: "criterion"

  defp pathways_case_display_status(row) do
    mismatch_map = pathways_mismatch_map(row.details_json)

    traversable_failed? =
      Map.has_key?(mismatch_map, "expected_traversable")

    other_criteria_failed? =
      mismatch_map
      |> Map.drop(["expected_traversable"])
      |> map_has_entries?()

    cond do
      row.failure_category == "query_failure" -> "failed"
      traversable_failed? -> "failed"
      other_criteria_failed? -> "warning"
      true -> "pass"
    end
  end

  defp pathways_case_issues(row) do
    case row.failure_category do
      "query_failure" -> [query_failure_issue(row.details_json)]
      "scoring_failure" -> scoring_failure_issue(row.details_json)
      _ -> ["All criteria passed"]
    end
  end

  defp query_failure_issue(details_json) when is_map(details_json) do
    reason = pathways_map_value(details_json, :reason)
    status = pathways_map_value(details_json, :status)

    case {reason, status} do
      {reason, status}
      when reason in ["non_2xx_response", :non_2xx_response] and is_integer(status) ->
        "Query failed: OTP returned HTTP #{status}"

      {reason, _status} when reason in ["timeout", :timeout] ->
        "Query failed: OTP request timed out"

      {nil, _status} ->
        "Query failed"

      {reason, _status} ->
        "Query failed: #{humanize_issue_token(reason)}"
    end
  end

  defp query_failure_issue(_details_json), do: "Query failed"

  defp scoring_failure_issue(details_json) when is_map(details_json) do
    details_json
    |> pathways_map_value(:mismatches)
    |> ensure_list()
    |> Enum.map(&mismatch_issue_reason/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> ["Criteria checks failed"]
      reasons -> reasons
    end
  end

  defp scoring_failure_issue(_details_json), do: ["Criteria checks failed"]

  defp mismatch_issue_reason(mismatch) do
    case mismatch_kind(mismatch) do
      "expected_traversable" -> "Traversability check failed"
      "expected_wheelchair_accessible" -> "Wheelchair accessibility check failed"
      "expected_min_duration_seconds" -> "Duration outside expected range"
      "expected_max_duration_seconds" -> "Duration outside expected range"
      "expected_min_distance_meters" -> "Distance outside expected range"
      "expected_max_distance_meters" -> "Distance outside expected range"
      nil -> nil
      kind -> "#{humanize_issue_token(kind)} failed"
    end
  end

  defp humanize_issue_token(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> humanize_issue_token()
  end

  defp humanize_issue_token(value) when is_binary(value) do
    value
    |> String.replace_prefix("expected_", "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp map_has_entries?(map) when is_map(map), do: map_size(map) > 0
  defp map_has_entries?(_map), do: false

  defp pathways_case_origin(row) do
    Values.presence(pathways_walkability_test_address(row)) || "-"
  end

  defp pathways_case_destination(row) do
    Values.presence(pathways_walkability_test_stop_id(row)) || "-"
  end

  defp pathways_walkability_test_address(%{walkability_test: walkability_test})
       when is_struct(walkability_test) do
    walkability_test.address
  end

  defp pathways_walkability_test_address(_row), do: nil

  defp pathways_walkability_test_stop_id(%{walkability_test: walkability_test})
       when is_struct(walkability_test) do
    walkability_test.stop_id
  end

  defp pathways_walkability_test_stop_id(_row), do: nil

  defp format_pathways_time(nil), do: "-"

  defp format_pathways_time(%DateTime{} = value) do
    value
    |> DateTime.add(-5 * 60 * 60, :second)
    |> Calendar.strftime("%Y-%m-%d %I:%M:%S %p")
  end

  defp format_pathways_time(_value), do: "-"

  defp pathways_itinerary_step_rows(itinerary_steps_json) when is_map(itinerary_steps_json) do
    itinerary_steps_json
    |> pathways_map_value(:legs)
    |> ensure_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {leg, leg_position} ->
      leg_index = normalize_index(pathways_map_value(leg, :index), leg_position)
      leg_mode = Values.presence(pathways_map_value(leg, :mode)) || "-"
      from_name = Values.presence(pathways_map_value(leg, :from_name)) || "-"
      to_name = Values.presence(pathways_map_value(leg, :to_name)) || "-"

      leg
      |> pathways_map_value(:steps)
      |> ensure_list()
      |> Enum.with_index()
      |> Enum.map(fn {step, step_position} ->
        %{
          leg_index: leg_index,
          step_index: normalize_index(pathways_map_value(step, :index), step_position),
          mode: leg_mode,
          street_name: Values.presence(pathways_map_value(step, :street_name)) || "-",
          relative_direction:
            Values.presence(pathways_map_value(step, :relative_direction)) || "-",
          absolute_direction:
            Values.presence(pathways_map_value(step, :absolute_direction)) || "-",
          distance_meters: normalize_distance(pathways_map_value(step, :distance_meters)),
          from_name: from_name,
          to_name: to_name
        }
      end)
    end)
  end

  defp pathways_itinerary_step_rows(_itinerary_steps_json), do: []

  defp pathways_map_value(map, key) when is_map(map) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp pathways_map_value(_map, _key), do: nil

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_value), do: []

  defp normalize_index(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp normalize_index(_value, fallback), do: fallback

  defp normalize_distance(value) when is_float(value), do: value
  defp normalize_distance(value) when is_integer(value), do: value * 1.0
  defp normalize_distance(_value), do: nil

  defp format_pathways_distance(nil), do: "-"

  defp format_pathways_distance(value) when is_float(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_pathways_distance(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pathways_distance(_value), do: "-"

  defp format_pathways_meters(value) do
    case format_pathways_distance(value) do
      "-" -> "-"
      text -> text <> " m"
    end
  end

  defp format_pathways_seconds(value) when is_number(value) do
    total = round(value)

    case {div(total, 60), rem(total, 60)} do
      {0, seconds} -> "#{seconds} s"
      {minutes, seconds} -> "#{minutes} min #{seconds} s"
    end
  end

  defp format_pathways_seconds(_value), do: "-"

  defp pathways_criteria_checks(row) do
    mismatch_map = pathways_mismatch_map(row.details_json)

    [
      criteria_check(
        row,
        mismatch_map,
        :expected_traversable,
        "Can be walked",
        pathways_expected_value(row, :expected_traversable),
        row.route_exists
      ),
      duration_range_check(row, mismatch_map),
      distance_range_check(row, mismatch_map),
      criteria_check(
        row,
        mismatch_map,
        :expected_wheelchair_accessible,
        "Wheelchair accessible",
        pathways_expected_value(row, :expected_wheelchair_accessible),
        row.wheelchair_route_exists
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp pathways_case_criteria_checks(pathways_case_results) when is_list(pathways_case_results) do
    Enum.reduce(pathways_case_results, %{}, fn row, acc ->
      Map.put(acc, row.order_index, pathways_criteria_checks(row))
    end)
  end

  defp pathways_case_criteria_checks(_pathways_case_results), do: %{}

  defp pathways_criteria_overview(pathways_case_results) when is_list(pathways_case_results) do
    normalized_case_criteria = pathways_normalized_case_criteria(pathways_case_results)

    Enum.map(@pathways_criteria_overview_definitions, fn %{kind: kind, label: label} ->
      criteria_entries =
        Enum.map(normalized_case_criteria, fn per_case_criteria ->
          Map.get(per_case_criteria, kind, %{configured: false, status: :not_configured})
        end)

      configured_count = Enum.count(criteria_entries, & &1.configured)
      evaluated_count = Enum.count(criteria_entries, &pathways_evaluated_criterion?/1)
      pass_count = Enum.count(criteria_entries, &pathways_criterion_with_status?(&1, :pass))
      fail_count = Enum.count(criteria_entries, &pathways_criterion_with_status?(&1, :fail))

      not_evaluated_count =
        Enum.count(criteria_entries, &pathways_criterion_with_status?(&1, :not_evaluated))

      %{
        kind: kind,
        label: label,
        configured_count: configured_count,
        evaluated_count: evaluated_count,
        pass_count: pass_count,
        fail_count: fail_count,
        not_evaluated_count: not_evaluated_count,
        pass_rate: percentage(pass_count, evaluated_count)
      }
    end)
  end

  defp pathways_criteria_overview(_pathways_case_results), do: []

  defp pathways_normalized_case_criteria(pathways_case_results) do
    Enum.map(pathways_case_results, fn row ->
      row
      |> pathways_criteria_checks()
      |> Enum.reduce(%{}, fn check, acc ->
        Map.put(acc, check.kind, %{
          configured: true,
          status: check.status,
          expected: check.expected,
          actual: check.actual
        })
      end)
    end)
  end

  defp pathways_evaluated_criterion?(%{configured: true, status: status})
       when status in [:pass, :fail],
       do: true

  defp pathways_evaluated_criterion?(_criterion), do: false

  defp pathways_criterion_with_status?(%{configured: true, status: status}, status_to_match),
    do: status == status_to_match

  defp pathways_criterion_with_status?(_criterion, _status_to_match), do: false

  defp pathways_trip_overview(pathways_case_results) when is_list(pathways_case_results) do
    status_totals =
      Enum.reduce(pathways_case_results, %{pass: 0, warning: 0, failed: 0}, fn row, acc ->
        increment_pathways_trip_status(acc, pathways_case_display_status(row))
      end)

    total_tests = length(pathways_case_results)

    %{
      total_tests: total_tests,
      pass_count: status_totals.pass,
      warning_count: status_totals.warning,
      fail_count: status_totals.failed,
      duration_seconds:
        pathways_numeric_availability_stats(pathways_case_results, :duration_seconds),
      distance_meters:
        pathways_numeric_availability_stats(pathways_case_results, :distance_meters)
    }
  end

  defp pathways_trip_overview(_pathways_case_results) do
    %{
      total_tests: 0,
      pass_count: 0,
      warning_count: 0,
      fail_count: 0,
      duration_seconds: pathways_empty_numeric_availability_stats(),
      distance_meters: pathways_empty_numeric_availability_stats()
    }
  end

  defp increment_pathways_trip_status(acc, "pass"), do: Map.update!(acc, :pass, &(&1 + 1))
  defp increment_pathways_trip_status(acc, "warning"), do: Map.update!(acc, :warning, &(&1 + 1))
  defp increment_pathways_trip_status(acc, "failed"), do: Map.update!(acc, :failed, &(&1 + 1))
  defp increment_pathways_trip_status(acc, _status), do: acc

  defp pathways_numeric_availability_stats(pathways_case_results, field) do
    values =
      pathways_case_results
      |> Enum.map(&Map.get(&1, field))
      |> Enum.filter(&is_number/1)
      |> Enum.map(&normalize_pathways_numeric_value/1)

    total_count = length(pathways_case_results)
    available_count = length(values)
    unavailable_count = total_count - available_count

    summary =
      case values do
        [] ->
          pathways_empty_numeric_availability_stats()

        _ ->
          %{
            available_count: available_count,
            unavailable_count: unavailable_count,
            availability_rate: percentage(available_count, total_count),
            min: values |> Enum.min() |> Float.round(1),
            max: values |> Enum.max() |> Float.round(1),
            average: values |> Enum.sum() |> Kernel./(available_count) |> Float.round(1)
          }
      end

    summary
  end

  defp pathways_empty_numeric_availability_stats do
    %{
      available_count: 0,
      unavailable_count: 0,
      availability_rate: 0.0,
      min: nil,
      max: nil,
      average: nil
    }
  end

  defp normalize_pathways_numeric_value(value) when is_float(value), do: value
  defp normalize_pathways_numeric_value(value) when is_integer(value), do: value * 1.0

  defp percentage(_value, 0), do: 0.0

  defp percentage(value, total) do
    value
    |> Kernel.*(100)
    |> Kernel./(total)
    |> Float.round(1)
  end

  defp criteria_check(_row, _mismatch_map, _kind, _label, nil, _actual), do: nil

  defp criteria_check(row, mismatch_map, kind, label, expected, default_actual) do
    mismatch = Map.get(mismatch_map, Atom.to_string(kind))

    case {row.failure_category, mismatch} do
      {"query_failure", _} ->
        %{
          kind: Atom.to_string(kind),
          label: label,
          expected: expected,
          actual: default_actual,
          status: :not_evaluated
        }

      {_, nil} ->
        %{
          kind: Atom.to_string(kind),
          label: label,
          expected: expected,
          actual: default_actual,
          status: :pass
        }

      {_, mismatch} ->
        %{
          kind: Atom.to_string(kind),
          label: label,
          expected: pathways_map_value(mismatch, :expected),
          actual: pathways_map_value(mismatch, :actual),
          status: :fail
        }
    end
  end

  defp pathways_expected_value(%{walkability_test: walkability_test}, field)
       when is_struct(walkability_test) do
    Map.get(walkability_test, field)
  end

  defp pathways_expected_value(_row, _field), do: nil

  defp duration_range_check(row, mismatch_map) do
    min_duration = pathways_expected_value(row, :expected_min_duration_seconds)
    max_duration = pathways_expected_value(row, :expected_max_duration_seconds)

    if is_integer(min_duration) or is_integer(max_duration) do
      min_mismatch = Map.get(mismatch_map, "expected_min_duration_seconds")
      max_mismatch = Map.get(mismatch_map, "expected_max_duration_seconds")

      status = duration_range_status(row, min_mismatch, max_mismatch)

      %{
        kind: "duration_seconds_range",
        label: "Walk time (s)",
        expected: duration_range_expected_value(min_duration, max_duration),
        actual: duration_range_actual_value(row.duration_seconds, min_mismatch, max_mismatch),
        status: status
      }
    else
      nil
    end
  end

  defp duration_range_status(%{failure_category: "query_failure"}, _min_mismatch, _max_mismatch),
    do: :not_evaluated

  defp duration_range_status(_row, nil, nil), do: :pass
  defp duration_range_status(_row, _min_mismatch, _max_mismatch), do: :fail

  defp duration_range_expected_value(min_duration, max_duration)
       when is_integer(min_duration) and is_integer(max_duration) do
    "#{min_duration} - #{max_duration}"
  end

  defp duration_range_expected_value(min_duration, _max_duration) when is_integer(min_duration),
    do: ">= #{min_duration}"

  defp duration_range_expected_value(_min_duration, max_duration) when is_integer(max_duration),
    do: "<= #{max_duration}"

  defp duration_range_actual_value(default_actual, nil, nil), do: default_actual

  defp duration_range_actual_value(default_actual, min_mismatch, max_mismatch) do
    min_actual = mismatch_actual_value(min_mismatch)
    max_actual = mismatch_actual_value(max_mismatch)
    min_actual || max_actual || default_actual
  end

  defp mismatch_actual_value(nil), do: nil

  defp mismatch_actual_value(mismatch) when is_map(mismatch) do
    pathways_map_value(mismatch, :actual)
  end

  defp mismatch_actual_value(_mismatch), do: nil

  defp distance_range_check(row, mismatch_map) do
    min_distance = pathways_expected_value(row, :expected_min_distance_meters)
    max_distance = pathways_expected_value(row, :expected_max_distance_meters)

    if is_integer(min_distance) or is_integer(max_distance) do
      min_mismatch = Map.get(mismatch_map, "expected_min_distance_meters")
      max_mismatch = Map.get(mismatch_map, "expected_max_distance_meters")

      status = distance_range_status(row, min_mismatch, max_mismatch)

      %{
        kind: "distance_meters_range",
        label: "Distance (m)",
        expected: distance_range_expected_value(min_distance, max_distance),
        actual: distance_range_actual_value(row.distance_meters, min_mismatch, max_mismatch),
        status: status
      }
    else
      nil
    end
  end

  defp distance_range_status(%{failure_category: "query_failure"}, _min_mismatch, _max_mismatch),
    do: :not_evaluated

  defp distance_range_status(_row, nil, nil), do: :pass
  defp distance_range_status(_row, _min_mismatch, _max_mismatch), do: :fail

  defp distance_range_expected_value(min_distance, max_distance)
       when is_integer(min_distance) and is_integer(max_distance) do
    "#{min_distance} - #{max_distance}"
  end

  defp distance_range_expected_value(min_distance, _max_distance) when is_integer(min_distance),
    do: ">= #{min_distance}"

  defp distance_range_expected_value(_min_distance, max_distance) when is_integer(max_distance),
    do: "<= #{max_distance}"

  defp distance_range_actual_value(default_actual, nil, nil), do: default_actual

  defp distance_range_actual_value(default_actual, min_mismatch, max_mismatch) do
    min_actual = mismatch_actual_value(min_mismatch)
    max_actual = mismatch_actual_value(max_mismatch)
    min_actual || max_actual || default_actual
  end

  defp pathways_mismatch_map(details_json) when is_map(details_json) do
    details_json
    |> pathways_map_value(:mismatches)
    |> ensure_list()
    |> Enum.reduce(%{}, fn mismatch, acc ->
      case mismatch_kind(mismatch) do
        nil -> acc
        kind -> Map.put(acc, kind, mismatch)
      end
    end)
  end

  defp pathways_mismatch_map(_details_json), do: %{}

  defp mismatch_kind(mismatch) when is_map(mismatch) do
    case pathways_map_value(mismatch, :kind) do
      kind when is_atom(kind) -> Atom.to_string(kind)
      kind when is_binary(kind) -> kind
      _ -> nil
    end
  end

  defp mismatch_kind(_mismatch), do: nil

  defp format_pathways_criteria_value(nil), do: "-"
  defp format_pathways_criteria_value(value) when is_binary(value), do: value
  defp format_pathways_criteria_value(true), do: "Yes"
  defp format_pathways_criteria_value(false), do: "No"
  defp format_pathways_criteria_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_pathways_criteria_value(value) when is_float(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_pathways_criteria_value(value), do: inspect(value)

  defp pathways_criteria_status_label(:pass), do: "Passed"
  defp pathways_criteria_status_label(:fail), do: "Failed"
  defp pathways_criteria_status_label(:not_evaluated), do: "Not checked"

  defp pathways_criteria_status_icon(:pass), do: "hero-check-circle"
  defp pathways_criteria_status_icon(:fail), do: "hero-x-circle"
  defp pathways_criteria_status_icon(:not_evaluated), do: "hero-minus-circle"

  defp pathways_criteria_status_class(:pass), do: "text-success-fg"
  defp pathways_criteria_status_class(:fail), do: "text-error-fg"
  defp pathways_criteria_status_class(:not_evaluated), do: "text-muted"

  defp pathways_empty_itinerary?(rows) when is_list(rows), do: rows == []
  defp pathways_empty_itinerary?(_rows), do: true

  defp pathways_empty_itinerary_text, do: "No itinerary steps available."

  defp failure_summary(run), do: run.error_details

  defp pathways_failure_diagnostics(%{
         run_type: "pathways_tests",
         status: "failed",
         error_details: error_details
       })
       when is_binary(error_details) do
    case Jason.decode(error_details) do
      {:ok, payload} when is_map(payload) ->
        build_log_excerpt = pathways_failure_build_log_excerpt(payload)

        [
          presenter_detail("Exit status", pathways_failure_exit_status(payload)),
          presenter_detail("Build log path", pathways_failure_build_log_path(payload)),
          presenter_detail("Build log excerpt", build_log_excerpt),
          presenter_detail(
            "Likely GTFS source",
            pathways_failure_build_log_gtfs_source(build_log_excerpt)
          ),
          presenter_detail(
            "Likely cause",
            pathways_failure_npe_parent_station_hint(build_log_excerpt)
          )
        ]
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp pathways_failure_diagnostics(_run), do: []

  defp pathways_failure(%{
         run_type: "pathways_tests",
         status: "failed",
         error_details: error_details
       })
       when is_binary(error_details) do
    case Jason.decode(error_details) do
      {:ok, payload} when is_map(payload) ->
        %{
          title: "The walk tests didn't finish.",
          summary: Map.get(payload, "message", failure_summary(%{error_details: error_details})),
          checks: [],
          details: [],
          blocking_issues: []
        }

      _other ->
        nil
    end
  end

  defp pathways_failure(_run), do: nil

  defp pathways_failure_message(%{
         run_type: "pathways_tests",
         status: "failed",
         error_details: error_details
       })
       when is_binary(error_details) do
    case Jason.decode(error_details) do
      {:ok, payload} when is_map(payload) ->
        payload
        |> pathways_failure_tokens()
        |> Enum.find_value(&normalize_pathways_failure_code/1)
        |> case do
          nil -> failure_summary(%{error_details: error_details, run_type: "pathways_tests"})
          code -> Map.get(@pathways_failure_messages, code, "The walk tests didn't finish.")
        end

      _other ->
        error_details
    end
  end

  defp pathways_failure_message(run), do: failure_summary(run)

  defp pathways_failure_tokens(error_payload) do
    reason = payload_value(error_payload, :reason)

    details_reason =
      error_payload
      |> payload_value(:details)
      |> payload_value(:reason)

    issue_codes =
      error_payload
      |> payload_value(:issues)
      |> case do
        issues when is_list(issues) -> Enum.map(issues, &payload_value(&1, :code))
        _other -> []
      end

    [reason, details_reason | issue_codes]
  end

  defp normalize_pathways_failure_code(:no_walkability_tests), do: :no_walkability_tests
  defp normalize_pathways_failure_code(:query_failure), do: :query_failure
  defp normalize_pathways_failure_code(:scoring_failure), do: :scoring_failure

  defp normalize_pathways_failure_code(:pathways_runner_spawn_failed),
    do: :pathways_runner_spawn_failed

  defp normalize_pathways_failure_code(:pathways_persistence_failed),
    do: :pathways_persistence_failed

  defp normalize_pathways_failure_code(:pathways_export_prep_failed),
    do: :pathways_export_prep_failed

  defp normalize_pathways_failure_code(:pathways_task_crashed), do: :pathways_task_crashed

  defp normalize_pathways_failure_code(:pathways_status_unavailable),
    do: :pathways_status_unavailable

  defp normalize_pathways_failure_code(:pathways_run_not_found), do: :pathways_run_not_found
  defp normalize_pathways_failure_code(:pathways_invalid_run_type), do: :pathways_invalid_run_type

  defp normalize_pathways_failure_code(:pathways_results_unavailable),
    do: :pathways_results_unavailable

  defp normalize_pathways_failure_code(value) when is_binary(value) do
    Map.get(@pathways_failure_codes, value)
  end

  defp normalize_pathways_failure_code(_value), do: nil

  defp pathways_failure_exit_status(payload) do
    case pathways_build_failure_reason_code(payload) do
      :build_command_failed ->
        payload
        |> pathways_build_failure_details()
        |> payload_value(:exit_status)
        |> case do
          nil ->
            payload
            |> payload_value(:details)
            |> payload_value(:exit_status)

          exit_status ->
            exit_status
        end

      _other ->
        nil
    end
  end

  defp pathways_failure_build_log_path(payload) do
    case pathways_build_failure_reason_code(payload) do
      :build_command_failed ->
        payload
        |> pathways_build_failure_details()
        |> payload_value(:build_log_path)
        |> case do
          nil ->
            payload
            |> payload_value(:details)
            |> payload_value(:build_log_path)

          build_log_path ->
            build_log_path
        end

      _other ->
        nil
    end
  end

  defp pathways_failure_build_log_excerpt(payload) do
    case pathways_failure_build_log_path(payload) do
      nil ->
        nil

      build_log_path ->
        extract_build_log_excerpt(build_log_path)
    end
  end

  defp pathways_failure_build_log_gtfs_source(nil), do: nil

  defp pathways_failure_build_log_gtfs_source(build_log_excerpt)
       when is_binary(build_log_excerpt) do
    case extract_gtfs_txt_filename(build_log_excerpt) do
      nil -> nil
      filename -> "Issue appears to come from #{filename}."
    end
  end

  defp pathways_failure_build_log_gtfs_source(_build_log_excerpt), do: nil

  defp pathways_failure_npe_parent_station_hint(nil), do: nil

  defp pathways_failure_npe_parent_station_hint(build_log_excerpt)
       when is_binary(build_log_excerpt) do
    if String.contains?(build_log_excerpt, "NullPointerException") do
      "NullPointerException often indicates a child stop is missing a valid parent_station assignment."
    else
      nil
    end
  end

  defp pathways_failure_npe_parent_station_hint(_build_log_excerpt), do: nil

  defp extract_gtfs_txt_filename(text) when is_binary(text) do
    case Regex.run(~r/\b([A-Za-z0-9_.-]+\.txt)\b/i, text, capture: :all_but_first) do
      [filename] -> filename
      _ -> nil
    end
  end

  defp extract_gtfs_txt_filename(_text), do: nil

  defp pathways_build_failure_reason_code(payload) do
    issue_reason_code =
      payload
      |> pathways_build_failure_details()
      |> payload_value(:reason_code)

    root_reason_code =
      payload
      |> payload_value(:details)
      |> payload_value(:reason_code)

    case issue_reason_code || root_reason_code do
      :build_command_failed -> :build_command_failed
      "build_command_failed" -> :build_command_failed
      _other -> nil
    end
  end

  defp pathways_build_failure_details(payload) do
    payload
    |> payload_value(:issues)
    |> case do
      issues when is_list(issues) ->
        Enum.find_value(issues, fn issue ->
          details = payload_value(issue, :details)

          case payload_value(details, :reason_code) do
            :build_command_failed -> details
            "build_command_failed" -> details
            _other -> nil
          end
        end)

      _other ->
        nil
    end
  end

  defp extract_build_log_excerpt(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> build_log_excerpt_from_body()

      {:error, _reason} ->
        nil
    end
  end

  defp extract_build_log_excerpt(_path), do: nil

  defp build_log_excerpt_from_body(body) when is_binary(body) do
    lines =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)

    highlighted =
      Enum.filter(lines, fn line ->
        String.contains?(line, "ERROR") or
          String.contains?(line, "Exception") or
          String.contains?(line, "Caused by")
      end)

    excerpt_lines =
      case highlighted do
        [] ->
          lines
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(-8)

        _ ->
          highlighted
          |> Enum.take(8)
      end

    case excerpt_lines do
      [] -> nil
      _lines -> Enum.join(excerpt_lines, "\n")
    end
  end

  defp presenter_detail(_label, nil), do: nil
  defp presenter_detail(_label, ""), do: nil

  defp presenter_detail(label, value) do
    %{label: label, value: presenter_detail_value(value)}
  end

  defp presenter_detail_value(value) when is_binary(value), do: value
  defp presenter_detail_value(value) when is_atom(value), do: Atom.to_string(value)
  defp presenter_detail_value(value) when is_integer(value), do: Integer.to_string(value)
  defp presenter_detail_value(value), do: inspect(value)

  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp payload_value(_payload, _key), do: nil

  defp load_pathways_render_data(%{run_type: "pathways_tests", status: "completed"} = run) do
    {run, Validations.Legacy.list_run_results(run.id)}
  end

  defp load_pathways_render_data(run), do: {run, []}
end
