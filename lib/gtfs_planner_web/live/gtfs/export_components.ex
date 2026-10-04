defmodule GtfsPlannerWeb.Gtfs.ExportComponents do
  @moduledoc """
  The Export page's presentation, on the application design system.

  One card walks the task in order: choose what to export (`type_options/1`),
  see what goes in the file (`contents/1`), then act on the latest file
  (`run_status/1`). The status band is the only place the page changes state and
  holds the page's one primary action, so which control is primary follows the
  latest run: Export feed, Download file, Retry export, Export again, or, when a
  garage ID clashes with a stop ID, Edit garages. `comparison/1` is the second
  region's card: two retained files, one explicit date range, its own single
  primary action, and a status band naming the comparison's state. `guide/1`
  says what to do with the
  file, and the right column holds the feed check (`check_panel/1`) and its
  history (`recent_checks/1`).

  The components carry no state and run no queries: `ExportLive` owns the events
  and the data, and passes the latest `Export.Run`, the file inventory and the
  check's state in.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.Gtfs.FeedPublicationComponents, only: [publish_action: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.ResultComponents, only: [result_section: 1, tone_badge: 1]

  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.ProductSurfaces

  @conflict_code "garage_stop_id_conflict"
  @warnings_shown 3

  @type_options [
    full: %{
      label: "Full feed",
      description: "Routes, stops, trips, calendars and fares. The file trip planners use.",
      format: "GTFS"
    },
    pathways: %{
      label: "Station pathways only",
      description: "Stops, levels and pathways. Not a complete feed on its own.",
      format: "GTFS pathways files"
    },
    operations: %{
      label: "Feed with operations data",
      description: "Full feed plus garages and vehicles, for CAD/AVL vendors. Keep it private.",
      format: "GTFS + operations (TODS)"
    }
  ]

  @doc """
  The export type, as one radio group of whole-card targets named for who the
  file is for. The technical name is the muted last line. The operations option
  is left out for organizations whose product hides it.

  The form's `phx-change` patches the URL, which owns the selected type.
  """
  attr :form, :any, required: true
  attr :export_type, :atom, required: true, values: [:full, :pathways, :operations]
  attr :operations?, :boolean, required: true

  def type_options(assigns) do
    assigns =
      assign(
        assigns,
        :options,
        Enum.filter(@type_options, fn {type, _option} ->
          type != :operations or assigns.operations?
        end)
      )

    ~H"""
    <.form for={@form} id="gtfs-export-form" phx-change="select_export_type" class="px-5 pt-5">
      <fieldset>
        <legend class="text-[13px] font-semibold text-strong">What are you exporting?</legend>
        <div class={[
          "mt-2.5 grid gap-3",
          if(@operations?, do: "sm:grid-cols-3", else: "sm:grid-cols-2")
        ]}>
          <label
            :for={{type, option} <- @options}
            class={[
              "relative flex cursor-pointer gap-3 rounded-card border border-control bg-white px-4 py-3.5 hover:bg-canvas",
              "has-[:checked]:border-action has-[:checked]:bg-selection",
              "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
            ]}
          >
            <input
              type="radio"
              id={"export-type-#{type}"}
              name={@form[:type].name}
              value={type}
              checked={@export_type == type}
              class="mt-0.5 size-[18px] shrink-0 accent-action focus-visible:outline-0"
            />
            <span class="min-w-0">
              <span class="block text-sm font-bold text-strong">{option.label}</span>
              <span class="mt-1 block text-[13px] leading-relaxed text-default">
                {option.description}
              </span>
              <span class="mt-1.5 block text-[13px] text-muted">{option.format}</span>
            </span>
          </label>
        </div>
      </fieldset>
    </.form>
    """
  end

  @doc """
  What the operations export adds to the full feed, and why it does not depend on
  the version. The counts are the organization's garages and vehicles.
  """
  attr :file_inventory, :list, required: true

  def operations_note(assigns) do
    counts = Map.new(assigns.file_inventory)

    assigns =
      assigns
      |> assign(:garages, Wording.count(Map.get(counts, "stops_supplement.txt", 0)))
      |> assign(:vehicles, Wording.count(Map.get(counts, "vehicles.txt", 0)))

    ~H"""
    <div class="px-5 pt-4">
      <.message
        id="operations-export-note"
        kind="info"
        title={"Garages (#{@garages}) and vehicles (#{@vehicles}) belong to the whole organization, not to one version."}
      >
        Vehicle types and garage assignments stay in this app; the file lists garages and vehicles only.
      </.message>
    </div>
    """
  end

  @doc """
  Says that a Pathways export leaves out the version's scheduled closures.

  Only the Pathways profile can omit closures, so only that selection carries it.
  Choose Full export switches the type and moves focus to the Full option.
  """
  attr :count, :integer, required: true

  def closures_omitted(assigns) do
    ~H"""
    <div class="px-5 pt-4">
      <.message
        id="export-pathways-closures-omitted"
        kind="info"
        title={"Pathways export leaves out #{@count} #{if @count == 1, do: "scheduled closure", else: "scheduled closures"}"}
      >
        Choose Full export to include closures and their calendars.
        <:action>
          <.button
            id="export-choose-full"
            variant="secondary"
            class="min-h-11"
            phx-click={
              JS.push("select_export_type", value: %{"export" => %{"type" => "full"}})
              |> JS.focus(to: "#export-type-full")
            }
          >
            Choose Full export
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  The consequence of exporting, shown before the button: a count for each thing
  trip planners read, then every file with its record count.

  A table with no records is left out of the ZIP, so its row says so instead of
  listing a file that will not exist.
  """
  attr :export_type, :atom, required: true
  attr :file_inventory, :list, required: true
  attr :missing_summary, :any, default: nil
  attr :defaults, :map, default: nil
  attr :version_id, :any, default: nil

  def contents(assigns) do
    counts = Map.new(assigns.file_inventory)
    included = Enum.count(assigns.file_inventory, fn {_file, count} -> count > 0 end)
    left_out = length(assigns.file_inventory) - included

    tile_counts =
      for {label, file} <- tiles(assigns.export_type), do: {label, Map.get(counts, file, 0)}

    assigns =
      assigns
      |> assign(:tiles, tile_counts)
      |> assign(:included, included)
      |> assign(:left_out, left_out)

    ~H"""
    <div id="export-contents" class="px-5 pb-5 pt-5">
      <h3 class="text-[13px] font-semibold text-strong">
        What goes in this file
        <span class="font-normal text-muted">· Tables with no records are left out.</span>
      </h3>

      <dl id="export-metrics" class={["mt-2.5 grid grid-cols-2 gap-3", tile_columns(length(@tiles))]}>
        <div :for={{label, count} <- @tiles} class="rounded-control border border-subtle px-4 py-2">
          <dt class="text-[13px] text-muted">{label}</dt>
          <dd class={[
            "mt-0.5 font-display text-[26px] font-semibold leading-none tracking-[-0.03em] tabular-nums",
            if(count > 0, do: "text-strong", else: "text-muted")
          ]}>
            {Wording.count(count)}
          </dd>
        </div>
      </dl>

      <div class="mt-3">
        <%= case @missing_summary do %>
          <% %{loading: true} -> %>
            <p
              id="export-missing-times-loading"
              class="rounded-card border border-subtle bg-canvas px-4 py-3 text-sm text-muted"
            >
              Counting missing stop times…
            </p>
          <% %{ok?: true, result: summary} -> %>
            <.missing_times_line
              :if={not is_nil(@defaults)}
              summary={summary}
              defaults={@defaults}
              version_id={@version_id}
            />
          <% _ -> %>
        <% end %>
      </div>

      <details
        id="export-files"
        phx-mounted={JS.ignore_attributes("open")}
        class="group mt-3 rounded-control border border-subtle"
      >
        <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 rounded-control px-4 text-sm font-semibold text-strong hover:bg-canvas [&::-webkit-details-marker]:hidden">
          <span>
            See every file
            <span class="font-normal text-muted">
              · {@included} included<span :if={@left_out > 0}>, {@left_out} left out</span>
            </span>
          </span>
          <.icon
            name="hero-chevron-down"
            class="size-4 shrink-0 text-muted transition-transform group-open:rotate-180 motion-reduce:transition-none"
          />
        </summary>

        <div
          id="export-inventory"
          tabindex="0"
          role="region"
          aria-label="Files in this export"
          class="max-h-[400px] overflow-auto border-t border-subtle"
        >
          <table :if={@file_inventory != []} class="w-full border-collapse text-left text-sm">
            <thead>
              <tr>
                <th
                  scope="col"
                  class="sticky top-0 border-b border-subtle bg-canvas px-4 py-2.5 text-[13px] font-[650] text-default"
                >
                  File
                </th>
                <th
                  scope="col"
                  class="sticky top-0 border-b border-subtle bg-canvas px-4 py-2.5 text-right text-[13px] font-[650] text-default"
                >
                  Records
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{filename, count} <- @file_inventory}
                class="border-b border-subtle last:border-0"
              >
                <th
                  scope="row"
                  class={[
                    "px-4 py-2.5 font-mono text-[13px] font-normal",
                    if(count > 0, do: "text-strong", else: "text-muted")
                  ]}
                >
                  {filename}
                  <span
                    :if={filename == "pathway_evolutions.txt"}
                    class="mt-0.5 block font-ds text-[13px] text-muted"
                  >
                    Scheduled closures · extension, not core GTFS
                  </span>
                </th>
                <td class={[
                  "px-4 py-2.5 text-right tabular-nums",
                  if(count > 0, do: "text-strong", else: "text-muted")
                ]}>
                  {Wording.count(count)}<span :if={count == 0} class="ml-2 text-[13px]">left out</span>
                </td>
              </tr>
            </tbody>
          </table>
          <p
            :if={@file_inventory == []}
            id="export-empty-inventory"
            class="px-4 py-3 text-sm text-muted"
          >
            This export type has no GTFS tables to package yet.
          </p>
        </div>

        <p class="border-t border-subtle px-4 py-3 text-[13px] leading-relaxed text-muted">
          Diagram, level and image data is added to the ZIP as extra files when it exists, and isn’t listed here.
        </p>
      </details>
    </div>
    """
  end

  attr :summary, :map, required: true
  attr :defaults, :map, required: true
  attr :version_id, :any, required: true

  # How the next export treats missing stop times under the current
  # defaults, with the counts `MissingTimes.summary/2` computed for this
  # version. Pathways Studio organizations see the same line: the settings
  # still describe what a full export of their data would do.
  defp missing_times_line(%{defaults: %{estimate_missing_times: true}} = assigns) do
    ~H"""
    <div
      id="export-missing-times"
      class="flex flex-wrap items-start gap-x-3 gap-y-1 rounded-card border border-cyan-200 bg-cyan-50 px-4 py-3 text-sm text-cyan-900"
    >
      <.icon name="hero-clock" class="mt-0.5 size-4 shrink-0" />
      <div class="min-w-0 flex-1">
        <p>
          <strong>Missing stop times: estimated.</strong>
          {estimate_sentence(@summary, @defaults)}
        </p>
      </div>
      <.link
        id="export-missing-times-link"
        navigate={~p"/gtfs/#{@version_id}/settings/export-defaults"}
        class="inline-flex min-h-11 items-center self-center text-sm font-[650] hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      >
        Export defaults
      </.link>
    </div>
    """
  end

  defp missing_times_line(assigns) do
    ~H"""
    <div
      id="export-missing-times"
      role="status"
      class="flex flex-wrap items-start gap-x-3 gap-y-1 rounded-card bg-warning-bg px-4 py-3 text-sm text-warning-fg"
    >
      <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
      <div class="min-w-0 flex-1">
        <p>
          <strong>Missing stop times: left blank.</strong>
          {blank_sentence(@summary)}
        </p>
      </div>
      <.link
        id="export-missing-times-link"
        navigate={~p"/gtfs/#{@version_id}/settings/export-defaults"}
        class="inline-flex min-h-11 items-center self-center text-sm font-[650] underline hover:no-underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      >
        Change in Export defaults
      </.link>
    </div>
    """
  end

  defp estimate_sentence(%{trips: 0}, _defaults),
    do: "Every trip has a time at every stop."

  # Every gapped trip is unfillable, so there is no estimate to count;
  # lead with that instead of "0 times on 0 trips".
  defp estimate_sentence(%{not_estimable: cant} = summary, _defaults)
       when length(cant) == summary.trips do
    "No missing times can be estimated. " <> cant_sentence(summary)
  end

  defp estimate_sentence(summary, defaults) do
    estimable = summary.trips - length(summary.not_estimable)

    "#{summary.estimable_times} #{if(summary.estimable_times == 1, do: "time", else: "times")} " <>
      "on #{Wording.count_noun(estimable, "trip")}, by #{estimate_method_label(defaults.estimate_method)}, " <>
      "marked as approximate. #{cant_sentence(summary)}"
  end

  defp blank_sentence(%{trips: 0}),
    do: "Every trip has a time at every stop."

  defp blank_sentence(summary) do
    "#{summary.missing_times} #{if(summary.missing_times == 1, do: "time", else: "times")} " <>
      "on #{Wording.count_noun(summary.trips, "trip")} go out blank, " <>
      "so each rider app will guess them its own way."
  end

  defp cant_sentence(%{not_estimable: []}), do: "Every trip with gaps can be estimated."

  defp cant_sentence(%{not_estimable: cant}) do
    count = length(cant)

    "#{count} #{if(count == 1, do: "trip", else: "trips")} can't be estimated and " <>
      "#{if(count == 1, do: "goes", else: "go")} out as #{if(count == 1, do: "it is", else: "they are")}."
  end

  defp estimate_method_label(:even), do: "equal time per stop"
  defp estimate_method_label(_method), do: "distance along the path"

  defp tiles(:full),
    do: [
      {"Routes", "routes.txt"},
      {"Trips", "trips.txt"},
      {"Stops", "stops.txt"},
      {"Service calendars", "calendar.txt"}
    ]

  defp tiles(:pathways),
    do: [
      {"Stops and stations", "stops.txt"},
      {"Levels", "levels.txt"},
      {"Pathways", "pathways.txt"}
    ]

  defp tiles(:operations),
    do: [
      {"Routes", "routes.txt"},
      {"Trips", "trips.txt"},
      {"Stops", "stops.txt"},
      {"Garages", "stops_supplement.txt"},
      {"Vehicles", "vehicles.txt"}
    ]

  defp tile_columns(3), do: "sm:grid-cols-3"
  defp tile_columns(4), do: "sm:grid-cols-4"
  defp tile_columns(5), do: "sm:grid-cols-5"

  @doc """
  The latest export of this type, and what to do next.

  `run` is the latest `Export.Run` for the selected type, or `nil` before the
  first export. `notice` is a failed action's message (start, cancel or retry),
  shown in the band beside the control that failed. The band is a polite live
  region and its title takes focus when an action starts, so a keyboard reader
  hears the new state and lands next to it.
  """
  attr :run, :any, default: nil
  attr :export_type, :atom, required: true
  attr :version, :map, required: true
  attr :notice, :string, default: nil
  attr :defaults, :map, default: nil

  # Publication is one more thing the operator may do with a ready file, so its
  # opener sits in the same action row as Download. `publish?` is the server's
  # answer, never the page's: an installation without publishing, or an
  # operations file, passes false and the row is exactly what it was.
  attr :publish?, :boolean, default: false

  def run_status(assigns) do
    view = status(assigns.run, assigns.export_type, assigns.version)
    warnings = if assigns.run, do: assigns.run.warnings || [], else: []

    {conflicts, others} =
      if conflict?(assigns.run),
        do: Enum.split_with(warnings, &(warning_code(&1) == @conflict_code)),
        else: {[], Enum.reject(warnings, &(warning_code(&1) == @conflict_code))}

    assigns =
      assigns
      |> assign(:view, view)
      |> assign(:conflicts, conflicts)
      |> assign(:others, others)

    ~H"""
    <div
      id="export-run-status"
      aria-live="polite"
      class="border-t border-subtle bg-canvas px-5 py-4"
    >
      <div :if={@notice} class="mb-5">
        <.message id="export-notice" kind="error" title={@notice} />
      </div>

      <div :if={stale_missing_times?(@run, @defaults)} class="mb-5">
        <.message
          id="export-stale-settings"
          kind="info"
          title="Export defaults changed after this file was made."
        >
          {stale_detail(@run, @defaults)}
        </.message>
      </div>

      <div class="flex flex-wrap items-start justify-between gap-x-8 gap-y-4">
        <div
          id={if is_nil(@run), do: "export-empty-history"}
          class="flex min-w-0 flex-1 basis-[300px] gap-3.5"
        >
          <span class={[
            "flex size-10 shrink-0 items-center justify-center rounded-full",
            tone_class(@view.tone)
          ]}>
            <.icon
              name={@view.icon}
              class={["size-5", @view[:spin?] && "motion-safe:animate-spin"]}
            />
          </span>
          <div class="min-w-0">
            <h3
              id="export-run-title"
              tabindex="-1"
              class="text-base font-bold leading-snug text-strong focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-focus"
            >
              {@view.title}
            </h3>
            <p class="mt-1 max-w-[64ch] text-sm leading-relaxed text-default">{@view.detail}</p>
            <p :if={@view[:note]} class="mt-1 text-[13px] font-semibold text-strong">
              {@view.note}
            </p>
            <p :if={@view[:meta]} class="mt-1.5 text-[13px] tabular-nums text-muted">
              {@view.meta}
            </p>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2 max-sm:w-full max-sm:[&>*]:flex-1">
          <.run_action
            :for={action <- @view.actions}
            action={action}
            run={@run}
            version={@version}
          />
          <.publish_action :if={@publish?} />
        </div>
      </div>

      <details
        :if={@run && @run.state == :ready}
        id="export-file-details"
        phx-mounted={JS.ignore_attributes("open")}
        class="group mt-5 rounded-control border border-subtle"
      >
        <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 rounded-control px-4 text-sm font-semibold text-strong hover:bg-canvas [&::-webkit-details-marker]:hidden">
          <span>File details</span>
          <.icon
            name="hero-chevron-down"
            class="size-4 shrink-0 text-muted transition-transform group-open:rotate-180 motion-reduce:transition-none"
          />
        </summary>
        <dl class="grid gap-x-6 gap-y-2 border-t border-subtle px-4 py-3 text-sm sm:grid-cols-[12rem_minmax(0,1fr)]">
          <dt class="text-muted">Missing stop times</dt>
          <dd id="export-run-missing-times" class="text-strong">
            {recorded_missing_times(@run)}
          </dd>
        </dl>
      </details>

      <div
        :if={@conflicts != []}
        id="export-conflict-panel"
        class="mt-5 rounded-card border border-error-line bg-error-bg px-4 py-3.5 text-error-fg"
      >
        <ul id="export-conflicts" class="grid gap-3 text-sm">
          <li :for={conflict <- @conflicts} class="border-l-2 border-error-line pl-3">
            {warning_detail(conflict)}
          </li>
        </ul>
      </div>

      <.warning_list :if={@others != []} warnings={@others} created?={@run.state == :ready} />
    </div>
    """
  end

  attr :action, :atom, required: true
  attr :run, :any, default: nil
  attr :version, :map, required: true

  defp run_action(%{action: :export} = assigns) do
    ~H"""
    <.button id="start-export" class="min-h-11" phx-click={start_js("start_export")}>
      Export feed
    </.button>
    """
  end

  defp run_action(%{action: :exporting} = assigns) do
    ~H"""
    <.button id="start-export" class="min-h-11" disabled>Exporting…</.button>
    """
  end

  defp run_action(%{action: :cancelling} = assigns) do
    ~H"""
    <.button id="cancelling-export" class="min-h-11" disabled>Cancelling…</.button>
    """
  end

  defp run_action(%{action: :cancel} = assigns) do
    ~H"""
    <.button
      id="cancel-export"
      variant="secondary"
      class="min-h-11"
      phx-click={start_js("cancel_export")}
    >
      Cancel export
    </.button>
    """
  end

  defp run_action(%{action: :download} = assigns) do
    ~H"""
    <.button
      id="export-download-link"
      href={~p"/gtfs/#{@version.id}/export-runs/#{@run.id}/download"}
      class="min-h-11"
    >
      <.icon name="hero-arrow-down-tray" class="size-4" /> Download file
    </.button>
    <.button
      :if={@run.flex_artifact_key}
      id="export-flex-download-link"
      href={~p"/gtfs/#{@version.id}/export-runs/#{@run.id}/download?file=flex"}
      variant="secondary"
      class="min-h-11"
    >
      <.icon name="hero-arrow-down-tray" class="size-4" /> Download flex file
    </.button>
    """
  end

  defp run_action(%{action: :export_again} = assigns) do
    ~H"""
    <.button
      id="start-export"
      variant="secondary"
      class="min-h-11"
      phx-click={start_js("start_export")}
    >
      Export again
    </.button>
    """
  end

  defp run_action(%{action: :retry} = assigns) do
    ~H"""
    <.button id="retry-export" class="min-h-11" phx-click={start_js("retry_export")}>
      <.icon name="hero-arrow-path" class="size-4" /> Retry export
    </.button>
    """
  end

  defp run_action(%{action: :retry_secondary} = assigns) do
    ~H"""
    <.button
      id="retry-export"
      variant="secondary"
      class="min-h-11"
      phx-click={start_js("retry_export")}
    >
      Retry export
    </.button>
    """
  end

  defp run_action(%{action: :restart} = assigns) do
    ~H"""
    <.button id="retry-export" class="min-h-11" phx-click={start_js("retry_export")}>
      Export again
    </.button>
    """
  end

  defp run_action(%{action: :edit_garages} = assigns) do
    ~H"""
    <.button
      id="export-edit-garages"
      href={"/gtfs/#{@version.id}/settings/garages"}
      class="min-h-11"
    >
      Edit garages
    </.button>
    """
  end

  # The control that started an action disappears or is disabled when the state
  # changes, so focus moves to the band's title, which also names the new state.
  defp start_js(event), do: JS.push(event) |> JS.focus(to: "#export-run-title")

  defp status(nil, export_type, _version) do
    %{
      tone: :neutral,
      icon: "hero-document",
      title: none_title(export_type),
      detail: "Export to create a ZIP file. It stays available to download for a short time.",
      actions: [:export]
    }
  end

  defp status(%Run{state: :pending}, _export_type, _version) do
    %{
      tone: :info,
      icon: "hero-arrow-path",
      spin?: true,
      title: "Queued",
      detail:
        "Your export is waiting to start. This page updates on its own, and you can leave and come back.",
      actions: [:exporting, :cancel]
    }
  end

  defp status(%Run{state: :building, cancel_requested_at: nil}, _export_type, _version) do
    %{
      tone: :info,
      icon: "hero-arrow-path",
      spin?: true,
      title: "Building your file",
      detail:
        "Packaging your data. This page updates on its own, and you can leave and come back.",
      actions: [:exporting, :cancel]
    }
  end

  defp status(%Run{state: :building}, _export_type, _version) do
    %{
      tone: :warning,
      icon: "hero-arrow-path",
      spin?: true,
      title: "Cancelling export",
      detail: "The export stops at the next safe point. No file will be saved.",
      actions: [:cancelling]
    }
  end

  defp status(%Run{state: :ready} = run, export_type, version) do
    %{
      tone: :success,
      icon: "hero-check",
      title: "Ready to download",
      detail: "#{type_name(export_type)} · #{version.name}",
      note:
        if(export_type == :operations,
          do: "Contains garages and vehicles. Share it only with your CAD/AVL vendor."
        ),
      meta: ready_meta(run),
      actions: [:download, :export_again]
    }
  end

  defp status(%Run{state: :failed, failure_code: @conflict_code}, _export_type, _version) do
    %{
      tone: :error,
      icon: "hero-exclamation-triangle",
      title: "Garage IDs clash with stop IDs",
      detail:
        "Some garage IDs are the same as stop IDs already in the feed, so two places would share one ID. Change those garage IDs, then export again.",
      actions: [:edit_garages, :retry_secondary]
    }
  end

  defp status(
         %Run{state: :failed, failure_code: "artifact_storage_unavailable"},
         _export_type,
         _version
       ) do
    %{
      tone: :error,
      icon: "hero-exclamation-triangle",
      title: "Export failed",
      detail:
        "The file was built but couldn’t be saved, because this server can’t write export files. Ask an administrator to check the export storage location, then try again.",
      actions: [:retry]
    }
  end

  defp status(%Run{state: :failed}, _export_type, _version) do
    %{
      tone: :error,
      icon: "hero-exclamation-triangle",
      title: "Export failed",
      detail:
        "The build stopped because of an error, and no file was saved. Try again. If it keeps failing, tell an administrator.",
      actions: [:retry]
    }
  end

  defp status(%Run{state: :interrupted}, _export_type, _version) do
    %{
      tone: :error,
      icon: "hero-exclamation-triangle",
      title: "Export interrupted",
      detail: "The export stopped before it finished, so no file was saved. Try again.",
      actions: [:retry]
    }
  end

  defp status(%Run{state: :cancelled}, _export_type, _version) do
    %{
      tone: :warning,
      icon: "hero-no-symbol",
      title: "Export cancelled",
      detail: "This export was cancelled before a file was saved.",
      actions: [:restart]
    }
  end

  defp status(%Run{state: :expired}, _export_type, _version) do
    %{
      tone: :warning,
      icon: "hero-clock",
      title: "Download expired",
      detail:
        "The file was deleted when its download time ran out. Export again to get a new copy.",
      actions: [:restart]
    }
  end

  defp none_title(:full), do: "No full feed exported yet"
  defp none_title(:pathways), do: "No pathways file exported yet"
  defp none_title(:operations), do: "No operations export yet"

  defp type_name(:full), do: "Full feed"
  defp type_name(:pathways), do: "Station pathways only"
  defp type_name(:operations), do: "Feed with operations data"

  # A ready run reports when the file was made and when its download ends, so
  # the retention limit is stated as a time instead of "the retention period".
  defp ready_meta(%Run{} = run) do
    [
      run.finished_at && "Created #{DisplayClock.format_datetime(run.finished_at)}",
      run.artifact_expires_at &&
        "Available until #{DisplayClock.format_datetime(run.artifact_expires_at)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      meta -> meta
    end
  end

  # Neutral is the empty state; the four state tones use the design system's
  # message colours, with success in the same cyan as the rest of the app.
  defp tone_class(:neutral), do: "border border-subtle bg-white text-muted"
  defp tone_class(:info), do: "bg-soft text-cyan-800"
  defp tone_class(:success), do: "bg-soft text-cyan-700"
  defp tone_class(:warning), do: "bg-warning-bg text-warning-fg"
  defp tone_class(:error), do: "bg-error-bg text-error-fg"

  # A finished run's display reads the run's recorded missing-times setting
  # (INV-3), never the current defaults; only the pre-run line and the
  # validator read current defaults. A run written before the setting
  # existed records `false, nil`, which reads as "Left blank" without
  # inventing a method.
  defp recorded_missing_times(%Run{estimate_missing_times: true, estimate_method: :even}),
    do: "Estimated by equal time per stop"

  defp recorded_missing_times(%Run{estimate_missing_times: true}),
    do: "Estimated by distance along the path"

  defp recorded_missing_times(_run), do: "Left blank"

  defp stale_missing_times?(
         %Run{estimate_missing_times: true, estimate_method: method},
         %{estimate_missing_times: true, estimate_method: method}
       ),
       do: false

  defp stale_missing_times?(%Run{estimate_missing_times: false}, %{
         estimate_missing_times: false
       }),
       do: false

  defp stale_missing_times?(%Run{}, %{} = _defaults), do: true
  defp stale_missing_times?(_run, _defaults), do: false

  defp stale_detail(%Run{} = run, defaults) do
    "This file #{String.downcase(recorded_missing_times(run))}. " <>
      "Export again to use today's settings (#{current_missing_times_setting(defaults)})."
  end

  defp current_missing_times_setting(%{
         estimate_missing_times: true,
         estimate_method: :even
       }),
       do: "estimate by equal time per stop"

  defp current_missing_times_setting(%{estimate_missing_times: true}),
    do: "estimate by distance along the path"

  defp current_missing_times_setting(_defaults), do: "leave blank"

  defp conflict?(%Run{failure_code: code}), do: code == @conflict_code
  defp conflict?(_run), do: false

  # Persisted warnings are read back from `jsonb[]` with string keys, so both key
  # spellings resolve through one accessor.
  defp warning_code(issue), do: Map.get(issue, :code, Map.get(issue, "code"))

  defp warning_detail(issue, default \\ nil),
    do: Map.get(issue, :detail, Map.get(issue, "detail", default))

  attr :warnings, :list, required: true
  attr :created?, :boolean, required: true

  defp warning_list(assigns) do
    {shown, rest} = Enum.split(assigns.warnings, @warnings_shown)

    assigns =
      assigns
      |> assign(:shown, shown)
      |> assign(:rest, rest)
      |> assign(:count, length(assigns.warnings))

    ~H"""
    <div
      id="export-warning-panel"
      class="mt-5 rounded-card border border-warning-line bg-warning-bg px-4 py-3.5 text-warning-fg"
    >
      <p class="flex items-center gap-2 text-sm font-bold">
        <.icon name="hero-exclamation-triangle" class="size-[18px] shrink-0" />
        {@count} {if @count == 1, do: "warning", else: "warnings"} about {if @created?,
          do: "this file",
          else: "this export"}
      </p>
      <p class="mt-1 text-[13px]">
        {if @created?,
          do: "The file was created. These may affect how trip planners read it.",
          else: "Found while preparing this export."}
      </p>
      <ul class="mt-3 grid gap-3 text-sm">
        <.warning_item :for={issue <- @shown} issue={issue} />
      </ul>
      <details
        :if={@rest != []}
        id="export-warnings-more"
        phx-mounted={JS.ignore_attributes("open")}
        class="mt-3 text-sm"
      >
        <summary class="inline-flex min-h-11 cursor-pointer items-center font-semibold underline">
          Show {length(@rest)} more
        </summary>
        <ul class="grid gap-3 pb-1">
          <.warning_item :for={issue <- @rest} issue={issue} />
        </ul>
      </details>
    </div>
    """
  end

  attr :issue, :map, required: true

  defp warning_item(assigns) do
    assigns =
      assigns
      |> assign(:detail, warning_detail(assigns.issue, "Preflight reported an issue"))
      |> assign(:code, warning_code(assigns.issue))

    ~H"""
    <li class="border-l-2 border-warning-line pl-3">
      <p>{@detail}</p>
      <p :if={@code} class="mt-0.5 font-mono text-[13px] opacity-80">{@code}</p>
    </li>
    """
  end

  @doc """
  What to do with the file once it is downloaded. Trip planners fetch a feed from
  a permanent address instead of accepting a file, so the full feed's guidance is
  to host the file; the app has no public feed address yet, and says so. The
  operations file is private and the pathways file is not a complete feed.
  """
  attr :export_type, :atom, required: true
  attr :version, :map, required: true
  attr :organization, :any, required: true

  def guide(assigns) do
    assigns =
      assign(assigns, :feed_url?, ProductSurfaces.visible?(assigns.organization, :feed_url))

    ~H"""
    <.result_section
      id="export-guide"
      title="After you download"
      lede="How to get the file to the people who need it."
    >
      <div class="grid gap-4 px-5 py-5 text-sm leading-relaxed text-default">
        <%= case @export_type do %>
          <% :full -> %>
            <p class="max-w-[68ch]">
              Trip planners pick up your feed from a permanent web address, not from a file you email.
            </p>
            <ol role="list" class="grid gap-3 sm:grid-cols-3">
              <.guide_step number="1">Download the file before it expires.</.guide_step>
              <.guide_step number="2">
                Put it on a web address that never changes, such as your agency’s website.
              </.guide_step>
              <.guide_step number="3">Give that address to each trip planner.</.guide_step>
            </ol>
            <dl class="grid gap-x-8 gap-y-3 sm:grid-cols-2">
              <div>
                <dt class="font-semibold text-strong">Google Maps</dt>
                <dd>
                  Add the address in the Transit Partner Dashboard. Google fetches it on a schedule, at least weekly.
                </dd>
              </div>
              <div>
                <dt class="font-semibold text-strong">Transit app</dt>
                <dd>
                  Send the address to Transit’s data team. Transit needs a permanent, static address and picks up new data within hours.
                </dd>
              </div>
            </dl>
            <p :if={@feed_url?} class="flex flex-wrap items-center gap-x-3 text-[13px] text-muted">
              Coming soon in Settings: a permanent feed URL, so you won’t need to host the file yourself.
              <.guide_link id="export-feed-url" navigate={~p"/gtfs/#{@version.id}/settings/feed-url"}>
                See what’s planned
              </.guide_link>
            </p>
          <% :pathways -> %>
            <p class="max-w-[68ch]">
              This file holds station data only: stops, levels and pathways. It isn’t a complete feed.
            </p>
            <p class="max-w-[68ch]">
              Give it to the person or tool that combines it with your routes and schedules. Trip planners still need your full feed.
            </p>
          <% :operations -> %>
            <p class="max-w-[68ch]">
              Send this file to your CAD/AVL or scheduling vendor. It has your full feed plus garages and vehicles.
            </p>
            <p class="max-w-[68ch] rounded-control bg-canvas px-4 py-3">
              <strong class="font-semibold text-strong">Keep it private.</strong>
              Operations data is normally not published, so don’t host it publicly or send it to trip planners. Give them the full feed instead.
            </p>
            <p class="max-w-[68ch]">
              Vehicle types and garage assignments stay in this app; the file lists garages and vehicles only.
            </p>
            <p class="flex flex-wrap items-center gap-x-4 text-[13px]">
              <.guide_link
                id="export-manage-garages"
                navigate={~p"/gtfs/#{@version.id}/settings/garages"}
              >
                Manage garages
              </.guide_link>
              <.guide_link id="export-manage-fleet" navigate={~p"/gtfs/#{@version.id}/settings/fleet"}>
                Manage fleet
              </.guide_link>
            </p>
        <% end %>
      </div>
    </.result_section>
    """
  end

  attr :number, :string, required: true
  slot :inner_block, required: true

  defp guide_step(assigns) do
    ~H"""
    <li class="flex items-start gap-3 rounded-control border border-subtle px-4 py-3">
      <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-soft text-[13px] font-bold text-cyan-800">
        {@number}
      </span>
      <span class="min-w-0">{render_slot(@inner_block)}</span>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  defp guide_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="inline-flex min-h-11 items-center text-[13px] font-[650] text-action no-underline hover:text-action-hover hover:underline"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Compare two retained full feed files over one explicit date range.

  The form names both sides and the window, and starts nothing by itself: the
  draft is `%{"left_run_id", "right_run_id", "from", "to"}` and
  `ExportLive` owns the events, the choices and the running comparison. The two
  run selectors carry a prompt and never a default, and the date range starts
  blank: a comparison always compares two named files over dates the editor
  chose.

  `choices` is `%{rows: [row], next_cursor: String.t() | nil}` for the page the
  server listed. A run the editor chose on an earlier page is still an option
  here, because `ExportLive` keeps the selected identities server-side rather
  than trusting the submitted value.

  The caps and the storage effect sit beside the action rather than behind a
  disclosure, because both change what starting a comparison does: it takes the
  existing download claim on each file, and a file that turns out to be damaged
  is closed and removed by the existing failed-run path.

  The status band is a polite live region whose title takes focus when the
  comparison starts, so a keyboard reader lands on the new state.
  """
  attr :form, :any, required: true
  attr :choices, :map, required: true

  attr :chosen, :map,
    required: true,
    doc: "`%{left: row | nil, right: row | nil}` the chosen rows, retained server-side"

  attr :status, :atom, required: true
  attr :notice, :string, default: nil
  attr :result, :map, default: nil

  def comparison(assigns) do
    assigns =
      assigns
      |> assign(:options, Enum.map(assigns.choices.rows, &{run_label(&1), to_string(&1.run_id)}))
      |> assign(:running?, assigns.status in [:running, :cancelling])
      |> assign(:view, comparison_view(assigns.status, assigns.chosen, assigns.result))

    ~H"""
    <div id="export-comparison" class="px-5 py-5">
      <.form
        for={@form}
        id="export-comparison-form"
        phx-change="select_comparison"
        phx-submit="start_comparison"
      >
        <fieldset>
          <legend class="text-[13px] font-semibold text-strong">
            Which two files do you want to compare?
          </legend>
          <div class="mt-2.5 grid gap-3 sm:grid-cols-2">
            <.input
              field={@form[:left_run_id]}
              type="select"
              id="comparison-left"
              label="Earlier export"
              prompt="Choose an export"
              options={@options}
            />
            <.input
              field={@form[:right_run_id]}
              type="select"
              id="comparison-right"
              label="Candidate export"
              prompt="Choose an export"
              options={@options}
            />
          </div>
        </fieldset>

        <div class="mt-3 grid gap-3 sm:grid-cols-2">
          <.input field={@form[:from]} type="date" id="comparison-from" label="From" />
          <.input field={@form[:to]} type="date" id="comparison-to" label="To" />
        </div>

        <p id="comparison-window-note" class="mt-2 text-[13px] leading-relaxed text-muted">
          The same dates are compared on both sides. One comparison covers at most 62 dates.
        </p>

        <div class="mt-4 flex flex-wrap items-center gap-2 max-sm:w-full max-sm:[&>*]:flex-1">
          <.button
            :if={not @running?}
            id="comparison-start"
            class="min-h-11"
            phx-click={JS.focus(to: "#comparison-status-title")}
          >
            Compare exports
          </.button>
          <.button
            :if={@status == :cancelling}
            id="comparison-start"
            class="min-h-11"
            disabled
          >
            Cancelling…
          </.button>
          <.button
            :if={@running?}
            id="comparison-cancel"
            variant="secondary"
            class="min-h-11"
            phx-click="cancel_comparison"
          >
            Cancel comparison
          </.button>
          <.button
            :if={@status in [:completed, :refused]}
            id="comparison-close"
            variant="quiet"
            class="min-h-11"
            phx-click="close_comparison"
          >
            Start over
          </.button>
          <.button
            :if={@choices.next_cursor}
            id="comparison-more-choices"
            variant="quiet"
            class="min-h-11"
            phx-click="load_more_comparison_choices"
          >
            Show more exports
          </.button>
        </div>

        <div
          id="comparison-caps"
          class="mt-4 rounded-card border border-subtle bg-canvas px-4 py-3 text-[13px] leading-relaxed text-default"
        >
          <p class="font-semibold text-strong">What one comparison reads</p>
          <ul class="mt-1.5 grid gap-1">
            <li>At most 150 MB compressed and 20 MB of the compared tables per file.</li>
            <li>At most 100,000 rows per file, and 200,000 exact departures per file.</li>
            <li>A file over any of these limits is refused whole, never partly compared.</li>
          </ul>
          <p class="mt-2">
            Comparing takes the normal download claim on each file, so that file’s download count goes
            up. If a file turns out to be damaged, it is closed and deleted and must be exported again.
          </p>
        </div>
      </.form>

      <.comparison_status view={@view} notice={@notice} />
    </div>
    """
  end

  attr :view, :map, required: true
  attr :notice, :string, default: nil

  defp comparison_status(assigns) do
    ~H"""
    <div
      id="comparison-status"
      role="status"
      aria-live="polite"
      class="mt-4 flex items-start gap-3.5 rounded-card border border-subtle px-4 py-3.5"
    >
      <span class={[
        "flex size-10 shrink-0 items-center justify-center rounded-full",
        comparison_tone_class(@view.tone)
      ]}>
        <.icon name={@view.icon} class={["size-5", @view[:spin?] && "motion-safe:animate-spin"]} />
      </span>
      <div class="min-w-0">
        <h3
          id="comparison-status-title"
          tabindex="-1"
          class="text-base font-bold leading-snug text-strong focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-focus"
        >
          {@view.title}
        </h3>
        <p id="comparison-status-detail" class="mt-1 text-sm leading-relaxed text-default">
          {@view.detail}
        </p>
        <p :if={@notice} id="comparison-notice" class="mt-1 text-[13px] font-semibold text-strong">
          {@notice}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The way into the comparison helper, shown once a comparison has finished.

  `context` is the immutable copy `ExportLive` admitted for the helper, or `nil`
  when none was. With one, the helper is offered; without one, the card says why
  and what to do, and the finished comparison above it is untouched. `notice` is
  `:source_too_large` when the whole comparison is more than the helper can hold,
  and `:invalid_scope` for any other refusal. Both point at the explicit scope
  form, because narrowing is the only way to a smaller copy.

  The refusal is a polite live region: it appears with the finished comparison,
  and a keyboard reader should hear it without looking for it.
  """
  attr :context, :map, default: nil
  attr :notice, :atom, default: nil
  attr :open?, :boolean, default: false

  def comparison_helper(assigns) do
    ~H"""
    <section
      id="comparison-helper-entry"
      aria-labelledby="comparison-helper-title"
      class="rounded-card border border-subtle bg-white px-5 py-4"
    >
      <%= if @context do %>
        <h3 id="comparison-helper-title" class="text-base font-bold text-strong">
          Ask about this comparison
        </h3>
        <p class="mt-1 text-[13px] leading-relaxed text-muted">
          The helper explains what changed and what could not be compared, using only the rows on
          this page. It can’t change your feed or start another comparison.
        </p>
        <.button
          id="comparison-helper-open"
          type="button"
          phx-click="comparison_helper_open"
          aria-expanded={to_string(@open?)}
          aria-controls="agent-panel"
          variant="quiet"
          class="mt-2 min-h-11"
        >
          Open comparison helper
        </.button>
      <% else %>
        <h3 id="comparison-helper-title" class="text-base font-bold text-strong">
          {helper_refusal_title(@notice)}
        </h3>
        <p
          id="comparison-helper-notice"
          role="status"
          class="mt-1 text-[13px] leading-relaxed text-default"
        >
          {helper_refusal_detail(@notice)}
        </p>
        <.button
          id="comparison-helper-narrow"
          type="button"
          variant="quiet"
          class="mt-2 min-h-11"
          phx-click={JS.focus(to: "#comparison-scope-routes")}
        >
          Choose routes and dates
        </.button>
      <% end %>
    </section>
    """
  end

  defp helper_refusal_title(:source_too_large), do: "The helper can’t read all of this comparison"
  defp helper_refusal_title(_other), do: "The helper can’t read this comparison"

  defp helper_refusal_detail(:source_too_large),
    do:
      "It has more rows than the helper can hold. Choose fewer routes and dates under “Narrow this comparison”, then ask again. The comparison below is unchanged."

  defp helper_refusal_detail(_other),
    do:
      "The comparison below is unchanged. Narrow it to the routes and dates you care about to try the helper again."

  # Two files of the same version exported on the same day are different
  # comparisons, so the label names the version and the exact export time. A run
  # that never recorded a version name is labelled as an export rather than
  # rendering a leading separator, and the time keeps two same-day files apart.
  defp run_label(row) do
    "#{version_label(row.version_name)} · exported #{format_timestamp(row.created_at)}"
  end

  defp version_label(name) when is_binary(name) and name != "", do: name
  defp version_label(_absent), do: "Full feed export"

  defp comparison_view(status, _chosen, _result) when status in [:idle],
    do: %{
      tone: :neutral,
      icon: "hero-document",
      title: "No comparison running",
      detail:
        "Choose two exported full feed files and the dates to compare them over. Nothing is read until you compare."
    }

  defp comparison_view(status, _chosen, _result) when status in [:running, :cancelling],
    do: %{
      tone: if(status == :running, do: :info, else: :warning),
      icon: "hero-arrow-path",
      spin?: true,
      title: if(status == :running, do: "Comparing exports", else: "Cancelling comparison"),
      detail:
        if(
          status == :running,
          do:
            "Reading both files and comparing their service over the dates you chose. This page updates on its own.",
          else: "The comparison stops at the next safe point and releases both files."
        )
    }

  defp comparison_view(:completed, chosen, result) do
    %{
      tone: :success,
      icon: "hero-check",
      title: "Comparison finished",
      detail:
        "Compared #{chosen_label(chosen.left)} with #{chosen_label(chosen.right)} over #{format_date_range(result.window)}."
    }
  end

  defp comparison_view(:refused, _chosen, _result),
    do: %{
      tone: :error,
      icon: "hero-exclamation-triangle",
      title: "The comparison couldn’t finish",
      detail: "Nothing in your feed was changed. Your dates and file choices are still here."
    }

  # The chosen rows are server-held, so a file that vanished from the current
  # page still names itself honestly instead of rendering an empty comparison.
  defp chosen_label(nil), do: "a chosen export"

  defp chosen_label(%{version_name: name} = row) when is_binary(name) and name != "",
    do: "#{name} (exported #{format_timestamp(row.created_at)})"

  # A run that recorded no version name still names itself by what it is and
  # when it was exported, so the finished band never reads "the other export"
  # twice and leaves the reader with no way to tell the two files apart.
  defp chosen_label(%{created_at: created_at}) when not is_nil(created_at),
    do: "the export made #{format_timestamp(created_at)}"

  defp chosen_label(_row), do: "an export with no recorded time"

  @doc """
  What the completed comparison found: the two files' identities, the shared
  window, the totals with their reason when a total could not be measured, the
  differences, structural changes, unresolved matches and unknowns as paged
  streams, and the explicit scope chooser.

  Every list is a LiveView stream, so a large native result pages instead of
  rendering thousands of rows, and a row is inspectable with the keyboard
  through an ordinary button.

  `view` is the result actually in view: the full native result, or the narrowed
  one `Compare.narrow/2` produced. `result` stays the full comparison, so
  clearing a scope restores it without recomputing anything.
  """
  attr :result, :map, required: true
  attr :view, :map, required: true
  attr :scope, :map, default: nil
  attr :scope_form, :any, required: true
  attr :scope_notice, :string, default: nil
  attr :inspected, :map, default: nil
  attr :page, :map, required: true
  attr :true_totals, :map, required: true

  # Each list is passed in as a slot because only the template that owns a
  # stream may iterate it. A stream consumed anywhere else renders its first
  # page and then stops pruning, so a narrowed scope would leave the full
  # comparison's rows on the page.
  slot :differences_list, required: true
  slot :structural_list, required: true
  slot :unresolved_list, required: true
  slot :unknowns_list, required: true

  def comparison_results(assigns) do
    assigns =
      assigns
      |> assign(:window, assigns.view.window)
      |> assign(:route_pairs, route_pair_options(assigns.view))
      |> assign(:date_options, date_options(assigns.view.window))
      |> assign(:totals, assigns.view.totals)
      |> assign(:completeness, assigns.view.completeness)
      |> assign(:omitted, omitted_units(assigns.view.exclusions))

    ~H"""
    <div id="comparison-results" class="grid gap-6">
      <.result_section
        id="comparison-summary"
        title="What the comparison found"
        lede={summary_lede(@completeness)}
      >
        <div class="grid gap-5 px-5 py-5">
          <dl id="comparison-artifacts" class="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-2">
            <.artifact_column label="Earlier export" identity={@result.left} />
            <.artifact_column label="Candidate export" identity={@result.right} />
          </dl>

          <p id="comparison-window" class="text-[13px] leading-relaxed text-muted">
            Both files were compared over the same dates, {format_date_range(@window)}.
          </p>

          <div id="comparison-totals">
            <p class="text-[13px] font-semibold text-strong">Totals across the compared routes</p>
            <%= if @totals.exact_count_delta == nil do %>
              <p id="comparison-totals-unknown" class="mt-1.5 text-sm leading-relaxed text-default">
                A whole-feed total was not measured, so none is shown. The comparison found:
              </p>
              <ul
                id="comparison-total-reasons"
                class="mt-1.5 grid gap-1 text-[13px] leading-relaxed text-default"
              >
                <li :for={reason <- @totals.reasons} data-reason={reason}>
                  {totals_reason(reason)}
                </li>
              </ul>
            <% else %>
              <dl class="mt-1.5 grid grid-cols-2 gap-3">
                <div class="rounded-control border border-subtle bg-canvas px-3 py-2.5">
                  <dt class="text-[13px] text-muted">Scheduled trips</dt>
                  <dd
                    id="comparison-scheduled-delta"
                    class="mt-0.5 font-display text-[26px] font-semibold leading-none tabular-nums"
                  >
                    {signed(@totals.scheduled_count_delta)}
                  </dd>
                </div>
                <div class="rounded-control border border-subtle bg-canvas px-3 py-2.5">
                  <dt class="text-[13px] text-muted">Exact departures</dt>
                  <dd
                    id="comparison-exact-delta"
                    class="mt-0.5 font-display text-[26px] font-semibold leading-none tabular-nums"
                  >
                    {signed(@totals.exact_count_delta)}
                  </dd>
                </div>
              </dl>
              <p class="mt-1.5 text-[13px] text-muted">{measured_units_label(@totals)}</p>
            <% end %>

            <p
              :if={@true_totals.comparison_unknowns > 0}
              id="comparison-totals-unknown-coverage"
              class="mt-1.5 text-[13px] leading-relaxed text-muted"
            >
              {@true_totals.comparison_unknowns} row{if @true_totals.comparison_unknowns == 1,
                do: "",
                else: "s"} could not be read from the bytes admitted above, so nothing above states
              anything about {if @true_totals.comparison_unknowns == 1, do: "it", else: "them"}.
              The reason and the file it came from are listed under Unknowns.
            </p>
          </div>

          <div id="comparison-completeness">
            <.tone_badge tone={completeness_tone(@completeness.status)}>
              {completeness_label(@completeness.status)}
            </.tone_badge>
            <ul
              :if={@completeness.reasons != []}
              id="comparison-completeness-reasons"
              class="mt-2 grid gap-1 text-[13px] leading-relaxed text-default"
            >
              <li :for={reason <- @completeness.reasons} data-reason={reason}>
                {completeness_reason(reason)}
              </li>
            </ul>
          </div>

          <div
            :if={@view[:scope]}
            id="comparison-scope-applied"
            class="rounded-card border border-info-line bg-info-bg px-4 py-3 text-[13px] leading-relaxed"
          >
            <p class="font-semibold">Showing a narrowed scope</p>
            <p class="mt-0.5">
              {length(@view.scope.route_pair_keys)} route{plural(@view.scope.route_pair_keys)} and {length(
                @view.scope.dates
              )} date{plural(@view.scope.dates)}. The totals above
              count only these; the full comparison is still held by this page.
            </p>
            <p :if={@omitted != []} id="comparison-omitted-count" class="mt-1">
              {length(@omitted)} route and date group{plural(@omitted)} from the full
              comparison {if length(@omitted) == 1, do: "is", else: "are"} left out of this scope.
            </p>
            <.button
              id="comparison-clear-scope"
              variant="quiet"
              class="mt-2 min-h-11"
              phx-click="clear_comparison_scope"
            >
              Show the whole comparison
            </.button>
          </div>
        </div>
      </.result_section>

      <.result_section
        id="comparison-differences"
        title="Service differences"
        count={@true_totals.comparison_differences}
        lede="What changed in the compared service, one row per difference."
      >
        {render_slot(@differences_list)}
        <p
          :if={@true_totals.comparison_differences == 0}
          id="comparison-differences-empty"
          class="px-5 py-6 text-center text-[13px] text-muted"
        >
          No service differences were found in this scope.
        </p>
        <.page_bar
          collection={:comparison_differences}
          page={@page.comparison_differences}
          true_total={@true_totals.comparison_differences}
          noun="difference"
        />
      </.result_section>

      <.result_section
        id="comparison-structural"
        title="Identifier and presence changes"
        count={@true_totals.comparison_structural}
        lede="Renamed, added and removed entities. These are not service loss on their own."
      >
        {render_slot(@structural_list)}
        <p
          :if={@true_totals.comparison_structural == 0}
          id="comparison-structural-empty"
          class="px-5 py-6 text-center text-[13px] text-muted"
        >
          No identifiers changed.
        </p>
        <.page_bar
          collection={:comparison_structural}
          page={@page.comparison_structural}
          true_total={@true_totals.comparison_structural}
          noun="change"
        />
      </.result_section>

      <.result_section
        id="comparison-unresolved"
        title="Unresolved entity matches"
        count={@true_totals.comparison_unresolved}
        lede="Entities this comparison could not pair with confidence. They are never counted as a loss."
      >
        {render_slot(@unresolved_list)}
        <p
          :if={@true_totals.comparison_unresolved == 0}
          id="comparison-unresolved-empty"
          class="px-5 py-6 text-center text-[13px] text-muted"
        >
          Every entity was paired.
        </p>
        <.page_bar
          collection={:comparison_unresolved}
          page={@page.comparison_unresolved}
          true_total={@true_totals.comparison_unresolved}
          noun="unresolved match"
        />
      </.result_section>

      <.result_section
        id="comparison-unknowns-section"
        title="What this comparison could not read"
        count={@true_totals.comparison_unknowns}
        lede="Rows the files did not state clearly. They are never counted as zero service."
      >
        {render_slot(@unknowns_list)}
        <p
          :if={@true_totals.comparison_unknowns == 0}
          id="comparison-unknowns-empty"
          class="px-5 py-6 text-center text-[13px] text-muted"
        >
          Nothing was unreadable.
        </p>
        <.page_bar
          collection={:comparison_unknowns}
          page={@page.comparison_unknowns}
          true_total={@true_totals.comparison_unknowns}
          noun="unknown row"
        />
      </.result_section>

      <div
        :if={@inspected}
        id="comparison-inspected"
        role="region"
        aria-labelledby="comparison-inspected-title"
        tabindex="-1"
        class="rounded-card border border-subtle bg-white px-5 py-5 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <h3 id="comparison-inspected-title" class="text-base font-bold text-strong">
            One row in full
          </h3>
          <.button
            id="comparison-inspected-close"
            variant="quiet"
            size="sm"
            phx-click={
              JS.push("close_comparison_detail") |> JS.focus(to: "#comparison-inspected-title")
            }
          >
            Close
          </.button>
        </div>
        <p class="mt-1 text-[13px] leading-relaxed text-muted">
          The row as the comparison recorded it, including the file and row it came from.
        </p>
        <dl
          id="comparison-inspected-body"
          class="mt-3 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-[10rem_minmax(0,1fr)]"
        >
          <.detail_term term="Kind" value={inspect_kind(@inspected)} />
          <.detail_term term="Route" value={inspect_route(@inspected)} />
          <.detail_term term="Dates" value={inspect_dates(@inspected)} />
          <.detail_term term="Counts" value={inspect_counts(@inspected)} />
          <.detail_term term="Reason" value={inspect_reason(@inspected)} />
          <.detail_term term="Source rows" value={inspect_refs(@inspected)} />
          <.detail_term term="Frequency windows" value={inspect_frequency(@inspected)} />
        </dl>
      </div>

      <.form for={@scope_form} id="comparison-scope-form" phx-submit="narrow_comparison">
        <fieldset class="rounded-card border border-subtle bg-white px-5 py-5">
          <legend class="text-[13px] font-semibold text-strong">
            Narrow this comparison to the routes and dates you care about
          </legend>
          <p class="mt-1 text-[13px] leading-relaxed text-muted">
            Narrowing is explicit and stays on this page. The full comparison is kept: the totals
            above count only what you select, and every group left out is named below. This is an
            internal comparison of two of your own files. Nothing here is published or shared
            automatically.
          </p>

          <div class="mt-3 grid gap-3 sm:grid-cols-2">
            <.input
              field={@scope_form[:route_pair_keys]}
              type="select"
              id="comparison-scope-routes"
              label="Routes"
              multiple
              options={@route_pairs}
            />
            <.input
              field={@scope_form[:dates]}
              type="select"
              id="comparison-scope-dates"
              label="Dates"
              multiple
              options={@date_options}
            />
          </div>

          <p
            :if={@scope_notice}
            id="comparison-scope-notice"
            class="mt-2 text-[13px] font-semibold text-strong"
          >
            {@scope_notice}
          </p>

          <div class="mt-4 flex flex-wrap items-center gap-2 max-sm:w-full max-sm:[&>*]:flex-1">
            <.button
              id="comparison-share-scope"
              class="min-h-11"
              phx-click={JS.focus(to: "#comparison-scope-routes")}
            >
              Narrow to this selection
            </.button>
          </div>
        </fieldset>
      </.form>

      <details
        id="comparison-exclusions"
        class="group rounded-card border border-subtle bg-white px-5 py-4"
      >
        <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 text-sm font-semibold text-strong [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right"
            class="size-4 text-muted transition-transform group-open:rotate-90"
          /> What this comparison does not cover
        </summary>
        <ul
          id="comparison-exclusion-list"
          class="grid gap-1.5 pt-2 text-[13px] leading-relaxed text-default"
        >
          <li :for={exclusion <- @view.exclusions} data-reason={exclusion.reason}>
            {exclusion.detail}
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :identity, :map, required: true

  defp artifact_column(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-[13px] font-semibold text-strong">{@label}</dt>
      <dd class="mt-0.5 text-[13px] leading-relaxed text-muted">
        <p>Feed version <span class="font-mono">{short_id(@identity.version_id)}</span></p>
        <p class="mt-0.5">SHA-256 <span class="font-mono">{short_id(@identity.sha256)}</span></p>
        <p class="mt-0.0.5">
          {format_bytes(@identity.size)} · expires {format_timestamp(@identity.expires_at)}
        </p>
        <p :if={@identity[:estimate_missing_times]} class="mt-0.5">
          Missing stop times were estimated at export time
          ({estimate_label(@identity[:estimate_method])}), so no original value is available to
          compare.
        </p>
      </dd>
    </div>
    """
  end

  attr :term, :string, required: true
  attr :value, :string, required: true

  defp detail_term(assigns) do
    ~H"""
    <dt class="text-[13px] text-muted">{@term}</dt>
    <dd class="min-w-0 break-words text-strong">{@value}</dd>
    """
  end

  attr :collection, :atom, required: true
  attr :page, :map, required: true
  attr :true_total, :integer, required: true
  attr :noun, :string, required: true

  # Paging is deterministic: the same page of the same result always shows the
  # same rows, and the counter states the whole collection's size, not the page's.
  defp page_bar(assigns) do
    ~H"""
    <div
      :if={@true_total > @page.limit}
      id={"comparison-#{short_collection(@collection)}-paging"}
      class="flex flex-wrap items-center justify-between gap-2 border-t border-subtle bg-canvas px-5 py-3"
    >
      <p class="text-[13px] tabular-nums text-muted">
        Showing {first_shown(@page)}–{last_shown(@page, @true_total)} of {@true_total}
        {if @true_total == 1, do: @noun, else: @noun <> "s"}
      </p>
      <div class="flex items-center gap-2">
        <.button
          :if={@page.offset > 0}
          id={"comparison-#{short_collection(@collection)}-previous"}
          variant="secondary"
          size="sm"
          class="min-h-11"
          phx-click="page_comparison"
          phx-value-collection={@collection}
          phx-value-offset={max(@page.offset - @page.limit, 0)}
          phx-value-limit={@page.limit}
        >
          Previous
        </.button>
        <.button
          :if={last_shown(@page, @true_total) < @true_total}
          id={"comparison-#{short_collection(@collection)}-next"}
          variant="secondary"
          size="sm"
          class="min-h-11"
          phx-click="page_comparison"
          phx-value-collection={@collection}
          phx-value-offset={@page.offset + @page.limit}
          phx-value-limit={@page.limit}
        >
          Next
        </.button>
      </div>
    </div>
    """
  end

  # The DOM ids of the paging controls drop the stream's own `comparison_`
  # prefix, so the page's ids stay short and stable.
  defp short_collection(:comparison_differences), do: "differences"
  defp short_collection(:comparison_structural), do: "structural"
  defp short_collection(:comparison_unresolved), do: "unresolved"
  defp short_collection(:comparison_unknowns), do: "unknowns"

  defp first_shown(%{offset: offset}), do: offset + 1

  defp last_shown(%{offset: offset, limit: limit}, true_total),
    do: min(offset + limit, true_total)

  # The narrowing form only ever offers route pairs and dates this very result
  # proved, so a selection cannot name something the comparison never found.
  defp route_pair_options(view) do
    case Compare.route_pairs(view) do
      [] -> [{"No routes were compared", ""}]
      pairs -> Enum.map(pairs, &{&1.label, &1.key})
    end
  end

  defp date_options(window) do
    window.from
    |> Date.range(window.to)
    |> Enum.map(&{Date.to_iso8601(&1), Date.to_iso8601(&1)})
  end

  defp omitted_units(exclusions),
    do: Enum.filter(exclusions, &(&1.reason == :narrowed_out_of_scope))

  defp summary_lede(%{status: :complete}),
    do: "Every supported dimension of both files was compared over these dates."

  defp summary_lede(%{status: :incomplete}),
    do: "Some of what these files describe could not be compared, so this is a partial answer."

  defp completeness_tone(:complete), do: "success"
  defp completeness_tone(:incomplete), do: "warning"

  defp completeness_label(:complete), do: "Complete for this window"
  defp completeness_label(:incomplete), do: "Incomplete for this window"

  defp completeness_reason(:no_service_groups),
    do: "Neither file stated service for these routes and dates."

  defp completeness_reason(:unmeasured_units),
    do: "At least one route and date could not be compared on both sides."

  defp completeness_reason(:unresolved_entity_matches),
    do: "Some entities could not be paired with confidence."

  defp completeness_reason(:stop_meaning_changed),
    do: "A stop moved or changed type, so its trips were not compared for timing."

  defp completeness_reason(:left_evaluation_incomplete),
    do: "The earlier file has rows that could not be read."

  defp completeness_reason(:right_evaluation_incomplete),
    do: "The candidate file has rows that could not be read."

  defp completeness_reason(:unpaired_trips),
    do: "Some trips on the same route and date could not be paired between the two files."

  defp completeness_reason(reason),
    do: "This comparison is incomplete for another reason: #{reason}."

  defp totals_reason(:unmapped_route), do: "A route in one file has no proven match in the other."
  defp totals_reason(:one_sided_unit), do: "A route states service on one side only."

  defp totals_reason(:incomplete_counts),
    do: "A route states frequency windows rather than exact departures."

  defp totals_reason(:unknown_timezone),
    do: "A route’s timezone is unknown, so its timing is not compared."

  defp totals_reason(:timezone_mismatch), do: "The two files give a route different timezones."
  defp totals_reason(:stop_meaning_changed), do: "A stop’s correspondence changed meaning."
  defp totals_reason(:stop_ambiguous), do: "A stop could not be told apart from a similar one."
  defp totals_reason(:stop_unresolved), do: "A stop has no proven correspondence."

  defp totals_reason(:left_evaluation_incomplete),
    do: "The earlier file has rows that could not be read."

  defp totals_reason(:right_evaluation_incomplete),
    do: "The candidate file has rows that could not be read."

  defp totals_reason(reason), do: "This total was not measured: #{reason}."

  defp measured_units_label(%{measured_units: measured, total_units: total}) do
    "Measured across #{measured} of #{total} compared route and date #{if total == 1, do: "group", else: "groups"}."
  end

  defp difference_reason(:one_sided_unit),
    do: "One file states service here and the other states none, so no change is claimed."

  defp difference_reason(:incomplete_counts),
    do:
      "One file states frequency windows rather than exact departures, so counts are not compared."

  defp difference_reason(:unmapped_route), do: "This route has no proven match in the other file."
  defp difference_reason(reason), do: "Not compared: #{reason}."

  defp change_kind(:added), do: "Service added"
  defp change_kind(:removed), do: "Service removed"
  defp change_kind(:count_changed), do: "Trip count changed"
  defp change_kind(:timing_changed), do: "Timing changed"
  defp change_kind(:frequency_changed), do: "Frequency changed"
  defp change_kind(:identifier), do: "Renamed"
  defp change_kind(reason), do: humanize(reason)

  # A structural change is a rename, a presence change, or a field of an entity that
  # kept its identifier (its service dates, stop times, frequency windows, name and
  # so on). The last kind is neither new nor missing, so it says which field moved.
  defp structural_title(change) when change in [:identifier, :added, :removed],
    do: change_kind(change)

  defp structural_title(_field), do: "Changed"

  defp structural_note(:identifier),
    do: "Renamed; the service it carries was compared under both identifiers."

  defp structural_note(:removed), do: "This entity is missing from the candidate file."
  defp structural_note(:added), do: "This entity is new in the candidate file."

  defp structural_note(field),
    do: "Same identifier, but its #{structural_field(field)} changed between the two files."

  defp structural_field(:service_dates), do: "service dates"
  defp structural_field(:time_vector), do: "stop times"
  defp structural_field(:stop_pattern), do: "stops"
  defp structural_field(:frequencies), do: "frequency windows"
  defp structural_field(field), do: field |> to_string() |> String.replace("_", " ")

  defp unresolved_reason(:no_candidate), do: "no candidate on the other side"
  defp unresolved_reason(:ambiguous_signature), do: "several entities share its signature"
  defp unresolved_reason(:missing_field), do: "a field it needs was absent"
  defp unresolved_reason(:unproven_dependency), do: "something it depends on was unresolved"
  defp unresolved_reason(reason), do: humanize(reason)

  defp unknown_reason(reason), do: humanize(reason)

  defp humanize(reason),
    do: reason |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp side_label(:left), do: "Earlier"
  defp side_label(:right), do: "Candidate"
  defp side_label(other), do: humanize(other)

  defp route_label(%{left: left, right: right}) do
    cond do
      is_binary(left) and is_binary(right) -> "#{left} → #{right}"
      is_binary(left) -> "#{left} (earlier file only)"
      is_binary(right) -> "#{right} (candidate file only)"
      true -> "Unnamed route"
    end
  end

  defp change_dates(%{date: date, dates: dates}) do
    cond do
      is_map(date) -> Date.to_iso8601(date)
      dates != [] -> Enum.map_join(dates, ", ", &Date.to_iso8601/1)
      true -> "All compared dates"
    end
  end

  defp change_delta(%{delta: delta, counts: counts}) do
    "trips #{signed(delta[:scheduled_count])} · exact #{signed(delta[:exact_count])} · was #{counts_description(counts)}"
  end

  defp counts_description(%{left: left, right: right}),
    do: "#{side_count(left)} then #{side_count(right)}"

  defp side_count(nil), do: "none"

  defp side_count(counts) when is_map(counts),
    do: "#{counts[:scheduled_count] || 0} scheduled, #{counts[:exact_count] || 0} exact"

  defp signed(nil), do: "not measured"
  defp signed(0), do: "no change"
  defp signed(value) when value > 0, do: "+#{value}"
  defp signed(value), do: "#{value}"

  # An entity of the earlier file is matched against candidates from the candidate
  # file and the other way round, so each candidate is named for the file it is in.
  defp unresolved_refs(%{left_ref: left, right_ref: right, candidates: candidates}) do
    candidate_file = if left, do: "candidate", else: "earlier"

    parts =
      ([
         left && "earlier #{left.id} (#{left.file} row #{left.row})",
         right && "candidate #{right.id} (#{right.file} row #{right.row})"
       ] ++
         Enum.map(candidates, &"#{candidate_file} #{&1.id} (#{&1.file} row #{&1.row})"))
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "No identifiers were recorded for this entry."
      parts -> Enum.join(parts, " · ")
    end
  end

  # A side, when a row has one, is what a reader needs first: an unreadable row
  # is evidence about one named file, not about the comparison in general.
  defp inspect_kind(%{side: side, reason: reason}),
    do: "#{side_label(side)} file · #{unknown_reason(reason)}"

  defp inspect_kind(%{kind: kind}), do: change_kind(kind)
  defp inspect_kind(%{change: change}), do: change_kind(change)

  defp inspect_kind(%{entity: entity, reason: reason}) when is_binary(entity),
    do: "#{entity} · #{unresolved_reason(reason)}"

  defp inspect_route(%{route_ids: route_ids}), do: route_label(route_ids)
  defp inspect_route(_row), do: "Not tied to a route pair."

  defp inspect_dates(%{date: date, dates: dates}) do
    cond do
      is_map(date) -> Date.to_iso8601(date)
      dates != [] -> Enum.map_join(dates, ", ", &Date.to_iso8601/1)
      true -> "No service date applies to this row."
    end
  end

  defp inspect_dates(_row), do: "No service date applies to this row."

  defp inspect_counts(%{delta: delta, counts: counts}) do
    "was #{counts_description(counts)}; now trips #{signed(delta[:scheduled_count])}, exact #{signed(delta[:exact_count])}"
  end

  defp inspect_counts(%{left: left, right: right}) when is_map(left) and is_map(right) do
    "earlier #{side_count(Map.take(left, [:scheduled_count, :exact_count]))}, " <>
      "candidate #{side_count(Map.take(right, [:scheduled_count, :exact_count]))}"
  end

  defp inspect_counts(%{left: left, right: right}),
    do: "earlier #{side_count(left)}, candidate #{side_count(right)}"

  defp inspect_counts(%{entity: entity}),
    do: "This #{entity} has no trip counts; it is an identity or presence change."

  defp inspect_counts(%{reason: reason}), do: "This row has no counts: #{unknown_reason(reason)}."

  defp inspect_reason(%{reason: nil}), do: "The comparison measured this row."
  defp inspect_reason(%{reason: reason}) when is_atom(reason), do: difference_reason(reason)
  defp inspect_reason(_row), do: "The comparison measured this row."

  defp inspect_refs(%{source_refs: %{left: left, right: right}}) do
    [left, right]
    |> Enum.map_join(" · ", fn
      [] -> "no rows recorded"
      refs -> Enum.map_join(refs, ", ", &"#{&1.file} row #{&1.row}")
    end)
  end

  defp inspect_refs(%{left_ref: left, right_ref: right}) do
    [
      left && "earlier #{left.file} row #{left.row}",
      right && "candidate #{right.file} row #{right.row}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "No rows were recorded."
      refs -> refs
    end
  end

  defp inspect_refs(%{source: %{file: file, row: row}}), do: "#{file} row #{row}"
  defp inspect_refs(_row), do: "No rows were recorded."

  # Frequency windows are shown separately from a departure count, because a
  # window is a template rather than a proven number of trips.
  defp inspect_frequency(%{frequency_windows: %{left: left, right: right}}) do
    case {left, right} do
      {[], []} -> "None. Both files state exact trips here."
      _windows -> Enum.map_join([left, right], " · ", &window_description/1)
    end
  end

  defp inspect_frequency(_row), do: "None recorded."

  defp window_description([]), do: "no windows"

  defp window_description(windows) do
    Enum.map_join(windows, ", ", fn window ->
      exact = if window[:exact_times] == 1, do: "every trip", else: "a template"
      "#{window[:start_secs]}–#{window[:end_secs]}s every #{window[:headway_secs]}s (#{exact})"
    end)
  end

  defp short_id(nil), do: "unknown"
  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short_id(value), do: to_string(value)

  defp estimate_label(:even), do: "equal time per stop"
  defp estimate_label(_method), do: "distance along the path"

  defp format_bytes(nil), do: "unknown size"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  defp comparison_tone_class(:neutral), do: "border border-subtle bg-white text-muted"
  defp comparison_tone_class(:info), do: "bg-soft text-cyan-800"
  defp comparison_tone_class(:success), do: "bg-soft text-cyan-700"
  defp comparison_tone_class(:warning), do: "bg-warning-bg text-warning-fg"
  defp comparison_tone_class(:error), do: "bg-error-bg text-error-fg"

  # A window's bounds are plain `Date`s and a run's timestamp is a `DateTime`,
  # so both are formatted here rather than at each call site.
  defp format_timestamp(%DateTime{} = time),
    do: Calendar.strftime(time, "%b %-d, %Y %-I:%M %p")

  defp format_timestamp(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")
  defp format_timestamp(nil), do: "an unknown time"

  defp format_date_range(%{from: from, to: to}),
    do: "#{format_timestamp(from)} – #{format_timestamp(to)}"

  @doc """
  The feed check: idle, running with its phase, finished with a verdict, or
  unable to finish.

  `error` is `:failed`, `:not_started` or `:other_organization`. The check reads
  the version's current data, not the downloaded file, and the card says so.
  Both actions on a finished check are secondary: the page's one primary is in
  the export band.
  """
  attr :validating?, :boolean, required: true
  attr :progress, :map, default: nil, doc: "`%{phase: atom, percent: 0..100}` while running"
  attr :result, :map, default: nil, doc: "`%{summary: %{errors:, warnings:, infos:}}`"
  attr :error, :atom, default: nil
  attr :validation_run_id, :any, default: nil
  attr :version, :map, required: true
  attr :include_flex, :boolean, default: false

  def check_panel(assigns) do
    ~H"""
    <.result_section
      id="export-check"
      title="Check for problems"
      lede="Runs the MobilityData GTFS Validator, the standard open-source checker for transit feeds, on this version’s data."
    >
      <div
        id="export-check-body"
        tabindex="-1"
        aria-live="polite"
        class="px-5 py-5 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
      >
        <div :if={@error} class="mb-4">
          <.message
            id="validation-error-panel"
            kind="error"
            title={elem(check_error_copy(@error), 0)}
          >
            {elem(check_error_copy(@error), 1)}
          </.message>
        </div>

        <%= cond do %>
          <% @validating? -> %>
            <div class="flex items-center gap-2.5 text-sm font-semibold text-strong">
              <.icon
                name="hero-arrow-path"
                class="size-4 shrink-0 text-cyan-700 motion-safe:animate-spin"
              />
              <span id="check-phase">{phase_label(@progress.phase)}</span>
            </div>
            <progress
              id="check-progress"
              class="progress progress-info mt-3 w-full"
              value={@progress.percent}
              max="100"
              aria-label="Check progress"
            />
          <% @result -> %>
            <dl id="mobility-summary-metrics" class="grid grid-cols-3 gap-2.5">
              <div
                :for={{key, label, count} <- check_tiles(@result.summary)}
                data-count={key}
                class={["rounded-control border px-3 py-2.5", tile_border(key, count)]}
              >
                <dt class="text-[13px]">{label}</dt>
                <dd class="mt-0.5 font-display text-[28px] font-semibold leading-none tracking-[-0.03em] tabular-nums">
                  {count}
                </dd>
              </div>
            </dl>

            <div class="mt-4">
              <.verdict summary={@result.summary} />
            </div>

            <div class="mt-4 flex flex-wrap gap-2">
              <.button
                id="view-validation-results"
                variant="secondary"
                class="min-h-11 max-sm:flex-1"
                navigate={~p"/gtfs/#{@version.id}/validation/#{@validation_run_id}"}
              >
                View full results
              </.button>
              <.button
                id="reset-validation"
                variant="secondary"
                class="min-h-11 max-sm:flex-1"
                phx-click={JS.push("reset_validation") |> JS.focus(to: "#export-check-body")}
              >
                Check again
              </.button>
            </div>
            <p class="mt-3 text-[13px] leading-relaxed text-muted">
              Checks read this version’s current data, not a downloaded file.
            </p>
          <% true -> %>
            <p :if={is_nil(@error)} class="text-sm leading-relaxed text-default">
              Run a check before you send the file to trip planners, so you hear about problems first.
            </p>
            <div class={[
              "flex flex-wrap items-center gap-2 max-sm:w-full max-sm:[&>*]:flex-1",
              is_nil(@error) && "mt-4"
            ]}>
              <.button
                id="run-validation"
                variant="secondary"
                class="min-h-11"
                phx-click={JS.push("run_validation") |> JS.focus(to: "#export-check-body")}
              >
                {if @error, do: "Try again", else: "Check feed"}
              </.button>
              <.button
                :if={@include_flex}
                id="validate-flex-button"
                variant="secondary"
                class="min-h-11"
                phx-click={JS.push("run_flex_validation") |> JS.focus(to: "#export-check-body")}
              >
                Check flex file
              </.button>
            </div>
        <% end %>
      </div>
    </.result_section>
    """
  end

  defp check_error_copy(:failed),
    do: {"The check couldn’t finish.", "Nothing in your data changed. Try again."}

  defp check_error_copy(:not_started), do: {"The check couldn’t start.", "Try again."}

  defp check_error_copy(:other_organization),
    do: {"This check can’t be shown.", "It belongs to another organization."}

  defp phase_label(:exporting), do: "Packaging your data…"
  defp phase_label(:validating), do: "Running the checker…"
  defp phase_label(:processing), do: "Reading the results…"
  defp phase_label(_phase), do: "Getting ready…"

  defp check_tiles(summary),
    do: [
      {"errors", "Errors", summary.errors},
      {"warnings", "Warnings", summary.warnings},
      {"infos", "Information", summary.infos}
    ]

  # A tile takes its colour only when it has something to report, and always
  # carries its word, so the state never rests on colour alone.
  defp tile_border("errors", count) when count > 0,
    do: "border-error-line bg-error-bg text-error-fg"

  defp tile_border("warnings", count) when count > 0,
    do: "border-warning-line bg-warning-bg text-warning-fg"

  defp tile_border("infos", count) when count > 0, do: "border-subtle bg-white text-strong"
  defp tile_border(_key, _count), do: "border-subtle bg-white text-muted"

  attr :summary, :map, required: true

  # Errors are violations of the GTFS reference, so they get the instruction;
  # warnings are best-practice issues most trip planners still accept.
  defp verdict(%{summary: %{errors: errors}} = assigns) when errors > 0 do
    ~H"""
    <.message id="check-verdict" kind="error" title="Fix the errors before you share this feed.">
      Trip planners may reject a feed that has errors.
    </.message>
    """
  end

  defp verdict(%{summary: %{warnings: warnings}} = assigns) when warnings > 0 do
    ~H"""
    <.message id="check-verdict" kind="warning" title="No errors.">
      Review the {@summary.warnings} {if @summary.warnings == 1, do: "warning", else: "warnings"}. They point to weak spots, but most trip planners still accept the feed.
    </.message>
    """
  end

  defp verdict(assigns) do
    ~H"""
    <.message id="check-verdict" kind="success" title="No errors or warnings.">
      Information notices are optional to review.
    </.message>
    """
  end

  @doc """
  The last five checks of any kind as a list, newest first: what ran, when, and
  what it found. A check is `%{id, title, started_at, path, kind, errors,
  warnings, infos}`; a `:pathways_test` row reports failed, couldn't-be-checked
  and passed instead of the three severities.
  """
  attr :checks, :list, required: true

  def recent_checks(assigns) do
    ~H"""
    <.result_section id="recent-checks" title="Recent checks" lede={recent_summary(@checks)}>
      <ul role="list">
        <li
          :for={check <- @checks}
          id={"recent-check-#{check.id}"}
          class="border-b border-subtle px-2 py-1 last:border-0"
        >
          <.link
            navigate={check.path}
            class="group block rounded-control px-3 py-2 no-underline hover:bg-canvas"
          >
            <span class="block text-sm font-semibold text-action group-hover:underline">
              {check.title}
            </span>
            <span class="mt-0.5 block text-[13px] tabular-nums text-muted">
              {DisplayClock.format_datetime(check.started_at)}
            </span>
            <span
              id={"recent-validation-counts-#{check.id}"}
              class="mt-1 block text-[13px] tabular-nums text-default"
            >
              <%= if check.kind == :pathways_test do %>
                {check.errors} failed · {check.warnings} couldn’t be checked · {check.infos} passed
              <% else %>
                <span class={severity_class(:errors, check.errors)}>
                  {check.errors} {if check.errors == 1, do: "error", else: "errors"}
                </span>
                ·
                <span class={severity_class(:warnings, check.warnings)}>
                  {check.warnings} {if check.warnings == 1, do: "warning", else: "warnings"}
                </span>
                · <span class="text-strong">{check.infos} information</span>
              <% end %>
            </span>
          </.link>
        </li>
      </ul>
    </.result_section>
    """
  end

  defp recent_summary([_only]), do: "The most recent check of this version."

  defp recent_summary(checks) do
    with_errors = Enum.count(checks, &(&1.errors > 0))
    with_warnings = Enum.count(checks, &(&1.warnings > 0))

    "#{with_errors} of the last #{length(checks)} checks reported errors, and #{with_warnings} reported warnings."
  end

  defp severity_class(:errors, count) when count > 0, do: "font-semibold text-error-fg"
  defp severity_class(:warnings, count) when count > 0, do: "font-semibold text-warning-fg"
  defp severity_class(_kind, _count), do: "text-muted"

  @doc """
  One row of the differences list. The list itself is a slot on
  `comparison_results/1`; this is only the row's own markup, so the owning
  template stays the one that iterates the stream.
  """
  attr :dom_id, :string, required: true
  attr :change, :map, required: true

  def comparison_difference_row(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="min-w-0">
        <p class="text-sm font-semibold text-strong">
          {change_kind(@change.kind)} · {route_label(@change.route_ids)}
        </p>
        <p class="mt-0.5 text-[13px] text-muted">
          {change_dates(@change)}
          {if @change.direction_id, do: " · direction #{@change.direction_id}"}
        </p>
        <p :if={@change.reason} class="mt-0.5 text-[13px] text-muted">
          {difference_reason(@change.reason)}
        </p>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <span id={"#{@dom_id}-delta"} class="text-sm font-semibold tabular-nums text-strong">
          {change_delta(@change)}
        </span>
        <.button
          id={"#{@dom_id}-inspect"}
          variant="quiet"
          size="sm"
          phx-click="inspect_comparison_row"
          phx-value-collection={:comparison_differences}
          phx-value-row={@dom_id}
        >
          Inspect
        </.button>
      </div>
    </div>
    """
  end

  @doc "One row of the identifier and presence changes list."
  attr :dom_id, :string, required: true
  attr :change, :map, required: true

  def comparison_structural_row(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="min-w-0">
        <p class="text-sm font-semibold text-strong">
          {structural_title(@change.change)} {@change.entity}
          <span class="font-mono text-[13px]">{@change.id}</span>
        </p>
        <p class="mt-0.5 text-[13px] leading-relaxed text-muted">
          {structural_note(@change.change)}
          {if @change.meaning_changed,
            do: " Its meaning changed, so aligned timing was not claimed."}
        </p>
      </div>
      <.button
        id={"#{@dom_id}-inspect"}
        variant="quiet"
        size="sm"
        phx-click="inspect_comparison_row"
        phx-value-collection={:comparison_structural}
        phx-value-row={@dom_id}
      >
        Inspect
      </.button>
    </div>
    """
  end

  @doc "One row of the unresolved entity matches list."
  attr :dom_id, :string, required: true
  attr :entry, :map, required: true

  def comparison_unresolved_row(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="min-w-0">
        <p class="text-sm font-semibold text-strong">
          {@entry.entity} · {unresolved_reason(@entry.reason)}
        </p>
        <p class="mt-0.5 font-mono text-[13px] leading-relaxed text-muted">
          {unresolved_refs(@entry)}
        </p>
      </div>
      <.button
        id={"#{@dom_id}-inspect"}
        variant="quiet"
        size="sm"
        phx-click="inspect_comparison_row"
        phx-value-collection={:comparison_unresolved}
        phx-value-row={@dom_id}
      >
        Inspect
      </.button>
    </div>
    """
  end

  @doc "One row of the rows this comparison could not read list."
  attr :dom_id, :string, required: true
  attr :unknown, :map, required: true

  def comparison_unknown_row(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="min-w-0">
        <p class="text-sm font-semibold text-strong">
          {side_label(@unknown.side)} file · {unknown_reason(@unknown.reason)}
        </p>
        <p class="mt-0.5 text-[13px] leading-relaxed text-muted">{@unknown.detail}</p>
        <p
          :if={@unknown[:source] && @unknown.source[:file]}
          class="mt-0.5 font-mono text-[13px] text-muted"
        >
          {@unknown.source.file} row {@unknown.source.row}
        </p>
      </div>
      <.button
        id={"#{@dom_id}-inspect"}
        variant="quiet"
        size="sm"
        phx-click="inspect_comparison_row"
        phx-value-collection={:comparison_unknowns}
        phx-value-row={@dom_id}
      >
        Inspect
      </.button>
    </div>
    """
  end
end
