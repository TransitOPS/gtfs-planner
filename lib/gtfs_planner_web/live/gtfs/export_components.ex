defmodule GtfsPlannerWeb.Gtfs.ExportComponents do
  @moduledoc """
  The Export page's presentation, on the application design system.

  The Export page's presentation, on the application design system.

  The page's one card is `new_file/1`: a grouped kind choice, what the chosen
  file contains (`contents/1`, including the async operations preview), and the
  single action that starts the build. The right column holds the feed check
  (`check_panel/1`) and its history (`recent_checks/1`).

  `run_status/1` and `guide/1` are isolated compatibility components kept for
  their own tests; the Export page no longer renders them.

  The components carry no state and run no queries: `ExportLive` owns the events
  and the data, and passes the latest `Export.Run`, the file inventory, the
  operations preview and the check's state in.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.Gtfs.FeedPublicationComponents, only: [publish_action: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.ResultComponents, only: [result_section: 1]

  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Export.Run
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
      label: "Station pathways",
      description: "Stops, levels and pathways. Not a complete feed on its own.",
      format: "GTFS pathways files"
    },
    operations: %{
      label: "Full feed with operations data",
      description: "The full feed plus garages, vehicles and runs, in one file. Keep it private.",
      format: "GTFS + operations (TODS)"
    },
    operations_only: %{
      label: "Operations data only",
      description:
        "Garages, vehicles and runs, keyed to this version. Not a feed by itself. Keep it private.",
      format: "TODS"
    }
  ]

  @trip_planner_types [:full, :pathways]
  @vendor_types [:operations, :operations_only]

  @export_cta %{
    full: "Export full feed",
    pathways: "Export station pathways",
    operations: "Export feed with operations",
    operations_only: "Export operations data"
  }

  @doc """
  The New file card: choose what kind of file to build, read what it contains,
  and start the build with the card's one action.

  The card owns the page's single `#gtfs-export-form`, so the footer's
  `#start-export` is the form's own submit and the radio group, the contents and
  the action all describe the same chosen draft. Selecting a kind patches the
  URL through the form's own `phx-change`; the server owns the selected type.

  The action is busy only while the selected kind's run is pending, building or
  cancelling; every other state leaves it enabled.
  """
  attr :form, :any, required: true
  attr :export_type, :atom, required: true
  attr :operations?, :boolean, required: true
  attr :version, :map, required: true
  attr :file_inventory, :list, required: true
  attr :operations_preview, :any, required: true
  attr :missing_summary, :any, default: nil
  attr :defaults, :map, default: nil
  attr :run, :any, default: nil
  attr :notice, :string, default: nil
  attr :closure_count, :integer, default: 0

  def new_file(assigns) do
    assigns =
      assigns
      |> assign(:busy?, operations_run_busy?(assigns.run))
      |> assign(:cta_label, Map.fetch!(@export_cta, assigns.export_type))

    ~H"""
    <.form for={@form} id="gtfs-export-form" phx-change="select_export_type">
      <section
        id="export-new-file"
        aria-labelledby="new-h"
        class="overflow-hidden rounded-card border border-subtle bg-white"
      >
        <div class="px-5 pb-0 pt-5">
          <h2 id="new-h" class="text-base font-bold text-strong">New file</h2>
        </div>

        <.type_options form={@form} export_type={@export_type} operations?={@operations?} />

        <.closures_omitted
          :if={@export_type == :pathways and @closure_count > 0}
          count={@closure_count}
        />

        <.contents
          export_type={@export_type}
          file_inventory={@file_inventory}
          operations_preview={@operations_preview}
          missing_summary={@missing_summary}
          defaults={@defaults}
          version_id={@version.id}
          version={@version}
        />

        <footer class="flex flex-wrap items-center gap-3 border-t border-subtle bg-canvas px-5 py-4">
          <div :if={@notice} class="w-full">
            <.message id="export-notice" kind="error" title={@notice} />
          </div>
          <.button
            id="start-export"
            type="button"
            phx-click="start_export"
            class="min-h-11"
            disabled={@busy?}
          >
            {if @busy?, do: "Exporting…", else: @cta_label}
          </.button>
          <span :if={@busy?} class="text-[13px] text-muted">
            This file is being built. It appears in Files below.
          </span>
        </footer>
      </section>
    </.form>
    """
  end

  defp operations_run_busy?(%{state: state}) when state in [:pending, :building], do: true
  defp operations_run_busy?(_run), do: false

  @doc """
  The export kind, split into the two audiences the prototype names: files for
  trip planners, and files for a CAD/AVL or scheduling vendor. The vendor group
  and its Private tag appear only when the organization's product offers the
  operations export.

  One radio name spans both fieldsets, so the kinds are one choice.
  """
  attr :form, :any, required: true
  attr :export_type, :atom, required: true
  attr :operations?, :boolean, required: true

  def type_options(assigns) do
    assigns =
      assigns
      |> assign(:trip_planner_options, Enum.map(@trip_planner_types, &{&1, @type_options[&1]}))
      |> assign(:vendor_options, Enum.map(@vendor_types, &{&1, @type_options[&1]}))

    ~H"""
    <div class="grid gap-4 px-5 pt-4">
      <fieldset id="export-type-group-trip-planners" class="min-w-0">
        <legend class="text-[13px] font-semibold text-strong">For trip planners</legend>
        <div class="mt-2.5 grid gap-3 sm:grid-cols-2">
          <.type_card
            :for={{type, option} <- @trip_planner_options}
            form={@form}
            type={type}
            option={option}
            export_type={@export_type}
          />
        </div>
      </fieldset>

      <fieldset :if={@operations?} id="export-type-group-vendor" class="min-w-0">
        <legend class="flex items-center gap-2 text-[13px] font-semibold text-strong">
          For your CAD/AVL or scheduling vendor
          <span class="inline-flex items-center gap-1 rounded-full bg-warning-bg px-2 py-0.5 text-[12px] font-semibold text-warning-fg">
            <.icon name="hero-lock-closed" class="size-3" /> Private
          </span>
        </legend>
        <div class="mt-2.5 grid gap-3 sm:grid-cols-2">
          <.type_card
            :for={{type, option} <- @vendor_options}
            form={@form}
            type={type}
            option={option}
            export_type={@export_type}
          />
        </div>
      </fieldset>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :type, :atom, required: true
  attr :option, :map, required: true
  attr :export_type, :atom, required: true

  defp type_card(assigns) do
    ~H"""
    <label class="relative flex min-h-11 cursor-pointer gap-3 rounded-control border border-control bg-white px-4 py-3.5 hover:bg-canvas has-[:checked]:border-action has-[:checked]:bg-selection has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus">
      <input
        type="radio"
        id={"export-type-#{@type}"}
        name={@form[:type].name}
        value={@type}
        checked={@export_type == @type}
        class="mt-0.5 size-[18px] shrink-0 accent-action focus-visible:outline-0"
      />
      <span class="min-w-0">
        <span class="block text-sm font-bold text-strong">{@option.label}</span>
        <span class="mt-1 block text-[13px] leading-relaxed text-default">
          {@option.description}
        </span>
        <span class="mt-1.5 block text-[13px] text-muted">{@option.format}</span>
      </span>
    </label>
    """
  end

  @doc """
  Says that a Pathways export leaves out the version's scheduled closures.

  Only the Pathways profile can omit closures, so only that selection carries it.
  The warning uses the shared callout treatment and its action switches to Full.
  """
  attr :count, :integer, required: true

  def closures_omitted(assigns) do
    ~H"""
    <div class="px-5 pt-4">
      <.callout
        id="export-pathways-closures-omitted"
        kind="warning"
        title={"#{@count} #{if @count == 1, do: "scheduled closure is", else: "scheduled closures are"} left out."}
      >
        <p>The full feed includes them.</p>
        <.button
          id="export-choose-full"
          variant="secondary"
          class="mt-2 min-h-11"
          phx-click={
            JS.push("select_export_type", value: %{"export" => %{"type" => "full"}})
            |> JS.focus(to: "#export-type-full")
          }
        >
          Choose full feed
        </.button>
      </.callout>
    </div>
    """
  end

  @doc """
  What the chosen file contains: joined tiles for each thing it counts, the
  compact defaults rows for the kinds that carry GTFS, and the full inventory.

  Operations tiles and operations inventory entries come only from
  `Export.operations_preview/2`. While that async read is loading the tiles are
  skeletons; a failed read says `Couldn’t count` and never disables the export.
  A combined Operations file merges the preview into the Full base inventory; an
  Operations-only file is the preview inventory on its own.
  """
  attr :export_type, :atom, required: true
  attr :file_inventory, :list, required: true
  attr :operations_preview, :any, default: nil
  attr :missing_summary, :any, default: nil
  attr :defaults, :map, default: nil
  attr :version_id, :any, required: true
  attr :version, :map, required: true

  def contents(assigns) do
    base = assigns.file_inventory
    preview = operations_state(assigns.operations_preview)

    {inventory_status, inventory} = contents_inventory(assigns.export_type, base, preview)
    included = Enum.count(inventory, fn {_file, count} -> count > 0 end)
    left_out = length(inventory) - included

    assigns =
      assigns
      |> assign(:version_label, version_label(assigns.version))
      |> assign(:inventory_status, inventory_status)
      |> assign(:inventory, inventory)
      |> assign(:included, included)
      |> assign(:left_out, left_out)
      |> assign(:tiles, contents_tiles(assigns.export_type, base, preview, assigns.version_id))

    ~H"""
    <div id="export-contents" class="px-5 pb-5 pt-5">
      <h3 class="text-[13px] font-semibold text-strong">
        In this file <span class="font-normal text-muted">· {@version_label}</span>
      </h3>

      <dl
        id="export-metrics"
        class={[
          "mt-2.5 grid grid-cols-2 gap-px overflow-hidden rounded-control border border-subtle bg-subtle",
          tile_columns(length(@tiles))
        ]}
      >
        <div :for={tile <- @tiles} id={"export-tile-#{tile.key}"} class="bg-white px-4 py-2">
          <dt class="text-[13px] text-muted">{tile.label}</dt>
          <dd class="mt-0.5 font-display text-[26px] font-semibold leading-none tracking-[-0.03em] tabular-nums">
            <%= case tile.value do %>
              <% {:count, count} -> %>
                <span class={if count > 0, do: "text-strong", else: "text-muted"}>
                  {Wording.count(count)}
                </span>
              <% :loading -> %>
                <span id={"export-tile-#{tile.key}-loading"} class="text-muted">—</span>
              <% :error -> %>
                <span
                  id={"export-tile-#{tile.key}-error"}
                  class="text-[13px] font-semibold text-warning-fg"
                >
                  Couldn’t count
                </span>
              <% :no_run_work -> %>
                <span class="text-[13px] font-normal text-muted">No run work to reconcile</span>
            <% end %>
          </dd>
          <p :if={tile[:note]} class="mt-1">
            <.link
              id={"export-tile-#{tile.key}-note"}
              navigate={tile.note.path}
              class="text-[12px] font-semibold text-action hover:underline"
            >
              {tile.note.label}
            </.link>
          </p>
        </div>
      </dl>

      <dl
        :if={@export_type in [:full, :operations]}
        id="export-defaults"
        class="mt-4 grid gap-1.5 border-t border-subtle pt-4 text-[13px]"
      >
        <div class="flex items-baseline justify-between gap-6">
          <dt class="text-muted">Missing stop times</dt>
          <dd id="export-missing-times" class="flex min-w-0 items-baseline gap-4 text-right">
            <span class="text-strong">{missing_times_label(@missing_summary, @defaults)}</span>
            <.link
              id="export-missing-times-link"
              navigate={~p"/gtfs/#{@version_id}/settings/export-defaults"}
              class="shrink-0 font-semibold text-action hover:underline"
            >
              Change
            </.link>
          </dd>
        </div>
        <div class="flex items-baseline justify-between gap-6">
          <dt class="text-muted">Flex services</dt>
          <dd id="export-flex-defaults" class="flex min-w-0 items-baseline gap-4 text-right">
            <span class="text-strong">{flex_label(@defaults)}</span>
            <.link
              id="export-flex-change"
              navigate={~p"/gtfs/#{@version_id}/settings/export-defaults"}
              class="shrink-0 font-semibold text-action hover:underline"
            >
              Change
            </.link>
          </dd>
        </div>
      </dl>

      <details
        id="export-files"
        phx-mounted={JS.ignore_attributes("open")}
        class="group mt-3 rounded-control border border-subtle"
      >
        <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 rounded-control px-4 text-sm font-semibold text-strong hover:bg-canvas [&::-webkit-details-marker]:hidden">
          <%= case @inventory_status do %>
            <% :ready -> %>
              <span>
                {@included} {if @included == 1, do: "file", else: "files"} in the ZIP
                <span class="font-normal text-muted">
                  · {if @left_out > 0,
                    do:
                      "#{@left_out} empty #{if @left_out == 1, do: "table", else: "tables"} left out",
                    else: "nothing left out"}
                </span>
              </span>
            <% :loading -> %>
              <span id="export-inventory-counting">Counting files in the ZIP…</span>
            <% :error -> %>
              <span id="export-inventory-count-unavailable">File count unavailable</span>
          <% end %>
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
          <table
            :if={@inventory_status == :ready and @inventory != []}
            class="w-full border-collapse text-left text-sm"
          >
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
                :for={{filename, count} <- @inventory}
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
            :if={@inventory_status == :ready and @inventory == []}
            id="export-empty-inventory"
            class="px-4 py-3 text-sm text-muted"
          >
            This export type has no tables to package yet.
          </p>
          <p
            :if={@inventory_status == :loading}
            id="export-inventory-loading"
            class="px-4 py-3 text-sm text-muted"
          >
            Counting the files and records for this export…
          </p>
          <p
            :if={@inventory_status == :error}
            id="export-inventory-unavailable"
            class="px-4 py-3 text-sm text-muted"
          >
            The file inventory couldn’t be counted. You can still export this file.
          </p>
        </div>

        <p class="border-t border-subtle px-4 py-3 text-[13px] leading-relaxed text-muted">
          Diagram, level and image data is added to the ZIP as extra files when it exists, and isn’t listed here.
        </p>
      </details>
    </div>
    """
  end

  defp version_label(%{name: name}) when is_binary(name) and name != "",
    do: "#{name} as it is now"

  defp version_label(_version), do: "this version as it is now"

  defp flex_label(%{include_flex: true}), do: "Separate flex file"
  defp flex_label(_defaults), do: "Not included"

  defp operations_state(%{loading: true}), do: :loading
  defp operations_state(%{ok?: true, result: result}), do: {:ok, result}
  defp operations_state(_other), do: :error

  defp contents_inventory(:operations_only, _base, {:ok, preview}), do: {:ready, preview.files}
  defp contents_inventory(:operations_only, _base, :loading), do: {:loading, []}
  defp contents_inventory(:operations_only, _base, :error), do: {:error, []}

  defp contents_inventory(:operations, base, {:ok, preview}),
    do: {:ready, merge_inventory(base, preview.files)}

  defp contents_inventory(:operations, _base, :loading), do: {:loading, []}
  defp contents_inventory(:operations, _base, :error), do: {:error, []}
  defp contents_inventory(_kind, base, _preview), do: {:ready, base}

  defp merge_inventory(base, extra) do
    (base ++ extra)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {file, counts} -> {file, Enum.max(counts)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp contents_tiles(:full, base, _preview, _version_id), do: base_tiles(tiles(:full), base)

  defp contents_tiles(:pathways, base, _preview, _version_id),
    do: base_tiles(tiles(:pathways), base)

  defp contents_tiles(:operations, base, preview, version_id) do
    base_tiles([{"Routes", "routes.txt"}, {"Trips", "trips.txt"}], base) ++
      preview_tiles(:operations, preview, version_id)
  end

  defp contents_tiles(:operations_only, _base, preview, version_id),
    do: preview_tiles(:operations_only, preview, version_id)

  defp base_tiles(specs, base) do
    counts = Map.new(base)

    Enum.map(specs, fn {label, file} ->
      %{key: file, label: label, value: {:count, Map.get(counts, file, 0)}}
    end)
  end

  defp preview_tiles(kind, state, version_id) do
    Enum.map(preview_tile_specs(kind), fn tile ->
      tile
      |> Map.put(:value, preview_tile_value(tile, state))
      |> Map.put(:note, preview_tile_note(tile, state, version_id))
    end)
  end

  defp preview_tile_specs(:operations_only) do
    [
      %{key: "garages", label: "Garages", source: {:file, "stops_supplement.txt"}},
      %{key: "vehicles", label: "Vehicles", source: {:file, "vehicles.txt"}},
      %{key: "runs", label: "Runs", source: {:field, :runs}},
      %{key: "trips_in_run", label: "Trips in a run", source: {:field, :trips_in_run}}
    ]
  end

  defp preview_tile_specs(:operations) do
    [
      %{key: "garages", label: "Garages", source: {:file, "stops_supplement.txt"}},
      %{key: "vehicles", label: "Vehicles", source: {:file, "vehicles.txt"}},
      %{key: "trips_in_run", label: "Trips in a run", source: {:field, :trips_in_run}}
    ]
  end

  defp preview_tile_value(_tile, :loading), do: :loading
  defp preview_tile_value(_tile, :error), do: :error

  defp preview_tile_value(%{source: {:file, file}}, {:ok, preview}),
    do: {:count, preview_file_count(preview, file)}

  defp preview_tile_value(%{source: {:field, :runs}}, {:ok, preview}), do: {:count, preview.runs}

  defp preview_tile_value(%{source: {:field, :trips_in_run}}, {:ok, preview}) do
    if preview.runs == 0 and preview.trips_in_run == 0,
      do: :no_run_work,
      else: {:count, preview.trips_in_run}
  end

  defp preview_file_count(preview, file), do: preview.files |> Map.new() |> Map.get(file, 0)

  # A tile's note is the one thing that tile is missing, so the reader is sent
  # to the page that fixes it. Zero garages or vehicles, and trips no run
  # covers, each point at their own version-scoped page.
  defp preview_tile_note(%{key: "garages"}, {:ok, preview}, version_id) do
    if preview_file_count(preview, "stops_supplement.txt") == 0,
      do: %{label: "Manage garages", path: ~p"/gtfs/#{version_id}/settings/garages"},
      else: nil
  end

  defp preview_tile_note(%{key: "vehicles"}, {:ok, preview}, version_id) do
    if preview_file_count(preview, "vehicles.txt") == 0,
      do: %{label: "Add vehicles", path: ~p"/gtfs/#{version_id}/settings/fleet"},
      else: nil
  end

  defp preview_tile_note(%{key: "trips_in_run"}, {:ok, preview}, version_id) do
    gap = preview.trips_total - preview.trips_in_run

    if gap > 0 and preview.trips_total > 0,
      do: %{
        label: "#{gap} of #{preview.trips_total} not in a run",
        path: ~p"/gtfs/#{version_id}/runs"
      },
      else: nil
  end

  defp preview_tile_note(_tile, _state, _version_id), do: nil

  defp missing_times_label(%{loading: true}, _defaults), do: "Counting missing stop times…"

  defp missing_times_label(
         %{ok?: true, result: summary},
         %{estimate_missing_times: true} = defaults
       ),
       do: estimate_sentence(summary, defaults)

  defp missing_times_label(%{ok?: true, result: summary}, _defaults), do: blank_sentence(summary)
  defp missing_times_label(_summary, _defaults), do: "Not available"

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
      {"Calendars", "calendar.txt"}
    ]

  defp tiles(:pathways),
    do: [
      {"Stations", "stops.txt"},
      {"Levels", "levels.txt"},
      {"Pathways", "pathways.txt"}
    ]

  defp tile_columns(3), do: "sm:grid-cols-3"
  defp tile_columns(4), do: "sm:grid-cols-4"
  defp tile_columns(5), do: "sm:grid-cols-5"

  @doc """
  The Files card: every retained run of this version, newest first, kept for 24
  hours. Rows are the live `:files` stream, each with a stable
  `export-file-<id>` id, so a run's row can be replaced in place.
  """
  attr :empty?, :boolean, default: true
  attr :has_more?, :boolean, default: false
  attr :notice, :string, default: nil
  attr :finished_run, :any, default: nil
  attr :clash_run, :any, default: nil
  attr :version, :map, required: true
  slot :files_list, required: true

  def files_card(assigns) do
    ~H"""
    <section
      id="export-files-card"
      aria-labelledby="files-h"
      class="min-w-0 max-w-full rounded-card border border-subtle bg-white"
    >
      <.finished_band :if={@finished_run} run={@finished_run} version={@version} />

      <div class="flex items-center justify-between px-5 pt-5">
        <h2 id="files-h" class="text-base font-bold text-strong">Files</h2>
        <p class="text-[13px] text-muted">Kept for 24 hours</p>
      </div>

      <p
        :if={@notice}
        id="export-files-notice"
        role="status"
        class="px-5 pt-3 text-[13px] font-semibold text-strong"
      >
        {@notice}
      </p>

      <div
        :if={@clash_run}
        id="export-garage-clash"
        class="mx-5 mt-3 rounded-card border border-error-line bg-error-bg px-4 py-3.5 text-error-fg"
      >
        <p class="text-sm font-semibold">Garage IDs clash with stop IDs.</p>
        <ul id="export-garage-clash-details" class="mt-2 grid gap-3 text-sm">
          <li
            :for={warning <- conflict_warnings(@clash_run)}
            class="border-l-2 border-error-line pl-3"
          >
            {warning_detail(warning)}
          </li>
        </ul>
        <.link
          id="export-edit-garages"
          navigate={~p"/gtfs/#{@version.id}/settings/garages"}
          class="mt-2 inline-flex min-h-11 items-center font-semibold underline"
        >
          Edit garages
        </.link>
      </div>

      <div
        :if={!@empty?}
        id="export-files-scroll"
        class="mt-3 max-w-full overflow-x-auto"
      >
        <table
          id="export-files-rows"
          phx-update="stream"
          class="w-full min-w-[760px] border-collapse text-left text-sm"
        >
          <thead id="export-files-head">
            <tr id="export-files-head-row">
              <th
                scope="col"
                class="border-b border-subtle px-5 py-2.5 text-[13px] font-[650] text-default"
              >
                File
              </th>
              <th
                scope="col"
                class="border-b border-subtle px-5 py-2.5 text-[13px] font-[650] text-default"
              >
                Created
              </th>
              <th
                scope="col"
                class="border-b border-subtle px-5 py-2.5 text-[13px] font-[650] text-default"
              >
                Status
              </th>
              <th
                scope="col"
                class="border-b border-subtle px-5 py-2.5 text-right text-[13px] font-[650] text-default"
              >
                Actions
              </th>
            </tr>
          </thead>
          {render_slot(@files_list)}
        </table>
      </div>

      <div
        :if={@empty?}
        id="export-files-empty"
        class="m-5 mt-3 rounded-card border border-dashed border-control bg-canvas px-5 py-8 text-center"
      >
        <.icon name="hero-document" class="mx-auto size-7 text-muted" />
        <p class="mt-2 text-sm font-semibold text-strong">No files from the last 24 hours</p>
        <p class="mt-1 text-[13px] text-muted">
          Files you export appear here to download, publish or compare.
        </p>
      </div>

      <div :if={@has_more?} class="border-t border-subtle px-5 py-3">
        <.button
          id="load-more-files"
          type="button"
          phx-click="load_more_files"
          variant="secondary"
          class="min-h-11"
        >
          Show more files
        </.button>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".FileMenu">
        export default {
          mounted() {
            this.el.addEventListener("keydown", (event) => {
              if (event.key === "Escape") this.el.removeAttribute("open")
            })
          }
        }
      </script>
    </section>
    """
  end

  @doc "One Files row: identity, created time, status and the scoped action."
  attr :dom_id, :string, required: true
  attr :run, :map, required: true
  attr :version, :map, required: true
  attr :match, :any, default: nil
  attr :open?, :boolean, default: false
  attr :defaults, :map, default: nil
  attr :full_current?, :boolean, default: false

  def file_row(assigns) do
    ~H"""
    <tbody id={@dom_id} class="border-b border-subtle last:border-0">
      <tr>
        <th scope="row" class="px-5 py-3 align-top font-normal">
          <span class="font-semibold text-strong">{file_label(@run)}</span>
          <span
            :if={@run.export_type in [:operations, :operations_only]}
            class="ml-2 rounded-full bg-warning-bg px-2 py-0.5 text-[12px] font-semibold text-warning-fg"
          >
            Private
          </span>
          <span :if={@run.state == :ready} class="mt-0.5 block font-mono text-[12px] text-muted">
            {ready_file_meta(@run)}
          </span>
        </th>
        <td class="px-5 py-3 align-top text-[13px] tabular-nums text-muted">
          <span class="block">{DisplayClock.format_datetime(@run.inserted_at)}</span>
          <span :if={@run.state == :ready} class="mt-0.5 block text-[12px]">
            Until {DisplayClock.format_datetime(@run.artifact_expires_at)}
          </span>
        </td>
        <td class="px-5 py-3 align-top text-[13px] text-default">
          <%= if @run.state == :building and is_nil(@run.cancel_requested_at) do %>
            <span class="block font-semibold text-strong">Building…</span>
            <span class="mt-1 block text-[12px] text-muted">
              Started {DisplayClock.format_datetime(@run.started_at || @run.inserted_at)}
            </span>
            <progress
              id={"#{@dom_id}-progress"}
              class="progress progress-info mt-1.5 block h-1.5 w-full"
              aria-label="Build progress"
            />
          <% else %>
            <.file_status_cell run={@run} dom_id={@dom_id} open?={@open?} />
          <% end %>
        </td>
        <td class="px-5 py-3 align-top text-right">
          <span class="inline-flex items-center gap-2">
            <.file_actions run={@run} version={@version} />
            <.file_menu :if={file_menu?(@run)} run={@run} version={@version} />
          </span>
        </td>
      </tr>

      <tr :if={@open? and ready_warnings?(@run)}>
        <td colspan="4" class="px-5 pb-4">
          <div id={"#{@dom_id}-warnings-detail"} class="grid gap-2">
            <.warning_group
              :for={group <- warning_groups(@run.warnings)}
              group={group}
              version={@version}
            />
            <p class="mt-1 text-[12px] text-muted">{made_with(@run)}</p>
            <p
              :if={stale_missing_times?(@run, @defaults)}
              id={"#{@dom_id}-stale-settings"}
              class="text-[12px] text-muted"
            >
              {stale_detail(@run, @defaults)}
            </p>
          </div>
        </td>
      </tr>

      <tr :if={@match}>
        <td colspan="4" class="px-5 pb-4">
          <.match_line
            id={"#{@dom_id}-match"}
            match={@match}
            full_current?={@full_current?}
          />
        </td>
      </tr>
    </tbody>
    """
  end

  attr :run, :map, required: true
  attr :dom_id, :string, required: true
  attr :open?, :boolean, required: true

  defp file_status_cell(assigns) do
    ~H"""
    <%= if @run.state == :ready and ready_warnings?(@run) do %>
      <button
        type="button"
        id={"#{@dom_id}-warnings"}
        phx-click="toggle_file_warnings"
        phx-value-run={@run.id}
        aria-expanded={to_string(@open?)}
        class="inline-flex min-h-9 items-center gap-1.5 rounded-full border border-control px-3 text-[13px] font-semibold text-strong hover:bg-canvas"
      >
        <.icon
          name="hero-chevron-down"
          class={["size-3.5 transition-transform", @open? && "rotate-180"]}
        />
        {length(@run.warnings || [])} warnings
      </button>
    <% else %>
      {file_status(@run)}
    <% end %>
    """
  end

  defp ready_warnings?(%{state: :ready, warnings: warnings}), do: warnings not in [nil, []]
  defp ready_warnings?(_run), do: false

  attr :group, :map, required: true
  attr :version, :map, required: true

  defp warning_group(assigns) do
    assigns = assign(assigns, :fix, warning_fix(assigns.group, assigns.version))

    ~H"""
    <div class="rounded-r-card border-l-4 border-warning-line bg-warning-bg/40 px-4 py-3">
      <p class="text-sm font-semibold text-strong">
        {warning_group_title(@group)}
        <span class="font-normal text-muted">· {length(@group.warnings)} warnings</span>
      </p>
      <p class="mt-0.5 text-[13px] text-default">{warning_group_detail(@group)}</p>
      <p class="mt-0.5 font-mono text-[12px] text-muted">{@group.code}</p>
      <.link
        :if={@fix}
        id={"warning-fix-#{@group.code}"}
        navigate={elem(@fix, 1)}
        class="mt-1 inline-flex min-h-9 items-center text-[13px] font-semibold text-action underline"
      >
        {elem(@fix, 0)}
      </.link>
    </div>
    """
  end

  defp warning_groups(warnings) do
    warnings
    |> Enum.group_by(&warning_code/1)
    |> Enum.map(fn {code, grouped} -> %{code: code, warnings: grouped} end)
  end

  defp warning_group_title(%{code: "tods_runs_uncovered", warnings: warnings}) do
    case uncovered_trip_total(warnings) do
      0 -> "Some trips are not in a run"
      total -> "#{total} trips are not in a run"
    end
  end

  defp warning_group_title(%{code: "tods_file_omitted", warnings: warnings}) do
    if Enum.any?(warnings, &(warning_detail(&1) =~ "vehicles.txt")),
      do: "vehicles.txt was not included",
      else: "A file was not included"
  end

  defp warning_group_title(%{code: "garage_stop_id_conflict"}),
    do: "Garage IDs clash with stop IDs"

  defp warning_group_title(%{code: code}),
    do: code |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp warning_group_detail(%{warnings: [first | _]}), do: warning_detail(first)

  defp uncovered_trip_total(warnings) do
    warnings
    |> Enum.map(fn warning ->
      case Regex.run(~r/^(\d+) trips are not in a run/, warning_detail(warning)) do
        [_, count] -> String.to_integer(count)
        _no_match -> 0
      end
    end)
    |> Enum.sum()
  end

  defp warning_fix(%{code: "tods_runs_uncovered"}, version),
    do: {"Open runs", ~p"/gtfs/#{version.id}/runs"}

  defp warning_fix(%{code: "tods_file_omitted", warnings: warnings}, version) do
    if Enum.any?(warnings, &(warning_detail(&1) =~ "vehicles.txt")),
      do: {"Manage fleet", ~p"/gtfs/#{version.id}/settings/fleet"}
  end

  defp warning_fix(%{code: "garage_stop_id_conflict"}, version),
    do: {"Manage garages", ~p"/gtfs/#{version.id}/settings/garages"}

  defp warning_fix(_group, _version), do: nil

  defp made_with(run) do
    parts = [missing_times_made_with(run) | flex_made_with(run)]
    "Made with: " <> Enum.join(parts, " · ")
  end

  defp missing_times_made_with(run) do
    case recorded_missing_times(run) do
      "Estimated by distance along the path" ->
        "missing stop times estimated by distance along the path"

      "Estimated by equal time per stop" ->
        "missing stop times estimated by equal time per stop"

      _other ->
        "missing stop times left blank"
    end
  end

  defp flex_made_with(%{flex_artifact_key: key}) when is_binary(key),
    do: ["flex services in a separate file"]

  defp flex_made_with(_run), do: []

  attr :id, :string, required: true
  attr :match, :any, required: true
  attr :full_current?, :boolean, required: true

  defp match_line(assigns) do
    {tone, icon, text} = match_copy(assigns.match, assigns.full_current?)
    assigns = assign(assigns, tone: tone, icon: icon, text: text)

    ~H"""
    <p id={@id} class={["flex items-start gap-1.5 text-[13px] font-semibold", @tone]}>
      <.icon name={@icon} class="mt-0.5 size-3.5 shrink-0" />
      <span>{@text}</span>
    </p>
    """
  end

  defp match_copy({:published, run}, _full_current?),
    do:
      {"text-success-fg", "hero-check",
       "Matches the published full feed #{run.artifact_filename}"}

  defp match_copy({:file, run}, _full_current?),
    do: {"text-success-fg", "hero-check", "Matches #{run.artifact_filename}"}

  defp match_copy(:published_unknown, _full_current?) do
    {"text-warning-fg", "hero-exclamation-triangle",
     "No full feed from the last 24 hours matches. The published feed can't be checked because it was published before matching was added."}
  end

  defp match_copy(:none, true),
    do:
      {"text-warning-fg", "hero-exclamation-triangle",
       "Doesn't match the published feed or any full feed from the last 24 hours"}

  defp match_copy(:none, false),
    do:
      {"text-warning-fg", "hero-exclamation-triangle",
       "Doesn't match any full feed from the last 24 hours"}

  attr :run, :map, required: true
  attr :version, :map, required: true

  defp file_actions(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2">
      <.link
        :if={@run.state == :ready}
        id={"export-file-#{@run.id}-download"}
        navigate={~p"/gtfs/#{@version.id}/export-runs/#{@run.id}/download"}
        class="inline-flex min-h-11 items-center gap-1.5 whitespace-nowrap rounded-control border border-control px-3 text-[13px] font-semibold text-action hover:bg-canvas"
      >
        <.icon name="hero-arrow-down-tray" class="size-4" /> Download file
      </.link>
      <.button
        :if={@run.state in [:pending, :building]}
        type="button"
        phx-click="cancel_file"
        phx-value-run={@run.id}
        variant="quiet"
        size="sm"
      >
        Cancel
      </.button>
      <.button
        :if={@run.state in [:failed, :interrupted, :cancelled, :expired]}
        type="button"
        phx-click={if @run.state == :failed, do: "retry_file", else: "export_again_file"}
        phx-value-run={@run.id}
        variant="quiet"
        size="sm"
      >
        {if @run.state == :failed, do: "Retry export", else: "Export again"}
      </.button>
    </span>
    """
  end

  defp file_menu?(%{state: :ready} = run),
    do: not is_nil(run.flex_artifact_key) or run.export_type == :full

  defp file_menu?(_run), do: false

  attr :run, :map, required: true
  attr :version, :map, required: true

  defp file_menu(assigns) do
    ~H"""
    <details
      id={"export-file-#{@run.id}-menu"}
      phx-hook=".FileMenu"
      class="relative inline-block text-left"
    >
      <summary
        aria-label="More actions"
        class="inline-flex size-11 cursor-pointer list-none items-center justify-center rounded-control border border-control text-default hover:bg-canvas [&::-webkit-details-marker]:hidden"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
      </summary>
      <div class="absolute right-0 z-20 mt-1 min-w-44 rounded-control border border-subtle bg-white py-1 shadow-lg">
        <.link
          :if={@run.state == :ready and not is_nil(@run.flex_artifact_key)}
          id={"export-file-#{@run.id}-download-flex"}
          navigate={~p"/gtfs/#{@version.id}/export-runs/#{@run.id}/download?file=flex"}
          class="block min-h-11 px-4 py-2 text-[13px] text-default hover:bg-canvas"
        >
          Download flex file
        </.link>
        <.link
          :if={@run.state == :ready and @run.export_type == :full}
          id={"export-file-#{@run.id}-compare"}
          navigate={~p"/gtfs/#{@version.id}/compare?newer=#{@run.id}"}
          class="block min-h-11 px-4 py-2 text-[13px] text-default hover:bg-canvas"
        >
          Compare with another file
        </.link>
      </div>
    </details>
    """
  end

  attr :run, :map, required: true
  attr :version, :map, required: true

  defp finished_band(assigns) do
    ~H"""
    <div
      id="export-finished"
      role="status"
      class="flex flex-wrap items-center gap-x-4 gap-y-3 border-b border-subtle bg-soft px-5 py-4 text-cyan-800"
    >
      <.icon name="hero-check-circle" class="size-5 shrink-0 text-cyan-700" />
      <div class="min-w-0 flex-1">
        <p class="text-sm font-semibold">{file_label(@run)} is ready.</p>
        <p class="mt-0.5 text-[13px]">{finished_meta(@run)}</p>
      </div>
      <span class="inline-flex items-center gap-2">
        <.link
          id="export-download-link"
          navigate={~p"/gtfs/#{@version.id}/export-runs/#{@run.id}/download"}
          class="btn btn-primary min-h-10 gap-1.5"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> Download file
        </.link>
        <button
          id="export-finished-dismiss"
          type="button"
          phx-click="dismiss_finished"
          aria-label="Dismiss finished export"
          title="Dismiss"
          class="grid size-11 place-items-center rounded-control transition-colors hover:bg-white/60"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </span>
    </div>
    """
  end

  defp ready_file_meta(run) do
    flex = if run.flex_artifact_key, do: " · + flex file", else: ""

    "#{run.artifact_filename || "file"} · #{file_size(run.artifact_size_bytes)}#{flex}"
  end

  defp finished_meta(run) do
    count = length(run.warnings || [])
    warnings = if count == 0, do: "No warnings", else: "#{count} warnings"

    "#{file_size(run.artifact_size_bytes)} · #{warnings} · until " <>
      DisplayClock.format_datetime(run.artifact_expires_at)
  end

  defp file_size(nil), do: "unknown size"
  defp file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp file_label(%{export_type: :pathways}), do: "Station pathways"
  defp file_label(%{export_type: :operations}), do: "Full feed with operations data"
  defp file_label(%{export_type: :operations_only}), do: "Operations data only"
  defp file_label(_run), do: "Full feed"

  defp file_status(%{state: :pending}), do: "Queued"

  defp file_status(%{state: :building, cancel_requested_at: at}) when not is_nil(at),
    do: "Cancelling…"

  defp file_status(%{state: :building}), do: "Building…"

  defp file_status(%{state: :ready, warnings: warnings}) when warnings in [nil, []],
    do: "No warnings"

  defp file_status(%{state: :ready, warnings: warnings}), do: "#{length(warnings)} warnings"

  defp file_status(%{state: :failed, failure_code: @conflict_code}),
    do: "Garage IDs clash with stop IDs"

  defp file_status(%{state: :failed, failure_code: "busy"}), do: "Could not start"
  defp file_status(%{state: :failed}), do: "Export failed"
  defp file_status(%{state: :interrupted}), do: "Export interrupted"
  defp file_status(%{state: :cancelled}), do: "Export cancelled"
  defp file_status(%{state: :expired}), do: "Download expired"
  defp file_status(_run), do: "Unknown"

  defp conflict_warnings(run),
    do: Enum.filter(run.warnings || [], &(warning_code(&1) == @conflict_code))

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
end
