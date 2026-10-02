defmodule GtfsPlannerWeb.Gtfs.ExportDefaultsLive do
  @moduledoc """
  Settings › Export defaults: the organization-wide settings an export reads.

  Two settings live here, and both come from the reference's export line: whether
  a full export also writes the flex file, and which file the agency's realtime
  vendor reads. They apply to every version of the organization, so the version
  in the URL is navigation context and a version switch keeps this page, as
  Garages and Fleet do.

  The page saves once. A keystroke re-reads the switch's consequence, the note
  for the chosen realtime answer, and the missing-times consequence from the
  draft, and Save writes all four settings through `ExportDefaults.update/3`,
  whose changeset casts the four settings only — a submitted organization ID
  is ignored rather than written. The Flex list reads the same row for its
  export-state line, so the two surfaces cannot disagree about whether exports
  carry flex.

  The impact block below the form counts the URL version's trips with missing
  times through `Export.MissingTimes.summary/2`, loaded asynchronously so a
  large version never blocks the form. The export defaults the catalog still
  promises — ID formats — are named in a note at the foot of the page instead
  of being offered as controls that cannot work yet.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1, form_section: 1, scope_line: 1]

  alias GtfsPlanner.Gtfs.Export.MissingTimes
  alias GtfsPlanner.Gtfs.ExportDefault
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Gtfs.FlexComponents
  alias GtfsPlannerWeb.Layouts
  alias Phoenix.LiveView.AsyncResult

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @permission_error "You no longer have permission to edit export defaults. " <>
                      "Ask an organization administrator to restore your access."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Export defaults")
     |> assign(:defaults, nil)
     |> assign(:form, nil)
     |> assign(:include_flex, true)
     |> assign(:realtime_note, nil)
     |> assign(:estimate_missing_times, true)
     |> assign(:estimate_method, :distance)
     |> assign(:missing_consequence, nil)
     |> assign(:missing_summary, AsyncResult.loading())}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    defaults = ExportDefaults.get(socket.assigns.current_organization.id)

    {:noreply,
     socket
     |> assign(:defaults, defaults)
     |> assign_form(ExportDefault.changeset(defaults, %{}))
     |> load_missing_summary()}
  end

  @impl true
  def handle_event("validate", %{"export_default" => params}, socket) do
    changeset = ExportDefault.changeset(socket.assigns.defaults, params)

    {:noreply, assign_form(socket, changeset, :validate)}
  end

  @impl true
  def handle_event("save", %{"export_default" => params}, socket) do
    case ExportDefaults.update(
           socket.assigns.current_organization.id,
           socket.assigns.current_user,
           params
         ) do
      {:ok, defaults} ->
        {:noreply,
         socket
         |> assign(:defaults, defaults)
         |> assign_form(ExportDefault.changeset(defaults, %{}))
         |> load_missing_summary()
         |> put_flash(:info, "Export defaults saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        # The select and the switch carry one value each, so a rejected save is a
        # forged or stale request; the draft stays visible with its error.
        {:noreply,
         socket
         |> assign_form(changeset, :insert)
         |> put_flash(:error, "Nothing was saved. Check the highlighted field.")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign_form(ExportDefault.changeset(socket.assigns.defaults, params))
         |> put_flash(:error, @permission_error)}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry_missing_summary", _params, socket) do
    {:noreply, load_missing_summary(socket)}
  end

  # A version switch keeps this page, because the settings here apply to every
  # version; only another published version of this organization navigates.
  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: section_path(version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: section_path(version_id))}
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
      <div id="export-defaults-page" class="ds-page">
        <.back_link id="settings-back" navigate={settings_path(@current_gtfs_version.id)}>
          Settings
        </.back_link>

        <.header>
          Export defaults
          <:subtitle>
            All versions · Choose how future exports are written.
            <.scope_line id="export-defaults-scope" icon="hero-square-3-stack-3d">
              Shared across all service versions for {@current_organization.name}.
            </.scope_line>
          </:subtitle>
        </.header>

        <.form
          for={@form}
          id="export-defaults-form"
          novalidate
          phx-change="validate"
          phx-submit="save"
          class="mt-6 max-w-2xl overflow-hidden rounded-card border border-subtle bg-white"
        >
          <div class="grid gap-6 p-5 sm:p-6">
            <.form_section title="Flex services" first?>
              <div>
                <.input
                  field={@form[:include_flex]}
                  type="checkbox"
                  id="flex-switch"
                  label="Include flex services in exports"
                />

                <p id="flex-switch-consequence" class="mt-1 text-[13px] text-muted">
                  {switch_consequence(@include_flex)}
                </p>
              </div>
            </.form_section>

            <.form_section title="Realtime">
              <%!-- The question is the reference's own wording and wraps on a narrow
              screen: `input/1`'s own label renders in daisyUI's `label` span, which
              does not wrap, so the label is written here instead. --%>
              <div>
                <label for="realtime-source" class="block text-[13px] font-[650] text-strong">
                  Which file does your realtime vendor read?
                </label>

                <div class="mt-1.5 max-w-xs">
                  <.input
                    field={@form[:realtime_source]}
                    type="select"
                    id="realtime-source"
                    options={FlexComponents.realtime_options()}
                  />
                </div>
              </div>

              <FlexComponents.realtime_note_card :if={@realtime_note} note={@realtime_note} />

              <p class="text-[13px] text-muted">
                One answer for your agency. Every version uses it, and it applies to every route.
              </p>
            </.form_section>

            <div id="export-defaults-missing-times">
              <.form_section title="Missing stop times">
                <p class="text-[13px] text-muted">
                  Some trips have times only at their timepoints, often because they came from
                  an imported feed. This decides what riders’ apps get for the stops in between.
                </p>

                <fieldset>
                  <legend class="text-[13px] font-[650] text-strong">In exported files</legend>
                  <div class="mt-1.5 grid gap-2">
                    <label
                      for="estimate-missing-times-estimate"
                      class="flex min-h-11 cursor-pointer items-start gap-3 rounded-control border border-subtle px-3 py-2 has-[:checked]:border-action has-[:checked]:bg-selection has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
                    >
                      <input
                        type="radio"
                        id="estimate-missing-times-estimate"
                        name={@form[:estimate_missing_times].name}
                        value="true"
                        checked={@estimate_missing_times == true}
                        class="mt-1 size-4 shrink-0 accent-action"
                      />
                      <span class="min-w-0">
                        <span class="block text-sm font-[650] text-strong">
                          Estimate missing times
                          <span class="font-normal text-muted">(recommended)</span>
                        </span>
                        <span class="mt-0.5 block text-[13px] text-muted">
                          Riders’ apps get a time at every stop. Estimated times are marked as
                          approximate, and times you entered stay as they are.
                        </span>
                      </span>
                    </label>
                    <label
                      for="estimate-missing-times-blank"
                      class="flex min-h-11 cursor-pointer items-start gap-3 rounded-control border border-subtle px-3 py-2 has-[:checked]:border-action has-[:checked]:bg-selection has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
                    >
                      <input
                        type="radio"
                        id="estimate-missing-times-blank"
                        name={@form[:estimate_missing_times].name}
                        value="false"
                        checked={@estimate_missing_times == false}
                        class="mt-1 size-4 shrink-0 accent-action"
                      />
                      <span class="min-w-0">
                        <span class="block text-sm font-[650] text-strong">Leave them blank</span>
                        <span class="mt-0.5 block text-[13px] text-muted">
                          Each app fills the gaps its own way. Google Maps shows the time of the
                          stop before, so a 13-minute ride can look like 17.
                        </span>
                      </span>
                    </label>
                  </div>
                </fieldset>

                <fieldset>
                  <legend class="text-[13px] font-[650] text-strong">
                    Share the time between timed stops by
                  </legend>
                  <div class="mt-1.5 grid gap-2">
                    <label
                      for="estimate-method-distance"
                      class="flex min-h-11 cursor-pointer items-start gap-3 rounded-control border border-subtle px-3 py-2 has-[:checked]:border-action has-[:checked]:bg-selection has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
                    >
                      <input
                        type="radio"
                        id="estimate-method-distance"
                        name={@form[:estimate_method].name}
                        value="distance"
                        checked={@estimate_method == :distance}
                        class="mt-1 size-4 shrink-0 accent-action"
                      />
                      <span class="min-w-0">
                        <span class="block text-sm font-[650] text-strong">
                          Distance along the path
                          <span class="font-normal text-muted">(recommended)</span>
                        </span>
                        <span class="mt-0.5 block text-[13px] text-muted">
                          Stops farther apart get more of the time. A section with no path uses the
                          straight line between its stops.
                        </span>
                      </span>
                    </label>
                    <label
                      for="estimate-method-even"
                      class="flex min-h-11 cursor-pointer items-start gap-3 rounded-control border border-subtle px-3 py-2 has-[:checked]:border-action has-[:checked]:bg-selection has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
                    >
                      <input
                        type="radio"
                        id="estimate-method-even"
                        name={@form[:estimate_method].name}
                        value="even"
                        checked={@estimate_method == :even}
                        class="mt-1 size-4 shrink-0 accent-action"
                      />
                      <span class="min-w-0">
                        <span class="block text-sm font-[650] text-strong">Equal time per stop</span>
                        <span class="mt-0.5 block text-[13px] text-muted">
                          Every stop gets the same share, whatever the distance. Use it only if many
                          paths are missing or wrong.
                        </span>
                      </span>
                    </label>
                  </div>
                </fieldset>

                <p class="text-[13px] text-muted">
                  Also used by Fill times between timepoints in each pattern’s Running times.
                </p>

                <div
                  :if={@missing_consequence}
                  id="missing-times-consequence"
                  role="status"
                  class={[
                    "rounded-control border px-4 py-3 text-sm",
                    @missing_consequence.tone == :warning &&
                      "border-warning-line bg-warning-bg text-warning-fg",
                    @missing_consequence.tone == :info && "border-subtle bg-soft text-cyan-800"
                  ]}
                >
                  {@missing_consequence.text}
                </div>
              </.form_section>
            </div>
          </div>

          <div class="flex flex-wrap items-center justify-end gap-3 border-t border-subtle px-5 py-4 sm:px-6">
            <.button type="submit" class="min-h-11" phx-disable-with="Saving…">
              Save changes
            </.button>
          </div>
        </.form>

        <section
          id="export-defaults-impact"
          aria-label="Missing stop times in this version"
          class="mt-6 max-w-2xl overflow-hidden rounded-card border border-subtle bg-white"
        >
          <div class="border-b border-subtle bg-canvas px-5 py-4">
            <h2 class="text-base font-bold text-strong">In {@current_gtfs_version.name}</h2>
            <p class="mt-1 text-[13px] text-muted">
              What the next export does with this version’s trips.
            </p>
          </div>
          <div class="px-5 py-5">
            <%= cond do %>
              <% @missing_summary.loading -> %>
                <div id="missing-impact-loading" aria-busy="true">
                  <div class="grid gap-3 sm:grid-cols-3">
                    <div class="h-[76px] rounded-card bg-navy-100/60 motion-safe:animate-pulse"></div>
                    <div class="h-[76px] rounded-card bg-navy-100/60 motion-safe:animate-pulse"></div>
                    <div class="h-[76px] rounded-card bg-navy-100/60 motion-safe:animate-pulse"></div>
                  </div>
                  <p class="mt-3 text-[13px] text-muted">Counting trips with missing times…</p>
                </div>
              <% @missing_summary.failed -> %>
                <div id="missing-impact-error">
                  <p class="text-sm text-strong">Couldn’t count missing times.</p>
                  <p class="mt-1 text-[13px] text-muted">
                    Your settings are still here. Check your connection and try counting again.
                  </p>
                  <.button
                    id="missing-impact-retry"
                    type="button"
                    class="mt-3 min-h-11"
                    phx-click="retry_missing_summary"
                  >
                    Retry
                  </.button>
                </div>
              <% summary = @missing_summary.result -> %>
                <%= if summary.trips == 0 do %>
                  <p id="missing-impact-empty" class="flex items-start gap-2 text-sm text-default">
                    <.icon name="hero-check-circle" class="mt-0.5 size-5 shrink-0 text-cyan-700" />
                    <span>
                      <strong class="font-bold">Every trip has a time at every stop.</strong>
                      Nothing needs estimating in {@current_gtfs_version.name}. This setting applies
                      if an import or a new trip leaves gaps.
                    </span>
                  </p>
                <% else %>
                  <div class="grid gap-3 sm:grid-cols-3">
                    <.impact_metric label="Trips with missing times" value={summary.trips} />
                    <.impact_metric label="Missing times" value={summary.missing_times} />
                    <.impact_metric
                      label="Can’t be estimated"
                      value={length(summary.not_estimable)}
                      tone={:warning}
                    />
                  </div>
                  <p class="mt-3 text-sm text-default">{impact_sentence(@defaults, summary)}</p>
                  <div class="mt-4 overflow-x-auto">
                    <table id="missing-impact-routes" class="w-full border-collapse text-left text-sm">
                      <caption class="sr-only">Trips with missing times, by route</caption>
                      <thead>
                        <tr class="border-b border-subtle text-[13px] text-muted">
                          <th scope="col" class="py-2 pr-3 font-[650]">Route</th>
                          <th scope="col" class="px-2 py-2 text-right font-[650]">Trips</th>
                          <th scope="col" class="px-2 py-2 text-right font-[650]">Missing</th>
                          <th scope="col" class="py-2 pl-3 font-[650]">Estimated by</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr
                          :for={route <- summary.routes}
                          class="border-b border-subtle align-top last:border-b-0"
                        >
                          <th scope="row" class="py-3 pr-3 font-normal">
                            <.link
                              navigate={
                                ~p"/gtfs/#{@current_gtfs_version.id}/routes/#{route.route_id}/schedules"
                              }
                              class="font-semibold"
                            >
                              {route_label(route)}
                            </.link>
                          </th>
                          <td class="px-2 py-3 text-right tabular-nums">{route.trips}</td>
                          <td class="px-2 py-3 text-right tabular-nums">{route.missing_times}</td>
                          <td class="py-3 pl-3">
                            {estimate_badge(route, @defaults.estimate_method)}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                  <div :if={summary.not_estimable != []} class="mt-6">
                    <h3 class="flex items-center gap-2 text-sm font-bold text-strong">
                      <.icon name="hero-exclamation-triangle" class="size-4 text-warning-fg" />
                      Can’t be estimated · {length(summary.not_estimable)}
                    </h3>
                    <p class="mt-1 text-[13px] text-default">
                      These are exported as they are, and the feed check reports them. Fix them in
                      the route’s schedule.
                    </p>
                    <ul
                      id="missing-impact-unestimable"
                      class="mt-3 divide-y divide-subtle rounded-card border border-subtle"
                    >
                      <li
                        :for={trip <- Enum.take(summary.not_estimable, 20)}
                        class="flex items-start gap-3 px-4 py-3"
                      >
                        <div class="min-w-0 flex-1">
                          <p class="text-sm font-semibold text-strong">Trip {trip.trip_id}</p>
                          <p class="mt-0.5 text-[13px] text-default">
                            {not_estimable_reason(trip.reason)}{not_estimable_context(trip)}
                          </p>
                        </div>
                        <.link
                          :if={trip.route_id}
                          navigate={
                            ~p"/gtfs/#{@current_gtfs_version.id}/routes/#{trip.route_id}/schedules"
                          }
                          class="inline-flex min-h-11 shrink-0 items-center text-sm font-[650]"
                        >
                          Open schedule
                        </.link>
                      </li>
                    </ul>
                  </div>
                <% end %>
            <% end %>
          </div>
        </section>

        <p id="export-defaults-more" class="mt-4 max-w-2xl text-[13px] text-muted">
          More export defaults are coming. ID formats will join this page.
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"

  # The switch's consequence in the reference's words: what a full export writes
  # with flex on, and what riders lose with it off.
  defp switch_consequence(true) do
    "Exports also write a flex file: your fixed routes plus flex, built and published with your main feed. Apps that show flex load it instead of the main feed, which stays as it is for Google Maps."
  end

  defp switch_consequence(false) do
    "Exports leave flex out. Riders won’t see these services in trip planners until flex is turned on."
  end

  # The form, the switch's consequence, the realtime note and the
  # missing-times consequence always move together, so a keystroke cannot show
  # a control whose explanation describes another value. All are read from the
  # cast changeset rather than the form's own field values, which hold the
  # submitted strings during a validate round trip. `action: :validate` marks
  # the round trip as a keystroke, so an error appears only beside a touched
  # field.
  defp assign_form(socket, %Ecto.Changeset{} = changeset, action \\ nil) do
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset

    socket
    |> assign(:form, to_form(changeset, as: :export_default))
    |> assign(:include_flex, Ecto.Changeset.get_field(changeset, :include_flex))
    |> assign(
      :realtime_note,
      FlexComponents.realtime_note(Ecto.Changeset.get_field(changeset, :realtime_source), nil)
    )
    |> assign(
      :estimate_missing_times,
      Ecto.Changeset.get_field(changeset, :estimate_missing_times)
    )
    |> assign(:estimate_method, Ecto.Changeset.get_field(changeset, :estimate_method))
    |> assign(
      :missing_consequence,
      missing_consequence(changeset, socket.assigns.defaults, socket.assigns.missing_summary)
    )
  end

  # The version's missing-times count loads apart from the form, so a large
  # version never blocks saving; a retry restarts the same read.
  defp load_missing_summary(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    assign_async(socket, :missing_summary, fn ->
      {:ok, %{missing_summary: MissingTimes.summary(organization_id, version_id)}}
    end)
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :neutral, values: [:neutral, :warning]

  defp impact_metric(assigns) do
    ~H"""
    <div class={[
      "min-w-0 rounded-card border px-4 py-3",
      @tone == :warning && "border-warning-line bg-warning-bg",
      @tone != :warning && "border-subtle bg-white"
    ]}>
      <p class={[
        "text-[13px]",
        @tone == :warning && "text-warning-fg",
        @tone != :warning && "text-muted"
      ]}>
        {@label}
      </p>
      <p class={[
        "mt-0.5 font-display text-[28px] font-semibold leading-none tabular-nums",
        @tone == :warning && "text-warning-fg",
        @tone != :warning && "text-strong"
      ]}>
        {@value}
      </p>
    </div>
    """
  end

  # What the next export does with this version under the saved settings: the
  # draft's own delta lives in the consequence line above Save instead.
  defp impact_sentence(%{estimate_missing_times: true} = _defaults, summary) do
    estimable = summary.trips - length(summary.not_estimable)

    "The next export estimates #{summary.estimable_times} times on #{Wording.count_noun(estimable, "trip")} " <>
      "across #{Wording.count_noun(length(summary.routes), "route")}. " <>
      cant_sentence(summary)
  end

  defp impact_sentence(%{estimate_missing_times: false} = _defaults, summary) do
    "The next export leaves #{summary.missing_times} times blank on " <>
      "#{Wording.count_noun(summary.trips, "trip")}. " <> cant_sentence(summary)
  end

  defp cant_sentence(%{not_estimable: []}), do: "Every trip with gaps can be estimated."

  defp cant_sentence(%{not_estimable: cant}) do
    count = length(cant)

    "#{count} #{if(count == 1, do: "trip", else: "trips")} can't be estimated and " <>
      "#{if(count == 1, do: "is", else: "are")} exported as #{if(count == 1, do: "it is", else: "they are")}."
  end

  defp route_label(%{route_short_name: short, route_long_name: long, route_id: id}) do
    [short, long]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> id
      names -> Enum.join(names, " · ")
    end
  end

  defp estimate_badge(%{straight_line?: true}, _method), do: "Straight line, no path"
  defp estimate_badge(_route, :even), do: "Equal time per stop"
  defp estimate_badge(_route, _method), do: "By distance"

  defp not_estimable_reason(:no_first_time), do: "The first stop has no time."
  defp not_estimable_reason(:no_last_time), do: "The last stop has no time."

  defp not_estimable_reason(:timepoint_without_time),
    do: "A timepoint has no time, so no gap in this trip is filled."

  defp not_estimable_reason(:order), do: "Times run backwards between two timed stops."

  defp not_estimable_context(%{service_id: service, first_departure: departure}) do
    [service, departure]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> ""
      parts -> " #{Enum.join(parts, " · ")}."
    end
  end

  # The draft's delta from what is saved, in the version's own counts once the
  # impact block has loaded; nothing renders when the draft matches the saved
  # row, so Save and the consequence never disagree.
  defp missing_consequence(changeset, saved, async_summary) do
    draft_estimate = Ecto.Changeset.get_field(changeset, :estimate_missing_times)
    draft_method = Ecto.Changeset.get_field(changeset, :estimate_method)

    if draft_estimate == saved.estimate_missing_times and draft_method == saved.estimate_method do
      nil
    else
      summary = if async_summary.ok?, do: async_summary.result, else: nil
      build_consequence(draft_estimate, draft_method, saved, summary)
    end
  end

  defp build_consequence(true, _method, _saved, nil) do
    %{tone: :info, text: "The next export estimates missing times, marked as approximate."}
  end

  defp build_consequence(false, _method, _saved, nil) do
    %{
      tone: :warning,
      text:
        "The next export leaves missing times blank. Riders’ apps will each fill them their own way."
    }
  end

  # Only the method changed while estimating: the same trips are estimated,
  # but their times move.
  defp build_consequence(
         true,
         _method,
         %{estimate_missing_times: true},
         %{estimable_trips: estimable}
       )
       when is_integer(estimable) do
    %{
      tone: :info,
      text:
        "Estimated times on #{Wording.count_noun(estimable, "trip")} will change in the next export. " <>
          "Times saved in trips and patterns don’t change."
    }
  end

  defp build_consequence(true, _method, _saved, summary) do
    estimable = summary.trips - length(summary.not_estimable)

    %{
      tone: :info,
      text:
        "The next export estimates #{summary.estimable_times} times on " <>
          "#{Wording.count_noun(estimable, "trip")}. Nothing saved in trips changes." <>
          cant_suffix(summary)
    }
  end

  defp build_consequence(false, _method, _saved, summary) do
    %{
      tone: :warning,
      text:
        "The next export leaves #{summary.missing_times} times blank on " <>
          "#{Wording.count_noun(summary.trips, "trip")}. Riders’ apps will each fill them their own way."
    }
  end

  defp cant_suffix(%{not_estimable: []}), do: ""

  defp cant_suffix(%{not_estimable: cant}) do
    count = length(cant)
    " #{count} #{if(count == 1, do: "trip", else: "trips")} can't be estimated."
  end

  defp section_path(version_id), do: "/gtfs/#{version_id}/settings/export-defaults"
end
