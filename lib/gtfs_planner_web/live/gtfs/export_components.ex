defmodule GtfsPlannerWeb.Gtfs.ExportComponents do
  @moduledoc """
  The Export page's presentation, on the application design system.

  One card walks the task in order: choose what to export (`type_options/1`),
  see what goes in the file (`contents/1`), then act on the latest file
  (`run_status/1`). The status band is the only place the page changes state and
  holds the page's one primary action, so which control is primary follows the
  latest run: Export feed, Download file, Retry export, Export again, or, when a
  garage ID clashes with a stop ID, Edit garages. `guide/1` says what to do with
  the file, and the right column holds the feed check (`check_panel/1`) and its
  history (`recent_checks/1`).

  The components carry no state and run no queries: `ExportLive` owns the events
  and the data, and passes the latest `Export.Run`, the file inventory and the
  check's state in.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.ResultComponents, only: [result_section: 1]

  alias GtfsPlanner.Gtfs.Export.Run
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
      |> assign(:garages, format_count(Map.get(counts, "stops_supplement.txt", 0)))
      |> assign(:vehicles, format_count(Map.get(counts, "vehicles.txt", 0)))

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
            {format_count(count)}
          </dd>
        </div>
      </dl>

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
                  {format_count(count)}<span :if={count == 0} class="ml-2 text-[13px]">left out</span>
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
        </div>
      </div>

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
      run.finished_at && "Created #{format_time(run.finished_at)}",
      run.artifact_expires_at && "Available until #{format_time(run.artifact_expires_at)}"
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
              {format_time(check.started_at)}
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

  # Times are stored in UTC and the app has no per-user time zone, so the zone is
  # named instead of implied.
  defp format_time(%DateTime{} = time),
    do: Calendar.strftime(time, "%b %-d, %Y %-I:%M %p") <> " UTC"

  defp format_count(count),
    do: count |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
end
